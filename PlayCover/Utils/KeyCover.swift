//
//  KeyCover.swift
//  PlayCover
//
//  Created by Venti on 31/01/2023.
//

import CommonCrypto
import Foundation
import Observation
import Security
import SwiftUI
import Synchronization

final class KeyCover: @unchecked Sendable {
    static var playChainPath: URL {
        let playChainDir = PlayTools.playCoverContainer.appendingPathComponent("PlayChain")

        if !FileManager.default.fileExists(atPath: playChainDir.path) {
            do {
                try FileManager.default.createDirectory(at: playChainDir, withIntermediateDirectories: true)
            } catch {
                PlayCoverDiagnostics.reportError(error)
            }
        }

        return playChainDir
    }

    private let plainTextKey: Mutex<String?>
    private let preferences: KeyCoverPreferences
    private let passwordStore: KeyCoverPassword
    private let playChainDirectory: URL
    private weak var observable: KeyCoverObservable?

    // This is only exposed at runtime
    var keyCoverPlainTextKey: String? {
        get { plainTextKey.withLock { $0 } }
        set { plainTextKey.withLock { $0 = newValue } }
    }

    init(
        preferences: KeyCoverPreferences = KeyCoverPreferences(),
        passwordStore: KeyCoverPassword = KeyCoverPassword(),
        observable: KeyCoverObservable? = nil,
        playChainDirectory: URL = KeyCover.playChainPath
    ) {
        self.preferences = preferences
        self.passwordStore = passwordStore
        self.observable = observable
        self.playChainDirectory = playChainDirectory

        let initialKey: String?
        if !ProcessInfo.isRunningUnitTests || playChainDirectory != Self.playChainPath {
            if preferences.keyCoverEnabled == .selfGeneratedPassword {
                if let localKey = passwordStore.loadLocalManagedPassword() {
                    initialKey = localKey
                } else {
                    // Migrate off legacy KeyCover silently when there are no encrypted PlayChain DBs.
                    let hasEncryptedChains = Self.listKeychains(in: playChainDirectory)
                        .contains(where: \.chainEncryptionStatus)
                    if !hasEncryptedChains {
                        preferences.keyCoverEnabled = .disabled
                        passwordStore.deleteLegacyKeychainItemIfPresent()
                    }
                    initialKey = nil
                }
            } else {
                initialKey = nil
            }
        } else {
            initialKey = nil
        }
        self.plainTextKey = Mutex(initialKey)
    }

    func isKeyCoverEnabled() -> Bool {
        return preferences.keyCoverEnabled != .disabled
    }

    static func listKeychains(in directory: URL = KeyCover.playChainPath) -> [KeyCoverKey] {
        let keychains = try? FileManager.default
            .contentsOfDirectory(at: directory,
                                 includingPropertiesForKeys: nil,
                                 options: .skipsHiddenFiles)
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

    static func unlockedCount(in keychains: [KeyCoverKey]? = nil) -> Int {
        var count = 0
        for keychain in (keychains ?? listKeychains()) where !keychain.chainEncryptionStatus {
            count += 1
        }
        return count
    }

    func listKeychains() -> [KeyCoverKey] {
        Self.listKeychains(in: playChainDirectory)
    }

    func unlockedCount() -> Int {
        Self.unlockedCount(in: listKeychains())
    }

    func unlockChain(_ keychain: KeyCoverKey) async throws {
        if keyCoverPlainTextKey == nil {
            switch preferences.keyCoverEnabled {
            case .selfGeneratedPassword:
                if let resolved = passwordStore.resolveSelfGeneratedPassword(allowLegacyKeychainMigration: true) {
                    keyCoverPlainTextKey = resolved
                }
            case .userProvidedPassword:
                try await observable?.requestUnlockPromptAndWait()
            case .disabled:
                break
            }
        }
        if keychain.chainEncryptionStatus, let key = keyCoverPlainTextKey {
            try keychain.decryptKeyDB(plainTextKey: key) { [weak observable] in
                Task { @MainActor in
                    observable?.update()
                }
            }
        }
    }

    func lockChain(_ keychain: KeyCoverKey) throws {
        guard let key = keyCoverPlainTextKey else {
            return
        }
        if !keychain.chainEncryptionStatus {
            try keychain.encryptKeyDB(plainTextKey: key) { [weak observable] in
                Task { @MainActor in
                    observable?.update()
                }
            }
        }
    }

    func lockAllChainsAsync() {
        Task {
            if keyCoverPlainTextKey == nil && preferences.keyCoverEnabled == .selfGeneratedPassword {
                _ = passwordStore.resolveSelfGeneratedPassword(allowLegacyKeychainMigration: true)
            }
            for keychain in listKeychains() where !keychain.chainEncryptionStatus {
                try? lockChain(keychain)
            }
        }
    }
}

@Observable
final class KeyCoverObservable: @unchecked Sendable {
    var keyCoverEnabled: Bool
    var unlockedCount: Int
    var keychains: [KeyCoverKey]

