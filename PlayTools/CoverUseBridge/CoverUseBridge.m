#import "CoverUseBridge.h"

#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <math.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

#define CUB_MAX_FRAME_BYTES (16U * 1024U * 1024U)
#define CUB_MAX_TREE_NODES 500U
#define CUB_MAX_TREE_DEPTH 14U
#define CUB_FD_GUARD_MAGIC 0x5054435542475544ULL
#define CUB_FD_GUARD_FLAGS (0x01U | 0x02U | 0x04U | 0x08U)

extern int change_fdguard_np(int fd, const uint64_t *guard, uint32_t guardflags, const uint64_t *nguard,
                             uint32_t nguardflags, int *fdflagsp) __attribute__((weak_import));
extern int guarded_close_np(int fd, const uint64_t *guard) __attribute__((weak_import));

static dispatch_queue_t s_cub_io_queue = nil;
static NSHashTable<UIWindow *> *s_cub_observed_windows = nil;
static NSMapTable<NSString *, id> *s_cub_node_cache = nil;
static NSMutableArray<UIWindow *> *s_cub_cached_windows = nil;
static id s_cub_win_visible_obs = nil;
static id s_cub_win_key_obs = nil;
static _Atomic double s_cub_last_width = 0.0;
static _Atomic double s_cub_last_height = 0.0;

static void cub_secure_zero_bytes(void *ptr, size_t len) {
    if (ptr == NULL || len == 0U) {
        return;
    }
    volatile unsigned char *p = (volatile unsigned char *)ptr;
    for (size_t i = 0; i < len; i++) {
        p[i] = 0U;
    }
}

static void cub_register_hidden_socket(int fd, uint16_t port) {
    typedef void (*RegisterFDFn)(int);
    typedef void (*RegisterPortFn)(uint16_t);
    RegisterFDFn regFD = (RegisterFDFn)dlsym(RTLD_DEFAULT, "pt_register_hidden_fd");
    if (regFD != NULL) {
        regFD(fd);
    }
    RegisterPortFn regPort = (RegisterPortFn)dlsym(RTLD_DEFAULT, "pt_register_hidden_loopback_port");
    if (regPort != NULL) {
        regPort(port);
    }
}

static void cub_unregister_hidden_socket(int fd, uint16_t port) {
    typedef void (*UnregisterFDFn)(int);
    typedef void (*UnregisterPortFn)(uint16_t);
    UnregisterFDFn unregFD = (UnregisterFDFn)dlsym(RTLD_DEFAULT, "pt_unregister_hidden_fd");
    if (unregFD != NULL) {
        unregFD(fd);
    }
    UnregisterPortFn unregPort = (UnregisterPortFn)dlsym(RTLD_DEFAULT, "pt_unregister_hidden_loopback_port");
    if (unregPort != NULL) {
        unregPort(port);
    }
}

static void cub_close_bridge_fd(int fd, uint16_t port, uint64_t guard, BOOL guarded) {
    if (fd < 0) {
        return;
    }
    cub_unregister_hidden_socket(fd, port);
    if (guarded) {
        if (&guarded_close_np != NULL && guarded_close_np(fd, &guard) == 0) {
            return;
        }
        if (&change_fdguard_np != NULL && change_fdguard_np(fd, &guard, CUB_FD_GUARD_FLAGS, NULL, 0, NULL) == 0) {
            close(fd);
        }
        // Never call raw close(fd) while GUARD_CLOSE is still armed; XNU raises fatal EXC_GUARD.
        return;
    }
    close(fd);
}

typedef struct {
    _Atomic int state; // 0 = pending, 1 = started, 2 = timed_out
    _Atomic int refs;
} cub_dispatch_gate_t;

static void cub_dispatch_gate_release(cub_dispatch_gate_t *gate) {
    if (gate != NULL && atomic_fetch_sub_explicit(&gate->refs, 1, memory_order_acq_rel) == 1) {
        free(gate);
    }
}

static NSDictionary *cub_timeout_error_response(void) {
    return @{
        @"ok" : @(NO),
        @"code" : @"MAIN_THREAD_TIMEOUT",
        @"error" : @"MAIN_THREAD_TIMEOUT: Timed out waiting for guest main queue"
    };
}

static BOOL cub_run_on_main_with_timeout(double timeoutSecs, dispatch_block_t block) {
    if (block == nil) {
        return NO;
    }
    if ([NSThread isMainThread]) {
        @autoreleasepool {
            block();
        }
        return YES;
    }
    cub_dispatch_gate_t *gate = (cub_dispatch_gate_t *)calloc(1U, sizeof(cub_dispatch_gate_t));
    if (gate == NULL) {
        return NO;
    }
    atomic_init(&gate->state, 0);
    atomic_init(&gate->refs, 2);
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        int expected = 0;
        if (atomic_compare_exchange_strong_explicit(&gate->state, &expected, 1, memory_order_acq_rel,
                                                    memory_order_acquire)) {
            @autoreleasepool {
                block();
            }
            dispatch_semaphore_signal(sem);
        }
        cub_dispatch_gate_release(gate);
    });
    int64_t delta = (int64_t)(timeoutSecs * (double)NSEC_PER_SEC);
    if (delta < (int64_t)(100LL * (int64_t)NSEC_PER_MSEC)) {
        delta = (int64_t)(100LL * (int64_t)NSEC_PER_MSEC);
    }
    BOOL completed = (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, delta)) == 0);
    if (!completed) {
        int expected = 0;
        (void)atomic_compare_exchange_strong_explicit(&gate->state, &expected, 2, memory_order_acq_rel,
                                                      memory_order_acquire);
    }
    cub_dispatch_gate_release(gate);
    return completed;
}

static double cub_double_from_obj(id obj, double fallback, BOOL *outValid) {
    if ([obj isKindOfClass:[NSNumber class]]) {
        double v = [(NSNumber *)obj doubleValue];
        if (isfinite(v)) {
            if (outValid != NULL) {
                *outValid = YES;
            }
            return v;
        }
    }
    if (outValid != NULL) {
        *outValid = NO;
    }
    return fallback;
}

static NSInteger cub_integer_from_obj(id obj, NSInteger fallback) {
    if ([obj isKindOfClass:[NSNumber class]]) {
        double v = [(NSNumber *)obj doubleValue];
        if (isfinite(v) && v >= (double)NSIntegerMin && v <= (double)NSIntegerMax) {
            return [(NSNumber *)obj integerValue];
        }
    }
    return fallback;
}

static BOOL cub_bool_from_obj(id obj, BOOL fallback) {
    if ([obj isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)obj boolValue];
    }
    return fallback;
}

static NSString *cub_string_from_obj(id obj) {
    if ([obj isKindOfClass:[NSString class]]) {
        return (NSString *)obj;
    }
    if ([obj isKindOfClass:[NSAttributedString class]]) {
        return [(NSAttributedString *)obj string];
    }
    return nil;
}

static double cub_finite_double(double value, double fallback) {
    return isfinite(value) ? value : fallback;
}

static Class cub_play_settings_class(void) {
    return NSClassFromString(@"PlayTools.PlaySettings") ?: NSClassFromString(@"_TtC9PlayTools12PlaySettings")
                                                        ?: NSClassFromString(@"PlaySettings");
}

static const void *cub_internal_overlay_tag_key(void) {
    static const void *s_key = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class psCls = cub_play_settings_class();
        SEL sel = sel_registerName("pm_internalOverlayTagKeyAddress");
        if (psCls != Nil && [psCls respondsToSelector:sel]) {
            NSUInteger addr = ((NSUInteger (*)(id, SEL))objc_msgSend)(psCls, sel);
            s_key = (const void *)(uintptr_t)addr;
        }
    });
    return s_key;
}

