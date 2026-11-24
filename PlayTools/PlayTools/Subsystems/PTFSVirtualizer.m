//
//  PTFSVirtualizer.m
//  PlayTools
//

#import "PTInternal.h"
#if __has_include(<sys/fsgetpath.h>)
#include <sys/fsgetpath.h>
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

__attribute__((visibility("hidden"))) const char *pt_normalize_lexical_path(const char *src, char *dst, size_t dst_size) {
    if (src == NULL || dst == NULL || dst_size < 2 || src[0] != '/') {
        return NULL;
    }
    size_t seg_starts[512];
    size_t seg_depth = 0;
    size_t out = 0;
    dst[out++] = '/';

    const char *p = src + 1;
    while (*p != '\0') {
        while (*p == '/') {
            p++;
        }
        if (*p == '\0') {
            break;
        }
        const char *seg_end = p;
        while (*seg_end != '\0' && *seg_end != '/') {
            seg_end++;
        }
        size_t seg_len = (size_t)(seg_end - p);
        if (seg_len == 1 && p[0] == '.') {
            // Skip "."
        } else if (seg_len == 2 && p[0] == '.' && p[1] == '.') {
            if (seg_depth > 0) {
                out = seg_starts[--seg_depth];
                if (out == 0) {
                    out = 1;
                }
            }
        } else {
            if (out > 1) {
                if (out + 1 >= dst_size) {
                    return NULL;
                }
                dst[out++] = '/';
            }
            if (seg_depth < 512) {
                seg_starts[seg_depth++] = (out > 1) ? (out - 1) : 0;
            }
            if (out + seg_len >= dst_size) {
                return NULL;
            }
            memcpy(dst + out, p, seg_len);
            out += seg_len;
        }
        p = seg_end;
    }
    dst[out] = '\0';
    return dst;
}


__attribute__((visibility("hidden"))) char s_real_app_bundle_dir[PATH_MAX];
__attribute__((visibility("hidden"))) size_t s_real_app_bundle_len = 0;
static _Atomic bool s_bundle_map_ready = false;

__attribute__((visibility("hidden"))) char s_real_data_container_dir[PATH_MAX];
__attribute__((visibility("hidden"))) size_t s_real_data_container_len = 0;
static _Atomic int s_data_map_state = 0; // 0: uninitialized/retryable, 1: ready
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

__attribute__((visibility("hidden"))) const char *pt_match_prefix_modulo_private(const char *path, const char *base, size_t base_len) {
    if (path == NULL || base == NULL || base_len == 0) {
        return NULL;
    }
    if (strncmp(path, base, base_len) == 0 && (path[base_len] == '/' || path[base_len] == '\0')) {
        return path + base_len;
    }
    if (base_len > 8 && strncmp(base, "/private/", 9) == 0) {
        const char *sbase = base + 8;
        size_t slen = base_len - 8;
        if (strncmp(path, sbase, slen) == 0 && (path[slen] == '/' || path[slen] == '\0')) {
            return path + slen;
        }
    } else if (strncmp(path, "/private/", 9) == 0) {
        const char *spath = path + 8;
        if (strncmp(spath, base, base_len) == 0 && (spath[base_len] == '/' || spath[base_len] == '\0')) {
            return spath + base_len;
        }
    }
    return NULL;
}

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

