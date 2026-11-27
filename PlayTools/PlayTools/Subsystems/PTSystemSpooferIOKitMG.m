//
//  PTSystemSpooferIOKitMG.m
//  PlayTools
//

#import "PTSystemSpooferInternal.h"
#import "PTFSInternal.h"
#import "PTDyldInternal.h"
#include <CommonCrypto/CommonDigest.h>
@import AudioToolbox;
@import CoreServices;
@import IOKit;


static NSArray<NSString *> *pt_blocked_ioreg_keys_list(void) {
    static NSArray<NSString *> *s_keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_keys = @[
            @"serial-number", @"IOPlatformSerialNumber", @"SystemSerialNumber",
            @"IOPlatformUUID", @"mlb-serial-number", @"board-id",
            @"CompatibleDeviceFallback", @"has-boot-chime", @"boot-args",
            @"IONVRAM", @"efi-boot-device",
            @"AppleClamshellState", @"AppleClamshellCausesSleep",
            @"HibernateMode", @"HibernateFile",
            @"AppleRawAdapterDetails", @"AdapterDetails",
            @"Supported Features", @"SystemPowerProfileOverrideDict",
            @"fmm-computer-name", @"SystemAudioVolume", @"StartupMute",
            @"backlight-nits", @"prev-lang:kbd", @"auto-boot"
        ];
    });
    return s_keys;
}

static NSArray<NSString *> *pt_spoofed_ioreg_keys_list(void) {
    static NSArray<NSString *> *s_keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_keys = @[
            @"model", @"target-type", @"target-sub-type", @"compatible", @"chip-id",
            @"model-number", @"regulatory-model-number", @"region-info", @"platform-name",
            @"product-name", @"product-description", @"product-soc-name", @"manufacturer",
            @"gpu-core-count", @"metal-plugin-name", @"MetalPluginName", @"MetalPluginClassName",
            @"name", @"IOClass", @"CFBundleIdentifier"
        ];
    });
    return s_keys;
}

static BOOL pt_is_blocked_ioreg_key(CFStringRef key) {
    if (key == NULL) {
        return NO;
    }
    NSString *kstr = (__bridge NSString *)key;
    for (NSString *blocked in pt_blocked_ioreg_keys_list()) {
        if ([kstr isEqualToString:blocked]) {
            return YES;
        }
    }
    return NO;
}

static BOOL pt_is_spoofed_ioreg_key(CFStringRef key) {
    if (key == NULL) {
        return NO;
    }
    NSString *kstr = (__bridge NSString *)key;
    for (NSString *spoof in pt_spoofed_ioreg_keys_list()) {
        if ([kstr isEqualToString:spoof]) {
            return YES;
        }
    }
    return NO;
}

static CFTypeRef pt_create_sanitized_ioreg_cfvalue_if_changed(CFTypeRef val, CFAllocatorRef allocator, int depth) CF_RETURNS_RETAINED;

static CFTypeRef pt_create_ioreg_cstr_like(const char *cstr, CFTypeRef orig_val, CFAllocatorRef allocator) CF_RETURNS_RETAINED {
    if (cstr == NULL) {
        return NULL;
    }
    if (orig_val != NULL && CFGetTypeID(orig_val) == CFStringGetTypeID()) {
        return CFStringCreateWithCString(allocator, cstr, kCFStringEncodingUTF8);
    }
    return CFDataCreate(allocator, (const UInt8 *)cstr, (CFIndex)(strlen(cstr) + 1));
}

static CFTypeRef pt_spoof_ioreg_value_for_key(CFStringRef key, CFTypeRef orig_val, CFAllocatorRef allocator) CF_RETURNS_RETAINED {
    if (key == NULL || orig_val == NULL) {
        return NULL;
    }
    const pt_device_profile_t *profile = pt_get_active_device_profile();
    if (CFStringCompare(key, CFSTR("model"), 0) == kCFCompareEqualTo) {
        return pt_create_ioreg_cstr_like(profile->model, orig_val, allocator);
    }
    if (CFStringCompare(key, CFSTR("target-type"), 0) == kCFCompareEqualTo ||
        CFStringCompare(key, CFSTR("target-sub-type"), 0) == kCFCompareEqualTo) {
        return pt_create_ioreg_cstr_like(profile->oem_id, orig_val, allocator);
    }
    if (CFStringCompare(key, CFSTR("compatible"), 0) == kCFCompareEqualTo) {
        if (CFGetTypeID(orig_val) == CFStringGetTypeID()) {
            return CFStringCreateWithCString(allocator, profile->oem_id, kCFStringEncodingUTF8);
        }
        return pt_create_compatible_cfdata(allocator);
    }
    if (CFStringCompare(key, CFSTR("chip-id"), 0) == kCFCompareEqualTo) {
        uint32_t chip = 0x8103U;
        if (profile != NULL && profile->soc_code != NULL &&
            (profile->soc_code[0] == 't' || profile->soc_code[0] == 's')) {
            chip = (uint32_t)strtoul(profile->soc_code + 1, NULL, 16);
        }
        if (CFGetTypeID(orig_val) == CFNumberGetTypeID()) {
            int32_t s32 = (int32_t)chip;
            return CFNumberCreate(allocator, kCFNumberSInt32Type, &s32);
        }
        if (CFGetTypeID(orig_val) == CFDataGetTypeID()) {
            CFIndex dlen = CFDataGetLength((CFDataRef)orig_val);
            if (dlen == 8) {
                uint64_t chip64 = OSSwapHostToLittleInt64((uint64_t)chip);
                return CFDataCreate(allocator, (const UInt8 *)&chip64, sizeof(chip64));
            }
            uint32_t chip32 = OSSwapHostToLittleInt32(chip);
            return CFDataCreate(allocator, (const UInt8 *)&chip32, sizeof(chip32));
        }
        return NULL;
    }
    if (CFStringCompare(key, CFSTR("model-number"), 0) == kCFCompareEqualTo) {
        return pt_create_ioreg_cstr_like(profile->model_number, orig_val, allocator);
    }
    if (CFStringCompare(key, CFSTR("regulatory-model-number"), 0) == kCFCompareEqualTo) {
        return pt_create_ioreg_cstr_like(profile->regulatory_model, orig_val, allocator);
    }
    if (CFStringCompare(key, CFSTR("region-info"), 0) == kCFCompareEqualTo) {
        return pt_create_ioreg_cstr_like("LL/A", orig_val, allocator);
    }
    if (CFStringCompare(key, CFSTR("platform-name"), 0) == kCFCompareEqualTo) {
        return pt_create_ioreg_cstr_like("iphoneos", orig_val, allocator);
    }
    if (CFStringCompare(key, CFSTR("product-name"), 0) == kCFCompareEqualTo ||
        CFStringCompare(key, CFSTR("product-description"), 0) == kCFCompareEqualTo) {
        return pt_create_ioreg_cstr_like(profile->marketing_name, orig_val, allocator);
    }
    if (CFStringCompare(key, CFSTR("product-soc-name"), 0) == kCFCompareEqualTo) {
        return pt_create_ioreg_cstr_like(profile->cpu_brand, orig_val, allocator);
    }
    if (CFStringCompare(key, CFSTR("manufacturer"), 0) == kCFCompareEqualTo) {
        return pt_create_ioreg_cstr_like("Apple Inc.", orig_val, allocator);
    }
    if (CFStringCompare(key, CFSTR("gpu-core-count"), 0) == kCFCompareEqualTo) {
        if (CFGetTypeID(orig_val) == CFNumberGetTypeID()) {
            int32_t cores = (int32_t)profile->gpu_cores;
            return CFNumberCreate(allocator, kCFNumberSInt32Type, &cores);
        }
        if (CFGetTypeID(orig_val) == CFDataGetTypeID() && CFDataGetLength((CFDataRef)orig_val) == sizeof(uint32_t)) {
            uint32_t cores = profile->gpu_cores;
            return CFDataCreate(allocator, (const UInt8 *)&cores, sizeof(cores));
        }
        return NULL;
    }
    if (CFStringCompare(key, CFSTR("metal-plugin-name"), 0) == kCFCompareEqualTo ||
        CFStringCompare(key, CFSTR("MetalPluginName"), 0) == kCFCompareEqualTo) {
        char plugin[64];
        const char *ggen = (profile->gpu_gen != NULL) ? profile->gpu_gen : "G13G";
        snprintf(plugin, sizeof(plugin), "AGXMetal%s", ggen);
        return pt_create_ioreg_cstr_like(plugin, orig_val, allocator);
    }
    if (CFStringCompare(key, CFSTR("MetalPluginClassName"), 0) == kCFCompareEqualTo) {
        char orig_buf[128] = {0};
        if (CFGetTypeID(orig_val) == CFStringGetTypeID()) {
            CFStringGetCString((CFStringRef)orig_val, orig_buf, (CFIndex)sizeof(orig_buf), kCFStringEncodingUTF8);
        } else if (CFGetTypeID(orig_val) == CFDataGetTypeID()) {
            CFIndex dlen = CFDataGetLength((CFDataRef)orig_val);
            if (dlen > 0 && dlen < (CFIndex)sizeof(orig_buf)) {
                memcpy(orig_buf, CFDataGetBytePtr((CFDataRef)orig_val), (size_t)dlen);
                orig_buf[dlen] = '\0';
            }
        }
        char plugin[96];
        const char *ggen = (profile->gpu_gen != NULL) ? profile->gpu_gen : "G13G";
        if (strstr(orig_buf, "Device") != NULL) {
            snprintf(plugin, sizeof(plugin), "AGXMetal%sDevice", ggen);
        } else {
            snprintf(plugin, sizeof(plugin), "AGXMetal%s", ggen);
        }
        return pt_create_ioreg_cstr_like(plugin, orig_val, allocator);
    }
    if (CFStringCompare(key, CFSTR("name"), 0) == kCFCompareEqualTo ||
        CFStringCompare(key, CFSTR("IOClass"), 0) == kCFCompareEqualTo ||
        CFStringCompare(key, CFSTR("CFBundleIdentifier"), 0) == kCFCompareEqualTo) {
        if (CFGetTypeID(orig_val) == CFDataGetTypeID()) {
            CFDataRef sanitized_data = pt_sanitize_io_nul_delimited_bytes(
                CFDataGetBytePtr((CFDataRef)orig_val),
                (size_t)CFDataGetLength((CFDataRef)orig_val),
                allocator);
            if (sanitized_data != NULL) {
                return sanitized_data;
            }
            return NULL;
        }
        char buf[256] = {0};
        BOOL extracted = NO;
        if (CFGetTypeID(orig_val) == CFStringGetTypeID()) {
            extracted = CFStringGetCString((CFStringRef)orig_val, buf, (CFIndex)sizeof(buf), kCFStringEncodingUTF8) ? YES : NO;
        }
        if (extracted && buf[0] != '\0') {
            char orig_copy[256];
            strlcpy(orig_copy, buf, sizeof(orig_copy));
            if (CFStringCompare(key, CFSTR("IOClass"), 0) == kCFCompareEqualTo) {
                if (strncmp(buf, "AppleACPI", 9) == 0) {
                    strlcpy(buf, "AppleARMPE", sizeof(buf));
                } else if (pt_is_hidden_io_class_or_name(buf, NULL)) {
                    strlcpy(buf, "IOService", sizeof(buf));
                } else {
                    pt_sanitize_io_hardware_name(buf, sizeof(buf));
                }
            } else if (CFStringCompare(key, CFSTR("CFBundleIdentifier"), 0) == kCFCompareEqualTo) {
                if (strstr(buf, "Mac") != NULL ||
                    strstr(buf, "AppleACPI") != NULL ||
                    strstr(buf, "AppleSMC") != NULL ||
                    strstr(buf, "Thunderbolt") != NULL ||
                    strcasestr(buf, "PlayCover") != NULL ||
                    strcasestr(buf, "MacOver") != NULL ||
                    strcasestr(buf, "PlayTools") != NULL) {
                    strlcpy(buf, "com.apple.driver.AppleARMPlatform", sizeof(buf));
                } else {
                    pt_sanitize_io_hardware_name(buf, sizeof(buf));
                }
            } else {
                if (strncmp(buf, "Mac", 3) == 0 || strstr(buf, "MacBook") != NULL || strstr(buf, "iMac") != NULL) {
                    strlcpy(buf, profile->model, sizeof(buf));
                } else if (pt_is_hidden_io_class_or_name(NULL, buf)) {
                    strlcpy(buf, "IOService", sizeof(buf));
                } else {
                    pt_sanitize_io_hardware_name(buf, sizeof(buf));
                }
            }
            if (strcmp(buf, orig_copy) != 0) {
                return pt_create_ioreg_cstr_like(buf, orig_val, allocator);
            }
        }
        return NULL;
    }
    return NULL;
}

