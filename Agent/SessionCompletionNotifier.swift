import Foundation

/// Impure — the one place in the Agent that shells out to a script or makes
/// a network call. Deliberately NOT in `Shared/`: that compiles into every
/// target including the root `KeepyUppyHelper`, which has zero exec/network
/// capability today and should gain none, even unreached — see
/// `Shared/SessionCompletion.swift` for the pure config/diff logic this
/// wraps. `CLI/SessionCompletionNotifier.swift` is this file's near-twin,
/// duplicated rather than shared for the same reason.
///
/// Fire-and-forget: a slow webhook endpoint or a hung script must never
/// stall the Agent's 5s evidence-loop tick. Failures are logged via
/// `agentLogger`, never thrown, never surfaced as a crash.
/// Refuses every HTTP redirect on the webhook POST.
///
/// `URLSession.shared` follows redirects by default, so a webhook endpoint —
/// or anything that has taken it over, or a plain HTTP hop that has been
/// tampered with in flight — can answer the POST with a 307 and have the
/// request, method, headers and body replayed verbatim against a completely
/// different host. Verified locally before writing this: a 307 from
/// `127.0.0.1:8801` delivered the POST body to `127.0.0.1:8802` untouched;
/// with this delegate attached the redirect was refused and the second server
/// received nothing. Low severity, since the endpoint is one the user typed
/// themselves, but the user typed *one* host and this is what holds the
/// request to it.
///
/// Resolving the completion handler with `nil` returns the redirect response
/// itself to the caller instead of following it, which is exactly what we
/// want: the POST is not replayed, and the notifier logs a non-2xx outcome
/// rather than a network error.
///
/// Duplicated in `CLI/SessionCompletionNotifier.swift` for the same reason
/// that file duplicates everything else here.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        agentLogger.error("session-completion webhook refused a \(response.statusCode) redirect to \(request.url?.host ?? "another host")")
        completionHandler(nil)
    }
}

final class SessionCompletionNotifier {
    private let scriptTimeout: TimeInterval = 10
    /// Held as a property rather than created per call. `URLSessionTask`
    /// does retain its delegate until the task completes (checked
    /// empirically — an inline instance is *not* deallocated early), but a
    /// single stateless instance owned here does not depend on that
    /// behaviour at all.
    private let redirectBlocker = RedirectBlocker()

    func notify(config: SessionCompletionConfig, event: SessionCompletionEvent) {
        if let scriptPath = config.scriptPath, !scriptPath.isEmpty {
            runScript(at: scriptPath, event: event)
        }
        if let webhookURL = config.webhookURL, !webhookURL.isEmpty {
            postWebhook(urlString: webhookURL, event: event)
        }
    }

    private func runScript(at path: String, event: SessionCompletionEvent) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.environment = environment(for: event)
        do {
            try process.run()
        } catch {
            agentLogger.error("session-completion script at \(path) failed to launch: \(error.localizedDescription)")
            return
        }
        let timeout = scriptTimeout
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
            agentLogger.error("session-completion script at \(path) timed out after \(Int(timeout))s and was terminated")
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

    private func postWebhook(urlString: String, event: SessionCompletionEvent) {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            agentLogger.error("session-completion webhook URL is not http/https, skipping: \(urlString)")
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

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let task = URLSession.shared.dataTask(with: request) { _, _, error in
            if let error {
                agentLogger.error("session-completion webhook POST to \(url.host ?? url.absoluteString) failed: \(error.localizedDescription)")
            }
        }
        task.delegate = redirectBlocker
        task.resume()
    }
}
