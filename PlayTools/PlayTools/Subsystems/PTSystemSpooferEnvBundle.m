//
//  PTSystemSpooferEnvBundle.m
//  PlayTools
//

#import "PTSystemSpooferInternal.h"
#import "PTDetectionRules.h"
#import "PTFSInternal.h"
#import "PTDyldInternal.h"

__attribute__((visibility("hidden")))
BOOL pt_is_hidden_env_key(const char *name) {
    return pt_is_hidden_env_key_cstr(name) ? YES : NO;
}

static char *pt_getenv(const char *name) {
    if (name == NULL) {
        return NULL;
    }
    char *raw_val = getenv(name);
    if (pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return raw_val;
    }
    BOOL bypass = pt_is_bypass_enabled();
    const char *vh = pt_get_virtual_home_cstr();
    const char *vt = pt_get_virtual_tmpdir_cstr();
    const char *rewritten = NULL;
    pt_env_entry_action_t act = pt_resolve_env_entry(
        name, raw_val, (raw_val != NULL), bypass, vh, vt, &rewritten);
    switch (act) {
        case PT_ENV_ENTRY_HIDE:
            PT_DEBUG_TRACE("spoofer", "hid getenv key=%s", name);
            return NULL;
        case PT_ENV_ENTRY_REWRITE:
            PT_DEBUG_TRACE("spoofer", "virtualized getenv %s -> %s", name, rewritten != NULL ? rewritten : "");
            return (char *)rewritten;
        case PT_ENV_ENTRY_KEEP:
        default:
            return raw_val;
    }
}

static char *pt_alloc_env_kv(const char *key, const char *val) {
    size_t klen = strlen(key);
    size_t vlen = strlen(val);
    char *buf = (char *)malloc(klen + 1 + vlen + 1);
    if (buf != NULL) {
        memcpy(buf, key, klen);
        buf[klen] = '=';
        memcpy(buf + klen + 1, val, vlen + 1);
    }
    return buf;
}

#define PT_IMMORTAL_SHADOW_ENV_SLOTS 256U
#define PT_RETIRED_SHADOW_ENV_SLOTS 256U

static pthread_mutex_t s_shadow_env_mutex = PTHREAD_MUTEX_INITIALIZER;
static char **s_shadow_environ = NULL;
static char **s_last_real_environ = NULL;
static size_t s_last_real_env_count = 0;
static char **s_last_real_snapshot = NULL;
static char *s_last_vh = NULL;
static char *s_last_vt = NULL;
static char **s_immortal_shadow_envs[PT_IMMORTAL_SHADOW_ENV_SLOTS] = {0};
static size_t s_immortal_shadow_env_count = 0;
static char **s_retired_shadow_envs[PT_RETIRED_SHADOW_ENV_SLOTS] = {0};
static size_t s_retired_shadow_env_idx = 0;

static inline BOOL pt_nullable_str_diff(const char *a, const char *b) {
    if (a == b) {
        return NO;
    }
    if (a == NULL || b == NULL) {
        return YES;
    }
    return strcmp(a, b) != 0;
}

static void pt_free_env_array(char **env_arr) {
    if (env_arr == NULL) {
        return;
    }
    for (size_t i = 0; env_arr[i] != NULL; i++) {
        free(env_arr[i]);
    }
    free(env_arr);
}

static void pt_free_env_snapshot(char **snap, size_t count) {
    if (snap == NULL) {
        return;
    }
    for (size_t i = 0; i < count; i++) {
        free(snap[i]);
    }
    free(snap);
}

static char ***pt_refresh_shadow_environ(char ***real_envp) {
    if (real_envp == NULL || *real_envp == NULL) {
        return real_envp;
    }
    pthread_mutex_lock(&s_shadow_env_mutex);
    char **cur_real = *real_envp;
    size_t real_count = 0;
    while (cur_real[real_count] != NULL) {
        real_count++;
    }
    const char *vh = pt_get_virtual_home_cstr();
    const char *vt = pt_get_virtual_tmpdir_cstr();

    BOOL needs_rebuild = (s_shadow_environ == NULL ||
                          cur_real != s_last_real_environ ||
                          real_count != s_last_real_env_count ||
                          (real_count > 0 && s_last_real_snapshot == NULL) ||
                          pt_nullable_str_diff(vh, s_last_vh) ||
                          pt_nullable_str_diff(vt, s_last_vt));
    if (!needs_rebuild) {
        for (size_t i = 0; i < real_count; i++) {
            const char *cur_entry = cur_real[i];
            const char *snap_entry = s_last_real_snapshot[i];
            if (((cur_entry == NULL) != (snap_entry == NULL)) ||
                (cur_entry != NULL && strcmp(cur_entry, snap_entry) != 0)) {
                needs_rebuild = YES;
                break;
            }
        }
    }

    if (needs_rebuild) {
        BOOL bypass = pt_is_bypass_enabled();
        char **new_env = (char **)calloc(real_count + 6, sizeof(char *));
        char **new_real_snapshot = (char **)calloc(real_count + 1, sizeof(char *));
        char *new_vh = (vh != NULL) ? strdup(vh) : NULL;
        char *new_vt = (vt != NULL) ? strdup(vt) : NULL;
        BOOL alloc_ok = (new_env != NULL && new_real_snapshot != NULL &&
                         (vh == NULL || new_vh != NULL) &&
                         (vt == NULL || new_vt != NULL));
        size_t out_idx = 0;
        if (alloc_ok) {
            BOOL added_home = NO;
            BOOL added_cffixed_home = NO;
            BOOL added_tmpdir = NO;
            BOOL added_tmp = NO;
            BOOL added_temp = NO;
            BOOL added_pwd = NO;
            BOOL added_path = NO;
            for (size_t i = 0; i < real_count; i++) {
                const char *entry = cur_real[i];
                if (entry == NULL) {
                    continue;
                }
                char *snap_dup = strdup(entry);
                if (snap_dup == NULL) {
                    alloc_ok = NO;
                    break;
                }
                new_real_snapshot[i] = snap_dup;

                const char *eq = strchr(snap_dup, '=');
                if (eq == NULL || eq == snap_dup) {
                    continue;
                }
                size_t klen = (size_t)(eq - snap_dup);
                char stack_key[256];
                char *heap_key = NULL;
                const char *key_ptr = stack_key;
                if (klen < sizeof(stack_key)) {
                    memcpy(stack_key, snap_dup, klen);
                    stack_key[klen] = '\0';
                } else {
                    heap_key = (char *)malloc(klen + 1);
                    if (heap_key == NULL) {
                        alloc_ok = NO;
                        break;
                    }
                    memcpy(heap_key, snap_dup, klen);
                    heap_key[klen] = '\0';
                    key_ptr = heap_key;
                }
                BOOL duplicate_special = NO;
                if (strcmp(key_ptr, "HOME") == 0) {
                    duplicate_special = added_home;
                    added_home = YES;
                } else if (strcmp(key_ptr, "CFFIXED_USER_HOME") == 0) {
                    duplicate_special = added_cffixed_home;
                    added_cffixed_home = YES;
                } else if (strcmp(key_ptr, "TMPDIR") == 0) {
                    duplicate_special = added_tmpdir;
                    added_tmpdir = YES;
                } else if (strcmp(key_ptr, "TMP") == 0) {
                    duplicate_special = added_tmp;
                    added_tmp = YES;
                } else if (strcmp(key_ptr, "TEMP") == 0) {
                    duplicate_special = added_temp;
                    added_temp = YES;
                } else if (strcmp(key_ptr, "PWD") == 0) {
                    duplicate_special = added_pwd;
                    added_pwd = YES;
                } else if (strcmp(key_ptr, "PATH") == 0) {
                    duplicate_special = added_path;
                    added_path = YES;
                }
                if (duplicate_special) {
                    free(heap_key);
                    continue;
                }
                const char *rewritten = NULL;
                pt_env_entry_action_t act = pt_resolve_env_entry(
                    key_ptr, eq + 1, YES, bypass, vh, vt, &rewritten);
                if (act == PT_ENV_ENTRY_REWRITE && rewritten != NULL) {
                    char *kv = pt_alloc_env_kv(key_ptr, rewritten);
                    free(heap_key);
                    if (kv == NULL) {
                        alloc_ok = NO;
                        break;
                    }
                    new_env[out_idx++] = kv;
                } else if (act == PT_ENV_ENTRY_KEEP) {
                    free(heap_key);
                    char *dup = strdup(snap_dup);
                    if (dup == NULL) {
                        alloc_ok = NO;
                        break;
                    }
                    new_env[out_idx++] = dup;
                } else {
                    free(heap_key);
                }
            }
            const char *const kMandatoryKeys[] = { "HOME", "CFFIXED_USER_HOME", "TMPDIR", "PATH" };
            const BOOL addedFlags[] = { added_home, added_cffixed_home, added_tmpdir, added_path };
            for (size_t mi = 0; alloc_ok && mi < 4U; mi++) {
                if (!addedFlags[mi]) {
                    const char *mkey = kMandatoryKeys[mi];
                    const char *rewritten = NULL;
                    if (pt_resolve_env_entry(mkey, NULL, NO, bypass, vh, vt, &rewritten) == PT_ENV_ENTRY_REWRITE &&
                        rewritten != NULL) {
                        char *kv = pt_alloc_env_kv(mkey, rewritten);
                        if (kv == NULL) {
                            alloc_ok = NO;
                            break;
                        }
                        new_env[out_idx++] = kv;
                    }
                }
            }
        }
        if (alloc_ok) {
            new_env[out_idx] = NULL;
            char **prev_shadow = __atomic_load_n(&s_shadow_environ, __ATOMIC_RELAXED);
            if (prev_shadow != NULL) {
                if (s_immortal_shadow_env_count < PT_IMMORTAL_SHADOW_ENV_SLOTS) {
                    s_immortal_shadow_envs[s_immortal_shadow_env_count++] = prev_shadow;
                } else {
                    pt_free_env_array(s_retired_shadow_envs[s_retired_shadow_env_idx]);
                    s_retired_shadow_envs[s_retired_shadow_env_idx] = prev_shadow;
                    s_retired_shadow_env_idx = (s_retired_shadow_env_idx + 1U) % PT_RETIRED_SHADOW_ENV_SLOTS;
                }
            }
            __atomic_store_n(&s_shadow_environ, new_env, __ATOMIC_RELEASE);
            pt_free_env_snapshot(s_last_real_snapshot, s_last_real_env_count);
            free(s_last_vh);
            free(s_last_vt);
            s_last_real_environ = cur_real;
            s_last_real_env_count = real_count;
            s_last_real_snapshot = new_real_snapshot;
            s_last_vh = new_vh;
            s_last_vt = new_vt;
        } else {
            pt_free_env_array(new_env);
            pt_free_env_snapshot(new_real_snapshot, real_count);
            free(new_vh);
            free(new_vt);
        }
    }
    char **cur_shadow = __atomic_load_n(&s_shadow_environ, __ATOMIC_ACQUIRE);
    char ***ret_ptr = (cur_shadow != NULL) ? &s_shadow_environ : real_envp;
    pthread_mutex_unlock(&s_shadow_env_mutex);
    return ret_ptr;
}

__attribute__((visibility("hidden")))
char ***pt_get_app_shadow_environ_ptr(void) {
    char ***real_envp = _NSGetEnviron();
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire) ||
        real_envp == NULL || *real_envp == NULL) {
        return real_envp;
    }
    return pt_refresh_shadow_environ(real_envp);
}

static char ***pt_NSGetEnviron(void) {
    char ***real_envp = _NSGetEnviron();
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire) ||
        real_envp == NULL || *real_envp == NULL ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return real_envp;
    }
    return pt_refresh_shadow_environ(real_envp);
}

static const char *const kPTStrippedMacOSLaunchFlags[] = {
    "-NSDocumentRevisionsDebugMode",
    "-ApplePersistenceIgnoreState",
};