    private let preferences: KeyCoverPreferences
    private weak var keyCover: KeyCover?

    var isKeyCoverUnlockingPromptShown: Bool {
        didSet {
            if !isKeyCoverUnlockingPromptShown {
                resumeUnlockPromptWaiters()
            }
        }
    }

    init(preferences: KeyCoverPreferences = KeyCoverPreferences(), keyCover: KeyCover? = nil) {
        self.preferences = preferences
        self.keyCover = keyCover
        self.keyCoverEnabled = preferences.keyCoverEnabled != .disabled
        let initialKeychains = KeyCover.listKeychains()
        self.keychains = initialKeychains
        self.unlockedCount = KeyCover.unlockedCount(in: initialKeychains)
        self.isKeyCoverUnlockingPromptShown = preferences.keyCoverEnabled == .selfGeneratedPassword
            ? false : preferences.keyCoverEnabled == .disabled
            ? false : preferences.promptForKeyCoverPasswordAtLaunch
    }

    func attachKeyCover(_ keyCover: KeyCover) {
        self.keyCover = keyCover
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.update()
            }
        }
    }

    private let unlockPromptWaiters = Mutex<[UUID: CheckedContinuation<Void, Error>]>([:])

    @MainActor
    func requestUnlockPromptAndWait() async throws {
        isKeyCoverUnlockingPromptShown = true
        try await waitForUnlockPromptDismissal()
    }

    @MainActor
    func waitForUnlockPromptDismissal() async throws {
        guard isKeyCoverUnlockingPromptShown else { return }
        try Task.checkCancellation()
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                unlockPromptWaiters.withLock { waiters in
                    if !isKeyCoverUnlockingPromptShown {
                        continuation.resume()
                        return
                    }
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    waiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let pending = self.unlockPromptWaiters.withLock {
                    $0.removeValue(forKey: waiterID)
                }
                pending?.resume(throwing: CancellationError())
            }
        }
    }

    private func resumeUnlockPromptWaiters() {
        let waiters = unlockPromptWaiters.withLock { waiters -> [CheckedContinuation<Void, Error>] in
            let current = Array(waiters.values)
            waiters.removeAll()
            return current
        }
        for continuation in waiters {
            continuation.resume()
        }
    }

    func update() {
        let list = keyCover?.listKeychains() ?? KeyCover.listKeychains()
        keyCoverEnabled = keyCover?.isKeyCoverEnabled() ?? (preferences.keyCoverEnabled != .disabled)
        unlockedCount = KeyCover.unlockedCount(in: list)
        keychains = list
    }
}

struct KeyCoverKey {
    static let encryptedKeyExtension = "keyCover"

    var appBundleID: String
    var playChainDirectory: URL = KeyCover.playChainPath

    var decryptedKeyDB: URL {
        playChainDirectory
            .appendingPathComponent(appBundleID)
            .appendingPathExtension("db")
    }
    var encryptedKeyDB: URL {
        playChainDirectory
            .appendingPathComponent(appBundleID)
            .appendingPathExtension(KeyCoverKey.encryptedKeyExtension)
    }

    var chainEncryptionStatus: Bool {
        return FileManager.default.fileExists(atPath: encryptedKeyDB.path)
    }

    func encryptKeyDB(plainTextKey: String, onUpdate: (() -> Void)? = nil) throws {
        try runOpenSSL(sourceURL: decryptedKeyDB,
                       destURL: encryptedKeyDB,
                       decrypt: false,
                       plainTextKey: plainTextKey)

        try deleteKeyDB()
        onUpdate?()
    }

    func decryptKeyDB(plainTextKey: String, onUpdate: (() -> Void)? = nil) throws {
        try runOpenSSL(sourceURL: encryptedKeyDB,
                       destURL: decryptedKeyDB,
                       decrypt: true,
                       plainTextKey: plainTextKey)

        try deleteEncryptedKeyDB()
        onUpdate?()
    }

