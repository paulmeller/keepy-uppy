import Foundation

/// Code-signing requirement pinning both ends of the XPC connection.
///
/// The code-signing requirement grammar has no prefix/wildcard operator for
/// `identifier` — `=` is an exact match and `*` is a literal asterisk
/// (verified empirically with `codesign -R` against ad-hoc-signed binaries).
/// So each admitted binary is named explicitly instead. This also means
/// widening the boundary — admitting one more binary — is a single,
/// deliberate, reviewable line rather than a pattern someone could
/// unknowingly broaden.
enum SigningRequirement {
    /// Substituted at build time from KEEPY_UPPY_TEAM_ID (Task 10).
    static let teamID = "REPLACE_WITH_TEAM_ID"

    // MARK: - Inbound: one requirement per Mach service, one identifier each
    //
    // The daemon exposes one Mach service per client role
    // (`Shared/XPCProtocol.swift`) and each listener pins the matching
    // requirement below, so an accepted connection's role is established
    // structurally by the OS at accept time. There is deliberately no
    // "general" requirement admitting several identifiers any more: the
    // single service that used to admit all three clients was what forced
    // the daemon to invent a random per-connection `ClientID`, since arriving
    // on that service said nothing about *which* client had arrived. Three
    // single-identifier services are strictly tighter than that shape, not
    // looser — every service now admits exactly one binary.
    //
    // The daemon's own identifier is deliberately absent from all three: the
    // daemon never connects to itself, so admitting it inbound would only
    // widen the boundary with no legitimate caller to justify it. It appears
    // only in `helperRequirement`, which is the *outbound* constant clients
    // pin the daemon peer with.

    /// The menu-bar app's bundle identifier.
    static let appIdentifier = "au.com.workwireless.keepy-uppy"

    /// The agent's bundle identifier.
    static let agentIdentifier = "au.com.workwireless.keepy-uppy.agent"

    /// The `keepy-uppy` CLI's bundle identifier.
    static let cliIdentifier = "au.com.workwireless.keepy-uppy.cli"

    /// The `anchor apple generic` + Team ID clauses shared by every
    /// requirement string below, factored out once so all four are built
    /// from the same pieces and cannot drift apart from each other.
    private static let anchorAndTeam =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""

    // HISTORICAL NOTE, deliberately kept — it cost real debugging effort and
    // anyone adding an OR-group here must know it. `and` binds tighter than
    // `or` in the code-signing requirement grammar, so an unparenthesised
    // "... and identifier = A or identifier = B" parses as
    // "(... and A) or (B)" — admitting anything claiming identifier B with
    // no Team ID check at all, i.e. a privilege-escalation path into a root
    // daemon. Any multi-identifier group MUST be wrapped in parentheses.
    //
    // As of the three-service split, no live string in this file contains an
    // `or` at all: every requirement below pins exactly one identifier, so
    // the hazard cannot currently be tripped. The rule is recorded because
    // the moment someone widens one of these to admit a second identifier,
    // it applies again immediately.

    /// Pins the app-only Mach service (`helperMachServiceName`) to the
    /// menu-bar app's bundle identifier alone.
    static let appRequirement =
        anchorAndTeam + " and identifier = \"\(appIdentifier)\""

    /// Pins the agent-only Mach service (`agentMachServiceName`) to the
    /// agent's bundle identifier alone, so a connection accepted there can
    /// only ever be the agent binary.
    static let agentRequirement =
        anchorAndTeam + " and identifier = \"\(agentIdentifier)\""

    /// Pins the CLI-only Mach service (`cliMachServiceName`) to the
    /// `keepy-uppy` binary's bundle identifier alone.
    static let cliRequirement =
        anchorAndTeam + " and identifier = \"\(cliIdentifier)\""

    // MARK: - Outbound: what clients pin the daemon with

    /// The daemon's own bundle identifier, named once for the same reason
    /// the three client identifiers are: so it and `helperRequirement` below
    /// cannot drift apart. Deliberately absent from every inbound
    /// requirement — see the MARK comment above.
    static let helperIdentifier = "au.com.workwireless.keepy-uppy.helper"

    /// Pins the daemon's own identity. This is what the app, CLI, and agent
    /// each pass to `setCodeSigningRequirement` on their outbound
    /// connection: that call validates the **peer**, never the caller's own
    /// identity, so a client must pin a requirement describing the *daemon*.
    /// Spec §4 requires both ends of every connection to pin a requirement
    /// before `resume()`; this is the clients' end. Built from the same
    /// `anchorAndTeam` clause as the inbound requirements above so all four
    /// cannot drift apart. Deliberately distinct from them, and must stay
    /// so: pinning an inbound requirement client-side rejects the daemon on
    /// the first real message (verified with `codesign -R` against a real
    /// `KeepyUppyHelper` binary — see `SigningRequirementIdentifierTests`).
    static let helperRequirement =
        anchorAndTeam + " and identifier = \"\(helperIdentifier)\""

    /// Ad-hoc builds have no Team ID, so the requirement cannot be satisfied
    /// locally. Enforcement is therefore compiled out in DEBUG — loudly.
    /// A build that silently skipped verification would be far worse than one
    /// that refuses to run.
    static var isEnforced: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }
}

/// Gates whether an *unenforced* (DEBUG) daemon accepts XPC connections at
/// all (security review batch B, Fix 5). Logging that enforcement is
/// disabled and then accepting the connection anyway means any
/// unprivileged local process can drive a root daemon's power state for as
/// long as a Debug build happens to be registered — the exact failure mode
/// `SigningRequirement.isEnforced`'s doc comment says must never happen
/// silently. Pulled out as a pure, dependency-injectable predicate so the
/// "must never be on by accident" property is unit tested directly,
/// without standing up a real XPC connection.
enum InsecureDebugGate {
    static let environmentKey = "KEEPY_UPPY_INSECURE_XPC"

    /// True only when the daemon's own environment has this set to exactly
    /// "1" — not merely present, not "true"/"yes"/anything else — so a
    /// stray or truthy-but-wrong value can never accidentally opt in.
    static func isExplicitlyOptedIn(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[environmentKey] == "1"
    }
}
