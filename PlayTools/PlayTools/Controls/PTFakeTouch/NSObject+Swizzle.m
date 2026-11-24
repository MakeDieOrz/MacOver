//
//  NSObject+PrivateSwizzle.m
//  PlayTools
//
//  Created by siri on 06.10.2021.
//

#import "NSObject+Swizzle.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <string.h>
#import "CoreGraphics/CoreGraphics.h"
#import "UIKit/UIKit.h"
#import <PlayTools/PlayTools-Swift.h>
#import "PTFakeMetaTouch.h"
#import <VideoSubscriberAccount/VideoSubscriberAccount.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMotion/CoreMotion.h>
#import <GameController/GameController.h>

extern __attribute__((visibility("hidden"))) void pt_ensure_playloader_early_init(void);
extern __attribute__((visibility("hidden"))) BOOL pt_is_bypass_enabled(void);
extern __attribute__((visibility("hidden"))) BOOL pt_is_effective_system_or_playtools_caller(const void *ret_addr);
extern __attribute__((visibility("hidden"))) void pt_get_spoofed_screen_native_bounds(double *out_portrait_width, double *out_portrait_height, double *out_native_scale);
extern __attribute__((visibility("hidden"))) double pt_get_device_native_scale(void);
extern __attribute__((visibility("hidden"))) uint32_t pt_get_device_max_fps(void);
extern __attribute__((visibility("hidden"))) const char *pt_get_device_model_cstr(void);
extern __attribute__((visibility("hidden"))) void pt_register_swizzled_imp(const void *hook_imp, const void *orig_imp);
extern __attribute__((visibility("hidden"))) void pt_register_hidden_swizzle_selector(SEL sel);
extern __attribute__((visibility("hidden"))) BOOL pt_is_address_in_playtools(const void *addr);

__attribute__((visibility("hidden")))
@interface PTSwizzleHooks : NSObject
@end

__attribute__((visibility("hidden")))
@interface PTSwizzleLoader : NSObject
@end

void pt_swizzle_instance_method(Class cls, SEL origSelector, SEL newSelector)
{
    if (cls == Nil || origSelector == NULL || newSelector == NULL) {
        return;
    }
    Method originalMethod = class_getInstanceMethod(cls, origSelector);
    Method swizzledMethod = class_getInstanceMethod([PTSwizzleHooks class], newSelector);
    if (!swizzledMethod) {
        swizzledMethod = class_getInstanceMethod(cls, newSelector);
    }
    if (!originalMethod || !swizzledMethod) {
        return;
    }

    IMP hookIMP = method_getImplementation(swizzledMethod);
    IMP origIMP = method_getImplementation(originalMethod);
    const char *origTypes = method_getTypeEncoding(originalMethod);
    const char *swizzledTypes = method_getTypeEncoding(swizzledMethod);
    if (class_addMethod(cls,
                        origSelector,
                        hookIMP,
                        swizzledTypes)) {
        class_replaceMethod(cls,
                            newSelector,
                            origIMP,
                            origTypes);
        pt_register_hidden_swizzle_selector(newSelector);
        pt_register_swizzled_imp((const void *)hookIMP, (const void *)origIMP);
    } else {
        IMP prevIMP = class_replaceMethod(cls,
                                          origSelector,
                                          hookIMP,
                                          swizzledTypes);
        IMP actualOrig = prevIMP ?: origIMP;
        class_replaceMethod(cls,
                            newSelector,
                            actualOrig,
                            origTypes);
        pt_register_hidden_swizzle_selector(newSelector);
        pt_register_swizzled_imp((const void *)hookIMP, (const void *)actualOrig);
    }
}

static void pt_replace_instance_imp(Class cls, SEL origSel, IMP hookIMP, IMP *outOrigIMP) {
    if (cls == Nil || origSel == NULL || hookIMP == NULL) {
        return;
    }
    Method origMethod = class_getInstanceMethod(cls, origSel);
    if (origMethod == NULL) {
        return;
    }
    IMP prev = method_getImplementation(origMethod);
    if (prev == hookIMP) {
        return;
    }
    IMP replaced = class_replaceMethod(cls, origSel, hookIMP, method_getTypeEncoding(origMethod));
    IMP actualOrig = replaced ?: prev;
    pt_register_swizzled_imp((const void *)hookIMP, (const void *)actualOrig);
    if (outOrigIMP != NULL && *outOrigIMP == NULL) {
        *outOrigIMP = actualOrig;
    }
}

static void pt_replace_class_imp(Class cls, SEL origSel, IMP hookIMP, IMP *outOrigIMP) {
    if (cls == Nil || origSel == NULL || hookIMP == NULL) {
        return;
    }
    Method origMethod = class_getClassMethod(cls, origSel);
    if (origMethod == NULL) {
        return;
    }
    Class metaCls = object_getClass((id)cls);
    IMP prev = method_getImplementation(origMethod);
    if (prev == hookIMP) {
        return;
    }
    IMP replaced = class_replaceMethod(metaCls, origSel, hookIMP, method_getTypeEncoding(origMethod));
    IMP actualOrig = replaced ?: prev;
    pt_register_swizzled_imp((const void *)hookIMP, (const void *)actualOrig);
    if (outOrigIMP != NULL && *outOrigIMP == NULL) {
        *outOrigIMP = actualOrig;
    }
}

static os_unfair_lock s_swz_imp_lock = OS_UNFAIR_LOCK_INIT;
static CFMutableDictionaryRef s_orig_screenmode_size_imps = NULL;
static CFMutableDictionaryRef s_orig_screenmode_aspect_imps = NULL;
static CFMutableDictionaryRef s_orig_fbs_disp_name_imps = NULL;
static CFMutableDictionaryRef s_orig_fbs_disp_devname_imps = NULL;
static CFMutableDictionaryRef s_orig_fbs_disp_hwid_imps = NULL;
static CFMutableDictionaryRef s_orig_fbs_disp_pixelsize_imps = NULL;
static CFMutableDictionaryRef s_orig_fbs_disp_pointscale_imps = NULL;

#define PT_SWIZZLE_MAX_ACTIVE_FRAMES 32

typedef struct {
    const void *self_ptr;
    CFMutableDictionaryRef dict;
    Class dispatched_cls;
} pt_swizzle_active_frame_t;

