//
//  PTEntitlements.m
//  PlayTools
//

#import "PTInternal.h"

static NSDictionary *pt_get_fallback_entitlements_dict(void) {
    static NSDictionary *s_fallback_entitlements = nil;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        const char *user_root = pt_get_host_user_root_cstr();
        if (user_root == NULL) {
            return;
        }
        char bid[256];
        bid[0] = '\0';
        NSString *mainBid = [[NSBundle mainBundle] bundleIdentifier];
        if (mainBid.length > 0) {
            strlcpy(bid, [mainBid UTF8String], sizeof(bid));
        } else {
            (void)pt_read_main_bundle_id_early(bid, sizeof(bid));
        }
        if (bid[0] == '\0') {
            return;
        }
        char ent_path[PATH_MAX];
        int n = snprintf(ent_path, sizeof(ent_path),
                         "%s/Library/Containers/app.makedie.MacOver/Entitlements/%s.plist",
                         user_root, bid);
        if (n <= 0 || (size_t)n >= sizeof(ent_path)) {
            return;
        }
        int fd = pt_orig_open_nocancel(ent_path, O_RDONLY);
        if (fd < 0) {
            return;
        }
        size_t len = 0;
        size_t map_size = 0;
        uint8_t *bytes = pt_read_fd_plist_bytes(fd, &len, &map_size);
        close(fd);
        if (bytes != NULL && len > 0) {
            NSData *data = [NSData dataWithBytes:bytes length:len];
            munmap(bytes, map_size);
            id obj = [NSPropertyListSerialization propertyListWithData:data
                                                               options:NSPropertyListImmutable
                                                                format:nil
                                                                 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                s_fallback_entitlements = (NSDictionary *)obj;
            }
        } else if (bytes != NULL) {
            munmap(bytes, map_size);
        }
    });
    return s_fallback_entitlements;
}

static BOOL pt_is_hidden_entitlement_key(NSString *key) {
    if (key == nil) {
        return NO;
    }
    if ([key isEqualToString:@"com.apple.security.application-groups"]) {
        return NO;
    }
    return ([key isEqualToString:@"get-task-allow"] ||
            [key isEqualToString:@"com.apple.private.tcc.allow"] ||
            [key hasPrefix:@"com.apple.security."]);
}

#define PT_CS_OPS_STATUS 0
#define PT_CS_OPS_ENTITLEMENTS_BLOB 7
#define PT_CS_OPS_DER_ENTITLEMENTS_BLOB 15
#define PT_CS_VALID 0x00000001U
#define PT_CS_ADHOC 0x00000002U
#define PT_CS_GET_TASK_ALLOW 0x00000004U
#define PT_ERR_SEC_CS_NO_SUCH_CODE ((OSStatus)-67068)

static CFTypeRef pt_SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error) {
    if (entitlement == NULL) {
        if (error != NULL) {
            *error = NULL;
        }
        return NULL;
    }
    NSString *key = (__bridge NSString *)entitlement;
    BOOL bypass = pt_is_bypass_enabled();
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(__builtin_return_address(0));
    if (bypass && key != nil && !is_sys && pt_is_hidden_entitlement_key(key)) {
        PT_DEBUG_TRACE("entitlements", "hid SecTask entitlement=%s", [key UTF8String] ?: "<nil>");
        if (error != NULL) {
            *error = NULL;
        }
        return NULL;
    }
    CFErrorRef localErr = NULL;
    CFTypeRef val = SecTaskCopyValueForEntitlement(task, entitlement, error != NULL ? &localErr : NULL);
    if (val == NULL && key != nil && !is_sys && (!bypass || !pt_is_hidden_entitlement_key(key))) {
        id fallback = pt_get_fallback_entitlements_dict()[key];
        if (fallback != nil) {
            if (localErr != NULL) {
                CFRelease(localErr);
                localErr = NULL;
            }
            if (error != NULL) {
                *error = NULL;
            }
            return CFBridgingRetain(fallback);
        }
    }
    if (error != NULL) {
        *error = localErr;
    } else if (localErr != NULL) {
        CFRelease(localErr);
    }
    return val;
}

