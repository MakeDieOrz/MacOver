//
//  PTSystemSpooferObjC.m
//  PlayTools
//

#import "PSInternal.h"

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

static BOOL ps_is_iphone_device_model(void) {
    const char *m = pt_get_device_model_cstr();
    return (m != NULL && strncmp(m, "iPhone", 6) == 0);
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

- (BOOL) pm_canOpenURL:(NSURL *)url {
    if (url != nil && url.scheme != nil) {
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
                @"macover"
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
    if (cId != NULL && pt_is_registered_hidden_module(cId)) {
        return YES;
    }
    return ([bId containsString:@"PlayTools"] ||
            [bId containsString:@"AKInterface"] ||
            [bId containsString:@"playcover"] ||
            [bId containsString:@"macover"] ||
            [bId containsString:@"MacOver"] ||
            [bId containsString:@"app.makedie"] ||
            [bId isEqualToString:@"com.apple.AppKit"] ||
            [bId isEqualToString:@"com.apple.UIKitMacHelper"] ||
            [bId isEqualToString:@"com.apple.ViewBridge"] ||
            [bId isEqualToString:@"com.apple.SkyLight"] ||
            [bId isEqualToString:@"com.apple.HIToolbox"] ||
            [bId isEqualToString:@"com.apple.Carbon"] ||
            [bId isEqualToString:@"com.apple.Cocoa"]);
}

static BOOL ps_is_hidden_bundle(NSBundle *bundle, const void *caller) {
    if (bundle == nil) {
        return NO;
    }
    NSString *bPath = bundle.bundlePath ?: @"";
    if ([bPath containsString:@"PlayTools"] ||
        [bPath containsString:@"AKInterface"] ||
        [bPath containsString:@"UserPlugins"] ||
        [bPath containsString:@"AppKit.framework"] ||
        [bPath containsString:@"UIKitMacHelper.framework"] ||
        [bPath containsString:@"ViewBridge.framework"] ||
        [bPath containsString:@"SkyLight.framework"] ||
        [bPath containsString:@"HIToolbox.framework"] ||
        [bPath containsString:@"Carbon.framework"] ||
        [bPath containsString:@"Cocoa.framework"] ||
        ([bPath UTF8String] != NULL && pt_is_registered_hidden_module([bPath UTF8String])) ||
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

+ (NSBundle *) pm_bundleWithPath:(NSString *)path {
    const void *caller = __builtin_return_address(0);
    if (ps_is_hidden_path(path, caller)) {
        return nil;
    }
    NSString *resolved = ps_resolve_virtual_nsstring_path(path);
    if (resolved != path && ps_is_hidden_path(ps_strip_iossupport_nsstring(resolved), caller)) {
        return nil;
    }
    return [self pm_bundleWithPath:resolved];
}

+ (NSBundle *) pm_bundleWithURL:(NSURL *)url {
    const void *caller = __builtin_return_address(0);
    if (url != nil && [url isFileURL] && ps_is_hidden_path(url.path, caller)) {
        return nil;
    }
    NSURL *resolved = ps_resolve_virtual_nsurl(url);
    if (resolved != url && resolved != nil && [resolved isFileURL] &&
        ps_is_hidden_path(ps_strip_iossupport_nsstring(resolved.path), caller)) {
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
    if (ps_is_hidden_path(path, caller)) {
        return nil;
    }
    NSString *resolved = ps_resolve_virtual_nsstring_path(path);
    if (resolved != path && ps_is_hidden_path(ps_strip_iossupport_nsstring(resolved), caller)) {
        return nil;
    }
    return [self pm_ps_initWithPath:resolved];
}

- (instancetype) pm_ps_initWithURL:(NSURL *)url {
    const void *caller = __builtin_return_address(0);
    if (url != nil && [url isFileURL] && ps_is_hidden_path(url.path, caller)) {
        return nil;
    }
    NSURL *resolved = ps_resolve_virtual_nsurl(url);
    if (resolved != url && resolved != nil && [resolved isFileURL] &&
        ps_is_hidden_path(ps_strip_iossupport_nsstring(resolved.path), caller)) {
        return nil;
    }
    return [self pm_ps_initWithURL:resolved];
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
        NSDictionary<NSString *, id> *loc = [(NSBundle *)(id)self localizedInfoDictionary];
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
        return ps_virtual_mobileprovision_path_if_applicable(self, name, ext, nil, caller);
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
        return ps_virtual_mobileprovision_path_if_applicable(self, name, ext, subpath, caller);
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
        return ps_virtual_mobileprovision_path_if_applicable(self, name, ext, subpath, caller);
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
        NSString *vpath = ps_virtual_mobileprovision_path_if_applicable(self, name, ext, nil, caller);
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
        NSString *vpath = ps_virtual_mobileprovision_path_if_applicable(self, name, ext, subpath, caller);
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
        NSString *vpath = ps_virtual_mobileprovision_path_if_applicable(self, name, ext, subpath, caller);
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

static NSError *ps_make_devicecheck_unsupported_error(void) {
    NSString *domain = @"com.apple.devicecheck.error";
    NSString * __unsafe_unretained const *sym =
        (NSString * __unsafe_unretained const *)dlsym(RTLD_DEFAULT, "DCErrorDomain");
    if (sym != NULL && *sym != nil && [*sym isKindOfClass:[NSString class]]) {
        domain = *sym;
    }
    // DCErrorFeatureUnsupported == 1 in <DeviceCheck/DCError.h>
    return [NSError errorWithDomain:domain code:1 userInfo:nil];
}

- (BOOL) pm_ps_appAttest_isSupported {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NO;
    }
    return [self pm_ps_appAttest_isSupported];
}

- (void) pm_ps_appAttest_generateKeyWithCompletionHandler:(void (^)(NSString * _Nullable keyId, NSError * _Nullable error))completionHandler {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (completionHandler != nil) {
            NSError *err = ps_make_devicecheck_unsupported_error();
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                completionHandler(nil, err);
            });
        }
        return;
    }
    [self pm_ps_appAttest_generateKeyWithCompletionHandler:completionHandler];
}

- (void) pm_ps_appAttest_attestKey:(NSString *)keyId
                    clientDataHash:(NSData *)clientDataHash
                 completionHandler:(void (^)(NSData * _Nullable attestationObject, NSError * _Nullable error))completionHandler {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (completionHandler != nil) {
            NSError *err = ps_make_devicecheck_unsupported_error();
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                completionHandler(nil, err);
            });
        }
        return;
    }
    [self pm_ps_appAttest_attestKey:keyId clientDataHash:clientDataHash completionHandler:completionHandler];
}

- (void) pm_ps_appAttest_generateAssertion:(NSString *)keyId
                            clientDataHash:(NSData *)clientDataHash
                         completionHandler:(void (^)(NSData * _Nullable assertionObject, NSError * _Nullable error))completionHandler {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (completionHandler != nil) {
            NSError *err = ps_make_devicecheck_unsupported_error();
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                completionHandler(nil, err);
            });
        }
        return;
    }
    [self pm_ps_appAttest_generateAssertion:keyId clientDataHash:clientDataHash completionHandler:completionHandler];
}

- (BOOL) pm_ps_dcDevice_isSupported {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NO;
    }
    return [self pm_ps_dcDevice_isSupported];
}

- (void) pm_ps_dcDevice_generateTokenWithCompletionHandler:(void (^)(NSData * _Nullable data, NSError * _Nullable error))completion {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (completion != nil) {
            NSError *err = ps_make_devicecheck_unsupported_error();
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                completion(nil, err);
            });
        }
        return;
    }
    [self pm_ps_dcDevice_generateTokenWithCompletionHandler:completion];
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

static BOOL ps_get_cached_ios_sysver(NSOperatingSystemVersion *outVer, NSString * __autoreleasing *outVerString) {
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
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_spoofed_os_version_string((NSProcessInfo *)self);
    }
    return [self pm_ps_operatingSystemVersionString];
}

- (NSString *) pm_ps_swift_operatingSystemVersionString {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_spoofed_os_version_string((NSProcessInfo *)self);
    }
    return [self pm_ps_swift_operatingSystemVersionString];
}

- (NSOperatingSystemVersion) pm_ps_operatingSystemVersion {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        NSOperatingSystemVersion ver = {0, 0, 0};
        if (ps_get_cached_ios_sysver(&ver, NULL)) {
            return ver;
        }
    }
    return [self pm_ps_operatingSystemVersion];
}

- (NSOperatingSystemVersion) pm_ps_swift_operatingSystemVersion {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        NSOperatingSystemVersion ver = {0, 0, 0};
        if (ps_get_cached_ios_sysver(&ver, NULL)) {
            return ver;
        }
    }
    return [self pm_ps_swift_operatingSystemVersion];
}

- (BOOL) pm_ps_isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion)version {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        NSOperatingSystemVersion ver = {0, 0, 0};
        if (ps_get_cached_ios_sysver(&ver, NULL)) {
            return ps_os_version_at_least(ver, version);
        }
    }
    return [self pm_ps_isOperatingSystemAtLeastVersion:version];
}

- (BOOL) pm_ps_swift_isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion)version {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
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


static atomic_bool s_audio_port_name_swizzled = false;
static atomic_bool s_audio_port_uid_swizzled = false;

static NSString *ps_sanitize_audio_port_string(NSString *orig, NSString *portType, BOOL isUID) {
    if (orig.length == 0) {
        return orig;
    }
    NSString *devWord = pt_get_spoofed_device_is_ipad() ? @"iPad" : @"iPhone";
    if ([portType isEqualToString:@"Speaker"]) {
        if (isUID) {
            return @"Speaker";
        }
        if ([orig rangeOfString:@"扬声器"].location != NSNotFound) {
            return @"扬声器";
        }
        return @"Speaker";
    }
    if ([portType isEqualToString:@"MicrophoneBuiltIn"]) {
        if (isUID) {
            return @"Built-In Microphone";
        }
        if ([orig rangeOfString:@"麦克风"].location != NSNotFound) {
            return [NSString stringWithFormat:@"%@ 麦克风", devWord];
        }
        return [NSString stringWithFormat:@"%@ Microphone", devWord];
    }

    static NSArray<NSString *> *s_macModels = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_macModels = @[@"MacBook Air", @"MacBook Pro", @"MacBook", @"Mac mini", @"Mac Studio", @"Mac Pro", @"iMac"];
    });

    NSString *res = orig;
    BOOL changed = NO;
    if ([res rangeOfString:@"BuiltInSpeakerDevice"].location != NSNotFound) {
        res = [res stringByReplacingOccurrencesOfString:@"BuiltInSpeakerDevice" withString:@"Speaker"];
        changed = YES;
    }
    if ([res rangeOfString:@"BuiltInMicrophoneDevice"].location != NSNotFound) {
        res = [res stringByReplacingOccurrencesOfString:@"BuiltInMicrophoneDevice" withString:@"Built-In Microphone"];
        changed = YES;
    }
    for (NSString *macModel in s_macModels) {
        if ([res rangeOfString:macModel options:NSCaseInsensitiveSearch].location != NSNotFound) {
            res = [res stringByReplacingOccurrencesOfString:macModel
                                                 withString:devWord
                                                    options:NSCaseInsensitiveSearch
                                                      range:NSMakeRange(0, res.length)];
            changed = YES;
        }
    }
    if (changed) {
        NSString *compactSpeaker = [NSString stringWithFormat:@"%@扬声器", devWord];
        if ([res rangeOfString:compactSpeaker].location != NSNotFound) {
            res = [res stringByReplacingOccurrencesOfString:compactSpeaker
                                                 withString:[NSString stringWithFormat:@"%@ 扬声器", devWord]];
        }
        NSString *compactMic = [NSString stringWithFormat:@"%@麦克风", devWord];
        if ([res rangeOfString:compactMic].location != NSNotFound) {
            res = [res stringByReplacingOccurrencesOfString:compactMic
                                                 withString:[NSString stringWithFormat:@"%@ 麦克风", devWord]];
        }
    }
    return res;
}

static NSString *ps_audio_port_type(id portDesc) {
    SEL ptSel = NSSelectorFromString(@"portType");
    if (portDesc != nil && [portDesc respondsToSelector:ptSel]) {
        return ((NSString *(*)(id, SEL))objc_msgSend)(portDesc, ptSel);
    }
    return nil;
}

- (NSString *) pm_ps_portName {
    const void *caller = __builtin_return_address(0);
    NSString *orig = [self pm_ps_portName];
    if (orig.length > 0 && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        return ps_sanitize_audio_port_string(orig, ps_audio_port_type(self), NO);
    }
    return orig;
}

- (NSString *) pm_ps_UID {
    const void *caller = __builtin_return_address(0);
    NSString *orig = [self pm_ps_UID];
    if (orig.length > 0 && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        return ps_sanitize_audio_port_string(orig, ps_audio_port_type(self), YES);
    }
    return orig;
}

- (NSString *) pm_ps_audio_port_description {
    const void *caller = __builtin_return_address(0);
    NSString *origDesc = [self pm_ps_audio_port_description];
    if (origDesc.length > 0 && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        NSString *portType = ps_audio_port_type(self);
        NSString *res = origDesc;
        if (atomic_load_explicit(&s_audio_port_name_swizzled, memory_order_acquire)) {
            NSString *realName = [self pm_ps_portName];
            NSString *sanitizedName = ps_sanitize_audio_port_string(realName, portType, NO);
            if (realName.length > 0 && sanitizedName.length > 0 && ![sanitizedName isEqualToString:realName]) {
                res = [res stringByReplacingOccurrencesOfString:realName withString:sanitizedName];
            }
        }
        if (atomic_load_explicit(&s_audio_port_uid_swizzled, memory_order_acquire)) {
            NSString *realUID = [self pm_ps_UID];
            NSString *sanitizedUID = ps_sanitize_audio_port_string(realUID, portType, YES);
            if (realUID.length > 0 && sanitizedUID.length > 0 && ![sanitizedUID isEqualToString:realUID]) {
                res = [res stringByReplacingOccurrencesOfString:realUID withString:sanitizedUID];
            }
        }
        res = ps_sanitize_audio_port_string(res, nil, NO);
        return res;
    }
    return origDesc;
}

static os_unfair_lock s_av_swizzle_lock = OS_UNFAIR_LOCK_INIT;
static CFMutableDictionaryRef s_av_orig_name_imps = NULL;
static CFMutableDictionaryRef s_av_orig_modelid_imps = NULL;

static void ps_swizzle_capture_device_class(Class cls) {
    if (cls == Nil) {
        return;
    }
    ps_swizzle_class_sel_storing_imp(&s_av_swizzle_lock, &s_av_orig_name_imps, cls,
                                     sel_registerName("localizedName"), @selector(pm_ps_av_localizedName));
    ps_swizzle_class_sel_storing_imp(&s_av_swizzle_lock, &s_av_orig_modelid_imps, cls,
                                     sel_registerName("modelID"), @selector(pm_ps_av_modelID));
}

