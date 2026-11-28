//
//  Shell.swift
//  PlayCover
//

import AppKit
import Foundation

public class Shell {
    public init() {}

    @discardableResult
    public static func run(print: Bool = true, _ binary: String, _ args: String...) throws -> String {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe

        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }

        try process.run()
        try? pipe.fileHandleForWriting.close()

        let output: Data
        do {
            output = try pipe.fileHandleForReading.readToEnd() ?? Data()
        } catch {
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()

        let text = String(data: output, encoding: .utf8) ?? "Shell error occured"
        if print {
            PlayCoverDiagnostics.log(text)
        }

        let status = process.terminationStatus
        if status != 0 {
            throw PlayCoverError.shellExecutionFailed(binary: binary, status: status, output: text)
        }
        return text
    }

    public static func signMacho(_ binary: URL) throws {
        try run("/usr/bin/codesign", "-fs-", binary.path)
    }

    public static func signAppWith(_ exec: URL, entitlements: URL) throws {
        try run("/usr/bin/codesign", "-fs-", exec.deletingLastPathComponent().path,
                "--deep", "--entitlements", entitlements.path)
    }

    public static func signApp(_ exec: URL) throws {
        try run("/usr/bin/codesign", "-fs-", exec.deletingLastPathComponent().path,
                "--deep", "--preserve-metadata=entitlements")
    }

    public static func verifyAppSignature(_ bundleURL: URL) throws {
        try run("/usr/bin/codesign", "--verify", "--deep", "--strict", bundleURL.path)
    }

    public static func isValidBundleIdentifier(_ bundleID: String) -> Bool {
        guard bundleID.count >= 2, bundleID.count <= 128 else {
            return false
        }
        guard bundleID.contains("."),
              !bundleID.hasPrefix("."),
              !bundleID.hasPrefix("-"),
              !bundleID.hasSuffix("."),
              !bundleID.contains("..") else {
            return false
        }
        return bundleID.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (v >= 0x30 && v <= 0x39)
                || (v >= 0x41 && v <= 0x5A)
                || (v >= 0x61 && v <= 0x7A)
                || v == 0x2E
                || v == 0x2D
                || v == 0x5F
        }
    }

    public static func setMetalHUD(_ bundleID: String, enabled: Bool) throws {
        guard isValidBundleIdentifier(bundleID) else {
            throw PlayCoverError.playToolsError(
                "Refused to update Metal HUD for invalid bundle identifier: \(bundleID)"
            )
        }
        try run("/usr/bin/defaults", "write", bundleID,
                "MetalForceHudEnabled", "-bool", String(enabled))
    }

    public static func lldb(
        _ url: URL,
        withTerminalWindow: Bool = false,
        onExit: (@Sendable (Bool) -> Void)? = nil
    ) throws {
        Task(priority: .utility) {
            var launchedSuccessfully = false
            do {
                if withTerminalWindow {
                    let command = "/usr/bin/lldb -o run \(url.esc) -o exit"
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                    let osascript = """
                        tell app "Terminal"
                            reopen
                            activate
                            do script "\(command)"
                        end tell
                    """
                    let appleScript = NSAppleScript(source: osascript)
                    var possibleError: NSDictionary?
                    appleScript?.executeAndReturnError(&possibleError)

                    if let error = possibleError {
                        let desc = error.allKeys.compactMap { ($0 as? String).flatMap { error[$0] } }
                            .map { String(describing: $0) }
                            .joined(separator: "; ")
                        throw PlayCoverError.appleScriptFailed(desc.isEmpty ? "AppleScript error" : desc)
                    }
                    launchedSuccessfully = true
                } else {
                    try run("/usr/bin/lldb", "-o", "run", url.path, "-o", "exit")
                    launchedSuccessfully = true
                }
            } catch {
                PlayCoverDiagnostics.reportError(error)
            }
            onExit?(launchedSuccessfully)
        }
    }
}
