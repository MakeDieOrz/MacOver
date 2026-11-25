//
//  PTSystemSpooferObjC.m
//  PlayTools
//

#import "PSInternal.h"
#include <math.h>

@implementation PSSwizzleHooks (PlayShadowSystem)

- (NSInteger) pm_hook_deviceType {
    return 1;
}

static NSString *ps_current_device_model_nsstring(void) {
    const char *m = pt_get_device_model_cstr();
    if (m != NULL && m[0] != '\0') {
        NSString *s = [NSString stringWithUTF8String:m];
        if (s.length > 0) {
            return s;
        }
    }
    return @"iPad13,8";
}

static NSString *ps_current_oem_id_nsstring(void) {
    const char *o = pt_get_oem_id_cstr();
    if (o != NULL && o[0] != '\0') {
        NSString *s = [NSString stringWithUTF8String:o];
        if (s.length > 0) {
            return s;
        }
    }
    return @"J522AP";
}

- (NSString *) pm_hook_platform {
    return ps_current_device_model_nsstring();
}

- (NSString *) pm_hook_hwModel {
    return ps_current_oem_id_nsstring();
}

- (NSString *) pm_hook_deviceName {
    return ps_is_iphone_device_model() ? @"iPhone" : @"iPad";
}

- (NSString *) pm_hook_deviceModel {
    return ps_is_iphone_device_model() ? @"iPhone" : @"iPad";
}

- (NSString *) pm_hook_deviceLocalizedModel {
    return ps_is_iphone_device_model() ? @"iPhone" : @"iPad";
}

__attribute__((visibility("hidden"))) NSUUID * (*s_orig_device_identifierForVendor)(id, SEL) = NULL;

static NSUUID *ps_cached_host_hardware_uuid(void) {
    static NSUUID *s_hostUUID = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        char buf[64] = {0};
        size_t len = sizeof(buf);
        if (sysctlbyname("kern.uuid", buf, &len, NULL, 0) == 0 && buf[0] != '\0') {
            NSString *s = [NSString stringWithUTF8String:buf];
            if (s.length > 0) {
                s_hostUUID = [[NSUUID alloc] initWithUUIDString:s];
            }
        }
    });
    return s_hostUUID;
}

static NSUUID *ps_fallback_vendor_uuid(void) {
    static NSUUID *s_fallbackUUID = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"app.makedie.app";
        const char *vh = pt_get_virtual_home_cstr();
        NSString *seed = [NSString stringWithFormat:@"ps-idfv:%@:%s", bundleID, (vh != NULL) ? vh : ""];
        NSData *seedData = [seed dataUsingEncoding:NSUTF8StringEncoding];
        uint8_t digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(seedData.bytes, (CC_LONG)seedData.length, digest);
        uuid_t bytes;
        memcpy(bytes, digest, sizeof(uuid_t));
        bytes[6] = (uint8_t)((bytes[6] & 0x0F) | 0x40);
        bytes[8] = (uint8_t)((bytes[8] & 0x3F) | 0x80);
        s_fallbackUUID = [[NSUUID alloc] initWithUUIDBytes:bytes];
    });
    return s_fallbackUUID;
}

__attribute__((visibility("hidden"))) NSUUID *ps_hook_device_identifierForVendor(id self, SEL _cmd) {
    NSUUID *orig = s_orig_device_identifierForVendor ? s_orig_device_identifierForVendor(self, _cmd) : nil;
    if (!pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return orig;
    }
    if (orig == nil) {
        return ps_fallback_vendor_uuid();
    }
    uuid_t rawBytes;
    [orig getUUIDBytes:rawBytes];
    BOOL allZero = YES;
    for (size_t i = 0; i < sizeof(uuid_t); i++) {
        if (rawBytes[i] != 0) {
            allZero = NO;
            break;
        }
    }
    if (allZero) {
        return ps_fallback_vendor_uuid();
    }
    NSUUID *hostUUID = ps_cached_host_hardware_uuid();
    if (hostUUID != nil && [orig isEqual:hostUUID]) {
        return ps_fallback_vendor_uuid();
    }
    return orig;
}

- (NSString *) pm_hook_systemName {
    return ps_is_iphone_device_model() ? @"iOS" : @"iPadOS";
}

- (NSString *) pm_hook_systemVersion {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        const char *ovVer = pt_get_reported_ios_version_override(NULL);
        if (ovVer != NULL) {
            NSString *verStr = [NSString stringWithUTF8String:ovVer];
            if (verStr.length > 0) {
                return verStr;
            }
        }
    }
    return [self pm_hook_systemVersion];
}

- (UIUserInterfaceIdiom) pm_hook_userInterfaceIdiom {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_is_iphone_device_model() ? UIUserInterfaceIdiomPhone : UIUserInterfaceIdiomPad;
    }
    return [self pm_hook_userInterfaceIdiom];
}

- (UIUserInterfaceIdiom) pm_hook_traitUserInterfaceIdiom {
    UIUserInterfaceIdiom orig = [self pm_hook_traitUserInterfaceIdiom];
    if (orig == UIUserInterfaceIdiomUnspecified) {
        return orig;
    }
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        BOOL isIPhone = ps_is_iphone_device_model();
        return isIPhone ? UIUserInterfaceIdiomPhone : (orig == UIUserInterfaceIdiomMac ? UIUserInterfaceIdiomPad : orig);
    }
    return orig;
}

- (NSString *) pm_hook_traitDescription {
    NSString *desc = [self pm_hook_traitDescription];
    if (desc.length > 0 &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        BOOL isIPhone = ps_is_iphone_device_model();
        NSString *target = isIPhone ? @"UserInterfaceIdiom = Phone" : @"UserInterfaceIdiom = Pad";
        if ([desc containsString:@"UserInterfaceIdiom = Mac"]) {
            desc = [desc stringByReplacingOccurrencesOfString:@"UserInterfaceIdiom = Mac" withString:target];
        }
        if (isIPhone && [desc containsString:@"UserInterfaceIdiom = Pad"]) {
            desc = [desc stringByReplacingOccurrencesOfString:@"UserInterfaceIdiom = Pad" withString:@"UserInterfaceIdiom = Phone"];
        }
    }
    return desc;
}

- (UIDisplayGamut) pm_hook_traitDisplayGamut {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        const char *m = pt_get_device_model_cstr();
        if (m != NULL && strcmp(m, "iPad6,7") == 0) {
            return UIDisplayGamutSRGB;
        }
        return UIDisplayGamutP3;
    }
    return [self pm_hook_traitDisplayGamut];
}

static const char kPSProximityMonitoringEnabledKey = 0;

- (void) pm_ps_setProximityMonitoringEnabled:(BOOL)enabled {
    if (pt_is_bypass_enabled() &&
        ps_is_iphone_device_model() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        objc_setAssociatedObject(self, &kPSProximityMonitoringEnabledKey, @(enabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    [self pm_ps_setProximityMonitoringEnabled:enabled];
}

- (BOOL) pm_ps_isProximityMonitoringEnabled {
    if (pt_is_bypass_enabled() &&
        ps_is_iphone_device_model() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        NSNumber *val = objc_getAssociatedObject(self, &kPSProximityMonitoringEnabledKey);
        return [val boolValue];
    }
    return [self pm_ps_isProximityMonitoringEnabled];
}

- (BOOL) pm_ps_proximityState {
    if (pt_is_bypass_enabled() &&
        ps_is_iphone_device_model() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NO;
    }
    return [self pm_ps_proximityState];
}

- (BOOL) pm_canOpenURL:(NSURL *)url {
    if (url != nil && url.scheme != nil &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        static NSSet<NSString *> *s_blockedSchemes = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            s_blockedSchemes = [NSSet setWithArray:@[
                @"apple-magnifier",
                @"trollstore",
                @"dopamine",
                @"palera1n",
                @"santander",
                @"cydia",
                @"sileo",
                @"zbra",
                @"filza",
                @"undecimus",
                @"activator",
                @"ssh",
                @"apt",
                @"playcover",
                @"macover",
                @"x-apple.systempreferences",
                @"macappstore",
                @"macappstores",
                @"finder",
                @"applescript",
                @"x-man-page",
                @"vnc",
                @"afp",
                @"dict"
            ]];
        });
        NSString *scheme = [url.scheme lowercaseString];
        if ([s_blockedSchemes containsObject:scheme]) {
            return NO;
        }
    }
    return [self pm_canOpenURL:url];
}


static inline NSString *ps_virtualize_bundle_path_for_caller(NSString *path, const void *caller) {
    if (path.length > 0 && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        return ps_virtualize_nsstring_path_for_app(path, YES);
    }
    return path;
}

__attribute__((visibility("hidden"))) NSURL *ps_virtualize_bundle_url_for_caller(NSURL *url, const void *caller) {
    if (url != nil && [url isFileURL] && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        return ps_virtualize_nsurl_for_app(url, YES);
    }
    return url;
}

static NSArray<NSString *> *ps_filter_and_virtualize_bundle_paths(NSArray<NSString *> *paths, const void *caller) {
    if (paths == nil || !pt_is_bypass_enabled() || ps_is_effective_system_or_playtools_caller(caller)) {
        return paths;
    }
    NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:paths.count];
    for (NSString *p in paths) {
        if (ps_is_hidden_path(ps_strip_iossupport_nsstring(p), caller)) {
            continue;
        }
        NSString *vp = ps_virtualize_nsstring_path_for_app(p, YES);
        if (vp != nil) {
            [result addObject:vp];
        }
    }
    return [result copy];
}

static NSArray<NSURL *> *ps_filter_and_virtualize_bundle_urls(NSArray<NSURL *> *urls, const void *caller) {
    if (urls == nil || !pt_is_bypass_enabled() || ps_is_effective_system_or_playtools_caller(caller)) {
        return urls;
    }
    NSMutableArray<NSURL *> *result = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *u in urls) {
        if ([u isFileURL] && ps_is_hidden_path(ps_strip_iossupport_nsstring(u.path), caller)) {
            continue;
        }
        NSURL *vu = [u isFileURL] ? ps_virtualize_nsurl_for_app(u, YES) : u;
        if (vu != nil) {
            [result addObject:vu];
        }
    }
    return [result copy];
}

static BOOL ps_is_hidden_bundle_identifier(NSString *bId) {
    if (bId.length == 0) {
        return NO;
    }
    const char *cId = [bId UTF8String];
    if (cId != NULL) {
        if (pt_is_hidden_bundle_id_cstr(cId) || pt_is_registered_hidden_module(cId)) {
            return YES;
        }
    }
    if ([bId hasPrefix:@"com.apple.AGXMetal"]) {
        return YES;
    }
    return NO;
}

static BOOL ps_is_hidden_bundle(NSBundle *bundle, const void *caller) {
    if (bundle == nil) {
        return NO;
    }
    NSString *bPath = bundle.bundlePath ?: @"";
    const char *cPath = [bPath UTF8String];
    if ([bPath containsString:@"PlayTools"] ||
        [bPath containsString:@"AKInterface"] ||
        [bPath containsString:@"UserPlugins"] ||
        (cPath != NULL && (pt_is_registered_hidden_module(cPath) ||
                           pt_is_hidden_dyld_image_name(cPath) ||
                           pt_is_post13_7_hidden_framework_path(cPath))) ||
        ps_is_hidden_path(ps_strip_iossupport_nsstring(bPath), caller)) {
        return YES;
    }
    return ps_is_hidden_bundle_identifier(bundle.bundleIdentifier);
}

static NSArray<NSBundle *> *ps_filter_bundles(NSArray<NSBundle *> *bundles, const void *caller) {
    if (bundles == nil || !pt_is_bypass_enabled() || ps_is_effective_system_or_playtools_caller(caller)) {
        return bundles;
    }
    NSMutableArray<NSBundle *> *filtered = nil;
    for (NSUInteger i = 0; i < bundles.count; i++) {
        NSBundle *bundle = bundles[i];
        if (ps_is_hidden_bundle(bundle, caller)) {
            if (filtered == nil) {
                filtered = [NSMutableArray arrayWithCapacity:bundles.count - 1];
                for (NSUInteger j = 0; j < i; j++) {
                    [filtered addObject:bundles[j]];
                }
            }
        } else if (filtered != nil) {
            [filtered addObject:bundle];
        }
    }
    return filtered != nil ? [filtered copy] : bundles;
}

__attribute__((visibility("hidden"))) NSBundle * (*s_orig_bundleForClass)(id, SEL, Class) = NULL;
__attribute__((visibility("hidden"))) NSBundle *ps_hook_bundle_for_class(id self, SEL _cmd, Class aClass) {
    NSBundle *orig = s_orig_bundleForClass ? s_orig_bundleForClass(self, _cmd, aClass) : nil;
    const void *caller = __builtin_return_address(0);
    if (orig == nil ||
        (pt_is_bypass_enabled() &&
         !ps_is_effective_system_or_playtools_caller(caller) &&
         ps_is_hidden_bundle(orig, caller))) {
        return [NSBundle mainBundle];
    }
    return orig;
}

+ (NSArray<NSBundle *> *) pm_allFrameworks {
    return ps_filter_bundles([self pm_allFrameworks], __builtin_return_address(0));
}

+ (NSArray<NSBundle *> *) pm_allBundles {
    return ps_filter_bundles([self pm_allBundles], __builtin_return_address(0));
}

+ (NSBundle *) pm_bundleWithIdentifier:(NSString *)identifier {
    const void *caller = __builtin_return_address(0);
    if (identifier != nil && pt_is_bypass_enabled() &&
        ps_is_hidden_bundle_identifier(identifier) &&
        !ps_is_effective_system_or_playtools_caller(caller)) {
        return nil;
    }
    return [self pm_bundleWithIdentifier:identifier];
}

static BOOL ps_is_hidden_bundle_path_for_caller(NSString *path, const void *caller) {
    if (path.length == 0) {
        return NO;
    }
    if (ps_is_hidden_path(path, caller)) {
        return YES;
    }
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        const char *cpath = [path UTF8String];
        if (cpath != NULL &&
            (pt_is_hidden_dyld_image_name(cpath) ||
             pt_is_post13_7_hidden_framework_path(cpath))) {
            return YES;
        }
    }
    return NO;
}

+ (NSBundle *) pm_bundleWithPath:(NSString *)path {
    const void *caller = __builtin_return_address(0);
    if (ps_is_hidden_bundle_path_for_caller(path, caller)) {
        return nil;
    }
    NSString *resolved = ps_resolve_virtual_nsstring_path(path);
    if (resolved != path && ps_is_hidden_bundle_path_for_caller(ps_strip_iossupport_nsstring(resolved), caller)) {
        return nil;
    }
    return [self pm_bundleWithPath:resolved];
}

