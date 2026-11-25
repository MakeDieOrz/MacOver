//
//  PTFSVirtualizer.m
//  PlayTools
//

#import "PTFSInternal.h"
#import "PTSystemSpooferInternal.h"
#import "PTDyldInternal.h"
#if __has_include(<sys/fsgetpath.h>)
#include <sys/fsgetpath.h>
#endif
#if __has_include(<sys/unistd.h>)
#include <sys/unistd.h>
#endif

extern const char *dyld_image_path_containing_address(const void *addr);
extern const struct mach_header *dyld_image_header_containing_address(const void *addr);

// Lock-free BSS caller-address cache (safe during dyld/libSystem bootstrap before TLV/malloc init).
// ARM64 instructions are 4-byte aligned ((addr & 3) == 0); bits [1:0] store (kind - 1), entry 0 = empty.
static _Atomic uint64_t s_caller_addr_cache[PT_CALLER_ADDR_CACHE_SIZE];
static _Atomic(const struct mach_header *) s_playtools_self_mh = NULL;

static inline const struct mach_header *pt_get_self_playtools_mh(void) {
    const struct mach_header *mh = atomic_load_explicit(&s_playtools_self_mh, memory_order_acquire);
    if (mh == NULL) {
        mh = dyld_image_header_containing_address((const void *)&pt_is_system_or_playtools_caller);
        if (mh != NULL) {
            atomic_store_explicit(&s_playtools_self_mh, mh, memory_order_release);
        }
    }
    return mh;
}

static inline uint8_t pt_classify_caller_addr(const void *ret_addr) {
    if (ret_addr == NULL) {
        return PT_CALLER_SYS_NON_WRAPPER;
    }
    uint64_t key = (uint64_t)(uintptr_t)ret_addr;
    size_t slot = pt_caller_addr_cache_slot(key);
    if (__builtin_expect(pt_caller_addr_is_cacheable_aligned(key), 1)) {
        uint64_t entry = atomic_load_explicit(&s_caller_addr_cache[slot], memory_order_relaxed);
        uint8_t cached_kind = PT_CALLER_UNKNOWN;
        if (pt_caller_addr_cache_match(entry, key, &cached_kind)) {
            return cached_kind;
        }
    }

    const char *fname = dyld_image_path_containing_address(ret_addr);
    if (fname == NULL) {
        return PT_CALLER_APP;
    }

    bool cacheable = false;
    uint8_t kind = pt_classify_caller_image_path(fname, &cacheable);
    if (kind == PT_CALLER_APP) {
        const struct mach_header *self_mh = pt_get_self_playtools_mh();
        if (self_mh != NULL && dyld_image_header_containing_address(ret_addr) == self_mh) {
            kind = PT_CALLER_PLAYTOOLS;
            cacheable = true;
        }
    }

    if (cacheable) {
        uint64_t packed = 0ULL;
        if (pt_caller_addr_try_pack(key, kind, &packed)) {
            atomic_store_explicit(&s_caller_addr_cache[slot], packed, memory_order_relaxed);
        }
    }
    return kind;
}

__attribute__((visibility("hidden")))
BOOL pt_is_system_or_playtools_caller(const void *ret_addr) {
    return pt_classify_caller_addr(ret_addr) != PT_CALLER_APP;
}

static _Thread_local BOOL s_tls_in_callstack = NO;
static _Thread_local uintptr_t s_tls_stack_bot = 0;
static _Thread_local uintptr_t s_tls_stack_top = 0;

static _Atomic uint64_t s_wrapper_context_cache[PT_WRAPPER_CACHE_SIZE];

static BOOL pt_inspect_backtrace_frames(BOOL seen_wrapper) {
    void *addrs[PT_MAX_CALLER_UNWIND_DEPTH + 10];
    int count = backtrace(addrs, PT_MAX_CALLER_UNWIND_DEPTH + 10);
    int caller_depth = 0;
    for (int i = 1; i < count; i++) {
        uint8_t fkind = pt_classify_caller_addr(pt_strip_return_addr((uintptr_t)addrs[i]));
        if (fkind == PT_CALLER_PLAYTOOLS) {
            if (!seen_wrapper) {
                continue;
            }
            return YES;
        }
        if (fkind == PT_CALLER_SYS_WRAPPER) {
            seen_wrapper = YES;
            caller_depth++;
            if (caller_depth >= PT_MAX_CALLER_UNWIND_DEPTH) {
                return YES;
            }
            continue;
        }
        return (fkind != PT_CALLER_APP);
    }
    return YES;
}

__attribute__((visibility("hidden")))
BOOL pt_is_effective_system_or_playtools_caller(const void *ret_addr) {
    // Never touch _Thread_local storage (pt_is_in_internal_scope / s_tls_*)
    // before libSystem_initializer finishes dyld TLV bootstrap.
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return YES;
    }
    if (pt_is_in_internal_scope()) {
        return YES;
    }
    uint8_t kind = pt_classify_caller_addr(ret_addr);
    if (kind == PT_CALLER_APP) {
        return NO;
    }
    if (kind == PT_CALLER_PLAYTOOLS || kind == PT_CALLER_SYS_NON_WRAPPER) {
        return YES;
    }
    if (s_tls_in_callstack) {
        return YES;
    }
    s_tls_in_callstack = YES;
    BOOL result = YES;
    BOOL seen_wrapper = NO;
#if defined(__arm64__) || defined(__aarch64__)
    if (s_tls_stack_top == 0) {
        pthread_t self = pthread_self();
        uintptr_t stop = (uintptr_t)pthread_get_stackaddr_np(self);
        size_t ssize = pthread_get_stacksize_np(self);
        s_tls_stack_bot = (stop > ssize) ? (stop - ssize) : 0;
        s_tls_stack_top = stop;
    }
    uintptr_t stack_top = s_tls_stack_top;
    uintptr_t stack_bot = s_tls_stack_bot;
    uintptr_t fp = (uintptr_t)__builtin_frame_address(0);
    BOOL need_backtrace_fallback = NO;

    // Advance past internal PlayTools helper frames (without counting toward wrapper budget)
    // until reaching the first external/wrapper frame, then check the 3-frame cache
    // (populated only when the verdict resolves within the first 3 frames) and bound
    // unwinding to PT_MAX_CALLER_UNWIND_DEPTH frames.
    for (int hop = 0; hop < 32; hop++) {
        if (stack_top < 16 || fp < stack_bot || fp + 16 > stack_top || (fp & 0x7) != 0) {
            if (hop == 0) {
                need_backtrace_fallback = YES;
            }
            break;
        }
        uintptr_t next_fp = ((const uintptr_t *)fp)[0];
        const void *lr_addr = pt_strip_return_addr(((const uintptr_t *)fp)[1]);
        if (lr_addr == NULL) {
            break;
        }
        uint8_t fkind = pt_classify_caller_addr(lr_addr);
        if (fkind == PT_CALLER_PLAYTOOLS) {
            if (next_fp <= fp) {
                break;
            }
            fp = next_fp;
            continue;
        }

        // First external frame reached: collect up to 2 caller link registers for compound key.
        uintptr_t lr0 = (uintptr_t)lr_addr;
        uintptr_t fp1_lr = 0;
        uintptr_t fp2_lr = 0;
        if (next_fp > fp && stack_top >= 16 && next_fp >= stack_bot && next_fp + 16 <= stack_top && (next_fp & 0x7) == 0) {
            fp1_lr = (uintptr_t)pt_strip_return_addr(((const uintptr_t *)next_fp)[1]);
            uintptr_t fp2 = ((const uintptr_t *)next_fp)[0];
            if (fp2 > next_fp && fp2 >= stack_bot && fp2 + 16 <= stack_top && (fp2 & 0x7) == 0) {
                fp2_lr = (uintptr_t)pt_strip_return_addr(((const uintptr_t *)fp2)[1]);
            }
        }
        bool key_matches_ret = (lr0 == (uintptr_t)pt_strip_return_addr((uintptr_t)ret_addr));
        uint64_t compound_key = 0ULL;
        size_t wslot = 0;
        if (key_matches_ret) {
            compound_key = pt_caller_compound_key3(lr0, fp1_lr, fp2_lr);
            wslot = pt_wrapper_cache_slot(compound_key);
            uint64_t cached_entry = atomic_load_explicit(&s_wrapper_context_cache[wslot], memory_order_relaxed);
            bool cached_sys = false;
            if (pt_wrapper_cache_match(cached_entry, compound_key, &cached_sys)) {
                s_tls_in_callstack = NO;
                return cached_sys ? YES : NO;
            }
        }

        // Cache miss: perform bounded frame walk up to PT_MAX_CALLER_UNWIND_DEPTH.
        uint8_t frame_kinds[PT_MAX_CALLER_UNWIND_DEPTH];
        size_t collected = 0;
        uintptr_t walk_fp = fp;
        for (int depth = 0; depth < PT_MAX_CALLER_UNWIND_DEPTH; depth++) {
            uint8_t wkind;
            uintptr_t wnext;
            if (depth == 0) {
                wnext = next_fp;
                wkind = fkind;
            } else {
                if (stack_top < 16 || walk_fp < stack_bot || walk_fp + 16 > stack_top || (walk_fp & 0x7) != 0) {
                    break;
                }
                wnext = ((const uintptr_t *)walk_fp)[0];
                const void *wlr = pt_strip_return_addr(((const uintptr_t *)walk_fp)[1]);
                if (wlr == NULL) {
                    break;
                }
                wkind = pt_classify_caller_addr(wlr);
            }
            frame_kinds[collected++] = wkind;
            if (wkind != PT_CALLER_SYS_WRAPPER) {
                break;
            }
            if (wnext <= walk_fp) {
                break;
            }
            walk_fp = wnext;
        }
        bool cacheable_3frame = false;
        bool bounded_sys = pt_classify_bounded_frame_kinds_ex(frame_kinds, collected, true, &cacheable_3frame);
        result = bounded_sys ? YES : NO;
        // Only cache verdicts fully determined within the 3-frame key [0..2];
        // deeper chains must not poison the 3-frame slot for other origins.
        if (key_matches_ret && cacheable_3frame) {
            uint64_t packed = pt_wrapper_cache_pack(compound_key, bounded_sys);
            atomic_store_explicit(&s_wrapper_context_cache[wslot], packed, memory_order_relaxed);
        }
        break;
    }
    if (need_backtrace_fallback) {
        result = pt_inspect_backtrace_frames(seen_wrapper);
    }
#else
    result = pt_inspect_backtrace_frames(seen_wrapper);
#endif
    s_tls_in_callstack = NO;
    return result;
}

__attribute__((visibility("hidden"))) BOOL pt_needs_lexical_norm(const char *p) {
    if (p == NULL || p[0] != '/') {
        return NO;
    }
    const char *slash = p;
    while ((slash = strchr(slash, '/')) != NULL) {
        char next = slash[1];
        if (next == '/') {
            return YES;
        }
        if (next == '.' &&
            (slash[2] == '/' || slash[2] == '\0' ||
             (slash[2] == '.' && (slash[3] == '/' || slash[3] == '\0')))) {
            return YES;
        }
        slash++;
    }
    return NO;
}