    /// Probes whether `plainTextKey` decrypts `encryptedKeyDB` without altering `.db` or `.keyCover`.
    func canDecrypt(plainTextKey: String) -> Bool {
        guard chainEncryptionStatus else { return false }
        let probeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("keycover-probe-\(UUID().uuidString).db")
        defer {
            try? FileManager.default.removeItem(at: probeURL)
        }
        do {
            try runOpenSSL(sourceURL: encryptedKeyDB,
                           destURL: probeURL,
                           decrypt: true,
                           plainTextKey: plainTextKey)
            return true
        } catch {
            return false
        }
    }

    private func runOpenSSL(sourceURL: URL,
                            destURL: URL,
                            decrypt: Bool,
                            plainTextKey: String) throws {
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

    func deleteKeyDB() throws {
        let fm = FileManager.default
        try fm.removeItem(at: decryptedKeyDB)
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecarURL = URL(fileURLWithPath: decryptedKeyDB.path + suffix)
            if fm.fileExists(atPath: sidecarURL.path) {
                try fm.removeItem(at: sidecarURL)
            }
        }
    }

    func deleteEncryptedKeyDB() throws {
        try FileManager.default.removeItem(at: encryptedKeyDB)
    }
}

final class KeyCoverPassword: @unchecked Sendable {
    static let tag = "app.makedie.masterkey"
    private static let storeFileName = "keycover.json"
    private static let pbkdf2Iterations = 100_000
    private static let saltByteCount = 16
    private static let verifierByteCount = 32

    static var defaultStoreDirectory: URL {
        PlayTools.playCoverContainer.appendingPathComponent("KeyCover", isDirectory: true)
    }

    private enum StoredKind: String, Codable, Sendable {
        case selfGeneratedKey
        case passwordVerifier
    }

    private struct StoredRecord: Codable, Sendable {
        var version: Int = 1
        var kind: StoredKind
        var managedKey: String?
        var saltBase64: String?
        var verifierBase64: String?
        var iterations: Int?
    }

    private let preferences: KeyCoverPreferences
    private let storeDirectory: URL
    private let playChainDirectory: URL
    private let legacyKeychainReader: @Sendable () -> String?
    private let legacyKeychainDeleter: @Sendable () -> Void
    private weak var keyCover: KeyCover?
    private weak var observable: KeyCoverObservable?

    init(
        preferences: KeyCoverPreferences = KeyCoverPreferences(),
        keyCover: KeyCover? = nil,
        observable: KeyCoverObservable? = nil,
        storeDirectory: URL = KeyCoverPassword.defaultStoreDirectory,
        playChainDirectory: URL = KeyCover.playChainPath,
        legacyKeychainReader: (@Sendable () -> String?)? = nil,
        legacyKeychainDeleter: (@Sendable () -> Void)? = nil
    ) {
        self.preferences = preferences
        self.keyCover = keyCover
        self.observable = observable
        self.storeDirectory = storeDirectory
        self.playChainDirectory = playChainDirectory
        self.legacyKeychainReader = legacyKeychainReader ?? Self.defaultLegacyKeychainReader
        self.legacyKeychainDeleter = legacyKeychainDeleter ?? Self.defaultLegacyKeychainDeleter
    }

    func attachKeyCover(_ keyCover: KeyCover) {
        self.keyCover = keyCover
    }

    func loadLocalManagedPassword() -> String? {
        guard let record = readRecord(), record.kind == .selfGeneratedKey else {
            return nil
        }
        return record.managedKey
    }

    func hasLocalRecord() -> Bool {
        readRecord() != nil
    }

    func hasEncryptedChains() -> Bool {
        KeyCover.listKeychains(in: playChainDirectory).contains(where: \.chainEncryptionStatus)
    }

    func deleteLegacyKeychainItemIfPresent() {
        legacyKeychainDeleter()
    }

    func resolveSelfGeneratedPassword(allowLegacyKeychainMigration: Bool) -> String? {
        if let cached = keyCover?.keyCoverPlainTextKey, !cached.isEmpty {
            return cached
        }
        if let localKey = loadLocalManagedPassword() {
            keyCover?.keyCoverPlainTextKey = localKey
            return localKey
        }
        guard allowLegacyKeychainMigration, let legacyKey = legacyKeychainReader() else {
            return nil
        }
        let record = StoredRecord(kind: .selfGeneratedKey, managedKey: legacyKey)
        do {
            try writeRecord(record)
            legacyKeychainDeleter()
        } catch {
            print("Error persisting migrated KeyCover configuration: \(error)")
        }
        keyCover?.keyCoverPlainTextKey = legacyKey
        return legacyKey
    }

