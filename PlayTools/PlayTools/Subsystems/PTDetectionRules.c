//
//  PTDetectionRules.c
//  PlayTools
//
//  Pure-C anti-detection rule matchers, path normalizers, and xattr/network filters.
//

#include "PTDetectionRules.h"
#include "PTSFSymbols13Allowlist.h"

#include <ctype.h>
#include <stdio.h>
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

__attribute__((visibility("hidden"))) bool pt_is_hidden_sysctl_name_cstr(const char *name, bool compat13_7,
                                                                         uint32_t e_cores) {
    if (name == NULL || name[0] == '\0') {
        return false;
    }
    if (strcmp(name, "sysctl.proc_translated") == 0 || strcmp(name, "sysctl.proc_native") == 0 ||
        strcmp(name, "sysctl.proc_cputype") == 0 || strcmp(name, "kern.iossupportversion") == 0 ||
        strncmp(name, "kern.hibernate", 14) == 0 || strncmp(name, "kern.hv.", 8) == 0 ||
        strncmp(name, "kern.dtrace.", 12) == 0 || strcmp(name, "kern.singleuser") == 0 ||
        strcmp(name, "kern.safeboot") == 0 || strcmp(name, "kern.willshutdown") == 0 ||
        strcmp(name, "kern.waketime") == 0 || strcmp(name, "kern.sleeptime") == 0 ||
        strcmp(name, "kern.darkboot") == 0 || strcmp(name, "kern.minimalboot") == 0 ||
        strcmp(name, "kern.aotmode") == 0 || strcmp(name, "kern.aotmodebits") == 0 ||
        strcmp(name, "kern.lowpowerwake") == 0 || strcmp(name, "kern.bootsignature") == 0 ||
        strcmp(name, "kern.system_version_compat") == 0 || strcmp(name, "kern.osproductversioncompat") == 0 ||
        strcmp(name, "kern.drivercorefile") == 0 || strcmp(name, "kern.kdp_corefile") == 0 ||
        strcmp(name, "hw.use_kernelmanagerd") == 0 || strcmp(name, "hw.features.allows_security_research") == 0 ||
        strcmp(name, "hw.ephemeral_storage") == 0 || strcmp(name, "hw.use_recovery_securityd") == 0 ||
        strcmp(name, "vm.swapusage") == 0 || strcmp(name, "vm.darkwake_mode") == 0 ||
        strncmp(name, "vm.compressor.swapper.", 22) == 0 || strncmp(name, "vm.compressor_swapout", 21) == 0 ||
        strncmp(name, "vm.compressor_swapper_", 22) == 0 || strncmp(name, "security.mac.sandbox.", 21) == 0 ||
        strncmp(name, "security.mac.asp.", 17) == 0 || strncmp(name, "security.mac.endpointsecurity.", 30) == 0 ||
        strncmp(name, "security.mac.qtn.", 17) == 0 ||
        (strncmp(name, "security.mac.amfi.", 18) == 0 &&
         strcmp(name, "security.mac.amfi.developer_mode_status") != 0)) {
        return true;
    }
    if (strncmp(name, "hw.perflevel1.", 14) == 0 && e_cores == 0U) {
        return true;
    }
    if (compat13_7) {
        if (strncmp(name, "hw.optional.arm.", 16) == 0 || strcmp(name, "kern.osproductversioncompat") == 0 ||
            strcmp(name, "hw.nperflevels") == 0 || strncmp(name, "hw.perflevel0.", 14) == 0 ||
            strncmp(name, "hw.perflevel1.", 14) == 0) {
            return true;
        }
    }
    return false;
}

__attribute__((visibility("hidden"))) uint64_t pt_sanitize_osvariant_status_u64(uint64_t raw_status) {
    return raw_status & ~0x0000000005555555ULL;
}