typedef struct {
    pt_swizzle_active_frame_t frames[PT_SWIZZLE_MAX_ACTIVE_FRAMES];
    int depth;
} pt_swizzle_active_stack_t;

static _Thread_local pt_swizzle_active_stack_t tls_pt_swizzle_stack = { .depth = 0 };

static Class pt_find_defining_class(Class cls, SEL origSel) {
    for (Class c = cls; c != Nil; c = class_getSuperclass(c)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(c, &count);
        if (methods != NULL) {
            BOOL found = NO;
            for (unsigned int i = 0; i < count; i++) {
                if (method_getName(methods[i]) == origSel) {
                    found = YES;
                    break;
                }
            }
            free(methods);
            if (found) {
                return c;
            }
        }
    }
    return Nil;
}

static IMP pt_lookup_stored_imp_and_push(CFMutableDictionaryRef dict, id self, BOOL *outPushed) {
    if (outPushed != NULL) {
        *outPushed = NO;
    }
    if (self == nil || dict == NULL) {
        return NULL;
    }
    Class startCls = object_getClass(self);
    if (tls_pt_swizzle_stack.depth > 0) {
        pt_swizzle_active_frame_t *top = &tls_pt_swizzle_stack.frames[tls_pt_swizzle_stack.depth - 1];
        if (top->self_ptr == (__bridge const void *)self && top->dict == dict) {
            startCls = class_getSuperclass(top->dispatched_cls);
        }
    }
    os_unfair_lock_lock(&s_swz_imp_lock);
    IMP origIMP = NULL;
    Class matchedCls = Nil;
    for (Class c = startCls; c != Nil; c = class_getSuperclass(c)) {
        const void *val = CFDictionaryGetValue(dict, (__bridge const void *)c);
        if (val != NULL) {
            origIMP = (IMP)val;
            matchedCls = c;
            break;
        }
    }
    os_unfair_lock_unlock(&s_swz_imp_lock);
    if (origIMP != NULL && matchedCls != Nil && tls_pt_swizzle_stack.depth < PT_SWIZZLE_MAX_ACTIVE_FRAMES) {
        tls_pt_swizzle_stack.frames[tls_pt_swizzle_stack.depth++] = (pt_swizzle_active_frame_t){
            .self_ptr = (__bridge const void *)self,
            .dict = dict,
            .dispatched_cls = matchedCls
        };
        if (outPushed != NULL) {
            *outPushed = YES;
        }
    }
    return origIMP;
}

static inline void pt_pop_stored_imp_frame(BOOL pushed) {
    if (pushed && tls_pt_swizzle_stack.depth > 0) {
        tls_pt_swizzle_stack.depth--;
    }
}

static void pt_replace_storing_imp(CFMutableDictionaryRef *dictPtr, Class cls, SEL origSel, IMP hookIMP) {
    if (cls == Nil || origSel == NULL || hookIMP == NULL) {
        return;
    }
    while (cls != Nil && strncmp(class_getName(cls), "NSKVONotifying_", 15) == 0) {
        cls = class_getSuperclass(cls);
    }
    Class ownerCls = pt_find_defining_class(cls, origSel);
    if (ownerCls == Nil) {
        return;
    }
    Method origMethod = class_getInstanceMethod(ownerCls, origSel);
    if (origMethod == NULL) {
        return;
    }
    IMP registeredOrigIMP = NULL;
    os_unfair_lock_lock(&s_swz_imp_lock);
    if (*dictPtr == NULL) {
        *dictPtr = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
    }
    if (*dictPtr != NULL && !CFDictionaryContainsKey(*dictPtr, (__bridge const void *)ownerCls)) {
        IMP currentIMP = method_getImplementation(origMethod);
        if (currentIMP != NULL && currentIMP != hookIMP) {
            CFDictionarySetValue(*dictPtr, (__bridge const void *)ownerCls, (const void *)currentIMP);
            class_replaceMethod(ownerCls, origSel, hookIMP, method_getTypeEncoding(origMethod));
            registeredOrigIMP = currentIMP;
        }
    }
    os_unfair_lock_unlock(&s_swz_imp_lock);
    if (registeredOrigIMP != NULL) {
        pt_register_swizzled_imp((const void *)hookIMP, (const void *)registeredOrigIMP);
    }
}

static CGRect (*s_orig_scene_frame)(id, SEL) = NULL;
static CGRect (*s_orig_scene_bounds)(id, SEL) = NULL;
static CGSize (*s_orig_fbs_mode_size)(id, SEL) = NULL;
static CGSize (*s_orig_fbs_mode_pixelSize)(id, SEL) = NULL;
static CGFloat (*s_orig_fbs_mode_pointScale)(id, SEL) = NULL;
static double (*s_orig_fbs_mode_refreshRate)(id, SEL) = NULL;
static CGRect (*s_orig_screen_bounds)(id, SEL) = NULL;
static CGRect (*s_orig_screen_nativeBounds)(id, SEL) = NULL;
static CGRect (*s_orig_fixed_coord_bounds)(id, SEL) = NULL;
static NSInteger (*s_orig_screen_maxFPS)(id, SEL) = NULL;
static id (*s_orig_screen_currentMode)(id, SEL) = NULL;
static id (*s_orig_screen_preferredMode)(id, SEL) = NULL;
static NSArray *(*s_orig_screen_availableModes)(id, SEL) = NULL;
static NSArray *(*s_orig_screen_screens)(id, SEL) = NULL;
static NSString *(*s_orig_screen_description)(id, SEL) = NULL;
static id (*s_orig_screen_dispCfg)(id, SEL) = NULL;
static id (*s_orig_screen_privDispCfg)(id, SEL) = NULL;
static long long (*s_orig_device_orientation)(id, SEL) = NULL;
static NSString *(*s_orig_nsstring_regex_replace)(id, SEL, NSString *, NSString *, NSRegularExpressionOptions, NSRange) = NULL;
static void (*s_orig_requestRecordPermission)(id, SEL, void (^)(BOOL)) = NULL;
static id (*s_orig_CMMotionManager_init)(id, SEL) = NULL;
static void (*s_orig_Unity_KeyboardDelegate_Initialize)(id, SEL) = NULL;
static id (*s_orig_menuBuilder_initWithRootMenu)(id, SEL, id) = NULL;

