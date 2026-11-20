//
//  MediaVolume.m
//  PlayTools
//
//  Created by Undefined on 2025/12/20.
//

#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <math.h>
#import <os/lock.h>
#import <stdatomic.h>
#import "../PlayLoader.h"

extern __attribute__((visibility("hidden"))) void pt_register_swizzled_imp(const void *hook_imp, const void *orig_imp);
extern __attribute__((visibility("hidden"))) BOOL pt_is_address_in_playtools(const void *addr);

__attribute__((visibility("hidden")))
@interface MediaVolumeLoader : NSObject
@end

static _Atomic float s_virtual_volume = 0.5f;
static os_unfair_lock s_media_volume_lock = OS_UNFAIR_LOCK_INIT;
static _Atomic BOOL s_avAudioHooked = NO;
static _Atomic BOOL s_mpSliderHooked = NO;
static _Atomic BOOL s_mpPlayerHooked = NO;
static _Atomic BOOL s_mpAppPlayerHooked = NO;

static float (*s_orig_slider_value)(id, SEL) __attribute__((unused)) = NULL;
static void (*s_orig_slider_setValue)(id, SEL, float) = NULL;
static void (*s_orig_slider_setValueAnimated)(id, SEL, float, BOOL) = NULL;

static inline float pt_clamp_virtual_volume(float value) {
    if (isnan(value) || value < 0.0f) {
        return 0.0f;
    }
    if (value > 1.0f) {
        return 1.0f;
    }
    return value;
}

static void pt_update_virtual_volume(float clamped) {
    float prev = atomic_load_explicit(&s_virtual_volume, memory_order_relaxed);
    if (prev == clamped) {
        return;
    }
    Class avCls = objc_getClass("AVAudioSession");
    AVAudioSession *session = (avCls != Nil) ? [avCls sharedInstance] : nil;
    if (session != nil) {
        [session willChangeValueForKey:@"outputVolume"];
        atomic_store_explicit(&s_virtual_volume, clamped, memory_order_release);
        [session didChangeValueForKey:@"outputVolume"];
    } else {
        atomic_store_explicit(&s_virtual_volume, clamped, memory_order_release);
    }
}

static float pt_media_get_output_volume(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return atomic_load_explicit(&s_virtual_volume, memory_order_acquire);
}

static float pt_media_slider_get_value(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return atomic_load_explicit(&s_virtual_volume, memory_order_acquire);
}

static void pt_media_slider_set_value(id self, SEL _cmd, float value) {
    float clamped = pt_clamp_virtual_volume(value);
    pt_update_virtual_volume(clamped);
    if (s_orig_slider_setValue != NULL) {
        s_orig_slider_setValue(self, _cmd, clamped);
    }
}

static void pt_media_slider_set_value_animated(id self, SEL _cmd, float value, BOOL animated) {
    float clamped = pt_clamp_virtual_volume(value);
    pt_update_virtual_volume(clamped);
    if (s_orig_slider_setValueAnimated != NULL) {
        s_orig_slider_setValueAnimated(self, _cmd, clamped, animated);
    }
}

static float pt_media_player_get_volume(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return atomic_load_explicit(&s_virtual_volume, memory_order_acquire);
}

static void pt_media_player_set_volume(id self, SEL _cmd, float value) {
    (void)self;
    (void)_cmd;
    pt_update_virtual_volume(pt_clamp_virtual_volume(value));
}

static float pt_media_app_player_get_volume(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return atomic_load_explicit(&s_virtual_volume, memory_order_acquire);
}

static void pt_media_app_player_set_volume(id self, SEL _cmd, float value) {
    (void)self;
    (void)_cmd;
    pt_update_virtual_volume(pt_clamp_virtual_volume(value));
}

static BOOL pt_is_media_volume_hook_imp(IMP imp) {
    return (imp == (IMP)pt_media_get_output_volume ||
            imp == (IMP)pt_media_slider_get_value ||
            imp == (IMP)pt_media_slider_set_value ||
            imp == (IMP)pt_media_slider_set_value_animated ||
            imp == (IMP)pt_media_player_get_volume ||
            imp == (IMP)pt_media_player_set_volume ||
            imp == (IMP)pt_media_app_player_get_volume ||
            imp == (IMP)pt_media_app_player_set_volume);
}

