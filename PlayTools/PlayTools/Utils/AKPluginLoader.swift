//
//  AKPluginLoader.swift
//  PlayTools
//
//  Created by Isaac Marovitz on 13/09/2022.
//

import Darwin
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

    private static func isValidSignedPluginBundle(at bundleURL: URL) -> Bundle? {
        var dirSt = Darwin.stat()
        guard Darwin.lstat(bundleURL.path, &dirSt) == 0,
              (dirSt.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }
        let resolvedBundleURL = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard let bundle = Bundle(url: resolvedBundleURL),
              let execURL = bundle.executableURL else {
            return nil
        }
        var execSt = Darwin.stat()
        guard Darwin.lstat(execURL.path, &execSt) == 0,
              (execSt.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        let resolvedExec = execURL.resolvingSymlinksInPath().standardizedFileURL
        let bundlePrefix = resolvedBundleURL.path.hasSuffix("/")
            ? resolvedBundleURL.path
            : (resolvedBundleURL.path + "/")
        guard resolvedExec.path.hasPrefix(bundlePrefix) else {
            return nil
        }
        let fm = FileManager.default
        let hasBundleSeal =
            fm.fileExists(atPath: resolvedBundleURL.appendingPathComponent("Contents/_CodeSignature").path) ||
            fm.fileExists(atPath: resolvedBundleURL.appendingPathComponent("_CodeSignature").path)
        guard PTPluginContainer.verifyCodeSignature(
            at: resolvedBundleURL,
            doNotValidateResources: !hasBundleSeal
        ) else {
            return nil
        }
        return bundle
    }

    static func loadPlugin(from candidateURLs: [URL?]) -> Plugin? {
        for case let bundleURL? in candidateURLs {
            guard let bundle = isValidSignedPluginBundle(at: bundleURL),
                  let pluginClass = bundle.principalClass as? Plugin.Type else {
                continue
            }
            return pluginClass.init()
        }
        return nil
    }
}
