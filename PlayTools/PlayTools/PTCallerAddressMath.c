//
//  PTCallerAddressMath.c
//  PlayTools
//

#include "PTCallerAddressMath.h"
#include "Subsystems/PTRegistration.h"
#include <stdatomic.h>
#include <string.h>
#include <strings.h>
#include <sys/sysctl.h>

static _Atomic uint64_t s_pt_user_addr_strip_mask = PT_USER_ADDR_STRIP_MASK;

uint64_t pt_active_user_addr_strip_mask(void) {
    return atomic_load_explicit(&s_pt_user_addr_strip_mask, memory_order_relaxed);
}

void pt_configure_user_va_bits(uint8_t va_bits) {
    uint64_t mask = (va_bits >= 52U) ? PT_USER_ADDR_LVA_STRIP_MASK : PT_USER_ADDR_STRIP_MASK;
    atomic_store_explicit(&s_pt_user_addr_strip_mask, mask, memory_order_release);
}

void pt_init_user_va_bits_from_kernel(void) {
    uint32_t va_bits = 0;
    size_t len = sizeof(va_bits);
    if (sysctlbyname("machdep.virtual_address_size", &va_bits, &len, NULL, 0) == 0 && len == sizeof(va_bits)) {
        pt_configure_user_va_bits((uint8_t)(va_bits > 255U ? 255U : va_bits));
    }
}

static _Thread_local int s_tls_playtools_internal_depth = 0;

void pt_enter_internal_scope(void) {
    s_tls_playtools_internal_depth++;
}

void pt_leave_internal_scope(void) {
    if (s_tls_playtools_internal_depth > 0) {
        s_tls_playtools_internal_depth--;
    }
}

bool pt_is_in_internal_scope(void) {
    return s_tls_playtools_internal_depth > 0;
}

static bool pt_path_has_dotdot(const char *fname) {
    if (fname == NULL) {
        return false;
    }
    if (strstr(fname, "/../") != NULL || strcmp(fname, "..") == 0) {
        return true;
    }
    size_t len = strlen(fname);
    if (len >= 3 && strcmp(fname + len - 3, "/..") == 0) {
        return true;
    }
    if (strncmp(fname, "../", 3) == 0) {
        return true;
    }
    return false;
}

static bool pt_match_runtime_segment(const char *fname, const char *segment) {
    const char *hit = strstr(fname, segment);
    if (hit == NULL) {
        return false;
    }
    const char *after = hit + strlen(segment);
    return strstr(after, ".app/") == NULL;
}

static bool pt_is_playtools_runtime_path(const char *fname) {
    if (pt_match_runtime_segment(fname, "/Frameworks/PlayTools.framework/") ||
        pt_match_runtime_segment(fname, "/PlayTools.framework/PlugIns/AKInterface.bundle/") ||
        pt_match_runtime_segment(fname, ".app/Contents/PlugIns/AKInterface.bundle/") ||
        pt_match_runtime_segment(fname, ".app/PlugIns/AKInterface.bundle/") ||
        pt_match_runtime_segment(fname, "/Frameworks/UserPlugins/") ||
        pt_match_runtime_segment(fname, "/PlayTools/UserPlugins/")) {
        return true;
    }
    if (strncmp(fname, "PlayTools.framework/", 20) == 0 && strstr(fname + 20, ".app/") == NULL) {
        return true;
    }
    if (strncmp(fname, "AKInterface.bundle/", 19) == 0 && strstr(fname + 19, ".app/") == NULL) {
        return true;
    }
    return false;
}

bool pt_is_wrapper_library_path(const char *fname) {
    if (fname == NULL || fname[0] == '\0' || pt_path_has_dotdot(fname)) {
        return false;
    }
    if (strncmp(fname, "/System/", 8) != 0 && strncmp(fname, "/usr/lib/", 9) != 0 &&
        strncmp(fname, "/Library/Apple/", 15) != 0) {
        return false;
    }
    return (strncmp(fname, "/usr/lib/system/", 16) == 0 || strncmp(fname, "/usr/lib/swift/", 15) == 0 ||
            strncmp(fname, "/usr/lib/libz.", 14) == 0 || strncmp(fname, "/usr/lib/libxml2.", 17) == 0 ||
            strncmp(fname, "/usr/lib/libarchive.", 20) == 0 || strstr(fname, "libc++.") != NULL ||
            strstr(fname, "libobjc.A.dylib") != NULL || strstr(fname, "libsqlite3.") != NULL ||
            strstr(fname, "/Foundation.framework/") != NULL ||
            strstr(fname, "/FoundationEssentials.framework/") != NULL ||
            strstr(fname, "/FoundationInternationalization.framework/") != NULL ||
            strstr(fname, "/CoreFoundation.framework/") != NULL ||
            strstr(fname, "/CoreServicesInternal.framework/") != NULL);
}

