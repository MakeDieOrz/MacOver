//
//  SystemConfig.swift
//  PlayCover
//

import Foundation
import PlayCoverCore
import Synchronization

public class SystemConfig {
    private static let isFirstTimePlaySignLock = Mutex<Bool>(false)

    public static var isFirstTimePlaySign: Bool {
        get { isFirstTimePlaySignLock.withLock { $0 } }
        set { isFirstTimePlaySignLock.withLock { $0 = newValue } }
    }

    public static let isPlaySignActive: Bool = isSIPDisabled() && isRunningAMFIEnabled()

    public static func preFlightStatus() -> PrivilegePreFlightStatus {
        DualTrackPrivilegeEscalator.preFlightStatus()
    }

    public static func enablePlaySign() async throws {
        try await DualTrackPrivilegeEscalator.enableAMFIBootArgs()
    }

    public static func isSIPDisabled() -> Bool {
        do {
            let check = try Shell.run("/usr/bin/csrutil", "status")
            return check.contains("unknown") || check.contains("disabled")
        } catch {
            return false
        }
    }

    public static func isPRAMValid() -> Bool {
        do {
            let check = try Shell.run("/usr/sbin/nvram", "boot-args")
            for option in NVRAM_OPTIONS where check.contains(option) {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    public static func isRunningAMFIEnabled() -> Bool {
        do {
            let check = try Shell.run("/usr/sbin/sysctl", "kern.bootargs")
            for option in NVRAM_OPTIONS where check.contains(option) {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    private static let NVRAM_OPTIONS = [
        "amfi_get_out_of_my_way=1",
        "amfi_get_out_of_my_way=0x1",
        "amfi_get_out_of_my_way=1 ipc_control_port_options=0",
        "amfi_get_out_of_my_way=0x1 ipc_control_port_options=0"
    ]
}
