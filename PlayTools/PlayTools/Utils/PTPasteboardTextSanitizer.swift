//
//  PTPasteboardTextSanitizer.swift
//  PlayTools
//

import Foundation

public enum PTPasteboardTextSanitizer {
    public enum LineEndingStyle: Equatable {
        case lf
        case crlf
    }

    public struct Options: Equatable {
        public var lineEndingStyle: LineEndingStyle
        public var stripUnsafeControlCharacters: Bool
        public var allowTabs: Bool
        public var stripLeadingBOM: Bool
        public var normalizeUnicodeNFC: Bool
        public var maxUTF16Units: Int?

        public static let `default` = Options()

        public init(
            lineEndingStyle: LineEndingStyle = .lf,
            stripUnsafeControlCharacters: Bool = true,
            allowTabs: Bool = true,
            stripLeadingBOM: Bool = true,
            normalizeUnicodeNFC: Bool = true,
            maxUTF16Units: Int? = 262_144
        ) {
            self.lineEndingStyle = lineEndingStyle
            self.stripUnsafeControlCharacters = stripUnsafeControlCharacters
            self.allowTabs = allowTabs
            self.stripLeadingBOM = stripLeadingBOM
            self.normalizeUnicodeNFC = normalizeUnicodeNFC
            self.maxUTF16Units = maxUTF16Units
        }
    }

    private static func isSafeNFCBoundary(_ scalar: UnicodeScalar) -> Bool {
        let val = scalar.value
        if (val >= 0x1160 && val <= 0x11FF) || (val >= 0xD7B0 && val <= 0xD7FF) {
            return false
        }
        return scalar.properties.canonicalCombiningClass == .notReordered
    }

    private static func isASCIISafeBreak(_ value: UInt32) -> Bool {
        value == 0x09 || value == 0x0A || (value >= 0x20 && value <= 0x7E)
    }

    public static func sanitize(_ input: String, options: Options = .default) -> String {
        if let maxUnits = options.maxUTF16Units, maxUnits <= 0 {
            return ""
        }

        let scalars = input.unicodeScalars
        var idx = scalars.startIndex
        if options.stripLeadingBOM {
            while idx < scalars.endIndex && scalars[idx].value == 0xFEFF {
                idx = scalars.index(after: idx)
            }
        }

        // Normalize CRLF, CR, LS (U+2028), and PS (U+2029) to LF via scalar scan
        // so Swift Character clustering on "\r\n" is handled deterministically,
        // and normalize NFC in O(n) chunks at safe starter boundaries.
        let chunkLimit = 2048
        var chunk = String.UnicodeScalarView()
        chunk.reserveCapacity(chunkLimit)
        var result = ""
        var resultUTF16Count = 0
        var lastAppendedValue: UInt32 = 0
        var chunkCount = 0

        func flushChunk() {
            guard chunkCount > 0 else { return }
            var piece = String(chunk)
            chunk.removeAll(keepingCapacity: true)
            chunkCount = 0
            if options.normalizeUnicodeNFC {
                piece = piece.precomposedStringWithCanonicalMapping
            }
            result.append(piece)
            resultUTF16Count += piece.utf16.count
        }

        func appendNormalizedScalar(_ scalar: UnicodeScalar) -> Bool {
            if chunkCount >= chunkLimit && isSafeNFCBoundary(scalar) {
                flushChunk()
            }
            if let maxUnits = options.maxUTF16Units,
               chunkCount == 0,
               resultUTF16Count > maxUnits,
               lastAppendedValue == 0x0A ||
                (isASCIISafeBreak(lastAppendedValue) && isASCIISafeBreak(scalar.value)) {
                return false
            }
            if let maxUnits = options.maxUTF16Units,
               resultUTF16Count > maxUnits,
               lastAppendedValue == 0x0A {
                flushChunk()
                return false
            }
            chunk.append(scalar)
            chunkCount += 1
            lastAppendedValue = scalar.value
            return true
        }

        let lfScalar = UnicodeScalar(0x0A)
        let crScalar = UnicodeScalar(0x0D)

        while idx < scalars.endIndex {
            let scalar = scalars[idx]
            let val = scalar.value
            if val == 0x0D {
                let nextIdx = scalars.index(after: idx)
                if nextIdx < scalars.endIndex && scalars[nextIdx].value == 0x0A {
                    idx = nextIdx
                }
                if options.lineEndingStyle == .crlf, let crScalar {
                    if !appendNormalizedScalar(crScalar) { break }
                }
                if let lfScalar {
                    if !appendNormalizedScalar(lfScalar) { break }
                }
            } else if val == 0x2028 || val == 0x2029 || val == 0x0A {
                if options.lineEndingStyle == .crlf, let crScalar {
                    if !appendNormalizedScalar(crScalar) { break }
                }
                if let lfScalar {
                    if !appendNormalizedScalar(lfScalar) { break }
                }
            } else if val == 0x09 {
                if options.allowTabs || !options.stripUnsafeControlCharacters {
                    if !appendNormalizedScalar(scalar) { break }
                }
            } else if options.stripUnsafeControlCharacters &&
                        ((val <= 0x1F) || (val >= 0x7F && val <= 0x9F)) {
                // Drop NUL, C0 controls, DEL, and C1 controls.
            } else {
                if !appendNormalizedScalar(scalar) { break }
            }
            idx = scalars.index(after: idx)
        }

        flushChunk()

        if let maxUnits = options.maxUTF16Units {
            result = truncatePreservingGraphemes(result, maxUTF16Units: maxUnits)
        }
        return result
    }

