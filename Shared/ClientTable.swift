import Foundation

/// Tracks which connected clients want the Mac kept awake.
/// The desired system state is simply "any client wants it", so losing a
/// client — by disconnect, crash, or termination — restores sleep on its own.
struct ClientTable<ID: Hashable> {
    private var wants: [ID: Bool] = [:]

    var desiredKeepAwake: Bool { wants.values.contains(true) }
    var clientCount: Int { wants.count }

    mutating func set(_ id: ID, wantsAwake: Bool) {
        wants[id] = wantsAwake
    }

    mutating func remove(_ id: ID) {
        wants.removeValue(forKey: id)
    }
}
