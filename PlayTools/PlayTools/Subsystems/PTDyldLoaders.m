//
//  PTDyldLoaders.m
//  PlayTools
//

#import "PTDyldInternal.h"
#import "PTSystemSpooferInternal.h"
#import "PTFSInternal.h"
#import "PTNetworkInternal.h"
#import "PTInterposeRegistry.h"

extern const void *pt_orig_objc_lookUpClass(const char *name) __asm__("_objc_lookUpClass");

static _Thread_local char s_tls_dlerror_buf[2048];
static _Thread_local bool s_tls_dlerror_pending = false;

static void pt_set_synthetic_dlerror(const char *msg) {
    if (msg == NULL) {
        msg = "image not found";
    }
    strlcpy(s_tls_dlerror_buf, msg, sizeof(s_tls_dlerror_buf));
    s_tls_dlerror_pending = true;
    (void)dlerror();
}

static BOOL pt_dlerror_contains_hidden_token(const char *s) {
    if (s == NULL) {
        return NO;
    }
    if (pt_is_registered_hidden_module(s)) {
        return YES;
    }
    static const char *const kTokens[] = {
        "PlayTools",
        "AKInterface",
        "UserPlugins",
        "PlayCover",
        "MacOver",
        "app.makedie",
        "AppKit",
        "UIKitMacHelper",
        "Preboot",
        "Cryptexes",
        "SkyLight",
        "ViewBridge",
        "HIToolbox",
        "Carbon",
        "Cocoa",
        "/Users/"
    };
    for (size_t i = 0; i < sizeof(kTokens) / sizeof(kTokens[0]); i++) {
        if (strcasestr(s, kTokens[i]) != NULL) {
            return YES;
        }
    }
    return NO;
}

static void pt_sanitize_dlerror_buf(const char *src, char *dst, size_t dst_cap) {
    if (dst == NULL || dst_cap == 0) {
        return;
    }
    if (src == NULL || src[0] == '\0') {
        dst[0] = '\0';
        return;
    }
    pt_ensure_bundle_path_map();
    pt_ensure_data_container_map();
    const char *host_root = pt_get_host_user_root_cstr();
    size_t host_root_len = (host_root != NULL) ? strlen(host_root) : 0;

    size_t out = 0;
    const char *p = src;
    while (*p != '\0' && out + 1 < dst_cap) {
        if (s_real_app_bundle_len > 0 &&
            strncmp(p, s_real_app_bundle_dir, s_real_app_bundle_len) == 0) {
            size_t n = strlcpy(dst + out, s_virtual_private_bundle_dir, dst_cap - out);
            out += (n < dst_cap - out) ? n : (dst_cap - out - 1);
            p += s_real_app_bundle_len;
            if (strncmp(p, "/Contents/MacOS/", 16) == 0) {
                if (out + 1 < dst_cap) { dst[out++] = '/'; }
                p += 16;
            } else if (strncmp(p, "/Contents/Resources/", 20) == 0) {
                if (out + 1 < dst_cap) { dst[out++] = '/'; }
                p += 20;
            } else if (strncmp(p, "/Contents/", 10) == 0) {
                if (out + 1 < dst_cap) { dst[out++] = '/'; }
                p += 10;
            } else if (strncmp(p, "/Contents", 9) == 0 && (p[9] == '\0' || p[9] == '\'' || p[9] == '"' || p[9] == ')' || p[9] == ' ' || p[9] == ',' || p[9] == ':')) {
                p += 9;
            }
            continue;
        }
        if (s_real_data_container_len > 0 &&
            strncmp(p, s_real_data_container_dir, s_real_data_container_len) == 0) {
            size_t n = strlcpy(dst + out, s_virtual_private_data_dir, dst_cap - out);
            out += (n < dst_cap - out) ? n : (dst_cap - out - 1);
            p += s_real_data_container_len;
            continue;
        }
        if (strncmp(p, "/System/Volumes/Preboot/Cryptexes/OS/", 37) == 0) {
            p += 36;
            continue;
        }
        if (strncmp(p, "/System/Cryptexes/OS/", 21) == 0) {
            p += 20;
            continue;
        }
        if (strncmp(p, "/System/Volumes/Data/", 21) == 0) {
            p += 20;
            continue;
        }
        if (strncmp(p, "/System/iOSSupport/", 19) == 0) {
            p += 18;
            continue;
        }
        if (strncmp(p, ".app/Contents/", 14) == 0) {
            size_t n = strlcpy(dst + out, ".app/", dst_cap - out);
            out += (n < dst_cap - out) ? n : (dst_cap - out - 1);
            p += 14;
            if (strncmp(p, "MacOS/", 6) == 0) {
                p += 6;
            } else if (strncmp(p, "Resources/", 10) == 0) {
                p += 10;
            }
            continue;
        }
        if (strncmp(p, ".framework/Versions/", 20) == 0) {
            const char *ver_start = p + 20;
            const char *slash = ver_start;
            while (*slash != '\0' && *slash != '/' && *slash != '\'' && *slash != '"' && *slash != '\n' && (size_t)(slash - ver_start) < 32) {
                slash++;
            }
            if (*slash == '/') {
                size_t n = strlcpy(dst + out, ".framework", dst_cap - out);
                out += (n < dst_cap - out) ? n : (dst_cap - out - 1);
                p = slash;
                continue;
            }
        }
        if (host_root_len > 0 && strncmp(p, host_root, host_root_len) == 0 &&
            (p[host_root_len] == '/' || p[host_root_len] == '\0' || p[host_root_len] == '\'' ||
             p[host_root_len] == '"' || p[host_root_len] == ')' || p[host_root_len] == ',' || p[host_root_len] == ' ')) {
            size_t n = strlcpy(dst + out, "/var/mobile", dst_cap - out);
            out += (n < dst_cap - out) ? n : (dst_cap - out - 1);
            p += host_root_len;
            continue;
        }
        if (strncmp(p, "/Users/", 7) == 0) {
            const char *uend = p + 7;
            while (*uend != '\0' && *uend != '/' && *uend != '\'' && *uend != '"' &&
                   *uend != ')' && *uend != ',' && *uend != ' ' && *uend != ':' && *uend != '\n') {
                uend++;
            }
            size_t n = strlcpy(dst + out, "/var/mobile", dst_cap - out);
            out += (n < dst_cap - out) ? n : (dst_cap - out - 1);
            p = uend;
            continue;
        }
        dst[out++] = *p++;
    }
    dst[out] = '\0';

    if (pt_dlerror_contains_hidden_token(dst)) {
        strlcpy(dst,
                (strncmp(src, "dlsym(", 6) == 0) ? "symbol not found" : "image not found",
                dst_cap);
    }
}

static char *pt_dlerror(void) {
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return dlerror();
    }
    const void *caller = __builtin_return_address(0);
    BOOL hide = (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller));
    if (hide && s_tls_dlerror_pending) {
        s_tls_dlerror_pending = false;
        (void)dlerror();
        return s_tls_dlerror_buf;
    }
    s_tls_dlerror_pending = false;
    char *err = dlerror();
    if (err == NULL || !hide) {
        return err;
    }
    pt_sanitize_dlerror_buf(err, s_tls_dlerror_buf, sizeof(s_tls_dlerror_buf));
    return s_tls_dlerror_buf;
}