static BOOL cub_is_internal_overlay_view(id element) {
    if (element == nil) {
        return NO;
    }
    const void *tagKey = cub_internal_overlay_tag_key();
    if (tagKey != NULL && objc_getAssociatedObject(element, tagKey) != nil) {
        return YES;
    }
    if ([element isKindOfClass:[UIView class]]) {
        Class psCls = cub_play_settings_class();
        SEL isOverlaySel = sel_registerName("isInternalOverlayView:");
        if (psCls != Nil && [psCls respondsToSelector:isOverlaySel]) {
            if (((BOOL (*)(id, SEL, id))objc_msgSend)(psCls, isOverlaySel, element)) {
                return YES;
            }
        }
    }
    return NO;
}

static BOOL cub_is_or_descends_from_internal_overlay(id element) {
    if (element == nil) {
        return NO;
    }
    if (cub_is_internal_overlay_view(element)) {
        return YES;
    }
    if ([element isKindOfClass:[UIView class]]) {
        UIView *cur = [(UIView *)element superview];
        NSInteger depth = 0;
        while (cur != nil && depth < 128) {
            if (cub_is_internal_overlay_view(cur)) {
                return YES;
            }
            cur = cur.superview;
            depth++;
        }
        UIWindow *win = [(UIView *)element window];
        if (win != nil && cub_is_internal_overlay_view(win)) {
            return YES;
        }
    }
    return NO;
}

static id cub_find_node_by_id(NSString *nodeID) {
    if (![nodeID isKindOfClass:[NSString class]] || nodeID.length == 0) {
        return nil;
    }
    id obj = [s_cub_node_cache objectForKey:nodeID];
    if (obj == nil || cub_is_or_descends_from_internal_overlay(obj)) {
        return nil;
    }
    return obj;
}

static void cub_collect_visible_internal_overlays(UIView *root, NSMutableArray<UIView *> *outViews, NSInteger depth) {
    if (root == nil || outViews == nil || depth > 48 || outViews.count >= 256) {
        return;
    }
    if (root.hidden) {
        return;
    }
    if (cub_is_internal_overlay_view(root)) {
        [outViews addObject:root];
        return;
    }
    for (UIView *sub in root.subviews) {
        cub_collect_visible_internal_overlays(sub, outViews, depth + 1);
    }
}

static BOOL cub_is_auxiliary_window(UIWindow *win) {
    if (win == nil || cub_is_internal_overlay_view(win)) {
        return YES;
    }
    NSString *clsName = NSStringFromClass([win class]);
    if (clsName == nil) {
        return NO;
    }
    if ([clsName containsString:@"UITextEffectsWindow"] || [clsName containsString:@"UIRemoteKeyboardWindow"] ||
        [clsName containsString:@"InputWindow"] || [clsName containsString:@"_UIInteractiveHighlightEnvironment"] ||
        [clsName containsString:@"_UIRemoteViewController"]) {
        return YES;
    }
    return NO;
}

static void cub_record_viewport_size(CGSize size) {
    double w = (double)size.width;
    double h = (double)size.height;
    if (isfinite(w) && isfinite(h) && w > 1.0 && h > 1.0) {
        atomic_store_explicit(&s_cub_last_width, w, memory_order_release);
        atomic_store_explicit(&s_cub_last_height, h, memory_order_release);
    }
}

static void cub_current_logical_size_safe(double *outW, double *outH) {
    double w = atomic_load_explicit(&s_cub_last_width, memory_order_acquire);
    double h = atomic_load_explicit(&s_cub_last_height, memory_order_acquire);
    if (isfinite(w) && isfinite(h) && w > 1.0 && h > 1.0) {
        *outW = w;
        *outH = h;
        return;
    }

    Class psCls = cub_play_settings_class();
    SEL sharedSel = sel_registerName("shared");
    SEL widthSel = sel_registerName("windowSizeWidth");
    SEL heightSel = sel_registerName("windowSizeHeight");
    if (psCls != Nil && [psCls respondsToSelector:sharedSel]) {
        id shared = ((id (*)(id, SEL))objc_msgSend)(psCls, sharedSel);
        if (shared != nil && [shared respondsToSelector:widthSel] && [shared respondsToSelector:heightSel]) {
            double sw = (double)((CGFloat (*)(id, SEL))objc_msgSend)(shared, widthSel);
            double sh = (double)((CGFloat (*)(id, SEL))objc_msgSend)(shared, heightSel);
            if (isfinite(sw) && isfinite(sh) && sw > 1.0 && sh > 1.0) {
                *outW = sw;
                *outH = sh;
                return;
            }
        }
    }

    *outW = 1280.0;
    *outH = 800.0;
}

static void cub_viewport_from_window_on_main(UIWindow *window, double *outW, double *outH) {
    if (window != nil) {
        CGSize bsz = window.bounds.size;
        if (isfinite((double)bsz.width) && isfinite((double)bsz.height) && bsz.width > 1.0 && bsz.height > 1.0) {
            cub_record_viewport_size(bsz);
            *outW = (double)bsz.width;
            *outH = (double)bsz.height;
            return;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIScreen *mainScreen = [UIScreen mainScreen];
#pragma clang diagnostic pop
    if (mainScreen != nil) {
        CGSize ssz = mainScreen.bounds.size;
        if (isfinite((double)ssz.width) && isfinite((double)ssz.height) && ssz.width > 1.0 && ssz.height > 1.0) {
            cub_record_viewport_size(ssz);
            *outW = (double)ssz.width;
            *outH = (double)ssz.height;
            return;
        }
    }
    cub_current_logical_size_safe(outW, outH);
}

static BOOL cub_write_all(int fd, const uint8_t *buf, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = write(fd, buf + sent, len - sent);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return NO;
        }
        if (n == 0) {
            return NO;
        }
        sent += (size_t)n;
    }
    return YES;
}

static int cub_read_exact(int fd, uint8_t *buf, size_t len) {
    size_t got = 0;
    while (got < len) {
        ssize_t n = read(fd, buf + got, len - got);
        if (n == 0) {
            return (got == 0) ? 0 : -1;
        }
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        got += (size_t)n;
    }
    return 1;
}

static BOOL cub_send_json(int fd, NSDictionary *obj) {
    if (obj == nil || ![NSJSONSerialization isValidJSONObject:obj]) {
        return NO;
    }
    NSData *payload = nil;
    @try {
        NSError *err = nil;
        payload = [NSJSONSerialization dataWithJSONObject:obj options:0 error:&err];
    } @catch (NSException *exception) {
        (void)exception;
        return NO;
    }
    if (payload == nil || payload.length == 0 || payload.length > CUB_MAX_FRAME_BYTES) {
        return NO;
    }
    uint32_t lenBE = htonl((uint32_t)payload.length);
    if (!cub_write_all(fd, (const uint8_t *)&lenBE, sizeof(lenBE))) {
        return NO;
    }
    return cub_write_all(fd, (const uint8_t *)payload.bytes, payload.length);
}

