import CFNetwork
import CryptoKit
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
    private enum PatternKind: Sendable {
        case domain(String)
        case suffix(String)
        case keyword(String)
        case urlPrefix(String)
        case regex(String)
    }

    private struct CompiledRule: Sendable {
        let isAllow: Bool
        let kind: PatternKind
    }

    private let rules: [CompiledRule]

    public init(rawPatterns: [String]) {
        var compiled: [CompiledRule] = []
        for raw in rawPatterns {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard NetworkRuleParser.isImportableRuleLine(trimmed),
                  NetworkRuleParser.isRuleEnabled(trimmed) else {
                continue
            }
            let meta = NetworkRuleParser.classifyRule(trimmed)
            var expr = NetworkRuleParser.stripInlineComment(meta.body)
            if expr.hasPrefix("@@") {
                expr = String(expr.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if expr.hasPrefix("!") {
                expr = String(expr.dropFirst(1)).trimmingCharacters(in: .whitespaces)
            }

            if let comma = expr.firstIndex(of: ",") {
                let kindToken = expr[..<comma].trimmingCharacters(in: .whitespaces).uppercased()
                let restParts = expr[expr.index(after: comma)...].split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard let value = restParts.first, !value.isEmpty else { continue }
                switch kindToken {
                case "URL-REGEX", "REGEX":
                    compiled.append(CompiledRule(isAllow: meta.isAllow, kind: .regex(value)))
                case "DOMAIN-SUFFIX", "HOST-SUFFIX":
                    compiled.append(CompiledRule(isAllow: meta.isAllow, kind: .suffix(value.lowercased())))
                case "DOMAIN-KEYWORD", "HOST-KEYWORD":
                    compiled.append(CompiledRule(isAllow: meta.isAllow, kind: .keyword(value.lowercased())))
                default:
                    compiled.append(CompiledRule(isAllow: meta.isAllow, kind: .domain(value.lowercased())))
                }
            } else if expr.hasPrefix("^") {
                compiled.append(CompiledRule(isAllow: meta.isAllow, kind: .regex(expr)))
            } else if expr.hasPrefix("/"), expr.hasSuffix("/"), expr.count > 2 {
                compiled.append(CompiledRule(isAllow: meta.isAllow, kind: .regex(String(expr.dropFirst().dropLast()))))
            } else {
                if expr.hasPrefix("||") {
                    expr = String(expr.dropFirst(2))
                }
                if expr.hasSuffix("^") {
                    expr = String(expr.dropLast())
                }
                let lower = expr.lowercased()
                if lower.contains("/") {
                    compiled.append(CompiledRule(isAllow: meta.isAllow, kind: .urlPrefix(lower)))
                } else if lower.hasPrefix("*.") {
                    compiled.append(CompiledRule(isAllow: meta.isAllow, kind: .suffix(String(lower.dropFirst(2)))))
                } else if lower.hasPrefix(".") {
                    compiled.append(CompiledRule(isAllow: meta.isAllow, kind: .suffix(String(lower.dropFirst()))))
                } else if !lower.isEmpty {
                    compiled.append(CompiledRule(isAllow: meta.isAllow, kind: .domain(lower)))
                }
            }
        }
        self.rules = compiled
    }

    public func evaluate(host: String, urlString: String) -> NetworkRuleMatchResult {
        let lowerHost = host.lowercased()
        let lowerURL = urlString.lowercased()
        var blocked = false

        for rule in rules {
            guard matches(rule.kind, host: lowerHost, url: lowerURL) else { continue }
            if rule.isAllow {
                return .allow
            }
            blocked = true
        }
        return blocked ? .block : .pass
    }

    private func matches(_ kind: PatternKind, host: String, url: String) -> Bool {
        switch kind {
        case let .domain(target):
            return host == target || host.hasSuffix("." + target)
        case let .suffix(suffix):
            return host == suffix || host.hasSuffix("." + suffix)
        case let .keyword(kw):
            return url.contains(kw)
        case let .urlPrefix(prefix):
            return url.contains(prefix)
        case let .regex(pattern):
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return false
            }
            let range = NSRange(url.startIndex..<url.endIndex, in: url)
            return regex.firstMatch(in: url, range: range) != nil
        }
    }
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
                return buffer.isEmpty ? nil : nil
            }
            buffer.append(chunk)
        }
    }

    func readExact(count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        while buffer.count < count {
            let chunk = try await receiveChunk()
            if chunk.isEmpty {
                break
            }
            buffer.append(chunk)
        }
        let takeCount = min(count, buffer.count)
        let out = Data(buffer.prefix(takeCount))
        buffer.removeFirst(takeCount)
        return out
    }

    func readLine() async throws -> String? {
        let crlf = Data([0x0D, 0x0A])
        while true {
            if let range = buffer.range(of: crlf) {
                let lineData = buffer[..<range.lowerBound]
                buffer.removeSubrange(..<range.upperBound)
                return String(data: Data(lineData), encoding: .utf8) ?? ""
            }
            let chunk = try await receiveChunk()
            if chunk.isEmpty {
                if buffer.isEmpty { return nil }
                let rem = String(data: buffer, encoding: .utf8)
                buffer.removeAll()
                return rem
            }
            buffer.append(chunk)
        }
    }

    func readChunkedBody() async throws -> Data {
        var out = Data()
        while true {
            guard let sizeLine = try await readLine() else { break }
            let sizeToken = sizeLine.split(separator: ";", maxSplits: 1).first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            guard let chunkSize = Int(sizeToken, radix: 16) else {
                throw MITMProxyError.invalidHTTPRequest("Invalid chunk length: \(sizeLine)")
            }
            if chunkSize == 0 {
                while let trailer = try await readLine(), !trailer.isEmpty {}
                break
            }
            let payload = try await readExact(count: chunkSize)
            out.append(payload)
            _ = try await readExact(count: 2) // trailing CRLF
        }
        return out
    }

    func readUntilEOF() async throws -> Data {
        var out = buffer
        buffer.removeAll()
        while true {
            do {
                let chunk = try await receiveChunk()
                if chunk.isEmpty {
                    break
                }
                out.append(chunk)
            } catch {
                if !out.isEmpty {
                    break
                }
                throw error
            }
        }
        return out
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

private struct ParsedHTTPRequest {
    let method: String
    let target: String
    let version: String
    let headers: [(name: String, value: String)]
    let headerMap: [String: String]
    let body: Data
}

private struct ParsedHTTPResponse {
    let statusCode: Int
    let reasonPhrase: String
    let version: String
    let headers: [(name: String, value: String)]
    let headerMap: [String: String]
    let body: Data
}

public actor LocalMITMProxyServer {
    private let leafIssuer: X509LeafIssuer
    public let captureStore: TrafficCaptureStore
    private let upstreamTrustOverrideDER: Data?

    private var config: MITMServerConfiguration
    private let queue = DispatchQueue(label: "app.makedie.MacOver.MITMProxy", qos: .userInitiated)
    private var listener: NWListener?
    private var boundListenPort: UInt16 = 0
    private var isStopped = false
    private var activeConnections: [UUID: NWConnection] = [:]
    private var terminators: [String: (port: UInt16, listener: NWListener)] = [:]
    private var pendingTerminators: [String: Task<UInt16, Error>] = [:]
    private var terminatorOrder: [String] = []
    private let maxTerminators = 256

    public init(
        rootCertificateDER: Data,
        rootPrivateKeyDER: Data,
        configuration: MITMServerConfiguration,
        captureStore: TrafficCaptureStore? = nil,
        upstreamTrustOverrideDER: Data? = nil
    ) throws {
        self.leafIssuer = try X509LeafIssuer(
            rootCertificateDER: rootCertificateDER,
            rootPrivateKeyDER: rootPrivateKeyDER
        )
        self.config = configuration
        self.captureStore = captureStore ?? TrafficCaptureStore(bundleID: configuration.bundleID)
        self.upstreamTrustOverrideDER = upstreamTrustOverrideDER
    }

    public func updateConfiguration(_ newConfig: MITMServerConfiguration) {
        self.config = newConfig
    }

    @discardableResult
    public func start() async throws -> UInt16 {
        if let existing = listener, let port = existing.port?.rawValue {
            return port
        }
        isStopped = false

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
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

        if isStopped {
            newListener.cancel()
            throw MITMProxyError.failedToStartListener("Server stopped during startup")
        }
        self.listener = newListener
        self.boundListenPort = boundPort
        return boundPort
    }

    public func stop() {
        isStopped = true
        listener?.cancel()
        listener = nil
        boundListenPort = 0
        for pending in pendingTerminators.values {
            pending.cancel()
        }
        pendingTerminators.removeAll()
        for conn in activeConnections.values {
            conn.cancel()
        }
        activeConnections.removeAll()
        for entry in terminators.values {
            entry.listener.cancel()
        }
        terminators.removeAll()
        terminatorOrder.removeAll()
    }

    private func acceptClientConnection(_ connection: NWConnection) {
        let token = UUID()
        activeConnections[token] = connection
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
    }

    private func handleProxyClient(_ connection: NWConnection) async {
        let stream = BufferedConnection(connection: connection)
        let connectStart = ContinuousClock.now
        var activeConnectTarget: (host: String, port: Int)?
        do {
            while !Task.isCancelled {
                guard let headerData = try await stream.readHeaderBlock(),
                      let req = parseHTTPRequestHead(headerData, body: Data()) else {
                    return
                }

                if req.method.uppercased() == "CONNECT" {
                    let (host, port) = Self.parseHostPort(req.target, defaultPort: 443)
                    guard !host.isEmpty else {
                        let resp = Self.simpleResponse(code: 400, reason: "Bad Request", body: "Invalid CONNECT target")
                        try? await stream.writeAll(resp)
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
                let body = try await readBody(for: req.headerMap, from: stream)
                let fullReq = ParsedHTTPRequest(
                    method: req.method,
                    target: req.target,
                    version: req.version,
                    headers: req.headers,
                    headerMap: req.headerMap,
                    body: body
                )
                let keepAlive = await handlePlainHTTPRequest(fullReq, clientStream: stream)
                if !keepAlive {
                    return
                }
            }
        } catch {
            if let target = activeConnectTarget {
                let portSuffix = target.port == 443 ? "" : ":\(target.port)"
                let errMsg = error.localizedDescription
                try? await stream.writeAll(Self.simpleResponse(code: 502, reason: "Bad Gateway", body: errMsg))
                captureStore.append(MITMCaptureEntry(
                    bundleID: config.bundleID,
                    method: "CONNECT",
                    scheme: "https",
                    host: target.host,
                    port: target.port,
                    path: "/",
                    urlString: "https://\(target.host)\(portSuffix)/",
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
        let fullURL = "https://\(host)\(port == 443 ? "" : ":\(port)")/"
        if currentConfig.enableNetworkRules {
            let evaluator = NetworkRuleEvaluator(rawPatterns: currentConfig.blockedURLPatterns)
            if evaluator.evaluate(host: host, urlString: fullURL) == .block {
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
        let terminatorPort = try await getOrCreateTerminator(host: host, upstreamPort: port)
        let bridgeConn = try await connectTCP(
            targetHost: "127.0.0.1",
            connectHost: "127.0.0.1",
            port: terminatorPort
        )
        defer { bridgeConn.cancel() }

        try await clientStream.writeAll(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
        let initialClientData = await clientStream.drainRemainder()
        await Self.pumpBidirectional(
            client: clientStream.connection,
            upstream: bridgeConn,
            initialUpstreamBytes: initialClientData
        )
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

        let task = Task<UInt16, Error> {
            let nwIdentity = try leafIssuer.makeSecIdentity(for: host)
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, nwIdentity)
            sec_protocol_options_add_tls_application_protocol(tlsOptions.securityProtocolOptions, "http/1.1")

            let params = NWParameters(tls: tlsOptions, tcp: .init())
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)

            let termListener = try NWListener(using: params)
            termListener.newConnectionHandler = { [weak server = self] tlsConn in
                guard let server else {
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
        terminators[cacheKey] = (port, termListener)
        terminatorOrder.append(cacheKey)
        while terminatorOrder.count > maxTerminators {
            let evicted = terminatorOrder.removeFirst()
            if let entry = terminators.removeValue(forKey: evicted) {
                entry.listener.cancel()
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
                store.append(MITMCaptureEntry(
                    bundleID: bundleID,
                    method: "TLS",
                    scheme: "https",
                    host: targetHost,
                    port: targetPort,
                    path: "/",
                    urlString: "https://\(targetHost)\(portSuffix)/",
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
                          let head = parseHTTPRequestHead(headerData, body: Data()) else {
                        logTLSErrorIfNeeded("TLS connection closed before HTTP request")
                        break
                    }
                    didReceiveRequest.withLock { $0 = true }
                    if Self.shouldSend100Continue(headers: head.headerMap) {
                        try await stream.writeAll(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
                    }
                    let reqBody = try await readBody(for: head.headerMap, from: stream)
                    let req = ParsedHTTPRequest(
                        method: head.method,
                        target: head.target,
                        version: head.version,
                        headers: head.headers,
                        headerMap: head.headerMap,
                        body: reqBody
                    )
                    let keepAlive = await forwardSingleRequest(
                        req,
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
    private func handlePlainHTTPRequest(_ req: ParsedHTTPRequest, clientStream: BufferedConnection) async -> Bool {
        let parsed = Self.resolvePlainHTTPTarget(req.target, headers: req.headerMap)
        return await forwardSingleRequest(
            ParsedHTTPRequest(
                method: req.method,
                target: parsed.path,
                version: req.version,
                headers: req.headers,
                headerMap: req.headerMap,
                body: req.body
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
        _ req: ParsedHTTPRequest,
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
        let path = Self.normalizeOriginPath(from: req.target)
        let fullURL = "\(scheme)://\(host)\(portSuffix)\(path)"

        let capturedReqBody = currentConfig.captureBodies ? req.body : nil

        if currentConfig.enableNetworkRules {
            let evaluator = NetworkRuleEvaluator(rawPatterns: currentConfig.blockedURLPatterns)
            if evaluator.evaluate(host: host, urlString: fullURL) == .block {
                let statusCode: Int
                let reason: String
                let bodyText: String
                let contentType: String
                let disposition: TrafficDisposition
                if currentConfig.networkBlockMock200 {
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
                    requestBody: capturedReqBody,
                    statusCode: statusCode,
                    responseHeaders: ["Content-Type": contentType],
                    responseBody: currentConfig.captureBodies ? Data(bodyText.utf8) : nil,
                    durationMs: Self.elapsedMs(since: clockStart),
                    disposition: disposition
                ))
                return false
            }
        }

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
            let wireRequest = Self.serializeRequestForUpstream(req, host: host, portSuffix: portSuffix, path: path)
            try await upstreamStream.writeAll(wireRequest)

            var respHead: ParsedHTTPResponse
            while true {
                guard let respHeadData = try await upstreamStream.readHeaderBlock(),
                      let parsed = parseHTTPResponseHead(respHeadData) else {
                    throw MITMProxyError.upstreamConnectionFailed("Empty HTTP response from \(host)")
                }
                if (100..<200).contains(parsed.statusCode) && parsed.statusCode != 101 {
                    if parsed.statusCode != 100 {
                        let interimWire = Self.serializeResponseForClient(parsed, method: req.method, body: Data())
                        try await clientStream.writeAll(interimWire)
                    }
                    continue
                }
                respHead = parsed
                break
            }

            if respHead.statusCode == 101 {
                var upgradeWire = Self.serializeResponseForClient(respHead, method: req.method, body: Data())
                let upstreamExtra = await upstreamStream.drainRemainder()
                if !upstreamExtra.isEmpty {
                    upgradeWire.append(upstreamExtra)
                }
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
                    requestBody: capturedReqBody,
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

            let respBody = try await readResponseBody(
                statusCode: respHead.statusCode,
                method: req.method,
                headers: respHead.headerMap,
                from: upstreamStream
            )
            let wireResp = Self.serializeResponseForClient(respHead, method: req.method, body: respBody)
            try await clientStream.writeAll(wireResp)

            captureStore.append(MITMCaptureEntry(
                bundleID: currentConfig.bundleID,
                method: req.method,
                scheme: scheme,
                host: host,
                port: port,
                path: path,
                urlString: fullURL,
                requestHeaders: req.headerMap,
                requestBody: capturedReqBody,
                statusCode: respHead.statusCode,
                responseHeaders: respHead.headerMap,
                responseBody: currentConfig.captureBodies ? respBody : nil,
                durationMs: Self.elapsedMs(since: clockStart),
                disposition: dispositionOnSuccess
            ))

            let connHdr = req.headerMap.first { $0.key.lowercased() == "connection" }?.value.lowercased()
            return connHdr != "close"
        } catch {
            let errBody = error.localizedDescription
            try? await clientStream.writeAll(Self.simpleResponse(code: 502, reason: "Bad Gateway", body: errBody))
            captureStore.append(MITMCaptureEntry(
                bundleID: currentConfig.bundleID,
                method: req.method,
                scheme: scheme,
                host: host,
                port: port,
                path: path,
                urlString: fullURL,
                requestHeaders: req.headerMap,
                requestBody: capturedReqBody,
                statusCode: 502,
                durationMs: Self.elapsedMs(since: clockStart),
                disposition: .error,
                errorDescription: errBody
            ))
            return false
        }
    }

    private func connectTCP(targetHost: String, connectHost: String, port: UInt16) async throws -> NWConnection {
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
        return conn
    }

    private func connectTLS(
        targetHost: String,
        connectHost: String,
        sniHost: String,
        port: UInt16
    ) async throws -> NWConnection {
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, sniHost)
        sec_protocol_options_add_tls_application_protocol(tlsOptions.securityProtocolOptions, "http/1.1")

        if let trustOverrideDER = upstreamTrustOverrideDER,
           let anchorCert = SecCertificateCreateWithData(nil, trustOverrideDER as CFData) {
            sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, secTrust, completion in
                let trustRef = sec_trust_copy_ref(secTrust).takeRetainedValue()
                SecTrustSetAnchorCertificates(trustRef, [anchorCert] as CFArray)
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
        return conn
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let lower = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower == "localhost" || lower == "127.0.0.1" || lower == "::1" || lower == "[::1]"
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
        defer { activeConnections.removeValue(forKey: token) }

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

    private func parseHTTPRequestHead(_ data: Data, body: Data) -> ParsedHTTPRequest? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let target = String(parts[1])
        let version = parts.count >= 3 ? String(parts[2]) : "HTTP/1.1"

        var headers: [(String, String)] = []
        var map: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
            map[name] = value
        }
        return ParsedHTTPRequest(
            method: method,
            target: target,
            version: version,
            headers: headers,
            headerMap: map,
            body: body
        )
    }

    private func parseHTTPResponseHead(_ data: Data) -> ParsedHTTPResponse? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let code = Int(parts[1]) else { return nil }

        let version = String(parts[0])
        let reason = parts.count >= 3 ? String(parts[2]) : HTTPURLResponse.localizedString(forStatusCode: code)
        var headers: [(String, String)] = []
        var map: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
            map[name] = value
        }
        return ParsedHTTPResponse(
            statusCode: code,
            reasonPhrase: reason,
            version: version,
            headers: headers,
            headerMap: map,
            body: Data()
        )
    }

    private func readBody(for headers: [String: String], from stream: BufferedConnection) async throws -> Data {
        if let te = headers.first(where: { $0.key.lowercased() == "transfer-encoding" })?.value.lowercased(),
           te.contains("chunked") {
            return try await stream.readChunkedBody()
        }
        if let clStr = headers.first(where: { $0.key.lowercased() == "content-length" })?.value,
           let length = Int(clStr), length > 0 {
            return try await stream.readExact(count: length)
        }
        return Data()
    }

    private func readResponseBody(
        statusCode: Int,
        method: String,
        headers: [String: String],
        from stream: BufferedConnection
    ) async throws -> Data {
        if method.uppercased() == "HEAD" || (100..<200).contains(statusCode) || statusCode == 204 || statusCode == 304 {
            return Data()
        }
        if let te = headers.first(where: { $0.key.lowercased() == "transfer-encoding" })?.value.lowercased(),
           te.contains("chunked") {
            return try await stream.readChunkedBody()
        }
        if let clStr = headers.first(where: { $0.key.lowercased() == "content-length" })?.value,
           let length = Int(clStr) {
            return length > 0 ? try await stream.readExact(count: length) : Data()
        }
        return try await stream.readUntilEOF()
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
           let len = Int(cl), len > 0 {
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

    private static func serializeRequestForUpstream(
        _ req: ParsedHTTPRequest,
        host: String,
        portSuffix: String,
        path: String
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
            headerLines.append("Host: \(host)\(portSuffix)")
        }
        headerLines.append(isWebSocketUpgrade ? "Connection: Upgrade" : "Connection: close")
        let hadExplicitLength = req.headerMap.contains { entry in
            let lower = entry.key.lowercased()
            return lower == "content-length" || lower == "transfer-encoding"
        }
        let upperMethod = req.method.uppercased()
        let expectsBodyHeader = !req.body.isEmpty || hadExplicitLength ||
            upperMethod == "POST" || upperMethod == "PUT" || upperMethod == "PATCH"
        if expectsBodyHeader {
            headerLines.append("Content-Length: \(req.body.count)")
        }
        var out = Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        out.append(req.body)
        return out
    }

    private static func serializeResponseForClient(
        _ resp: ParsedHTTPResponse,
        method: String,
        body: Data
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

        let noBodyStatus = (100..<200).contains(resp.statusCode) ||
            resp.statusCode == 204 || resp.statusCode == 304
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
        if !noBodyStatus && !isHead {
            headerLines.append("Content-Length: \(body.count)")
        }
        if !(100..<200).contains(resp.statusCode) {
            headerLines.append("Connection: keep-alive")
        }
        var out = Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        out.append(body)
        return out
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
