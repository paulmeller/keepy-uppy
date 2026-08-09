import Foundation

/// The order `keepy-uppy reset` has to do things in, and what to do when the
/// step that puts the Mac back does not land.
///
/// ## Why the order needs a rule of its own
///
/// `reset` unregisters the daemon through `SMAppService.unregister()` — smd
/// performs the privileged eviction, which is what makes a wedged install
/// recoverable without root. But eviction removes **the only process that can
/// clear `SleepDisabled`**: that setting is global, root-only, and survives
/// process death *and reboot*. So unregistering while a session is live left
/// the setting at `1` with nothing running that would ever put it back — a Mac
/// that never sleeps again, with no visible cause and no client left to blame
/// for it.
///
/// Nothing here trades one mechanism against the other. Assertions and
/// `SleepDisabled` are complementary, and the assertion axis needs no rule at
/// all in this scenario: `powerd` reaps a dead holder's assertions, so an
/// evicted daemon takes them with it. It is only the persistent axis that can
/// outlive the daemon, so it is the only one the order has to protect.
///
/// The rule is therefore: put the machine back **first**, evict **second**, and
/// never evict while the setting is known to still be on. Every partial failure
/// then leaves the Mac able to sleep rather than unable — the direction that
/// costs a user some battery instead of costing them a machine that will not
/// rest.
///
/// ## Why this lives in `Shared/`
///
/// Because the alternative is that it lives nowhere a test can reach.
/// `CLI/main.swift` is top-level executable code outside the test target, and
/// `Helper/` is not in that target's module graph at all — so the parts of this
/// that can be got silently wrong (unregistering anyway; reporting a Mac as
/// held when it is not) would be verified by reading alone. Same argument, and
/// same move, as `SessionIsolation` and `SessionTable.desiredPowerPlan`.
enum DaemonRemoval {
    /// What the daemon reported when it was asked to put the Mac back before
    /// being evicted — the reply to `HelperProtocol.prepareForRemoval`.
    ///
    /// Both of the reachable cases carry a session count, because the daemon
    /// ends every session *before* it tries the clear
    /// (`DaemonRuntime.prepareForRemoval`). A refusal is therefore never a
    /// no-op: the user's sessions are already gone by the time it is reported,
    /// and a message that says only "nothing was unregistered" is precise about
    /// the install and silent about the eight-hour job that just stopped.
    enum ConvergeOutcome: Equatable {
        /// Every session ended and the sleep setting is back off. The Mac can
        /// sleep now, so evicting the daemon cannot strand it awake.
        case sleepRestored(stopped: Int)
        /// Every session ended, and this Mac is still being held: the root-only
        /// clear did not take and the setting still reads on.
        case sleepStillDisabled(stopped: Int)
        /// Nothing answered on the CLI's Mach service — no daemon registered,
        /// one already evicted, or a daemon too old to have `prepareForRemoval`
        /// (see `next(after:)`, which is careful about that last one).
        case unreachable

        /// The cases without their payloads, purely so they can be enumerated.
        /// Swift synthesises `CaseIterable` only for payload-free enums, and
        /// the payloads here are what the refusal message is written from, so
        /// the two are separated rather than either one given up.
        enum Kind: CaseIterable {
            case sleepRestored
            case sleepStillDisabled
            case unreachable

            /// The payloads worth exercising for this case: both "and it ended
            /// some" and "and it ended none" wherever that is a real
            /// distinction, because it is a distinction the messages make.
            var representatives: [ConvergeOutcome] {
                switch self {
                case .sleepRestored:
                    return [.sleepRestored(stopped: 0), .sleepRestored(stopped: 3)]
                case .sleepStillDisabled:
                    return [.sleepStillDisabled(stopped: 0), .sleepStillDisabled(stopped: 2)]
                case .unreachable:
                    return [.unreachable]
                }
            }
        }

        var kind: Kind {
            switch self {
            case .sleepRestored: return .sleepRestored
            case .sleepStillDisabled: return .sleepStillDisabled
            case .unreachable: return .unreachable
            }
        }

