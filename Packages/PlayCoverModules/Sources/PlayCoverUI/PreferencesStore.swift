import Foundation
import Observation
import PlayCoverCore
import Synchronization

public enum KeyCoverStatus: String, Codable, Hashable, Sendable {
    case disabled
    case selfGeneratedPassword
    case userProvidedPassword
}

@Observable
public final class KeyCoverPreferences: @unchecked Sendable {
    private enum Keys {
        static let keyCoverEnabled = "keyCoverEnabled"
        static let promptAtLaunch = "promptForKeyCoverPasswordAtLaunch"
    }

    private struct State: Sendable {
        var keyCoverEnabled: KeyCoverStatus
        var promptForKeyCoverPasswordAtLaunch: Bool
    }

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let stateLock: Mutex<State>

    public var keyCoverEnabled: KeyCoverStatus {
        get {
            access(keyPath: \.keyCoverEnabled)
            return stateLock.withLock { $0.keyCoverEnabled }
        }
        set {
            withMutation(keyPath: \.keyCoverEnabled) {
                let changed = stateLock.withLock { state -> Bool in
                    guard state.keyCoverEnabled != newValue else { return false }
                    state.keyCoverEnabled = newValue
                    return true
                }
                if changed {
                    userDefaults.set(newValue.rawValue, forKey: Keys.keyCoverEnabled)
                }
            }
        }
    }

    public var promptForKeyCoverPasswordAtLaunch: Bool {
        get {
            access(keyPath: \.promptForKeyCoverPasswordAtLaunch)
            return stateLock.withLock { $0.promptForKeyCoverPasswordAtLaunch }
        }
        set {
            withMutation(keyPath: \.promptForKeyCoverPasswordAtLaunch) {
                let changed = stateLock.withLock { state -> Bool in
                    guard state.promptForKeyCoverPasswordAtLaunch != newValue else { return false }
                    state.promptForKeyCoverPasswordAtLaunch = newValue
                    return true
                }
                if changed {
                    userDefaults.set(newValue, forKey: Keys.promptAtLaunch)
                }
            }
        }
    }

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let initialStatus: KeyCoverStatus
        if let raw = userDefaults.string(forKey: Keys.keyCoverEnabled),
           let status = KeyCoverStatus(rawValue: raw) {
            initialStatus = status
        } else {
            initialStatus = .disabled
        }
        let initialPrompt = userDefaults.object(forKey: Keys.promptAtLaunch) != nil
            ? userDefaults.bool(forKey: Keys.promptAtLaunch)
            : true
        self.stateLock = Mutex(State(
            keyCoverEnabled: initialStatus,
            promptForKeyCoverPasswordAtLaunch: initialPrompt
        ))
    }
}

@Observable
public final class InstallPreferences: @unchecked Sendable {
    private enum Keys {
        static let alwaysInstallPlayTools = "AlwaysInstallPlayTools"
        static let defaultAppType = "DefaultAppType"
        static let showInstallPopup = "ShowInstallPopup"
        static let showAppStorePopup = "ShowAppStorePopup"
    }

    @ObservationIgnored private let userDefaults: UserDefaults

    public var alwaysInstallPlayTools: Bool {
        didSet {
            guard oldValue != alwaysInstallPlayTools else { return }
            userDefaults.set(alwaysInstallPlayTools, forKey: Keys.alwaysInstallPlayTools)
        }
    }

    public var defaultAppType: LSApplicationCategoryType {
        didSet {
            guard oldValue != defaultAppType else { return }
            userDefaults.set(defaultAppType.rawValue, forKey: Keys.defaultAppType)
        }
    }

    public var showInstallPopup: Bool {
        didSet {
            guard oldValue != showInstallPopup else { return }
            userDefaults.set(showInstallPopup, forKey: Keys.showInstallPopup)
        }
    }

