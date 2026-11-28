//
//  Store.swift
//  PlayCover
//
//  Created by Isaac Marovitz on 06/08/2022.
//

import Foundation
import Observation

@Observable
class StoreVM {
    private let plistSource: URL

    private var isDecoding = false
    private var suppressEncode = false

    init(resolveOnInit: Bool = !ProcessInfo.isRunningUnitTests) {
        plistSource = PlayTools.playCoverContainer
            .appendingPathComponent("Sources")
            .appendingPathExtension("plist")
        sourcesList = []
        if !decode() { encode() }
        if resolveOnInit {
            resolveSources()
        }
    }

    var sourcesList: [SourceData] {
        didSet {
            if !isDecoding && !suppressEncode {
                encode()
            }
        }
    }
    var sourcesData: [SourceJSON] = [] {
        didSet {
            updateSourcesApps()
        }
    }
    var sourcesApps: [SourceAppsData] = []

    private var resolveTask: Task<Void, Never>?
    private var hasResolvedInitialSources = false

    public func getEnabledSources() -> [SourceJSON] {
        return sourcesData.filter { sourceJSON in
            return sourcesList.contains { sourceData in
                sourceData.id == sourceJSON.id && sourceData.isEnabled
            }
        }
    }

    func enableSourceToggle(source: SourceData, value: Bool) {
        if let index = sourcesList.firstIndex(of: source) {
            sourcesList[index].isEnabled = value
        }
        updateSourcesApps()
    }

    func updateSourcesApps() {
        sourcesApps.removeAll()
        let enabledSources: [SourceJSON] = getEnabledSources()
        for source in enabledSources {
            appendSourceData(source)
        }
    }

    //
    func addSource(_ source: SourceData) {
        guard !sourcesList.contains(where: { $0.source == source.source }) else { return }
        sourcesList.append(source)
        resolveSources()
    }

    //
    func deleteSource(_ selectedSource: inout Set<UUID>) {
        sourcesList.removeAll {
            selectedSource.contains($0.id)
        }
        selectedSource.removeAll()
        resolveSources()
    }

    //
    func moveSourceUp(_ selectedSource: inout Set<UUID>) {
        guard !selectedSource.isEmpty, sourcesList.count > 1 else { return }
        var updated = sourcesList
        var moved = false
        for index in 1..<updated.count {
            if selectedSource.contains(updated[index].id) && !selectedSource.contains(updated[index - 1].id) {
                updated.swapAt(index - 1, index)
                moved = true
            }
        }
        guard moved else { return }
        sourcesList = updated
        resolveSources()
    }

    //
    func moveSourceDown(_ selectedSource: inout Set<UUID>) {
        guard !selectedSource.isEmpty, sourcesList.count > 1 else { return }
        var updated = sourcesList
        var moved = false
        for index in stride(from: updated.count - 2, through: 0, by: -1) {
            if selectedSource.contains(updated[index].id) && !selectedSource.contains(updated[index + 1].id) {
                updated.swapAt(index, index + 1)
                moved = true
            }
        }
        guard moved else { return }
        sourcesList = updated
        resolveSources()
    }

    func resolveSourcesIfNeeded() {
        guard !hasResolvedInitialSources else { return }
        resolveSources()
    }

    private func updateSourceStatus(id: UUID, status: SourceValidation) {
        guard let index = sourcesList.firstIndex(where: { $0.id == id }) else { return }
        guard sourcesList[index].status != status else { return }
        suppressEncode = true
        defer { suppressEncode = false }
        sourcesList[index].status = status
    }

    //
    func resolveSources() {
        hasResolvedInitialSources = true
        resolveTask?.cancel()
        resolveTask = Task { @MainActor in
            guard !sourcesList.isEmpty else {
                sourcesData.removeAll()
                return
            }

            let isConnected = await NetworkVM.isConnectedToNetworkAsync()
            if Task.isCancelled { return }

            let snapshot = sourcesList.map { (id: $0.id, source: $0.source) }
            sourcesData.removeAll()

            for item in snapshot {
                if Task.isCancelled { return }
                updateSourceStatus(id: item.id, status: .checking)
                let (sourceJson, sourceState) = await getSourceData(
                    sourceLink: item.source,
                    sourceId: item.id,
                    isConnected: isConnected
                )
                if Task.isCancelled { return }
                guard sourcesList.contains(where: { $0.id == item.id }) else { continue }
                updateSourceStatus(id: item.id, status: sourceState)
                if sourceState == .valid, let sourceJson {
                    sourcesData.append(sourceJson)
                }
            }
        }
    }

