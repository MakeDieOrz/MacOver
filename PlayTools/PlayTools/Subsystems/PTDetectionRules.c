//
//  PTDetectionRules.c
//  PlayTools
//
//  Pure-C anti-detection rule matchers, path normalizers, and xattr/network filters.
//

#include "PTDetectionRules.h"
#include "PTSFSymbols13Allowlist.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define PT_HAS_PREFIX_LIT(s, lit) (strncmp((s), (lit), sizeof(lit) - 1) == 0)

__attribute__((visibility("hidden"))) const char *pt_normalize_lexical_path(const char *src, char *dst,
                                                                            size_t dst_size) {
    if (src == NULL || dst == NULL || dst_size < 2 || src[0] != '/') {
        return NULL;
    }
    size_t seg_starts[512];
    size_t seg_depth = 0;
    size_t out = 0;
    dst[out++] = '/';

    const char *p = src + 1;
    while (*p != '\0') {
        while (*p == '/') {
            p++;
        }
        if (*p == '\0') {
            break;
        }
        const char *seg_end = p;
        while (*seg_end != '\0' && *seg_end != '/') {
            seg_end++;
        }
        size_t seg_len = (size_t)(seg_end - p);
        if (seg_len == 1 && p[0] == '.') {
            // Skip "."
        } else if (seg_len == 2 && p[0] == '.' && p[1] == '.') {
            if (seg_depth > 0) {
                out = seg_starts[--seg_depth];
                if (out == 0) {
                    out = 1;
                }
            }
        } else {
            if (out > 1) {
                if (out + 1 >= dst_size) {
                    return NULL;
                }
                dst[out++] = '/';
            }
            if (seg_depth < 512) {
                seg_starts[seg_depth++] = (out > 1) ? (out - 1) : 0;
            }
            if (out + seg_len >= dst_size) {
                return NULL;
            }
            memcpy(dst + out, p, seg_len);
            out += seg_len;
        }
        p = seg_end;
    }
    dst[out] = '\0';
    return dst;
}

__attribute__((visibility("hidden"))) const char *pt_match_prefix_modulo_private(const char *path, const char *base,
                                                                                 size_t base_len) {
    if (path == NULL || base == NULL || base_len == 0) {
        return NULL;
    }
    if (strncasecmp(path, base, base_len) == 0 && (path[base_len] == '/' || path[base_len] == '\0')) {
        return path + base_len;
    }
    if (base_len > 8 && strncasecmp(base, "/private/", 9) == 0) {
        const char *sbase = base + 8;
        size_t slen = base_len - 8;
        if (strncasecmp(path, sbase, slen) == 0 && (path[slen] == '/' || path[slen] == '\0')) {
            return path + slen;
        }
    } else if (strncasecmp(path, "/private/", 9) == 0) {
        const char *spath = path + 8;
        if (strncasecmp(spath, base, base_len) == 0 && (spath[base_len] == '/' || spath[base_len] == '\0')) {
            return spath + base_len;
        }
    }
    return NULL;
}

__attribute__((visibility("hidden"))) bool pt_path_has_component(const char *path, const char *comp) {
    if (path == NULL || comp == NULL || comp[0] == '\0') {
        return false;
    }
    size_t comp_len = strlen(comp);
    const char *cursor = path;
    while ((cursor = strstr(cursor, comp)) != NULL) {
        bool left_ok = (cursor == path || cursor[-1] == '/');
        char right = cursor[comp_len];
        bool right_ok = (right == '\0' || right == '/');
        if (left_ok && right_ok) {
            return true;
        }
        cursor += 1;
    }
    return false;
}

__attribute__((visibility("hidden"))) bool pt_is_macos_only_framework_path_cstr(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return false;
    }
    static const char *const kMacOSOnlyFrameworks[] = {
        "AppKit.framework",
        "_AppIntents_AppKit.framework",
        "_FoundationModels_AppKit.framework",
        "_GroupActivities_AppKit.framework",
        "_PermissionKit_AppKit.framework",
        "JITAppKit.framework",
        "UIKitMacHelper.framework",
        "PreviewsUIKitMacHelper.framework",
        "ViewBridge.framework",
        "FaceTimeNotificationViewBridge.framework",
        "SkyLight.framework",
        "HIToolbox.framework",
        "Carbon.framework",
        "Cocoa.framework",
        "CombineCocoa.framework",
        "ApplicationServices.framework",
        "IOBluetooth.framework",
        "ServiceManagement.framework",
        "WatchdogServiceManagement.framework",
        "ScriptingBridge.framework",
        "DiskArbitration.framework",
        "EndpointSecurity.framework",
        "Hypervisor.framework",
        "Virtualization.framework",
        "CoreWLAN.framework",
        "CoreDisplay.framework",
        "OpenDirectory.framework",
        "DirectoryService.framework",
        "FinderSync.framework",
        "SystemAdministration.framework",
        "Automator.framework",
        "AppleScriptObjC.framework",
        "InputMethodKit.framework",
        "PreferencePanes.framework",
        "ScreenSaver.framework",
        "SecurityInterface.framework",
        "OSAKit.framework",
        "NetFS.framework",
        "ParavirtualizedGraphics.framework",
        "DriverKit.framework",
        "DFRFoundation.framework",
        "LoginUIKit.framework",
        "BezelServices.framework",
        "DisplayServices.framework",
        "AmbientDisplay.framework",
        "AppleSystemInfo.framework",
        "FinderKit.framework",
        "DesktopServicesPriv.framework",
        "PackageKit.framework",
        "Uninstall.framework",
        "MonitorPanel.framework",
        "UniversalAccess.framework",
        "SpeechObjects.framework",
        "FSEvents.framework",
        "AE.framework",
        "CarbonCore.framework",
        "OSServices.framework",
        "Metadata.framework",
        "SearchKit.framework",
        "LaunchServices.framework",
        "DictionaryServices.framework",
        "SharedFileList.framework",
        "CoreMediaIO.framework",
        "IOUSBHost.framework",
        "Quartz.framework",
        "DiscRecording.framework",
        "Collaboration.framework",
        "ForceFeedback.framework",
        "PCSC.framework",
        "ExceptionHandling.framework",
        "ICADevices.framework",
        "IOBluetoothUI.framework",
        "InstallerPlugins.framework",
        "AGL.framework",
        "TWAIN.framework",
        "DVDPlayback.framework",
        "SyncServices.framework",
        "Catalyst.framework",
        "AVKitMacHelper.framework",
        "AuthKitUIMacHelper.framework",
        "ContactsUIMacHelper.framework",
        "MessageUIMacHelper.framework",
        "ReplayKitMacHelper.framework",
        "TextInputUIMacHelper.framework",
        "QuickLookIosmac.framework",
        "QuickLookUIIosmac.framework",
        "MobileActivationMacOS.framework",
        "MenuBarClientCore.framework",
        "WindowManagement.framework",
        "UniversalControl.framework",
        "VideoToolboxParavirtualizationSupport.framework",
        "ScreenCaptureKit.framework",
        "DiskImages.framework",
        "DiskManagement.framework",
        "EFILogin.framework",
        "SystemPolicy.framework",
        "XprotectFramework.framework",
        "login.framework",
        "loginsupport.framework",
        "DSExternalDisplay.framework",
        "ProDisplayLibrary.framework",
        "HIDDisplay.framework",
        "MachineSettings.framework",
        "DebugSymbols.framework",
        "CommerceKit.framework",
        "CommerceCore.framework",
        "OpenGL.framework",
        "OpenCL.framework",
        "GLUT.framework",
        "Kerberos.framework",
        "LDAP.framework",
        "AppleLDAP.framework",
        "QuickLookUI.framework",
        "QuickLookNonBaseSystem.framework",
        "PreferencePanesSupport.framework",
        "SecurityFoundation.framework",
        "NetAuth.framework",
        "IO80211.framework",
        "AppleVA.framework",
        "libUniversalAccess.dylib",
        "libRosetta.dylib",
        "liboah.dylib",
        "libSMC.dylib",
        "libEndpointSecuritySystem.dylib",
        "libCoreStorage.dylib",
    };
    const size_t n = sizeof(kMacOSOnlyFrameworks) / sizeof(kMacOSOnlyFrameworks[0]);
    for (size_t i = 0; i < n; i++) {
        if (pt_path_has_component(name, kMacOSOnlyFrameworks[i])) {
            return true;
        }
    }
    return false;
}