    public static func sanitizeOptional(_ input: String?, options: Options = .default) -> String? {
        guard let input else { return nil }
        return sanitize(input, options: options)
    }

    public static func truncatePreservingGraphemes(_ text: String, maxUTF16Units: Int) -> String {
        guard maxUTF16Units > 0 else { return "" }
        if text.utf16.count <= maxUTF16Units {
            return text
        }
        var units = 0
        var endIndex = text.startIndex
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let next = text.index(after: cursor)
            let charUnits = text[cursor..<next].utf16.count
            if units + charUnits > maxUTF16Units {
                break
            }
            units += charUnits
            endIndex = next
            cursor = next
        }
        return String(text[..<endIndex])
    }

    public static func extractPlainText(fromHTMLFallback html: String, options: Options = .default) -> String {
        var text = html
        let stripBlockTags = [
            "(?is)<script\\b[^>]*>.*?</script>",
            "(?is)<style\\b[^>]*>.*?</style>"
        ]
        for pattern in stripBlockTags {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(
            of: "(?i)<br\\s*/?>|</p>|</div>|</li>",
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeBasicHTMLEntities(text)
        return sanitize(text, options: options)
    }

    public static func resolveSanitizedText(
        plainText: String?,
        htmlFallback: String?,
        options: Options = .default
    ) -> String? {
        if let plain = sanitizeOptional(plainText, options: options), !plain.isEmpty {
            return plain
        }
        if let htmlFallback {
            let extracted = extractPlainText(fromHTMLFallback: htmlFallback, options: options)
            if !extracted.isEmpty {
                return extracted
            }
        }
        if plainText != nil {
            return ""
        }
        return nil
    }

    private static func decodeBasicHTMLEntities(_ input: String) -> String {
        let pattern = "&(?:nbsp|lt|gt|quot|apos|amp|#[xX][0-9A-Fa-f]+|#[0-9]+);"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let nsString = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return input }

        let mutable = NSMutableString(string: input)
        for match in matches.reversed() {
            let token = nsString.substring(with: match.range)
            let replacement: String?
            switch token {
            case "&nbsp;":
                replacement = " "
            case "&lt;":
                replacement = "<"
            case "&gt;":
                replacement = ">"
            case "&quot;":
                replacement = "\""
            case "&apos;":
                replacement = "'"
            case "&amp;":
                replacement = "&"
            default:
                if token.hasPrefix("&#x") || token.hasPrefix("&#X") {
                    let hexStr = String(token.dropFirst(3).dropLast())
                    if let code = UInt32(hexStr, radix: 16), let scalar = UnicodeScalar(code) {
                        replacement = String(scalar)
                    } else {
                        replacement = nil
                    }
                } else if token.hasPrefix("&#") {
                    let decStr = String(token.dropFirst(2).dropLast())
                    if let code = UInt32(decStr, radix: 10), let scalar = UnicodeScalar(code) {
                        replacement = String(scalar)
                    } else {
                        replacement = nil
                    }
                } else {
                    replacement = nil
                }
            }
            if let replacement {
                mutable.replaceCharacters(in: match.range, with: replacement)
            }
        }
        return mutable as String
    }
}
