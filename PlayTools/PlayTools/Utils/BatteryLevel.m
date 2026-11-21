//
//  BatteryLevel.m
//  PlayTools
//
//  Created by Edoardo C. on 07/08/24.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import "../PlayLoader.h"

__attribute__((visibility("hidden")))
@interface BatteryLevelLoader : NSObject
@end

static _Atomic BOOL s_batteryMonitoringEnabled = NO;
static void (*s_orig_setBatteryMonitoringEnabled)(id, SEL, BOOL) = NULL;

static void pt_battery_setMonitoringEnabled(id self, SEL _cmd, BOOL enabled) {
    atomic_store_explicit(&s_batteryMonitoringEnabled, enabled, memory_order_relaxed);
    if (s_orig_setBatteryMonitoringEnabled != NULL) {
        s_orig_setBatteryMonitoringEnabled(self, _cmd, enabled);
    }
}

static BOOL pt_battery_isMonitoringEnabled(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return atomic_load_explicit(&s_batteryMonitoringEnabled, memory_order_relaxed);
}

static float pt_battery_level(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return atomic_load_explicit(&s_batteryMonitoringEnabled, memory_order_relaxed) ? 0.85f : -1.0f;
}

static UIDeviceBatteryState pt_battery_state(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    return atomic_load_explicit(&s_batteryMonitoringEnabled, memory_order_relaxed)
        ? UIDeviceBatteryStateUnplugged
        : UIDeviceBatteryStateUnknown;
}

static void pt_battery_replace_method(Class cls, SEL origSel, IMP hookIMP, IMP *outOrigIMP) {
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

@implementation BatteryLevelLoader
+ (void)load {
    pt_ensure_playloader_early_init();
    if (!pt_is_bypass_enabled()) {
        return;
    }
    Class uiDeviceCls = objc_getClass("UIDevice");
    if (uiDeviceCls == Nil) {
        return;
    }
    pt_battery_replace_method(uiDeviceCls,
                              @selector(setBatteryMonitoringEnabled:),
                              (IMP)pt_battery_setMonitoringEnabled,
                              (IMP *)&s_orig_setBatteryMonitoringEnabled);
    pt_battery_replace_method(uiDeviceCls,
                              @selector(isBatteryMonitoringEnabled),
                              (IMP)pt_battery_isMonitoringEnabled,
                              NULL);
    pt_battery_replace_method(uiDeviceCls,
                              @selector(batteryState),
                              (IMP)pt_battery_state,
                              NULL);
    pt_battery_replace_method(uiDeviceCls,
                              @selector(batteryLevel),
                              (IMP)pt_battery_level,
                              NULL);
}
@end