static BOOL pt_is_hidden_normalized_path_cached_caller(const char *norm, const void *caller, int *inout_is_sys_caller) {
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
                      (norm[25] == '\0' || norm[25] == '/')))) {
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
                      (strncasecmp(norm, "/System/Library/CoreServices/Finder.app", 39) == 0 &&
                       (norm[39] == '\0' || norm[39] == '/')) ||
                      strcmp(norm, "/System/Volumes") == 0 ||
                      strcmp(norm, "/System/Volumes/Data") == 0))) {
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
                    strncmp(norm, "/usr/local/bin/brew", 19) == 0) {
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
                     strncmp(norm, "/var/vm", 7) == 0 &&
                     (norm[7] == '\0' || norm[7] == '/'))) {
                    is_candidate = YES;
                }
                break;
            case 'p':
                if (strcmp(norm, "/private/var/select/sh") == 0 ||
                    (check_bypass_artifacts &&
                     strncmp(norm, "/private/var/vm", 15) == 0 &&
                     (norm[15] == '\0' || norm[15] == '/'))) {
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
static size_t s_virtual_private_bundle_len = 0;
static char s_virtual_var_bundle_dir[PATH_MAX];
static size_t s_virtual_var_bundle_len = 0;
static char s_virtual_bundle_uuid_parent_var[128];
static char s_virtual_bundle_uuid_parent_priv[136];
static bool s_app_info_plist_in_contents = false;

static char s_virtual_var_data_dir[PATH_MAX];
static size_t s_virtual_var_data_len = 0;
__attribute__((visibility("hidden"))) char s_virtual_private_data_dir[PATH_MAX];
__attribute__((visibility("hidden"))) size_t s_virtual_private_data_len = 0;
static char s_virtual_tmpdir[PATH_MAX];

static pthread_once_t s_bundle_path_once = PTHREAD_ONCE_INIT;
static os_unfair_lock s_container_map_lock = OS_UNFAIR_LOCK_INIT;
static char s_real_group_containers_root[PATH_MAX];
static size_t s_real_group_containers_root_len = 0;
static _Atomic bool s_group_map_nonempty = false;

static inline const char *pt_join_path_fast(char *buf,
                                            size_t bufsize,
                                            const char *prefix,
                                            size_t prefix_len,
                                            const char *suffix) {
    if (buf == NULL || bufsize == 0 || prefix == NULL) {
        return NULL;
    }
    size_t slen = (suffix != NULL) ? strlen(suffix) : 0;
    if (prefix_len + slen >= bufsize) {
        return NULL;
    }
    memcpy(buf, prefix, prefix_len);
    if (slen > 0) {
        memcpy(buf + prefix_len, suffix, slen);
    }
    buf[prefix_len + slen] = '\0';
    return buf;
}

#define PT_MAX_GROUP_CONTAINERS 64
typedef struct {
    char real_dir[PATH_MAX];
    size_t real_len;
    char uuid[40];
    char virt_var[128];
    size_t virt_var_len;
    char virt_priv[136];
    size_t virt_priv_len;
} pt_group_container_entry_t;

static os_unfair_lock s_group_map_lock = OS_UNFAIR_LOCK_INIT;
static pt_group_container_entry_t s_group_map[PT_MAX_GROUP_CONTAINERS];
static size_t s_group_map_count = 0;
static BOOL s_group_root_scanned = NO;

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

static os_unfair_lock s_image_path_lock = OS_UNFAIR_LOCK_INIT;
static CFMutableDictionaryRef s_image_path_ptr_cache = NULL;
static CFMutableDictionaryRef s_image_path_str_cache = NULL;

static uint64_t pt_fnv1a_64(const char *str, uint64_t seed) {
    uint64_t h = seed;
    for (const unsigned char *p = (const unsigned char *)str; *p != '\0'; ++p) {
        h ^= (uint64_t)(*p);
        h *= 1099511628211ULL;
    }
    return h;
}

static void pt_format_deterministic_uuid(const char *input, uint64_t seed1, uint64_t seed2, char out_uuid[40]) {
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

static const char *pt_lookup_app_backup_redirect_unlocked(const char *p, const char *bundle_rel) {
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
    pt_ensure_app_backup_map();
    if (!atomic_load_explicit(&s_app_backup_ready, memory_order_acquire)) {
        return NULL;
    }
    const char *target = pt_lookup_app_backup_redirect_unlocked(p, rel);
    if (target == NULL) {
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

static BOOL pt_is_active_app_backup_file_path(const char *p) {
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
    if (s_has_backup_executable && s_backup_executable_len > 0) {
        const char *rel = pt_match_prefix_modulo_private(p, s_backup_executable_path, s_backup_executable_len);
        if (rel != NULL && rel[0] == '\0') {
            return YES;
        }
    }
    return NO;
}

static const char *pt_virtualize_app_backup_path(const char *p, char *buf, size_t bufsize, BOOL use_private_prefix) {
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
    if (s_has_backup_executable && s_backup_executable_len > 0 && s_real_main_exec_rel_path[0] == '/') {
        const char *rel = pt_match_prefix_modulo_private(p, s_backup_executable_path, s_backup_executable_len);
        if (rel != NULL && rel[0] == '\0') {
            return pt_join_path_fast(buf, bufsize, prefix, plen, s_real_main_exec_rel_path);
        }
    }
    return NULL;
}

static void pt_maybe_init_test_group_root_locked(void) {
    if (s_real_group_containers_root_len > 0) {
        return;
    }
    const char *test_group_root = pt_raw_getenv("PLAYTOOLS_TEST_GROUP_CONTAINERS_ROOT");
    if (test_group_root != NULL && test_group_root[0] == '/') {
        if (strncmp(test_group_root, "/System/Volumes/Data/", 21) == 0) {
            test_group_root += 20;
        }
        size_t glen = strlen(test_group_root);
        while (glen > 1 && test_group_root[glen - 1] == '/') {
            glen--;
        }
        if (glen > 0 && glen < sizeof(s_real_group_containers_root)) {
            memcpy(s_real_group_containers_root, test_group_root, glen);
            s_real_group_containers_root[glen] = '\0';
            s_real_group_containers_root_len = glen;
        }
    }
}

__attribute__((visibility("hidden"))) BOOL pt_ensure_data_container_map(void) {
    int st = atomic_load_explicit(&s_data_map_state, memory_order_acquire);
    if (st != 0) {
        return (st == 1);
    }
    os_unfair_lock_lock(&s_container_map_lock);
    st = atomic_load_explicit(&s_data_map_state, memory_order_relaxed);
    if (st != 0) {
        os_unfair_lock_unlock(&s_container_map_lock);
        return (st == 1);
    }

    pt_maybe_init_test_group_root_locked();

    const char *test_data = pt_raw_getenv("PLAYTOOLS_TEST_DATA_CONTAINER");
    const char *raw_home = NULL;
    BOOL is_test_override = NO;
    if (test_data != NULL && test_data[0] != '\0') {
        raw_home = test_data;
        is_test_override = YES;
    } else {
        raw_home = pt_raw_getenv("CFFIXED_USER_HOME");
        if (raw_home == NULL || raw_home[0] == '\0') {
            raw_home = pt_raw_getenv("HOME");
        }
    }

    BOOL ready = NO;
    if ((is_test_override && raw_home[0] == '/') ||
        (raw_home != NULL && strstr(raw_home, "/Library/Containers/") != NULL)) {
        if (strncmp(raw_home, "/System/Volumes/Data/", 21) == 0) {
            raw_home += 20;
        }
        size_t home_len = strlen(raw_home);
        while (home_len > 1 && raw_home[home_len - 1] == '/') {
            home_len--;
        }
        if (home_len > 0 && home_len < sizeof(s_real_data_container_dir)) {
            memcpy(s_real_data_container_dir, raw_home, home_len);
            s_real_data_container_dir[home_len] = '\0';
            s_real_data_container_len = home_len;

            char real_tmp[PATH_MAX];
            snprintf(real_tmp, sizeof(real_tmp), "%s/tmp", s_real_data_container_dir);
            mkdir(real_tmp, 0755);

            char data_uuid[40];
            pt_format_deterministic_uuid(s_real_data_container_dir,
                                         0x517cc1b727220a95ULL,
                                         0x2545f4914f6cdd1dULL,
                                         data_uuid);

            snprintf(s_virtual_var_data_dir, sizeof(s_virtual_var_data_dir),
                     "/var/mobile/Containers/Data/Application/%s", data_uuid);
            s_virtual_var_data_len = strlen(s_virtual_var_data_dir);

            snprintf(s_virtual_private_data_dir, sizeof(s_virtual_private_data_dir),
                     "/private/var/mobile/Containers/Data/Application/%s", data_uuid);
            s_virtual_private_data_len = strlen(s_virtual_private_data_dir);

            snprintf(s_virtual_tmpdir, sizeof(s_virtual_tmpdir),
                     "%s/tmp/", s_virtual_private_data_dir);

            if (s_real_group_containers_root_len == 0) {
                const char *containers_marker = strstr(s_real_data_container_dir, "/Library/Containers/");
                if (containers_marker != NULL && containers_marker > s_real_data_container_dir) {
                    size_t prefix_len = (size_t)(containers_marker - s_real_data_container_dir);
                    int gn = snprintf(s_real_group_containers_root, sizeof(s_real_group_containers_root),
                                      "%.*s/Library/Group Containers",
                                      (int)prefix_len, s_real_data_container_dir);
                    if (gn > 0 && (size_t)gn < sizeof(s_real_group_containers_root)) {
                        s_real_group_containers_root_len = (size_t)gn;
                    }
                }
            }

            atomic_store_explicit(&s_data_map_state, 1, memory_order_release);
            ready = YES;
        }
    }
    os_unfair_lock_unlock(&s_container_map_lock);
    return ready;
}

static const pt_group_container_entry_t *pt_group_register_dir_locked(const char *real_group_dir) {
    if (real_group_dir == NULL || real_group_dir[0] != '/') {
        return NULL;
    }
    const char *p = real_group_dir;
    if (strncmp(p, "/System/Volumes/Data/", 21) == 0) {
        p += 20;
    }
    size_t len = strlen(p);
    while (len > 1 && p[len - 1] == '/') {
        len--;
    }
    if (len <= 1 || len >= PATH_MAX) {
        return NULL;
    }
    for (size_t i = 0; i < s_group_map_count; i++) {
        if (s_group_map[i].real_len == len &&
            strncmp(s_group_map[i].real_dir, p, len) == 0) {
            return &s_group_map[i];
        }
    }
    if (s_group_map_count >= PT_MAX_GROUP_CONTAINERS) {
        return NULL;
    }
    pt_group_container_entry_t *entry = &s_group_map[s_group_map_count];
    memcpy(entry->real_dir, p, len);
    entry->real_dir[len] = '\0';
    entry->real_len = len;

    const char *slash = strrchr(entry->real_dir, '/');
    const char *group_id = (slash != NULL && slash[1] != '\0') ? (slash + 1) : entry->real_dir;
    pt_format_deterministic_uuid(group_id,
                                 0x94d049bb133111ebULL,
                                 0xbf58476d1ce4e5b9ULL,
                                 entry->uuid);

    snprintf(entry->virt_var, sizeof(entry->virt_var),
             "/var/mobile/Containers/Shared/AppGroup/%s", entry->uuid);
    entry->virt_var_len = strlen(entry->virt_var);

    snprintf(entry->virt_priv, sizeof(entry->virt_priv),
             "/private/var/mobile/Containers/Shared/AppGroup/%s", entry->uuid);
    entry->virt_priv_len = strlen(entry->virt_priv);

    s_group_map_count++;
    atomic_store_explicit(&s_group_map_nonempty, true, memory_order_release);
    return entry;
}

static const char *pt_group_format_virtual(const pt_group_container_entry_t *entry,
                                           const char *suffix,
                                           char *buf,
                                           size_t bufsize,
                                           BOOL use_private_prefix) {
    if (entry == NULL || buf == NULL || bufsize == 0) {
        return NULL;
    }
    const char *prefix = use_private_prefix ? entry->virt_priv : entry->virt_var;
    int n = snprintf(buf, bufsize, "%s%s", prefix, (suffix != NULL) ? suffix : "");
    return (n >= 0 && (size_t)n < bufsize) ? buf : NULL;
}

static const char *pt_group_match_candidate_locked(const char *cand,
                                                   char *buf,
                                                   size_t bufsize,
                                                   BOOL use_private_prefix) {
    if (cand == NULL || cand[0] != '/') {
        return NULL;
    }
    for (size_t i = 0; i < s_group_map_count; i++) {
        const pt_group_container_entry_t *e = &s_group_map[i];
        const char *suffix = pt_match_prefix_modulo_private(cand, e->real_dir, e->real_len);
        if (suffix != NULL) {
            return pt_group_format_virtual(e, suffix, buf, bufsize, use_private_prefix);
        }
    }
    if (s_real_group_containers_root_len > 0) {
        const char *sub = pt_match_prefix_modulo_private(cand, s_real_group_containers_root, s_real_group_containers_root_len);
        if (sub != NULL && sub[0] == '/') {
            const char *gid = sub + 1;
            if (gid[0] != '\0' && gid[0] != '/') {
                const char *slash = strchr(gid, '/');
                size_t gid_len = (slash != NULL) ? (size_t)(slash - gid) : strlen(gid);
                char group_dir[PATH_MAX];
                int n = snprintf(group_dir, sizeof(group_dir), "%s/%.*s",
                                 s_real_group_containers_root, (int)gid_len, gid);
                if (n > 0 && (size_t)n < sizeof(group_dir)) {
                    const pt_group_container_entry_t *entry = pt_group_register_dir_locked(group_dir);
                    if (entry != NULL) {
                        const char *suffix = (slash != NULL) ? slash : "";
                        return pt_group_format_virtual(entry, suffix, buf, bufsize, use_private_prefix);
                    }
                }
            }
        }
    }
    return NULL;
}

static const char *pt_group_try_virtualize_known_or_root(const char *p,
                                                        char *buf,
                                                        size_t bufsize,
                                                        BOOL use_private_prefix) {
    if (p == NULL || p[0] != '/' || buf == NULL || bufsize == 0) {
        return NULL;
    }
    if (strncmp(p, "/System/", 8) == 0 || strncmp(p, "/usr/", 5) == 0 || strncmp(p, "/dev/", 5) == 0) {
        return NULL;
    }
    BOOL has_known = atomic_load_explicit(&s_group_map_nonempty, memory_order_acquire);
    if (!has_known) {
        if (s_real_group_containers_root_len == 0 ||
            pt_match_prefix_modulo_private(p, s_real_group_containers_root, s_real_group_containers_root_len) == NULL) {
            return NULL;
        }
    }
    os_unfair_lock_lock(&s_group_map_lock);
    const char *res = pt_group_match_candidate_locked(p, buf, bufsize, use_private_prefix);
    if (res == NULL && strncmp(p, "/private/", 9) == 0) {
        res = pt_group_match_candidate_locked(p + 8, buf, bufsize, use_private_prefix);
    }
    os_unfair_lock_unlock(&s_group_map_lock);
    return res;
}

static void pt_scan_group_containers_root_locked(void) {
    if (s_group_root_scanned || s_real_group_containers_root_len == 0) {
        return;
    }
    s_group_root_scanned = YES;
    DIR *dirp = opendir(s_real_group_containers_root);
    if (dirp == NULL) {
        return;
    }
    struct dirent *ent = NULL;
    while ((ent = readdir(dirp)) != NULL) {
        if (ent->d_name[0] == '.') {
            continue;
        }
        if (ent->d_type != DT_DIR && ent->d_type != DT_UNKNOWN && ent->d_type != DT_LNK) {
            continue;
        }
        char child[PATH_MAX];
        int n = snprintf(child, sizeof(child), "%s/%s", s_real_group_containers_root, ent->d_name);
        if (n > 0 && (size_t)n < sizeof(child)) {
            if (ent->d_type == DT_UNKNOWN) {
                struct stat st;
                if (stat(child, &st) != 0 || !S_ISDIR(st.st_mode)) {
                    continue;
                }
            }
            pt_group_register_dir_locked(child);
        }
    }
    closedir(dirp);
}

static BOOL pt_lookup_virtual_group_container(const char *work,
                                              char *out_real_dir,
                                              size_t out_real_dir_size,
                                              const char **out_suffix) {
    if (work == NULL) {
        return NO;
    }
    BOOL is_priv = (strncmp(work, "/private/var/mobile/Containers/Shared/AppGroup/", 47) == 0);
    BOOL is_var = (!is_priv && strncmp(work, "/var/mobile/Containers/Shared/AppGroup/", 39) == 0);
    if (!is_priv && !is_var) {
        return NO;
    }

    os_unfair_lock_lock(&s_group_map_lock);
    for (int pass = 0; pass < 2; pass++) {
        for (size_t i = 0; i < s_group_map_count; i++) {
            const pt_group_container_entry_t *e = &s_group_map[i];
            const char *vprefix = is_priv ? e->virt_priv : e->virt_var;
            size_t vlen = is_priv ? e->virt_priv_len : e->virt_var_len;
            if (strncmp(work, vprefix, vlen) == 0 &&
                (work[vlen] == '/' || work[vlen] == '\0')) {
                if (out_real_dir != NULL && out_real_dir_size > 0) {
                    strlcpy(out_real_dir, e->real_dir, out_real_dir_size);
                }
                if (out_suffix != NULL) {
                    *out_suffix = work + vlen;
                }
                os_unfair_lock_unlock(&s_group_map_lock);
                return YES;
            }
        }
        if (pass == 0 && !s_group_root_scanned && s_real_group_containers_root_len > 0) {
            pt_scan_group_containers_root_locked();
        } else {
            break;
        }
    }
    os_unfair_lock_unlock(&s_group_map_lock);
    return NO;
}

__attribute__((visibility("hidden")))
const char *pt_register_and_virtualize_group_container(const char *real_group_path,
                                                       char *buf,
                                                       size_t bufsize,
                                                       BOOL use_private_prefix) {
    if (real_group_path == NULL || real_group_path[0] == '\0' || buf == NULL || bufsize == 0) {
        return real_group_path;
    }
    pt_ensure_data_container_map();

    char lex_buf[PATH_MAX];
    const char *p = real_group_path;
    if (p[0] == '/' && pt_needs_lexical_norm(p)) {
        const char *collapsed = pt_normalize_lexical_path(p, lex_buf, sizeof(lex_buf));
        if (collapsed != NULL) {
            p = collapsed;
        }
    }
    if (strncmp(p, "/System/Volumes/Data/", 21) == 0) {
        p += 20;
    }
    size_t len = strlen(p);
    while (len > 1 && p[len - 1] == '/') {
        len--;
    }
    if (p[0] != '/' || len <= 1 || len >= PATH_MAX) {
        return real_group_path;
    }
    char clean[PATH_MAX];
    memcpy(clean, p, len);
    clean[len] = '\0';

    const char *existing = pt_group_try_virtualize_known_or_root(clean, buf, bufsize, use_private_prefix);
    if (existing != NULL) {
        return existing;
    }

    os_unfair_lock_lock(&s_group_map_lock);
    const pt_group_container_entry_t *entry = pt_group_register_dir_locked(clean);
    const char *virt = pt_group_format_virtual(entry, "", buf, bufsize, use_private_prefix);
    os_unfair_lock_unlock(&s_group_map_lock);
    return (virt != NULL) ? virt : real_group_path;
}

__attribute__((visibility("hidden")))
const char *pt_get_virtual_home_cstr(void) {
    if (!pt_ensure_data_container_map()) {
        return NULL;
    }
    return (s_real_data_container_len > 0) ? s_virtual_var_data_dir : NULL;
}

__attribute__((visibility("hidden")))
const char *pt_get_virtual_tmpdir_cstr(void) {
    if (!pt_ensure_data_container_map()) {
        return NULL;
    }
    return (s_real_data_container_len > 0) ? s_virtual_tmpdir : NULL;
}

static BOOL pt_is_clean_virtual_ancestor_dir(const char *p) {
    if (p == NULL || p[0] != '/') {
        return NO;
    }
    if (strncmp(p, "/private/", 9) == 0) {
        p += 8;
    }
    if (strncmp(p, "/var/", 5) != 0) {
        return NO;
    }
    size_t len = strlen(p);
    while (len > 1 && p[len - 1] == '/') {
        len--;
    }
    if (len >= 128) {
        return NO;
    }
    char clean[128];
    memcpy(clean, p, len);
    clean[len] = '\0';

    if (strcmp(clean, "/var/mobile") == 0 ||
        strcmp(clean, "/var/mobile/Containers") == 0 ||
        strcmp(clean, "/var/mobile/Containers/Data") == 0 ||
        strcmp(clean, "/var/mobile/Containers/Data/Application") == 0 ||
        strcmp(clean, "/var/mobile/Containers/Shared") == 0 ||
        strcmp(clean, "/var/mobile/Containers/Shared/AppGroup") == 0 ||
        strcmp(clean, "/var/containers") == 0 ||
        strcmp(clean, "/var/containers/Bundle") == 0 ||
        strcmp(clean, "/var/containers/Bundle/Application") == 0) {
        return YES;
    }
    if (strncmp(clean, "/var/containers/Bundle/Application/", 35) == 0) {
        pt_ensure_bundle_path_map();
        if (s_virtual_bundle_uuid_parent_var[0] != '\0' &&
            strcmp(clean, s_virtual_bundle_uuid_parent_var) == 0) {
            return YES;
        }
    }
    return NO;
}

__attribute__((visibility("hidden")))
BOOL pt_is_virtual_container_ancestor_dir(const char *path) {
    if (path == NULL || path[0] != '/') {
        return NO;
    }
    char lex_buf[PATH_MAX];
    const char *p = path;
    if (pt_needs_lexical_norm(p)) {
        const char *collapsed = pt_normalize_lexical_path(p, lex_buf, sizeof(lex_buf));
        if (collapsed != NULL) {
            p = collapsed;
        }
    }
    return pt_is_clean_virtual_ancestor_dir(p);
}

static _Atomic bool s_has_synth_sysver = false;
static os_unfair_lock s_synth_sysver_lock = OS_UNFAIR_LOCK_INIT;
static char s_synth_sysver_path[PATH_MAX] = {0};
static char s_synth_sysver_ver[32] = {0};
static char s_synth_sysver_build[32] = {0};
static dev_t s_synth_sysver_dev = 0;
static ino_t s_synth_sysver_ino = 0;

static BOOL pt_is_synth_system_version_path(const char *p) {
    if (p == NULL || !atomic_load_explicit(&s_has_synth_sysver, memory_order_acquire) ||
        strstr(p, ".pt_sysver_") == NULL) {
        return NO;
    }
    BOOL match = NO;
    os_unfair_lock_lock(&s_synth_sysver_lock);
    if (s_synth_sysver_path[0] != '\0') {
        const char *rem = pt_match_prefix_modulo_private(p, s_synth_sysver_path, strlen(s_synth_sysver_path));
        match = (rem != NULL && rem[0] == '\0');
    }
    os_unfair_lock_unlock(&s_synth_sysver_lock);
    return match;
}

__attribute__((visibility("hidden")))
const char *pt_virtualize_path_for_app(const char *path, char *buf, size_t bufsize, BOOL use_private_prefix) {
    if (path == NULL || buf == NULL || bufsize == 0) {
        return path;
    }
    pt_ensure_bundle_path_map();
    pt_ensure_data_container_map();
    const char *p = path;
    if (strncmp(p, "/System/Volumes/Data/", 21) == 0) {
        p += 20;
    }
    if (strncmp(p, "/System/iOSSupport/", 19) == 0) {
        p += 18;
    }
    if (pt_is_synth_system_version_path(p)) {
        size_t n = strlcpy(buf, "/System/Library/CoreServices/SystemVersion.plist", bufsize);
        return (n < bufsize) ? buf : path;
    }
    if (s_real_data_container_len > 0) {
        const char *suffix = pt_match_prefix_modulo_private(p, s_real_data_container_dir, s_real_data_container_len);
        if (suffix != NULL) {
            const char *prefix = use_private_prefix ? s_virtual_private_data_dir : s_virtual_var_data_dir;
            size_t plen = use_private_prefix ? s_virtual_private_data_len : s_virtual_var_data_len;
            const char *joined = pt_join_path_fast(buf, bufsize, prefix, plen, suffix);
            return (joined != NULL) ? joined : path;
        }
    }
    if (s_real_app_bundle_len > 0) {
        const char *suffix = pt_match_prefix_modulo_private(p, s_real_app_bundle_dir, s_real_app_bundle_len);
        if (suffix != NULL) {
            const char *prefix = use_private_prefix ? s_virtual_private_bundle_dir : s_virtual_var_bundle_dir;
            size_t plen = use_private_prefix ? s_virtual_private_bundle_len : s_virtual_var_bundle_len;
            const char *joined = pt_join_path_fast(buf, bufsize, prefix, plen, suffix);
            return (joined != NULL) ? joined : path;
        }
    }
    const char *backup_virt = pt_virtualize_app_backup_path(p, buf, bufsize, use_private_prefix);
    if (backup_virt != NULL) {
        return backup_virt;
    }
    const char *group_virt = pt_group_try_virtualize_known_or_root(p, buf, bufsize, use_private_prefix);
    if (group_virt != NULL) {
        return group_virt;
    }
    if (strcasecmp(p, "/System/Library/CoreServices/iOSSystemVersion.plist") == 0) {
        size_t n = strlcpy(buf, "/System/Library/CoreServices/SystemVersion.plist", bufsize);
        return (n < bufsize) ? buf : path;
    }
    if (p != path) {
        size_t n = strlcpy(buf, p, bufsize);
        return (n < bufsize) ? buf : path;
    }
    return path;
}

static BOOL pt_is_sensitive_host_fd_path(const char *path, const void *caller) {
    if (path == NULL || path[0] == '\0' || !pt_is_bypass_enabled()) {
        return NO;
    }
    const char *p = path;
    if (strncmp(p, "/System/Volumes/Data/", 21) == 0) {
        p += 20;
    }
    if (pt_is_active_app_backup_file_path(p) || pt_is_synth_system_version_path(p)) {
        return NO;
    }
    int is_sys_caller = -1;
    if (pt_is_hidden_normalized_path_cached_caller(p, caller, &is_sys_caller)) {
        return YES;
    }
    if (pt_is_hidden_dyld_image_name(p)) {
        return YES;
    }
    pt_ensure_bundle_path_map();
    pt_ensure_data_container_map();
    if (s_real_data_container_len > 0 &&
        pt_match_prefix_modulo_private(p, s_real_data_container_dir, s_real_data_container_len) != NULL) {
        return NO;
    }
    if (s_real_app_bundle_len > 0 &&
        pt_match_prefix_modulo_private(p, s_real_app_bundle_dir, s_real_app_bundle_len) != NULL) {
        return NO;
    }
    if (strncmp(p, "/Library/Application Support/MacOver", 36) == 0 ||
        strncmp(p, "/Library/Application Support/PlayCover", 38) == 0 ||
        strstr(p, "/Library/Containers/app.makedie.") != NULL ||
        strstr(p, "/Library/Preferences/app.makedie.") != NULL ||
        strstr(p, "/Library/Containers/io.playcover.") != NULL ||
        strstr(p, "/Library/Preferences/io.playcover.") != NULL) {
        return YES;
    }
    const char *user_root = pt_get_host_user_root_cstr();
    if (user_root != NULL) {
        size_t ur_len = strlen(user_root);
        if (ur_len > 1 && strncmp(p, user_root, ur_len) == 0 && (p[ur_len] == '/' || p[ur_len] == '\0')) {
            char tmp[PATH_MAX];
            if (pt_group_try_virtualize_known_or_root(p, tmp, sizeof(tmp), YES) != NULL) {
                return NO;
            }
            return YES;
        }
    }
    return NO;
}

// Lock-free write-once fast cache for immortal dyld image string pointers (zero TLV / zero lock on hit).
static _Atomic(const char *) s_img_fast_keys[256];
static _Atomic(const char *) s_img_fast_vals[256];

static inline void pt_img_fast_cache_try_publish(size_t slot, const char *raw_path, const char *sanitized) {
    if (raw_path == NULL || raw_path == (const char *)1 || sanitized == NULL) {
        return;
    }
    const char *expected = NULL;
    if (atomic_compare_exchange_strong_explicit(&s_img_fast_keys[slot],
                                                &expected,
                                                (const char *)1,
                                                memory_order_acq_rel,
                                                memory_order_relaxed)) {
        atomic_store_explicit(&s_img_fast_vals[slot], sanitized, memory_order_relaxed);
        atomic_store_explicit(&s_img_fast_keys[slot], raw_path, memory_order_release);
    }
}

static const char *pt_sanitize_image_path_internal(const char *raw_path, BOOL allow_ptr_cache) {
    if (raw_path == NULL) {
        return NULL;
    }
    uintptr_t raw_u = (uintptr_t)raw_path;
    size_t fast_slot = (size_t)(((raw_u >> 3) ^ (raw_u >> 12)) & 255U);
    if (allow_ptr_cache) {
        const char *k = atomic_load_explicit(&s_img_fast_keys[fast_slot], memory_order_acquire);
        if (k == raw_path) {
            return atomic_load_explicit(&s_img_fast_vals[fast_slot], memory_order_relaxed);
        }
    }

    pt_ensure_bundle_path_map();
    pt_ensure_data_container_map();

    if (allow_ptr_cache) {
        os_unfair_lock_lock(&s_image_path_lock);
        if (s_image_path_ptr_cache != NULL) {
            const void *cached = CFDictionaryGetValue(s_image_path_ptr_cache, raw_path);
            if (cached != NULL) {
                os_unfair_lock_unlock(&s_image_path_lock);
                pt_img_fast_cache_try_publish(fast_slot, raw_path, (const char *)cached);
                return (const char *)cached;
            }
        }
        os_unfair_lock_unlock(&s_image_path_lock);
    }

    const char *p = raw_path;
    if (strncmp(p, "/System/iOSSupport/", 19) == 0) {
        p += 18;
    } else if (strncmp(p, "/System/Volumes/Data/", 21) == 0) {
        p += 20;
    }

    char transformed[PATH_MAX];
    const char *candidate = p;

    const char *bundle_suf = (s_real_app_bundle_len > 0) ? pt_match_prefix_modulo_private(p, s_real_app_bundle_dir, s_real_app_bundle_len) : NULL;
    const char *data_suf = (bundle_suf == NULL && s_real_data_container_len > 0) ? pt_match_prefix_modulo_private(p, s_real_data_container_dir, s_real_data_container_len) : NULL;
    if (bundle_suf != NULL) {
        int n = snprintf(transformed, sizeof(transformed), "%s%s",
                         s_virtual_private_bundle_dir, bundle_suf);
        if (n >= 0 && (size_t)n < sizeof(transformed)) {
            candidate = transformed;
        }
    } else if (data_suf != NULL) {
        int n = snprintf(transformed, sizeof(transformed), "%s%s",
                         s_virtual_private_data_dir, data_suf);
        if (n >= 0 && (size_t)n < sizeof(transformed)) {
            candidate = transformed;
        }
    } else if ((strncmp(p, "/System/", 8) == 0 || strncmp(p, "/Library/", 9) == 0)) {
        const char *fw_ver = strstr(p, ".framework/Versions/");
        if (fw_ver != NULL) {
            const char *ver_dir = fw_ver + 10; // points to "/Versions/..."
            const char *after_versions = ver_dir + 10; // past "/Versions/"
            const char *next_slash = strchr(after_versions, '/');
            if (next_slash != NULL) {
                size_t prefix_len = (size_t)(ver_dir - p);
                if (prefix_len + strlen(next_slash) + 1 < sizeof(transformed)) {
                    memcpy(transformed, p, prefix_len);
                    strcpy(transformed + prefix_len, next_slash);
                    candidate = transformed;
                }
            }
        }
    } else {
        const char *group_virt = pt_group_try_virtualize_known_or_root(p, transformed, sizeof(transformed), YES);
        if (group_virt != NULL) {
            candidate = group_virt;
        }
    }

    os_unfair_lock_lock(&s_image_path_lock);
    if (s_image_path_ptr_cache == NULL) {
        s_image_path_ptr_cache = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
        s_image_path_str_cache = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, NULL);
    }
    const char *interned = NULL;
    if (candidate == raw_path && allow_ptr_cache) {
        interned = raw_path;
    } else {
        CFStringRef keyRef = CFStringCreateWithCString(kCFAllocatorDefault, candidate, kCFStringEncodingUTF8);
        if (keyRef != NULL) {
            const void *existing = CFDictionaryGetValue(s_image_path_str_cache, keyRef);
            if (existing != NULL) {
                interned = (const char *)existing;
            } else if (CFDictionaryGetCount(s_image_path_str_cache) < 4096) {
                char *dup = strdup(candidate);
                if (dup != NULL) {
                    CFDictionarySetValue(s_image_path_str_cache, keyRef, dup);
                    interned = dup;
                }
            }
            CFRelease(keyRef);
        }
        if (interned == NULL) {
            interned = allow_ptr_cache ? p : raw_path;
        }
    }
    if (allow_ptr_cache && CFDictionaryGetCount(s_image_path_ptr_cache) < 4096) {
        CFDictionarySetValue(s_image_path_ptr_cache, raw_path, interned);
        pt_img_fast_cache_try_publish(fast_slot, raw_path, interned);
    }
    os_unfair_lock_unlock(&s_image_path_lock);
    return interned;
}

__attribute__((visibility("hidden")))
const char *pt_sanitize_image_path_for_app(const char *raw_path) {
    return pt_sanitize_image_path_internal(raw_path, YES);
}

__attribute__((visibility("hidden")))
const char *pt_sanitize_image_path_for_cstr(const char *raw_path) {
    return pt_sanitize_image_path_internal(raw_path, NO);
}

__attribute__((visibility("hidden")))
BOOL pt_is_virtual_container_path(const char *path) {
    if (path == NULL || path[0] != '/') {
        return NO;
    }
    char lex_buf[PATH_MAX];
    const char *work = path;
    if (pt_needs_lexical_norm(work)) {
        const char *collapsed = pt_normalize_lexical_path(work, lex_buf, sizeof(lex_buf));
        if (collapsed != NULL) {
            work = collapsed;
        }
    }
    if (strncmp(work, "/var/", 5) != 0 && strncmp(work, "/private/var/", 13) != 0) {
        return NO;
    }
    pt_ensure_bundle_path_map();
    pt_ensure_data_container_map();
    if (s_real_data_container_len > 0) {
        if (s_virtual_var_data_len > 0 &&
            strncmp(work, s_virtual_var_data_dir, s_virtual_var_data_len) == 0 &&
            (work[s_virtual_var_data_len] == '/' || work[s_virtual_var_data_len] == '\0')) {
            return YES;
        }
        if (s_virtual_private_data_len > 0 &&
            strncmp(work, s_virtual_private_data_dir, s_virtual_private_data_len) == 0 &&
            (work[s_virtual_private_data_len] == '/' || work[s_virtual_private_data_len] == '\0')) {
            return YES;
        }
    }
    if (s_real_app_bundle_len > 0) {
        if (s_virtual_private_bundle_len > 0 &&
            strncmp(work, s_virtual_private_bundle_dir, s_virtual_private_bundle_len) == 0 &&
            (work[s_virtual_private_bundle_len] == '/' || work[s_virtual_private_bundle_len] == '\0')) {
            return YES;
        }
        if (s_virtual_var_bundle_len > 0 &&
            strncmp(work, s_virtual_var_bundle_dir, s_virtual_var_bundle_len) == 0 &&
            (work[s_virtual_var_bundle_len] == '/' || work[s_virtual_var_bundle_len] == '\0')) {
            return YES;
        }
    }
    if (pt_lookup_virtual_group_container(work, NULL, 0, NULL)) {
        return YES;
    }
    return NO;
}

static const char *pt_try_map_clean_virtual_container_path(const char *work, char *buf, size_t bufsize) {
    if (work == NULL || buf == NULL || bufsize == 0) {
        return NULL;
    }
    pt_ensure_bundle_path_map();
    pt_ensure_data_container_map();
    if (s_real_data_container_len > 0) {
        if (s_virtual_var_data_len > 0 &&
            strncmp(work, s_virtual_var_data_dir, s_virtual_var_data_len) == 0 &&
            (work[s_virtual_var_data_len] == '/' || work[s_virtual_var_data_len] == '\0')) {
            return pt_join_path_fast(buf, bufsize, s_real_data_container_dir, s_real_data_container_len, work + s_virtual_var_data_len);
        }
        if (s_virtual_private_data_len > 0 &&
            strncmp(work, s_virtual_private_data_dir, s_virtual_private_data_len) == 0 &&
            (work[s_virtual_private_data_len] == '/' || work[s_virtual_private_data_len] == '\0')) {
            return pt_join_path_fast(buf, bufsize, s_real_data_container_dir, s_real_data_container_len, work + s_virtual_private_data_len);
        }
    }
    if (s_real_app_bundle_len > 0) {
        const char *bundle_rel = NULL;
        if (s_virtual_private_bundle_len > 0 &&
            strncmp(work, s_virtual_private_bundle_dir, s_virtual_private_bundle_len) == 0 &&
            (work[s_virtual_private_bundle_len] == '/' || work[s_virtual_private_bundle_len] == '\0')) {
            bundle_rel = work + s_virtual_private_bundle_len;
        } else if (s_virtual_var_bundle_len > 0 &&
                   strncmp(work, s_virtual_var_bundle_dir, s_virtual_var_bundle_len) == 0 &&
                   (work[s_virtual_var_bundle_len] == '/' || work[s_virtual_var_bundle_len] == '\0')) {
            bundle_rel = work + s_virtual_var_bundle_len;
        }
        if (bundle_rel != NULL) {
            if (s_app_info_plist_in_contents && strcmp(bundle_rel, "/Info.plist") == 0) {
                return pt_join_path_fast(buf, bufsize, s_real_app_bundle_dir, s_real_app_bundle_len, "/Contents/Info.plist");
            }
            return pt_join_path_fast(buf, bufsize, s_real_app_bundle_dir, s_real_app_bundle_len, bundle_rel);
        }
    }
    char real_group_dir[PATH_MAX];
    const char *suffix = NULL;
    if (pt_lookup_virtual_group_container(work, real_group_dir, sizeof(real_group_dir), &suffix)) {
        int n = snprintf(buf, bufsize, "%s%s", real_group_dir, (suffix != NULL) ? suffix : "");
        return (n >= 0 && (size_t)n < bufsize) ? buf : NULL;
    }
    return NULL;
}

__attribute__((visibility("hidden"))) BOOL pt_is_reverse_mapped_iossupport(const char *orig_path, const char *resolved_path) {
    if (orig_path == NULL || resolved_path == NULL || orig_path == resolved_path) {
        return NO;
    }
    return (strncmp(resolved_path, "/System/iOSSupport/System/Library/", 36) == 0 &&
            strncmp(orig_path, "/System/iOSSupport", 18) != 0);
}

__attribute__((visibility("hidden")))
const char *pt_resolve_virtual_path(const char *path, char *buf, size_t bufsize) {
    if (path == NULL || buf == NULL || bufsize == 0 || path[0] != '/') {
        return path;
    }
    char lex_buf[PATH_MAX];
    const char *work = path;
    BOOL was_normalized = NO;
    if (pt_needs_lexical_norm(work)) {
        const char *collapsed = pt_normalize_lexical_path(work, lex_buf, sizeof(lex_buf));
        if (collapsed != NULL) {
            work = collapsed;
            was_normalized = YES;
        }
    }
    if (strncmp(work, "/var/", 5) == 0 || strncmp(work, "/private/var/", 13) == 0) {
        const char *mapped = pt_try_map_clean_virtual_container_path(work, buf, bufsize);
        if (mapped != NULL) {
            return mapped;
        }
        if (was_normalized && pt_is_clean_virtual_ancestor_dir(work)) {
            size_t wlen = strlen(work);
            if (wlen < bufsize) {
                memcpy(buf, work, wlen + 1);
                return buf;
            }
        }
        return path;
    }
    if ((strncmp(work, "/System/Library/Frameworks/", 27) == 0 ||
         strncmp(work, "/System/Library/PrivateFrameworks/", 34) == 0) &&
        access(work, F_OK) != 0) {
        int n = snprintf(buf, bufsize, "/System/iOSSupport%s", work);
        if (n > 0 && (size_t)n < bufsize && access(buf, F_OK) == 0) {
            return buf;
        }
    }
    return path;
}

__attribute__((visibility("hidden")))
const char *pt_resolve_virtual_bundle_path(const char *path, char *buf, size_t bufsize) {
    return pt_resolve_virtual_path(path, buf, bufsize);
}


__attribute__((visibility("hidden"))) _Atomic uint8_t ue_status = 0;

static char const* ue_fix_filename(char const* filename) {
    if (filename == NULL || atomic_load_explicit(&ue_status, memory_order_relaxed) != 2) {
        return filename;
    }
    static char UE_PATTERN[1024] = "//Users/";
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        getlogin_r(UE_PATTERN + 8, sizeof(UE_PATTERN) - 8);
    });
    char const* p = filename;
    char const* last_p = p;
    while ((p = strstr(p, UE_PATTERN))) {
        last_p = ++p;
    }
    return last_p;
}

__attribute__((visibility("hidden"))) BOOL pt_fd_is_sensitive(int fd, const void *caller) {
    if (fd < 0 || !pt_is_bypass_enabled()) {
        return NO;
    }
    if (pt_is_effective_system_or_playtools_caller(caller)) {
        return NO;
    }
    char fd_path[PATH_MAX];
    if (fcntl(fd, F_GETPATH, fd_path) == -1) {
        return NO;
    }
    return pt_is_sensitive_host_fd_path(fd_path, caller);
}

static size_t pt_count_path_components(const char *p) {
    size_t count = 0;
    if (p == NULL) {
        return 0;
    }
    while (*p != '\0') {
        while (*p == '/') {
            p++;
        }
        if (*p == '\0') {
            break;
        }
        count++;
        while (*p != '\0' && *p != '/') {
            p++;
        }
    }
    return count;
}

static const char *pt_strip_private_vol_prefix(const char *p) {
    if (p == NULL) {
        return NULL;
    }
    if (strncmp(p, "/System/Volumes/Data/", 21) == 0) {
        p += 20;
    }
    if (strncmp(p, "/private/", 9) == 0) {
        p += 8;
    }
    return p;
}

static void pt_compute_escaped_virtual_ancestor(const char *real_base,
                                                const char *virt_base,
                                                const char *norm_work,
                                                char *vbuf,
                                                size_t vbuf_size) {
    if (vbuf == NULL || vbuf_size == 0) {
        return;
    }
    const char *rb = pt_strip_private_vol_prefix(real_base);
    const char *nw = pt_strip_private_vol_prefix(norm_work);
    size_t common = 0;
    if (rb != NULL && nw != NULL) {
        size_t i = 0;
        while (rb[i] != '\0' && nw[i] != '\0' && rb[i] == nw[i]) {
            if (rb[i] == '/' && i > 0) {
                common = i;
            }
            i++;
        }
        if (rb[i] == '\0' && (nw[i] == '/' || nw[i] == '\0')) {
            common = i;
        } else if (nw[i] == '\0' && (rb[i] == '/' || rb[i] == '\0')) {
            common = i;
        }
    }
    size_t up_levels = (rb != NULL && common < strlen(rb)) ? pt_count_path_components(rb + common) : 1;
    if (up_levels == 0) {
        up_levels = 1;
    }
    strlcpy(vbuf, virt_base, vbuf_size);
    for (size_t k = 0; k < up_levels; k++) {
        char *slash = strrchr(vbuf, '/');
        if (slash == NULL || slash <= vbuf + 12) { // keep at least "/private/var"
            break;
        }
        *slash = '\0';
    }
}

static _Atomic int s_has_ios_sysver_plist = -1;

static BOOL pt_has_ios_system_version_plist(void) {
    int cached = atomic_load_explicit(&s_has_ios_sysver_plist, memory_order_acquire);
    if (cached >= 0) {
        return cached == 1;
    }
    BOOL exists = (access("/System/Library/CoreServices/iOSSystemVersion.plist", F_OK) == 0);
    atomic_store_explicit(&s_has_ios_sysver_plist, exists ? 1 : 0, memory_order_release);
    return exists;
}

static BOOL pt_write_all_fd(int fd, const char *data, size_t len) {
    size_t written = 0;
    while (written < len) {
        ssize_t n = write(fd, data + written, len - written);
        if (n > 0) {
            written += (size_t)n;
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else {
            return NO;
        }
    }
    return YES;
}

static BOOL pt_ensure_synthesized_system_version_plist(const char *ver,
                                                       const char *build,
                                                       char *out_buf,
                                                       size_t out_cap) {
    if (ver == NULL || ver[0] == '\0' || build == NULL || build[0] == '\0' ||
        out_buf == NULL || out_cap == 0) {
        return NO;
    }

    os_unfair_lock_lock(&s_synth_sysver_lock);
    if (s_synth_sysver_path[0] != '\0' &&
        strcmp(s_synth_sysver_ver, ver) == 0 &&
        strcmp(s_synth_sysver_build, build) == 0) {
        pt_enter_internal_scope();
        struct stat st;
        BOOL alive = (stat(s_synth_sysver_path, &st) == 0 &&
                      st.st_dev == s_synth_sysver_dev &&
                      st.st_ino == s_synth_sysver_ino);
        pt_leave_internal_scope();
        if (alive) {
            size_t n = strlcpy(out_buf, s_synth_sysver_path, out_cap);
            os_unfair_lock_unlock(&s_synth_sysver_lock);
            return n < out_cap;
        }
    }

    char xml[1024];
    int xml_len = snprintf(xml, sizeof(xml),
                           "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                           "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
                           "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
                           "<plist version=\"1.0\">\n"
                           "<dict>\n"
                           "\t<key>ProductBuildVersion</key>\n"
                           "\t<string>%s</string>\n"
                           "\t<key>ProductCopyright</key>\n"
                           "\t<string>1983-2025 Apple Inc.</string>\n"
                           "\t<key>ProductName</key>\n"
                           "\t<string>iPhone OS</string>\n"
                           "\t<key>ProductUserVisibleVersion</key>\n"
                           "\t<string>%s</string>\n"
                           "\t<key>ProductVersion</key>\n"
                           "\t<string>%s</string>\n"
                           "</dict>\n"
                           "</plist>\n",
                           build, ver, ver);
    if (xml_len <= 0 || (size_t)xml_len >= sizeof(xml)) {
        os_unfair_lock_unlock(&s_synth_sysver_lock);
        return NO;
    }

    pt_ensure_data_container_map();
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
        size_t elen = strlen(env_tmp_buf);
        while (elen > 1 && env_tmp_buf[elen - 1] == '/') {
            env_tmp_buf[--elen] = '\0';
        }
        dirs[1] = env_tmp_buf;
    }

    BOOL ok = NO;
    char chosen_path[PATH_MAX] = {0};
    struct stat chosen_st;
    memset(&chosen_st, 0, sizeof(chosen_st));
    pid_t pid = getpid();

    pt_enter_internal_scope();
    for (size_t i = 0; i < 3 && !ok; i++) {
        const char *dir = dirs[i];
        if (dir == NULL || dir[0] != '/') {
            continue;
        }
        if (i == 0) {
            (void)mkdir(dir, 0700);
        }
        char target[PATH_MAX];
        char staging[PATH_MAX];
        int tn = snprintf(target, sizeof(target), "%s/.pt_sysver_%d_%s_%s.plist",
                          dir, (int)pid, ver, build);
        int sn = snprintf(staging, sizeof(staging), "%s/.pt_sysver_%d_tmp.plist",
                          dir, (int)pid);
        if (tn <= 0 || (size_t)tn >= sizeof(target) ||
            sn <= 0 || (size_t)sn >= sizeof(staging)) {
            continue;
        }
        int fd = pt_orig_open_nocancel(staging, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
        if (fd < 0) {
            continue;
        }
        BOOL wrote = pt_write_all_fd(fd, xml, (size_t)xml_len);
        (void)close(fd);
        if (wrote && rename(staging, target) == 0 && stat(target, &chosen_st) == 0) {
            strlcpy(chosen_path, target, sizeof(chosen_path));
            ok = YES;
        } else {
            (void)unlink(staging);
        }
    }
    pt_leave_internal_scope();

    if (ok) {
        strlcpy(s_synth_sysver_path, chosen_path, sizeof(s_synth_sysver_path));
        strlcpy(s_synth_sysver_ver, ver, sizeof(s_synth_sysver_ver));
        strlcpy(s_synth_sysver_build, build, sizeof(s_synth_sysver_build));
        s_synth_sysver_dev = chosen_st.st_dev;
        s_synth_sysver_ino = chosen_st.st_ino;
        atomic_store_explicit(&s_has_synth_sysver, 1, memory_order_release);
        size_t n = strlcpy(out_buf, s_synth_sysver_path, out_cap);
        os_unfair_lock_unlock(&s_synth_sysver_lock);
        return n < out_cap;
    }
    os_unfair_lock_unlock(&s_synth_sysver_lock);
    return NO;
}

static pt_fs_path_disposition_t pt_prepare_fs_path_abs_cached_caller(const char *cleaned,
                                                                      const void *caller,
                                                                      char *vbuf,
                                                                      size_t vbuf_size,
                                                                      const char **out_path,
                                                                      int *inout_is_sys_caller,
                                                                      BOOL for_readonly) {
    *out_path = cleaned;
    if (cleaned == NULL || cleaned[0] == '\0') {
        return PT_FS_PATH_NORMAL;
    }

    pt_ensure_bundle_path_map();
    pt_ensure_data_container_map();

    char lex_buf[PATH_MAX];
    const char *norm = cleaned;
    BOOL was_normalized = NO;
    if (cleaned[0] == '/' && pt_needs_lexical_norm(cleaned)) {
        const char *collapsed = pt_normalize_lexical_path(cleaned, lex_buf, sizeof(lex_buf));
        if (collapsed != NULL) {
            norm = collapsed;
            was_normalized = YES;
        }
    }

    if (was_normalized) {
        const char *raw_work = cleaned;
        if (strncmp(raw_work, "/System/Volumes/Data/", 21) == 0) {
            raw_work += 20;
        }
        BOOL started_in_real_data = (s_real_data_container_len > 0 &&
                                     pt_match_prefix_modulo_private(raw_work, s_real_data_container_dir, s_real_data_container_len) != NULL);
        BOOL started_in_real_bundle = (s_real_app_bundle_len > 0 &&
                                       pt_match_prefix_modulo_private(raw_work, s_real_app_bundle_dir, s_real_app_bundle_len) != NULL);
        if (started_in_real_data || started_in_real_bundle) {
            const char *norm_work = norm;
            if (strncmp(norm_work, "/System/Volumes/Data/", 21) == 0) {
                norm_work += 20;
            }
            BOOL escaped_data = (started_in_real_data &&
                                 pt_match_prefix_modulo_private(norm_work, s_real_data_container_dir, s_real_data_container_len) == NULL);
            BOOL escaped_bundle = (started_in_real_bundle &&
                                   pt_match_prefix_modulo_private(norm_work, s_real_app_bundle_dir, s_real_app_bundle_len) == NULL);
            if ((escaped_data || escaped_bundle) && pt_is_bypass_enabled()) {
                if (*inout_is_sys_caller < 0) {
                    *inout_is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
                }
                if (*inout_is_sys_caller == 0) {
                    if (vbuf != NULL && vbuf_size > 0) {
                        if (escaped_data) {
                            pt_compute_escaped_virtual_ancestor(s_real_data_container_dir,
                                                                s_virtual_private_data_dir,
                                                                norm_work, vbuf, vbuf_size);
                        } else {
                            pt_compute_escaped_virtual_ancestor(s_real_app_bundle_dir,
                                                                s_virtual_private_bundle_dir,
                                                                norm_work, vbuf, vbuf_size);
                        }
                        *out_path = vbuf;
                    }
                    return PT_FS_PATH_VIRTUAL_ANCESTOR;
                }
            }
        }
    }

    if (norm[0] == '/' &&
        (strncmp(norm, "/var/", 5) == 0 || strncmp(norm, "/private/var/", 13) == 0)) {
        const char *mapped = pt_try_map_clean_virtual_container_path(norm, vbuf, vbuf_size);
        if (mapped != NULL) {
            *out_path = mapped;
            norm = mapped;
        } else if (pt_is_clean_virtual_ancestor_dir(norm)) {
            if (vbuf != NULL && vbuf_size > 0) {
                strlcpy(vbuf, norm, vbuf_size);
                *out_path = vbuf;
            }
            return PT_FS_PATH_VIRTUAL_ANCESTOR;
        }
    }

    if (for_readonly) {
        const char *backup = pt_lookup_app_backup_redirect_for_caller(
            norm, caller, vbuf, vbuf_size, inout_is_sys_caller);
        if (backup != NULL) {
            *out_path = backup;
            return PT_FS_PATH_NORMAL;
        }
    }

    if (pt_is_nonsensitive_app_or_tmp_path(norm,
                                            s_real_app_bundle_dir,
                                            s_real_app_bundle_len,
                                            s_real_data_container_dir,
                                            s_real_data_container_len)) {
        return PT_FS_PATH_NORMAL;
    }

    if (pt_is_hidden_normalized_path_cached_caller(norm, caller, inout_is_sys_caller)) {
        return PT_FS_PATH_HIDDEN;
    }

    if (for_readonly && pt_is_bypass_enabled() && vbuf != NULL && vbuf_size > 0) {
        const char *sv_norm = norm;
        if (strncasecmp(sv_norm, "/System/Volumes/Data/", 21) == 0) {
            sv_norm += 20;
        }
        if (strcasecmp(sv_norm, "/System/Library/CoreServices/SystemVersion.plist") == 0 ||
            strcasecmp(sv_norm, "/System/Library/CoreServices/iOSSystemVersion.plist") == 0) {
            if (*inout_is_sys_caller < 0) {
                *inout_is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
            }
            if (*inout_is_sys_caller == 0) {
                const char *ov_build = NULL;
                const char *ov_ver = pt_get_reported_ios_version_override(&ov_build);
                if (ov_ver != NULL && ov_build != NULL &&
                    pt_ensure_synthesized_system_version_plist(ov_ver, ov_build, vbuf, vbuf_size)) {
                    *out_path = vbuf;
                    return PT_FS_PATH_NORMAL;
                }
                if (pt_has_ios_system_version_plist()) {
                    strlcpy(vbuf, "/System/Library/CoreServices/iOSSystemVersion.plist", vbuf_size);
                    *out_path = vbuf;
                    return PT_FS_PATH_NORMAL;
                }
            }
        }
    }

    if (norm[0] == '/' && norm[1] == 'S' && strncmp(norm, "/System/Library/", 16) == 0) {
        BOOL is_fw = (strncmp(norm + 16, "Frameworks/", 11) == 0);
        BOOL is_pfw = (!is_fw && strncmp(norm + 16, "PrivateFrameworks/", 18) == 0);
        if (is_fw || is_pfw) {
            size_t nlen = strlen(norm);
            static const char kFwInfoSuffix[] = ".framework/Info.plist";
            static const size_t kFwInfoSuffixLen = sizeof(kFwInfoSuffix) - 1;
            BOOL handled_info = NO;
            if (nlen > kFwInfoSuffixLen &&
                norm[nlen - 1] == 't' &&
                memcmp(norm + nlen - kFwInfoSuffixLen, kFwInfoSuffix, kFwInfoSuffixLen) == 0 &&
                strstr(norm + 16, "/Versions/") == NULL &&
                strstr(norm + 16, "/Resources/") == NULL &&
                access(norm, F_OK) != 0 &&
                vbuf != NULL &&
                vbuf_size > 0) {
                size_t fw_dir_len = nlen - 11; // strip "/Info.plist"
                int n = snprintf(vbuf, vbuf_size, "%.*s/Resources/Info.plist",
                                 (int)fw_dir_len, norm);
                if (n > 0 && (size_t)n < vbuf_size && access(vbuf, F_OK) == 0) {
                    *out_path = vbuf;
                    handled_info = YES;
                } else {
                    n = snprintf(vbuf, vbuf_size, "/System/iOSSupport%.*s/Resources/Info.plist",
                                 (int)fw_dir_len, norm);
                    if (n > 0 && (size_t)n < vbuf_size && access(vbuf, F_OK) == 0) {
                        *out_path = vbuf;
                        handled_info = YES;
                    }
                }
            }
            if (!handled_info && vbuf != NULL && vbuf_size > 0 && access(norm, F_OK) != 0) {
                int n = snprintf(vbuf, vbuf_size, "/System/iOSSupport%s", norm);
                if (n > 0 && (size_t)n < vbuf_size && access(vbuf, F_OK) == 0) {
                    *out_path = vbuf;
                }
            }
        }
    }

    return PT_FS_PATH_NORMAL;
}

static pt_fs_path_disposition_t pt_prepare_fs_path_at_cached_caller(int dirfd,
                                                                     const char *raw_path,
                                                                     const void *caller,
                                                                     char *vbuf,
                                                                     size_t vbuf_size,
                                                                     const char **out_path,
                                                                     int *inout_is_sys_caller,
                                                                     BOOL for_readonly) {
    const char *cleaned = ue_fix_filename(raw_path);
    *out_path = cleaned;
    if (cleaned == NULL || cleaned[0] == '\0' ||
        !atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return PT_FS_PATH_NORMAL;
    }
    if (cleaned[0] != '/') {
        if (dirfd == AT_FDCWD) {
            if (*inout_is_sys_caller < 0) {
                *inout_is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
            }
            if (*inout_is_sys_caller == 1 && strstr(cleaned, "Info.plist") == NULL) {
                return PT_FS_PATH_NORMAL;
            }
        }
        static _Thread_local int tls_rel_resolve = 0;
        if (tls_rel_resolve == 0) {
            tls_rel_resolve = 1;
            char base_dir[PATH_MAX];
            base_dir[0] = '\0';
            if (dirfd >= 0 && dirfd != AT_FDCWD) {
                if (fcntl(dirfd, F_GETPATH, base_dir) == -1) {
                    base_dir[0] = '\0';
                }
            } else {
                int cfd = pt_orig_open_nocancel(".", O_RDONLY | O_DIRECTORY);
                if (cfd < 0) {
                    cfd = pt_orig_open_nocancel(".", O_RDONLY);
                }
                if (cfd >= 0) {
                    if (fcntl(cfd, F_GETPATH, base_dir) == -1) {
                        base_dir[0] = '\0';
                    }
                    close(cfd);
                }
            }
            if (base_dir[0] == '/') {
                const char *base_use = base_dir;
                if (strncmp(base_use, "/System/Volumes/Data/", 21) == 0) {
                    base_use += 20;
                }
                char rel_abs[PATH_MAX];
                int n = snprintf(rel_abs, sizeof(rel_abs), "%s/%s",
                                 (strcmp(base_use, "/") == 0) ? "" : base_use, cleaned);
                if (n > 0 && (size_t)n < sizeof(rel_abs)) {
                    const char *resolved_out = NULL;
                    pt_fs_path_disposition_t disp = pt_prepare_fs_path_abs_cached_caller(rel_abs,
                                                                                         caller,
                                                                                         vbuf,
                                                                                         vbuf_size,
                                                                                         &resolved_out,
                                                                                         inout_is_sys_caller,
                                                                                         for_readonly);
                    tls_rel_resolve = 0;
                    if (disp != PT_FS_PATH_NORMAL) {
                        if (resolved_out != rel_abs) {
                            *out_path = resolved_out;
                        }
                        return disp;
                    }
                    if (resolved_out != rel_abs) {
                        *out_path = resolved_out;
                    }
                    return PT_FS_PATH_NORMAL;
                }
            }
            tls_rel_resolve = 0;
        }
    }
    return pt_prepare_fs_path_abs_cached_caller(cleaned, caller, vbuf, vbuf_size, out_path, inout_is_sys_caller, for_readonly);
}

__attribute__((visibility("hidden"))) pt_fs_path_disposition_t pt_prepare_fs_path_cached_caller(const char *raw_path,
                                                                         const void *caller,
                                                                         char *vbuf,
                                                                         size_t vbuf_size,
                                                                         const char **out_path,
                                                                         int *inout_is_sys_caller) {
    return pt_prepare_fs_path_at_cached_caller(AT_FDCWD, raw_path, caller, vbuf, vbuf_size, out_path, inout_is_sys_caller, NO);
}

static inline pt_fs_path_disposition_t pt_prepare_fs_path_cached_caller_ro(const char *raw_path,
                                                                           const void *caller,
                                                                           char *vbuf,
                                                                           size_t vbuf_size,
                                                                           const char **out_path,
                                                                           int *inout_is_sys_caller) {
    return pt_prepare_fs_path_at_cached_caller(AT_FDCWD, raw_path, caller, vbuf, vbuf_size, out_path, inout_is_sys_caller, YES);
}

static inline BOOL pt_open_flags_are_readonly(int oflag) {
    return ((oflag & O_ACCMODE) == O_RDONLY) &&
           ((oflag & (O_CREAT | O_TRUNC | O_APPEND | O_EXCL)) == 0);
}

static inline BOOL pt_fopen_mode_is_readonly(const char *mode) {
    return mode != NULL && mode[0] == 'r' && strchr(mode, '+') == NULL;
}

static inline pt_fs_path_disposition_t pt_prepare_fs_path_mode(const char *raw_path,
                                                                const void *caller,
                                                                char *vbuf,
                                                                size_t vbuf_size,
                                                                const char **out_path,
                                                                BOOL for_readonly) {
    int is_sys_caller = -1;
    return pt_prepare_fs_path_at_cached_caller(AT_FDCWD, raw_path, caller, vbuf, vbuf_size, out_path, &is_sys_caller, for_readonly);
}

static inline pt_fs_path_disposition_t pt_prepare_fs_path(const char *raw_path,
                                                          const void *caller,
                                                          char *vbuf,
                                                          size_t vbuf_size,
                                                          const char **out_path) {
    return pt_prepare_fs_path_mode(raw_path, caller, vbuf, vbuf_size, out_path, NO);
}

static inline pt_fs_path_disposition_t pt_prepare_fs_path_ro(const char *raw_path,
                                                             const void *caller,
                                                             char *vbuf,
                                                             size_t vbuf_size,
                                                             const char **out_path) {
    return pt_prepare_fs_path_mode(raw_path, caller, vbuf, vbuf_size, out_path, YES);
}

static inline pt_fs_path_disposition_t pt_prepare_fs_path_at_mode(int dirfd,
                                                                   const char *raw_path,
                                                                   const void *caller,
                                                                   char *vbuf,
                                                                   size_t vbuf_size,
                                                                   const char **out_path,
                                                                   BOOL for_readonly) {
    int is_sys_caller = -1;
    return pt_prepare_fs_path_at_cached_caller(dirfd, raw_path, caller, vbuf, vbuf_size, out_path, &is_sys_caller, for_readonly);
}

static inline pt_fs_path_disposition_t pt_prepare_fs_path_at(int dirfd,
                                                             const char *raw_path,
                                                             const void *caller,
                                                             char *vbuf,
                                                             size_t vbuf_size,
                                                             const char **out_path) {
    return pt_prepare_fs_path_at_mode(dirfd, raw_path, caller, vbuf, vbuf_size, out_path, NO);
}

static inline pt_fs_path_disposition_t pt_prepare_fs_path_at_ro(int dirfd,
                                                                const char *raw_path,
                                                                const void *caller,
                                                                char *vbuf,
                                                                size_t vbuf_size,
                                                                const char **out_path) {
    return pt_prepare_fs_path_at_mode(dirfd, raw_path, caller, vbuf, vbuf_size, out_path, YES);
}

static inline BOOL pt_is_hidden_dirent_name(const char *d_name) {
    if (d_name == NULL || d_name[0] == '\0') {
        return NO;
    }
    if (strncmp(d_name, "discord-ipc-", 12) == 0 ||
        strncmp(d_name, ".pt_sysver_", 11) == 0) {
        return YES;
    }
    if (strstr(d_name, "Play") != NULL &&
        (strstr(d_name, "PlayTools") != NULL ||
         strstr(d_name, "Playtools.strings") != NULL ||
         strstr(d_name, "io.playcover.PlayCover") != NULL)) {
        return YES;
    }
    if (strstr(d_name, "app.makedie.MacOver") != NULL ||
        strstr(d_name, "MacOver.app") != NULL ||
        strstr(d_name, "AKInterface") != NULL ||
        strstr(d_name, "UserPlugins") != NULL ||
        pt_is_registered_hidden_module(d_name)) {
        return YES;
    }
    if (pt_is_bypass_enabled() &&
        (strcmp(d_name, ".CFUserTextEncoding") == 0 ||
         strcmp(d_name, "Saved Application State") == 0 ||
         strstr(d_name, "~iosmac.savedState") != NULL)) {
        return YES;
    }
    return NO;
}

static int pt_stat_virtual_ancestor(struct stat *buf) {
    pt_ensure_data_container_map();
    const char *backing = (s_real_data_container_len > 0) ? s_real_data_container_dir : "/private/var";
    int rc = stat(backing, buf);
    if (rc == 0 && buf != NULL) {
        buf->st_mode = (buf->st_mode & ~S_IFMT) | S_IFDIR;
        buf->st_mode &= ~(S_IWUSR | S_IWGRP | S_IWOTH);
    }
    return rc;
}

__attribute__((visibility("hidden")))
int pt_fs_open_with_caller(const char *filename, int oflag, mode_t mode, const void *caller) {
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_mode(filename,
                                                            caller,
                                                            vbuf,
                                                            sizeof(vbuf),
                                                            &resolved,
                                                            pt_open_flags_are_readonly(oflag));
    if (disp == PT_FS_PATH_HIDDEN) {
        PT_DEBUG_TRACE("fs", "hid open path=%s", filename != NULL ? filename : "<null>");
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        PT_DEBUG_TRACE("fs", "virtual-ancestor open path=%s", filename != NULL ? filename : "<null>");
        errno = (oflag & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC)) ? EACCES : EPERM;
        return -1;
    }
    if (resolved == NULL) {
        errno = EFAULT;
        return -1;
    }
    if (filename != NULL && resolved != filename) {
        PT_DEBUG_TRACE("fs", "redirected open %s -> %s", filename, resolved);
    }
    if (oflag & O_CREAT) {
        return open(resolved, oflag, (int)mode);
    }
    return open(resolved, oflag);
}

static int pt_open(char const* restrict filename, int oflag, ... ) {
    mode_t mode = 0;
    if (oflag & O_CREAT) {
        va_list ap;
        va_start(ap, oflag);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return pt_fs_open_with_caller(filename, oflag, mode, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_fs_openat_with_caller(int fd, const char *path, int oflag, mode_t mode, const void *caller) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_at_mode(fd,
                                                               path,
                                                               caller,
                                                               vbuf,
                                                               sizeof(vbuf),
                                                               &path,
                                                               pt_open_flags_are_readonly(oflag));
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = (oflag & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC)) ? EACCES : EPERM;
        return -1;
    }
    if (oflag & O_CREAT) {
        return openat(fd, path, oflag, (int)mode);
    }
    return openat(fd, path, oflag);
}

static int pt_openat(int fd, const char *path, int oflag, ...) {
    mode_t mode = 0;
    if (oflag & O_CREAT) {
        va_list ap;
        va_start(ap, oflag);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    return pt_fs_openat_with_caller(fd, path, oflag, mode, __builtin_return_address(0));
}

static int pt_creat(const char *path, mode_t mode) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path(path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EACCES;
        return -1;
    }
    return creat(path, mode);
}

extern int pt_orig_open_nocancel(const char *, int, ...) __asm("_open$NOCANCEL");
extern int pt_orig_openat_nocancel(int, const char *, int, ...) __asm("_openat$NOCANCEL");
extern int pt_orig_creat_nocancel(const char *, mode_t) __asm("_creat$NOCANCEL");

static int pt_open_nocancel(char const* restrict filename, int oflag, ...) {
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_mode(filename,
                                                            __builtin_return_address(0),
                                                            vbuf,
                                                            sizeof(vbuf),
                                                            &resolved,
                                                            pt_open_flags_are_readonly(oflag));
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = (oflag & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC)) ? EACCES : EPERM;
        return -1;
    }
    if (oflag & O_CREAT) {
        va_list ap;
        va_start(ap, oflag);
        int mod = va_arg(ap, int);
        va_end(ap);
        return pt_orig_open_nocancel(resolved, oflag, mod);
    }
    return pt_orig_open_nocancel(resolved, oflag);
}

