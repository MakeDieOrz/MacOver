import CFNetwork
import CryptoKit
import Darwin
import Foundation
import Network
import PlayCoverCore
import Security
import Synchronization

public enum MITMProxyError: Error, LocalizedError, Sendable {
    case failedToStartListener(String)
    case upstreamConnectionFailed(String)
    case invalidHTTPRequest(String)

    public var errorDescription: String? {
        switch self {
        case let .failedToStartListener(msg):
            return "MITM listener failed: \(msg)"
        case let .upstreamConnectionFailed(msg):
            return "Upstream connection failed: \(msg)"
        case let .invalidHTTPRequest(msg):
            return "Malformed HTTP request: \(msg)"
        }
    }
}

public enum NetworkRuleMatchResult: Equatable, Sendable {
    case pass
    case allow
    case block
}

public struct NetworkRuleEvaluator: Sendable {
    private let engine: CanonicalNetworkRuleEngine

    public init(rawPatterns: [String]) {
        self.engine = CanonicalNetworkRuleEngine(rawPatterns: rawPatterns)
    }

    public func evaluate(host: String, urlString: String) -> NetworkRuleMatchResult {
        switch engine.evaluate(host: host, urlString: urlString) {
        case .pass:
            return .pass
        case .allow:
            return .allow
        case .block:
            return .block
        }
    }

    public func evaluateDetailed(host: String, urlString: String) -> NetworkRuleDecision {
        engine.evaluate(host: host, urlString: urlString)
    }

    public func evaluateHostForTunnel(host: String) -> NetworkRuleDecision {
        engine.evaluateHostForTunnel(host: host)
    }
}

private enum HTTPBodyFraming: Equatable, Sendable {
    case none
    case contentLength(Int)
    case chunked
    case closeDelimited
}

private struct StreamCaptureSummary: Sendable {
    let data: Data
    let truncated: Bool
}