__attribute__((visibility("hidden"))) bool pt_is_hidden_macos_only_dlsym_symbol_cstr(const char *symbol) {
    if (symbol == NULL || symbol[0] == '\0') {
        return false;
    }
    if (PT_HAS_PREFIX_LIT(symbol, "SecCode") || PT_HAS_PREFIX_LIT(symbol, "SecStaticCode") ||
        PT_HAS_PREFIX_LIT(symbol, "SecRequirementCreate") || PT_HAS_PREFIX_LIT(symbol, "SecKeychain") ||
        PT_HAS_PREFIX_LIT(symbol, "SecACL") || PT_HAS_PREFIX_LIT(symbol, "SecAccess") ||
        PT_HAS_PREFIX_LIT(symbol, "SecTrustedApplication") || PT_HAS_PREFIX_LIT(symbol, "Authorization") ||
        strcmp(symbol, "MTLCopyAllDevices") == 0 || PT_HAS_PREFIX_LIT(symbol, "MTLCopyAllDevices") ||
        strcmp(symbol, "CTFontManagerCopyAvailableFontURLs") == 0 || PT_HAS_PREFIX_LIT(symbol, "AudioObject") ||
        PT_HAS_PREFIX_LIT(symbol, "AudioHardware") || strcmp(symbol, "AudioDeviceCreateIOProcID") == 0 ||
        strcmp(symbol, "AudioDeviceDestroyIOProcID") == 0 || strcmp(symbol, "AudioDeviceStart") == 0 ||
        strcmp(symbol, "AudioDeviceStop") == 0 || PT_HAS_PREFIX_LIT(symbol, "AudioDeviceGetProperty") ||
        strcmp(symbol, "AudioDeviceSetProperty") == 0 || PT_HAS_PREFIX_LIT(symbol, "SCDynamicStore") ||
        PT_HAS_PREFIX_LIT(symbol, "SCPreferences") || PT_HAS_PREFIX_LIT(symbol, "SCNetworkSet") ||
        PT_HAS_PREFIX_LIT(symbol, "SCNetworkService") || PT_HAS_PREFIX_LIT(symbol, "SCBondInterface") ||
        PT_HAS_PREFIX_LIT(symbol, "SCVLANInterface") || strcmp(symbol, "SCNetworkInterfaceCopyAll") == 0 ||
        PT_HAS_PREFIX_LIT(symbol, "CVDisplayLink") || PT_HAS_PREFIX_LIT(symbol, "FSEventStream") ||
        PT_HAS_PREFIX_LIT(symbol, "LSOpen") || PT_HAS_PREFIX_LIT(symbol, "LSCopyApplicationURLs") ||
        PT_HAS_PREFIX_LIT(symbol, "LSFindApplication") || strcmp(symbol, "AECreateDesc") == 0 ||
        strcmp(symbol, "AESendMessage") == 0 || PT_HAS_PREFIX_LIT(symbol, "MDQuery") ||
        strcmp(symbol, "csr_check") == 0 || strcmp(symbol, "csr_get_active_config") == 0 ||
        strcmp(symbol, "csrctl") == 0 || PT_HAS_PREFIX_LIT(symbol, "IOBluetooth") ||
        strcmp(symbol, "_LSCopyApplicationInformation") == 0 || strcmp(symbol, "_LSGetCurrentApplicationASN") == 0 ||
        PT_HAS_PREFIX_LIT(symbol, "_LSASN") || PT_HAS_PREFIX_LIT(symbol, "_LSCopyApplicationInformation") ||
        PT_HAS_PREFIX_LIT(symbol, "IOHIDManager") || PT_HAS_PREFIX_LIT(symbol, "IOHIDDevice") ||
        strcmp(symbol, "NSAddImage") == 0 || strcmp(symbol, "NSAddLibrary") == 0 ||
        strcmp(symbol, "NSAddLibraryWithSearching") == 0 || strcmp(symbol, "NSCreateObjectFileImageFromFile") == 0 ||
        strcmp(symbol, "NSCreateObjectFileImageFromMemory") == 0 || strcmp(symbol, "NSDestroyObjectFileImage") == 0 ||
        strcmp(symbol, "NSIsSymbolDefinedInObjectFileImage") == 0 ||
        strcmp(symbol, "NSGetSectionDataInObjectFileImage") == 0 || strcmp(symbol, "NSNameOfModule") == 0 ||
        strcmp(symbol, "NSLibraryNameForModule") == 0 || strcmp(symbol, "NSLinkModule") == 0 ||
        strcmp(symbol, "NSUnLinkModule") == 0 || PT_HAS_PREFIX_LIT(symbol, "NSIsSymbolNameDefined") ||
        PT_HAS_PREFIX_LIT(symbol, "NSLookupAndBindSymbol") || strcmp(symbol, "NSLookupSymbolInModule") == 0 ||
        strcmp(symbol, "NSLookupSymbolInImage") == 0 || strcmp(symbol, "NSAddressOfSymbol") == 0 ||
        strcmp(symbol, "NSModuleForSymbol") == 0 || strcmp(symbol, "NSLinkEditError") == 0 ||
        strcmp(symbol, "_dyld_present") == 0 || strcmp(symbol, "_dyld_bind_fully_image_containing_address") == 0 ||
        strcmp(symbol, "_dyld_image_containing_address") == 0 || PT_HAS_PREFIX_LIT(symbol, "_dyld_lookup_and_bind") ||
        strcmp(symbol, "_dyld_get_image_header_containing_address") == 0 ||
        strcmp(symbol, "_dyld_process_info_for_each_aot_image") == 0 ||
        strcmp(symbol, "_dyld_process_info_get_aot_cache") == 0 ||
        strcmp(symbol, "dyld_shared_cache_for_each_subcache4Rosetta") == 0 ||
        strcmp(symbol, "dyld_shared_subcache_get_info4Rosetta") == 0) {
        return true;
    }
    if (symbol[0] == 'C' && symbol[1] == 'G') {
        if (strcmp(symbol, "CGMainDisplayID") == 0 || strcmp(symbol, "CGGetActiveDisplayList") == 0 ||
            strcmp(symbol, "CGGetOnlineDisplayList") == 0 || PT_HAS_PREFIX_LIT(symbol, "CGGetDisplaysWith") ||
            PT_HAS_PREFIX_LIT(symbol, "CGDisplay") || PT_HAS_PREFIX_LIT(symbol, "CGWindowList") ||
            PT_HAS_PREFIX_LIT(symbol, "CGEventCreate") || PT_HAS_PREFIX_LIT(symbol, "CGEventPost") ||
            PT_HAS_PREFIX_LIT(symbol, "CGEventSource") || PT_HAS_PREFIX_LIT(symbol, "CGEventTap") ||
            strcmp(symbol, "CGPreflightScreenCaptureAccess") == 0 ||
            strcmp(symbol, "CGRequestScreenCaptureAccess") == 0 ||
            strcmp(symbol, "CGPreflightListenEventAccess") == 0 || strcmp(symbol, "CGRequestListenEventAccess") == 0 ||
            strcmp(symbol, "CGPreflightPostEventAccess") == 0 || strcmp(symbol, "CGRequestPostEventAccess") == 0 ||
            strcmp(symbol, "CGWarpMouseCursorPosition") == 0 ||
            strcmp(symbol, "CGAssociateMouseAndMouseCursorPosition") == 0 || strcmp(symbol, "CGCursorIsVisible") == 0 ||
            strcmp(symbol, "CGSessionCopyCurrentDictionary") == 0) {
            return true;
        }
    }
    return false;
}

