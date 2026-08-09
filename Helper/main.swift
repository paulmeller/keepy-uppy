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

// The daemon's last act on the way out, and part of why the persistent axis is
// safe to entrust to a process at all.
//
// `SleepDisabled` is global, root-only, and survives process death *and*
// reboot, so any path that ends this process without clearing it leaves a Mac
// that will not sleep and nothing running to explain why. Until now the only
// covered path was the one this daemon chooses for itself
// (`DaemonRuntime.tickLocked`'s "app bundle is gone", which makes exactly the
// write below before `exit(0)`). Every path somebody *else* chooses —
// `launchctl bootout`, the eviction `keepy-uppy reset` performs, an upgrade, a
// toggle in System Settings — arrives as SIGTERM, whose default disposition is
// to die quietly with the setting still on. This makes the persistent axis's
// lifetime match the process's, which is what the assertion axis has always got
// for free: `powerd` reaps a dead holder's assertions and logs it as
// `ClientDied`. Two mechanisms, both put back, for two different reasons —
// they are complementary, and neither stands in for the other.
//
// `DispatchSource`, not `signal(SIGTERM, handler)`: the handler calls IOKit and
// `Logger`, neither of which is async-signal-safe, so running it on the
// interrupted thread would be undefined behaviour at exactly the moment
// correctness matters most. `SIG_IGN` first is what stops the default
// disposition from killing the process before the source ever fires.
//
// The write is direct and takes no locks, deliberately. Routing it through
// `DaemonRuntime`'s serial queue would be tidier and could block behind
// whatever that queue is already running — and a handler that blocks is
// indistinguishable from no handler, because launchd follows SIGTERM with
// SIGKILL. A bare `setSleepDisabled(false)` touches no shared state and cannot
// be made to wait. Assertions are left to `powerd`, as they are on every other
// exit path here.
//
// `exit(0)`, for the same reason the Team ID guard above gives: the plist's
// `KeepAlive.SuccessfulExit = false` respawns this daemon on any non-zero
// exit, so exiting non-zero here would fight whoever asked it to stop, in a
// loop. Zero leaves the job on-demand — the next client message relaunches it,
// and `start()` converges again on the way in.
//
// SIGKILL stays uncatchable, so this is one more path covered, not a
// guarantee. `DaemonRuntime.start()`'s converge-to-safe at launch remains the
// backstop for everything nothing can catch.
signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
terminationSource.setEventHandler {
    let ok = PowerControl.setSleepDisabled(false)
    helperLogger.log("SIGTERM: forced sleep enabled, success=\(ok); exiting")
    exit(0)
}
terminationSource.resume()

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