static CFDictionaryRef pt_SecTaskCopyValuesForEntitlements(SecTaskRef task, CFArrayRef entitlements, CFErrorRef *error) {
    BOOL bypass = pt_is_bypass_enabled();
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(__builtin_return_address(0));
    CFErrorRef localErr = NULL;
    CFDictionaryRef orig = SecTaskCopyValuesForEntitlements(task, entitlements, error != NULL ? &localErr : NULL);
    if (!is_sys) {
        NSDictionary *dict = (__bridge NSDictionary *)orig;
        NSMutableDictionary *clean = nil;
        if (bypass && dict != nil) {
            for (NSString *key in dict) {
                if ([key isKindOfClass:[NSString class]] && pt_is_hidden_entitlement_key(key)) {
                    if (clean == nil) {
                        clean = [dict mutableCopy];
                    }
                    [clean removeObjectForKey:key];
                }
            }
        }
        if (entitlements != NULL) {
            NSDictionary *fb = pt_get_fallback_entitlements_dict();
            if (fb.count > 0) {
                for (id reqKey in (__bridge NSArray *)entitlements) {
                    if ([reqKey isKindOfClass:[NSString class]] &&
                        (!bypass || !pt_is_hidden_entitlement_key((NSString *)reqKey))) {
                        id curVal = (clean != nil) ? clean[reqKey] : dict[reqKey];
                        if (curVal == nil && fb[reqKey] != nil) {
                            if (clean == nil) {
                                clean = (dict != nil) ? [dict mutableCopy] : [NSMutableDictionary dictionary];
                            }
                            clean[reqKey] = fb[reqKey];
                        }
                    }
                }
            }
        }
        if (clean != nil) {
            if (orig != NULL) {
                CFRelease(orig);
            }
            if (localErr != NULL) {
                CFRelease(localErr);
                localErr = NULL;
            }
            if (error != NULL) {
                *error = NULL;
            }
            return (__bridge_retained CFDictionaryRef)[clean copy];
        }
    }
    if (error != NULL) {
        *error = localErr;
    } else if (localErr != NULL) {
        CFRelease(localErr);
    }
    return orig;
}

static uint32_t pt_SecTaskGetCodeSignStatus(SecTaskRef task) {
    uint32_t flags = SecTaskGetCodeSignStatus(task);
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        flags &= ~(PT_CS_ADHOC | PT_CS_GET_TASK_ALLOW);
        flags |= PT_CS_VALID;
    }
    return flags;
}

static CFStringRef pt_SecTaskCopySigningIdentifier(SecTaskRef task, CFErrorRef *error) {
    CFErrorRef localErr = NULL;
    CFStringRef ident = SecTaskCopySigningIdentifier(task, error != NULL ? &localErr : NULL);
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        BOOL bad = (ident == NULL);
        if (!bad &&
            ([(__bridge NSString *)ident rangeOfString:@"PlayCover" options:NSCaseInsensitiveSearch].location !=
                 NSNotFound ||
             [(__bridge NSString *)ident rangeOfString:@"MacOver" options:NSCaseInsensitiveSearch].location !=
                 NSNotFound ||
             [(__bridge NSString *)ident rangeOfString:@"app.makedie" options:NSCaseInsensitiveSearch].location !=
                 NSNotFound)) {
            bad = YES;
        }
        if (bad) {
            char bid[256];
            bid[0] = '\0';
            NSString *mainBid = [[NSBundle mainBundle] bundleIdentifier];
            if (mainBid.length > 0 &&
                [mainBid rangeOfString:@"PlayCover" options:NSCaseInsensitiveSearch].location == NSNotFound &&
                [mainBid rangeOfString:@"MacOver" options:NSCaseInsensitiveSearch].location == NSNotFound) {
                strlcpy(bid, [mainBid UTF8String], sizeof(bid));
            } else {
                (void)pt_read_main_bundle_id_early(bid, sizeof(bid));
            }
            if (bid[0] != '\0') {
                if (ident != NULL) {
                    CFRelease(ident);
                }
                if (localErr != NULL) {
                    CFRelease(localErr);
                    localErr = NULL;
                }
                if (error != NULL) {
                    *error = NULL;
                }
                return CFStringCreateWithCString(kCFAllocatorDefault, bid, kCFStringEncodingUTF8);
            }
        }
    }
    if (error != NULL) {
        *error = localErr;
    } else if (localErr != NULL) {
        CFRelease(localErr);
    }
    return ident;
}

static BOOL pt_static_code_is_hidden(SecStaticCodeRef staticCode, const void *caller, BOOL *out_in_app_bundle) {
    if (out_in_app_bundle != NULL) {
        *out_in_app_bundle = NO;
    }
    if (staticCode == NULL) {
        return NO;
    }
    CFURLRef codeURL = NULL;
    if (SecCodeCopyPath(staticCode, 0, &codeURL) != 0 || codeURL == NULL) {
        return NO;
    }
    UInt8 raw[PATH_MAX];
    BOOL hidden = NO;
    if (CFURLGetFileSystemRepresentation(codeURL, true, raw, sizeof(raw))) {
        const char *path = (const char *)raw;
        char vbuf[PATH_MAX];
        const char *virt = pt_virtualize_path_for_app(path, vbuf, sizeof(vbuf), YES);
        const char *check_path = (virt != NULL) ? virt : path;
        hidden = (pt_is_hidden_path(check_path, caller) || pt_is_hidden_dyld_image_name(check_path));
        if (out_in_app_bundle != NULL && !hidden) {
            pt_ensure_bundle_path_map();
            if (s_real_app_bundle_len > 0 &&
                strncmp(path, s_real_app_bundle_dir, s_real_app_bundle_len) == 0 &&
                (path[s_real_app_bundle_len] == '/' || path[s_real_app_bundle_len] == '\0')) {
                *out_in_app_bundle = YES;
            }
        }
    }
    CFRelease(codeURL);
    return hidden;
}