static NSDictionary *cub_read_json(int fd, BOOL *outEOF) {
    if (outEOF != NULL) {
        *outEOF = NO;
    }
    uint32_t lenBE = 0;
    int rc = cub_read_exact(fd, (uint8_t *)&lenBE, sizeof(lenBE));
    if (rc <= 0) {
        if (rc == 0 && outEOF != NULL) {
            *outEOF = YES;
        }
        return nil;
    }
    uint32_t len = ntohl(lenBE);
    if (len == 0 || len > CUB_MAX_FRAME_BYTES) {
        return nil;
    }
    uint8_t *buf = (uint8_t *)malloc((size_t)len);
    if (buf == NULL) {
        return nil;
    }
    int bodyRc = cub_read_exact(fd, buf, (size_t)len);
    if (bodyRc <= 0) {
        free(buf);
        if (bodyRc == 0 && outEOF != NULL) {
            *outEOF = YES;
        }
        return nil;
    }
    NSData *data = [NSData dataWithBytesNoCopy:buf length:(NSUInteger)len freeWhenDone:YES];
    id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![decoded isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return (NSDictionary *)decoded;
}

static NSArray<UIWindow *> *cub_collect_windows_on_main(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    UIApplication *app = [UIApplication sharedApplication];
    if (app != nil) {
        for (UIScene *scene in app.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *winScene = (UIWindowScene *)scene;
                for (UIWindow *win in winScene.windows) {
                    NSValue *ptr = [NSValue valueWithPointer:(__bridge const void *)win];
                    double alpha = cub_finite_double((double)win.alpha, 0.0);
                    if (![seen containsObject:ptr] && !win.hidden && alpha >= 0.01 && !cub_is_auxiliary_window(win)) {
                        [seen addObject:ptr];
                        [windows addObject:win];
                    }
                }
            }
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *win in app.windows) {
            NSValue *ptr = [NSValue valueWithPointer:(__bridge const void *)win];
            double alpha = cub_finite_double((double)win.alpha, 0.0);
            if (![seen containsObject:ptr] && !win.hidden && alpha >= 0.01 && !cub_is_auxiliary_window(win)) {
                [seen addObject:ptr];
                [windows addObject:win];
            }
        }
#pragma clang diagnostic pop
    }
    if (s_cub_observed_windows != nil) {
        for (UIWindow *win in s_cub_observed_windows) {
            NSValue *ptr = [NSValue valueWithPointer:(__bridge const void *)win];
            double alpha = cub_finite_double((double)win.alpha, 0.0);
            if (![seen containsObject:ptr] && !win.hidden && alpha >= 0.01 && !cub_is_auxiliary_window(win)) {
                [seen addObject:ptr];
                [windows addObject:win];
            }
        }
    }
    if (s_cub_cached_windows == nil) {
        s_cub_cached_windows = [NSMutableArray array];
    }
    [s_cub_cached_windows setArray:windows];
    return windows;
}

static UIWindow *cub_primary_window_on_main(void) {
    NSArray<UIWindow *> *windows = cub_collect_windows_on_main();
    UIWindow *chosen = nil;
    for (UIWindow *win in windows) {
        if (win.isKeyWindow) {
            chosen = win;
            break;
        }
    }
    if (chosen == nil) {
        chosen = windows.firstObject;
    }
    if (chosen != nil) {
        cub_record_viewport_size(chosen.bounds.size);
    }
    return chosen;
}

static NSString *cub_role_for_element(id element, BOOL *outIsList, BOOL *outIsCanvas) {
    if (outIsList != NULL) {
        *outIsList = NO;
    }
    if (outIsCanvas != NULL) {
        *outIsCanvas = NO;
    }
    if ([element isKindOfClass:[UIWindow class]]) {
        return @"win";
    }
    if ([element isKindOfClass:[UIButton class]]) {
        return @"btn";
    }
    if ([element isKindOfClass:[UISearchBar class]]) {
        return @"search";
    }
    if ([element isKindOfClass:[UITextField class]] || [element isKindOfClass:[UITextView class]]) {
        return @"input";
    }
    if ([element isKindOfClass:[UISwitch class]]) {
        return @"switch";
    }
    if ([element isKindOfClass:[UISlider class]]) {
        return @"slider";
    }
    if ([element isKindOfClass:[UILabel class]]) {
        return @"text";
    }
    if ([element isKindOfClass:[UIImageView class]]) {
        return @"img";
    }
    if ([element isKindOfClass:[UITableView class]] || [element isKindOfClass:[UICollectionView class]]) {
        if (outIsList != NULL) {
            *outIsList = YES;
        }
        return @"list";
    }
    if ([element isKindOfClass:[UITableViewCell class]] || [element isKindOfClass:[UICollectionViewCell class]]) {
        return @"row";
    }
    if ([element isKindOfClass:[UIScrollView class]]) {
        return @"scroll";
    }
    Class mtkViewCls = NSClassFromString(@"MTKView");
    if (mtkViewCls != Nil && [element isKindOfClass:mtkViewCls]) {
        if (outIsCanvas != NULL) {
            *outIsCanvas = YES;
        }
        return @"canvas";
    }
    Class wkWebCls = NSClassFromString(@"WKWebView");
    if (wkWebCls != Nil && [element isKindOfClass:wkWebCls]) {
        return @"web";
    }

    if ([element respondsToSelector:@selector(accessibilityTraits)]) {
        UIAccessibilityTraits traits = [element accessibilityTraits];
        if ((traits & UIAccessibilityTraitButton) != 0) {
            return @"btn";
        }
        if ((traits & UIAccessibilityTraitLink) != 0) {
            return @"link";
        }
        if ((traits & UIAccessibilityTraitStaticText) != 0) {
            return @"text";
        }
        if ((traits & UIAccessibilityTraitImage) != 0) {
            return @"img";
        }
        if ((traits & UIAccessibilityTraitAdjustable) != 0) {
            return @"slider";
        }
    }
    return NSStringFromClass([element class]) ?: @"UIView";
}

static BOOL cub_is_interactive_element(id element, NSString *role) {
    if ([role isEqualToString:@"btn"] || [role isEqualToString:@"input"] || [role isEqualToString:@"search"] ||
        [role isEqualToString:@"switch"] || [role isEqualToString:@"slider"] || [role isEqualToString:@"link"] ||
        [role isEqualToString:@"row"]) {
        return YES;
    }
    if ([element isKindOfClass:[UIControl class]]) {
        return YES;
    }
    if ([element conformsToProtocol:@protocol(UITextInput)]) {
        return YES;
    }
    if ([element isKindOfClass:[UIView class]]) {
        UIView *view = (UIView *)element;
        if (view.isUserInteractionEnabled && view.gestureRecognizers.count > 0) {
            return YES;
        }
    }
    if ([element respondsToSelector:@selector(isAccessibilityElement)] && [element isAccessibilityElement]) {
        UIAccessibilityTraits traits = [element accessibilityTraits];
        if ((traits & (UIAccessibilityTraitButton | UIAccessibilityTraitLink | UIAccessibilityTraitAdjustable)) != 0) {
            return YES;
        }
    }
    return NO;
}

static NSDictionary *cub_rect_dict(CGRect r) {
    BOOL invalid = CGRectIsNull(r) || CGRectIsEmpty(r) || CGRectIsInfinite(r) || !isfinite((double)r.origin.x) ||
                   !isfinite((double)r.origin.y) || !isfinite((double)r.size.width) || !isfinite((double)r.size.height);
    return @{
        @"x" : @(invalid ? 0.0 : (double)r.origin.x),
        @"y" : @(invalid ? 0.0 : (double)r.origin.y),
        @"width" : @(invalid ? 0.0 : (double)r.size.width),
        @"height" : @(invalid ? 0.0 : (double)r.size.height)
    };
}

