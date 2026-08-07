import Foundation

/// Who a peer is, established structurally by *which of the daemon's three
/// Mach services accepted its connection* (`Helper/main.swift` stands up one
/// `NSXPCListener` per case; `Shared/XPCProtocol.swift` names the services).
///
/// Each service pins a code-signing requirement admitting exactly one bundle
/// identifier, so arriving on a service *is* proof of being that binary —
/// enforced by the OS atomically at accept time, with no lookup to race. This
/// is the same reasoning that already governed agent-ness (the old
/// `PeerIdentity.isAgent(_:)` re-derived it from the peer's pid after accept,
/// which is TOCTOU-prone: a pid can be recycled between accept and lookup).
/// Role is never asserted by the client and never re-derived after the fact.
enum ClientRole: String, CaseIterable {
    case app
    case agent
    case cli

    /// The service a listener for this role must be created on. Kept here,
    /// rather than left implicit in `Helper/main.swift`, so the
    /// service ↔ role ↔ requirement mapping is one table in one place and
    /// cannot half-drift.
    var machServiceName: String {
        switch self {
        case .app: return helperMachServiceName
        case .agent: return agentMachServiceName
        case .cli: return cliMachServiceName
        }
    }

    /// The *inbound* requirement the listener for this role pins on its
    /// peers — one identifier each, never the OR-list of all three that the
    /// single general service used to carry. Not to be confused with
    /// `SigningRequirement.helperRequirement`, which is what clients pin the
    /// daemon (the peer at the other end) with.
    var inboundSigningRequirement: String {
        switch self {
        case .app: return SigningRequirement.appRequirement
        case .agent: return SigningRequirement.agentRequirement
        case .cli: return SigningRequirement.cliRequirement
        }
    }

    /// Only the agent may report condition observations or register as the
    /// user-session observer (`HelperService.reportConditionEnded` /
    /// `registerAsAgent`). Spelled once here so that authorization keeps
    /// meaning exactly "arrived on the agent-only Mach service".
    var isAgent: Bool { self == .agent }

    /// The caller's session-ownership identity: **stable** across
    /// invocations, **server-derived**, and **unforgeable**.
    ///
    /// Both inputs are facts the daemon establishes itself and a client
    /// cannot influence: the role comes from which listener accepted the
    /// connection (above), and `userID` comes from
    /// `NSXPCConnection.effectiveUserIdentifier`, which XPC fills in from the
    /// peer's audit credentials. Nothing here is self-declared — a client
    /// *does* put an `owner` in its `startSession` payload, but
    /// `HelperService.startSession` overwrites it with this value and always
    /// has.
    ///
    /// Why it must be stable: every isolation guarantee (Task 10) is a
    /// comparison against `Session.owner`, and the daemon used to mint
    /// `ClientID(rawValue: UUID().uuidString)` per accepted connection. A
    /// fresh identity per connection meant a second `keepy-uppy` invocation
    /// could never match the first's sessions, so `keepy-uppy off` with no
    /// flags — the documented primary workflow — silently ended nothing and
    /// still exited 0. It also made `SessionAdmission.maxSessionsPerOwner`
    /// close to decorative, since reconnecting produced a brand-new owner
    /// with a fresh allowance.
    ///
    /// Why isolation is not weakened by making it stable: the two components
    /// are exactly the two boundaries that must be kept apart. Different
    /// roles get different ids, so the CLI still cannot stop the menu-bar
    /// app's sessions (or the agent's) with a scoped `off`; different uids
    /// get different ids, so one user on a multi-user Mac still cannot touch
    /// another's.
    func clientID(forUserID userID: UInt32) -> ClientID {
        ClientID(rawValue: "\(rawValue)-\(userID)")
    }
}
