//
//  KeyCover.swift
//  PlayCover
//
//  Created by Venti on 31/01/2023.
//

import Foundation
import CryptoKit
import SwiftUI
import Security

final class KeyCover {
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

    private let keyLock = NSLock()
    private var _keyCoverPlainTextKey: String?
    private let preferences: KeyCoverPreferences
    private let passwordStore: KeyCoverPassword
    private weak var observable: KeyCoverObservable?

    // This is only exposed at runtime
    var keyCoverPlainTextKey: String? {
        get {
            keyLock.lock()
            defer { keyLock.unlock() }
            return _keyCoverPlainTextKey
        }
        set {
            keyLock.lock()
            _keyCoverPlainTextKey = newValue
            keyLock.unlock()
        }
    }

    init(
        preferences: KeyCoverPreferences = KeyCoverPreferences(),
        passwordStore: KeyCoverPassword = KeyCoverPassword(),
        observable: KeyCoverObservable? = nil
    ) {
        self.preferences = preferences
        self.passwordStore = passwordStore
        self.observable = observable
        _keyCoverPlainTextKey = preferences.keyCoverEnabled == .selfGeneratedPassword
            ? passwordStore.getKeyCoverPassword() : nil
    }

    func isKeyCoverEnabled() -> Bool {
        return preferences.keyCoverEnabled != .disabled
    }

    static func listKeychains() -> [KeyCoverKey] {
        let keychains = try? FileManager.default
            .contentsOfDirectory(at: KeyCover.playChainPath,
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
            keychainList.append(KeyCoverKey(appBundleID: keychainName))
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
        Self.listKeychains()
    }

    func unlockedCount() -> Int {
        Self.unlockedCount(in: Self.listKeychains())
    }

    func unlockChain(_ keychain: KeyCoverKey) async throws {
        if keyCoverPlainTextKey == nil {
            try await observable?.requestUnlockPromptAndWait()
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
            for keychain in listKeychains() where !keychain.chainEncryptionStatus {
                try? lockChain(keychain)
            }
        }
    }
}

class KeyCoverObservable: ObservableObject {
    @Published var keyCoverEnabled: Bool
    @Published var unlockedCount: Int
    @Published var keychains: [KeyCoverKey]

    private let preferences: KeyCoverPreferences
    private weak var keyCover: KeyCover?

    @Published var isKeyCoverUnlockingPromptShown: Bool {
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

    private let waitersLock = NSLock()
    private var unlockPromptWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

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
                waitersLock.lock()
                if !isKeyCoverUnlockingPromptShown {
                    waitersLock.unlock()
                    continuation.resume()
                    return
                }
                if Task.isCancelled {
                    waitersLock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                unlockPromptWaiters[waiterID] = continuation
                waitersLock.unlock()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.waitersLock.lock()
                let pending = self.unlockPromptWaiters.removeValue(forKey: waiterID)
                self.waitersLock.unlock()
                pending?.resume(throwing: CancellationError())
            }
        }
    }

    private func resumeUnlockPromptWaiters() {
        waitersLock.lock()
        let waiters = Array(unlockPromptWaiters.values)
        unlockPromptWaiters.removeAll()
        waitersLock.unlock()
        for continuation in waiters {
            continuation.resume()
        }
    }

    func update() {
        let list = KeyCover.listKeychains()
        keyCoverEnabled = keyCover?.isKeyCoverEnabled() ?? (preferences.keyCoverEnabled != .disabled)
        unlockedCount = KeyCover.unlockedCount(in: list)
        keychains = list
    }
}

struct KeyCoverKey {
    static let encryptedKeyExtension = "keyCover"

    var appBundleID: String

    var decryptedKeyDB: URL {
        KeyCover.playChainPath
            .appendingPathComponent(appBundleID)
            .appendingPathExtension("db")
    }
    var encryptedKeyDB: URL {
        KeyCover.playChainPath
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

class KeyCoverPassword {
    let tag = "app.makedie.masterkey"

    private let preferences: KeyCoverPreferences
    private weak var keyCover: KeyCover?
    private weak var observable: KeyCoverObservable?

    init(
        preferences: KeyCoverPreferences = KeyCoverPreferences(),
        keyCover: KeyCover? = nil,
        observable: KeyCoverObservable? = nil
    ) {
        self.preferences = preferences
        self.keyCover = keyCover
        self.observable = observable
    }

    func attachKeyCover(_ keyCover: KeyCover) {
        self.keyCover = keyCover
    }

    @discardableResult
    func setKeyCoverPassword(_ key: String) -> Bool {
        guard let keyData = key.data(using: .utf8) else { return false }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tag,
            kSecAttrAccount as String: tag
        ]
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = keyData

        let oldKey = getKeyCoverPassword()
        if let oldKey {
            keyCover?.keyCoverPlainTextKey = oldKey
            for keychain in KeyCover.listKeychains() where keychain.chainEncryptionStatus {
                try? keychain.decryptKeyDB(plainTextKey: oldKey)
            }
            keyCover?.keyCoverPlainTextKey = nil
        }

        SecItemDelete(baseQuery as CFDictionary)
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            print("Error storing master key in keychain: \(status)")
            if let oldKey {
                keyCover?.keyCoverPlainTextKey = oldKey
                for keychain in KeyCover.listKeychains() where !keychain.chainEncryptionStatus {
                    try? keychain.encryptKeyDB(plainTextKey: oldKey)
                }
            }
            return false
        }

        keyCover?.keyCoverPlainTextKey = key

        for keychain in KeyCover.listKeychains() where !keychain.chainEncryptionStatus {
            try? keychain.encryptKeyDB(plainTextKey: key)
        }

        Task { @MainActor [weak observable] in
            observable?.update()
        }
        return true
    }

    func getKeyCoverPassword() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tag,
                                    kSecAttrAccount as String: tag,
                                    kSecReturnData as String: kCFBooleanTrue as Any,
                                    kSecMatchLimit as String: kSecMatchLimitOne]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        if status == errSecSuccess {
            if let data = dataTypeRef as? Data {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    func removeKeyCoverPassword() {
        let currentKey = keyCover?.keyCoverPlainTextKey ?? getKeyCoverPassword()
        if let currentKey {
            for chain in KeyCover.listKeychains() where chain.chainEncryptionStatus {
                try? chain.decryptKeyDB(plainTextKey: currentKey)
            }
        }

        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tag,
                                    kSecAttrAccount as String: tag]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            print("Error removing master key from keychain: \(status)")
        }

        preferences.keyCoverEnabled = .disabled
        keyCover?.keyCoverPlainTextKey = nil

        Task { @MainActor [weak observable] in
            observable?.update()
        }
    }

    func forceResetKeyCoverPassword() {
        if keyCover?.keyCoverPlainTextKey != nil {
            return
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tag,
                                    kSecAttrAccount as String: tag]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            print("Error removing master key from keychain: \(status)")
        }

        preferences.keyCoverEnabled = .disabled
        keyCover?.keyCoverPlainTextKey = nil

        for chain in KeyCover.listKeychains() {
            try? chain.deleteEncryptedKeyDB()
        }

        Task { @MainActor [weak observable] in
            observable?.update()
        }
    }

    func validatePassword(_ key: String) -> Bool {
        return key == getKeyCoverPassword()
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
}