static BOOL ps_is_hidden_capture_device(id dev) {
    if (dev == nil) {
        return NO;
    }
    SEL dtSel = sel_registerName("deviceType");
    if ([dev respondsToSelector:dtSel]) {
        NSString *dt = ((NSString *(*)(id, SEL))objc_msgSend)(dev, dtSel);
        if ([dt isKindOfClass:[NSString class]]) {
            if ([dt containsString:@"Continuity"] ||
                [dt containsString:@"External"] ||
                [dt containsString:@"DeskView"]) {
                return YES;
            }
        }
    }
    BOOL pushed = NO;
    IMP nameIMP = ps_lookup_orig_imp_and_push(&s_av_swizzle_lock, s_av_orig_name_imps, dev, &pushed);
    NSString *name = nil;
    if (nameIMP != NULL) {
        @try {
            name = ((NSString *(*)(id, SEL))nameIMP)(dev, sel_registerName("localizedName"));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    } else if ([dev respondsToSelector:sel_registerName("localizedName")]) {
        name = ((NSString *(*)(id, SEL))objc_msgSend)(dev, sel_registerName("localizedName"));
    }
    if ([name isKindOfClass:[NSString class]]) {
        if ([name containsString:@"Continuity"] ||
            [name containsString:@"Desk View"]) {
            return YES;
        }
    }
    return NO;
}

static NSString *ps_sanitize_capture_device_string(id dev, NSString *orig, BOOL isModelID) {
    if (orig.length == 0) {
        return orig;
    }
    static NSArray<NSString *> *s_cameraMacKeywords = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_cameraMacKeywords = @[@"FaceTime", @"MacBook Air", @"MacBook Pro", @"MacBook", @"Mac mini", @"Mac Studio", @"Mac Pro", @"iMac"];
    });
    BOOL isCamera = NO;
    SEL hasMediaSel = sel_registerName("hasMediaType:");
    if ([dev respondsToSelector:hasMediaSel]) {
        isCamera = ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(dev, hasMediaSel, @"vide");
    }
    if (isCamera ||
        [orig rangeOfString:@"FaceTime" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [orig rangeOfString:@"Camera" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        for (NSString *kw in s_cameraMacKeywords) {
            if ([orig rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
                return isModelID
                    ? @"com.apple.avfoundation.avcapturedevice.built-in_video:1"
                    : @"Front Camera";
            }
        }
    }
    return ps_sanitize_audio_port_string(orig, nil, isModelID);
}

static NSArray *ps_filter_capture_devices(NSArray *devices, BOOL isAppCaller) {
    if (devices == nil) {
        return nil;
    }
    NSMutableArray *filtered = isAppCaller ? [NSMutableArray arrayWithCapacity:devices.count] : nil;
    for (id dev in devices) {
        if (dev != nil) {
            ps_swizzle_capture_device_class(object_getClass(dev));
            if (isAppCaller && !ps_is_hidden_capture_device(dev)) {
                [filtered addObject:dev];
            }
        }
    }
    return isAppCaller ? [filtered copy] : devices;
}

- (NSString *) pm_ps_av_localizedName {
    SEL sel = sel_registerName("localizedName");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_av_swizzle_lock, s_av_orig_name_imps, self, &pushed);
    NSString *orig = nil;
    if (origIMP != NULL) {
        @try {
            orig = ((NSString *(*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (orig.length > 0 && pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_sanitize_capture_device_string(self, orig, NO);
    }
    return orig;
}

- (NSString *) pm_ps_av_modelID {
    SEL sel = sel_registerName("modelID");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_av_swizzle_lock, s_av_orig_modelid_imps, self, &pushed);
    NSString *orig = nil;
    if (origIMP != NULL) {
        @try {
            orig = ((NSString *(*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (orig.length > 0 && pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_sanitize_capture_device_string(self, orig, YES);
    }
    return orig;
}

+ (NSArray *) pm_ps_av_devices {
    NSArray *devices = [self pm_ps_av_devices];
    BOOL isAppCaller = pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0));
    return ps_filter_capture_devices(devices, isAppCaller);
}

+ (NSArray *) pm_ps_av_devicesWithMediaType:(NSString *)mediaType {
    NSArray *devices = [self pm_ps_av_devicesWithMediaType:mediaType];
    BOOL isAppCaller = pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0));
    return ps_filter_capture_devices(devices, isAppCaller);
}

+ (id) pm_ps_av_defaultDeviceWithMediaType:(NSString *)mediaType {
    id dev = [self pm_ps_av_defaultDeviceWithMediaType:mediaType];
    if (dev != nil) {
        ps_swizzle_capture_device_class(object_getClass(dev));
        if (pt_is_bypass_enabled() &&
            !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
            ps_is_hidden_capture_device(dev)) {
            NSArray *fallback = ps_filter_capture_devices([self pm_ps_av_devicesWithMediaType:mediaType], YES);
            return fallback.firstObject;
        }
    }
    return dev;
}

+ (id) pm_ps_av_defaultDeviceWithDeviceType:(NSString *)deviceType mediaType:(NSString *)mediaType position:(NSInteger)position {
    id dev = [self pm_ps_av_defaultDeviceWithDeviceType:deviceType mediaType:mediaType position:position];
    if (dev != nil) {
        ps_swizzle_capture_device_class(object_getClass(dev));
        if (pt_is_bypass_enabled() &&
            !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
            ps_is_hidden_capture_device(dev)) {
            return nil;
        }
    }
    return dev;
}

- (NSArray *) pm_ps_av_session_devices {
    NSArray *devices = [self pm_ps_av_session_devices];
    BOOL isAppCaller = pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0));
    return ps_filter_capture_devices(devices, isAppCaller);
}

- (id) pm_ps_objectForKey:(NSString *)defaultName {
    if ([defaultName isEqualToString:@"playtoolsKeymappingDisabledAt"] &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return nil;
    }
    return [self pm_ps_objectForKey:defaultName];
}

- (NSDictionary<NSString *, id> *) pm_ps_dictionaryRepresentation {
    NSDictionary<NSString *, id> *dict = [self pm_ps_dictionaryRepresentation];
    if (dict != nil &&
        dict[@"playtoolsKeymappingDisabledAt"] != nil &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        NSMutableDictionary<NSString *, id> *filtered = [dict mutableCopy];
        [filtered removeObjectForKey:@"playtoolsKeymappingDisabledAt"];
        return [filtered copy];
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


static _Atomic bool s_wk_custom_protocol_handles_file = false;
static const char kPSWKExplicitCustomUAKey = 0;
static const char kPSWKUCCManagedModeKey = 0;

static NSString * const kPSWKEnvScriptMarker = @"/*__pt_wk_env_v1__*/";
static NSString * const kPSWKVFileScriptMarker = @"/*__pt_wk_vfile_v1__*/";

static NSString *ps_ios_os_version_for_ua(void) {
    const char *ovVer = pt_get_reported_ios_version_override(NULL);
    if (ovVer != NULL) {
        NSString *ovStr = [NSString stringWithUTF8String:ovVer];
        if (ovStr.length > 0) {
            return [ovStr stringByReplacingOccurrencesOfString:@"." withString:@"_"];
        }
    }
    NSString *ver = [[UIDevice currentDevice] systemVersion];
    if (ver.length == 0) {
        return @"18_0";
    }
    NSString *underscored = [ver stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    return underscored.length > 0 ? underscored : @"18_0";
}

static NSString *ps_ios_ua_platform_token(void) {
    NSString *osVer = ps_ios_os_version_for_ua();
    if (ps_is_iphone_device_model()) {
        return [NSString stringWithFormat:@"iPhone; CPU iPhone OS %@ like Mac OS X", osVer];
    }
    return [NSString stringWithFormat:@"iPad; CPU OS %@ like Mac OS X", osVer];
}

static NSString *ps_build_default_wk_user_agent(id configuration) {
    NSString *appSuffix = @"Mobile/15E148";
    if (configuration != nil) {
        SEL appNameSel = NSSelectorFromString(@"applicationNameForUserAgent");
        if ([configuration respondsToSelector:appNameSel]) {
            NSString *cfgAppName = ((NSString *(*)(id, SEL))objc_msgSend)(configuration, appNameSel);
            if ([cfgAppName isKindOfClass:[NSString class]]) {
                NSString *trimmed = [cfgAppName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (trimmed.length > 0) {
                    if ([trimmed hasPrefix:@"Mobile/"]) {
                        appSuffix = trimmed;
                    } else {
                        appSuffix = [NSString stringWithFormat:@"Mobile/15E148 %@", trimmed];
                    }
                }
            }
        }
    }
    return [NSString stringWithFormat:@"Mozilla/5.0 (%@) AppleWebKit/605.1.15 (KHTML, like Gecko) %@",
            ps_ios_ua_platform_token(), appSuffix];
}

static NSString *ps_sanitize_mac_token_in_ua(NSString *ua) {
    if (ua.length == 0 || ![ua containsString:@"Macintosh"]) {
        return ua;
    }
    static NSRegularExpression *s_macUARe = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_macUARe = [NSRegularExpression regularExpressionWithPattern:@"Macintosh;\\s*(?:Intel|Apple)?\\s*Mac OS X[^)]*"
                                                              options:0
                                                                error:nil];
    });
    if (s_macUARe == nil) {
        return ua;
    }
    return [s_macUARe stringByReplacingMatchesInString:ua
                                               options:0
                                                 range:NSMakeRange(0, ua.length)
                                          withTemplate:ps_ios_ua_platform_token()];
}

static void ps_get_wk_env_profile_params(NSString **outPlat,
                                          NSString **outUaToken,
                                          unsigned int *outCores,
                                          int *outPtWidth,
                                          int *outPtHeight,
                                          double *outDpr) {
    NSString *plat = ps_is_iphone_device_model() ? @"iPhone" : @"iPad";
    NSString *uaToken = ps_ios_ua_platform_token();
    unsigned int cores = (unsigned int)pt_get_spoofed_cpu_cores();
    if (cores == 0) {
        cores = 6;
    }
    double dpr = pt_get_device_native_scale();
    if (dpr <= 0.0) {
        dpr = 2.0;
    }
    uint32_t nativeW = pt_get_device_native_width();
    uint32_t nativeH = pt_get_device_native_height();
    if (nativeW == 0 || nativeH == 0) {
        BOOL isPhone = ps_is_iphone_device_model();
        nativeW = isPhone ? 1284U : 2048U;
        nativeH = isPhone ? 2778U : 2732U;
    }
    int ptWidth = (int)llround((double)nativeW / dpr);
    int ptHeight = (int)llround((double)nativeH / dpr);
    if (ptWidth <= 0) {
        ptWidth = ps_is_iphone_device_model() ? 428 : 1024;
    }
    if (ptHeight <= 0) {
        ptHeight = ps_is_iphone_device_model() ? 926 : 1366;
    }
    if (outPlat) *outPlat = plat;
    if (outUaToken) *outUaToken = uaToken;
    if (outCores) *outCores = cores;
    if (outPtWidth) *outPtWidth = ptWidth;
    if (outPtHeight) *outPtHeight = ptHeight;
    if (outDpr) *outDpr = dpr;
}

static NSString *ps_build_wk_env_user_script_source(void);

static NSString *ps_build_wk_env_user_script_source_uncached(NSString *plat,
                                                             NSString *uaToken,
                                                             unsigned int cores,
                                                             int ptWidth,
                                                             int ptHeight,
                                                             double dpr) {
    NSString *preamble = [NSString stringWithFormat:
        @"%@\n"
        "(function(){\n"
        "  const plat = '%@';\n"
        "  const uaToken = '%@';\n"
        "  const cores = %u;\n"
        "  const ptWidth = %d;\n"
        "  const ptHeight = %d;\n"
        "  const dpr = %.6g;\n",
        kPSWKEnvScriptMarker, plat, uaToken, cores, ptWidth, ptHeight, dpr];

    static NSString * const kEnvScriptBody =
        @"  const wrappedFns = new WeakSet();\n"
        "  const toStringMap = new WeakMap();\n"
        "  const patchedWindows = new WeakSet();\n"
        "  const patchedOriProtos = new WeakSet();\n"
        "  const debugExtContexts = new WeakSet();\n"
        "  const touchHandlerMap = new WeakMap();\n"
        "  const mqlMediaMap = new WeakMap();\n"
        "  const macDevLabelRe = /facetime|macbook|mac\\s*mini|mac\\s*studio|mac\\s*pro|imac|studio\\s*display|pro\\s*display|apple\\s*display|continuity|desk\\s*view/i;\n"
        "  const macCamLabelRe = /facetime|desk\\s*view|continuity/i;\n"
        "  const blockedWebGLExts = new Set([\n"
        "    'ext_disjoint_timer_query',\n"
        "    'ext_disjoint_timer_query_webgl2'\n"
        "  ]);\n"
        "  const ptBlobMap = (typeof Map === 'function') ? new Map() : null;\n"
        "  const ptPendingWorkerURLs = (typeof Set === 'function') ? new Set() : null;\n"
        "  const ptSharedEntries = (typeof Map === 'function') ? new Map() : null;\n"
        "  const rawFnToString = Function.prototype.toString;\n"
        "  function markNativeFn(fn, nativeStr, fnName, ObjCtor) {\n"
        "    wrappedFns.add(fn);\n"
        "    toStringMap.set(fn, nativeStr);\n"
        "    if (fnName) {\n"
        "      try {\n"
        "        const defProp = (ObjCtor && ObjCtor.defineProperty) || Object.defineProperty;\n"
        "        defProp(fn, 'name', { value: fnName, configurable: true });\n"
        "      } catch (_) {}\n"
        "    }\n"
        "    return fn;\n"
        "  }\n"
        "  function defGetter(obj, prop, fn, winObj, enumOverride) {\n"
        "    if (!obj) return;\n"
        "    const Obj = (winObj && winObj.Object) || Object;\n"
        "    try {\n"
        "      const d = Obj.getOwnPropertyDescriptor(obj, prop);\n"
        "      if (d && d.configurable === false) return;\n"
        "      markNativeFn(fn, 'function get ' + prop + '() { [native code] }', 'get ' + prop, Obj);\n"
        "      Obj.defineProperty(obj, prop, {\n"
        "        get: fn,\n"
        "        configurable: true,\n"
        "        enumerable: (typeof enumOverride === 'boolean') ? enumOverride : (d ? d.enumerable : true)\n"
        "      });\n"
        "    } catch (_) {}\n"
        "  }\n"
        "  function workerBootstrap(p, u, c, baseHref, isShared, bootFnSrc, sharedName) {\n"
        "    const wWrappedFns = new WeakSet();\n"
        "    const wToStringMap = new WeakMap();\n"
        "    const wDebugExtContexts = new WeakSet();\n"
        "    const wBlockedWebGLExts = new Set([\n"
        "      'ext_disjoint_timer_query',\n"
        "      'ext_disjoint_timer_query_webgl2'\n"
        "    ]);\n"
        "    function wMark(fn, str, fnName) {\n"
        "      wWrappedFns.add(fn);\n"
        "      wToStringMap.set(fn, str);\n"
        "      if (fnName) {\n"
        "        try { Object.defineProperty(fn, 'name', { value: fnName, configurable: true }); } catch (_) {}\n"
        "      }\n"
        "      return fn;\n"
        "    }\n"
        "    const FnProto = (typeof Function !== 'undefined') ? Function.prototype : null;\n"
        "    const origFnToString = (FnProto && typeof FnProto.toString === 'function') ? FnProto.toString : null;\n"
        "    if (FnProto && origFnToString && !wWrappedFns.has(origFnToString)) {\n"
        "      const toStringWrapper = function toString() {\n"
        "        if (wToStringMap.has(this)) return wToStringMap.get(this);\n"
        "        return origFnToString.call(this);\n"
        "      };\n"
        "      wMark(toStringWrapper, 'function toString() { [native code] }', 'toString');\n"
        "      try {\n"
        "        Object.defineProperty(FnProto, 'toString', {\n"
        "          value: toStringWrapper,\n"
        "          configurable: true,\n"
        "          writable: true,\n"
        "          enumerable: false\n"
        "        });\n"
        "      } catch (_) {}\n"
        "    }\n"
        "    function wDefGetter(obj, prop, fn) {\n"
        "      if (!obj) return;\n"
        "      try {\n"
        "        const d = Object.getOwnPropertyDescriptor(obj, prop);\n"
        "        if (d && d.configurable === false) return;\n"
        "        wMark(fn, 'function get ' + prop + '() { [native code] }', 'get ' + prop);\n"
        "        Object.defineProperty(obj, prop, {\n"
        "          get: fn,\n"
        "          configurable: true,\n"
        "          enumerable: d ? d.enumerable : true\n"
        "        });\n"
        "      } catch (_) {}\n"
        "    }\n"
        "    function wAssignGlobal(prop, fn) {\n"
        "      if (typeof self === 'undefined') return;\n"
        "      try {\n"
        "        self[prop] = fn;\n"
        "        if (self[prop] === fn) return;\n"
        "      } catch (_) {}\n"
        "      try {\n"
        "        Object.defineProperty(self, prop, {\n"
        "          value: fn,\n"
        "          configurable: true,\n"
        "          writable: true,\n"
        "          enumerable: true\n"
        "        });\n"
        "      } catch (_) {}\n"
        "    }\n"
        "    const np = (typeof self !== 'undefined' && self.WorkerNavigator && self.WorkerNavigator.prototype)\n"
        "      ? self.WorkerNavigator.prototype\n"
        "      : ((typeof WorkerNavigator !== 'undefined' && WorkerNavigator.prototype)\n"
        "        ? WorkerNavigator.prototype\n"
        "        : (typeof self !== 'undefined' && self.navigator ? Object.getPrototypeOf(self.navigator) : null));\n"
        "    if (np) {\n"
        "      const oua = Object.getOwnPropertyDescriptor(np, 'userAgent');\n"
        "      const oav = Object.getOwnPropertyDescriptor(np, 'appVersion');\n"
        "      wDefGetter(np, 'platform', function() { return p; });\n"
        "      wDefGetter(np, 'hardwareConcurrency', function() { return c; });\n"
        "      wDefGetter(np, 'maxTouchPoints', function() { return 5; });\n"
        "      wDefGetter(np, 'vendor', function() { return 'Apple Computer, Inc.'; });\n"
        "      if (oua && typeof oua.get === 'function') {\n"
        "        wDefGetter(np, 'userAgent', function() {\n"
        "          return String(oua.get.call(this) || '').replace(/Macintosh;\\s*(?:Intel|Apple)?\\s*Mac OS X[^)]*/g, u);\n"
        "        });\n"
        "      }\n"
        "      if (oav && typeof oav.get === 'function') {\n"
        "        wDefGetter(np, 'appVersion', function() {\n"
        "          return String(oav.get.call(this) || '').replace(/Macintosh;\\s*(?:Intel|Apple)?\\s*Mac OS X[^)]*/g, u);\n"
        "        });\n"
        "      }\n"
        "    }\n"
        "    function wPatchWebGL(ctor) {\n"
        "      if (!ctor || !ctor.prototype) return;\n"
        "      const proto = ctor.prototype;\n"
        "      if (typeof proto.getSupportedExtensions === 'function' && !wWrappedFns.has(proto.getSupportedExtensions)) {\n"
        "        const origGetSupExts = proto.getSupportedExtensions;\n"
        "        const wrappedGetSupExts = ({ getSupportedExtensions() {\n"
        "          const list = origGetSupExts.apply(this, arguments);\n"
        "          if (!Array.isArray(list)) return list;\n"
        "          return list.filter(function(extName) {\n"
        "            return typeof extName === 'string' && !wBlockedWebGLExts.has(extName.toLowerCase());\n"
        "          });\n"
        "        } }).getSupportedExtensions;\n"
        "        wMark(wrappedGetSupExts, 'function getSupportedExtensions() { [native code] }', 'getSupportedExtensions');\n"
        "        try { proto.getSupportedExtensions = wrappedGetSupExts; } catch (_) {}\n"
        "      }\n"
        "      if (typeof proto.getExtension === 'function' && !wWrappedFns.has(proto.getExtension)) {\n"
        "        const origGetExt = proto.getExtension;\n"
        "        const wrappedGetExt = ({ getExtension(name) {\n"
        "          if (typeof name === 'string' && wBlockedWebGLExts.has(name.toLowerCase())) {\n"
        "            return null;\n"
        "          }\n"
        "          const ext = origGetExt.apply(this, arguments);\n"
        "          try {\n"
        "            if (ext && typeof name === 'string' && name.toLowerCase() === 'webgl_debug_renderer_info') {\n"
        "              wDebugExtContexts.add(this);\n"
        "            }\n"
        "          } catch (_) {}\n"
        "          return ext;\n"
        "        } }).getExtension;\n"
        "        wMark(wrappedGetExt, 'function getExtension() { [native code] }', 'getExtension');\n"
        "        try { proto.getExtension = wrappedGetExt; } catch (_) {}\n"
        "      }\n"
        "      if (typeof proto.getParameter === 'function' && !wWrappedFns.has(proto.getParameter)) {\n"
        "        const origGetParam = proto.getParameter;\n"
        "        const wrappedGetParam = ({ getParameter(pname) {\n"
        "          if (wDebugExtContexts.has(this)) {\n"
        "            if (pname === 37445) return 'Apple Inc.';\n"
        "            if (pname === 37446) return 'Apple GPU';\n"
        "          }\n"
        "          return origGetParam.apply(this, arguments);\n"
        "        } }).getParameter;\n"
        "        wMark(wrappedGetParam, 'function getParameter() { [native code] }', 'getParameter');\n"
        "        try { proto.getParameter = wrappedGetParam; } catch (_) {}\n"
        "      }\n"
        "    }\n"
        "    if (typeof WebGLRenderingContext !== 'undefined') wPatchWebGL(WebGLRenderingContext);\n"
        "    if (typeof WebGL2RenderingContext !== 'undefined') wPatchWebGL(WebGL2RenderingContext);\n"
        "    if (typeof OffscreenCanvas !== 'undefined' && OffscreenCanvas.prototype && typeof OffscreenCanvas.prototype.getContext === 'function' && !wWrappedFns.has(OffscreenCanvas.prototype.getContext)) {\n"
        "      const origOffscreenGetContext = OffscreenCanvas.prototype.getContext;\n"
        "      const wrappedOffscreenGetContext = function getContext(contextType) {\n"
        "        const ctx = origOffscreenGetContext.apply(this, arguments);\n"
        "        try {\n"
        "          if (ctx && (contextType === 'webgl' || contextType === 'experimental-webgl' || contextType === 'webgl2')) {\n"
        "            const ctxProto = Object.getPrototypeOf(ctx);\n"
        "            if (ctxProto && typeof ctxProto.getParameter === 'function' && !wWrappedFns.has(ctxProto.getParameter)) {\n"
        "              wPatchWebGL(ctxProto.constructor || { prototype: ctxProto });\n"
        "            }\n"
        "          }\n"
        "        } catch (_) {}\n"
        "        return ctx;\n"
        "      };\n"
        "      wMark(wrappedOffscreenGetContext, 'function getContext() { [native code] }', 'getContext');\n"
        "      try { OffscreenCanvas.prototype.getContext = wrappedOffscreenGetContext; } catch (_) {}\n"
        "    }\n"
        "    let parsedBase = null;\n"
        "    try {\n"
        "      if (baseHref && typeof baseHref === 'string') parsedBase = new URL(baseHref);\n"
        "    } catch (_) {\n"
        "      parsedBase = null;\n"
        "    }\n"
        "    if (parsedBase) {\n"
        "      const locProto = (typeof WorkerLocation !== 'undefined' && WorkerLocation.prototype)\n"
        "        ? WorkerLocation.prototype\n"
        "        : (typeof location !== 'undefined' ? Object.getPrototypeOf(location) : null);\n"
        "      if (locProto && locProto !== Object.prototype) {\n"
        "        wDefGetter(locProto, 'href', function() { return parsedBase.href; });\n"
        "        wDefGetter(locProto, 'protocol', function() { return parsedBase.protocol; });\n"
        "        wDefGetter(locProto, 'host', function() { return parsedBase.host; });\n"
        "        wDefGetter(locProto, 'hostname', function() { return parsedBase.hostname; });\n"
        "        wDefGetter(locProto, 'port', function() { return parsedBase.port; });\n"
        "        wDefGetter(locProto, 'pathname', function() { return parsedBase.pathname; });\n"
        "        wDefGetter(locProto, 'search', function() { return parsedBase.search; });\n"
        "        wDefGetter(locProto, 'hash', function() { return parsedBase.hash; });\n"
        "        wDefGetter(locProto, 'origin', function() { return parsedBase.origin; });\n"
        "        const locToString = wMark(function toString() {\n"
        "          return parsedBase.href;\n"
        "        }, 'function toString() { [native code] }', 'toString');\n"
        "        try {\n"
        "          const td = Object.getOwnPropertyDescriptor(locProto, 'toString');\n"
        "          if (!td || td.configurable !== false) {\n"
        "            Object.defineProperty(locProto, 'toString', {\n"
        "              value: locToString,\n"
        "              configurable: true,\n"
        "              writable: true,\n"
        "              enumerable: td ? td.enumerable : true\n"
        "            });\n"
        "          } else if (td.writable) {\n"
        "            locProto.toString = locToString;\n"
        "          }\n"
        "        } catch (_) {}\n"
        "      }\n"
        "      function resolveRelURL(val) {\n"
        "        if (typeof val !== 'string') return val;\n"
        "        if (/^(?:blob|data|javascript):/i.test(val.trim())) return val;\n"
        "        try {\n"
        "          return new URL(val, parsedBase.href).href;\n"
        "        } catch (_) {\n"
        "          return val;\n"
        "        }\n"
        "      }\n"
        "      if (typeof self !== 'undefined' && typeof self.importScripts === 'function' && !wWrappedFns.has(self.importScripts)) {\n"
        "        const origImportScripts = self.importScripts;\n"
        "        const wrappedImportScripts = ({ importScripts() {\n"
        "          const resolvedArgs = [];\n"
        "          for (let i = 0; i < arguments.length; i++) {\n"
        "            resolvedArgs.push(resolveRelURL(String(arguments[i])));\n"
        "          }\n"
        "          return origImportScripts.apply(this == null ? self : this, resolvedArgs);\n"
        "        } }).importScripts;\n"
        "        wMark(wrappedImportScripts, 'function importScripts() { [native code] }', 'importScripts');\n"
        "        wAssignGlobal('importScripts', wrappedImportScripts);\n"
        "      }\n"
        "      const reqCtor = (typeof self !== 'undefined' && self.Request) || (typeof Request !== 'undefined' ? Request : null);\n"
        "      if (typeof reqCtor === 'function' && !wWrappedFns.has(reqCtor)) {\n"
        "        const OrigRequest = reqCtor;\n"
        "        const WrappedRequest = function Request(input) {\n"
        "          const args = Array.prototype.slice.call(arguments);\n"
        "          if (args.length > 0 && typeof args[0] === 'string') {\n"
        "            args[0] = resolveRelURL(args[0]);\n"
        "          }\n"
        "          if (!new.target) {\n"
        "            return OrigRequest.apply(this, args);\n"
        "          }\n"
        "          if (typeof Reflect === 'object' && typeof Reflect.construct === 'function') {\n"
        "            return Reflect.construct(OrigRequest, args, new.target);\n"
        "          }\n"
        "          return args.length > 1 ? new OrigRequest(args[0], args[1]) : new OrigRequest(args[0]);\n"
        "        };\n"
        "        WrappedRequest.prototype = OrigRequest.prototype;\n"
        "        try { Object.setPrototypeOf(WrappedRequest, OrigRequest); } catch (_) {}\n"
        "        wMark(WrappedRequest, 'function Request() { [native code] }', 'Request');\n"
        "        wAssignGlobal('Request', WrappedRequest);\n"
        "      }\n"
        "      const origFetch = (typeof self !== 'undefined' && self.fetch) || (typeof fetch !== 'undefined' ? fetch : null);\n"
        "      if (typeof origFetch === 'function' && !wWrappedFns.has(origFetch)) {\n"
        "        const wrappedFetch = ({ fetch(input) {\n"
        "          const args = Array.prototype.slice.call(arguments);\n"
        "          if (args.length > 0 && typeof args[0] === 'string') {\n"
        "            args[0] = resolveRelURL(args[0]);\n"
        "          }\n"
        "          return origFetch.apply(this == null ? self : this, args);\n"
        "        } }).fetch;\n"
        "        wMark(wrappedFetch, 'function fetch() { [native code] }', 'fetch');\n"
        "        wAssignGlobal('fetch', wrappedFetch);\n"
        "      }\n"
        "      if (typeof XMLHttpRequest !== 'undefined' && XMLHttpRequest.prototype &&\n"
        "          typeof XMLHttpRequest.prototype.open === 'function' && !wWrappedFns.has(XMLHttpRequest.prototype.open)) {\n"
        "        const origXHROpen = XMLHttpRequest.prototype.open;\n"
        "        const wrappedXHROpen = ({ open(method, url) {\n"
        "          const args = Array.prototype.slice.call(arguments);\n"
        "          if (args.length > 1 && typeof args[1] === 'string') {\n"
        "            args[1] = resolveRelURL(args[1]);\n"
        "          }\n"
        "          return origXHROpen.apply(this, args);\n"
        "        } }).open;\n"
        "        wMark(wrappedXHROpen, 'function open() { [native code] }', 'open');\n"
        "        try { XMLHttpRequest.prototype.open = wrappedXHROpen; } catch (_) {}\n"
        "      }\n"
        "      const esCtor = (typeof self !== 'undefined' && self.EventSource) || (typeof EventSource !== 'undefined' ? EventSource : null);\n"
        "      if (typeof esCtor === 'function' && !wWrappedFns.has(esCtor)) {\n"
        "        const OrigEventSource = esCtor;\n"
        "        const WrappedEventSource = function EventSource(url, eventSourceInitDict) {\n"
        "          const args = Array.prototype.slice.call(arguments);\n"
        "          if (args.length > 0 && typeof args[0] === 'string') {\n"
        "            args[0] = resolveRelURL(args[0]);\n"
        "          }\n"
        "          if (!new.target) {\n"
        "            return OrigEventSource.apply(this, args);\n"
        "          }\n"
        "          if (typeof Reflect === 'object' && typeof Reflect.construct === 'function') {\n"
        "            return Reflect.construct(OrigEventSource, args, new.target);\n"
        "          }\n"
        "          return args.length > 1 ? new OrigEventSource(args[0], args[1]) : new OrigEventSource(args[0]);\n"
        "        };\n"
        "        WrappedEventSource.prototype = OrigEventSource.prototype;\n"
        "        try { Object.setPrototypeOf(WrappedEventSource, OrigEventSource); } catch (_) {}\n"
        "        wMark(WrappedEventSource, 'function EventSource() { [native code] }', 'EventSource');\n"
        "        wAssignGlobal('EventSource', WrappedEventSource);\n"
        "      }\n"
        "      const wsCtor = (typeof self !== 'undefined' && self.WebSocket) || (typeof WebSocket !== 'undefined' ? WebSocket : null);\n"
        "      if (typeof wsCtor === 'function' && !wWrappedFns.has(wsCtor)) {\n"
        "        const OrigWebSocket = wsCtor;\n"
        "        const WrappedWebSocket = function WebSocket(url, protocols) {\n"
        "          const args = Array.prototype.slice.call(arguments);\n"
        "          if (args.length > 0 && typeof args[0] === 'string') {\n"
        "            const rawWS = args[0].trim();\n"
        "            if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(rawWS) && rawWS.indexOf('//') !== 0) {\n"
        "              args[0] = resolveRelURL(args[0]).replace(/^http/i, 'ws');\n"
        "            }\n"
        "          }\n"
        "          if (!new.target) {\n"
        "            return OrigWebSocket.apply(this, args);\n"
        "          }\n"
        "          if (typeof Reflect === 'object' && typeof Reflect.construct === 'function') {\n"
        "            return Reflect.construct(OrigWebSocket, args, new.target);\n"
        "          }\n"
        "          return args.length > 1 ? new OrigWebSocket(args[0], args[1]) : new OrigWebSocket(args[0]);\n"
        "        };\n"
        "        WrappedWebSocket.prototype = OrigWebSocket.prototype;\n"
        "        try { Object.setPrototypeOf(WrappedWebSocket, OrigWebSocket); } catch (_) {}\n"
        "        wMark(WrappedWebSocket, 'function WebSocket() { [native code] }', 'WebSocket');\n"
        "        wAssignGlobal('WebSocket', WrappedWebSocket);\n"
        "      }\n"
        "    }\n"
        "    const wBlobMap = (typeof Map === 'function') ? new Map() : null;\n"
        "    const wPendingWorkerURLs = (typeof Set === 'function') ? new Set() : null;\n"
        "    const wURL = (typeof URL === 'function') ? URL : null;\n"
        "    const wOrigCreateObjectURL = (wURL && typeof wURL.createObjectURL === 'function') ? wURL.createObjectURL.bind(wURL) : null;\n"
        "    const wOrigRevokeObjectURL = (wURL && typeof wURL.revokeObjectURL === 'function') ? wURL.revokeObjectURL.bind(wURL) : null;\n"
        "    function wScheduleRevoke(uStr, ms) {\n"
        "      if (!wOrigRevokeObjectURL || !uStr || typeof setTimeout !== 'function') return;\n"
        "      setTimeout(function() { try { wOrigRevokeObjectURL(uStr); } catch (_) {} }, ms);\n"
        "    }\n"
        "    if (wURL && wOrigCreateObjectURL && wBlobMap && typeof Blob === 'function' && !wWrappedFns.has(wURL.createObjectURL)) {\n"
        "      const wWrappedCreate = ({ createObjectURL(obj) {\n"
        "        const res = wOrigCreateObjectURL(obj);\n"
        "        try {\n"
        "          if (typeof res === 'string' && ((obj instanceof Blob) || (obj && typeof obj === 'object' && typeof obj.size === 'number' && typeof obj.type === 'string' && typeof obj.slice === 'function')) && obj.size <= 4194304) {\n"
        "            if (wBlobMap.size >= 128) {\n"
        "              const oldest = wBlobMap.keys().next();\n"
        "              if (!oldest.done) wBlobMap.delete(oldest.value);\n"
        "            }\n"
        "            wBlobMap.set(res, obj);\n"
        "          }\n"
        "        } catch (_) {}\n"
        "        return res;\n"
        "      } }).createObjectURL;\n"
        "      wMark(wWrappedCreate, 'function createObjectURL() { [native code] }', 'createObjectURL');\n"
        "      try { wURL.createObjectURL = wWrappedCreate; } catch (_) {}\n"
        "    }\n"
        "    if (wURL && wOrigRevokeObjectURL && !wWrappedFns.has(wURL.revokeObjectURL)) {\n"
        "      const wWrappedRevoke = ({ revokeObjectURL(uStr) {\n"
        "        const key = String(uStr);\n"
        "        if (wBlobMap) wBlobMap.delete(key);\n"
        "        if (wPendingWorkerURLs && wPendingWorkerURLs.has(key)) {\n"
        "          wScheduleRevoke(uStr, 3000);\n"
        "          return;\n"
        "        }\n"
        "        return wOrigRevokeObjectURL(uStr);\n"
        "      } }).revokeObjectURL;\n"
        "      wMark(wWrappedRevoke, 'function revokeObjectURL() { [native code] }', 'revokeObjectURL');\n"
        "      try { wURL.revokeObjectURL = wWrappedRevoke; } catch (_) {}\n"
        "    }\n"
        "    const workerCtor = (typeof self !== 'undefined' && self.Worker) || (typeof Worker !== 'undefined' ? Worker : null);\n"
        "    if (typeof workerCtor === 'function' && !wWrappedFns.has(workerCtor)) {\n"
        "      const OrigWorker = workerCtor;\n"
        "      const childBootSrc = (typeof bootFnSrc === 'string' && bootFnSrc)\n"
        "        ? bootFnSrc\n"
        "        : (origFnToString ? origFnToString.call(workerBootstrap) : '');\n"
        "      function buildChildSetupCode(cBaseHref) {\n"
        "        return '(' + childBootSrc + ')(' +\n"
        "          JSON.stringify(p) + ',' +\n"
        "          JSON.stringify(u) + ',' +\n"
        "          c + ',' +\n"
        "          JSON.stringify(cBaseHref || '') + ',false,' +\n"
        "          JSON.stringify(childBootSrc) + ');';\n"
        "      }\n"
        "      const WrappedChildWorker = function Worker(scriptURL) {\n"
        "        if (arguments.length === 0) {\n"
        "          return new OrigWorker();\n"
        "        }\n"
        "        const hasOpts = arguments.length > 1;\n"
        "        const options = hasOpts ? arguments[1] : undefined;\n"
        "        if (!new.target) {\n"
        "          return hasOpts ? OrigWorker(scriptURL, options) : OrigWorker(scriptURL);\n"
        "        }\n"
        "        try {\n"
        "          const rawChildStr = String(scriptURL);\n"
        "          if (/^javascript:/i.test(rawChildStr.trim())) {\n"
        "            return hasOpts ? new OrigWorker(scriptURL, options) : new OrigWorker(scriptURL);\n"
        "          }\n"
        "          const childResolveBase = parsedBase\n"
        "            ? parsedBase.href\n"
        "            : ((typeof location !== 'undefined' && location.href) ? location.href : '');\n"
        "          const absChildURL = new URL(rawChildStr, childResolveBase).href;\n"
        "          if (/^(?:javascript|file|pt-vfile):/i.test(absChildURL)) {\n"
        "            return hasOpts ? new OrigWorker(scriptURL, options) : new OrigWorker(scriptURL);\n"
        "          }\n"
        "          const isChildModule = Boolean(options && typeof options === 'object' && options.type === 'module');\n"
        "          const selfOrigin = (typeof self !== 'undefined' && typeof self.origin === 'string')\n"
        "            ? self.origin\n"
        "            : ((typeof location !== 'undefined' && typeof location.origin === 'string') ? location.origin : '');\n"
        "          if (selfOrigin === 'null') {\n"
        "            if (/^data:/i.test(absChildURL) && childBootSrc) {\n"
        "              const dChildBoot = buildChildSetupCode('');\n"
        "              let dChildEntry;\n"
        "              if (isChildModule) {\n"
        "                const dChildSetup = 'data:text/javascript;charset=utf-8,' + encodeURIComponent(dChildBoot);\n"
        "                dChildEntry = 'data:text/javascript;charset=utf-8,' + encodeURIComponent('import ' + JSON.stringify(dChildSetup) + ';\\nimport ' + JSON.stringify(absChildURL) + ';\\n');\n"
        "              } else {\n"
        "                dChildEntry = 'data:text/javascript;charset=utf-8,' + encodeURIComponent(dChildBoot + '\\nimportScripts(' + JSON.stringify(absChildURL) + ');\\n');\n"
        "              }\n"
        "              return hasOpts ? new OrigWorker(dChildEntry, options) : new OrigWorker(dChildEntry);\n"
        "            }\n"
        "            return hasOpts ? new OrigWorker(scriptURL, options) : new OrigWorker(scriptURL);\n"
        "          }\n"
        "          const isChildBlob = /^blob:/i.test(absChildURL);\n"
        "          const isChildData = /^data:/i.test(absChildURL);\n"
        "          if (!isChildBlob && !isChildData && selfOrigin && selfOrigin !== 'null') {\n"
        "            let childOrigin = '';\n"
        "            try { childOrigin = new URL(absChildURL).origin; } catch (_) {}\n"
        "            if (childOrigin && childOrigin !== selfOrigin) {\n"
        "              return hasOpts ? new OrigWorker(scriptURL, options) : new OrigWorker(scriptURL);\n"
        "            }\n"
        "          }\n"
        "          if (!childBootSrc || typeof Blob !== 'function' || !wOrigCreateObjectURL) {\n"
        "            return hasOpts ? new OrigWorker(absChildURL, options) : new OrigWorker(absChildURL);\n"
        "          }\n"
        "          const childBaseHref = (!isChildBlob && !isChildData) ? absChildURL : '';\n"
        "          const childBootCode = buildChildSetupCode(childBaseHref);\n"
        "          let childTargetURL = absChildURL;\n"
        "          if (isChildBlob) {\n"
        "            if (wBlobMap && wBlobMap.has(absChildURL)) {\n"
        "              childTargetURL = wOrigCreateObjectURL(wBlobMap.get(absChildURL));\n"
        "              wScheduleRevoke(childTargetURL, 5000);\n"
        "            } else if (wPendingWorkerURLs) {\n"
        "              wPendingWorkerURLs.add(absChildURL);\n"
        "              if (typeof setTimeout === 'function') {\n"
        "                setTimeout(function() { wPendingWorkerURLs.delete(absChildURL); }, 3000);\n"
        "              }\n"
        "            }\n"
        "          }\n"
        "          let childEntrySrc;\n"
        "          if (isChildModule) {\n"
        "            const childSetupURL = wOrigCreateObjectURL(new Blob([childBootCode], { type: 'text/javascript' }));\n"
        "            wScheduleRevoke(childSetupURL, 5000);\n"
        "            childEntrySrc = 'import ' + JSON.stringify(childSetupURL) + ';\\nimport ' + JSON.stringify(childTargetURL) + ';\\n';\n"
        "          } else {\n"
        "            childEntrySrc = childBootCode + '\\nimportScripts(' + JSON.stringify(childTargetURL) + ');\\n';\n"
        "          }\n"
        "          const childEntryURL = wOrigCreateObjectURL(new Blob([childEntrySrc], { type: 'text/javascript' }));\n"
        "          wScheduleRevoke(childEntryURL, 5000);\n"
        "          return hasOpts ? new OrigWorker(childEntryURL, options) : new OrigWorker(childEntryURL);\n"
        "        } catch (_) {\n"
        "          return hasOpts ? new OrigWorker(scriptURL, options) : new OrigWorker(scriptURL);\n"
        "        }\n"
        "      };\n"
        "      WrappedChildWorker.prototype = OrigWorker.prototype;\n"
        "      try { Object.setPrototypeOf(WrappedChildWorker, OrigWorker); } catch (_) {}\n"
        "      wMark(WrappedChildWorker, 'function Worker() { [native code] }', 'Worker');\n"
        "      wAssignGlobal('Worker', WrappedChildWorker);\n"
        "    }\n"
        "    if (isShared === true && typeof sharedName === 'string') {\n"
        "      const swgProto = (typeof SharedWorkerGlobalScope !== 'undefined' && SharedWorkerGlobalScope.prototype)\n"
        "        ? SharedWorkerGlobalScope.prototype\n"
        "        : null;\n"
        "      const nameOwn = (typeof self !== 'undefined') ? Object.getOwnPropertyDescriptor(self, 'name') : null;\n"
        "      const nameTarget = (nameOwn && nameOwn.configurable !== false)\n"
        "        ? self\n"
        "        : (swgProto ? swgProto : ((typeof self !== 'undefined') ? self : null));\n"
        "      wDefGetter(nameTarget, 'name', function() { return sharedName; });\n"
        "    }\n"
        "    if (isShared === true && typeof self !== 'undefined' && typeof self.addEventListener === 'function') {\n"
        "      const bridgedEvents = new WeakSet();\n"
        "      let userOnConnect = null;\n"
        "      let prevOnConnectWrapper = null;\n"
        "      const ocSelfDesc = Object.getOwnPropertyDescriptor(self, 'onconnect');\n"
        "      const ocProto = (typeof SharedWorkerGlobalScope !== 'undefined' && SharedWorkerGlobalScope.prototype)\n"
        "        ? SharedWorkerGlobalScope.prototype\n"
        "        : null;\n"
        "      const ocTarget = ocSelfDesc\n"
        "        ? self\n"
        "        : (ocProto && Object.getOwnPropertyDescriptor(ocProto, 'onconnect') ? ocProto : self);\n"
        "      try {\n"
        "        const ocDesc = Object.getOwnPropertyDescriptor(ocTarget, 'onconnect');\n"
        "        if (!ocDesc || ocDesc.configurable !== false) {\n"
        "          Object.defineProperty(ocTarget, 'onconnect', {\n"
        "            configurable: true,\n"
        "            enumerable: ocDesc ? ocDesc.enumerable : true,\n"
        "            get: wMark(function() { return userOnConnect; }, 'function get onconnect() { [native code] }', 'get onconnect'),\n"
        "            set: wMark(function(fn) {\n"
        "              if (prevOnConnectWrapper) {\n"
        "                self.removeEventListener('connect', prevOnConnectWrapper);\n"
        "                prevOnConnectWrapper = null;\n"
        "              }\n"
        "              if (typeof fn === 'function') {\n"
        "                userOnConnect = fn;\n"
        "                prevOnConnectWrapper = function(e) { return fn.call(this, e); };\n"
        "                self.addEventListener('connect', prevOnConnectWrapper);\n"
        "              } else {\n"
        "                userOnConnect = null;\n"
        "              }\n"
        "            }, 'function set onconnect() { [native code] }', 'set onconnect')\n"
        "          });\n"
        "        }\n"
        "      } catch (_) {}\n"
        "      self.addEventListener('connect', function(ev) {\n"
        "        if (!ev || bridgedEvents.has(ev)) return;\n"
        "        const carrierPort = ev.ports && ev.ports[0];\n"
        "        if (!carrierPort) return;\n"
        "        if (typeof ev.stopImmediatePropagation === 'function') ev.stopImmediatePropagation();\n"
        "        carrierPort.onmessage = function(mEv) {\n"
        "          const md = mEv && mEv.data;\n"
        "          if (!md || !md.__ptBridgeConnect || !mEv.ports || !mEv.ports[0]) return;\n"
        "          carrierPort.onmessage = null;\n"
        "          const userPort = mEv.ports[0];\n"
        "          const synOrigin = parsedBase ? parsedBase.origin : (typeof self.origin === 'string' ? self.origin : '');\n"
        "          let synEv = null;\n"
        "          try {\n"
        "            synEv = new MessageEvent('connect', { ports: [userPort], source: userPort, origin: synOrigin });\n"
        "          } catch (_) {\n"
        "            try {\n"
        "              synEv = new MessageEvent('connect', { ports: [userPort], origin: synOrigin });\n"
        "            } catch (_) {\n"
        "              synEv = new Event('connect');\n"
        "              try { Object.defineProperty(synEv, 'ports', { value: [userPort], enumerable: true }); } catch (_) {}\n"
        "              try { Object.defineProperty(synEv, 'source', { value: userPort, enumerable: true }); } catch (_) {}\n"
        "            }\n"
        "          }\n"
        "          bridgedEvents.add(synEv);\n"
        "          self.dispatchEvent(synEv);\n"
        "        };\n"
        "        if (typeof carrierPort.start === 'function') carrierPort.start();\n"
        "        try { carrierPort.postMessage({ __ptBridgeReady: 1 }); } catch (_) {}\n"
        "      }, true);\n"
        "    }\n"
        "  }\n"
        "  function sharedCoordMain() {\n"
        "    var entries = [];\n"
        "    var nextId = 1;\n"
        "    function handleMsg(port, ev) {\n"
        "      var d = ev && ev.data;\n"
        "      if (!d || typeof d !== 'object') return;\n"
        "      if (d.op === 'acquire') {\n"
        "        var absURL = String(d.absURL || '');\n"
        "        var isModule = Boolean(d.isModule);\n"
        "        var name = (d.name !== undefined && d.name !== null) ? String(d.name) : '';\n"
        "        var clientId = String(d.clientId || '');\n"
        "        var matched = null;\n"
        "        for (var i = 0; i < entries.length; i++) {\n"
        "          var e = entries[i];\n"
        "          if (!e.clients || e.clients.size === 0) continue;\n"
        "          if (name !== '') {\n"
        "            if (e.name === name) {\n"
        "              if (e.absURL !== absURL || e.isModule !== isModule) {\n"
        "                port.postMessage({ reqId: d.reqId, status: 'mismatch' });\n"
        "                return;\n"
        "              }\n"
        "              matched = e;\n"
        "              break;\n"
        "            }\n"
        "          } else {\n"
        "            if (e.name === '' && e.absURL === absURL && e.isModule === isModule) {\n"
        "              matched = e;\n"
        "              break;\n"
        "            }\n"
        "          }\n"
        "        }\n"
        "        if (matched) {\n"
        "          matched.clients.add(clientId);\n"
        "          port.postMessage({ reqId: d.reqId, status: 'reuse', entryId: matched.entryId, blobURL: matched.blobURL });\n"
        "          return;\n"
        "        }\n"
        "        var created = {\n"
        "          entryId: nextId++,\n"
        "          absURL: absURL,\n"
        "          isModule: isModule,\n"
        "          name: name,\n"
        "          blobURL: String(d.blobURL || ''),\n"
        "          clients: new Set()\n"
        "        };\n"
        "        created.clients.add(clientId);\n"
        "        entries.push(created);\n"
        "        port.postMessage({ reqId: d.reqId, status: 'elected', entryId: created.entryId, blobURL: created.blobURL });\n"
        "        return;\n"
        "      }\n"
        "      if (d.op === 'leave') {\n"
        "        var cid = String(d.clientId || '');\n"
        "        for (var j = entries.length - 1; j >= 0; j--) {\n"
        "          entries[j].clients.delete(cid);\n"
        "          if (entries[j].clients.size === 0) {\n"
        "            entries.splice(j, 1);\n"
        "          }\n"
        "        }\n"
        "        return;\n"
        "      }\n"
        "      if (d.op === 'invalidate') {\n"
        "        var eid = d.entryId;\n"
        "        var burl = d.blobURL;\n"
        "        for (var k = entries.length - 1; k >= 0; k--) {\n"
        "          if (entries[k].entryId === eid && (!burl || entries[k].blobURL === burl)) {\n"
        "            if (d.clientId) entries[k].clients.delete(String(d.clientId));\n"
        "            entries.splice(k, 1);\n"
        "          }\n"
        "        }\n"
        "        return;\n"
        "      }\n"
        "    }\n"
        "    self.addEventListener('connect', function(ev) {\n"
        "      var port = ev.ports && ev.ports[0];\n"
        "      if (!port) return;\n"
        "      port.addEventListener('message', function(mEv) {\n"
        "        handleMsg(port, mEv);\n"
        "      });\n"
        "      port.start();\n"
        "    });\n"
        "  }\n"
        "  const workerBootSrc = rawFnToString.call(workerBootstrap);\n"
        "  const sharedCoordSrc = '(' + rawFnToString.call(sharedCoordMain) + ')();';\n"
        "  function buildWorkerSetupCode(baseHref, isShared, sharedName) {\n"
        "    const bHref = (typeof baseHref === 'string') ? baseHref : '';\n"
        "    const sharedFlag = Boolean(isShared);\n"
        "    let argsStr = JSON.stringify(plat) + ',' + JSON.stringify(uaToken) + ',' + cores + ',' + JSON.stringify(bHref) + ',' + (sharedFlag ? 'true' : 'false') + ',' + JSON.stringify(workerBootSrc);\n"
        "    if (typeof sharedName === 'string') {\n"
        "      argsStr += ',' + JSON.stringify(sharedName);\n"
        "    }\n"
        "    return '(' + workerBootSrc + ')(' + argsStr + ');';\n"
        "  }\n"
        "  function patchWebGL(ctor, ObjCtor) {\n"
        "    if (!ctor || !ctor.prototype) return;\n"
        "    const proto = ctor.prototype;\n"
        "    if (typeof proto.getSupportedExtensions === 'function' && !wrappedFns.has(proto.getSupportedExtensions)) {\n"
        "      const origGetSupExts = proto.getSupportedExtensions;\n"
        "      const wrappedGetSupExts = ({ getSupportedExtensions() {\n"
        "        const list = origGetSupExts.apply(this, arguments);\n"
        "        if (!Array.isArray(list)) return list;\n"
        "        return list.filter(function(extName) {\n"
        "          return typeof extName === 'string' && !blockedWebGLExts.has(extName.toLowerCase());\n"
        "        });\n"
        "      } }).getSupportedExtensions;\n"
        "      markNativeFn(wrappedGetSupExts, 'function getSupportedExtensions() { [native code] }', 'getSupportedExtensions', ObjCtor);\n"
        "      try { proto.getSupportedExtensions = wrappedGetSupExts; } catch (_) {}\n"
        "    }\n"
        "    if (typeof proto.getExtension === 'function' && !wrappedFns.has(proto.getExtension)) {\n"
        "      const origGetExt = proto.getExtension;\n"
        "      const wrappedGetExt = ({ getExtension(name) {\n"
        "        if (typeof name === 'string' && blockedWebGLExts.has(name.toLowerCase())) {\n"
        "          return null;\n"
        "        }\n"
        "        const ext = origGetExt.apply(this, arguments);\n"
        "        try {\n"
        "          if (ext && typeof name === 'string' && name.toLowerCase() === 'webgl_debug_renderer_info') {\n"
        "            debugExtContexts.add(this);\n"
        "          }\n"
        "        } catch (_) {}\n"
        "        return ext;\n"
        "      } }).getExtension;\n"
        "      markNativeFn(wrappedGetExt, 'function getExtension() { [native code] }', 'getExtension', ObjCtor);\n"
        "      try { proto.getExtension = wrappedGetExt; } catch (_) {}\n"
        "    }\n"
        "    if (typeof proto.getParameter === 'function' && !wrappedFns.has(proto.getParameter)) {\n"
        "      const origGetParam = proto.getParameter;\n"
        "      const wrappedGetParam = ({ getParameter(pname) {\n"
        "        if (debugExtContexts.has(this)) {\n"
        "          if (pname === 37445) return 'Apple Inc.';\n"
        "          if (pname === 37446) return 'Apple GPU';\n"
        "        }\n"
        "        return origGetParam.apply(this, arguments);\n"
        "      } }).getParameter;\n"
        "      markNativeFn(wrappedGetParam, 'function getParameter() { [native code] }', 'getParameter', ObjCtor);\n"
        "      try { proto.getParameter = wrappedGetParam; } catch (_) {}\n"
        "    }\n"
        "  }\n"
        "  function makeEmptyArrayLike(proto, winObj) {\n"
        "    const Obj = (winObj && winObj.Object) || Object;\n"
        "    const arrProto = (winObj && winObj.Array && winObj.Array.prototype) || Array.prototype;\n"
        "    const iterFn = (typeof Symbol !== 'undefined' && Symbol.iterator) ? arrProto[Symbol.iterator] : null;\n"
        "    const obj = Obj.create(proto || Obj.prototype);\n"
        "    const itemFn = markNativeFn(({ item(index) { return null; } }).item, 'function item() { [native code] }', 'item', Obj);\n"
        "    const namedItemFn = markNativeFn(({ namedItem(name) { return null; } }).namedItem, 'function namedItem() { [native code] }', 'namedItem', Obj);\n"
        "    const refreshFn = markNativeFn(({ refresh() {} }).refresh, 'function refresh() { [native code] }', 'refresh', Obj);\n"
        "    Obj.defineProperty(obj, 'length', { value: 0, writable: false, enumerable: false, configurable: false });\n"
        "    Obj.defineProperty(obj, 'item', { value: itemFn, writable: false, enumerable: false, configurable: false });\n"
        "    Obj.defineProperty(obj, 'namedItem', { value: namedItemFn, writable: false, enumerable: false, configurable: false });\n"
        "    Obj.defineProperty(obj, 'refresh', { value: refreshFn, writable: false, enumerable: false, configurable: false });\n"
        "    if (iterFn && typeof iterFn === 'function') {\n"
        "      Obj.defineProperty(obj, Symbol.iterator, { value: iterFn, writable: false, enumerable: false, configurable: false });\n"
        "    }\n"
        "    return Obj.freeze(obj);\n"
        "  }\n"
        "  function evalMediaCmp(prefix, actual, val) {\n"
        "    if (prefix === 'min-') return actual >= val;\n"
        "    if (prefix === 'max-') return actual <= val;\n"
        "    return actual === val;\n"
        "  }\n"
        "  function rewriteMediaQuery(q, sw, sh) {\n"
        "    const orig = String(q);\n"
        "    let changed = false;\n"
        "    let rw = orig.replace(/\\(\\s*(any-)?pointer\\s*:\\s*(none|coarse|fine)\\s*\\)/gi, function(full, anyP, val) {\n"
        "      changed = true;\n"
        "      return (val.toLowerCase() === 'coarse') ? '(min-width: 0px)' : '(min-width: 999999px)';\n"
        "    });\n"
        "    rw = rw.replace(/\\(\\s*(any-)?hover\\s*:\\s*(none|hover)\\s*\\)/gi, function(full, anyP, val) {\n"
        "      changed = true;\n"
        "      return (val.toLowerCase() === 'none') ? '(min-width: 0px)' : '(min-width: 999999px)';\n"
        "    });\n"
        "    rw = rw.replace(/\\(\\s*(any-)?(pointer|hover)\\s*\\)/gi, function(full, anyP, feat) {\n"
        "      changed = true;\n"
        "      return (feat.toLowerCase() === 'pointer') ? '(min-width: 0px)' : '(min-width: 999999px)';\n"
        "    });\n"
        "    rw = rw.replace(/\\(\\s*(min-|max-)?device-(width|height)\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)px\\s*\\)/gi, function(full, pre, dim, numStr) {\n"
        "      const p = pre ? pre.toLowerCase() : '';\n"
        "      const actual = (dim.toLowerCase() === 'width') ? sw : sh;\n"
        "      const pass = evalMediaCmp(p, actual, parseFloat(numStr));\n"
        "      changed = true;\n"
        "      return pass ? '(min-width: 0px)' : '(min-width: 999999px)';\n"
        "    });\n"
        "    return changed ? rw : null;\n"
        "  }\n"
        "  function patchWindow(win) {\n"
        "    if (!win) return;\n"
        "    try {\n"
        "      const winObj = win.Object;\n"
        "      if (!winObj) return;\n"
        "      const FnProto = win.Function && win.Function.prototype;\n"
        "      if (patchedWindows.has(win) && FnProto && wrappedFns.has(FnProto.toString)) return;\n"
        "      patchedWindows.add(win);\n"
        "      if (FnProto && typeof FnProto.toString === 'function' && !wrappedFns.has(FnProto.toString)) {\n"
        "        const origFnToString = FnProto.toString;\n"
        "        const toStringWrapper = ({ toString() {\n"
        "          if (toStringMap.has(this)) {\n"
        "            return toStringMap.get(this);\n"
        "          }\n"
        "          return origFnToString.call(this);\n"
        "        } }).toString;\n"
        "        markNativeFn(toStringWrapper, 'function toString() { [native code] }', 'toString', winObj);\n"
        "        try {\n"
        "          winObj.defineProperty(FnProto, 'toString', {\n"
        "            value: toStringWrapper,\n"
        "            configurable: true,\n"
        "            writable: true,\n"
        "            enumerable: false\n"
        "          });\n"
        "        } catch (_) {}\n"
        "      }\n"
        "      const navProto = (win.Navigator && win.Navigator.prototype)\n"
        "        ? win.Navigator.prototype\n"
        "        : (win.navigator ? winObj.getPrototypeOf(win.navigator) : null);\n"
        "      if (navProto) {\n"
        "        const origUADesc = winObj.getOwnPropertyDescriptor(navProto, 'userAgent');\n"
        "        const origAVDesc = winObj.getOwnPropertyDescriptor(navProto, 'appVersion');\n"
        "        defGetter(navProto, 'platform', () => plat, win);\n"
        "        defGetter(navProto, 'hardwareConcurrency', () => cores, win);\n"
        "        defGetter(navProto, 'maxTouchPoints', () => 5, win);\n"
        "        defGetter(navProto, 'vendor', () => 'Apple Computer, Inc.', win);\n"
        "        defGetter(navProto, 'pdfViewerEnabled', () => false, win);\n"
        "        if (!('standalone' in navProto)) {\n"
        "          defGetter(navProto, 'standalone', () => false, win);\n"
        "        }\n"
        "        if ('userAgentData' in navProto) {\n"
        "          defGetter(navProto, 'userAgentData', () => undefined, win);\n"
        "        }\n"
        "        const emptyPlugins = makeEmptyArrayLike(win.PluginArray ? win.PluginArray.prototype : winObj.prototype, win);\n"
        "        const emptyMimeTypes = makeEmptyArrayLike(win.MimeTypeArray ? win.MimeTypeArray.prototype : winObj.prototype, win);\n"
        "        defGetter(navProto, 'plugins', () => emptyPlugins, win);\n"
        "        defGetter(navProto, 'mimeTypes', () => emptyMimeTypes, win);\n"
        "        if (origUADesc && typeof origUADesc.get === 'function') {\n"
        "          const uaGet = winObj.getOwnPropertyDescriptor(({ get userAgent() {\n"
        "            const ua = String(origUADesc.get.call(this) || '');\n"
        "            return ua.replace(/Macintosh;\\s*(?:Intel|Apple)?\\s*Mac OS X[^)]*/g, uaToken);\n"
        "          } }), 'userAgent').get;\n"
        "          defGetter(navProto, 'userAgent', uaGet, win);\n"
        "        }\n"
        "        if (origAVDesc && typeof origAVDesc.get === 'function') {\n"
        "          const avGet = winObj.getOwnPropertyDescriptor(({ get appVersion() {\n"
        "            const av = String(origAVDesc.get.call(this) || '');\n"
        "            return av.replace(/Macintosh;\\s*(?:Intel|Apple)?\\s*Mac OS X[^)]*/g, uaToken);\n"
        "          } }), 'appVersion').get;\n"
        "          defGetter(navProto, 'appVersion', avGet, win);\n"
        "        }\n"
        "      }\n"
        "      const md = win.navigator && win.navigator.mediaDevices;\n"
        "      const micLabel = (plat === 'iPhone') ? 'iPhone Microphone' : 'iPad Microphone';\n"
        "      const spkLabel = (plat === 'iPhone') ? 'iPhone Speakers' : 'iPad Speakers';\n"
        "      if (md) {\n"
        "        const mdProto = (win.MediaDevices && win.MediaDevices.prototype) || winObj.getPrototypeOf(md);\n"
        "        const mdTarget = (mdProto && typeof mdProto.enumerateDevices === 'function' && !winObj.getOwnPropertyDescriptor(md, 'enumerateDevices')) ? mdProto : md;\n"
        "        if (mdTarget && typeof mdTarget.enumerateDevices === 'function' && !wrappedFns.has(mdTarget.enumerateDevices)) {\n"
        "          const origEnum = mdTarget.enumerateDevices;\n"
        "          const sanitizeDevice = function(d) {\n"
        "            if (!d || typeof d.label !== 'string') return d;\n"
        "            const lbl = d.label;\n"
        "            if (!macDevLabelRe.test(lbl)) return d;\n"
        "            let newLabel = lbl;\n"
        "            if (macCamLabelRe.test(lbl) || d.kind === 'videoinput') {\n"
        "              newLabel = 'Front Camera';\n"
        "            } else {\n"
        "              newLabel = (d.kind === 'audiooutput' && /speaker|display/i.test(lbl)) ? spkLabel : micLabel;\n"
        "            }\n"
        "            if (newLabel === lbl) return d;\n"
        "            try {\n"
        "              const clone = winObj.create(winObj.getPrototypeOf(d));\n"
        "              const props = ['deviceId', 'kind', 'groupId'];\n"
        "              for (let i = 0; i < props.length; i++) {\n"
        "                winObj.defineProperty(clone, props[i], { value: d[props[i]], enumerable: true, configurable: true });\n"
        "              }\n"
        "              winObj.defineProperty(clone, 'label', { value: newLabel, enumerable: true, configurable: true });\n"
        "              if (typeof d.toJSON === 'function') {\n"
        "                const jsonFn = markNativeFn(({ toJSON() {\n"
        "                  return { deviceId: clone.deviceId, kind: clone.kind, label: clone.label, groupId: clone.groupId };\n"
        "                } }).toJSON, 'function toJSON() { [native code] }', 'toJSON', winObj);\n"
        "                winObj.defineProperty(clone, 'toJSON', { value: jsonFn, enumerable: false, configurable: true });\n"
        "              }\n"
        "              return clone;\n"
        "            } catch (_) {\n"
        "              return d;\n"
        "            }\n"
        "          };\n"
        "          const wrappedEnum = ({ enumerateDevices() {\n"
        "            return origEnum.apply(this, arguments).then(function(list) {\n"
        "              if (!win.Array.isArray(list)) return list;\n"
        "              return list.map(sanitizeDevice);\n"
        "            });\n"
        "          } }).enumerateDevices;\n"
        "          markNativeFn(wrappedEnum, 'function enumerateDevices() { [native code] }', 'enumerateDevices', winObj);\n"
        "          try { mdTarget.enumerateDevices = wrappedEnum; } catch (_) {}\n"
        "        }\n"
        "        const gdmTarget = (mdProto && typeof mdProto.getDisplayMedia === 'function' && !winObj.getOwnPropertyDescriptor(md, 'getDisplayMedia')) ? mdProto : md;\n"
        "        if (gdmTarget && typeof gdmTarget.getDisplayMedia === 'function' && !wrappedFns.has(gdmTarget.getDisplayMedia)) {\n"
        "          const wrappedGDM = ({ getDisplayMedia() {\n"
        "            const DE = win.DOMException || DOMException;\n"
        "            const err = DE ? new DE('The request is not allowed by the user agent.', 'NotAllowedError') : new win.Error('NotAllowedError');\n"
        "            return (win.Promise || Promise).reject(err);\n"
        "          } }).getDisplayMedia;\n"
        "          markNativeFn(wrappedGDM, 'function getDisplayMedia() { [native code] }', 'getDisplayMedia', winObj);\n"
        "          try { gdmTarget.getDisplayMedia = wrappedGDM; } catch (_) {}\n"
        "        }\n"
        "      }\n"
        "      const mstProto = win.MediaStreamTrack && win.MediaStreamTrack.prototype;\n"
        "      if (mstProto) {\n"
        "        const origMstLabel = winObj.getOwnPropertyDescriptor(mstProto, 'label');\n"
        "        if (origMstLabel && typeof origMstLabel.get === 'function' && origMstLabel.configurable !== false && !wrappedFns.has(origMstLabel.get)) {\n"
        "          const mstLabelGet = winObj.getOwnPropertyDescriptor(({ get label() {\n"
        "            const raw = String(origMstLabel.get.call(this) || '');\n"
        "            if (!macDevLabelRe.test(raw)) return raw;\n"
        "            if (macCamLabelRe.test(raw) || this.kind === 'video') return 'Front Camera';\n"
        "            return micLabel;\n"
        "          } }), 'label').get;\n"
        "          defGetter(mstProto, 'label', mstLabelGet, win);\n"
        "        }\n"
        "      }\n"
        "      const portraitW = Math.min(ptWidth, ptHeight);\n"
        "      const portraitH = Math.max(ptWidth, ptHeight);\n"
        "      const landscapeW = portraitH;\n"
        "      const landscapeH = portraitW;\n"
        "      const isLandscape = function() {\n"
        "        try {\n"
        "          const iw = win.innerWidth;\n"
        "          const ih = win.innerHeight;\n"
        "          return (iw > 0 && ih > 0 && iw > ih);\n"
        "        } catch (_) {\n"
        "          return false;\n"
        "        }\n"
        "      };\n"
        "      const screenProto = (win.Screen && win.Screen.prototype)\n"
        "        ? win.Screen.prototype\n"
        "        : (win.screen ? winObj.getPrototypeOf(win.screen) : null);\n"
        "      if (screenProto) {\n"
        "        defGetter(screenProto, 'width', () => isLandscape() ? landscapeW : portraitW, win);\n"
        "        defGetter(screenProto, 'height', () => isLandscape() ? landscapeH : portraitH, win);\n"
        "        defGetter(screenProto, 'availWidth', () => isLandscape() ? landscapeW : portraitW, win);\n"
        "        defGetter(screenProto, 'availHeight', () => isLandscape() ? landscapeH : portraitH, win);\n"
        "        defGetter(screenProto, 'availTop', () => 0, win);\n"
        "        defGetter(screenProto, 'availLeft', () => 0, win);\n"
        "        defGetter(screenProto, 'colorDepth', () => 24, win);\n"
        "        defGetter(screenProto, 'pixelDepth', () => 24, win);\n"
        "      }\n"
        "      const scrOri = win.screen && win.screen.orientation;\n"
        "      const scrOriProto = (win.ScreenOrientation && win.ScreenOrientation.prototype) || (scrOri ? winObj.getPrototypeOf(scrOri) : null);\n"
        "      if (scrOriProto && !patchedOriProtos.has(scrOriProto)) {\n"
        "        patchedOriProtos.add(scrOriProto);\n"
        "        defGetter(scrOriProto, 'type', () => isLandscape() ? 'landscape-primary' : 'portrait-primary', win);\n"
        "        defGetter(scrOriProto, 'angle', () => isLandscape() ? 90 : 0, win);\n"
        "      }\n"
        "      const protoTarget = (win.Window && win.Window.prototype && win.Window.prototype.isPrototypeOf(win)) ? win.Window.prototype : win;\n"
        "      const defWinGetter = function(prop, getterFn) {\n"
        "        const own = winObj.getOwnPropertyDescriptor(win, prop);\n"
        "        const target = own ? win : protoTarget;\n"
        "        defGetter(target, prop, getterFn, win);\n"
        "      };\n"
        "      defWinGetter('devicePixelRatio', () => dpr);\n"
        "      defWinGetter('orientation', () => isLandscape() ? 90 : 0);\n"
        "      defWinGetter('screenX', () => 0);\n"
        "      defWinGetter('screenY', () => 0);\n"
        "      defWinGetter('screenLeft', () => 0);\n"
        "      defWinGetter('screenTop', () => 0);\n"
        "      defWinGetter('outerWidth', () => (win.innerWidth > 0) ? win.innerWidth : (isLandscape() ? landscapeW : portraitW));\n"
        "      defWinGetter('outerHeight', () => (win.innerHeight > 0) ? win.innerHeight : (isLandscape() ? landscapeH : portraitH));\n"
        "      const ensureOnTouchProp = function(target, propName) {\n"
        "        if (!target || (propName in target)) return;\n"
        "        try {\n"
        "          const getter = markNativeFn(winObj.getOwnPropertyDescriptor(({ get v() {\n"
        "            return touchHandlerMap.has(this) ? touchHandlerMap.get(this) : null;\n"
        "          } }), 'v').get, 'function get ' + propName + '() { [native code] }', 'get ' + propName, winObj);\n"
        "          const setter = markNativeFn(winObj.getOwnPropertyDescriptor(({ set v(val) {\n"
        "            if (typeof val === 'function') touchHandlerMap.set(this, val);\n"
        "            else touchHandlerMap.delete(this);\n"
        "          } }), 'v').set, 'function set ' + propName + '() { [native code] }', 'set ' + propName, winObj);\n"
        "          winObj.defineProperty(target, propName, { get: getter, set: setter, configurable: true, enumerable: true });\n"
        "        } catch (_) {}\n"
        "      };\n"
        "      const touchProps = ['ontouchstart', 'ontouchmove', 'ontouchend', 'ontouchcancel'];\n"
        "      for (let ti = 0; ti < touchProps.length; ti++) {\n"
        "        const tp = touchProps[ti];\n"
        "        if (win.Window && win.Window.prototype) ensureOnTouchProp(win.Window.prototype, tp);\n"
        "        if (!(tp in win)) ensureOnTouchProp(win, tp);\n"
        "        if (win.Document && win.Document.prototype) ensureOnTouchProp(win.Document.prototype, tp);\n"
        "        if (win.HTMLElement && win.HTMLElement.prototype) ensureOnTouchProp(win.HTMLElement.prototype, tp);\n"
        "      }\n"
        "      if (typeof win.Touch !== 'function') {\n"
        "        const TouchCtor = function Touch(init) {\n"
        "          const opts = (init && typeof init === 'object') ? init : {};\n"
        "          this.identifier = opts.identifier || 0;\n"
        "          this.target = opts.target || null;\n"
        "          this.clientX = opts.clientX || 0;\n"
        "          this.clientY = opts.clientY || 0;\n"
        "          this.screenX = opts.screenX || 0;\n"
        "          this.screenY = opts.screenY || 0;\n"
        "          this.pageX = opts.pageX || 0;\n"
        "          this.pageY = opts.pageY || 0;\n"
        "          this.radiusX = opts.radiusX || 0;\n"
        "          this.radiusY = opts.radiusY || 0;\n"
        "          this.rotationAngle = opts.rotationAngle || 0;\n"
        "          this.force = opts.force || 0;\n"
        "        };\n"
        "        markNativeFn(TouchCtor, 'function Touch() { [native code] }', 'Touch', winObj);\n"
        "        try { winObj.defineProperty(win, 'Touch', { value: TouchCtor, configurable: true, writable: true, enumerable: false }); } catch (_) { win.Touch = TouchCtor; }\n"
        "      }\n"
        "      if (typeof win.TouchList !== 'function') {\n"
        "        const TouchListCtor = function TouchList(items) {\n"
        "          const n = (items && typeof items.length === 'number') ? (items.length >>> 0) : 0;\n"
        "          for (let i = 0; i < n; i++) this[i] = items[i];\n"
        "          this.length = n;\n"
        "        };\n"
        "        TouchListCtor.prototype.item = markNativeFn(function item(index) {\n"
        "          return (index >= 0 && index < this.length) ? this[index] : null;\n"
        "        }, 'function item() { [native code] }', 'item', winObj);\n"
        "        if (win.Symbol && win.Symbol.iterator && win.Array && win.Array.prototype[win.Symbol.iterator]) {\n"
        "          TouchListCtor.prototype[win.Symbol.iterator] = win.Array.prototype[win.Symbol.iterator];\n"
        "        }\n"
        "        markNativeFn(TouchListCtor, 'function TouchList() { [native code] }', 'TouchList', winObj);\n"
        "        try { winObj.defineProperty(win, 'TouchList', { value: TouchListCtor, configurable: true, writable: true, enumerable: false }); } catch (_) { win.TouchList = TouchListCtor; }\n"
        "      }\n"
        "      if (typeof win.TouchEvent !== 'function') {\n"
        "        const BaseEvent = win.UIEvent || win.Event || function Event(t) { this.type = String(t); };\n"
        "        const toTouchList = function(items) {\n"
        "          if (win.TouchList) {\n"
        "            if (items instanceof win.TouchList) return items;\n"
        "            return new win.TouchList(items);\n"
        "          }\n"
        "          return items || [];\n"
        "        };\n"
        "        const TouchEventCtor = function TouchEvent(type, init) {\n"
        "          const opts = (init && typeof init === 'object') ? init : {};\n"
        "          let ev;\n"
        "          try {\n"
        "            ev = win.Reflect ? win.Reflect.construct(BaseEvent, [type, opts], TouchEventCtor) : new BaseEvent(type, opts);\n"
        "          } catch (_) {\n"
        "            ev = this;\n"
        "            ev.type = String(type);\n"
        "          }\n"
        "          if (ev && ev !== this) {\n"
        "            try { winObj.setPrototypeOf(ev, TouchEventCtor.prototype); } catch (_) {}\n"
        "          }\n"
        "          const tgt = ev || this;\n"
        "          if (!('touches' in tgt)) tgt.touches = toTouchList(opts.touches);\n"
        "          if (!('targetTouches' in tgt)) tgt.targetTouches = toTouchList(opts.targetTouches);\n"
        "          if (!('changedTouches' in tgt)) tgt.changedTouches = toTouchList(opts.changedTouches);\n"
        "          if (!('altKey' in tgt)) tgt.altKey = Boolean(opts.altKey);\n"
        "          if (!('metaKey' in tgt)) tgt.metaKey = Boolean(opts.metaKey);\n"
        "          if (!('ctrlKey' in tgt)) tgt.ctrlKey = Boolean(opts.ctrlKey);\n"
        "          if (!('shiftKey' in tgt)) tgt.shiftKey = Boolean(opts.shiftKey);\n"
        "          return tgt;\n"
        "        };\n"
        "        try {\n"
        "          if (BaseEvent && BaseEvent.prototype) {\n"
        "            TouchEventCtor.prototype = winObj.create(BaseEvent.prototype);\n"
        "            TouchEventCtor.prototype.constructor = TouchEventCtor;\n"
        "          }\n"
        "        } catch (_) {}\n"
        "        markNativeFn(TouchEventCtor, 'function TouchEvent() { [native code] }', 'TouchEvent', winObj);\n"
        "        try { winObj.defineProperty(win, 'TouchEvent', { value: TouchEventCtor, configurable: true, writable: true, enumerable: false }); } catch (_) { win.TouchEvent = TouchEventCtor; }\n"
        "      }\n"
        "      const docProto = win.Document && win.Document.prototype;\n"
        "      if (docProto && typeof docProto.createEvent === 'function' && !wrappedFns.has(docProto.createEvent)) {\n"
        "        const origCreateEvent = docProto.createEvent;\n"
        "        const wrappedCreateEvent = ({ createEvent(type) {\n"
        "          if (typeof type === 'string' && type.toLowerCase() === 'touchevent') {\n"
        "            try { return origCreateEvent.call(this, type); } catch (_) {\n"
        "              if (typeof win.TouchEvent === 'function') return new win.TouchEvent('touchstart');\n"
        "            }\n"
        "          }\n"
        "          return origCreateEvent.apply(this, arguments);\n"
        "        } }).createEvent;\n"
        "        markNativeFn(wrappedCreateEvent, 'function createEvent() { [native code] }', 'createEvent', winObj);\n"
        "        try { docProto.createEvent = wrappedCreateEvent; } catch (_) {}\n"
        "      }\n"
        "      const mqlProto = win.MediaQueryList && win.MediaQueryList.prototype;\n"
        "      if (mqlProto) {\n"
        "        const origMediaDesc = winObj.getOwnPropertyDescriptor(mqlProto, 'media');\n"
        "        if (origMediaDesc && typeof origMediaDesc.get === 'function' && origMediaDesc.configurable !== false && !wrappedFns.has(origMediaDesc.get)) {\n"
        "          const mediaGet = winObj.getOwnPropertyDescriptor(({ get media() {\n"
        "            return mqlMediaMap.has(this) ? mqlMediaMap.get(this) : origMediaDesc.get.call(this);\n"
        "          } }), 'media').get;\n"
        "          defGetter(mqlProto, 'media', mediaGet, win);\n"
        "        }\n"
        "      }\n"
        "      const mmOwn = winObj.getOwnPropertyDescriptor(win, 'matchMedia');\n"
        "      const mmTarget = mmOwn ? win : ((win.Window && win.Window.prototype && typeof win.Window.prototype.matchMedia === 'function') ? win.Window.prototype : win);\n"
        "      if (mmTarget && typeof mmTarget.matchMedia === 'function' && !wrappedFns.has(mmTarget.matchMedia)) {\n"
        "        const origMatchMedia = mmTarget.matchMedia;\n"
        "        const wrappedMatchMedia = ({ matchMedia(query) {\n"
        "          const sw = isLandscape() ? landscapeW : portraitW;\n"
        "          const sh = isLandscape() ? landscapeH : portraitH;\n"
        "          const rw = rewriteMediaQuery(query, sw, sh);\n"
        "          if (rw === null) return origMatchMedia.apply(this, arguments);\n"
        "          const mql = origMatchMedia.call(this, rw);\n"
        "          if (mql && typeof mql === 'object') mqlMediaMap.set(mql, String(query));\n"
        "          return mql;\n"
        "        } }).matchMedia;\n"
        "        markNativeFn(wrappedMatchMedia, 'function matchMedia() { [native code] }', 'matchMedia', winObj);\n"
        "        try { mmTarget.matchMedia = wrappedMatchMedia; } catch (_) {}\n"
        "      }\n"
        "      if (win.CSS && typeof win.CSS.supports === 'function' && !wrappedFns.has(win.CSS.supports)) {\n"
        "        const origCSSSupports = win.CSS.supports;\n"
        "        const wrappedCSSSupports = ({ supports(prop, value) {\n"
        "          if (typeof prop === 'string' && /^-webkit-(?:touch-callout|overflow-scrolling)\\b/i.test(prop.trim())) {\n"
        "            return true;\n"
        "          }\n"
        "          return origCSSSupports.apply(this, arguments);\n"
        "        } }).supports;\n"
        "        markNativeFn(wrappedCSSSupports, 'function supports() { [native code] }', 'supports', winObj);\n"
        "        try { win.CSS.supports = wrappedCSSSupports; } catch (_) {}\n"
        "      }\n"
        "      if (typeof win.WebGLRenderingContext !== 'undefined') patchWebGL(win.WebGLRenderingContext, winObj);\n"
        "      if (typeof win.WebGL2RenderingContext !== 'undefined') patchWebGL(win.WebGL2RenderingContext, winObj);\n"
        "      if (typeof win.OffscreenCanvas !== 'undefined' && win.OffscreenCanvas.prototype && typeof win.OffscreenCanvas.prototype.getContext === 'function' && !wrappedFns.has(win.OffscreenCanvas.prototype.getContext)) {\n"
        "        const origOffscreenGetContext = win.OffscreenCanvas.prototype.getContext;\n"
        "        const wrappedOffscreenGetContext = function getContext(contextType) {\n"
        "          const ctx = origOffscreenGetContext.apply(this, arguments);\n"
        "          try {\n"
        "            if (ctx && (contextType === 'webgl' || contextType === 'experimental-webgl' || contextType === 'webgl2')) {\n"
        "              const ctxProto = winObj.getPrototypeOf(ctx);\n"
        "              if (ctxProto && typeof ctxProto.getParameter === 'function' && !wrappedFns.has(ctxProto.getParameter)) {\n"
        "                patchWebGL(ctxProto.constructor || { prototype: ctxProto }, winObj);\n"
        "              }\n"
        "            }\n"
        "          } catch (_) {}\n"
        "          return ctx;\n"
        "        };\n"
        "        markNativeFn(wrappedOffscreenGetContext, 'function getContext() { [native code] }', 'getContext', winObj);\n"
        "        try { win.OffscreenCanvas.prototype.getContext = wrappedOffscreenGetContext; } catch (_) {}\n"
        "      }\n"
        "      const iframeProto = win.HTMLIFrameElement && win.HTMLIFrameElement.prototype;\n"
        "      if (iframeProto) {\n"
        "        const cwDesc = winObj.getOwnPropertyDescriptor(iframeProto, 'contentWindow');\n"
        "        if (cwDesc && typeof cwDesc.get === 'function' && cwDesc.configurable !== false && !wrappedFns.has(cwDesc.get)) {\n"
        "          const origCWGet = cwDesc.get;\n"
        "          const cwGetFn = winObj.getOwnPropertyDescriptor(({ get contentWindow() {\n"
        "            const cw = origCWGet.call(this);\n"
        "            try { if (cw) patchWindow(cw); } catch (_) {}\n"
        "            return cw;\n"
        "          } }), 'contentWindow').get;\n"
        "          defGetter(iframeProto, 'contentWindow', cwGetFn, win);\n"
        "        }\n"
        "        const cdDesc = winObj.getOwnPropertyDescriptor(iframeProto, 'contentDocument');\n"
        "        if (cdDesc && typeof cdDesc.get === 'function' && cdDesc.configurable !== false && !wrappedFns.has(cdDesc.get)) {\n"
        "          const origCDGet = cdDesc.get;\n"
        "          const cdGetFn = winObj.getOwnPropertyDescriptor(({ get contentDocument() {\n"
        "            const cd = origCDGet.call(this);\n"
        "            try {\n"
        "              const cw = (cd && cd.defaultView) || (cwDesc && typeof cwDesc.get === 'function' ? cwDesc.get.call(this) : null);\n"
        "              if (cw) patchWindow(cw);\n"
        "            } catch (_) {}\n"
        "            return cd;\n"
        "          } }), 'contentDocument').get;\n"
        "          defGetter(iframeProto, 'contentDocument', cdGetFn, win);\n"
        "        }\n"
        "      }\n"
        "      const nodeProto = win.Node && win.Node.prototype;\n"
        "      if (nodeProto) {\n"
        "        if (typeof nodeProto.appendChild === 'function' && !wrappedFns.has(nodeProto.appendChild)) {\n"
        "          const origAppend = nodeProto.appendChild;\n"
        "          const wrappedAppend = ({ appendChild(node) {\n"
        "            const res = origAppend.apply(this, arguments);\n"
        "            if (node && node.tagName === 'IFRAME') {\n"
        "              try { if (node.contentWindow) patchWindow(node.contentWindow); } catch (_) {}\n"
        "            }\n"
        "            return res;\n"
        "          } }).appendChild;\n"
        "          markNativeFn(wrappedAppend, 'function appendChild() { [native code] }', 'appendChild', winObj);\n"
        "          try { nodeProto.appendChild = wrappedAppend; } catch (_) {}\n"
        "        }\n"
        "        if (typeof nodeProto.insertBefore === 'function' && !wrappedFns.has(nodeProto.insertBefore)) {\n"
        "          const origInsert = nodeProto.insertBefore;\n"
        "          const wrappedInsert = ({ insertBefore(newNode, referenceNode) {\n"
        "            const res = origInsert.apply(this, arguments);\n"
        "            if (newNode && newNode.tagName === 'IFRAME') {\n"
        "              try { if (newNode.contentWindow) patchWindow(newNode.contentWindow); } catch (_) {}\n"
        "            }\n"
        "            return res;\n"
        "          } }).insertBefore;\n"
        "          markNativeFn(wrappedInsert, 'function insertBefore() { [native code] }', 'insertBefore', winObj);\n"
        "          try { nodeProto.insertBefore = wrappedInsert; } catch (_) {}\n"
        "        }\n"
        "      }\n"
        "      if (typeof win.open === 'function' && !wrappedFns.has(win.open)) {\n"
        "        const origWinOpen = win.open;\n"
        "        const wrappedWinOpen = ({ open() {\n"
        "          const opened = origWinOpen.apply(this, arguments);\n"
        "          try { if (opened) patchWindow(opened); } catch (_) {}\n"
        "          return opened;\n"
        "        } }).open;\n"
        "        markNativeFn(wrappedWinOpen, 'function open() { [native code] }', 'open', winObj);\n"
        "        try { win.open = wrappedWinOpen; } catch (_) {}\n"
        "      }\n"
        "      const winBlob = win.Blob || Blob;\n"
        "      const winURL = win.URL || URL;\n"
        "      if (typeof winBlob === 'function' && typeof winURL === 'function' && typeof winURL.createObjectURL === 'function') {\n"
        "        let winSetupModURL = null;\n"
        "        const origCreateObjectURL = winURL.createObjectURL.bind(winURL);\n"
        "        const origRevokeObjectURL = (typeof winURL.revokeObjectURL === 'function') ? winURL.revokeObjectURL.bind(winURL) : null;\n"
        "        function scheduleBlobRevoke(u, ms) {\n"
        "          if (!origRevokeObjectURL || !u || typeof setTimeout !== 'function') return;\n"
        "          setTimeout(function() { try { origRevokeObjectURL(u); } catch (_) {} }, ms);\n"
        "        }\n"
        "        if (ptBlobMap && !wrappedFns.has(winURL.createObjectURL)) {\n"
        "          const wrappedCreate = ({ createObjectURL(obj) {\n"
        "            const u = origCreateObjectURL(obj);\n"
        "            try {\n"
        "              const isBlobObj = (obj instanceof winBlob) || (typeof Blob === 'function' && obj instanceof Blob) ||\n"
        "                (obj && typeof obj === 'object' && typeof obj.size === 'number' && typeof obj.type === 'string' && typeof obj.slice === 'function');\n"
        "              if (typeof u === 'string' && isBlobObj && obj.size <= 4194304) {\n"
        "                if (ptBlobMap.size >= 128) {\n"
        "                  const oldest = ptBlobMap.keys().next();\n"
        "                  if (!oldest.done) ptBlobMap.delete(oldest.value);\n"
        "                }\n"
        "                ptBlobMap.set(u, obj);\n"
        "              }\n"
        "            } catch (_) {}\n"
        "            return u;\n"
        "          } }).createObjectURL;\n"
        "          markNativeFn(wrappedCreate, 'function createObjectURL() { [native code] }', 'createObjectURL', winObj);\n"
        "          try { winURL.createObjectURL = wrappedCreate; } catch (_) {}\n"
        "        }\n"
        "        if (origRevokeObjectURL && !wrappedFns.has(winURL.revokeObjectURL)) {\n"
        "          const wrappedRevoke = ({ revokeObjectURL(u) {\n"
        "            const key = String(u);\n"
        "            if (ptBlobMap) ptBlobMap.delete(key);\n"
        "            if (ptPendingWorkerURLs && ptPendingWorkerURLs.has(key)) {\n"
        "              scheduleBlobRevoke(u, 3000);\n"
        "              return;\n"
        "            }\n"
        "            return origRevokeObjectURL(u);\n"
        "          } }).revokeObjectURL;\n"
        "          markNativeFn(wrappedRevoke, 'function revokeObjectURL() { [native code] }', 'revokeObjectURL', winObj);\n"
        "          try { winURL.revokeObjectURL = wrappedRevoke; } catch (_) {}\n"
        "        }\n"
        "        let coordPort = null;\n"
        "        let coordBroken = false;\n"
        "        let nextCoordReqId = 1;\n"
        "        const pendingCoordReqs = (typeof Map === 'function') ? new Map() : null;\n"
        "        const swClientId = 'c_' + Math.random().toString(36).slice(2) + '_' + Date.now().toString(36);\n"
        "        let leaveHookInstalled = false;\n"
        "        function ensureSharedCoord(OrigSW, winOrigin) {\n"
        "          if (coordBroken) return null;\n"
        "          if (coordPort) return coordPort;\n"
        "          try {\n"
        "            const coordURL = 'data:text/javascript;charset=utf-8,' + encodeURIComponent(sharedCoordSrc);\n"
        "            const coordSW = new OrigSW(coordURL, '__pt_sw_coord__:' + winOrigin);\n"
        "            coordPort = coordSW.port;\n"
        "            coordPort.onmessage = function(ev) {\n"
        "              const msg = ev && ev.data;\n"
        "              if (!msg || !msg.reqId || !pendingCoordReqs) return;\n"
        "              const cb = pendingCoordReqs.get(msg.reqId);\n"
        "              if (cb) {\n"
        "                pendingCoordReqs.delete(msg.reqId);\n"
        "                cb(msg);\n"
        "              }\n"
        "            };\n"
        "            coordSW.onerror = function() {\n"
        "              coordBroken = true;\n"
        "              coordPort = null;\n"
        "              if (pendingCoordReqs) {\n"
        "                pendingCoordReqs.forEach(function(cb) {\n"
        "                  try { cb({ status: 'fallback' }); } catch (_) {}\n"
        "                });\n"
        "                pendingCoordReqs.clear();\n"
        "              }\n"
        "            };\n"
        "            coordPort.start();\n"
        "            if (!leaveHookInstalled && typeof win.addEventListener === 'function') {\n"
        "              leaveHookInstalled = true;\n"
        "              const sendLeave = function(ev) {\n"
        "                if (ev && ev.type === 'pagehide' && ev.persisted) return;\n"
        "                if (coordPort) {\n"
        "                  try { coordPort.postMessage({ op: 'leave', clientId: swClientId }); } catch (_) {}\n"
        "                }\n"
        "                if (pendingCoordReqs) pendingCoordReqs.clear();\n"
        "                if (ptBlobMap) ptBlobMap.clear();\n"
        "              };\n"
        "              win.addEventListener('pagehide', sendLeave);\n"
        "              win.addEventListener('unload', sendLeave);\n"
        "            }\n"
        "            return coordPort;\n"
        "          } catch (_) {\n"
        "            coordBroken = true;\n"
        "            coordPort = null;\n"
        "            return null;\n"
        "          }\n"
        "        }\n"
        "        function createEntryBundle(targetURL, logicalBase, isModule, asBridged, swName, keepAlive) {\n"
        "          const bootCode = buildWorkerSetupCode(logicalBase, asBridged, swName);\n"
        "          let setupURL = null;\n"
        "          let ownSetupURL = null;\n"
        "          let entrySrc;\n"
        "          if (isModule) {\n"
        "            if (logicalBase === '' && !asBridged) {\n"
        "              if (!winSetupModURL) {\n"
        "                winSetupModURL = origCreateObjectURL(new winBlob([bootCode], { type: 'text/javascript' }));\n"
        "              }\n"
        "              setupURL = winSetupModURL;\n"
        "            } else {\n"
        "              ownSetupURL = origCreateObjectURL(new winBlob([bootCode], { type: 'text/javascript' }));\n"
        "              setupURL = ownSetupURL;\n"
        "              if (!asBridged && !keepAlive) scheduleBlobRevoke(ownSetupURL, 60000);\n"
        "            }\n"
        "            entrySrc = 'import ' + JSON.stringify(setupURL) + ';\\nimport ' + JSON.stringify(targetURL) + ';\\n';\n"
        "          } else {\n"
        "            entrySrc = bootCode + '\\nimportScripts(' + JSON.stringify(targetURL) + ');\\n';\n"
        "          }\n"
        "          const entryURL = origCreateObjectURL(new winBlob([entrySrc], { type: 'text/javascript' }));\n"
        "          return { entryURL: entryURL, setupURL: ownSetupURL };\n"
        "        }\n"
        "        function revokeBundle(bundle) {\n"
        "          if (!bundle || !origRevokeObjectURL) return;\n"
        "          if (bundle.entryURL) { try { origRevokeObjectURL(bundle.entryURL); } catch (_) {} }\n"
        "          if (bundle.setupURL) { try { origRevokeObjectURL(bundle.setupURL); } catch (_) {} }\n"
        "        }\n"
        "        function wrapWorkerCtor(ctorName) {\n"
        "          const Orig = win[ctorName];\n"
        "          if (typeof Orig !== 'function' || wrappedFns.has(Orig)) return;\n"
        "          const Wrapped = function(scriptURL) {\n"
        "            if (arguments.length === 0) {\n"
        "              return new Orig();\n"
        "            }\n"
        "            const hasOpts = arguments.length > 1;\n"
        "            const options = hasOpts ? arguments[1] : undefined;\n"
        "            if (!new.target) {\n"
        "              return hasOpts ? Orig(scriptURL, options) : Orig(scriptURL);\n"
        "            }\n"
        "            try {\n"
        "              const rawStr = String(scriptURL);\n"
        "              if (/^javascript:/i.test(rawStr.trim())) {\n"
        "                return hasOpts ? new Orig(scriptURL, options) : new Orig(scriptURL);\n"
        "              }\n"
        "              const baseLoc = (win.document && win.document.baseURI)\n"
        "                ? win.document.baseURI\n"
        "                : ((win.location && win.location.href) ? win.location.href : location.href);\n"
        "              const absURL = new winURL(rawStr, baseLoc).href;\n"
        "              if (/^(?:javascript|file|pt-vfile):/i.test(absURL)) {\n"
        "                return hasOpts ? new Orig(scriptURL, options) : new Orig(scriptURL);\n"
        "              }\n"
        "              let workerName = '';\n"
        "              let isModule = false;\n"
        "              if (typeof options === 'string') {\n"
        "                workerName = options;\n"
        "              } else if (options && typeof options === 'object') {\n"
        "                if ('type' in options && options.type !== undefined && options.type !== 'classic' && options.type !== 'module') {\n"
        "                  return new Orig(scriptURL, options);\n"
        "                }\n"
        "                workerName = (options.name !== undefined) ? String(options.name) : '';\n"
        "                isModule = (options.type === 'module');\n"
        "              }\n"
        "              const winOrigin = win.location ? win.location.origin : (typeof location !== 'undefined' ? location.origin : '');\n"
        "              if (winOrigin === 'null') {\n"
        "                if (/^data:/i.test(absURL)) {\n"
        "                  const dataBootCode = buildWorkerSetupCode('', false);\n"
        "                  let dEntry;\n"
        "                  if (isModule) {\n"
        "                    const dSetup = 'data:text/javascript;charset=utf-8,' + encodeURIComponent(dataBootCode);\n"
        "                    dEntry = 'data:text/javascript;charset=utf-8,' + encodeURIComponent('import ' + JSON.stringify(dSetup) + ';\\nimport ' + JSON.stringify(absURL) + ';\\n');\n"
        "                  } else {\n"
        "                    dEntry = 'data:text/javascript;charset=utf-8,' + encodeURIComponent(dataBootCode + '\\nimportScripts(' + JSON.stringify(absURL) + ');\\n');\n"
        "                  }\n"
        "                  return hasOpts ? new Orig(dEntry, options) : new Orig(dEntry);\n"
        "                }\n"
        "                return hasOpts ? new Orig(scriptURL, options) : new Orig(scriptURL);\n"
        "              }\n"
        "              const isBlob = /^blob:/i.test(absURL);\n"
        "              const isData = /^data:/i.test(absURL);\n"
        "              if (!isBlob && !isData && winOrigin && winOrigin !== 'null') {\n"
        "                let targetOrigin = '';\n"
        "                try { targetOrigin = new winURL(absURL).origin; } catch (_) {}\n"
        "                if (targetOrigin && targetOrigin !== winOrigin) {\n"
        "                  return hasOpts ? new Orig(scriptURL, options) : new Orig(scriptURL);\n"
        "                }\n"
        "              }\n"
        "              if (ctorName === 'SharedWorker' && !isBlob && !isData && winOrigin && winOrigin !== 'null') {\n"
        "                const cPort = ensureSharedCoord(Orig, winOrigin);\n"
        "                const WinMC = win.MessageChannel || (typeof MessageChannel !== 'undefined' ? MessageChannel : null);\n"
        "                if (cPort && typeof WinMC === 'function' && pendingCoordReqs) {\n"
        "                  const mc = new WinMC();\n"
        "                  const WinET = win.EventTarget || (typeof EventTarget !== 'undefined' ? EventTarget : null);\n"
        "                  const sw = (typeof WinET === 'function') ? new WinET() : winObj.create(Orig.prototype);\n"
        "                  if (typeof WinET === 'function') {\n"
        "                    try { winObj.setPrototypeOf(sw, Orig.prototype); } catch (_) {}\n"
        "                  }\n"
        "                  winObj.defineProperty(sw, 'port', {\n"
        "                    configurable: true,\n"
        "                    enumerable: true,\n"
        "                    get: markNativeFn(function() { return mc.port1; }, 'function get port() { [native code] }', 'get port', winObj)\n"
        "                  });\n"
        "                  let onErrorHandler = null;\n"
        "                  let onErrorListener = null;\n"
        "                  winObj.defineProperty(sw, 'onerror', {\n"
        "                    configurable: true,\n"
        "                    enumerable: true,\n"
        "                    get: markNativeFn(function() { return onErrorHandler; }, 'function get onerror() { [native code] }', 'get onerror', winObj),\n"
        "                    set: markNativeFn(function(fn) {\n"
        "                      if (typeof fn === 'function') {\n"
        "                        onErrorHandler = fn;\n"
        "                        if (!onErrorListener && typeof sw.addEventListener === 'function') {\n"
        "                          onErrorListener = function(ev) {\n"
        "                            if (typeof onErrorHandler === 'function') {\n"
        "                              return onErrorHandler.call(this, ev);\n"
        "                            }\n"
        "                          };\n"
        "                          sw.addEventListener('error', onErrorListener);\n"
        "                        }\n"
        "                      } else {\n"
        "                        onErrorHandler = null;\n"
        "                        if (onErrorListener && typeof sw.removeEventListener === 'function') {\n"
        "                          sw.removeEventListener('error', onErrorListener);\n"
        "                          onErrorListener = null;\n"
        "                        }\n"
        "                      }\n"
        "                    }, 'function set onerror() { [native code] }', 'set onerror', winObj)\n"
        "                  });\n"
        "                  const dispatchSwError = function(msg, srcEv) {\n"
        "                    let errEv = null;\n"
        "                    try {\n"
        "                      const EECtor = win.ErrorEvent || (typeof ErrorEvent !== 'undefined' ? ErrorEvent : null);\n"
        "                      if (typeof EECtor === 'function') {\n"
        "                        errEv = new EECtor('error', {\n"
        "                          message: msg || (srcEv && srcEv.message) || 'SharedWorker error',\n"
        "                          filename: (srcEv && srcEv.filename) || absURL,\n"
        "                          lineno: (srcEv && srcEv.lineno) || 0,\n"
        "                          colno: (srcEv && srcEv.colno) || 0,\n"
        "                          error: (srcEv && srcEv.error) || undefined\n"
        "                        });\n"
        "                      }\n"
        "                    } catch (_) {}\n"
        "                    if (!errEv) {\n"
        "                      try {\n"
        "                        const EvCtor = win.Event || Event;\n"
        "                        errEv = new EvCtor('error');\n"
        "                      } catch (_) {}\n"
        "                    }\n"
        "                    if (errEv && typeof sw.dispatchEvent === 'function') {\n"
        "                      try { sw.dispatchEvent(errEv); } catch (_) {}\n"
        "                    }\n"
        "                  };\n"
        "                  const bridgeToRealSW = function(realSW, onBeforeBridgeError) {\n"
        "                    let bridgeReady = false;\n"
        "                    realSW.onerror = function(ev) {\n"
        "                      if (!bridgeReady && typeof onBeforeBridgeError === 'function') {\n"
        "                        if (onBeforeBridgeError(ev)) return;\n"
        "                      }\n"
        "                      dispatchSwError(null, ev);\n"
        "                    };\n"
        "                    realSW.port.onmessage = function(mEv) {\n"
        "                      const md = mEv && mEv.data;\n"
        "                      if (!md || !md.__ptBridgeReady || bridgeReady) return;\n"
        "                      bridgeReady = true;\n"
        "                      realSW.port.onmessage = null;\n"
        "                      try {\n"
        "                        realSW.port.postMessage({ __ptBridgeConnect: 1 }, [mc.port2]);\n"
        "                      } catch (_) {\n"
        "                        dispatchSwError('SharedWorker bridge error');\n"
        "                      }\n"
        "                    };\n"
        "                    realSW.port.start();\n"
        "                  };\n"
        "                  const connectLocalFallback = function(candBundle) {\n"
        "                    let fbURL = candBundle.entryURL;\n"
        "                    if (ptSharedEntries) {\n"
        "                      const fbKey = winOrigin + '|fb|' + absURL + (isModule ? '|m|' : '|c|') + workerName;\n"
        "                      if (ptSharedEntries.has(fbKey)) {\n"
        "                        fbURL = ptSharedEntries.get(fbKey);\n"
        "                        revokeBundle(candBundle);\n"
        "                      } else if (ptSharedEntries.size < 128) {\n"
        "                        ptSharedEntries.set(fbKey, fbURL);\n"
        "                      }\n"
        "                    }\n"
        "                    try {\n"
        "                      const realSW = hasOpts ? new Orig(fbURL, options) : new Orig(fbURL);\n"
        "                      bridgeToRealSW(realSW, null);\n"
        "                    } catch (_) {\n"
        "                      dispatchSwError('SharedWorker construction failed');\n"
        "                    }\n"
        "                  };\n"
        "                  const acquireAndConnect = function(retried) {\n"
        "                    const cand = createEntryBundle(absURL, absURL, isModule, true, workerName, true);\n"
        "                    const reqId = nextCoordReqId++;\n"
        "                    pendingCoordReqs.set(reqId, function(reply) {\n"
        "                      if (!reply || reply.status === 'fallback') {\n"
        "                        connectLocalFallback(cand);\n"
        "                        return;\n"
        "                      }\n"
        "                      if (reply.status === 'mismatch') {\n"
        "                        revokeBundle(cand);\n"
        "                        dispatchSwError('URLMismatchError');\n"
        "                        return;\n"
        "                      }\n"
        "                      const resolvedBlobURL = reply.blobURL;\n"
        "                      if (reply.status === 'reuse') {\n"
        "                        revokeBundle(cand);\n"
        "                      }\n"
        "                      const internalName = '__pt_sw_inst__:' + reply.entryId;\n"
        "                      let swOpts;\n"
        "                      if (isModule) {\n"
        "                        swOpts = (options && typeof options === 'object' && options.credentials !== undefined)\n"
        "                          ? { type: 'module', name: internalName, credentials: options.credentials }\n"
        "                          : { type: 'module', name: internalName };\n"
        "                      } else {\n"
        "                        swOpts = internalName;\n"
        "                      }\n"
        "                      let realSW;\n"
        "                      try {\n"
        "                        realSW = new Orig(resolvedBlobURL, swOpts);\n"
        "                      } catch (_) {\n"
        "                        if (coordPort) {\n"
        "                          try { coordPort.postMessage({ op: 'invalidate', entryId: reply.entryId, blobURL: resolvedBlobURL, clientId: swClientId }); } catch (_) {}\n"
        "                        }\n"
        "                        if (reply.status === 'elected') revokeBundle(cand);\n"
        "                        if (reply.status === 'reuse' && !retried) {\n"
        "                          acquireAndConnect(true);\n"
        "                          return;\n"
        "                        }\n"
        "                        dispatchSwError('SharedWorker instantiation failed');\n"
        "                        return;\n"
        "                      }\n"
        "                      bridgeToRealSW(realSW, function() {\n"
        "                        if (coordPort) {\n"
        "                          try { coordPort.postMessage({ op: 'invalidate', entryId: reply.entryId, blobURL: resolvedBlobURL, clientId: swClientId }); } catch (_) {}\n"
        "                        }\n"
        "                        if (reply.status === 'elected') revokeBundle(cand);\n"
        "                        if (reply.status === 'reuse' && !retried) {\n"
        "                          try { realSW.port.close(); } catch (_) {}\n"
        "                          acquireAndConnect(true);\n"
        "                          return true;\n"
        "                        }\n"
        "                        return false;\n"
        "                      });\n"
        "                    });\n"
        "                    try {\n"
        "                      cPort.postMessage({\n"
        "                        op: 'acquire',\n"
        "                        reqId: reqId,\n"
        "                        clientId: swClientId,\n"
        "                        absURL: absURL,\n"
        "                        isModule: isModule,\n"
        "                        name: workerName,\n"
        "                        blobURL: cand.entryURL\n"
        "                      });\n"
        "                    } catch (_) {\n"
        "                      pendingCoordReqs.delete(reqId);\n"
        "                      coordBroken = true;\n"
        "                      coordPort = null;\n"
        "                      connectLocalFallback(cand);\n"
        "                    }\n"
        "                  };\n"
        "                  acquireAndConnect(false);\n"
        "                  return sw;\n"
        "                }\n"
        "              }\n"
        "              const sharedKey = (ctorName === 'SharedWorker' && ptSharedEntries)\n"
        "                ? ((winOrigin || '') + '|' + absURL + (isModule ? '|m|' : '|c|') + workerName)\n"
        "                : null;\n"
        "              if (sharedKey && ptSharedEntries.has(sharedKey)) {\n"
        "                const cachedURL = ptSharedEntries.get(sharedKey);\n"
        "                return hasOpts ? new Orig(cachedURL, options) : new Orig(cachedURL);\n"
        "              }\n"
        "              let targetURL;\n"
        "              if (isBlob) {\n"
        "                if (ptBlobMap && ptBlobMap.has(absURL)) {\n"
        "                  targetURL = origCreateObjectURL(ptBlobMap.get(absURL));\n"
        "                  if (!sharedKey) scheduleBlobRevoke(targetURL, 5000);\n"
        "                } else {\n"
        "                  targetURL = absURL;\n"
        "                  if (ptPendingWorkerURLs) {\n"
        "                    ptPendingWorkerURLs.add(absURL);\n"
        "                    if (typeof setTimeout === 'function') {\n"
        "                      setTimeout(function() { ptPendingWorkerURLs.delete(absURL); }, 3000);\n"
        "                    }\n"
        "                  }\n"
        "                }\n"
        "              } else {\n"
        "                targetURL = absURL;\n"
        "              }\n"
        "              const logicalBaseHref = (!isBlob && !isData) ? targetURL : '';\n"
        "              const bundle = createEntryBundle(targetURL, logicalBaseHref, isModule, false, undefined, sharedKey != null);\n"
        "              if (sharedKey && ptSharedEntries) {\n"
        "                if (ptSharedEntries.size < 128) ptSharedEntries.set(sharedKey, bundle.entryURL);\n"
        "              } else {\n"
        "                scheduleBlobRevoke(bundle.entryURL, 5000);\n"
        "              }\n"
        "              return hasOpts ? new Orig(bundle.entryURL, options) : new Orig(bundle.entryURL);\n"
        "            } catch (_) {\n"
        "              return hasOpts ? new Orig(scriptURL, options) : new Orig(scriptURL);\n"
        "            }\n"
        "          };\n"
        "          Wrapped.prototype = Orig.prototype;\n"
        "          try { winObj.setPrototypeOf(Wrapped, Orig); } catch (_) {}\n"
        "          markNativeFn(Wrapped, 'function ' + ctorName + '() { [native code] }', ctorName, winObj);\n"
        "          try { win[ctorName] = Wrapped; } catch (_) {}\n"
        "        }\n"
        "        wrapWorkerCtor('Worker');\n"
        "        wrapWorkerCtor('SharedWorker');\n"
        "      }\n"
        "    } catch (_) {}\n"
        "  }\n"
        "  if (typeof window !== 'undefined') patchWindow(window);\n"
        "})();";

    return [preamble stringByAppendingString:kEnvScriptBody];
}

static os_unfair_lock s_wkEnvCacheLock = OS_UNFAIR_LOCK_INIT;
static NSString *s_cachedWKEnvPlat = nil;
static NSString *s_cachedWKEnvUaToken = nil;
static unsigned int s_cachedWKEnvCores = 0;
static int s_cachedWKEnvPtW = 0;
static int s_cachedWKEnvPtH = 0;
static double s_cachedWKEnvDpr = 0.0;
static NSString *s_cachedWKEnvSource = nil;
static id s_cachedWKEnvScript = nil;

static id ps_create_wk_user_script(NSString *source);

static void ps_get_cached_wk_env(NSString **outSource, id *outScript) {
    NSString *plat = nil;
    NSString *uaToken = nil;
    unsigned int cores = 0;
    int ptWidth = 0;
    int ptHeight = 0;
    double dpr = 0.0;
    ps_get_wk_env_profile_params(&plat, &uaToken, &cores, &ptWidth, &ptHeight, &dpr);

    os_unfair_lock_lock(&s_wkEnvCacheLock);
    BOOL cacheHit = (s_cachedWKEnvSource != nil &&
                     s_cachedWKEnvCores == cores &&
                     s_cachedWKEnvPtW == ptWidth &&
                     s_cachedWKEnvPtH == ptHeight &&
                     fabs(s_cachedWKEnvDpr - dpr) < 1e-6 &&
                     [s_cachedWKEnvPlat isEqualToString:plat] &&
                     [s_cachedWKEnvUaToken isEqualToString:uaToken]);
    if (cacheHit) {
        NSString *src = s_cachedWKEnvSource;
        id script = s_cachedWKEnvScript;
        os_unfair_lock_unlock(&s_wkEnvCacheLock);
        if (script == nil && outScript != NULL) {
            script = ps_create_wk_user_script(src);
            if (script != nil) {
                os_unfair_lock_lock(&s_wkEnvCacheLock);
                if (s_cachedWKEnvScript == nil && s_cachedWKEnvSource == src) {
                    s_cachedWKEnvScript = script;
                } else if (s_cachedWKEnvScript != nil) {
                    script = s_cachedWKEnvScript;
                }
                os_unfair_lock_unlock(&s_wkEnvCacheLock);
            }
        }
        if (outSource) *outSource = src;
        if (outScript) *outScript = script;
        return;
    }
    os_unfair_lock_unlock(&s_wkEnvCacheLock);

    NSString *built = ps_build_wk_env_user_script_source_uncached(plat, uaToken, cores, ptWidth, ptHeight, dpr);
    id builtScript = (outScript != NULL || objc_getClass("WKUserScript") != Nil) ? ps_create_wk_user_script(built) : nil;

    os_unfair_lock_lock(&s_wkEnvCacheLock);
    s_cachedWKEnvPlat = [plat copy];
    s_cachedWKEnvUaToken = [uaToken copy];
    s_cachedWKEnvCores = cores;
    s_cachedWKEnvPtW = ptWidth;
    s_cachedWKEnvPtH = ptHeight;
    s_cachedWKEnvDpr = dpr;
    s_cachedWKEnvSource = built;
    if (builtScript != nil) {
        s_cachedWKEnvScript = builtScript;
    }
    os_unfair_lock_unlock(&s_wkEnvCacheLock);

    if (outSource) *outSource = built;
    if (outScript) *outScript = builtScript;
}

__attribute__((unused))
static NSString *ps_build_wk_env_user_script_source(void) {
    NSString *src = nil;
    ps_get_cached_wk_env(&src, NULL);
    return src;
}

static id ps_cached_wk_env_user_script(void) {
    id script = nil;
    ps_get_cached_wk_env(NULL, &script);
    return script;
}

static NSString *ps_build_wk_vfile_user_script_source(void) {
    return [NSString stringWithFormat:
        @"%@\n"
        "(function(){\n"
        "  if (typeof location !== 'undefined' && location.protocol !== 'file:' && location.protocol !== 'pt-vfile:' && location.protocol !== 'about:') return;\n"
        "  if (window.__ptVFileApplied) return;\n"
        "  try { Object.defineProperty(window, '__ptVFileApplied', { value: true, configurable: false, enumerable: false, writable: false }); } catch (e) { window.__ptVFileApplied = true; }\n"
        "  var VCONT_RE = /^\\/(?:private\\/)?var\\/(?:mobile\\/Containers\\/(?:Data\\/Application|Shared\\/AppGroup)|containers\\/Bundle\\/Application)\\/[0-9A-Fa-f-]{36}(?:\\/|$)/;\n"
        "  function toVFile(raw) {\n"
        "    if (typeof raw !== 'string' || raw.length < 12) return raw;\n"
        "    if (raw.indexOf('pt-vfile:') === 0) return raw;\n"
        "    if (raw.indexOf('var/') === -1) return raw;\n"
        "    try {\n"
        "      var base = (typeof document !== 'undefined' && document.baseURI) ? document.baseURI : 'https://localhost/';\n"
        "      var u = new URL(raw, base);\n"
        "      if (u.protocol === 'file:' && VCONT_RE.test(u.pathname)) {\n"
        "        return 'pt-vfile://' + u.pathname + u.search + u.hash;\n"
        "      }\n"
        "    } catch (e) {}\n"
        "    return raw;\n"
        "  }\n"
        "  function fromVFile(val) {\n"
        "    if (typeof val === 'string' && val.indexOf('pt-vfile://') === 0) {\n"
        "      return 'file://' + val.slice(11);\n"
        "    }\n"
        "    return val;\n"
        "  }\n"
        "  function toVFileSrcset(raw) {\n"
        "    if (typeof raw !== 'string' || raw.indexOf('var/') === -1) return raw;\n"
        "    return raw.split(',').map(function(part) {\n"
        "      var trimmed = part.trim();\n"
        "      if (!trimmed) return part;\n"
        "      var sp = trimmed.search(/\\s/);\n"
        "      if (sp === -1) return toVFile(trimmed);\n"
        "      return toVFile(trimmed.slice(0, sp)) + trimmed.slice(sp);\n"
        "    }).join(', ');\n"
        "  }\n"
        "  function toVFileCss(raw) {\n"
        "    if (typeof raw !== 'string' || raw.indexOf('var/') === -1) return raw;\n"
        "    return raw.replace(/url\\(\\s*(['\"]?)([^'\")]+)\\1\\s*\\)/gi, function(m, q, inner) {\n"
        "      var rw = toVFile(inner.trim());\n"
        "      return rw !== inner.trim() ? ('url(' + q + rw + q + ')') : m;\n"
        "    });\n"
        "  }\n"
        "  function wrapUrlProp(ctor, prop, isSrcset) {\n"
        "    if (!ctor || !ctor.prototype) return;\n"
        "    var d = Object.getOwnPropertyDescriptor(ctor.prototype, prop);\n"
        "    if (!d || typeof d.set !== 'function' || d.configurable === false) return;\n"
        "    Object.defineProperty(ctor.prototype, prop, {\n"
        "      configurable: true,\n"
        "      enumerable: d.enumerable,\n"
        "      get: d.get ? function() { return fromVFile(d.get.call(this)); } : undefined,\n"
        "      set: function(v) { d.set.call(this, (typeof v === 'string') ? (isSrcset ? toVFileSrcset(v) : toVFile(v)) : v); }\n"
        "    });\n"
        "  }\n"
        "  function wrapGetterOnly(ctor, prop) {\n"
        "    if (!ctor || !ctor.prototype) return;\n"
        "    var d = Object.getOwnPropertyDescriptor(ctor.prototype, prop);\n"
        "    if (!d || typeof d.get !== 'function' || d.configurable === false) return;\n"
        "    Object.defineProperty(ctor.prototype, prop, {\n"
        "      configurable: true,\n"
        "      enumerable: d.enumerable,\n"
        "      get: function() { return fromVFile(d.get.call(this)); }\n"
        "    });\n"
        "  }\n"
        "  if (typeof HTMLImageElement !== 'undefined') {\n"
        "    wrapUrlProp(HTMLImageElement, 'src', false);\n"
        "    wrapUrlProp(HTMLImageElement, 'srcset', true);\n"
        "    wrapGetterOnly(HTMLImageElement, 'currentSrc');\n"
        "  }\n"
        "  if (typeof HTMLMediaElement !== 'undefined') {\n"
        "    wrapUrlProp(HTMLMediaElement, 'src', false);\n"
        "    wrapGetterOnly(HTMLMediaElement, 'currentSrc');\n"
        "  }\n"
        "  if (typeof HTMLVideoElement !== 'undefined') wrapUrlProp(HTMLVideoElement, 'poster', false);\n"
        "  if (typeof HTMLSourceElement !== 'undefined') {\n"
        "    wrapUrlProp(HTMLSourceElement, 'src', false);\n"
        "    wrapUrlProp(HTMLSourceElement, 'srcset', true);\n"
        "  }\n"
        "  if (typeof HTMLScriptElement !== 'undefined') wrapUrlProp(HTMLScriptElement, 'src', false);\n"
        "  if (typeof HTMLIFrameElement !== 'undefined') wrapUrlProp(HTMLIFrameElement, 'src', false);\n"
        "  if (typeof HTMLEmbedElement !== 'undefined') wrapUrlProp(HTMLEmbedElement, 'src', false);\n"
        "  if (typeof HTMLTrackElement !== 'undefined') wrapUrlProp(HTMLTrackElement, 'src', false);\n"
        "  if (typeof HTMLObjectElement !== 'undefined') wrapUrlProp(HTMLObjectElement, 'data', false);\n"
        "  if (typeof HTMLLinkElement !== 'undefined') wrapUrlProp(HTMLLinkElement, 'href', false);\n"
        "  var origSetAttr = (typeof Element !== 'undefined' && Element.prototype) ? Element.prototype.setAttribute : null;\n"
        "  var origGetAttr = (typeof Element !== 'undefined' && Element.prototype) ? Element.prototype.getAttribute : null;\n"
        "  if (origSetAttr && origGetAttr) {\n"
        "    Element.prototype.setAttribute = function(name, value) {\n"
        "      if (arguments.length < 2) return origSetAttr.apply(this, arguments);\n"
        "      if (typeof name === 'string' && typeof value === 'string') {\n"
        "        var ln = name.toLowerCase();\n"
        "        if (ln === 'src' || ln === 'poster' || ln === 'data' || (ln === 'href' && (this.tagName === 'LINK' || this.tagName === 'image'))) {\n"
        "          arguments[1] = toVFile(value);\n"
        "        } else if (ln === 'srcset') {\n"
        "          arguments[1] = toVFileSrcset(value);\n"
        "        } else if (ln === 'style') {\n"
        "          arguments[1] = toVFileCss(value);\n"
        "        }\n"
        "      }\n"
        "      return origSetAttr.apply(this, arguments);\n"
        "    };\n"
        "    Element.prototype.getAttribute = function(name) {\n"
        "      if (arguments.length < 1) return origGetAttr.apply(this, arguments);\n"
        "      return fromVFile(origGetAttr.apply(this, arguments));\n"
        "    };\n"
        "  }\n"
        "  if (typeof CSSStyleDeclaration !== 'undefined' && CSSStyleDeclaration.prototype) {\n"
        "    var origSetProp = CSSStyleDeclaration.prototype.setProperty;\n"
        "    if (origSetProp) {\n"
        "      CSSStyleDeclaration.prototype.setProperty = function(prop, val, prio) {\n"
        "        if (arguments.length < 2) return origSetProp.apply(this, arguments);\n"
        "        if (typeof val === 'string') arguments[1] = toVFileCss(val);\n"
        "        return origSetProp.apply(this, arguments);\n"
        "      };\n"
        "    }\n"
        "    ['backgroundImage', 'background', 'maskImage', 'webkitMaskImage'].forEach(function(p) {\n"
        "      var d = Object.getOwnPropertyDescriptor(CSSStyleDeclaration.prototype, p);\n"
        "      if (d && typeof d.set === 'function' && d.configurable !== false) {\n"
        "        Object.defineProperty(CSSStyleDeclaration.prototype, p, {\n"
        "          configurable: true,\n"
        "          enumerable: d.enumerable,\n"
        "          get: d.get,\n"
        "          set: function(v) { d.set.call(this, typeof v === 'string' ? toVFileCss(v) : v); }\n"
        "        });\n"
        "      }\n"
        "    });\n"
        "  }\n"
        "  var allowRawFetch = (typeof location !== 'undefined') && (location.protocol === 'file:' || location.protocol === 'pt-vfile:' || location.protocol === 'about:' || location.origin === 'null');\n"
        "  if (allowRawFetch && typeof window.fetch === 'function') {\n"
        "    var origFetch = window.fetch;\n"
        "    window.fetch = function(input, init) {\n"
        "      if (arguments.length === 0) return origFetch.apply(this, arguments);\n"
        "      if (typeof input === 'string') input = toVFile(input);\n"
        "      else if (typeof URL !== 'undefined' && input instanceof URL) input = toVFile(input.href);\n"
        "      else if (typeof Request !== 'undefined' && input instanceof Request) {\n"
        "        var rwUrl = toVFile(input.url);\n"
        "        if (rwUrl !== input.url) input = new Request(rwUrl, input);\n"
        "      }\n"
        "      return (arguments.length > 1) ? origFetch.call(this, input, init) : origFetch.call(this, input);\n"
        "    };\n"
        "  }\n"
        "  if (allowRawFetch && typeof XMLHttpRequest !== 'undefined' && XMLHttpRequest.prototype && XMLHttpRequest.prototype.open) {\n"
        "    var origOpen = XMLHttpRequest.prototype.open;\n"
        "    XMLHttpRequest.prototype.open = function(method, url) {\n"
        "      if (typeof url === 'string') arguments[1] = toVFile(url);\n"
        "      return origOpen.apply(this, arguments);\n"
        "    };\n"
        "  }\n"
        "  function rwAttr(el, attrName) {\n"
        "    var raw = origGetAttr.call(el, attrName);\n"
        "    if (raw && raw.indexOf('var/') !== -1 && raw.indexOf('pt-vfile:') !== 0) {\n"
        "      var rw = toVFile(raw);\n"
        "      if (rw !== raw) origSetAttr.call(el, attrName, rw);\n"
        "    }\n"
        "  }\n"
        "  function scanElement(el) {\n"
        "    var tag = el.tagName;\n"
        "    if (tag === 'VIDEO') {\n"
        "      rwAttr(el, 'src');\n"
        "      rwAttr(el, 'poster');\n"
        "    } else if (tag === 'OBJECT') {\n"
        "      rwAttr(el, 'data');\n"
        "    } else if (tag === 'LINK') {\n"
        "      rwAttr(el, 'href');\n"
        "    } else {\n"
        "      rwAttr(el, 'src');\n"
        "    }\n"
        "    var ss = origGetAttr.call(el, 'srcset');\n"
        "    if (ss && ss.indexOf('var/') !== -1) {\n"
        "      var rws = toVFileSrcset(ss);\n"
        "      if (rws !== ss) origSetAttr.call(el, 'srcset', rws);\n"
        "    }\n"
        "    var st = origGetAttr.call(el, 'style');\n"
        "    if (st && st.indexOf('var/') !== -1) {\n"
        "      var rwst = toVFileCss(st);\n"
        "      if (rwst !== st) origSetAttr.call(el, 'style', rwst);\n"
        "    }\n"
        "  }\n"
        "  function scanNode(root) {\n"
        "    if (!root || root.nodeType !== 1 || !origSetAttr || !origGetAttr) return;\n"
        "    scanElement(root);\n"
        "    if (root.firstElementChild && root.querySelectorAll) {\n"
        "      var sub = root.querySelectorAll('img,video,audio,source,script,iframe,embed,track,object,link,[style]');\n"
        "      for (var i = 0; i < sub.length; i++) scanElement(sub[i]);\n"
        "    }\n"
        "  }\n"
        "  if (typeof MutationObserver !== 'undefined') {\n"
        "    var mo = new MutationObserver(function(muts) {\n"
        "      var firstEl = null;\n"
        "      var batch = null;\n"
        "      var batchSet = null;\n"
        "      for (var i = 0; i < muts.length; i++) {\n"
        "        var added = muts[i].addedNodes;\n"
        "        for (var k = 0; k < added.length; k++) {\n"
        "          var n = added[k];\n"
        "          if (!n || n.nodeType !== 1) continue;\n"
        "          if (firstEl === null) {\n"
        "            firstEl = n;\n"
        "          } else {\n"
        "            if (batch === null) {\n"
        "              batch = [firstEl];\n"
        "              if (typeof Set !== 'undefined') {\n"
        "                batchSet = new Set();\n"
        "                batchSet.add(firstEl);\n"
        "              }\n"
        "            }\n"
        "            if (batchSet) {\n"
        "              if (!batchSet.has(n)) {\n"
        "                batchSet.add(n);\n"
        "                batch.push(n);\n"
        "              }\n"
        "            } else {\n"
        "              batch.push(n);\n"
        "            }\n"
        "          }\n"
        "        }\n"
        "      }\n"
        "      if (firstEl === null) return;\n"
        "      if (batch === null) {\n"
        "        scanNode(firstEl);\n"
        "        return;\n"
        "      }\n"
        "      for (var j = 0; j < batch.length; j++) {\n"
        "        var el = batch[j];\n"
        "        var hasAncestor = false;\n"
        "        if (batchSet) {\n"
        "          for (var p = el.parentNode; p; p = p.parentNode) {\n"
        "            if (batchSet.has(p)) {\n"
        "              hasAncestor = true;\n"
        "              break;\n"
        "            }\n"
        "          }\n"
        "        }\n"
        "        if (!hasAncestor) scanNode(el);\n"
        "      }\n"
        "    });\n"
        "    if (document && document.documentElement) {\n"
        "      scanNode(document.documentElement);\n"
        "      mo.observe(document.documentElement, { childList: true, subtree: true });\n"
        "    } else if (typeof document !== 'undefined') {\n"
        "      document.addEventListener('DOMContentLoaded', function() {\n"
        "        if (document.documentElement) {\n"
        "          scanNode(document.documentElement);\n"
        "          mo.observe(document.documentElement, { childList: true, subtree: true });\n"
        "        }\n"
        "      }, { once: true });\n"
        "    }\n"
        "  }\n"
        "})();",
        kPSWKVFileScriptMarker];
}

static NSString *ps_cached_wk_vfile_user_script_source(void) {
    static NSString *s_vfileSrc = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_vfileSrc = ps_build_wk_vfile_user_script_source();
    });
    return s_vfileSrc;
}

static id ps_cached_wk_vfile_user_script(void) {
    static id s_vfileScript = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_vfileScript = ps_create_wk_user_script(ps_cached_wk_vfile_user_script_source());
    });
    return s_vfileScript;
}

static id ps_create_wk_user_script(NSString *source) {
    Class usCls = objc_getClass("WKUserScript");
    if (usCls == nil || source.length == 0) {
        return nil;
    }
    SEL initSel = NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:");
    id allocObj = [usCls alloc];
    if (allocObj != nil && [allocObj respondsToSelector:initSel]) {
        return ((id (*)(id, SEL, NSString *, NSInteger, BOOL))objc_msgSend)(allocObj, initSel, source, 0, NO);
    }
    return nil;
}

static BOOL ps_ucc_has_script_with_marker(id ucc, NSString *marker) {
    SEL scriptsSel = NSSelectorFromString(@"userScripts");
    if (ucc == nil || ![ucc respondsToSelector:scriptsSel]) {
        return NO;
    }
    NSArray *scripts = ((NSArray *(*)(id, SEL))objc_msgSend)(ucc, scriptsSel);
    SEL srcSel = NSSelectorFromString(@"source");
    for (id script in scripts) {
        if ([script respondsToSelector:srcSel]) {
            NSString *src = ((NSString *(*)(id, SEL))objc_msgSend)(script, srcSel);
            if ([src isKindOfClass:[NSString class]] && [src hasPrefix:marker]) {
                return YES;
            }
        }
    }
    return NO;
}

static void ps_apply_playtools_scripts_to_ucc(id ucc, BOOL enableVFile) {
    if (ucc == nil) {
        return;
    }
    NSNumber *cachedMode = objc_getAssociatedObject(ucc, &kPSWKUCCManagedModeKey);
    NSInteger wantState = enableVFile ? 2 : 1;
    if (cachedMode != nil && [cachedMode integerValue] >= wantState) {
        return;
    }
    SEL addSel = NSSelectorFromString(@"addUserScript:");
    if (![ucc respondsToSelector:addSel]) {
        return;
    }
    BOOL hasEnv = ps_ucc_has_script_with_marker(ucc, kPSWKEnvScriptMarker);
    BOOL hasVFile = ps_ucc_has_script_with_marker(ucc, kPSWKVFileScriptMarker);
    if (!hasEnv) {
        id envScript = ps_cached_wk_env_user_script();
        id vfileScript = (enableVFile && !hasVFile) ? ps_cached_wk_vfile_user_script() : nil;
        SEL scriptsSel = NSSelectorFromString(@"userScripts");
        SEL origRemoveSel = @selector(pm_wk_removeAllUserScripts);
        NSArray *existing = ([ucc respondsToSelector:scriptsSel])
            ? [((NSArray *(*)(id, SEL))objc_msgSend)(ucc, scriptsSel) copy]
            : nil;
        if (existing.count > 0 && [ucc respondsToSelector:origRemoveSel]) {
            ((void (*)(id, SEL))objc_msgSend)(ucc, origRemoveSel);
            if (envScript != nil) {
                ((void (*)(id, SEL, id))objc_msgSend)(ucc, addSel, envScript);
            }
            if (vfileScript != nil) {
                ((void (*)(id, SEL, id))objc_msgSend)(ucc, addSel, vfileScript);
                hasVFile = YES;
            }
            for (id s in existing) {
                ((void (*)(id, SEL, id))objc_msgSend)(ucc, addSel, s);
            }
        } else {
            if (envScript != nil) {
                ((void (*)(id, SEL, id))objc_msgSend)(ucc, addSel, envScript);
            }
            if (vfileScript != nil) {
                ((void (*)(id, SEL, id))objc_msgSend)(ucc, addSel, vfileScript);
                hasVFile = YES;
            }
        }
    } else if (enableVFile && !hasVFile) {
        id vfileScript = ps_cached_wk_vfile_user_script();
        if (vfileScript != nil) {
            ((void (*)(id, SEL, id))objc_msgSend)(ucc, addSel, vfileScript);
            hasVFile = YES;
        }
    }
    objc_setAssociatedObject(ucc, &kPSWKUCCManagedModeKey, @((enableVFile || hasVFile) ? 2 : 1), OBJC_ASSOCIATION_RETAIN);
}

static BOOL ps_wk_config_has_custom_file_interception(id cfg) {
    if (atomic_load_explicit(&s_wk_custom_protocol_handles_file, memory_order_relaxed)) {
        return YES;
    }
    if (cfg != nil) {
        SEL handlerSel = @selector(urlSchemeHandlerForURLScheme:);
        if ([cfg respondsToSelector:handlerSel]) {
            id handler = ((id (*)(id, SEL, NSString *))objc_msgSend)(cfg, handlerSel, @"file");
            if (handler != nil) {
                return YES;
            }
        }
    }
    return NO;
}

static BOOL ps_wkwebview_has_custom_file_interception(id webView) {
    if (atomic_load_explicit(&s_wk_custom_protocol_handles_file, memory_order_relaxed)) {
        return YES;
    }
    if (webView != nil) {
        SEL cfgSel = @selector(configuration);
        if ([webView respondsToSelector:cfgSel]) {
            id cfg = ((id (*)(id, SEL))objc_msgSend)(webView, cfgSel);
            return ps_wk_config_has_custom_file_interception(cfg);
        }
    }
    return NO;
}

__attribute__((visibility("hidden"))) PSVirtualFileReadScope *ps_make_read_scope_for_explicit_access(NSURL *docURL, NSURL *readAccessURL) {
    NSString *docReal = ps_canonical_container_real_path_from_url(docURL);
    NSURL *effectiveRead = readAccessURL ?: docURL;
    NSString *readReal = ps_canonical_container_real_path_from_url(effectiveRead);
    if (readReal.length == 0) {
        return nil;
    }
    BOOL allowSubtree = NO;
    struct stat st;
    if (stat([readReal fileSystemRepresentation], &st) == 0) {
        allowSubtree = S_ISDIR(st.st_mode) ? YES : NO;
    } else {
        allowSubtree = [effectiveRead hasDirectoryPath];
    }
    PSVirtualFileReadScope *scope = [[PSVirtualFileReadScope alloc] init];
    scope.allowedRealPath = readReal;
    scope.expectedDocRealPath = (docReal.length > 0) ? docReal : readReal;
    scope.allowSubtree = allowSubtree;
    return scope;
}

static BOOL ps_wkwebview_allows_file_access_from_file_urls(id webView) {
    if (webView == nil) {
        return NO;
    }
    SEL cfgSel = @selector(configuration);
    if (![webView respondsToSelector:cfgSel]) {
        return NO;
    }
    id cfg = ((id (*)(id, SEL))objc_msgSend)(webView, cfgSel);
    SEL prefSel = NSSelectorFromString(@"preferences");
    if (cfg == nil || ![cfg respondsToSelector:prefSel]) {
        return NO;
    }
    id prefs = ((id (*)(id, SEL))objc_msgSend)(cfg, prefSel);
    if (prefs == nil) {
        return NO;
    }
    @try {
        id val = [prefs valueForKey:@"allowFileAccessFromFileURLs"];
        if ([val respondsToSelector:@selector(boolValue)] && [val boolValue]) {
            return YES;
        }
    } @catch (NSException *exception) {
        (void)exception;
    }
    return NO;
}

__attribute__((visibility("hidden"))) PSVirtualFileReadScope *ps_make_read_scope_for_file_request(id webView, NSURL *fileURL) {
    NSString *docReal = ps_canonical_container_real_path_from_url(fileURL);
    if (docReal.length == 0) {
        return nil;
    }
    PSVirtualFileReadScope *scope = [[PSVirtualFileReadScope alloc] init];
    scope.expectedDocRealPath = docReal;
    if (ps_wkwebview_allows_file_access_from_file_urls(webView)) {
        NSURL *parentURL = [ps_resolve_virtual_nsurl(fileURL) URLByDeletingLastPathComponent];
        NSString *parentReal = ps_canonical_container_real_path_from_url(parentURL);
        if (parentReal.length > 0) {
            scope.allowedRealPath = parentReal;
            scope.allowSubtree = YES;
            return scope;
        }
    }
    scope.allowedRealPath = docReal;
    scope.allowSubtree = NO;
    return scope;
}

__attribute__((visibility("hidden"))) PSVirtualFileReadScope *ps_make_read_scope_for_base_url(NSURL *baseURL) {
    NSString *baseReal = ps_canonical_container_real_path_from_url(baseURL);
    if (baseReal.length == 0) {
        return nil;
    }
    PSVirtualFileReadScope *scope = [[PSVirtualFileReadScope alloc] init];
    scope.expectedDocRealPath = baseReal;
    struct stat st;
    BOOL baseIsDir = NO;
    if (stat([baseReal fileSystemRepresentation], &st) == 0) {
        baseIsDir = S_ISDIR(st.st_mode) ? YES : NO;
    } else {
        baseIsDir = [baseURL hasDirectoryPath];
    }
    if (baseIsDir) {
        scope.allowedRealPath = baseReal;
        scope.allowSubtree = YES;
        return scope;
    }
    NSURL *parentURL = [ps_resolve_virtual_nsurl(baseURL) URLByDeletingLastPathComponent];
    NSString *parentReal = ps_canonical_container_real_path_from_url(parentURL);
    if (parentReal.length > 0) {
        scope.allowedRealPath = parentReal;
        scope.allowSubtree = YES;
    } else {
        scope.allowedRealPath = baseReal;
        scope.allowSubtree = NO;
    }
    return scope;
}

static void ps_sync_wkwebview_for_scope(id webView, PSVirtualFileReadScope *scope) {
    if (webView == nil) {
        return;
    }
    ps_set_wkwebview_read_scope(webView, scope);
    SEL cfgSel = @selector(configuration);
    if (![webView respondsToSelector:cfgSel]) {
        return;
    }
    id cfg = ((id (*)(id, SEL))objc_msgSend)(webView, cfgSel);
    SEL uccSel = NSSelectorFromString(@"userContentController");
    if (cfg != nil && [cfg respondsToSelector:uccSel]) {
        id ucc = ((id (*)(id, SEL))objc_msgSend)(cfg, uccSel);
        BOOL hasVFileHandler = NO;
        SEL handlerSel = @selector(urlSchemeHandlerForURLScheme:);
        if ([cfg respondsToSelector:handlerSel]) {
            hasVFileHandler = (((id (*)(id, SEL, NSString *))objc_msgSend)(cfg, handlerSel, @"pt-vfile") != nil);
        }
        BOOL enableVFile = (scope != nil) && hasVFileHandler && !ps_wk_config_has_custom_file_interception(cfg);
        ps_apply_playtools_scripts_to_ucc(ucc, enableVFile);
    }
}

- (NSArray *) pm_wk_userScripts {
    const void *caller = __builtin_return_address(0);
    NSArray *scripts = [self pm_wk_userScripts];
    if (scripts.count == 0 || !pt_is_bypass_enabled() || ps_is_effective_system_or_playtools_caller(caller)) {
        return scripts;
    }
    SEL srcSel = NSSelectorFromString(@"source");
    NSMutableArray *filtered = nil;
    for (NSUInteger i = 0; i < scripts.count; i++) {
        id script = scripts[i];
        BOOL isInternal = NO;
        if ([script respondsToSelector:srcSel]) {
            NSString *src = ((NSString *(*)(id, SEL))objc_msgSend)(script, srcSel);
            if ([src isKindOfClass:[NSString class]] &&
                ([src hasPrefix:kPSWKEnvScriptMarker] || [src hasPrefix:kPSWKVFileScriptMarker])) {
                isInternal = YES;
            }
        }
        if (isInternal) {
            if (filtered == nil) {
                filtered = [NSMutableArray arrayWithCapacity:scripts.count - 1];
                for (NSUInteger j = 0; j < i; j++) {
                    [filtered addObject:scripts[j]];
                }
            }
        } else if (filtered != nil) {
            [filtered addObject:script];
        }
    }
    return filtered != nil ? [filtered copy] : scripts;
}

- (void) pm_wk_removeAllUserScripts {
    [self pm_wk_removeAllUserScripts];
    NSNumber *mode = objc_getAssociatedObject(self, &kPSWKUCCManagedModeKey);
    if (mode != nil) {
        objc_setAssociatedObject(self, &kPSWKUCCManagedModeKey, nil, OBJC_ASSOCIATION_RETAIN);
        BOOL wantVFile = ([mode integerValue] == 2) &&
                         !atomic_load_explicit(&s_wk_custom_protocol_handles_file, memory_order_relaxed);
        ps_apply_playtools_scripts_to_ucc(self, wantVFile);
    }
}

static void ps_prepare_wk_configuration(id cfg) {
    if (cfg == nil) {
        return;
    }
    SEL getHandlerSel = @selector(urlSchemeHandlerForURLScheme:);
    SEL setHandlerSel = NSSelectorFromString(@"setURLSchemeHandler:forURLScheme:");
    if ([cfg respondsToSelector:getHandlerSel] &&
        [cfg respondsToSelector:setHandlerSel]) {
        id existingHandler = ((id (*)(id, SEL, NSString *))objc_msgSend)(cfg, getHandlerSel, @"pt-vfile");
        if (existingHandler == nil) {
            @try {
                ((void (*)(id, SEL, id, NSString *))objc_msgSend)(cfg,
                                                                  setHandlerSel,
                                                                  ps_shared_vfile_scheme_handler(),
                                                                  @"pt-vfile");
            } @catch (NSException *exception) {
                (void)exception;
            }
        }
    }
    SEL uccSel = NSSelectorFromString(@"userContentController");
    if ([cfg respondsToSelector:uccSel]) {
        id ucc = ((id (*)(id, SEL))objc_msgSend)(cfg, uccSel);
        ps_apply_playtools_scripts_to_ucc(ucc, NO);
    }
}

- (instancetype) pm_wk_cfg_init {
    self = [self pm_wk_cfg_init];
    if (self != nil) {
        ps_prepare_wk_configuration(self);
    }
    return self;
}

- (instancetype) pm_wk_cfg_initWithCoder:(NSCoder *)coder {
    self = [self pm_wk_cfg_initWithCoder:coder];
    if (self != nil) {
        ps_prepare_wk_configuration(self);
    }
    return self;
}

static void ps_finish_wkwebview_init(id initialized, id cfg) {
    if (initialized == nil) {
        return;
    }
    id effectiveCfg = cfg;
    if (effectiveCfg == nil && [initialized respondsToSelector:@selector(configuration)]) {
        effectiveCfg = ((id (*)(id, SEL))objc_msgSend)(initialized, @selector(configuration));
        if (effectiveCfg != nil) {
            SEL uccSel = NSSelectorFromString(@"userContentController");
            if ([effectiveCfg respondsToSelector:uccSel]) {
                id ucc = ((id (*)(id, SEL))objc_msgSend)(effectiveCfg, uccSel);
                ps_apply_playtools_scripts_to_ucc(ucc, NO);
            }
        }
    }
    NSString *origUA = [initialized respondsToSelector:@selector(pm_wk_customUserAgent)]
        ? [initialized pm_wk_customUserAgent]
        : nil;
    if ([origUA isKindOfClass:[NSString class]] && origUA.length > 0) {
        NSString *sanitized = ps_sanitize_mac_token_in_ua(origUA);
        objc_setAssociatedObject(initialized, &kPSWKExplicitCustomUAKey, sanitized, OBJC_ASSOCIATION_COPY_NONATOMIC);
        if (![sanitized isEqualToString:origUA] &&
            [initialized respondsToSelector:@selector(pm_wk_setCustomUserAgent:)]) {
            [initialized pm_wk_setCustomUserAgent:sanitized];
        }
    } else if ([initialized respondsToSelector:@selector(pm_wk_setCustomUserAgent:)] &&
               objc_getAssociatedObject(initialized, &kPSWKExplicitCustomUAKey) == nil) {
        NSString *defaultUA = ps_build_default_wk_user_agent(effectiveCfg);
        [initialized pm_wk_setCustomUserAgent:defaultUA];
    }
}

- (instancetype) pm_wk_initWithFrame:(CGRect)frame configuration:(id)configuration {
    id effectiveCfg = configuration;
    if (effectiveCfg == nil) {
        Class cfgCls = objc_getClass("WKWebViewConfiguration");
        if (cfgCls != nil) {
            effectiveCfg = [[cfgCls alloc] init];
        }
    }
    ps_prepare_wk_configuration(effectiveCfg);
    id initialized = [self pm_wk_initWithFrame:frame configuration:effectiveCfg];
    ps_finish_wkwebview_init(initialized, effectiveCfg);
    return initialized;
}

- (instancetype) pm_wk_initWithCoder:(NSCoder *)coder {
    id initialized = [self pm_wk_initWithCoder:coder];
    ps_finish_wkwebview_init(initialized, nil);
    return initialized;
}

- (void) pm_wk_setCustomUserAgent:(NSString *)customUserAgent {
    if (customUserAgent == nil || customUserAgent.length == 0) {
        objc_setAssociatedObject(self, &kPSWKExplicitCustomUAKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        id cfg = [self respondsToSelector:@selector(configuration)]
            ? ((id (*)(id, SEL))objc_msgSend)(self, @selector(configuration))
            : nil;
        [self pm_wk_setCustomUserAgent:ps_build_default_wk_user_agent(cfg)];
        return;
    }
    NSString *sanitized = ps_sanitize_mac_token_in_ua(customUserAgent);
    objc_setAssociatedObject(self, &kPSWKExplicitCustomUAKey, sanitized, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [self pm_wk_setCustomUserAgent:sanitized];
}

- (NSString *) pm_wk_customUserAgent {
    const void *caller = __builtin_return_address(0);
    if (!pt_is_bypass_enabled() || ps_is_effective_system_or_playtools_caller(caller)) {
        return [self pm_wk_customUserAgent];
    }
    return objc_getAssociatedObject(self, &kPSWKExplicitCustomUAKey);
}

static NSURLRequest *ps_virtualize_url_request_for_caller(NSURLRequest *req, const void *caller) {
    if (req == nil || !pt_is_bypass_enabled() || ps_is_effective_system_or_playtools_caller(caller)) {
        return req;
    }
    NSURL *origURL = req.URL;
    if (origURL != nil && [origURL isFileURL]) {
        NSURL *virtURL = ps_virtualize_nsurl_for_app(origURL, YES);
        if (virtURL != origURL && virtURL != nil && ![virtURL isEqual:origURL]) {
            NSMutableURLRequest *mreq = [req mutableCopy];
            mreq.URL = virtURL;
            return [req isKindOfClass:[NSMutableURLRequest class]] ? mreq : [mreq copy];
        }
    }
    return req;
}

- (NSURL *) pm_wk_URL {
    return ps_virtualize_bundle_url_for_caller([self pm_wk_URL], __builtin_return_address(0));
}

- (NSURLRequest *) pm_wk_nav_request {
    return ps_virtualize_url_request_for_caller([self pm_wk_nav_request], __builtin_return_address(0));
}

- (NSURLRequest *) pm_wk_frame_request {
    return ps_virtualize_url_request_for_caller([self pm_wk_frame_request], __builtin_return_address(0));
}

static BOOL ps_is_wk_wide_read_access_ancestor(NSURL *readAccessURL) {
    if (readAccessURL == nil || ![readAccessURL isFileURL]) {
        return NO;
    }
    NSString *std = [[readAccessURL standardizedURL] path];
    if (std.length == 0) {
        return NO;
    }
    if (std.length > 1 && [std hasSuffix:@"/"]) {
        std = [std substringToIndex:std.length - 1];
    }
    if ([std isEqualToString:@"/"] ||
        [std isEqualToString:@"/var"] ||
        [std isEqualToString:@"/private/var"]) {
        return YES;
    }
    return ps_is_virtual_ancestor_nsstring(std);
}

static NSURL *ps_wk_native_read_access_url_for_wide_ancestor(NSURL *docURL) {
    NSURL *resolvedDoc = (docURL != nil && [docURL isFileURL]) ? ps_resolve_virtual_nsurl(docURL) : nil;
    NSString *docPrePath = resolvedDoc.path;
    if (docPrePath.length > 0) {
        NSString *virtDoc = ps_virtualize_nsstring_path_for_app(docPrePath, YES);
        NSString *virtRoot = ps_extract_virtual_container_root(virtDoc);
        if (virtRoot.length > 0) {
            NSString *realRoot = ps_resolve_virtual_nsstring_path(virtRoot);
            if (realRoot.length > 0 && ![realRoot isEqualToString:virtRoot] &&
                ps_real_path_matches_or_under(docPrePath, realRoot, YES)) {
                return [NSURL fileURLWithPath:realRoot isDirectory:YES];
            }
        }
        ps_seed_wk_canon_container_roots();
        os_unfair_lock_lock(&s_wkCanonRootsLock);
        NSArray<NSString *> *roots = [s_wkCanonContainerRoots copy];
        os_unfair_lock_unlock(&s_wkCanonRootsLock);
        for (NSString *knownRoot in roots) {
            if (ps_real_path_matches_or_under(docPrePath, knownRoot, YES)) {
                return [NSURL fileURLWithPath:knownRoot isDirectory:YES];
            }
        }
        struct stat st;
        if (stat([docPrePath fileSystemRepresentation], &st) == 0 && S_ISDIR(st.st_mode)) {
            return resolvedDoc;
        }
        NSURL *parent = [resolvedDoc URLByDeletingLastPathComponent];
        if (parent != nil) {
            return parent;
        }
    }
    const char *vh = pt_get_virtual_home_cstr();
    if (vh != NULL && vh[0] == '/') {
        NSString *vHome = [NSString stringWithUTF8String:vh];
        NSString *rHome = ps_resolve_virtual_nsstring_path(vHome);
        if (rHome.length > 0 && ![rHome isEqualToString:vHome]) {
            return [NSURL fileURLWithPath:rHome isDirectory:YES];
        }
    }
    return [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
}

__attribute__((visibility("hidden"))) PSVirtualFileReadScope *ps_make_read_scope_for_base_url_or_nil(NSURL *baseURL) {
    if (baseURL == nil || [baseURL.scheme caseInsensitiveCompare:@"about"] == NSOrderedSame) {
        PSVirtualFileReadScope *scope = [[PSVirtualFileReadScope alloc] init];
        scope.expectedDocRealPath = @"";
        scope.allowedRealPath = @"";
        scope.allowSubtree = YES;
        scope.allowAllAppContainers = YES;
        return scope;
    }
    if ([baseURL isFileURL]) {
        return ps_make_read_scope_for_base_url(baseURL);
    }
    return nil;
}

- (id) pm_loadFileURL:(NSURL *)URL allowingReadAccessToURL:(NSURL *)readAccessURL {
    if (ps_wkwebview_has_custom_file_interception(self)) {
        ps_sync_wkwebview_for_scope(self, nil);
        return [self pm_loadFileURL:URL allowingReadAccessToURL:readAccessURL];
    }
    if (ps_is_wk_wide_read_access_ancestor(readAccessURL)) {
        NSURL *resolvedDoc = ps_resolve_virtual_nsurl(URL);
        NSURL *nativeRead = ps_wk_native_read_access_url_for_wide_ancestor(URL);
        NSString *docReal = ps_canonical_container_real_path_from_url(URL);
        NSString *readReal = ps_canonical_container_real_path_from_url(nativeRead);
        PSVirtualFileReadScope *scope = [[PSVirtualFileReadScope alloc] init];
        scope.allowAllAppContainers = YES;
        scope.allowSubtree = YES;
        scope.expectedDocRealPath = docReal ?: @"";
        scope.allowedRealPath = readReal ?: (docReal ?: @"");
        ps_sync_wkwebview_for_scope(self, scope);
        return [self pm_loadFileURL:resolvedDoc allowingReadAccessToURL:nativeRead];
    }
    PSVirtualFileReadScope *scope = ps_make_read_scope_for_explicit_access(URL, readAccessURL);
    ps_sync_wkwebview_for_scope(self, scope);
    return [self pm_loadFileURL:ps_resolve_virtual_nsurl(URL)
        allowingReadAccessToURL:ps_resolve_virtual_nsurl(readAccessURL)];
}

- (id) pm_loadFileRequest:(NSURLRequest *)request allowingReadAccessToURL:(NSURL *)readAccessURL {
    if (ps_wkwebview_has_custom_file_interception(self)) {
        ps_sync_wkwebview_for_scope(self, nil);
        return [self pm_loadFileRequest:request allowingReadAccessToURL:readAccessURL];
    }
    if (ps_is_wk_wide_read_access_ancestor(readAccessURL)) {
        NSURL *docURL = (request != nil) ? request.URL : nil;
        NSURL *nativeRead = ps_wk_native_read_access_url_for_wide_ancestor(docURL);
        NSString *docReal = (docURL != nil && [docURL isFileURL]) ? ps_canonical_container_real_path_from_url(docURL) : nil;
        NSString *readReal = ps_canonical_container_real_path_from_url(nativeRead);
        PSVirtualFileReadScope *scope = nil;
        if (docURL != nil && [docURL isFileURL]) {
            scope = [[PSVirtualFileReadScope alloc] init];
            scope.allowAllAppContainers = YES;
            scope.allowSubtree = YES;
            scope.expectedDocRealPath = docReal ?: @"";
            scope.allowedRealPath = readReal ?: (docReal ?: @"");
        }
        ps_sync_wkwebview_for_scope(self, scope);
        if (request != nil && [request.URL isFileURL]) {
            NSURL *resolved = ps_resolve_virtual_nsurl(request.URL);
            if (resolved != request.URL) {
                NSMutableURLRequest *mreq = [request mutableCopy];
                mreq.URL = resolved;
                return [self pm_loadFileRequest:mreq allowingReadAccessToURL:nativeRead];
            }
        }
        return [self pm_loadFileRequest:request allowingReadAccessToURL:nativeRead];
    }
    PSVirtualFileReadScope *scope = (request != nil && [request.URL isFileURL])
        ? ps_make_read_scope_for_explicit_access(request.URL, readAccessURL)
        : nil;
    ps_sync_wkwebview_for_scope(self, scope);
    NSURL *resolvedRead = ps_resolve_virtual_nsurl(readAccessURL);
    if (request != nil && [request.URL isFileURL]) {
        NSURL *resolved = ps_resolve_virtual_nsurl(request.URL);
        if (resolved != request.URL) {
            NSMutableURLRequest *mreq = [request mutableCopy];
            mreq.URL = resolved;
            return [self pm_loadFileRequest:mreq allowingReadAccessToURL:resolvedRead];
        }
    }
    return [self pm_loadFileRequest:request allowingReadAccessToURL:resolvedRead];
}

- (id) pm_wk_loadRequest:(NSURLRequest *)request {
    if (!ps_wkwebview_has_custom_file_interception(self) &&
        request != nil && [request.URL isFileURL]) {
        PSVirtualFileReadScope *scope = ps_make_read_scope_for_file_request(self, request.URL);
        ps_sync_wkwebview_for_scope(self, scope);
        NSURL *resolved = ps_resolve_virtual_nsurl(request.URL);
        if (resolved != request.URL) {
            NSMutableURLRequest *mreq = [request mutableCopy];
            mreq.URL = resolved;
            return [self pm_wk_loadRequest:mreq];
        }
        return [self pm_wk_loadRequest:request];
    }
    ps_sync_wkwebview_for_scope(self, nil);
    return [self pm_wk_loadRequest:request];
}

- (id) pm_wk_loadHTMLString:(NSString *)string baseURL:(NSURL *)baseURL {
    if (ps_wkwebview_has_custom_file_interception(self)) {
        ps_sync_wkwebview_for_scope(self, nil);
        return [self pm_wk_loadHTMLString:string baseURL:baseURL];
    }
    PSVirtualFileReadScope *scope = ps_make_read_scope_for_base_url_or_nil(baseURL);
    ps_sync_wkwebview_for_scope(self, scope);
    NSURL *effectiveBase = ps_resolve_virtual_nsurl(baseURL);
    return [self pm_wk_loadHTMLString:string baseURL:effectiveBase];
}

- (id) pm_wk_loadData:(NSData *)data
             MIMEType:(NSString *)MIMEType
characterEncodingName:(NSString *)characterEncodingName
              baseURL:(NSURL *)baseURL {
    if (ps_wkwebview_has_custom_file_interception(self)) {
        ps_sync_wkwebview_for_scope(self, nil);
        return [self pm_wk_loadData:data
                           MIMEType:MIMEType
              characterEncodingName:characterEncodingName
                            baseURL:baseURL];
    }
    PSVirtualFileReadScope *scope = ps_make_read_scope_for_base_url_or_nil(baseURL);
    ps_sync_wkwebview_for_scope(self, scope);
    NSURL *effectiveBase = ps_resolve_virtual_nsurl(baseURL);
    return [self pm_wk_loadData:data
                       MIMEType:MIMEType
          characterEncodingName:characterEncodingName
                        baseURL:effectiveBase];
}


+ (void) pm_wk_registerSchemeForCustomProtocol:(NSString *)scheme {
    if ([scheme isKindOfClass:[NSString class]] &&
        [scheme caseInsensitiveCompare:@"file"] == NSOrderedSame) {
        atomic_store_explicit(&s_wk_custom_protocol_handles_file, true, memory_order_relaxed);
    }
    [self pm_wk_registerSchemeForCustomProtocol:scheme];
}

+ (void) pm_wk_unregisterSchemeForCustomProtocol:(NSString *)scheme {
    if ([scheme isKindOfClass:[NSString class]] &&
        [scheme caseInsensitiveCompare:@"file"] == NSOrderedSame) {
        atomic_store_explicit(&s_wk_custom_protocol_handles_file, false, memory_order_relaxed);
    }
    [self pm_wk_unregisterSchemeForCustomProtocol:scheme];
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

static os_unfair_lock s_audio_port_swizzle_lock = OS_UNFAIR_LOCK_INIT;
static BOOL s_audio_port_hooks_installed = NO;

static void ps_install_audio_session_port_hooks(void) {
    os_unfair_lock_lock(&s_audio_port_swizzle_lock);
    if (!s_audio_port_hooks_installed) {
        Class cls = NSClassFromString(@"AVAudioSessionPortDescription");
        if (cls != Nil) {
            SEL portNameSel = NSSelectorFromString(@"portName");
            if (class_getInstanceMethod(cls, portNameSel) != NULL) {
                ps_swizzle_instance_method(cls, portNameSel, @selector(pm_ps_portName));
                atomic_store_explicit(&s_audio_port_name_swizzled, true, memory_order_release);
            }
            SEL uidSel = NSSelectorFromString(@"UID");
            if (class_getInstanceMethod(cls, uidSel) != NULL) {
                ps_swizzle_instance_method(cls, uidSel, @selector(pm_ps_UID));
                atomic_store_explicit(&s_audio_port_uid_swizzled, true, memory_order_release);
            }
            if (class_getInstanceMethod(cls, @selector(description)) != NULL) {
                ps_swizzle_instance_method(cls, @selector(description), @selector(pm_ps_audio_port_description));
            }
            s_audio_port_hooks_installed = YES;
        }
    }
    os_unfair_lock_unlock(&s_audio_port_swizzle_lock);
}

static os_unfair_lock s_av_hooks_lock = OS_UNFAIR_LOCK_INIT;
static BOOL s_av_device_hooks_installed = NO;
static BOOL s_av_session_hooks_installed = NO;

static void ps_install_avcapture_hooks_if_loaded(void) {
    os_unfair_lock_lock(&s_av_hooks_lock);
    if (!s_av_device_hooks_installed) {
        Class avCls = objc_getClass("AVCaptureDevice");
        if (avCls != Nil) {
            SEL devicesSel = sel_registerName("devices");
            if (class_getClassMethod(avCls, devicesSel) != NULL) {
                ps_swizzle_class_method(avCls, devicesSel, @selector(pm_ps_av_devices));
            }
            SEL devicesMediaSel = sel_registerName("devicesWithMediaType:");
            if (class_getClassMethod(avCls, devicesMediaSel) != NULL) {
                ps_swizzle_class_method(avCls, devicesMediaSel, @selector(pm_ps_av_devicesWithMediaType:));
            }
            SEL defMediaSel = sel_registerName("defaultDeviceWithMediaType:");
            if (class_getClassMethod(avCls, defMediaSel) != NULL) {
                ps_swizzle_class_method(avCls, defMediaSel, @selector(pm_ps_av_defaultDeviceWithMediaType:));
            }
            SEL defTypeSel = sel_registerName("defaultDeviceWithDeviceType:mediaType:position:");
            if (class_getClassMethod(avCls, defTypeSel) != NULL) {
                ps_swizzle_class_method(avCls, defTypeSel, @selector(pm_ps_av_defaultDeviceWithDeviceType:mediaType:position:));
            }
            ps_swizzle_capture_device_class(avCls);
            s_av_device_hooks_installed = YES;
        }
    }
    if (!s_av_session_hooks_installed) {
        Class sessionCls = objc_getClass("AVCaptureDeviceDiscoverySession");
        if (sessionCls != Nil) {
            SEL devicesSel = sel_registerName("devices");
            if (class_getInstanceMethod(sessionCls, devicesSel) != NULL) {
                ps_swizzle_instance_method(sessionCls, devicesSel, @selector(pm_ps_av_session_devices));
            }
            s_av_session_hooks_installed = YES;
        }
    }
    os_unfair_lock_unlock(&s_av_hooks_lock);
}

static _Atomic bool s_ps_dynamic_hooks_ready = false;

__attribute__((visibility("hidden")))
void ps_load_environment_bypass_hooks(void) {
    Class piClass = objc_getClass("NSProcessInfo");
    ps_swizzle_instance_method(piClass, @selector(isMacCatalystApp), @selector(pm_isMacCatalystApp));
    ps_swizzle_instance_method(piClass, @selector(isiOSAppOnMac), @selector(pm_isiOSAppOnMac));
    ps_replace_instance_method(piClass, NSSelectorFromString(@"isiOSAppOnVision"), @selector(pm_return_no));
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
            ps_swizzle_instance_method(concretePIClass, @selector(isMacCatalystApp), @selector(pm_swift_isMacCatalystApp));
        }
        if (ps_class_defines_instance_method(concretePIClass, @selector(isiOSAppOnMac))) {
            ps_swizzle_instance_method(concretePIClass, @selector(isiOSAppOnMac), @selector(pm_swift_isiOSAppOnMac));
        }
        SEL visionSel = NSSelectorFromString(@"isiOSAppOnVision");
        if (ps_class_defines_instance_method(concretePIClass, visionSel)) {
            ps_replace_instance_method(concretePIClass, visionSel, @selector(pm_return_no));
        }
        SEL catAtLeastSel = NSSelectorFromString(@"macCatalystVersionIsAtLeastVersion:");
        if (ps_class_defines_instance_method(concretePIClass, catAtLeastSel)) {
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
    }

    Class viewCls = objc_getClass("UIView");
    if (viewCls != Nil && class_getInstanceMethod(viewCls, @selector(subviews)) != NULL) {
        ps_swizzle_instance_method(viewCls, @selector(subviews), @selector(pm_ps_subviews));
    }
    Class appCls = objc_getClass("UIApplication");
    if (appCls != Nil && class_getInstanceMethod(appCls, @selector(windows)) != NULL) {
        ps_swizzle_instance_method(appCls, @selector(windows), @selector(pm_ps_app_windows));
    }
    Class sceneCls = objc_getClass("UIWindowScene");
    if (sceneCls != Nil && class_getInstanceMethod(sceneCls, @selector(windows)) != NULL) {
        ps_swizzle_instance_method(sceneCls, @selector(windows), @selector(pm_ps_scene_windows));
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

static void ps_install_app_attest_hooks_if_loaded(void) {
    Class appAttestCls = objc_getClass("DCAppAttestService");
    if (appAttestCls != Nil) {
        static dispatch_once_t appAttestOnce;
        dispatch_once(&appAttestOnce, ^{
            SEL isSupportedSel = NSSelectorFromString(@"isSupported");
            if (class_getInstanceMethod(appAttestCls, isSupportedSel) != NULL) {
                ps_swizzle_instance_method(appAttestCls, isSupportedSel, @selector(pm_ps_appAttest_isSupported));
            }
            SEL genKeySel = NSSelectorFromString(@"generateKeyWithCompletionHandler:");
            if (class_getInstanceMethod(appAttestCls, genKeySel) != NULL) {
                ps_swizzle_instance_method(appAttestCls, genKeySel, @selector(pm_ps_appAttest_generateKeyWithCompletionHandler:));
            }
            SEL attestSel = NSSelectorFromString(@"attestKey:clientDataHash:completionHandler:");
            if (class_getInstanceMethod(appAttestCls, attestSel) != NULL) {
                ps_swizzle_instance_method(appAttestCls, attestSel, @selector(pm_ps_appAttest_attestKey:clientDataHash:completionHandler:));
            }
            SEL assertSel = NSSelectorFromString(@"generateAssertion:clientDataHash:completionHandler:");
            if (class_getInstanceMethod(appAttestCls, assertSel) != NULL) {
                ps_swizzle_instance_method(appAttestCls, assertSel, @selector(pm_ps_appAttest_generateAssertion:clientDataHash:completionHandler:));
            }
        });
    }
    Class dcDeviceCls = objc_getClass("DCDevice");
    if (dcDeviceCls != Nil) {
        static dispatch_once_t dcDeviceOnce;
        dispatch_once(&dcDeviceOnce, ^{
            SEL isSupportedSel = NSSelectorFromString(@"isSupported");
            if (class_getInstanceMethod(dcDeviceCls, isSupportedSel) != NULL) {
                ps_swizzle_instance_method(dcDeviceCls, isSupportedSel, @selector(pm_ps_dcDevice_isSupported));
            }
            SEL genTokenSel = NSSelectorFromString(@"generateTokenWithCompletionHandler:");
            if (class_getInstanceMethod(dcDeviceCls, genTokenSel) != NULL) {
                ps_swizzle_instance_method(dcDeviceCls, genTokenSel, @selector(pm_ps_dcDevice_generateTokenWithCompletionHandler:));
            }
        });
    }
}

__attribute__((visibility("hidden")))
@interface PSVirtualMotionState : NSObject
@property (nonatomic, assign) BOOL accelActive;
@property (nonatomic, assign) BOOL gyroActive;
@property (nonatomic, assign) BOOL magActive;
@property (nonatomic, assign) BOOL dmActive;
@property (nonatomic, strong) dispatch_source_t accelTimer;
@property (nonatomic, strong) dispatch_source_t gyroTimer;
@property (nonatomic, strong) dispatch_source_t magTimer;
@property (nonatomic, strong) dispatch_source_t dmTimer;
@end

@implementation PSVirtualMotionState
- (void)dealloc {
    if (_accelTimer) { dispatch_source_cancel(_accelTimer); _accelTimer = nil; }
    if (_gyroTimer) { dispatch_source_cancel(_gyroTimer); _gyroTimer = nil; }
    if (_magTimer) { dispatch_source_cancel(_magTimer); _magTimer = nil; }
    if (_dmTimer) { dispatch_source_cancel(_dmTimer); _dmTimer = nil; }
}
@end

static const char kPSMotionStateAssocKey = 0;
static const char kPSMotionSamplePayloadKey = 0;
static const char kPSRealDMMagneticFieldKey = 0;
static _Atomic uint64_t s_ps_motion_tick = 1ULL;
static Class s_ps_mockAccelCls = Nil;
static Class s_ps_mockGyroCls = Nil;
static Class s_ps_mockMagCls = Nil;
static Class s_ps_mockAttitudeCls = Nil;
static Class s_ps_mockDeviceMotionCls = Nil;

static os_unfair_lock s_ps_cm_clock_lock = OS_UNFAIR_LOCK_INIT;
static BOOL s_ps_cm_has_real_offset = NO;
static double s_ps_cm_real_offset = 0.0;
static double s_ps_cm_last_virtual_ts = 0.0;

__attribute__((visibility("hidden")))
@interface PSVirtualMotionSamplePayload : NSObject {
@public
    os_unfair_lock _lock;
    BOOL _hasTimestamp;
    NSTimeInterval _timestamp;
    CMAcceleration _acceleration;
    CMRotationRate _rotationRate;
    CMMagneticField _magneticField;
    CMAcceleration _userAcceleration;
    CMCalibratedMagneticField _calibratedMagneticField;
}
@end

@implementation PSVirtualMotionSamplePayload
- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _lock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}
@end

static PSVirtualMotionState *ps_motion_state(id mgr, BOOL createIfMissing) {
    if (mgr == nil) {
        return nil;
    }
    @synchronized (mgr) {
        PSVirtualMotionState *st = objc_getAssociatedObject(mgr, &kPSMotionStateAssocKey);
        if (st == nil && createIfMissing) {
            st = [[PSVirtualMotionState alloc] init];
            objc_setAssociatedObject(mgr, &kPSMotionStateAssocKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return st;
    }
}

static inline double ps_motion_micro_jitter(uint64_t seed, double scale) {
    uint64_t x = seed * 6364136223846793005ULL + 1442695040888963407ULL;
    x ^= (x >> 33);
    int32_t centered = (int32_t)(x & 0xFFFFU) - 32768;
    return ((double)centered / 32768.0) * scale;
}

static BOOL ps_is_mock_motion_sample(id sample) {
    if (sample == nil) {
        return NO;
    }
    Class cls = object_getClass(sample);
    return (cls != Nil) &&
           (cls == s_ps_mockAccelCls ||
            cls == s_ps_mockGyroCls ||
            cls == s_ps_mockMagCls ||
            cls == s_ps_mockDeviceMotionCls);
}

static void ps_cm_observe_real_sample(id sample) {
    if (sample == nil || ps_is_mock_motion_sample(sample)) {
        return;
    }
    if (![sample respondsToSelector:@selector(timestamp)]) {
        return;
    }
    double realTs = ((double (*)(id, SEL))objc_msgSend)(sample, @selector(timestamp));
    if (!isfinite(realTs) || realTs <= 0.0) {
        return;
    }
    double up = [[NSProcessInfo processInfo] systemUptime];
    if (!isfinite(up) || up < 0.0) {
        return;
    }
    double offset = realTs - up;
    os_unfair_lock_lock(&s_ps_cm_clock_lock);
    s_ps_cm_real_offset = offset;
    s_ps_cm_has_real_offset = YES;
    os_unfair_lock_unlock(&s_ps_cm_clock_lock);
}

static NSTimeInterval ps_cm_next_virtual_timestamp(void) {
    double up = [[NSProcessInfo processInfo] systemUptime];
    if (!isfinite(up) || up < 0.0) {
        up = 0.0;
    }
    os_unfair_lock_lock(&s_ps_cm_clock_lock);
    double ts = s_ps_cm_has_real_offset ? (up + s_ps_cm_real_offset) : up;
    if (!isfinite(ts) || ts <= 0.0) {
        ts = up;
    }
    if (ts <= s_ps_cm_last_virtual_ts) {
        ts = s_ps_cm_last_virtual_ts + 0.0001;
    }
    s_ps_cm_last_virtual_ts = ts;
    os_unfair_lock_unlock(&s_ps_cm_clock_lock);
    return ts;
}

static PSVirtualMotionSamplePayload *ps_make_initialized_motion_payload(void) {
    PSVirtualMotionSamplePayload *payload = [[PSVirtualMotionSamplePayload alloc] init];
    uint64_t t = atomic_fetch_add_explicit(&s_ps_motion_tick, 1ULL, memory_order_relaxed);
    payload->_acceleration = (CMAcceleration){
        .x = 0.0012 + ps_motion_micro_jitter(t, 0.0004),
        .y = -0.0085 + ps_motion_micro_jitter(t ^ 0x9E3779B9ULL, 0.0004),
        .z = -0.9998 + ps_motion_micro_jitter(t ^ 0x517CC1B7ULL, 0.0004)
    };
    payload->_rotationRate = (CMRotationRate){
        .x = ps_motion_micro_jitter(t ^ 0x11ULL, 0.0003),
        .y = ps_motion_micro_jitter(t ^ 0x22ULL, 0.0003),
        .z = ps_motion_micro_jitter(t ^ 0x33ULL, 0.0003)
    };
    payload->_magneticField = (CMMagneticField){
        .x = 18.4 + ps_motion_micro_jitter(t ^ 0x44ULL, 0.02),
        .y = -6.2 + ps_motion_micro_jitter(t ^ 0x55ULL, 0.02),
        .z = -41.5 + ps_motion_micro_jitter(t ^ 0x66ULL, 0.02)
    };
    payload->_userAcceleration = (CMAcceleration){
        .x = ps_motion_micro_jitter(t ^ 0x77ULL, 0.0003),
        .y = ps_motion_micro_jitter(t ^ 0x88ULL, 0.0003),
        .z = ps_motion_micro_jitter(t ^ 0x99ULL, 0.0003)
    };
    payload->_calibratedMagneticField = (CMCalibratedMagneticField){
        .field = payload->_magneticField,
        .accuracy = CMMagneticFieldCalibrationAccuracyHigh
    };
    return payload;
}

static PSVirtualMotionSamplePayload *ps_motion_sample_payload(id sample, BOOL createIfMissing) {
    if (sample == nil) {
        return nil;
    }
    @synchronized (sample) {
        PSVirtualMotionSamplePayload *payload = objc_getAssociatedObject(sample, &kPSMotionSamplePayloadKey);
        if (payload == nil && createIfMissing) {
            payload = ps_make_initialized_motion_payload();
            objc_setAssociatedObject(sample, &kPSMotionSamplePayloadKey, payload, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return payload;
    }
}

static void ps_copy_hook_method_to_class(Class dstCls, SEL dstSel, SEL srcHookSel) {
    if (dstCls == Nil || dstSel == NULL || srcHookSel == NULL) {
        return;
    }
    Method m = class_getInstanceMethod([PSSwizzleHooks class], srcHookSel);
    if (m != NULL) {
        class_addMethod(dstCls, dstSel, method_getImplementation(m), method_getTypeEncoding(m));
    }
}

static void ps_ensure_mock_motion_sample_classes(void) {
    static dispatch_once_t sampleOnce;
    dispatch_once(&sampleOnce, ^{
        Class baseAccel = objc_getClass("CMAccelerometerData");
        if (baseAccel != Nil) {
            Class c = objc_allocateClassPair(baseAccel, "PSVirtualAccelerometerData", 0);
            if (c != Nil) {
                ps_copy_hook_method_to_class(c, @selector(class), @selector(pm_ps_cm_accel_class));
                ps_copy_hook_method_to_class(c, @selector(copyWithZone:), @selector(pm_ps_cm_copyWithZone:));
                ps_copy_hook_method_to_class(c, @selector(description), @selector(pm_ps_cm_sample_description));
                ps_copy_hook_method_to_class(c, @selector(timestamp), @selector(pm_ps_cm_sample_timestamp));
                ps_copy_hook_method_to_class(c, @selector(acceleration), @selector(pm_ps_cm_sample_acceleration));
                objc_registerClassPair(c);
                s_ps_mockAccelCls = c;
            }
        }
        Class baseGyro = objc_getClass("CMGyroData");
        if (baseGyro != Nil) {
            Class c = objc_allocateClassPair(baseGyro, "PSVirtualGyroData", 0);
            if (c != Nil) {
                ps_copy_hook_method_to_class(c, @selector(class), @selector(pm_ps_cm_gyro_class));
                ps_copy_hook_method_to_class(c, @selector(copyWithZone:), @selector(pm_ps_cm_copyWithZone:));
                ps_copy_hook_method_to_class(c, @selector(description), @selector(pm_ps_cm_sample_description));
                ps_copy_hook_method_to_class(c, @selector(timestamp), @selector(pm_ps_cm_sample_timestamp));
                ps_copy_hook_method_to_class(c, @selector(rotationRate), @selector(pm_ps_cm_sample_rotationRate));
                objc_registerClassPair(c);
                s_ps_mockGyroCls = c;
            }
        }
        Class baseMag = objc_getClass("CMMagnetometerData");
        if (baseMag != Nil) {
            Class c = objc_allocateClassPair(baseMag, "PSVirtualMagnetometerData", 0);
            if (c != Nil) {
                ps_copy_hook_method_to_class(c, @selector(class), @selector(pm_ps_cm_mag_class));
                ps_copy_hook_method_to_class(c, @selector(copyWithZone:), @selector(pm_ps_cm_copyWithZone:));
                ps_copy_hook_method_to_class(c, @selector(description), @selector(pm_ps_cm_sample_description));
                ps_copy_hook_method_to_class(c, @selector(timestamp), @selector(pm_ps_cm_sample_timestamp));
                ps_copy_hook_method_to_class(c, @selector(magneticField), @selector(pm_ps_cm_sample_magneticField));
                objc_registerClassPair(c);
                s_ps_mockMagCls = c;
            }
        }
        Class baseAtt = objc_getClass("CMAttitude");
        if (baseAtt != Nil) {
            Class c = objc_allocateClassPair(baseAtt, "PSVirtualAttitude", 0);
            if (c != Nil) {
                ps_copy_hook_method_to_class(c, @selector(class), @selector(pm_ps_cm_attitude_class));
                ps_copy_hook_method_to_class(c, @selector(copyWithZone:), @selector(pm_ps_cm_copyWithZone:));
                ps_copy_hook_method_to_class(c, @selector(description), @selector(pm_ps_cm_attitude_description));
                ps_copy_hook_method_to_class(c, @selector(roll), @selector(pm_ps_cm_attitude_roll));
                ps_copy_hook_method_to_class(c, @selector(pitch), @selector(pm_ps_cm_attitude_pitch));
                ps_copy_hook_method_to_class(c, @selector(yaw), @selector(pm_ps_cm_attitude_yaw));
                ps_copy_hook_method_to_class(c, @selector(quaternion), @selector(pm_ps_cm_attitude_quaternion));
                ps_copy_hook_method_to_class(c, @selector(rotationMatrix), @selector(pm_ps_cm_attitude_rotationMatrix));
                ps_copy_hook_method_to_class(c, @selector(multiplyByInverseOfAttitude:), @selector(pm_ps_cm_attitude_multiplyByInverseOfAttitude:));
                objc_registerClassPair(c);
                s_ps_mockAttitudeCls = c;
            }
        }
        Class baseDM = objc_getClass("CMDeviceMotion");
        if (baseDM != Nil) {
            Class c = objc_allocateClassPair(baseDM, "PSVirtualDeviceMotion", 0);
            if (c != Nil) {
                ps_copy_hook_method_to_class(c, @selector(class), @selector(pm_ps_cm_dm_class));
                ps_copy_hook_method_to_class(c, @selector(copyWithZone:), @selector(pm_ps_cm_copyWithZone:));
                ps_copy_hook_method_to_class(c, @selector(description), @selector(pm_ps_cm_sample_description));
                ps_copy_hook_method_to_class(c, @selector(timestamp), @selector(pm_ps_cm_sample_timestamp));
                ps_copy_hook_method_to_class(c, @selector(attitude), @selector(pm_ps_cm_dm_attitude));
                ps_copy_hook_method_to_class(c, @selector(gravity), @selector(pm_ps_cm_dm_gravity));
                ps_copy_hook_method_to_class(c, @selector(userAcceleration), @selector(pm_ps_cm_dm_userAcceleration));
                ps_copy_hook_method_to_class(c, @selector(rotationRate), @selector(pm_ps_cm_sample_rotationRate));
                ps_copy_hook_method_to_class(c, @selector(magneticField), @selector(pm_ps_cm_dm_magneticField));
                ps_copy_hook_method_to_class(c, @selector(heading), @selector(pm_ps_cm_dm_heading));
                objc_registerClassPair(c);
                s_ps_mockDeviceMotionCls = c;
            }
        }
    });
}

static id ps_make_mock_sample_instance(Class cls) {
    ps_ensure_mock_motion_sample_classes();
    id instance = (cls != Nil) ? [[cls alloc] init] : nil;
    if (instance != nil) {
        (void)ps_motion_sample_payload(instance, YES);
    }
    return instance;
}

static dispatch_source_t ps_schedule_motion_timer(id mgr,
                                                  NSTimeInterval interval,
                                                  NSOperationQueue *queue,
                                                  void (^emitBlock)(id strongMgr)) {
    if (mgr == nil || emitBlock == nil) {
        return nil;
    }
    double sec = (isfinite(interval) && interval >= 0.01) ? interval : 0.05;
    NSOperationQueue *targetQueue = queue ?: [NSOperationQueue mainQueue];
    __weak id weakMgr = mgr;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    if (timer == nil) {
        return nil;
    }
    uint64_t ns = (uint64_t)(sec * (double)NSEC_PER_SEC);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), ns, ns / 5ULL);
    dispatch_source_set_event_handler(timer, ^{
        id strongMgr = weakMgr;
        if (strongMgr == nil) {
            dispatch_source_cancel(timer);
            return;
        }
        [targetQueue addOperationWithBlock:^{
            id innerMgr = weakMgr;
            if (innerMgr != nil) {
                emitBlock(innerMgr);
            }
        }];
    });
    dispatch_resume(timer);
    return timer;
}

@implementation PSSwizzleHooks (PlayShadowCoreMotion)

- (Class) pm_ps_cm_accel_class { return objc_getClass("CMAccelerometerData"); }
- (Class) pm_ps_cm_gyro_class { return objc_getClass("CMGyroData"); }
- (Class) pm_ps_cm_mag_class { return objc_getClass("CMMagnetometerData"); }
- (Class) pm_ps_cm_attitude_class { return objc_getClass("CMAttitude"); }
- (Class) pm_ps_cm_dm_class { return objc_getClass("CMDeviceMotion"); }

- (id) pm_ps_cm_copyWithZone:(NSZone * __unused)zone NS_RETURNS_RETAINED {
    return self;
}

- (NSString *) pm_ps_cm_sample_description {
    return [NSString stringWithFormat:@"<%@ %p timestamp=%.6f>",
            NSStringFromClass([self class]),
            self,
            [[self valueForKey:@"timestamp"] doubleValue]];
}

- (NSString *) pm_ps_cm_attitude_description {
    return [NSString stringWithFormat:@"<CMAttitude %p roll=%.4f pitch=%.4f yaw=%.4f>",
            self, 0.0012, 0.0085, 0.0];
}

- (void) pm_ps_cm_attitude_multiplyByInverseOfAttitude:(CMAttitude * __unused)attitude {
}

- (NSTimeInterval) pm_ps_cm_sample_timestamp {
    PSVirtualMotionSamplePayload *payload = ps_motion_sample_payload(self, YES);
    if (payload == nil) {
        return ps_cm_next_virtual_timestamp();
    }
    os_unfair_lock_lock(&payload->_lock);
    if (!payload->_hasTimestamp) {
        payload->_timestamp = ps_cm_next_virtual_timestamp();
        payload->_hasTimestamp = YES;
    }
    NSTimeInterval ts = payload->_timestamp;
    os_unfair_lock_unlock(&payload->_lock);
    return ts;
}

- (CMAcceleration) pm_ps_cm_sample_acceleration {
    PSVirtualMotionSamplePayload *payload = ps_motion_sample_payload(self, YES);
    if (payload != nil) {
        return payload->_acceleration;
    }
    return (CMAcceleration){ .x = 0.0012, .y = -0.0085, .z = -0.9998 };
}

- (CMRotationRate) pm_ps_cm_sample_rotationRate {
    PSVirtualMotionSamplePayload *payload = ps_motion_sample_payload(self, YES);
    if (payload != nil) {
        return payload->_rotationRate;
    }
    return (CMRotationRate){ .x = 0.0, .y = 0.0, .z = 0.0 };
}

- (CMMagneticField) pm_ps_cm_sample_magneticField {
    PSVirtualMotionSamplePayload *payload = ps_motion_sample_payload(self, YES);
    if (payload != nil) {
        return payload->_magneticField;
    }
    return (CMMagneticField){ .x = 18.4, .y = -6.2, .z = -41.5 };
}

- (double) pm_ps_cm_attitude_roll { return 0.0012; }
- (double) pm_ps_cm_attitude_pitch { return 0.0085; }
- (double) pm_ps_cm_attitude_yaw { return 0.0; }

- (CMQuaternion) pm_ps_cm_attitude_quaternion {
    return (CMQuaternion){ .x = 0.00425, .y = 0.0006, .z = 0.0, .w = 0.99999 };
}

- (CMRotationMatrix) pm_ps_cm_attitude_rotationMatrix {
    return (CMRotationMatrix){
        .m11 = 1.0, .m12 = 0.0, .m13 = 0.0,
        .m21 = 0.0, .m22 = 1.0, .m23 = 0.0,
        .m31 = 0.0, .m32 = 0.0, .m33 = 1.0
    };
}

- (CMAttitude *) pm_ps_cm_dm_attitude {
    ps_ensure_mock_motion_sample_classes();
    return (s_ps_mockAttitudeCls != Nil) ? [[s_ps_mockAttitudeCls alloc] init] : nil;
}

- (CMAcceleration) pm_ps_cm_dm_gravity {
    return (CMAcceleration){ .x = 0.0012, .y = -0.0085, .z = -0.9999 };
}

- (CMAcceleration) pm_ps_cm_dm_userAcceleration {
    PSVirtualMotionSamplePayload *payload = ps_motion_sample_payload(self, YES);
    if (payload != nil) {
        return payload->_userAcceleration;
    }
    return (CMAcceleration){ .x = 0.0, .y = 0.0, .z = 0.0 };
}

- (CMCalibratedMagneticField) pm_ps_cm_dm_magneticField {
    PSVirtualMotionSamplePayload *payload = ps_motion_sample_payload(self, YES);
    if (payload != nil) {
        return payload->_calibratedMagneticField;
    }
    return (CMCalibratedMagneticField){
        .field = { .x = 18.4, .y = -6.2, .z = -41.5 },
        .accuracy = CMMagneticFieldCalibrationAccuracyHigh
    };
}

- (CMCalibratedMagneticField) pm_ps_cm_real_dm_magneticField {
    CMCalibratedMagneticField orig = [self pm_ps_cm_real_dm_magneticField];
    if (orig.accuracy == CMMagneticFieldCalibrationAccuracyUncalibrated &&
        orig.field.x == 0.0 &&
        orig.field.y == 0.0 &&
        orig.field.z == 0.0 &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        @synchronized (self) {
            NSValue *cached = objc_getAssociatedObject(self, &kPSRealDMMagneticFieldKey);
            if (cached != nil && strcmp(cached.objCType, @encode(CMCalibratedMagneticField)) == 0) {
                CMCalibratedMagneticField out = {0};
                [cached getValue:&out];
                return out;
            }
            uint64_t t = atomic_fetch_add_explicit(&s_ps_motion_tick, 1ULL, memory_order_relaxed);
            CMCalibratedMagneticField synth = {
                .field = {
                    .x = 18.4 + ps_motion_micro_jitter(t ^ 0x44ULL, 0.02),
                    .y = -6.2 + ps_motion_micro_jitter(t ^ 0x55ULL, 0.02),
                    .z = -41.5 + ps_motion_micro_jitter(t ^ 0x66ULL, 0.02)
                },
                .accuracy = CMMagneticFieldCalibrationAccuracyHigh
            };
            NSValue *boxed = [NSValue valueWithBytes:&synth objCType:@encode(CMCalibratedMagneticField)];
            objc_setAssociatedObject(self, &kPSRealDMMagneticFieldKey, boxed, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return synth;
        }
    }
    return orig;
}

- (double) pm_ps_cm_dm_heading { return 18.6; }

- (BOOL) pm_ps_cm_isAccelerometerAvailable {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return YES;
    }
    return [self pm_ps_cm_isAccelerometerAvailable];
}

- (BOOL) pm_ps_cm_isGyroAvailable {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return YES;
    }
    return [self pm_ps_cm_isGyroAvailable];
}

- (BOOL) pm_ps_cm_isMagnetometerAvailable {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return YES;
    }
    return [self pm_ps_cm_isMagnetometerAvailable];
}

- (BOOL) pm_ps_cm_isDeviceMotionAvailable {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return YES;
    }
    return [self pm_ps_cm_isDeviceMotionAvailable];
}

+ (BOOL) pm_ps_cm_isRelativeAltitudeAvailable {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return YES;
    }
    return [self pm_ps_cm_isRelativeAltitudeAvailable];
}

- (BOOL) pm_ps_cm_isAccelerometerActive {
    BOOL orig = [self pm_ps_cm_isAccelerometerActive];
    if (!orig && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        PSVirtualMotionState *st = ps_motion_state(self, NO);
        if (st != nil) {
            @synchronized (st) {
                return st.accelActive;
            }
        }
    }
    return orig;
}

- (BOOL) pm_ps_cm_isGyroActive {
    BOOL orig = [self pm_ps_cm_isGyroActive];
    if (!orig && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        PSVirtualMotionState *st = ps_motion_state(self, NO);
        if (st != nil) {
            @synchronized (st) {
                return st.gyroActive;
            }
        }
    }
    return orig;
}

- (BOOL) pm_ps_cm_isMagnetometerActive {
    BOOL orig = [self pm_ps_cm_isMagnetometerActive];
    if (!orig && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        PSVirtualMotionState *st = ps_motion_state(self, NO);
        if (st != nil) {
            @synchronized (st) {
                return st.magActive;
            }
        }
    }
    return orig;
}

- (BOOL) pm_ps_cm_isDeviceMotionActive {
    BOOL orig = [self pm_ps_cm_isDeviceMotionActive];
    if (!orig && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        PSVirtualMotionState *st = ps_motion_state(self, NO);
        if (st != nil) {
            @synchronized (st) {
                return st.dmActive;
            }
        }
    }
    return orig;
}

- (CMAccelerometerData *) pm_ps_cm_accelerometerData {
    CMAccelerometerData *orig = [self pm_ps_cm_accelerometerData];
    ps_cm_observe_real_sample(orig);
    if (orig == nil && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        PSVirtualMotionState *st = ps_motion_state(self, NO);
        BOOL active = NO;
        if (st != nil) {
            @synchronized (st) {
                active = st.accelActive;
            }
        }
        if (active) {
            ps_ensure_mock_motion_sample_classes();
            return ps_make_mock_sample_instance(s_ps_mockAccelCls);
        }
    }
    return orig;
}

- (CMGyroData *) pm_ps_cm_gyroData {
    CMGyroData *orig = [self pm_ps_cm_gyroData];
    ps_cm_observe_real_sample(orig);
    if (orig == nil && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        PSVirtualMotionState *st = ps_motion_state(self, NO);
        BOOL active = NO;
        if (st != nil) {
            @synchronized (st) {
                active = st.gyroActive;
            }
        }
        if (active) {
            ps_ensure_mock_motion_sample_classes();
            return ps_make_mock_sample_instance(s_ps_mockGyroCls);
        }
    }
    return orig;
}

- (CMMagnetometerData *) pm_ps_cm_magnetometerData {
    CMMagnetometerData *orig = [self pm_ps_cm_magnetometerData];
    ps_cm_observe_real_sample(orig);
    if (orig == nil && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        PSVirtualMotionState *st = ps_motion_state(self, NO);
        BOOL active = NO;
        if (st != nil) {
            @synchronized (st) {
                active = st.magActive;
            }
        }
        if (active) {
            ps_cm_observe_real_sample([self pm_ps_cm_accelerometerData]);
            ps_cm_observe_real_sample([self pm_ps_cm_deviceMotion]);
            ps_ensure_mock_motion_sample_classes();
            return ps_make_mock_sample_instance(s_ps_mockMagCls);
        }
    }
    return orig;
}

- (CMDeviceMotion *) pm_ps_cm_deviceMotion {
    CMDeviceMotion *orig = [self pm_ps_cm_deviceMotion];
    ps_cm_observe_real_sample(orig);
    if (orig == nil && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        PSVirtualMotionState *st = ps_motion_state(self, NO);
        BOOL active = NO;
        if (st != nil) {
            @synchronized (st) {
                active = st.dmActive;
            }
        }
        if (active) {
            ps_ensure_mock_motion_sample_classes();
            return ps_make_mock_sample_instance(s_ps_mockDeviceMotionCls);
        }
    }
    return orig;
}

- (void) pm_ps_cm_startAccelerometerUpdates {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        ![self pm_ps_cm_isAccelerometerAvailable]) {
        PSVirtualMotionState *st = ps_motion_state(self, YES);
        @synchronized (st) {
            st.accelActive = YES;
        }
    }
    [self pm_ps_cm_startAccelerometerUpdates];
}

- (void) pm_ps_cm_startAccelerometerUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMAccelerometerHandler)handler {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        ![self pm_ps_cm_isAccelerometerAvailable]) {
        PSVirtualMotionState *st = ps_motion_state(self, YES);
        @synchronized (st) {
            st.accelActive = YES;
            if (st.accelTimer) { dispatch_source_cancel(st.accelTimer); st.accelTimer = nil; }
            if (handler != nil) {
                NSTimeInterval iv = ((CMMotionManager *)self).accelerometerUpdateInterval;
                st.accelTimer = ps_schedule_motion_timer(self, iv, queue, ^(__unused id mgr) {
                    ps_ensure_mock_motion_sample_classes();
                    CMAccelerometerData *sample = ps_make_mock_sample_instance(s_ps_mockAccelCls);
                    if (sample != nil) {
                        handler(sample, nil);
                    }
                });
                return;
            }
        }
    }
    if (handler != nil && pt_is_bypass_enabled()) {
        CMAccelerometerHandler userHandler = [handler copy];
        [self pm_ps_cm_startAccelerometerUpdatesToQueue:queue withHandler:^(CMAccelerometerData *data, NSError *error) {
            ps_cm_observe_real_sample(data);
            userHandler(data, error);
        }];
        return;
    }
    [self pm_ps_cm_startAccelerometerUpdatesToQueue:queue withHandler:handler];
}

- (void) pm_ps_cm_stopAccelerometerUpdates {
    PSVirtualMotionState *st = ps_motion_state(self, NO);
    if (st != nil) {
        @synchronized (st) {
            st.accelActive = NO;
            if (st.accelTimer) { dispatch_source_cancel(st.accelTimer); st.accelTimer = nil; }
        }
    }
    [self pm_ps_cm_stopAccelerometerUpdates];
}

- (void) pm_ps_cm_startGyroUpdates {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        ![self pm_ps_cm_isGyroAvailable]) {
        PSVirtualMotionState *st = ps_motion_state(self, YES);
        @synchronized (st) {
            st.gyroActive = YES;
        }
    }
    [self pm_ps_cm_startGyroUpdates];
}

