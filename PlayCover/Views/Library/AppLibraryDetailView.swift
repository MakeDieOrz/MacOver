//
//  AppLibraryDetailView.swift
//  PlayCover
//

import SwiftUI

struct AppLibraryDetailView: View {
    @Environment(PlayCoverDependencies.self) var dependencies
    @Environment(AppsVM.self) var appsVM
    @Environment(InstallVM.self) var installVM
    @Environment(DownloadVM.self) var downloadVM
    @Environment(AppNavigationState.self) var navState

    @FocusState private var isGridFocused: Bool
    @State private var scrollViewportSize: CGSize = .zero
    @State private var clearPrefsApp: PlayApp?
    @State private var clearPlayChainApp: PlayApp?
    @State private var showLegacyConvertAlert = false

    private let gridColumns = [
        GridItem(.adaptive(minimum: 148, maximum: 170), spacing: 14)
    ]

    private var estimatedColumnCount: Int {
        let availableWidth = max(0, scrollViewportSize.width - 36)
        return max(1, Int((availableWidth + 14) / (148 + 14)))
    }

    private var selectedApp: PlayApp? {
        guard let selectedAppID = navState.selectedAppID else { return nil }
        return appsVM.apps.first(where: { $0.id == selectedAppID })
    }

    var body: some View {
        @Bindable var navState = navState
        Group {
            if appsVM.updatingApps && appsVM.apps.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appsVM.apps.isEmpty {
                emptyLibraryView
            } else if appsVM.filteredApps.isEmpty {
                ContentUnavailableView.search(text: navState.searchText)
            } else if navState.libraryLayout == .table {
                AppTableView(
                    apps: appsVM.filteredApps,
                    onClearPreferences: { clearPrefsApp = $0 },
                    onClearPlayChain: { clearPlayChainApp = $0 }
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: gridColumns, spacing: 14) {
                            ForEach(appsVM.filteredApps) { app in
                                AppCardView(
                                    app: app,
                                    isSelected: navState.selectedAppID == app.id,
                                    onSelect: {
                                        navState.selectedAppID = app.id
                                        isGridFocused = true
                                    },
                                    onClearPreferences: { clearPrefsApp = $0 },
                                    onClearPlayChain: { clearPlayChainApp = $0 }
                                )
                                .id(app.id)
                            }
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, minHeight: scrollViewportSize.height, alignment: .top)
                        .background {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    navState.selectedAppID = nil
                                }
                        }
                        .animation(.snappy(duration: 0.24), value: appsVM.filteredApps.map(\.id))
                    }
                    .onGeometryChange(for: CGSize.self) { geo in
                        geo.size
                    } action: { newSize in
                        scrollViewportSize = newSize
                    }
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .focusable()
                    .focused($isGridFocused)
                    .focusEffectDisabled()
                    .onKeyPress(.leftArrow) { moveGridSelection(delta: -1) }
                    .onKeyPress(.rightArrow) { moveGridSelection(delta: 1) }
                    .onKeyPress(.upArrow) { moveGridSelection(delta: -estimatedColumnCount) }
                    .onKeyPress(.downArrow) { moveGridSelection(delta: estimatedColumnCount) }
                    .onKeyPress(.return) { launchOrActivateSelectedApp() }
                    .onKeyPress(.space) {
                        if navState.selectedAppID == nil, let first = appsVM.filteredApps.first {
                            navState.selectedAppID = first.id
                        }
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard navState.selectedAppID != nil else { return .ignored }
                        navState.selectedAppID = nil
                        return .handled
                    }
                    .onChange(of: navState.selectedAppID) { _, newID in
                        guard let newID else { return }
                        withAnimation(.snappy(duration: 0.2)) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
            }
        }
        .navigationTitle("sidebar.appLibrary")
        .onChange(of: navState.searchText) { _, newQuery in
            appsVM.searchText = newQuery
            appsVM.applyFilter()
        }
        .onAppear {
            appsVM.searchText = navState.searchText
            appsVM.applyFilter()
            showLegacyConvertAlert = LegacySettings.doesMonolithExist
            if navState.libraryLayout == .grid {
                isGridFocused = true
            }
        }
        .onChange(of: navState.libraryLayout) { _, newLayout in
            if newLayout == .grid {
                isGridFocused = true
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    navState.pendingImportIPATrigger = UUID()
                } label: {
                    Label("playapp.add", systemImage: "plus")
                }
                .help("playapp.add")

                Button {
                    if let selectedApp {
                        navState.openConfiguration(for: selectedApp, pane: .overview)
                    }
                } label: {
                    Label("action.configure", systemImage: "slider.horizontal.3")
                }
                .disabled(selectedApp == nil)
                .help("action.configure")
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItemGroup(placement: .primaryAction) {
                Picker("sidebar.layoutPicker", selection: $navState.libraryLayout) {
                    Image(systemName: "square.grid.2x2")
                        .accessibilityLabel(Text("sidebar.layoutPicker"))
                        .tag(LibraryLayoutMode.grid)
                    Image(systemName: "tablecells")
                        .accessibilityLabel(Text("library.table.app"))
                        .tag(LibraryLayoutMode.table)
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
        .alert("alert.app.preferences", isPresented: Binding(
            get: { clearPrefsApp != nil },
            set: { if !$0 { clearPrefsApp = nil } }
        )) {
            Button("button.Proceed", role: .destructive) {
                if let target = clearPrefsApp, !target.isRunning, !target.isBusy {
                    target.deletePreferences()
                }
                clearPrefsApp = nil
            }
            Button("button.Cancel", role: .cancel) { clearPrefsApp = nil }
        }
        .alert("alert.app.clearPlayChain", isPresented: Binding(
            get: { clearPlayChainApp != nil },
            set: { if !$0 { clearPlayChainApp = nil } }
        )) {
            Button("button.Proceed", role: .destructive) {
                if let target = clearPlayChainApp, !target.isRunning, !target.isBusy {
                    target.clearPlayChain()
                    ConfigInfoPane.removeResidualPlayChainArtifacts(for: target.info.bundleIdentifier)
                }
                clearPlayChainApp = nil
            }
            Button("button.Cancel", role: .cancel) { clearPlayChainApp = nil }
        }
        .alert("alert.legacyImport.title", isPresented: $showLegacyConvertAlert) {
            Button("button.Convert", role: .destructive) {
                LegacySettings.convertLegacyMonolithPlist(LegacySettings.monolithURL)
                do {
                    try FileManager.default.removeItem(at: LegacySettings.monolithURL)
                } catch {
                    PlayCoverDiagnostics.reportError(error)
                }
            }
            .keyboardShortcut(.defaultAction)
            Button("button.Cancel", role: .cancel) {}
        } message: {
            Text("alert.legacyImport.subtitle")
        }
    }

    private var emptyLibraryView: some View {
        ContentUnavailableView {
            Label("playapp.noSources.title", systemImage: "square.grid.2x2")
        } description: {
            VStack(spacing: 6) {
                Text("playapp.noSources.subtitle")
                Text("library.empty.dropHint")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } actions: {
            Button("playapp.importIPA") {
                navState.pendingImportIPATrigger = UUID()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func moveGridSelection(delta: Int) -> KeyPress.Result {
        let apps = appsVM.filteredApps
        guard !apps.isEmpty else { return .ignored }
        guard let currentID = navState.selectedAppID,
              let currentIndex = apps.firstIndex(where: { $0.id == currentID }) else {
            navState.selectedAppID = delta < 0 ? apps.last?.id : apps.first?.id
            return .handled
        }
        let nextIndex = min(max(currentIndex + delta, 0), apps.count - 1)
        navState.selectedAppID = apps[nextIndex].id
        return .handled
    }

    private func launchOrActivateSelectedApp() -> KeyPress.Result {
        guard let app = selectedApp,
              appsVM.filteredApps.contains(where: { $0.id == app.id }) else {
            return .ignored
        }
        if app.isRunning, app.activateRunningApplication() {
            return .handled
        }
        Task(priority: .userInitiated) {
            if !app.isBusy {
                await app.launch()
            }
        }
        return .handled
    }
}
