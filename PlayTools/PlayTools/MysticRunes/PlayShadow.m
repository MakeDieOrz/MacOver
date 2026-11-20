//
//  PlayShadow.m
//  PlayTools
//

#import "../Subsystems/PSInternal.h"

__attribute__((visibility("hidden"))) void ps_swizzle_instance_method(Class cls, SEL origSelector, SEL newSelector) {
    if (cls == Nil || origSelector == NULL || newSelector == NULL) {
        return;
    }
    Method originalMethod = class_getInstanceMethod(cls, origSelector);
    Method swizzledMethod = class_getInstanceMethod([PSSwizzleHooks class], newSelector);
    if (!originalMethod || !swizzledMethod) {
        return;
    }

    const char *origTypes = method_getTypeEncoding(originalMethod);
    const char *swizzledTypes = method_getTypeEncoding(swizzledMethod);
    IMP hookIMP = method_getImplementation(swizzledMethod);
    IMP origIMP = method_getImplementation(originalMethod);
    if (class_addMethod(cls,
                        origSelector,
                        hookIMP,
                        swizzledTypes)) {
        class_replaceMethod(cls,
                            newSelector,
                            origIMP,
                            origTypes);
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
        pt_register_swizzled_imp((const void *)hookIMP, (const void *)actualOrig);
    }
}

__attribute__((visibility("hidden"))) void ps_replace_instance_method(Class cls, SEL origSelector, SEL newSelector) {
    if (cls == Nil || origSelector == NULL || newSelector == NULL) {
        return;
    }
    Method originalMethod = class_getInstanceMethod(cls, origSelector);
    Method swizzledMethod = class_getInstanceMethod([PSSwizzleHooks class], newSelector);
    if (!originalMethod || !swizzledMethod) {
        return;
    }
    IMP hookIMP = method_getImplementation(swizzledMethod);
    IMP origIMP = method_getImplementation(originalMethod);
    IMP prevIMP = class_replaceMethod(cls,
                                      origSelector,
                                      hookIMP,
                                      method_getTypeEncoding(originalMethod));
    IMP actualOrig = prevIMP ?: origIMP;
    pt_register_swizzled_imp((const void *)hookIMP, (const void *)actualOrig);
}

__attribute__((visibility("hidden"))) void ps_swizzle_class_method(Class cls, SEL origSelector, SEL newSelector) {
    if (cls == Nil || origSelector == NULL || newSelector == NULL) {
        return;
    }
    Class metaCls = object_getClass((id)cls);
    Method originalMethod = class_getClassMethod(cls, origSelector);
    Method swizzledMethod = class_getClassMethod([PSSwizzleHooks class], newSelector);
    if (!originalMethod || !swizzledMethod) {
        return;
    }

    const char *origTypes = method_getTypeEncoding(originalMethod);
    const char *swizzledTypes = method_getTypeEncoding(swizzledMethod);
    IMP hookIMP = method_getImplementation(swizzledMethod);
    IMP origIMP = method_getImplementation(originalMethod);
    if (class_addMethod(metaCls,
                        origSelector,
                        hookIMP,
                        swizzledTypes)) {
        class_replaceMethod(metaCls,
                            newSelector,
                            origIMP,
                            origTypes);
        pt_register_swizzled_imp((const void *)hookIMP, (const void *)origIMP);
    } else {
        IMP prevIMP = class_replaceMethod(metaCls,
                                          origSelector,
                                          hookIMP,
                                          swizzledTypes);
        IMP actualOrig = prevIMP ?: origIMP;
        class_replaceMethod(metaCls,
                            newSelector,
                            actualOrig,
                            origTypes);
        pt_register_swizzled_imp((const void *)hookIMP, (const void *)actualOrig);
    }
}

__attribute__((visibility("hidden"))) void ps_replace_class_method(Class cls, SEL origSelector, SEL newSelector) {
    if (cls == Nil || origSelector == NULL || newSelector == NULL) {
        return;
    }
    Class metaCls = object_getClass((id)cls);
    Method originalMethod = class_getClassMethod(cls, origSelector);
    Method swizzledMethod = class_getClassMethod([PSSwizzleHooks class], newSelector);
    if (!originalMethod || !swizzledMethod) {
        return;
    }
    IMP hookIMP = method_getImplementation(swizzledMethod);
    IMP origIMP = method_getImplementation(originalMethod);
    IMP prevIMP = class_replaceMethod(metaCls,
                                      origSelector,
                                      hookIMP,
                                      method_getTypeEncoding(originalMethod));
    IMP actualOrig = prevIMP ?: origIMP;
    pt_register_swizzled_imp((const void *)hookIMP, (const void *)actualOrig);
}

@implementation PSSwizzleHooks
@end



typedef struct {
    ps_swizzle_active_frame_t frames[PS_SWIZZLE_MAX_ACTIVE_FRAMES];
    int depth;
} ps_swizzle_active_stack_t;

static _Thread_local ps_swizzle_active_stack_t tls_ps_swizzle_stack = { .depth = 0 };

__attribute__((visibility("hidden"))) BOOL ps_class_defines_instance_method(Class cls, SEL sel);

