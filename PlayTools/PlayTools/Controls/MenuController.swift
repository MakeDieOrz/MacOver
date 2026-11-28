/*
 See LICENSE folder for this sample’s licensing information.
 
 Abstract:
 Menu construction extensions for this sample.
 */

import UIKit

@MainActor
private enum PTRotationGeometry {
    static let orientationMasks: [UIInterfaceOrientationMask] = [
        .landscapeLeft,
        .portrait,
        .landscapeRight,
        .portraitUpsideDown
    ]

    static func mask(forIndex index: Int) -> UIInterfaceOrientationMask {
        let normalized = ((index % orientationMasks.count) + orientationMasks.count) % orientationMasks.count
        return orientationMasks[normalized]
    }

    static func apply(rotationIndex: Int, to windowScene: UIWindowScene) {
        let orientationMask = mask(forIndex: rotationIndex)
        if #available(iOS 16.0, macCatalyst 16.0, *) {
            let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientationMask)
            windowScene.requestGeometryUpdate(preferences) { _ in }
            for window in windowScene.windows where !PlayScreen.isInternalOverlayWindow(window) {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}

extension UIApplication {
    @objc(pm_menu_switchEditorMode:)
    func switchEditorMode(_ sender: AnyObject) {
        ModeAutomaton.onCmdK()
    }

    @objc(pm_menu_removeElement:)
    func removeElement(_ sender: AnyObject) {
        EditorController.shared.removeControl()
    }

    @objc(pm_menu_upscaleElement:)
    func upscaleElement(_ sender: AnyObject) {
        EditorController.shared.focusedControl?.resize(down: false)
    }

    @objc(pm_menu_downscaleElement:)
    func downscaleElement(_ sender: AnyObject) {
        EditorController.shared.focusedControl?.resize(down: true)
    }

    // put a mark in the toucher log, so as to align with tester description
    @objc(pm_menu_markToucherLog:)
    func markToucherLog(_ sender: AnyObject) {
        Toucher.writeLog(logMessage: "mark")
        Toast.showHint(title: "Log marked")
    }

    @objc(pm_menu_rotateView:)
    func rotateView(_ sender: AnyObject) {
        guard let dict = sender.propertyList as? [String: Any],
              let index = dict["rotationIndex"] as? Int else {
            return
        }
        let normalized = ((index % 4) + 4) % 4
        if AKInterface.shared?.isSequoiaOrNewer == true {
            let isPortrait = (normalized == 1 || normalized == 3)
            let targetSize = CGSize(
                width: PlaySettings.shared.windowSizeWidth,
                height: PlaySettings.shared.windowSizeHeight
            )
            AKInterface.shared?.setWindowOrientation?(portrait: isPortrait, targetSize: targetSize)
        }
        for scene in connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            PTRotationGeometry.apply(rotationIndex: normalized, to: windowScene)
        }

        if !PlaySettings.shared.strictEmulationMode {
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 2, execute: {
                Toast.showHint(title: "Rotated")
            })
        }
    }

    @objc(pm_menu_toggleDebugOverlay:)
    func toggleDebugOverlay(_ sender: AnyObject) {
        MainActor.assumeIsolated {
            DebugController.instance.toggleDebugOverlay()
        }
    }

    @objc(pm_menu_hideCursor:)
    func hideCursor(_ sender: AnyObject) {
        AKInterface.shared?.hideCursorMove()
    }

    @objc(pm_menu_nextKeymap:)
    func nextKeymap(_ sender: AnyObject) {
        let isCmdK = mode == .editor

        if isCmdK {
            ModeAutomaton.onCmdK()
        }

        keymap.nextKeymap()
        Toast.showHint(title: "Switched to next keymap: \(keymap.currentKeymapName)")
        ActionDispatcher.build()

        if isCmdK {
            ModeAutomaton.onCmdK()
        }
    }

    @objc(pm_menu_previousKeymap:)
    func previousKeymap(_ sender: AnyObject) {
        let isCmdK = mode == .editor

        if isCmdK {
            ModeAutomaton.onCmdK()
        }

        keymap.previousKeymap()
        Toast.showHint(title: "Switched to previous keymap: \(keymap.currentKeymapName)")
        ActionDispatcher.build()

        if isCmdK {
            ModeAutomaton.onCmdK()
        }
    }
}

extension UIViewController {
    @objc(pm_menu_rotateView:deviceOrientation:)
    func rotateView(_ sender: AnyObject, deviceOrientation: Int) {
        _ = sender
        guard let windowScene = viewIfLoaded?.window?.windowScene ?? screen.windowScene else {
            return
        }
        PTRotationGeometry.apply(rotationIndex: deviceOrientation, to: windowScene)
    }
}

struct CommandsList {
    static let KeymappingToolbox = "keymapping"
}
// have to use a customized name, in case it conflicts with the game's localization file
let keymapping = [
    playToolsLocalizedString("menu.keymapping.toggleEditor", value: "Open/Close Keymapping Editor"),
    playToolsLocalizedString("menu.keymapping.deleteElement", value: "Delete selected element"),
    playToolsLocalizedString("menu.keymapping.upsizeElement", value: "Upsize selected element"),
    playToolsLocalizedString("menu.keymapping.downsizeElement", value: "Downsize selected element"),
    playToolsLocalizedString("menu.keymapping.toggleDebug", value: "Toggle Debug Overlay"),
    playToolsLocalizedString("menu.keymapping.hide.pointer", value: "Hide Mouse Pointer"),
    playToolsLocalizedString("menu.keymapping.previousKeymap", value: "Previous Keymap"),
    playToolsLocalizedString("menu.keymapping.nextKeymap", value: "Next Keymap")
]
@MainActor let iconsSelctor = [
    UIImage(systemName: "pencil"),
    UIImage(systemName: "trash.fill"),
    UIImage(systemName: "square.resize.up"),
    UIImage(systemName: "square.resize.down"),
    UIImage(systemName: "wrench.and.screwdriver"),
    UIImage(systemName: "pointer.arrow.slash"),
    UIImage(systemName: "arrow.down.square"),
    UIImage(systemName: "arrow.up.square")
  ]