static NSDictionary *cub_snapshot_node(id element, UIWindow *window, NSUInteger depth, NSUInteger *counter,
                                       BOOL *hasInteractive, BOOL *sawCanvas, NSMutableSet<NSValue *> *visited) {
    if (element == nil || depth > CUB_MAX_TREE_DEPTH || *counter >= CUB_MAX_TREE_NODES) {
        return nil;
    }
    if (cub_is_internal_overlay_view(element)) {
        return nil;
    }
    NSValue *ptrVal = [NSValue valueWithPointer:(__bridge const void *)element];
    if ([visited containsObject:ptrVal]) {
        return nil;
    }
    [visited addObject:ptrVal];

    BOOL isHidden = NO;
    double alpha = 1.0;
    BOOL enabled = YES;
    BOOL selected = NO;
    BOOL focused = NO;
    CGRect frameInWin = CGRectZero;

    if ([element isKindOfClass:[UIView class]]) {
        UIView *view = (UIView *)element;
        isHidden = view.isHidden;
        double rawAlpha = (double)view.alpha;
        alpha = isfinite(rawAlpha) ? fmin(fmax(rawAlpha, 0.0), 1.0) : 0.0;
        if (isHidden || alpha < 0.01) {
            return nil;
        }
        frameInWin = (window != nil) ? [view convertRect:view.bounds toView:window] : view.frame;
        focused = view.isFocused;
        if ([view isKindOfClass:[UIControl class]]) {
            UIControl *ctrl = (UIControl *)view;
            enabled = ctrl.isEnabled;
            selected = ctrl.isSelected;
        }
    } else if ([element respondsToSelector:@selector(accessibilityFrame)]) {
        CGRect accFrame = [element accessibilityFrame];
        if (CGRectIsNull(accFrame) || CGRectIsInfinite(accFrame)) {
            frameInWin = CGRectZero;
        } else {
            UIScreen *winScreen = window.screen;
            frameInWin = (window != nil && winScreen != nil)
                             ? [window convertRect:accFrame fromCoordinateSpace:winScreen.fixedCoordinateSpace]
                             : accFrame;
        }
        if ([element respondsToSelector:@selector(accessibilityElementsHidden)] &&
            [element accessibilityElementsHidden]) {
            return nil;
        }
    }

    *counter += 1U;
    NSString *nodeID = [NSString stringWithFormat:@"br-%lu", (unsigned long)*counter];
    [s_cub_node_cache setObject:element forKey:nodeID];

    BOOL isList = NO;
    BOOL isCanvas = NO;
    NSString *role = cub_role_for_element(element, &isList, &isCanvas);
    if (isCanvas) {
        *sawCanvas = YES;
    }

    NSString *label = nil;
    if ([element respondsToSelector:@selector(accessibilityLabel)]) {
        label = cub_string_from_obj([element accessibilityLabel]);
    }
    if (label.length == 0 && [element isKindOfClass:[UIButton class]]) {
        label = cub_string_from_obj([(UIButton *)element currentTitle]);
    } else if (label.length == 0 && [element isKindOfClass:[UILabel class]]) {
        label = cub_string_from_obj([(UILabel *)element text]);
    } else if (label.length == 0 && [element isKindOfClass:[UITextField class]]) {
        label = cub_string_from_obj([(UITextField *)element placeholder]);
    }

    NSString *valueStr = nil;
    if ([element isKindOfClass:[UITextField class]]) {
        valueStr = cub_string_from_obj([(UITextField *)element text]);
    } else if ([element isKindOfClass:[UITextView class]]) {
        valueStr = cub_string_from_obj([(UITextView *)element text]);
    } else if ([element isKindOfClass:[UISwitch class]]) {
        valueStr = [(UISwitch *)element isOn] ? @"1" : @"0";
    } else if ([element isKindOfClass:[UISlider class]]) {
        double sliderVal = cub_finite_double((double)[(UISlider *)element value], 0.0);
        valueStr = [NSString stringWithFormat:@"%.2f", sliderVal];
    } else if ([element respondsToSelector:@selector(accessibilityValue)]) {
        valueStr = cub_string_from_obj([element accessibilityValue]);
    }

    NSString *hint = [element respondsToSelector:@selector(accessibilityHint)]
                         ? cub_string_from_obj([element accessibilityHint])
                         : nil;
    NSString *identifier = nil;
    if ([element respondsToSelector:@selector(accessibilityIdentifier)]) {
        identifier = cub_string_from_obj([element accessibilityIdentifier]);
    }

    BOOL interactive = cub_is_interactive_element(element, role);
    if (interactive) {
        *hasInteractive = YES;
    }
    NSArray<NSString *> *actions = interactive ? @[ @"press", @"tap" ] : @[];

    NSMutableArray<id> *rawChildren = [NSMutableArray array];
    if ([element respondsToSelector:@selector(accessibilityElements)]) {
        id accElemsObj = [element accessibilityElements];
        if ([accElemsObj isKindOfClass:[NSArray class]] && [(NSArray *)accElemsObj count] > 0) {
            [rawChildren addObjectsFromArray:(NSArray *)accElemsObj];
        }
    }
    if (rawChildren.count == 0 && [element respondsToSelector:@selector(accessibilityElementCount)]) {
        NSInteger count = [element accessibilityElementCount];
        if (count != NSNotFound && count > 0 && count < 500) {
            for (NSInteger idx = 0; idx < count; idx++) {
                id childAcc = [element accessibilityElementAtIndex:idx];
                if (childAcc != nil) {
                    [rawChildren addObject:childAcc];
                }
            }
        }
    }
    if (rawChildren.count == 0 && [element isKindOfClass:[UIView class]]) {
        [rawChildren addObjectsFromArray:[(UIView *)element subviews]];
    }

    NSMutableArray<NSDictionary *> *childDicts = [NSMutableArray arrayWithCapacity:rawChildren.count];
    for (id child in rawChildren) {
        if (*counter >= CUB_MAX_TREE_NODES) {
            break;
        }
        NSDictionary *childDict =
            cub_snapshot_node(child, window, depth + 1U, counter, hasInteractive, sawCanvas, visited);
        if (childDict != nil) {
            [childDicts addObject:childDict];
        }
    }

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"id"] = nodeID;
    dict[@"role"] = role ?: @"UIView";
    if (label.length > 0) {
        dict[@"label"] = label;
    }
    if (valueStr.length > 0) {
        dict[@"value"] = valueStr;
    }
    if (hint.length > 0) {
        dict[@"hint"] = hint;
    }
    if (identifier.length > 0) {
        dict[@"identifier"] = identifier;
    }
    dict[@"enabled"] = @(enabled);
    dict[@"selected"] = @(selected);
    dict[@"focused"] = @(focused);
    dict[@"hidden"] = @(NO);
    dict[@"alpha"] = @(cub_finite_double(alpha, 1.0));
    dict[@"frame"] = cub_rect_dict(frameInWin);
    dict[@"actions"] = actions;
    dict[@"isInteractive"] = @(interactive);
    dict[@"isListContainer"] = @(isList);
    dict[@"isCanvas"] = @(isCanvas);
    dict[@"children"] = childDicts;
    return dict;
}