static BOOL pt_has_blocked_jailbreak_dlopen_component(const char *path) {
    if (path == NULL || path[0] == '\0') {
        return NO;
    }
    static const struct {
        const char *name;
        size_t len;
    } s_dir_or_fw_components[] = {
        PT_STR_ENTRY("MobileSubstrate"),
        PT_STR_ENTRY("TweakInject"),
        PT_STR_ENTRY("CydiaSubstrate.framework"),
        PT_STR_ENTRY("ElleKit.framework"),
        PT_STR_ENTRY("libhooker.framework"),
        PT_STR_ENTRY("Substitute.framework"),
        PT_STR_ENTRY("FridaGadget.framework"),
        PT_STR_ENTRY("SubstrateBootstrap.framework")
    };
#define PT_DLOPEN_PREFIX_ENTRY(lit, req_delim) { (lit), sizeof(lit) - 1, (req_delim) }
    static const struct {
        const char *prefix;
        size_t len;
        BOOL require_delim;
    } s_basename_prefixes[] = {
        PT_DLOPEN_PREFIX_ENTRY("MobileSubstrate", YES),
        PT_DLOPEN_PREFIX_ENTRY("libMobileSubstrate", YES),
        PT_DLOPEN_PREFIX_ENTRY("CydiaSubstrate", YES),
        PT_DLOPEN_PREFIX_ENTRY("libCydiaSubstrate", YES),
        PT_DLOPEN_PREFIX_ENTRY("SubstrateInserter", YES),
        PT_DLOPEN_PREFIX_ENTRY("libSubstrateInserter", YES),
        PT_DLOPEN_PREFIX_ENTRY("SubstrateBootstrap", YES),
        PT_DLOPEN_PREFIX_ENTRY("libSubstrateBootstrap", YES),
        PT_DLOPEN_PREFIX_ENTRY("TweakInject", YES),
        PT_DLOPEN_PREFIX_ENTRY("libTweakInject", YES),
        PT_DLOPEN_PREFIX_ENTRY("ellekit", YES),
        PT_DLOPEN_PREFIX_ENTRY("libellekit", YES),
        PT_DLOPEN_PREFIX_ENTRY("libhooker", YES),
        PT_DLOPEN_PREFIX_ENTRY("libsubstitute", YES),
        PT_DLOPEN_PREFIX_ENTRY("fridagadget", YES),
        PT_DLOPEN_PREFIX_ENTRY("libfridagadget", YES),
        PT_DLOPEN_PREFIX_ENTRY("frida", YES),
        PT_DLOPEN_PREFIX_ENTRY("libfrida", YES),
        PT_DLOPEN_PREFIX_ENTRY("cycript", YES),
        PT_DLOPEN_PREFIX_ENTRY("libcycript", YES),
        PT_DLOPEN_PREFIX_ENTRY("SSLKillSwitch2", YES),
        PT_DLOPEN_PREFIX_ENTRY("libSSLKillSwitch2", YES),
        PT_DLOPEN_PREFIX_ENTRY("Choicy", YES),
        PT_DLOPEN_PREFIX_ENTRY("libChoicy", YES)
    };
#undef PT_DLOPEN_PREFIX_ENTRY

    const char *last_seg = NULL;
    size_t last_seg_len = 0;
    const char *p = path;
    while (*p != '\0') {
        while (*p == '/') {
            p++;
        }
        if (*p == '\0') {
            break;
        }
        const char *seg_start = p;
        while (*p != '\0' && *p != '/') {
            p++;
        }
        size_t seg_len = (size_t)(p - seg_start);
        last_seg = seg_start;
        last_seg_len = seg_len;
        for (size_t i = 0; i < sizeof(s_dir_or_fw_components) / sizeof(s_dir_or_fw_components[0]); ++i) {
            if (seg_len == s_dir_or_fw_components[i].len &&
                strncasecmp(seg_start, s_dir_or_fw_components[i].name, seg_len) == 0) {
                return YES;
            }
        }
    }

    if (last_seg != NULL && last_seg_len > 0) {
        for (size_t i = 0; i < sizeof(s_basename_prefixes) / sizeof(s_basename_prefixes[0]); ++i) {
            size_t plen = s_basename_prefixes[i].len;
            if (last_seg_len >= plen &&
                strncasecmp(last_seg, s_basename_prefixes[i].prefix, plen) == 0) {
                if (!s_basename_prefixes[i].require_delim || last_seg_len == plen) {
                    return YES;
                }
                char delim = last_seg[plen];
                if (delim == '.' || delim == '-' || delim == '_' ||
                    (delim >= '0' && delim <= '9')) {
                    return YES;
                }
            }
        }
    }
    return NO;
}

static BOOL pt_is_cf_internal_carboncore_caller(const void *caller) {
    if (caller == NULL) {
        return NO;
    }
    const void *scaller = pt_strip_return_addr((uintptr_t)caller);
    Dl_info cinfo;
    if (dladdr(scaller, &cinfo) == 0 || cinfo.dli_fname == NULL) {
        return NO;
    }
    if (pt_classify_caller_image_path(cinfo.dli_fname, NULL) != PT_CALLER_SYS_WRAPPER) {
        return NO;
    }
    return pt_is_cf_internal_carboncore_bridge_caller_cstr(cinfo.dli_fname, cinfo.dli_sname) ? YES : NO;
}