CFTypeRef IORegistryEntryCreateCFProperty(mach_port_t entry, CFStringRef key, CFAllocatorRef allocator, uint32_t options) CF_RETURNS_RETAINED;
static CFTypeRef pt_IORegistryEntryCreateCFProperty(mach_port_t entry, CFStringRef key, CFAllocatorRef allocator, uint32_t options) CF_RETURNS_RETAINED {
    if (entry == MACH_PORT_NULL) {
        return NULL;
    }
    BOOL app_caller = (pt_is_bypass_enabled() &&
                       !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    if (key != NULL && app_caller && pt_is_blocked_ioreg_key(key)) {
        return NULL;
    }
    CFTypeRef orig = IORegistryEntryCreateCFProperty(entry, key, allocator, options);
    if (orig != NULL && app_caller) {
        if (key != NULL && pt_is_spoofed_ioreg_key(key)) {
            CFTypeRef spoofed = pt_spoof_ioreg_value_for_key(key, orig, allocator);
            if (spoofed != NULL) {
                CFRelease(orig);
                return spoofed;
            }
        }
        CFTypeRef sanitized = pt_create_sanitized_ioreg_cfvalue_if_changed(orig, allocator, 0);
        if (sanitized != NULL) {
            CFRelease(orig);
            return sanitized;
        }
    }
    return orig;
}

CFTypeRef IORegistryEntrySearchCFProperty(mach_port_t entry, const char *plane, CFStringRef key, CFAllocatorRef allocator, uint32_t options) CF_RETURNS_RETAINED;
static CFTypeRef pt_IORegistryEntrySearchCFProperty(mach_port_t entry, const char *plane, CFStringRef key, CFAllocatorRef allocator, uint32_t options) CF_RETURNS_RETAINED {
    if (entry == MACH_PORT_NULL) {
        return NULL;
    }
    BOOL app_caller = (pt_is_bypass_enabled() &&
                       !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    if (key != NULL && app_caller && pt_is_blocked_ioreg_key(key)) {
        return NULL;
    }
    CFTypeRef orig = IORegistryEntrySearchCFProperty(entry, plane, key, allocator, options);
    if (orig != NULL && app_caller) {
        if (key != NULL && pt_is_spoofed_ioreg_key(key)) {
            CFTypeRef spoofed = pt_spoof_ioreg_value_for_key(key, orig, allocator);
            if (spoofed != NULL) {
                CFRelease(orig);
                return spoofed;
            }
        }
        CFTypeRef sanitized = pt_create_sanitized_ioreg_cfvalue_if_changed(orig, allocator, 0);
        if (sanitized != NULL) {
            CFRelease(orig);
            return sanitized;
        }
    }
    return orig;
}

static void pt_sanitize_ioreg_cfproperties_dict(NSMutableDictionary *dict, CFAllocatorRef allocator) {
    if (dict == nil) {
        return;
    }
    for (NSString *k in pt_blocked_ioreg_keys_list()) {
        [dict removeObjectForKey:k];
    }
    for (NSString *k in pt_spoofed_ioreg_keys_list()) {
        id cur = dict[k];
        if (cur != nil) {
            CFTypeRef repl = pt_spoof_ioreg_value_for_key((__bridge CFStringRef)k, (__bridge CFTypeRef)cur, allocator);
            if (repl != NULL) {
                dict[k] = (__bridge_transfer id)repl;
            }
        }
    }
    NSArray *remainingKeys = [dict allKeys];
    for (id keyObj in remainingKeys) {
        if (![keyObj isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *keyStr = (NSString *)keyObj;
        id cur = dict[keyStr];
        CFTypeRef repl = pt_create_sanitized_ioreg_cfvalue_if_changed((__bridge CFTypeRef)cur, allocator, 1);
        if (repl != NULL) {
            dict[keyStr] = (__bridge_transfer id)repl;
        }
    }
}

kern_return_t IORegistryEntryCreateCFProperties(mach_port_t entry, CFMutableDictionaryRef *properties, CFAllocatorRef allocator, uint32_t options);
static kern_return_t pt_IORegistryEntryCreateCFProperties(mach_port_t entry, CFMutableDictionaryRef *properties, CFAllocatorRef allocator, uint32_t options) {
    if (entry == MACH_PORT_NULL) {
        return KERN_INVALID_ARGUMENT;
    }
    kern_return_t kr = IORegistryEntryCreateCFProperties(entry, properties, allocator, options);
    if (kr == KERN_SUCCESS && properties != NULL && *properties != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        pt_sanitize_ioreg_cfproperties_dict((__bridge NSMutableDictionary *)(*properties), allocator);
    }
    return kr;
}

static BOOL pt_is_hidden_io_path(const char *path) {
    if (path == NULL || path[0] == '\0') {
        return NO;
    }
    if (strstr(path, "AppleACPIPlatformExpert") != NULL ||
        strstr(path, "AppleSMC") != NULL ||
        strstr(path, "Mac") != NULL) {
        return YES;
    }
    const char *p = path;
    while (*p != '\0') {
        while (*p == '/' || *p == ':') {
            p++;
        }
        if (*p == '\0') {
            break;
        }
        const char *seg_start = p;
        while (*p != '\0' && *p != '/' && *p != ':') {
            p++;
        }
        const char *seg_end = p;
        const char *at = memchr(seg_start, '@', (size_t)(seg_end - seg_start));
        if (at != NULL) {
            seg_end = at;
        }
        size_t seg_len = (size_t)(seg_end - seg_start);
        if (seg_len > 0 && seg_len < 128U) {
            char comp[128];
            memcpy(comp, seg_start, seg_len);
            comp[seg_len] = '\0';
            if (pt_is_hidden_io_class_or_name(comp, comp)) {
                return YES;
            }
        }
    }
    return NO;
}

static void pt_format_hidden_io_plane_path(const char *plane, char *out_buf, size_t out_size) {
    if (out_buf == NULL || out_size == 0) {
        return;
    }
    if (plane != NULL && strcmp(plane, "IODeviceTree") == 0) {
        strlcpy(out_buf, "IODeviceTree:/arm-io", out_size);
    } else if (plane != NULL && plane[0] != '\0') {
        snprintf(out_buf, out_size, "%s:/AppleARMPE", plane);
    } else {
        strlcpy(out_buf, "IOService:/AppleARMPE", out_size);
    }
}

extern kern_return_t IORegistryEntryGetPath(mach_port_t entry, const char *plane, char *path);
static kern_return_t pt_IORegistryEntryGetPath(mach_port_t entry, const char *plane, char *path) {
    kern_return_t kr = IORegistryEntryGetPath(entry, plane, path);
    if (kr == KERN_SUCCESS && path != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_is_hidden_io_path(path)) {
            pt_format_hidden_io_plane_path(plane, path, 512U);
        } else {
            pt_sanitize_io_hardware_name(path, 512U);
        }
    }
    return kr;
}

static BOOL pt_is_blocked_ioservice_matching(CFDictionaryRef matching) {
    if (matching == NULL || CFGetTypeID(matching) != CFDictionaryGetTypeID()) {
        return NO;
    }
    NSDictionary *dict = (__bridge NSDictionary *)matching;
    id prov = dict[@"IOProviderClass"];
    if ([prov isKindOfClass:[NSString class]]) {
        const char *pc = [(NSString *)prov UTF8String];
        if (pc != NULL && pt_is_hidden_io_class_or_name(pc, pc)) {
            return YES;
        }
    }
    id nameMatch = dict[@"IONameMatch"];
    if ([nameMatch isKindOfClass:[NSString class]]) {
        const char *nc = [(NSString *)nameMatch UTF8String];
        if (nc != NULL && pt_is_hidden_io_class_or_name(nc, nc)) {
            return YES;
        }
    } else if ([nameMatch isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)nameMatch) {
            if ([item isKindOfClass:[NSString class]]) {
                const char *ic = [(NSString *)item UTF8String];
                if (ic != NULL && pt_is_hidden_io_class_or_name(ic, ic)) {
                    return YES;
                }
            }
        }
    }
    return NO;
}

static BOOL pt_io_entry_is_hidden(io_registry_entry_t entry);

extern mach_port_t IOServiceGetMatchingService(mach_port_t mainPort, CFDictionaryRef matching);
static mach_port_t pt_IOServiceGetMatchingService(mach_port_t mainPort, CFDictionaryRef matching) {
    BOOL app_caller = (pt_is_bypass_enabled() &&
                       !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    if (matching != NULL && app_caller && pt_is_blocked_ioservice_matching(matching)) {
        CFRelease(matching);
        return MACH_PORT_NULL;
    }
    mach_port_t entry = IOServiceGetMatchingService(mainPort, matching);
    if (app_caller && entry != MACH_PORT_NULL) {
        BOOL hide = pt_io_entry_is_hidden(entry);
        if (!hide) {
            io_string_t path = {0};
            if (IORegistryEntryGetPath(entry, "IOService", path) == KERN_SUCCESS && pt_is_hidden_io_path(path)) {
                hide = YES;
            }
        }
        if (hide) {
            IOObjectRelease(entry);
            return MACH_PORT_NULL;
        }
    }
    return entry;
}

extern kern_return_t IOServiceGetMatchingServices(mach_port_t mainPort, CFDictionaryRef matching, uint32_t *existing);
static kern_return_t pt_IOServiceGetMatchingServices(mach_port_t mainPort, CFDictionaryRef matching, uint32_t *existing) {
    if (matching != NULL && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_blocked_ioservice_matching(matching)) {
        CFRelease(matching);
        if (existing != NULL) {
            *existing = MACH_PORT_NULL;
        }
        return KERN_SUCCESS;
    }
    return IOServiceGetMatchingServices(mainPort, matching, existing);
}

__attribute__((visibility("hidden"))) BOOL pt_is_hidden_io_class_or_name(const char *cls_name, const char *entry_name) {
    const char *names[2] = { cls_name, entry_name };
    for (int i = 0; i < 2; i++) {
        const char *s = names[i];
        if (s == NULL || s[0] == '\0') {
            continue;
        }
        if (strstr(s, "Mac") != NULL ||
            strncmp(s, "AppleSMC", 8) == 0 ||
            strncmp(s, "AppleACPI", 9) == 0 ||
            strncmp(s, "AppleSMBus", 10) == 0 ||
            strncmp(s, "IOThunderbolt", 13) == 0 ||
            strncmp(s, "AppleThunderbolt", 16) == 0 ||
            strncmp(s, "AppleUSB4", 9) == 0 ||
            strstr(s, "USB4") != NULL ||
            strncmp(s, "IOPortTransport", 15) == 0 ||
            strncmp(s, "AppleHPM", 8) == 0 ||
            strstr(s, "TCON") != NULL ||
            strstr(s, "DisplayConnection") != NULL ||
            strstr(s, "EndpointSecurity") != NULL ||
            strcmp(s, "IOBluetoothACPIMethods") == 0 ||
            strcmp(s, "AppleMultitouchTrackpadHIDEventDriver") == 0 ||
            strcmp(s, "AppleActuatorHIDEventDriver") == 0 ||
            strcmp(s, "AppleHIDKeyboardEventDriverV2") == 0 ||
            strncmp(s, "AppleHIDTransport", 17) == 0 ||
            strstr(s, "ATCDPXBAR") != NULL ||
            strstr(s, "AppleParadeDP855TCON") != NULL ||
            strstr(s, "AppleATCDPAltModePort") != NULL ||
            strstr(s, "AppleATCDPINAdapterPort") != NULL ||
            strstr(s, "AppleDisplayCrossbar") != NULL ||
            strcmp(s, "IOHIDSystem") == 0 ||
            strncmp(s, "AppleAuthCPDock", 15) == 0 ||
            strncmp(s, "AppleExternalSecondaryAudio", 27) == 0 ||
            strncmp(s, "AppleSmartBattery", 17) == 0 ||
            strcmp(s, "AppleBacklightDisplay") == 0 ||
            strcmp(s, "IODisplayWrangler") == 0 ||
            strcmp(s, "AGPM") == 0) {
            return YES;
        }
    }
    return NO;
}

__attribute__((visibility("hidden"))) void pt_sanitize_io_hardware_name(char *buf, size_t cap) {
    if (buf == NULL || cap == 0 || buf[0] == '\0') {
        return;
    }
    const pt_device_profile_t *profile = pt_get_active_device_profile();
    pt_sanitize_io_hardware_name_cstr(
        buf,
        cap,
        (profile != NULL) ? profile->soc_code : NULL,
        (profile != NULL) ? profile->gpu_gen : NULL,
        (profile != NULL) ? profile->oem_id : NULL,
        (profile != NULL) ? profile->gpu_arch : NULL,
        pt_is_compat13_7_active() ? true : false
    );
}

static BOOL pt_sanitize_io_cstr_token_inplace(char *tok, size_t cap) {
    if (tok == NULL || cap == 0 || tok[0] == '\0') {
        return NO;
    }
    char orig[512];
    strlcpy(orig, tok, sizeof(orig));
    if (strncmp(tok, "AppleACPI", 9) == 0) {
        strlcpy(tok, "AppleARMPE", cap);
    } else if (strstr(tok, "Mac") != NULL || strstr(tok, "AppleSMC") != NULL ||
               strstr(tok, "Thunderbolt") != NULL || strcasestr(tok, "PlayTools") != NULL ||
               strcasestr(tok, "PlayCover") != NULL || strcasestr(tok, "MacOver") != NULL) {
        strlcpy(tok, pt_get_active_device_profile()->model, cap);
    } else if (pt_is_hidden_io_class_or_name(tok, tok)) {
        strlcpy(tok, "IOService", cap);
    } else {
        pt_sanitize_io_hardware_name(tok, cap);
    }
    return (strcmp(tok, orig) != 0);
}

__attribute__((visibility("hidden"))) CFDataRef pt_sanitize_io_nul_delimited_bytes(const uint8_t *src, size_t src_len, CFAllocatorRef allocator) CF_RETURNS_RETAINED {
    if (src == NULL || src_len == 0 || src_len > 8192U) {
        return NULL;
    }
    size_t printable_cnt = 0;
    for (size_t i = 0; i < src_len; i++) {
        uint8_t c = src[i];
        if (c == '\0' || (c >= 0x20 && c < 0x7F)) {
            printable_cnt++;
        } else {
            return NULL;
        }
    }
    if (printable_cnt != src_len) {
        return NULL;
    }
    CFMutableDataRef out = CFDataCreateMutable(allocator, (CFIndex)src_len);
    if (out == NULL) {
        return NULL;
    }
    BOOL modified = NO;
    size_t pos = 0;
    while (pos < src_len) {
        if (src[pos] == '\0') {
            uint8_t zero = 0;
            CFDataAppendBytes(out, &zero, 1);
            pos++;
            continue;
        }
        size_t end = pos;
        while (end < src_len && src[end] != '\0') {
            end++;
        }
        size_t tlen = end - pos;
        char tok[512];
        size_t cpy = (tlen < sizeof(tok) - 1U) ? tlen : (sizeof(tok) - 1U);
        memcpy(tok, src + pos, cpy);
        tok[cpy] = '\0';
        if (pt_sanitize_io_cstr_token_inplace(tok, sizeof(tok))) {
            modified = YES;
        }
        CFDataAppendBytes(out, (const UInt8 *)tok, (CFIndex)strlen(tok));
        if (end < src_len && src[end] == '\0') {
            uint8_t zero = 0;
            CFDataAppendBytes(out, &zero, 1);
            pos = end + 1U;
        } else {
            pos = end;
        }
    }
    if (!modified) {
        CFRelease(out);
        return NULL;
    }
    return out;
}

static CFTypeRef pt_create_sanitized_ioreg_cfvalue_if_changed(CFTypeRef val, CFAllocatorRef allocator, int depth) CF_RETURNS_RETAINED {
    if (val == NULL || depth > 8) {
        return NULL;
    }
    CFTypeID tid = CFGetTypeID(val);
    if (tid == CFStringGetTypeID()) {
        const char *raw = [(__bridge NSString *)val UTF8String];
        if (raw == NULL || raw[0] == '\0') {
            return NULL;
        }
        char buf[512];
        strlcpy(buf, raw, sizeof(buf));
        char orig[512];
        strlcpy(orig, buf, sizeof(orig));
        if (strcmp(buf, "macOS") == 0) {
            strlcpy(buf, "iPhone OS", sizeof(buf));
        } else if (strstr(buf, "Mac") != NULL ||
                   strstr(buf, "AppleACPI") != NULL ||
                   strstr(buf, "AppleSMC") != NULL ||
                   strstr(buf, "Thunderbolt") != NULL) {
            strlcpy(buf, pt_get_active_device_profile()->model, sizeof(buf));
        } else {
            pt_sanitize_io_hardware_name(buf, sizeof(buf));
        }
        if (strcmp(buf, orig) != 0) {
            return CFStringCreateWithCString(allocator, buf, kCFStringEncodingUTF8);
        }
        return NULL;
    }
    if (tid == CFDataGetTypeID()) {
        CFIndex dlen = CFDataGetLength((CFDataRef)val);
        if (dlen > 0 && dlen <= 8192) {
            return pt_sanitize_io_nul_delimited_bytes(
                CFDataGetBytePtr((CFDataRef)val), (size_t)dlen, allocator);
        }
        return NULL;
    }
    if (tid == CFDictionaryGetTypeID()) {
        NSDictionary *dict = (__bridge NSDictionary *)val;
        NSMutableDictionary *mut = nil;
        NSArray *keys = [dict allKeys];
        for (id keyObj in keys) {
            if (![keyObj isKindOfClass:[NSString class]]) {
                continue;
            }
            NSString *keyStr = (NSString *)keyObj;
            CFStringRef kcf = (__bridge CFStringRef)keyStr;
            if (pt_is_blocked_ioreg_key(kcf)) {
                if (mut == nil) mut = [dict mutableCopy];
                [mut removeObjectForKey:keyStr];
                continue;
            }
            id curVal = dict[keyStr];
            if (curVal == nil) {
                continue;
            }
            if (pt_is_spoofed_ioreg_key(kcf)) {
                CFTypeRef sp = pt_spoof_ioreg_value_for_key(kcf, (__bridge CFTypeRef)curVal, allocator);
                if (sp != NULL) {
                    if (mut == nil) mut = [dict mutableCopy];
                    mut[keyStr] = (__bridge_transfer id)sp;
                    continue;
                }
            }
            CFTypeRef childRepl = pt_create_sanitized_ioreg_cfvalue_if_changed(
                (__bridge CFTypeRef)curVal, allocator, depth + 1);
            if (childRepl != NULL) {
                if (mut == nil) mut = [dict mutableCopy];
                mut[keyStr] = (__bridge_transfer id)childRepl;
            }
        }
        return (mut != nil) ? CFBridgingRetain([mut copy]) : NULL;
    }
    if (tid == CFArrayGetTypeID()) {
        NSArray *arr = (__bridge NSArray *)val;
        NSMutableArray *mut = nil;
        for (NSUInteger i = 0; i < arr.count; i++) {
            CFTypeRef childRepl = pt_create_sanitized_ioreg_cfvalue_if_changed(
                (__bridge CFTypeRef)arr[i], allocator, depth + 1);
            if (childRepl != NULL) {
                if (mut == nil) mut = [arr mutableCopy];
                mut[i] = (__bridge_transfer id)childRepl;
            }
        }
        return (mut != nil) ? CFBridgingRetain([mut copy]) : NULL;
    }
    return NULL;
}

static kern_return_t pt_IOObjectGetClass(io_object_t object, io_name_t className) {
    kern_return_t kr = IOObjectGetClass(object, className);
    if (kr == KERN_SUCCESS && className != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (strncmp(className, "AppleACPI", 9) == 0) {
            strlcpy(className, "AppleARMPE", sizeof(io_name_t));
        } else if (pt_is_hidden_io_class_or_name(className, NULL)) {
            strlcpy(className, "IOService", sizeof(io_name_t));
        } else {
            pt_sanitize_io_hardware_name(className, sizeof(io_name_t));
        }
    }
    return kr;
}

static boolean_t pt_IOObjectConformsTo(io_object_t object, const io_name_t className) {
    if (className != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_hidden_io_class_or_name(className, NULL)) {
        return FALSE;
    }
    return IOObjectConformsTo(object, className);
}

static kern_return_t pt_IORegistryEntryGetName(io_registry_entry_t entry, io_name_t name) {
    kern_return_t kr = IORegistryEntryGetName(entry, name);
    if (kr == KERN_SUCCESS && name != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_is_hidden_io_class_or_name(NULL, name)) {
            strlcpy(name, "IOService", sizeof(io_name_t));
        } else {
            pt_sanitize_io_hardware_name(name, sizeof(io_name_t));
        }
    }
    return kr;
}

static kern_return_t pt_IORegistryEntryGetNameInPlane(io_registry_entry_t entry,
                                                     const io_name_t plane,
                                                     io_name_t name) {
    kern_return_t kr = IORegistryEntryGetNameInPlane(entry, plane, name);
    if (kr == KERN_SUCCESS && name != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_is_hidden_io_class_or_name(NULL, name)) {
            strlcpy(name, "IOService", sizeof(io_name_t));
        } else {
            pt_sanitize_io_hardware_name(name, sizeof(io_name_t));
        }
    }
    return kr;
}

static CFStringRef pt_sanitize_io_class_cfstring(CFStringRef orig, CFAllocatorRef allocator) CF_RETURNS_RETAINED {
    if (orig == NULL) {
        return NULL;
    }
    char buf[256] = {0};
    if (!CFStringGetCString(orig, buf, (CFIndex)sizeof(buf), kCFStringEncodingUTF8)) {
        return orig;
    }
    char orig_copy[256];
    strlcpy(orig_copy, buf, sizeof(orig_copy));
    if (strncmp(buf, "AppleACPI", 9) == 0) {
        strlcpy(buf, "AppleARMPE", sizeof(buf));
    } else if (pt_is_hidden_io_class_or_name(buf, NULL)) {
        strlcpy(buf, "IOService", sizeof(buf));
    } else {
        pt_sanitize_io_hardware_name(buf, sizeof(buf));
    }
    if (strcmp(buf, orig_copy) != 0) {
        CFStringRef repl = CFStringCreateWithCString(allocator, buf, kCFStringEncodingUTF8);
        if (repl != NULL) {
            CFRelease(orig);
            return repl;
        }
    }
    return orig;
}

static CFStringRef pt_IOObjectCopyClass(io_object_t object) CF_RETURNS_RETAINED {
    CFStringRef cls = IOObjectCopyClass(object);
    if (cls != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return pt_sanitize_io_class_cfstring(cls, kCFAllocatorDefault);
    }
    return cls;
}

static CFStringRef pt_IOObjectCopySuperclassForClass(CFStringRef classname) CF_RETURNS_RETAINED {
    BOOL filter = (pt_is_bypass_enabled() &&
                   !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    if (filter && classname != NULL) {
        char req[256] = {0};
        if (CFStringGetCString(classname, req, (CFIndex)sizeof(req), kCFStringEncodingUTF8) &&
            pt_is_hidden_io_class_or_name(req, NULL)) {
            return NULL;
        }
    }
    CFStringRef sup = IOObjectCopySuperclassForClass(classname);
    if (filter && sup != NULL) {
        return pt_sanitize_io_class_cfstring(sup, kCFAllocatorDefault);
    }
    return sup;
}

static CFStringRef pt_IOObjectCopyBundleIdentifierForClass(CFStringRef classname) CF_RETURNS_RETAINED {
    BOOL filter = (pt_is_bypass_enabled() &&
                   !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    if (filter && classname != NULL) {
        char req[256] = {0};
        if (CFStringGetCString(classname, req, (CFIndex)sizeof(req), kCFStringEncodingUTF8) &&
            pt_is_hidden_io_class_or_name(req, NULL)) {
            return NULL;
        }
    }
    CFStringRef bid = IOObjectCopyBundleIdentifierForClass(classname);
    if (filter && bid != NULL) {
        char buf[256] = {0};
        if (CFStringGetCString(bid, buf, (CFIndex)sizeof(buf), kCFStringEncodingUTF8)) {
            char orig_copy[256];
            strlcpy(orig_copy, buf, sizeof(orig_copy));
            if (strstr(buf, "Mac") != NULL ||
                strstr(buf, "AppleACPI") != NULL ||
                strstr(buf, "AppleSMC") != NULL ||
                strstr(buf, "Thunderbolt") != NULL ||
                strcasestr(buf, "PlayCover") != NULL ||
                strcasestr(buf, "MacOver") != NULL ||
                strcasestr(buf, "PlayTools") != NULL) {
                strlcpy(buf, "com.apple.driver.AppleARMPlatform", sizeof(buf));
            } else {
                pt_sanitize_io_hardware_name(buf, sizeof(buf));
            }
            if (strcmp(buf, orig_copy) != 0) {
                CFStringRef repl = CFStringCreateWithCString(kCFAllocatorDefault, buf, kCFStringEncodingUTF8);
                if (repl != NULL) {
                    CFRelease(bid);
                    return repl;
                }
            }
        }
    }
    return bid;
}

extern kern_return_t pt_orig_IORegistryEntryGetProperty(io_registry_entry_t entry,
                                                       const io_name_t propertyName,
                                                       io_struct_inband_t buffer,
                                                       uint32_t *size)
    __asm("_IORegistryEntryGetProperty") __attribute__((weak_import));

static kern_return_t pt_IORegistryEntryGetProperty(io_registry_entry_t entry,
                                                   const io_name_t propertyName,
                                                   io_struct_inband_t buffer,
                                                   uint32_t *size) {
    if (&pt_orig_IORegistryEntryGetProperty == NULL) {
        return kIOReturnUnsupported;
    }
    BOOL filter = (pt_is_bypass_enabled() &&
                   !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    CFStringRef key = NULL;
    if (filter && propertyName != NULL) {
        key = CFStringCreateWithCString(kCFAllocatorDefault, propertyName, kCFStringEncodingUTF8);
        if (key != NULL && pt_is_blocked_ioreg_key(key)) {
            CFRelease(key);
            return kIOReturnNotFound;
        }
    }
    uint32_t cap = (size != NULL) ? *size : 0U;
    kern_return_t kr = pt_orig_IORegistryEntryGetProperty(entry, propertyName, buffer, size);
    if (filter && kr == KERN_SUCCESS && buffer != NULL && size != NULL && *size > 0U && cap > 0U) {
        uint32_t cur_len = (*size <= cap) ? *size : cap;
        CFDataRef replData = NULL;
        if (key != NULL && pt_is_spoofed_ioreg_key(key)) {
            CFDataRef raw = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault,
                                                        (const UInt8 *)buffer,
                                                        (CFIndex)cur_len,
                                                        kCFAllocatorNull);
            if (raw != NULL) {
                CFTypeRef spoofed = pt_spoof_ioreg_value_for_key(key, raw, kCFAllocatorDefault);
                CFRelease(raw);
                if (spoofed != NULL) {
                    if (CFGetTypeID(spoofed) == CFDataGetTypeID()) {
                        replData = (CFDataRef)spoofed;
                    } else if (CFGetTypeID(spoofed) == CFStringGetTypeID()) {
                        char sbuf[512] = {0};
                        if (CFStringGetCString((CFStringRef)spoofed, sbuf, (CFIndex)sizeof(sbuf), kCFStringEncodingUTF8)) {
                            replData = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)sbuf, (CFIndex)(strlen(sbuf) + 1U));
                        }
                        CFRelease(spoofed);
                    } else {
                        CFRelease(spoofed);
                    }
                }
            }
        } else {
            replData = pt_sanitize_io_nul_delimited_bytes((const uint8_t *)buffer, (size_t)cur_len, kCFAllocatorDefault);
        }
        if (replData != NULL) {
            CFIndex rlen = CFDataGetLength(replData);
            if (rlen > 0 && (uint32_t)rlen <= cap) {
                memcpy(buffer, CFDataGetBytePtr(replData), (size_t)rlen);
                *size = (uint32_t)rlen;
            } else if ((uint32_t)rlen > cap) {
                memset(buffer, 0, cap);
                *size = (uint32_t)rlen;
                CFRelease(replData);
                if (key != NULL) {
                    CFRelease(key);
                }
                return kIOReturnNoSpace;
            }
            CFRelease(replData);
        }
    }
    if (key != NULL) {
        CFRelease(key);
    }
    return kr;
}

static CFStringRef pt_IORegistryEntryCopyPath(io_registry_entry_t entry, const io_name_t plane) CF_RETURNS_RETAINED {
    CFStringRef path = IORegistryEntryCopyPath(entry, plane);
    if (path != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        char buf[512] = {0};
        if (CFStringGetCString(path, buf, (CFIndex)sizeof(buf), kCFStringEncodingUTF8)) {
            char orig[512];
            strlcpy(orig, buf, sizeof(orig));
            if (pt_is_hidden_io_path(buf)) {
                pt_format_hidden_io_plane_path(plane, buf, sizeof(buf));
            } else {
                pt_sanitize_io_hardware_name(buf, sizeof(buf));
            }
            if (strcmp(buf, orig) != 0) {
                CFStringRef repl = CFStringCreateWithCString(kCFAllocatorDefault, buf, kCFStringEncodingUTF8);
                if (repl != NULL) {
                    CFRelease(path);
                    return repl;
                }
            }
        }
    }
    return path;
}

static io_registry_entry_t pt_IORegistryEntryCopyFromPath(mach_port_t mainPort, CFStringRef path) {
    BOOL filter = (pt_is_bypass_enabled() &&
                   !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    if (filter && path != NULL) {
        char cpath[512] = {0};
        if (CFStringGetCString(path, cpath, (CFIndex)sizeof(cpath), kCFStringEncodingUTF8) &&
            pt_is_hidden_io_path(cpath)) {
            return MACH_PORT_NULL;
        }
    }
    io_registry_entry_t entry = IORegistryEntryCopyFromPath(mainPort, path);
    if (filter && entry != MACH_PORT_NULL) {
        io_name_t cls = {0};
        io_name_t name = {0};
        (void)IOObjectGetClass(entry, cls);
        (void)IORegistryEntryGetName(entry, name);
        if (pt_is_hidden_io_class_or_name(cls, name)) {
            IOObjectRelease(entry);
            return MACH_PORT_NULL;
        }
    }
    return entry;
}

static io_object_t pt_IOIteratorNext(io_iterator_t iterator) {
    if (!pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return IOIteratorNext(iterator);
    }
    for (int guard = 0; guard < 16384; guard++) {
        io_object_t obj = IOIteratorNext(iterator);
        if (obj == MACH_PORT_NULL) {
            return MACH_PORT_NULL;
        }
        io_name_t cls = {0};
        io_name_t name = {0};
        (void)IOObjectGetClass(obj, cls);
        (void)IORegistryEntryGetName(obj, name);
        if (pt_is_hidden_io_class_or_name(cls, name)) {
            IOObjectRelease(obj);
            continue;
        }
        return obj;
    }
    return MACH_PORT_NULL;
}

static BOOL pt_io_entry_is_hidden(io_registry_entry_t entry) {
    if (entry == MACH_PORT_NULL) {
        return NO;
    }
    io_name_t cls = {0};
    io_name_t name = {0};
    (void)IOObjectGetClass(entry, cls);
    (void)IORegistryEntryGetName(entry, name);
    return pt_is_hidden_io_class_or_name(cls, name);
}

static io_registry_entry_t pt_IORegistryEntryFromPath(mach_port_t mainPort, const io_string_t path) {
    BOOL filter = (pt_is_bypass_enabled() &&
                   !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    if (filter && path != NULL && pt_is_hidden_io_path(path)) {
        return MACH_PORT_NULL;
    }
    io_registry_entry_t entry = IORegistryEntryFromPath(mainPort, path);
    if (filter && entry != MACH_PORT_NULL && pt_io_entry_is_hidden(entry)) {
        IOObjectRelease(entry);
        return MACH_PORT_NULL;
    }
    return entry;
}

static kern_return_t pt_IORegistryEntryGetChildEntry(io_registry_entry_t entry,
                                                     const io_name_t plane,
                                                     io_registry_entry_t *child) {
    kern_return_t kr = IORegistryEntryGetChildEntry(entry, plane, child);
    if (kr == KERN_SUCCESS && child != NULL && *child != MACH_PORT_NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_io_entry_is_hidden(*child)) {
        IOObjectRelease(*child);
        *child = MACH_PORT_NULL;
        io_iterator_t iter = MACH_PORT_NULL;
        if (IORegistryEntryGetChildIterator(entry, plane, &iter) == KERN_SUCCESS && iter != MACH_PORT_NULL) {
            for (int guard = 0; guard < 1024; guard++) {
                io_object_t next = IOIteratorNext(iter);
                if (next == MACH_PORT_NULL) {
                    break;
                }
                if (!pt_io_entry_is_hidden(next)) {
                    *child = next;
                    IOObjectRelease(iter);
                    return KERN_SUCCESS;
                }
                IOObjectRelease(next);
            }
            IOObjectRelease(iter);
        }
        return kIOReturnNoDevice;
    }
    return kr;
}

static kern_return_t pt_IORegistryEntryGetParentEntry(io_registry_entry_t entry,
                                                      const io_name_t plane,
                                                      io_registry_entry_t *parent) {
    kern_return_t kr = IORegistryEntryGetParentEntry(entry, plane, parent);
    if (kr == KERN_SUCCESS && parent != NULL && *parent != MACH_PORT_NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_io_entry_is_hidden(*parent)) {
        io_registry_entry_t cur = *parent;
        *parent = MACH_PORT_NULL;
        for (int guard = 0; guard < 32; guard++) {
            io_registry_entry_t up = MACH_PORT_NULL;
            kern_return_t ukr = IORegistryEntryGetParentEntry(cur, plane, &up);
            IOObjectRelease(cur);
            if (ukr != KERN_SUCCESS || up == MACH_PORT_NULL) {
                return kIOReturnNoDevice;
            }
            if (!pt_io_entry_is_hidden(up)) {
                *parent = up;
                return KERN_SUCCESS;
            }
            cur = up;
        }
        IOObjectRelease(cur);
        return kIOReturnNoDevice;
    }
    return kr;
}

__attribute__((visibility("hidden"))) BOOL pt_is_hidden_audio_component(AudioComponent comp) {
    if (comp == NULL) {
        return NO;
    }
    AudioComponentDescription desc;
    memset(&desc, 0, sizeof(desc));
    if (AudioComponentGetDescription(comp, &desc) != noErr) {
        return NO;
    }
    if (desc.componentManufacturer != 'appl') {
        return YES;
    }
    switch (desc.componentType) {
        case 'auou':
            return (desc.componentSubType == 'ahal' ||
                    desc.componentSubType == 'def ' ||
                    desc.componentSubType == 'sys ' ||
                    desc.componentSubType == 'atap');
        case 'aumu':
            return (desc.componentSubType == 'dls ');
        case 'augn':
            return (desc.componentSubType == 'nrcv' ||
                    desc.componentSubType == 'ttsp');
        case 'aufx':
            return (desc.componentSubType == 'nsnd' ||
                    desc.componentSubType == 'sdly');
        case 'ausp':
            return (desc.componentSubType == 'mctk');
        case 'aupn':
            return YES;
        case 'aumx':
            return (desc.componentSubType == 'smxr' ||
                    desc.componentSubType == '3dmx');
        default:
            return NO;
    }
}

static AudioComponent _Nullable pt_AudioComponentFindNext(
    AudioComponent _Nullable inComponent,
    const AudioComponentDescription * _Nullable inDesc) {
    if (inDesc == NULL) {
        return NULL;
    }
    if (!pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return AudioComponentFindNext(inComponent, inDesc);
    }
    AudioComponent cur = inComponent;
    for (int guard = 0; guard < 4096; guard++) {
        cur = AudioComponentFindNext(cur, inDesc);
        if (cur == NULL) {
            return NULL;
        }
        if (!pt_is_hidden_audio_component(cur)) {
            return cur;
        }
    }
    return NULL;
}

static UInt32 pt_AudioComponentCount(const AudioComponentDescription * _Nullable inDesc) {
    if (inDesc == NULL) {
        return 0;
    }
    if (!pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return AudioComponentCount(inDesc);
    }
    UInt32 count = 0;
    AudioComponent cur = NULL;
    for (UInt32 guard = 0; guard < 4096U; guard++) {
        cur = AudioComponentFindNext(cur, inDesc);
        if (cur == NULL) {
            break;
        }
        if (!pt_is_hidden_audio_component(cur)) {
            count++;
        }
    }
    return count;
}

extern OSStatus pt_orig_AudioComponentInstanceNew(AudioComponent inComponent, AudioComponentInstance _Nullable *outInstance)
    __asm__("_AudioComponentInstanceNew") __attribute__((weak_import));
extern void pt_orig_AudioComponentInstantiate(AudioComponent inComponent,
                                              AudioComponentInstantiationOptions inOptions,
                                              void (^inCompletionHandler)(AudioComponentInstance _Nullable, OSStatus))
    __asm__("_AudioComponentInstantiate") __attribute__((weak_import));

static OSStatus pt_AudioComponentInstanceNew(AudioComponent inComponent, AudioComponentInstance _Nullable *outInstance) {
    if (&pt_orig_AudioComponentInstanceNew == NULL) {
        if (outInstance != NULL) {
            *outInstance = NULL;
        }
        return -3000; // kAudio_ParamError / component not found
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_hidden_audio_component(inComponent)) {
        if (outInstance != NULL) {
            *outInstance = NULL;
        }
        return -3000;
    }
    return pt_orig_AudioComponentInstanceNew(inComponent, outInstance);
}

static void pt_AudioComponentInstantiate(AudioComponent inComponent,
                                         AudioComponentInstantiationOptions inOptions,
                                         void (^inCompletionHandler)(AudioComponentInstance _Nullable, OSStatus)) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_hidden_audio_component(inComponent)) {
        if (inCompletionHandler != nil) {
            inCompletionHandler(NULL, -3000);
        }
        return;
    }
    if (&pt_orig_AudioComponentInstantiate != NULL) {
        pt_orig_AudioComponentInstantiate(inComponent, inOptions, inCompletionHandler);
    } else if (inCompletionHandler != nil) {
        inCompletionHandler(NULL, -3000);
    }
}

static OSStatus pt_AudioUnitGetProperty(AudioUnit inUnit,
                                        AudioUnitPropertyID inID,
                                        AudioUnitScope inScope,
                                        AudioUnitElement inElement,
                                        void *outData,
                                        UInt32 *ioDataSize) {
    if (inID == 2000U &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return (OSStatus)-10879; // kAudioUnitErr_InvalidProperty
    }
    return AudioUnitGetProperty(inUnit, inID, inScope, inElement, outData, ioDataSize);
}

static OSStatus pt_AudioUnitGetPropertyInfo(AudioUnit inUnit,
                                            AudioUnitPropertyID inID,
                                            AudioUnitScope inScope,
                                            AudioUnitElement inElement,
                                            UInt32 *outDataSize,
                                            Boolean *outWritable) {
    if (inID == 2000U &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return (OSStatus)-10879; // kAudioUnitErr_InvalidProperty
    }
    return AudioUnitGetPropertyInfo(inUnit, inID, inScope, inElement, outDataSize, outWritable);
}

typedef NS_ENUM(NSInteger, pt_uttype_bundle_action_t) {
    PT_UTTYPE_BUNDLE_KEEP = 0,
    PT_UTTYPE_BUNDLE_REWRITE_MOBILECORETYPES = 1,
    PT_UTTYPE_BUNDLE_HIDE = 2,
};

static pt_uttype_bundle_action_t pt_classify_uttype_declaring_bundle(CFURLRef url, const void *caller) {
    if (url == NULL) {
        return PT_UTTYPE_BUNDLE_KEEP;
    }
    UInt8 raw[PATH_MAX];
    if (!CFURLGetFileSystemRepresentation(url, true, raw, sizeof(raw))) {
        return PT_UTTYPE_BUNDLE_KEEP;
    }
    const char *p = (const char *)raw;
    if (strncmp(p, "/System/Volumes/Data/", 21) == 0) {
        p += 20;
    }
    pt_ensure_bundle_path_map();
    pt_ensure_data_container_map();
    if ((s_real_app_bundle_len > 0 &&
         pt_match_prefix_modulo_private(p, s_real_app_bundle_dir, s_real_app_bundle_len) != NULL) ||
        (s_real_data_container_len > 0 &&
         pt_match_prefix_modulo_private(p, s_real_data_container_dir, s_real_data_container_len) != NULL)) {
        return PT_UTTYPE_BUNDLE_KEEP;
    }
    if (strcasecmp(p, "/System/Library/CoreServices/CoreTypes.bundle") == 0 ||
        strncasecmp(p, "/System/Library/CoreServices/CoreTypes.bundle/", 46) == 0) {
        return PT_UTTYPE_BUNDLE_REWRITE_MOBILECORETYPES;
    }
    if (strstr(p, "DiskImageMounter.app") != NULL ||
        strstr(p, "Finder.app") != NULL ||
        strncmp(p, "/Applications/", 14) == 0 ||
        strncmp(p, "/System/Applications/", 21) == 0 ||
        strstr(p, "/Applications/") != NULL ||
        (strncmp(p, "/System/Library/CoreServices/", 29) == 0 && strstr(p, ".app") != NULL) ||
        pt_is_hidden_path(p, caller) ||
        pt_is_hidden_dyld_image_name(p)) {
        return PT_UTTYPE_BUNDLE_HIDE;
    }
    return PT_UTTYPE_BUNDLE_KEEP;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static CFURLRef _Nullable pt_UTTypeCopyDeclaringBundleURL(CFStringRef inUTI) CF_RETURNS_RETAINED {
    if (inUTI == NULL) {
        return NULL;
    }
    CFURLRef url = UTTypeCopyDeclaringBundleURL(inUTI);
    const void *caller = __builtin_return_address(0);
    if (url == NULL ||
        !pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(caller)) {
        return url;
    }
    switch (pt_classify_uttype_declaring_bundle(url, caller)) {
        case PT_UTTYPE_BUNDLE_HIDE:
            CFRelease(url);
            return NULL;
        case PT_UTTYPE_BUNDLE_REWRITE_MOBILECORETYPES: {
            static const char kMobileCoreTypes[] = "/System/Library/CoreServices/MobileCoreTypes.bundle";
            CFURLRef mobile = CFURLCreateFromFileSystemRepresentation(
                kCFAllocatorDefault,
                (const UInt8 *)kMobileCoreTypes,
                (CFIndex)(sizeof(kMobileCoreTypes) - 1U),
                true);
            CFRelease(url);
            return mobile;
        }
        case PT_UTTYPE_BUNDLE_KEEP:
        default:
            return pt_sanitize_cfbundle_returned_url(url, caller);
    }
}

static CFDictionaryRef _Nullable pt_UTTypeCopyDeclaration(CFStringRef inUTI) CF_RETURNS_RETAINED {
    if (inUTI == NULL) {
        return NULL;
    }
    CFDictionaryRef decl = UTTypeCopyDeclaration(inUTI);
    const void *caller = __builtin_return_address(0);
    if (decl == NULL ||
        !pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(caller)) {
        return decl;
    }
    CFURLRef bundleURL = UTTypeCopyDeclaringBundleURL(inUTI);
    if (bundleURL != NULL) {
        pt_uttype_bundle_action_t act = pt_classify_uttype_declaring_bundle(bundleURL, caller);
        CFRelease(bundleURL);
        if (act == PT_UTTYPE_BUNDLE_HIDE) {
            CFRelease(decl);
            return NULL;
        }
    }
    return decl;
}

#pragma clang diagnostic pop

__attribute__((visibility("hidden")))
float pt_get_shared_spoofed_battery_level(void) {
    static uint64_t s_start_sec = 0;
    static uint32_t s_seed_pct = 82U;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        struct timespec ts;
        if (clock_gettime(CLOCK_MONOTONIC_RAW, &ts) == 0 && ts.tv_sec > 0) {
            s_start_sec = (uint64_t)ts.tv_sec;
        }
        pt_ensure_bundle_path_map();
        const char *seed = (s_real_app_bundle_len > 0) ? s_real_app_bundle_dir : "playtools";
        uint32_t h = 2166136261U;
        for (const unsigned char *p = (const unsigned char *)seed; *p != '\0'; p++) {
            h ^= (uint32_t)(*p);
            h *= 16777619U;
        }
        s_seed_pct = 76U + (h % 12U);
    });
    uint64_t elapsed_sec = 0;
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &now) == 0 &&
        now.tv_sec > 0 && (uint64_t)now.tv_sec >= s_start_sec) {
        elapsed_sec = (uint64_t)now.tv_sec - s_start_sec;
    }
    uint64_t steps = elapsed_sec / 420ULL;
    const int32_t span = 20; // [68..87] inclusive
    int32_t base_off = (int32_t)(s_seed_pct - 68U);
    int32_t cycle = (int32_t)(steps % (uint64_t)(2 * (span - 1)));
    int32_t pos = base_off - cycle;
    while (pos < 0 || pos >= span) {
        if (pos < 0) {
            pos = -pos;
        }
        if (pos >= span) {
            pos = 2 * (span - 1) - pos;
        }
    }
    int32_t pct = 68 + pos;
    if (pct < 68) pct = 68;
    if (pct > 87) pct = 87;
    return (float)pct / 100.0f;
}