static BOOL pt_is_launch_flag_bool_value(const char *val) {
    if (val == NULL || val[0] == '\0') {
        return NO;
    }
    return (strcasecmp(val, "YES") == 0 ||
            strcasecmp(val, "NO") == 0 ||
            strcasecmp(val, "true") == 0 ||
            strcasecmp(val, "false") == 0 ||
            strcmp(val, "1") == 0 ||
            strcmp(val, "0") == 0);
}

__attribute__((visibility("hidden")))
int pt_macos_launch_arg_skip_count(const char *arg, const char *next_arg) {
    if (arg == NULL || arg[0] != '-') {
        return 0;
    }
    for (size_t i = 0; i < sizeof(kPTStrippedMacOSLaunchFlags) / sizeof(kPTStrippedMacOSLaunchFlags[0]); i++) {
        if (strcmp(arg, kPTStrippedMacOSLaunchFlags[i]) == 0) {
            return pt_is_launch_flag_bool_value(next_arg) ? 2 : 1;
        }
    }
    return 0;
}

#define PT_IMMORTAL_SHADOW_ARGV_SLOTS 64U
#define PT_RETIRED_SHADOW_ARGV_SLOTS 64U

static pthread_mutex_t s_shadow_argv_mutex = PTHREAD_MUTEX_INITIALIZER;
static char **s_shadow_argv = NULL;
static int s_shadow_raw_argc = -1;
static int s_shadow_filtered_argc = 0;
static char **s_immortal_shadow_argvs[PT_IMMORTAL_SHADOW_ARGV_SLOTS] = {0};
static size_t s_immortal_shadow_argv_count = 0;
static char **s_retired_shadow_argvs[PT_RETIRED_SHADOW_ARGV_SLOTS] = {0};
static size_t s_retired_shadow_argv_idx = 0;
static char s_shadow_progname_buf[PATH_MAX];
static char *s_shadow_progname_ptr = NULL;
static pthread_once_t s_shadow_progname_once = PTHREAD_ONCE_INIT;

static void pt_refresh_shadow_argv_locked(char **cur_argv, int raw_argc) {
    char **cur_shadow = __atomic_load_n(&s_shadow_argv, __ATOMIC_RELAXED);
    if (cur_shadow != NULL && s_shadow_raw_argc == raw_argc) {
        return;
    }
    char **built = (char **)calloc((size_t)raw_argc + 1U, sizeof(char *));
    if (built == NULL) {
        return;
    }
    BOOL ok = YES;
    int out_idx = 0;
    for (int i = 0; i < raw_argc; i++) {
        const char *arg = cur_argv[i] != NULL ? cur_argv[i] : "";
        if (i > 0) {
            const char *next_arg = (i + 1 < raw_argc) ? cur_argv[i + 1] : NULL;
            int skip = pt_macos_launch_arg_skip_count(arg, next_arg);
            if (skip > 0) {
                if (skip == 2 && i + 1 < raw_argc) {
                    i++;
                }
                continue;
            }
        }
        const char *src = arg;
        if (i == 0 && arg[0] != '\0') {
            const char *san = pt_sanitize_image_path_for_cstr(arg);
            if (san != NULL && san[0] != '\0') {
                src = san;
            }
        }
        built[out_idx] = strdup(src);
        if (built[out_idx] == NULL) {
            ok = NO;
            break;
        }
        out_idx++;
    }
    if (ok) {
        built[out_idx] = NULL;
        if (cur_shadow != NULL) {
            if (s_immortal_shadow_argv_count < PT_IMMORTAL_SHADOW_ARGV_SLOTS) {
                s_immortal_shadow_argvs[s_immortal_shadow_argv_count++] = cur_shadow;
            } else {
                pt_free_env_array(s_retired_shadow_argvs[s_retired_shadow_argv_idx]);
                s_retired_shadow_argvs[s_retired_shadow_argv_idx] = cur_shadow;
                s_retired_shadow_argv_idx = (s_retired_shadow_argv_idx + 1U) % PT_RETIRED_SHADOW_ARGV_SLOTS;
            }
        }
        __atomic_store_n(&s_shadow_filtered_argc, out_idx, __ATOMIC_RELEASE);
        __atomic_store_n(&s_shadow_argv, built, __ATOMIC_RELEASE);
        s_shadow_raw_argc = raw_argc;
    } else {
        pt_free_env_array(built);
    }
}

static int pt_resolve_raw_argc(char **cur_argv) {
    int *real_argcp = _NSGetArgc();
    int argc = (real_argcp != NULL && *real_argcp > 0) ? *real_argcp : 0;
    if (argc == 0 && cur_argv != NULL) {
        while (cur_argv[argc] != NULL && argc < 4096) {
            argc++;
        }
    }
    return argc;
}

static char ***pt_NSGetArgv(void) {
    char ***real_argvp = _NSGetArgv();
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire) ||
        real_argvp == NULL || *real_argvp == NULL ||
        !pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return real_argvp;
    }
    char **cur_argv = *real_argvp;
    int argc = pt_resolve_raw_argc(cur_argv);
    pthread_mutex_lock(&s_shadow_argv_mutex);
    pt_refresh_shadow_argv_locked(cur_argv, argc);
    char **cur_shadow = __atomic_load_n(&s_shadow_argv, __ATOMIC_ACQUIRE);
    char ***ret = (cur_shadow != NULL) ? &s_shadow_argv : real_argvp;
    pthread_mutex_unlock(&s_shadow_argv_mutex);
    return ret;
}

static int *pt_NSGetArgc(void) {
    int *real_argcp = _NSGetArgc();
    char ***real_argvp = _NSGetArgv();
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire) ||
        real_argcp == NULL || real_argvp == NULL || *real_argvp == NULL ||
        !pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return real_argcp;
    }
    char **cur_argv = *real_argvp;
    int argc = pt_resolve_raw_argc(cur_argv);
    pthread_mutex_lock(&s_shadow_argv_mutex);
    pt_refresh_shadow_argv_locked(cur_argv, argc);
    char **cur_shadow = __atomic_load_n(&s_shadow_argv, __ATOMIC_ACQUIRE);
    int *ret = (cur_shadow != NULL) ? &s_shadow_filtered_argc : real_argcp;
    pthread_mutex_unlock(&s_shadow_argv_mutex);
    return ret;
}

static void pt_init_shadow_progname(void) {
    const char *exec_path = pt_get_main_executable_path();
    const char *base = NULL;
    if (exec_path != NULL && exec_path[0] != '\0') {
        const char *slash = strrchr(exec_path, '/');
        base = (slash != NULL && slash[1] != '\0') ? (slash + 1) : exec_path;
    }
    if (base == NULL || base[0] == '\0') {
        char **real_pn = _NSGetProgname();
        if (real_pn != NULL && *real_pn != NULL && (*real_pn)[0] != '\0') {
            const char *slash = strrchr(*real_pn, '/');
            base = (slash != NULL && slash[1] != '\0') ? (slash + 1) : *real_pn;
        }
    }
    if (base != NULL && base[0] != '\0') {
        strlcpy(s_shadow_progname_buf, base, sizeof(s_shadow_progname_buf));
        s_shadow_progname_ptr = s_shadow_progname_buf;
    }
}

static char **pt_NSGetProgname(void) {
    char **real_pn = _NSGetProgname();
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire) ||
        !pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return real_pn;
    }
    pthread_once(&s_shadow_progname_once, pt_init_shadow_progname);
    return (s_shadow_progname_ptr != NULL) ? &s_shadow_progname_ptr : real_pn;
}

static const char *pt_getprogname(void) {
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire) ||
        !pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return getprogname();
    }
    pthread_once(&s_shadow_progname_once, pt_init_shadow_progname);
    return (s_shadow_progname_ptr != NULL) ? s_shadow_progname_ptr : getprogname();
}

extern CFURLRef CFCopyHomeDirectoryURL(void);
extern CFURLRef CFCopyHomeDirectoryURLForUser(CFStringRef uName);
extern CFStringRef CFCopyUserName(void);

static CFURLRef pt_CFCopyHomeDirectoryURL(void) {
    if (!pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        const char *vh = pt_get_virtual_home_cstr();
        if (vh != NULL) {
            return CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
                                                           (const UInt8 *)vh,
                                                           (CFIndex)strlen(vh),
                                                           true);
        }
    }
    return CFCopyHomeDirectoryURL();
}

static CFURLRef pt_CFCopyHomeDirectoryURLForUser(CFStringRef uName) {
    if (!pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        const char *vh = pt_get_virtual_home_cstr();
        if (vh != NULL) {
            NSString *uStr = (__bridge NSString *)uName;
            if (uStr == nil || [uStr isEqualToString:@"mobile"]) {
                return CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
                                                               (const UInt8 *)vh,
                                                               (CFIndex)strlen(vh),
                                                               true);
            }
            return NULL;
        }
    }
    return CFCopyHomeDirectoryURLForUser(uName);
}

static CFStringRef pt_CFCopyUserName(void) {
    if (!pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return CFSTR("mobile");
    }
    return CFCopyUserName();
}

static NSString *pt_NSHomeDirectory(void) {
    if (!pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        const char *vh = pt_get_virtual_home_cstr();
        if (vh != NULL) {
            return [NSString stringWithUTF8String:vh];
        }
    }
    return NSHomeDirectory();
}

static NSString *pt_NSHomeDirectoryForUser(NSString *userName) {
    if (!pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        const char *vh = pt_get_virtual_home_cstr();
        if (vh != NULL) {
            if (userName == nil || [userName isEqualToString:@"mobile"]) {
                return [NSString stringWithUTF8String:vh];
            }
            return nil;
        }
    }
    return NSHomeDirectoryForUser(userName);
}

static NSString *pt_NSTemporaryDirectory(void) {
    if (!pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        const char *vt = pt_get_virtual_tmpdir_cstr();
        if (vt != NULL) {
            return [NSString stringWithUTF8String:vt];
        }
    }
    return NSTemporaryDirectory();
}

static NSArray<NSString *> *pt_NSSearchPathForDirectoriesInDomains(NSSearchPathDirectory directory,
                                                                   NSSearchPathDomainMask domainMask,
                                                                   BOOL expandTilde) {
    const void *caller = __builtin_return_address(0);
    NSArray<NSString *> *orig = NSSearchPathForDirectoriesInDomains(directory, domainMask, expandTilde);
    if (orig.count > 0 && !pt_is_effective_system_or_playtools_caller(caller)) {
        BOOL bypass = pt_is_bypass_enabled();
        NSMutableArray<NSString *> *filtered = nil;
        for (NSUInteger i = 0; i < orig.count; i++) {
            NSString *item = orig[i];
            NSString *outItem = item;
            const char *raw = [item fileSystemRepresentation];
            char vbuf[PATH_MAX];
            const char *virt = expandTilde ? pt_virtualize_path_for_app(raw, vbuf, sizeof(vbuf), NO) : raw;
            if (expandTilde && virt != NULL && virt != raw) {
                NSString *virtStr = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:virt
                                                                                                length:strlen(virt)];
                if (virtStr != nil) {
                    outItem = virtStr;
                }
            }
            const char *checkPath = (virt != NULL) ? virt : raw;
            BOOL hide = (bypass && checkPath != NULL && pt_is_hidden_path(checkPath, caller));
            if ((outItem != item || hide) && filtered == nil) {
                filtered = [NSMutableArray arrayWithCapacity:orig.count];
                for (NSUInteger j = 0; j < i; j++) {
                    [filtered addObject:orig[j]];
                }
            }
            if (filtered != nil && !hide) {
                [filtered addObject:outItem];
            }
        }
        if (filtered != nil) {
            return [filtered copy];
        }
    }
    return orig;
}