__attribute__((visibility("hidden"))) uint64_t pt_spoofed_l1d_cache_size_u64(uint32_t max_apple_gpu_family,
                                                                             bool is_e_core) {
    if (is_e_core) {
        if (max_apple_gpu_family <= 1006U) {
            return 32768ULL;
        }
        return 65536ULL;
    }
    if (max_apple_gpu_family <= 1003U) {
        return 32768ULL;
    }
    if (max_apple_gpu_family <= 1006U) {
        return 65536ULL;
    }
    return 131072ULL;
}

__attribute__((visibility("hidden"))) uint64_t pt_spoofed_l1i_cache_size_u64(uint32_t max_apple_gpu_family,
                                                                             bool is_e_core) {
    if (is_e_core) {
        if (max_apple_gpu_family <= 1006U) {
            return 65536ULL;
        }
        return 131072ULL;
    }
    if (max_apple_gpu_family <= 1003U) {
        return 65536ULL;
    }
    if (max_apple_gpu_family <= 1006U) {
        return 131072ULL;
    }
    return 196608ULL;
}

__attribute__((visibility("hidden"))) void pt_spoofed_l2_cache_sizes_u64(uint32_t max_apple_gpu_family,
                                                                         const char *model, uint64_t *out_p_l2,
                                                                         uint64_t *out_e_l2) {
    uint64_t p_l2 = 16ULL << 20;
    uint64_t e_l2 = 4ULL << 20;
    if (max_apple_gpu_family <= 1003U) {
        p_l2 = 3ULL << 20;
        e_l2 = 0ULL;
    } else if (max_apple_gpu_family <= 1006U) {
        p_l2 = 8ULL << 20;
        e_l2 = 4ULL << 20;
    } else if (max_apple_gpu_family == 1007U || (model != NULL && strcmp(model, "iPhone14,3") == 0)) {
        p_l2 = 12ULL << 20;
        e_l2 = 4ULL << 20;
    }
    if (out_p_l2 != NULL) {
        *out_p_l2 = p_l2;
    }
    if (out_e_l2 != NULL) {
        *out_e_l2 = e_l2;
    }
}

static void pt_replace_substr_in_buf(char *buf, size_t cap, const char *needle, const char *repl) {
    if (buf == NULL || cap == 0 || needle == NULL || repl == NULL) {
        return;
    }
    size_t nlen = strlen(needle);
    size_t rlen = strlen(repl);
    if (nlen == 0 || strcmp(needle, repl) == 0) {
        return;
    }
    size_t pos = 0;
    for (int guard = 0; guard < 16; guard++) {
        char *hit = strstr(buf + pos, needle);
        if (hit == NULL) {
            break;
        }
        size_t off = (size_t)(hit - buf);
        size_t cur_len = strlen(buf);
        if (cur_len - nlen + rlen >= cap) {
            break;
        }
        if (rlen != nlen) {
            memmove(hit + rlen, hit + nlen, cur_len - off - nlen + 1U);
        }
        memcpy(hit, repl, rlen);
        pos = off + rlen;
    }
}

static void pt_replace_agx_gen_tokens(char *buf, size_t cap, const char *prefix_with_g, const char *prefix_no_g,
                                      const char *gpu_gen, unsigned long target_gen, bool compat13_7) {
    if (buf == NULL || cap == 0 || prefix_with_g == NULL || prefix_no_g == NULL || gpu_gen == NULL) {
        return;
    }
    size_t plen = strlen(prefix_with_g);
    size_t target_len = strlen(gpu_gen);
    char repl[64];
    int rn = snprintf(repl, sizeof(repl), "%s%s", prefix_no_g, gpu_gen);
    if (rn <= 0 || (size_t)rn >= sizeof(repl)) {
        return;
    }
    size_t rlen = (size_t)rn;
    size_t pos = 0;
    for (int guard = 0; guard < 16; guard++) {
        char *hit = strstr(buf + pos, prefix_with_g);
        if (hit == NULL) {
            break;
        }
        if (hit[plen] < '0' || hit[plen] > '9') {
            pos = (size_t)(hit - buf) + plen;
            continue;
        }
        char *endp = NULL;
        unsigned long gen = strtoul(hit + plen, &endp, 10);
        if (endp == NULL || endp == hit + plen) {
            pos = (size_t)(hit - buf) + plen;
            continue;
        }
        if (*endp != '\0' && strchr("GPSXCDgpsxcd", *endp) != NULL) {
            endp++;
        }
        size_t tok_gen_len = (size_t)(endp - (hit + plen - 1U));
        bool mismatch = (gen != target_gen) || (compat13_7 && gen >= 13UL) || (tok_gen_len != target_len) ||
                        (strncmp(hit + plen - 1U, gpu_gen, target_len) != 0);
        size_t span_len = (size_t)(endp - hit);
        size_t off = (size_t)(hit - buf);
        if (mismatch) {
            size_t cur_len = strlen(buf);
            if (cur_len - span_len + rlen >= cap) {
                break;
            }
            if (rlen != span_len) {
                memmove(hit + rlen, endp, cur_len - off - span_len + 1U);
            }
            memcpy(hit, repl, rlen);
            pos = off + rlen;
        } else {
            pos = off + span_len;
        }
    }
}