static int pt_openat_nocancel(int fd, const char *path, int oflag, ...) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_at_mode(fd,
                                                               path,
                                                               __builtin_return_address(0),
                                                               vbuf,
                                                               sizeof(vbuf),
                                                               &path,
                                                               pt_open_flags_are_readonly(oflag));
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = (oflag & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC)) ? EACCES : EPERM;
        return -1;
    }
    if (oflag & O_CREAT) {
        va_list ap;
        va_start(ap, oflag);
        int mod = va_arg(ap, int);
        va_end(ap);
        return pt_orig_openat_nocancel(fd, path, oflag, mod);
    }
    return pt_orig_openat_nocancel(fd, path, oflag);
}

static int pt_creat_nocancel(const char *path, mode_t mode) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path(path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EACCES;
        return -1;
    }
    return pt_orig_creat_nocancel(path, mode);
}

static int pt_open_dprotected_np(const char *path, int flags, int dpclass, int dpflags, ...) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_mode(path,
                                                            __builtin_return_address(0),
                                                            vbuf,
                                                            sizeof(vbuf),
                                                            &path,
                                                            pt_open_flags_are_readonly(flags));
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = (flags & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC)) ? EACCES : EPERM;
        return -1;
    }
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, dpflags);
        int mode = va_arg(ap, int);
        va_end(ap);
        return open_dprotected_np(path, flags, dpclass, dpflags, mode);
    }
    return open_dprotected_np(path, flags, dpclass, dpflags);
}

static int pt_openat_dprotected_np(int fd, const char *path, int flags, int dpclass, int dpflags, ...) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_at_mode(fd,
                                                               path,
                                                               __builtin_return_address(0),
                                                               vbuf,
                                                               sizeof(vbuf),
                                                               &path,
                                                               pt_open_flags_are_readonly(flags));
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = (flags & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC)) ? EACCES : EPERM;
        return -1;
    }
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, dpflags);
        int mode = va_arg(ap, int);
        va_end(ap);
        return openat_dprotected_np(fd, path, flags, dpclass, dpflags, mode);
    }
    return openat_dprotected_np(fd, path, flags, dpclass, dpflags);
}

typedef uint64_t pt_guardid_t;
extern int guarded_open_np(const char *path, const pt_guardid_t *guard, u_int guardflags, int flags, ...);
extern int guarded_open_dprotected_np(const char *path, const pt_guardid_t *guard, u_int guardflags, int flags, int dpclass, int dpflags, ...);

static int pt_guarded_open_np(const char *path, const pt_guardid_t *guard, u_int guardflags, int flags, ...) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_mode(path,
                                                            __builtin_return_address(0),
                                                            vbuf,
                                                            sizeof(vbuf),
                                                            &path,
                                                            pt_open_flags_are_readonly(flags));
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = (flags & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC)) ? EACCES : EPERM;
        return -1;
    }
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        int mode = va_arg(ap, int);
        va_end(ap);
        return guarded_open_np(path, guard, guardflags, flags, mode);
    }
    return guarded_open_np(path, guard, guardflags, flags);
}

static int pt_guarded_open_dprotected_np(const char *path, const pt_guardid_t *guard, u_int guardflags, int flags, int dpclass, int dpflags, ...) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_mode(path,
                                                            __builtin_return_address(0),
                                                            vbuf,
                                                            sizeof(vbuf),
                                                            &path,
                                                            pt_open_flags_are_readonly(flags));
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = (flags & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC)) ? EACCES : EPERM;
        return -1;
    }
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, dpflags);
        int mode = va_arg(ap, int);
        va_end(ap);
        return guarded_open_dprotected_np(path, guard, guardflags, flags, dpclass, dpflags, mode);
    }
    return guarded_open_dprotected_np(path, guard, guardflags, flags, dpclass, dpflags);
}

extern FILE *pt_orig_fopen_darwin_extsn(const char *, const char *) __asm("_fopen$DARWIN_EXTSN");

static FILE *pt_fopen(const char *filename, const char *mode) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_mode(filename,
                                                            __builtin_return_address(0),
                                                            vbuf,
                                                            sizeof(vbuf),
                                                            &filename,
                                                            pt_fopen_mode_is_readonly(mode));
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return NULL;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return NULL;
    }
    return fopen(filename, mode);
}

static FILE *pt_fopen_darwin_extsn(const char *filename, const char *mode) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_mode(filename,
                                                            __builtin_return_address(0),
                                                            vbuf,
                                                            sizeof(vbuf),
                                                            &filename,
                                                            pt_fopen_mode_is_readonly(mode));
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return NULL;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return NULL;
    }
    return pt_orig_fopen_darwin_extsn(filename, mode);
}

static FILE *pt_freopen(const char *filename, const char *mode, FILE *stream) {
    char vbuf[PATH_MAX];
    if (filename != NULL) {
        pt_fs_path_disposition_t disp = pt_prepare_fs_path_mode(filename,
                                                                __builtin_return_address(0),
                                                                vbuf,
                                                                sizeof(vbuf),
                                                                &filename,
                                                                pt_fopen_mode_is_readonly(mode));
        if (disp == PT_FS_PATH_HIDDEN) {
            errno = ENOENT;
            return NULL;
        }
        if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
            errno = EPERM;
            return NULL;
        }
    }
    return freopen(filename, mode, stream);
}

__attribute__((visibility("hidden")))
int pt_fs_stat_with_caller(const char *path, struct stat *buf, BOOL follow_symlinks, const void *caller) {
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_ro(path, caller, vbuf, sizeof(vbuf), &resolved);
    if (disp == PT_FS_PATH_HIDDEN) {
        PT_DEBUG_TRACE("fs", "hid %s path=%s", follow_symlinks ? "stat" : "lstat", path != NULL ? path : "<null>");
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        PT_DEBUG_TRACE("fs", "virtual-ancestor %s path=%s", follow_symlinks ? "stat" : "lstat", path != NULL ? path : "<null>");
        return pt_stat_virtual_ancestor(buf);
    }
    if (resolved == NULL) {
        errno = EFAULT;
        return -1;
    }
    if (path != NULL && resolved != path) {
        PT_DEBUG_TRACE("fs", "redirected %s %s -> %s", follow_symlinks ? "stat" : "lstat", path, resolved);
    }
    return follow_symlinks ? stat(resolved, buf) : lstat(resolved, buf);
}

static int pt_stat(char const* restrict path, struct stat* restrict buf) {
    return pt_fs_stat_with_caller(path, buf, YES, __builtin_return_address(0));
}

static int pt_lstat(char const* restrict path, struct stat* restrict buf) {
    return pt_fs_stat_with_caller(path, buf, NO, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_fs_fstatat_with_caller(int fd, const char *path, struct stat *buf, int flag, const void *caller) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_at_ro(fd, path, caller, vbuf, sizeof(vbuf), &path);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        return pt_stat_virtual_ancestor(buf);
    }
    return fstatat(fd, path, buf, flag);
}

static int pt_fstatat(int fd, const char *path, struct stat *buf, int flag) {
    return pt_fs_fstatat_with_caller(fd, path, buf, flag, __builtin_return_address(0));
}

static int pt_statx_np(const char *path, struct stat *buf, filesec_t fsec) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_ro(path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        return pt_stat_virtual_ancestor(buf);
    }
    return statx_np(path, buf, fsec);
}

static int pt_lstatx_np(const char *path, struct stat *buf, filesec_t fsec) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_ro(path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        return pt_stat_virtual_ancestor(buf);
    }
    return lstatx_np(path, buf, fsec);
}

__attribute__((visibility("hidden")))
int pt_fs_access_with_caller(const char *path, int mode, const void *caller) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_mode(path,
                                                            caller,
                                                            vbuf,
                                                            sizeof(vbuf),
                                                            &path,
                                                            (mode & W_OK) == 0);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        if (mode & W_OK) {
            errno = EACCES;
            return -1;
        }
        return 0;
    }
    return access(path, mode);
}

static int pt_access(char const* path, int mode) {
    return pt_fs_access_with_caller(path, mode, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_fs_faccessat_with_caller(int fd, const char *path, int mode, int flag, const void *caller) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_at_mode(fd,
                                                               path,
                                                               caller,
                                                               vbuf,
                                                               sizeof(vbuf),
                                                               &path,
                                                               (mode & W_OK) == 0);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        if (mode & W_OK) {
            errno = EACCES;
            return -1;
        }
        return 0;
    }
    return faccessat(fd, path, mode, flag);
}

