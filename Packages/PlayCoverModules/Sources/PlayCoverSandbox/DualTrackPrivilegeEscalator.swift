import Foundation
import PlayCoverCore
import Security
import ServiceManagement

public enum DualTrackPrivilegeEscalator {
    public static let helperMachServiceName = "io.playcover.PlayCover.Helper"
    public static let helperDaemonPlistName = "io.playcover.PlayCover.Helper.plist"
    public static let amfiBootArgs = "amfi_get_out_of_my_way=0x1 ipc_control_port_options=0"

    private static let nvramAMFIOptions = [
        "amfi_get_out_of_my_way=1",
        "amfi_get_out_of_my_way=0x1",
        "amfi_get_out_of_my_way=1 ipc_control_port_options=0",
        "amfi_get_out_of_my_way=0x1 ipc_control_port_options=0"
    ]

    public static func selectTrack(
        macOS13OrNewer: Bool,
        hasDeveloperIDTeam: Bool,
        hasEmbeddedHelperPlist: Bool
    ) -> PrivilegeEscalationTrack {
        if macOS13OrNewer && hasDeveloperIDTeam && hasEmbeddedHelperPlist {
            return .xpcHelper
        }
        return .appleScriptGUI
    }

    public static func activeTrack(bundle: Bundle = .main) -> PrivilegeEscalationTrack {
        selectTrack(
            macOS13OrNewer: true,
            hasDeveloperIDTeam: currentProcessHasDeveloperIDTeam(),
            hasEmbeddedHelperPlist: embeddedHelperDaemonPlistExists(in: bundle)
        )
    }

    public static func embeddedHelperDaemonPlistExists(in bundle: Bundle = .main) -> Bool {
        let daemonURL = bundle.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
            .appendingPathComponent(helperDaemonPlistName)
        let toolURL = bundle.bundleURL
            .appendingPathComponent("Contents/Library/HelperTools/PlayCoverHelper")
        let fm = FileManager.default
        return fm.fileExists(atPath: daemonURL.path) && fm.isExecutableFile(atPath: toolURL.path)
    }

    public static func hasDeveloperIDIdentity(teamIdentifier: String?, leafCommonName: String?) -> Bool {
        guard let teamID = teamIdentifier, !teamID.isEmpty,
              let commonName = leafCommonName else {
            return false
        }
        return commonName.hasPrefix("Developer ID Application:")
    }

    public static func currentProcessHasDeveloperIDTeam() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let selfCode = code else {
            return false
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticSelf = staticCode else {
            return false
        }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticSelf,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoCF
        ) == errSecSuccess,
        let info = infoCF as? [String: Any],
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String,
        !teamID.isEmpty else {
            return false
        }