static BOOL pt_code_is_hidden(SecCodeRef code, const void *caller, BOOL *out_in_app_bundle) {
    if (code == NULL) {
        return NO;
    }
    SecStaticCodeRef sc = NULL;
    if (SecCodeCopyStaticCode(code, 0, &sc) != 0 || sc == NULL) {
        return NO;
    }
    BOOL hidden = pt_static_code_is_hidden(sc, caller, out_in_app_bundle);
    CFRelease(sc);
    return hidden;
}

static OSStatus pt_SecCodeCopySelf(SecCSFlags flags, SecCodeRef *self) {
    return SecCodeCopySelf(flags, self);
}

static OSStatus pt_SecCodeCopyStaticCode(SecCodeRef code, SecCSFlags flags, SecStaticCodeRef *staticCode) {
    return SecCodeCopyStaticCode(code, flags, staticCode);
}

static OSStatus pt_SecCodeCopyPath(SecStaticCodeRef staticCode, SecCSFlags flags, CFURLRef *path) {
    OSStatus st = SecCodeCopyPath(staticCode, flags, path);
    if (st == 0 && path != NULL && *path != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        *path = pt_sanitize_cfbundle_returned_url(*path, __builtin_return_address(0));
        if (*path == NULL) {
            return PT_ERR_SEC_CS_NO_SUCH_CODE;
        }
    }
    return st;
}

