import Foundation
import Testing
@testable import PlayCover

@Suite
struct PlayRulesTests {
    @Test
    func playRulesDecodesBlocklistGreenlistAndLegacyAliases() throws {
        let modernJSON = """
        {
          "blocklist": ["/tmp/a"],
          "greenlist": ["/tmp/b"],
          "allow": ["/tmp/c"],
          "bypass": ["/tmp/d"]
        }
        """
        let modern = try JSONDecoder().decode(PlayRules.self, from: Data(modernJSON.utf8))
        #expect(modern.blocklist == ["/tmp/a"])
        #expect(modern.greenlist == ["/tmp/b"])
        #expect(modern.allow == ["/tmp/c"])
        #expect(modern.bypass == ["/tmp/d"])

        let legacyJSON = """
        {
          "blacklist": ["/legacy/block"],
          "whitelist": ["/legacy/green"]
        }
        """
        let legacy = try JSONDecoder().decode(PlayRules.self, from: Data(legacyJSON.utf8))
        #expect(legacy.blocklist == ["/legacy/block"])
        #expect(legacy.greenlist == ["/legacy/green"])
        #expect(legacy.allow == nil)
        #expect(legacy.bypass == nil)
    }

    @Test
    func ruleTemplateRenderAndBuildRules() {
        var template = RuleTemplate(data: ["BundleID": "com.example.app"])
        template.User = "tester"
        #expect(
            template.render(template: "${Home}/Library/${BundleID}/${User}/${Unknown}") ==
                "${Home}/Library/com.example.app/tester/${Unknown}"
        )

        let built = PlayRules.buildRules(
            rules: [
                "(subpath \"${HomeDirectory}/Library/Containers/${BundleID}\")",
                "(literal \"/Users/${NSUserName}\")"
            ],
            bundleID: "io.playcover.UnitTest"
        )
        #expect(built.count == 2)
        let expectedHome = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(built[0] == "(subpath \"\(expectedHome)/Library/Containers/io.playcover.UnitTest\")")
        #expect(built[1] == "(literal \"/Users/\(NSUserName())\")")
    }

    @Test
    func ruleTemplateSinglePassDeterministicRenderAndDateDynamicMember() {
        let t1 = RuleTemplate(data: ["A": "${B}", "B": "expanded"])
        let t2 = RuleTemplate(data: ["B": "expanded", "A": "${B}"])
        #expect(t1.render(template: "${A}") == "${B}")
        #expect(t2.render(template: "${A}") == "${B}")
        #expect(t1.render(template: "${A}-${B}-${Missing}") == "${B}-expanded-${Missing}")
        #expect(t1.render(template: "${unclosed") == "${unclosed")
        #expect(t1.render(template: "${outer ${B}}") == "${outer expanded}")

        var dateTemplate = RuleTemplate()
        let fallbackDate: Date = dateTemplate.missingDate
        #expect(fallbackDate == Date(timeIntervalSince1970: 0))

        let sampleDate = Date(timeIntervalSince1970: 1_700_000_000)
        dateTemplate.created = sampleDate
        let roundTripped: Date = dateTemplate.created
        #expect(abs(roundTripped.timeIntervalSince1970 - sampleDate.timeIntervalSince1970) <= 1.0)
    }

    @Test
    func playRulesPrecedenceNullFallbackAndInvalidType() throws {
        let mixedJSON = """
        {
          "blocklist": ["/modern/block"],
          "blacklist": ["/legacy/block"],
          "greenlist": ["/modern/green"],
          "whitelist": ["/legacy/green"]
        }
        """
        let mixed = try JSONDecoder().decode(PlayRules.self, from: Data(mixedJSON.utf8))
        #expect(mixed.blocklist == ["/modern/block"])
        #expect(mixed.greenlist == ["/modern/green"])

        let nullFallbackJSON = """
        {
          "blocklist": null,
          "blacklist": ["/legacy/block"],
          "greenlist": null,
          "whitelist": ["/legacy/green"]
        }
        """
        let fallback = try JSONDecoder().decode(PlayRules.self, from: Data(nullFallbackJSON.utf8))
        #expect(fallback.blocklist == ["/legacy/block"])
        #expect(fallback.greenlist == ["/legacy/green"])

        let invalidTypeJSON = """
        {
          "blocklist": 123
        }
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PlayRules.self, from: Data(invalidTypeJSON.utf8))
        }
    }
}