static BOOL s_screenNativeDefaultMode = NO;
static BOOL s_screenNativeResizableOnly = NO;
static BOOL s_screenBoundsHooked = NO;

static double pt_get_default_height(void) {
    return [[UIScreen mainScreen] bounds].size.height;
}

static double pt_get_default_width(void) {
    return [[UIScreen mainScreen] bounds].size.width;
}

static CGRect pt_resolve_effective_screen_bounds(id screenOrNil) {
    id targetScreen = screenOrNil;
    if (targetScreen != nil && ![targetScreen isKindOfClass:[UIScreen class]]) {
        targetScreen = nil;
    }
    if (targetScreen == nil && [NSThread isMainThread] && s_orig_screen_bounds != NULL) {
        targetScreen = [UIScreen mainScreen];
    }
    if (s_orig_screen_bounds != NULL) {
        CGRect raw = (targetScreen != nil) ? s_orig_screen_bounds(targetScreen, @selector(bounds)) : CGRectZero;
        return s_screenBoundsHooked ? [PlayScreen boundsResizable:raw] : raw;
    }
    if (s_screenBoundsHooked) {
        return [PlayScreen boundsResizable:CGRectZero];
    }
    return CGRectZero;
}

static BOOL pt_get_spoofed_portrait_pixel_size(id screenOrNil,
                                               double *out_px_w,
                                               double *out_px_h) {
    double s = pt_get_device_native_scale();
    if (s <= 0.0) {
        s = 2.0;
    }
    // Prefer the active device profile's physical portrait resolution (e.g. 1242x2688 @ 3x
    // for iPhone12,5; 2048x2732 @ 2x for iPad13,8) for app-facing pixel queries under bypass.
    // Logical point coordinate spaces (`UIScreen.bounds` / `fixedCoordinateSpace.bounds`) use
    // `pt_resolve_effective_screen_bounds` so window layout and touch mapping stay aligned.
    double w = 0.0, h = 0.0, spoofS = s;
    pt_get_spoofed_screen_native_bounds(&w, &h, &spoofS);
    if (w > 0.0 && h > 0.0) {
        if (out_px_w) *out_px_w = MIN(w, h);
        if (out_px_h) *out_px_h = MAX(w, h);
        return YES;
    }
    CGRect b = pt_resolve_effective_screen_bounds(screenOrNil);
    if (b.size.width > 1.0 && b.size.height > 1.0) {
        double minPt = MIN((double)b.size.width, (double)b.size.height);
        double maxPt = MAX((double)b.size.width, (double)b.size.height);
        if (out_px_w) *out_px_w = round(minPt * s);
        if (out_px_h) *out_px_h = round(maxPt * s);
        return YES;
    }
    if (out_px_w) *out_px_w = 0.0;
    if (out_px_h) *out_px_h = 0.0;
    return NO;
}

static inline BOOL pt_try_get_spoofed_native_bounds_for_caller(id screenOrNil, const void *caller, CGRect *outBounds) {
    if (!pt_is_bypass_enabled() || pt_is_effective_system_or_playtools_caller(caller)) {
        return NO;
    }
    double pxW = 0.0, pxH = 0.0;
    if (pt_get_spoofed_portrait_pixel_size(screenOrNil, &pxW, &pxH) && pxW > 0.0 && pxH > 0.0) {
        *outBounds = CGRectMake(0, 0, pxW, pxH);
        return YES;
    }
    return NO;
}

static NSInteger pt_spoofed_max_fps(void) {
    uint32_t profileFPS = pt_get_device_max_fps();
    if (profileFPS > 0U) {
        return (NSInteger)profileFPS;
    }
    const char *m = pt_get_device_model_cstr();
    if (m != NULL && (strcmp(m, "iPad6,7") == 0 || strcmp(m, "iPhone12,5") == 0)) {
        return 60;
    }
    return 120;
}

static BOOL pt_hook_prefersPointerLocked(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return NO;
}

static CGRect pt_hook_scene_frame_default(id self, SEL _cmd) {
    CGRect orig = s_orig_scene_frame ? s_orig_scene_frame(self, _cmd) : CGRectZero;
    return [PlayScreen frameDefault:orig];
}

static CGRect pt_hook_scene_frame(id self, SEL _cmd) {
    CGRect orig = s_orig_scene_frame ? s_orig_scene_frame(self, _cmd) : CGRectZero;
    return [PlayScreen frame:orig];
}

static CGRect pt_hook_scene_bounds_default(id self, SEL _cmd) {
    CGRect orig = s_orig_scene_bounds ? s_orig_scene_bounds(self, _cmd) : CGRectZero;
    return [PlayScreen boundsDefault:orig];
}

static CGRect pt_hook_scene_bounds(id self, SEL _cmd) {
    CGRect orig = s_orig_scene_bounds ? s_orig_scene_bounds(self, _cmd) : CGRectZero;
    return [PlayScreen bounds:orig];
}

static CGSize pt_hook_fbs_mode_size_default(id self, SEL _cmd) {
    CGSize orig = s_orig_fbs_mode_size ? s_orig_fbs_mode_size(self, _cmd) : CGSizeZero;
    return [PlayScreen sizeAspectRatioDefault:orig];
}

static CGSize pt_hook_fbs_mode_size(id self, SEL _cmd) {
    CGSize orig = s_orig_fbs_mode_size ? s_orig_fbs_mode_size(self, _cmd) : CGSizeZero;
    return [PlayScreen sizeAspectRatio:orig];
}

static CGSize pt_hook_fbs_mode_pixelSize(id self, SEL _cmd) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        double pxW = 0.0, pxH = 0.0;
        if (pt_get_spoofed_portrait_pixel_size(nil, &pxW, &pxH) && pxW > 0.0 && pxH > 0.0) {
            return CGSizeMake(pxW, pxH);
        }
    }
    return s_orig_fbs_mode_pixelSize ? s_orig_fbs_mode_pixelSize(self, _cmd) : CGSizeZero;
}