+ (NSBundle *) pm_bundleWithURL:(NSURL *)url {
    const void *caller = __builtin_return_address(0);
    if (url != nil && [url isFileURL] && ps_is_hidden_bundle_path_for_caller(url.path, caller)) {
        return nil;
    }
    NSURL *resolved = ps_resolve_virtual_nsurl(url);
    if (resolved != url && resolved != nil && [resolved isFileURL] &&
        ps_is_hidden_bundle_path_for_caller(ps_strip_iossupport_nsstring(resolved.path), caller)) {
        return nil;
    }
    return [self pm_bundleWithURL:resolved];
}

__attribute__((visibility("hidden"))) NSString *ps_app_settings_plist_path(void) {
    const char *overridePlist = pt_raw_getenv("PLAYTOOLS_SETTINGS_PLIST");
    if (overridePlist != NULL && overridePlist[0] == '/') {
        return [NSString stringWithUTF8String:overridePlist];
    }
    static NSString *s_plistPath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (bundleID.length == 0) {
            return;
        }
        NSString *root = nil;
        const char *hostUserRoot = pt_get_host_user_root_cstr();
        if (hostUserRoot != NULL && hostUserRoot[0] == '/') {
            root = [NSString stringWithUTF8String:hostUserRoot];
        } else {
            const char *cfHome = pt_raw_getenv("CFFIXED_USER_HOME");
            if (cfHome != NULL && cfHome[0] == '/') {
                NSString *cfStr = [NSString stringWithUTF8String:cfHome];
                NSRange marker = [cfStr rangeOfString:@"/Library/Containers/"];
                if (marker.location != NSNotFound && marker.location > 0) {
                    root = [cfStr substringToIndex:marker.location];
                }
            }
            if (root.length == 0) {
                root = [PlaySettings resolveHostUserRoot];
            }
        }
        if (root.length > 0) {
            s_plistPath = [NSString stringWithFormat:@"%@/Library/Containers/app.makedie.MacOver/App Settings/%@.plist",
                           root, bundleID];
        }
    });
    return s_plistPath;
}

- (instancetype) pm_ps_initWithPath:(NSString *)path {
    const void *caller = __builtin_return_address(0);
    if (ps_is_hidden_bundle_path_for_caller(path, caller)) {
        return nil;
    }
    NSString *resolved = ps_resolve_virtual_nsstring_path(path);
    if (resolved != path && ps_is_hidden_bundle_path_for_caller(ps_strip_iossupport_nsstring(resolved), caller)) {
        return nil;
    }
    return [self pm_ps_initWithPath:resolved];
}

- (instancetype) pm_ps_initWithURL:(NSURL *)url {
    const void *caller = __builtin_return_address(0);
    if (url != nil && [url isFileURL] && ps_is_hidden_bundle_path_for_caller(url.path, caller)) {
        return nil;
    }
    NSURL *resolved = ps_resolve_virtual_nsurl(url);
    if (resolved != url && resolved != nil && [resolved isFileURL] &&
        ps_is_hidden_bundle_path_for_caller(ps_strip_iossupport_nsstring(resolved.path), caller)) {
        return nil;
    }
    return [self pm_ps_initWithURL:resolved];
}

static BOOL ps_is_hidden_bundle_resolved_class(Class cls) {
    if (cls == Nil) {
        return NO;
    }
    const char *cname = class_getName(cls);
    const char *img = class_getImageName(cls);
    if (img != NULL &&
        (pt_is_hidden_dyld_image_name(img) || pt_is_post13_7_hidden_framework_path(img))) {
        pt_ensure_bundle_path_map();
        if (s_real_app_bundle_len == 0 ||
            pt_match_prefix_modulo_private(img, s_real_app_bundle_dir, s_real_app_bundle_len) == NULL) {
            return YES;
        }
    }
    if (cname != NULL && pt_is_hidden_objc_class(cname)) {
        if (cname[0] == 'N' && cname[1] == 'S' && img != NULL) {
            pt_ensure_bundle_path_map();
            if (s_real_app_bundle_len > 0 &&
                pt_match_prefix_modulo_private(img, s_real_app_bundle_dir, s_real_app_bundle_len) != NULL) {
                return NO;
            }
        }
        return YES;
    }
    return NO;
}

- (NSArray<NSNumber *> *) pm_ps_bundle_executableArchitectures {
    NSArray<NSNumber *> *orig = [self pm_ps_bundle_executableArchitectures];
    if (orig.count == 0 ||
        !pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return orig;
    }
    NSMutableArray<NSNumber *> *filtered = [NSMutableArray arrayWithCapacity:orig.count];
    for (NSNumber *arch in orig) {
        NSInteger v = arch.integerValue;
        // Strip x86_64 (0x01000007) and i386 (0x00000007) universal slices on spoofed iOS
        if (v == 0x01000007 || v == 0x00000007) {
            continue;
        }
        [filtered addObject:arch];
    }
    return (filtered.count > 0) ? [filtered copy] : @[@(0x0100000c)];
}

- (Class) pm_ps_bundle_classNamed:(NSString *)className {
    const void *caller = __builtin_return_address(0);
    BOOL appCaller = (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller));
    if (appCaller && className.length > 0) {
        const char *cstr = [className UTF8String];
        if (cstr != NULL && pt_is_hidden_objc_class(cstr) && !(cstr[0] == 'N' && cstr[1] == 'S')) {
            return Nil;
        }
    }
    Class cls = [self pm_ps_bundle_classNamed:className];
    if (appCaller && ps_is_hidden_bundle_resolved_class(cls)) {
        return Nil;
    }
    return cls;
}

- (Class) pm_ps_bundle_principalClass {
    const void *caller = __builtin_return_address(0);
    BOOL appCaller = (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller));
    Class cls = [self pm_ps_bundle_principalClass];
    if (appCaller && ps_is_hidden_bundle_resolved_class(cls)) {
        return Nil;
    }
    return cls;
}

- (NSString *) pm_ps_bundlePath {
    return ps_virtualize_bundle_path_for_caller([self pm_ps_bundlePath], __builtin_return_address(0));
}

- (NSString *) pm_ps_resourcePath {
    return ps_virtualize_bundle_path_for_caller([self pm_ps_resourcePath], __builtin_return_address(0));
}

- (NSString *) pm_ps_executablePath {
    return ps_virtualize_bundle_path_for_caller([self pm_ps_executablePath], __builtin_return_address(0));
}

- (NSString *) pm_ps_privateFrameworksPath {
    return ps_virtualize_bundle_path_for_caller([self pm_ps_privateFrameworksPath], __builtin_return_address(0));
}

- (NSString *) pm_ps_sharedFrameworksPath {
    return ps_virtualize_bundle_path_for_caller([self pm_ps_sharedFrameworksPath], __builtin_return_address(0));
}

- (NSString *) pm_ps_sharedSupportPath {
    return ps_virtualize_bundle_path_for_caller([self pm_ps_sharedSupportPath], __builtin_return_address(0));
}

- (NSString *) pm_ps_builtInPlugInsPath {
    return ps_virtualize_bundle_path_for_caller([self pm_ps_builtInPlugInsPath], __builtin_return_address(0));
}

- (NSURL *) pm_ps_bundleURL {
    return ps_virtualize_bundle_url_for_caller([self pm_ps_bundleURL], __builtin_return_address(0));
}

- (NSURL *) pm_ps_resourceURL {
    return ps_virtualize_bundle_url_for_caller([self pm_ps_resourceURL], __builtin_return_address(0));
}

- (NSURL *) pm_ps_executableURL {
    return ps_virtualize_bundle_url_for_caller([self pm_ps_executableURL], __builtin_return_address(0));
}

- (NSURL *) pm_ps_privateFrameworksURL {
    return ps_virtualize_bundle_url_for_caller([self pm_ps_privateFrameworksURL], __builtin_return_address(0));
}

- (NSURL *) pm_ps_sharedFrameworksURL {
    return ps_virtualize_bundle_url_for_caller([self pm_ps_sharedFrameworksURL], __builtin_return_address(0));
}

- (NSURL *) pm_ps_sharedSupportURL {
    return ps_virtualize_bundle_url_for_caller([self pm_ps_sharedSupportURL], __builtin_return_address(0));
}

- (NSURL *) pm_ps_builtInPlugInsURL {
    return ps_virtualize_bundle_url_for_caller([self pm_ps_builtInPlugInsURL], __builtin_return_address(0));
}

- (NSURL *) pm_ps_appStoreReceiptURL {
    return ps_virtualize_bundle_url_for_caller([self pm_ps_appStoreReceiptURL], __builtin_return_address(0));
}

- (NSString *) pm_ps_pathForAuxiliaryExecutable:(NSString *)executableName {
    return ps_virtualize_bundle_path_for_caller([self pm_ps_pathForAuxiliaryExecutable:executableName], __builtin_return_address(0));
}

- (NSURL *) pm_ps_URLForAuxiliaryExecutable:(NSString *)executableName {
    return ps_virtualize_bundle_url_for_caller([self pm_ps_URLForAuxiliaryExecutable:executableName], __builtin_return_address(0));
}

- (NSDictionary<NSString *, id> *) pm_ps_localizedInfoDictionary {
    NSDictionary<NSString *, id> *orig = [self pm_ps_localizedInfoDictionary];
    if (orig != nil &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_info_dict_needs_sanitize(orig)) {
            NSDictionary<NSString *, id> *clean = [orig isKindOfClass:[NSMutableDictionary class]]
                ? pt_build_sanitized_mutable_info_dict(orig)
                : pt_build_sanitized_info_dict(orig);
            if (clean != nil) {
                return clean;
            }
        }
    }
    return orig;
}

- (NSDictionary<NSString *, id> *) pm_ps_infoDictionary {
    NSDictionary<NSString *, id> *orig = [self pm_ps_infoDictionary];
    if (orig != nil &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_info_dict_needs_sanitize(orig)) {
            NSDictionary<NSString *, id> *clean = [orig isKindOfClass:[NSMutableDictionary class]]
                ? pt_build_sanitized_mutable_info_dict(orig)
                : pt_build_sanitized_info_dict(orig);
            if (clean != nil) {
                return clean;
            }
        }
    }
    return orig;
}

- (id) pm_ps_objectForInfoDictionaryKey:(NSString *)key {
    if (key != nil &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        NSDictionary<NSString *, id> *loc = [self pm_ps_localizedInfoDictionary];
        if (loc != nil) {
            NSDictionary<NSString *, id> *cleanLoc = pt_info_dict_needs_sanitize(loc)
                ? pt_build_sanitized_info_dict(loc)
                : loc;
            if (cleanLoc != nil && cleanLoc[key] != nil) {
                return cleanLoc[key];
            }
            if (loc[key] != nil) {
                return nil;
            }
        }
        NSDictionary<NSString *, id> *rawInfo = [self pm_ps_infoDictionary];
        if (rawInfo != nil) {
            NSDictionary<NSString *, id> *cleanInfo = pt_info_dict_needs_sanitize(rawInfo)
                ? pt_build_sanitized_info_dict(rawInfo)
                : rawInfo;
            if (cleanInfo != nil && cleanInfo[key] != nil) {
                return cleanInfo[key];
            }
            if (rawInfo[key] != nil) {
                return nil;
            }
        }
    }
    return [self pm_ps_objectForInfoDictionaryKey:key];
}

static BOOL ps_is_embedded_mobileprovision_query(NSString *name, NSString *ext, NSString *subpath) {
    if (subpath != nil && subpath.length > 0) {
        return NO;
    }
    if ([name isEqualToString:@"embedded"]) {
        return (ext != nil &&
                ([ext isEqualToString:@"mobileprovision"] ||
                 [ext isEqualToString:@".mobileprovision"]));
    }
    if ([name isEqualToString:@"embedded.mobileprovision"]) {
        return (ext == nil || ext.length == 0);
    }
    return NO;
}

static NSString *ps_virtual_mobileprovision_path_if_applicable(NSBundle *bundle,
                                                               NSString *name,
                                                               NSString *ext,
                                                               NSString *subpath,
                                                               const void *caller) {
    if (bundle != [NSBundle mainBundle] ||
        !ps_is_embedded_mobileprovision_query(name, ext, subpath) ||
        !pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(caller) ||
        !pt_has_backup_mobileprovision()) {
        return nil;
    }
    char vbuf[PATH_MAX];
    const char *vpath = pt_copy_virtual_mobileprovision_path(vbuf, sizeof(vbuf));
    if (vpath == NULL || vpath[0] == '\0') {
        return nil;
    }
    return [NSString stringWithUTF8String:vpath];
}

- (NSString *) pm_ps_pathForResource:(NSString *)name ofType:(NSString *)ext {
    const void *caller = __builtin_return_address(0);
    NSString *res = [self pm_ps_pathForResource:name ofType:ext];
    if (res == nil) {
        return ps_virtual_mobileprovision_path_if_applicable((NSBundle *)self, name, ext, nil, caller);
    }
    if (ps_is_hidden_path(ps_strip_iossupport_nsstring(res), caller)) {
        return nil;
    }
    return ps_virtualize_bundle_path_for_caller(res, caller);
}

- (NSString *) pm_ps_pathForResource:(NSString *)name ofType:(NSString *)ext inDirectory:(NSString *)subpath {
    const void *caller = __builtin_return_address(0);
    NSString *res = [self pm_ps_pathForResource:name ofType:ext inDirectory:subpath];
    if (res == nil) {
        return ps_virtual_mobileprovision_path_if_applicable((NSBundle *)self, name, ext, subpath, caller);
    }
    if (ps_is_hidden_path(ps_strip_iossupport_nsstring(res), caller)) {
        return nil;
    }
    return ps_virtualize_bundle_path_for_caller(res, caller);
}

- (NSString *) pm_ps_pathForResource:(NSString *)name ofType:(NSString *)ext inDirectory:(NSString *)subpath forLocalization:(NSString *)localizationName {
    const void *caller = __builtin_return_address(0);
    NSString *res = [self pm_ps_pathForResource:name ofType:ext inDirectory:subpath forLocalization:localizationName];
    if (res == nil) {
        return ps_virtual_mobileprovision_path_if_applicable((NSBundle *)self, name, ext, subpath, caller);
    }
    if (ps_is_hidden_path(ps_strip_iossupport_nsstring(res), caller)) {
        return nil;
    }
    return ps_virtualize_bundle_path_for_caller(res, caller);
}