__attribute__((visibility("hidden"))) char s_real_app_bundle_dir[PATH_MAX];
__attribute__((visibility("hidden"))) size_t s_real_app_bundle_len = 0;
static _Atomic bool s_bundle_map_ready = false;

__attribute__((visibility("hidden"))) char s_real_data_container_dir[PATH_MAX];
__attribute__((visibility("hidden"))) size_t s_real_data_container_len = 0;
__attribute__((visibility("hidden"))) _Atomic int s_data_map_state = 0; // 0: uninitialized/retryable, 1: ready
__attribute__((visibility("hidden"))) BOOL pt_ensure_data_container_map(void);

static _Atomic bool s_app_backups_disabled_for_safe_mode = false;
static _Atomic bool s_app_backup_ready = false;
static pthread_once_t s_app_backup_once = PTHREAD_ONCE_INIT;
static char s_app_backup_dir[PATH_MAX];
static size_t s_app_backup_dir_len = 0;
static char s_backup_manifest_path[PATH_MAX];
static dev_t s_backup_manifest_dev = 0;
static ino_t s_backup_manifest_ino = 0;
static BOOL s_has_backup_manifest_pin = NO;
static char s_backup_mobileprovision_path[PATH_MAX];
static size_t s_backup_mobileprovision_len = 0;
static dev_t s_backup_mobileprovision_dev = 0;
static ino_t s_backup_mobileprovision_ino = 0;
static BOOL s_has_backup_mobileprovision = NO;
static char s_backup_info_plist_path[PATH_MAX];
static size_t s_backup_info_plist_len = 0;
static dev_t s_backup_info_plist_dev = 0;
static ino_t s_backup_info_plist_ino = 0;
static BOOL s_has_backup_info_plist = NO;
static char s_backup_code_resources_path[PATH_MAX];
static size_t s_backup_code_resources_len = 0;
static dev_t s_backup_code_resources_dev = 0;
static ino_t s_backup_code_resources_ino = 0;
static BOOL s_has_backup_code_resources = NO;
static os_unfair_lock s_synth_code_res_lock = OS_UNFAIR_LOCK_INIT;
static _Atomic bool s_has_synth_code_res = false;
static char s_synth_code_res_path[PATH_MAX];
static dev_t s_synth_code_res_dev = 0;
static ino_t s_synth_code_res_ino = 0;
static char s_backup_executable_path[PATH_MAX];
static size_t s_backup_executable_len = 0;
static dev_t s_backup_executable_dev = 0;
static ino_t s_backup_executable_ino = 0;
static BOOL s_has_backup_executable = NO;
static char s_real_main_exec_path[PATH_MAX];
static size_t s_real_main_exec_len = 0;
static char s_real_main_exec_rel_path[PATH_MAX];
static void pt_ensure_app_backup_map(void);
static BOOL pt_norm_is_inside_group_container(const char *norm);

static inline BOOL pt_match_path_component_token(const char *start,
                                                 const char *q,
                                                 const char *tok,
                                                 size_t tok_len,
                                                 BOOL allow_dot_end) {
    if (q != start && q[-1] != '/') {
        return NO;
    }
    if (strncmp(q, tok, tok_len) != 0) {
        return NO;
    }
    char endc = q[tok_len];
    return (endc == '\0' || endc == '/' || (allow_dot_end && endc == '.'));
}

static inline BOOL pt_rel_subpath_has_hidden_plugin_component(const char *rel) {
    if (rel == NULL || rel[0] == '\0') {
        return NO;
    }
    if (pt_is_registered_hidden_module(rel)) {
        return YES;
    }
    for (const char *q = rel; *q != '\0'; q++) {
        if (q != rel && q[-1] != '/') {
            continue;
        }
        switch (*q) {
            case 'P':
                if (q[1] == 'l' && q[2] == 'a' && q[3] == 'y') {
                    if (pt_match_path_component_token(rel, q, "PlayTools.framework", 19, NO) ||
                        pt_match_path_component_token(rel, q, "PlayTools.dylib", 15, NO) ||
                        pt_match_path_component_token(rel, q, "Playtools.strings", 17, NO)) {
                        return YES;
                    }
                }
                break;
            case 'i':
                if (pt_match_path_component_token(rel, q, "io.playcover.PlayCover", 22, YES)) {
                    return YES;
                }
                break;
            case 'a':
                if (pt_match_path_component_token(rel, q, "app.makedie.MacOver", 19, YES)) {
                    return YES;
                }
                break;
            case 'A':
                if (pt_match_path_component_token(rel, q, "AKInterface.bundle", 18, NO)) {
                    return YES;
                }
                break;
            case 'U':
                if (pt_match_path_component_token(rel, q, "UserPlugins", 11, NO)) {
                    return YES;
                }
                break;
            default:
                break;
        }
    }
    return NO;
}

static inline BOOL pt_rel_data_subpath_is_macos_artifact(const char *rel) {
    if (!pt_is_bypass_enabled() || rel == NULL || rel[0] != '/') {
        return NO;
    }
    const char *s = rel + 1;
    static const struct {
        const char *prefix;
        size_t len;
    } kArtifacts[] = {
        PT_STR_ENTRY("Desktop"),
        PT_STR_ENTRY(".CFUserTextEncoding"),
        PT_STR_ENTRY("Library/Saved Application State"),
        PT_STR_ENTRY("Library/Application Scripts")
    };
    for (size_t i = 0; i < sizeof(kArtifacts) / sizeof(kArtifacts[0]); ++i) {
        size_t len = kArtifacts[i].len;
        if (strncmp(s, kArtifacts[i].prefix, len) == 0 &&
            (s[len] == '\0' || s[len] == '/')) {
            return YES;
        }
    }
    return NO;
}

static BOOL pt_rel_data_subpath_is_host_user_symlink(const char *rel) {
    if (!pt_is_bypass_enabled() || rel == NULL || rel[0] != '/' || s_real_data_container_len == 0) {
        return NO;
    }
    const char *s = rel + 1;
    static const struct {
        const char *name;
        size_t len;
    } kSymlinkNames[] = {
        PT_STR_ENTRY("Downloads"),
        PT_STR_ENTRY("Movies"),
        PT_STR_ENTRY("Music"),
        PT_STR_ENTRY("Pictures")
    };
    const char *matched_name = NULL;
    for (size_t i = 0; i < sizeof(kSymlinkNames) / sizeof(kSymlinkNames[0]); i++) {
        size_t len = kSymlinkNames[i].len;
        if (strncmp(s, kSymlinkNames[i].name, len) == 0 &&
            (s[len] == '\0' || s[len] == '/')) {
            matched_name = kSymlinkNames[i].name;
            break;
        }
    }
    if (matched_name == NULL) {
        return NO;
    }

    char link_path[PATH_MAX];
    int ln = snprintf(link_path, sizeof(link_path), "%s/%s", s_real_data_container_dir, matched_name);
    if (ln <= 0 || (size_t)ln >= sizeof(link_path)) {
        return NO;
    }
    struct stat st;
    if (lstat(link_path, &st) != 0 || !S_ISLNK(st.st_mode)) {
        return NO;
    }
    char target[PATH_MAX];
    ssize_t rlen = readlink(link_path, target, sizeof(target) - 1U);
    if (rlen <= 0) {
        return NO;
    }
    target[rlen] = '\0';

    char joined[PATH_MAX];
    const char *cand = target;
    if (target[0] != '/') {
        int jn = snprintf(joined, sizeof(joined), "%s/%s", s_real_data_container_dir, target);
        if (jn <= 0 || (size_t)jn >= sizeof(joined)) {
            return NO;
        }
        cand = joined;
    }
    char norm_buf[PATH_MAX];
    const char *resolved = cand;
    if (cand[0] == '/' && pt_needs_lexical_norm(cand)) {
        const char *collapsed = pt_normalize_lexical_path(cand, norm_buf, sizeof(norm_buf));
        if (collapsed != NULL) {
            resolved = collapsed;
        }
    }
    if (strncmp(resolved, "/System/Volumes/Data/", 21) == 0) {
        resolved += 20;
    }
    if (pt_match_prefix_modulo_private(resolved, s_real_data_container_dir, s_real_data_container_len) != NULL) {
        return NO;
    }
    if (strncmp(resolved, "/Users/", 7) == 0) {
        return YES;
    }
    const char *user_root = pt_get_host_user_root_cstr();
    if (user_root != NULL) {
        size_t ur_len = strlen(user_root);
        if (ur_len > 1U && strncmp(resolved, user_root, ur_len) == 0 &&
            (resolved[ur_len] == '/' || resolved[ur_len] == '\0')) {
            return YES;
        }
    }
    return NO;
}