        /// Every outcome, with representative payloads, so the rule below can
        /// be tested as an invariant over all of them rather than case by case.
        ///
        /// The chain is what makes "a new outcome cannot be added without
        /// deciding which side of the rule it falls on" a fact about the
        /// compiler rather than about a list somebody remembered to update: a
        /// new case breaks `kind`'s switch, fixing that needs a new `Kind`,
        /// which breaks `representatives`' switch, and fixing *that* puts the
        /// outcome in here — where `DaemonRemovalTests` exercises it. The
        /// invariant test used to iterate a hand-written array, which is
        /// exactly as complete as its author's memory: a fourth outcome added
        /// to the enum passed through it unexercised, even though the compiler
        /// did force the *decision* at `next(after:)` and at the CLI's
        /// reporting switch.
        static let all: [ConvergeOutcome] = Kind.allCases.flatMap { $0.representatives }
    }

    enum Step: Equatable {
        /// Go ahead and unregister the launchd jobs.
        case unregister
        /// Leave the install exactly as it is, and say why.
        case refuse(String)
    }

    /// Whether the daemon may report this Mac as put back, given what its clear
    /// returned **and** what the setting then read.
    ///
    /// The write's return value alone was the wrong question, and wrong in the
    /// one direction that never recovers. `IOPMSetSystemPowerSetting` is
    /// undeclared SPI, and "a machine where the undeclared SPI refuses writes
    /// outright" is a case `PowerPlanHolder.apply` already contemplates. On one
    /// of those the clear returns `false` on *every* attempt, so `reset`
    /// reported `.sleepStillDisabled`, refused, and told the user to run it
    /// again in five seconds — advice that could never come true. And on that
    /// same machine the setting was never successfully written to `1` either,
    /// so the Mac whose recovery verb had just locked itself out was not being
    /// held at all.
    ///
    /// So the question is about the setting, not about the write: this Mac is
    /// put back if the clear landed **or** the setting reads off. Both halves
    /// earn their place.
    ///
    /// - The read is what fixes the refuses-every-write machine above.
    /// - The write's success still short-circuits it, because a setting that
    ///   reads on immediately after a *successful* clear is something else's
    ///   doing — another root process holding it on — and that is not a
    ///   refusal the daemon can retry away. Without the short-circuit, one
    ///   foreign holder would lock `reset` out permanently, which is the same
    ///   bug wearing a different hat.
    ///
    /// The one thing this cannot resolve is a failed *read*:
    /// `PowerControl.sleepDisabled()` answers `false` when
    /// `IOPMCopySystemPowerSettings` declines to answer, which arrives here as
    /// "off". That is deliberate, and it is the same answer `isKeepingAwake()`
    /// has always given the same failure; the alternative is a refusal no retry
    /// can clear, which is precisely what this exists to stop.
    static func sleepWasRestored(writeSucceeded: Bool, settingStillOn: Bool) -> Bool {
        writeSucceeded || !settingStillOn
    }

    static func next(after outcome: ConvergeOutcome) -> Step {
        switch outcome {
        case .sleepRestored:
            return .unregister

        case .sleepStillDisabled(let stopped):
            // The one branch that must not unregister. The daemon is alive,
            // it rewrites the setting on every 5s tick, and it is the only
            // thing on the machine that can. Evicting it now is the single
            // action that turns a transient refusal into a permanent one.
            //
            // The message leads with the sessions because they are already
            // gone — `prepareForRemoval` stops first and writes second — so
            // "nothing was unregistered" on its own would describe a no-op
            // that did not happen.
            return .refuse(
                sessionsAlreadyEnded(stopped)
                + "the daemon could not turn sleep back on, so this Mac is still being held awake. "
                + "Nothing was unregistered — evicting the daemon now would leave that setting on "
                + "with no process left to clear it, and it survives a reboot. "
                + "The daemon retries every 5 seconds; run 'keepy-uppy reset' again in a moment.")

        case .unreachable:
            // Refusing here would break `reset` for precisely the state it
            // exists to recover: a half-installed or wedged daemon that cannot
            // answer is exactly when someone runs it.
            //
            // The old justification for that — "a daemon that will not answer
            // is not going to clear the setting whether or not it stays
            // registered" — is true of a daemon that is *gone* and false of one
            // flavour of this case. A daemon from a build predating
            // `prepareForRemoval` replies "does not implement selector", which
            // lands here, and that daemon is alive, ticking, and would converge
            // if it were asked in a vocabulary it knows. The window is real
            // rather than theoretical: the job is launched on demand and
            // respawned only after an unsuccessful exit, so an in-place bundle
            // overwrite restarts nothing, and the old process does not notice
            // either — `DaemonRuntime.tickLocked` checks that the bundle path
            // still *exists*, which after an overwrite it does.
            //
            // Unregistering anyway is still the right step, because the
            // alternative is worse in the case that matters more: on a machine
            // whose daemon is genuinely gone, a previous incarnation may well
            // have left the setting on, and refusing would make the one verb
            // that could repair the install permanently unavailable — with
            // nothing running that would ever clear the setting either. What
            // changed is what the caller is told: `unreachableNote` now *reads*
            // the setting instead of naming a check, so the skewed-protocol
            // case ends with a definite statement and a command rather than a
            // quiet unregister. `Helper/main.swift`'s SIGTERM handler closes
            // the same window outright for every daemon carrying it, since the
            // eviction's own signal is what that handler converges on.
            return .unregister
        }
    }

