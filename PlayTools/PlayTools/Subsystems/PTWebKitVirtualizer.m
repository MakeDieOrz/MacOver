//
//  PTWebKitVirtualizer.m
//  PlayTools
//
//  Unified WebKit virtualization: custom pt-vfile scheme handler,
//  read-scope confinement, UserAgent/JS spoofing, and WKWebView hooks.
//

#import "PSInternal.h"

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

static const char kPSWKReadScopeAssocKey = 0;

@interface PSVirtualFileReadScope : NSObject
@property (nonatomic, copy) NSString *allowedRealPath;
@property (nonatomic, copy) NSString *expectedDocRealPath;
@property (nonatomic, assign) BOOL allowSubtree;
@property (nonatomic, assign) BOOL allowAllAppContainers;
@end

@implementation PSVirtualFileReadScope
@end

static os_unfair_lock s_wkCanonRootsLock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray<NSString *> *s_wkCanonContainerRoots = nil;
static BOOL s_wkDataRootSeeded = NO;
static BOOL s_wkBundleRootSeeded = NO;

static BOOL ps_real_path_matches_or_under(NSString *candidate, NSString *root, BOOL allowSubtree);

static NSString *ps_extract_virtual_container_root(NSString *virtPath) {
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

static void ps_seed_wk_canon_container_roots(void) {
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

static NSString *ps_canonical_container_real_path_from_url(NSURL *url) {
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

static BOOL ps_real_path_matches_or_under(NSString *candidate, NSString *root, BOOL allowSubtree) {
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

static void ps_set_wkwebview_read_scope(id webView, PSVirtualFileReadScope *scope) {
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

static id ps_shared_vfile_scheme_handler(void) {
    static PSVirtualFileSchemeHandler *s_handler = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_handler = [[PSVirtualFileSchemeHandler alloc] init];
    });
    return s_handler;
}

static void ps_install_wk_scheme_privacy_hooks_if_loaded(void) {
    Class wkCfgCls = objc_getClass("WKWebViewConfiguration");
    if (wkCfgCls != Nil) {
        static dispatch_once_t wkSchemeOnce;
        dispatch_once(&wkSchemeOnce, ^{
            SEL getHandlerSel = NSSelectorFromString(@"urlSchemeHandlerForURLScheme:");
            if (class_getInstanceMethod(wkCfgCls, getHandlerSel) != NULL) {
                ps_swizzle_instance_method(wkCfgCls,
                                           getHandlerSel,
                                           @selector(pm_wk_cfg_urlSchemeHandlerForURLScheme:));
            }
            SEL setHandlerSel = NSSelectorFromString(@"setURLSchemeHandler:forURLScheme:");
            if (class_getInstanceMethod(wkCfgCls, setHandlerSel) != NULL) {
                ps_swizzle_instance_method(wkCfgCls,
                                           setHandlerSel,
                                           @selector(pm_wk_cfg_setURLSchemeHandler:forURLScheme:));
            }
        });
    }
}

@implementation PSSwizzleHooks (PlayShadowWebKit)

static _Atomic bool s_wk_custom_protocol_handles_file = false;
static const char kPSWKExplicitCustomUAKey = 0;
static const char kPSWKUCCManagedModeKey = 0;


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

static os_unfair_lock s_wkEnvCacheLock = OS_UNFAIR_LOCK_INIT;
static NSString *s_cachedWKEnvPlat = nil;
static NSString *s_cachedWKEnvUaToken = nil;
static unsigned int s_cachedWKEnvCores = 0;
static int s_cachedWKEnvPtW = 0;
static int s_cachedWKEnvPtH = 0;
static double s_cachedWKEnvDpr = 0.0;
static BOOL s_cachedWKEnvCompat13 = NO;
static int32_t s_cachedWKEnvMaxAppleFam = 0;
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
    BOOL compat13 = pt_is_compat13_7_active();
    int32_t maxAppleFam = pt_get_spoofed_max_apple_gpu_family();
    ps_get_wk_env_profile_params(&plat, &uaToken, &cores, &ptWidth, &ptHeight, &dpr);

    os_unfair_lock_lock(&s_wkEnvCacheLock);
    BOOL cacheHit = (s_cachedWKEnvSource != nil &&
                     s_cachedWKEnvCores == cores &&
                     s_cachedWKEnvPtW == ptWidth &&
                     s_cachedWKEnvPtH == ptHeight &&
                     s_cachedWKEnvCompat13 == compat13 &&
                     s_cachedWKEnvMaxAppleFam == maxAppleFam &&
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

    NSString *built = ps_build_wk_env_user_script_source_uncached(plat, uaToken, cores, ptWidth, ptHeight, dpr, compat13, maxAppleFam);
    id builtScript = (outScript != NULL || objc_getClass("WKUserScript") != Nil) ? ps_create_wk_user_script(built) : nil;

    os_unfair_lock_lock(&s_wkEnvCacheLock);
    s_cachedWKEnvPlat = [plat copy];
    s_cachedWKEnvUaToken = [uaToken copy];
    s_cachedWKEnvCores = cores;
    s_cachedWKEnvPtW = ptWidth;
    s_cachedWKEnvPtH = ptHeight;
    s_cachedWKEnvDpr = dpr;
    s_cachedWKEnvCompat13 = compat13;
    s_cachedWKEnvMaxAppleFam = maxAppleFam;
    s_cachedWKEnvSource = built;
    if (builtScript != nil) {
        s_cachedWKEnvScript = builtScript;
    } else {
        s_cachedWKEnvScript = nil;
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

static PSVirtualFileReadScope *ps_make_read_scope_for_explicit_access(NSURL *docURL, NSURL *readAccessURL) {
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

static PSVirtualFileReadScope *ps_make_read_scope_for_file_request(id webView, NSURL *fileURL) {
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

static PSVirtualFileReadScope *ps_make_read_scope_for_base_url(NSURL *baseURL) {
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
    ps_apply_proxy_to_wk_configuration(cfg);
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

static const char kPSWKAppVFileSchemeHandlerKey = 0;

- (void) pm_wk_cfg_setURLSchemeHandler:(id)urlSchemeHandler forURLScheme:(NSString *)urlScheme {
    const void *caller = __builtin_return_address(0);
    if ([urlScheme isKindOfClass:[NSString class]] &&
        [urlScheme caseInsensitiveCompare:@"pt-vfile"] == NSOrderedSame &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(caller)) {
        objc_setAssociatedObject(self,
                                 &kPSWKAppVFileSchemeHandlerKey,
                                 urlSchemeHandler,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    [self pm_wk_cfg_setURLSchemeHandler:urlSchemeHandler forURLScheme:urlScheme];
}

- (id) pm_wk_cfg_urlSchemeHandlerForURLScheme:(NSString *)urlScheme {
    const void *caller = __builtin_return_address(0);
    id result = [self pm_wk_cfg_urlSchemeHandlerForURLScheme:urlScheme];
    if ([urlScheme isKindOfClass:[NSString class]] &&
        [urlScheme caseInsensitiveCompare:@"pt-vfile"] == NSOrderedSame &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(caller)) {
        id appHandler = objc_getAssociatedObject(self, &kPSWKAppVFileSchemeHandlerKey);
        if (appHandler != nil) {
            return appHandler;
        }
        if (result != nil) {
            id sharedVFile = ps_shared_vfile_scheme_handler();
            Class vfileCls = (sharedVFile != nil) ? object_getClass(sharedVFile) : Nil;
            if (result == sharedVFile || (vfileCls != Nil && [result isKindOfClass:vfileCls])) {
                return nil;
            }
        }
    }
    return result;
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
    ps_install_default_wk_trust_delegate(initialized);
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

static PSVirtualFileReadScope *ps_make_read_scope_for_base_url_or_nil(NSURL *baseURL) {
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
            ps_install_webkit_network_hooks_if_loaded();
            ps_install_wk_scheme_privacy_hooks_if_loaded();
        });
    }
}