static NSDictionary *cub_handle_get_ui_tree(NSString *bundleID) {
    __block NSDictionary *snapshot = nil;
    BOOL completed = cub_run_on_main_with_timeout(5.0, ^{
        if (s_cub_node_cache == nil) {
            s_cub_node_cache = [NSMapTable strongToWeakObjectsMapTable];
        }
        [s_cub_node_cache removeAllObjects];

        UIWindow *primary = cub_primary_window_on_main();
        double winW = 1280.0;
        double winH = 800.0;
        cub_viewport_from_window_on_main(primary, &winW, &winH);
        NSUInteger counter = 0;
        BOOL hasInteractive = NO;
        BOOL sawCanvas = NO;
        NSMutableSet<NSValue *> *visited = [NSMutableSet set];
        NSDictionary *rootNode = nil;
        if (primary != nil) {
            rootNode = cub_snapshot_node(primary, primary, 0U, &counter, &hasInteractive, &sawCanvas, visited);
        }
        if (rootNode == nil) {
            rootNode = @{
                @"id" : @"br-root",
                @"role" : @"win",
                @"label" : bundleID ?: @"",
                @"enabled" : @(YES),
                @"selected" : @(NO),
                @"focused" : @(NO),
                @"hidden" : @(NO),
                @"alpha" : @(1.0),
                @"frame" : cub_rect_dict(CGRectMake(0.0, 0.0, (CGFloat)winW, (CGFloat)winH)),
                @"actions" : @[],
                @"isInteractive" : @(NO),
                @"isListContainer" : @(NO),
                @"isCanvas" : @(sawCanvas),
                @"children" : @[]
            };
        }
        BOOL canvasOnly = (sawCanvas && !hasInteractive);
        snapshot = @{
            @"bundleID" : bundleID ?: @"",
            @"pid" : @(getpid()),
            @"width" : @(winW),
            @"height" : @(winH),
            @"logicalWidth" : @(winW),
            @"logicalHeight" : @(winH),
            @"source" : @"bridge",
            @"isCanvasOnlyHint" : @(canvasOnly),
            @"root" : rootNode
        };
    });
    if (!completed || snapshot == nil) {
        return cub_timeout_error_response();
    }
    return @{@"ok" : @(YES), @"result" : snapshot};
}

static NSDictionary *cub_handle_activate_node(NSDictionary *params) {
    NSString *nodeID = params[@"nodeID"];
    if (![nodeID isKindOfClass:[NSString class]] || nodeID.length == 0) {
        return @{@"ok" : @(NO), @"error" : @"Missing nodeID"};
    }
    __block id targetObj = nil;
    __block BOOL dispatchAsyncControl = NO;
    __block BOOL canTryAccessibility = NO;
    __block double vpW = 1280.0;
    __block double vpH = 800.0;
    cub_current_logical_size_safe(&vpW, &vpH);

    BOOL lookupOK = cub_run_on_main_with_timeout(2.0, ^{
        UIWindow *primary = cub_primary_window_on_main();
        cub_viewport_from_window_on_main(primary, &vpW, &vpH);
        id obj = cub_find_node_by_id(nodeID);
        if (obj == nil) {
            return;
        }
        targetObj = obj;
        if ([obj isKindOfClass:[UIControl class]]) {
            UIControl *ctrl = (UIControl *)obj;
            if (ctrl.isEnabled &&
                ([obj isKindOfClass:[UIButton class]] || (ctrl.allControlEvents & UIControlEventTouchUpInside) != 0 ||
                 ctrl.allTargets.count > 0)) {
                dispatchAsyncControl = YES;
                return;
            }
        }
        if ([obj respondsToSelector:@selector(accessibilityActivate)]) {
            canTryAccessibility = YES;
        } else if ([obj isKindOfClass:[UIControl class]] && [(UIControl *)obj isEnabled]) {
            dispatchAsyncControl = YES;
        }
    });
    if (!lookupOK) {
        return cub_timeout_error_response();
    }
    if (targetObj == nil) {
        return @{@"ok" : @(NO), @"error" : @"Node unavailable or not activatable"};
    }

    if (dispatchAsyncControl) {
        UIControl *ctrl = (UIControl *)targetObj;
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                if (ctrl.isEnabled) {
                    [ctrl sendActionsForControlEvents:UIControlEventTouchUpInside];
                }
            }
        });
        return @{
            @"ok" : @(YES),
            @"result" : @{@"activated" : @(YES), @"logicalWidth" : @(vpW), @"logicalHeight" : @(vpH)}
        };
    }

    if (canTryAccessibility) {
        __block BOOL activated = NO;
        id objRef = targetObj;
        BOOL actCompleted = cub_run_on_main_with_timeout(2.0, ^{
            activated = [objRef accessibilityActivate];
            if (!activated && [objRef isKindOfClass:[UIControl class]]) {
                UIControl *ctrl = (UIControl *)objRef;
                if (ctrl.isEnabled) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        @autoreleasepool {
                            if (ctrl.isEnabled) {
                                [ctrl sendActionsForControlEvents:UIControlEventTouchUpInside];
                            }
                        }
                    });
                    activated = YES;
                }
            }
        });
        if (!actCompleted) {
            return cub_timeout_error_response();
        }
        if (activated) {
            return @{
                @"ok" : @(YES),
                @"result" : @{@"activated" : @(YES), @"logicalWidth" : @(vpW), @"logicalHeight" : @(vpH)}
            };
        }
    }

    return @{@"ok" : @(NO), @"error" : @"Node unavailable or not activatable"};
}

static NSDictionary *cub_handle_set_text(NSDictionary *params) {
    NSString *nodeID = params[@"nodeID"];
    NSString *text = [params[@"text"] isKindOfClass:[NSString class]] ? params[@"text"] : @"";
    BOOL clearFirst = cub_bool_from_obj(params[@"clear"], YES);
    if (![nodeID isKindOfClass:[NSString class]] || nodeID.length == 0) {
        return @{@"ok" : @(NO), @"error" : @"Missing nodeID"};
    }
    __block BOOL updated = NO;
    __block double vpW = 1280.0;
    __block double vpH = 800.0;
    cub_current_logical_size_safe(&vpW, &vpH);
    BOOL completed = cub_run_on_main_with_timeout(3.0, ^{
        UIWindow *primary = cub_primary_window_on_main();
        cub_viewport_from_window_on_main(primary, &vpW, &vpH);
        id obj = cub_find_node_by_id(nodeID);
        if (obj == nil) {
            return;
        }
        if ([obj isKindOfClass:[UIResponder class]]) {
            [(UIResponder *)obj becomeFirstResponder];
        }
        if ([obj conformsToProtocol:@protocol(UITextInput)]) {
            id<UITextInput> input = (id<UITextInput>)obj;
            if (clearFirst && input.beginningOfDocument != nil && input.endOfDocument != nil) {
                UITextRange *fullRange = [input textRangeFromPosition:input.beginningOfDocument
                                                           toPosition:input.endOfDocument];
                if (fullRange != nil) {
                    [input replaceRange:fullRange withText:text];
                    updated = YES;
                    return;
                }
            }
            [input insertText:text];
            updated = YES;
            return;
        }
        if ([obj isKindOfClass:[UITextField class]]) {
            UITextField *tf = (UITextField *)obj;
            tf.text = clearFirst ? text : [(tf.text ?: @"") stringByAppendingString:text];
            dispatch_async(dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    [tf sendActionsForControlEvents:UIControlEventEditingChanged];
                }
            });
            updated = YES;
        } else if ([obj isKindOfClass:[UITextView class]]) {
            UITextView *tv = (UITextView *)obj;
            tv.text = clearFirst ? text : [(tv.text ?: @"") stringByAppendingString:text];
            updated = YES;
        }
    });
    if (!completed) {
        return cub_timeout_error_response();
    }
    if (!updated) {
        return @{@"ok" : @(NO), @"error" : @"Target node is not text-editable"};
    }
    return @{@"ok" : @(YES), @"result" : @{@"updated" : @(YES), @"logicalWidth" : @(vpW), @"logicalHeight" : @(vpH)}};
}

static NSInteger cub_dispatch_fake_touch(Class fakeTouchCls, SEL sel, NSInteger touchID, CGPoint point,
                                         UITouchPhase phase, UIWindow *window) {
    UIView *hitView = (window != nil) ? [window hitTest:point withEvent:nil] : nil;
    CGPoint screenPoint =
        (window != nil) ? CGPointMake(point.x + window.frame.origin.x, point.y + window.frame.origin.y) : point;
    return ((NSInteger (*)(id, SEL, NSInteger, CGPoint, UITouchPhase, UIWindow *, UIView *))objc_msgSend)(
        fakeTouchCls, sel, touchID, screenPoint, phase, window, hitView);
}

