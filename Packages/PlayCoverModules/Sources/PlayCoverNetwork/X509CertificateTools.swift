import CryptoKit
import Darwin
import Foundation
import Network
import PlayCoverCore
import Security
import Synchronization

public enum X509Error: Error, LocalizedError, Sendable {
    case invalidCertificateData
    case invalidPrivateKeyData
    case oidEncodingFailed(String)
    case secIdentityCreationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCertificateData:
            return "Unable to parse X.509 certificate (expected PEM or DER format)."
        case .invalidPrivateKeyData:
            return "Unable to parse P-256 EC private key."
        case let .oidEncodingFailed(oid):
            return "Failed to encode OID: \(oid)"
        case let .secIdentityCreationFailed(reason):
            return "Failed to construct in-memory TLS identity: \(reason)"
        }
    }
}

private enum ASN1DER {
    static func tlv(tag: UInt8, payload: Data) -> Data {
        var out = Data([tag])
        let length = payload.count
        if length < 0x80 {
            out.append(UInt8(length))
        } else {
            var lenBytes: [UInt8] = []
            var rem = length
            while rem > 0 {
                lenBytes.insert(UInt8(rem & 0xFF), at: 0)
                rem >>= 8
            }
            out.append(0x80 | UInt8(lenBytes.count))
            out.append(contentsOf: lenBytes)
        }
        out.append(payload)
        return out
    }

    static func sequence(_ items: [Data]) -> Data {
        var payload = Data()
        for item in items {
            payload.append(item)
        }
        return tlv(tag: 0x30, payload: payload)
    }

    static func set(_ items: [Data]) -> Data {
        var payload = Data()
        for item in items {
            payload.append(item)
        }
        return tlv(tag: 0x31, payload: payload)
    }

    static func explicitTag(_ number: UInt8, payload: Data) -> Data {
        tlv(tag: 0xA0 | (number & 0x1F), payload: payload)
    }

    static func boolean(_ value: Bool) -> Data {
        tlv(tag: 0x01, payload: Data([value ? 0xFF : 0x00]))
    }

    static func integer(_ value: Int) -> Data {
        precondition(value >= 0)
        if value == 0 {
            return tlv(tag: 0x02, payload: Data([0x00]))
        }
        var bytes: [UInt8] = []
        var rem = value
        while rem > 0 {
            bytes.insert(UInt8(rem & 0xFF), at: 0)
            rem >>= 8
        }
        if let first = bytes.first, (first & 0x80) != 0 {
            bytes.insert(0x00, at: 0)
        }
        return tlv(tag: 0x02, payload: Data(bytes))
    }

    static func positiveUnsignedInteger(_ rawBytes: Data) -> Data {
        var trimmed = Array(rawBytes)
        while trimmed.count > 1 && trimmed.first == 0x00 {
            trimmed.removeFirst()
        }
        if trimmed.isEmpty {
            trimmed = [0x01]
        }
        if let first = trimmed.first, (first & 0x80) != 0 {
            trimmed.insert(0x00, at: 0)
        }
        return tlv(tag: 0x02, payload: Data(trimmed))
    }

    static func bitString(_ raw: Data, unusedBits: UInt8 = 0) -> Data {
        var payload = Data([unusedBits])
        payload.append(raw)
        return tlv(tag: 0x03, payload: payload)
    }

    static func keyUsageBitString(bitsMSB: [Int]) -> Data {
        // RFC 5280 KeyUsage BIT STRING: bit 0 is MSB (0x80) of byte 0.
        var byte0: UInt8 = 0
        var byte1: UInt8 = 0
        var maxBit = 0
        for bit in bitsMSB {
            maxBit = max(maxBit, bit)
            if bit < 8 {
                byte0 |= UInt8(1 << (7 - bit))
            } else if bit < 16 {
                byte1 |= UInt8(1 << (15 - bit))
            }
        }
        let bytes: [UInt8] = maxBit >= 8 ? [byte0, byte1] : [byte0]
        let lastByteBitCount = (maxBit % 8) + 1
        let unused = UInt8(8 - lastByteBitCount)
        return bitString(Data(bytes), unusedBits: unused)
    }