__attribute__((visibility("hidden"))) void pt_sanitize_io_hardware_name_cstr(char *buf, size_t cap,
                                                                             const char *lower_soc, const char *gpu_gen,
                                                                             const char *oem_id, const char *gpu_arch,
                                                                             bool compat13_7) {
    if (buf == NULL || cap == 0 || buf[0] == '\0') {
        return;
    }
    const char *eff_lower_soc = (lower_soc != NULL && lower_soc[0] != '\0') ? lower_soc : "t8103";
    char upper_soc[16] = {0};
    for (size_t i = 0; i + 1U < sizeof(upper_soc) && eff_lower_soc[i] != '\0'; i++) {
        char c = eff_lower_soc[i];
        upper_soc[i] = (c >= 'a' && c <= 'z') ? (char)(c - 'a' + 'A') : c;
    }
    const char *eff_gpu_gen = (gpu_gen != NULL && gpu_gen[0] != '\0') ? gpu_gen : "G13G";
    char gpu_short[8] = "G13";
    if (eff_gpu_gen[0] == 'G' && eff_gpu_gen[1] >= '0' && eff_gpu_gen[1] <= '9') {
        size_t gl = 2U;
        while (gl + 1U < sizeof(gpu_short) && eff_gpu_gen[gl] >= '0' && eff_gpu_gen[gl] <= '9') {
            gl++;
        }
        memcpy(gpu_short, eff_gpu_gen, gl);
        gpu_short[gl] = '\0';
    }
    const char *isp_gen = (strcmp(upper_soc, "S8001") == 0)
                              ? "H8"
                              : ((strcmp(upper_soc, "T8027") == 0 || strcmp(upper_soc, "T8000") == 0)
                                     ? "H11"
                                     : (strcmp(upper_soc, "T8030") == 0 ? "H12" : "H13"));

    static const char *const kHostSocs[] = {"S8001", "T8000", "T8010", "T8015", "T8020", "T8027", "T8100", "T8110",
                                            "T8120", "T8130", "T8140", "T8103", "T8101", "T8102", "T810x", "T8112",
                                            "T8122", "T8132", "T8142", "T6000", "T6001", "T6002", "T6020", "T6021",
                                            "T6022", "T6030", "T6031", "T6032", "T6034", "T6040", "T6041", "T6042"};
    static const char *const kHostSocsLower[] = {
        "s8001", "t8000", "t8010", "t8015", "t8020", "t8027", "t8100", "t8110", "t8120", "t8130", "t8140",
        "t8103", "t8101", "t8102", "t810x", "t8112", "t8122", "t8132", "t8142", "t6000", "t6001", "t6002",
        "t6020", "t6021", "t6022", "t6030", "t6031", "t6032", "t6034", "t6040", "t6041", "t6042"};
    for (size_t i = 0; i < sizeof(kHostSocs) / sizeof(kHostSocs[0]); i++) {
        if (strcmp(kHostSocs[i], upper_soc) != 0) {
            pt_replace_substr_in_buf(buf, cap, kHostSocs[i], upper_soc);
            pt_replace_substr_in_buf(buf, cap, kHostSocsLower[i], eff_lower_soc);
        }
    }

    unsigned long target_gen = strtoul(gpu_short + 1, NULL, 10);
    pt_replace_agx_gen_tokens(buf, cap, "AGXAcceleratorG", "AGXAccelerator", eff_gpu_gen, target_gen, compat13_7);
    pt_replace_agx_gen_tokens(buf, cap, "AGXMetalG", "AGXMetal", eff_gpu_gen, target_gen, compat13_7);
    pt_replace_agx_gen_tokens(buf, cap, "AGXFirmwareKextG", "AGXFirmwareKext", eff_gpu_gen, target_gen, compat13_7);

    static const char *const kGpuShorts[] = {"G13", "G14", "G15", "G16", "G17", "G18"};
    static const char *const kIspGens[] = {"H13", "H14", "H15", "H16"};
    if (strstr(buf, "AGXFirmwareKext") != NULL || compat13_7 || strcmp(upper_soc, "T8103") != 0) {
        if (strstr(buf, "AGX") != NULL && strstr(buf, "AGXAccelerator") == NULL && strstr(buf, "AGXMetal") == NULL &&
            strstr(buf, "AGXFirmwareKext") == NULL) {
            for (size_t i = 0; i < sizeof(kGpuShorts) / sizeof(kGpuShorts[0]); i++) {
                if (strcmp(kGpuShorts[i], gpu_short) != 0) {
                    pt_replace_substr_in_buf(buf, cap, kGpuShorts[i], gpu_short);
                }
            }
        }
        if (strstr(buf, "CamIn") != NULL) {
            for (size_t i = 0; i < sizeof(kIspGens) / sizeof(kIspGens[0]); i++) {
                if (strcmp(kIspGens[i], isp_gen) != 0) {
                    pt_replace_substr_in_buf(buf, cap, kIspGens[i], isp_gen);
                }
            }
        }
    }

    static const char *const kMacBoardIDs[] = {
        "J180", "J274", "J275", "J293", "J313", "J314", "J316", "J323", "J375", "J413", "J414", "J415", "J416",
        "J433", "J434", "J456", "J457", "J473", "J474", "J475", "J493", "J504", "J514", "J516", "J575", "J604",
        "J613", "J614", "J615", "J616", "J623", "J624", "J673", "J713", "J715", "J773", "J775", "j180", "j274",
        "j275", "j293", "j313", "j314", "j316", "j323", "j375", "j413", "j414", "j415", "j416", "j433", "j434",
        "j456", "j457", "j473", "j474", "j475", "j493", "j504", "j514", "j516", "j575", "j604", "j613", "j614",
        "j615", "j616", "j623", "j624", "j673", "j713", "j715", "j773", "j775"};
    const char *oem = (oem_id != NULL && oem_id[0] != '\0') ? oem_id : "J522AP";
    char board_repl[16] = {0};
    strlcpy(board_repl, oem, sizeof(board_repl));
    size_t blen = strlen(board_repl);
    if (blen > 2U && strcasecmp(board_repl + blen - 2U, "AP") == 0) {
        board_repl[blen - 2U] = '\0';
    }
    char board_repl_lower[16] = {0};
    for (size_t i = 0; i + 1U < sizeof(board_repl_lower) && board_repl[i] != '\0'; i++) {
        char c = board_repl[i];
        board_repl_lower[i] = (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
    }
    for (size_t i = 0; i < sizeof(kMacBoardIDs) / sizeof(kMacBoardIDs[0]); i++) {
        bool is_lower = (kMacBoardIDs[i][0] >= 'a' && kMacBoardIDs[i][0] <= 'z');
        const char *target_board = is_lower ? board_repl_lower : board_repl;
        if (strcasecmp(kMacBoardIDs[i], target_board) != 0 && strstr(buf, kMacBoardIDs[i]) != NULL) {
            pt_replace_substr_in_buf(buf, cap, kMacBoardIDs[i], target_board);
        }
    }

    const char *target_gpu_arch = (gpu_arch != NULL && gpu_arch[0] != '\0') ? gpu_arch : "applegpu_g13g";
    size_t target_gpu_len = strlen(target_gpu_arch);
    size_t gpu_pos = 0;
    for (int guard = 0; guard < 16; guard++) {
        char *hit = strstr(buf + gpu_pos, "applegpu_g");
        if (hit == NULL) {
            break;
        }
        if (hit[10] < '0' || hit[10] > '9') {
            gpu_pos = (size_t)(hit - buf) + 10U;
            continue;
        }
        char *endp = hit + 10U;
        while (*endp >= '0' && *endp <= '9') {
            endp++;
        }
        if (*endp >= 'a' && *endp <= 'z') {
            endp++;
        }
        size_t span = (size_t)(endp - hit);
        size_t off = (size_t)(hit - buf);
        if (span != target_gpu_len || strncmp(hit, target_gpu_arch, span) != 0) {
            size_t cur_len = strlen(buf);
            if (cur_len - span + target_gpu_len >= cap) {
                break;
            }
            if (target_gpu_len != span) {
                memmove(hit + target_gpu_len, endp, cur_len - off - span + 1U);
            }
            memcpy(hit, target_gpu_arch, target_gpu_len);
            gpu_pos = off + target_gpu_len;
        } else {
            gpu_pos = off + span;
        }
    }
}

__attribute__((visibility("hidden"))) bool pt_is_app_embedded_bundle_path_cstr(const char *path) {
    if (path == NULL || path[0] != '/') {
        return false;
    }
    return (strstr(path, ".app/Frameworks/") != NULL || strstr(path, ".app/PlugIns/") != NULL ||
            strstr(path, ".app/Contents/Frameworks/") != NULL || strstr(path, ".app/Contents/PlugIns/") != NULL ||
            strstr(path, ".appex/Frameworks/") != NULL);
}

__attribute__((visibility("hidden"))) bool pt_is_post13_7_framework_path_cstr(const char *path) {
    if (path == NULL || path[0] == '\0' || pt_is_app_embedded_bundle_path_cstr(path)) {
        return false;
    }
    static const char *const kPost13_7Components[] = {
        "ExtensionKit.framework",
        "ExtensionFoundation.framework",
        "WidgetKit.framework",
        "TipKit.framework",
        "AppIntents.framework",
        "AppTrackingTransparency.framework",
        "UniformTypeIdentifiers.framework",
        "Observation.framework",
        "SwiftData.framework",
        "ActivityKit.framework",
        "GroupActivities.framework",
        "NearbyInteraction.framework",
        "Charts.framework",
        "OSLog.framework",
        "WeatherKit.framework",
        "MusicKit.framework",
        "RoomPlan.framework",
        "WorkoutKit.framework",
        "Translation.framework",
        "FamilyControls.framework",
        "ManagedSettings.framework",
        "DeviceActivity.framework",
        "Cinematic.framework",
        "CoreTransferable.framework",
        "Spatial.framework",
        "DockKit.framework",
        "FinanceKit.framework",
        "JournalingSuggestions.framework",
        "SensitiveContentAnalysis.framework",
        "LockedCameraCapture.framework",
        "MarketplaceKit.framework",
        "libswift_Concurrency.dylib",
        "libswift_StringProcessing.dylib",
    };
    const size_t n = sizeof(kPost13_7Components) / sizeof(kPost13_7Components[0]);
    for (size_t i = 0; i < n; i++) {
        if (pt_path_has_component(path, kPost13_7Components[i])) {
            return true;
        }
    }
    return false;
}

__attribute__((visibility("hidden"))) bool pt_collapse_macos_framework_versions_in_place_cstr(char *work, size_t cap) {
    if (work == NULL || cap == 0) {
        return false;
    }
    bool changed = false;
    for (int iter = 0; iter < 8; iter++) {
        const char *fw_ver = strcasestr(work, ".framework/Versions/");
        const char *bdl_ver = strcasestr(work, ".bundle/Versions/");
        const char *bdl_mac = strcasestr(work, ".bundle/Contents/MacOS/");
        const char *hit = fw_ver;
        size_t keep_ext_len = 10U;
        size_t skip_prefix_len = 20U;
        if (bdl_ver != NULL && (hit == NULL || bdl_ver < hit)) {
            hit = bdl_ver;
            keep_ext_len = 7U;
            skip_prefix_len = 17U;
        }
        if (bdl_mac != NULL && (hit == NULL || bdl_mac < hit)) {
            hit = bdl_mac;
            keep_ext_len = 7U;
            skip_prefix_len = 22U;
        }
        if (hit == NULL) {
            break;
        }
        const char *rest = NULL;
        if (hit == bdl_mac) {
            rest = hit + skip_prefix_len;
        } else {
            const char *after_versions = hit + skip_prefix_len;
            rest = strchr(after_versions, '/');
        }
        if (rest == NULL) {
            break;
        }
        size_t prefix_len = (size_t)(hit - work) + keep_ext_len;
        size_t rest_len = strlen(rest);
        if (prefix_len + rest_len >= cap) {
            break;
        }
        memmove(work + prefix_len, rest, rest_len + 1U);
        changed = true;
    }
    return changed;
}

__attribute__((visibility("hidden"))) bool pt_is_dirty_code_resources_key_cstr(const char *key) {
    if (key == NULL || key[0] == '\0') {
        return false;
    }
    return (strcasestr(key, "PlayTools") != NULL || strcasestr(key, "PlayCover") != NULL ||
            strcasestr(key, "MacOver") != NULL || strcasestr(key, "AKInterface") != NULL ||
            strcasestr(key, "SVCPatches") != NULL || strcasestr(key, "Playtools.strings") != NULL ||
            strcasestr(key, "UserPlugins") != NULL || strcasestr(key, "pm_keymapping_state") != NULL ||
            strcasestr(key, "toucher.log") != NULL);
}

__attribute__((visibility("hidden"))) bool pt_is_hidden_runtime_artifact_name_cstr(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return false;
    }
    if (strcasecmp(name, "toucher.log") == 0 || strcasecmp(name, "pm_keymapping_state.plist") == 0) {
        return true;
    }
    if (strncasecmp(name, "pm_keymapping_state_", 20) == 0) {
        size_t len = strlen(name);
        if (len >= 26U && strcasecmp(name + len - 6U, ".plist") == 0) {
            return true;
        }
    }
    return false;
}