uint8_t pt_classify_caller_image_path(const char *fname, bool *out_cacheable) {
    if (out_cacheable != NULL) {
        *out_cacheable = false;
    }
    if (fname == NULL || fname[0] == '\0') {
        return PT_CALLER_APP;
    }
    bool has_dotdot = pt_path_has_dotdot(fname);
    if (!has_dotdot && (strncmp(fname, "/System/", 8) == 0 || strncmp(fname, "/usr/lib/", 9) == 0 ||
                        strncmp(fname, "/Library/Apple/", 15) == 0)) {
        if (out_cacheable != NULL) {
            *out_cacheable = true;
        }
        return pt_is_wrapper_library_path(fname) ? PT_CALLER_SYS_WRAPPER : PT_CALLER_SYS_NON_WRAPPER;
    }
    if (!has_dotdot && pt_is_playtools_runtime_path(fname)) {
        if (out_cacheable != NULL) {
            *out_cacheable = true;
        }
        return PT_CALLER_PLAYTOOLS;
    }
    if (strstr(fname, ".app/") != NULL) {
        if (!has_dotdot && out_cacheable != NULL) {
            *out_cacheable = true;
        }
        return PT_CALLER_APP;
    }
    return PT_CALLER_APP;
}

static const char *pt_math_match_prefix_modulo_private(const char *path, const char *base, size_t base_len) {
    if (path == NULL || base == NULL || base_len == 0U) {
        return NULL;
    }
    if (strncasecmp(path, base, base_len) == 0 && (path[base_len] == '/' || path[base_len] == '\0')) {
        return path + base_len;
    }
    if (base_len > 8U && strncasecmp(base, "/private/", 9) == 0) {
        const char *sbase = base + 8;
        size_t slen = base_len - 8U;
        if (strncasecmp(path, sbase, slen) == 0 && (path[slen] == '/' || path[slen] == '\0')) {
            return path + slen;
        }
    } else if (strncasecmp(path, "/private/", 9) == 0) {
        const char *spath = path + 8;
        if (strncasecmp(spath, base, base_len) == 0 && (spath[base_len] == '/' || spath[base_len] == '\0')) {
            return spath + base_len;
        }
    }
    return NULL;
}

static bool pt_rel_has_sensitive_runtime_component(const char *rel) {
    if (rel == NULL || rel[0] == '\0') {
        return false;
    }
    if (pt_is_registered_hidden_module(rel)) {
        return true;
    }
    return (strcasestr(rel, "PlayTools.framework") != NULL || strcasestr(rel, "PlayTools.dylib") != NULL ||
            strcasestr(rel, "Playtools.strings") != NULL || strcasestr(rel, "app.makedie.MacOver") != NULL ||
            strcasestr(rel, "io.playcover.PlayCover") != NULL || strcasestr(rel, "AKInterface.bundle") != NULL ||
            strcasestr(rel, "UserPlugins") != NULL || strcasestr(rel, ".pt_sysver_") != NULL ||
            strcasestr(rel, ".pt_coderes_") != NULL || strcasestr(rel, ".pt_info_") != NULL ||
            strcasestr(rel, "pm_keymapping_state") != NULL || strcasestr(rel, "toucher.log") != NULL);
}

bool pt_is_nonsensitive_app_or_tmp_path(const char *norm_path, const char *bundle_dir, size_t bundle_len,
                                        const char *data_dir, size_t data_len) {
    if (norm_path == NULL || norm_path[0] != '/' || pt_path_has_dotdot(norm_path)) {
        return false;
    }

    const char *work = norm_path;
    if (strncasecmp(work, "/System/Volumes/Data/", 21) == 0) {
        work += 20;
    }

    if (pt_is_registered_hidden_module(work)) {
        return false;
    }

    if (bundle_dir != NULL && bundle_len > 0U) {
        const char *rel = pt_math_match_prefix_modulo_private(work, bundle_dir, bundle_len);
        if (rel != NULL) {
            return !pt_rel_has_sensitive_runtime_component(rel);
        }
    }

    if (data_dir != NULL && data_len > 0U) {
        const char *rel = pt_math_match_prefix_modulo_private(work, data_dir, data_len);
        if (rel != NULL && (strcasecmp(rel, "/tmp") == 0 || strncasecmp(rel, "/tmp/", 5) == 0)) {
            return !pt_rel_has_sensitive_runtime_component(rel);
        }
    }

    return false;
}

bool pt_classify_bounded_frame_kinds_ex(const uint8_t *frame_kinds, size_t count, bool initial_seen_wrapper,
                                        bool *out_cacheable_3frame) {
    (void)initial_seen_wrapper;
    if (out_cacheable_3frame != NULL) {
        *out_cacheable_3frame = false;
    }
    if (frame_kinds == NULL || count == 0U) {
        return true;
    }
    size_t limit = count < (size_t)PT_MAX_CALLER_UNWIND_DEPTH ? count : (size_t)PT_MAX_CALLER_UNWIND_DEPTH;
    for (size_t i = 0; i < limit; i++) {
        uint8_t fkind = frame_kinds[i];
        if (fkind == PT_CALLER_PLAYTOOLS || fkind == PT_CALLER_SYS_WRAPPER) {
            continue;
        }
        if (out_cacheable_3frame != NULL) {
            *out_cacheable_3frame = (i < 3U);
        }
        return (fkind != PT_CALLER_APP);
    }
    return true;
}

bool pt_classify_bounded_frame_kinds(const uint8_t *frame_kinds, size_t count, bool initial_seen_wrapper) {
    return pt_classify_bounded_frame_kinds_ex(frame_kinds, count, initial_seen_wrapper, NULL);
}
