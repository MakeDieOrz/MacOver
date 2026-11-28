import Foundation

public enum HeaderRedactor {
    public static let redactedPlaceholder = "[REDACTED]"

    private static let exactSensitiveNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "www-authenticate",
        "proxy-authenticate",
        "cookie",
        "set-cookie",
        "set-cookie2",
        "x-api-key",
        "api-key",
        "x-auth-token",
        "x-session-token",
        "x-access-token",
        "x-csrf-token",
        "x-xsrf-token"
    ]

    private static let sensitiveSubstrings: [String] = [
        "token",
        "secret",
        "password",
        "passwd",
        "passphrase",
        "apikey",
        "api_key",
        "api-key",
        "auth",
        "cookie",
        "session",
        "jwt",
        "signature",
        "subscription-key",
        "subscription_key",
        "credential",
        "private-key",
        "private_key",
        "access-key",
        "access_key",
        "bearer"
    ]

    private static let exactSensitiveQueryOrBodyKeys: Set<String> = [
        "code",
        "sig",
        "key",
        "pwd",
        "pass",
        "pin",
        "otp",
        "totp",
        "mfa",
        "cvv",
        "ssn",
        "sid",
        "ssid",
        "ticket",
        "assertion",
        "oauth_verifier",
        "client_secret",
        "access_token",
        "refresh_token",
        "id_token",
        "api_key",
        "apikey",
        "api-key"
    ]

    public static func isSensitiveHeader(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }
        if exactSensitiveNames.contains(lower) {
            return true
        }
        return sensitiveSubstrings.contains(where: { lower.contains($0) })
    }

    public static func isSensitiveKey(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }
        if exactSensitiveQueryOrBodyKeys.contains(lower) || exactSensitiveNames.contains(lower) {
            return true
        }
        return sensitiveSubstrings.contains(where: { lower.contains($0) })
    }

    public static func redact(
        headers: [String: String],
        allowSensitiveHeaders: Bool
    ) -> [String: String] {
        guard !allowSensitiveHeaders else {
            return headers
        }
        var out: [String: String] = [:]
        out.reserveCapacity(headers.count)
        for (key, value) in headers {
            out[key] = isSensitiveHeader(key) ? redactedPlaceholder : value
        }
        return out
    }

    public static func redactURL(
        _ urlString: String,
        allowSensitiveHeaders: Bool
    ) -> String {
        guard !allowSensitiveHeaders, !urlString.isEmpty else {
            return urlString
        }
        guard var components = URLComponents(string: urlString) else {
            return redactMalformedURL(urlString)
        }
        if components.password != nil {
            components.password = redactedPlaceholder
        }
        if let items = components.queryItems, !items.isEmpty {
            components.queryItems = items.map { item in
                if isSensitiveKey(item.name) {
                    return URLQueryItem(name: item.name, value: redactedPlaceholder)
                }
                if let val = item.value, looksLikeInlineSecretToken(val) {
                    return URLQueryItem(name: item.name, value: redactedPlaceholder)
                }
                return item
            }
        }
        if let fragment = components.fragment, fragment.contains("=") {
            components.fragment = redactKeyValueDelimitedString(fragment, separator: "&")
        }
        return components.string ?? redactMalformedURL(urlString)
    }

    private static func redactMalformedURL(_ raw: String) -> String {
        let baseAndQuery: String
        let fragmentPart: String?
        if let hashIdx = raw.firstIndex(of: "#") {
            baseAndQuery = String(raw[..<hashIdx])
            let rawFrag = String(raw[raw.index(after: hashIdx)...])
            fragmentPart = rawFrag.contains("=")
                ? redactKeyValueDelimitedString(rawFrag, separator: "&")
                : rawFrag
        } else {
            baseAndQuery = raw
            fragmentPart = nil
        }

        let basePart: String
        let queryPart: String?
        if let qIdx = baseAndQuery.firstIndex(of: "?") {
            basePart = redactMalformedUserInfo(String(baseAndQuery[..<qIdx]))
            let rawQuery = String(baseAndQuery[baseAndQuery.index(after: qIdx)...])
            queryPart = redactKeyValueDelimitedString(rawQuery, separator: "&")
        } else {
            basePart = redactMalformedUserInfo(baseAndQuery)
            queryPart = nil
        }

        var rebuilt = basePart
        if let queryPart {
            rebuilt += "?" + queryPart
        }
        if let fragmentPart {
            rebuilt += "#" + fragmentPart
        }
        return rebuilt
    }

    private static func redactMalformedUserInfo(_ base: String) -> String {
        guard let schemeRange = base.range(of: "://") else {
            return base
        }
        let afterScheme = base[schemeRange.upperBound...]
        let authorityEnd = afterScheme.firstIndex(of: "/") ?? afterScheme.endIndex
        let authority = afterScheme[..<authorityEnd]
        guard let atIdx = authority.lastIndex(of: "@") else {
            return base
        }
        let userInfo = authority[..<atIdx]
        guard let colonIdx = userInfo.firstIndex(of: ":") else {
            return base
        }
        let user = userInfo[..<colonIdx]
        let hostAndRest = base[atIdx...]
        return "\(base[..<schemeRange.upperBound])\(user):\(redactedPlaceholder)\(hostAndRest)"
    }

    public static func redactKeyValueDelimitedString(_ input: String, separator: Character) -> String {
        let parts = input.split(separator: separator, omittingEmptySubsequences: false)
        var modified = false
        let rewritten = parts.map { part -> String in
            let str = String(part)
            guard let eqIdx = str.firstIndex(of: "=") else {
                return str
            }
            let rawKey = String(str[..<eqIdx])
            let decodedKey = rawKey.removingPercentEncoding ?? rawKey
            let rawVal = String(str[str.index(after: eqIdx)...])
            let decodedVal = rawVal.removingPercentEncoding ?? rawVal
            if isSensitiveKey(decodedKey) || looksLikeInlineSecretToken(decodedVal) {
                modified = true
                return "\(rawKey)=\(redactedPlaceholder)"
            }
            return str
        }
        return modified ? rewritten.joined(separator: String(separator)) : input
    }

    public static func looksLikeInlineSecretToken(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else { return false }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("bearer ") || lower.hasPrefix("basic ") {
            return true
        }
        // Compact JWS/JWT format: three base64url segments starting with eyJ
        if trimmed.hasPrefix("eyJ") {
            let segs = trimmed.split(separator: ".", omittingEmptySubsequences: false)
            if segs.count == 3 && segs.allSatisfy({ $0.count >= 4 }) {
                return true
            }
        }
        return false
    }
}