__attribute__((visibility("hidden"))) BOOL pt_is_hidden_normalized_path_cached_caller(const char *norm, const void *caller, int *inout_is_sys_caller) {
    if (norm == NULL || norm[0] == '\0') {
        return NO;
    }
    if (strncmp(norm, "/System/Volumes/Data/", 21) == 0) {
        norm += 20;
    }

    if (norm[0] == '/') {
        if (atomic_load_explicit(&s_bundle_map_ready, memory_order_acquire) &&
            s_real_app_bundle_len > 0) {
            const char *rel = pt_match_prefix_modulo_private(norm, s_real_app_bundle_dir, s_real_app_bundle_len);
            if (rel != NULL) {
                if (!pt_rel_subpath_has_hidden_plugin_component(rel)) {
                    return NO;
                }
                if (*inout_is_sys_caller < 0) {
                    *inout_is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
                }
                return (*inout_is_sys_caller == 0);
            }
        }
        int data_state = atomic_load_explicit(&s_data_map_state, memory_order_acquire);
        if (data_state == 0 && strstr(norm, "/Library/Containers/") != NULL) {
            if (pt_ensure_data_container_map()) {
                data_state = 1;
            }
        }
        if (data_state == 1 && s_real_data_container_len > 0) {
            const char *rel = pt_match_prefix_modulo_private(norm, s_real_data_container_dir, s_real_data_container_len);
            if (rel != NULL) {
                if (!pt_rel_subpath_has_hidden_plugin_component(rel) &&
                    !pt_rel_data_subpath_is_macos_artifact(rel) &&
                    !pt_rel_data_subpath_is_host_user_symlink(rel)) {
                    return NO;
                }
                if (*inout_is_sys_caller < 0) {
                    *inout_is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
                }
                return (*inout_is_sys_caller == 0);
            }
        }
        if (pt_norm_is_inside_group_container(norm)) {
            if (!pt_rel_subpath_has_hidden_plugin_component(norm)) {
                return NO;
            }
            if (*inout_is_sys_caller < 0) {
                *inout_is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
            }
            return (*inout_is_sys_caller == 0);
        }
        if (!atomic_load_explicit(&s_app_backup_ready, memory_order_acquire) &&
            strstr(norm, "AppBackups") != NULL &&
            !pt_is_in_internal_scope() &&
            atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
            pt_ensure_app_backup_map();
        }
        if (atomic_load_explicit(&s_app_backup_ready, memory_order_acquire) &&
            s_app_backup_dir_len > 0 &&
            pt_match_prefix_modulo_private(norm, s_app_backup_dir, s_app_backup_dir_len) != NULL) {
            if (*inout_is_sys_caller < 0) {
                *inout_is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
            }
            return (*inout_is_sys_caller == 0);
        }
        if (strstr(norm, "/app.makedie.MacOver/SVCPatches") != NULL ||
            strstr(norm, "/io.playcover.PlayCover/SVCPatches") != NULL) {
            if (*inout_is_sys_caller < 0) {
                *inout_is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
            }
            return (*inout_is_sys_caller == 0);
        }
    }

    if (norm[0] == '/') {
        char c1 = norm[1];
        if (c1 == 'A' || c1 == 'L' || c1 == 'p' || c1 == 'v' || c1 == 'u' || c1 == 'e' || c1 == 'c' || c1 == '.') {
            typedef struct {
                const char *prefix;
                size_t len;
            } pt_prefix_entry_t;
            static const pt_prefix_entry_t always_blocked[] = {
                PT_STR_ENTRY("/Applications/MacOver.app"),
                PT_STR_ENTRY("/Applications/PlayCover.app"),
                PT_STR_ENTRY("/Applications/Cydia.app"),
                PT_STR_ENTRY("/Applications/Sileo.app"),
                PT_STR_ENTRY("/Applications/Zebra.app"),
                PT_STR_ENTRY("/Applications/TrollStore.app"),
                PT_STR_ENTRY("/Applications/Dopamine.app"),
                PT_STR_ENTRY("/Applications/palera1n.app"),
                PT_STR_ENTRY("/Applications/Filza.app"),
                PT_STR_ENTRY("/Library/MobileSubstrate"),
                PT_STR_ENTRY("/Library/TweakInject"),
                PT_STR_ENTRY("/Library/dpkg"),
                PT_STR_ENTRY("/Library/Frameworks/CydiaSubstrate.framework"),
                PT_STR_ENTRY("/Library/Frameworks/ElleKit.framework"),
                PT_STR_ENTRY("/Library/Frameworks/libhooker.dylib"),
                PT_STR_ENTRY("/Library/PreferenceBundles/LaunchInSafeMode.bundle"),
                PT_STR_ENTRY("/private/preboot"),
                PT_STR_ENTRY("/private/var/jb"),
                PT_STR_ENTRY("/private/var/binpack"),
                PT_STR_ENTRY("/private/var/checkra1n.dmg"),
                PT_STR_ENTRY("/private/var/lib/apt"),
                PT_STR_ENTRY("/private/var/lib/cydia"),
                PT_STR_ENTRY("/private/var/lib/dpkg"),
                PT_STR_ENTRY("/private/var/lib/undecimus"),
                PT_STR_ENTRY("/private/var/containers/Bundle/tweaksupport"),
                PT_STR_ENTRY("/private/var/containers/Bundle/iosbinpack64"),
                PT_STR_ENTRY("/private/var/mobile/Library/palera1n"),
                PT_STR_ENTRY("/private/var/mobile/Library/Caches/com.opa334.TrollStore"),
                PT_STR_ENTRY("/private/var/log/apt"),
                PT_STR_ENTRY("/private/var/log/syslog"),
                PT_STR_ENTRY("/private/var/stash"),
                PT_STR_ENTRY("/private/etc/apt"),
                PT_STR_ENTRY("/private/etc/ssh"),
                PT_STR_ENTRY("/var/jb"),
                PT_STR_ENTRY("/var/binpack"),
                PT_STR_ENTRY("/var/checkra1n.dmg"),
                PT_STR_ENTRY("/var/cache/apt"),
                PT_STR_ENTRY("/var/lib/apt"),
                PT_STR_ENTRY("/var/lib/cydia"),
                PT_STR_ENTRY("/var/lib/dpkg"),
                PT_STR_ENTRY("/var/lib/undecimus"),
                PT_STR_ENTRY("/var/containers/Bundle/tweaksupport"),
                PT_STR_ENTRY("/var/containers/Bundle/iosbinpack64"),
                PT_STR_ENTRY("/var/mobile/Library/palera1n"),
                PT_STR_ENTRY("/var/mobile/Library/Caches/com.opa334.TrollStore"),
                PT_STR_ENTRY("/var/log/apt"),
                PT_STR_ENTRY("/var/log/syslog"),
                PT_STR_ENTRY("/usr/lib/TweakInject"),
                PT_STR_ENTRY("/var/jb/usr/lib/TweakInject"),
                PT_STR_ENTRY("/private/var/jb/usr/lib/TweakInject"),
                PT_STR_ENTRY("/usr/lib/ellekit.dylib"),
                PT_STR_ENTRY("/usr/lib/libhooker.dylib"),
                PT_STR_ENTRY("/usr/lib/libsubstitute.dylib"),
                PT_STR_ENTRY("/usr/lib/SSLKillSwitch2.dylib"),
                PT_STR_ENTRY("/usr/lib/Shadow.dylib"),
                PT_STR_ENTRY("/usr/lib/Choicy.dylib"),
                PT_STR_ENTRY("/usr/lib/substrate"),
                PT_STR_ENTRY("/usr/sbin/frida-server"),
                PT_STR_ENTRY("/usr/bin/cycript"),
                PT_STR_ENTRY("/usr/local/bin/cycript"),
                PT_STR_ENTRY("/usr/lib/libcycript.dylib"),
                PT_STR_ENTRY("/usr/libexec/ssh-keysign"),
                PT_STR_ENTRY("/usr/libexec/sftp-server"),
                PT_STR_ENTRY("/usr/sbin/sshd"),
                PT_STR_ENTRY("/usr/bin/sshd"),
                PT_STR_ENTRY("/usr/bin/ssh"),
                PT_STR_ENTRY("/etc/ssh"),
                PT_STR_ENTRY("/etc/apt"),
                PT_STR_ENTRY("/cores/binpack"),
                PT_STR_ENTRY("/.installed_unc0ver"),
                PT_STR_ENTRY("/.bootstrapped_electra"),
                PT_STR_ENTRY("/.installed_dopamine"),
                PT_STR_ENTRY("/.installed_palera1n"),
                PT_STR_ENTRY("/.palera1n_strapped"),
                PT_STR_ENTRY("/.procursus_strapped")
            };
            for (size_t i = 0; i < sizeof(always_blocked) / sizeof(always_blocked[0]); ++i) {
                size_t len = always_blocked[i].len;
                if (norm[1] == always_blocked[i].prefix[1] &&
                    strncmp(norm, always_blocked[i].prefix, len) == 0 &&
                    (norm[len] == '\0' || norm[len] == '/')) {
                    return YES;
                }
            }
        }
    }

    BOOL check_bypass_artifacts = pt_is_bypass_enabled();
    BOOL is_candidate = NO;
    if (norm[0] == '/') {
        switch (norm[1]) {
            case 'A':
                if (check_bypass_artifacts &&
                    strncmp(norm, "/Applications", 13) == 0 &&
                    (norm[13] == '\0' || norm[13] == '/')) {
                    is_candidate = YES;
                }
                break;
            case 'L':
                if (check_bypass_artifacts &&
                    ((strncmp(norm, "/Library/Application Support", 28) == 0 &&
                      (norm[28] == '\0' || norm[28] == '/')) ||
                     (strncmp(norm, "/Library/Desktop Pictures", 25) == 0 &&
                      (norm[25] == '\0' || norm[25] == '/')) ||
                     (strncmp(norm, "/Library/LaunchDaemons", 22) == 0 &&
                      (norm[22] == '\0' || norm[22] == '/')) ||
                     (strncmp(norm, "/Library/LaunchAgents", 21) == 0 &&
                      (norm[21] == '\0' || norm[21] == '/')) ||
                     (strncmp(norm, "/Library/Frameworks", 19) == 0 &&
                      (norm[19] == '\0' || norm[19] == '/')) ||
                     (strncmp(norm, "/Library/Extensions", 19) == 0 &&
                      (norm[19] == '\0' || norm[19] == '/')) ||
                     strcmp(norm, "/Library/Preferences/SystemConfiguration/preferences.plist") == 0 ||
                     strcmp(norm, "/Library/Preferences/com.apple.TimeMachine.plist") == 0 ||
                     strncmp(norm, "/Library/Preferences/com.apple.windowserver", 43) == 0 ||
                     strcmp(norm, "/Library/Preferences/com.apple.loginwindow.plist") == 0)) {
                    is_candidate = YES;
                }
                break;
            case 'S':
            case 's':
                if ((strncmp(norm, "/System/iOSSupport", 18) == 0 &&
                     (norm[18] == '\0' || norm[18] == '/')) ||
                    (check_bypass_artifacts &&
                     ((strncmp(norm, "/System/Applications", 20) == 0 &&
                       (norm[20] == '\0' || norm[20] == '/')) ||
                      (strncmp(norm, "/System/Library/Extensions", 26) == 0 &&
                       (norm[26] == '\0' || norm[26] == '/')) ||
                      (strncasecmp(norm, "/System/Library/CoreServices/Finder.app", 39) == 0 &&
                       (norm[39] == '\0' || norm[39] == '/')) ||
                      (strncasecmp(norm, "/System/Library/CoreServices/Dock.app", 37) == 0 &&
                       (norm[37] == '\0' || norm[37] == '/')) ||
                      (strncasecmp(norm, "/System/Library/CoreServices/SystemUIServer.app", 47) == 0 &&
                       (norm[47] == '\0' || norm[47] == '/')) ||
                      (strncasecmp(norm, "/System/Library/CoreServices/ControlCenter.app", 46) == 0 &&
                       (norm[46] == '\0' || norm[46] == '/')) ||
                      (strncasecmp(norm, "/System/Library/CoreServices/WindowManager.app", 46) == 0 &&
                       (norm[46] == '\0' || norm[46] == '/')) ||
                      (strncasecmp(norm, "/System/Library/CoreServices/NotificationCenter.app", 51) == 0 &&
                       (norm[51] == '\0' || norm[51] == '/')) ||
                      strcasecmp(norm, "/System/Library/CoreServices/iOSSystemVersion.plist") == 0 ||
                      strcmp(norm, "/System/Volumes") == 0 ||
                      strcmp(norm, "/System/Volumes/Data") == 0 ||
                      (strncmp(norm, "/System/Volumes/VM", 18) == 0 &&
                       (norm[18] == '\0' || norm[18] == '/')) ||
                      (strncmp(norm, "/System/Volumes/Preboot", 23) == 0 &&
                       (norm[23] == '\0' || norm[23] == '/')) ||
                      (strncmp(norm, "/System/Volumes/Update", 22) == 0 &&
                       (norm[22] == '\0' || norm[22] == '/')) ||
                      (strncmp(norm, "/System/Volumes/Hardware", 24) == 0 &&
                       (norm[24] == '\0' || norm[24] == '/'))))) {
                    is_candidate = YES;
                }
                break;
            case 'e':
                if (check_bypass_artifacts &&
                    (strcmp(norm, "/etc/resolv.conf") == 0 ||
                     strcmp(norm, "/etc/synthetic.conf") == 0)) {
                    is_candidate = YES;
                }
                break;
            case 'V':
                if (check_bypass_artifacts &&
                    strncmp(norm, "/Volumes", 8) == 0 &&
                    (norm[8] == '\0' || norm[8] == '/')) {
                    is_candidate = YES;
                }
                break;
            case 'U':
                if (check_bypass_artifacts) {
                    if (strcmp(norm, "/Users") == 0 ||
                        strcmp(norm, "/Users/Shared") == 0 ||
                        strncmp(norm, "/Users/Shared/", 14) == 0) {
                        is_candidate = YES;
                    }
                }
                break;
            case 'b':
                if (strcmp(norm, "/bin/bash") == 0 ||
                    strcmp(norm, "/bin/sh") == 0 ||
                    strcmp(norm, "/bin/zsh") == 0) {
                    is_candidate = YES;
                }
                break;
            case 'u':
                if (strcmp(norm, "/usr/bin/sudo") == 0 ||
                    strncmp(norm, "/usr/local/Homebrew", 19) == 0 ||
                    strncmp(norm, "/usr/local/bin/brew", 19) == 0 ||
                    (check_bypass_artifacts &&
                     ((strncmp(norm, "/usr/local", 10) == 0 &&
                       (norm[10] == '\0' || norm[10] == '/')) ||
                      strcmp(norm, "/usr/share/firmlinks") == 0 ||
                      strcmp(norm, "/usr/bin/osascript") == 0 ||
                      strcmp(norm, "/usr/bin/sw_vers") == 0 ||
                      strcmp(norm, "/usr/bin/open") == 0 ||
                      strcmp(norm, "/usr/bin/mdls") == 0 ||
                      strcmp(norm, "/usr/bin/xcrun") == 0 ||
                      strcmp(norm, "/usr/bin/xcode-select") == 0 ||
                      strcmp(norm, "/usr/sbin/screencapture") == 0))) {
                    is_candidate = YES;
                }
                break;
            case 'o':
                if (check_bypass_artifacts
                        ? (strncmp(norm, "/opt", 4) == 0 && (norm[4] == '\0' || norm[4] == '/'))
                        : (strncmp(norm, "/opt/homebrew", 13) == 0)) {
                    is_candidate = YES;
                }
                break;
            case 'v':
                if (strcmp(norm, "/var/select/sh") == 0 ||
                    (check_bypass_artifacts &&
                     ((strncmp(norm, "/var/vm", 7) == 0 &&
                       (norm[7] == '\0' || norm[7] == '/')) ||
                      strcmp(norm, "/var/run/utmpx") == 0 ||
                      strcmp(norm, "/var/run/resolv.conf") == 0 ||
                      (strncmp(norm, "/var/db/dslocal", 15) == 0 &&
                       (norm[15] == '\0' || norm[15] == '/'))))) {
                    is_candidate = YES;
                }
                break;
            case 'p':
                if (strcmp(norm, "/private/var/select/sh") == 0 ||
                    (check_bypass_artifacts &&
                     ((strncmp(norm, "/private/var/vm", 15) == 0 &&
                       (norm[15] == '\0' || norm[15] == '/')) ||
                      strcmp(norm, "/private/var/run/utmpx") == 0 ||
                      strcmp(norm, "/private/var/run/resolv.conf") == 0 ||
                      strcmp(norm, "/private/etc/resolv.conf") == 0 ||
                      strcmp(norm, "/private/etc/synthetic.conf") == 0 ||
                      (strncmp(norm, "/private/var/db/dslocal", 23) == 0 &&
                       (norm[23] == '\0' || norm[23] == '/'))))) {
                    is_candidate = YES;
                }
                break;
            default:
                break;
        }
    }
    if (!is_candidate && pt_is_registered_hidden_module(norm)) {
        is_candidate = YES;
    }
    if (!is_candidate) {
        for (const char *q = norm; *q != '\0' && !is_candidate; q++) {
            switch (*q) {
                case 'd':
                    if ((q == norm || q[-1] == '/') && strncmp(q, "discord-ipc-", 12) == 0) {
                        is_candidate = YES;
                    }
                    break;
                case 'P':
                    if ((q == norm || q[-1] == '/') && q[1] == 'l' && q[2] == 'a' && q[3] == 'y') {
                        if (pt_match_path_component_token(norm, q, "PlayTools.framework", 19, NO) ||
                            pt_match_path_component_token(norm, q, "PlayTools.dylib", 15, NO) ||
                            pt_match_path_component_token(norm, q, "Playtools.strings", 17, NO)) {
                            is_candidate = YES;
                        }
                    }
                    break;
                case 'i':
                    if (pt_match_path_component_token(norm, q, "io.playcover.PlayCover", 22, YES)) {
                        if (strstr(norm, "/io.playcover.PlayCover/Applications/") == NULL) {
                            is_candidate = YES;
                        }
                    }
                    break;
                case 'a':
                    if (pt_match_path_component_token(norm, q, "app.makedie.MacOver", 19, YES)) {
                        if (strstr(norm, "/app.makedie.MacOver/Applications/") == NULL) {
                            is_candidate = YES;
                        }
                    }
                    break;
                case 'A':
                    if (pt_match_path_component_token(norm, q, "AKInterface.bundle", 18, NO)) {
                        is_candidate = YES;
                    }
                    break;
                case 'U':
                    if (pt_match_path_component_token(norm, q, "UserPlugins", 11, NO)) {
                        is_candidate = YES;
                    }
                    break;
                case '~':
                    if (check_bypass_artifacts &&
                        strncmp(q, "~iosmac.savedState", 18) == 0 &&
                        (q[18] == '\0' || q[18] == '/')) {
                        is_candidate = YES;
                    }
                    break;
                case '/':
                    if (check_bypass_artifacts) {
                        if (q[1] == 'S' &&
                            strncmp(q, "/Saved Application State", 24) == 0 &&
                            (q[24] == '\0' || q[24] == '/')) {
                            is_candidate = YES;
                        } else if (q[1] == '.' &&
                                   strncmp(q, "/.CFUserTextEncoding", 21) == 0 &&
                                   (q[21] == '\0' || q[21] == '/')) {
                            is_candidate = YES;
                        }
                    }
                    break;
                default:
                    break;
            }
        }
    }
    if (is_candidate) {
        if (*inout_is_sys_caller < 0) {
            *inout_is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
        }
        if (*inout_is_sys_caller == 0) {
            return YES;
        }
    }
    return NO;
}