__attribute__((visibility("hidden"))) bool pt_is_desktop_supplemental_gid_c(gid_t g) {
    switch (g) {
    case 12:  // everyone
    case 29:  // certusers
    case 33:  // _appstore
    case 61:  // localaccounts
    case 79:  // _appserverusr
    case 80:  // admin
    case 81:  // _appserveradm
    case 98:  // _lpadmin
    case 100: // _lpoperator
    case 101: // _developer
    case 204: // _developer
    case 250: // _analyticsusers
    case 395: // com.apple.access_ftp
    case 398: // com.apple.access_screensharing
    case 399: // com.apple.access_ssh
    case 400: // com.apple.access_remote_ae
    case 701: // com.apple.sharepoint.group
        return true;
    default:
        return (g >= 390U && g <= 410U);
    }
}

__attribute__((visibility("hidden"))) bool pt_is_hidden_thread_name_cstr(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return false;
    }
    if (strcmp(name, "com.apple.NSEventThread") == 0 || strncmp(name, "NIO-", 4) == 0 ||
        strcasestr(name, "NSEventThread") != NULL || strcasestr(name, "PlayTools") != NULL ||
        strcasestr(name, "PlayCover") != NULL || strcasestr(name, "MacOver") != NULL ||
        strcasestr(name, "PlayChain") != NULL || strcasestr(name, "PlaySettings") != NULL ||
        strcasestr(name, "PlayShadow") != NULL || strcasestr(name, "PTMediaVolume") != NULL) {
        return true;
    }
    return false;
}

