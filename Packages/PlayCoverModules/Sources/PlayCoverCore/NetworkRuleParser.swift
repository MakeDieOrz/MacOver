//
//  NetworkRuleParser.swift
//  PlayCover
//

import Darwin
import Foundation

public enum NetworkRuleAction: Equatable, Sendable {
    case defaultBlock
    case forceMock200
    case forceFail
}

public enum NetworkRuleDecision: Equatable, Sendable {
    case pass
    case allow
    case block(NetworkRuleAction)
}

/// Canonical network rule compiler/evaluator matching `PlayTools/Subsystems/PTNetworkRules.m` 1:1.
public struct CanonicalNetworkRuleEngine: Sendable {
    private struct IndexedHostRule: Sendable {
        let index: Int
        let action: NetworkRuleAction
    }

    private struct WildcardHostRule: Sendable {
        let pattern: String
        let index: Int
        let action: NetworkRuleAction
    }

    private struct RegexRule: @unchecked Sendable {
        let regex: NSRegularExpression
        let action: NetworkRuleAction
    }

    private struct URLRule: Sendable {
        let pattern: String
        let index: Int
        let action: NetworkRuleAction
    }

    private let exactHostRules: [String: IndexedHostRule]
    private let suffixHostRules: [String: IndexedHostRule]
    private let wildcardHostRules: [WildcardHostRule]
    private let blockRegexRules: [RegexRule]
    private let literalURLRules: [URLRule]
    private let wildcardURLRules: [URLRule]

    private let allowExactHosts: Set<String>
    private let allowSuffixHosts: Set<String>
    private let allowWildcardHosts: [String]
    private let allowRegexRules: [RegexRule]
    private let allowLiteralURLRules: [String]
    private let allowWildcardURLRules: [String]
    private let hasHostlessAllowRule: Bool
    private let dnsExemptExactHosts: Set<String>
    private let dnsExemptSuffixHosts: Set<String>
    private let dnsExemptWildcardHosts: [String]
    private let dnsExemptHostRegexes: [RegexRule]

