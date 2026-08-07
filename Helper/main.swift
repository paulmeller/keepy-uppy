import Foundation

// A build that runs `xcodebuild archive` directly instead of `just archive`
// never has REPLACE_WITH_TEAM_ID substituted. The signing requirement still
// parses in that case — it just matches nothing, so the daemon becomes
// silently unreachable. That looks like "the app is broken", and the wrong
// fix for that misdiagnosis is loosening the requirement. Refuse to start
// instead, loudly, so the real cause is obvious. Compiled out in DEBUG,
// where the placeholder is expected (ad-hoc builds have no Team ID at all —
// see SigningRequirement.isEnforced).
//
// exit(0), not exit(1): the launchd plist sets KeepAlive.SuccessfulExit =
// false, which respawns the daemon on *any non-zero* exit. exit(1) here
// would crash-loop a mis-archived build roughly every 10 seconds forever,
// faulting each time and never reaching `runtime.start()` to converge sleep
// back to enabled. `DaemonRuntime.tickLocked()`'s "app bundle is gone" exit
// follows the same pattern for the same reason: this must not auto-restart.
#if !DEBUG
guard SigningRequirement.teamID != "REPLACE_WITH_TEAM_ID" else {
    helperLogger.fault("Refusing to start: Team ID placeholder was not substituted at build time. Archive with `just archive`, not a bare `xcodebuild archive`.")
    exit(0)
}
#endif

let runtime = DaemonRuntime()
runtime.start()

// One Mach service per client role, one listener each: role is established
// structurally by which service a peer connects to, rather than derived
// after acceptance from the peer's pid (TOCTOU-prone — a pid can be recycled
// between accept and lookup). Every listener sets its code-signing
// requirement before `resume()`, exactly as before, and each of those
// requirements now admits exactly one bundle identifier — which is what lets
// the accepting listener also supply the peer's stable `ClientID`
// (`ClientRole.clientID(forUserID:)`).
//
// Driven off `ClientRole.allCases`, so adding a role means adding a case to
// `ClientRole` and a `MachServices` entry in
// `Launchd/au.com.workwireless.keepy-uppy.helper.plist` — nothing here. A
// listener whose service is not declared in that plist never receives
// anything.

// Both arrays are retained deliberately: `NSXPCListener.delegate` is weak, so
// a delegate that only lived for one loop iteration would be deallocated
// before the first connection ever arrived.
var listenerDelegates: [HelperListenerDelegate] = []
var listeners: [NSXPCListener] = []

for role in ClientRole.allCases {
    let delegate = HelperListenerDelegate(runtime: runtime, role: role)
    let listener = NSXPCListener(machServiceName: role.machServiceName)
    listener.delegate = delegate
    listener.resume()
    listenerDelegates.append(delegate)
    listeners.append(listener)
}

RunLoop.main.run()
