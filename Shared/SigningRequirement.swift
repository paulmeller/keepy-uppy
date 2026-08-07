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

    /// The agent's bundle identifier. Named once here so `identifiers` below
    /// and `agentRequirement` (which pins the dedicated agent Mach service to
    /// this identifier alone — see `agentMachServiceName`) cannot drift apart
    /// from each other.
    static let agentIdentifier = "au.com.workwireless.keepy-uppy.agent"

    /// Every binary permitted to talk to the daemon, named explicitly.
    static let identifiers = [
        "au.com.workwireless.keepy-uppy",
        "au.com.workwireless.keepy-uppy.helper",
        agentIdentifier,
        "au.com.workwireless.keepy-uppy.cli",
    ]

    /// The `anchor apple generic` + Team ID clauses shared by every
    /// requirement string below, factored out once so `requirement` and
    /// `agentRequirement` are built from the same pieces and cannot drift
    /// apart from each other.
    private static let anchorAndTeam =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""

    // NOTE: the identifier group MUST stay parenthesised. `and` binds
    // tighter than `or` in this grammar, so an unparenthesised
    // "... and identifier = A or identifier = B" parses as
    // "(... and A) or (B)" — admitting anything claiming identifier B with
    // no Team ID check at all. That is a privilege-escalation hole into a
    // root daemon.
    static let requirement =
        anchorAndTeam + " and ("
        + identifiers.map { "identifier = \"\($0)\"" }.joined(separator: " or ")
        + ")"

    /// Pins the dedicated agent Mach service (`agentMachServiceName`)
    /// exclusively to the agent's bundle identifier, so a connection
    /// accepted there can only ever be the agent binary. Built from the same
    /// `anchorAndTeam` clause as `requirement` above so the two cannot drift
    /// apart.
    ///
    /// NOTE: the same parenthesisation rule documented above still applies —
    /// `and` binds tighter than `or` in this grammar. A single identifier
    /// needs no OR-group today, but if this requirement ever grows to admit
    /// more than one identifier, that group MUST be parenthesised exactly as
    /// `requirement`'s is, for the same privilege-escalation reason.
    static let agentRequirement =
        anchorAndTeam + " and identifier = \"\(agentIdentifier)\""

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
