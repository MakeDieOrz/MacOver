import Darwin
import Foundation
import Security
import Synchronization

public enum MCPTokenAuthError: LocalizedError, Sendable {
    case entropyUnavailable(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .entropyUnavailable(let status):
            return "CSPRNG failure while generating MCP token (OSStatus \(status))"
        }
    }
}

public enum MCPTokenAuth {
    public static func generateSecureHexToken(byteCount: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: max(16, byteCount))
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw MCPTokenAuthError.entropyUnavailable(status)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func generateHexToken(byteCount: Int = 32) -> String {
        if let token = try? generateSecureHexToken(byteCount: byteCount) {
            return token
        }
        var rng = SystemRandomNumberGenerator()
        let count = max(16, byteCount)
        var bytes = [UInt8](repeating: 0, count: count)
        for idx in 0..<count {
            bytes[idx] = UInt8.random(in: UInt8.min...UInt8.max, using: &rng)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for idx in a.indices {
            diff |= a[idx] ^ b[idx]
        }
        return diff == 0
    }
}

public enum MCPProcessIdentity {
    public static func bsdInfo(for pid: Int32) -> proc_bsdinfo? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let copied = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard copied >= size else { return nil }
        return info
    }

    public static func startTimeSec(for pid: Int32) -> UInt64? {
        bsdInfo(for: pid)?.pbi_start_tvsec
    }

    public static func executablePath(for pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        guard let rawPath = String(bytes: bytes, encoding: .utf8), !rawPath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path
    }

    public static func enclosingAppBundleIdentifier(forExecutablePath path: String) -> String? {
        var cursor = URL(fileURLWithPath: path).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            if cursor.pathExtension.lowercased() == "app" {
                let candidates = [
                    cursor.appendingPathComponent("Info.plist"),
                    cursor.appendingPathComponent("Contents/Info.plist")
                ]
                for plistURL in candidates {
                    if let data = try? Data(contentsOf: plistURL),
                       let plist = try? PropertyListSerialization.propertyList(
                           from: data,
                           options: [],
                           format: nil
                       ) as? [String: Any],
                       let bid = plist["CFBundleIdentifier"] as? String,
                       !bid.isEmpty {
                        return bid
                    }
                }
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path {
                break
            }
            cursor = parent
        }
        return nil
    }
}

public struct MCPDaemonSession: Equatable, Sendable, Codable {
    public let port: UInt16
    public let token: String
    public let pid: Int32
    public let version: String
    public let startedAt: Date
    public let executablePath: String?
    public let processStartTimeSec: UInt64?

    public init(
        port: UInt16,
        token: String,
        pid: Int32,
        version: String,
        startedAt: Date = Date(),
        executablePath: String? = nil,
        processStartTimeSec: UInt64? = nil
    ) {
        self.port = port
        self.token = token
        self.pid = pid
        self.version = version
        self.startedAt = startedAt
        if let executablePath {
            self.executablePath = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
        } else if pid == getpid() {
            self.executablePath = MCPProcessIdentity.executablePath(for: pid)
        } else {
            self.executablePath = nil
        }
        if let processStartTimeSec {
            self.processStartTimeSec = processStartTimeSec
        } else if pid == getpid() {
            self.processStartTimeSec = MCPProcessIdentity.startTimeSec(for: pid)
        } else {
            self.processStartTimeSec = nil
        }
    }

    public var isHostProcessAlive: Bool {
        guard pid > 0 else { return false }
        guard let info = MCPProcessIdentity.bsdInfo(for: pid) else {
            return false
        }
        guard info.pbi_uid == getuid() else {
            return false
        }
        guard let livePath = MCPProcessIdentity.executablePath(for: pid), !livePath.isEmpty else {
            return false
        }
        if let expectedPath = executablePath, !expectedPath.isEmpty {
            let canonicalExpected = URL(fileURLWithPath: expectedPath).resolvingSymlinksInPath().path
            guard livePath == canonicalExpected else {
                return false
            }
        }
        if let expectedStart = processStartTimeSec {
            guard info.pbi_start_tvsec == expectedStart else {
                return false
            }
        }
        return true
    }
}

public enum MCPDaemonSessionFileError: LocalizedError, Sendable {
    case insecurePermissions(String)
    case readFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .insecurePermissions(let detail):
            return "Insecure MCP session file permissions: \(detail)"
        case .readFailed(let detail):
            return "Failed to read MCP session file: \(detail)"
        case .writeFailed(let detail):
            return "Failed to write MCP session file: \(detail)"
        }
    }
}