static BOOL pt_should_block_dlopen_path(const char *path, const void *caller) {
    if (path == NULL || !pt_is_bypass_enabled()) {
        return NO;
    }
    if (pt_is_effective_system_or_playtools_caller(caller)) {
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
    // Allow CoreFoundation's internal text-encoding lookup bridge while keeping app callers blocked.
    if (pt_is_carboncore_framework_path_cstr(norm) && pt_is_cf_internal_carboncore_caller(caller)) {
        return NO;
    }
    if (strstr(norm, ".framework/Versions/") != NULL ||
        strstr(norm, ".bundle/Versions/") != NULL ||
        strstr(norm, ".bundle/Contents/MacOS/") != NULL) {
        return YES;
    }
    return (pt_is_hidden_path(norm, caller) ||
            pt_is_hidden_dyld_image_name(norm) ||
            pt_is_post13_7_hidden_framework_path(norm) ||
            pt_has_blocked_jailbreak_dlopen_component(norm));
}

static BOOL pt_should_block_resolved_dlopen_path(const char *orig_path,
                                                  const char *resolved_path,
                                                  const void *caller) {
    return pt_is_reverse_mapped_iossupport(orig_path, resolved_path)
        ? pt_should_block_dlopen_path(orig_path, caller)
        : pt_should_block_dlopen_path(resolved_path, caller);
}

static void pt_set_blocked_dlopen_preflight_error(const char *path) {
    const char *base = (path != NULL) ? strrchr(path, '/') : NULL;
    const char *shown = (base != NULL && base[1] != '\0') ? (base + 1) : (path != NULL ? path : "<null>");
    if (pt_is_hidden_dyld_image_name(shown)) {
        shown = "image";
    }
    char msg[256];
    snprintf(msg, sizeof(msg), "dlopen_preflight(%s): image not found", shown);
    pt_set_synthetic_dlerror(msg);
}

static BOOL pt_copy_parent_dir(const char *file_path, char *out_dir, size_t out_size) {
    if (file_path == NULL || out_dir == NULL || out_size < 2) {
        return NO;
    }
    const char *slash = strrchr(file_path, '/');
    if (slash == NULL) {
        return NO;
    }
    size_t len = (size_t)(slash - file_path);
    if (len == 0) {
        out_dir[0] = '/';
        out_dir[1] = '\0';
        return YES;
    }
    if (len >= out_size) {
        return NO;
    }
    memcpy(out_dir, file_path, len);
    out_dir[len] = '\0';
    return YES;
}

static BOOL pt_expand_dyld_token_path(const char *raw,
                                      const char *loader_dir,
                                      const char *exec_dir,
                                      char *out,
                                      size_t out_size) {
    if (raw == NULL || out == NULL || out_size == 0) {
        return NO;
    }
    const char *base_dir = NULL;
    const char *suffix = NULL;
    if (strncmp(raw, "@loader_path/", 13) == 0 || strcmp(raw, "@loader_path") == 0) {
        base_dir = (loader_dir != NULL) ? loader_dir : exec_dir;
        suffix = raw + 12;
    } else if (strncmp(raw, "@executable_path/", 17) == 0 || strcmp(raw, "@executable_path") == 0) {
        base_dir = exec_dir;
        suffix = raw + 16;
    } else {
        size_t n = strlcpy(out, raw, out_size);
        return (n < out_size);
    }
    if (base_dir == NULL) {
        return NO;
    }
    if (strcmp(base_dir, "/") == 0 && suffix[0] == '/') {
        size_t n = strlcpy(out, suffix, out_size);
        return (n < out_size);
    }
    int n = snprintf(out, out_size, "%s%s", base_dir, suffix);
    return (n > 0 && (size_t)n < out_size);
}

static int pt_dlopen_preflight_try_candidate(const char *raw_cand, const void *caller) {
    if (raw_cand == NULL || raw_cand[0] == '\0') {
        return 0;
    }
    char lex_buf[PATH_MAX];
    const char *norm = raw_cand;
    if (norm[0] == '/' && pt_needs_lexical_norm(norm)) {
        const char *collapsed = pt_normalize_lexical_path(norm, lex_buf, sizeof(lex_buf));
        if (collapsed != NULL) {
            norm = collapsed;
        }
    }
    char vbuf[PATH_MAX];
    const char *cand = pt_resolve_virtual_bundle_path(norm, vbuf, sizeof(vbuf));
    if (pt_should_block_resolved_dlopen_path(norm, cand, caller)) {
        pt_set_blocked_dlopen_preflight_error(cand);
        return -1;
    }
    if (cand[0] == '/' && access(cand, F_OK) == 0) {
        if (dlopen_preflight(cand)) {
            (void)dlerror();
            return 1;
        }
    }
    return 0;
}

static int pt_dlopen_preflight_search_rpaths(const struct mach_header *mh,
                                             const char *rpath_rel,
                                             const char *loader_dir,
                                             const char *exec_dir,
                                             const void *caller) {
    if (mh == NULL || !pt_is_valid_user_pointer((const void *)mh) ||
        rpath_rel == NULL || mh->magic != MH_MAGIC_64) {
        return 0;
    }
    const struct mach_header_64 *mh64 = (const struct mach_header_64 *)mh;
    const uint8_t *cmd_ptr = (const uint8_t *)(mh64 + 1);
    const uint8_t *cmd_end = cmd_ptr + mh64->sizeofcmds;
    for (uint32_t i = 0; i < mh64->ncmds && cmd_ptr + sizeof(struct load_command) <= cmd_end; i++) {
        const struct load_command *lc = (const struct load_command *)cmd_ptr;
        if (lc->cmdsize < sizeof(struct load_command) || cmd_ptr + lc->cmdsize > cmd_end) {
            break;
        }
        if (lc->cmd == LC_RPATH && lc->cmdsize >= sizeof(struct rpath_command)) {
            const struct rpath_command *rc = (const struct rpath_command *)lc;
            uint32_t off = rc->path.offset;
            if (off >= sizeof(struct rpath_command) && off < lc->cmdsize) {
                const char *rpath_raw = (const char *)lc + off;
                size_t max_len = (size_t)(lc->cmdsize - off);
                size_t rlen = strnlen(rpath_raw, max_len);
                if (rlen > 0 && rlen < max_len) {
                    char expanded_rpath[PATH_MAX];
                    if (pt_expand_dyld_token_path(rpath_raw, loader_dir, exec_dir,
                                                  expanded_rpath, sizeof(expanded_rpath))) {
                        size_t erlen = strlen(expanded_rpath);
                        char full_cand[PATH_MAX];
                        int n = (erlen > 0 && expanded_rpath[erlen - 1] == '/')
                            ? snprintf(full_cand, sizeof(full_cand), "%s%s", expanded_rpath, rpath_rel)
                            : snprintf(full_cand, sizeof(full_cand), "%s/%s", expanded_rpath, rpath_rel);
                        if (n > 0 && (size_t)n < sizeof(full_cand)) {
                            int res = pt_dlopen_preflight_try_candidate(full_cand, caller);
                            if (res != 0) {
                                return res;
                            }
                        }
                    }
                }
            }
        }
        cmd_ptr += lc->cmdsize;
    }
    return 0;
}

#define PT_EXPLICIT_FW_HANDLE_INIT_CAP 128U
#define PT_EXPLICIT_FW_HANDLE_MAX_CAP 4096U

typedef struct {
    void *handle;
    char path[PATH_MAX];
} pt_explicit_fw_handle_entry_t;

static os_unfair_lock s_explicit_fw_handle_lock = OS_UNFAIR_LOCK_INIT;
static pt_explicit_fw_handle_entry_t *s_explicit_fw_handles = NULL;
static uint32_t s_explicit_fw_handle_cap = 0;
static uint32_t s_explicit_fw_handle_next = 0;

static void pt_evict_explicit_framework_handle(void *handle) {
    if (handle == NULL) {
        return;
    }
    os_unfair_lock_lock(&s_explicit_fw_handle_lock);
    if (s_explicit_fw_handles != NULL) {
        for (uint32_t i = 0; i < s_explicit_fw_handle_cap; i++) {
            if (s_explicit_fw_handles[i].handle == handle) {
                s_explicit_fw_handles[i].handle = NULL;
                s_explicit_fw_handles[i].path[0] = '\0';
            }
        }
    }
    os_unfair_lock_unlock(&s_explicit_fw_handle_lock);
}

static void pt_record_explicit_framework_handle(void *handle,
                                                const char *orig_path,
                                                const char *resolved_path,
                                                const void *caller) {
    if (handle == NULL || !pt_is_bypass_enabled() || pt_is_effective_system_or_playtools_caller(caller)) {
        return;
    }
    BOOL is_framework = (orig_path != NULL &&
                         resolved_path != NULL &&
                         strstr(resolved_path, ".framework/") != NULL &&
                         strstr(resolved_path, "/System.framework/") == NULL);
    os_unfair_lock_lock(&s_explicit_fw_handle_lock);
    if (!is_framework) {
        if (s_explicit_fw_handles != NULL) {
            for (uint32_t i = 0; i < s_explicit_fw_handle_cap; i++) {
                if (s_explicit_fw_handles[i].handle == handle) {
                    s_explicit_fw_handles[i].handle = NULL;
                    s_explicit_fw_handles[i].path[0] = '\0';
                }
            }
        }
        os_unfair_lock_unlock(&s_explicit_fw_handle_lock);
        return;
    }
    if (s_explicit_fw_handles == NULL) {
        s_explicit_fw_handles = (pt_explicit_fw_handle_entry_t *)calloc(
            PT_EXPLICIT_FW_HANDLE_INIT_CAP, sizeof(pt_explicit_fw_handle_entry_t));
        if (s_explicit_fw_handles == NULL) {
            os_unfair_lock_unlock(&s_explicit_fw_handle_lock);
            return;
        }
        s_explicit_fw_handle_cap = PT_EXPLICIT_FW_HANDLE_INIT_CAP;
    }
    if (s_explicit_fw_handle_cap == 0U) {
        os_unfair_lock_unlock(&s_explicit_fw_handle_lock);
        return;
    }
    uint32_t free_slot = s_explicit_fw_handle_cap;
    for (uint32_t i = 0; i < s_explicit_fw_handle_cap; i++) {
        if (s_explicit_fw_handles[i].handle == handle) {
            strlcpy(s_explicit_fw_handles[i].path, resolved_path, sizeof(s_explicit_fw_handles[i].path));
            os_unfair_lock_unlock(&s_explicit_fw_handle_lock);
            return;
        }
        if (s_explicit_fw_handles[i].handle == NULL && free_slot == s_explicit_fw_handle_cap) {
            free_slot = i;
        }
    }
    if (free_slot == s_explicit_fw_handle_cap && s_explicit_fw_handle_cap < PT_EXPLICIT_FW_HANDLE_MAX_CAP) {
        uint32_t new_cap = s_explicit_fw_handle_cap * 2U;
        if (new_cap > PT_EXPLICIT_FW_HANDLE_MAX_CAP) {
            new_cap = PT_EXPLICIT_FW_HANDLE_MAX_CAP;
        }
        if (new_cap > s_explicit_fw_handle_cap) {
            pt_explicit_fw_handle_entry_t *grown = (pt_explicit_fw_handle_entry_t *)realloc(
                s_explicit_fw_handles, (size_t)new_cap * sizeof(pt_explicit_fw_handle_entry_t));
            if (grown != NULL) {
                memset(grown + s_explicit_fw_handle_cap,
                       0,
                       (size_t)(new_cap - s_explicit_fw_handle_cap) * sizeof(pt_explicit_fw_handle_entry_t));
                s_explicit_fw_handles = grown;
                free_slot = s_explicit_fw_handle_cap;
                s_explicit_fw_handle_cap = new_cap;
            }
        }
    }
    uint32_t cap = s_explicit_fw_handle_cap;
    if (cap == 0U) {
        os_unfair_lock_unlock(&s_explicit_fw_handle_lock);
        return;
    }
    uint32_t slot = free_slot;
    if (slot >= cap) {
        slot = s_explicit_fw_handle_next % cap;
        s_explicit_fw_handle_next = (slot + 1U) % cap;
    }
    s_explicit_fw_handles[slot].handle = handle;
    strlcpy(s_explicit_fw_handles[slot].path, resolved_path, sizeof(s_explicit_fw_handles[slot].path));
    os_unfair_lock_unlock(&s_explicit_fw_handle_lock);
}

static BOOL pt_lookup_explicit_framework_handle_path(void *handle, char *out_buf, size_t out_cap) {
    if (handle == NULL || out_buf == NULL || out_cap == 0) {
        return NO;
    }
    BOOL found = NO;
    os_unfair_lock_lock(&s_explicit_fw_handle_lock);
    if (s_explicit_fw_handles != NULL) {
        for (uint32_t i = 0; i < s_explicit_fw_handle_cap; i++) {
            if (s_explicit_fw_handles[i].handle == handle && s_explicit_fw_handles[i].path[0] != '\0') {
                strlcpy(out_buf, s_explicit_fw_handles[i].path, out_cap);
                found = YES;
                break;
            }
        }
    }
    os_unfair_lock_unlock(&s_explicit_fw_handle_lock);
    return found;
}

static int pt_dlclose(void *handle) {
    int rc = dlclose(handle);
    if (rc == 0 && handle != NULL) {
        pt_evict_explicit_framework_handle(handle);
    }
    return rc;
}

extern void *dlopen_from(const char *path, int mode, void *addressInCaller);

static void *pt_dlopen_from(const char *path, int mode, void *addressInCaller) {
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return dlopen_from(path, mode, addressInCaller);
    }
    s_tls_dlerror_pending = false;
    const void *caller = __builtin_return_address(0);
    const char *orig_path = path;
    char resolved_buf[PATH_MAX];
    if (path != NULL) {
        path = pt_resolve_virtual_bundle_path(path, resolved_buf, sizeof(resolved_buf));
    }
    if (pt_should_block_resolved_dlopen_path(orig_path, path, caller)) {
        PT_DEBUG_TRACE("dyld", "blocked dlopen_from path=%s", path != NULL ? path : "<null>");
        const char *base = (path != NULL) ? strrchr(path, '/') : NULL;
        const char *shown = (base != NULL && base[1] != '\0') ? (base + 1) : (path != NULL ? path : "<null>");
        if (pt_is_hidden_dyld_image_name(shown)) {
            shown = "image";
        }
        char msg[256];
        snprintf(msg, sizeof(msg), "dlopen(%s, 0x%04x): image not found", shown, mode);
        pt_set_synthetic_dlerror(msg);
        return NULL;
    }
    void *handle = dlopen_from(path, mode, addressInCaller != NULL ? addressInCaller : (void *)caller);
    if (handle != NULL) {
        pt_record_explicit_framework_handle(handle, orig_path, path, caller);
        if (orig_path != NULL) {
            ps_notify_dynamic_image_loaded();
        }
    }
    return handle;
}