static OSStatus pt_SecCodeCopySigningInformation(SecStaticCodeRef code, SecCSFlags flags, CFDictionaryRef *information) {
    const void *caller = __builtin_return_address(0);
    BOOL app_caller = (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller));
    if (app_caller && pt_static_code_is_hidden(code, caller, NULL)) {
        if (information != NULL) {
            *information = NULL;
        }
        return PT_ERR_SEC_CS_NO_SUCH_CODE;
    }
    OSStatus st = SecCodeCopySigningInformation(code, flags, information);
    if (st == 0 && information != NULL && *information != NULL && app_caller) {
        NSDictionary *dict = (__bridge NSDictionary *)(*information);
        if ([dict isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *clean = [dict mutableCopy];
            id mainExec = clean[@"main-executable"];
            if (mainExec != nil && CFGetTypeID((__bridge CFTypeRef)mainExec) == CFURLGetTypeID()) {
                CFURLRef virtURL = pt_sanitize_cfbundle_returned_url(
                    (CFURLRef)CFRetain((__bridge CFTypeRef)mainExec), caller);
                if (virtURL != NULL) {
                    clean[@"main-executable"] = (__bridge_transfer NSURL *)virtURL;
                } else {
                    [clean removeObjectForKey:@"main-executable"];
                }
            }
            id infoPlist = clean[@"info-plist"];
            if ([infoPlist isKindOfClass:[NSDictionary class]] && pt_info_dict_needs_sanitize(infoPlist)) {
                NSDictionary *sanPlist = pt_build_sanitized_info_dict(infoPlist);
                if (sanPlist != nil) {
                    clean[@"info-plist"] = sanPlist;
                }
            }
            id entDict = clean[@"entitlements-dict"];
            if ([entDict isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *cleanEnt = nil;
                for (NSString *ek in (NSDictionary *)entDict) {
                    if ([ek isKindOfClass:[NSString class]] && pt_is_hidden_entitlement_key(ek)) {
                        if (cleanEnt == nil) {
                            cleanEnt = [(NSDictionary *)entDict mutableCopy];
                        }
                        [cleanEnt removeObjectForKey:ek];
                    }
                }
                if (cleanEnt != nil) {
                    clean[@"entitlements-dict"] = [cleanEnt copy];
                }
            }
            [clean removeObjectForKey:@"entitlements"];
            [clean removeObjectForKey:@"entitlements-DER"];
            [clean removeObjectForKey:@"changed-files"];
            id flagsObj = clean[@"flags"];
            if ([flagsObj isKindOfClass:[NSNumber class]]) {
                uint32_t f = [(NSNumber *)flagsObj unsignedIntValue];
                f &= ~(PT_CS_ADHOC | PT_CS_GET_TASK_ALLOW);
                clean[@"flags"] = @(f);
            }
            id statusObj = clean[@"status"];
            if ([statusObj isKindOfClass:[NSNumber class]]) {
                uint32_t s = [(NSNumber *)statusObj unsignedIntValue];
                s &= ~(PT_CS_ADHOC | PT_CS_GET_TASK_ALLOW);
                s |= PT_CS_VALID;
                clean[@"status"] = @(s);
            }
            id platObj = clean[@"platform-identifier"];
            if ([platObj isKindOfClass:[NSNumber class]] && [(NSNumber *)platObj intValue] > 0) {
                clean[@"platform-identifier"] = @(2);
            }
            id identObj = clean[@"identifier"];
            if ([identObj isKindOfClass:[NSString class]] &&
                ([(NSString *)identObj rangeOfString:@"PlayCover" options:NSCaseInsensitiveSearch].location !=
                     NSNotFound ||
                 [(NSString *)identObj rangeOfString:@"MacOver" options:NSCaseInsensitiveSearch].location !=
                     NSNotFound ||
                 [(NSString *)identObj rangeOfString:@"app.makedie" options:NSCaseInsensitiveSearch].location !=
                     NSNotFound)) {
                NSString *mainBid = [[NSBundle mainBundle] bundleIdentifier];
                if (mainBid.length > 0 &&
                    [mainBid rangeOfString:@"PlayCover" options:NSCaseInsensitiveSearch].location == NSNotFound &&
                    [mainBid rangeOfString:@"MacOver" options:NSCaseInsensitiveSearch].location == NSNotFound) {
                    clean[@"identifier"] = mainBid;
                }
            }
            CFRelease(*information);
            *information = (__bridge_retained CFDictionaryRef)[clean copy];
        }
    }
    return st;
}

static OSStatus pt_SecStaticCodeCreateWithPath(CFURLRef path, SecCSFlags flags, SecStaticCodeRef *staticCode) {
    const void *caller = __builtin_return_address(0);
    BOOL blocked = NO;
    CFURLRef resolvedURL = pt_resolve_cfbundle_input_url(path, caller, &blocked);
    if (blocked) {
        if (resolvedURL != NULL) {
            CFRelease(resolvedURL);
        }
        if (staticCode != NULL) {
            *staticCode = NULL;
        }
        return PT_ERR_SEC_CS_NO_SUCH_CODE;
    }
    OSStatus st = SecStaticCodeCreateWithPath(resolvedURL != NULL ? resolvedURL : path, flags, staticCode);
    if (resolvedURL != NULL) {
        CFRelease(resolvedURL);
    }
    return st;
}

static OSStatus pt_SecStaticCodeCreateWithPathAndAttributes(CFURLRef path,
                                                            SecCSFlags flags,
                                                            CFDictionaryRef attributes,
                                                            SecStaticCodeRef *staticCode) {
    const void *caller = __builtin_return_address(0);
    BOOL blocked = NO;
    CFURLRef resolvedURL = pt_resolve_cfbundle_input_url(path, caller, &blocked);
    if (blocked) {
        if (resolvedURL != NULL) {
            CFRelease(resolvedURL);
        }
        if (staticCode != NULL) {
            *staticCode = NULL;
        }
        return PT_ERR_SEC_CS_NO_SUCH_CODE;
    }
    OSStatus st = SecStaticCodeCreateWithPathAndAttributes(
        resolvedURL != NULL ? resolvedURL : path, flags, attributes, staticCode);
    if (resolvedURL != NULL) {
        CFRelease(resolvedURL);
    }
    return st;
}

static OSStatus pt_SecCodeCheckValidityWithErrors(SecCodeRef code,
                                                  SecCSFlags flags,
                                                  SecRequirementRef requirement,
                                                  CFErrorRef *errors) {
    const void *caller = __builtin_return_address(0);
    BOOL app_caller = (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller));
    BOOL in_app_bundle = NO;
    if (app_caller && pt_code_is_hidden(code, caller, &in_app_bundle)) {
        if (errors != NULL) {
            *errors = NULL;
        }
        return PT_ERR_SEC_CS_NO_SUCH_CODE;
    }
    CFErrorRef localErr = NULL;
    OSStatus st = SecCodeCheckValidityWithErrors(code, flags, requirement, errors != NULL ? &localErr : NULL);
    if (st != 0 && app_caller && in_app_bundle && requirement == NULL) {
        if (localErr != NULL) {
            CFRelease(localErr);
        }
        if (errors != NULL) {
            *errors = NULL;
        }
        return 0;
    }
    if (errors != NULL) {
        *errors = localErr;
    } else if (localErr != NULL) {
        CFRelease(localErr);
    }
    return st;
}

static OSStatus pt_SecCodeCheckValidity(SecCodeRef code, SecCSFlags flags, SecRequirementRef requirement) {
    return pt_SecCodeCheckValidityWithErrors(code, flags, requirement, NULL);
}

