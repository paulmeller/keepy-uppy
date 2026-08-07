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

// The whole reason this executable exists. Without this the agent is a
// process that connects and then does nothing: `.whileAppRunning`,
// `.whileExternalDisplay` and `.whileCPUBusy` sessions never get their
// `reportConditionEnded` call when the condition actually ends (they would
// linger until the daemon's fail-safes — agent disconnect or the 8h
// backstop — rather than ending when the app quits or the display
// unplugs), and every trigger rule the Settings UI saves is dead storage
// nothing ever reads.
//
// Top-level `let` for the same reason as `connection` above: the runner
// owns the repeating `Timer` and must outlive this file's straight-line
// execution. A `Task`- or closure-scoped binding would be deallocated the
// instant the closure returned, silently taking the timer with it and
// restoring exactly the do-nothing behavior this line fixes.
let evidenceLoop = MainActor.assumeIsolated { EvidenceLoopRunner(connection: connection) }
MainActor.assumeIsolated { evidenceLoop.start() }

RunLoop.main.run()