__attribute__((visibility("hidden"))) CFURLRef pt_resolve_cfbundle_input_url(CFURLRef url, const void *caller, BOOL *out_blocked) CF_RETURNS_RETAINED {
    if (out_blocked != NULL) {
        *out_blocked = NO;
    }
    if (url == NULL) {
        return NULL;
    }
    UInt8 raw[PATH_MAX];
    if (!CFURLGetFileSystemRepresentation(url, true, raw, sizeof(raw))) {
        return (CFURLRef)CFRetain(url);
    }
    const char *orig_path = (const char *)raw;
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller) &&
        (pt_is_hidden_path(orig_path, caller) ||
         pt_is_hidden_dyld_image_name(orig_path) ||
         pt_is_post13_7_hidden_framework_path(orig_path))) {
        if (out_blocked != NULL) {
            *out_blocked = YES;
        }
        return NULL;
    }
    char resolved_buf[PATH_MAX];
    const char *resolved = pt_resolve_virtual_path(orig_path, resolved_buf, sizeof(resolved_buf));
    if (resolved != NULL && resolved != orig_path && strcmp(resolved, orig_path) != 0) {
        Boolean isDir = CFURLHasDirectoryPath(url);
        CFURLRef resolvedURL = CFURLCreateFromFileSystemRepresentation(
            kCFAllocatorDefault, (const UInt8 *)resolved, (CFIndex)strlen(resolved), isDir);
        if (resolvedURL != NULL) {
            return resolvedURL;
        }
    }
    return (CFURLRef)CFRetain(url);
}

__attribute__((visibility("hidden"))) CFURLRef pt_sanitize_cfbundle_returned_url(CFURLRef CF_CONSUMED url, const void *caller) CF_RETURNS_RETAINED {
    if (url == NULL) {
        return NULL;
    }
    if (!pt_is_bypass_enabled() || pt_is_effective_system_or_playtools_caller(caller)) {
        return url;
    }
    UInt8 raw[PATH_MAX];
    if (!CFURLGetFileSystemRepresentation(url, true, raw, sizeof(raw))) {
        return url;
    }
    const char *orig_path = (const char *)raw;
    char vbuf[PATH_MAX];
    const char *virt = pt_virtualize_path_for_app(orig_path, vbuf, sizeof(vbuf), YES);
    const char *check_path = (virt != NULL) ? virt : orig_path;
    if (pt_is_hidden_path(check_path, caller) || pt_is_hidden_dyld_image_name(check_path)) {
        CFRelease(url);
        return NULL;
    }
    if (virt != NULL && strcmp(virt, orig_path) != 0) {
        Boolean isDir = CFURLHasDirectoryPath(url);
        CFURLRef virtURL = CFURLCreateFromFileSystemRepresentation(
            kCFAllocatorDefault, (const UInt8 *)virt, (CFIndex)strlen(virt), isDir);
        if (virtURL != NULL) {
            CFRelease(url);
            return virtURL;
        }
    }
    return url;
}

static CFArrayRef pt_sanitize_cfbundle_returned_url_array(CFArrayRef CF_CONSUMED urls, const void *caller) CF_RETURNS_RETAINED {
    if (urls == NULL) {
        return NULL;
    }
    if (!pt_is_bypass_enabled() || pt_is_effective_system_or_playtools_caller(caller)) {
        return urls;
    }
    CFIndex count = CFArrayGetCount(urls);
    if (count <= 0) {
        return urls;
    }
    CFMutableArrayRef out = CFArrayCreateMutable(kCFAllocatorDefault, count, &kCFTypeArrayCallBacks);
    if (out == NULL) {
        return urls;
    }
    BOOL changed = NO;
    for (CFIndex i = 0; i < count; i++) {
        CFTypeRef elem = CFArrayGetValueAtIndex(urls, i);
        if (elem == NULL || CFGetTypeID(elem) != CFURLGetTypeID()) {
            changed = YES;
            continue;
        }
        CFURLRef origURL = (CFURLRef)elem;
        CFURLRef retained = (CFURLRef)CFRetain(origURL);
        CFURLRef sanitized = pt_sanitize_cfbundle_returned_url(retained, caller);
        if (sanitized == NULL) {
            changed = YES;
        } else {
            if (sanitized != origURL) {
                changed = YES;
            }
            CFArrayAppendValue(out, sanitized);
            CFRelease(sanitized);
        }
    }
    if (!changed) {
        CFRelease(out);
        return urls;
    }
    CFRelease(urls);
    return out;
}

__attribute__((visibility("hidden")))
BOOL pt_is_hidden_bundle_id_cstr(const char *bid) {
    return pt_is_hidden_bundle_id_rule_cstr(bid, pt_is_compat13_7_active() ? true : false) ? YES : NO;
}

static BOOL pt_is_hidden_bundle_identifier(CFStringRef bundleID) {
    if (bundleID == NULL) {
        return NO;
    }
    const char *fast = CFStringGetCStringPtr(bundleID, kCFStringEncodingUTF8);
    if (fast != NULL) {
        return pt_is_hidden_bundle_id_cstr(fast);
    }
    char buf[256];
    if (CFStringGetCString(bundleID, buf, (CFIndex)sizeof(buf), kCFStringEncodingUTF8)) {
        return pt_is_hidden_bundle_id_cstr(buf);
    }
    return NO;
}

static BOOL pt_bundle_is_hidden(CFBundleRef bundle, const void *caller) {
    if (bundle == NULL) {
        return NO;
    }
    CFStringRef bid = CFBundleGetIdentifier(bundle);
    if (bid != NULL && pt_is_hidden_bundle_identifier(bid)) {
        return YES;
    }
    CFURLRef bURL = CFBundleCopyBundleURL(bundle);
    if (bURL != NULL) {
        UInt8 raw[PATH_MAX];
        BOOL hidden = NO;
        if (CFURLGetFileSystemRepresentation(bURL, true, raw, sizeof(raw))) {
            char vbuf[PATH_MAX];
            const char *virt = pt_virtualize_path_for_app((const char *)raw, vbuf, sizeof(vbuf), YES);
            const char *check_path = (virt != NULL) ? virt : (const char *)raw;
            hidden = (pt_is_hidden_path(check_path, caller) || pt_is_hidden_dyld_image_name(check_path));
        }
        CFRelease(bURL);
        return hidden;
    }
    return NO;
}

static pthread_once_t s_info_min_os_once = PTHREAD_ONCE_INIT;
static char s_info_main_bundle_id[256];
static char s_info_orig_min_os_ver[64];

static void pt_init_info_min_os_cache(void) {
    s_info_main_bundle_id[0] = '\0';
    s_info_orig_min_os_ver[0] = '\0';
    (void)pt_read_main_bundle_id_early(s_info_main_bundle_id, sizeof(s_info_main_bundle_id));
    int sfd = pt_open_early_settings_plist_fd();
    if (sfd >= 0) {
        (void)pt_read_plist_top_string_from_fd(
            sfd, "originalMinimumOSVersion", s_info_orig_min_os_ver, sizeof(s_info_orig_min_os_ver));
        close(sfd);
    }
}

static id pt_restored_min_os_for_info_dict(NSDictionary *dict) {
    id origVal = dict[@"MinimumOSVersion"];
    if (origVal == nil) {
        return nil;
    }
    pthread_once(&s_info_min_os_once, pt_init_info_min_os_cache);
    id bid = dict[@"CFBundleIdentifier"];
    if (s_info_main_bundle_id[0] != '\0') {
        if (![bid isKindOfClass:[NSString class]]) {
            return origVal;
        }
        const char *bidC = [(NSString *)bid UTF8String];
        if (bidC == NULL || strcmp(bidC, s_info_main_bundle_id) != 0) {
            return origVal;
        }
    }
    if (s_info_orig_min_os_ver[0] != '\0') {
        return [NSString stringWithUTF8String:s_info_orig_min_os_ver];
    }
    if ([origVal isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)origVal;
        if ([s isEqualToString:@"11"] || [s isEqualToString:@"11.0"]) {
            return @"15.0";
        }
    }
    return origVal;
}

__attribute__((visibility("hidden"))) BOOL pt_is_info_plist_dict(NSDictionary *dict) {
    return [dict isKindOfClass:[NSDictionary class]] &&
           (dict[@"CFBundleIdentifier"] != nil || dict[@"CFBundleExecutable"] != nil);
}

static NSString *pt_compat13_framework_bundle_version(NSString *bid) {
    if (![bid isKindOfClass:[NSString class]] || !pt_is_compat13_7_active()) {
        return nil;
    }
    if ([bid isEqualToString:@"com.apple.Foundation"] ||
        [bid isEqualToString:@"com.apple.CoreFoundation"]) {
        return @"1677.104";
    }
    if ([bid isEqualToString:@"com.apple.UIKitCore"] ||
        [bid isEqualToString:@"com.apple.UIKit"]) {
        return @"3698.54.4";
    }
    if ([bid isEqualToString:@"com.apple.CoreMotion"]) {
        return @"2394.0.33";
    }
    if ([bid isEqualToString:@"com.apple.WebKit"] ||
        [bid isEqualToString:@"com.apple.JavaScriptCore"]) {
        return @"609.4.1";
    }
    if ([bid isEqualToString:@"com.apple.CFNetwork"]) {
        return @"1128.0.1";
    }
    if ([bid isEqualToString:@"com.apple.Photos"]) {
        return @"3652.30.210";
    }
    if ([bid isEqualToString:@"com.apple.GameController"]) {
        return @"1.0";
    }
    if ([bid isEqualToString:@"com.apple.Metal"]) {
        return @"212.8";
    }
    if ([bid isEqualToString:@"com.apple.Security"]) {
        return @"59306.140.5";
    }
    if ([bid isEqualToString:@"com.apple.CoreGraphics"]) {
        return @"1355.22";
    }
    if ([bid isEqualToString:@"com.apple.QuartzCore"]) {
        return @"841.4";
    }
    if ([bid isEqualToString:@"com.apple.AVFoundation"]) {
        return @"1800.12";
    }
    if ([bid isEqualToString:@"com.apple.audio.CoreAudio"] ||
        [bid isEqualToString:@"com.apple.CoreAudio"] ||
        [bid isEqualToString:@"com.apple.audio.toolbox.AudioToolbox"]) {
        return @"5.0";
    }
    if ([bid isEqualToString:@"com.apple.SwiftUI"]) {
        return @"42.19.2";
    }
    if ([bid isEqualToString:@"com.apple.corelocation"] ||
        [bid isEqualToString:@"com.apple.CoreLocation"]) {
        return @"2394.0.22";
    }
    if ([bid isEqualToString:@"com.apple.CoreBluetooth"]) {
        return @"1";
    }
    if ([bid isEqualToString:@"com.apple.CoreImage"]) {
        return @"940.9";
    }
    if ([bid isEqualToString:@"com.apple.CoreText"]) {
        return @"643.1.5.1";
    }
    if ([bid isEqualToString:@"com.apple.ImageIO.framework"] ||
        [bid isEqualToString:@"com.apple.ImageIO"]) {
        return @"1976.11";
    }
    if ([bid isEqualToString:@"com.apple.Network"]) {
        return @"1880.120.4";
    }
    return nil;
}

