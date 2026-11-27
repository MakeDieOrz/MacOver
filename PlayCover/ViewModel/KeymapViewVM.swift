//
//  KeymapViewVM.swift
//  PlayCover
//
//  Created by TheMoonThatRises on 6/20/25.
//

import Observation
import SwiftUI

@MainActor
@Observable
final class KeymapViewVM {

    public let app: PlayApp

    var selectedKeymap: URL?
    var kmName = ""

    var defaultKm: URL

    var showKeymapImport = false
    var showKeymapRename = false
    var showCreateKeymap = false

    var appIcon: NSImage?
    private var hasLoadedCache = false

    var keymapURLS: [URL] = [] {
        didSet {
            app.keymapping.keymapConfig.keymapOrder = keymapURLS
        }
    }

    init(app: PlayApp, loadCacheImmediately: Bool = true) {
        self.app = app
        self.defaultKm = app.keymapping.keymapConfig.defaultKm

        if loadCacheImmediately {
            self.reloadKeymapCache()
        }
    }

    func ensureLoaded() {
        guard !hasLoadedCache else { return }
        reloadKeymapCache()
    }

    func reloadKeymapCache() {
        hasLoadedCache = true
        app.keymapping.reloadKeymapCache()
        keymapURLS = app.keymapping.keymapConfig.keymapOrder
    }

    func setDefaultKeymap(keymap: URL) {
        app.keymapping.keymapConfig.defaultKm = keymap
        defaultKm = keymap
    }

}
