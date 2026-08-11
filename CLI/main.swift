import Foundation
import ServiceManagement

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

/// The live connection, kept beyond `connect()` for `reset` alone.
///
/// Every other verb wants the shared error handler below: "the daemon did not
/// answer" is conclusive and fatal for them. `reset` is the one verb for which
/// it is neither — an unreachable daemon is the half-installed state `reset`
/// exists to recover — so it needs a proxy carrying an error handler of its
/// own, and building one needs the connection rather than the proxy.
var daemonConnection: NSXPCConnection?

/// What a verb wants said *in addition to* the shared timeout line at the
/// bottom of this file, when its own silence needs explaining.
///
/// `reset` is the only verb that sets it, and it is the only one that needs to:
/// for everything else "timed out waiting for the daemon" is the whole story,
/// whereas a `reset` that stalls has left an install untouched and may have
/// left this Mac held awake — neither of which is deducible from that line.
///
/// A closure rather than a string because the note reports what this Mac's
/// sleep setting reads, and that read has to happen when the timeout fires
/// rather than ten seconds earlier.
var timeoutAdvice: (() -> String)?

func connect() -> HelperProtocol? {
    // The CLI-ONLY Mach service, never the app's. That is what makes the
    // daemon see this process as the CLI, and therefore what gives every
    // `keepy-uppy` invocation by this user the same stable `ClientID` — the
    // thing `off` with no flags needs in order to match sessions a previous
    // invocation started (`ClientRole.clientID(forUserID:)`).
    let connection = NSXPCConnection(machServiceName: cliMachServiceName, options: .privileged)
    connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
    if SigningRequirement.isEnforced {
        // Unchanged, and still correct: this pins the PEER (the daemon), not
        // this process's own identity — `setCodeSigningRequirement` validates
        // the other end of the connection. The daemon's *inbound* requirement
        // for this service (`SigningRequirement.cliRequirement`) deliberately
        // excludes the daemon's own identifier, so pinning an inbound
        // requirement here would reject the daemon on the first real message.
        connection.setCodeSigningRequirement(SigningRequirement.helperRequirement)
    }
    connection.resume()
    daemonConnection = connection
    return connection.remoteObjectProxyWithErrorHandler { error in
        FileHandle.standardError.write("keepy-uppy: \(error.localizedDescription)\n".data(using: .utf8)!)
        // End the wait here rather than letting the 10s timeout deliver it.
        // A connection error is already conclusive, and the slow path is most
        // likely to be hit exactly when a client and daemon disagree about
        // which Mach services exist — the mixed-version window during an
        // upgrade — where a 10s stall reads as a hang.
        exitCode = 1
        semaphore.signal()
    } as? HelperProtocol
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("keepy-uppy: \(message)\n".data(using: .utf8)!)
    exit(1)
}

// A placeholder only. `HelperService.startSession` overwrites `owner` with
// the identity it derived server-side from the accepting listener's role and
// the peer's authenticated uid, and never trusts this field — so despite the
// superficially similar shape, this is NOT the `"cli-<uid>"` id this process's
// sessions end up owned by (`ClientRole.clientID(forUserID:)`). It is kept
// only because `Session` requires a non-optional `owner` to encode.
let ownerID = ClientID(rawValue: "cli-pid-\(ProcessInfo.processInfo.processIdentifier)")

let command: CLICommand
switch parseCLIArguments(Array(CommandLine.arguments.dropFirst())) {
case .success(let parsed): command = parsed
case .failure(let error): fail(error.message)
}

// `finished` is handled here, before the daemon connection below is even
// attempted, because it deliberately never talks to the daemon at all — see
// CLICommand.swift's doc comment on this case. It reads the same shared
// UserDefaults suite `SessionCompletionStore`/`TriggerStore` already use and
// fires the configured script/webhook itself, so a coding-assistant tool's
// own completion hook (Claude Code's `SessionEnd`, etc.) works even on a
// machine where the daemon isn't running or hasn't been set up yet.
if case .finished(let tool) = command {
    let config = SessionCompletionStore.load()
    if config.scriptPath != nil || config.webhookURL != nil {
        SessionCompletionNotifier().notifyAndWait(config: config, event: SessionCompletionEvent(
            tool: tool, sessionID: nil, kind: nil, endedAt: Date()))
    }
    exit(0)
}

guard let proxy = connect() else { fail("could not connect to the Keepy Uppy daemon") }