    static func octetString(_ raw: Data) -> Data {
        tlv(tag: 0x04, payload: raw)
    }

    static func oid(_ dotted: String) throws -> Data {
        let parts = dotted.split(separator: ".").compactMap { UInt64($0) }
        guard parts.count >= 2, parts[0] <= 2, parts[0] == 2 || parts[1] < 40 else {
            throw X509Error.oidEncodingFailed(dotted)
        }
        var bytes: [UInt8] = [UInt8(parts[0] * 40 + parts[1])]
        for arc in parts.dropFirst(2) {
            if arc == 0 {
                bytes.append(0)
                continue
            }
            var encoded: [UInt8] = []
            var v = arc
            encoded.insert(UInt8(v & 0x7F), at: 0)
            v >>= 7
            while v > 0 {
                encoded.insert(UInt8((v & 0x7F) | 0x80), at: 0)
                v >>= 7
            }
            bytes.append(contentsOf: encoded)
        }
        return tlv(tag: 0x06, payload: Data(bytes))
    }

    static func utf8String(_ str: String) -> Data {
        tlv(tag: 0x0C, payload: Data(str.utf8))
    }

    static func generalizedOrUTCTime(_ date: Date) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let year = calendar.component(.year, from: date)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        if year >= 1950 && year <= 2049 {
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            return tlv(tag: 0x17, payload: Data(formatter.string(from: date).utf8))
        } else {
            formatter.dateFormat = "yyyyMMddHHmmss'Z'"
            return tlv(tag: 0x18, payload: Data(formatter.string(from: date).utf8))
        }
    }

    static func name(commonName: String, organization: String?) -> Data {
        var rdns: [Data] = []
        if let organization, !organization.isEmpty {
            let attr = sequence([oidUnsafe("2.5.4.10"), utf8String(organization)])
            rdns.append(set([attr]))
        }
        let cnAttr = sequence([oidUnsafe("2.5.4.3"), utf8String(commonName)])
        rdns.append(set([cnAttr]))
        return sequence(rdns)
    }

    private static func oidUnsafe(_ dotted: String) -> Data {
        (try? oid(dotted)) ?? Data()
    }

    static func extensionEntry(oid oidStr: String, critical: Bool = false, value: Data) throws -> Data {
        var items = [try oid(oidStr)]
        if critical {
            items.append(boolean(true))
        }
        items.append(octetString(value))
        return sequence(items)
    }
}

public enum X509CertificateInspector {
    public static func sha256Hex(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    public static func exportPEM(der: Data) -> String {
        let base64 = der.base64EncodedString()
        var lines: [String] = ["-----BEGIN CERTIFICATE-----"]
        var idx = base64.startIndex
        while idx < base64.endIndex {
            let next = base64.index(idx, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[idx..<next]))
            idx = next
        }
        lines.append("-----END CERTIFICATE-----")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func parseCertificates(from data: Data) throws -> [Data] {
        if let text = String(data: data, encoding: .utf8),
           text.contains("-----BEGIN CERTIFICATE-----") {
            var parsed: [Data] = []
            let blocks = text.components(separatedBy: "-----BEGIN CERTIFICATE-----")
            for block in blocks.dropFirst() {
                guard let endRange = block.range(of: "-----END CERTIFICATE-----") else { continue }
                let body = block[..<endRange.lowerBound]
                    .components(separatedBy: .whitespacesAndNewlines)
                    .joined()
                if let der = Data(base64Encoded: body),
                   SecCertificateCreateWithData(nil, der as CFData) != nil {
                    parsed.append(der)
                }
            }
            if !parsed.isEmpty {
                return parsed
            }
        }

        if SecCertificateCreateWithData(nil, data as CFData) != nil {
            return [data]
        }
        throw X509Error.invalidCertificateData
    }

    public static func inspect(
        der: Data,
        label: String? = nil,
        source: CertificateSource = .imported,
        enabled: Bool = true
    ) throws -> AppCertificateRecord {
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw X509Error.invalidCertificateData
        }
        let fingerprint = sha256Hex(of: der)
        var commonNameCF: CFString?
        SecCertificateCopyCommonName(cert, &commonNameCF)
        let subjectSummary = (SecCertificateCopySubjectSummary(cert) as String?)
            ?? (commonNameCF as String?)
            ?? fingerprint.prefix(12).uppercased()

        let keys: [CFString] = [
            kSecOIDX509V1IssuerName,
            kSecOIDX509V1ValidityNotBefore,
            kSecOIDX509V1ValidityNotAfter,
            kSecOIDBasicConstraints
        ]
        let values = SecCertificateCopyValues(cert, keys as CFArray, nil) as? [CFString: Any] ?? [:]

        let notBefore = extractDate(from: values[kSecOIDX509V1ValidityNotBefore])
        let notAfter = extractDate(from: values[kSecOIDX509V1ValidityNotAfter])
        let isCA = extractIsCA(from: values[kSecOIDBasicConstraints])
        let issuer = extractName(from: values[kSecOIDX509V1IssuerName]) ?? subjectSummary

        let chosenLabel: String
        if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chosenLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            chosenLabel = subjectSummary
        }