static CFDictionaryRef pt_get_spoofed_iops_battery_dict(void) {
    static os_unfair_lock s_iops_lock = OS_UNFAIR_LOCK_INIT;
    static CFDictionaryRef s_dicts[20] = {0};
    int32_t cur_cap = (int32_t)lroundf(pt_get_shared_spoofed_battery_level() * 100.0f);
    if (cur_cap < 68) cur_cap = 68;
    if (cur_cap > 87) cur_cap = 87;
    size_t idx = (size_t)(cur_cap - 68);
    os_unfair_lock_lock(&s_iops_lock);
    CFDictionaryRef cached = s_dicts[idx];
    os_unfair_lock_unlock(&s_iops_lock);
    if (cached != NULL) {
        return cached;
    }

    int32_t max_cap = 100;
    int32_t neg_one = -1;
    CFNumberRef curNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &cur_cap);
    CFNumberRef maxNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &max_cap);
    CFNumberRef negNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &neg_one);
    const void *keys[] = {
        CFSTR("Name"),
        CFSTR("Type"),
        CFSTR("Transport Type"),
        CFSTR("Is Present"),
        CFSTR("Power Source State"),
        CFSTR("Current Capacity"),
        CFSTR("Max Capacity"),
        CFSTR("Is Charging"),
        CFSTR("Is Charged"),
        CFSTR("Time to Empty"),
        CFSTR("Time to Full Charge"),
    };
    const void *vals[] = {
        CFSTR("InternalBattery-0"),
        CFSTR("InternalBattery"),
        CFSTR("Internal"),
        kCFBooleanTrue,
        CFSTR("Battery Power"),
        curNum,
        maxNum,
        kCFBooleanFalse,
        kCFBooleanFalse,
        negNum,
        negNum,
    };
    CFDictionaryRef built = CFDictionaryCreate(kCFAllocatorDefault,
                                               keys,
                                               vals,
                                               (CFIndex)(sizeof(keys) / sizeof(keys[0])),
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    if (curNum != NULL) CFRelease(curNum);
    if (maxNum != NULL) CFRelease(maxNum);
    if (negNum != NULL) CFRelease(negNum);
    if (built == NULL) {
        return NULL;
    }
    CFDictionaryRef to_release = NULL;
    os_unfair_lock_lock(&s_iops_lock);
    if (s_dicts[idx] == NULL) {
        s_dicts[idx] = built;
        cached = built;
    } else {
        cached = s_dicts[idx];
        to_release = built;
    }
    os_unfair_lock_unlock(&s_iops_lock);
    if (to_release != NULL) {
        CFRelease(to_release);
    }
    return cached;
}