static CGFloat pt_hook_fbs_mode_pointScale(id self, SEL _cmd) {
    CGFloat orig = s_orig_fbs_mode_pointScale ? s_orig_fbs_mode_pointScale(self, _cmd) : 2.0;
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        double s = pt_get_device_native_scale();
        if (s > 0) {
            return (CGFloat)s;
        }
    }
    return orig;
}

static double pt_hook_fbs_mode_refreshRate(id self, SEL _cmd) {
    double orig = s_orig_fbs_mode_refreshRate ? s_orig_fbs_mode_refreshRate(self, _cmd) : 60.0;
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return (double)pt_spoofed_max_fps();
    }
    return orig;
}

static CGRect pt_hook_screen_bounds_resizable(id self, SEL _cmd) {
    if ([[PlaySettings shared] strictEmulationMode]) {
        return [PlayScreen boundsResizable:CGRectZero];
    }
    CGRect orig = s_orig_screen_bounds ? s_orig_screen_bounds(self, _cmd) : CGRectZero;
    return [PlayScreen boundsResizable:orig];
}

static CGRect pt_hook_screen_nativeBounds(id self, SEL _cmd) {
    CGRect spoofed = CGRectZero;
    if (pt_try_get_spoofed_native_bounds_for_caller(self, __builtin_return_address(0), &spoofed)) {
        return spoofed;
    }
    CGRect orig = s_orig_screen_nativeBounds ? s_orig_screen_nativeBounds(self, _cmd) : CGRectZero;
    if (s_screenNativeResizableOnly) {
        return orig;
    }
    return s_screenNativeDefaultMode ? [PlayScreen nativeBoundsDefault:orig] : [PlayScreen nativeBounds:orig];
}

static CGFloat pt_hook_screen_nativeScale(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    const void *caller = __builtin_return_address(0);
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
        double s = pt_get_device_native_scale();
        if (s > 0) {
            return (CGFloat)s;
        }
    }
    return [[PlaySettings shared] customScaler];
}

static CGFloat pt_hook_screen_scale(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    const void *caller = __builtin_return_address(0);
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
        double s = pt_get_device_native_scale();
        if (s > 0) {
            return (CGFloat)s;
        }
    }
    // Return rounded value of [[PlaySettings shared] customScaler]
    // Even though it is a double return, this will only accept .0 value or apps will crash
    return round([[PlaySettings shared] customScaler]);
}

static NSInteger pt_hook_screen_maxFPS(id self, SEL _cmd) {
    NSInteger orig = s_orig_screen_maxFPS ? s_orig_screen_maxFPS(self, _cmd) : 60;
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return pt_spoofed_max_fps();
    }
    return orig;
}

static CGSize pt_hook_screenmode_size(id self, SEL _cmd) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        double pxW = 0.0, pxH = 0.0;
        if (pt_get_spoofed_portrait_pixel_size(nil, &pxW, &pxH) && pxW > 0.0 && pxH > 0.0) {
            return CGSizeMake(pxW, pxH);
        }
    }
    BOOL pushed = NO;
    IMP origIMP = pt_lookup_stored_imp_and_push(s_orig_screenmode_size_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((CGSize (*)(id, SEL))origIMP)(self, _cmd);
        } @finally {
            pt_pop_stored_imp_frame(pushed);
        }
    }
    return CGSizeZero;
}

static CGFloat pt_hook_screenmode_aspect(id self, SEL _cmd) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return 1.0;
    }
    BOOL pushed = NO;
    IMP origIMP = pt_lookup_stored_imp_and_push(s_orig_screenmode_aspect_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((CGFloat (*)(id, SEL))origIMP)(self, _cmd);
        } @finally {
            pt_pop_stored_imp_frame(pushed);
        }
    }
    return 1.0;
}

static void pt_ensure_screenmode_class_swizzled(id mode) {
    if (mode == nil) {
        return;
    }
    Class cls = object_getClass(mode);
    pt_replace_storing_imp(&s_orig_screenmode_size_imps, cls, @selector(size), (IMP)pt_hook_screenmode_size);
    pt_replace_storing_imp(&s_orig_screenmode_aspect_imps, cls, @selector(pixelAspectRatio), (IMP)pt_hook_screenmode_aspect);
}

static id pt_hook_screen_currentMode(id self, SEL _cmd) {
    id mode = s_orig_screen_currentMode ? s_orig_screen_currentMode(self, _cmd) : nil;
    pt_ensure_screenmode_class_swizzled(mode);
    return mode;
}

static id pt_hook_screen_preferredMode(id self, SEL _cmd) {
    const void *caller = __builtin_return_address(0);
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller) && s_orig_screen_currentMode != NULL) {
        id cur = s_orig_screen_currentMode(self, @selector(currentMode));
        pt_ensure_screenmode_class_swizzled(cur);
        if (cur != nil) {
            return cur;
        }
    }
    id mode = s_orig_screen_preferredMode ? s_orig_screen_preferredMode(self, _cmd) : nil;
    pt_ensure_screenmode_class_swizzled(mode);
    return mode;
}

static NSArray *pt_hook_screen_availableModes(id self, SEL _cmd) {
    const void *caller = __builtin_return_address(0);
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller) && s_orig_screen_currentMode != NULL) {
        id cur = s_orig_screen_currentMode(self, @selector(currentMode));
        pt_ensure_screenmode_class_swizzled(cur);
        if (cur != nil) {
            return @[cur];
        }
    }
    NSArray *modes = s_orig_screen_availableModes ? s_orig_screen_availableModes(self, _cmd) : @[];
    for (id m in modes) {
        pt_ensure_screenmode_class_swizzled(m);
    }
    return modes;
}

static NSArray *pt_hook_screen_screens(id self, SEL _cmd) {
    NSArray *orig = s_orig_screen_screens ? s_orig_screen_screens(self, _cmd) : @[];
    if (orig.count > 1 && pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return @[orig.firstObject];
    }
    return orig;
}

