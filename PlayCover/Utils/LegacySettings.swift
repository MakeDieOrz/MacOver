//
//  LegacySettings.swift
//  PlayCover
//
//  Created by Isaac Marovitz on 07/09/2022.
//

import Foundation

nonisolated class LegacySettings {
    public static let monolithURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Preferences")
        .appendingPathComponent("playcover")
        .appendingPathExtension("plist")
    public static var doesMonolithExist: Bool {
        return FileManager.default.fileExists(atPath: monolithURL.path)
    }

    static func convertLegacyMonolithPlist(_ from: URL) {
        var dictionary: [String: Any]

        do {
            if let monolith = try [String: Any].read(from) {
                if !monolith.isEmpty {
                    dictionary = monolith

                    for (key, value) in dictionary {
                        if let dict = value as? [String: Any] {
                            if let settings = convertLegacySettingsDict(dict) {
                                let settingsURL = AppSettings.appSettingsDir.appendingPathComponent(key)
                                                                            .appendingPathExtension("plist")
                                do {
                                    let data = try PropertyListEncoder().encode(settings)
                                    try data.write(to: settingsURL)
                                } catch {
                                    print(error)
                                }
                            }

                            if let legacyKeymaps = dict["pc.layout"] as? [Any] {
                                let keymap = convertLegacyKeymapArray(legacyKeymaps, key)
                                let keymapURL = Keymapping.keymappingDir.appendingPathComponent(key)
                                                                        .appendingPathExtension("plist")
                                do {
                                    let data = try PropertyListEncoder().encode(keymap)
                                    try data.write(to: keymapURL)
                                } catch {
                                    print(error)
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            PlayCoverDiagnostics.reportError("Failed to read playcover.plist")
        }
    }

    private static func isBoolean(_ value: Any?) -> Bool {
        if value is Bool {
            return true
        }
        if let num = value as? NSNumber {
            return CFGetTypeID(num) == CFBooleanGetTypeID()
        }
        return false
    }

    private static func floatValue(_ value: Any?, default defaultValue: Float) -> Float {
        guard !isBoolean(value) else { return defaultValue }
        switch value {
        case let val as Float:
            return val
        case let val as Double:
            return Float(val)
        case let val as CGFloat:
            return Float(val)
        case let val as Int:
            return Float(val)
        case let val as NSNumber:
            return val.floatValue
        default:
            return defaultValue
        }
    }

    private static func cgFloatValue(_ value: Any?, default defaultValue: CGFloat) -> CGFloat {
        guard !isBoolean(value) else { return defaultValue }
        switch value {
        case let val as CGFloat:
            return val
        case let val as Double:
            return CGFloat(val)
        case let val as Float:
            return CGFloat(val)
        case let val as Int:
            return CGFloat(val)
        case let val as NSNumber:
            return CGFloat(val.doubleValue)
        default:
            return defaultValue
        }
    }

    private static func intValue(_ value: Any?, default defaultValue: Int) -> Int {
        guard !isBoolean(value) else { return defaultValue }
        switch value {
        case let val as Int:
            return val
        case let val as NSNumber:
            return val.intValue
        default:
            return defaultValue
        }
    }

    static func convertLegacySettingsDict(_ from: [String: Any]) -> AppSettingsData? {
        var dictionary: [String: Any]

        if !from.isEmpty {
            dictionary = from

            var settingsData = AppSettingsData()
            settingsData.keymapping = dictionary["pc.keymapping"] as? Bool ?? true
            settingsData.sensitivity = floatValue(dictionary["pc.sensivity"], default: 50)
            settingsData.disableTimeout = dictionary["pc.disableTimeout"] as? Bool ?? false

            return settingsData
        } else {
            return nil
        }
    }

    static func convertLegacyKeymapArray(_ from: [Any], _ bundleID: String) -> Keymap? {
        var keymap = Keymap(bundleIdentifier: bundleID)

        for item in from {
            if let data = item as? [Any] {
                if data.count == 4 {
                    let size = cgFloatValue(data[3], default: 5)
                    let xCoord = cgFloatValue(data[1], default: 0)
                    let yCoord = cgFloatValue(data[2], default: 0)

                    let transform = KeyModelTransform(size: size, xCoord: xCoord, yCoord: yCoord)

                    let keyCode = intValue(data[0], default: 0)
                    keymap.buttonModels.append(ButtonModel(keyCode: keyCode,
                                                           keyName: KeyCodeNames.keyCodes[keyCode] ?? "Btn",
                                                           transform: transform))
                } else if data.count == 2 {
                    let xCoord = cgFloatValue(data[0], default: 0)
                    let yCoord = cgFloatValue(data[1], default: 0)

                    let transform = KeyModelTransform(size: 25, xCoord: xCoord, yCoord: yCoord)

                    keymap.mouseAreaModel.append(MouseAreaModel(keyName: "Mouse", transform: transform))
                } else if data.count == 8 {
                    let size = cgFloatValue(data[6], default: 5)
                    let xCoord = cgFloatValue(data[4], default: 0)
                    let yCoord = cgFloatValue(data[5], default: 0)

                    let transform = KeyModelTransform(size: size, xCoord: xCoord, yCoord: yCoord)

                    let upKeyCode = intValue(data[0], default: 0)
                    let leftKeyCode = intValue(data[2], default: 0)
                    let rightKeyCode = intValue(data[3], default: 0)
                    let downKeyCode = intValue(data[1], default: 0)
                    keymap.joystickModel.append(JoystickModel(upKeyCode: upKeyCode,
                                                              rightKeyCode: rightKeyCode,
                                                              downKeyCode: downKeyCode,
                                                              leftKeyCode: leftKeyCode,
                                                              keyName: "Keyboard",
                                                              transform: transform,
                                                              mode: .FIXED))
                } else if data.count == 5 {
                    let size = cgFloatValue(data[3], default: 5)
                    let xCoord = cgFloatValue(data[1], default: 0)
                    let yCoord = cgFloatValue(data[2], default: 0)

                    let transform = KeyModelTransform(size: size, xCoord: xCoord, yCoord: yCoord)

                    let keyCode = intValue(data[0], default: 0)
                    keymap.draggableButtonModels.append(ButtonModel(keyCode: keyCode,
                                                                    keyName: "Mouse",
                                                                    transform: transform))
                }
            }
        }

        return keymap
    }

    static func convertLegacyKeymapFile(_ from: URL) -> Keymap? {
        var dictionary: [String: Any]

        do {
            if let settings = try [String: Any].read(from) {
                if !settings.isEmpty {
                    dictionary = settings
                    if let legacyKeymaps = dictionary["pc.layout"] as? [Any] {
                        return convertLegacyKeymapArray(legacyKeymaps, from.deletingPathExtension().lastPathComponent)
                    } else {
                        PlayCoverDiagnostics.reportError("Could not find keymapping in legacy file!")
                    }
                }
            }
        } catch {
            return nil
        }

        return nil
    }
}
