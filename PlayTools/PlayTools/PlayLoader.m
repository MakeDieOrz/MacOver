//
//  PlayLoader.m
//  PlayTools
//

#import "Subsystems/PTInternal.h"

__attribute__((visibility("hidden"))) void pt_ensure_playloader_early_init(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        atomic_store_explicit(&s_libsystem_ready, true, memory_order_release);
        pt_debug_trace_mark_ready();
        pt_enter_internal_scope();
        pt_ensure_bundle_path_map();
        pt_ensure_data_container_map();
        s_tls_bypass_init_depth++;
        pthread_once(&s_pt_bypass_early_once, pt_init_early_bypass);
        s_tls_bypass_init_depth--;
        pt_ensure_early_device_info_safe();
        (void)[PTSafeMode.shared ensureEvaluatedForCurrentProcess];
        if ([PTSafeMode isActive]) {
            pt_disable_reported_ios_override_for_safe_mode();
            pt_disable_app_backups_for_safe_mode();
        }
        pt_svc_interceptor_init_early();

        BOOL prev_tls = s_tls_initializing_device_info;
        s_tls_initializing_device_info = YES;
        PlaySettings *settings = [PlaySettings shared];
        BOOL bypass = [settings bypass];
        BOOL playChain = [settings playChain];
        BOOL playChainDebug = [settings playChainDebugging];
        BOOL blockSleep = [settings blockSleepSpamming];
        BOOL rootWorkDir = [settings rootWorkDir];
        s_tls_initializing_device_info = prev_tls;

        const char *dis_env = pt_raw_getenv("DISABLE_PLAYSHADOW_BYPASS");
        if (dis_env != NULL && strcmp(dis_env, "1") == 0) {
            bypass = NO;
        }

        atomic_store_explicit(&s_bypass_enabled, bypass, memory_order_release);
        atomic_store_explicit(&s_pt_bypass_inited, YES, memory_order_release);
        atomic_store_explicit(&s_playchain_cached, playChain ? 1 : 0, memory_order_release);
        atomic_store_explicit(&s_playchain_debug_cached, playChainDebug ? 1 : 0, memory_order_release);
        atomic_store_explicit(&s_block_sleep_spamming_cached, blockSleep ? 1 : 0, memory_order_release);
        atomic_store_explicit(&s_pt_loaded, YES, memory_order_release);

        pthread_once(&s_pt_device_info_once, pt_init_device_info);
        if (rootWorkDir) {
            chdir("/");
        }
        pt_leave_internal_scope();
    });
}

@implementation PlayLoader

+ (void)load {
    pt_ensure_playloader_early_init();
}

static void __attribute__((constructor)) initialize(void) {
    pt_enter_internal_scope();
    [PlayCover launch];

    if (atomic_load_explicit(&ue_status, memory_order_relaxed) == 0) {
        if (PlayInfo.isUnrealEngine) {
            atomic_store_explicit(&ue_status, 2, memory_order_relaxed);
        }
    }

    if (atomic_load_explicit(&ue_status, memory_order_relaxed) == 2) {
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"UnrealEngine Hooked"]];
    }

    if (atomic_load_explicit(&s_block_sleep_spamming_cached, memory_order_acquire) == 1 ||
        [[PlaySettings shared] blockSleepSpamming]) {
        // Add an observer so we can unlock threads on app termination
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *_Nonnull note) {
                                                          (void)note;
                                                          if (thread_sleep_sem != nil) {
                                                              dispatch_semaphore_signal(thread_sleep_sem);
                                                          }
                                                      }];
    }
    pt_leave_internal_scope();
}

@end