static CGRect pt_hook_fixed_coord_bounds(id self, SEL _cmd) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        id scr = nil;
        SEL scrSel = sel_registerName("_screen");
        if ([self respondsToSelector:scrSel]) {
            scr = ((id (*)(id, SEL))objc_msgSend)(self, scrSel);
        }
        CGRect b = pt_resolve_effective_screen_bounds(scr);
        if (b.size.width <= 1.0 || b.size.height <= 1.0) {
            b = s_orig_fixed_coord_bounds ? s_orig_fixed_coord_bounds(self, _cmd) : CGRectZero;
        }
        if (b.size.width > 1.0 && b.size.height > 1.0) {
            double minPt = MIN((double)b.size.width, (double)b.size.height);
            double maxPt = MAX((double)b.size.width, (double)b.size.height);
            return CGRectMake(0, 0, minPt, maxPt);
        }
    }
    return s_orig_fixed_coord_bounds ? s_orig_fixed_coord_bounds(self, _cmd) : CGRectZero;
}

static NSString *pt_hook_screen_description(id self, SEL _cmd) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        CGRect b = pt_resolve_effective_screen_bounds(self);
        double pxW = 0.0, pxH = 0.0;
        (void)pt_get_spoofed_portrait_pixel_size(self, &pxW, &pxH);
        id cur = s_orig_screen_currentMode ? s_orig_screen_currentMode(self, @selector(currentMode)) : nil;
        return [NSString stringWithFormat:@"<UIScreen: %p; bounds = %@; mode = <UIScreenMode: %p; size = %.6f x %.6f>>",
                (__bridge void *)self, NSStringFromCGRect(b), (__bridge void *)cur, pxW, pxH];
    }
    return s_orig_screen_description ? s_orig_screen_description(self, _cmd) : @"<UIScreen>";
}

static NSString *pt_hook_fbs_disp_name(id self, SEL _cmd) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return @"LCD";
    }
    BOOL pushed = NO;
    IMP origIMP = pt_lookup_stored_imp_and_push(s_orig_fbs_disp_name_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((NSString *(*)(id, SEL))origIMP)(self, _cmd);
        } @finally {
            pt_pop_stored_imp_frame(pushed);
        }
    }
    return @"LCD";
}

static NSString *pt_hook_fbs_disp_devname(id self, SEL _cmd) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return @"Display";
    }
    BOOL pushed = NO;
    IMP origIMP = pt_lookup_stored_imp_and_push(s_orig_fbs_disp_devname_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((NSString *(*)(id, SEL))origIMP)(self, _cmd);
        } @finally {
            pt_pop_stored_imp_frame(pushed);
        }
    }
    return @"Display";
}

static id pt_hook_fbs_disp_hwid(id self, SEL _cmd) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return nil;
    }
    BOOL pushed = NO;
    IMP origIMP = pt_lookup_stored_imp_and_push(s_orig_fbs_disp_hwid_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((id (*)(id, SEL))origIMP)(self, _cmd);
        } @finally {
            pt_pop_stored_imp_frame(pushed);
        }
    }
    return nil;
}

static CGSize pt_hook_fbs_disp_pixelSize(id self, SEL _cmd) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        double pxW = 0.0, pxH = 0.0;
        if (pt_get_spoofed_portrait_pixel_size(nil, &pxW, &pxH) && pxW > 0.0 && pxH > 0.0) {
            return CGSizeMake(pxW, pxH);
        }
    }
    BOOL pushed = NO;
    IMP origIMP = pt_lookup_stored_imp_and_push(s_orig_fbs_disp_pixelsize_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((CGSize (*)(id, SEL))origIMP)(self, _cmd);
        } @finally {
            pt_pop_stored_imp_frame(pushed);
        }
    }
    return CGSizeZero;
}

static CGFloat pt_hook_fbs_disp_pointScale(id self, SEL _cmd) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        double s = pt_get_device_native_scale();
        if (s > 0) {
            return (CGFloat)s;
        }
    }
    BOOL pushed = NO;
    IMP origIMP = pt_lookup_stored_imp_and_push(s_orig_fbs_disp_pointscale_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((CGFloat (*)(id, SEL))origIMP)(self, _cmd);
        } @finally {
            pt_pop_stored_imp_frame(pushed);
        }
    }
    return 2.0;
}

static void pt_ensure_fbs_disp_cfg_swizzled(Class cls) {
    if (cls == Nil) {
        return;
    }
    pt_replace_storing_imp(&s_orig_fbs_disp_name_imps, cls, sel_registerName("name"), (IMP)pt_hook_fbs_disp_name);
    pt_replace_storing_imp(&s_orig_fbs_disp_devname_imps, cls, sel_registerName("deviceName"), (IMP)pt_hook_fbs_disp_devname);
    pt_replace_storing_imp(&s_orig_fbs_disp_hwid_imps, cls, sel_registerName("hardwareIdentifier"), (IMP)pt_hook_fbs_disp_hwid);
    pt_replace_storing_imp(&s_orig_fbs_disp_pixelsize_imps, cls, sel_registerName("pixelSize"), (IMP)pt_hook_fbs_disp_pixelSize);
    pt_replace_storing_imp(&s_orig_fbs_disp_pointscale_imps, cls, sel_registerName("pointScale"), (IMP)pt_hook_fbs_disp_pointScale);
}

static id pt_hook_screen_dispCfg(id self, SEL _cmd) {
    id cfg = s_orig_screen_dispCfg ? s_orig_screen_dispCfg(self, _cmd) : nil;
    if (cfg != nil) {
        pt_ensure_fbs_disp_cfg_swizzled(object_getClass(cfg));
    }
    return cfg;
}

static id pt_hook_screen_privDispCfg(id self, SEL _cmd) {
    id cfg = s_orig_screen_privDispCfg ? s_orig_screen_privDispCfg(self, _cmd) : nil;
    if (cfg != nil) {
        pt_ensure_fbs_disp_cfg_swizzled(object_getClass(cfg));
    }
    return cfg;
}

static long long pt_hook_device_orientation(id self, SEL _cmd) {
    if (!pt_is_bypass_enabled() || pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (s_orig_device_orientation != NULL) {
            return s_orig_device_orientation(self, _cmd);
        }
        return UIDeviceOrientationLandscapeLeft;
    }
    CGRect b = [PlayScreen boundsResizable:CGRectZero];
    if (b.size.height > b.size.width && b.size.width > 0) {
        return UIDeviceOrientationPortrait;
    }
    return UIDeviceOrientationLandscapeLeft;
}

static BOOL pt_hook_requiresFullScreen(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return NO;
}

