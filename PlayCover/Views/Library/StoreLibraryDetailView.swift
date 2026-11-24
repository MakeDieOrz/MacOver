//
//  StoreLibraryDetailView.swift
//  PlayCover
//

import SwiftUI

struct StoreLibraryDetailView: View {
    @Environment(\.appearsActive) private var appearsActive
    @EnvironmentObject var dependencies: PlayCoverDependencies
    @EnvironmentObject var storeVM: StoreVM
    @EnvironmentObject var appsVM: AppsVM
    @EnvironmentObject var downloadVM: DownloadVM
    @EnvironmentObject var installVM: InstallVM
    @EnvironmentObject var urlObserved: URLObservable
    @EnvironmentObject var navState: AppNavigationState

    let sourceID: UUID?

    @State private var isList = UserDefaults.standard.bool(forKey: "IPALibraryView")
    @State private var sortAlphabetical = UserDefaults.standard.bool(forKey: "IPASourceAlphabetically")
    @State private var addSourcePresented = false

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

    private var visibleApps: [SourceAppsData] {
        let ordered = sortAlphabetical
            ? baseApps.sorted { $0.name.lowercased() < $1.name.lowercased() }
            : baseApps
        let trimmed = navState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ordered }
        return ordered.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var navigationTitleText: String {
        activeSource?.name ?? NSLocalizedString("sidebar.ipaLibrary", comment: "")
    }

    var body: some View {
        let enabledSources = storeVM.getEnabledSources()
        Group {
            if !NetworkVM.isConnectedToNetwork() {
                ContentUnavailableView {
                    Label("ipaLibrary.noNetworkConnection.toast", systemImage: "wifi.slash")
                } description: {
                    Text("ipaLibrary.noNetworkConnection.required")
                } actions: {
                    Button("button.Reload") {
                        storeVM.resolveSources()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if enabledSources.isEmpty {
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
            } else {
                ScrollView {
                    if isList {
                        LazyVStack(spacing: 6) {
                            ForEach(visibleApps, id: \.bundleID) { app in
                                StoreItemTileView(
                                    app: app,
                                    isList: true,
                                    isSelected: navState.selectedStoreApp?.bundleID == app.bundleID,
                                    appearsActive: appearsActive,
                                    onSelect: { navState.selectedStoreApp = app },
                                    onDownload: { startDownload(for: app) }
                                )
                            }
                        }
                        .padding(16)
                    } else {
                        LazyVGrid(columns: gridColumns, spacing: 14) {
                            ForEach(visibleApps, id: \.bundleID) { app in
                                StoreItemTileView(
                                    app: app,
                                    isList: false,
                                    isSelected: navState.selectedStoreApp?.bundleID == app.bundleID,
                                    appearsActive: appearsActive,
                                    onSelect: { navState.selectedStoreApp = app },
                                    onDownload: { startDownload(for: app) }
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
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    addSourcePresented = true
                } label: {
                    Label("playapp.addSource", systemImage: "plus")
                }
                .help("playapp.addSource")

                Button {
                    storeVM.resolveSources()
                } label: {
                    Label("playapp.refreshSources", systemImage: "arrow.clockwise")
                }
                .disabled(enabledSources.isEmpty)
                .help("playapp.refreshSources")
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItemGroup(placement: .primaryAction) {
                Toggle("A–Z", isOn: $sortAlphabetical)
                    .help("ipaLibrary.AlphabeticalSort")

                Picker("sidebar.layoutPicker", selection: $isList) {
                    Image(systemName: "square.grid.2x2").tag(false)
                    Image(systemName: "list.bullet").tag(true)
                }
                .pickerStyle(.segmented)
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
                .environmentObject(storeVM)
                .environmentObject(urlObserved)
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
    @EnvironmentObject var appsVM: AppsVM
    @EnvironmentObject var downloadVM: DownloadVM

    let app: SourceAppsData
    let isList: Bool
    let isSelected: Bool
    let appearsActive: Bool
    let onSelect: () -> Void
    let onDownload: () -> Void

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
                VStack(spacing: 8) {
                    ZStack(alignment: .bottom) {
                        StoreAppIconView(app: app, size: 72, cornerRadius: 17)
                        if downloadVM.inProgress && downloadVM.storeAppData == app {
                            ProgressView(value: downloadVM.progress)
                                .padding(6)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                    VStack(spacing: 2) {
                        Label(app.name, systemImage: info.symbol)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(app.version)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .help(NSLocalizedString(info.helpKey, comment: ""))
                }
                .padding(10)
                .frame(width: 148, height: 148)
            }
        }
        .background(RoundedRectangle(cornerRadius: isList ? 10 : 16, style: .continuous).fill(backgroundFill))
        .overlay(
            RoundedRectangle(cornerRadius: isList ? 10 : 16, style: .continuous)
                .strokeBorder(isSelected && appearsActive ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: isList ? 10 : 16, style: .continuous))
        .gesture(TapGesture(count: 2).onEnded {
            onDownload()
        })
        .simultaneousGesture(TapGesture().onEnded {
            onSelect()
        })
    }
}
