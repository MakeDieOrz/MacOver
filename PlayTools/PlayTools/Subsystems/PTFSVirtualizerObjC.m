//
//  PTFSVirtualizerObjC.m
//  PlayTools
//

#import "PSInternal.h"

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

static NSURL *ps_rebuild_file_nsurl(NSURL *origURL, NSString *newPath) {
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
    return pt_is_hidden_path(raw, caller);
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

static NSString *ps_guess_mime_type_for_path(NSString *path) {
    NSString *ext = [[path pathExtension] lowercaseString];
    if (ext.length == 0) {
        return @"application/octet-stream";
    }
    static NSDictionary<NSString *, NSString *> *s_mimeMap = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_mimeMap = @{
            @"png": @"image/png",
            @"jpg": @"image/jpeg",
            @"jpeg": @"image/jpeg",
            @"gif": @"image/gif",
            @"webp": @"image/webp",
            @"svg": @"image/svg+xml",
            @"avif": @"image/avif",
            @"bmp": @"image/bmp",
            @"ico": @"image/x-icon",
            @"heic": @"image/heic",
            @"heif": @"image/heif",
            @"tif": @"image/tiff",
            @"tiff": @"image/tiff",
            @"mp4": @"video/mp4",
            @"m4v": @"video/x-m4v",
            @"mov": @"video/quicktime",
            @"webm": @"video/webm",
            @"mp3": @"audio/mpeg",
            @"m4a": @"audio/mp4",
            @"aac": @"audio/aac",
            @"wav": @"audio/wav",
            @"ogg": @"audio/ogg",
            @"opus": @"audio/opus",
            @"pdf": @"application/pdf",
            @"html": @"text/html; charset=utf-8",
            @"htm": @"text/html; charset=utf-8",
            @"css": @"text/css; charset=utf-8",
            @"js": @"text/javascript; charset=utf-8",
            @"mjs": @"text/javascript; charset=utf-8",
            @"json": @"application/json; charset=utf-8",
            @"xml": @"application/xml; charset=utf-8",
            @"txt": @"text/plain; charset=utf-8",
            @"wasm": @"application/wasm",
            @"woff": @"font/woff",
            @"woff2": @"font/woff2",
            @"ttf": @"font/ttf",
            @"otf": @"font/otf"
        };
    });
    return s_mimeMap[ext] ?: @"application/octet-stream";
}

static const char kPSVFileTaskStateAssocKey = 0;

__attribute__((visibility("hidden")))
@interface PSVFileTaskState : NSObject {
@public
    _Atomic BOOL _active;
    dispatch_semaphore_t _flowSem;
}
@end

@implementation PSVFileTaskState
- (instancetype)init {
    self = [super init];
    if (self != nil) {
        atomic_store_explicit(&_active, true, memory_order_relaxed);
        _flowSem = dispatch_semaphore_create(0);
    }
    return self;
}
@end

static inline PSVFileTaskState *ps_vfile_track_task_start(id task) {
    if (task == nil) return nil;
    PSVFileTaskState *state = [[PSVFileTaskState alloc] init];
    objc_setAssociatedObject(task, &kPSVFileTaskStateAssocKey, state, OBJC_ASSOCIATION_RETAIN);
    return state;
}

static inline BOOL ps_vfile_is_state_active(PSVFileTaskState *state) {
    return (state != nil && atomic_load_explicit(&state->_active, memory_order_acquire));
}

static inline BOOL ps_vfile_claim_state_done(PSVFileTaskState *state) {
    if (state == nil) return NO;
    BOOL wasActive = atomic_exchange_explicit(&state->_active, false, memory_order_acq_rel);
    if (wasActive && state->_flowSem != nil) {
        dispatch_semaphore_signal(state->_flowSem);
    }
    return wasActive;
}

static void ps_vfile_fail_on_main(id urlSchemeTask, PSVFileTaskState *state, NSError *err) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!ps_vfile_claim_state_done(state)) {
            return;
        }
        objc_setAssociatedObject(urlSchemeTask, &kPSVFileTaskStateAssocKey, nil, OBJC_ASSOCIATION_RETAIN);
        @try {
            SEL failSel = @selector(didFailWithError:);
            if ([urlSchemeTask respondsToSelector:failSel]) {
                ((void (*)(id, SEL, NSError *))objc_msgSend)(urlSchemeTask, failSel, err);
            }
        } @catch (NSException *exception) {
            (void)exception;
        }
    });
}

static NSOperationQueue *ps_vfile_operation_queue(void) {
    static NSOperationQueue *s_ioQueue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_ioQueue = [[NSOperationQueue alloc] init];
        s_ioQueue.name = @"app.makedie.PlayShadow.vfile.io";
        s_ioQueue.maxConcurrentOperationCount = 6;
        s_ioQueue.qualityOfService = NSQualityOfServiceUserInitiated;
    });
    return s_ioQueue;
}

static BOOL ps_vfile_parse_uint64(NSString *str, uint64_t *outVal) {
    if (str == nil || str.length == 0) {
        return NO;
    }
    uint64_t val = 0;
    for (NSUInteger i = 0; i < str.length; i++) {
        unichar ch = [str characterAtIndex:i];
        if (ch < '0' || ch > '9') {
            return NO;
        }
        uint64_t digit = (uint64_t)(ch - '0');
        if (val > (UINT64_MAX - digit) / 10ULL) {
            return NO;
        }
        val = val * 10ULL + digit;
    }
    if (outVal != NULL) {
        *outVal = val;
    }
    return YES;
}

__attribute__((visibility("hidden"))) const char kPSWKReadScopeAssocKey = 0;

__attribute__((visibility("hidden")))

@implementation PSVirtualFileReadScope
@end

__attribute__((visibility("hidden"))) os_unfair_lock s_wkCanonRootsLock = OS_UNFAIR_LOCK_INIT;
__attribute__((visibility("hidden"))) NSMutableArray<NSString *> *s_wkCanonContainerRoots = nil;
static BOOL s_wkDataRootSeeded = NO;
static BOOL s_wkBundleRootSeeded = NO;

__attribute__((visibility("hidden"))) BOOL ps_real_path_matches_or_under(NSString *candidate, NSString *root, BOOL allowSubtree);

__attribute__((visibility("hidden"))) NSString *ps_extract_virtual_container_root(NSString *virtPath) {
    if (virtPath.length == 0) {
        return nil;
    }
    NSString *work = virtPath;
    if ([work hasPrefix:@"/private/var/"]) {
        work = [work substringFromIndex:8];
    }
    if ([work hasPrefix:@"/var/mobile/Containers/Data/Application/"] ||
        [work hasPrefix:@"/var/mobile/Containers/Shared/AppGroup/"]) {
        NSString *prefix = [work hasPrefix:@"/var/mobile/Containers/Data/Application/"]
            ? @"/var/mobile/Containers/Data/Application/"
            : @"/var/mobile/Containers/Shared/AppGroup/";
        NSUInteger start = prefix.length;
        if (work.length <= start) {
            return nil;
        }
        NSRange slash = [work rangeOfString:@"/" options:0 range:NSMakeRange(start, work.length - start)];
        NSUInteger end = (slash.location != NSNotFound) ? slash.location : work.length;
        return (end > start) ? [work substringToIndex:end] : nil;
    }
    NSString *bundlePrefix = @"/var/containers/Bundle/Application/";
    if ([work hasPrefix:bundlePrefix]) {
        NSUInteger start = bundlePrefix.length;
        if (work.length <= start) {
            return nil;
        }
        NSRange uuidSlash = [work rangeOfString:@"/" options:0 range:NSMakeRange(start, work.length - start)];
        if (uuidSlash.location == NSNotFound || uuidSlash.location + 1 >= work.length) {
            return nil;
        }
        NSUInteger appStart = uuidSlash.location + 1;
        NSRange appSlash = [work rangeOfString:@"/" options:0 range:NSMakeRange(appStart, work.length - appStart)];
        NSUInteger end = (appSlash.location != NSNotFound) ? appSlash.location : work.length;
        return (end > appStart) ? [work substringToIndex:end] : nil;
    }
    return nil;
}

