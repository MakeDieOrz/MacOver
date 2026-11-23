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
        for cls in tables {
            let tableName = cls as String
            let pRef = PTPlayChainPersistentRef.encode(tableName: tableName)
            XCTAssertEqual(pRef.count, 20)
            XCTAssertTrue(PTPlayChainPersistentRef.isPersistentRef(pRef))
            XCTAssertEqual(PTPlayChainPersistentRef.decodeTableName(from: pRef), tableName)

            // Ensure no readable PCPR prefix or ASCII table name appears in persistent ref bytes
            XCTAssertFalse(pRef.starts(with: Data("PCPR".utf8)))
            let utf8Str = String(data: pRef, encoding: .utf8)
            XCTAssertNil(utf8Str)
            XCTAssertNil(pRef.range(of: Data(tableName.utf8)))
            for byte in pRef.prefix(4) {
                XCTAssertGreaterThanOrEqual(byte, 0x80)
            }
        }

        // Legacy PCPR1 lookup fallback remains decodable without minting PCPR1
        let legacyRef = Data("PCPR1:genp:\(UUID().uuidString)".utf8)
        XCTAssertTrue(PTPlayChainPersistentRef.isPersistentRef(legacyRef))
        XCTAssertEqual(PTPlayChainPersistentRef.decodeTableName(from: legacyRef), kSecClassGenericPassword as String)

        // Arbitrary 20-byte non-persistent-ref key payload is not misidentified
        let random20 = Data(repeating: 0x2A, count: 20)
        XCTAssertFalse(PTPlayChainPersistentRef.isPersistentRef(random20))
        XCTAssertNil(PTPlayChainPersistentRef.decodeTableName(from: random20))
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
}
