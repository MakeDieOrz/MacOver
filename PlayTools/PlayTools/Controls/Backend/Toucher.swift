//
//  Toucher.swift
//  PlayCoverInject
//

import Foundation
import UIKit

final class Toucher: Sendable {
    private final class LogState: @unchecked Sendable {
        var logEnabled = false
        var logFilePath =
            NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] + "/toucher.log"
        var logCount = 0
        var logFile: FileHandle?
        var termObserverInstalled = false
    }

    private static let stateLock = PTUnfairLock()
    private static let state = LogState()

    // For debug only
    static var logEnabled: Bool {
        get { stateLock.withLock { state.logEnabled } }
        set { stateLock.withLock { state.logEnabled = newValue } }
    }
    static var logFilePath: String {
        get { stateLock.withLock { state.logFilePath } }
        set { stateLock.withLock { state.logFilePath = newValue } }
    }
    static var logFile: FileHandle? {
        get { stateLock.withLock { state.logFile } }
        set { stateLock.withLock { state.logFile = newValue } }
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
        let path = logFilePath
        if FileManager.default.createFile(atPath: path, contents: nil, attributes: nil) {
            let handle = FileHandle(forWritingAtPath: path)
            var shouldInstallObserver = false
            stateLock.withLock {
                state.logFile = handle
                if !state.termObserverInstalled {
                    state.termObserverInstalled = true
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
                    let closing = stateLock.withLock { () -> FileHandle? in
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
        if !logEnabled {
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
        stateLock.withLock {
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