__attribute__((visibility("hidden"))) bool pt_is_hidden_env_key_cstr(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return false;
    }
    if (strncmp(name, "XPC_", 4) == 0 || strncmp(name, "DYLD_", 5) == 0 || strncmp(name, "__XPC_DYLD_", 11) == 0 ||
        strncmp(name, "SIMULATOR_", 10) == 0 || strncmp(name, "METAL_", 6) == 0 || strncmp(name, "MTL_", 4) == 0 ||
        strncmp(name, "HOMEBREW_", 9) == 0 || strcasestr(name, "playcover") != NULL ||
        strcasestr(name, "macover") != NULL || strcasestr(name, "playtools") != NULL) {
        return true;
    }
    static const char *const kHiddenKeys[] = {"MallocStackLogging",
                                              "MallocStackLoggingNoCompact",
                                              "MallocNanoZone",
                                              "NSZombieEnabled",
                                              "CLASSIC",
                                              "OSSignpostLogging",
                                              "OS_ACTIVITY_DT_MODE",
                                              "OS_ACTIVITY_MODE",
                                              "OBJC_DISABLE_INITIALIZE_FORK_SAFETY",
                                              "MTLCaptureEnabled",
                                              "__CFBundleIdentifier",
                                              "__CF_USER_TEXT_ENCODING",
                                              "DARWIN_USER_TEMP_DIR",
                                              "DARWIN_USER_CACHE_DIR",
                                              "DARWIN_USER_DIR",
                                              "SQLITE_EXEMPT_PATH_FROM_VNODE_GUARDS",
                                              "TERM",
                                              "TERM_PROGRAM",
                                              "TERM_PROGRAM_VERSION",
                                              "TERM_SESSION_ID",
                                              "Apple_PubSub_Socket_Render",
                                              "DISPLAY",
                                              "SHELL",
                                              "SSH_AUTH_SOCK",
                                              "SECURITYSESSIONID",
                                              "LaunchInstanceID",
                                              "COMMAND_MODE",
                                              "USE_EXTRA_ANTIJB",
                                              "USER",
                                              "LOGNAME",
                                              "OLDPWD",
                                              "SHLVL",
                                              "_",
                                              "APP_SANDBOX_CONTAINER_ID",
                                              "DISABLE_PLAYSHADOW_BYPASS"};
    size_t count = sizeof(kHiddenKeys) / sizeof(kHiddenKeys[0]);
    for (size_t i = 0; i < count; i++) {
        if (strcmp(name, kHiddenKeys[i]) == 0) {
            return true;
        }
    }
    return false;
}

__attribute__((visibility("hidden"))) bool pt_is_hidden_bundle_id_rule_cstr(const char *bid, bool compat13_7) {
    if (bid == NULL || bid[0] == '\0') {
        return false;
    }
    if (strcasestr(bid, "PlayTools") != NULL || strcasestr(bid, "PlayCover") != NULL ||
        strcasestr(bid, "MacOver") != NULL || strcasestr(bid, "app.makedie") != NULL ||
        strcasestr(bid, "AKInterface") != NULL) {
        return true;
    }
    static const char *const kMacOSHiddenBundleIDs[] = {
        "com.apple.AppKit",
        "com.apple.UIKitMacHelper",
        "com.apple.ViewBridge",
        "com.apple.SkyLight",
        "com.apple.HIToolbox",
        "com.apple.Carbon",
        "com.apple.Cocoa",
        "com.apple.ApplicationServices",
        "com.apple.ServiceManagement",
        "com.apple.ScriptingBridge",
        "com.apple.DiskArbitration",
        "com.apple.Hypervisor",
        "com.apple.Virtualization",
        "com.apple.CoreWLAN",
        "com.apple.OpenDirectory",
        "com.apple.DirectoryService",
        "com.apple.FinderSync",
        "com.apple.SystemAdministration",
        "com.apple.Automator",
        "com.apple.AppleScriptObjC",
        "com.apple.InputMethodKit",
        "com.apple.PreferencePanes",
        "com.apple.ScreenSaver",
        "com.apple.SecurityInterface",
        "com.apple.OSAKit",
        "com.apple.NetFS",
        "com.apple.ParavirtualizedGraphics",
        "com.apple.DriverKit",
        "com.apple.CoreServices.CarbonCore",
        "com.apple.AE",
        "com.apple.LaunchServices",
        "com.apple.FSEvents",
        "com.apple.OSServices",
        "com.apple.Metadata",
        "com.apple.SearchKit",
        "com.apple.DictionaryServices",
        "com.apple.SharedFileList",
        "com.apple.CoreMediaIO",
        "com.apple.IOUSBHost",
        "com.apple.DiscRecording",
        "com.apple.IOBluetooth",
        "com.apple.IOBluetoothUI",
        "com.apple.AGL",
        "com.apple.Quartz",
        "com.apple.DesktopServicesPriv",
        "com.apple.FinderKit",
        "com.apple.LoginUIKit",
        "com.apple.DFRFoundation",
        "com.apple.BezelServices",
        "com.apple.DisplayServices",
        "com.apple.AmbientDisplay",
        "com.apple.AppleSystemInfo",
        "com.apple.PackageKit",
        "com.apple.CoreDisplay",
        "com.apple.EndpointSecurity",
        "com.apple.opengl",
        "com.apple.opencl",
        "com.apple.Kerberos",
        "com.apple.LDAP",
        "com.apple.QuickLookUIFramework",
        "com.apple.PreferencePanesSupport",
        "com.apple.securityfoundation",
        "com.apple.NetAuth",
        "com.apple.IO80211",
    };
    for (size_t i = 0; i < sizeof(kMacOSHiddenBundleIDs) / sizeof(kMacOSHiddenBundleIDs[0]); i++) {
        if (strcmp(bid, kMacOSHiddenBundleIDs[i]) == 0) {
            return true;
        }
    }
    if (compat13_7) {
        static const char *const kPost137BundleIDs[] = {
            "com.apple.AppTrackingTransparency",
            "com.apple.WidgetKit",
            "com.apple.AppClip",
            "com.apple.UniformTypeIdentifiers",
            "com.apple.ScreenTime",
            "com.apple.SensorKit",
            "com.apple.NearbyInteraction",
            "com.apple.MLCompute",
            "com.apple.ExtensionKit",
            "com.apple.ExtensionFoundation",
            "com.apple.AppIntents",
            "com.apple.OSLog",
            "com.apple.WorkoutKit",
            "com.apple.FamilyControls",
            "com.apple.ManagedSettings",
            "com.apple.DeviceActivity",
            "com.apple.CoreTransferable",
            "com.apple.Spatial",
            "com.apple.LockedCameraCapture",
            "com.apple.MarketplaceKit",
            "com.apple.GroupActivities",
            "com.apple.ShazamKit",
            "com.apple.MusicKit",
            "com.apple.WeatherKit",
            "com.apple.Charts",
            "com.apple.ActivityKit",
            "com.apple.LiveCommunicationKit",
            "com.apple.TipKit",
            "com.apple.SwiftData",
            "com.apple.Observation",
            "com.apple.Translation",
            "com.apple.JournalingSuggestions",
            "com.apple.BrowserEngineKit",
            "com.apple.DeviceDiscoveryExtension",
            "com.apple.RoomPlan",
            "com.apple.BackgroundAssets",
            "com.apple.ThreadNetwork",
            "com.apple.Matter",
            "com.apple.DockKit",
            "com.apple.Cinematic",
            "com.apple.SensitiveContentAnalysis",
            "com.apple.Symbols",
            "com.apple.AccessorySetupKit",
            "com.apple.WritingTools",
            "com.apple.FinanceKit",
        };
        for (size_t i = 0; i < sizeof(kPost137BundleIDs) / sizeof(kPost137BundleIDs[0]); i++) {
            if (strcmp(bid, kPost137BundleIDs[i]) == 0) {
                return true;
            }
        }
    }
    return false;
}