public enum MCPDaemonSessionFile {
    public static let maxSessionFileBytes = 64 * 1024

    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent("app.makedie.MacOver", isDirectory: true)
            .appendingPathComponent("MCP", isDirectory: true)
            .appendingPathComponent("daemon.json")
    }

    public static func write(_ session: MCPDaemonSession, to url: URL = defaultURL()) throws {
        let dir = url.deletingLastPathComponent()
        let fileName = url.lastPathComponent
        guard !fileName.isEmpty, !fileName.contains("/"), fileName != ".", fileName != ".." else {
            throw MCPDaemonSessionFileError.writeFailed("invalid session filename")
        }

        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // Pin parent directory descriptor with O_DIRECTORY | O_NOFOLLOW to avoid lstat->chmod TOCTOU.
        let dirFD = Darwin.open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if dirFD < 0 {
            if errno == ELOOP || errno == ENOTDIR {
                throw MCPDaemonSessionFileError.insecurePermissions("session directory is a symlink or not a directory")
            }
            throw MCPDaemonSessionFileError.writeFailed(String(cString: strerror(errno)))
        }
        defer { Darwin.close(dirFD) }

        var dirStat = stat()
        guard Darwin.fstat(dirFD, &dirStat) == 0 else {
            throw MCPDaemonSessionFileError.writeFailed(String(cString: strerror(errno)))
        }
        guard (dirStat.st_mode & S_IFMT) == S_IFDIR else {
            throw MCPDaemonSessionFileError.insecurePermissions("session directory is not a real directory")
        }
        guard dirStat.st_uid == getuid() else {
            throw MCPDaemonSessionFileError.insecurePermissions("session directory owner mismatch")
        }
        guard Darwin.fchmod(dirFD, 0o700) == 0 else {
            throw MCPDaemonSessionFileError.writeFailed("fchmod 0700 failed: \(String(cString: strerror(errno)))")
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(session)
        guard data.count <= maxSessionFileBytes else {
            throw MCPDaemonSessionFileError.writeFailed("encoded session exceeds size cap")
        }

        var stagedName: String?
        var fd: Int32 = -1
        for _ in 0..<8 {
            let candidateName = ".daemon.\(UUID().uuidString).tmp"
            let opened = Darwin.openat(
                dirFD,
                candidateName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
            if opened >= 0 {
                stagedName = candidateName
                fd = opened
                break
            }
            if errno != EEXIST {
                throw MCPDaemonSessionFileError.writeFailed(String(cString: strerror(errno)))
            }
        }
        guard fd >= 0, let tmpName = stagedName else {
            throw MCPDaemonSessionFileError.writeFailed("failed to create unique temp session file")
        }

        var tmpStat = stat()
        guard Darwin.fstat(fd, &tmpStat) == 0,
              (tmpStat.st_mode & S_IFMT) == S_IFREG,
              tmpStat.st_uid == getuid() else {
            Darwin.close(fd)
            Darwin.unlinkat(dirFD, tmpName, 0)
            throw MCPDaemonSessionFileError.insecurePermissions("temporary session file validation failed")
        }

        var writeOK = true
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var offset = 0
            while offset < rawBuf.count {
                let n = Darwin.write(fd, base.advanced(by: offset), rawBuf.count - offset)
                if n < 0 && errno == EINTR {
                    continue
                }
                if n <= 0 {
                    writeOK = false
                    break
                }
                offset += n
            }
        }
        let chmodOK = Darwin.fchmod(fd, 0o600) == 0
        _ = Darwin.fsync(fd)
        Darwin.close(fd)
        guard writeOK && chmodOK else {
            Darwin.unlinkat(dirFD, tmpName, 0)
            throw MCPDaemonSessionFileError.writeFailed(writeOK ? "fchmod failed" : "short write")
        }
        if Darwin.renameat(dirFD, tmpName, dirFD, fileName) != 0 {
            let err = String(cString: strerror(errno))
            Darwin.unlinkat(dirFD, tmpName, 0)
            throw MCPDaemonSessionFileError.writeFailed(err)
        }
    }

    public static func read(from url: URL = defaultURL()) throws -> MCPDaemonSession {
        let dir = url.deletingLastPathComponent()
        let fileName = url.lastPathComponent
        guard !fileName.isEmpty, !fileName.contains("/"), fileName != ".", fileName != ".." else {
            throw MCPDaemonSessionFileError.readFailed("invalid session filename")
        }

        let dirFD = Darwin.open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if dirFD < 0 {
            if errno == ELOOP || errno == ENOTDIR {
                throw MCPDaemonSessionFileError.insecurePermissions("session directory is a symlink or not a directory")
            }
            throw MCPDaemonSessionFileError.readFailed("session directory missing or unreadable")
        }
        defer { Darwin.close(dirFD) }

        var dirStat = stat()
        guard Darwin.fstat(dirFD, &dirStat) == 0 else {
            throw MCPDaemonSessionFileError.readFailed(String(cString: strerror(errno)))
        }
        guard (dirStat.st_mode & S_IFMT) == S_IFDIR else {
            throw MCPDaemonSessionFileError.insecurePermissions("session directory is not a real directory")
        }
        guard dirStat.st_uid == getuid() else {
            throw MCPDaemonSessionFileError.insecurePermissions("session directory owner mismatch")
        }
        let dirPerms = dirStat.st_mode & 0o777
        guard (dirPerms & 0o077) == 0 else {
            throw MCPDaemonSessionFileError.insecurePermissions(
                String(format: "session directory mode %o too permissive", dirPerms)
            )
        }

        let fd = Darwin.openat(dirFD, fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ELOOP {
                throw MCPDaemonSessionFileError.insecurePermissions("session file is a symlink")
            }
            throw MCPDaemonSessionFileError.readFailed("session file missing or unreadable")
        }
        defer { Darwin.close(fd) }

        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else {
            throw MCPDaemonSessionFileError.readFailed(String(cString: strerror(errno)))
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw MCPDaemonSessionFileError.insecurePermissions("session file is not a regular file")
        }
        guard st.st_uid == getuid() else {
            throw MCPDaemonSessionFileError.insecurePermissions("owner mismatch")
        }
        let perms = st.st_mode & 0o777
        guard (perms & 0o077) == 0 else {
            throw MCPDaemonSessionFileError.insecurePermissions(String(format: "mode %o too permissive", perms))
        }
        guard st.st_size > 0, st.st_size <= off_t(maxSessionFileBytes) else {
            throw MCPDaemonSessionFileError.readFailed("session file size out of bounds")
        }

        var data = Data()
        data.reserveCapacity(Int(st.st_size))
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBytes { rawBuf -> Int in
                guard let base = rawBuf.baseAddress else { return -1 }
                return Darwin.read(fd, base, rawBuf.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw MCPDaemonSessionFileError.readFailed(String(cString: strerror(errno)))
            }
            if n == 0 {
                break
            }
            if data.count + n > maxSessionFileBytes {
                throw MCPDaemonSessionFileError.readFailed("session file exceeded size cap while reading")
            }
            data.append(contentsOf: buf[0..<n])
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MCPDaemonSession.self, from: data)
    }

    public static func remove(at url: URL = defaultURL()) {
        unlink(url.path)
    }
}

