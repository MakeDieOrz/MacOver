//
//  Downloader.swift
//  PlayCover
//
//  Created by Amir Mohammadi on 9/26/1401 AP.
//

import Foundation
import DownloadManager

/// DownloaderManager can be configured through this struct, default values are as the same as below
/// `public struct DownloadManagerConfig {`
///    `public var maximumRetries = 3`
///    `public var exponentialBackoffMultiplier = 10`
///    `public var usesNotificationCenter = false`
///    `public var showsLocalNotifications = false`
///    `public var logVerbosity: LogVerbosity = .none
/// `}`
///  Use `downloader.configuration = DownloadManagerConfig()` in
///  `DownloadApp` class before `downloader.addDownload` to apply
///  More details: https://github.com/shapedbyiris/download-manager/blob/master/README.md

class DownloadApp {
    let url: URL?
    let app: SourceAppsData?
    let warning: String?
    private weak var dependencies: PlayCoverDependencies?

    private var activeDownloadDir: URL?

    init(
        url: URL?,
        app: SourceAppsData?,
        warning: String?,
        dependencies: PlayCoverDependencies? = nil
    ) {
        self.url = url
        self.app = app
        self.warning = warning
        self.dependencies = dependencies
        self.downloadVM = dependencies?.downloadVM ?? DownloadVM()
        self.installVM = dependencies?.installVM ?? InstallVM()
    }

    let downloadVM: DownloadVM
    let installVM: InstallVM
    let downloader = DownloadManager.shared

    private func cleanupDownloadDir(_ dir: URL? = nil) {
        let target = dir ?? activeDownloadDir
        if let target {
            FileManager.default.delete(at: target)
            if target == activeDownloadDir {
                activeDownloadDir = nil
            }
        }
    }

    @MainActor
    func start() {
        if installVM.inProgress {
            PlayCoverDiagnostics.reportError(PlayCoverError.waitInstallation)
            return
        }
        let presenter = dependencies?.alertPresenter ?? AlertPresenter()
        let installPrefs = dependencies?.installPreferences
        Task { @MainActor in
            if let app = app, PlayApp.PROHIBITED_APPS.contains(app.bundleID) {
                let response = await presenter.present(
                    PlayCoverAlertRequest(
                        title: NSLocalizedString("alert.error", comment: ""),
                        message: String(
                            format: NSLocalizedString("error.appProhibited", comment: ""),
                            arguments: [app.name]
                        ),
                        style: .warning,
                        buttons: [
                            PlayCoverAlertButton(title: NSLocalizedString("Ok", comment: ""), isCancel: true),
                            PlayCoverAlertButton(title: NSLocalizedString("alert.download.downloadAnyway", comment: ""))
                        ],
                        defaultCancelIndex: 0
                    )
                )
                if response.buttonIndex == 0 {
                    return
                }
            }

            if let warningMessage = warning, let app = app {
                let response = await presenter.present(
                    PlayCoverAlertRequest(
                        title: NSLocalizedString(warningMessage, comment: ""),
                        message: String(
                            format: NSLocalizedString("alert.install.anyway", comment: ""),
                            arguments: [app.name]
                        ),
                        style: .warning,
                        buttons: [
                            PlayCoverAlertButton(title: NSLocalizedString("button.Yes", comment: "")),
                            PlayCoverAlertButton(title: NSLocalizedString("button.No", comment: ""), isCancel: true)
                        ],
                        defaultCancelIndex: 1
                    )
                )
                if response.buttonIndex == 1 {
                    return
                }
            }
            if let url = url, let app = app {
                let ipa = IPA(url: url)
                if await ipa.checkOfficialMacOS(
                    app: IPA.Application.store(app),
                    alertPresenter: presenter,
                    installPreferences: installPrefs
                ) {
                    cancel()
                } else {
                    if url.isFileURL {
                        proceedInstall(url, deleteIPA: false)
                    } else {
                        let (finalURL, urlIsValid) = await NetworkVM.isURLAccessible(url: url, popup: true)
                        if urlIsValid, let newWrappedURL = finalURL {
                            proceedDownload(newWrappedURL)
                        }
                    }
                }
            }
        }
    }