static NSString *ps_record_wk_canon_container_root(NSString *realRoot) {
    if (realRoot.length == 0) {
        return nil;
    }
    NSURL *u = [[NSURL fileURLWithPath:realRoot] URLByResolvingSymlinksInPath];
    NSString *canon = u.path;
    if (canon.length > 1 && [canon hasSuffix:@"/"]) {
        canon = [canon substringToIndex:canon.length - 1];
    }
    if (canon.length == 0 || [canon isEqualToString:@"/"] || ps_is_hidden_path(canon, NULL)) {
        return nil;
    }
    os_unfair_lock_lock(&s_wkCanonRootsLock);
    if (s_wkCanonContainerRoots == nil) {
        s_wkCanonContainerRoots = [NSMutableArray array];
    }
    if (![s_wkCanonContainerRoots containsObject:canon] && s_wkCanonContainerRoots.count < 64) {
        [s_wkCanonContainerRoots addObject:canon];
    }
    os_unfair_lock_unlock(&s_wkCanonRootsLock);
    return canon;
}

__attribute__((visibility("hidden"))) void ps_seed_wk_canon_container_roots(void) {
    os_unfair_lock_lock(&s_wkCanonRootsLock);
    BOOL needData = !s_wkDataRootSeeded;
    BOOL needBundle = !s_wkBundleRootSeeded;
    os_unfair_lock_unlock(&s_wkCanonRootsLock);

    if (needData) {
        const char *vh = pt_get_virtual_home_cstr();
        if (vh != NULL && vh[0] == '/') {
            NSString *vHome = [NSString stringWithUTF8String:vh];
            NSString *rHome = ps_resolve_virtual_nsstring_path(vHome);
            if (rHome.length > 0 && ![rHome isEqualToString:vHome]) {
                ps_record_wk_canon_container_root(rHome);
                os_unfair_lock_lock(&s_wkCanonRootsLock);
                s_wkDataRootSeeded = YES;
                os_unfair_lock_unlock(&s_wkCanonRootsLock);
            }
        }
    }
    if (needBundle) {
        NSString *bPath = [[NSBundle mainBundle] bundlePath];
        if (bPath.length > 0) {
            ps_record_wk_canon_container_root(bPath);
            os_unfair_lock_lock(&s_wkCanonRootsLock);
            s_wkBundleRootSeeded = YES;
            os_unfair_lock_unlock(&s_wkCanonRootsLock);
        }
    }
}

__attribute__((visibility("hidden"))) NSString *ps_canonical_container_real_path_from_url(NSURL *url) {
    if (url == nil || ![url isFileURL]) {
        return nil;
    }
    ps_seed_wk_canon_container_roots();

    NSURL *resolved = ps_resolve_virtual_nsurl(url);
    NSString *preCanonPath = resolved.path;
    NSURL *canon = [resolved URLByResolvingSymlinksInPath];
    NSString *realPath = canon.path;
    if (realPath.length == 0 || ps_is_hidden_path(realPath, NULL)) {
        return nil;
    }

    NSString *preVirt = (preCanonPath.length > 0) ? ps_virtualize_nsstring_path_for_app(preCanonPath, YES) : nil;
    BOOL mappedBefore = (preVirt.length > 0 && ps_is_virtual_container_nsstring(preVirt));
    if (mappedBefore) {
        NSString *virtRoot = ps_extract_virtual_container_root(preVirt);
        if (virtRoot.length > 0) {
            NSString *realRoot = ps_resolve_virtual_nsstring_path(virtRoot);
            NSString *canonRoot = (realRoot.length > 0 && ![realRoot isEqualToString:virtRoot])
                ? ps_record_wk_canon_container_root(realRoot)
                : nil;
            if (canonRoot.length > 0 && ps_real_path_matches_or_under(realPath, canonRoot, YES)) {
                return realPath;
            }
        }
    }

    NSString *postVirt = ps_virtualize_nsstring_path_for_app(realPath, YES);
    if (postVirt.length > 0 && ps_is_virtual_container_nsstring(postVirt)) {
        NSString *virtRoot = ps_extract_virtual_container_root(postVirt);
        if (virtRoot.length > 0) {
            NSString *realRoot = ps_resolve_virtual_nsstring_path(virtRoot);
            if (realRoot.length > 0 && ![realRoot isEqualToString:virtRoot]) {
                ps_record_wk_canon_container_root(realRoot);
            }
        }
        return realPath;
    }

    os_unfair_lock_lock(&s_wkCanonRootsLock);
    NSArray<NSString *> *roots = [s_wkCanonContainerRoots copy];
    os_unfair_lock_unlock(&s_wkCanonRootsLock);
    for (NSString *knownRoot in roots) {
        if (ps_real_path_matches_or_under(realPath, knownRoot, YES)) {
            return realPath;
        }
    }
    return nil;
}

__attribute__((visibility("hidden"))) BOOL ps_real_path_matches_or_under(NSString *candidate, NSString *root, BOOL allowSubtree) {
    if (candidate.length == 0 || root.length == 0) {
        return NO;
    }
    if ([candidate isEqualToString:root]) {
        return YES;
    }
    if (!allowSubtree) {
        return NO;
    }
    if ([root isEqualToString:@"/"]) {
        return NO;
    }
    if (candidate.length > root.length &&
        [candidate hasPrefix:root] &&
        [candidate characterAtIndex:root.length] == '/') {
        return YES;
    }
    return NO;
}

static BOOL ps_real_path_is_allowed_by_scope(NSString *realPath, PSVirtualFileReadScope *scope) {
    if (realPath.length == 0 || scope == nil) {
        return NO;
    }
    if (scope.allowAllAppContainers) {
        return YES;
    }
    if (scope.expectedDocRealPath.length > 0 && [realPath isEqualToString:scope.expectedDocRealPath]) {
        return YES;
    }
    return ps_real_path_matches_or_under(realPath, scope.allowedRealPath, scope.allowSubtree);
}