static OSStatus pt_SecStaticCodeCheckValidityWithErrors(SecStaticCodeRef staticCode,
                                                        SecCSFlags flags,
                                                        SecRequirementRef requirement,
                                                        CFErrorRef *errors) {
    const void *caller = __builtin_return_address(0);
    BOOL app_caller = (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller));
    BOOL in_app_bundle = NO;
    if (app_caller && pt_static_code_is_hidden(staticCode, caller, &in_app_bundle)) {
        if (errors != NULL) {
            *errors = NULL;
        }
        return PT_ERR_SEC_CS_NO_SUCH_CODE;
    }
    CFErrorRef localErr = NULL;
    OSStatus st = SecStaticCodeCheckValidityWithErrors(
        staticCode, flags, requirement, errors != NULL ? &localErr : NULL);
    if (st != 0 && app_caller && in_app_bundle && requirement == NULL) {
        if (localErr != NULL) {
            CFRelease(localErr);
        }
        if (errors != NULL) {
            *errors = NULL;
        }
        return 0;
    }
    if (errors != NULL) {
        *errors = localErr;
    } else if (localErr != NULL) {
        CFRelease(localErr);
    }
    return st;
}

static OSStatus pt_SecStaticCodeCheckValidity(SecStaticCodeRef staticCode,
                                              SecCSFlags flags,
                                              SecRequirementRef requirement) {
    return pt_SecStaticCodeCheckValidityWithErrors(staticCode, flags, requirement, NULL);
}

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
extern int csops_audittoken(pid_t pid, unsigned int ops, void *useraddr, size_t usersize, audit_token_t *token);

__attribute__((visibility("hidden")))
int pt_csops_with_caller(pid_t pid, unsigned int ops, void *useraddr, size_t usersize, const void *caller) {
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return csops(pid, ops, useraddr, usersize);
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller) &&
        (pid == 0 || pid == getpid())) {
        if (ops == PT_CS_OPS_ENTITLEMENTS_BLOB || ops == PT_CS_OPS_DER_ENTITLEMENTS_BLOB) {
            PT_DEBUG_TRACE("entitlements", "blocked csops blob query pid=%d ops=0x%x", pid, ops);
            errno = EINVAL;
            return -1;
        }
        int ret = csops(pid, ops, useraddr, usersize);
        if (ret == 0 && ops == PT_CS_OPS_STATUS && useraddr != NULL && usersize >= sizeof(uint32_t)) {
            uint32_t *flags = (uint32_t *)useraddr;
            *flags &= ~(PT_CS_ADHOC | PT_CS_GET_TASK_ALLOW);
            *flags |= PT_CS_VALID;
            PT_DEBUG_TRACE("entitlements", "spoofed csops status pid=%d flags=0x%x", pid, *flags);
        }
        return ret;
    }
    return csops(pid, ops, useraddr, usersize);
}

static int pt_csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize) {
    return pt_csops_with_caller(pid, ops, useraddr, usersize, __builtin_return_address(0));
}

static int pt_csops_audittoken(pid_t pid, unsigned int ops, void *useraddr, size_t usersize, audit_token_t *token) {
    const void *caller = __builtin_return_address(0);
    if (atomic_load_explicit(&s_libsystem_ready, memory_order_acquire) &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller) &&
        (pid == 0 || pid == getpid())) {
        return pt_csops_with_caller(pid, ops, useraddr, usersize, caller);
    }
    return csops_audittoken(pid, ops, useraddr, usersize, token);
}

extern int ptrace(int request, pid_t pid, caddr_t addr, int data);
#ifndef PT_DENY_ATTACH
#define PT_DENY_ATTACH 31
#endif
__attribute__((visibility("hidden")))
int pt_ptrace_with_caller(int request, pid_t pid, caddr_t addr, int data, const void *caller) {
    (void)caller;
    if (request == PT_DENY_ATTACH && pt_is_bypass_enabled()) {
        PT_DEBUG_TRACE("entitlements", "bypassed ptrace PT_DENY_ATTACH pid=%d", pid);
        return 0;
    }
    return ptrace(request, pid, addr, data);
}

static int pt_ptrace(int request, pid_t pid, caddr_t addr, int data) {
    return pt_ptrace_with_caller(request, pid, addr, data, __builtin_return_address(0));
}


// Interpose Apple Keychain functions (SecItemCopyMatching, SecItemAdd, SecItemUpdate, SecItemDelete)
// This allows us to intercept keychain requests and return our own data

