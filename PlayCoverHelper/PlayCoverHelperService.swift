import Darwin
import Foundation
import PlayCoverCore
import PlayCoverSandbox

final class PlayCoverHelperService: NSObject, NSXPCListenerDelegate, PlayCoverHelperProtocol {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard HelperSecurityValidator.verifyIncomingConnection(newConnection) else {
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: PlayCoverHelperProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func configureAMFIBootArgs(completion: @escaping (NSError?) -> Void) {
        do {
            try runTool("/usr/sbin/nvram", arguments: ["boot-args=\(DualTrackPrivilegeEscalator.amfiBootArgs)"])
            completion(nil)
        } catch {
            completion(error as NSError)
        }
    }

    func repairContainerPermissions(at path: String, completion: @escaping (NSError?) -> Void) {
        guard let validatedPath = HelperSecurityValidator.validateContainerPath(path) else {
            completion(
                PlayCoverError.privilegeEscalationFailed("Rejected invalid container path for permission repair.")
                    as NSError
            )
            return
        }
        guard FileManager.default.fileExists(atPath: validatedPath) else {
            completion(
                PlayCoverError.privilegeEscalationFailed("Container directory does not exist at path.") as NSError
            )
            return
        }
        do {
            if let owner = Self.resolveHomeOwner(fromContainerPath: validatedPath) {
                try runTool("/usr/sbin/chown", arguments: ["-R", "\(owner.uid):\(owner.gid)", validatedPath])
            }
            try runTool("/bin/chmod", arguments: ["-R", "u+rwX", validatedPath])
            completion(nil)
        } catch {
            completion(error as NSError)
        }
    }

    func manageTCCPermissions(for bundleID: String, reset: Bool, completion: @escaping (NSError?) -> Void) {
        guard HelperSecurityValidator.validateBundleIdentifier(bundleID) else {
            completion(
                PlayCoverError.privilegeEscalationFailed("Rejected invalid bundle identifier for TCC management.")
                    as NSError
            )
            return
        }
        guard reset else {
            completion(nil)
            return
        }
        do {
            try runTool("/usr/bin/tccutil", arguments: ["reset", "All", bundleID])
            completion(nil)
        } catch {
            completion(error as NSError)
        }
    }

    private static func resolveHomeOwner(fromContainerPath path: String) -> (uid: uid_t, gid: gid_t)? {
        let components = URL(fileURLWithPath: path).pathComponents
        guard components.count >= 3, components[1] == "Users" else {
            return nil
        }
        let userHome = "/Users/\(components[2])"
        var st = Darwin.stat()
        guard stat(userHome, &st) == 0 else {
            return nil
        }
        return (st.st_uid, st.st_gid)
    }

    private func runTool(_ binary: String, arguments: [String]) throws {
        let process = Process()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardOutput = errPipe
        process.standardError = errPipe
        defer {
            try? errPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForWriting.close()
        }
        try process.run()
        try? errPipe.fileHandleForWriting.close()
        let outData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let output = String(data: outData, encoding: .utf8) ?? ""
            throw PlayCoverError.shellExecutionFailed(
                binary: binary,
                status: process.terminationStatus,
                output: output
            )
        }
    }
}