public enum MCPSocketError: LocalizedError, Sendable {
    case socketFailed(String)
    case connectFailed(String)
    case timeout
    case protocolError(String)
    case unauthorized

    public var errorDescription: String? {
        switch self {
        case .socketFailed(let msg):
            return "Loopback socket failure: \(msg)"
        case .connectFailed(let msg):
            return "Loopback connect failure: \(msg)"
        case .timeout:
            return "Loopback IPC timed out"
        case .protocolError(let msg):
            return "Loopback protocol error: \(msg)"
        case .unauthorized:
            return "Loopback token authentication failed"
        }
    }
}

public enum MCPBridgeCommandError: LocalizedError, Equatable, Sendable {
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .rejected(let msg):
            return "CoverUseBridge command error: \(msg)"
        }
    }
}

public enum MCPFramedSocketIO {
    public static let maxPreAuthFrameBytes = 64 * 1024
    public static let maxRequestFrameBytes = 256 * 1024
    public static let maxFrameBytes = 24 * 1024 * 1024

    public static func configureSocket(_ fd: Int32, timeoutSeconds: Double = 10.0) {
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
        if timeoutSeconds > 0 {
            let secs = Int(timeoutSeconds)
            let usecs = Int32((timeoutSeconds - Double(secs)) * 1_000_000)
            var tv = timeval(tv_sec: secs, tv_usec: usecs)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    public static func writeFrame(_ data: Data, to fd: Int32) throws {
        guard data.count <= maxFrameBytes else {
            throw MCPSocketError.protocolError("Frame too large: \(data.count)")
        }
        var lenBE = UInt32(data.count).bigEndian
        let headerWritten = withUnsafeBytes(of: &lenBE) { rawBuf -> Bool in
            writeAll(fd: fd, base: rawBuf.baseAddress, count: rawBuf.count)
        }
        guard headerWritten else {
            throw MCPSocketError.socketFailed(String(cString: strerror(errno)))
        }
        let bodyWritten = data.withUnsafeBytes { rawBuf -> Bool in
            writeAll(fd: fd, base: rawBuf.baseAddress, count: rawBuf.count)
        }
        guard bodyWritten else {
            throw MCPSocketError.socketFailed(String(cString: strerror(errno)))
        }
    }

    public static func readFrame(from fd: Int32, maxBytes: Int = maxFrameBytes) throws -> Data? {
        var lenBE: UInt32 = 0
        let headerRead = withUnsafeMutableBytes(of: &lenBE) { rawBuf -> Int in
            readExact(fd: fd, base: rawBuf.baseAddress, count: rawBuf.count)
        }
        if headerRead == 0 {
            return nil
        }
        if headerRead < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw MCPSocketError.timeout
            }
            throw MCPSocketError.socketFailed(String(cString: strerror(errno)))
        }
        let effectiveCap = max(1, min(maxBytes, maxFrameBytes))
        let length = Int(UInt32(bigEndian: lenBE))
        guard length > 0, length <= effectiveCap else {
            throw MCPSocketError.protocolError("Invalid frame length: \(length)")
        }

        let chunkSize = min(length, 64 * 1024)
        var payload = Data()
        payload.reserveCapacity(chunkSize)
        var scratch = [UInt8](repeating: 0, count: chunkSize)
        var remaining = length
        while remaining > 0 {
            let toRead = min(remaining, scratch.count)
            let bodyRead = scratch.withUnsafeMutableBytes { rawBuf -> Int in
                readExact(fd: fd, base: rawBuf.baseAddress, count: toRead)
            }
            if bodyRead != toRead {
                if bodyRead < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    throw MCPSocketError.timeout
                }
                throw MCPSocketError.protocolError("Truncated frame payload")
            }
            payload.append(contentsOf: scratch[0..<toRead])
            remaining -= toRead
        }
        return payload
    }

    public static func createLoopbackListener() throws -> (fd: Int32, port: UInt16) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw MCPSocketError.socketFailed(String(cString: strerror(errno)))
        }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindRc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRc == 0 else {
            let err = String(cString: strerror(errno))
            Darwin.close(fd)
            throw MCPSocketError.socketFailed("bind failed: \(err)")
        }
        guard Darwin.listen(fd, 64) == 0 else {
            let err = String(cString: strerror(errno))
            Darwin.close(fd)
            throw MCPSocketError.socketFailed("listen failed: \(err)")
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameRc = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.getsockname(fd, saPtr, &len)
            }
        }
        guard nameRc == 0 else {
            let err = String(cString: strerror(errno))
            Darwin.close(fd)
            throw MCPSocketError.socketFailed("getsockname failed: \(err)")
        }
        return (fd, UInt16(bigEndian: boundAddr.sin_port))
    }

    public static func connectLoopback(port: UInt16, timeoutSeconds: Double = 10.0) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw MCPSocketError.socketFailed(String(cString: strerror(errno)))
        }
        configureSocket(fd, timeoutSeconds: timeoutSeconds)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let connRc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connRc == 0 else {
            let err = String(cString: strerror(errno))
            Darwin.close(fd)
            throw MCPSocketError.connectFailed(err)
        }
        return fd
    }

    private static func writeAll(fd: Int32, base: UnsafeRawPointer?, count: Int) -> Bool {
        guard count > 0, let base else { return count == 0 }
        var sent = 0
        while sent < count {
            let n = Darwin.write(fd, base.advanced(by: sent), count - sent)
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                return false
            }
            sent += n
        }
        return true
    }

    private static func readExact(fd: Int32, base: UnsafeMutableRawPointer?, count: Int) -> Int {
        guard count > 0, let base else { return 0 }
        var total = 0
        while total < count {
            let n = Darwin.read(fd, base.advanced(by: total), count - total)
            if n == 0 {
                return total == 0 ? 0 : -1
            }
            if n < 0 {
                if errno == EINTR { continue }
                return -1
            }
            total += n
        }
        return total
    }
}