static inline BOOL pt_is_playchain_enabled(void) {
    int cached = atomic_load_explicit(&s_playchain_cached, memory_order_acquire);
    if (cached >= 0) {
        return cached != 0;
    }
    BOOL v = NO;
    if (atomic_load_explicit(&s_pt_loaded, memory_order_acquire)) {
        v = [[PlaySettings shared] playChain];
        atomic_store_explicit(&s_playchain_cached, v ? 1 : 0, memory_order_release);
    }
    return v;
}

static inline BOOL pt_is_playchain_debug_enabled(void) {
    int cached = atomic_load_explicit(&s_playchain_debug_cached, memory_order_acquire);
    if (cached >= 0) {
        return cached != 0;
    }
    BOOL v = NO;
    if (atomic_load_explicit(&s_pt_loaded, memory_order_acquire)) {
        v = [[PlaySettings shared] playChainDebugging];
        atomic_store_explicit(&s_playchain_debug_cached, v ? 1 : 0, memory_order_release);
    }
    return v;
}

// Use the implementations from PlayKeychain
static OSStatus pt_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    OSStatus retval;
    if (result != NULL) {
        *result = NULL;
    }
    if (pt_is_playchain_enabled()) {
        if (query == NULL) {
            return errSecParam;
        }
        retval = [PlayKeychain copyMatching:(__bridge NSDictionary * _Nonnull)(query) result:result];
        if (retval == errSecItemNotFound) {
            CFTypeRef secClass = CFDictionaryGetValue(query, kSecClass);
            if ((secClass != NULL && CFEqual(secClass, kSecClassCertificate)) ||
                CFDictionaryContainsKey(query, kSecMatchPolicy) ||
                CFDictionaryContainsKey(query, kSecMatchTrustedOnly)) {
                if (result != NULL) {
                    *result = NULL;
                }
                retval = SecItemCopyMatching(query, result);
            }
        }
    } else {
        retval = SecItemCopyMatching(query, result);
    }
    if (result != NULL && retval == errSecSuccess && pt_is_playchain_debug_enabled()) {
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemCopyMatching: %@", query]];
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemCopyMatching result: %@", (result && *result) ? (__bridge id)(*result) : @"(null)"]];
    }
    return retval;
}

static OSStatus pt_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    OSStatus retval;
    if (result != NULL) {
        *result = NULL;
    }
    if (pt_is_playchain_enabled()) {
        if (attributes == NULL) {
            return errSecParam;
        }
        retval = [PlayKeychain add:(__bridge NSDictionary * _Nonnull)(attributes) result:result];
    } else {
        retval = SecItemAdd(attributes, result);
    }
    if (result != NULL && retval == errSecSuccess && pt_is_playchain_debug_enabled()) {
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemAdd: %@", attributes]];
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemAdd result: %@", (result && *result) ? (__bridge id)(*result) : @"(null)"]];
    }
    return retval;
}

static OSStatus pt_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    OSStatus retval;
    if (pt_is_playchain_enabled()) {
        if (query == NULL || attributesToUpdate == NULL) {
            return errSecParam;
        }
        retval = [PlayKeychain update:(__bridge NSDictionary * _Nonnull)(query) attributesToUpdate:(__bridge NSDictionary * _Nonnull)(attributesToUpdate)];
    } else {
        retval = SecItemUpdate(query, attributesToUpdate);
    }
    if (attributesToUpdate != NULL && pt_is_playchain_debug_enabled()) {
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemUpdate: %@", query]];
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemUpdate attributesToUpdate: %@", attributesToUpdate]];
    }
    return retval;
}

static OSStatus pt_SecItemDelete(CFDictionaryRef query) {
    OSStatus retval;
    if (pt_is_playchain_enabled()) {
        if (query == NULL) {
            return errSecParam;
        }
        retval = [PlayKeychain delete:(__bridge NSDictionary * _Nonnull)(query)];
    } else {
        retval = SecItemDelete(query);
    }
    if (pt_is_playchain_debug_enabled()) {
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemDelete: %@", query]];
    }
    return retval;
}

static SecKeyRef pt_SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    SecKeyRef result;
    if (error != NULL) {
        *error = NULL;
    }
    if (pt_is_playchain_enabled()) {
        if (parameters == NULL) {
            if (error != NULL) {
                *error = CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainOSStatus, errSecParam, NULL);
            }
            return NULL;
        }
        result = [PlayKeychain keyCreateRandomKey:(__bridge NSDictionary * _Nonnull)(parameters) error:error];
    } else {
        result = SecKeyCreateRandomKey(parameters, (void *)error);
    }
    if (pt_is_playchain_debug_enabled()) {
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecKeyCreateRandomKey: %@", parameters]];
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecKeyCreateRandomKey result: %@", result]];
    }
    return result;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
