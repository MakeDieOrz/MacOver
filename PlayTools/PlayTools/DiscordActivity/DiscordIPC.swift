//
//  DiscordIPC.swift
//  PlayTools
//
//  Created by 이승윤 on 2022/07/15.
//

import Darwin
import Foundation
import Synchronization

struct DiscordTimestamps: Encodable {
    var start: Int?

    enum CodingKeys: String, CodingKey {
        case start
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(start, forKey: .start)
    }
}

struct DiscordAssets: Encodable {
    var largeImage: String?
    var largeText: String?
    var smallImage: String?
    var smallText: String?

    enum CodingKeys: String, CodingKey {
        case largeImage = "large_image"
        case largeText = "large_text"
        case smallImage = "small_image"
        case smallText = "small_text"
    }
}

struct DiscordButton: Encodable {
    let label: String
    let url: String
}

struct DiscordRichPresence: Encodable {
    typealias Timestamps = DiscordTimestamps
    typealias Assets = DiscordAssets
    typealias Button = DiscordButton

    var details: String?
    var state: String?
    var timestamps = Timestamps()
    var assets = Assets()
    var buttons: [Button] = []

    enum CodingKeys: String, CodingKey {
        case details, state, timestamps, assets, buttons
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(details, forKey: .details)
        try container.encodeIfPresent(state, forKey: .state)
        if timestamps.start != nil {
            try container.encode(timestamps, forKey: .timestamps)
        }
        try container.encode(assets, forKey: .assets)
        if !buttons.isEmpty {
            try container.encode(buttons, forKey: .buttons)
        }
    }
}

private struct DiscordSetActivityArgs: Encodable {
    let pid: Int32
    let activity: DiscordRichPresence?

    enum CodingKeys: String, CodingKey {
        case pid, activity
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pid, forKey: .pid)
        try container.encode(activity, forKey: .activity)
    }
}

private struct DiscordSetActivityCommand: Encodable {
    let cmd = "SET_ACTIVITY"
    let args: DiscordSetActivityArgs
    let nonce: String
}

final class DiscordIPCClient: Sendable {
    enum Opcode: UInt32 {
        case handshake = 0
        case frame = 1
        case close = 2
        case ping = 3
        case pong = 4
    }

    private struct HandshakePayload: Encodable {
        let v = 1
        let client_id: String
    }

    private typealias SetActivityCommand = DiscordSetActivityCommand

    private let appId: String
    private let socketPaths: [String]
    private let lock = PTUnfairLock()
    private let ioLock = PTUnfairLock()
    private let readQueue = DispatchQueue(label: "com.apple.ipc.transport.read", qos: .utility)
    nonisolated(unsafe) private var fd: Int32 = -1
    nonisolated(unsafe) private var readSource: DispatchSourceRead?

    init(appId: String, socketPaths: [String]? = nil) {
        self.appId = appId
        self.socketPaths = socketPaths ?? Self.candidateSocketPaths()
    }

    deinit {
        disconnect()
    }

