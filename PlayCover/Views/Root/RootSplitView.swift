//
//  RootSplitView.swift
//  PlayCover
//

import SwiftUI
import UniformTypeIdentifiers

struct RootSplitView: View {
    @Environment(PlayCoverDependencies.self) var dependencies
    @Environment(AppsVM.self) var appsVM
    @Environment(StoreVM.self) var storeVM
    @Environment(AppIntegrity.self) var integrity
    @Environment(AlertPresenter.self) var alertPresenter
    @Environment(KeyCoverObservable.self) var keyCoverObserved
    @Environment(StartupAlertCenter.self) var startupAlerts
    @Environment(URLObservable.self) var urlObserved
    @Environment(InstallVM.self) var installVM
    @Environment(DownloadVM.self) var downloadVM
    @Environment(AppNavigationState.self) var navState

    var autoFetchOnAppear: Bool = true

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var dropTargeted = false

    private var configTargetApp: PlayApp? {
        guard let targetID = navState.configTargetID else { return nil }
        return appsVM.apps.first(where: { $0.id == targetID })
    }

    var body: some View {
        @Bindable var navState = navState
        @Bindable var integrity = integrity
        @Bindable var keyCoverObserved = keyCoverObserved
        @Bindable var startupAlerts = startupAlerts
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Group {
                if let app = configTargetApp {
                    ConfigSidebar(app: app, settings: app.settings)
                } else {
                    LibrarySidebar()
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 6) {
                VStack(spacing: 6) {
                    ActivityCapsule()
                    SigningStatusCapsule()
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 300)
        } detail: {
            detailContent
                .inspector(isPresented: $navState.showInspector) {
                    InspectorRouter()
                        .inspectorColumnWidth(min: 260, ideal: 296, max: 360)
                }
        }
        .overlay(alignment: .bottom) {
            GlassToastStack()
        }
        .overlay {
            if dropTargeted {
                IPADropOverlay()
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDroppedURLs(urls)
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
        .onAppear {
            if urlObserved.type == .source {
                navState.sidebarDestination = .storeAll
            }
            if autoFetchOnAppear {
                appsVM.fetchApps()
            }
        }
        .onChange(of: urlObserved.action) {
            if urlObserved.type == .source {
                navState.closeConfiguration()
                navState.sidebarDestination = .storeAll
            }
        }
        .onChange(of: navState.pendingImportIPATrigger) { _, trigger in
            guard trigger != nil else { return }
            selectAndInstallIPA()
        }
        .sheet(isPresented: $navState.isSigningSetupShown) {
            SigningGuideView(isSigningSetupShown: $navState.isSigningSetupShown)
        }
        .sheet(isPresented: $keyCoverObserved.isKeyCoverUnlockingPromptShown) {
            KeyCoverUnlockingPrompt()
                .environment(dependencies)
                .environment(keyCoverObserved)
        }
        .background(alertSheetHost)
        .alert("alert.moveAppToApplications.title", isPresented: $integrity.integrityOff) {
            Button("alert.moveAppToApplications.move", role: .cancel) {
                integrity.moveToApps()
            }
            .tint(.accentColor)
            .keyboardShortcut(.defaultAction)
        } message: {
            Text("alert.moveAppToApplications.subtitle")
        }
        .alert(item: $startupAlerts.activeAlert) { alertItem in
            startupAlert(for: alertItem)
        }
        .frame(minWidth: 1024, minHeight: 600)
    }

    @ViewBuilder
    private var detailContent: some View {
        if let app = configTargetApp {
            AppConfigurationView(app: app, settings: app.settings)
                .id(app.id)
        } else {
            switch navState.sidebarDestination ?? .library {
            case .library:
                AppLibraryDetailView()
            case .storeAll:
                StoreLibraryDetailView(sourceID: nil)
            case let .storeSource(sourceID):
                StoreLibraryDetailView(sourceID: sourceID)
            }
        }
    }

    private var alertSheetHost: some View {
        Color.clear.sheet(
            item: Binding(
                get: { alertPresenter.activeRequest },
                set: { newValue in
                    if newValue == nil, let prev = alertPresenter.activeRequest {
                        alertPresenter.handleDismissed(requestID: prev.id)
                    }
                }
            )
        ) { request in
            PlayCoverAlertSheet(request: request) { response in
                alertPresenter.resolveActive(with: response)
            }
        }
    }

    private func startupAlert(for item: StartupAlertItem) -> Alert {
        switch item {
        case .lowPowerMode:
            return Alert(
                title: Text("alert.power.title"),
                message: Text("alert.power.subtitle"),
                primaryButton: .default(Text("button.OK")) {
                    startupAlerts.dismissCurrent()
                },
                secondaryButton: .cancel(Text("alert.supression")) {
                    UserDefaults.standard.set(false, forKey: "ShowLowPowerModeAlert")
                    startupAlerts.dismissCurrent()
                }
            )
        case let .audioSampleRate(deviceID, _):
            return Alert(
                title: Text("soundAlert.messageText"),
                message: Text("soundAlert.informativeText"),
                primaryButton: .default(Text("button.OK")) {
                    dependencies.soundDeviceService.applyDefaultSampleRate(for: deviceID)
                    startupAlerts.dismissCurrent()
                },
                secondaryButton: .cancel(Text("button.Cancel")) {
                    startupAlerts.dismissCurrent()
                }
            )
        case let .safeModeActivated(appName, _, breadcrumbPath):
            return Alert(
                title: Text(String(
                    format: NSLocalizedString("safeMode.alert.title", comment: ""),
                    appName
                )),
                message: Text(String(
                    format: NSLocalizedString("safeMode.alert.message", comment: ""),
                    appName
                )),
                primaryButton: .default(Text("button.OK")) {
                    startupAlerts.dismissCurrent()
                },
                secondaryButton: .destructive(Text("safeMode.alert.clear")) {
                    try? FileManager.default.removeItem(atPath: breadcrumbPath)
                    startupAlerts.dismissCurrent()
                }
            )
        }
    }

    private func selectAndInstallIPA() {
        guard !installVM.inProgress else {
            PlayCoverDiagnostics.reportError(PlayCoverError.waitInstallation)
            return
        }
        guard !downloadVM.inProgress else {
            PlayCoverDiagnostics.reportError(PlayCoverError.waitDownload)
            return
        }
        NSOpenPanel.selectIPA { result in
            if case .success(let url) = result {
                installApp(at: url)
            }
        }
    }

    private func handleDroppedURLs(_ urls: [URL]) -> Bool {
        guard let url = urls.first else { return false }
        guard !installVM.inProgress else {
            PlayCoverDiagnostics.reportError(PlayCoverError.waitInstallation)
            return false
        }
        guard !downloadVM.inProgress else {
            PlayCoverDiagnostics.reportError(PlayCoverError.waitDownload)
            return false
        }
        guard url.pathExtension.lowercased() == "ipa" else {
            PlayCoverDiagnostics.showToast(
                toastType: .error,
                toastDetails: NSLocalizedString("alert.wrongFileType.subtitle", comment: "")
            )
            return false
        }
        installApp(at: url)
        return true
    }

    private func installApp(at url: URL) {
        Installer.install(ipaUrl: url, export: false, dependencies: dependencies) { finalURL in
            Task { @MainActor in
                appsVM.fetchApps()
                if finalURL != nil {
                    dependencies.notifyService.notify(
                        NSLocalizedString("notification.appInstalled", comment: ""),
                        NSLocalizedString("notification.appInstalled.message", comment: "")
                    )
                }
            }
        }
    }
}