- (void) pm_ps_cm_startGyroUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMGyroHandler)handler {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        ![self pm_ps_cm_isGyroAvailable]) {
        PSVirtualMotionState *st = ps_motion_state(self, YES);
        @synchronized (st) {
            st.gyroActive = YES;
            if (st.gyroTimer) { dispatch_source_cancel(st.gyroTimer); st.gyroTimer = nil; }
            if (handler != nil) {
                NSTimeInterval iv = ((CMMotionManager *)self).gyroUpdateInterval;
                st.gyroTimer = ps_schedule_motion_timer(self, iv, queue, ^(__unused id mgr) {
                    ps_ensure_mock_motion_sample_classes();
                    CMGyroData *sample = ps_make_mock_sample_instance(s_ps_mockGyroCls);
                    if (sample != nil) {
                        handler(sample, nil);
                    }
                });
                return;
            }
        }
    }
    if (handler != nil && pt_is_bypass_enabled()) {
        CMGyroHandler userHandler = [handler copy];
        [self pm_ps_cm_startGyroUpdatesToQueue:queue withHandler:^(CMGyroData *data, NSError *error) {
            ps_cm_observe_real_sample(data);
            userHandler(data, error);
        }];
        return;
    }
    [self pm_ps_cm_startGyroUpdatesToQueue:queue withHandler:handler];
}

