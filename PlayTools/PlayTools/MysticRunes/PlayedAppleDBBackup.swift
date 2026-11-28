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

    private static func precreateSecureRegularFile(atPath path: String, exclusive: Bool) -> Bool {
        var flags = O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC
        if exclusive {
            flags |= O_EXCL
        }
        let fd = Darwin.open(path, flags, mode_t(0o600))
        guard fd >= 0 else {
            return false
        }
        defer { Darwin.close(fd) }
        var st = Darwin.stat()
        guard Darwin.fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG else {
            return false
        }
        _ = Darwin.fchmod(fd, mode_t(0o600))
        return true
    }

    private static func hardenRegularFile(atPath path: String) {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        var st = Darwin.stat()
        if Darwin.fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG {
            _ = Darwin.fchmod(fd, mode_t(0o600))
        }
    }

    private static func hardenParentDirectoryIfSafe(forFilePath path: String) {
        let parentDir = (path as NSString).deletingLastPathComponent
        guard !parentDir.isEmpty,
              parentDir != "/",
              parentDir != "/tmp",
              parentDir != "/private/tmp" else {
            return
        }
        var dirSt = Darwin.stat()
        guard Darwin.lstat(parentDir, &dirSt) == 0,
              (dirSt.st_mode & S_IFMT) == S_IFDIR,
              dirSt.st_uid == Darwin.geteuid() else {
            return
        }
        _ = Darwin.chmod(parentDir, mode_t(0o700))
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

        hardenParentDirectoryIfSafe(forFilePath: dbPath)

        let bakPath = backupPath(for: dbPath, fromVersion: currentVersion)
        var existingStat = Darwin.stat()
        if Darwin.lstat(bakPath, &existingStat) == 0 {
            if (existingStat.st_mode & S_IFMT) == S_IFLNK {
                logger?("Refusing to write pre-migration backup over symlink at \(bakPath)")
                return false
            }
            hardenRegularFile(atPath: bakPath)
            return true
        }

        // Canonicalize the parent directory via Darwin.realpath (unlike URL.resolvingSymlinksInPath,
        // realpath resolves /var -> /private/var on macOS) so SQLITE_OPEN_NOFOLLOW succeeds on real
        // parent paths while still strictly refusing symlinks at the leaf backup file.
        let parentDir = (bakPath as NSString).deletingLastPathComponent
        var resolvedBuf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolvedParentDir = Darwin.realpath(parentDir, &resolvedBuf)
            .map { String(cString: $0) } ?? parentDir
        let resolvedBakPath = (resolvedParentDir as NSString)
            .appendingPathComponent((bakPath as NSString).lastPathComponent)
        let tmpPath = "\(resolvedBakPath).tmp"
        _ = Darwin.unlink(tmpPath)
        guard precreateSecureRegularFile(atPath: tmpPath, exclusive: true) else {
            let errnoCopy = errno
            logger?("Failed to pre-create secure pre-migration backup \(tmpPath): errno=\(errnoCopy)")
            return false
        }

        var destPtr: OpaquePointer?
        let openFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOFOLLOW
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
        _ = Darwin.unlink("\(tmpPath)-wal")
        _ = Darwin.unlink("\(tmpPath)-shm")

        guard stepRc == SQLITE_DONE, finishRc == SQLITE_OK else {
            logger?("SQLite backup failed step=\(stepRc) finish=\(finishRc)")
            _ = Darwin.unlink(tmpPath)
            return false
        }

        hardenRegularFile(atPath: tmpPath)
        if Darwin.rename(tmpPath, resolvedBakPath) != 0 {
            let errnoCopy = errno
            logger?("Failed atomic rename for DB backup \(resolvedBakPath): errno=\(errnoCopy)")
            _ = Darwin.unlink(tmpPath)
            return false
        }
        hardenRegularFile(atPath: resolvedBakPath)

        logger?("Created pre-migration Keychain DB backup at \(resolvedBakPath)")
        return true
    }
}
