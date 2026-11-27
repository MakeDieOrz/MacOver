import Testing
@testable import PlayCover

@Suite
struct NetworkRuleParserTests {
    @Test
    func enableDisableAndActiveBody() {
        #expect(NetworkRuleParser.isRuleEnabled("ads.example.com"))
        #expect(!NetworkRuleParser.isRuleEnabled("  #!OFF ads.example.com"))
        #expect(NetworkRuleParser.activeBody("  #!OFF   ads.example.com  ") == "ads.example.com")
        #expect(NetworkRuleParser.activeBody("  example.com\n") == "example.com")
    }

    @Test
    func stripInlineComment() {
        #expect(NetworkRuleParser.stripInlineComment("ads.example.com # tracker") == "ads.example.com")
        #expect(NetworkRuleParser.stripInlineComment("ads.example.com\t// comment") == "ads.example.com")
        #expect(NetworkRuleParser.stripInlineComment("https://example.com/path") == "https://example.com/path")
        #expect(NetworkRuleParser.stripInlineComment("foo\\#bar [#] # trailing") == "foo\\#bar [#]")
    }

    @Test
    func classifyRuleKindsAndAllowMarkers() {
        let domainBlock = NetworkRuleParser.classifyRule("tracker.example.com")
        #expect(domainBlock.isEnabled)
        #expect(!domainBlock.isAllow)
        #expect(domainBlock.kindKey == "settings.network.kind.domain")

        let atAllow = NetworkRuleParser.classifyRule("@@DOMAIN-SUFFIX,example.com,REJECT")
        #expect(atAllow.isAllow)
        #expect(atAllow.kindKey == "settings.network.kind.suffix")

        let bangAllow = NetworkRuleParser.classifyRule("!*.cdn.example.com")
        #expect(bangAllow.isAllow)
        #expect(bangAllow.kindKey == "settings.network.kind.suffix")

        let directiveAllow = NetworkRuleParser.classifyRule("DOMAIN-KEYWORD,telemetry,DIRECT")
        #expect(directiveAllow.isAllow)
        #expect(directiveAllow.kindKey == "settings.network.kind.keyword")

        let allowOption = NetworkRuleParser.classifyRule("HOST-SUFFIX,safe.org,ALLOW")
        #expect(allowOption.isAllow)
        #expect(allowOption.kindKey == "settings.network.kind.suffix")

        let regexRule = NetworkRuleParser.classifyRule("#!OFF ^https://ads\\.example\\.com/.*$")
        #expect(!regexRule.isEnabled)
        #expect(!regexRule.isAllow)
        #expect(regexRule.kindKey == "settings.network.kind.regex")

        let slashRegex = NetworkRuleParser.classifyRule("/^https:\\/\\/ad/")
        #expect(slashRegex.kindKey == "settings.network.kind.regex")

        let urlRule = NetworkRuleParser.classifyRule("example.com/ads/banner.js")
        #expect(urlRule.kindKey == "settings.network.kind.url")
    }

