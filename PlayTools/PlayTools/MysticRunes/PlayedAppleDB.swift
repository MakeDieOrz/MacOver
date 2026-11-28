//
//  PlayedAppleBackend.swift
//  PlayTools
//
//  Created by Ryu-ga on 2/20/24.
//

import CryptoKit
import Darwin
import Foundation
import Security
import SQLite3

final class PlayKeychainDB: NSObject, @unchecked Sendable {
    public static let shared = PlayKeychainDB()

    private let dbLock = PTUnfairLock()
    private let databasePathOverride: String?
    private var dbVersion: Int = 2
    private var cachedDB: OpaquePointer?
    private var cachedDBPath: String?
    private var cachedDBDev: dev_t = 0
    private var cachedDBIno: ino_t = 0
    private var stmtCache: [String: OpaquePointer] = [:]
    private var cachedEnvCFHome: String?
    private var cachedEnvHome: String?
    private var cachedResolvedDBPath: String?
    private var cachedEncryptionKeys: [String: SymmetricKey] = [:]
    private var cachedLegacyFallbackKeys: [String: SymmetricKey] = [:]
    private var activeDBPathForDecryption: String?
    private var defaultAccessGroup: String?

    func setDefaultAccessGroup(_ group: String?) {
        let trimmed = group?.trimmingCharacters(in: .whitespacesAndNewlines)
        dbLock.withLock {
            defaultAccessGroup = (trimmed?.isEmpty == false) ? trimmed : nil
        }
    }

    func currentDefaultAccessGroup() -> String? {
        dbLock.withLock { defaultAccessGroup }
    }

    private static let maxCachedStatements = 64

    private static let plistBlobMagic: [UInt8] = [
        0x50, 0x4C, 0x54, 0x5F, 0x50, 0x4C, 0x49, 0x53, 0x54, 0x00, 0x01, 0x00
    ]
    private static let tagEscapedRawData: UInt8 = 0x00
    private static let tagTypedPlistScalar: UInt8 = 0x01
    private static let tagBoolFalse: UInt8 = 0x02
    private static let tagBoolTrue: UInt8 = 0x03
    private static let tagInt64: UInt8 = 0x04
    private static let tagDouble: UInt8 = 0x05
    private static let tagDate: UInt8 = 0x06
    private static let tagPlistContainer: UInt8 = 0x07
    private static let tagEncryptedData: UInt8 = 0x08
    private static let legacyBplistPrefix: [UInt8] = [0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x30, 0x30]

    private static let encryptedColumns: Set<String> = [
        kSecValueData as String,
        internalPrivateKeyColumn
    ]

    private static let rawBinaryColumns: Set<String> = {
        var cols: Set<String> = Set(([
            kSecValueData,
            kSecValuePersistentRef,
            kSecAttrGeneric,
            kSecAttrIssuer,
            kSecAttrSerialNumber,
            kSecAttrSubject,
            kSecAttrSubjectKeyID,
            kSecAttrPublicKeyHash,
            kSecAttrApplicationLabel,
            kSecAttrApplicationTag
        ] as [CFString]).map { $0 as String })
        cols.insert(internalPrivateKeyColumn)
        return cols
    }()

    private static let legacyDateColumns: Set<String> = Set(([
        kSecAttrCreationDate,
        kSecAttrModificationDate
    ] as [CFString]).map { $0 as String })

    private static let legacyBoolColumns: Set<String> = Set(([
        kSecAttrIsInvisible,
        kSecAttrIsNegative,
        kSecAttrSynchronizable,
        kSecAttrIsPermanent,
        kSecAttrCanEncrypt,
        kSecAttrCanDecrypt,
        kSecAttrCanDerive,
        kSecAttrCanSign,
        kSecAttrCanVerify,
        kSecAttrCanWrap,
        kSecAttrCanUnwrap
    ] as [CFString]).map { $0 as String })

    private static let legacyNumberColumns: Set<String> = Set(([
        kSecAttrPort,
        kSecAttrCreator,
        kSecAttrType,
        kSecAttrCertificateType,
        kSecAttrCertificateEncoding,
        kSecAttrEffectiveKeySize,
        kSecAttrKeySizeInBits,
        kSecAttrAuthenticationType,
        kSecAttrProtocol,
        kSecAttrKeyClass,
        kSecAttrKeyType
    ] as [CFString]).map { $0 as String })

    internal static let internalPrivateKeyColumn = "pc_privkey"
    internal static let internalTokenIDColumn = "pc_tokid"
    private static let internalMatchItemListKey = "__pc_match_item_list"
    private static let internalInvalidQueryKey = "__pc_invalid_query"

    private static let supportedMatchKeys: Set<String> = [
        kSecMatchLimit as String,
        kSecMatchItemList as String
    ]

    private static let supportedUseContextKeys: Set<String> = [
        kSecUseDataProtectionKeychain as String,
        kSecUseAuthenticationContext as String,
        kSecUseAuthenticationUI as String,
        "u_OpPrompt" // kSecUseOperationPrompt (avoid Catalyst deprecation warning)
    ]

    private static let queryMetaKeys: Set<String> = {
        var keys: Set<String> = [
            kSecClass as String,
            kSecReturnData as String,
            kSecReturnAttributes as String,
            kSecReturnRef as String,
            kSecReturnPersistentRef as String,
            internalMatchItemListKey,
            internalInvalidQueryKey
        ]
        keys.formUnion(supportedMatchKeys)
        keys.formUnion(supportedUseContextKeys)
        return keys
    }()

    private static let nonFilterableKeys: Set<String> = [
        kSecAttrAccessControl as String,
        kSecValueRef as String,
        kSecUseDataProtectionKeychain as String,
        internalPrivateKeyColumn
    ]

    private static let nonUpdatableKeys: Set<String> = [
        kSecAttrAccessControl as String,
        kSecValueRef as String,
        kSecUseDataProtectionKeychain as String,
        kSecValuePersistentRef as String,
        kSecAttrCreationDate as String,
        internalTokenIDColumn
    ]

    private static let orderedTableNames: [String] = PlayedAppleDBConstants.primaries.keys
        .map { $0 as String }
        .sorted()

    private static let allowedColumnsByTable: [String: Set<String>] = {
        var map: [String: Set<String>] = [:]
        let valueNames = PlayedAppleDBConstants.values.map { $0 as String }
        for (cls, primaries) in PlayedAppleDBConstants.primaries {
            let table = cls as String
            var cols = Set(primaries.map { $0 as String })
            if let attrs = PlayedAppleDBConstants.attributes[cls] {
                cols.formUnion(attrs.map { $0 as String })
            }
            cols.formUnion(valueNames)
            if table == (kSecClassIdentity as String) {
                cols.insert(internalPrivateKeyColumn)
            }
            if table == (kSecClassKey as String) {
                cols.insert(internalTokenIDColumn)
            }
            map[table] = cols
        }
        return map
    }()

    private struct MatchItemPredicate {
        let targetTable: String?
        let attributes: [String: Any]
        let requiredValueData: Data?
    }

    private struct FilterPlan {
        let clause: String
        let values: [CFTypeRef]
        let hasEffectiveFilter: Bool
        let droppedNonMetaFilterKey: Bool
        let requiredValueData: Data?
        let matchItemPredicates: [MatchItemPredicate]?

        var needsPostFetchFilter: Bool {
            requiredValueData != nil || matchItemPredicates != nil
        }

        var isGuaranteedEmpty: Bool {
            if let predicates = matchItemPredicates, predicates.isEmpty {
                return true
            }
            return false
        }
    }

    private struct PreparedInsert {
        let tableName: String
        let primaryColumns: [CFString]
        let columns: [String]
        let values: [CFTypeRef]
        let insertQuery: String
        let dupCheckSQL: String
        let primaryBindVals: [CFTypeRef]
        let hasNullPrimary: Bool
        let usesDefaultAccessGroup: Bool
        let needsGeneratedPersistentRef: Bool
        let resultDict: NSMutableDictionary
    }

    init(databasePathOverride: String? = nil) {
        self.databasePathOverride = databasePathOverride
        super.init()
    }

    deinit {
        dbLock.withLock {
            closeDatabaseLocked()
        }
    }

    private func closeDatabaseLocked() {
        for stmt in stmtCache.values {
            sqlite3_finalize(stmt)
        }
        stmtCache.removeAll(keepingCapacity: false)
        if let db = cachedDB {
            sqlite3_close_v2(db)
            cachedDB = nil
            cachedDBPath = nil
            cachedDBDev = 0
            cachedDBIno = 0
        }
    }

