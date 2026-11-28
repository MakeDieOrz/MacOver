//
//  Keymapping.swift
//  PlayCover
//
//  Created by TheMoonThatRises on 9/15/25.
//

import Darwin
import Foundation
import Synchronization
import UniformTypeIdentifiers

nonisolated enum KeymappingError: LocalizedError, Sendable {
    case invalidName(String)
    case notFound(String)
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            return "Invalid keymap name '\(name)'."
        case .notFound(let name):
            return "Keymap '\(name)' not found."
        case .unsafePath(let name):
            return "Keymap path for '\(name)' escapes keymapping directory or is a symlink."
        }
    }
}

nonisolated final class Keymapping: @unchecked Sendable {
    static var keymappingDir: URL {
        let keymappingFolder = PlayTools.playCoverContainer.appendingPathComponent("Keymapping")
        if !FileManager.default.fileExists(atPath: keymappingFolder.path) {
            do {
                try FileManager.default.createDirectory(
                    at: keymappingFolder,
                    withIntermediateDirectories: true,
                    attributes: [:]
                )
            } catch {
                PlayCoverDiagnostics.reportError(error)
            }
        }
        return keymappingFolder
    }

    static func isValidKeymapName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == name, name.count <= 128 else {
            return false
        }
        if name.hasPrefix(".") || name.contains("..") {
            return false
        }
        if name.contains("/") || name.contains("\\") || name.contains(":") {
            return false
        }
        for scalar in name.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7F {
            return false
        }
        return true
    }

    let info: AppInfo
    let baseKeymapURL: URL
    let configURL: URL
    private let hasValidBundleIdentifier: Bool

    let encoder: PropertyListEncoder
    weak var alertPresenter: AlertPresenter?
    private let lock = Mutex<Void>(())

    var keymapConfig: KeymapConfig {
        get {
            lock.withLock { _ in
                loadConfigLocked()
            }
        }
        set {
            lock.withLock { _ in
                saveConfigLocked(newValue)
            }
        }
    }

    init(_ info: AppInfo, alertPresenter: AlertPresenter? = nil) {
        self.info = info
        self.alertPresenter = alertPresenter
        let validID = Shell.isValidBundleIdentifier(info.bundleIdentifier)
        self.hasValidBundleIdentifier = validID

        let safeDirName = validID ? info.bundleIdentifier : "invalid-bundle"
        self.baseKeymapURL = Keymapping.keymappingDir.appendingPathComponent(safeDirName, isDirectory: true)
        self.configURL = baseKeymapURL.appendingPathComponent(".config").appendingPathExtension("plist")

        if validID && !FileManager.default.fileExists(atPath: self.baseKeymapURL.path) {
            do {
                try FileManager.default.createDirectory(
                    at: self.baseKeymapURL,
                    withIntermediateDirectories: true
                )
            } catch {
                PlayCoverDiagnostics.reportError(error)
            }
        }

        self.encoder = PropertyListEncoder()
        self.encoder.outputFormat = .xml

        if validID {
            self.reloadKeymapCache()
        }
    }

    private func verifyBaseDirectoryLocked() throws {
        guard hasValidBundleIdentifier else {
            throw KeymappingError.unsafePath(info.bundleIdentifier)
        }
        let rootDir = Keymapping.keymappingDir
        var rootStat = Darwin.stat()
        guard Darwin.lstat(rootDir.path, &rootStat) == 0,
              (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            throw KeymappingError.unsafePath(info.bundleIdentifier)
        }
        var baseStat = Darwin.stat()
        guard Darwin.lstat(baseKeymapURL.path, &baseStat) == 0,
              (baseStat.st_mode & S_IFMT) == S_IFDIR else {
            throw KeymappingError.unsafePath(info.bundleIdentifier)
        }
        let resolvedRoot = rootDir.resolvingSymlinksInPath().standardizedFileURL
        let resolvedBase = baseKeymapURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedBase.deletingLastPathComponent() == resolvedRoot else {
            throw KeymappingError.unsafePath(info.bundleIdentifier)
        }
    }

    private func readRegularFileNoFollowLocked(at url: URL) throws -> Data {
        try verifyBaseDirectoryLocked()
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let err = errno
            if err == ELOOP {
                throw KeymappingError.unsafePath(url.lastPathComponent)
            }
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .ENOENT)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }

        var st = Darwin.stat()
        guard Darwin.fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG else {
            throw KeymappingError.unsafePath(url.lastPathComponent)
        }
        return try handle.readToEnd() ?? Data()
    }

    private func writeRegularFileAtomicallyNoFollowLocked(_ data: Data, to url: URL) throws {
        try verifyBaseDirectoryLocked()
        var existingStat = Darwin.stat()
        if Darwin.lstat(url.path, &existingStat) == 0,
           (existingStat.st_mode & S_IFMT) != S_IFREG {
            throw KeymappingError.unsafePath(url.lastPathComponent)
        }

        let tempURL = baseKeymapURL.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = Darwin.open(
            tempURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
        }
        var committed = false
        defer {
            _ = Darwin.close(fd)
            if !committed {
                _ = Darwin.unlink(tempURL.path)
            }
        }
        try data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var written = 0
            while written < rawBuf.count {
                let rc = Darwin.write(fd, base.advanced(by: written), rawBuf.count - written)
                if rc < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += rc
            }
        }
        guard Darwin.rename(tempURL.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        committed = true
    }

    private func validatedKeymapPath(name: String) throws -> URL {
        guard Self.isValidKeymapName(name) else {
            throw KeymappingError.invalidName(name)
        }
        try verifyBaseDirectoryLocked()
        let candidate = baseKeymapURL.appendingPathComponent(name).appendingPathExtension("plist")
        let stdBase = baseKeymapURL.standardizedFileURL
        guard candidate.standardizedFileURL.deletingLastPathComponent() == stdBase else {
            throw KeymappingError.unsafePath(name)
        }
        var st = Darwin.stat()
        if Darwin.lstat(candidate.path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFREG else {
                throw KeymappingError.unsafePath(name)
            }
        }
        let resolvedParent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
        let resolvedBase = baseKeymapURL.resolvingSymlinksInPath()
        guard resolvedParent == resolvedBase else {
            throw KeymappingError.unsafePath(name)
        }
        return candidate
    }

    private func loadConfigLocked() -> KeymapConfig {
        do {
            let data = try readRegularFileNoFollowLocked(at: configURL)
            return try PropertyListDecoder().decode(KeymapConfig.self, from: data)
        } catch {
            print(error)
            return resetConfigLocked()
        }
    }

    private func saveConfigLocked(_ config: KeymapConfig) {
        do {
            let data = try encoder.encode(config)
            try writeRegularFileAtomicallyNoFollowLocked(data, to: configURL)
        } catch {
            print(error)
        }
    }

    private func resetConfigLocked() -> KeymapConfig {
        let defaultURL = baseKeymapURL.appendingPathComponent("default").appendingPathExtension("plist")
        let fallback = KeymapConfig(defaultKm: defaultURL, keymapOrder: [defaultURL])
        saveConfigLocked(fallback)
        return fallback
    }

    public func reloadKeymapCache() {
        lock.withLock { _ in
            guard (try? verifyBaseDirectoryLocked()) != nil else {
                return
            }

            let directoryContents: [URL]
            do {
                directoryContents = try FileManager.default.contentsOfDirectory(
                    at: baseKeymapURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            } catch {
                print("failed to get keymapping directory")
                PlayCoverDiagnostics.reportError(error)
                return
            }

            var config = loadConfigLocked()
            var configDirty = false
            var discoveredByName: [String: URL] = [:]
            var discoveredNames: [String] = []

            for keymap in directoryContents where keymap.pathExtension == "plist" {
                let candidateName = keymap.deletingPathExtension().lastPathComponent
                guard let validURL = try? validatedKeymapPath(name: candidateName) else { continue }
                var st = Darwin.stat()
                guard Darwin.lstat(validURL.path, &st) == 0,
                      (st.st_mode & S_IFMT) == S_IFREG else {
                    continue
                }
                if discoveredByName[candidateName] == nil {
                    discoveredByName[candidateName] = validURL
                    discoveredNames.append(candidateName)
                }
            }

            // Rebase any legacy pre-migration URLs in .config.plist by filename onto baseKeymapURL
            // so existing keymaps are never overwritten with empty defaults.
            var normalizedOrder: [URL] = []
            var seenNames = Set<String>()
            for rawEntry in config.keymapOrder {
                let entryName = rawEntry.deletingPathExtension().lastPathComponent
                guard let rebasedURL = try? validatedKeymapPath(name: entryName) else {
                    configDirty = true
                    continue
                }
                if rawEntry != rebasedURL {
                    configDirty = true
                }
                if seenNames.insert(entryName).inserted {
                    normalizedOrder.append(rebasedURL)
                } else {
                    configDirty = true
                }
            }

            for name in discoveredNames.sorted() {
                if let url = discoveredByName[name], seenNames.insert(name).inserted {
                    normalizedOrder.append(url)
                    configDirty = true
                }
            }

            if discoveredByName.isEmpty {
                if let defaultURL = try? validatedKeymapPath(name: "default") {
                    let defaultMap = Keymap(bundleIdentifier: info.bundleIdentifier)
                    if let data = try? encoder.encode(defaultMap) {
                        try? writeRegularFileAtomicallyNoFollowLocked(data, to: defaultURL)
                    }
                    if seenNames.insert("default").inserted {
                        normalizedOrder.append(defaultURL)
                        configDirty = true
                    }
                }
            } else {
                for url in normalizedOrder {
                    let missingName = url.deletingPathExtension().lastPathComponent
                    if discoveredByName[missingName] == nil {
                        let emptyMap = Keymap(bundleIdentifier: info.bundleIdentifier)
                        if let data = try? encoder.encode(emptyMap) {
                            try? writeRegularFileAtomicallyNoFollowLocked(data, to: url)
                        }
                    }
                }
            }

            if config.keymapOrder != normalizedOrder {
                config.keymapOrder = normalizedOrder
                configDirty = true
            }

            let defaultName = config.defaultKm.deletingPathExtension().lastPathComponent
            if let rebasedDefault = try? validatedKeymapPath(name: defaultName),
               normalizedOrder.contains(rebasedDefault) {
                if config.defaultKm != rebasedDefault {
                    config.defaultKm = rebasedDefault
                    configDirty = true
                }
            } else if let first = normalizedOrder.first, config.defaultKm != first {
                config.defaultKm = first
                configDirty = true
            }

            if configDirty {
                saveConfigLocked(config)
            }
        }
    }

    public func readKeymap(name: String) throws -> Keymap {
        try lock.withLock { _ in
            let path = try validatedKeymapPath(name: name)
            var st = Darwin.stat()
            guard Darwin.lstat(path.path, &st) == 0 else {
                throw KeymappingError.notFound(name)
            }
            guard (st.st_mode & S_IFMT) == S_IFREG else {
                throw KeymappingError.unsafePath(name)
            }
            let data = try readRegularFileNoFollowLocked(at: path)
            return try PropertyListDecoder().decode(Keymap.self, from: data)
        }
    }

    public func getKeymap(name: String) -> Keymap {
        lock.withLock { _ in
            guard let path = try? validatedKeymapPath(name: name) else {
                return Keymap(bundleIdentifier: info.bundleIdentifier)
            }
            do {
                let data = try readRegularFileNoFollowLocked(at: path)
                return try PropertyListDecoder().decode(Keymap.self, from: data)
            } catch {
                print(error)
                return resetLocked(name: name)
            }
        }
    }

    public func createEmptyKeymap(name: String) -> Bool {
        lock.withLock { _ in
            guard let path = try? writeKeymapLocked(
                name: name,
                map: Keymap(bundleIdentifier: info.bundleIdentifier)
            ) else {
                return false
            }
            return loadConfigLocked().keymapOrder.contains(path)
        }
    }

    public func saveKeymapValidated(name: String, map: Keymap) throws {
        try lock.withLock { _ in
            _ = try writeKeymapLocked(name: name, map: map)
        }
    }

    public func saveKeymap(name: String, map: Keymap) {
        lock.withLock { _ in
            _ = try? writeKeymapLocked(name: name, map: map)
        }
    }

    public func listKeymapNames() -> [String] {
        lock.withLock { _ in
            loadConfigLocked().keymapOrder
                .map { $0.deletingPathExtension().lastPathComponent }
                .filter { Self.isValidKeymapName($0) }
        }
    }

    @discardableResult
    private func writeKeymapLocked(name: String, map: Keymap) throws -> URL {
        let keymapPath = try validatedKeymapPath(name: name)
        let data = try encoder.encode(map)
        try writeRegularFileAtomicallyNoFollowLocked(data, to: keymapPath)

        var config = loadConfigLocked()
        if !config.keymapOrder.contains(keymapPath) {
            config.keymapOrder.append(keymapPath)
            saveConfigLocked(config)
        }
        return keymapPath
    }

    public func renameKeymap(prevName: String, newName: String) -> Bool {
        lock.withLock { _ in
            guard let oldPath = try? validatedKeymapPath(name: prevName),
                  let newPath = try? validatedKeymapPath(name: newName) else {
                return false
            }
            var config = loadConfigLocked()
            guard let oldKeymapIndex = config.keymapOrder.firstIndex(of: oldPath) else {
                print("could not find keymap with name: \(prevName)")
                return false
            }
            do {
                try FileManager.default.moveItem(at: oldPath, to: newPath)
                config.keymapOrder[oldKeymapIndex] = newPath
                if config.defaultKm == oldPath {
                    config.defaultKm = newPath
                }
                saveConfigLocked(config)
                return true
            } catch {
                PlayCoverDiagnostics.reportError(error)
                return false
            }
        }
    }

    public func deleteKeymap(name: String) -> Bool {
        lock.withLock { _ in
            guard let keymapURL = try? validatedKeymapPath(name: name) else {
                return false
            }
            var config = loadConfigLocked()
            guard let keymapIndex = config.keymapOrder.firstIndex(of: keymapURL) else {
                print("could not find keymap with name: \(name)")
                return false
            }
            do {
                try FileManager.default.trashItem(at: keymapURL, resultingItemURL: nil)
                config.keymapOrder.remove(at: keymapIndex)
                saveConfigLocked(config)
                return true
            } catch {
                PlayCoverDiagnostics.reportError(error)
                return false
            }
        }
    }

    public func hasKeymap(name: String) -> Bool {
        lock.withLock { _ in
            guard let path = try? validatedKeymapPath(name: name) else {
                return false
            }
            return loadConfigLocked().keymapOrder.contains(path)
        }
    }

    @discardableResult
    public func reset(name: String) -> Keymap {
        lock.withLock { _ in
            resetLocked(name: name)
        }
    }

    private func resetLocked(name: String) -> Keymap {
        let fallback = Keymap(bundleIdentifier: info.bundleIdentifier)
        _ = try? writeKeymapLocked(name: name, map: fallback)
        return fallback
    }

    @MainActor
    public func importKeymap(name: String, success: @escaping @MainActor (Bool) -> Void) {
        guard Self.isValidKeymapName(name) else {
            success(false)
            return
        }
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = true
        openPanel.allowedContentTypes = [UTType(exportedAs: "app.makedie.MacOver-playmap")]
        openPanel.title = NSLocalizedString("playapp.importKm", comment: "")

        openPanel.begin { result in
            if result == .OK {
                let selectedPath = openPanel.url
                openPanel.close()
                guard let selectedPath else { return }
                Task { @MainActor in
                    do {
                        let data = try Data(contentsOf: selectedPath)
                        let importedKeymap = try PropertyListDecoder().decode(Keymap.self, from: data)
                        if importedKeymap.bundleIdentifier == self.info.bundleIdentifier {
                            self.saveKeymap(name: name, map: importedKeymap)
                            success(true)
                        } else if await self.differentBundleIdKeymapAlert() {
                            self.saveKeymap(name: name, map: importedKeymap)
                            success(true)
                        } else {
                            success(false)
                        }
                    } catch {
                        if let keymap = LegacySettings.convertLegacyKeymapFile(selectedPath) {
                            if keymap.bundleIdentifier == self.info.bundleIdentifier {
                                self.saveKeymap(name: name, map: keymap)
                                success(true)
                            } else if await self.differentBundleIdKeymapAlert() {
                                self.saveKeymap(name: name, map: keymap)
                                success(true)
                            } else {
                                success(false)
                            }
                        } else {
                            success(false)
                        }
                    }
                }
            }
        }
    }

    @MainActor
    public func exportKeymap(name: String) {
        let savePanel = NSSavePanel()
        savePanel.title = NSLocalizedString("playapp.exportKm", comment: "")
        savePanel.nameFieldLabel = NSLocalizedString("playapp.exportKmPanel.fieldLabel", comment: "")
        savePanel.nameFieldStringValue = info.displayName
        savePanel.allowedContentTypes = [UTType(exportedAs: "app.makedie.MacOver-playmap")]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false

        savePanel.begin { result in
            if result == .OK {
                do {
                    if let selectedPath = savePanel.url {
                        let data = try self.encoder.encode(self.getKeymap(name: name))
                        try data.write(to: selectedPath, options: [.atomic])
                        selectedPath.openInFinder()
                    }
                } catch {
                    savePanel.close()
                    PlayCoverDiagnostics.reportError(error)
                }
                savePanel.close()
            }
        }
    }

    @MainActor
    private func differentBundleIdKeymapAlert() async -> Bool {
        let presenter = alertPresenter ?? AlertPresenter()
        let response = await presenter.present(
            PlayCoverAlertRequest(
                title: NSLocalizedString("alert.differentBundleIdKeymap.message", comment: ""),
                message: NSLocalizedString("alert.differentBundleIdKeymap.text", comment: ""),
                style: .warning,
                buttons: [
                    PlayCoverAlertButton(title: NSLocalizedString("button.Proceed", comment: "")),
                    PlayCoverAlertButton(title: NSLocalizedString("button.Cancel", comment: ""), isCancel: true)
                ],
                defaultCancelIndex: 1
            )
        )
        return response.buttonIndex == 0
    }
}