    @discardableResult
    func connect() -> Bool {
        let alreadyOpen = lock.withLock { fd >= 0 }
        if alreadyOpen { return true }

        guard !appId.isEmpty else { return false }
        let encoder = JSONEncoder()
        guard let handshakeData = try? encoder.encode(HandshakePayload(client_id: appId)) else {
            return false
        }

        for path in socketPaths {
            guard Self.isUnixSocket(at: path) else { continue }
            guard let connectedFD = Self.openUnixSocket(at: path) else { continue }

            guard Self.writeFrame(fd: connectedFD, opcode: .handshake, payload: handshakeData),
                  Self.completeHandshake(fd: connectedFD) else {
                Darwin.close(connectedFD)
                continue
            }

            // Bound subsequent DispatchSourceRead recv waits so partial frames cannot stall readQueue for 2s.
            var readTimeout = timeval(tv_sec: 0, tv_usec: 250_000)
            _ = Darwin.setsockopt(
                connectedFD,
                SOL_SOCKET,
                SO_RCVTIMEO,
                &readTimeout,
                socklen_t(MemoryLayout<timeval>.size)
            )

            let source = DispatchSource.makeReadSource(fileDescriptor: connectedFD, queue: readQueue)
            let socketIOLock = self.ioLock
            source.setEventHandler { [weak self] in
                guard let self else { return }
                guard let frame = Self.readFrame(fd: connectedFD) else {
                    self.disconnect()
                    return
                }
                if frame.opcode == .ping {
                    socketIOLock.withLock {
                        let activeFD = self.lock.withLock { self.fd }
                        guard activeFD == connectedFD else { return }
                        _ = Self.writeFrame(fd: connectedFD, opcode: .pong, payload: frame.payload)
                    }
                } else if frame.opcode == .close {
                    self.disconnect()
                }
            }
            source.setCancelHandler {
                socketIOLock.withLock {
                    _ = Darwin.close(connectedFD)
                }
            }

            let wonRace = lock.withLock { () -> Bool in
                guard fd < 0 else { return false }
                fd = connectedFD
                readSource = source
                return true
            }
            guard wonRace else {
                source.setEventHandler {}
                source.resume()
                source.cancel()
                return true
            }
            source.resume()
            return true
        }
        return false
    }

    func setPresence(_ presence: DiscordRichPresence) {
        let cmd = SetActivityCommand(
            args: .init(pid: Darwin.getpid(), activity: presence),
            nonce: UUID().uuidString
        )
        sendCommand(cmd)
    }

    func clearPresence() {
        let cmd = SetActivityCommand(
            args: .init(pid: Darwin.getpid(), activity: nil),
            nonce: UUID().uuidString
        )
        sendCommand(cmd)
    }

    func disconnect() {
        var sourceToCancel: DispatchSourceRead?
        ioLock.withLock {
            let (activeFD, source) = lock.withLock { () -> (Int32, DispatchSourceRead?) in
                let activeFD = fd
                let source = readSource
                fd = -1
                readSource = nil
                return (activeFD, source)
            }
            sourceToCancel = source

            if activeFD >= 0 {
                _ = Self.writeFrame(fd: activeFD, opcode: .close, payload: Data(), nonBlocking: true)
                if source == nil {
                    Darwin.close(activeFD)
                }
            }
        }
        sourceToCancel?.cancel()
    }

    private func sendCommand(_ command: SetActivityCommand) {
        guard let data = try? JSONEncoder().encode(command) else { return }
        let sendFailed = ioLock.withLock { () -> Bool in
            let activeFD = lock.withLock { fd }
            guard activeFD >= 0 else { return false }
            return !Self.writeFrame(fd: activeFD, opcode: .frame, payload: data)
        }
        if sendFailed {
            disconnect()
        }
    }

    static func candidateSocketPaths(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var dirs: [String] = [FileManager.default.temporaryDirectory.path]
        for key in ["TMPDIR", "XDG_RUNTIME_DIR", "TMP", "TEMP"] {
            if let val = environment[key], !val.isEmpty {
                dirs.append(val)
            }
        }
        dirs.append("/tmp")

        var seen = Set<String>()
        var paths: [String] = []
        for rawDir in dirs {
            let cleanDir = rawDir.hasSuffix("/") ? String(rawDir.dropLast()) : rawDir
            guard !cleanDir.isEmpty, seen.insert(cleanDir).inserted else { continue }
            for idx in 0..<10 {
                paths.append("\(cleanDir)/discord-ipc-\(idx)")
            }
        }
        return paths
    }

    static func hasLiveDiscordSocket(paths: [String]? = nil) -> Bool {
        for path in paths ?? candidateSocketPaths() {
            guard isUnixSocket(at: path) else { continue }
            if let fd = openUnixSocket(at: path) {
                Darwin.close(fd)
                return true
            }
        }
        return false
    }