__attribute__((visibility("hidden")))
BOOL pt_is_hidden_path(const char *path, const void *caller) {
    if (path == NULL || path[0] == '\0') {
        return NO;
    }
    char lex_buf[PATH_MAX];
    const char *norm = path;
    if (norm[0] == '/' && pt_needs_lexical_norm(norm)) {
        const char *collapsed = pt_normalize_lexical_path(norm, lex_buf, sizeof(lex_buf));
        if (collapsed != NULL) {
            norm = collapsed;
        }
    }
    int is_sys_caller = -1;
    return pt_is_hidden_normalized_path_cached_caller(norm, caller, &is_sys_caller);
}



__attribute__((visibility("hidden"))) char s_virtual_private_bundle_dir[PATH_MAX];
__attribute__((visibility("hidden"))) size_t s_virtual_private_bundle_len = 0;
__attribute__((visibility("hidden"))) char s_virtual_var_bundle_dir[PATH_MAX];
__attribute__((visibility("hidden"))) size_t s_virtual_var_bundle_len = 0;
__attribute__((visibility("hidden"))) char s_virtual_bundle_uuid_parent_var[128];
static char s_virtual_bundle_uuid_parent_priv[136];
__attribute__((visibility("hidden"))) bool s_app_info_plist_in_contents = false;

__attribute__((visibility("hidden"))) char s_virtual_var_data_dir[PATH_MAX];
__attribute__((visibility("hidden"))) size_t s_virtual_var_data_len = 0;
__attribute__((visibility("hidden"))) char s_virtual_private_data_dir[PATH_MAX];
__attribute__((visibility("hidden"))) size_t s_virtual_private_data_len = 0;
__attribute__((visibility("hidden"))) char s_virtual_tmpdir[PATH_MAX];

static pthread_once_t s_bundle_path_once = PTHREAD_ONCE_INIT;
__attribute__((visibility("hidden"))) os_unfair_lock s_container_map_lock = OS_UNFAIR_LOCK_INIT;
__attribute__((visibility("hidden"))) char s_real_group_containers_root[PATH_MAX];
__attribute__((visibility("hidden"))) size_t s_real_group_containers_root_len = 0;
__attribute__((visibility("hidden"))) _Atomic bool s_group_map_nonempty = false;


__attribute__((visibility("hidden"))) os_unfair_lock s_group_map_lock = OS_UNFAIR_LOCK_INIT;
__attribute__((visibility("hidden"))) pt_group_container_entry_t s_group_map[PT_MAX_GROUP_CONTAINERS];
__attribute__((visibility("hidden"))) size_t s_group_map_count = 0;
__attribute__((visibility("hidden"))) BOOL s_group_root_scanned = NO;

static BOOL pt_norm_is_inside_group_container(const char *norm) {
    if (norm == NULL || norm[0] != '/') {
        return NO;
    }
    if (s_real_group_containers_root_len > 0 &&
        pt_match_prefix_modulo_private(norm, s_real_group_containers_root, s_real_group_containers_root_len) != NULL) {
        if (!atomic_load_explicit(&s_group_map_nonempty, memory_order_acquire)) {
            return NO;
        }
        os_unfair_lock_lock(&s_group_map_lock);
        BOOL matched = NO;
        for (size_t i = 0; i < s_group_map_count; i++) {
            if (s_group_map[i].real_len > 0 &&
                pt_match_prefix_modulo_private(norm, s_group_map[i].real_dir, s_group_map[i].real_len) != NULL) {
                matched = YES;
                break;
            }
        }
        os_unfair_lock_unlock(&s_group_map_lock);
        return matched;
    }
    return NO;
}


static uint64_t pt_fnv1a_64(const char *str, uint64_t seed) {
    uint64_t h = seed;
    for (const unsigned char *p = (const unsigned char *)str; *p != '\0'; ++p) {
        h ^= (uint64_t)(*p);
        h *= 1099511628211ULL;
    }
    return h;
}

__attribute__((visibility("hidden"))) void pt_format_deterministic_uuid(const char *input, uint64_t seed1, uint64_t seed2, char out_uuid[40]) {
    uint64_t h1 = pt_fnv1a_64(input, seed1);
    uint64_t h2 = pt_fnv1a_64(input, seed2 ^ h1);
    snprintf(out_uuid, 40, "%08X-%04X-4%03X-%04X-%012llX",
             (unsigned int)(h1 >> 32),
             (unsigned int)((h1 >> 16) & 0xFFFF),
             (unsigned int)(h1 & 0x0FFF),
             (unsigned int)(0x8000 | ((h2 >> 48) & 0x3FFF)),
             (unsigned long long)(h2 & 0xFFFFFFFFFFFFULL));
}