__attribute__((visibility("hidden"))) bool pt_is_hidden_macos_pref_key_cstr(const char *key) {
    if (key == NULL || key[0] == '\0') {
        return false;
    }
    if (strncmp(key, "NSWindow Frame", 14) == 0 || strncmp(key, "NSToolbar Configuration", 23) == 0 ||
        strncmp(key, "NSNav", 5) == 0 || strncmp(key, "NSStatusItem", 12) == 0 ||
        strncmp(key, "NSTableView", 11) == 0 || strncmp(key, "NSSplitView", 11) == 0 ||
        strncmp(key, "NSSpellChecker", 14) == 0 || strncmp(key, "NSGlass", 7) == 0 ||
        strncmp(key, "com.apple.trackpad.", 19) == 0 || strncmp(key, "com.apple.mouse.", 16) == 0 ||
        strncmp(key, "com.apple.springing.", 20) == 0 || strncmp(key, "com.apple.sound.beep.", 21) == 0 ||
        strncmp(key, "com.apple.finder.", 17) == 0 || strcasestr(key, "PlayCover") != NULL ||
        strcasestr(key, "PlayTools") != NULL || strcasestr(key, "MacOver") != NULL ||
        strcasestr(key, "AKInterface") != NULL) {
        return true;
    }
    static const char *const kHiddenPrefKeys[] = {
        "NSQuitAlwaysKeepsWindows",
        "AppleActionOnDoubleClick",
        "AppleMiniaturizeOnDoubleClick",
        "AppleShowScrollBars",
        "AppleScrollerPagingBehavior",
        "AppleMenuBarVisibleInFullscreen",
        "AppleEnableSwipeNavigateWithScrolls",
        "AppleEnableMouseSwipeNavigateWithScrolls",
        "ApplePressAndHoldEnabled",
        "AppleAntiAliasingThreshold",
        "AppleKeyboardUIMode",
        "AppleIconAppearanceTheme",
        "com.apple.swipescrolldirection",
        "com.apple.sound.uiaudio.enabled",
        "NSDocumentRevisionsDebugMode",
        "ApplePersistenceIgnoreState",
        "NSFullScreenMenuItemEverywhere",
        "NSPreferredWebServices",
        "WebKitDeveloperExtras",
    };
    for (size_t i = 0; i < sizeof(kHiddenPrefKeys) / sizeof(kHiddenPrefKeys[0]); i++) {
        if (strcmp(key, kHiddenPrefKeys[i]) == 0) {
            return true;
        }
    }
    return false;
}

__attribute__((visibility("hidden"))) bool pt_is_hidden_macos_mach_service_cstr(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return false;
    }
    if (strcmp(name, "com.apple.dock.server") == 0 || strncmp(name, "com.apple.dock.", 15) == 0 ||
        strncmp(name, "com.apple.windowserver.", 23) == 0 || strncmp(name, "com.apple.finder.", 17) == 0 ||
        strcmp(name, "com.apple.Finder") == 0 || strncmp(name, "com.apple.coreservices.launchservicesd", 38) == 0 ||
        strncmp(name, "com.apple.coreservices.appleevents", 34) == 0 ||
        strncmp(name, "com.apple.coreservices.quarantine-resolver", 42) == 0 ||
        strncmp(name, "com.apple.coreservices.sharedfilelistd", 38) == 0 ||
        strcmp(name, "com.apple.CoreServices.coreservicesd") == 0 || strncmp(name, "com.apple.loginwindow", 21) == 0 ||
        strncmp(name, "com.apple.systemuiserver", 24) == 0 || strcmp(name, "com.apple.pasteboard.1") == 0 ||
        strcmp(name, "com.apple.CoreDisplay.master") == 0 || strncmp(name, "com.apple.SkyLight.", 19) == 0 ||
        strncmp(name, "com.apple.ControlCenter", 23) == 0 || strncmp(name, "com.apple.tsm.uiserver", 22) == 0 ||
        strcmp(name, "com.apple.DesktopServicesHelper") == 0 || strncmp(name, "com.apple.endpointsecurity.", 27) == 0 ||
        strcmp(name, "com.apple.DiskArbitration.diskarbitrationd") == 0 || strcmp(name, "com.apple.FSEvents") == 0 ||
        strncmp(name, "com.apple.metadata.mds", 22) == 0 || strcmp(name, "com.apple.PowerManagement.control") == 0 ||
        strcmp(name, "com.apple.ocspd") == 0 || strncmp(name, "com.apple.cmio.", 15) == 0 ||
        strcmp(name, "com.apple.touchbarserver") == 0 || strcmp(name, "com.apple.SecurityServer") == 0) {
        return true;
    }
    if (strcasestr(name, "playcover") != NULL || strcasestr(name, "macover") != NULL ||
        strcasestr(name, "app.makedie") != NULL || strcasestr(name, "playtools") != NULL ||
        strcasestr(name, "akinterface") != NULL) {
        return true;
    }
    return false;
}

__attribute__((visibility("hidden"))) bool pt_is_hidden_xattr_name_cstr(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return false;
    }
    if (strncmp(name, "com.apple.metadata:", 19) == 0) {
        return true;
    }
    return (strcmp(name, "com.apple.quarantine") == 0 || strcmp(name, "com.apple.provenance") == 0 ||
            strcmp(name, "com.apple.macl") == 0 || strcmp(name, "com.apple.FinderInfo") == 0 ||
            strcmp(name, "com.apple.ResourceFork") == 0 || strcmp(name, "com.apple.TextEncoding") == 0 ||
            strcmp(name, "com.apple.lastuseddate#PS") == 0 || strcmp(name, "com.apple.LaunchServices.OpenWith") == 0 ||
            strcmp(name, "com.apple.rootless") == 0);
}

