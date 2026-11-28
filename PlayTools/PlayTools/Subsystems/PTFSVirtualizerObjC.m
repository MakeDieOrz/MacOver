//
//  PTFSVirtualizerObjC.m
//  PlayTools
//

#import "PSInternal.h"
#import "PTEntitlementsInternal.h"
#include <sys/mman.h>

static inline BOOL ps_cstr_may_need_virtual_resolve(const char *raw) {
    if (raw == NULL || raw[0] != '/') {
        return NO;
    }
    return (strncmp(raw, "/var/", 5) == 0 ||
            strncmp(raw, "/private/var/", 13) == 0 ||
            strstr(raw, "/.") != NULL ||
            strstr(raw, "//") != NULL);
}

static inline BOOL ps_may_need_virtual_resolve(NSString *path) {
    if (path == nil || path.length < 4) {
        return NO;
    }
    unichar c0 = [path characterAtIndex:0];
    if (c0 != '/') {
        return NO;
    }
    return ([path hasPrefix:@"/var/"] ||
            [path hasPrefix:@"/private/var/"] ||
            [path hasPrefix:@"/System/Library/Frameworks/"] ||
            [path hasPrefix:@"/System/Library/PrivateFrameworks/"] ||
            [path containsString:@"/."] ||
            [path containsString:@"//"]);
}

__attribute__((visibility("hidden"))) NSString *ps_strip_iossupport_nsstring(NSString *p) {
    if (p != nil && [p hasPrefix:@"/System/iOSSupport"] &&
        (p.length == 18 || [p characterAtIndex:18] == '/')) {
        return (p.length == 18) ? @"/" : [p substringFromIndex:18];
    }
    return p;
}

static void ps_prepare_fm_path_mode(NSString *path,
                                    const void *caller,
                                    BOOL allowReadOnlyBackup,
                                    NSString * __autoreleasing *outResolved,
                                    BOOL *outIsHidden,
                                    BOOL *outIsAncestor,
                                    BOOL *outUsedBackup) {
    if (outUsedBackup) *outUsedBackup = NO;
    if (path == nil || path.length == 0) {
        if (outResolved) *outResolved = path;
        if (outIsHidden) *outIsHidden = NO;
        if (outIsAncestor) *outIsAncestor = NO;
        return;
    }
    char raw[PATH_MAX];
    if (!CFStringGetFileSystemRepresentation((__bridge CFStringRef)path, raw, sizeof(raw))) {
        const char *utf8 = [path UTF8String];
        if (outResolved) *outResolved = path;
        if (outIsHidden) *outIsHidden = (utf8 != NULL && pt_is_hidden_path(utf8, caller));
        if (outIsAncestor) *outIsAncestor = NO;
        return;
    }
    if (raw[0] != '/' || strstr(raw, "/..") != NULL) {
        char prepBuf[PATH_MAX];
        const char *prepOut = NULL;
        int isSys = -1;
        pt_fs_path_disposition_t disp = pt_prepare_fs_path_at_cached_caller(
            AT_FDCWD, raw, caller, prepBuf, sizeof(prepBuf), &prepOut, &isSys, allowReadOnlyBackup);
        if (disp == PT_FS_PATH_HIDDEN) {
            if (outResolved) *outResolved = path;
            if (outIsHidden) *outIsHidden = YES;
            if (outIsAncestor) *outIsAncestor = NO;
            return;
        }
        if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
            NSString *ancStr = path;
            if (prepOut != NULL && prepOut != raw) {
                CFStringRef cfAnc = CFStringCreateWithFileSystemRepresentation(kCFAllocatorDefault, prepOut);
                if (cfAnc != NULL) {
                    ancStr = (__bridge_transfer NSString *)cfAnc;
                }
            }
            if (outResolved) *outResolved = ancStr;
            if (outIsHidden) *outIsHidden = NO;
            if (outIsAncestor) *outIsAncestor = YES;
            return;
        }
        NSString *resStr = path;
        BOOL usedBk = NO;
        if (prepOut != NULL && prepOut != raw) {
            CFStringRef cfRes = CFStringCreateWithFileSystemRepresentation(kCFAllocatorDefault, prepOut);
            if (cfRes != NULL) {
                resStr = (__bridge_transfer NSString *)cfRes;
            }
            if (allowReadOnlyBackup &&
                (pt_is_active_app_backup_file_path(prepOut) || pt_is_synth_system_version_path(prepOut))) {
                usedBk = YES;
            }
        }
        if (outResolved) *outResolved = resStr;
        if (outIsHidden) *outIsHidden = NO;
        if (outIsAncestor) *outIsAncestor = NO;
        if (outUsedBackup) *outUsedBackup = usedBk;
        return;
    }
    char resolvedBuf[PATH_MAX];
    const char *active = raw;
    NSString *resolvedStr = path;
    if (ps_cstr_may_need_virtual_resolve(raw)) {
        const char *resolved = pt_resolve_virtual_path(raw, resolvedBuf, sizeof(resolvedBuf));
        if (resolved != NULL && resolved != raw) {
            active = resolved;
            CFStringRef cfStr = CFStringCreateWithFileSystemRepresentation(kCFAllocatorDefault, resolved);
            if (cfStr != NULL) {
                resolvedStr = (__bridge_transfer NSString *)cfStr;
            }
        }
    }
    if (allowReadOnlyBackup) {
        char backupBuf[PATH_MAX];
        int isSysCaller = -1;
        const char *backup = pt_lookup_app_backup_redirect_for_caller(
            active, caller, backupBuf, sizeof(backupBuf), &isSysCaller);
        if (backup != NULL) {
            CFStringRef cfBackup = CFStringCreateWithFileSystemRepresentation(kCFAllocatorDefault, backup);
            if (cfBackup != NULL) {
                if (outResolved) *outResolved = (__bridge_transfer NSString *)cfBackup;
                if (outIsHidden) *outIsHidden = NO;
                if (outIsAncestor) *outIsAncestor = NO;
                if (outUsedBackup) *outUsedBackup = YES;
                return;
            }
        }
    }
    BOOL hidden = pt_is_hidden_path(active, caller);
    if (!hidden && active != raw && !pt_is_reverse_mapped_iossupport(raw, active)) {
        hidden = pt_is_hidden_path(raw, caller);
    }
    BOOL ancestor = NO;
    if (!hidden && ps_cstr_may_need_virtual_resolve(active)) {
        ancestor = pt_is_virtual_container_ancestor_dir(active);
    }
    if (outResolved) *outResolved = resolvedStr;
    if (outIsHidden) *outIsHidden = hidden;
    if (outIsAncestor) *outIsAncestor = ancestor;
}

static void ps_prepare_fm_path(NSString *path,
                               const void *caller,
                               NSString * __autoreleasing *outResolved,
                               BOOL *outIsHidden,
                               BOOL *outIsAncestor) {
    ps_prepare_fm_path_mode(path, caller, NO, outResolved, outIsHidden, outIsAncestor, NULL);
}

__attribute__((visibility("hidden"))) BOOL ps_is_virtual_ancestor_nsstring(NSString *path) {
    if (!ps_may_need_virtual_resolve(path)) {
        return NO;
    }
    char raw[PATH_MAX];
    if (!CFStringGetFileSystemRepresentation((__bridge CFStringRef)path, raw, sizeof(raw))) {
        return NO;
    }
    return pt_is_virtual_container_ancestor_dir(raw);
}

__attribute__((visibility("hidden"))) NSString *ps_resolve_virtual_nsstring_path(NSString *path) {
    if (!ps_may_need_virtual_resolve(path)) {
        return path;
    }
    char raw[PATH_MAX];
    if (!CFStringGetFileSystemRepresentation((__bridge CFStringRef)path, raw, sizeof(raw))) {
        return path;
    }
    char buf[PATH_MAX];
    const char *resolved = pt_resolve_virtual_path(raw, buf, sizeof(buf));
    if (resolved != NULL && resolved != raw) {
        CFStringRef cfStr = CFStringCreateWithFileSystemRepresentation(kCFAllocatorDefault, resolved);
        if (cfStr != NULL) {
            return (__bridge_transfer NSString *)cfStr;
        }
    }
    return path;
}

__attribute__((visibility("hidden"))) BOOL ps_is_virtual_container_nsstring(NSString *path) {
    if (!ps_may_need_virtual_resolve(path)) {
        return NO;
    }
    char raw[PATH_MAX];
    if (!CFStringGetFileSystemRepresentation((__bridge CFStringRef)path, raw, sizeof(raw))) {
        return NO;
    }
    return pt_is_virtual_container_path(raw);
}

__attribute__((visibility("hidden"))) NSURL *ps_rebuild_file_nsurl(NSURL *origURL, NSString *newPath) {
    BOOL isDir = [origURL hasDirectoryPath];
    NSURL *baseFileURL = [NSURL fileURLWithPath:newPath isDirectory:isDir];
    if (baseFileURL == nil) {
        return origURL;
    }
    if (origURL.query == nil && origURL.fragment == nil) {
        return baseFileURL;
    }
    NSURLComponents *origComp = [NSURLComponents componentsWithURL:origURL resolvingAgainstBaseURL:YES];
    NSURLComponents *newComp = [NSURLComponents componentsWithURL:baseFileURL resolvingAgainstBaseURL:NO];
    if (origComp != nil && newComp != nil) {
        newComp.percentEncodedQuery = origComp.percentEncodedQuery;
        newComp.percentEncodedFragment = origComp.percentEncodedFragment;
        NSURL *rebuilt = newComp.URL;
        if (rebuilt != nil) {
            return rebuilt;
        }
    }
    return baseFileURL;
}

__attribute__((visibility("hidden"))) NSURL *ps_resolve_virtual_nsurl(NSURL *url) {
    if (url == nil || ![url isFileURL]) {
        return url;
    }
    NSString *origPath = url.path;
    NSString *resolvedPath = ps_resolve_virtual_nsstring_path(origPath);
    if (resolvedPath != nil && resolvedPath != origPath && ![resolvedPath isEqualToString:origPath]) {
        return ps_rebuild_file_nsurl(url, resolvedPath);
    }
    return url;
}

__attribute__((visibility("hidden"))) NSString *ps_virtualize_nsstring_path_for_app(NSString *path, BOOL usePrivatePrefix) {
    if (path == nil || path.length == 0) {
        return path;
    }
    char raw[PATH_MAX];
    if (!CFStringGetFileSystemRepresentation((__bridge CFStringRef)path, raw, sizeof(raw))) {
        return path;
    }
    char buf[PATH_MAX];
    const char *virt = pt_virtualize_path_for_app(raw, buf, sizeof(buf), usePrivatePrefix);
    if (virt != NULL && virt != raw) {
        CFStringRef cfStr = CFStringCreateWithFileSystemRepresentation(kCFAllocatorDefault, virt);
        if (cfStr != NULL) {
            return (__bridge_transfer NSString *)cfStr;
        }
    }
    return path;
}

__attribute__((visibility("hidden"))) NSURL *ps_virtualize_nsurl_for_app(NSURL *url, BOOL usePrivatePrefix) {
    if (url == nil || ![url isFileURL]) {
        return url;
    }
    NSString *origPath = url.path;
    NSString *virtPath = ps_virtualize_nsstring_path_for_app(origPath, usePrivatePrefix);
    if (virtPath != nil && virtPath != origPath && ![virtPath isEqualToString:origPath]) {
        return ps_rebuild_file_nsurl(url, virtPath);
    }
    return url;
}

__attribute__((visibility("hidden"))) BOOL ps_is_effective_system_or_playtools_caller(const void *ret_addr) {
    return pt_is_effective_system_or_playtools_caller(ret_addr);
}

static void ps_record_replaced_path_strings(NSMutableDictionary<NSString *, NSString *> * __strong *replacedStringsPtr,
                                            NSString *origStr,
                                            NSString *virtStr) {
    if (replacedStringsPtr == NULL || origStr.length == 0 || virtStr.length == 0 || [origStr isEqualToString:virtStr]) {
        return;
    }
    if (*replacedStringsPtr == nil) {
        *replacedStringsPtr = [NSMutableDictionary dictionary];
    }
    (*replacedStringsPtr)[origStr] = virtStr;
}

static NSString *ps_scrub_host_paths_in_text(NSString *s, BOOL usePrivatePrefix) {
    if (s.length < 7 || [s rangeOfString:@"/"].location == NSNotFound) {
        return s;
    }
    static NSString *s_hostRoot = nil;
    static NSRegularExpression *s_hostPathRe = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *hr = pt_get_host_user_root_cstr();
        if (hr != NULL && hr[0] == '/') {
            s_hostRoot = [NSString stringWithUTF8String:hr];
        }
        s_hostPathRe = [NSRegularExpression regularExpressionWithPattern:@"(?:/System/Volumes/Data)?(?:/Users/[^/\\s\"'”)>\\]]+(?:/[^\\s\"'”)>\\]]*)?|/Applications/(?:MacOver|PlayCover)\\.app(?:/[^\\s\"'”)>\\]]*)?|/Library/Frameworks/PlayTools\\.framework(?:/[^\\s\"'”)>\\]]*)?)"
                                                                 options:0
                                                                   error:nil];
    });
    BOOL maybeHost = ([s rangeOfString:@"/Users/"].location != NSNotFound ||
                      [s rangeOfString:@"/System/Volumes/Data/"].location != NSNotFound ||
                      [s rangeOfString:@"MacOver"].location != NSNotFound ||
                      [s rangeOfString:@"PlayCover"].location != NSNotFound ||
                      [s rangeOfString:@"PlayTools"].location != NSNotFound ||
                      (s_hostRoot.length > 0 && [s rangeOfString:s_hostRoot].location != NSNotFound));
    if (!maybeHost || s_hostPathRe == nil) {
        return s;
    }
    NSArray<NSTextCheckingResult *> *matches = [s_hostPathRe matchesInString:s options:0 range:NSMakeRange(0, s.length)];
    if (matches.count == 0) {
        if (s_hostRoot.length > 0 && [s rangeOfString:s_hostRoot].location != NSNotFound) {
            return [s stringByReplacingOccurrencesOfString:s_hostRoot withString:@"/var/mobile"];
        }
        return s;
    }
    NSMutableString *out = [s mutableCopy];
    for (NSInteger i = (NSInteger)matches.count - 1; i >= 0; i--) {
        NSRange mr = matches[(NSUInteger)i].range;
        NSString *tok = [s substringWithRange:mr];
        NSString *repl = ps_virtualize_nsstring_path_for_app(tok, usePrivatePrefix);
        if (repl == tok || [repl isEqualToString:tok]) {
            if (s_hostRoot.length > 0 && [tok hasPrefix:s_hostRoot]) {
                repl = [@"/var/mobile" stringByAppendingString:[tok substringFromIndex:s_hostRoot.length]];
            } else if ([tok hasPrefix:@"/System/Volumes/Data"]) {
                NSString *stripped = [tok substringFromIndex:20];
                NSString *vStripped = ps_virtualize_nsstring_path_for_app(stripped, usePrivatePrefix);
                if (vStripped != stripped && ![vStripped isEqualToString:stripped]) {
                    repl = vStripped;
                } else {
                    repl = @"/var/mobile";
                }
            } else {
                repl = @"/var/mobile";
            }
        }
        if (repl != nil && ![repl isEqualToString:tok]) {
            [out replaceCharactersInRange:mr withString:repl];
        }
    }
    return [out copy];
}

#define PS_NSERROR_MAX_DEPTH 6

typedef struct {
    const void *ancestors[PS_NSERROR_MAX_DEPTH + 4];
    int count;
} ps_nserror_visit_stack_t;

static inline BOOL ps_nserror_visit_contains(const ps_nserror_visit_stack_t *stack, const void *ptr) {
    if (stack == NULL || ptr == NULL) {
        return NO;
    }
    for (int i = 0; i < stack->count; i++) {
        if (stack->ancestors[i] == ptr) {
            return YES;
        }
    }
    return NO;
}

static inline ps_nserror_visit_stack_t ps_nserror_visit_push(const ps_nserror_visit_stack_t *stack, const void *ptr) {
    ps_nserror_visit_stack_t next = (stack != NULL) ? *stack : (ps_nserror_visit_stack_t){ .ancestors = {0}, .count = 0 };
    if (ptr != NULL && next.count < (int)(sizeof(next.ancestors) / sizeof(next.ancestors[0]))) {
        next.ancestors[next.count++] = ptr;
    }
    return next;
}

static NSError *ps_virtualize_nserror_recursive_inner(NSError *err,
                                                      BOOL usePrivatePrefix,
                                                      int depth,
                                                      const ps_nserror_visit_stack_t *visitStack);

static NSDictionary *ps_virtualize_nserror_dict(NSDictionary *ui,
                                                BOOL usePrivatePrefix,
                                                int depth,
                                                const ps_nserror_visit_stack_t *visitStack,
                                                NSMutableDictionary<NSString *, NSString *> * __strong *parentReplacedStringsPtr);

static NSError *ps_virtualize_nserror_recursive(NSError *err, BOOL usePrivatePrefix, int depth) {
    return ps_virtualize_nserror_recursive_inner(err, usePrivatePrefix, depth, NULL);
}

static id ps_virtualize_nserror_value(id val,
                                      BOOL usePrivatePrefix,
                                      int depth,
                                      const ps_nserror_visit_stack_t *visitStack,
                                      NSMutableDictionary<NSString *, NSString *> * __strong *replacedStringsPtr) {
    if (val == nil || depth > PS_NSERROR_MAX_DEPTH) {
        return val;
    }
    if ([val isKindOfClass:[NSURL class]]) {
        NSURL *u = (NSURL *)val;
        if ([u isFileURL]) {
            NSURL *vu = ps_virtualize_nsurl_for_app(u, usePrivatePrefix);
            if (vu != u && vu != nil && ![vu isEqual:u]) {
                ps_record_replaced_path_strings(replacedStringsPtr, u.path, vu.path);
                ps_record_replaced_path_strings(replacedStringsPtr, u.absoluteString, vu.absoluteString);
                return vu;
            }
        }
        return val;
    }
    if ([val isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)val;
        if ([s hasPrefix:@"/"]) {
            NSString *vs = ps_virtualize_nsstring_path_for_app(s, usePrivatePrefix);
            if (vs != s && vs != nil && ![vs isEqualToString:s]) {
                ps_record_replaced_path_strings(replacedStringsPtr, s, vs);
                return vs;
            }
        } else if ([s hasPrefix:@"file:///"]) {
            NSURL *u = [NSURL URLWithString:s];
            if (u != nil && [u isFileURL]) {
                NSURL *vu = ps_virtualize_nsurl_for_app(u, usePrivatePrefix);
                NSString *vAbs = vu.absoluteString;
                if (vu != u && vAbs.length > 0 && ![vAbs isEqualToString:s]) {
                    ps_record_replaced_path_strings(replacedStringsPtr, u.path, vu.path);
                    ps_record_replaced_path_strings(replacedStringsPtr, s, vAbs);
                    return vAbs;
                }
            }
        }
        return val;
    }
    const void *valPtr = (__bridge const void *)val;
    if ([val isKindOfClass:[NSError class]]) {
        if (ps_nserror_visit_contains(visitStack, valPtr)) {
            return val;
        }
        return ps_virtualize_nserror_recursive_inner((NSError *)val, usePrivatePrefix, depth + 1, visitStack);
    }
    if ([val isKindOfClass:[NSDictionary class]]) {
        if (depth >= PS_NSERROR_MAX_DEPTH || ps_nserror_visit_contains(visitStack, valPtr)) {
            return val;
        }
        ps_nserror_visit_stack_t nextStack = ps_nserror_visit_push(visitStack, valPtr);
        return ps_virtualize_nserror_dict((NSDictionary *)val, usePrivatePrefix, depth + 1, &nextStack, replacedStringsPtr);
    }
    if ([val isKindOfClass:[NSArray class]]) {
        if (depth >= PS_NSERROR_MAX_DEPTH || ps_nserror_visit_contains(visitStack, valPtr)) {
            return val;
        }
        ps_nserror_visit_stack_t nextStack = ps_nserror_visit_push(visitStack, valPtr);
        NSArray *arr = (NSArray *)val;
        NSMutableArray *mappedArr = nil;
        for (NSUInteger i = 0; i < arr.count; i++) {
            id elem = arr[i];
            id newElem = ps_virtualize_nserror_value(elem, usePrivatePrefix, depth + 1, &nextStack, replacedStringsPtr);
            if (newElem != elem && newElem != nil) {
                if (mappedArr == nil) {
                    mappedArr = [arr mutableCopy];
                }
                mappedArr[i] = newElem;
            }
        }
        return (mappedArr != nil) ? [mappedArr copy] : val;
    }
    if ([val isKindOfClass:[NSSet class]]) {
        if (depth >= PS_NSERROR_MAX_DEPTH || ps_nserror_visit_contains(visitStack, valPtr)) {
            return val;
        }
        ps_nserror_visit_stack_t nextStack = ps_nserror_visit_push(visitStack, valPtr);
        NSArray *items = [(NSSet *)val allObjects];
        NSMutableArray *mappedItems = nil;
        for (NSUInteger i = 0; i < items.count; i++) {
            id elem = items[i];
            id newElem = ps_virtualize_nserror_value(elem, usePrivatePrefix, depth + 1, &nextStack, replacedStringsPtr);
            if (newElem != elem && newElem != nil) {
                if (mappedItems == nil) {
                    mappedItems = [items mutableCopy];
                }
                mappedItems[i] = newElem;
            }
        }
        return (mappedItems != nil) ? [NSSet setWithArray:mappedItems] : val;
    }
    return val;
}