static void *pt_dlopen(const char *path, int mode) {
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return dlopen(path, mode);
    }
    s_tls_dlerror_pending = false;
    const void *caller = __builtin_return_address(0);
    const char *orig_path = path;
    char resolved_buf[PATH_MAX];
    if (path != NULL) {
        path = pt_resolve_virtual_bundle_path(path, resolved_buf, sizeof(resolved_buf));
    }
    if (pt_should_block_resolved_dlopen_path(orig_path, path, caller)) {
        PT_DEBUG_TRACE("dyld", "blocked dlopen path=%s", path != NULL ? path : "<null>");
        const char *base = (path != NULL) ? strrchr(path, '/') : NULL;
        const char *shown = (base != NULL && base[1] != '\0') ? (base + 1) : (path != NULL ? path : "<null>");
        if (pt_is_hidden_dyld_image_name(shown)) {
            shown = "image";
        }
        char msg[256];
        snprintf(msg, sizeof(msg), "dlopen(%s, 0x%04x): image not found", shown, mode);
        pt_set_synthetic_dlerror(msg);
        return NULL;
    }
    void *handle = (caller != NULL) ? dlopen_from(path, mode, (void *)caller) : dlopen(path, mode);
    if (handle != NULL) {
        pt_record_explicit_framework_handle(handle, orig_path, path, caller);
        if (orig_path != NULL) {
            ps_notify_dynamic_image_loaded();
        }
    }
    return handle;
}

extern void *dlopen_audited(const char *path, int mode) __attribute__((weak_import));

static void *pt_dlopen_audited(const char *path, int mode) {
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        if (&dlopen_audited != NULL) {
            return dlopen_audited(path, mode);
        }
        return dlopen(path, mode);
    }
    s_tls_dlerror_pending = false;
    const void *caller = __builtin_return_address(0);
    const char *orig_path = path;
    char resolved_buf[PATH_MAX];
    if (path != NULL) {
        path = pt_resolve_virtual_bundle_path(path, resolved_buf, sizeof(resolved_buf));
    }
    if (pt_should_block_resolved_dlopen_path(orig_path, path, caller)) {
        PT_DEBUG_TRACE("dyld", "blocked dlopen_audited path=%s", path != NULL ? path : "<null>");
        const char *base = (path != NULL) ? strrchr(path, '/') : NULL;
        const char *shown = (base != NULL && base[1] != '\0') ? (base + 1) : (path != NULL ? path : "<null>");
        if (pt_is_hidden_dyld_image_name(shown)) {
            shown = "image";
        }
        char msg[256];
        snprintf(msg, sizeof(msg), "dlopen_audited(%s, 0x%04x): image not found", shown, mode);
        pt_set_synthetic_dlerror(msg);
        return NULL;
    }
    void *handle = NULL;
    if (path != NULL &&
        (path[0] == '@' || path[0] != '/') &&
        caller != NULL) {
        handle = dlopen_from(path, mode, (void *)caller);
    } else if (&dlopen_audited != NULL) {
        handle = dlopen_audited(path, mode);
    } else if (caller != NULL) {
        handle = dlopen_from(path, mode, (void *)caller);
    } else {
        handle = dlopen(path, mode);
    }
    if (handle != NULL) {
        pt_record_explicit_framework_handle(handle, orig_path, path, caller);
        if (orig_path != NULL) {
            ps_notify_dynamic_image_loaded();
        }
    }
    return handle;
}

__attribute__((noinline))
static int pt_dlopen_preflight_handle_token_path(const char *path, const void *caller) {
    if (pt_should_block_dlopen_path(path, caller)) {
        pt_set_blocked_dlopen_preflight_error(path);
        return -1;
    }
    const void *scaller = pt_strip_return_addr((uintptr_t)caller);
    const char *caller_img = dyld_image_path_containing_address(scaller);
    const struct mach_header *caller_hdr = dyld_image_header_containing_address(scaller);
    const char *main_exec = pt_get_main_executable_path();
    const struct mach_header *main_hdr = pt_get_main_executable_header();
    char caller_dir_buf[PATH_MAX];
    char exec_dir_buf[PATH_MAX];
    const char *caller_dir = pt_copy_parent_dir(caller_img, caller_dir_buf, sizeof(caller_dir_buf)) ? caller_dir_buf : NULL;
    const char *exec_dir = pt_copy_parent_dir(main_exec, exec_dir_buf, sizeof(exec_dir_buf)) ? exec_dir_buf : NULL;

    if (strncmp(path, "@rpath/", 7) == 0) {
        const char *rel = path + 7;
        BOOL sanitize_rpath_lc = (pt_is_bypass_enabled() &&
                                  !pt_is_effective_system_or_playtools_caller(caller));
        const struct mach_header *caller_lc_hdr =
            (sanitize_rpath_lc && caller_hdr != NULL) ? pt_maybe_shadow_mach_header(caller_hdr) : caller_hdr;
        int res = pt_dlopen_preflight_search_rpaths(caller_lc_hdr, rel, caller_dir, exec_dir, caller);
        if (res != 0) {
            return res;
        }
        if (main_hdr != NULL && main_hdr != caller_hdr) {
            const struct mach_header *main_lc_hdr =
                sanitize_rpath_lc ? pt_maybe_shadow_mach_header(main_hdr) : main_hdr;
            res = pt_dlopen_preflight_search_rpaths(main_lc_hdr, rel, exec_dir, exec_dir, caller);
            if (res != 0) {
                return res;
            }
        }
    } else {
        char expanded[PATH_MAX];
        if (pt_expand_dyld_token_path(path, caller_dir, exec_dir, expanded, sizeof(expanded))) {
            int res = pt_dlopen_preflight_try_candidate(expanded, caller);
            if (res != 0) {
                return res;
            }
        }
    }
    return 0;
}

static bool pt_dlopen_preflight(const char *path) {
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return dlopen_preflight(path);
    }
    s_tls_dlerror_pending = false;
    const void *caller = __builtin_return_address(0);
    if (path != NULL &&
        (strncmp(path, "@rpath/", 7) == 0 ||
         strncmp(path, "@loader_path/", 13) == 0 ||
         strncmp(path, "@executable_path/", 17) == 0)) {
        int token_res = pt_dlopen_preflight_handle_token_path(path, caller);
        if (token_res > 0) {
            return true;
        }
        if (token_res < 0) {
            return false;
        }
        return dlopen_preflight(path);
    }
    const char *orig_path = path;
    char resolved_buf[PATH_MAX];
    if (path != NULL) {
        path = pt_resolve_virtual_bundle_path(path, resolved_buf, sizeof(resolved_buf));
    }
    if (pt_should_block_resolved_dlopen_path(orig_path, path, caller)) {
        pt_set_blocked_dlopen_preflight_error(path);
        return false;
    }
    return dlopen_preflight(path);
}

extern const void *swift_getTypeByMangledNameInContext(const char *typeNameStart,
                                                       size_t typeNameLength,
                                                       const void *context,
                                                       const void * const *genericArgs)
    __attribute__((swiftcall)) __attribute__((weak_import));

extern const void *swift_getTypeByMangledNameInContext2(const char *typeNameStart,
                                                        size_t typeNameLength,
                                                        const void *context,
                                                        const void * const *genericArgs)
    __attribute__((swiftcall)) __attribute__((weak_import));

extern const void *swift_getTypeByMangledNameInContextInMetadataState(size_t metadataState,
                                                                      const char *typeNameStart,
                                                                      size_t typeNameLength,
                                                                      const void *context,
                                                                      const void * const *genericArgs)
    __attribute__((swiftcall)) __attribute__((weak_import));

extern const void *swift_getTypeByMangledNameInContextInMetadataState2(size_t metadataState,
                                                                       const char *typeNameStart,
                                                                       size_t typeNameLength,
                                                                       const void *context,
                                                                       const void * const *genericArgs)
    __attribute__((swiftcall)) __attribute__((weak_import));

extern const void *swift_getTypeByMangledNameInEnvironment(const char *typeNameStart,
                                                           size_t typeNameLength,
                                                           const void *environment,
                                                           const void * const *genericArgs)
    __attribute__((swiftcall)) __attribute__((weak_import));

extern const void *swift_getTypeByMangledNameInEnvironmentInMetadataState(size_t metadataState,
                                                                          const char *typeNameStart,
                                                                          size_t typeNameLength,
                                                                          const void *environment,
                                                                          const void * const *genericArgs)
    __attribute__((swiftcall)) __attribute__((weak_import));

extern const void *pt_orig_swift_typeByName(uint64_t w0, uint64_t w1)
    __asm("_$ss11_typeByNameyypXpSgSSF") __attribute__((swiftcall)) __attribute__((weak_import));

extern CFTypeRef pt_orig_swift_string_bridge(uint64_t w0, uint64_t w1)
    __asm("_$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF")
    __attribute__((swiftcall)) __attribute__((weak_import)) CF_RETURNS_RETAINED;

typedef struct {
    const char *data;
    size_t length;
} pt_swift_type_name_pair_t;

extern pt_swift_type_name_pair_t swift_getTypeName(const void *type, bool qualified)
    __attribute__((weak_import));

extern const void *swift_getTypeByMangledName(size_t metadataState,
                                              const char *typeNameStart,
                                              size_t typeNameLength,
                                              const void * const *origGenericArgs,
                                              void *substGenericParam,
                                              void *substWitnessTable)
    __attribute__((swiftcall)) __attribute__((weak_import));

extern const void *swift_conformsToProtocol(const void *type, const void *protocol)
    __attribute__((weak_import));
extern const void *swift_conformsToProtocol2(const void *type, const void *protocol)
    __attribute__((weak_import));
extern const void *swift_conformsToProtocolCommon(const void *type, const void *protocol)
    __attribute__((weak_import));