__attribute__((visibility("hidden"))) ssize_t pt_filter_xattr_list_buffer(char *buf, ssize_t raw_len) {
    if (buf == NULL || raw_len <= 0) {
        return raw_len;
    }
    char *read_ptr = buf;
    char *write_ptr = buf;
    char *end = buf + raw_len;
    while (read_ptr < end) {
        size_t len = strnlen(read_ptr, (size_t)(end - read_ptr));
        if (len == (size_t)(end - read_ptr)) {
            size_t rem = (size_t)(end - read_ptr);
            if (write_ptr != read_ptr) {
                memmove(write_ptr, read_ptr, rem);
            }
            write_ptr += rem;
            break;
        }
        size_t entry_sz = len + 1U;
        if (!pt_is_hidden_xattr_name_cstr(read_ptr)) {
            if (write_ptr != read_ptr) {
                memmove(write_ptr, read_ptr, entry_sz);
            }
            write_ptr += entry_sz;
        }
        read_ptr += entry_sz;
    }
    return (ssize_t)(write_ptr - buf);
}

__attribute__((visibility("hidden"))) bool pt_is_hidden_network_ifname_prefix_cstr(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return false;
    }
    return (strncmp(name, "vmenet", 6) == 0 || strncmp(name, "vmnet", 5) == 0 || strncmp(name, "bridge", 6) == 0 ||
            strncmp(name, "anpi", 4) == 0 || strncmp(name, "feth", 4) == 0 || strncmp(name, "XHC", 3) == 0 ||
            strncmp(name, "gif", 3) == 0 || strncmp(name, "stf", 3) == 0 || strncmp(name, "pktap", 5) == 0 ||
            strncmp(name, "iptap", 5) == 0 || strncmp(name, "vlan", 4) == 0 || strncmp(name, "bond", 4) == 0 ||
            strncmp(name, "fw", 2) == 0 || strncmp(name, "usb", 3) == 0);
}

__attribute__((visibility("hidden"))) bool pt_is_secondary_en_ifname_cstr(const char *name) {
    if (name == NULL) {
        return false;
    }
    if (name[0] == 'e' && name[1] == 'n' && name[2] >= '1' && name[2] <= '9') {
        return (name[3] == '\0' || (name[3] >= '0' && name[3] <= '9' && name[4] == '\0'));
    }
    return false;
}

__attribute__((visibility("hidden"))) bool pt_is_hidden_desktop_font_name_cstr(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return false;
    }
    while (*name != '\0' && isspace((unsigned char)*name)) {
        name++;
    }
    if (*name == '\0') {
        return false;
    }
    static const char *const kHiddenFontPrefixes[] = {"monaco",
                                                      "geneva",
                                                      "herculanum",
                                                      "lucida grande",
                                                      "lucidagrande",
                                                      "skia",
                                                      "osaka",
                                                      "applegothic",
                                                      "applemyungjo",
                                                      "apple chancery",
                                                      "applechancery",
                                                      "apple braille",
                                                      "applebraille",
                                                      "andale mono",
                                                      "andalemono",
                                                      "ayuthaya",
                                                      "baghdad",
                                                      "big caslon",
                                                      "bigcaslon",
                                                      "brush script mt",
                                                      "brushscriptmt",
                                                      "comic sans ms",
                                                      "comicsansms",
                                                      "corsiva hebrew",
                                                      "corsivahebrew",
                                                      "decotype naskh",
                                                      "decotypenaskh",
                                                      "gurmukhi mt",
                                                      "gurmukhimt",
                                                      "impact",
                                                      "inaimathi",
                                                      "krungthep",
                                                      "kufistandardgk",
                                                      "luminari",
                                                      "microsoft sans serif",
                                                      "microsoftsansserif",
                                                      "mshtakan",
                                                      "muna",
                                                      "new peninim mt",
                                                      "newpeninimmt",
                                                      "plantagenet cherokee",
                                                      "plantagenetcherokee",
                                                      "pt mono",
                                                      "ptmono",
                                                      "pt sans",
                                                      "ptsans",
                                                      "pt serif",
                                                      "ptserif",
                                                      "raanana",
                                                      "sathu",
                                                      "silom",
                                                      "tahoma",
                                                      "trattatello",
                                                      "webdings",
                                                      "wingdings",
                                                      "gb18030 bitmap",
                                                      "pcmyungjo",
                                                      "pilgi",
                                                      "gungseo",
                                                      "headlinea",
                                                      "lihei pro",
                                                      "lisong pro",
                                                      "biaukai",
                                                      "wawati",
                                                      "xingkai",
                                                      "yuanti",
                                                      "hannotate",
                                                      "hanzipen",
                                                      "lantinghei",
                                                      "baoli",
                                                      "libian",
                                                      "weibei",
                                                      "yuppy",
                                                      "klee",
                                                      "tsukushi",
                                                      "toppan bunkyu",
                                                      "yugothic",
                                                      "yumincho",
                                                      "sf mono",
                                                      "sfmono"};
    for (size_t i = 0; i < sizeof(kHiddenFontPrefixes) / sizeof(kHiddenFontPrefixes[0]); i++) {
        size_t plen = strlen(kHiddenFontPrefixes[i]);
        if (strncasecmp(name, kHiddenFontPrefixes[i], plen) == 0) {
            return true;
        }
    }
    return false;
}

static int pt_sf_symbol_bsearch_cmp(const void *key, const void *elem) {
    const char *k = (const char *)key;
    const char *e = *(const char *const *)elem;
    return strcmp(k, e);
}

__attribute__((visibility("hidden"))) bool pt_is_post13_7_sf_symbol_name_cstr(const char *s) {
    if (s == NULL || s[0] == '\0') {
        return false;
    }
    const size_t kAllowCount = sizeof(kPTSFSymbols13Allowlist) / sizeof(kPTSFSymbols13Allowlist[0]);
    if (bsearch(s, kPTSFSymbols13Allowlist, kAllowCount, sizeof(kPTSFSymbols13Allowlist[0]),
                pt_sf_symbol_bsearch_cmp) != NULL) {
        return false;
    }
    static const char *const kLocaleSuffixes[] = {".rtl", ".ar", ".he", ".hi", ".ja", ".ko", ".th", ".zh"};
    size_t len = strlen(s);
    if (len < 128U) {
        char base[128];
        memcpy(base, s, len + 1U);
        for (size_t i = 0; i < sizeof(kLocaleSuffixes) / sizeof(kLocaleSuffixes[0]); i++) {
            size_t slen = strlen(kLocaleSuffixes[i]);
            if (len > slen && strcmp(base + len - slen, kLocaleSuffixes[i]) == 0) {
                base[len - slen] = '\0';
                if (bsearch(base, kPTSFSymbols13Allowlist, kAllowCount, sizeof(kPTSFSymbols13Allowlist[0]),
                            pt_sf_symbol_bsearch_cmp) != NULL) {
                    return false;
                }
                break;
            }
        }
    }
    return true;
}

