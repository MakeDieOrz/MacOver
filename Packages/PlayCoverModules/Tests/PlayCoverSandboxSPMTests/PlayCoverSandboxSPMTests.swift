import Foundation
import XCTest
@testable import PlayCoverCore
@testable import PlayCoverSandbox

final class PlayCoverSandboxSPMTests: XCTestCase {
    func testDualTrackPrivilegeEscalatorRulesAndCommandQuoting() {
        XCTAssertEqual(
            DualTrackPrivilegeEscalator.selectTrack(
                macOS13OrNewer: true,
                hasDeveloperIDTeam: true,
                hasEmbeddedHelperPlist: true
            ),
            .xpcHelper
        )
        XCTAssertEqual(
            DualTrackPrivilegeEscalator.selectTrack(
                macOS13OrNewer: true,
                hasDeveloperIDTeam: true,
                hasEmbeddedHelperPlist: false
            ),
            .appleScriptGUI
        )
        XCTAssertEqual(
            DualTrackPrivilegeEscalator.selectTrack(
                macOS13OrNewer: true,
                hasDeveloperIDTeam: false,
                hasEmbeddedHelperPlist: true
            ),
            .appleScriptGUI
        )
        XCTAssertEqual(
            DualTrackPrivilegeEscalator.selectTrack(
                macOS13OrNewer: false,
                hasDeveloperIDTeam: true,
                hasEmbeddedHelperPlist: true
            ),
            .appleScriptGUI
        )

        XCTAssertTrue(
            DualTrackPrivilegeEscalator.hasDeveloperIDIdentity(
                teamIdentifier: "ABCDE12345",
                leafCommonName: "Developer ID Application: Example Corp (ABCDE12345)"
            )
        )
        XCTAssertFalse(
            DualTrackPrivilegeEscalator.hasDeveloperIDIdentity(
                teamIdentifier: "ABCDE12345",
                leafCommonName: "Apple Development: Test User"
            )
        )
        XCTAssertEqual(DualTrackPrivilegeEscalator.shellSingleQuoted("a'b"), "'a'\"'\"'b'")

        let script = DualTrackPrivilegeEscalator.buildAppleScriptPrivilegeCommand(
            binary: "/usr/sbin/nvram",
            arguments: ["boot-args=amfi_get_out_of_my_way=1"]
        )
        XCTAssertTrue(script.contains("with administrator privileges"))
        _ = DualTrackPrivilegeEscalator.preFlightStatus()
    }

    func testHelperSecurityValidatorContainerAndBundleChecks() {
        XCTAssertTrue(HelperSecurityValidator.validateBundleIdentifier("io.playcover.PlayCover"))
        XCTAssertFalse(HelperSecurityValidator.validateBundleIdentifier("../bad"))
        XCTAssertFalse(HelperSecurityValidator.validateBundleIdentifier(""))

        let containersRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .standardizedFileURL
        let validContainer = containersRoot
            .appendingPathComponent("com.example.game/Data/Library", isDirectory: true)
            .path

        XCTAssertNotNil(HelperSecurityValidator.validateContainerPath(validContainer))
        XCTAssertNil(HelperSecurityValidator.validateContainerPath(containersRoot.path + "/../Documents"))
        XCTAssertNil(HelperSecurityValidator.validateContainerPath("/etc/passwd"))

        XCTAssertTrue(HelperSecurityValidator.isValidTeamIdentifier("ABCDE12345"))
        XCTAssertFalse(HelperSecurityValidator.isValidTeamIdentifier("invalid-team!"))
        XCTAssertNil(HelperSecurityValidator.clientCodeSigningRequirement(teamID: nil))
        XCTAssertNotNil(HelperSecurityValidator.clientCodeSigningRequirement(teamID: "ABCDE12345"))
    }
}