extern const void *swift_conformsToProtocolWithExecutionContext(const void *type,
                                                              const void *protocol,
                                                              const void *ctx)
    __attribute__((weak_import));

static BOOL pt_is_hidden_swift_mangled_type_name(const char *typeNameStart, size_t typeNameLength) {
    if (typeNameStart == NULL || typeNameLength == 0 || !pt_is_valid_user_pointer(typeNameStart)) {
        return NO;
    }
    size_t scan_len = (typeNameLength > 4096U) ? 4096U : typeNameLength;
    if (pt_is_hidden_swift_mangled_type_name_cstr(typeNameStart, scan_len, pt_is_compat13_7_active())) {
        return YES;
    }
    if (pt_registered_hidden_module_count() > 0) {
        char tmp[1024];
        size_t copy_len = (scan_len >= sizeof(tmp)) ? (sizeof(tmp) - 1U) : scan_len;
        for (size_t i = 0; i < copy_len; i++) {
            char ch = typeNameStart[i];
            tmp[i] = (ch == '\0') ? ' ' : ch;
        }
        tmp[copy_len] = '\0';
        if (pt_is_registered_hidden_module(tmp)) {
            return YES;
        }
    }
    return NO;
}

static size_t pt_strip_metatype_suffix_len(const char *buf, size_t len) {
    if (len > 5U && memcmp(buf + len - 5U, ".Type", 5U) == 0) {
        return len - 5U;
    }
    if (len > 9U && memcmp(buf + len - 9U, ".Protocol", 9U) == 0) {
        return len - 9U;
    }
    return len;
}

static BOOL pt_swift_qualified_token_is_hidden(const char *tok, size_t len) {
    if (tok == NULL || len == 0 || len >= 512U) {
        return NO;
    }
    char buf[512];
    memcpy(buf, tok, len);
    buf[len] = '\0';

    size_t base_len = pt_strip_metatype_suffix_len(buf, len);
    char base_buf[512];
    memcpy(base_buf, buf, base_len);
    base_buf[base_len] = '\0';

    if (strncmp(base_buf, "__C.", 4) == 0) {
        return pt_is_hidden_objc_class(base_buf + 4);
    }
    if (pt_is_hidden_swift_qualified_token_cstr(buf, len, pt_is_compat13_7_active())) {
        return YES;
    }
    if (pt_registered_hidden_module_count() > 0) {
        const char *first_dot = (const char *)memchr(base_buf, '.', base_len);
        if (first_dot != NULL) {
            size_t mod_len = (size_t)(first_dot - base_buf);
            if (mod_len > 0 && mod_len < sizeof(buf)) {
                char mod_buf[512];
                memcpy(mod_buf, base_buf, mod_len);
                mod_buf[mod_len] = '\0';
                if (pt_is_registered_hidden_module(mod_buf)) {
                    return YES;
                }
            }
        } else if (pt_is_registered_hidden_module(base_buf)) {
            return YES;
        }
    }
    if (memchr(base_buf, '.', base_len) == NULL && pt_is_hidden_objc_class(base_buf)) {
        return YES;
    }
    return NO;
}

static BOOL pt_should_hide_swift_metadata_ptr_depth(const void *meta, int depth) {
    if (depth > 4 || meta == NULL || (((uintptr_t)meta & 0x7U) != 0) || !pt_is_valid_user_pointer(meta)) {
        return NO;
    }
    const char *img = dyld_image_path_containing_address(meta);
    const struct mach_header *mh = dyld_image_header_containing_address(meta);
    if ((mh != NULL && pt_is_hidden_dyld_image_header(mh)) ||
        (img != NULL && pt_should_hide_dyld_image(img))) {
        return YES;
    }
    uintptr_t kind = 0;
    memcpy(&kind, meta, sizeof(kind));
    if (kind == 0x305U) {
        // MetadataKind::ObjCClassWrapper stores bridged Class at offset 1 word.
        const void *wrapped = NULL;
        memcpy(&wrapped, (const uint8_t *)meta + sizeof(uintptr_t), sizeof(wrapped));
        if (wrapped != NULL && pt_is_valid_user_pointer(wrapped)) {
            Class wcls = (__bridge Class)wrapped;
            if (pt_should_hide_resolved_objc_class(class_getName(wcls), wcls)) {
                return YES;
            }
        }
    } else if (kind == 0x301U || kind == 0x302U) {
        // MetadataKind::Metatype (0x301) / ExistentialMetatype (0x302) store InstanceType at offset 1 word.
        const void *instance_meta = NULL;
        memcpy(&instance_meta, (const uint8_t *)meta + sizeof(uintptr_t), sizeof(instance_meta));
        if (instance_meta != NULL && (((uintptr_t)instance_meta & 0x7U) == 0) &&
            pt_is_valid_user_pointer(instance_meta)) {
            return pt_should_hide_swift_metadata_ptr_depth(instance_meta, depth + 1);
        }
    }
    if (img != NULL && !pt_is_system_or_playtools_caller(meta)) {
        return NO;
    }
    static _Thread_local bool s_tls_in_swift_type_name = false;
    if (!s_tls_in_swift_type_name && &swift_getTypeName != NULL) {
        s_tls_in_swift_type_name = true;
        pt_enter_internal_scope();
        pt_swift_type_name_pair_t tname = swift_getTypeName(meta, true);
        pt_leave_internal_scope();
        s_tls_in_swift_type_name = false;
        if (tname.data != NULL && tname.length > 0 && tname.length < 4096U &&
            pt_is_valid_user_pointer(tname.data)) {
            char full_buf[1024];
            size_t flen = (tname.length >= sizeof(full_buf)) ? (sizeof(full_buf) - 1U) : tname.length;
            memcpy(full_buf, tname.data, flen);
            full_buf[flen] = '\0';
            const char *p = full_buf;
            while (*p != '\0') {
                while (*p != '\0' && (*p == '<' || *p == '>' || *p == ',' || *p == '(' || *p == ')' ||
                                      *p == '[' || *p == ']' || *p == ':' || *p == '?' || *p == '!' ||
                                      *p == '&' || *p == ' ')) {
                    p++;
                }
                if (*p == '\0') {
                    break;
                }
                const char *start = p;
                while (*p != '\0' && *p != '<' && *p != '>' && *p != ',' && *p != '(' && *p != ')' &&
                       *p != '[' && *p != ']' && *p != ':' && *p != '?' && *p != '!' && *p != '&' &&
                       *p != ' ') {
                    p++;
                }
                if (pt_swift_qualified_token_is_hidden(start, (size_t)(p - start))) {
                    return YES;
                }
            }
        }
    }
    return NO;
}

static BOOL pt_should_hide_swift_metadata_ptr(const void *meta) {
    return pt_should_hide_swift_metadata_ptr_depth(meta, 0);
}

static BOOL pt_is_swift_type_lookup_app_caller(const void *ret_addr) {
    if (pt_is_in_internal_scope() || pt_is_address_in_playtools(ret_addr)) {
        return NO;
    }
    if (!pt_is_effective_system_or_playtools_caller(ret_addr)) {
        return YES;
    }
    const char *img0 = dyld_image_path_containing_address(pt_strip_code_ptr(ret_addr));
    if (img0 == NULL || (strstr(img0, "libswift") == NULL && strncmp(img0, "/usr/lib/", 9) != 0)) {
        return NO;
    }
#if defined(__arm64__) || defined(__aarch64__)
    pthread_t self = pthread_self();
    uintptr_t stack_top = (self != NULL) ? (uintptr_t)pthread_get_stackaddr_np(self) : 0;
    size_t stack_sz = (self != NULL) ? pthread_get_stacksize_np(self) : 0;
    uintptr_t stack_bot = (stack_top > stack_sz && stack_sz > 0) ? (stack_top - stack_sz) : 0;
    uintptr_t fp = (uintptr_t)__builtin_frame_address(0);
    for (int depth = 0; depth < PT_MAX_CALLER_UNWIND_DEPTH; depth++) {
        if (stack_top < 16 || fp < stack_bot || fp + 16 > stack_top || (fp & 0x7) != 0) {
            break;
        }
        uintptr_t next_fp = ((const uintptr_t *)fp)[0];
        const void *lr = pt_strip_return_addr(((const uintptr_t *)fp)[1]);
        if (lr != NULL) {
            if (pt_is_address_in_playtools(lr)) {
                return NO;
            }
            if (!pt_is_system_or_playtools_caller(lr)) {
                return YES;
            }
        }
        if (next_fp <= fp) {
            break;
        }
        fp = next_fp;
    }
#endif
    return NO;
}

static BOOL pt_should_hide_swift_type_lookup(const char *typeNameStart,
                                              size_t typeNameLength,
                                              const void *caller) {
    return (pt_is_bypass_enabled() &&
            pt_is_hidden_swift_mangled_type_name(typeNameStart, typeNameLength) &&
            pt_is_swift_type_lookup_app_caller(caller));
}