        return AppCertificateRecord(
            id: fingerprint,
            label: chosenLabel,
            subject: subjectSummary,
            issuer: issuer,
            notBefore: notBefore,
            notAfter: notAfter,
            isCA: isCA,
            enabled: enabled,
            source: source
        )
    }

    private static func extractDate(from entry: Any?) -> Date? {
        guard let dict = entry as? [CFString: Any],
              let value = dict[kSecPropertyKeyValue] else {
            return nil
        }
        if let date = value as? Date {
            return date
        }
        if let number = value as? NSNumber {
            return Date(timeIntervalSinceReferenceDate: number.doubleValue)
        }
        return nil
    }

    private static func extractIsCA(from entry: Any?) -> Bool {
        guard let dict = entry as? [CFString: Any],
              let pairs = dict[kSecPropertyKeyValue] as? [[CFString: Any]] else {
            return false
        }
        for pair in pairs {
            let label = (pair[kSecPropertyKeyLabel] as? String)?.lowercased() ?? ""
            if label.contains("certificate authority") || label == "ca" {
                if let boolVal = pair[kSecPropertyKeyValue] as? Bool {
                    return boolVal
                }
                if let numVal = pair[kSecPropertyKeyValue] as? NSNumber {
                    return numVal.boolValue
                }
                if let strVal = (pair[kSecPropertyKeyValue] as? String)?.lowercased() {
                    return strVal == "yes" || strVal == "true" || strVal == "1"
                }
            }
        }
        return false
    }

    private static func extractName(from entry: Any?) -> String? {
        guard let dict = entry as? [CFString: Any],
              let pairs = dict[kSecPropertyKeyValue] as? [[CFString: Any]] else {
            return nil
        }
        for pair in pairs {
            let label = (pair[kSecPropertyKeyLabel] as? String) ?? ""
            if label == "2.5.4.3" || label.lowercased().contains("common name"),
               let val = pair[kSecPropertyKeyValue] as? String, !val.isEmpty {
                return val
            }
        }
        for pair in pairs {
            if let val = pair[kSecPropertyKeyValue] as? String, !val.isEmpty {
                return val
            }
        }
        return nil
    }
}

public enum X509CertificateGenerator {
    // ecPublicKey / ecdsa-with-SHA256 (RFC 5758: no NULL params!)
    fileprivate static let oidECDSAWithSHA256 = "1.2.840.10045.4.3.2"
    fileprivate static let oidBasicConstraints = "2.5.29.19"
    fileprivate static let oidKeyUsage = "2.5.29.15"
    fileprivate static let oidSubjectKeyID = "2.5.29.14"
    fileprivate static let oidAuthorityKeyID = "2.5.29.35"
    fileprivate static let oidSubjectAltName = "2.5.29.17"
    fileprivate static let oidExtKeyUsage = "2.5.29.37"
    fileprivate static let oidServerAuth = "1.3.6.1.5.5.7.3.1"

