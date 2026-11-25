import Foundation
import Testing
@testable import PlayCoverCore
@testable import PlayCoverSandbox

@Suite(.serialized)
struct PlayCoverSandboxSPMTests {
    @Test
    func dualTrackPrivilegeEscalatorRulesAndCommandQuoting() {
        #expect(
            DualTrackPrivilegeEscalator.selectTrack(
                macOS13OrNewer: true,
                hasDeveloperIDTeam: true,
                hasEmbeddedHelperPlist: true
            ) == .xpcHelper
        )
        #expect(
            DualTrackPrivilegeEscalator.selectTrack(
                macOS13OrNewer: true,
                hasDeveloperIDTeam: true,
                hasEmbeddedHelperPlist: false
            ) == .appleScriptGUI
        )
        #expect(
            DualTrackPrivilegeEscalator.selectTrack(
                macOS13OrNewer: true,
                hasDeveloperIDTeam: false,
                hasEmbeddedHelperPlist: true
            ) == .appleScriptGUI
        )
        #expect(
            DualTrackPrivilegeEscalator.selectTrack(
                macOS13OrNewer: false,
                hasDeveloperIDTeam: true,
                hasEmbeddedHelperPlist: true
            ) == .appleScriptGUI
        )

        #expect(
            DualTrackPrivilegeEscalator.hasDeveloperIDIdentity(
                teamIdentifier: "ABCDE12345",
                leafCommonName: "Developer ID Application: Example Corp (ABCDE12345)"
            )
        )
        #expect(
            !DualTrackPrivilegeEscalator.hasDeveloperIDIdentity(
                teamIdentifier: "ABCDE12345",
                leafCommonName: "Apple Development: Test User"
            )
        )
        #expect(DualTrackPrivilegeEscalator.shellSingleQuoted("a'b") == "'a'\"'\"'b'")

        let script = DualTrackPrivilegeEscalator.buildAppleScriptPrivilegeCommand(
            binary: "/usr/sbin/nvram",
            arguments: ["boot-args=amfi_get_out_of_my_way=1"]
        )
        #expect(script.contains("with administrator privileges"))
        _ = DualTrackPrivilegeEscalator.preFlightStatus()
    }

    @Test
    func helperSecurityValidatorContainerAndBundleChecks() {
        #expect(HelperSecurityValidator.validateBundleIdentifier("app.makedie.MacOver"))
        #expect(!HelperSecurityValidator.validateBundleIdentifier("../bad"))
        #expect(!HelperSecurityValidator.validateBundleIdentifier(""))

        let containersRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .standardizedFileURL
        let validContainer = containersRoot
            .appendingPathComponent("com.example.game/Data/Library", isDirectory: true)
            .path

        #expect(HelperSecurityValidator.validateContainerPath(validContainer) != nil)
        #expect(HelperSecurityValidator.validateContainerPath(containersRoot.path + "/../Documents") == nil)
        #expect(HelperSecurityValidator.validateContainerPath("/etc/passwd") == nil)

        #expect(HelperSecurityValidator.isValidTeamIdentifier("ABCDE12345"))
        #expect(!HelperSecurityValidator.isValidTeamIdentifier("invalid-team!"))
        #expect(HelperSecurityValidator.clientCodeSigningRequirement(teamID: nil) == nil)
        #expect(HelperSecurityValidator.clientCodeSigningRequirement(teamID: "ABCDE12345") != nil)
    }
}