static NSDictionary *cub_handle_touch(NSDictionary *params) {
    Class fakeTouchCls = NSClassFromString(@"PTFakeMetaTouch");
    SEL touchSel = sel_registerName("fakeTouchId:AtPoint:withTouchPhase:inWindow:onView:");
    if (fakeTouchCls == Nil || ![fakeTouchCls respondsToSelector:touchSel]) {
        return @{@"ok" : @(NO), @"error" : @"PTFakeMetaTouch runtime class unavailable"};
    }

    NSString *gesture = [params[@"gesture"] isKindOfClass:[NSString class]] ? params[@"gesture"] : @"tap";
    double x = cub_double_from_obj(params[@"x"], 0.0, NULL);
    double y = cub_double_from_obj(params[@"y"], 0.0, NULL);
    NSInteger durationMs = cub_integer_from_obj(params[@"durationMs"], 220);
    if (durationMs < 20) {
        durationMs = 20;
    } else if (durationMs > 5000) {
        durationMs = 5000;
    }

    __block UIWindow *window = nil;
    __block double vpW = 1280.0;
    __block double vpH = 800.0;
    if (!cub_run_on_main_with_timeout(3.0, ^{
            window = cub_primary_window_on_main();
            cub_viewport_from_window_on_main(window, &vpW, &vpH);
        })) {
        return cub_timeout_error_response();
    }
    if (window == nil) {
        return @{@"ok" : @(NO), @"error" : @"No active UIWindow in target process"};
    }

    if ([gesture isEqualToString:@"tap"] || [gesture isEqualToString:@"long_press"]) {
        NSInteger holdMs = [gesture isEqualToString:@"long_press"] ? durationMs : 35;
        CGPoint pt = CGPointMake((CGFloat)x, (CGFloat)y);
        __block NSInteger tid = -1;
        BOOL beganOK = cub_run_on_main_with_timeout(
            2.0, ^{ tid = cub_dispatch_fake_touch(fakeTouchCls, touchSel, -1, pt, UITouchPhaseBegan, window); });
        if (!beganOK) {
            return cub_timeout_error_response();
        }
        if (tid < 0) {
            return @{@"ok" : @(NO), @"error" : @"Failed to initiate touch"};
        }
        usleep((useconds_t)(holdMs * 1000L));
        BOOL endedOK = cub_run_on_main_with_timeout(
            2.0, ^{ (void)cub_dispatch_fake_touch(fakeTouchCls, touchSel, tid, pt, UITouchPhaseEnded, window); });
        if (!endedOK) {
            return cub_timeout_error_response();
        }
        return
            @{@"ok" : @(YES),
              @"result" : @{@"gesture" : gesture, @"logicalWidth" : @(vpW), @"logicalHeight" : @(vpH)}};
    }

    if ([gesture isEqualToString:@"swipe"] || [gesture isEqualToString:@"drag"]) {
        double toX = cub_double_from_obj(params[@"toX"], x, NULL);
        double toY = cub_double_from_obj(params[@"toY"], y, NULL);
        NSInteger steps = MAX(4, (durationMs + 15) / 16);
        CGPoint startPt = CGPointMake((CGFloat)x, (CGFloat)y);
        __block NSInteger tid = -1;
        BOOL beganOK = cub_run_on_main_with_timeout(
            2.0, ^{ tid = cub_dispatch_fake_touch(fakeTouchCls, touchSel, -1, startPt, UITouchPhaseBegan, window); });
        if (!beganOK) {
            return cub_timeout_error_response();
        }
        if (tid < 0) {
            return @{@"ok" : @(NO), @"error" : @"Failed to start swipe/drag touch"};
        }
        BOOL moveTimedOut = NO;
        for (NSInteger step = 1; step < steps; step++) {
            usleep(16667);
            double t = (double)step / (double)steps;
            CGPoint pt = CGPointMake((CGFloat)(x + (toX - x) * t), (CGFloat)(y + (toY - y) * t));
            if (!cub_run_on_main_with_timeout(2.0, ^{
                    (void)cub_dispatch_fake_touch(fakeTouchCls, touchSel, tid, pt, UITouchPhaseMoved, window);
                })) {
                moveTimedOut = YES;
                break;
            }
        }
        usleep(16667);
        CGPoint endPt = CGPointMake((CGFloat)toX, (CGFloat)toY);
        UITouchPhase finalPhase = moveTimedOut ? UITouchPhaseCancelled : UITouchPhaseEnded;
        BOOL endedOK = cub_run_on_main_with_timeout(
            2.0, ^{ (void)cub_dispatch_fake_touch(fakeTouchCls, touchSel, tid, endPt, finalPhase, window); });
        if (moveTimedOut || !endedOK) {
            return cub_timeout_error_response();
        }
        return
            @{@"ok" : @(YES),
              @"result" : @{@"gesture" : gesture, @"logicalWidth" : @(vpW), @"logicalHeight" : @(vpH)}};
    }

    if ([gesture isEqualToString:@"pinch"]) {
        double scale = cub_double_from_obj(params[@"scale"], 1.5, NULL);
        if (scale <= 0.05) {
            scale = 0.05;
        }
        double startHalf = 80.0;
        double endHalf = startHalf * scale;
        NSInteger steps = MAX(6, (durationMs + 15) / 16);
        CGPoint p1Start = CGPointMake((CGFloat)(x - startHalf), (CGFloat)y);
        CGPoint p2Start = CGPointMake((CGFloat)(x + startHalf), (CGFloat)y);
        __block NSInteger tid1 = -1;
        __block NSInteger tid2 = -1;
        BOOL beganOK = cub_run_on_main_with_timeout(2.0, ^{
            tid1 = cub_dispatch_fake_touch(fakeTouchCls, touchSel, -1, p1Start, UITouchPhaseBegan, window);
            tid2 = cub_dispatch_fake_touch(fakeTouchCls, touchSel, -1, p2Start, UITouchPhaseBegan, window);
        });
        if (!beganOK || tid1 < 0 || tid2 < 0) {
            (void)cub_run_on_main_with_timeout(2.0, ^{
                if (tid1 >= 0) {
                    (void)cub_dispatch_fake_touch(fakeTouchCls, touchSel, tid1, p1Start, UITouchPhaseCancelled, window);
                }
                if (tid2 >= 0) {
                    (void)cub_dispatch_fake_touch(fakeTouchCls, touchSel, tid2, p2Start, UITouchPhaseCancelled, window);
                }
            });
            if (!beganOK) {
                return cub_timeout_error_response();
            }
            return @{@"ok" : @(NO), @"error" : @"Failed to initiate two-finger pinch touch"};
        }
        BOOL moveTimedOut = NO;
        for (NSInteger step = 1; step < steps; step++) {
            usleep(16667);
            double t = (double)step / (double)steps;
            double half = startHalf + (endHalf - startHalf) * t;
            CGPoint p1 = CGPointMake((CGFloat)(x - half), (CGFloat)y);
            CGPoint p2 = CGPointMake((CGFloat)(x + half), (CGFloat)y);
            if (!cub_run_on_main_with_timeout(2.0, ^{
                    (void)cub_dispatch_fake_touch(fakeTouchCls, touchSel, tid1, p1, UITouchPhaseMoved, window);
                    (void)cub_dispatch_fake_touch(fakeTouchCls, touchSel, tid2, p2, UITouchPhaseMoved, window);
                })) {
                moveTimedOut = YES;
                break;
            }
        }
        usleep(16667);
        CGPoint p1End = CGPointMake((CGFloat)(x - endHalf), (CGFloat)y);
        CGPoint p2End = CGPointMake((CGFloat)(x + endHalf), (CGFloat)y);
        UITouchPhase finalPhase = moveTimedOut ? UITouchPhaseCancelled : UITouchPhaseEnded;
        BOOL endedOK = cub_run_on_main_with_timeout(2.0, ^{
            (void)cub_dispatch_fake_touch(fakeTouchCls, touchSel, tid1, p1End, finalPhase, window);
            (void)cub_dispatch_fake_touch(fakeTouchCls, touchSel, tid2, p2End, finalPhase, window);
        });
        if (moveTimedOut || !endedOK) {
            return cub_timeout_error_response();
        }
        return @{
            @"ok" : @(YES),
            @"result" : @{@"gesture" : @"pinch", @"logicalWidth" : @(vpW), @"logicalHeight" : @(vpH)}
        };
    }

    return @{@"ok" : @(NO), @"error" : @"Unsupported touch gesture"};
}

