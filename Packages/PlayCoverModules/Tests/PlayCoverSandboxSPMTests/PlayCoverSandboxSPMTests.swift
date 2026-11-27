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

    @Test
    func entitlementsComposerRulesBypassSelfBundleAndDiscordIPC() {
        #expect(EntitlementsComposer.mergeRuleLists(["a", "b"], ["b", "c"]) == ["a", "b", "c"])
        #expect(EntitlementsComposer.escapeSBPLPath("a\nb") == nil)
        #expect(EntitlementsComposer.escapeSBPLPath("/Applications/Test\"App") == "/Applications/Test\\\"App")
        #expect(EntitlementsComposer.escapeSBPLRegex("/var/folders/a+b")?.contains("\\+") == true)

        let aliases = EntitlementsComposer.expandSandboxDenyAliases("/var/db/test")
        #expect(aliases.contains("/var/db/test"))
        #expect(aliases.contains("/private/var/db/test"))

        let discordRules = EntitlementsComposer.discordIPCSBPLRules(temporaryDirectoryPath: "/var/folders/tmp/")
        #expect(discordRules.count == 1)
        #expect(discordRules[0].contains("discord-ipc-[0-9]+"))

        let appGroups = EntitlementsComposer.declaredApplicationGroups(
            from: ["com.apple.security.application-groups": ["group.com.example.one", "../bad"]]
        )
        var settings = AppSettingsData()
        settings.bundleIdentifier = "com.example.sandbox"
        settings.bypass = true
        settings.discordActivity.enable = true

        let rules = PlayRules(
            blocklist: ["/Applications/Self.app", "/Library/BadTool"],
            greenlist: ["/usr/local/green"],
            allow: ["(allow file-read* (literal \"/tmp/allowed\"))"],
            bypass: ["(deny sysctl-read (sysctl-name \"debug.test\"))"]
        )
        let bundleURL = URL(fileURLWithPath: "/Applications/Self.app")
        let composed = EntitlementsComposer.compose(
            bundleID: "com.example.sandbox",
            bundleURL: bundleURL,
            settings: settings,
            rules: rules,
            isPlaySignActive: true,
            specificEntitlements: ["com.example.custom": true],
            declaredGroups: appGroups,
            temporaryDirectoryPath: "/var/folders/tmp"
        )

        #expect(composed["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(composed["com.example.custom"] as? Bool == true)
        let sbpl = (composed["com.apple.security.temporary-exception.sbpl"] as? [String]) ?? []
        let joined = sbpl.joined(separator: "\n")
        #expect(joined.contains("(allow file-read* (literal \"/tmp/allowed\"))"))
        #expect(joined.contains("Group Containers/group.com.example.one"))
        #expect(!joined.contains("Group Containers/../bad"))
        #expect(joined.contains("(deny sysctl-read (sysctl-name \"debug.test\"))"))
        #expect(!joined.contains("    (subpath \"/Applications/Self.app\")"))
        #expect(joined.contains("    (subpath \"/Library/BadTool\")"))
        #expect(joined.contains("file-map-executable process-exec (subpath \"/Applications/Self.app\")"))
    }

    @Test
    func entitlementsComposerNoPlaySignStrictBypassCookieRunAndTargetBundle() {
        var strictSettings = AppSettingsData()
        strictSettings.bundleIdentifier = "com.example.strict"
        strictSettings.bypass = false
        strictSettings.strictEmulationMode = true
        #expect(strictSettings.effectiveBypass)

        let sourceURL = URL(fileURLWithPath: "/Applications/Stage.app")
        let targetURL = URL(fileURLWithPath: "/Applications/Installed.app")
        let noPlaySignRules = PlayRules(
            blocklist: ["/Applications/Installed.app", "/Library/Blocked"],
            bypass: ["(deny sysctl-read (sysctl-name \"kern.strict\"))"]
        )
        let composedStrict = EntitlementsComposer.compose(
            bundleID: "com.example.strict",
            bundleURL: sourceURL,
            targetBundleURL: targetURL,
            settings: strictSettings,
            rules: noPlaySignRules,
            isPlaySignActive: false,
            specificEntitlements: ["com.example.secret": true]
        )
        #expect(composedStrict["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(composedStrict["com.apple.private.tcc.allow"] == nil)
        #expect(composedStrict["com.example.secret"] == nil)
        let strictSBPL = ((composedStrict["com.apple.security.temporary-exception.sbpl"] as? [String]) ?? [])
            .joined(separator: "\n")
        #expect(strictSBPL.contains("(deny process-fork)"))
        #expect(strictSBPL.contains("(deny sysctl-read (sysctl-name \"kern.strict\"))"))
        #expect(!strictSBPL.contains("    (subpath \"/Applications/Installed.app\")"))
        #expect(strictSBPL.contains("    (subpath \"/Library/Blocked\")"))
        #expect(strictSBPL.contains("file-map-executable process-exec (subpath \"/Applications/Installed.app\")"))

        var crSettings = AppSettingsData()
        crSettings.bundleIdentifier = "com.devsisters.ck"
        let crComposed = EntitlementsComposer.compose(
            bundleID: "com.devsisters.ck",
            bundleURL: targetURL,
            settings: crSettings,
            rules: PlayRules(),
            isPlaySignActive: false
        )
        #expect(crComposed["com.apple.security.app-sandbox"] == nil)
    }
}
