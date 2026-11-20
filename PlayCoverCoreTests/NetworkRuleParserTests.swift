import XCTest
@testable import PlayCover

final class NetworkRuleParserTests: XCTestCase {
    func testEnableDisableAndActiveBody() {
        XCTAssertTrue(NetworkRuleParser.isRuleEnabled("ads.example.com"))
        XCTAssertFalse(NetworkRuleParser.isRuleEnabled("  #!OFF ads.example.com"))
        XCTAssertEqual(NetworkRuleParser.activeBody("  #!OFF   ads.example.com  "), "ads.example.com")
        XCTAssertEqual(NetworkRuleParser.activeBody("  example.com\n"), "example.com")
    }

    func testStripInlineComment() {
        XCTAssertEqual(NetworkRuleParser.stripInlineComment("ads.example.com # tracker"), "ads.example.com")
        XCTAssertEqual(NetworkRuleParser.stripInlineComment("ads.example.com\t// comment"), "ads.example.com")
        XCTAssertEqual(NetworkRuleParser.stripInlineComment("https://example.com/path"), "https://example.com/path")
        XCTAssertEqual(NetworkRuleParser.stripInlineComment("foo\\#bar [#] # trailing"), "foo\\#bar [#]")
    }

    func testClassifyRuleKindsAndAllowMarkers() {
        let domainBlock = NetworkRuleParser.classifyRule("tracker.example.com")
        XCTAssertTrue(domainBlock.isEnabled)
        XCTAssertFalse(domainBlock.isAllow)
        XCTAssertEqual(domainBlock.kindKey, "settings.network.kind.domain")

        let atAllow = NetworkRuleParser.classifyRule("@@DOMAIN-SUFFIX,example.com,REJECT")
        XCTAssertTrue(atAllow.isAllow)
        XCTAssertEqual(atAllow.kindKey, "settings.network.kind.suffix")

        let bangAllow = NetworkRuleParser.classifyRule("!*.cdn.example.com")
        XCTAssertTrue(bangAllow.isAllow)
        XCTAssertEqual(bangAllow.kindKey, "settings.network.kind.suffix")

        let directiveAllow = NetworkRuleParser.classifyRule("DOMAIN-KEYWORD,telemetry,DIRECT")
        XCTAssertTrue(directiveAllow.isAllow)
        XCTAssertEqual(directiveAllow.kindKey, "settings.network.kind.keyword")

        let allowOption = NetworkRuleParser.classifyRule("HOST-SUFFIX,safe.org,ALLOW")
        XCTAssertTrue(allowOption.isAllow)
        XCTAssertEqual(allowOption.kindKey, "settings.network.kind.suffix")

        let regexRule = NetworkRuleParser.classifyRule("#!OFF ^https://ads\\.example\\.com/.*$")
        XCTAssertFalse(regexRule.isEnabled)
        XCTAssertFalse(regexRule.isAllow)
        XCTAssertEqual(regexRule.kindKey, "settings.network.kind.regex")

        let slashRegex = NetworkRuleParser.classifyRule("/^https:\\/\\/ad/")
        XCTAssertEqual(slashRegex.kindKey, "settings.network.kind.regex")

        let urlRule = NetworkRuleParser.classifyRule("example.com/ads/banner.js")
        XCTAssertEqual(urlRule.kindKey, "settings.network.kind.url")
    }

    func testIsImportableRuleLineAndNormalizedAllowRule() {
        XCTAssertFalse(NetworkRuleParser.isImportableRuleLine(""))
        XCTAssertFalse(NetworkRuleParser.isImportableRuleLine("# comment"))
        XCTAssertFalse(NetworkRuleParser.isImportableRuleLine("// comment"))
        XCTAssertFalse(NetworkRuleParser.isImportableRuleLine("; comment"))
        XCTAssertFalse(NetworkRuleParser.isImportableRuleLine("! comment"))
        XCTAssertFalse(NetworkRuleParser.isImportableRuleLine("!\tcomment"))
        XCTAssertFalse(NetworkRuleParser.isImportableRuleLine("![Adblock Plus 2.0]"))
        XCTAssertFalse(NetworkRuleParser.isImportableRuleLine("!"))
        XCTAssertFalse(NetworkRuleParser.isImportableRuleLine("#!OFF"))
        XCTAssertTrue(NetworkRuleParser.isImportableRuleLine("#!OFF ads.example.com"))
        XCTAssertTrue(NetworkRuleParser.isImportableRuleLine("ads.example.com"))

        XCTAssertEqual(NetworkRuleParser.normalizedAllowRule("ads.example.com"), "@@ads.example.com")
        XCTAssertEqual(NetworkRuleParser.normalizedAllowRule("@@ads.example.com"), "@@ads.example.com")
        XCTAssertEqual(NetworkRuleParser.normalizedAllowRule("DOMAIN,api.example.com,DIRECT"), "DOMAIN,api.example.com,DIRECT")
    }