    func cancel() {
        downloader.cancelAllDownloads()
        cleanupDownloadDir()

        Task { @MainActor in
            downloadVM.next(.canceled, 0.95, 1.0)
            downloadVM.storeAppData = nil
        }
    }

    private func proceedDownload(_ finalURL: URL) {
        Task { @MainActor in
            self.downloadVM.storeAppData = self.app
            self.downloadVM.next(.downloading, 0.0, 0.7)
        }

        var tmpDir: URL?
        do {
            tmpDir = try FileManager.default.url(for: .itemReplacementDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: FileManager.default.temporaryDirectory,
                                                 create: true)
            activeDownloadDir = tmpDir

            if let tmpDir = tmpDir {
                downloader.addDownload(url: finalURL,
                                       destinationURL: tmpDir,
                                       onProgress: { progress in
                    Task { @MainActor in
                        self.downloadVM.progress = Double(progress)
                    }
                }, onCompletion: { error, fileURL in
                    Task { @MainActor in
                        self.downloadVM.next(.integrity, 0.7, 0.95)

                        if let error = error {
                            self.downloadVM.next(.failed, 0.95, 1.0)
                            self.downloadVM.storeAppData = nil
                            self.cleanupDownloadDir(tmpDir)
                            PlayCoverDiagnostics.reportError(error)
                            return
                        }

                        self.verifyChecksum(checksum: self.downloadVM.storeAppData?.checksum,
                                            file: fileURL) { completing in
                            Task { @MainActor in
                                self.downloadVM.next(completing ? .finish : .failed, 0.95, 1.0)
                                if completing {
                                    self.proceedInstall(fileURL, downloadDir: tmpDir)
                                } else {
                                    self.downloadVM.storeAppData = nil
                                    self.cleanupDownloadDir(tmpDir)
                                }
                            }
                        }
                    }
                })
            }
        } catch {
            Task { @MainActor in
                self.downloadVM.next(.failed, 0.95, 1.0)
                self.downloadVM.storeAppData = nil
            }
            cleanupDownloadDir(tmpDir)
            PlayCoverDiagnostics.reportError(error)
        }
    }

    private func verifyChecksum(checksum: String?, file: URL?, completion: @escaping (Bool) -> Void) {
        Task.detached(priority: .userInitiated) {
            if let originalSum = checksum, !originalSum.isEmpty, let fileURL = file {
                if let sha256 = fileURL.sha256, originalSum != sha256 {
                    self.checksumAlert(originalSum: originalSum, givenSum: sha256, completion: completion)
                    return
                }
            }

            completion(true)
        }
    }

    private func checksumAlert(originalSum: String, givenSum: String, completion: @escaping (Bool) -> Void) {
        let presenter = dependencies?.alertPresenter ?? AlertPresenter()
        Task { @MainActor in
            let response = await presenter.present(
                PlayCoverAlertRequest(
                    title: NSLocalizedString("playapp.download.differentChecksum", comment: ""),
                    message: String(
                        format: NSLocalizedString("playapp.download.differentChecksumDesc", comment: ""),
                        arguments: [originalSum, givenSum]
                    ),
                    style: .warning,
                    buttons: [
                        PlayCoverAlertButton(title: NSLocalizedString("button.Proceed", comment: "")),
                        PlayCoverAlertButton(title: NSLocalizedString("button.Cancel", comment: ""), isCancel: true)
                    ],
                    defaultCancelIndex: 1
                )
            )
            completion(response.buttonIndex == 0)
        }
    }

    private func proceedInstall(_ url: URL?, downloadDir: URL? = nil, deleteIPA: Bool = true) {
        if let url = url {
            let deps = dependencies
            Installer.install(ipaUrl: url, export: false, dependencies: deps, returnCompletion: { finalURL in
                Task { @MainActor in
                    if deleteIPA {
                        FileManager.default.delete(at: url)
                        self.cleanupDownloadDir(downloadDir)
                    }
                    deps?.appsVM.fetchApps()
                    deps?.storeVM.resolveSources()
                    if finalURL != nil {
                        deps?.notifyService.notify(
                            NSLocalizedString("notification.appInstalled", comment: ""),
                            NSLocalizedString("notification.appInstalled.message", comment: ""))
                    }
                    self.downloadVM.storeAppData = nil
                }
            })
        } else if deleteIPA {
            cleanupDownloadDir(downloadDir)
        }
    }
}