static NSDictionary *ps_virtualize_nserror_dict(NSDictionary *ui,
                                                BOOL usePrivatePrefix,
                                                int depth,
                                                const ps_nserror_visit_stack_t *visitStack,
                                                NSMutableDictionary<NSString *, NSString *> * __strong *parentReplacedStringsPtr) {
    if (ui == nil || ui.count == 0 || depth > PS_NSERROR_MAX_DEPTH) {
        return ui;
    }
    NSMutableDictionary *mappedUI = nil;
    NSMutableDictionary<NSString *, NSString *> *localReplaced = nil;
    for (id key in ui) {
        id val = ui[key];
        id newVal = ps_virtualize_nserror_value(val, usePrivatePrefix, depth, visitStack, &localReplaced);
        if (newVal != val && newVal != nil) {
            if (mappedUI == nil) {
                mappedUI = [ui mutableCopy];
            }
            mappedUI[key] = newVal;
        }
    }
    if (parentReplacedStringsPtr != NULL && localReplaced.count > 0) {
        if (*parentReplacedStringsPtr == nil) {
            *parentReplacedStringsPtr = [NSMutableDictionary dictionary];
        }
        [*parentReplacedStringsPtr addEntriesFromDictionary:localReplaced];
    }
    NSArray<NSString *> *sortedKeys = (localReplaced.count > 0)
        ? [[localReplaced allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            if (a.length > b.length) return NSOrderedAscending;
            if (a.length < b.length) return NSOrderedDescending;
            return NSOrderedSame;
        }]
        : nil;
    for (id key in ui) {
        if (mappedUI != nil && mappedUI[key] != ui[key]) {
            continue;
        }
        id val = ui[key];
        if ([val isKindOfClass:[NSString class]]) {
            NSString *s = (NSString *)val;
            if ([s rangeOfString:@"/"].location != NSNotFound) {
                NSString *updated = s;
                if (sortedKeys != nil) {
                    for (NSString *origSub in sortedKeys) {
                        if ([updated rangeOfString:origSub].location != NSNotFound) {
                            updated = [updated stringByReplacingOccurrencesOfString:origSub
                                                                         withString:localReplaced[origSub]];
                        }
                    }
                }
                updated = ps_scrub_host_paths_in_text(updated, usePrivatePrefix);
                if (updated != s && ![updated isEqualToString:s]) {
                    if (mappedUI == nil) {
                        mappedUI = [ui mutableCopy];
                    }
                    mappedUI[key] = updated;
                }
            }
        }
    }
    if (mappedUI == nil) {
        return ui;
    }
    return [mappedUI copy];
}

static NSError *ps_virtualize_nserror_recursive_inner(NSError *err,
                                                      BOOL usePrivatePrefix,
                                                      int depth,
                                                      const ps_nserror_visit_stack_t *visitStack) {
    if (err == nil || depth > PS_NSERROR_MAX_DEPTH || !pt_is_bypass_enabled()) {
        return err;
    }
    const void *errPtr = (__bridge const void *)err;
    if (ps_nserror_visit_contains(visitStack, errPtr)) {
        return err;
    }
    NSDictionary *ui = err.userInfo;
    if (ui == nil || ui.count == 0) {
        return err;
    }
    const void *uiPtr = (__bridge const void *)ui;
    if (ps_nserror_visit_contains(visitStack, uiPtr)) {
        return err;
    }
    ps_nserror_visit_stack_t nextStack = ps_nserror_visit_push(visitStack, errPtr);
    nextStack = ps_nserror_visit_push(&nextStack, uiPtr);
    NSDictionary *newUI = ps_virtualize_nserror_dict(ui, usePrivatePrefix, depth, &nextStack, NULL);
    if (newUI == ui || newUI == nil) {
        return err;
    }
    return [NSError errorWithDomain:err.domain code:err.code userInfo:newUI];
}

static inline void ps_assign_virtualized_nserror(NSError **outError,
                                                 NSError *rawError,
                                                 BOOL usePrivatePrefix,
                                                 BOOL forceVirtualize,
                                                 const void *caller) {
    if (outError == NULL) {
        return;
    }
    if (rawError != nil && pt_is_bypass_enabled() &&
        (forceVirtualize || !ps_is_effective_system_or_playtools_caller(caller))) {
        *outError = ps_virtualize_nserror_recursive(rawError, usePrivatePrefix, 0);
    } else {
        *outError = rawError;
    }
}

__attribute__((visibility("hidden"))) BOOL ps_is_hidden_path(NSString *path, const void *caller) {
    if (path == nil || path.length == 0) {
        return NO;
    }
    char raw[PATH_MAX];
    if (!CFStringGetFileSystemRepresentation((__bridge CFStringRef)path, raw, sizeof(raw))) {
        const char *utf8 = [path UTF8String];
        return (utf8 != NULL && pt_is_hidden_path(utf8, caller));
    }
    if (raw[0] != '/' || strstr(raw, "/..") != NULL) {
        char vbuf[PATH_MAX];
        const char *resolved = NULL;
        int isSys = -1;
        pt_fs_path_disposition_t disp = pt_prepare_fs_path_at_cached_caller(
            AT_FDCWD, raw, caller, vbuf, sizeof(vbuf), &resolved, &isSys, NO);
        return (disp == PT_FS_PATH_HIDDEN);
    }
    return pt_is_hidden_path(raw, caller);
}

static BOOL ps_is_sensitive_or_hidden_nsstring(NSString *path, const void *caller) {
    if (path == nil || path.length == 0) {
        return NO;
    }
    char raw[PATH_MAX];
    if (!CFStringGetFileSystemRepresentation((__bridge CFStringRef)path, raw, sizeof(raw))) {
        const char *utf8 = [path UTF8String];
        if (utf8 == NULL) {
            return NO;
        }
        return pt_is_hidden_path(utf8, caller) ||
               (utf8[0] == '/' && pt_is_sensitive_host_fd_path(utf8, caller)) ||
               pt_is_hidden_dyld_image_name(utf8);
    }
    if (raw[0] == '/') {
        if (pt_is_sensitive_host_fd_path(raw, caller) || pt_is_hidden_dyld_image_name(raw)) {
            return YES;
        }
        return pt_is_hidden_path(raw, caller);
    }
    return ps_is_hidden_path(path, caller);
}

static void ps_prepare_fm_url_for_modify(NSURL *url,
                                         const void *caller,
                                         NSURL * __autoreleasing *outResolvedURL,
                                         BOOL *outIsHidden,
                                         BOOL *outIsAncestor) {
    BOOL hidden = NO;
    BOOL ancestor = NO;
    NSURL *resolvedURL = url;
    if (url != nil && [url isFileURL]) {
        NSString *origPath = url.path;
        NSString *resolvedPath = origPath;
        ps_prepare_fm_path(origPath, caller, &resolvedPath, &hidden, &ancestor);
        if (!hidden && !ancestor) {
            if (resolvedPath != nil && resolvedPath != origPath && ![resolvedPath isEqualToString:origPath]) {
                resolvedURL = ps_rebuild_file_nsurl(url, resolvedPath);
            }
            NSString *finalPath = [resolvedURL isFileURL] ? resolvedURL.path : nil;
            if (ps_is_hidden_path(ps_strip_iossupport_nsstring(finalPath), caller)) {
                hidden = YES;
            } else if (ps_is_virtual_ancestor_nsstring(origPath) || ps_is_virtual_ancestor_nsstring(finalPath)) {
                ancestor = YES;
            }
        }
    }
    if (outResolvedURL) *outResolvedURL = resolvedURL;
    if (outIsHidden) *outIsHidden = hidden;
    if (outIsAncestor) *outIsAncestor = ancestor;
}

static NSString *ps_finalize_sanitized_nsstring_path(NSString *orig,
                                                     NSString *result,
                                                     BOOL isSysCaller,
                                                     const void *caller) {
    if (result == nil || isSysCaller || !pt_is_bypass_enabled()) {
        return result;
    }
    NSString *virt = ps_virtualize_nsstring_path_for_app(result, NO);
    if (virt != nil && ps_is_sensitive_or_hidden_nsstring(virt, caller)) {
        NSString *safeOrig = (orig != nil) ? ps_virtualize_nsstring_path_for_app(orig, NO) : nil;
        if (safeOrig != nil && !ps_is_sensitive_or_hidden_nsstring(safeOrig, caller)) {
            return safeOrig;
        }
        return ps_scrub_host_paths_in_text(safeOrig ?: virt, NO);
    }
    return virt;
}

static NSURL *ps_finalize_sanitized_nsurl(NSURL *origURL,
                                          NSURL *resultURL,
                                          BOOL isSysCaller,
                                          const void *caller) {
    if (resultURL == nil || ![resultURL isFileURL] || isSysCaller || !pt_is_bypass_enabled()) {
        return resultURL;
    }
    NSURL *virtURL = ps_virtualize_nsurl_for_app(resultURL, NO);
    NSString *vp = [virtURL isFileURL] ? virtURL.path : nil;
    if (vp.length > 0 && ps_is_sensitive_or_hidden_nsstring(vp, caller)) {
        NSURL *safeOrig = (origURL != nil) ? ps_virtualize_nsurl_for_app(origURL, NO) : nil;
        NSString *sp = [safeOrig isFileURL] ? safeOrig.path : nil;
        if (sp.length > 0 && !ps_is_sensitive_or_hidden_nsstring(sp, caller)) {
            return safeOrig;
        }
        NSString *scrubbed = ps_scrub_host_paths_in_text(sp ?: vp, NO);
        return ps_rebuild_file_nsurl(origURL ?: resultURL, scrubbed);
    }
    return virtURL;
}

__attribute__((visibility("hidden")))
@interface PSResolvedPreviewItem : NSObject
@property (nonatomic, strong) id target;
@property (nonatomic, strong) NSURL *resolvedURL;
@end

@implementation PSResolvedPreviewItem

- (NSURL *)previewItemURL {
    return _resolvedURL;
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector == @selector(previewItemURL)) {
        return YES;
    }
    return [_target respondsToSelector:aSelector] || [super respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    if ([_target respondsToSelector:aSelector]) {
        return _target;
    }
    return [super forwardingTargetForSelector:aSelector];
}

@end

static id ps_resolve_ql_preview_item(id item) {
    if (item == nil) {
        return nil;
    }
    if ([item isKindOfClass:[NSURL class]]) {
        return ps_resolve_virtual_nsurl((NSURL *)item);
    }
    SEL urlSel = @selector(previewItemURL);
    if ([item respondsToSelector:urlSel]) {
        NSURL *origURL = ((NSURL *(*)(id, SEL))objc_msgSend)(item, urlSel);
        if ([origURL isKindOfClass:[NSURL class]] && [origURL isFileURL]) {
            NSURL *resolved = ps_resolve_virtual_nsurl(origURL);
            if (resolved != nil && resolved != origURL && ![resolved isEqual:origURL]) {
                PSResolvedPreviewItem *wrapped = [[PSResolvedPreviewItem alloc] init];
                wrapped.target = item;
                wrapped.resolvedURL = resolved;
                return wrapped;
            }
        }
    }
    return item;
}

__attribute__((visibility("hidden"))) const char kPSQLProxyAssocKey = 0;

__attribute__((visibility("hidden")))
@interface PSQLDataSourceProxy : NSObject
@property (nonatomic, weak) id target;
@end

@implementation PSQLDataSourceProxy

- (NSInteger)numberOfPreviewItemsInPreviewController:(id)controller {
    id ds = self.target;
    SEL sel = @selector(numberOfPreviewItemsInPreviewController:);
    if (ds != nil && [ds respondsToSelector:sel]) {
        return ((NSInteger (*)(id, SEL, id))objc_msgSend)(ds, sel, controller);
    }
    return 0;
}

- (id)previewController:(id)controller previewItemAtIndex:(NSInteger)index {
    id ds = self.target;
    SEL sel = @selector(previewController:previewItemAtIndex:);
    if (ds != nil && [ds respondsToSelector:sel]) {
        id item = ((id (*)(id, SEL, id, NSInteger))objc_msgSend)(ds, sel, controller, index);
        return ps_resolve_ql_preview_item(item);
    }
    return nil;
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector == @selector(numberOfPreviewItemsInPreviewController:) ||
        aSelector == @selector(previewController:previewItemAtIndex:)) {
        return YES;
    }
    id ds = self.target;
    return (ds != nil && [ds respondsToSelector:aSelector]) || [super respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    id ds = self.target;
    if (ds != nil && [ds respondsToSelector:aSelector]) {
        return ds;
    }
    return [super forwardingTargetForSelector:aSelector];
}

@end


__attribute__((visibility("hidden"))) NSString *ps_normalize_virtual_ancestor_nsstring(NSString *path) {
    NSString *norm = ps_resolve_virtual_nsstring_path(path);
    if ([norm hasPrefix:@"/private/"]) {
        norm = [norm substringFromIndex:8];
    }
    while (norm.length > 1 && [norm hasSuffix:@"/"]) {
        norm = [norm substringToIndex:norm.length - 1];
    }
    return norm;
}

static NSURL *ps_sanitize_file_path_nsurl(NSURL *url,
                                          BOOL usePrivatePrefix,
                                          const void *caller,
                                          BOOL *outHidden) {
    if (outHidden != NULL) {
        *outHidden = NO;
    }
    if (url == nil || ![url isFileURL]) {
        return url;
    }
    NSURL *virt = ps_virtualize_nsurl_for_app(url, usePrivatePrefix);
    if (virt != nil && virt != url && ![virt isEqual:url]) {
        return virt;
    }
    NSString *resPath = [url path];
    if (resPath.length > 0) {
        if (ps_is_hidden_path(resPath, caller)) {
            if (outHidden != NULL) {
                *outHidden = YES;
            }
            return nil;
        }
        if (ps_is_virtual_ancestor_nsstring(resPath)) {
            return ps_rebuild_file_nsurl(url, ps_normalize_virtual_ancestor_nsstring(resPath));
        }
    }
    return url;
}

static CFURLRef ps_CFURLCreateFilePathURL(CFAllocatorRef allocator,
                                          CFURLRef url,
                                          CFErrorRef *error) CF_RETURNS_RETAINED {
    const void *caller = __builtin_return_address(0);
    CFURLRef result = CFURLCreateFilePathURL(allocator, url, error);
    if (result == NULL ||
        !pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(caller)) {
        return result;
    }
    NSURL *sanitized = nil;
    BOOL isHidden = NO;
    @autoreleasepool {
        NSURL *nsResult = (__bridge NSURL *)result;
        sanitized = ps_sanitize_file_path_nsurl(nsResult, NO, caller, &isHidden);
    }
    if (isHidden) {
        if (error != NULL) {
            *error = CFErrorCreate(allocator,
                                   (__bridge CFStringRef)NSCocoaErrorDomain,
                                   NSFileReadNoSuchFileError,
                                   NULL);
        }
        CFRelease(result);
        return NULL;
    }
    if (sanitized != nil && sanitized != (__bridge NSURL *)result) {
        CFRelease(result);
        return (__bridge_retained CFURLRef)sanitized;
    }
    return result;
}

PT_INTERPOSE(ps_CFURLCreateFilePathURL, CFURLCreateFilePathURL)

@interface PSSwizzleHooks (PlayShadowNSURLFilePath)
- (NSURL *) pm_filePathURL;
@end


@implementation PSSwizzleHooks (PlayShadowFS)

static inline BOOL ps_has_hidden_fs_substring(NSString *s) {
    if (s.length == 0) {
        return NO;
    }
    const char *baseC = [[s lastPathComponent] UTF8String];
    if (baseC != NULL && pt_is_hidden_runtime_artifact_name_cstr(baseC)) {
        return YES;
    }
    return ([s rangeOfString:@"PlayTools" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [s rangeOfString:@"Playtools.strings" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [s rangeOfString:@"AKInterface" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [s rangeOfString:@"UserPlugins" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [s rangeOfString:@".pt_sysver_" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [s rangeOfString:@".pt_coderes_" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [s rangeOfString:@".pt_info_" options:NSCaseInsensitiveSearch].location != NSNotFound);
}

static NSArray<NSString *> *ps_filter_dir_items(NSArray<NSString *> *items, NSString *baseDir, const void *caller) {
    if (items == nil || ps_is_effective_system_or_playtools_caller(caller)) {
        return items;
    }
    NSMutableArray<NSString *> *filtered = [NSMutableArray arrayWithCapacity:items.count];
    for (NSString *item in items) {
        if (ps_has_hidden_fs_substring(item)) {
            continue;
        }
        if (baseDir.length > 0) {
            NSString *childPath = [baseDir stringByAppendingPathComponent:item];
            if (ps_is_hidden_path(childPath, caller)) {
                continue;
            }
        }
        [filtered addObject:item];
    }
    return [filtered copy];
}

static inline BOOL ps_is_hidden_url_item(NSString *itemPath, const void *caller) {
    if (itemPath.length == 0) {
        return NO;
    }
    if (ps_has_hidden_fs_substring(itemPath)) {
        return YES;
    }
    return ps_is_hidden_path(itemPath, caller);
}

- (NSArray<NSString *> *) pm_contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    NSString *origPath = path;
    BOOL wasVirtual = (origPath != nil && ps_is_virtual_container_nsstring(origPath));
    BOOL usePrivatePrefix = (origPath != nil && [origPath hasPrefix:@"/private/"]);
    path = ps_resolve_virtual_nsstring_path(path);
    if (ps_is_hidden_path(path, caller) || ps_is_virtual_ancestor_nsstring(path)) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:ps_is_virtual_ancestor_nsstring(path) ? NSFileReadNoPermissionError : NSFileReadNoSuchFileError
                                     userInfo:nil];
        }
        return nil;
    }
    NSError *localErr = nil;
    NSArray<NSString *> *items = [self pm_contentsOfDirectoryAtPath:path error:(error != NULL ? &localErr : NULL)];
    if (items == nil) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    NSString *baseDir = (path.length > 0 && ![path hasPrefix:@"/"])
        ? [[self pm_currentDirectoryPath] stringByAppendingPathComponent:path]
        : path;
    return ps_filter_dir_items(items, baseDir, caller);
}

- (NSArray<NSString *> *) pm_subpathsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    NSString *origPath = path;
    BOOL wasVirtual = (origPath != nil && ps_is_virtual_container_nsstring(origPath));
    BOOL usePrivatePrefix = (origPath != nil && [origPath hasPrefix:@"/private/"]);
    path = ps_resolve_virtual_nsstring_path(path);
    if (ps_is_hidden_path(path, caller) || ps_is_virtual_ancestor_nsstring(path)) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:ps_is_virtual_ancestor_nsstring(path) ? NSFileReadNoPermissionError : NSFileReadNoSuchFileError
                                     userInfo:nil];
        }
        return nil;
    }
    NSError *localErr = nil;
    NSArray<NSString *> *items = [self pm_subpathsOfDirectoryAtPath:path error:(error != NULL ? &localErr : NULL)];
    if (items == nil) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    NSString *baseDir = (path.length > 0 && ![path hasPrefix:@"/"])
        ? [[self pm_currentDirectoryPath] stringByAppendingPathComponent:path]
        : path;
    return ps_filter_dir_items(items, baseDir, caller);
}

