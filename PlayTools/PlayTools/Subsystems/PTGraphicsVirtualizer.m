//
//  PTGraphicsVirtualizer.m
//  PlayTools
//

#import "PSInternal.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

@implementation PSSwizzleHooks (PlayShadowGraphics)

static os_unfair_lock s_mtl_swizzle_lock = OS_UNFAIR_LOCK_INIT;
static CFMutableDictionaryRef s_mtl_orig_name_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_working_set_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_max_buf_imps = NULL;

static uint64_t ps_mtl_memory_cap(void) {
    uint64_t mem = pt_get_spoofed_physical_memory();
    if (mem == 0) {
        mem = (uint64_t)[[NSProcessInfo processInfo] physicalMemory];
    }
    return (mem * 3ULL) / 4ULL;
}

- (NSString *) pm_mtl_device_name {
    if (!pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        BOOL pushed = NO;
        IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_name_imps, self, &pushed);
        if (origIMP != NULL) {
            @try {
                return ((NSString *(*)(id, SEL))origIMP)(self, @selector(name));
            } @finally {
                ps_pop_orig_imp_frame(pushed);
            }
        }
    }
    const char *gpuName = pt_get_spoofed_gpu_name_cstr();
    if (gpuName != NULL && gpuName[0] != '\0') {
        static os_unfair_lock s_gpuNameLock = OS_UNFAIR_LOCK_INIT;
        static const char *s_lastGpuPtr = NULL;
        static char s_lastGpuBuf[128] = {0};
        static NSString *s_cachedGpuName = nil;
        os_unfair_lock_lock(&s_gpuNameLock);
        if (s_cachedGpuName == nil || (s_lastGpuPtr != gpuName && strncmp(s_lastGpuBuf, gpuName, sizeof(s_lastGpuBuf) - 1) != 0)) {
            NSString *s = [NSString stringWithUTF8String:gpuName];
            if (s.length > 0) {
                s_cachedGpuName = [s copy];
                s_lastGpuPtr = gpuName;
                strlcpy(s_lastGpuBuf, gpuName, sizeof(s_lastGpuBuf));
            }
        }
        NSString *result = s_cachedGpuName;
        os_unfair_lock_unlock(&s_gpuNameLock);
        if (result.length > 0) {
            return result;
        }
    }
    return @"Apple GPU";
}