extern CFTypeRef IOPSCopyPowerSourcesInfo(void);
static CFTypeRef pt_IOPSCopyPowerSourcesInfo(void) CF_RETURNS_RETAINED {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        CFDictionaryRef batt = pt_get_spoofed_iops_battery_dict();
        if (batt != NULL) {
            const void *items[1] = { batt };
            return CFArrayCreate(kCFAllocatorDefault, items, 1, &kCFTypeArrayCallBacks);
        }
        return CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
    }
    return IOPSCopyPowerSourcesInfo();
}

extern CFArrayRef IOPSCopyPowerSourcesList(CFTypeRef blob);
static CFArrayRef pt_IOPSCopyPowerSourcesList(CFTypeRef blob) CF_RETURNS_RETAINED {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (blob != NULL && CFGetTypeID(blob) == CFArrayGetTypeID() &&
            CFArrayGetCount((CFArrayRef)blob) > 0) {
            return CFArrayCreateCopy(kCFAllocatorDefault, (CFArrayRef)blob);
        }
        CFDictionaryRef batt = pt_get_spoofed_iops_battery_dict();
        if (batt != NULL) {
            const void *items[1] = { batt };
            return CFArrayCreate(kCFAllocatorDefault, items, 1, &kCFTypeArrayCallBacks);
        }
        return CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
    }
    return IOPSCopyPowerSourcesList(blob);
}

