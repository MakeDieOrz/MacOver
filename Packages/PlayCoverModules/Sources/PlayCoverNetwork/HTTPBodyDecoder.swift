import Compression
import Foundation

public struct DecodedHTTPBody: Equatable, Sendable {
    public let data: Data
    public let appliedEncodings: [String]
    public let outputTruncated: Bool
    public let decodingFailed: Bool

    public init(
        data: Data,
        appliedEncodings: [String] = [],
        outputTruncated: Bool = false,
        decodingFailed: Bool = false
    ) {
        self.data = data
        self.appliedEncodings = appliedEncodings
        self.outputTruncated = outputTruncated
        self.decodingFailed = decodingFailed
    }
}

public struct FormattedHTTPBody: Equatable, Sendable {
    public let text: String
    public let isHex: Bool
    public let decoded: DecodedHTTPBody

    public init(text: String, isHex: Bool, decoded: DecodedHTTPBody) {
        self.text = text
        self.isHex = isHex
        self.decoded = decoded
    }
}

public enum HTTPBodyDecoder {
    public static let defaultMaxDecodedBytes = 4 * 1024 * 1024

    public static func headerValue(named lowerName: String, in headers: [String: String]) -> String? {
        for (key, value) in headers where key.lowercased() == lowerName {
            return value
        }
        return nil
    }

    public static func decode(
        _ rawData: Data,
        headers: [String: String],
        maxOutputBytes: Int = defaultMaxDecodedBytes
    ) -> DecodedHTTPBody {
        guard !rawData.isEmpty else {
            return DecodedHTTPBody(data: rawData)
        }
        let budget = max(1024, maxOutputBytes)
        let rawEncoding = headerValue(named: "content-encoding", in: headers) ?? ""
        let encodings = rawEncoding
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0 != "identity" }

        if encodings.isEmpty {
            if hasGzipMagic(rawData),
               let result = decompressGzip(rawData, maxOutputBytes: budget) {
                return DecodedHTTPBody(
                    data: result.data,
                    appliedEncodings: ["gzip"],
                    outputTruncated: result.truncated,
                    decodingFailed: false
                )
            }
            return DecodedHTTPBody(data: rawData)
        }

        var current = rawData
        var applied: [String] = []
        var anyTruncated = false

        for encoding in encodings.reversed() {
            let decompressed: (data: Data, truncated: Bool)?
            switch encoding {
            case "gzip", "x-gzip":
                decompressed = decompressGzip(current, maxOutputBytes: budget)
            case "deflate":
                decompressed = decompressDeflate(current, maxOutputBytes: budget)
            case "br":
                if let streamOut = decompressStream(
                    current,
                    algorithm: COMPRESSION_BROTLI,
                    maxOutputBytes: budget
                ), streamOut.ended || !streamOut.data.isEmpty {
                    decompressed = (streamOut.data, streamOut.truncated)
                } else {
                    decompressed = nil
                }
            default:
                decompressed = nil
            }

            guard let output = decompressed else {
                return DecodedHTTPBody(
                    data: current,
                    appliedEncodings: applied,
                    outputTruncated: anyTruncated,
                    decodingFailed: true
                )
            }
            current = output.data
            applied.append(encoding)
            if output.truncated {
                anyTruncated = true
                break
            }
        }

