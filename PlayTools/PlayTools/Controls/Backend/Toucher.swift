//
//  Toucher.swift
//  PlayCoverInject
//

import Darwin
import Foundation
import Synchronization
import UIKit

final class Toucher: Sendable {
    private struct LogState {
        var logEnabled = false
        var logFilePath: String?
        var logCount = 0
        var logFile: FileHandle?
        var termObserverInstalled = false
    }

    private static let state = Mutex(LogState())

    private static var isLoggingPermitted: Bool {
        #if DEBUG
        return !PlaySettings.shared.bypass && !PlaySettings.shared.strictEmulationMode
        #else
        return false
        #endif
    }

    // For debug only (strictly disabled under bypass/strictEmulationMode and Release builds).
    static var logEnabled: Bool {
        get {
            guard isLoggingPermitted else { return false }
            return state.withLock { $0.logEnabled }
        }
        set {
            state.withLock { $0.logEnabled = isLoggingPermitted ? newValue : false }
        }
    }
    static var logFilePath: String {
        get {
            state.withLock { current in
                if let existing = current.logFilePath {
                    return existing
                }
                let path = FileManager.default.temporaryDirectory
                    .appendingPathComponent("toucher.log")
                    .path
                current.logFilePath = path
                return path
            }
        }
        set { state.withLock { $0.logFilePath = newValue } }
    }
    static var logFile: FileHandle? {
        get { state.withLock { $0.logFile } }
        set { state.withLock { $0.logFile = newValue } }
    }

    static func clearCachedTargets() {
        // Hit-testing now runs asynchronously inside PTFakeMetaTouch's main-runloop source.
    }

    /**
     on invocations with phase "began", an int id is allocated, which can be used later to refer to this touch point.
     on invocations with phase "ended", id is set to nil representing the touch point is no longer valid.
     */
    static func touchcam(point: CGPoint, phase: UITouch.Phase, tid: inout Int?,
                         // Name info for debug use
                         actionName: String, keyName: String) {
        if phase == UITouch.Phase.began {
            if tid != nil {
                return
            }
            let allocatedId = PTFakeMetaTouch.fakeTouchId(-1, at: point, with: phase,
                                                          in: nil, on: nil)
            if logEnabled {
                writeLog(logMessage:
                    "\(phase.rawValue.description) \(allocatedId.description) \(point.debugDescription)")
            }
            guard allocatedId >= 0 else {
                tid = nil
                return
            }
            tid = allocatedId
            DebugModel.instance.record(point: point, phase: phase, tid: allocatedId,
                                       description: actionName + "(" + keyName + ")")
            return
        }

        guard let activeId = tid, activeId >= 0 else {
            return
        }
        let isTerminal = (phase == .ended || phase == .cancelled)

        let resultId = PTFakeMetaTouch.fakeTouchId(activeId, at: point, with: phase,
                                                   in: nil, on: nil)
        if logEnabled {
            writeLog(logMessage:
                "\(phase.rawValue.description) \(resultId.description) \(point.debugDescription)")
        }
        let recordId: Int
        if isTerminal || resultId < 0 {
            tid = nil
            recordId = activeId
        } else {
            tid = resultId
            recordId = resultId
        }
        DebugModel.instance.record(point: point, phase: phase, tid: recordId,
                                   description: actionName + "(" + keyName + ")")
    }

    static func setupLogfile() {
        guard isLoggingPermitted, logEnabled else { return }
        let path = logFilePath
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        if fd >= 0 {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var shouldInstallObserver = false
            state.withLock {
                $0.logFile = handle
                if !$0.termObserverInstalled {
                    $0.termObserverInstalled = true
                    shouldInstallObserver = true
                }
            }
            Toast.showOver(msg: path)
            if shouldInstallObserver {
                NotificationCenter.default.addObserver(
                    forName: NSNotification.Name(rawValue: "NSApplicationWillTerminateNotification"),
                    object: nil,
                    queue: OperationQueue.main
                ) { _ in
                    let closing = state.withLock { state -> FileHandle? in
                        let f = state.logFile
                        state.logFile = nil
                        return f
                    }
                    try? closing?.close()
                }
            }
        } else {
            Toast.showHint(title: "logFile creation failed")
            return
        }
    }

    static func writeLog(logMessage: String) {
        guard isLoggingPermitted, logEnabled else {
            return
        }
        if logFile == nil {
            setupLogfile()
        }
        let message = "\(DispatchTime.now().rawValue) \(logMessage)\n"
        guard let data = message.data(using: .utf8) else {
            Toast.showHint(title: "log message is utf8 uncodable")
            return
        }
        state.withLock { state in
            guard let file = state.logFile else {
                return
            }
            state.logCount += 1
            // roll over
            if state.logCount > 60000 {
                try? file.truncate(atOffset: 0)
                state.logCount = 0
            }
            file.write(data)
        }
    }
}