static NSString *pt_sanitized_dtsdk_name(NSString *sdkStr, NSString *bid) {
    if (![sdkStr isKindOfClass:[NSString class]]) {
        return nil;
    }
    const char *ovVer = pt_get_reported_ios_version_override(NULL);
    const char *verCStr = (ovVer != NULL && ovVer[0] != '\0') ? ovVer : pt_get_spoofed_ios_version_cstr();
    NSString *iosSdk = (verCStr != NULL && verCStr[0] != '\0')
        ? [NSString stringWithFormat:@"iphoneos%s", verCStr]
        : @"iphoneos";
    BOOL isApple = ([bid isKindOfClass:[NSString class]] && [bid hasPrefix:@"com.apple."]);
    if (isApple && (pt_is_compat13_7_active() || (ovVer != NULL && ovVer[0] != '\0'))) {
        return iosSdk;
    }
    NSString *cleaned = sdkStr;
    if ([cleaned rangeOfString:@"macosx" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        cleaned = [cleaned stringByReplacingOccurrencesOfString:@"macosx"
                                                     withString:@"iphoneos"
                                                        options:NSCaseInsensitiveSearch
                                                          range:NSMakeRange(0, cleaned.length)];
    } else if ([cleaned rangeOfString:@"maccatalyst" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        cleaned = iosSdk;
    }
    if ([cleaned hasSuffix:@".internal"]) {
        cleaned = isApple ? iosSdk : [cleaned substringToIndex:(cleaned.length - 9U)];
    }
    return cleaned;
}

__attribute__((visibility("hidden"))) BOOL pt_info_dict_needs_sanitize(NSDictionary *dict) {
    if (![dict isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    if (dict[@"LSMinimumSystemVersion"] != nil ||
        dict[@"LSMinimumSystemVersionByArchitecture"] != nil ||
        dict[@"LSRequiresNativeExecution"] != nil ||
        dict[@"NSSupportsAutomaticTermination"] != nil ||
        dict[@"NSSupportsSuddenTermination"] != nil ||
        dict[@"LSApplicationCategoryType"] != nil ||
        dict[@"LSEnvironment"] != nil ||
        dict[@"PCInstallGeneration"] != nil) {
        return YES;
    }
    id minOS = dict[@"MinimumOSVersion"];
    if (minOS != nil) {
        id restored = pt_restored_min_os_for_info_dict(dict);
        if (restored != minOS && restored != nil && ![restored isEqual:minOS]) {
            return YES;
        }
    }
    id prin = dict[@"NSPrincipalClass"];
    if ([prin isKindOfClass:[NSString class]] && [(NSString *)prin isEqualToString:@"NSApplication"]) {
        return YES;
    }
    id dtPlatform = dict[@"DTPlatformName"];
    if ([dtPlatform isKindOfClass:[NSString class]]) {
        NSString *dp = (NSString *)dtPlatform;
        if ([dp caseInsensitiveCompare:@"macosx"] == NSOrderedSame ||
            [dp caseInsensitiveCompare:@"maccatalyst"] == NSOrderedSame) {
            return YES;
        }
    }
    id bid = dict[@"CFBundleIdentifier"];
    NSString *bidStr = [bid isKindOfClass:[NSString class]] ? (NSString *)bid : nil;
    BOOL isApple = (bidStr != nil && [bidStr hasPrefix:@"com.apple."]);
    const char *ovVer = pt_get_reported_ios_version_override(NULL);
    id dtSdk = dict[@"DTSDKName"];
    if ([dtSdk isKindOfClass:[NSString class]]) {
        NSString *sdkStr = (NSString *)dtSdk;
        if ([sdkStr rangeOfString:@"macosx" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [sdkStr rangeOfString:@"maccatalyst" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [sdkStr hasSuffix:@".internal"]) {
            return YES;
        }
        if (isApple && pt_is_compat13_7_active() && ![sdkStr isEqualToString:@"iphoneos13.7"]) {
            return YES;
        }
        if (isApple && ovVer != NULL && ovVer[0] != '\0') {
            NSString *expectedSdk = [NSString stringWithFormat:@"iphoneos%s", ovVer];
            if (![sdkStr isEqualToString:expectedSdk]) {
                return YES;
            }
        }
    }
    if (isApple && pt_is_compat13_7_active()) {
        id dtPlatVer = dict[@"DTPlatformVersion"];
        if ([dtPlatVer isKindOfClass:[NSString class]] && ![(NSString *)dtPlatVer isEqualToString:@"13.7"]) {
            return YES;
        }
        id dtSdkBuild = dict[@"DTSDKBuild"];
        if ([dtSdkBuild isKindOfClass:[NSString class]] && ![(NSString *)dtSdkBuild isEqualToString:@"17H35"]) {
            return YES;
        }
        id dtPlatBuild = dict[@"DTPlatformBuild"];
        if ([dtPlatBuild isKindOfClass:[NSString class]] && ![(NSString *)dtPlatBuild isEqualToString:@"17H35"]) {
            return YES;
        }
        id dtXcode = dict[@"DTXcode"];
        if ([dtXcode isKindOfClass:[NSString class]] && ![(NSString *)dtXcode isEqualToString:@"1170"]) {
            return YES;
        }
        id dtXcodeBuild = dict[@"DTXcodeBuild"];
        if ([dtXcodeBuild isKindOfClass:[NSString class]] && ![(NSString *)dtXcodeBuild isEqualToString:@"11E801a"]) {
            return YES;
        }
        id buildOs = dict[@"BuildMachineOSBuild"];
        if ([buildOs isKindOfClass:[NSString class]] && ![(NSString *)buildOs isEqualToString:@"19G2021"]) {
            return YES;
        }
    } else if (isApple) {
        pt_ensure_host_kernel_info();
        const char *ovBuild = NULL;
        const char *ovVer = pt_get_reported_ios_version_override(&ovBuild);
        const char *effVer = (ovVer != NULL && ovVer[0] != '\0') ? ovVer : s_spoofed_ios_version;
        const char *effBuild = (ovBuild != NULL && ovBuild[0] != '\0') ? ovBuild : s_spoofed_osversion;
        if (effVer != NULL && effVer[0] != '\0' && [dict[@"DTPlatformVersion"] isKindOfClass:[NSString class]]) {
            NSString *expVer = [NSString stringWithUTF8String:effVer];
            if (expVer != nil && ![(NSString *)dict[@"DTPlatformVersion"] isEqualToString:expVer]) {
                return YES;
            }
        }
        if (effBuild != NULL && effBuild[0] != '\0') {
            NSString *expBuild = [NSString stringWithUTF8String:effBuild];
            if (expBuild != nil) {
                if ([dict[@"DTSDKBuild"] isKindOfClass:[NSString class]] &&
                    ![(NSString *)dict[@"DTSDKBuild"] isEqualToString:expBuild]) {
                    return YES;
                }
                if ([dict[@"DTPlatformBuild"] isKindOfClass:[NSString class]] &&
                    ![(NSString *)dict[@"DTPlatformBuild"] isEqualToString:expBuild]) {
                    return YES;
                }
            }
        }
    }
    NSString *targetVer = pt_compat13_framework_bundle_version(bidStr);
    if (targetVer != nil &&
        [dict[@"CFBundleVersion"] isKindOfClass:[NSString class]] &&
        ![(NSString *)dict[@"CFBundleVersion"] isEqualToString:targetVer]) {
        return YES;
    }
    id sup = dict[@"CFBundleSupportedPlatforms"];
    if ([sup isKindOfClass:[NSArray class]]) {
        for (id p in (NSArray *)sup) {
            if ([p isKindOfClass:[NSString class]] &&
                ([(NSString *)p isEqualToString:@"MacOSX"] ||
                 [(NSString *)p isEqualToString:@"macOS"] ||
                 [(NSString *)p isEqualToString:@"MacCatalyst"])) {
                return YES;
            }
        }
    }
    return NO;
}

__attribute__((visibility("hidden"))) NSMutableDictionary *pt_build_sanitized_mutable_info_dict(NSDictionary *dict) {
    if (![dict isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSMutableDictionary *m = [dict mutableCopy];
    [m removeObjectForKey:@"LSMinimumSystemVersion"];
    [m removeObjectForKey:@"LSMinimumSystemVersionByArchitecture"];
    [m removeObjectForKey:@"LSRequiresNativeExecution"];
    [m removeObjectForKey:@"NSSupportsAutomaticTermination"];
    [m removeObjectForKey:@"NSSupportsSuddenTermination"];
    [m removeObjectForKey:@"LSApplicationCategoryType"];
    [m removeObjectForKey:@"LSEnvironment"];
    [m removeObjectForKey:@"PCInstallGeneration"];

    id minOS = dict[@"MinimumOSVersion"];
    if (minOS != nil) {
        id restored = pt_restored_min_os_for_info_dict(dict);
        if (restored != minOS && restored != nil && ![restored isEqual:minOS]) {
            m[@"MinimumOSVersion"] = restored;
        }
    }
    id prin = m[@"NSPrincipalClass"];
    if ([prin isKindOfClass:[NSString class]] && [(NSString *)prin isEqualToString:@"NSApplication"]) {
        m[@"NSPrincipalClass"] = @"UIApplication";
    }
    id dtPlatform = m[@"DTPlatformName"];
    if ([dtPlatform isKindOfClass:[NSString class]]) {
        NSString *dp = (NSString *)dtPlatform;
        if ([dp caseInsensitiveCompare:@"macosx"] == NSOrderedSame ||
            [dp caseInsensitiveCompare:@"maccatalyst"] == NSOrderedSame) {
            m[@"DTPlatformName"] = @"iphoneos";
        }
    }
    NSString *bidStr = [m[@"CFBundleIdentifier"] isKindOfClass:[NSString class]] ? (NSString *)m[@"CFBundleIdentifier"] : nil;
    BOOL isApple = (bidStr != nil && [bidStr hasPrefix:@"com.apple."]);
    id dtSdk = m[@"DTSDKName"];
    if ([dtSdk isKindOfClass:[NSString class]]) {
        NSString *cleanSdk = pt_sanitized_dtsdk_name((NSString *)dtSdk, bidStr);
        if (cleanSdk != nil && ![cleanSdk isEqualToString:(NSString *)dtSdk]) {
            m[@"DTSDKName"] = cleanSdk;
        }
    }
    if (isApple && pt_is_compat13_7_active()) {
        if ([m[@"DTPlatformVersion"] isKindOfClass:[NSString class]]) {
            m[@"DTPlatformVersion"] = @"13.7";
        }
        if ([m[@"DTSDKBuild"] isKindOfClass:[NSString class]]) {
            m[@"DTSDKBuild"] = @"17H35";
        }
        if ([m[@"DTPlatformBuild"] isKindOfClass:[NSString class]]) {
            m[@"DTPlatformBuild"] = @"17H35";
        }
        if ([m[@"DTXcode"] isKindOfClass:[NSString class]]) {
            m[@"DTXcode"] = @"1170";
        }
        if ([m[@"DTXcodeBuild"] isKindOfClass:[NSString class]]) {
            m[@"DTXcodeBuild"] = @"11E801a";
        }
        if ([m[@"BuildMachineOSBuild"] isKindOfClass:[NSString class]]) {
            m[@"BuildMachineOSBuild"] = @"19G2021";
        }
    } else if (isApple) {
        pt_ensure_host_kernel_info();
        const char *ovBuild = NULL;
        const char *ovVer = pt_get_reported_ios_version_override(&ovBuild);
        const char *effVer = (ovVer != NULL && ovVer[0] != '\0') ? ovVer : s_spoofed_ios_version;
        const char *effBuild = (ovBuild != NULL && ovBuild[0] != '\0') ? ovBuild : s_spoofed_osversion;
        if (effVer != NULL && effVer[0] != '\0' && [m[@"DTPlatformVersion"] isKindOfClass:[NSString class]]) {
            NSString *expVer = [NSString stringWithUTF8String:effVer];
            if (expVer != nil) {
                m[@"DTPlatformVersion"] = expVer;
            }
        }
        if (effBuild != NULL && effBuild[0] != '\0') {
            NSString *expBuild = [NSString stringWithUTF8String:effBuild];
            if (expBuild != nil) {
                if ([m[@"DTSDKBuild"] isKindOfClass:[NSString class]]) {
                    m[@"DTSDKBuild"] = expBuild;
                }
                if ([m[@"DTPlatformBuild"] isKindOfClass:[NSString class]]) {
                    m[@"DTPlatformBuild"] = expBuild;
                }
            }
        }
    }
    NSString *targetVer = pt_compat13_framework_bundle_version(bidStr);
    if (targetVer != nil && [m[@"CFBundleVersion"] isKindOfClass:[NSString class]]) {
        m[@"CFBundleVersion"] = targetVer;
    }
    id sup = m[@"CFBundleSupportedPlatforms"];
    if ([sup isKindOfClass:[NSArray class]]) {
        BOOL hasMac = NO;
        for (id p in (NSArray *)sup) {
            if ([p isKindOfClass:[NSString class]] &&
                ([(NSString *)p isEqualToString:@"MacOSX"] ||
                 [(NSString *)p isEqualToString:@"macOS"] ||
                 [(NSString *)p isEqualToString:@"MacCatalyst"])) {
                hasMac = YES;
                break;
            }
        }
        if (hasMac) {
            m[@"CFBundleSupportedPlatforms"] = [NSMutableArray arrayWithObject:@"iPhoneOS"];
        }
    }
    return m;
}

__attribute__((visibility("hidden")))
BOOL pt_is_hidden_macos_pref_key(const char *key) {
    return pt_is_hidden_macos_pref_key_cstr(key) ? YES : NO;
}

static BOOL pt_cfstr_to_cstr(CFStringRef s, char *buf, size_t cap, const char **out_ptr) {
    if (s == NULL || out_ptr == NULL) {
        return NO;
    }
    const char *fast = CFStringGetCStringPtr(s, kCFStringEncodingUTF8);
    if (fast != NULL) {
        *out_ptr = fast;
        return YES;
    }
    if (buf != NULL && cap > 0 && CFStringGetCString(s, buf, (CFIndex)cap, kCFStringEncodingUTF8)) {
        *out_ptr = buf;
        return YES;
    }
    return NO;
}

__attribute__((visibility("hidden")))
BOOL pt_cstr_contains_macos_pref_leak(const char *s) {
    if (s == NULL || s[0] == '\0') {
        return NO;
    }
    return (strstr(s, "/Users/") != NULL ||
            strstr(s, "/System/Volumes/Data") != NULL ||
            strcasestr(s, "PlayCover") != NULL ||
            strcasestr(s, "PlayTools") != NULL ||
            strcasestr(s, "MacOver") != NULL);
}

static BOOL pt_pref_value_contains_macos_leak(CFPropertyListRef val, int depth) {
    if (val == NULL || depth > 3) {
        return NO;
    }
    CFTypeID tid = CFGetTypeID(val);
    if (tid == CFStringGetTypeID()) {
        char buf[512];
        const char *cstr = NULL;
        if (pt_cfstr_to_cstr((CFStringRef)val, buf, sizeof(buf), &cstr)) {
            return pt_cstr_contains_macos_pref_leak(cstr);
        }
        return NO;
    }
    if (tid == CFArrayGetTypeID()) {
        CFArrayRef arr = (CFArrayRef)val;
        CFIndex n = CFArrayGetCount(arr);
        if (n > 4096) {
            n = 4096;
        }
        for (CFIndex i = 0; i < n; i++) {
            if (pt_pref_value_contains_macos_leak(CFArrayGetValueAtIndex(arr, i), depth + 1)) {
                return YES;
            }
        }
        return NO;
    }
    if (tid == CFDictionaryGetTypeID()) {
        NSDictionary *nsDict = (__bridge NSDictionary *)val;
        for (id k in nsDict) {
            if ([k isKindOfClass:[NSString class]]) {
                const char *kc = [(NSString *)k UTF8String];
                if (kc != NULL && pt_is_hidden_macos_pref_key(kc)) {
                    return YES;
                }
            }
            id v = nsDict[k];
            if (v != nil && pt_pref_value_contains_macos_leak((__bridge CFPropertyListRef)v, depth + 1)) {
                return YES;
            }
        }
        return NO;
    }
    return NO;
}

static CFPropertyListRef pt_sanitize_cfpref_value_retained(CFPropertyListRef CF_CONSUMED val, int depth) CF_RETURNS_RETAINED {
    if (val == NULL) {
        return NULL;
    }
    if (depth > 3 || !pt_pref_value_contains_macos_leak(val, depth)) {
        return val;
    }
    CFTypeID tid = CFGetTypeID(val);
    if (tid == CFStringGetTypeID()) {
        CFRelease(val);
        return NULL;
    }
    if (tid == CFArrayGetTypeID()) {
        CFArrayRef arr = (CFArrayRef)val;
        CFIndex n = CFArrayGetCount(arr);
        CFMutableArrayRef out = CFArrayCreateMutable(kCFAllocatorDefault, n, &kCFTypeArrayCallBacks);
        if (out == NULL) {
            CFRelease(val);
            return NULL;
        }
        for (CFIndex i = 0; i < n; i++) {
            CFPropertyListRef elem = CFArrayGetValueAtIndex(arr, i);
            if (elem == NULL) {
                continue;
            }
            CFPropertyListRef clean = pt_sanitize_cfpref_value_retained((CFPropertyListRef)CFRetain(elem), depth + 1);
            if (clean != NULL) {
                CFArrayAppendValue(out, clean);
                CFRelease(clean);
            }
        }
        CFRelease(val);
        return out;
    }
    if (tid == CFDictionaryGetTypeID()) {
        NSDictionary *nsDict = (__bridge NSDictionary *)val;
        NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:nsDict.count];
        for (id k in nsDict) {
            if ([k isKindOfClass:[NSString class]]) {
                const char *kc = [(NSString *)k UTF8String];
                if (kc != NULL && pt_is_hidden_macos_pref_key(kc)) {
                    continue;
                }
            }
            id v = nsDict[k];
            if (v == nil) {
                continue;
            }
            CFPropertyListRef clean = pt_sanitize_cfpref_value_retained((CFPropertyListRef)CFRetain((__bridge CFTypeRef)v), depth + 1);
            if (clean != NULL) {
                out[k] = (__bridge_transfer id)clean;
            }
        }
        CFRelease(val);
        return (__bridge_retained CFPropertyListRef)[out copy];
    }
    CFRelease(val);
    return NULL;
}

static CFPropertyListRef pt_CFPreferencesCopyAppValue(CFStringRef key, CFStringRef applicationID) CF_RETURNS_RETAINED {
    if (key == NULL) {
        return NULL;
    }
    BOOL should_filter = (pt_is_bypass_enabled() &&
                          !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    if (should_filter) {
        char kbuf[256];
        const char *kstr = NULL;
        if (pt_cfstr_to_cstr(key, kbuf, sizeof(kbuf), &kstr) && pt_is_hidden_macos_pref_key(kstr)) {
            return NULL;
        }
    }
    CFPropertyListRef val = CFPreferencesCopyAppValue(key, applicationID);
    if (val != NULL && should_filter) {
        return pt_sanitize_cfpref_value_retained(val, 0);
    }
    return val;
}

static CFPropertyListRef pt_CFPreferencesCopyValue(CFStringRef key,
                                                   CFStringRef applicationID,
                                                   CFStringRef userName,
                                                   CFStringRef hostName) CF_RETURNS_RETAINED {
    if (key == NULL) {
        return NULL;
    }
    BOOL should_filter = (pt_is_bypass_enabled() &&
                          !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    if (should_filter) {
        char kbuf[256];
        const char *kstr = NULL;
        if (pt_cfstr_to_cstr(key, kbuf, sizeof(kbuf), &kstr) && pt_is_hidden_macos_pref_key(kstr)) {
            return NULL;
        }
    }
    CFPropertyListRef val = CFPreferencesCopyValue(key, applicationID, userName, hostName);
    if (val != NULL && should_filter) {
        return pt_sanitize_cfpref_value_retained(val, 0);
    }
    return val;
}

static CFArrayRef pt_CFPreferencesCopyKeyList(CFStringRef applicationID,
                                              CFStringRef userName,
                                              CFStringRef hostName) CF_RETURNS_RETAINED {
    CFArrayRef keys = CFPreferencesCopyKeyList(applicationID, userName, hostName);
    if (keys == NULL ||
        !pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return keys;
    }
    CFIndex n = CFArrayGetCount(keys);
    CFMutableArrayRef out = NULL;
    for (CFIndex i = 0; i < n; i++) {
        CFTypeRef item = CFArrayGetValueAtIndex(keys, i);
        BOOL hide = NO;
        if (item != NULL && CFGetTypeID(item) == CFStringGetTypeID()) {
            char kbuf[256];
            const char *kstr = NULL;
            if (pt_cfstr_to_cstr((CFStringRef)item, kbuf, sizeof(kbuf), &kstr) &&
                pt_is_hidden_macos_pref_key(kstr)) {
                hide = YES;
            }
        }
        if (hide && out == NULL) {
            out = CFArrayCreateMutable(kCFAllocatorDefault, n, &kCFTypeArrayCallBacks);
            if (out != NULL) {
                for (CFIndex j = 0; j < i; j++) {
                    CFArrayAppendValue(out, CFArrayGetValueAtIndex(keys, j));
                }
            }
        } else if (out != NULL && !hide) {
            CFArrayAppendValue(out, item);
        }
    }
    if (out != NULL) {
        CFRelease(keys);
        return out;
    }
    return keys;
}

static Boolean pt_CFPreferencesGetAppBooleanValue(CFStringRef key,
                                                 CFStringRef applicationID,
                                                 Boolean *keyExistsAndHasValidFormat) {
    if (key == NULL) {
        if (keyExistsAndHasValidFormat != NULL) {
            *keyExistsAndHasValidFormat = false;
        }
        return false;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        char kbuf[256];
        const char *kstr = NULL;
        if (pt_cfstr_to_cstr(key, kbuf, sizeof(kbuf), &kstr) && pt_is_hidden_macos_pref_key(kstr)) {
            if (keyExistsAndHasValidFormat != NULL) {
                *keyExistsAndHasValidFormat = false;
            }
            return false;
        }
    }
    return CFPreferencesGetAppBooleanValue(key, applicationID, keyExistsAndHasValidFormat);
}

static CFIndex pt_CFPreferencesGetAppIntegerValue(CFStringRef key,
                                                 CFStringRef applicationID,
                                                 Boolean *keyExistsAndHasValidFormat) {
    if (key == NULL) {
        if (keyExistsAndHasValidFormat != NULL) {
            *keyExistsAndHasValidFormat = false;
        }
        return 0;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        char kbuf[256];
        const char *kstr = NULL;
        if (pt_cfstr_to_cstr(key, kbuf, sizeof(kbuf), &kstr) && pt_is_hidden_macos_pref_key(kstr)) {
            if (keyExistsAndHasValidFormat != NULL) {
                *keyExistsAndHasValidFormat = false;
            }
            return 0;
        }
    }
    return CFPreferencesGetAppIntegerValue(key, applicationID, keyExistsAndHasValidFormat);
}

static CFDictionaryRef pt_CFPreferencesCopyMultiple(CFArrayRef keysToFetch,
                                                    CFStringRef applicationID,
                                                    CFStringRef userName,
                                                    CFStringRef hostName) CF_RETURNS_RETAINED {
    CFDictionaryRef dict = CFPreferencesCopyMultiple(keysToFetch, applicationID, userName, hostName);
    if (dict == NULL ||
        !pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return dict;
    }
    return (CFDictionaryRef)pt_sanitize_cfpref_value_retained(dict, 0);
}

static Boolean pt_CFPreferencesAppValueIsForced(CFStringRef key, CFStringRef applicationID) {
    if (key == NULL) {
        return false;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        char kbuf[256];
        const char *kstr = NULL;
        if (pt_cfstr_to_cstr(key, kbuf, sizeof(kbuf), &kstr) && pt_is_hidden_macos_pref_key(kstr)) {
            return false;
        }
    }
    return CFPreferencesAppValueIsForced(key, applicationID);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static CFArrayRef pt_CFPreferencesCopyApplicationList(CFStringRef userName,
                                                      CFStringRef hostName) CF_RETURNS_RETAINED {
    CFArrayRef list = CFPreferencesCopyApplicationList(userName, hostName);
    if (list == NULL ||
        !pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return list;
    }
    char mainBidBuf[256];
    mainBidBuf[0] = '\0';
    (void)pt_read_main_bundle_id_early(mainBidBuf, sizeof(mainBidBuf));
    CFIndex n = CFArrayGetCount(list);
    CFMutableArrayRef out = CFArrayCreateMutable(kCFAllocatorDefault, n, &kCFTypeArrayCallBacks);
    if (out == NULL) {
        return list;
    }
    for (CFIndex i = 0; i < n; i++) {
        CFTypeRef item = CFArrayGetValueAtIndex(list, i);
        if (item == NULL || CFGetTypeID(item) != CFStringGetTypeID()) {
            continue;
        }
        char dbuf[256];
        const char *dstr = NULL;
        if (!pt_cfstr_to_cstr((CFStringRef)item, dbuf, sizeof(dbuf), &dstr) || dstr == NULL) {
            continue;
        }
        BOOL keep = (strcmp(dstr, "Apple Global Domain") == 0 ||
                     strcmp(dstr, "NSGlobalDomain") == 0 ||
                     (mainBidBuf[0] != '\0' && strcmp(dstr, mainBidBuf) == 0));
        if (keep) {
            CFArrayAppendValue(out, item);
        }
    }
    CFRelease(list);
    return out;
}
#pragma clang diagnostic pop

__attribute__((visibility("hidden"))) NSDictionary *pt_build_sanitized_info_dict(NSDictionary *dict) {
    NSMutableDictionary *m = pt_build_sanitized_mutable_info_dict(dict);
    if (m == nil) {
        return nil;
    }
    if ([m[@"CFBundleSupportedPlatforms"] isKindOfClass:[NSMutableArray class]]) {
        m[@"CFBundleSupportedPlatforms"] = [m[@"CFBundleSupportedPlatforms"] copy];
    }
    return [m copy];
}

static CFDictionaryRef pt_sanitize_info_dict_copy(CFDictionaryRef infoDict, const void *caller) {
    if (infoDict == NULL) {
        return NULL;
    }
    if (!pt_is_bypass_enabled() || pt_is_effective_system_or_playtools_caller(caller)) {
        return infoDict;
    }
    NSDictionary *dict = (__bridge NSDictionary *)infoDict;
    if (!pt_info_dict_needs_sanitize(dict)) {
        return infoDict;
    }
    NSDictionary *clean = [dict isKindOfClass:[NSMutableDictionary class]]
        ? pt_build_sanitized_mutable_info_dict(dict)
        : pt_build_sanitized_info_dict(dict);
    if (clean != nil) {
        CFRelease(infoDict);
        return (__bridge_retained CFDictionaryRef)clean;
    }
    return infoDict;
}

static os_unfair_lock s_bundle_info_cache_lock = OS_UNFAIR_LOCK_INIT;
static CFMutableDictionaryRef s_bundle_info_cache = NULL;

static CFDictionaryRef pt_sanitize_info_dict_cached_get(CFDictionaryRef rawDict, const void *caller) {
    if (rawDict == NULL) {
        return NULL;
    }
    if (!pt_is_bypass_enabled() || pt_is_effective_system_or_playtools_caller(caller)) {
        return rawDict;
    }
    NSDictionary *dict = (__bridge NSDictionary *)rawDict;
    if (!pt_info_dict_needs_sanitize(dict)) {
        return rawDict;
    }
    os_unfair_lock_lock(&s_bundle_info_cache_lock);
    if (s_bundle_info_cache == NULL) {
        static const CFDictionaryKeyCallBacks kPtrRetainKeyCallBacks = {
            0,
            NULL,
            NULL,
            NULL,
            NULL,
            NULL
        };
        CFDictionaryKeyCallBacks keyCB = kPtrRetainKeyCallBacks;
        keyCB.retain = kCFTypeDictionaryKeyCallBacks.retain;
        keyCB.release = kCFTypeDictionaryKeyCallBacks.release;
        keyCB.copyDescription = kCFTypeDictionaryKeyCallBacks.copyDescription;
        s_bundle_info_cache = CFDictionaryCreateMutable(
            kCFAllocatorDefault, 0, &keyCB, &kCFTypeDictionaryValueCallBacks);
    }
    CFDictionaryRef cached = (s_bundle_info_cache != NULL)
        ? (CFDictionaryRef)CFDictionaryGetValue(s_bundle_info_cache, rawDict)
        : NULL;
    os_unfair_lock_unlock(&s_bundle_info_cache_lock);
    if (cached != NULL) {
        return cached;
    }
    NSDictionary *clean = [dict isKindOfClass:[NSMutableDictionary class]]
        ? pt_build_sanitized_mutable_info_dict(dict)
        : pt_build_sanitized_info_dict(dict);
    if (clean == nil) {
        return rawDict;
    }
    CFDictionaryRef cleanRef = (__bridge CFDictionaryRef)clean;
    os_unfair_lock_lock(&s_bundle_info_cache_lock);
    if (s_bundle_info_cache != NULL) {
        CFDictionaryRef race = (CFDictionaryRef)CFDictionaryGetValue(s_bundle_info_cache, rawDict);
        if (race != NULL) {
            os_unfair_lock_unlock(&s_bundle_info_cache_lock);
            return race;
        }
        if (CFDictionaryGetCount(s_bundle_info_cache) < 2048) {
            CFDictionarySetValue(s_bundle_info_cache, rawDict, cleanRef);
            CFDictionaryRef kept = (CFDictionaryRef)CFDictionaryGetValue(s_bundle_info_cache, rawDict);
            os_unfair_lock_unlock(&s_bundle_info_cache_lock);
            return kept;
        }
    }
    os_unfair_lock_unlock(&s_bundle_info_cache_lock);
    // Keep clean alive for the current autorelease pool instead of failing open or evicting live entries.
    (void)[clean self];
    return cleanRef;
}

static CFBundleRef pt_CFBundleCreate(CFAllocatorRef allocator, CFURLRef bundleURL) {
    const void *caller = __builtin_return_address(0);
    BOOL blocked = NO;
    CFURLRef resolvedURL = pt_resolve_cfbundle_input_url(bundleURL, caller, &blocked);
    if (blocked) {
        return NULL;
    }
    CFBundleRef bundle = CFBundleCreate(allocator, resolvedURL != NULL ? resolvedURL : bundleURL);
    if (resolvedURL != NULL) {
        CFRelease(resolvedURL);
    }
    if (bundle != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller) &&
        pt_bundle_is_hidden(bundle, caller)) {
        CFRelease(bundle);
        return NULL;
    }
    return bundle;
}

static CFURLRef pt_CFBundleCopyBundleURL(CFBundleRef bundle) {
    return pt_sanitize_cfbundle_returned_url(CFBundleCopyBundleURL(bundle),
                                             __builtin_return_address(0));
}

static CFURLRef pt_CFBundleCopyResourcesDirectoryURL(CFBundleRef bundle) {
    return pt_sanitize_cfbundle_returned_url(CFBundleCopyResourcesDirectoryURL(bundle),
                                             __builtin_return_address(0));
}

static CFURLRef pt_CFBundleCopyExecutableURL(CFBundleRef bundle) {
    return pt_sanitize_cfbundle_returned_url(CFBundleCopyExecutableURL(bundle),
                                             __builtin_return_address(0));
}

static CFURLRef pt_copy_virtual_mobileprovision_cfurl_if_applicable(CFBundleRef bundle,
                                                                   CFStringRef resourceName,
                                                                   CFStringRef resourceType,
                                                                   CFStringRef subDirName,
                                                                   const void *caller) CF_RETURNS_RETAINED {
    if (bundle == NULL || bundle != CFBundleGetMainBundle() || resourceName == NULL) {
        return NULL;
    }
    if (subDirName != NULL && CFStringGetLength(subDirName) > 0) {
        return NULL;
    }
    NSString *nameStr = (__bridge NSString *)resourceName;
    NSString *typeStr = (__bridge NSString *)resourceType;
    BOOL matches = NO;
    if ([nameStr isEqualToString:@"embedded"]) {
        matches = (typeStr != nil &&
                   ([typeStr isEqualToString:@"mobileprovision"] ||
                    [typeStr isEqualToString:@".mobileprovision"]));
    } else if ([nameStr isEqualToString:@"embedded.mobileprovision"]) {
        matches = (typeStr == nil || typeStr.length == 0);
    }
    if (!matches || !pt_is_bypass_enabled() || pt_is_effective_system_or_playtools_caller(caller)) {
        return NULL;
    }
    if (!pt_has_backup_mobileprovision()) {
        return NULL;
    }
    char vbuf[PATH_MAX];
    const char *vpath = pt_copy_virtual_mobileprovision_path(vbuf, sizeof(vbuf));
    if (vpath == NULL || vpath[0] == '\0') {
        return NULL;
    }
    return CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, (const UInt8 *)vpath, (CFIndex)strlen(vpath), false);
}

static CFURLRef pt_CFBundleCopyResourceURL(CFBundleRef bundle,
                                           CFStringRef resourceName,
                                           CFStringRef resourceType,
                                           CFStringRef subDirName) {
    const void *caller = __builtin_return_address(0);
    CFURLRef out = CFBundleCopyResourceURL(bundle, resourceName, resourceType, subDirName);
    if (out == NULL) {
        return pt_copy_virtual_mobileprovision_cfurl_if_applicable(
            bundle, resourceName, resourceType, subDirName, caller);
    }
    return pt_sanitize_cfbundle_returned_url(out, caller);
}

static CFArrayRef pt_CFBundleCopyResourceURLsOfType(CFBundleRef bundle,
                                                   CFStringRef resourceType,
                                                   CFStringRef subDirName) {
    return pt_sanitize_cfbundle_returned_url_array(
        CFBundleCopyResourceURLsOfType(bundle, resourceType, subDirName),
        __builtin_return_address(0));
}

static CFURLRef pt_CFBundleCopyResourceURLInDirectory(CFURLRef bundleURL,
                                                      CFStringRef resourceName,
                                                      CFStringRef resourceType,
                                                      CFStringRef subDirName) {
    const void *caller = __builtin_return_address(0);
    BOOL blocked = NO;
    CFURLRef resolvedURL = pt_resolve_cfbundle_input_url(bundleURL, caller, &blocked);
    if (blocked) {
        return NULL;
    }
    CFURLRef out = CFBundleCopyResourceURLInDirectory(resolvedURL != NULL ? resolvedURL : bundleURL,
                                                      resourceName, resourceType, subDirName);
    if (resolvedURL != NULL) {
        CFRelease(resolvedURL);
    }
    return pt_sanitize_cfbundle_returned_url(out, caller);
}

static CFArrayRef pt_CFBundleCopyResourceURLsOfTypeInDirectory(CFURLRef bundleURL,
                                                              CFStringRef resourceType,
                                                              CFStringRef subDirName) {
    const void *caller = __builtin_return_address(0);
    BOOL blocked = NO;
    CFURLRef resolvedURL = pt_resolve_cfbundle_input_url(bundleURL, caller, &blocked);
    if (blocked) {
        return NULL;
    }
    CFArrayRef out = CFBundleCopyResourceURLsOfTypeInDirectory(resolvedURL != NULL ? resolvedURL : bundleURL,
                                                               resourceType, subDirName);
    if (resolvedURL != NULL) {
        CFRelease(resolvedURL);
    }
    return pt_sanitize_cfbundle_returned_url_array(out, caller);
}

static CFURLRef pt_CFBundleCopyResourceURLForLocalization(CFBundleRef bundle,
                                                          CFStringRef resourceName,
                                                          CFStringRef resourceType,
                                                          CFStringRef subDirName,
                                                          CFStringRef localizationName) {
    const void *caller = __builtin_return_address(0);
    CFURLRef out = CFBundleCopyResourceURLForLocalization(
        bundle, resourceName, resourceType, subDirName, localizationName);
    if (out == NULL) {
        return pt_copy_virtual_mobileprovision_cfurl_if_applicable(
            bundle, resourceName, resourceType, subDirName, caller);
    }
    return pt_sanitize_cfbundle_returned_url(out, caller);
}

static CFArrayRef pt_CFBundleCopyResourceURLsOfTypeForLocalization(CFBundleRef bundle,
                                                                  CFStringRef resourceType,
                                                                  CFStringRef subDirName,
                                                                  CFStringRef localizationName) {
    return pt_sanitize_cfbundle_returned_url_array(
        CFBundleCopyResourceURLsOfTypeForLocalization(bundle, resourceType, subDirName, localizationName),
        __builtin_return_address(0));
}

static CFURLRef pt_CFBundleCopyAuxiliaryExecutableURL(CFBundleRef bundle, CFStringRef executableName) {
    return pt_sanitize_cfbundle_returned_url(
        CFBundleCopyAuxiliaryExecutableURL(bundle, executableName),
        __builtin_return_address(0));
}

static CFURLRef pt_CFBundleCopyBuiltInPlugInsURL(CFBundleRef bundle) {
    return pt_sanitize_cfbundle_returned_url(
        CFBundleCopyBuiltInPlugInsURL(bundle),
        __builtin_return_address(0));
}

static CFURLRef pt_CFBundleCopySharedFrameworksURL(CFBundleRef bundle) {
    return pt_sanitize_cfbundle_returned_url(
        CFBundleCopySharedFrameworksURL(bundle),
        __builtin_return_address(0));
}

static CFURLRef pt_CFBundleCopyPrivateFrameworksURL(CFBundleRef bundle) {
    return pt_sanitize_cfbundle_returned_url(
        CFBundleCopyPrivateFrameworksURL(bundle),
        __builtin_return_address(0));
}

static CFURLRef pt_CFBundleCopySharedSupportURL(CFBundleRef bundle) {
    return pt_sanitize_cfbundle_returned_url(
        CFBundleCopySharedSupportURL(bundle),
        __builtin_return_address(0));
}

static CFURLRef pt_CFBundleCopySupportFilesDirectoryURL(CFBundleRef bundle) {
    return pt_sanitize_cfbundle_returned_url(
        CFBundleCopySupportFilesDirectoryURL(bundle),
        __builtin_return_address(0));
}

static CFDictionaryRef pt_CFBundleCopyInfoDictionaryForURL(CFURLRef url) {
    const void *caller = __builtin_return_address(0);
    BOOL blocked = NO;
    CFURLRef resolvedURL = pt_resolve_cfbundle_input_url(url, caller, &blocked);
    if (blocked) {
        return NULL;
    }
    CFDictionaryRef dict = CFBundleCopyInfoDictionaryForURL(resolvedURL != NULL ? resolvedURL : url);
    if (resolvedURL != NULL) {
        CFRelease(resolvedURL);
    }
    return pt_sanitize_info_dict_copy(dict, caller);
}

static CFDictionaryRef pt_CFBundleCopyInfoDictionaryInDirectory(CFURLRef bundleURL) {
    const void *caller = __builtin_return_address(0);
    BOOL blocked = NO;
    CFURLRef resolvedURL = pt_resolve_cfbundle_input_url(bundleURL, caller, &blocked);
    if (blocked) {
        return NULL;
    }
    CFDictionaryRef dict = CFBundleCopyInfoDictionaryInDirectory(resolvedURL != NULL ? resolvedURL : bundleURL);
    if (resolvedURL != NULL) {
        CFRelease(resolvedURL);
    }
    return pt_sanitize_info_dict_copy(dict, caller);
}

static CFDictionaryRef pt_CFBundleGetInfoDictionary(CFBundleRef bundle) {
    return pt_sanitize_info_dict_cached_get(
        CFBundleGetInfoDictionary(bundle),
        __builtin_return_address(0));
}

static CFDictionaryRef pt_CFBundleGetLocalInfoDictionary(CFBundleRef bundle) {
    return pt_sanitize_info_dict_cached_get(
        CFBundleGetLocalInfoDictionary(bundle),
        __builtin_return_address(0));
}

static CFTypeRef pt_CFBundleGetValueForInfoDictionaryKey(CFBundleRef bundle, CFStringRef key) {
    const void *caller = __builtin_return_address(0);
    if (bundle != NULL && key != NULL && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        CFDictionaryRef rawLocal = CFBundleGetLocalInfoDictionary(bundle);
        CFDictionaryRef localSanitized = pt_sanitize_info_dict_cached_get(rawLocal, caller);
        if (localSanitized != NULL && CFDictionaryContainsKey(localSanitized, key)) {
            return CFDictionaryGetValue(localSanitized, key);
        }
        if (rawLocal != NULL && CFDictionaryContainsKey(rawLocal, key)) {
            return NULL;
        }
        CFDictionaryRef rawMain = CFBundleGetInfoDictionary(bundle);
        CFDictionaryRef mainSanitized = pt_sanitize_info_dict_cached_get(rawMain, caller);
        if (mainSanitized != NULL && CFDictionaryContainsKey(mainSanitized, key)) {
            return CFDictionaryGetValue(mainSanitized, key);
        }
        if (rawMain != NULL && CFDictionaryContainsKey(rawMain, key)) {
            return NULL;
        }
    }
    return CFBundleGetValueForInfoDictionaryKey(bundle, key);
}

static CFBundleRef pt_CFBundleGetBundleWithIdentifier(CFStringRef bundleID) {
    const void *caller = __builtin_return_address(0);
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
        if (pt_is_hidden_bundle_identifier(bundleID)) {
            return NULL;
        }
    }
    CFBundleRef b = CFBundleGetBundleWithIdentifier(bundleID);
    if (b != NULL && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller) &&
        pt_bundle_is_hidden(b, caller)) {
        return NULL;
    }
    return b;
}

#define PT_RETIRED_ALL_BUNDLES_SLOTS 32
static os_unfair_lock s_all_bundles_lock = OS_UNFAIR_LOCK_INIT;
static CFArrayRef s_cached_all_bundles_raw = NULL;
static CFIndex s_cached_all_bundles_raw_count = -1;
static CFArrayRef s_cached_all_bundles_filtered = NULL;
static CFArrayRef s_retired_all_bundles[PT_RETIRED_ALL_BUNDLES_SLOTS] = {0};
static size_t s_retired_all_bundles_idx = 0;

static CFArrayRef pt_CFBundleGetAllBundles(void) {
    CFArrayRef raw = CFBundleGetAllBundles();
    const void *caller = __builtin_return_address(0);
    if (raw == NULL || !pt_is_bypass_enabled() || pt_is_effective_system_or_playtools_caller(caller)) {
        return raw;
    }
    CFIndex rawCount = CFArrayGetCount(raw);
    os_unfair_lock_lock(&s_all_bundles_lock);
    if (s_cached_all_bundles_filtered != NULL &&
        s_cached_all_bundles_raw == raw &&
        s_cached_all_bundles_raw_count == rawCount) {
        CFArrayRef res = s_cached_all_bundles_filtered;
        os_unfair_lock_unlock(&s_all_bundles_lock);
        return res;
    }
    os_unfair_lock_unlock(&s_all_bundles_lock);

    CFMutableArrayRef filtered = CFArrayCreateMutable(kCFAllocatorDefault, rawCount, &kCFTypeArrayCallBacks);
    if (filtered == NULL) {
        return raw;
    }
    for (CFIndex i = 0; i < rawCount; i++) {
        CFBundleRef b = (CFBundleRef)CFArrayGetValueAtIndex(raw, i);
        if (b != NULL && !pt_bundle_is_hidden(b, caller)) {
            CFArrayAppendValue(filtered, b);
        }
    }
    CFArrayRef immutable = CFArrayCreateCopy(kCFAllocatorDefault, filtered);
    CFRelease(filtered);
    if (immutable == NULL) {
        return raw;
    }
    os_unfair_lock_lock(&s_all_bundles_lock);
    if (s_cached_all_bundles_filtered != NULL) {
        if (s_retired_all_bundles[s_retired_all_bundles_idx] != NULL) {
            CFRelease(s_retired_all_bundles[s_retired_all_bundles_idx]);
        }
        s_retired_all_bundles[s_retired_all_bundles_idx] = s_cached_all_bundles_filtered;
        s_retired_all_bundles_idx = (s_retired_all_bundles_idx + 1U) % PT_RETIRED_ALL_BUNDLES_SLOTS;
    }
    s_cached_all_bundles_filtered = immutable;
    s_cached_all_bundles_raw = raw;
    s_cached_all_bundles_raw_count = rawCount;
    os_unfair_lock_unlock(&s_all_bundles_lock);
    return immutable;
}

static void *pt_cfbundle_filter_symbol_ptr(void *orig_ptr, CFStringRef symName) {
    if (orig_ptr == NULL || symName == NULL) {
        return orig_ptr;
    }
    char sbuf[256];
    const char *sstr = NULL;
    if (!pt_cfstr_to_cstr(symName, sbuf, sizeof(sbuf), &sstr) || sstr == NULL) {
        return orig_ptr;
    }
    if (pt_is_hidden_macos_only_dlsym_symbol(sstr)) {
        return NULL;
    }
    void *routed = pt_route_dlsym_symbol_for_app(sstr);
    if (routed == PT_DLSYM_HIDDEN_SENTINEL) {
        return NULL;
    }
    return (routed != NULL) ? routed : orig_ptr;
}

static void *pt_CFBundleGetFunctionPointerForName(CFBundleRef bundle, CFStringRef functionName) {
    const void *caller = __builtin_return_address(0);
    BOOL app_caller = (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller));
    if (app_caller) {
        if (pt_bundle_is_hidden(bundle, caller)) {
            return NULL;
        }
        char sbuf[256];
        const char *sstr = NULL;
        if (functionName != NULL && pt_cfstr_to_cstr(functionName, sbuf, sizeof(sbuf), &sstr) &&
            pt_is_hidden_macos_only_dlsym_symbol(sstr)) {
            return NULL;
        }
    }
    void *ptr = CFBundleGetFunctionPointerForName(bundle, functionName);
    if (app_caller && ptr != NULL) {
        return pt_cfbundle_filter_symbol_ptr(ptr, functionName);
    }
    return ptr;
}

static void pt_CFBundleGetFunctionPointersForNames(CFBundleRef bundle, CFArrayRef functionNames, void *ftbl[]) {
    const void *caller = __builtin_return_address(0);
    BOOL app_caller = (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller));
    CFIndex count = (functionNames != NULL) ? CFArrayGetCount(functionNames) : 0;
    if (app_caller && pt_bundle_is_hidden(bundle, caller)) {
        if (ftbl != NULL && count > 0) {
            memset(ftbl, 0, (size_t)count * sizeof(void *));
        }
        return;
    }
    CFBundleGetFunctionPointersForNames(bundle, functionNames, ftbl);
    if (app_caller && ftbl != NULL && functionNames != NULL && count > 0) {
        for (CFIndex i = 0; i < count; i++) {
            CFTypeRef item = CFArrayGetValueAtIndex(functionNames, i);
            if (item != NULL && CFGetTypeID(item) == CFStringGetTypeID()) {
                ftbl[i] = pt_cfbundle_filter_symbol_ptr(ftbl[i], (CFStringRef)item);
            }
        }
    }
}

static void *pt_CFBundleGetDataPointerForName(CFBundleRef bundle, CFStringRef symbolName) {
    const void *caller = __builtin_return_address(0);
    BOOL app_caller = (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller));
    if (app_caller) {
        if (pt_bundle_is_hidden(bundle, caller)) {
            return NULL;
        }
        char sbuf[256];
        const char *sstr = NULL;
        if (symbolName != NULL && pt_cfstr_to_cstr(symbolName, sbuf, sizeof(sbuf), &sstr) &&
            pt_is_hidden_macos_only_dlsym_symbol(sstr)) {
            return NULL;
        }
    }
    void *ptr = CFBundleGetDataPointerForName(bundle, symbolName);
    if (app_caller && ptr != NULL) {
        return pt_cfbundle_filter_symbol_ptr(ptr, symbolName);
    }
    return ptr;
}

static void pt_CFBundleGetDataPointersForNames(CFBundleRef bundle, CFArrayRef symbolNames, void *stbl[]) {
    const void *caller = __builtin_return_address(0);
    BOOL app_caller = (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller));
    CFIndex count = (symbolNames != NULL) ? CFArrayGetCount(symbolNames) : 0;
    if (app_caller && pt_bundle_is_hidden(bundle, caller)) {
        if (stbl != NULL && count > 0) {
            memset(stbl, 0, (size_t)count * sizeof(void *));
        }
        return;
    }
    CFBundleGetDataPointersForNames(bundle, symbolNames, stbl);
    if (app_caller && stbl != NULL && symbolNames != NULL && count > 0) {
        for (CFIndex i = 0; i < count; i++) {
            CFTypeRef item = CFArrayGetValueAtIndex(symbolNames, i);
            if (item != NULL && CFGetTypeID(item) == CFStringGetTypeID()) {
                stbl[i] = pt_cfbundle_filter_symbol_ptr(stbl[i], (CFStringRef)item);
            }
        }
    }
}

static CFArrayRef pt_filter_executable_architectures_array(CFArrayRef CF_CONSUMED archs) CF_RETURNS_RETAINED {
    if (archs == NULL) {
        return NULL;
    }
    CFIndex n = CFArrayGetCount(archs);
    CFMutableArrayRef out = NULL;
    for (CFIndex i = 0; i < n; i++) {
        CFTypeRef item = CFArrayGetValueAtIndex(archs, i);
        BOOL drop = NO;
        if (item != NULL && CFGetTypeID(item) == CFNumberGetTypeID()) {
            SInt32 arch = 0;
            if (CFNumberGetValue((CFNumberRef)item, kCFNumberSInt32Type, &arch) &&
                (arch == 0x01000007 || arch == 0x00000007)) {
                drop = YES;
            }
        }
        if (drop && out == NULL) {
            out = CFArrayCreateMutable(kCFAllocatorDefault, n, &kCFTypeArrayCallBacks);
            if (out != NULL) {
                for (CFIndex j = 0; j < i; j++) {
                    CFArrayAppendValue(out, CFArrayGetValueAtIndex(archs, j));
                }
            }
        } else if (out != NULL && !drop) {
            CFArrayAppendValue(out, item);
        }
    }
    if (out != NULL) {
        CFRelease(archs);
        return out;
    }
    return archs;
}

static CFArrayRef pt_CFBundleCopyExecutableArchitectures(CFBundleRef bundle) CF_RETURNS_RETAINED {
    const void *caller = __builtin_return_address(0);
    BOOL app_caller = (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller));
    if (app_caller && pt_bundle_is_hidden(bundle, caller)) {
        return NULL;
    }
    CFArrayRef archs = CFBundleCopyExecutableArchitectures(bundle);
    if (app_caller && archs != NULL) {
        return pt_filter_executable_architectures_array(archs);
    }
    return archs;
}

static CFArrayRef pt_CFBundleCopyExecutableArchitecturesForURL(CFURLRef url) CF_RETURNS_RETAINED {
    const void *caller = __builtin_return_address(0);
    BOOL app_caller = (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller));
    BOOL blocked = NO;
    CFURLRef resolved = pt_resolve_cfbundle_input_url(url, caller, &blocked);
    if (blocked) {
        if (resolved != NULL) {
            CFRelease(resolved);
        }
        return NULL;
    }
    CFArrayRef archs = CFBundleCopyExecutableArchitecturesForURL(resolved != NULL ? resolved : url);
    if (resolved != NULL) {
        CFRelease(resolved);
    }
    if (app_caller && archs != NULL) {
        return pt_filter_executable_architectures_array(archs);
    }
    return archs;
}