extern CFDictionaryRef IOPSGetPowerSourceDescription(CFTypeRef blob, CFTypeRef ps);
static CFDictionaryRef pt_IOPSGetPowerSourceDescription(CFTypeRef blob, CFTypeRef ps) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (ps != NULL && CFGetTypeID(ps) == CFDictionaryGetTypeID()) {
            return (CFDictionaryRef)ps;
        }
        return pt_get_spoofed_iops_battery_dict();
    }
    return IOPSGetPowerSourceDescription(blob, ps);
}

extern CFStringRef IOPSGetProvidingPowerSourceType(CFTypeRef snapshot);
static CFStringRef pt_IOPSGetProvidingPowerSourceType(CFTypeRef snapshot) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return CFSTR("Battery Power");
    }
    return IOPSGetProvidingPowerSourceType(snapshot);
}

extern CFTimeInterval IOPSGetTimeRemainingEstimate(void);
static CFTimeInterval pt_IOPSGetTimeRemainingEstimate(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return 18000.0;
    }
    return IOPSGetTimeRemainingEstimate();
}

extern Boolean IOPSDrawingUnlimitedPower(void);
static Boolean pt_IOPSDrawingUnlimitedPower(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return false;
    }
    return IOPSDrawingUnlimitedPower();
}

extern CFDictionaryRef IOPSCopyExternalPowerAdapterDetails(void);
static CFDictionaryRef pt_IOPSCopyExternalPowerAdapterDetails(void) CF_RETURNS_RETAINED {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NULL;
    }
    return IOPSCopyExternalPowerAdapterDetails();
}