- (NSArray<NSString *> *) pm_subpathsAtPath:(NSString *)path {
    const void *caller = __builtin_return_address(0);
    path = ps_resolve_virtual_nsstring_path(path);
    if (ps_is_hidden_path(path, caller) || ps_is_virtual_ancestor_nsstring(path)) {
        return nil;
    }
    NSArray<NSString *> *items = [self pm_subpathsAtPath:path];
    NSString *baseDir = (path.length > 0 && ![path hasPrefix:@"/"])
        ? [[self pm_currentDirectoryPath] stringByAppendingPathComponent:path]
        : path;
    return ps_filter_dir_items(items, baseDir, caller);
}

static const uint8_t kPSEnumVirtualModeKey = 0;
static const uint8_t kPSEnumBasePathKey = 0;

- (NSArray<NSURL *> *) pm_contentsOfDirectoryAtURL:(NSURL *)url includingPropertiesForKeys:(NSArray<NSURLResourceKey> *)keys options:(NSDirectoryEnumerationOptions)mask error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    NSString *origPath = [url isFileURL] ? url.path : nil;
    BOOL wasVirtual = (origPath != nil && ps_is_virtual_container_nsstring(origPath));
    BOOL usePrivatePrefix = (origPath != nil && [origPath hasPrefix:@"/private/"]);
    NSURL *resolvedURL = ps_resolve_virtual_nsurl(url);
    if ([resolvedURL isFileURL] &&
        (ps_is_hidden_path(resolvedURL.path, caller) || ps_is_virtual_ancestor_nsstring(resolvedURL.path))) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:ps_is_virtual_ancestor_nsstring(resolvedURL.path) ? NSFileReadNoPermissionError : NSFileReadNoSuchFileError
                                     userInfo:nil];
        }
        return nil;
    }
    NSError *localErr = nil;
    NSArray<NSURL *> *items = [self pm_contentsOfDirectoryAtURL:resolvedURL
                                    includingPropertiesForKeys:keys
                                                       options:mask
                                                         error:(error != NULL ? &localErr : NULL)];
    if (items == nil) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    BOOL isAppCaller = !ps_is_effective_system_or_playtools_caller(caller);
    if (items != nil && (isAppCaller || wasVirtual)) {
        NSMutableArray<NSURL *> *filtered = [NSMutableArray arrayWithCapacity:items.count];
        for (NSURL *item in items) {
            NSString *itemPath = item.path ?: @"";
            if (isAppCaller && ps_is_hidden_url_item(itemPath, caller)) {
                continue;
            }
            [filtered addObject:wasVirtual ? ps_virtualize_nsurl_for_app(item, usePrivatePrefix) : item];
        }
        return [filtered copy];
    }
    return items;
}

- (NSDirectoryEnumerator<NSString *> *) pm_enumeratorAtPath:(NSString *)path {
    const void *caller = __builtin_return_address(0);
    path = ps_resolve_virtual_nsstring_path(path);
    if (ps_is_hidden_path(path, caller) || ps_is_virtual_ancestor_nsstring(path)) {
        return nil;
    }
    NSDirectoryEnumerator<NSString *> *enumerator = [self pm_enumeratorAtPath:path];
    if (enumerator != nil && path.length > 0) {
        NSString *baseDir = ![path hasPrefix:@"/"]
            ? [[self pm_currentDirectoryPath] stringByAppendingPathComponent:path]
            : path;
        if (baseDir.length > 0) {
            objc_setAssociatedObject(enumerator, &kPSEnumBasePathKey, baseDir, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
    }
    return enumerator;
}

- (id) pm_ps_allDescendantNextObject {
    const void *caller = __builtin_return_address(0);
    BOOL isAppCaller = !ps_is_effective_system_or_playtools_caller(caller);
    NSString *baseDir = isAppCaller ? objc_getAssociatedObject(self, &kPSEnumBasePathKey) : nil;
    while (YES) {
        id obj = [self pm_ps_allDescendantNextObject];
        if (obj == nil || ![obj isKindOfClass:[NSString class]]) {
            return obj;
        }
        if (isAppCaller) {
            NSString *rel = (NSString *)obj;
            if (ps_has_hidden_fs_substring(rel)) {
                continue;
            }
            if (baseDir.length > 0) {
                NSString *fullPath = [baseDir stringByAppendingPathComponent:rel];
                if (ps_is_hidden_path(fullPath, caller)) {
                    continue;
                }
            }
        }
        return obj;
    }
}

- (NSDirectoryEnumerator<NSURL *> *) pm_enumeratorAtURL:(NSURL *)url
                             includingPropertiesForKeys:(NSArray<NSURLResourceKey> *)keys
                                                options:(NSDirectoryEnumerationOptions)mask
                                           errorHandler:(BOOL (^)(NSURL *url, NSError *error))handler {
    const void *caller = __builtin_return_address(0);
    NSString *origPath = [url isFileURL] ? url.path : nil;
    BOOL wasVirtual = (origPath != nil && ps_is_virtual_container_nsstring(origPath));
    BOOL usePrivatePrefix = (origPath != nil && [origPath hasPrefix:@"/private/"]);
    NSURL *resolvedURL = ps_resolve_virtual_nsurl(url);
    if ([resolvedURL isFileURL] &&
        (ps_is_hidden_path(resolvedURL.path, caller) || ps_is_virtual_ancestor_nsstring(resolvedURL.path))) {
        return nil;
    }
    BOOL (^wrappedHandler)(NSURL *, NSError *) = handler;
    if (handler != nil && pt_is_bypass_enabled() &&
        (wasVirtual || !ps_is_effective_system_or_playtools_caller(caller))) {
        BOOL (^origHandler)(NSURL *, NSError *) = [handler copy];
        wrappedHandler = ^BOOL(NSURL *errURL, NSError *err) {
            if ([errURL isFileURL] && ps_is_hidden_url_item(errURL.path ?: @"", NULL)) {
                return YES;
            }
            NSURL *virtURL = [errURL isFileURL] ? ps_virtualize_nsurl_for_app(errURL, usePrivatePrefix) : errURL;
            NSError *virtErr = ps_virtualize_nserror_recursive(err, usePrivatePrefix, 0);
            return origHandler(virtURL, virtErr);
        };
    }
    NSDirectoryEnumerator<NSURL *> *enumerator = [self pm_enumeratorAtURL:resolvedURL
                                               includingPropertiesForKeys:keys
                                                                  options:mask
                                                             errorHandler:wrappedHandler];
    if (enumerator != nil && wasVirtual) {
        objc_setAssociatedObject(enumerator, &kPSEnumVirtualModeKey, @(usePrivatePrefix ? 2 : 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return enumerator;
}

- (id) pm_urlDirEnumeratorNextObject {
    const void *caller = __builtin_return_address(0);
    BOOL isAppCaller = !ps_is_effective_system_or_playtools_caller(caller);
    NSNumber *modeNum = objc_getAssociatedObject(self, &kPSEnumVirtualModeKey);
    while (YES) {
        id obj = [self pm_urlDirEnumeratorNextObject];
        if (obj == nil || ![obj isKindOfClass:[NSURL class]]) {
            return obj;
        }
        NSURL *item = (NSURL *)obj;
        if (isAppCaller && [item isFileURL]) {
            NSString *itemPath = item.path ?: @"";
            if (ps_is_hidden_url_item(itemPath, caller)) {
                continue;
            }
        }
        if (modeNum != nil) {
            return ps_virtualize_nsurl_for_app(item, modeNum.intValue == 2);
        }
        return item;
    }
}

static BOOL ps_is_safe_declared_app_group_id(NSString *rawGroupID) {
    if (![rawGroupID isKindOfClass:[NSString class]] || rawGroupID.length == 0 || rawGroupID.length > 128) {
        return NO;
    }
    NSString *trimmed = [rawGroupID stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![trimmed isEqualToString:rawGroupID] ||
        [rawGroupID hasPrefix:@"."] ||
        [rawGroupID containsString:@".."]) {
        return NO;
    }
    for (NSUInteger i = 0; i < rawGroupID.length; i++) {
        unichar ch = [rawGroupID characterAtIndex:i];
        BOOL ok = ((ch >= '0' && ch <= '9') ||
                   (ch >= 'A' && ch <= 'Z') ||
                   (ch >= 'a' && ch <= 'z') ||
                   ch == '.' || ch == '-' || ch == '_');
        if (!ok) {
            return NO;
        }
    }
    NSString *lower = [rawGroupID lowercaseString];
    if ([lower isEqualToString:@"app.makedie"] ||
        [lower isEqualToString:@"io.playcover"] ||
        [lower isEqualToString:@"com.apple"] ||
        [lower isEqualToString:@".globalpreferences"] ||
        [lower hasPrefix:@"app.makedie."] ||
        [lower hasPrefix:@"io.playcover."] ||
        [lower hasPrefix:@"com.apple."] ||
        [lower hasPrefix:@"group.app.makedie."] ||
        [lower hasPrefix:@"group.io.playcover."] ||
        [lower hasPrefix:@"group.com.apple."]) {
        return NO;
    }
    return YES;
}

static BOOL ps_is_valid_guest_bundle_id_for_app_groups(NSString *bid) {
    if (![bid isKindOfClass:[NSString class]] || bid.length == 0 || bid.length > 255) {
        return NO;
    }
    if ([bid hasPrefix:@"."] || [bid containsString:@".."]) {
        return NO;
    }
    for (NSUInteger i = 0; i < bid.length; i++) {
        unichar ch = [bid characterAtIndex:i];
        BOOL ok = ((ch >= '0' && ch <= '9') ||
                   (ch >= 'A' && ch <= 'Z') ||
                   (ch >= 'a' && ch <= 'z') ||
                   ch == '.' || ch == '-' || ch == '_');
        if (!ok) {
            return NO;
        }
    }
    NSString *lower = [bid lowercaseString];
    if ([lower isEqualToString:@"app.makedie"] ||
        [lower hasPrefix:@"app.makedie."] ||
        [lower isEqualToString:@"io.playcover"] ||
        [lower hasPrefix:@"io.playcover."] ||
        [lower isEqualToString:@"com.apple"] ||
        [lower hasPrefix:@"com.apple."]) {
        return NO;
    }
    return YES;
}

static NSString *ps_resolve_guest_bundle_id_for_app_groups(void) {
    char bid[256];
    bid[0] = '\0';
    if (pt_read_main_bundle_id_early(bid, sizeof(bid)) && bid[0] != '\0') {
        NSString *early = [NSString stringWithUTF8String:bid];
        if (ps_is_valid_guest_bundle_id_for_app_groups(early)) {
            return early;
        }
    }
    NSString *mainBid = [[NSBundle mainBundle] bundleIdentifier];
    if (ps_is_valid_guest_bundle_id_for_app_groups(mainBid)) {
        return mainBid;
    }
    return nil;
}

static void ps_add_declared_groups_from_value(NSMutableSet<NSString *> *dest, id rawValue) {
    if ([rawValue isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)rawValue) {
            if ([item isKindOfClass:[NSString class]] && ps_is_safe_declared_app_group_id((NSString *)item)) {
                [dest addObject:(NSString *)item];
            }
        }
    } else if ([rawValue isKindOfClass:[NSString class]] && ps_is_safe_declared_app_group_id((NSString *)rawValue)) {
        [dest addObject:(NSString *)rawValue];
    }
}

static NSSet<NSString *> *ps_declared_application_groups(void) {
    static NSSet<NSString *> *s_declared = nil;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        NSMutableSet<NSString *> *groups = [NSMutableSet set];
        pt_enter_internal_scope();
        const char *userRoot = pt_get_host_user_root_cstr();
        NSString *bid = ps_resolve_guest_bundle_id_for_app_groups();
        const char *bidC = [bid UTF8String];
        if (userRoot != NULL && userRoot[0] == '/' && bidC != NULL && bidC[0] != '\0') {
            char entPath[PATH_MAX];
            int n = snprintf(entPath, sizeof(entPath),
                             "%s/Library/Containers/app.makedie.MacOver/Entitlements/%s.plist",
                             userRoot, bidC);
            if (n > 0 && (size_t)n < sizeof(entPath)) {
                int fd = pt_orig_open_nocancel(entPath, O_RDONLY);
                if (fd >= 0) {
                    size_t len = 0;
                    size_t mapSize = 0;
                    uint8_t *bytes = pt_read_fd_plist_bytes(fd, &len, &mapSize);
                    close(fd);
                    if (bytes != NULL && len > 0) {
                        NSData *data = [NSData dataWithBytes:bytes length:len];
                        munmap(bytes, mapSize);
                        id plist = [NSPropertyListSerialization propertyListWithData:data
                                                                             options:NSPropertyListImmutable
                                                                              format:nil
                                                                               error:nil];
                        if ([plist isKindOfClass:[NSDictionary class]]) {
                            ps_add_declared_groups_from_value(
                                groups, ((NSDictionary *)plist)[@"com.apple.security.application-groups"]);
                        }
                    } else if (bytes != NULL) {
                        munmap(bytes, mapSize);
                    }
                }
            }
        }
        SecTaskRef selfTask = SecTaskCreateFromSelf(kCFAllocatorDefault);
        if (selfTask != NULL) {
            CFTypeRef liveGroups = SecTaskCopyValueForEntitlement(
                selfTask, CFSTR("com.apple.security.application-groups"), NULL);
            if (liveGroups != NULL) {
                ps_add_declared_groups_from_value(groups, (__bridge id)liveGroups);
                CFRelease(liveGroups);
            }
            CFRelease(selfTask);
        }
        pt_leave_internal_scope();
        s_declared = [groups copy];
    });
    return s_declared ?: [NSSet set];
}

- (NSURL *) pm_ps_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    const void *caller = __builtin_return_address(0);
    BOOL isSys = ps_is_effective_system_or_playtools_caller(caller);
    if (!ps_is_safe_declared_app_group_id(groupIdentifier)) {
        return isSys ? [self pm_ps_containerURLForSecurityApplicationGroupIdentifier:groupIdentifier] : nil;
    }
    NSSet<NSString *> *declared = ps_declared_application_groups();
    if (![declared containsObject:groupIdentifier]) {
        return isSys ? [self pm_ps_containerURLForSecurityApplicationGroupIdentifier:groupIdentifier] : nil;
    }

    pt_ensure_data_container_map();
    char baseRoot[PATH_MAX];
    baseRoot[0] = '\0';
    if (s_real_group_containers_root_len > 0 &&
        s_real_group_containers_root_len < sizeof(baseRoot)) {
        memcpy(baseRoot, s_real_group_containers_root, s_real_group_containers_root_len + 1U);
    } else {
        const char *userRoot = pt_get_host_user_root_cstr();
        NSString *bid = ps_resolve_guest_bundle_id_for_app_groups();
        const char *bidC = [bid UTF8String];
        if (userRoot == NULL || userRoot[0] != '/' || bidC == NULL || bidC[0] == '\0') {
            return nil;
        }
        int rn = snprintf(baseRoot, sizeof(baseRoot),
                          "%s/Library/Containers/app.makedie.MacOver/AppGroups/%s",
                          userRoot, bidC);
        if (rn <= 0 || (size_t)rn >= sizeof(baseRoot)) {
            return nil;
        }
    }

    const char *groupC = [groupIdentifier UTF8String];
    if (groupC == NULL || groupC[0] == '\0') {
        return nil;
    }
    char raw[PATH_MAX];
    int gn = snprintf(raw, sizeof(raw), "%s/%s", baseRoot, groupC);
    if (gn <= 0 || (size_t)gn >= sizeof(raw)) {
        return nil;
    }

    CFStringRef cfReal = CFStringCreateWithFileSystemRepresentation(kCFAllocatorDefault, raw);
    if (cfReal == NULL) {
        return nil;
    }
    NSString *realStr = (__bridge_transfer NSString *)cfReal;

    BOOL dirReady = NO;
    pt_enter_internal_scope();
    struct stat st;
    if (lstat(raw, &st) == 0) {
        dirReady = S_ISDIR(st.st_mode) ? YES : NO;
    } else {
        if (mkdir(raw, 0700) == 0 || errno == EEXIST) {
            if (lstat(raw, &st) == 0 && S_ISDIR(st.st_mode)) {
                dirReady = YES;
            }
        } else if (errno == ENOENT) {
            (void)[self pm_createDirectoryAtPath:realStr
                     withIntermediateDirectories:YES
                                      attributes:@{ NSFilePosixPermissions: @(0700) }
                                           error:nil];
            if (lstat(raw, &st) == 0 && S_ISDIR(st.st_mode)) {
                dirReady = YES;
            }
        }
    }
    pt_leave_internal_scope();
    if (!dirReady) {
        return nil;
    }

    char virtBuf[PATH_MAX];
    const char *virt = pt_register_and_virtualize_group_container(raw, virtBuf, sizeof(virtBuf), YES);
    if (pt_is_bypass_enabled() &&
        !isSys &&
        virt != NULL &&
        virt != raw) {
        CFStringRef cfVirt = CFStringCreateWithFileSystemRepresentation(kCFAllocatorDefault, virt);
        if (cfVirt != NULL) {
            NSString *virtStr = (__bridge_transfer NSString *)cfVirt;
            return [NSURL fileURLWithPath:virtStr isDirectory:YES];
        }
    }
    return [NSURL fileURLWithPath:realStr isDirectory:YES];
}


__attribute__((visibility("hidden"))) NSString *ps_normalize_virtual_ancestor_nsstring(NSString *path);

static NSString *ps_file_protection_for_dpclass(int dpclass) {
    switch (dpclass) {
        case 1:
            return NSFileProtectionComplete;
        case 2:
            return NSFileProtectionCompleteUnlessOpen;
        case 4:
            return NSFileProtectionNone;
        case 3:
        default:
            return NSFileProtectionCompleteUntilFirstUserAuthentication;
    }
}

static int ps_dpclass_from_file_protection(id val) {
    if (![val isKindOfClass:[NSString class]]) {
        return 0;
    }
    NSString *s = (NSString *)val;
    if ([s isEqualToString:NSFileProtectionComplete] ||
        [s isEqualToString:NSURLFileProtectionComplete]) {
        return 1;
    }
    if ([s isEqualToString:NSFileProtectionCompleteUnlessOpen] ||
        [s isEqualToString:NSURLFileProtectionCompleteUnlessOpen]) {
        return 2;
    }
    if ([s isEqualToString:NSFileProtectionCompleteUntilFirstUserAuthentication] ||
        [s isEqualToString:NSURLFileProtectionCompleteUntilFirstUserAuthentication]) {
        return 3;
    }
    if ([s isEqualToString:NSFileProtectionNone] ||
        [s isEqualToString:NSURLFileProtectionNone]) {
        return 4;
    }
    return 0;
}

static NSString *ps_synthesized_file_protection_for_path(NSString *path, BOOL isDirectory) {
    if (!isDirectory && path.length > 0) {
        char raw[PATH_MAX];
        struct stat st;
        if (CFStringGetFileSystemRepresentation((__bridge CFStringRef)path, raw, sizeof(raw)) &&
            stat(raw, &st) == 0) {
            int dp = pt_lookup_stat_dpclass(st.st_dev, st.st_ino);
            if (dp > 0) {
                return ps_file_protection_for_dpclass(dp);
            }
        }
    }
    return NSURLFileProtectionCompleteUntilFirstUserAuthentication;
}

static NSURL *ps_resolve_readonly_nsurl_and_backup(NSURL *origURL,
                                                   const void *caller,
                                                   BOOL *outWasVirtual,
                                                   BOOL *outUsePrivatePrefix,
                                                   BOOL *outUsedBackup) {
    if (outWasVirtual) *outWasVirtual = NO;
    if (outUsePrivatePrefix) *outUsePrivatePrefix = NO;
    if (outUsedBackup) *outUsedBackup = NO;
    if (origURL == nil || ![origURL isFileURL]) {
        return origURL;
    }
    NSString *origPath = [origURL path];
    if (origPath.length > 0) {
        if (outWasVirtual) *outWasVirtual = ps_is_virtual_container_nsstring(origPath);
        if (outUsePrivatePrefix) *outUsePrivatePrefix = [origPath hasPrefix:@"/private/"];
    }
    NSURL *resolvedURL = ps_resolve_virtual_nsurl(origURL);
    NSString *resolvedPath = [resolvedURL isFileURL] ? [resolvedURL path] : nil;
    if (resolvedPath.length > 0 &&
        !ps_is_hidden_path(resolvedPath, caller) &&
        !ps_is_virtual_ancestor_nsstring(resolvedPath)) {
        char raw[PATH_MAX];
        if (CFStringGetFileSystemRepresentation((__bridge CFStringRef)resolvedPath, raw, sizeof(raw))) {
            char backupBuf[PATH_MAX];
            int isSysCaller = -1;
            const char *backup = pt_lookup_app_backup_redirect_for_caller(
                raw, caller, backupBuf, sizeof(backupBuf), &isSysCaller);
            if (backup != NULL) {
                CFStringRef cfBackup = CFStringCreateWithFileSystemRepresentation(kCFAllocatorDefault, backup);
                if (cfBackup != NULL) {
                    NSString *backupStr = (__bridge_transfer NSString *)cfBackup;
                    if (outUsedBackup) *outUsedBackup = YES;
                    return ps_rebuild_file_nsurl(resolvedURL, backupStr);
                }
            }
        }
    }
    return resolvedURL;
}

static id ps_virtual_ancestor_resource_value_for_key(NSString *origPath, NSURLResourceKey key, BOOL *outHandled) {
    *outHandled = YES;
    if ([key isEqualToString:NSURLIsDirectoryKey] ||
        [key isEqualToString:NSURLIsReadableKey] ||
        [key isEqualToString:NSURLIsExecutableKey]) {
        return @YES;
    }
    if ([key isEqualToString:NSURLIsRegularFileKey] ||
        [key isEqualToString:NSURLIsSymbolicLinkKey] ||
        [key isEqualToString:NSURLIsPackageKey] ||
        [key isEqualToString:NSURLIsApplicationKey] ||
        [key isEqualToString:NSURLIsAliasFileKey] ||
        [key isEqualToString:NSURLIsHiddenKey] ||
        [key isEqualToString:NSURLIsWritableKey] ||
        [key isEqualToString:NSURLIsVolumeKey] ||
        [key isEqualToString:NSURLVolumeIsRootFileSystemKey]) {
        return @NO;
    }
    if ([key isEqualToString:NSURLFileResourceTypeKey]) {
        return NSURLFileResourceTypeDirectory;
    }
    if ([key isEqualToString:NSURLFileProtectionKey]) {
        return NSURLFileProtectionCompleteUntilFirstUserAuthentication;
    }
    NSString *norm = ps_normalize_virtual_ancestor_nsstring(origPath);
    BOOL usePrivatePrefix = [origPath hasPrefix:@"/private/"];
    if ([key isEqualToString:NSURLNameKey] || [key isEqualToString:NSURLLocalizedNameKey]) {
        return [norm lastPathComponent];
    }
    if ([key isEqualToString:NSURLPathKey]) {
        return usePrivatePrefix ? [@"/private" stringByAppendingString:norm] : norm;
    }
    if ([key isEqualToString:NSURLCanonicalPathKey]) {
        return [@"/private" stringByAppendingString:norm];
    }
    if ([key isEqualToString:NSURLParentDirectoryURLKey]) {
        NSString *parent = [norm stringByDeletingLastPathComponent];
        if (parent.length == 0) parent = @"/";
        if (usePrivatePrefix && ![parent isEqualToString:@"/"]) {
            parent = [@"/private" stringByAppendingString:parent];
        }
        return [NSURL fileURLWithPath:parent isDirectory:YES];
    }
    if ([key isEqualToString:NSURLVolumeSupportsCaseSensitiveNamesKey]) {
        return @YES;
    }
    if ([key isEqualToString:NSURLVolumeNameKey] ||
        [key isEqualToString:NSURLVolumeLocalizedNameKey]) {
        return @"Data";
    }
    if ([key isEqualToString:NSURLVolumeURLKey]) {
        return [NSURL fileURLWithPath:@"/private/var" isDirectory:YES];
    }
    if ([key isEqualToString:@"NSURLVolumeMountFromLocationKey"]) {
        return @"disk0s1s2";
    }
    *outHandled = NO;
    return nil;
}

static BOOL ps_url_path_is_system_root_volume(NSString *path) {
    if (path.length == 0) {
        return NO;
    }
    if ([path hasPrefix:@"/System/Volumes/"]) {
        return NO;
    }
    if ([path isEqualToString:@"/"] ||
        [path isEqualToString:@"/System"] ||
        [path hasPrefix:@"/System/Library/"] ||
        [path isEqualToString:@"/System/Library"] ||
        [path hasPrefix:@"/System/Applications/"] ||
        [path hasPrefix:@"/System/Cryptexes/"] ||
        [path hasPrefix:@"/usr/"] ||
        [path isEqualToString:@"/usr"] ||
        [path hasPrefix:@"/bin/"] ||
        [path isEqualToString:@"/bin"] ||
        [path hasPrefix:@"/sbin/"] ||
        [path isEqualToString:@"/sbin"]) {
        return YES;
    }
    return NO;
}

static id ps_sanitize_url_resource_value(NSURL *origURL,
                                         NSURLResourceKey key,
                                         id val,
                                         BOOL usePrivatePrefix,
                                         const void *caller) {
    if (val == nil || key == nil ||
        !pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(caller)) {
        return val;
    }
    if ([key isEqualToString:NSURLVolumeSupportsCaseSensitiveNamesKey]) {
        return @YES;
    }
    if ([key isEqualToString:NSURLVolumeIsRootFileSystemKey]) {
        NSString *origPath = [origURL isFileURL] ? origURL.path : nil;
        return @(ps_url_path_is_system_root_volume(origPath));
    }
    if ([key isEqualToString:@"NSURLVolumeMountFromLocationKey"] &&
        [val isKindOfClass:[NSString class]]) {
        NSString *origPath = [origURL isFileURL] ? origURL.path : nil;
        BOOL isRootVol = ps_url_path_is_system_root_volume(origPath);
        if ([(NSString *)val hasPrefix:@"/dev/"]) {
            return isRootVol ? @"/dev/disk0s1s1" : @"/dev/disk0s1s2";
        }
        return isRootVol ? @"disk0s1s1" : @"disk0s1s2";
    }
    if ([key isEqualToString:NSURLVolumeNameKey] ||
        [key isEqualToString:NSURLVolumeLocalizedNameKey]) {
        if ([val isKindOfClass:[NSString class]]) {
            NSString *origPath = [origURL isFileURL] ? origURL.path : nil;
            return ps_url_path_is_system_root_volume(origPath) ? @"System" : @"Data";
        }
        return val;
    }
    if ([key isEqualToString:NSURLVolumeURLKey]) {
        if ([val isKindOfClass:[NSURL class]] && [(NSURL *)val isFileURL]) {
            NSString *vp = [(NSURL *)val path];
            if ([vp isEqualToString:@"/System/Volumes/Data"] ||
                [vp isEqualToString:@"/System/Volumes/Data/"] ||
                [vp hasPrefix:@"/Volumes/"] ||
                [vp hasPrefix:@"/Users/"]) {
                return [NSURL fileURLWithPath:@"/private/var" isDirectory:YES];
            }
            if ([vp isEqualToString:@"/"]) {
                NSString *origPath = [origURL isFileURL] ? origURL.path : nil;
                if (origPath.length > 0 && !ps_url_path_is_system_root_volume(origPath)) {
                    return [NSURL fileURLWithPath:@"/private/var" isDirectory:YES];
                }
            }
            return ps_virtualize_nsurl_for_app((NSURL *)val, YES);
        }
        return val;
    }
    if ([key isEqualToString:NSURLFileProtectionKey]) {
        NSString *resolvedPath = [ps_resolve_virtual_nsurl(origURL) path];
        return ps_synthesized_file_protection_for_path(resolvedPath, [origURL hasDirectoryPath]);
    }
    if ([val isKindOfClass:[NSString class]]) {
        if ([key isEqualToString:NSURLCanonicalPathKey]) {
            return ps_virtualize_nsstring_path_for_app((NSString *)val, YES);
        }
        if ([key isEqualToString:NSURLPathKey]) {
            return ps_virtualize_nsstring_path_for_app((NSString *)val, usePrivatePrefix);
        }
    } else if ([val isKindOfClass:[NSURL class]]) {
        return ps_virtualize_nsurl_for_app((NSURL *)val, usePrivatePrefix);
    }
    return val;
}

- (BOOL) pm_checkResourceIsReachableAndReturnError:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    NSURL *selfURL = (NSURL *)self;
    BOOL wasVirtual = NO;
    BOOL usePrivatePrefix = NO;
    BOOL usedBackup = NO;
    if ([selfURL isFileURL]) {
        NSString *origPath = [selfURL path];
        NSURL *url = ps_resolve_readonly_nsurl_and_backup(
            selfURL, caller, &wasVirtual, &usePrivatePrefix, &usedBackup);
        NSString *resolvedPath = [url path];
        if (!usedBackup && ps_is_hidden_path(resolvedPath, caller)) {
            if (error != NULL) {
                *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
            }
            return NO;
        }
        if (ps_is_virtual_ancestor_nsstring(resolvedPath) || ps_is_virtual_ancestor_nsstring(origPath)) {
            return YES;
        }
        if (url != selfURL) {
            NSError *localErr = nil;
            BOOL ok = NO;
            if (usedBackup) {
                pt_enter_internal_scope();
                ok = [(id)url pm_checkResourceIsReachableAndReturnError:(error != NULL ? &localErr : NULL)];
                pt_leave_internal_scope();
            } else {
                ok = [(id)url pm_checkResourceIsReachableAndReturnError:(error != NULL ? &localErr : NULL)];
            }
            if (!ok) {
                ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
            }
            return ok;
        }
    }
    NSError *localErr = nil;
    BOOL ok = [self pm_checkResourceIsReachableAndReturnError:(error != NULL ? &localErr : NULL)];
    if (!ok) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return ok;
}

