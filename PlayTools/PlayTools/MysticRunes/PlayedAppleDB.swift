//
//  PlayedAppleBackend.swift
//  PlayTools
//
//  Created by Ryu-ga on 2/20/24.
//

import Darwin
import Foundation
import Security
import SQLite3

class PlayKeychainDB: NSObject {
    public static let shared = PlayKeychainDB()

    private let dbLock: UnsafeMutablePointer<os_unfair_lock_s>
    private var dbVersion: Int = 2
    private var cachedDB: OpaquePointer?
    private var cachedDBPath: String?
    private var cachedDBDev: dev_t = 0
    private var cachedDBIno: ino_t = 0
    private var stmtCache: [String: OpaquePointer] = [:]
    private var cachedEnvCFHome: String?
    private var cachedEnvHome: String?
    private var cachedResolvedDBPath: String?

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
    private static let legacyBplistPrefix: [UInt8] = [0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x30, 0x30]

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

    private static let nonFilterableKeys: Set<String> = [
        kSecAttrAccessControl as String,
        kSecValueRef as String,
        kSecUseDataProtectionKeychain as String,
        internalPrivateKeyColumn
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

    override init() {
        dbLock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        dbLock.initialize(to: os_unfair_lock_s())
        super.init()
    }

    deinit {
        os_unfair_lock_lock(dbLock)
        closeDatabaseLocked()
        os_unfair_lock_unlock(dbLock)
        dbLock.deinitialize(count: 1)
        dbLock.deallocate()
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

    private static func normalizeAttributes(
        _ raw: NSDictionary,
        forPersistence: Bool,
        populateCertMetadataFromData: Bool
    ) -> NSMutableDictionary {
        let dict = NSMutableDictionary(dictionary: raw)
        if let ref = dict[kSecValueRef] {
            let cfRef = ref as CFTypeRef
            let typeID = CFGetTypeID(cfRef)
            if typeID == SecCertificateGetTypeID() {
                let cert = unsafeBitCast(cfRef, to: SecCertificate.self)
                if dict[kSecClass] == nil {
                    dict[kSecClass as String] = kSecClassCertificate
                }
                if dict[kSecValueData] == nil {
                    dict[kSecValueData as String] = SecCertificateCopyData(cert) as Data
                }
                if forPersistence {
                    populateCertificateMetadata(from: cert, into: dict)
                }
            } else if typeID == SecKeyGetTypeID() {
                let key = unsafeBitCast(cfRef, to: SecKey.self)
                if dict[kSecClass] == nil {
                    dict[kSecClass as String] = kSecClassKey
                }
                if dict[kSecValueData] == nil,
                   let extData = SecKeyCopyExternalRepresentation(key, nil) as Data? {
                    dict[kSecValueData as String] = extData
                }
                if forPersistence, PTPlayChainSecureEnclaveRegistry.isSecureEnclaveKey(key) {
                    dict[internalTokenIDColumn] = kSecAttrTokenIDSecureEnclave as String
                }
                if let keyAttrs = SecKeyCopyAttributes(key) as NSDictionary? {
                    if dict[kSecValueData] == nil, let vData = keyAttrs[kSecValueData] as? Data {
                        dict[kSecValueData as String] = vData
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
                    }
                }
            } else if typeID == SecIdentityGetTypeID() {
                let identity = unsafeBitCast(cfRef, to: SecIdentity.self)
                if dict[kSecClass] == nil {
                    dict[kSecClass as String] = kSecClassIdentity
                }
                var certRef: SecCertificate?
                if SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess, let cert = certRef {
                    if dict[kSecValueData] == nil {
                        dict[kSecValueData as String] = SecCertificateCopyData(cert) as Data
                    }
                    if forPersistence {
                        populateCertificateMetadata(from: cert, into: dict)
                    }
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
                        }
                    } else if dict[kSecValueData] == nil,
                              let privData = SecKeyCopyExternalRepresentation(privKey, nil) as Data? {
                        dict[kSecValueData as String] = privData
                    }
                }
            }
            dict.removeObject(forKey: kSecValueRef)
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

    private static func makePersistentRef(tableName: String) -> Data {
        return PTPlayChainPersistentRef.encode(tableName: tableName)
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
        return []
    }

    private func filterClauseAndValues(
        tableName: String,
        primaryColumns: [CFString],
        attributes: NSDictionary
    ) -> (clause: String, values: [CFTypeRef])? {
        guard let allowedCols = Self.allowedColumnsByTable[tableName] else {
            return nil
        }

        var clauses: [String] = []
        var values: [CFTypeRef] = []
        var seen = Set<String>()

        func appendFilter(key: String, attr: Any) {
            guard !seen.contains(key), allowedCols.contains(key) else {
                return
            }
            seen.insert(key)
            guard !Self.nonFilterableKeys.contains(key) else {
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
                }
                return
            }
            if attr is NSNull {
                clauses.append("\(key) IS NULL")
            } else if Self.isEncodableForFilter(attr) {
                clauses.append("\(key) = ?")
                values.append(attr as CFTypeRef)
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
        // Fallback: allow arbitrary valid column keys passed by string name
        for (rawKey, attr) in attributes {
            if let key = rawKey as? String {
                appendFilter(key: key, attr: attr)
            }
        }

        if clauses.isEmpty {
            return ("1 = 1", [])
        }
        return (clauses.joined(separator: " AND "), values)
    }

    private func bindValues(
        _ values: [CFTypeRef],
        to stmt: OpaquePointer,
        startingAt startIndex: Int32 = 1,
        in sqlite3DB: OpaquePointer,
        context: String
    ) -> Bool {
        for (offset, value) in values.enumerated() {
            if !encodeData(stmt: stmt, index: startIndex + Int32(offset), value: value) {
                let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed to \(context) db: \(errorMessage)")
                return false
            }
        }
        return true
    }

    func query(_ attributes: NSDictionary) -> [NSMutableDictionary]? {
        let normalized = Self.normalizeAttributes(
            attributes,
            forPersistence: false,
            populateCertMetadataFromData: false
        )
        let candidateTables = Self.resolveCandidateTables(for: normalized)
        guard !candidateTables.isEmpty else {
            return nil
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
            explicitLimit = 1
        }
        let selectLimit = (explicitLimit < 0) ? Int.max : Int(explicitLimit)

        var dictArr: [NSMutableDictionary] = []
        guard usingDB({ sqlite3DB in
            for tableName in candidateTables {
                if explicitLimit >= 0 && dictArr.count >= selectLimit {
                    break
                }
                guard let primaryColumns = PlayedAppleDBConstants.primaries[tableName as CFString],
                      let whereInfo = filterClauseAndValues(
                          tableName: tableName,
                          primaryColumns: primaryColumns,
                          attributes: normalized
                      ) else {
                    continue
                }

                let remainingLimit: Int64 = (explicitLimit < 0) ? -1 : Int64(selectLimit - dictArr.count)
                let selectQuery = "SELECT rowid, * FROM \(tableName) WHERE \(whereInfo.clause) LIMIT ?"
                var missingPersistentRefs: [(Int64, Data)] = []

                do {
                    guard let stmt = preparedStatement(for: selectQuery, in: sqlite3DB) else {
                        PlayKeychain.debugLogger("Failed query \(selectQuery)")
                        PlayKeychain.debugLogger("Failed to query to db table: \(String(cString: sqlite3_errmsg(sqlite3DB)))")
                        return false
                    }
                    defer { sqlite3_reset(stmt) }

                    guard bindValues(whereInfo.values, to: stmt, in: sqlite3DB, context: "bind query") else {
                        return false
                    }

                    let limitIndex = Int32(whereInfo.values.count + 1)
                    guard sqlite3_bind_int64(stmt, limitIndex, remainingLimit) == SQLITE_OK else {
                        PlayKeychain.debugLogger("Failed to bind query limit: \(String(cString: sqlite3_errmsg(sqlite3DB)))")
                        return false
                    }

                    let columns = sqlite3_column_count(stmt)
                    var columnNames: [String] = []
                    columnNames.reserveCapacity(Int(columns))
                    for index in 0..<columns {
                        columnNames.append(String(cString: sqlite3_column_name(stmt, index)))
                    }

                    while sqlite3_step(stmt) == SQLITE_ROW && dictArr.count < selectLimit {
                        let rowID = sqlite3_column_int64(stmt, 0)
                        let newDict = NSMutableDictionary(capacity: Int(columns) + 2)
                        newDict[kSecClass as String] = tableName
                        for index in 1..<Int(columns) {
                            if let value = decodeData(stmt: stmt, index: Int32(index), columnName: columnNames[index]) {
                                newDict[columnNames[index]] = value
                            }
                        }
                        if newDict[kSecAttrSynchronizable as String] == nil {
                            newDict[kSecAttrSynchronizable as String] = false as CFBoolean
                        }
                        if newDict[kSecValuePersistentRef as String] == nil {
                            let pRef = Self.makePersistentRef(tableName: tableName)
                            newDict[kSecValuePersistentRef as String] = pRef
                            missingPersistentRefs.append((rowID, pRef))
                        }
                        dictArr.append(newDict)
                    }
                }

                if !missingPersistentRefs.isEmpty {
                    let backfillSQL = "UPDATE \(tableName) SET \(kSecValuePersistentRef) = ? WHERE rowid = ?"
                    if let updStmt = preparedStatement(for: backfillSQL, in: sqlite3DB) {
                        defer { sqlite3_reset(updStmt) }
                        for (rowID, pRef) in missingPersistentRefs {
                            sqlite3_reset(updStmt)
                            sqlite3_clear_bindings(updStmt)
                            if encodeData(stmt: updStmt, index: 1, value: pRef as CFData),
                               sqlite3_bind_int64(updStmt, 2, rowID) == SQLITE_OK {
                                _ = sqlite3_step(updStmt)
                            }
                        }
                    }
                }
            }

            return true
        }) else { return nil }

        return dictArr
    }

    func insertWithStatus(_ attributes: NSDictionary) -> (status: OSStatus, item: NSMutableDictionary?) {
        let normalized = Self.normalizeAttributes(
            attributes,
            forPersistence: true,
            populateCertMetadataFromData: true
        )
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
        if normalized[pRefKey] == nil {
            normalized[pRefKey] = Self.makePersistentRef(tableName: tableName)
        }

        var columnsQuery = primaryColumns.map { "\($0)" }
        columnsQuery.append(contentsOf: secondaryColumns.compactMap { col in
            guard let val = normalized[col],
                  (val is NSNull || Self.isEncodableValue(val)) else {
                return nil
            }
            return "\(col)"
        })
        columnsQuery.append(contentsOf: PlayedAppleDBConstants.values.compactMap { col in
            let colStr = col as String
            guard colStr != (kSecValueRef as String),
                  let val = normalized[col],
                  (val is NSNull || Self.isEncodableValue(val)) else {
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
                  (val is NSNull || Self.isEncodableValue(val)) else {
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
        for col in primaryColumns {
            if let val = normalized[col], !(val is NSNull), Self.isEncodableValue(val) {
                primaryClauses.append("\(col) = ?")
                primaryBindVals.append(val as CFTypeRef)
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

        var finalStatus: OSStatus = errSecIO
        let ok = usingDB { sqlite3DB in
            guard sqlite3_exec(sqlite3DB, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                finalStatus = errSecIO
                return false
            }

            if hasNullPrimary {
                if let dupStmt = preparedStatement(for: dupCheckSQL, in: sqlite3DB) {
                    let bound = bindValues(primaryBindVals, to: dupStmt, in: sqlite3DB, context: "check duplicate")
                    let exists = bound && (sqlite3_step(dupStmt) == SQLITE_ROW)
                    sqlite3_reset(dupStmt)
                    if !bound {
                        sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                        finalStatus = errSecIO
                        return false
                    }
                    if exists {
                        sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                        finalStatus = errSecDuplicateItem
                        return false
                    }
                }
            }

            guard let stmt = preparedStatement(for: insertQuery, in: sqlite3DB) else {
                let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed query \(insertQuery)")
                PlayKeychain.debugLogger("Failed to make query: \(errorMessage)")
                sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                finalStatus = errSecIO
                return false
            }

            let boundInsert = bindValues(insertValues, to: stmt, in: sqlite3DB, context: "insert into")
            guard boundInsert else {
                sqlite3_reset(stmt)
                sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                finalStatus = errSecIO
                return false
            }

            let stepRc = sqlite3_step(stmt)
            let errCode = sqlite3_errcode(sqlite3DB)
            sqlite3_reset(stmt)
            if stepRc == SQLITE_DONE {
                guard sqlite3_exec(sqlite3DB, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                    sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                    finalStatus = errSecIO
                    return false
                }
                finalStatus = errSecSuccess
                return true
            }
            sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
            if errCode == SQLITE_CONSTRAINT || stepRc == SQLITE_CONSTRAINT {
                finalStatus = errSecDuplicateItem
            } else {
                PlayKeychain.debugLogger("Insert failed: \(String(cString: sqlite3_errmsg(sqlite3DB)))")
                finalStatus = errSecIO
            }
            return false
        }

        return ok ? (errSecSuccess, newDict) : (finalStatus, nil)
    }

    func insert(_ attributes: NSDictionary) -> NSMutableDictionary? {
        return insertWithStatus(attributes).item
    }

    // swiftlint:disable:next function_body_length
    func updateMatching(_ query: NSDictionary, attributesToUpdate: NSDictionary) -> OSStatus {
        let normalizedQuery = Self.normalizeAttributes(
            query,
            forPersistence: false,
            populateCertMetadataFromData: false
        )
        let normalizedUpdates = Self.normalizeAttributes(
            attributesToUpdate,
            forPersistence: true,
            populateCertMetadataFromData: true
        )
        let candidateTables = Self.resolveCandidateTables(for: normalizedQuery)
        guard !candidateTables.isEmpty else {
            return errSecParam
        }

        var finalStatus: OSStatus = errSecItemNotFound
        _ = usingDB { sqlite3DB in
            guard sqlite3_exec(sqlite3DB, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                finalStatus = errSecIO
                return false
            }

            for tableName in candidateTables {
                guard let primaryColumns = PlayedAppleDBConstants.primaries[tableName as CFString],
                      let allowedCols = Self.allowedColumnsByTable[tableName],
                      let whereInfo = filterClauseAndValues(
                          tableName: tableName,
                          primaryColumns: primaryColumns,
                          attributes: normalizedQuery
                      ) else {
                    continue
                }

                let pkNames = primaryColumns.map { $0 as String }
                let pkSelect = pkNames.joined(separator: ", ")
                let selectRowIDsSQL = "SELECT rowid, \(pkSelect) FROM \(tableName) WHERE \(whereInfo.clause)"

                var matchedRows: [(rowID: Int64, pkValues: [CFTypeRef?])] = []
                do {
                    guard let selectStmt = preparedStatement(for: selectRowIDsSQL, in: sqlite3DB) else {
                        PlayKeychain.debugLogger("Failed query \(selectRowIDsSQL): \(String(cString: sqlite3_errmsg(sqlite3DB)))")
                        sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                        finalStatus = errSecIO
                        return false
                    }
                    defer { sqlite3_reset(selectStmt) }

                    guard bindValues(whereInfo.values, to: selectStmt, in: sqlite3DB, context: "select for update") else {
                        sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                        finalStatus = errSecIO
                        return false
                    }
                    while sqlite3_step(selectStmt) == SQLITE_ROW {
                        let rowID = sqlite3_column_int64(selectStmt, 0)
                        var pks: [CFTypeRef?] = []
                        pks.reserveCapacity(pkNames.count)
                        for idx in 0..<pkNames.count {
                            pks.append(decodeData(stmt: selectStmt, index: Int32(idx + 1), columnName: pkNames[idx]))
                        }
                        matchedRows.append((rowID: rowID, pkValues: pks))
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
                          !Self.nonFilterableKeys.contains(col) else {
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
                        sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
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
                                dupClauses.append("\(pkCol) = ?")
                                dupVals.append(val)
                            } else {
                                dupClauses.append("\(pkCol) IS NULL")
                            }
                        }
                        let dupCheckSQL = "SELECT 1 FROM \(tableName) WHERE \(dupClauses.joined(separator: " AND ")) AND rowid != ? LIMIT 1"
                        var hasCollision = false
                        do {
                            guard let dupStmt = preparedStatement(for: dupCheckSQL, in: sqlite3DB) else {
                                sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                                finalStatus = errSecIO
                                return false
                            }
                            defer { sqlite3_reset(dupStmt) }
                            guard bindValues(dupVals, to: dupStmt, in: sqlite3DB, context: "check update duplicate"),
                                  sqlite3_bind_int64(dupStmt, Int32(dupVals.count + 1), rowID) == SQLITE_OK else {
                                sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                                finalStatus = errSecIO
                                return false
                            }
                            hasCollision = (sqlite3_step(dupStmt) == SQLITE_ROW)
                        }
                        if hasCollision {
                            sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                            finalStatus = errSecDuplicateItem
                            return false
                        }
                    }

                    do {
                        guard let updStmt = preparedStatement(for: updateSQL, in: sqlite3DB) else {
                            sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                            finalStatus = errSecIO
                            return false
                        }
                        defer { sqlite3_reset(updStmt) }
                        guard bindValues(updateVals, to: updStmt, in: sqlite3DB, context: "update into"),
                              sqlite3_bind_int64(updStmt, rowIDParamIndex, rowID) == SQLITE_OK else {
                            sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                            finalStatus = errSecIO
                            return false
                        }
                        let rc = sqlite3_step(updStmt)
                        if rc != SQLITE_DONE {
                            let errCode = sqlite3_errcode(sqlite3DB)
                            sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                            finalStatus = (rc == SQLITE_CONSTRAINT || errCode == SQLITE_CONSTRAINT)
                                ? errSecDuplicateItem
                                : errSecIO
                            return false
                        }
                    }
                }

                guard sqlite3_exec(sqlite3DB, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                    sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
                    finalStatus = errSecIO
                    return false
                }
                finalStatus = errSecSuccess
                return true
            }

            sqlite3_exec(sqlite3DB, "ROLLBACK", nil, nil, nil)
            finalStatus = errSecItemNotFound
            return false
        }
        return finalStatus
    }

    func update(_ attributes: NSDictionary) -> Bool {
        return updateMatching(attributes, attributesToUpdate: attributes) == errSecSuccess
    }

    func deleteMatching(_ attributes: NSDictionary) -> OSStatus {
        let normalized = Self.normalizeAttributes(
            attributes,
            forPersistence: false,
            populateCertMetadataFromData: false
        )
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
        } else {
            explicitDeleteLimit = nil
        }

        var finalStatus: OSStatus = errSecIO
        _ = usingDB { sqlite3DB in
            var totalChanged: Int64 = 0
            for tableName in candidateTables {
                if let limit = explicitDeleteLimit, totalChanged >= limit {
                    break
                }
                guard let primaryColumns = PlayedAppleDBConstants.primaries[tableName as CFString],
                      let whereInfo = filterClauseAndValues(
                          tableName: tableName,
                          primaryColumns: primaryColumns,
                          attributes: normalized
                      ) else {
                    continue
                }

                let deleteQuery: String
                if let limit = explicitDeleteLimit {
                    let remaining = limit - totalChanged
                    deleteQuery = "DELETE FROM \(tableName) WHERE rowid IN (SELECT rowid FROM \(tableName) WHERE \(whereInfo.clause) LIMIT \(remaining))"
                } else {
                    deleteQuery = "DELETE FROM \(tableName) WHERE \(whereInfo.clause)"
                }

                guard let stmt = preparedStatement(for: deleteQuery, in: sqlite3DB) else {
                    let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                    PlayKeychain.debugLogger("Failed query \(deleteQuery)")
                    PlayKeychain.debugLogger("Failed to delete items from db table: \(errorMessage)")
                    finalStatus = errSecIO
                    return false
                }
                defer { sqlite3_reset(stmt) }

                guard bindValues(whereInfo.values, to: stmt, in: sqlite3DB, context: "delete from") else {
                    finalStatus = errSecIO
                    return false
                }

                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    finalStatus = errSecIO
                    return false
                }

                totalChanged += Int64(sqlite3_changes(sqlite3DB))
            }

            finalStatus = (totalChanged > 0) ? errSecSuccess : errSecItemNotFound
            return totalChanged > 0
        }
        return finalStatus
    }

    func delete(_ attributes: NSDictionary) -> Bool {
        return deleteMatching(attributes) == errSecSuccess
    }

    private func ensureSchema(_ sqlite3DB: OpaquePointer, dbPath: String) -> Bool {
        _ = PlayedAppleDBBackup.backupIfNeeded(
            sourceDB: sqlite3DB,
            dbPath: dbPath,
            targetVersion: dbVersion
        ) { msg in
            PlayKeychain.debugLogger(msg)
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
                return false
            }

            var existingColumns = Set<String>()
            let pragmaSQL = "PRAGMA table_info(\(tableName));"
            var infoStmt: OpaquePointer?
            guard sqlite3_prepare_v2(sqlite3DB, pragmaSQL, -1, &infoStmt, nil) == SQLITE_OK,
                  let stmt = infoStmt else {
                let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed query \(pragmaSQL): \(errorMessage)")
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
                    return false
                }
            }
        }

        let currentVersion = PlayedAppleDBBackup.queryUserVersion(sqlite3DB)
        if Int(currentVersion) < dbVersion {
            guard migrateLegacyUntaggedScalars(sqlite3DB) else {
                return false
            }
            guard sqlite3_exec(sqlite3DB, "PRAGMA user_version = \(dbVersion);", nil, nil, nil) == SQLITE_OK else {
                let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed to set user_version=\(dbVersion): \(errorMessage)")
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
        let cfHome = getenv("CFFIXED_USER_HOME").flatMap { String(validatingUTF8: $0) }
        let home = getenv("HOME").flatMap { String(validatingUTF8: $0) }
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

    private func usingDB(_ callback: (OpaquePointer) -> Bool) -> Bool {
        return withDatabase(callback)
    }

    private func withDatabase(_ callback: (OpaquePointer) -> Bool) -> Bool {
        os_unfair_lock_lock(dbLock)
        defer { os_unfair_lock_unlock(dbLock) }

        let dbPath = databasePathLocked()
        if let existingDB = cachedDB {
            var st = Darwin.stat()
            let statOK = (stat(dbPath, &st) == 0)
            if cachedDBPath == dbPath &&
                statOK &&
                st.st_nlink > 0 &&
                st.st_dev == cachedDBDev &&
                st.st_ino == cachedDBIno {
                return callback(existingDB)
            }
            closeDatabaseLocked()
        }

        guard let sqlite3DB = openDatabase(atPath: dbPath) else { return false }
        cachedDB = sqlite3DB
        cachedDBPath = dbPath
        var st = Darwin.stat()
        if stat(dbPath, &st) == 0 {
            cachedDBDev = st.st_dev
            cachedDBIno = st.st_ino
        } else {
            cachedDBDev = 0
            cachedDBIno = 0
        }
        return callback(sqlite3DB)
    }

    private func openDatabase(atPath dbPath: String) -> OpaquePointer? {
        var sqlite3DB: OpaquePointer?
        let playChainDir = (dbPath as NSString).deletingLastPathComponent
        var dirSt = Darwin.stat()
        if stat(playChainDir, &dirSt) != 0 {
            try? FileManager.default.createDirectory(atPath: playChainDir, withIntermediateDirectories: true)
        }

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbPath, &sqlite3DB, flags, nil) == SQLITE_OK,
              let db = sqlite3DB else {
            if let sqlite3DB = sqlite3DB {
                sqlite3_close_v2(sqlite3DB)
            }
            PlayKeychain.debugLogger("Failed to connect to DB")
            return nil
        }

        let pragmas = "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000; PRAGMA temp_store=MEMORY;"
        if sqlite3_exec(db, pragmas, nil, nil, nil) != SQLITE_OK {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            PlayKeychain.debugLogger("Failed to configure SQLite pragmas: \(errorMessage)")
        }

        guard ensureSchema(db, dbPath: dbPath) else {
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

    private func encodeData(stmt: OpaquePointer, index: Int32, value: CFTypeRef) -> Bool {
        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var result = SQLITE_FAIL
        let typeID = CFGetTypeID(value)
        switch typeID {
        case CFStringGetTypeID():
            guard let string = value as? String else { return false }
            result = sqlite3_bind_text(stmt, index, string, -1, sqliteTransient)
        case CFDataGetTypeID():
            guard let data = value as? Data else { return false }
            if data.starts(with: Self.plistBlobMagic) {
                var payload = Data(capacity: Self.plistBlobMagic.count + 1 + data.count)
                payload.append(contentsOf: Self.plistBlobMagic)
                payload.append(Self.tagEscapedRawData)
                payload.append(data)
                result = bindBlob(payload, to: stmt, index: index, transient: sqliteTransient)
            } else {
                result = bindBlob(data, to: stmt, index: index, transient: sqliteTransient)
            }
        case CFBooleanGetTypeID():
            let boolVal = CFBooleanGetValue((value as! CFBoolean)) // swiftlint:disable:this force_cast
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
            let numRef = value as! CFNumber // swiftlint:disable:this force_cast
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
            let dateRef = value as! CFDate // swiftlint:disable:this force_cast
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

    private func decodeData(stmt: OpaquePointer, index: Int32, columnName: String? = nil) -> CFTypeRef? {
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