__attribute__((visibility("hidden"))) void ps_set_wkwebview_read_scope(id webView, PSVirtualFileReadScope *scope) {
    if (webView == nil) {
        return;
    }
    objc_setAssociatedObject(webView, &kPSWKReadScopeAssocKey, scope, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static PSVirtualFileReadScope *ps_get_wkwebview_read_scope(id webView) {
    if (webView == nil) {
        return nil;
    }
    return objc_getAssociatedObject(webView, &kPSWKReadScopeAssocKey);
}

static BOOL ps_verify_wk_initiator_on_main(id webView, id urlSchemeTask, NSURLRequest *req, PSVirtualFileReadScope *scope) {
    if (webView == nil || scope == nil || (!scope.allowAllAppContainers && scope.allowedRealPath.length == 0)) {
        return NO;
    }
    SEL urlSel = @selector(URL);
    if ([webView respondsToSelector:urlSel]) {
        NSURL *wvURL = ((NSURL *(*)(id, SEL))objc_msgSend)(webView, urlSel);
        if (wvURL != nil && wvURL.absoluteString.length > 0) {
            NSString *wvScheme = wvURL.scheme ?: @"";
            if ([wvScheme caseInsensitiveCompare:@"about"] != NSOrderedSame &&
                [wvScheme caseInsensitiveCompare:@"file"] != NSOrderedSame &&
                [wvScheme caseInsensitiveCompare:@"pt-vfile"] != NSOrderedSame) {
                return NO;
            }
        }
    }
    SEL frameSel = NSSelectorFromString(@"_frame");
    if (urlSchemeTask != nil && [urlSchemeTask respondsToSelector:frameSel]) {
        id frameInfo = ((id (*)(id, SEL))objc_msgSend)(urlSchemeTask, frameSel);
        if (frameInfo != nil) {
            SEL secOriginSel = NSSelectorFromString(@"securityOrigin");
            if ([frameInfo respondsToSelector:secOriginSel]) {
                id secOrigin = ((id (*)(id, SEL))objc_msgSend)(frameInfo, secOriginSel);
                SEL protoSel = NSSelectorFromString(@"protocol");
                if (secOrigin != nil && [secOrigin respondsToSelector:protoSel]) {
                    NSString *proto = ((NSString *(*)(id, SEL))objc_msgSend)(secOrigin, protoSel);
                    if ([proto isKindOfClass:[NSString class]] && proto.length > 0 &&
                        [proto caseInsensitiveCompare:@"file"] != NSOrderedSame &&
                        [proto caseInsensitiveCompare:@"pt-vfile"] != NSOrderedSame &&
                        [proto caseInsensitiveCompare:@"about"] != NSOrderedSame &&
                        [proto caseInsensitiveCompare:@"null"] != NSOrderedSame) {
                        return NO;
                    }
                }
            }
            SEL frameReqSel = @selector(request);
            if ([frameInfo respondsToSelector:frameReqSel]) {
                NSURLRequest *frameReq = ((NSURLRequest *(*)(id, SEL))objc_msgSend)(frameInfo, frameReqSel);
                NSURL *frameURL = frameReq.URL;
                if (frameURL != nil && frameURL.absoluteString.length > 0) {
                    NSString *frameScheme = frameURL.scheme ?: @"";
                    if ([frameScheme caseInsensitiveCompare:@"about"] != NSOrderedSame &&
                        [frameScheme caseInsensitiveCompare:@"file"] != NSOrderedSame &&
                        [frameScheme caseInsensitiveCompare:@"pt-vfile"] != NSOrderedSame) {
                        return NO;
                    }
                }
            }
        }
    }
    NSURL *mainDocURL = req.mainDocumentURL;
    if (mainDocURL != nil && mainDocURL.absoluteString.length > 0) {
        NSString *scheme = mainDocURL.scheme ?: @"";
        if ([scheme caseInsensitiveCompare:@"about"] != NSOrderedSame &&
            [scheme caseInsensitiveCompare:@"file"] != NSOrderedSame &&
            [scheme caseInsensitiveCompare:@"pt-vfile"] != NSOrderedSame) {
            return NO;
        }
    }
    NSString *originHdr = [req valueForHTTPHeaderField:@"Origin"];
    if (originHdr.length > 0 && ![originHdr isEqualToString:@"null"]) {
        NSString *lo = [originHdr lowercaseString];
        if (![lo hasPrefix:@"file:"] && ![lo hasPrefix:@"pt-vfile:"] && ![lo hasPrefix:@"about:"]) {
            return NO;
        }
    }
    NSString *refererHdr = [req valueForHTTPHeaderField:@"Referer"];
    if (refererHdr.length > 0) {
        NSString *lr = [refererHdr lowercaseString];
        if (![lr hasPrefix:@"file:"] && ![lr hasPrefix:@"pt-vfile:"] && ![lr hasPrefix:@"about:"]) {
            return NO;
        }
    }
    return YES;
}

__attribute__((visibility("hidden")))
@interface PSVirtualFileSchemeHandler : NSObject
@end

@implementation PSVirtualFileSchemeHandler

- (void)webView:(id)webView startURLSchemeTask:(id)urlSchemeTask {
    if (urlSchemeTask == nil) {
        return;
    }
    PSVFileTaskState *state = ps_vfile_track_task_start(urlSchemeTask);
    SEL reqSel = @selector(request);
    NSURLRequest *req = [urlSchemeTask respondsToSelector:reqSel]
        ? ((NSURLRequest *(*)(id, SEL))objc_msgSend)(urlSchemeTask, reqSel)
        : nil;
    PSVirtualFileReadScope *scope = ps_get_wkwebview_read_scope(webView);
    if (!ps_verify_wk_initiator_on_main(webView, urlSchemeTask, req, scope)) {
        if (ps_vfile_claim_state_done(state)) {
            objc_setAssociatedObject(urlSchemeTask, &kPSVFileTaskStateAssocKey, nil, OBJC_ASSOCIATION_RETAIN);
            @try {
                NSError *permErr = [NSError errorWithDomain:NSURLErrorDomain
                                                       code:NSURLErrorNoPermissionsToReadFile
                                                   userInfo:nil];
                SEL failSel = @selector(didFailWithError:);
                if ([urlSchemeTask respondsToSelector:failSel]) {
                    ((void (*)(id, SEL, NSError *))objc_msgSend)(urlSchemeTask, failSel, permErr);
                }
            } @catch (NSException *exception) {
                (void)exception;
            }
        }
        return;
    }
    NSURL *reqURL = req.URL;
    NSString *rangeHeader = [req valueForHTTPHeaderField:@"Range"];
    NSString *originHeader = [req valueForHTTPHeaderField:@"Origin"];
    NSString *method = req.HTTPMethod ?: @"GET";
    BOOL isOptions = ([method caseInsensitiveCompare:@"OPTIONS"] == NSOrderedSame);
    BOOL isHead = ([method caseInsensitiveCompare:@"HEAD"] == NSOrderedSame);

    [ps_vfile_operation_queue() addOperationWithBlock:^{
        if (!ps_vfile_is_state_active(state)) {
            return;
        }
        int fd = -1;
        uint8_t *buf = NULL;
        @try {
            NSError *failErr = nil;
            NSString *realPath = nil;

            do {
                if (reqURL == nil || [reqURL.scheme caseInsensitiveCompare:@"pt-vfile"] != NSOrderedSame) {
                    failErr = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadURL userInfo:nil];
                    break;
                }
                NSURLComponents *comp = [NSURLComponents componentsWithURL:reqURL resolvingAgainstBaseURL:NO];
                if (comp == nil) {
                    failErr = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadURL userInfo:nil];
                    break;
                }
                comp.scheme = @"file";
                comp.host = @"";
                NSURL *virtFileURL = comp.URL;
                NSString *virtPath = (virtFileURL != nil && [virtFileURL isFileURL]) ? virtFileURL.path : nil;
                if (virtPath.length == 0 || !ps_is_virtual_container_nsstring(virtPath)) {
                    failErr = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil];
                    break;
                }
                realPath = ps_canonical_container_real_path_from_url(virtFileURL);
                if (!ps_real_path_is_allowed_by_scope(realPath, scope)) {
                    failErr = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNoPermissionsToReadFile userInfo:nil];
                    break;
                }
            } while (0);

            if (failErr != nil) {
                ps_vfile_fail_on_main(urlSchemeTask, state, failErr);
                return;
            }

            if (!ps_vfile_is_state_active(state)) {
                return;
            }

            NSString *lowerOrigin = originHeader ? [originHeader lowercaseString] : @"";
            BOOL allowOrigin = (lowerOrigin.length == 0 ||
                                [lowerOrigin isEqualToString:@"null"] ||
                                [lowerOrigin hasPrefix:@"file:"] ||
                                [lowerOrigin hasPrefix:@"pt-vfile:"] ||
                                [lowerOrigin hasPrefix:@"about:"]);

            if (isOptions) {
                NSMutableDictionary<NSString *, NSString *> *optHeaders = [NSMutableDictionary dictionaryWithDictionary:@{
                    @"Cache-Control": @"no-cache",
                    @"Access-Control-Allow-Methods": @"GET, HEAD, OPTIONS",
                    @"Access-Control-Allow-Headers": @"*",
                    @"Access-Control-Expose-Headers": @"Content-Length, Content-Range, Accept-Ranges"
                }];
                if (allowOrigin) {
                    optHeaders[@"Access-Control-Allow-Origin"] = @"*";
                }
                NSHTTPURLResponse *optResp = [[NSHTTPURLResponse alloc] initWithURL:reqURL
                                                                         statusCode:204
                                                                        HTTPVersion:@"HTTP/1.1"
                                                                       headerFields:optHeaders];
                if (optResp == nil) {
                    ps_vfile_fail_on_main(urlSchemeTask, state,
                                          [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotOpenFile userInfo:nil]);
                    return;
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!ps_vfile_is_state_active(state)) {
                        return;
                    }
                    @try {
                        SEL respSel = @selector(didReceiveResponse:);
                        if ([urlSchemeTask respondsToSelector:respSel]) {
                            ((void (*)(id, SEL, NSURLResponse *))objc_msgSend)(urlSchemeTask, respSel, optResp);
                        }
                        if (ps_vfile_claim_state_done(state)) {
                            objc_setAssociatedObject(urlSchemeTask, &kPSVFileTaskStateAssocKey, nil, OBJC_ASSOCIATION_RETAIN);
                            SEL finSel = @selector(didFinish);
                            if ([urlSchemeTask respondsToSelector:finSel]) {
                                ((void (*)(id, SEL))objc_msgSend)(urlSchemeTask, finSel);
                            }
                        }
                    } @catch (NSException *exception) {
                        ps_vfile_claim_state_done(state);
                        objc_setAssociatedObject(urlSchemeTask, &kPSVFileTaskStateAssocKey, nil, OBJC_ASSOCIATION_RETAIN);
                        (void)exception;
                    }
                });
                return;
            }

            fd = open([realPath fileSystemRepresentation], O_RDONLY | O_CLOEXEC);
            if (fd < 0) {
                int errNo = errno;
                NSInteger urlErrCode = NSURLErrorCannotOpenFile;
                if (errNo == ENOENT || errNo == ENOTDIR) {
                    urlErrCode = NSURLErrorFileDoesNotExist;
                } else if (errNo == EACCES || errNo == EPERM) {
                    urlErrCode = NSURLErrorNoPermissionsToReadFile;
                }
                ps_vfile_fail_on_main(urlSchemeTask, state,
                                      [NSError errorWithDomain:NSURLErrorDomain code:urlErrCode userInfo:nil]);
                return;
            }

            struct stat st;
            if (fstat(fd, &st) != 0 || S_ISDIR(st.st_mode) || !S_ISREG(st.st_mode) || st.st_size < 0) {
                close(fd);
                fd = -1;
                ps_vfile_fail_on_main(urlSchemeTask, state,
                                      [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil]);
                return;
            }

            uint64_t totalLen = (uint64_t)st.st_size;
            NSInteger statusCode = 200;
            uint64_t startByte = 0;
            uint64_t endByte = (totalLen > 0) ? (totalLen - 1ULL) : 0ULL;
            uint64_t contentLength = totalLen;

            NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionaryWithDictionary:@{
                @"Content-Type": ps_guess_mime_type_for_path(realPath),
                @"Accept-Ranges": @"bytes",
                @"Cache-Control": @"no-cache",
                @"Access-Control-Allow-Methods": @"GET, HEAD, OPTIONS",
                @"Access-Control-Allow-Headers": @"*",
                @"Access-Control-Expose-Headers": @"Content-Length, Content-Range, Accept-Ranges"
            }];
            if (allowOrigin) {
                headers[@"Access-Control-Allow-Origin"] = @"*";
            }

            NSString *trimmedRange = rangeHeader
                ? [rangeHeader stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                : nil;
            if (trimmedRange.length > 6 && [[trimmedRange lowercaseString] hasPrefix:@"bytes="]) {
                NSString *spec = [[trimmedRange substringFromIndex:6]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if ([spec rangeOfString:@","].location == NSNotFound) {
                    NSRange dash = [spec rangeOfString:@"-"];
                    if (dash.location != NSNotFound) {
                        if (totalLen == 0) {
                            statusCode = 416;
                            contentLength = 0;
                            headers[@"Content-Range"] = @"bytes */0";
                        } else {
                            NSString *startStr = [[spec substringToIndex:dash.location]
                                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                            NSString *endStr = [[spec substringFromIndex:dash.location + 1]
                                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                            uint64_t parsedStart = 0;
                            uint64_t parsedEnd = totalLen - 1ULL;
                            BOOL parsedSyntax = NO;
                            BOOL satisfiable = NO;

                            if (startStr.length > 0) {
                                if (ps_vfile_parse_uint64(startStr, &parsedStart)) {
                                    if (endStr.length > 0) {
                                        if (ps_vfile_parse_uint64(endStr, &parsedEnd)) {
                                            parsedSyntax = YES;
                                            if (parsedStart < totalLen && parsedEnd >= parsedStart) {
                                                satisfiable = YES;
                                                if (parsedEnd >= totalLen) {
                                                    parsedEnd = totalLen - 1ULL;
                                                }
                                            }
                                        }
                                    } else {
                                        parsedSyntax = YES;
                                        if (parsedStart < totalLen) {
                                            satisfiable = YES;
                                            parsedEnd = totalLen - 1ULL;
                                        }
                                    }
                                }
                            } else if (endStr.length > 0) {
                                uint64_t suffixLen = 0;
                                if (ps_vfile_parse_uint64(endStr, &suffixLen)) {
                                    parsedSyntax = YES;
                                    if (suffixLen > 0) {
                                        satisfiable = YES;
                                        parsedStart = (suffixLen >= totalLen) ? 0ULL : (totalLen - suffixLen);
                                        parsedEnd = totalLen - 1ULL;
                                    }
                                }
                            }

                            if (parsedSyntax) {
                                if (satisfiable) {
                                    startByte = parsedStart;
                                    endByte = parsedEnd;
                                    contentLength = endByte - startByte + 1ULL;
                                    statusCode = 206;
                                    headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes %llu-%llu/%llu",
                                                                 startByte, endByte, totalLen];
                                } else {
                                    statusCode = 416;
                                    contentLength = 0;
                                    headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes */%llu", totalLen];
                                }
                            }
                        }
                    }
                }
            }

            headers[@"Content-Length"] = [NSString stringWithFormat:@"%llu", contentLength];
            NSHTTPURLResponse *httpResp = [[NSHTTPURLResponse alloc] initWithURL:reqURL
                                                                      statusCode:statusCode
                                                                     HTTPVersion:@"HTTP/1.1"
                                                                    headerFields:headers];
            if (httpResp == nil) {
                ps_vfile_fail_on_main(urlSchemeTask, state,
                                      [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotOpenFile userInfo:nil]);
                return;
            }

            static const size_t kPSVFileChunkBytes = 512 * 1024;
            if (isHead || statusCode == 416 || contentLength == 0 || contentLength <= (uint64_t)kPSVFileChunkBytes) {
                NSData *singleData = nil;
                if (!isHead && statusCode != 416 && contentLength > 0) {
                    size_t targetBytes = (size_t)contentLength;
                    buf = (uint8_t *)malloc(targetBytes);
                    if (buf == NULL) {
                        ps_vfile_fail_on_main(urlSchemeTask, state,
                                              [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotOpenFile userInfo:nil]);
                        return;
                    }
                    size_t filled = 0;
                    off_t off = (off_t)startByte;
                    while (filled < targetBytes) {
                        if (!ps_vfile_is_state_active(state)) {
                            return;
                        }
                        ssize_t nread = pread(fd, buf + filled, targetBytes - filled, off + (off_t)filled);
                        if (nread < 0 && errno == EINTR) {
                            continue;
                        }
                        if (nread <= 0) {
                            ps_vfile_fail_on_main(urlSchemeTask, state,
                                                  [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotOpenFile userInfo:nil]);
                            return;
                        }
                        filled += (size_t)nread;
                    }
                    singleData = [NSData dataWithBytesNoCopy:buf length:targetBytes freeWhenDone:YES];
                    buf = NULL;
                }
                close(fd);
                fd = -1;

                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!ps_vfile_is_state_active(state)) {
                        return;
                    }
                    @try {
                        SEL respSel = @selector(didReceiveResponse:);
                        if ([urlSchemeTask respondsToSelector:respSel]) {
                            ((void (*)(id, SEL, NSURLResponse *))objc_msgSend)(urlSchemeTask, respSel, httpResp);
                        }
                        if (singleData != nil && ps_vfile_is_state_active(state)) {
                            SEL dataSel = @selector(didReceiveData:);
                            if ([urlSchemeTask respondsToSelector:dataSel]) {
                                ((void (*)(id, SEL, NSData *))objc_msgSend)(urlSchemeTask, dataSel, singleData);
                            }
                        }
                        if (ps_vfile_claim_state_done(state)) {
                            objc_setAssociatedObject(urlSchemeTask, &kPSVFileTaskStateAssocKey, nil, OBJC_ASSOCIATION_RETAIN);
                            SEL finSel = @selector(didFinish);
                            if ([urlSchemeTask respondsToSelector:finSel]) {
                                ((void (*)(id, SEL))objc_msgSend)(urlSchemeTask, finSel);
                            }
                        }
                    } @catch (NSException *exception) {
                        ps_vfile_claim_state_done(state);
                        objc_setAssociatedObject(urlSchemeTask, &kPSVFileTaskStateAssocKey, nil, OBJC_ASSOCIATION_RETAIN);
                        (void)exception;
                    }
                });
                return;
            }

            buf = (uint8_t *)malloc(kPSVFileChunkBytes);
            if (buf == NULL) {
                ps_vfile_fail_on_main(urlSchemeTask, state,
                                      [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotOpenFile userInfo:nil]);
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (!ps_vfile_is_state_active(state)) {
                    return;
                }
                @try {
                    SEL respSel = @selector(didReceiveResponse:);
                    if ([urlSchemeTask respondsToSelector:respSel]) {
                        ((void (*)(id, SEL, NSURLResponse *))objc_msgSend)(urlSchemeTask, respSel, httpResp);
                    }
                } @catch (NSException *exception) {
                    ps_vfile_claim_state_done(state);
                    objc_setAssociatedObject(urlSchemeTask, &kPSVFileTaskStateAssocKey, nil, OBJC_ASSOCIATION_RETAIN);
                    (void)exception;
                }
            });

            uint64_t remaining = contentLength;
            off_t offset = (off_t)startByte;
            while (remaining > 0) {
                if (!ps_vfile_is_state_active(state)) {
                    return;
                }
                size_t toRead = (remaining < (uint64_t)kPSVFileChunkBytes) ? (size_t)remaining : kPSVFileChunkBytes;
                ssize_t nread = -1;
                do {
                    nread = pread(fd, buf, toRead, offset);
                } while (nread < 0 && errno == EINTR);

                if (nread <= 0) {
                    ps_vfile_fail_on_main(urlSchemeTask, state,
                                          [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotOpenFile userInfo:nil]);
                    return;
                }

                @autoreleasepool {
                    NSData *chunkData = [NSData dataWithBytes:buf length:(NSUInteger)nread];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (ps_vfile_is_state_active(state)) {
                            @try {
                                SEL dataSel = @selector(didReceiveData:);
                                if ([urlSchemeTask respondsToSelector:dataSel]) {
                                    ((void (*)(id, SEL, NSData *))objc_msgSend)(urlSchemeTask, dataSel, chunkData);
                                }
                            } @catch (NSException *exception) {
                                ps_vfile_claim_state_done(state);
                                objc_setAssociatedObject(urlSchemeTask, &kPSVFileTaskStateAssocKey, nil, OBJC_ASSOCIATION_RETAIN);
                                (void)exception;
                            }
                        }
                        if (state->_flowSem != nil) {
                            dispatch_semaphore_signal(state->_flowSem);
                        }
                    });
                }
                dispatch_semaphore_wait(state->_flowSem, DISPATCH_TIME_FOREVER);
                if (!ps_vfile_is_state_active(state)) {
                    return;
                }

                offset += (off_t)nread;
                remaining -= (uint64_t)nread;
            }

            close(fd);
            fd = -1;

            dispatch_async(dispatch_get_main_queue(), ^{
                if (!ps_vfile_claim_state_done(state)) {
                    return;
                }
                objc_setAssociatedObject(urlSchemeTask, &kPSVFileTaskStateAssocKey, nil, OBJC_ASSOCIATION_RETAIN);
                @try {
                    SEL finSel = @selector(didFinish);
                    if ([urlSchemeTask respondsToSelector:finSel]) {
                        ((void (*)(id, SEL))objc_msgSend)(urlSchemeTask, finSel);
                    }
                } @catch (NSException *exception) {
                    (void)exception;
                }
            });
        } @finally {
            if (buf != NULL) {
                free(buf);
                buf = NULL;
            }
            if (fd >= 0) {
                close(fd);
                fd = -1;
            }
        }
    }];
}

