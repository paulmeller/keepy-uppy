import Foundation
import os

/// Code-signing requirement pinning both ends of the XPC connection.
///
/// Scoped to our Team ID plus a bundle-identifier prefix (spec §5) so the app,
/// the CLI, and any future companion are admitted — all of which still require
/// our signing key. Widening a boundary later is where mistakes get made.
enum SigningRequirement {
    /// Substituted at build time from KEEPY_UPPY_TEAM_ID (Task 10).
    static let teamID = "REPLACE_WITH_TEAM_ID"

    static let requirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" "
        + "and identifier = \"au.com.workwireless.keepy-uppy*\""

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
