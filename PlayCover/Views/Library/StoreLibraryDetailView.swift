//
//  StoreLibraryDetailView.swift
//  PlayCover
//

import AppKit
import SwiftUI

struct StoreLibraryDetailView: View {
    @Environment(\.appearsActive) private var appearsActive
    @Environment(PlayCoverDependencies.self) var dependencies
    @Environment(StoreVM.self) var storeVM
    @Environment(AppsVM.self) var appsVM
    @Environment(DownloadVM.self) var downloadVM
    @Environment(InstallVM.self) var installVM
    @Environment(URLObservable.self) var urlObserved
    @Environment(AppNavigationState.self) var navState

    let sourceID: UUID?

    @State private var isList = UserDefaults.standard.bool(forKey: "IPALibraryView")
    @State private var sortAlphabetical = UserDefaults.standard.bool(forKey: "IPASourceAlphabetically")
    @State private var addSourcePresented = false
    @State private var isConnected: Bool?

    private let gridColumns = [
        GridItem(.adaptive(minimum: 148, maximum: 170), spacing: 14)
    ]

    private var activeSource: SourceJSON? {
        guard let sourceID else { return nil }
        return storeVM.getEnabledSources().first(where: { $0.id == sourceID })
    }

    private var baseApps: [SourceAppsData] {
        activeSource?.data ?? storeVM.sourcesApps
    }

