//
//  SystemConfig.swift
//  PlayCover
//

import Darwin
import Foundation
import PlayCoverCore
import Synchronization

public class SystemConfig {
    private static let isFirstTimePlaySignLock = Mutex<Bool>(false)

    public static var isFirstTimePlaySign: Bool {
        get { isFirstTimePlaySignLock.withLock { $0 } }
        set { isFirstTimePlaySignLock.withLock { $0 = newValue } }
    }

    public static var isPlaySignActive: Bool {
        isSIPDisabled() && isRunningAMFIEnabled()
    }

    public static func preFlightStatus() -> PrivilegePreFlightStatus {
        DualTrackPrivilegeEscalator.preFlightStatus()
    }

    public static func enablePlaySign() async throws {
        try await DualTrackPrivilegeEscalator.enableAMFIBootArgs()
    }

    public static func isSIPDisabled() -> Bool {
        do {
            let check = try Shell.run("/usr/bin/csrutil", "status")
            return DualTrackPrivilegeEscalator.parseSIPDisabled(from: check)
        } catch {
            return false
        }
    }

    public static func isPRAMValid() -> Bool {
        do {
            let check = try Shell.run("/usr/sbin/nvram", "boot-args")
            return DualTrackPrivilegeEscalator.hasAMFIBootArg(in: check)
        } catch {
            return false
        }
    }

    public static func isRunningAMFIEnabled() -> Bool {
        var size = 0
        guard Darwin.sysctlbyname("kern.bootargs", nil, &size, nil, 0) == 0, size > 0 else {
            return false
        }
        var buffer = [CChar](repeating: 0, count: size + 1)
        guard Darwin.sysctlbyname("kern.bootargs", &buffer, &size, nil, 0) == 0 else {
            return false
        }
        let endIndex = buffer.firstIndex(of: 0) ?? buffer.count
        let bootArgs = String(
            bytes: buffer.prefix(endIndex).map { UInt8(bitPattern: $0) },
            encoding: .utf8
        ) ?? ""
        return DualTrackPrivilegeEscalator.hasAMFIBootArg(in: bootArgs)
    }
}