static int pt_faccessat(int fd, const char *path, int mode, int flag) {
    return pt_fs_faccessat_with_caller(fd, path, mode, flag, __builtin_return_address(0));
}

static ssize_t pt_finish_readlink(ssize_t len,
                                  char *raw_buf,
                                  char * restrict buf,
                                  size_t bufsize,
                                  const void *caller) {
    if (len < 0) {
        return -1;
    }
    raw_buf[len] = '\0';
    const char *out_path = raw_buf;
    size_t out_len = (size_t)len;
    char vout[PATH_MAX];
    if (!pt_is_effective_system_or_playtools_caller(caller)) {
        if ((raw_buf[0] == '/' && pt_is_sensitive_host_fd_path(raw_buf, caller)) ||
            pt_is_hidden_dyld_image_name(raw_buf)) {
            errno = ENOENT;
            return -1;
        }
        const char *virt = pt_virtualize_path_for_app(raw_buf, vout, sizeof(vout), NO);
        if (virt != raw_buf) {
            out_path = virt;
            out_len = strlen(virt);
        }
    }
    size_t copy_len = out_len < bufsize ? out_len : bufsize;
    memcpy(buf, out_path, copy_len);
    return (ssize_t)copy_len;
}

__attribute__((visibility("hidden")))
ssize_t pt_fs_readlink_with_caller(const char *path, char *buf, size_t bufsize, const void *caller) {
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path(path, caller, vbuf, sizeof(vbuf), &resolved);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EINVAL;
        return -1;
    }
    if (buf == NULL) {
        errno = EFAULT;
        return -1;
    }
    if (bufsize == 0) {
        return readlink(resolved, buf, 0);
    }
    char raw_buf[PATH_MAX];
    ssize_t len = readlink(resolved, raw_buf, sizeof(raw_buf) - 1);
    return pt_finish_readlink(len, raw_buf, buf, bufsize, caller);
}

static ssize_t pt_readlink(const char * restrict path, char * restrict buf, size_t bufsize) {
    return pt_fs_readlink_with_caller(path, buf, bufsize, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
ssize_t pt_fs_readlinkat_with_caller(int fd, const char *path, char *buf, size_t bufsize, const void *caller) {
    if (pt_fd_is_sensitive(fd, caller)) {
        errno = ENOENT;
        return -1;
    }
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_at(fd, path, caller, vbuf, sizeof(vbuf), &resolved);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EINVAL;
        return -1;
    }
    if (buf == NULL || bufsize == 0) {
        return readlinkat(fd, resolved, buf, bufsize);
    }
    char raw_buf[PATH_MAX];
    ssize_t len = readlinkat(fd, resolved, raw_buf, sizeof(raw_buf) - 1);
    return pt_finish_readlink(len, raw_buf, buf, bufsize, caller);
}

static ssize_t pt_readlinkat(int fd, const char * restrict path, char * restrict buf, size_t bufsize) {
    return pt_fs_readlinkat_with_caller(fd, path, buf, bufsize, __builtin_return_address(0));
}

extern char *pt_orig_realpath_legacy(const char *, char *) __asm("_realpath");

static char *pt_realpath_common(const char * restrict file_name,
                                char * restrict resolved_name,
                                const void *caller,
                                char *(*orig_fn)(const char *, char *)) {
    int is_sys_caller = -1;
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller_ro(file_name, caller, vbuf, sizeof(vbuf), &resolved, &is_sys_caller);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return NULL;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        char canon[PATH_MAX];
        if (strncmp(resolved, "/private/", 9) == 0 || strcmp(resolved, "/private") == 0) {
            strlcpy(canon, resolved, sizeof(canon));
        } else if (strncmp(resolved, "/var/", 5) == 0 || strcmp(resolved, "/var") == 0) {
            snprintf(canon, sizeof(canon), "/private%s", resolved);
        } else {
            char anc_vout[PATH_MAX];
            const char *virt_anc = pt_virtualize_path_for_app(resolved, anc_vout, sizeof(anc_vout), YES);
            if (strncmp(virt_anc, "/var/", 5) == 0 || strcmp(virt_anc, "/var") == 0) {
                snprintf(canon, sizeof(canon), "/private%s", virt_anc);
            } else if (pt_is_sensitive_host_fd_path(virt_anc, caller)) {
                strlcpy(canon, "/private/var/mobile", sizeof(canon));
            } else {
                strlcpy(canon, virt_anc, sizeof(canon));
            }
        }
        size_t clen = strlen(canon);
        while (clen > 1 && canon[clen - 1] == '/') {
            canon[--clen] = '\0';
        }
        if (resolved_name != NULL) {
            strlcpy(resolved_name, canon, PATH_MAX);
            return resolved_name;
        }
        return strdup(canon);
    }
    if (is_sys_caller < 0) {
        is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
    }
    BOOL is_virtual_in = (resolved == vbuf);
    if (is_sys_caller == 0 || is_virtual_in) {
        char tmp_resolved[PATH_MAX];
        char *res = orig_fn(resolved, tmp_resolved);
        if (res == NULL) {
            return NULL;
        }
        if (is_sys_caller == 0 && pt_is_sensitive_host_fd_path(tmp_resolved, caller)) {
            errno = ENOENT;
            return NULL;
        }
        char vout[PATH_MAX];
        const char *virt = pt_virtualize_path_for_app(tmp_resolved, vout, sizeof(vout), YES);
        if (resolved_name != NULL) {
            strlcpy(resolved_name, virt, PATH_MAX);
            return resolved_name;
        }
        return strdup(virt);
    }
    return orig_fn(resolved, resolved_name);
}

static char *pt_realpath(const char * restrict file_name, char * restrict resolved_name) {
    return pt_realpath_common(file_name, resolved_name, __builtin_return_address(0), realpath);
}

static char *pt_realpath_legacy(const char * restrict file_name, char * restrict resolved_name) {
    return pt_realpath_common(file_name, resolved_name, __builtin_return_address(0), pt_orig_realpath_legacy);
}

static char *pt_getcwd(char *buf, size_t size) {
    const void *caller = __builtin_return_address(0);
    if (buf != NULL && size == 0) {
        errno = EINVAL;
        return NULL;
    }
    char raw_buf[PATH_MAX];
    if (getcwd(raw_buf, sizeof(raw_buf)) == NULL) {
        return NULL;
    }
    const char *out_path = raw_buf;
    char vout[PATH_MAX];
    if (!pt_is_effective_system_or_playtools_caller(caller)) {
        out_path = pt_virtualize_path_for_app(raw_buf, vout, sizeof(vout), YES);
    }
    size_t need = strlen(out_path) + 1;
    if (buf != NULL) {
        if (need > size) {
            errno = ERANGE;
            return NULL;
        }
        memcpy(buf, out_path, need);
        return buf;
    }
    if (size == 0) {
        return strdup(out_path);
    }
    if (need > size) {
        errno = ERANGE;
        return NULL;
    }
    char *alloc = (char *)malloc(size);
    if (alloc == NULL) {
        return NULL;
    }
    memcpy(alloc, out_path, need);
    return alloc;
}

static int pt_chdir(const char *path) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path(path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return -1;
    }
    return chdir(path);
}

static int pt_fchdir(int fd) {
    if (pt_fd_is_sensitive(fd, __builtin_return_address(0))) {
        errno = EACCES;
        return -1;
    }
    return fchdir(fd);
}

static int pt_handle_fcntl_getpath(int ret, int cmd, void *parg, const void *caller) {
    if (ret != -1 && parg != NULL &&
        (cmd == F_GETPATH
#ifdef F_GETPATH_MTMINFO
         || cmd == F_GETPATH_MTMINFO
#endif
#ifdef F_GETPATH_NOFIRMLINK
         || cmd == F_GETPATH_NOFIRMLINK
#endif
         )) {
        char *pathbuf = (char *)parg;
        if (!pt_is_effective_system_or_playtools_caller(caller)) {
            if (pt_is_sensitive_host_fd_path(pathbuf, caller)) {
                pathbuf[0] = '\0';
                errno = EBADF;
                return -1;
            }
            char vout[PATH_MAX];
            const char *virt = pt_virtualize_path_for_app(pathbuf, vout, sizeof(vout), YES);
            if (virt != pathbuf) {
                strlcpy(pathbuf, virt, MAXPATHLEN);
            }
        }
    }
    return ret;
}

__attribute__((visibility("hidden")))
int pt_fs_fcntl_with_caller(int fd, int cmd, uintptr_t arg, const void *caller) {
    switch (cmd) {
        case F_GETFD:
        case F_GETFL:
        case F_GETOWN:
        case F_FLUSH_DATA:
        case F_CHKCLEAN:
        case F_FULLFSYNC:
        case F_FREEZE_FS:
        case F_THAW_FS:
        case F_GETPROTECTIONCLASS:
        case F_GETNOSIGPIPE:
        case F_GETPROTECTIONLEVEL:
        case F_BARRIERFSYNC:
#ifdef F_GETLEASE
        case F_GETLEASE:
#endif
            return fcntl(fd, cmd);

        case F_DUPFD:
        case F_DUPFD_CLOEXEC:
#ifdef F_DUPFD_CLOFORK
        case F_DUPFD_CLOFORK:
#endif
        {
            int ret = fcntl(fd, cmd, (int)arg);
            if (ret >= 0) {
                pt_network_notify_fd_dup(fd, ret);
            }
            return ret;
        }
        case F_SETFD:
        case F_SETFL:
        case F_SETOWN:
        case F_RDAHEAD:
        case F_NOCACHE:
        case F_GLOBAL_NOCACHE:
        case F_NODIRECT:
        case F_SETPROTECTIONCLASS:
        case F_SETBACKINGSTORE:
        case F_SETNOSIGPIPE:
        case F_SINGLE_WRITER:
#ifdef F_SETLEASE
        case F_SETLEASE:
#endif
#ifdef F_NOCACHE_EXT
        case F_NOCACHE_EXT:
#endif
            return fcntl(fd, cmd, (int)arg);

        case F_SETSIZE:
            return fcntl(fd, cmd, (off_t)arg);

        default: {
            void *parg = (void *)arg;
            int ret = fcntl(fd, cmd, parg);
            return pt_handle_fcntl_getpath(ret, cmd, parg, caller);
        }
    }
}

static int pt_fcntl(int fd, int cmd, ...) {
    switch (cmd) {
        case F_GETFD:
        case F_GETFL:
        case F_GETOWN:
        case F_FLUSH_DATA:
        case F_CHKCLEAN:
        case F_FULLFSYNC:
        case F_FREEZE_FS:
        case F_THAW_FS:
        case F_GETPROTECTIONCLASS:
        case F_GETNOSIGPIPE:
        case F_GETPROTECTIONLEVEL:
        case F_BARRIERFSYNC:
#ifdef F_GETLEASE
        case F_GETLEASE:
#endif
            return fcntl(fd, cmd);

        case F_DUPFD:
        case F_DUPFD_CLOEXEC:
#ifdef F_DUPFD_CLOFORK
        case F_DUPFD_CLOFORK:
#endif
        {
            va_list ap;
            va_start(ap, cmd);
            int iarg = va_arg(ap, int);
            va_end(ap);
            int ret = fcntl(fd, cmd, iarg);
            if (ret >= 0) {
                pt_network_notify_fd_dup(fd, ret);
            }
            return ret;
        }
        case F_SETFD:
        case F_SETFL:
        case F_SETOWN:
        case F_RDAHEAD:
        case F_NOCACHE:
        case F_GLOBAL_NOCACHE:
        case F_NODIRECT:
        case F_SETPROTECTIONCLASS:
        case F_SETBACKINGSTORE:
        case F_SETNOSIGPIPE:
        case F_SINGLE_WRITER:
#ifdef F_SETLEASE
        case F_SETLEASE:
#endif
#ifdef F_NOCACHE_EXT
        case F_NOCACHE_EXT:
#endif
        {
            va_list ap;
            va_start(ap, cmd);
            int iarg = va_arg(ap, int);
            va_end(ap);
            return fcntl(fd, cmd, iarg);
        }

        case F_SETSIZE:
        {
            va_list ap;
            va_start(ap, cmd);
            off_t oarg = va_arg(ap, off_t);
            va_end(ap);
            return fcntl(fd, cmd, oarg);
        }

        default:
        {
            va_list ap;
            va_start(ap, cmd);
            void *parg = va_arg(ap, void *);
            va_end(ap);
            int ret = fcntl(fd, cmd, parg);
            return pt_handle_fcntl_getpath(ret, cmd, parg, __builtin_return_address(0));
        }
    }
}

extern int pt_orig_fcntl_nocancel(int, int, ...) __asm("_fcntl$NOCANCEL");

static int pt_fcntl_nocancel(int fd, int cmd, ...) {
    switch (cmd) {
        case F_GETFD:
        case F_GETFL:
        case F_GETOWN:
        case F_FLUSH_DATA:
        case F_CHKCLEAN:
        case F_FULLFSYNC:
        case F_FREEZE_FS:
        case F_THAW_FS:
        case F_GETPROTECTIONCLASS:
        case F_GETNOSIGPIPE:
        case F_GETPROTECTIONLEVEL:
        case F_BARRIERFSYNC:
#ifdef F_GETLEASE
        case F_GETLEASE:
#endif
            return pt_orig_fcntl_nocancel(fd, cmd);

        case F_DUPFD:
        case F_DUPFD_CLOEXEC:
#ifdef F_DUPFD_CLOFORK
        case F_DUPFD_CLOFORK:
#endif
        {
            va_list ap;
            va_start(ap, cmd);
            int iarg = va_arg(ap, int);
            va_end(ap);
            int ret = pt_orig_fcntl_nocancel(fd, cmd, iarg);
            if (ret >= 0) {
                pt_network_notify_fd_dup(fd, ret);
            }
            return ret;
        }
        case F_SETFD:
        case F_SETFL:
        case F_SETOWN:
        case F_RDAHEAD:
        case F_NOCACHE:
        case F_GLOBAL_NOCACHE:
        case F_NODIRECT:
        case F_SETPROTECTIONCLASS:
        case F_SETBACKINGSTORE:
        case F_SETNOSIGPIPE:
        case F_SINGLE_WRITER:
#ifdef F_SETLEASE
        case F_SETLEASE:
#endif
#ifdef F_NOCACHE_EXT
        case F_NOCACHE_EXT:
#endif
        {
            va_list ap;
            va_start(ap, cmd);
            int iarg = va_arg(ap, int);
            va_end(ap);
            return pt_orig_fcntl_nocancel(fd, cmd, iarg);
        }

        case F_SETSIZE:
        {
            va_list ap;
            va_start(ap, cmd);
            off_t oarg = va_arg(ap, off_t);
            va_end(ap);
            return pt_orig_fcntl_nocancel(fd, cmd, oarg);
        }

        default:
        {
            va_list ap;
            va_start(ap, cmd);
            void *parg = va_arg(ap, void *);
            va_end(ap);
            int ret = pt_orig_fcntl_nocancel(fd, cmd, parg);
            return pt_handle_fcntl_getpath(ret, cmd, parg, __builtin_return_address(0));
        }
    }
}

static int pt_proc_pidpath(int pid, void *buffer, uint32_t buffersize) {
    const void *caller = __builtin_return_address(0);
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (!is_sys && pid != 0 && pid != getpid()) {
        errno = ESRCH;
        return 0;
    }
    int ret = proc_pidpath(pid, buffer, buffersize);
    if (ret > 0 && buffer != NULL && buffersize > 1 && !is_sys) {
        char *pathbuf = (char *)buffer;
        char vout[PATH_MAX];
        const char *virt = pt_virtualize_path_for_app(pathbuf, vout, sizeof(vout), YES);
        const char *effective = (virt != NULL) ? virt : pathbuf;
        if (pt_is_sensitive_host_fd_path(effective, caller)) {
            PT_DEBUG_TRACE("fs", "hid proc_pidpath pid=%d path=%s", pid, pathbuf);
            pathbuf[0] = '\0';
            errno = ESRCH;
            return 0;
        }
        if (virt != NULL && virt != pathbuf) {
            PT_DEBUG_TRACE("fs", "virtualized proc_pidpath %s -> %s", pathbuf, virt);
            size_t n = strlcpy(pathbuf, virt, (size_t)buffersize);
            if (n < (size_t)buffersize) {
                return (int)n;
            }
            errno = ENOMEM;
            return 0;
        }
    }
    return ret;
}

static int pt_proc_pidfdinfo(int pid, int fd, int flavor, void *buffer, int buffersize) {
    const void *caller = __builtin_return_address(0);
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (!is_sys && pid != 0 && pid != getpid()) {
        errno = ESRCH;
        return 0;
    }
    int ret = proc_pidfdinfo(pid, fd, flavor, buffer, buffersize);
    if (ret > 0 && buffer != NULL &&
        flavor == PROC_PIDFDVNODEPATHINFO &&
        (size_t)ret >= sizeof(struct vnode_fdinfowithpath) &&
        !is_sys) {
        struct vnode_fdinfowithpath *info = (struct vnode_fdinfowithpath *)buffer;
        if (pt_is_sensitive_host_fd_path(info->pvip.vip_path, caller)) {
            memset(info, 0, sizeof(struct vnode_fdinfowithpath));
            errno = EBADF;
            return 0;
        }
        char vout[PATH_MAX];
        const char *virt = pt_virtualize_path_for_app(info->pvip.vip_path, vout, sizeof(vout), YES);
        if (virt != info->pvip.vip_path) {
            strlcpy(info->pvip.vip_path, virt, sizeof(info->pvip.vip_path));
        }
    }
    return ret;
}

static void pt_sanitize_vnode_vip_path(char *vip_path, size_t cap, const void *caller, const char *fallback) {
    if (cap == 0 || vip_path[0] == '\0') {
        return;
    }
    if (pt_is_hidden_dyld_image_name(vip_path) ||
        pt_is_sensitive_host_fd_path(vip_path, caller)) {
        strlcpy(vip_path, fallback, cap);
        return;
    }
    char vout[PATH_MAX];
    const char *virt = pt_virtualize_path_for_app(vip_path, vout, sizeof(vout), YES);
    if (virt != vip_path) {
        strlcpy(vip_path, virt, cap);
    } else {
        const char *san = pt_sanitize_image_path_for_app(vip_path);
        if (san != vip_path) {
            strlcpy(vip_path, san, cap);
        }
    }
}


static int pt_proc_regionfilename(int pid, uint64_t address, void *buffer, uint32_t buffersize) {
    const void *caller = __builtin_return_address(0);
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (!is_sys && pid != 0 && pid != getpid()) {
        errno = ESRCH;
        return 0;
    }
    int ret = proc_regionfilename(pid, address, buffer, buffersize);
    if (ret > 0 && buffer != NULL && buffersize > 1 && !is_sys) {
        char *pbuf = (char *)buffer;
        if (pt_is_hidden_dyld_image_name(pbuf) ||
            pt_is_sensitive_host_fd_path(pbuf, caller)) {
            const char *fb = pt_fallback_system_image_path();
            size_t n = strlcpy(pbuf, fb, (size_t)buffersize);
            return (n < (size_t)buffersize) ? (int)n : (int)(buffersize - 1);
        }
        char vout[PATH_MAX];
        const char *virt = pt_virtualize_path_for_app(pbuf, vout, sizeof(vout), YES);
        const char *san = (virt != pbuf) ? virt : pt_sanitize_image_path_for_app(pbuf);
        if (san != pbuf) {
            size_t n = strlcpy(pbuf, san, (size_t)buffersize);
            return (n < (size_t)buffersize) ? (int)n : (int)(buffersize - 1);
        }
    }
    return ret;
}

static int pt_fs_proc_pidinfo_ex(int pid,
                                     int flavor,
                                     uint64_t arg,
                                     void *buffer,
                                     int buffersize,
                                     const void *caller,
                                     BOOL raw_syscall_abi) {
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    int self_pid = getpid();
    if (!is_sys && pid != 0 && pid != self_pid) {
        errno = ESRCH;
        return raw_syscall_abi ? -1 : 0;
    }
    int saved_errno = errno;
    errno = 0;
    int ret = proc_pidinfo(pid, flavor, arg, buffer, buffersize);
    int call_errno = errno;
    BOOL failed = (ret < 0 || call_errno != 0);
    if (failed) {
        errno = call_errno;
        return raw_syscall_abi ? -1 : ret;
    }
    if (ret == 0 && flavor != PROC_PIDPATHINFO) {
        errno = saved_errno;
        return 0;
    }
    if (buffer == NULL || is_sys) {
        errno = saved_errno;
        return ret;
    }
    BOOL bypass_active = pt_is_bypass_enabled();
    switch (flavor) {
        case PROC_PIDVNODEPATHINFO:
            if ((size_t)ret >= sizeof(struct proc_vnodepathinfo)) {
                struct proc_vnodepathinfo vinfo;
                memcpy(&vinfo, buffer, sizeof(vinfo));
                const char *vh = pt_get_virtual_home_cstr();
                const char *fb = (vh != NULL) ? vh : "/";
                pt_sanitize_vnode_vip_path(vinfo.pvi_cdir.vip_path, sizeof(vinfo.pvi_cdir.vip_path), caller, fb);
                pt_sanitize_vnode_vip_path(vinfo.pvi_rdir.vip_path, sizeof(vinfo.pvi_rdir.vip_path), caller, "/");
                memcpy(buffer, &vinfo, sizeof(vinfo));
            }
            break;

        case PROC_PIDLISTFDS:
            if ((size_t)ret >= sizeof(struct proc_fdinfo)) {
                int count = ret / (int)sizeof(struct proc_fdinfo);
                struct proc_fdinfo *fds = (struct proc_fdinfo *)buffer;
                int kept = 0;
                for (int i = 0; i < count; i++) {
                    if (fds[i].proc_fdtype == PROX_FDTYPE_VNODE) {
                        struct vnode_fdinfowithpath vfi;
                        int vret = proc_pidfdinfo(self_pid, fds[i].proc_fd, PROC_PIDFDVNODEPATHINFO, &vfi, (int)sizeof(vfi));
                        if (vret > 0 && (size_t)vret >= sizeof(vfi) &&
                            pt_is_sensitive_host_fd_path(vfi.pvip.vip_path, caller)) {
                            continue;
                        }
                    }
                    if (kept != i) {
                        fds[kept] = fds[i];
                    }
                    kept++;
                }
                ret = kept * (int)sizeof(struct proc_fdinfo);
            }
            break;

        case PROC_PIDLISTTHREADS:
            if (bypass_active && (size_t)ret >= sizeof(uint64_t)) {
                int count = ret / (int)sizeof(uint64_t);
                uint64_t *tids = (uint64_t *)buffer;
                int kept = 0;
                for (int i = 0; i < count; i++) {
                    struct proc_threadinfo ti;
                    int tr = proc_pidinfo(self_pid, PROC_PIDTHREADINFO, tids[i], &ti, (int)sizeof(ti));
                    if (tr > 0 && (size_t)tr >= sizeof(ti) && pt_is_hidden_thread_name(ti.pth_name)) {
                        continue;
                    }
                    if (kept != i) {
                        tids[kept] = tids[i];
                    }
                    kept++;
                }
                ret = kept * (int)sizeof(uint64_t);
            }
            break;

        case PROC_PIDTHREADINFO:
        case PROC_PIDTHREADID64INFO:
            if (bypass_active && (size_t)ret >= sizeof(struct proc_threadinfo)) {
                struct proc_threadinfo *ti = (struct proc_threadinfo *)buffer;
                if (pt_is_hidden_thread_name(ti->pth_name)) {
                    memset(ti->pth_name, 0, sizeof(ti->pth_name));
                }
            }
            break;

        case PROC_PIDTHREADPATHINFO:
            if ((size_t)ret >= sizeof(struct proc_threadwithpathinfo)) {
                struct proc_threadwithpathinfo tpi;
                memcpy(&tpi, buffer, sizeof(tpi));
                if (bypass_active && pt_is_hidden_thread_name(tpi.pt.pth_name)) {
                    memset(tpi.pt.pth_name, 0, sizeof(tpi.pt.pth_name));
                }
                pt_sanitize_vnode_vip_path(tpi.pvip.vip_path,
                                           sizeof(tpi.pvip.vip_path),
                                           caller,
                                           pt_fallback_system_image_path());
                memcpy(buffer, &tpi, sizeof(tpi));
            }
            break;

        case PROC_PIDTBSDINFO:
            if ((size_t)ret >= sizeof(struct proc_bsdinfo)) {
                struct proc_bsdinfo *binfo = (struct proc_bsdinfo *)buffer;
                binfo->pbi_flags &= ~(uint32_t)PROC_FLAG_TRACED;
                binfo->pbi_ppid = 1;
                if (bypass_active) {
                    if (binfo->pbi_gid == 20U) {
                        binfo->pbi_gid = 501U;
                    }
                    if (binfo->pbi_rgid == 20U) {
                        binfo->pbi_rgid = 501U;
                    }
                    if (binfo->pbi_svgid == 20U) {
                        binfo->pbi_svgid = 501U;
                    }
                }
            }
            break;

        case PROC_PIDTASKALLINFO:
            if ((size_t)ret >= sizeof(struct proc_taskallinfo)) {
                struct proc_taskallinfo *tinfo = (struct proc_taskallinfo *)buffer;
                tinfo->pbsd.pbi_flags &= ~(uint32_t)PROC_FLAG_TRACED;
                tinfo->pbsd.pbi_ppid = 1;
                if (bypass_active) {
                    if (tinfo->pbsd.pbi_gid == 20U) {
                        tinfo->pbsd.pbi_gid = 501U;
                    }
                    if (tinfo->pbsd.pbi_rgid == 20U) {
                        tinfo->pbsd.pbi_rgid = 501U;
                    }
                    if (tinfo->pbsd.pbi_svgid == 20U) {
                        tinfo->pbsd.pbi_svgid = 501U;
                    }
                }
            }
            break;

        case PROC_PIDT_SHORTBSDINFO:
            if ((size_t)ret >= sizeof(struct proc_bsdshortinfo)) {
                struct proc_bsdshortinfo *sinfo = (struct proc_bsdshortinfo *)buffer;
                sinfo->pbsi_flags &= ~(uint32_t)PROC_FLAG_TRACED;
                sinfo->pbsi_ppid = 1;
                if (bypass_active) {
                    if (sinfo->pbsi_gid == 20U) {
                        sinfo->pbsi_gid = 501U;
                    }
                    if (sinfo->pbsi_rgid == 20U) {
                        sinfo->pbsi_rgid = 501U;
                    }
                    if (sinfo->pbsi_svgid == 20U) {
                        sinfo->pbsi_svgid = 501U;
                    }
                }
            }
            break;

        case PROC_PIDREGIONPATHINFO:
        case PROC_PIDREGIONPATHINFO2:
        case PROC_PIDREGIONPATHINFO3:
            if ((size_t)ret >= sizeof(struct proc_regionwithpathinfo)) {
                struct proc_regionwithpathinfo rinfo;
                memcpy(&rinfo, buffer, sizeof(rinfo));
                pt_sanitize_vnode_vip_path(rinfo.prp_vip.vip_path,
                                           sizeof(rinfo.prp_vip.vip_path),
                                           caller,
                                           pt_fallback_system_image_path());
                memcpy(buffer, &rinfo, sizeof(rinfo));
            }
            break;

        case PROC_PIDPATHINFO:
            if (buffersize > 1) {
                char *pbuf = (char *)buffer;
                pbuf[buffersize - 1] = '\0';
                char vout[PATH_MAX];
                const char *virt = pt_virtualize_path_for_app(pbuf, vout, sizeof(vout), YES);
                if (virt != pbuf) {
                    strlcpy(pbuf, virt, (size_t)buffersize);
                }
                if (pt_is_sensitive_host_fd_path(pbuf, caller)) {
                    pbuf[0] = '\0';
                    errno = ESRCH;
                    return raw_syscall_abi ? -1 : 0;
                }
                errno = saved_errno;
                return 0;
            }
            break;

        default:
            break;
    }
    errno = saved_errno;
    return ret;
}

