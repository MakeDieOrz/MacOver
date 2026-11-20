import Foundation
import XCTest
@testable import PlayCover

final class PlayRulesTests: XCTestCase {
    func testPlayRulesDecodesBlocklistGreenlistAndLegacyAliases() throws {
        let modernJSON = """
        {
          "blocklist": ["/tmp/a"],
          "greenlist": ["/tmp/b"],
          "allow": ["/tmp/c"],
          "bypass": ["/tmp/d"]
        }
        """
        let modern = try JSONDecoder().decode(PlayRules.self, from: Data(modernJSON.utf8))
        XCTAssertEqual(modern.blocklist, ["/tmp/a"])
        XCTAssertEqual(modern.greenlist, ["/tmp/b"])
        XCTAssertEqual(modern.allow, ["/tmp/c"])
        XCTAssertEqual(modern.bypass, ["/tmp/d"])

        let legacyJSON = """
        {
          "blacklist": ["/legacy/block"],
          "whitelist": ["/legacy/green"]
        }
        """
        let legacy = try JSONDecoder().decode(PlayRules.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(legacy.blocklist, ["/legacy/block"])
        XCTAssertEqual(legacy.greenlist, ["/legacy/green"])
        XCTAssertNil(legacy.allow)
        XCTAssertNil(legacy.bypass)
    }

    func testRuleTemplateRenderAndBuildRules() {
        var template = RuleTemplate(data: ["BundleID": "com.example.app"])
        template.User = "tester"
        XCTAssertEqual(
            template.render(template: "${Home}/Library/${BundleID}/${User}/${Unknown}"),
            "${Home}/Library/com.example.app/tester/${Unknown}"
        )

        let built = PlayRules.buildRules(
            rules: [
                "(subpath \"${HomeDirectory}/Library/Containers/${BundleID}\")",
                "(literal \"/Users/${NSUserName}\")"
            ],
            bundleID: "io.playcover.UnitTest"
        )
        XCTAssertEqual(built.count, 2)
        let expectedHome = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(built[0], "(subpath \"\(expectedHome)/Library/Containers/io.playcover.UnitTest\")")
        XCTAssertEqual(built[1], "(literal \"/Users/\(NSUserName())\")")
    }

    func testRuleTemplateSinglePassDeterministicRenderAndDateDynamicMember() {
        let t1 = RuleTemplate(data: ["A": "${B}", "B": "expanded"])
        let t2 = RuleTemplate(data: ["B": "expanded", "A": "${B}"])
        XCTAssertEqual(t1.render(template: "${A}"), "${B}")
        XCTAssertEqual(t2.render(template: "${A}"), "${B}")
        XCTAssertEqual(t1.render(template: "${A}-${B}-${Missing}"), "${B}-expanded-${Missing}")
        XCTAssertEqual(t1.render(template: "${unclosed"), "${unclosed")
        XCTAssertEqual(t1.render(template: "${outer ${B}}"), "${outer expanded}")

        var dateTemplate = RuleTemplate()
        let fallbackDate: Date = dateTemplate.missingDate
        XCTAssertEqual(fallbackDate, Date(timeIntervalSince1970: 0))

        let sampleDate = Date(timeIntervalSince1970: 1_700_000_000)
        dateTemplate.created = sampleDate
        let roundTripped: Date = dateTemplate.created
        XCTAssertEqual(roundTripped.timeIntervalSince1970, sampleDate.timeIntervalSince1970, accuracy: 1.0)
    }

    func testPlayRulesPrecedenceNullFallbackAndInvalidType() throws {
        let mixedJSON = """
        {
          "blocklist": ["/modern/block"],
          "blacklist": ["/legacy/block"],
          "greenlist": ["/modern/green"],
          "whitelist": ["/legacy/green"]
        }
        """
        let mixed = try JSONDecoder().decode(PlayRules.self, from: Data(mixedJSON.utf8))
        XCTAssertEqual(mixed.blocklist, ["/modern/block"])
        XCTAssertEqual(mixed.greenlist, ["/modern/green"])

        let nullFallbackJSON = """
        {
          "blocklist": null,
          "blacklist": ["/legacy/block"],
          "greenlist": null,
          "whitelist": ["/legacy/green"]
        }
        """
        let fallback = try JSONDecoder().decode(PlayRules.self, from: Data(nullFallbackJSON.utf8))
        XCTAssertEqual(fallback.blocklist, ["/legacy/block"])
        XCTAssertEqual(fallback.greenlist, ["/legacy/green"])

        let invalidTypeJSON = """
        {
          "blocklist": 123
        }
        """
        XCTAssertThrowsError(try JSONDecoder().decode(PlayRules.self, from: Data(invalidTypeJSON.utf8)))
    }
}
