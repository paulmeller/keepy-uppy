import Foundation

// Top-level code in a `main.swift` tool target is a synchronous, actor-
// nonisolated context in this toolchain/language-mode combination — it is
// NOT implicitly @MainActor, even though it always runs on the main thread
// in practice (there is no other thread here yet: this file's own
// `RunLoop.main.run()` below is what starts the run loop). `assumeIsolated`
// is the documented escape hatch for exactly this situation: proving to the
// type system what is already true at runtime, without introducing a `Task`
// whose closure-local `connection` would be deallocated (and its XPC
// connection torn down) the instant the closure returns.
let connection = MainActor.assumeIsolated { DaemonConnection() }
MainActor.assumeIsolated { connection.connect() }

RunLoop.main.run()
