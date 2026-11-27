import CoreFoundation
import Foundation
import Testing

@Suite
struct PTPasteboardTextSanitizerTests {
    @Test
    func lineEndingNormalization() {
        let input = "a\r\nb\rc\u{2028}d\u{2029}e\nf"
        #expect(PTPasteboardTextSanitizer.sanitize(input) == "a\nb\nc\nd\ne\nf")

        var crlfOptions = PTPasteboardTextSanitizer.Options.default
        crlfOptions.lineEndingStyle = .crlf
        #expect(PTPasteboardTextSanitizer.sanitize(input, options: crlfOptions) == "a\r\nb\r\nc\r\nd\r\ne\r\nf")
    }

    @Test
    func controlCharactersAndTabsAndBOMAndUnicodeNormalization() {
        let raw = "\u{FEFF}he\u{0000}l\u{0007}lo\tworld\u{007F}\u{0085}e\u{0301}👍🏽"
        #expect(PTPasteboardTextSanitizer.sanitize(raw) == "hello\tworldé👍🏽")

        var noTabs = PTPasteboardTextSanitizer.Options.default
        noTabs.allowTabs = false
        #expect(PTPasteboardTextSanitizer.sanitize("a\tb\u{0001}c", options: noTabs) == "abc")
    }

    @Test
    func truncationPreservingGraphemes() {
        let big = String(repeating: "x", count: 100_000)
        var capped = PTPasteboardTextSanitizer.Options.default
        capped.maxUTF16Units = 4096
        let truncated = PTPasteboardTextSanitizer.sanitize(big, options: capped)
        #expect(truncated.utf16.count == 4096)

        // "a😀" has UTF-16 count 1 + 2 = 3; capping at 2 must preserve "a" cleanly without splitting surrogate
        #expect(PTPasteboardTextSanitizer.truncatePreservingGraphemes("a😀", maxUTF16Units: 2) == "a")
        #expect(PTPasteboardTextSanitizer.truncatePreservingGraphemes("a😀", maxUTF16Units: 0) == "")
    }