    public static func generateRootCA(
        commonName: String,
        organization: String = "MacOver",
        validDays: Int = 3650
    ) throws -> (certificateDER: Data, privateKeyDER: Data) {
        let key = P256.Signing.PrivateKey()
        let now = Date()
        let notBefore = now.addingTimeInterval(-300)
        let notAfter = now.addingTimeInterval(TimeInterval(validDays * 86_400))

        let serial = randomSerial()
        let issuerAndSubject = ASN1DER.name(commonName: commonName, organization: organization)
        let sigAlg = ASN1DER.sequence([try ASN1DER.oid(oidECDSAWithSHA256)])
        let spki = key.publicKey.derRepresentation
        let skiDigest = Data(SHA256.hash(data: key.publicKey.x963Representation).prefix(20))

        let basicConstraints = try ASN1DER.extensionEntry(
            oid: oidBasicConstraints,
            critical: true,
            value: ASN1DER.sequence([ASN1DER.boolean(true)])
        )
        // keyCertSign = bit 5, cRLSign = bit 6
        let keyUsage = try ASN1DER.extensionEntry(
            oid: oidKeyUsage,
            critical: true,
            value: ASN1DER.keyUsageBitString(bitsMSB: [5, 6])
        )
        let skiExt = try ASN1DER.extensionEntry(
            oid: oidSubjectKeyID,
            critical: false,
            value: ASN1DER.octetString(skiDigest)
        )

        let tbs = ASN1DER.sequence([
            ASN1DER.explicitTag(0, payload: ASN1DER.integer(2)), // v3
            ASN1DER.positiveUnsignedInteger(serial),
            sigAlg,
            issuerAndSubject,
            ASN1DER.sequence([
                ASN1DER.generalizedOrUTCTime(notBefore),
                ASN1DER.generalizedOrUTCTime(notAfter)
            ]),
            issuerAndSubject,
            spki,
            ASN1DER.explicitTag(3, payload: ASN1DER.sequence([basicConstraints, keyUsage, skiExt]))
        ])

        let signature = try key.signature(for: tbs)
        let certDER = ASN1DER.sequence([
            tbs,
            sigAlg,
            ASN1DER.bitString(signature.derRepresentation)
        ])
        return (certDER, key.derRepresentation)
    }

    fileprivate static func randomSerial() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        bytes[0] = (bytes[0] & 0x7F) | 0x01
        return Data(bytes)
    }
}

public final class X509LeafIssuer: Sendable {
    private let rootCertDER: Data
    private let rootSecCertData: Data
    private let rootKey: P256.Signing.PrivateKey
    private let rootSKI: Data
    private let rootSubjectNameDER: Data
    private let rootNotAfter: Date?

    private let leafKey: P256.Signing.PrivateKey
    private let leafKeyAttrData: Data
    private let cachedDERByHost = Mutex<[String: Data]>([:])

    public init(rootCertificateDER: Data, rootPrivateKeyDER: Data) throws {
        guard SecCertificateCreateWithData(nil, rootCertificateDER as CFData) != nil else {
            throw X509Error.invalidCertificateData
        }
        let parsedKey: P256.Signing.PrivateKey
        do {
            parsedKey = try P256.Signing.PrivateKey(derRepresentation: rootPrivateKeyDER)
        } catch {
            throw X509Error.invalidPrivateKeyData
        }
        self.rootCertDER = rootCertificateDER
        self.rootSecCertData = rootCertificateDER
        self.rootKey = parsedKey
        self.rootSKI = Data(SHA256.hash(data: parsedKey.publicKey.x963Representation).prefix(20))
        self.rootSubjectNameDER = try Self.extractSubjectNameDER(fromCertificateDER: rootCertificateDER)
        self.rootNotAfter = (try? X509CertificateInspector.inspect(der: rootCertificateDER))?.notAfter
        self.leafKey = P256.Signing.PrivateKey()
        self.leafKeyAttrData = leafKey.x963Representation
    }