static void pt_derive_app_folder_name(const char *real_bundle_dir, char *out_name, size_t out_size) {
    char raw[256];
    raw[0] = '\0';

    int sfd = pt_open_early_settings_plist_fd();
    if (sfd >= 0) {
        (void)pt_read_plist_top_string_from_fd(sfd, "originalBundleName", raw, sizeof(raw));
        close(sfd);
    }
    if (raw[0] == '\0' && real_bundle_dir != NULL && real_bundle_dir[0] == '/') {
        char info_path[PATH_MAX];
        int n = snprintf(info_path, sizeof(info_path), "%s/Contents/Info.plist", real_bundle_dir);
        int ifd = (n > 0 && (size_t)n < sizeof(info_path)) ? pt_orig_open_nocancel(info_path, O_RDONLY) : -1;
        if (ifd < 0) {
            n = snprintf(info_path, sizeof(info_path), "%s/Info.plist", real_bundle_dir);
            if (n > 0 && (size_t)n < sizeof(info_path)) {
                ifd = pt_orig_open_nocancel(info_path, O_RDONLY);
            }
        }
        if (ifd >= 0) {
            (void)pt_read_plist_top_string_from_fd(ifd, "CFBundleExecutable", raw, sizeof(raw));
            close(ifd);
        }
    }
    if (raw[0] != '\0') {
        const char *slash = strrchr(raw, '/');
        const char *base = (slash != NULL && slash[1] != '\0') ? (slash + 1) : raw;
        size_t blen = strlen(base);
        while (blen > 0 && base[blen - 1] == '/') {
            blen--;
        }
        if (blen > 4 && strncmp(base + blen - 4, ".app", 4) == 0) {
            blen -= 4;
        }
        if (blen > 0) {
            int n = snprintf(out_name, out_size, "%.*s.app", (int)blen, base);
            if (n > 0 && (size_t)n < out_size) {
                return;
            }
        }
    }
    const char *fallback = (real_bundle_dir != NULL) ? strrchr(real_bundle_dir, '/') : NULL;
    fallback = (fallback != NULL && fallback[1] != '\0') ? (fallback + 1) : "App.app";
    strlcpy(out_name, fallback, out_size);
}

static void pt_init_bundle_path_map(void) {
    pt_enter_internal_scope();
    char bundle_buf[PATH_MAX];
    const char *bundle_src = NULL;
    size_t bundle_len = 0;

    const char *exec_path = pt_get_main_executable_path();
    if (exec_path != NULL) {
        const char *app_ext = strstr(exec_path, ".app/");
        if (app_ext != NULL) {
            bundle_src = exec_path;
            bundle_len = (size_t)(app_ext + 4 - exec_path);
        }
    }
    if (bundle_src == NULL || bundle_len == 0) {
        const char *test_bundle = pt_raw_getenv("PLAYTOOLS_TEST_BUNDLE_DIR");
        if (test_bundle != NULL && test_bundle[0] == '/') {
            if (strncmp(test_bundle, "/System/Volumes/Data/", 21) == 0) {
                test_bundle += 20;
            }
            size_t tlen = strlen(test_bundle);
            while (tlen > 1 && test_bundle[tlen - 1] == '/') {
                tlen--;
            }
            if (tlen > 0 && tlen < sizeof(bundle_buf)) {
                memcpy(bundle_buf, test_bundle, tlen);
                bundle_buf[tlen] = '\0';
                bundle_src = bundle_buf;
                bundle_len = tlen;
            }
        }
    }
    if (bundle_src != NULL && bundle_len > 0 && bundle_len < sizeof(s_real_app_bundle_dir)) {
        memcpy(s_real_app_bundle_dir, bundle_src, bundle_len);
        s_real_app_bundle_dir[bundle_len] = '\0';
        s_real_app_bundle_len = bundle_len;

        char app_folder[256];
        pt_derive_app_folder_name(s_real_app_bundle_dir, app_folder, sizeof(app_folder));

        char bundle_uuid[40];
        pt_format_deterministic_uuid(s_real_app_bundle_dir,
                                     14695981039346656037ULL,
                                     0x9e3779b97f4a7c15ULL,
                                     bundle_uuid);

        snprintf(s_virtual_bundle_uuid_parent_var, sizeof(s_virtual_bundle_uuid_parent_var),
                 "/var/containers/Bundle/Application/%s", bundle_uuid);
        snprintf(s_virtual_bundle_uuid_parent_priv, sizeof(s_virtual_bundle_uuid_parent_priv),
                 "/private/var/containers/Bundle/Application/%s", bundle_uuid);

        snprintf(s_virtual_private_bundle_dir, sizeof(s_virtual_private_bundle_dir),
                 "/private/var/containers/Bundle/Application/%s/%s", bundle_uuid, app_folder);
        s_virtual_private_bundle_len = strlen(s_virtual_private_bundle_dir);

        snprintf(s_virtual_var_bundle_dir, sizeof(s_virtual_var_bundle_dir),
                 "/var/containers/Bundle/Application/%s/%s", bundle_uuid, app_folder);
        s_virtual_var_bundle_len = strlen(s_virtual_var_bundle_dir);

        char flat_info[PATH_MAX];
        char contents_info[PATH_MAX];
        int fn = snprintf(flat_info, sizeof(flat_info), "%s/Info.plist", s_real_app_bundle_dir);
        int cn = snprintf(contents_info, sizeof(contents_info), "%s/Contents/Info.plist", s_real_app_bundle_dir);
        if (fn > 0 && (size_t)fn < sizeof(flat_info) && access(flat_info, F_OK) != 0 &&
            cn > 0 && (size_t)cn < sizeof(contents_info) && access(contents_info, F_OK) == 0) {
            s_app_info_plist_in_contents = true;
        }
    }
    atomic_store_explicit(&s_bundle_map_ready, true, memory_order_release);
    pt_leave_internal_scope();
}

__attribute__((visibility("hidden"))) void pt_ensure_bundle_path_map(void) {
    if (!atomic_load_explicit(&s_bundle_map_ready, memory_order_acquire)) {
        pthread_once(&s_bundle_path_once, pt_init_bundle_path_map);
    }
}

static BOOL pt_verify_app_backup_manifest(const char *backup_dir,
                                          const char *real_bundle_dir,
                                          dev_t *out_manifest_dev,
                                          ino_t *out_manifest_ino) {
    if (backup_dir == NULL || backup_dir[0] != '/' ||
        real_bundle_dir == NULL || real_bundle_dir[0] != '/') {
        return NO;
    }
    char manifest_path[PATH_MAX];
    int mn = snprintf(manifest_path, sizeof(manifest_path), "%s/manifest.plist", backup_dir);
    if (mn <= 0 || (size_t)mn >= sizeof(manifest_path)) {
        return NO;
    }
    int mfd = pt_orig_open_nocancel(manifest_path, O_RDONLY | O_NOFOLLOW);
    if (mfd < 0) {
        return NO;
    }
    struct stat mst;
    if (fstat(mfd, &mst) != 0 || !S_ISREG(mst.st_mode)) {
        close(mfd);
        return NO;
    }

    char info_path[PATH_MAX];
    int info_n = snprintf(info_path, sizeof(info_path), "%s/Contents/Info.plist", real_bundle_dir);
    int ifd = (info_n > 0 && (size_t)info_n < sizeof(info_path)) ? pt_orig_open_nocancel(info_path, O_RDONLY) : -1;
    if (ifd < 0) {
        info_n = snprintf(info_path, sizeof(info_path), "%s/Info.plist", real_bundle_dir);
        if (info_n > 0 && (size_t)info_n < sizeof(info_path)) {
            ifd = pt_orig_open_nocancel(info_path, O_RDONLY);
        }
    }
    if (ifd < 0) {
        close(mfd);
        return NO;
    }

    char m_gen[128] = {0};
    char b_gen[128] = {0};
    char m_bid[256] = {0};
    char b_bid[256] = {0};
    char m_short[128] = {0};
    char b_short[128] = {0};
    char m_ver[128] = {0};
    char b_ver[128] = {0};

    BOOL ok = (pt_read_plist_top_string_from_fd(mfd, "PCInstallGeneration", m_gen, sizeof(m_gen)) &&
               pt_read_plist_top_string_from_fd(ifd, "PCInstallGeneration", b_gen, sizeof(b_gen)) &&
               m_gen[0] != '\0' &&
               strcmp(m_gen, b_gen) == 0 &&
               pt_read_plist_top_string_from_fd(mfd, "CFBundleIdentifier", m_bid, sizeof(m_bid)) &&
               pt_read_plist_top_string_from_fd(ifd, "CFBundleIdentifier", b_bid, sizeof(b_bid)) &&
               m_bid[0] != '\0' &&
               strcmp(m_bid, b_bid) == 0);
    if (ok) {
        BOOL has_m_short = pt_read_plist_top_string_from_fd(mfd, "CFBundleShortVersionString", m_short, sizeof(m_short));
        BOOL has_b_short = pt_read_plist_top_string_from_fd(ifd, "CFBundleShortVersionString", b_short, sizeof(b_short));
        BOOL has_m_ver = pt_read_plist_top_string_from_fd(mfd, "CFBundleVersion", m_ver, sizeof(m_ver));
        BOOL has_b_ver = pt_read_plist_top_string_from_fd(ifd, "CFBundleVersion", b_ver, sizeof(b_ver));
        const char *eff_m_short = has_m_short ? m_short : "";
        const char *eff_b_short = has_b_short ? b_short : "";
        const char *eff_m_ver = has_m_ver ? m_ver : "";
        const char *eff_b_ver = has_b_ver ? b_ver : "";
        if (strcmp(eff_m_short, eff_b_short) != 0 || strcmp(eff_m_ver, eff_b_ver) != 0) {
            ok = NO;
        }
    }

    close(ifd);
    close(mfd);
    if (ok) {
        if (out_manifest_dev != NULL) {
            *out_manifest_dev = mst.st_dev;
        }
        if (out_manifest_ino != NULL) {
            *out_manifest_ino = mst.st_ino;
        }
    }
    return ok;
}

