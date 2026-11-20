//
//  KeymapData.swift
//  PlayCover
//
//  Created by Isaac Marovitz on 23/08/2022.
//

import CoreGraphics
import Foundation

public struct KeyModelTransform: Codable {
    public var size: CGFloat
    public var xCoord: CGFloat
    public var yCoord: CGFloat

    public init(size: CGFloat, xCoord: CGFloat, yCoord: CGFloat) {
        self.size = size
        self.xCoord = xCoord
        self.yCoord = yCoord
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        size = Self.decodeCGFloat(from: container, forKey: .size, default: 5)
        xCoord = Self.decodeCGFloat(from: container, forKey: .xCoord, default: 0)
        yCoord = Self.decodeCGFloat(from: container, forKey: .yCoord, default: 0)
    }

    private static func decodeCGFloat<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K,
        default defaultValue: CGFloat
    ) -> CGFloat {
        if let value = try? container.decodeIfPresent(CGFloat.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return CGFloat(value)
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return CGFloat(value)
        }
        return defaultValue
    }
}

public struct ButtonModel: Codable {
    public var keyCode: Int
    public var keyName: String
    public var transform: KeyModelTransform

    public init(keyCode: Int, keyName: String, transform: KeyModelTransform) {
        self.keyCode = keyCode
        self.keyName = keyName.isEmpty ? KeyCodeNames.keyCodes[keyCode] ?? "Btn" : keyName
        self.transform = transform
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keyCode = try container.decode(Int.self, forKey: .keyCode)
        let keyName = (try? container.decodeIfPresent(String.self, forKey: .keyName)) ?? ""
        let transform = (try? container.decodeIfPresent(KeyModelTransform.self, forKey: .transform))
            ?? KeyModelTransform(size: 5, xCoord: 0, yCoord: 0)
        self.init(keyCode: keyCode, keyName: keyName, transform: transform)
    }
}

public enum JoystickMode: Int, Codable {
    case FIXED
    case FLOATING
}

public struct JoystickModel: Codable {
    public var upKeyCode: Int
    public var rightKeyCode: Int
    public var downKeyCode: Int
    public var leftKeyCode: Int
    public var keyName: String
    public var transform: KeyModelTransform
    public var mode: JoystickMode

    public init(upKeyCode: Int,
                rightKeyCode: Int,
                downKeyCode: Int,
                leftKeyCode: Int,
                keyName: String,
                transform: KeyModelTransform,
                mode: JoystickMode) {
        self.upKeyCode = upKeyCode
        self.rightKeyCode = rightKeyCode
        self.downKeyCode = downKeyCode
        self.leftKeyCode = leftKeyCode
        self.keyName = keyName
        self.transform = transform
        self.mode = mode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let upKeyCode = try container.decode(Int.self, forKey: .upKeyCode)
        let rightKeyCode = try container.decode(Int.self, forKey: .rightKeyCode)
        let downKeyCode = try container.decode(Int.self, forKey: .downKeyCode)
        let leftKeyCode = try container.decode(Int.self, forKey: .leftKeyCode)
        let keyName = (try? container.decodeIfPresent(String.self, forKey: .keyName)) ?? "Keyboard"
        let transform = (try? container.decodeIfPresent(KeyModelTransform.self, forKey: .transform))
            ?? KeyModelTransform(size: 5, xCoord: 0, yCoord: 0)
        let mode = (try? container.decodeIfPresent(JoystickMode.self, forKey: .mode)) ?? .FIXED
        self.init(upKeyCode: upKeyCode,
                  rightKeyCode: rightKeyCode,
                  downKeyCode: downKeyCode,
                  leftKeyCode: leftKeyCode,
                  keyName: keyName,
                  transform: transform,
                  mode: mode)
    }
}

public struct MouseAreaModel: Codable {
    public var keyName: String
    public var transform: KeyModelTransform

    public init(keyName: String, transform: KeyModelTransform) {
        self.keyName = keyName
        self.transform = transform
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keyName = (try? container.decodeIfPresent(String.self, forKey: .keyName)) ?? "Mouse"
        let transform = (try? container.decodeIfPresent(KeyModelTransform.self, forKey: .transform))
            ?? KeyModelTransform(size: 25, xCoord: 0, yCoord: 0)
        self.init(keyName: keyName, transform: transform)
    }
}

private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(T.self)
    }
}

public struct Keymap: Codable {
    public var buttonModels: [ButtonModel] = []
    public var draggableButtonModels: [ButtonModel] = []
    public var joystickModel: [JoystickModel] = []
    public var mouseAreaModel: [MouseAreaModel] = []
    public var bundleIdentifier: String = ""
    public var version = "2.0.0"

    public init(buttonModels: [ButtonModel] = [],
                draggableButtonModels: [ButtonModel] = [],
                joystickModel: [JoystickModel] = [],
                mouseAreaModel: [MouseAreaModel] = [],
                bundleIdentifier: String = "",
                version: String = "2.0.0") {
        self.buttonModels = buttonModels
        self.draggableButtonModels = draggableButtonModels
        self.joystickModel = joystickModel
        self.mouseAreaModel = mouseAreaModel
        self.bundleIdentifier = bundleIdentifier
        self.version = version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        buttonModels = (try? container.decodeIfPresent(
            [FailableDecodable<ButtonModel>].self, forKey: .buttonModels
        ))?.compactMap(\.value) ?? []
        draggableButtonModels = (try? container.decodeIfPresent(
            [FailableDecodable<ButtonModel>].self, forKey: .draggableButtonModels
        ))?.compactMap(\.value) ?? []
        joystickModel = (try? container.decodeIfPresent(
            [FailableDecodable<JoystickModel>].self, forKey: .joystickModel
        ))?.compactMap(\.value) ?? []
        mouseAreaModel = (try? container.decodeIfPresent(
            [FailableDecodable<MouseAreaModel>].self, forKey: .mouseAreaModel
        ))?.compactMap(\.value) ?? []
        bundleIdentifier = (try? container.decodeIfPresent(String.self, forKey: .bundleIdentifier)) ?? ""
        version = (try? container.decodeIfPresent(String.self, forKey: .version)) ?? "2.0.0"
    }
}

public struct KeymapConfig: Codable {
    public var defaultKm: URL
    public var keymapOrder: [URL]

    public init(defaultKm: URL, keymapOrder: [URL]) {
        self.defaultKm = defaultKm
        self.keymapOrder = keymapOrder
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let order = (try? container.decodeIfPresent(
            [FailableDecodable<URL>].self, forKey: .keymapOrder
        ))?.compactMap(\.value) ?? []
        self.init(defaultKm: try container.decode(URL.self, forKey: .defaultKm),
                  keymapOrder: order)
    }
}
