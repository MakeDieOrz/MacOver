import Foundation
import PlayCoverCore

public enum KeyCoverStatus: String, Codable, Hashable {
    case disabled
    case selfGeneratedPassword
    case userProvidedPassword
}

public final class KeyCoverPreferences: NSObject, ObservableObject {
    private enum Keys {
        static let keyCoverEnabled = "keyCoverEnabled"
        static let promptAtLaunch = "promptForKeyCoverPasswordAtLaunch"
    }

    private let userDefaults: UserDefaults

    @Published public var keyCoverEnabled: KeyCoverStatus {
        didSet {
            guard oldValue != keyCoverEnabled else { return }
            userDefaults.set(keyCoverEnabled.rawValue, forKey: Keys.keyCoverEnabled)
        }
    }

    @Published public var promptForKeyCoverPasswordAtLaunch: Bool {
        didSet {
            guard oldValue != promptForKeyCoverPasswordAtLaunch else { return }
            userDefaults.set(promptForKeyCoverPasswordAtLaunch, forKey: Keys.promptAtLaunch)
        }
    }

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let raw = userDefaults.string(forKey: Keys.keyCoverEnabled),
           let status = KeyCoverStatus(rawValue: raw) {
            self.keyCoverEnabled = status
        } else {
            self.keyCoverEnabled = .disabled
        }
        if userDefaults.object(forKey: Keys.promptAtLaunch) != nil {
            self.promptForKeyCoverPasswordAtLaunch = userDefaults.bool(forKey: Keys.promptAtLaunch)
        } else {
            self.promptForKeyCoverPasswordAtLaunch = true
        }
        super.init()
    }
}

public final class InstallPreferences: NSObject, ObservableObject {
    private enum Keys {
        static let alwaysInstallPlayTools = "AlwaysInstallPlayTools"
        static let defaultAppType = "DefaultAppType"
        static let showInstallPopup = "ShowInstallPopup"
        static let showAppStorePopup = "ShowAppStorePopup"
    }

    private let userDefaults: UserDefaults

    @Published public var alwaysInstallPlayTools: Bool {
        didSet {
            guard oldValue != alwaysInstallPlayTools else { return }
            userDefaults.set(alwaysInstallPlayTools, forKey: Keys.alwaysInstallPlayTools)
        }
    }

    @Published public var defaultAppType: LSApplicationCategoryType {
        didSet {
            guard oldValue != defaultAppType else { return }
            userDefaults.set(defaultAppType.rawValue, forKey: Keys.defaultAppType)
        }
    }

    @Published public var showInstallPopup: Bool {
        didSet {
            guard oldValue != showInstallPopup else { return }
            userDefaults.set(showInstallPopup, forKey: Keys.showInstallPopup)
        }
    }

    @Published public var showAppStorePopup: Bool {
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
        super.init()
    }
}

public final class UninstallPreferences: NSObject, ObservableObject {
    private enum Keys {
        static let clearAppData = "ClearAppDataUninstall"
        static let removeAppKeymap = "RemoveAppKeymapUninstall"
        static let removeAppSettings = "RemoveAppSettingUninstall"
        static let removeAppNetworkRules = "RemoveAppNetworkRulesUninstall"
        static let removeAppEntitlements = "RemoveAppEntitlementsUninstall"
        static let removePlayChain = "RemovePlayChainUninstall"
        static let showUninstallPopup = "ShowUninstallPopup"
    }

    private let userDefaults: UserDefaults

    @Published public var clearAppData: Bool {
        didSet {
            guard oldValue != clearAppData else { return }
            userDefaults.set(clearAppData, forKey: Keys.clearAppData)
        }
    }

    @Published public var removeAppKeymap: Bool {
        didSet {
            guard oldValue != removeAppKeymap else { return }
            userDefaults.set(removeAppKeymap, forKey: Keys.removeAppKeymap)
        }
    }

    @Published public var removeAppSettings: Bool {
        didSet {
            guard oldValue != removeAppSettings else { return }
            userDefaults.set(removeAppSettings, forKey: Keys.removeAppSettings)
        }
    }

    @Published public var removeAppNetworkRules: Bool {
        didSet {
            guard oldValue != removeAppNetworkRules else { return }
            userDefaults.set(removeAppNetworkRules, forKey: Keys.removeAppNetworkRules)
        }
    }

    @Published public var removeAppEntitlements: Bool {
        didSet {
            guard oldValue != removeAppEntitlements else { return }
            userDefaults.set(removeAppEntitlements, forKey: Keys.removeAppEntitlements)
        }
    }

    @Published public var removePlayChain: Bool {
        didSet {
            guard oldValue != removePlayChain else { return }
            userDefaults.set(removePlayChain, forKey: Keys.removePlayChain)
        }
    }

    @Published public var showUninstallPopup: Bool {
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
        super.init()
    }
}