static void pt_hook_setCurrentSubscription(id self, SEL _cmd, id currentSubscription) {
    (void)self; (void)_cmd; (void)currentSubscription;
}

static NSString *pt_hook_nsstring_regex_replace(id self, SEL _cmd, NSString *pattern, NSString *template, NSRegularExpressionOptions options, NSRange range) {
    if ([(NSString *)self length] == 0) {
        return @"";
    }
    if (s_orig_nsstring_regex_replace != NULL) {
        return s_orig_nsstring_regex_replace(self, _cmd, pattern, template, options, range);
    }
    return @"";
}

static void pt_hook_requestRecordPermission(id self, SEL _cmd, void (^response)(BOOL)) {
    BOOL granted = [[AVAudioSession sharedInstance] recordPermission] == AVAudioSessionRecordPermissionGranted;
    if (granted) {
        if (response != nil) {
            response(granted);
        }
    } else if (s_orig_requestRecordPermission != NULL) {
        s_orig_requestRecordPermission(self, _cmd, response);
    } else if (response != nil) {
        response(NO);
    }
}

static id pt_hook_CMMotionManager_init(id self, SEL _cmd) {
    CMMotionManager *motionManager = s_orig_CMMotionManager_init ? (CMMotionManager *)s_orig_CMMotionManager_init(self, _cmd) : nil;
    if (motionManager != nil) {
        // The default update interval is 0, which may lead to excessive CPU usage
        motionManager.accelerometerUpdateInterval = 0.01;
        motionManager.deviceMotionUpdateInterval = 0.01;
        motionManager.gyroUpdateInterval = 0.01;
    }
    return motionManager;
}

static GCMouse *(*s_orig_GCMouse_current)(id, SEL) = NULL;
static NSArray *(*s_orig_GCMouse_mice)(id, SEL) = NULL;

static GCMouse *pt_hook_GCMouse_current(id self, SEL _cmd) {
    if (pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        s_orig_GCMouse_current != NULL) {
        return s_orig_GCMouse_current(self, _cmd);
    }
    return nil;
}

static NSArray *pt_hook_GCMouse_mice(id self, SEL _cmd) {
    if (pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        s_orig_GCMouse_mice != NULL) {
        return s_orig_GCMouse_mice(self, _cmd);
    }
    return @[];
}

static void pt_hook_Unity_KeyboardDelegate_Initialize(id self, SEL _cmd) {
    @try {
        if (s_orig_Unity_KeyboardDelegate_Initialize != NULL) {
            s_orig_Unity_KeyboardDelegate_Initialize(self, _cmd);
        }
    }
    @catch (NSException *exception) {
        (void)exception;
    }
}

static atomic_bool s_menuWasCreated = false;
static id pt_hook_initWithRootMenu(id self, SEL _cmd, id rootMenu) {
    id initialized = s_orig_menuBuilder_initWithRootMenu ? s_orig_menuBuilder_initWithRootMenu(self, _cmd, rootMenu) : self;
    if (initialized != nil && !atomic_exchange_explicit(&s_menuWasCreated, true, memory_order_acq_rel)) {
        [PlayCover initMenuWithMenu:initialized];
    }
    return initialized;
}

static void pt_install_bypass_screen_hooks(BOOL hookBounds) {
    Class screenCls = objc_getClass("UIScreen");
    if (screenCls != Nil) {
        if (hookBounds) {
            s_screenBoundsHooked = YES;
            pt_replace_instance_imp(screenCls, @selector(bounds), (IMP)pt_hook_screen_bounds_resizable, (IMP *)&s_orig_screen_bounds);
        } else if (s_orig_screen_bounds == NULL) {
            Method m = class_getInstanceMethod(screenCls, @selector(bounds));
            if (m != NULL) {
                s_orig_screen_bounds = (CGRect (*)(id, SEL))method_getImplementation(m);
            }
        }
        pt_replace_instance_imp(screenCls, @selector(nativeBounds), (IMP)pt_hook_screen_nativeBounds, (IMP *)&s_orig_screen_nativeBounds);
        pt_replace_instance_imp(screenCls, @selector(nativeScale), (IMP)pt_hook_screen_nativeScale, NULL);
        pt_replace_instance_imp(screenCls, @selector(scale), (IMP)pt_hook_screen_scale, NULL);
        if (pt_is_bypass_enabled()) {
            pt_replace_instance_imp(screenCls, @selector(maximumFramesPerSecond), (IMP)pt_hook_screen_maxFPS, (IMP *)&s_orig_screen_maxFPS);
            pt_replace_instance_imp(screenCls, @selector(currentMode), (IMP)pt_hook_screen_currentMode, (IMP *)&s_orig_screen_currentMode);
            pt_replace_instance_imp(screenCls, @selector(preferredMode), (IMP)pt_hook_screen_preferredMode, (IMP *)&s_orig_screen_preferredMode);
            pt_replace_instance_imp(screenCls, @selector(availableModes), (IMP)pt_hook_screen_availableModes, (IMP *)&s_orig_screen_availableModes);
            pt_replace_class_imp(screenCls, @selector(screens), (IMP)pt_hook_screen_screens, (IMP *)&s_orig_screen_screens);
            pt_replace_instance_imp(screenCls, @selector(description), (IMP)pt_hook_screen_description, (IMP *)&s_orig_screen_description);
            pt_replace_instance_imp(screenCls, sel_registerName("displayConfiguration"), (IMP)pt_hook_screen_dispCfg, (IMP *)&s_orig_screen_dispCfg);
            pt_replace_instance_imp(screenCls, sel_registerName("_displayConfiguration"), (IMP)pt_hook_screen_privDispCfg, (IMP *)&s_orig_screen_privDispCfg);
        }
    }
    if (pt_is_bypass_enabled()) {
        Class modeCls = objc_getClass("UIScreenMode");
        if (modeCls != Nil) {
            pt_replace_storing_imp(&s_orig_screenmode_size_imps, modeCls, @selector(size), (IMP)pt_hook_screenmode_size);
            pt_replace_storing_imp(&s_orig_screenmode_aspect_imps, modeCls, @selector(pixelAspectRatio), (IMP)pt_hook_screenmode_aspect);
        }
        Class fbsDispCfgCls = objc_getClass("FBSDisplayConfiguration");
        if (fbsDispCfgCls != Nil) {
            pt_ensure_fbs_disp_cfg_swizzled(fbsDispCfgCls);
        }
        Class fbsModeCls = objc_getClass("FBSDisplayMode");
        if (fbsModeCls != Nil) {
            pt_replace_instance_imp(fbsModeCls, sel_registerName("pixelSize"), (IMP)pt_hook_fbs_mode_pixelSize, (IMP *)&s_orig_fbs_mode_pixelSize);
            pt_replace_instance_imp(fbsModeCls, sel_registerName("pointScale"), (IMP)pt_hook_fbs_mode_pointScale, (IMP *)&s_orig_fbs_mode_pointScale);
            pt_replace_instance_imp(fbsModeCls, sel_registerName("refreshRate"), (IMP)pt_hook_fbs_mode_refreshRate, (IMP *)&s_orig_fbs_mode_refreshRate);
        }
        Class fixedCoordCls = objc_getClass("_UIScreenFixedCoordinateSpace");
        if (fixedCoordCls != Nil) {
            pt_replace_instance_imp(fixedCoordCls, @selector(bounds), (IMP)pt_hook_fixed_coord_bounds, (IMP *)&s_orig_fixed_coord_bounds);
        }
        Class devCls = objc_getClass("UIDevice");
        if (devCls != Nil) {
            pt_replace_instance_imp(devCls, @selector(orientation), (IMP)pt_hook_device_orientation, (IMP *)&s_orig_device_orientation);
        }
    }
}

