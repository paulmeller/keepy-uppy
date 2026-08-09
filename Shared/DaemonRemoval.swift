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
/// `Helper/` is not in that target's module graph at all — so the one part of
/// this that can be got silently wrong (unregistering anyway) would be verified
/// by reading alone. Same argument, and same move, as `SessionIsolation` and
/// `SessionTable.desiredPowerPlan`.
enum DaemonRemoval {
    /// What the daemon reported when it was asked to put the Mac back before
    /// being evicted — the reply to `HelperProtocol.prepareForRemoval`.
    enum ConvergeOutcome: Equatable {
        /// Every session ended and the sleep setting is back off. The Mac can
        /// sleep now, so evicting the daemon cannot strand it awake.
        case sleepRestored(stopped: Int)
        /// The daemon is still there and this Mac is still being held: the
        /// root-only clear was refused.
        case sleepStillDisabled
        /// Nothing answered on the CLI's Mach service — no daemon registered,
        /// one already evicted, or a build predating `prepareForRemoval`.
        case unreachable
    }

    enum Step: Equatable {
        /// Go ahead and unregister the launchd jobs.
        case unregister
        /// Leave the install exactly as it is, and say why.
        case refuse(String)
    }

    static func next(after outcome: ConvergeOutcome) -> Step {
        switch outcome {
        case .sleepRestored:
            return .unregister

        case .sleepStillDisabled:
            // The one branch that must not unregister. The daemon is alive,
            // it rewrites the setting on every 5s tick, and it is the only
            // thing on the machine that can. Evicting it now is the single
            // action that turns a transient refusal into a permanent one.
            return .refuse(
                "the daemon could not turn sleep back on, so this Mac is still being held awake. "
                + "Nothing was unregistered — evicting the daemon now would leave that setting on "
                + "with no process left to clear it, and it survives a reboot. "
                + "The daemon retries every 5 seconds; run 'keepy-uppy reset' again in a moment.")

        case .unreachable:
            // Refusing here would break `reset` for precisely the state it
            // exists to recover: a half-installed or wedged daemon that cannot
            // answer is exactly when someone runs it. There is nothing to gain
            // either — a daemon that will not answer is not going to clear the
            // setting whether or not it stays registered, and the CLI is
            // unprivileged so it cannot clear it in the daemon's place. Going
            // ahead cannot make this worse; it just cannot make it better,
            // which is what the caller gets told instead of a refusal.
            return .unregister
        }
    }

    /// What to tell someone whose daemon did not answer. Not an error: on a
    /// machine that was never set up — or was already reset once — this is the
    /// ordinary case, and a scary line there teaches people to ignore the line.
    /// It names the check rather than performing it, because the CLI has no
    /// privilege to read or repair the setting on the user's behalf.
    static let unreachableNote =
        "the daemon did not answer, so no sessions could be ended before unregistering. "
        + "If this Mac will not sleep afterwards, check 'pmset -g | grep -i sleepdisabled'."
}