    /// The one repair available to someone whose daemon is not going to perform
    /// it. Reading `SleepDisabled` is unprivileged; clearing it is root-only,
    /// which is why this is a command for the user rather than something the
    /// CLI quietly does on their behalf.
    static let manualSleepRepair = "sudo pmset -a disablesleep 0"

    /// What to tell someone whose daemon did not answer. Not an error: on a
    /// machine that was never set up — or was already reset once — this is the
    /// ordinary case, and a scary line there teaches people to ignore the line.
    ///
    /// It used to name a check ("check `pmset -g | grep -i sleepdisabled`")
    /// rather than perform one, on the grounds that the CLI could neither read
    /// nor repair the setting. Half of that was wrong. The *repair* is
    /// root-only; the *read* is not — `PowerControl.sleepDisabled()` lives in
    /// `Shared/`, which `project.yml` compiles into the `keepy-uppy` target,
    /// and the old note already asked the user to run the unprivileged check
    /// themselves. So the CLI reads it, and a conditional hint about what might
    /// be true becomes a statement about this Mac plus the command that fixes
    /// it. A user who ran the old check and saw `1` was told nothing further.
    static func unreachableNote(sleepStillDisabled: Bool) -> String {
        let opening = "the daemon did not answer, so no sessions could be ended before unregistering. "
        guard sleepStillDisabled else {
            return opening
                + "This Mac's sleep setting reads as off, so unregistering cannot strand it awake — "
                + "that setting is the only thing here that can outlive the daemon, since power "
                + "assertions are released when their holder dies."
        }
        return opening
            + "This Mac is being held awake right now: 'SleepDisabled' is on, and it survives a "
            + "reboot. Unregistering leaves nothing running that would ever clear it, so put sleep "
            + "back yourself with '\(manualSleepRepair)'."
    }

    /// What `reset` wants said *in addition to* the CLI's shared "timed out
    /// waiting for the daemon" line.
    ///
    /// The timeout itself already errs in the safe direction — a daemon that
    /// accepts `prepareForRemoval` and never replies leaves the CLI exiting 1
    /// without unregistering anything — but the shared line says none of the
    /// three things this particular user needs: that their install was left
    /// alone, what this Mac's sleep setting actually reads, and what to do
    /// next. The refusal path says all three, and a stall is no less alarming
    /// than a refusal.
    static func timedOutNote(sleepStillDisabled: Bool) -> String {
        let opening = "the daemon took the request to put this Mac back and never replied, so "
            + "nothing was unregistered. "
        guard sleepStillDisabled else {
            return opening
                + "This Mac's sleep setting reads as off. Run 'keepy-uppy reset' again once the "
                + "daemon is answering."
        }
        return opening
            + "This Mac is being held awake right now: 'SleepDisabled' is on, and it survives a "
            + "reboot. Run 'keepy-uppy reset' again once the daemon is answering; if it never "
            + "does, put sleep back yourself with '\(manualSleepRepair)'."
    }

    /// The refusal's opening clause. Separate because the count is the part a
    /// user acts on differently: none ended is a `reset` that cost them
    /// nothing, and several ended is work that has already stopped and will not
    /// restart when they retry.
    private static func sessionsAlreadyEnded(_ stopped: Int) -> String {
        stopped == 0
            ? "no sessions were running, and "
            : "\(stopped) session(s) were ended and will not come back, but "
    }
}
