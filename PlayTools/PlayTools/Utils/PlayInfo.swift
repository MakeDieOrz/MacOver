//
//  PlayInformation.swift
//  PlayTools
//

import Foundation

class PlayInfo: NSObject {
    static var isLauncherInstalled: Bool {
        return AKInterface.shared?
            .urlForApplicationWithBundleIdentifier("app.makedie.MacOver") != nil
    }

    @objc static var isUnrealEngine: Bool {
        let appFolder = Bundle.main.bundleURL
        let ueFiles: [URL] = [
            appFolder.appendingPathComponent("ue4commandline.txt"),
            appFolder.appendingPathComponent("uecommandline.txt")
        ]

        for ueFile in ueFiles where FileManager.default.fileExists(atPath: ueFile.path) {
            return true
        }
        return false
    }
}