static const char *pt_find_substr(const char *hay, size_t hay_len, const char *needle, size_t needle_len) {
    if (hay == NULL || needle == NULL || needle_len == 0 || hay_len < needle_len) {
        return NULL;
    }
    const char *end = hay + (hay_len - needle_len) + 1U;
    const char *cur = hay;
    while (cur < end) {
        const char *hit = (const char *)memchr(cur, (unsigned char)needle[0], (size_t)(end - cur));
        if (hit == NULL) {
            return NULL;
        }
        if (needle_len == 1U || memcmp(hit + 1, needle + 1, needle_len - 1U) == 0) {
            return hit;
        }
        cur = hit + 1;
    }
    return NULL;
}

static bool pt_is_swift_type_delimiter(unsigned char ch) {
    switch (ch) {
    case '<':
    case '>':
    case ',':
    case '(':
    case ')':
    case '[':
    case ']':
    case ':':
    case '?':
    case '!':
    case '&':
    case ' ':
        return true;
    default:
        return false;
    }
}

static bool pt_mangled_contains_len_token(const char *buf, size_t len, const char *lit, size_t lit_len) {
    if (buf == NULL || lit == NULL || lit_len == 0 || len < lit_len) {
        return false;
    }
    const char *cur = buf;
    size_t rem = len;
    while (rem >= lit_len) {
        const char *pos = pt_find_substr(cur, rem, lit, lit_len);
        if (pos == NULL) {
            return false;
        }
        if (pos == buf || !isdigit((unsigned char)pos[-1])) {
            return true;
        }
        size_t adv = (size_t)(pos - cur) + 1U;
        cur += adv;
        rem -= adv;
    }
    return false;
}

static bool pt_has_qualified_module_prefix(const char *buf, size_t len, const char *lit, size_t lit_len) {
    if (buf == NULL || lit == NULL || lit_len == 0 || len < lit_len) {
        return false;
    }
    const char *cur = buf;
    size_t rem = len;
    while (rem >= lit_len) {
        const char *pos = pt_find_substr(cur, rem, lit, lit_len);
        if (pos == NULL) {
            return false;
        }
        if (pos == buf || pt_is_swift_type_delimiter((unsigned char)pos[-1])) {
            return true;
        }
        size_t adv = (size_t)(pos - cur) + 1U;
        cur += adv;
        rem -= adv;
    }
    return false;
}

static bool pt_has_qualified_type_token(const char *buf, size_t len, const char *lit, size_t lit_len) {
    if (buf == NULL || lit == NULL || lit_len == 0 || len < lit_len) {
        return false;
    }
    const char *cur = buf;
    size_t rem = len;
    while (rem >= lit_len) {
        const char *pos = pt_find_substr(cur, rem, lit, lit_len);
        if (pos == NULL) {
            return false;
        }
        bool start_ok = (pos == buf || pt_is_swift_type_delimiter((unsigned char)pos[-1]));
        const char *end = pos + lit_len;
        bool end_ok = (end == buf + len || pt_is_swift_type_delimiter((unsigned char)*end) || *end == '.');
        if (start_ok && end_ok) {
            return true;
        }
        size_t adv = (size_t)(pos - cur) + 1U;
        cur += adv;
        rem -= adv;
    }
    return false;
}

static const char *const kHiddenSwiftAlwaysDottedModules[] = {
    "PlayTools.", "AKInterface.",      "PlayCover.", "AppKit.",    "UIKitMacHelper.", "ViewBridge.",
    "SkyLight.",  "ScreenCaptureKit.", "Carbon.",    "HIToolbox.", "Cocoa.",          "IOBluetooth.",
};

static const char *const kHiddenSwiftCompat13QualifiedTypes[] = {
    "SwiftUI.LazyVStack",
    "SwiftUI.ProgressView",
    "SwiftUI.App",
    "SwiftUI.WindowGroup",
    "SwiftUI.Canvas",
    "SwiftUI.TimelineView",
    "SwiftUI.Label",
    "SwiftUI.Link",
    "SwiftUI.GridRow",
    "SwiftUI.NavigationSplitView",
    "Foundation.AttributedString",
    "Foundation.FormatStyle",
    "Foundation.Morphology",
    "StoreKit.Product",
    "StoreKit.Transaction",
    "_StringProcessing.Regex",
    "Observation.Observable",
    "Swift.Duration",
    "Swift.ContinuousClock",
    "Swift.SuspendingClock",
    "_Concurrency.Task",
    "Swift.Sendable",
    "OSLog.Logger",
};

