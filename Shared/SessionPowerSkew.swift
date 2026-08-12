import Foundation

/// **Did the power request I sent survive into the session the daemon
/// admitted?**
///
/// ## Why this exists
///
/// `Session` crosses the XPC boundary as JSON, and `Session.init(from:)`
/// defaults both power axes when their key is absent. That is what lets a
/// client and a daemon of different vintages keep talking at all — but it is
/// also, exactly, what lets a *new* client's request be **silently dropped by
/// an old daemon**: the daemon decodes the payload, never sees `wakeMode` or
/// `keepsDisksAwake` because its `Session` has no such property, admits a
/// session without them, and replies with a session id. Nothing fails. The
/// client's UI shows a running session that is not doing what was asked.
///
/// This is not hypothetical. The daemon is a root LaunchDaemon launched on
/// demand and respawned only after an *unsuccessful* exit
/// (`KeepAlive: {SuccessfulExit: false}` plus `MachServices`), so replacing the
/// app bundle in place restarts nothing — the old daemon keeps serving until
/// the Mac reboots. On the machine this was written on, the live daemon
/// predates both axes and had been up for three days.
///
/// ## Why a read-back rather than a version check
///
/// Because the check costs **no new protocol surface at all**, and new protocol
/// surface is the one thing that must not be spent here. Measured over an
/// isolated `NSXPCListener` (`UnimplementedVerbProbeTests`): sending a verb the
/// far side does not implement is *not* a recoverable per-call error. It
/// interrupts the connection, and the daemon-side connection is **invalidated**
/// — which in the real daemon runs `HelperListenerDelegate`'s `tearDownOnce`
/// and ends the caller's `clientBound` sessions. A capability probe would
/// therefore cost a user their session on precisely the old daemon it was
/// meant to detect.
///
/// A version comparison would be free of that, but it is not reliable here:
/// this project ships one `MARKETING_VERSION` for every build and moves
/// `CURRENT_PROJECT_VERSION` only in `just bump` (a `notarize` dependency), so
/// two builds of different vintages routinely report the same string — and a
/// daemon predating Plan 7 Task 10 answers with a bare short version, which
/// orders against nothing.
///
/// The read-back uses `listSessions`, which every daemon since the first
/// version implements, and it answers the question that actually matters —
/// "is the session running the way I asked?" — rather than the proxy question
/// "is the daemon new enough?". It generalises for free: any future axis added
/// to `Session` is covered the moment it is added to `Axis` below.
///
/// It is a **detection, not a prevention**. There is no prevention available:
/// see `Session.init(from:)`'s comment for why making the request undecodable
/// to an old daemon cannot be scoped to the sessions that need it.
enum SessionPowerSkew {
    /// One axis of `PowerRequest`, named so a message can say which was lost.
    ///
    /// `CaseIterable` is load-bearing: `unmetAxes` iterates it, so a third axis
    /// added to `PowerRequest` is covered by adding one case here, and the
    /// `switch` in `describes` will not compile until its phrase is written.
    enum Axis: CaseIterable, Equatable {
        case wakeMode
        case keepsDisksAwake

        /// Whether this axis differs between the two requests.
        func differs(_ requested: PowerRequest, _ admitted: PowerRequest) -> Bool {
            switch self {
            case .wakeMode: return requested.wakeMode != admitted.wakeMode
            case .keepsDisksAwake: return requested.keepsDisksAwake != admitted.keepsDisksAwake
            }
        }

        /// How the message names this axis. Phrased as what the user chose, not
        /// as the field name: nobody picked "keepsDisksAwake".
        var describes: String {
            switch self {
            case .wakeMode: return "how it keeps this Mac awake"
            case .keepsDisksAwake: return "keeping attached disks awake"
            }
        }
    }

    /// The axes the daemon did not carry across, in `Axis.allCases` order.
    ///
    /// A plain inequality, in both directions, and deliberately not "requested
    /// something the admission lacks". The daemon does not *rewrite* either
    /// axis — `Session.authorized(id:owner:ownerUID:startedAt:)` copies both
    /// straight through, and `SessionAdmission` admits or rejects rather than
    /// editing — so any difference at all is the wire losing something, whichever
    /// way it points. An old daemon loses `wakeMode` *upwards* (absent decodes
    /// as `.clamshell`, the strongest) and `keepsDisksAwake` *downwards* (absent
    /// decodes as `false`), and a check written only for the weakening direction
    /// would miss half of it.
    ///
    /// No defaulted parameter, on `Session.init`'s rule: a caller that supplies
    /// one side and forgets the other is the failure this is here to catch.
    static func unmetAxes(requested: PowerRequest, admitted: PowerRequest) -> [Axis] {
        Axis.allCases.filter { $0.differs(requested, admitted) }
    }

    /// The sentence to show, or `nil` when the request survived intact —
    /// which is the overwhelmingly common case and must say nothing at all.
    ///
    /// It leads with the session still running, because it is: this is a
    /// weaker-or-stronger-than-asked session, not a failure, and a message that
    /// opened with the problem would read as "your session did not start". The
    /// remedy is the same one `daemonDiagnosticsSentence` gives for a version
    /// mismatch, and for the same reason — a restart is what replaces a daemon
    /// left running by the copy of the app that was overwritten.
    static func note(requested: PowerRequest, admitted: PowerRequest) -> String? {
        let unmet = unmetAxes(requested: requested, admitted: admitted)
        guard !unmet.isEmpty else { return nil }
        let phrases = unmet.map(\.describes)
        // "a and b" rather than a serial list: there are exactly two axes, and
        // a comma-joined list of two reads as a truncated one.
        let listed = phrases.count == 1 ? phrases[0] : phrases.joined(separator: " and ")
        return "This session is running, but the background service ignored \(listed). "
            + "It's an older build than this app — restarting this Mac starts the new one."
    }
}