static CFArrayRef pt_CFBundleCreateBundlesFromDirectory(CFAllocatorRef allocator,
                                                       CFURLRef directoryURL,
                                                       CFStringRef bundleType) CF_RETURNS_RETAINED {
    const void *caller = __builtin_return_address(0);
    BOOL app_caller = (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller));
    BOOL blocked = NO;
    CFURLRef resolved = pt_resolve_cfbundle_input_url(directoryURL, caller, &blocked);
    if (blocked) {
        if (resolved != NULL) {
            CFRelease(resolved);
        }
        return CFArrayCreate(allocator, NULL, 0, &kCFTypeArrayCallBacks);
    }
    CFArrayRef arr = CFBundleCreateBundlesFromDirectory(allocator, resolved != NULL ? resolved : directoryURL, bundleType);
    if (resolved != NULL) {
        CFRelease(resolved);
    }
    if (!app_caller || arr == NULL) {
        return arr;
    }
    CFIndex n = CFArrayGetCount(arr);
    CFMutableArrayRef out = NULL;
    for (CFIndex i = 0; i < n; i++) {
        CFBundleRef b = (CFBundleRef)CFArrayGetValueAtIndex(arr, i);
        BOOL hide = (b != NULL && pt_bundle_is_hidden(b, caller));
        if (hide && out == NULL) {
            out = CFArrayCreateMutable(allocator, n, &kCFTypeArrayCallBacks);
            if (out != NULL) {
                for (CFIndex j = 0; j < i; j++) {
                    CFArrayAppendValue(out, CFArrayGetValueAtIndex(arr, j));
                }
            }
        } else if (out != NULL && !hide) {
            CFArrayAppendValue(out, b);
        }
    }
    if (out != NULL) {
        CFRelease(arr);
        return out;
    }
    return arr;
}