// Deprecated, but some apps might still use it.
static OSStatus pt_SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    OSStatus retval;
    if (pt_is_playchain_enabled()) {
        if (parameters == NULL) {
            return errSecParam;
        }
        retval = [PlayKeychain keyGeneratePair:(__bridge NSDictionary * _Nonnull)(parameters) publicKey:(void *)publicKey privateKey:(void *)privateKey];
    } else {
        retval = SecKeyGeneratePair(parameters, (void *)publicKey, (void *)privateKey);
    }
    if (pt_is_playchain_debug_enabled()) {
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecKeyGeneratePair: %@", parameters]];
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecKeyGeneratePair public key result: %@", (retval == errSecSuccess && publicKey != NULL) ? *publicKey : nil]];
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecKeyGeneratePair private key result: %@", (retval == errSecSuccess && privateKey != NULL) ? *privateKey : nil]];
    }
    return retval;
}

DYLD_INTERPOSE(pt_SecItemCopyMatching, SecItemCopyMatching)
DYLD_INTERPOSE(pt_SecItemAdd, SecItemAdd)
DYLD_INTERPOSE(pt_SecItemUpdate, SecItemUpdate)
DYLD_INTERPOSE(pt_SecItemDelete, SecItemDelete)
DYLD_INTERPOSE(pt_SecKeyCreateRandomKey, SecKeyCreateRandomKey)
DYLD_INTERPOSE(pt_SecKeyGeneratePair, SecKeyGeneratePair)
#pragma clang diagnostic pop


extern char *sandbox_extension_issue_file(const char *extension_class, const char *path, uint32_t flags);
extern char *sandbox_extension_issue_file_to_self(const char *extension_class, const char *path, uint32_t flags);
extern char *sandbox_extension_issue_file_to_process(const char *extension_class, const char *path, uint32_t flags, audit_token_t token);
extern char *sandbox_extension_issue_file_to_process_by_pid(const char *extension_class, const char *path, uint32_t flags, pid_t pid);

static char *pt_sandbox_extension_issue_file(const char *extension_class, const char *path, uint32_t flags) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EPERM)) {
        return NULL;
    }
    return sandbox_extension_issue_file(extension_class, path, flags);
}

static char *pt_sandbox_extension_issue_file_to_self(const char *extension_class, const char *path, uint32_t flags) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EPERM)) {
        return NULL;
    }
    return sandbox_extension_issue_file_to_self(extension_class, path, flags);
}

static char *pt_sandbox_extension_issue_file_to_process(const char *extension_class, const char *path, uint32_t flags, audit_token_t token) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EPERM)) {
        return NULL;
    }
    return sandbox_extension_issue_file_to_process(extension_class, path, flags, token);
}

static char *pt_sandbox_extension_issue_file_to_process_by_pid(const char *extension_class, const char *path, uint32_t flags, pid_t pid) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EPERM)) {
        return NULL;
    }
    return sandbox_extension_issue_file_to_process_by_pid(extension_class, path, flags, pid);
}

#ifndef SANDBOX_FILTER_NONE
#define PT_SANDBOX_FILTER_NONE 0
#else
#define PT_SANDBOX_FILTER_NONE SANDBOX_FILTER_NONE
#endif
#ifndef SANDBOX_FILTER_PATH
#define PT_SANDBOX_FILTER_PATH 1
#else
#define PT_SANDBOX_FILTER_PATH SANDBOX_FILTER_PATH
#endif
#ifndef SANDBOX_FILTER_DESCRIPTOR
#define PT_SANDBOX_FILTER_DESCRIPTOR 10
#else
#define PT_SANDBOX_FILTER_DESCRIPTOR SANDBOX_FILTER_DESCRIPTOR
#endif

