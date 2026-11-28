import Foundation

public enum MCPJSONValue: Equatable, Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([MCPJSONValue])
    case object([String: MCPJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
        } else if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            self = .double(doubleVal)
        } else if let stringVal = try? container.decode(String.self) {
            self = .string(stringVal)
        } else if let arrayVal = try? container.decode([MCPJSONValue].self) {
            self = .array(arrayVal)
        } else if let objectVal = try? container.decode([String: MCPJSONValue].self) {
            self = .object(objectVal)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    public var boolValue: Bool? {
        guard case .bool(let val) = self else { return nil }
        return val
    }

    public var intValue: Int? {
        switch self {
        case .int(let val):
            return val
        case .double(let val):
            return Int(exactly: val)
        default:
            return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let val):
            return val
        case .int(let val):
            return Double(val)
        default:
            return nil
        }
    }

    public var stringValue: String? {
        guard case .string(let val) = self else { return nil }
        return val
    }

    public var arrayValue: [MCPJSONValue]? {
        guard case .array(let val) = self else { return nil }
        return val
    }

    public var objectValue: [String: MCPJSONValue]? {
        guard case .object(let val) = self else { return nil }
        return val
    }

    public subscript(key: String) -> MCPJSONValue? {
        objectValue?[key]
    }

    public static func fromFoundation(_ raw: Any) -> MCPJSONValue {
        switch raw {
        case is NSNull:
            return .null
        case let num as NSNumber:
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return .bool(num.boolValue)
            }
            let objCType = String(cString: num.objCType)
            if objCType == "f" || objCType == "d" {
                return .double(num.doubleValue)
            }
            return .int(num.intValue)
        case let str as String:
            return .string(str)
        case let arr as [Any]:
            return .array(arr.map { fromFoundation($0) })
        case let dict as [String: Any]:
            return .object(dict.mapValues { fromFoundation($0) })
        default:
            return .string(String(describing: raw))
        }
    }

    public func toFoundation() -> Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .string(let value):
            return value
        case .array(let value):
            return value.map { $0.toFoundation() }
        case .object(let value):
            return value.mapValues { $0.toFoundation() }
        }
    }
}

public extension Dictionary where Key == String, Value == MCPJSONValue {
    func string(_ key: String) -> String? {
        self[key]?.stringValue
    }

    func bool(_ key: String) -> Bool? {
        self[key]?.boolValue
    }

    func int(_ key: String) -> Int? {
        self[key]?.intValue
    }

    func double(_ key: String) -> Double? {
        self[key]?.doubleValue
    }

    func stringArray(_ key: String) -> [String]? {
        self[key]?.arrayValue?.compactMap(\.stringValue)
    }
}