static const void *pt_swift_getTypeByMangledNameInContext(const char *typeNameStart,
                                                         size_t typeNameLength,
                                                         const void *context,
                                                         const void * const *genericArgs)
    __attribute__((swiftcall)) {
    const void *caller = __builtin_return_address(0);
    if (pt_should_hide_swift_type_lookup(typeNameStart, typeNameLength, caller) ||
        &swift_getTypeByMangledNameInContext == NULL) {
        return NULL;
    }
    const void *meta = swift_getTypeByMangledNameInContext(typeNameStart, typeNameLength, context, genericArgs);
    if (meta != NULL && pt_is_bypass_enabled() &&
        pt_is_swift_type_lookup_app_caller(caller) &&
        pt_should_hide_swift_metadata_ptr(meta)) {
        return NULL;
    }
    return meta;
}

static const void *pt_swift_getTypeByMangledNameInContext2(const char *typeNameStart,
                                                          size_t typeNameLength,
                                                          const void *context,
                                                          const void * const *genericArgs)
    __attribute__((swiftcall)) {
    const void *caller = __builtin_return_address(0);
    if (pt_should_hide_swift_type_lookup(typeNameStart, typeNameLength, caller) ||
        &swift_getTypeByMangledNameInContext2 == NULL) {
        return NULL;
    }
    const void *meta = swift_getTypeByMangledNameInContext2(typeNameStart, typeNameLength, context, genericArgs);
    if (meta != NULL && pt_is_bypass_enabled() &&
        pt_is_swift_type_lookup_app_caller(caller) &&
        pt_should_hide_swift_metadata_ptr(meta)) {
        return NULL;
    }
    return meta;
}

static const void *pt_swift_getTypeByMangledNameInContextInMetadataState(size_t metadataState,
                                                                        const char *typeNameStart,
                                                                        size_t typeNameLength,
                                                                        const void *context,
                                                                        const void * const *genericArgs)
    __attribute__((swiftcall)) {
    const void *caller = __builtin_return_address(0);
    if (pt_should_hide_swift_type_lookup(typeNameStart, typeNameLength, caller) ||
        &swift_getTypeByMangledNameInContextInMetadataState == NULL) {
        return NULL;
    }
    const void *meta = swift_getTypeByMangledNameInContextInMetadataState(metadataState,
                                                                          typeNameStart,
                                                                          typeNameLength,
                                                                          context,
                                                                          genericArgs);
    if (meta != NULL && pt_is_bypass_enabled() &&
        pt_is_swift_type_lookup_app_caller(caller) &&
        pt_should_hide_swift_metadata_ptr(meta)) {
        return NULL;
    }
    return meta;
}

static const void *pt_swift_getTypeByMangledNameInContextInMetadataState2(size_t metadataState,
                                                                         const char *typeNameStart,
                                                                         size_t typeNameLength,
                                                                         const void *context,
                                                                         const void * const *genericArgs)
    __attribute__((swiftcall)) {
    const void *caller = __builtin_return_address(0);
    if (pt_should_hide_swift_type_lookup(typeNameStart, typeNameLength, caller) ||
        &swift_getTypeByMangledNameInContextInMetadataState2 == NULL) {
        return NULL;
    }
    const void *meta = swift_getTypeByMangledNameInContextInMetadataState2(metadataState,
                                                                           typeNameStart,
                                                                           typeNameLength,
                                                                           context,
                                                                           genericArgs);
    if (meta != NULL && pt_is_bypass_enabled() &&
        pt_is_swift_type_lookup_app_caller(caller) &&
        pt_should_hide_swift_metadata_ptr(meta)) {
        return NULL;
    }
    return meta;
}

static const void *pt_swift_getTypeByMangledNameInEnvironment(const char *typeNameStart,
                                                              size_t typeNameLength,
                                                              const void *environment,
                                                              const void * const *genericArgs)
    __attribute__((swiftcall)) {
    const void *caller = __builtin_return_address(0);
    if (pt_should_hide_swift_type_lookup(typeNameStart, typeNameLength, caller) ||
        &swift_getTypeByMangledNameInEnvironment == NULL) {
        return NULL;
    }
    const void *meta = swift_getTypeByMangledNameInEnvironment(typeNameStart,
                                                              typeNameLength,
                                                              environment,
                                                              genericArgs);
    if (meta != NULL && pt_is_bypass_enabled() &&
        pt_is_swift_type_lookup_app_caller(caller) &&
        pt_should_hide_swift_metadata_ptr(meta)) {
        return NULL;
    }
    return meta;
}

static const void *pt_swift_getTypeByMangledNameInEnvironmentInMetadataState(size_t metadataState,
                                                                             const char *typeNameStart,
                                                                             size_t typeNameLength,
                                                                             const void *environment,
                                                                             const void * const *genericArgs)
    __attribute__((swiftcall)) {
    const void *caller = __builtin_return_address(0);
    if (pt_should_hide_swift_type_lookup(typeNameStart, typeNameLength, caller) ||
        &swift_getTypeByMangledNameInEnvironmentInMetadataState == NULL) {
        return NULL;
    }
    const void *meta = swift_getTypeByMangledNameInEnvironmentInMetadataState(metadataState,
                                                                             typeNameStart,
                                                                             typeNameLength,
                                                                             environment,
                                                                             genericArgs);
    if (meta != NULL && pt_is_bypass_enabled() &&
        pt_is_swift_type_lookup_app_caller(caller) &&
        pt_should_hide_swift_metadata_ptr(meta)) {
        return NULL;
    }
    return meta;
}

static const void *pt_swift_getTypeByMangledName(size_t metadataState,
                                                 const char *typeNameStart,
                                                 size_t typeNameLength,
                                                 const void * const *origGenericArgs,
                                                 void *substGenericParam,
                                                 void *substWitnessTable)
    __attribute__((swiftcall)) {
    const void *caller = __builtin_return_address(0);
    if (pt_should_hide_swift_type_lookup(typeNameStart, typeNameLength, caller) ||
        &swift_getTypeByMangledName == NULL) {
        return NULL;
    }
    const void *meta = swift_getTypeByMangledName(metadataState,
                                                  typeNameStart,
                                                  typeNameLength,
                                                  origGenericArgs,
                                                  substGenericParam,
                                                  substWitnessTable);
    if (meta != NULL && pt_is_bypass_enabled() &&
        pt_is_swift_type_lookup_app_caller(caller) &&
        pt_should_hide_swift_metadata_ptr(meta)) {
        return NULL;
    }
    return meta;
}

static BOOL pt_should_hide_swift_protocol_descriptor(const void *protocol) {
    if (protocol == NULL || (((uintptr_t)protocol & 0x3U) != 0) || !pt_is_valid_user_pointer(protocol)) {
        return NO;
    }
    const struct mach_header *mh = dyld_image_header_containing_address(protocol);
    const char *img = dyld_image_path_containing_address(protocol);
    if ((mh != NULL && pt_is_hidden_dyld_image_header(mh)) ||
        (img != NULL && pt_should_hide_dyld_image(img))) {
        return YES;
    }
    uint32_t flags = 0;
    memcpy(&flags, protocol, sizeof(flags));
    if ((flags & 0x1FU) != 3U) { // ContextDescriptorKind::Protocol == 3
        return NO;
    }
    int32_t rel = 0;
    memcpy(&rel, (const uint8_t *)protocol + 8U, sizeof(rel));
    if (rel == 0) {
        return NO;
    }
    uintptr_t name_addr = (uintptr_t)protocol + 8U + (intptr_t)rel;
    const char *pname = (const char *)name_addr;
    if (!pt_is_valid_user_pointer(pname)) {
        return NO;
    }
    char pbuf[128];
    size_t plen = strnlen(pname, sizeof(pbuf) - 1U);
    memcpy(pbuf, pname, plen);
    pbuf[plen] = '\0';
    if (pt_is_hidden_objc_class(pbuf)) {
        return YES;
    }
    if (!pt_is_compat13_7_active()) {
        return NO;
    }
    return (strcmp(pbuf, "Sendable") == 0 ||
            strcmp(pbuf, "App") == 0 ||
            strcmp(pbuf, "Scene") == 0 ||
            strcmp(pbuf, "FormatStyle") == 0 ||
            strcmp(pbuf, "Observable") == 0 ||
            strcmp(pbuf, "Actor") == 0 ||
            strcmp(pbuf, "Clock") == 0 ||
            strcmp(pbuf, "DurationProtocol") == 0);
}

static BOOL pt_swift_conformsToProtocol_should_hide_input(const void *type,
                                                          const void *protocol,
                                                          const void *caller) {
    if (!pt_is_bypass_enabled() || !pt_is_swift_type_lookup_app_caller(caller)) {
        return NO;
    }
    return (pt_should_hide_swift_metadata_ptr(type) ||
            pt_should_hide_swift_protocol_descriptor(protocol));
}

static const void *pt_swift_conformsToProtocol_filter_wt(const void *wt, const void *caller) {
    if (wt != NULL && pt_is_bypass_enabled() && pt_is_swift_type_lookup_app_caller(caller)) {
        const struct mach_header *wmh = dyld_image_header_containing_address(wt);
        const char *wimg = dyld_image_path_containing_address(wt);
        if ((wmh != NULL && pt_is_hidden_dyld_image_header(wmh)) ||
            (wimg != NULL && pt_should_hide_dyld_image(wimg))) {
            return NULL;
        }
    }
    return wt;
}

static const void *pt_swift_conformsToProtocol(const void *type, const void *protocol) {
    if (&swift_conformsToProtocol == NULL) {
        return NULL;
    }
    const void *caller = __builtin_return_address(0);
    if (pt_swift_conformsToProtocol_should_hide_input(type, protocol, caller)) {
        return NULL;
    }
    return pt_swift_conformsToProtocol_filter_wt(swift_conformsToProtocol(type, protocol), caller);
}