    func testDisabledTabWhitespaceCRLFAndNormalizedDisabledRule() {
        XCTAssertFalse(NetworkRuleParser.isRuleEnabled("  #!OFF\tads.example.com"))
        XCTAssertEqual(NetworkRuleParser.activeBody("  #!OFF\tads.example.com\r\n"), "ads.example.com")
        XCTAssertTrue(NetworkRuleParser.isRuleEnabled("#!OFFicial.example.com"))

        XCTAssertFalse(NetworkRuleParser.isImportableRuleLine("   "))
        XCTAssertFalse(NetworkRuleParser.isImportableRuleLine("  # comment"))
        XCTAssertFalse(NetworkRuleParser.isImportableRuleLine("!\r"))
        XCTAssertFalse(NetworkRuleParser.isImportableRuleLine("  #!OFF  "))
        XCTAssertFalse(NetworkRuleParser.isImportableRuleLine("  #!OFF\t  "))
        XCTAssertTrue(NetworkRuleParser.isImportableRuleLine("  #!OFF\tads.example.com"))

        let normalizedDisabled = NetworkRuleParser.normalizedAllowRule("#!OFF ads.example.com")
        XCTAssertEqual(normalizedDisabled, "#!OFF @@ads.example.com")
        let metaDisabledAllow = NetworkRuleParser.classifyRule(normalizedDisabled)
        XCTAssertFalse(metaDisabledAllow.isEnabled)
        XCTAssertTrue(metaDisabledAllow.isAllow)
        XCTAssertEqual(metaDisabledAllow.body, "@@ads.example.com")

        XCTAssertEqual(NetworkRuleParser.stripInlineComment("# comment"), "")
        XCTAssertEqual(NetworkRuleParser.stripInlineComment(" # comment"), "")
        XCTAssertEqual(NetworkRuleParser.stripInlineComment("// comment"), "")
        XCTAssertEqual(
            NetworkRuleParser.stripInlineComment("  #!OFF ads.example.com # c"),
            "#!OFF ads.example.com"
        )
        XCTAssertEqual(
            NetworkRuleParser.stripInlineComment("  #!OFF\tads.example.com // c"),
            "#!OFF\tads.example.com"
        )
        XCTAssertEqual(
            NetworkRuleParser.stripInlineComment("ads.example.com #!OFF inline"),
            "ads.example.com"
        )

        XCTAssertFalse(NetworkRuleParser.isImportableRuleLine("#!OFF # comment"))
        XCTAssertFalse(NetworkRuleParser.isImportableRuleLine("#!OFF // comment"))
        XCTAssertFalse(NetworkRuleParser.isImportableRuleLine("  #!OFF ; comment"))
        XCTAssertFalse(NetworkRuleParser.isImportableRuleLine("#!OFF ! comment"))
        XCTAssertFalse(NetworkRuleParser.isImportableRuleLine("#!OFF ![Adblock]"))
        XCTAssertFalse(NetworkRuleParser.isImportableRuleLine("#!OFF !"))
        XCTAssertTrue(NetworkRuleParser.isImportableRuleLine("#!OFF !*.cdn.example.com"))
    }

    func testClassifyActionVsPatternAllowKeywordAndBareBang() {
        let keywordAllowBlock = NetworkRuleParser.classifyRule("DOMAIN-KEYWORD,allow,REJECT")
        XCTAssertFalse(keywordAllowBlock.isAllow)
        XCTAssertEqual(keywordAllowBlock.kindKey, "settings.network.kind.keyword")

        let keywordDirectBlock = NetworkRuleParser.classifyRule("DOMAIN-KEYWORD,direct,REJECT")
        XCTAssertFalse(keywordDirectBlock.isAllow)

        let noResolveDirect = NetworkRuleParser.classifyRule("DOMAIN-SUFFIX,safe.org,DIRECT,no-resolve")
        XCTAssertTrue(noResolveDirect.isAllow)
        XCTAssertEqual(noResolveDirect.kindKey, "settings.network.kind.suffix")

        let bareBang = NetworkRuleParser.classifyRule("!")
        XCTAssertFalse(bareBang.isAllow)
    }
}