__attribute__((visibility("hidden")))
int pt_fs_proc_pidinfo_with_caller(int pid, int flavor, uint64_t arg, void *buffer, int buffersize, const void *caller) {
    return pt_fs_proc_pidinfo_ex(pid, flavor, arg, buffer, buffersize, caller, NO);
}

__attribute__((visibility("hidden")))
int pt_fs_proc_pidinfo_syscall_with_caller(int pid, int flavor, uint64_t arg, void *buffer, int buffersize, const void *caller) {
    return pt_fs_proc_pidinfo_ex(pid, flavor, arg, buffer, buffersize, caller, YES);
}

static int pt_proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize) {
    return pt_fs_proc_pidinfo_with_caller(pid, flavor, arg, buffer, buffersize, __builtin_return_address(0));
}

static int pt_proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize) {
    if (!pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (type == PROC_ALL_PIDS || typeinfo == 0 || (uid_t)typeinfo == getuid() || typeinfo == 501U) {
            if (buffer == NULL || buffersize <= 0) {
                return (int)sizeof(int);
            }
            if (buffersize < (int)sizeof(int)) {
                return 0;
            }
            *(int *)buffer = getpid();
            return (int)sizeof(int);
        }
        return 0;
    }
    return proc_listpids(type, typeinfo, buffer, buffersize);
}

static int pt_proc_listallpids(void *buffer, int buffersize) {
    if (!pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (buffer == NULL || buffersize <= 0) {
            return (int)sizeof(int);
        }
        if (buffersize < (int)sizeof(int)) {
            return 0;
        }
        *(int *)buffer = getpid();
        return (int)sizeof(int);
    }
    return proc_listallpids(buffer, buffersize);
}

static int pt_proc_name(int pid, void *buffer, uint32_t buffersize) {
    if (pid != 0 && pid != getpid() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        errno = ESRCH;
        return 0;
    }
    return proc_name(pid, buffer, buffersize);
}

extern DIR *__opendir2(const char *name, int flags);

static DIR *pt_opendir(const char *name) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path(name, __builtin_return_address(0), vbuf, sizeof(vbuf), &name);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return NULL;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return NULL;
    }
    return opendir(name);
}

static DIR *pt_opendir2(const char *name, int flags) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path(name, __builtin_return_address(0), vbuf, sizeof(vbuf), &name);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return NULL;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return NULL;
    }
    return __opendir2(name, flags);
}

static DIR *pt_fdopendir(int fd) {
    if (fd < 0) {
        errno = EBADF;
        return NULL;
    }
    if (pt_fd_is_sensitive(fd, __builtin_return_address(0))) {
        errno = EBADF;
        return NULL;
    }
    return fdopendir(fd);
}

static inline BOOL pt_is_macos_data_root_symlink_name(const char *d_name) {
    if (d_name == NULL || d_name[0] == '\0') {
        return NO;
    }
    return (strcmp(d_name, "Desktop") == 0 ||
            strcmp(d_name, "Downloads") == 0 ||
            strcmp(d_name, "Movies") == 0 ||
            strcmp(d_name, "Music") == 0 ||
            strcmp(d_name, "Pictures") == 0);
}

static BOOL pt_path_equals_real_data_root(const char *path) {
    if (path == NULL || path[0] != '/') {
        return NO;
    }
    pt_ensure_data_container_map();
    if (s_real_data_container_len == 0) {
        return NO;
    }
    if (strncmp(path, "/System/Volumes/Data/", 21) == 0) {
        path += 20;
    }
    size_t len = strlen(path);
    while (len > 1 && path[len - 1] == '/') {
        len--;
    }
    if (len >= PATH_MAX) {
        return NO;
    }
    char clean_path[PATH_MAX];
    memcpy(clean_path, path, len);
    clean_path[len] = '\0';
    const char *suf = pt_match_prefix_modulo_private(clean_path, s_real_data_container_dir, s_real_data_container_len);
    return (suf != NULL && suf[0] == '\0');
}

static BOOL pt_dir_fd_is_real_data_root(DIR *dirp) {
    if (dirp == NULL) {
        return NO;
    }
    int fd = dirfd(dirp);
    if (fd < 0) {
        return NO;
    }
    char dp[PATH_MAX];
    if (fcntl(fd, F_GETPATH, dp) == -1) {
        return NO;
    }
    return pt_path_equals_real_data_root(dp);
}

static BOOL pt_dirname_is_real_data_root(const char *dirname) {
    if (dirname == NULL || dirname[0] != '/') {
        return NO;
    }
    char lex_buf[PATH_MAX];
    const char *norm = dirname;
    if (pt_needs_lexical_norm(norm)) {
        const char *collapsed = pt_normalize_lexical_path(norm, lex_buf, sizeof(lex_buf));
        if (collapsed != NULL) {
            norm = collapsed;
        }
    }
    return pt_path_equals_real_data_root(norm);
}

static BOOL pt_should_hide_dirent(const char *d_name,
                                  uint8_t d_type,
                                  const void *caller,
                                  int *inout_is_sys_caller,
                                  int *inout_in_data_root,
                                  DIR *dirp_for_lazy_check,
                                  int dirfd_for_check,
                                  const char *dirname_for_lazy_check) {
    if (d_name == NULL || d_name[0] == '\0' || !pt_is_bypass_enabled()) {
        return NO;
    }
    BOOL hide_candidate = pt_is_hidden_dirent_name(d_name);
    if (!hide_candidate && strcasecmp(d_name, "Finder.app") == 0) {
        char dp[PATH_MAX];
        const char *dir_path = dirname_for_lazy_check;
        if (dir_path == NULL) {
            int dfd = (dirp_for_lazy_check != NULL) ? dirfd(dirp_for_lazy_check) : dirfd_for_check;
            if (dfd >= 0 && fcntl(dfd, F_GETPATH, dp) != -1) {
                dir_path = dp;
            }
        }
        if (dir_path != NULL) {
            if (strncasecmp(dir_path, "/System/Volumes/Data/", 21) == 0) {
                dir_path += 20;
            }
            if (strcasecmp(dir_path, "/System/Library/CoreServices") == 0) {
                hide_candidate = YES;
            }
        }
    }
    if (!hide_candidate && pt_is_macos_data_root_symlink_name(d_name)) {
        if (*inout_in_data_root < 0) {
            BOOL in_root = NO;
            if (dirp_for_lazy_check != NULL) {
                in_root = pt_dir_fd_is_real_data_root(dirp_for_lazy_check);
            } else if (dirname_for_lazy_check != NULL) {
                in_root = pt_dirname_is_real_data_root(dirname_for_lazy_check);
            }
            *inout_in_data_root = in_root ? 1 : 0;
        }
        if (*inout_in_data_root == 1) {
            if (strcmp(d_name, "Desktop") == 0) {
                hide_candidate = YES;
            } else if (d_type == DT_LNK) {
                hide_candidate = YES;
            } else if (d_type == DT_UNKNOWN) {
                struct stat st;
                int dfd = (dirp_for_lazy_check != NULL) ? dirfd(dirp_for_lazy_check) : dirfd_for_check;
                if (dfd >= 0) {
                    if (fstatat(dfd, d_name, &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISLNK(st.st_mode)) {
                        hide_candidate = YES;
                    }
                } else if (dirname_for_lazy_check != NULL) {
                    char full[PATH_MAX];
                    int n = snprintf(full, sizeof(full), "%s/%s", dirname_for_lazy_check, d_name);
                    if (n > 0 && (size_t)n < sizeof(full) && lstat(full, &st) == 0 && S_ISLNK(st.st_mode)) {
                        hide_candidate = YES;
                    }
                }
            }
        }
    }
    if (!hide_candidate) {
        return NO;
    }
    if (*inout_is_sys_caller < 0) {
        *inout_is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
    }
    return (*inout_is_sys_caller == 0);
}

static struct dirent *pt_readdir(DIR *dirp) {
    const void *caller = __builtin_return_address(0);
    struct dirent *entry = readdir(dirp);
    int is_sys_caller = -1;
    int in_data_root = -1;
    while (entry != NULL &&
           pt_should_hide_dirent(entry->d_name, entry->d_type, caller, &is_sys_caller, &in_data_root, dirp, -1, NULL)) {
        entry = readdir(dirp);
    }
    return entry;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static int pt_readdir_r(DIR *dirp, struct dirent *entry, struct dirent **result) {
    const void *caller = __builtin_return_address(0);
    int rc = readdir_r(dirp, entry, result);
    int is_sys_caller = -1;
    int in_data_root = -1;
    while (rc == 0 && result != NULL && *result != NULL &&
           pt_should_hide_dirent((*result)->d_name, (*result)->d_type, caller, &is_sys_caller, &in_data_root, dirp, -1, NULL)) {
        rc = readdir_r(dirp, entry, result);
    }
    return rc;
}
#pragma clang diagnostic pop

static int pt_filter_scandir_results(struct dirent ***namelist,
                                     int count,
                                     const char *resolved_dirname,
                                     const void *caller,
                                     int is_sys_caller) {
    if (count <= 0 || namelist == NULL || *namelist == NULL) {
        return count;
    }
    struct dirent **list = *namelist;
    int in_data_root = -1;
    int dst = 0;
    for (int i = 0; i < count; i++) {
        struct dirent *ent = list[i];
        if (ent != NULL &&
            pt_should_hide_dirent(ent->d_name, ent->d_type, caller, &is_sys_caller, &in_data_root, NULL, -1, resolved_dirname)) {
            free(ent);
            continue;
        }
        list[dst++] = ent;
    }
    return dst;
}

static int pt_scandir(const char *dirname,
                      struct dirent ***namelist,
                      int (*select_fn)(const struct dirent *),
                      int (*compar_fn)(const struct dirent **, const struct dirent **)) {
    const void *caller = __builtin_return_address(0);
    int is_sys_caller = -1;
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(dirname, caller, vbuf, sizeof(vbuf), &dirname, &is_sys_caller);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return -1;
    }
    int count = scandir(dirname, namelist, select_fn, compar_fn);
    return pt_filter_scandir_results(namelist, count, dirname, caller, is_sys_caller);
}

static int pt_scandir_b(const char *dirname,
                        struct dirent ***namelist,
                        int (^select_blk)(const struct dirent *),
                        int (^compar_blk)(const struct dirent **, const struct dirent **)) {
    const void *caller = __builtin_return_address(0);
    int is_sys_caller = -1;
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(dirname, caller, vbuf, sizeof(vbuf), &dirname, &is_sys_caller);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return -1;
    }
    int count = scandir_b(dirname, namelist, select_blk, compar_blk);
    return pt_filter_scandir_results(namelist, count, dirname, caller, is_sys_caller);
}

static int pt_mkdir(const char *path, mode_t mode) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path(path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EEXIST;
        return -1;
    }
    return mkdir(path, mode);
}

__attribute__((visibility("hidden"))) BOOL pt_prepare_fs_path_for_modify(int dirfd,
                                                 const char *raw_path,
                                                 const void *caller,
                                                 char *vbuf,
                                                 size_t vbuf_size,
                                                 const char **out_path,
                                                 int ancestor_errno) {
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_at(dirfd, raw_path, caller, vbuf, vbuf_size, out_path);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return NO;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = ancestor_errno;
        return NO;
    }
    return YES;
}

static int pt_mkdirat(int fd, const char *path, mode_t mode) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_at(fd, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EEXIST;
        return -1;
    }
    return mkdirat(fd, path, mode);
}

static int pt_mkpath_np(const char *path, mode_t omode) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path(path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        return 0;
    }
    return mkpath_np(path, omode);
}

static int pt_mkpathat_np(int dfd, const char *path, mode_t omode) {
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_at(dfd, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        return 0;
    }
    return mkpathat_np(dfd, path, omode);
}

static int pt_rmdir(const char *path) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return rmdir(path);
}

typedef struct {
    uint32_t bit;
    size_t sz;
} pt_attr_bit_size_t;

static void pt_attr_walk_group(uint32_t mask,
                               const pt_attr_bit_size_t *table,
                               size_t table_len,
                               uint64_t options,
                               BOOL is_common,
                               size_t *inout_off,
                               uint32_t target_bit,
                               BOOL is_target_group,
                               size_t rec_len,
                               size_t *out_found_off,
                               BOOL *out_found) {
    for (size_t i = 0; i < table_len; i++) {
        uint32_t bit = table[i].bit;
        if (is_target_group && bit == target_bit) {
            if ((mask & bit) != 0 && *inout_off + table[i].sz <= rec_len) {
                *out_found_off = *inout_off;
                *out_found = YES;
            }
            return;
        }
        if ((mask & bit) != 0) {
            size_t sz = table[i].sz;
            if (is_common && bit == 0x00100000U && (options & FSOPT_ATTR_CMN_EXTENDED) == 0) {
                sz = sizeof(attrreference_t);
            }
            *inout_off += sz;
        }
    }
}

typedef enum {
    PT_ATTR_GROUP_COMMON = 0,
    PT_ATTR_GROUP_VOL = 1,
    PT_ATTR_GROUP_DIR = 2,
    PT_ATTR_GROUP_FILE = 3,
    PT_ATTR_GROUP_FORK = 4,
} pt_attr_group_t;

static size_t pt_attr_offset_in_record(const struct attrlist *req,
                                        const char *rec_ptr,
                                        uint32_t rec_len,
                                        uint64_t options,
                                        pt_attr_group_t target_group,
                                        uint32_t target_bit,
                                        BOOL *out_present) {
    *out_present = NO;
    if (req == NULL || rec_ptr == NULL || rec_len < sizeof(uint32_t)) {
        return 0;
    }
    size_t off = sizeof(uint32_t);
    uint32_t cmn_mask = req->commonattr;
    uint32_t vol_mask = req->volattr;
    uint32_t dir_mask = req->dirattr;
    uint32_t file_mask = req->fileattr;
    uint32_t fork_mask = req->forkattr;
    if ((req->commonattr & ATTR_CMN_RETURNED_ATTRS) != 0) {
        if (off + sizeof(attribute_set_t) > rec_len) {
            return 0;
        }
        const attribute_set_t *ret_attrs = (const attribute_set_t *)(rec_ptr + off);
        cmn_mask = ret_attrs->commonattr;
        vol_mask = ret_attrs->volattr;
        dir_mask = ret_attrs->dirattr;
        file_mask = ret_attrs->fileattr;
        fork_mask = ret_attrs->forkattr;
        off += sizeof(attribute_set_t);
    }
    cmn_mask &= ~(uint32_t)ATTR_CMN_RETURNED_ATTRS;
    vol_mask &= ~(uint32_t)ATTR_VOL_INFO;

    uint32_t target_mask = 0;
    switch (target_group) {
        case PT_ATTR_GROUP_COMMON: target_mask = cmn_mask; break;
        case PT_ATTR_GROUP_VOL:    target_mask = vol_mask; break;
        case PT_ATTR_GROUP_DIR:    target_mask = dir_mask; break;
        case PT_ATTR_GROUP_FILE:   target_mask = file_mask; break;
        case PT_ATTR_GROUP_FORK:   target_mask = fork_mask; break;
    }
    if ((target_mask & target_bit) == 0) {
        return 0;
    }

    static const pt_attr_bit_size_t kCmnLayout[] = {
        { ATTR_CMN_NAME,               sizeof(attrreference_t) },
        { ATTR_CMN_DEVID,              sizeof(dev_t) },
        { ATTR_CMN_FSID,               sizeof(fsid_t) },
        { ATTR_CMN_OBJTYPE,            sizeof(fsobj_type_t) },
        { ATTR_CMN_OBJTAG,             sizeof(fsobj_tag_t) },
        { ATTR_CMN_OBJID,              sizeof(fsobj_id_t) },
        { ATTR_CMN_OBJPERMANENTID,     sizeof(fsobj_id_t) },
        { ATTR_CMN_PAROBJID,           sizeof(fsobj_id_t) },
        { ATTR_CMN_SCRIPT,             sizeof(text_encoding_t) },
        { ATTR_CMN_CRTIME,             sizeof(struct timespec) },
        { ATTR_CMN_MODTIME,            sizeof(struct timespec) },
        { ATTR_CMN_CHGTIME,            sizeof(struct timespec) },
        { ATTR_CMN_ACCTIME,            sizeof(struct timespec) },
        { ATTR_CMN_BKUPTIME,           sizeof(struct timespec) },
        { ATTR_CMN_FNDRINFO,           32 },
        { ATTR_CMN_OWNERID,            sizeof(uid_t) },
        { ATTR_CMN_GRPID,              sizeof(gid_t) },
        { ATTR_CMN_ACCESSMASK,         sizeof(uint32_t) },
        { ATTR_CMN_FLAGS,              sizeof(uint32_t) },
        { ATTR_CMN_GEN_COUNT,          sizeof(uint32_t) },
        { ATTR_CMN_DOCUMENT_ID,        sizeof(uint32_t) },
        { ATTR_CMN_USERACCESS,         sizeof(uint32_t) },
        { ATTR_CMN_EXTENDED_SECURITY,  sizeof(attrreference_t) },
        { ATTR_CMN_UUID,               sizeof(guid_t) },
        { ATTR_CMN_GRPUUID,            sizeof(guid_t) },
        { ATTR_CMN_FILEID,             sizeof(uint64_t) },
        { ATTR_CMN_PARENTID,           sizeof(uint64_t) },
        { ATTR_CMN_FULLPATH,           sizeof(attrreference_t) },
        { ATTR_CMN_ADDEDTIME,          sizeof(struct timespec) },
        { ATTR_CMN_ERROR,              sizeof(uint32_t) },
        { ATTR_CMN_DATA_PROTECT_FLAGS, sizeof(uint32_t) },
    };
    static const pt_attr_bit_size_t kVolLayout[] = {
        { ATTR_VOL_FSTYPE,           sizeof(uint32_t) },
        { ATTR_VOL_SIGNATURE,        sizeof(uint32_t) },
        { ATTR_VOL_SIZE,             sizeof(off_t) },
        { ATTR_VOL_SPACEFREE,        sizeof(off_t) },
        { ATTR_VOL_SPACEAVAIL,       sizeof(off_t) },
        { ATTR_VOL_MINALLOCATION,    sizeof(off_t) },
        { ATTR_VOL_ALLOCATIONCLUMP,  sizeof(off_t) },
        { ATTR_VOL_IOBLOCKSIZE,      sizeof(uint32_t) },
        { ATTR_VOL_OBJCOUNT,         sizeof(uint32_t) },
        { ATTR_VOL_FILECOUNT,        sizeof(uint32_t) },
        { ATTR_VOL_DIRCOUNT,         sizeof(uint32_t) },
        { ATTR_VOL_MAXOBJCOUNT,      sizeof(uint32_t) },
        { ATTR_VOL_MOUNTPOINT,       sizeof(attrreference_t) },
        { ATTR_VOL_NAME,             sizeof(attrreference_t) },
        { ATTR_VOL_MOUNTFLAGS,       sizeof(uint32_t) },
        { ATTR_VOL_MOUNTEDDEVICE,    sizeof(attrreference_t) },
        { ATTR_VOL_ENCODINGSUSED,    sizeof(uint64_t) },
        { ATTR_VOL_CAPABILITIES,     sizeof(vol_capabilities_attr_t) },
        { ATTR_VOL_UUID,             sizeof(uuid_t) },
        { ATTR_VOL_MOUNTEXTFLAGS,    sizeof(uint32_t) },
        { ATTR_VOL_FSTYPENAME,       sizeof(attrreference_t) },
        { ATTR_VOL_FSSUBTYPE,        sizeof(uint32_t) },
        { ATTR_VOL_OWNER,            sizeof(uid_t) },
        { ATTR_VOL_SPACEUSED,        sizeof(off_t) },
        { ATTR_VOL_QUOTA_SIZE,       sizeof(off_t) },
        { ATTR_VOL_RESERVED_SIZE,    sizeof(off_t) },
        { ATTR_VOL_ATTRIBUTES,       sizeof(vol_attributes_attr_t) },
    };
    static const pt_attr_bit_size_t kDirLayout[] = {
        { ATTR_DIR_LINKCOUNT,   sizeof(uint32_t) },
        { ATTR_DIR_ENTRYCOUNT,  sizeof(uint32_t) },
        { ATTR_DIR_MOUNTSTATUS, sizeof(uint32_t) },
        { ATTR_DIR_ALLOCSIZE,   sizeof(off_t) },
        { ATTR_DIR_IOBLOCKSIZE, sizeof(uint32_t) },
        { ATTR_DIR_DATALENGTH,  sizeof(off_t) },
    };
    static const pt_attr_bit_size_t kFileLayout[] = {
        { ATTR_FILE_LINKCOUNT,     sizeof(uint32_t) },
        { ATTR_FILE_TOTALSIZE,     sizeof(off_t) },
        { ATTR_FILE_ALLOCSIZE,     sizeof(off_t) },
        { ATTR_FILE_IOBLOCKSIZE,   sizeof(uint32_t) },
        { ATTR_FILE_CLUMPSIZE,     sizeof(uint32_t) },
        { ATTR_FILE_DEVTYPE,       sizeof(uint32_t) },
        { ATTR_FILE_FILETYPE,      sizeof(uint32_t) },
        { ATTR_FILE_FORKCOUNT,     sizeof(uint32_t) },
        { ATTR_FILE_FORKLIST,      sizeof(attrreference_t) },
        { ATTR_FILE_DATALENGTH,    sizeof(off_t) },
        { ATTR_FILE_DATAALLOCSIZE, sizeof(off_t) },
        { ATTR_FILE_DATAEXTENTS,   sizeof(extentrecord) },
        { ATTR_FILE_RSRCLENGTH,    sizeof(off_t) },
        { ATTR_FILE_RSRCALLOCSIZE, sizeof(off_t) },
        { ATTR_FILE_RSRCEXTENTS,   sizeof(extentrecord) },
    };
    static const pt_attr_bit_size_t kForkLayout[] = {
        { ATTR_CMNEXT_RELPATH,        sizeof(attrreference_t) },
        { ATTR_CMNEXT_PRIVATESIZE,    sizeof(off_t) },
        { ATTR_CMNEXT_LINKID,         sizeof(uint64_t) },
        { ATTR_CMNEXT_NOFIRMLINKPATH, sizeof(attrreference_t) },
    };

    size_t found_off = 0;
    BOOL found = NO;
    pt_attr_walk_group(cmn_mask, kCmnLayout, sizeof(kCmnLayout) / sizeof(kCmnLayout[0]),
                       options, YES, &off, target_bit, target_group == PT_ATTR_GROUP_COMMON,
                       rec_len, &found_off, &found);
    if (target_group == PT_ATTR_GROUP_COMMON) {
        *out_present = found;
        return found_off;
    }
    if (vol_mask != 0) {
        pt_attr_walk_group(vol_mask, kVolLayout, sizeof(kVolLayout) / sizeof(kVolLayout[0]),
                           options, NO, &off, target_bit, target_group == PT_ATTR_GROUP_VOL,
                           rec_len, &found_off, &found);
    }
    if (target_group == PT_ATTR_GROUP_VOL) {
        *out_present = found;
        return found_off;
    }
    pt_attr_walk_group(dir_mask, kDirLayout, sizeof(kDirLayout) / sizeof(kDirLayout[0]),
                       options, NO, &off, target_bit, target_group == PT_ATTR_GROUP_DIR,
                       rec_len, &found_off, &found);
    if (target_group == PT_ATTR_GROUP_DIR) {
        *out_present = found;
        return found_off;
    }
    pt_attr_walk_group(file_mask, kFileLayout, sizeof(kFileLayout) / sizeof(kFileLayout[0]),
                       options, NO, &off, target_bit, target_group == PT_ATTR_GROUP_FILE,
                       rec_len, &found_off, &found);
    if (target_group == PT_ATTR_GROUP_FILE) {
        *out_present = found;
        return found_off;
    }
    pt_attr_walk_group(fork_mask, kForkLayout, sizeof(kForkLayout) / sizeof(kForkLayout[0]),
                       options, NO, &off, target_bit, target_group == PT_ATTR_GROUP_FORK,
                       rec_len, &found_off, &found);
    *out_present = found;
    return found_off;
}

static size_t pt_attr_cmn_offset_in_record(const struct attrlist *req,
                                            const char *rec_ptr,
                                            uint32_t rec_len,
                                            uint64_t options,
                                            uint32_t target_bit,
                                            BOOL *out_present) {
    return pt_attr_offset_in_record(req, rec_ptr, rec_len, options,
                                    PT_ATTR_GROUP_COMMON, target_bit, out_present);
}

