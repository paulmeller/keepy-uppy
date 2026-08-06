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

    /// Every binary permitted to talk to the daemon, named explicitly.
    static let identifiers = [
        "au.com.workwireless.keepy-uppy",
        "au.com.workwireless.keepy-uppy.helper",
        "au.com.workwireless.keepy-uppy.agent",
        "au.com.workwireless.keepy-uppy.cli",
    ]

    // NOTE: the identifier group MUST stay parenthesised. `and` binds
    // tighter than `or` in this grammar, so an unparenthesised
    // "... and identifier = A or identifier = B" parses as
    // "(... and A) or (B)" — admitting anything claiming identifier B with
    // no Team ID check at all. That is a privilege-escalation hole into a
    // root daemon.
    static let requirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and ("
        + identifiers.map { "identifier = \"\($0)\"" }.joined(separator: " or ")
        + ")"

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
