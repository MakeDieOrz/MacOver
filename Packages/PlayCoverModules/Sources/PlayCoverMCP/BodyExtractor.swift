import Foundation
import PlayCoverNetwork

public struct ExtractedBodyResult: Equatable, Sendable {
    public let text: String
    public let truncated: Bool
    public let isHex: Bool

    public init(text: String, truncated: Bool, isHex: Bool) {
        self.text = text
        self.truncated = truncated
        self.isHex = isHex
    }
}

public enum BodyExtractor {
    public static let defaultMaxBodyBytes = 4_096

    public static func extract(
        rawData: Data?,
        headers: [String: String],
        maxBodyBytes: Int = defaultMaxBodyBytes,
        jsonPath: String? = nil,
        grep: String? = nil,
        redactSensitive: Bool = true
    ) -> ExtractedBodyResult? {
        guard let rawData, !rawData.isEmpty else {
            return nil
        }
        let byteBudget = max(256, min(65_536, maxBodyBytes))
        let decoded = HTTPBodyDecoder.decode(rawData, headers: headers)
        let contentType = HTTPBodyDecoder.headerValue(named: "content-type", in: headers)

        let parsedJSON = try? JSONSerialization.jsonObject(with: decoded.data)
        let workingJSON: Any? = parsedJSON.map { redactSensitive ? redactJSONValue($0) : $0 }

        var isHex = false
        var text: String
        if let jsonPath, !jsonPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let root = workingJSON {
                if let matched = evaluateJSONPath(jsonPath, in: root) {
                    text = serializeJSONFragment(matched)
                } else {
                    text = "<jsonPath '\(jsonPath)' not found>"
                }
            } else {
                text = "<body is not valid JSON for jsonPath '\(jsonPath)'>"
            }
        } else {
            if let root = workingJSON,
               JSONSerialization.isValidJSONObject(root),
               let pretty = try? JSONSerialization.data(
                   withJSONObject: root,
                   options: [.prettyPrinted, .sortedKeys]
               ),
               let jsonStr = String(data: pretty, encoding: .utf8) {
                text = jsonStr
            } else if let readable = HTTPBodyDecoder.decodeText(decoded.data, contentType: contentType) {
                text = redactSensitive ? redactTextBody(readable, contentType: contentType) : readable
            } else if redactSensitive {
                return ExtractedBodyResult(
                    text: "[REDACTED binary body (\(decoded.data.count) bytes); "
                        + "enable allowSensitiveHeaders in Settings -> MCP to inspect raw binary payloads]",
                    truncated: false,
                    isHex: false
                )
            } else {
                text = HTTPBodyDecoder.hexString(for: decoded.data)
                isHex = true
            }
        }

