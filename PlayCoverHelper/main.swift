import Foundation
import PlayCoverSandbox

let helperService = PlayCoverHelperService()
let listener = NSXPCListener(machServiceName: DualTrackPrivilegeEscalator.helperMachServiceName)
if let requirement = HelperSecurityValidator.clientCodeSigningRequirement() {
    listener.setConnectionCodeSigningRequirement(requirement)
}
listener.delegate = helperService
listener.resume()
RunLoop.current.run()