- (NSDictionary<NSURLResourceKey, id> *) pm_resourceValuesForKeys:(NSArray<NSURLResourceKey> *)keys error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    NSURL *selfURL = (NSURL *)self;
    NSString *origPath = [selfURL isFileURL] ? [selfURL path] : nil;
    BOOL wasVirtual = NO, usePrivatePrefix = NO, usedBackup = NO;
    NSURL *url = ps_resolve_readonly_nsurl_and_backup(
        selfURL, caller, &wasVirtual, &usePrivatePrefix, &usedBackup);
    if ([url isFileURL]) {
        NSString *resolvedPath = [url path];
        if (!usedBackup && ps_is_hidden_path(resolvedPath, caller)) {
            if (error != NULL) {
                *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
            }
            return nil;
        }
        if (!wasVirtual && (ps_is_virtual_ancestor_nsstring(resolvedPath) || ps_is_virtual_ancestor_nsstring(origPath))) {
            NSMutableDictionary<NSURLResourceKey, id> *synth = [NSMutableDictionary dictionaryWithCapacity:keys.count];
            NSMutableArray<NSURLResourceKey> *fallbackKeys = nil;
            for (NSURLResourceKey k in keys) {
                BOOL handled = NO;
                id v = ps_virtual_ancestor_resource_value_for_key(origPath ?: resolvedPath, k, &handled);
                if (handled) {
                    if (v != nil) {
                        synth[k] = v;
                    }
                } else {
                    if (fallbackKeys == nil) {
                        fallbackKeys = [NSMutableArray array];
                    }
                    [fallbackKeys addObject:k];
                }
            }
            if (fallbackKeys.count > 0) {
                NSURL *backingURL = [NSURL fileURLWithPath:@"/private/var" isDirectory:YES];
                NSDictionary<NSURLResourceKey, id> *backingVals = [(id)backingURL pm_resourceValuesForKeys:fallbackKeys error:nil];
                if (backingVals != nil) {
                    for (NSURLResourceKey bk in backingVals) {
                        id bval = ps_sanitize_url_resource_value(selfURL, bk, backingVals[bk], usePrivatePrefix, caller);
                        if (bval != nil) {
                            synth[bk] = bval;
                        }
                    }
                }
            }
            return [synth copy];
        }
    }
    NSError *localErr = nil;
    NSDictionary<NSURLResourceKey, id> *res = nil;
    if (usedBackup) {
        pt_enter_internal_scope();
        res = (url != selfURL)
            ? [(id)url pm_resourceValuesForKeys:keys error:(error != NULL ? &localErr : NULL)]
            : [self pm_resourceValuesForKeys:keys error:(error != NULL ? &localErr : NULL)];
        pt_leave_internal_scope();
    } else {
        res = (url != selfURL)
            ? [(id)url pm_resourceValuesForKeys:keys error:(error != NULL ? &localErr : NULL)]
            : [self pm_resourceValuesForKeys:keys error:(error != NULL ? &localErr : NULL)];
    }
    if (res == nil) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    if (res != nil) {
        NSMutableDictionary<NSURLResourceKey, id> *mapped = nil;
        for (NSURLResourceKey k in res) {
            id val = res[k];
            id newVal = ps_sanitize_url_resource_value(selfURL, k, val, usePrivatePrefix, caller);
            if (newVal != val && ![newVal isEqual:val]) {
                if (mapped == nil) {
                    mapped = [res mutableCopy];
                }
                mapped[k] = newVal;
            }
        }
        if (pt_is_bypass_enabled() &&
            !ps_is_effective_system_or_playtools_caller(caller) &&
            [keys containsObject:NSURLFileProtectionKey] &&
            (mapped ?: res)[NSURLFileProtectionKey] == nil) {
            if (mapped == nil) {
                mapped = [res mutableCopy];
            }
            mapped[NSURLFileProtectionKey] = ps_synthesized_file_protection_for_path(
                [url isFileURL] ? [url path] : nil, [url hasDirectoryPath]);
        }
        if (mapped != nil) {
            return [mapped copy];
        }
    }
    return res;
}

- (BOOL) pm_getResourceValue:(out id  _Nullable *)value forKey:(NSURLResourceKey)key error:(out NSError **)error {
    const void *caller = __builtin_return_address(0);
    NSURL *selfURL = (NSURL *)self;
    NSString *origPath = [selfURL isFileURL] ? [selfURL path] : nil;
    BOOL wasVirtual = NO, usePrivatePrefix = NO, usedBackup = NO;
    NSURL *url = ps_resolve_readonly_nsurl_and_backup(
        selfURL, caller, &wasVirtual, &usePrivatePrefix, &usedBackup);
    if ([url isFileURL]) {
        NSString *resolvedPath = [url path];
        if (!usedBackup && ps_is_hidden_path(resolvedPath, caller)) {
            if (value != NULL) *value = nil;
            if (error != NULL) {
                *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
            }
            return NO;
        }
        if (!wasVirtual && (ps_is_virtual_ancestor_nsstring(resolvedPath) || ps_is_virtual_ancestor_nsstring(origPath))) {
            BOOL handled = NO;
            id v = ps_virtual_ancestor_resource_value_for_key(origPath ?: resolvedPath, key, &handled);
            if (handled) {
                if (value != NULL) {
                    *value = v;
                }
                return YES;
            }
            NSURL *backingURL = [NSURL fileURLWithPath:@"/private/var" isDirectory:YES];
            BOOL okAnc = [(id)backingURL pm_getResourceValue:value forKey:key error:error];
            if (okAnc && value != NULL && *value != nil) {
                *value = ps_sanitize_url_resource_value(selfURL, key, *value, usePrivatePrefix, caller);
            }
            return okAnc;
        }
    }
    NSError *localErr = nil;
    BOOL ok = NO;
    if (usedBackup) {
        pt_enter_internal_scope();
        ok = (url != selfURL)
            ? [(id)url pm_getResourceValue:value forKey:key error:(error != NULL ? &localErr : NULL)]
            : [self pm_getResourceValue:value forKey:key error:(error != NULL ? &localErr : NULL)];
        pt_leave_internal_scope();
    } else {
        ok = (url != selfURL)
            ? [(id)url pm_getResourceValue:value forKey:key error:(error != NULL ? &localErr : NULL)]
            : [self pm_getResourceValue:value forKey:key error:(error != NULL ? &localErr : NULL)];
    }
    if (!ok) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    if (ok && value != NULL) {
        if (*value != nil) {
            *value = ps_sanitize_url_resource_value(selfURL, key, *value, usePrivatePrefix, caller);
        } else if (pt_is_bypass_enabled() &&
                   !ps_is_effective_system_or_playtools_caller(caller) &&
                   [key isEqualToString:NSURLFileProtectionKey]) {
            *value = ps_synthesized_file_protection_for_path(
                [url isFileURL] ? [url path] : nil, [url hasDirectoryPath]);
        }
    }
    return ok;
}

- (BOOL) pm_setResourceValue:(id)value forKey:(NSURLResourceKey)key error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    NSURL *selfURL = (NSURL *)self;
    if (![selfURL isFileURL] ||
        !pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(caller)) {
        return [self pm_setResourceValue:value forKey:key error:error];
    }
    NSString *origPath = [selfURL path];
    BOOL wasVirtual = (origPath != nil && ps_is_virtual_container_nsstring(origPath));
    BOOL usePrivatePrefix = (origPath != nil && [origPath hasPrefix:@"/private/"]);
    NSURL *url = ps_resolve_virtual_nsurl(selfURL);
    NSString *resolvedPath = [url path];
    if (ps_is_hidden_path(resolvedPath, caller)) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
        }
        return NO;
    }
    if (!wasVirtual && (ps_is_virtual_ancestor_nsstring(resolvedPath) || ps_is_virtual_ancestor_nsstring(origPath))) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
        }
        return NO;
    }
    if ([key isEqualToString:NSURLFileProtectionKey]) {
        int dp = ps_dpclass_from_file_protection(value);
        if (dp > 0 && resolvedPath.length > 0) {
            char raw[PATH_MAX];
            struct stat st;
            if (CFStringGetFileSystemRepresentation((__bridge CFStringRef)resolvedPath, raw, sizeof(raw)) &&
                stat(raw, &st) == 0) {
                pt_record_stat_dpclass(st.st_dev, st.st_ino, dp);
            }
        }
    }
    NSError *localErr = nil;
    BOOL ok = (url != selfURL)
        ? [(id)url pm_setResourceValue:value forKey:key error:(error != NULL ? &localErr : NULL)]
        : [self pm_setResourceValue:value forKey:key error:(error != NULL ? &localErr : NULL)];
    if (!ok) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return ok;
}

