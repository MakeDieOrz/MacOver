//
//  AppsVM.swift
//  PlayCover
//

import Foundation

class AppsVM: ObservableObject {

    public static let appDirectory = PlayTools.playCoverContainer.appendingPathComponent("Applications")

    weak var dependencies: PlayCoverDependencies?

    init(dependencies: PlayCoverDependencies? = nil, loadOnInit: Bool = !ProcessInfo.isRunningUnitTests) {
        self.dependencies = dependencies
        try? AppsVM.ensureBaseDirectoriesExist()
        if loadOnInit {
            PlayTools.installOnSystem()
            fetchApps()
        }
    }

    static func ensureBaseDirectoriesExist() throws {
        try FileManager.default.createDirectory(
            at: appDirectory,
            withIntermediateDirectories: true
        )
    }

    @Published var filteredApps: [PlayApp] = []
    @Published var apps: [PlayApp] = []
    @Published var searchText: String = ""
    @Published var updatingApps = true

    private var fetchTask: Task<Void, Never>?

    @MainActor
    func applyFilter() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let nextFiltered = query.isEmpty
            ? apps
            : apps.filter { $0.searchText.contains(query) }
        filteredApps = nextFiltered.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static func shouldReuseExistingApp(_ existing: PlayApp, at appURL: URL) -> Bool {
        let plistURL = appURL.appendingPathComponent("Info").appendingPathExtension("plist")
        let freshInfo = AppInfo(contentsOf: plistURL)
        let existingInfo = existing.info
        let generationKey = Installer.installGenerationInfoKey
        return freshInfo.bundleIdentifier == existingInfo.bundleIdentifier
            && freshInfo.bundleVersion == existingInfo.bundleVersion
            && freshInfo[object: "CFBundleVersion"] == existingInfo[object: "CFBundleVersion"]
            && freshInfo.executableName == existingInfo.executableName
            && freshInfo.displayName == existingInfo.displayName
            && freshInfo.bundleName == existingInfo.bundleName
            && freshInfo[string: generationKey] == existingInfo[string: generationKey]
    }

    func fetchApps() {
        fetchTask?.cancel()
        let deps = self.dependencies
        fetchTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.updatingApps = true
            }

            let existingByURL = await MainActor.run {
                Dictionary(self.apps.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
            }

            let loadedApps: [PlayApp] = await Task.detached(priority: .userInitiated) {
                var discovered: [PlayApp] = []
                do {
                    let fm = FileManager.default
                    let directoryContents = try fm.contentsOfDirectory(
                        at: AppsVM.appDirectory,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: []
                    )

                    for sub in directoryContents where sub.hasDirectoryPath {
                        if Task.isCancelled { return discovered }
                        if sub.pathExtension.contains("app") &&
                            fm.fileExists(atPath: sub.appendingPathComponent("Info")
                                .appendingPathExtension("plist")
                                .path) {
                            let app: PlayApp
                            if let existing = existingByURL[sub],
                               AppsVM.shouldReuseExistingApp(existing, at: sub) {
                                app = existing
                            } else {
                                app = PlayApp(appUrl: sub, dependencies: deps)
                            }
                            app.dependencies = deps
                            app.ensureAliasUpToDate()
                            print("Application installed under:", sub.path)
                            discovered.append(app)
                        }
                    }
                } catch {
                    print(error)
                }

                if Task.isCancelled { return discovered }

                do {
                    let existingCache: [String]
                    if FileManager.default.fileExists(atPath: PlayApp.bundleIDCacheURL.path) {
                        existingCache = try PlayApp.bundleIDCache
                    } else {
                        existingCache = []
                    }
                    let existingSet = Set(existingCache)
                    var missingIDs: [String] = []
                    var seenMissing = Set<String>()
                    for app in discovered {
                        let bid = app.info.bundleIdentifier
                        if !bid.isEmpty && !existingSet.contains(bid) && seenMissing.insert(bid).inserted {
                            missingIDs.append(bid)
                        }
                    }
                    if !missingIDs.isEmpty {
                        let merged = existingCache + missingIDs
                        let payload = merged.joined(separator: "\n") + "\n"
                        try payload.write(to: PlayApp.bundleIDCacheURL, atomically: true, encoding: .utf8)
                    }
                } catch {
                    PlayCoverDiagnostics.reportError(error)
                }

                return discovered
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.apps = loadedApps
                self.applyFilter()
                self.updatingApps = false
            }
        }
    }
}