static atomic_bool s_unityKeyboardHooked = false;
static void pt_install_unity_keyboard_hook_if_loaded(void) {
    if (atomic_load_explicit(&s_unityKeyboardHooked, memory_order_acquire)) {
        return;
    }
    Class kdCls = objc_getClass("KeyboardDelegate");
    if (kdCls != Nil) {
        if (!atomic_exchange_explicit(&s_unityKeyboardHooked, true, memory_order_acq_rel)) {
            pt_replace_class_imp(kdCls, NSSelectorFromString(@"Initialize"), (IMP)pt_hook_Unity_KeyboardDelegate_Initialize, (IMP *)&s_orig_Unity_KeyboardDelegate_Initialize);
        }
    }
}

@implementation PTSwizzleHooks
@end

/*
 This class only exists to apply swizzles from the +load of a class that won't have any categories/extensions. The reason
 for not doing this in a C module initializer is that obj-c initialization happens before any __attribute__((constructor))
 is called. This way we can guarantee the hooks will be applied before [PlayCover launch] is called (in PlayLoader.m).
 */

static Class pt_resolve_frontboard_frame_class(Class sceneCoreCls, Class sceneCls) {
    SEL frameSel = @selector(frame);
    if (sceneCoreCls != Nil && class_getInstanceMethod(sceneCoreCls, frameSel) != NULL) {
        return sceneCoreCls;
    }
    if (sceneCls != Nil && class_getInstanceMethod(sceneCls, frameSel) != NULL) {
        return sceneCls;
    }
    return Nil;
}