- (uint64_t) pm_ps_mtl_recommendedMaxWorkingSetSize {
    SEL sel = sel_registerName("recommendedMaxWorkingSetSize");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_working_set_imps, self, &pushed);
    uint64_t orig = 0;
    if (origIMP != NULL) {
        @try {
            orig = ((uint64_t (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        uint64_t cap = ps_mtl_memory_cap();
        if (cap > 0 && orig > cap) {
            return cap;
        }
    }
    return orig;
}

- (NSUInteger) pm_ps_mtl_maxBufferLength {
    SEL sel = sel_registerName("maxBufferLength");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_max_buf_imps, self, &pushed);
    NSUInteger orig = 0;
    if (origIMP != NULL) {
        @try {
            orig = ((NSUInteger (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        uint64_t cap = ps_mtl_memory_cap();
        if (cap > 0 && (uint64_t)orig > cap) {
            return (NSUInteger)cap;
        }
    }
    return orig;
}


@end

static void ps_swizzle_mtl_device_class(Class cls) {
    if (cls == Nil) {
        return;
    }
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_name_imps, cls,
                                     @selector(name), @selector(pm_mtl_device_name));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_working_set_imps, cls,
                                     sel_registerName("recommendedMaxWorkingSetSize"),
                                     @selector(pm_ps_mtl_recommendedMaxWorkingSetSize));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_max_buf_imps, cls,
                                     sel_registerName("maxBufferLength"),
                                     @selector(pm_ps_mtl_maxBufferLength));
}

__attribute__((visibility("hidden"))) void ps_install_metal_hooks_if_loaded(void) {
    typedef CFTypeRef (*ps_mtl_create_default_fn)(void);
    ps_mtl_create_default_fn mtlCreateDefault = (ps_mtl_create_default_fn)dlsym(RTLD_DEFAULT, "MTLCreateSystemDefaultDevice");
#if TARGET_OS_MACCATALYST
    typedef CFArrayRef (*ps_mtl_copy_all_fn)(void);
    ps_mtl_copy_all_fn mtlCopyAll = (ps_mtl_copy_all_fn)dlsym(RTLD_DEFAULT, "MTLCopyAllDevices");
#else
    void *mtlCopyAll = NULL;
#endif
    if (mtlCreateDefault != NULL || mtlCopyAll != NULL) {
        static dispatch_once_t mtlOnce;
        dispatch_once(&mtlOnce, ^{
            PT_DEBUG_TRACE("graphics", "installing Metal hooks");
            if (mtlCreateDefault != NULL) {
                CFTypeRef devRef = mtlCreateDefault();
                if (devRef != NULL) {
                    id dev = CFBridgingRelease(devRef);
                    if (dev != nil) {
                        ps_swizzle_mtl_device_class(object_getClass(dev));
                    }
                }
            }
#if TARGET_OS_MACCATALYST
            if (mtlCopyAll != NULL) {
                CFArrayRef devsRef = mtlCopyAll();
                if (devsRef != NULL) {
                    NSArray *devices = CFBridgingRelease(devsRef);
                    for (id dev in devices) {
                        if (dev != nil) {
                            ps_swizzle_mtl_device_class(object_getClass(dev));
                        }
                    }
                }
            }
#endif
        });
    }
}


static void (*s_orig_dl_setPreferredFrameRateRange)(id, SEL, CAFrameRateRange) = NULL;
static CAFrameRateRange (*s_orig_dl_preferredFrameRateRange)(id, SEL) = NULL;
static void (*s_orig_dl_setPreferredFramesPerSecond)(id, SEL, NSInteger) = NULL;
static NSInteger (*s_orig_dl_preferredFramesPerSecond)(id, SEL) = NULL;
static void (*s_orig_dl_addToRunLoopForMode)(id, SEL, NSRunLoop *, NSRunLoopMode) = NULL;

static void (*s_orig_mtkview_setPreferredFramesPerSecond)(id, SEL, NSInteger) = NULL;
static NSInteger (*s_orig_mtkview_preferredFramesPerSecond)(id, SEL) = NULL;
static void (*s_orig_mtkview_didMoveToWindow)(id, SEL) = NULL;

static NSInteger ps_effective_target_frame_rate_hz(void) {
    return [[PlaySettings shared] targetFrameRateHz];
}

static CAFrameRateRange ps_clamped_frame_rate_range(CAFrameRateRange range, NSInteger capHz) {
    if (capHz <= 0) {
        return range;
    }
    float cap = (float)capHz;
    float clippedMax = (!isfinite(range.maximum) || range.maximum <= 0.0f) ? cap : fminf(range.maximum, cap);
    float clippedMin = (!isfinite(range.minimum) || range.minimum <= 0.0f) ? clippedMax : fminf(range.minimum, clippedMax);
    float clippedPref = (!isfinite(range.preferred) || range.preferred <= 0.0f)
        ? clippedMax
        : fminf(fmaxf(range.preferred, clippedMin), clippedMax);
    return (CAFrameRateRange){ clippedMin, clippedMax, clippedPref };
}

static NSInteger ps_clamped_legacy_fps(NSInteger fps, NSInteger capHz) {
    if (capHz <= 0) {
        return fps;
    }
    if (fps <= 0) {
        return capHz;
    }
    return (fps < capHz) ? fps : capHz;
}

static IMP ps_replace_method_with_c_hook(Class cls, SEL sel, IMP hookIMP) {
    if (cls == Nil || sel == NULL || hookIMP == NULL) {
        return NULL;
    }
    Method m = class_getInstanceMethod(cls, sel);
    if (m == NULL) {
        return NULL;
    }
    IMP origBefore = method_getImplementation(m);
    IMP prev = class_replaceMethod(cls, sel, hookIMP, method_getTypeEncoding(m));
    IMP orig = prev ?: origBefore;
    if (orig != NULL) {
        pt_register_swizzled_imp((const void *)hookIMP, (const void *)orig);
    }
    return orig;
}

static void ps_hook_dl_setPreferredFrameRateRange(id self, SEL _cmd, CAFrameRateRange range) {
    NSInteger capHz = ps_effective_target_frame_rate_hz();
    if (capHz > 0 && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        CAFrameRateRange clamped = ps_clamped_frame_rate_range(range, capHz);
        PT_DEBUG_TRACE("graphics",
                       "CADisplayLink setPreferredFrameRateRange cap=%ld (%.1f,%.1f,%.1f)->(%.1f,%.1f,%.1f)",
                       (long)capHz,
                       range.minimum, range.maximum, range.preferred,
                       clamped.minimum, clamped.maximum, clamped.preferred);
        range = clamped;
    }
    if (s_orig_dl_setPreferredFrameRateRange != NULL) {
        s_orig_dl_setPreferredFrameRateRange(self, _cmd, range);
    }
}

static void ps_hook_dl_setPreferredFramesPerSecond(id self, SEL _cmd, NSInteger fps) {
    NSInteger capHz = ps_effective_target_frame_rate_hz();
    if (capHz > 0 && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        NSInteger clamped = ps_clamped_legacy_fps(fps, capHz);
        PT_DEBUG_TRACE("graphics",
                       "CADisplayLink setPreferredFramesPerSecond cap=%ld %ld->%ld",
                       (long)capHz, (long)fps, (long)clamped);
        fps = clamped;
    }
    if (s_orig_dl_setPreferredFramesPerSecond != NULL) {
        s_orig_dl_setPreferredFramesPerSecond(self, _cmd, fps);
    }
}

static void ps_hook_dl_addToRunLoopForMode(id self, SEL _cmd, NSRunLoop *runloop, NSRunLoopMode mode) {
    NSInteger capHz = ps_effective_target_frame_rate_hz();
    if (capHz > 0 && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        CAFrameRateRange curRange = { 0.0f, 0.0f, 0.0f };
        if (s_orig_dl_preferredFrameRateRange != NULL) {
            curRange = s_orig_dl_preferredFrameRateRange(self, sel_registerName("preferredFrameRateRange"));
        }
        NSInteger curLegacyFPS = 0;
        if (s_orig_dl_preferredFramesPerSecond != NULL) {
            curLegacyFPS = s_orig_dl_preferredFramesPerSecond(self, sel_registerName("preferredFramesPerSecond"));
        }
        BOOL keepLowerLegacyFPS = (curRange.maximum <= 0.0f && curLegacyFPS > 0 && curLegacyFPS < capHz);
        if (!keepLowerLegacyFPS && s_orig_dl_setPreferredFrameRateRange != NULL) {
            CAFrameRateRange clamped = ps_clamped_frame_rate_range(curRange, capHz);
            PT_DEBUG_TRACE("graphics",
                           "CADisplayLink addToRunLoop cap=%ld -> (%.1f,%.1f,%.1f)",
                           (long)capHz, clamped.minimum, clamped.maximum, clamped.preferred);
            s_orig_dl_setPreferredFrameRateRange(self, sel_registerName("preferredFrameRateRange"), clamped);
        }
    }
    if (s_orig_dl_addToRunLoopForMode != NULL) {
        s_orig_dl_addToRunLoopForMode(self, _cmd, runloop, mode);
    }
}

static void ps_hook_mtkview_setPreferredFramesPerSecond(id self, SEL _cmd, NSInteger fps) {
    NSInteger capHz = ps_effective_target_frame_rate_hz();
    if (capHz > 0 && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        NSInteger clamped = ps_clamped_legacy_fps(fps, capHz);
        PT_DEBUG_TRACE("graphics",
                       "MTKView setPreferredFramesPerSecond cap=%ld %ld->%ld",
                       (long)capHz, (long)fps, (long)clamped);
        fps = clamped;
    }
    if (s_orig_mtkview_setPreferredFramesPerSecond != NULL) {
        s_orig_mtkview_setPreferredFramesPerSecond(self, _cmd, fps);
    }
}

static void ps_hook_mtkview_didMoveToWindow(id self, SEL _cmd) {
    if (s_orig_mtkview_didMoveToWindow != NULL) {
        s_orig_mtkview_didMoveToWindow(self, _cmd);
    }
    NSInteger capHz = ps_effective_target_frame_rate_hz();
    if (capHz > 0 && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        NSInteger curFPS = 0;
        if (s_orig_mtkview_preferredFramesPerSecond != NULL) {
            curFPS = s_orig_mtkview_preferredFramesPerSecond(self, sel_registerName("preferredFramesPerSecond"));
        }
        NSInteger clamped = ps_clamped_legacy_fps(curFPS, capHz);
        if (clamped != curFPS && s_orig_mtkview_setPreferredFramesPerSecond != NULL) {
            PT_DEBUG_TRACE("graphics",
                           "MTKView didMoveToWindow cap=%ld %ld->%ld",
                           (long)capHz, (long)curFPS, (long)clamped);
            s_orig_mtkview_setPreferredFramesPerSecond(self, sel_registerName("preferredFramesPerSecond"), clamped);
        }
    }
}

static void ps_install_display_link_hooks_if_loaded(void) {
    Class dlCls = objc_getClass("CADisplayLink");
    if (dlCls == Nil) {
        return;
    }
    static dispatch_once_t dlOnce;
    dispatch_once(&dlOnce, ^{
        PT_DEBUG_TRACE("graphics", "installing CADisplayLink frame rate hooks");
        Method mGetRange = class_getInstanceMethod(dlCls, sel_registerName("preferredFrameRateRange"));
        if (mGetRange != NULL) {
            s_orig_dl_preferredFrameRateRange = (CAFrameRateRange (*)(id, SEL))method_getImplementation(mGetRange);
        }
        Method mGetFPS = class_getInstanceMethod(dlCls, sel_registerName("preferredFramesPerSecond"));
        if (mGetFPS != NULL) {
            s_orig_dl_preferredFramesPerSecond = (NSInteger (*)(id, SEL))method_getImplementation(mGetFPS);
        }
        s_orig_dl_setPreferredFrameRateRange = (void (*)(id, SEL, CAFrameRateRange))ps_replace_method_with_c_hook(
            dlCls, sel_registerName("setPreferredFrameRateRange:"), (IMP)ps_hook_dl_setPreferredFrameRateRange);
        s_orig_dl_setPreferredFramesPerSecond = (void (*)(id, SEL, NSInteger))ps_replace_method_with_c_hook(
            dlCls, sel_registerName("setPreferredFramesPerSecond:"), (IMP)ps_hook_dl_setPreferredFramesPerSecond);
        s_orig_dl_addToRunLoopForMode = (void (*)(id, SEL, NSRunLoop *, NSRunLoopMode))ps_replace_method_with_c_hook(
            dlCls, sel_registerName("addToRunLoop:forMode:"), (IMP)ps_hook_dl_addToRunLoopForMode);
    });
}

static void ps_install_mtkview_frame_rate_hooks_if_loaded(void) {
    Class mtkCls = objc_getClass("MTKView");
    if (mtkCls == Nil) {
        static dispatch_once_t obsOnce;
        dispatch_once(&obsOnce, ^{
            [[NSNotificationCenter defaultCenter] addObserverForName:NSBundleDidLoadNotification
                                                              object:nil
                                                               queue:nil
                                                          usingBlock:^(NSNotification * _Nonnull note) {
                (void)note;
                if (objc_getClass("MTKView") != Nil) {
                    ps_install_mtkview_frame_rate_hooks_if_loaded();
                }
            }];
        });
        return;
    }
    static dispatch_once_t mtkOnce;
    dispatch_once(&mtkOnce, ^{
        PT_DEBUG_TRACE("graphics", "installing MTKView frame rate hooks");
        Method mGetFPS = class_getInstanceMethod(mtkCls, sel_registerName("preferredFramesPerSecond"));
        if (mGetFPS != NULL) {
            s_orig_mtkview_preferredFramesPerSecond = (NSInteger (*)(id, SEL))method_getImplementation(mGetFPS);
        }
        s_orig_mtkview_setPreferredFramesPerSecond = (void (*)(id, SEL, NSInteger))ps_replace_method_with_c_hook(
            mtkCls, sel_registerName("setPreferredFramesPerSecond:"), (IMP)ps_hook_mtkview_setPreferredFramesPerSecond);
        s_orig_mtkview_didMoveToWindow = (void (*)(id, SEL))ps_replace_method_with_c_hook(
            mtkCls, sel_registerName("didMoveToWindow"), (IMP)ps_hook_mtkview_didMoveToWindow);
    });
}

void pt_install_frame_rate_hooks_if_loaded(void) {
    ps_install_display_link_hooks_if_loaded();
    ps_install_mtkview_frame_rate_hooks_if_loaded();
}

void pt_install_graphics_hooks_if_loaded(void) {

    ps_install_metal_hooks_if_loaded();
    pt_install_frame_rate_hooks_if_loaded();

}