        let devIDRequirementString =
            "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ " +
            "and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */" as CFString
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(devIDRequirementString, SecCSFlags(), &requirement) == errSecSuccess,
              let devIDRequirement = requirement else {
            return false
        }
        return SecStaticCodeCheckValidity(staticSelf, SecCSFlags(), devIDRequirement) == errSecSuccess
    }

    public static func shellSingleQuoted(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    public static func appleScriptEscaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    public static func buildAppleScriptPrivilegeCommand(binary: String, arguments: [String]) -> String {
        let shellCommand = ([binary] + arguments)
            .map { shellSingleQuoted($0) }
            .joined(separator: " ")
        return "do shell script \"\(appleScriptEscaped(shellCommand))\" with administrator privileges"
    }

    public static func preFlightStatus() -> PrivilegePreFlightStatus {
        let csrOutput = (try? runReadOnlyProcess("/usr/bin/csrutil", arguments: ["status"])) ?? ""
        let sipDisabled = csrOutput.contains("unknown") || csrOutput.contains("disabled")

        let nvramResult = try? runReadOnlyProcess("/usr/sbin/nvram", arguments: ["boot-args"])
        let amfiInNVRAM = nvramResult.map { out in
            nvramAMFIOptions.contains(where: { out.contains($0) })
        } ?? false

        // Without SIP NVRAM bypass, modifying boot-args fails even with root privileges.
        let nvramWritable = sipDisabled || csrOutput.contains("NVRAM Protections: disabled")

        let sysctlOutput = (try? runReadOnlyProcess("/usr/sbin/sysctl", arguments: ["kern.bootargs"])) ?? ""
        let amfiInRunningOS = nvramAMFIOptions.contains(where: { sysctlOutput.contains($0) })

        return PrivilegePreFlightStatus(
            sipDisabled: sipDisabled,
            nvramWritable: nvramWritable,
            amfiDisabledInNVRAM: amfiInNVRAM,
            amfiDisabledInRunningOS: amfiInRunningOS
        )
    }

    public static func enableAMFIBootArgs() async throws {
        let status = preFlightStatus()
        if status.amfiDisabledInNVRAM {
            return
        }
        guard status.nvramWritable else {
            throw PlayCoverError.privilegeEscalationFailed(
                "System Integrity Protection NVRAM protections are active. Disable SIP or NVRAM protection in Recovery OS before configuring AMFI boot-args."
            )
        }

        switch activeTrack() {
        case .xpcHelper:
            try await callXPCHelper { proxy, done in
                proxy.configureAMFIBootArgs(completion: done)
            }
        case .appleScriptGUI:
            try await executeAppleScriptAdminCommand(
                binary: "/usr/sbin/nvram",
                arguments: ["boot-args=\(amfiBootArgs)"]
            )
        }
    }

    public static func repairContainerPermissions(at path: String) async throws {
        guard let validatedPath = HelperSecurityValidator.validateContainerPath(path) else {
            throw PlayCoverError.privilegeEscalationFailed("Refused permission repair for invalid container path.")
        }

        switch activeTrack() {
        case .xpcHelper:
            try await callXPCHelper { proxy, done in
                proxy.repairContainerPermissions(at: validatedPath, completion: done)
            }
        case .appleScriptGUI:
            try await executeAppleScriptAdminCommand(
                binary: "/bin/chmod",
                arguments: ["-R", "u+rwX", validatedPath]
            )
        }
    }

    public static func manageTCCPermissions(for bundleID: String, reset: Bool) async throws {
        guard HelperSecurityValidator.validateBundleIdentifier(bundleID) else {
            throw PlayCoverError.privilegeEscalationFailed("Refused TCC change for invalid bundle identifier.")
        }
        guard reset else { return }

        switch activeTrack() {
        case .xpcHelper:
            try await callXPCHelper { proxy, done in
                proxy.manageTCCPermissions(for: bundleID, reset: true, completion: done)
            }
        case .appleScriptGUI:
            try await executeAppleScriptAdminCommand(
                binary: "/usr/bin/tccutil",
                arguments: ["reset", "All", bundleID]
            )
        }
    }

    private static func callXPCHelper(
        _ invoke: @escaping (PlayCoverHelperProtocol, @escaping (NSError?) -> Void) -> Void
    ) async throws {
        let service = SMAppService.daemon(plistName: helperDaemonPlistName)
        if service.status != .enabled {
            try service.register()
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let connection = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: PlayCoverHelperProtocol.self)

            let lock = NSLock()
            var resumed = false
            func finish(_ result: Result<Void, Error>) {
                lock.lock()
                guard !resumed else {
                    lock.unlock()
                    return
                }
                resumed = true
                lock.unlock()
                connection.invalidate()
                continuation.resume(with: result)
            }

            connection.invalidationHandler = {
                finish(.failure(PlayCoverError.privilegeEscalationFailed("Privileged helper XPC connection invalidated.")))
            }
            connection.interruptionHandler = {
                finish(.failure(PlayCoverError.privilegeEscalationFailed("Privileged helper XPC connection interrupted.")))
            }
            connection.resume()

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                finish(.failure(error))
            }) as? PlayCoverHelperProtocol else {
                finish(.failure(PlayCoverError.privilegeEscalationFailed("Failed to obtain PlayCoverHelperProtocol proxy.")))
                return
            }

            invoke(proxy) { error in
                if let error {
                    finish(.failure(error))
                } else {
                    finish(.success(()))
                }
            }
        }
    }

    public static func executeAppleScriptAdminCommand(binary: String, arguments: [String]) async throws {
        let source = buildAppleScriptPrivilegeCommand(binary: binary, arguments: arguments)
        try await MainActor.run {
            guard let script = NSAppleScript(source: source) else {
                throw PlayCoverError.appleScriptFailed("Failed to initialize NSAppleScript.")
            }
            var errorInfo: NSDictionary?
            script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let message = (errorInfo[NSAppleScript.errorMessage] as? String)
                    ?? (errorInfo[NSAppleScript.errorBriefMessage] as? String)
                    ?? "Administrator authentication canceled or failed."
                throw PlayCoverError.privilegeEscalationFailed(message)
            }
        }
    }

    private static func runReadOnlyProcess(_ binary: String, arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        try process.run()
        try? pipe.fileHandleForWriting.close()
        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw PlayCoverError.shellExecutionFailed(
                binary: binary,
                status: process.terminationStatus,
                output: output
            )
        }
        return output
    }
}