static void pt_write_attr_ref_replacement(char *rec_ptr,
                                          size_t max_rec_cap,
                                          attrreference_t *ref,
                                          uintptr_t str_start,
                                          size_t avail_str,
                                          BOOL can_grow_record,
                                          const char *replacement,
                                          BOOL is_mountpoint) {
    if (replacement == NULL) {
        return;
    }
    uint32_t rec_len = *(uint32_t *)rec_ptr;
    size_t vlen = strlen(replacement) + 1U;
    if (vlen <= (size_t)ref->attr_length && vlen <= avail_str) {
        memcpy((void *)str_start, replacement, vlen);
        ref->attr_length = (uint32_t)vlen;
        return;
    }
    if (can_grow_record) {
        size_t padded = (vlen + 3U) & ~3U;
        if ((size_t)rec_len + padded <= max_rec_cap) {
            char *dst = rec_ptr + rec_len;
            memset(dst, 0, padded);
            memcpy(dst, replacement, vlen);
            ref->attr_dataoffset = (int32_t)(dst - (char *)ref);
            ref->attr_length = (uint32_t)vlen;
            *(uint32_t *)rec_ptr = rec_len + (uint32_t)padded;
            return;
        }
    }
    if (!is_mountpoint && strncmp(replacement, "/private/var/", 13) == 0) {
        const char *short_virt = replacement + 8;
        size_t slen = strlen(short_virt) + 1U;
        if (slen <= (size_t)ref->attr_length && slen <= avail_str) {
            memcpy((void *)str_start, short_virt, slen);
            ref->attr_length = (uint32_t)slen;
            return;
        }
    }
    if (is_mountpoint && avail_str >= 2 && ref->attr_length >= 2) {
        memcpy((void *)str_start, "/", 2);
        ref->attr_length = 2;
        return;
    }
    if (avail_str > 0) {
        *(char *)str_start = '\0';
        ref->attr_length = 1;
    }
}

static void pt_sanitize_attr_path_ref(const struct attrlist *alist,
                                      char *rec_ptr,
                                      size_t max_rec_cap,
                                      uint64_t options,
                                      BOOL can_grow_record,
                                      pt_attr_group_t group,
                                      uint32_t bit,
                                      BOOL is_mountpoint,
                                      const char *override_path,
                                      const void *caller) {
    uint32_t rec_len = *(uint32_t *)rec_ptr;
    if (rec_len < sizeof(uint32_t) || (size_t)rec_len > max_rec_cap) {
        return;
    }
    BOOL has_attr = NO;
    size_t attr_off = pt_attr_offset_in_record(alist, rec_ptr, rec_len, options, group, bit, &has_attr);
    if (!has_attr || attr_off + sizeof(attrreference_t) > rec_len) {
        return;
    }
    attrreference_t *ref = (attrreference_t *)(rec_ptr + attr_off);
    if (ref->attr_dataoffset <= 0 || ref->attr_length == 0) {
        return;
    }
    uintptr_t str_start = (uintptr_t)ref + (uintptr_t)ref->attr_dataoffset;
    uintptr_t rec_end = (uintptr_t)rec_ptr + (uintptr_t)rec_len;
    if (str_start < (uintptr_t)rec_ptr || str_start >= rec_end) {
        return;
    }
    size_t avail_str = (size_t)(rec_end - str_start);
    if (override_path != NULL) {
        pt_write_attr_ref_replacement(rec_ptr, max_rec_cap, ref, str_start, avail_str,
                                      can_grow_record, override_path, is_mountpoint);
        return;
    }
    char orig_copy[PATH_MAX];
    size_t copy_n = (ref->attr_length < avail_str) ? (size_t)ref->attr_length : avail_str;
    if (copy_n >= sizeof(orig_copy)) {
        copy_n = sizeof(orig_copy) - 1;
    }
    memcpy(orig_copy, (const void *)str_start, copy_n);
    orig_copy[copy_n] = '\0';

    if (is_mountpoint) {
        if (strcmp(orig_copy, "/System/Volumes/Data") == 0 ||
            strncmp(orig_copy, "/Volumes/", 9) == 0 ||
            strncmp(orig_copy, "/Users/", 7) == 0) {
            pt_write_attr_ref_replacement(rec_ptr, max_rec_cap, ref, str_start, avail_str,
                                          can_grow_record, "/private/var", YES);
        } else if (strncmp(orig_copy, "/System/Volumes/Data/", 21) == 0) {
            pt_write_attr_ref_replacement(rec_ptr, max_rec_cap, ref, str_start, avail_str,
                                          can_grow_record, orig_copy + 20, YES);
        }
        return;
    }

    if (group == PT_ATTR_GROUP_COMMON && bit == ATTR_CMN_NAME) {
        const char *user_root = pt_get_host_user_root_cstr();
        const char *host_user = (user_root != NULL && strncmp(user_root, "/Users/", 7) == 0) ? (user_root + 7) : NULL;
        if (pt_is_hidden_dirent_name(orig_copy) ||
            (host_user != NULL && host_user[0] != '\0' && strcmp(orig_copy, host_user) == 0)) {
            pt_write_attr_ref_replacement(rec_ptr, max_rec_cap, ref, str_start, avail_str,
                                          can_grow_record, "mobile", NO);
        }
        return;
    }

    if (pt_is_sensitive_host_fd_path(orig_copy, caller)) {
        if (avail_str > 0) {
            *(char *)str_start = '\0';
            ref->attr_length = 1;
        }
        return;
    }
    char vout[PATH_MAX];
    const char *virt = pt_virtualize_path_for_app(orig_copy, vout, sizeof(vout), YES);
    if (virt != orig_copy) {
        pt_write_attr_ref_replacement(rec_ptr, max_rec_cap, ref, str_start, avail_str,
                                      can_grow_record, virt, NO);
    }
}

static void pt_sanitize_attr_fullpath_in_record(const struct attrlist *alist,
                                                char *rec_ptr,
                                                size_t max_rec_cap,
                                                uint64_t options,
                                                BOOL can_grow_record,
                                                const void *caller) {
    if (alist == NULL || rec_ptr == NULL || max_rec_cap < sizeof(uint32_t)) {
        return;
    }
    if ((alist->commonattr & ATTR_CMN_NAME) != 0) {
        pt_sanitize_attr_path_ref(alist, rec_ptr, max_rec_cap, options, can_grow_record,
                                  PT_ATTR_GROUP_COMMON, ATTR_CMN_NAME, NO, NULL, caller);
    }
    if ((alist->commonattr & ATTR_CMN_FULLPATH) != 0) {
        pt_sanitize_attr_path_ref(alist, rec_ptr, max_rec_cap, options, can_grow_record,
                                  PT_ATTR_GROUP_COMMON, ATTR_CMN_FULLPATH, NO, NULL, caller);
    }
    if ((alist->volattr & ATTR_VOL_MOUNTPOINT) != 0) {
        pt_sanitize_attr_path_ref(alist, rec_ptr, max_rec_cap, options, can_grow_record,
                                  PT_ATTR_GROUP_VOL, ATTR_VOL_MOUNTPOINT, YES, NULL, caller);
    }
    if ((alist->forkattr & ATTR_CMNEXT_NOFIRMLINKPATH) != 0) {
        pt_sanitize_attr_path_ref(alist, rec_ptr, max_rec_cap, options, can_grow_record,
                                  PT_ATTR_GROUP_FORK, ATTR_CMNEXT_NOFIRMLINKPATH, NO, NULL, caller);
    }
}

static void pt_sanitize_attr_virtual_ancestor_record(const struct attrlist *alist,
                                                     char *rec_ptr,
                                                     size_t max_rec_cap,
                                                     uint64_t options,
                                                     BOOL can_grow_record,
                                                     const char *ancestor_path,
                                                     const void *caller) {
    if (alist == NULL || rec_ptr == NULL || max_rec_cap < sizeof(uint32_t) || ancestor_path == NULL) {
        return;
    }
    const char *base = strrchr(ancestor_path, '/');
    const char *name_override = (base != NULL && base[1] != '\0') ? (base + 1) : "/";
    if ((alist->commonattr & ATTR_CMN_NAME) != 0) {
        pt_sanitize_attr_path_ref(alist, rec_ptr, max_rec_cap, options, can_grow_record,
                                  PT_ATTR_GROUP_COMMON, ATTR_CMN_NAME, NO, name_override, caller);
    }
    if ((alist->commonattr & ATTR_CMN_FULLPATH) != 0) {
        pt_sanitize_attr_path_ref(alist, rec_ptr, max_rec_cap, options, can_grow_record,
                                  PT_ATTR_GROUP_COMMON, ATTR_CMN_FULLPATH, NO, ancestor_path, caller);
    }
    if ((alist->volattr & ATTR_VOL_MOUNTPOINT) != 0) {
        pt_sanitize_attr_path_ref(alist, rec_ptr, max_rec_cap, options, can_grow_record,
                                  PT_ATTR_GROUP_VOL, ATTR_VOL_MOUNTPOINT, YES, "/private/var", caller);
    }
    if ((alist->forkattr & ATTR_CMNEXT_NOFIRMLINKPATH) != 0) {
        pt_sanitize_attr_path_ref(alist, rec_ptr, max_rec_cap, options, can_grow_record,
                                  PT_ATTR_GROUP_FORK, ATTR_CMNEXT_NOFIRMLINKPATH, NO, ancestor_path, caller);
    }
}

static int pt_getattrlist(const char *path, void *attrList, void *attrBuf, size_t attrBufSize, unsigned int options) {
    const void *caller = __builtin_return_address(0);
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path(path, caller, vbuf, sizeof(vbuf), &resolved);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    const char *ancestor_override = NULL;
    const char *query_path = resolved;
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        ancestor_override = (resolved != NULL) ? resolved : "/private/var/mobile";
        pt_ensure_data_container_map();
        query_path = (s_real_data_container_len > 0) ? s_real_data_container_dir : "/private/var";
    }
    int ret = getattrlist(query_path, attrList, attrBuf, attrBufSize, options);
    if (ret == 0 && attrList != NULL && attrBuf != NULL && attrBufSize >= sizeof(uint32_t) &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        if (ancestor_override != NULL) {
            pt_sanitize_attr_virtual_ancestor_record((const struct attrlist *)attrList,
                                                     (char *)attrBuf,
                                                     attrBufSize,
                                                     (uint64_t)options,
                                                     (options & FSOPT_REPORT_FULLSIZE) == 0,
                                                     ancestor_override,
                                                     caller);
        } else {
            pt_sanitize_attr_fullpath_in_record((const struct attrlist *)attrList,
                                                (char *)attrBuf,
                                                attrBufSize,
                                                (uint64_t)options,
                                                (options & FSOPT_REPORT_FULLSIZE) == 0,
                                                caller);
        }
    }
    return ret;
}

static int pt_fgetattrlist(int fd, void *attrList, void *attrBuf, size_t attrBufSize, unsigned int options) {
    const void *caller = __builtin_return_address(0);
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (!is_sys && pt_fd_is_sensitive(fd, caller)) {
        errno = EBADF;
        return -1;
    }
    int ret = fgetattrlist(fd, attrList, attrBuf, attrBufSize, options);
    if (ret == 0 && attrList != NULL && attrBuf != NULL && attrBufSize >= sizeof(uint32_t) && !is_sys) {
        pt_sanitize_attr_fullpath_in_record((const struct attrlist *)attrList,
                                            (char *)attrBuf,
                                            attrBufSize,
                                            (uint64_t)options,
                                            (options & FSOPT_REPORT_FULLSIZE) == 0,
                                            caller);
    }
    return ret;
}

static int pt_getattrlistat(int fd, const char *path, void *attrList, void *attrBuf, size_t attrBufSize, unsigned long options) {
    const void *caller = __builtin_return_address(0);
    if (pt_fd_is_sensitive(fd, caller)) {
        errno = EBADF;
        return -1;
    }
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_at(fd, path, caller, vbuf, sizeof(vbuf), &resolved);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    int ret = -1;
    const char *ancestor_override = NULL;
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        ancestor_override = (resolved != NULL) ? resolved : "/private/var/mobile";
        pt_ensure_data_container_map();
        const char *proxy = (s_real_data_container_len > 0) ? s_real_data_container_dir : "/private/var";
        ret = getattrlist(proxy, attrList, attrBuf, attrBufSize, (unsigned int)options);
    } else {
        ret = getattrlistat(fd, resolved, attrList, attrBuf, attrBufSize, options);
    }
    if (ret == 0 && attrList != NULL && attrBuf != NULL && attrBufSize >= sizeof(uint32_t) &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        if (ancestor_override != NULL) {
            pt_sanitize_attr_virtual_ancestor_record((const struct attrlist *)attrList,
                                                     (char *)attrBuf,
                                                     attrBufSize,
                                                     (uint64_t)options,
                                                     (options & FSOPT_REPORT_FULLSIZE) == 0,
                                                     ancestor_override,
                                                     caller);
        } else {
            pt_sanitize_attr_fullpath_in_record((const struct attrlist *)attrList,
                                                (char *)attrBuf,
                                                attrBufSize,
                                                (uint64_t)options,
                                                (options & FSOPT_REPORT_FULLSIZE) == 0,
                                                caller);
        }
    }
    return ret;
}

static int pt_getattrlistbulk(int dirfd, void *attrList, void *attrBuf, size_t attrBufSize, uint64_t options) {
    const void *caller = __builtin_return_address(0);
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (is_sys) {
        return getattrlistbulk(dirfd, attrList, attrBuf, attrBufSize, options);
    }
    char dirpath[PATH_MAX];
    dirpath[0] = '\0';
    if (dirfd >= 0 && fcntl(dirfd, F_GETPATH, dirpath) != -1 && pt_is_sensitive_host_fd_path(dirpath, caller)) {
        errno = ENOENT;
        return -1;
    }
    int is_sys_int = 0;
    int in_data_root = (dirpath[0] != '\0') ? (pt_path_equals_real_data_root(dirpath) ? 1 : 0) : -1;
    const struct attrlist *alist = (const struct attrlist *)attrList;

    for (;;) {
        int count = getattrlistbulk(dirfd, attrList, attrBuf, attrBufSize, options);
        if (count <= 0 || attrBuf == NULL || alist == NULL) {
            return count;
        }
        char *read_ptr = (char *)attrBuf;
        char *write_ptr = (char *)attrBuf;
        char *buf_end = (char *)attrBuf + attrBufSize;
        int kept = 0;

        for (int i = 0; i < count && read_ptr + sizeof(uint32_t) <= buf_end; i++) {
            uint32_t rec_len = *(uint32_t *)read_ptr;
            if (rec_len < sizeof(uint32_t) || read_ptr + rec_len > buf_end) {
                break;
            }
            BOOL hide = NO;
            BOOL has_name = NO;
            size_t name_off = pt_attr_cmn_offset_in_record(alist, read_ptr, rec_len, options, ATTR_CMN_NAME, &has_name);
            if (has_name && name_off + sizeof(attrreference_t) <= rec_len) {
                const attrreference_t *nref = (const attrreference_t *)(read_ptr + name_off);
                uintptr_t nstart = (uintptr_t)nref + (uintptr_t)nref->attr_dataoffset;
                uintptr_t nend = (uintptr_t)read_ptr + (uintptr_t)rec_len;
                if (nref->attr_dataoffset > 0 && nstart >= (uintptr_t)read_ptr && nstart < nend) {
                    char nbuf[NAME_MAX + 1];
                    size_t nmax = (size_t)(nend - nstart);
                    size_t nc = (nref->attr_length < nmax) ? (size_t)nref->attr_length : nmax;
                    if (nc >= sizeof(nbuf)) nc = sizeof(nbuf) - 1;
                    memcpy(nbuf, (const void *)nstart, nc);
                    nbuf[nc] = '\0';
                    if (pt_should_hide_dirent(nbuf, DT_UNKNOWN, caller, &is_sys_int, &in_data_root, NULL, dirfd, (dirpath[0] != '\0') ? dirpath : NULL)) {
                        hide = YES;
                    }
                }
            }
            if (!hide) {
                pt_sanitize_attr_fullpath_in_record(alist, read_ptr, rec_len, options, NO, caller);
                if (write_ptr != read_ptr) {
                    memmove(write_ptr, read_ptr, rec_len);
                }
                write_ptr += rec_len;
                kept++;
            }
            read_ptr += rec_len;
        }
        if (kept > 0) {
            return kept;
        }
    }
}

static int pt_setattrlist(const char *path, void *attrList, void *attrBuf, size_t attrBufSize, unsigned int options) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return setattrlist(path, attrList, attrBuf, attrBufSize, options);
}

static int pt_fsetattrlist(int fd, void *attrList, void *attrBuf, size_t attrBufSize, unsigned int options) {
    if (pt_fd_is_sensitive(fd, __builtin_return_address(0))) {
        errno = EACCES;
        return -1;
    }
    return fsetattrlist(fd, attrList, attrBuf, attrBufSize, options);
}

static long pt_pathconf(const char *path, int name) {
    const void *caller = __builtin_return_address(0);
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path(path, caller, vbuf, sizeof(vbuf), &resolved);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        pt_ensure_data_container_map();
        resolved = (s_real_data_container_len > 0) ? s_real_data_container_dir : "/private/var";
    }
    return pathconf(resolved, name);
}

static long pt_fpathconf(int fd, int name) {
    if (fd < 0) {
        errno = EBADF;
        return -1;
    }
    if (pt_fd_is_sensitive(fd, __builtin_return_address(0))) {
        errno = EBADF;
        return -1;
    }
    return fpathconf(fd, name);
}

static void pt_sanitize_statfs_entry(struct statfs *buf, const void *caller, int *inout_is_sys) {
    if (buf == NULL) {
        return;
    }
    if (*inout_is_sys < 0) {
        *inout_is_sys = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
    }
    if (*inout_is_sys != 0) {
        return;
    }
    if (strcmp(buf->f_mntonname, "/System/Volumes/Data") == 0 ||
        strncmp(buf->f_mntonname, "/Volumes/", 9) == 0 ||
        strncmp(buf->f_mntonname, "/Users/", 7) == 0 ||
        strncmp(buf->f_mntonname, "/System/Volumes/Data/Users/", 27) == 0) {
        strlcpy(buf->f_mntonname, "/private/var", sizeof(buf->f_mntonname));
        strlcpy(buf->f_mntfromname, "/dev/disk0s1s2", sizeof(buf->f_mntfromname));
    } else if (strncmp(buf->f_mntonname, "/System/Volumes/Data/", 21) == 0) {
        char stripped[MFSTYPENAMELEN + MAXPATHLEN];
        strlcpy(stripped, buf->f_mntonname + 20, sizeof(stripped));
        strlcpy(buf->f_mntonname, stripped, sizeof(buf->f_mntonname));
    }
    if (strcmp(buf->f_mntonname, "/") == 0) {
        strlcpy(buf->f_mntfromname, "/dev/disk0s1s1", sizeof(buf->f_mntfromname));
    } else if (strcmp(buf->f_mntonname, "/private/var") == 0) {
        strlcpy(buf->f_mntfromname, "/dev/disk0s1s2", sizeof(buf->f_mntfromname));
    }
}

static BOOL pt_should_hide_mount_entry(const struct statfs *buf) {
    if (buf == NULL) {
        return NO;
    }
    return (strcmp(buf->f_mntonname, "/") != 0 &&
            strcmp(buf->f_mntonname, "/System/Volumes/Data") != 0 &&
            strcmp(buf->f_mntonname, "/private/var") != 0 &&
            strcmp(buf->f_mntonname, "/private/var/mobile") != 0);
}

static int pt_filter_statfs_array(struct statfs *buf, int count, const void *caller) {
    if (count <= 0 || buf == NULL || !pt_is_bypass_enabled()) {
        return count;
    }
    int is_sys = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
    if (is_sys != 0) {
        return count;
    }
    int kept = 0;
    for (int i = 0; i < count; i++) {
        if (pt_should_hide_mount_entry(&buf[i])) {
            continue;
        }
        pt_sanitize_statfs_entry(&buf[i], caller, &is_sys);
        if (kept != i) {
            buf[kept] = buf[i];
        }
        kept++;
    }
    return kept;
}

static int pt_statfs(const char *path, struct statfs *buf) {
    const void *caller = __builtin_return_address(0);
    int is_sys_caller = -1;
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(path, caller, vbuf, sizeof(vbuf), &path, &is_sys_caller);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        pt_ensure_data_container_map();
        path = (s_real_data_container_len > 0) ? s_real_data_container_dir : "/private/var";
    }
    int ret = statfs(path, buf);
    if (ret == 0 && buf != NULL) {
        pt_sanitize_statfs_entry(buf, caller, &is_sys_caller);
    }
    return ret;
}

static int pt_fstatfs(int fd, struct statfs *buf) {
    const void *caller = __builtin_return_address(0);
    if (pt_fd_is_sensitive(fd, caller)) {
        errno = EBADF;
        return -1;
    }
    int is_sys_caller = -1;
    int ret = fstatfs(fd, buf);
    if (ret == 0 && buf != NULL) {
        pt_sanitize_statfs_entry(buf, caller, &is_sys_caller);
    }
    return ret;
}

static int pt_getfsstat(struct statfs *buf, int bufsize, int mode) {
    const void *caller = __builtin_return_address(0);
    int count = getfsstat(buf, bufsize, mode);
    if (count > 0 && buf != NULL && bufsize > 0) {
        return pt_filter_statfs_array(buf, count, caller);
    }
    return count;
}

static int pt_getmntinfo(struct statfs **mntbufp, int mode) {
    const void *caller = __builtin_return_address(0);
    int count = getmntinfo(mntbufp, mode);
    if (count > 0 && mntbufp != NULL && *mntbufp != NULL) {
        return pt_filter_statfs_array(*mntbufp, count, caller);
    }
    return count;
}

static int pt_getmntinfo_r_np(struct statfs **mntbufp, int mode) {
    const void *caller = __builtin_return_address(0);
    int count = getmntinfo_r_np(mntbufp, mode);
    if (count > 0 && mntbufp != NULL && *mntbufp != NULL) {
        return pt_filter_statfs_array(*mntbufp, count, caller);
    }
    return count;
}

static int pt_statvfs(const char * restrict path, struct statvfs * restrict buf) {
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path(path, __builtin_return_address(0), vbuf, sizeof(vbuf), &resolved);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        pt_ensure_data_container_map();
        resolved = (s_real_data_container_len > 0) ? s_real_data_container_dir : "/private/var";
    }
    return statvfs(resolved, buf);
}

static int pt_fstatvfs(int fd, struct statvfs *buf) {
    if (pt_fd_is_sensitive(fd, __builtin_return_address(0))) {
        errno = EBADF;
        return -1;
    }
    return fstatvfs(fd, buf);
}


static int pt_rename(char const* restrict old_name, char const* restrict new_name) {
    char vbuf1[PATH_MAX];
    char vbuf2[PATH_MAX];
    const char *resolved_old = NULL;
    const char *resolved_new = NULL;
    const void *caller = __builtin_return_address(0);
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, old_name, caller, vbuf1, sizeof(vbuf1), &resolved_old, EACCES) ||
        !pt_prepare_fs_path_for_modify(AT_FDCWD, new_name, caller, vbuf2, sizeof(vbuf2), &resolved_new, EACCES)) {
        return -1;
    }
    return rename(resolved_old, resolved_new);
}

static int pt_renameat(int fromfd, const char *from, int tofd, const char *to) {
    char vbuf1[PATH_MAX];
    char vbuf2[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    if (!pt_prepare_fs_path_for_modify(fromfd, from, caller, vbuf1, sizeof(vbuf1), &from, EACCES) ||
        !pt_prepare_fs_path_for_modify(tofd, to, caller, vbuf2, sizeof(vbuf2), &to, EACCES)) {
        return -1;
    }
    return renameat(fromfd, from, tofd, to);
}

static int pt_renamex_np(const char *from, const char *to, unsigned int flags) {
    char vbuf1[PATH_MAX];
    char vbuf2[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, from, caller, vbuf1, sizeof(vbuf1), &from, EACCES) ||
        !pt_prepare_fs_path_for_modify(AT_FDCWD, to, caller, vbuf2, sizeof(vbuf2), &to, EACCES)) {
        return -1;
    }
    return renamex_np(from, to, flags);
}

static int pt_renameatx_np(int fromfd, const char *from, int tofd, const char *to, unsigned int flags) {
    char vbuf1[PATH_MAX];
    char vbuf2[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    if (!pt_prepare_fs_path_for_modify(fromfd, from, caller, vbuf1, sizeof(vbuf1), &from, EACCES) ||
        !pt_prepare_fs_path_for_modify(tofd, to, caller, vbuf2, sizeof(vbuf2), &to, EACCES)) {
        return -1;
    }
    return renameatx_np(fromfd, from, tofd, to, flags);
}

static int pt_unlink(char const* path) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return unlink(path);
}

static int pt_unlinkat(int fd, const char *path, int flag) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(fd, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return unlinkat(fd, path, flag);
}

static int pt_remove(const char *path) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return remove(path);
}

static int pt_removefile(const char *path, removefile_state_t state, removefile_flags_t flags) {
    char vbuf[PATH_MAX];
    if (path != NULL &&
        !pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return removefile(path, state, flags);
}

static int pt_link(const char *path1, const char *path2) {
    char vbuf1[PATH_MAX];
    char vbuf2[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path1, caller, vbuf1, sizeof(vbuf1), &path1, EACCES) ||
        !pt_prepare_fs_path_for_modify(AT_FDCWD, path2, caller, vbuf2, sizeof(vbuf2), &path2, EACCES)) {
        return -1;
    }
    return link(path1, path2);
}

static int pt_linkat(int fd1, const char *path1, int fd2, const char *path2, int flag) {
    char vbuf1[PATH_MAX];
    char vbuf2[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    if (!pt_prepare_fs_path_for_modify(fd1, path1, caller, vbuf1, sizeof(vbuf1), &path1, EACCES) ||
        !pt_prepare_fs_path_for_modify(fd2, path2, caller, vbuf2, sizeof(vbuf2), &path2, EACCES)) {
        return -1;
    }
    return linkat(fd1, path1, fd2, path2, flag);
}

static int pt_symlink(const char *path1, const char *path2) {
    char vbuf1[PATH_MAX];
    char vbuf2[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path1, caller, vbuf1, sizeof(vbuf1), &path1, EACCES) ||
        !pt_prepare_fs_path_for_modify(AT_FDCWD, path2, caller, vbuf2, sizeof(vbuf2), &path2, EACCES)) {
        return -1;
    }
    return symlink(path1, path2);
}

static int pt_symlinkat(const char *path1, int fd, const char *path2) {
    char vbuf1[PATH_MAX];
    char vbuf2[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path1, caller, vbuf1, sizeof(vbuf1), &path1, EACCES) ||
        !pt_prepare_fs_path_for_modify(fd, path2, caller, vbuf2, sizeof(vbuf2), &path2, EACCES)) {
        return -1;
    }
    return symlinkat(path1, fd, path2);
}

static int pt_chmod(const char *path, mode_t mode) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return chmod(path, mode);
}

static int pt_lchmod(const char *path, mode_t mode) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return lchmod(path, mode);
}

static int pt_fchmodat(int fd, const char *path, mode_t mode, int flag) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(fd, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return fchmodat(fd, path, mode, flag);
}

static int pt_chown(const char *path, uid_t owner, gid_t group) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return chown(path, owner, group);
}

static int pt_lchown(const char *path, uid_t owner, gid_t group) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return lchown(path, owner, group);
}

