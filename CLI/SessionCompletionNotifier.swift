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
final class SessionCompletionNotifier {
    private let webhookTimeout: TimeInterval = 10

    func notifyAndWait(config: SessionCompletionConfig, event: SessionCompletionEvent) {
        if let scriptPath = config.scriptPath, !scriptPath.isEmpty {
            runScript(at: scriptPath, event: event)
        }
        if let webhookURL = config.webhookURL, !webhookURL.isEmpty {
            postWebhookAndWait(urlString: webhookURL, event: event)
        }
    }

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
        URLSession.shared.dataTask(with: request) { _, _, error in
            if let error {
                FileHandle.standardError.write(
                    "keepy-uppy: session-completion webhook POST failed: \(error.localizedDescription)\n"
                        .data(using: .utf8)!)
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + webhookTimeout + 1)
    }
}