let keymappingSelectors = [#selector(UIApplication.switchEditorMode(_:)),
                           #selector(UIApplication.removeElement(_:)),
                           #selector(UIApplication.upscaleElement(_:)),
                           #selector(UIApplication.downscaleElement(_:)),
                           #selector(UIApplication.toggleDebugOverlay(_:)),
                           #selector(UIApplication.hideCursor(_:)),
                           #selector(UIApplication.previousKeymap(_:)),
                           #selector(UIApplication.nextKeymap(_:))
    ]

@MainActor
class MenuController {
    init(with builder: UIMenuBuilder) {
    #if canImport(UIKit.UIMainMenuSystem)
        // Delay to avoid error
        // Cannot set a main menu system configuration while the main menu system is building.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let configuration = UIMainMenuSystem.Configuration()
                configuration.sidebarPreference = .included
                UIMainMenuSystem.shared.setBuildConfiguration(configuration) { [weak self] builder in
                    self?.setupMenu(with: builder)
                }
            }
        }
    #else
        setupMenu(with: builder)
    #endif
    }

    func setupMenu(with builder: UIMenuBuilder) {
        if Toucher.logEnabled {
            builder.insertSibling(MenuController.debuggingMenu(), afterMenu: .view)
        }
        builder.insertSibling(MenuController.keymappingMenu(), afterMenu: .view)
    }

    static func debuggingMenu() -> UIMenu {
        let menuTitle = [
            "Put a mark in toucher log"
        ]
        let keyCommands = ["L"]
        let selectors = [
            #selector(UIApplication.markToucherLog(_:))
        ]
        let count = min(keyCommands.count, min(menuTitle.count, selectors.count))
        let arrowKeyChildrenCommands = (0..<count).map { index in
            let btn = menuTitle[index]
            return UIKeyCommand(
                title: btn,
                image: nil,
                action: selectors[index],
                input: keyCommands[index],
                modifierFlags: .command,
                propertyList: [CommandsList.KeymappingToolbox: btn]
            )
        }
        return UIMenu(title: "Debug",
                      image: nil,
                      identifier: .debuggingMenu,
                      options: [],
                      children: [
                        UIMenu(title: "",
                               image: nil,
                               identifier: .debuggingOptionsMenu,
                               options: .displayInline,
                               children: arrowKeyChildrenCommands)])
    }

    class func keymappingMenu() -> UIMenu {
        let keyCommands = [
            "K",                            // Toggle keymap editor
            UIKeyCommand.inputDelete,       // Remove keymap element
            UIKeyCommand.inputUpArrow,      // Increase keymap element size
            UIKeyCommand.inputDownArrow,    // Decrease keymap element size
            "D",                            // Toggle debug overlay
            ".",                            // Hide cursor until move
            "[",                            // Previous keymap
            "]"                             // Next keymap
        ]
        let count = min(
            min(keyCommands.count, keymapping.count),
            min(iconsSelctor.count, keymappingSelectors.count)
        )
        let arrowKeyChildrenCommands = (0..<count).map { index in
            let btn = keymapping[index]
            return UIKeyCommand(
                title: btn,
                image: iconsSelctor[index],
                action: keymappingSelectors[index],
                input: keyCommands[index],
                modifierFlags: .command,
                propertyList: [CommandsList.KeymappingToolbox: btn]
            )
        }

        // Every rotation item calls the *same selector*, passing its index in propertyList
        let rotationMenuItems = [
            "Landscape Left (0°)", "Portrait (90°)", "Landscape Right (180°)", "Portrait Upside Down (270°)"
        ].enumerated().map { (index, title) in
            UIKeyCommand(
                title: title, image: nil,
                action: #selector(UIApplication.rotateView(_:)),
                input: "\(index + 1)",
                modifierFlags: [.command, .shift], // ⌘⇧1–4
                propertyList: ["rotationIndex": index]
            )
        }

        let rotationMenu = UIMenu(
            title: playToolsLocalizedString("menu.keymapping.rotateDisplay", value: "Rotate display area"),
            image: nil,
            identifier: .rotationOptionsMenu,
            options: [],
            children: rotationMenuItems
        )

        // Combine all menus
        let arrowKeysGroup = UIMenu(
            title: "", image: nil,
            identifier: .keymappingOptionsMenu,
            options: .displayInline,
            children: arrowKeyChildrenCommands + [rotationMenu]
        )

        return UIMenu(
            title: playToolsLocalizedString("menu.keymapping", value: "Keymapping"),
            image: nil,
            identifier: .keymappingMenu,
            options: [],
            children: [arrowKeysGroup]
        )
    }
}

extension UIMenu.Identifier {
    static var keymappingMenu: UIMenu.Identifier { UIMenu.Identifier("com.apple.menu.application.ext1") }
    static var keymappingOptionsMenu: UIMenu.Identifier { UIMenu.Identifier("com.apple.menu.application.ext2") }
    static var debuggingMenu: UIMenu.Identifier { UIMenu.Identifier("com.apple.menu.application.ext3") }
    static var debuggingOptionsMenu: UIMenu.Identifier { UIMenu.Identifier("com.apple.menu.application.ext4") }
    static var rotationOptionsMenu: UIMenu.Identifier { UIMenu.Identifier("com.apple.menu.application.ext5") }
}
