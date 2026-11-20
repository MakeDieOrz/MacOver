import Foundation

public enum PlayCoverDiagnosticToastKind: Equatable, Sendable {
    case notice
    case error
    case network
}

public enum PlayCoverDiagnostics {
    private static let lock = NSLock()
    private static var logHandler: ((String, Bool) -> Void)?
    private static var errorHandler: ((String) -> Void)?
    private static var messageHandler: ((String) -> Void)?
    private static var toastHandler: ((PlayCoverDiagnosticToastKind, String, UInt64) -> Void)?
    private static var activeToastChecker: ((PlayCoverDiagnosticToastKind) -> Bool)?

    public static func configure(
        logHandler: ((String, Bool) -> Void)?,
        errorHandler: ((String) -> Void)?,
        messageHandler: ((String) -> Void)?,
        toastHandler: ((PlayCoverDiagnosticToastKind, String, UInt64) -> Void)?,
        activeToastChecker: ((PlayCoverDiagnosticToastKind) -> Bool)? = nil
    ) {
        lock.lock()
        self.logHandler = logHandler
        self.errorHandler = errorHandler
        self.messageHandler = messageHandler
        self.toastHandler = toastHandler
        self.activeToastChecker = activeToastChecker
        lock.unlock()
    }

    public static func reset() {
        lock.lock()
        logHandler = nil
        errorHandler = nil
        messageHandler = nil
        toastHandler = nil
        activeToastChecker = nil
        lock.unlock()
    }

    public static func log(_ str: String, isError: Bool = false) {
        lock.lock()
        let handler = logHandler
        lock.unlock()
        if let handler {
            handler(str, isError)
        } else {
            print(isError ? "ERROR: \(str)" : str)
        }
    }

    public static func reportError(_ error: Error) {
        reportError(error.localizedDescription)
    }

    public static func reportError(_ message: String) {
        lock.lock()
        let handler = errorHandler
        lock.unlock()
        if let handler {
            handler(message)
        } else {
            log(message, isError: true)
        }
    }

    public static func reportMessage(_ message: String) {
        lock.lock()
        let handler = messageHandler
        lock.unlock()
        if let handler {
            handler(message)
        } else {
            log(message, isError: false)
        }
    }

    public static func showToast(
        toastType: PlayCoverDiagnosticToastKind,
        toastDetails: String,
        timeRemaining: UInt64 = 3
    ) {
        lock.lock()
        let handler = toastHandler
        lock.unlock()
        if let handler {
            handler(toastType, toastDetails, timeRemaining)
        } else {
            log(toastDetails, isError: toastType == .error)
        }
    }

    public static func hasActiveToast(ofType kind: PlayCoverDiagnosticToastKind) -> Bool {
        lock.lock()
        let checker = activeToastChecker
        lock.unlock()
        return checker?(kind) ?? false
    }
}
