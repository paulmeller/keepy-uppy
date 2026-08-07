import Foundation
import Security

/// Resolves the code-signing identity of an XPC peer process, so the agent
/// role is derived from something the OS attests to — never from anything
/// the client asserts about itself (spec §4: "Bundle identifiers distinguish
/// role, not authorisation").
enum PeerIdentity {
    /// Bundle identifier the agent is signed with (spec §3).
    static let agentBundleIdentifier = "au.com.workwireless.keepy-uppy.agent"

    /// The signing identifier (bundle id) of the process on the other end of
    /// `connection`, resolved from its pid via `SecCode`. `nil` if it cannot
    /// be resolved (no code signature, or the process has already exited).
    static func signingIdentifier(of connection: NSXPCConnection) -> String? {
        var guestCode: SecCode?
        let attributes = [kSecGuestAttributePid as String: connection.processIdentifier] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guestCode) == errSecSuccess,
              let guestCode else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guestCode, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return nil }

        return info[kSecCodeInfoIdentifier as String] as? String
    }

    /// Whether `connection`'s peer is the agent, derived from its signing
    /// identity — never from anything the client asserts about itself.
    ///
    /// In DEBUG, signature verification is compiled out entirely (ad-hoc
    /// builds have no stable Team ID to check — see `SigningRequirement`),
    /// so there is no trustworthy identity to derive a role from at all.
    /// Rather than silently trusting every peer as a non-agent (which would
    /// make agent-only development impossible) or as *the* agent (which
    /// would make role enforcement look like it works when it doesn't), this
    /// treats every connection as the agent and logs loudly on every one: a
    /// build that silently downgraded role enforcement would be far worse
    /// than one that is visibly, noisily permissive.
    static func isAgent(_ connection: NSXPCConnection) -> Bool {
        #if DEBUG
        helperLogger.error(
            "⚠️ DEBUG BUILD: agent role NOT verified from peer signing identity; every XPC client is treated as the agent. This build must never be distributed.")
        return true
        #else
        return signingIdentifier(of: connection) == agentBundleIdentifier
        #endif
    }
}