static const void *pt_swift_conformsToProtocol2(const void *type, const void *protocol) {
    if (&swift_conformsToProtocol2 == NULL) {
        return NULL;
    }
    const void *caller = __builtin_return_address(0);
    if (pt_swift_conformsToProtocol_should_hide_input(type, protocol, caller)) {
        return NULL;
    }
    return pt_swift_conformsToProtocol_filter_wt(swift_conformsToProtocol2(type, protocol), caller);
}

static const void *pt_swift_conformsToProtocolCommon(const void *type, const void *protocol) {
    if (&swift_conformsToProtocolCommon == NULL) {
        return NULL;
    }
    const void *caller = __builtin_return_address(0);
    if (pt_swift_conformsToProtocol_should_hide_input(type, protocol, caller)) {
        return NULL;
    }
    return pt_swift_conformsToProtocol_filter_wt(swift_conformsToProtocolCommon(type, protocol), caller);
}

static const void *pt_swift_conformsToProtocolWithExecutionContext(const void *type,
                                                                 const void *protocol,
                                                                 const void *ctx) {
    if (&swift_conformsToProtocolWithExecutionContext == NULL) {
        return NULL;
    }
    const void *caller = __builtin_return_address(0);
    if (pt_swift_conformsToProtocol_should_hide_input(type, protocol, caller)) {
        return NULL;
    }
    return pt_swift_conformsToProtocol_filter_wt(
        swift_conformsToProtocolWithExecutionContext(type, protocol, ctx), caller);
}

static BOOL pt_is_hidden_swift_type_cstr(const char *buf, size_t len) {
    if (pt_is_hidden_swift_mangled_type_name(buf, len)) {
        return YES;
    }
    if (buf == NULL || len == 0 || !pt_is_valid_user_pointer(buf)) {
        return NO;
    }
    char tmp[512];
    size_t copy_len = (len >= sizeof(tmp)) ? (sizeof(tmp) - 1U) : len;
    memcpy(tmp, buf, copy_len);
    tmp[copy_len] = '\0';
    return (strcmp(tmp, "PlayTools") == 0 ||
            strcmp(tmp, "AKInterface") == 0 ||
            strcmp(tmp, "PlayCover") == 0 ||
            pt_is_hidden_objc_class(tmp));
}

static BOOL pt_swift_string_is_hidden_type(uint64_t w0, uint64_t w1) {
    if ((w1 & (1ULL << 61)) != 0) {
        size_t len = (size_t)((w1 >> 56) & 0xfULL);
        char sbuf[16];
        memset(sbuf, 0, sizeof(sbuf));
        memcpy(sbuf, &w0, 8);
        memcpy(sbuf + 8, &w1, 7);
        return pt_is_hidden_swift_type_cstr(sbuf, len);
    }
    if (&pt_orig_swift_string_bridge == NULL) {
        return NO;
    }
    CFTypeRef cf = pt_orig_swift_string_bridge(w0, w1);
    if (cf == NULL) {
        return NO;
    }
    char stack_buf[1024];
    const char *cstr = CFStringGetCStringPtr((CFStringRef)cf, kCFStringEncodingUTF8);
    if (cstr == NULL &&
        CFStringGetCString((CFStringRef)cf, stack_buf, sizeof(stack_buf), kCFStringEncodingUTF8)) {
        cstr = stack_buf;
    }
    BOOL hide = (cstr != NULL && pt_is_hidden_swift_type_cstr(cstr, strlen(cstr)));
    CFRelease(cf);
    return hide;
}

static const void *pt_swift_typeByName(uint64_t w0, uint64_t w1) __attribute__((swiftcall)) {
    const void *caller = __builtin_return_address(0);
    BOOL appCaller = (pt_is_bypass_enabled() && pt_is_swift_type_lookup_app_caller(caller));
    if (appCaller && pt_swift_string_is_hidden_type(w0, w1)) {
        return NULL;
    }
    if (&pt_orig_swift_typeByName == NULL) {
        return NULL;
    }
    const void *meta = pt_orig_swift_typeByName(w0, w1);
    if (meta != NULL && appCaller && pt_should_hide_swift_metadata_ptr(meta)) {
        return NULL;
    }
    return meta;
}

__attribute__((visibility("hidden"))) BOOL pt_is_hidden_macos_only_dlsym_symbol(const char *symbol) {
    return pt_is_hidden_macos_only_dlsym_symbol_cstr(symbol) ? YES : NO;
}

static void *pt_dlsym(void *handle, const char *symbol);

static void *pt_dlsym_resolve_compat13_cf_version(void) {
    static const double s_compat13_cf_version = 1677.104;
    return pt_is_compat13_7_active() ? (void *)&s_compat13_cf_version : NULL;
}


PT_DLSYM_DYNAMIC("kCFCoreFoundationVersionNumber", pt_dlsym_resolve_compat13_cf_version)
PT_DLSYM_DYNAMIC("NSFoundationVersionNumber", pt_dlsym_resolve_compat13_cf_version)

__attribute__((visibility("hidden"))) void *pt_route_dlsym_symbol_for_app(const char *symbol) {
    return pt_interpose_registry_lookup(symbol, pt_is_compat13_7_active() ? true : false);
}

static BOOL pt_is_internal_automation_reg_symbol(const char *symbol) {
    if (symbol == NULL) {
        return NO;
    }
    return (strcmp(symbol, "pt_register_hidden_fd") == 0 ||
            strcmp(symbol, "pt_unregister_hidden_fd") == 0 ||
            strcmp(symbol, "pt_register_hidden_loopback_port") == 0 ||
            strcmp(symbol, "pt_unregister_hidden_loopback_port") == 0 ||
            strcmp(symbol, "pt_consume_automation_bootstrap") == 0);
}

