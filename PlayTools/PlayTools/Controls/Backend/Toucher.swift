//
//  Toucher.swift
//  PlayCoverInject
//

import Foundation
import UIKit

class Toucher {
    // For debug only
    static var logEnabled = false
    static var logFilePath =
    NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] + "/toucher.log"
    static private var logCount = 0
    static var logFile: FileHandle?
    private static var termObserverInstalled = false

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
        if FileManager.default.createFile(atPath: logFilePath, contents: nil, attributes: nil) {
            logFile = FileHandle(forWritingAtPath: logFilePath)
            Toast.showOver(msg: logFilePath)
        } else {
            Toast.showHint(title: "logFile creation failed")
            return
        }
        if !termObserverInstalled {
            termObserverInstalled = true
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name(rawValue: "NSApplicationWillTerminateNotification"),
                object: nil,
                queue: OperationQueue.main
            ) { _ in
                try? logFile?.close()
                logFile = nil
            }
        }
    }

    static func writeLog(logMessage: String) {
        if !logEnabled {
            return
        }
        if logFile == nil {
            setupLogfile()
        }
        guard let file = logFile else {
            return
        }
        let message = "\(DispatchTime.now().rawValue) \(logMessage)\n"
        guard let data = message.data(using: .utf8) else {
            Toast.showHint(title: "log message is utf8 uncodable")
            return
        }
        logCount += 1
        // roll over
        if logCount > 60000 {
            try? file.truncate(atOffset: 0)
            logCount = 0
        }
        file.write(data)
    }
}