+ (NSString *) pm_ps_cls_pathForResource:(NSString *)name ofType:(NSString *)ext inDirectory:(NSString *)bundlePath {
    const void *caller = __builtin_return_address(0);
    if (ps_is_hidden_path(bundlePath, caller)) {
        return nil;
    }
    NSString *resolved = ps_resolve_virtual_nsstring_path(bundlePath);
    if (resolved != bundlePath && ps_is_hidden_path(ps_strip_iossupport_nsstring(resolved), caller)) {
        return nil;
    }
    NSString *res = [self pm_ps_cls_pathForResource:name ofType:ext inDirectory:resolved];
    if (ps_is_hidden_path(ps_strip_iossupport_nsstring(res), caller)) {
        return nil;
    }
    return ps_virtualize_bundle_path_for_caller(res, caller);
}

- (NSURL *) pm_ps_URLForResource:(NSString *)name withExtension:(NSString *)ext {
    const void *caller = __builtin_return_address(0);
    NSURL *res = [self pm_ps_URLForResource:name withExtension:ext];
    if (res == nil) {
        NSString *vpath = ps_virtual_mobileprovision_path_if_applicable((NSBundle *)self, name, ext, nil, caller);
        return (vpath != nil) ? [NSURL fileURLWithPath:vpath isDirectory:NO] : nil;
    }
    if ([res isFileURL] && ps_is_hidden_path(ps_strip_iossupport_nsstring(res.path), caller)) {
        return nil;
    }
    return ps_virtualize_bundle_url_for_caller(res, caller);
}

- (NSURL *) pm_ps_URLForResource:(NSString *)name withExtension:(NSString *)ext subdirectory:(NSString *)subpath {
    const void *caller = __builtin_return_address(0);
    NSURL *res = [self pm_ps_URLForResource:name withExtension:ext subdirectory:subpath];
    if (res == nil) {
        NSString *vpath = ps_virtual_mobileprovision_path_if_applicable((NSBundle *)self, name, ext, subpath, caller);
        return (vpath != nil) ? [NSURL fileURLWithPath:vpath isDirectory:NO] : nil;
    }
    if ([res isFileURL] && ps_is_hidden_path(ps_strip_iossupport_nsstring(res.path), caller)) {
        return nil;
    }
    return ps_virtualize_bundle_url_for_caller(res, caller);
}

- (NSURL *) pm_ps_URLForResource:(NSString *)name withExtension:(NSString *)ext subdirectory:(NSString *)subpath localization:(NSString *)localizationName {
    const void *caller = __builtin_return_address(0);
    NSURL *res = [self pm_ps_URLForResource:name withExtension:ext subdirectory:subpath localization:localizationName];
    if (res == nil) {
        NSString *vpath = ps_virtual_mobileprovision_path_if_applicable((NSBundle *)self, name, ext, subpath, caller);
        return (vpath != nil) ? [NSURL fileURLWithPath:vpath isDirectory:NO] : nil;
    }
    if ([res isFileURL] && ps_is_hidden_path(ps_strip_iossupport_nsstring(res.path), caller)) {
        return nil;
    }
    return ps_virtualize_bundle_url_for_caller(res, caller);
}

+ (NSURL *) pm_ps_URLForResource:(NSString *)name withExtension:(NSString *)ext subdirectory:(NSString *)subpath inBundleWithURL:(NSURL *)bundleURL {
    const void *caller = __builtin_return_address(0);
    if (bundleURL != nil && [bundleURL isFileURL] && ps_is_hidden_path(bundleURL.path, caller)) {
        return nil;
    }
    NSURL *resolved = ps_resolve_virtual_nsurl(bundleURL);
    if (resolved != bundleURL && resolved != nil && [resolved isFileURL] &&
        ps_is_hidden_path(ps_strip_iossupport_nsstring(resolved.path), caller)) {
        return nil;
    }
    NSURL *res = [self pm_ps_URLForResource:name withExtension:ext subdirectory:subpath inBundleWithURL:resolved];
    if (res != nil && [res isFileURL] && ps_is_hidden_path(ps_strip_iossupport_nsstring(res.path), caller)) {
        return nil;
    }
    return ps_virtualize_bundle_url_for_caller(res, caller);
}

- (NSArray<NSString *> *) pm_ps_pathsForResourcesOfType:(NSString *)ext inDirectory:(NSString *)subpath {
    const void *caller = __builtin_return_address(0);
    return ps_filter_and_virtualize_bundle_paths([self pm_ps_pathsForResourcesOfType:ext inDirectory:subpath], caller);
}

+ (NSArray<NSString *> *) pm_ps_cls_pathsForResourcesOfType:(NSString *)ext inDirectory:(NSString *)bundlePath {
    const void *caller = __builtin_return_address(0);
    if (ps_is_hidden_path(bundlePath, caller)) {
        return @[];
    }
    NSString *resolved = ps_resolve_virtual_nsstring_path(bundlePath);
    if (resolved != bundlePath && ps_is_hidden_path(ps_strip_iossupport_nsstring(resolved), caller)) {
        return @[];
    }
    return ps_filter_and_virtualize_bundle_paths([self pm_ps_cls_pathsForResourcesOfType:ext inDirectory:resolved], caller);
}

- (NSArray<NSURL *> *) pm_ps_URLsForResourcesWithExtension:(NSString *)ext subdirectory:(NSString *)subpath {
    const void *caller = __builtin_return_address(0);
    return ps_filter_and_virtualize_bundle_urls([self pm_ps_URLsForResourcesWithExtension:ext subdirectory:subpath], caller);
}

- (NSArray<NSURL *> *) pm_ps_URLsForResourcesWithExtension:(NSString *)ext subdirectory:(NSString *)subpath localization:(NSString *)localizationName {
    const void *caller = __builtin_return_address(0);
    return ps_filter_and_virtualize_bundle_urls([self pm_ps_URLsForResourcesWithExtension:ext subdirectory:subpath localization:localizationName], caller);
}

+ (NSArray<NSURL *> *) pm_ps_URLsForResourcesWithExtension:(NSString *)ext subdirectory:(NSString *)subpath inBundleWithURL:(NSURL *)bundleURL {
    const void *caller = __builtin_return_address(0);
    if (bundleURL != nil && [bundleURL isFileURL] && ps_is_hidden_path(bundleURL.path, caller)) {
        return @[];
    }
    NSURL *resolved = ps_resolve_virtual_nsurl(bundleURL);
    if (resolved != bundleURL && resolved != nil && [resolved isFileURL] &&
        ps_is_hidden_path(ps_strip_iossupport_nsstring(resolved.path), caller)) {
        return @[];
    }
    return ps_filter_and_virtualize_bundle_urls([self pm_ps_URLsForResourcesWithExtension:ext subdirectory:subpath inBundleWithURL:resolved], caller);
}

- (NSString *) pm_ps_bundle_description {
    const void *caller = __builtin_return_address(0);
    NSString *origDesc = [self pm_ps_bundle_description];
    if (origDesc.length > 0 && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        NSString *realBundlePath = [self pm_ps_bundlePath];
        if (realBundlePath.length > 0) {
            NSString *virtBundlePath = ps_virtualize_nsstring_path_for_app(realBundlePath, YES);
            if (virtBundlePath.length > 0 && ![virtBundlePath isEqualToString:realBundlePath]) {
                return [origDesc stringByReplacingOccurrencesOfString:realBundlePath withString:virtBundlePath];
            }
        }
    }
    return origDesc;
}

static NSMutableDictionary *ps_sanitized_system_version_mutable_dict(NSDictionary *dict) {
    if (dict == nil) {
        return nil;
    }
    NSMutableDictionary *modified = [dict mutableCopy];
    pt_sanitize_system_version_dict(modified);
    return modified;
}

+ (NSDictionary *) pm_dictionaryWithContentsOfFile:(NSString *)path {
    const void *caller = __builtin_return_address(0);
    if (ps_is_hidden_path(path, caller)) {
        return nil;
    }
    NSString *resolved = ps_resolve_virtual_nsstring_path(path);
    if (resolved != path && ps_is_hidden_path(ps_strip_iossupport_nsstring(resolved), caller)) {
        return nil;
    }
    BOOL usedBackup = NO;
    if (resolved.length > 0) {
        const char *resolvedC = [resolved fileSystemRepresentation];
        if (resolvedC != NULL) {
            char backupBuf[PATH_MAX];
            int isSysCaller = -1;
            const char *backup = pt_lookup_app_backup_redirect_for_caller(
                resolvedC, caller, backupBuf, sizeof(backupBuf), &isSysCaller);
            if (backup != NULL) {
                CFStringRef cfBackup = CFStringCreateWithFileSystemRepresentation(kCFAllocatorDefault, backup);
                if (cfBackup != NULL) {
                    resolved = (__bridge_transfer NSString *)cfBackup;
                    usedBackup = YES;
                }
            }
        }
    }
    NSDictionary *dict = nil;
    if (usedBackup) {
        pt_enter_internal_scope();
        dict = [self pm_dictionaryWithContentsOfFile:resolved];
        pt_leave_internal_scope();
    } else {
        dict = [self pm_dictionaryWithContentsOfFile:resolved];
    }
    if (dict != nil && pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(caller)) {
        BOOL wantMutable = [self isSubclassOfClass:[NSMutableDictionary class]];
        if ([resolved hasSuffix:@"/SystemVersion.plist"] || pt_is_system_version_plist_dict(dict)) {
            NSMutableDictionary *modified = ps_sanitized_system_version_mutable_dict(dict);
            return wantMutable ? modified : [modified copy];
        }
        if (pt_is_info_plist_dict(dict) && pt_info_dict_needs_sanitize(dict)) {
            NSMutableDictionary *modified = pt_build_sanitized_mutable_info_dict(dict);
            if (!wantMutable && [modified[@"CFBundleSupportedPlatforms"] isKindOfClass:[NSMutableArray class]]) {
                modified[@"CFBundleSupportedPlatforms"] = [modified[@"CFBundleSupportedPlatforms"] copy];
            }
            return wantMutable ? modified : [modified copy];
        }
    }
    return dict;
}

+ (NSDictionary *) pm_dictionaryWithContentsOfURL:(NSURL *)url {
    const void *caller = __builtin_return_address(0);
    if (url != nil && [url isFileURL] && ps_is_hidden_path(url.path, caller)) {
        return nil;
    }
    NSURL *resolved = ps_resolve_virtual_nsurl(url);
    if (resolved != url && resolved != nil && [resolved isFileURL] &&
        ps_is_hidden_path(ps_strip_iossupport_nsstring(resolved.path), caller)) {
        return nil;
    }
    BOOL usedBackup = NO;
    if (resolved != nil && [resolved isFileURL]) {
        char resolvedC[PATH_MAX];
        if (CFURLGetFileSystemRepresentation((__bridge CFURLRef)resolved, true, (UInt8 *)resolvedC, sizeof(resolvedC))) {
            char backupBuf[PATH_MAX];
            int isSysCaller = -1;
            const char *backup = pt_lookup_app_backup_redirect_for_caller(
                resolvedC, caller, backupBuf, sizeof(backupBuf), &isSysCaller);
            if (backup != NULL) {
                CFURLRef cfBackupURL = CFURLCreateFromFileSystemRepresentation(
                    kCFAllocatorDefault, (const UInt8 *)backup, (CFIndex)strlen(backup), false);
                if (cfBackupURL != NULL) {
                    resolved = (__bridge_transfer NSURL *)cfBackupURL;
                    usedBackup = YES;
                }
            }
        }
    }
    NSDictionary *dict = nil;
    if (usedBackup) {
        pt_enter_internal_scope();
        dict = [self pm_dictionaryWithContentsOfURL:resolved];
        pt_leave_internal_scope();
    } else {
        dict = [self pm_dictionaryWithContentsOfURL:resolved];
    }
    if (dict != nil && pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(caller)) {
        BOOL wantMutable = [self isSubclassOfClass:[NSMutableDictionary class]];
        if ([resolved.path hasSuffix:@"/SystemVersion.plist"] || pt_is_system_version_plist_dict(dict)) {
            NSMutableDictionary *modified = ps_sanitized_system_version_mutable_dict(dict);
            return wantMutable ? modified : [modified copy];
        }
        if (pt_is_info_plist_dict(dict) && pt_info_dict_needs_sanitize(dict)) {
            NSMutableDictionary *modified = pt_build_sanitized_mutable_info_dict(dict);
            if (!wantMutable && [modified[@"CFBundleSupportedPlatforms"] isKindOfClass:[NSMutableArray class]]) {
                modified[@"CFBundleSupportedPlatforms"] = [modified[@"CFBundleSupportedPlatforms"] copy];
            }
            return wantMutable ? modified : [modified copy];
        }
    }
    return dict;
}

+ (id) pm_propertyListWithData:(NSData *)data options:(NSPropertyListReadOptions)opt format:(NSPropertyListFormat *)format error:(NSError **)error {
    id plist = [self pm_propertyListWithData:data options:opt format:format error:error];
    if ([plist isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)plist;
        BOOL isSysVer = pt_is_system_version_plist_dict(dict);
        BOOL isCodeRes = ([dict[@"files"] isKindOfClass:[NSDictionary class]] ||
                          [dict[@"files2"] isKindOfClass:[NSDictionary class]]);
        BOOL isInfoPlist = (!isSysVer && !isCodeRes &&
                            pt_is_info_plist_dict(dict) &&
                            pt_info_dict_needs_sanitize(dict));
        if ((isSysVer || isCodeRes || isInfoPlist) &&
            pt_is_bypass_enabled() &&
            !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
            BOOL wantMutableContainers = ((opt & (NSPropertyListMutableContainers | NSPropertyListMutableContainersAndLeaves)) != 0);
            if (isSysVer) {
                NSMutableDictionary *modified = ps_sanitized_system_version_mutable_dict(dict);
                if (!wantMutableContainers) {
                    return [modified copy];
                }
                return modified;
            }
            if (isCodeRes) {
                NSMutableDictionary *modified = nil;
                for (NSString *subKey in @[@"files", @"files2"]) {
                    NSDictionary *sub = dict[subKey];
                    if ([sub isKindOfClass:[NSDictionary class]]) {
                        NSMutableDictionary *cleanSub = nil;
                        for (id kObj in sub) {
                            if ([kObj isKindOfClass:[NSString class]]) {
                                NSString *k = (NSString *)kObj;
                                if ([k containsString:@"PlayTools"] ||
                                    [k containsString:@"AKInterface"] ||
                                    [k containsString:@"Playtools.strings"] ||
                                    [k containsString:@"UserPlugins"]) {
                                    if (cleanSub == nil) cleanSub = [sub mutableCopy];
                                    [cleanSub removeObjectForKey:kObj];
                                }
                            }
                        }
                        if (cleanSub != nil) {
                            if (modified == nil) modified = [dict mutableCopy];
                            modified[subKey] = wantMutableContainers ? cleanSub : [cleanSub copy];
                        }
                    }
                }
                if (modified != nil) {
                    if (!wantMutableContainers) {
                        return [modified copy];
                    }
                    return modified;
                }
            }
            if (isInfoPlist) {
                NSMutableDictionary *modified = pt_build_sanitized_mutable_info_dict(dict);
                if (modified != nil) {
                    if (!wantMutableContainers &&
                        [modified[@"CFBundleSupportedPlatforms"] isKindOfClass:[NSMutableArray class]]) {
                        modified[@"CFBundleSupportedPlatforms"] = [modified[@"CFBundleSupportedPlatforms"] copy];
                    }
                    return wantMutableContainers ? modified : [modified copy];
                }
            }
        }
    }
    return plist;
}

