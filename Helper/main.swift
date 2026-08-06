import Foundation

let delegate = HelperListenerDelegate()
delegate.startup()

let listener = NSXPCListener(machServiceName: helperMachServiceName)
listener.delegate = delegate
listener.resume()

RunLoop.main.run()
