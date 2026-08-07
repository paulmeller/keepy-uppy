import Foundation

let runtime = DaemonRuntime()
let delegate = HelperListenerDelegate(runtime: runtime)
runtime.start()

let listener = NSXPCListener(machServiceName: helperMachServiceName)
listener.delegate = delegate
listener.resume()

RunLoop.main.run()