- (bool) pm_return_false {
    return false;
}

- (bool) pm_return_true {
    return true;
}

- (BOOL) pm_return_yes {
    return YES;
}

- (BOOL) pm_return_no {
    return NO;
}

- (int) pm_return_0 {
    return 0;
}

- (int) pm_return_1 {
    return 1;
}

- (id) pm_return_null {
    return nil;
}

- (NSString *) pm_return_empty {
    return @"";
}

- (NSDictionary *) pm_return_empty_dictionary {
    return @{};
}

- (BOOL) pm_isMacCatalystApp {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NO;
    }
    return [self pm_isMacCatalystApp];
}

- (BOOL) pm_swift_isMacCatalystApp {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NO;
    }
    return [self pm_swift_isMacCatalystApp];
}

- (BOOL) pm_isiOSAppOnMac {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NO;
    }
    return [self pm_isiOSAppOnMac];
}

- (BOOL) pm_swift_isiOSAppOnMac {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NO;
    }
    return [self pm_swift_isiOSAppOnMac];
}

- (BOOL) pm_isiOSAppOnVision_no {
    return NO;
}

- (BOOL) pm_swift_isiOSAppOnVision_no {
    return NO;
}

- (BOOL) pm_macCatalystVersionIsAtLeastVersion:(NSOperatingSystemVersion)version {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NO;
    }
    return [self pm_macCatalystVersionIsAtLeastVersion:version];
}

- (BOOL) pm_swift_macCatalystVersionIsAtLeastVersion:(NSOperatingSystemVersion)version {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NO;
    }
    return [self pm_swift_macCatalystVersionIsAtLeastVersion:version];
}

- (NSUInteger) pm_pi_processorCount {
    if (!pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return [self pm_pi_processorCount];
    }
    uint32_t cores = pt_get_spoofed_cpu_cores();
    return (NSUInteger)(cores > 0 ? cores : 8);
}

- (NSUInteger) pm_swift_pi_processorCount {
    if (!pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return [self pm_swift_pi_processorCount];
    }
    uint32_t cores = pt_get_spoofed_cpu_cores();
    return (NSUInteger)(cores > 0 ? cores : 8);
}

- (NSUInteger) pm_pi_activeProcessorCount {
    if (!pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return [self pm_pi_activeProcessorCount];
    }
    uint32_t cores = pt_get_spoofed_cpu_cores();
    return (NSUInteger)(cores > 0 ? cores : 8);
}

- (NSUInteger) pm_swift_pi_activeProcessorCount {
    if (!pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return [self pm_swift_pi_activeProcessorCount];
    }
    uint32_t cores = pt_get_spoofed_cpu_cores();
    return (NSUInteger)(cores > 0 ? cores : 8);
}

- (unsigned long long) pm_pi_physicalMemory {
    if (!pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return [self pm_pi_physicalMemory];
    }
    uint64_t mem = pt_get_spoofed_physical_memory();
    if (mem > 0) {
        return (unsigned long long)mem;
    }
    return [self pm_pi_physicalMemory];
}

- (unsigned long long) pm_swift_pi_physicalMemory {
    if (!pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return [self pm_swift_pi_physicalMemory];
    }
    uint64_t mem = pt_get_spoofed_physical_memory();
    if (mem > 0) {
        return (unsigned long long)mem;
    }
    return [self pm_swift_pi_physicalMemory];
}

__attribute__((visibility("hidden"))) BOOL ps_get_cached_ios_sysver(NSOperatingSystemVersion *outVer, NSString * __autoreleasing *outVerString) {
    const char *ovBuild = NULL;
    const char *ovVer = pt_get_reported_ios_version_override(&ovBuild);
    if (ovVer != NULL) {
        int maj = 0, min = 0, pat = 0;
        if (sscanf(ovVer, "%d.%d.%d", &maj, &min, &pat) >= 1 && maj > 0) {
            if (outVer != NULL) {
                *outVer = (NSOperatingSystemVersion){ maj, min, pat };
            }
            if (outVerString != NULL) {
                NSString *verStr = [NSString stringWithUTF8String:ovVer];
                if (ovBuild != NULL && ovBuild[0] != '\0') {
                    NSString *buildStr = [NSString stringWithUTF8String:ovBuild];
                    *outVerString = [NSString stringWithFormat:@"Version %@ (Build %@)",
                                     verStr ?: @"18.3", buildStr ?: @"22D63"];
                } else {
                    *outVerString = [NSString stringWithFormat:@"Version %@", verStr ?: @"18.3"];
                }
            }
            return YES;
        }
    }
    static NSOperatingSystemVersion s_iosVer = {0, 0, 0};
    static BOOL s_hasParsedVer = NO;
    static NSString *s_fullVerString = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *sysVer = [NSDictionary dictionaryWithContentsOfFile:@"/System/Library/CoreServices/SystemVersion.plist"];
        NSString *verStr = nil;
        NSString *iosVer = sysVer[@"iOSSupportVersion"];
        if (!([iosVer isKindOfClass:[NSString class]] && iosVer.length > 0)) {
            const char *fallbackCStr = pt_get_spoofed_ios_version_cstr();
            if (fallbackCStr != NULL && fallbackCStr[0] != '\0') {
                iosVer = [NSString stringWithUTF8String:fallbackCStr];
            }
        }
        if ([iosVer isKindOfClass:[NSString class]] && iosVer.length > 0) {
            verStr = [iosVer copy];
            NSArray<NSString *> *parts = [iosVer componentsSeparatedByString:@"."];
            if (parts.count >= 1) {
                s_iosVer.majorVersion = [parts[0] integerValue];
                s_iosVer.minorVersion = (parts.count >= 2) ? [parts[1] integerValue] : 0;
                s_iosVer.patchVersion = (parts.count >= 3) ? [parts[2] integerValue] : 0;
                s_hasParsedVer = (s_iosVer.majorVersion > 0);
            }
        }
        NSString *buildStr = sysVer[@"ProductBuildVersion"];
        if ([buildStr isKindOfClass:[NSString class]] && buildStr.length > 0) {
            char sanitizedBuild[64] = {0};
            if (pt_sanitize_ios_build_version_cstr(buildStr.UTF8String,
                                                   verStr.UTF8String,
                                                   sanitizedBuild,
                                                   sizeof(sanitizedBuild))) {
                NSString *mapped = [NSString stringWithUTF8String:sanitizedBuild];
                if (mapped.length > 0) {
                    buildStr = mapped;
                }
            }
        } else {
            buildStr = nil;
        }
        if (verStr.length > 0) {
            s_fullVerString = (buildStr.length > 0)
                ? [NSString stringWithFormat:@"Version %@ (Build %@)", verStr, buildStr]
                : [NSString stringWithFormat:@"Version %@", verStr];
        }
    });
    if (outVer != NULL && s_hasParsedVer) {
        *outVer = s_iosVer;
    }
    if (outVerString != NULL) {
        *outVerString = s_fullVerString;
    }
    return s_hasParsedVer;
}

static NSString *ps_spoofed_os_version_string(NSProcessInfo *pi) {
    NSString *cached = nil;
    ps_get_cached_ios_sysver(NULL, &cached);
    if (cached.length > 0) {
        return cached;
    }
    NSOperatingSystemVersion ver = [pi operatingSystemVersion];
    NSString *verStr = (ver.patchVersion > 0)
        ? [NSString stringWithFormat:@"%ld.%ld.%ld", (long)ver.majorVersion, (long)ver.minorVersion, (long)ver.patchVersion]
        : [NSString stringWithFormat:@"%ld.%ld", (long)ver.majorVersion, (long)ver.minorVersion];
    return [NSString stringWithFormat:@"Version %@", verStr];
}

static BOOL ps_os_version_at_least(NSOperatingSystemVersion cur, NSOperatingSystemVersion target) {
    if (cur.majorVersion != target.majorVersion) {
        return cur.majorVersion > target.majorVersion;
    }
    if (cur.minorVersion != target.minorVersion) {
        return cur.minorVersion > target.minorVersion;
    }
    return cur.patchVersion >= target.patchVersion;
}

static NSString *ps_cached_bundle_executable_name(void) {
    static NSString *s_execName = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        id val = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleExecutable"];
        if ([val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) {
            s_execName = [(NSString *)val copy];
        }
    });
    return s_execName;
}

static NSString *ps_sanitize_process_name(NSString *orig) {
    if (orig.length > 0 &&
        ([orig rangeOfString:@"PlayCover" options:NSCaseInsensitiveSearch].location == NSNotFound) &&
        ([orig rangeOfString:@"MacOver" options:NSCaseInsensitiveSearch].location == NSNotFound) &&
        ([orig rangeOfString:@"PlayTools" options:NSCaseInsensitiveSearch].location == NSNotFound)) {
        return orig;
    }
    return ps_cached_bundle_executable_name() ?: orig;
}

- (NSString *) pm_ps_operatingSystemVersionString {
    if (pt_is_bypass_enabled() &&
        pt_is_availability_app_caller(__builtin_return_address(0))) {
        return ps_spoofed_os_version_string((NSProcessInfo *)self);
    }
    return [self pm_ps_operatingSystemVersionString];
}

- (NSString *) pm_ps_swift_operatingSystemVersionString {
    if (pt_is_bypass_enabled() &&
        pt_is_availability_app_caller(__builtin_return_address(0))) {
        return ps_spoofed_os_version_string((NSProcessInfo *)self);
    }
    return [self pm_ps_swift_operatingSystemVersionString];
}

- (NSOperatingSystemVersion) pm_ps_operatingSystemVersion {
    if (pt_is_bypass_enabled() &&
        pt_is_availability_app_caller(__builtin_return_address(0))) {
        NSOperatingSystemVersion ver = {0, 0, 0};
        if (ps_get_cached_ios_sysver(&ver, NULL)) {
            return ver;
        }
    }
    return [self pm_ps_operatingSystemVersion];
}

- (NSOperatingSystemVersion) pm_ps_swift_operatingSystemVersion {
    if (pt_is_bypass_enabled() &&
        pt_is_availability_app_caller(__builtin_return_address(0))) {
        NSOperatingSystemVersion ver = {0, 0, 0};
        if (ps_get_cached_ios_sysver(&ver, NULL)) {
            return ver;
        }
    }
    return [self pm_ps_swift_operatingSystemVersion];
}

- (BOOL) pm_ps_isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion)version {
    if (pt_is_bypass_enabled() &&
        pt_is_availability_app_caller(__builtin_return_address(0))) {
        NSOperatingSystemVersion ver = {0, 0, 0};
        if (ps_get_cached_ios_sysver(&ver, NULL)) {
            return ps_os_version_at_least(ver, version);
        }
    }
    return [self pm_ps_isOperatingSystemAtLeastVersion:version];
}

- (BOOL) pm_ps_swift_isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion)version {
    if (pt_is_bypass_enabled() &&
        pt_is_availability_app_caller(__builtin_return_address(0))) {
        NSOperatingSystemVersion ver = {0, 0, 0};
        if (ps_get_cached_ios_sysver(&ver, NULL)) {
            return ps_os_version_at_least(ver, version);
        }
    }
    return [self pm_ps_swift_isOperatingSystemAtLeastVersion:version];
}

- (NSString *) pm_ps_processName {
    NSString *orig = [self pm_ps_processName];
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_sanitize_process_name(orig);
    }
    return orig;
}

- (NSString *) pm_ps_swift_processName {
    NSString *orig = [self pm_ps_swift_processName];
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_sanitize_process_name(orig);
    }
    return orig;
}

- (BOOL) pm_ps_isLowPowerModeEnabled {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NO;
    }
    return [self pm_ps_isLowPowerModeEnabled];
}

- (BOOL) pm_ps_swift_isLowPowerModeEnabled {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NO;
    }
    return [self pm_ps_swift_isLowPowerModeEnabled];
}

- (NSProcessInfoThermalState) pm_ps_thermalState {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NSProcessInfoThermalStateNominal;
    }
    return [self pm_ps_thermalState];
}

- (NSProcessInfoThermalState) pm_ps_swift_thermalState {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NSProcessInfoThermalStateNominal;
    }
    return [self pm_ps_swift_thermalState];
}


static BOOL ps_is_hidden_user_default_key(NSString *key) {
    if (key == nil || key.length == 0) {
        return NO;
    }
    if ([key isEqualToString:@"playtoolsKeymappingDisabledAt"]) {
        return YES;
    }
    const char *ckey = [key UTF8String];
    return (ckey != NULL && pt_is_hidden_macos_pref_key(ckey));
}

static BOOL ps_user_default_val_leaks_host_user_depth(id val, int depth) {
    if (val == nil || depth > 3) {
        return NO;
    }
    if ([val isKindOfClass:[NSString class]]) {
        return [(NSString *)val containsString:@"/Users/"];
    }
    if ([val isKindOfClass:[NSURL class]]) {
        NSString *p = [(NSURL *)val path];
        return (p != nil && [p containsString:@"/Users/"]);
    }
    if ([val isKindOfClass:[NSArray class]]) {
        for (id elem in (NSArray *)val) {
            if (ps_user_default_val_leaks_host_user_depth(elem, depth + 1)) {
                return YES;
            }
        }
        return NO;
    }
    if ([val isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)val;
        for (id k in d) {
            if (ps_user_default_val_leaks_host_user_depth(k, depth + 1) ||
                ps_user_default_val_leaks_host_user_depth(d[k], depth + 1)) {
                return YES;
            }
        }
        return NO;
    }
    return NO;
}

static BOOL ps_user_default_val_leaks_host_user(id val) {
    return ps_user_default_val_leaks_host_user_depth(val, 0);
}

