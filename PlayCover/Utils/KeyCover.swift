//
//  KeyCover.swift
//  PlayCover
//
//  Created by Venti on 31/01/2023.
//

import Foundation
import Observation
import Security
import Synchronization

nonisolated final class KeyCover: Sendable {
    private struct WeakObservableBox: Sendable {
        weak var value: KeyCoverObservable?
    }

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
    private let observableBox: Mutex<WeakObservableBox>

    private var observable: KeyCoverObservable? {
        observableBox.withLock { $0.value }
    }

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
        self.observableBox = Mutex(WeakObservableBox(value: observable))
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
        KeyCoverVaultStore.listKeychains(in: directory)
    }

    static func unlockedCount(in keychains: [KeyCoverKey]? = nil) -> Int {
        KeyCoverVaultStore.unlockedCount(in: keychains ?? listKeychains())
    }

    func listKeychains() -> [KeyCoverKey] {
        Self.listKeychains(in: playChainDirectory)
    }

    func unlockedCount() -> Int {
        Self.unlockedCount(in: listKeychains())
    }

    func unlockChain(_ keychain: KeyCoverKey) async throws {
        let obs = observable
        if keyCoverPlainTextKey == nil {
            switch preferences.keyCoverEnabled {
            case .selfGeneratedPassword:
                if let resolved = passwordStore.resolveSelfGeneratedPassword(allowLegacyKeychainMigration: true) {
                    keyCoverPlainTextKey = resolved
                }
            case .userProvidedPassword:
                try await obs?.requestUnlockPromptAndWait()
            case .disabled:
                break
            }
        }
        if keychain.chainEncryptionStatus, let key = keyCoverPlainTextKey {
            try keychain.decryptKeyDB(plainTextKey: key) { [weak obs] in
                Task { @MainActor in
                    obs?.update()
                }
            }
        }
    }

    func lockChain(_ keychain: KeyCoverKey) throws {
        if keyCoverPlainTextKey == nil && preferences.keyCoverEnabled == .selfGeneratedPassword,
           let resolved = passwordStore.resolveSelfGeneratedPassword(allowLegacyKeychainMigration: true) {
            keyCoverPlainTextKey = resolved
        }
        guard let key = keyCoverPlainTextKey else {
            return
        }
        let obs = observable
        if !keychain.chainEncryptionStatus {
            try keychain.encryptKeyDB(plainTextKey: key) { [weak obs] in
                Task { @MainActor in
                    obs?.update()
                }
            }
        }
    }

    func lockAllChainsSynchronously(excluding runningBundleIDs: Set<String> = []) {
        guard isKeyCoverEnabled() else { return }
        if keyCoverPlainTextKey == nil && preferences.keyCoverEnabled == .selfGeneratedPassword,
           let resolved = passwordStore.resolveSelfGeneratedPassword(allowLegacyKeychainMigration: true) {
            keyCoverPlainTextKey = resolved
        }
        guard let key = keyCoverPlainTextKey else { return }
        for keychain in listKeychains() where !keychain.chainEncryptionStatus {
            if runningBundleIDs.contains(keychain.appBundleID) {
                continue
            }
            try? keychain.encryptKeyDB(plainTextKey: key)
        }
    }

    func lockAllChainsAsync() {
        Task {
            if keyCoverPlainTextKey == nil && preferences.keyCoverEnabled == .selfGeneratedPassword,
               let resolved = passwordStore.resolveSelfGeneratedPassword(allowLegacyKeychainMigration: true) {
                keyCoverPlainTextKey = resolved
            }
            for keychain in listKeychains() where !keychain.chainEncryptionStatus {
                try? lockChain(keychain)
            }
        }
    }
}

@MainActor
@Observable
final class KeyCoverObservable {
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
        let initialKeychains = preferences.keyCoverEnabled == .disabled ? [] : KeyCover.listKeychains()
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

    func refreshAsync() {
        let currentKeyCover = keyCover
        let fallbackEnabled = preferences.keyCoverEnabled != .disabled
        Task.detached(priority: .utility) {
            let list = currentKeyCover?.listKeychains() ?? KeyCover.listKeychains()
            let unlocked = KeyCover.unlockedCount(in: list)
            let enabled = currentKeyCover?.isKeyCoverEnabled() ?? fallbackEnabled
            await MainActor.run {
                self.keyCoverEnabled = enabled
                self.unlockedCount = unlocked
                self.keychains = list
            }
        }
    }
}

