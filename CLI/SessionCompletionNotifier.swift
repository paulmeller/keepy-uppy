import Foundation

/// The CLI's near-twin of `Agent/SessionCompletionNotifier.swift` —
/// duplicated rather than shared (see that file's comment on why this
/// doesn't live in `Shared/`), and adapted for a short-lived process rather
/// than a persistent one:
///
/// - Errors go to stderr in this file's own established style
///   (`FileHandle.standardError.write`), not `os.Logger` — `keepy-uppy` has
///   no logger of its own today, and a one-shot CLI invocation belongs on
///   the user's terminal, not in the unified log.
/// - The webhook POST is waited on synchronously (bounded by a timeout),
///   because unlike the Agent, this process calls `exit()` immediately
///   after `finished` runs — a fire-and-forget `URLSession` task would have
///   its underlying connection torn down before ever leaving the machine. A
///   launched script needs no such wait: `Process.run()` spawns a detached
///   child with its own PID that keeps running after this process exits.
/// See `Agent/SessionCompletionNotifier.swift`'s copy for the full reasoning
/// and for the local 307 experiment that motivated it. Duplicated rather than
/// shared for the same reason the rest of this file is.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        FileHandle.standardError.write(
            "keepy-uppy: session-completion webhook refused a \(response.statusCode) redirect to \(request.url?.host ?? "another host")\n"
                .data(using: .utf8)!)
        completionHandler(nil)
    }
}

final class SessionCompletionNotifier {
    private let webhookTimeout: TimeInterval = 10
    private let redirectBlocker = RedirectBlocker()

    func notifyAndWait(config: SessionCompletionConfig, event: SessionCompletionEvent) {
        if let scriptPath = config.scriptPath, !scriptPath.isEmpty {
            runScript(at: scriptPath, event: event)
        }
        if let webhookURL = config.webhookURL, !webhookURL.isEmpty {
            postWebhookAndWait(urlString: webhookURL, event: event)
        }
    }

    /// **Launches the script and does not wait for it, or bound it.** The
    /// Agent's copy caps its child at 10s; this one deliberately has no cap,
    /// and that asymmetry is a decision rather than an oversight:
    ///
    /// `keepy-uppy finished` calls `exit(0)` the instant this returns, and a
    /// timeout scheduled on a queue in a process that is about to exit never
    /// runs — checked directly, with the same `DispatchQueue.global()
    /// .asyncAfter` shape the Agent uses: scheduled, `exit(0)`, handler never
    /// fired, three times out of three. So porting the Agent's cap here would
    /// be dead code that reads like a guarantee. The alternative — blocking
    /// this process for up to 10s to enforce it — would put a ten-second
    /// stall on the end of every coding-assistant session, which is the exact
    /// hot path this command exists for.
    ///
    /// The consequence, stated plainly because it is the user's to manage:
    /// the script is **orphaned** on purpose. It is reparented to `launchd`,
    /// keeps running after `keepy-uppy` exits, and nothing in Keepy Uppy will
    /// ever terminate it. That is the desired behaviour for a hook (a
    /// notification, a `git push`, an upload should not be killed because the
    /// launcher was short-lived), but a script that hangs here hangs
    /// forever, once per invocation. `README.md` says so too, next to the
    /// Agent's 10s cap, so the difference is discoverable without reading
    /// this file.
    private func runScript(at path: String, event: SessionCompletionEvent) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.environment = environment(for: event)
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(
                "keepy-uppy: session-completion script at \(path) failed to launch: \(error.localizedDescription)\n"
                    .data(using: .utf8)!)
        }
    }

    private func environment(for event: SessionCompletionEvent) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["KEEPY_UPPY_EVENT"] = "session_ended"
        env["KEEPY_UPPY_TOOL"] = event.tool ?? ""
        env["KEEPY_UPPY_SESSION_ID"] = event.sessionID ?? ""
        env["KEEPY_UPPY_KIND"] = event.kind ?? ""
        env["KEEPY_UPPY_ENDED_AT"] = ISO8601DateFormatter().string(from: event.endedAt)
        return env
    }

    private func postWebhookAndWait(urlString: String, event: SessionCompletionEvent) {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            FileHandle.standardError.write(
                "keepy-uppy: session-completion webhook URL is not http/https, skipping\n".data(using: .utf8)!)
            return
        }

        var payload: [String: Any] = [
            "event": "session_ended",
            "endedAt": ISO8601DateFormatter().string(from: event.endedAt),
        ]
        if let tool = event.tool { payload["tool"] = tool }
        if let sessionID = event.sessionID { payload["sessionId"] = sessionID }
        if let kind = event.kind { payload["kind"] = kind }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: url, timeoutInterval: webhookTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { _, _, error in
            if let error {
                FileHandle.standardError.write(
                    "keepy-uppy: session-completion webhook POST failed: \(error.localizedDescription)\n"
                        .data(using: .utf8)!)
            }
            semaphore.signal()
        }
        task.delegate = redirectBlocker
        task.resume()
        _ = semaphore.wait(timeout: .now() + webhookTimeout + 1)
    }
}