    @Test
    func optionalAndHTMLFallbackAndResolutionPriority() {
        #expect(PTPasteboardTextSanitizer.sanitizeOptional(nil) == nil)
        #expect(PTPasteboardTextSanitizer.sanitizeOptional("ok\r\n") == "ok\n")

        let html = """
        <style>body{color:red;}</style><script>alert(1)</script>
        <p>Hello &amp; &#39;world&#39;&nbsp;&#x21;</p><div>Next<br/>Line</div>
        """
        let extracted = PTPasteboardTextSanitizer.extractPlainText(fromHTMLFallback: html)
        #expect(extracted.contains("Hello & 'world' !"))
        #expect(extracted.contains("Next\nLine"))
        #expect(!extracted.contains("alert(1)"))

        #expect(
            PTPasteboardTextSanitizer.resolveSanitizedText(plainText: "direct\r\n", htmlFallback: "<p>html</p>") ==
                "direct\n"
        )
        #expect(
            PTPasteboardTextSanitizer.resolveSanitizedText(plainText: "", htmlFallback: "<p>fallback</p>") ==
                "fallback\n"
        )
        #expect(
            PTPasteboardTextSanitizer.resolveSanitizedText(plainText: "", htmlFallback: nil) == ""
        )
        #expect(
            PTPasteboardTextSanitizer.resolveSanitizedText(plainText: nil, htmlFallback: nil) == nil
        )
    }

    @Test
    func pathologicalLeadingBOMsAndAllBOMInput() {
        let bomPrefix = String(repeating: "\u{FEFF}", count: 200_000)
        let start = CFAbsoluteTimeGetCurrent()
        let stripped = PTPasteboardTextSanitizer.sanitize(bomPrefix + "hello")
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        #expect(stripped == "hello")
        #expect(elapsed < 0.5)

        #expect(PTPasteboardTextSanitizer.sanitize("\u{FEFF}\u{FEFF}\u{FEFF}") == "")

        var keepBOM = PTPasteboardTextSanitizer.Options.default
        keepBOM.stripLeadingBOM = false
        #expect(PTPasteboardTextSanitizer.sanitize("\u{FEFF}abc", options: keepBOM) == "\u{FEFF}abc")
    }

    @Test
    func htmlEntitySinglePassNoDoubleDecode() {
        let html = "<p>&amp;#39; &amp;#x3C; &amp;lt; &#x26;#39;</p>"
        let extracted = PTPasteboardTextSanitizer.extractPlainText(fromHTMLFallback: html)
        #expect(extracted == "&#39; &#x3C; &lt; &#39;\n")
    }

    @Test
    func malformedNumericEntitiesAndUnicodeBoundaries() {
        let malformed = "<p>&#999999999999; &#55296; &#x110000; &#0; &unknown; & &#; &#x;</p>"
        let extracted = PTPasteboardTextSanitizer.extractPlainText(fromHTMLFallback: malformed)
        #expect(extracted == "&#999999999999; &#55296; &#x110000;  &unknown; & &#; &#x;\n")

        // ZWJ family emoji ("👨‍👩‍👧‍👦") has 11 UTF-16 units; truncating at 5 must drop the entire grapheme cluster
        #expect(PTPasteboardTextSanitizer.truncatePreservingGraphemes("👨‍👩‍👧‍👦", maxUTF16Units: 5) == "")
        // Skin-tone emoji ("👍🏽") has 4 UTF-16 units; truncating at 2 must drop it
        #expect(PTPasteboardTextSanitizer.truncatePreservingGraphemes("👍🏽", maxUTF16Units: 2) == "")
        #expect(PTPasteboardTextSanitizer.truncatePreservingGraphemes("abc", maxUTF16Units: -5) == "")

        var rawControls = PTPasteboardTextSanitizer.Options.default
        rawControls.stripUnsafeControlCharacters = false
        rawControls.allowTabs = false
        #expect(PTPasteboardTextSanitizer.sanitize("a\tb\u{0001}c", options: rawControls) == "a\tb\u{0001}c")

        var noNFC = PTPasteboardTextSanitizer.Options.default
        noNFC.normalizeUnicodeNFC = false
        #expect(PTPasteboardTextSanitizer.sanitize("e\u{0301}", options: noNFC) == "e\u{0301}")
    }

    @Test
    func largeCombiningAndEmojiInputLinearLatency() {
        let unit = "e\u{0301}👍🏽\r\n"
        let big = String(repeating: unit, count: 100_000)

        let startDefault = CFAbsoluteTimeGetCurrent()
        let truncated = PTPasteboardTextSanitizer.sanitize(big)
        let elapsedDefault = CFAbsoluteTimeGetCurrent() - startDefault
        #expect(elapsedDefault < 0.5)

        let expectedUnit = "é👍🏽\n"
        let expectedPrefix = String(repeating: expectedUnit, count: 43_690) + "é"
        #expect(truncated.utf16.count == 262_141)
        #expect(truncated == expectedPrefix)

        var unboundedOptions = PTPasteboardTextSanitizer.Options.default
        unboundedOptions.maxUTF16Units = nil
        let startUnbounded = CFAbsoluteTimeGetCurrent()
        let unbounded = PTPasteboardTextSanitizer.sanitize(big, options: unboundedOptions)
        let elapsedUnbounded = CFAbsoluteTimeGetCurrent() - startUnbounded
        #expect(elapsedUnbounded < 0.5)
        #expect(unbounded.utf16.count == 600_000)
        #expect(unbounded.hasPrefix("é👍🏽\né👍🏽\n"))
        #expect(unbounded.hasSuffix("é👍🏽\n"))

        // Chunk boundary (2048 scalars) must preserve combining marks & Hangul Jamo L+V+T composition
        let boundaryPad = String(repeating: "a", count: 2047)
        let hangulBoundary = boundaryPad + "\u{1100}\u{1161}\u{11A8}" + "e\u{0301}"
        let sanitizedBoundary = PTPasteboardTextSanitizer.sanitize(hangulBoundary)
        #expect(sanitizedBoundary == boundaryPad + "각é")
    }
}
