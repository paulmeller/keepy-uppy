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
final class SessionCompletionNotifier {
    private let scriptTimeout: TimeInterval = 10

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

        URLSession.shared.dataTask(with: request) { _, _, error in
            if let error {
                agentLogger.error("session-completion webhook POST to \(url.host ?? url.absoluteString) failed: \(error.localizedDescription)")
            }
        }.resume()
    }
}