    public func leafCertificateDER(for host: String) throws -> Data {
        let normalized = Self.normalizeHost(host)
        if let existing = cachedDERByHost.withLock({ $0[normalized] }) {
            return existing
        }

        let now = Date()
        // <= 397 days per Apple TLS certificate lifetime policy, clamped to Root CA notAfter.
        let desiredNotAfter = now.addingTimeInterval(365 * 86_400)
        let notAfter = rootNotAfter.map { min(desiredNotAfter, $0) } ?? desiredNotAfter
        let notBefore = min(now.addingTimeInterval(-300), notAfter)

        let sigAlg = ASN1DER.sequence([try ASN1DER.oid(X509CertificateGenerator.oidECDSAWithSHA256)])
        let subject = ASN1DER.name(commonName: normalized, organization: "MacOver MITM")
        let spki = leafKey.publicKey.derRepresentation
        let leafSKI = Data(SHA256.hash(data: leafKey.publicKey.x963Representation).prefix(20))

        let basicConstraints = try ASN1DER.extensionEntry(
            oid: X509CertificateGenerator.oidBasicConstraints,
            critical: true,
            value: ASN1DER.sequence([ASN1DER.boolean(false)])
        )
        // digitalSignature = bit 0, keyEncipherment = bit 2
        let keyUsage = try ASN1DER.extensionEntry(
            oid: X509CertificateGenerator.oidKeyUsage,
            critical: true,
            value: ASN1DER.keyUsageBitString(bitsMSB: [0, 2])
        )
        let eku = try ASN1DER.extensionEntry(
            oid: X509CertificateGenerator.oidExtKeyUsage,
            critical: false,
            value: ASN1DER.sequence([try ASN1DER.oid(X509CertificateGenerator.oidServerAuth)])
        )
        let san = try ASN1DER.extensionEntry(
            oid: X509CertificateGenerator.oidSubjectAltName,
            critical: false,
            value: Self.buildSANSequence(for: normalized)
        )
        let skiExt = try ASN1DER.extensionEntry(
            oid: X509CertificateGenerator.oidSubjectKeyID,
            critical: false,
            value: ASN1DER.octetString(leafSKI)
        )
        let akiExt = try ASN1DER.extensionEntry(
            oid: X509CertificateGenerator.oidAuthorityKeyID,
            critical: false,
            value: ASN1DER.sequence([ASN1DER.tlv(tag: 0x80, payload: rootSKI)])
        )

        let tbs = ASN1DER.sequence([
            ASN1DER.explicitTag(0, payload: ASN1DER.integer(2)),
            ASN1DER.positiveUnsignedInteger(X509CertificateGenerator.randomSerial()),
            sigAlg,
            rootSubjectNameDER,
            ASN1DER.sequence([
                ASN1DER.generalizedOrUTCTime(notBefore),
                ASN1DER.generalizedOrUTCTime(notAfter)
            ]),
            subject,
            spki,
            ASN1DER.explicitTag(
                3,
                payload: ASN1DER.sequence([basicConstraints, keyUsage, eku, san, skiExt, akiExt])
            )
        ])

        let signature = try rootKey.signature(for: tbs)
        let certDER = ASN1DER.sequence([
            tbs,
            sigAlg,
            ASN1DER.bitString(signature.derRepresentation)
        ])

        cachedDERByHost.withLock { cache in
            if cache.count > 256 {
                cache.removeAll(keepingCapacity: true)
            }
            cache[normalized] = certDER
        }
        return certDER
    }