extern CFArrayRef IOPSCopyPowerSourcesByType(int type);
static CFArrayRef pt_IOPSCopyPowerSourcesByType(int type) CF_RETURNS_RETAINED {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        CFDictionaryRef batt = pt_get_spoofed_iops_battery_dict();
        if (batt != NULL) {
            const void *items[1] = { batt };
            return CFArrayCreate(kCFAllocatorDefault, items, 1, &kCFTypeArrayCallBacks);
        }
        return CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
    }
    return IOPSCopyPowerSourcesByType(type);
}

extern IOReturn pt_orig_IOPSGetPercentRemaining(int *percent, bool *isCharging, bool *isFinisher)
    __asm__("_IOPSGetPercentRemaining") __attribute__((weak_import));
static IOReturn pt_IOPSGetPercentRemaining(int *percent, bool *isCharging, bool *isFinisher) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        int cur_cap = (int)lroundf(pt_get_shared_spoofed_battery_level() * 100.0f);
        if (cur_cap < 68) cur_cap = 68;
        if (cur_cap > 87) cur_cap = 87;
        if (percent != NULL) {
            *percent = cur_cap;
        }
        if (isCharging != NULL) {
            *isCharging = false;
        }
        if (isFinisher != NULL) {
            *isFinisher = false;
        }
        return kIOReturnSuccess;
    }
    if (&pt_orig_IOPSGetPercentRemaining != NULL) {
        return pt_orig_IOPSGetPercentRemaining(percent, isCharging, isFinisher);
    }
    return kIOReturnUnsupported;
}

extern CFTypeRef MGCopyAnswer(CFStringRef question, CFDictionaryRef options) __attribute__((weak_import));
extern CFTypeRef MGCopyAnswerWithError(CFStringRef question, CFDictionaryRef options, int *outError) __attribute__((weak_import));
extern CFDictionaryRef MGCopyMultipleAnswers(CFArrayRef questions, CFDictionaryRef options) __attribute__((weak_import));
extern bool MGGetBoolAnswer(CFStringRef question) __attribute__((weak_import));
extern int32_t MGGetSInt32Answer(CFStringRef question, int32_t defaultVal) __attribute__((weak_import));
extern int64_t MGGetSInt64Answer(CFStringRef question, int64_t defaultVal) __attribute__((weak_import));
extern float MGGetFloat32Answer(CFStringRef question, float defaultVal) __attribute__((weak_import));
extern CFStringRef MGGetStringAnswer(CFStringRef question) __attribute__((weak_import)) CF_RETURNS_RETAINED;
extern int32_t MGGetProductType(void) __attribute__((weak_import));
extern bool MGIsQuestionValid(CFStringRef question) __attribute__((weak_import));

static void pt_mg_format_deterministic_ids(char *out_serial, size_t ser_sz, char *out_udid, size_t udid_sz) {
    pt_ensure_bundle_path_map();
    pt_ensure_data_container_map();
    const char *seed = (s_real_data_container_len > 0) ? s_real_data_container_dir :
                       ((s_real_app_bundle_len > 0) ? s_real_app_bundle_dir : "playcover");
    uint64_t h1 = 14695981039346656037ULL;
    uint64_t h2 = 0x9e3779b97f4a7c15ULL;
    for (const unsigned char *p = (const unsigned char *)seed; *p != '\0'; p++) {
        h1 ^= (uint64_t)(*p);
        h1 *= 1099511628211ULL;
        h2 = (h2 * 6364136223846793005ULL) ^ ((uint64_t)(*p) + 0x517cc1b727220a95ULL);
    }
    if (out_serial != NULL && ser_sz > 0) {
        static const char kAlphaNum[] = "0123456789ABCDEFGHJKLMNPQRSTUVWXYZ";
        char tmp[13];
        uint64_t v = h1;
        for (int i = 0; i < 12; i++) {
            tmp[i] = kAlphaNum[v % (sizeof(kAlphaNum) - 1)];
            v = (v >> 5) ^ (v * 2654435761ULL);
        }
        tmp[12] = '\0';
        strlcpy(out_serial, tmp, ser_sz);
    }
    if (out_udid != NULL && udid_sz > 0) {
        uint32_t chip_prefix = 0x8103U;
        const pt_device_profile_t *prof = pt_get_active_device_profile();
        if (prof->soc_code != NULL && (prof->soc_code[0] == 't' || prof->soc_code[0] == 's')) {
            chip_prefix = (uint32_t)strtoul(prof->soc_code + 1, NULL, 16);
        }
        snprintf(out_udid, udid_sz, "0000%04X-%016llX", (unsigned int)chip_prefix, (unsigned long long)h2);
    }
}

static uint32_t pt_mg_chip_id(const pt_device_profile_t *profile) {
    if (profile != NULL && profile->soc_code != NULL &&
        (profile->soc_code[0] == 't' || profile->soc_code[0] == 's')) {
        return (uint32_t)strtoul(profile->soc_code + 1, NULL, 16);
    }
    return 0x8103U;
}

static int32_t pt_mg_board_id(const pt_device_profile_t *profile) {
    if (profile == NULL || profile->model == NULL) {
        return 0x06;
    }
    if (strcmp(profile->model, "iPad6,7") == 0) return 0x10;
    if (strcmp(profile->model, "iPad8,6") == 0) return 0x0C;
    if (strcmp(profile->model, "iPad13,8") == 0) return 0x06;
    if (strcmp(profile->model, "iPad14,5") == 0) return 0x0E;
    if (strcmp(profile->model, "iPad16,6") == 0) return 0x14;
    if (strcmp(profile->model, "iPad17,3") == 0) return 0x16;
    if (strcmp(profile->model, "iPhone12,5") == 0) return 0x06;
    if (strcmp(profile->model, "iPhone14,3") == 0) return 0x0A;
    if (strcmp(profile->model, "iPhone15,3") == 0) return 0x0C;
    if (strcmp(profile->model, "iPhone16,2") == 0) return 0x0E;
    if (strcmp(profile->model, "iPhone17,2") == 0) return 0x10;
    if (strcmp(profile->model, "iPhone18,2") == 0) return 0x12;
    return 0x08;
}

static BOOL pt_mg_is_faceid_model(const char *m) {
    if (m == NULL || m[0] == '\0') {
        return NO;
    }
    if (strcmp(m, "iPhone12,8") == 0 || strcmp(m, "iPhone14,6") == 0 ||
        strcmp(m, "iPad16,1") == 0 || strcmp(m, "iPad16,2") == 0) {
        return NO;
    }
    if (strncmp(m, "iPad8,", 6) == 0 ||
        strncmp(m, "iPad16,", 7) == 0 ||
        strncmp(m, "iPad17,", 7) == 0 ||
        strcmp(m, "iPhone10,3") == 0 ||
        strcmp(m, "iPhone10,6") == 0 ||
        strncmp(m, "iPhone11,", 9) == 0 ||
        strncmp(m, "iPhone12,", 9) == 0 ||
        strncmp(m, "iPhone13,", 9) == 0 ||
        strncmp(m, "iPhone14,", 9) == 0 ||
        strncmp(m, "iPhone15,", 9) == 0 ||
        strncmp(m, "iPhone16,", 9) == 0 ||
        strncmp(m, "iPhone17,", 9) == 0 ||
        strncmp(m, "iPhone18,", 9) == 0) {
        return YES;
    }
    static const char *const kExtraFaceID[] = {
        "iPad13,4", "iPad13,5", "iPad13,6", "iPad13,7",
        "iPad13,8", "iPad13,9", "iPad13,10", "iPad13,11",
        "iPad14,3", "iPad14,4", "iPad14,5", "iPad14,6"
    };
    for (size_t i = 0; i < sizeof(kExtraFaceID) / sizeof(kExtraFaceID[0]); i++) {
        if (strcmp(m, kExtraFaceID[i]) == 0) {
            return YES;
        }
    }
    return NO;
}

static int32_t pt_mg_product_type_enum(const pt_device_profile_t *profile) {
    if (profile == NULL || profile->model == NULL || profile->model[0] == '\0') {
        return (int32_t)3047992373U; // iPad13,8 deterministic code
    }
    if (strcmp(profile->model, "iPad6,7") == 0) return (int32_t)3826259891U;
    if (strcmp(profile->model, "iPad8,6") == 0) return (int32_t)2219225672U;
    if (strcmp(profile->model, "iPad13,8") == 0) return (int32_t)3047992373U;
    if (strcmp(profile->model, "iPad14,5") == 0) return (int32_t)2959110358U;
    if (strcmp(profile->model, "iPad16,6") == 0) return (int32_t)3482895411U;
    if (strcmp(profile->model, "iPad17,3") == 0) return (int32_t)2739481651U;
    if (strcmp(profile->model, "iPhone12,5") == 0) return (int32_t)1790878510U;
    if (strcmp(profile->model, "iPhone14,3") == 0) return (int32_t)1179926470U;
    if (strcmp(profile->model, "iPhone15,3") == 0) return (int32_t)2816236405U;
    if (strcmp(profile->model, "iPhone16,2") == 0) return (int32_t)2376455129U;
    if (strcmp(profile->model, "iPhone17,2") == 0) return (int32_t)3104882917U;
    if (strcmp(profile->model, "iPhone18,2") == 0) return (int32_t)4019283745U;
    uint32_t h = 2166136261U;
    for (const unsigned char *p = (const unsigned char *)profile->model; *p != '\0'; ++p) {
        h ^= (uint32_t)(*p);
        h *= 16777619U;
    }
    return (int32_t)(h != 0U ? h : 1790878510U);
}

static os_unfair_lock s_mg_str_cache_lock = OS_UNFAIR_LOCK_INIT;
static CFMutableDictionaryRef s_mg_str_cache = NULL;