__attribute__((visibility("hidden"))) bool
pt_is_hidden_swift_mangled_type_name_cstr(const char *typeNameStart, size_t typeNameLength, bool compat13_7) {
    if (typeNameStart == NULL || typeNameLength == 0) {
        return false;
    }
    size_t scan_len = (typeNameLength > 4096U) ? 4096U : typeNameLength;

    static const char *const kAlwaysMangledLenTokens[] = {
        "9PlayTools",   "11AKInterface", "9PlayCover",         "8AKPlugin", "6AppKit",    "14UIKitMacHelper",
        "10ViewBridge", "8SkyLight",     "16ScreenCaptureKit", "6Carbon",   "9HIToolbox", "5Cocoa",
    };
    for (size_t i = 0; i < sizeof(kAlwaysMangledLenTokens) / sizeof(kAlwaysMangledLenTokens[0]); i++) {
        const char *tok = kAlwaysMangledLenTokens[i];
        if (pt_mangled_contains_len_token(typeNameStart, scan_len, tok, strlen(tok))) {
            return true;
        }
    }
    for (size_t i = 0; i < sizeof(kHiddenSwiftAlwaysDottedModules) / sizeof(kHiddenSwiftAlwaysDottedModules[0]); i++) {
        const char *mod = kHiddenSwiftAlwaysDottedModules[i];
        if (pt_has_qualified_module_prefix(typeNameStart, scan_len, mod, strlen(mod))) {
            return true;
        }
    }

    if (compat13_7) {
        static const char *const kCompat13MangledLenTokens[] = {
            "7SwiftUI10LazyVStack",
            "7SwiftUI12ProgressView",
            "7SwiftUI10LazyHStack",
            "7SwiftUI9LazyVGrid",
            "7SwiftUI9LazyHGrid",
            "7SwiftUI10TextEditor",
            "7SwiftUI11ColorPicker",
            "7SwiftUI10AsyncImage",
            "7SwiftUI15NavigationStack",
            "7SwiftUI19NavigationSplitViewV",
            "7SwiftUI4GridV",
            "7SwiftUI7GridRowV",
            "7SwiftUI10AppStorage",
            "7SwiftUI11StateObject",
            "7SwiftUI12SceneStorage",
            "7SwiftUI12ScaledMetric",
            "7SwiftUI3AppP",
            "7SwiftUI5SceneP",
            "7SwiftUI11WindowGroupV",
            "7SwiftUI6CanvasV",
            "7SwiftUI12TimelineViewV",
            "7SwiftUI5LabelV",
            "7SwiftUI4LinkV",
            "10Foundation16AttributedString",
            "10Foundation11FormatStyle",
            "10Foundation10Morphology",
            "8StoreKit7Product",
            "8StoreKit11Transaction",
            "17_StringProcessing",
            "11Observation",
            "12_Concurrency",
            "22UniformTypeIdentifiers6UTType",
            "5OSLog6Logger",
        };
        for (size_t i = 0; i < sizeof(kCompat13MangledLenTokens) / sizeof(kCompat13MangledLenTokens[0]); i++) {
            const char *tok = kCompat13MangledLenTokens[i];
            if (pt_mangled_contains_len_token(typeNameStart, scan_len, tok, strlen(tok))) {
                return true;
            }
        }
        static const char *const kCompat13StdlibTokens[] = {
            "s8DurationV",
            "s15ContinuousClockV",
            "s15SuspendingClockV",
            "s8SendableP",
        };
        for (size_t i = 0; i < sizeof(kCompat13StdlibTokens) / sizeof(kCompat13StdlibTokens[0]); i++) {
            const char *tok = kCompat13StdlibTokens[i];
            if (pt_find_substr(typeNameStart, scan_len, tok, strlen(tok)) != NULL) {
                return true;
            }
        }
        for (size_t i = 0;
             i < sizeof(kHiddenSwiftCompat13QualifiedTypes) / sizeof(kHiddenSwiftCompat13QualifiedTypes[0]); i++) {
            const char *qtype = kHiddenSwiftCompat13QualifiedTypes[i];
            if (pt_has_qualified_type_token(typeNameStart, scan_len, qtype, strlen(qtype))) {
                return true;
            }
        }
        if (scan_len >= 3U && strncmp(typeNameStart, "ScT", 3) == 0) {
            return true;
        }
    }
    return false;
}

__attribute__((visibility("hidden"))) bool pt_is_hidden_swift_qualified_token_cstr(const char *tok, size_t len,
                                                                                   bool compat13_7) {
    if (tok == NULL || len == 0) {
        return false;
    }
    for (size_t i = 0; i < sizeof(kHiddenSwiftAlwaysDottedModules) / sizeof(kHiddenSwiftAlwaysDottedModules[0]); i++) {
        const char *mod = kHiddenSwiftAlwaysDottedModules[i];
        size_t mlen = strlen(mod);
        if (len >= mlen && memcmp(tok, mod, mlen) == 0) {
            return true;
        }
    }
    if (compat13_7) {
        static const char *const kCompat13DottedModules[] = {
            "_Concurrency.",
            "_StringProcessing.",
            "Observation.",
            "UniformTypeIdentifiers.",
        };
        for (size_t i = 0; i < sizeof(kCompat13DottedModules) / sizeof(kCompat13DottedModules[0]); i++) {
            const char *mod = kCompat13DottedModules[i];
            size_t mlen = strlen(mod);
            if (len >= mlen && memcmp(tok, mod, mlen) == 0) {
                return true;
            }
        }
        for (size_t i = 0;
             i < sizeof(kHiddenSwiftCompat13QualifiedTypes) / sizeof(kHiddenSwiftCompat13QualifiedTypes[0]); i++) {
            const char *qtype = kHiddenSwiftCompat13QualifiedTypes[i];
            size_t qlen = strlen(qtype);
            if (len >= qlen && memcmp(tok, qtype, qlen) == 0 && (len == qlen || tok[qlen] == '.')) {
                return true;
            }
        }
    }
    return false;
}

__attribute__((visibility("hidden"))) bool pt_is_carboncore_framework_path_cstr(const char *path) {
    if (path == NULL || path[0] == '\0' || strstr(path, "..") != NULL) {
        return false;
    }
    static const char kCoreServicesPrefix[] = "/System/Library/Frameworks/CoreServices.framework/";
    const size_t prefix_len = sizeof(kCoreServicesPrefix) - 1U;
    if (strncmp(path, kCoreServicesPrefix, prefix_len) != 0) {
        return false;
    }
    const char *hit = strstr(path + prefix_len, "CarbonCore.framework/");
    return (hit != NULL && (hit == path + prefix_len || hit[-1] == '/'));
}

__attribute__((visibility("hidden"))) bool pt_is_cf_internal_carboncore_bridge_caller_cstr(const char *caller_fname,
                                                                                           const char *caller_sname) {
    if (caller_fname == NULL || caller_fname[0] == '\0' || strstr(caller_fname, "..") != NULL) {
        return false;
    }
    static const char kCFPrefix[] = "/System/Library/Frameworks/CoreFoundation.framework/";
    if (strncmp(caller_fname, kCFPrefix, sizeof(kCFPrefix) - 1U) != 0) {
        return false;
    }
    if (caller_sname != NULL && strstr(caller_sname, "CFBundle") != NULL) {
        return false;
    }
    return true;
}
