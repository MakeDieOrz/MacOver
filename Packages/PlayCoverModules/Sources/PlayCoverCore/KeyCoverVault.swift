//
//  KeyCoverVault.swift
//  PlayCoverCore
//

import CommonCrypto
import CryptoKit
import Darwin
import Foundation
import Security
import SQLite3
import Synchronization

public enum SecureFileWriter {
    public static func writeSecretFileAtomically(
        _ data: Data,
        to destinationURL: URL,
        directoryPermissions: mode_t = 0o700,
        filePermissions: mode_t = 0o600
    ) throws {
        let fm = FileManager.default
        let dir = destinationURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: directoryPermissions)]
            )
        }

        let tmpURL = dir.appendingPathComponent(".\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = Darwin.open(
            tmpURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            filePermissions
        )
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
        }

        var moved = false
        defer {
            if !moved {
                _ = Darwin.unlink(tmpURL.path)
            }
        }

        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let written = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    offset += written
                }
            }
            if Darwin.fchmod(fd, filePermissions) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
            }
            _ = Darwin.fsync(fd)
            if Darwin.close(fd) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            _ = Darwin.close(fd)
            throw error
        }

        if Darwin.rename(tmpURL.path, destinationURL.path) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        moved = true
    }
}

public struct KeyCoverKey: Equatable, Hashable, Sendable {
    public static let encryptedKeyExtension = "keyCover"
    private static let envelopeMagic = Data([0x4D, 0x43, 0x4B, 0x56, 0x31, 0x00, 0x00, 0x00]) // "MCKV1\0\0\0"
    private static let sqliteMagic = Data("SQLite format 3\0".utf8)
    private static let envelopeHeaderSize = 8 + 4 + 16 // magic + iterations(BE) + salt
    private static let defaultPBKDF2Iterations: UInt32 = 100_000
    private static let minPBKDF2Iterations: UInt32 = 1_000
    private static let maxPBKDF2Iterations: UInt32 = 5_000_000
    private static let saltByteCount = 16
    private static let aesKeyByteCount = 32

    public var appBundleID: String
    public var playChainDirectory: URL

    public init(appBundleID: String, playChainDirectory: URL) {
        self.appBundleID = appBundleID
        self.playChainDirectory = playChainDirectory
    }

    public var decryptedKeyDB: URL {
        playChainDirectory
            .appendingPathComponent(appBundleID)
            .appendingPathExtension("db")
    }

    public var encryptedKeyDB: URL {
        playChainDirectory
            .appendingPathComponent(appBundleID)
            .appendingPathExtension(KeyCoverKey.encryptedKeyExtension)
    }

    public var chainEncryptionStatus: Bool {
        FileManager.default.fileExists(atPath: encryptedKeyDB.path)
    }

    public func encryptKeyDB(plainTextKey: String, onUpdate: (() -> Void)? = nil) throws {
        guard !plainTextKey.isEmpty else {
            throw Self.vaultError("KeyCover encryption requires a non-empty key.")
        }
        try checkpointSQLiteWALIfNeeded(at: decryptedKeyDB)
        let plaintext = try Data(contentsOf: decryptedKeyDB)
        guard !plaintext.isEmpty else {
            throw Self.vaultError("Refusing to encrypt empty PlayChain database.")
        }
        let ciphertext = try Self.sealAuthenticated(plaintext: plaintext, plainTextKey: plainTextKey)
        try SecureFileWriter.writeSecretFileAtomically(ciphertext, to: encryptedKeyDB)
        try deleteKeyDB()
        onUpdate?()
    }

    public func decryptKeyDB(plainTextKey: String, onUpdate: (() -> Void)? = nil) throws {
        guard !plainTextKey.isEmpty else {
            throw Self.vaultError("KeyCover decryption requires a non-empty key.")
        }
        let plaintext = try decryptBytes(from: encryptedKeyDB, plainTextKey: plainTextKey)
        // Clear any stale SQLite sidecars before replacing .db to avoid SQLITE_CORRUPT WAL replay.
        removeSQLiteSidecars()
        try SecureFileWriter.writeSecretFileAtomically(plaintext, to: decryptedKeyDB)
        removeSQLiteSidecars()
        try deleteEncryptedKeyDB()
        onUpdate?()
    }

    /// Probes whether `plainTextKey` decrypts `encryptedKeyDB` without altering `.db` or `.keyCover`.
    public func canDecrypt(plainTextKey: String) -> Bool {
        guard !plainTextKey.isEmpty, chainEncryptionStatus else { return false }
        return (try? decryptBytes(from: encryptedKeyDB, plainTextKey: plainTextKey)) != nil
    }