@implementation PTSwizzleLoader
+ (void)load {
    pt_ensure_playloader_early_init();
    BOOL safeModeActive = [PTSafeMode.shared ensureEvaluatedForCurrentProcess];
    Class sceneCls = objc_getClass("FBSSceneSettings");
    Class sceneCoreCls = objc_getClass("FBSSceneSettingsCore");
    Class frameTargetCls = pt_resolve_frontboard_frame_class(sceneCoreCls, sceneCls);
    Class fbsModeCls = objc_getClass("FBSDisplayMode");

    if (safeModeActive) {
        s_screenNativeResizableOnly = YES;
        if (pt_is_bypass_enabled()) {
            pt_install_bypass_screen_hooks(NO);
        }
    } else if (@available(iOS 16.3, *)) {
        if ([[PlaySettings shared] resizableWindow]) {
            pt_replace_instance_imp(objc_getClass("_UIApplicationInfoParser"), NSSelectorFromString(@"requiresFullScreen"), (IMP)pt_hook_requiresFullScreen, NULL);
            s_screenNativeResizableOnly = YES;
            pt_install_bypass_screen_hooks(YES);
        }
        else if ([[PlaySettings shared] adaptiveDisplay]) {
            if ([[PlaySettings shared] inverseScreenValues]) {
                s_screenNativeDefaultMode = YES;
                if (frameTargetCls != Nil) {
                    pt_replace_instance_imp(frameTargetCls, @selector(frame), (IMP)pt_hook_scene_frame_default, (IMP *)&s_orig_scene_frame);
                }
                if (sceneCls != Nil && class_getInstanceMethod(sceneCls, @selector(bounds)) != NULL) {
                    pt_replace_instance_imp(sceneCls, @selector(bounds), (IMP)pt_hook_scene_bounds_default, (IMP *)&s_orig_scene_bounds);
                }
                if (fbsModeCls != Nil && class_getInstanceMethod(fbsModeCls, @selector(size)) != NULL) {
                    pt_replace_instance_imp(fbsModeCls, @selector(size), (IMP)pt_hook_fbs_mode_size_default, (IMP *)&s_orig_fbs_mode_size);
                }
                pt_install_bypass_screen_hooks(YES);
                pt_replace_instance_imp(objc_getClass("UIDevice"), @selector(orientation), (IMP)pt_hook_device_orientation, (IMP *)&s_orig_device_orientation);
            } else {
                s_screenNativeDefaultMode = NO;
                if (frameTargetCls != Nil) {
                    pt_replace_instance_imp(frameTargetCls, @selector(frame), (IMP)pt_hook_scene_frame, (IMP *)&s_orig_scene_frame);
                }
                if (sceneCls != Nil && class_getInstanceMethod(sceneCls, @selector(bounds)) != NULL) {
                    pt_replace_instance_imp(sceneCls, @selector(bounds), (IMP)pt_hook_scene_bounds, (IMP *)&s_orig_scene_bounds);
                }
                if (fbsModeCls != Nil && class_getInstanceMethod(fbsModeCls, @selector(size)) != NULL) {
                    pt_replace_instance_imp(fbsModeCls, @selector(size), (IMP)pt_hook_fbs_mode_size, (IMP *)&s_orig_fbs_mode_size);
                }
                pt_install_bypass_screen_hooks(YES);
                pt_replace_instance_imp(objc_getClass("UIDevice"), @selector(orientation), (IMP)pt_hook_device_orientation, (IMP *)&s_orig_device_orientation);
            }
        }
        else {
            if ([[PlaySettings shared] windowFixMethod] == 1) {
                if (pt_is_bypass_enabled()) {
                    s_screenNativeResizableOnly = YES;
                    pt_install_bypass_screen_hooks(NO);
                }
            }
            else {
                CGFloat newValueW = (CGFloat)pt_get_default_width();
                CGFloat newValueH = (CGFloat)pt_get_default_height();
                if (newValueW > 1.0 && newValueH > 1.0) {
                    [[PlaySettings shared] setValue:@(newValueW) forKey:@"windowSizeWidth"];
                    [[PlaySettings shared] setValue:@(newValueH) forKey:@"windowSizeHeight"];
                }
                s_screenNativeDefaultMode = YES;
                if (![[PlaySettings shared] inverseScreenValues]) {
                    if (frameTargetCls != Nil) {
                        pt_replace_instance_imp(frameTargetCls, @selector(frame), (IMP)pt_hook_scene_frame_default, (IMP *)&s_orig_scene_frame);
                    }
                    if (sceneCls != Nil && class_getInstanceMethod(sceneCls, @selector(bounds)) != NULL) {
                        pt_replace_instance_imp(sceneCls, @selector(bounds), (IMP)pt_hook_scene_bounds_default, (IMP *)&s_orig_scene_bounds);
                    }
                    if (fbsModeCls != Nil && class_getInstanceMethod(fbsModeCls, @selector(size)) != NULL) {
                        pt_replace_instance_imp(fbsModeCls, @selector(size), (IMP)pt_hook_fbs_mode_size_default, (IMP *)&s_orig_fbs_mode_size);
                    }
                }
                pt_install_bypass_screen_hooks(YES);
                pt_replace_instance_imp(objc_getClass("UIDevice"), @selector(orientation), (IMP)pt_hook_device_orientation, (IMP *)&s_orig_device_orientation);
            }
        }
    }
    else {
        if ([[PlaySettings shared] adaptiveDisplay]) {
            if (frameTargetCls != Nil) {
                pt_replace_instance_imp(frameTargetCls, @selector(frame), (IMP)pt_hook_scene_frame, (IMP *)&s_orig_scene_frame);
            }
            if (sceneCls != Nil && class_getInstanceMethod(sceneCls, @selector(bounds)) != NULL) {
                pt_replace_instance_imp(sceneCls, @selector(bounds), (IMP)pt_hook_scene_bounds, (IMP *)&s_orig_scene_bounds);
            }
            if (fbsModeCls != Nil && class_getInstanceMethod(fbsModeCls, @selector(size)) != NULL) {
                pt_replace_instance_imp(fbsModeCls, @selector(size), (IMP)pt_hook_fbs_mode_size, (IMP *)&s_orig_fbs_mode_size);
            }
        }
        if (pt_is_bypass_enabled()) {
            s_screenNativeResizableOnly = YES;
            pt_install_bypass_screen_hooks(NO);
        }
    }

    if ([[PlaySettings shared] keymapping]) {
        pt_replace_instance_imp(objc_getClass("_UIMenuBuilder"), sel_getUid("initWithRootMenu:"), (IMP)pt_hook_initWithRootMenu, (IMP *)&s_orig_menuBuilder_initWithRootMenu);
    }
    pt_replace_instance_imp(objc_getClass("IOSViewController"), @selector(prefersPointerLocked), (IMP)pt_hook_prefersPointerLocked, NULL);
    pt_replace_instance_imp(objc_getClass("VSSubscriptionRegistrationCenter"), @selector(setCurrentSubscription:), (IMP)pt_hook_setCurrentSubscription, NULL);

    if (PlayInfo.isUnrealEngine) {
        // Fix NSRegularExpression crash when system language is set to Chinese
        CFStringEncoding encoding = CFStringGetSystemEncoding();
        if (encoding == kCFStringEncodingMacChineseSimp || encoding == kCFStringEncodingMacChineseTrad) {
            SEL origSelector = NSSelectorFromString(@"_stringByReplacingOccurrencesOfRegularExpressionPattern:withTemplate:options:range:");
            pt_replace_instance_imp(objc_getClass("NSString"), origSelector, (IMP)pt_hook_nsstring_regex_replace, (IMP *)&s_orig_nsstring_regex_replace);
        }
    }

    if ([[PlaySettings shared] checkMicPermissionSync]) {
        pt_replace_instance_imp(objc_getClass("AVAudioSession"), @selector(requestRecordPermission:), (IMP)pt_hook_requestRecordPermission, (IMP *)&s_orig_requestRecordPermission);
    }

    if ([[PlaySettings shared] limitMotionUpdateFrequency]) {
        pt_replace_instance_imp(objc_getClass("CMMotionManager"), @selector(init), (IMP)pt_hook_CMMotionManager_init, (IMP *)&s_orig_CMMotionManager_init);
    }

    if ([[PlaySettings shared] disableBuiltinMouse]) {
        pt_replace_class_imp(objc_getClass("GCMouse"), @selector(current), (IMP)pt_hook_GCMouse_current, (IMP *)&s_orig_GCMouse_current);
        pt_replace_class_imp(objc_getClass("GCMouse"), @selector(mice), (IMP)pt_hook_GCMouse_mice, (IMP *)&s_orig_GCMouse_mice);
    }

    if ([[PlaySettings shared] ignoreUnityKeyboardInitializationError]) {
        pt_install_unity_keyboard_hook_if_loaded();
        if (!atomic_load_explicit(&s_unityKeyboardHooked, memory_order_acquire)) {
            [[NSNotificationCenter defaultCenter] addObserverForName:NSBundleDidLoadNotification
                                                              object:nil
                                                               queue:nil
                                                          usingBlock:^(NSNotification * _Nonnull note) {
                (void)note;
                pt_install_unity_keyboard_hook_if_loaded();
            }];
        }
    }
}

@end