    private var trimmedSearchText: String {
        navState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleApps: [SourceAppsData] {
        let ordered = sortAlphabetical
            ? baseApps.sorted { $0.name.lowercased() < $1.name.lowercased() }
            : baseApps
        guard !trimmedSearchText.isEmpty else { return ordered }
        return ordered.filter { $0.name.localizedCaseInsensitiveContains(trimmedSearchText) }
    }

    private var hasEnabledConfiguredSources: Bool {
        storeVM.sourcesList.contains(where: \.isEnabled)
    }

    private var isResolvingSources: Bool {
        storeVM.sourcesList.contains(where: { $0.isEnabled && $0.status == .checking })
    }

    private var isInitialLoading: Bool {
        if isConnected == nil {
            return true
        }
        return isConnected == true && hasEnabledConfiguredSources && baseApps.isEmpty && isResolvingSources
    }

    private var navigationTitleText: String {
        activeSource?.name ?? NSLocalizedString("sidebar.ipaLibrary", comment: "")
    }

    var body: some View {
        let enabledSources = storeVM.getEnabledSources()
        Group {
            if isInitialLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isConnected == false {
                ContentUnavailableView {
                    Label("ipaLibrary.noNetworkConnection.toast", systemImage: "wifi.slash")
                } description: {
                    Text("ipaLibrary.noNetworkConnection.required")
                } actions: {
                    Button("button.Reload") {
                        Task { await checkConnectivity(resolveSources: true) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if !hasEnabledConfiguredSources && enabledSources.isEmpty {
                ContentUnavailableView {
                    Label("ipaLibrary.noSources.title", systemImage: "tray")
                } description: {
                    Text("ipaLibrary.noSources.subtitle")
                } actions: {
                    Button("ipaLibrary.noSources.button") {
                        addSourcePresented = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if visibleApps.isEmpty && !trimmedSearchText.isEmpty {
                ContentUnavailableView.search(text: navState.searchText)
            } else if visibleApps.isEmpty {
                ContentUnavailableView {
                    Label("ipaLibrary.noSources.title", systemImage: "tray")
                } description: {
                    Text("ipaLibrary.noSources.subtitle")
                } actions: {
                    Button("button.Reload") {
                        Task { await checkConnectivity(resolveSources: true) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    if isList {
                        LazyVStack(spacing: 6) {
                            ForEach(visibleApps, id: \.self) { app in
                                StoreItemTileView(
                                    app: app,
                                    isList: true,
                                    isSelected: navState.selectedStoreApp == app,
                                    appearsActive: appearsActive,
                                    onSelect: { navState.selectedStoreApp = app },
                                    onDownload: { startDownload(for: app) },
                                    onCopyBundleID: { copyBundleID(for: app) }
                                )
                            }
                        }
                        .padding(16)
                    } else {
                        LazyVGrid(columns: gridColumns, spacing: 14) {
                            ForEach(visibleApps, id: \.self) { app in
                                StoreItemTileView(
                                    app: app,
                                    isList: false,
                                    isSelected: navState.selectedStoreApp == app,
                                    appearsActive: appearsActive,
                                    onSelect: { navState.selectedStoreApp = app },
                                    onDownload: { startDownload(for: app) },
                                    onCopyBundleID: { copyBundleID(for: app) }
                                )
                            }
                        }
                        .padding(18)
                    }
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .contentShape(Rectangle())
                .onTapGesture {
                    navState.selectedStoreApp = nil
                }
            }
        }
        .navigationTitle(navigationTitleText)
        .task {
            await checkConnectivity(resolveSources: false)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    addSourcePresented = true
                } label: {
                    Label("playapp.addSource", systemImage: "plus")
                }
                .help("playapp.addSource")

                Button {
                    Task { await checkConnectivity(resolveSources: true) }
                } label: {
                    Label("playapp.refreshSources", systemImage: "arrow.clockwise")
                }
                .disabled(!hasEnabledConfiguredSources && enabledSources.isEmpty)
                .help("playapp.refreshSources")
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItemGroup(placement: .primaryAction) {
                Toggle("A–Z", isOn: $sortAlphabetical)
                    .help("ipaLibrary.AlphabeticalSort")

                Picker("sidebar.layoutPicker", selection: $isList) {
                    Image(systemName: "square.grid.2x2")
                        .accessibilityLabel(Text("sidebar.layoutPicker"))
                        .tag(false)
                    Image(systemName: "list.bullet")
                        .accessibilityLabel(Text("library.table.app"))
                        .tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(Text("sidebar.layoutPicker"))
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    navState.showInspector.toggle()
                } label: {
                    Label("inspector.toggle", systemImage: "sidebar.right")
                }
                .help("inspector.toggle")
            }
        }
        .sheet(isPresented: $addSourcePresented) {
            AddSourceView(addSourceSheet: $addSourcePresented)
                .environment(storeVM)
                .environment(urlObserved)
        }
        .onChange(of: isList) { _, value in
            UserDefaults.standard.set(value, forKey: "IPALibraryView")
        }
        .onChange(of: sortAlphabetical) { _, value in
            UserDefaults.standard.set(value, forKey: "IPASourceAlphabetically")
        }
        .onChange(of: urlObserved.type) {
            if urlObserved.type == .source {
                addSourcePresented = true
            }
        }
        .onAppear {
            if urlObserved.type == .source {
                addSourcePresented = true
            }
        }
    }

    private func checkConnectivity(resolveSources: Bool) async {
        let connected = await NetworkVM.isConnectedToNetworkAsync()
        isConnected = connected
        if connected && resolveSources {
            storeVM.resolveSources()
        }
    }

    private func copyBundleID(for app: SourceAppsData) {
        app.bundleID.copyToClipBoard()
        dependencies.toastVM.showToast(
            toastType: .notice,
            toastDetails: "\(NSLocalizedString("action.copy", comment: "")): \(app.bundleID)"
        )
    }

    private func startDownload(for app: SourceAppsData) {
        guard let url = URL(string: app.link) else { return }
        guard !downloadVM.inProgress else {
            PlayCoverDiagnostics.reportError(PlayCoverError.waitDownload)
            return
        }
        let installedApp = appsVM.apps.first(where: { $0.info.bundleIdentifier == app.bundleID })
        let installedVersion = installedApp?.info.bundleVersion
        let warning: String?
        if let installedVersion {
            switch app.version.compare(installedVersion, options: .numeric) {
            case .orderedAscending: warning = "ipaLibrary.version.older"
            case .orderedSame: warning = "ipaLibrary.version.same"
            case .orderedDescending: warning = "ipaLibrary.version.newer"
            }
        } else {
            warning = nil
        }
        let deps = dependencies
        Task {
            let resolvedURL = await RedirectHandler.resolveDirectDownloadURL(for: url)
            await MainActor.run {
                DownloadApp(url: resolvedURL, app: app, warning: warning, dependencies: deps).start()
            }
        }
    }
}

private struct StoreBadgeDisplay {
    let symbol: String
    let helpKey: String
    let color: Color
}

private struct StoreItemTileView: View {
    @Environment(AppsVM.self) var appsVM
    @Environment(DownloadVM.self) var downloadVM

    let app: SourceAppsData
    let isList: Bool
    let isSelected: Bool
    let appearsActive: Bool
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onCopyBundleID: () -> Void

    @State private var isHovered = false

    private var badgeInfo: StoreBadgeDisplay {
        guard let installed = appsVM.apps.first(where: { $0.info.bundleIdentifier == app.bundleID }) else {
            return StoreBadgeDisplay(symbol: "arrow.down.circle", helpKey: "ipaLibrary.download", color: .secondary)
        }
        switch app.version.compare(installed.info.bundleVersion, options: .numeric) {
        case .orderedAscending:
            return StoreBadgeDisplay(
                symbol: "checkmark.circle.badge.xmark",
                helpKey: "ipaLibrary.version.older",
                color: .orange
            )
        case .orderedSame:
            return StoreBadgeDisplay(symbol: "checkmark.circle", helpKey: "ipaLibrary.version.same", color: .green)
        case .orderedDescending:
            return StoreBadgeDisplay(
                symbol: "checkmark.circle.trianglebadge.exclamationmark",
                helpKey: "ipaLibrary.version.newer",
                color: .blue
            )
        }
    }

    private var backgroundFill: Color {
        if isSelected {
            return appearsActive ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.14)
        }
        if isHovered {
            return Color.secondary.opacity(0.08)
        }
        return Color.clear
    }

    var body: some View {
        let info = badgeInfo
        Group {
            if isList {
                HStack(spacing: 12) {
                    Image(systemName: info.symbol)
                        .foregroundStyle(info.color)
                        .help(NSLocalizedString(info.helpKey, comment: ""))
                    StoreAppIconView(app: app, size: 32, cornerRadius: 8)
                    Text(app.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer()
                    if downloadVM.inProgress && downloadVM.storeAppData == app {
                        ProgressView(value: downloadVM.progress)
                            .frame(width: 70)
                    }
                    Text(app.version)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 10) {
                    ZStack(alignment: .bottom) {
                        StoreAppIconView(app: app, size: 72, cornerRadius: 17)
                        if downloadVM.inProgress && downloadVM.storeAppData == app {
                            ProgressView(value: downloadVM.progress)
                                .padding(6)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                    VStack(spacing: 2) {
                        Label {
                            Text(app.name)
                                .foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: info.symbol)
                                .foregroundStyle(info.color)
                        }
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        Text(app.version)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .help(NSLocalizedString(info.helpKey, comment: ""))
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .frame(height: 156)
            }
        }
        .background(RoundedRectangle(cornerRadius: isList ? 10 : 16, style: .continuous).fill(backgroundFill))
        .overlay(
            RoundedRectangle(cornerRadius: isList ? 10 : 16, style: .continuous)
                .strokeBorder(
                    isSelected && appearsActive
                        ? Color.accentColor
                        : (isHovered ? Color.primary.opacity(0.08) : Color.clear),
                    lineWidth: isSelected && appearsActive ? 2 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: isList ? 10 : 16, style: .continuous))
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.16)) {
                isHovered = hovering
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(app.name))
        .accessibilityValue(Text("\(app.version), \(NSLocalizedString(info.helpKey, comment: ""))"))
        .accessibilityHint(Text("store.downloadInstall"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            onSelect()
        }
        .accessibilityAction(named: Text("store.downloadInstall")) {
            onDownload()
        }
        .gesture(TapGesture(count: 2).onEnded {
            onSelect()
            onDownload()
        })
        .simultaneousGesture(TapGesture().onEnded {
            onSelect()
        })
        .contextMenu {
            Button("store.downloadInstall", systemImage: "arrow.down.circle") {
                onDownload()
            }
            .disabled(downloadVM.inProgress)

            Divider()

            Button("action.copy", systemImage: "doc.on.doc") {
                onCopyBundleID()
            }

            if let downloadURL = URL(string: app.link) {
                Button("settings.info.url", systemImage: "link") {
                    NSWorkspace.shared.open(downloadURL)
                }
            }

            if let lookupURL = URL(string: app.itunesLookup) {
                Button("ipaLibrary.info.itunes", systemImage: "arrow.up.right.square") {
                    NSWorkspace.shared.open(lookupURL)
                }
            }
        }
    }
}