        // Apply grep filter after both jsonPath extraction and full-body formatting (MED-05).
        if let grep, !grep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let needle = grep.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matchingLines = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.lowercased().contains(needle) }
            text = matchingLines.isEmpty
                ? "<no lines matching '\(grep)'>"
                : matchingLines.joined(separator: "\n")
        }

        let utf8 = Data(text.utf8)
        if utf8.count > byteBudget {
            let endIdx = utf8.index(utf8.startIndex, offsetBy: byteBudget)
            for trim in 0...3 {
                let candidateEnd = utf8.index(
                    endIdx,
                    offsetBy: -trim,
                    limitedBy: utf8.startIndex
                ) ?? utf8.startIndex
                let candidate = utf8[..<candidateEnd]
                if let valid = String(bytes: candidate, encoding: .utf8) {
                    return ExtractedBodyResult(
                        text: "\(valid)\n...[truncated \(utf8.count - candidate.count) bytes]",
                        truncated: true,
                        isHex: isHex
                    )
                }
            }
            let safeEnd = utf8.index(utf8.startIndex, offsetBy: max(0, byteBudget - 3))
            let clipped = String(bytes: utf8[..<safeEnd], encoding: .utf8) ?? ""
            return ExtractedBodyResult(
                text: "\(clipped)\n...[truncated \(utf8.count - byteBudget) bytes]",
                truncated: true,
                isHex: isHex
            )
        }
        return ExtractedBodyResult(text: text, truncated: false, isHex: isHex)
    }

    private static func redactJSONValue(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (key, nested) in dict {
                if HeaderRedactor.isSensitiveKey(key) {
                    out[key] = HeaderRedactor.redactedPlaceholder
                } else {
                    out[key] = redactJSONValue(nested)
                }
            }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map { redactJSONValue($0) }
        }
        if let str = value as? String {
            if HeaderRedactor.looksLikeInlineSecretToken(str) {
                return HeaderRedactor.redactedPlaceholder
            }
            var sanitized = str
            if sanitized.contains("://") {
                sanitized = redactURLsInText(sanitized)
            } else if sanitized.contains("?") && sanitized.contains("=") {
                sanitized = HeaderRedactor.redactURL(sanitized, allowSensitiveHeaders: false)
            }
            return redactInlineTokens(in: sanitized)
        }
        return value
    }

    private static func redactTextBody(_ text: String, contentType: String?) -> String {
        var result = text
        let lowerType = (contentType ?? "").lowercased()
        if lowerType.contains("application/x-www-form-urlencoded")
            || (!result.contains("\n") && !result.contains("://") && result.contains("=") && result.contains("&")) {
            result = HeaderRedactor.redactKeyValueDelimitedString(result, separator: "&")
        }

        let lines = result.split(separator: "\n", omittingEmptySubsequences: false).map { rawLine -> String in
            var line = String(rawLine)
            if line.contains("://") {
                line = redactURLsInText(line)
            } else if line.contains("=") {
                line = HeaderRedactor.redactKeyValueDelimitedString(line, separator: "&")
            }
            if let colonIdx = line.firstIndex(of: ":") {
                let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                let lowerKey = key.lowercased()
                let isScheme = lowerKey == "http" || lowerKey == "https" || lowerKey == "ws" || lowerKey == "wss"
                if !isScheme, !key.contains(" "), HeaderRedactor.isSensitiveKey(key) {
                    line = "\(line[..<colonIdx]): \(HeaderRedactor.redactedPlaceholder)"
                }
            }
            return redactInlineTokens(in: line)
        }
        return lines.joined(separator: "\n")
    }

    private static func redactURLsInText(_ input: String) -> String {
        guard input.contains("://"),
              let regex = try? NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s"'<>)\]]+"#) else {
            return input
        }
        let nsInput = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: nsInput.length))
        guard !matches.isEmpty else { return input }

        var output = input
        for match in matches.reversed() {
            guard let swiftRange = Range(match.range, in: output) else { continue }
            let rawURL = String(output[swiftRange])
            let safeURL = HeaderRedactor.redactURL(rawURL, allowSensitiveHeaders: false)
            output.replaceSubrange(swiftRange, with: safeURL)
        }
        return output
    }

    private static func redactInlineTokens(in line: String) -> String {
        var output = line
        let patterns = [
            #"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"#,
            #"\beyJ[A-Za-z0-9_-]{6,}\.eyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\b"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(output.startIndex..<output.endIndex, in: output)
                output = regex.stringByReplacingMatches(
                    in: output,
                    range: range,
                    withTemplate: HeaderRedactor.redactedPlaceholder
                )
            }
        }
        return output
    }

    private enum PathToken {
        case key(String)
        case index(Int)
    }

    private static func evaluateJSONPath(_ path: String, in root: Any) -> Any? {
        let tokens = parseTokens(path)
        guard !tokens.isEmpty else { return root }
        var current: Any = root
        for token in tokens {
            switch token {
            case .key(let key):
                guard let dict = current as? [String: Any], let next = dict[key] else {
                    return nil
                }
                current = next
            case .index(let idx):
                guard let arr = current as? [Any], idx >= 0, idx < arr.count else {
                    return nil
                }
                current = arr[idx]
            }
        }
        return current
    }

    private static func parseTokens(_ raw: String) -> [PathToken] {
        var str = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("$.") {
            str = String(str.dropFirst(2))
        } else if str.hasPrefix("$") {
            str = String(str.dropFirst(1))
        }
        var tokens: [PathToken] = []
        var buffer = ""
        var idx = str.startIndex
        while idx < str.endIndex {
            let ch = str[idx]
            if ch == "." {
                if !buffer.isEmpty {
                    tokens.append(.key(buffer))
                    buffer = ""
                }
                idx = str.index(after: idx)
            } else if ch == "[" {
                if !buffer.isEmpty {
                    tokens.append(.key(buffer))
                    buffer = ""
                }
                let nextStart = str.index(after: idx)
                if let close = str[nextStart...].firstIndex(of: "]") {
                    let inside = String(str[nextStart..<close])
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                    if let arrIndex = Int(inside) {
                        tokens.append(.index(arrIndex))
                    } else if !inside.isEmpty {
                        tokens.append(.key(inside))
                    }
                    idx = str.index(after: close)
                } else {
                    break
                }
            } else {
                buffer.append(ch)
                idx = str.index(after: idx)
            }
        }
        if !buffer.isEmpty {
            tokens.append(.key(buffer))
        }
        return tokens
    }

    private static func serializeJSONFragment(_ value: Any) -> String {
        if let str = value as? String {
            return str
        }
        if let num = value as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return num.boolValue ? "true" : "false"
            }
            return num.stringValue
        }
        if value is NSNull {
            return "null"
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(
               withJSONObject: value,
               options: [.prettyPrinted, .sortedKeys]
           ),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return String(describing: value)
    }
}
