import Foundation

@objc public protocol PlayCoverHelperProtocol {
    func configureAMFIBootArgs(completion: @escaping (NSError?) -> Void)
    func repairContainerPermissions(at path: String, completion: @escaping (NSError?) -> Void)
    func manageTCCPermissions(for bundleID: String, reset: Bool, completion: @escaping (NSError?) -> Void)
}

public enum PrivilegeEscalationTrack: Equatable {
    case xpcHelper
    case appleScriptGUI
}

public struct PrivilegePreFlightStatus: Equatable {
    public let sipDisabled: Bool
    public let nvramWritable: Bool
    public let amfiDisabledInNVRAM: Bool
    public let amfiDisabledInRunningOS: Bool

    public init(
        sipDisabled: Bool,
        nvramWritable: Bool,
        amfiDisabledInNVRAM: Bool,
        amfiDisabledInRunningOS: Bool
    ) {
        self.sipDisabled = sipDisabled
        self.nvramWritable = nvramWritable
        self.amfiDisabledInNVRAM = amfiDisabledInNVRAM
        self.amfiDisabledInRunningOS = amfiDisabledInRunningOS
    }
}