    @Test
    func isImportableRuleLineAndNormalizedAllowRule() {
        #expect(!NetworkRuleParser.isImportableRuleLine(""))
        #expect(!NetworkRuleParser.isImportableRuleLine("# comment"))
        #expect(!NetworkRuleParser.isImportableRuleLine("// comment"))
        #expect(!NetworkRuleParser.isImportableRuleLine("; comment"))
        #expect(!NetworkRuleParser.isImportableRuleLine("! comment"))
        #expect(!NetworkRuleParser.isImportableRuleLine("!\tcomment"))
        #expect(!NetworkRuleParser.isImportableRuleLine("![Adblock Plus 2.0]"))
        #expect(!NetworkRuleParser.isImportableRuleLine("!"))
        #expect(!NetworkRuleParser.isImportableRuleLine("#!OFF"))
        #expect(NetworkRuleParser.isImportableRuleLine("#!OFF ads.example.com"))
        #expect(NetworkRuleParser.isImportableRuleLine("ads.example.com"))

        #expect(NetworkRuleParser.normalizedAllowRule("ads.example.com") == "@@ads.example.com")
        #expect(NetworkRuleParser.normalizedAllowRule("@@ads.example.com") == "@@ads.example.com")
        #expect(
            NetworkRuleParser.normalizedAllowRule("DOMAIN,api.example.com,DIRECT") == "DOMAIN,api.example.com,DIRECT"
        )
    }

    @Test
    func disabledTabWhitespaceCRLFAndNormalizedDisabledRule() {
        #expect(!NetworkRuleParser.isRuleEnabled("  #!OFF\tads.example.com"))
        #expect(NetworkRuleParser.activeBody("  #!OFF\tads.example.com\r\n") == "ads.example.com")
        #expect(NetworkRuleParser.isRuleEnabled("#!OFFicial.example.com"))

        #expect(!NetworkRuleParser.isImportableRuleLine("   "))
        #expect(!NetworkRuleParser.isImportableRuleLine("  # comment"))
        #expect(!NetworkRuleParser.isImportableRuleLine("!\r"))
        #expect(!NetworkRuleParser.isImportableRuleLine("  #!OFF  "))
        #expect(!NetworkRuleParser.isImportableRuleLine("  #!OFF\t  "))
        #expect(NetworkRuleParser.isImportableRuleLine("  #!OFF\tads.example.com"))

        let normalizedDisabled = NetworkRuleParser.normalizedAllowRule("#!OFF ads.example.com")
        #expect(normalizedDisabled == "#!OFF @@ads.example.com")
        let metaDisabledAllow = NetworkRuleParser.classifyRule(normalizedDisabled)
        #expect(!metaDisabledAllow.isEnabled)
        #expect(metaDisabledAllow.isAllow)
        #expect(metaDisabledAllow.body == "@@ads.example.com")

        #expect(NetworkRuleParser.stripInlineComment("# comment") == "")
        #expect(NetworkRuleParser.stripInlineComment(" # comment") == "")
        #expect(NetworkRuleParser.stripInlineComment("// comment") == "")
        #expect(
            NetworkRuleParser.stripInlineComment("  #!OFF ads.example.com # c") == "#!OFF ads.example.com"
        )
        #expect(
            NetworkRuleParser.stripInlineComment("  #!OFF\tads.example.com // c") == "#!OFF\tads.example.com"
        )
        #expect(
            NetworkRuleParser.stripInlineComment("ads.example.com #!OFF inline") == "ads.example.com"
        )

        #expect(!NetworkRuleParser.isImportableRuleLine("#!OFF # comment"))
        #expect(!NetworkRuleParser.isImportableRuleLine("#!OFF // comment"))
        #expect(!NetworkRuleParser.isImportableRuleLine("  #!OFF ; comment"))
        #expect(!NetworkRuleParser.isImportableRuleLine("#!OFF ! comment"))
        #expect(!NetworkRuleParser.isImportableRuleLine("#!OFF ![Adblock]"))
        #expect(!NetworkRuleParser.isImportableRuleLine("#!OFF !"))
        #expect(NetworkRuleParser.isImportableRuleLine("#!OFF !*.cdn.example.com"))
    }

    @Test
    func classifyActionVsPatternAllowKeywordAndBareBang() {
        let keywordAllowBlock = NetworkRuleParser.classifyRule("DOMAIN-KEYWORD,allow,REJECT")
        #expect(!keywordAllowBlock.isAllow)
        #expect(keywordAllowBlock.kindKey == "settings.network.kind.keyword")

        let keywordDirectBlock = NetworkRuleParser.classifyRule("DOMAIN-KEYWORD,direct,REJECT")
        #expect(!keywordDirectBlock.isAllow)

        let noResolveDirect = NetworkRuleParser.classifyRule("DOMAIN-SUFFIX,safe.org,DIRECT,no-resolve")
        #expect(noResolveDirect.isAllow)
        #expect(noResolveDirect.kindKey == "settings.network.kind.suffix")

        let bareBang = NetworkRuleParser.classifyRule("!")
        #expect(!bareBang.isAllow)
    }
}
