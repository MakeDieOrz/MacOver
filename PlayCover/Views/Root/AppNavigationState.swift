//
//  AppNavigationState.swift
//  PlayCover
//

import Foundation
import Observation
import SwiftUI

enum SidebarDestination: Hashable {
    case library
    case storeAll
    case storeSource(UUID)
}

enum ConfigPane: String, CaseIterable, Identifiable, Hashable {
    case overview
    case display
    case device
    case input
    case network
    case plugins
    case advanced
    case info

    var id: String { rawValue }

    var titleKey: String { "config.pane.\(rawValue)" }

    var systemImage: String {
        switch self {
        case .overview: return "slider.horizontal.3"
        case .display: return "display"
        case .device: return "ipad.landscape"
        case .input: return "keyboard"
        case .network: return "network.badge.shield.half.filled"
        case .plugins: return "puzzlepiece.extension"
        case .advanced: return "wrench.and.screwdriver"
        case .info: return "info.circle"
        }
    }
}

enum LibraryLayoutMode: String, Hashable {
    case grid
    case table
}

@MainActor
@Observable
final class AppNavigationState {
    private static let layoutDefaultsKey = "AppLibraryLayoutMode"
    private static let legacyListDefaultsKey = "AppLibraryView"

    var sidebarDestination: SidebarDestination? = .library
    var configTargetID: PlayApp.ID?
    var activeConfigPane: ConfigPane = .overview
    var selectedAppID: PlayApp.ID?
    var selectedStoreApp: SourceAppsData?
    var showInspector: Bool = true
    var isSigningSetupShown: Bool = false
    var isActivityPopoverShown: Bool = false
    var searchText: String = ""
    var pendingImportIPATrigger: UUID?
    var libraryLayout: LibraryLayoutMode {
        didSet {
            UserDefaults.standard.set(libraryLayout.rawValue, forKey: Self.layoutDefaultsKey)
            UserDefaults.standard.set(libraryLayout == .table, forKey: Self.legacyListDefaultsKey)
        }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.layoutDefaultsKey),
           let stored = LibraryLayoutMode(rawValue: raw) {
            self.libraryLayout = stored
        } else {
            let legacyIsList = UserDefaults.standard.bool(forKey: Self.legacyListDefaultsKey)
            self.libraryLayout = legacyIsList ? .table : .grid
        }
    }

    func openConfiguration(for app: PlayApp, pane: ConfigPane = .overview) {
        selectedAppID = app.id
        activeConfigPane = pane
        withAnimation(.snappy) {
            configTargetID = app.id
        }
    }

    func closeConfiguration() {
        withAnimation(.snappy) {
            configTargetID = nil
        }
    }
}