    public init(rawPatterns: [String]) {
        var blockHosts: [(rule: String, action: NetworkRuleAction)] = []
        var blockRegexes: [RegexRule] = []
        var blockURLs: [(rule: String, action: NetworkRuleAction)] = []
        var allowHosts: [String] = []
        var allowRegexes: [RegexRule] = []
        var allowURLs: [String] = []
        var dnsExemptHosts: [String] = []
        var dnsExemptRegexes: [RegexRule] = []
        var hostlessAllow = false

        for raw in rawPatterns {
            let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard NetworkRuleParser.isImportableRuleLine(trimmedRaw),
                  NetworkRuleParser.isRuleEnabled(trimmedRaw) else {
                continue
            }
            var trimmed = NetworkRuleParser.stripInlineComment(trimmedRaw)
            if trimmed.isEmpty { continue }

            var isAllow = false
            var ruleAction: NetworkRuleAction = .defaultBlock
            if trimmed.hasPrefix("@@") {
                isAllow = true
                trimmed = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("!") {
                isAllow = true
                trimmed = String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)
            }
            if trimmed.isEmpty { continue }

            if let firstComma = trimmed.firstIndex(of: ",") {
                let kind = trimmed[..<firstComma].trimmingCharacters(in: .whitespaces).uppercased()
                var rest = trimmed[trimmed.index(after: firstComma)...].trimmingCharacters(in: .whitespaces)
                let isRegexKind = (kind == "URL-REGEX" || kind == "REGEX")
                let isDomainExact = (kind == "DOMAIN" || kind == "HOST")
                let isDomainSuffix = (kind == "DOMAIN-SUFFIX" || kind == "HOST-SUFFIX")
                let isDomainKeyword = (kind == "DOMAIN-KEYWORD" || kind == "HOST-KEYWORD")

                if isRegexKind {
                    while let lastComma = rest.lastIndex(of: ",") {
                        let tail = String(rest[rest.index(after: lastComma)...])
                        if Self.parseActionToken(tail, isAllow: &isAllow, action: &ruleAction) {
                            rest = rest[..<lastComma].trimmingCharacters(in: .whitespaces)
                        } else {
                            break
                        }
                    }
                    if !rest.isEmpty,
                       let re = try? NSRegularExpression(pattern: rest, options: [.caseInsensitive]) {
                        if isAllow {
                            allowRegexes.append(RegexRule(regex: re, action: .defaultBlock))
                            if let hostRe = Self.buildDNSExemptRegex(from: rest, hasHostless: &hostlessAllow) {
                                dnsExemptRegexes.append(RegexRule(regex: hostRe, action: .defaultBlock))
                            }
                        } else {
                            blockRegexes.append(RegexRule(regex: re, action: ruleAction))
                        }
                        continue
                    }
                } else if isDomainExact || isDomainSuffix || isDomainKeyword {
                    let parts = rest.split(separator: ",", omittingEmptySubsequences: false).map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                    let val = parts.first ?? ""
                    for token in parts.dropFirst() {
                        _ = Self.parseActionToken(token, isAllow: &isAllow, action: &ruleAction)
                    }
                    if !val.isEmpty {
                        let hostToken: String
                        if isDomainExact {
                            hostToken = Self.normalizePlainHostToken(val, exactOnly: true)
                        } else if isDomainSuffix {
                            let norm = Self.normalizePlainHostToken(val, exactOnly: false)
                            if norm.isEmpty {
                                hostToken = ""
                            } else if norm.contains("*") || norm.hasPrefix(".") {
                                hostToken = norm
                            } else {
                                hostToken = "." + norm
                            }
                        } else {
                            hostToken = "*\(val.lowercased())*"
                        }
                        if !hostToken.isEmpty {
                            if isAllow {
                                allowHosts.append(hostToken)
                            } else {
                                blockHosts.append((hostToken, ruleAction))
                            }
                            continue
                        }
                    }
                }
            }

            if trimmed.hasPrefix("||") {
                let afterPipes = String(trimmed.dropFirst(2))
                let parsed = Self.compileAdblockAnchorRule(afterPipes)
                if let pureHost = parsed.pureHost, !pureHost.isEmpty {
                    if isAllow {
                        allowHosts.append(pureHost)
                    } else {
                        blockHosts.append((pureHost, ruleAction))
                    }
                    continue
                }
                if let regex = parsed.regex {
                    if isAllow {
                        allowRegexes.append(RegexRule(regex: regex, action: .defaultBlock))
                        if let authHost = parsed.authorityHost,
                           !authHost.replacingOccurrences(of: "*", with: "").isEmpty {
                            dnsExemptHosts.append(authHost)
                        } else {
                            hostlessAllow = true
                        }
                    } else {
                        blockRegexes.append(RegexRule(regex: regex, action: ruleAction))
                    }
                    continue
                }
            }

            if trimmed.hasPrefix("^") || (trimmed.hasPrefix("/") && trimmed.hasSuffix("/") && trimmed.count > 2) {
                let pattern = trimmed.hasPrefix("^")
                    ? trimmed
                    : String(trimmed.dropFirst().dropLast())
                if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    if isAllow {
                        allowRegexes.append(RegexRule(regex: re, action: .defaultBlock))
                        if let hostRe = Self.buildDNSExemptRegex(from: pattern, hasHostless: &hostlessAllow) {
                            dnsExemptRegexes.append(RegexRule(regex: hostRe, action: .defaultBlock))
                        }
                    } else {
                        blockRegexes.append(RegexRule(regex: re, action: ruleAction))
                    }
                    continue
                }
            }

            if trimmed.hasPrefix("|") {
                var body = String(trimmed.dropFirst())
                var endAnchor = false
                if body.count > 1 && body.hasSuffix("|") {
                    endAnchor = true
                    body = String(body.dropLast())
                }
                if !body.isEmpty {
                    var pat = "^"
                    for scalar in body.unicodeScalars {
                        Self.appendEscapedRegexScalar(
                            &pat,
                            scalar: scalar,
                            treatStarAsWildcard: true,
                            wildcardNoSlash: false,
                            treatCaretAsSep: true
                        )
                    }
                    if endAnchor {
                        pat.append("$")
                    }
                    if let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) {
                        if isAllow {
                            allowRegexes.append(RegexRule(regex: re, action: .defaultBlock))
                            if let hostPat = Self.extractHostPatternFromAllowURLRule(
                                body.lowercased(),
                                hasHostless: &hostlessAllow
                            ) {
                                dnsExemptHosts.append(hostPat)
                            }
                        } else {
                            blockRegexes.append(RegexRule(regex: re, action: ruleAction))
                        }
                        continue
                    }
                }
            }