- (BOOL) pm_setResourceValues:(NSDictionary<NSURLResourceKey, id> *)keyedValues error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    NSURL *selfURL = (NSURL *)self;
    if (![selfURL isFileURL] ||
        !pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(caller)) {
        return [self pm_setResourceValues:keyedValues error:error];
    }
    NSString *origPath = [selfURL path];
    BOOL wasVirtual = (origPath != nil && ps_is_virtual_container_nsstring(origPath));
    BOOL usePrivatePrefix = (origPath != nil && [origPath hasPrefix:@"/private/"]);
    NSURL *url = ps_resolve_virtual_nsurl(selfURL);
    NSString *resolvedPath = [url path];
    if (ps_is_hidden_path(resolvedPath, caller)) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
        }
        return NO;
    }
    if (!wasVirtual && (ps_is_virtual_ancestor_nsstring(resolvedPath) || ps_is_virtual_ancestor_nsstring(origPath))) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
        }
        return NO;
    }
    int dp = ps_dpclass_from_file_protection(keyedValues[NSURLFileProtectionKey]);
    if (dp > 0 && resolvedPath.length > 0) {
        char raw[PATH_MAX];
        struct stat st;
        if (CFStringGetFileSystemRepresentation((__bridge CFStringRef)resolvedPath, raw, sizeof(raw)) &&
            stat(raw, &st) == 0) {
            pt_record_stat_dpclass(st.st_dev, st.st_ino, dp);
        }
    }
    NSError *localErr = nil;
    BOOL ok = (url != selfURL)
        ? [(id)url pm_setResourceValues:keyedValues error:(error != NULL ? &localErr : NULL)]
        : [self pm_setResourceValues:keyedValues error:(error != NULL ? &localErr : NULL)];
    if (!ok) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return ok;
}

- (NSArray<NSURL *> *) pm_mountedVolumeURLsIncludingResourceValuesForKeys:(NSArray<NSURLResourceKey> *)propertyKeys
                                                                  options:(NSVolumeEnumerationOptions)options {
    const void *caller = __builtin_return_address(0);
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        // Per Apple Foundation docs, mountedVolumeURLsIncludingResourceValuesForKeys:options:
        // always returns nil on non-macOS platforms (including iOS).
        return nil;
    }
    return [self pm_mountedVolumeURLsIncludingResourceValuesForKeys:propertyKeys options:options];
}

- (NSDictionary<NSFileAttributeKey, id> *) pm_attributesOfFileSystemForPath:(NSString *)path
                                                                      error:(NSError * _Nullable __autoreleasing *)error {
    const void *caller = __builtin_return_address(0);
    if (!pt_is_bypass_enabled() || ps_is_effective_system_or_playtools_caller(caller)) {
        return [self pm_attributesOfFileSystemForPath:path error:error];
    }
    BOOL hidden = NO, ancestor = NO, usedBackup = NO;
    BOOL usePrivatePrefix = [path isKindOfClass:[NSString class]] && [path hasPrefix:@"/private/"];
    BOOL wasVirtual = [path isKindOfClass:[NSString class]] && ps_is_virtual_container_nsstring(path);
    NSString *resolved = path;
    ps_prepare_fm_path_mode(path, caller, YES, &resolved, &hidden, &ancestor, &usedBackup);
    if (hidden) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileReadNoSuchFileError
                                     userInfo:(path != nil ? @{NSFilePathErrorKey: path} : nil)];
        }
        return nil;
    }
    if (ancestor) {
        pt_ensure_data_container_map();
        if (s_real_data_container_len > 0) {
            resolved = [NSString stringWithUTF8String:s_real_data_container_dir];
        } else {
            resolved = @"/private/var";
        }
    }
    NSError *localErr = nil;
    NSDictionary<NSFileAttributeKey, id> *attrs = nil;
    if (usedBackup) {
        pt_enter_internal_scope();
        attrs = [self pm_attributesOfFileSystemForPath:resolved error:(error != NULL ? &localErr : NULL)];
        pt_leave_internal_scope();
    } else {
        attrs = [self pm_attributesOfFileSystemForPath:resolved error:(error != NULL ? &localErr : NULL)];
    }
    if (attrs == nil) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return attrs;
}

- (BOOL) pm_fileExistsAtPath:(NSString *)path {
    BOOL hidden = NO, ancestor = NO, usedBackup = NO;
    ps_prepare_fm_path_mode(path, __builtin_return_address(0), YES, &path, &hidden, &ancestor, &usedBackup);
    if (hidden) {
        return NO;
    }
    if (ancestor) {
        return YES;
    }
    if (usedBackup) {
        pt_enter_internal_scope();
        BOOL exists = [self pm_fileExistsAtPath:path];
        pt_leave_internal_scope();
        return exists;
    }
    return [self pm_fileExistsAtPath:path];
}

- (BOOL) pm_fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
    BOOL hidden = NO, ancestor = NO, usedBackup = NO;
    ps_prepare_fm_path_mode(path, __builtin_return_address(0), YES, &path, &hidden, &ancestor, &usedBackup);
    if (hidden) {
        return NO;
    }
    if (ancestor) {
        if (isDirectory != NULL) {
            *isDirectory = YES;
        }
        return YES;
    }
    if (usedBackup) {
        pt_enter_internal_scope();
        BOOL exists = [self pm_fileExistsAtPath:path isDirectory:isDirectory];
        pt_leave_internal_scope();
        return exists;
    }
    return [self pm_fileExistsAtPath:path isDirectory:isDirectory];
}

- (BOOL) pm_isReadableFileAtPath:(NSString *)path {
    BOOL hidden = NO, ancestor = NO, usedBackup = NO;
    ps_prepare_fm_path_mode(path, __builtin_return_address(0), YES, &path, &hidden, &ancestor, &usedBackup);
    if (hidden) {
        return NO;
    }
    if (ancestor) {
        return YES;
    }
    if (usedBackup) {
        pt_enter_internal_scope();
        BOOL readable = [self pm_isReadableFileAtPath:path];
        pt_leave_internal_scope();
        return readable;
    }
    return [self pm_isReadableFileAtPath:path];
}

- (BOOL) pm_isWritableFileAtPath:(NSString *)path {
    BOOL hidden = NO, ancestor = NO;
    ps_prepare_fm_path(path, __builtin_return_address(0), &path, &hidden, &ancestor);
    if (hidden || ancestor) {
        return NO;
    }
    return [self pm_isWritableFileAtPath:path];
}

- (BOOL) pm_isExecutableFileAtPath:(NSString *)path {
    BOOL hidden = NO, ancestor = NO, usedBackup = NO;
    ps_prepare_fm_path_mode(path, __builtin_return_address(0), YES, &path, &hidden, &ancestor, &usedBackup);
    if (hidden) {
        return NO;
    }
    if (ancestor) {
        return YES;
    }
    if (usedBackup) {
        pt_enter_internal_scope();
        BOOL executable = [self pm_isExecutableFileAtPath:path];
        pt_leave_internal_scope();
        return executable;
    }
    return [self pm_isExecutableFileAtPath:path];
}

- (BOOL) pm_isDeletableFileAtPath:(NSString *)path {
    BOOL hidden = NO, ancestor = NO;
    ps_prepare_fm_path(path, __builtin_return_address(0), &path, &hidden, &ancestor);
    if (hidden || ancestor) {
        return NO;
    }
    return [self pm_isDeletableFileAtPath:path];
}

static inline void ps_detect_path_virtual_flags(NSString *p1, NSString *p2, BOOL *outWasVirtual, BOOL *outUsePrivate) {
    BOOL v1 = (p1 != nil && ps_is_virtual_container_nsstring(p1));
    BOOL v2 = (p2 != nil && ps_is_virtual_container_nsstring(p2));
    *outWasVirtual = (v1 || v2);
    *outUsePrivate = ((v1 && [p1 hasPrefix:@"/private/"]) || (v2 && [p2 hasPrefix:@"/private/"]));
}

- (NSDictionary<NSFileAttributeKey, id> *) pm_attributesOfItemAtPath:(NSString *)path error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO;
    ps_detect_path_virtual_flags(path, nil, &wasVirtual, &usePrivatePrefix);
    BOOL hidden = NO, ancestor = NO, usedBackup = NO;
    ps_prepare_fm_path_mode(path, caller, YES, &path, &hidden, &ancestor, &usedBackup);
    if (hidden) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
        }
        return nil;
    }
    if (ancestor) {
        return @{
            NSFileType: NSFileTypeDirectory,
            NSFilePosixPermissions: @(0555)
        };
    }
    NSError *localErr = nil;
    NSDictionary<NSFileAttributeKey, id> *attrs = nil;
    if (usedBackup) {
        pt_enter_internal_scope();
        attrs = [self pm_attributesOfItemAtPath:path error:(error != NULL ? &localErr : NULL)];
        pt_leave_internal_scope();
    } else {
        attrs = [self pm_attributesOfItemAtPath:path error:(error != NULL ? &localErr : NULL)];
    }
    if (attrs == nil) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
        return nil;
    }
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        NSMutableDictionary<NSFileAttributeKey, id> *san = nil;
        id grpId = attrs[NSFileGroupOwnerAccountID];
        if ([grpId isKindOfClass:[NSNumber class]] && [(NSNumber *)grpId unsignedIntValue] == 20U) {
            san = [attrs mutableCopy];
            san[NSFileGroupOwnerAccountID] = @(501);
        }
        id grpName = attrs[NSFileGroupOwnerAccountName];
        if ([grpName isKindOfClass:[NSString class]] && [(NSString *)grpName isEqualToString:@"staff"]) {
            if (san == nil) {
                san = [attrs mutableCopy];
            }
            san[NSFileGroupOwnerAccountName] = @"mobile";
        }
        id ownerName = attrs[NSFileOwnerAccountName];
        if ([ownerName isKindOfClass:[NSString class]]) {
            const char *hr = pt_get_host_user_root_cstr();
            const char *hostUser = (hr != NULL && strncmp(hr, "/Users/", 7) == 0) ? (hr + 7) : NULL;
            if (hostUser != NULL && hostUser[0] != '\0' &&
                strcmp([(NSString *)ownerName UTF8String] ?: "", hostUser) == 0) {
                if (san == nil) {
                    san = [attrs mutableCopy];
                }
                san[NSFileOwnerAccountName] = @"mobile";
            }
        }
        NSString *resolvedItemPath = ps_resolve_virtual_nsstring_path(path);
        NSString *synthProtection = ps_synthesized_file_protection_for_path(
            resolvedItemPath,
            [attrs[NSFileType] isEqualToString:NSFileTypeDirectory]);
        if (![synthProtection isEqual:attrs[NSFileProtectionKey]]) {
            if (san == nil) {
                san = [attrs mutableCopy];
            }
            san[NSFileProtectionKey] = synthProtection;
        }
        if (san != nil) {
            return [san copy];
        }
    }
    return attrs;
}

- (NSData *) pm_contentsAtPath:(NSString *)path {
    BOOL hidden = NO, ancestor = NO, usedBackup = NO;
    ps_prepare_fm_path_mode(path, __builtin_return_address(0), YES, &path, &hidden, &ancestor, &usedBackup);
    if (hidden) {
        return nil;
    }
    if (usedBackup) {
        pt_enter_internal_scope();
        NSData *data = [self pm_contentsAtPath:path];
        pt_leave_internal_scope();
        return data;
    }
    return [self pm_contentsAtPath:path];
}

- (NSString *) pm_destinationOfSymbolicLinkAtPath:(NSString *)path error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO;
    ps_detect_path_virtual_flags(path, nil, &wasVirtual, &usePrivatePrefix);
    BOOL hidden = NO, ancestor = NO;
    ps_prepare_fm_path(path, caller, &path, &hidden, &ancestor);
    if (hidden) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
        }
        return nil;
    }
    if (ancestor) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:nil];
        }
        return nil;
    }
    NSError *localErr = nil;
    NSString *dest = [self pm_destinationOfSymbolicLinkAtPath:path error:(error != NULL ? &localErr : NULL)];
    if (dest == nil) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
        return nil;
    }
    if (!ps_is_effective_system_or_playtools_caller(caller)) {
        if (ps_is_sensitive_or_hidden_nsstring(dest, caller)) {
            if (error != NULL) {
                *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
            }
            return nil;
        }
        if (pt_is_bypass_enabled() && dest.length > 0 && ![dest hasPrefix:@"/"] && path.length > 0) {
            NSString *parent = [path stringByDeletingLastPathComponent];
            NSString *joined = [parent stringByAppendingPathComponent:dest];
            char joinedC[PATH_MAX];
            char normC[PATH_MAX];
            if (CFStringGetFileSystemRepresentation((__bridge CFStringRef)joined, joinedC, sizeof(joinedC)) &&
                joinedC[0] == '/') {
                const char *norm = pt_normalize_lexical_path(joinedC, normC, sizeof(normC)) ?: joinedC;
                if (pt_is_sensitive_host_fd_path(norm, caller) || pt_is_hidden_path(norm, caller)) {
                    if (error != NULL) {
                        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
                    }
                    return nil;
                }
            }
        }
        NSString *virt = ps_virtualize_nsstring_path_for_app(dest, NO);
        if (virt != nil && ps_is_sensitive_or_hidden_nsstring(virt, caller)) {
            if (error != NULL) {
                *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
            }
            return nil;
        }
        if (virt != dest) {
            return virt;
        }
    }
    return dest;
}

static void ps_prepare_file_url_for_io(NSURL *url,
                                       const void *caller,
                                       BOOL allowReadOnlyBackup,
                                       NSURL * __autoreleasing *outResolvedURL,
                                       BOOL *outIsHidden,
                                       BOOL *outWasVirtual,
                                       BOOL *outUsePrivate,
                                       BOOL *outUsedBackup) {
    BOOL wasVirt = NO, usePriv = NO, hidden = NO, usedBackup = NO;
    NSURL *resolved = url;
    if (url != nil && [url isFileURL]) {
        NSString *rawPath = url.path;
        wasVirt = (rawPath != nil && ps_is_virtual_container_nsstring(rawPath));
        usePriv = (rawPath != nil && [rawPath hasPrefix:@"/private/"]);
        if (ps_is_hidden_path(rawPath, caller)) {
            hidden = YES;
        } else {
            resolved = ps_resolve_virtual_nsurl(url);
            if (resolved != url && ps_is_hidden_path(ps_strip_iossupport_nsstring(resolved.path), caller)) {
                hidden = YES;
            } else if (allowReadOnlyBackup && resolved != nil && [resolved isFileURL]) {
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
        }
    }
    if (outResolvedURL) *outResolvedURL = resolved;
    if (outIsHidden) *outIsHidden = hidden;
    if (outWasVirtual) *outWasVirtual = wasVirt;
    if (outUsePrivate) *outUsePrivate = usePriv;
    if (outUsedBackup) *outUsedBackup = usedBackup;
}

+ (NSData *) pm_dataWithContentsOfFile:(NSString *)path {
    BOOL hidden = NO, usedBackup = NO;
    ps_prepare_fm_path_mode(path, __builtin_return_address(0), YES, &path, &hidden, NULL, &usedBackup);
    if (hidden) {
        return nil;
    }
    if (usedBackup) {
        pt_enter_internal_scope();
        NSData *data = [self pm_dataWithContentsOfFile:path];
        pt_leave_internal_scope();
        return data;
    }
    return [self pm_dataWithContentsOfFile:path];
}

+ (NSData *) pm_dataWithContentsOfFile:(NSString *)path options:(NSDataReadingOptions)readOptionsMask error:(NSError **)errorPtr {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO, hidden = NO, usedBackup = NO;
    ps_detect_path_virtual_flags(path, nil, &wasVirtual, &usePrivatePrefix);
    ps_prepare_fm_path_mode(path, caller, YES, &path, &hidden, NULL, &usedBackup);
    if (hidden) {
        if (errorPtr != NULL) {
            *errorPtr = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
        }
        return nil;
    }
    NSError *localErr = nil;
    NSData *data = nil;
    if (usedBackup) {
        pt_enter_internal_scope();
        data = [self pm_dataWithContentsOfFile:path options:readOptionsMask error:(errorPtr != NULL ? &localErr : NULL)];
        pt_leave_internal_scope();
    } else {
        data = [self pm_dataWithContentsOfFile:path options:readOptionsMask error:(errorPtr != NULL ? &localErr : NULL)];
    }
    if (data == nil) {
        ps_assign_virtualized_nserror(errorPtr, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return data;
}

+ (NSData *) pm_dataWithContentsOfURL:(NSURL *)url options:(NSDataReadingOptions)readOptionsMask error:(NSError **)errorPtr {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO, hidden = NO, usedBackup = NO;
    NSURL *resolvedURL = nil;
    ps_prepare_file_url_for_io(url, caller, YES, &resolvedURL, &hidden, &wasVirtual, &usePrivatePrefix, &usedBackup);
    if (hidden) {
        if (errorPtr != NULL) {
            *errorPtr = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
        }
        return nil;
    }
    NSError *localErr = nil;
    NSData *data = nil;
    if (usedBackup) {
        pt_enter_internal_scope();
        data = [self pm_dataWithContentsOfURL:resolvedURL options:readOptionsMask error:(errorPtr != NULL ? &localErr : NULL)];
        pt_leave_internal_scope();
    } else {
        data = [self pm_dataWithContentsOfURL:resolvedURL options:readOptionsMask error:(errorPtr != NULL ? &localErr : NULL)];
    }
    if (data == nil) {
        ps_assign_virtualized_nserror(errorPtr, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return data;
}

- (BOOL) pm_data_writeToFile:(NSString *)path options:(NSDataWritingOptions)writeOptionsMask error:(NSError **)errorPtr {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO, hidden = NO;
    ps_detect_path_virtual_flags(path, nil, &wasVirtual, &usePrivatePrefix);
    ps_prepare_fm_path(path, caller, &path, &hidden, NULL);
    if (hidden) {
        if (errorPtr != NULL) {
            *errorPtr = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
        }
        return NO;
    }
    NSError *localErr = nil;
    BOOL ok = [self pm_data_writeToFile:path options:writeOptionsMask error:(errorPtr != NULL ? &localErr : NULL)];
    if (!ok) {
        ps_assign_virtualized_nserror(errorPtr, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return ok;
}

- (BOOL) pm_data_writeToURL:(NSURL *)url options:(NSDataWritingOptions)writeOptionsMask error:(NSError **)errorPtr {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO, hidden = NO;
    NSURL *resolvedURL = nil;
    ps_prepare_file_url_for_io(url, caller, NO, &resolvedURL, &hidden, &wasVirtual, &usePrivatePrefix, NULL);
    if (hidden) {
        if (errorPtr != NULL) {
            *errorPtr = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
        }
        return NO;
    }
    NSError *localErr = nil;
    BOOL ok = [self pm_data_writeToURL:resolvedURL options:writeOptionsMask error:(errorPtr != NULL ? &localErr : NULL)];
    if (!ok) {
        ps_assign_virtualized_nserror(errorPtr, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return ok;
}

+ (NSString *) pm_stringWithContentsOfFile:(NSString *)path encoding:(NSStringEncoding)enc error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO, hidden = NO, usedBackup = NO;
    ps_detect_path_virtual_flags(path, nil, &wasVirtual, &usePrivatePrefix);
    ps_prepare_fm_path_mode(path, caller, YES, &path, &hidden, NULL, &usedBackup);
    if (hidden) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
        }
        return nil;
    }
    NSError *localErr = nil;
    NSString *res = nil;
    if (usedBackup) {
        pt_enter_internal_scope();
        res = [self pm_stringWithContentsOfFile:path encoding:enc error:(error != NULL ? &localErr : NULL)];
        pt_leave_internal_scope();
    } else {
        res = [self pm_stringWithContentsOfFile:path encoding:enc error:(error != NULL ? &localErr : NULL)];
    }
    if (res == nil) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return res;
}

+ (NSString *) pm_stringWithContentsOfURL:(NSURL *)url encoding:(NSStringEncoding)enc error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO, hidden = NO, usedBackup = NO;
    NSURL *resolvedURL = nil;
    ps_prepare_file_url_for_io(url, caller, YES, &resolvedURL, &hidden, &wasVirtual, &usePrivatePrefix, &usedBackup);
    if (hidden) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
        }
        return nil;
    }
    NSError *localErr = nil;
    NSString *res = nil;
    if (usedBackup) {
        pt_enter_internal_scope();
        res = [self pm_stringWithContentsOfURL:resolvedURL encoding:enc error:(error != NULL ? &localErr : NULL)];
        pt_leave_internal_scope();
    } else {
        res = [self pm_stringWithContentsOfURL:resolvedURL encoding:enc error:(error != NULL ? &localErr : NULL)];
    }
    if (res == nil) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return res;
}

- (BOOL) pm_str_writeToFile:(NSString *)path atomically:(BOOL)useAuxiliaryFile encoding:(NSStringEncoding)enc error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO, hidden = NO;
    ps_detect_path_virtual_flags(path, nil, &wasVirtual, &usePrivatePrefix);
    ps_prepare_fm_path(path, caller, &path, &hidden, NULL);
    if (hidden) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
        }
        return NO;
    }
    NSError *localErr = nil;
    BOOL ok = [self pm_str_writeToFile:path atomically:useAuxiliaryFile encoding:enc error:(error != NULL ? &localErr : NULL)];
    if (!ok) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return ok;
}