    //
    func awaitResolveSources() async {
        guard let task = resolveTask else {
            return
        }
        _ = await task.result
    }

    //
    @discardableResult private func encode() -> Bool {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml

        do {
            let data = try encoder.encode(sourcesList)
            try data.write(to: plistSource, options: .atomic)
            return true
        } catch {
            print("StoreVM: Failed to encode Sources.plist! ", error)
            return false
        }
    }

    //
    @discardableResult private func decode() -> Bool {
        isDecoding = true
        defer { isDecoding = false }
        do {
            let data = try Data(contentsOf: plistSource)
            sourcesList = try PropertyListDecoder().decode([SourceData].self, from: data)
            return true
        } catch {
            print("StoreVM: Failed to decode Sources.plist! ", error)
            return false
        }
    }

    static func normalizeSourceURL(_ rawSource: String) -> URL? {
        let trimmed = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }

        guard var url = URL(string: trimmed) else { return nil }
        if url.scheme == nil {
            guard let httpsURL = URL(string: "https://" + trimmed) else { return nil }
            url = httpsURL
        }

        if url.isFileURL {
            return url.path.isEmpty ? nil : url
        }

        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }

        return url
    }

    static func fetchAndValidateSource(
        url: URL,
        sourceId: UUID = UUID(),
        isConnected: Bool? = nil
    ) async -> (SourceJSON?, SourceValidation) {
        let dataToDecode: Data
        if url.isFileURL {
            do {
                dataToDecode = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url)
                }.value
            } catch {
                debugPrint("Error reading local source URL: \(url): \(error)")
                return (nil, .badurl)
            }
        } else {
            let networkAvailable: Bool
            if let isConnected {
                networkAvailable = isConnected
            } else {
                networkAvailable = await NetworkVM.isConnectedToNetworkAsync()
            }
            guard networkAvailable else {
                return (nil, .badurl)
            }

            do {
                let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return (nil, .badurl)
                }
                dataToDecode = data
            } catch {
                debugPrint("Error fetching data from URL: \(url): \(error)")
                return (nil, .badurl)
            }
        }

        do {
            let decodedData = try JSONDecoder().decode(SourceJSON.self, from: dataToDecode)
            return (decodedData, .valid)
        } catch {
            do {
                let sourceName = url.isFileURL
                    ? url.deletingPathExtension().lastPathComponent
                    : (url.host ?? url.absoluteString)
                let oldTypeJson = try JSONDecoder().decode([SourceAppsData].self, from: dataToDecode)
                let decodedData = SourceJSON(name: sourceName, data: oldTypeJson, id: sourceId)
                return (decodedData, .valid)
            } catch {
                debugPrint("Error decoding JSON from URL: \(url): \(error)")
                return (nil, .badjson)
            }
        }
    }

    //
    private func getSourceData(
        sourceLink: String,
        sourceId: UUID,
        isConnected: Bool
    ) async -> (SourceJSON?, SourceValidation) {
        guard let url = Self.normalizeSourceURL(sourceLink) else { return (nil, .badurl) }
        return await Self.fetchAndValidateSource(url: url, sourceId: sourceId, isConnected: isConnected)
    }

    //
    private func appendSourceData(_ source: SourceJSON) {
        for app in source.data where !sourcesApps.contains(where: { $0.bundleID == app.bundleID }) {
            sourcesApps.append(app)
        }
    }

}

// Source Data Structure
nonisolated struct SourceJSON: Codable, Equatable, Hashable {
    let name: String
    let data: [SourceAppsData]
    let id: UUID
}

nonisolated struct SourceAppsData: Codable, Equatable, Hashable {
    let bundleID: String
    let name: String
    let version: String
    let itunesLookup: String
    let link: String
    let checksum: String?
}