static int pt_fchownat(int fd, const char *path, uid_t owner, gid_t group, int flag) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(fd, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return fchownat(fd, path, owner, group, flag);
}

static int pt_chflags(const char *path, __uint32_t flags) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return chflags(path, flags);
}

static int pt_lchflags(const char *path, __uint32_t flags) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return lchflags(path, flags);
}

static int pt_truncate(const char *path, off_t length) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return truncate(path, length);
}

static int pt_utimes(const char *path, const struct timeval *times) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return utimes(path, times);
}

static int pt_lutimes(const char *path, const struct timeval *times) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return lutimes(path, times);
}

static int pt_utimensat(int fd, const char *path, const struct timespec times[2], int flag) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(fd, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return utimensat(fd, path, times, flag);
}

static int pt_utime(const char *path, const struct utimbuf *times) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    return utime(path, times);
}

static BOOL pt_is_hidden_traversed_entry(const char *path,
                                         const char *d_name_hint,
                                         const void *caller,
                                         int *inout_is_sys_caller) {
    if (path == NULL || path[0] == '\0' || !pt_is_bypass_enabled()) {
        return NO;
    }
    if (*inout_is_sys_caller < 0) {
        *inout_is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
    }
    if (*inout_is_sys_caller != 0) {
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
    if (pt_is_hidden_normalized_path_cached_caller(norm, caller, inout_is_sys_caller)) {
        return YES;
    }

    const char *base = d_name_hint;
    if (base == NULL || base[0] == '\0') {
        const char *slash = strrchr(norm, '/');
        base = (slash != NULL) ? (slash + 1) : norm;
    }
    if (pt_is_hidden_dirent_name(base)) {
        return YES;
    }
    if (pt_is_macos_data_root_symlink_name(base) && norm[0] == '/') {
        const char *slash = strrchr(norm, '/');
        if (slash != NULL) {
            BOOL is_data_root = NO;
            size_t parent_len = (size_t)(slash - norm);
            if (parent_len == 0) {
                is_data_root = pt_path_equals_real_data_root("/");
            } else if (parent_len < PATH_MAX) {
                char parent[PATH_MAX];
                memcpy(parent, norm, parent_len);
                parent[parent_len] = '\0';
                is_data_root = pt_path_equals_real_data_root(parent);
            }
            if (is_data_root) {
                if (strcmp(base, "Desktop") == 0) {
                    return YES;
                }
                struct stat st;
                if (lstat(norm, &st) == 0 && S_ISLNK(st.st_mode)) {
                    return YES;
                }
            }
        }
    }
    return NO;
}

typedef struct pt_ftw_tls_ctx {
    int (*ftw_fn)(const char *, const struct stat *, int);
    int (*nftw_fn)(const char *, const struct stat *, int, struct FTW *);
    const void *caller;
    int is_sys_caller;
    struct pt_ftw_tls_ctx *prev;
} pt_ftw_tls_ctx_t;

static _Thread_local pt_ftw_tls_ctx_t *tls_pt_ftw_ctx = NULL;

static int pt_ftw_trampoline(const char *fpath, const struct stat *sb, int typeflag) {
    pt_ftw_tls_ctx_t *ctx = tls_pt_ftw_ctx;
    if (ctx == NULL || ctx->ftw_fn == NULL) {
        return 0;
    }
    if (fpath != NULL && pt_is_hidden_traversed_entry(fpath, NULL, ctx->caller, &ctx->is_sys_caller)) {
        return 0;
    }
    char vout[PATH_MAX];
    const char *virt = fpath;
    if (fpath != NULL && ctx->is_sys_caller == 0) {
        virt = pt_virtualize_path_for_app(fpath, vout, sizeof(vout), YES);
    }
    return ctx->ftw_fn(virt, sb, typeflag);
}

static int pt_nftw_trampoline(const char *fpath, const struct stat *sb, int typeflag, struct FTW *ftwbuf) {
    pt_ftw_tls_ctx_t *ctx = tls_pt_ftw_ctx;
    if (ctx == NULL || ctx->nftw_fn == NULL) {
        return 0;
    }
    if (fpath != NULL && pt_is_hidden_traversed_entry(fpath, NULL, ctx->caller, &ctx->is_sys_caller)) {
        return 0;
    }
    char vout[PATH_MAX];
    const char *virt = fpath;
    struct FTW ftw_local;
    struct FTW *out_ftwbuf = ftwbuf;
    if (fpath != NULL && ctx->is_sys_caller == 0) {
        virt = pt_virtualize_path_for_app(fpath, vout, sizeof(vout), YES);
        if (virt != fpath && ftwbuf != NULL) {
            ftw_local = *ftwbuf;
            const char *slash = strrchr(virt, '/');
            ftw_local.base = (slash != NULL) ? (int)(slash - virt + 1) : 0;
            out_ftwbuf = &ftw_local;
        }
    }
    return ctx->nftw_fn(virt, sb, typeflag, out_ftwbuf);
}

static int pt_ftw(const char *dirpath, int (*fn)(const char *, const struct stat *, int), int nopenfd) {
    char vbuf[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    int is_sys_caller = -1;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(dirpath, caller, vbuf, sizeof(vbuf), &dirpath, &is_sys_caller);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return -1;
    }
    if (fn == NULL || !pt_is_bypass_enabled() || is_sys_caller == 1 ||
        (is_sys_caller < 0 && pt_is_effective_system_or_playtools_caller(caller))) {
        return ftw(dirpath, fn, nopenfd);
    }
    pt_ftw_tls_ctx_t ctx = {
        .ftw_fn = fn,
        .nftw_fn = NULL,
        .caller = caller,
        .is_sys_caller = 0,
        .prev = tls_pt_ftw_ctx,
    };
    tls_pt_ftw_ctx = &ctx;
    int ret = ftw(dirpath, pt_ftw_trampoline, nopenfd);
    tls_pt_ftw_ctx = ctx.prev;
    return ret;
}

static int pt_nftw(const char *dirpath, int (*fn)(const char *, const struct stat *, int, struct FTW *), int nopenfd, int flags) {
    char vbuf[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    int is_sys_caller = -1;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(dirpath, caller, vbuf, sizeof(vbuf), &dirpath, &is_sys_caller);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return -1;
    }
    if (fn == NULL || !pt_is_bypass_enabled() || is_sys_caller == 1 ||
        (is_sys_caller < 0 && pt_is_effective_system_or_playtools_caller(caller))) {
        return nftw(dirpath, fn, nopenfd, flags);
    }
    pt_ftw_tls_ctx_t ctx = {
        .ftw_fn = NULL,
        .nftw_fn = fn,
        .caller = caller,
        .is_sys_caller = 0,
        .prev = tls_pt_ftw_ctx,
    };
    tls_pt_ftw_ctx = &ctx;
    int ret = nftw(dirpath, pt_nftw_trampoline, nopenfd, flags);
    tls_pt_ftw_ctx = ctx.prev;
    return ret;
}

typedef struct pt_fts_child_record {
    FTSENT *ent;
    char *orig_path;
    char *orig_accpath;
    char *virt_path;
    char *virt_accpath;
    FTSENT *orig_link;
    BOOL link_overridden;
    __typeof__(((FTSENT *)0)->fts_pathlen) orig_pathlen;
    struct pt_fts_child_record *next;
} pt_fts_child_record_t;

typedef struct {
    const void *caller;
    int is_sys_caller;
    BOOL use_private_prefix;
    FTSENT *cur_ent;
    char *orig_cur_path;
    char *orig_cur_accpath;
    __typeof__(((FTSENT *)0)->fts_pathlen) orig_cur_pathlen;
    pt_fts_child_record_t *children;
    char cur_virt_path[PATH_MAX];
} pt_fts_state_t;

static os_unfair_lock s_fts_states_lock = OS_UNFAIR_LOCK_INIT;
static CFMutableDictionaryRef s_fts_states = NULL;

static pt_fts_state_t *pt_fts_lookup_state(FTS *ftsp) {
    if (ftsp == NULL) {
        return NULL;
    }
    pt_fts_state_t *state = NULL;
    os_unfair_lock_lock(&s_fts_states_lock);
    if (s_fts_states != NULL) {
        state = (pt_fts_state_t *)CFDictionaryGetValue(s_fts_states, ftsp);
    }
    os_unfair_lock_unlock(&s_fts_states_lock);
    return state;
}

static void pt_fts_restore_cur(pt_fts_state_t *state) {
    if (state == NULL || state->cur_ent == NULL) {
        return;
    }
    state->cur_ent->fts_path = state->orig_cur_path;
    state->cur_ent->fts_accpath = state->orig_cur_accpath;
    state->cur_ent->fts_pathlen = state->orig_cur_pathlen;
    state->cur_ent = NULL;
    state->orig_cur_path = NULL;
    state->orig_cur_accpath = NULL;
    state->orig_cur_pathlen = 0;
}

static void pt_fts_restore_children(pt_fts_state_t *state) {
    if (state == NULL) {
        return;
    }
    pt_fts_child_record_t *rec = state->children;
    state->children = NULL;
    while (rec != NULL) {
        pt_fts_child_record_t *next = rec->next;
        if (rec->ent != NULL) {
            rec->ent->fts_path = rec->orig_path;
            rec->ent->fts_accpath = rec->orig_accpath;
            rec->ent->fts_pathlen = rec->orig_pathlen;
            if (rec->link_overridden) {
                rec->ent->fts_link = rec->orig_link;
            }
        }
        free(rec->virt_path);
        free(rec->virt_accpath);
        free(rec);
        rec = next;
    }
}

static FTS *pt_fts_open_common(char * const *path_argv,
                               int options,
                               int (*compar)(const FTSENT **, const FTSENT **),
#ifdef __BLOCKS__
                               int (^compar_b)(const FTSENT **, const FTSENT **),
                               BOOL use_block,
#endif
                               const void *caller) {
    if (path_argv == NULL || path_argv[0] == NULL || !pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(caller)) {
#ifdef __BLOCKS__
        if (use_block) {
            return fts_open_b(path_argv, options, compar_b);
        }
#endif
        return fts_open(path_argv, options, compar);
    }

    size_t argc = 0;
    while (path_argv[argc] != NULL) {
        argc++;
    }
    char **mapped_argv = (char **)calloc(argc + 1U, sizeof(char *));
    char **owned_strs = (char **)calloc(argc + 1U, sizeof(char *));
    if (mapped_argv == NULL || owned_strs == NULL) {
        free(mapped_argv);
        free(owned_strs);
        errno = ENOMEM;
        return NULL;
    }

    size_t out_idx = 0;
    size_t owned_idx = 0;
    int sys_caller = 0;
    for (size_t i = 0; i < argc; i++) {
        char vbuf[PATH_MAX];
        const char *resolved = NULL;
        pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(path_argv[i], caller, vbuf, sizeof(vbuf), &resolved, &sys_caller);
        if (disp == PT_FS_PATH_HIDDEN || disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
            continue;
        }
        char *dup = strdup(resolved != NULL ? resolved : path_argv[i]);
        if (dup == NULL) {
            for (size_t j = 0; j < owned_idx; j++) {
                free(owned_strs[j]);
            }
            free(owned_strs);
            free(mapped_argv);
            errno = ENOMEM;
            return NULL;
        }
        owned_strs[owned_idx++] = dup;
        mapped_argv[out_idx++] = dup;
    }

    if (out_idx == 0) {
        for (size_t j = 0; j < owned_idx; j++) {
            free(owned_strs[j]);
        }
        free(owned_strs);
        free(mapped_argv);
        errno = ENOENT;
        return NULL;
    }

#ifdef __BLOCKS__
    FTS *ftsp = use_block ? fts_open_b(mapped_argv, options, compar_b) : fts_open(mapped_argv, options, compar);
#else
    FTS *ftsp = fts_open(mapped_argv, options, compar);
#endif
    int saved_errno = errno;
    for (size_t j = 0; j < owned_idx; j++) {
        free(owned_strs[j]);
    }
    free(owned_strs);
    free(mapped_argv);

    if (ftsp != NULL) {
        pt_fts_state_t *state = (pt_fts_state_t *)calloc(1U, sizeof(pt_fts_state_t));
        if (state != NULL) {
            state->caller = caller;
            state->is_sys_caller = 0;
            state->use_private_prefix = (strncmp(path_argv[0], "/private/", 9) == 0);
            os_unfair_lock_lock(&s_fts_states_lock);
            if (s_fts_states == NULL) {
                s_fts_states = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
            }
            if (s_fts_states != NULL) {
                CFDictionarySetValue(s_fts_states, ftsp, state);
            } else {
                free(state);
            }
            os_unfair_lock_unlock(&s_fts_states_lock);
        }
    }
    errno = saved_errno;
    return ftsp;
}

static FTS *pt_fts_open(char * const *path_argv, int options, int (*compar)(const FTSENT **, const FTSENT **)) {
    return pt_fts_open_common(path_argv, options, compar,
#ifdef __BLOCKS__
                              NULL, NO,
#endif
                              __builtin_return_address(0));
}

#ifdef __BLOCKS__
static FTS *pt_fts_open_b(char * const *path_argv, int options, int (^compar)(const FTSENT **, const FTSENT **)) {
    return pt_fts_open_common(path_argv, options, NULL, compar, YES, __builtin_return_address(0));
}
#endif

static FTSENT *pt_fts_read(FTS *ftsp) {
    pt_fts_state_t *state = pt_fts_lookup_state(ftsp);
    if (state != NULL) {
        pt_fts_restore_cur(state);
        pt_fts_restore_children(state);
    }
    if (ftsp == NULL || state == NULL || !pt_is_bypass_enabled()) {
        return fts_read(ftsp);
    }

    for (;;) {
        FTSENT *ent = fts_read(ftsp);
        if (ent == NULL) {
            return NULL;
        }
        if (ent->fts_path != NULL &&
            pt_is_hidden_traversed_entry(ent->fts_path, ent->fts_name, state->caller, &state->is_sys_caller)) {
            if (ent->fts_info == FTS_D) {
                fts_set(ftsp, ent, FTS_SKIP);
            }
            continue;
        }
        if (ent->fts_path != NULL && state->is_sys_caller == 0) {
            const char *virt = pt_virtualize_path_for_app(ent->fts_path, state->cur_virt_path, sizeof(state->cur_virt_path), state->use_private_prefix);
            if (virt != ent->fts_path) {
                state->cur_ent = ent;
                state->orig_cur_path = ent->fts_path;
                state->orig_cur_accpath = ent->fts_accpath;
                state->orig_cur_pathlen = ent->fts_pathlen;
                ent->fts_path = state->cur_virt_path;
                size_t vlen = strlen(state->cur_virt_path);
                size_t max_plen = (sizeof(ent->fts_pathlen) == sizeof(unsigned short)) ? (size_t)USHRT_MAX : SIZE_MAX;
                ent->fts_pathlen = (__typeof__(ent->fts_pathlen))MIN(vlen, max_plen);
                if (ent->fts_accpath != NULL && ent->fts_accpath[0] == '/') {
                    ent->fts_accpath = state->cur_virt_path;
                }
            }
        }
        return ent;
    }
}

static const char *pt_fts_build_child_fullpath(const FTSENT *c, char *buf, size_t bufsize) {
    if (c == NULL || buf == NULL || bufsize == 0) {
        return NULL;
    }
    if (c->fts_path != NULL && c->fts_path[0] != '\0') {
        size_t plen = strlen(c->fts_path);
        int n = (plen > 0 && c->fts_path[plen - 1] == '/')
            ? snprintf(buf, bufsize, "%s%s", c->fts_path, c->fts_name)
            : snprintf(buf, bufsize, "%s/%s", c->fts_path, c->fts_name);
        return (n > 0 && (size_t)n < bufsize) ? buf : NULL;
    }
    if (c->fts_accpath != NULL && c->fts_accpath[0] != '\0') {
        return c->fts_accpath;
    }
    return c->fts_name;
}

static FTSENT *pt_fts_children(FTS *ftsp, int instr) {
    pt_fts_state_t *state = pt_fts_lookup_state(ftsp);
    if (state != NULL) {
        pt_fts_restore_cur(state);
        pt_fts_restore_children(state);
    }
    FTSENT *head = fts_children(ftsp, instr);
    if (head == NULL || state == NULL || !pt_is_bypass_enabled() || state->is_sys_caller == 1) {
        return head;
    }

    FTSENT *out_head = NULL;
    FTSENT *prev_visible = NULL;
    pt_fts_child_record_t *prev_visible_rec = NULL;
    pt_fts_child_record_t *rec_tail = NULL;

    for (FTSENT *curr = head; curr != NULL;) {
        FTSENT *next = curr->fts_link;
        pt_fts_child_record_t *rec = (pt_fts_child_record_t *)calloc(1U, sizeof(pt_fts_child_record_t));
        if (rec == NULL) {
            pt_fts_restore_children(state);
            return head;
        }
        rec->ent = curr;
        rec->orig_path = curr->fts_path;
        rec->orig_accpath = curr->fts_accpath;
        rec->orig_pathlen = curr->fts_pathlen;
        rec->orig_link = next;
        rec->link_overridden = NO;
        if (rec_tail == NULL) {
            state->children = rec;
        } else {
            rec_tail->next = rec;
        }
        rec_tail = rec;

        char fullbuf[PATH_MAX];
        const char *full = pt_fts_build_child_fullpath(curr, fullbuf, sizeof(fullbuf));
        BOOL hidden = (full != NULL &&
                       pt_is_hidden_traversed_entry(full, curr->fts_name, state->caller, &state->is_sys_caller));
        if (hidden) {
            if (prev_visible != NULL) {
                prev_visible->fts_link = next;
                if (prev_visible_rec != NULL) {
                    prev_visible_rec->link_overridden = YES;
                }
            }
        } else {
            if (out_head == NULL) {
                out_head = curr;
            }
            if (state->is_sys_caller == 0) {
                if (curr->fts_path != NULL && curr->fts_path[0] != '\0') {
                    char vbuf[PATH_MAX];
                    const char *vp = pt_virtualize_path_for_app(curr->fts_path, vbuf, sizeof(vbuf), state->use_private_prefix);
                    if (vp != curr->fts_path) {
                        rec->virt_path = strdup(vp);
                        if (rec->virt_path != NULL) {
                            curr->fts_path = rec->virt_path;
                            size_t vplen = strlen(rec->virt_path);
                            size_t sep = (vplen > 0 && rec->virt_path[vplen - 1] == '/') ? 0U : 1U;
                            size_t new_plen = vplen + sep + (size_t)curr->fts_namelen;
                            size_t max_plen = (sizeof(curr->fts_pathlen) == sizeof(unsigned short)) ? (size_t)USHRT_MAX : SIZE_MAX;
                            curr->fts_pathlen = (__typeof__(curr->fts_pathlen))MIN(new_plen, max_plen);
                            if (curr->fts_accpath != NULL && curr->fts_accpath[0] == '/') {
                                if (rec->orig_path != NULL && strcmp(curr->fts_accpath, rec->orig_path) == 0) {
                                    curr->fts_accpath = rec->virt_path;
                                } else {
                                    char vabuf[PATH_MAX];
                                    const char *va = pt_virtualize_path_for_app(curr->fts_accpath, vabuf, sizeof(vabuf), state->use_private_prefix);
                                    if (va != curr->fts_accpath) {
                                        rec->virt_accpath = strdup(va);
                                        if (rec->virt_accpath != NULL) {
                                            curr->fts_accpath = rec->virt_accpath;
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else if (curr->fts_accpath != NULL && curr->fts_accpath[0] == '/') {
                    char vabuf[PATH_MAX];
                    const char *va = pt_virtualize_path_for_app(curr->fts_accpath, vabuf, sizeof(vabuf), state->use_private_prefix);
                    if (va != curr->fts_accpath) {
                        rec->virt_accpath = strdup(va);
                        if (rec->virt_accpath != NULL) {
                            curr->fts_accpath = rec->virt_accpath;
                        }
                    }
                }
            }
            prev_visible = curr;
            prev_visible_rec = rec;
        }
        curr = next;
    }
    return out_head;
}

static int pt_fts_set(FTS *ftsp, FTSENT *sp, int instr) {
    pt_fts_state_t *state = pt_fts_lookup_state(ftsp);
    if (state != NULL) {
        pt_fts_restore_cur(state);
        if (sp != NULL) {
            for (pt_fts_child_record_t *rec = state->children; rec != NULL; rec = rec->next) {
                if (rec->ent == sp) {
                    sp->fts_path = rec->orig_path;
                    sp->fts_accpath = rec->orig_accpath;
                    sp->fts_pathlen = rec->orig_pathlen;
                    break;
                }
            }
        }
    }
    return fts_set(ftsp, sp, instr);
}

static int pt_fts_close(FTS *ftsp) {
    if (ftsp != NULL) {
        pt_fts_state_t *state = NULL;
        os_unfair_lock_lock(&s_fts_states_lock);
        if (s_fts_states != NULL) {
            state = (pt_fts_state_t *)CFDictionaryGetValue(s_fts_states, ftsp);
            if (state != NULL) {
                CFDictionaryRemoveValue(s_fts_states, ftsp);
            }
        }
        os_unfair_lock_unlock(&s_fts_states_lock);
        if (state != NULL) {
            pt_fts_restore_cur(state);
            pt_fts_restore_children(state);
            free(state);
        }
    }
    return fts_close(ftsp);
}

static int pt_filter_and_virtualize_glob(glob_t *pglob,
                                         int flags,
                                         size_t start_match_idx,
                                         const void *caller,
                                         int *inout_is_sys_caller) {
    if (pglob == NULL || pglob->gl_pathv == NULL || pglob->gl_pathc <= start_match_idx) {
        return 0;
    }
    size_t offs = ((flags & GLOB_DOOFFS) != 0) ? pglob->gl_offs : 0U;
    size_t orig_pathc = pglob->gl_pathc;
    size_t write_idx = start_match_idx;
    for (size_t i = start_match_idx; i < orig_pathc; i++) {
        char *entry = pglob->gl_pathv[offs + i];
        if (entry == NULL) {
            continue;
        }
        if (pt_is_hidden_traversed_entry(entry, NULL, caller, inout_is_sys_caller)) {
            free(entry);
            continue;
        }
        char vout[PATH_MAX];
        const char *virt = pt_virtualize_path_for_app(entry, vout, sizeof(vout), YES);
        if (virt != entry) {
            char *vdup = strdup(virt);
            if (vdup != NULL) {
                free(entry);
                entry = vdup;
            }
        }
        pglob->gl_pathv[offs + write_idx] = entry;
        write_idx++;
    }
    for (size_t i = write_idx; i < orig_pathc; i++) {
        pglob->gl_pathv[offs + i] = NULL;
    }
    pglob->gl_pathc = write_idx;
    if (write_idx == 0) {
        if ((flags & GLOB_APPEND) == 0) {
            globfree(pglob);
            pglob->gl_pathc = 0;
            pglob->gl_pathv = NULL;
        }
        return GLOB_NOMATCH;
    }
    return 0;
}

static int pt_glob(const char * __restrict pattern,
                   int flags,
                   int (*errfunc)(const char *, int),
                   glob_t * __restrict pglob) {
    char vbuf[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    int is_sys_caller = -1;
    const char *resolved_pattern = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(pattern, caller, vbuf, sizeof(vbuf), &resolved_pattern, &is_sys_caller);
    if (disp == PT_FS_PATH_HIDDEN || disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        if (pglob != NULL && (flags & GLOB_APPEND) == 0) {
            pglob->gl_pathc = 0;
            pglob->gl_pathv = NULL;
        }
        return GLOB_NOMATCH;
    }
    size_t start_idx = ((flags & GLOB_APPEND) != 0 && pglob != NULL) ? pglob->gl_pathc : 0U;
    int rc = glob(resolved_pattern, flags, errfunc, pglob);
    if ((rc == 0 || rc == GLOB_ABORTED) && pt_is_bypass_enabled() &&
        (is_sys_caller == 0 || (is_sys_caller < 0 && !pt_is_effective_system_or_playtools_caller(caller)))) {
        is_sys_caller = 0;
        int frc = pt_filter_and_virtualize_glob(pglob, flags, start_idx, caller, &is_sys_caller);
        if (rc == 0 && frc != 0) {
            return frc;
        }
    }
    return rc;
}

static int pt_glob_b(const char * __restrict pattern,
                     int flags,
                     int (^errblk)(const char *, int),
                     glob_t * __restrict pglob) {
    char vbuf[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    int is_sys_caller = -1;
    const char *resolved_pattern = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(pattern, caller, vbuf, sizeof(vbuf), &resolved_pattern, &is_sys_caller);
    if (disp == PT_FS_PATH_HIDDEN || disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        if (pglob != NULL && (flags & GLOB_APPEND) == 0) {
            pglob->gl_pathc = 0;
            pglob->gl_pathv = NULL;
        }
        return GLOB_NOMATCH;
    }
    size_t start_idx = ((flags & GLOB_APPEND) != 0 && pglob != NULL) ? pglob->gl_pathc : 0U;
    int rc = glob_b(resolved_pattern, flags, errblk, pglob);
    if ((rc == 0 || rc == GLOB_ABORTED) && pt_is_bypass_enabled() &&
        (is_sys_caller == 0 || (is_sys_caller < 0 && !pt_is_effective_system_or_playtools_caller(caller)))) {
        is_sys_caller = 0;
        int frc = pt_filter_and_virtualize_glob(pglob, flags, start_idx, caller, &is_sys_caller);
        if (rc == 0 && frc != 0) {
            return frc;
        }
    }
    return rc;
}

static int pt_posix_spawn_file_actions_addopen(posix_spawn_file_actions_t * actions,
                                               int fildes,
                                               const char * restrict path,
                                               int oflag,
                                               mode_t mode) {
    char vbuf[PATH_MAX];
    const char *resolved = NULL;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path(path, __builtin_return_address(0), vbuf, sizeof(vbuf), &resolved);
    if (disp == PT_FS_PATH_HIDDEN) {
        return ENOENT;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        return EPERM;
    }
    return posix_spawn_file_actions_addopen(actions, fildes, resolved, oflag, mode);
}

static inline BOOL pt_is_hidden_xattr_name(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return NO;
    }
    return (strcmp(name, "com.apple.quarantine") == 0 ||
            strcmp(name, "com.apple.provenance") == 0 ||
            strcmp(name, "com.apple.macl") == 0);
}

static ssize_t pt_filter_xattr_list_buffer(char *buf, ssize_t raw_len) {
    if (buf == NULL || raw_len <= 0) {
        return raw_len;
    }
    char *read_ptr = buf;
    char *write_ptr = buf;
    char *end = buf + raw_len;
    while (read_ptr < end) {
        size_t len = strnlen(read_ptr, (size_t)(end - read_ptr));
        if (len == (size_t)(end - read_ptr)) {
            size_t rem = (size_t)(end - read_ptr);
            if (write_ptr != read_ptr) {
                memmove(write_ptr, read_ptr, rem);
            }
            write_ptr += rem;
            break;
        }
        size_t entry_sz = len + 1U;
        if (!pt_is_hidden_xattr_name(read_ptr)) {
            if (write_ptr != read_ptr) {
                memmove(write_ptr, read_ptr, entry_sz);
            }
            write_ptr += entry_sz;
        }
        read_ptr += entry_sz;
    }
    return (ssize_t)(write_ptr - buf);
}

static ssize_t pt_listxattr_filtered(BOOL is_fd,
                                     int fd,
                                     const char *path,
                                     char *namebuff,
                                     size_t size,
                                     int options) {
    ssize_t raw_size = is_fd ? flistxattr(fd, NULL, 0, options) : listxattr(path, NULL, 0, options);
    if (raw_size <= 0) {
        return raw_size;
    }
    char stack_tmp[4096];
    char *tmp = stack_tmp;
    if ((size_t)raw_size > sizeof(stack_tmp)) {
        tmp = (char *)malloc((size_t)raw_size);
        if (tmp == NULL) {
            errno = ENOMEM;
            return -1;
        }
    }
    ssize_t filled = is_fd ? flistxattr(fd, tmp, (size_t)raw_size, options)
                           : listxattr(path, tmp, (size_t)raw_size, options);
    if (filled < 0) {
        int saved_errno = errno;
        if (tmp != stack_tmp) {
            free(tmp);
        }
        errno = saved_errno;
        return -1;
    }
    ssize_t filtered_len = pt_filter_xattr_list_buffer(tmp, filled);
    if (namebuff != NULL && size > 0) {
        if ((size_t)filtered_len > size) {
            if (tmp != stack_tmp) {
                free(tmp);
            }
            errno = ERANGE;
            return -1;
        }
        if (filtered_len > 0) {
            memcpy(namebuff, tmp, (size_t)filtered_len);
        }
    }
    if (tmp != stack_tmp) {
        free(tmp);
    }
    return filtered_len;
}

static ssize_t pt_getxattr(const char *path, const char *name, void *value, size_t size, u_int32_t position, int options) {
    const void *caller = __builtin_return_address(0);
    int is_sys = -1;
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(path, caller, vbuf, sizeof(vbuf), &path, &is_sys);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return -1;
    }
    if (is_sys < 0) {
        is_sys = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
    }
    if (is_sys == 0 && pt_is_bypass_enabled() && pt_is_hidden_xattr_name(name)) {
        errno = ENOATTR;
        return -1;
    }
    return getxattr(path, name, value, size, position, options);
}

static ssize_t pt_fgetxattr(int fd, const char *name, void *value, size_t size, u_int32_t position, int options) {
    const void *caller = __builtin_return_address(0);
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (!is_sys) {
        if (pt_fd_is_sensitive(fd, caller)) {
            errno = EBADF;
            return -1;
        }
        if (pt_is_bypass_enabled() && pt_is_hidden_xattr_name(name)) {
            errno = ENOATTR;
            return -1;
        }
    }
    return fgetxattr(fd, name, value, size, position, options);
}

static int pt_setxattr(const char *path, const char *name, const void *value, size_t size, u_int32_t position, int options) {
    const void *caller = __builtin_return_address(0);
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, caller, vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    if (!pt_is_effective_system_or_playtools_caller(caller) &&
        pt_is_bypass_enabled() &&
        pt_is_hidden_xattr_name(name)) {
        errno = EPERM;
        return -1;
    }
    return setxattr(path, name, value, size, position, options);
}

static int pt_fsetxattr(int fd, const char *name, const void *value, size_t size, u_int32_t position, int options) {
    const void *caller = __builtin_return_address(0);
    if (!pt_is_effective_system_or_playtools_caller(caller)) {
        if (pt_fd_is_sensitive(fd, caller)) {
            errno = EACCES;
            return -1;
        }
        if (pt_is_bypass_enabled() && pt_is_hidden_xattr_name(name)) {
            errno = EPERM;
            return -1;
        }
    }
    return fsetxattr(fd, name, value, size, position, options);
}

static ssize_t pt_listxattr(const char *path, char *namebuff, size_t size, int options) {
    const void *caller = __builtin_return_address(0);
    int is_sys = -1;
    char vbuf[PATH_MAX];
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(path, caller, vbuf, sizeof(vbuf), &path, &is_sys);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return -1;
    }
    if (is_sys < 0) {
        is_sys = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
    }
    if (is_sys != 0 || !pt_is_bypass_enabled()) {
        return listxattr(path, namebuff, size, options);
    }
    if (namebuff == NULL || size == 0) {
        return pt_listxattr_filtered(NO, -1, path, NULL, 0, options);
    }
    ssize_t ret = listxattr(path, namebuff, size, options);
    if (ret < 0 && errno == ERANGE) {
        return pt_listxattr_filtered(NO, -1, path, namebuff, size, options);
    }
    return pt_filter_xattr_list_buffer(namebuff, ret);
}

static ssize_t pt_flistxattr(int fd, char *namebuff, size_t size, int options) {
    const void *caller = __builtin_return_address(0);
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (!is_sys && pt_fd_is_sensitive(fd, caller)) {
        errno = EBADF;
        return -1;
    }
    if (is_sys || !pt_is_bypass_enabled()) {
        return flistxattr(fd, namebuff, size, options);
    }
    if (namebuff == NULL || size == 0) {
        return pt_listxattr_filtered(YES, fd, NULL, NULL, 0, options);
    }
    ssize_t ret = flistxattr(fd, namebuff, size, options);
    if (ret < 0 && errno == ERANGE) {
        return pt_listxattr_filtered(YES, fd, NULL, namebuff, size, options);
    }
    return pt_filter_xattr_list_buffer(namebuff, ret);
}

static int pt_removexattr(const char *path, const char *name, int options) {
    const void *caller = __builtin_return_address(0);
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, caller, vbuf, sizeof(vbuf), &path, EACCES)) {
        return -1;
    }
    if (!pt_is_effective_system_or_playtools_caller(caller) &&
        pt_is_bypass_enabled() &&
        pt_is_hidden_xattr_name(name)) {
        errno = ENOATTR;
        return -1;
    }
    return removexattr(path, name, options);
}

static int pt_fremovexattr(int fd, const char *name, int options) {
    const void *caller = __builtin_return_address(0);
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (!is_sys) {
        if (pt_fd_is_sensitive(fd, caller)) {
            errno = EACCES;
            return -1;
        }
        if (pt_is_bypass_enabled() && pt_is_hidden_xattr_name(name)) {
            errno = ENOATTR;
            return -1;
        }
    }
    return fremovexattr(fd, name, options);
}

static int pt_copyfile(const char *from, const char *to, copyfile_state_t state, copyfile_flags_t flags) {
    char vbuf1[PATH_MAX];
    char vbuf2[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    if (from != NULL &&
        !pt_prepare_fs_path_for_modify(AT_FDCWD, from, caller, vbuf1, sizeof(vbuf1), &from, EACCES)) {
        return -1;
    }
    if (to != NULL &&
        !pt_prepare_fs_path_for_modify(AT_FDCWD, to, caller, vbuf2, sizeof(vbuf2), &to, EACCES)) {
        return -1;
    }
    return copyfile(from, to, state, flags);
}

static int pt_clonefile(const char *src, const char *dst, uint32_t flags) {
    char vbuf1[PATH_MAX];
    char vbuf2[PATH_MAX];
    const void *caller = __builtin_return_address(0);
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, src, caller, vbuf1, sizeof(vbuf1), &src, EACCES) ||
        !pt_prepare_fs_path_for_modify(AT_FDCWD, dst, caller, vbuf2, sizeof(vbuf2), &dst, EACCES)) {
        return -1;
    }
    return clonefile(src, dst, flags);
}

static int pt_clonefileat(int src_dirfd, const char *src, int dst_dirfd, const char *dst, uint32_t flags) {
    const void *caller = __builtin_return_address(0);
    if (pt_fd_is_sensitive(src_dirfd, caller)) {
        errno = ENOENT;
        return -1;
    }
    if (pt_fd_is_sensitive(dst_dirfd, caller)) {
        errno = EACCES;
        return -1;
    }
    char vbuf1[PATH_MAX];
    char vbuf2[PATH_MAX];
    pt_fs_path_disposition_t disp_src = pt_prepare_fs_path_at(src_dirfd, src, caller, vbuf1, sizeof(vbuf1), &src);
    if (disp_src == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp_src == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EPERM;
        return -1;
    }
    if (!pt_prepare_fs_path_for_modify(dst_dirfd, dst, caller, vbuf2, sizeof(vbuf2), &dst, EACCES)) {
        return -1;
    }
    return clonefileat(src_dirfd, src, dst_dirfd, dst, flags);
}

static size_t pt_count_template_xs(const char *tmpl, int slen) {
    if (tmpl == NULL || slen < 0) {
        return 0;
    }
    size_t tlen = strlen(tmpl);
    if (tlen < (size_t)slen) {
        return 0;
    }
    size_t end = tlen - (size_t)slen;
    size_t x_count = 0;
    while (end > x_count && tmpl[end - 1 - x_count] == 'X') {
        x_count++;
    }
    return x_count;
}

static void pt_copy_template_xs(char *tmpl, const char *vbuf, int slen, size_t x_count) {
    if (tmpl == NULL || vbuf == NULL || slen < 0 || x_count == 0) {
        return;
    }
    size_t tlen = strlen(tmpl);
    size_t vlen = strlen(vbuf);
    size_t tail = x_count + (size_t)slen;
    if (tlen >= tail && vlen >= tail) {
        memcpy(tmpl + tlen - tail, vbuf + vlen - tail, x_count);
    }
}

static int pt_mkstemp(char *tmpl) {
    if (tmpl == NULL) {
        errno = EINVAL;
        return -1;
    }
    size_t x_count = pt_count_template_xs(tmpl, 0);
    char vbuf[PATH_MAX];
    const char *resolved = pt_resolve_virtual_path(tmpl, vbuf, sizeof(vbuf));
    if (resolved == vbuf) {
        int fd = mkstemp(vbuf);
        if (fd >= 0) {
            pt_copy_template_xs(tmpl, vbuf, 0, x_count);
        }
        return fd;
    }
    return mkstemp(tmpl);
}

static int pt_mkstemps(char *tmpl, int slen) {
    if (tmpl == NULL) {
        return mkstemps(tmpl, slen);
    }
    size_t x_count = pt_count_template_xs(tmpl, slen);
    char vbuf[PATH_MAX];
    const char *resolved = pt_resolve_virtual_path(tmpl, vbuf, sizeof(vbuf));
    if (resolved == vbuf) {
        int fd = mkstemps(vbuf, slen);
        if (fd >= 0) {
            pt_copy_template_xs(tmpl, vbuf, slen, x_count);
        }
        return fd;
    }
    return mkstemps(tmpl, slen);
}

static int pt_mkostemp(char *tmpl, int oflags) {
    if (tmpl == NULL) {
        return mkostemp(tmpl, oflags);
    }
    size_t x_count = pt_count_template_xs(tmpl, 0);
    char vbuf[PATH_MAX];
    const char *resolved = pt_resolve_virtual_path(tmpl, vbuf, sizeof(vbuf));
    if (resolved == vbuf) {
        int fd = mkostemp(vbuf, oflags);
        if (fd >= 0) {
            pt_copy_template_xs(tmpl, vbuf, 0, x_count);
        }
        return fd;
    }
    return mkostemp(tmpl, oflags);
}

static int pt_mkostemps(char *tmpl, int slen, int oflags) {
    if (tmpl == NULL) {
        return mkostemps(tmpl, slen, oflags);
    }
    size_t x_count = pt_count_template_xs(tmpl, slen);
    char vbuf[PATH_MAX];
    const char *resolved = pt_resolve_virtual_path(tmpl, vbuf, sizeof(vbuf));
    if (resolved == vbuf) {
        int fd = mkostemps(vbuf, slen, oflags);
        if (fd >= 0) {
            pt_copy_template_xs(tmpl, vbuf, slen, x_count);
        }
        return fd;
    }
    return mkostemps(tmpl, slen, oflags);
}

static char *pt_mkdtemp(char *tmpl) {
    if (tmpl == NULL) {
        errno = EINVAL;
        return NULL;
    }
    size_t x_count = pt_count_template_xs(tmpl, 0);
    char vbuf[PATH_MAX];
    const char *resolved = pt_resolve_virtual_path(tmpl, vbuf, sizeof(vbuf));
    if (resolved == vbuf) {
        char *res = mkdtemp(vbuf);
        if (res == NULL) {
            return NULL;
        }
        pt_copy_template_xs(tmpl, vbuf, 0, x_count);
        return tmpl;
    }
    return mkdtemp(tmpl);
}

extern char *pt_orig_mktemp(char *) __asm("_mktemp");
static char *pt_mktemp(char *tmpl) {
    if (tmpl == NULL) {
        errno = EINVAL;
        return NULL;
    }
    size_t x_count = pt_count_template_xs(tmpl, 0);
    char vbuf[PATH_MAX];
    const char *resolved = pt_resolve_virtual_path(tmpl, vbuf, sizeof(vbuf));
    if (resolved == vbuf) {
        char *res = pt_orig_mktemp(vbuf);
        if (res == NULL || vbuf[0] == '\0') {
            tmpl[0] = '\0';
            return tmpl;
        }
        pt_copy_template_xs(tmpl, vbuf, 0, x_count);
        return tmpl;
    }
    return pt_orig_mktemp(tmpl);
}

extern char *_amkrtemp(const char *path);
static char *pt_amkrtemp(const char *path) {
    char vbuf[PATH_MAX];
    path = pt_resolve_virtual_path(ue_fix_filename(path), vbuf, sizeof(vbuf));
    return _amkrtemp(path);
}


static const char *pt_resolve_sqlite_filename(const char *filename, char *buf, size_t bufsize, const char **out_check_path, char *check_buf, size_t check_bufsize) {
    if (out_check_path != NULL) {
        *out_check_path = NULL;
    }
    if (filename == NULL || buf == NULL || bufsize == 0) {
        return filename;
    }
    if (filename[0] == '/') {
        const char *fixed = ue_fix_filename(filename);
        const char *resolved = pt_resolve_virtual_path(fixed, buf, bufsize);
        if (out_check_path != NULL) {
            *out_check_path = pt_is_reverse_mapped_iossupport(fixed, resolved) ? fixed : resolved;
        }
        return resolved;
    }
    if (strncmp(filename, "file:", 5) == 0) {
        const char *path_start = NULL;
        if (strncmp(filename, "file://localhost/", 17) == 0) {
            path_start = filename + 16;
        } else if (strncmp(filename, "file:///", 8) == 0) {
            path_start = filename + 7;
        } else if (filename[5] == '/') {
            path_start = filename + 5;
        }
        if (path_start != NULL) {
            const char *tail = strpbrk(path_start, "?#");
            size_t path_len = (tail != NULL) ? (size_t)(tail - path_start) : strlen(path_start);
            if (path_len > 0 && path_len < PATH_MAX) {
                char path_only[PATH_MAX];
                memcpy(path_only, path_start, path_len);
                path_only[path_len] = '\0';
                const char *resolved = pt_resolve_virtual_path(path_only, check_buf, check_bufsize);
                if (out_check_path != NULL) {
                    if (pt_is_reverse_mapped_iossupport(path_only, resolved)) {
                        *out_check_path = NULL;
                    } else {
                        *out_check_path = (resolved == path_only) ? NULL : resolved;
                        if (*out_check_path == NULL && path_len < check_bufsize) {
                            memcpy(check_buf, path_only, path_len + 1);
                            *out_check_path = check_buf;
                        }
                    }
                }
                if (resolved != path_only) {
                    int n = snprintf(buf, bufsize, "file://%s%s", resolved, (tail != NULL) ? tail : "");
                    if (n >= 0 && (size_t)n < bufsize) {
                        return buf;
                    }
                }
            }
        }
    }
    return filename;
}

static int pt_sqlite3_open(const char *filename, sqlite3 **ppDb) {
    char vbuf[PATH_MAX + 128];
    char cbuf[PATH_MAX];
    const char *check_path = NULL;
    filename = pt_resolve_sqlite_filename(filename, vbuf, sizeof(vbuf), &check_path, cbuf, sizeof(cbuf));
    if (check_path != NULL &&
        (pt_is_hidden_path(check_path, __builtin_return_address(0)) ||
         pt_is_virtual_container_ancestor_dir(check_path))) {
        if (ppDb != NULL) {
            *ppDb = NULL;
        }
        return SQLITE_CANTOPEN;
    }
    return sqlite3_open(filename, ppDb);
}

static int pt_sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs) {
    char vbuf[PATH_MAX + 128];
    char cbuf[PATH_MAX];
    const char *check_path = NULL;
    filename = pt_resolve_sqlite_filename(filename, vbuf, sizeof(vbuf), &check_path, cbuf, sizeof(cbuf));
    if (check_path != NULL &&
        (pt_is_hidden_path(check_path, __builtin_return_address(0)) ||
         (pt_is_virtual_container_ancestor_dir(check_path) && (flags & (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)) != 0) ||
         pt_is_virtual_container_ancestor_dir(check_path))) {
        if (ppDb != NULL) {
            *ppDb = NULL;
        }
        return SQLITE_CANTOPEN;
    }
    return sqlite3_open_v2(filename, ppDb, flags, zVfs);
}


DYLD_INTERPOSE(pt_open, open)
DYLD_INTERPOSE(pt_open_nocancel, pt_orig_open_nocancel)
DYLD_INTERPOSE(pt_openat, openat)
DYLD_INTERPOSE(pt_openat_nocancel, pt_orig_openat_nocancel)
DYLD_INTERPOSE(pt_creat, creat)
DYLD_INTERPOSE(pt_creat_nocancel, pt_orig_creat_nocancel)
DYLD_INTERPOSE(pt_open_dprotected_np, open_dprotected_np)
DYLD_INTERPOSE(pt_openat_dprotected_np, openat_dprotected_np)
DYLD_INTERPOSE(pt_guarded_open_np, guarded_open_np)
DYLD_INTERPOSE(pt_guarded_open_dprotected_np, guarded_open_dprotected_np)
DYLD_INTERPOSE(pt_fopen, fopen)
DYLD_INTERPOSE(pt_fopen_darwin_extsn, pt_orig_fopen_darwin_extsn)
DYLD_INTERPOSE(pt_freopen, freopen)
DYLD_INTERPOSE(pt_stat, stat)
DYLD_INTERPOSE(pt_lstat, lstat)
DYLD_INTERPOSE(pt_fstatat, fstatat)
DYLD_INTERPOSE(pt_statx_np, statx_np)
DYLD_INTERPOSE(pt_lstatx_np, lstatx_np)
DYLD_INTERPOSE(pt_access, access)
DYLD_INTERPOSE(pt_faccessat, faccessat)
DYLD_INTERPOSE(pt_readlink, readlink)
DYLD_INTERPOSE(pt_readlinkat, readlinkat)
DYLD_INTERPOSE(pt_realpath, realpath)
DYLD_INTERPOSE(pt_realpath_legacy, pt_orig_realpath_legacy)
DYLD_INTERPOSE(pt_getcwd, getcwd)
DYLD_INTERPOSE(pt_chdir, chdir)
DYLD_INTERPOSE(pt_fchdir, fchdir)
DYLD_INTERPOSE(pt_fcntl, fcntl)
DYLD_INTERPOSE(pt_fcntl_nocancel, pt_orig_fcntl_nocancel)
DYLD_INTERPOSE(pt_proc_pidpath, proc_pidpath)
DYLD_INTERPOSE(pt_proc_pidfdinfo, proc_pidfdinfo)
DYLD_INTERPOSE(pt_proc_pidinfo, proc_pidinfo)
DYLD_INTERPOSE(pt_proc_listpids, proc_listpids)
DYLD_INTERPOSE(pt_proc_listallpids, proc_listallpids)
DYLD_INTERPOSE(pt_proc_name, proc_name)
DYLD_INTERPOSE(pt_proc_regionfilename, proc_regionfilename)
DYLD_INTERPOSE(pt_opendir, opendir)
DYLD_INTERPOSE(pt_opendir2, __opendir2)
DYLD_INTERPOSE(pt_fdopendir, fdopendir)
DYLD_INTERPOSE(pt_readdir, readdir)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
DYLD_INTERPOSE(pt_readdir_r, readdir_r)
#pragma clang diagnostic pop
DYLD_INTERPOSE(pt_scandir, scandir)
DYLD_INTERPOSE(pt_scandir_b, scandir_b)
DYLD_INTERPOSE(pt_mkdir, mkdir)
DYLD_INTERPOSE(pt_mkdirat, mkdirat)
DYLD_INTERPOSE(pt_mkpath_np, mkpath_np)
DYLD_INTERPOSE(pt_mkpathat_np, mkpathat_np)
DYLD_INTERPOSE(pt_rmdir, rmdir)
DYLD_INTERPOSE(pt_getattrlist, getattrlist)
DYLD_INTERPOSE(pt_fgetattrlist, fgetattrlist)
DYLD_INTERPOSE(pt_getattrlistat, getattrlistat)
DYLD_INTERPOSE(pt_getattrlistbulk, getattrlistbulk)
DYLD_INTERPOSE(pt_setattrlist, setattrlist)
DYLD_INTERPOSE(pt_fsetattrlist, fsetattrlist)
DYLD_INTERPOSE(pt_pathconf, pathconf)
DYLD_INTERPOSE(pt_fpathconf, fpathconf)
DYLD_INTERPOSE(pt_statfs, statfs)
DYLD_INTERPOSE(pt_fstatfs, fstatfs)
DYLD_INTERPOSE(pt_getfsstat, getfsstat)
DYLD_INTERPOSE(pt_getmntinfo, getmntinfo)
DYLD_INTERPOSE(pt_getmntinfo_r_np, getmntinfo_r_np)
DYLD_INTERPOSE(pt_statvfs, statvfs)
DYLD_INTERPOSE(pt_fstatvfs, fstatvfs)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
DYLD_INTERPOSE(pt_mktemp, mktemp)
#pragma clang diagnostic pop
DYLD_INTERPOSE(pt_rename, rename)
DYLD_INTERPOSE(pt_renameat, renameat)
DYLD_INTERPOSE(pt_renamex_np, renamex_np)
DYLD_INTERPOSE(pt_renameatx_np, renameatx_np)
DYLD_INTERPOSE(pt_unlink, unlink)
DYLD_INTERPOSE(pt_unlinkat, unlinkat)
DYLD_INTERPOSE(pt_remove, remove)
DYLD_INTERPOSE(pt_removefile, removefile)
DYLD_INTERPOSE(pt_link, link)
DYLD_INTERPOSE(pt_linkat, linkat)
DYLD_INTERPOSE(pt_symlink, symlink)
DYLD_INTERPOSE(pt_symlinkat, symlinkat)
DYLD_INTERPOSE(pt_chmod, chmod)
DYLD_INTERPOSE(pt_lchmod, lchmod)
DYLD_INTERPOSE(pt_fchmodat, fchmodat)
DYLD_INTERPOSE(pt_chown, chown)
DYLD_INTERPOSE(pt_lchown, lchown)
DYLD_INTERPOSE(pt_fchownat, fchownat)
DYLD_INTERPOSE(pt_chflags, chflags)
DYLD_INTERPOSE(pt_lchflags, lchflags)
DYLD_INTERPOSE(pt_truncate, truncate)
DYLD_INTERPOSE(pt_utimes, utimes)
DYLD_INTERPOSE(pt_lutimes, lutimes)
DYLD_INTERPOSE(pt_utimensat, utimensat)
DYLD_INTERPOSE(pt_utime, utime)
DYLD_INTERPOSE(pt_ftw, ftw)
DYLD_INTERPOSE(pt_nftw, nftw)
DYLD_INTERPOSE(pt_fts_open, fts_open)
#ifdef __BLOCKS__
DYLD_INTERPOSE(pt_fts_open_b, fts_open_b)
#endif
DYLD_INTERPOSE(pt_fts_read, fts_read)
DYLD_INTERPOSE(pt_fts_children, fts_children)
DYLD_INTERPOSE(pt_fts_set, fts_set)
DYLD_INTERPOSE(pt_fts_close, fts_close)
DYLD_INTERPOSE(pt_glob, glob)
DYLD_INTERPOSE(pt_glob_b, glob_b)
DYLD_INTERPOSE(pt_posix_spawn_file_actions_addopen, posix_spawn_file_actions_addopen)
DYLD_INTERPOSE(pt_getxattr, getxattr)
DYLD_INTERPOSE(pt_fgetxattr, fgetxattr)
DYLD_INTERPOSE(pt_setxattr, setxattr)
DYLD_INTERPOSE(pt_fsetxattr, fsetxattr)
DYLD_INTERPOSE(pt_listxattr, listxattr)
DYLD_INTERPOSE(pt_flistxattr, flistxattr)
DYLD_INTERPOSE(pt_removexattr, removexattr)
DYLD_INTERPOSE(pt_fremovexattr, fremovexattr)
DYLD_INTERPOSE(pt_copyfile, copyfile)
DYLD_INTERPOSE(pt_clonefile, clonefile)
DYLD_INTERPOSE(pt_clonefileat, clonefileat)
DYLD_INTERPOSE(pt_mkstemp, mkstemp)
DYLD_INTERPOSE(pt_mkstemps, mkstemps)
DYLD_INTERPOSE(pt_mkostemp, mkostemp)
DYLD_INTERPOSE(pt_mkostemps, mkostemps)
DYLD_INTERPOSE(pt_mkdtemp, mkdtemp)
DYLD_INTERPOSE(pt_amkrtemp, _amkrtemp)
static ssize_t pt_fs_fsgetpath_impl(char *buf, size_t bufsize, fsid_t *fsid, uint64_t objid, const void *caller) {
    ssize_t ret = fsgetpath(buf, bufsize, fsid, objid);
    if (ret <= 0 || buf == NULL || bufsize == 0 || pt_is_effective_system_or_playtools_caller(caller)) {
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
void *pt_fs_dlsym_route(const char *symbol) {
    if (symbol == NULL) {
        return NULL;
    }
    if (strcmp(symbol, "fsgetpath") == 0) {
        return (void *)&pt_fsgetpath;
    }
    if (strcmp(symbol, "proc_pidinfo") == 0) {
        return (void *)&pt_proc_pidinfo;
    }
    return NULL;
}

DYLD_INTERPOSE(pt_sqlite3_open, sqlite3_open)
DYLD_INTERPOSE(pt_sqlite3_open_v2, sqlite3_open_v2)
DYLD_INTERPOSE(pt_fsgetpath, fsgetpath)
