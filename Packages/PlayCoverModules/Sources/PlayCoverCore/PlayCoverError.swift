import Foundation

public enum PlayCoverError: Error, Equatable {
    case infoPlistNotFound
    case waitInstallation
    case waitDownload
    case appEncrypted
    case appCorrupted
    case appProhibited
    case appMaliciousProhibited
    case failedToStripBinary
    case invalidUserDylib
    case shellExecutionFailed(binary: String, status: Int32, output: String)
    case appleScriptFailed(String)
    case playToolsError(String)
    case entitlementsError(String)
    case privilegeEscalationFailed(String)
    case networkError(String)
}

extension PlayCoverError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .infoPlistNotFound:
            return NSLocalizedString("error.corruptedIPA", comment: "")
        case .waitInstallation:
            return NSLocalizedString("error.waitInstallation", comment: "")
        case .waitDownload:
            return NSLocalizedString("error.waitDownload", comment: "")
        case .appEncrypted:
            return NSLocalizedString("error.appEncrypted", comment: "")
        case .appCorrupted:
            return NSLocalizedString("error.appCorrupted", comment: "")
        case .appProhibited:
            return NSLocalizedString("error.appProhibited", comment: "")
        case .appMaliciousProhibited:
            return NSLocalizedString("error.appMaliciousProhibited", comment: "")
        case .failedToStripBinary:
            return NSLocalizedString("error.failedToStripBinary", comment: "")
        case .invalidUserDylib:
            return NSLocalizedString("error.invalidUserDylib", comment: "")
        case let .shellExecutionFailed(_, _, output):
            return output.isEmpty ? "Shell command failed" : output
        case let .appleScriptFailed(message),
             let .playToolsError(message),
             let .entitlementsError(message),
             let .privilegeEscalationFailed(message),
             let .networkError(message):
            return message
        }
    }
}