static void *pt_dlsym(void *handle, const char *symbol) {
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return dlsym(handle, symbol);
    }
    s_tls_dlerror_pending = false;
    const void *caller = __builtin_return_address(0);
    BOOL is_sys_or_pt = pt_is_effective_system_or_playtools_caller(caller);
    if (!is_sys_or_pt && symbol != NULL && pt_is_internal_automation_reg_symbol(symbol)) {
        PT_DEBUG_TRACE("dyld", "hid internal automation symbol=%s", symbol);
        pt_set_synthetic_dlerror("symbol not found");
        return NULL;
    }
    BOOL app_caller = (pt_is_bypass_enabled() && !is_sys_or_pt);
    if (app_caller && symbol != NULL) {
        if (strncmp(symbol, "OBJC_CLASS_$_", 13) == 0) {
            const char *clsName = symbol + 13;
            if (pt_should_hide_resolved_objc_class(clsName, (__bridge Class)pt_orig_objc_lookUpClass(clsName))) {
                PT_DEBUG_TRACE("dyld", "hid dlsym symbol=%s", symbol);
                pt_set_synthetic_dlerror("symbol not found");
                return NULL;
            }
        } else if (strncmp(symbol, "OBJC_METACLASS_$_", 17) == 0) {
            const char *clsName = symbol + 17;
            if (pt_should_hide_resolved_objc_class(clsName, (__bridge Class)pt_orig_objc_lookUpClass(clsName))) {
                PT_DEBUG_TRACE("dyld", "hid dlsym symbol=%s", symbol);
                pt_set_synthetic_dlerror("symbol not found");
                return NULL;
            }
        } else if (strncmp(symbol, "OBJC_EHTYPE_$_", 14) == 0) {
            const char *clsName = symbol + 14;
            if (pt_should_hide_resolved_objc_class(clsName, (__bridge Class)pt_orig_objc_lookUpClass(clsName))) {
                PT_DEBUG_TRACE("dyld", "hid dlsym symbol=%s", symbol);
                pt_set_synthetic_dlerror("symbol not found");
                return NULL;
            }
        } else if (pt_is_hidden_macos_only_dlsym_symbol(symbol) ||
                   (pt_is_compat13_7_active() &&
                    (PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI10LazyVStack") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI12ProgressView") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI10LazyHStack") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI9LazyVGrid") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI9LazyHGrid") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI10TextEditor") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI11ColorPicker") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI10AsyncImage") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI15NavigationStack") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI19NavigationSplitViewV") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI4GridV") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI7GridRowV") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI10AppStorage") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI11StateObject") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI12SceneStorage") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI12ScaledMetric") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI3AppP") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI5SceneP") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI11WindowGroupV") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI6CanvasV") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI12TimelineViewV") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI5LabelV") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI4LinkV") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s10Foundation16AttributedString") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s10Foundation11FormatStyle") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s10Foundation10Morphology") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s8StoreKit7Product") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s8StoreKit11Transaction") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s17_StringProcessing") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s11Observation") ||
                     PT_HAS_PREFIX_LIT(symbol, "$ss8DurationV") ||
                     PT_HAS_PREFIX_LIT(symbol, "$ss15ContinuousClockV") ||
                     PT_HAS_PREFIX_LIT(symbol, "$ss15SuspendingClockV") ||
                     PT_HAS_PREFIX_LIT(symbol, "$ss8SendableP") ||
                     PT_HAS_PREFIX_LIT(symbol, "$sScT") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s12_Concurrency") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s22UniformTypeIdentifiers6UTType") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s5OSLog6Logger")))) {
            PT_DEBUG_TRACE("dyld", "hid macOS-only symbol=%s", symbol);
            pt_set_synthetic_dlerror("symbol not found");
            return NULL;
        } else if (handle == RTLD_DEFAULT || handle == RTLD_NEXT) {
            void *routed = pt_route_dlsym_symbol_for_app(symbol);
            if (routed == PT_DLSYM_HIDDEN_SENTINEL) {
                PT_DEBUG_TRACE("dyld", "hid compat13 symbol=%s", symbol);
                pt_set_synthetic_dlerror("symbol not found");
                return NULL;
            }
            if (routed != NULL) {
                return routed;
            }
        }
    }
    void *sym = NULL;
    BOOL resolved_rtld_next = NO;
    if (handle == RTLD_NEXT && caller != NULL && symbol != NULL) {
        const void *scaller = pt_strip_return_addr((uintptr_t)caller);
        const struct mach_header *caller_hdr = dyld_image_header_containing_address(scaller);
        if (caller_hdr != NULL) {
            uint32_t count = _dyld_image_count();
            uint32_t caller_idx = UINT32_MAX;
            for (uint32_t i = 0; i < count; i++) {
                if (_dyld_get_image_header(i) == caller_hdr) {
                    caller_idx = i;
                    break;
                }
            }
            if (caller_idx != UINT32_MAX) {
                for (uint32_t j = caller_idx + 1U; j < count; j++) {
                    const struct mach_header *img_hdr = _dyld_get_image_header(j);
                    const char *img_name = _dyld_get_image_name(j);
                    if (img_name == NULL) {
                        continue;
                    }
                    if (app_caller &&
                        (pt_is_hidden_dyld_image_header(img_hdr) ||
                         pt_is_hidden_dyld_image_name(img_name) ||
                         pt_is_post13_7_hidden_framework_path(img_name))) {
                        continue;
                    }
                    if (strstr(img_name, "PlayTools") != NULL ||
                        strstr(img_name, "AKInterface") != NULL ||
                        strstr(img_name, "UserPlugins") != NULL) {
                        continue;
                    }
                    void *h = dlopen(img_name, RTLD_LAZY | RTLD_NOLOAD | RTLD_FIRST);
                    if (h != NULL) {
                        void *cand = dlsym(h, symbol);
                        dlclose(h);
                        if (cand != NULL) {
                            sym = cand;
                            resolved_rtld_next = YES;
                            break;
                        }
                    }
                }
            }
        }
    }
    if (!resolved_rtld_next) {
        void *temp_self_handle = NULL;
        void *lookup_handle = handle;
        if (handle == RTLD_SELF && caller != NULL) {
            const void *scaller = pt_strip_return_addr((uintptr_t)caller);
            const char *caller_img = dyld_image_path_containing_address(scaller);
            if (caller_img != NULL) {
                temp_self_handle = dlopen(caller_img, RTLD_LAZY | RTLD_NOLOAD);
                if (temp_self_handle != NULL) {
                    lookup_handle = temp_self_handle;
                }
            }
        }
        sym = dlsym(lookup_handle, symbol);
        if (temp_self_handle != NULL) {
            dlclose(temp_self_handle);
        }
    } else {
        (void)dlerror();
    }
    if (sym != NULL && app_caller) {
        const void *target_sym = pt_resolve_interposed_target(sym);
        Dl_info sym_info = {0};
        BOOL has_sym_info = (dladdr(target_sym, &sym_info) != 0 && sym_info.dli_fname != NULL);
        if (target_sym == sym) {
            BOOL cf_carboncore_bridge = (has_sym_info && handle != NULL && handle != RTLD_DEFAULT &&
                                         handle != RTLD_NEXT && handle != RTLD_MAIN_ONLY && handle != RTLD_SELF &&
                                         pt_is_carboncore_framework_path_cstr(sym_info.dli_fname) &&
                                         pt_is_cf_internal_carboncore_caller(caller));
            const struct mach_header *sym_hdr = dyld_image_header_containing_address(target_sym);
            if (!cf_carboncore_bridge && sym_hdr != NULL && pt_is_hidden_dyld_image_header(sym_hdr)) {
                PT_DEBUG_TRACE("dyld", "hid dlsym symbol=%s", symbol != NULL ? symbol : "<null>");
                pt_set_synthetic_dlerror("symbol not found");
                return NULL;
            }
            if (!cf_carboncore_bridge && has_sym_info &&
                (pt_is_hidden_dyld_image_name(sym_info.dli_fname) ||
                 pt_is_post13_7_hidden_framework_path(sym_info.dli_fname))) {
                PT_DEBUG_TRACE("dyld", "hid dlsym symbol=%s", symbol != NULL ? symbol : "<null>");
                pt_set_synthetic_dlerror("symbol not found");
                return NULL;
            }
        }
        if (has_sym_info &&
            handle != NULL && handle != RTLD_DEFAULT && handle != RTLD_NEXT &&
            handle != RTLD_MAIN_ONLY && handle != RTLD_SELF &&
            symbol != NULL &&
            (strncmp(sym_info.dli_fname, "/usr/lib/system/", 16) == 0 ||
             strcmp(sym_info.dli_fname, "/usr/lib/libSystem.B.dylib") == 0)) {
            char opened_path[PATH_MAX];
            if (pt_lookup_explicit_framework_handle_path(handle, opened_path, sizeof(opened_path))) {
                void *first_h = dlopen(opened_path, RTLD_LAZY | RTLD_NOLOAD | RTLD_FIRST);
                void *direct_sym = NULL;
                if (first_h != NULL) {
                    direct_sym = dlsym(first_h, symbol);
                    dlclose(first_h);
                }
                if (direct_sym == NULL) {
                    PT_DEBUG_TRACE("dyld",
                                   "hid transitive libsystem dlsym handle=%s symbol=%s",
                                   opened_path,
                                   symbol);
                    pt_set_synthetic_dlerror("symbol not found");
                    return NULL;
                }
            }
        }
        if (handle != RTLD_DEFAULT && handle != RTLD_NEXT && handle != RTLD_MAIN_ONLY && symbol != NULL) {
            void *routed = pt_route_dlsym_symbol_for_app(symbol);
            if (routed == PT_DLSYM_HIDDEN_SENTINEL) {
                PT_DEBUG_TRACE("dyld", "hid compat13 symbol=%s", symbol);
                pt_set_synthetic_dlerror("symbol not found");
                return NULL;
            }
            if (routed != NULL) {
                return routed;
            }
        }
    }
    return sym;
}

PT_INTERPOSE(pt_dlopen, dlopen)
PT_INTERPOSE(pt_dlopen_audited, dlopen_audited)
PT_INTERPOSE(pt_dlopen_from, dlopen_from)
PT_INTERPOSE(pt_dlopen_preflight, dlopen_preflight)
PT_INTERPOSE(pt_dlclose, dlclose)
PT_INTERPOSE(pt_dlsym, dlsym)
PT_INTERPOSE(pt_dlerror, dlerror)
PT_INTERPOSE_WEAK(pt_swift_getTypeByMangledName, swift_getTypeByMangledName)
PT_INTERPOSE_WEAK(pt_swift_getTypeByMangledNameInContext, swift_getTypeByMangledNameInContext)
PT_INTERPOSE_WEAK_NAMED_FLAGS(pt_swift_getTypeByMangledNameInContext2, swift_getTypeByMangledNameInContext2, "swift_getTypeByMangledNameInContext2", PT_DLSYM_FLAG_HIDE_IN_COMPAT13_7)
PT_INTERPOSE_WEAK(pt_swift_getTypeByMangledNameInContextInMetadataState, swift_getTypeByMangledNameInContextInMetadataState)
PT_INTERPOSE_WEAK_NAMED_FLAGS(pt_swift_getTypeByMangledNameInContextInMetadataState2, swift_getTypeByMangledNameInContextInMetadataState2, "swift_getTypeByMangledNameInContextInMetadataState2", PT_DLSYM_FLAG_HIDE_IN_COMPAT13_7)
PT_INTERPOSE_WEAK(pt_swift_getTypeByMangledNameInEnvironment, swift_getTypeByMangledNameInEnvironment)
PT_INTERPOSE_WEAK(pt_swift_getTypeByMangledNameInEnvironmentInMetadataState, swift_getTypeByMangledNameInEnvironmentInMetadataState)
PT_INTERPOSE_WEAK_NAMED(pt_swift_typeByName, pt_orig_swift_typeByName, "$ss11_typeByNameyypXpSgSSF")
PT_INTERPOSE_WEAK(pt_swift_conformsToProtocol, swift_conformsToProtocol)
PT_INTERPOSE_WEAK_NAMED_FLAGS(pt_swift_conformsToProtocol2, swift_conformsToProtocol2, "swift_conformsToProtocol2", PT_DLSYM_FLAG_HIDE_IN_COMPAT13_7)
PT_INTERPOSE_WEAK(pt_swift_conformsToProtocolCommon, swift_conformsToProtocolCommon)
PT_INTERPOSE_WEAK_NAMED_FLAGS(pt_swift_conformsToProtocolWithExecutionContext, swift_conformsToProtocolWithExecutionContext, "swift_conformsToProtocolWithExecutionContext", PT_DLSYM_FLAG_HIDE_IN_COMPAT13_7)
