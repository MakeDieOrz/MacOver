import Foundation
import SwiftUI

final class PlayCoverDependencies: ObservableObject, @unchecked Sendable {
    let alertPresenter: AlertPresenter
    let startupAlerts: StartupAlertCenter
    let toastVM: ToastVM
    let modifierKeyObserver: ModifierKeyObserver
    let keyCoverPreferences: KeyCoverPreferences
    let installPreferences: InstallPreferences
    let uninstallPreferences: UninstallPreferences
    let log: Log
    let keyCoverObservable: KeyCoverObservable
    let keyCoverPassword: KeyCoverPassword
    let keyCover: KeyCover
    let soundDeviceService: SoundDeviceService
    let notifyService: NotifyService
    let cacher: Cacher
    let installVM: InstallVM
    let downloadVM: DownloadVM
    let appsVM: AppsVM
    let storeVM: StoreVM
    let versionCheck: VersionCheck
    let urlObservable: URLObservable
    let urlHandler: URLHandler
    let appIntegrity: AppIntegrity

    init(
        userDefaults: UserDefaults = .standard,
        loadInitialData: Bool = !ProcessInfo.isRunningUnitTests,
        configureDiagnostics: Bool = true
    ) {
        let alertPresenter = AlertPresenter()
        let startupAlerts = StartupAlertCenter()
        let toastVM = ToastVM()
        let modifierKeyObserver = ModifierKeyObserver()
        let keyCoverPreferences = KeyCoverPreferences(userDefaults: userDefaults)
        let installPreferences = InstallPreferences(userDefaults: userDefaults)
        let uninstallPreferences = UninstallPreferences(userDefaults: userDefaults)
        let log = Log(alertPresenter: alertPresenter)
        let keyCoverObservable = KeyCoverObservable(preferences: keyCoverPreferences)
        let keyCoverPassword = KeyCoverPassword(
            preferences: keyCoverPreferences,
            observable: keyCoverObservable
        )
        let keyCover = KeyCover(
            preferences: keyCoverPreferences,
            passwordStore: keyCoverPassword,
            observable: keyCoverObservable
        )
        keyCoverPassword.attachKeyCover(keyCover)
        keyCoverObservable.attachKeyCover(keyCover)

        let soundDeviceService = SoundDeviceService(startupAlerts: startupAlerts)
        let notifyService = NotifyService()
        let cacher = Cacher()
        let installVM = InstallVM()
        let downloadVM = DownloadVM()
        let appsVM = AppsVM(loadOnInit: false)
        let storeVM = StoreVM(resolveOnInit: loadInitialData)
        let versionCheck = VersionCheck()
        let urlObservable = URLObservable()
        let urlHandler = URLHandler()
        let appIntegrity = AppIntegrity()

        self.alertPresenter = alertPresenter
        self.startupAlerts = startupAlerts
        self.toastVM = toastVM
        self.modifierKeyObserver = modifierKeyObserver
        self.keyCoverPreferences = keyCoverPreferences
        self.installPreferences = installPreferences
        self.uninstallPreferences = uninstallPreferences
        self.log = log
        self.keyCoverObservable = keyCoverObservable
        self.keyCoverPassword = keyCoverPassword
        self.keyCover = keyCover
        self.soundDeviceService = soundDeviceService
        self.notifyService = notifyService
        self.cacher = cacher
        self.installVM = installVM
        self.downloadVM = downloadVM
        self.appsVM = appsVM
        self.storeVM = storeVM
        self.versionCheck = versionCheck
        self.urlObservable = urlObservable
        self.urlHandler = urlHandler
        self.appIntegrity = appIntegrity

        appsVM.dependencies = self
        versionCheck.dependencies = self
        urlHandler.dependencies = self
        cacher.appsVM = appsVM

        if configureDiagnostics {
            PlayCoverDiagnostics.configure(
                logHandler: { [weak log] message, isError in
                    log?.log(message, isError: isError)
                },
                errorHandler: { [weak log] message in
                    log?.error(message)
                },
                messageHandler: { [weak log] message in
                    log?.msg(message)
                },
                toastHandler: { [weak toastVM] kind, details, timeRemaining in
                    let mapped: ToastType
                    switch kind {
                    case .notice:
                        mapped = .notice
                    case .error:
                        mapped = .error
                    case .network:
                        mapped = .network
                    }
                    toastVM?.showToast(toastType: mapped, toastDetails: details, timeRemaining: timeRemaining)
                },
                activeToastChecker: { [weak toastVM] kind in
                    guard let toastVM else { return false }
                    let mapped: ToastType
                    switch kind {
                    case .notice:
                        mapped = .notice
                    case .error:
                        mapped = .error
                    case .network:
                        mapped = .network
                    }
                    return toastVM.hasToast(ofType: mapped)
                }
            )
        }

        if loadInitialData {
            PlayTools.installOnSystem()
            appsVM.fetchApps()
        }
    }
}