- (void) pm_ps_cm_stopGyroUpdates {
    PSVirtualMotionState *st = ps_motion_state(self, NO);
    if (st != nil) {
        @synchronized (st) {
            st.gyroActive = NO;
            if (st.gyroTimer) { dispatch_source_cancel(st.gyroTimer); st.gyroTimer = nil; }
        }
    }
    [self pm_ps_cm_stopGyroUpdates];
}

- (void) pm_ps_cm_startMagnetometerUpdates {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        ![self pm_ps_cm_isMagnetometerAvailable]) {
        ps_cm_observe_real_sample([self pm_ps_cm_accelerometerData]);
        ps_cm_observe_real_sample([self pm_ps_cm_deviceMotion]);
        PSVirtualMotionState *st = ps_motion_state(self, YES);
        @synchronized (st) {
            st.magActive = YES;
        }
    }
    [self pm_ps_cm_startMagnetometerUpdates];
}

- (void) pm_ps_cm_startMagnetometerUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMMagnetometerHandler)handler {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        ![self pm_ps_cm_isMagnetometerAvailable]) {
        ps_cm_observe_real_sample([self pm_ps_cm_accelerometerData]);
        ps_cm_observe_real_sample([self pm_ps_cm_deviceMotion]);
        PSVirtualMotionState *st = ps_motion_state(self, YES);
        @synchronized (st) {
            st.magActive = YES;
            if (st.magTimer) { dispatch_source_cancel(st.magTimer); st.magTimer = nil; }
            if (handler != nil) {
                NSTimeInterval iv = ((CMMotionManager *)self).magnetometerUpdateInterval;
                st.magTimer = ps_schedule_motion_timer(self, iv, queue, ^(__unused id mgr) {
                    ps_ensure_mock_motion_sample_classes();
                    CMMagnetometerData *sample = ps_make_mock_sample_instance(s_ps_mockMagCls);
                    if (sample != nil) {
                        handler(sample, nil);
                    }
                });
                return;
            }
        }
    }
    if (handler != nil && pt_is_bypass_enabled()) {
        CMMagnetometerHandler userHandler = [handler copy];
        [self pm_ps_cm_startMagnetometerUpdatesToQueue:queue withHandler:^(CMMagnetometerData *data, NSError *error) {
            ps_cm_observe_real_sample(data);
            userHandler(data, error);
        }];
        return;
    }
    [self pm_ps_cm_startMagnetometerUpdatesToQueue:queue withHandler:handler];
}