private actor BufferedConnection {
    nonisolated let connection: NWConnection
    private var buffer = Data()

    init(connection: NWConnection) {
        self.connection = connection
    }

    func drainRemainder() -> Data {
        let out = buffer
        buffer.removeAll(keepingCapacity: false)
        return out
    }

    func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func readUpTo(maxCount: Int) async throws -> Data {
        guard maxCount > 0 else { return Data() }
        if buffer.isEmpty {
            let chunk = try await receiveChunk()
            if chunk.isEmpty {
                return Data()
            }
            if chunk.count <= maxCount {
                return chunk
            }
            buffer.append(chunk)
        }
        let takeCount = min(maxCount, buffer.count)
        let out = Data(buffer.prefix(takeCount))
        buffer.removeFirst(takeCount)
        return out
    }

    func readHeaderBlock(maxBytes: Int = 131_072) async throws -> Data? {
        let delimiter = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        while true {
            if let range = buffer.range(of: delimiter) {
                let block = buffer[..<range.lowerBound]
                buffer.removeSubrange(..<range.upperBound)
                return Data(block)
            }
            if buffer.count > maxBytes {
                throw MITMProxyError.invalidHTTPRequest("HTTP header exceeds \(maxBytes) bytes")
            }
            let chunk = try await receiveChunk()
            if chunk.isEmpty {
                return nil
            }
            buffer.append(chunk)
        }
    }

    func readExact(count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        while buffer.count < count {
            let chunk = try await receiveChunk()
            if chunk.isEmpty {
                throw MITMProxyError.upstreamConnectionFailed(
                    "Premature EOF while reading HTTP body (expected \(count) bytes, got \(buffer.count))"
                )
            }
            buffer.append(chunk)
        }
        let out = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return out
    }

    func readLine(maxBytes: Int = 16_384) async throws -> String? {
        let crlf = Data([0x0D, 0x0A])
        while true {
            if let range = buffer.range(of: crlf) {
                let lineData = buffer[..<range.lowerBound]
                if lineData.count > maxBytes {
                    throw MITMProxyError.invalidHTTPRequest("HTTP line exceeds \(maxBytes) bytes")
                }
                buffer.removeSubrange(..<range.upperBound)
                return String(data: Data(lineData), encoding: .utf8) ?? ""
            }
            if buffer.count > maxBytes {
                throw MITMProxyError.invalidHTTPRequest("HTTP line exceeds \(maxBytes) bytes")
            }
            let chunk = try await receiveChunk()
            if chunk.isEmpty {
                if buffer.isEmpty { return nil }
                throw MITMProxyError.upstreamConnectionFailed("Premature EOF before CRLF in HTTP stream")
            }
            buffer.append(chunk)
        }
    }

    private static func parseChunkSize(from sizeLine: String) throws -> Int {
        let sizeToken = sizeLine.split(separator: ";", maxSplits: 1).first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard !sizeToken.isEmpty,
              !sizeToken.hasPrefix("+"),
              !sizeToken.hasPrefix("-"),
              sizeToken.unicodeScalars.allSatisfy({ scalar in
                  let v = scalar.value
                  return (v >= 0x30 && v <= 0x39)
                      || (v >= 0x41 && v <= 0x46)
                      || (v >= 0x61 && v <= 0x66)
              }),
              let chunkSize = Int(sizeToken, radix: 16),
              chunkSize >= 0,
              chunkSize <= 256 * 1024 * 1024 else {
            throw MITMProxyError.invalidHTTPRequest("Invalid chunk length: \(sizeLine)")
        }
        return chunkSize
    }

    private static func appendCaptured(
        _ chunk: Data,
        into captured: inout Data,
        truncated: inout Bool,
        limit: Int
    ) {
        guard limit > 0, !chunk.isEmpty else { return }
        if captured.count >= limit {
            truncated = true
            return
        }
        let remaining = limit - captured.count
        if chunk.count <= remaining {
            captured.append(chunk)
        } else {
            captured.append(chunk.prefix(remaining))
            truncated = true
        }
    }

    func streamFixedLength(
        count: Int,
        to destination: BufferedConnection?,
        captureLimit: Int,
        leadingWirePrefix: Data? = nil,
        onPrefixSent: (@Sendable () -> Void)? = nil
    ) async throws -> StreamCaptureSummary {
        if count <= 0 {
            if let destination, let leadingWirePrefix, !leadingWirePrefix.isEmpty {
                try await destination.writeAll(leadingWirePrefix)
                onPrefixSent?()
            }
            return StreamCaptureSummary(data: Data(), truncated: false)
        }
        var remaining = count
        var captured = Data()
        var truncated = false
        var pendingPrefix = leadingWirePrefix
        while remaining > 0 {
            let chunk = try await readUpTo(maxCount: min(65_536, remaining))
            if chunk.isEmpty {
                throw MITMProxyError.upstreamConnectionFailed(
                    "Premature EOF while streaming HTTP body (\(remaining) bytes remaining)"
                )
            }
            if let destination {
                if let prefix = pendingPrefix, !prefix.isEmpty {
                    var combined = prefix
                    combined.append(chunk)
                    pendingPrefix = nil
                    onPrefixSent?()
                    try await destination.writeAll(combined)
                } else {
                    try await destination.writeAll(chunk)
                }
            }
            Self.appendCaptured(chunk, into: &captured, truncated: &truncated, limit: captureLimit)
            remaining -= chunk.count
        }
        return StreamCaptureSummary(data: captured, truncated: truncated)
    }

    func streamChunkedBody(
        to destination: BufferedConnection?,
        captureLimit: Int
    ) async throws -> StreamCaptureSummary {
        var captured = Data()
        var truncated = false
        while true {
            guard let sizeLine = try await readLine() else {
                throw MITMProxyError.upstreamConnectionFailed("Premature EOF before chunk size")
            }
            let chunkSize = try Self.parseChunkSize(from: sizeLine)
            if chunkSize == 0 {
                var trailerCount = 0
                while true {
                    guard let trailer = try await readLine() else {
                        throw MITMProxyError.upstreamConnectionFailed("Premature EOF in chunked trailers")
                    }
                    if trailer.isEmpty {
                        break
                    }
                    trailerCount += 1
                    if trailerCount > 128 {
                        throw MITMProxyError.invalidHTTPRequest("Too many chunked trailers")
                    }
                }
                if let destination {
                    try await destination.writeAll(Data("0\r\n\r\n".utf8))
                }
                break
            }

            if let destination {
                try await destination.writeAll(Data("\(String(chunkSize, radix: 16))\r\n".utf8))
            }
            var remaining = chunkSize
            while remaining > 0 {
                let chunk = try await readUpTo(maxCount: min(65_536, remaining))
                if chunk.isEmpty {
                    throw MITMProxyError.upstreamConnectionFailed(
                        "Premature EOF mid-chunk (\(remaining) bytes remaining)"
                    )
                }
                if let destination {
                    try await destination.writeAll(chunk)
                }
                Self.appendCaptured(chunk, into: &captured, truncated: &truncated, limit: captureLimit)
                remaining -= chunk.count
            }
            let trailingCRLF = try await readExact(count: 2)
            guard trailingCRLF == Data([0x0D, 0x0A]) else {
                throw MITMProxyError.invalidHTTPRequest("Missing CRLF after HTTP chunk payload")
            }
            if let destination {
                try await destination.writeAll(Data([0x0D, 0x0A]))
            }
        }
        return StreamCaptureSummary(data: captured, truncated: truncated)
    }

    func streamUntilEOF(
        to destination: BufferedConnection?,
        captureLimit: Int
    ) async throws -> StreamCaptureSummary {
        var captured = Data()
        var truncated = false
        while true {
            let chunk = try await readUpTo(maxCount: 65_536)
            if chunk.isEmpty {
                break
            }
            if let destination {
                try await destination.writeAll(chunk)
            }
            Self.appendCaptured(chunk, into: &captured, truncated: &truncated, limit: captureLimit)
        }
        return StreamCaptureSummary(data: captured, truncated: truncated)
    }

    func writeAll(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

private struct ParsedHTTPRequestHead {
    let method: String
    let target: String
    let version: String
    let headers: [(name: String, value: String)]
    let headerMap: [String: String]
}

private struct ParsedHTTPResponseHead {
    let statusCode: Int
    let reasonPhrase: String
    let version: String
    let headers: [(name: String, value: String)]
    let headerMap: [String: String]
}

public actor LocalMITMProxyServer {
    private struct ShutdownHandles: @unchecked Sendable {
        var stopped = false
        var listeners: [UUID: NWListener] = [:]
        var connections: [UUID: NWConnection] = [:]
    }

    private var leafIssuer: X509LeafIssuer
    private var rootCertificateDER: Data
    public let captureStore: TrafficCaptureStore
    private var upstreamCustomAnchorDERs: [Data]
    private var allowedClientPIDs: Set<pid_t>?

    private var config: MITMServerConfiguration
    private let allowedClientBundlePrefixes: [String]?
    private let queue = DispatchQueue(label: "app.makedie.MacOver.MITMProxy", qos: .userInitiated)
    private let shutdownHandles = Mutex<ShutdownHandles>(ShutdownHandles())
    private var listener: NWListener?
    private var listenerToken: UUID?
    private var boundListenPort: UInt16 = 0
    private var isStopped = false
    private var activeConnections: [UUID: NWConnection] = [:]
    private var terminators: [String: (port: UInt16, listener: NWListener, token: UUID)] = [:]
    private var activeTerminatorHandshakes: [String: Int] = [:]
    private var pendingTerminators: [String: Task<UInt16, Error>] = [:]
    private var terminatorOrder: [String] = []
    private let maxTerminators = 256

    public init(
        rootCertificateDER: Data,
        rootPrivateKeyDER: Data,
        configuration: MITMServerConfiguration,
        captureStore: TrafficCaptureStore? = nil,
        upstreamTrustOverrideDER: Data? = nil,
        upstreamCustomAnchorDERs: [Data] = [],
        allowedClientPIDs: Set<pid_t>? = nil,
        allowedClientAppBundleURL: URL? = nil
    ) throws {
        self.leafIssuer = try X509LeafIssuer(
            rootCertificateDER: rootCertificateDER,
            rootPrivateKeyDER: rootPrivateKeyDER
        )
        self.rootCertificateDER = rootCertificateDER
        self.config = configuration
        self.captureStore = captureStore ?? TrafficCaptureStore(bundleID: configuration.bundleID)
        var anchors = upstreamCustomAnchorDERs
        if let upstreamTrustOverrideDER {
            anchors.append(upstreamTrustOverrideDER)
        }
        self.upstreamCustomAnchorDERs = anchors
        self.allowedClientPIDs = allowedClientPIDs
        if let bundleURL = allowedClientAppBundleURL {
            var prefixes: [String] = []
            let resolved = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
            let standardized = bundleURL.standardizedFileURL.path
            for raw in [resolved, standardized] where !raw.isEmpty {
                let normalized = raw.hasSuffix("/") ? raw : raw + "/"
                if !prefixes.contains(normalized) {
                    prefixes.append(normalized)
                }
            }
            self.allowedClientBundlePrefixes = prefixes.isEmpty ? nil : prefixes
        } else {
            self.allowedClientBundlePrefixes = nil
        }
    }

    public func updateConfiguration(_ newConfig: MITMServerConfiguration) {
        self.config = newConfig
    }

    public func updateUpstreamCustomAnchors(_ ders: [Data]) {
        self.upstreamCustomAnchorDERs = ders
    }

    public func updateAllowedClientPIDs(_ pids: Set<pid_t>?) {
        self.allowedClientPIDs = pids
    }

    var currentStaticAllowedClientPIDs: Set<pid_t>? {
        allowedClientPIDs
    }

    public func updateRootCA(certificateDER: Data, privateKeyDER: Data) throws {
        guard certificateDER != rootCertificateDER else { return }
        let nextIssuer = try X509LeafIssuer(
            rootCertificateDER: certificateDER,
            rootPrivateKeyDER: privateKeyDER
        )
        self.leafIssuer = nextIssuer
        self.rootCertificateDER = certificateDER
        for pending in pendingTerminators.values {
            pending.cancel()
        }
        pendingTerminators.removeAll()
        for entry in terminators.values {
            entry.listener.cancel()
            unregisterShutdownListener(token: entry.token)
        }
        terminators.removeAll()
        terminatorOrder.removeAll()
    }

    public nonisolated func stopImmediately() {
        let (listenersToCancel, connectionsToCancel) = shutdownHandles.withLock { state -> (
            [NWListener], [NWConnection]
        ) in
            state.stopped = true
            let ls = Array(state.listeners.values)
            let cs = Array(state.connections.values)
            state.listeners.removeAll()
            state.connections.removeAll()
            return (ls, cs)
        }
        for listener in listenersToCancel {
            listener.cancel()
        }
        for conn in connectionsToCancel {
            conn.cancel()
        }
    }

    private func registerShutdownListener(_ listener: NWListener) -> UUID {
        let token = UUID()
        let alreadyStopped = shutdownHandles.withLock { state -> Bool in
            if state.stopped { return true }
            state.listeners[token] = listener
            return false
        }
        if alreadyStopped {
            listener.cancel()
        }
        return token
    }

    private func unregisterShutdownListener(token: UUID) {
        shutdownHandles.withLock { _ = $0.listeners.removeValue(forKey: token) }
    }

    private func registerShutdownConnection(_ connection: NWConnection, token: UUID) {
        let alreadyStopped = shutdownHandles.withLock { state -> Bool in
            if state.stopped { return true }
            state.connections[token] = connection
            return false
        }
        if alreadyStopped {
            connection.cancel()
        }
    }

    private func unregisterShutdownConnection(token: UUID) {
        shutdownHandles.withLock { _ = $0.connections.removeValue(forKey: token) }
    }

    @discardableResult
    public func start() async throws -> UInt16 {
        if let existing = listener, let port = existing.port?.rawValue {
            return port
        }
        isStopped = false
        shutdownHandles.withLock { $0.stopped = false }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = false
        let nwPort: NWEndpoint.Port = config.listenPort == 0
            ? .any
            : (NWEndpoint.Port(rawValue: config.listenPort) ?? .any)
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)

        let newListener = try NWListener(using: params)
        newListener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task {
                await self.acceptClientConnection(connection)
            }
        }

        let boundPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let settled = Mutex(false)
            newListener.stateUpdateHandler = { state in
                let shouldSettle = settled.withLock { done -> Bool in
                    guard !done else { return false }
                    switch state {
                    case .ready, .failed, .cancelled:
                        done = true
                        return true
                    default:
                        return false
                    }
                }
                guard shouldSettle else { return }
                switch state {
                case .ready:
                    if let port = newListener.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: MITMProxyError.failedToStartListener("Missing bound port"))
                    }
                case let .failed(error):
                    continuation.resume(throwing: MITMProxyError.failedToStartListener(error.localizedDescription))
                case .cancelled:
                    continuation.resume(throwing: MITMProxyError.failedToStartListener("Listener cancelled"))
                default:
                    break
                }
            }
            newListener.start(queue: self.queue)
        }

        if isStopped || shutdownHandles.withLock({ $0.stopped }) {
            newListener.cancel()
            throw MITMProxyError.failedToStartListener("Server stopped during startup")
        }
        self.listener = newListener
        self.listenerToken = registerShutdownListener(newListener)
        self.boundListenPort = boundPort
        return boundPort
    }

    public func stop() {
        isStopped = true
        if let listenerToken {
            unregisterShutdownListener(token: listenerToken)
            self.listenerToken = nil
        }
        listener?.cancel()
        listener = nil
        boundListenPort = 0
        for pending in pendingTerminators.values {
            pending.cancel()
        }
        pendingTerminators.removeAll()
        for (token, conn) in activeConnections {
            conn.cancel()
            unregisterShutdownConnection(token: token)
        }
        activeConnections.removeAll()
        for entry in terminators.values {
            entry.listener.cancel()
            unregisterShutdownListener(token: entry.token)
        }
        terminators.removeAll()
        terminatorOrder.removeAll()
        stopImmediately()
    }

    private func acceptClientConnection(_ connection: NWConnection) {
        if allowedClientPIDs != nil || allowedClientBundlePrefixes != nil {
            var admitted = false
            if let allowedPIDs = allowedClientPIDs,
               Self.isLoopbackPeerOwnedByAnyPID(
                   endpoint: connection.endpoint,
                   targetPIDs: allowedPIDs,
                   listenPort: boundListenPort
               ) {
                admitted = true
            } else if let bundlePrefixes = allowedClientBundlePrefixes,
                      let peerPort = Self.extractLoopbackPeerPort(from: connection.endpoint),
                      let peerPID = Self.findSameUIDPeerPID(peerPort: peerPort, listenPort: boundListenPort),
                      Self.shouldAdmitDynamicPeer(peerPID: peerPID, bundlePrefixes: bundlePrefixes) {
                // Intentionally keep dynamic bundle-prefix verification separate from static
                // allowedClientPIDs so PID reuse and shared XPC daemons are never permanently admitted.
                admitted = true
            }
            guard admitted else {
                connection.cancel()
                return
            }
        }
        let token = UUID()
        activeConnections[token] = connection
        registerShutdownConnection(connection, token: token)
        connection.start(queue: queue)

        Task {
            defer {
                connection.cancel()
                Task { self.removeConnection(token: token) }
            }
            await handleProxyClient(connection)
        }
    }

    private func removeConnection(token: UUID) {
        activeConnections.removeValue(forKey: token)
        unregisterShutdownConnection(token: token)
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(lhs, rhs) {
            diff |= a ^ b
        }
        return diff == 0
    }

    private static func isProxyAuthorizationValid(
        headers: [(name: String, value: String)],
        requiredToken: String?
    ) -> Bool {
        guard let token = requiredToken, !token.isEmpty else {
            return true
        }
        guard let authHeader = headers.first(where: {
            $0.name.lowercased() == "proxy-authorization"
        })?.value.trimmingCharacters(in: .whitespacesAndNewlines),
        !authHeader.isEmpty else {
            return false
        }
        let tokenData = Data(token.utf8)
        let lower = authHeader.lowercased()
        if lower.hasPrefix("bearer ") {
            let candidate = String(authHeader.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            return constantTimeEqual(Data(candidate.utf8), tokenData)
        }
        if lower.hasPrefix("basic ") {
            let b64 = String(authHeader.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let decodedData = Data(base64Encoded: b64),
                  let decoded = String(data: decodedData, encoding: .utf8) else {
                return false
            }
            let password: String
            if let colon = decoded.firstIndex(of: ":") {
                password = String(decoded[decoded.index(after: colon)...])
            } else {
                password = decoded
            }
            return constantTimeEqual(Data(password.utf8), tokenData)
        }
        return false
    }

    private static func extractLoopbackPeerPort(from endpoint: NWEndpoint) -> UInt16? {
        guard case let .hostPort(host, port) = endpoint else { return nil }
        let hostStr: String
        switch host {
        case let .ipv4(addr):
            hostStr = "\(addr)"
        case let .ipv6(addr):
            hostStr = "\(addr)"
        case let .name(name, _):
            hostStr = name
        @unknown default:
            return nil
        }
        guard isLoopbackHost(hostStr) else { return nil }
        let peerPort = port.rawValue
        return peerPort > 0 ? peerPort : nil
    }

    private static func isLoopbackPeerOwnedByAnyPID(
        endpoint: NWEndpoint,
        targetPIDs: Set<pid_t>,
        listenPort: UInt16 = 0
    ) -> Bool {
        guard !targetPIDs.isEmpty else { return false }
        guard let peerPort = extractLoopbackPeerPort(from: endpoint) else { return false }
        for pid in targetPIDs where process(pid, ownsLocalTCPPort: peerPort, connectedToPort: listenPort) {
            return true
        }
        return false
    }

    private static func findSameUIDPeerPID(peerPort: UInt16, listenPort: UInt16) -> pid_t? {
        let uid = Darwin.getuid()
        let estimatedBytes = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard estimatedBytes > 0 else { return nil }
        let count = Int(estimatedBytes) / MemoryLayout<pid_t>.stride + 32
        var pids = [pid_t](repeating: 0, count: count)
        let actualBytes = pids.withUnsafeMutableBytes { raw -> Int32 in
            proc_listpids(UInt32(PROC_UID_ONLY), uid, raw.baseAddress, Int32(raw.count))
        }
        guard actualBytes > 0 else { return nil }
        let pidCount = Int(actualBytes) / MemoryLayout<pid_t>.stride
        for idx in 0..<pidCount {
            let pid = pids[idx]
            guard pid > 0 else { continue }
            if process(pid, ownsLocalTCPPort: peerPort, connectedToPort: listenPort) {
                return pid
            }
        }
        return nil
    }

    private typealias ResponsibilityLookupFn = @convention(c) (pid_t) -> pid_t

    private static let responsibilityLookup: ResponsibilityLookupFn? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let sym = Darwin.dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(sym, to: ResponsibilityLookupFn.self)
    }()

    static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let fn = responsibilityLookup else { return nil }
        let responsible = fn(pid)
        return responsible > 0 ? responsible : nil
    }

    static func isAppleSystemNetworkHelperPath(_ execPath: String) -> Bool {
        let standardized = URL(fileURLWithPath: execPath).standardizedFileURL.path
        let resolved = URL(fileURLWithPath: execPath).resolvingSymlinksInPath().standardizedFileURL.path
        for path in [standardized, resolved] {
            if (path.hasPrefix("/System/") && path.hasSuffix("/com.apple.WebKit.Networking"))
                || path == "/usr/libexec/nsurlsessiond" {
                return true
            }
        }
        return false
    }

    static func executablePathMatchesBundlePrefixes(_ execPath: String, prefixes: [String]) -> Bool {
        let standardizedExec = URL(fileURLWithPath: execPath).standardizedFileURL.path
        let resolvedExec = URL(fileURLWithPath: execPath).resolvingSymlinksInPath().standardizedFileURL.path
        return prefixes.contains(where: {
            standardizedExec.hasPrefix($0) || resolvedExec.hasPrefix($0)
        })
    }

    static func shouldAdmitDynamicPeer(
        peerPID: pid_t,
        bundlePrefixes: [String],
        executablePathLookup: (pid_t) -> String? = executablePath(for:),
        responsiblePIDLookup: (pid_t) -> pid_t? = responsiblePID(for:)
    ) -> Bool {
        guard let execPath = executablePathLookup(peerPID) else { return false }
        if executablePathMatchesBundlePrefixes(execPath, prefixes: bundlePrefixes) {
            return true
        }
        if isAppleSystemNetworkHelperPath(execPath),
           let respPID = responsiblePIDLookup(peerPID),
           respPID > 0,
           let respExecPath = executablePathLookup(respPID),
           executablePathMatchesBundlePrefixes(respExecPath, prefixes: bundlePrefixes) {
            return true
        }
        return false
    }

    private static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return nil }
        let bytes = buffer.prefix(Int(len)).map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func process(
        _ pid: pid_t,
        ownsLocalTCPPort port: UInt16,
        connectedToPort remotePort: UInt16 = 0
    ) -> Bool {
        let estimatedSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard estimatedSize > 0 else { return false }
        let fdInfoSize = MemoryLayout<proc_fdinfo>.stride
        let count = Int(estimatedSize) / fdInfoSize + 16
        var fdInfos = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let actualSize = fdInfos.withUnsafeMutableBytes { raw -> Int32 in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard actualSize > 0 else { return false }
        let fdCount = Int(actualSize) / fdInfoSize
        let targetNetPort = Int32(port.bigEndian)
        let expectedRemoteNetPort = Int32(remotePort.bigEndian)
        for idx in 0..<fdCount {
            let info = fdInfos[idx]
            guard info.proc_fdtype == PROX_FDTYPE_SOCKET else { continue }
            var sockInfo = socket_fdinfo()
            let sockSize = proc_pidfdinfo(
                pid,
                info.proc_fd,
                PROC_PIDFDSOCKETINFO,
                &sockInfo,
                Int32(MemoryLayout<socket_fdinfo>.size)
            )
            guard sockSize == Int32(MemoryLayout<socket_fdinfo>.size) else { continue }
            let family = sockInfo.psi.soi_family
            guard family == AF_INET || family == AF_INET6 else { continue }
            guard sockInfo.psi.soi_kind == SOCKINFO_TCP else { continue }
            let ini = sockInfo.psi.soi_proto.pri_tcp.tcpsi_ini
            if ini.insi_lport == targetNetPort {
                if remotePort == 0 || ini.insi_fport == expectedRemoteNetPort {
                    return true
                }
            }
        }
        return false
    }

    private func isBlockedLoopbackOrSelfTarget(host: String, port: Int) -> String? {
        guard port > 0, port <= 65_535 else { return nil }
        let resolvedHost = config.hostOverrides[host.lowercased()] ?? host
        let isHostLoopback = Self.isLoopbackHost(host)
        let isResolvedLoopback = Self.isLoopbackHost(resolvedHost)
        guard isHostLoopback || isResolvedLoopback else {
            return nil
        }
        let targetPort = UInt16(port)
        if boundListenPort > 0 && targetPort == boundListenPort {
            return "Blocked self-proxy loop"
        }
        if terminators.values.contains(where: { $0.port == targetPort }) {
            return "Blocked self-proxy loop"
        }
        if config.blockLoopbackTargets && config.hostOverrides[host.lowercased()] == nil {
            return "Blocked loopback destination"
        }
        return nil
    }

    private func handleProxyClient(_ connection: NWConnection) async {
        let stream = BufferedConnection(connection: connection)
        let connectStart = ContinuousClock.now
        var activeConnectTarget: (host: String, port: Int)?
        do {
            while !Task.isCancelled {
                guard let headerData = try await stream.readHeaderBlock(),
                      let req = parseHTTPRequestHead(headerData) else {
                    return
                }

                if !Self.isProxyAuthorizationValid(
                    headers: req.headers,
                    requiredToken: config.requiredProxyAuthToken
                ) {
                    let resp = Data(
                        (
                            "HTTP/1.1 407 Proxy Authentication Required\r\n" +
                            "Proxy-Authenticate: Basic realm=\"MacOver\"\r\n" +
                            "Content-Length: 0\r\n" +
                            "Connection: close\r\n\r\n"
                        ).utf8
                    )
                    try? await stream.writeAll(resp)
                    return
                }

                if Self.hasDuplicateHostHeaders(req.headers) {
                    try? await stream.writeAll(
                        Self.simpleResponse(code: 400, reason: "Bad Request", body: "Duplicate Host header")
                    )
                    return
                }

                if req.method.uppercased() == "CONNECT" {
                    let (host, port) = Self.parseHostPort(req.target, defaultPort: 443)
                    guard !host.isEmpty, port > 0, port <= 65_535 else {
                        let resp = Self.simpleResponse(code: 400, reason: "Bad Request", body: "Invalid CONNECT target")
                        try? await stream.writeAll(resp)
                        return
                    }
                    if let blockReason = isBlockedLoopbackOrSelfTarget(host: host, port: port) {
                        let resp = Self.simpleResponse(
                            code: 403,
                            reason: "Forbidden",
                            body: blockReason
                        )
                        try? await stream.writeAll(resp)
                        let authorityHost = Self.formatAuthorityHost(host)
                        captureStore.append(MITMCaptureEntry(
                            bundleID: config.bundleID,
                            method: "CONNECT",
                            scheme: "https",
                            host: host,
                            port: port,
                            path: "/",
                            urlString: "https://\(authorityHost):\(port)/",
                            statusCode: 403,
                            durationMs: Self.elapsedMs(since: connectStart),
                            disposition: .blocked,
                            errorDescription: blockReason
                        ))
                        return
                    }
                    activeConnectTarget = (host, port)
                    let currentConfig = config
                    if MITMHostMatcher.matches(
                        host: host,
                        mitmAllHosts: currentConfig.mitmAllHosts,
                        patterns: currentConfig.mitmHostPatterns
                    ) {
                        try await handleCONNECTMITM(
                            host: host,
                            port: port,
                            clientStream: stream
                        )
                    } else {
                        try await handleCONNECTTunnel(
                            host: host,
                            port: port,
                            clientStream: stream
                        )
                    }
                    return
                }

                if Self.shouldSend100Continue(headers: req.headerMap) {
                    try await stream.writeAll(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
                }
                let keepAlive = await handlePlainHTTPRequest(req, clientStream: stream)
                if !keepAlive {
                    return
                }
            }
        } catch {
            if let target = activeConnectTarget {
                let portSuffix = target.port == 443 ? "" : ":\(target.port)"
                let authorityHost = Self.formatAuthorityHost(target.host)
                let errMsg = error.localizedDescription
                try? await stream.writeAll(Self.simpleResponse(code: 502, reason: "Bad Gateway", body: errMsg))
                captureStore.append(MITMCaptureEntry(
                    bundleID: config.bundleID,
                    method: "CONNECT",
                    scheme: "https",
                    host: target.host,
                    port: target.port,
                    path: "/",
                    urlString: "https://\(authorityHost)\(portSuffix)/",
                    statusCode: 502,
                    durationMs: Self.elapsedMs(since: connectStart),
                    disposition: .error,
                    errorDescription: errMsg
                ))
            }
        }
    }

    private func handleCONNECTTunnel(
        host: String,
        port: Int,
        clientStream: BufferedConnection
    ) async throws {
        let start = ContinuousClock.now
        let currentConfig = config
        let authorityHost = Self.formatAuthorityHost(host)
        let fullURL = "https://\(authorityHost)\(port == 443 ? "" : ":\(port)")/"
        if currentConfig.enableNetworkRules {
            let evaluator = NetworkRuleEvaluator(rawPatterns: currentConfig.blockedURLPatterns)
            if case .block = evaluator.evaluateHostForTunnel(host: host) {
                let forbidden = Self.simpleResponse(code: 403, reason: "Forbidden", body: "Blocked by MacOver")
                try await clientStream.writeAll(forbidden)
                captureStore.append(MITMCaptureEntry(
                    bundleID: currentConfig.bundleID,
                    method: "CONNECT",
                    scheme: "https",
                    host: host,
                    port: port,
                    path: "/",
                    urlString: fullURL,
                    statusCode: 403,
                    durationMs: Self.elapsedMs(since: start),
                    disposition: .blocked
                ))
                return
            }
        }

        let connectHost = currentConfig.hostOverrides[host.lowercased()] ?? host
        let upstream = try await connectTCP(
            targetHost: host,
            connectHost: connectHost,
            port: UInt16(clamping: port)
        )
        defer { upstream.cancel() }

        try await clientStream.writeAll(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
        captureStore.append(MITMCaptureEntry(
            bundleID: currentConfig.bundleID,
            method: "CONNECT",
            scheme: "https",
            host: host,
            port: port,
            path: "/",
            urlString: fullURL,
            statusCode: 200,
            durationMs: Self.elapsedMs(since: start),
            disposition: .tunnel
        ))

        let initialClientData = await clientStream.drainRemainder()
        await Self.pumpBidirectional(
            client: clientStream.connection,
            upstream: upstream,
            initialUpstreamBytes: initialClientData
        )
    }

    private func handleCONNECTMITM(
        host: String,
        port: Int,
        clientStream: BufferedConnection
    ) async throws {
        let cacheKey = "\(host.lowercased()):\(port)"
        let terminatorPort = try await getOrCreateTerminator(host: host, upstreamPort: port)
        activeTerminatorHandshakes[cacheKey, default: 0] += 1
        let bridgeConn: NWConnection
        do {
            bridgeConn = try await connectTCP(
                targetHost: "127.0.0.1",
                connectHost: "127.0.0.1",
                port: terminatorPort,
                allowInternalTerminator: true
            )
        } catch {
            releaseTerminatorHandshake(cacheKey: cacheKey)
            throw error
        }
        releaseTerminatorHandshake(cacheKey: cacheKey)
        defer { bridgeConn.cancel() }

        try await clientStream.writeAll(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
        let initialClientData = await clientStream.drainRemainder()
        await Self.pumpBidirectional(
            client: clientStream.connection,
            upstream: bridgeConn,
            initialUpstreamBytes: initialClientData
        )
    }

    private func releaseTerminatorHandshake(cacheKey: String) {
        let next = (activeTerminatorHandshakes[cacheKey] ?? 1) - 1
        if next <= 0 {
            activeTerminatorHandshakes.removeValue(forKey: cacheKey)
        } else {
            activeTerminatorHandshakes[cacheKey] = next
        }
    }

    private func getOrCreateTerminator(host: String, upstreamPort: Int) async throws -> UInt16 {
        let cacheKey = "\(host.lowercased()):\(upstreamPort)"
        if isStopped {
            throw MITMProxyError.failedToStartListener("Server stopped")
        }
        if let existing = terminators[cacheKey] {
            return existing.port
        }
        if let pendingTask = pendingTerminators[cacheKey] {
            return try await pendingTask.value
        }

        let issuerSnapshot = self.leafIssuer
        let task = Task<UInt16, Error> {
            let nwIdentity = try issuerSnapshot.makeSecIdentity(for: host)
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, nwIdentity)
            sec_protocol_options_add_tls_application_protocol(tlsOptions.securityProtocolOptions, "http/1.1")

            let params = NWParameters(tls: tlsOptions, tcp: .init())
            params.allowLocalEndpointReuse = false
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)

            let selfPID = getpid()
            let termListener = try NWListener(using: params)
            termListener.newConnectionHandler = { [weak server = self] tlsConn in
                guard let server,
                      Self.isLoopbackPeerOwnedByAnyPID(
                          endpoint: tlsConn.endpoint,
                          targetPIDs: [selfPID]
                      ) else {
                    tlsConn.cancel()
                    return
                }
                Task {
                    await server.handleDecryptedHTTPSConnection(tlsConn, targetHost: host, targetPort: upstreamPort)
                }
            }

            let boundPort: UInt16
            do {
                boundPort = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        let settled = Mutex(false)
                        termListener.stateUpdateHandler = { state in
                            let shouldSettle = settled.withLock { done -> Bool in
                                guard !done else { return false }
                                switch state {
                                case .ready, .failed, .cancelled:
                                    done = true
                                    return true
                                default:
                                    return false
                                }
                            }
                            guard shouldSettle else { return }
                            switch state {
                            case .ready:
                                if let port = termListener.port?.rawValue {
                                    continuation.resume(returning: port)
                                } else {
                                    let err = MITMProxyError.failedToStartListener("Missing TLS terminator port")
                                    continuation.resume(throwing: err)
                                }
                            case let .failed(error):
                                let err = MITMProxyError.failedToStartListener(error.localizedDescription)
                                continuation.resume(throwing: err)
                            case .cancelled:
                                let err = MITMProxyError.failedToStartListener("Terminator cancelled")
                                continuation.resume(throwing: err)
                            default:
                                break
                            }
                        }
                        termListener.start(queue: self.queue)
                    }
                } onCancel: {
                    termListener.cancel()
                }
            } catch {
                termListener.cancel()
                throw error
            }

            return registerTerminator(termListener, port: boundPort, cacheKey: cacheKey)
        }
        pendingTerminators[cacheKey] = task
        defer { pendingTerminators.removeValue(forKey: cacheKey) }
        let port = try await task.value
        if isStopped {
            throw MITMProxyError.failedToStartListener("Server stopped")
        }
        return port
    }

    private func registerTerminator(_ termListener: NWListener, port: UInt16, cacheKey: String) -> UInt16 {
        if isStopped || Task.isCancelled {
            termListener.cancel()
            return port
        }
        if let existing = terminators[cacheKey] {
            termListener.cancel()
            return existing.port
        }
        let token = registerShutdownListener(termListener)
        terminators[cacheKey] = (port, termListener, token)
        terminatorOrder.append(cacheKey)
        while terminatorOrder.count > maxTerminators {
            guard let evictIdx = terminatorOrder.firstIndex(where: {
                (activeTerminatorHandshakes[$0] ?? 0) == 0
            }) else {
                break
            }
            let evicted = terminatorOrder.remove(at: evictIdx)
            if let entry = terminators.removeValue(forKey: evicted) {
                entry.listener.cancel()
                unregisterShutdownListener(token: entry.token)
            }
        }
        return port
    }

    private func handleDecryptedHTTPSConnection(
        _ connection: NWConnection,
        targetHost: String,
        targetPort: Int
    ) {
        let token = UUID()
        activeConnections[token] = connection
        registerShutdownConnection(connection, token: token)
        let bundleID = config.bundleID
        let store = captureStore
        let didReceiveRequest = Mutex(false)
        let loggedHandshakeError = Mutex(false)
        let logTLSErrorIfNeeded: @Sendable (String) -> Void = { description in
            let shouldLog = !didReceiveRequest.withLock { $0 } &&
                loggedHandshakeError.withLock { already -> Bool in
                    guard !already else { return false }
                    already = true
                    return true
                }
            if shouldLog {
                let portSuffix = targetPort == 443 ? "" : ":\(targetPort)"
                let authorityHost = Self.formatAuthorityHost(targetHost)
                store.append(MITMCaptureEntry(
                    bundleID: bundleID,
                    method: "TLS",
                    scheme: "https",
                    host: targetHost,
                    port: targetPort,
                    path: "/",
                    urlString: "https://\(authorityHost)\(portSuffix)/",
                    statusCode: nil,
                    durationMs: 0,
                    disposition: .error,
                    errorDescription: description
                ))
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case let .failed(error):
                logTLSErrorIfNeeded(error.localizedDescription)
            case let .waiting(error):
                // Accepted server connections do not recover from .waiting; log and tear down.
                logTLSErrorIfNeeded(error.localizedDescription)
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)

        Task {
            defer {
                logTLSErrorIfNeeded("TLS handshake aborted before HTTP request")
                connection.cancel()
                Task { self.removeConnection(token: token) }
            }
            let stream = BufferedConnection(connection: connection)
            while !Task.isCancelled {
                do {
                    guard let headerData = try await stream.readHeaderBlock(),
                          let head = parseHTTPRequestHead(headerData) else {
                        logTLSErrorIfNeeded("TLS connection closed before HTTP request")
                        break
                    }
                    didReceiveRequest.withLock { $0 = true }
                    if Self.hasDuplicateHostHeaders(head.headers) {
                        try? await stream.writeAll(
                            Self.simpleResponse(code: 400, reason: "Bad Request", body: "Duplicate Host header")
                        )
                        break
                    }
                    if Self.shouldSend100Continue(headers: head.headerMap) {
                        try await stream.writeAll(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
                    }
                    let keepAlive = await forwardSingleRequest(
                        head,
                        target: ForwardTarget(
                            scheme: "https",
                            host: targetHost,
                            port: targetPort,
                            useTLS: true,
                            dispositionOnSuccess: .decrypted
                        ),
                        clientStream: stream
                    )
                    if !keepAlive { break }
                } catch {
                    logTLSErrorIfNeeded(error.localizedDescription)
                    break
                }
            }
        }
    }

    @discardableResult
    private func handlePlainHTTPRequest(
        _ req: ParsedHTTPRequestHead,
        clientStream: BufferedConnection
    ) async -> Bool {
        let parsed = Self.resolvePlainHTTPTarget(req.target, headers: req.headerMap)
        if parsed.host.isEmpty || parsed.port <= 0 || parsed.port > 65_535 {
            try? await clientStream.writeAll(
                Self.simpleResponse(code: 400, reason: "Bad Request", body: "Invalid HTTP target host")
            )
            return false
        }
        if let blockReason = isBlockedLoopbackOrSelfTarget(host: parsed.host, port: parsed.port) {
            try? await clientStream.writeAll(
                Self.simpleResponse(code: 403, reason: "Forbidden", body: blockReason)
            )
            let authorityHost = Self.formatAuthorityHost(parsed.host)
            captureStore.append(MITMCaptureEntry(
                bundleID: config.bundleID,
                method: req.method,
                scheme: "http",
                host: parsed.host,
                port: parsed.port,
                path: parsed.path,
                urlString: "http://\(authorityHost):\(parsed.port)\(parsed.path)",
                requestHeaders: req.headerMap,
                statusCode: 403,
                durationMs: 0,
                disposition: .blocked,
                errorDescription: blockReason
            ))
            return false
        }
        return await forwardSingleRequest(
            ParsedHTTPRequestHead(
                method: req.method,
                target: parsed.path,
                version: req.version,
                headers: req.headers,
                headerMap: req.headerMap
            ),
            target: ForwardTarget(
                scheme: "http",
                host: parsed.host,
                port: parsed.port,
                useTLS: false,
                dispositionOnSuccess: .forwarded
            ),
            clientStream: clientStream
        )
    }

    private struct ForwardTarget {
        let scheme: String
        let host: String
        let port: Int
        let useTLS: Bool
        let dispositionOnSuccess: TrafficDisposition
    }

    @discardableResult
    private func forwardSingleRequest(
        _ req: ParsedHTTPRequestHead,
        target: ForwardTarget,
        clientStream: BufferedConnection
    ) async -> Bool {
        let scheme = target.scheme
        let host = target.host
        let port = target.port
        let useTLS = target.useTLS
        let dispositionOnSuccess = target.dispositionOnSuccess
        let clockStart = ContinuousClock.now
        let currentConfig = config
        let defaultPort = useTLS ? 443 : 80
        let portSuffix = port == defaultPort ? "" : ":\(port)"
        let authorityHost = Self.formatAuthorityHost(host)
        let path = Self.normalizeOriginPath(from: req.target)
        let fullURL = "\(scheme)://\(authorityHost)\(portSuffix)\(path)"
        let captureLimit = currentConfig.captureBodies ? captureStore.maxBodyBytes : 0

        let reqFraming: HTTPBodyFraming
        do {
            reqFraming = try Self.determineRequestBodyFraming(headers: req.headers)
        } catch {
            let errBody = error.localizedDescription
            try? await clientStream.writeAll(Self.simpleResponse(code: 400, reason: "Bad Request", body: errBody))
            return false
        }

        if currentConfig.enableNetworkRules {
            let evaluator = NetworkRuleEvaluator(rawPatterns: currentConfig.blockedURLPatterns)
            if case let .block(action) = evaluator.evaluateDetailed(host: host, urlString: fullURL) {
                var capturedReq: StreamCaptureSummary?
                if captureLimit > 0 {
                    switch reqFraming {
                    case let .contentLength(len) where len > 0 && len <= captureLimit:
                        capturedReq = try? await clientStream.streamFixedLength(
                            count: len,
                            to: nil,
                            captureLimit: captureLimit
                        )
                    default:
                        break
                    }
                }
                let useMock200: Bool
                switch action {
                case .forceMock200:
                    useMock200 = true
                case .forceFail:
                    useMock200 = false
                case .defaultBlock:
                    useMock200 = currentConfig.networkBlockMock200
                }
                let statusCode: Int
                let reason: String
                let bodyText: String
                let contentType: String
                let disposition: TrafficDisposition
                if useMock200 {
                    statusCode = 200
                    reason = "OK"
                    bodyText = "{}"
                    contentType = "application/json"
                    disposition = .mocked200
                } else {
                    statusCode = 403
                    reason = "Forbidden"
                    bodyText = "Blocked by MacOver"
                    contentType = "text/plain"
                    disposition = .blocked
                }
                let rawResp = Self.simpleResponse(
                    code: statusCode,
                    reason: reason,
                    contentType: contentType,
                    body: bodyText
                )
                try? await clientStream.writeAll(rawResp)
                captureStore.append(MITMCaptureEntry(
                    bundleID: currentConfig.bundleID,
                    method: req.method,
                    scheme: scheme,
                    host: host,
                    port: port,
                    path: path,
                    urlString: fullURL,
                    requestHeaders: req.headerMap,
                    requestBody: currentConfig.captureBodies ? (capturedReq?.data ?? Data()) : nil,
                    requestBodyTruncated: capturedReq?.truncated ?? false,
                    statusCode: statusCode,
                    responseHeaders: ["Content-Type": contentType],
                    responseBody: currentConfig.captureBodies ? Data(bodyText.utf8) : nil,
                    durationMs: Self.elapsedMs(since: clockStart),
                    disposition: disposition
                ))
                return false
            }
        }

        let didWriteResponseHead = Mutex(false)
        var capturedReqSummary = StreamCaptureSummary(data: Data(), truncated: false)

        do {
            let connectHost = currentConfig.hostOverrides[host.lowercased()] ?? host
            let upstreamConn: NWConnection
            if useTLS {
                let uPort = UInt16(clamping: port)
                upstreamConn = try await connectTLS(
                    targetHost: host,
                    connectHost: connectHost,
                    sniHost: host,
                    port: uPort
                )
            } else {
                upstreamConn = try await connectTCP(
                    targetHost: host,
                    connectHost: connectHost,
                    port: UInt16(clamping: port)
                )
            }
            defer { upstreamConn.cancel() }

            let upstreamStream = BufferedConnection(connection: upstreamConn)
            let wireHead = Self.serializeRequestHeadForUpstream(
                req,
                host: host,
                portSuffix: portSuffix,
                path: path,
                framing: reqFraming
            )
            switch reqFraming {
            case .none, .closeDelimited:
                try await upstreamStream.writeAll(wireHead)
            case let .contentLength(len):
                capturedReqSummary = try await clientStream.streamFixedLength(
                    count: len,
                    to: upstreamStream,
                    captureLimit: captureLimit,
                    leadingWirePrefix: wireHead
                )
            case .chunked:
                try await upstreamStream.writeAll(wireHead)
                capturedReqSummary = try await clientStream.streamChunkedBody(
                    to: upstreamStream,
                    captureLimit: captureLimit
                )
            }

            var respHead: ParsedHTTPResponseHead
            while true {
                guard let respHeadData = try await upstreamStream.readHeaderBlock(),
                      let parsed = parseHTTPResponseHead(respHeadData) else {
                    throw MITMProxyError.upstreamConnectionFailed("Empty HTTP response from \(host)")
                }
                if (100..<200).contains(parsed.statusCode) && parsed.statusCode != 101 {
                    if parsed.statusCode != 100 {
                        let interimWire = Self.serializeResponseHeadForClient(
                            parsed,
                            method: req.method,
                            framing: .none
                        )
                        try await clientStream.writeAll(interimWire)
                    }
                    continue
                }
                respHead = parsed
                break
            }

            if respHead.statusCode == 101 {
                var upgradeWire = Self.serializeResponseHeadForClient(respHead, method: req.method, framing: .none)
                let upstreamExtra = await upstreamStream.drainRemainder()
                if !upstreamExtra.isEmpty {
                    upgradeWire.append(upstreamExtra)
                }
                didWriteResponseHead.withLock { $0 = true }
                try await clientStream.writeAll(upgradeWire)
                captureStore.append(MITMCaptureEntry(
                    bundleID: currentConfig.bundleID,
                    method: req.method,
                    scheme: scheme,
                    host: host,
                    port: port,
                    path: path,
                    urlString: fullURL,
                    requestHeaders: req.headerMap,
                    requestBody: currentConfig.captureBodies ? capturedReqSummary.data : nil,
                    requestBodyTruncated: capturedReqSummary.truncated,
                    statusCode: 101,
                    responseHeaders: respHead.headerMap,
                    responseBody: nil,
                    durationMs: Self.elapsedMs(since: clockStart),
                    disposition: dispositionOnSuccess
                ))
                await Self.pumpBidirectional(
                    client: clientStream.connection,
                    upstream: upstreamConn,
                    initialUpstreamBytes: await clientStream.drainRemainder()
                )
                return false
            }

            let respFraming = try Self.determineResponseBodyFraming(
                statusCode: respHead.statusCode,
                method: req.method,
                headers: respHead.headers
            )
            let wireRespHead = Self.serializeResponseHeadForClient(
                respHead,
                method: req.method,
                framing: respFraming
            )

            let capturedRespSummary: StreamCaptureSummary
            switch respFraming {
            case .none:
                didWriteResponseHead.withLock { $0 = true }
                try await clientStream.writeAll(wireRespHead)
                capturedRespSummary = StreamCaptureSummary(data: Data(), truncated: false)
            case let .contentLength(len):
                capturedRespSummary = try await upstreamStream.streamFixedLength(
                    count: len,
                    to: clientStream,
                    captureLimit: captureLimit,
                    leadingWirePrefix: wireRespHead,
                    onPrefixSent: {
                        didWriteResponseHead.withLock { $0 = true }
                    }
                )
            case .chunked:
                didWriteResponseHead.withLock { $0 = true }
                try await clientStream.writeAll(wireRespHead)
                capturedRespSummary = try await upstreamStream.streamChunkedBody(
                    to: clientStream,
                    captureLimit: captureLimit
                )
            case .closeDelimited:
                didWriteResponseHead.withLock { $0 = true }
                try await clientStream.writeAll(wireRespHead)
                capturedRespSummary = try await upstreamStream.streamUntilEOF(
                    to: clientStream,
                    captureLimit: captureLimit
                )
            }

            captureStore.append(MITMCaptureEntry(
                bundleID: currentConfig.bundleID,
                method: req.method,
                scheme: scheme,
                host: host,
                port: port,
                path: path,
                urlString: fullURL,
                requestHeaders: req.headerMap,
                requestBody: currentConfig.captureBodies ? capturedReqSummary.data : nil,
                requestBodyTruncated: capturedReqSummary.truncated,
                statusCode: respHead.statusCode,
                responseHeaders: respHead.headerMap,
                responseBody: currentConfig.captureBodies ? capturedRespSummary.data : nil,
                responseBodyTruncated: capturedRespSummary.truncated,
                durationMs: Self.elapsedMs(since: clockStart),
                disposition: dispositionOnSuccess
            ))

            if respFraming == .closeDelimited {
                return false
            }
            let connHdr = req.headerMap.first { $0.key.lowercased() == "connection" }?.value.lowercased()
            return connHdr != "close"
        } catch {
            let errBody = error.localizedDescription
            if !didWriteResponseHead.withLock({ $0 }) {
                try? await clientStream.writeAll(Self.simpleResponse(code: 502, reason: "Bad Gateway", body: errBody))
            } else {
                // Abort client connection immediately so truncated streams never appear as valid 200 OK.
                clientStream.connection.cancel()
            }
            captureStore.append(MITMCaptureEntry(
                bundleID: currentConfig.bundleID,
                method: req.method,
                scheme: scheme,
                host: host,
                port: port,
                path: path,
                urlString: fullURL,
                requestHeaders: req.headerMap,
                requestBody: currentConfig.captureBodies ? capturedReqSummary.data : nil,
                requestBodyTruncated: capturedReqSummary.truncated,
                statusCode: didWriteResponseHead.withLock({ $0 }) ? nil : 502,
                durationMs: Self.elapsedMs(since: clockStart),
                disposition: .error,
                errorDescription: errBody
            ))
            return false
        }
    }

    private func validateResolvedRemoteEndpoint(
        of conn: NWConnection,
        targetHost: String,
        allowInternalTerminator: Bool
    ) throws {
        guard !allowInternalTerminator else { return }
        guard let remoteEndpoint = conn.currentPath?.remoteEndpoint,
              case let .hostPort(host, port) = remoteEndpoint else {
            return
        }
        let resolvedHost: String
        switch host {
        case let .ipv4(addr):
            resolvedHost = "\(addr)"
        case let .ipv6(addr):
            resolvedHost = "\(addr)"
        case let .name(name, _):
            resolvedHost = name
        @unknown default:
            return
        }
        guard Self.isLoopbackHost(resolvedHost) else { return }
        let resolvedPort = port.rawValue
        if boundListenPort > 0 && resolvedPort == boundListenPort {
            conn.cancel()
            throw MITMProxyError.upstreamConnectionFailed("Blocked resolved self-proxy loop")
        }
        if terminators.values.contains(where: { $0.port == resolvedPort }) {
            conn.cancel()
            throw MITMProxyError.upstreamConnectionFailed("Blocked resolved self-proxy loop")
        }
        if config.blockLoopbackTargets && config.hostOverrides[targetHost.lowercased()] == nil {
            conn.cancel()
            throw MITMProxyError.upstreamConnectionFailed(
                "Blocked resolved loopback/link-local destination: \(resolvedHost)"
            )
        }
    }

    func connectTCP(
        targetHost: String,
        connectHost: String,
        port: UInt16,
        allowInternalTerminator: Bool = false
    ) async throws -> NWConnection {
        let params = NWParameters.tcp
        Self.applyUpstreamProxyIfAvailable(
            to: params,
            targetHost: targetHost,
            listenPort: boundListenPort,
            hostOverrides: config.hostOverrides
        )
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .http
        let conn = NWConnection(host: NWEndpoint.Host(connectHost), port: nwPort, using: params)
        try await waitForReady(conn)
        try validateResolvedRemoteEndpoint(
            of: conn,
            targetHost: targetHost,
            allowInternalTerminator: allowInternalTerminator
        )
        return conn
    }

    private func connectTLS(
        targetHost: String,
        connectHost: String,
        sniHost: String,
        port: UInt16
    ) async throws -> NWConnection {
        let tlsOptions = NWProtocolTLS.Options()
        // RFC 6066 §3: literal IPv4 and IPv6 addresses are forbidden in TLS SNI HostName.
        if !sniHost.isEmpty && !Self.isIPLiteral(sniHost) {
            sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, sniHost)
        }
        sec_protocol_options_add_tls_application_protocol(tlsOptions.securityProtocolOptions, "http/1.1")

        let customAnchors = upstreamCustomAnchorDERs.compactMap { der in
            SecCertificateCreateWithData(nil, der as CFData)
        }
        if !customAnchors.isEmpty {
            sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, secTrust, completion in
                let trustRef = sec_trust_copy_ref(secTrust).takeRetainedValue()
                SecTrustSetAnchorCertificates(trustRef, customAnchors as CFArray)
                SecTrustSetAnchorCertificatesOnly(trustRef, false)
                var cfErr: CFError?
                let ok = SecTrustEvaluateWithError(trustRef, &cfErr)
                completion(ok)
            }, queue)
        }

        let params = NWParameters(tls: tlsOptions, tcp: .init())
        Self.applyUpstreamProxyIfAvailable(
            to: params,
            targetHost: targetHost,
            listenPort: boundListenPort,
            hostOverrides: config.hostOverrides
        )
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .https
        let conn = NWConnection(host: NWEndpoint.Host(connectHost), port: nwPort, using: params)
        try await waitForReady(conn)
        try validateResolvedRemoteEndpoint(
            of: conn,
            targetHost: targetHost,
            allowInternalTerminator: false
        )
        return conn
    }

    static func isIPLiteral(_ host: String) -> Bool {
        var stripped = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.hasPrefix("[") && stripped.hasSuffix("]") {
            stripped = String(stripped.dropFirst().dropLast())
        }
        if let pct = stripped.firstIndex(of: "%") {
            stripped = String(stripped[..<pct])
        }
        var ipv4 = in_addr()
        if Darwin.inet_pton(AF_INET, stripped, &ipv4) == 1 {
            return true
        }
        var ipv6 = in6_addr()
        return Darwin.inet_pton(AF_INET6, stripped, &ipv6) == 1
    }

    static func formatAuthorityHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(":") && !(trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            return "[\(trimmed)]"
        }
        return trimmed
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        var lower = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("[") && lower.hasSuffix("]") {
            lower = String(lower.dropFirst().dropLast())
        }
        if let pct = lower.firstIndex(of: "%") {
            lower = String(lower[..<pct])
        }
        while lower.hasSuffix(".") {
            lower.removeLast()
        }
        guard !lower.isEmpty else { return false }
        if lower == "localhost"
            || lower.hasSuffix(".localhost")
            || lower == "::1"
            || lower == "0.0.0.0"
            || lower == "::" {
            return true
        }
        var ipv4 = in_addr()
        if Darwin.inet_pton(AF_INET, lower, &ipv4) == 1 || Darwin.inet_aton(lower, &ipv4) == 1 {
            let hostOrder = UInt32(bigEndian: ipv4.s_addr)
            let firstOctet = hostOrder >> 24
            // Block 127.0.0.0/8 (loopback), 0.0.0.0/8 ("this" host), and 169.254.0.0/16 (link-local / cloud metadata).
            return firstOctet == 127
                || firstOctet == 0
                || (hostOrder & 0xFFFF_0000) == 0xA9FE_0000
        }
        var ipv6 = in6_addr()
        if Darwin.inet_pton(AF_INET6, lower, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            if bytes.count == 16 {
                // Link-local fe80::/10
                if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 {
                    return true
                }
                let first10Zero = bytes[0..<10].allSatisfy { $0 == 0 }
                let first12Zero = first10Zero && bytes[10] == 0 && bytes[11] == 0
                if first12Zero {
                    // :: (unspecified) or ::1 (loopback)
                    if bytes[12] == 0 && bytes[13] == 0 && bytes[14] == 0 && (bytes[15] == 0 || bytes[15] == 1) {
                        return true
                    }
                    // IPv4-compatible ::a.b.c.d (127.0.0.0/8, 0.0.0.0/8, 169.254.0.0/16)
                    if bytes[12] == 127 || bytes[12] == 0 || (bytes[12] == 169 && bytes[13] == 254) {
                        return true
                    }
                }
                // IPv4-mapped IPv6 ::ffff:a.b.c.d (127.0.0.0/8, 0.0.0.0/8, 169.254.0.0/16)
                if first10Zero && bytes[10] == 0xFF && bytes[11] == 0xFF {
                    if bytes[12] == 127 || bytes[12] == 0 || (bytes[12] == 169 && bytes[13] == 254) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func hostMatchesProxyExceptions(_ host: String, exceptions: [String]) -> Bool {
        let lower = host.lowercased()
        for rawPattern in exceptions {
            let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if pattern.isEmpty { continue }
            if pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst(1))
                let bare = String(pattern.dropFirst(2))
                if lower == bare || lower.hasSuffix(suffix) {
                    return true
                }
            } else if lower == pattern {
                return true
            }
        }
        return false
    }

    private static func applyUpstreamProxyIfAvailable(
        to params: NWParameters,
        targetHost: String,
        listenPort: UInt16,
        hostOverrides: [String: String]
    ) {
        let lowerTarget = targetHost.lowercased()
        if hostOverrides[lowerTarget] != nil || isLoopbackHost(lowerTarget) {
            return
        }
        guard let proxyDict = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return
        }
        if let exceptions = proxyDict["ExceptionsList"] as? [String],
           hostMatchesProxyExceptions(lowerTarget, exceptions: exceptions) {
            return
        }

        func validProxyEndpoint(enableKey: String, hostKey: String, portKey: String) -> (String, UInt16)? {
            guard (proxyDict[enableKey] as? NSNumber)?.boolValue == true,
                  let pHost = (proxyDict[hostKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !pHost.isEmpty,
                  let rawPort = (proxyDict[portKey] as? NSNumber)?.intValue,
                  rawPort > 0 && rawPort <= 65_535 else {
                return nil
            }
            if listenPort > 0 && UInt16(rawPort) == listenPort && isLoopbackHost(pHost) {
                return nil
            }
            return (pHost, UInt16(rawPort))
        }

        var proxyConfig: ProxyConfiguration?
        if let (pHost, pPort) = validProxyEndpoint(
            enableKey: "HTTPSEnable", hostKey: "HTTPSProxy", portKey: "HTTPSPort"
        ), let nwPort = NWEndpoint.Port(rawValue: pPort) {
            proxyConfig = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .init(pHost), port: nwPort))
        } else if let (pHost, pPort) = validProxyEndpoint(
            enableKey: "HTTPEnable", hostKey: "HTTPProxy", portKey: "HTTPPort"
        ), let nwPort = NWEndpoint.Port(rawValue: pPort) {
            proxyConfig = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .init(pHost), port: nwPort))
        } else if let (pHost, pPort) = validProxyEndpoint(
            enableKey: "SOCKSEnable", hostKey: "SOCKSProxy", portKey: "SOCKSPort"
        ), let nwPort = NWEndpoint.Port(rawValue: pPort) {
            proxyConfig = ProxyConfiguration(socksv5Proxy: .hostPort(host: .init(pHost), port: nwPort))
        }

        guard var resolvedProxy = proxyConfig else { return }
        resolvedProxy.allowFailover = true
        let privacyCtx = NWParameters.PrivacyContext(description: "MacOverMITMUpstream")
        privacyCtx.proxyConfigurations = [resolvedProxy]
        params.setPrivacyContext(privacyCtx)
    }

    private func waitForReady(_ connection: NWConnection, timeoutSeconds: Double = 15.0) async throws {
        if isStopped {
            connection.cancel()
            throw MITMProxyError.upstreamConnectionFailed("Server stopped")
        }
        let token = UUID()
        activeConnections[token] = connection
        registerShutdownConnection(connection, token: token)
        defer {
            activeConnections.removeValue(forKey: token)
            unregisterShutdownConnection(token: token)
        }

        let timeoutTask = Task { [weak connection] in
            try await Task.sleep(for: .seconds(timeoutSeconds))
            connection?.cancel()
        }
        defer { timeoutTask.cancel() }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let settled = Mutex(false)
                    connection.stateUpdateHandler = { state in
                        let shouldSettle = settled.withLock { done -> Bool in
                            guard !done else { return false }
                            switch state {
                            case .ready, .failed, .cancelled, .waiting:
                                done = true
                                return true
                            default:
                                return false
                            }
                        }
                        guard shouldSettle else { return }
                        switch state {
                        case .ready:
                            continuation.resume()
                        case let .waiting(error):
                            connection.cancel()
                            continuation.resume(
                                throwing: MITMProxyError.upstreamConnectionFailed(error.localizedDescription)
                            )
                        case let .failed(error):
                            connection.cancel()
                            continuation.resume(
                                throwing: MITMProxyError.upstreamConnectionFailed(error.localizedDescription)
                            )
                        case .cancelled:
                            continuation.resume(
                                throwing: MITMProxyError.upstreamConnectionFailed("Connection cancelled")
                            )
                        default:
                            break
                        }
                    }
                    connection.start(queue: self.queue)
                }
            } onCancel: {
                connection.cancel()
            }
        } catch {
            connection.cancel()
            throw error
        }
    }

    private static func hasBareCRorLF(_ string: String) -> Bool {
        string.unicodeScalars.contains { $0.value == 0x0A || $0.value == 0x0D }
    }

    private static func isValidHeaderName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return v > 0x20 && v < 0x7F && v != 0x3A // printable ASCII, no space/CTL/colon
        }
    }

    static func hasDuplicateHostHeaders(_ headers: [(name: String, value: String)]) -> Bool {
        var hostCount = 0
        for header in headers where header.name.lowercased() == "host" {
            hostCount += 1
            if hostCount > 1 {
                return true
            }
        }
        return false
    }

    static func appendHeaderMapValue(_ value: String, forName name: String, into map: inout [String: String]) {
        let lowerName = name.lowercased()
        if let existingKey = map.keys.first(where: { $0.lowercased() == lowerName }),
           let existing = map[existingKey] {
            if lowerName == "set-cookie" {
                map[existingKey] = existing + "\n" + value
            } else {
                map[existingKey] = existing + ", " + value
            }
        } else {
            map[name] = value
        }
    }

    private func parseHTTPRequestHead(_ data: Data) -> ParsedHTTPRequestHead? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !Self.hasBareCRorLF(requestLine) else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let target = String(parts[1])
        let version = parts.count >= 3 ? String(parts[2]) : "HTTP/1.1"

        var headers: [(String, String)] = []
        var map: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            guard !Self.hasBareCRorLF(line),
                  let colon = line.firstIndex(of: ":") else {
                return nil
            }
            let name = String(line[..<colon])
            guard Self.isValidHeaderName(name) else { return nil }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
            Self.appendHeaderMapValue(value, forName: name, into: &map)
        }
        return ParsedHTTPRequestHead(
            method: method,
            target: target,
            version: version,
            headers: headers,
            headerMap: map
        )
    }

    private func parseHTTPResponseHead(_ data: Data) -> ParsedHTTPResponseHead? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first, !Self.hasBareCRorLF(statusLine) else { return nil }
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let code = Int(parts[1]) else { return nil }

        let version = String(parts[0])
        let reason = parts.count >= 3 ? String(parts[2]) : HTTPURLResponse.localizedString(forStatusCode: code)
        var headers: [(String, String)] = []
        var map: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            guard !Self.hasBareCRorLF(line),
                  let colon = line.firstIndex(of: ":") else {
                return nil
            }
            let name = String(line[..<colon])
            guard Self.isValidHeaderName(name) else { return nil }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
            Self.appendHeaderMapValue(value, forName: name, into: &map)
        }
        return ParsedHTTPResponseHead(
            statusCode: code,
            reasonPhrase: reason,
            version: version,
            headers: headers,
            headerMap: map
        )
    }

    private static func parseNonNegativeContentLength(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }),
              let length = Int(trimmed),
              length >= 0 else {
            return nil
        }
        return length
    }

    private static func validatedSingleContentLength(
        from headers: [(name: String, value: String)],
        isRequest: Bool
    ) throws -> Int? {
        let clValues = headers.filter { $0.name.lowercased() == "content-length" }.map(\.value)
        guard !clValues.isEmpty else { return nil }
        var resolvedLength: Int?
        for rawHeader in clValues {
            let parts = rawHeader.split(separator: ",", omittingEmptySubsequences: false)
            for part in parts {
                guard let parsed = parseNonNegativeContentLength(String(part)) else {
                    if isRequest {
                        throw MITMProxyError.invalidHTTPRequest("Invalid Content-Length: \(rawHeader)")
                    }
                    throw MITMProxyError.upstreamConnectionFailed("Invalid upstream Content-Length: \(rawHeader)")
                }
                if let existing = resolvedLength, existing != parsed {
                    if isRequest {
                        throw MITMProxyError.invalidHTTPRequest("Conflicting Content-Length headers")
                    }
                    throw MITMProxyError.upstreamConnectionFailed("Conflicting upstream Content-Length headers")
                }
                resolvedLength = parsed
            }
        }
        return resolvedLength
    }

    private static func determineRequestBodyFraming(
        headers: [(name: String, value: String)]
    ) throws -> HTTPBodyFraming {
        let teValues = headers.filter { $0.name.lowercased() == "transfer-encoding" }.map { $0.value.lowercased() }
        let clLength = try validatedSingleContentLength(from: headers, isRequest: true)
        if !teValues.isEmpty {
            // RFC 9112 §6.3: reject requests carrying both Transfer-Encoding and Content-Length (smuggling defense).
            if clLength != nil {
                throw MITMProxyError.invalidHTTPRequest(
                    "Ambiguous request with both Transfer-Encoding and Content-Length"
                )
            }
            if teValues.contains(where: { $0.contains("chunked") }) {
                return .chunked
            }
            throw MITMProxyError.invalidHTTPRequest("Unsupported Transfer-Encoding")
        }
        if let clLength {
            return .contentLength(clLength)
        }
        return .none
    }

    private static func determineResponseBodyFraming(
        statusCode: Int,
        method: String,
        headers: [(name: String, value: String)]
    ) throws -> HTTPBodyFraming {
        if method.uppercased() == "HEAD" || (100..<200).contains(statusCode) || statusCode == 204 || statusCode == 304 {
            return .none
        }
        let teValues = headers.filter { $0.name.lowercased() == "transfer-encoding" }.map { $0.value.lowercased() }
        let clLength = try validatedSingleContentLength(from: headers, isRequest: false)
        if teValues.contains(where: { $0.contains("chunked") }) {
            return .chunked
        }
        if let clLength {
            return .contentLength(clLength)
        }
        return .closeDelimited
    }

    private static func shouldSend100Continue(headers: [String: String]) -> Bool {
        guard let expect = headers.first(where: { $0.key.lowercased() == "expect" })?.value,
              expect.lowercased().contains("100-continue") else {
            return false
        }
        if let te = headers.first(where: { $0.key.lowercased() == "transfer-encoding" })?.value.lowercased(),
           te.contains("chunked") {
            return true
        }
        if let cl = headers.first(where: { $0.key.lowercased() == "content-length" })?.value,
           let len = parseNonNegativeContentLength(cl), len > 0 {
            return true
        }
        return false
    }

    private static func normalizeOriginPath(from target: String) -> String {
        let lower = target.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://"),
           let components = URLComponents(string: target) {
            var path = components.percentEncodedPath
            if path.isEmpty {
                path = "/"
            }
            if let query = components.percentEncodedQuery {
                path += "?" + query
            }
            return path
        }
        return target.hasPrefix("/") ? target : "/\(target)"
    }

    private static func serializeRequestHeadForUpstream(
        _ req: ParsedHTTPRequestHead,
        host: String,
        portSuffix: String,
        path: String,
        framing: HTTPBodyFraming
    ) -> Data {
        var headerLines = ["\(req.method) \(path) HTTP/1.1"]
        var hasHost = false
        var isWebSocketUpgrade = false
        let hasUpgradeHeader = req.headers.contains { $0.name.lowercased() == "upgrade" }
        if hasUpgradeHeader,
           let connHeader = req.headers.first(where: { $0.name.lowercased() == "connection" })?.value.lowercased(),
           connHeader.contains("upgrade") {
            isWebSocketUpgrade = true
        }
        for (name, value) in req.headers {
            let lower = name.lowercased()
            if lower == "proxy-connection" || lower == "proxy-authorization" ||
                lower == "transfer-encoding" || lower == "content-length" ||
                lower == "connection" || lower == "expect" {
                continue
            }
            if lower == "host" {
                hasHost = true
            }
            headerLines.append("\(name): \(value)")
        }
        if !hasHost {
            headerLines.append("Host: \(formatAuthorityHost(host))\(portSuffix)")
        }
        headerLines.append(isWebSocketUpgrade ? "Connection: Upgrade" : "Connection: close")
        switch framing {
        case .chunked:
            headerLines.append("Transfer-Encoding: chunked")
        case let .contentLength(length):
            headerLines.append("Content-Length: \(length)")
        case .none, .closeDelimited:
            let upperMethod = req.method.uppercased()
            if upperMethod == "POST" || upperMethod == "PUT" || upperMethod == "PATCH" {
                headerLines.append("Content-Length: 0")
            }
        }
        return Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private static func serializeResponseHeadForClient(
        _ resp: ParsedHTTPResponseHead,
        method: String,
        framing: HTTPBodyFraming
    ) -> Data {
        var headerLines = ["HTTP/1.1 \(resp.statusCode) \(resp.reasonPhrase)"]
        if resp.statusCode == 101 {
            for (name, value) in resp.headers {
                let lower = name.lowercased()
                if lower == "transfer-encoding" || lower == "content-length" {
                    continue
                }
                headerLines.append("\(name): \(value)")
            }
            return Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        }

        let isHead = method.uppercased() == "HEAD"

        for (name, value) in resp.headers {
            let lower = name.lowercased()
            if lower == "transfer-encoding" || lower == "connection" {
                continue
            }
            if lower == "content-length" && !isHead {
                continue
            }
            headerLines.append("\(name): \(value)")
        }

        switch framing {
        case .none:
            break
        case let .contentLength(length):
            headerLines.append("Content-Length: \(length)")
        case .chunked:
            headerLines.append("Transfer-Encoding: chunked")
        case .closeDelimited:
            break
        }

        if !(100..<200).contains(resp.statusCode) {
            headerLines.append(framing == .closeDelimited ? "Connection: close" : "Connection: keep-alive")
        }
        return Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private static func simpleResponse(
        code: Int,
        reason: String,
        contentType: String = "text/plain",
        body: String
    ) -> Data {
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(code) \(reason)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(bodyData.count)\r\n" +
            "Connection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(bodyData)
        return out
    }

    private static func parseHostPort(_ authority: String, defaultPort: Int) -> (host: String, port: Int) {
        let trimmed = authority.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["), let closeBracket = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeBracket])
            let after = trimmed[trimmed.index(after: closeBracket)...]
            if after.hasPrefix(":"), let port = Int(after.dropFirst()) {
                return (host, port)
            }
            return (host, defaultPort)
        }
        if let colon = trimmed.lastIndex(of: ":"), let port = Int(trimmed[trimmed.index(after: colon)...]) {
            return (String(trimmed[..<colon]), port)
        }
        return (trimmed, defaultPort)
    }

    private static func resolvePlainHTTPTarget(
        _ target: String,
        headers: [String: String]
    ) -> (host: String, port: Int, path: String) {
        if let components = URLComponents(string: target), let host = components.host, !host.isEmpty {
            let port = components.port ?? 80
            var path = components.percentEncodedPath
            if path.isEmpty { path = "/" }
            if let query = components.percentEncodedQuery {
                path += "?" + query
            }
            return (host, port, path)
        }
        let hostHeader = headers.first { $0.key.lowercased() == "host" }?.value ?? ""
        let (host, port) = parseHostPort(hostHeader, defaultPort: 80)
        return (host, port, target.hasPrefix("/") ? target : "/\(target)")
    }

    private static func elapsedMs(since start: ContinuousClock.Instant) -> Double {
        let dur = start.duration(to: .now)
        return Double(dur.components.seconds) * 1000.0 + Double(dur.components.attoseconds) / 1e15
    }

    private static func pumpBidirectional(
        client: NWConnection,
        upstream: NWConnection,
        initialUpstreamBytes: Data
    ) async {
        if !initialUpstreamBytes.isEmpty {
            await sendAsync(initialUpstreamBytes, on: upstream)
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await copyLoop(from: client, to: upstream)
            }
            group.addTask {
                await copyLoop(from: upstream, to: client)
            }
            await group.next()
            group.cancelAll()
            client.cancel()
            upstream.cancel()
        }
    }

    private static func copyLoop(from src: NWConnection, to dst: NWConnection) async {
        while !Task.isCancelled {
            let result: (data: Data?, isComplete: Bool) = await withCheckedContinuation { continuation in
                src.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    if error != nil {
                        continuation.resume(returning: (nil, true))
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: (data, isComplete))
                    } else if isComplete {
                        continuation.resume(returning: (nil, true))
                    } else {
                        continuation.resume(returning: (nil, true))
                    }
                }
            }
            if let chunk = result.data, !chunk.isEmpty {
                let ok = await sendAsync(chunk, on: dst, isComplete: result.isComplete)
                if !ok || result.isComplete { break }
            } else {
                if result.isComplete {
                    _ = await sendAsync(nil, on: dst, isComplete: true)
                }
                break
            }
        }
    }

    @discardableResult
    private static func sendAsync(_ data: Data?, on connection: NWConnection, isComplete: Bool = false) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(
                content: data,
                contentContext: .defaultMessage,
                isComplete: isComplete,
                completion: .contentProcessed { error in
                    continuation.resume(returning: error == nil)
                }
            )
        }
    }
}
