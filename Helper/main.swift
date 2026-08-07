import Foundation

let runtime = DaemonRuntime()
runtime.start()

// Two Mach services, two listeners: role is established structurally by
// which service a peer connects to, rather than derived after acceptance
// from the peer's pid (TOCTOU-prone — a pid can be recycled between accept
// and lookup). Both listeners set their code-signing requirement before
// `resume()`, exactly as before.

let generalDelegate = HelperListenerDelegate(runtime: runtime, isAgent: false)
let generalListener = NSXPCListener(machServiceName: helperMachServiceName)
generalListener.delegate = generalDelegate
generalListener.resume()

let agentDelegate = HelperListenerDelegate(runtime: runtime, isAgent: true)
let agentListener = NSXPCListener(machServiceName: agentMachServiceName)
agentListener.delegate = agentDelegate
agentListener.resume()

RunLoop.main.run()