- (BOOL) pm_str_writeToURL:(NSURL *)url atomically:(BOOL)useAuxiliaryFile encoding:(NSStringEncoding)enc error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO, hidden = NO;
    NSURL *resolvedURL = nil;
    ps_prepare_file_url_for_io(url, caller, NO, &resolvedURL, &hidden, &wasVirtual, &usePrivatePrefix, NULL);
    if (hidden) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
        }
        return NO;
    }
    NSError *localErr = nil;
    BOOL ok = [self pm_str_writeToURL:resolvedURL atomically:useAuxiliaryFile encoding:enc error:(error != NULL ? &localErr : NULL)];
    if (!ok) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return ok;
}

- (NSArray<NSURL *> *) pm_URLsForDirectory:(NSSearchPathDirectory)directory inDomains:(NSSearchPathDomainMask)domainMask {
    const void *caller = __builtin_return_address(0);
    NSArray<NSURL *> *orig = [self pm_URLsForDirectory:directory inDomains:domainMask];
    if (orig.count > 0) {
        BOOL bypass = pt_is_bypass_enabled();
        NSMutableArray<NSURL *> *filtered = nil;
        int isSysCaller = -1;
        for (NSUInteger i = 0; i < orig.count; i++) {
            NSURL *u = orig[i];
            NSURL *vu = ps_virtualize_nsurl_for_app(u, NO);
            BOOL changed = (vu != u);
            BOOL hide = NO;
            if (bypass && [vu isFileURL]) {
                if (isSysCaller < 0) {
                    isSysCaller = ps_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
                }
                if (isSysCaller != 0) {
                    return orig;
                }
                NSString *vpath = vu.path;
                if (vpath.length > 0 && ps_is_hidden_path(vpath, caller)) {
                    hide = YES;
                }
            } else if (changed) {
                if (isSysCaller < 0) {
                    isSysCaller = ps_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
                }
                if (isSysCaller != 0) {
                    return orig;
                }
            }
            if ((changed || hide) && filtered == nil) {
                filtered = [NSMutableArray arrayWithCapacity:orig.count];
                for (NSUInteger j = 0; j < i; j++) {
                    [filtered addObject:orig[j]];
                }
            }
            if (filtered != nil && !hide) {
                [filtered addObject:vu];
            }
        }
        if (filtered != nil) {
            return [filtered copy];
        }
    }
    return orig;
}

- (NSURL *) pm_URLForDirectory:(NSSearchPathDirectory)directory
                      inDomain:(NSSearchPathDomainMask)domain
             appropriateForURL:(NSURL *)url
                        create:(BOOL)shouldCreate
                         error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO;
    ps_detect_path_virtual_flags([url isFileURL] ? url.path : nil, nil, &wasVirtual, &usePrivatePrefix);
    NSURL *resolvedAppropriate = ps_resolve_virtual_nsurl(url);
    NSError *localErr = nil;
    NSURL *res = [self pm_URLForDirectory:directory
                                 inDomain:domain
                        appropriateForURL:resolvedAppropriate
                                   create:shouldCreate
                                    error:(error != NULL ? &localErr : NULL)];
    if (res == nil) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    if (res != nil) {
        NSURL *virt = ps_virtualize_nsurl_for_app(res, NO);
        if (virt != res && !ps_is_effective_system_or_playtools_caller(caller)) {
            return virt;
        }
    }
    return res;
}

- (NSURL *) pm_temporaryDirectory {
    const char *vt = pt_get_virtual_tmpdir_cstr();
    if (vt != NULL && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        NSString *vtStr = [NSString stringWithUTF8String:vt];
        if (vtStr != nil) {
            return [NSURL fileURLWithPath:vtStr isDirectory:YES];
        }
    }
    return [self pm_temporaryDirectory];
}

- (NSURL *) pm_ps_homeDirectoryForCurrentUser {
    if (!ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        const char *vh = pt_get_virtual_home_cstr();
        if (vh != NULL && vh[0] == '/') {
            NSString *vhStr = [NSString stringWithUTF8String:vh];
            if (vhStr.length > 0) {
                return [NSURL fileURLWithPath:vhStr isDirectory:YES];
            }
        }
        NSString *virtHome = ps_virtualize_nsstring_path_for_app(NSHomeDirectory(), NO);
        if (virtHome.length > 0) {
            return [NSURL fileURLWithPath:virtHome isDirectory:YES];
        }
    }
    return [self pm_ps_homeDirectoryForCurrentUser];
}

- (NSURL *) pm_ps_homeDirectoryForUser:(NSString *)userName {
    const void *caller = __builtin_return_address(0);
    if (!ps_is_effective_system_or_playtools_caller(caller)) {
        if (userName.length == 0 ||
            [userName isEqualToString:NSUserName()] ||
            [userName isEqualToString:@"mobile"]) {
            const char *vh = pt_get_virtual_home_cstr();
            if (vh != NULL && vh[0] == '/') {
                NSString *vhStr = [NSString stringWithUTF8String:vh];
                if (vhStr.length > 0) {
                    return [NSURL fileURLWithPath:vhStr isDirectory:YES];
                }
            }
            NSString *virtHome = ps_virtualize_nsstring_path_for_app(NSHomeDirectory(), NO);
            if (virtHome.length > 0) {
                return [NSURL fileURLWithPath:virtHome isDirectory:YES];
            }
        }
        NSURL *orig = [self pm_ps_homeDirectoryForUser:userName];
        if (orig != nil) {
            NSString *origPath = [orig isFileURL] ? orig.path : nil;
            if (pt_is_bypass_enabled() && origPath.length > 0 &&
                ([origPath hasPrefix:@"/Users/"] ||
                 [origPath hasPrefix:@"/System/Volumes/Data/Users/"] ||
                 ps_is_hidden_path(origPath, caller))) {
                return nil;
            }
            return ps_virtualize_nsurl_for_app(orig, NO);
        }
        return nil;
    }
    return [self pm_ps_homeDirectoryForUser:userName];
}

- (NSString *) pm_currentDirectoryPath {
    const void *caller = __builtin_return_address(0);
    NSString *orig = [self pm_currentDirectoryPath];
    if (orig != nil && !ps_is_effective_system_or_playtools_caller(caller)) {
        NSString *virt = ps_virtualize_nsstring_path_for_app(orig, YES);
        if (virt != orig && ![virt isEqualToString:orig]) {
            return virt;
        }
        if (ps_is_hidden_path(orig, caller)) {
            const char *vh = pt_get_virtual_home_cstr();
            return (vh != NULL && vh[0] != '\0')
                ? [NSString stringWithUTF8String:vh]
                : @"/var/mobile";
        }
    }
    return orig;
}

- (BOOL) pm_changeCurrentDirectoryPath:(NSString *)path {
    const void *caller = __builtin_return_address(0);
    BOOL hidden = NO, ancestor = NO;
    ps_prepare_fm_path(path, caller, &path, &hidden, &ancestor);
    if (hidden || ancestor || ps_is_hidden_path(path, caller) || ps_is_virtual_ancestor_nsstring(path)) {
        return NO;
    }
    return [self pm_changeCurrentDirectoryPath:path];
}

- (BOOL) pm_createDirectoryAtPath:(NSString *)path
      withIntermediateDirectories:(BOOL)createIntermediates
                       attributes:(NSDictionary<NSFileAttributeKey, id> *)attributes
                            error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO;
    ps_detect_path_virtual_flags(path, nil, &wasVirtual, &usePrivatePrefix);
    BOOL hidden = NO, ancestor = NO;
    ps_prepare_fm_path(path, caller, &path, &hidden, &ancestor);
    if (hidden || ps_is_hidden_path(path, caller)) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
        }
        return NO;
    }
    if (ancestor || ps_is_virtual_ancestor_nsstring(path)) {
        if (createIntermediates) {
            return YES;
        }
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteFileExistsError userInfo:nil];
        }
        return NO;
    }
    NSError *localErr = nil;
    BOOL ok = [self pm_createDirectoryAtPath:path
                 withIntermediateDirectories:createIntermediates
                                  attributes:attributes
                                       error:(error != NULL ? &localErr : NULL)];
    if (!ok) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return ok;
}

- (BOOL) pm_createDirectoryAtURL:(NSURL *)url
     withIntermediateDirectories:(BOOL)createIntermediates
                      attributes:(NSDictionary<NSFileAttributeKey, id> *)attributes
                           error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO;
    ps_detect_path_virtual_flags([url isFileURL] ? url.path : nil, nil, &wasVirtual, &usePrivatePrefix);
    BOOL hidden = NO, ancestor = NO;
    ps_prepare_fm_url_for_modify(url, caller, &url, &hidden, &ancestor);
    if (hidden) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
        }
        return NO;
    }
    if (ancestor) {
        if (createIntermediates) {
            return YES;
        }
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteFileExistsError userInfo:nil];
        }
        return NO;
    }
    NSError *localErr = nil;
    BOOL ok = [self pm_createDirectoryAtURL:url
                withIntermediateDirectories:createIntermediates
                                 attributes:attributes
                                      error:(error != NULL ? &localErr : NULL)];
    if (!ok) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return ok;
}

- (BOOL) pm_createFileAtPath:(NSString *)path
                    contents:(NSData *)data
                  attributes:(NSDictionary<NSFileAttributeKey, id> *)attr {
    const void *caller = __builtin_return_address(0);
    BOOL hidden = NO, ancestor = NO;
    ps_prepare_fm_path(path, caller, &path, &hidden, &ancestor);
    if (hidden || ancestor || ps_is_hidden_path(path, caller) || ps_is_virtual_ancestor_nsstring(path)) {
        return NO;
    }
    return [self pm_createFileAtPath:path contents:data attributes:attr];
}

- (BOOL) pm_removeItemAtPath:(NSString *)path error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO;
    ps_detect_path_virtual_flags(path, nil, &wasVirtual, &usePrivatePrefix);
    BOOL hidden = NO, ancestor = NO;
    ps_prepare_fm_path(path, caller, &path, &hidden, &ancestor);
    if (hidden || ps_is_hidden_path(path, caller)) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
        }
        return NO;
    }
    if (ancestor || ps_is_virtual_ancestor_nsstring(path)) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
        }
        return NO;
    }
    NSError *localErr = nil;
    BOOL ok = [self pm_removeItemAtPath:path error:(error != NULL ? &localErr : NULL)];
    if (!ok) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return ok;
}

- (BOOL) pm_removeItemAtURL:(NSURL *)URL error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO;
    ps_detect_path_virtual_flags([URL isFileURL] ? URL.path : nil, nil, &wasVirtual, &usePrivatePrefix);
    BOOL hidden = NO, ancestor = NO;
    ps_prepare_fm_url_for_modify(URL, caller, &URL, &hidden, &ancestor);
    if (hidden) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
        }
        return NO;
    }
    if (ancestor) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
        }
        return NO;
    }
    NSError *localErr = nil;
    BOOL ok = [self pm_removeItemAtURL:URL error:(error != NULL ? &localErr : NULL)];
    if (!ok) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return ok;
}

- (BOOL) pm_copyItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO;
    ps_detect_path_virtual_flags(srcPath, dstPath, &wasVirtual, &usePrivatePrefix);
    BOOL srcHidden = NO, srcAncestor = NO, dstHidden = NO, dstAncestor = NO;
    ps_prepare_fm_path(srcPath, caller, &srcPath, &srcHidden, &srcAncestor);
    ps_prepare_fm_path(dstPath, caller, &dstPath, &dstHidden, &dstAncestor);
    if (srcHidden || ps_is_hidden_path(srcPath, caller)) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
        }
        return NO;
    }
    if (dstHidden || ps_is_hidden_path(dstPath, caller) ||
        srcAncestor || dstAncestor ||
        ps_is_virtual_ancestor_nsstring(srcPath) || ps_is_virtual_ancestor_nsstring(dstPath)) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
        }
        return NO;
    }
    NSError *localErr = nil;
    BOOL ok = [self pm_copyItemAtPath:srcPath
                                toPath:dstPath
                                 error:(error != NULL ? &localErr : NULL)];
    if (!ok) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return ok;
}

- (BOOL) pm_copyItemAtURL:(NSURL *)srcURL toURL:(NSURL *)dstURL error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO;
    ps_detect_path_virtual_flags([srcURL isFileURL] ? srcURL.path : nil,
                                 [dstURL isFileURL] ? dstURL.path : nil,
                                 &wasVirtual,
                                 &usePrivatePrefix);
    BOOL srcHidden = NO, srcAncestor = NO, dstHidden = NO, dstAncestor = NO;
    ps_prepare_fm_url_for_modify(srcURL, caller, &srcURL, &srcHidden, &srcAncestor);
    ps_prepare_fm_url_for_modify(dstURL, caller, &dstURL, &dstHidden, &dstAncestor);
    if (srcHidden) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
        }
        return NO;
    }
    if (dstHidden || srcAncestor || dstAncestor) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
        }
        return NO;
    }
    NSError *localErr = nil;
    BOOL ok = [self pm_copyItemAtURL:srcURL
                               toURL:dstURL
                               error:(error != NULL ? &localErr : NULL)];
    if (!ok) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return ok;
}

- (BOOL) pm_moveItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO;
    ps_detect_path_virtual_flags(srcPath, dstPath, &wasVirtual, &usePrivatePrefix);
    BOOL srcHidden = NO, srcAncestor = NO, dstHidden = NO, dstAncestor = NO;
    ps_prepare_fm_path(srcPath, caller, &srcPath, &srcHidden, &srcAncestor);
    ps_prepare_fm_path(dstPath, caller, &dstPath, &dstHidden, &dstAncestor);
    if (srcHidden || ps_is_hidden_path(srcPath, caller)) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
        }
        return NO;
    }
    if (dstHidden || ps_is_hidden_path(dstPath, caller) ||
        srcAncestor || dstAncestor ||
        ps_is_virtual_ancestor_nsstring(srcPath) || ps_is_virtual_ancestor_nsstring(dstPath)) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
        }
        return NO;
    }
    NSError *localErr = nil;
    BOOL ok = [self pm_moveItemAtPath:srcPath
                                toPath:dstPath
                                 error:(error != NULL ? &localErr : NULL)];
    if (!ok) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return ok;
}

- (BOOL) pm_moveItemAtURL:(NSURL *)srcURL toURL:(NSURL *)dstURL error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO;
    ps_detect_path_virtual_flags([srcURL isFileURL] ? srcURL.path : nil,
                                 [dstURL isFileURL] ? dstURL.path : nil,
                                 &wasVirtual,
                                 &usePrivatePrefix);
    BOOL srcHidden = NO, srcAncestor = NO, dstHidden = NO, dstAncestor = NO;
    ps_prepare_fm_url_for_modify(srcURL, caller, &srcURL, &srcHidden, &srcAncestor);
    ps_prepare_fm_url_for_modify(dstURL, caller, &dstURL, &dstHidden, &dstAncestor);
    if (srcHidden) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
        }
        return NO;
    }
    if (dstHidden || srcAncestor || dstAncestor) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
        }
        return NO;
    }
    NSError *localErr = nil;
    BOOL ok = [self pm_moveItemAtURL:srcURL
                               toURL:dstURL
                               error:(error != NULL ? &localErr : NULL)];
    if (!ok) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return ok;
}

- (BOOL) pm_linkItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO;
    ps_detect_path_virtual_flags(srcPath, dstPath, &wasVirtual, &usePrivatePrefix);
    BOOL srcHidden = NO, srcAncestor = NO, dstHidden = NO, dstAncestor = NO;
    ps_prepare_fm_path(srcPath, caller, &srcPath, &srcHidden, &srcAncestor);
    ps_prepare_fm_path(dstPath, caller, &dstPath, &dstHidden, &dstAncestor);
    if (srcHidden || ps_is_hidden_path(srcPath, caller)) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
        }
        return NO;
    }
    if (dstHidden || ps_is_hidden_path(dstPath, caller) ||
        srcAncestor || dstAncestor ||
        ps_is_virtual_ancestor_nsstring(srcPath) || ps_is_virtual_ancestor_nsstring(dstPath)) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
        }
        return NO;
    }
    NSError *localErr = nil;
    BOOL ok = [self pm_linkItemAtPath:srcPath
                                toPath:dstPath
                                 error:(error != NULL ? &localErr : NULL)];
    if (!ok) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return ok;
}

- (BOOL) pm_linkItemAtURL:(NSURL *)srcURL toURL:(NSURL *)dstURL error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO;
    ps_detect_path_virtual_flags([srcURL isFileURL] ? srcURL.path : nil,
                                 [dstURL isFileURL] ? dstURL.path : nil,
                                 &wasVirtual,
                                 &usePrivatePrefix);
    BOOL srcHidden = NO, srcAncestor = NO, dstHidden = NO, dstAncestor = NO;
    ps_prepare_fm_url_for_modify(srcURL, caller, &srcURL, &srcHidden, &srcAncestor);
    ps_prepare_fm_url_for_modify(dstURL, caller, &dstURL, &dstHidden, &dstAncestor);
    if (srcHidden) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
        }
        return NO;
    }
    if (dstHidden || srcAncestor || dstAncestor) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
        }
        return NO;
    }
    NSError *localErr = nil;
    BOOL ok = [self pm_linkItemAtURL:srcURL
                               toURL:dstURL
                               error:(error != NULL ? &localErr : NULL)];
    if (!ok) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return ok;
}

- (BOOL) pm_createSymbolicLinkAtPath:(NSString *)path
                 withDestinationPath:(NSString *)destPath
                               error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO;
    ps_detect_path_virtual_flags(path, destPath, &wasVirtual, &usePrivatePrefix);
    BOOL pathHidden = NO, pathAncestor = NO, destHidden = NO, destAncestor = NO;
    ps_prepare_fm_path(path, caller, &path, &pathHidden, &pathAncestor);
    if (destPath.length > 0 && ![destPath hasPrefix:@"/"]) {
        // Symlink targets are resolved relative to the link's parent directory, not CWD.
        NSString *parentDir = [path stringByDeletingLastPathComponent];
        NSString *joinedDest = (parentDir.length > 0)
            ? [parentDir stringByAppendingPathComponent:destPath]
            : destPath;
        NSString *checkedDest = joinedDest;
        ps_prepare_fm_path(joinedDest, caller, &checkedDest, &destHidden, &destAncestor);
        if (!destHidden && ps_is_hidden_path(checkedDest, caller)) {
            destHidden = YES;
        }
        if (!destAncestor && ps_is_virtual_ancestor_nsstring(checkedDest)) {
            destAncestor = YES;
        }
    } else {
        ps_prepare_fm_path(destPath, caller, &destPath, &destHidden, &destAncestor);
        if (!destHidden && ps_is_hidden_path(destPath, caller)) {
            destHidden = YES;
        }
        if (!destAncestor && ps_is_virtual_ancestor_nsstring(destPath)) {
            destAncestor = YES;
        }
    }
    if (pathHidden || destHidden ||
        ps_is_hidden_path(path, caller) ||
        pathAncestor || destAncestor ||
        ps_is_virtual_ancestor_nsstring(path)) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
        }
        return NO;
    }
    NSError *localErr = nil;
    BOOL ok = [self pm_createSymbolicLinkAtPath:path
                            withDestinationPath:destPath
                                          error:(error != NULL ? &localErr : NULL)];
    if (!ok) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return ok;
}

