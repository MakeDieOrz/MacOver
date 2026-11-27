//
//  AppSettingsPersistence.swift
//  PlayCoverCore
//

import Foundation

public enum AppSettingsPersistence {
    public static func decode(from url: URL) throws -> AppSettingsData {
        let data = try Data(contentsOf: url)
        return try PropertyListDecoder().decode(AppSettingsData.self, from: data)
    }

    @discardableResult
    public static func encode(
        _ snapshot: AppSettingsData,
        to url: URL,
        preservingExistingKeys: Bool
    ) throws -> AppSettingsData {
        var updatedSnapshot = snapshot
        var diskDict: [String: Any]?

        if preservingExistingKeys,
           let diskData = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(
               from: diskData, options: [], format: nil
           ) as? [String: Any] {
            diskDict = plist
            if let diskDisabledAt = plist["keymappingDisabledAt"] as? NSNumber {
                let diskValue = diskDisabledAt.floatValue
                if updatedSnapshot.keymappingDisabledAt != diskValue {
                    updatedSnapshot.keymappingDisabledAt = diskValue
                }
            }
        }

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let encodedData = try encoder.encode(updatedSnapshot)

        let outputData: Data
        if preservingExistingKeys,
           var merged = diskDict,
           let encodedDict = try PropertyListSerialization.propertyList(
               from: encodedData, options: [], format: nil
           ) as? [String: Any] {
            for (key, value) in encodedDict {
                merged[key] = value
            }
            if updatedSnapshot.originalBundleName == nil {
                merged.removeValue(forKey: "originalBundleName")
            }
            if updatedSnapshot.originalMinimumOSVersion == nil {
                merged.removeValue(forKey: "originalMinimumOSVersion")
            }
            outputData = try PropertyListSerialization.data(
                fromPropertyList: merged, format: .xml, options: 0
            )
        } else {
            outputData = encodedData
        }

        try outputData.write(to: url, options: .atomic)
        return updatedSnapshot
    }

    @discardableResult
    public static func preserveUnreadableFileIfPresent(at url: URL, bundleIdentifier: String) -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let backupURL = url.appendingPathExtension("bak")
        do {
            try? fileManager.removeItem(at: backupURL)
            try fileManager.copyItem(at: url, to: backupURL)
            PlayCoverDiagnostics.log("Preserved unreadable app settings at \(backupURL.path)", isError: true)
            return backupURL
        } catch {
            PlayCoverDiagnostics.log(
                "Failed to preserve unreadable app settings for \(bundleIdentifier): " +
                    error.localizedDescription,
                isError: true
            )
            return nil
        }
    }

    public static func autoResolution(
        screenWidth: Int,
        screenHeight: Int,
        hasNotch: Bool
    ) -> (width: Int, height: Int) {
        let wFloat = Float(screenWidth)
        let hFloat = Float(screenHeight)
        if hasNotch && wFloat > 0 && (hFloat / wFloat) * 16.0 > 10.3 && (hFloat / wFloat) * 16.0 < 10.4 {
            return (screenWidth, Int((wFloat / 16) * 10))
        }
        return (screenWidth, screenHeight)
    }
}
