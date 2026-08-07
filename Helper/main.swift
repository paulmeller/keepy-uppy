import Foundation

// A build that runs `xcodebuild archive` directly instead of `just archive`
// never has REPLACE_WITH_TEAM_ID substituted. The signing requirement still
// parses in that case — it just matches nothing, so the daemon becomes
// silently unreachable. That looks like "the app is broken", and the wrong
// fix for that misdiagnosis is loosening the requirement. Refuse to start
// instead, loudly, so the real cause is obvious. Compiled out in DEBUG,
// where the placeholder is expected (ad-hoc builds have no Team ID at all —
// see SigningRequirement.isEnforced).
#if !DEBUG
guard SigningRequirement.teamID != "REPLACE_WITH_TEAM_ID" else {
    helperLogger.fault("Refusing to start: Team ID placeholder was not substituted at build time. Archive with `just archive`, not a bare `xcodebuild archive`.")
    exit(1)
}
#endif

let runtime = DaemonRuntime()
runtime.start()

// Two Mach services, two listeners: role is established structurally by
// which service a peer connects to, rather than derived after acceptance
// from the peer's pid (TOCTOU-prone — a pid can be recycled between accept
// and lookup). Both listeners set their code-signing requirement before
// `resume()`, exactly as before.

let generalDelegate = HelperListenerDelegate(runtime: runtime, isAgent: false)
let generalListener = NSXPCListener(machServiceName: helperMachServiceName)
generalListener.delegate = generalDelegate
generalListener.resume()

let agentDelegate = HelperListenerDelegate(runtime: runtime, isAgent: true)
let agentListener = NSXPCListener(machServiceName: agentMachServiceName)
agentListener.delegate = agentDelegate
agentListener.resume()

RunLoop.main.run()