static CFStringRef pt_mg_cached_cfstring(const char *key_tag, const char *cstr) {
    if (cstr == NULL) {
        return NULL;
    }
    os_unfair_lock_lock(&s_mg_str_cache_lock);
    if (s_mg_str_cache == NULL) {
        s_mg_str_cache = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    CFStringRef val = NULL;
    if (s_mg_str_cache != NULL) {
        CFStringRef kref = CFStringCreateWithCString(kCFAllocatorDefault, key_tag, kCFStringEncodingUTF8);
        if (kref != NULL) {
            val = (CFStringRef)CFDictionaryGetValue(s_mg_str_cache, kref);
            if (val == NULL) {
                val = CFStringCreateWithCString(kCFAllocatorDefault, cstr, kCFStringEncodingUTF8);
                if (val != NULL) {
                    CFDictionarySetValue(s_mg_str_cache, kref, val);
                    CFRelease(val);
                }
            }
            CFRelease(kref);
        }
    }
    os_unfair_lock_unlock(&s_mg_str_cache_lock);
    return val;
}

static NSDictionary<NSString *, NSString *> *pt_mg_obfuscated_key_map(void) {
    static NSDictionary<NSString *, NSString *> *s_map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        static NSString *const kCanonicalKeys[] = {
            @"ProductType", @"ThinningProductType", @"HWModelStr", @"HardwarePlatform",
            @"DeviceClass", @"DeviceName", @"UserAssignedDeviceName", @"ComputerName",
            @"ProductName", @"ProductVersion", @"BuildVersion", @"ProductBuildVersion",
            @"ModelNumber", @"RegulatoryModelNumber", @"marketing-name",
            @"SerialNumber", @"UniqueDeviceID", @"ChipID", @"BoardId",
            @"DeviceFamily", @"SupportedDeviceFamilies", @"DeviceClassNumber",
            @"UserInterfaceIdiom", @"ipad", @"iphone",
            @"HasBattery", @"BatteryCurrentCapacity", @"BatteryIsCharging", @"ExternalPowerSourceConnected",
            @"TouchIDCapability", @"HasMesa", @"PearlIDCapability", @"HasPearl",
            @"main-screen-width", @"main-screen-height", @"main-screen-scale", @"ScreenDimensions",
            @"HasBaseband", @"VibratorCapability", @"CPUArchitecture",
            @"apple-internal-install", @"has-si-dev-tree", @"InternalBuild",
            @"ArtworkTraits", @"CompatibleDeviceFallback", @"DieId", @"UniqueChipID", @"SysCfgDict"
        };
        NSMutableDictionary<NSString *, NSString *> *map =
            [NSMutableDictionary dictionaryWithCapacity:(sizeof(kCanonicalKeys) / sizeof(kCanonicalKeys[0]))];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (size_t i = 0; i < sizeof(kCanonicalKeys) / sizeof(kCanonicalKeys[0]); i++) {
            NSString *canonical = kCanonicalKeys[i];
            NSString *prefixed = [@"MGCopyAnswer" stringByAppendingString:canonical];
            const char *utf8 = [prefixed UTF8String];
            if (utf8 == NULL) {
                continue;
            }
            uint8_t digest[CC_MD5_DIGEST_LENGTH];
            CC_MD5(utf8, (CC_LONG)strlen(utf8), digest);
            NSString *b64 = [[NSData dataWithBytes:digest length:sizeof(digest)] base64EncodedStringWithOptions:0];
            while ([b64 hasSuffix:@"="]) {
                b64 = [b64 substringToIndex:b64.length - 1];
            }
            if (b64.length == 22) {
                map[b64] = canonical;
            }
        }
#pragma clang diagnostic pop
        s_map = [map copy];
    });
    return s_map;
}

static BOOL pt_mg_lookup_spoofed_internal(CFStringRef question, CFTypeRef *out_val, BOOL retain_result) {
    if (question == NULL || out_val == NULL) {
        return NO;
    }
    *out_val = NULL;
    NSString *key = (__bridge NSString *)question;
    if (key.length == 22) {
        NSString *unhashed = pt_mg_obfuscated_key_map()[key];
        if (unhashed != nil) {
            key = unhashed;
        }
    }
    const pt_device_profile_t *profile = pt_get_active_device_profile();

    if ([key isEqualToString:@"ProductType"] || [key isEqualToString:@"ThinningProductType"]) {
        CFStringRef s = pt_mg_cached_cfstring(profile->model, profile->model);
        *out_val = (retain_result && s != NULL) ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"HWModelStr"]) {
        CFStringRef s = pt_mg_cached_cfstring(profile->oem_id, profile->oem_id);
        *out_val = (retain_result && s != NULL) ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"HardwarePlatform"]) {
        const char *soc = (profile->soc_code != NULL) ? profile->soc_code : "t8103";
        CFStringRef s = pt_mg_cached_cfstring(soc, soc);
        *out_val = (retain_result && s != NULL) ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"DeviceClass"] ||
        [key isEqualToString:@"DeviceName"] ||
        [key isEqualToString:@"UserAssignedDeviceName"] ||
        [key isEqualToString:@"ComputerName"]) {
        CFStringRef s = profile->is_ipad ? CFSTR("iPad") : CFSTR("iPhone");
        *out_val = retain_result ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"ProductName"]) {
        CFStringRef s = CFSTR("iPhone OS");
        *out_val = retain_result ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"ProductVersion"]) {
        pt_ensure_host_kernel_info();
        const char *ov_ver = pt_get_reported_ios_version_override(NULL);
        const char *effVer = (ov_ver != NULL) ? ov_ver : s_spoofed_ios_version;
        CFStringRef s = pt_mg_cached_cfstring(effVer, effVer);
        *out_val = (retain_result && s != NULL) ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"BuildVersion"] || [key isEqualToString:@"ProductBuildVersion"]) {
        pt_ensure_host_kernel_info();
        const char *ov_build = NULL;
        (void)pt_get_reported_ios_version_override(&ov_build);
        const char *effBuild = (ov_build != NULL) ? ov_build : s_spoofed_osversion;
        CFStringRef s = pt_mg_cached_cfstring(effBuild, effBuild);
        *out_val = (retain_result && s != NULL) ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"ModelNumber"]) {
        CFStringRef s = pt_mg_cached_cfstring(profile->model_number, profile->model_number);
        *out_val = (retain_result && s != NULL) ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"RegulatoryModelNumber"]) {
        CFStringRef s = pt_mg_cached_cfstring(profile->regulatory_model, profile->regulatory_model);
        *out_val = (retain_result && s != NULL) ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"marketing-name"]) {
        CFStringRef s = pt_mg_cached_cfstring(profile->marketing_name, profile->marketing_name);
        *out_val = (retain_result && s != NULL) ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"SerialNumber"]) {
        char ser[32];
        pt_mg_format_deterministic_ids(ser, sizeof(ser), NULL, 0);
        CFStringRef s = pt_mg_cached_cfstring("SerialNumber", ser);
        *out_val = (retain_result && s != NULL) ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"UniqueDeviceID"]) {
        char udid[64];
        pt_mg_format_deterministic_ids(NULL, 0, udid, sizeof(udid));
        char tag[96];
        snprintf(tag, sizeof(tag), "UDID:%s", profile->model);
        CFStringRef s = pt_mg_cached_cfstring(tag, udid);
        *out_val = (retain_result && s != NULL) ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"CPUArchitecture"]) {
        const char *arch = (strcmp(profile->model, "iPad6,7") == 0) ? "arm64" : "arm64e";
        CFStringRef s = pt_mg_cached_cfstring(arch, arch);
        *out_val = (retain_result && s != NULL) ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"ChipID"]) {
        int32_t chip = (int32_t)pt_mg_chip_id(profile);
        *out_val = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &chip);
        return YES;
    }
    if ([key isEqualToString:@"BoardId"]) {
        int32_t bid = pt_mg_board_id(profile);
        *out_val = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &bid);
        return YES;
    }
    if ([key isEqualToString:@"DeviceClassNumber"]) {
        int32_t clsNum = profile->is_ipad ? 3 : 1;
        *out_val = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &clsNum);
        return YES;
    }
    if ([key isEqualToString:@"UserInterfaceIdiom"]) {
        int32_t idiom = profile->is_ipad ? 1 : 0;
        *out_val = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &idiom);
        return YES;
    }
    if ([key isEqualToString:@"BatteryCurrentCapacity"]) {
        int32_t capPct = (int32_t)lroundf(pt_get_shared_spoofed_battery_level() * 100.0f);
        *out_val = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &capPct);
        return YES;
    }
    if ([key isEqualToString:@"main-screen-width"]) {
        int32_t w = (int32_t)profile->native_width;
        *out_val = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &w);
        return YES;
    }
    if ([key isEqualToString:@"main-screen-height"]) {
        int32_t h = (int32_t)profile->native_height;
        *out_val = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &h);
        return YES;
    }
    if ([key isEqualToString:@"main-screen-scale"]) {
        double sc = profile->native_scale;
        *out_val = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &sc);
        return YES;
    }
    if ([key isEqualToString:@"ScreenDimensions"]) {
        NSDictionary *dims = @{
            @"Width": @((int32_t)profile->native_width),
            @"Height": @((int32_t)profile->native_height),
        };
        *out_val = CFBridgingRetain(dims);
        return YES;
    }
    if ([key isEqualToString:@"DeviceFamily"] ||
        [key isEqualToString:@"SupportedDeviceFamilies"]) {
        NSArray *arr = @[ @(profile->is_ipad ? 2 : 1) ];
        *out_val = CFBridgingRetain(arr);
        return YES;
    }
    if ([key isEqualToString:@"ipad"]) {
        CFBooleanRef b = profile->is_ipad ? kCFBooleanTrue : kCFBooleanFalse;
        *out_val = retain_result ? CFRetain(b) : b;
        return YES;
    }
    if ([key isEqualToString:@"iphone"]) {
        CFBooleanRef b = profile->is_ipad ? kCFBooleanFalse : kCFBooleanTrue;
        *out_val = retain_result ? CFRetain(b) : b;
        return YES;
    }
    if ([key isEqualToString:@"HasBattery"]) {
        *out_val = retain_result ? CFRetain(kCFBooleanTrue) : kCFBooleanTrue;
        return YES;
    }
    if ([key isEqualToString:@"BatteryIsCharging"] ||
        [key isEqualToString:@"ExternalPowerSourceConnected"]) {
        *out_val = retain_result ? CFRetain(kCFBooleanFalse) : kCFBooleanFalse;
        return YES;
    }
    if ([key isEqualToString:@"TouchIDCapability"] || [key isEqualToString:@"HasMesa"]) {
        CFBooleanRef b = pt_mg_is_faceid_model(profile->model) ? kCFBooleanFalse : kCFBooleanTrue;
        *out_val = retain_result ? CFRetain(b) : b;
        return YES;
    }
    if ([key isEqualToString:@"PearlIDCapability"] || [key isEqualToString:@"HasPearl"]) {
        CFBooleanRef b = pt_mg_is_faceid_model(profile->model) ? kCFBooleanTrue : kCFBooleanFalse;
        *out_val = retain_result ? CFRetain(b) : b;
        return YES;
    }
    if ([key isEqualToString:@"HasBaseband"] || [key isEqualToString:@"VibratorCapability"]) {
        CFBooleanRef b = profile->is_ipad ? kCFBooleanFalse : kCFBooleanTrue;
        *out_val = retain_result ? CFRetain(b) : b;
        return YES;
    }
    if ([key isEqualToString:@"apple-internal-install"] ||
        [key isEqualToString:@"has-si-dev-tree"] ||
        [key isEqualToString:@"InternalBuild"]) {
        *out_val = retain_result ? CFRetain(kCFBooleanFalse) : kCFBooleanFalse;
        return YES;
    }
    if ([key isEqualToString:@"ArtworkTraits"]) {
        NSString *gamut = (strcmp(profile->model, "iPad6,7") == 0) ? @"sRGB" : @"P3";
        NSDictionary *traits = @{
            @"ArtworkDeviceIdiom": profile->is_ipad ? @"ipad" : @"iphone",
            @"ArtworkDeviceProductDescription": [NSString stringWithUTF8String:profile->marketing_name],
            @"ArtworkDisplayGamut": gamut,
            @"ArtworkScaleFactor": @((int)profile->native_scale),
        };
        *out_val = CFBridgingRetain(traits);
        return YES;
    }
    if ([key isEqualToString:@"CompatibleDeviceFallback"] ||
        [key isEqualToString:@"DieId"] ||
        [key isEqualToString:@"UniqueChipID"] ||
        [key isEqualToString:@"SysCfgDict"]) {
        *out_val = NULL;
        return YES;
    }
    return NO;
}

static BOOL pt_mg_lookup_spoofed(CFStringRef question, CFTypeRef *out_retained) {
    return pt_mg_lookup_spoofed_internal(question, out_retained, YES);
}

