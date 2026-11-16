import AppKit

final class UntitledHelper: NSObject, UntitledHelperProtocol {
    func currentPlayback(reply: @escaping @Sendable (Data?) -> Void) {
        guard let application = UntitledAccessibility.runningApplication,
              let playback = UntitledAccessibility.read(pid: application.processIdentifier) else {
            reply(nil)
            return
        }
        reply(try? JSONEncoder().encode(playback))
    }

    func diagnostics(header: String, reply: @escaping @Sendable (String) -> Void) {
        reply(UntitledAccessibility.diagnostics(header: header + "\nRead by: scrap's [untitled] helper"))
    }
}

final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: UntitledHelperProtocol.self)
        connection.exportedObject = UntitledHelper()
        connection.resume()
        return true
    }
}

let delegate = HelperDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