- (void) pm_ps_cm_stopMagnetometerUpdates {
    PSVirtualMotionState *st = ps_motion_state(self, NO);
    if (st != nil) {
        @synchronized (st) {
            st.magActive = NO;
            if (st.magTimer) { dispatch_source_cancel(st.magTimer); st.magTimer = nil; }
        }
    }
    [self pm_ps_cm_stopMagnetometerUpdates];
}

- (void) pm_ps_cm_startDeviceMotionUpdates {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        ![self pm_ps_cm_isDeviceMotionAvailable]) {
        PSVirtualMotionState *st = ps_motion_state(self, YES);
        @synchronized (st) {
            st.dmActive = YES;
        }
    }
    [self pm_ps_cm_startDeviceMotionUpdates];
}

- (void) pm_ps_cm_startDeviceMotionUpdatesUsingReferenceFrame:(CMAttitudeReferenceFrame)frame {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        ![self pm_ps_cm_isDeviceMotionAvailable]) {
        PSVirtualMotionState *st = ps_motion_state(self, YES);
        @synchronized (st) {
            st.dmActive = YES;
        }
    }
    [self pm_ps_cm_startDeviceMotionUpdatesUsingReferenceFrame:frame];
}

- (void) pm_ps_cm_startDeviceMotionUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMDeviceMotionHandler)handler {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        ![self pm_ps_cm_isDeviceMotionAvailable]) {
        PSVirtualMotionState *st = ps_motion_state(self, YES);
        @synchronized (st) {
            st.dmActive = YES;
            if (st.dmTimer) { dispatch_source_cancel(st.dmTimer); st.dmTimer = nil; }
            if (handler != nil) {
                NSTimeInterval iv = ((CMMotionManager *)self).deviceMotionUpdateInterval;
                st.dmTimer = ps_schedule_motion_timer(self, iv, queue, ^(__unused id mgr) {
                    ps_ensure_mock_motion_sample_classes();
                    CMDeviceMotion *sample = ps_make_mock_sample_instance(s_ps_mockDeviceMotionCls);
                    if (sample != nil) {
                        handler(sample, nil);
                    }
                });
                return;
            }
        }
    }
    if (handler != nil && pt_is_bypass_enabled()) {
        CMDeviceMotionHandler userHandler = [handler copy];
        [self pm_ps_cm_startDeviceMotionUpdatesToQueue:queue withHandler:^(CMDeviceMotion *motion, NSError *error) {
            ps_cm_observe_real_sample(motion);
            userHandler(motion, error);
        }];
        return;
    }
    [self pm_ps_cm_startDeviceMotionUpdatesToQueue:queue withHandler:handler];
}

