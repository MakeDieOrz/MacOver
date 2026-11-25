//
//  NetworkRuleParser.swift
//  PlayCover
//

import Foundation

public enum NetworkRuleParser {
    public static let disabledPrefix = "#!OFF "
    private static let disabledMarker = "#!OFF"

    public struct RuleMeta: Equatable, Sendable {
        public let isEnabled: Bool
        public let isAllow: Bool
        public let kindKey: String
        public let body: String

        public init(isEnabled: Bool, isAllow: Bool, kindKey: String, body: String) {
            self.isEnabled = isEnabled
            self.isAllow = isAllow
            self.kindKey = kindKey
            self.body = body
        }
    }

    private static func disabledBodyIfPresent(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix(disabledMarker) else { return nil }
        let rest = trimmed.dropFirst(disabledMarker.count)
        guard let first = rest.first else {
            return ""
        }
        guard first == " " || first == "\t" else {
            return nil
        }
        return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isRuleEnabled(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return disabledBodyIfPresent(trimmed) == nil
    }

    public static func activeBody(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return disabledBodyIfPresent(trimmed) ?? trimmed
    }

    public static func stripInlineComment(_ rule: String) -> String {
        let chars = Array(rule)
        var escaped = false
        var clsDepth = 0
        for idx in chars.indices {
            let ch = chars[idx]
            if escaped {
                escaped = false
                continue
            }
            if ch == "\\" {
                escaped = true
                continue
            }
            if clsDepth > 0 {
                if ch == "]" { clsDepth -= 1 }
                continue
            }
            if ch == "[" {
                clsDepth += 1
                continue
            }
            let atCommentBoundary = idx == 0 || chars[idx - 1] == " " || chars[idx - 1] == "\t"
            if atCommentBoundary {
                if ch == "#" {
                    let prefixOnlyWhitespace = chars[..<idx].allSatisfy { $0 == " " || $0 == "\t" }
                    if prefixOnlyWhitespace {
                        let tail = String(chars[idx...])
                        if disabledBodyIfPresent(tail) != nil {
                            continue
                        }
                    }
                    return String(chars[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if ch == "/" && idx + 1 < chars.count && chars[idx + 1] == "/" {
                    return String(chars[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return rule.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func classifyRule(_ raw: String) -> RuleMeta {
        let enabled = isRuleEnabled(raw)
        let body = activeBody(raw)
        var expr = stripInlineComment(body)
        var isAllow = false

        if expr.hasPrefix("@@") {
            let afterAt = String(expr.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if !afterAt.isEmpty {
                isAllow = true
                expr = afterAt
            }
        } else if expr.hasPrefix("!") && !expr.hasPrefix("! ") && !expr.hasPrefix("!\t") && !expr.hasPrefix("![") {
            let afterBang = String(expr.dropFirst(1)).trimmingCharacters(in: .whitespaces)
            if !afterBang.isEmpty {
                isAllow = true
                expr = afterBang
            }
        }

        let upper = expr.uppercased()
        let kindKey: String
        if let comma = upper.firstIndex(of: ",") {
            let kind = upper[..<comma].trimmingCharacters(in: .whitespaces)
            let parts = upper[upper.index(after: comma)...].split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let actionTokens = parts.count >= 2 ? Array(parts.dropFirst()) : parts
            if actionTokens.contains("DIRECT") || actionTokens.contains("ALLOW") {
                isAllow = true
            }
            switch kind {
            case "URL-REGEX", "REGEX":
                kindKey = "settings.network.kind.regex"
            case "DOMAIN-SUFFIX", "HOST-SUFFIX":
                kindKey = "settings.network.kind.suffix"
            case "DOMAIN-KEYWORD", "HOST-KEYWORD":
                kindKey = "settings.network.kind.keyword"
            default:
                kindKey = "settings.network.kind.domain"
            }
        } else if expr.hasPrefix("^") || (expr.hasPrefix("/") && expr.hasSuffix("/") && expr.count > 2) {
            kindKey = "settings.network.kind.regex"
        } else if expr.contains("/") {
            kindKey = "settings.network.kind.url"
        } else if expr.hasPrefix("*.") || expr.hasPrefix(".") {
            kindKey = "settings.network.kind.suffix"
        } else {
            kindKey = "settings.network.kind.domain"
        }

        return RuleMeta(isEnabled: enabled, isAllow: isAllow, kindKey: kindKey, body: body)
    }

    private static func isCommentOnly(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("#") || trimmed.hasPrefix("//") || trimmed.hasPrefix(";") ||
            trimmed.hasPrefix("! ") || trimmed.hasPrefix("!\t") || trimmed.hasPrefix("![") || trimmed == "!"
    }

    public static func isImportableRuleLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if let disabledBody = disabledBodyIfPresent(trimmed) {
            return !disabledBody.isEmpty && !isCommentOnly(disabledBody)
        }
        return !isCommentOnly(trimmed)
    }

    public static func normalizedAllowRule(_ line: String) -> String {
        let meta = classifyRule(line)
        if meta.isAllow {
            return line
        }
        if !meta.isEnabled {
            return disabledPrefix + "@@" + meta.body
        }
        return "@@" + meta.body
    }
}