__attribute__((visibility("hidden"))) IMP ps_lookup_orig_imp_and_push(os_unfair_lock *lock, CFMutableDictionaryRef dict, id self, BOOL *outPushed) {
    if (outPushed != NULL) {
        *outPushed = NO;
    }
    if (self == nil || dict == NULL) {
        return NULL;
    }
    Class startCls = object_getClass(self);
    if (tls_ps_swizzle_stack.depth > 0) {
        ps_swizzle_active_frame_t *top = &tls_ps_swizzle_stack.frames[tls_ps_swizzle_stack.depth - 1];
        if (top->self_ptr == (__bridge const void *)self && top->dict == dict) {
            startCls = class_getSuperclass(top->dispatched_cls);
        }
    }
    os_unfair_lock_lock(lock);
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
    os_unfair_lock_unlock(lock);
    if (origIMP != NULL && matchedCls != Nil && tls_ps_swizzle_stack.depth < PS_SWIZZLE_MAX_ACTIVE_FRAMES) {
        tls_ps_swizzle_stack.frames[tls_ps_swizzle_stack.depth++] = (ps_swizzle_active_frame_t){
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

__attribute__((visibility("hidden"))) void ps_pop_orig_imp_frame(BOOL pushed) {
    if (pushed && tls_ps_swizzle_stack.depth > 0) {
        tls_ps_swizzle_stack.depth--;
    }
}

__attribute__((visibility("hidden"))) void ps_swizzle_class_sel_storing_imp(os_unfair_lock *lock,
                                             CFMutableDictionaryRef *dictPtr,
                                             Class cls,
                                             SEL origSel,
                                             SEL hookSel) {
    if (cls == Nil || origSel == NULL || hookSel == NULL) {
        return;
    }
    while (cls != Nil && strncmp(class_getName(cls), "NSKVONotifying_", 15) == 0) {
        cls = class_getSuperclass(cls);
    }
    Class ownerCls = Nil;
    for (Class c = cls; c != Nil; c = class_getSuperclass(c)) {
        if (ps_class_defines_instance_method(c, origSel)) {
            ownerCls = c;
            break;
        }
    }
    if (ownerCls == Nil) {
        return;
    }
    Method origMethod = class_getInstanceMethod(ownerCls, origSel);
    Method hookMethod = class_getInstanceMethod([PSSwizzleHooks class], hookSel);
    if (origMethod == NULL || hookMethod == NULL) {
        return;
    }
    IMP hookIMP = method_getImplementation(hookMethod);
    const char *types = method_getTypeEncoding(origMethod);
    IMP registeredOrigIMP = NULL;
    os_unfair_lock_lock(lock);
    if (*dictPtr == NULL) {
        *dictPtr = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
    }
    if (*dictPtr != NULL &&
        !CFDictionaryContainsKey(*dictPtr, (__bridge const void *)ownerCls)) {
        IMP currentIMP = method_getImplementation(origMethod);
        if (currentIMP != NULL && currentIMP != hookIMP) {
            CFDictionarySetValue(*dictPtr, (__bridge const void *)ownerCls, (const void *)currentIMP);
            class_replaceMethod(ownerCls, origSel, hookIMP, types);
            registeredOrigIMP = currentIMP;
        }
    }
    os_unfair_lock_unlock(lock);
    if (registeredOrigIMP != NULL) {
        pt_register_swizzled_imp((const void *)hookIMP, (const void *)registeredOrigIMP);
    }
}


__attribute__((visibility("hidden"))) BOOL ps_class_defines_instance_method(Class cls, SEL sel) {
    if (cls == nil || sel == NULL) {
        return NO;
    }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (methods == NULL) {
        return NO;
    }
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            found = YES;
            break;
        }
    }
    free(methods);
    return found;
}

@implementation PlayShadowLoader

+ (void) load {
    (void)[PTSafeMode.shared ensureEvaluatedForCurrentProcess];
    if ([PTSafeMode isActive]) {
        pt_disable_reported_ios_override_for_safe_mode();
    }
    [self debugLogger:@"PlayShadow is now loading"];
    ps_install_network_blocker_hooks();
    pt_install_frame_rate_hooks_if_loaded();
    if (pt_is_bypass_enabled() &&
        ![[NSProcessInfo processInfo].environment[@"DISABLE_PLAYSHADOW_BYPASS"] isEqualToString:@"1"]) {
        [self loadJailbreakBypass];
        [self loadEnvironmentBypass];
    }

    // Swizzle ATTrackingManager
    ps_replace_class_method(objc_getClass("ATTrackingManager"), @selector(requestTrackingAuthorizationWithCompletionHandler:), @selector(pm_return_2_with_completion_handler:));
    ps_replace_class_method(objc_getClass("ATTrackingManager"), @selector(trackingAuthorizationStatus), @selector(pm_return_2));
    
    // Block UIAlertController presentation to bypass Endfield jailbreak message
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleID isEqualToString:@"com.gryphline.endfield.ios"] || 
    [bundleID isEqualToString:@"com.hypergryph.endfield"]) {
        [self debugLogger:@"loading UIAlertController bypass"];
        ps_swizzle_instance_method(objc_getClass("UIViewController"), @selector(presentViewController:animated:completion:), @selector(pm_endfield_presentViewController:animated:completion:));
    }
    
    if ([bundleID isEqualToString:@"com.kurogame.wutheringwaves.global"] || [bundleID isEqualToString:@"com.kurogame.mingchao"]) {
        ps_replace_instance_method(objc_getClass("KRDeclaredAgeRangeService"), @selector(isAgeRangeRequestAvailable), @selector(pm_return_false));
    }
}

+ (void) loadJailbreakBypass {
    [self debugLogger:@"Jailbreak bypass loading"];

    ps_install_system_jailbreak_bypass_hooks();
}

+ (void) loadEnvironmentBypass {
    ps_load_environment_bypass_hooks();
}

+ (void) debugLogger: (NSString *) message {
    (void)message;
}

@end