- (void)webView:(id)webView stopURLSchemeTask:(id)urlSchemeTask {
    (void)webView;
    if (urlSchemeTask == nil) {
        return;
    }
    PSVFileTaskState *state = objc_getAssociatedObject(urlSchemeTask, &kPSVFileTaskStateAssocKey);
    (void)ps_vfile_claim_state_done(state);
    objc_setAssociatedObject(urlSchemeTask, &kPSVFileTaskStateAssocKey, nil, OBJC_ASSOCIATION_RETAIN);
}

@end

__attribute__((visibility("hidden"))) id ps_shared_vfile_scheme_handler(void) {
    static PSVirtualFileSchemeHandler *s_handler = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_handler = [[PSVirtualFileSchemeHandler alloc] init];
    });
    return s_handler;
}


@implementation PSSwizzleHooks (PlayShadowFS)

static NSArray<NSString *> *ps_filter_dir_items(NSArray<NSString *> *items, NSString *baseDir, const void *caller) {
    if (items == nil || ps_is_effective_system_or_playtools_caller(caller)) {
        return items;
    }
    NSMutableArray<NSString *> *filtered = [NSMutableArray arrayWithCapacity:items.count];
    for (NSString *item in items) {
        if ([item containsString:@"PlayTools"] ||
            [item containsString:@"Playtools.strings"] ||
            [item containsString:@"AKInterface"] ||
            [item containsString:@"UserPlugins"]) {
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
    if ([itemPath containsString:@"PlayTools"] ||
        [itemPath containsString:@"Playtools.strings"] ||
        [itemPath containsString:@"AKInterface"] ||
        [itemPath containsString:@"UserPlugins"] ||
        ([itemPath containsString:@"app.makedie.MacOver"] &&
         ![itemPath containsString:@"/app.makedie.MacOver/Applications/"]) ||
        ([itemPath containsString:@"io.playcover.PlayCover"] &&
         ![itemPath containsString:@"/io.playcover.PlayCover/Applications/"])) {
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
            if ([rel containsString:@"PlayTools"] ||
                [rel containsString:@"Playtools.strings"] ||
                [rel containsString:@"AKInterface"] ||
                [rel containsString:@"UserPlugins"]) {
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

- (NSURL *) pm_ps_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    const void *caller = __builtin_return_address(0);
    NSURL *realURL = [self pm_ps_containerURLForSecurityApplicationGroupIdentifier:groupIdentifier];
    if (realURL == nil || ![realURL isFileURL]) {
        return realURL;
    }
    NSString *realPath = realURL.path;
    if (realPath.length == 0) {
        return realURL;
    }
    char raw[PATH_MAX];
    if (!CFStringGetFileSystemRepresentation((__bridge CFStringRef)realPath, raw, sizeof(raw))) {
        return realURL;
    }
    char virtBuf[PATH_MAX];
    const char *virt = pt_register_and_virtualize_group_container(raw, virtBuf, sizeof(virtBuf), YES);
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(caller) &&
        virt != NULL &&
        virt != raw) {
        CFStringRef cfStr = CFStringCreateWithFileSystemRepresentation(kCFAllocatorDefault, virt);
        if (cfStr != NULL) {
            NSString *virtStr = (__bridge_transfer NSString *)cfStr;
            return ps_rebuild_file_nsurl(realURL, virtStr);
        }
    }
    return realURL;
}


static NSString *ps_normalize_virtual_ancestor_nsstring(NSString *path);

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
        [key isEqualToString:NSURLIsVolumeKey]) {
        return @NO;
    }
    if ([key isEqualToString:NSURLFileResourceTypeKey]) {
        return NSURLFileResourceTypeDirectory;
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
    *outHandled = NO;
    return nil;
}

- (BOOL) pm_checkResourceIsReachableAndReturnError:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    NSURL *selfURL = (NSURL *)self;
    BOOL wasVirtual = NO;
    BOOL usePrivatePrefix = NO;
    if ([selfURL isFileURL]) {
        NSString *origPath = [selfURL path];
        wasVirtual = (origPath != nil && ps_is_virtual_container_nsstring(origPath));
        usePrivatePrefix = (origPath != nil && [origPath hasPrefix:@"/private/"]);
        NSURL *url = ps_resolve_virtual_nsurl(selfURL);
        NSString *resolvedPath = [url path];
        if (ps_is_hidden_path(resolvedPath, caller)) {
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
            BOOL ok = [(id)url pm_checkResourceIsReachableAndReturnError:(error != NULL ? &localErr : NULL)];
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
    BOOL wasVirtual = (origPath != nil && ps_is_virtual_container_nsstring(origPath));
    BOOL usePrivatePrefix = (origPath != nil && [origPath hasPrefix:@"/private/"]);
    NSURL *url = ps_resolve_virtual_nsurl(selfURL);
    if ([url isFileURL]) {
        NSString *resolvedPath = [url path];
        if (ps_is_hidden_path(resolvedPath, caller)) {
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
                    [synth addEntriesFromDictionary:backingVals];
                }
            }
            return [synth copy];
        }
    }
    NSError *localErr = nil;
    NSDictionary<NSURLResourceKey, id> *res = (url != selfURL)
        ? [(id)url pm_resourceValuesForKeys:keys error:(error != NULL ? &localErr : NULL)]
        : [self pm_resourceValuesForKeys:keys error:(error != NULL ? &localErr : NULL)];
    if (res == nil) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    if (res != nil && wasVirtual) {
        NSMutableDictionary<NSURLResourceKey, id> *mapped = nil;
        for (NSURLResourceKey k in res) {
            id val = res[k];
            id newVal = val;
            if ([val isKindOfClass:[NSString class]]) {
                if ([k isEqualToString:NSURLCanonicalPathKey]) {
                    newVal = ps_virtualize_nsstring_path_for_app((NSString *)val, YES);
                } else if ([k isEqualToString:NSURLPathKey]) {
                    newVal = ps_virtualize_nsstring_path_for_app((NSString *)val, usePrivatePrefix);
                }
            } else if ([val isKindOfClass:[NSURL class]]) {
                newVal = ps_virtualize_nsurl_for_app((NSURL *)val, usePrivatePrefix);
            }
            if (newVal != val) {
                if (mapped == nil) {
                    mapped = [res mutableCopy];
                }
                mapped[k] = newVal;
            }
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
    BOOL wasVirtual = (origPath != nil && ps_is_virtual_container_nsstring(origPath));
    BOOL usePrivatePrefix = (origPath != nil && [origPath hasPrefix:@"/private/"]);
    NSURL *url = ps_resolve_virtual_nsurl(selfURL);
    if ([url isFileURL]) {
        NSString *resolvedPath = [url path];
        if (ps_is_hidden_path(resolvedPath, caller)) {
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
            return [(id)backingURL pm_getResourceValue:value forKey:key error:error];
        }
    }
    NSError *localErr = nil;
    BOOL ok = (url != selfURL)
        ? [(id)url pm_getResourceValue:value forKey:key error:(error != NULL ? &localErr : NULL)]
        : [self pm_getResourceValue:value forKey:key error:(error != NULL ? &localErr : NULL)];
    if (!ok) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    if (ok && wasVirtual && value != NULL && *value != nil) {
        if ([*value isKindOfClass:[NSString class]]) {
            if ([key isEqualToString:NSURLCanonicalPathKey]) {
                *value = ps_virtualize_nsstring_path_for_app((NSString *)*value, YES);
            } else if ([key isEqualToString:NSURLPathKey]) {
                *value = ps_virtualize_nsstring_path_for_app((NSString *)*value, usePrivatePrefix);
            }
        } else if ([*value isKindOfClass:[NSURL class]]) {
            *value = ps_virtualize_nsurl_for_app((NSURL *)*value, usePrivatePrefix);
        }
    }
    return ok;
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
    BOOL hidden = NO;
    ps_prepare_fm_path(path, caller, &path, &hidden, NULL);
    if (hidden) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
        }
        return nil;
    }
    NSError *localErr = nil;
    NSString *dest = [self pm_destinationOfSymbolicLinkAtPath:path error:(error != NULL ? &localErr : NULL)];
    if (dest == nil) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
        return nil;
    }
    NSString *virt = ps_virtualize_nsstring_path_for_app(dest, NO);
    if (virt != dest && !ps_is_effective_system_or_playtools_caller(caller)) {
        return virt;
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
        NSMutableArray<NSURL *> *mapped = nil;
        int isSysCaller = -1;
        for (NSUInteger i = 0; i < orig.count; i++) {
            NSURL *u = orig[i];
            NSURL *vu = ps_virtualize_nsurl_for_app(u, NO);
            if (vu != u) {
                if (isSysCaller < 0) {
                    isSysCaller = ps_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
                }
                if (isSysCaller != 0) {
                    return orig;
                }
                if (mapped == nil) {
                    mapped = [orig mutableCopy];
                }
                mapped[i] = vu;
            }
        }
        if (mapped != nil) {
            return [mapped copy];
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
            return ps_virtualize_nsurl_for_app(orig, NO);
        }
        return nil;
    }
    return [self pm_ps_homeDirectoryForUser:userName];
}