static NSDictionary<NSString *, id> *ps_sanitize_user_defaults_dict(NSDictionary<NSString *, id> *dict) {
    if (dict == nil || dict.count == 0) {
        return dict;
    }
    NSMutableDictionary<NSString *, id> *filtered = nil;
    for (NSString *k in dict) {
        id v = dict[k];
        if (ps_is_hidden_user_default_key(k) || ps_user_default_val_leaks_host_user(v)) {
            if (filtered == nil) {
                filtered = [dict mutableCopy];
            }
            [filtered removeObjectForKey:k];
        }
    }
    return (filtered != nil) ? [filtered copy] : dict;
}

- (id) pm_ps_objectForKey:(NSString *)defaultName {
    const void *caller = __builtin_return_address(0);
    BOOL isAppCaller = pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller);
    if (isAppCaller && ps_is_hidden_user_default_key(defaultName)) {
        return nil;
    }
    id val = [self pm_ps_objectForKey:defaultName];
    if (isAppCaller && ps_user_default_val_leaks_host_user(val)) {
        return nil;
    }
    return val;
}

- (NSDictionary<NSString *, id> *) pm_ps_dictionaryRepresentation {
    NSDictionary<NSString *, id> *dict = [self pm_ps_dictionaryRepresentation];
    if (dict != nil &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_sanitize_user_defaults_dict(dict);
    }
    return dict;
}

- (NSDictionary<NSString *, id> *) pm_ps_persistentDomainForName:(NSString *)domainName {
    NSDictionary<NSString *, id> *dict = [self pm_ps_persistentDomainForName:domainName];
    if (dict != nil &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_sanitize_user_defaults_dict(dict);
    }
    return dict;
}

- (NSDictionary<NSString *, id> *) pm_ps_volatileDomainForName:(NSString *)domainName {
    NSDictionary<NSString *, id> *dict = [self pm_ps_volatileDomainForName:domainName];
    if (dict != nil &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_sanitize_user_defaults_dict(dict);
    }
    return dict;
}

static const void *ps_internal_overlay_tag_key(void) {
    static const void *s_key = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_key = (const void *)(uintptr_t)[PlaySettings pm_internalOverlayTagKeyAddress];
    });
    return s_key;
}

static BOOL ps_class_belongs_to_playtools_image(Class cls) {
    if (cls == Nil) {
        return NO;
    }
    static os_unfair_lock s_clsCacheLock = OS_UNFAIR_LOCK_INIT;
    static CFMutableDictionaryRef s_clsCache = NULL;
    os_unfair_lock_lock(&s_clsCacheLock);
    if (s_clsCache != NULL) {
        const void *cached = CFDictionaryGetValue(s_clsCache, (__bridge const void *)cls);
        if (cached != NULL) {
            os_unfair_lock_unlock(&s_clsCacheLock);
            return ((uintptr_t)cached == 2);
        }
    }
    os_unfair_lock_unlock(&s_clsCacheLock);

    static const char *s_ptPath = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_ptPath = dyld_image_path_containing_address((__bridge const void *)[PlayShadowLoader class]);
    });
    if (s_ptPath == NULL) {
        return NO;
    }
    const char *clsPath = dyld_image_path_containing_address((__bridge const void *)cls);
    if (clsPath == NULL) {
        Class superCls = class_getSuperclass(cls);
        if (superCls != Nil) {
            clsPath = dyld_image_path_containing_address((__bridge const void *)superCls);
        }
    }
    BOOL isPT = (clsPath != NULL && strcmp(clsPath, s_ptPath) == 0);

    os_unfair_lock_lock(&s_clsCacheLock);
    if (s_clsCache == NULL) {
        s_clsCache = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
    }
    if (s_clsCache != NULL && CFDictionaryGetCount(s_clsCache) < 4096) {
        CFDictionarySetValue(s_clsCache, (__bridge const void *)cls, (const void *)(uintptr_t)(isPT ? 2 : 1));
    }
    os_unfair_lock_unlock(&s_clsCacheLock);
    return isPT;
}

static BOOL ps_is_internal_playtools_view(UIView *view) {
    if (view == nil) {
        return NO;
    }
    const void *tagKey = ps_internal_overlay_tag_key();
    if (tagKey != NULL && objc_getAssociatedObject(view, tagKey) != nil) {
        return YES;
    }
    if (ps_class_belongs_to_playtools_image(object_getClass(view))) {
        return YES;
    }
    UIResponder *next = [view nextResponder];
    if ([next isKindOfClass:[UIViewController class]] &&
        ps_class_belongs_to_playtools_image(object_getClass(next))) {
        return YES;
    }
    return NO;
}

static BOOL ps_is_internal_playtools_window(UIWindow *window) {
    if (window == nil) {
        return NO;
    }
    if (ps_is_internal_playtools_view(window)) {
        return YES;
    }
    UIViewController *rootVC = window.rootViewController;
    if (rootVC != nil && ps_class_belongs_to_playtools_image(object_getClass(rootVC))) {
        return YES;
    }
    return NO;
}

- (NSArray<__kindof UIView *> *) pm_ps_subviews {
    NSArray<UIView *> *orig = [self pm_ps_subviews];
    if (orig.count == 0 || !pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return orig;
    }
    NSMutableArray<UIView *> *filtered = nil;
    for (NSUInteger i = 0; i < orig.count; i++) {
        UIView *sub = orig[i];
        if (ps_is_internal_playtools_view(sub)) {
            if (filtered == nil) {
                filtered = [NSMutableArray arrayWithCapacity:orig.count - 1];
                for (NSUInteger j = 0; j < i; j++) {
                    [filtered addObject:orig[j]];
                }
            }
        } else if (filtered != nil) {
            [filtered addObject:sub];
        }
    }
    return filtered != nil ? [filtered copy] : orig;
}

static NSArray<UIWindow *> *ps_filter_windows_array(NSArray<UIWindow *> *orig, const void *caller) {
    if (orig.count == 0 || !pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(caller)) {
        return orig;
    }
    NSMutableArray<UIWindow *> *filtered = nil;
    for (NSUInteger i = 0; i < orig.count; i++) {
        UIWindow *win = orig[i];
        if (ps_is_internal_playtools_window(win)) {
            if (filtered == nil) {
                filtered = [NSMutableArray arrayWithCapacity:orig.count - 1];
                for (NSUInteger j = 0; j < i; j++) {
                    [filtered addObject:orig[j]];
                }
            }
        } else if (filtered != nil) {
            [filtered addObject:win];
        }
    }
    return filtered != nil ? [filtered copy] : orig;
}

- (NSArray<UIWindow *> *) pm_ps_app_windows {
    return ps_filter_windows_array([self pm_ps_app_windows], __builtin_return_address(0));
}

- (NSArray<UIWindow *> *) pm_ps_scene_windows {
    return ps_filter_windows_array([self pm_ps_scene_windows], __builtin_return_address(0));
}

- (id) pm_ps_scene_titlebar {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return nil;
    }
    return [self pm_ps_scene_titlebar];
}

- (id) pm_ps_scene_sizeRestrictions {
    if (pt_is_bypass_enabled() &&
        (ps_is_iphone_device_model() || pt_is_compat13_7_active()) &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return nil;
    }
    return [self pm_ps_scene_sizeRestrictions];
}

- (BOOL) pm_ps_app_supportsMultipleScenes {
    if (pt_is_bypass_enabled() &&
        ps_is_iphone_device_model() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NO;
    }
    return [self pm_ps_app_supportsMultipleScenes];
}

- (id) pm_ps_menuBuilder_menuForIdentifier:(NSString *)identifier {
    if (identifier.length > 0 &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        [identifier hasPrefix:@"com.apple.menu.application.ext"]) {
        return nil;
    }
    return [self pm_ps_menuBuilder_menuForIdentifier:identifier];
}

static NSDictionary *ps_sanitize_process_environment(NSDictionary *orig) {
    BOOL bypass = pt_is_bypass_enabled();
    const char *vh = pt_get_virtual_home_cstr();
    const char *vt = pt_get_virtual_tmpdir_cstr();
    NSMutableDictionary *sanitized = [NSMutableDictionary dictionaryWithCapacity:orig.count + 4U];
    if (orig != nil) {
        [orig enumerateKeysAndObjectsUsingBlock:^(id keyObj, id valObj, BOOL *stop) {
            (void)stop;
            if (![keyObj isKindOfClass:[NSString class]]) {
                return;
            }
            NSString *key = (NSString *)keyObj;
            const char *keyCStr = [key UTF8String];
            if (keyCStr == NULL || keyCStr[0] == '\0') {
                return;
            }
            NSString *valStr = [valObj isKindOfClass:[NSString class]] ? (NSString *)valObj : [valObj description];
            const char *valCStr = (valStr != nil) ? [valStr UTF8String] : "";
            const char *rewritten = NULL;
            pt_env_entry_action_t act = pt_resolve_env_entry(
                keyCStr, valCStr, YES, bypass, vh, vt, &rewritten);
            if (act == PT_ENV_ENTRY_REWRITE && rewritten != NULL) {
                NSString *rewrittenStr = [NSString stringWithUTF8String:rewritten];
                if (rewrittenStr != nil) {
                    sanitized[key] = rewrittenStr;
                }
            } else if (act == PT_ENV_ENTRY_KEEP && valStr != nil) {
                sanitized[key] = valStr;
            }
        }];
    }
    NSArray<NSString *> *mandatoryKeys = @[@"HOME", @"CFFIXED_USER_HOME", @"TMPDIR", @"PATH"];
    for (NSString *mkey in mandatoryKeys) {
        if (sanitized[mkey] == nil) {
            const char *rewritten = NULL;
            if (pt_resolve_env_entry([mkey UTF8String], NULL, NO, bypass, vh, vt, &rewritten) == PT_ENV_ENTRY_REWRITE &&
                rewritten != NULL) {
                NSString *rewrittenStr = [NSString stringWithUTF8String:rewritten];
                if (rewrittenStr != nil) {
                    sanitized[mkey] = rewrittenStr;
                }
            }
        }
    }
    return [sanitized copy];
}

- (NSDictionary *) pm_environment {
    NSDictionary *orig = [self pm_environment];
    if (ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return orig ?: @{};
    }
    return ps_sanitize_process_environment(orig);
}

- (NSDictionary *) pm_swift_environment {
    NSDictionary *orig = [self pm_swift_environment];
    if (ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return orig ?: @{};
    }
    return ps_sanitize_process_environment(orig);
}

- (NSString *) pm_hostName {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return pt_get_spoofed_device_is_ipad() ? @"iPad" : @"iPhone";
    }
    return [self pm_hostName];
}

- (NSString *) pm_swift_hostName {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return pt_get_spoofed_device_is_ipad() ? @"iPad" : @"iPhone";
    }
    return [self pm_swift_hostName];
}

- (NSString *) pm_userName {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return @"mobile";
    }
    return [self pm_userName];
}

- (NSString *) pm_swift_userName {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return @"mobile";
    }
    return [self pm_swift_userName];
}

- (NSString *) pm_fullUserName {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return @"Mobile User";
    }
    return [self pm_fullUserName];
}

- (NSString *) pm_swift_fullUserName {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return @"Mobile User";
    }
    return [self pm_swift_fullUserName];
}

static NSArray<NSString *> *ps_sanitize_process_arguments(NSArray<NSString *> *orig) {
    NSUInteger count = orig.count;
    if (count == 0) {
        return orig;
    }
    NSMutableArray<NSString *> *modified = [NSMutableArray arrayWithCapacity:count];
    BOOL changed = NO;
    for (NSUInteger i = 0; i < count; i++) {
        NSString *item = orig[i];
        const char *cstr = [item isKindOfClass:[NSString class]] ? [item UTF8String] : NULL;
        if (i == 0) {
            if (cstr != NULL && cstr[0] != '\0') {
                const char *sanitized = pt_sanitize_image_path_for_cstr(cstr);
                if (sanitized != NULL && sanitized[0] != '\0') {
                    NSString *sanitizedStr = [NSString stringWithUTF8String:sanitized];
                    if (sanitizedStr != nil && ![sanitizedStr isEqualToString:item]) {
                        [modified addObject:sanitizedStr];
                        changed = YES;
                        continue;
                    }
                }
            }
            [modified addObject:item];
            continue;
        }
        const char *nextCstr = NULL;
        if (i + 1 < count && [orig[i + 1] isKindOfClass:[NSString class]]) {
            nextCstr = [orig[i + 1] UTF8String];
        }
        int skip = pt_macos_launch_arg_skip_count(cstr, nextCstr);
        if (skip > 0) {
            changed = YES;
            if (skip == 2 && i + 1 < count) {
                i++;
            }
            continue;
        }
        [modified addObject:item];
    }
    return changed ? [modified copy] : orig;
}

- (NSArray<NSString *> *) pm_arguments {
    NSArray<NSString *> *orig = [self pm_arguments];
    if (orig.count > 0 && pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_sanitize_process_arguments(orig);
    }
    return orig;
}

- (NSArray<NSString *> *) pm_swift_arguments {
    NSArray<NSString *> *orig = [self pm_swift_arguments];
    if (orig.count > 0 && pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_sanitize_process_arguments(orig);
    }
    return orig;
}


// Endfield UIAlertController hook
- (void)pm_endfield_presentViewController:(UIViewController *)viewControllerToPresent
                                 animated:(BOOL)flag
                               completion:(void (^)(void))completion {
    // If it's a UIAlertController, silently ignore it
    if ([viewControllerToPresent isKindOfClass:[UIAlertController class]]) {
        if (completion) {
            completion();
        }
        return;
    }

    // Otherwise, present normally
    [self pm_endfield_presentViewController:viewControllerToPresent animated:flag completion:completion];
}

// Class methods

+ (void) pm_return_2_with_completion_handler:(void (^)(NSInteger))completionHandler {
    if (completionHandler != nil) {
        void (^block)(NSInteger) = [completionHandler copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            block(2);
        });
    }
}

+ (NSInteger) pm_return_2 {
    return 2;
}

+ (bool) pm_clsm_return_false {
    return false;
}

+ (bool) pm_clsm_return_true {
    return true;
}

+ (BOOL) pm_clsm_return_yes {
    return YES;
}

+ (BOOL) pm_clsm_return_no {
    return NO;
}

+ (int) pm_clsm_do_nothing_with_callback:(void (^)(int))callback {
    return 0;
}


@end

static _Atomic bool s_ps_dynamic_hooks_ready = false;

