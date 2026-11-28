import Darwin
import Foundation

public struct MCPRequestID: Equatable, Hashable, Sendable, Codable {
    public let rawValue: MCPJSONValue

    public init(_ rawValue: MCPJSONValue) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        self.rawValue = try MCPJSONValue(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try rawValue.encode(to: encoder)
    }
}

public struct MCPRPCRequest: Equatable, Sendable, Codable {
    public let jsonrpc: String
    public let id: MCPRequestID?
    public let method: String
    public let params: MCPJSONValue?

    public init(
        jsonrpc: String = "2.0",
        id: MCPRequestID? = nil,
        method: String,
        params: MCPJSONValue? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct MCPRPCError: Equatable, Sendable, Codable, Error {
    public let code: Int
    public let message: String
    public let data: MCPJSONValue?

    public init(code: Int, message: String, data: MCPJSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static func parseError(_ msg: String) -> MCPRPCError {
        MCPRPCError(code: -32_700, message: msg)
    }

    public static func invalidRequest(_ msg: String) -> MCPRPCError {
        MCPRPCError(code: -32_600, message: msg)
    }

    public static func methodNotFound(_ method: String) -> MCPRPCError {
        MCPRPCError(code: -32_601, message: "Method not found: \(method)")
    }

    public static func invalidParams(_ msg: String) -> MCPRPCError {
        MCPRPCError(code: -32_602, message: msg)
    }

    public static func internalError(_ msg: String) -> MCPRPCError {
        MCPRPCError(code: -32_603, message: msg)
    }
}

public struct MCPRPCResponse: Equatable, Sendable, Codable {
    public let jsonrpc: String
    public let id: MCPRequestID?
    public let result: MCPJSONValue?
    public let error: MCPRPCError?

    public init(
        jsonrpc: String = "2.0",
        id: MCPRequestID?,
        result: MCPJSONValue? = nil,
        error: MCPRPCError? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = result
        self.error = error
    }
}

public enum MCPContentBlock: Equatable, Sendable, Codable {
    case text(String)
    case image(data: String, mimeType: String)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case data
        case mimeType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "image":
            self = .image(
                data: try container.decode(String.self, forKey: .data),
                mimeType: try container.decode(String.self, forKey: .mimeType)
            )
        default:
            self = .text(try container.decodeIfPresent(String.self, forKey: .text) ?? "")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        case .image(let data, let mimeType):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        }
    }
}

public struct MCPToolCallResult: Equatable, Sendable, Codable {
    public let content: [MCPContentBlock]
    public let isError: Bool?

    public init(content: [MCPContentBlock], isError: Bool? = nil) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ value: String, isError: Bool = false) -> MCPToolCallResult {
        MCPToolCallResult(content: [.text(value)], isError: isError ? true : nil)
    }

    public static func json(_ value: MCPJSONValue, isError: Bool = false) -> MCPToolCallResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let raw = (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return .text(raw, isError: isError)
    }
}

public enum MCPFramingMode: Equatable, Sendable {
    case ndjson
    case contentLength
}

public enum MCPStdioFramer {
    public static let maxContentLengthBytes = 32 * 1024 * 1024
    public static let maxHeaderBytes = 16 * 1024
    public static let maxBufferBytes = maxContentLengthBytes + maxHeaderBytes

    public static func readNextFrame(
        from handle: FileHandle,
        buffer: inout Data
    ) throws -> (payload: Data, mode: MCPFramingMode)? {
        var mode: MCPFramingMode = .ndjson
        return try readNextFrame(from: handle, buffer: &buffer, activeMode: &mode)
    }

