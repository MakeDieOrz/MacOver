import Foundation
import Security
import SQLite3
import XCTest

final class PlayedAppleDBBackupTests: XCTestCase {
    private var tempDir: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayedAppleDBBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
    }

    override func tearDownWithError() throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    func testLegacyV1WalDatabaseCreatesAtomicBackupAndPreservesExistingBackup() throws {
        let dir = try XCTUnwrap(tempDir)
        let dbURL = dir.appendingPathComponent("com.example.game.db")
        let backupURL = URL(fileURLWithPath: PlayedAppleDBBackup.backupPath(for: dbURL.path, fromVersion: 1))
        XCTAssertEqual(backupURL.path, "\(dbURL.path).v1.bak")
        XCTAssertTrue(backupURL.path.hasPrefix(dbURL.path))
        XCTAssertNotEqual(backupURL.pathExtension, "db")

        var dbPtr: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(dbURL.path, &dbPtr, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK
        )
        let db = try XCTUnwrap(dbPtr)
        defer { sqlite3_close_v2(db) }

        XCTAssertEqual(
            sqlite3_exec(
                db,
                "PRAGMA journal_mode=WAL; CREATE TABLE genp (acct TEXT PRIMARY KEY, val TEXT);" +
                    "INSERT INTO genp (acct, val) VALUES ('alice', 'secret_v1');" +
                    "PRAGMA user_version = 1;",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )

        var logged: [String] = []
        XCTAssertTrue(
            PlayedAppleDBBackup.backupIfNeeded(sourceDB: db, dbPath: dbURL.path, targetVersion: 2) {
                logged.append($0)
            }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(backupURL.path).tmp"))
        XCTAssertFalse(logged.isEmpty)

        // Mutate live DB to v2 and verify backup retains original v1 data
        XCTAssertEqual(
            sqlite3_exec(db, "UPDATE genp SET val = 'migrated_v2'; PRAGMA user_version = 2;", nil, nil, nil),
            SQLITE_OK
        )

        var bakPtr: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(backupURL.path, &bakPtr, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let bakDB = try XCTUnwrap(bakPtr)
        defer { sqlite3_close_v2(bakDB) }
        XCTAssertEqual(PlayedAppleDBBackup.queryUserVersion(bakDB), 1)

        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(bakDB, "SELECT val FROM genp WHERE acct = 'alice';", -1, &stmt, nil), SQLITE_OK)
        let prepared = try XCTUnwrap(stmt)
        defer { sqlite3_finalize(prepared) }
        XCTAssertEqual(sqlite3_step(prepared), SQLITE_ROW)
        let restoredVal = try XCTUnwrap(sqlite3_column_text(prepared, 0)).withMemoryRebound(to: CChar.self, capacity: 1) {
            String(cString: $0)
        }
        XCTAssertEqual(restoredVal, "secret_v1")

        // Repeated backup attempt for same version must not overwrite existing .v1.bak
        XCTAssertTrue(PlayedAppleDBBackup.backupIfNeeded(sourceDB: db, dbPath: dbURL.path, targetVersion: 2))
    }

    func testAlreadyUpgradedV2DatabaseSkipsBackup() throws {
        let dir = try XCTUnwrap(tempDir)
        let dbURL = dir.appendingPathComponent("com.example.v2.db")
        let backupURL = URL(fileURLWithPath: PlayedAppleDBBackup.backupPath(for: dbURL.path, fromVersion: 2))

        var dbPtr: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(dbURL.path, &dbPtr, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK
        )
        let db = try XCTUnwrap(dbPtr)
        defer { sqlite3_close_v2(db) }

        XCTAssertEqual(
            sqlite3_exec(db, "CREATE TABLE genp (acct TEXT PRIMARY KEY); PRAGMA user_version = 2;", nil, nil, nil),
            SQLITE_OK
        )
        XCTAssertTrue(PlayedAppleDBBackup.backupIfNeeded(sourceDB: db, dbPath: dbURL.path, targetVersion: 2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testOpaqueBinaryPersistentRefEncodingAndLegacyDecoding() throws {
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
            XCTAssertEqual(pRef.count, 12)
            XCTAssertTrue(PTPlayChainPersistentRef.isPersistentRef(pRef))
            XCTAssertEqual(PTPlayChainPersistentRef.decodeTableName(from: pRef), tableName)

            // Ensure iOS 12-byte format: 4-byte class tag + 8-byte little-endian rowID
            XCTAssertFalse(pRef.starts(with: Data("PCPR".utf8)))
            XCTAssertEqual(Data(pRef.prefix(4)), Data(tableName.utf8))
            var decodedRowID: Int64 = 0
            _ = withUnsafeMutableBytes(of: &decodedRowID) { dst in
                pRef[4..<12].copyBytes(to: dst)
            }
            XCTAssertEqual(Int64(littleEndian: decodedRowID), rowID)
        }

        // Legacy 20-byte [0x8A, 0x9F, 0xC4, 0x91..0x95] binary refs remain decodable
        var legacyBinaryBytes: [UInt8] = [0x8A, 0x9F, 0xC4, 0x91]
        legacyBinaryBytes.append(contentsOf: [UInt8](repeating: 0x11, count: 16))
        let legacyBinaryRef = Data(legacyBinaryBytes)
        XCTAssertTrue(PTPlayChainPersistentRef.isPersistentRef(legacyBinaryRef))
        XCTAssertEqual(PTPlayChainPersistentRef.decodeTableName(from: legacyBinaryRef), kSecClassGenericPassword as String)

        // Legacy PCPR1 lookup fallback remains decodable without minting PCPR1
        let legacyRef = Data("PCPR1:genp:\(UUID().uuidString)".utf8)
        XCTAssertTrue(PTPlayChainPersistentRef.isPersistentRef(legacyRef))
        XCTAssertEqual(PTPlayChainPersistentRef.decodeTableName(from: legacyRef), kSecClassGenericPassword as String)

        // Arbitrary non-persistent-ref key payloads (including invalid zero rowID or unknown 12-byte tags) are rejected
        let random20 = Data(repeating: 0x2A, count: 20)
        XCTAssertFalse(PTPlayChainPersistentRef.isPersistentRef(random20))
        XCTAssertNil(PTPlayChainPersistentRef.decodeTableName(from: random20))

        var zeroRowGenp = Data("genp".utf8)
        zeroRowGenp.append(Data(repeating: 0, count: 8))
        XCTAssertFalse(PTPlayChainPersistentRef.isPersistentRef(zeroRowGenp))
        XCTAssertNil(PTPlayChainPersistentRef.decodeTableName(from: zeroRowGenp))

        let random12 = Data("abcd12345678".utf8)
        XCTAssertFalse(PTPlayChainPersistentRef.isPersistentRef(random12))
        XCTAssertNil(PTPlayChainPersistentRef.decodeTableName(from: random12))
    }

    func testAccessGroupEntitlementAllowsDefaultsAndEntitledPatterns() {
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
        XCTAssertTrue(patterns.contains("ABCD123456.com.example.shared"))
        XCTAssertTrue(patterns.contains("ABCD123456.com.example.legacy"))
        XCTAssertTrue(patterns.contains("ABCD123456.com.example.app"))

        XCTAssertEqual(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: nil,
                allowedPatterns: patterns,
                isReadOnlyQuery: false
            ),
            errSecSuccess
        )
        XCTAssertEqual(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: "",
                allowedPatterns: patterns,
                isReadOnlyQuery: false
            ),
            errSecSuccess
        )
        XCTAssertEqual(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: "ABCD123456.com.example.shared",
                allowedPatterns: patterns,
                isReadOnlyQuery: false
            ),
            errSecSuccess
        )
        XCTAssertEqual(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: "ABCD123456.com.example.anything",
                allowedPatterns: ["ABCD123456.*"],
                isReadOnlyQuery: false
            ),
            errSecSuccess
        )
    }

    func testAccessGroupEntitlementRejectsForeignAndInvalidGroups() {
        let patterns = ["ABCD123456.com.example.app"]
        XCTAssertEqual(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: "ZZZZ999999.com.evil.app",
                allowedPatterns: patterns,
                isReadOnlyQuery: false
            ),
            errSecMissingEntitlement
        )
        XCTAssertEqual(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: "com.apple.mobilesafari",
                allowedPatterns: patterns,
                isReadOnlyQuery: true
            ),
            errSecMissingEntitlement
        )
        XCTAssertEqual(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: kSecAttrAccessGroupToken as String,
                allowedPatterns: patterns,
                isReadOnlyQuery: true
            ),
            errSecSuccess
        )
        XCTAssertEqual(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: kSecAttrAccessGroupToken as String,
                allowedPatterns: patterns,
                isReadOnlyQuery: false
            ),
            errSecMissingEntitlement
        )
        XCTAssertEqual(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: 123,
                allowedPatterns: patterns,
                isReadOnlyQuery: false
            ),
            errSecParam
        )
    }

    func testSecureEnclaveRegistryTracksPrivateKeysOnly() throws {
        XCTAssertTrue(PTPlayChainSecureEnclaveRegistry.parametersRequestSecureEnclave([
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave as String
        ]))
        XCTAssertTrue(PTPlayChainSecureEnclaveRegistry.parametersRequestSecureEnclave([
            kSecPrivateKeyAttrs as String: [
                kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave as String
            ]
        ]))
        XCTAssertFalse(PTPlayChainSecureEnclaveRegistry.parametersRequestSecureEnclave([
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom as String
        ]))

        let ecAttrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256
        ]
        let seKey = try XCTUnwrap(SecKeyCreateRandomKey(ecAttrs as CFDictionary, nil))
        let normalKey = try XCTUnwrap(SecKeyCreateRandomKey(ecAttrs as CFDictionary, nil))
        let sePubKey = try XCTUnwrap(SecKeyCopyPublicKey(seKey))

        PTPlayChainSecureEnclaveRegistry.markSecureEnclaveKey(seKey)
        PTPlayChainSecureEnclaveRegistry.markSecureEnclaveKey(sePubKey)

        XCTAssertTrue(PTPlayChainSecureEnclaveRegistry.isSecureEnclaveKey(seKey))
        XCTAssertFalse(PTPlayChainSecureEnclaveRegistry.isSecureEnclaveKey(sePubKey))
        XCTAssertFalse(PTPlayChainSecureEnclaveRegistry.isSecureEnclaveKey(normalKey))
    }

    func testAccessGroupPolicyIncludesValidAppGroupsAndPreservesFakeTeamID() {
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

        XCTAssertTrue(patterns.contains("ABCD123456.com.example.shared"))
        XCTAssertTrue(patterns.contains("ABCD123456.com.example.legacy"))
        XCTAssertTrue(patterns.contains("FAKETEAMID.com.example.legacy"))
        XCTAssertTrue(patterns.contains("ABCD123456.com.example.app"))
        XCTAssertTrue(patterns.contains("FAKETEAMID.com.example.app"))
        XCTAssertTrue(patterns.contains("group.com.example.shared"))
        XCTAssertTrue(patterns.contains("group.com.example.trimmed"))

        XCTAssertFalse(patterns.contains("ABCD123456."))
        XCTAssertFalse(patterns.contains("group."))
        XCTAssertFalse(patterns.contains("group.*"))
        XCTAssertFalse(patterns.contains("not-a-group"))
        XCTAssertFalse(patterns.contains("group.com/evil"))
        XCTAssertFalse(patterns.contains("group.com..evil"))
        XCTAssertFalse(patterns.contains("group.has space"))
    }

    func testAccessGroupValidationAllowsAppGroupsFakeTeamAndRejectsNSNull() {
        let patterns = [
            "ABCD123456.com.example.app",
            "FAKETEAMID.com.example.legacy",
            "group.com.example.shared"
        ]
        XCTAssertEqual(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: "group.com.example.shared",
                allowedPatterns: patterns,
                isReadOnlyQuery: false
            ),
            errSecSuccess
        )
        XCTAssertEqual(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: "FAKETEAMID.com.example.legacy",
                allowedPatterns: patterns,
                isReadOnlyQuery: true
            ),
            errSecSuccess
        )
        XCTAssertEqual(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: "group.com.other.evil",
                allowedPatterns: patterns,
                isReadOnlyQuery: false
            ),
            errSecMissingEntitlement
        )
        XCTAssertEqual(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: NSNull(),
                allowedPatterns: patterns,
                isReadOnlyQuery: false
            ),
            errSecParam
        )
        XCTAssertEqual(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: NSNull(),
                allowedPatterns: patterns,
                isReadOnlyQuery: true
            ),
            errSecParam
        )
        XCTAssertEqual(
            PTPlayChainAccessGroupPolicy.validate(
                requestedGroup: ["group.com.example.shared"],
                allowedPatterns: patterns,
                isReadOnlyQuery: false
            ),
            errSecParam
        )
    }

    func testSecureEnclaveUpdatePolicyProtectsTokenIDColumn() {
        XCTAssertFalse(
            PTPlayChainKeyUpdatePolicy.isUpdatableColumn(
                "pc_tokid",
                internalTokenIDColumn: "pc_tokid"
            )
        )
        XCTAssertTrue(
            PTPlayChainKeyUpdatePolicy.isUpdatableColumn(
                kSecAttrLabel as String,
                internalTokenIDColumn: "pc_tokid"
            )
        )
        XCTAssertTrue(
            PTPlayChainKeyUpdatePolicy.isUpdatableColumn(
                kSecAttrApplicationTag as String,
                internalTokenIDColumn: "pc_tokid"
            )
        )
    }
}