    @discardableResult
    func setKeyCoverPassword(_ key: String, mode: KeyCoverStatus? = nil, currentPassword: String? = nil) -> Bool {
        let targetMode = mode
            ?? (preferences.keyCoverEnabled == .disabled ? .selfGeneratedPassword : preferences.keyCoverEnabled)
        guard targetMode != .disabled, !key.isEmpty else { return false }
        guard let newRecord = makeRecord(for: key, mode: targetMode) else { return false }

        let allChains = KeyCover.listKeychains(in: playChainDirectory)
        let encryptedChains = allChains.filter(\.chainEncryptionStatus)

        let resolvedOldKey: String?
        if let currentPassword, !currentPassword.isEmpty {
            resolvedOldKey = currentPassword
        } else if let cached = keyCover?.keyCoverPlainTextKey, !cached.isEmpty {
            resolvedOldKey = cached
        } else if let localManaged = loadLocalManagedPassword() {
            resolvedOldKey = localManaged
        } else if !encryptedChains.isEmpty, preferences.keyCoverEnabled == .selfGeneratedPassword {
            resolvedOldKey = legacyKeychainReader()
        } else {
            resolvedOldKey = nil
        }

        if !encryptedChains.isEmpty && resolvedOldKey == nil {
            return false
        }

        var decryptedForRotation: [KeyCoverKey] = []
        if let oldKey = resolvedOldKey, !encryptedChains.isEmpty {
            keyCover?.keyCoverPlainTextKey = oldKey
            for chain in encryptedChains {
                do {
                    try chain.decryptKeyDB(plainTextKey: oldKey)
                    decryptedForRotation.append(chain)
                } catch {
                    for rolledBack in decryptedForRotation {
                        try? rolledBack.encryptKeyDB(plainTextKey: oldKey)
                    }
                    return false
                }
            }
            keyCover?.keyCoverPlainTextKey = nil
        }

        do {
            try writeRecord(newRecord)
        } catch {
            print("Error storing KeyCover configuration: \(error)")
            if let oldKey = resolvedOldKey {
                for rolledBack in decryptedForRotation {
                    try? rolledBack.encryptKeyDB(plainTextKey: oldKey)
                }
                if !decryptedForRotation.isEmpty {
                    keyCover?.keyCoverPlainTextKey = oldKey
                }
            }
            return false
        }

        legacyKeychainDeleter()
        keyCover?.keyCoverPlainTextKey = key

        for keychain in KeyCover.listKeychains(in: playChainDirectory) where !keychain.chainEncryptionStatus {
            try? keychain.encryptKeyDB(plainTextKey: key)
        }

        Task { @MainActor [weak observable] in
            observable?.update()
        }
        return true
    }

    func getKeyCoverPassword() -> String? {
        loadLocalManagedPassword()
    }

    @discardableResult
    func removeKeyCoverPassword(currentPassword: String? = nil) -> Bool {
        let encryptedChains = KeyCover.listKeychains(in: playChainDirectory).filter(\.chainEncryptionStatus)
        let activeKey: String?
        if let currentPassword, !currentPassword.isEmpty {
            activeKey = currentPassword
        } else if let cached = keyCover?.keyCoverPlainTextKey, !cached.isEmpty {
            activeKey = cached
        } else if preferences.keyCoverEnabled == .selfGeneratedPassword {
            activeKey = resolveSelfGeneratedPassword(allowLegacyKeychainMigration: !encryptedChains.isEmpty)
        } else {
            activeKey = nil
        }

        if !encryptedChains.isEmpty {
            guard let activeKey else { return false }
            for chain in encryptedChains {
                do {
                    try chain.decryptKeyDB(plainTextKey: activeKey)
                } catch {
                    return false
                }
            }
        }

        removeRecordFile()
        legacyKeychainDeleter()

        preferences.keyCoverEnabled = .disabled
        keyCover?.keyCoverPlainTextKey = nil

        Task { @MainActor [weak observable] in
            observable?.update()
        }
        return true
    }

    func forceResetKeyCoverPassword() {
        if keyCover?.keyCoverPlainTextKey != nil {
            return
        }
        removeRecordFile()
        legacyKeychainDeleter()

        preferences.keyCoverEnabled = .disabled
        keyCover?.keyCoverPlainTextKey = nil

        for chain in KeyCover.listKeychains(in: playChainDirectory) {
            try? chain.deleteEncryptedKeyDB()
        }

        Task { @MainActor [weak observable] in
            observable?.update()
        }
    }

    func validatePassword(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }

        if let record = readRecord() {
            switch record.kind {
            case .selfGeneratedKey:
                guard let stored = record.managedKey else { return false }
                return Self.constantTimeEqual(Data(stored.utf8), Data(key.utf8))
            case .passwordVerifier:
                guard let saltBase64 = record.saltBase64,
                      let verifierBase64 = record.verifierBase64,
                      let salt = Data(base64Encoded: saltBase64),
                      let expected = Data(base64Encoded: verifierBase64) else {
                    return false
                }
                let iterations = record.iterations ?? Self.pbkdf2Iterations
                guard let derived = Self.derivePBKDF2(
                    password: key,
                    salt: salt,
                    iterations: iterations,
                    byteCount: expected.count
                ) else {
                    return false
                }
                return Self.constantTimeEqual(derived, expected)
            }
        }

        // Lazy migration when no local keycover.json exists yet.
        if preferences.keyCoverEnabled == .userProvidedPassword,
           let sampleEncrypted = KeyCover.listKeychains(in: playChainDirectory).first(where: \.chainEncryptionStatus) {
            guard sampleEncrypted.canDecrypt(plainTextKey: key) else {
                return false
            }
            if let verifierRecord = makeRecord(for: key, mode: .userProvidedPassword) {
                try? writeRecord(verifierRecord)
            }
            legacyKeychainDeleter()
            return true
        }

        guard let legacyKey = legacyKeychainReader(),
              Self.constantTimeEqual(Data(legacyKey.utf8), Data(key.utf8)) else {
            return false
        }
        let targetMode: KeyCoverStatus = preferences.keyCoverEnabled == .selfGeneratedPassword
            ? .selfGeneratedPassword
            : .userProvidedPassword
        if let migratedRecord = makeRecord(for: key, mode: targetMode) {
            try? writeRecord(migratedRecord)
        }
        legacyKeychainDeleter()
        return true
    }

    func generateVerySecurePassword() -> String {
        let length = 32
        let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+")
        var randomBytes = [UInt8](repeating: 0, count: length)
        if SecRandomCopyBytes(kSecRandomDefault, length, &randomBytes) == errSecSuccess {
            return String(randomBytes.map { letters[Int($0) % letters.count] })
        }
        return String((0..<length).map { _ in letters.randomElement() ?? "." })
    }

    // MARK: - Private Storage & Crypto Helpers

    private var recordURL: URL {
        storeDirectory.appendingPathComponent(Self.storeFileName)
    }

    private func makeRecord(for key: String, mode: KeyCoverStatus) -> StoredRecord? {
        switch mode {
        case .selfGeneratedPassword:
            return StoredRecord(kind: .selfGeneratedKey, managedKey: key)
        case .userProvidedPassword:
            var salt = Data(count: Self.saltByteCount)
            let randomStatus = salt.withUnsafeMutableBytes { buf -> OSStatus in
                guard let base = buf.baseAddress else { return errSecAllocate }
                return SecRandomCopyBytes(kSecRandomDefault, Self.saltByteCount, base)
            }
            guard randomStatus == errSecSuccess,
                  let verifier = Self.derivePBKDF2(
                    password: key,
                    salt: salt,
                    iterations: Self.pbkdf2Iterations,
                    byteCount: Self.verifierByteCount
                  ) else {
                return nil
            }
            return StoredRecord(
                kind: .passwordVerifier,
                saltBase64: salt.base64EncodedString(),
                verifierBase64: verifier.base64EncodedString(),
                iterations: Self.pbkdf2Iterations
            )
        case .disabled:
            return nil
        }
    }

    private func readRecord() -> StoredRecord? {
        guard let data = try? Data(contentsOf: recordURL) else { return nil }
        return try? JSONDecoder().decode(StoredRecord.self, from: data)
    }

    private func writeRecord(_ record: StoredRecord) throws {
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

    private func removeRecordFile() {
        try? FileManager.default.removeItem(at: recordURL)
    }

    private static func derivePBKDF2(
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

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(lhs, rhs) {
            diff |= a ^ b
        }
        return diff == 0
    }

    private static let defaultLegacyKeychainReader: @Sendable () -> String? = {
        guard !ProcessInfo.isRunningUnitTests else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tag,
            kSecAttrAccount as String: tag,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        guard status == errSecSuccess, let data = dataTypeRef as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static let defaultLegacyKeychainDeleter: @Sendable () -> Void = {
        guard !ProcessInfo.isRunningUnitTests else { return }
        let existsQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tag,
            kSecAttrAccount as String: tag,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let existsStatus = SecItemCopyMatching(existsQuery as CFDictionary, nil)
        guard existsStatus == errSecSuccess else { return }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tag,
            kSecAttrAccount as String: tag
        ]
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            print("Error removing legacy master key from keychain: \(deleteStatus)")
        }
    }
}
