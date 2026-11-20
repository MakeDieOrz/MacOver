import Foundation
import XCTest
@testable import PlayCover

final class KeymapAndLegacySettingsTests: XCTestCase {
    func testKeymapAndKeymapConfigCodableRoundTrip() throws {
        let btn = ButtonModel(
            keyCode: 44,
            keyName: "",
            transform: KeyModelTransform(size: 8, xCoord: 25, yCoord: 75)
        )
        XCTAssertEqual(btn.keyName, "Spc")

        let fallbackBtn = ButtonModel(
            keyCode: 99999,
            keyName: "",
            transform: KeyModelTransform(size: 5, xCoord: 10, yCoord: 20)
        )
        XCTAssertEqual(fallbackBtn.keyName, "Btn")

        let keymap = Keymap(
            buttonModels: [btn],
            draggableButtonModels: [fallbackBtn],
            joystickModel: [
                JoystickModel(
                    upKeyCode: 26,
                    rightKeyCode: 7,
                    downKeyCode: 22,
                    leftKeyCode: 4,
                    keyName: "WASD",
                    transform: KeyModelTransform(size: 15, xCoord: 30, yCoord: 70),
                    mode: .FLOATING
                )
            ],
            mouseAreaModel: [
                MouseAreaModel(
                    keyName: "Look",
                    transform: KeyModelTransform(size: 25, xCoord: 50, yCoord: 50)
                )
            ],
            bundleIdentifier: "com.example.keymap",
            version: "2.0.0"
        )

        let encoded = try PropertyListEncoder().encode(keymap)
        let decoded = try PropertyListDecoder().decode(Keymap.self, from: encoded)
        XCTAssertEqual(decoded.bundleIdentifier, "com.example.keymap")
        XCTAssertEqual(decoded.buttonModels.count, 1)
        XCTAssertEqual(decoded.buttonModels.first?.keyName, "Spc")
        XCTAssertEqual(decoded.joystickModel.first?.mode, .FLOATING)
        XCTAssertEqual(decoded.mouseAreaModel.first?.keyName, "Look")

        let defaultURL = URL(fileURLWithPath: "/tmp/default.plist")
        let altURL = URL(fileURLWithPath: "/tmp/alt.plist")
        let config = KeymapConfig(defaultKm: defaultURL, keymapOrder: [defaultURL, altURL])
        let cfgData = try JSONEncoder().encode(config)
        let decodedCfg = try JSONDecoder().decode(KeymapConfig.self, from: cfgData)
        XCTAssertEqual(decodedCfg.defaultKm, defaultURL)
        XCTAssertEqual(decodedCfg.keymapOrder, [defaultURL, altURL])
    }

    func testFailableDecodableDropsMalformedItemsGracefully() throws {
        let json = """
        {
          "buttonModels": [
            {"keyCode": 4, "keyName": "A", "transform": {"size": 5, "xCoord": 10, "yCoord": 20}},
            {"notAKeyCode": "bad"}
          ],
          "bundleIdentifier": "com.test.failable"
        }
        """
        let decoded = try JSONDecoder().decode(Keymap.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.bundleIdentifier, "com.test.failable")
        XCTAssertEqual(decoded.buttonModels.count, 1)
        XCTAssertEqual(decoded.buttonModels.first?.keyCode, 4)

        let cfgJSON = """
        {
          "defaultKm": "file:///tmp/default.plist",
          "keymapOrder": ["file:///tmp/default.plist", 12345]
        }
        """
        let decodedCfg = try JSONDecoder().decode(KeymapConfig.self, from: Data(cfgJSON.utf8))
        XCTAssertEqual(decodedCfg.keymapOrder, [URL(fileURLWithPath: "/tmp/default.plist")])
    }

    func testLegacySettingsDictAndKeymapArrayConversion() {
        XCTAssertNil(LegacySettings.convertLegacySettingsDict([:]))

        let dict: [String: Any] = [
            "pc.keymapping": false,
            "pc.sensivity": Float(82.5),
            "pc.disableTimeout": true
        ]
        let converted = LegacySettings.convertLegacySettingsDict(dict)
        XCTAssertNotNil(converted)
        XCTAssertEqual(converted?.keymapping, false)
        XCTAssertEqual(converted?.sensitivity, 82.5)
        XCTAssertEqual(converted?.disableTimeout, true)

        let legacyLayout: [Any] = [
            [4, CGFloat(10), CGFloat(20), CGFloat(6)] as [Any],                  // 4-item button
            [CGFloat(50), CGFloat(55)] as [Any],                                 // 2-item mouse area
            [26, 22, 4, 7, CGFloat(30), CGFloat(70), CGFloat(14), 0] as [Any],   // 8-item joystick
            [41, CGFloat(80), CGFloat(90), CGFloat(5), 1] as [Any],              // 5-item draggable button
            ["ignored", 1, 2] as [Any]                                           // unknown length skipped
        ]
        let keymap = LegacySettings.convertLegacyKeymapArray(legacyLayout, "com.legacy.game")
        XCTAssertEqual(keymap?.bundleIdentifier, "com.legacy.game")
        XCTAssertEqual(keymap?.buttonModels.count, 1)
        XCTAssertEqual(keymap?.buttonModels.first?.keyName, "A")
        XCTAssertEqual(keymap?.mouseAreaModel.count, 1)
        XCTAssertEqual(keymap?.mouseAreaModel.first?.transform.size, 25)
        XCTAssertEqual(keymap?.joystickModel.count, 1)
        XCTAssertEqual(keymap?.joystickModel.first?.upKeyCode, 26)
        XCTAssertEqual(keymap?.joystickModel.first?.downKeyCode, 22)
        XCTAssertEqual(keymap?.joystickModel.first?.leftKeyCode, 4)
        XCTAssertEqual(keymap?.joystickModel.first?.rightKeyCode, 7)
        XCTAssertEqual(keymap?.draggableButtonModels.count, 1)
        XCTAssertEqual(keymap?.draggableButtonModels.first?.keyName, "Mouse")
    }

