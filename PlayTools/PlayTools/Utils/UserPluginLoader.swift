//
//  UserPluginLoader.swift
//  PlayTools
//
//  Delegates user plugin discovery, validation, Safe Mode gating, and dynamic
//  anti-detection registration to PTPluginContainer.
//

import Foundation

enum UserPluginLoader {
    static func initialize() {
        PTPluginContainer.shared.initialize()
    }
}
