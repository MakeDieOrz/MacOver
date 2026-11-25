import Foundation
import Synchronization

public enum PlayCoverDiagnosticToastKind: Equatable, Sendable {
    case notice
    case error
    case network
}

public enum PlayCoverDiagnostics {
    private struct Handlers {
        var logHandler: (@Sendable (String, Bool) -> Void)?
        var errorHandler: (@Sendable (String) -> Void)?
        var messageHandler: (@Sendable (String) -> Void)?
        var toastHandler: (@Sendable (PlayCoverDiagnosticToastKind, String, UInt64) -> Void)?
        var activeToastChecker: (@Sendable (PlayCoverDiagnosticToastKind) -> Bool)?
    }

    private static let state = Mutex<Handlers>(Handlers())

    public static func configure(
        logHandler: (@Sendable (String, Bool) -> Void)?,
        errorHandler: (@Sendable (String) -> Void)?,
        messageHandler: (@Sendable (String) -> Void)?,
        toastHandler: (@Sendable (PlayCoverDiagnosticToastKind, String, UInt64) -> Void)?,
        activeToastChecker: (@Sendable (PlayCoverDiagnosticToastKind) -> Bool)? = nil
    ) {
        state.withLock { handlers in
            handlers.logHandler = logHandler
            handlers.errorHandler = errorHandler
            handlers.messageHandler = messageHandler
            handlers.toastHandler = toastHandler
            handlers.activeToastChecker = activeToastChecker
        }
    }

    public static func reset() {
        state.withLock { handlers in
            handlers = Handlers()
        }
    }

    public static func log(_ str: String, isError: Bool = false) {
        let handler = state.withLock { $0.logHandler }
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
        let handler = state.withLock { $0.errorHandler }
        if let handler {
            handler(message)
        } else {
            log(message, isError: true)
        }
    }

    public static func reportMessage(_ message: String) {
        let handler = state.withLock { $0.messageHandler }
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
        let handler = state.withLock { $0.toastHandler }
        if let handler {
            handler(toastType, toastDetails, timeRemaining)
        } else {
            log(toastDetails, isError: toastType == .error)
        }
    }

    public static func hasActiveToast(ofType kind: PlayCoverDiagnosticToastKind) -> Bool {
        let checker = state.withLock { $0.activeToastChecker }
        return checker?(kind) ?? false
    }
}