static void *pt_dlsym_resolve_environ(void) {
    return (void *)pt_get_app_shadow_environ_ptr();
}

PT_DLSYM_DYNAMIC("environ", pt_dlsym_resolve_environ)
PT_INTERPOSE(pt_getenv, getenv)
PT_INTERPOSE(pt_NSGetEnviron, _NSGetEnviron)
PT_INTERPOSE(pt_NSGetArgv, _NSGetArgv)
PT_INTERPOSE(pt_NSGetArgc, _NSGetArgc)
PT_INTERPOSE(pt_NSGetProgname, _NSGetProgname)
PT_INTERPOSE(pt_getprogname, getprogname)
PT_INTERPOSE(pt_CFCopyHomeDirectoryURL, CFCopyHomeDirectoryURL)
PT_INTERPOSE(pt_CFCopyHomeDirectoryURLForUser, CFCopyHomeDirectoryURLForUser)
PT_INTERPOSE(pt_CFCopyUserName, CFCopyUserName)
PT_INTERPOSE(pt_NSHomeDirectory, NSHomeDirectory)
PT_INTERPOSE(pt_NSHomeDirectoryForUser, NSHomeDirectoryForUser)
PT_INTERPOSE(pt_NSTemporaryDirectory, NSTemporaryDirectory)
PT_INTERPOSE(pt_NSSearchPathForDirectoriesInDomains, NSSearchPathForDirectoriesInDomains)
PT_INTERPOSE(pt_CFBundleCreate, CFBundleCreate)
PT_INTERPOSE(pt_CFBundleCopyBundleURL, CFBundleCopyBundleURL)
PT_INTERPOSE(pt_CFBundleCopyResourcesDirectoryURL, CFBundleCopyResourcesDirectoryURL)
PT_INTERPOSE(pt_CFBundleCopyExecutableURL, CFBundleCopyExecutableURL)
PT_INTERPOSE(pt_CFBundleCopyResourceURL, CFBundleCopyResourceURL)
PT_INTERPOSE(pt_CFBundleCopyResourceURLsOfType, CFBundleCopyResourceURLsOfType)
PT_INTERPOSE(pt_CFBundleCopyResourceURLInDirectory, CFBundleCopyResourceURLInDirectory)
PT_INTERPOSE(pt_CFBundleCopyResourceURLsOfTypeInDirectory, CFBundleCopyResourceURLsOfTypeInDirectory)
PT_INTERPOSE(pt_CFBundleCopyResourceURLForLocalization, CFBundleCopyResourceURLForLocalization)
PT_INTERPOSE(pt_CFBundleCopyResourceURLsOfTypeForLocalization, CFBundleCopyResourceURLsOfTypeForLocalization)
PT_INTERPOSE(pt_CFBundleCopyAuxiliaryExecutableURL, CFBundleCopyAuxiliaryExecutableURL)
PT_INTERPOSE(pt_CFBundleCopyBuiltInPlugInsURL, CFBundleCopyBuiltInPlugInsURL)
PT_INTERPOSE(pt_CFBundleCopySharedFrameworksURL, CFBundleCopySharedFrameworksURL)
PT_INTERPOSE(pt_CFBundleCopyPrivateFrameworksURL, CFBundleCopyPrivateFrameworksURL)
PT_INTERPOSE(pt_CFBundleCopySharedSupportURL, CFBundleCopySharedSupportURL)
PT_INTERPOSE(pt_CFBundleCopySupportFilesDirectoryURL, CFBundleCopySupportFilesDirectoryURL)
PT_INTERPOSE(pt_CFBundleCopyInfoDictionaryForURL, CFBundleCopyInfoDictionaryForURL)
PT_INTERPOSE(pt_CFBundleCopyInfoDictionaryInDirectory, CFBundleCopyInfoDictionaryInDirectory)
PT_INTERPOSE(pt_CFBundleGetInfoDictionary, CFBundleGetInfoDictionary)
PT_INTERPOSE(pt_CFBundleGetLocalInfoDictionary, CFBundleGetLocalInfoDictionary)
PT_INTERPOSE(pt_CFBundleGetValueForInfoDictionaryKey, CFBundleGetValueForInfoDictionaryKey)
PT_INTERPOSE(pt_CFBundleGetBundleWithIdentifier, CFBundleGetBundleWithIdentifier)
PT_INTERPOSE(pt_CFBundleGetAllBundles, CFBundleGetAllBundles)
PT_INTERPOSE(pt_CFPreferencesCopyAppValue, CFPreferencesCopyAppValue)
PT_INTERPOSE(pt_CFPreferencesCopyMultiple, CFPreferencesCopyMultiple)
PT_INTERPOSE(pt_CFPreferencesCopyValue, CFPreferencesCopyValue)
PT_INTERPOSE(pt_CFPreferencesCopyKeyList, CFPreferencesCopyKeyList)
PT_INTERPOSE(pt_CFPreferencesGetAppBooleanValue, CFPreferencesGetAppBooleanValue)
PT_INTERPOSE(pt_CFPreferencesGetAppIntegerValue, CFPreferencesGetAppIntegerValue)
PT_INTERPOSE(pt_CFPreferencesAppValueIsForced, CFPreferencesAppValueIsForced)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
PT_INTERPOSE(pt_CFPreferencesCopyApplicationList, CFPreferencesCopyApplicationList)
#pragma clang diagnostic pop
PT_INTERPOSE(pt_CFBundleGetFunctionPointerForName, CFBundleGetFunctionPointerForName)
PT_INTERPOSE(pt_CFBundleGetFunctionPointersForNames, CFBundleGetFunctionPointersForNames)
PT_INTERPOSE(pt_CFBundleGetDataPointerForName, CFBundleGetDataPointerForName)
PT_INTERPOSE(pt_CFBundleGetDataPointersForNames, CFBundleGetDataPointersForNames)
PT_INTERPOSE(pt_CFBundleCopyExecutableArchitectures, CFBundleCopyExecutableArchitectures)
PT_INTERPOSE(pt_CFBundleCopyExecutableArchitecturesForURL, CFBundleCopyExecutableArchitecturesForURL)
PT_INTERPOSE(pt_CFBundleCreateBundlesFromDirectory, CFBundleCreateBundlesFromDirectory)