__attribute__((visibility("hidden"))) CFTypeRef pt_MGCopyAnswer(CFStringRef question, CFDictionaryRef options) {
    BOOL app_caller = (pt_is_bypass_enabled() &&
                       !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    if (app_caller) {
        CFTypeRef spoofed = NULL;
        if (pt_mg_lookup_spoofed(question, &spoofed)) {
            return spoofed;
        }
    }
    CFTypeRef orig = (MGCopyAnswer != NULL) ? MGCopyAnswer(question, options) : NULL;
    if (app_caller && orig != NULL) {
        CFTypeRef san = pt_create_sanitized_ioreg_cfvalue_if_changed(orig, kCFAllocatorDefault, 0);
        if (san != NULL) {
            CFRelease(orig);
            return san;
        }
    }
    return orig;
}

__attribute__((visibility("hidden"))) CFTypeRef pt_MGCopyAnswerWithError(CFStringRef question, CFDictionaryRef options, int *outError) {
    BOOL app_caller = (pt_is_bypass_enabled() &&
                       !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    if (app_caller) {
        CFTypeRef spoofed = NULL;
        if (pt_mg_lookup_spoofed(question, &spoofed)) {
            if (outError != NULL) {
                *outError = (spoofed != NULL) ? 0 : -1;
            }
            return spoofed;
        }
    }
    if (MGCopyAnswerWithError != NULL) {
        CFTypeRef orig = MGCopyAnswerWithError(question, options, outError);
        if (app_caller && orig != NULL) {
            CFTypeRef san = pt_create_sanitized_ioreg_cfvalue_if_changed(orig, kCFAllocatorDefault, 0);
            if (san != NULL) {
                CFRelease(orig);
                return san;
            }
        }
        return orig;
    }
    if (outError != NULL) {
        *outError = -1;
    }
    return NULL;
}

__attribute__((visibility("hidden"))) CFDictionaryRef pt_MGCopyMultipleAnswers(CFArrayRef questions, CFDictionaryRef options) {
    BOOL app_caller = (pt_is_bypass_enabled() &&
                       !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    if (!app_caller) {
        return (MGCopyMultipleAnswers != NULL) ? MGCopyMultipleAnswers(questions, options) : NULL;
    }
    if (questions == NULL) {
        return NULL;
    }
    CFDictionaryRef orig = (MGCopyMultipleAnswers != NULL) ? MGCopyMultipleAnswers(questions, options) : NULL;
    NSMutableDictionary *result = (orig != NULL) ? [(__bridge NSDictionary *)orig mutableCopy] : [NSMutableDictionary dictionary];
    if (orig != NULL) {
        CFRelease(orig);
    }
    for (id q in (__bridge NSArray *)questions) {
        if ([q isKindOfClass:[NSString class]]) {
            CFTypeRef spoofed = NULL;
            if (pt_mg_lookup_spoofed((__bridge CFStringRef)q, &spoofed)) {
                if (spoofed != NULL) {
                    result[q] = (__bridge_transfer id)spoofed;
                } else {
                    [result removeObjectForKey:q];
                }
            } else if (result[q] != nil) {
                CFTypeRef san = pt_create_sanitized_ioreg_cfvalue_if_changed(
                    (__bridge CFTypeRef)result[q], kCFAllocatorDefault, 0);
                if (san != NULL) {
                    result[q] = (__bridge_transfer id)san;
                }
            }
        }
    }
    return (__bridge_retained CFDictionaryRef)[result copy];
}

__attribute__((visibility("hidden"))) bool pt_MGGetBoolAnswer(CFStringRef question) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        CFTypeRef spoofed = NULL;
        if (pt_mg_lookup_spoofed(question, &spoofed)) {
            bool res = false;
            if (spoofed != NULL) {
                if (CFGetTypeID(spoofed) == CFBooleanGetTypeID()) {
                    res = CFBooleanGetValue((CFBooleanRef)spoofed);
                }
                CFRelease(spoofed);
            }
            return res;
        }
    }
    return (MGGetBoolAnswer != NULL) ? MGGetBoolAnswer(question) : false;
}

__attribute__((visibility("hidden"))) int32_t pt_MGGetSInt32Answer(CFStringRef question, int32_t defaultVal) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        CFTypeRef spoofed = NULL;
        if (pt_mg_lookup_spoofed(question, &spoofed)) {
            int32_t res = defaultVal;
            if (spoofed != NULL) {
                if (CFGetTypeID(spoofed) == CFNumberGetTypeID()) {
                    CFNumberGetValue((CFNumberRef)spoofed, kCFNumberSInt32Type, &res);
                }
                CFRelease(spoofed);
            }
            return res;
        }
    }
    return (MGGetSInt32Answer != NULL) ? MGGetSInt32Answer(question, defaultVal) : defaultVal;
}

__attribute__((visibility("hidden"))) int64_t pt_MGGetSInt64Answer(CFStringRef question, int64_t defaultVal) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        CFTypeRef spoofed = NULL;
        if (pt_mg_lookup_spoofed(question, &spoofed)) {
            int64_t res = defaultVal;
            if (spoofed != NULL) {
                if (CFGetTypeID(spoofed) == CFNumberGetTypeID()) {
                    CFNumberGetValue((CFNumberRef)spoofed, kCFNumberSInt64Type, &res);
                }
                CFRelease(spoofed);
            }
            return res;
        }
    }
    return (MGGetSInt64Answer != NULL) ? MGGetSInt64Answer(question, defaultVal) : defaultVal;
}

__attribute__((visibility("hidden"))) float pt_MGGetFloat32Answer(CFStringRef question, float defaultVal) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        CFTypeRef spoofed = NULL;
        if (pt_mg_lookup_spoofed(question, &spoofed)) {
            float res = defaultVal;
            if (spoofed != NULL) {
                if (CFGetTypeID(spoofed) == CFNumberGetTypeID()) {
                    CFNumberGetValue((CFNumberRef)spoofed, kCFNumberFloat32Type, &res);
                }
                CFRelease(spoofed);
            }
            return res;
        }
    }
    return (MGGetFloat32Answer != NULL) ? MGGetFloat32Answer(question, defaultVal) : defaultVal;
}

__attribute__((visibility("hidden"))) CFStringRef pt_MGGetStringAnswer(CFStringRef question) CF_RETURNS_RETAINED {
    BOOL app_caller = (pt_is_bypass_enabled() &&
                       !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    if (app_caller) {
        CFTypeRef spoofed = NULL;
        if (pt_mg_lookup_spoofed_internal(question, &spoofed, YES)) {
            if (spoofed != NULL && CFGetTypeID(spoofed) != CFStringGetTypeID()) {
                CFRelease(spoofed);
                return NULL;
            }
            return (CFStringRef)spoofed;
        }
    }
    CFStringRef orig = (MGGetStringAnswer != NULL) ? MGGetStringAnswer(question) : NULL;
    if (app_caller && orig != NULL) {
        CFTypeRef san = pt_create_sanitized_ioreg_cfvalue_if_changed(orig, kCFAllocatorDefault, 0);
        if (san != NULL) {
            CFRelease(orig);
            if (CFGetTypeID(san) == CFStringGetTypeID()) {
                return (CFStringRef)san;
            }
            CFRelease(san);
            return NULL;
        }
    }
    return orig;
}

__attribute__((visibility("hidden"))) int32_t pt_MGGetProductType(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return pt_mg_product_type_enum(pt_get_active_device_profile());
    }
    return (MGGetProductType != NULL) ? MGGetProductType() : 0;
}

__attribute__((visibility("hidden"))) bool pt_MGIsQuestionValid(CFStringRef question) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        CFTypeRef spoofed = NULL;
        if (pt_mg_lookup_spoofed(question, &spoofed)) {
            bool valid = (spoofed != NULL);
            if (spoofed != NULL) {
                CFRelease(spoofed);
            }
            return valid;
        }
    }
    return (MGIsQuestionValid != NULL) ? MGIsQuestionValid(question) : false;
}

PT_INTERPOSE(pt_IORegistryEntryCreateCFProperty, IORegistryEntryCreateCFProperty)
PT_INTERPOSE(pt_IORegistryEntrySearchCFProperty, IORegistryEntrySearchCFProperty)
PT_INTERPOSE(pt_IORegistryEntryCreateCFProperties, IORegistryEntryCreateCFProperties)
PT_INTERPOSE_WEAK_NAMED(pt_IORegistryEntryGetProperty, pt_orig_IORegistryEntryGetProperty, "IORegistryEntryGetProperty")
PT_INTERPOSE(pt_IORegistryEntryGetPath, IORegistryEntryGetPath)
PT_INTERPOSE(pt_IORegistryEntryCopyPath, IORegistryEntryCopyPath)
PT_INTERPOSE(pt_IOServiceGetMatchingService, IOServiceGetMatchingService)
PT_INTERPOSE(pt_IOServiceGetMatchingServices, IOServiceGetMatchingServices)
PT_INTERPOSE(pt_IOObjectGetClass, IOObjectGetClass)
PT_INTERPOSE(pt_IOObjectCopyClass, IOObjectCopyClass)
PT_INTERPOSE(pt_IOObjectCopySuperclassForClass, IOObjectCopySuperclassForClass)
PT_INTERPOSE(pt_IOObjectCopyBundleIdentifierForClass, IOObjectCopyBundleIdentifierForClass)
PT_INTERPOSE(pt_IOIteratorNext, IOIteratorNext)
PT_INTERPOSE(pt_AudioComponentFindNext, AudioComponentFindNext)
PT_INTERPOSE(pt_AudioComponentCount, AudioComponentCount)
PT_INTERPOSE_WEAK_NAMED(pt_AudioComponentInstanceNew, pt_orig_AudioComponentInstanceNew, "AudioComponentInstanceNew")
PT_INTERPOSE_WEAK_NAMED(pt_AudioComponentInstantiate, pt_orig_AudioComponentInstantiate, "AudioComponentInstantiate")
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
PT_INTERPOSE(pt_UTTypeCopyDeclaringBundleURL, UTTypeCopyDeclaringBundleURL)
PT_INTERPOSE(pt_UTTypeCopyDeclaration, UTTypeCopyDeclaration)
#pragma clang diagnostic pop
PT_INTERPOSE(pt_IOPSCopyPowerSourcesInfo, IOPSCopyPowerSourcesInfo)
PT_INTERPOSE(pt_IOPSCopyPowerSourcesList, IOPSCopyPowerSourcesList)
PT_INTERPOSE(pt_IOPSGetPowerSourceDescription, IOPSGetPowerSourceDescription)
PT_INTERPOSE(pt_IOPSGetProvidingPowerSourceType, IOPSGetProvidingPowerSourceType)
PT_INTERPOSE(pt_IOPSGetTimeRemainingEstimate, IOPSGetTimeRemainingEstimate)
PT_INTERPOSE(pt_IOPSDrawingUnlimitedPower, IOPSDrawingUnlimitedPower)
PT_INTERPOSE(pt_IOPSCopyExternalPowerAdapterDetails, IOPSCopyExternalPowerAdapterDetails)
PT_INTERPOSE(pt_IOPSCopyPowerSourcesByType, IOPSCopyPowerSourcesByType)
PT_INTERPOSE_WEAK_NAMED(pt_IOPSGetPercentRemaining, pt_orig_IOPSGetPercentRemaining, "IOPSGetPercentRemaining")
PT_INTERPOSE(pt_MGCopyAnswer, MGCopyAnswer)
PT_INTERPOSE(pt_MGCopyAnswerWithError, MGCopyAnswerWithError)
PT_INTERPOSE(pt_MGCopyMultipleAnswers, MGCopyMultipleAnswers)
PT_INTERPOSE(pt_MGGetBoolAnswer, MGGetBoolAnswer)
PT_INTERPOSE(pt_MGGetSInt32Answer, MGGetSInt32Answer)
PT_INTERPOSE(pt_MGGetSInt64Answer, MGGetSInt64Answer)
PT_INTERPOSE(pt_MGGetFloat32Answer, MGGetFloat32Answer)
PT_INTERPOSE(pt_MGGetStringAnswer, MGGetStringAnswer)
PT_INTERPOSE(pt_MGGetProductType, MGGetProductType)
PT_INTERPOSE(pt_MGIsQuestionValid, MGIsQuestionValid)
PT_INTERPOSE(pt_IORegistryEntryGetName, IORegistryEntryGetName)
PT_INTERPOSE(pt_IORegistryEntryGetNameInPlane, IORegistryEntryGetNameInPlane)
PT_INTERPOSE(pt_IOObjectConformsTo, IOObjectConformsTo)
PT_INTERPOSE(pt_IORegistryEntryFromPath, IORegistryEntryFromPath)
PT_INTERPOSE(pt_IORegistryEntryCopyFromPath, IORegistryEntryCopyFromPath)
PT_INTERPOSE(pt_IORegistryEntryGetChildEntry, IORegistryEntryGetChildEntry)
PT_INTERPOSE(pt_IORegistryEntryGetParentEntry, IORegistryEntryGetParentEntry)
PT_INTERPOSE(pt_AudioUnitGetProperty, AudioUnitGetProperty)
PT_INTERPOSE(pt_AudioUnitGetPropertyInfo, AudioUnitGetPropertyInfo)