- (void) pm_ps_cm_startDeviceMotionUpdatesUsingReferenceFrame:(CMAttitudeReferenceFrame)frame
                                                      toQueue:(NSOperationQueue *)queue
                                                  withHandler:(CMDeviceMotionHandler)handler {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        ![self pm_ps_cm_isDeviceMotionAvailable]) {
        PSVirtualMotionState *st = ps_motion_state(self, YES);
        @synchronized (st) {
            st.dmActive = YES;
            if (st.dmTimer) { dispatch_source_cancel(st.dmTimer); st.dmTimer = nil; }
            if (handler != nil) {
                NSTimeInterval iv = ((CMMotionManager *)self).deviceMotionUpdateInterval;
                st.dmTimer = ps_schedule_motion_timer(self, iv, queue, ^(__unused id mgr) {
                    ps_ensure_mock_motion_sample_classes();
                    CMDeviceMotion *sample = ps_make_mock_sample_instance(s_ps_mockDeviceMotionCls);
                    if (sample != nil) {
                        handler(sample, nil);
                    }
                });
                return;
            }
        }
    }
    if (handler != nil && pt_is_bypass_enabled()) {
        CMDeviceMotionHandler userHandler = [handler copy];
        [self pm_ps_cm_startDeviceMotionUpdatesUsingReferenceFrame:frame toQueue:queue withHandler:^(CMDeviceMotion *motion, NSError *error) {
            ps_cm_observe_real_sample(motion);
            userHandler(motion, error);
        }];
        return;
    }
    [self pm_ps_cm_startDeviceMotionUpdatesUsingReferenceFrame:frame toQueue:queue withHandler:handler];
}

