import Foundation

/// Minimal client for the local Discord RPC socket (`discord-ipc-N` in the user's temp folder).
/// Frames are a little-endian opcode and length followed by a JSON payload.
nonisolated final class DiscordIPCConnection: @unchecked Sendable {
    enum Opcode: UInt32 { case handshake = 0, frame = 1, close = 2, ping = 3, pong = 4 }

    enum Event {
        case ready(username: String?)
        case closed(reason: String?)
        case error(code: Int?, message: String)
    }

    /// Called on the main actor. Set once, before connecting.
    var onEvent: (@MainActor (Event) -> Void)?
    private let queue = DispatchQueue(label: "scrap.discord-ipc")
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var buffer = Data()

    deinit { if socketFD >= 0 { Darwin.close(socketFD) } }

    func connect(clientID: String) {
        queue.async { [self] in
            guard socketFD < 0 else { return }
            for path in Self.socketPaths() {
                let fd = Self.openSocket(at: path)
                guard fd >= 0 else { continue }
                socketFD = fd
                buffer.removeAll()
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self] in self?.readAvailable() }
                readSource = source
                source.resume()
                write(.handshake, ["v": 1, "client_id": clientID])
                return
            }
            emit(.closed(reason: nil))
        }
    }

    func setActivity(_ activity: [String: Any]?) {
        var args: [String: Any] = ["pid": Int(getpid())]
        if let activity { args["activity"] = activity }
        let payload: [String: Any] = ["cmd": "SET_ACTIVITY", "args": args, "nonce": UUID().uuidString]
        queue.async { [self] in
            guard socketFD >= 0 else { return }
            write(.frame, payload)
        }
    }

    func disconnect() {
        queue.async { [self] in teardown(reason: nil, notify: false) }
    }

    // MARK: - Framing

    static func encode(_ opcode: Opcode, _ payload: [String: Any]) -> Data? {
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var data = Data(capacity: 8 + json.count)
        withUnsafeBytes(of: opcode.rawValue.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(json)
        return data
    }

    /// Removes and returns every complete frame at the start of `buffer`.
    static func decodeFrames(_ buffer: inout Data) -> [(opcode: UInt32, payload: [String: Any])] {
        var frames: [(UInt32, [String: Any])] = []
        while buffer.count >= 8 {
            let header = [UInt8](buffer.prefix(8))
            let opcode = header[0..<4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
            let length = Int(header[4..<8].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) })
            guard buffer.count >= 8 + length else { break }
            let body = buffer.subdata(in: buffer.startIndex + 8 ..< buffer.startIndex + 8 + length)
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 8 + length)
            frames.append((opcode, (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]))
        }
        return frames
    }

    private func write(_ opcode: Opcode, _ payload: [String: Any]) {
        guard let data = Self.encode(opcode, payload) else { return }
        let ok = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.send(socketFD, raw.baseAddress! + offset, raw.count - offset, 0)
                if sent < 0 { if errno == EINTR { continue }; return false }
                offset += sent
            }
            return true
        }
        if !ok { teardown(reason: "Lost connection to Discord.", notify: true) }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let count = Darwin.recv(socketFD, &chunk, chunk.count, 0)
        guard count > 0 else {
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            teardown(reason: nil, notify: true)
            return
        }
        buffer.append(contentsOf: chunk[0..<count])
        for frame in Self.decodeFrames(&buffer) {
            switch Opcode(rawValue: frame.opcode) {
            case .frame:
                handle(frame.payload)
            case .ping:
                write(.pong, frame.payload)
            case .close:
                teardown(reason: frame.payload["message"] as? String, notify: true)
                return
            default:
                break
            }
        }
    }

    private func handle(_ payload: [String: Any]) {
        let data = payload["data"] as? [String: Any]
        if payload["evt"] as? String == "READY" {
            let user = data?["user"] as? [String: Any]
            let name = (user?["global_name"] as? String) ?? (user?["username"] as? String)
            emit(.ready(username: name))
        } else if payload["evt"] as? String == "ERROR" {
            emit(.error(code: data?["code"] as? Int, message: data?["message"] as? String ?? "Discord rejected the activity."))
        }
    }

    private func teardown(reason: String?, notify: Bool) {
        readSource?.cancel()
        readSource = nil
        if socketFD >= 0 { Darwin.close(socketFD) }
        socketFD = -1
        buffer.removeAll()
        if notify { emit(.closed(reason: reason)) }
    }

    private func emit(_ event: Event) {
        guard let handler = onEvent else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { handler(event) } }
    }

    // MARK: - Socket discovery

    /// scrap is sandboxed, so `TMPDIR` points inside its container. Discord's socket lives in the
    /// real per-user temp folder under /private/var/folders, which the sandbox exception lets us scan.
    static func socketPaths() -> [String] {
        var folders: [String] = []
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"], !tmp.contains("/Library/Containers/") {
            folders.append(tmp)
        }
        let fm = FileManager.default
        let root = "/private/var/folders"
        for first in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            for second in (try? fm.contentsOfDirectory(atPath: "\(root)/\(first)")) ?? [] {
                folders.append("\(root)/\(first)/\(second)/T")
            }
        }
        var seen = Set<String>()
        var paths: [String] = []
        for folder in folders {
            let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
            for index in 0..<10 {
                let path = "\(base)/discord-ipc-\(index)"
                guard seen.insert(path).inserted,
                      let attributes = try? fm.attributesOfItem(atPath: path),
                      attributes[.type] as? FileAttributeType == .typeSocket,
                      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { continue }
                paths.append(path)
            }
        }
        return paths
    }

    private static func openSocket(at path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let fits = withUnsafeMutableBytes(of: &address.sun_path) { raw -> Bool in
            let bytes = Array(path.utf8)
            guard bytes.count < raw.count else { return false }
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
            return true
        }
        guard fits else { Darwin.close(fd); return -1 }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { Darwin.close(fd); return -1 }
        return fd
    }
}