static NSDictionary *cub_handle_screenshot(NSDictionary *params) {
    NSInteger maxDim = cub_integer_from_obj(params[@"maxDim"], 768);
    if (maxDim < 128) {
        maxDim = 128;
    } else if (maxDim > 2048) {
        maxDim = 2048;
    }
    NSString *format =
        [params[@"format"] isKindOfClass:[NSString class]] ? [params[@"format"] lowercaseString] : @"jpeg";
    double quality = cub_double_from_obj(params[@"quality"], 0.65, NULL);
    if (quality < 0.2) {
        quality = 0.2;
    } else if (quality > 1.0) {
        quality = 1.0;
    }

    BOOL hasClip = NO;
    CGRect parsedClip = CGRectZero;
    id clipRaw = params[@"clipRect"];
    if (clipRaw != nil && clipRaw != [NSNull null]) {
        if (![clipRaw isKindOfClass:[NSDictionary class]]) {
            return @{@"ok" : @(NO), @"error" : @"Invalid clipRect"};
        }
        NSDictionary *clipDict = (NSDictionary *)clipRaw;
        BOOL xOK = NO;
        BOOL yOK = NO;
        BOOL wOK = NO;
        BOOL hOK = NO;
        double cx = cub_double_from_obj(clipDict[@"x"], 0.0, &xOK);
        double cy = cub_double_from_obj(clipDict[@"y"], 0.0, &yOK);
        double cw = cub_double_from_obj(clipDict[@"w"], 0.0, &wOK);
        double ch = cub_double_from_obj(clipDict[@"h"], 0.0, &hOK);
        if (!xOK || !yOK || !wOK || !hOK || cw <= 0.0 || ch <= 0.0) {
            return @{@"ok" : @(NO), @"error" : @"Invalid clipRect coordinates"};
        }
        hasClip = YES;
        parsedClip = CGRectMake((CGFloat)cx, (CGFloat)cy, (CGFloat)cw, (CGFloat)ch);
    }

    __block NSString *b64 = nil;
    __block NSString *mime = nil;
    __block NSInteger outW = 0;
    __block NSInteger outH = 0;
    __block double vpW = 1280.0;
    __block double vpH = 800.0;
    __block NSString *errMsg = nil;

    BOOL completed = cub_run_on_main_with_timeout(5.0, ^{
        UIWindow *window = cub_primary_window_on_main();
        if (window == nil || CGRectIsEmpty(window.bounds) || CGRectIsInfinite(window.bounds)) {
            errMsg = @"No active UIWindow to capture";
            return;
        }
        cub_viewport_from_window_on_main(window, &vpW, &vpH);
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
        fmt.scale = 1.0;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:window.bounds format:fmt];
        NSMutableArray<UIView *> *hiddenOverlays = [NSMutableArray array];
        cub_collect_visible_internal_overlays(window, hiddenOverlays, 0);
        UIImage *rendered = nil;
        @try {
            for (UIView *overlay in hiddenOverlays) {
                overlay.hidden = YES;
            }
            rendered = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                BOOL drew = [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
                if (!drew) {
                    [window.layer renderInContext:ctx.CGContext];
                }
            }];
        } @finally {
            for (UIView *overlay in hiddenOverlays) {
                overlay.hidden = NO;
            }
        }
        CGImageRef cgImg = rendered.CGImage;
        if (cgImg == NULL) {
            errMsg = @"Failed to render window image";
            return;
        }
        UIImage *finalImg = rendered;
        if (hasClip) {
            CGRect crop = CGRectIntersection(parsedClip,
                                             CGRectMake(0.0, 0.0, window.bounds.size.width, window.bounds.size.height));
            if (CGRectIsNull(crop) || crop.size.width < 2.0 || crop.size.height < 2.0) {
                errMsg = @"clipRect does not intersect active window";
                return;
            }
            CGImageRef cropped = CGImageCreateWithImageInRect(cgImg, crop);
            if (cropped != NULL) {
                finalImg = [UIImage imageWithCGImage:cropped];
                CGImageRelease(cropped);
            }
        }
        CGSize curSize = finalImg.size;
        CGFloat maxSide = MAX(curSize.width, curSize.height);
        if (maxSide > (CGFloat)maxDim && maxSide > 0.0) {
            CGFloat ratio = (CGFloat)maxDim / maxSide;
            CGSize targetSize =
                CGSizeMake(MAX(1.0, round(curSize.width * ratio)), MAX(1.0, round(curSize.height * ratio)));
            UIGraphicsImageRenderer *scaleRenderer = [[UIGraphicsImageRenderer alloc] initWithSize:targetSize
                                                                                            format:fmt];
            finalImg = [scaleRenderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                (void)ctx;
                [finalImg drawInRect:CGRectMake(0.0, 0.0, targetSize.width, targetSize.height)];
            }];
        }

        NSData *encoded = nil;
        if ([format isEqualToString:@"png"]) {
            encoded = UIImagePNGRepresentation(finalImg);
            mime = @"image/png";
        } else {
            encoded = UIImageJPEGRepresentation(finalImg, (CGFloat)quality);
            mime = @"image/jpeg";
        }
        if (encoded == nil) {
            errMsg = @"Failed to encode captured image";
            return;
        }
        b64 = [encoded base64EncodedStringWithOptions:0];
        outW = (NSInteger)finalImg.size.width;
        outH = (NSInteger)finalImg.size.height;
    });

    if (!completed) {
        return cub_timeout_error_response();
    }
    if (errMsg != nil) {
        return @{@"ok" : @(NO), @"error" : errMsg};
    }
    return @{
        @"ok" : @(YES),
        @"result" : @{
            @"data" : b64 ?: @"",
            @"mimeType" : mime ?: @"image/jpeg",
            @"width" : @(outW),
            @"height" : @(outH),
            @"logicalWidth" : @(vpW),
            @"logicalHeight" : @(vpH)
        }
    };
}

