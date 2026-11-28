import Foundation
import PlayCoverCore

public enum NetworkProxyMode: String, Codable, CaseIterable, Sendable {
    case direct
    case external
    case builtInMITM
}

public enum ExternalProxyProtocol: String, Codable, CaseIterable, Sendable {
    case http
    case socks5
}

public enum CertificateSource: String, Codable, Sendable {
    case imported
    case generatedBuiltIn
}

public struct AppCertificateRecord: Codable, Identifiable, Equatable, Sendable {
    /// Lowercase hex SHA-256 fingerprint of the DER certificate.
    public let id: String
    public var label: String
    public var subject: String
    public var issuer: String
    public var notBefore: Date?
    public var notAfter: Date?
    public var isCA: Bool
    public var enabled: Bool
    public var source: CertificateSource
    public var createdAt: Date

    public init(
        id: String,
        label: String,
        subject: String,
        issuer: String,
        notBefore: Date?,
        notAfter: Date?,
        isCA: Bool,
        enabled: Bool,
        source: CertificateSource,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.subject = subject
        self.issuer = issuer
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.isCA = isCA
        self.enabled = enabled
        self.source = source
        self.createdAt = createdAt
    }

    public var isExpired: Bool {
        guard let notAfter else { return false }
        return notAfter < Date()
    }

    public var shortFingerprint: String {
        let prefix = String(id.prefix(16)).uppercased()
        var grouped: [String] = []
        var idx = prefix.startIndex
        while idx < prefix.endIndex {
            let next = prefix.index(idx, offsetBy: 2, limitedBy: prefix.endIndex) ?? prefix.endIndex
            grouped.append(String(prefix[idx..<next]))
            idx = next
        }
        return grouped.joined(separator: ":")
    }
}

public enum TrafficDisposition: String, Codable, CaseIterable, Sendable {
    case forwarded
    case decrypted
    case tunnel
    case blocked
    case mocked200
    case error
}

public struct MITMCaptureEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let bundleID: String
    public let method: String
    public let scheme: String
    public let host: String
    public let port: Int
    public let path: String
    public let urlString: String
    public let requestHeaders: [String: String]
    public let requestBody: Data?
    public let requestBodyTruncated: Bool
    public let statusCode: Int?
    public let responseHeaders: [String: String]
    public let responseBody: Data?
    public let responseBodyTruncated: Bool
    public let durationMs: Double
    public let disposition: TrafficDisposition
    public let errorDescription: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        bundleID: String,
        method: String,
        scheme: String,
        host: String,
        port: Int,
        path: String,
        urlString: String,
        requestHeaders: [String: String] = [:],
        requestBody: Data? = nil,
        requestBodyTruncated: Bool = false,
        statusCode: Int? = nil,
        responseHeaders: [String: String] = [:],
        responseBody: Data? = nil,
        responseBodyTruncated: Bool = false,
        durationMs: Double = 0,
        disposition: TrafficDisposition,
        errorDescription: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.bundleID = bundleID
        self.method = method
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
        self.urlString = urlString
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.requestBodyTruncated = requestBodyTruncated
        self.statusCode = statusCode
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.responseBodyTruncated = responseBodyTruncated
        self.durationMs = durationMs
        self.disposition = disposition
        self.errorDescription = errorDescription
    }
}

public struct MITMServerConfiguration: Equatable, Sendable {
    public var bundleID: String
    public var listenPort: UInt16
    public var mitmAllHosts: Bool
    public var mitmHostPatterns: [String]
    public var enableNetworkRules: Bool
    public var networkBlockMock200: Bool
    public var blockedURLPatterns: [String]
    public var captureBodies: Bool
    public var hostOverrides: [String: String]
    public var blockLoopbackTargets: Bool
    public var requiredProxyAuthToken: String?

    public init(
        bundleID: String,
        listenPort: UInt16 = 0,
        mitmAllHosts: Bool = true,
        mitmHostPatterns: [String] = [],
        enableNetworkRules: Bool = false,
        networkBlockMock200: Bool = true,
        blockedURLPatterns: [String] = [],
        captureBodies: Bool = true,
        hostOverrides: [String: String] = [:],
        blockLoopbackTargets: Bool = false,
        requiredProxyAuthToken: String? = nil
    ) {
        self.bundleID = bundleID
        self.listenPort = listenPort
        self.mitmAllHosts = mitmAllHosts
        self.mitmHostPatterns = mitmHostPatterns
        self.enableNetworkRules = enableNetworkRules
        self.networkBlockMock200 = networkBlockMock200
        self.blockedURLPatterns = blockedURLPatterns
        self.captureBodies = captureBodies
        self.hostOverrides = hostOverrides
        self.blockLoopbackTargets = blockLoopbackTargets
        self.requiredProxyAuthToken = requiredProxyAuthToken
    }
}