switch command {
case .on(let kind, let persistence, let wakeMode):
    // `wakeMode` needs no new XPC method and no new parameter: `Session` is
    // what crosses the boundary, as JSON, and it carries the field. See
    // `HelperProtocol.startSession` for which fields of this payload the
    // daemon actually honours — `owner` below is not one of them.
    // `ownerUID: 0` is a placeholder in exactly the sense `ownerID` above is —
    // the daemon establishes it from the authenticated peer and never trusts
    // this field (`Session.authorized(id:owner:ownerUID:startedAt:)`). It is
    // stated because `Session.init` has no defaulted parameters: every field is
    // named at every construction site, on purpose.
    let session = Session(id: UUID(), kind: kind, owner: ownerID, ownerUID: 0,
                          persistence: persistence, origin: .manual, startedAt: Date(),
                          triggerID: nil, wakeMode: wakeMode, keepsDisksAwake: false)
    guard let data = try? JSONEncoder().encode(session) else { fail("internal error encoding session") }
    proxy.startSession(data) { sessionID, error in
        if let sessionID {
            print("Started session \(sessionID)")
            // Said on stderr, because a wake-mode flag *removes* the
            // lid-closed guarantee and neither flag's name mentions it.
            // stderr and not stdout — `status --json` and `sessions` output
            // must stay machine-clean, and this is a note about the
            // invocation, not part of the answer. `nil` for the default,
            // which takes nothing away.
            //
            // Inside the accepted branch, not before the call: a start the
            // daemon refuses (`ownerLimitReached`, `globalLimitReached`)
            // creates no session, so warning about what that session gave up
            // describes something that does not exist — two lines on stderr,
            // one saying the request failed and one qualifying a guarantee
            // the user never received.
            if let caveat = wakeMode.lidCloseCaveat {
                FileHandle.standardError.write("keepy-uppy: note: \(caveat)\n".data(using: .utf8)!)
            }
        } else {
            FileHandle.standardError.write("keepy-uppy: \(error ?? "failed")\n".data(using: .utf8)!)
            exitCode = 1
        }
        semaphore.signal()
    }

case .off(.all), .off(.own):
    // The two differ only in scope and in what to say when nothing matched;
    // everything else about reporting a stop was previously written twice.
    let all = command == .off(.all)
    proxy.stopAllSessions(all: all) { stopped, error in
        if let error {
            FileHandle.standardError.write("keepy-uppy: \(error)\n".data(using: .utf8)!)
            exitCode = 1
        } else if stopped == 0 {
            print(all ? "No sessions were running." : "No sessions of yours were running.")
        } else {
            print("Stopped \(stopped) session(s).")
        }
        semaphore.signal()
    }

case .off(.session(let id)):
    proxy.stopSession(id) { ok, error in
        if !ok { FileHandle.standardError.write("keepy-uppy: \(error ?? "failed")\n".data(using: .utf8)!); exitCode = 1 }
        semaphore.signal()
    }

case .status(let json):
    proxy.currentState { disabled in
        if json {
            print("{\"keepingAwake\": \(disabled)}")
        } else {
            print(disabled ? "keeping awake" : "normal sleep")
        }
        semaphore.signal()
    }

case .sessions:
    proxy.listSessions { data, error in
        guard let data, let sessions = try? JSONDecoder().decode([Session].self, from: data) else {
            FileHandle.standardError.write("keepy-uppy: \(error ?? "failed to list sessions")\n".data(using: .utf8)!)
            exitCode = 1
            semaphore.signal()
            return
        }
        if sessions.isEmpty {
            print("No active sessions.")
        } else {
            for session in sessions {
                // `wake=` is here because nothing else reports it. `status`
                // answers a boolean that is true for every mode — deliberately
                // unchanged, scripts parse it — and the menu bar shows the
                // same filled balloon either way, so before this line a
                // `--display-may-sleep` session was indistinguishable from a
                // lid-safe one in every output the product has.
                print("\(session.id)  \(session.kind)  origin=\(session.origin.rawValue)"
                      + "  wake=\(session.wakeMode.sessionListDescription)")
            }
        }
        semaphore.signal()
    }

case .finished:
    fatalError("handled above, before the daemon connection is attempted")

case .setup:
    // Unlike the branches above, this doesn't talk to the daemon over XPC
    // at all — SMAppService registration is a separate, synchronous call.
    // There's no async completion handler to signal the semaphore from, so
    // this branch does the work inline and signals immediately itself,
    // falling through to the same wait/exit epilogue as every other branch
    // rather than exiting early or leaving the semaphore unsignaled (which
    // would hang the process for the full 10s timeout).
    func registerAndReport(_ label: String, _ service: SMAppService) -> Bool {
        do {
            try service.register()
        } catch {
            FileHandle.standardError.write("keepy-uppy: \(label) registration failed: \(error.localizedDescription)\n".data(using: .utf8)!)
            exitCode = 1
            return false
        }
        switch service.status {
        case .enabled:
            print("\(label): registered")
        case .requiresApproval:
            print("\(label): requires approval — run 'keepy-uppy setup' again after approving in System Settings")
            return true
        default:
            print("\(label): \(service.status)")
        }
        return false
    }

    let daemonNeedsApproval = registerAndReport(
        "Daemon", SMAppService.daemon(plistName: helperPlistName))
    let agentNeedsApproval = registerAndReport(
        "Agent", SMAppService.agent(plistName: agentPlistName))

    if daemonNeedsApproval || agentNeedsApproval {
        SMAppService.openSystemSettingsLoginItems()
    }

    semaphore.signal()

case .reset:
    // `unregister()` is deliberately routed through SMAppService rather than
    // documented as `sudo launchctl bootout`: smd performs the privileged
    // eviction on the user's behalf, so a wedged daemon is recoverable
    // without root.
    //
    // Unlike `.setup` above, this is no longer purely synchronous work.
    // Eviction removes the only process that can clear `SleepDisabled`, and
    // that setting survives process death and reboot — so a `reset` run with a
    // session live used to leave the Mac unable to sleep, permanently, with
    // nothing left running to fix it. The daemon is therefore asked to put the
    // machine back *first*, and `DaemonRemoval` decides whether the eviction
    // may follow. See that type for the whole rule; this branch is only its
    // plumbing.
    func unregisterAndReport(_ label: String, _ service: SMAppService) {
        do {
            try service.unregister()
            print("\(label): unregistered")
        } catch {
            // Not-registered is the expected, benign case when recovering a
            // half-installed state, and is worth reporting as success rather
            // than an error the user has to interpret.
            if service.status == .notRegistered || service.status == .notFound {
                print("\(label): not registered")
            } else {
                FileHandle.standardError.write("keepy-uppy: \(label) unregister failed: \(error.localizedDescription)\n".data(using: .utf8)!)
                exitCode = 1
            }
        }
    }

    func finish(_ outcome: DaemonRemoval.ConvergeOutcome) {
        switch DaemonRemoval.next(after: outcome) {
        case .refuse(let reason):
            FileHandle.standardError.write("keepy-uppy: \(reason)\n".data(using: .utf8)!)
            exitCode = 1
        case .unregister:
            switch outcome {
            case .sleepRestored(let stopped) where stopped > 0:
                print("Ended \(stopped) session(s) and restored sleep.")
            case .unreachable:
                // stderr, and not fatal: on a machine that was never set up
                // this is the ordinary case, and `reset` still has real work
                // to do. It is a note, not a failure, so the exit status is
                // left to whether the unregisters below succeed.
                //
                // The read is this process's own. It is unprivileged —
                // `PowerControl.sleepDisabled()` is in `Shared/`, compiled into
                // this target — and it is the difference between telling a user
                // what to go and check and telling them what is true of their
                // Mac. It matters most in the case the note reads oddest for: a
                // daemon too old to know `prepareForRemoval` answers "does not
                // implement selector" and lands here while still alive and
                // still holding the setting on.
                FileHandle.standardError.write(
                    "keepy-uppy: \(DaemonRemoval.unreachableNote(sleepStillDisabled: PowerControl.sleepDisabled()))\n"
                        .data(using: .utf8)!)
            case .sleepRestored, .sleepStillDisabled:
                break
            }
            unregisterAndReport("Daemon", SMAppService.daemon(plistName: helperPlistName))
            unregisterAndReport("Agent", SMAppService.agent(plistName: agentPlistName))
            print("Run 'keepy-uppy setup' to register again.")
        }
        semaphore.signal()
    }

    // The third way this can end, after the reply and the error: the daemon
    // accepts the message and never answers. Nothing here runs then — the
    // semaphore times out ten seconds later and the process exits without
    // unregistering, which is the safe direction but says so to nobody. This is
    // what it says instead, and it reads the sleep setting at the moment it is
    // printed rather than now.
    timeoutAdvice = { DaemonRemoval.timedOutNote(sleepStillDisabled: PowerControl.sleepDisabled()) }

    // A proxy of this branch's own, so an unreachable daemon lands in
    // `finish(.unreachable)` rather than in the shared handler's exit path —
    // which would abandon `reset` without unregistering anything, in exactly
    // the situation it is most often run. Exactly one of the two closures
    // runs: XPC delivers either the reply or the error, never both.
    let removalProxy = daemonConnection?.remoteObjectProxyWithErrorHandler { _ in
        finish(.unreachable)
    } as? HelperProtocol

    if let removalProxy {
        removalProxy.prepareForRemoval { stopped, sleepRestored in
            // The count is carried on both branches. It used to be dropped on
            // the refusal, which made the refusal sound like a no-op — but
            // `prepareForRemoval` ends every session *before* it tries the
            // clear, so by the time this arrives those sessions are gone
            // whichever way the flag went.
            finish(sleepRestored
                   ? .sleepRestored(stopped: stopped)
                   : .sleepStillDisabled(stopped: stopped))
        }
    } else {
        finish(.unreachable)
    }
}

let waitResult = semaphore.wait(timeout: .now() + 10)
if waitResult == .timedOut {
    FileHandle.standardError.write("keepy-uppy: timed out waiting for the daemon\n".data(using: .utf8)!)
    if let timeoutAdvice {
        FileHandle.standardError.write("keepy-uppy: \(timeoutAdvice())\n".data(using: .utf8)!)
    }
    exitCode = 1
}
exit(exitCode)