    func testLegacySettingsNumericCoercionForIntAndDouble() {
        let intDict: [String: Any] = ["pc.sensivity": 75]
        let fromInt = LegacySettings.convertLegacySettingsDict(intDict)
        XCTAssertEqual(fromInt?.sensitivity, 75.0)

        let doubleDict: [String: Any] = ["pc.sensivity": Double(82.5)]
        let fromDouble = LegacySettings.convertLegacySettingsDict(doubleDict)
        XCTAssertEqual(fromDouble?.sensitivity, 82.5)

        let boolTrapDict: [String: Any] = ["pc.sensivity": true]
        let fromBool = LegacySettings.convertLegacySettingsDict(boolTrapDict)
        XCTAssertEqual(fromBool?.sensitivity, 50.0)

        let intLayout: [Any] = [
            [4, 10, 20, 6] as [Any],
            [Double(50.5), 55] as [Any]
        ]
        let km = LegacySettings.convertLegacyKeymapArray(intLayout, "com.test.int")
        XCTAssertEqual(km?.buttonModels.first?.keyCode, 4)
        XCTAssertEqual(km?.buttonModels.first?.transform.xCoord, 10)
        XCTAssertEqual(km?.buttonModels.first?.transform.yCoord, 20)
        XCTAssertEqual(km?.buttonModels.first?.transform.size, 6)
        XCTAssertEqual(km?.mouseAreaModel.first?.transform.xCoord, 50.5)
        XCTAssertEqual(km?.mouseAreaModel.first?.transform.yCoord, 55)
    }

    func testConvertLegacyKeymapFileFromXMLPlistAndCorruptedPlist() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyKeymapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let validURL = dir.appendingPathComponent("com.example.legacy.plist")
        let xmlPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>pc.layout</key>
            <array>
                <array>
                    <integer>4</integer>
                    <real>12.5</real>
                    <real>25.0</real>
                    <integer>7</integer>
                </array>
            </array>
        </dict>
        </plist>
        """
        try Data(xmlPlist.utf8).write(to: validURL)
        let converted = try XCTUnwrap(LegacySettings.convertLegacyKeymapFile(validURL))
        XCTAssertEqual(converted.bundleIdentifier, "com.example.legacy")
        XCTAssertEqual(converted.buttonModels.count, 1)
        XCTAssertEqual(converted.buttonModels.first?.keyCode, 4)
        XCTAssertEqual(converted.buttonModels.first?.transform.xCoord, 12.5)
        XCTAssertEqual(converted.buttonModels.first?.transform.size, 7.0)

        let missingLayoutURL = dir.appendingPathComponent("nolayout.plist")
        try Data("<plist version=\"1.0\"><dict><key>other</key><true/></dict></plist>".utf8)
            .write(to: missingLayoutURL)
        XCTAssertNil(LegacySettings.convertLegacyKeymapFile(missingLayoutURL))

        let corruptURL = dir.appendingPathComponent("corrupt.plist")
        try Data("not a valid plist".utf8).write(to: corruptURL)
        XCTAssertNil(LegacySettings.convertLegacyKeymapFile(corruptURL))
    }

    func testKeymapFailableDecodableAllArraysAndInvalidTransformOrMode() throws {
        let json = """
        {
          "buttonModels": [
            {"keyCode": 4, "transform": {"size": "bad", "xCoord": "bad", "yCoord": 15}},
            {"bad": true}
          ],
          "draggableButtonModels": [
            {"keyCode": 41, "transform": {"size": 8, "xCoord": 10, "yCoord": 20}},
            "invalid"
          ],
          "joystickModel": [
            {
              "upKeyCode": 26,
              "rightKeyCode": 7,
              "downKeyCode": 22,
              "leftKeyCode": 4,
              "mode": 99
            },
            {"upKeyCode": "bad"}
          ],
          "mouseAreaModel": [
            {"keyName": "Look"},
            123
          ],
          "bundleIdentifier": "com.test.all"
        }
        """
        let decoded = try JSONDecoder().decode(Keymap.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.buttonModels.count, 1)
        XCTAssertEqual(decoded.buttonModels.first?.transform.size, 5)
        XCTAssertEqual(decoded.buttonModels.first?.transform.xCoord, 0)
        XCTAssertEqual(decoded.buttonModels.first?.transform.yCoord, 15)
        XCTAssertEqual(decoded.draggableButtonModels.count, 1)
        XCTAssertEqual(decoded.joystickModel.count, 1)
        XCTAssertEqual(decoded.joystickModel.first?.mode, .FIXED)
        XCTAssertEqual(decoded.mouseAreaModel.count, 1)
        XCTAssertEqual(decoded.mouseAreaModel.first?.transform.size, 25)
    }

    func testKeymapConfigMissingDefaultKmThrows() {
        let missingDefaultJSON = """
        {
          "keymapOrder": ["file:///tmp/default.plist"]
        }
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(KeymapConfig.self, from: Data(missingDefaultJSON.utf8))
        )
    }
}