public enum MITMHostMatcher {
    public static func matches(host: String, mitmAllHosts: Bool, patterns: [String]) -> Bool {
        if mitmAllHosts {
            return true
        }
        let lowerHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowerHost.isEmpty else { return false }

        for raw in patterns {
            var token = NetworkRuleParser.stripInlineComment(NetworkRuleParser.activeBody(raw))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if token.isEmpty || !NetworkRuleParser.isRuleEnabled(raw) {
                continue
            }
            if token.hasPrefix("||") {
                token = String(token.dropFirst(2))
            }
            if let slashIdx = token.firstIndex(of: "/") {
                token = String(token[..<slashIdx])
            }
            if let colonIdx = token.firstIndex(of: ":") {
                token = String(token[..<colonIdx])
            }
            guard !token.isEmpty else { continue }

            if token.contains("*") {
                if wildcardMatch(pattern: token, text: lowerHost) {
                    return true
                }
            } else if token.hasPrefix(".") {
                let suffix = String(token.dropFirst())
                if lowerHost == suffix || lowerHost.hasSuffix(token) {
                    return true
                }
            } else if lowerHost == token || lowerHost.hasSuffix("." + token) {
                return true
            }
        }
        return false
    }

    private static func wildcardMatch(pattern: String, text: String) -> Bool {
        let p = Array(pattern)
        let t = Array(text)
        var pi = 0
        var ti = 0
        var starIdx: Int?
        var matchIdx = 0

        while ti < t.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == t[ti]) {
                pi += 1
                ti += 1
            } else if pi < p.count && p[pi] == "*" {
                starIdx = pi
                matchIdx = ti
                pi += 1
            } else if let star = starIdx {
                pi = star + 1
                matchIdx += 1
                ti = matchIdx
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" {
            pi += 1
        }
        return pi == p.count
    }
}

public enum HARExporter {
    private struct HARRoot: Codable {
        let log: HARLog
    }

    private struct HARLog: Codable {
        let version: String
        let creator: HARCreator
        let entries: [HAREntry]
    }

    private struct HARCreator: Codable {
        let name: String
        let version: String
    }

    private struct HAREntry: Codable {
        let startedDateTime: String
        let time: Double
        let request: HARRequest
        let response: HARResponse
        let cache: [String: String]
        let timings: HARTimings
        let comment: String?
    }

    private struct HARHeader: Codable {
        let name: String
        let value: String
    }

    private struct HARQueryParam: Codable {
        let name: String
        let value: String
    }

    private struct HARPostData: Codable {
        let mimeType: String
        let text: String
    }

    private struct HARRequest: Codable {
        let method: String
        let url: String
        let httpVersion: String
        let headers: [HARHeader]
        let queryString: [HARQueryParam]
        let headersSize: Int
        let bodySize: Int
        let postData: HARPostData?
    }

    private struct HARContent: Codable {
        let size: Int
        let mimeType: String
        let text: String?
        let encoding: String?
    }

    private struct HARResponse: Codable {
        let status: Int
        let statusText: String
        let httpVersion: String
        let headers: [HARHeader]
        let content: HARContent
        let redirectURL: String
        let headersSize: Int
        let bodySize: Int
    }

    private struct HARTimings: Codable {
        let send: Double
        let wait: Double
        let receive: Double
    }

    private static let redactedPlaceholder = "[REDACTED]"

