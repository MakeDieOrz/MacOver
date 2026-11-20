import AppKit
import Foundation
import XCTest
@testable import PlayCover

final class AppSettingsDataTests: XCTestCase {
    func testDefaultValuesAndCodableRoundTrip() throws {
        var original = AppSettingsData()
        XCTAssertEqual(original.bundleIdentifier, "")
        XCTAssertEqual(original.sensitivity, 50)
        XCTAssertEqual(original.windowWidth, 1920)
        XCTAssertEqual(original.windowHeight, 1080)
        XCTAssertEqual(original.customScaler, 2.0)
        XCTAssertEqual(original.iosDeviceModel, "iPad13,8")
        XCTAssertEqual(original.notch, NSScreen.hasNotch())
        XCTAssertTrue(original.playChain)
        XCTAssertTrue(original.networkBlockMock200)
        XCTAssertFalse(original.enableNetworkRules)

        original.bundleIdentifier = "com.example.game"
        original.sensitivity = 72.5
        original.customScaler = 1.5
        original.enableNetworkRules = true
        original.blockedURLPatterns = ["ads.example.com", "@@cdn.example.com"]
        original.discordActivity = DiscordActivity()
        original.discordActivity.enable = true
        original.discordActivity.applicationID = "123456"
        original.discordActivity.details = "Playing"

        let plistEncoder = PropertyListEncoder()
        plistEncoder.outputFormat = .xml
        let plistData = try plistEncoder.encode(original)
        let decodedPlist = try PropertyListDecoder().decode(AppSettingsData.self, from: plistData)
        XCTAssertEqual(decodedPlist, original)

        let jsonData = try JSONEncoder().encode(original)
        let decodedJSON = try JSONDecoder().decode(AppSettingsData.self, from: jsonData)
        XCTAssertEqual(decodedJSON, original)
    }

    func testTolerantDecodingForLegacyAndMixedNumericTypes() throws {
        let json = """
        {
          "bundleIdentifier": "com.legacy.app",
          "sensitivity": 65,
          "customScaler": 3,
          "keymappingDisabledAt": 12.5,
          "playChain": false
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(AppSettingsData.self, from: data)
        XCTAssertEqual(decoded.bundleIdentifier, "com.legacy.app")
        XCTAssertEqual(decoded.sensitivity, 65.0)
        XCTAssertEqual(decoded.customScaler, 3.0)
        XCTAssertEqual(decoded.keymappingDisabledAt, 12.5)
        XCTAssertFalse(decoded.playChain)
        XCTAssertEqual(decoded.notch, NSScreen.hasNotch())
        XCTAssertTrue(decoded.networkBlockMock200)
        XCTAssertEqual(decoded.blockedURLPatterns, [])

        let emptyDecoded = try JSONDecoder().decode(AppSettingsData.self, from: Data("{}".utf8))
        XCTAssertEqual(emptyDecoded, AppSettingsData())
    }

    func testDiscordActivityDefaultsAndPartialDecoding() throws {
        let defaults = DiscordActivity()
        XCTAssertFalse(defaults.enable)
        XCTAssertEqual(defaults.applicationID, "")
        XCTAssertEqual(defaults.details, "")
        XCTAssertEqual(defaults.state, "")
        XCTAssertEqual(defaults.image, "")

        let partial = try JSONDecoder().decode(
            DiscordActivity.self,
            from: Data(#"{"enable":true,"details":"Boss Fight"}"#.utf8)
        )
        XCTAssertTrue(partial.enable)
        XCTAssertEqual(partial.applicationID, "")
        XCTAssertEqual(partial.details, "Boss Fight")
        XCTAssertEqual(partial.state, "")
        XCTAssertEqual(partial.image, "")
    }

    func testMalformedFieldsFallbackAndExtremeNumericBounds() throws {
        let malformedJSON = """
        {
          "bundleIdentifier": 999,
          "sensitivity": "bad",
          "customScaler": "bad",
          "discordActivity": 123,
          "blockedURLPatterns": [123, "ok"],
          "windowWidth": "wide",
          "windowHeight": -100,
          "keymappingDisabledAt": 999999.5,
          "version": "99.0.0-future"
        }
        """
        let decoded = try JSONDecoder().decode(AppSettingsData.self, from: Data(malformedJSON.utf8))
        XCTAssertEqual(decoded.bundleIdentifier, "")
        XCTAssertEqual(decoded.sensitivity, 50)
        XCTAssertEqual(decoded.customScaler, 2.0)
        XCTAssertEqual(decoded.discordActivity, DiscordActivity())
        XCTAssertEqual(decoded.blockedURLPatterns, [])
        XCTAssertEqual(decoded.windowWidth, 1920)
        XCTAssertEqual(decoded.windowHeight, -100)
        XCTAssertEqual(decoded.keymappingDisabledAt, 999999.5)
        XCTAssertEqual(decoded.version, "99.0.0-future")
    }
}