    public func makeSecIdentity(for host: String) throws -> sec_identity_t {
        let leafDER = try leafCertificateDER(for: host)
        guard let leafCert = SecCertificateCreateWithData(nil, leafDER as CFData),
              let rootCert = SecCertificateCreateWithData(nil, rootSecCertData as CFData) else {
            throw X509Error.invalidCertificateData
        }
        var err: Unmanaged<CFError>?
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256
        ]
        guard let secKey = SecKeyCreateWithData(leafKeyAttrData as CFData, keyAttrs as CFDictionary, &err) else {
            let reason = err?.takeRetainedValue().localizedDescription ?? "SecKeyCreateWithData returned nil"
            throw X509Error.secIdentityCreationFailed(reason)
        }
        guard let secIdentity = SecIdentityCreate(nil, leafCert, secKey) else {
            throw X509Error.secIdentityCreationFailed("SecIdentityCreate returned nil")
        }
        let chain: [SecCertificate] = [rootCert]
        guard let nwIdentity = sec_identity_create_with_certificates(secIdentity, chain as CFArray) else {
            throw X509Error.secIdentityCreationFailed("sec_identity_create_with_certificates returned nil")
        }
        return nwIdentity
    }

    private static func normalizeHost(_ host: String) -> String {
        var trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private static func buildSANSequence(for host: String) -> Data {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let ipData = withUnsafeBytes(of: &ipv4) { Data($0) }
            return ASN1DER.sequence([ASN1DER.tlv(tag: 0x87, payload: ipData)])
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            let ipData = withUnsafeBytes(of: &ipv6) { Data($0) }
            return ASN1DER.sequence([ASN1DER.tlv(tag: 0x87, payload: ipData)])
        }
        return ASN1DER.sequence([ASN1DER.tlv(tag: 0x82, payload: Data(host.utf8))])
    }

    private static func extractSubjectNameDER(fromCertificateDER der: Data) throws -> Data {
        // Certificate -> tbsCertificate SEQUENCE { version [0], serial, sigAlg, issuer, validity, subject }
        let certBody = try parseTLV(der, expectedTag: 0x30)
        let tbsBody = try parseTLV(certBody.value, expectedTag: 0x30)
        var cursor = tbsBody.value.startIndex
        let bytes = tbsBody.value

        func nextElement() throws -> Data {
            let parsed = try parseRawElement(bytes[cursor...])
            cursor = parsed.nextIndex
            return parsed.rawElement
        }

        // version [0] optional
        if cursor < bytes.endIndex && bytes[cursor] == 0xA0 {
            _ = try nextElement()
        }
        _ = try nextElement() // serialNumber
        _ = try nextElement() // signature
        _ = try nextElement() // issuer
        _ = try nextElement() // validity
        let subject = try nextElement() // subject
        return subject
    }

    private static func parseTLV(_ data: Data, expectedTag: UInt8) throws -> (value: Data, nextIndex: Data.Index) {
        let parsed = try parseRawElement(data)
        guard parsed.tag == expectedTag else {
            throw X509Error.invalidCertificateData
        }
        return (parsed.value, parsed.nextIndex)
    }

    private static func parseRawElement(
        _ slice: Data
    ) throws -> (tag: UInt8, value: Data, rawElement: Data, nextIndex: Data.Index) {
        var idx = slice.startIndex
        guard idx < slice.endIndex else {
            throw X509Error.invalidCertificateData
        }
        let tag = slice[idx]
        idx = slice.index(after: idx)
        guard idx < slice.endIndex else {
            throw X509Error.invalidCertificateData
        }
        let firstLen = slice[idx]
        idx = slice.index(after: idx)
        let contentLen: Int
        if (firstLen & 0x80) == 0 {
            contentLen = Int(firstLen)
        } else {
            let lenByteCount = Int(firstLen & 0x7F)
            guard lenByteCount > 0, lenByteCount <= 4,
                  slice.distance(from: idx, to: slice.endIndex) >= lenByteCount else {
                throw X509Error.invalidCertificateData
            }
            var decoded = 0
            for _ in 0..<lenByteCount {
                decoded = (decoded << 8) | Int(slice[idx])
                idx = slice.index(after: idx)
            }
            contentLen = decoded
        }
        guard slice.distance(from: idx, to: slice.endIndex) >= contentLen else {
            throw X509Error.invalidCertificateData
        }
        let endIdx = slice.index(idx, offsetBy: contentLen)
        return (tag, slice[idx..<endIdx], slice[slice.startIndex..<endIdx], endIdx)
    }
}