- (BOOL) pm_createSymbolicLinkAtURL:(NSURL *)url
                 withDestinationURL:(NSURL *)destURL
                              error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO;
    ps_detect_path_virtual_flags([url isFileURL] ? url.path : nil,
                                 [destURL isFileURL] ? destURL.path : nil,
                                 &wasVirtual,
                                 &usePrivatePrefix);
    BOOL urlHidden = NO, urlAncestor = NO, destHidden = NO, destAncestor = NO;
    ps_prepare_fm_url_for_modify(url, caller, &url, &urlHidden, &urlAncestor);
    ps_prepare_fm_url_for_modify(destURL, caller, &destURL, &destHidden, &destAncestor);
    if (urlHidden || destHidden || urlAncestor || destAncestor) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
        }
        return NO;
    }
    NSError *localErr = nil;
    BOOL ok = [self pm_createSymbolicLinkAtURL:url
                            withDestinationURL:destURL
                                         error:(error != NULL ? &localErr : NULL)];
    if (!ok) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return ok;
}

- (BOOL) pm_replaceItemAtURL:(NSURL *)originalItemURL
               withItemAtURL:(NSURL *)newItemURL
              backupItemName:(NSString *)backupItemName
                     options:(NSFileManagerItemReplacementOptions)options
            resultingItemURL:(NSURL * _Nullable *)resultingURL
                       error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO;
    ps_detect_path_virtual_flags([originalItemURL isFileURL] ? originalItemURL.path : nil,
                                 [newItemURL isFileURL] ? newItemURL.path : nil,
                                 &wasVirtual,
                                 &usePrivatePrefix);
    BOOL origHidden = NO, origAncestor = NO, newHidden = NO, newAncestor = NO;
    ps_prepare_fm_url_for_modify(originalItemURL, caller, &originalItemURL, &origHidden, &origAncestor);
    ps_prepare_fm_url_for_modify(newItemURL, caller, &newItemURL, &newHidden, &newAncestor);
    if (origHidden || newHidden) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
        }
        return NO;
    }
    if (origAncestor || newAncestor) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
        }
        return NO;
    }
    NSError *localErr = nil;
    BOOL ok = [self pm_replaceItemAtURL:originalItemURL
                          withItemAtURL:newItemURL
                         backupItemName:backupItemName
                                options:options
                       resultingItemURL:resultingURL
                                  error:(error != NULL ? &localErr : NULL)];
    if (!ok) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    if (ok && resultingURL != NULL && *resultingURL != nil && wasVirtual) {
        *resultingURL = ps_virtualize_nsurl_for_app(*resultingURL, usePrivatePrefix);
    }
    return ok;
}

static BOOL ps_is_unallowed_other_user_tilde(NSString *path, const void *caller) {
    if (path == nil || ![path hasPrefix:@"~"] ||
        !pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(caller)) {
        return NO;
    }
    if (path.length == 1 || [path characterAtIndex:1] == '/') {
        return NO;
    }
    NSRange slash = [path rangeOfString:@"/"];
    NSString *user = (slash.location == NSNotFound)
        ? [path substringFromIndex:1]
        : [path substringWithRange:NSMakeRange(1, slash.location - 1)];
    return ![user isEqualToString:@"mobile"];
}

- (BOOL) pm_setAttributes:(NSDictionary<NSFileAttributeKey, id> *)attributes
             ofItemAtPath:(NSString *)path
                    error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO;
    ps_detect_path_virtual_flags(path, nil, &wasVirtual, &usePrivatePrefix);
    NSString *resolvedPath = path;
    BOOL hidden = NO, ancestor = NO;
    ps_prepare_fm_path(path, caller, &resolvedPath, &hidden, &ancestor);
    if (hidden || ps_is_hidden_path(resolvedPath, caller)) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
        }
        return NO;
    }
    if (ancestor || ps_is_virtual_ancestor_nsstring(resolvedPath)) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
        }
        return NO;
    }
    BOOL isSys = ps_is_effective_system_or_playtools_caller(caller);
    int dp = (!isSys && attributes != nil)
        ? ps_dpclass_from_file_protection(attributes[NSFileProtectionKey])
        : 0;
    NSError *localErr = nil;
    BOOL ok = [self pm_setAttributes:attributes
                        ofItemAtPath:resolvedPath
                               error:(error != NULL ? &localErr : NULL)];
    if (dp > 0 && resolvedPath.length > 0) {
        char raw[PATH_MAX];
        struct stat st;
        if (CFStringGetFileSystemRepresentation((__bridge CFStringRef)resolvedPath, raw, sizeof(raw)) &&
            !pt_is_sensitive_host_fd_path(raw, caller) &&
            stat(raw, &st) == 0) {
            pt_record_stat_dpclass(st.st_dev, st.st_ino, dp);
            if (!ok && attributes.count == 1) {
                ok = YES;
            }
        }
    }
    if (!ok) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return ok;
}

- (NSString *) pm_stringByExpandingTildeInPath {
    const void *caller = __builtin_return_address(0);
    NSString *orig = (NSString *)self;
    if (ps_is_unallowed_other_user_tilde(orig, caller)) {
        return orig;
    }
    NSString *expanded = [self pm_stringByExpandingTildeInPath];
    BOOL isSys = ps_is_effective_system_or_playtools_caller(caller);
    return ps_finalize_sanitized_nsstring_path(orig, expanded, isSys, caller);
}

- (NSString *) pm_ps2_stringByExpandingTildeInPath {
    const void *caller = __builtin_return_address(0);
    NSString *orig = (NSString *)self;
    if (ps_is_unallowed_other_user_tilde(orig, caller)) {
        return orig;
    }
    NSString *expanded = [self pm_ps2_stringByExpandingTildeInPath];
    BOOL isSys = ps_is_effective_system_or_playtools_caller(caller);
    return ps_finalize_sanitized_nsstring_path(orig, expanded, isSys, caller);
}

- (NSString *) pm_stringByResolvingSymlinksInPath {
    const void *caller = __builtin_return_address(0);
    NSString *orig = (NSString *)self;
    BOOL isSys = ps_is_effective_system_or_playtools_caller(caller);
    if (ps_is_virtual_container_nsstring(orig)) {
        NSString *resolvedIn = ps_resolve_virtual_nsstring_path(orig);
        if (!isSys && ps_is_hidden_path(resolvedIn, caller)) {
            return orig;
        }
        pt_enter_internal_scope();
        NSString *resolvedOut = [resolvedIn stringByResolvingSymlinksInPath];
        pt_leave_internal_scope();
        return ps_finalize_sanitized_nsstring_path(orig, resolvedOut, isSys, caller);
    }
    if (ps_is_virtual_ancestor_nsstring(orig)) {
        return ps_normalize_virtual_ancestor_nsstring(orig);
    }
    if (!isSys && ps_is_hidden_path(orig, caller)) {
        return ps_finalize_sanitized_nsstring_path(orig, orig, isSys, caller);
    }
    NSString *res = [self pm_stringByResolvingSymlinksInPath];
    return ps_finalize_sanitized_nsstring_path(orig, res, isSys, caller);
}

- (NSString *) pm_ps2_stringByResolvingSymlinksInPath {
    const void *caller = __builtin_return_address(0);
    NSString *orig = (NSString *)self;
    BOOL isSys = ps_is_effective_system_or_playtools_caller(caller);
    if (ps_is_virtual_container_nsstring(orig)) {
        NSString *resolvedIn = ps_resolve_virtual_nsstring_path(orig);
        if (!isSys && ps_is_hidden_path(resolvedIn, caller)) {
            return orig;
        }
        pt_enter_internal_scope();
        NSString *resolvedOut = [resolvedIn stringByResolvingSymlinksInPath];
        pt_leave_internal_scope();
        return ps_finalize_sanitized_nsstring_path(orig, resolvedOut, isSys, caller);
    }
    if (ps_is_virtual_ancestor_nsstring(orig)) {
        return ps_normalize_virtual_ancestor_nsstring(orig);
    }
    if (!isSys && ps_is_hidden_path(orig, caller)) {
        return ps_finalize_sanitized_nsstring_path(orig, orig, isSys, caller);
    }
    NSString *res = [self pm_ps2_stringByResolvingSymlinksInPath];
    return ps_finalize_sanitized_nsstring_path(orig, res, isSys, caller);
}

- (NSString *) pm_stringByStandardizingPath {
    const void *caller = __builtin_return_address(0);
    NSString *orig = (NSString *)self;
    BOOL isSys = ps_is_effective_system_or_playtools_caller(caller);
    if ([orig hasPrefix:@"~"]) {
        if (ps_is_unallowed_other_user_tilde(orig, caller)) {
            return orig;
        }
        NSString *res = [self pm_stringByStandardizingPath];
        return ps_finalize_sanitized_nsstring_path(orig, res, isSys, caller);
    }
    if (ps_is_virtual_container_nsstring(orig)) {
        NSString *resolvedIn = ps_resolve_virtual_nsstring_path(orig);
        if (!isSys && ps_is_hidden_path(resolvedIn, caller)) {
            return orig;
        }
        pt_enter_internal_scope();
        NSString *resolvedOut = [resolvedIn stringByStandardizingPath];
        pt_leave_internal_scope();
        return ps_finalize_sanitized_nsstring_path(orig, resolvedOut, isSys, caller);
    }
    if (ps_is_virtual_ancestor_nsstring(orig)) {
        return ps_normalize_virtual_ancestor_nsstring(orig);
    }
    if (!isSys && ps_is_hidden_path(orig, caller)) {
        return ps_finalize_sanitized_nsstring_path(orig, orig, isSys, caller);
    }
    NSString *res = [self pm_stringByStandardizingPath];
    return ps_finalize_sanitized_nsstring_path(orig, res, isSys, caller);
}

- (NSString *) pm_ps2_stringByStandardizingPath {
    const void *caller = __builtin_return_address(0);
    NSString *orig = (NSString *)self;
    BOOL isSys = ps_is_effective_system_or_playtools_caller(caller);
    if ([orig hasPrefix:@"~"]) {
        if (ps_is_unallowed_other_user_tilde(orig, caller)) {
            return orig;
        }
        NSString *res = [self pm_ps2_stringByStandardizingPath];
        return ps_finalize_sanitized_nsstring_path(orig, res, isSys, caller);
    }
    if (ps_is_virtual_container_nsstring(orig)) {
        NSString *resolvedIn = ps_resolve_virtual_nsstring_path(orig);
        if (!isSys && ps_is_hidden_path(resolvedIn, caller)) {
            return orig;
        }
        pt_enter_internal_scope();
        NSString *resolvedOut = [resolvedIn stringByStandardizingPath];
        pt_leave_internal_scope();
        return ps_finalize_sanitized_nsstring_path(orig, resolvedOut, isSys, caller);
    }
    if (ps_is_virtual_ancestor_nsstring(orig)) {
        return ps_normalize_virtual_ancestor_nsstring(orig);
    }
    if (!isSys && ps_is_hidden_path(orig, caller)) {
        return ps_finalize_sanitized_nsstring_path(orig, orig, isSys, caller);
    }
    NSString *res = [self pm_ps2_stringByStandardizingPath];
    return ps_finalize_sanitized_nsstring_path(orig, res, isSys, caller);
}

- (NSURL *) pm_URLByResolvingSymlinksInPath {
    const void *caller = __builtin_return_address(0);
    NSURL *selfURL = (NSURL *)self;
    BOOL isSys = ps_is_effective_system_or_playtools_caller(caller);
    if ([selfURL isFileURL]) {
        NSString *origPath = [selfURL path];
        if (ps_is_virtual_container_nsstring(origPath)) {
            NSURL *resolvedIn = ps_resolve_virtual_nsurl(selfURL);
            if (!isSys && ps_is_hidden_path([resolvedIn path], caller)) {
                return selfURL;
            }
            pt_enter_internal_scope();
            NSURL *resolvedOut = [(id)resolvedIn pm_URLByResolvingSymlinksInPath];
            pt_leave_internal_scope();
            return ps_finalize_sanitized_nsurl(selfURL, resolvedOut, isSys, caller);
        }
        if (ps_is_virtual_ancestor_nsstring(origPath)) {
            return ps_rebuild_file_nsurl(selfURL, ps_normalize_virtual_ancestor_nsstring(origPath));
        }
        if (!isSys && ps_is_hidden_path(origPath, caller)) {
            return ps_finalize_sanitized_nsurl(selfURL, selfURL, isSys, caller);
        }
    }
    NSURL *res = [self pm_URLByResolvingSymlinksInPath];
    return ps_finalize_sanitized_nsurl(selfURL, res, isSys, caller);
}

- (NSURL *) pm_URLByStandardizingPath {
    const void *caller = __builtin_return_address(0);
    NSURL *selfURL = (NSURL *)self;
    BOOL isSys = ps_is_effective_system_or_playtools_caller(caller);
    if ([selfURL isFileURL]) {
        NSString *origPath = [selfURL path];
        if (ps_is_virtual_container_nsstring(origPath)) {
            NSURL *resolvedIn = ps_resolve_virtual_nsurl(selfURL);
            if (!isSys && ps_is_hidden_path([resolvedIn path], caller)) {
                return selfURL;
            }
            pt_enter_internal_scope();
            NSURL *resolvedOut = [(id)resolvedIn pm_URLByStandardizingPath];
            pt_leave_internal_scope();
            return ps_finalize_sanitized_nsurl(selfURL, resolvedOut, isSys, caller);
        }
        if (ps_is_virtual_ancestor_nsstring(origPath)) {
            return ps_rebuild_file_nsurl(selfURL, ps_normalize_virtual_ancestor_nsstring(origPath));
        }
        if (!isSys && ps_is_hidden_path(origPath, caller)) {
            return ps_finalize_sanitized_nsurl(selfURL, selfURL, isSys, caller);
        }
    }
    NSURL *res = [self pm_URLByStandardizingPath];
    return ps_finalize_sanitized_nsurl(selfURL, res, isSys, caller);
}

- (NSURL *) pm_fileReferenceURL {
    const void *caller = __builtin_return_address(0);
    if (!pt_is_bypass_enabled() || ps_is_effective_system_or_playtools_caller(caller)) {
        return [self pm_fileReferenceURL];
    }
    NSURL *selfURL = (NSURL *)self;
    if ([selfURL isFileURL]) {
        NSString *origPath = [selfURL path];
        BOOL wasVirtual = (origPath != nil && ps_is_virtual_container_nsstring(origPath));
        NSURL *resolved = ps_resolve_virtual_nsurl(selfURL);
        NSString *resolvedPath = [resolved isFileURL] ? [resolved path] : nil;
        if (resolvedPath != nil && ps_is_hidden_path(resolvedPath, caller)) {
            return nil;
        }
        if (!wasVirtual &&
            (ps_is_virtual_ancestor_nsstring(resolvedPath) || ps_is_virtual_ancestor_nsstring(origPath))) {
            return ps_rebuild_file_nsurl(selfURL, ps_normalize_virtual_ancestor_nsstring(origPath ?: resolvedPath));
        }
        if (resolved != selfURL) {
            return [(id)resolved pm_fileReferenceURL];
        }
    }
    return [self pm_fileReferenceURL];
}

- (NSURL *) pm_filePathURL {
    const void *caller = __builtin_return_address(0);
    if (!pt_is_bypass_enabled() || ps_is_effective_system_or_playtools_caller(caller)) {
        return [self pm_filePathURL];
    }
    NSURL *selfURL = (NSURL *)self;
    BOOL usePrivatePrefix = NO;
    if ([selfURL isFileURL]) {
        NSString *origPath = [selfURL path];
        if (origPath.length > 0) {
            if (ps_is_hidden_path(origPath, caller)) {
                return nil;
            }
            if (ps_is_virtual_ancestor_nsstring(origPath)) {
                return ps_rebuild_file_nsurl(selfURL, ps_normalize_virtual_ancestor_nsstring(origPath));
            }
            usePrivatePrefix = [origPath hasPrefix:@"/private/"];
        }
    }
    NSURL *res = [self pm_filePathURL];
    BOOL isHidden = NO;
    NSURL *sanitized = ps_sanitize_file_path_nsurl(res, usePrivatePrefix, caller, &isHidden);
    return isHidden ? nil : sanitized;
}


- (void) pm_ql_setDataSource:(id)dataSource {
    if (dataSource == nil || [dataSource isKindOfClass:[PSQLDataSourceProxy class]]) {
        objc_setAssociatedObject(self, &kPSQLProxyAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self pm_ql_setDataSource:dataSource];
        return;
    }
    PSQLDataSourceProxy *proxy = [[PSQLDataSourceProxy alloc] init];
    proxy.target = dataSource;
    objc_setAssociatedObject(self, &kPSQLProxyAssocKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self pm_ql_setDataSource:proxy];
}

- (id) pm_ql_dataSource {
    const void *caller = __builtin_return_address(0);
    id raw = [self pm_ql_dataSource];
    if ([raw isKindOfClass:[PSQLDataSourceProxy class]] &&
        !ps_is_effective_system_or_playtools_caller(caller)) {
        return ((PSQLDataSourceProxy *)raw).target;
    }
    return raw;
}

- (instancetype) pm_dic_initWithURL:(NSURL *)url {
    return [self pm_dic_initWithURL:ps_resolve_virtual_nsurl(url)];
}

- (void) pm_dic_setURL:(NSURL *)url {
    [self pm_dic_setURL:ps_resolve_virtual_nsurl(url)];
}

- (NSURL *) pm_dic_URL {
    return ps_virtualize_bundle_url_for_caller([self pm_dic_URL], __builtin_return_address(0));
}

- (instancetype) pm_initWithActivityItems:(NSArray *)activityItems
                    applicationActivities:(NSArray *)applicationActivities {
    if (activityItems.count > 0) {
        NSMutableArray *resolvedItems = nil;
        for (NSUInteger i = 0; i < activityItems.count; i++) {
            id item = activityItems[i];
            if ([item isKindOfClass:[NSURL class]] && [(NSURL *)item isFileURL]) {
                NSURL *resolved = ps_resolve_virtual_nsurl((NSURL *)item);
                if (resolved != nil && resolved != item && ![resolved isEqual:item]) {
                    if (resolvedItems == nil) {
                        resolvedItems = [activityItems mutableCopy];
                    }
                    resolvedItems[i] = resolved;
                }
            }
        }
        if (resolvedItems != nil) {
            return [self pm_initWithActivityItems:resolvedItems applicationActivities:applicationActivities];
        }
    }
    return [self pm_initWithActivityItems:activityItems applicationActivities:applicationActivities];
}


@end


__attribute__((visibility("hidden"))) void ps_install_quicklook_hooks_if_loaded(void) {
    Class qlCls = objc_getClass("QLPreviewController");
    if (qlCls != nil) {
        static dispatch_once_t qlOnce;
        dispatch_once(&qlOnce, ^{
            ps_swizzle_instance_method(qlCls, @selector(setDataSource:),
                                       @selector(pm_ql_setDataSource:));
            ps_swizzle_instance_method(qlCls, @selector(dataSource),
                                       @selector(pm_ql_dataSource));
        });
    }
    Class dicCls = objc_getClass("UIDocumentInteractionController");
    if (dicCls != nil) {
        static dispatch_once_t dicOnce;
        dispatch_once(&dicOnce, ^{
            ps_swizzle_instance_method(dicCls, @selector(initWithURL:),
                                       @selector(pm_dic_initWithURL:));
            ps_swizzle_instance_method(dicCls, @selector(setURL:),
                                       @selector(pm_dic_setURL:));
            if (class_getInstanceMethod(dicCls, @selector(URL)) != NULL) {
                ps_swizzle_instance_method(dicCls, @selector(URL),
                                           @selector(pm_dic_URL));
            }
        });
    }
    Class actCls = objc_getClass("UIActivityViewController");
    if (actCls != nil) {
        static dispatch_once_t actOnce;
        dispatch_once(&actOnce, ^{
            ps_swizzle_instance_method(actCls, @selector(initWithActivityItems:applicationActivities:),
                                       @selector(pm_initWithActivityItems:applicationActivities:));
        });
    }
}

