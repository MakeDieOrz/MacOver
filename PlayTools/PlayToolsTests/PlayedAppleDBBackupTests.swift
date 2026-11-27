import Foundation
import Security
import SQLite3
import Testing

extension PlayToolsGlobalStateScope {
@Suite(.serialized)
final class PlayedAppleDBBackupTests {
    private let tempDir: URL

    init() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayedAppleDBBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test
    func legacyV1WalDatabaseCreatesAtomicBackupAndPreservesExistingBackup() throws {
        let dbURL = tempDir.appendingPathComponent("com.example.game.db")
        let backupURL = URL(fileURLWithPath: PlayedAppleDBBackup.backupPath(for: dbURL.path, fromVersion: 1))
        #expect(backupURL.path == "\(dbURL.path).v1.bak")
        #expect(backupURL.path.hasPrefix(dbURL.path))
        #expect(backupURL.pathExtension != "db")

        var dbPtr: OpaquePointer?
        #expect(
            sqlite3_open_v2(dbURL.path, &dbPtr, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK
        )
        let db = try #require(dbPtr)
        defer { sqlite3_close_v2(db) }

        #expect(
            sqlite3_exec(
                db,
                "PRAGMA journal_mode=WAL; CREATE TABLE genp (acct TEXT PRIMARY KEY, val TEXT);" +
                    "INSERT INTO genp (acct, val) VALUES ('alice', 'secret_v1');" +
                    "PRAGMA user_version = 1;",
                nil,
                nil,
                nil
            ) == SQLITE_OK
        )

        var logged: [String] = []
        #expect(
            PlayedAppleDBBackup.backupIfNeeded(sourceDB: db, dbPath: dbURL.path, targetVersion: 2) {
                logged.append($0)
            }
        )
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(!FileManager.default.fileExists(atPath: "\(backupURL.path).tmp"))
        #expect(!logged.isEmpty)