static void ps_register_safe_false_cf_imp(Class cls, SEL hookSel) {
    Method safeFalseM = class_getInstanceMethod([NSObject class], NSSelectorFromString(@"isNSString__"));
    IMP safeImp = (safeFalseM != NULL) ? method_getImplementation(safeFalseM) : NULL;
    if (safeImp == NULL) {
        return;
    }
    Method hookM = class_getInstanceMethod(cls, hookSel);
    if (hookM != NULL) {
        pt_register_swizzled_imp((const void *)method_getImplementation(hookM),
                                 (const void *)safeImp);
    }
}

__attribute__((visibility("hidden")))
void ps_load_environment_bypass_hooks(void) {
    Class piClass = objc_getClass("NSProcessInfo");
    ps_register_safe_false_cf_imp([PSSwizzleHooks class], @selector(pm_isMacCatalystApp));
    ps_register_safe_false_cf_imp([PSSwizzleHooks class], @selector(pm_isiOSAppOnMac));
    ps_register_safe_false_cf_imp([PSSwizzleHooks class], @selector(pm_macCatalystVersionIsAtLeastVersion:));
    ps_swizzle_instance_method(piClass, @selector(isMacCatalystApp), @selector(pm_isMacCatalystApp));
    ps_swizzle_instance_method(piClass, @selector(isiOSAppOnMac), @selector(pm_isiOSAppOnMac));
    ps_replace_instance_method(piClass, NSSelectorFromString(@"isiOSAppOnVision"), @selector(pm_isiOSAppOnVision_no));
    ps_swizzle_instance_method(piClass, NSSelectorFromString(@"macCatalystVersionIsAtLeastVersion:"), @selector(pm_macCatalystVersionIsAtLeastVersion:));
    ps_swizzle_instance_method(piClass, @selector(isLowPowerModeEnabled), @selector(pm_ps_isLowPowerModeEnabled));
    ps_swizzle_instance_method(piClass, @selector(thermalState), @selector(pm_ps_thermalState));
    ps_swizzle_instance_method(piClass, @selector(environment), @selector(pm_environment));
    ps_swizzle_instance_method(piClass, @selector(hostName), @selector(pm_hostName));
    ps_swizzle_instance_method(piClass, @selector(processName), @selector(pm_ps_processName));
    ps_swizzle_instance_method(piClass, NSSelectorFromString(@"userName"), @selector(pm_userName));
    ps_swizzle_instance_method(piClass, NSSelectorFromString(@"fullUserName"), @selector(pm_fullUserName));
    ps_swizzle_instance_method(piClass, @selector(arguments), @selector(pm_arguments));
    if (ps_class_defines_instance_method(piClass, @selector(operatingSystemVersion))) {
        ps_swizzle_instance_method(piClass, @selector(operatingSystemVersion), @selector(pm_ps_operatingSystemVersion));
    }
    if (ps_class_defines_instance_method(piClass, @selector(isOperatingSystemAtLeastVersion:))) {
        ps_swizzle_instance_method(piClass, @selector(isOperatingSystemAtLeastVersion:), @selector(pm_ps_isOperatingSystemAtLeastVersion:));
    }
    if (ps_class_defines_instance_method(piClass, @selector(operatingSystemVersionString))) {
        ps_swizzle_instance_method(piClass, @selector(operatingSystemVersionString), @selector(pm_ps_operatingSystemVersionString));
    }
    if (ps_class_defines_instance_method(piClass, @selector(processorCount))) {
        ps_swizzle_instance_method(piClass, @selector(processorCount), @selector(pm_pi_processorCount));
    }
    if (ps_class_defines_instance_method(piClass, @selector(activeProcessorCount))) {
        ps_swizzle_instance_method(piClass, @selector(activeProcessorCount), @selector(pm_pi_activeProcessorCount));
    }
    if (ps_class_defines_instance_method(piClass, @selector(physicalMemory))) {
        ps_swizzle_instance_method(piClass, @selector(physicalMemory), @selector(pm_pi_physicalMemory));
    }

    Class concretePIClass = object_getClass([NSProcessInfo processInfo]);
    if (concretePIClass != nil && concretePIClass != piClass) {
        if (ps_class_defines_instance_method(concretePIClass, @selector(isMacCatalystApp))) {
            ps_register_safe_false_cf_imp([PSSwizzleHooks class], @selector(pm_swift_isMacCatalystApp));
            ps_swizzle_instance_method(concretePIClass, @selector(isMacCatalystApp), @selector(pm_swift_isMacCatalystApp));
        }
        if (ps_class_defines_instance_method(concretePIClass, @selector(isiOSAppOnMac))) {
            ps_register_safe_false_cf_imp([PSSwizzleHooks class], @selector(pm_swift_isiOSAppOnMac));
            ps_swizzle_instance_method(concretePIClass, @selector(isiOSAppOnMac), @selector(pm_swift_isiOSAppOnMac));
        }
        SEL visionSel = NSSelectorFromString(@"isiOSAppOnVision");
        if (ps_class_defines_instance_method(concretePIClass, visionSel)) {
            ps_replace_instance_method(concretePIClass, visionSel, @selector(pm_swift_isiOSAppOnVision_no));
        }
        SEL catAtLeastSel = NSSelectorFromString(@"macCatalystVersionIsAtLeastVersion:");
        if (ps_class_defines_instance_method(concretePIClass, catAtLeastSel)) {
            ps_register_safe_false_cf_imp([PSSwizzleHooks class], @selector(pm_swift_macCatalystVersionIsAtLeastVersion:));
            ps_swizzle_instance_method(concretePIClass, catAtLeastSel, @selector(pm_swift_macCatalystVersionIsAtLeastVersion:));
        }
        if (ps_class_defines_instance_method(concretePIClass, @selector(isLowPowerModeEnabled))) {
            ps_swizzle_instance_method(concretePIClass, @selector(isLowPowerModeEnabled), @selector(pm_ps_swift_isLowPowerModeEnabled));
        }
        if (ps_class_defines_instance_method(concretePIClass, @selector(thermalState))) {
            ps_swizzle_instance_method(concretePIClass, @selector(thermalState), @selector(pm_ps_swift_thermalState));
        }
        if (ps_class_defines_instance_method(concretePIClass, @selector(environment))) {
            ps_swizzle_instance_method(concretePIClass, @selector(environment), @selector(pm_swift_environment));
        }
        if (ps_class_defines_instance_method(concretePIClass, @selector(hostName))) {
            ps_swizzle_instance_method(concretePIClass, @selector(hostName), @selector(pm_swift_hostName));
        }
        if (ps_class_defines_instance_method(concretePIClass, @selector(processName))) {
            ps_swizzle_instance_method(concretePIClass, @selector(processName), @selector(pm_ps_swift_processName));
        }
        SEL userSel = NSSelectorFromString(@"userName");
        if (ps_class_defines_instance_method(concretePIClass, userSel)) {
            ps_swizzle_instance_method(concretePIClass, userSel, @selector(pm_swift_userName));
        }
        SEL fullUserSel = NSSelectorFromString(@"fullUserName");
        if (ps_class_defines_instance_method(concretePIClass, fullUserSel)) {
            ps_swizzle_instance_method(concretePIClass, fullUserSel, @selector(pm_swift_fullUserName));
        }
        if (ps_class_defines_instance_method(concretePIClass, @selector(arguments))) {
            ps_swizzle_instance_method(concretePIClass, @selector(arguments), @selector(pm_swift_arguments));
        }
        if (ps_class_defines_instance_method(concretePIClass, @selector(operatingSystemVersion))) {
            ps_swizzle_instance_method(concretePIClass, @selector(operatingSystemVersion), @selector(pm_ps_swift_operatingSystemVersion));
        }
        if (ps_class_defines_instance_method(concretePIClass, @selector(isOperatingSystemAtLeastVersion:))) {
            ps_swizzle_instance_method(concretePIClass, @selector(isOperatingSystemAtLeastVersion:), @selector(pm_ps_swift_isOperatingSystemAtLeastVersion:));
        }
        if (ps_class_defines_instance_method(concretePIClass, @selector(operatingSystemVersionString))) {
            ps_swizzle_instance_method(concretePIClass, @selector(operatingSystemVersionString), @selector(pm_ps_swift_operatingSystemVersionString));
        }
        if (ps_class_defines_instance_method(concretePIClass, @selector(processorCount))) {
            ps_swizzle_instance_method(concretePIClass, @selector(processorCount), @selector(pm_swift_pi_processorCount));
        }
        if (ps_class_defines_instance_method(concretePIClass, @selector(activeProcessorCount))) {
            ps_swizzle_instance_method(concretePIClass, @selector(activeProcessorCount), @selector(pm_swift_pi_activeProcessorCount));
        }
        if (ps_class_defines_instance_method(concretePIClass, @selector(physicalMemory))) {
            ps_swizzle_instance_method(concretePIClass, @selector(physicalMemory), @selector(pm_swift_pi_physicalMemory));
        }
    }

    Class udCls = objc_getClass("NSUserDefaults");
    if (udCls != Nil) {
        ps_swizzle_instance_method(udCls, @selector(objectForKey:), @selector(pm_ps_objectForKey:));
        ps_swizzle_instance_method(udCls, @selector(dictionaryRepresentation), @selector(pm_ps_dictionaryRepresentation));
        if (class_getInstanceMethod(udCls, @selector(persistentDomainForName:)) != NULL) {
            ps_swizzle_instance_method(udCls, @selector(persistentDomainForName:), @selector(pm_ps_persistentDomainForName:));
        }
        if (class_getInstanceMethod(udCls, @selector(volatileDomainForName:)) != NULL) {
            ps_swizzle_instance_method(udCls, @selector(volatileDomainForName:), @selector(pm_ps_volatileDomainForName:));
        }
    }

    Class viewCls = objc_getClass("UIView");
    if (viewCls != Nil && class_getInstanceMethod(viewCls, @selector(subviews)) != NULL) {
        ps_swizzle_instance_method(viewCls, @selector(subviews), @selector(pm_ps_subviews));
    }
    Class appCls = objc_getClass("UIApplication");
    if (appCls != Nil) {
        if (class_getInstanceMethod(appCls, @selector(windows)) != NULL) {
            ps_swizzle_instance_method(appCls, @selector(windows), @selector(pm_ps_app_windows));
        }
        SEL multiScenesSel = sel_registerName("supportsMultipleScenes");
        if (class_getInstanceMethod(appCls, multiScenesSel) != NULL) {
            ps_swizzle_instance_method(appCls, multiScenesSel, @selector(pm_ps_app_supportsMultipleScenes));
        }
    }
    Class sceneCls = objc_getClass("UIWindowScene");
    if (sceneCls != Nil) {
        if (class_getInstanceMethod(sceneCls, @selector(windows)) != NULL) {
            ps_swizzle_instance_method(sceneCls, @selector(windows), @selector(pm_ps_scene_windows));
        }
        SEL titlebarSel = sel_registerName("titlebar");
        if (class_getInstanceMethod(sceneCls, titlebarSel) != NULL) {
            ps_swizzle_instance_method(sceneCls, titlebarSel, @selector(pm_ps_scene_titlebar));
        }
        SEL sizeRestrSel = sel_registerName("sizeRestrictions");
        if (class_getInstanceMethod(sceneCls, sizeRestrSel) != NULL) {
            ps_swizzle_instance_method(sceneCls, sizeRestrSel, @selector(pm_ps_scene_sizeRestrictions));
        }
    }
    Class menuBuilderCls = objc_getClass("_UIMenuBuilder");
    if (menuBuilderCls != Nil) {
        SEL menuForIdSel = sel_registerName("menuForIdentifier:");
        if (class_getInstanceMethod(menuBuilderCls, menuForIdSel) != NULL) {
            ps_swizzle_instance_method(menuBuilderCls, menuForIdSel, @selector(pm_ps_menuBuilder_menuForIdentifier:));
        }
    }

    ps_install_dynamic_system_bundle_hooks();
    atomic_store_explicit(&s_ps_dynamic_hooks_ready, true, memory_order_release);
    [[NSNotificationCenter defaultCenter] addObserverForName:NSBundleDidLoadNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        (void)note;
        ps_install_dynamic_system_bundle_hooks();
    }];
}

__attribute__((visibility("hidden")))
void ps_notify_dynamic_image_loaded(void) {
    if (atomic_load_explicit(&s_ps_dynamic_hooks_ready, memory_order_acquire)) {
        ps_install_dynamic_system_bundle_hooks();
    }
}



@interface PSSwizzleHooks (PlayShadowNSURLFilePath)
- (NSURL *) pm_filePathURL;
@end


__attribute__((visibility("hidden")))
void ps_install_dynamic_system_bundle_hooks(void) {
    static _Thread_local bool s_tls_installing_dynamic_hooks = false;
    static _Thread_local bool s_tls_needs_rescan = false;
    if (s_tls_installing_dynamic_hooks) {
        s_tls_needs_rescan = true;
        return;
    }
    s_tls_installing_dynamic_hooks = true;
    do {
        s_tls_needs_rescan = false;
        ps_install_uifont_hooks_if_loaded();
        pt_install_graphics_hooks_if_loaded();
        ps_install_webkit_hooks_if_loaded();
        ps_install_webkit_network_hooks_if_loaded();
        ps_install_quicklook_hooks_if_loaded();
        ps_install_audio_session_port_hooks();
        ps_install_avcapture_hooks_if_loaded();
        ps_install_app_attest_hooks_if_loaded();
        ps_install_coremotion_hooks_if_loaded();
        ps_install_local_auth_hooks_if_loaded();
        ps_install_game_controller_hooks_if_loaded();
        ps_install_jscontext_hooks_if_loaded();
    } while (s_tls_needs_rescan);
    s_tls_installing_dynamic_hooks = false;
}