__attribute__((constructor))
static void pt_fs_objc_install_volume_hooks(void) {
    static dispatch_once_t volOnce;
    dispatch_once(&volOnce, ^{
        Class fmCls = objc_getClass("NSFileManager");
        if (fmCls != Nil &&
            class_getInstanceMethod(fmCls, @selector(mountedVolumeURLsIncludingResourceValuesForKeys:options:)) != NULL) {
            ps_swizzle_instance_method(fmCls,
                                       @selector(mountedVolumeURLsIncludingResourceValuesForKeys:options:),
                                       @selector(pm_mountedVolumeURLsIncludingResourceValuesForKeys:options:));
        }
        if (fmCls != Nil &&
            class_getInstanceMethod(fmCls, @selector(attributesOfFileSystemForPath:error:)) != NULL) {
            ps_swizzle_instance_method(fmCls,
                                       @selector(attributesOfFileSystemForPath:error:),
                                       @selector(pm_attributesOfFileSystemForPath:error:));
        }
    });
}

static BOOL ps_assign_virtualized_cferror(CFErrorRef *outError,
                                          CFErrorRef CF_CONSUMED rawError,
                                          BOOL usePrivatePrefix,
                                          BOOL forceVirtualize,
                                          const void *caller) {
    if (rawError == NULL) {
        return NO;
    }
    if (outError == NULL) {
        CFRelease(rawError);
        return YES;
    }
    NSError *nsErr = (__bridge_transfer NSError *)rawError;
    NSError *virtErr = nil;
    ps_assign_virtualized_nserror(&virtErr, nsErr, usePrivatePrefix, forceVirtualize, caller);
    *outError = (virtErr != nil) ? (__bridge_retained CFErrorRef)virtErr : NULL;
    return (*outError != NULL);
}

__attribute__((visibility("hidden")))
Boolean pt_CFURLCopyResourcePropertyForKey(CFURLRef url,
                                           CFStringRef key,
                                           void *propertyValueTypeRefPtr,
                                           CFErrorRef *error) {
    const void *caller = __builtin_return_address(0);
    if (url == NULL || key == NULL ||
        !pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(caller)) {
        return CFURLCopyResourcePropertyForKey(url, key, propertyValueTypeRefPtr, error);
    }
    NSURL *origURL = (__bridge NSURL *)url;
    NSString *origPath = [origURL isFileURL] ? [origURL path] : nil;
    BOOL wasVirtual = NO, usePrivatePrefix = NO, usedBackup = NO;
    NSURL *resolvedURL = ps_resolve_readonly_nsurl_and_backup(
        origURL, caller, &wasVirtual, &usePrivatePrefix, &usedBackup);
    NSString *resolvedPath = [resolvedURL isFileURL] ? [resolvedURL path] : nil;
    if (!usedBackup && resolvedPath != nil && ps_is_hidden_path(resolvedPath, caller)) {
        if (propertyValueTypeRefPtr != NULL) {
            *(CFTypeRef *)propertyValueTypeRefPtr = NULL;
        }
        if (error != NULL) {
            *error = CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainCocoa, NSFileReadNoSuchFileError, NULL);
        }
        return false;
    }
    if (!wasVirtual && [origURL isFileURL] &&
        (ps_is_virtual_ancestor_nsstring(resolvedPath) || ps_is_virtual_ancestor_nsstring(origPath))) {
        BOOL handled = NO;
        id v = ps_virtual_ancestor_resource_value_for_key(origPath ?: resolvedPath,
                                                          (__bridge NSURLResourceKey)key,
                                                          &handled);
        if (handled) {
            if (propertyValueTypeRefPtr != NULL) {
                *(CFTypeRef *)propertyValueTypeRefPtr = (v != nil) ? CFBridgingRetain(v) : NULL;
            }
            return true;
        }
        NSURL *backingURL = [NSURL fileURLWithPath:@"/private/var" isDirectory:YES];
        CFErrorRef localErr = NULL;
        Boolean okAnc = CFURLCopyResourcePropertyForKey((__bridge CFURLRef)backingURL,
                                                        key,
                                                        propertyValueTypeRefPtr,
                                                        (error != NULL) ? &localErr : NULL);
        if (!okAnc) {
            ps_assign_virtualized_cferror(error, localErr, usePrivatePrefix, YES, caller);
            return false;
        }
        if (propertyValueTypeRefPtr != NULL) {
            CFTypeRef rawVal = *(CFTypeRef *)propertyValueTypeRefPtr;
            if (rawVal != NULL) {
                id objVal = (__bridge id)rawVal;
                id cleanVal = ps_sanitize_url_resource_value(origURL, (__bridge NSURLResourceKey)key, objVal, usePrivatePrefix, caller);
                if (cleanVal != objVal && ![cleanVal isEqual:objVal]) {
                    CFRelease(rawVal);
                    *(CFTypeRef *)propertyValueTypeRefPtr = (cleanVal != nil) ? CFBridgingRetain(cleanVal) : NULL;
                }
            }
        }
        return true;
    }
    CFURLRef queryURL = (resolvedURL != nil) ? (__bridge CFURLRef)resolvedURL : url;
    CFErrorRef localErr = NULL;
    Boolean ok = false;
    if (usedBackup) {
        pt_enter_internal_scope();
        ok = CFURLCopyResourcePropertyForKey(queryURL,
                                             key,
                                             propertyValueTypeRefPtr,
                                             (error != NULL) ? &localErr : NULL);
        pt_leave_internal_scope();
    } else {
        ok = CFURLCopyResourcePropertyForKey(queryURL,
                                             key,
                                             propertyValueTypeRefPtr,
                                             (error != NULL) ? &localErr : NULL);
    }
    if (!ok) {
        ps_assign_virtualized_cferror(error, localErr, usePrivatePrefix, wasVirtual, caller);
        return false;
    }
    if (ok && propertyValueTypeRefPtr != NULL) {
        CFTypeRef rawVal = *(CFTypeRef *)propertyValueTypeRefPtr;
        if (rawVal != NULL) {
            id objVal = (__bridge id)rawVal;
            id cleanVal = ps_sanitize_url_resource_value(origURL, (__bridge NSURLResourceKey)key, objVal, usePrivatePrefix, caller);
            if (cleanVal != objVal && ![cleanVal isEqual:objVal]) {
                CFRelease(rawVal);
                *(CFTypeRef *)propertyValueTypeRefPtr = (cleanVal != nil) ? CFBridgingRetain(cleanVal) : NULL;
            }
        } else if (CFEqual(key, (__bridge CFStringRef)NSURLFileProtectionKey)) {
            NSString *prot = ps_synthesized_file_protection_for_path(
                [resolvedURL isFileURL] ? [resolvedURL path] : nil,
                [resolvedURL hasDirectoryPath]);
            *(CFTypeRef *)propertyValueTypeRefPtr = CFBridgingRetain(prot);
        }
    }
    return ok;
}

__attribute__((visibility("hidden")))
CFDictionaryRef pt_CFURLCopyResourcePropertiesForKeys(CFURLRef url,
                                                      CFArrayRef keys,
                                                      CFErrorRef *error) {
    const void *caller = __builtin_return_address(0);
    if (url == NULL ||
        !pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(caller)) {
        return CFURLCopyResourcePropertiesForKeys(url, keys, error);
    }
    NSURL *origURL = (__bridge NSURL *)url;
    NSString *origPath = [origURL isFileURL] ? [origURL path] : nil;
    BOOL wasVirtual = NO, usePrivatePrefix = NO, usedBackup = NO;
    NSURL *resolvedURL = ps_resolve_readonly_nsurl_and_backup(
        origURL, caller, &wasVirtual, &usePrivatePrefix, &usedBackup);
    NSString *resolvedPath = [resolvedURL isFileURL] ? [resolvedURL path] : nil;
    if (!usedBackup && resolvedPath != nil && ps_is_hidden_path(resolvedPath, caller)) {
        if (error != NULL) {
            *error = CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainCocoa, NSFileReadNoSuchFileError, NULL);
        }
        return NULL;
    }
    if (!wasVirtual && [origURL isFileURL] &&
        (ps_is_virtual_ancestor_nsstring(resolvedPath) || ps_is_virtual_ancestor_nsstring(origPath))) {
        NSArray<NSURLResourceKey> *nsKeys = (__bridge NSArray<NSURLResourceKey> *)keys;
        NSMutableDictionary<NSURLResourceKey, id> *synth = [NSMutableDictionary dictionaryWithCapacity:nsKeys.count];
        NSMutableArray<NSURLResourceKey> *fallbackKeys = nil;
        for (NSURLResourceKey k in nsKeys) {
            BOOL handled = NO;
            id v = ps_virtual_ancestor_resource_value_for_key(origPath ?: resolvedPath, k, &handled);
            if (handled) {
                if (v != nil) {
                    synth[k] = v;
                }
            } else {
                if (fallbackKeys == nil) {
                    fallbackKeys = [NSMutableArray array];
                }
                [fallbackKeys addObject:k];
            }
        }
        if (fallbackKeys.count > 0) {
            NSURL *backingURL = [NSURL fileURLWithPath:@"/private/var" isDirectory:YES];
            CFDictionaryRef backingRef = CFURLCopyResourcePropertiesForKeys((__bridge CFURLRef)backingURL,
                                                                            (__bridge CFArrayRef)fallbackKeys,
                                                                            NULL);
            if (backingRef != NULL) {
                NSDictionary<NSURLResourceKey, id> *backingVals = (__bridge_transfer NSDictionary<NSURLResourceKey, id> *)backingRef;
                for (NSURLResourceKey bk in backingVals) {
                    id bval = ps_sanitize_url_resource_value(origURL, bk, backingVals[bk], usePrivatePrefix, caller);
                    if (bval != nil) {
                        synth[bk] = bval;
                    }
                }
            }
        }
        return (__bridge_retained CFDictionaryRef)[synth copy];
    }
    CFURLRef queryURL = (resolvedURL != nil) ? (__bridge CFURLRef)resolvedURL : url;
    CFErrorRef localErr = NULL;
    CFDictionaryRef dictRef = NULL;
    if (usedBackup) {
        pt_enter_internal_scope();
        dictRef = CFURLCopyResourcePropertiesForKeys(queryURL,
                                                     keys,
                                                     (error != NULL) ? &localErr : NULL);
        pt_leave_internal_scope();
    } else {
        dictRef = CFURLCopyResourcePropertiesForKeys(queryURL,
                                                     keys,
                                                     (error != NULL) ? &localErr : NULL);
    }
    if (dictRef == NULL) {
        ps_assign_virtualized_cferror(error, localErr, usePrivatePrefix, wasVirtual, caller);
        return NULL;
    }
    NSDictionary *dict = (__bridge NSDictionary *)dictRef;
    NSMutableDictionary *mapped = nil;
    for (NSURLResourceKey k in dict) {
        id val = dict[k];
        id cleanVal = ps_sanitize_url_resource_value(origURL, k, val, usePrivatePrefix, caller);
        if (cleanVal != val && ![cleanVal isEqual:val]) {
            if (mapped == nil) {
                mapped = [dict mutableCopy];
            }
            mapped[k] = cleanVal;
        }
    }
    if (keys != NULL &&
        CFArrayContainsValue(keys, CFRangeMake(0, CFArrayGetCount(keys)), (__bridge CFStringRef)NSURLFileProtectionKey) &&
        (mapped ?: dict)[(__bridge id)(__bridge CFStringRef)NSURLFileProtectionKey] == nil) {
        if (mapped == nil) {
            mapped = [dict mutableCopy];
        }
        mapped[(__bridge id)(__bridge CFStringRef)NSURLFileProtectionKey] = ps_synthesized_file_protection_for_path(
            [resolvedURL isFileURL] ? [resolvedURL path] : nil,
            [resolvedURL hasDirectoryPath]);
    }
    if (mapped != nil) {
        CFRelease(dictRef);
        return (__bridge_retained CFDictionaryRef)[mapped copy];
    }
    return dictRef;
}

__attribute__((visibility("hidden")))
Boolean pt_CFURLSetResourcePropertyForKey(CFURLRef url,
                                          CFStringRef key,
                                          CFTypeRef propertyValue,
                                          CFErrorRef *error) {
    const void *caller = __builtin_return_address(0);
    if (url == NULL || key == NULL ||
        !pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(caller)) {
        return CFURLSetResourcePropertyForKey(url, key, propertyValue, error);
    }
    NSURL *origURL = (__bridge NSURL *)url;
    if (![origURL isFileURL]) {
        return CFURLSetResourcePropertyForKey(url, key, propertyValue, error);
    }
    NSString *origPath = [origURL path];
    BOOL wasVirtual = (origPath != nil && ps_is_virtual_container_nsstring(origPath));
    BOOL usePrivatePrefix = (origPath != nil && [origPath hasPrefix:@"/private/"]);
    NSURL *resolvedURL = ps_resolve_virtual_nsurl(origURL);
    NSString *resolvedPath = [resolvedURL path];
    if (ps_is_hidden_path(resolvedPath, caller)) {
        if (error != NULL) {
            *error = CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainCocoa, NSFileNoSuchFileError, NULL);
        }
        return false;
    }
    if (!wasVirtual && (ps_is_virtual_ancestor_nsstring(resolvedPath) || ps_is_virtual_ancestor_nsstring(origPath))) {
        if (error != NULL) {
            *error = CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainCocoa, NSFileWriteNoPermissionError, NULL);
        }
        return false;
    }
    if (CFEqual(key, (__bridge CFStringRef)NSURLFileProtectionKey)) {
        int dp = ps_dpclass_from_file_protection((__bridge id)propertyValue);
        if (dp > 0 && resolvedPath.length > 0) {
            char raw[PATH_MAX];
            struct stat st;
            if (CFStringGetFileSystemRepresentation((__bridge CFStringRef)resolvedPath, raw, sizeof(raw)) &&
                stat(raw, &st) == 0) {
                pt_record_stat_dpclass(st.st_dev, st.st_ino, dp);
            }
        }
    }
    CFURLRef targetURL = (resolvedURL != nil) ? (__bridge CFURLRef)resolvedURL : url;
    CFErrorRef localErr = NULL;
    Boolean ok = CFURLSetResourcePropertyForKey(targetURL, key, propertyValue, error != NULL ? &localErr : NULL);
    if (!ok) {
        ps_assign_virtualized_cferror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return ok;
}

__attribute__((visibility("hidden")))
Boolean pt_CFURLSetResourcePropertiesForKeys(CFURLRef url,
                                             CFDictionaryRef keyedPropertyValues,
                                             CFErrorRef *error) {
    const void *caller = __builtin_return_address(0);
    if (url == NULL ||
        !pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(caller)) {
        return CFURLSetResourcePropertiesForKeys(url, keyedPropertyValues, error);
    }
    NSURL *origURL = (__bridge NSURL *)url;
    if (![origURL isFileURL]) {
        return CFURLSetResourcePropertiesForKeys(url, keyedPropertyValues, error);
    }
    NSString *origPath = [origURL path];
    BOOL wasVirtual = (origPath != nil && ps_is_virtual_container_nsstring(origPath));
    BOOL usePrivatePrefix = (origPath != nil && [origPath hasPrefix:@"/private/"]);
    NSURL *resolvedURL = ps_resolve_virtual_nsurl(origURL);
    NSString *resolvedPath = [resolvedURL path];
    if (ps_is_hidden_path(resolvedPath, caller)) {
        if (error != NULL) {
            *error = CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainCocoa, NSFileNoSuchFileError, NULL);
        }
        return false;
    }
    if (!wasVirtual && (ps_is_virtual_ancestor_nsstring(resolvedPath) || ps_is_virtual_ancestor_nsstring(origPath))) {
        if (error != NULL) {
            *error = CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainCocoa, NSFileWriteNoPermissionError, NULL);
        }
        return false;
    }
    if (keyedPropertyValues != NULL) {
        NSDictionary *dict = (__bridge NSDictionary *)keyedPropertyValues;
        int dp = ps_dpclass_from_file_protection(dict[(__bridge id)(__bridge CFStringRef)NSURLFileProtectionKey]);
        if (dp > 0 && resolvedPath.length > 0) {
            char raw[PATH_MAX];
            struct stat st;
            if (CFStringGetFileSystemRepresentation((__bridge CFStringRef)resolvedPath, raw, sizeof(raw)) &&
                stat(raw, &st) == 0) {
                pt_record_stat_dpclass(st.st_dev, st.st_ino, dp);
            }
        }
    }
    CFURLRef targetURL = (resolvedURL != nil) ? (__bridge CFURLRef)resolvedURL : url;
    CFErrorRef localErr = NULL;
    Boolean ok = CFURLSetResourcePropertiesForKeys(targetURL, keyedPropertyValues, error != NULL ? &localErr : NULL);
    if (!ok) {
        ps_assign_virtualized_cferror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return ok;
}

__attribute__((visibility("hidden")))
CFURLRef pt_CFURLCreateFileReferenceURL(CFAllocatorRef allocator, CFURLRef url, CFErrorRef *error) {
    const void *caller = __builtin_return_address(0);
    if (url == NULL ||
        !pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(caller)) {
        return CFURLCreateFileReferenceURL(allocator, url, error);
    }
    NSURL *origURL = (__bridge NSURL *)url;
    if (![origURL isFileURL]) {
        return CFURLCreateFileReferenceURL(allocator, url, error);
    }
    NSString *origPath = [origURL path];
    BOOL wasVirtual = (origPath != nil && ps_is_virtual_container_nsstring(origPath));
    BOOL usePrivatePrefix = (origPath != nil && [origPath hasPrefix:@"/private/"]);
    NSURL *resolvedURL = ps_resolve_virtual_nsurl(origURL);
    NSString *resolvedPath = [resolvedURL path];
    if (ps_is_hidden_path(resolvedPath, caller)) {
        if (error != NULL) {
            *error = CFErrorCreate(allocator, kCFErrorDomainCocoa, NSFileReadNoSuchFileError, NULL);
        }
        return NULL;
    }
    if (!wasVirtual && (ps_is_virtual_ancestor_nsstring(resolvedPath) || ps_is_virtual_ancestor_nsstring(origPath))) {
        NSURL *anc = ps_rebuild_file_nsurl(origURL, ps_normalize_virtual_ancestor_nsstring(origPath ?: resolvedPath));
        return (__bridge_retained CFURLRef)anc;
    }
    CFURLRef targetURL = (resolvedURL != nil) ? (__bridge CFURLRef)resolvedURL : url;
    CFErrorRef localErr = NULL;
    CFURLRef refURL = CFURLCreateFileReferenceURL(allocator, targetURL, error != NULL ? &localErr : NULL);
    if (refURL == NULL) {
        ps_assign_virtualized_cferror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return refURL;
}

PT_INTERPOSE(pt_CFURLCopyResourcePropertyForKey, CFURLCopyResourcePropertyForKey)
PT_INTERPOSE(pt_CFURLCopyResourcePropertiesForKeys, CFURLCopyResourcePropertiesForKeys)
PT_INTERPOSE(pt_CFURLSetResourcePropertyForKey, CFURLSetResourcePropertyForKey)
PT_INTERPOSE(pt_CFURLSetResourcePropertiesForKeys, CFURLSetResourcePropertiesForKeys)
PT_INTERPOSE(pt_CFURLCreateFileReferenceURL, CFURLCreateFileReferenceURL)