static int pt_sandbox_check_impl(BOOL use_audit_token,
                                 pid_t pid,
                                 audit_token_t au,
                                 const char *operation,
                                 int type,
                                 va_list ap,
                                 const void *caller) {
    int filter = (type & 0x0f);
    BOOL bypass = pt_is_bypass_enabled();
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);

    if (!is_sys && bypass && !use_audit_token && pid != 0 && pid != getpid()) {
        errno = EPERM;
        return -1;
    }

    if (filter == PT_SANDBOX_FILTER_NONE) {
        int ret = use_audit_token ? sandbox_check_by_audit_token(au, operation, type)
                                  : sandbox_check(pid, operation, type);
        if (!is_sys && bypass && ret == 0 &&
            (operation == NULL || strncmp(operation, "process-fork", 12) == 0)) {
            return 1;
        }
        return ret;
    }

    if (filter == PT_SANDBOX_FILTER_PATH) {
        const char *path = va_arg(ap, const char *);
        char vbuf[PATH_MAX];
        const char *resolved = path;
        int is_sys_flag = is_sys ? 1 : 0;
        pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(
            path, caller, vbuf, sizeof(vbuf), &resolved, &is_sys_flag);
        if (!is_sys && bypass && (disp == PT_FS_PATH_HIDDEN || disp == PT_FS_PATH_VIRTUAL_ANCESTOR)) {
            return 1;
        }
        return use_audit_token ? sandbox_check_by_audit_token(au, operation, type, resolved)
                               : sandbox_check(pid, operation, type, resolved);
    }

    if (filter == PT_SANDBOX_FILTER_DESCRIPTOR) {
        int fd = va_arg(ap, int);
        if (!is_sys && pt_fd_is_sensitive(fd, caller)) {
            return 1;
        }
        return use_audit_token ? sandbox_check_by_audit_token(au, operation, type, fd)
                               : sandbox_check(pid, operation, type, fd);
    }

    uintptr_t arg1 = va_arg(ap, uintptr_t);
    if (!is_sys && bypass && arg1 != 0 &&
        (filter == 2 || filter == 3 || filter == 6 || filter == 9 || filter == 12)) {
        const char *sarg = (const char *)arg1;
        if (strcasestr(sarg, "playcover") != NULL ||
            strcasestr(sarg, "macover") != NULL ||
            strcasestr(sarg, "app.makedie") != NULL ||
            strcasestr(sarg, "playtools") != NULL ||
            strcasestr(sarg, "akinterface") != NULL) {
            return 1;
        }
    }
    return use_audit_token ? sandbox_check_by_audit_token(au, operation, type, arg1)
                           : sandbox_check(pid, operation, type, arg1);
}

static int pt_sandbox_check(pid_t pid, const char *operation, int type, ...) {
    audit_token_t zero_au = {0};
    va_list ap;
    va_start(ap, type);
    int ret = pt_sandbox_check_impl(NO, pid, zero_au, operation, type, ap, __builtin_return_address(0));
    va_end(ap);
    return ret;
}

static int pt_sandbox_check_by_audit_token(audit_token_t au, const char *operation, int type, ...) {
    va_list ap;
    va_start(ap, type);
    int ret = pt_sandbox_check_impl(YES, 0, au, operation, type, ap, __builtin_return_address(0));
    va_end(ap);
    return ret;
}


DYLD_INTERPOSE(pt_SecTaskCopyValueForEntitlement, SecTaskCopyValueForEntitlement)
DYLD_INTERPOSE(pt_SecTaskCopyValuesForEntitlements, SecTaskCopyValuesForEntitlements)
DYLD_INTERPOSE(pt_SecTaskGetCodeSignStatus, SecTaskGetCodeSignStatus)
DYLD_INTERPOSE(pt_SecTaskCopySigningIdentifier, SecTaskCopySigningIdentifier)
DYLD_INTERPOSE(pt_SecCodeCopySelf, SecCodeCopySelf)
DYLD_INTERPOSE(pt_SecCodeCopyStaticCode, SecCodeCopyStaticCode)
DYLD_INTERPOSE(pt_SecCodeCopyPath, SecCodeCopyPath)
DYLD_INTERPOSE(pt_SecCodeCopySigningInformation, SecCodeCopySigningInformation)
DYLD_INTERPOSE(pt_SecCodeCheckValidity, SecCodeCheckValidity)
DYLD_INTERPOSE(pt_SecCodeCheckValidityWithErrors, SecCodeCheckValidityWithErrors)
DYLD_INTERPOSE(pt_SecStaticCodeCreateWithPath, SecStaticCodeCreateWithPath)
DYLD_INTERPOSE(pt_SecStaticCodeCreateWithPathAndAttributes, SecStaticCodeCreateWithPathAndAttributes)
DYLD_INTERPOSE(pt_SecStaticCodeCheckValidity, SecStaticCodeCheckValidity)
DYLD_INTERPOSE(pt_SecStaticCodeCheckValidityWithErrors, SecStaticCodeCheckValidityWithErrors)
DYLD_INTERPOSE(pt_csops, csops)
DYLD_INTERPOSE(pt_csops_audittoken, csops_audittoken)
DYLD_INTERPOSE(pt_ptrace, ptrace)
DYLD_INTERPOSE(pt_sandbox_extension_issue_file, sandbox_extension_issue_file)
DYLD_INTERPOSE(pt_sandbox_extension_issue_file_to_self, sandbox_extension_issue_file_to_self)
DYLD_INTERPOSE(pt_sandbox_extension_issue_file_to_process, sandbox_extension_issue_file_to_process)
DYLD_INTERPOSE(pt_sandbox_extension_issue_file_to_process_by_pid, sandbox_extension_issue_file_to_process_by_pid)
DYLD_INTERPOSE(pt_sandbox_check, sandbox_check)
DYLD_INTERPOSE(pt_sandbox_check_by_audit_token, sandbox_check_by_audit_token)