        // Mutate live DB to v2 and verify backup retains original v1 data
        #expect(
            sqlite3_exec(db, "UPDATE genp SET val = 'migrated_v2'; PRAGMA user_version = 2;", nil, nil, nil) ==
                SQLITE_OK
        )

        var bakPtr: OpaquePointer?
        #expect(sqlite3_open_v2(backupURL.path, &bakPtr, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        let bakDB = try #require(bakPtr)
        defer { sqlite3_close_v2(bakDB) }
        #expect(PlayedAppleDBBackup.queryUserVersion(bakDB) == 1)

        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(bakDB, "SELECT val FROM genp WHERE acct = 'alice';", -1, &stmt, nil) == SQLITE_OK)
        let prepared = try #require(stmt)
        defer { sqlite3_finalize(prepared) }
        #expect(sqlite3_step(prepared) == SQLITE_ROW)
        let restoredVal = try #require(sqlite3_column_text(prepared, 0)).withMemoryRebound(to: CChar.self, capacity: 1) {
            String(cString: $0)
        }
        #expect(restoredVal == "secret_v1")

        // Repeated backup attempt for same version must not overwrite existing .v1.bak
        #expect(PlayedAppleDBBackup.backupIfNeeded(sourceDB: db, dbPath: dbURL.path, targetVersion: 2))
    }

    @Test
    func alreadyUpgradedV2DatabaseSkipsBackup() throws {
        let dbURL = tempDir.appendingPathComponent("com.example.v2.db")
        let backupURL = URL(fileURLWithPath: PlayedAppleDBBackup.backupPath(for: dbURL.path, fromVersion: 2))

        var dbPtr: OpaquePointer?
        #expect(
            sqlite3_open_v2(dbURL.path, &dbPtr, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK
        )
        let db = try #require(dbPtr)
        defer { sqlite3_close_v2(db) }

        #expect(
            sqlite3_exec(db, "CREATE TABLE genp (acct TEXT PRIMARY KEY); PRAGMA user_version = 2;", nil, nil, nil) ==
                SQLITE_OK
        )
        #expect(PlayedAppleDBBackup.backupIfNeeded(sourceDB: db, dbPath: dbURL.path, targetVersion: 2))
        #expect(!FileManager.default.fileExists(atPath: backupURL.path))
    }

    @Test
    func opaqueBinaryPersistentRefEncodingAndLegacyDecoding() {
        let tables: [CFString] = [
            kSecClassGenericPassword,
            kSecClassInternetPassword,
            kSecClassCertificate,
            kSecClassKey,
            kSecClassIdentity
        ]
        for (idx, cls) in tables.enumerated() {
            let tableName = cls as String
            let rowID = Int64(idx + 1)
            let pRef = PTPlayChainPersistentRef.encode(tableName: tableName, rowID: rowID)
            #expect(pRef.count == 12)
            #expect(PTPlayChainPersistentRef.isPersistentRef(pRef))
            #expect(PTPlayChainPersistentRef.decodeTableName(from: pRef) == tableName)

            // Ensure iOS 12-byte format: 4-byte class tag + 8-byte little-endian rowID
            #expect(!pRef.starts(with: Data("PCPR".utf8)))
            #expect(Data(pRef.prefix(4)) == Data(tableName.utf8))
            var decodedRowID: Int64 = 0
            _ = withUnsafeMutableBytes(of: &decodedRowID) { dst in
                pRef[4..<12].copyBytes(to: dst)
            }
            #expect(Int64(littleEndian: decodedRowID) == rowID)
        }

        // Legacy 20-byte [0x8A, 0x9F, 0xC4, 0x91..0x95] binary refs remain decodable
        var legacyBinaryBytes: [UInt8] = [0x8A, 0x9F, 0xC4, 0x91]
        legacyBinaryBytes.append(contentsOf: [UInt8](repeating: 0x11, count: 16))
        let legacyBinaryRef = Data(legacyBinaryBytes)
        #expect(PTPlayChainPersistentRef.isPersistentRef(legacyBinaryRef))
        #expect(PTPlayChainPersistentRef.decodeTableName(from: legacyBinaryRef) == kSecClassGenericPassword as String)

        // Legacy PCPR1 lookup fallback remains decodable without minting PCPR1
        let legacyRef = Data("PCPR1:genp:\(UUID().uuidString)".utf8)
        #expect(PTPlayChainPersistentRef.isPersistentRef(legacyRef))
        #expect(PTPlayChainPersistentRef.decodeTableName(from: legacyRef) == kSecClassGenericPassword as String)

        // Arbitrary non-persistent-ref key payloads (including invalid zero rowID or unknown 12-byte tags) are rejected
        let random20 = Data(repeating: 0x2A, count: 20)
        #expect(!PTPlayChainPersistentRef.isPersistentRef(random20))
        #expect(PTPlayChainPersistentRef.decodeTableName(from: random20) == nil)

        var zeroRowGenp = Data("genp".utf8)
        zeroRowGenp.append(Data(repeating: 0, count: 8))
        #expect(!PTPlayChainPersistentRef.isPersistentRef(zeroRowGenp))
        #expect(PTPlayChainPersistentRef.decodeTableName(from: zeroRowGenp) == nil)

        let random12 = Data("abcd12345678".utf8)
        #expect(!PTPlayChainPersistentRef.isPersistentRef(random12))
        #expect(PTPlayChainPersistentRef.decodeTableName(from: random12) == nil)
    }

    @Test
    func accessGroupEntitlementAllowsDefaultsAndEntitledPatterns() {
        let entitlements: [String: Any] = [
            "keychain-access-groups": [
                "$(AppIdentifierPrefix)com.example.shared",
                "FAKETEAMID.com.example.legacy"
            ],
            "application-identifier": "ABCD123456.com.example.app"
        ]
        let patterns = PTPlayChainAccessGroupPolicy.expandAccessGroupPatterns(
            fromEntitlements: entitlements,
            teamID: "ABCD123456",
            bundleID: "com.example.app"
        )
        #expect(patterns.contains("ABCD123456.com.example.shared"))
        #expect(patterns.contains("ABCD123456.com.example.legacy"))
        #expect(patterns.contains("ABCD123456.com.example.app"))

        #expect(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: nil,
                allowedPatterns: patterns,
                isReadOnlyQuery: false
            ) == errSecSuccess
        )
        #expect(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: "",
                allowedPatterns: patterns,
                isReadOnlyQuery: false
            ) == errSecSuccess
        )
        #expect(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: "ABCD123456.com.example.shared",
                allowedPatterns: patterns,
                isReadOnlyQuery: false
            ) == errSecSuccess
        )
        #expect(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: "ABCD123456.com.example.anything",
                allowedPatterns: ["ABCD123456.*"],
                isReadOnlyQuery: false
            ) == errSecSuccess
        )
    }

    @Test
    func accessGroupEntitlementRejectsForeignAndInvalidGroups() {
        let patterns = ["ABCD123456.com.example.app"]
        #expect(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: "ZZZZ999999.com.evil.app",
                allowedPatterns: patterns,
                isReadOnlyQuery: false
            ) == errSecMissingEntitlement
        )
        #expect(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: "com.apple.mobilesafari",
                allowedPatterns: patterns,
                isReadOnlyQuery: true
            ) == errSecMissingEntitlement
        )
        #expect(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: kSecAttrAccessGroupToken as String,
                allowedPatterns: patterns,
                isReadOnlyQuery: true
            ) == errSecSuccess
        )
        #expect(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: kSecAttrAccessGroupToken as String,
                allowedPatterns: patterns,
                isReadOnlyQuery: false
            ) == errSecMissingEntitlement
        )
        #expect(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: 123,
                allowedPatterns: patterns,
                isReadOnlyQuery: false
            ) == errSecParam
        )
    }

    @Test
    func secureEnclaveRegistryTracksPrivateKeysOnly() throws {
        #expect(PTPlayChainSecureEnclaveRegistry.parametersRequestSecureEnclave([
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave as String
        ]))
        #expect(PTPlayChainSecureEnclaveRegistry.parametersRequestSecureEnclave([
            kSecPrivateKeyAttrs as String: [
                kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave as String
            ]
        ]))
        #expect(!PTPlayChainSecureEnclaveRegistry.parametersRequestSecureEnclave([
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom as String
        ]))

        let ecAttrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256
        ]
        let seKey = try #require(SecKeyCreateRandomKey(ecAttrs as CFDictionary, nil))
        let normalKey = try #require(SecKeyCreateRandomKey(ecAttrs as CFDictionary, nil))
        let sePubKey = try #require(SecKeyCopyPublicKey(seKey))

        PTPlayChainSecureEnclaveRegistry.markSecureEnclaveKey(seKey)
        PTPlayChainSecureEnclaveRegistry.markSecureEnclaveKey(sePubKey)

        #expect(PTPlayChainSecureEnclaveRegistry.isSecureEnclaveKey(seKey))
        #expect(!PTPlayChainSecureEnclaveRegistry.isSecureEnclaveKey(sePubKey))
        #expect(!PTPlayChainSecureEnclaveRegistry.isSecureEnclaveKey(normalKey))
    }

    @Test
    func accessGroupPolicyIncludesValidAppGroupsAndPreservesFakeTeamID() {
        let entitlements: [String: Any] = [
            "keychain-access-groups": [
                "$(AppIdentifierPrefix)com.example.shared",
                "FAKETEAMID.com.example.legacy",
                "FAKETEAMID."
            ],
            "application-identifier": "FAKETEAMID.com.example.app",
            "com.apple.security.application-groups": [
                "group.com.example.shared",
                "  group.com.example.trimmed  ",
                "group.",
                "group.*",
                "not-a-group",
                "group.com/evil",
                "group.com..evil",
                "group.has space"
            ]
        ]

        let patterns = PTPlayChainAccessGroupPolicy.expandAccessGroupPatterns(
            fromEntitlements: entitlements,
            teamID: "ABCD123456",
            bundleID: "com.example.app"
        )

        #expect(patterns.contains("ABCD123456.com.example.shared"))
        #expect(patterns.contains("ABCD123456.com.example.legacy"))
        #expect(patterns.contains("FAKETEAMID.com.example.legacy"))
        #expect(patterns.contains("ABCD123456.com.example.app"))
        #expect(patterns.contains("FAKETEAMID.com.example.app"))
        #expect(patterns.contains("group.com.example.shared"))
        #expect(patterns.contains("group.com.example.trimmed"))

        #expect(!patterns.contains("ABCD123456."))
        #expect(!patterns.contains("group."))
        #expect(!patterns.contains("group.*"))
        #expect(!patterns.contains("not-a-group"))
        #expect(!patterns.contains("group.com/evil"))
        #expect(!patterns.contains("group.com..evil"))
        #expect(!patterns.contains("group.has space"))
    }

    @Test
    func accessGroupValidationAllowsAppGroupsFakeTeamAndRejectsNSNull() {
        let patterns = [
            "ABCD123456.com.example.app",
            "FAKETEAMID.com.example.legacy",
            "group.com.example.shared"
        ]
        #expect(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: "group.com.example.shared",
                allowedPatterns: patterns,
                isReadOnlyQuery: false
            ) == errSecSuccess
        )
        #expect(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: "FAKETEAMID.com.example.legacy",
                allowedPatterns: patterns,
                isReadOnlyQuery: true
            ) == errSecSuccess
        )
        #expect(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: "group.com.other.evil",
                allowedPatterns: patterns,
                isReadOnlyQuery: false
            ) == errSecMissingEntitlement
        )
        #expect(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: NSNull(),
                allowedPatterns: patterns,
                isReadOnlyQuery: false
            ) == errSecParam
        )
        #expect(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: NSNull(),
                allowedPatterns: patterns,
                isReadOnlyQuery: true
            ) == errSecParam
        )
        #expect(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: ["group.com.example.shared"],
                allowedPatterns: patterns,
                isReadOnlyQuery: false
            ) == errSecParam
        )
    }

    @Test
    func secureEnclaveUpdatePolicyProtectsTokenIDColumn() {
        #expect(
            !PTPlayChainKeyUpdatePolicy.isUpdatableColumn(
                "pc_tokid",
                internalTokenIDColumn: "pc_tokid"
            )
        )
        #expect(
            PTPlayChainKeyUpdatePolicy.isUpdatableColumn(
                kSecAttrLabel as String,
                internalTokenIDColumn: "pc_tokid"
            )
        )
        #expect(
            PTPlayChainKeyUpdatePolicy.isUpdatableColumn(
                kSecAttrApplicationTag as String,
                internalTokenIDColumn: "pc_tokid"
            )
        )
    }
}
}
