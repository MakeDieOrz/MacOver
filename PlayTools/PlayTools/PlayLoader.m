//
//  PlayLoader.m
//  PlayTools
//

#import "Subsystems/PTInternal.h"
#import "Subsystems/PTRegistration.h"
#include <crt_externs.h>

static void pt_secure_zero_env_bytes(char *ptr, size_t len) {
    if (ptr == NULL || len == 0U) {
        return;
    }
    volatile unsigned char *p = (volatile unsigned char *)ptr;
    for (size_t i = 0; i < len; i++) {
        p[i] = 0U;
    }
}

static void pt_harvest_and_scrub_automation_env_early(void) {
    static const char *const kAutomationKeys[] = {
        "MACOVER_AUTOMATION_PORT",
        "MACOVER_AUTOMATION_TOKEN",
        "MACOVER_AUTOMATION_BUNDLE_ID",
        "MACOVER_AUTOMATION_BRIDGE_DIR",
    };

    char port_buf[16] = {0};
    char token_buf[128] = {0};
    char bundle_buf[256] = {0};
    char bridge_dir_buf[1024] = {0};

    const char *port_raw = pt_raw_getenv("MACOVER_AUTOMATION_PORT");
    const char *token_raw = pt_raw_getenv("MACOVER_AUTOMATION_TOKEN");
    const char *bundle_raw = pt_raw_getenv("MACOVER_AUTOMATION_BUNDLE_ID");
    const char *bridge_dir_raw = pt_raw_getenv("MACOVER_AUTOMATION_BRIDGE_DIR");
    if (port_raw != NULL) {
        strlcpy(port_buf, port_raw, sizeof(port_buf));
    }
    if (token_raw != NULL) {
        strlcpy(token_buf, token_raw, sizeof(token_buf));
    }
    if (bundle_raw != NULL) {
        strlcpy(bundle_buf, bundle_raw, sizeof(bundle_buf));
    }
    if (bridge_dir_raw != NULL) {
        strlcpy(bridge_dir_buf, bridge_dir_raw, sizeof(bridge_dir_buf));
    }

    // Record raw initial environ string pointers and keys for ALL MACOVER_AUTOMATION_*
    // variables before unsetenv compacts environ, then unset every discovered key and zero
    // their backing bytes so main(argc, argv, envp) / stack scans cannot recover secrets.
    static const char kAutomationPrefix[] = "MACOVER_AUTOMATION_";
    const size_t kAutomationPrefixLen = sizeof(kAutomationPrefix) - 1U;
    char *raw_entries[32] = {0};
    size_t raw_lens[32] = {0};
    char discovered_keys[32][128] = {{0}};
    size_t raw_count = 0;
    char ***envp_ptr = _NSGetEnviron();
    if (envp_ptr != NULL && *envp_ptr != NULL) {
        char **envp = *envp_ptr;
        for (size_t i = 0; envp[i] != NULL && raw_count < 32U; i++) {
            char *entry = envp[i];
            if (strncmp(entry, kAutomationPrefix, kAutomationPrefixLen) == 0) {
                const char *eq = strchr(entry + kAutomationPrefixLen, '=');
                if (eq != NULL) {
                    size_t key_len = (size_t)(eq - entry);
                    if (key_len > 0U && key_len < sizeof(discovered_keys[0])) {
                        memcpy(discovered_keys[raw_count], entry, key_len);
                        discovered_keys[raw_count][key_len] = '\0';
                    }
                    raw_entries[raw_count] = entry;
                    raw_lens[raw_count] = strlen(entry);
                    raw_count++;
                }
            }
        }
    }

    for (size_t k = 0; k < (sizeof(kAutomationKeys) / sizeof(kAutomationKeys[0])); k++) {
        (void)unsetenv(kAutomationKeys[k]);
    }
    for (size_t i = 0; i < raw_count; i++) {
        if (discovered_keys[i][0] != '\0') {
            (void)unsetenv(discovered_keys[i]);
        }
    }
    for (size_t i = 0; i < raw_count; i++) {
        pt_secure_zero_env_bytes(raw_entries[i], raw_lens[i]);
    }
    pt_secure_zero_env_bytes((char *)discovered_keys, sizeof(discovered_keys));

    const char *safe_raw = pt_raw_getenv("PLAYTOOLS_SAFE_MODE");
    BOOL safe_env = (safe_raw != NULL && strcmp(safe_raw, "1") == 0);
    if (!safe_env && port_buf[0] != '\0' && token_buf[0] != '\0' && bundle_buf[0] != '\0') {
        char *end_ptr = NULL;
        long parsed_port = strtol(port_buf, &end_ptr, 10);
        if (end_ptr != port_buf && *end_ptr == '\0' && parsed_port > 0L && parsed_port <= 65535L) {
            pt_store_automation_bootstrap((uint16_t)parsed_port, token_buf, bundle_buf, bridge_dir_buf);
        }
    }

    pt_secure_zero_env_bytes(port_buf, sizeof(port_buf));
    pt_secure_zero_env_bytes(token_buf, sizeof(token_buf));
    pt_secure_zero_env_bytes(bundle_buf, sizeof(bundle_buf));
    pt_secure_zero_env_bytes(bridge_dir_buf, sizeof(bridge_dir_buf));
}

__attribute__((visibility("hidden"))) void pt_ensure_playloader_early_init(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        atomic_store_explicit(&s_libsystem_ready, true, memory_order_release);
        pt_debug_trace_mark_ready();
        pt_enter_internal_scope();
        pt_harvest_and_scrub_automation_env_early();
        pt_ensure_bundle_path_map();
        pt_ensure_data_container_map();
        s_tls_bypass_init_depth++;
        pthread_once(&s_pt_bypass_early_once, pt_init_early_bypass);
        s_tls_bypass_init_depth--;
        pt_ensure_early_device_info_safe();
        (void)[PTSafeMode.shared ensureEvaluatedForCurrentProcess];
        if ([PTSafeMode isActive]) {
            pt_clear_automation_bootstrap();
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
        if (bypass && ![PTSafeMode isActive]) {
            pt_init_nonlazy_got_cloaking();
        }

        pthread_once(&s_pt_device_info_once, pt_init_device_info);
        if (bypass && ![PTSafeMode isActive]) {
            pt_init_linkedit_cs_blob_cloaking();
            pt_refresh_hidden_image_bounds();
        }
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