static void pt_init_app_backup_map(void) {
    pt_enter_internal_scope();
    do {
        pt_ensure_bundle_path_map();

        char raw_dir[PATH_MAX] = {0};
        const char *test_dir = pt_raw_getenv("PLAYTOOLS_TEST_APP_BACKUPS_DIR");
        if (test_dir != NULL && test_dir[0] == '/') {
            strlcpy(raw_dir, test_dir, sizeof(raw_dir));
        } else {
            const char *user_root = pt_get_host_user_root_cstr();
            if (user_root != NULL && user_root[0] == '/') {
                char bid[256];
                bid[0] = '\0';
                if (!pt_read_main_bundle_id_early(bid, sizeof(bid)) || bid[0] == '\0') {
                    const char *home = pt_raw_getenv("CFFIXED_USER_HOME");
                    const char *marker = (home != NULL) ? strstr(home, "/Library/Containers/") : NULL;
                    if (marker != NULL) {
                        const char *cid_start = marker + 20;
                        const char *cid_end = strchr(cid_start, '/');
                        size_t cid_len = (cid_end != NULL) ? (size_t)(cid_end - cid_start) : strlen(cid_start);
                        if (cid_len > 0 && cid_len < sizeof(bid)) {
                            memcpy(bid, cid_start, cid_len);
                            bid[cid_len] = '\0';
                        }
                    }
                }
                if (bid[0] != '\0') {
                    int n = snprintf(raw_dir, sizeof(raw_dir),
                                     "%s/Library/Containers/app.makedie.MacOver/AppBackups/%s",
                                     user_root, bid);
                    if (n <= 0 || (size_t)n >= sizeof(raw_dir)) {
                        raw_dir[0] = '\0';
                    }
                }
            }
        }

        const char *p = raw_dir;
        if (strncmp(p, "/System/Volumes/Data/", 21) == 0) {
            p += 20;
        }
        size_t blen = strlen(p);
        while (blen > 1 && p[blen - 1] == '/') {
            blen--;
        }
        if (blen == 0 || p[0] != '/' || blen >= sizeof(s_app_backup_dir)) {
            break;
        }
        memcpy(s_app_backup_dir, p, blen);
        s_app_backup_dir[blen] = '\0';
        s_app_backup_dir_len = blen;

        struct stat st;
        if (stat(s_app_backup_dir, &st) != 0 || !S_ISDIR(st.st_mode)) {
            break;
        }

        dev_t manifest_dev = 0;
        ino_t manifest_ino = 0;
        if (s_real_app_bundle_len == 0 ||
            !pt_verify_app_backup_manifest(s_app_backup_dir, s_real_app_bundle_dir, &manifest_dev, &manifest_ino)) {
            break;
        }

        char cand[PATH_MAX];
        int mn = snprintf(cand, sizeof(cand), "%s/manifest.plist", s_app_backup_dir);
        if (mn <= 0 || (size_t)mn >= sizeof(cand)) {
            break;
        }
        strlcpy(s_backup_manifest_path, cand, sizeof(s_backup_manifest_path));
        s_backup_manifest_dev = manifest_dev;
        s_backup_manifest_ino = manifest_ino;
        s_has_backup_manifest_pin = YES;

        int pn = snprintf(cand, sizeof(cand), "%s/embedded.mobileprovision", s_app_backup_dir);
        if (pn > 0 && (size_t)pn < sizeof(cand) && lstat(cand, &st) == 0 && S_ISREG(st.st_mode)) {
            strlcpy(s_backup_mobileprovision_path, cand, sizeof(s_backup_mobileprovision_path));
            s_backup_mobileprovision_len = (size_t)pn;
            s_backup_mobileprovision_dev = st.st_dev;
            s_backup_mobileprovision_ino = st.st_ino;
            s_has_backup_mobileprovision = YES;
        }

        int in = snprintf(cand, sizeof(cand), "%s/Info.plist", s_app_backup_dir);
        if (in > 0 && (size_t)in < sizeof(cand) && lstat(cand, &st) == 0 && S_ISREG(st.st_mode)) {
            strlcpy(s_backup_info_plist_path, cand, sizeof(s_backup_info_plist_path));
            s_backup_info_plist_len = (size_t)in;
            s_backup_info_plist_dev = st.st_dev;
            s_backup_info_plist_ino = st.st_ino;
            s_has_backup_info_plist = YES;
        }

        int crn = snprintf(cand, sizeof(cand), "%s/CodeResources", s_app_backup_dir);
        if (crn > 0 && (size_t)crn < sizeof(cand) && lstat(cand, &st) == 0 && S_ISREG(st.st_mode)) {
            strlcpy(s_backup_code_resources_path, cand, sizeof(s_backup_code_resources_path));
            s_backup_code_resources_len = (size_t)crn;
            s_backup_code_resources_dev = st.st_dev;
            s_backup_code_resources_ino = st.st_ino;
            s_has_backup_code_resources = YES;
        }

        int en = snprintf(cand, sizeof(cand), "%s/executable", s_app_backup_dir);
        if (en > 0 && (size_t)en < sizeof(cand) && lstat(cand, &st) == 0 && S_ISREG(st.st_mode)) {
            dev_t exec_dev = st.st_dev;
            ino_t exec_ino = st.st_ino;
            const char *exec_path = pt_get_main_executable_path();
            if (exec_path != NULL && exec_path[0] == '/') {
                if (strncmp(exec_path, "/System/Volumes/Data/", 21) == 0) {
                    exec_path += 20;
                }
                size_t elen = strlen(exec_path);
                if (elen > 0 && elen < sizeof(s_real_main_exec_path)) {
                    memcpy(s_real_main_exec_path, exec_path, elen);
                    s_real_main_exec_path[elen] = '\0';
                    s_real_main_exec_len = elen;

                    const char *rel = (s_real_app_bundle_len > 0)
                        ? pt_match_prefix_modulo_private(s_real_main_exec_path,
                                                         s_real_app_bundle_dir,
                                                         s_real_app_bundle_len)
                        : NULL;
                    if (rel != NULL && rel[0] == '/' && strlen(rel) < sizeof(s_real_main_exec_rel_path)) {
                        strlcpy(s_real_main_exec_rel_path, rel, sizeof(s_real_main_exec_rel_path));
                        strlcpy(s_backup_executable_path, cand, sizeof(s_backup_executable_path));
                        s_backup_executable_len = (size_t)en;
                        s_backup_executable_dev = exec_dev;
                        s_backup_executable_ino = exec_ino;
                        s_has_backup_executable = YES;
                    } else {
                        s_real_main_exec_path[0] = '\0';
                        s_real_main_exec_len = 0;
                    }
                }
            }
        }
    } while (0);
    atomic_store_explicit(&s_app_backup_ready, true, memory_order_release);
    pt_leave_internal_scope();
}

static void pt_ensure_app_backup_map(void) {
    if (!atomic_load_explicit(&s_app_backup_ready, memory_order_acquire) &&
        !pt_is_in_internal_scope() &&
        atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        pthread_once(&s_app_backup_once, pt_init_app_backup_map);
    }
}

__attribute__((visibility("hidden"))) void pt_disable_app_backups_for_safe_mode(void) {
    atomic_store_explicit(&s_app_backups_disabled_for_safe_mode, true, memory_order_release);
}

static BOOL pt_verify_pinned_backup_file(const char *path, dev_t exp_dev, ino_t exp_ino) {
    if (!s_has_backup_manifest_pin || path == NULL || path[0] != '/') {
        return NO;
    }
    struct stat mst;
    if (lstat(s_backup_manifest_path, &mst) != 0 ||
        !S_ISREG(mst.st_mode) ||
        mst.st_dev != s_backup_manifest_dev ||
        mst.st_ino != s_backup_manifest_ino) {
        atomic_store_explicit(&s_app_backups_disabled_for_safe_mode, true, memory_order_release);
        return NO;
    }
    struct stat fst;
    if (lstat(path, &fst) != 0 ||
        !S_ISREG(fst.st_mode) ||
        fst.st_dev != exp_dev ||
        fst.st_ino != exp_ino) {
        return NO;
    }
    return YES;
}

__attribute__((visibility("hidden"))) BOOL pt_has_backup_mobileprovision(void) {
    if (atomic_load_explicit(&s_app_backups_disabled_for_safe_mode, memory_order_acquire) ||
        !pt_is_bypass_enabled()) {
        return NO;
    }
    pt_ensure_app_backup_map();
    if (!atomic_load_explicit(&s_app_backup_ready, memory_order_acquire) || !s_has_backup_mobileprovision) {
        return NO;
    }
    return pt_verify_pinned_backup_file(
        s_backup_mobileprovision_path, s_backup_mobileprovision_dev, s_backup_mobileprovision_ino);
}

__attribute__((visibility("hidden")))
const char *pt_copy_virtual_mobileprovision_path(char *buf, size_t bufsize) {
    if (buf == NULL || bufsize == 0) {
        return NULL;
    }
    pt_ensure_bundle_path_map();
    if (!pt_has_backup_mobileprovision() || s_virtual_private_bundle_len == 0) {
        return NULL;
    }
    return pt_join_path_fast(buf, bufsize,
                             s_virtual_private_bundle_dir,
                             s_virtual_private_bundle_len,
                             "/embedded.mobileprovision");
}

static NSMutableDictionary *pt_clean_code_resources_subdict(NSDictionary *sub) {
    NSMutableDictionary *clean = nil;
    for (id key in sub) {
        if ([key isKindOfClass:[NSString class]]) {
            NSString *k = (NSString *)key;
            if ([k localizedCaseInsensitiveContainsString:@"PlayTools"] ||
                [k localizedCaseInsensitiveContainsString:@"PlayCover"] ||
                [k localizedCaseInsensitiveContainsString:@"MacOver"] ||
                [k localizedCaseInsensitiveContainsString:@"AKInterface"] ||
                [k localizedCaseInsensitiveContainsString:@"SVCPatches"] ||
                [k localizedCaseInsensitiveContainsString:@"Playtools.strings"] ||
                [k localizedCaseInsensitiveContainsString:@"UserPlugins"]) {
                if (clean == nil) {
                    clean = [sub mutableCopy];
                }
                [clean removeObjectForKey:key];
            }
        }
    }
    return clean;
}

__attribute__((visibility("hidden"))) BOOL pt_is_synth_code_resources_path(const char *p) {
    if (p == NULL || !atomic_load_explicit(&s_has_synth_code_res, memory_order_acquire) ||
        strstr(p, ".pt_coderes_") == NULL) {
        return NO;
    }
    BOOL match = NO;
    os_unfair_lock_lock(&s_synth_code_res_lock);
    if (s_synth_code_res_path[0] != '\0') {
        const char *rem = pt_match_prefix_modulo_private(p, s_synth_code_res_path, strlen(s_synth_code_res_path));
        match = (rem != NULL && rem[0] == '\0');
    }
    os_unfair_lock_unlock(&s_synth_code_res_lock);
    return match;
}

