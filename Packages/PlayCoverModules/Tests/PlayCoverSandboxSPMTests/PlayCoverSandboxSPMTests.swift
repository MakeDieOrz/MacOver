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
            from: [
                "com.apple.security.application-groups": [
                    "group.com.example.one",
                    "../bad",
                    "app.makedie.MacOver",
                    ".GlobalPreferences",
                    "group.com.apple.notes"
                ]
            ]
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
            specificEntitlements: [
                "com.apple.developer.game-center": true,
                "com.apple.security.app-sandbox": false,
                "com.apple.private.security.no-sandbox": true,
                "com.example.custom": true
            ],
            declaredGroups: appGroups,
            temporaryDirectoryPath: "/var/folders/tmp"
        )

        #expect(composed["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(composed["com.apple.developer.game-center"] as? Bool == true)
        #expect(composed["com.apple.private.security.no-sandbox"] == nil)
        #expect(composed["com.example.custom"] == nil)
        let sbpl = (composed["com.apple.security.temporary-exception.sbpl"] as? [String]) ?? []
        let joined = sbpl.joined(separator: "\n")
        #expect(joined.contains("(allow file-read* (literal \"/tmp/allowed\"))"))
        #expect(joined.contains("AppGroups/com.example.sandbox/group.com.example.one"))
        #expect(joined.contains("app.makedie.MacOver.AppGroups.com.example.sandbox.group.com.example.one"))
        #expect(!joined.contains("Group Containers/"))
        #expect(!joined.contains("../bad"))
        #expect(!joined.contains("(preference-domain \"app.makedie.MacOver\")"))
        #expect(!joined.contains("(preference-domain \".GlobalPreferences\")"))
        #expect(!joined.contains("group.com.apple.notes"))
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
        #expect(crComposed["com.apple.security.app-sandbox"] as? Bool == true)
    }

    @Test
    func systemConfigAMFICheckRunsInProcessWithoutSubprocess() {
        _ = SystemConfig.isRunningAMFIEnabled()
    }

    @Test
    func helperSecurityValidatorRejectsSymlinksCrossUserAndRepairsDescriptorPinned() throws {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard home.hasPrefix("/Users/") else { return }

        let testBundleID = "com.example.macover-sec-\(UUID().uuidString.lowercased())"
        let containersRoot = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
        try fm.createDirectory(at: containersRoot, withIntermediateDirectories: true)
        let containerURL = containersRoot.appendingPathComponent(testBundleID, isDirectory: true)
        let dataURL = containerURL.appendingPathComponent("Data", isDirectory: true)
        try fm.createDirectory(at: dataURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: containerURL) }

        let outsideDir = fm.temporaryDirectory.appendingPathComponent("helper-sec-out-\(UUID().uuidString)")
        try fm.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outsideDir) }
        let outsideSentinel = outsideDir.appendingPathComponent("sentinel.txt")
        try Data("do-not-touch".utf8).write(to: outsideSentinel)
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: outsideSentinel.path)

        let insideFile = dataURL.appendingPathComponent("readonly.txt")
        try Data("repair-me".utf8).write(to: insideFile)
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: insideFile.path)

        let symlinkToOutside = dataURL.appendingPathComponent("escape-link")
        try fm.createSymbolicLink(at: symlinkToOutside, withDestinationURL: outsideSentinel)
        let symlinkDirToOutside = dataURL.appendingPathComponent("escape-dir")
        try fm.createSymbolicLink(at: symlinkDirToOutside, withDestinationURL: outsideDir)

        // Cross-user path must be rejected when userHomeRoot is pinned
        #expect(HelperSecurityValidator.validateContainerPath(
            containerURL.path,
            userHomeRoot: "/Users/differentuser",
            requireExisting: true
        ) == nil)

        // Path containing a symlink component must be rejected
        #expect(HelperSecurityValidator.validateContainerPath(
            symlinkDirToOutside.path,
            userHomeRoot: home,
            requireExisting: true
        ) == nil)

        // Descriptor-pinned repair restores owner rw on inside files while leaving symlink targets untouched
        try HelperSecurityValidator.repairContainerPermissionsSecurely(
            at: containerURL.path,
            userHomeRoot: home
        )
        let repairedMode = (try fm.attributesOfItem(atPath: insideFile.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(repairedMode == 0o600)
        let outsideMode = (try fm.attributesOfItem(
            atPath: outsideSentinel.path
        )[.posixPermissions] as? NSNumber)?.intValue
        #expect(outsideMode == 0o400)
    }

    @Test
    func entitlementsComposerProtectsSecretsAndScopesRuntimeAllowsPostDeny() throws {
        var settings = AppSettingsData()
        settings.bundleIdentifier = "com.example.secretscope"
        let composed = EntitlementsComposer.compose(
            bundleID: "com.example.secretscope",
            bundleURL: URL(fileURLWithPath: "/Applications/SecretScope.app"),
            settings: settings,
            rules: PlayRules(),
            isPlaySignActive: true
        )
        let sbpl = ((composed["com.apple.security.temporary-exception.sbpl"] as? [String]) ?? [])
            .joined(separator: "\n")

        // Critical secrets must be denied
        #expect(sbpl.contains("Library/Containers/app.makedie.MacOver/KeyCover"))
        #expect(sbpl.contains("Library/Containers/app.makedie.MacOver/Certificates"))
        #expect(sbpl.contains("Library/Containers/app.makedie.MacOver/PlayChain"))
        #expect(sbpl.contains("Library/Containers/app.makedie.MacOver/PlayTools/UserPlugins"))

        // Scoped runtime allows must appear AFTER the critical deny rules (SBPL last-match-wins)
        let certDenyRange = try #require(sbpl.range(of: "app.makedie.MacOver/Certificates\""))
        let runtimeCertAllowRange = try #require(
            sbpl.range(of: "app.makedie.MacOver/Certificates/com.example.secretscope/runtime.certs\"")
        )
        #expect(runtimeCertAllowRange.lowerBound > certDenyRange.upperBound)

        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let playChainLiteral = "(literal \"\(homePath)/Library/Containers/app.makedie.MacOver/" +
            "PlayChain/com.example.secretscope.db\")"
        let playChainDenyRange = try #require(sbpl.range(of: "app.makedie.MacOver/PlayChain\""))
        let playChainAllowRange = try #require(sbpl.range(of: playChainLiteral))
        #expect(playChainAllowRange.lowerBound > playChainDenyRange.upperBound)
        #expect(!sbpl.contains("(prefix \""))
        #expect(sbpl.contains("com.example.secretscope.db-wal\""))
        #expect(sbpl.contains("com.example.secretscope.db-shm\""))
        #expect(sbpl.contains("com.example.secretscope.db-journal\""))
        #expect(sbpl.contains("Library/Containers/app.makedie.MacOver/Data"))
    }

    @Test
    func entitlementsComposerStripsDangerousTCCAndBlocksReservedBundleID() {
        #expect(!EntitlementsComposer.tccServices.contains("kTCCServiceAll"))
        #expect(!EntitlementsComposer.tccServices.contains("kTCCServiceSystemPolicyAllFiles"))
        #expect(!EntitlementsComposer.tccServices.contains("kTCCServiceAccessibility"))
        #expect(!EntitlementsComposer.tccServices.contains("kTCCServicePostEvent"))
        #expect(!EntitlementsComposer.tccServices.contains("kTCCServiceAppleEvents"))

        var spoofSettings = AppSettingsData()
        spoofSettings.bundleIdentifier = "app.makedie.MacOver"
        let rules = PlayRules(
            allow: ["(allow file* (subpath \"${HomeDirectory}/Library/Containers/${BundleID}\"))"]
        )
        let composed = EntitlementsComposer.compose(
            bundleID: "app.makedie.MacOver",
            bundleURL: URL(fileURLWithPath: "/Applications/Spoof.app"),
            settings: spoofSettings,
            rules: rules,
            isPlaySignActive: true,
            declaredGroups: ["group.com.example.test"]
        )
        #expect(composed["com.apple.security.app-sandbox"] as? Bool == true)
        let sbpl = ((composed["com.apple.security.temporary-exception.sbpl"] as? [String]) ?? [])
            .joined(separator: "\n")
        #expect(!sbpl.contains("(allow file* (subpath"))
        #expect(!sbpl.contains("runtime.certs"))
        #expect(!sbpl.contains("AppGroups/app.makedie.MacOver"))
    }

    @Test
    func helperSecurityValidatorRejectsHardlinksReservedIDsAndUnmanagedContainers() throws {
        #expect(HelperSecurityValidator.isReservedBundleIdentifier("com.apple.Safari"))
        #expect(HelperSecurityValidator.isReservedBundleIdentifier("app.makedie.MacOver"))
        #expect(HelperSecurityValidator.isReservedBundleIdentifier("io.playcover.PlayCover"))
        #expect(!HelperSecurityValidator.isReservedBundleIdentifier("com.example.game"))
        #expect(!HelperSecurityValidator.validateGuestBundleIdentifier("com.apple.Terminal"))
        #expect(HelperSecurityValidator.validateGuestBundleIdentifier("com.example.game"))

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard home.hasPrefix("/Users/") else { return }

        let containersRoot = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
        #expect(HelperSecurityValidator.validateContainerPath(
            containersRoot.appendingPathComponent("com.apple.Safari").path,
            userHomeRoot: home
        ) == nil)
        #expect(HelperSecurityValidator.validateContainerPath(
            containersRoot.appendingPathComponent("app.makedie.MacOver").path,
            userHomeRoot: home
        ) == nil)

        // Managed apps directory check
        let tempAppsDir = fm.temporaryDirectory.appendingPathComponent("managed-apps-\(UUID().uuidString)")
        try fm.createDirectory(at: tempAppsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempAppsDir) }

        let managedBundleID = "com.example.managed-\(UUID().uuidString.lowercased())"
        let managedAppURL = tempAppsDir.appendingPathComponent("\(managedBundleID).app", isDirectory: true)
        try fm.createDirectory(at: managedAppURL, withIntermediateDirectories: true)
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": managedBundleID],
            format: .xml,
            options: 0
        )
        try plistData.write(to: managedAppURL.appendingPathComponent("Info.plist"))

        #expect(HelperSecurityValidator.isManagedAppBundleID(managedBundleID, in: tempAppsDir))
        #expect(!HelperSecurityValidator.isManagedAppBundleID("com.example.unmanaged", in: tempAppsDir))
        #expect(HelperSecurityValidator.validateContainerPath(
            containersRoot.appendingPathComponent("com.example.unmanaged").path,
            userHomeRoot: home,
            managedAppsDirectory: tempAppsDir
        ) == nil)
        #expect(HelperSecurityValidator.validateContainerPath(
            containersRoot.appendingPathComponent(managedBundleID).path,
            userHomeRoot: home,
            managedAppsDirectory: tempAppsDir
        ) != nil)

        // Hardlink rejection in repairContainerPermissionsSecurely
        try fm.createDirectory(at: containersRoot, withIntermediateDirectories: true)
        let containerURL = containersRoot.appendingPathComponent(managedBundleID, isDirectory: true)
        let dataURL = containerURL.appendingPathComponent("Data", isDirectory: true)
        try fm.createDirectory(at: dataURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: containerURL) }

        let outsideFile = tempAppsDir.appendingPathComponent("hardlink-target.txt")
        try Data("protected".utf8).write(to: outsideFile)
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: outsideFile.path)

        let hardlinkInside = dataURL.appendingPathComponent("hardlink.txt")
        try fm.linkItem(at: outsideFile, to: hardlinkInside)

        #expect(throws: Error.self) {
            try HelperSecurityValidator.repairContainerPermissionsSecurely(
                at: containerURL.path,
                userHomeRoot: home,
                managedAppsDirectory: tempAppsDir
            )
        }
        let targetMode = (try fm.attributesOfItem(atPath: outsideFile.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(targetMode == 0o400)
    }

    @Test
    func dualTrackPrivilegeEscalatorStrictSIPParsingAndNVRAMMerge() {
        #expect(!DualTrackPrivilegeEscalator.parseSIPDisabled(
            from: "System Integrity Protection status: enabled."
        ))
        let partialCustomSIP = """
        System Integrity Protection status: unknown (Custom Configuration).

        Configuration:
        \tDebugging Restrictions: disabled
        \tFilesystem Protections: enabled
        """
        #expect(!DualTrackPrivilegeEscalator.parseSIPDisabled(from: partialCustomSIP))
        #expect(DualTrackPrivilegeEscalator.parseSIPDisabled(
            from: "System Integrity Protection status: disabled."
        ))
        let bothDisabledCustomSIP = """
        System Integrity Protection status: unknown (Custom Configuration).
        \tFilesystem Protections: disabled
        \tDebugging Restrictions: disabled
        """
        #expect(DualTrackPrivilegeEscalator.parseSIPDisabled(from: bothDisabledCustomSIP))
        #expect(DualTrackPrivilegeEscalator.parseNVRAMWritable(
            from: "System Integrity Protection status: unknown (Custom Configuration).\n\tNVRAM Protections: disabled\n"
        ))
        #expect(!DualTrackPrivilegeEscalator.parseNVRAMWritable(
            from: "System Integrity Protection status: enabled.\n\tNVRAM Protections: enabled\n"
        ))

        #expect(DualTrackPrivilegeEscalator.hasAMFIBootArg(in: "kern.bootargs: keepsyms=1 amfi_get_out_of_my_way=1"))
        #expect(DualTrackPrivilegeEscalator.hasAMFIBootArg(in: "boot-args\tamfi_get_out_of_my_way=0x1"))
        #expect(!DualTrackPrivilegeEscalator.hasAMFIBootArg(in: "kern.bootargs: amfi_get_out_of_my_way=10"))

        let merged = DualTrackPrivilegeEscalator.mergedAMFIBootArgs(existingOutput: "boot-args\tkeepsyms=1 -v")
        #expect(merged == "keepsyms=1 -v amfi_get_out_of_my_way=0x1 ipc_control_port_options=0")

        let mergedAlready = DualTrackPrivilegeEscalator.mergedAMFIBootArgs(
            existingOutput: "boot-args\t-v amfi_get_out_of_my_way=1"
        )
        #expect(mergedAlready == "-v amfi_get_out_of_my_way=1 ipc_control_port_options=0")
    }

    @Test
    func entitlementsComposerKeymappingSymlinkDenyAndKeychainGroupHardening() throws {
        var settings = AppSettingsData()
        settings.bypass = true
        let rules = PlayRules(
            allow: [
                "(allow file* file-read* file-write* (subpath " +
                "\"${HomeDirectory}/Library/Containers/app.makedie.MacOver/Keymapping/${BundleID}\"))"
            ]
        )

        let bundleURL = URL(fileURLWithPath: "/tmp/com.example.game.app")

        // Non-[String] keychain-access-groups must be dropped without falling through
        let nonArrayComposed = EntitlementsComposer.compose(
            bundleID: "com.example.game",
            bundleURL: bundleURL,
            settings: settings,
            rules: rules,
            isPlaySignActive: true,
            specificEntitlements: ["keychain-access-groups": "ABCDE12345.app.makedie.MacOver"]
        )
        #expect(nonArrayComposed["keychain-access-groups"] == nil)

        // TeamID-prefixed reserved groups, wildcards, and macro placeholders must be filtered out
        let filteredComposed = EntitlementsComposer.compose(
            bundleID: "com.example.game",
            bundleURL: bundleURL,
            settings: settings,
            rules: rules,
            isPlaySignActive: true,
            specificEntitlements: [
                "keychain-access-groups": [
                    "*",
                    "ABCDE12345.*",
                    "ABCDE12345.app.makedie.MacOver",
                    "ABCDE12345.io.playcover.PlayCover",
                    "ABCDE12345.com.apple.keychain",
                    "$(AppIdentifierPrefix)app.makedie.MacOver",
                    "ABCDE12345.com.example.game"
                ]
            ]
        )
        #expect(filteredComposed["keychain-access-groups"] as? [String] == ["ABCDE12345.com.example.game"])

        // Keymapping/<BundleID> must get a trailing SBPL symlink-create deny rule (last-match-wins)
        // wrapping multiple firmlink subpath aliases inside (require-any ...).
        let sbpl = try #require(filteredComposed["com.apple.security.temporary-exception.sbpl"] as? [String])
        let allowIdx = try #require(sbpl.firstIndex {
            $0.contains("allow file*") && $0.contains("/Keymapping/com.example.game")
        })
        let symlinkDenyIdx = try #require(sbpl.firstIndex {
            $0.contains("(deny file-write-create (require-all (vnode-type SYMLINK) (require-any ")
                && $0.contains("/Keymapping/com.example.game")
                && $0.contains("/System/Volumes/Data/")
        })
        #expect(symlinkDenyIdx > allowIdx)

        // Live macOS Seatbelt verification via /usr/bin/sandbox-exec:
        // regular file creation + atomic rename succeed while symlink creation fails with EPERM.
        let fm = FileManager.default
        let tempKeymapDir = fm.temporaryDirectory
            .appendingPathComponent("SBPLKeymapVerify-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempKeymapDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempKeymapDir) }
        let realKeymapPath = tempKeymapDir.resolvingSymlinksInPath().standardizedFileURL.path
        let aliases = EntitlementsComposer.expandSandboxDenyAliases(realKeymapPath)
        let subpathFilters = aliases.compactMap {
            EntitlementsComposer.escapeSBPLPath($0).map { "(subpath \"\($0)\")" }
        }
        #expect(subpathFilters.count >= 2)
        let pathFilter = "(require-any \(subpathFilters.joined(separator: " ")))"
        let profile = """
        (version 1)
        (allow default)
        (allow file* file-read* file-write* file-write-data file-read-metadata file-ioctl \(pathFilter))
        (deny file-write-create (require-all (vnode-type SYMLINK) \(pathFilter)))
        """
        let regularTmp = tempKeymapDir.appendingPathComponent("keymap.tmp").path
        let regularFinal = tempKeymapDir.appendingPathComponent("keymap.plist").path
        let symlinkTarget = tempKeymapDir.appendingPathComponent("escape.plist").path

        let regProc = Process()
        regProc.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        regProc.arguments = [
            "-p", profile, "/bin/sh", "-c",
            "printf ok > \"$1\" && mv \"$1\" \"$2\"", "_", regularTmp, regularFinal
        ]
        try regProc.run()
        regProc.waitUntilExit()
        #expect(regProc.terminationStatus == 0)
        #expect(fm.fileExists(atPath: regularFinal))

        let symProc = Process()
        let errPipe = Pipe()
        symProc.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        symProc.arguments = ["-p", profile, "/bin/ln", "-s", "/etc/hosts", symlinkTarget]
        symProc.standardError = errPipe
        try symProc.run()
        symProc.waitUntilExit()
        let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(symProc.terminationStatus != 0)
        #expect(errText.localizedCaseInsensitiveContains("Operation not permitted"))
        var symStat = Darwin.stat()
        #expect(Darwin.lstat(symlinkTarget, &symStat) != 0)
    }
}