    private static let sensitiveHeaderExactNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "api-key",
        "x-auth-token",
        "x-csrf-token",
        "x-xsrf-token",
        "x-session-token",
        "x-access-token",
        "x-secret"
    ]

    private static let sensitiveKeySubstrings: [String] = [
        "token",
        "secret",
        "password",
        "passwd",
        "apikey",
        "api_key",
        "api-key",
        "auth",
        "credential",
        "session",
        "cookie",
        "private_key",
        "private-key"
    ]

    private static let sensitiveQueryExactNames: Set<String> = [
        "key",
        "sig",
        "signature",
        "code",
        "otp",
        "pwd",
        "sid",
        "jwt",
        "bearer",
        "ticket"
    ]

    private static func isSensitiveHeaderName(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if sensitiveHeaderExactNames.contains(lower) {
            return true
        }
        return sensitiveKeySubstrings.contains { lower.contains($0) }
    }

    private static func isSensitiveKeyName(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if sensitiveQueryExactNames.contains(lower) {
            return true
        }
        return sensitiveKeySubstrings.contains { lower.contains($0) }
    }

    private static func redactURLString(_ urlString: String) -> String {
        guard var comps = URLComponents(string: urlString) else {
            return redactMalformedURL(urlString)
        }
        if comps.user != nil {
            comps.user = redactedPlaceholder
        }
        if comps.password != nil {
            comps.password = redactedPlaceholder
        }
        if let items = comps.queryItems, !items.isEmpty {
            comps.queryItems = items.map { item in
                if isSensitiveKeyName(item.name) {
                    return URLQueryItem(name: item.name, value: redactedPlaceholder)
                }
                return item
            }
        }
        if let frag = comps.fragment, frag.contains("=") {
            comps.fragment = redactedPlaceholder
        }
        return comps.string ?? urlString
    }

    private static func redactMalformedURL(_ raw: String) -> String {
        guard let qIdx = raw.firstIndex(of: "?") else { return raw }
        let prefix = String(raw[..<qIdx])
        let queryAndFrag = String(raw[raw.index(after: qIdx)...])
        let parts = queryAndFrag.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let query = String(parts[0])
        let redactedParams = query.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { return String(pair) }
            let key = String(kv[0])
            if isSensitiveKeyName(key) {
                return "\(key)=\(redactedPlaceholder)"
            }
            return String(pair)
        }.joined(separator: "&")
        if parts.count == 2 {
            let frag = String(parts[1])
            return "\(prefix)?\(redactedParams)#\(frag.contains("=") ? redactedPlaceholder : frag)"
        }
        return "\(prefix)?\(redactedParams)"
    }

    private static func redactJSONValue(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict {
                if isSensitiveKeyName(k) {
                    out[k] = redactedPlaceholder
                } else {
                    out[k] = redactJSONValue(v)
                }
            }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map { redactJSONValue($0) }
        }
        if let str = value as? String {
            if str.contains("://") && (str.contains("?") || str.contains("@") || str.contains("#")) {
                return redactURLString(str)
            }
            return str
        }
        return value
    }

    private static func redactBodyText(_ text: String, mimeType: String) -> String {
        let lowerMime = mimeType.lowercased()
        if lowerMime.contains("json"),
           let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            let sanitized = redactJSONValue(obj)
            if JSONSerialization.isValidJSONObject(sanitized),
               let encoded = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys]),
               let redactedStr = String(data: encoded, encoding: .utf8) {
                return redactedStr
            }
        }
        if lowerMime.contains("x-www-form-urlencoded") {
            return text.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard kv.count == 2 else { return String(pair) }
                let key = String(kv[0])
                let decodedKey = key.removingPercentEncoding ?? key
                if isSensitiveKeyName(decodedKey) {
                    return "\(key)=\(redactedPlaceholder)"
                }
                return String(pair)
            }.joined(separator: "&")
        }
        if text.contains("://"),
           let urlRegex = try? NSRegularExpression(
               pattern: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s"'<>()\[\]{}]+"#
           ) {
            let nsText = text as NSString
            let matches = urlRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            if !matches.isEmpty {
                let mutable = NSMutableString(string: text)
                for match in matches.reversed() {
                    let candidate = nsText.substring(with: match.range)
                    if candidate.contains("?") || candidate.contains("@") || candidate.contains("#") {
                        mutable.replaceCharacters(in: match.range, with: redactURLString(candidate))
                    }
                }
                return mutable as String
            }
        }
        return text
    }

    private static func redactHeaderValue(name: String, value: String) -> String {
        if isSensitiveHeaderName(name) {
            return redactedPlaceholder
        }
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower == "location" || lower == "referer" || lower == "referrer"
            || (value.contains("://") && (value.contains("?") || value.contains("@") || value.contains("#"))) {
            return redactURLString(value)
        }
        return value
    }

    public static func export(
        entries: [MITMCaptureEntry],
        appVersion: String = "1.0.8",
        redactSensitive: Bool = true
    ) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let harEntries: [HAREntry] = entries.map { entry in
            let reqHeaders = entry.requestHeaders.sorted { $0.key < $1.key }
                .map { pair in
                    HARHeader(
                        name: pair.key,
                        value: redactSensitive
                            ? redactHeaderValue(name: pair.key, value: pair.value)
                            : pair.value
                    )
                }
            let respHeaders = entry.responseHeaders.sorted { $0.key < $1.key }
                .map { pair in
                    HARHeader(
                        name: pair.key,
                        value: redactSensitive
                            ? redactHeaderValue(name: pair.key, value: pair.value)
                            : pair.value
                    )
                }

            let exportedURL = redactSensitive ? redactURLString(entry.urlString) : entry.urlString

            let queryParams: [HARQueryParam] = {
                guard let comps = URLComponents(string: entry.urlString), let items = comps.queryItems else {
                    return []
                }
                return items.map { item in
                    let val = (redactSensitive && isSensitiveKeyName(item.name))
                        ? redactedPlaceholder
                        : (item.value ?? "")
                    return HARQueryParam(name: item.name, value: val)
                }
            }()

            let reqMime = HTTPBodyDecoder.headerValue(
                named: "content-type",
                in: entry.requestHeaders
            ) ?? "application/octet-stream"
            let postData: HARPostData? = entry.requestBody.flatMap { body -> HARPostData? in
                guard !body.isEmpty else { return nil }
                let decoded = HTTPBodyDecoder.decode(body, headers: entry.requestHeaders)
                let rawText = HTTPBodyDecoder.decodeText(decoded.data, contentType: reqMime)
                let text: String
                if let rawText {
                    text = redactSensitive ? redactBodyText(rawText, mimeType: reqMime) : rawText
                } else if redactSensitive {
                    text = redactedPlaceholder
                } else {
                    text = decoded.data.base64EncodedString()
                }
                return HARPostData(mimeType: reqMime, text: text)
            }

            let respMime = HTTPBodyDecoder.headerValue(
                named: "content-type",
                in: entry.responseHeaders
            ) ?? "application/octet-stream"
            let respBody = entry.responseBody ?? Data()
            let respContent: HARContent
            if respBody.isEmpty {
                respContent = HARContent(size: 0, mimeType: respMime, text: "", encoding: nil)
            } else {
                let decodedResp = HTTPBodyDecoder.decode(respBody, headers: entry.responseHeaders)
                if let rawText = HTTPBodyDecoder.decodeText(decodedResp.data, contentType: respMime) {
                    let text = redactSensitive ? redactBodyText(rawText, mimeType: respMime) : rawText
                    respContent = HARContent(
                        size: decodedResp.data.count,
                        mimeType: respMime,
                        text: text,
                        encoding: nil
                    )
                } else if redactSensitive {
                    respContent = HARContent(
                        size: decodedResp.data.count,
                        mimeType: respMime,
                        text: redactedPlaceholder,
                        encoding: nil
                    )
                } else {
                    respContent = HARContent(
                        size: decodedResp.data.count,
                        mimeType: respMime,
                        text: decodedResp.data.base64EncodedString(),
                        encoding: "base64"
                    )
                }
            }

            let status = entry.statusCode ?? 0
            let statusText = status > 0
                ? HTTPURLResponse.localizedString(forStatusCode: status)
                : entry.disposition.rawValue

            let rawRedirect = HTTPBodyDecoder.headerValue(
                named: "location",
                in: entry.responseHeaders
            ) ?? ""
            let exportedRedirect = (redactSensitive && !rawRedirect.isEmpty)
                ? redactURLString(rawRedirect)
                : rawRedirect

            return HAREntry(
                startedDateTime: formatter.string(from: entry.timestamp),
                time: max(0, entry.durationMs),
                request: HARRequest(
                    method: entry.method,
                    url: exportedURL,
                    httpVersion: "HTTP/1.1",
                    headers: reqHeaders,
                    queryString: queryParams,
                    headersSize: -1,
                    bodySize: entry.requestBody?.count ?? 0,
                    postData: postData
                ),
                response: HARResponse(
                    status: status,
                    statusText: statusText,
                    httpVersion: "HTTP/1.1",
                    headers: respHeaders,
                    content: respContent,
                    redirectURL: exportedRedirect,
                    headersSize: -1,
                    bodySize: respBody.count
                ),
                cache: [:],
                timings: HARTimings(send: 0, wait: max(0, entry.durationMs), receive: 0),
                comment: entry.errorDescription
            )
        }

        let root = HARRoot(
            log: HARLog(
                version: "1.2",
                creator: HARCreator(name: "MacOver", version: appVersion),
                entries: harEntries
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(root)
    }
}