static const char *pt_get_or_build_sanitized_code_resources_path(char *out_buf, size_t out_size) {
    if (s_real_app_bundle_len == 0 || out_buf == NULL || out_size == 0) {
        return NULL;
    }
    int saved_errno = errno;
    char cached_path[PATH_MAX];
    cached_path[0] = '\0';
    dev_t cached_dev = 0;
    ino_t cached_ino = 0;
    os_unfair_lock_lock(&s_synth_code_res_lock);
    if (s_synth_code_res_path[0] != '\0') {
        strlcpy(cached_path, s_synth_code_res_path, sizeof(cached_path));
        cached_dev = s_synth_code_res_dev;
        cached_ino = s_synth_code_res_ino;
    }
    os_unfair_lock_unlock(&s_synth_code_res_lock);

    if (cached_path[0] != '\0') {
        pt_enter_internal_scope();
        struct stat st;
        BOOL alive = (stat(cached_path, &st) == 0 &&
                      st.st_dev == cached_dev &&
                      st.st_ino == cached_ino);
        pt_leave_internal_scope();
        if (alive) {
            size_t n = strlcpy(out_buf, cached_path, out_size);
            errno = saved_errno;
            return (n < out_size) ? out_buf : NULL;
        }
    }

    pt_ensure_data_container_map();
    pt_enter_internal_scope();
    NSData *xmlOut = nil;
    @autoreleasepool {
        char src_path[PATH_MAX];
        int sn = snprintf(src_path, sizeof(src_path), "%s/_CodeSignature/CodeResources", s_real_app_bundle_dir);
        int rfd = (sn > 0 && (size_t)sn < sizeof(src_path)) ? pt_orig_open_nocancel(src_path, O_RDONLY) : -1;
        if (rfd < 0) {
            sn = snprintf(src_path, sizeof(src_path), "%s/Contents/_CodeSignature/CodeResources", s_real_app_bundle_dir);
            if (sn > 0 && (size_t)sn < sizeof(src_path)) {
                rfd = pt_orig_open_nocancel(src_path, O_RDONLY);
            }
        }
        if (rfd >= 0) {
            size_t raw_len = 0;
            size_t map_size = 0;
            uint8_t *raw_bytes = pt_read_fd_plist_bytes(rfd, &raw_len, &map_size);
            close(rfd);
            if (raw_bytes != NULL && raw_len > 0) {
                NSData *rawData = [NSData dataWithBytes:raw_bytes length:raw_len];
                munmap(raw_bytes, map_size);
                id plist = [NSPropertyListSerialization propertyListWithData:rawData
                                                                     options:NSPropertyListImmutable
                                                                      format:nil
                                                                       error:nil];
                if ([plist isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *dict = (NSDictionary *)plist;
                    NSArray<NSString *> *subkeys = @[@"files", @"files2", @"rules", @"rules2"];
                    NSMutableDictionary *cleanDict = nil;
                    for (NSString *sk in subkeys) {
                        id sub = dict[sk];
                        if ([sub isKindOfClass:[NSDictionary class]]) {
                            NSMutableDictionary *csub = pt_clean_code_resources_subdict((NSDictionary *)sub);
                            if (csub != nil) {
                                if (cleanDict == nil) {
                                    cleanDict = [dict mutableCopy];
                                }
                                cleanDict[sk] = [csub copy];
                            }
                        }
                    }
                    if (cleanDict != nil) {
                        xmlOut = [NSPropertyListSerialization dataWithPropertyList:cleanDict
                                                                            format:NSPropertyListXMLFormat_v1_0
                                                                           options:0
                                                                             error:nil];
                    }
                }
            } else if (raw_bytes != NULL) {
                munmap(raw_bytes, map_size);
            }
        }
    }
    if (xmlOut == nil || xmlOut.length == 0) {
        pt_leave_internal_scope();
        errno = saved_errno;
        return NULL;
    }

    char container_tmp[PATH_MAX];
    const char *dirs[3] = { NULL, NULL, "/tmp" };
    if (s_real_data_container_len > 0) {
        int dn = snprintf(container_tmp, sizeof(container_tmp), "%s/tmp", s_real_data_container_dir);
        if (dn > 0 && (size_t)dn < sizeof(container_tmp)) {
            dirs[0] = container_tmp;
        }
    }
    const char *env_tmp = pt_raw_getenv("TMPDIR");
    char env_tmp_buf[PATH_MAX];
    if (env_tmp != NULL && env_tmp[0] == '/') {
        strlcpy(env_tmp_buf, env_tmp, sizeof(env_tmp_buf));
        size_t el = strlen(env_tmp_buf);
        while (el > 1 && env_tmp_buf[el - 1] == '/') {
            env_tmp_buf[--el] = '\0';
        }
        dirs[1] = env_tmp_buf;
    }

    char created_path[PATH_MAX];
    created_path[0] = '\0';
    dev_t created_dev = 0;
    ino_t created_ino = 0;
    for (size_t i = 0; i < 3 && created_path[0] == '\0'; i++) {
        if (dirs[i] == NULL || dirs[i][0] != '/') {
            continue;
        }
        char tmpl[PATH_MAX];
        int tn = snprintf(tmpl, sizeof(tmpl), "%s/.pt_coderes_XXXXXX", dirs[i]);
        if (tn <= 0 || (size_t)tn >= sizeof(tmpl)) {
            continue;
        }
        int fd = mkstemp(tmpl);
        if (fd < 0) {
            continue;
        }
        (void)fchmod(fd, 0444);
        const uint8_t *wptr = (const uint8_t *)xmlOut.bytes;
        size_t rem = xmlOut.length;
        BOOL wrote = YES;
        while (rem > 0) {
            ssize_t w = write(fd, wptr, rem);
            if (w <= 0) {
                wrote = NO;
                break;
            }
            wptr += (size_t)w;
            rem -= (size_t)w;
        }
        struct stat st;
        if (wrote && fstat(fd, &st) == 0) {
            close(fd);
            strlcpy(created_path, tmpl, sizeof(created_path));
            created_dev = st.st_dev;
            created_ino = st.st_ino;
            break;
        }
        close(fd);
        unlink(tmpl);
    }
    if (created_path[0] == '\0') {
        pt_leave_internal_scope();
        errno = saved_errno;
        return NULL;
    }

    BOOL discard_created = NO;
    size_t copied_len = out_size;
    os_unfair_lock_lock(&s_synth_code_res_lock);
    if (s_synth_code_res_path[0] != '\0' &&
        (s_synth_code_res_dev != cached_dev || s_synth_code_res_ino != cached_ino)) {
        copied_len = strlcpy(out_buf, s_synth_code_res_path, out_size);
        discard_created = YES;
    }
    if (!discard_created) {
        strlcpy(s_synth_code_res_path, created_path, sizeof(s_synth_code_res_path));
        s_synth_code_res_dev = created_dev;
        s_synth_code_res_ino = created_ino;
        atomic_store_explicit(&s_has_synth_code_res, true, memory_order_release);
        copied_len = strlcpy(out_buf, created_path, out_size);
    }
    os_unfair_lock_unlock(&s_synth_code_res_lock);
    if (discard_created) {
        unlink(created_path);
    }
    pt_leave_internal_scope();
    errno = saved_errno;
    return (copied_len < out_size && out_buf[0] != '\0') ? out_buf : NULL;
}

static const char *pt_lookup_app_backup_redirect_unlocked(const char *p, const char *bundle_rel, char *vbuf, size_t vbuf_size) {
    if (s_has_backup_mobileprovision && bundle_rel != NULL &&
        (strcmp(bundle_rel, "/embedded.mobileprovision") == 0 ||
         strcmp(bundle_rel, "/Contents/embedded.mobileprovision") == 0)) {
        return pt_verify_pinned_backup_file(
            s_backup_mobileprovision_path, s_backup_mobileprovision_dev, s_backup_mobileprovision_ino)
            ? s_backup_mobileprovision_path
            : NULL;
    }
    if (s_has_backup_info_plist && bundle_rel != NULL &&
        (strcmp(bundle_rel, "/Info.plist") == 0 ||
         strcmp(bundle_rel, "/Contents/Info.plist") == 0)) {
        return pt_verify_pinned_backup_file(
            s_backup_info_plist_path, s_backup_info_plist_dev, s_backup_info_plist_ino)
            ? s_backup_info_plist_path
            : NULL;
    }
    if (bundle_rel != NULL &&
        (strcmp(bundle_rel, "/_CodeSignature/CodeResources") == 0 ||
         strcmp(bundle_rel, "/Contents/_CodeSignature/CodeResources") == 0)) {
        if (s_has_backup_code_resources) {
            const char *pinned = pt_verify_pinned_backup_file(
                s_backup_code_resources_path, s_backup_code_resources_dev, s_backup_code_resources_ino)
                ? s_backup_code_resources_path
                : NULL;
            if (pinned != NULL) {
                return pinned;
            }
        }
        return pt_get_or_build_sanitized_code_resources_path(vbuf, vbuf_size);
    }
    if (s_has_backup_executable && s_real_main_exec_len > 0 && p != NULL) {
        const char *erel = pt_match_prefix_modulo_private(p, s_real_main_exec_path, s_real_main_exec_len);
        if (erel != NULL && erel[0] == '\0') {
            return pt_verify_pinned_backup_file(
                s_backup_executable_path, s_backup_executable_dev, s_backup_executable_ino)
                ? s_backup_executable_path
                : NULL;
        }
    }
    return NULL;
}

__attribute__((visibility("hidden")))
const char *pt_lookup_app_backup_redirect_for_caller(const char *raw_path,
                                                     const void *caller,
                                                     char *vbuf,
                                                     size_t vbuf_size,
                                                     int *inout_is_sys_caller) {
    if (raw_path == NULL || raw_path[0] != '/' || vbuf == NULL || vbuf_size == 0 ||
        pt_is_in_internal_scope() ||
        !pt_is_bypass_enabled() ||
        atomic_load_explicit(&s_app_backups_disabled_for_safe_mode, memory_order_acquire)) {
        return NULL;
    }
    if (!atomic_load_explicit(&s_bundle_map_ready, memory_order_acquire) || s_real_app_bundle_len == 0) {
        return NULL;
    }
    const char *p = raw_path;
    if (strncmp(p, "/System/Volumes/Data/", 21) == 0) {
        p += 20;
    }
    const char *rel = pt_match_prefix_modulo_private(p, s_real_app_bundle_dir, s_real_app_bundle_len);
    if (rel == NULL || rel[0] != '/') {
        return NULL;
    }
    int local_sys = (inout_is_sys_caller != NULL) ? *inout_is_sys_caller : -1;
    if (local_sys < 0) {
        local_sys = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
        if (inout_is_sys_caller != NULL) {
            *inout_is_sys_caller = local_sys;
        }
    }
    if (local_sys == 1) {
        return NULL;
    }
    pt_ensure_app_backup_map();
    if (!atomic_load_explicit(&s_app_backup_ready, memory_order_acquire)) {
        return NULL;
    }
    const char *target = pt_lookup_app_backup_redirect_unlocked(p, rel, vbuf, vbuf_size);
    if (target == NULL) {
        return NULL;
    }
    if (target == vbuf) {
        return vbuf;
    }
    size_t n = strlcpy(vbuf, target, vbuf_size);
    return (n < vbuf_size) ? vbuf : NULL;
}

static os_unfair_lock s_backup_main_hdr_lock = OS_UNFAIR_LOCK_INIT;
static BOOL s_backup_main_hdr_loaded = NO;
static uint8_t *s_backup_main_hdr_bytes = NULL;
static size_t s_backup_main_hdr_len = 0;

static off_t pt_find_arm64_slice_offset_in_fd(int fd, cpu_subtype_t wanted_subtype) {
    struct fat_header fh;
    if (pread(fd, &fh, sizeof(fh), 0) != (ssize_t)sizeof(fh)) {
        return -1;
    }
    if (fh.magic == MH_MAGIC_64) {
        return 0;
    }
    uint32_t magic = ntohl(fh.magic);
    uint32_t count = ntohl(fh.nfat_arch);
    if ((magic != FAT_MAGIC && magic != FAT_MAGIC_64) || count == 0 || count > 128U) {
        return -1;
    }
    BOOL is_fat64 = (magic == FAT_MAGIC_64);
    size_t stride = is_fat64 ? sizeof(struct fat_arch_64) : sizeof(struct fat_arch);
    off_t fallback = -1;
    for (uint32_t i = 0; i < count; i++) {
        union {
            struct fat_arch a32;
            struct fat_arch_64 a64;
        } entry;
        off_t eoff = (off_t)(sizeof(fh) + (size_t)i * stride);
        if (pread(fd, &entry, stride, eoff) != (ssize_t)stride) {
            return -1;
        }
        uint32_t cpu = ntohl(is_fat64 ? (uint32_t)entry.a64.cputype : (uint32_t)entry.a32.cputype);
        uint32_t sub = ntohl(is_fat64 ? (uint32_t)entry.a64.cpusubtype : (uint32_t)entry.a32.cpusubtype);
        uint64_t off = is_fat64 ? __builtin_bswap64(entry.a64.offset) : (uint64_t)ntohl(entry.a32.offset);
        if (cpu != (uint32_t)CPU_TYPE_ARM64 || off > (uint64_t)(INT64_MAX - 2 * 1024 * 1024)) {
            continue;
        }
        if ((sub & ~(uint32_t)CPU_SUBTYPE_MASK) == ((uint32_t)wanted_subtype & ~(uint32_t)CPU_SUBTYPE_MASK)) {
            return (off_t)off;
        }
        if (fallback < 0) {
            fallback = (off_t)off;
        }
    }
    return fallback;
}

__attribute__((visibility("hidden")))
const uint8_t *pt_get_cached_backup_main_mach_header(size_t *out_len) {
    if (out_len != NULL) {
        *out_len = 0;
    }
    if (atomic_load_explicit(&s_app_backups_disabled_for_safe_mode, memory_order_acquire) ||
        !pt_is_bypass_enabled()) {
        return NULL;
    }
    pt_ensure_app_backup_map();
    if (!atomic_load_explicit(&s_app_backup_ready, memory_order_acquire) ||
        !s_has_backup_executable ||
        !pt_verify_pinned_backup_file(s_backup_executable_path, s_backup_executable_dev, s_backup_executable_ino)) {
        return NULL;
    }

    os_unfair_lock_lock(&s_backup_main_hdr_lock);
    if (!s_backup_main_hdr_loaded) {
        s_backup_main_hdr_loaded = YES;
        pt_enter_internal_scope();
        int fd = pt_orig_open_nocancel(s_backup_executable_path, O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            cpu_subtype_t wanted = CPU_SUBTYPE_ARM64_ALL;
            const struct mach_header *live_mh = pt_get_main_executable_header();
            if (live_mh != NULL && pt_is_valid_user_pointer(live_mh)) {
                wanted = live_mh->cpusubtype;
            }
            off_t slice_off = pt_find_arm64_slice_offset_in_fd(fd, wanted);
            struct mach_header_64 mh64;
            if (slice_off >= 0 &&
                pread(fd, &mh64, sizeof(mh64), slice_off) == (ssize_t)sizeof(mh64) &&
                mh64.magic == MH_MAGIC_64 &&
                mh64.sizeofcmds > 0 &&
                mh64.sizeofcmds <= (1U << 20)) {
                size_t total = sizeof(mh64) + (size_t)mh64.sizeofcmds;
                uint8_t *buf = (uint8_t *)malloc(total);
                if (buf != NULL) {
                    if (pread(fd, buf, total, slice_off) == (ssize_t)total) {
                        s_backup_main_hdr_bytes = buf;
                        s_backup_main_hdr_len = total;
                    } else {
                        free(buf);
                    }
                }
            }
            close(fd);
        }
        pt_leave_internal_scope();
    }
    const uint8_t *res = s_backup_main_hdr_bytes;
    size_t res_len = s_backup_main_hdr_len;
    os_unfair_lock_unlock(&s_backup_main_hdr_lock);

    if (res == NULL || res_len < sizeof(struct mach_header_64)) {
        return NULL;
    }
    if (out_len != NULL) {
        *out_len = res_len;
    }
    return res;
}

__attribute__((visibility("hidden"))) BOOL pt_is_active_app_backup_file_path(const char *p) {
    if (p == NULL || p[0] != '/' ||
        atomic_load_explicit(&s_app_backups_disabled_for_safe_mode, memory_order_acquire) ||
        !atomic_load_explicit(&s_app_backup_ready, memory_order_acquire)) {
        return NO;
    }
    if (s_has_backup_mobileprovision && s_backup_mobileprovision_len > 0) {
        const char *rel = pt_match_prefix_modulo_private(p, s_backup_mobileprovision_path, s_backup_mobileprovision_len);
        if (rel != NULL && rel[0] == '\0') {
            return YES;
        }
    }
    if (s_has_backup_info_plist && s_backup_info_plist_len > 0) {
        const char *rel = pt_match_prefix_modulo_private(p, s_backup_info_plist_path, s_backup_info_plist_len);
        if (rel != NULL && rel[0] == '\0') {
            return YES;
        }
    }
    if (s_has_backup_code_resources && s_backup_code_resources_len > 0) {
        const char *rel = pt_match_prefix_modulo_private(p, s_backup_code_resources_path, s_backup_code_resources_len);
        if (rel != NULL && rel[0] == '\0') {
            return YES;
        }
    }
    if (pt_is_synth_code_resources_path(p)) {
        return YES;
    }
    if (s_has_backup_executable && s_backup_executable_len > 0) {
        const char *rel = pt_match_prefix_modulo_private(p, s_backup_executable_path, s_backup_executable_len);
        if (rel != NULL && rel[0] == '\0') {
            return YES;
        }
    }
    return NO;
}

__attribute__((visibility("hidden"))) const char *pt_virtualize_app_backup_path(const char *p, char *buf, size_t bufsize, BOOL use_private_prefix) {
    if (p == NULL || buf == NULL || bufsize == 0 ||
        atomic_load_explicit(&s_app_backups_disabled_for_safe_mode, memory_order_acquire) ||
        !atomic_load_explicit(&s_app_backup_ready, memory_order_acquire) ||
        s_real_app_bundle_len == 0) {
        return NULL;
    }
    const char *prefix = use_private_prefix ? s_virtual_private_bundle_dir : s_virtual_var_bundle_dir;
    size_t plen = use_private_prefix ? s_virtual_private_bundle_len : s_virtual_var_bundle_len;
    if (plen == 0) {
        return NULL;
    }
    if (s_has_backup_mobileprovision && s_backup_mobileprovision_len > 0) {
        const char *rel = pt_match_prefix_modulo_private(p, s_backup_mobileprovision_path, s_backup_mobileprovision_len);
        if (rel != NULL && rel[0] == '\0') {
            return pt_join_path_fast(buf, bufsize, prefix, plen, "/embedded.mobileprovision");
        }
    }
    if (s_has_backup_info_plist && s_backup_info_plist_len > 0) {
        const char *rel = pt_match_prefix_modulo_private(p, s_backup_info_plist_path, s_backup_info_plist_len);
        if (rel != NULL && rel[0] == '\0') {
            return pt_join_path_fast(buf, bufsize, prefix, plen, "/Info.plist");
        }
    }
    if (s_has_backup_code_resources && s_backup_code_resources_len > 0) {
        const char *rel = pt_match_prefix_modulo_private(p, s_backup_code_resources_path, s_backup_code_resources_len);
        if (rel != NULL && rel[0] == '\0') {
            return pt_join_path_fast(buf, bufsize, prefix, plen, "/_CodeSignature/CodeResources");
        }
    }
    if (pt_is_synth_code_resources_path(p)) {
        return pt_join_path_fast(buf, bufsize, prefix, plen, "/_CodeSignature/CodeResources");
    }
    if (s_has_backup_executable && s_backup_executable_len > 0 && s_real_main_exec_rel_path[0] == '/') {
        const char *rel = pt_match_prefix_modulo_private(p, s_backup_executable_path, s_backup_executable_len);
        if (rel != NULL && rel[0] == '\0') {
            return pt_join_path_fast(buf, bufsize, prefix, plen, s_real_main_exec_rel_path);
        }
    }
    return NULL;
}


static ssize_t pt_fs_fsgetpath_impl(char *buf, size_t bufsize, fsid_t *fsid, uint64_t objid, const void *caller) {
    ssize_t ret = fsgetpath(buf, bufsize, fsid, objid);
    if (ret <= 0 || buf == NULL || bufsize == 0 ||
        !pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(caller)) {
        return ret;
    }
    buf[bufsize - 1] = '\0';
    char vout[PATH_MAX];
    const char *virt = pt_virtualize_path_for_app(buf, vout, sizeof(vout), YES);
    if (virt != buf) {
        size_t n = strlcpy(buf, virt, bufsize);
        if (n >= bufsize) {
            errno = ENAMETOOLONG;
            return -1;
        }
        ret = (ssize_t)(n + 1);
    }
    if (pt_is_sensitive_host_fd_path(buf, caller)) {
        buf[0] = '\0';
        errno = ENOENT;
        return -1;
    }
    return ret;
}

__attribute__((visibility("hidden")))
ssize_t pt_fs_fsgetpath_with_caller(char *buf, size_t bufsize, fsid_t *fsid, uint64_t objid, const void *caller) {
    return pt_fs_fsgetpath_impl(buf, bufsize, fsid, objid, caller);
}

static ssize_t pt_fsgetpath(char *buf, size_t bufsize, fsid_t *fsid, uint64_t objid) {
    return pt_fs_fsgetpath_impl(buf, bufsize, fsid, objid, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
ssize_t pt_fs_fsgetpath_ext_with_caller(char *buf,
                                        size_t bufsize,
                                        fsid_t *fsid,
                                        uint64_t objid,
                                        uint64_t flags,
                                        const void *caller) {
    typedef ssize_t (*FsGetPathExtFn)(char *, size_t, fsid_t *, uint64_t, uint64_t);
    static FsGetPathExtFn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (FsGetPathExtFn)dlsym(RTLD_NEXT, "fsgetpath_ext");
    });
    if (s_orig == NULL) {
        errno = ENOSYS;
        return -1;
    }
    ssize_t ret = s_orig(buf, bufsize, fsid, objid, flags);
    if (ret <= 0 || buf == NULL || bufsize == 0 ||
        !pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(caller)) {
        return ret;
    }
    buf[bufsize - 1] = '\0';
    char vout[PATH_MAX];
    const char *virt = pt_virtualize_path_for_app(buf, vout, sizeof(vout), YES);
    if (virt != buf) {
        size_t n = strlcpy(buf, virt, bufsize);
        if (n >= bufsize) {
            errno = ENAMETOOLONG;
            return -1;
        }
        ret = (ssize_t)(n + 1);
    }
    if (pt_is_sensitive_host_fd_path(buf, caller)) {
        buf[0] = '\0';
        errno = ENOENT;
        return -1;
    }
    return ret;
}

static ssize_t pt_fsgetpath_ext(char *buf, size_t bufsize, fsid_t *fsid, uint64_t objid, uint64_t flags) {
    return pt_fs_fsgetpath_ext_with_caller(buf, bufsize, fsid, objid, flags, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_fs_searchfs_with_caller(const char *path,
                               void *searchblock,
                               unsigned long *nummatches,
                               unsigned int scriptcode,
                               unsigned int options,
                               void *state,
                               const void *caller) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
        errno = ENOTSUP;
        return -1;
    }
    typedef int (*SearchFsFn)(const char *, void *, unsigned long *, unsigned int, unsigned int, void *);
    static SearchFsFn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (SearchFsFn)dlsym(RTLD_NEXT, "searchfs");
    });
    if (s_orig != NULL) {
        return s_orig(path, searchblock, nummatches, scriptcode, options, state);
    }
    errno = ENOSYS;
    return -1;
}

static int pt_searchfs(const char *path,
                       void *searchblock,
                       unsigned long *nummatches,
                       unsigned int scriptcode,
                       unsigned int options,
                       void *state) {
    return pt_fs_searchfs_with_caller(path, searchblock, nummatches, scriptcode, options, state,
                                      __builtin_return_address(0));
}

PT_INTERPOSE(pt_fsgetpath, fsgetpath)
PT_DLSYM_ONLY("fsgetpath_ext", pt_fsgetpath_ext)
PT_DLSYM_ONLY("searchfs", pt_searchfs)