    public static func readNextFrame(
        from handle: FileHandle,
        buffer: inout Data,
        activeMode: inout MCPFramingMode
    ) throws -> (payload: Data, mode: MCPFramingMode)? {
        while true {
            trimLeadingNewlines(&buffer)
            if let parsed = try extractFrame(from: &buffer, activeMode: &activeMode) {
                activeMode = parsed.1
                return parsed
            }
            if buffer.count > maxBufferBytes {
                buffer.removeAll(keepingCapacity: false)
                throw MCPRPCError.parseError("Frame buffer exceeded maximum size (\(maxBufferBytes) bytes)")
            }
            let chunk = try readAvailableChunk(from: handle, maxBytes: 64 * 1024)
            if chunk.isEmpty {
                if !buffer.isEmpty {
                    let remaining = buffer
                    buffer.removeAll(keepingCapacity: false)
                    if let tail = String(data: remaining, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !tail.isEmpty {
                        activeMode = .ndjson
                        return (Data(tail.utf8), .ndjson)
                    }
                    throw MCPRPCError.parseError("Trailing invalid UTF-8 frame data at EOF")
                }
                return nil
            }
            if buffer.count + chunk.count > maxBufferBytes {
                buffer.removeAll(keepingCapacity: false)
                throw MCPRPCError.parseError("Frame buffer exceeded maximum size (\(maxBufferBytes) bytes)")
            }
            buffer.append(chunk)
        }
    }

    public static func encodeFrame(_ payload: Data, mode: MCPFramingMode) -> Data {
        switch mode {
        case .ndjson:
            var out = payload
            out.append(0x0A)
            return out
        case .contentLength:
            let header = "Content-Length: \(payload.count)\r\n\r\n"
            var out = Data(header.utf8)
            out.append(payload)
            return out
        }
    }

    private static func readAvailableChunk(from handle: FileHandle, maxBytes: Int) throws -> Data {
        let capacity = max(1, maxBytes)
        var raw = [UInt8](repeating: 0, count: capacity)
        let fd = handle.fileDescriptor
        while true {
            let n = raw.withUnsafeMutableBytes { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                return Darwin.read(fd, base, capacity)
            }
            if n > 0 {
                return Data(raw[0..<n])
            }
            if n == 0 {
                return Data()
            }
            let err = errno
            if err == EINTR {
                continue
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
    }

    private static func trimLeadingNewlines(_ buffer: inout Data) {
        while let first = buffer.first, first == 0x0A || first == 0x0D {
            buffer.removeFirst()
        }
    }

    private static func extractFrame(
        from buffer: inout Data,
        activeMode: inout MCPFramingMode
    ) throws -> (Data, MCPFramingMode)? {
        guard !buffer.isEmpty else { return nil }
        if buffer.first == 0x7B || buffer.first == 0x5B {
            guard let nlIndex = buffer.firstIndex(of: 0x0A) else {
                if buffer.count > maxContentLengthBytes {
                    buffer.removeAll(keepingCapacity: false)
                    throw MCPRPCError.parseError("NDJSON frame exceeds maximum size")
                }
                return nil
            }
            let line = Data(buffer[buffer.startIndex..<nlIndex])
            buffer.removeSubrange(buffer.startIndex...nlIndex)
            return (line, .ndjson)
        }

        let separatorCRLF = Data("\r\n\r\n".utf8)
        let separatorLF = Data("\n\n".utf8)
        let headerRange: Range<Data.Index>
        if let crlfRange = buffer.range(of: separatorCRLF) {
            headerRange = crlfRange
        } else if let lfRange = buffer.range(of: separatorLF) {
            headerRange = lfRange
        } else if let nlIndex = buffer.firstIndex(of: 0x0A) {
            let lineSlice = buffer[buffer.startIndex..<nlIndex]
            let lineStr = String(data: lineSlice, encoding: .utf8)
            if let lineStr,
               lineStr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("content-length:") {
                activeMode = .contentLength
                if buffer.count > maxHeaderBytes {
                    buffer.removeAll(keepingCapacity: false)
                    throw MCPRPCError.parseError("Frame header exceeded maximum size")
                }
                return nil
            }
            let line = Data(lineSlice)
            buffer.removeSubrange(buffer.startIndex...nlIndex)
            if lineStr == nil {
                throw MCPRPCError.parseError("Invalid UTF-8 line frame")
            }
            return (line, .ndjson)
        } else {
            if buffer.count > maxHeaderBytes {
                buffer.removeAll(keepingCapacity: false)
                throw MCPRPCError.parseError("Unterminated frame header exceeded maximum size")
            }
            return nil
        }

        activeMode = .contentLength
        let headerData = Data(buffer[buffer.startIndex..<headerRange.lowerBound])
        if headerData.count > maxHeaderBytes {
            buffer.removeSubrange(buffer.startIndex..<headerRange.upperBound)
            throw MCPRPCError.parseError("Frame header exceeded maximum size")
        }
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            buffer.removeSubrange(buffer.startIndex..<headerRange.upperBound)
            throw MCPRPCError.parseError("Invalid UTF-8 frame header")
        }
        var contentLength: Int?
        for line in headerText.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        guard let length = contentLength, length >= 0, length <= maxContentLengthBytes else {
            buffer.removeSubrange(buffer.startIndex..<headerRange.upperBound)
            throw MCPRPCError.parseError("Missing or invalid Content-Length")
        }
        let bodyStart = headerRange.upperBound
        let availableBodyBytes = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard availableBodyBytes >= length else {
            return nil
        }
        let neededEnd = buffer.index(bodyStart, offsetBy: length)
        let payload = Data(buffer[bodyStart..<neededEnd])
        buffer.removeSubrange(buffer.startIndex..<neededEnd)
        return (payload, .contentLength)
    }
}

public enum MCPProtocol {
    public static let defaultProtocolVersion = "2025-03-26"
    public static let serverName = "macover-mcp"
    public static let serverVersion = "1.0.10"

    public static func makeInitializeResult(requestedVersion: String?) -> MCPJSONValue {
        let negotiated: String
        if let requestedVersion, !requestedVersion.isEmpty {
            negotiated = requestedVersion
        } else {
            negotiated = defaultProtocolVersion
        }
        return .object([
            "protocolVersion": .string(negotiated),
            "capabilities": .object([
                "tools": .object(["listChanged": .bool(false)])
            ]),
            "serverInfo": .object([
                "name": .string(serverName),
                "version": .string(serverVersion)
            ])
        ])
    }
}