    public var showAppStorePopup: Bool {
        didSet {
            guard oldValue != showAppStorePopup else { return }
            userDefaults.set(showAppStorePopup, forKey: Keys.showAppStorePopup)
        }
    }

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.alwaysInstallPlayTools = userDefaults.object(forKey: Keys.alwaysInstallPlayTools) != nil
            ? userDefaults.bool(forKey: Keys.alwaysInstallPlayTools)
            : true
        if let raw = userDefaults.string(forKey: Keys.defaultAppType),
           let category = LSApplicationCategoryType(rawValue: raw) {
            self.defaultAppType = category
        } else {
            self.defaultAppType = .none
        }
        self.showInstallPopup = userDefaults.object(forKey: Keys.showInstallPopup) != nil
            ? userDefaults.bool(forKey: Keys.showInstallPopup)
            : false
        self.showAppStorePopup = userDefaults.object(forKey: Keys.showAppStorePopup) != nil
            ? userDefaults.bool(forKey: Keys.showAppStorePopup)
            : true
    }
}

@MainActor
@Observable
public final class UninstallPreferences {
    private enum Keys {
        static let clearAppData = "ClearAppDataUninstall"
        static let removeAppKeymap = "RemoveAppKeymapUninstall"
        static let removeAppSettings = "RemoveAppSettingUninstall"
        static let removeAppNetworkRules = "RemoveAppNetworkRulesUninstall"
        static let removeAppEntitlements = "RemoveAppEntitlementsUninstall"
        static let removePlayChain = "RemovePlayChainUninstall"
        static let showUninstallPopup = "ShowUninstallPopup"
    }

    @ObservationIgnored private let userDefaults: UserDefaults

    public var clearAppData: Bool {
        didSet {
            guard oldValue != clearAppData else { return }
            userDefaults.set(clearAppData, forKey: Keys.clearAppData)
        }
    }

    public var removeAppKeymap: Bool {
        didSet {
            guard oldValue != removeAppKeymap else { return }
            userDefaults.set(removeAppKeymap, forKey: Keys.removeAppKeymap)
        }
    }

    public var removeAppSettings: Bool {
        didSet {
            guard oldValue != removeAppSettings else { return }
            userDefaults.set(removeAppSettings, forKey: Keys.removeAppSettings)
        }
    }

    public var removeAppNetworkRules: Bool {
        didSet {
            guard oldValue != removeAppNetworkRules else { return }
            userDefaults.set(removeAppNetworkRules, forKey: Keys.removeAppNetworkRules)
        }
    }

    public var removeAppEntitlements: Bool {
        didSet {
            guard oldValue != removeAppEntitlements else { return }
            userDefaults.set(removeAppEntitlements, forKey: Keys.removeAppEntitlements)
        }
    }

    public var removePlayChain: Bool {
        didSet {
            guard oldValue != removePlayChain else { return }
            userDefaults.set(removePlayChain, forKey: Keys.removePlayChain)
        }
    }

    public var showUninstallPopup: Bool {
        didSet {
            guard oldValue != showUninstallPopup else { return }
            userDefaults.set(showUninstallPopup, forKey: Keys.showUninstallPopup)
        }
    }

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.clearAppData = userDefaults.object(forKey: Keys.clearAppData) != nil
            ? userDefaults.bool(forKey: Keys.clearAppData)
            : false
        self.removeAppKeymap = userDefaults.object(forKey: Keys.removeAppKeymap) != nil
            ? userDefaults.bool(forKey: Keys.removeAppKeymap)
            : false
        self.removeAppSettings = userDefaults.object(forKey: Keys.removeAppSettings) != nil
            ? userDefaults.bool(forKey: Keys.removeAppSettings)
            : false
        self.removeAppNetworkRules = userDefaults.object(forKey: Keys.removeAppNetworkRules) != nil
            ? userDefaults.bool(forKey: Keys.removeAppNetworkRules)
            : false
        self.removeAppEntitlements = userDefaults.object(forKey: Keys.removeAppEntitlements) != nil
            ? userDefaults.bool(forKey: Keys.removeAppEntitlements)
            : false
        self.removePlayChain = userDefaults.object(forKey: Keys.removePlayChain) != nil
            ? userDefaults.bool(forKey: Keys.removePlayChain)
            : false
        self.showUninstallPopup = userDefaults.object(forKey: Keys.showUninstallPopup) != nil
            ? userDefaults.bool(forKey: Keys.showUninstallPopup)
            : true
    }
}
