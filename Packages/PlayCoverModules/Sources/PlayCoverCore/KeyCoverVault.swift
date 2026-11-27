//
//  KeyCoverVault.swift
//  PlayCoverCore
//

import CommonCrypto
import Foundation
import Security

public struct KeyCoverKey: Equatable, Hashable, Sendable {
    public static let encryptedKeyExtension = "keyCover"

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
        try runOpenSSL(
            sourceURL: decryptedKeyDB,
            destURL: encryptedKeyDB,
            decrypt: false,
            plainTextKey: plainTextKey
        )
        try deleteKeyDB()
        onUpdate?()
    }

    public func decryptKeyDB(plainTextKey: String, onUpdate: (() -> Void)? = nil) throws {
        try runOpenSSL(
            sourceURL: encryptedKeyDB,
            destURL: decryptedKeyDB,
            decrypt: true,
            plainTextKey: plainTextKey
        )
        try deleteEncryptedKeyDB()
        onUpdate?()
    }

    /// Probes whether `plainTextKey` decrypts `encryptedKeyDB` without altering `.db` or `.keyCover`.
    public func canDecrypt(plainTextKey: String) -> Bool {
        guard chainEncryptionStatus else { return false }
        let probeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("keycover-probe-\(UUID().uuidString).db")
        defer {
            try? FileManager.default.removeItem(at: probeURL)
        }
        do {
            try runOpenSSL(
                sourceURL: encryptedKeyDB,
                destURL: probeURL,
                decrypt: true,
                plainTextKey: plainTextKey
            )
            return true
        } catch {
            return false
        }
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

    private func runOpenSSL(
        sourceURL: URL,
        destURL: URL,
        decrypt: Bool,
        plainTextKey: String
    ) throws {
        let fm = FileManager.default
        let tmpURL = destURL.appendingPathExtension("tmp-\(UUID().uuidString)")

        if fm.fileExists(atPath: tmpURL.path) {
            try fm.removeItem(at: tmpURL)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        var arguments = ["enc", "-aes-256-cbc", "-A"]
        if decrypt {
            arguments.append("-d")
        }
        arguments.append(contentsOf: [
            "-in", sourceURL.path,
            "-out", tmpURL.path,
            "-pass", "stdin"
        ])
        task.arguments = arguments

        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardInput = stdinPipe
        task.standardError = stderrPipe

        defer {
            try? stdinPipe.fileHandleForReading.close()
            try? stdinPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForWriting.close()
        }

        do {
            try task.run()
        } catch {
            try? fm.removeItem(at: tmpURL)
            throw error
        }

        try? stdinPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForWriting.close()

        if let keyData = (plainTextKey + "\n").data(using: .utf8) {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: keyData)
        }
        try? stdinPipe.fileHandleForWriting.close()

        let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        task.waitUntilExit()

        let stderrOutput = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderrSuffix = stderrOutput.isEmpty ? "" : ": \(stderrOutput)"
        let operation = decrypt ? "decrypt" : "encrypt"

        let exitCode = task.terminationStatus
        let tmpExists = fm.fileExists(atPath: tmpURL.path)
        let outputSize = (try? fm.attributesOfItem(atPath: tmpURL.path)[.size] as? NSNumber)?.uint64Value ?? 0

        guard exitCode == 0, tmpExists, outputSize > 0 else {
            try? fm.removeItem(at: tmpURL)
            let reason: String
            if exitCode != 0 {
                reason = "OpenSSL \(operation) failed with exit code \(exitCode)\(stderrSuffix)"
            } else if !tmpExists {
                reason = "OpenSSL \(operation) produced no output file (exit code \(exitCode))\(stderrSuffix)"
            } else {
                reason = "OpenSSL \(operation) produced an empty output file (exit code \(exitCode))\(stderrSuffix)"
            }
            throw NSError(
                domain: "app.makedie.KeyCover",
                code: Int(exitCode != 0 ? exitCode : -1),
                userInfo: [NSLocalizedDescriptionKey: reason]
            )
        }

        do {
            if fm.fileExists(atPath: destURL.path) {
                _ = try fm.replaceItemAt(destURL, withItemAt: tmpURL)
            } else {
                try fm.moveItem(at: tmpURL, to: destURL)
            }
        } catch {
            try? fm.removeItem(at: tmpURL)
            throw error
        }
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
        let fm = FileManager.default
        if !fm.fileExists(atPath: storeDirectory.path) {
            try fm.createDirectory(
                at: storeDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)

        let tmpURL = storeDirectory.appendingPathComponent(".\(Self.storeFileName).tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmpURL, options: [.atomic])
            if chmod(tmpURL.path, 0o600) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
            }
            if fm.fileExists(atPath: recordURL.path) {
                _ = try fm.replaceItemAt(recordURL, withItemAt: tmpURL)
            } else {
                try fm.moveItem(at: tmpURL, to: recordURL)
            }
            _ = chmod(recordURL.path, 0o600)
        } catch {
            try? fm.removeItem(at: tmpURL)
            throw error
        }
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