public struct MCPIPCRequestEnvelope: Codable, Sendable {
    public let token: String
    public let toolName: String
    public let arguments: [String: MCPJSONValue]

    public init(token: String, toolName: String, arguments: [String: MCPJSONValue]) {
        self.token = token
        self.toolName = toolName
        self.arguments = arguments
    }
}

public struct MCPIPCResponseEnvelope: Codable, Sendable {
    public let ok: Bool
    public let result: MCPToolCallResult?
    public let errorMessage: String?

    public init(ok: Bool, result: MCPToolCallResult? = nil, errorMessage: String? = nil) {
        self.ok = ok
        self.result = result
        self.errorMessage = errorMessage
    }
}

public final class MCPLoopbackServer: Sendable {
    public typealias ToolHandler = @Sendable (String, [String: MCPJSONValue]) async -> MCPToolCallResult
    public static let maxPreAuthClients = 32
    public static let maxAuthenticatedClients = 32
    public static let preAuthTimeoutSeconds: Double = 0.25
    public static let postAuthTimeoutSeconds: Double = 90.0

    private struct State: Sendable {
        var listenFD: Int32 = -1
        var port: UInt16 = 0
        var token: String = ""
        var stopped: Bool = true
        var preAuthClientFDs: [Int32: Date] = [:]
        var authenticatedClientFDs: Set<Int32> = []
    }

    private let state = Mutex<State>(State())
    private let handler: ToolHandler
    private let acceptQueue = DispatchQueue(label: "app.makedie.MacOver.MCPLoopbackServer.accept", qos: .userInitiated)
    private let clientIOQueue = DispatchQueue(
        label: "app.makedie.MacOver.MCPLoopbackServer.io",
        qos: .userInitiated,
        attributes: .concurrent
    )

    public init(handler: @escaping ToolHandler) {
        self.handler = handler
    }

    public func start() throws -> (port: UInt16, token: String) {
        stop()
        let token = try MCPTokenAuth.generateSecureHexToken()
        let (fd, port) = try MCPFramedSocketIO.createLoopbackListener()
        state.withLock {
            $0.listenFD = fd
            $0.port = port
            $0.token = token
            $0.stopped = false
        }

        acceptQueue.async { [weak self] in
            self?.runAcceptLoop(listenFD: fd, token: token)
        }
        return (port, token)
    }