    private static func isUnixSocket(at path: String) -> Bool {
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0 else {
            return false
        }
        guard (st.st_mode & S_IFMT) == S_IFSOCK else {
            return false
        }
        return st.st_uid == Darwin.geteuid()
    }

    private static func completeHandshake(fd: Int32) -> Bool {
        for _ in 0..<4 {
            guard let reply = readFrame(fd: fd) else { return false }
            switch reply.opcode {
            case .frame:
                return true
            case .ping:
                guard writeFrame(fd: fd, opcode: .pong, payload: reply.payload) else { return false }
            default:
                return false
            }
        }
        return false
    }

    private static func openUnixSocket(at path: String) -> Int32? {
        guard isUnixSocket(at: path) else { return nil }
        var addr = sockaddr_un()
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = path.utf8CString
        guard utf8.count > 0, utf8.count <= maxPathLen,
              let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) else {
            return nil
        }

        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }

        var noSigPipe: Int32 = 1
        _ = Darwin.setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        _ = Darwin.setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = Darwin.setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            utf8.withUnsafeBytes { src in
                buf.copyMemory(from: src)
            }
        }
        let addrLen = socklen_t(pathOffset + utf8.count)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(sock, $0, addrLen) }
        }
        guard rc == 0 else {
            Darwin.close(sock)
            return nil
        }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard Darwin.getpeereid(sock, &peerUID, &peerGID) == 0,
              peerUID == Darwin.geteuid() else {
            Darwin.close(sock)
            return nil
        }
        return sock
    }

    @discardableResult
    static func writeFrame(
        fd: Int32,
        opcode: Opcode,
        payload: Data,
        nonBlocking: Bool = false
    ) -> Bool {
        var header = Data(capacity: 8 + payload.count)
        var opLE = opcode.rawValue.littleEndian
        var lenLE = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &opLE) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &lenLE) { header.append(contentsOf: $0) }
        header.append(payload)

        let sendFlags: Int32 = nonBlocking ? Int32(MSG_DONTWAIT) : 0
        return header.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return true }
            var sent = 0
            while sent < rawBuf.count {
                let n = Darwin.send(fd, base.advanced(by: sent), rawBuf.count - sent, sendFlags)
                if n > 0 {
                    sent += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    static func readFrame(fd: Int32) -> (opcode: Opcode, payload: Data)? {
        guard let head = readExact(fd: fd, count: 8) else { return nil }
        let rawOp: UInt32 = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        let rawLen: UInt32 = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        let opVal = UInt32(littleEndian: rawOp)
        let len = Int(UInt32(littleEndian: rawLen))
        guard let opcode = Opcode(rawValue: opVal), len >= 0, len <= 1_048_576 else { return nil }
        guard len > 0 else { return (opcode, Data()) }
        guard let payload = readExact(fd: fd, count: len) else { return nil }
        return (opcode, payload)
    }

    private static func readExact(fd: Int32, count: Int) -> Data? {
        var buf = Data(count: count)
        let ok = buf.withUnsafeMutableBytes { rawBuf -> Bool in
            guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return false }
            var offset = 0
            while offset < count {
                let n = Darwin.recv(fd, base.advanced(by: offset), count - offset, 0)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        return ok ? buf : nil
    }
}

final class DiscordIPC: Sendable {
    public static let shared = DiscordIPC()

    private let rpcState = Mutex<DiscordIPCClient?>(nil)
    private let observerLock = PTUnfairLock()
    nonisolated(unsafe) private var termObserver: NSObjectProtocol?
    private static let defaultAppID = ""

    func initialize() {
        guard !PTSafeMode.isActive,
              !PlaySettings.shared.strictEmulationMode,
              !PlaySettings.shared.bypass else {
            return
        }
        let custom = PlaySettings.shared.discordActivity
        guard custom.enable else { return }

        let appId = custom.applicationID.isEmpty ? Self.defaultAppID : custom.applicationID
        guard !appId.isEmpty else { return }
        let details = custom.details
        let state = custom.state
        let image = custom.image

        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            guard DiscordIPCClient.hasLiveDiscordSocket() else { return }

            let activity = await self.createActivity(details: details, state: state, image: image)
            guard DiscordIPCClient.hasLiveDiscordSocket() else { return }

            let ipc = DiscordIPCClient(appId: appId)
            guard ipc.connect() else { return }
            ipc.setPresence(activity)
            self.setActiveRPC(ipc)
        }
    }

    private func setActiveRPC(_ ipc: DiscordIPCClient) {
        rpcState.withLock { $0 = ipc }
        observerLock.withLock {
            guard termObserver == nil else { return }
            termObserver = NotificationCenter.default.addObserver(
                forName: NSNotification.Name(rawValue: "NSApplicationWillTerminateNotification"),
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.shutdown()
            }
        }
    }

    func shutdown() {
        let activeRPC = rpcState.withLock { rpc -> DiscordIPCClient? in
            let current = rpc
            rpc = nil
            return current
        }
        observerLock.withLock {
            if let observer = termObserver {
                NotificationCenter.default.removeObserver(observer)
                termObserver = nil
            }
        }
        guard let activeRPC else { return }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            activeRPC.clearPresence()
            activeRPC.disconnect()
            finished.signal()
        }
        if finished.wait(timeout: .now() + 0.25) == .timedOut {
            activeRPC.disconnect()
        }
    }

    func createActivity(details: String, state: String, image: String) async -> DiscordRichPresence {
        var activity = DiscordRichPresence()

        if details.isEmpty {
            let name = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? ""
            let displayName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? name
            activity.details = "Playing \(displayName)"
        } else {
            activity.details = details.count == 1 ? "\(details) " : details
        }

        let poweredStr = "Powered by MacOver"
        if state.isEmpty {
            activity.state = poweredStr
        } else {
            activity.state = state.count == 1 ? "\(state) " : state
            activity.assets.smallText = poweredStr
            activity.assets.largeText = poweredStr
        }

        let logo = "https://raw.githubusercontent.com/MakeDieOrz/MacOver/master/images/logo.png"
        if image.isEmpty {
            let bundleID = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? ""
            if let appImage = await loadImage(bundleID: bundleID) {
                activity.assets.largeImage = appImage
                activity.assets.largeText = nil
                activity.assets.smallImage = logo
            } else {
                activity.assets.largeImage = logo
            }
        } else {
            activity.assets.largeImage = image
            activity.assets.largeText = nil
            activity.assets.smallImage = logo
        }

        activity.timestamps.start = Int(Date().timeIntervalSince1970)
        activity.buttons = [
            DiscordRichPresence.Button(
                label: "Download MacOver",
                url: "https://github.com/MakeDieOrz/MacOver/releases"
            )
        ]
        return activity
    }

    func loadImage(bundleID: String) async -> String? {
        guard !bundleID.isEmpty,
              let encoded = bundleID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(encoded)") else {
            return nil
        }

        do {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = []
            config.timeoutIntervalForRequest = 5
            config.timeoutIntervalForResource = 5
            let session = URLSession(configuration: config)
            defer { session.finishTasksAndInvalidate() }
            let (data, _) = try await session.data(for: URLRequest(url: url))
            let jsonResult = try JSONDecoder().decode(ITunesResponse.self, from: data)
            if jsonResult.resultCount > 0, let first = jsonResult.results.first {
                return first.artworkUrl512 ?? first.artworkUrl100
            }
            return nil
        } catch {
            return nil
        }
    }
}

struct ITunesResult: Decodable {
    var artworkUrl512: String?
    var artworkUrl100: String?
}

struct ITunesResponse: Decodable {
    var resultCount: Int
    var results: [ITunesResult]
}