nonisolated final class KeyCoverPassword: Sendable {
    private struct WeakKeyCoverBox: Sendable {
        weak var value: KeyCover?
    }

    private struct WeakObservableBox: Sendable {
        weak var value: KeyCoverObservable?
    }

    static let tag = "app.makedie.masterkey"

    static var defaultStoreDirectory: URL {
        PlayTools.playCoverContainer.appendingPathComponent("KeyCover", isDirectory: true)
    }

    private let preferences: KeyCoverPreferences
    private let vaultStore: KeyCoverVaultStore
    private let playChainDirectory: URL
    private let legacyKeychainReader: @Sendable () -> String?
    private let legacyKeychainDeleter: @Sendable () -> Void
    private let keyCoverBox: Mutex<WeakKeyCoverBox>
    private let observableBox: Mutex<WeakObservableBox>

    private var keyCover: KeyCover? {
        keyCoverBox.withLock { $0.value }
    }

    private var observable: KeyCoverObservable? {
        observableBox.withLock { $0.value }
    }

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
        self.keyCoverBox = Mutex(WeakKeyCoverBox(value: keyCover))
        self.observableBox = Mutex(WeakObservableBox(value: observable))
        self.vaultStore = KeyCoverVaultStore(storeDirectory: storeDirectory)
        self.playChainDirectory = playChainDirectory
        self.legacyKeychainReader = legacyKeychainReader ?? Self.defaultLegacyKeychainReader
        self.legacyKeychainDeleter = legacyKeychainDeleter ?? Self.defaultLegacyKeychainDeleter
    }

    func attachKeyCover(_ keyCover: KeyCover) {
        keyCoverBox.withLock { $0.value = keyCover }
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
        let record = vaultStore.makeSelfGeneratedRecord(key: legacyKey)
        do {
            try vaultStore.writeRecord(record)
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
        let existingRecord = readRecord()

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

        // Always verify existing keycover.json credentials before replacing the record,
        // even when no encrypted PlayChain databases currently exist.
        if let existingRecord {
            guard let oldKey = resolvedOldKey,
                  vaultStore.verify(password: oldKey, against: existingRecord) else {
                return false
            }
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
            try vaultStore.writeRecord(newRecord)
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

        let obs = observable
        Task { @MainActor [weak obs] in
            obs?.update()
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

        if let record = readRecord() {
            guard let activeKey, vaultStore.verify(password: activeKey, against: record) else {
                return false
            }
        }

        if !encryptedChains.isEmpty {
            guard let activeKey else { return false }
            if readRecord() == nil {
                guard validatePassword(activeKey) else { return false }
            }
            guard encryptedChains.allSatisfy({ $0.canDecrypt(plainTextKey: activeKey) }) else {
                return false
            }
            var decryptedChains: [KeyCoverKey] = []
            for chain in encryptedChains {
                do {
                    try chain.decryptKeyDB(plainTextKey: activeKey)
                    decryptedChains.append(chain)
                } catch {
                    for rolledBack in decryptedChains {
                        try? rolledBack.encryptKeyDB(plainTextKey: activeKey)
                    }
                    return false
                }
            }
        }

        vaultStore.removeRecord()
        legacyKeychainDeleter()

        preferences.keyCoverEnabled = .disabled
        keyCover?.keyCoverPlainTextKey = nil

        let obs = observable
        Task { @MainActor [weak obs] in
            obs?.update()
        }
        return true
    }

    func forceResetKeyCoverPassword() {
        if keyCover?.keyCoverPlainTextKey != nil {
            return
        }
        vaultStore.removeRecord()
        legacyKeychainDeleter()

        preferences.keyCoverEnabled = .disabled
        keyCover?.keyCoverPlainTextKey = nil

        for chain in KeyCover.listKeychains(in: playChainDirectory) {
            try? chain.deleteEncryptedKeyDB()
        }

        let obs = observable
        Task { @MainActor [weak obs] in
            obs?.update()
        }
    }

    func validatePassword(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }

        if let record = readRecord() {
            return vaultStore.verify(password: key, against: record)
        }

        // Lazy migration when no local keycover.json exists yet.
        if preferences.keyCoverEnabled == .userProvidedPassword,
           let sampleEncrypted = KeyCover.listKeychains(in: playChainDirectory).first(where: \.chainEncryptionStatus) {
            guard sampleEncrypted.canDecrypt(plainTextKey: key) else {
                return false
            }
            if let verifierRecord = makeRecord(for: key, mode: .userProvidedPassword) {
                try? vaultStore.writeRecord(verifierRecord)
            }
            legacyKeychainDeleter()
            return true
        }

        guard let legacyKey = legacyKeychainReader(),
              KeyCoverVaultStore.constantTimeEqual(Data(legacyKey.utf8), Data(key.utf8)) else {
            return false
        }
        let targetMode: KeyCoverStatus = preferences.keyCoverEnabled == .selfGeneratedPassword
            ? .selfGeneratedPassword
            : .userProvidedPassword
        if let migratedRecord = makeRecord(for: key, mode: targetMode) {
            try? vaultStore.writeRecord(migratedRecord)
        }
        legacyKeychainDeleter()
        return true
    }

    func generateVerySecurePassword() -> String {
        KeyCoverVaultStore.generateSecurePassword()
    }

    // MARK: - Private Storage Delegation

    private func makeRecord(for key: String, mode: KeyCoverStatus) -> KeyCoverVaultRecord? {
        switch mode {
        case .selfGeneratedPassword:
            return vaultStore.makeSelfGeneratedRecord(key: key)
        case .userProvidedPassword:
            return vaultStore.makePasswordVerifierRecord(password: key)
        case .disabled:
            return nil
        }
    }

    private func readRecord() -> KeyCoverVaultRecord? {
        vaultStore.readRecord()
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