    public func stop() {
        let fd = state.withLock { current -> Int32 in
            current.stopped = true
            let old = current.listenFD
            current.listenFD = -1
            current.port = 0
            current.token = ""
            // Shutdown active client FDs while holding state lock so handleClient's defer
            // cannot close and recycle an FD before shutdown completes (R3-LOW-05a).
            for clientFD in current.preAuthClientFDs.keys {
                Darwin.shutdown(clientFD, SHUT_RDWR)
            }
            for clientFD in current.authenticatedClientFDs {
                Darwin.shutdown(clientFD, SHUT_RDWR)
            }
            current.preAuthClientFDs.removeAll()
            current.authenticatedClientFDs.removeAll()
            return old
        }
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    private func runAcceptLoop(listenFD: Int32, token: String) {
        while !state.withLock({ $0.stopped }) {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.accept(listenFD, saPtr, &len)
                }
            }
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            let now = Date()
            let admitted = state.withLock { current -> Bool in
                guard !current.stopped else { return false }
                if current.preAuthClientFDs.count >= Self.maxPreAuthClients {
                    let cutoff = now.addingTimeInterval(-Self.preAuthTimeoutSeconds)
                    let toEvict = current.preAuthClientFDs
                        .filter { $0.value <= cutoff }
                        .map(\.key)
                    for pendingFD in toEvict {
                        // Shutdown inside state.withLock before removal so handleClient cannot
                        // close and recycle pendingFD before shutdown (R3-LOW-05a).
                        Darwin.shutdown(pendingFD, SHUT_RDWR)
                        current.preAuthClientFDs.removeValue(forKey: pendingFD)
                    }
                }
                guard current.preAuthClientFDs.count < Self.maxPreAuthClients else {
                    return false
                }
                current.preAuthClientFDs[clientFD] = now
                return true
            }
            guard admitted else {
                Darwin.close(clientFD)
                continue
            }
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.handleClient(fd: clientFD, expectedToken: token)
            }
        }
    }

    private func handleClient(fd: Int32, expectedToken: String) async {
        defer {
            state.withLock { current in
                _ = current.preAuthClientFDs.removeValue(forKey: fd)
                _ = current.authenticatedClientFDs.remove(fd)
            }
            Darwin.close(fd)
        }
        var authenticated = false
        do {
            while let payload = try await readFrameAsync(
                from: fd,
                maxBytes: authenticated
                    ? MCPFramedSocketIO.maxRequestFrameBytes
                    : MCPFramedSocketIO.maxPreAuthFrameBytes,
                timeoutSeconds: authenticated ? Self.postAuthTimeoutSeconds : Self.preAuthTimeoutSeconds
            ) {
                let envelope = try JSONDecoder().decode(MCPIPCRequestEnvelope.self, from: payload)
                guard MCPTokenAuth.constantTimeEquals(envelope.token, expectedToken) else {
                    let denied = MCPIPCResponseEnvelope(ok: false, errorMessage: "Unauthorized daemon token")
                    let encoded = try JSONEncoder().encode(denied)
                    try await writeFrameAsync(encoded, to: fd, timeoutSeconds: Self.preAuthTimeoutSeconds)
                    return
                }
                if !authenticated {
                    let promoted = state.withLock { current -> Bool in
                        _ = current.preAuthClientFDs.removeValue(forKey: fd)
                        guard !current.stopped,
                              current.authenticatedClientFDs.count < Self.maxAuthenticatedClients else {
                            return false
                        }
                        current.authenticatedClientFDs.insert(fd)
                        return true
                    }
                    guard promoted else {
                        let busy = MCPIPCResponseEnvelope(ok: false, errorMessage: "Daemon client limit reached")
                        if let encoded = try? JSONEncoder().encode(busy) {
                            try? await writeFrameAsync(encoded, to: fd, timeoutSeconds: Self.preAuthTimeoutSeconds)
                        }
                        return
                    }
                    authenticated = true
                }
                let result = await handler(envelope.toolName, envelope.arguments)
                let reply = MCPIPCResponseEnvelope(ok: true, result: result)
                let encoded = try JSONEncoder().encode(reply)
                try await writeFrameAsync(encoded, to: fd, timeoutSeconds: Self.postAuthTimeoutSeconds)
            }
        } catch {
            if let encoded = try? JSONEncoder().encode(
                MCPIPCResponseEnvelope(ok: false, errorMessage: error.localizedDescription)
            ) {
                try? await writeFrameAsync(encoded, to: fd, timeoutSeconds: Self.preAuthTimeoutSeconds)
            }
        }
    }

    private func readFrameAsync(from fd: Int32, maxBytes: Int, timeoutSeconds: Double) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            clientIOQueue.async {
                MCPFramedSocketIO.configureSocket(fd, timeoutSeconds: timeoutSeconds)
                do {
                    let payload = try MCPFramedSocketIO.readFrame(from: fd, maxBytes: maxBytes)
                    continuation.resume(returning: payload)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func writeFrameAsync(_ data: Data, to fd: Int32, timeoutSeconds: Double) async throws {
        try await withCheckedThrowingContinuation { continuation in
            clientIOQueue.async {
                MCPFramedSocketIO.configureSocket(fd, timeoutSeconds: timeoutSeconds)
                do {
                    try MCPFramedSocketIO.writeFrame(data, to: fd)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

public enum MCPLoopbackClient {
    public static func call(
        session: MCPDaemonSession,
        toolName: String,
        arguments: [String: MCPJSONValue],
        timeoutSeconds: Double = 65.0
    ) throws -> MCPToolCallResult {
        guard session.isHostProcessAlive else {
            throw MCPSocketError.connectFailed("Host process identity verification failed for pid \(session.pid)")
        }
        let fd = try MCPFramedSocketIO.connectLoopback(port: session.port, timeoutSeconds: timeoutSeconds)
        defer { Darwin.close(fd) }

        let request = MCPIPCRequestEnvelope(token: session.token, toolName: toolName, arguments: arguments)
        let reqData = try JSONEncoder().encode(request)
        try MCPFramedSocketIO.writeFrame(reqData, to: fd)

        guard let respData = try MCPFramedSocketIO.readFrame(from: fd) else {
            throw MCPSocketError.protocolError("Empty response from MacOver host")
        }
        let response = try JSONDecoder().decode(MCPIPCResponseEnvelope.self, from: respData)
        guard response.ok, let result = response.result else {
            throw MCPSocketError.protocolError(response.errorMessage ?? "Host rejected request")
        }
        return result
    }
}

public struct MCPBridgePendingToken: Sendable {
    public let bundleID: String
    public let expectedExecutablePath: String?
    public let expiresAt: Date

    public init(bundleID: String, expectedExecutablePath: String? = nil, expiresAt: Date) {
        self.bundleID = bundleID
        self.expectedExecutablePath = expectedExecutablePath
        self.expiresAt = expiresAt
    }
}

public final class MCPBridgeHub: Sendable {
    public static let maxConcurrentHandshakes = 32
    public static let preAuthTimeoutSeconds: Double = 0.25
    public typealias PeerPIDValidator = @Sendable (Int32, String, String?) -> Bool

    public struct SessionInfo: Equatable, Sendable {
        public let bundleID: String
        public let pid: Int32
        public let logicalWidth: Double
        public let logicalHeight: Double
        public let hasLiveViewport: Bool

        public init(
            bundleID: String,
            pid: Int32,
            logicalWidth: Double,
            logicalHeight: Double,
            hasLiveViewport: Bool = false
        ) {
            self.bundleID = bundleID
            self.pid = pid
            self.logicalWidth = logicalWidth
            self.logicalHeight = logicalHeight
            self.hasLiveViewport = hasLiveViewport
        }
    }

    private struct ViewportState: Sendable {
        var width: Double
        var height: Double
        var hasLiveViewport: Bool
    }

    private final class BridgeConnection: Sendable {
        let bundleID: String
        let pid: Int32
        let fd: Int32
        let viewport: Mutex<ViewportState>
        let ioLock = Mutex<Void>(())
        let closed = Mutex<Bool>(false)

        init(
            bundleID: String,
            pid: Int32,
            logicalWidth: Double,
            logicalHeight: Double,
            hasLiveViewport: Bool,
            fd: Int32
        ) {
            self.bundleID = bundleID
            self.pid = pid
            self.fd = fd
            self.viewport = Mutex(ViewportState(
                width: logicalWidth,
                height: logicalHeight,
                hasLiveViewport: hasLiveViewport
            ))
        }

        func snapshotSessionInfo() -> SessionInfo {
            let vp = viewport.withLock { $0 }
            return SessionInfo(
                bundleID: bundleID,
                pid: pid,
                logicalWidth: vp.width,
                logicalHeight: vp.height,
                hasLiveViewport: vp.hasLiveViewport
            )
        }

        func updateViewport(width: Double, height: Double, isLive: Bool = true) {
            guard width.isFinite, height.isFinite, width > 0, height > 0,
                  width <= 32_768, height <= 32_768 else {
                return
            }
            viewport.withLock { current in
                current.width = width
                current.height = height
                if isLive {
                    current.hasLiveViewport = true
                }
            }
        }

        func updateViewportIfPresent(from result: MCPJSONValue, method: String) {
            guard let obj = result.objectValue else { return }
            if let lw = obj.double("logicalWidth"), let lh = obj.double("logicalHeight"),
               lw.isFinite, lh.isFinite, lw > 0, lh > 0 {
                updateViewport(width: lw, height: lh, isLive: true)
                return
            }
            if method == "get_ui_tree",
               let w = obj.double("width"), let h = obj.double("height"),
               w.isFinite, h.isFinite, w > 0, h > 0 {
                updateViewport(width: w, height: h, isLive: true)
            }
        }

        func request(method: String, params: [String: MCPJSONValue], timeoutSeconds: Double) throws -> MCPJSONValue {
            try ioLock.withLock { _ in
                if closed.withLock({ $0 }) {
                    throw MCPSocketError.connectFailed("Bridge connection closed")
                }
                MCPFramedSocketIO.configureSocket(fd, timeoutSeconds: timeoutSeconds)
                let reqID = UUID().uuidString
                let envelope: [String: MCPJSONValue] = [
                    "id": .string(reqID),
                    "method": .string(method),
                    "params": .object(params)
                ]
                let data = try JSONEncoder().encode(MCPJSONValue.object(envelope))
                try MCPFramedSocketIO.writeFrame(data, to: fd)

                guard let respData = try MCPFramedSocketIO.readFrame(from: fd) else {
                    closed.withLock { $0 = true }
                    throw MCPSocketError.connectFailed("Bridge connection EOF")
                }
                let decoded = try JSONDecoder().decode(MCPJSONValue.self, from: respData)
                guard let obj = decoded.objectValue else {
                    throw MCPSocketError.protocolError("Bridge response is not a JSON object")
                }
                if obj.bool("ok") == false {
                    let msg = obj.string("error") ?? "Bridge command failed"
                    throw MCPBridgeCommandError.rejected(msg)
                }
                let result = obj["result"] ?? .object([:])
                updateViewportIfPresent(from: result, method: method)
                return result
            }
        }

        func close() {
            let shouldClose = closed.withLock { isClosed -> Bool in
                if isClosed { return false }
                isClosed = true
                return true
            }
            if shouldClose {
                Darwin.shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
            }
        }
    }

    private struct HubState: Sendable {
        var listenFD: Int32 = -1
        var port: UInt16 = 0
        var stopped: Bool = true
        var activeHandshakeFDs: [Int32: Date] = [:]
        var pendingTokens: [String: MCPBridgePendingToken] = [:]
        var connections: [String: BridgeConnection] = [:]
    }

    private let state = Mutex<HubState>(HubState())
    private let acceptQueue = DispatchQueue(label: "app.makedie.MacOver.MCPBridgeHub.accept", qos: .userInitiated)
    private let handshakeQueue = DispatchQueue(
        label: "app.makedie.MacOver.MCPBridgeHub.handshake",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let rpcQueue = DispatchQueue(
        label: "app.makedie.MacOver.MCPBridgeHub.rpc",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let peerPIDValidator: PeerPIDValidator

    public init(
        requireAppBundleMatch: Bool = false,
        peerPIDValidator: PeerPIDValidator? = nil
    ) {
        if let peerPIDValidator {
            self.peerPIDValidator = peerPIDValidator
        } else {
            self.peerPIDValidator = { pid, bundleID, expectedExecutablePath in
                Self.defaultValidatePeerProcess(
                    pid: pid,
                    bundleID: bundleID,
                    expectedExecutablePath: expectedExecutablePath,
                    requireAppBundleMatch: requireAppBundleMatch
                )
            }
        }
    }

    public static func defaultValidatePeerProcess(
        pid: Int32,
        bundleID: String,
        expectedExecutablePath: String?,
        requireAppBundleMatch: Bool
    ) -> Bool {
        guard pid > 0 else { return false }
        guard let bsdInfo = MCPProcessIdentity.bsdInfo(for: pid),
              bsdInfo.pbi_uid == getuid() else {
            return false
        }
        guard let livePath = MCPProcessIdentity.executablePath(for: pid), !livePath.isEmpty else {
            return false
        }
        if let expected = expectedExecutablePath, !expected.isEmpty {
            let canonicalExpected = URL(fileURLWithPath: expected).resolvingSymlinksInPath().path
            if livePath == canonicalExpected {
                return true
            }
            let expectedBundle = URL(fileURLWithPath: canonicalExpected).deletingLastPathComponent().path
            if expectedBundle.hasSuffix(".app"), livePath.hasPrefix(expectedBundle + "/") {
                return true
            }
            return false
        }
        if requireAppBundleMatch {
            return MCPProcessIdentity.enclosingAppBundleIdentifier(forExecutablePath: livePath) == bundleID
        }
        return true
    }

    public func start() throws -> UInt16 {
        stop()
        let (fd, port) = try MCPFramedSocketIO.createLoopbackListener()
        state.withLock {
            $0.listenFD = fd
            $0.port = port
            $0.stopped = false
        }
        acceptQueue.async { [weak self] in
            self?.runAcceptLoop(listenFD: fd)
        }
        return port
    }

    public func stop() {
        let (fd, conns) = state.withLock { current -> (Int32, [BridgeConnection]) in
            current.stopped = true
            let oldFD = current.listenFD
            current.listenFD = -1
            current.port = 0
            current.pendingTokens.removeAll()
            // Shutdown active handshake FDs while holding state lock so performHandshake's defer
            // cannot close and recycle an FD before shutdown completes (R3-LOW-05a).
            for hsFD in current.activeHandshakeFDs.keys {
                Darwin.shutdown(hsFD, SHUT_RDWR)
            }
            current.activeHandshakeFDs.removeAll()
            let existing = Array(current.connections.values)
            current.connections.removeAll()
            return (oldFD, existing)
        }
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        for conn in conns {
            conn.close()
        }
    }

    public var currentPort: UInt16? {
        state.withLock { $0.stopped || $0.port == 0 ? nil : $0.port }
    }

    public func issueLaunchToken(
        for bundleID: String,
        expectedExecutablePath: String? = nil,
        ttlSeconds: TimeInterval = 15.0
    ) -> String {
        let token = MCPTokenAuth.generateHexToken()
        let now = Date()
        let expiry = now.addingTimeInterval(max(1.0, ttlSeconds))
        state.withLock { current in
            current.pendingTokens = current.pendingTokens.filter { $0.value.expiresAt > now }
            current.pendingTokens[token] = MCPBridgePendingToken(
                bundleID: bundleID,
                expectedExecutablePath: expectedExecutablePath,
                expiresAt: expiry
            )
        }
        return token
    }

    public func sessionInfo(for bundleID: String) -> SessionInfo? {
        state.withLock { current in
            current.connections[bundleID]?.snapshotSessionInfo()
        }
    }

    public func updateViewport(for bundleID: String, width: Double, height: Double, isLive: Bool = true) {
        let conn = state.withLock { $0.connections[bundleID] }
        conn?.updateViewport(width: width, height: height, isLive: isLive)
    }

    public func connectedBundleIDs() -> [String] {
        state.withLock { Array($0.connections.keys).sorted() }
    }

    public func disconnect(bundleID: String) {
        let removed = state.withLock { $0.connections.removeValue(forKey: bundleID) }
        removed?.close()
    }

    public func sendRequest(
        bundleID: String,
        method: String,
        params: [String: MCPJSONValue] = [:],
        timeoutSeconds: Double = 15.0
    ) throws -> MCPJSONValue {
        guard let conn = state.withLock({ $0.connections[bundleID] }) else {
            throw MCPSocketError.connectFailed("CoverUseBridge is not connected for \(bundleID)")
        }
        do {
            return try conn.request(method: method, params: params, timeoutSeconds: timeoutSeconds)
        } catch let cmdError as MCPBridgeCommandError {
            throw cmdError
        } catch {
            disconnect(bundleID: bundleID)
            throw error
        }
    }

    public func sendRequestAsync(
        bundleID: String,
        method: String,
        params: [String: MCPJSONValue] = [:],
        timeoutSeconds: Double = 15.0
    ) async throws -> MCPJSONValue {
        try await withCheckedThrowingContinuation { continuation in
            rpcQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: MCPSocketError.connectFailed("MCPBridgeHub deallocated"))
                    return
                }
                do {
                    let result = try self.sendRequest(
                        bundleID: bundleID,
                        method: method,
                        params: params,
                        timeoutSeconds: timeoutSeconds
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runAcceptLoop(listenFD: Int32) {
        while !state.withLock({ $0.stopped }) {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.accept(listenFD, saPtr, &len)
                }
            }
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            let now = Date()
            let admitted = state.withLock { current -> Bool in
                guard !current.stopped else { return false }
                if current.activeHandshakeFDs.count >= Self.maxConcurrentHandshakes {
                    let cutoff = now.addingTimeInterval(-Self.preAuthTimeoutSeconds)
                    let toEvict = current.activeHandshakeFDs
                        .filter { $0.value <= cutoff }
                        .map(\.key)
                    for hsFD in toEvict {
                        // Shutdown inside state.withLock before removal so performHandshake cannot
                        // close and recycle hsFD before shutdown (R3-LOW-05a).
                        Darwin.shutdown(hsFD, SHUT_RDWR)
                        current.activeHandshakeFDs.removeValue(forKey: hsFD)
                    }
                }
                guard current.activeHandshakeFDs.count < Self.maxConcurrentHandshakes else {
                    return false
                }
                current.activeHandshakeFDs[clientFD] = now
                return true
            }
            guard admitted else {
                Darwin.close(clientFD)
                continue
            }
            handshakeQueue.async { [weak self] in
                self?.performHandshake(clientFD: clientFD)
            }
        }
    }

    private func performHandshake(clientFD: Int32) {
        var ownershipTransferred = false
        defer {
            state.withLock { current in
                _ = current.activeHandshakeFDs.removeValue(forKey: clientFD)
            }
            if !ownershipTransferred {
                Darwin.close(clientFD)
            }
        }
        MCPFramedSocketIO.configureSocket(clientFD, timeoutSeconds: Self.preAuthTimeoutSeconds)
        do {
            guard let helloData = try MCPFramedSocketIO.readFrame(
                from: clientFD,
                maxBytes: MCPFramedSocketIO.maxPreAuthFrameBytes
            ) else {
                return
            }
            let decoded = try JSONDecoder().decode(MCPJSONValue.self, from: helloData)
            guard let obj = decoded.objectValue,
                  obj.string("type") == "hello",
                  let token = obj.string("token"),
                  let bundleID = obj.string("bundleID"),
                  !bundleID.isEmpty else {
                sendFailureAck(fd: clientFD, error: "Invalid hello payload")
                return
            }

            // Authenticate and consume single-use token BEFORE parsing metadata (H-02).
            let consumedMeta = state.withLock { current -> MCPBridgePendingToken? in
                let now = Date()
                var matchedKey: String?
                var matchedMeta: MCPBridgePendingToken?
                for (candidateToken, meta) in current.pendingTokens where MCPTokenAuth.constantTimeEquals(
                    candidateToken,
                    token
                ) {
                    if meta.expiresAt >= now && meta.bundleID == bundleID {
                        matchedKey = candidateToken
                        matchedMeta = meta
                    }
                    break
                }
                guard let keyToConsume = matchedKey, let meta = matchedMeta else {
                    return nil
                }
                current.pendingTokens.removeValue(forKey: keyToConsume)
                return meta
            }

            guard let pendingMeta = consumedMeta else {
                sendFailureAck(fd: clientFD, error: "Invalid or expired launch token")
                return
            }

            guard let rawPID = obj.int("pid"),
                  let pid = Int32(exactly: rawPID),
                  pid > 0 else {
                sendFailureAck(fd: clientFD, error: "Invalid peer PID")
                return
            }

            guard peerPIDValidator(pid, bundleID, pendingMeta.expectedExecutablePath) else {
                sendFailureAck(fd: clientFD, error: "Peer process verification failed")
                return
            }

            let rawWidth = obj.double("logicalWidth") ?? 0
            let rawHeight = obj.double("logicalHeight") ?? 0
            let validDims = rawWidth.isFinite && rawHeight.isFinite
                && rawWidth > 0 && rawHeight > 0
                && rawWidth <= 32_768 && rawHeight <= 32_768
            let width = validDims ? rawWidth : 0
            let height = validDims ? rawHeight : 0
            let hasLiveViewport = obj.bool("isLiveViewport") ?? false

            // Write hello_ack BEFORE publishing BridgeConnection (M-04).
            MCPFramedSocketIO.configureSocket(clientFD, timeoutSeconds: 5.0)
            let ack = MCPJSONValue.object(["type": .string("hello_ack"), "ok": .bool(true)])
            let ackData = try JSONEncoder().encode(ack)
            try MCPFramedSocketIO.writeFrame(ackData, to: clientFD)

            let conn = BridgeConnection(
                bundleID: bundleID,
                pid: pid,
                logicalWidth: width,
                logicalHeight: height,
                hasLiveViewport: hasLiveViewport,
                fd: clientFD
            )
            let (published, previous) = state.withLock { current -> (Bool, BridgeConnection?) in
                _ = current.activeHandshakeFDs.removeValue(forKey: clientFD)
                guard !current.stopped else {
                    return (false, nil)
                }
                let old = current.connections.removeValue(forKey: bundleID)
                current.connections[bundleID] = conn
                return (true, old)
            }
            ownershipTransferred = true
            previous?.close()
            if !published {
                conn.close()
            }
        } catch {
            // Cleanup handled safely by defer after unregistering clientFD under state.withLock.
        }
    }

    private func sendFailureAck(fd: Int32, error: String) {
        let ack = MCPJSONValue.object([
            "type": .string("hello_ack"),
            "ok": .bool(false),
            "error": .string(error)
        ])
        if let data = try? JSONEncoder().encode(ack) {
            try? MCPFramedSocketIO.writeFrame(data, to: fd)
        }
    }
}