        return DecodedHTTPBody(
            data: current,
            appliedEncodings: applied,
            outputTruncated: anyTruncated,
            decodingFailed: false
        )
    }

    public static func decodeText(_ data: Data, contentType: String?) -> String? {
        guard !data.isEmpty else { return "" }
        var candidate: String?
        if let charset = parseCharset(from: contentType) {
            let cfEnc = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cfEnc != kCFStringEncodingInvalidId {
                let nsEnc = CFStringConvertEncodingToNSStringEncoding(cfEnc)
                candidate = String(data: data, encoding: String.Encoding(rawValue: nsEnc))
            }
        }
        if candidate == nil {
            candidate = String(data: data, encoding: .utf8)
        }
        guard let text = candidate else { return nil }
        return looksLikeReadableText(text, contentType: contentType) ? text : nil
    }

    public static func formatDisplayText(
        _ rawData: Data,
        headers: [String: String],
        maxOutputBytes: Int = defaultMaxDecodedBytes
    ) -> FormattedHTTPBody {
        let decoded = decode(rawData, headers: headers, maxOutputBytes: maxOutputBytes)
        if !decoded.data.isEmpty,
           let jsonObj = try? JSONSerialization.jsonObject(with: decoded.data),
           let pretty = try? JSONSerialization.data(
               withJSONObject: jsonObj,
               options: [.prettyPrinted, .sortedKeys]
           ),
           let jsonStr = String(data: pretty, encoding: .utf8) {
            return FormattedHTTPBody(text: jsonStr, isHex: false, decoded: decoded)
        }
        let contentType = headerValue(named: "content-type", in: headers)
        if let text = decodeText(decoded.data, contentType: contentType) {
            return FormattedHTTPBody(text: text, isHex: false, decoded: decoded)
        }
        return FormattedHTTPBody(
            text: hexString(for: decoded.data),
            isHex: true,
            decoded: decoded
        )
    }

    public static func hexString(for data: Data, maxBytes: Int = 4096) -> String {
        data.prefix(maxBytes).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func hasGzipMagic(_ data: Data) -> Bool {
        data.count >= 10 &&
            data[data.startIndex] == 0x1F &&
            data[data.startIndex + 1] == 0x8B &&
            data[data.startIndex + 2] == 0x08
    }

    private static func gzipHeaderPayloadOffset(in bytes: Data, startingAt start: Int) -> Int? {
        guard start + 10 <= bytes.count else { return nil }
        guard bytes[start] == 0x1F, bytes[start + 1] == 0x8B, bytes[start + 2] == 0x08 else {
            return nil
        }
        let flg = bytes[start + 3]
        var pos = start + 10
        if (flg & 0x04) != 0 {
            guard pos + 2 <= bytes.count else { return nil }
            let extraLen = Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8)
            pos += 2 + extraLen
            guard pos <= bytes.count else { return nil }
        }
        if (flg & 0x08) != 0 {
            guard let nulIdx = bytes[pos...].firstIndex(of: 0) else { return nil }
            pos = nulIdx + 1
        }
        if (flg & 0x10) != 0 {
            guard let nulIdx = bytes[pos...].firstIndex(of: 0) else { return nil }
            pos = nulIdx + 1
        }
        if (flg & 0x02) != 0 {
            guard pos + 2 <= bytes.count else { return nil }
            pos += 2
        }
        return pos <= bytes.count ? pos : nil
    }

    private static func decompressGzip(
        _ input: Data,
        maxOutputBytes: Int
    ) -> (data: Data, truncated: Bool)? {
        let bytes = Data(input)
        var offset = 0
        var output = Data()
        var anyMemberEnded = false
        var truncated = false

        while offset + 10 <= bytes.count {
            guard let payloadOffset = gzipHeaderPayloadOffset(in: bytes, startingAt: offset) else {
                if output.isEmpty && !anyMemberEnded {
                    return nil
                }
                break
            }
            let remainingBudget = maxOutputBytes - output.count
            if remainingBudget <= 0 {
                truncated = true
                break
            }
            let compressedSlice = Data(bytes[payloadOffset...])
            guard let member = decompressStream(
                compressedSlice,
                algorithm: COMPRESSION_ZLIB,
                maxOutputBytes: remainingBudget
            ) else {
                if output.isEmpty && !anyMemberEnded {
                    return nil
                }
                truncated = true
                break
            }
            output.append(member.data)
            if member.ended {
                anyMemberEnded = true
            }
            if member.truncated {
                truncated = true
                break
            }
            if !member.ended {
                truncated = true
                break
            }
            let nextOffset = payloadOffset + member.consumed + 8
            if nextOffset >= bytes.count {
                break
            }
            offset = nextOffset
        }

        if output.isEmpty && !anyMemberEnded {
            return nil
        }
        return (output, truncated)
    }

    private static func decompressDeflate(
        _ input: Data,
        maxOutputBytes: Int
    ) -> (data: Data, truncated: Bool)? {
        let bytes = Data(input)
        if bytes.count >= 2 {
            let cmf = bytes[0]
            let flg = bytes[1]
            let validMethod = (cmf & 0x0F) == 8 && (cmf >> 4) <= 7
            let validCheck = ((UInt16(cmf) << 8) | UInt16(flg)) % 31 == 0
            if validMethod && validCheck {
                let payloadOffset = ((flg & 0x20) != 0) ? 6 : 2
                if payloadOffset < bytes.count,
                   let zlibOut = decompressStream(
                       Data(bytes[payloadOffset...]),
                       algorithm: COMPRESSION_ZLIB,
                       maxOutputBytes: maxOutputBytes
                   ),
                   zlibOut.ended || !zlibOut.data.isEmpty {
                    return (zlibOut.data, zlibOut.truncated)
                }
            }
        }
        guard let rawOut = decompressStream(
            bytes,
            algorithm: COMPRESSION_ZLIB,
            maxOutputBytes: maxOutputBytes
        ), rawOut.ended || !rawOut.data.isEmpty else {
            return nil
        }
        return (rawOut.data, rawOut.truncated)
    }

    private static func decompressStream(
        _ input: Data,
        algorithm: compression_algorithm,
        maxOutputBytes: Int
    ) -> (data: Data, consumed: Int, ended: Bool, truncated: Bool)? {
        guard !input.isEmpty else { return nil }
        return input.withUnsafeBytes { rawBuf -> (Data, Int, Bool, Bool)? in
            guard let baseAddr = rawBuf.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }
            let scratchSize = 65_536
            let dstBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: scratchSize)
            defer { dstBuf.deallocate() }

            var stream = compression_stream(
                dst_ptr: dstBuf,
                dst_size: scratchSize,
                src_ptr: baseAddr,
                src_size: rawBuf.count,
                state: nil
            )
            let initStatus = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm)
            guard initStatus == COMPRESSION_STATUS_OK else {
                return nil
            }
            defer { compression_stream_destroy(&stream) }

            stream.src_ptr = baseAddr
            stream.src_size = rawBuf.count

            var output = Data()
            var ended = false
            var truncated = false
            let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)

            while true {
                stream.dst_ptr = dstBuf
                stream.dst_size = scratchSize
                let status = compression_stream_process(&stream, flags)
                let produced = scratchSize - stream.dst_size
                if produced > 0 {
                    let remaining = maxOutputBytes - output.count
                    if produced >= remaining {
                        if remaining > 0 {
                            output.append(dstBuf, count: remaining)
                        }
                        if status != COMPRESSION_STATUS_END || produced > remaining {
                            truncated = true
                        } else {
                            ended = true
                        }
                        break
                    }
                    output.append(dstBuf, count: produced)
                }

                if status == COMPRESSION_STATUS_END {
                    ended = true
                    break
                } else if status == COMPRESSION_STATUS_ERROR {
                    if output.isEmpty {
                        return nil
                    }
                    truncated = true
                    break
                } else if produced == 0 && stream.src_size == 0 {
                    if !output.isEmpty {
                        truncated = true
                    }
                    break
                }
            }

            let consumed = rawBuf.count - stream.src_size
            return (output, consumed, ended, truncated)
        }
    }

    private static func parseCharset(from contentType: String?) -> String? {
        guard let contentType else { return nil }
        for param in contentType.split(separator: ";").dropFirst() {
            let trimmed = param.trimmingCharacters(in: .whitespacesAndNewlines)
            if let eq = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                if key == "charset" {
                    var val = trimmed[trimmed.index(after: eq)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
                        val = String(val.dropFirst().dropLast())
                    }
                    return val.isEmpty ? nil : val
                }
            }
        }
        return nil
    }

    private static func looksLikeReadableText(_ text: String, contentType: String?) -> Bool {
        if text.unicodeScalars.contains("\0") {
            return false
        }
        let lowerCT = contentType?.lowercased() ?? ""
        let explicitlyText = lowerCT.contains("text/") ||
            lowerCT.contains("json") ||
            lowerCT.contains("xml") ||
            lowerCT.contains("javascript") ||
            lowerCT.contains("x-www-form-urlencoded") ||
            lowerCT.contains("graphql")
        if explicitlyText {
            return true
        }
        var total = 0
        var controlCount = 0
        for scalar in text.unicodeScalars.prefix(4096) {
            total += 1
            let v = scalar.value
            if (v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D) || v == 0x7F {
                controlCount += 1
            }
        }
        guard total > 0 else { return true }
        return controlCount * 100 <= total * 15
    }
}
