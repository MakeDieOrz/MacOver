//
//  PlayCover.swift
//  PlayTools
//

import Darwin
import Foundation
import UIKit

public final class PlayCover: NSObject, Sendable {

    static let shared = PlayCover()
    @MainActor var menuController: MenuController?
    @MainActor private var isTerminatingFromWindowClose = false

    @objc static public func launch() {
        _ = PTSafeMode.shared.ensureEvaluatedForCurrentProcess()

        if PlaySettings.shared.rootWorkDir {
            // Change the working directory to / just like iOS
            FileManager.default.changeCurrentDirectoryPath("/")
        }

        quitWhenClose()
        AKInterface.initialize()
        UserPluginLoader.initialize()
        PlayScreen.shared.initialize()
        PlayInput.shared.initialize()
        DiscordIPC.shared.initialize()

        let rotation = PlaySettings.shared.displayRotation
        if rotation != 0 {
            if AKInterface.shared?.isSequoiaOrNewer == true {
                let isPortrait = (rotation % 4 == 1 || rotation % 4 == 3)
                let targetSize = CGSize(
                    width: PlaySettings.shared.windowSizeWidth,
                    height: PlaySettings.shared.windowSizeHeight
                )
                AKInterface.shared?.setWindowOrientation?(portrait: isPortrait, targetSize: targetSize)
            }
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.5, execute: {
                let rotateCommand = UIKeyCommand(
                    title: "Keep Rotation Command",
                    image: nil,
                    action: #selector(UIApplication.rotateView(_:)),
                    input: "",
                    modifierFlags: [],
                    propertyList: ["rotationIndex": rotation]
                )
                UIApplication.shared.sendAction(
                    #selector(UIApplication.rotateView(_:)),
                    to: UIApplication.shared,
                    from: rotateCommand,
                    for: nil
                )
            })
        }
    }

    @objc static public func initMenu(menu: NSObject) {
        guard let menuBuilder = menu as? UIMenuBuilder else { return }
        if Thread.isMainThread {
            nonisolated(unsafe) let unsafeMenuBuilder = menuBuilder
            MainActor.assumeIsolated {
                shared.menuController = MenuController(with: unsafeMenuBuilder)
            }
        }
    }

    static public func quitWhenClose() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "NSApplicationWillTerminateNotification"),
            object: nil,
            queue: OperationQueue.main
        ) { _ in
            MainActor.assumeIsolated {
                shared.isTerminatingFromWindowClose = true
                PTSafeMode.shared.markGracefulTermination()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "NSWindowWillCloseNotification"),
            object: nil,
            queue: OperationQueue.main
        ) { notif in
            nonisolated(unsafe) let closedObject = notif.object
            MainActor.assumeIsolated {
                guard !shared.isTerminatingFromWindowClose else { return }
                let shouldQuit: Bool
                if let closedNSObject = closedObject as? NSObject {
                    if let decide = AKInterface.shared?.shouldTerminateOnWindowClose {
                        shouldQuit = decide(closedNSObject)
                    } else {
                        shouldQuit = PlayScreen.shared.nsWindow?.isEqual(closedNSObject) ?? false
                    }
                } else {
                    shouldQuit = false
                }
                if shouldQuit {
                    shared.isTerminatingFromWindowClose = true
                    PTSafeMode.shared.markGracefulTermination()

                    // Do NOT manually post UIScene / UIApplication lifecycle notifications synchronously inside
                    // NSWindowWillCloseNotification: AppKit fires it mid-[UIScene _invalidate], and forging
                    // UIApplication.willResignActiveNotification hits a UINSUIKitBackgroundingController assertion
                    // (SIGABRT). Defer to NSApplication.terminate(nil) so AppKit & UIKitMacHelper drive shutdown.
                    if let terminate = AKInterface.shared?.terminateApplication {
                        DispatchQueue.main.async {
                            terminate()
                        }
                    } else {
                        DispatchQueue.main.async {
                            Darwin.exit(0)
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        Darwin.exit(0)
                    }
                }
            }
        }
    }

    static func delay(_ delay: Double, closure: @escaping @MainActor @Sendable () -> Void) {
        let when = DispatchTime.now() + delay
        DispatchQueue.main.asyncAfter(deadline: when) {
            MainActor.assumeIsolated(closure)
        }
    }
}