    public func deleteKeyDB() throws {
        let fm = FileManager.default
        try fm.removeItem(at: decryptedKeyDB)
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecarURL = URL(fileURLWithPath: decryptedKeyDB.path + suffix)
            if fm.fileExists(atPath: sidecarURL.path) {
                try fm.removeItem(at: sidecarURL)
            }
        }
    }

    public func deleteEncryptedKeyDB() throws {
        try FileManager.default.removeItem(at: encryptedKeyDB)
    }

    private func removeSQLiteSidecars() {
        let fm = FileManager.default
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecarURL = URL(fileURLWithPath: decryptedKeyDB.path + suffix)
            if fm.fileExists(atPath: sidecarURL.path) {
                try? fm.removeItem(at: sidecarURL)
            }
        }
    }

    private func checkpointSQLiteWALIfNeeded(at dbURL: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbURL.path) else {
            throw Self.vaultError("PlayChain database not found at \(dbURL.path).")
        }
        guard Self.hasSQLiteHeader(at: dbURL) else {
            return
        }
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        let walHasData: Bool
        if let attrs = try? fm.attributesOfItem(atPath: walURL.path),
           let size = attrs[.size] as? NSNumber {
            walHasData = size.uint64Value > 0
        } else {
            walHasData = false
        }

        var db: OpaquePointer?
        let openRc = sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE, nil)
        guard openRc == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            if walHasData {
                throw Self.vaultError("Failed to open PlayChain SQLite database for WAL checkpoint (rc=\(openRc)).")
            }
            return
        }
        defer { sqlite3_close(db) }

        _ = sqlite3_busy_timeout(db, 2000)
        var logFrames: Int32 = 0
        var checkpointedFrames: Int32 = 0
        let cpRc = sqlite3_wal_checkpoint_v2(
            db,
            nil,
            SQLITE_CHECKPOINT_TRUNCATE,
            &logFrames,
            &checkpointedFrames
        )
        if cpRc != SQLITE_OK || (logFrames > 0 && checkpointedFrames < logFrames) {
            throw Self.vaultError(
                "Failed to checkpoint PlayChain SQLite WAL before encryption " +
                    "(rc=\(cpRc), log=\(logFrames), checkpointed=\(checkpointedFrames))."
            )
        }
    }

    private static func hasSQLiteHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: sqliteMagic.count) else { return false }
        return prefix == sqliteMagic
    }

    private static func sealAuthenticated(plaintext: Data, plainTextKey: String) throws -> Data {
        var salt = Data(count: saltByteCount)
        let status = salt.withUnsafeMutableBytes { buf -> OSStatus in
            guard let base = buf.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, saltByteCount, base)
        }
        guard status == errSecSuccess else {
            throw vaultError("Failed to generate cryptographic salt (status=\(status)).")
        }

        let iterations = defaultPBKDF2Iterations
        guard let keyData = KeyCoverVaultStore.derivePBKDF2(
            password: plainTextKey,
            salt: salt,
            iterations: Int(iterations),
            byteCount: aesKeyByteCount
        ) else {
            throw vaultError("Failed to derive KeyCover encryption key.")
        }

        var header = Data()
        header.reserveCapacity(envelopeHeaderSize)
        header.append(envelopeMagic)
        var bigEndianIter = iterations.bigEndian
        withUnsafeBytes(of: &bigEndianIter) { header.append(contentsOf: $0) }
        header.append(salt)

        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: keyData),
            authenticating: header
        )
        guard let combined = sealed.combined else {
            throw vaultError("Failed to serialize authenticated KeyCover ciphertext.")
        }

        var envelope = header
        envelope.append(combined)
        return envelope
    }

    private static func openAuthenticated(envelope: Data, plainTextKey: String) throws -> Data {
        guard envelope.count > envelopeHeaderSize,
              envelope.prefix(envelopeMagic.count) == envelopeMagic else {
            throw vaultError("Invalid authenticated KeyCover envelope.")
        }

        let iterStart = envelope.startIndex + envelopeMagic.count
        let iterBytes = envelope[iterStart..<(iterStart + 4)]
        let iterations = iterBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard iterations >= minPBKDF2Iterations, iterations <= maxPBKDF2Iterations else {
            throw vaultError("Invalid KeyCover KDF iteration count.")
        }

        let saltStart = iterStart + 4
        let saltEnd = saltStart + saltByteCount
        let header = Data(envelope[envelope.startIndex..<saltEnd])
        let salt = Data(envelope[saltStart..<saltEnd])
        let combined = Data(envelope[saltEnd..<envelope.endIndex])

        guard let keyData = KeyCoverVaultStore.derivePBKDF2(
            password: plainTextKey,
            salt: salt,
            iterations: Int(iterations),
            byteCount: aesKeyByteCount
        ) else {
            throw vaultError("Failed to derive KeyCover decryption key.")
        }

        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(
            sealedBox,
            using: SymmetricKey(data: keyData),
            authenticating: header
        )
    }

    private func decryptBytes(from sourceURL: URL, plainTextKey: String) throws -> Data {
        let raw = try Data(contentsOf: sourceURL)
        guard !raw.isEmpty else {
            throw Self.vaultError("Encrypted KeyCover file is empty.")
        }
        if raw.count >= Self.envelopeMagic.count && raw.prefix(Self.envelopeMagic.count) == Self.envelopeMagic {
            return try Self.openAuthenticated(envelope: raw, plainTextKey: plainTextKey)
        }
        let legacyPlaintext = try runLegacyOpenSSLDecrypt(sourceURL: sourceURL, plainTextKey: plainTextKey)
        guard legacyPlaintext.count >= Self.sqliteMagic.count,
              legacyPlaintext.prefix(Self.sqliteMagic.count) == Self.sqliteMagic else {
            throw Self.vaultError("Legacy KeyCover decryption did not produce a valid SQLite database.")
        }
        return legacyPlaintext
    }

    private func runLegacyOpenSSLDecrypt(
        sourceURL: URL,
        plainTextKey: String
    ) throws -> Data {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        task.arguments = [
            "enc", "-aes-256-cbc", "-A", "-d",
            "-in", sourceURL.path,
            "-pass", "stdin"
        ]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardInput = stdinPipe
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        defer {
            try? stdinPipe.fileHandleForReading.close()
            try? stdinPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForWriting.close()
        }

        try task.run()

        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        if let keyData = (plainTextKey + "\n").data(using: .utf8) {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: keyData)
        }
        try? stdinPipe.fileHandleForWriting.close()

        let group = DispatchGroup()
        let stdoutBox = Mutex<Data>(Data())
        let stderrBox = Mutex<Data>(Data())
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
            stdoutBox.withLock { $0 = data }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            stderrBox.withLock { $0 = data }
            group.leave()
        }
        group.wait()
        task.waitUntilExit()

        let stdoutData = stdoutBox.withLock { $0 }
        let stderrData = stderrBox.withLock { $0 }

        let stderrOutput = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderrSuffix = stderrOutput.isEmpty ? "" : ": \(stderrOutput)"
        let exitCode = task.terminationStatus

        guard exitCode == 0, !stdoutData.isEmpty else {
            let reason: String
            if exitCode != 0 {
                reason = "OpenSSL decrypt failed with exit code \(exitCode)\(stderrSuffix)"
            } else {
                reason = "OpenSSL decrypt produced an empty output (exit code \(exitCode))\(stderrSuffix)"
            }
            throw NSError(
                domain: "app.makedie.KeyCover",
                code: Int(exitCode != 0 ? exitCode : -1),
                userInfo: [NSLocalizedDescriptionKey: reason]
            )
        }

        return stdoutData
    }

    private static func vaultError(_ message: String) -> NSError {
        NSError(
            domain: "app.makedie.KeyCover",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

public enum KeyCoverVaultKind: String, Codable, Sendable {
    case selfGeneratedKey
    case passwordVerifier
}

public struct KeyCoverVaultRecord: Codable, Equatable, Sendable {
    public var version: Int
    public var kind: KeyCoverVaultKind
    public var managedKey: String?
    public var saltBase64: String?
    public var verifierBase64: String?
    public var iterations: Int?

    public init(
        version: Int = 1,
        kind: KeyCoverVaultKind,
        managedKey: String? = nil,
        saltBase64: String? = nil,
        verifierBase64: String? = nil,
        iterations: Int? = nil
    ) {
        self.version = version
        self.kind = kind
        self.managedKey = managedKey
        self.saltBase64 = saltBase64
        self.verifierBase64 = verifierBase64
        self.iterations = iterations
    }
}

public struct KeyCoverVaultStore: Sendable {
    public static let storeFileName = "keycover.json"
    public static let pbkdf2Iterations = 100_000
    public static let saltByteCount = 16
    public static let verifierByteCount = 32

    public let storeDirectory: URL

    public var recordURL: URL {
        storeDirectory.appendingPathComponent(Self.storeFileName)
    }

    public init(storeDirectory: URL) {
        self.storeDirectory = storeDirectory
    }

    public func readRecord() -> KeyCoverVaultRecord? {
        guard let data = try? Data(contentsOf: recordURL) else { return nil }
        return try? JSONDecoder().decode(KeyCoverVaultRecord.self, from: data)
    }

    public func writeRecord(_ record: KeyCoverVaultRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        try SecureFileWriter.writeSecretFileAtomically(
            data,
            to: recordURL,
            directoryPermissions: 0o700,
            filePermissions: 0o600
        )
    }

    public func removeRecord() {
        try? FileManager.default.removeItem(at: recordURL)
    }

    public func makeSelfGeneratedRecord(key: String) -> KeyCoverVaultRecord {
        KeyCoverVaultRecord(kind: .selfGeneratedKey, managedKey: key)
    }

    public func makePasswordVerifierRecord(
        password: String,
        iterations: Int = KeyCoverVaultStore.pbkdf2Iterations
    ) -> KeyCoverVaultRecord? {
        var salt = Data(count: Self.saltByteCount)
        let randomStatus = salt.withUnsafeMutableBytes { buf -> OSStatus in
            guard let base = buf.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, Self.saltByteCount, base)
        }
        guard randomStatus == errSecSuccess,
              let verifier = Self.derivePBKDF2(
                password: password,
                salt: salt,
                iterations: iterations,
                byteCount: Self.verifierByteCount
              ) else {
            return nil
        }
        return KeyCoverVaultRecord(
            kind: .passwordVerifier,
            saltBase64: salt.base64EncodedString(),
            verifierBase64: verifier.base64EncodedString(),
            iterations: iterations
        )
    }

    public func verify(password: String, against record: KeyCoverVaultRecord) -> Bool {
        guard !password.isEmpty else { return false }
        switch record.kind {
        case .selfGeneratedKey:
            guard let stored = record.managedKey else { return false }
            return Self.constantTimeEqual(Data(stored.utf8), Data(password.utf8))
        case .passwordVerifier:
            guard let saltBase64 = record.saltBase64,
                  let verifierBase64 = record.verifierBase64,
                  let salt = Data(base64Encoded: saltBase64),
                  let expected = Data(base64Encoded: verifierBase64) else {
                return false
            }
            let iterations = record.iterations ?? Self.pbkdf2Iterations
            guard let derived = Self.derivePBKDF2(
                password: password,
                salt: salt,
                iterations: iterations,
                byteCount: expected.count
            ) else {
                return false
            }
            return Self.constantTimeEqual(derived, expected)
        }
    }

    public static func derivePBKDF2(
        password: String,
        salt: Data,
        iterations: Int,
        byteCount: Int
    ) -> Data? {
        var derived = Data(count: byteCount)
        let passwordLength = password.utf8.count
        let status: Int32 = password.withCString { passwordPtr in
            salt.withUnsafeBytes { saltBytes in
                let saltPtr = saltBytes.bindMemory(to: UInt8.self).baseAddress
                return derived.withUnsafeMutableBytes { derivedBytes in
                    let derivedPtr = derivedBytes.bindMemory(to: UInt8.self).baseAddress
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr,
                        passwordLength,
                        saltPtr,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedPtr,
                        byteCount
                    )
                }
            }
        }
        return status == kCCSuccess ? derived : nil
    }

    public static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(lhs, rhs) {
            diff |= a ^ b
        }
        return diff == 0
    }

    public static func generateSecurePassword(length: Int = 32) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+")
        var randomBytes = [UInt8](repeating: 0, count: length)
        if SecRandomCopyBytes(kSecRandomDefault, length, &randomBytes) == errSecSuccess {
            return String(randomBytes.map { letters[Int($0) % letters.count] })
        }
        return String((0..<length).map { _ in letters.randomElement() ?? "." })
    }

    public static func listKeychains(in directory: URL) -> [KeyCoverKey] {
        let keychains = try? FileManager.default
            .contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )
        var seenBundleIDs = Set<String>()
        var keychainList: [KeyCoverKey] = []
        for file in keychains ?? [] {
            let ext = file.pathExtension
            guard ext == "db" || ext == KeyCoverKey.encryptedKeyExtension else {
                continue
            }
            let keychainName = file.deletingPathExtension().lastPathComponent
            guard !keychainName.isEmpty, seenBundleIDs.insert(keychainName).inserted else {
                continue
            }
            keychainList.append(KeyCoverKey(appBundleID: keychainName, playChainDirectory: directory))
        }
        return keychainList.sorted { $0.appBundleID < $1.appBundleID }
    }

    public static func unlockedCount(in keychains: [KeyCoverKey]) -> Int {
        var count = 0
        for keychain in keychains where !keychain.chainEncryptionStatus {
            count += 1
        }
        return count
    }
}