- (NSString *) pm_currentDirectoryPath {
    const void *caller = __builtin_return_address(0);
    NSString *orig = [self pm_currentDirectoryPath];
    if (orig != nil) {
        NSString *virt = ps_virtualize_nsstring_path_for_app(orig, YES);
        if (virt != orig && !ps_is_effective_system_or_playtools_caller(caller)) {
            return virt;
        }
    }
    return orig;
}

- (BOOL) pm_changeCurrentDirectoryPath:(NSString *)path {
    return [self pm_changeCurrentDirectoryPath:ps_resolve_virtual_nsstring_path(path)];
}

- (BOOL) pm_createDirectoryAtPath:(NSString *)path
      withIntermediateDirectories:(BOOL)createIntermediates
                       attributes:(NSDictionary<NSFileAttributeKey, id> *)attributes
                            error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO;
    ps_detect_path_virtual_flags(path, nil, &wasVirtual, &usePrivatePrefix);
    path = ps_resolve_virtual_nsstring_path(path);
    if (ps_is_virtual_ancestor_nsstring(path)) {
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
    url = ps_resolve_virtual_nsurl(url);
    if ([url isFileURL] && ps_is_virtual_ancestor_nsstring(url.path)) {
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
    path = ps_resolve_virtual_nsstring_path(path);
    if (ps_is_virtual_ancestor_nsstring(path)) {
        return NO;
    }
    return [self pm_createFileAtPath:path contents:data attributes:attr];
}

- (BOOL) pm_removeItemAtPath:(NSString *)path error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO;
    ps_detect_path_virtual_flags(path, nil, &wasVirtual, &usePrivatePrefix);
    path = ps_resolve_virtual_nsstring_path(path);
    if (ps_is_virtual_ancestor_nsstring(path)) {
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
    URL = ps_resolve_virtual_nsurl(URL);
    if ([URL isFileURL] && ps_is_virtual_ancestor_nsstring(URL.path)) {
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
    NSError *localErr = nil;
    BOOL ok = [self pm_copyItemAtPath:ps_resolve_virtual_nsstring_path(srcPath)
                                toPath:ps_resolve_virtual_nsstring_path(dstPath)
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
    NSError *localErr = nil;
    BOOL ok = [self pm_copyItemAtURL:ps_resolve_virtual_nsurl(srcURL)
                               toURL:ps_resolve_virtual_nsurl(dstURL)
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
    NSError *localErr = nil;
    BOOL ok = [self pm_moveItemAtPath:ps_resolve_virtual_nsstring_path(srcPath)
                                toPath:ps_resolve_virtual_nsstring_path(dstPath)
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
    NSError *localErr = nil;
    BOOL ok = [self pm_moveItemAtURL:ps_resolve_virtual_nsurl(srcURL)
                               toURL:ps_resolve_virtual_nsurl(dstURL)
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
    NSError *localErr = nil;
    BOOL ok = [self pm_linkItemAtPath:ps_resolve_virtual_nsstring_path(srcPath)
                                toPath:ps_resolve_virtual_nsstring_path(dstPath)
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
    NSError *localErr = nil;
    BOOL ok = [self pm_linkItemAtURL:ps_resolve_virtual_nsurl(srcURL)
                               toURL:ps_resolve_virtual_nsurl(dstURL)
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
    NSError *localErr = nil;
    BOOL ok = [self pm_createSymbolicLinkAtPath:ps_resolve_virtual_nsstring_path(path)
                            withDestinationPath:ps_resolve_virtual_nsstring_path(destPath)
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
    NSError *localErr = nil;
    BOOL ok = [self pm_createSymbolicLinkAtURL:ps_resolve_virtual_nsurl(url)
                            withDestinationURL:ps_resolve_virtual_nsurl(destURL)
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
    NSError *localErr = nil;
    BOOL ok = [self pm_replaceItemAtURL:ps_resolve_virtual_nsurl(originalItemURL)
                          withItemAtURL:ps_resolve_virtual_nsurl(newItemURL)
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

- (BOOL) pm_setAttributes:(NSDictionary<NSFileAttributeKey, id> *)attributes
             ofItemAtPath:(NSString *)path
                    error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL wasVirtual = NO, usePrivatePrefix = NO;
    ps_detect_path_virtual_flags(path, nil, &wasVirtual, &usePrivatePrefix);
    NSError *localErr = nil;
    BOOL ok = [self pm_setAttributes:attributes
                        ofItemAtPath:ps_resolve_virtual_nsstring_path(path)
                               error:(error != NULL ? &localErr : NULL)];
    if (!ok) {
        ps_assign_virtualized_nserror(error, localErr, usePrivatePrefix, wasVirtual, caller);
    }
    return ok;
}

static NSString *ps_normalize_virtual_ancestor_nsstring(NSString *path) {
    NSString *norm = ps_resolve_virtual_nsstring_path(path);
    if ([norm hasPrefix:@"/private/"]) {
        norm = [norm substringFromIndex:8];
    }
    while (norm.length > 1 && [norm hasSuffix:@"/"]) {
        norm = [norm substringToIndex:norm.length - 1];
    }
    return norm;
}

- (NSString *) pm_stringByExpandingTildeInPath {
    const void *caller = __builtin_return_address(0);
    NSString *expanded = [self pm_stringByExpandingTildeInPath];
    if (expanded != nil && !ps_is_effective_system_or_playtools_caller(caller)) {
        return ps_virtualize_nsstring_path_for_app(expanded, NO);
    }
    return expanded;
}

- (NSString *) pm_ps2_stringByExpandingTildeInPath {
    const void *caller = __builtin_return_address(0);
    NSString *expanded = [self pm_ps2_stringByExpandingTildeInPath];
    if (expanded != nil && !ps_is_effective_system_or_playtools_caller(caller)) {
        return ps_virtualize_nsstring_path_for_app(expanded, NO);
    }
    return expanded;
}

- (NSString *) pm_stringByResolvingSymlinksInPath {
    NSString *orig = (NSString *)self;
    if (ps_is_virtual_container_nsstring(orig)) {
        NSString *resolvedIn = ps_resolve_virtual_nsstring_path(orig);
        NSString *resolvedOut = [resolvedIn stringByResolvingSymlinksInPath];
        return ps_virtualize_nsstring_path_for_app(resolvedOut, NO);
    }
    if (ps_is_virtual_ancestor_nsstring(orig)) {
        return ps_normalize_virtual_ancestor_nsstring(orig);
    }
    return [self pm_stringByResolvingSymlinksInPath];
}

- (NSString *) pm_ps2_stringByResolvingSymlinksInPath {
    NSString *orig = (NSString *)self;
    if (ps_is_virtual_container_nsstring(orig)) {
        NSString *resolvedIn = ps_resolve_virtual_nsstring_path(orig);
        NSString *resolvedOut = [resolvedIn stringByResolvingSymlinksInPath];
        return ps_virtualize_nsstring_path_for_app(resolvedOut, NO);
    }
    if (ps_is_virtual_ancestor_nsstring(orig)) {
        return ps_normalize_virtual_ancestor_nsstring(orig);
    }
    return [self pm_ps2_stringByResolvingSymlinksInPath];
}

- (NSString *) pm_stringByStandardizingPath {
    const void *caller = __builtin_return_address(0);
    NSString *orig = (NSString *)self;
    if ([orig hasPrefix:@"~"]) {
        NSString *res = [self pm_stringByStandardizingPath];
        if (res != nil && !ps_is_effective_system_or_playtools_caller(caller)) {
            return ps_virtualize_nsstring_path_for_app(res, NO);
        }
        return res;
    }
    if (ps_is_virtual_container_nsstring(orig)) {
        NSString *resolvedIn = ps_resolve_virtual_nsstring_path(orig);
        NSString *resolvedOut = [resolvedIn stringByStandardizingPath];
        return ps_virtualize_nsstring_path_for_app(resolvedOut, NO);
    }
    if (ps_is_virtual_ancestor_nsstring(orig)) {
        return ps_normalize_virtual_ancestor_nsstring(orig);
    }
    return [self pm_stringByStandardizingPath];
}

- (NSString *) pm_ps2_stringByStandardizingPath {
    const void *caller = __builtin_return_address(0);
    NSString *orig = (NSString *)self;
    if ([orig hasPrefix:@"~"]) {
        NSString *res = [self pm_ps2_stringByStandardizingPath];
        if (res != nil && !ps_is_effective_system_or_playtools_caller(caller)) {
            return ps_virtualize_nsstring_path_for_app(res, NO);
        }
        return res;
    }
    if (ps_is_virtual_container_nsstring(orig)) {
        NSString *resolvedIn = ps_resolve_virtual_nsstring_path(orig);
        NSString *resolvedOut = [resolvedIn stringByStandardizingPath];
        return ps_virtualize_nsstring_path_for_app(resolvedOut, NO);
    }
    if (ps_is_virtual_ancestor_nsstring(orig)) {
        return ps_normalize_virtual_ancestor_nsstring(orig);
    }
    return [self pm_ps2_stringByStandardizingPath];
}

- (NSURL *) pm_URLByResolvingSymlinksInPath {
    NSURL *selfURL = (NSURL *)self;
    if ([selfURL isFileURL]) {
        NSString *origPath = [selfURL path];
        if (ps_is_virtual_container_nsstring(origPath)) {
            NSURL *resolvedIn = ps_resolve_virtual_nsurl(selfURL);
            NSURL *resolvedOut = [(id)resolvedIn pm_URLByResolvingSymlinksInPath];
            return ps_virtualize_nsurl_for_app(resolvedOut, NO);
        }
        if (ps_is_virtual_ancestor_nsstring(origPath)) {
            return ps_rebuild_file_nsurl(selfURL, ps_normalize_virtual_ancestor_nsstring(origPath));
        }
    }
    return [self pm_URLByResolvingSymlinksInPath];
}

- (NSURL *) pm_URLByStandardizingPath {
    NSURL *selfURL = (NSURL *)self;
    if ([selfURL isFileURL]) {
        NSString *origPath = [selfURL path];
        if (ps_is_virtual_container_nsstring(origPath)) {
            NSURL *resolvedIn = ps_resolve_virtual_nsurl(selfURL);
            NSURL *resolvedOut = [(id)resolvedIn pm_URLByStandardizingPath];
            return ps_virtualize_nsurl_for_app(resolvedOut, NO);
        }
        if (ps_is_virtual_ancestor_nsstring(origPath)) {
            return ps_rebuild_file_nsurl(selfURL, ps_normalize_virtual_ancestor_nsstring(origPath));
        }
    }
    return [self pm_URLByStandardizingPath];
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

__attribute__((visibility("hidden"))) void ps_install_webkit_hooks_if_loaded(void) {
    Class wkCls = objc_getClass("WKWebView");
    if (wkCls != nil) {
        static dispatch_once_t wkOnce;
        dispatch_once(&wkOnce, ^{
            Protocol *wkSchemeProto = objc_getProtocol("WKURLSchemeHandler");
            if (wkSchemeProto != NULL) {
                class_addProtocol([PSVirtualFileSchemeHandler class], wkSchemeProto);
            }
            Class wkCfgCls = objc_getClass("WKWebViewConfiguration");
            if (wkCfgCls != Nil) {
                if (class_getInstanceMethod(wkCfgCls, @selector(init)) != NULL) {
                    ps_swizzle_instance_method(wkCfgCls, @selector(init), @selector(pm_wk_cfg_init));
                }
                if (class_getInstanceMethod(wkCfgCls, @selector(initWithCoder:)) != NULL) {
                    ps_swizzle_instance_method(wkCfgCls, @selector(initWithCoder:), @selector(pm_wk_cfg_initWithCoder:));
                }
            }
            ps_swizzle_instance_method(wkCls, NSSelectorFromString(@"initWithFrame:configuration:"),
                                       @selector(pm_wk_initWithFrame:configuration:));
            if (class_getInstanceMethod(wkCls, @selector(initWithCoder:)) != NULL) {
                ps_swizzle_instance_method(wkCls, @selector(initWithCoder:),
                                           @selector(pm_wk_initWithCoder:));
            }
            ps_swizzle_instance_method(wkCls, NSSelectorFromString(@"setCustomUserAgent:"),
                                       @selector(pm_wk_setCustomUserAgent:));
            ps_swizzle_instance_method(wkCls, NSSelectorFromString(@"customUserAgent"),
                                       @selector(pm_wk_customUserAgent));
            if (class_getInstanceMethod(wkCls, @selector(URL)) != NULL) {
                ps_swizzle_instance_method(wkCls, @selector(URL), @selector(pm_wk_URL));
            }
            ps_swizzle_instance_method(wkCls, NSSelectorFromString(@"loadFileURL:allowingReadAccessToURL:"),
                                       @selector(pm_loadFileURL:allowingReadAccessToURL:));
            SEL loadFileReqSel = NSSelectorFromString(@"loadFileRequest:allowingReadAccessToURL:");
            if ([wkCls instancesRespondToSelector:loadFileReqSel]) {
                ps_swizzle_instance_method(wkCls, loadFileReqSel,
                                           @selector(pm_loadFileRequest:allowingReadAccessToURL:));
            }
            ps_swizzle_instance_method(wkCls, NSSelectorFromString(@"loadRequest:"),
                                       @selector(pm_wk_loadRequest:));
            ps_swizzle_instance_method(wkCls, NSSelectorFromString(@"loadHTMLString:baseURL:"),
                                       @selector(pm_wk_loadHTMLString:baseURL:));
            ps_swizzle_instance_method(wkCls, NSSelectorFromString(@"loadData:MIMEType:characterEncodingName:baseURL:"),
                                       @selector(pm_wk_loadData:MIMEType:characterEncodingName:baseURL:));

            Class navActionCls = objc_getClass("WKNavigationAction");
            if (navActionCls != Nil && class_getInstanceMethod(navActionCls, @selector(request)) != NULL) {
                ps_swizzle_instance_method(navActionCls, @selector(request), @selector(pm_wk_nav_request));
            }
            Class frameInfoCls = objc_getClass("WKFrameInfo");
            if (frameInfoCls != Nil && class_getInstanceMethod(frameInfoCls, @selector(request)) != NULL) {
                ps_swizzle_instance_method(frameInfoCls, @selector(request), @selector(pm_wk_frame_request));
            }

            Class uccCls = objc_getClass("WKUserContentController");
            if (uccCls != nil) {
                if (class_getInstanceMethod(uccCls, NSSelectorFromString(@"userScripts")) != NULL) {
                    ps_swizzle_instance_method(uccCls, NSSelectorFromString(@"userScripts"),
                                               @selector(pm_wk_userScripts));
                }
                ps_swizzle_instance_method(uccCls, NSSelectorFromString(@"removeAllUserScripts"),
                                           @selector(pm_wk_removeAllUserScripts));
            }

            Class wkBccCls = objc_getClass("WKBrowsingContextController");
            if (wkBccCls != nil) {
                SEL regSel = NSSelectorFromString(@"registerSchemeForCustomProtocol:");
                if ([wkBccCls respondsToSelector:regSel]) {
                    ps_swizzle_class_method(wkBccCls, regSel,
                                            @selector(pm_wk_registerSchemeForCustomProtocol:));
                }
                SEL unregSel = NSSelectorFromString(@"unregisterSchemeForCustomProtocol:");
                if ([wkBccCls respondsToSelector:unregSel]) {
                    ps_swizzle_class_method(wkBccCls, unregSel,
                                            @selector(pm_wk_unregisterSchemeForCustomProtocol:));
                }
            }
        });
    }
}

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