static void cub_run_connection_loop(uint16_t port, NSString *token, NSString *bundleID) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return;
    }
    (void)fcntl(fd, F_SETFD, FD_CLOEXEC);
    uint64_t guard = CUB_FD_GUARD_MAGIC ^ ((uint64_t)(uint32_t)getpid() << 16) ^ (uint64_t)port;
    BOOL guarded = NO;
    if (&change_fdguard_np != NULL) {
        guarded = (change_fdguard_np(fd, NULL, 0, &guard, CUB_FD_GUARD_FLAGS, NULL) == 0);
    }
    cub_register_hidden_socket(fd, port);

    int yes = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    (void)setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = (uint8_t)sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");

    if (connect(fd, (const struct sockaddr *)&addr, sizeof(addr)) != 0) {
        cub_close_bridge_fd(fd, port, guard, guarded);
        return;
    }

    double logicalW = 1280.0;
    double logicalH = 800.0;
    cub_current_logical_size_safe(&logicalW, &logicalH);

    NSDictionary *hello = @{
        @"type" : @"hello",
        @"token" : token,
        @"bundleID" : bundleID,
        @"pid" : @(getpid()),
        @"logicalWidth" : @(logicalW),
        @"logicalHeight" : @(logicalH)
    };
    if (!cub_send_json(fd, hello)) {
        cub_close_bridge_fd(fd, port, guard, guarded);
        return;
    }

    BOOL eof = NO;
    NSDictionary *ack = cub_read_json(fd, &eof);
    if (ack == nil || !cub_bool_from_obj(ack[@"ok"], NO)) {
        cub_close_bridge_fd(fd, port, guard, guarded);
        return;
    }

    while (true) {
        BOOL loopEOF = NO;
        NSDictionary *req = cub_read_json(fd, &loopEOF);
        if (req == nil) {
            break;
        }
        NSString *method = [req[@"method"] isKindOfClass:[NSString class]] ? req[@"method"] : @"";
        NSDictionary *params = [req[@"params"] isKindOfClass:[NSDictionary class]] ? req[@"params"] : @{};
        NSDictionary *resp = nil;
        if ([method isEqualToString:@"get_ui_tree"]) {
            resp = cub_handle_get_ui_tree(bundleID);
        } else if ([method isEqualToString:@"activate_node"]) {
            resp = cub_handle_activate_node(params);
        } else if ([method isEqualToString:@"set_text"]) {
            resp = cub_handle_set_text(params);
        } else if ([method isEqualToString:@"touch"]) {
            resp = cub_handle_touch(params);
        } else if ([method isEqualToString:@"screenshot"]) {
            resp = cub_handle_screenshot(params);
        } else {
            resp = @{@"ok" : @(NO), @"error" : @"Unknown bridge method"};
        }
        if (!cub_send_json(fd, resp)) {
            break;
        }
    }

    cub_close_bridge_fd(fd, port, guard, guarded);
}

static void cub_record_observed_window(NSNotification *note) {
    UIWindow *win = [note.object isKindOfClass:[UIWindow class]] ? (UIWindow *)note.object : nil;
    if (win == nil || cub_is_auxiliary_window(win)) {
        return;
    }
    if (s_cub_observed_windows == nil) {
        s_cub_observed_windows = [NSHashTable weakObjectsHashTable];
    }
    [s_cub_observed_windows addObject:win];
    cub_record_viewport_size(win.bounds.size);
}

__attribute__((constructor)) static void cub_bootstrap(void) {
    uint16_t port = 0;
    char tokenBuf[128] = {0};
    char bundleBuf[256] = {0};

    typedef bool (*ConsumeBootstrapFn)(uint16_t *, char *, size_t, char *, size_t);
    ConsumeBootstrapFn consumeFn = (ConsumeBootstrapFn)dlsym(RTLD_DEFAULT, "pt_consume_automation_bootstrap");
    BOOL hasBootstrap = NO;
    if (consumeFn != NULL) {
        hasBootstrap = consumeFn(&port, tokenBuf, sizeof(tokenBuf), bundleBuf, sizeof(bundleBuf)) ? YES : NO;
    }

    if (!hasBootstrap) {
        const char *portRaw = getenv("MACOVER_AUTOMATION_PORT");
        const char *tokenRaw = getenv("MACOVER_AUTOMATION_TOKEN");
        const char *bundleRaw = getenv("MACOVER_AUTOMATION_BUNDLE_ID");
        const char *safeRaw = getenv("PLAYTOOLS_SAFE_MODE");

        char portBuf[16] = {0};
        if (portRaw != NULL) {
            strlcpy(portBuf, portRaw, sizeof(portBuf));
        }
        if (tokenRaw != NULL) {
            strlcpy(tokenBuf, tokenRaw, sizeof(tokenBuf));
        }
        if (bundleRaw != NULL) {
            strlcpy(bundleBuf, bundleRaw, sizeof(bundleBuf));
        }

        unsetenv("MACOVER_AUTOMATION_PORT");
        unsetenv("MACOVER_AUTOMATION_TOKEN");
        unsetenv("MACOVER_AUTOMATION_BUNDLE_ID");

        if (safeRaw != NULL && strcmp(safeRaw, "1") == 0) {
            cub_secure_zero_bytes(portBuf, sizeof(portBuf));
            cub_secure_zero_bytes(tokenBuf, sizeof(tokenBuf));
            cub_secure_zero_bytes(bundleBuf, sizeof(bundleBuf));
            return;
        }
        if (portBuf[0] == '\0' || tokenBuf[0] == '\0' || bundleBuf[0] == '\0') {
            cub_secure_zero_bytes(portBuf, sizeof(portBuf));
            cub_secure_zero_bytes(tokenBuf, sizeof(tokenBuf));
            cub_secure_zero_bytes(bundleBuf, sizeof(bundleBuf));
            return;
        }
        char *endPtr = NULL;
        long parsedPort = strtol(portBuf, &endPtr, 10);
        cub_secure_zero_bytes(portBuf, sizeof(portBuf));
        if (endPtr == portBuf || *endPtr != '\0' || parsedPort <= 0 || parsedPort > 65535) {
            cub_secure_zero_bytes(tokenBuf, sizeof(tokenBuf));
            cub_secure_zero_bytes(bundleBuf, sizeof(bundleBuf));
            return;
        }
        port = (uint16_t)parsedPort;
    }

    const char *safeEnv = getenv("PLAYTOOLS_SAFE_MODE");
    if (safeEnv != NULL && strcmp(safeEnv, "1") == 0) {
        cub_secure_zero_bytes(tokenBuf, sizeof(tokenBuf));
        cub_secure_zero_bytes(bundleBuf, sizeof(bundleBuf));
        return;
    }
    if (port == 0 || tokenBuf[0] == '\0' || bundleBuf[0] == '\0') {
        cub_secure_zero_bytes(tokenBuf, sizeof(tokenBuf));
        cub_secure_zero_bytes(bundleBuf, sizeof(bundleBuf));
        return;
    }

    NSString *token = [NSString stringWithUTF8String:tokenBuf];
    NSString *bundleID = [NSString stringWithUTF8String:bundleBuf];
    cub_secure_zero_bytes(tokenBuf, sizeof(tokenBuf));
    cub_secure_zero_bytes(bundleBuf, sizeof(bundleBuf));
    if (token.length == 0 || bundleID.length == 0) {
        return;
    }

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    s_cub_win_visible_obs = [center addObserverForName:UIWindowDidBecomeVisibleNotification
                                                object:nil
                                                 queue:[NSOperationQueue mainQueue]
                                            usingBlock:^(NSNotification *note) { cub_record_observed_window(note); }];
    s_cub_win_key_obs = [center addObserverForName:UIWindowDidBecomeKeyNotification
                                            object:nil
                                             queue:[NSOperationQueue mainQueue]
                                        usingBlock:^(NSNotification *note) { cub_record_observed_window(note); }];

    s_cub_io_queue = dispatch_queue_create("com.apple.uikit.axbridge", DISPATCH_QUEUE_SERIAL);
    dispatch_async(s_cub_io_queue, ^{
        @autoreleasepool {
            cub_run_connection_loop(port, token, bundleID);
        }
    });
}
