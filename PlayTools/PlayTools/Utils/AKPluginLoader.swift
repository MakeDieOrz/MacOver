//
//  AKPluginLoader.swift
//  PlayTools
//
//  Created by Isaac Marovitz on 13/09/2022.
//

import Foundation

class AKInterface {
    private static let sharedLock = PTUnfairLock()
    nonisolated(unsafe) private static var _shared: Plugin?

    public static var shared: Plugin? {
        get { sharedLock.withLock { _shared } }
        set { sharedLock.withLock { _shared = newValue } }
    }

    public static func initialize() {
        shared = loadPlugin()
    }

    private static func loadPlugin() -> Plugin? {
        let candidateURLs: [URL?] = [
            Bundle.main.builtInPlugInsURL?
                .appendingPathComponent("AKInterface")
                .appendingPathExtension("bundle"),
            Bundle(for: AKInterface.self).builtInPlugInsURL?
                .appendingPathComponent("AKInterface")
                .appendingPathExtension("bundle")
        ]
        return loadPlugin(from: candidateURLs)
    }

    static func loadPlugin(from candidateURLs: [URL?]) -> Plugin? {
        for case let bundleURL? in candidateURLs {
            if let bundle = Bundle(url: bundleURL),
               let pluginClass = bundle.principalClass as? Plugin.Type {
                return pluginClass.init()
            }
        }
        return nil
    }
}
