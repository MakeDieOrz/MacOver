//
//  PlayedAppleDBBackup.swift
//  PlayTools
//

import Darwin
import Foundation
import SQLite3

public enum PlayedAppleDBBackup {
    public static func backupPath(for dbPath: String, fromVersion: Int) -> String {
        "\(dbPath).v\(fromVersion).bak"
    }

    public static func queryUserVersion(_ sqlite3DB: OpaquePointer) -> Int32 {
        var currentVersion: Int32 = 0
        var verStmt: OpaquePointer?
        if sqlite3_prepare_v2(sqlite3DB, "PRAGMA user_version;", -1, &verStmt, nil) == SQLITE_OK,
           let stmt = verStmt {
            if sqlite3_step(stmt) == SQLITE_ROW {
                currentVersion = sqlite3_column_int(stmt, 0)
            }
            sqlite3_finalize(stmt)
        }
        return currentVersion
    }

    private static func hasExistingUserTables(_ sqlite3DB: OpaquePointer) -> Bool {
        let sql = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(sqlite3DB, sql, -1, &stmt, nil) == SQLITE_OK,
              let prepared = stmt else {
            return false
        }
        defer { sqlite3_finalize(prepared) }
        if sqlite3_step(prepared) == SQLITE_ROW {
            return sqlite3_column_int64(prepared, 0) > 0
        }
        return false
    }

    @discardableResult
    public static func backupIfNeeded(
        sourceDB: OpaquePointer,
        dbPath: String,
        targetVersion: Int,
        logger: ((String) -> Void)? = nil
    ) -> Bool {
        guard !dbPath.isEmpty, dbPath != ":memory:" else {
            return true
        }
        guard hasExistingUserTables(sourceDB) else {
            return true
        }
        let currentVersion = Int(queryUserVersion(sourceDB))
        guard currentVersion < targetVersion else {
            return true
        }

        let bakPath = backupPath(for: dbPath, fromVersion: currentVersion)
        var existingStat = Darwin.stat()
        if stat(bakPath, &existingStat) == 0 {
            return true
        }

        let tmpPath = "\(bakPath).tmp"
        _ = Darwin.unlink(tmpPath)

        var destPtr: OpaquePointer?
        let openFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(tmpPath, &destPtr, openFlags, nil) == SQLITE_OK,
              let destDB = destPtr else {
            if let destPtr {
                let err = String(cString: sqlite3_errmsg(destPtr))
                logger?("Failed to open pre-migration backup \(tmpPath): \(err)")
                sqlite3_close_v2(destPtr)
            }
            _ = Darwin.unlink(tmpPath)
            return false
        }

        guard let backup = sqlite3_backup_init(destDB, "main", sourceDB, "main") else {
            let err = String(cString: sqlite3_errmsg(destDB))
            logger?("Failed sqlite3_backup_init to \(tmpPath): \(err)")
            sqlite3_close_v2(destDB)
            _ = Darwin.unlink(tmpPath)
            return false
        }

        let stepRc = sqlite3_backup_step(backup, -1)
        let finishRc = sqlite3_backup_finish(backup)
        if stepRc == SQLITE_DONE, finishRc == SQLITE_OK {
            // Convert backup from copied WAL header to self-contained DELETE journal mode
            // so single-file read-only opens never fail looking for a missing -wal sidecar.
            _ = sqlite3_exec(destDB, "PRAGMA journal_mode=DELETE;", nil, nil, nil)
        }
        sqlite3_close_v2(destDB)

        guard stepRc == SQLITE_DONE, finishRc == SQLITE_OK else {
            logger?("SQLite backup failed step=\(stepRc) finish=\(finishRc)")
            _ = Darwin.unlink(tmpPath)
            return false
        }

        if Darwin.rename(tmpPath, bakPath) != 0 {
            let errnoCopy = errno
            logger?("Failed atomic rename for DB backup \(bakPath): errno=\(errnoCopy)")
            _ = Darwin.unlink(tmpPath)
            return false
        }

        logger?("Created pre-migration Keychain DB backup at \(bakPath)")
        return true
    }
}
