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
}