static IMP pt_volume_replace_instance_method(Class cls, SEL origSelector, IMP hookIMP) {
    if (cls == Nil || origSelector == NULL || hookIMP == NULL) {
        return NULL;
    }
    Method originalMethod = class_getInstanceMethod(cls, origSelector);
    if (!originalMethod) {
        return NULL;
    }
    IMP origBefore = method_getImplementation(originalMethod);
    if (origBefore == hookIMP || pt_is_media_volume_hook_imp(origBefore)) {
        return NULL;
    }
    IMP replaced = class_replaceMethod(cls, origSelector, hookIMP, method_getTypeEncoding(originalMethod));
    IMP actualOrig = replaced ?: origBefore;
    if (actualOrig != NULL) {
        pt_register_swizzled_imp((const void *)hookIMP, (const void *)actualOrig);
    }
    return actualOrig;
}

static void pt_install_media_volume_hooks_if_loaded(void) {
    os_unfair_lock_lock(&s_media_volume_lock);
    if (!atomic_load_explicit(&s_avAudioHooked, memory_order_relaxed)) {
        Class avCls = objc_getClass("AVAudioSession");
        if (avCls != Nil) {
            pt_volume_replace_instance_method(avCls, @selector(outputVolume), (IMP)pt_media_get_output_volume);
            atomic_store_explicit(&s_avAudioHooked, YES, memory_order_release);
        }
    }
    if (!atomic_load_explicit(&s_mpSliderHooked, memory_order_relaxed)) {
        Class sliderCls = objc_getClass("MPVolumeSlider");
        if (sliderCls != Nil) {
            IMP origVal = pt_volume_replace_instance_method(sliderCls, @selector(value), (IMP)pt_media_slider_get_value);
            if (s_orig_slider_value == NULL && origVal != NULL) {
                s_orig_slider_value = (float (*)(id, SEL))origVal;
            }
            IMP origSetVal = pt_volume_replace_instance_method(sliderCls, @selector(setValue:), (IMP)pt_media_slider_set_value);
            if (s_orig_slider_setValue == NULL && origSetVal != NULL) {
                s_orig_slider_setValue = (void (*)(id, SEL, float))origSetVal;
            }
            IMP origSetValAnim = pt_volume_replace_instance_method(sliderCls, @selector(setValue:animated:), (IMP)pt_media_slider_set_value_animated);
            if (s_orig_slider_setValueAnimated == NULL && origSetValAnim != NULL) {
                s_orig_slider_setValueAnimated = (void (*)(id, SEL, float, BOOL))origSetValAnim;
            }
            atomic_store_explicit(&s_mpSliderHooked, YES, memory_order_release);
        }
    }
    if (!atomic_load_explicit(&s_mpPlayerHooked, memory_order_relaxed)) {
        Class playerCls = objc_getClass("MPMusicPlayerController");
        if (playerCls != Nil) {
            pt_volume_replace_instance_method(playerCls, @selector(volume), (IMP)pt_media_player_get_volume);
            pt_volume_replace_instance_method(playerCls, @selector(setVolume:), (IMP)pt_media_player_set_volume);
            atomic_store_explicit(&s_mpPlayerHooked, YES, memory_order_release);
        }
    }
    if (!atomic_load_explicit(&s_mpAppPlayerHooked, memory_order_relaxed)) {
        Class appPlayerCls = objc_getClass("MPMusicPlayerApplicationController");
        if (appPlayerCls != Nil) {
            pt_volume_replace_instance_method(appPlayerCls, @selector(volume), (IMP)pt_media_app_player_get_volume);
            pt_volume_replace_instance_method(appPlayerCls, @selector(setVolume:), (IMP)pt_media_app_player_set_volume);
            atomic_store_explicit(&s_mpAppPlayerHooked, YES, memory_order_release);
        }
    }
    os_unfair_lock_unlock(&s_media_volume_lock);
}

@implementation MediaVolumeLoader

+ (void)load {
    if (!pt_is_bypass_enabled()) {
        return;
    }
    pt_install_media_volume_hooks_if_loaded();
    [[NSNotificationCenter defaultCenter] addObserverForName:NSBundleDidLoadNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        (void)note;
        if (!atomic_load_explicit(&s_avAudioHooked, memory_order_acquire) ||
            !atomic_load_explicit(&s_mpSliderHooked, memory_order_acquire) ||
            !atomic_load_explicit(&s_mpPlayerHooked, memory_order_acquire) ||
            !atomic_load_explicit(&s_mpAppPlayerHooked, memory_order_acquire)) {
            pt_install_media_volume_hooks_if_loaded();
        }
    }];
}

@end