__attribute__((visibility("hidden"))) bool pt_path_has_hidden_runtime_artifact_cstr(const char *path) {
    if (path == NULL || path[0] == '\0') {
        return false;
    }
    const char *p = path;
    while (*p != '\0') {
        while (*p == '/') {
            p++;
        }
        if (*p == '\0') {
            break;
        }
        const char *end = p;
        while (*end != '\0' && *end != '/') {
            end++;
        }
        size_t len = (size_t)(end - p);
        if (len > 0U && len < 256U) {
            char comp[256];
            memcpy(comp, p, len);
            comp[len] = '\0';
            if (pt_is_hidden_runtime_artifact_name_cstr(comp)) {
                return true;
            }
        }
        p = end;
    }
    return false;
}

__attribute__((visibility("hidden"))) bool pt_is_sensitive_unix_socket_token_cstr(const char *sun_path) {
    if (sun_path == NULL || sun_path[0] == '\0') {
        return false;
    }
    return (strstr(sun_path, "/var/folders/") != NULL || strstr(sun_path, "com.apple.launchd") != NULL ||
            strstr(sun_path, "discord-ipc") != NULL || strcasestr(sun_path, "PlayCover") != NULL ||
            strcasestr(sun_path, "PlayTools") != NULL || strcasestr(sun_path, "MacOver") != NULL ||
            strcasestr(sun_path, "app.makedie") != NULL);
}

__attribute__((visibility("hidden"))) bool pt_is_icu_age_post_13_7_c(uint8_t major, uint8_t minor) {
    return (major > 12U) || (major == 12U && minor > 1U);
}