__attribute__((visibility("hidden")))
void ps_install_system_jailbreak_bypass_hooks(void) {
    // Device model & platform consistency
    ps_replace_instance_method(objc_getClass("UIDevice"), @selector(platform), @selector(pm_hook_platform));
    ps_replace_instance_method(objc_getClass("UIDevice"), @selector(hwModel), @selector(pm_hook_hwModel));
    ps_replace_instance_method(objc_getClass("UIDevice"), @selector(name), @selector(pm_hook_deviceName));
    ps_replace_instance_method(objc_getClass("UIDevice"), @selector(model), @selector(pm_hook_deviceModel));
    ps_replace_instance_method(objc_getClass("UIDevice"), @selector(localizedModel), @selector(pm_hook_deviceLocalizedModel));
    ps_replace_instance_method(objc_getClass("UIDevice"), @selector(systemName), @selector(pm_hook_systemName));
    ps_swizzle_instance_method(objc_getClass("UIDevice"), @selector(systemVersion), @selector(pm_hook_systemVersion));
    ps_swizzle_instance_method(objc_getClass("UIDevice"), @selector(userInterfaceIdiom), @selector(pm_hook_userInterfaceIdiom));
    {
        Class devCls = objc_getClass("UIDevice");
        if (devCls != Nil) {
            if (class_getInstanceMethod(devCls, @selector(setProximityMonitoringEnabled:)) != NULL) {
                ps_swizzle_instance_method(devCls, @selector(setProximityMonitoringEnabled:), @selector(pm_ps_setProximityMonitoringEnabled:));
            }
            if (class_getInstanceMethod(devCls, @selector(isProximityMonitoringEnabled)) != NULL) {
                ps_swizzle_instance_method(devCls, @selector(isProximityMonitoringEnabled), @selector(pm_ps_isProximityMonitoringEnabled));
            }
            if (class_getInstanceMethod(devCls, @selector(proximityState)) != NULL) {
                ps_swizzle_instance_method(devCls, @selector(proximityState), @selector(pm_ps_proximityState));
            }
        }
    }
    {
        Class devCls = objc_getClass("UIDevice");
        if (devCls != Nil) {
            Method idfvM = class_getInstanceMethod(devCls, @selector(identifierForVendor));
            if (idfvM != NULL) {
                IMP origBefore = method_getImplementation(idfvM);
                IMP prev = class_replaceMethod(devCls,
                                               @selector(identifierForVendor),
                                               (IMP)ps_hook_device_identifierForVendor,
                                               method_getTypeEncoding(idfvM));
                IMP orig = prev ?: origBefore;
                s_orig_device_identifierForVendor = (NSUUID *(*)(id, SEL))orig;
                pt_register_swizzled_imp((const void *)ps_hook_device_identifierForVendor, (const void *)orig);
            }
        }
    }
    Class traitCls = objc_getClass("UITraitCollection");
    ps_swizzle_instance_method(traitCls, @selector(userInterfaceIdiom), @selector(pm_hook_traitUserInterfaceIdiom));
    if (traitCls != Nil && class_getInstanceMethod(traitCls, @selector(description)) != NULL) {
        ps_swizzle_instance_method(traitCls, @selector(description), @selector(pm_hook_traitDescription));
    }
    if (traitCls != Nil && class_getInstanceMethod(traitCls, @selector(displayGamut)) != NULL) {
        ps_swizzle_instance_method(traitCls, @selector(displayGamut), @selector(pm_hook_traitDisplayGamut));
    }
    {
        Class imgCls = objc_getClass("UIImage");
        if (imgCls != Nil) {
            SEL sys1 = sel_registerName("systemImageNamed:");
            SEL sys2 = sel_registerName("systemImageNamed:withConfiguration:");
            SEL sys3 = sel_registerName("systemImageNamed:compatibleWithTraitCollection:");
            SEL sys4 = sel_registerName("systemImageNamed:variableValue:withConfiguration:");
            if (class_getClassMethod(imgCls, sys1) != NULL) {
                ps_swizzle_class_method(imgCls, sys1, @selector(pm_ps_uiimage_systemImageNamed:));
            }
            if (class_getClassMethod(imgCls, sys2) != NULL) {
                ps_swizzle_class_method(imgCls, sys2, @selector(pm_ps_uiimage_systemImageNamed:withConfiguration:));
            }
            if (class_getClassMethod(imgCls, sys3) != NULL) {
                ps_swizzle_class_method(imgCls, sys3, @selector(pm_ps_uiimage_systemImageNamed:compatibleWithTraitCollection:));
            }
            if (class_getClassMethod(imgCls, sys4) != NULL) {
                ps_swizzle_class_method(imgCls, sys4, @selector(pm_ps_uiimage_systemImageNamed:variableValue:withConfiguration:));
            }
        }
    }
    ps_install_nsobject_reflection_hooks();
    ps_replace_instance_method(objc_getClass("RNDeviceInfo"), @selector(getDeviceType), @selector(pm_hook_deviceType));

    // Block URL scheme probing for TrollStore / PlayCover / Cydia
    ps_swizzle_instance_method(objc_getClass("UIApplication"), @selector(canOpenURL:), @selector(pm_canOpenURL:));

    // Hide PlayCover / Mac / Jailbreak paths in NSFileManager, NSBundle & SystemVersion.plist
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(fileExistsAtPath:), @selector(pm_fileExistsAtPath:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(fileExistsAtPath:isDirectory:), @selector(pm_fileExistsAtPath:isDirectory:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(isReadableFileAtPath:), @selector(pm_isReadableFileAtPath:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(isWritableFileAtPath:), @selector(pm_isWritableFileAtPath:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(isExecutableFileAtPath:), @selector(pm_isExecutableFileAtPath:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(isDeletableFileAtPath:), @selector(pm_isDeletableFileAtPath:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(attributesOfItemAtPath:error:), @selector(pm_attributesOfItemAtPath:error:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(contentsAtPath:), @selector(pm_contentsAtPath:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(destinationOfSymbolicLinkAtPath:error:), @selector(pm_destinationOfSymbolicLinkAtPath:error:));
    ps_swizzle_instance_method(objc_getClass("NSURL"), @selector(checkResourceIsReachableAndReturnError:), @selector(pm_checkResourceIsReachableAndReturnError:));
    ps_swizzle_instance_method(objc_getClass("NSURL"), @selector(resourceValuesForKeys:error:), @selector(pm_resourceValuesForKeys:error:));
    ps_swizzle_instance_method(objc_getClass("NSURL"), @selector(getResourceValue:forKey:error:), @selector(pm_getResourceValue:forKey:error:));
    ps_swizzle_instance_method(objc_getClass("NSURL"), @selector(URLByResolvingSymlinksInPath), @selector(pm_URLByResolvingSymlinksInPath));
    ps_swizzle_instance_method(objc_getClass("NSURL"), @selector(URLByStandardizingPath), @selector(pm_URLByStandardizingPath));
    ps_swizzle_instance_method(objc_getClass("NSURL"), @selector(filePathURL), @selector(pm_filePathURL));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(contentsOfDirectoryAtPath:error:), @selector(pm_contentsOfDirectoryAtPath:error:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(subpathsOfDirectoryAtPath:error:), @selector(pm_subpathsOfDirectoryAtPath:error:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(subpathsAtPath:), @selector(pm_subpathsAtPath:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(contentsOfDirectoryAtURL:includingPropertiesForKeys:options:error:), @selector(pm_contentsOfDirectoryAtURL:includingPropertiesForKeys:options:error:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(enumeratorAtPath:), @selector(pm_enumeratorAtPath:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(enumeratorAtURL:includingPropertiesForKeys:options:errorHandler:), @selector(pm_enumeratorAtURL:includingPropertiesForKeys:options:errorHandler:));
    ps_swizzle_instance_method(objc_getClass("NSURLDirectoryEnumerator"), @selector(nextObject), @selector(pm_urlDirEnumeratorNextObject));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(URLsForDirectory:inDomains:), @selector(pm_URLsForDirectory:inDomains:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(URLForDirectory:inDomain:appropriateForURL:create:error:), @selector(pm_URLForDirectory:inDomain:appropriateForURL:create:error:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(temporaryDirectory), @selector(pm_temporaryDirectory));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(currentDirectoryPath), @selector(pm_currentDirectoryPath));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(changeCurrentDirectoryPath:), @selector(pm_changeCurrentDirectoryPath:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(createDirectoryAtPath:withIntermediateDirectories:attributes:error:), @selector(pm_createDirectoryAtPath:withIntermediateDirectories:attributes:error:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(createDirectoryAtURL:withIntermediateDirectories:attributes:error:), @selector(pm_createDirectoryAtURL:withIntermediateDirectories:attributes:error:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(createFileAtPath:contents:attributes:), @selector(pm_createFileAtPath:contents:attributes:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(removeItemAtPath:error:), @selector(pm_removeItemAtPath:error:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(removeItemAtURL:error:), @selector(pm_removeItemAtURL:error:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(copyItemAtPath:toPath:error:), @selector(pm_copyItemAtPath:toPath:error:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(copyItemAtURL:toURL:error:), @selector(pm_copyItemAtURL:toURL:error:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(moveItemAtPath:toPath:error:), @selector(pm_moveItemAtPath:toPath:error:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(moveItemAtURL:toURL:error:), @selector(pm_moveItemAtURL:toURL:error:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(linkItemAtPath:toPath:error:), @selector(pm_linkItemAtPath:toPath:error:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(linkItemAtURL:toURL:error:), @selector(pm_linkItemAtURL:toURL:error:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(createSymbolicLinkAtPath:withDestinationPath:error:), @selector(pm_createSymbolicLinkAtPath:withDestinationPath:error:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(createSymbolicLinkAtURL:withDestinationURL:error:), @selector(pm_createSymbolicLinkAtURL:withDestinationURL:error:));
    ps_swizzle_instance_method(objc_getClass("NSFileManager"), @selector(replaceItemAtURL:withItemAtURL:backupItemName:options:resultingItemURL:error:), @selector(pm_replaceItemAtURL:withItemAtURL:backupItemName:options:resultingItemURL:error:));
    Class fmCls = objc_getClass("NSFileManager");
    SEL homeCurSel = sel_registerName("homeDirectoryForCurrentUser");
    if (class_getInstanceMethod(fmCls, homeCurSel) != NULL) {
        ps_swizzle_instance_method(fmCls, homeCurSel, @selector(pm_ps_homeDirectoryForCurrentUser));
    }
    SEL homeUserSel = sel_registerName("homeDirectoryForUser:");
    if (class_getInstanceMethod(fmCls, homeUserSel) != NULL) {
        ps_swizzle_instance_method(fmCls, homeUserSel, @selector(pm_ps_homeDirectoryForUser:));
    }
    Class allDescEnumCls = objc_getClass("NSAllDescendantPathsEnumerator");
    if (allDescEnumCls != Nil && class_getInstanceMethod(allDescEnumCls, @selector(nextObject)) != NULL) {
        ps_swizzle_instance_method(allDescEnumCls, @selector(nextObject), @selector(pm_ps_allDescendantNextObject));
    }
    ps_swizzle_instance_method(fmCls, @selector(setAttributes:ofItemAtPath:error:), @selector(pm_setAttributes:ofItemAtPath:error:));
    if (class_getInstanceMethod(fmCls, @selector(containerURLForSecurityApplicationGroupIdentifier:)) != NULL) {
        ps_swizzle_instance_method(fmCls, @selector(containerURLForSecurityApplicationGroupIdentifier:), @selector(pm_ps_containerURLForSecurityApplicationGroupIdentifier:));
    }
    ps_swizzle_instance_method(objc_getClass("NSString"), @selector(stringByExpandingTildeInPath), @selector(pm_stringByExpandingTildeInPath));
    ps_swizzle_instance_method(objc_getClass("NSString"), @selector(stringByResolvingSymlinksInPath), @selector(pm_stringByResolvingSymlinksInPath));
    ps_swizzle_instance_method(objc_getClass("NSString"), @selector(stringByStandardizingPath), @selector(pm_stringByStandardizingPath));
    Class pathStoreCls = objc_getClass("NSPathStore2");
    if (pathStoreCls != nil) {
        ps_swizzle_instance_method(pathStoreCls, @selector(stringByExpandingTildeInPath), @selector(pm_ps2_stringByExpandingTildeInPath));
        ps_swizzle_instance_method(pathStoreCls, @selector(stringByResolvingSymlinksInPath), @selector(pm_ps2_stringByResolvingSymlinksInPath));
        ps_swizzle_instance_method(pathStoreCls, @selector(stringByStandardizingPath), @selector(pm_ps2_stringByStandardizingPath));
    }
    Class dataCls = objc_getClass("NSData");
    if (dataCls != Nil) {
        ps_swizzle_class_method(dataCls, @selector(dataWithContentsOfFile:), @selector(pm_dataWithContentsOfFile:));
        ps_swizzle_class_method(dataCls, @selector(dataWithContentsOfFile:options:error:), @selector(pm_dataWithContentsOfFile:options:error:));
        ps_swizzle_class_method(dataCls, @selector(dataWithContentsOfURL:options:error:), @selector(pm_dataWithContentsOfURL:options:error:));
        ps_swizzle_instance_method(dataCls, @selector(writeToFile:options:error:), @selector(pm_data_writeToFile:options:error:));
        ps_swizzle_instance_method(dataCls, @selector(writeToURL:options:error:), @selector(pm_data_writeToURL:options:error:));
    }
    Class strCls = objc_getClass("NSString");
    if (strCls != Nil) {
        ps_swizzle_class_method(strCls, @selector(stringWithContentsOfFile:encoding:error:), @selector(pm_stringWithContentsOfFile:encoding:error:));
        ps_swizzle_class_method(strCls, @selector(stringWithContentsOfURL:encoding:error:), @selector(pm_stringWithContentsOfURL:encoding:error:));
        ps_swizzle_instance_method(strCls, @selector(writeToFile:atomically:encoding:error:), @selector(pm_str_writeToFile:atomically:encoding:error:));
        ps_swizzle_instance_method(strCls, @selector(writeToURL:atomically:encoding:error:), @selector(pm_str_writeToURL:atomically:encoding:error:));
    }
    Class bundleCls = objc_getClass("NSBundle");
    ps_swizzle_class_method(bundleCls, @selector(allFrameworks), @selector(pm_allFrameworks));
    ps_swizzle_class_method(bundleCls, @selector(allBundles), @selector(pm_allBundles));
    ps_swizzle_class_method(bundleCls, @selector(bundleWithIdentifier:), @selector(pm_bundleWithIdentifier:));
    ps_swizzle_class_method(bundleCls, @selector(bundleWithPath:), @selector(pm_bundleWithPath:));
    ps_swizzle_class_method(bundleCls, @selector(bundleWithURL:), @selector(pm_bundleWithURL:));
    {
        Method bfcM = class_getClassMethod(bundleCls, @selector(bundleForClass:));
        Class bundleMeta = object_getClass((id)bundleCls);
        if (bfcM != NULL && bundleMeta != Nil) {
            IMP origBefore = method_getImplementation(bfcM);
            IMP prev = class_replaceMethod(
                bundleMeta, @selector(bundleForClass:), (IMP)ps_hook_bundle_for_class, method_getTypeEncoding(bfcM));
            IMP orig = prev ?: origBefore;
            s_orig_bundleForClass = (NSBundle *(*)(id, SEL, Class))orig;
            pt_register_swizzled_imp((const void *)ps_hook_bundle_for_class, (const void *)orig);
        }
    }
    const struct {
        SEL orig;
        SEL hook;
    } kPSBundleInstanceSwizzles[] = {
        { @selector(initWithPath:), @selector(pm_ps_initWithPath:) },
        { @selector(initWithURL:), @selector(pm_ps_initWithURL:) },
        { @selector(bundlePath), @selector(pm_ps_bundlePath) },
        { @selector(resourcePath), @selector(pm_ps_resourcePath) },
        { @selector(executablePath), @selector(pm_ps_executablePath) },
        { @selector(privateFrameworksPath), @selector(pm_ps_privateFrameworksPath) },
        { @selector(sharedFrameworksPath), @selector(pm_ps_sharedFrameworksPath) },
        { @selector(sharedSupportPath), @selector(pm_ps_sharedSupportPath) },
        { @selector(builtInPlugInsPath), @selector(pm_ps_builtInPlugInsPath) },
        { @selector(bundleURL), @selector(pm_ps_bundleURL) },
        { @selector(resourceURL), @selector(pm_ps_resourceURL) },
        { @selector(executableURL), @selector(pm_ps_executableURL) },
        { @selector(privateFrameworksURL), @selector(pm_ps_privateFrameworksURL) },
        { @selector(sharedFrameworksURL), @selector(pm_ps_sharedFrameworksURL) },
        { @selector(sharedSupportURL), @selector(pm_ps_sharedSupportURL) },
        { @selector(builtInPlugInsURL), @selector(pm_ps_builtInPlugInsURL) },
        { @selector(appStoreReceiptURL), @selector(pm_ps_appStoreReceiptURL) },
        { @selector(pathForAuxiliaryExecutable:), @selector(pm_ps_pathForAuxiliaryExecutable:) },
        { @selector(URLForAuxiliaryExecutable:), @selector(pm_ps_URLForAuxiliaryExecutable:) },
        { @selector(pathForResource:ofType:), @selector(pm_ps_pathForResource:ofType:) },
        { @selector(pathForResource:ofType:inDirectory:), @selector(pm_ps_pathForResource:ofType:inDirectory:) },
        { @selector(pathForResource:ofType:inDirectory:forLocalization:), @selector(pm_ps_pathForResource:ofType:inDirectory:forLocalization:) },
        { @selector(URLForResource:withExtension:), @selector(pm_ps_URLForResource:withExtension:) },
        { @selector(URLForResource:withExtension:subdirectory:), @selector(pm_ps_URLForResource:withExtension:subdirectory:) },
        { @selector(URLForResource:withExtension:subdirectory:localization:), @selector(pm_ps_URLForResource:withExtension:subdirectory:localization:) },
        { @selector(pathsForResourcesOfType:inDirectory:), @selector(pm_ps_pathsForResourcesOfType:inDirectory:) },
        { @selector(URLsForResourcesWithExtension:subdirectory:), @selector(pm_ps_URLsForResourcesWithExtension:subdirectory:) },
        { @selector(URLsForResourcesWithExtension:subdirectory:localization:), @selector(pm_ps_URLsForResourcesWithExtension:subdirectory:localization:) },
        { @selector(localizedInfoDictionary), @selector(pm_ps_localizedInfoDictionary) },
        { @selector(infoDictionary), @selector(pm_ps_infoDictionary) },
        { @selector(objectForInfoDictionaryKey:), @selector(pm_ps_objectForInfoDictionaryKey:) },
        { @selector(executableArchitectures), @selector(pm_ps_bundle_executableArchitectures) },
        { @selector(classNamed:), @selector(pm_ps_bundle_classNamed:) },
        { @selector(principalClass), @selector(pm_ps_bundle_principalClass) },
        { @selector(description), @selector(pm_ps_bundle_description) }
    };
    for (size_t i = 0; i < sizeof(kPSBundleInstanceSwizzles) / sizeof(kPSBundleInstanceSwizzles[0]); i++) {
        if (class_getInstanceMethod(bundleCls, kPSBundleInstanceSwizzles[i].orig) != NULL) {
            ps_swizzle_instance_method(bundleCls, kPSBundleInstanceSwizzles[i].orig, kPSBundleInstanceSwizzles[i].hook);
        }
    }
    const struct {
        SEL orig;
        SEL hook;
    } kPSBundleClassSwizzles[] = {
        { @selector(pathForResource:ofType:inDirectory:), @selector(pm_ps_cls_pathForResource:ofType:inDirectory:) },
        { @selector(URLForResource:withExtension:subdirectory:inBundleWithURL:), @selector(pm_ps_URLForResource:withExtension:subdirectory:inBundleWithURL:) },
        { @selector(pathsForResourcesOfType:inDirectory:), @selector(pm_ps_cls_pathsForResourcesOfType:inDirectory:) },
        { @selector(URLsForResourcesWithExtension:subdirectory:inBundleWithURL:), @selector(pm_ps_URLsForResourcesWithExtension:subdirectory:inBundleWithURL:) }
    };
    for (size_t i = 0; i < sizeof(kPSBundleClassSwizzles) / sizeof(kPSBundleClassSwizzles[0]); i++) {
        if (class_getClassMethod(bundleCls, kPSBundleClassSwizzles[i].orig) != NULL) {
            ps_swizzle_class_method(bundleCls, kPSBundleClassSwizzles[i].orig, kPSBundleClassSwizzles[i].hook);
        }
    }
    ps_swizzle_class_method(objc_getClass("NSDictionary"), @selector(dictionaryWithContentsOfFile:), @selector(pm_dictionaryWithContentsOfFile:));
    ps_swizzle_class_method(objc_getClass("NSDictionary"), @selector(dictionaryWithContentsOfURL:), @selector(pm_dictionaryWithContentsOfURL:));
    ps_swizzle_class_method(objc_getClass("NSPropertyListSerialization"), @selector(propertyListWithData:options:format:error:), @selector(pm_propertyListWithData:options:format:error:));

    // Class: UIDevice
    ps_replace_class_method(objc_getClass("UIDevice"), @selector(isJailbroken), @selector(pm_clsm_return_no));
    ps_replace_instance_method(objc_getClass("UIDevice"), @selector(isJailBreak), @selector(pm_return_no));
    ps_replace_instance_method(objc_getClass("UIDevice"), @selector(isJailBroken), @selector(pm_return_no));

    // Class: JailbreakDetectionVC
    ps_replace_instance_method(objc_getClass("JailbreakDetectionVC"), @selector(isJailbroken), @selector(pm_return_no));

    // Class: DTTJailbreakDetection
    ps_replace_class_method(objc_getClass("DTTJailbreakDetection"), @selector(isJailbroken), @selector(pm_clsm_return_no));

    // Class: ANSMetadata
    ps_replace_instance_method(objc_getClass("ANSMetadata"), @selector(computeIsJailbroken), @selector(pm_return_no));
    ps_replace_instance_method(objc_getClass("ANSMetadata"), @selector(isJailbroken), @selector(pm_return_no));

    // Class: AppsFlyerUtils
    ps_replace_class_method(objc_getClass("AppsFlyerUtils"), @selector(isJailBreakon), @selector(pm_clsm_return_no));
    ps_replace_class_method(objc_getClass("AppsFlyerUtils"), @selector(isJailbroken), @selector(pm_clsm_return_no));
    ps_replace_class_method(objc_getClass("AppsFlyerUtils"), @selector(isJailbrokenWithSkipAdvancedJailbreakValidation:), @selector(pm_clsm_return_false));

    // Class: jailBreak
    ps_replace_class_method(objc_getClass("jailBreak"), @selector(isJailBreak), @selector(pm_clsm_return_false));

    // Class: GBDeviceInfo
    ps_replace_instance_method(objc_getClass("GBDeviceInfo"), @selector(isJailbroken), @selector(pm_return_no));

    // Class: CMARAppRestrictionsDelegate
    ps_replace_instance_method(objc_getClass("CMARAppRestrictionsDelegate"), @selector(isDeviceNonCompliant), @selector(pm_return_false));

    // Class: ADYSecurityChecks
    ps_replace_class_method(objc_getClass("ADYSecurityChecks"), @selector(isDeviceJailbroken), @selector(pm_clsm_return_false));

    // Class: UBReportMetadataDevice
    ps_replace_instance_method(objc_getClass("UBReportMetadataDevice"), @selector(is_rooted), @selector(pm_return_null));

    // Class: UtilitySystem
    ps_replace_class_method(objc_getClass("UtilitySystem"), @selector(isJailbreak), @selector(pm_clsm_return_false));

    // Class: GemaltoConfiguration
    ps_replace_class_method(objc_getClass("GemaltoConfiguration"), @selector(isJailbreak), @selector(pm_clsm_return_false));

    // Class: CPWRDeviceInfo
    ps_replace_instance_method(objc_getClass("CPWRDeviceInfo"), @selector(isJailbroken), @selector(pm_return_false));

    // Class: CPWRSessionInfo
    ps_replace_instance_method(objc_getClass("CPWRSessionInfo"), @selector(isJailbroken), @selector(pm_return_false));

    // Class: KSSystemInfo
    ps_replace_class_method(objc_getClass("KSSystemInfo"), @selector(isJailbroken), @selector(pm_clsm_return_false));

    // Class: EMDSKPPConfiguration
    ps_replace_instance_method(objc_getClass("EMDSKPPConfiguration"), @selector(jailBroken), @selector(pm_return_false));

    // Class: EnrollParameters
    ps_replace_instance_method(objc_getClass("EnrollParameters"), @selector(jailbroken), @selector(pm_return_null));

    // Class: EMDskppConfigurationBuilder
    ps_replace_instance_method(objc_getClass("EMDskppConfigurationBuilder"), @selector(jailbreakStatus), @selector(pm_return_false));

    // Class: FCRSystemMetadata
    ps_replace_instance_method(objc_getClass("FCRSystemMetadata"), @selector(isJailbroken), @selector(pm_return_false));

    // Class: v_VDMap
    ps_replace_instance_method(objc_getClass("v_VDMap"), @selector(isJailbrokenDetected), @selector(pm_return_false));
    ps_replace_instance_method(objc_getClass("v_VDMap"), @selector(isJailBrokenDetectedByVOS), @selector(pm_return_false));
    ps_replace_instance_method(objc_getClass("v_VDMap"), @selector(isDFPHookedDetecedByVOS), @selector(pm_return_false));
    ps_replace_instance_method(objc_getClass("v_VDMap"), @selector(isCodeInjectionDetectedByVOS), @selector(pm_return_false));
    ps_replace_instance_method(objc_getClass("v_VDMap"), @selector(isDebuggerCheckDetectedByVOS), @selector(pm_return_false));
    ps_replace_instance_method(objc_getClass("v_VDMap"), @selector(isAppSignerCheckDetectedByVOS), @selector(pm_return_false));
    ps_replace_instance_method(objc_getClass("v_VDMap"), @selector(v_checkAModified), @selector(pm_return_false));
    ps_replace_instance_method(objc_getClass("v_VDMap"), @selector(isRuntimeTamperingDetected), @selector(pm_return_false));

    // Class: SDMUtils
    ps_replace_instance_method(objc_getClass("SDMUtils"), @selector(isJailBroken), @selector(pm_return_no));

    // Class: OneSignalJailbreakDetection
    ps_replace_class_method(objc_getClass("OneSignalJailbreakDetection"), @selector(isJailbroken), @selector(pm_clsm_return_no));

    // Class: DigiPassHandler
    ps_replace_instance_method(objc_getClass("DigiPassHandler"), @selector(rootedDeviceTestResult), @selector(pm_return_no));

    // Class: AWMyDeviceGeneralInfo
    ps_replace_instance_method(objc_getClass("AWMyDeviceGeneralInfo"), @selector(isCompliant), @selector(pm_return_true));

    // Class: DTXSessionInfo
    ps_replace_instance_method(objc_getClass("DTXSessionInfo"), @selector(isJailbroken), @selector(pm_return_false));

    // Class: DTXDeviceInfo
    ps_replace_instance_method(objc_getClass("DTXDeviceInfo"), @selector(isJailbroken), @selector(pm_return_false));

    // Class: JailbreakDetection
    ps_replace_instance_method(objc_getClass("JailbreakDetection"), @selector(jailbroken), @selector(pm_return_false));

    // Class: jailBrokenJudge
    ps_replace_instance_method(objc_getClass("jailBrokenJudge"), @selector(isJailBreak), @selector(pm_return_false));
    ps_replace_instance_method(objc_getClass("jailBrokenJudge"), @selector(isCydiaJailBreak), @selector(pm_return_false));
    ps_replace_instance_method(objc_getClass("jailBrokenJudge"), @selector(isApplicationsJailBreak), @selector(pm_return_false));
    ps_replace_instance_method(objc_getClass("jailBrokenJudge"), @selector(ischeckCydiaJailBreak), @selector(pm_return_false));
    ps_replace_instance_method(objc_getClass("jailBrokenJudge"), @selector(isPathJailBreak), @selector(pm_return_false));
    ps_replace_instance_method(objc_getClass("jailBrokenJudge"), @selector(boolIsjailbreak), @selector(pm_return_false));

    // Class: FBAdBotDetector
    ps_replace_instance_method(objc_getClass("FBAdBotDetector"), @selector(isJailBrokenDevice), @selector(pm_return_false));

    // Class: TNGDeviceTool
    ps_replace_class_method(objc_getClass("TNGDeviceTool"), @selector(isJailBreak), @selector(pm_clsm_return_false));
    ps_replace_class_method(objc_getClass("TNGDeviceTool"), @selector(isJailBreak_file), @selector(pm_clsm_return_false));
    ps_replace_class_method(objc_getClass("TNGDeviceTool"), @selector(isJailBreak_cydia), @selector(pm_clsm_return_false));
    ps_replace_class_method(objc_getClass("TNGDeviceTool"), @selector(isJailBreak_appList), @selector(pm_clsm_return_false));
    ps_replace_class_method(objc_getClass("TNGDeviceTool"), @selector(isJailBreak_env), @selector(pm_clsm_return_false));

    // Class: DTDeviceInfo
    ps_replace_class_method(objc_getClass("DTDeviceInfo"), @selector(isJailbreak), @selector(pm_clsm_return_false));

    // Class: SecVIDeviceUtil
    ps_replace_class_method(objc_getClass("SecVIDeviceUtil"), @selector(isJailbreak), @selector(pm_clsm_return_false));

    // Class: RVPBridgeExtension4Jailbroken
    ps_replace_instance_method(objc_getClass("RVPBridgeExtension4Jailbroken"), @selector(isJailbroken), @selector(pm_return_false));

    // Class: ZDetection
    ps_replace_class_method(objc_getClass("ZDetection"), @selector(isRootedOrJailbroken), @selector(pm_clsm_return_false));
}