            let lower = trimmed.lowercased()
            if lower.contains("/") {
                if isAllow {
                    allowURLs.append(lower)
                    if let hostPat = Self.extractHostPatternFromAllowURLRule(lower, hasHostless: &hostlessAllow) {
                        dnsExemptHosts.append(hostPat)
                    }
                } else {
                    blockURLs.append((lower, ruleAction))
                }
            } else {
                let normHost = Self.normalizePlainHostToken(lower, exactOnly: false)
                if !normHost.isEmpty {
                    if isAllow {
                        allowHosts.append(normHost)
                    } else {
                        blockHosts.append((normHost, ruleAction))
                    }
                }
            }
        }

        let indexedBlockHosts = Self.buildIndexedHostTables(blockHosts)
        self.exactHostRules = indexedBlockHosts.exact
        self.suffixHostRules = indexedBlockHosts.suffix
        self.wildcardHostRules = indexedBlockHosts.wildcards

        let indexedAllowHosts = Self.buildIndexedHostSets(allowHosts)
        self.allowExactHosts = indexedAllowHosts.exact
        self.allowSuffixHosts = indexedAllowHosts.suffix
        self.allowWildcardHosts = indexedAllowHosts.wildcards

        let indexedDNSExempt = Self.buildIndexedHostSets(dnsExemptHosts)
        self.dnsExemptExactHosts = indexedDNSExempt.exact
        self.dnsExemptSuffixHosts = indexedDNSExempt.suffix
        self.dnsExemptWildcardHosts = indexedDNSExempt.wildcards
        self.dnsExemptHostRegexes = dnsExemptRegexes
        self.hasHostlessAllowRule = hostlessAllow

        self.blockRegexRules = blockRegexes
        self.allowRegexRules = allowRegexes

        var litBlockURLs: [URLRule] = []
        var wildBlockURLs: [URLRule] = []
        for (idx, item) in blockURLs.enumerated() where !item.rule.isEmpty {
            let entry = URLRule(pattern: item.rule, index: idx, action: item.action)
            if item.rule.contains("*") {
                wildBlockURLs.append(entry)
            } else {
                litBlockURLs.append(entry)
            }
        }
        self.literalURLRules = litBlockURLs
        self.wildcardURLRules = wildBlockURLs

        self.allowLiteralURLRules = allowURLs.filter { !$0.isEmpty && !$0.contains("*") }
        self.allowWildcardURLRules = allowURLs.filter { !$0.isEmpty && $0.contains("*") }
    }

    public func evaluate(host: String, urlString: String) -> NetworkRuleDecision {
        let lowerHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lowerURL = urlString.lowercased()
        let lowerPath = URLComponents(string: urlString)?.path.lowercased() ?? ""

        if !lowerHost.isEmpty && Self.matchesHostSets(
            lowerHost: lowerHost,
            exact: allowExactHosts,
            suffix: allowSuffixHosts,
            wildcards: allowWildcardHosts
        ) {
            return .allow
        }

        if !allowRegexRules.isEmpty && !urlString.isEmpty {
            let fullRange = NSRange(urlString.startIndex..<urlString.endIndex, in: urlString)
            for rule in allowRegexRules where rule.regex.firstMatch(in: urlString, range: fullRange) != nil {
                return .allow
            }
        }

        for rule in allowLiteralURLRules {
            if lowerURL.contains(rule) || (!lowerPath.isEmpty && lowerPath.contains(rule)) {
                return .allow
            }
        }
        for rule in allowWildcardURLRules {
            if Self.fnmatchCaseFold(pattern: rule, value: lowerURL) ||
                (!lowerPath.isEmpty && Self.fnmatchCaseFold(pattern: rule, value: lowerPath)) {
                return .allow
            }
        }

        if !lowerHost.isEmpty, let hostAction = lookupHostAction(lowerHost: lowerHost) {
            return .block(hostAction)
        }

        if !blockRegexRules.isEmpty && !urlString.isEmpty {
            let fullRange = NSRange(urlString.startIndex..<urlString.endIndex, in: urlString)
            for rule in blockRegexRules where rule.regex.firstMatch(in: urlString, range: fullRange) != nil {
                return .block(rule.action)
            }
        }

        if !literalURLRules.isEmpty || !wildcardURLRules.isEmpty {
            var bestIdx = Int.max
            var bestAction: NetworkRuleAction = .defaultBlock
            var matched = false

            for rule in literalURLRules {
                if lowerURL.contains(rule.pattern) || (!lowerPath.isEmpty && lowerPath.contains(rule.pattern)) {
                    bestIdx = rule.index
                    bestAction = rule.action
                    matched = true
                    break
                }
            }
            for rule in wildcardURLRules {
                if matched && rule.index >= bestIdx {
                    break
                }
                if Self.fnmatchCaseFold(pattern: rule.pattern, value: lowerURL) ||
                    (!lowerPath.isEmpty && Self.fnmatchCaseFold(pattern: rule.pattern, value: lowerPath)) {
                    bestAction = rule.action
                    matched = true
                    break
                }
            }
            if matched {
                return .block(bestAction)
            }
        }

        return .pass
    }

    /// Host-level evaluation for opaque HTTPS CONNECT tunnels (mirrors `ps_should_block_host_cstr`).
    public func evaluateHostForTunnel(host: String) -> NetworkRuleDecision {
        let lowerHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowerHost.isEmpty, !hasHostlessAllowRule else { return .pass }

        guard let action = lookupHostAction(lowerHost: lowerHost) else {
            return .pass
        }
        if Self.matchesHostSets(
            lowerHost: lowerHost,
            exact: allowExactHosts,
            suffix: allowSuffixHosts,
            wildcards: allowWildcardHosts
        ) {
            return .allow
        }
        if Self.matchesHostSets(
            lowerHost: lowerHost,
            exact: dnsExemptExactHosts,
            suffix: dnsExemptSuffixHosts,
            wildcards: dnsExemptWildcardHosts
        ) {
            return .allow
        }
        if !dnsExemptHostRegexes.isEmpty {
            let probes = ["https://\(lowerHost)/", "http://\(lowerHost)/", "\(lowerHost)/"]
            for probe in probes {
                let range = NSRange(probe.startIndex..<probe.endIndex, in: probe)
                for rule in dnsExemptHostRegexes where rule.regex.firstMatch(in: probe, range: range) != nil {
                    return .allow
                }
            }
        }
        return .block(action)
    }

    private func lookupHostAction(lowerHost: String) -> NetworkRuleAction? {
        var found = false
        var bestIdx = Int.max
        var bestAction: NetworkRuleAction = .defaultBlock

        if let exact = exactHostRules[lowerHost] {
            found = true
            bestIdx = exact.index
            bestAction = exact.action
        }

        if !suffixHostRules.isEmpty && !lowerHost.isEmpty {
            var candidate = lowerHost[...]
            while !candidate.isEmpty {
                if let hit = suffixHostRules[String(candidate)], !found || hit.index < bestIdx {
                    found = true
                    bestIdx = hit.index
                    bestAction = hit.action
                }
                guard let dot = candidate.firstIndex(of: ".") else { break }
                let nextStart = candidate.index(after: dot)
                guard nextStart < candidate.endIndex else { break }
                candidate = candidate[nextStart...]
            }
        }

        for rule in wildcardHostRules {
            if found && rule.index >= bestIdx {
                break
            }
            if Self.fnmatchCaseFold(pattern: rule.pattern, value: lowerHost) {
                found = true
                bestAction = rule.action
                break
            }
        }

        return found ? bestAction : nil
    }

    private static func matchesHostSets(
        lowerHost: String,
        exact: Set<String>,
        suffix: Set<String>,
        wildcards: [String]
    ) -> Bool {
        if exact.contains(lowerHost) {
            return true
        }
        if !suffix.isEmpty && !lowerHost.isEmpty {
            var candidate = lowerHost[...]
            while !candidate.isEmpty {
                if suffix.contains(String(candidate)) {
                    return true
                }
                guard let dot = candidate.firstIndex(of: ".") else { break }
                let nextStart = candidate.index(after: dot)
                guard nextStart < candidate.endIndex else { break }
                candidate = candidate[nextStart...]
            }
        }
        for rule in wildcards where fnmatchCaseFold(pattern: rule, value: lowerHost) {
            return true
        }
        return false
    }

    private static func fnmatchCaseFold(pattern: String, value: String) -> Bool {
        pattern.withCString { patPtr in
            value.withCString { valPtr in
                Darwin.fnmatch(patPtr, valPtr, FNM_CASEFOLD) == 0
            }
        }
    }

    private static func parseActionToken(
        _ token: String,
        isAllow: inout Bool,
        action: inout NetworkRuleAction
    ) -> Bool {
        let upper = token.trimmingCharacters(in: .whitespaces).uppercased()
        switch upper {
        case "DIRECT", "ALLOW":
            isAllow = true
            return true
        case "MOCK-200", "MOCK200", "REJECT-DICT", "REJECT-200", "REJECT-EMPTY":
            action = .forceMock200
            return true
        case "REJECT-DROP", "REJECT-ERROR", "REJECT-NO-DROP", "FAIL":
            action = .forceFail
            return true
        case "REJECT", "BLOCK", "PROXY", "REJECT-TINYGIF":
            action = .defaultBlock
            return true
        case "NO-RESOLVE", "PRE-MATCH", "EXTENDED-MATCHING":
            return true
        default:
            return false
        }
    }

    private static func normalizePlainHostToken(_ rawHost: String, exactOnly: Bool) -> String {
        var h = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while h.hasSuffix("^") {
            h.removeLast()
        }
        if !h.hasPrefix("["), let colon = h.firstIndex(of: ":") {
            h = String(h[..<colon])
        }
        guard !h.isEmpty else { return "" }
        if exactOnly {
            if h.hasPrefix(".") {
                h.removeFirst()
            }
            return h.isEmpty ? "" : "=" + h
        }
        if h.hasPrefix("*.") {
            return String(h.dropFirst())
        }
        return h
    }

    private static func appendEscapedRegexScalar(
        _ out: inout String,
        scalar: UnicodeScalar,
        treatStarAsWildcard: Bool,
        wildcardNoSlash: Bool,
        treatCaretAsSep: Bool
    ) {
        if scalar == "*" && treatStarAsWildcard {
            out.append(wildcardNoSlash ? "[^/?#:]*" : ".*")
            return
        }
        if scalar == "^" && treatCaretAsSep {
            out.append("(?:$|[/?#&])")
            return
        }
        switch scalar {
        case "\\", "^", "$", ".", "|", "?", "*", "+", "(", ")", "[", "]", "{", "}":
            out.append("\\")
            out.unicodeScalars.append(scalar)
        default:
            out.unicodeScalars.append(scalar)
        }
    }

    private static func compileAdblockAnchorRule(
        _ afterDoublePipe: String
    ) -> (regex: NSRegularExpression?, pureHost: String?, authorityHost: String?) {
        var s = afterDoublePipe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return (nil, nil, nil) }

        if let dollarIdx = s.lastIndex(of: "$") {
            let optStart = s.index(after: dollarIdx)
            if optStart < s.endIndex {
                let opt = s[optStart...]
                var allOptChars = true
                var hasAsciiLetter = false
                for ch in opt.unicodeScalars {
                    if (ch.value >= 0x61 && ch.value <= 0x7A) || (ch.value >= 0x41 && ch.value <= 0x5A) {
                        hasAsciiLetter = true
                    } else if !((ch.value >= 0x30 && ch.value <= 0x39)
                                || ch == "," || ch == "~" || ch == "=" || ch == "-") {
                        allOptChars = false
                        break
                    }
                }
                if allOptChars && hasAsciiLetter {
                    s = String(s[..<dollarIdx])
                }
            }
        }
        guard !s.isEmpty else { return (nil, nil, nil) }

        guard let sepIdx = s.firstIndex(where: { $0 == "/" || $0 == "?" }) else {
            let pure = normalizePlainHostToken(s, exactOnly: false)
            return (nil, pure.isEmpty ? nil : pure, nil)
        }

        var authorityRaw = String(s[..<sepIdx])
        var pathPart = String(s[sepIdx...])
        while authorityRaw.hasSuffix("^") {
            authorityRaw.removeLast()
        }
        let authHostNorm = normalizePlainHostToken(authorityRaw, exactOnly: false)
        let authorityHost = authHostNorm.isEmpty ? nil : authHostNorm

        var authLower = authorityRaw.lowercased()
        var explicitPort: String?
        if !authLower.hasPrefix("["), let colon = authLower.firstIndex(of: ":") {
            let portCandidate = String(authLower[authLower.index(after: colon)...])
            if !portCandidate.isEmpty && portCandidate.allSatisfy({ $0 >= "0" && $0 <= "9" }) {
                explicitPort = portCandidate
                authLower = String(authLower[..<colon])
            }
        }

        var pat = "^[a-z][a-z0-9+.-]*://(?:[^/?#:]*\\.)?"
        var hostBody = authLower
        if hostBody.hasPrefix("*.") {
            hostBody = String(hostBody.dropFirst(2))
        } else if hostBody.hasPrefix(".") {
            hostBody = String(hostBody.dropFirst())
        }
        for scalar in hostBody.unicodeScalars {
            appendEscapedRegexScalar(
                &pat,
                scalar: scalar,
                treatStarAsWildcard: true,
                wildcardNoSlash: true,
                treatCaretAsSep: false
            )
        }
        if let explicitPort {
            pat.append(":\(explicitPort)")
        } else {
            pat.append("(?::\\d+)?")
        }

        var endAnchor = false
        if pathPart.hasSuffix("$") {
            endAnchor = true
            pathPart.removeLast()
        }
        for scalar in pathPart.unicodeScalars {
            appendEscapedRegexScalar(
                &pat,
                scalar: scalar,
                treatStarAsWildcard: true,
                wildcardNoSlash: false,
                treatCaretAsSep: true
            )
        }
        if endAnchor {
            pat.append("$")
        }
        let regex = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive])
        return (regex, nil, authorityHost)
    }

    private static func extractHostPatternFromAllowURLRule(
        _ rule: String,
        hasHostless: inout Bool
    ) -> String? {
        if rule.isEmpty || rule.hasPrefix("/") || rule.hasPrefix("*/") || rule.hasPrefix("?") {
            hasHostless = true
            return nil
        }
        var rest = rule
        var anchoredHost = false
        let firstSlash = rule.firstIndex(of: "/")
        if let schemeRange = rule.range(of: "://"),
           firstSlash == nil || schemeRange.lowerBound < (firstSlash ?? rule.endIndex) {
            rest = String(rule[schemeRange.upperBound...])
            anchoredHost = true
        } else if rule.hasPrefix("||") || rule.hasPrefix("//") {
            rest = String(rule.dropFirst(2))
            anchoredHost = true
        }

        var authority = rest.firstIndex(of: "/").map { String(rest[..<$0]) } ?? rest
        while authority.hasSuffix("^") {
            authority.removeLast()
        }
        if let atIdx = authority.lastIndex(of: "@") {
            authority = String(authority[authority.index(after: atIdx)...])
        }
        if !authority.hasPrefix("["), let colon = authority.firstIndex(of: ":") {
            authority = String(authority[..<colon])
        }
        let stripped = authority.replacingOccurrences(of: "*", with: "")
        if authority.isEmpty || stripped.isEmpty {
            hasHostless = true
            return nil
        }
        if !anchoredHost && !authority.hasPrefix("*") {
            return "*" + authority
        }
        return authority
    }

    private static func isValidSchemeRegexUnit(_ ch: UInt16) -> Bool {
        (ch >= 0x61 && ch <= 0x7A) // a-z
            || (ch >= 0x41 && ch <= 0x5A) // A-Z
            || (ch >= 0x30 && ch <= 0x39) // 0-9
            || ch == 0x5E // ^
            || ch == 0x2B // +
            || ch == 0x2D // -
            || ch == 0x3F // ?
            || ch == 0x28 // (
            || ch == 0x29 // )
            || ch == 0x3A // :
            || ch == 0x7C // |
            || ch == 0x5B // [
            || ch == 0x5D // ]
    }

    private static func buildDNSExemptRegex(
        from pattern: String,
        hasHostless: inout Bool
    ) -> NSRegularExpression? {
        if pattern.isEmpty || pattern.hasPrefix("/") || pattern.hasPrefix("^/") {
            hasHostless = true
            return nil
        }

        let units = Array(pattern.utf16)
        let len = units.count
        var scanStart = 0
        var hasScheme = false

        // Locate "://" in UTF-16 code units (matching NSString rangeOfString:@"://")
        var schemeLocation: Int?
        if len >= 3 {
            for idx in 0...(len - 3)
            where units[idx] == 0x3A && units[idx + 1] == 0x2F && units[idx + 2] == 0x2F {
                schemeLocation = idx
                break
            }
        }

        if let schemeLoc = schemeLocation {
            var safeBeforeScheme = (schemeLoc > 0)
            var esc = false
            var pDepth = 0
            var cDepth = 0
            for idx in 0..<schemeLoc {
                let ch = units[idx]
                if esc {
                    esc = false
                    if ch != 0x2B && ch != 0x2D { // '+' or '-'
                        safeBeforeScheme = false
                        break
                    }
                    continue
                }
                if ch == 0x5C { esc = true; continue } // '\\'
                if cDepth > 0 {
                    if ch == 0x5D { cDepth -= 1 } // ']'
                    if !isValidSchemeRegexUnit(ch) {
                        safeBeforeScheme = false
                        break
                    }
                    continue
                }
                if ch == 0x5B { cDepth += 1; continue } // '['
                if ch == 0x28 { pDepth += 1; continue } // '('
                if ch == 0x29 { // ')'
                    if pDepth == 0 {
                        safeBeforeScheme = false
                        break
                    }
                    pDepth -= 1
                    continue
                }
                if (ch == 0x7C && pDepth == 0) || !isValidSchemeRegexUnit(ch) {
                    safeBeforeScheme = false
                    break
                }
            }
            if safeBeforeScheme && !esc && pDepth == 0 && cDepth == 0 {
                hasScheme = true
                scanStart = schemeLoc + 3
            } else {
                hasHostless = true
                return nil
            }
        }

        var esc = false
        var pDepth = 0
        var cDepth = 0
        var cutPos: Int?
        var unsafeAuthorityConstruct = false
        for idx in scanStart..<len {
            let ch = units[idx]
            if esc { esc = false; continue }
            if ch == 0x5C { esc = true; continue } // '\\'
            if cDepth > 0 {
                if ch == 0x3A { // ':'
                    unsafeAuthorityConstruct = true
                }
                if ch == 0x5D { cDepth -= 1 } // ']'
                continue
            }
            if ch == 0x5B { cDepth += 1; continue } // '['
            if ch == 0x28 { pDepth += 1; continue } // '('
            if ch == 0x29 { // ')'
                if pDepth == 0 {
                    unsafeAuthorityConstruct = true
                    break
                }
                pDepth -= 1
                continue
            }
            if ch == 0x40 { // '@'
                unsafeAuthorityConstruct = true
                break
            }
            if ch == 0x2F { // '/'
                if pDepth == 0 {
                    cutPos = idx
                    break
                } else {
                    unsafeAuthorityConstruct = true
                    break
                }
            }
        }

        if unsafeAuthorityConstruct || esc || pDepth != 0 || cDepth != 0 {
            hasHostless = true
            return nil
        }

        let authEnd = cutPos ?? len
        guard authEnd > scanStart else {
            hasHostless = true
            return nil
        }

        let authUnits = Array(units[scanStart..<authEnd])
        let aLen = authUnits.count
        var cleanHostUnits: [UInt16] = []
        cleanHostUnits.reserveCapacity(aLen)
        var strippedTrailingTopPort = false
        var gDepth = 0
        var clsDepth = 0
        var idx = 0

        while idx < aLen {
            let ch = authUnits[idx]
            var isPortColon = false
            var afterColonIdx = idx

            if ch == 0x5C { // '\\'
                if idx + 1 >= aLen {
                    hasHostless = true
                    return nil
                }
                let next = authUnits[idx + 1]
                if clsDepth == 0 && next == 0x3A { // ':'
                    isPortColon = true
                    afterColonIdx = idx + 2
                } else {
                    cleanHostUnits.append(0x5C)
                    cleanHostUnits.append(next)
                    idx += 2
                    continue
                }
            } else if clsDepth > 0 {
                if ch == 0x5D { clsDepth -= 1 } // ']'
                cleanHostUnits.append(ch)
                idx += 1
                continue
            } else if ch == 0x5B { // '['
                clsDepth += 1
                cleanHostUnits.append(0x5B)
                idx += 1
                continue
            } else if ch == 0x28 { // '('
                gDepth += 1
                cleanHostUnits.append(0x28)
                idx += 1
                if idx < aLen && authUnits[idx] == 0x3F { // '?'
                    cleanHostUnits.append(0x3F)
                    idx += 1
                    if idx >= aLen {
                        hasHostless = true
                        return nil
                    }
                    let qch = authUnits[idx]
                    if qch == 0x3D || qch == 0x21 || qch == 0x3C { // '=', '!', '<'
                        hasHostless = true
                        return nil
                    }
                    while idx < aLen {
                        let fch = authUnits[idx]
                        if (fch >= 0x61 && fch <= 0x7A) || (fch >= 0x41 && fch <= 0x5A) || fch == 0x2D {
                            cleanHostUnits.append(fch)
                            idx += 1
                        } else {
                            break
                        }
                    }
                    if idx < aLen && authUnits[idx] == 0x3A { // ':'
                        cleanHostUnits.append(0x3A)
                        idx += 1
                    }
                }
                continue
            } else if ch == 0x29 { // ')'
                if gDepth > 0 { gDepth -= 1 }
                cleanHostUnits.append(0x29)
                idx += 1
                continue
            } else if ch == 0x3A { // ':'
                isPortColon = true
                afterColonIdx = idx + 1
            }

            if isPortColon {
                let baseDepth = gDepth
                idx = afterColonIdx
                var portEsc = false
                var portClsDepth = 0
                while idx < aLen {
                    let pch = authUnits[idx]
                    if portEsc {
                        portEsc = false
                        idx += 1
                        continue
                    }
                    if pch == 0x5C {
                        portEsc = true
                        idx += 1
                        continue
                    }
                    if portClsDepth > 0 {
                        if pch == 0x5D { portClsDepth -= 1 }
                        idx += 1
                        continue
                    }
                    if pch == 0x5B {
                        portClsDepth += 1
                        idx += 1
                        continue
                    }
                    if pch == 0x28 {
                        gDepth += 1
                        idx += 1
                        continue
                    }
                    if pch == 0x29 {
                        if gDepth == baseDepth {
                            break
                        }
                        gDepth -= 1
                        idx += 1
                        continue
                    }
                    if gDepth == baseDepth && (pch == 0x7C || pch == 0x24) { // '|' or '$'
                        break
                    }
                    idx += 1
                }
                if baseDepth == 0 && (idx == aLen || (idx < aLen && authUnits[idx] == 0x24)) {
                    strippedTrailingTopPort = true
                }
                continue
            }

            cleanHostUnits.append(ch)
            idx += 1
        }

        let cleanHost = String(utf16CodeUnits: cleanHostUnits, count: cleanHostUnits.count)
        guard !cleanHost.isEmpty else {
            hasHostless = true
            return nil
        }

        let rightBounded = (cutPos != nil || strippedTrailingTopPort)
        let compiledPat: String
        if hasScheme {
            compiledPat = rightBounded
                ? "^(?:https?://)?\(cleanHost)(?:$|[:/])"
                : "^(?:https?://)?\(cleanHost)"
        } else {
            compiledPat = rightBounded
                ? "\(cleanHost)(?:$|[:/])"
                : cleanHost
        }

        guard let hostRe = try? NSRegularExpression(pattern: compiledPat, options: [.caseInsensitive]) else {
            hasHostless = true
            return nil
        }
        let canaries = [
            "https://__playtools_canary_host__.invalid/",
            "http://__playtools_canary_host__.invalid/",
            "__playtools_canary_host__.invalid/"
        ]
        for canary in canaries {
            let range = NSRange(location: 0, length: (canary as NSString).length)
            if hostRe.firstMatch(in: canary, options: [], range: range) != nil {
                hasHostless = true
                return nil
            }
        }
        return hostRe
    }

    private static func buildIndexedHostTables(
        _ rules: [(rule: String, action: NetworkRuleAction)]
    ) -> (exact: [String: IndexedHostRule], suffix: [String: IndexedHostRule], wildcards: [WildcardHostRule]) {
        var exact: [String: IndexedHostRule] = [:]
        var suffix: [String: IndexedHostRule] = [:]
        var wildcards: [WildcardHostRule] = []
        for (idx, item) in rules.enumerated() where !item.rule.isEmpty {
            let lower = item.rule.lowercased()
            if lower.hasPrefix("=") {
                let key = String(lower.dropFirst())
                if !key.isEmpty && exact[key] == nil {
                    exact[key] = IndexedHostRule(index: idx, action: item.action)
                }
            } else if lower.contains("*") {
                wildcards.append(WildcardHostRule(pattern: lower, index: idx, action: item.action))
            } else {
                let key = lower.hasPrefix(".") ? String(lower.dropFirst()) : lower
                if !key.isEmpty && suffix[key] == nil {
                    suffix[key] = IndexedHostRule(index: idx, action: item.action)
                }
            }
        }
        return (exact, suffix, wildcards)
    }

    private static func buildIndexedHostSets(
        _ rules: [String]
    ) -> (exact: Set<String>, suffix: Set<String>, wildcards: [String]) {
        var exact = Set<String>()
        var suffix = Set<String>()
        var wildcards: [String] = []
        for rule in rules where !rule.isEmpty {
            let lower = rule.lowercased()
            if lower.hasPrefix("=") {
                let key = String(lower.dropFirst())
                if !key.isEmpty { exact.insert(key) }
            } else if lower.contains("*") {
                wildcards.append(lower)
            } else {
                let key = lower.hasPrefix(".") ? String(lower.dropFirst()) : lower
                if !key.isEmpty { suffix.insert(key) }
            }
        }
        return (exact, suffix, wildcards)
    }
}

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