    private func preparedStatement(for sql: String, in db: OpaquePointer) -> OpaquePointer? {
        if let existing = stmtCache[sql] {
            sqlite3_reset(existing)
            sqlite3_clear_bindings(existing)
            return existing
        }
        var newStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &newStmt, nil) == SQLITE_OK,
              let stmt = newStmt else {
            return nil
        }
        if stmtCache.count >= Self.maxCachedStatements {
            for cached in stmtCache.values {
                sqlite3_finalize(cached)
            }
            stmtCache.removeAll(keepingCapacity: true)
        }
        stmtCache[sql] = stmt
        return stmt
    }

    private static let hostHardwareIdentityBytes: Data = {
        typealias GetHostUUIDFn = @convention(c) (
            UnsafeMutablePointer<UInt8>?,
            UnsafePointer<timespec>?
        ) -> Int32
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "gethostuuid") {
            let fn = unsafeBitCast(sym, to: GetHostUUIDFn.self)
            var uuid = [UInt8](repeating: 0, count: 16)
            var timeout = timespec(tv_sec: 1, tv_nsec: 0)
            if fn(&uuid, &timeout) == 0 {
                return Data(uuid)
            }
        }
        var size = 0
        if Darwin.sysctlbyname("kern.uuid", nil, &size, nil, 0) == 0, size > 0 {
            var buf = [UInt8](repeating: 0, count: size)
            if Darwin.sysctlbyname("kern.uuid", &buf, &size, nil, 0) == 0 {
                return Data(buf.prefix(size))
            }
        }
        return Data(PlaySettings.resolveHostUserRoot().utf8)
    }()

    private static let keyFileName = ".playchain_key"
    private static let keyFileByteCount = 32

    private static func readExactKeyFileNoFollow(atPath path: String) -> Data? {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var st = Darwin.stat()
        guard Darwin.fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size == off_t(keyFileByteCount) else {
            return nil
        }
        _ = Darwin.fchmod(fd, mode_t(0o600))
        var buf = [UInt8](repeating: 0, count: keyFileByteCount)
        var offset = 0
        while offset < keyFileByteCount {
            let n = buf.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: offset), keyFileByteCount - offset)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 {
                return nil
            }
            offset += n
        }
        return Data(buf)
    }

    private func loadOrCreatePerUserKeyFileLocked(forDBPath dbPath: String) -> Data? {
        let playChainDir = (dbPath as NSString).deletingLastPathComponent
        var dirSt = Darwin.stat()
        if Darwin.lstat(playChainDir, &dirSt) != 0 {
            try? FileManager.default.createDirectory(
                atPath: playChainDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            guard Darwin.lstat(playChainDir, &dirSt) == 0 else {
                return nil
            }
        }
        guard (dirSt.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }
        if dirSt.st_uid == Darwin.geteuid() {
            _ = Darwin.chmod(playChainDir, mode_t(0o700))
        }
        var resolvedBuf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolvedDir = Darwin.realpath(playChainDir, &resolvedBuf)
            .map { String(cString: $0) } ?? playChainDir
        let keyPath = (resolvedDir as NSString).appendingPathComponent(Self.keyFileName)

        if let existing = Self.readExactKeyFileNoFollow(atPath: keyPath) {
            return existing
        }
        var existingSt = Darwin.stat()
        if Darwin.lstat(keyPath, &existingSt) == 0 {
            // Do not overwrite symlink or unexpected existing entry.
            return nil
        }

        var randomBytes = [UInt8](repeating: 0, count: Self.keyFileByteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, Self.keyFileByteCount, &randomBytes) == errSecSuccess else {
            return nil
        }
        let tmpPath = (resolvedDir as NSString)
            .appendingPathComponent("\(Self.keyFileName).tmp.\(Darwin.getpid()).\(UUID().uuidString)")
        let fd = Darwin.open(tmpPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else {
            return nil
        }
        var writeOK = true
        var written = 0
        while written < Self.keyFileByteCount {
            let n = randomBytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: written), Self.keyFileByteCount - written)
            }
            if n < 0 {
                if errno == EINTR { continue }
                writeOK = false
                break
            }
            written += n
        }
        _ = Darwin.fchmod(fd, mode_t(0o600))
        _ = Darwin.fsync(fd)
        Darwin.close(fd)
        guard writeOK else {
            _ = Darwin.unlink(tmpPath)
            return nil
        }

        let linkRC = Darwin.link(tmpPath, keyPath)
        let linkErr = errno
        _ = Darwin.unlink(tmpPath)
        if linkRC == 0 {
            hardenRegularFileMode0600(atPath: keyPath)
            return Data(randomBytes)
        }
        if linkErr == EEXIST {
            return Self.readExactKeyFileNoFollow(atPath: keyPath)
        }
        return nil
    }

    private func deriveLegacyDeterministicKey(fileName: String, uid: uid_t) -> SymmetricKey {
        var material = Data()
        material.append(Self.hostHardwareIdentityBytes)
        var uidLE = uid.littleEndian
        withUnsafeBytes(of: &uidLE) { material.append(contentsOf: $0) }
        material.append(Data(PlaySettings.resolveHostUserRoot().utf8))
        material.append(Data(fileName.utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: material),
            salt: Data("app.makedie.MacOver.PlayChain.v1".utf8),
            info: Data("AES-256-GCM:\(fileName):uid=\(uid)".utf8),
            outputByteCount: 32
        )
    }

    private func encryptionKeyLocked(forDBPath dbPath: String) -> SymmetricKey {
        if let cached = cachedEncryptionKeys[dbPath] {
            return cached
        }
        let fileName = (dbPath as NSString).lastPathComponent
        let uid = Darwin.getuid()
        let legacyV1 = deriveLegacyDeterministicKey(fileName: fileName, uid: uid)

        if let perUserSecret = loadOrCreatePerUserKeyFileLocked(forDBPath: dbPath) {
            var material = Data()
            material.append(perUserSecret)
            material.append(Self.hostHardwareIdentityBytes)
            var uidLE = uid.littleEndian
            withUnsafeBytes(of: &uidLE) { material.append(contentsOf: $0) }
            material.append(Data(PlaySettings.resolveHostUserRoot().utf8))
            material.append(Data(fileName.utf8))
            let derived = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: material),
                salt: Data("app.makedie.MacOver.PlayChain.v2".utf8),
                info: Data("AES-256-GCM:\(fileName):uid=\(uid)".utf8),
                outputByteCount: 32
            )
            cachedEncryptionKeys[dbPath] = derived
            cachedLegacyFallbackKeys[dbPath] = legacyV1
            return derived
        }

        cachedEncryptionKeys[dbPath] = legacyV1
        cachedLegacyFallbackKeys.removeValue(forKey: dbPath)
        return legacyV1
    }

    private static func encryptSecretBlob(
        _ plaintext: Data,
        columnName: String,
        key: SymmetricKey
    ) -> Data? {
        guard let sealed = try? AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: Data(columnName.utf8)
        ), let combined = sealed.combined else {
            return nil
        }
        var out = Data(capacity: plistBlobMagic.count + 1 + combined.count)
        out.append(contentsOf: plistBlobMagic)
        out.append(tagEncryptedData)
        out.append(combined)
        return out
    }

    private static func decryptSecretBlob(
        bytes: UnsafePointer<UInt8>,
        length: Int,
        columnName: String,
        key: SymmetricKey
    ) -> Data? {
        guard length >= 28 else { return nil }
        let combined = Data(bytes: bytes, count: length)
        guard let sealedBox = try? AES.GCM.SealedBox(combined: combined) else {
            return nil
        }
        return try? AES.GCM.open(
            sealedBox,
            using: key,
            authenticating: Data(columnName.utf8)
        )
    }

    private static func boolValue(from raw: Any) -> Bool? {
        let cf = raw as CFTypeRef
        let typeID = CFGetTypeID(cf)
        if typeID == CFBooleanGetTypeID() {
            return CFBooleanGetValue(unsafeDowncast(cf, to: CFBoolean.self))
        }
        if typeID == CFNumberGetTypeID(), let num = raw as? NSNumber {
            return num.boolValue
        }
        return nil
    }

    private static func isEncodableValue(_ val: Any) -> Bool {
        let cf = val as CFTypeRef
        switch CFGetTypeID(cf) {
        case CFStringGetTypeID(),
             CFDataGetTypeID(),
             CFBooleanGetTypeID(),
             CFNumberGetTypeID(),
             CFDateGetTypeID():
            return true
        case CFDictionaryGetTypeID(), CFArrayGetTypeID():
            return CFPropertyListIsValid(cf, .binaryFormat_v1_0)
        default:
            return false
        }
    }

    private static func isEncodableForFilter(_ val: Any) -> Bool {
        return isEncodableValue(val)
    }

    private static func validateQueryParameters(_ raw: NSDictionary) -> OSStatus {
        for (rawKey, val) in raw {
            guard let key = rawKey as? String else {
                return errSecParam
            }
            if key == (kSecMatchItemList as String) {
                guard val is [Any] || val is NSArray else {
                    return errSecParam
                }
                continue
            }
            if key == "u_ItemList" || key == "keychain" {
                return errSecParam
            }
            if key.hasPrefix("m_"), !supportedMatchKeys.contains(key) {
                return errSecParam
            }
            if key.hasPrefix("u_"), !supportedUseContextKeys.contains(key) {
                return errSecParam
            }
        }
        return errSecSuccess
    }

    private static func populateCertificateMetadata(from cert: SecCertificate, into dict: NSMutableDictionary) {
        if dict[kSecAttrIssuer] == nil,
           let issuer = SecCertificateCopyNormalizedIssuerSequence(cert) as Data? {
            dict[kSecAttrIssuer as String] = issuer
        }
        if dict[kSecAttrSubject] == nil,
           let subject = SecCertificateCopyNormalizedSubjectSequence(cert) as Data? {
            dict[kSecAttrSubject as String] = subject
        }
        if dict[kSecAttrSerialNumber] == nil,
           let serial = SecCertificateCopySerialNumberData(cert, nil) as Data? {
            dict[kSecAttrSerialNumber as String] = serial
        }
        if dict[kSecAttrLabel] == nil,
           let summary = SecCertificateCopySubjectSummary(cert) as String? {
            dict[kSecAttrLabel as String] = summary
        }
        if dict[kSecAttrPublicKeyHash] == nil,
           let pubKey = SecCertificateCopyKey(cert),
           let pubData = SecKeyCopyExternalRepresentation(pubKey, nil) as Data? {
            dict[kSecAttrPublicKeyHash as String] = Data(Insecure.SHA1.hash(data: pubData))
        }
    }

    private static func mergeKeyAttributes(
        from keyAttrs: NSDictionary,
        into dict: NSMutableDictionary,
        allowedCols: Set<String>
    ) {
        for (rawKey, val) in keyAttrs {
            guard let col = rawKey as? String,
                  allowedCols.contains(col),
                  !nonFilterableKeys.contains(col),
                  col != (kSecValueData as String),
                  col != (kSecValuePersistentRef as String),
                  dict[col] == nil,
                  isEncodableValue(val) else {
                continue
            }
            dict[col] = val
        }
    }

    private static func extractReferenceAttributes(
        from cfRef: CFTypeRef,
        into dict: NSMutableDictionary,
        forPersistence: Bool
    ) -> Bool {
        let typeID = CFGetTypeID(cfRef)
        if typeID == SecCertificateGetTypeID() {
            let cert = unsafeDowncast(cfRef, to: SecCertificate.self)
            if dict[kSecClass] == nil {
                dict[kSecClass as String] = kSecClassCertificate
            }
            if dict[kSecValueData] == nil {
                dict[kSecValueData as String] = SecCertificateCopyData(cert) as Data
            }
            populateCertificateMetadata(from: cert, into: dict)
            return true
        }
        if typeID == SecKeyGetTypeID() {
            let key = unsafeDowncast(cfRef, to: SecKey.self)
            if dict[kSecClass] == nil {
                dict[kSecClass as String] = kSecClassKey
            }
            var extracted = false
            if dict[kSecValueData] == nil,
               let extData = SecKeyCopyExternalRepresentation(key, nil) as Data? {
                dict[kSecValueData as String] = extData
                extracted = true
            }
            if forPersistence, PTPlayChainSecureEnclaveRegistry.isSecureEnclaveKey(key) {
                dict[internalTokenIDColumn] = kSecAttrTokenIDSecureEnclave as String
            }
            if let keyAttrs = SecKeyCopyAttributes(key) as NSDictionary? {
                if dict[kSecValueData] == nil, let vData = keyAttrs[kSecValueData] as? Data {
                    dict[kSecValueData as String] = vData
                    extracted = true
                }
                if forPersistence, let keyCols = allowedColumnsByTable[kSecClassKey as String] {
                    mergeKeyAttributes(from: keyAttrs, into: dict, allowedCols: keyCols)
                } else {
                    if dict[kSecAttrKeyType] == nil, let kType = keyAttrs[kSecAttrKeyType] {
                        dict[kSecAttrKeyType as String] = kType
                    }
                    if dict[kSecAttrKeyClass] == nil, let kClass = keyAttrs[kSecAttrKeyClass] {
                        dict[kSecAttrKeyClass as String] = kClass
                    }
                    if dict[kSecAttrApplicationLabel] == nil,
                       let appLabel = keyAttrs[kSecAttrApplicationLabel] {
                        dict[kSecAttrApplicationLabel as String] = appLabel
                    }
                }
            }
            return extracted || dict[kSecValueData] != nil || dict[kSecAttrApplicationLabel] != nil
        }
        if typeID == SecIdentityGetTypeID() {
            let identity = unsafeDowncast(cfRef, to: SecIdentity.self)
            if dict[kSecClass] == nil {
                dict[kSecClass as String] = kSecClassIdentity
            }
            var extracted = false
            var certRef: SecCertificate?
            if SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess, let cert = certRef {
                if dict[kSecValueData] == nil {
                    dict[kSecValueData as String] = SecCertificateCopyData(cert) as Data
                }
                populateCertificateMetadata(from: cert, into: dict)
                extracted = true
            }
            var privKeyRef: SecKey?
            if SecIdentityCopyPrivateKey(identity, &privKeyRef) == errSecSuccess, let privKey = privKeyRef {
                if forPersistence {
                    if let keyAttrs = SecKeyCopyAttributes(privKey) as NSDictionary?,
                       let idCols = allowedColumnsByTable[kSecClassIdentity as String] {
                        mergeKeyAttributes(from: keyAttrs, into: dict, allowedCols: idCols)
                    }
                    if let privData = SecKeyCopyExternalRepresentation(privKey, nil) as Data? {
                        if dict[kSecValueData] == nil {
                            dict[kSecValueData as String] = privData
                        }
                        dict[internalPrivateKeyColumn] = privData
                        extracted = true
                    }
                } else if dict[kSecValueData] == nil,
                          let privData = SecKeyCopyExternalRepresentation(privKey, nil) as Data? {
                    dict[kSecValueData as String] = privData
                    extracted = true
                }
            }
            return extracted
        }
        if typeID == CFDataGetTypeID(), let rawData = cfRef as? Data,
           PTPlayChainPersistentRef.isPersistentRef(rawData) {
            if let table = PTPlayChainPersistentRef.decodeTableName(from: rawData), dict[kSecClass] == nil {
                dict[kSecClass as String] = table
            }
            dict[kSecValuePersistentRef as String] = rawData
            return true
        }
        return false
    }

    private static func normalizeAttributes(
        _ raw: NSDictionary,
        forPersistence: Bool,
        populateCertMetadataFromData: Bool
    ) -> NSMutableDictionary {
        let dict = NSMutableDictionary(dictionary: raw)
        if let ref = dict[kSecValueRef] {
            let ok = extractReferenceAttributes(
                from: ref as CFTypeRef,
                into: dict,
                forPersistence: forPersistence
            )
            if !ok {
                dict[internalInvalidQueryKey] = true
            }
            dict.removeObject(forKey: kSecValueRef)
        }

        if let rawMatchList = dict[kSecMatchItemList] {
            dict.removeObject(forKey: kSecMatchItemList)
            if let items = rawMatchList as? [Any] {
                var extractedPredicates: [MatchItemPredicate] = []
                extractedPredicates.reserveCapacity(items.count)
                for item in items {
                    let itemDict = NSMutableDictionary()
                    guard extractReferenceAttributes(
                        from: item as CFTypeRef,
                        into: itemDict,
                        forPersistence: false
                    ) else {
                        dict[internalInvalidQueryKey] = true
                        break
                    }
                    let targetTable = itemDict[kSecClass] as? String
                    let requiredData = itemDict[kSecValueData] as? Data
                    var attrMap: [String: Any] = [:]
                    for (k, v) in itemDict {
                        guard let keyStr = k as? String,
                              keyStr != (kSecClass as String),
                              keyStr != (kSecValueData as String),
                              !nonFilterableKeys.contains(keyStr) else {
                            continue
                        }
                        attrMap[keyStr] = v
                    }
                    extractedPredicates.append(
                        MatchItemPredicate(
                            targetTable: targetTable,
                            attributes: attrMap,
                            requiredValueData: requiredData
                        )
                    )
                }
                dict[internalMatchItemListKey] = extractedPredicates
            } else {
                dict[internalInvalidQueryKey] = true
            }
        }

        if populateCertMetadataFromData,
           (dict[kSecClass] as? String) == (kSecClassCertificate as String),
           let certData = dict[kSecValueData] as? Data,
           let cert = SecCertificateCreateWithData(nil, certData as CFData) {
            populateCertificateMetadata(from: cert, into: dict)
        }

        if let tokenID = dict[kSecAttrTokenID as String] as? String {
            dict[internalTokenIDColumn] = tokenID
            dict.removeObject(forKey: kSecAttrTokenID)
        }

        return dict
    }

    private static func makePersistentRef(tableName: String, rowID: Int64) -> Data {
        return PTPlayChainPersistentRef.encode(tableName: tableName, rowID: rowID)
    }

    private static func resolveCandidateTables(for attributes: NSDictionary) -> [String] {
        if let tableName = attributes[kSecClass] as? String {
            return PlayedAppleDBConstants.primaries[tableName as CFString] != nil ? [tableName] : []
        }
        if let pRefData = attributes[kSecValuePersistentRef] as? Data {
            if let decodedTable = PTPlayChainPersistentRef.decodeTableName(from: pRefData),
               PlayedAppleDBConstants.primaries[decodedTable as CFString] != nil {
                return [decodedTable]
            }
            return orderedTableNames
        }
        if let predicates = attributes[internalMatchItemListKey] as? [MatchItemPredicate] {
            var tables: [String] = []
            var seen = Set<String>()
            for pred in predicates {
                if let table = pred.targetTable,
                   PlayedAppleDBConstants.primaries[table as CFString] != nil,
                   seen.insert(table).inserted {
                    tables.append(table)
                }
            }
            if !tables.isEmpty {
                return tables
            }
            if !predicates.isEmpty {
                return orderedTableNames
            }
            return []
        }
        return []
    }

    private func buildFilterPlan(
        tableName: String,
        primaryColumns: [CFString],
        attributes: NSDictionary,
        defaultAccessGroup: String? = nil
    ) -> FilterPlan? {
        guard let allowedCols = Self.allowedColumnsByTable[tableName] else {
            return nil
        }

        var clauses: [String] = []
        var values: [CFTypeRef] = []
        var seen = Set<String>()
        var hasEffectiveFilter = false
        var droppedNonMetaFilterKey = false
        var requiredValueData: Data?

        let matchPredicates = attributes[Self.internalMatchItemListKey] as? [MatchItemPredicate]
        if let matchPredicates {
            hasEffectiveFilter = true
            let tablePredicates = matchPredicates.filter { pred in
                pred.targetTable == nil || pred.targetTable == tableName
            }
            if tablePredicates.isEmpty {
                return FilterPlan(
                    clause: "1 = 0",
                    values: [],
                    hasEffectiveFilter: true,
                    droppedNonMetaFilterKey: false,
                    requiredValueData: nil,
                    matchItemPredicates: []
                )
            }
        }

        func appendFilter(key: String, attr: Any) {
            guard !seen.contains(key) else {
                return
            }
            if Self.queryMetaKeys.contains(key) {
                seen.insert(key)
                return
            }
            seen.insert(key)
            if key == (kSecValueData as String) {
                if let data = attr as? Data {
                    requiredValueData = data
                    hasEffectiveFilter = true
                } else {
                    droppedNonMetaFilterKey = true
                }
                return
            }
            guard allowedCols.contains(key), !Self.nonFilterableKeys.contains(key) else {
                droppedNonMetaFilterKey = true
                return
            }
            if key == (kSecAttrSynchronizable as String) {
                if (attr as? String) == (kSecAttrSynchronizableAny as String) {
                    return
                }
                if let boolVal = Self.boolValue(from: attr) {
                    if boolVal {
                        clauses.append("\(key) = ?")
                        values.append(true as CFBoolean)
                    } else {
                        clauses.append("(\(key) = ? OR \(key) IS NULL)")
                        values.append(false as CFBoolean)
                    }
                    hasEffectiveFilter = true
                } else {
                    droppedNonMetaFilterKey = true
                }
                return
            }
            if key == (kSecAttrAccessGroup as String),
               let strAttr = attr as? String,
               let defGroup = defaultAccessGroup,
               strAttr == defGroup {
                clauses.append("(\(key) = ? OR \(key) IS NULL)")
                values.append(strAttr as CFTypeRef)
                hasEffectiveFilter = true
                return
            }
            if attr is NSNull {
                clauses.append("\(key) IS NULL")
                hasEffectiveFilter = true
            } else if Self.isEncodableForFilter(attr) {
                clauses.append("\(key) = ?")
                values.append(attr as CFTypeRef)
                hasEffectiveFilter = true
            } else {
                droppedNonMetaFilterKey = true
            }
        }

        for col in primaryColumns {
            let key = col as String
            if let attr = attributes[col] {
                appendFilter(key: key, attr: attr)
            }
        }
        if let secondaryColumns = PlayedAppleDBConstants.attributes[tableName as CFString] {
            for col in secondaryColumns {
                let key = col as String
                if let attr = attributes[col] {
                    appendFilter(key: key, attr: attr)
                }
            }
        }
        for (rawKey, attr) in attributes {
            if let key = rawKey as? String {
                appendFilter(key: key, attr: attr)
            } else {
                droppedNonMetaFilterKey = true
            }
        }

        let clause = clauses.isEmpty ? "1 = 1" : clauses.joined(separator: " AND ")
        let filteredPredicates = matchPredicates?.filter { pred in
            pred.targetTable == nil || pred.targetTable == tableName
        }
        return FilterPlan(
            clause: clause,
            values: values,
            hasEffectiveFilter: hasEffectiveFilter,
            droppedNonMetaFilterKey: droppedNonMetaFilterKey,
            requiredValueData: requiredValueData,
            matchItemPredicates: filteredPredicates
        )
    }

    private static func valuesEqual(_ lhs: Any?, _ rhs: Any) -> Bool {
        guard let lhs else {
            return rhs is NSNull
        }
        if let lData = lhs as? Data, let rData = rhs as? Data {
            return lData == rData
        }
        if let lStr = lhs as? String, let rStr = rhs as? String {
            return lStr == rStr
        }
        if let lBool = boolValue(from: lhs), let rBool = boolValue(from: rhs) {
            return lBool == rBool
        }
        if let lNum = lhs as? NSNumber, let rNum = rhs as? NSNumber {
            return lNum == rNum
        }
        if let lDate = lhs as? Date, let rDate = rhs as? Date {
            return abs(lDate.timeIntervalSince1970 - rDate.timeIntervalSince1970) < 0.0001
        }
        return (lhs as AnyObject).isEqual(rhs)
    }

    private static func rowMatchesPostFilters(_ row: NSDictionary, plan: FilterPlan) -> Bool {
        if let requiredData = plan.requiredValueData {
            guard let rowData = row[kSecValueData as String] as? Data, rowData == requiredData else {
                return false
            }
        }
        if let predicates = plan.matchItemPredicates {
            guard !predicates.isEmpty else { return false }
            let matchedAny = predicates.contains { pred in
                if let expectedData = pred.requiredValueData {
                    guard let rowData = row[kSecValueData as String] as? Data,
                          rowData == expectedData else {
                        return false
                    }
                }
                for (key, expectedVal) in pred.attributes where !valuesEqual(row[key], expectedVal) {
                    return false
                }
                return true
            }
            if !matchedAny {
                return false
            }
        }
        return true
    }

    private func bindValues(
        _ values: [CFTypeRef],
        columns: [String]? = nil,
        encryptionKey: SymmetricKey? = nil,
        to stmt: OpaquePointer,
        startingAt startIndex: Int32 = 1,
        in sqlite3DB: OpaquePointer,
        context: String
    ) -> Bool {
        for (offset, value) in values.enumerated() {
            let colName = columns.flatMap { offset < $0.count ? $0[offset] : nil }
            if !encodeData(
                stmt: stmt,
                index: startIndex + Int32(offset),
                value: value,
                columnName: colName,
                encryptionKey: encryptionKey
            ) {
                let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed to \(context) db: \(errorMessage)")
                return false
            }
        }
        return true
    }

    func query(_ attributes: NSDictionary) -> [NSMutableDictionary]? {
        let (status, items) = queryWithStatus(attributes)
        guard status == errSecSuccess else {
            return nil
        }
        return items
    }

    func queryWithStatus(_ attributes: NSDictionary) -> (status: OSStatus, items: [NSMutableDictionary]?) {
        let paramStatus = Self.validateQueryParameters(attributes)
        guard paramStatus == errSecSuccess else {
            return (paramStatus, nil)
        }
        let normalized = Self.normalizeAttributes(
            attributes,
            forPersistence: false,
            populateCertMetadataFromData: false
        )
        if normalized[Self.internalInvalidQueryKey] != nil {
            return (errSecParam, nil)
        }
        if let predicates = normalized[Self.internalMatchItemListKey] as? [MatchItemPredicate],
           predicates.isEmpty {
            return (errSecItemNotFound, nil)
        }
        let candidateTables = Self.resolveCandidateTables(for: normalized)
        guard !candidateTables.isEmpty else {
            return (errSecParam, nil)
        }

        let matchLimitObj = normalized[kSecMatchLimit]
        let isLimitAll = (matchLimitObj as? String == kSecMatchLimitAll as String)
        let isLimitOne = (matchLimitObj as? String == kSecMatchLimitOne as String)
        let explicitLimit: Int64
        if isLimitAll {
            explicitLimit = -1
        } else if isLimitOne || matchLimitObj == nil {
            explicitLimit = 1
        } else if let num = matchLimitObj as? NSNumber {
            explicitLimit = max(1, num.int64Value)
        } else {
            return (errSecParam, nil)
        }
        let selectLimit = (explicitLimit < 0) ? Int.max : Int(explicitLimit)

        let defaultGroup = currentDefaultAccessGroup()
        var dictArr: [NSMutableDictionary] = []
        var finalStatus: OSStatus = errSecIO
        let ok = usingDB { sqlite3DB, dbPath, encKey in
            for tableName in candidateTables {
                if explicitLimit >= 0 && dictArr.count >= selectLimit {
                    break
                }
                guard let primaryColumns = PlayedAppleDBConstants.primaries[tableName as CFString],
                      let plan = buildFilterPlan(
                          tableName: tableName,
                          primaryColumns: primaryColumns,
                          attributes: normalized,
                          defaultAccessGroup: defaultGroup
                      ) else {
                    continue
                }
                if plan.droppedNonMetaFilterKey {
                    finalStatus = errSecParam
                    return false
                }
                if plan.isGuaranteedEmpty {
                    continue
                }

                let remainingLimit: Int64 = (explicitLimit < 0 || plan.needsPostFetchFilter)
                    ? -1
                    : Int64(selectLimit - dictArr.count)
                let selectQuery = "SELECT rowid, * FROM \(tableName) WHERE \(plan.clause) LIMIT ?"
                var missingPersistentRefs: [(Int64, Data)] = []

                do {
                    guard let stmt = preparedStatement(for: selectQuery, in: sqlite3DB) else {
                        PlayKeychain.debugLogger("Failed query \(selectQuery)")
                        let errMsg = String(cString: sqlite3_errmsg(sqlite3DB))
                        PlayKeychain.debugLogger("Failed to query to db table: \(errMsg)")
                        finalStatus = errSecIO
                        return false
                    }
                    defer { sqlite3_reset(stmt) }

                    guard bindValues(plan.values, to: stmt, in: sqlite3DB, context: "bind query") else {
                        finalStatus = errSecIO
                        return false
                    }

                    let limitIndex = Int32(plan.values.count + 1)
                    guard sqlite3_bind_int64(stmt, limitIndex, remainingLimit) == SQLITE_OK else {
                        let errMsg = String(cString: sqlite3_errmsg(sqlite3DB))
                        PlayKeychain.debugLogger("Failed to bind query limit: \(errMsg)")
                        finalStatus = errSecIO
                        return false
                    }

                    let columns = sqlite3_column_count(stmt)
                    var columnNames: [String] = []
                    columnNames.reserveCapacity(Int(columns))
                    for index in 0..<columns {
                        columnNames.append(String(cString: sqlite3_column_name(stmt, index)))
                    }

                    var lastStepRc: Int32 = SQLITE_DONE
                    while dictArr.count < selectLimit {
                        lastStepRc = sqlite3_step(stmt)
                        guard lastStepRc == SQLITE_ROW else {
                            break
                        }
                        let rowID = sqlite3_column_int64(stmt, 0)
                        let newDict = NSMutableDictionary(capacity: Int(columns) + 2)
                        newDict[kSecClass as String] = tableName
                        for index in 1..<Int(columns) {
                            if let value = decodeData(
                                stmt: stmt,
                                index: Int32(index),
                                columnName: columnNames[index],
                                encryptionKey: encKey
                            ) {
                                newDict[columnNames[index]] = value
                            }
                        }
                        if newDict[kSecAttrSynchronizable as String] == nil {
                            newDict[kSecAttrSynchronizable as String] = false as CFBoolean
                        }
                        if newDict[kSecAttrAccessGroup as String] == nil, let defGroup = defaultGroup {
                            newDict[kSecAttrAccessGroup as String] = defGroup
                        }
                        if newDict[kSecValuePersistentRef as String] == nil {
                            let pRef = Self.makePersistentRef(tableName: tableName, rowID: rowID)
                            newDict[kSecValuePersistentRef as String] = pRef
                            missingPersistentRefs.append((rowID, pRef))
                        }
                        if !plan.needsPostFetchFilter || Self.rowMatchesPostFilters(newDict, plan: plan) {
                            dictArr.append(newDict)
                        }
                    }

                    if dictArr.count < selectLimit && lastStepRc != SQLITE_DONE {
                        PlayKeychain.debugLogger("Query step failed with SQLite rc=\(lastStepRc)")
                        finalStatus = errSecIO
                        return false
                    }
                }

                if !missingPersistentRefs.isEmpty {
                    backfillPersistentRefs(
                        missingPersistentRefs,
                        tableName: tableName,
                        in: sqlite3DB,
                        dbPath: dbPath
                    )
                }

                if tableName == (kSecClassIdentity as String), dictArr.count < selectLimit {
                    let synthStatus = appendSynthesizedIdentities(
                        into: &dictArr,
                        limit: selectLimit,
                        normalizedQuery: normalized,
                        identityPlan: plan,
                        defaultAccessGroup: defaultGroup,
                        sqlite3DB: sqlite3DB,
                        encryptionKey: encKey
                    )
                    if synthStatus != errSecSuccess {
                        finalStatus = synthStatus
                        return false
                    }
                }
            }

            finalStatus = errSecSuccess
            return true
        }
        guard ok, finalStatus == errSecSuccess else {
            return (finalStatus, nil)
        }
        return (errSecSuccess, dictArr)
    }

    private func backfillPersistentRefs(
        _ refs: [(Int64, Data)],
        tableName: String,
        in sqlite3DB: OpaquePointer,
        dbPath: String
    ) {
        guard sqlite3_exec(sqlite3DB, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            return
        }
        let backfillSQL = "UPDATE \(tableName) SET \(kSecValuePersistentRef) = ? WHERE rowid = ?"
        var succeeded = true
        if let updStmt = preparedStatement(for: backfillSQL, in: sqlite3DB) {
            defer { sqlite3_reset(updStmt) }
            for (rowID, pRef) in refs {
                sqlite3_reset(updStmt)
                sqlite3_clear_bindings(updStmt)
                if encodeData(stmt: updStmt, index: 1, value: pRef as CFData),
                   sqlite3_bind_int64(updStmt, 2, rowID) == SQLITE_OK,
                   sqlite3_step(updStmt) == SQLITE_DONE {
                    continue
                }
                succeeded = false
                break
            }
        } else {
            succeeded = false
        }
        if succeeded && sqlite3_exec(sqlite3DB, "COMMIT", nil, nil, nil) == SQLITE_OK {
            hardenDatabaseSidecars(forDBPath: dbPath)
        } else {
            _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
        }
    }

    private func fetchAllRows(
        tableName: String,
        defaultAccessGroup: String?,
        sqlite3DB: OpaquePointer,
        encryptionKey: SymmetricKey
    ) -> (status: OSStatus, rows: [NSMutableDictionary]) {
        let sql = "SELECT rowid, * FROM \(tableName)"
        guard let stmt = preparedStatement(for: sql, in: sqlite3DB) else {
            return (errSecIO, [])
        }
        defer { sqlite3_reset(stmt) }
        let columns = sqlite3_column_count(stmt)
        var columnNames: [String] = []
        columnNames.reserveCapacity(Int(columns))
        for index in 0..<columns {
            columnNames.append(String(cString: sqlite3_column_name(stmt, index)))
        }
        var rows: [NSMutableDictionary] = []
        var stepRc: Int32 = SQLITE_DONE
        while true {
            stepRc = sqlite3_step(stmt)
            guard stepRc == SQLITE_ROW else { break }
            let rowID = sqlite3_column_int64(stmt, 0)
            let row = NSMutableDictionary(capacity: Int(columns) + 2)
            row[kSecClass as String] = tableName
            for index in 1..<Int(columns) {
                if let value = decodeData(
                    stmt: stmt,
                    index: Int32(index),
                    columnName: columnNames[index],
                    encryptionKey: encryptionKey
                ) {
                    row[columnNames[index]] = value
                }
            }
            if row[kSecAttrSynchronizable as String] == nil {
                row[kSecAttrSynchronizable as String] = false as CFBoolean
            }
            if row[kSecAttrAccessGroup as String] == nil, let defGroup = defaultAccessGroup {
                row[kSecAttrAccessGroup as String] = defGroup
            }
            if row[kSecValuePersistentRef as String] == nil {
                row[kSecValuePersistentRef as String] = Self.makePersistentRef(tableName: tableName, rowID: rowID)
            }
            rows.append(row)
        }
        guard stepRc == SQLITE_DONE else {
            return (errSecIO, [])
        }
        return (errSecSuccess, rows)
    }

    // swiftlint:disable:next function_parameter_count
    private func appendSynthesizedIdentities(
        into results: inout [NSMutableDictionary],
        limit: Int,
        normalizedQuery: NSDictionary,
        identityPlan: FilterPlan,
        defaultAccessGroup: String?,
        sqlite3DB: OpaquePointer,
        encryptionKey: SymmetricKey
    ) -> OSStatus {
        let certFetch = fetchAllRows(
            tableName: kSecClassCertificate as String,
            defaultAccessGroup: defaultAccessGroup,
            sqlite3DB: sqlite3DB,
            encryptionKey: encryptionKey
        )
        guard certFetch.status == errSecSuccess else {
            return certFetch.status
        }
        guard !certFetch.rows.isEmpty else {
            return errSecSuccess
        }

        let keyFetch = fetchAllRows(
            tableName: kSecClassKey as String,
            defaultAccessGroup: defaultAccessGroup,
            sqlite3DB: sqlite3DB,
            encryptionKey: encryptionKey
        )
        guard keyFetch.status == errSecSuccess else {
            return keyFetch.status
        }
        let privateKeys = keyFetch.rows.filter { row in
            let kcls = (row[kSecAttrKeyClass as String] as? String) ?? (row["kcls"] as? String)
            return kcls == (kSecAttrKeyClassPrivate as String)
        }
        guard !privateKeys.isEmpty else {
            return errSecSuccess
        }

        let existingCertDatas = Set(results.compactMap { $0[kSecValueData as String] as? Data })
        let idCols = Self.allowedColumnsByTable[kSecClassIdentity as String] ?? []

        for certRow in certFetch.rows {
            if results.count >= limit {
                break
            }
            guard let certData = certRow[kSecValueData as String] as? Data,
                  !existingCertDatas.contains(certData) else {
                continue
            }
            var pubKeyHash = certRow[kSecAttrPublicKeyHash as String] as? Data
            if pubKeyHash == nil,
               let cert = SecCertificateCreateWithData(nil, certData as CFData),
               let pubKey = SecCertificateCopyKey(cert),
               let pubData = SecKeyCopyExternalRepresentation(pubKey, nil) as Data? {
                pubKeyHash = Data(Insecure.SHA1.hash(data: pubData))
            }
            guard let certHash = pubKeyHash else {
                continue
            }
            let certAgrp = certRow[kSecAttrAccessGroup as String] as? String

            for privRow in privateKeys {
                guard let privData = privRow[kSecValueData as String] as? Data else {
                    continue
                }
                let keyLabel = privRow[kSecAttrApplicationLabel as String] as? Data
                var matchesKey = (keyLabel == certHash)
                if !matchesKey,
                   let keyType = (privRow[kSecAttrKeyType as String] ?? privRow["type"]) as? String {
                    let keyAttrs: [CFString: Any] = [
                        kSecAttrKeyType: keyType,
                        kSecAttrKeyClass: kSecAttrKeyClassPrivate
                    ]
                    if let secPriv = SecKeyCreateWithData(privData as CFData, keyAttrs as CFDictionary, nil),
                       let secPub = SecKeyCopyPublicKey(secPriv),
                       let pubExt = SecKeyCopyExternalRepresentation(secPub, nil) as Data? {
                        matchesKey = (Data(Insecure.SHA1.hash(data: pubExt)) == certHash)
                    }
                }
                guard matchesKey else {
                    continue
                }
                let keyAgrp = privRow[kSecAttrAccessGroup as String] as? String
                if let certAgrp, let keyAgrp, certAgrp != keyAgrp {
                    continue
                }

                let synth = NSMutableDictionary(dictionary: certRow)
                synth[kSecClass as String] = kSecClassIdentity as String
                synth[kSecAttrPublicKeyHash as String] = certHash
                synth[Self.internalPrivateKeyColumn] = privData
                for (rawKey, val) in privRow {
                    guard let col = rawKey as? String,
                          idCols.contains(col),
                          col != (kSecValueData as String),
                          col != (kSecValuePersistentRef as String),
                          synth[col] == nil else {
                        continue
                    }
                    synth[col] = val
                }

                if Self.synthesizedRowMatchesQuery(
                    synth,
                    normalizedQuery: normalizedQuery,
                    plan: identityPlan,
                    defaultAccessGroup: defaultAccessGroup
                ) {
                    results.append(synth)
                    break
                }
            }
        }
        return errSecSuccess
    }

    private static func synthesizedRowMatchesQuery(
        _ row: NSDictionary,
        normalizedQuery: NSDictionary,
        plan: FilterPlan,
        defaultAccessGroup: String?
    ) -> Bool {
        for (rawKey, attr) in normalizedQuery {
            guard let key = rawKey as? String else { return false }
            if queryMetaKeys.contains(key) || key == (kSecValueData as String) {
                continue
            }
            if key == (kSecAttrSynchronizable as String) {
                if (attr as? String) == (kSecAttrSynchronizableAny as String) {
                    continue
                }
                if let expected = boolValue(from: attr) {
                    let actual = row[key].flatMap { boolValue(from: $0) } ?? false
                    if actual != expected { return false }
                }
                continue
            }
            if key == (kSecAttrAccessGroup as String),
               let expected = attr as? String,
               let defGroup = defaultAccessGroup,
               expected == defGroup {
                let actual = row[key] as? String
                if actual != nil && actual != expected { return false }
                continue
            }
            if !valuesEqual(row[key], attr) {
                return false
            }
        }
        return rowMatchesPostFilters(row, plan: plan)
    }

    private func prepareInsert(_ attributes: NSDictionary) -> (status: OSStatus, prepared: PreparedInsert?) {
        let paramStatus = Self.validateQueryParameters(attributes)
        guard paramStatus == errSecSuccess else {
            return (paramStatus, nil)
        }
        if let rawToken = attributes[kSecAttrTokenID as String] as? String,
           rawToken == (kSecAttrTokenIDSecureEnclave as String),
           attributes[Self.internalTokenIDColumn] == nil,
           attributes[kSecValueData] != nil {
            return (errSecParam, nil)
        }

        let effectiveDefaultAccessGroup = currentDefaultAccessGroup()
        let normalized = Self.normalizeAttributes(
            attributes,
            forPersistence: true,
            populateCertMetadataFromData: true
        )
        if normalized[Self.internalInvalidQueryKey] != nil {
            return (errSecParam, nil)
        }
        guard let tableName = normalized[kSecClass] as? String,
              let primaryColumns = PlayedAppleDBConstants.primaries[tableName as CFString],
              let secondaryColumns = PlayedAppleDBConstants.attributes[tableName as CFString] else {
            return (errSecParam, nil)
        }

        let syncKey = kSecAttrSynchronizable as String
        if let rawSync = normalized[syncKey], let boolSync = Self.boolValue(from: rawSync) {
            normalized[syncKey] = (boolSync ? true : false) as CFBoolean
        } else {
            normalized[syncKey] = false as CFBoolean
        }
        let agrpKey = kSecAttrAccessGroup as String
        if normalized[agrpKey] == nil, let defGroup = effectiveDefaultAccessGroup {
            normalized[agrpKey] = defGroup
        }

        let now = Date()
        let cdatKey = kSecAttrCreationDate as String
        let mdatKey = kSecAttrModificationDate as String
        if normalized[cdatKey] == nil {
            normalized[cdatKey] = now
        }
        if normalized[mdatKey] == nil {
            normalized[mdatKey] = now
        }
        let pRefKey = kSecValuePersistentRef as String
        let needsGeneratedPersistentRef = (normalized[pRefKey] == nil)

        var columnsQuery = primaryColumns.map { "\($0)" }
        columnsQuery.append(contentsOf: secondaryColumns.compactMap { col in
            guard let val = normalized[col],
                  val is NSNull || Self.isEncodableValue(val) else {
                return nil
            }
            return "\(col)"
        })
        columnsQuery.append(contentsOf: PlayedAppleDBConstants.values.compactMap { col in
            let colStr = col as String
            guard colStr != (kSecValueRef as String),
                  let val = normalized[col],
                  val is NSNull || Self.isEncodableValue(val) else {
                return nil
            }
            return colStr
        })
        if tableName == (kSecClassIdentity as String),
           normalized[Self.internalPrivateKeyColumn] is Data {
            columnsQuery.append(Self.internalPrivateKeyColumn)
        }
        if tableName == (kSecClassKey as String),
           normalized[Self.internalTokenIDColumn] is String {
            columnsQuery.append(Self.internalTokenIDColumn)
        }

        let insertValues: [CFTypeRef] = columnsQuery.map { col in
            guard let val = normalized[col],
                  val is NSNull || Self.isEncodableValue(val) else {
                return NSNull()
            }
            return val as CFTypeRef
        }
        let insertColumns = columnsQuery.joined(separator: ", ")
        let insertPlaceholders = Array(repeating: "?", count: insertValues.count).joined(separator: ", ")
        let insertQuery = "INSERT INTO \(tableName) (\(insertColumns)) VALUES (\(insertPlaceholders))"

        var primaryClauses: [String] = []
        var primaryBindVals: [CFTypeRef] = []
        var hasNullPrimary = false
        var usesDefaultAccessGroup = false
        for col in primaryColumns {
            if let val = normalized[col], !(val is NSNull), Self.isEncodableValue(val) {
                if (col as String) == "agrp",
                   let defGroup = effectiveDefaultAccessGroup,
                   (val as? String) == defGroup {
                    usesDefaultAccessGroup = true
                    primaryClauses.append("(agrp = ? OR agrp IS NULL)")
                    primaryBindVals.append(val as CFTypeRef)
                } else {
                    primaryClauses.append("\(col) = ?")
                    primaryBindVals.append(val as CFTypeRef)
                }
            } else {
                hasNullPrimary = true
                primaryClauses.append("\(col) IS NULL")
            }
        }
        let dupCheckSQL = "SELECT 1 FROM \(tableName) WHERE \(primaryClauses.joined(separator: " AND ")) LIMIT 1"

        let newDict = NSMutableDictionary(capacity: columnsQuery.count + 1)
        newDict[kSecClass as String] = tableName
        for column in columnsQuery {
            if let val = normalized[column], !(val is NSNull) {
                newDict[column] = val
            }
        }

        return (
            errSecSuccess,
            PreparedInsert(
                tableName: tableName,
                primaryColumns: primaryColumns,
                columns: columnsQuery,
                values: insertValues,
                insertQuery: insertQuery,
                dupCheckSQL: dupCheckSQL,
                primaryBindVals: primaryBindVals,
                hasNullPrimary: hasNullPrimary,
                usesDefaultAccessGroup: usesDefaultAccessGroup,
                needsGeneratedPersistentRef: needsGeneratedPersistentRef,
                resultDict: newDict
            )
        )
    }

    private func executePreparedInsertInTransaction(
        _ prep: PreparedInsert,
        sqlite3DB: OpaquePointer,
        encryptionKey: SymmetricKey
    ) -> OSStatus {
        if prep.hasNullPrimary || prep.usesDefaultAccessGroup {
            if let dupStmt = preparedStatement(for: prep.dupCheckSQL, in: sqlite3DB) {
                let bound = bindValues(prep.primaryBindVals, to: dupStmt, in: sqlite3DB, context: "check duplicate")
                let stepRc = bound ? sqlite3_step(dupStmt) : SQLITE_ERROR
                sqlite3_reset(dupStmt)
                if !bound || (stepRc != SQLITE_ROW && stepRc != SQLITE_DONE) {
                    return errSecIO
                }
                if stepRc == SQLITE_ROW {
                    return errSecDuplicateItem
                }
            } else {
                return errSecIO
            }
        }

        guard let stmt = preparedStatement(for: prep.insertQuery, in: sqlite3DB) else {
            let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
            PlayKeychain.debugLogger("Failed query \(prep.insertQuery)")
            PlayKeychain.debugLogger("Failed to make query: \(errorMessage)")
            return errSecIO
        }

        let boundInsert = bindValues(
            prep.values,
            columns: prep.columns,
            encryptionKey: encryptionKey,
            to: stmt,
            in: sqlite3DB,
            context: "insert into"
        )
        guard boundInsert else {
            sqlite3_reset(stmt)
            return errSecIO
        }

        let stepRc = sqlite3_step(stmt)
        let errCode = sqlite3_errcode(sqlite3DB)
        sqlite3_reset(stmt)
        guard stepRc == SQLITE_DONE else {
            if errCode == SQLITE_CONSTRAINT || stepRc == SQLITE_CONSTRAINT {
                return errSecDuplicateItem
            }
            PlayKeychain.debugLogger("Insert failed: \(String(cString: sqlite3_errmsg(sqlite3DB)))")
            return errSecIO
        }

        if prep.needsGeneratedPersistentRef {
            let pRefKey = kSecValuePersistentRef as String
            let rowID = sqlite3_last_insert_rowid(sqlite3DB)
            let generatedRef = Self.makePersistentRef(tableName: prep.tableName, rowID: rowID)
            let refSQL = "UPDATE \(prep.tableName) SET \(pRefKey) = ? WHERE rowid = ?"
            guard let refStmt = preparedStatement(for: refSQL, in: sqlite3DB) else {
                return errSecIO
            }
            defer { sqlite3_reset(refStmt) }
            guard encodeData(stmt: refStmt, index: 1, value: generatedRef as CFData),
                  sqlite3_bind_int64(refStmt, 2, rowID) == SQLITE_OK,
                  sqlite3_step(refStmt) == SQLITE_DONE else {
                return errSecIO
            }
            prep.resultDict[pRefKey] = generatedRef
        }
        return errSecSuccess
    }

    func insertWithStatus(_ attributes: NSDictionary) -> (status: OSStatus, item: NSMutableDictionary?) {
        let (batchStatus, items) = insertBatchWithStatus([attributes])
        return (batchStatus, items?.first)
    }

    func insertBatchWithStatus(_ items: [NSDictionary]) -> (status: OSStatus, items: [NSMutableDictionary]?) {
        guard !items.isEmpty else {
            return (errSecParam, nil)
        }
        var preparedItems: [PreparedInsert] = []
        preparedItems.reserveCapacity(items.count)
        for raw in items {
            let (prepStatus, prep) = prepareInsert(raw)
            guard prepStatus == errSecSuccess, let prep else {
                return (prepStatus, nil)
            }
            preparedItems.append(prep)
        }

        var finalStatus: OSStatus = errSecIO
        let ok = usingDB { sqlite3DB, dbPath, encKey in
            guard sqlite3_exec(sqlite3DB, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                finalStatus = errSecIO
                return false
            }

            for prep in preparedItems {
                let status = executePreparedInsertInTransaction(
                    prep,
                    sqlite3DB: sqlite3DB,
                    encryptionKey: encKey
                )
                guard status == errSecSuccess else {
                    _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                    finalStatus = status
                    return false
                }
            }

            guard sqlite3_exec(sqlite3DB, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                finalStatus = errSecIO
                return false
            }
            hardenDatabaseSidecars(forDBPath: dbPath)
            finalStatus = errSecSuccess
            return true
        }

        return ok ? (errSecSuccess, preparedItems.map(\.resultDict)) : (finalStatus, nil)
    }

    func insert(_ attributes: NSDictionary) -> NSMutableDictionary? {
        return insertWithStatus(attributes).item
    }

    func updateMatching(_ query: NSDictionary, attributesToUpdate: NSDictionary) -> OSStatus {
        let paramStatus = Self.validateQueryParameters(query)
        guard paramStatus == errSecSuccess else {
            return paramStatus
        }
        let normalizedQuery = Self.normalizeAttributes(
            query,
            forPersistence: false,
            populateCertMetadataFromData: false
        )
        if normalizedQuery[Self.internalInvalidQueryKey] != nil {
            return errSecParam
        }
        if let predicates = normalizedQuery[Self.internalMatchItemListKey] as? [MatchItemPredicate],
           predicates.isEmpty {
            return errSecItemNotFound
        }
        let normalizedUpdates = Self.normalizeAttributes(
            attributesToUpdate,
            forPersistence: true,
            populateCertMetadataFromData: true
        )
        if normalizedUpdates[Self.internalInvalidQueryKey] != nil {
            return errSecParam
        }
        let candidateTables = Self.resolveCandidateTables(for: normalizedQuery)
        guard !candidateTables.isEmpty else {
            return errSecParam
        }

        let defaultGroup = currentDefaultAccessGroup()
        var finalStatus: OSStatus = errSecItemNotFound
        _ = usingDB { sqlite3DB, dbPath, encKey in
            guard sqlite3_exec(sqlite3DB, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                finalStatus = errSecIO
                return false
            }

            for tableName in candidateTables {
                guard let primaryColumns = PlayedAppleDBConstants.primaries[tableName as CFString],
                      let allowedCols = Self.allowedColumnsByTable[tableName],
                      let plan = buildFilterPlan(
                          tableName: tableName,
                          primaryColumns: primaryColumns,
                          attributes: normalizedQuery,
                          defaultAccessGroup: defaultGroup
                      ) else {
                    continue
                }

                // Refuse WHERE 1 = 1 fallback when non-meta keys were dropped or neither filter nor class exists.
                if PTPlayChainMutationFilterPolicy.shouldRejectMutation(
                    droppedNonMetaFilterKey: plan.droppedNonMetaFilterKey,
                    hasEffectiveFilter: plan.hasEffectiveFilter,
                    hasExplicitSecClass: normalizedQuery[kSecClass] != nil
                ) {
                    _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                    finalStatus = errSecParam
                    return false
                }
                if plan.isGuaranteedEmpty {
                    continue
                }

                let pkNames = primaryColumns.map { $0 as String }
                let selectRowIDsSQL: String
                if plan.needsPostFetchFilter {
                    selectRowIDsSQL = "SELECT rowid, * FROM \(tableName) WHERE \(plan.clause)"
                } else {
                    let pkSelect = pkNames.joined(separator: ", ")
                    selectRowIDsSQL = "SELECT rowid, \(pkSelect) FROM \(tableName) WHERE \(plan.clause)"
                }

                var matchedRows: [(rowID: Int64, pkValues: [CFTypeRef?])] = []
                do {
                    guard let selectStmt = preparedStatement(for: selectRowIDsSQL, in: sqlite3DB) else {
                        let errMsg = String(cString: sqlite3_errmsg(sqlite3DB))
                        PlayKeychain.debugLogger("Failed query \(selectRowIDsSQL): \(errMsg)")
                        _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                        finalStatus = errSecIO
                        return false
                    }
                    defer { sqlite3_reset(selectStmt) }

                    let selCtx = "select for update"
                    guard bindValues(plan.values, to: selectStmt, in: sqlite3DB, context: selCtx) else {
                        _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                        finalStatus = errSecIO
                        return false
                    }

                    let colCount = sqlite3_column_count(selectStmt)
                    var colNames: [String] = []
                    colNames.reserveCapacity(Int(colCount))
                    for idx in 0..<colCount {
                        colNames.append(String(cString: sqlite3_column_name(selectStmt, idx)))
                    }

                    var stepRc: Int32 = SQLITE_DONE
                    while true {
                        stepRc = sqlite3_step(selectStmt)
                        guard stepRc == SQLITE_ROW else { break }
                        let rowID = sqlite3_column_int64(selectStmt, 0)
                        if plan.needsPostFetchFilter {
                            let row = NSMutableDictionary(capacity: Int(colCount))
                            for idx in 1..<Int(colCount) {
                                if let val = decodeData(
                                    stmt: selectStmt,
                                    index: Int32(idx),
                                    columnName: colNames[idx],
                                    encryptionKey: encKey
                                ) {
                                    row[colNames[idx]] = val
                                }
                            }
                            if !Self.rowMatchesPostFilters(row, plan: plan) {
                                continue
                            }
                            let pks: [CFTypeRef?] = pkNames.map { row[$0].map { $0 as CFTypeRef } }
                            matchedRows.append((rowID: rowID, pkValues: pks))
                        } else {
                            var pks: [CFTypeRef?] = []
                            pks.reserveCapacity(pkNames.count)
                            for idx in 0..<pkNames.count {
                                pks.append(
                                    decodeData(
                                        stmt: selectStmt,
                                        index: Int32(idx + 1),
                                        columnName: pkNames[idx],
                                        encryptionKey: encKey
                                    )
                                )
                            }
                            matchedRows.append((rowID: rowID, pkValues: pks))
                        }
                    }
                    guard stepRc == SQLITE_DONE else {
                        _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                        finalStatus = errSecIO
                        return false
                    }
                }

                guard !matchedRows.isEmpty else {
                    continue
                }

                var updateCols: [String] = []
                var updateVals: [CFTypeRef] = []
                var updateMap: [String: CFTypeRef] = [:]
                for (rawKey, val) in normalizedUpdates {
                    guard let col = rawKey as? String,
                          allowedCols.contains(col),
                          !Self.nonUpdatableKeys.contains(col),
                          PTPlayChainKeyUpdatePolicy.isUpdatableColumn(
                              col,
                              internalTokenIDColumn: Self.internalTokenIDColumn
                          ) else {
                        continue
                    }
                    if col == Self.internalPrivateKeyColumn && tableName != (kSecClassIdentity as String) {
                        continue
                    }
                    if col == (kSecAttrSynchronizable as String) {
                        if (val as? String) == (kSecAttrSynchronizableAny as String) {
                            continue
                        }
                        if let boolVal = Self.boolValue(from: val) {
                            let cfBool: CFTypeRef = (boolVal ? true : false) as CFBoolean
                            updateCols.append(col)
                            updateVals.append(cfBool)
                            updateMap[col] = cfBool
                        }
                        continue
                    }
                    if val is NSNull {
                        let nullRef = NSNull() as CFTypeRef
                        updateCols.append(col)
                        updateVals.append(nullRef)
                        updateMap[col] = nullRef
                    } else if Self.isEncodableValue(val) {
                        let cfVal = val as CFTypeRef
                        updateCols.append(col)
                        updateVals.append(cfVal)
                        updateMap[col] = cfVal
                    }
                }

                let mdatKey = kSecAttrModificationDate as String
                if allowedCols.contains(mdatKey), updateMap[mdatKey] == nil {
                    let nowRef = Date() as CFTypeRef
                    updateCols.append(mdatKey)
                    updateVals.append(nowRef)
                    updateMap[mdatKey] = nowRef
                }

                if updateCols.isEmpty {
                    guard sqlite3_exec(sqlite3DB, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                        _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                        finalStatus = errSecIO
                        return false
                    }
                    finalStatus = errSecSuccess
                    return true
                }

                let anyPKUpdated = pkNames.contains { updateMap[$0] != nil }
                let setClause = updateCols.map { "\($0) = ?" }.joined(separator: ", ")
                let updateSQL = "UPDATE \(tableName) SET \(setClause) WHERE rowid = ?"
                let rowIDParamIndex = Int32(updateVals.count + 1)

                for (rowID, currentPKs) in matchedRows {
                    if anyPKUpdated {
                        let defGroup = currentDefaultAccessGroup()
                        var dupClauses: [String] = []
                        var dupVals: [CFTypeRef] = []
                        for (idx, pkCol) in pkNames.enumerated() {
                            let effectiveVal: CFTypeRef?
                            if let updatedVal = updateMap[pkCol] {
                                effectiveVal = (updatedVal is NSNull) ? nil : updatedVal
                            } else {
                                effectiveVal = currentPKs[idx]
                            }
                            if let val = effectiveVal {
                                if pkCol == "agrp", let defGroup, (val as? String) == defGroup {
                                    dupClauses.append("(agrp = ? OR agrp IS NULL)")
                                    dupVals.append(val)
                                } else {
                                    dupClauses.append("\(pkCol) = ?")
                                    dupVals.append(val)
                                }
                            } else {
                                dupClauses.append("\(pkCol) IS NULL")
                            }
                        }
                        let dupFilter = dupClauses.joined(separator: " AND ")
                        let dupCheckSQL = "SELECT 1 FROM \(tableName) WHERE \(dupFilter) AND rowid != ? LIMIT 1"
                        var hasCollision = false
                        do {
                            guard let dupStmt = preparedStatement(for: dupCheckSQL, in: sqlite3DB) else {
                                _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                                finalStatus = errSecIO
                                return false
                            }
                            defer { sqlite3_reset(dupStmt) }
                            guard bindValues(dupVals, to: dupStmt, in: sqlite3DB, context: "check update duplicate"),
                                  sqlite3_bind_int64(dupStmt, Int32(dupVals.count + 1), rowID) == SQLITE_OK else {
                                _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                                finalStatus = errSecIO
                                return false
                            }
                            let dupRc = sqlite3_step(dupStmt)
                            if dupRc != SQLITE_ROW && dupRc != SQLITE_DONE {
                                _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                                finalStatus = errSecIO
                                return false
                            }
                            hasCollision = (dupRc == SQLITE_ROW)
                        }
                        if hasCollision {
                            _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                            finalStatus = errSecDuplicateItem
                            return false
                        }
                    }

                    do {
                        guard let updStmt = preparedStatement(for: updateSQL, in: sqlite3DB) else {
                            _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                            finalStatus = errSecIO
                            return false
                        }
                        defer { sqlite3_reset(updStmt) }
                        guard bindValues(
                            updateVals,
                            columns: updateCols,
                            encryptionKey: encKey,
                            to: updStmt,
                            in: sqlite3DB,
                            context: "update into"
                        ),
                              sqlite3_bind_int64(updStmt, rowIDParamIndex, rowID) == SQLITE_OK else {
                            _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                            finalStatus = errSecIO
                            return false
                        }
                        let rc = sqlite3_step(updStmt)
                        if rc != SQLITE_DONE {
                            let errCode = sqlite3_errcode(sqlite3DB)
                            _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                            finalStatus = (rc == SQLITE_CONSTRAINT || errCode == SQLITE_CONSTRAINT)
                                ? errSecDuplicateItem
                                : errSecIO
                            return false
                        }
                    }
                }

                guard sqlite3_exec(sqlite3DB, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                    _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                    finalStatus = errSecIO
                    return false
                }
                hardenDatabaseSidecars(forDBPath: dbPath)
                finalStatus = errSecSuccess
                return true
            }

            _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
            finalStatus = errSecItemNotFound
            return false
        }
        return finalStatus
    }

    func update(_ attributes: NSDictionary) -> Bool {
        return updateMatching(attributes, attributesToUpdate: attributes) == errSecSuccess
    }

    func deleteMatching(_ attributes: NSDictionary) -> OSStatus {
        let paramStatus = Self.validateQueryParameters(attributes)
        guard paramStatus == errSecSuccess else {
            return paramStatus
        }
        let normalized = Self.normalizeAttributes(
            attributes,
            forPersistence: false,
            populateCertMetadataFromData: false
        )
        if normalized[Self.internalInvalidQueryKey] != nil {
            return errSecParam
        }
        if let predicates = normalized[Self.internalMatchItemListKey] as? [MatchItemPredicate],
           predicates.isEmpty {
            return errSecItemNotFound
        }
        let candidateTables = Self.resolveCandidateTables(for: normalized)
        guard !candidateTables.isEmpty else {
            return errSecParam
        }

        let matchLimitObj = normalized[kSecMatchLimit]
        let explicitDeleteLimit: Int64?
        if (matchLimitObj as? String) == (kSecMatchLimitOne as String) {
            explicitDeleteLimit = 1
        } else if (matchLimitObj as? String) == (kSecMatchLimitAll as String) {
            explicitDeleteLimit = nil
        } else if let num = matchLimitObj as? NSNumber {
            explicitDeleteLimit = max(1, num.int64Value)
        } else if matchLimitObj == nil {
            explicitDeleteLimit = nil
        } else {
            return errSecParam
        }

        let defaultGroup = currentDefaultAccessGroup()
        var finalStatus: OSStatus = errSecIO
        _ = usingDB { sqlite3DB, dbPath, encKey in
            guard sqlite3_exec(sqlite3DB, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                finalStatus = errSecIO
                return false
            }

            var totalChanged: Int64 = 0
            for tableName in candidateTables {
                if let limit = explicitDeleteLimit, totalChanged >= limit {
                    break
                }
                guard let primaryColumns = PlayedAppleDBConstants.primaries[tableName as CFString],
                      let plan = buildFilterPlan(
                          tableName: tableName,
                          primaryColumns: primaryColumns,
                          attributes: normalized,
                          defaultAccessGroup: defaultGroup
                      ) else {
                    continue
                }

                // Refuse WHERE 1 = 1 fallback when non-meta keys were dropped or neither filter nor class exists.
                if PTPlayChainMutationFilterPolicy.shouldRejectMutation(
                    droppedNonMetaFilterKey: plan.droppedNonMetaFilterKey,
                    hasEffectiveFilter: plan.hasEffectiveFilter,
                    hasExplicitSecClass: normalized[kSecClass] != nil
                ) {
                    _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                    finalStatus = errSecParam
                    return false
                }
                if plan.isGuaranteedEmpty {
                    continue
                }

                if plan.needsPostFetchFilter {
                    let selectSQL = "SELECT rowid, * FROM \(tableName) WHERE \(plan.clause)"
                    var rowIDsToDelete: [Int64] = []
                    do {
                        guard let selStmt = preparedStatement(for: selectSQL, in: sqlite3DB) else {
                            _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                            finalStatus = errSecIO
                            return false
                        }
                        defer { sqlite3_reset(selStmt) }
                        guard bindValues(plan.values, to: selStmt, in: sqlite3DB, context: "select for delete") else {
                            _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                            finalStatus = errSecIO
                            return false
                        }
                        let colCount = sqlite3_column_count(selStmt)
                        var colNames: [String] = []
                        colNames.reserveCapacity(Int(colCount))
                        for idx in 0..<colCount {
                            colNames.append(String(cString: sqlite3_column_name(selStmt, idx)))
                        }
                        var stepRc: Int32 = SQLITE_DONE
                        while true {
                            if let limit = explicitDeleteLimit,
                               totalChanged + Int64(rowIDsToDelete.count) >= limit {
                                break
                            }
                            stepRc = sqlite3_step(selStmt)
                            guard stepRc == SQLITE_ROW else { break }
                            let rowID = sqlite3_column_int64(selStmt, 0)
                            let row = NSMutableDictionary(capacity: Int(colCount))
                            for idx in 1..<Int(colCount) {
                                if let val = decodeData(
                                    stmt: selStmt,
                                    index: Int32(idx),
                                    columnName: colNames[idx],
                                    encryptionKey: encKey
                                ) {
                                    row[colNames[idx]] = val
                                }
                            }
                            if Self.rowMatchesPostFilters(row, plan: plan) {
                                rowIDsToDelete.append(rowID)
                            }
                        }
                        let hitLimit = explicitDeleteLimit.map { totalChanged + Int64(rowIDsToDelete.count) >= $0 }
                            ?? false
                        if !hitLimit && stepRc != SQLITE_DONE {
                            _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                            finalStatus = errSecIO
                            return false
                        }
                    }

                    if !rowIDsToDelete.isEmpty {
                        let delByRowSQL = "DELETE FROM \(tableName) WHERE rowid = ?"
                        guard let delStmt = preparedStatement(for: delByRowSQL, in: sqlite3DB) else {
                            _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                            finalStatus = errSecIO
                            return false
                        }
                        defer { sqlite3_reset(delStmt) }
                        for rowID in rowIDsToDelete {
                            sqlite3_reset(delStmt)
                            sqlite3_clear_bindings(delStmt)
                            guard sqlite3_bind_int64(delStmt, 1, rowID) == SQLITE_OK,
                                  sqlite3_step(delStmt) == SQLITE_DONE else {
                                _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                                finalStatus = errSecIO
                                return false
                            }
                            totalChanged += Int64(sqlite3_changes(sqlite3DB))
                        }
                    }
                    continue
                }

                let deleteQuery: String
                if let limit = explicitDeleteLimit {
                    let remaining = limit - totalChanged
                    deleteQuery = "DELETE FROM \(tableName) WHERE rowid IN "
                        + "(SELECT rowid FROM \(tableName) WHERE \(plan.clause) LIMIT \(remaining))"
                } else {
                    deleteQuery = "DELETE FROM \(tableName) WHERE \(plan.clause)"
                }

                guard let stmt = preparedStatement(for: deleteQuery, in: sqlite3DB) else {
                    let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                    PlayKeychain.debugLogger("Failed query \(deleteQuery)")
                    PlayKeychain.debugLogger("Failed to delete items from db table: \(errorMessage)")
                    _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                    finalStatus = errSecIO
                    return false
                }
                defer { sqlite3_reset(stmt) }

                guard bindValues(plan.values, to: stmt, in: sqlite3DB, context: "delete from") else {
                    _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                    finalStatus = errSecIO
                    return false
                }

                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                    finalStatus = errSecIO
                    return false
                }

                totalChanged += Int64(sqlite3_changes(sqlite3DB))
            }

            guard sqlite3_exec(sqlite3DB, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                finalStatus = errSecIO
                return false
            }
            if totalChanged > 0 {
                hardenDatabaseSidecars(forDBPath: dbPath)
            }
            finalStatus = (totalChanged > 0) ? errSecSuccess : errSecItemNotFound
            return totalChanged > 0
        }
        return finalStatus
    }

    func delete(_ attributes: NSDictionary) -> Bool {
        return deleteMatching(attributes) == errSecSuccess
    }

    private func ensureSchema(
        _ sqlite3DB: OpaquePointer,
        dbPath: String,
        encryptionKey: SymmetricKey
    ) -> Bool {
        _ = PlayedAppleDBBackup.backupIfNeeded(
            sourceDB: sqlite3DB,
            dbPath: dbPath,
            targetVersion: dbVersion
        ) { msg in
            PlayKeychain.debugLogger(msg)
        }

        guard sqlite3_exec(sqlite3DB, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
            PlayKeychain.debugLogger("Failed to start schema transaction: \(errorMessage)")
            return false
        }

        for (key, value) in PlayedAppleDBConstants.primaries {
            let tableName = key as String
            var columns: [String] = value.map { $0 as String }
            if let attrs = PlayedAppleDBConstants.attributes[key] {
                columns.append(contentsOf: attrs.map { $0 as String })
            }
            columns.append(contentsOf: PlayedAppleDBConstants.values.map { $0 as String })
            if tableName == (kSecClassIdentity as String) {
                columns.append(Self.internalPrivateKeyColumn)
            }
            if tableName == (kSecClassKey as String) {
                columns.append(Self.internalTokenIDColumn)
            }
            let columnsSetting = columns.map { "\($0) TEXT" }.joined(separator: ", ")
            let primaryKeysSetting = "PRIMARY KEY (\(value.map { "\($0)" }.joined(separator: ", ")))"
            let createTableQuery = "CREATE TABLE IF NOT EXISTS \(tableName) (\(columnsSetting), \(primaryKeysSetting));"
            guard sqlite3_exec(sqlite3DB, createTableQuery, nil, nil, nil) == SQLITE_OK else {
                let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed query \(createTableQuery)")
                PlayKeychain.debugLogger("Failed to create db table: \(errorMessage)")
                _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                return false
            }

            var existingColumns = Set<String>()
            let pragmaSQL = "PRAGMA table_info(\(tableName));"
            var infoStmt: OpaquePointer?
            guard sqlite3_prepare_v2(sqlite3DB, pragmaSQL, -1, &infoStmt, nil) == SQLITE_OK,
                  let stmt = infoStmt else {
                let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed query \(pragmaSQL): \(errorMessage)")
                _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                return false
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let namePtr = sqlite3_column_text(stmt, 1) {
                    existingColumns.insert(String(cString: namePtr))
                }
            }
            sqlite3_finalize(stmt)

            let expectedColumns = (Self.allowedColumnsByTable[tableName] ?? []).sorted()
            for col in expectedColumns where !existingColumns.contains(col) {
                let alterSQL = "ALTER TABLE \(tableName) ADD COLUMN \(col) TEXT;"
                guard sqlite3_exec(sqlite3DB, alterSQL, nil, nil, nil) == SQLITE_OK else {
                    let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                    PlayKeychain.debugLogger("Failed query \(alterSQL): \(errorMessage)")
                    _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                    return false
                }
            }
        }

        let currentVersion = PlayedAppleDBBackup.queryUserVersion(sqlite3DB)
        if Int(currentVersion) < dbVersion {
            guard migrateLegacyUntaggedScalars(sqlite3DB) else {
                _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                return false
            }
            guard sqlite3_exec(sqlite3DB, "PRAGMA user_version = \(dbVersion);", nil, nil, nil) == SQLITE_OK else {
                let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed to set user_version=\(dbVersion): \(errorMessage)")
                _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                return false
            }
        }

        guard migrateLegacyPlaintextSecrets(sqlite3DB, encryptionKey: encryptionKey) else {
            _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
            return false
        }

        guard sqlite3_exec(sqlite3DB, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
            PlayKeychain.debugLogger("Failed to commit schema transaction: \(errorMessage)")
            _ = sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
            return false
        }

        hardenDatabaseSidecars(forDBPath: dbPath)
        cleanupPlaintextPreMigrationBackups(forDBPath: dbPath)
        return true
    }

    private func cleanupPlaintextPreMigrationBackups(forDBPath dbPath: String) {
        let parentDir = (dbPath as NSString).deletingLastPathComponent
        var resolvedBuf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolvedParent = Darwin.realpath(parentDir, &resolvedBuf)
            .map { String(cString: $0) } ?? parentDir
        let resolvedDBPath = (resolvedParent as NSString)
            .appendingPathComponent((dbPath as NSString).lastPathComponent)
        for legacyVer in 0..<dbVersion {
            let bakPath = PlayedAppleDBBackup.backupPath(for: resolvedDBPath, fromVersion: legacyVer)
            var st = Darwin.stat()
            if Darwin.lstat(bakPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG {
                _ = Darwin.unlink(bakPath)
            }
        }
    }

    private func isAlreadyEncryptedBlob(_ bytes: UnsafePointer<UInt8>, size: Int) -> Bool {
        let magicLen = Self.plistBlobMagic.count
        guard size > magicLen + 28 else { return false }
        for i in 0..<magicLen where bytes[i] != Self.plistBlobMagic[i] {
            return false
        }
        return bytes[magicLen] == Self.tagEncryptedData
    }

    @discardableResult
    private func migrateLegacyPlaintextSecrets(
        _ sqlite3DB: OpaquePointer,
        encryptionKey: SymmetricKey
    ) -> Bool {
        var pending: [(table: String, rowID: Int64, col: String, plaintext: Data)] = []
        let magicLen = Self.plistBlobMagic.count
        for tableName in Self.orderedTableNames {
            let targetCols = (tableName == (kSecClassIdentity as String))
                ? [kSecValueData as String, Self.internalPrivateKeyColumn]
                : [kSecValueData as String]
            let selectSQL = "SELECT rowid, \(targetCols.joined(separator: ", ")) FROM \(tableName);"
            var selectStmt: OpaquePointer?
            guard sqlite3_prepare_v2(sqlite3DB, selectSQL, -1, &selectStmt, nil) == SQLITE_OK,
                  let stmt = selectStmt else {
                continue
            }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let rowID = sqlite3_column_int64(stmt, 0)
                for (colIdx, colName) in targetCols.enumerated() {
                    let sqlIdx = Int32(colIdx + 1)
                    guard sqlite3_column_type(stmt, sqlIdx) == SQLITE_BLOB else { continue }
                    let size = Int(sqlite3_column_bytes(stmt, sqlIdx))
                    if size > 0, let rawPtr = sqlite3_column_blob(stmt, sqlIdx) {
                        let bytes = rawPtr.assumingMemoryBound(to: UInt8.self)
                        if isAlreadyEncryptedBlob(bytes, size: size) {
                            let payloadStart = magicLen + 1
                            let payloadLen = size - payloadStart
                            if Self.decryptSecretBlob(
                                bytes: bytes.advanced(by: payloadStart),
                                length: payloadLen,
                                columnName: colName,
                                key: encryptionKey
                            ) != nil {
                                continue
                            }
                        }
                    }
                    if let decoded = decodeData(
                        stmt: stmt,
                        index: sqlIdx,
                        columnName: colName,
                        encryptionKey: encryptionKey
                    ) as? Data {
                        pending.append((table: tableName, rowID: rowID, col: colName, plaintext: decoded))
                    }
                }
            }
        }

        for item in pending {
            let updateSQL = "UPDATE \(item.table) SET \(item.col) = ? WHERE rowid = ?;"
            var updStmt: OpaquePointer?
            guard sqlite3_prepare_v2(sqlite3DB, updateSQL, -1, &updStmt, nil) == SQLITE_OK,
                  let stmt = updStmt else {
                return false
            }
            defer { sqlite3_finalize(stmt) }
            guard encodeData(
                stmt: stmt,
                index: 1,
                value: item.plaintext as CFData,
                columnName: item.col,
                encryptionKey: encryptionKey
            ),
                  sqlite3_bind_int64(stmt, 2, item.rowID) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_DONE else {
                return false
            }
        }
        return true
    }

    @discardableResult
    private func migrateLegacyUntaggedScalars(_ sqlite3DB: OpaquePointer) -> Bool {
        guard sqlite3_exec(sqlite3DB, "SAVEPOINT pt_legacy_scalar_mig;", nil, nil, nil) == SQLITE_OK else {
            return false
        }
        var pendingUpdates: [(table: String, rowID: Int64, col: String, value: CFTypeRef)] = []
        let magicLen = Self.plistBlobMagic.count
        let bplistLen = Self.legacyBplistPrefix.count

        for tableName in Self.orderedTableNames {
            let scalarCols = (Self.allowedColumnsByTable[tableName] ?? [])
                .subtracting(Self.rawBinaryColumns)
                .subtracting(Self.nonFilterableKeys)
                .sorted()
            guard !scalarCols.isEmpty else { continue }

            let selectSQL = "SELECT rowid, \(scalarCols.joined(separator: ", ")) FROM \(tableName);"
            var selectStmt: OpaquePointer?
            guard sqlite3_prepare_v2(sqlite3DB, selectSQL, -1, &selectStmt, nil) == SQLITE_OK,
                  let stmt = selectStmt else {
                continue
            }
            defer { sqlite3_finalize(stmt) }

            while sqlite3_step(stmt) == SQLITE_ROW {
                let rowID = sqlite3_column_int64(stmt, 0)
                for (colIdx, colName) in scalarCols.enumerated() {
                    let sqlIdx = Int32(colIdx + 1)
                    guard sqlite3_column_type(stmt, sqlIdx) == SQLITE_BLOB else { continue }
                    let size = Int(sqlite3_column_bytes(stmt, sqlIdx))
                    guard size > magicLen + bplistLen,
                          let rawPtr = sqlite3_column_blob(stmt, sqlIdx) else {
                        continue
                    }
                    let bytes = rawPtr.assumingMemoryBound(to: UInt8.self)
                    if let legacyVal = decodeLegacyUntaggedScalar(
                        bytes: bytes,
                        size: size,
                        columnName: colName
                    ) {
                        pendingUpdates.append((table: tableName, rowID: rowID, col: colName, value: legacyVal))
                    }
                }
            }
        }

        var failed = false
        for item in pendingUpdates {
            let updateSQL = "UPDATE OR IGNORE \(item.table) SET \(item.col) = ? WHERE rowid = ?;"
            var updStmt: OpaquePointer?
            guard sqlite3_prepare_v2(sqlite3DB, updateSQL, -1, &updStmt, nil) == SQLITE_OK,
                  let stmt = updStmt else {
                failed = true
                break
            }
            defer { sqlite3_finalize(stmt) }
            if encodeData(stmt: stmt, index: 1, value: item.value),
               sqlite3_bind_int64(stmt, 2, item.rowID) == SQLITE_OK {
                let stepRc = sqlite3_step(stmt)
                if stepRc != SQLITE_DONE {
                    failed = true
                    break
                }
            } else {
                failed = true
                break
            }
        }

        if failed {
            _ = sqlite3_exec(sqlite3DB, "ROLLBACK TO SAVEPOINT pt_legacy_scalar_mig;", nil, nil, nil)
            _ = sqlite3_exec(sqlite3DB, "RELEASE SAVEPOINT pt_legacy_scalar_mig;", nil, nil, nil)
            return false
        }

        return sqlite3_exec(sqlite3DB, "RELEASE SAVEPOINT pt_legacy_scalar_mig;", nil, nil, nil) == SQLITE_OK
    }

    private func databasePathLocked() -> String {
        if let databasePathOverride {
            return databasePathOverride
        }
        let cfHome = getenv("CFFIXED_USER_HOME").flatMap { String(validatingCString: $0) }
        let home = getenv("HOME").flatMap { String(validatingCString: $0) }
        if let cached = cachedResolvedDBPath,
           cfHome == cachedEnvCFHome,
           home == cachedEnvHome {
            return cached
        }
        let bundleID = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? "Shared"
        let path = URL(fileURLWithPath: PlaySettings.resolveHostUserRoot())
            .appendingPathComponent("Library/Containers/app.makedie.MacOver")
            .appendingPathComponent("PlayChain")
            .appendingPathComponent("\(bundleID).db")
            .path
        cachedEnvCFHome = cfHome
        cachedEnvHome = home
        cachedResolvedDBPath = path
        return path
    }

    private func usingDB(_ callback: (OpaquePointer, String, SymmetricKey) -> Bool) -> Bool {
        return withDatabase(callback)
    }

    private func withDatabase(_ callback: (OpaquePointer, String, SymmetricKey) -> Bool) -> Bool {
        dbLock.withLock {
            let dbPath = databasePathLocked()
            let encKey = encryptionKeyLocked(forDBPath: dbPath)
            let prevActivePath = activeDBPathForDecryption
            activeDBPathForDecryption = dbPath
            defer { activeDBPathForDecryption = prevActivePath }
            if let existingDB = cachedDB {
                var st = Darwin.stat()
                let statOK = (Darwin.lstat(dbPath, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG)
                if cachedDBPath == dbPath &&
                    statOK &&
                    st.st_nlink > 0 &&
                    st.st_dev == cachedDBDev &&
                    st.st_ino == cachedDBIno {
                    return callback(existingDB, dbPath, encKey)
                }
                closeDatabaseLocked()
            }

            guard let sqlite3DB = openDatabase(atPath: dbPath, encryptionKey: encKey) else { return false }
            cachedDB = sqlite3DB
            cachedDBPath = dbPath
            var st = Darwin.stat()
            if Darwin.lstat(dbPath, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG {
                cachedDBDev = st.st_dev
                cachedDBIno = st.st_ino
            } else {
                cachedDBDev = 0
                cachedDBIno = 0
            }
            return callback(sqlite3DB, dbPath, encKey)
        }
    }

    private func hardenRegularFileMode0600(atPath path: String) {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        var st = Darwin.stat()
        if Darwin.fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG {
            _ = Darwin.fchmod(fd, mode_t(0o600))
        }
    }

    private func hardenDatabaseSidecars(forDBPath dbPath: String) {
        hardenRegularFileMode0600(atPath: dbPath)
        hardenRegularFileMode0600(atPath: "\(dbPath)-wal")
        hardenRegularFileMode0600(atPath: "\(dbPath)-shm")
        hardenRegularFileMode0600(atPath: "\(dbPath)-journal")
    }

    private func openDatabase(atPath dbPath: String, encryptionKey: SymmetricKey) -> OpaquePointer? {
        var sqlite3DB: OpaquePointer?
        let playChainDir = (dbPath as NSString).deletingLastPathComponent
        var dirSt = Darwin.stat()
        if Darwin.lstat(playChainDir, &dirSt) == 0 {
            guard (dirSt.st_mode & S_IFMT) == S_IFDIR else {
                PlayKeychain.debugLogger("Refusing non-directory PlayChain path")
                return nil
            }
            if dirSt.st_uid == Darwin.geteuid() {
                _ = Darwin.chmod(playChainDir, mode_t(0o700))
            }
        } else {
            try? FileManager.default.createDirectory(
                atPath: playChainDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            if Darwin.lstat(playChainDir, &dirSt) == 0, (dirSt.st_mode & S_IFMT) == S_IFDIR {
                _ = Darwin.chmod(playChainDir, mode_t(0o700))
            }
        }

        // Canonicalize OS-level ancestor symlinks via Darwin.realpath (e.g. /var -> /private/var)
        // on the already-verified non-symlink PlayChain directory so SQLITE_OPEN_NOFOLLOW succeeds
        // while still rejecting any symlink at the leaf database file.
        var resolvedBuf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolvedPlayChainDir = Darwin.realpath(playChainDir, &resolvedBuf)
            .map { String(cString: $0) } ?? playChainDir
        let resolvedDBPath = (resolvedPlayChainDir as NSString)
            .appendingPathComponent((dbPath as NSString).lastPathComponent)

        // Pre-open with O_NOFOLLOW and 0600 permissions to prevent symlink redirection and 0644 creation.
        let preFD = Darwin.open(resolvedDBPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard preFD >= 0 else {
            PlayKeychain.debugLogger("Refused to open DB path safely (errno=\(errno))")
            return nil
        }
        var fileSt = Darwin.stat()
        let isRegFile = (Darwin.fstat(preFD, &fileSt) == 0 && (fileSt.st_mode & S_IFMT) == S_IFREG)
        if isRegFile {
            _ = Darwin.fchmod(preFD, mode_t(0o600))
        }
        Darwin.close(preFD)
        guard isRegFile else {
            PlayKeychain.debugLogger("Refused non-regular DB file")
            return nil
        }

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(resolvedDBPath, &sqlite3DB, flags, nil) == SQLITE_OK,
              let db = sqlite3DB else {
            if let sqlite3DB = sqlite3DB {
                sqlite3_close_v2(sqlite3DB)
            }
            PlayKeychain.debugLogger("Failed to connect to DB")
            return nil
        }

        let pragmas = "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; "
            + "PRAGMA busy_timeout=5000; PRAGMA temp_store=MEMORY;"
        if sqlite3_exec(db, pragmas, nil, nil, nil) != SQLITE_OK {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            PlayKeychain.debugLogger("Failed to configure SQLite pragmas: \(errorMessage)")
        }
        hardenDatabaseSidecars(forDBPath: dbPath)

        guard ensureSchema(db, dbPath: dbPath, encryptionKey: encryptionKey) else {
            sqlite3_close_v2(db)
            return nil
        }

        return db
    }

    private func bindBlob(
        _ data: Data,
        to stmt: OpaquePointer,
        index: Int32,
        transient: sqlite3_destructor_type
    ) -> Int32 {
        if data.isEmpty {
            return sqlite3_bind_zeroblob(stmt, index, 0)
        }
        return data.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(stmt, index, rawBuffer.baseAddress, Int32(rawBuffer.count), transient)
        }
    }

    private func bindTaggedFixed64(_ tag: UInt8, value: UInt64, to stmt: OpaquePointer, index: Int32,
                                   transient: sqlite3_destructor_type) -> Int32 {
        let magicLen = Self.plistBlobMagic.count
        var stackBuf = [UInt8](repeating: 0, count: magicLen + 1 + 8)
        for i in 0..<magicLen {
            stackBuf[i] = Self.plistBlobMagic[i]
        }
        stackBuf[magicLen] = tag
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { src in
            for i in 0..<8 {
                stackBuf[magicLen + 1 + i] = src[i]
            }
        }
        return stackBuf.withUnsafeBytes { rawBuf in
            sqlite3_bind_blob(stmt, index, rawBuf.baseAddress, Int32(rawBuf.count), transient)
        }
    }

    private func encodeData(
        stmt: OpaquePointer,
        index: Int32,
        value: CFTypeRef,
        columnName: String? = nil,
        encryptionKey: SymmetricKey? = nil
    ) -> Bool {
        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var result = SQLITE_FAIL
        let typeID = CFGetTypeID(value)
        switch typeID {
        case CFStringGetTypeID():
            guard let string = value as? String else { return false }
            result = sqlite3_bind_text(stmt, index, string, -1, sqliteTransient)
        case CFDataGetTypeID():
            guard let data = value as? Data else { return false }
            if let col = columnName, Self.encryptedColumns.contains(col), let key = encryptionKey {
                guard let encrypted = Self.encryptSecretBlob(data, columnName: col, key: key) else {
                    return false
                }
                result = bindBlob(encrypted, to: stmt, index: index, transient: sqliteTransient)
            } else if data.starts(with: Self.plistBlobMagic) {
                var payload = Data(capacity: Self.plistBlobMagic.count + 1 + data.count)
                payload.append(contentsOf: Self.plistBlobMagic)
                payload.append(Self.tagEscapedRawData)
                payload.append(data)
                result = bindBlob(payload, to: stmt, index: index, transient: sqliteTransient)
            } else {
                result = bindBlob(data, to: stmt, index: index, transient: sqliteTransient)
            }
        case CFBooleanGetTypeID():
            let boolVal = CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
            let magicLen = Self.plistBlobMagic.count
            var stackBuf = [UInt8](repeating: 0, count: magicLen + 1)
            for i in 0..<magicLen {
                stackBuf[i] = Self.plistBlobMagic[i]
            }
            stackBuf[magicLen] = boolVal ? Self.tagBoolTrue : Self.tagBoolFalse
            result = stackBuf.withUnsafeBytes { rawBuf in
                sqlite3_bind_blob(stmt, index, rawBuf.baseAddress, Int32(rawBuf.count), sqliteTransient)
            }
        case CFNumberGetTypeID():
            let numRef = unsafeDowncast(value, to: CFNumber.self)
            if !CFNumberIsFloatType(numRef) {
                var intVal: Int64 = 0
                if CFNumberGetValue(numRef, .sInt64Type, &intVal),
                   NSNumber(value: intVal) == (value as? NSNumber) {
                    result = bindTaggedFixed64(
                        Self.tagInt64,
                        value: UInt64(bitPattern: intVal),
                        to: stmt,
                        index: index,
                        transient: sqliteTransient
                    )
                    break
                }
            } else {
                var dblVal: Double = 0
                if CFNumberGetValue(numRef, .float64Type, &dblVal) {
                    result = bindTaggedFixed64(
                        Self.tagDouble,
                        value: dblVal.bitPattern,
                        to: stmt,
                        index: index,
                        transient: sqliteTransient
                    )
                    break
                }
            }
            guard let plistData = CFPropertyListCreateData(
                kCFAllocatorDefault,
                value,
                .binaryFormat_v1_0,
                0,
                nil
            )?.takeRetainedValue() else {
                PlayKeychain.debugLogger("Failed to serialize plist number type: \(typeID)")
                return false
            }
            var payload = Data(Self.plistBlobMagic)
            payload.append(Self.tagTypedPlistScalar)
            payload.append(plistData as Data)
            result = bindBlob(payload, to: stmt, index: index, transient: sqliteTransient)
        case CFDateGetTypeID():
            let dateRef = unsafeDowncast(value, to: CFDate.self)
            let absTime = CFDateGetAbsoluteTime(dateRef)
            result = bindTaggedFixed64(
                Self.tagDate,
                value: absTime.bitPattern,
                to: stmt,
                index: index,
                transient: sqliteTransient
            )
        case CFDictionaryGetTypeID(), CFArrayGetTypeID():
            if CFPropertyListIsValid(value, .binaryFormat_v1_0),
               let plistData = CFPropertyListCreateData(
                   kCFAllocatorDefault,
                   value,
                   .binaryFormat_v1_0,
                   0,
                   nil
               )?.takeRetainedValue() {
                var payload = Data(Self.plistBlobMagic)
                payload.append(Self.tagPlistContainer)
                payload.append(plistData as Data)
                result = bindBlob(payload, to: stmt, index: index, transient: sqliteTransient)
            } else {
                PlayKeychain.debugLogger("Cannot serialize non-plist container type: \(typeID)")
                return false
            }
        case CFNullGetTypeID():
            result = sqlite3_bind_null(stmt, index)
        default:
            PlayKeychain.debugLogger("Cannot encode this data type: \(typeID)")
            return false
        }

        return result == SQLITE_OK
    }

    private func decodeFixed64(_ base: UnsafePointer<UInt8>, offset: Int) -> UInt64 {
        var le: UInt64 = 0
        withUnsafeMutableBytes(of: &le) { dst in
            dst.copyBytes(from: UnsafeRawBufferPointer(start: base.advanced(by: offset), count: 8))
        }
        return UInt64(littleEndian: le)
    }

    private func decodeBinaryPlistSlice(bytes: UnsafePointer<UInt8>, length: Int) -> CFTypeRef? {
        guard length > 0,
              let subData = CFDataCreateWithBytesNoCopy(
                  kCFAllocatorDefault,
                  bytes,
                  length,
                  kCFAllocatorNull
              ),
              let plist = CFPropertyListCreateWithData(
                  kCFAllocatorDefault,
                  subData,
                  CFPropertyListMutabilityOptions().rawValue,
                  nil,
                  nil
              )?.takeRetainedValue() else {
            return nil
        }
        return plist
    }

    private func decodeLegacyUntaggedScalar(
        bytes: UnsafePointer<UInt8>,
        size: Int,
        columnName: String?
    ) -> CFTypeRef? {
        guard let col = columnName, !Self.rawBinaryColumns.contains(col) else {
            return nil
        }
        let magicLen = Self.plistBlobMagic.count
        let bplistLen = Self.legacyBplistPrefix.count
        guard size > magicLen + bplistLen else {
            return nil
        }
        for i in 0..<magicLen where bytes[i] != Self.plistBlobMagic[i] {
            return nil
        }
        for i in 0..<bplistLen where bytes[magicLen + i] != Self.legacyBplistPrefix[i] {
            return nil
        }
        guard let plist = decodeBinaryPlistSlice(bytes: bytes.advanced(by: magicLen), length: size - magicLen) else {
            return nil
        }
        let typeID = CFGetTypeID(plist)
        if Self.legacyDateColumns.contains(col) {
            return typeID == CFDateGetTypeID() ? plist : nil
        }
        if Self.legacyBoolColumns.contains(col) {
            return typeID == CFBooleanGetTypeID() ? plist : nil
        }
        if Self.legacyNumberColumns.contains(col) {
            return typeID == CFNumberGetTypeID() ? plist : nil
        }
        let isScalar = (typeID == CFBooleanGetTypeID() ||
                        typeID == CFNumberGetTypeID() ||
                        typeID == CFDateGetTypeID())
        return isScalar ? plist : nil
    }

    private func decodeData(
        stmt: OpaquePointer,
        index: Int32,
        columnName: String? = nil,
        encryptionKey: SymmetricKey? = nil
    ) -> CFTypeRef? {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_TEXT:
            guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
            let byteLen = sqlite3_column_bytes(stmt, index)
            return CFStringCreateWithBytes(
                nil,
                ptr,
                CFIndex(byteLen),
                CFStringBuiltInEncodings.UTF8.rawValue,
                false
            )
        case SQLITE_BLOB:
            let size = Int(sqlite3_column_bytes(stmt, index))
            guard size > 0, let rawPtr = sqlite3_column_blob(stmt, index) else {
                return CFDataCreate(nil, nil, 0)
            }
            let bytes = rawPtr.assumingMemoryBound(to: UInt8.self)
            let magicLen = Self.plistBlobMagic.count
            if size > magicLen {
                var matchesMagic = true
                for i in 0..<magicLen where bytes[i] != Self.plistBlobMagic[i] {
                    matchesMagic = false
                    break
                }
                if matchesMagic {
                    let tag = bytes[magicLen]
                    let payloadStart = magicLen + 1
                    let payloadLen = size - payloadStart
                    switch tag {
                    case Self.tagEscapedRawData:
                        return CFDataCreate(kCFAllocatorDefault, bytes.advanced(by: payloadStart), payloadLen)
                    case Self.tagEncryptedData:
                        guard let col = columnName,
                              let key = encryptionKey else {
                            return nil
                        }
                        if let decrypted = Self.decryptSecretBlob(
                            bytes: bytes.advanced(by: payloadStart),
                            length: payloadLen,
                            columnName: col,
                            key: key
                        ) {
                            return decrypted as CFData
                        }
                        if let activePath = activeDBPathForDecryption,
                           let fallbackKey = cachedLegacyFallbackKeys[activePath],
                           let decrypted = Self.decryptSecretBlob(
                               bytes: bytes.advanced(by: payloadStart),
                               length: payloadLen,
                               columnName: col,
                               key: fallbackKey
                           ) {
                            return decrypted as CFData
                        }
                        return nil
                    case Self.tagBoolFalse:
                        if payloadLen == 0 {
                            return kCFBooleanFalse
                        }
                    case Self.tagBoolTrue:
                        if payloadLen == 0 {
                            return kCFBooleanTrue
                        }
                    case Self.tagInt64:
                        if payloadLen == 8 {
                            let val = Int64(bitPattern: decodeFixed64(bytes, offset: payloadStart))
                            return NSNumber(value: val)
                        }
                    case Self.tagDouble:
                        if payloadLen == 8 {
                            let val = Double(bitPattern: decodeFixed64(bytes, offset: payloadStart))
                            return NSNumber(value: val)
                        }
                    case Self.tagDate:
                        if payloadLen == 8 {
                            let absTime = Double(bitPattern: decodeFixed64(bytes, offset: payloadStart))
                            return CFDateCreate(kCFAllocatorDefault, absTime)
                        }
                    case Self.tagTypedPlistScalar:
                        if let plist = decodeBinaryPlistSlice(
                            bytes: bytes.advanced(by: payloadStart),
                            length: payloadLen
                        ) {
                            let typeID = CFGetTypeID(plist)
                            if typeID == CFBooleanGetTypeID() ||
                                typeID == CFNumberGetTypeID() ||
                                typeID == CFDateGetTypeID() {
                                return plist
                            }
                        }
                        return nil
                    case Self.tagPlistContainer:
                        if let plist = decodeBinaryPlistSlice(
                            bytes: bytes.advanced(by: payloadStart),
                            length: payloadLen
                        ) {
                            let typeID = CFGetTypeID(plist)
                            if typeID == CFDictionaryGetTypeID() || typeID == CFArrayGetTypeID() {
                                return plist
                            }
                        }
                        return nil
                    default:
                        if let legacyVal = decodeLegacyUntaggedScalar(
                            bytes: bytes,
                            size: size,
                            columnName: columnName
                        ) {
                            return legacyVal
                        }
                    }
                }
            }
            return CFDataCreate(kCFAllocatorDefault, bytes, size)
        case SQLITE_NULL:
            return nil
        default:
            PlayKeychain.debugLogger("Cannot decode this data \(sqlite3_column_type(stmt, index))")
            return nil
        }
    }
}