- (void) pm_ps_cm_stopDeviceMotionUpdates {
    PSVirtualMotionState *st = ps_motion_state(self, NO);
    if (st != nil) {
        @synchronized (st) {
            st.dmActive = NO;
            if (st.dmTimer) { dispatch_source_cancel(st.dmTimer); st.dmTimer = nil; }
        }
    }
    [self pm_ps_cm_stopDeviceMotionUpdates];
}

@end

static void ps_install_coremotion_hooks_if_loaded(void) {
    Class cmCls = objc_getClass("CMMotionManager");
    if (cmCls != Nil) {
        static dispatch_once_t cmOnce;
        dispatch_once(&cmOnce, ^{
            ps_ensure_mock_motion_sample_classes();
            ps_swizzle_instance_method(cmCls, @selector(isAccelerometerAvailable), @selector(pm_ps_cm_isAccelerometerAvailable));
            ps_swizzle_instance_method(cmCls, @selector(isGyroAvailable), @selector(pm_ps_cm_isGyroAvailable));
            ps_swizzle_instance_method(cmCls, @selector(isMagnetometerAvailable), @selector(pm_ps_cm_isMagnetometerAvailable));
            ps_swizzle_instance_method(cmCls, @selector(isDeviceMotionAvailable), @selector(pm_ps_cm_isDeviceMotionAvailable));
            ps_swizzle_instance_method(cmCls, @selector(isAccelerometerActive), @selector(pm_ps_cm_isAccelerometerActive));
            ps_swizzle_instance_method(cmCls, @selector(isGyroActive), @selector(pm_ps_cm_isGyroActive));
            ps_swizzle_instance_method(cmCls, @selector(isMagnetometerActive), @selector(pm_ps_cm_isMagnetometerActive));
            ps_swizzle_instance_method(cmCls, @selector(isDeviceMotionActive), @selector(pm_ps_cm_isDeviceMotionActive));
            ps_swizzle_instance_method(cmCls, @selector(accelerometerData), @selector(pm_ps_cm_accelerometerData));
            ps_swizzle_instance_method(cmCls, @selector(gyroData), @selector(pm_ps_cm_gyroData));
            ps_swizzle_instance_method(cmCls, @selector(magnetometerData), @selector(pm_ps_cm_magnetometerData));
            ps_swizzle_instance_method(cmCls, @selector(deviceMotion), @selector(pm_ps_cm_deviceMotion));
            ps_swizzle_instance_method(cmCls, @selector(startAccelerometerUpdates), @selector(pm_ps_cm_startAccelerometerUpdates));
            ps_swizzle_instance_method(cmCls, @selector(startAccelerometerUpdatesToQueue:withHandler:), @selector(pm_ps_cm_startAccelerometerUpdatesToQueue:withHandler:));
            ps_swizzle_instance_method(cmCls, @selector(stopAccelerometerUpdates), @selector(pm_ps_cm_stopAccelerometerUpdates));
            ps_swizzle_instance_method(cmCls, @selector(startGyroUpdates), @selector(pm_ps_cm_startGyroUpdates));
            ps_swizzle_instance_method(cmCls, @selector(startGyroUpdatesToQueue:withHandler:), @selector(pm_ps_cm_startGyroUpdatesToQueue:withHandler:));
            ps_swizzle_instance_method(cmCls, @selector(stopGyroUpdates), @selector(pm_ps_cm_stopGyroUpdates));
            ps_swizzle_instance_method(cmCls, @selector(startMagnetometerUpdates), @selector(pm_ps_cm_startMagnetometerUpdates));
            ps_swizzle_instance_method(cmCls, @selector(startMagnetometerUpdatesToQueue:withHandler:), @selector(pm_ps_cm_startMagnetometerUpdatesToQueue:withHandler:));
            ps_swizzle_instance_method(cmCls, @selector(stopMagnetometerUpdates), @selector(pm_ps_cm_stopMagnetometerUpdates));
            ps_swizzle_instance_method(cmCls, @selector(startDeviceMotionUpdates), @selector(pm_ps_cm_startDeviceMotionUpdates));
            ps_swizzle_instance_method(cmCls, @selector(startDeviceMotionUpdatesUsingReferenceFrame:), @selector(pm_ps_cm_startDeviceMotionUpdatesUsingReferenceFrame:));
            ps_swizzle_instance_method(cmCls, @selector(startDeviceMotionUpdatesToQueue:withHandler:), @selector(pm_ps_cm_startDeviceMotionUpdatesToQueue:withHandler:));
            ps_swizzle_instance_method(cmCls, @selector(startDeviceMotionUpdatesUsingReferenceFrame:toQueue:withHandler:), @selector(pm_ps_cm_startDeviceMotionUpdatesUsingReferenceFrame:toQueue:withHandler:));
            ps_swizzle_instance_method(cmCls, @selector(stopDeviceMotionUpdates), @selector(pm_ps_cm_stopDeviceMotionUpdates));
        });
    }
    Class dmCls = objc_getClass("CMDeviceMotion");
    if (dmCls != Nil) {
        static dispatch_once_t dmOnce;
        dispatch_once(&dmOnce, ^{
            ps_ensure_mock_motion_sample_classes();
            ps_swizzle_instance_method(dmCls, @selector(magneticField), @selector(pm_ps_cm_real_dm_magneticField));
        });
    }
    Class altCls = objc_getClass("CMAltimeter");
    if (altCls != Nil) {
        static dispatch_once_t altOnce;
        dispatch_once(&altOnce, ^{
            ps_swizzle_class_method(altCls, @selector(isRelativeAltitudeAvailable), @selector(pm_ps_cm_isRelativeAltitudeAvailable));
        });
    }
}

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
        pt_install_graphics_hooks_if_loaded();
        ps_install_webkit_hooks_if_loaded();
        ps_install_quicklook_hooks_if_loaded();
        ps_install_audio_session_port_hooks();
        ps_install_avcapture_hooks_if_loaded();
        ps_install_app_attest_hooks_if_loaded();
        ps_install_coremotion_hooks_if_loaded();
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
    ps_swizzle_instance_method(objc_getClass("UITraitCollection"), @selector(userInterfaceIdiom), @selector(pm_hook_traitUserInterfaceIdiom));
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
        { @selector(pathForResource:ofType:), @selector(pm_ps_pathForResource:ofType:) },
        { @selector(pathForResource:ofType:inDirectory:), @selector(pm_ps_pathForResource:ofType:inDirectory:) },
        { @selector(pathForResource:ofType:inDirectory:forLocalization:), @selector(pm_ps_pathForResource:ofType:inDirectory:forLocalization:) },
        { @selector(URLForResource:withExtension:), @selector(pm_ps_URLForResource:withExtension:) },
        { @selector(URLForResource:withExtension:subdirectory:), @selector(pm_ps_URLForResource:withExtension:subdirectory:) },
        { @selector(URLForResource:withExtension:subdirectory:localization:), @selector(pm_ps_URLForResource:withExtension:subdirectory:localization:) },
        { @selector(pathsForResourcesOfType:inDirectory:), @selector(pm_ps_pathsForResourcesOfType:inDirectory:) },
        { @selector(URLsForResourcesWithExtension:subdirectory:), @selector(pm_ps_URLsForResourcesWithExtension:subdirectory:) },
        { @selector(URLsForResourcesWithExtension:subdirectory:localization:), @selector(pm_ps_URLsForResourcesWithExtension:subdirectory:localization:) },
        { @selector(infoDictionary), @selector(pm_ps_infoDictionary) },
        { @selector(objectForInfoDictionaryKey:), @selector(pm_ps_objectForInfoDictionaryKey:) },
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
