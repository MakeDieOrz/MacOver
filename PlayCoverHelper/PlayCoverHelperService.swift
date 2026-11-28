import Darwin
import Foundation
import PlayCoverCore
import PlayCoverSandbox

final class PlayCoverHelperService: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard let identity = HelperSecurityValidator.verifyIncomingConnectionIdentity(newConnection) else {
            return false
        }
        let session = PlayCoverHelperClientSession(identity: identity)
        newConnection.exportedInterface = NSXPCInterface(with: PlayCoverHelperProtocol.self)
        newConnection.exportedObject = session
        newConnection.resume()
        return true
    }
}

private final class PlayCoverHelperClientSession: NSObject, PlayCoverHelperProtocol {
    private let identity: VerifiedXPCClientIdentity

    private var managedAppsDirectory: URL {
        URL(fileURLWithPath: identity.homeDirectory)
            .appendingPathComponent("Library/Containers/app.makedie.MacOver/Applications", isDirectory: true)
    }

    init(identity: VerifiedXPCClientIdentity) {
        self.identity = identity
        super.init()
    }

    func configureAMFIBootArgs(completion: @escaping (NSError?) -> Void) {
        do {
            let existing = try? runToolCapturingOutput("/usr/sbin/nvram", arguments: ["boot-args"])
            let merged = DualTrackPrivilegeEscalator.mergedAMFIBootArgs(existingOutput: existing)
            try runTool("/usr/sbin/nvram", arguments: ["boot-args=\(merged)"])
            completion(nil)
        } catch {
            completion(error as NSError)
        }
    }

    func repairContainerPermissions(at path: String, completion: @escaping (NSError?) -> Void) {
        do {
            try HelperSecurityValidator.repairContainerPermissionsSecurely(
                at: path,
                userHomeRoot: identity.homeDirectory,
                ownerUID: identity.uid,
                ownerGID: identity.gid,
                managedAppsDirectory: managedAppsDirectory
            )
            completion(nil)
        } catch {
            completion(error as NSError)
        }
    }

    func manageTCCPermissions(for bundleID: String, reset: Bool, completion: @escaping (NSError?) -> Void) {
        guard HelperSecurityValidator.isManagedAppBundleID(bundleID, in: managedAppsDirectory) else {
            completion(
                PlayCoverError.privilegeEscalationFailed(
                    "Rejected unmanaged or reserved bundle identifier for TCC management."
                ) as NSError
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

    private func runTool(_ binary: String, arguments: [String]) throws {
        _ = try runToolCapturingOutput(binary, arguments: arguments)
    }

    private func runToolCapturingOutput(_ binary: String, arguments: [String]) throws -> String {
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
        let output = String(data: outData, encoding: .utf8) ?? ""
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
