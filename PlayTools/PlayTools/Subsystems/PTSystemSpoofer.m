//
//  PTSystemSpoofer.m
//  PlayTools
//

#import "PTInternal.h"
@import AudioToolbox;
@import CoreServices;
@import IOKit;
#include <grp.h>
#include <notify.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>

// Get device model from playcover .plist
// With a null terminator
__attribute__((visibility("hidden"))) volatile _Atomic bool s_libsystem_ready = false;
__attribute__((visibility("hidden"))) _Atomic BOOL s_pt_loaded = NO;
static _Atomic BOOL s_pt_device_info_ready = NO;
__attribute__((visibility("hidden"))) _Atomic BOOL s_bypass_enabled = YES;
__attribute__((visibility("hidden"))) _Atomic BOOL s_pt_bypass_inited = NO;
__attribute__((visibility("hidden"))) _Thread_local int s_tls_bypass_init_depth = 0;
static _Thread_local int s_tls_early_device_init = 0;
__attribute__((visibility("hidden"))) _Atomic int s_playchain_cached = -1;
__attribute__((visibility("hidden"))) _Atomic int s_playchain_debug_cached = -1;
__attribute__((visibility("hidden"))) pthread_once_t s_pt_bypass_early_once = PTHREAD_ONCE_INIT;
static char s_uncoerced_device_model[64] = "";
static _Atomic BOOL s_has_uncoerced_device_model = NO;
static char s_early_device_model[64] = "iPad13,8";
static char s_early_oem_id[64] = "J522AP";
static char s_final_device_model[64] = "iPad13,8";
static char s_final_oem_id[64] = "J522AP";
static _Atomic(const char *) s_active_device_model = s_early_device_model;
static _Atomic(const char *) s_active_oem_id = s_early_oem_id;
static _Atomic BOOL s_reported_ios_override_forced_off = NO;
static pthread_once_t s_pt_early_device_once = PTHREAD_ONCE_INIT;
__attribute__((visibility("hidden"))) pthread_once_t s_pt_device_info_once = PTHREAD_ONCE_INIT;
__attribute__((visibility("hidden"))) _Thread_local BOOL s_tls_initializing_device_info = NO;


static const pt_device_profile_t s_device_profiles[] = {
    { "iPad6,7",    "J98aAP",  "Apple A9X",        "Apple A9X GPU",     2, 2, 0, 4ULL << 30, 0x67ceee93U, "RELEASE_ARM64_T8000", "t8000", "iPad Pro (12.9-inch)",                  "ML0F2", "A1584", YES, 2048, 2732, 2.0, 60,  1003, "applegpu_g8s",  12, "G8S"  },
    { "iPad8,6",    "J320xAP", "Apple A12X Bionic","Apple A12X GPU",    8, 4, 4, 4ULL << 30, 0x07d34b9fU, "RELEASE_ARM64_T8027", "t8027", "iPad Pro (12.9-inch) (3rd generation)", "MTEL2", "A1876", YES, 2048, 2732, 2.0, 120, 1005, "applegpu_g11g",  7, "G11G" },
    { "iPad13,8",   "J522AP",  "Apple M1",         "Apple M1 GPU",      8, 4, 4, 8ULL << 30, 0x1b588bb3U, "RELEASE_ARM64_T8103", "t8103", "iPad Pro (12.9-inch) (5th generation)", "MHNF3", "A2378", YES, 2048, 2732, 2.0, 120, 1007, "applegpu_g13g",  8, "G13G" },
    { "iPad14,5",   "J620AP",  "Apple M2",         "Apple M2 GPU",      8, 4, 4, 8ULL << 30, 0xda33d83dU, "RELEASE_ARM64_T8112", "t8112", "iPad Pro (12.9-inch) (6th generation)", "MNXP3", "A2436", YES, 2048, 2732, 2.0, 120, 1008, "applegpu_g14g", 10, "G14G" },
    { "iPad16,6",   "J720AP",  "Apple M4",         "Apple M4 GPU",      9, 3, 6, 8ULL << 30, 0x6f5129acU, "RELEASE_ARM64_T8132", "t8132", "iPad Pro 13-inch (M4)",                 "MVX23", "A2925", YES, 2064, 2752, 2.0, 120, 1009, "applegpu_g16g", 10, "G16G" },
    { "iPad17,3",   "J820AP",  "Apple M5",         "Apple M5 GPU",      9, 3, 6, 12ULL << 30, 0x1d5a87e8U, "RELEASE_ARM64_T8142", "t8142", "iPad Pro 13-inch (M5)",                 "MD8R4", "A3360", YES, 2064, 2752, 2.0, 120, 1010, "applegpu_g18g", 10, "G18G" },
    { "iPhone12,5", "D431AP",  "Apple A13 Bionic", "Apple A13 GPU",     6, 2, 4, 4ULL << 30, 0x573b5eecU, "RELEASE_ARM64_T8030", "t8030", "iPhone 11 Pro Max",                     "MWHD2", "A2161", NO,  1242, 2688, 3.0, 60,  1006, "applegpu_g12p",  4, "G12P" },
    { "iPhone14,3", "D64AP",   "Apple A15 Bionic", "Apple A15 GPU",     6, 2, 4, 6ULL << 30, 0xda33d83dU, "RELEASE_ARM64_T8110", "t8110", "iPhone 13 Pro Max",                     "MLL63", "A2484", NO,  1284, 2778, 3.0, 120, 1008, "applegpu_g14p",  5, "G14P" },
    { "iPhone15,3", "D74AP",   "Apple A16 Bionic", "Apple A16 GPU",     6, 2, 4, 6ULL << 30, 0x8765edeaU, "RELEASE_ARM64_T8120", "t8120", "iPhone 14 Pro Max",                     "MQ8N3", "A2651", NO,  1290, 2796, 3.0, 120, 1008, "applegpu_g15p",  5, "G15P" },
    { "iPhone16,2", "D84AP",   "Apple A17 Pro",    "Apple A17 Pro GPU", 6, 2, 4, 8ULL << 30, 0xfa33415eU, "RELEASE_ARM64_T8130", "t8130", "iPhone 15 Pro Max",                     "MU683", "A2849", NO,  1290, 2796, 3.0, 120, 1009, "applegpu_g16p",  6, "G16P" },
    { "iPhone17,2", "D94AP",   "Apple A18 Pro",    "Apple A18 Pro GPU", 6, 2, 4, 8ULL << 30, 0x75d4acb9U, "RELEASE_ARM64_T8140", "t8140", "iPhone 16 Pro Max",                     "MYWV3", "A3084", NO,  1320, 2868, 3.0, 120, 1009, "applegpu_g17p",  6, "G17P" },
    { "iPhone18,2", "D94xAP",  "Apple A19 Pro",    "Apple A19 Pro GPU", 6, 2, 4, 12ULL << 30, 0xab345f09U, "RELEASE_ARM64_T8150", "t8150", "iPhone 17 Pro Max",                     "MFY84", "A3257", NO,  1320, 2868, 3.0, 120, 1010, "applegpu_g18p",  6, "G18P" },
};

static _Atomic(const pt_device_profile_t *) s_active_device_profile = &s_device_profiles[2];

static const pt_device_profile_t *pt_device_profile_for_model(const char *model) {
    static const size_t kDefaultIPadIdx = 2;    // iPad13,8
    static const size_t kDefaultIPhoneIdx = 10; // iPhone17,2
    if (model != NULL && model[0] != '\0') {
        size_t count = sizeof(s_device_profiles) / sizeof(s_device_profiles[0]);
        for (size_t i = 0; i < count; i++) {
            if (strcmp(model, s_device_profiles[i].model) == 0) {
                return &s_device_profiles[i];
            }
        }
        if (strncmp(model, "iPhone", 6) == 0) {
            return &s_device_profiles[kDefaultIPhoneIdx];
        }
    }
    return &s_device_profiles[kDefaultIPadIdx];
}

__attribute__((visibility("hidden"))) int pt_open_early_settings_plist_fd(void);
static BOOL pt_read_plist_top_bool_from_fd(int fd, const char *key, BOOL *out_val);

__attribute__((visibility("hidden")))
const char *pt_raw_getenv(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return NULL;
    }
    char ***envpp = _NSGetEnviron();
    if (envpp == NULL || !pt_is_valid_user_pointer(envpp)) {
        return NULL;
    }
    char **envp = *envpp;
    if (envp == NULL || !pt_is_valid_user_pointer(envp)) {
        return NULL;
    }
    size_t nlen = strlen(name);
    for (char **ep = envp; pt_is_valid_user_pointer(ep) && *ep != NULL; ep++) {
        const char *entry = *ep;
        if (!pt_is_valid_user_pointer(entry)) {
            continue;
        }
        if (strncmp(entry, name, nlen) == 0 && entry[nlen] == '=') {
            return entry + nlen + 1U;
        }
    }
    return NULL;
}

static BOOL pt_is_safe_mode_env_active(void);

__attribute__((visibility("hidden"))) void pt_init_early_bypass(void) {
    pt_enter_internal_scope();
    const char *dis = pt_raw_getenv("DISABLE_PLAYSHADOW_BYPASS");
    if (dis != NULL && strcmp(dis, "1") == 0) {
        atomic_store_explicit(&s_bypass_enabled, NO, memory_order_relaxed);
        atomic_store_explicit(&s_pt_bypass_inited, YES, memory_order_release);
        PT_DEBUG_TRACE("spoofer", "bypass disabled via DISABLE_PLAYSHADOW_BYPASS=1");
        pt_leave_internal_scope();
        return;
    }
    int fd = pt_open_early_settings_plist_fd();
    if (fd >= 0) {
        BOOL strict_val = NO;
        BOOL has_strict = pt_read_plist_top_bool_from_fd(fd, "strictEmulationMode", &strict_val) && strict_val;
        BOOL safe_mode_active = pt_is_safe_mode_env_active();
        BOOL bypass_val = YES;
        if (!(has_strict && !safe_mode_active) &&
            pt_read_plist_top_bool_from_fd(fd, "bypass", &bypass_val) && !bypass_val) {
            atomic_store_explicit(&s_bypass_enabled, NO, memory_order_relaxed);
        }
        close(fd);
    }
    atomic_store_explicit(&s_pt_bypass_inited, YES, memory_order_release);
    PT_DEBUG_TRACE("spoofer", "early bypass initialized enabled=%d",
                   atomic_load_explicit(&s_bypass_enabled, memory_order_relaxed) ? 1 : 0);
    pt_leave_internal_scope();
}

__attribute__((visibility("hidden")))
BOOL pt_is_bypass_enabled(void) {
    if (atomic_load_explicit(&s_pt_bypass_inited, memory_order_acquire)) {
        return atomic_load_explicit(&s_bypass_enabled, memory_order_relaxed);
    }
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return atomic_load_explicit(&s_bypass_enabled, memory_order_relaxed);
    }
    if (s_tls_bypass_init_depth > 0) {
        return atomic_load_explicit(&s_bypass_enabled, memory_order_relaxed);
    }
    s_tls_bypass_init_depth++;
    pthread_once(&s_pt_bypass_early_once, pt_init_early_bypass);
    s_tls_bypass_init_depth--;
    return atomic_load_explicit(&s_bypass_enabled, memory_order_relaxed);
}


static uint64_t pt_read_be_uint(const uint8_t *p, uint8_t nbytes) {
    uint64_t v = 0;
    for (uint8_t i = 0; i < nbytes; i++) {
        v = (v << 8) | (uint64_t)p[i];
    }
    return v;
}

static BOOL pt_bplist_read_count(const uint8_t *buf,
                                 size_t table_off,
                                 size_t pos,
                                 uint8_t low_nibble,
                                 uint64_t *out_count,
                                 size_t *out_hdr_len) {
    if (pos >= table_off) {
        return NO;
    }
    if (low_nibble < 0x0FU) {
        *out_count = (uint64_t)low_nibble;
        *out_hdr_len = 1;
        return YES;
    }
    if (pos + 2 > table_off) {
        return NO;
    }
    uint8_t int_marker = buf[pos + 1];
    if ((int_marker & 0xF0U) != 0x10U) {
        return NO;
    }
    uint8_t shift = (uint8_t)(int_marker & 0x0FU);
    if (shift > 3U) {
        return NO;
    }
    uint8_t int_bytes = (uint8_t)(1U << shift);
    if (pos + 2 + (size_t)int_bytes > table_off) {
        return NO;
    }
    *out_count = pt_read_be_uint(buf + pos + 2, int_bytes);
    *out_hdr_len = 2 + (size_t)int_bytes;
    return YES;
}

static BOOL pt_bplist_get_obj_offset(const uint8_t *buf,
                                     size_t table_off,
                                     uint8_t offset_int_size,
                                     uint64_t num_objects,
                                     uint64_t obj_idx,
                                     size_t *out_off) {
    if (obj_idx >= num_objects) {
        return NO;
    }
    size_t entry_pos = table_off + (size_t)(obj_idx * (uint64_t)offset_int_size);
    uint64_t raw_off = pt_read_be_uint(buf + entry_pos, offset_int_size);
    if (raw_off < 8ULL || raw_off >= (uint64_t)table_off) {
        return NO;
    }
    *out_off = (size_t)raw_off;
    return YES;
}

static size_t pt_encode_utf8_codepoint(uint32_t cp, char *dst, size_t cap) {
    if (cp <= 0x7FU) {
        if (cap < 1) return 0;
        dst[0] = (char)cp;
        return 1;
    }
    if (cp <= 0x7FFU) {
        if (cap < 2) return 0;
        dst[0] = (char)(0xC0U | (cp >> 6));
        dst[1] = (char)(0x80U | (cp & 0x3FU));
        return 2;
    }
    if (cp <= 0xFFFFU) {
        if (cap < 3) return 0;
        dst[0] = (char)(0xE0U | (cp >> 12));
        dst[1] = (char)(0x80U | ((cp >> 6) & 0x3FU));
        dst[2] = (char)(0x80U | (cp & 0x3FU));
        return 3;
    }
    if (cp <= 0x10FFFFU) {
        if (cap < 4) return 0;
        dst[0] = (char)(0xF0U | (cp >> 18));
        dst[1] = (char)(0x80U | ((cp >> 12) & 0x3FU));
        dst[2] = (char)(0x80U | ((cp >> 6) & 0x3FU));
        dst[3] = (char)(0x80U | (cp & 0x3FU));
        return 4;
    }
    return 0;
}

static BOOL pt_bplist_decode_string_at(const uint8_t *buf,
                                       size_t table_off,
                                       size_t obj_off,
                                       char *out_str,
                                       size_t out_size) {
    if (obj_off >= table_off || out_str == NULL || out_size < 2) {
        return NO;
    }
    uint8_t marker = buf[obj_off];
    uint8_t kind = (uint8_t)(marker & 0xF0U);
    uint64_t count = 0;
    size_t hdr_len = 0;
    if (!pt_bplist_read_count(buf, table_off, obj_off, (uint8_t)(marker & 0x0FU), &count, &hdr_len)) {
        return NO;
    }
    size_t body_pos = obj_off + hdr_len;
    if (kind == 0x50U) {
        if (count > (uint64_t)(table_off - body_pos) || count >= (uint64_t)out_size) {
            return NO;
        }
        memcpy(out_str, buf + body_pos, (size_t)count);
        out_str[count] = '\0';
        return YES;
    }
    if (kind == 0x60U) {
        if (count > (uint64_t)((table_off - body_pos) / 2U)) {
            return NO;
        }
        size_t written = 0;
        for (uint64_t i = 0; i < count; i++) {
            uint16_t u1 = (uint16_t)(((uint16_t)buf[body_pos + (size_t)(i * 2U)] << 8) |
                                     (uint16_t)buf[body_pos + (size_t)(i * 2U) + 1U]);
            uint32_t cp = (uint32_t)u1;
            if (u1 >= 0xD800U && u1 <= 0xDBFFU && (i + 1ULL) < count) {
                uint16_t u2 = (uint16_t)(((uint16_t)buf[body_pos + (size_t)((i + 1ULL) * 2U)] << 8) |
                                         (uint16_t)buf[body_pos + (size_t)((i + 1ULL) * 2U) + 1U]);
                if (u2 >= 0xDC00U && u2 <= 0xDFFFU) {
                    cp = 0x10000U + (((uint32_t)(u1 - 0xD800U) << 10) | (uint32_t)(u2 - 0xDC00U));
                    i++;
                }
            }
            size_t n = pt_encode_utf8_codepoint(cp, out_str + written, (out_size - 1U) - written);
            if (n == 0) {
                return NO;
            }
            written += n;
        }
        out_str[written] = '\0';
        return YES;
    }
    return NO;
}

static BOOL pt_bplist_find_top_value_offset(const uint8_t *buf,
                                            size_t len,
                                            const char *key,
                                            size_t *out_table_off,
                                            size_t *out_val_off) {
    if (buf == NULL || key == NULL || len < 40 || memcmp(buf, "bplist00", 8) != 0) {
        return NO;
    }
    const uint8_t *trailer = buf + (len - 32U);
    uint8_t offset_int_size = trailer[6];
    uint8_t object_ref_size = trailer[7];
    if (offset_int_size < 1U || offset_int_size > 8U ||
        object_ref_size < 1U || object_ref_size > 8U) {
        return NO;
    }
    uint64_t num_objects = pt_read_be_uint(trailer + 8, 8);
    uint64_t top_object = pt_read_be_uint(trailer + 16, 8);
    uint64_t offset_table_offset = pt_read_be_uint(trailer + 24, 8);
    size_t trailer_pos = len - 32U;
    if (num_objects == 0 || num_objects > (1ULL << 20) ||
        top_object >= num_objects ||
        offset_table_offset < 8ULL || offset_table_offset > (uint64_t)trailer_pos) {
        return NO;
    }
    size_t table_off = (size_t)offset_table_offset;
    if (num_objects > (uint64_t)((trailer_pos - table_off) / (size_t)offset_int_size)) {
        return NO;
    }
    size_t top_off = 0;
    if (!pt_bplist_get_obj_offset(buf, table_off, offset_int_size, num_objects, top_object, &top_off)) {
        return NO;
    }
    uint8_t top_marker = buf[top_off];
    if ((top_marker & 0xF0U) != 0xD0U) {
        return NO;
    }
    uint64_t pair_count = 0;
    size_t hdr_len = 0;
    if (!pt_bplist_read_count(buf, table_off, top_off, (uint8_t)(top_marker & 0x0FU), &pair_count, &hdr_len)) {
        return NO;
    }
    size_t refs_pos = top_off + hdr_len;
    size_t two_ref_bytes = 2U * (size_t)object_ref_size;
    if (pair_count > (uint64_t)((table_off - refs_pos) / two_ref_bytes)) {
        return NO;
    }
    for (uint64_t i = 0; i < pair_count; i++) {
        uint64_t key_ref = pt_read_be_uint(buf + refs_pos + (size_t)(i * (uint64_t)object_ref_size), object_ref_size);
        size_t key_off = 0;
        if (!pt_bplist_get_obj_offset(buf, table_off, offset_int_size, num_objects, key_ref, &key_off)) {
            continue;
        }
        char kbuf[256];
        if (!pt_bplist_decode_string_at(buf, table_off, key_off, kbuf, sizeof(kbuf))) {
            continue;
        }
        if (strcmp(kbuf, key) == 0) {
            uint64_t val_ref = pt_read_be_uint(buf + refs_pos + (size_t)((pair_count + i) * (uint64_t)object_ref_size),
                                               object_ref_size);
            size_t val_off = 0;
            if (!pt_bplist_get_obj_offset(buf, table_off, offset_int_size, num_objects, val_ref, &val_off)) {
                return NO;
            }
            *out_table_off = table_off;
            *out_val_off = val_off;
            return YES;
        }
    }
    return NO;
}

static BOOL pt_extract_bplist_top_string(const uint8_t *buf,
                                         size_t len,
                                         const char *key,
                                         char *out_val,
                                         size_t out_size) {
    if (out_val == NULL || out_size < 2) {
        return NO;
    }
    size_t table_off = 0, val_off = 0;
    if (!pt_bplist_find_top_value_offset(buf, len, key, &table_off, &val_off)) {
        return NO;
    }
    return pt_bplist_decode_string_at(buf, table_off, val_off, out_val, out_size);
}

static BOOL pt_extract_bplist_top_bool(const uint8_t *buf,
                                       size_t len,
                                       const char *key,
                                       BOOL *out_val) {
    if (out_val == NULL) {
        return NO;
    }
    size_t table_off = 0, val_off = 0;
    if (!pt_bplist_find_top_value_offset(buf, len, key, &table_off, &val_off) ||
        val_off >= table_off) {
        return NO;
    }
    if (buf[val_off] == 0x09U) {
        *out_val = YES;
        return YES;
    }
    if (buf[val_off] == 0x08U) {
        *out_val = NO;
        return YES;
    }
    return NO;
}

static BOOL pt_decode_xml_text_span(const char *start, const char *end, char *out_str, size_t out_size) {
    if (start == NULL || end == NULL || end < start || out_str == NULL || out_size < 2) {
        return NO;
    }
    size_t w = 0;
    const char *p = start;
    while (p < end) {
        if (strncmp(p, "<![CDATA[", 9) == 0) {
            const char *cd_end = strstr(p + 9, "]]>");
            if (cd_end == NULL || cd_end > end) {
                return NO;
            }
            size_t clen = (size_t)(cd_end - (p + 9));
            if (w + clen >= out_size) {
                return NO;
            }
            memcpy(out_str + w, p + 9, clen);
            w += clen;
            p = cd_end + 3;
            continue;
        }
        if (*p == '&') {
            const char *semi = (const char *)memchr(p + 1, ';', (size_t)(end - (p + 1)));
            if (semi != NULL) {
                size_t elen = (size_t)(semi - (p + 1));
                char repl = '\0';
                BOOL matched_entity = YES;
                if (elen == 3 && strncmp(p + 1, "amp", 3) == 0) repl = '&';
                else if (elen == 2 && strncmp(p + 1, "lt", 2) == 0) repl = '<';
                else if (elen == 2 && strncmp(p + 1, "gt", 2) == 0) repl = '>';
                else if (elen == 4 && strncmp(p + 1, "apos", 4) == 0) repl = '\'';
                else if (elen == 4 && strncmp(p + 1, "quot", 4) == 0) repl = '"';
                else if (elen >= 2 && p[1] == '#') {
                    uint32_t cp = 0;
                    if (p[2] == 'x' || p[2] == 'X') {
                        for (const char *h = p + 3; h < semi; h++) {
                            uint32_t d = 0;
                            if (*h >= '0' && *h <= '9') d = (uint32_t)(*h - '0');
                            else if (*h >= 'a' && *h <= 'f') d = (uint32_t)(*h - 'a' + 10);
                            else if (*h >= 'A' && *h <= 'F') d = (uint32_t)(*h - 'A' + 10);
                            else { matched_entity = NO; break; }
                            cp = (cp << 4) | d;
                        }
                    } else {
                        for (const char *dch = p + 2; dch < semi; dch++) {
                            if (*dch < '0' || *dch > '9') { matched_entity = NO; break; }
                            cp = cp * 10U + (uint32_t)(*dch - '0');
                        }
                    }
                    if (matched_entity && cp > 0) {
                        size_t n = pt_encode_utf8_codepoint(cp, out_str + w, (out_size - 1U) - w);
                        if (n == 0) return NO;
                        w += n;
                        p = semi + 1;
                        continue;
                    }
                    matched_entity = NO;
                } else {
                    matched_entity = NO;
                }
                if (matched_entity) {
                    if (w + 1 >= out_size) return NO;
                    out_str[w++] = repl;
                    p = semi + 1;
                    continue;
                }
            }
        }
        if (w + 1 >= out_size) {
            return NO;
        }
        out_str[w++] = *p++;
    }
    out_str[w] = '\0';
    return YES;
}

static BOOL pt_is_xml_tag_delim(char c) {
    return (c == '>' || c == '/' || c == ' ' || c == '\t' || c == '\r' || c == '\n');
}

static BOOL pt_xml_plist_find_top_value_tag(const char *xml,
                                            size_t len,
                                            const char *key,
                                            const char **out_tname,
                                            size_t *out_rem,
                                            const char **out_gt,
                                            BOOL *out_is_self_closing,
                                            const char **out_end) {
    if (xml == NULL || key == NULL || len == 0) {
        return NO;
    }
    const char *end = xml + len;
    const char *p = xml;
    int dict_depth = 0;
    int array_depth = 0;
    BOOL expect_target_value = NO;

    while (p < end) {
        const char *lt = (const char *)memchr(p, '<', (size_t)(end - p));
        if (lt == NULL || (lt + 1) >= end) {
            break;
        }
        if (lt + 4 <= end && strncmp(lt, "<!--", 4) == 0) {
            const char *cend = strstr(lt + 4, "-->");
            if (cend == NULL) break;
            p = cend + 3;
            continue;
        }
        if (lt + 9 <= end && strncmp(lt, "<![CDATA[", 9) == 0) {
            const char *cend = strstr(lt + 9, "]]>");
            if (cend == NULL) break;
            p = cend + 3;
            continue;
        }
        if (lt[1] == '?' || lt[1] == '!') {
            const char *gt = (const char *)memchr(lt + 2, '>', (size_t)(end - (lt + 2)));
            if (gt == NULL) break;
            p = gt + 1;
            continue;
        }
        const char *gt = (const char *)memchr(lt + 1, '>', (size_t)(end - (lt + 1)));
        if (gt == NULL) {
            break;
        }
        BOOL is_closing = (lt[1] == '/');
        BOOL is_self_closing = (!is_closing && gt > lt + 1 && gt[-1] == '/');
        const char *tname = is_closing ? (lt + 2) : (lt + 1);
        size_t rem = (size_t)(gt - tname);

        if (expect_target_value && dict_depth == 1 && array_depth == 0) {
            if (is_closing) {
                return NO;
            }
            *out_tname = tname;
            *out_rem = rem;
            *out_gt = gt;
            *out_is_self_closing = is_self_closing;
            *out_end = end;
            return YES;
        }

        if (!is_closing) {
            if (rem >= 4 && strncmp(tname, "dict", 4) == 0 && pt_is_xml_tag_delim(tname[4])) {
                if (!is_self_closing) dict_depth++;
                p = gt + 1;
                continue;
            }
            if (rem >= 5 && strncmp(tname, "array", 5) == 0 && pt_is_xml_tag_delim(tname[5])) {
                if (!is_self_closing) array_depth++;
                p = gt + 1;
                continue;
            }
            if (dict_depth == 1 && array_depth == 0 &&
                rem >= 3 && strncmp(tname, "key", 3) == 0 && pt_is_xml_tag_delim(tname[3])) {
                if (is_self_closing) {
                    p = gt + 1;
                    continue;
                }
                const char *kstart = gt + 1;
                const char *kend = strstr(kstart, "</key>");
                if (kend == NULL || kend > end) {
                    return NO;
                }
                char decoded_key[256];
                if (pt_decode_xml_text_span(kstart, kend, decoded_key, sizeof(decoded_key)) &&
                    strcmp(decoded_key, key) == 0) {
                    expect_target_value = YES;
                }
                p = kend + 6;
                continue;
            }
        } else {
            if (rem >= 4 && strncmp(tname, "dict", 4) == 0 && pt_is_xml_tag_delim(tname[4])) {
                if (dict_depth > 0) dict_depth--;
                p = gt + 1;
                continue;
            }
            if (rem >= 5 && strncmp(tname, "array", 5) == 0 && pt_is_xml_tag_delim(tname[5])) {
                if (array_depth > 0) array_depth--;
                p = gt + 1;
                continue;
            }
        }
        p = gt + 1;
    }
    return NO;
}

static BOOL pt_extract_xml_plist_top_string(const char *xml,
                                            size_t len,
                                            const char *key,
                                            char *out_val,
                                            size_t out_size) {
    if (out_val == NULL || out_size < 2) {
        return NO;
    }
    const char *tname = NULL, *gt = NULL, *end = NULL;
    size_t rem = 0;
    BOOL is_self_closing = NO;
    if (!pt_xml_plist_find_top_value_tag(xml, len, key, &tname, &rem, &gt, &is_self_closing, &end)) {
        return NO;
    }
    if (rem >= 6 && strncmp(tname, "string", 6) == 0 && pt_is_xml_tag_delim(tname[6])) {
        if (is_self_closing) {
            out_val[0] = '\0';
            return YES;
        }
        const char *val_start = gt + 1;
        const char *val_end = strstr(val_start, "</string>");
        if (val_end == NULL || val_end > end) {
            return NO;
        }
        return pt_decode_xml_text_span(val_start, val_end, out_val, out_size);
    }
    return NO;
}

static BOOL pt_extract_xml_plist_top_bool(const char *xml,
                                          size_t len,
                                          const char *key,
                                          BOOL *out_val) {
    if (out_val == NULL) {
        return NO;
    }
    const char *tname = NULL, *gt = NULL, *end = NULL;
    size_t rem = 0;
    BOOL is_self_closing = NO;
    if (!pt_xml_plist_find_top_value_tag(xml, len, key, &tname, &rem, &gt, &is_self_closing, &end)) {
        return NO;
    }
    if (rem >= 4 && strncmp(tname, "true", 4) == 0 && pt_is_xml_tag_delim(tname[4])) {
        *out_val = YES;
        return YES;
    }
    if (rem >= 5 && strncmp(tname, "false", 5) == 0 && pt_is_xml_tag_delim(tname[5])) {
        *out_val = NO;
        return YES;
    }
    return NO;
}

__attribute__((used, noinline, constructor(101)))
static void pt_mark_libsystem_ready_ctor(void) {
    atomic_store_explicit(&s_libsystem_ready, true, memory_order_release);
    pt_debug_trace_mark_ready();
    pt_init_user_va_bits_from_kernel();
}

__attribute__((visibility("hidden"))) uint8_t *pt_read_fd_plist_bytes(int fd, size_t *out_len, size_t *out_map_size) {
    if (fd < 0 || out_len == NULL || out_map_size == NULL) {
        return NULL;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0 || st.st_size > (8 * 1024 * 1024)) {
        return NULL;
    }
    (void)lseek(fd, 0, SEEK_SET);
    size_t file_size = (size_t)st.st_size;
    size_t page_size = (size_t)getpagesize();
    if (page_size == 0) {
        page_size = 4096U;
    }
    size_t req_size = file_size + 1U;
    size_t map_size = (req_size + page_size - 1U) & ~(page_size - 1U);
    void *mapped = mmap(NULL, map_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (mapped == MAP_FAILED) {
        return NULL;
    }
    uint8_t *buf = (uint8_t *)mapped;
    size_t total = 0;
    while (total < file_size) {
        ssize_t nr = read(fd, buf + total, file_size - total);
        if (nr < 0) {
            if (errno == EINTR) continue;
            munmap(buf, map_size);
            return NULL;
        }
        if (nr == 0) {
            break;
        }
        total += (size_t)nr;
    }
    buf[total] = 0;
    *out_len = total;
    *out_map_size = map_size;
    return buf;
}

__attribute__((visibility("hidden"))) BOOL pt_read_plist_top_string_from_fd(int fd, const char *key, char *out_val, size_t out_size) {
    if (key == NULL || out_val == NULL || out_size < 2) {
        return NO;
    }
    size_t total = 0;
    size_t map_size = 0;
    uint8_t *buf = pt_read_fd_plist_bytes(fd, &total, &map_size);
    if (buf == NULL) {
        return NO;
    }
    BOOL ok = NO;
    if (total >= 40U && memcmp(buf, "bplist00", 8) == 0) {
        ok = pt_extract_bplist_top_string(buf, total, key, out_val, out_size);
    } else if (total > 0) {
        ok = pt_extract_xml_plist_top_string((const char *)buf, total, key, out_val, out_size);
    }
    munmap(buf, map_size);
    return ok;
}

static BOOL pt_read_plist_top_bool_from_fd(int fd, const char *key, BOOL *out_val) {
    if (key == NULL || out_val == NULL) {
        return NO;
    }
    size_t total = 0;
    size_t map_size = 0;
    uint8_t *buf = pt_read_fd_plist_bytes(fd, &total, &map_size);
    if (buf == NULL) {
        return NO;
    }
    BOOL ok = NO;
    if (total >= 40U && memcmp(buf, "bplist00", 8) == 0) {
        ok = pt_extract_bplist_top_bool(buf, total, key, out_val);
    } else if (total > 0) {
        ok = pt_extract_xml_plist_top_bool((const char *)buf, total, key, out_val);
    }
    munmap(buf, map_size);
    return ok;
}

static char s_cached_host_user_root[256];
static pthread_once_t s_pt_host_user_root_once = PTHREAD_ONCE_INIT;

static BOOL pt_extract_host_user_root_from_env_val(const char *env_val, char *out_buf, size_t out_size) {
    if (env_val == NULL || env_val[0] != '/') {
        return NO;
    }
    const char *home = env_val;
    if (strncmp(home, "/System/Volumes/Data/", 21) == 0) {
        home += 20;
    }
    const char *containers_marker = strstr(home, "/Library/Containers/");
    if (containers_marker != NULL && containers_marker > home) {
        size_t len = (size_t)(containers_marker - home);
        if (len < out_size) {
            memcpy(out_buf, home, len);
            out_buf[len] = '\0';
            return YES;
        }
    }
    if (strncmp(home, "/Users/", 7) == 0) {
        const char *slash = strchr(home + 7, '/');
        size_t len = (slash != NULL) ? (size_t)(slash - home) : strlen(home);
        if (len > 7 && len < out_size) {
            memcpy(out_buf, home, len);
            out_buf[len] = '\0';
            return YES;
        }
    }
    return NO;
}

static void pt_init_host_user_root(void) {
    if (pt_extract_host_user_root_from_env_val(pt_raw_getenv("HOME"), s_cached_host_user_root, sizeof(s_cached_host_user_root))) {
        return;
    }
    if (pt_extract_host_user_root_from_env_val(pt_raw_getenv("CFFIXED_USER_HOME"), s_cached_host_user_root, sizeof(s_cached_host_user_root))) {
        return;
    }
    if (atomic_load_explicit(&s_libsystem_ready, memory_order_acquire) &&
        s_tls_bypass_init_depth == 0 &&
        s_tls_early_device_init == 0) {
        struct passwd *pw = getpwuid(getuid());
        if (pw != NULL && pw->pw_dir != NULL && pw->pw_dir[0] == '/') {
            strlcpy(s_cached_host_user_root, pw->pw_dir, sizeof(s_cached_host_user_root));
        }
    }
}

__attribute__((visibility("hidden")))
const char *pt_get_host_user_root_cstr(void) {
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return NULL;
    }
    if (s_tls_bypass_init_depth > 0 || s_tls_early_device_init > 0) {
        if (s_cached_host_user_root[0] != '\0') {
            return s_cached_host_user_root;
        }
        // Compute directly into stack or return without calling getpwuid inside early pthread_once
        static _Thread_local char tls_early_root[256];
        if (pt_extract_host_user_root_from_env_val(pt_raw_getenv("HOME"), tls_early_root, sizeof(tls_early_root)) ||
            pt_extract_host_user_root_from_env_val(pt_raw_getenv("CFFIXED_USER_HOME"), tls_early_root, sizeof(tls_early_root))) {
            return tls_early_root;
        }
        return NULL;
    }
    pthread_once(&s_pt_host_user_root_once, pt_init_host_user_root);
    return (s_cached_host_user_root[0] != '\0') ? s_cached_host_user_root : NULL;
}

__attribute__((visibility("hidden"))) const char *pt_get_main_executable_path(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header *mh = _dyld_get_image_header(i);
        if (mh != NULL && mh->filetype == MH_EXECUTE) {
            return _dyld_get_image_name(i);
        }
    }
    return _dyld_get_image_name(0);
}

__attribute__((visibility("hidden"))) const struct mach_header *pt_get_main_executable_header(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header *mh = _dyld_get_image_header(i);
        if (mh != NULL && mh->filetype == MH_EXECUTE) {
            return mh;
        }
    }
    return _dyld_get_image_header(0);
}

__attribute__((visibility("hidden"))) BOOL pt_read_main_bundle_id_early(char *out_bid, size_t out_size) {
    const char *exec_path = pt_get_main_executable_path();
    const char *app_ext = (exec_path != NULL) ? strstr(exec_path, ".app/") : NULL;
    if (app_ext == NULL) {
        return NO;
    }
    char info_path[PATH_MAX];
    size_t bundle_len = (size_t)(app_ext + 4 - exec_path);
    if (bundle_len >= sizeof(info_path) - 32) {
        return NO;
    }
    int n = snprintf(info_path, sizeof(info_path), "%.*s/Contents/Info.plist",
                     (int)bundle_len, exec_path);
    int fd = (n > 0 && (size_t)n < sizeof(info_path)) ? pt_orig_open_nocancel(info_path, O_RDONLY) : -1;
    if (fd < 0) {
        n = snprintf(info_path, sizeof(info_path), "%.*s/Info.plist",
                     (int)bundle_len, exec_path);
        if (n > 0 && (size_t)n < sizeof(info_path)) {
            fd = pt_orig_open_nocancel(info_path, O_RDONLY);
        }
    }
    if (fd < 0) {
        return NO;
    }
    BOOL ok = pt_read_plist_top_string_from_fd(fd, "CFBundleIdentifier", out_bid, out_size);
    close(fd);
    return ok;
}

__attribute__((visibility("hidden"))) int pt_open_early_settings_plist_fd(void) {
    int fd = -1;
    char plist_path[PATH_MAX];
    plist_path[0] = '\0';

    const char *override_plist = pt_raw_getenv("PLAYTOOLS_SETTINGS_PLIST");
    if (override_plist != NULL && override_plist[0] == '/') {
        return pt_orig_open_nocancel(override_plist, O_RDONLY);
    }
    const char *user_root = pt_get_host_user_root_cstr();
    if (user_root != NULL) {
        char bid[256];
        if (pt_read_main_bundle_id_early(bid, sizeof(bid)) && bid[0] != '\0') {
            snprintf(plist_path, sizeof(plist_path),
                     "%s/Library/Containers/app.makedie.MacOver/App Settings/%s.plist",
                     user_root, bid);
            fd = pt_orig_open_nocancel(plist_path, O_RDONLY);
        }
        if (fd < 0) {
            const char *home = pt_raw_getenv("CFFIXED_USER_HOME");
            const char *containers_marker = (home != NULL) ? strstr(home, "/Library/Containers/") : NULL;
            if (containers_marker != NULL) {
                const char *cid_start = containers_marker + 20;
                const char *cid_end = strchr(cid_start, '/');
                size_t cid_len = (cid_end != NULL) ? (size_t)(cid_end - cid_start) : strlen(cid_start);
                if (cid_len > 0 && cid_len < 256) {
                    snprintf(plist_path, sizeof(plist_path),
                             "%s/Library/Containers/app.makedie.MacOver/App Settings/%.*s.plist",
                             user_root, (int)cid_len, cid_start);
                    fd = pt_orig_open_nocancel(plist_path, O_RDONLY);
                }
            }
        }
    }
    return fd;
}

static const pt_device_profile_t *pt_set_cached_device_profile_from_model(const char *model,
                                                                         char *out_model,
                                                                         size_t out_model_size,
                                                                         char *out_oem,
                                                                         size_t out_oem_size) {
    const pt_device_profile_t *profile = pt_device_profile_for_model(model);
    strlcpy(out_model, profile->model, out_model_size);
    strlcpy(out_oem, profile->oem_id, out_oem_size);
    return profile;
}

static BOOL pt_is_safe_mode_env_active(void);

static void pt_copy_trimmed_ascii(const char *src, char *dst, size_t dst_size) {
    if (dst == NULL || dst_size == 0) {
        return;
    }
    dst[0] = '\0';
    if (src == NULL) {
        return;
    }
    while (*src == ' ' || *src == '\t' || *src == '\n' || *src == '\r') {
        src++;
    }
    size_t len = strlen(src);
    while (len > 0 && (src[len - 1] == ' ' || src[len - 1] == '\t' ||
                       src[len - 1] == '\n' || src[len - 1] == '\r')) {
        len--;
    }
    if (len == 0) {
        return;
    }
    if (len >= dst_size) {
        len = dst_size - 1;
    }
    memcpy(dst, src, len);
    dst[len] = '\0';
}

static int pt_parse_reported_ios_override_mode_cstr(const char *raw_mode) {
    char trimmed[32];
    pt_copy_trimmed_ascii(raw_mode, trimmed, sizeof(trimmed));
    if (trimmed[0] == '\0') {
        return 0; // PT_REPORTED_IOS_OVERRIDE_NONE
    }
    if (strcasecmp(trimmed, "compat18_3") == 0 ||
        strcmp(trimmed, "18.3") == 0 ||
        strcasecmp(trimmed, "ios18_3") == 0) {
        return 1; // PT_REPORTED_IOS_OVERRIDE_18_3
    }
    if (strcasecmp(trimmed, "compat13_7") == 0 ||
        strcmp(trimmed, "13.7") == 0 ||
        strcasecmp(trimmed, "ios13_7") == 0) {
        return 2; // PT_REPORTED_IOS_OVERRIDE_13_7
    }
    return 0;
}

static BOOL pt_is_compat13_7_mode_cstr(const char *rep_mode) {
    return pt_parse_reported_ios_override_mode_cstr(rep_mode) == 2;
}

static const char *pt_coerce_model_for_compat13_7(const char *model) {
    if (model != NULL &&
        (strcmp(model, "iPad6,7") == 0 ||
         strcmp(model, "iPad8,6") == 0 ||
         strcmp(model, "iPhone12,5") == 0)) {
        return model;
    }
    if (model != NULL && strncmp(model, "iPhone", 6) == 0) {
        return "iPhone12,5";
    }
    return "iPad8,6";
}

static void pt_init_early_device_info(void) {
    int fd = pt_open_early_settings_plist_fd();
    if (fd >= 0) {
        char raw_model[64] = {0};
        char parsed_model[64] = {0};
        if (pt_read_plist_top_string_from_fd(fd, "iosDeviceModel", raw_model, sizeof(raw_model))) {
            pt_copy_trimmed_ascii(raw_model, parsed_model, sizeof(parsed_model));
        }
        BOOL has_model = (parsed_model[0] != '\0');
        const char *base_model = has_model ? parsed_model : "iPad13,8";
        strlcpy(s_uncoerced_device_model, base_model, sizeof(s_uncoerced_device_model));
        atomic_store_explicit(&s_has_uncoerced_device_model, YES, memory_order_release);

        char rep_mode[32] = {0};
        BOOL is_compat13 = (!atomic_load_explicit(&s_reported_ios_override_forced_off, memory_order_acquire) &&
                            !pt_is_safe_mode_env_active() &&
                            pt_read_plist_top_string_from_fd(fd, "reportedIOSVersion", rep_mode, sizeof(rep_mode)) &&
                            pt_is_compat13_7_mode_cstr(rep_mode));
        const char *effective_model = is_compat13 ? pt_coerce_model_for_compat13_7(base_model) : base_model;
        if (has_model || is_compat13) {
            const pt_device_profile_t *profile = pt_set_cached_device_profile_from_model(
                effective_model,
                s_early_device_model, sizeof(s_early_device_model),
                s_early_oem_id, sizeof(s_early_oem_id));
            atomic_store_explicit(&s_active_device_profile, profile, memory_order_release);
            atomic_store_explicit(&s_active_device_model, profile->model, memory_order_release);
            atomic_store_explicit(&s_active_oem_id, profile->oem_id, memory_order_release);
        }
        close(fd);
    }
}

__attribute__((visibility("hidden"))) void pt_init_device_info(void) {
    pt_enter_internal_scope();
    if (s_tls_early_device_init == 0) {
        s_tls_early_device_init++;
        pthread_once(&s_pt_early_device_once, pt_init_early_device_info);
        s_tls_early_device_init--;
    }
    strlcpy(s_final_device_model, s_early_device_model, sizeof(s_final_device_model));
    strlcpy(s_final_oem_id, s_early_oem_id, sizeof(s_final_oem_id));
    const pt_device_profile_t *final_profile = pt_device_profile_for_model(s_final_device_model);
    const char *published_model = final_profile->model;
    const char *published_oem = final_profile->oem_id;
    BOOL prev_tls = s_tls_initializing_device_info;
    s_tls_initializing_device_info = YES;
    @autoreleasepool {
        PlaySettings *ps = [PlaySettings shared];
        NSString *rawCfg = [ps rawConfiguredDeviceModel];
        const char *rm = [rawCfg UTF8String];
        if (rm != NULL && rm[0] != '\0') {
            pt_copy_trimmed_ascii(rm, s_uncoerced_device_model, sizeof(s_uncoerced_device_model));
            if (s_uncoerced_device_model[0] != '\0') {
                atomic_store_explicit(&s_has_uncoerced_device_model, YES, memory_order_release);
            }
        }
        NSString *model = [ps deviceModel];
        const char *m = [model UTF8String];
        if (m != NULL && m[0] != '\0') {
            const char *eff_m = m;
            if ((atomic_load_explicit(&s_reported_ios_override_forced_off, memory_order_acquire) ||
                 pt_is_safe_mode_env_active()) &&
                atomic_load_explicit(&s_has_uncoerced_device_model, memory_order_acquire) &&
                s_uncoerced_device_model[0] != '\0') {
                eff_m = s_uncoerced_device_model;
            }
            final_profile = pt_set_cached_device_profile_from_model(
                eff_m,
                s_final_device_model, sizeof(s_final_device_model),
                s_final_oem_id, sizeof(s_final_oem_id));
            published_model = final_profile->model;
            published_oem = final_profile->oem_id;
        } else {
            NSString *oem = [ps oemID];
            const char *o = [oem UTF8String];
            if (o != NULL && o[0] != '\0') {
                strlcpy(s_final_oem_id, o, sizeof(s_final_oem_id));
                published_oem = s_final_oem_id;
            }
        }
    }
    s_tls_initializing_device_info = prev_tls;
    atomic_store_explicit(&s_active_device_profile, final_profile, memory_order_release);
    atomic_store_explicit(&s_active_device_model, published_model, memory_order_release);
    atomic_store_explicit(&s_active_oem_id, published_oem, memory_order_release);
    atomic_store_explicit(&s_pt_device_info_ready, YES, memory_order_release);
    pt_leave_internal_scope();
}

__attribute__((visibility("hidden"))) void pt_ensure_early_device_info_safe(void) {
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire) || s_tls_early_device_init > 0) {
        return;
    }
    s_tls_early_device_init++;
    pthread_once(&s_pt_early_device_once, pt_init_early_device_info);
    s_tls_early_device_init--;
}

static const char *pt_get_device_model(void) {
    if (atomic_load_explicit(&s_pt_device_info_ready, memory_order_acquire) ||
        !atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return atomic_load_explicit(&s_active_device_model, memory_order_acquire);
    }
    pt_ensure_early_device_info_safe();
    if (!atomic_load_explicit(&s_pt_loaded, memory_order_acquire) || s_tls_initializing_device_info) {
        return atomic_load_explicit(&s_active_device_model, memory_order_acquire);
    }
    pthread_once(&s_pt_device_info_once, pt_init_device_info);
    return atomic_load_explicit(&s_active_device_model, memory_order_acquire);
}

static const char *pt_get_oem_id(void) {
    if (atomic_load_explicit(&s_pt_device_info_ready, memory_order_acquire) ||
        !atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return atomic_load_explicit(&s_active_oem_id, memory_order_acquire);
    }
    pt_ensure_early_device_info_safe();
    if (!atomic_load_explicit(&s_pt_loaded, memory_order_acquire) || s_tls_initializing_device_info) {
        return atomic_load_explicit(&s_active_oem_id, memory_order_acquire);
    }
    pthread_once(&s_pt_device_info_once, pt_init_device_info);
    return atomic_load_explicit(&s_active_oem_id, memory_order_acquire);
}

static inline const char *pt_get_model_cstr(void) {
    return pt_get_device_model();
}

static inline const pt_device_profile_t *pt_get_active_device_profile(void) {
    if (atomic_load_explicit(&s_pt_device_info_ready, memory_order_acquire) ||
        !atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return atomic_load_explicit(&s_active_device_profile, memory_order_acquire);
    }
    (void)pt_get_device_model();
    return atomic_load_explicit(&s_active_device_profile, memory_order_acquire);
}

__attribute__((visibility("hidden")))
const char *pt_get_device_model_cstr(void) {
    return pt_get_device_model();
}

__attribute__((visibility("hidden")))
const char *pt_get_oem_id_cstr(void) {
    return pt_get_oem_id();
}

__attribute__((visibility("hidden")))
uint32_t pt_get_spoofed_cpu_cores(void) {
    return pt_get_active_device_profile()->cores;
}

__attribute__((visibility("hidden")))
uint64_t pt_get_spoofed_physical_memory(void) {
    return pt_get_active_device_profile()->ram_bytes;
}

__attribute__((visibility("hidden")))
const char *pt_get_spoofed_gpu_name_cstr(void) {
    return pt_get_active_device_profile()->gpu_name;
}

__attribute__((visibility("hidden")))
int32_t pt_get_spoofed_max_apple_gpu_family(void) {
    int32_t fam = pt_get_active_device_profile()->max_apple_gpu_family;
    return (fam > 0) ? fam : 1007;
}

__attribute__((visibility("hidden")))
const char *pt_get_spoofed_gpu_arch_cstr(void) {
    const char *arch = pt_get_active_device_profile()->gpu_arch;
    return (arch != NULL && arch[0] != '\0') ? arch : "applegpu_g13g";
}

__attribute__((visibility("hidden")))
BOOL pt_get_spoofed_device_is_ipad(void) {
    return pt_get_active_device_profile()->is_ipad;
}

__attribute__((visibility("hidden")))
void pt_get_spoofed_screen_native_bounds(double *out_portrait_width,
                                         double *out_portrait_height,
                                         double *out_native_scale) {
    const pt_device_profile_t *profile = pt_get_active_device_profile();
    if (out_portrait_width != NULL) {
        *out_portrait_width = (double)profile->native_width;
    }
    if (out_portrait_height != NULL) {
        *out_portrait_height = (double)profile->native_height;
    }
    if (out_native_scale != NULL) {
        *out_native_scale = profile->native_scale;
    }
}

__attribute__((visibility("hidden")))
double pt_get_device_native_scale(void) {
    return pt_get_active_device_profile()->native_scale;
}

__attribute__((visibility("hidden")))
uint32_t pt_get_device_native_width(void) {
    return pt_get_active_device_profile()->native_width;
}

__attribute__((visibility("hidden")))
uint32_t pt_get_device_native_height(void) {
    return pt_get_active_device_profile()->native_height;
}

__attribute__((visibility("hidden")))
uint32_t pt_get_device_max_fps(void) {
    uint32_t fps = pt_get_active_device_profile()->max_fps;
    return (fps > 0U) ? fps : 60U;
}



static int pt_write_sysctl_string(const char *value, void *oldp, size_t *oldlenp) {
    if (value == NULL) {
        value = "";
    }
    size_t requiredSize = strlen(value) + 1;
    if (oldp == NULL) {
        if (oldlenp != NULL) {
            *oldlenp = requiredSize;
        }
        return 0;
    }
    if (oldlenp == NULL || *oldlenp < requiredSize) {
        if (oldlenp != NULL) {
            *oldlenp = requiredSize;
        }
        errno = ENOMEM;
        return -1;
    }
    memcpy(oldp, value, requiredSize);
    *oldlenp = requiredSize;
    return 0;
}

static int pt_write_sysctl_int(int value, void *oldp, size_t *oldlenp) {
    size_t requiredSize = sizeof(int);
    if (oldp == NULL) {
        if (oldlenp != NULL) {
            *oldlenp = requiredSize;
        }
        return 0;
    }
    if (oldlenp == NULL || *oldlenp < requiredSize) {
        if (oldlenp != NULL) {
            *oldlenp = requiredSize;
        }
        errno = ENOMEM;
        return -1;
    }
    memcpy(oldp, &value, requiredSize);
    *oldlenp = requiredSize;
    return 0;
}

static int pt_write_sysctl_uint64(void *oldp, size_t *oldlenp, void *newp, uint64_t val) {
    if (newp != NULL) {
        errno = EPERM;
        return -1;
    }
    if (oldp == NULL) {
        if (oldlenp != NULL) {
            *oldlenp = sizeof(uint64_t);
        }
        return 0;
    }
    if (oldlenp == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (*oldlenp == sizeof(uint32_t)) {
        uint32_t v32 = (val > 0x80000000ULL) ? 0x80000000U : (uint32_t)val;
        memcpy(oldp, &v32, sizeof(uint32_t));
        *oldlenp = sizeof(uint32_t);
        return 0;
    }
    if (*oldlenp < sizeof(uint64_t)) {
        *oldlenp = sizeof(uint64_t);
        errno = ENOMEM;
        return -1;
    }
    memcpy(oldp, &val, sizeof(uint64_t));
    *oldlenp = sizeof(uint64_t);
    return 0;
}

static int pt_write_sysctl_uint64_array(void *oldp,
                                        size_t *oldlenp,
                                        void *newp,
                                        const uint64_t *vals,
                                        size_t count) {
    if (newp != NULL) {
        errno = EPERM;
        return -1;
    }
    size_t required = count * sizeof(uint64_t);
    if (oldp == NULL) {
        if (oldlenp != NULL) {
            *oldlenp = required;
        }
        return 0;
    }
    if (oldlenp == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (*oldlenp < required) {
        *oldlenp = required;
        errno = ENOMEM;
        return -1;
    }
    memcpy(oldp, vals, required);
    *oldlenp = required;
    return 0;
}


static CFDataRef pt_create_compatible_cfdata(CFAllocatorRef allocator) {
    const char *oem = OEM_ID;
    const char *model = DEVICE_MODEL;
    if (oem == NULL) oem = "J522AP";
    if (model == NULL) model = "iPad13,8";
    char buf[256];
    size_t oem_len = strlen(oem) + 1;
    size_t model_len = strlen(model) + 1;
    const char *arm = "AppleARM";
    size_t arm_len = strlen(arm) + 1;
    if (oem_len + model_len + arm_len > sizeof(buf)) {
        return CFDataCreate(allocator, (const UInt8 *)model, (CFIndex)model_len);
    }
    memcpy(buf, oem, oem_len);
    memcpy(buf + oem_len, model, model_len);
    memcpy(buf + oem_len + model_len, arm, arm_len);
    return CFDataCreate(allocator, (const UInt8 *)buf, (CFIndex)(oem_len + model_len + arm_len));
}


typedef enum {
    PT_REPORTED_IOS_OVERRIDE_NONE = 0,
    PT_REPORTED_IOS_OVERRIDE_18_3 = 1,
    PT_REPORTED_IOS_OVERRIDE_13_7 = 2
} pt_reported_ios_override_t;

static char s_real_kern_release[64] = "24.3.0";
static char s_spoofed_kern_version_prefix[256] = "Darwin Kernel Version 24.3.0: Sat Jan 11 02:18:34 PST 2025; root:xnu-11215.82.3~1";
static char s_compat18_kern_version_prefix[256] = "Darwin Kernel Version 24.3.0: Sat Jan 11 02:18:34 PST 2025; root:xnu-11215.61.2~1";
static char s_compat13_kern_version_prefix[256] = "Darwin Kernel Version 19.6.0: Mon Jul  6 21:14:08 PDT 2020; root:xnu-6153.121.2~1";
static char s_spoofed_osversion[64] = "22D63";
static char s_spoofed_ios_version[32] = "18.3";
static _Atomic int s_reported_ios_override_mode = PT_REPORTED_IOS_OVERRIDE_NONE;
static pthread_once_t s_host_kern_once = PTHREAD_ONCE_INIT;

static BOOL pt_is_safe_mode_env_active(void) {
    const char *raw = pt_raw_getenv("PLAYTOOLS_SAFE_MODE");
    if (raw == NULL) {
        return NO;
    }
    while (*raw == ' ' || *raw == '\t' || *raw == '\n' || *raw == '\r') {
        raw++;
    }
    if (raw[0] == '\0') {
        return NO;
    }
    char buf[8] = {0};
    size_t len = 0;
    while (raw[len] != '\0' && raw[len] != ' ' && raw[len] != '\t' &&
           raw[len] != '\n' && raw[len] != '\r' && len < sizeof(buf) - 1) {
        char c = raw[len];
        buf[len] = (c >= 'A' && c <= 'Z') ? (char)(c + ('a' - 'A')) : c;
        len++;
    }
    while (raw[len] == ' ' || raw[len] == '\t' || raw[len] == '\n' || raw[len] == '\r') {
        len++;
    }
    if (raw[len] != '\0') {
        return NO;
    }
    return strcmp(buf, "1") == 0 || strcmp(buf, "true") == 0 || strcmp(buf, "yes") == 0;
}

static void pt_synthesize_ios_kernel_version_prefix(const char *release_str, char *out_buf, size_t out_size) {
    int major = 24, minor = 3, patch = 0;
    int parsed = (release_str != NULL) ? sscanf(release_str, "%d.%d.%d", &major, &minor, &patch) : 0;
    const char *eff_release = (parsed >= 1 && major >= 18) ? release_str : "24.3.0";
    if (parsed < 1 || major < 18) {
        major = 24;
        minor = 3;
        patch = 0;
    } else {
        if (parsed < 2 || minor < 0) minor = 0;
        if (parsed < 3 || patch < 0) patch = 0;
    }

    int xnu_maj = 11215;
    switch (major) {
        case 18: xnu_maj = 4903; break;
        case 19: xnu_maj = 6153; break;
        case 20: xnu_maj = 7195; break;
        case 21: xnu_maj = (minor > 1) ? 8020 : 8019; break;
        case 22: xnu_maj = (minor >= 4) ? 8796 : 8792; break;
        case 23: xnu_maj = (minor >= 4) ? 10063 : 10002; break;
        case 24: xnu_maj = (minor >= 4) ? 11417 : 11215; break;
        case 25: xnu_maj = 12377; break;
        case 26: xnu_maj = 12900; break;
        case 27: xnu_maj = 13432; break;
        default:
            xnu_maj = (major > 27) ? (13432 + (major - 27) * 900) : 4903;
            break;
    }
    int xnu_min = (minor == 0) ? 1 : (minor * 20 + 1);
    int xnu_pat = (patch % 10) + 2;

    int base_year = (major >= 27) ? (1999 + major) : (2000 + major);
    int cal_year;
    int cal_month;
    const char *tz_str;
    switch (minor) {
        case 0: cal_month = 9;  cal_year = base_year;     tz_str = "PDT"; break;
        case 1: cal_month = 10; cal_year = base_year;     tz_str = "PDT"; break;
        case 2: cal_month = 11; cal_year = base_year;     tz_str = "PST"; break;
        case 3: cal_month = 1;  cal_year = base_year + 1; tz_str = "PST"; break;
        case 4: cal_month = 3;  cal_year = base_year + 1; tz_str = "PDT"; break;
        case 5: cal_month = 5;  cal_year = base_year + 1; tz_str = "PDT"; break;
        default: cal_month = 7; cal_year = base_year + 1; tz_str = "PDT"; break;
    }
    int cal_day = 6 + ((patch * 5) % 18);

    static const int sakamoto_t[12] = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    static const char * const wday_names[7] = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    static const char * const mon_names[12] = {
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    };
    int y = cal_year - (cal_month < 3 ? 1 : 0);
    int dow = (y + y / 4 - y / 100 + y / 400 + sakamoto_t[cal_month - 1] + cal_day) % 7;
    if (dow < 0) dow += 7;

    snprintf(out_buf, out_size,
             "Darwin Kernel Version %s: %s %s %2d 21:14:08 %s %d; root:xnu-%d.%d.%d~1",
             eff_release, wday_names[dow], mon_names[cal_month - 1], cal_day,
             tz_str, cal_year, xnu_maj, xnu_min, xnu_pat);
}

static void pt_fallback_ios_version_for_kern_major(int kern_major, char *out_buf, size_t out_size) {
    if (out_buf == NULL || out_size == 0) {
        return;
    }
    switch (kern_major) {
        case 19: strlcpy(out_buf, "13.7", out_size); break;
        case 20: strlcpy(out_buf, "14.8", out_size); break;
        case 21: strlcpy(out_buf, "15.8", out_size); break;
        case 22: strlcpy(out_buf, "16.7", out_size); break;
        case 23: strlcpy(out_buf, "17.6", out_size); break;
        case 24: strlcpy(out_buf, "18.3", out_size); break;
        case 25: strlcpy(out_buf, "26.0", out_size); break;
        default:
            if (kern_major > 25) {
                snprintf(out_buf, out_size, "%d.0", kern_major + 1);
            } else {
                strlcpy(out_buf, "18.3", out_size);
            }
            break;
    }
}

static const char *pt_canonical_ios_build_for_prefix(int expected_prefix, char *buf, size_t buf_size) {
    switch (expected_prefix) {
        case 17: return "17H35";
        case 18: return "18H17";
        case 19: return "19H12";
        case 20: return "20H19";
        case 21: return "21G93";
        case 22: return "22D63";
        case 23: return "23A341";
        default:
            if (buf != NULL && buf_size >= 6 && expected_prefix >= 15 && expected_prefix <= 99) {
                snprintf(buf, buf_size, "%dA340", expected_prefix);
                return buf;
            }
            return "22D63";
    }
}

static BOOL pt_expected_ios_build_prefix_for_major(int ios_major, int *out_expected_prefix) {
    if (out_expected_prefix == NULL) {
        return NO;
    }
    if (ios_major >= 11 && ios_major <= 18) {
        *out_expected_prefix = ios_major + 4;
        return YES;
    }
    if (ios_major >= 19 && ios_major <= 25) {
        *out_expected_prefix = 22;
        return YES;
    }
    if (ios_major >= 26 && ios_major <= 99) {
        *out_expected_prefix = ios_major - 3;
        return YES;
    }
    return NO;
}

static BOOL pt_sanitize_ios_build_version_with_kern_major(const char *build_cstr,
                                                          const char *ios_ver_cstr,
                                                          int kern_major,
                                                          char *out_buf,
                                                          size_t out_size) {
    if (out_buf == NULL || out_size < 4 || build_cstr == NULL) {
        return NO;
    }
    int expected_prefix = 0;
    if (ios_ver_cstr != NULL) {
        while (*ios_ver_cstr == ' ' || *ios_ver_cstr == '\t') {
            ios_ver_cstr++;
        }
        if (*ios_ver_cstr >= '0' && *ios_ver_cstr <= '9') {
            int pv_major = atoi(ios_ver_cstr);
            (void)pt_expected_ios_build_prefix_for_major(pv_major, &expected_prefix);
        }
    }
    if (expected_prefix <= 0 && kern_major >= 19) {
        expected_prefix = kern_major - 2;
    }

    const char *p = build_cstr;
    int b_prefix = 0;
    size_t digit_len = 0;
    while (*p >= '0' && *p <= '9' && digit_len < 4) {
        b_prefix = b_prefix * 10 + (*p - '0');
        p++;
        digit_len++;
    }
    BOOL valid_shape = (digit_len >= 2 && digit_len <= 3 &&
                        ((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z')));
    if (!valid_shape) {
        if (expected_prefix > 0) {
            char cbuf[16];
            const char *canon = pt_canonical_ios_build_for_prefix(expected_prefix, cbuf, sizeof(cbuf));
            strlcpy(out_buf, canon, out_size);
            return (strcmp(out_buf, build_cstr) != 0);
        }
        strlcpy(out_buf, build_cstr, out_size);
        return NO;
    }

    if (expected_prefix > 0 && b_prefix != expected_prefix) {
        int n = snprintf(out_buf, out_size, "%d%s", expected_prefix, p);
        if (n > 0 && (size_t)n < out_size) {
            return YES;
        }
    }
    strlcpy(out_buf, build_cstr, out_size);
    return NO;
}

static void pt_init_host_kernel_info(void) {
    struct utsname real_uts;
    memset(&real_uts, 0, sizeof(real_uts));
    if (uname(&real_uts) == 0) {
        if (real_uts.release[0] != '\0') {
            strlcpy(s_real_kern_release, real_uts.release, sizeof(s_real_kern_release));
        }
    }
    pt_synthesize_ios_kernel_version_prefix(s_real_kern_release,
                                            s_spoofed_kern_version_prefix,
                                            sizeof(s_spoofed_kern_version_prefix));

    BOOL has_ios_ver = NO;
    int sv_fd = pt_orig_open_nocancel("/System/Library/CoreServices/SystemVersion.plist", O_RDONLY);
    if (sv_fd >= 0) {
        char ios_ver[32];
        if (pt_read_plist_top_string_from_fd(sv_fd, "iOSSupportVersion", ios_ver, sizeof(ios_ver)) &&
            ios_ver[0] != '\0') {
            strlcpy(s_spoofed_ios_version, ios_ver, sizeof(s_spoofed_ios_version));
            has_ios_ver = YES;
        }
        close(sv_fd);
    }

    char osv[64] = {0};
    size_t osv_len = sizeof(osv);
    if (sysctlbyname("kern.osversion", osv, &osv_len, NULL, 0) != 0) {
        osv[0] = '\0';
    }
    int major = atoi(s_real_kern_release);
    if (!has_ios_ver && major >= 19) {
        pt_fallback_ios_version_for_kern_major(major, s_spoofed_ios_version, sizeof(s_spoofed_ios_version));
        has_ios_ver = YES;
    }
    if (osv[0] != '\0') {
        (void)pt_sanitize_ios_build_version_with_kern_major(
            osv,
            has_ios_ver ? s_spoofed_ios_version : NULL,
            major,
            s_spoofed_osversion,
            sizeof(s_spoofed_osversion));
    }

    pt_synthesize_ios_kernel_version_prefix("24.3.0",
                                            s_compat18_kern_version_prefix,
                                            sizeof(s_compat18_kern_version_prefix));
    pt_synthesize_ios_kernel_version_prefix("19.6.0",
                                            s_compat13_kern_version_prefix,
                                            sizeof(s_compat13_kern_version_prefix));

    if (!atomic_load_explicit(&s_reported_ios_override_forced_off, memory_order_acquire) &&
        !pt_is_safe_mode_env_active()) {
        int settings_fd = pt_open_early_settings_plist_fd();
        if (settings_fd >= 0) {
            char rep_mode[32] = {0};
            if (pt_read_plist_top_string_from_fd(settings_fd, "reportedIOSVersion", rep_mode, sizeof(rep_mode)) &&
                !atomic_load_explicit(&s_reported_ios_override_forced_off, memory_order_acquire)) {
                int parsed_override = pt_parse_reported_ios_override_mode_cstr(rep_mode);
                if (parsed_override == 1) {
                    atomic_store_explicit(&s_reported_ios_override_mode,
                                          PT_REPORTED_IOS_OVERRIDE_18_3,
                                          memory_order_release);
                } else if (parsed_override == 2) {
                    atomic_store_explicit(&s_reported_ios_override_mode,
                                          PT_REPORTED_IOS_OVERRIDE_13_7,
                                          memory_order_release);
                }
            }
            close(settings_fd);
        }
    }
}

static inline void pt_ensure_host_kernel_info(void) {
    pthread_once(&s_host_kern_once, pt_init_host_kernel_info);
}

static pt_reported_ios_override_t pt_active_reported_ios_override(void) {
    if (atomic_load_explicit(&s_reported_ios_override_forced_off, memory_order_acquire)) {
        return PT_REPORTED_IOS_OVERRIDE_NONE;
    }
    int mode = atomic_load_explicit(&s_reported_ios_override_mode, memory_order_acquire);
    if (mode == PT_REPORTED_IOS_OVERRIDE_18_3) {
        return PT_REPORTED_IOS_OVERRIDE_18_3;
    }
    if (mode == PT_REPORTED_IOS_OVERRIDE_13_7) {
        return PT_REPORTED_IOS_OVERRIDE_13_7;
    }
    return PT_REPORTED_IOS_OVERRIDE_NONE;
}

__attribute__((visibility("hidden"))) void pt_disable_reported_ios_override_for_safe_mode(void) {
    atomic_store_explicit(&s_reported_ios_override_forced_off, YES, memory_order_release);
    atomic_store_explicit(&s_reported_ios_override_mode, PT_REPORTED_IOS_OVERRIDE_NONE, memory_order_release);
    if (atomic_load_explicit(&s_has_uncoerced_device_model, memory_order_acquire) &&
        s_uncoerced_device_model[0] != '\0') {
        const pt_device_profile_t *orig_profile = pt_set_cached_device_profile_from_model(
            s_uncoerced_device_model,
            s_final_device_model, sizeof(s_final_device_model),
            s_final_oem_id, sizeof(s_final_oem_id));
        atomic_store_explicit(&s_active_device_profile, orig_profile, memory_order_release);
        atomic_store_explicit(&s_active_device_model, orig_profile->model, memory_order_release);
        atomic_store_explicit(&s_active_oem_id, orig_profile->oem_id, memory_order_release);
    }
}

__attribute__((visibility("hidden")))
BOOL pt_is_compat13_7_active(void) {
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire) ||
        !pt_is_bypass_enabled()) {
        return NO;
    }
    pt_ensure_host_kernel_info();
    return (pt_active_reported_ios_override() == PT_REPORTED_IOS_OVERRIDE_13_7);
}

extern bool pt_orig_availability_version_check(uint32_t count, const pt_dyld_build_version_t versions[])
    __asm("__availability_version_check") __attribute__((weak_import));

static BOOL pt_is_availability_app_caller(const void *caller, const void *frame_ptr) {
    if (!pt_is_effective_system_or_playtools_caller(caller)) {
        return YES;
    }
    const void *scaller = pt_strip_return_addr((uintptr_t)caller);
    const char *img = (scaller != NULL) ? dyld_image_path_containing_address(scaller) : NULL;
    if (img == NULL || strstr(img, "libswift") == NULL) {
        return NO;
    }
    pthread_t self_thr = pthread_self();
    uintptr_t stack_top = (uintptr_t)pthread_get_stackaddr_np(self_thr);
    size_t stack_sz = pthread_get_stacksize_np(self_thr);
    if (stack_top == 0 || stack_sz < 64 || stack_top < stack_sz) {
        return NO;
    }
    uintptr_t stack_bot = stack_top - stack_sz;
    uintptr_t fp = (uintptr_t)frame_ptr;
    for (int depth = 0; depth < PT_MAX_CALLER_UNWIND_DEPTH; depth++) {
        if (fp < stack_bot || fp + 16U > stack_top || (fp & 0x7U) != 0) {
            break;
        }
        const uintptr_t *frame = (const uintptr_t *)fp;
        uintptr_t next_fp = frame[0];
        const void *lr = (const void *)frame[1];
        if (lr != NULL) {
            if (!pt_is_effective_system_or_playtools_caller(lr)) {
                return YES;
            }
            const void *slr = pt_strip_return_addr((uintptr_t)lr);
            const char *pimg = (slr != NULL) ? dyld_image_path_containing_address(slr) : NULL;
            if (pimg == NULL || strstr(pimg, "libswift") == NULL) {
                return NO;
            }
        }
        if (next_fp <= fp) {
            break;
        }
        fp = next_fp;
    }
    return NO;
}

__attribute__((visibility("hidden")))
bool pt_availability_version_check(uint32_t count, const pt_dyld_build_version_t versions[]) {
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire) ||
        !pt_is_bypass_enabled() ||
        versions == NULL || count == 0 || count > 32U) {
        return (pt_orig_availability_version_check != NULL)
            ? pt_orig_availability_version_check(count, versions)
            : true;
    }
    const void *caller = __builtin_return_address(0);
    const void *fp = __builtin_frame_address(0);
    if (pt_is_availability_app_caller(caller, fp)) {
        pt_ensure_host_kernel_info();
        pt_reported_ios_override_t mode = pt_active_reported_ios_override();
        if (mode != PT_REPORTED_IOS_OVERRIDE_NONE) {
            uint32_t spoofed_ver = (mode == PT_REPORTED_IOS_OVERRIDE_13_7) ? 0x000D0700U : 0x00120300U;
            for (uint32_t i = 0; i < count; i++) {
                if (versions[i].platform == 2U) { // PLATFORM_IOS
                    return (spoofed_ver >= versions[i].version);
                }
            }
            for (uint32_t i = 0; i < count; i++) {
                if (versions[i].platform == 6U) { // PLATFORM_MACCATALYST
                    return (spoofed_ver >= versions[i].version);
                }
            }
        }
    }
    return (pt_orig_availability_version_check != NULL)
        ? pt_orig_availability_version_check(count, versions)
        : true;
}

__attribute__((visibility("hidden"))) const char *pt_get_reported_ios_version_override(const char **out_build) {
    pt_ensure_host_kernel_info();
    switch (pt_active_reported_ios_override()) {
        case PT_REPORTED_IOS_OVERRIDE_18_3:
            if (out_build != NULL) {
                *out_build = "22D63";
            }
            return "18.3";
        case PT_REPORTED_IOS_OVERRIDE_13_7:
            if (out_build != NULL) {
                *out_build = "17H35";
            }
            return "13.7";
        default:
            if (out_build != NULL) {
                *out_build = NULL;
            }
            return NULL;
    }
}

static const char *pt_get_effective_kern_release(void) {
    pt_ensure_host_kernel_info();
    switch (pt_active_reported_ios_override()) {
        case PT_REPORTED_IOS_OVERRIDE_13_7:
            return "19.6.0";
        case PT_REPORTED_IOS_OVERRIDE_18_3:
            return "24.3.0";
        default:
            return s_real_kern_release;
    }
}

static void pt_format_kernel_version(const pt_device_profile_t *profile, char *buf, size_t buf_size) {
    pt_ensure_host_kernel_info();
    const char *prefix = s_spoofed_kern_version_prefix;
    switch (pt_active_reported_ios_override()) {
        case PT_REPORTED_IOS_OVERRIDE_13_7:
            prefix = s_compat13_kern_version_prefix;
            break;
        case PT_REPORTED_IOS_OVERRIDE_18_3:
            prefix = s_compat18_kern_version_prefix;
            break;
        default:
            break;
    }
    snprintf(buf, buf_size, "%s/%s", prefix, profile->kernel_tag);
}

// Change the machine output by uname to match expected output on iOS
static int pt_uname(struct utsname *uts) {
    if (uts == NULL) {
        errno = EFAULT;
        return -1;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        pt_ensure_host_kernel_info();
        const pt_device_profile_t *profile = pt_get_active_device_profile();
        memset(uts, 0, sizeof(*uts));
        strlcpy(uts->sysname, "Darwin", sizeof(uts->sysname));
        strlcpy(uts->nodename, profile->is_ipad ? "iPad" : "iPhone", sizeof(uts->nodename));
        strlcpy(uts->release, pt_get_effective_kern_release(), sizeof(uts->release));
        pt_format_kernel_version(profile, uts->version, sizeof(uts->version));
        strlcpy(uts->machine, pt_get_model_cstr(), sizeof(uts->machine));
        return 0;
    }
    return uname(uts);
}

// Update output of sysctl for key values hw.machine, hw.product, hw.model and hw.target to match iOS output
// This spoofs the device type to apps allowing us to report as any iOS device
typedef struct {
    const char *name;
    int mib[6];
    u_int len;
} pt_sysctl_mib_entry_t;

static pt_sysctl_mib_entry_t s_sysctl_mibs[] = {
    { "hw.targettype", {0}, 0 },
    { "hw.jetsam_properties_product_type", {0}, 0 },
    { "machdep.cpu.brand_string", {0}, 0 },
    { "machdep.cpu.core_count", {0}, 0 },
    { "machdep.cpu.cores_per_package", {0}, 0 },
    { "machdep.cpu.thread_count", {0}, 0 },
    { "machdep.cpu.logical_per_package", {0}, 0 },
    { "machdep.cpu.vendor", {0}, 0 },
    { "hw.activecpu", {0}, 0 },
    { "hw.physicalcpu", {0}, 0 },
    { "hw.physicalcpu_max", {0}, 0 },
    { "hw.logicalcpu", {0}, 0 },
    { "hw.logicalcpu_max", {0}, 0 },
    { "hw.memsize_usable", {0}, 0 },
    { "hw.cpufamily", {0}, 0 },
    { "hw.cputype", {0}, 0 },
    { "hw.cpusubtype", {0}, 0 },
    { "hw.nperflevels", {0}, 0 },
    { "hw.perflevel0.physicalcpu", {0}, 0 },
    { "hw.perflevel0.physicalcpu_max", {0}, 0 },
    { "hw.perflevel0.logicalcpu", {0}, 0 },
    { "hw.perflevel0.logicalcpu_max", {0}, 0 },
    { "hw.perflevel0.l2cachesize", {0}, 0 },
    { "hw.perflevel0.name", {0}, 0 },
    { "hw.perflevel1.physicalcpu", {0}, 0 },
    { "hw.perflevel1.physicalcpu_max", {0}, 0 },
    { "hw.perflevel1.logicalcpu", {0}, 0 },
    { "hw.perflevel1.logicalcpu_max", {0}, 0 },
    { "hw.perflevel1.l2cachesize", {0}, 0 },
    { "hw.perflevel1.name", {0}, 0 },
    { "hw.l1dcachesize", {0}, 0 },
    { "hw.l2cachesize", {0}, 0 },
    { "hw.cacheconfig", {0}, 0 },
    { "hw.cachesize", {0}, 0 },
    { "hw.packages", {0}, 0 },
    { "hw.use_kernelmanagerd", {0}, 0 },
    { "vm.swapusage", {0}, 0 },
    { "vm.swapfileprefix", {0}, 0 },
    { "kern.iossupportversion", {0}, 0 },
    { "kern.osproductversion", {0}, 0 },
    { "kern.bootargs", {0}, 0 },
    { "kern.wakereason", {0}, 0 },
    { "kern.hibernatefile", {0}, 0 },
    { "kern.hibernatewakenotification", {0}, 0 },
    { "kern.hibernatemode", {0}, 0 },
    { "kern.hibernatestatistics", {0}, 0 },
    { "kern.hibernategraphicsready", {0}, 0 },
    { "kern.hibernatelockscreenready", {0}, 0 },
    { "kern.hibernatehidready", {0}, 0 },
    { "kern.hibernatecount", {0}, 0 },
    { "kern.hibernatepreview", {0}, 0 },
    { "kern.osproductversioncompat", {0}, 0 },
    { "kern.osvariant_status", {0}, 0 },
    { "kern.osbuildconfig", {0}, 0 },
    { "kern.hv_support", {0}, 0 },
    { "kern.hv_vmm_present", {0}, 0 },
    { "kern.singleuser", {0}, 0 },
    { "kern.safeboot", {0}, 0 },
    { "kern.willshutdown", {0}, 0 },
    { "kern.waketime", {0}, 0 },
    { "kern.sleeptime", {0}, 0 },
    { "kern.secure_kernel", {0}, 0 },
    { "security.mac.amfi.developer_mode_status", {0}, 0 },
    { "sysctl.proc_translated", {0}, 0 },
    { "sysctl.proc_native", {0}, 0 },
    { "sysctl.proc_cputype", {0}, 0 },
};
static pthread_once_t s_pt_sysctl_mibs_once = PTHREAD_ONCE_INIT;
static uint32_t s_sysctl_root_mask = 0;

static void pt_init_sysctl_mibs(void) {
    size_t count = sizeof(s_sysctl_mibs) / sizeof(s_sysctl_mibs[0]);
    uint32_t mask = 0;
    for (size_t i = 0; i < count; i++) {
        size_t n = 6;
        if (sysctlnametomib(s_sysctl_mibs[i].name, s_sysctl_mibs[i].mib, &n) == 0 && n > 0 && n <= 6) {
            s_sysctl_mibs[i].len = (u_int)n;
            int r = s_sysctl_mibs[i].mib[0];
            mask |= (r >= 0 && r < 31) ? (1U << (unsigned)r) : (1U << 31);
        } else {
            s_sysctl_mibs[i].len = 0;
        }
    }
    s_sysctl_root_mask = mask;
}

static const char *pt_lookup_mib_name(const int *name, u_int types) {
    pthread_once(&s_pt_sysctl_mibs_once, pt_init_sysctl_mibs);
    int r = name[0];
    uint32_t bit = (r >= 0 && r < 31) ? (1U << (unsigned)r) : (1U << 31);
    if ((s_sysctl_root_mask & bit) == 0) {
        return NULL;
    }
    size_t count = sizeof(s_sysctl_mibs) / sizeof(s_sysctl_mibs[0]);
    for (size_t i = 0; i < count; i++) {
        const pt_sysctl_mib_entry_t *e = &s_sysctl_mibs[i];
        if (e->len == 0 || e->len != types) {
            continue;
        }
        BOOL match = YES;
        for (u_int j = 0; j < types; j++) {
            if (name[j] != e->mib[j]) {
                match = NO;
                break;
            }
        }
        if (match) {
            return e->name;
        }
    }
    return NULL;
}

static inline BOOL pt_sysctl_resolve_is_sys(const void *caller, int *inout_is_sys_caller) {
    if (*inout_is_sys_caller < 0) {
        *inout_is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
    }
    return (*inout_is_sys_caller != 0);
}

static uint64_t pt_get_spoofed_l1d_cache_size(const pt_device_profile_t *profile) {
    if (profile != NULL) {
        if (profile->max_apple_gpu_family <= 1003) {
            return 32768ULL;
        }
        if (profile->max_apple_gpu_family <= 1006) {
            return 65536ULL;
        }
    }
    return 131072ULL;
}

static void pt_get_spoofed_l2_cache_sizes(const pt_device_profile_t *profile,
                                          uint64_t *out_p_l2,
                                          uint64_t *out_e_l2) {
    uint64_t p_l2 = 16ULL << 20;
    uint64_t e_l2 = 4ULL << 20;
    if (profile != NULL) {
        if (profile->max_apple_gpu_family <= 1003) {
            p_l2 = 3ULL << 20;
            e_l2 = 0ULL;
        } else if (profile->max_apple_gpu_family <= 1006) {
            p_l2 = 8ULL << 20;
            e_l2 = 4ULL << 20;
        } else if (profile->max_apple_gpu_family == 1007 ||
                   strcmp(profile->model, "iPhone14,3") == 0) {
            p_l2 = 12ULL << 20;
            e_l2 = 4ULL << 20;
        }
    }
    if (out_p_l2 != NULL) {
        *out_p_l2 = p_l2;
    }
    if (out_e_l2 != NULL) {
        *out_e_l2 = e_l2;
    }
}

static BOOL pt_is_hidden_sysctl_name(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return NO;
    }
    if (strcmp(name, "sysctl.proc_translated") == 0 ||
        strcmp(name, "sysctl.proc_native") == 0 ||
        strcmp(name, "sysctl.proc_cputype") == 0 ||
        strcmp(name, "kern.iossupportversion") == 0 ||
        strncmp(name, "kern.hibernate", 14) == 0 ||
        strcmp(name, "kern.singleuser") == 0 ||
        strcmp(name, "kern.safeboot") == 0 ||
        strcmp(name, "kern.willshutdown") == 0 ||
        strcmp(name, "kern.waketime") == 0 ||
        strcmp(name, "kern.sleeptime") == 0 ||
        strcmp(name, "hw.use_kernelmanagerd") == 0 ||
        strcmp(name, "vm.swapusage") == 0) {
        return YES;
    }
    if (strncmp(name, "hw.perflevel1.", 14) == 0 &&
        pt_get_active_device_profile()->e_cores == 0) {
        return YES;
    }
    if (pt_is_compat13_7_active()) {
        if (strncmp(name, "hw.optional.arm.FEAT_", 21) == 0 ||
            strcmp(name, "kern.osproductversioncompat") == 0 ||
            strcmp(name, "hw.nperflevels") == 0 ||
            strncmp(name, "hw.perflevel0.", 14) == 0 ||
            strncmp(name, "hw.perflevel1.", 14) == 0) {
            return YES;
        }
    }
    return NO;
}

static BOOL pt_handle_sysctl_name(const char *name,
                                  void *oldp,
                                  size_t *oldlenp,
                                  void *newp,
                                  size_t newlen,
                                  const void *caller,
                                  int *inout_is_sys_caller,
                                  int *out_ret) {
    if (name == NULL || out_ret == NULL) {
        return NO;
    }
    if (pt_is_hidden_sysctl_name(name)) {
        if (!pt_is_bypass_enabled() || pt_sysctl_resolve_is_sys(caller, inout_is_sys_caller)) {
            return NO;
        }
        errno = ENOENT;
        *out_ret = -1;
        return YES;
    }
    char c0 = name[0];
    if (c0 != 'h' && c0 != 'k' && c0 != 'm' && c0 != 's' && c0 != 'v') {
        return NO;
    }
    if (c0 == 'v' && strcmp(name, "vm.swapfileprefix") == 0) {
        if (!pt_is_bypass_enabled() || pt_sysctl_resolve_is_sys(caller, inout_is_sys_caller)) {
            return NO;
        }
        *out_ret = pt_write_sysctl_string("/private/var/vm/swapfile", oldp, oldlenp);
        return YES;
    }
    if (c0 == 'h' && strncmp(name, "hw.", 3) == 0) {
        if (!pt_is_bypass_enabled() || pt_sysctl_resolve_is_sys(caller, inout_is_sys_caller)) {
            return NO;
        }
        const char *sub = name + 3;
        if (strcmp(sub, "machine") == 0 || strcmp(sub, "product") == 0) {
            *out_ret = pt_write_sysctl_string(DEVICE_MODEL, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "model") == 0 ||
            strcmp(sub, "target") == 0 ||
            strcmp(sub, "targettype") == 0 ||
            strcmp(sub, "jetsam_properties_product_type") == 0) {
            *out_ret = pt_write_sysctl_string(OEM_ID, oldp, oldlenp);
            return YES;
        }
        const pt_device_profile_t *profile = pt_get_active_device_profile();
        if (strcmp(sub, "use_kernelmanagerd") == 0) {
            errno = ENOENT;
            *out_ret = -1;
            return YES;
        }
        if (strncmp(sub, "optional.arm.FEAT_", 18) == 0 && pt_is_compat13_7_active()) {
            errno = ENOENT;
            *out_ret = -1;
            return YES;
        }
        if (strcmp(sub, "packages") == 0) {
            *out_ret = pt_write_sysctl_int(1, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "l1dcachesize") == 0) {
            uint64_t l1d = pt_get_spoofed_l1d_cache_size(profile);
            *out_ret = pt_write_sysctl_uint64(oldp, oldlenp, (newlen > 0) ? newp : NULL, l1d);
            return YES;
        }
        if (strcmp(sub, "l2cachesize") == 0) {
            uint64_t p_l2 = 0;
            pt_get_spoofed_l2_cache_sizes(profile, &p_l2, NULL);
            *out_ret = pt_write_sysctl_uint64(oldp, oldlenp, (newlen > 0) ? newp : NULL, p_l2);
            return YES;
        }
        if (strcmp(sub, "cacheconfig") == 0) {
            uint64_t vals[10] = {0};
            vals[0] = (uint64_t)profile->cores;
            vals[1] = 1ULL;
            vals[2] = (uint64_t)(profile->e_cores > 0 ? profile->e_cores : profile->cores);
            *out_ret = pt_write_sysctl_uint64_array(oldp, oldlenp, (newlen > 0) ? newp : NULL, vals, 10U);
            return YES;
        }
        if (strcmp(sub, "cachesize") == 0) {
            uint64_t vals[10] = {0};
            uint64_t p_l2 = 0;
            pt_get_spoofed_l2_cache_sizes(profile, &p_l2, NULL);
            vals[0] = profile->ram_bytes;
            vals[1] = pt_get_spoofed_l1d_cache_size(profile);
            vals[2] = p_l2;
            *out_ret = pt_write_sysctl_uint64_array(oldp, oldlenp, (newlen > 0) ? newp : NULL, vals, 10U);
            return YES;
        }
        if (strcmp(sub, "ncpu") == 0 ||
            strcmp(sub, "activecpu") == 0 ||
            strcmp(sub, "availcpu") == 0 ||
            strcmp(sub, "physicalcpu") == 0 ||
            strcmp(sub, "physicalcpu_max") == 0 ||
            strcmp(sub, "logicalcpu") == 0 ||
            strcmp(sub, "logicalcpu_max") == 0) {
            *out_ret = pt_write_sysctl_int((int)profile->cores, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "memsize") == 0) {
            *out_ret = pt_write_sysctl_uint64(oldp, oldlenp, (newlen > 0) ? newp : NULL, profile->ram_bytes);
            return YES;
        }
        if (strcmp(sub, "memsize_usable") == 0) {
            uint64_t usable = profile->ram_bytes - (profile->ram_bytes / 16ULL);
            *out_ret = pt_write_sysctl_uint64(oldp, oldlenp, (newlen > 0) ? newp : NULL, usable);
            return YES;
        }
        if (strcmp(sub, "physmem") == 0) {
            uint32_t phys32 = (uint32_t)(profile->ram_bytes > 0x80000000ULL ? 0x80000000U : profile->ram_bytes);
            *out_ret = pt_write_sysctl_int((int)phys32, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "cpufamily") == 0) {
            *out_ret = pt_write_sysctl_int((int)profile->cpufamily, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "cputype") == 0) {
            *out_ret = pt_write_sysctl_int((int)CPU_TYPE_ARM64, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "cpusubtype") == 0) {
            *out_ret = pt_write_sysctl_int((int)CPU_SUBTYPE_ARM64_ALL, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "pagesize") == 0) {
            *out_ret = pt_write_sysctl_int(16384, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "nperflevels") == 0) {
            *out_ret = pt_write_sysctl_int(profile->e_cores > 0 ? 2 : 1, oldp, oldlenp);
            return YES;
        }
        if (strncmp(sub, "perflevel0.", 11) == 0) {
            const char *psub = sub + 11;
            if (strcmp(psub, "physicalcpu") == 0 ||
                strcmp(psub, "physicalcpu_max") == 0 ||
                strcmp(psub, "logicalcpu") == 0 ||
                strcmp(psub, "logicalcpu_max") == 0) {
                *out_ret = pt_write_sysctl_int((int)profile->p_cores, oldp, oldlenp);
                return YES;
            }
            if (strcmp(psub, "l2cachesize") == 0) {
                uint64_t p_l2 = 0;
                pt_get_spoofed_l2_cache_sizes(profile, &p_l2, NULL);
                *out_ret = pt_write_sysctl_uint64(oldp, oldlenp, (newlen > 0) ? newp : NULL, p_l2);
                return YES;
            }
            if (strcmp(psub, "name") == 0) {
                *out_ret = pt_write_sysctl_string("Performance", oldp, oldlenp);
                return YES;
            }
        }
        if (strncmp(sub, "perflevel1.", 11) == 0) {
            if (profile->e_cores == 0) {
                errno = ENOENT;
                *out_ret = -1;
                return YES;
            }
            const char *psub = sub + 11;
            if (strcmp(psub, "physicalcpu") == 0 ||
                strcmp(psub, "physicalcpu_max") == 0 ||
                strcmp(psub, "logicalcpu") == 0 ||
                strcmp(psub, "logicalcpu_max") == 0) {
                *out_ret = pt_write_sysctl_int((int)profile->e_cores, oldp, oldlenp);
                return YES;
            }
            if (strcmp(psub, "l2cachesize") == 0) {
                uint64_t e_l2 = 0;
                pt_get_spoofed_l2_cache_sizes(profile, NULL, &e_l2);
                *out_ret = pt_write_sysctl_uint64(oldp, oldlenp, (newlen > 0) ? newp : NULL, e_l2);
                return YES;
            }
            if (strcmp(psub, "name") == 0) {
                *out_ret = pt_write_sysctl_string("Efficiency", oldp, oldlenp);
                return YES;
            }
        }
        return NO;
    }
    if (c0 == 'k' && strncmp(name, "kern.", 5) == 0) {
        const char *sub = name + 5;
        if (!pt_is_bypass_enabled() || pt_sysctl_resolve_is_sys(caller, inout_is_sys_caller)) {
            return NO;
        }
        const pt_device_profile_t *profile = pt_get_active_device_profile();
        if (strcmp(sub, "ostype") == 0) {
            *out_ret = pt_write_sysctl_string("Darwin", oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "osrelease") == 0) {
            *out_ret = pt_write_sysctl_string(pt_get_effective_kern_release(), oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "osversion") == 0) {
            pt_ensure_host_kernel_info();
            const char *ov_build = NULL;
            (void)pt_get_reported_ios_version_override(&ov_build);
            *out_ret = pt_write_sysctl_string(ov_build != NULL ? ov_build : s_spoofed_osversion, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "osproductversion") == 0) {
            pt_ensure_host_kernel_info();
            const char *ov_ver = pt_get_reported_ios_version_override(NULL);
            *out_ret = pt_write_sysctl_string(ov_ver != NULL ? ov_ver : s_spoofed_ios_version, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "version") == 0) {
            char kver[256];
            pt_format_kernel_version(profile, kver, sizeof(kver));
            *out_ret = pt_write_sysctl_string(kver, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "hostname") == 0) {
            *out_ret = pt_write_sysctl_string(profile->is_ipad ? "iPad" : "iPhone", oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "osrevision") == 0) {
            *out_ret = pt_write_sysctl_int(199506, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "iossupportversion") == 0 ||
            strcmp(sub, "hibernatefile") == 0) {
            errno = ENOENT;
            *out_ret = -1;
            return YES;
        }
        if (strcmp(sub, "bootargs") == 0 ||
            strcmp(sub, "wakereason") == 0) {
            *out_ret = pt_write_sysctl_string("", oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "secure_kernel") == 0) {
            *out_ret = pt_write_sysctl_int(1, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "hv_support") == 0 ||
            strcmp(sub, "hv_vmm_present") == 0) {
            *out_ret = pt_write_sysctl_int(0, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "osbuildconfig") == 0) {
            *out_ret = pt_write_sysctl_string("release", oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "osvariant_status") == 0) {
            uint64_t raw_status = 0x70010000f288828aULL;
            size_t rlen = sizeof(raw_status);
            (void)sysctlbyname("kern.osvariant_status", &raw_status, &rlen, NULL, 0);
            // Preserve header/version bits [32..63], fixed sentinel bits [28..31] (0xF),
            // and every 2-bit pair's "known" bit (odd bits in [0..27]), while clearing
            // every 2-bit pair's "value" bit (even bits in [0..27]) for consumer iOS release.
            uint64_t consumer_ios_status = raw_status & ~0x0000000005555555ULL;
            *out_ret = pt_write_sysctl_uint64(oldp, oldlenp, (newlen > 0) ? newp : NULL, consumer_ios_status);
            return YES;
        }
        return NO;
    }
    if (c0 == 'm' && strncmp(name, "machdep.cpu.", 12) == 0) {
        if (!pt_is_bypass_enabled() || pt_sysctl_resolve_is_sys(caller, inout_is_sys_caller)) {
            return NO;
        }
        const pt_device_profile_t *profile = pt_get_active_device_profile();
        const char *sub = name + 12;
        if (strcmp(sub, "brand_string") == 0) {
            *out_ret = pt_write_sysctl_string(profile->cpu_brand, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "core_count") == 0 ||
            strcmp(sub, "cores_per_package") == 0 ||
            strcmp(sub, "thread_count") == 0 ||
            strcmp(sub, "logical_per_package") == 0) {
            *out_ret = pt_write_sysctl_int((int)profile->cores, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "vendor") == 0) {
            *out_ret = pt_write_sysctl_string("Apple", oldp, oldlenp);
            return YES;
        }
        errno = ENOENT;
        *out_ret = -1;
        return YES;
    }
    if (c0 == 's' && strcmp(name, "security.mac.amfi.developer_mode_status") == 0) {
        if (!pt_is_bypass_enabled() || pt_sysctl_resolve_is_sys(caller, inout_is_sys_caller)) {
            return NO;
        }
        *out_ret = pt_write_sysctl_int(0, oldp, oldlenp);
        return YES;
    }
    return NO;
}

static int pt_sysctlnametomib(const char *sname, int *mibp, size_t *sizep) {
    if (sname != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_hidden_sysctl_name(sname)) {
        errno = ENOENT;
        return -1;
    }
    return sysctlnametomib(sname, mibp, sizep);
}

static BOOL pt_append_procargs_bytes(char **buf, size_t *len, size_t *cap, const void *src, size_t n) {
    if (n == 0) {
        return YES;
    }
    if (*len + n > *cap) {
        size_t new_cap = (*cap == 0) ? 4096U : *cap;
        while (new_cap < *len + n) {
            if (new_cap > (16U << 20)) {
                return NO;
            }
            new_cap *= 2U;
        }
        char *grown = (char *)realloc(*buf, new_cap);
        if (grown == NULL) {
            return NO;
        }
        *buf = grown;
        *cap = new_cap;
    }
    memcpy(*buf + *len, src, n);
    *len += n;
    return YES;
}

__attribute__((visibility("hidden")))
BOOL pt_is_hidden_env_value(const char *val, BOOL has_virtual_container) {
    if (val == NULL || val[0] == '\0') {
        return NO;
    }
    if (strstr(val, "/Users/") != NULL ||
        strcasestr(val, "PlayTools") != NULL ||
        strcasestr(val, "PlayCover") != NULL ||
        strcasestr(val, "MacOver") != NULL ||
        strcasestr(val, "app.makedie") != NULL ||
        strcasestr(val, "AKInterface") != NULL) {
        return YES;
    }
    if (has_virtual_container &&
        (strstr(val, "/var/folders/") != NULL ||
         strstr(val, "/private/var/folders/") != NULL)) {
        return YES;
    }
    return NO;
}

__attribute__((visibility("hidden")))
pt_env_entry_action_t pt_resolve_env_entry(const char *key,
                                           const char *raw_val,
                                           BOOL has_raw_entry,
                                           BOOL bypass_enabled,
                                           const char *vh,
                                           const char *vt,
                                           const char **out_val) {
    if (out_val != NULL) {
        *out_val = NULL;
    }
    if (key == NULL || key[0] == '\0') {
        return PT_ENV_ENTRY_HIDE;
    }
    BOOL has_vc = (vh != NULL);
    if (strcmp(key, "HOME") == 0 || strcmp(key, "CFFIXED_USER_HOME") == 0) {
        if (vh != NULL) {
            if (out_val != NULL) {
                *out_val = vh;
            }
            return PT_ENV_ENTRY_REWRITE;
        }
        if (!has_raw_entry) {
            return PT_ENV_ENTRY_HIDE;
        }
        if (bypass_enabled && pt_is_hidden_env_value(raw_val, has_vc)) {
            return PT_ENV_ENTRY_HIDE;
        }
        return PT_ENV_ENTRY_KEEP;
    }
    if (strcmp(key, "TMPDIR") == 0) {
        if (vt != NULL) {
            if (out_val != NULL) {
                *out_val = vt;
            }
            return PT_ENV_ENTRY_REWRITE;
        }
        if (!has_raw_entry) {
            return PT_ENV_ENTRY_HIDE;
        }
        if (bypass_enabled && pt_is_hidden_env_value(raw_val, has_vc)) {
            return PT_ENV_ENTRY_HIDE;
        }
        return PT_ENV_ENTRY_KEEP;
    }
    if (strcmp(key, "TMP") == 0 || strcmp(key, "TEMP") == 0) {
        if (!has_raw_entry) {
            return PT_ENV_ENTRY_HIDE;
        }
        if (vt != NULL) {
            if (out_val != NULL) {
                *out_val = vt;
            }
            return PT_ENV_ENTRY_REWRITE;
        }
        if (bypass_enabled && pt_is_hidden_env_value(raw_val, has_vc)) {
            return PT_ENV_ENTRY_HIDE;
        }
        return PT_ENV_ENTRY_KEEP;
    }
    if (strcmp(key, "PWD") == 0) {
        if (!has_raw_entry) {
            return PT_ENV_ENTRY_HIDE;
        }
        if (bypass_enabled) {
            if (out_val != NULL) {
                *out_val = "/";
            }
            return PT_ENV_ENTRY_REWRITE;
        }
        return PT_ENV_ENTRY_KEEP;
    }
    if (strcmp(key, "PATH") == 0) {
        if (bypass_enabled) {
            if (out_val != NULL) {
                *out_val = "/usr/bin:/bin:/usr/sbin:/sbin";
            }
            return PT_ENV_ENTRY_REWRITE;
        }
        return has_raw_entry ? PT_ENV_ENTRY_KEEP : PT_ENV_ENTRY_HIDE;
    }
    if (!has_raw_entry) {
        return PT_ENV_ENTRY_HIDE;
    }
    if (bypass_enabled &&
        (pt_is_hidden_env_key(key) || pt_is_hidden_env_value(raw_val, has_vc))) {
        return PT_ENV_ENTRY_HIDE;
    }
    return PT_ENV_ENTRY_KEEP;
}

extern int pt_orig_kernel_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen)
    __asm("___sysctl");

static int pt_handle_sysctl_procargs(int *name, u_int types, void *buf, size_t *size) {
    if (types < 3 || (name[2] != getpid())) {
        errno = ESRCH;
        return -1;
    }
    BOOL is_v2 = (name[1] == KERN_PROCARGS2);
    size_t raw_len = 0;
    if (pt_orig_kernel_sysctl(name, types, NULL, &raw_len, NULL, 0) != 0 || raw_len == 0) {
        return -1;
    }
    size_t alloc_len = raw_len + 64U;
    char *raw = (char *)malloc(alloc_len);
    if (raw == NULL) {
        errno = ENOMEM;
        return -1;
    }
    if (pt_orig_kernel_sysctl(name, types, raw, &raw_len, NULL, 0) != 0) {
        int saved = errno;
        free(raw);
        errno = saved;
        return -1;
    }
    raw[raw_len] = '\0';

    char *out = NULL;
    size_t out_len = 0;
    size_t out_cap = 0;
    size_t pos = 0;
    int argc = 0;

    if (is_v2) {
        if (raw_len < sizeof(int)) {
            free(raw);
            errno = EINVAL;
            return -1;
        }
        memcpy(&argc, raw, sizeof(int));
        pos = sizeof(int);
        if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, &argc, sizeof(int))) {
            free(raw); free(out); errno = ENOMEM; return -1;
        }
    }

    if (pos < raw_len) {
        const char *exec_path = raw + pos;
        size_t elen = strnlen(exec_path, raw_len - pos);
        char vexec[PATH_MAX];
        const char *virt_exec = pt_virtualize_path_for_app(exec_path, vexec, sizeof(vexec), YES);
        size_t velen = strlen(virt_exec) + 1U;
        if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, virt_exec, velen)) {
            free(raw); free(out); errno = ENOMEM; return -1;
        }
        pos += (elen < raw_len - pos) ? (elen + 1U) : elen;
        while (pos < raw_len && raw[pos] == '\0') {
            pos++;
        }
        if (is_v2) {
            uint8_t zero = 0;
            while ((out_len & 3U) != 0U) {
                if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, &zero, 1U)) {
                    free(raw); free(out); errno = ENOMEM; return -1;
                }
            }
        }
    }

    BOOL bypass = pt_is_bypass_enabled();
    if (is_v2 && argc > 0) {
        int written_argc = 0;
        for (int i = 0; i < argc && pos < raw_len; i++) {
            const char *arg = raw + pos;
            size_t alen = strnlen(arg, raw_len - pos);
            size_t next_pos = pos + ((alen < raw_len - pos) ? (alen + 1U) : alen);
            if (bypass && i > 0) {
                const char *next_arg = (i + 1 < argc && next_pos < raw_len) ? (raw + next_pos) : NULL;
                int skip = pt_macos_launch_arg_skip_count(arg, next_arg);
                if (skip > 0) {
                    pos = next_pos;
                    if (skip == 2 && i + 1 < argc && pos < raw_len) {
                        size_t nlen = strnlen(raw + pos, raw_len - pos);
                        pos += (nlen < raw_len - pos) ? (nlen + 1U) : nlen;
                        i++;
                    }
                    continue;
                }
            }
            const char *out_arg = arg;
            char varg[PATH_MAX];
            if (i == 0) {
                out_arg = pt_virtualize_path_for_app(arg, varg, sizeof(varg), YES);
            }
            if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, out_arg, strlen(out_arg) + 1U)) {
                free(raw); free(out); errno = ENOMEM; return -1;
            }
            written_argc++;
            pos = next_pos;
        }
        if (out != NULL && out_len >= sizeof(int)) {
            memcpy(out, &written_argc, sizeof(int));
        }
    }

    const char *vh = pt_get_virtual_home_cstr();
    const char *vt = pt_get_virtual_tmpdir_cstr();
    BOOL wrote_home = NO;
    BOOL wrote_cffixed_home = NO;
    BOOL wrote_tmpdir = NO;
    BOOL wrote_tmp = NO;
    BOOL wrote_temp = NO;
    BOOL wrote_pwd = NO;
    BOOL wrote_path = NO;
    BOOL seen_env_entry = NO;
    while (pos < raw_len) {
        if (raw[pos] == '\0') {
            if (is_v2 || seen_env_entry) {
                break;
            }
            pos++;
            continue;
        }
        const char *entry = raw + pos;
        size_t elen = strnlen(entry, raw_len - pos);
        const char *eq = (const char *)memchr(entry, '=', elen);
        if (eq != NULL && eq > entry) {
            seen_env_entry = YES;
            size_t klen = (size_t)(eq - entry);
            char stack_key[256];
            char *heap_key = NULL;
            const char *kptr = stack_key;
            if (klen < sizeof(stack_key)) {
                memcpy(stack_key, entry, klen);
                stack_key[klen] = '\0';
            } else {
                heap_key = (char *)malloc(klen + 1U);
                if (heap_key != NULL) {
                    memcpy(heap_key, entry, klen);
                    heap_key[klen] = '\0';
                    kptr = heap_key;
                } else {
                    kptr = "";
                }
            }
            BOOL duplicate_special = NO;
            if (strcmp(kptr, "HOME") == 0) {
                duplicate_special = wrote_home;
                wrote_home = YES;
            } else if (strcmp(kptr, "CFFIXED_USER_HOME") == 0) {
                duplicate_special = wrote_cffixed_home;
                wrote_cffixed_home = YES;
            } else if (strcmp(kptr, "TMPDIR") == 0) {
                duplicate_special = wrote_tmpdir;
                wrote_tmpdir = YES;
            } else if (strcmp(kptr, "TMP") == 0) {
                duplicate_special = wrote_tmp;
                wrote_tmp = YES;
            } else if (strcmp(kptr, "TEMP") == 0) {
                duplicate_special = wrote_temp;
                wrote_temp = YES;
            } else if (strcmp(kptr, "PWD") == 0) {
                duplicate_special = wrote_pwd;
                wrote_pwd = YES;
            } else if (strcmp(kptr, "PATH") == 0) {
                duplicate_special = wrote_path;
                wrote_path = YES;
            }
            if (!duplicate_special && kptr[0] != '\0') {
                size_t vlen = elen - klen - 1U;
                char val_stack[2048];
                char *heap_val = NULL;
                const char *vptr = val_stack;
                if (vlen < sizeof(val_stack)) {
                    memcpy(val_stack, eq + 1, vlen);
                    val_stack[vlen] = '\0';
                } else {
                    heap_val = (char *)malloc(vlen + 1U);
                    if (heap_val != NULL) {
                        memcpy(heap_val, eq + 1, vlen);
                        heap_val[vlen] = '\0';
                        vptr = heap_val;
                    } else {
                        val_stack[0] = '\0';
                    }
                }
                const char *rewritten = NULL;
                pt_env_entry_action_t act = pt_resolve_env_entry(
                    kptr, vptr, YES, bypass, vh, vt, &rewritten);
                free(heap_val);
                if (act == PT_ENV_ENTRY_REWRITE && rewritten != NULL) {
                    if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, kptr, klen) ||
                        !pt_append_procargs_bytes(&out, &out_len, &out_cap, "=", 1U) ||
                        !pt_append_procargs_bytes(&out, &out_len, &out_cap, rewritten, strlen(rewritten) + 1U)) {
                        free(heap_key); free(raw); free(out); errno = ENOMEM; return -1;
                    }
                } else if (act == PT_ENV_ENTRY_KEEP) {
                    if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, entry, elen) ||
                        !pt_append_procargs_bytes(&out, &out_len, &out_cap, "", 1U)) {
                        free(heap_key); free(raw); free(out); errno = ENOMEM; return -1;
                    }
                }
            }
            free(heap_key);
        }
        pos += (elen < raw_len - pos) ? (elen + 1U) : elen;
    }
    const char *const kMandatoryKeys[] = { "HOME", "CFFIXED_USER_HOME", "TMPDIR", "PATH" };
    const BOOL wroteFlags[] = { wrote_home, wrote_cffixed_home, wrote_tmpdir, wrote_path };
    for (size_t mi = 0; mi < 4U; mi++) {
        if (!wroteFlags[mi]) {
            const char *mkey = kMandatoryKeys[mi];
            const char *rewritten = NULL;
            if (pt_resolve_env_entry(mkey, NULL, NO, bypass, vh, vt, &rewritten) == PT_ENV_ENTRY_REWRITE &&
                rewritten != NULL) {
                if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, mkey, strlen(mkey)) ||
                    !pt_append_procargs_bytes(&out, &out_len, &out_cap, "=", 1U) ||
                    !pt_append_procargs_bytes(&out, &out_len, &out_cap, rewritten, strlen(rewritten) + 1U)) {
                    free(raw); free(out); errno = ENOMEM; return -1;
                }
            }
        }
    }
    if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, "", 1U)) {
        free(raw); free(out); errno = ENOMEM; return -1;
    }
    free(raw);

    if (buf == NULL) {
        if (size != NULL) {
            *size = out_len;
        }
        free(out);
        return 0;
    }
    if (size == NULL || *size < out_len) {
        if (size != NULL) {
            *size = out_len;
        }
        free(out);
        errno = ENOMEM;
        return -1;
    }
    if (out_len > 0 && out != NULL) {
        memcpy(buf, out, out_len);
    }
    *size = out_len;
    free(out);
    return 0;
}

#define PT_RT_ROUNDUP(a) ((a) > 0U ? (1U + (((a) - 1U) | (sizeof(uint32_t) - 1U))) : sizeof(uint32_t))

static BOOL pt_u16_list_contains(const uint16_t *arr, size_t count, uint16_t val) {
    for (size_t i = 0; i < count; i++) {
        if (arr[i] == val) {
            return YES;
        }
    }
    return NO;
}

static void pt_u16_list_set_hidden(uint16_t *arr, size_t *count, size_t cap, uint16_t val, BOOL hidden) {
    if (val == 0) {
        return;
    }
    for (size_t i = 0; i < *count; i++) {
        if (arr[i] == val) {
            if (!hidden) {
                arr[i] = arr[*count - 1U];
                (*count)--;
            }
            return;
        }
    }
    if (hidden && *count < cap) {
        arr[(*count)++] = val;
    }
}

static BOOL pt_rt_ifinfo_msg_has_hidden_ifname(const uint8_t *msg,
                                               size_t msg_len,
                                               size_t fixed_hdr_len,
                                               int addrs) {
    if ((addrs & RTA_IFP) == 0 || msg_len <= fixed_hdr_len) {
        return NO;
    }
    const uint8_t *cur = msg + fixed_hdr_len;
    const uint8_t *end = msg + msg_len;
    for (int bit = 1; bit <= RTA_IFP; bit <<= 1) {
        if ((addrs & bit) == 0) {
            continue;
        }
        if ((size_t)(end - cur) < sizeof(struct sockaddr)) {
            return NO;
        }
        const struct sockaddr *sa = (const struct sockaddr *)cur;
        size_t sa_len = (size_t)sa->sa_len;
        if (sa_len == 0 || (size_t)(end - cur) < sa_len) {
            return NO;
        }
        if (bit == RTA_IFP) {
            if (sa->sa_family == AF_LINK && sa_len >= offsetof(struct sockaddr_dl, sdl_data)) {
                const struct sockaddr_dl *sdl = (const struct sockaddr_dl *)sa;
                size_t avail = sa_len - offsetof(struct sockaddr_dl, sdl_data);
                size_t nlen = (size_t)sdl->sdl_nlen;
                if (nlen > avail) {
                    nlen = avail;
                }
                if (nlen > 0 && nlen < IFNAMSIZ) {
                    char ifname[IFNAMSIZ];
                    memcpy(ifname, sdl->sdl_data, nlen);
                    ifname[nlen] = '\0';
                    return pt_is_hidden_network_ifname(ifname);
                }
            }
            return NO;
        }
        size_t step = (size_t)PT_RT_ROUNDUP((unsigned int)sa_len);
        if (step > (size_t)(end - cur)) {
            return NO;
        }
        cur += step;
    }
    return NO;
}

typedef struct {
    u_short msglen;
    u_char version;
    u_char type;
} pt_rt_msg_prefix_t;

static void pt_compact_rt_iflist_sysctl(void *buf, size_t *size) {
    if (buf == NULL || size == NULL || *size == 0) {
        return;
    }
    uint8_t *base = (uint8_t *)buf;
    size_t total = *size;
    size_t read_pos = 0;
    size_t write_pos = 0;
    uint16_t hidden_indices[64];
    size_t hidden_count = 0;
    BOOL skip_cur_if = NO;

    while (read_pos + sizeof(pt_rt_msg_prefix_t) <= total) {
        const uint8_t *msg = base + read_pos;
        pt_rt_msg_prefix_t pre;
        memcpy(&pre, msg, sizeof(pre));
        size_t msglen = (size_t)pre.msglen;
        if (msglen < sizeof(pt_rt_msg_prefix_t) || read_pos + msglen > total) {
            size_t rem = total - read_pos;
            if (write_pos != read_pos) {
                memmove(base + write_pos, base + read_pos, rem);
            }
            write_pos += rem;
            read_pos = total;
            break;
        }

        BOOL drop = NO;
        switch (pre.type) {
            case RTM_IFINFO:
                if (msglen >= sizeof(struct if_msghdr)) {
                    struct if_msghdr ifm;
                    memcpy(&ifm, msg, sizeof(ifm));
                    skip_cur_if = pt_rt_ifinfo_msg_has_hidden_ifname(
                        msg, msglen, sizeof(struct if_msghdr), ifm.ifm_addrs);
                    pt_u16_list_set_hidden(hidden_indices, &hidden_count, 64U, ifm.ifm_index, skip_cur_if);
                    drop = skip_cur_if;
                } else {
                    skip_cur_if = NO;
                }
                break;

            case RTM_IFINFO2:
                if (msglen >= sizeof(struct if_msghdr2)) {
                    struct if_msghdr2 ifm2;
                    memcpy(&ifm2, msg, sizeof(ifm2));
                    skip_cur_if = pt_rt_ifinfo_msg_has_hidden_ifname(
                        msg, msglen, sizeof(struct if_msghdr2), ifm2.ifm_addrs);
                    pt_u16_list_set_hidden(hidden_indices, &hidden_count, 64U, ifm2.ifm_index, skip_cur_if);
                    drop = skip_cur_if;
                } else {
                    skip_cur_if = NO;
                }
                break;

            case RTM_NEWADDR:
                if (msglen >= sizeof(struct ifa_msghdr)) {
                    struct ifa_msghdr ifam;
                    memcpy(&ifam, msg, sizeof(ifam));
                    drop = (skip_cur_if ||
                            pt_u16_list_contains(hidden_indices, hidden_count, ifam.ifam_index));
                }
                break;

            case RTM_NEWMADDR:
                if (msglen >= sizeof(struct ifma_msghdr)) {
                    struct ifma_msghdr ifmam;
                    memcpy(&ifmam, msg, sizeof(ifmam));
                    drop = (skip_cur_if ||
                            pt_u16_list_contains(hidden_indices, hidden_count, ifmam.ifmam_index));
                }
                break;

            case RTM_NEWMADDR2:
                if (msglen >= sizeof(struct ifma_msghdr2)) {
                    struct ifma_msghdr2 ifmam2;
                    memcpy(&ifmam2, msg, sizeof(ifmam2));
                    drop = (skip_cur_if ||
                            pt_u16_list_contains(hidden_indices, hidden_count, ifmam2.ifmam_index));
                }
                break;

            default:
                break;
        }

        if (!drop) {
            if (write_pos != read_pos) {
                memmove(base + write_pos, msg, msglen);
            }
            write_pos += msglen;
        }
        read_pos += msglen;
    }

    if (read_pos < total) {
        size_t rem = total - read_pos;
        if (write_pos != read_pos) {
            memmove(base + write_pos, base + read_pos, rem);
        }
        write_pos += rem;
    }
    *size = write_pos;
}

static gid_t pt_map_spoofed_gid(gid_t g);
static BOOL pt_is_desktop_supplemental_gid(gid_t g);

static void pt_sanitize_kinfo_proc(struct kinfo_proc *info, BOOL is_sys) {
    if (info == NULL) {
        return;
    }
    info->kp_proc.p_flag &= ~P_TRACED;
    if (is_sys || !pt_is_bypass_enabled()) {
        return;
    }
    info->kp_eproc.e_ppid = 1;
    strlcpy(info->kp_eproc.e_login, "mobile", sizeof(info->kp_eproc.e_login));
    info->kp_eproc.e_pcred.p_rgid = pt_map_spoofed_gid(info->kp_eproc.e_pcred.p_rgid);
    info->kp_eproc.e_pcred.p_svgid = pt_map_spoofed_gid(info->kp_eproc.e_pcred.p_svgid);
    size_t max_groups = sizeof(info->kp_eproc.e_ucred.cr_groups) / sizeof(info->kp_eproc.e_ucred.cr_groups[0]);
    short raw_n = info->kp_eproc.e_ucred.cr_ngroups;
    if (raw_n < 0) {
        raw_n = 0;
    }
    if ((size_t)raw_n > max_groups) {
        raw_n = (short)max_groups;
    }
    gid_t filtered[NGROUPS];
    size_t filtered_n = 0;
    for (short i = 0; i < raw_n && filtered_n < max_groups; i++) {
        gid_t g = info->kp_eproc.e_ucred.cr_groups[i];
        if (pt_is_desktop_supplemental_gid(g)) {
            continue;
        }
        g = pt_map_spoofed_gid(g);
        BOOL dup = NO;
        for (size_t j = 0; j < filtered_n; j++) {
            if (filtered[j] == g) {
                dup = YES;
                break;
            }
        }
        if (!dup) {
            filtered[filtered_n++] = g;
        }
    }
    if (filtered_n == 0) {
        filtered[0] = 501;
        filtered_n = 1;
    }
    for (size_t i = 0; i < filtered_n; i++) {
        info->kp_eproc.e_ucred.cr_groups[i] = filtered[i];
    }
    for (size_t i = filtered_n; i < max_groups; i++) {
        info->kp_eproc.e_ucred.cr_groups[i] = 0;
    }
    info->kp_eproc.e_ucred.cr_ngroups = (short)filtered_n;
}

__attribute__((visibility("hidden")))
int pt_sysctl_with_caller(int *name,
                          u_int types,
                          void *buf,
                          size_t *size,
                          void *arg0,
                          size_t arg1,
                          const void *ret_addr) {
    int is_sys_caller = -1;
    if (name != NULL && types >= 2) {
        if (name[0] == 0 &&
            pt_is_bypass_enabled() &&
            !pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
            if (name[1] == 3 && arg0 != NULL && arg1 > 0 && arg1 <= 512U) {
                char qname[513];
                size_t slen = strnlen((const char *)arg0, arg1);
                memcpy(qname, arg0, slen);
                qname[slen] = '\0';
                if (pt_is_hidden_sysctl_name(qname)) {
                    errno = ENOENT;
                    return -1;
                }
            } else if (name[1] == 1 && types >= 3) {
                char qname[512];
                size_t qlen = sizeof(qname) - 1U;
                if (pt_orig_kernel_sysctl(name, types, qname, &qlen, NULL, 0) == 0) {
                    qname[qlen < sizeof(qname) ? qlen : sizeof(qname) - 1U] = '\0';
                    if (pt_is_hidden_sysctl_name(qname)) {
                        errno = ENOENT;
                        return -1;
                    }
                }
            } else if ((name[1] == 2 || name[1] == 5) && types <= CTL_MAXNAME + 2) {
                int cur_q[CTL_MAXNAME + 2];
                memcpy(cur_q, name, (size_t)types * sizeof(int));
                u_int cur_qlen = types;
                for (int skip = 0; skip < 128; skip++) {
                    int next_oid[CTL_MAXNAME];
                    size_t next_sz = sizeof(next_oid);
                    int r = pt_orig_kernel_sysctl(cur_q, cur_qlen, next_oid, &next_sz, NULL, 0);
                    if (r != 0) {
                        return r;
                    }
                    if (next_sz == 0 || next_sz > sizeof(next_oid) || (next_sz % sizeof(int)) != 0) {
                        return pt_orig_kernel_sysctl(cur_q, cur_qlen, buf, size, arg0, arg1);
                    }
                    u_int next_cnt = (u_int)(next_sz / sizeof(int));
                    int name_q[CTL_MAXNAME + 2];
                    name_q[0] = 0;
                    name_q[1] = 1;
                    memcpy(name_q + 2, next_oid, next_sz);
                    char oid_name[512];
                    size_t oid_name_sz = sizeof(oid_name) - 1U;
                    if (pt_orig_kernel_sysctl(name_q, 2U + next_cnt, oid_name, &oid_name_sz, NULL, 0) == 0) {
                        oid_name[oid_name_sz < sizeof(oid_name) ? oid_name_sz : sizeof(oid_name) - 1U] = '\0';
                        if (pt_is_hidden_sysctl_name(oid_name)) {
                            cur_q[0] = 0;
                            cur_q[1] = name[1];
                            memcpy(cur_q + 2, next_oid, next_sz);
                            cur_qlen = 2U + next_cnt;
                            continue;
                        }
                    }
                    if (size == NULL) {
                        errno = EINVAL;
                        return -1;
                    }
                    if (buf == NULL) {
                        *size = next_sz;
                        return 0;
                    }
                    if (*size < next_sz) {
                        *size = next_sz;
                        errno = ENOMEM;
                        return -1;
                    }
                    memcpy(buf, next_oid, next_sz);
                    *size = next_sz;
                    return 0;
                }
                errno = ENOENT;
                return -1;
            }
        }
        if (name[0] == CTL_KERN) {
            if (types >= 4 && name[1] == KERN_PROC && name[2] == KERN_PROC_PID &&
                name[3] != getpid()) {
                if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                    errno = ESRCH;
                    return -1;
                }
            }
            if (types >= 3 && name[1] == KERN_PROC && name[2] != KERN_PROC_PID && buf == NULL && size != NULL &&
                pt_is_bypass_enabled() && !pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                *size = sizeof(struct kinfo_proc);
                return 0;
            }
            if (types >= 3 && (name[1] == KERN_PROCARGS || name[1] == KERN_PROCARGS2) &&
                pt_is_bypass_enabled() && !pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                return pt_handle_sysctl_procargs(name, types, buf, size);
            }
        }
        const char *mapped_name = pt_lookup_mib_name(name, types);
        if (mapped_name != NULL) {
            int sret = 0;
            if (pt_handle_sysctl_name(mapped_name, buf, size, arg0, arg1, ret_addr, &is_sys_caller, &sret)) {
                return sret;
            }
        }
        if ((name[0] == CTL_KERN || name[0] == CTL_HW) && pt_is_bypass_enabled()) {
            if (name[0] == CTL_KERN) {
                switch (name[1]) {
                    case KERN_OSTYPE:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            return pt_write_sysctl_string("Darwin", buf, size);
                        }
                        break;
                    case KERN_OSRELEASE:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            return pt_write_sysctl_string(pt_get_effective_kern_release(), buf, size);
                        }
                        break;
                    case KERN_OSVERSION:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            pt_ensure_host_kernel_info();
                            const char *ov_build = NULL;
                            (void)pt_get_reported_ios_version_override(&ov_build);
                            return pt_write_sysctl_string(ov_build != NULL ? ov_build : s_spoofed_osversion, buf, size);
                        }
                        break;
                    case KERN_VERSION:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            char kver[256];
                            pt_format_kernel_version(pt_get_active_device_profile(), kver, sizeof(kver));
                            return pt_write_sysctl_string(kver, buf, size);
                        }
                        break;
                    case KERN_HOSTNAME:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            return pt_write_sysctl_string(pt_get_active_device_profile()->is_ipad ? "iPad" : "iPhone", buf, size);
                        }
                        break;
                    case KERN_OSREV:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            return pt_write_sysctl_int(199506, buf, size);
                        }
                        break;
                    default:
                        break;
                }
            } else if (name[0] == CTL_HW) {
                switch (name[1]) {
                    case HW_MACHINE:
                    case HW_PRODUCT:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            return pt_write_sysctl_string(DEVICE_MODEL, buf, size);
                        }
                        break;
                    case HW_MODEL:
                    case HW_TARGET:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            return pt_write_sysctl_string(OEM_ID, buf, size);
                        }
                        break;
                    case HW_NCPU:
                    case HW_AVAILCPU:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            return pt_write_sysctl_int((int)pt_get_active_device_profile()->cores, buf, size);
                        }
                        break;
                    case HW_MEMSIZE:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            return pt_write_sysctl_uint64(buf, size, (arg1 > 0) ? arg0 : NULL, pt_get_active_device_profile()->ram_bytes);
                        }
                        break;
                    case HW_PHYSMEM:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            uint64_t ram = pt_get_active_device_profile()->ram_bytes;
                            uint32_t phys32 = (uint32_t)(ram > 0x80000000ULL ? 0x80000000U : ram);
                            return pt_write_sysctl_int((int)phys32, buf, size);
                        }
                        break;
                    case HW_PAGESIZE:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            return pt_write_sysctl_int(16384, buf, size);
                        }
                        break;
                    default:
                        break;
                }
            }
        }
    }
    // Fallback must not re-enter our ___sysctl interpose: libc's public sysctl()
    // forwards every non-CTL_USER MIB to __sysctl, which is interposed by
    // pt_kernel_sysctl and would recurse forever. Keep libc's userspace
    // CTL_USER handling, and call the original kernel entry for everything else.
    int ret = (name != NULL && types >= 1 && name[0] == CTL_USER)
        ? sysctl(name, types, buf, size, arg0, arg1)
        : pt_orig_kernel_sysctl(name, types, buf, size, arg0, arg1);
    if (ret == 0 && name != NULL && types >= 3 &&
        name[0] == CTL_KERN && name[1] == KERN_PROC && size != NULL) {
        BOOL is_sys = pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller);
        if (name[2] == KERN_PROC_PID) {
            if (buf != NULL && *size >= sizeof(struct kinfo_proc)) {
                pt_sanitize_kinfo_proc((struct kinfo_proc *)buf, is_sys);
            }
        } else if (name[2] == KERN_PROC_ALL ||
                   (!is_sys && name[2] != KERN_PROC_PID)) {
            pid_t self_pid = getpid();
            if (buf == NULL) {
                if (!is_sys) {
                    *size = sizeof(struct kinfo_proc);
                }
            } else if (*size >= sizeof(struct kinfo_proc)) {
                size_t count = *size / sizeof(struct kinfo_proc);
                struct kinfo_proc *entries = (struct kinfo_proc *)buf;
                BOOL found_self = NO;
                for (size_t i = 0; i < count; i++) {
                    if (entries[i].kp_proc.p_pid == self_pid) {
                        pt_sanitize_kinfo_proc(&entries[i], is_sys);
                        if (!is_sys) {
                            if (i != 0) {
                                entries[0] = entries[i];
                            }
                            *size = sizeof(struct kinfo_proc);
                        }
                        found_self = YES;
                        break;
                    }
                }
                if (!is_sys && !found_self) {
                    *size = 0;
                }
            }
        }
    }
    if (ret == 0 && name != NULL && types >= 5 &&
        name[0] == CTL_NET && name[1] == PF_ROUTE &&
        (name[4] == NET_RT_IFLIST || name[4] == NET_RT_IFLIST2
#ifdef NET_RT_IFLISTL
         || name[4] == NET_RT_IFLISTL
#endif
        ) &&
        buf != NULL && size != NULL && *size > 0 &&
        pt_is_bypass_enabled() &&
        !pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
        pt_compact_rt_iflist_sysctl(buf, size);
    }
    return ret;
}

static int pt_sysctl(int *name, u_int types, void *buf, size_t *size, void *arg0, size_t arg1) {
    return pt_sysctl_with_caller(name, types, buf, size, arg0, arg1, __builtin_return_address(0));
}

static int pt_kernel_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return pt_orig_kernel_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    }
    return pt_sysctl_with_caller(name, namelen, oldp, oldlenp, newp, newlen, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_sysctlbyname_with_caller(const char *name,
                                void *oldp,
                                size_t *oldlenp,
                                void *newp,
                                size_t newlen,
                                const void *caller) {
    if (name != NULL) {
        int is_sys_caller = -1;
        int sret = 0;
        if (pt_handle_sysctl_name(name, oldp, oldlenp, newp, newlen, caller, &is_sys_caller, &sret)) {
            PT_DEBUG_TRACE("spoofer", "spoofed sysctlbyname name=%s ret=%d", name, sret);
            return sret;
        }
    }
    return sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

static int pt_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    return pt_sysctlbyname_with_caller(name, oldp, oldlenp, newp, newlen, __builtin_return_address(0));
}

extern int pt_orig_kernel_sysctlbyname(const char *name,
                                       size_t namelen,
                                       void *oldp,
                                       size_t *oldlenp,
                                       void *newp,
                                       size_t newlen) __asm("___sysctlbyname");

static int pt_kernel_sysctlbyname(const char *name,
                                  size_t namelen,
                                  void *oldp,
                                  size_t *oldlenp,
                                  void *newp,
                                  size_t newlen) {
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return pt_orig_kernel_sysctlbyname(name, namelen, oldp, oldlenp, newp, newlen);
    }
    const void *caller = __builtin_return_address(0);
    if (name != NULL && namelen > 0 && namelen < 256U && pt_is_valid_user_pointer(name)) {
        char nbuf[256];
        size_t slen = strnlen(name, namelen);
        memcpy(nbuf, name, slen);
        nbuf[slen] = '\0';
        int is_sys_caller = -1;
        int sret = 0;
        if (pt_handle_sysctl_name(nbuf, oldp, oldlenp, newp, newlen, caller, &is_sys_caller, &sret)) {
            return sret;
        }
    }
    return pt_orig_kernel_sysctlbyname(name, namelen, oldp, oldlenp, newp, newlen);
}

__attribute__((visibility("hidden")))
BOOL pt_is_system_version_plist_dict(NSDictionary *dict) {
    if (![dict isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    if (![dict[@"ProductBuildVersion"] isKindOfClass:[NSString class]] ||
        dict[@"CFBundleIdentifier"] != nil ||
        dict[@"CFBundleExecutable"] != nil) {
        return NO;
    }
    if (dict[@"iOSSupportVersion"] != nil) {
        return YES;
    }
    id prodName = dict[@"ProductName"];
    if ([prodName isKindOfClass:[NSString class]] &&
        [dict[@"ProductVersion"] isKindOfClass:[NSString class]]) {
        NSString *pn = (NSString *)prodName;
        return ([pn isEqualToString:@"macOS"] ||
                [pn isEqualToString:@"Mac OS X"] ||
                [pn isEqualToString:@"iPhone OS"] ||
                [pn isEqualToString:@"iOS"]);
    }
    return NO;
}

__attribute__((visibility("hidden")))
BOOL pt_sanitize_ios_build_version_cstr(const char *build_cstr,
                                        const char *ios_ver_cstr,
                                        char *out_buf,
                                        size_t out_size) {
    pt_ensure_host_kernel_info();
    return pt_sanitize_ios_build_version_with_kern_major(
        build_cstr, ios_ver_cstr, atoi(s_real_kern_release), out_buf, out_size);
}

__attribute__((visibility("hidden")))
const char *pt_get_spoofed_ios_version_cstr(void) {
    pt_ensure_host_kernel_info();
    const char *ov_ver = pt_get_reported_ios_version_override(NULL);
    if (ov_ver != NULL && ov_ver[0] != '\0') {
        return ov_ver;
    }
    return s_spoofed_ios_version;
}

__attribute__((visibility("hidden")))
void pt_sanitize_system_version_dict(NSMutableDictionary *dict) {
    if (dict == nil) {
        return;
    }
    const char *ov_build = NULL;
    const char *ov_ver = pt_get_reported_ios_version_override(&ov_build);
    if (ov_ver != NULL && ov_build != NULL) {
        NSString *verStr = [NSString stringWithUTF8String:ov_ver];
        if (verStr != nil) {
            dict[@"ProductVersion"] = verStr;
            if (dict[@"ProductUserVisibleVersion"] != nil) {
                dict[@"ProductUserVisibleVersion"] = verStr;
            }
        }
        [dict removeObjectForKey:@"iOSSupportVersion"];
        NSString *buildStr = [NSString stringWithUTF8String:ov_build];
        if (buildStr != nil) {
            dict[@"ProductBuildVersion"] = buildStr;
        }
        dict[@"ProductName"] = @"iPhone OS";
        return;
    }
    pt_ensure_host_kernel_info();
    id origProdName = dict[@"ProductName"];
    BOOL origWasMac = ([origProdName isKindOfClass:[NSString class]] &&
                       ([(NSString *)origProdName isEqualToString:@"macOS"] ||
                        [(NSString *)origProdName isEqualToString:@"Mac OS X"]));
    id iosVer = dict[@"iOSSupportVersion"];
    BOOL copiedIOSVer = NO;
    if ([iosVer isKindOfClass:[NSString class]] && [(NSString *)iosVer length] > 0) {
        NSString *iosStr = (NSString *)iosVer;
        int parsedMaj = atoi([iosStr UTF8String]);
        if (parsedMaj >= 11 && (parsedMaj <= 18 || parsedMaj >= 26)) {
            dict[@"ProductVersion"] = iosStr;
            if (dict[@"ProductUserVisibleVersion"] != nil) {
                dict[@"ProductUserVisibleVersion"] = iosStr;
            }
            copiedIOSVer = YES;
        }
    }
    [dict removeObjectForKey:@"iOSSupportVersion"];

    if (origWasMac && !copiedIOSVer) {
        NSString *derivedVer = nil;
        id macVerObj = dict[@"ProductVersion"];
        if ([macVerObj isKindOfClass:[NSString class]] && [(NSString *)macVerObj length] > 0) {
            int macMaj = 0, macMin = 0, macPat = 0;
            int nscan = sscanf([(NSString *)macVerObj UTF8String], "%d.%d.%d", &macMaj, &macMin, &macPat);
            if (nscan >= 1 && macMaj >= 11 && macMaj <= 15) {
                int iosMaj = macMaj + 3;
                derivedVer = (nscan >= 3 && macPat > 0)
                    ? [NSString stringWithFormat:@"%d.%d.%d", iosMaj, macMin, macPat]
                    : [NSString stringWithFormat:@"%d.%d", iosMaj, (nscan >= 2 ? macMin : 0)];
            } else if (nscan >= 1 && macMaj >= 26) {
                derivedVer = (NSString *)macVerObj;
            }
        }
        if (derivedVer == nil && dict[@"ProductBuildVersion"] != nil &&
            [dict[@"ProductBuildVersion"] isKindOfClass:[NSString class]]) {
            int bPrefix = atoi([(NSString *)dict[@"ProductBuildVersion"] UTF8String]);
            if (bPrefix >= 19 && bPrefix <= 99) {
                char fbuf[32];
                pt_fallback_ios_version_for_kern_major(bPrefix, fbuf, sizeof(fbuf));
                derivedVer = [NSString stringWithUTF8String:fbuf];
            }
        }
        if (derivedVer == nil && s_spoofed_ios_version[0] != '\0') {
            derivedVer = [NSString stringWithUTF8String:s_spoofed_ios_version];
        }
        if (derivedVer != nil) {
            dict[@"ProductVersion"] = derivedVer;
            if (dict[@"ProductUserVisibleVersion"] != nil) {
                dict[@"ProductUserVisibleVersion"] = derivedVer;
            }
        }
    } else if (!origWasMac) {
        id curProdVer = dict[@"ProductVersion"];
        if (![curProdVer isKindOfClass:[NSString class]] || [(NSString *)curProdVer length] == 0) {
            NSString *fallbackVer = [NSString stringWithUTF8String:s_spoofed_ios_version];
            if (fallbackVer.length > 0) {
                dict[@"ProductVersion"] = fallbackVer;
                if (dict[@"ProductUserVisibleVersion"] != nil) {
                    dict[@"ProductUserVisibleVersion"] = fallbackVer;
                }
            }
        } else {
            int pvMaj = atoi([(NSString *)curProdVer UTF8String]);
            if (pvMaj < 11 || (pvMaj >= 19 && pvMaj <= 25)) {
                NSString *fallbackVer = [NSString stringWithUTF8String:s_spoofed_ios_version];
                if (fallbackVer.length > 0) {
                    dict[@"ProductVersion"] = fallbackVer;
                    if (dict[@"ProductUserVisibleVersion"] != nil) {
                        dict[@"ProductUserVisibleVersion"] = fallbackVer;
                    }
                }
            }
        }
    }

    id prodVer = dict[@"ProductVersion"];
    const char *iosVerCStr = [prodVer isKindOfClass:[NSString class]] ? [(NSString *)prodVer UTF8String] : NULL;
    id buildVer = dict[@"ProductBuildVersion"];
    const char *rawBuildCStr = [buildVer isKindOfClass:[NSString class]] ? [(NSString *)buildVer UTF8String] : "";
    char sanitized[64] = {0};
    if (pt_sanitize_ios_build_version_cstr(rawBuildCStr,
                                           iosVerCStr,
                                           sanitized,
                                           sizeof(sanitized))) {
        NSString *mapped = [NSString stringWithUTF8String:sanitized];
        if (mapped != nil) {
            dict[@"ProductBuildVersion"] = mapped;
        }
    }
    dict[@"ProductName"] = @"iPhone OS";
}

extern CFDictionaryRef _CFCopySystemVersionDictionary(void);
static CFDictionaryRef pt_CFCopySystemVersionDictionary(void) {
    CFDictionaryRef orig = _CFCopySystemVersionDictionary();
    if (orig == NULL) {
        return NULL;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        NSMutableDictionary *dict = [(__bridge NSDictionary *)orig mutableCopy];
        CFRelease(orig);
        pt_sanitize_system_version_dict(dict);
        return (__bridge_retained CFDictionaryRef)[dict copy];
    }
    return orig;
}

static NSMutableDictionary *pt_sanitize_code_resources_subdict(NSDictionary *sub) {
    NSMutableDictionary *clean = nil;
    for (id key in sub) {
        if ([key isKindOfClass:[NSString class]]) {
            NSString *k = (NSString *)key;
            if ([k containsString:@"PlayTools"] ||
                [k containsString:@"AKInterface"] ||
                [k containsString:@"Playtools.strings"] ||
                [k containsString:@"UserPlugins"]) {
                if (clean == nil) {
                    clean = [sub mutableCopy];
                }
                [clean removeObjectForKey:key];
            }
        }
    }
    return clean;
}

static NSMutableDictionary *pt_maybe_sanitize_info_plist_dict(NSDictionary *dict) {
    if (!pt_is_info_plist_dict(dict) || !pt_info_dict_needs_sanitize(dict)) {
        return nil;
    }
    return pt_build_sanitized_mutable_info_dict(dict);
}

static CFPropertyListRef pt_CFPropertyListCreateWithData(CFAllocatorRef allocator, CFDataRef data, CFOptionFlags options, CFPropertyListFormat *format, CFErrorRef *error) {
    CFPropertyListRef plist = CFPropertyListCreateWithData(allocator, data, options, format, error);
    if (plist != NULL && CFGetTypeID(plist) == CFDictionaryGetTypeID()) {
        NSDictionary *dict = (__bridge NSDictionary *)plist;
        BOOL isSysVer = pt_is_system_version_plist_dict(dict);
        BOOL isCodeRes = ([dict[@"files"] isKindOfClass:[NSDictionary class]] ||
                          [dict[@"files2"] isKindOfClass:[NSDictionary class]]);
        BOOL isInfoPlist = (dict[@"CFBundleIdentifier"] != nil || dict[@"CFBundleExecutable"] != nil);
        if ((isSysVer || isCodeRes || isInfoPlist) &&
            pt_is_bypass_enabled() &&
            !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
            BOOL immutable = (options == kCFPropertyListImmutable);
            if (isSysVer) {
                NSMutableDictionary *modified = [dict mutableCopy];
                pt_sanitize_system_version_dict(modified);
                CFRelease(plist);
                return (__bridge_retained CFPropertyListRef)(immutable ? [modified copy] : modified);
            }
            if (isCodeRes) {
                NSMutableDictionary *cleanFiles = [dict[@"files"] isKindOfClass:[NSDictionary class]] ? pt_sanitize_code_resources_subdict(dict[@"files"]) : nil;
                NSMutableDictionary *cleanFiles2 = [dict[@"files2"] isKindOfClass:[NSDictionary class]] ? pt_sanitize_code_resources_subdict(dict[@"files2"]) : nil;
                if (cleanFiles != nil || cleanFiles2 != nil) {
                    NSMutableDictionary *modified = [dict mutableCopy];
                    if (cleanFiles != nil) modified[@"files"] = immutable ? [cleanFiles copy] : cleanFiles;
                    if (cleanFiles2 != nil) modified[@"files2"] = immutable ? [cleanFiles2 copy] : cleanFiles2;
                    CFRelease(plist);
                    return (__bridge_retained CFPropertyListRef)(immutable ? [modified copy] : modified);
                }
            }
            if (isInfoPlist) {
                NSMutableDictionary *modified = pt_maybe_sanitize_info_plist_dict(dict);
                if (modified != nil) {
                    if (immutable && [modified[@"CFBundleSupportedPlatforms"] isKindOfClass:[NSMutableArray class]]) {
                        modified[@"CFBundleSupportedPlatforms"] = [modified[@"CFBundleSupportedPlatforms"] copy];
                    }
                    CFRelease(plist);
                    return (__bridge_retained CFPropertyListRef)(immutable ? [modified copy] : modified);
                }
            }
        }
    }
    return plist;
}

static NSArray<NSString *> *pt_blocked_ioreg_keys_list(void) {
    static NSArray<NSString *> *s_keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_keys = @[
            @"serial-number", @"IOPlatformSerialNumber", @"SystemSerialNumber",
            @"IOPlatformUUID", @"mlb-serial-number", @"board-id",
            @"CompatibleDeviceFallback", @"has-boot-chime", @"boot-args",
            @"IONVRAM", @"efi-boot-device",
            @"AppleClamshellState", @"HibernateMode", @"HibernateFile",
            @"AppleRawAdapterDetails", @"AdapterDetails"
        ];
    });
    return s_keys;
}

static NSArray<NSString *> *pt_spoofed_ioreg_keys_list(void) {
    static NSArray<NSString *> *s_keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_keys = @[
            @"model", @"target-type", @"target-sub-type", @"compatible",
            @"model-number", @"regulatory-model-number", @"region-info", @"platform-name",
            @"product-name", @"manufacturer", @"gpu-core-count", @"metal-plugin-name"
        ];
    });
    return s_keys;
}

static BOOL pt_is_blocked_ioreg_key(CFStringRef key) {
    if (key == NULL) {
        return NO;
    }
    NSString *kstr = (__bridge NSString *)key;
    for (NSString *blocked in pt_blocked_ioreg_keys_list()) {
        if ([kstr isEqualToString:blocked]) {
            return YES;
        }
    }
    return NO;
}

static BOOL pt_is_spoofed_ioreg_key(CFStringRef key) {
    if (key == NULL) {
        return NO;
    }
    NSString *kstr = (__bridge NSString *)key;
    for (NSString *spoof in pt_spoofed_ioreg_keys_list()) {
        if ([kstr isEqualToString:spoof]) {
            return YES;
        }
    }
    return NO;
}

static CFTypeRef pt_create_ioreg_cstr_like(const char *cstr, CFTypeRef orig_val, CFAllocatorRef allocator) CF_RETURNS_RETAINED {
    if (cstr == NULL) {
        return NULL;
    }
    if (orig_val != NULL && CFGetTypeID(orig_val) == CFStringGetTypeID()) {
        return CFStringCreateWithCString(allocator, cstr, kCFStringEncodingUTF8);
    }
    return CFDataCreate(allocator, (const UInt8 *)cstr, (CFIndex)(strlen(cstr) + 1));
}

static CFTypeRef pt_spoof_ioreg_value_for_key(CFStringRef key, CFTypeRef orig_val, CFAllocatorRef allocator) CF_RETURNS_RETAINED {
    if (key == NULL || orig_val == NULL) {
        return NULL;
    }
    const pt_device_profile_t *profile = pt_get_active_device_profile();
    if (CFStringCompare(key, CFSTR("model"), 0) == kCFCompareEqualTo) {
        return pt_create_ioreg_cstr_like(profile->model, orig_val, allocator);
    }
    if (CFStringCompare(key, CFSTR("target-type"), 0) == kCFCompareEqualTo ||
        CFStringCompare(key, CFSTR("target-sub-type"), 0) == kCFCompareEqualTo) {
        return pt_create_ioreg_cstr_like(profile->oem_id, orig_val, allocator);
    }
    if (CFStringCompare(key, CFSTR("compatible"), 0) == kCFCompareEqualTo) {
        if (CFGetTypeID(orig_val) == CFStringGetTypeID()) {
            return CFStringCreateWithCString(allocator, profile->oem_id, kCFStringEncodingUTF8);
        }
        return pt_create_compatible_cfdata(allocator);
    }
    if (CFStringCompare(key, CFSTR("model-number"), 0) == kCFCompareEqualTo) {
        return pt_create_ioreg_cstr_like(profile->model_number, orig_val, allocator);
    }
    if (CFStringCompare(key, CFSTR("regulatory-model-number"), 0) == kCFCompareEqualTo) {
        return pt_create_ioreg_cstr_like(profile->regulatory_model, orig_val, allocator);
    }
    if (CFStringCompare(key, CFSTR("region-info"), 0) == kCFCompareEqualTo) {
        return pt_create_ioreg_cstr_like("LL/A", orig_val, allocator);
    }
    if (CFStringCompare(key, CFSTR("platform-name"), 0) == kCFCompareEqualTo) {
        return pt_create_ioreg_cstr_like("iphoneos", orig_val, allocator);
    }
    if (CFStringCompare(key, CFSTR("product-name"), 0) == kCFCompareEqualTo) {
        return pt_create_ioreg_cstr_like(profile->marketing_name, orig_val, allocator);
    }
    if (CFStringCompare(key, CFSTR("manufacturer"), 0) == kCFCompareEqualTo) {
        return pt_create_ioreg_cstr_like("Apple Inc.", orig_val, allocator);
    }
    if (CFStringCompare(key, CFSTR("gpu-core-count"), 0) == kCFCompareEqualTo) {
        if (CFGetTypeID(orig_val) == CFNumberGetTypeID()) {
            int32_t cores = (int32_t)profile->gpu_cores;
            return CFNumberCreate(allocator, kCFNumberSInt32Type, &cores);
        }
        if (CFGetTypeID(orig_val) == CFDataGetTypeID() && CFDataGetLength((CFDataRef)orig_val) == sizeof(uint32_t)) {
            uint32_t cores = profile->gpu_cores;
            return CFDataCreate(allocator, (const UInt8 *)&cores, sizeof(cores));
        }
        return NULL;
    }
    if (CFStringCompare(key, CFSTR("metal-plugin-name"), 0) == kCFCompareEqualTo) {
        char plugin[64];
        const char *ggen = (profile->gpu_gen != NULL) ? profile->gpu_gen : "G13G";
        snprintf(plugin, sizeof(plugin), "AGXMetal%s", ggen);
        return pt_create_ioreg_cstr_like(plugin, orig_val, allocator);
    }
    return NULL;
}

CFTypeRef IORegistryEntryCreateCFProperty(mach_port_t entry, CFStringRef key, CFAllocatorRef allocator, uint32_t options) CF_RETURNS_RETAINED;
static CFTypeRef pt_IORegistryEntryCreateCFProperty(mach_port_t entry, CFStringRef key, CFAllocatorRef allocator, uint32_t options) CF_RETURNS_RETAINED {
    if (entry == MACH_PORT_NULL) {
        return NULL;
    }
    if (key != NULL && pt_is_blocked_ioreg_key(key) &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NULL;
    }
    CFTypeRef orig = IORegistryEntryCreateCFProperty(entry, key, allocator, options);
    if (orig != NULL && key != NULL && pt_is_spoofed_ioreg_key(key) &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        CFTypeRef spoofed = pt_spoof_ioreg_value_for_key(key, orig, allocator);
        if (spoofed != NULL) {
            CFRelease(orig);
            return spoofed;
        }
    }
    return orig;
}

CFTypeRef IORegistryEntrySearchCFProperty(mach_port_t entry, const char *plane, CFStringRef key, CFAllocatorRef allocator, uint32_t options) CF_RETURNS_RETAINED;
static CFTypeRef pt_IORegistryEntrySearchCFProperty(mach_port_t entry, const char *plane, CFStringRef key, CFAllocatorRef allocator, uint32_t options) CF_RETURNS_RETAINED {
    if (entry == MACH_PORT_NULL) {
        return NULL;
    }
    if (key != NULL && pt_is_blocked_ioreg_key(key) &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NULL;
    }
    CFTypeRef orig = IORegistryEntrySearchCFProperty(entry, plane, key, allocator, options);
    if (orig != NULL && key != NULL && pt_is_spoofed_ioreg_key(key) &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        CFTypeRef spoofed = pt_spoof_ioreg_value_for_key(key, orig, allocator);
        if (spoofed != NULL) {
            CFRelease(orig);
            return spoofed;
        }
    }
    return orig;
}

kern_return_t IORegistryEntryCreateCFProperties(mach_port_t entry, CFMutableDictionaryRef *properties, CFAllocatorRef allocator, uint32_t options);
static kern_return_t pt_IORegistryEntryCreateCFProperties(mach_port_t entry, CFMutableDictionaryRef *properties, CFAllocatorRef allocator, uint32_t options) {
    if (entry == MACH_PORT_NULL) {
        return KERN_INVALID_ARGUMENT;
    }
    kern_return_t kr = IORegistryEntryCreateCFProperties(entry, properties, allocator, options);
    if (kr == KERN_SUCCESS && properties != NULL && *properties != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        NSMutableDictionary *dict = (__bridge NSMutableDictionary *)(*properties);
        for (NSString *k in pt_blocked_ioreg_keys_list()) {
            [dict removeObjectForKey:k];
        }
        for (NSString *k in pt_spoofed_ioreg_keys_list()) {
            id cur = dict[k];
            if (cur != nil) {
                CFTypeRef repl = pt_spoof_ioreg_value_for_key((__bridge CFStringRef)k, (__bridge CFTypeRef)cur, allocator);
                if (repl != NULL) {
                    dict[k] = (__bridge_transfer id)repl;
                }
            }
        }
    }
    return kr;
}

static void pt_sanitize_io_hardware_name(char *buf, size_t cap);
static BOOL pt_is_hidden_io_class_or_name(const char *cls_name, const char *entry_name);

static BOOL pt_is_hidden_io_path(const char *path) {
    if (path == NULL || path[0] == '\0') {
        return NO;
    }
    if (strstr(path, "AppleACPIPlatformExpert") != NULL ||
        strstr(path, "AppleSMC") != NULL ||
        strstr(path, "Mac") != NULL) {
        return YES;
    }
    const char *p = path;
    while (*p != '\0') {
        while (*p == '/' || *p == ':') {
            p++;
        }
        if (*p == '\0') {
            break;
        }
        const char *seg_start = p;
        while (*p != '\0' && *p != '/' && *p != ':') {
            p++;
        }
        const char *seg_end = p;
        const char *at = memchr(seg_start, '@', (size_t)(seg_end - seg_start));
        if (at != NULL) {
            seg_end = at;
        }
        size_t seg_len = (size_t)(seg_end - seg_start);
        if (seg_len > 0 && seg_len < 128U) {
            char comp[128];
            memcpy(comp, seg_start, seg_len);
            comp[seg_len] = '\0';
            if (pt_is_hidden_io_class_or_name(comp, comp)) {
                return YES;
            }
        }
    }
    return NO;
}

extern kern_return_t IORegistryEntryGetPath(mach_port_t entry, const char *plane, char *path);
static kern_return_t pt_IORegistryEntryGetPath(mach_port_t entry, const char *plane, char *path) {
    kern_return_t kr = IORegistryEntryGetPath(entry, plane, path);
    if (kr == KERN_SUCCESS && path != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_is_hidden_io_path(path)) {
            strlcpy(path, "IOService:/AppleARMPE", 512);
        } else {
            pt_sanitize_io_hardware_name(path, 512U);
        }
    }
    return kr;
}

static BOOL pt_is_blocked_ioservice_matching(CFDictionaryRef matching) {
    if (matching == NULL || CFGetTypeID(matching) != CFDictionaryGetTypeID()) {
        return NO;
    }
    NSDictionary *dict = (__bridge NSDictionary *)matching;
    id prov = dict[@"IOProviderClass"];
    if ([prov isKindOfClass:[NSString class]]) {
        const char *pc = [(NSString *)prov UTF8String];
        if (pc != NULL && pt_is_hidden_io_class_or_name(pc, pc)) {
            return YES;
        }
    }
    id nameMatch = dict[@"IONameMatch"];
    if ([nameMatch isKindOfClass:[NSString class]]) {
        const char *nc = [(NSString *)nameMatch UTF8String];
        if (nc != NULL && pt_is_hidden_io_class_or_name(nc, nc)) {
            return YES;
        }
    } else if ([nameMatch isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)nameMatch) {
            if ([item isKindOfClass:[NSString class]]) {
                const char *ic = [(NSString *)item UTF8String];
                if (ic != NULL && pt_is_hidden_io_class_or_name(ic, ic)) {
                    return YES;
                }
            }
        }
    }
    return NO;
}

extern mach_port_t IOServiceGetMatchingService(mach_port_t mainPort, CFDictionaryRef matching);
static mach_port_t pt_IOServiceGetMatchingService(mach_port_t mainPort, CFDictionaryRef matching) {
    if (matching != NULL && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_blocked_ioservice_matching(matching)) {
        CFRelease(matching);
        return MACH_PORT_NULL;
    }
    return IOServiceGetMatchingService(mainPort, matching);
}

extern kern_return_t IOServiceGetMatchingServices(mach_port_t mainPort, CFDictionaryRef matching, uint32_t *existing);
static kern_return_t pt_IOServiceGetMatchingServices(mach_port_t mainPort, CFDictionaryRef matching, uint32_t *existing) {
    if (matching != NULL && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_blocked_ioservice_matching(matching)) {
        CFRelease(matching);
        if (existing != NULL) {
            *existing = MACH_PORT_NULL;
        }
        return KERN_SUCCESS;
    }
    return IOServiceGetMatchingServices(mainPort, matching, existing);
}

static BOOL pt_is_hidden_io_class_or_name(const char *cls_name, const char *entry_name) {
    const char *names[2] = { cls_name, entry_name };
    for (int i = 0; i < 2; i++) {
        const char *s = names[i];
        if (s == NULL || s[0] == '\0') {
            continue;
        }
        if (strstr(s, "Mac") != NULL ||
            strncmp(s, "AppleSMC", 8) == 0 ||
            strstr(s, "EndpointSecurity") != NULL ||
            strcmp(s, "IOBluetoothACPIMethods") == 0 ||
            strcmp(s, "AppleMultitouchTrackpadHIDEventDriver") == 0 ||
            strcmp(s, "AppleActuatorHIDEventDriver") == 0 ||
            strcmp(s, "AppleHIDKeyboardEventDriverV2") == 0 ||
            strncmp(s, "AppleHIDTransport", 17) == 0 ||
            strstr(s, "ATCDPXBAR") != NULL ||
            strstr(s, "AppleParadeDP855TCON") != NULL ||
            strstr(s, "AppleATCDPAltModePort") != NULL ||
            strstr(s, "AppleATCDPINAdapterPort") != NULL ||
            strstr(s, "AppleDisplayCrossbar") != NULL ||
            strcmp(s, "IOHIDSystem") == 0 ||
            strncmp(s, "AppleAuthCPDock", 15) == 0 ||
            strncmp(s, "AppleExternalSecondaryAudio", 27) == 0 ||
            strncmp(s, "AppleSmartBattery", 17) == 0) {
            return YES;
        }
    }
    if (cls_name != NULL && cls_name[0] != '\0') {
        if (strncmp(cls_name, "AppleACPI", 9) == 0 ||
            strncmp(cls_name, "AppleSMBus", 10) == 0 ||
            strncmp(cls_name, "IOThunderbolt", 13) == 0 ||
            strncmp(cls_name, "AppleThunderbolt", 16) == 0 ||
            strcmp(cls_name, "AppleBacklightDisplay") == 0 ||
            strcmp(cls_name, "IODisplayWrangler") == 0 ||
            strcmp(cls_name, "AGPM") == 0) {
            return YES;
        }
    }
    return NO;
}

static void pt_replace_substr_in_buf(char *buf, size_t cap, const char *needle, const char *repl) {
    if (buf == NULL || cap == 0 || needle == NULL || repl == NULL) {
        return;
    }
    size_t nlen = strlen(needle);
    size_t rlen = strlen(repl);
    if (nlen == 0 || strcmp(needle, repl) == 0) {
        return;
    }
    size_t pos = 0;
    for (int guard = 0; guard < 16; guard++) {
        char *hit = strstr(buf + pos, needle);
        if (hit == NULL) {
            break;
        }
        size_t off = (size_t)(hit - buf);
        size_t cur_len = strlen(buf);
        if (cur_len - nlen + rlen >= cap) {
            break;
        }
        if (rlen != nlen) {
            memmove(hit + rlen, hit + nlen, cur_len - off - nlen + 1U);
        }
        memcpy(hit, repl, rlen);
        pos = off + rlen;
    }
}

static void pt_replace_agx_gen_tokens(char *buf,
                                      size_t cap,
                                      const char *prefix_with_g,
                                      const char *prefix_no_g,
                                      const char *gpu_gen,
                                      unsigned long target_gen) {
    if (buf == NULL || cap == 0 || prefix_with_g == NULL || prefix_no_g == NULL || gpu_gen == NULL) {
        return;
    }
    size_t plen = strlen(prefix_with_g);
    size_t target_len = strlen(gpu_gen);
    char repl[64];
    int rn = snprintf(repl, sizeof(repl), "%s%s", prefix_no_g, gpu_gen);
    if (rn <= 0 || (size_t)rn >= sizeof(repl)) {
        return;
    }
    size_t rlen = (size_t)rn;
    size_t pos = 0;
    for (int guard = 0; guard < 16; guard++) {
        char *hit = strstr(buf + pos, prefix_with_g);
        if (hit == NULL) {
            break;
        }
        if (hit[plen] < '0' || hit[plen] > '9') {
            pos = (size_t)(hit - buf) + plen;
            continue;
        }
        char *endp = NULL;
        unsigned long gen = strtoul(hit + plen, &endp, 10);
        if (endp == NULL || endp == hit + plen) {
            pos = (size_t)(hit - buf) + plen;
            continue;
        }
        if (*endp != '\0' && strchr("GPSXCDgpsxcd", *endp) != NULL) {
            endp++;
        }
        size_t tok_gen_len = (size_t)(endp - (hit + plen - 1U));
        BOOL mismatch = (gen != target_gen) ||
                        (pt_is_compat13_7_active() && gen >= 13UL) ||
                        (tok_gen_len != target_len) ||
                        (strncmp(hit + plen - 1U, gpu_gen, target_len) != 0);
        size_t span_len = (size_t)(endp - hit);
        size_t off = (size_t)(hit - buf);
        if (mismatch) {
            size_t cur_len = strlen(buf);
            if (cur_len - span_len + rlen >= cap) {
                break;
            }
            if (rlen != span_len) {
                memmove(hit + rlen, endp, cur_len - off - span_len + 1U);
            }
            memcpy(hit, repl, rlen);
            pos = off + rlen;
        } else {
            pos = off + span_len;
        }
    }
}

static void pt_sanitize_io_hardware_name(char *buf, size_t cap) {
    if (buf == NULL || cap == 0 || buf[0] == '\0') {
        return;
    }
    const pt_device_profile_t *profile = pt_get_active_device_profile();
    const char *lower_soc = (profile != NULL && profile->soc_code != NULL) ? profile->soc_code : "t8103";
    char upper_soc[16] = {0};
    for (size_t i = 0; i + 1U < sizeof(upper_soc) && lower_soc[i] != '\0'; i++) {
        char c = lower_soc[i];
        upper_soc[i] = (c >= 'a' && c <= 'z') ? (char)(c - 'a' + 'A') : c;
    }
    const char *gpu_gen = (profile != NULL && profile->gpu_gen != NULL) ? profile->gpu_gen : "G13G";
    char gpu_short[8] = "G13";
    if (gpu_gen[0] == 'G' && gpu_gen[1] >= '0' && gpu_gen[1] <= '9') {
        size_t gl = 2U;
        while (gl + 1U < sizeof(gpu_short) && gpu_gen[gl] >= '0' && gpu_gen[gl] <= '9') {
            gl++;
        }
        memcpy(gpu_short, gpu_gen, gl);
        gpu_short[gl] = '\0';
    }
    const char *isp_gen = (strcmp(upper_soc, "T8027") == 0 || strcmp(upper_soc, "T8000") == 0)
        ? "H11"
        : (strcmp(upper_soc, "T8030") == 0 ? "H12" : "H13");

    static const char *const kHostSocs[] = {
        "T8103", "T8101", "T8102", "T810x", "T8112", "T8122", "T8132", "T8142",
        "T6000", "T6001", "T6002", "T6020", "T6021", "T6022",
        "T6030", "T6031", "T6034", "T6040", "T6041"
    };
    static const char *const kHostSocsLower[] = {
        "t8103", "t8101", "t8102", "t810x", "t8112", "t8122", "t8132", "t8142",
        "t6000", "t6001", "t6002", "t6020", "t6021", "t6022",
        "t6030", "t6031", "t6034", "t6040", "t6041"
    };
    for (size_t i = 0; i < sizeof(kHostSocs) / sizeof(kHostSocs[0]); i++) {
        if (strcmp(kHostSocs[i], upper_soc) != 0) {
            pt_replace_substr_in_buf(buf, cap, kHostSocs[i], upper_soc);
            pt_replace_substr_in_buf(buf, cap, kHostSocsLower[i], lower_soc);
        }
    }

    unsigned long target_gen = strtoul(gpu_short + 1, NULL, 10);
    pt_replace_agx_gen_tokens(buf, cap, "AGXAcceleratorG", "AGXAccelerator", gpu_gen, target_gen);
    pt_replace_agx_gen_tokens(buf, cap, "AGXMetalG", "AGXMetal", gpu_gen, target_gen);
    pt_replace_agx_gen_tokens(buf, cap, "AGXFirmwareKextG", "AGXFirmwareKext", gpu_gen, target_gen);

    static const char *const kGpuShorts[] = { "G13", "G14", "G15", "G16", "G17", "G18" };
    static const char *const kIspGens[] = { "H13", "H14", "H15", "H16" };
    if (strstr(buf, "AGXFirmwareKext") != NULL || pt_is_compat13_7_active() || strcmp(upper_soc, "T8103") != 0) {
        if (strstr(buf, "AGX") != NULL &&
            strstr(buf, "AGXAccelerator") == NULL &&
            strstr(buf, "AGXMetal") == NULL &&
            strstr(buf, "AGXFirmwareKext") == NULL) {
            for (size_t i = 0; i < sizeof(kGpuShorts) / sizeof(kGpuShorts[0]); i++) {
                if (strcmp(kGpuShorts[i], gpu_short) != 0) {
                    pt_replace_substr_in_buf(buf, cap, kGpuShorts[i], gpu_short);
                }
            }
        }
        if (strstr(buf, "CamIn") != NULL) {
            for (size_t i = 0; i < sizeof(kIspGens) / sizeof(kIspGens[0]); i++) {
                if (strcmp(kIspGens[i], isp_gen) != 0) {
                    pt_replace_substr_in_buf(buf, cap, kIspGens[i], isp_gen);
                }
            }
        }
    }
}

static kern_return_t pt_IOObjectGetClass(io_object_t object, io_name_t className) {
    kern_return_t kr = IOObjectGetClass(object, className);
    if (kr == KERN_SUCCESS && className != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (strncmp(className, "AppleACPI", 9) == 0) {
            strlcpy(className, "AppleARMPE", sizeof(io_name_t));
        } else if (pt_is_hidden_io_class_or_name(className, NULL)) {
            strlcpy(className, "IOService", sizeof(io_name_t));
        } else {
            pt_sanitize_io_hardware_name(className, sizeof(io_name_t));
        }
    }
    return kr;
}

static boolean_t pt_IOObjectConformsTo(io_object_t object, const io_name_t className) {
    if (className != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_hidden_io_class_or_name(className, NULL)) {
        return FALSE;
    }
    return IOObjectConformsTo(object, className);
}

static kern_return_t pt_IORegistryEntryGetName(io_registry_entry_t entry, io_name_t name) {
    kern_return_t kr = IORegistryEntryGetName(entry, name);
    if (kr == KERN_SUCCESS && name != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_is_hidden_io_class_or_name(NULL, name)) {
            strlcpy(name, "IOService", sizeof(io_name_t));
        } else {
            pt_sanitize_io_hardware_name(name, sizeof(io_name_t));
        }
    }
    return kr;
}

static kern_return_t pt_IORegistryEntryGetNameInPlane(io_registry_entry_t entry,
                                                     const io_name_t plane,
                                                     io_name_t name) {
    kern_return_t kr = IORegistryEntryGetNameInPlane(entry, plane, name);
    if (kr == KERN_SUCCESS && name != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_is_hidden_io_class_or_name(NULL, name)) {
            strlcpy(name, "IOService", sizeof(io_name_t));
        } else {
            pt_sanitize_io_hardware_name(name, sizeof(io_name_t));
        }
    }
    return kr;
}

static io_object_t pt_IOIteratorNext(io_iterator_t iterator) {
    if (!pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return IOIteratorNext(iterator);
    }
    for (int guard = 0; guard < 16384; guard++) {
        io_object_t obj = IOIteratorNext(iterator);
        if (obj == MACH_PORT_NULL) {
            return MACH_PORT_NULL;
        }
        io_name_t cls = {0};
        io_name_t name = {0};
        (void)IOObjectGetClass(obj, cls);
        (void)IORegistryEntryGetName(obj, name);
        if (pt_is_hidden_io_class_or_name(cls, name)) {
            IOObjectRelease(obj);
            continue;
        }
        return obj;
    }
    return MACH_PORT_NULL;
}

static BOOL pt_is_hidden_audio_component(AudioComponent comp) {
    if (comp == NULL) {
        return NO;
    }
    AudioComponentDescription desc;
    memset(&desc, 0, sizeof(desc));
    if (AudioComponentGetDescription(comp, &desc) != noErr) {
        return NO;
    }
    if (desc.componentManufacturer != 'appl') {
        return YES;
    }
    switch (desc.componentType) {
        case 'auou':
            return (desc.componentSubType == 'ahal' ||
                    desc.componentSubType == 'def ' ||
                    desc.componentSubType == 'sys ' ||
                    desc.componentSubType == 'atap');
        case 'aumu':
            return (desc.componentSubType == 'dls ');
        case 'augn':
            return (desc.componentSubType == 'nrcv' ||
                    desc.componentSubType == 'ttsp');
        case 'aufx':
            return (desc.componentSubType == 'nsnd' ||
                    desc.componentSubType == 'sdly');
        case 'ausp':
            return (desc.componentSubType == 'mctk');
        case 'aupn':
            return YES;
        case 'aumx':
            return (desc.componentSubType == 'smxr' ||
                    desc.componentSubType == '3dmx');
        default:
            return NO;
    }
}

static AudioComponent _Nullable pt_AudioComponentFindNext(
    AudioComponent _Nullable inComponent,
    const AudioComponentDescription * _Nullable inDesc) {
    if (inDesc == NULL) {
        return NULL;
    }
    if (!pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return AudioComponentFindNext(inComponent, inDesc);
    }
    AudioComponent cur = inComponent;
    for (int guard = 0; guard < 4096; guard++) {
        cur = AudioComponentFindNext(cur, inDesc);
        if (cur == NULL) {
            return NULL;
        }
        if (!pt_is_hidden_audio_component(cur)) {
            return cur;
        }
    }
    return NULL;
}

static UInt32 pt_AudioComponentCount(const AudioComponentDescription * _Nullable inDesc) {
    if (inDesc == NULL) {
        return 0;
    }
    if (!pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return AudioComponentCount(inDesc);
    }
    UInt32 count = 0;
    AudioComponent cur = NULL;
    for (UInt32 guard = 0; guard < 4096U; guard++) {
        cur = AudioComponentFindNext(cur, inDesc);
        if (cur == NULL) {
            break;
        }
        if (!pt_is_hidden_audio_component(cur)) {
            count++;
        }
    }
    return count;
}

typedef NS_ENUM(NSInteger, pt_uttype_bundle_action_t) {
    PT_UTTYPE_BUNDLE_KEEP = 0,
    PT_UTTYPE_BUNDLE_REWRITE_MOBILECORETYPES = 1,
    PT_UTTYPE_BUNDLE_HIDE = 2,
};

static pt_uttype_bundle_action_t pt_classify_uttype_declaring_bundle(CFURLRef url, const void *caller) {
    if (url == NULL) {
        return PT_UTTYPE_BUNDLE_KEEP;
    }
    UInt8 raw[PATH_MAX];
    if (!CFURLGetFileSystemRepresentation(url, true, raw, sizeof(raw))) {
        return PT_UTTYPE_BUNDLE_KEEP;
    }
    const char *p = (const char *)raw;
    if (strncmp(p, "/System/Volumes/Data/", 21) == 0) {
        p += 20;
    }
    pt_ensure_bundle_path_map();
    pt_ensure_data_container_map();
    if ((s_real_app_bundle_len > 0 &&
         pt_match_prefix_modulo_private(p, s_real_app_bundle_dir, s_real_app_bundle_len) != NULL) ||
        (s_real_data_container_len > 0 &&
         pt_match_prefix_modulo_private(p, s_real_data_container_dir, s_real_data_container_len) != NULL)) {
        return PT_UTTYPE_BUNDLE_KEEP;
    }
    if (strcasecmp(p, "/System/Library/CoreServices/CoreTypes.bundle") == 0 ||
        strncasecmp(p, "/System/Library/CoreServices/CoreTypes.bundle/", 46) == 0) {
        return PT_UTTYPE_BUNDLE_REWRITE_MOBILECORETYPES;
    }
    if (strstr(p, "DiskImageMounter.app") != NULL ||
        strstr(p, "Finder.app") != NULL ||
        strncmp(p, "/Applications/", 14) == 0 ||
        strncmp(p, "/System/Applications/", 21) == 0 ||
        strstr(p, "/Applications/") != NULL ||
        (strncmp(p, "/System/Library/CoreServices/", 29) == 0 && strstr(p, ".app") != NULL) ||
        pt_is_hidden_path(p, caller) ||
        pt_is_hidden_dyld_image_name(p)) {
        return PT_UTTYPE_BUNDLE_HIDE;
    }
    return PT_UTTYPE_BUNDLE_KEEP;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static CFURLRef _Nullable pt_UTTypeCopyDeclaringBundleURL(CFStringRef inUTI) CF_RETURNS_RETAINED {
    if (inUTI == NULL) {
        return NULL;
    }
    CFURLRef url = UTTypeCopyDeclaringBundleURL(inUTI);
    const void *caller = __builtin_return_address(0);
    if (url == NULL ||
        !pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(caller)) {
        return url;
    }
    switch (pt_classify_uttype_declaring_bundle(url, caller)) {
        case PT_UTTYPE_BUNDLE_HIDE:
            CFRelease(url);
            return NULL;
        case PT_UTTYPE_BUNDLE_REWRITE_MOBILECORETYPES: {
            static const char kMobileCoreTypes[] = "/System/Library/CoreServices/MobileCoreTypes.bundle";
            CFURLRef mobile = CFURLCreateFromFileSystemRepresentation(
                kCFAllocatorDefault,
                (const UInt8 *)kMobileCoreTypes,
                (CFIndex)(sizeof(kMobileCoreTypes) - 1U),
                true);
            CFRelease(url);
            return mobile;
        }
        case PT_UTTYPE_BUNDLE_KEEP:
        default:
            return pt_sanitize_cfbundle_returned_url(url, caller);
    }
}

static CFDictionaryRef _Nullable pt_UTTypeCopyDeclaration(CFStringRef inUTI) CF_RETURNS_RETAINED {
    if (inUTI == NULL) {
        return NULL;
    }
    CFDictionaryRef decl = UTTypeCopyDeclaration(inUTI);
    const void *caller = __builtin_return_address(0);
    if (decl == NULL ||
        !pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(caller)) {
        return decl;
    }
    CFURLRef bundleURL = UTTypeCopyDeclaringBundleURL(inUTI);
    if (bundleURL != NULL) {
        pt_uttype_bundle_action_t act = pt_classify_uttype_declaring_bundle(bundleURL, caller);
        CFRelease(bundleURL);
        if (act == PT_UTTYPE_BUNDLE_HIDE) {
            CFRelease(decl);
            return NULL;
        }
    }
    return decl;
}

#pragma clang diagnostic pop

static CFDictionaryRef pt_get_spoofed_iops_battery_dict(void) {
    static CFDictionaryRef s_dict = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        int32_t cur_cap = 85;
        int32_t max_cap = 100;
        int32_t neg_one = -1;
        CFNumberRef curNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &cur_cap);
        CFNumberRef maxNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &max_cap);
        CFNumberRef negNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &neg_one);
        const void *keys[] = {
            CFSTR("Name"),
            CFSTR("Type"),
            CFSTR("Transport Type"),
            CFSTR("Is Present"),
            CFSTR("Power Source State"),
            CFSTR("Current Capacity"),
            CFSTR("Max Capacity"),
            CFSTR("Is Charging"),
            CFSTR("Is Charged"),
            CFSTR("Time to Empty"),
            CFSTR("Time to Full Charge"),
        };
        const void *vals[] = {
            CFSTR("InternalBattery-0"),
            CFSTR("InternalBattery"),
            CFSTR("Internal"),
            kCFBooleanTrue,
            CFSTR("Battery Power"),
            curNum,
            maxNum,
            kCFBooleanFalse,
            kCFBooleanFalse,
            negNum,
            negNum,
        };
        s_dict = CFDictionaryCreate(kCFAllocatorDefault,
                                    keys,
                                    vals,
                                    (CFIndex)(sizeof(keys) / sizeof(keys[0])),
                                    &kCFTypeDictionaryKeyCallBacks,
                                    &kCFTypeDictionaryValueCallBacks);
        if (curNum != NULL) CFRelease(curNum);
        if (maxNum != NULL) CFRelease(maxNum);
        if (negNum != NULL) CFRelease(negNum);
    });
    return s_dict;
}

extern CFTypeRef IOPSCopyPowerSourcesInfo(void);
static CFTypeRef pt_IOPSCopyPowerSourcesInfo(void) CF_RETURNS_RETAINED {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        CFDictionaryRef batt = pt_get_spoofed_iops_battery_dict();
        if (batt != NULL) {
            const void *items[1] = { batt };
            return CFArrayCreate(kCFAllocatorDefault, items, 1, &kCFTypeArrayCallBacks);
        }
        return CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
    }
    return IOPSCopyPowerSourcesInfo();
}

extern CFArrayRef IOPSCopyPowerSourcesList(CFTypeRef blob);
static CFArrayRef pt_IOPSCopyPowerSourcesList(CFTypeRef blob) CF_RETURNS_RETAINED {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (blob != NULL && CFGetTypeID(blob) == CFArrayGetTypeID() &&
            CFArrayGetCount((CFArrayRef)blob) > 0) {
            return CFArrayCreateCopy(kCFAllocatorDefault, (CFArrayRef)blob);
        }
        CFDictionaryRef batt = pt_get_spoofed_iops_battery_dict();
        if (batt != NULL) {
            const void *items[1] = { batt };
            return CFArrayCreate(kCFAllocatorDefault, items, 1, &kCFTypeArrayCallBacks);
        }
        return CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
    }
    return IOPSCopyPowerSourcesList(blob);
}

extern CFDictionaryRef IOPSGetPowerSourceDescription(CFTypeRef blob, CFTypeRef ps);
static CFDictionaryRef pt_IOPSGetPowerSourceDescription(CFTypeRef blob, CFTypeRef ps) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (ps != NULL && CFGetTypeID(ps) == CFDictionaryGetTypeID()) {
            return (CFDictionaryRef)ps;
        }
        return pt_get_spoofed_iops_battery_dict();
    }
    return IOPSGetPowerSourceDescription(blob, ps);
}

extern CFTypeRef MGCopyAnswer(CFStringRef question, CFDictionaryRef options) __attribute__((weak_import));
extern CFTypeRef MGCopyAnswerWithError(CFStringRef question, CFDictionaryRef options, int *outError) __attribute__((weak_import));
extern CFDictionaryRef MGCopyMultipleAnswers(CFArrayRef questions, CFDictionaryRef options) __attribute__((weak_import));
extern bool MGGetBoolAnswer(CFStringRef question) __attribute__((weak_import));
extern int32_t MGGetSInt32Answer(CFStringRef question, int32_t defaultVal) __attribute__((weak_import));
extern CFStringRef MGGetStringAnswer(CFStringRef question) __attribute__((weak_import));
extern int32_t MGGetProductType(void) __attribute__((weak_import));

static void pt_mg_format_deterministic_ids(char *out_serial, size_t ser_sz, char *out_udid, size_t udid_sz) {
    pt_ensure_bundle_path_map();
    pt_ensure_data_container_map();
    const char *seed = (s_real_data_container_len > 0) ? s_real_data_container_dir :
                       ((s_real_app_bundle_len > 0) ? s_real_app_bundle_dir : "playcover");
    uint64_t h1 = 14695981039346656037ULL;
    uint64_t h2 = 0x9e3779b97f4a7c15ULL;
    for (const unsigned char *p = (const unsigned char *)seed; *p != '\0'; p++) {
        h1 ^= (uint64_t)(*p);
        h1 *= 1099511628211ULL;
        h2 = (h2 * 6364136223846793005ULL) ^ ((uint64_t)(*p) + 0x517cc1b727220a95ULL);
    }
    if (out_serial != NULL && ser_sz > 0) {
        static const char kAlphaNum[] = "0123456789ABCDEFGHJKLMNPQRSTUVWXYZ";
        char tmp[13];
        uint64_t v = h1;
        for (int i = 0; i < 12; i++) {
            tmp[i] = kAlphaNum[v % (sizeof(kAlphaNum) - 1)];
            v = (v >> 5) ^ (v * 2654435761ULL);
        }
        tmp[12] = '\0';
        strlcpy(out_serial, tmp, ser_sz);
    }
    if (out_udid != NULL && udid_sz > 0) {
        uint32_t chip_prefix = 0x8103U;
        const pt_device_profile_t *prof = pt_get_active_device_profile();
        if (prof->soc_code != NULL && prof->soc_code[0] == 't') {
            chip_prefix = (uint32_t)strtoul(prof->soc_code + 1, NULL, 16);
        }
        snprintf(out_udid, udid_sz, "0000%04X-%016llX", (unsigned int)chip_prefix, (unsigned long long)h2);
    }
}

static uint32_t pt_mg_chip_id(const pt_device_profile_t *profile) {
    if (profile != NULL && profile->soc_code != NULL && profile->soc_code[0] == 't') {
        return (uint32_t)strtoul(profile->soc_code + 1, NULL, 16);
    }
    return 0x8103U;
}

static int32_t pt_mg_product_type_enum(const pt_device_profile_t *profile) {
    if (profile == NULL || profile->model == NULL || profile->model[0] == '\0') {
        return (int32_t)3047992373U; // iPad13,8 deterministic code
    }
    if (strcmp(profile->model, "iPad6,7") == 0) return (int32_t)3826259891U;
    if (strcmp(profile->model, "iPad8,6") == 0) return (int32_t)2219225672U;
    if (strcmp(profile->model, "iPad13,8") == 0) return (int32_t)3047992373U;
    if (strcmp(profile->model, "iPad14,5") == 0) return (int32_t)2959110358U;
    if (strcmp(profile->model, "iPad16,6") == 0) return (int32_t)3482895411U;
    if (strcmp(profile->model, "iPad17,3") == 0) return (int32_t)2739481651U;
    if (strcmp(profile->model, "iPhone12,5") == 0) return (int32_t)1790878510U;
    if (strcmp(profile->model, "iPhone14,3") == 0) return (int32_t)1179926470U;
    if (strcmp(profile->model, "iPhone15,3") == 0) return (int32_t)2816236405U;
    if (strcmp(profile->model, "iPhone16,2") == 0) return (int32_t)2376455129U;
    if (strcmp(profile->model, "iPhone17,2") == 0) return (int32_t)3104882917U;
    if (strcmp(profile->model, "iPhone18,2") == 0) return (int32_t)4019283745U;
    uint32_t h = 2166136261U;
    for (const unsigned char *p = (const unsigned char *)profile->model; *p != '\0'; ++p) {
        h ^= (uint32_t)(*p);
        h *= 16777619U;
    }
    return (int32_t)(h != 0U ? h : 1790878510U);
}

static os_unfair_lock s_mg_str_cache_lock = OS_UNFAIR_LOCK_INIT;
static CFMutableDictionaryRef s_mg_str_cache = NULL;

static CFStringRef pt_mg_cached_cfstring(const char *key_tag, const char *cstr) {
    if (cstr == NULL) {
        return NULL;
    }
    os_unfair_lock_lock(&s_mg_str_cache_lock);
    if (s_mg_str_cache == NULL) {
        s_mg_str_cache = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    CFStringRef val = NULL;
    if (s_mg_str_cache != NULL) {
        CFStringRef kref = CFStringCreateWithCString(kCFAllocatorDefault, key_tag, kCFStringEncodingUTF8);
        if (kref != NULL) {
            val = (CFStringRef)CFDictionaryGetValue(s_mg_str_cache, kref);
            if (val == NULL) {
                val = CFStringCreateWithCString(kCFAllocatorDefault, cstr, kCFStringEncodingUTF8);
                if (val != NULL) {
                    CFDictionarySetValue(s_mg_str_cache, kref, val);
                    CFRelease(val);
                }
            }
            CFRelease(kref);
        }
    }
    os_unfair_lock_unlock(&s_mg_str_cache_lock);
    return val;
}

static BOOL pt_mg_lookup_spoofed_internal(CFStringRef question, CFTypeRef *out_val, BOOL retain_result) {
    if (question == NULL || out_val == NULL) {
        return NO;
    }
    *out_val = NULL;
    NSString *key = (__bridge NSString *)question;
    const pt_device_profile_t *profile = pt_get_active_device_profile();

    if ([key isEqualToString:@"ProductType"] || [key isEqualToString:@"ThinningProductType"]) {
        CFStringRef s = pt_mg_cached_cfstring(profile->model, profile->model);
        *out_val = (retain_result && s != NULL) ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"HWModelStr"]) {
        CFStringRef s = pt_mg_cached_cfstring(profile->oem_id, profile->oem_id);
        *out_val = (retain_result && s != NULL) ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"DeviceClass"] ||
        [key isEqualToString:@"DeviceName"] ||
        [key isEqualToString:@"UserAssignedDeviceName"]) {
        CFStringRef s = profile->is_ipad ? CFSTR("iPad") : CFSTR("iPhone");
        *out_val = retain_result ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"ProductName"]) {
        CFStringRef s = CFSTR("iPhone OS");
        *out_val = retain_result ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"ProductVersion"]) {
        pt_ensure_host_kernel_info();
        const char *ov_ver = pt_get_reported_ios_version_override(NULL);
        const char *effVer = (ov_ver != NULL) ? ov_ver : s_spoofed_ios_version;
        CFStringRef s = pt_mg_cached_cfstring(effVer, effVer);
        *out_val = (retain_result && s != NULL) ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"BuildVersion"] || [key isEqualToString:@"ProductBuildVersion"]) {
        pt_ensure_host_kernel_info();
        const char *ov_build = NULL;
        (void)pt_get_reported_ios_version_override(&ov_build);
        const char *effBuild = (ov_build != NULL) ? ov_build : s_spoofed_osversion;
        CFStringRef s = pt_mg_cached_cfstring(effBuild, effBuild);
        *out_val = (retain_result && s != NULL) ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"ModelNumber"]) {
        CFStringRef s = pt_mg_cached_cfstring(profile->model_number, profile->model_number);
        *out_val = (retain_result && s != NULL) ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"RegulatoryModelNumber"]) {
        CFStringRef s = pt_mg_cached_cfstring(profile->regulatory_model, profile->regulatory_model);
        *out_val = (retain_result && s != NULL) ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"marketing-name"]) {
        CFStringRef s = pt_mg_cached_cfstring(profile->marketing_name, profile->marketing_name);
        *out_val = (retain_result && s != NULL) ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"SerialNumber"]) {
        char ser[32];
        pt_mg_format_deterministic_ids(ser, sizeof(ser), NULL, 0);
        CFStringRef s = pt_mg_cached_cfstring("SerialNumber", ser);
        *out_val = (retain_result && s != NULL) ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"UniqueDeviceID"]) {
        char udid[64];
        pt_mg_format_deterministic_ids(NULL, 0, udid, sizeof(udid));
        char tag[96];
        snprintf(tag, sizeof(tag), "UDID:%s", profile->model);
        CFStringRef s = pt_mg_cached_cfstring(tag, udid);
        *out_val = (retain_result && s != NULL) ? CFRetain(s) : s;
        return YES;
    }
    if ([key isEqualToString:@"ChipID"]) {
        int32_t chip = (int32_t)pt_mg_chip_id(profile);
        *out_val = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &chip);
        return YES;
    }
    if ([key isEqualToString:@"DeviceFamily"] ||
        [key isEqualToString:@"SupportedDeviceFamilies"]) {
        NSArray *arr = @[ @(profile->is_ipad ? 2 : 1) ];
        *out_val = CFBridgingRetain(arr);
        return YES;
    }
    if ([key isEqualToString:@"ipad"]) {
        CFBooleanRef b = profile->is_ipad ? kCFBooleanTrue : kCFBooleanFalse;
        *out_val = retain_result ? CFRetain(b) : b;
        return YES;
    }
    if ([key isEqualToString:@"iphone"]) {
        CFBooleanRef b = profile->is_ipad ? kCFBooleanFalse : kCFBooleanTrue;
        *out_val = retain_result ? CFRetain(b) : b;
        return YES;
    }
    if ([key isEqualToString:@"apple-internal-install"] ||
        [key isEqualToString:@"has-si-dev-tree"]) {
        *out_val = retain_result ? CFRetain(kCFBooleanFalse) : kCFBooleanFalse;
        return YES;
    }
    if ([key isEqualToString:@"ArtworkTraits"]) {
        NSDictionary *traits = @{
            @"ArtworkDeviceIdiom": profile->is_ipad ? @"ipad" : @"iphone",
            @"ArtworkDeviceProductDescription": [NSString stringWithUTF8String:profile->marketing_name],
            @"ArtworkDisplayGamut": @"P3",
            @"ArtworkScaleFactor": @((int)profile->native_scale),
        };
        *out_val = CFBridgingRetain(traits);
        return YES;
    }
    if ([key isEqualToString:@"CompatibleDeviceFallback"] ||
        [key isEqualToString:@"DieId"] ||
        [key isEqualToString:@"UniqueChipID"] ||
        [key isEqualToString:@"SysCfgDict"]) {
        *out_val = NULL;
        return YES;
    }
    return NO;
}

static BOOL pt_mg_lookup_spoofed(CFStringRef question, CFTypeRef *out_retained) {
    return pt_mg_lookup_spoofed_internal(question, out_retained, YES);
}

__attribute__((visibility("hidden"))) CFTypeRef pt_MGCopyAnswer(CFStringRef question, CFDictionaryRef options) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        CFTypeRef spoofed = NULL;
        if (pt_mg_lookup_spoofed(question, &spoofed)) {
            return spoofed;
        }
    }
    return (MGCopyAnswer != NULL) ? MGCopyAnswer(question, options) : NULL;
}

__attribute__((visibility("hidden"))) CFTypeRef pt_MGCopyAnswerWithError(CFStringRef question, CFDictionaryRef options, int *outError) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        CFTypeRef spoofed = NULL;
        if (pt_mg_lookup_spoofed(question, &spoofed)) {
            if (outError != NULL) {
                *outError = (spoofed != NULL) ? 0 : -1;
            }
            return spoofed;
        }
    }
    if (MGCopyAnswerWithError != NULL) {
        return MGCopyAnswerWithError(question, options, outError);
    }
    if (outError != NULL) {
        *outError = -1;
    }
    return NULL;
}

__attribute__((visibility("hidden"))) CFDictionaryRef pt_MGCopyMultipleAnswers(CFArrayRef questions, CFDictionaryRef options) {
    BOOL app_caller = (pt_is_bypass_enabled() &&
                       !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    if (!app_caller) {
        return (MGCopyMultipleAnswers != NULL) ? MGCopyMultipleAnswers(questions, options) : NULL;
    }
    if (questions == NULL) {
        return NULL;
    }
    CFDictionaryRef orig = (MGCopyMultipleAnswers != NULL) ? MGCopyMultipleAnswers(questions, options) : NULL;
    NSMutableDictionary *result = (orig != NULL) ? [(__bridge NSDictionary *)orig mutableCopy] : [NSMutableDictionary dictionary];
    if (orig != NULL) {
        CFRelease(orig);
    }
    for (id q in (__bridge NSArray *)questions) {
        if ([q isKindOfClass:[NSString class]]) {
            CFTypeRef spoofed = NULL;
            if (pt_mg_lookup_spoofed((__bridge CFStringRef)q, &spoofed)) {
                if (spoofed != NULL) {
                    result[q] = (__bridge_transfer id)spoofed;
                } else {
                    [result removeObjectForKey:q];
                }
            }
        }
    }
    return (__bridge_retained CFDictionaryRef)[result copy];
}

__attribute__((visibility("hidden"))) bool pt_MGGetBoolAnswer(CFStringRef question) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        CFTypeRef spoofed = NULL;
        if (pt_mg_lookup_spoofed(question, &spoofed)) {
            bool res = false;
            if (spoofed != NULL) {
                if (CFGetTypeID(spoofed) == CFBooleanGetTypeID()) {
                    res = CFBooleanGetValue((CFBooleanRef)spoofed);
                }
                CFRelease(spoofed);
            }
            return res;
        }
    }
    return (MGGetBoolAnswer != NULL) ? MGGetBoolAnswer(question) : false;
}

__attribute__((visibility("hidden"))) int32_t pt_MGGetSInt32Answer(CFStringRef question, int32_t defaultVal) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        CFTypeRef spoofed = NULL;
        if (pt_mg_lookup_spoofed(question, &spoofed)) {
            int32_t res = defaultVal;
            if (spoofed != NULL) {
                if (CFGetTypeID(spoofed) == CFNumberGetTypeID()) {
                    CFNumberGetValue((CFNumberRef)spoofed, kCFNumberSInt32Type, &res);
                }
                CFRelease(spoofed);
            }
            return res;
        }
    }
    return (MGGetSInt32Answer != NULL) ? MGGetSInt32Answer(question, defaultVal) : defaultVal;
}

__attribute__((visibility("hidden"))) CFStringRef pt_MGGetStringAnswer(CFStringRef question) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        CFTypeRef spoofed = NULL;
        if (pt_mg_lookup_spoofed_internal(question, &spoofed, YES)) {
            if (spoofed != NULL && CFGetTypeID(spoofed) != CFStringGetTypeID()) {
                CFRelease(spoofed);
                return NULL;
            }
            return (CFStringRef)spoofed;
        }
    }
    return (MGGetStringAnswer != NULL) ? MGGetStringAnswer(question) : NULL;
}

__attribute__((visibility("hidden"))) int32_t pt_MGGetProductType(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return pt_mg_product_type_enum(pt_get_active_device_profile());
    }
    return (MGGetProductType != NULL) ? MGGetProductType() : 0;
}


__attribute__((visibility("hidden")))
BOOL pt_is_hidden_env_key(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return NO;
    }
    if (strncmp(name, "XPC_", 4) == 0 ||
        strncmp(name, "DYLD_", 5) == 0 ||
        strncmp(name, "__XPC_DYLD_", 11) == 0 ||
        strncmp(name, "SIMULATOR_", 10) == 0 ||
        strncmp(name, "METAL_", 6) == 0 ||
        strncmp(name, "MTL_", 4) == 0 ||
        strncmp(name, "HOMEBREW_", 9) == 0 ||
        strcasestr(name, "playcover") != NULL ||
        strcasestr(name, "macover") != NULL ||
        strcasestr(name, "playtools") != NULL) {
        return YES;
    }
    static const char *const kHiddenKeys[] = {
        "MallocStackLogging",
        "MallocStackLoggingNoCompact",
        "MallocNanoZone",
        "NSZombieEnabled",
        "CLASSIC",
        "OSSignpostLogging",
        "OS_ACTIVITY_DT_MODE",
        "OS_ACTIVITY_MODE",
        "OBJC_DISABLE_INITIALIZE_FORK_SAFETY",
        "MTLCaptureEnabled",
        "__CFBundleIdentifier",
        "__CF_USER_TEXT_ENCODING",
        "DARWIN_USER_TEMP_DIR",
        "DARWIN_USER_CACHE_DIR",
        "DARWIN_USER_DIR",
        "SQLITE_EXEMPT_PATH_FROM_VNODE_GUARDS",
        "TERM",
        "TERM_PROGRAM",
        "TERM_PROGRAM_VERSION",
        "TERM_SESSION_ID",
        "Apple_PubSub_Socket_Render",
        "DISPLAY",
        "SHELL",
        "SSH_AUTH_SOCK",
        "SECURITYSESSIONID",
        "LaunchInstanceID",
        "COMMAND_MODE",
        "USE_EXTRA_ANTIJB",
        "USER",
        "LOGNAME",
        "OLDPWD",
        "SHLVL",
        "_",
        "APP_SANDBOX_CONTAINER_ID",
        "DISABLE_PLAYSHADOW_BYPASS"
    };
    size_t count = sizeof(kHiddenKeys) / sizeof(kHiddenKeys[0]);
    for (size_t i = 0; i < count; i++) {
        if (strcmp(name, kHiddenKeys[i]) == 0) {
            return YES;
        }
    }
    return NO;
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
            if (uStr == nil ||
                [uStr isEqualToString:@"mobile"] ||
                [uStr isEqualToString:NSUserName()]) {
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
            if (userName == nil ||
                [userName isEqualToString:@"mobile"] ||
                [userName isEqualToString:NSUserName()]) {
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
    NSArray<NSString *> *orig = NSSearchPathForDirectoriesInDomains(directory, domainMask, expandTilde);
    if (orig.count > 0 && expandTilde &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        NSMutableArray<NSString *> *mapped = nil;
        for (NSUInteger i = 0; i < orig.count; i++) {
            NSString *item = orig[i];
            const char *raw = [item fileSystemRepresentation];
            char vbuf[PATH_MAX];
            const char *virt = pt_virtualize_path_for_app(raw, vbuf, sizeof(vbuf), NO);
            if (virt != NULL && virt != raw) {
                NSString *virtStr = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:virt
                                                                                                length:strlen(virt)];
                if (virtStr != nil) {
                    if (mapped == nil) {
                        mapped = [orig mutableCopy];
                    }
                    mapped[i] = virtStr;
                }
            }
        }
        if (mapped != nil) {
            return [mapped copy];
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
        (pt_is_hidden_path(orig_path, caller) || pt_is_hidden_dyld_image_name(orig_path))) {
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

static BOOL pt_is_hidden_bundle_identifier(CFStringRef bundleID) {
    if (bundleID == NULL) {
        return NO;
    }
    NSString *bid = (__bridge NSString *)bundleID;
    if ([bid isEqualToString:@"com.apple.AppKit"] ||
        [bid isEqualToString:@"com.apple.UIKitMacHelper"] ||
        [bid isEqualToString:@"com.apple.ViewBridge"] ||
        [bid isEqualToString:@"com.apple.SkyLight"] ||
        [bid isEqualToString:@"com.apple.HIToolbox"] ||
        [bid isEqualToString:@"com.apple.Carbon"] ||
        [bid rangeOfString:@"PlayTools" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [bid rangeOfString:@"PlayCover" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [bid rangeOfString:@"MacOver" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [bid rangeOfString:@"app.makedie" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [bid rangeOfString:@"AKInterface" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return YES;
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
    if (key == NULL || key[0] == '\0') {
        return NO;
    }
    if (strncmp(key, "NSWindow Frame", 14) == 0 ||
        strncmp(key, "NSToolbar Configuration", 23) == 0 ||
        strncmp(key, "NSNav", 5) == 0 ||
        strncmp(key, "NSStatusItem", 12) == 0 ||
        strncmp(key, "NSTableView", 11) == 0 ||
        strncmp(key, "NSSplitView", 11) == 0 ||
        strncmp(key, "com.apple.trackpad.", 19) == 0 ||
        strncmp(key, "com.apple.mouse.", 16) == 0 ||
        strncmp(key, "com.apple.springing.", 20) == 0 ||
        strncmp(key, "com.apple.sound.beep.", 21) == 0 ||
        strcasestr(key, "PlayCover") != NULL ||
        strcasestr(key, "PlayTools") != NULL ||
        strcasestr(key, "MacOver") != NULL ||
        strcasestr(key, "AKInterface") != NULL) {
        return YES;
    }
    static const char *const kHiddenPrefKeys[] = {
        "NSQuitAlwaysKeepsWindows",
        "AppleActionOnDoubleClick",
        "AppleMiniaturizeOnDoubleClick",
        "AppleShowScrollBars",
        "AppleScrollerPagingBehavior",
        "AppleMenuBarVisibleInFullscreen",
        "AppleEnableSwipeNavigateWithScrolls",
        "AppleEnableMouseSwipeNavigateWithScrolls",
        "ApplePressAndHoldEnabled",
        "com.apple.swipescrolldirection",
        "NSDocumentRevisionsDebugMode",
        "ApplePersistenceIgnoreState",
        "NSFullScreenMenuItemEverywhere",
        "WebKitDeveloperExtras",
    };
    for (size_t i = 0; i < sizeof(kHiddenPrefKeys) / sizeof(kHiddenPrefKeys[0]); i++) {
        if (strcmp(key, kHiddenPrefKeys[i]) == 0) {
            return YES;
        }
    }
    return NO;
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

static BOOL pt_cstr_contains_macos_pref_leak(const char *s) {
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
    if (val == NULL || depth > 2) {
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
        if (n > 64) {
            n = 64;
        }
        for (CFIndex i = 0; i < n; i++) {
            if (pt_pref_value_contains_macos_leak(CFArrayGetValueAtIndex(arr, i), depth + 1)) {
                return YES;
            }
        }
        return NO;
    }
    return NO;
}

static CFPropertyListRef pt_CFPreferencesCopyAppValue(CFStringRef key, CFStringRef applicationID) CF_RETURNS_RETAINED {
    BOOL should_filter = (pt_is_bypass_enabled() &&
                          !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    if (should_filter && key != NULL) {
        char kbuf[256];
        const char *kstr = NULL;
        if (pt_cfstr_to_cstr(key, kbuf, sizeof(kbuf), &kstr) && pt_is_hidden_macos_pref_key(kstr)) {
            return NULL;
        }
    }
    CFPropertyListRef val = CFPreferencesCopyAppValue(key, applicationID);
    if (val != NULL && should_filter && pt_pref_value_contains_macos_leak(val, 0)) {
        CFRelease(val);
        return NULL;
    }
    return val;
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
    NSDictionary *nsDict = (__bridge NSDictionary *)dict;
    NSMutableArray *keysToRemove = nil;
    for (id k in nsDict) {
        BOOL drop = NO;
        if ([k isKindOfClass:[NSString class]]) {
            const char *kc = [(NSString *)k UTF8String];
            if (kc != NULL && pt_is_hidden_macos_pref_key(kc)) {
                drop = YES;
            }
        }
        if (!drop) {
            id v = nsDict[k];
            if (v != nil && pt_pref_value_contains_macos_leak((__bridge CFPropertyListRef)v, 0)) {
                drop = YES;
            }
        }
        if (drop) {
            if (keysToRemove == nil) {
                keysToRemove = [NSMutableArray array];
            }
            [keysToRemove addObject:k];
        }
    }
    if (keysToRemove == nil) {
        return dict;
    }
    NSMutableDictionary *san = [nsDict mutableCopy];
    [san removeObjectsForKeys:keysToRemove];
    CFRelease(dict);
    return (__bridge_retained CFDictionaryRef)[san copy];
}

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
        if (CFDictionaryGetCount(s_bundle_info_cache) < 256) {
            CFDictionarySetValue(s_bundle_info_cache, rawDict, cleanRef);
            CFDictionaryRef kept = (CFDictionaryRef)CFDictionaryGetValue(s_bundle_info_cache, rawDict);
            os_unfair_lock_unlock(&s_bundle_info_cache_lock);
            return kept;
        }
    }
    os_unfair_lock_unlock(&s_bundle_info_cache_lock);
    return rawDict;
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


static int pt_gethostname(char *name, size_t namelen) {
    if (name != NULL && namelen > 0 &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        const char *model = DEVICE_MODEL;
        const char *host = (model != NULL && strncmp(model, "iPad", 4) == 0) ? "iPad" : "iPhone";
        strncpy(name, host, namelen - 1);
        name[namelen - 1] = '\0';
        return 0;
    }
    return gethostname(name, namelen);
}

static pthread_key_t s_pw_tls_key;
static pthread_once_t s_pw_tls_once = PTHREAD_ONCE_INIT;
static void pt_init_pw_tls_key(void) {
    pthread_key_create(&s_pw_tls_key, free);
}

static void pt_fill_mobile_passwd_struct(uid_t uid, gid_t gid, struct passwd *pwd, char *buffer, size_t bufsize) {
    static const char kBlock[] = "mobile\0*\0Mobile User\0/var/mobile\0/usr/sbin/nologin";
    memset(pwd, 0, sizeof(*pwd));
    pwd->pw_uid = uid;
    pwd->pw_gid = gid;
    if (buffer != NULL && bufsize >= sizeof(kBlock)) {
        memcpy(buffer, kBlock, sizeof(kBlock));
        pwd->pw_name = buffer;
        pwd->pw_passwd = buffer + 7;
        pwd->pw_gecos = buffer + 9;
        pwd->pw_dir = buffer + 21;
        pwd->pw_shell = buffer + 33;
    } else {
        pwd->pw_name = (char *)"mobile";
        pwd->pw_passwd = (char *)"*";
        pwd->pw_gecos = (char *)"Mobile User";
        pwd->pw_dir = (char *)"/var/mobile";
        pwd->pw_shell = (char *)"/usr/sbin/nologin";
    }
}

static struct passwd *pt_get_mobile_tls_passwd(uid_t uid, gid_t gid) {
    pthread_once(&s_pw_tls_once, pt_init_pw_tls_key);
    struct passwd *pw_buf = (struct passwd *)pthread_getspecific(s_pw_tls_key);
    if (pw_buf == NULL) {
        pw_buf = (struct passwd *)calloc(1, sizeof(struct passwd));
        if (pw_buf == NULL) {
            return NULL;
        }
        pthread_setspecific(s_pw_tls_key, pw_buf);
    }
    pt_fill_mobile_passwd_struct(uid, gid, pw_buf, NULL, 0);
    return pw_buf;
}

static BOOL pt_matches_host_username(const char *login) {
    if (login == NULL || login[0] == '\0' || strcmp(login, "mobile") == 0) {
        return NO;
    }
    const char *ur = pt_get_host_user_root_cstr();
    if (ur != NULL && strncmp(ur, "/Users/", 7) == 0) {
        const char *u = ur + 7;
        if (u[0] != '\0' && strcmp(login, u) == 0) {
            return YES;
        }
    }
    struct passwd *self_pw = getpwuid(getuid());
    if (self_pw != NULL && self_pw->pw_name != NULL && strcmp(login, self_pw->pw_name) == 0) {
        return YES;
    }
    return NO;
}

static inline gid_t pt_map_spoofed_gid(gid_t raw_gid) {
    return (pt_is_bypass_enabled() && raw_gid == 20) ? (gid_t)501 : raw_gid;
}

static struct passwd *pt_getpwuid(uid_t uid) {
    struct passwd *real_pw = getpwuid(uid);
    if (real_pw != NULL &&
        (uid == getuid() || uid == 501) &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        gid_t mapped_gid = pt_map_spoofed_gid(real_pw->pw_gid);
        struct passwd *pw_buf = pt_get_mobile_tls_passwd(real_pw->pw_uid, mapped_gid);
        if (pw_buf != NULL) {
            pw_buf->pw_change = real_pw->pw_change;
            pw_buf->pw_class = real_pw->pw_class;
            pw_buf->pw_expire = real_pw->pw_expire;
            return pw_buf;
        }
    }
    return real_pw;
}

static int pt_getpwuid_r(uid_t uid, struct passwd *pwd, char *buffer, size_t bufsize, struct passwd **result) {
    int rc = getpwuid_r(uid, pwd, buffer, bufsize, result);
    if (rc == 0 && pwd != NULL && result != NULL && *result != NULL &&
        (uid == getuid() || uid == 501) &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        gid_t mapped_gid = pt_map_spoofed_gid(pwd->pw_gid);
        pt_fill_mobile_passwd_struct(pwd->pw_uid, mapped_gid, pwd, buffer, bufsize);
    }
    return rc;
}

static struct passwd *pt_getpwnam(const char *login) {
    if (login != NULL && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (strcmp(login, "mobile") == 0) {
            gid_t mapped_gid = pt_map_spoofed_gid(getgid());
            struct passwd *pw_buf = pt_get_mobile_tls_passwd(getuid(), mapped_gid);
            if (pw_buf != NULL) {
                return pw_buf;
            }
        } else if (pt_matches_host_username(login)) {
            return NULL;
        }
    }
    return getpwnam(login);
}

static int pt_getpwnam_r(const char *login, struct passwd *pwd, char *buffer, size_t bufsize, struct passwd **result) {
    if (login != NULL && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (strcmp(login, "mobile") == 0) {
            if (pwd == NULL || result == NULL) {
                return EINVAL;
            }
            gid_t mapped_gid = pt_map_spoofed_gid(getgid());
            pt_fill_mobile_passwd_struct(getuid(), mapped_gid, pwd, buffer, bufsize);
            *result = pwd;
            return 0;
        }
        if (pt_matches_host_username(login)) {
            if (result != NULL) {
                *result = NULL;
            }
            return 0;
        }
    }
    return getpwnam_r(login, pwd, buffer, bufsize, result);
}

static char *pt_getlogin(void) {
    if (!pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return (char *)"mobile";
    }
    return getlogin();
}

static int pt_getlogin_r(char *buf, size_t bufsize) {
    if (!pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (buf == NULL || bufsize < 7) {
            return ERANGE;
        }
        memcpy(buf, "mobile", 7);
        return 0;
    }
    return getlogin_r(buf, bufsize);
}

static NSString *pt_NSUserName(void) {
    if (!pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return @"mobile";
    }
    return NSUserName();
}

static NSString *pt_NSFullUserName(void) {
    if (!pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return @"Mobile User";
    }
    return NSFullUserName();
}

static char *pt_user_from_uid(uid_t uid, int nouser) {
    if ((uid == getuid() || uid == 501) &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return (char *)"mobile";
    }
    return user_from_uid(uid, nouser);
}

static gid_t pt_getgid_with_caller(const void *caller) {
    gid_t gid = getgid();
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        return pt_map_spoofed_gid(gid);
    }
    return gid;
}

static gid_t pt_getgid(void) {
    return pt_getgid_with_caller(__builtin_return_address(0));
}

static gid_t pt_getegid_with_caller(const void *caller) {
    gid_t egid = getegid();
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        return pt_map_spoofed_gid(egid);
    }
    return egid;
}

static gid_t pt_getegid(void) {
    return pt_getegid_with_caller(__builtin_return_address(0));
}

static BOOL pt_is_desktop_supplemental_gid(gid_t g) {
    switch (g) {
        case 12:  // everyone
        case 29:  // certusers
        case 33:  // _appstore
        case 61:  // localaccounts
        case 79:  // _appserverusr
        case 80:  // admin
        case 81:  // _appserveradm
        case 98:  // _lpadmin
        case 100: // _lpoperator
        case 101: // _developer
        case 204: // _developer
        case 250: // _analyticsusers
        case 395: // com.apple.access_ftp
        case 398: // com.apple.access_screensharing
        case 399: // com.apple.access_ssh
        case 400: // com.apple.access_remote_ae
        case 701: // com.apple.sharepoint.group
            return YES;
        default:
            return (g >= 390U && g <= 410U);
    }
}

static int pt_getgroups_with_caller(int gidsetsize, gid_t grouplist[], const void *caller) {
    if (!pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(caller)) {
        return getgroups(gidsetsize, grouplist);
    }
    if (gidsetsize < 0) {
        errno = EINVAL;
        return -1;
    }
    gid_t host_groups[64];
    int host_n = getgroups(64, host_groups);
    if (host_n < 0) {
        host_groups[0] = getgid();
        host_n = 1;
    }

    gid_t filtered[64];
    int filtered_n = 0;
    for (int i = 0; i < host_n && filtered_n < 64; i++) {
        gid_t g = host_groups[i];
        if (pt_is_desktop_supplemental_gid(g)) {
            continue;
        }
        if (g == 20) {
            g = 501;
        }
        BOOL dup = NO;
        for (int j = 0; j < filtered_n; j++) {
            if (filtered[j] == g) {
                dup = YES;
                break;
            }
        }
        if (!dup) {
            filtered[filtered_n++] = g;
        }
    }
    if (filtered_n == 0) {
        filtered[0] = 501;
        filtered_n = 1;
    }
    if (gidsetsize == 0) {
        return filtered_n;
    }
    if (gidsetsize < filtered_n) {
        errno = EINVAL;
        return -1;
    }
    if (grouplist == NULL) {
        errno = EFAULT;
        return -1;
    }
    for (int i = 0; i < filtered_n; i++) {
        grouplist[i] = filtered[i];
    }
    return filtered_n;
}

static int pt_getgroups(int gidsetsize, gid_t grouplist[]) {
    return pt_getgroups_with_caller(gidsetsize, grouplist, __builtin_return_address(0));
}

static BOOL pt_is_hidden_macos_group_name(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return NO;
    }
    if (strncmp(name, "com.apple.sharepoint.", 21) == 0 ||
        strncmp(name, "com.apple.access_", 17) == 0) {
        return YES;
    }
    static const char *const kHiddenGroups[] = {
        "staff", "admin", "everyone", "certusers", "localaccounts",
        "_developer", "_appstore", "_lpadmin", "_lpoperator",
        "_appserverusr", "_appserveradm", "_analyticsusers",
    };
    for (size_t i = 0; i < sizeof(kHiddenGroups) / sizeof(kHiddenGroups[0]); i++) {
        if (strcmp(name, kHiddenGroups[i]) == 0) {
            return YES;
        }
    }
    return NO;
}

static struct group *pt_tls_mobile_group(void) {
    static _Thread_local struct group tls_grp;
    static _Thread_local char tls_name[16];
    static _Thread_local char tls_passwd[4];
    static _Thread_local char *tls_members[2];
    strlcpy(tls_name, "mobile", sizeof(tls_name));
    strlcpy(tls_passwd, "*", sizeof(tls_passwd));
    tls_members[0] = tls_name;
    tls_members[1] = NULL;
    tls_grp.gr_name = tls_name;
    tls_grp.gr_passwd = tls_passwd;
    tls_grp.gr_gid = 501;
    tls_grp.gr_mem = tls_members;
    return &tls_grp;
}

static int pt_fill_mobile_group_r(struct group *grp, char *buf, size_t bufsize, struct group **result) {
    if (result != NULL) {
        *result = NULL;
    }
    if (grp == NULL || buf == NULL) {
        return EINVAL;
    }
    uintptr_t p = (uintptr_t)buf;
    uintptr_t aligned = (p + (sizeof(char *) - 1U)) & ~(uintptr_t)(sizeof(char *) - 1U);
    size_t pad = (size_t)(aligned - p);
    size_t needed = pad + 2U * sizeof(char *) + 7U + 2U;
    if (bufsize < needed) {
        return ERANGE;
    }
    char **mem = (char **)aligned;
    char *gname = (char *)(aligned + 2U * sizeof(char *));
    char *gpass = gname + 7U;
    memcpy(gname, "mobile", 7U);
    memcpy(gpass, "*", 2U);
    mem[0] = gname;
    mem[1] = NULL;
    grp->gr_name = gname;
    grp->gr_passwd = gpass;
    grp->gr_gid = 501;
    grp->gr_mem = mem;
    if (result != NULL) {
        *result = grp;
    }
    return 0;
}

static struct group *pt_getgrgid(gid_t gid) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (gid == 501) {
            return pt_tls_mobile_group();
        }
        if (gid == 20 || pt_is_desktop_supplemental_gid(gid)) {
            return NULL;
        }
    }
    return getgrgid(gid);
}

static int pt_getgrgid_r(gid_t gid, struct group *grp, char *buf, size_t bufsize, struct group **result) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (gid == 501) {
            return pt_fill_mobile_group_r(grp, buf, bufsize, result);
        }
        if (gid == 20 || pt_is_desktop_supplemental_gid(gid)) {
            if (result != NULL) {
                *result = NULL;
            }
            return 0;
        }
    }
    return getgrgid_r(gid, grp, buf, bufsize, result);
}

static struct group *pt_getgrnam(const char *name) {
    if (name != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (strcmp(name, "mobile") == 0) {
            return pt_tls_mobile_group();
        }
        if (pt_is_hidden_macos_group_name(name)) {
            return NULL;
        }
    }
    return getgrnam(name);
}

static int pt_getgrnam_r(const char *name, struct group *grp, char *buf, size_t bufsize, struct group **result) {
    if (name != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (strcmp(name, "mobile") == 0) {
            return pt_fill_mobile_group_r(grp, buf, bufsize, result);
        }
        if (pt_is_hidden_macos_group_name(name)) {
            if (result != NULL) {
                *result = NULL;
            }
            return 0;
        }
    }
    return getgrnam_r(name, grp, buf, bufsize, result);
}

extern int pt_orig_getgrouplist(const char *name, int basegid, int *groups, int *ngroups) __asm("_getgrouplist");

static int pt_getgrouplist(const char *name, int basegid, int *groups, int *ngroups) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (ngroups == NULL) {
            errno = EINVAL;
            return -1;
        }
        gid_t mapped = pt_map_spoofed_gid((gid_t)basegid);
        if (pt_is_desktop_supplemental_gid(mapped)) {
            mapped = 501;
        }
        if (*ngroups < 1) {
            *ngroups = 1;
            return -1;
        }
        if (groups == NULL) {
            errno = EFAULT;
            return -1;
        }
        groups[0] = (int)mapped;
        *ngroups = 1;
        return 0;
    }
    return pt_orig_getgrouplist(name, basegid, groups, ngroups);
}

struct utmpx;
extern struct utmpx *pt_orig_getutxent(void) __asm("_getutxent");
extern struct utmpx *pt_orig_getutxid(const struct utmpx *) __asm("_getutxid");
extern struct utmpx *pt_orig_getutxline(const struct utmpx *) __asm("_getutxline");

static struct utmpx *pt_getutxent(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NULL;
    }
    return pt_orig_getutxent();
}

static struct utmpx *pt_getutxid(const struct utmpx *ut) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NULL;
    }
    return pt_orig_getutxid(ut);
}

static struct utmpx *pt_getutxline(const struct utmpx *ut) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NULL;
    }
    return pt_orig_getutxline(ut);
}

extern int pt_orig_gethostuuid(uuid_t id, const struct timespec *wait) __asm("_gethostuuid");

__attribute__((visibility("hidden")))
int pt_gethostuuid_with_caller(uuid_t id, const struct timespec *wait, const void *caller) {
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
        errno = EPERM;
        return -1;
    }
    return pt_orig_gethostuuid(id, wait);
}

static int pt_gethostuuid(uuid_t id, const struct timespec *wait) {
    return pt_gethostuuid_with_caller(id, wait, __builtin_return_address(0));
}

#define PT_THERMAL_NOTIFY_TOKEN_CAP 64U
static os_unfair_lock s_thermal_notify_lock = OS_UNFAIR_LOCK_INIT;
static int s_thermal_notify_tokens[PT_THERMAL_NOTIFY_TOKEN_CAP];
static BOOL s_thermal_notify_valid[PT_THERMAL_NOTIFY_TOKEN_CAP];

static void pt_record_thermal_notify_token(int token) {
    os_unfair_lock_lock(&s_thermal_notify_lock);
    int free_idx = -1;
    for (size_t i = 0; i < PT_THERMAL_NOTIFY_TOKEN_CAP; i++) {
        if (s_thermal_notify_valid[i] && s_thermal_notify_tokens[i] == token) {
            os_unfair_lock_unlock(&s_thermal_notify_lock);
            return;
        }
        if (!s_thermal_notify_valid[i] && free_idx < 0) {
            free_idx = (int)i;
        }
    }
    if (free_idx >= 0) {
        s_thermal_notify_tokens[free_idx] = token;
        s_thermal_notify_valid[free_idx] = YES;
    }
    os_unfair_lock_unlock(&s_thermal_notify_lock);
}

static void pt_remove_thermal_notify_token(int token) {
    os_unfair_lock_lock(&s_thermal_notify_lock);
    for (size_t i = 0; i < PT_THERMAL_NOTIFY_TOKEN_CAP; i++) {
        if (s_thermal_notify_valid[i] && s_thermal_notify_tokens[i] == token) {
            s_thermal_notify_valid[i] = NO;
            s_thermal_notify_tokens[i] = 0;
        }
    }
    os_unfair_lock_unlock(&s_thermal_notify_lock);
}

static BOOL pt_is_thermal_notify_token(int token) {
    BOOL found = NO;
    os_unfair_lock_lock(&s_thermal_notify_lock);
    for (size_t i = 0; i < PT_THERMAL_NOTIFY_TOKEN_CAP; i++) {
        if (s_thermal_notify_valid[i] && s_thermal_notify_tokens[i] == token) {
            found = YES;
            break;
        }
    }
    os_unfair_lock_unlock(&s_thermal_notify_lock);
    return found;
}

static uint32_t pt_notify_register_check(const char *name, int *out_token) {
    uint32_t st = notify_register_check(name, out_token);
    if (st == NOTIFY_STATUS_OK && out_token != NULL && name != NULL &&
        strcmp(name, "com.apple.system.thermalpressurelevel") == 0) {
        pt_record_thermal_notify_token(*out_token);
    }
    return st;
}

static uint32_t pt_notify_register_dispatch(const char *name,
                                            int *out_token,
                                            dispatch_queue_t queue,
                                            notify_handler_t handler) {
    uint32_t st = notify_register_dispatch(name, out_token, queue, handler);
    if (st == NOTIFY_STATUS_OK && out_token != NULL && name != NULL &&
        strcmp(name, "com.apple.system.thermalpressurelevel") == 0) {
        pt_record_thermal_notify_token(*out_token);
    }
    return st;
}

static uint32_t pt_notify_cancel(int token) {
    pt_remove_thermal_notify_token(token);
    return notify_cancel(token);
}

static uint32_t pt_notify_get_state(int token, uint64_t *state64) {
    uint32_t st = notify_get_state(token, state64);
    if (st == NOTIFY_STATUS_OK && state64 != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_thermal_notify_token(token)) {
        *state64 = 0ULL;
    }
    return st;
}

static long pt_sysconf(int name) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        const pt_device_profile_t *profile = pt_get_active_device_profile();
        switch (name) {
            case _SC_NPROCESSORS_CONF:
            case _SC_NPROCESSORS_ONLN:
                return (long)profile->cores;
            case _SC_PAGESIZE:
                return 16384L;
            case _SC_PHYS_PAGES:
                return (long)(profile->ram_bytes / 16384ULL);
            default:
                break;
        }
    }
    return sysconf(name);
}

static size_t pt_confstr(int name, char *buf, size_t len) {
    size_t ret = confstr(name, buf, len);
    if (ret > 0 && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (name == _CS_PATH) {
            static const char kIosPath[] = "/usr/bin:/bin:/usr/sbin:/sbin";
            if (buf != NULL && len > 0) {
                strlcpy(buf, kIosPath, len);
            }
            return sizeof(kIosPath);
        }
        if (name == _CS_DARWIN_USER_DIR ||
            name == _CS_DARWIN_USER_TEMP_DIR ||
            name == _CS_DARWIN_USER_CACHE_DIR) {
            pt_ensure_data_container_map();
            const char *sub = (name == _CS_DARWIN_USER_TEMP_DIR) ? "/tmp/" :
                              (name == _CS_DARWIN_USER_CACHE_DIR) ? "/Library/Caches/" : "/";
            const char *base_dir = (s_virtual_private_data_len > 0) ? s_virtual_private_data_dir : "/private/var/mobile";
            char vpath[PATH_MAX];
            int n = snprintf(vpath, sizeof(vpath), "%s%s", base_dir, sub);
            if (n > 0 && (size_t)n < sizeof(vpath)) {
                if (buf != NULL && len > 0) {
                    strlcpy(buf, vpath, len);
                }
                return (size_t)n + 1;
            }
            if (buf != NULL && len > 0) {
                char vout[PATH_MAX];
                const char *virt = pt_virtualize_path_for_app(buf, vout, sizeof(vout), NO);
                if (virt != buf) {
                    return strlcpy(buf, virt, len) + 1;
                }
            }
        }
    }
    return ret;
}


__attribute__((visibility("hidden"))) BOOL pt_is_hidden_thread_name(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return NO;
    }
    if (strcmp(name, "com.apple.NSEventThread") == 0 ||
        strncmp(name, "NIO-", 4) == 0 ||
        strcasestr(name, "NSEventThread") != NULL ||
        strcasestr(name, "SwordRPC") != NULL ||
        strcasestr(name, "PlayTools") != NULL ||
        strcasestr(name, "PlayCover") != NULL ||
        strcasestr(name, "MacOver") != NULL ||
        strcasestr(name, "PlayChain") != NULL ||
        strcasestr(name, "PlaySettings") != NULL ||
        strcasestr(name, "PlayShadow") != NULL ||
        strcasestr(name, "PTMediaVolume") != NULL) {
        return YES;
    }
    return NO;
}

static BOOL pt_is_hidden_mach_thread(thread_act_t thr) {
    if (thr == MACH_PORT_NULL) {
        return NO;
    }
    pthread_t pt = pthread_from_mach_thread_np(thr);
    if (pt != NULL) {
        char tname[MAXTHREADNAMESIZE];
        tname[0] = '\0';
        if (pthread_getname_np(pt, tname, sizeof(tname)) == 0 &&
            pt_is_hidden_thread_name(tname)) {
            return YES;
        }
    }
    thread_identifier_info_data_t id_info;
    mach_msg_type_number_t id_cnt = THREAD_IDENTIFIER_INFO_COUNT;
    if (thread_info(thr, THREAD_IDENTIFIER_INFO, (thread_info_t)&id_info, &id_cnt) == KERN_SUCCESS) {
        struct proc_threadinfo pinfo;
        int n = proc_pidinfo(getpid(), PROC_PIDTHREADINFO, id_info.thread_id, &pinfo, (int)sizeof(pinfo));
        if (n > 0 && (size_t)n >= sizeof(pinfo) && pt_is_hidden_thread_name(pinfo.pth_name)) {
            return YES;
        }
    }
    return NO;
}

static kern_return_t pt_task_threads(task_inspect_t target_task,
                                    thread_act_array_t *act_list,
                                    mach_msg_type_number_t *act_listCnt) {
    kern_return_t kr = task_threads(target_task, act_list, act_listCnt);
    if (kr != KERN_SUCCESS || act_list == NULL || *act_list == NULL ||
        act_listCnt == NULL || *act_listCnt == 0) {
        return kr;
    }
    if (target_task != mach_task_self() ||
        !pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return kr;
    }
    mach_msg_type_number_t orig_cnt = *act_listCnt;
    thread_act_t *orig_list = *act_list;
    thread_act_t stack_kept[256];
    thread_act_t *kept_buf = stack_kept;
    if (orig_cnt > (mach_msg_type_number_t)(sizeof(stack_kept) / sizeof(stack_kept[0]))) {
        kept_buf = (thread_act_t *)malloc((size_t)orig_cnt * sizeof(thread_act_t));
        if (kept_buf == NULL) {
            return kr;
        }
    }
    mach_msg_type_number_t kept = 0;
    for (mach_msg_type_number_t i = 0; i < orig_cnt; i++) {
        thread_act_t thr = orig_list[i];
        if (pt_is_hidden_mach_thread(thr)) {
            mach_port_deallocate(mach_task_self(), thr);
        } else {
            kept_buf[kept++] = thr;
        }
    }
    if (kept < orig_cnt) {
        if (kept == 0) {
            vm_deallocate(mach_task_self(), (vm_address_t)orig_list, (vm_size_t)(orig_cnt * sizeof(thread_act_t)));
            *act_list = NULL;
            *act_listCnt = 0;
        } else {
            vm_address_t new_addr = 0;
            if (vm_allocate(mach_task_self(), &new_addr, (vm_size_t)(kept * sizeof(thread_act_t)), VM_FLAGS_ANYWHERE) == KERN_SUCCESS) {
                thread_act_t *new_list = (thread_act_t *)new_addr;
                memcpy(new_list, kept_buf, (size_t)kept * sizeof(thread_act_t));
                vm_deallocate(mach_task_self(), (vm_address_t)orig_list, (vm_size_t)(orig_cnt * sizeof(thread_act_t)));
                *act_list = new_list;
                *act_listCnt = kept;
            } else {
                memcpy(orig_list, kept_buf, (size_t)kept * sizeof(thread_act_t));
                *act_listCnt = kept;
            }
        }
    }
    if (kept_buf != stack_kept) {
        free(kept_buf);
    }
    return KERN_SUCCESS;
}

static int pt_pthread_getname_np(pthread_t thread, char *name, size_t len) {
    int ret = pthread_getname_np(thread, name, len);
    if (ret == 0 && name != NULL && len > 0 &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_is_hidden_thread_name(name)) {
            name[0] = '\0';
        }
    }
    return ret;
}

static kern_return_t pt_thread_info(thread_inspect_t target_act,
                                    thread_flavor_t flavor,
                                    thread_info_t thread_info_out,
                                    mach_msg_type_number_t *thread_info_outCnt) {
    kern_return_t kr = thread_info(target_act, flavor, thread_info_out, thread_info_outCnt);
    if (kr == KERN_SUCCESS &&
        flavor == THREAD_EXTENDED_INFO &&
        thread_info_out != NULL &&
        thread_info_outCnt != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        size_t out_bytes = (size_t)(*thread_info_outCnt) * sizeof(integer_t);
        if (out_bytes >= offsetof(thread_extended_info_data_t, pth_name) +
                         sizeof(((thread_extended_info_data_t *)0)->pth_name)) {
            thread_extended_info_data_t *ext = (thread_extended_info_data_t *)thread_info_out;
            char namebuf[sizeof(ext->pth_name) + 1];
            size_t nlen = strnlen(ext->pth_name, sizeof(ext->pth_name));
            memcpy(namebuf, ext->pth_name, nlen);
            namebuf[nlen] = '\0';
            if (pt_is_hidden_thread_name(namebuf)) {
                memset(ext->pth_name, 0, sizeof(ext->pth_name));
            }
        }
    }
    return kr;
}


static pid_t pt_fork(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        PT_DEBUG_TRACE("spoofer", "blocked fork with EPERM");
        errno = EPERM;
        return -1;
    }
    return fork();
}

static pid_t pt_vfork(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        errno = EPERM;
        return -1;
    }
    // Returning from an interposed wrapper after vfork() is undefined behavior on the parent stack.
    return fork();
}

extern FILE *pt_orig_popen_darwin_extsn(const char *, const char *) __asm("_popen$DARWIN_EXTSN");

static FILE *pt_popen(const char *command, const char *mode) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        errno = EPERM;
        return NULL;
    }
    return popen(command, mode);
}

static FILE *pt_popen_darwin_extsn(const char *command, const char *mode) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        errno = EPERM;
        return NULL;
    }
    return pt_orig_popen_darwin_extsn(command, mode);
}

static int pt_posix_spawn(pid_t * restrict pid,
                          const char * restrict path,
                          const posix_spawn_file_actions_t *file_actions,
                          const posix_spawnattr_t * restrict attrp,
                          char *const argv[restrict],
                          char *const envp[restrict]) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        PT_DEBUG_TRACE("spoofer", "blocked posix_spawn path=%s", path != NULL ? path : "<null>");
        return EPERM;
    }
    return posix_spawn(pid, path, file_actions, attrp, argv, envp);
}

static int pt_posix_spawnp(pid_t * restrict pid,
                           const char * restrict file,
                           const posix_spawn_file_actions_t *file_actions,
                           const posix_spawnattr_t * restrict attrp,
                           char *const argv[restrict],
                           char *const envp[restrict]) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return EPERM;
    }
    return posix_spawnp(pid, file, file_actions, attrp, argv, envp);
}

extern int pt_orig_system(const char *) __asm("_system");
static int pt_system(const char *command) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (command == NULL) {
            return 0;
        }
        errno = EPERM;
        return -1;
    }
    return pt_orig_system(command);
}

static pid_t pt_getppid(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return 1;
    }
    return getppid();
}

static int pt_isatty(int fd) {
    if (fd < 0) {
        errno = EBADF;
        return 0;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        fd >= 0 && fd <= 2) {
        return 0;
    }
    return isatty(fd);
}


__attribute__((visibility("hidden"))) dispatch_once_t thread_sleep_once;
__attribute__((visibility("hidden"))) dispatch_semaphore_t thread_sleep_sem = nil;
__attribute__((visibility("hidden"))) _Atomic int s_block_sleep_spamming_cached = -1;
static pthread_once_t s_sleep_setting_once = PTHREAD_ONCE_INIT;
static _Thread_local uint32_t tls_sleep_counter = 0;
static _Thread_local uint64_t tls_sleep_timestamp = 0;

static void pt_init_sleep_setting(void) {
    @autoreleasepool {
        atomic_store_explicit(&s_block_sleep_spamming_cached,
                              [[PlaySettings shared] blockSleepSpamming] ? 1 : 0,
                              memory_order_release);
    }
}

static int pt_usleep(useconds_t usec) {
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return usleep(usec);
    }
    if (atomic_load_explicit(&s_pt_loaded, memory_order_acquire) &&
        atomic_load_explicit(&s_block_sleep_spamming_cached, memory_order_acquire) < 0) {
        pthread_once(&s_sleep_setting_once, pt_init_sleep_setting);
    }
    if (atomic_load_explicit(&s_block_sleep_spamming_cached, memory_order_acquire) == 1) {
        dispatch_once(&thread_sleep_once, ^{
            thread_sleep_sem = dispatch_semaphore_create(0);
        });
        if (usec == 100000) {
            uint64_t now = (uint64_t)time(NULL);
            if (now >= tls_sleep_timestamp && (now - tls_sleep_timestamp) < 2) {
                tls_sleep_counter++;
            } else {
                tls_sleep_counter = 1;
            }
            tls_sleep_timestamp = now;
        }
        if (tls_sleep_counter > 100) {
            PT_DEBUG_TRACE("spoofer", "stalled sleep-spamming thread usec=%u count=%u",
                           (unsigned int)usec, tls_sleep_counter);
            dispatch_semaphore_wait(thread_sleep_sem, DISPATCH_TIME_FOREVER);
            dispatch_semaphore_signal(thread_sleep_sem);
            return 0;
        }
    }
    return usleep(usec);
}

extern size_t os_proc_available_memory(void);

static uint64_t pt_compute_spoofed_available_memory_with_footprint(uint64_t footprint) {
    uint64_t limit = (pt_get_spoofed_physical_memory() * 65ULL) / 100ULL;
    limit &= ~(16384ULL - 1ULL);
    uint64_t floor_bytes = 128ULL << 20;
    if (limit > footprint + floor_bytes) {
        return (limit - footprint) & ~(16384ULL - 1ULL);
    }
    return floor_bytes;
}

static uint64_t pt_compute_spoofed_available_memory(void) {
    uint64_t limit = ((pt_get_spoofed_physical_memory() * 65ULL) / 100ULL) & ~(16384ULL - 1ULL);
    task_vm_info_data_t vm_info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm_info, &count) == KERN_SUCCESS &&
        count >= TASK_VM_INFO_REV1_COUNT) {
        return pt_compute_spoofed_available_memory_with_footprint((uint64_t)vm_info.phys_footprint);
    }
    return (limit / 2ULL) & ~(16384ULL - 1ULL);
}

static size_t pt_os_proc_available_memory(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return (size_t)pt_compute_spoofed_available_memory();
    }
    return os_proc_available_memory();
}

#define PT_SHADOW_DYLD_SLAB_COUNT 32
#define PT_SHADOW_DYLD_MIN_CAP 1024U
#define PT_SHADOW_DYLD_RETIRED_CAP 128U

static os_unfair_lock s_shadow_dyld_lock = OS_UNFAIR_LOCK_INIT;
static struct dyld_all_image_infos s_shadow_dyld_infos;
static uint32_t s_shadow_dyld_real_count = 0;
static uintptr_t s_shadow_dyld_real_uuid_count = 0;
static uint64_t s_shadow_dyld_real_ts = 0;
static struct dyld_image_info *s_shadow_dyld_slabs[PT_SHADOW_DYLD_SLAB_COUNT] = {0};
static uint32_t s_shadow_dyld_slab_caps[PT_SHADOW_DYLD_SLAB_COUNT] = {0};
static struct dyld_uuid_info *s_shadow_uuid_slabs[PT_SHADOW_DYLD_SLAB_COUNT] = {0};
static uintptr_t s_shadow_uuid_slab_caps[PT_SHADOW_DYLD_SLAB_COUNT] = {0};
static uint32_t s_shadow_dyld_slab_idx = 0;
static uint32_t s_shadow_dyld_max_count = 0;
static uintptr_t s_shadow_uuid_max_count = 0;
static BOOL s_shadow_dyld_initialized = NO;
static uint64_t s_shadow_dyld_reg_gen = UINT64_MAX;
static void *s_shadow_dyld_retired_bufs[PT_SHADOW_DYLD_RETIRED_CAP] = {0};
static uint32_t s_shadow_dyld_retired_count = 0;
static uint32_t s_shadow_dyld_retired_ring_idx = 0;

static inline void pt_retire_shadow_dyld_buf(void *buf) {
    if (buf == NULL) {
        return;
    }
    if (s_shadow_dyld_retired_count < PT_SHADOW_DYLD_RETIRED_CAP) {
        s_shadow_dyld_retired_bufs[s_shadow_dyld_retired_count++] = buf;
    } else {
        free(s_shadow_dyld_retired_bufs[s_shadow_dyld_retired_ring_idx]);
        s_shadow_dyld_retired_bufs[s_shadow_dyld_retired_ring_idx] = buf;
        s_shadow_dyld_retired_ring_idx =
            (s_shadow_dyld_retired_ring_idx + 1U) % PT_SHADOW_DYLD_RETIRED_CAP;
    }
}

static inline size_t pt_round_up_dyld_cap(size_t needed) {
    size_t cap = PT_SHADOW_DYLD_MIN_CAP;
    while (cap < needed && cap <= (SIZE_MAX / 2U)) {
        cap <<= 1U;
    }
    return (cap < needed) ? needed : cap;
}

static inline natural_t pt_scale_vm_page_count(natural_t count, uint64_t spoof_pages, uint64_t total_pages) {
    uint64_t scaled = ((uint64_t)count * spoof_pages) / total_pages;
    return (scaled > UINT32_MAX) ? UINT32_MAX : (natural_t)scaled;
}

static void pt_sanitize_host_basic_info_buf(host_basic_info_data_t *info, size_t out_bytes) {
    if (info == NULL) {
        return;
    }
    const pt_device_profile_t *profile = pt_get_active_device_profile();
    integer_t spoof_cores = (integer_t)profile->cores;
    uint64_t spoof_ram = profile->ram_bytes;
    if (out_bytes >= offsetof(host_basic_info_data_t, max_cpus) + sizeof(info->max_cpus)) {
        info->max_cpus = spoof_cores;
    }
    if (out_bytes >= offsetof(host_basic_info_data_t, avail_cpus) + sizeof(info->avail_cpus)) {
        info->avail_cpus = spoof_cores;
    }
    if (out_bytes >= offsetof(host_basic_info_data_t, memory_size) + sizeof(info->memory_size)) {
        info->memory_size = (natural_t)((spoof_ram > 0x80000000ULL) ? 0x80000000ULL : spoof_ram);
    }
    if (out_bytes >= offsetof(host_basic_info_data_t, physical_cpu) + sizeof(info->physical_cpu)) {
        info->physical_cpu = spoof_cores;
    }
    if (out_bytes >= offsetof(host_basic_info_data_t, physical_cpu_max) + sizeof(info->physical_cpu_max)) {
        info->physical_cpu_max = spoof_cores;
    }
    if (out_bytes >= offsetof(host_basic_info_data_t, logical_cpu) + sizeof(info->logical_cpu)) {
        info->logical_cpu = spoof_cores;
    }
    if (out_bytes >= offsetof(host_basic_info_data_t, logical_cpu_max) + sizeof(info->logical_cpu_max)) {
        info->logical_cpu_max = spoof_cores;
    }
    if (out_bytes >= offsetof(host_basic_info_data_t, max_mem) + sizeof(info->max_mem)) {
        info->max_mem = spoof_ram;
    }
}

static kern_return_t pt_host_info(host_t host,
                                  host_flavor_t flavor,
                                  host_info_t host_info_out,
                                  mach_msg_type_number_t *host_info_outCnt) {
    kern_return_t kr = host_info(host, flavor, host_info_out, host_info_outCnt);
    if (kr == KERN_SUCCESS &&
        flavor == HOST_BASIC_INFO &&
        host_info_out != NULL &&
        host_info_outCnt != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        size_t out_bytes = (size_t)(*host_info_outCnt) * sizeof(integer_t);
        pt_sanitize_host_basic_info_buf((host_basic_info_data_t *)host_info_out, out_bytes);
    }
    return kr;
}

static kern_return_t pt_host_processor_info(host_t host,
                                            processor_flavor_t flavor,
                                            natural_t *out_processor_count,
                                            processor_info_array_t *out_processor_info,
                                            mach_msg_type_number_t *out_processor_infoCnt) {
    kern_return_t kr = host_processor_info(host, flavor, out_processor_count, out_processor_info, out_processor_infoCnt);
    if (kr == KERN_SUCCESS &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        natural_t spoof_cores = (natural_t)pt_get_active_device_profile()->cores;
        if (out_processor_count != NULL) {
            natural_t real_cores = *out_processor_count;
            if (spoof_cores > 0 && real_cores > spoof_cores) {
                if (out_processor_infoCnt != NULL && real_cores > 0 && (*out_processor_infoCnt % real_cores) == 0) {
                    *out_processor_infoCnt = (*out_processor_infoCnt / real_cores) * spoof_cores;
                }
                *out_processor_count = spoof_cores;
            }
        }
        if (out_processor_info != NULL && *out_processor_info != NULL &&
            out_processor_infoCnt != NULL && *out_processor_infoCnt > 0 && vm_page_size > 0) {
            size_t used_bytes = (size_t)(*out_processor_infoCnt) * sizeof(integer_t);
            size_t page_sz = (size_t)vm_page_size;
            size_t alloc_bytes = ((used_bytes + page_sz - 1U) / page_sz) * page_sz;
            if (alloc_bytes > used_bytes) {
                memset((uint8_t *)(*out_processor_info) + used_bytes, 0, alloc_bytes - used_bytes);
            }
        }
    }
    return kr;
}

static void pt_sanitize_host_vm_info_buf(vm_statistics_data_t *v, size_t out_bytes) {
    if (v == NULL || out_bytes < offsetof(vm_statistics_data_t, wire_count) + sizeof(natural_t)) {
        return;
    }
    uint64_t page_sz = (vm_page_size > 0) ? (uint64_t)vm_page_size : 16384ULL;
    uint64_t spoof_pages = pt_get_active_device_profile()->ram_bytes / page_sz;
    uint64_t total_pages = (uint64_t)v->free_count + (uint64_t)v->active_count +
                           (uint64_t)v->inactive_count + (uint64_t)v->wire_count;
    if (spoof_pages > 0 && total_pages > spoof_pages) {
        v->free_count = pt_scale_vm_page_count(v->free_count, spoof_pages, total_pages);
        v->active_count = pt_scale_vm_page_count(v->active_count, spoof_pages, total_pages);
        v->inactive_count = pt_scale_vm_page_count(v->inactive_count, spoof_pages, total_pages);
        v->wire_count = pt_scale_vm_page_count(v->wire_count, spoof_pages, total_pages);
        if (out_bytes >= offsetof(vm_statistics_data_t, purgeable_count) + sizeof(v->purgeable_count)) {
            v->purgeable_count = pt_scale_vm_page_count(v->purgeable_count, spoof_pages, total_pages);
        }
        if (out_bytes >= offsetof(vm_statistics_data_t, speculative_count) + sizeof(v->speculative_count)) {
            v->speculative_count = pt_scale_vm_page_count(v->speculative_count, spoof_pages, total_pages);
        }
    }
}

static void pt_sanitize_host_vm_info64_buf(vm_statistics64_data_t *v, size_t out_bytes, BOOL clear_swaps) {
    if (v == NULL || out_bytes < offsetof(vm_statistics64_data_t, wire_count) + sizeof(natural_t)) {
        return;
    }
    uint64_t page_sz = (vm_page_size > 0) ? (uint64_t)vm_page_size : 16384ULL;
    uint64_t spoof_pages = pt_get_active_device_profile()->ram_bytes / page_sz;
    uint64_t total_pages = (uint64_t)v->free_count + (uint64_t)v->active_count +
                           (uint64_t)v->inactive_count + (uint64_t)v->wire_count;
    if (spoof_pages > 0 && total_pages > spoof_pages) {
        v->free_count = pt_scale_vm_page_count(v->free_count, spoof_pages, total_pages);
        v->active_count = pt_scale_vm_page_count(v->active_count, spoof_pages, total_pages);
        v->inactive_count = pt_scale_vm_page_count(v->inactive_count, spoof_pages, total_pages);
        v->wire_count = pt_scale_vm_page_count(v->wire_count, spoof_pages, total_pages);
        if (out_bytes >= offsetof(vm_statistics64_data_t, purgeable_count) + sizeof(v->purgeable_count)) {
            v->purgeable_count = pt_scale_vm_page_count(v->purgeable_count, spoof_pages, total_pages);
        }
        if (out_bytes >= offsetof(vm_statistics64_data_t, speculative_count) + sizeof(v->speculative_count)) {
            v->speculative_count = pt_scale_vm_page_count(v->speculative_count, spoof_pages, total_pages);
        }
        if (out_bytes >= offsetof(vm_statistics64_data_t, compressor_page_count) + sizeof(v->compressor_page_count)) {
            v->compressor_page_count = pt_scale_vm_page_count(v->compressor_page_count, spoof_pages, total_pages);
        }
        if (out_bytes >= offsetof(vm_statistics64_data_t, throttled_count) + sizeof(v->throttled_count)) {
            v->throttled_count = pt_scale_vm_page_count(v->throttled_count, spoof_pages, total_pages);
        }
        if (out_bytes >= offsetof(vm_statistics64_data_t, external_page_count) + sizeof(v->external_page_count)) {
            v->external_page_count = pt_scale_vm_page_count(v->external_page_count, spoof_pages, total_pages);
        }
        if (out_bytes >= offsetof(vm_statistics64_data_t, internal_page_count) + sizeof(v->internal_page_count)) {
            v->internal_page_count = pt_scale_vm_page_count(v->internal_page_count, spoof_pages, total_pages);
        }
    }
    if (clear_swaps) {
        if (out_bytes >= offsetof(vm_statistics64_data_t, swapins) + sizeof(v->swapins)) {
            v->swapins = 0;
        }
        if (out_bytes >= offsetof(vm_statistics64_data_t, swapouts) + sizeof(v->swapouts)) {
            v->swapouts = 0;
        }
    }
}

static kern_return_t pt_host_statistics(host_t host,
                                        host_flavor_t flavor,
                                        host_info_t host_info_out,
                                        mach_msg_type_number_t *host_info_outCnt) {
    kern_return_t kr = host_statistics(host, flavor, host_info_out, host_info_outCnt);
    if (kr == KERN_SUCCESS &&
        flavor == HOST_VM_INFO &&
        host_info_out != NULL &&
        host_info_outCnt != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        size_t out_bytes = (size_t)(*host_info_outCnt) * sizeof(integer_t);
        pt_sanitize_host_vm_info_buf((vm_statistics_data_t *)host_info_out, out_bytes);
    }
    return kr;
}

static kern_return_t pt_host_statistics64(host_t host,
                                          host_flavor_t flavor,
                                          host_info64_t host_info64_out,
                                          mach_msg_type_number_t *host_info64_outCnt) {
    kern_return_t kr = host_statistics64(host, flavor, host_info64_out, host_info64_outCnt);
    if (kr == KERN_SUCCESS &&
        (flavor == HOST_VM_INFO64 || flavor == HOST_VM_INFO) &&
        host_info64_out != NULL &&
        host_info64_outCnt != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        size_t out_bytes = (size_t)(*host_info64_outCnt) * sizeof(integer_t);
        pt_sanitize_host_vm_info64_buf((vm_statistics64_data_t *)host_info64_out, out_bytes, flavor == HOST_VM_INFO64);
    }
    return kr;
}

static void pt_sanitize_task_vm_info_buf(task_vm_info_data_t *vm, size_t out_bytes) {
    if (vm == NULL) {
        return;
    }
    size_t min_bytes = offsetof(task_vm_info_data_t, limit_bytes_remaining) +
                       sizeof(vm->limit_bytes_remaining);
    if (out_bytes >= min_bytes) {
        vm->limit_bytes_remaining = (mach_vm_size_t)pt_compute_spoofed_available_memory_with_footprint(
            (uint64_t)vm->phys_footprint);
    }
}

static void pt_sanitize_task_audit_token_buf(audit_token_t *tok, size_t out_bytes) {
    if (tok != NULL && out_bytes >= sizeof(audit_token_t)) {
        if (tok->val[2] == 20U) {
            tok->val[2] = 501U;
        }
        if (tok->val[4] == 20U) {
            tok->val[4] = 501U;
        }
    }
}

static void pt_sanitize_task_security_token_buf(security_token_t *tok, size_t out_bytes) {
    if (tok != NULL && out_bytes >= sizeof(security_token_t)) {
        if (tok->val[1] == 20U) {
            tok->val[1] = 501U;
        }
    }
}

static void pt_sanitize_task_dyld_info_buf(task_dyld_info_data_t *dyld_info, size_t out_bytes) {
    if (dyld_info == NULL || out_bytes < sizeof(task_dyld_info_data_t)) {
        return;
    }
    if (dyld_info->all_image_info_addr != 0 &&
        (dyld_info->all_image_info_format == TASK_DYLD_ALL_IMAGE_INFO_64 ||
         dyld_info->all_image_info_format == TASK_DYLD_ALL_IMAGE_INFO_32)) {
        const struct dyld_all_image_infos *real_infos =
            (const struct dyld_all_image_infos *)(uintptr_t)dyld_info->all_image_info_addr;
        os_unfair_lock_lock(&s_shadow_dyld_lock);
            uint32_t cur_real_count = __atomic_load_n(&real_infos->infoArrayCount, __ATOMIC_ACQUIRE);
            uint64_t cur_real_ts = __atomic_load_n(&real_infos->infoArrayChangeTimestamp, __ATOMIC_ACQUIRE);
            const struct dyld_image_info *cur_real_arr = __atomic_load_n(&real_infos->infoArray, __ATOMIC_ACQUIRE);
            uintptr_t cur_uuid_cnt = __atomic_load_n(&real_infos->uuidArrayCount, __ATOMIC_ACQUIRE);
            uint64_t cur_reg_gen = pt_hidden_registry_generation();
            if (cur_real_arr != NULL &&
                (!s_shadow_dyld_initialized ||
                 s_shadow_dyld_infos.infoArray == NULL ||
                 s_shadow_dyld_reg_gen != cur_reg_gen ||
                 s_shadow_dyld_real_count != cur_real_count ||
                 s_shadow_dyld_real_uuid_count != cur_uuid_cnt ||
                 s_shadow_dyld_real_ts != cur_real_ts)) {
                uint32_t next_slot = (s_shadow_dyld_slab_idx + 1U) & (PT_SHADOW_DYLD_SLAB_COUNT - 1U);
                for (int attempt = 0; attempt < 4; attempt++) {
                    uint64_t ts_before = __atomic_load_n(&real_infos->infoArrayChangeTimestamp, __ATOMIC_ACQUIRE);
                    uint32_t real_count = __atomic_load_n(&real_infos->infoArrayCount, __ATOMIC_ACQUIRE);
                    const struct dyld_image_info *real_arr = __atomic_load_n(&real_infos->infoArray, __ATOMIC_ACQUIRE);
                    uintptr_t real_uuid_cnt = __atomic_load_n(&real_infos->uuidArrayCount, __ATOMIC_ACQUIRE);
                    const struct dyld_uuid_info *real_uuid_arr = __atomic_load_n(&real_infos->uuidArray, __ATOMIC_ACQUIRE);
                    if (real_arr == NULL) {
                        break;
                    }

                    uint32_t min_needed = (real_count > s_shadow_dyld_max_count) ? real_count : s_shadow_dyld_max_count;
                    if (min_needed == 0U) {
                        min_needed = 1U;
                    }
                    size_t rounded_cap = pt_round_up_dyld_cap((size_t)min_needed);
                    uint32_t needed_cap = (rounded_cap > (size_t)UINT32_MAX) ? min_needed : (uint32_t)rounded_cap;
                    struct dyld_image_info *filtered = s_shadow_dyld_slabs[next_slot];
                    uint32_t slab_cap = s_shadow_dyld_slab_caps[next_slot];
                    if (filtered == NULL || slab_cap < needed_cap) {
                        struct dyld_image_info *grown =
                            (struct dyld_image_info *)calloc(needed_cap, sizeof(struct dyld_image_info));
                        if (grown == NULL) {
                            break;
                        }
                        pt_retire_shadow_dyld_buf(filtered);
                        filtered = grown;
                        slab_cap = needed_cap;
                        s_shadow_dyld_slabs[next_slot] = filtered;
                        s_shadow_dyld_slab_caps[next_slot] = slab_cap;
                    }

                    uintptr_t min_uuid_needed =
                        (real_uuid_cnt > s_shadow_uuid_max_count) ? real_uuid_cnt : s_shadow_uuid_max_count;
                    if (min_uuid_needed == 0U) {
                        min_uuid_needed = 1U;
                    }
                    size_t rounded_uuid_cap = pt_round_up_dyld_cap((size_t)min_uuid_needed);
                    uintptr_t needed_uuid_cap =
                        (rounded_uuid_cap < (size_t)min_uuid_needed) ? min_uuid_needed : (uintptr_t)rounded_uuid_cap;
                    struct dyld_uuid_info *filtered_uuids = s_shadow_uuid_slabs[next_slot];
                    uintptr_t uuid_slab_cap = s_shadow_uuid_slab_caps[next_slot];
                    if (filtered_uuids == NULL || uuid_slab_cap < needed_uuid_cap) {
                        struct dyld_uuid_info *grown_uuids =
                            (struct dyld_uuid_info *)calloc(needed_uuid_cap, sizeof(struct dyld_uuid_info));
                        if (grown_uuids == NULL) {
                            break;
                        }
                        pt_retire_shadow_dyld_buf(filtered_uuids);
                        filtered_uuids = grown_uuids;
                        uuid_slab_cap = needed_uuid_cap;
                        s_shadow_uuid_slabs[next_slot] = filtered_uuids;
                        s_shadow_uuid_slab_caps[next_slot] = uuid_slab_cap;
                    }

                    const struct mach_header *hidden_mhs[128];
                    size_t hidden_mh_count = 0;
                    uint32_t write_idx = 0;
                    for (uint32_t i = 0; i < real_count; i++) {
                        const char *img_path = real_arr[i].imageFilePath;
                        if (pt_should_hide_dyld_image(img_path) ||
                            pt_is_hidden_dyld_image_header(real_arr[i].imageLoadAddress)) {
                            if (real_arr[i].imageLoadAddress != NULL &&
                                hidden_mh_count < sizeof(hidden_mhs) / sizeof(hidden_mhs[0])) {
                                hidden_mhs[hidden_mh_count++] = real_arr[i].imageLoadAddress;
                            }
                            continue;
                        }
                        filtered[write_idx] = real_arr[i];
                        if (img_path != NULL) {
                            filtered[write_idx].imageFilePath = pt_sanitize_image_path_for_app(img_path);
                        }
                        write_idx++;
                    }
                    if (write_idx < slab_cap) {
                        memset(&filtered[write_idx], 0, (size_t)(slab_cap - write_idx) * sizeof(struct dyld_image_info));
                    }

                    uintptr_t uuid_write_idx = 0;
                    if (real_uuid_arr != NULL && real_uuid_cnt > 0) {
                        for (uintptr_t j = 0; j < real_uuid_cnt; j++) {
                            const struct mach_header *umh = real_uuid_arr[j].imageLoadAddress;
                            BOOL hide_uuid = NO;
                            for (size_t k = 0; k < hidden_mh_count; k++) {
                                if (hidden_mhs[k] == umh) {
                                    hide_uuid = YES;
                                    break;
                                }
                            }
                            if (!hide_uuid && umh != NULL) {
                                const char *upath = dyld_image_path_containing_address((const void *)umh);
                                if (upath != NULL && pt_should_hide_dyld_image(upath)) {
                                    hide_uuid = YES;
                                }
                            }
                            if (!hide_uuid) {
                                filtered_uuids[uuid_write_idx++] = real_uuid_arr[j];
                            }
                        }
                    }
                    if (uuid_write_idx < uuid_slab_cap) {
                        memset(&filtered_uuids[uuid_write_idx], 0,
                               (size_t)(uuid_slab_cap - uuid_write_idx) * sizeof(struct dyld_uuid_info));
                    }

                    uint64_t ts_after = __atomic_load_n(&real_infos->infoArrayChangeTimestamp, __ATOMIC_ACQUIRE);
                    if (ts_after != ts_before ||
                        __atomic_load_n(&real_infos->infoArrayCount, __ATOMIC_ACQUIRE) != real_count ||
                        __atomic_load_n(&real_infos->uuidArrayCount, __ATOMIC_ACQUIRE) != real_uuid_cnt) {
                        continue;
                    }

                    s_shadow_dyld_slab_idx = next_slot;
                    if (real_count > s_shadow_dyld_max_count) {
                        s_shadow_dyld_max_count = real_count;
                    }
                    if (real_uuid_cnt > s_shadow_uuid_max_count) {
                        s_shadow_uuid_max_count = real_uuid_cnt;
                    }

                    if (!s_shadow_dyld_initialized) {
                        struct dyld_all_image_infos tmp_infos;
                        memset(&tmp_infos, 0, sizeof(tmp_infos));
                        size_t copy_bytes = sizeof(tmp_infos);
                        if (dyld_info->all_image_info_size > 0 && (size_t)dyld_info->all_image_info_size < copy_bytes) {
                            copy_bytes = (size_t)dyld_info->all_image_info_size;
                        }
                        memcpy(&tmp_infos, real_infos, copy_bytes);
                        tmp_infos.infoArrayCount = write_idx;
                        tmp_infos.infoArray = filtered;
                        tmp_infos.uuidArrayCount = uuid_write_idx;
                        tmp_infos.uuidArray = (uuid_write_idx > 0) ? filtered_uuids : NULL;
                        tmp_infos.dyldAllImageInfosAddress = &s_shadow_dyld_infos;
                        if (tmp_infos.initialImageCount > write_idx) {
                            tmp_infos.initialImageCount = write_idx;
                        }
                        if (tmp_infos.dyldPath != NULL) {
                            tmp_infos.dyldPath = "/usr/lib/dyld";
                        }
                        if (tmp_infos.version >= 16) {
                            tmp_infos.platform = PLATFORM_IOS;
                        }
                        tmp_infos.errorMessage = NULL;
                        tmp_infos.errorKind = 0;
                        tmp_infos.errorClientOfDylibPath = NULL;
                        tmp_infos.errorTargetDylibPath = NULL;
                        tmp_infos.errorSymbol = NULL;
                        tmp_infos.compact_dyld_image_info_addr = 0;
                        tmp_infos.compact_dyld_image_info_size = 0;
                        tmp_infos.aotInfoCount = 0;
                        tmp_infos.aotInfoArray = NULL;
                        tmp_infos.aotInfoArrayChangeTimestamp = 0;
                        tmp_infos.aotSharedCacheBaseAddress = 0;
                        memset(tmp_infos.aotSharedCacheUUID, 0, sizeof(tmp_infos.aotSharedCacheUUID));
                        tmp_infos.infoArrayChangeTimestamp = ts_after;
                        atomic_thread_fence(memory_order_release);
                        memcpy(&s_shadow_dyld_infos, &tmp_infos, sizeof(s_shadow_dyld_infos));
                        atomic_thread_fence(memory_order_release);
                        s_shadow_dyld_initialized = YES;
                    } else {
                        atomic_thread_fence(memory_order_release);
                        if (write_idx < s_shadow_dyld_infos.infoArrayCount) {
                            __atomic_store_n(&s_shadow_dyld_infos.infoArrayCount, write_idx, __ATOMIC_RELEASE);
                            atomic_thread_fence(memory_order_release);
                        }
                        __atomic_store_n(&s_shadow_dyld_infos.infoArray, filtered, __ATOMIC_RELEASE);
                        atomic_thread_fence(memory_order_release);
                        __atomic_store_n(&s_shadow_dyld_infos.infoArrayCount, write_idx, __ATOMIC_RELEASE);

                        if (uuid_write_idx < s_shadow_dyld_infos.uuidArrayCount) {
                            __atomic_store_n(&s_shadow_dyld_infos.uuidArrayCount, uuid_write_idx, __ATOMIC_RELEASE);
                            atomic_thread_fence(memory_order_release);
                        }
                        __atomic_store_n(&s_shadow_dyld_infos.uuidArray,
                                         (uuid_write_idx > 0) ? filtered_uuids : NULL,
                                         __ATOMIC_RELEASE);
                        atomic_thread_fence(memory_order_release);
                        __atomic_store_n(&s_shadow_dyld_infos.uuidArrayCount, uuid_write_idx, __ATOMIC_RELEASE);

                        uintptr_t real_init = real_infos->initialImageCount;
                        uintptr_t clamped_init = (real_init > write_idx) ? (uintptr_t)write_idx : real_init;
                        __atomic_store_n(&s_shadow_dyld_infos.initialImageCount, clamped_init, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.compact_dyld_image_info_addr, (uintptr_t)0, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.compact_dyld_image_info_size, (size_t)0, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.aotInfoCount, (uint32_t)0, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.aotInfoArray, (const struct dyld_aot_image_info *)NULL, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.aotInfoArrayChangeTimestamp, (uint64_t)0, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.aotSharedCacheBaseAddress, (uintptr_t)0, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.errorMessage, (const char *)NULL, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.errorKind, (uintptr_t)0, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.errorClientOfDylibPath, (const char *)NULL, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.errorTargetDylibPath, (const char *)NULL, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.errorSymbol, (const char *)NULL, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.infoArrayChangeTimestamp, ts_after, __ATOMIC_RELEASE);
                    }
                    s_shadow_dyld_reg_gen = cur_reg_gen;
                    s_shadow_dyld_real_count = real_count;
                    s_shadow_dyld_real_uuid_count = real_uuid_cnt;
                    s_shadow_dyld_real_ts = ts_after;
                    break;
                }
            }
            if (s_shadow_dyld_initialized && s_shadow_dyld_infos.infoArray != NULL) {
                dyld_info->all_image_info_addr = (mach_vm_address_t)(uintptr_t)&s_shadow_dyld_infos;
                dyld_info->all_image_info_size = sizeof(s_shadow_dyld_infos);
            }
            os_unfair_lock_unlock(&s_shadow_dyld_lock);
    }
}

static kern_return_t pt_task_info(task_name_t target_task,
                                  task_flavor_t flavor,
                                  task_info_t task_info_out,
                                  mach_msg_type_number_t *task_info_outCnt) {
    kern_return_t kr = task_info(target_task, flavor, task_info_out, task_info_outCnt);
    if (kr != KERN_SUCCESS ||
        target_task != mach_task_self() ||
        task_info_out == NULL ||
        task_info_outCnt == NULL ||
        !pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return kr;
    }

    size_t out_bytes = (size_t)(*task_info_outCnt) * sizeof(natural_t);
    if (flavor == TASK_VM_INFO || flavor == TASK_VM_INFO_PURGEABLE) {
        pt_sanitize_task_vm_info_buf((task_vm_info_data_t *)task_info_out, out_bytes);
    } else if (flavor == TASK_AUDIT_TOKEN) {
        pt_sanitize_task_audit_token_buf((audit_token_t *)task_info_out, out_bytes);
    } else if (flavor == TASK_SECURITY_TOKEN) {
        pt_sanitize_task_security_token_buf((security_token_t *)task_info_out, out_bytes);
    } else if (flavor == TASK_DYLD_INFO) {
        pt_sanitize_task_dyld_info_buf((task_dyld_info_data_t *)task_info_out, out_bytes);
    }
    return kr;
}

extern kern_return_t pt_orig_vm_region_64(
    vm_map_read_t target_task,
    vm_address_t *address,
    vm_size_t *size,
    vm_region_flavor_t flavor,
    vm_region_info_t info,
    mach_msg_type_number_t *infoCnt,
    mach_port_t *object_name) __asm("_vm_region_64");

extern kern_return_t pt_orig_vm_region_recurse_64(
    vm_map_read_t target_task,
    vm_address_t *address,
    vm_size_t *size,
    natural_t *nesting_depth,
    vm_region_recurse_info_t info,
    mach_msg_type_number_t *infoCnt) __asm("_vm_region_recurse_64");

extern kern_return_t pt_orig_mach_vm_region(
    vm_map_read_t target_task,
    mach_vm_address_t *address,
    mach_vm_size_t *size,
    vm_region_flavor_t flavor,
    vm_region_info_t info,
    mach_msg_type_number_t *infoCnt,
    mach_port_t *object_name) __asm("_mach_vm_region");

extern kern_return_t pt_orig_mach_vm_region_recurse(
    vm_map_read_t target_task,
    mach_vm_address_t *address,
    mach_vm_size_t *size,
    natural_t *nesting_depth,
    vm_region_recurse_info_t info,
    mach_msg_type_number_t *infoCnt) __asm("_mach_vm_region_recurse");

extern kern_return_t pt_orig_vm_read_overwrite(
    vm_map_read_t target_task,
    vm_address_t address,
    vm_size_t size,
    vm_address_t data,
    vm_size_t *outsize) __asm("_vm_read_overwrite");

extern kern_return_t pt_orig_mach_vm_read_overwrite(
    vm_map_read_t target_task,
    mach_vm_address_t address,
    mach_vm_size_t size,
    mach_vm_address_t data,
    mach_vm_size_t *outsize) __asm("_mach_vm_read_overwrite");

extern kern_return_t pt_orig_vm_read(
    vm_map_read_t target_task,
    vm_address_t address,
    vm_size_t size,
    vm_offset_t *data,
    mach_msg_type_number_t *dataCnt) __asm("_vm_read");

extern kern_return_t pt_orig_mach_vm_read(
    vm_map_read_t target_task,
    mach_vm_address_t address,
    mach_vm_size_t size,
    vm_offset_t *data,
    mach_msg_type_number_t *dataCnt) __asm("_mach_vm_read");

static vm_prot_t pt_extract_vm_region_prot(vm_region_flavor_t flavor,
                                           const void *info,
                                           mach_msg_type_number_t infoCnt,
                                           BOOL is_recurse) {
    if (info == NULL) {
        return 0;
    }
    if (is_recurse) {
        if (infoCnt >= VM_REGION_SUBMAP_SHORT_INFO_COUNT_64) {
            return ((const vm_region_submap_short_info_data_64_t *)info)->protection;
        }
        return 0;
    }
    switch (flavor) {
        case VM_REGION_BASIC_INFO_64:
            if (infoCnt >= VM_REGION_BASIC_INFO_COUNT_64) {
                return ((const vm_region_basic_info_data_64_t *)info)->protection;
            }
            return 0;
        case VM_REGION_BASIC_INFO:
            if (infoCnt >= VM_REGION_BASIC_INFO_COUNT) {
                return ((const vm_region_basic_info_data_t *)info)->protection;
            }
            return 0;
        case VM_REGION_EXTENDED_INFO:
            if (infoCnt >= VM_REGION_EXTENDED_INFO_COUNT) {
                return ((const vm_region_extended_info_data_t *)info)->protection;
            }
            return 0;
        default:
            return 0;
    }
}

#define PT_CPU_TYPE_APPLE_GPU ((cpu_type_t)0x01000013)

static inline BOOL pt_is_sanitizable_macho_cputype(cpu_type_t ct) {
    return (ct == CPU_TYPE_ARM64 || ct == PT_CPU_TYPE_APPLE_GPU);
}

__attribute__((visibility("hidden")))
BOOL pt_is_hidden_unregistered_macho_region(uintptr_t addr, uintptr_t size, vm_prot_t prot) {
    if ((prot & (VM_PROT_READ | VM_PROT_EXECUTE)) != (VM_PROT_READ | VM_PROT_EXECUTE) ||
        addr == 0 ||
        size < sizeof(struct mach_header_64)) {
        return NO;
    }
    if (dyld_image_header_containing_address((const void *)addr) != NULL) {
        return NO;
    }
    struct mach_header_64 hdr;
    memset(&hdr, 0, sizeof(hdr));
    mach_vm_size_t out_sz = 0;
    kern_return_t kr = pt_orig_mach_vm_read_overwrite(
        mach_task_self(),
        (mach_vm_address_t)addr,
        sizeof(hdr),
        (mach_vm_address_t)(uintptr_t)&hdr,
        &out_sz);
    if (kr != KERN_SUCCESS || out_sz != sizeof(hdr)) {
        return NO;
    }
    return (hdr.magic == MH_MAGIC_64 &&
            hdr.cputype == CPU_TYPE_ARM64 &&
            hdr.sizeofcmds > 0 &&
            hdr.sizeofcmds <= (1U << 20) &&
            (hdr.filetype == MH_DYLIB || hdr.filetype == MH_BUNDLE || hdr.filetype == MH_DYLINKER));
}

static void pt_sanitize_vm_read_buffer(uintptr_t read_start, uint8_t *dst, size_t copied) {
    if (dst == NULL || copied == 0 || read_start > UINTPTR_MAX - copied) {
        return;
    }
    pt_svc_restore_patched_bytes_in_buffer(read_start, dst, copied);
    uintptr_t read_end = read_start + copied;
    const struct mach_header *mh = dyld_image_header_containing_address((const void *)read_start);
    if (mh == NULL && copied > sizeof(struct mach_header_64)) {
        uintptr_t next_page = (read_start + (uintptr_t)0x3FFFU) & ~(uintptr_t)0x3FFFU;
        if (next_page > read_start && next_page < read_end) {
            mh = dyld_image_header_containing_address((const void *)next_page);
        }
    }
    const struct mach_header_64 *mh64 = NULL;
    uintptr_t mh_base = 0;
    size_t real_hdr_total = 0;

    if (mh != NULL && pt_is_valid_user_pointer((const void *)mh)) {
        mh64 = (const struct mach_header_64 *)mh;
        if (mh64->magic != MH_MAGIC_64 ||
            mh64->sizeofcmds == 0 ||
            mh64->sizeofcmds > (1U << 20)) {
            return;
        }
        mh_base = (uintptr_t)mh64;
        real_hdr_total = sizeof(struct mach_header_64) + (size_t)mh64->sizeofcmds;
        if (mh_base > UINTPTR_MAX - real_hdr_total) {
            return;
        }
    } else {
        struct mach_header_64 hdr_copy;
        memset(&hdr_copy, 0, sizeof(hdr_copy));
        uintptr_t cand_base = 0;
        if (copied >= sizeof(struct mach_header_64)) {
            memcpy(&hdr_copy, dst, sizeof(hdr_copy));
            if (hdr_copy.magic == MH_MAGIC_64 &&
                pt_is_sanitizable_macho_cputype(hdr_copy.cputype) &&
                hdr_copy.ncmds > 0 &&
                hdr_copy.ncmds <= 4096U &&
                hdr_copy.sizeofcmds > 0 &&
                hdr_copy.sizeofcmds <= (1U << 20)) {
                cand_base = read_start;
            }
        }
        if (cand_base == 0 && copied > sizeof(struct mach_header_64)) {
            uintptr_t next_page = (read_start + (uintptr_t)0x3FFFU) & ~(uintptr_t)0x3FFFU;
            if (next_page > read_start && next_page + sizeof(struct mach_header_64) <= read_end) {
                memcpy(&hdr_copy, dst + (next_page - read_start), sizeof(hdr_copy));
                if (hdr_copy.magic == MH_MAGIC_64 &&
                    pt_is_sanitizable_macho_cputype(hdr_copy.cputype) &&
                    hdr_copy.ncmds > 0 &&
                    hdr_copy.ncmds <= 4096U &&
                    hdr_copy.sizeofcmds > 0 &&
                    hdr_copy.sizeofcmds <= (1U << 20)) {
                    cand_base = next_page;
                }
            }
        }
        if (cand_base == 0) {
            uintptr_t cur_page = read_start & ~(uintptr_t)0x3FFFU;
            for (int p = 0; p < 4; p++) {
                if (p > 0) {
                    if (cur_page < (uintptr_t)0x4000U) {
                        break;
                    }
                    cur_page -= (uintptr_t)0x4000U;
                }
                if (cur_page == read_start && copied >= sizeof(struct mach_header_64)) {
                    continue;
                }
                if (read_start < cur_page || (read_start - cur_page) > 65536U) {
                    break;
                }
                mach_vm_size_t hdr_out = 0;
                kern_return_t hkr = pt_orig_mach_vm_read_overwrite(
                    mach_task_self(),
                    (mach_vm_address_t)cur_page,
                    sizeof(hdr_copy),
                    (mach_vm_address_t)(uintptr_t)&hdr_copy,
                    &hdr_out);
                if (hkr == KERN_SUCCESS &&
                    hdr_out == sizeof(hdr_copy) &&
                    hdr_copy.magic == MH_MAGIC_64 &&
                    pt_is_sanitizable_macho_cputype(hdr_copy.cputype) &&
                    hdr_copy.ncmds > 0 &&
                    hdr_copy.ncmds <= 4096U &&
                    hdr_copy.sizeofcmds > 0 &&
                    hdr_copy.sizeofcmds <= (1U << 20)) {
                    size_t cand_total = sizeof(struct mach_header_64) + (size_t)hdr_copy.sizeofcmds;
                    if (cur_page <= UINTPTR_MAX - cand_total && read_start < cur_page + cand_total) {
                        cand_base = cur_page;
                        break;
                    }
                }
            }
        }
        if (cand_base == 0) {
            return;
        }
        real_hdr_total = sizeof(struct mach_header_64) + (size_t)hdr_copy.sizeofcmds;
        if (cand_base > UINTPTR_MAX - real_hdr_total) {
            return;
        }
        uintptr_t cand_end = cand_base + real_hdr_total;
        uintptr_t ov_start = (read_start > cand_base) ? read_start : cand_base;
        uintptr_t ov_end = (read_end < cand_end) ? read_end : cand_end;
        if (ov_start >= ov_end) {
            return;
        }
        uint8_t *raw_hdr = (uint8_t *)malloc(real_hdr_total);
        uint8_t *san_hdr = (uint8_t *)malloc(real_hdr_total);
        if (raw_hdr != NULL && san_hdr != NULL) {
            const uint8_t *src_ptr = NULL;
            if (cand_base >= read_start && cand_end <= read_end) {
                src_ptr = dst + (cand_base - read_start);
            } else {
                mach_vm_size_t full_out = 0;
                kern_return_t fkr = pt_orig_mach_vm_read_overwrite(
                    mach_task_self(),
                    (mach_vm_address_t)cand_base,
                    (mach_vm_size_t)real_hdr_total,
                    (mach_vm_address_t)(uintptr_t)raw_hdr,
                    &full_out);
                if (fkr == KERN_SUCCESS && full_out == real_hdr_total) {
                    src_ptr = raw_hdr;
                }
            }
            if (src_ptr != NULL &&
                pt_build_sanitized_mach_header_copy((const struct mach_header_64 *)src_ptr,
                                                    san_hdr,
                                                    real_hdr_total,
                                                    NULL)) {
                size_t dst_off = (size_t)(ov_start - read_start);
                size_t rel_off = (size_t)(ov_start - cand_base);
                size_t ov_len = (size_t)(ov_end - ov_start);
                memcpy(dst + dst_off, san_hdr + rel_off, ov_len);
            }
        }
        free(raw_hdr);
        free(san_hdr);
        return;
    }

    uintptr_t mh_end = mh_base + real_hdr_total;
    uintptr_t ov_start = (read_start > mh_base) ? read_start : mh_base;
    uintptr_t ov_end = (read_end < mh_end) ? read_end : mh_end;
    if (ov_start < ov_end) {
        size_t dst_off = (size_t)(ov_start - read_start);
        size_t rel_off = (size_t)(ov_start - mh_base);
        size_t ov_len = (size_t)(ov_end - ov_start);
        BOOL handled_hdr = NO;

        if (mh == pt_get_main_executable_header()) {
            size_t backup_len = 0;
            const uint8_t *backup_hdr = pt_get_cached_backup_main_mach_header(&backup_len);
            if (backup_hdr != NULL && backup_len >= sizeof(struct mach_header_64)) {
                if (rel_off < backup_len) {
                    size_t copy_len = ov_len;
                    if (copy_len > backup_len - rel_off) {
                        copy_len = backup_len - rel_off;
                    }
                    memcpy(dst + dst_off, backup_hdr + rel_off, copy_len);
                    if (copy_len < ov_len) {
                        memset(dst + dst_off + copy_len, 0, ov_len - copy_len);
                    }
                } else {
                    memset(dst + dst_off, 0, ov_len);
                }
                handled_hdr = YES;
            }
        }

        if (!handled_hdr) {
            uint8_t stack_buf[16384];
            uint8_t *heap_buf = NULL;
            uint8_t *work_buf = stack_buf;
            if (real_hdr_total > sizeof(stack_buf)) {
                heap_buf = (uint8_t *)malloc(real_hdr_total);
                work_buf = heap_buf;
            }
            if (work_buf != NULL &&
                pt_build_sanitized_mach_header_copy(mh64, work_buf, real_hdr_total, NULL)) {
                memcpy(dst + dst_off, work_buf + rel_off, ov_len);
            }
            free(heap_buf);
        }
    }
}

static kern_return_t pt_vm_read_overwrite(vm_map_read_t target_task,
                                          vm_address_t address,
                                          vm_size_t size,
                                          vm_address_t data,
                                          vm_size_t *outsize) {
    kern_return_t kr = pt_orig_vm_read_overwrite(target_task, address, size, data, outsize);
    if (kr == KERN_SUCCESS &&
        outsize != NULL &&
        *outsize > 0 &&
        data != 0 &&
        target_task == mach_task_self() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        pt_sanitize_vm_read_buffer((uintptr_t)address, (uint8_t *)(uintptr_t)data, (size_t)*outsize);
    }
    return kr;
}

static kern_return_t pt_mach_vm_read_overwrite(vm_map_read_t target_task,
                                               mach_vm_address_t address,
                                               mach_vm_size_t size,
                                               mach_vm_address_t data,
                                               mach_vm_size_t *outsize) {
    kern_return_t kr = pt_orig_mach_vm_read_overwrite(target_task, address, size, data, outsize);
    if (kr == KERN_SUCCESS &&
        outsize != NULL &&
        *outsize > 0 &&
        data != 0 &&
        target_task == mach_task_self() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        pt_sanitize_vm_read_buffer((uintptr_t)address, (uint8_t *)(uintptr_t)data, (size_t)*outsize);
    }
    return kr;
}

static kern_return_t pt_vm_read(vm_map_read_t target_task,
                                vm_address_t address,
                                vm_size_t size,
                                vm_offset_t *data,
                                mach_msg_type_number_t *dataCnt) {
    kern_return_t kr = pt_orig_vm_read(target_task, address, size, data, dataCnt);
    if (kr == KERN_SUCCESS &&
        data != NULL &&
        *data != 0 &&
        dataCnt != NULL &&
        *dataCnt > 0 &&
        target_task == mach_task_self() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        pt_sanitize_vm_read_buffer((uintptr_t)address, (uint8_t *)(uintptr_t)(*data), (size_t)(*dataCnt));
    }
    return kr;
}

static kern_return_t pt_mach_vm_read(vm_map_read_t target_task,
                                     mach_vm_address_t address,
                                     mach_vm_size_t size,
                                     vm_offset_t *data,
                                     mach_msg_type_number_t *dataCnt) {
    kern_return_t kr = pt_orig_mach_vm_read(target_task, address, size, data, dataCnt);
    if (kr == KERN_SUCCESS &&
        data != NULL &&
        *data != 0 &&
        dataCnt != NULL &&
        *dataCnt > 0 &&
        target_task == mach_task_self() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        pt_sanitize_vm_read_buffer((uintptr_t)address, (uint8_t *)(uintptr_t)(*data), (size_t)(*dataCnt));
    }
    return kr;
}

#define PT_VM_REGION_MAX_SKIPS 4096

static kern_return_t pt_vm_region_64(vm_map_read_t target_task,
                                     vm_address_t *address,
                                     vm_size_t *size,
                                     vm_region_flavor_t flavor,
                                     vm_region_info_t info,
                                     mach_msg_type_number_t *infoCnt,
                                     mach_port_t *object_name) {
    BOOL filter = (address != NULL && size != NULL && infoCnt != NULL &&
                   target_task == mach_task_self() &&
                   pt_is_bypass_enabled() &&
                   !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    mach_msg_type_number_t orig_cnt = (infoCnt != NULL) ? *infoCnt : 0;
    for (int skip = 0; skip < PT_VM_REGION_MAX_SKIPS; skip++) {
        kern_return_t kr = pt_orig_vm_region_64(target_task, address, size, flavor, info, infoCnt, object_name);
        if (kr != KERN_SUCCESS || !filter) {
            return kr;
        }
        vm_address_t cur_addr = *address;
        vm_size_t cur_size = *size;
        vm_prot_t prot = pt_extract_vm_region_prot(flavor, info, *infoCnt, NO);
        if (!pt_is_hidden_vm_region_range((uintptr_t)cur_addr, (uintptr_t)cur_size) &&
            !pt_is_hidden_unregistered_macho_region((uintptr_t)cur_addr, (uintptr_t)cur_size, prot)) {
            return kr;
        }
        if (object_name != NULL && MACH_PORT_VALID(*object_name)) {
            mach_port_deallocate(mach_task_self(), *object_name);
            *object_name = MACH_PORT_NULL;
        }
        if (cur_size == 0 || cur_addr + cur_size <= cur_addr) {
            return KERN_INVALID_ADDRESS;
        }
        *address = cur_addr + cur_size;
        *infoCnt = orig_cnt;
    }
    return KERN_INVALID_ADDRESS;
}

static kern_return_t pt_vm_region_recurse_64(vm_map_read_t target_task,
                                             vm_address_t *address,
                                             vm_size_t *size,
                                             natural_t *nesting_depth,
                                             vm_region_recurse_info_t info,
                                             mach_msg_type_number_t *infoCnt) {
    BOOL filter = (address != NULL && size != NULL && infoCnt != NULL &&
                   target_task == mach_task_self() &&
                   pt_is_bypass_enabled() &&
                   !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    mach_msg_type_number_t orig_cnt = (infoCnt != NULL) ? *infoCnt : 0;
    natural_t orig_depth = (nesting_depth != NULL) ? *nesting_depth : 0;
    for (int skip = 0; skip < PT_VM_REGION_MAX_SKIPS; skip++) {
        kern_return_t kr = pt_orig_vm_region_recurse_64(target_task, address, size, nesting_depth, info, infoCnt);
        if (kr != KERN_SUCCESS || !filter) {
            return kr;
        }
        vm_address_t cur_addr = *address;
        vm_size_t cur_size = *size;
        vm_prot_t prot = pt_extract_vm_region_prot(0, info, *infoCnt, YES);
        if (!pt_is_hidden_vm_region_range((uintptr_t)cur_addr, (uintptr_t)cur_size) &&
            !pt_is_hidden_unregistered_macho_region((uintptr_t)cur_addr, (uintptr_t)cur_size, prot)) {
            return kr;
        }
        if (cur_size == 0 || cur_addr + cur_size <= cur_addr) {
            return KERN_INVALID_ADDRESS;
        }
        *address = cur_addr + cur_size;
        *infoCnt = orig_cnt;
        if (nesting_depth != NULL) {
            *nesting_depth = orig_depth;
        }
    }
    return KERN_INVALID_ADDRESS;
}

static kern_return_t pt_mach_vm_region(vm_map_read_t target_task,
                                       mach_vm_address_t *address,
                                       mach_vm_size_t *size,
                                       vm_region_flavor_t flavor,
                                       vm_region_info_t info,
                                       mach_msg_type_number_t *infoCnt,
                                       mach_port_t *object_name) {
    BOOL filter = (address != NULL && size != NULL && infoCnt != NULL &&
                   target_task == mach_task_self() &&
                   pt_is_bypass_enabled() &&
                   !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    mach_msg_type_number_t orig_cnt = (infoCnt != NULL) ? *infoCnt : 0;
    for (int skip = 0; skip < PT_VM_REGION_MAX_SKIPS; skip++) {
        kern_return_t kr = pt_orig_mach_vm_region(target_task, address, size, flavor, info, infoCnt, object_name);
        if (kr != KERN_SUCCESS || !filter) {
            return kr;
        }
        mach_vm_address_t cur_addr = *address;
        mach_vm_size_t cur_size = *size;
        vm_prot_t prot = pt_extract_vm_region_prot(flavor, info, *infoCnt, NO);
        if (!pt_is_hidden_vm_region_range((uintptr_t)cur_addr, (uintptr_t)cur_size) &&
            !pt_is_hidden_unregistered_macho_region((uintptr_t)cur_addr, (uintptr_t)cur_size, prot)) {
            return kr;
        }
        if (object_name != NULL && MACH_PORT_VALID(*object_name)) {
            mach_port_deallocate(mach_task_self(), *object_name);
            *object_name = MACH_PORT_NULL;
        }
        if (cur_size == 0 || cur_addr + cur_size <= cur_addr) {
            return KERN_INVALID_ADDRESS;
        }
        *address = cur_addr + cur_size;
        *infoCnt = orig_cnt;
    }
    return KERN_INVALID_ADDRESS;
}

static kern_return_t pt_mach_vm_region_recurse(vm_map_read_t target_task,
                                               mach_vm_address_t *address,
                                               mach_vm_size_t *size,
                                               natural_t *nesting_depth,
                                               vm_region_recurse_info_t info,
                                               mach_msg_type_number_t *infoCnt) {
    BOOL filter = (address != NULL && size != NULL && infoCnt != NULL &&
                   target_task == mach_task_self() &&
                   pt_is_bypass_enabled() &&
                   !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    mach_msg_type_number_t orig_cnt = (infoCnt != NULL) ? *infoCnt : 0;
    natural_t orig_depth = (nesting_depth != NULL) ? *nesting_depth : 0;
    for (int skip = 0; skip < PT_VM_REGION_MAX_SKIPS; skip++) {
        kern_return_t kr = pt_orig_mach_vm_region_recurse(target_task, address, size, nesting_depth, info, infoCnt);
        if (kr != KERN_SUCCESS || !filter) {
            return kr;
        }
        mach_vm_address_t cur_addr = *address;
        mach_vm_size_t cur_size = *size;
        vm_prot_t prot = pt_extract_vm_region_prot(0, info, *infoCnt, YES);
        if (!pt_is_hidden_vm_region_range((uintptr_t)cur_addr, (uintptr_t)cur_size) &&
            !pt_is_hidden_unregistered_macho_region((uintptr_t)cur_addr, (uintptr_t)cur_size, prot)) {
            return kr;
        }
        if (cur_size == 0 || cur_addr + cur_size <= cur_addr) {
            return KERN_INVALID_ADDRESS;
        }
        *address = cur_addr + cur_size;
        *infoCnt = orig_cnt;
        if (nesting_depth != NULL) {
            *nesting_depth = orig_depth;
        }
    }
    return KERN_INVALID_ADDRESS;
}

extern intptr_t pt_orig_syscall(int, ...) __asm("_syscall");

#define PT_XNU_SYSCALL_MAX_ARGS 8

static inline BOOL pt_va_can_pop_uintptr(va_list ap, uintptr_t stack_bot, uintptr_t stack_top) {
#if defined(__aarch64__) && defined(__APPLE__)
    uintptr_t slot = (uintptr_t)ap;
    if (stack_top != 0 && stack_bot < stack_top) {
        return (slot >= stack_bot && slot + sizeof(uintptr_t) <= stack_top);
    }
#elif defined(__x86_64__)
    if (ap[0].gp_offset < 48U) {
        return YES;
    }
    uintptr_t slot = (uintptr_t)ap[0].overflow_arg_area;
    if (stack_top != 0 && stack_bot < stack_top) {
        return (slot >= stack_bot && slot + sizeof(uintptr_t) <= stack_top);
    }
#else
    (void)ap;
    (void)stack_bot;
    (void)stack_top;
#endif
    return YES;
}

#define PT_VA_POP_UINTPTR(ap, bot, top) \
    (pt_va_can_pop_uintptr((ap), (bot), (top)) ? va_arg((ap), uintptr_t) : (uintptr_t)0)

static inline BOOL pt_fcntl_cmd_has_no_arg(int cmd) {
    switch (cmd) {
        case F_GETFD:
        case F_GETFL:
        case F_GETOWN:
#ifdef F_FLUSH_DATA
        case F_FLUSH_DATA:
#endif
#ifdef F_CHKCLEAN
        case F_CHKCLEAN:
#endif
#ifdef F_FULLFSYNC
        case F_FULLFSYNC:
#endif
#ifdef F_FREEZE_FS
        case F_FREEZE_FS:
#endif
#ifdef F_THAW_FS
        case F_THAW_FS:
#endif
#ifdef F_GETPROTECTIONCLASS
        case F_GETPROTECTIONCLASS:
#endif
#ifdef F_GETNOSIGPIPE
        case F_GETNOSIGPIPE:
#endif
#ifdef F_GETPROTECTIONLEVEL
        case F_GETPROTECTIONLEVEL:
#endif
#ifdef F_BARRIERFSYNC
        case F_BARRIERFSYNC:
#endif
#ifdef F_GETLEASE
        case F_GETLEASE:
#endif
            return YES;
        default:
            return NO;
    }
}

__attribute__((visibility("hidden")))
intptr_t pt_syscall_dispatch_with_caller(int number,
                                         const uintptr_t args[PT_XNU_SYSCALL_MAX_ARGS],
                                         const void *caller,
                                         BOOL *out_handled) {
    if (out_handled != NULL) {
        *out_handled = YES;
    }
    if (number == 0 || number == 198) {
        number = (int)args[0];
        if (number == 0 || number == 198) {
            errno = ENOSYS;
            return -1;
        }
        uintptr_t shifted[PT_XNU_SYSCALL_MAX_ARGS] = {0};
        for (int i = 0; i < PT_XNU_SYSCALL_MAX_ARGS - 1; i++) {
            shifted[i] = args[i + 1];
        }
        return pt_syscall_dispatch_with_caller(number, shifted, caller, out_handled);
    }

    switch (number) {
        case 202: { // SYS___sysctl
            int *name = (int *)args[0];
            u_int namelen = (u_int)args[1];
            void *oldp = (void *)args[2];
            size_t *oldlenp = (size_t *)args[3];
            void *newp = (void *)args[4];
            size_t newlen = (size_t)args[5];
            return (intptr_t)pt_sysctl_with_caller(name, namelen, oldp, oldlenp, newp, newlen, caller);
        }
        case 274: { // SYS_sysctlbyname (XNU 6-arg ABI: name, namelen, oldp, oldlenp, newp, newlen)
            const char *name = (const char *)args[0];
            size_t namelen = (size_t)args[1];
            void *oldp = (void *)args[2];
            size_t *oldlenp = (size_t *)args[3];
            void *newp = (void *)args[4];
            size_t newlen = (size_t)args[5];
            if (name != NULL && namelen > 0 && namelen < 256U && pt_is_valid_user_pointer(name)) {
                char nbuf[256];
                size_t slen = strnlen(name, namelen);
                memcpy(nbuf, name, slen);
                nbuf[slen] = '\0';
                return (intptr_t)pt_sysctlbyname_with_caller(nbuf, oldp, oldlenp, newp, newlen, caller);
            }
            return (intptr_t)pt_orig_kernel_sysctlbyname(name, namelen, oldp, oldlenp, newp, newlen);
        }
        case 169: { // SYS_csops
            pid_t pid = (pid_t)args[0];
            unsigned int ops = (unsigned int)args[1];
            void *useraddr = (void *)args[2];
            size_t usersize = (size_t)args[3];
            return (intptr_t)pt_csops_with_caller(pid, ops, useraddr, usersize, caller);
        }
        case 170: { // SYS_csops_audittoken
            pid_t pid = (pid_t)args[0];
            unsigned int ops = (unsigned int)args[1];
            void *useraddr = (void *)args[2];
            size_t usersize = (size_t)args[3];
            audit_token_t *token = (audit_token_t *)(uintptr_t)args[4];
            if (pid == 0 || pid == getpid()) {
                return (intptr_t)pt_csops_audittoken_with_caller(pid, ops, useraddr, usersize, token, caller);
            }
            if (out_handled != NULL) {
                *out_handled = NO;
            }
            return 0;
        }
        case 18:  // SYS_getfsstat
        case 347: { // SYS_getfsstat64
            return (intptr_t)pt_fs_getfsstat_with_caller(
                (struct statfs *)(uintptr_t)args[0],
                (int)args[1],
                (int)args[2],
                caller);
        }
        case 142: { // SYS_gethostuuid
            return (intptr_t)pt_gethostuuid_with_caller(
                (unsigned char *)(uintptr_t)args[0],
                (const struct timespec *)(uintptr_t)args[1],
                caller);
        }
        case 157: // SYS_statfs
        case 345: { // SYS_statfs64
            return (intptr_t)pt_fs_statfs_with_caller(
                (const char *)(uintptr_t)args[0],
                (struct statfs *)(uintptr_t)args[1],
                caller);
        }
        case 158: // SYS_fstatfs
        case 346: { // SYS_fstatfs64
            return (intptr_t)pt_fs_fstatfs_with_caller(
                (int)args[0],
                (struct statfs *)(uintptr_t)args[1],
                caller);
        }
        case 234: { // SYS_getxattr
            return (intptr_t)pt_fs_getxattr_with_caller(
                (const char *)(uintptr_t)args[0],
                (const char *)(uintptr_t)args[1],
                (void *)(uintptr_t)args[2],
                (size_t)args[3],
                (uint32_t)args[4],
                (int)args[5],
                caller);
        }
        case 235: { // SYS_fgetxattr
            return (intptr_t)pt_fs_fgetxattr_with_caller(
                (int)args[0],
                (const char *)(uintptr_t)args[1],
                (void *)(uintptr_t)args[2],
                (size_t)args[3],
                (uint32_t)args[4],
                (int)args[5],
                caller);
        }
        case 240: { // SYS_listxattr
            return (intptr_t)pt_fs_listxattr_with_caller(
                (const char *)(uintptr_t)args[0],
                (char *)(uintptr_t)args[1],
                (size_t)args[2],
                (int)args[3],
                caller);
        }
        case 241: { // SYS_flistxattr
            return (intptr_t)pt_fs_flistxattr_with_caller(
                (int)args[0],
                (char *)(uintptr_t)args[1],
                (size_t)args[2],
                (int)args[3],
                caller);
        }
        case 344: { // SYS_getdirentries64
            return (intptr_t)pt_fs_getdirentries64_syscall_with_caller(
                (int)args[0],
                (void *)(uintptr_t)args[1],
                (size_t)args[2],
                (off_t *)(uintptr_t)args[3],
                caller);
        }
        case 461: { // SYS_getattrlistbulk
            return (intptr_t)pt_fs_getattrlistbulk_with_caller(
                (int)args[0],
                (void *)(uintptr_t)args[1],
                (void *)(uintptr_t)args[2],
                (size_t)args[3],
                (uint64_t)args[4],
                caller);
        }
        case 5: // SYS_open
        case 398: { // SYS_open_nocancel
            const char *path = (const char *)args[0];
            int oflag = (int)args[1];
            mode_t mode = (oflag & O_CREAT) ? (mode_t)args[2] : 0;
            return (intptr_t)pt_fs_open_with_caller(path, oflag, mode, caller);
        }
        case 463: // SYS_openat
        case 464: { // SYS_openat_nocancel
            int fd = (int)args[0];
            const char *path = (const char *)args[1];
            int oflag = (int)args[2];
            mode_t mode = (oflag & O_CREAT) ? (mode_t)args[3] : 0;
            return (intptr_t)pt_fs_openat_with_caller(fd, path, oflag, mode, caller);
        }
        case 188: // SYS_stat
        case 338: { // SYS_stat64
            const char *path = (const char *)args[0];
            struct stat *ub = (struct stat *)args[1];
            return (intptr_t)pt_fs_stat_with_caller(path, ub, YES, caller);
        }
        case 190: // SYS_lstat
        case 340: { // SYS_lstat64
            const char *path = (const char *)args[0];
            struct stat *ub = (struct stat *)args[1];
            return (intptr_t)pt_fs_stat_with_caller(path, ub, NO, caller);
        }
        case 469: // SYS_fstatat
        case 470: { // SYS_fstatat64
            int fd = (int)args[0];
            const char *path = (const char *)args[1];
            struct stat *ub = (struct stat *)args[2];
            int flag = (int)args[3];
            return (intptr_t)pt_fs_fstatat_with_caller(fd, path, ub, flag, caller);
        }
        case 33: { // SYS_access
            const char *path = (const char *)args[0];
            int mode = (int)args[1];
            return (intptr_t)pt_fs_access_with_caller(path, mode, caller);
        }
        case 466: { // SYS_faccessat
            int fd = (int)args[0];
            const char *path = (const char *)args[1];
            int mode = (int)args[2];
            int flag = (int)args[3];
            return (intptr_t)pt_fs_faccessat_with_caller(fd, path, mode, flag, caller);
        }
        case 58: { // SYS_readlink
            const char *path = (const char *)args[0];
            char *buf = (char *)args[1];
            size_t count = (size_t)args[2];
            return (intptr_t)pt_fs_readlink_with_caller(path, buf, count, caller);
        }
        case 473: { // SYS_readlinkat
            int fd = (int)args[0];
            const char *path = (const char *)args[1];
            char *buf = (char *)args[2];
            size_t count = (size_t)args[3];
            return (intptr_t)pt_fs_readlinkat_with_caller(fd, path, buf, count, caller);
        }
        case 92: // SYS_fcntl
        case 406: { // SYS_fcntl_nocancel
            int fd = (int)args[0];
            int cmd = (int)args[1];
            uintptr_t arg = pt_fcntl_cmd_has_no_arg(cmd) ? 0 : args[2];
            return (intptr_t)pt_fs_fcntl_with_caller(fd, cmd, arg, caller);
        }
        case 26: { // SYS_ptrace
            int req = (int)args[0];
            pid_t pid = (pid_t)args[1];
            caddr_t addr = (caddr_t)args[2];
            int data = (int)args[3];
            return (intptr_t)pt_ptrace_with_caller(req, pid, addr, data, caller);
        }
        case 2: // SYS_fork
        case 66: // SYS_vfork
        case 59: // SYS_execve
        case 244: { // SYS_posix_spawn
            if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
                errno = EPERM;
                return -1;
            }
            break;
        }
        case 39: { // SYS_getppid
            if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
                return 1;
            }
            break;
        }
        case 41:   // SYS_dup
        case 90: { // SYS_dup2
            intptr_t r = pt_orig_syscall(number, args[0], args[1], 0, 0, 0, 0, 0, 0);
            if (r >= 0) {
                pt_network_notify_fd_dup((int)args[0], (int)r);
            }
            return r;
        }
        case 43: { // SYS_getegid
            if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
                return (intptr_t)pt_getegid_with_caller(caller);
            }
            break;
        }
        case 47: { // SYS_getgid
            if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
                return (intptr_t)pt_getgid_with_caller(caller);
            }
            break;
        }
        case 79: { // SYS_getgroups
            if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
                return (intptr_t)pt_getgroups_with_caller((int)args[0], (gid_t *)(uintptr_t)args[1], caller);
            }
            break;
        }
        case 220: { // SYS_getattrlist
            return (intptr_t)pt_fs_getattrlist_with_caller(
                (const char *)(uintptr_t)args[0],
                (void *)(uintptr_t)args[1],
                (void *)(uintptr_t)args[2],
                (size_t)args[3],
                (unsigned int)args[4],
                caller);
        }
        case 228: { // SYS_fgetattrlist
            return (intptr_t)pt_fs_fgetattrlist_with_caller(
                (int)args[0],
                (void *)(uintptr_t)args[1],
                (void *)(uintptr_t)args[2],
                (size_t)args[3],
                (unsigned int)args[4],
                caller);
        }
        case 476: { // SYS_getattrlistat
            return (intptr_t)pt_fs_getattrlistat_with_caller(
                (int)args[0],
                (const char *)(uintptr_t)args[1],
                (void *)(uintptr_t)args[2],
                (void *)(uintptr_t)args[3],
                (size_t)args[4],
                (unsigned long)args[5],
                caller);
        }
        case 336: { // SYS_proc_info
            int32_t callnum = (int32_t)args[0];
            int32_t pid = (int32_t)args[1];
            uint32_t flavor = (uint32_t)args[2];
            uint64_t arg = (uint64_t)args[3];
            void *buffer = (void *)args[4];
            int32_t buffersize = (int32_t)args[5];
            if (callnum == 1) { // PROC_INFO_CALL_LISTPIDS
                return (intptr_t)pt_fs_proc_listpids_syscall_with_caller((uint32_t)pid, (uint32_t)flavor, buffer, buffersize, caller);
            } else if (callnum == 2) { // PROC_INFO_CALL_PIDINFO
                return (intptr_t)pt_fs_proc_pidinfo_syscall_with_caller(pid, (int)flavor, arg, buffer, buffersize, caller);
            } else if (callnum == 3) { // PROC_INFO_CALL_PIDFDINFO
                return (intptr_t)pt_fs_proc_pidfdinfo_syscall_with_caller(pid, (int)arg, (int)flavor, buffer, buffersize, caller);
            }
            break;
        }
        case 381: { // SYS___mac_syscall
            return (intptr_t)pt_mac_syscall_with_caller(
                (const char *)(uintptr_t)args[0],
                (int)args[1],
                (void *)(uintptr_t)args[2],
                caller,
                out_handled);
        }
        case 427: { // SYS_fsgetpath
            return (intptr_t)pt_fs_fsgetpath_with_caller(
                (char *)(uintptr_t)args[0],
                (size_t)args[1],
                (fsid_t *)(uintptr_t)args[2],
                (uint64_t)args[3],
                caller);
        }
        default:
            break;
    }

    if (out_handled != NULL) {
        *out_handled = NO;
    }
    return 0;
}

static intptr_t pt_syscall(int number, ...) {
    pthread_t self_thr = pthread_self();
    uintptr_t stack_top = (self_thr != NULL) ? (uintptr_t)pthread_get_stackaddr_np(self_thr) : 0;
    size_t stack_sz = (self_thr != NULL) ? pthread_get_stacksize_np(self_thr) : 0;
    uintptr_t stack_bot = (stack_top >= stack_sz && stack_sz > 0) ? (stack_top - stack_sz) : 0;

    va_list ap;
    va_start(ap, number);

    uintptr_t args[PT_XNU_SYSCALL_MAX_ARGS] = {0};
    for (int i = 0; i < PT_XNU_SYSCALL_MAX_ARGS; i++) {
        if (!pt_va_can_pop_uintptr(ap, stack_bot, stack_top)) {
            break;
        }
        args[i] = va_arg(ap, uintptr_t);
    }
    va_end(ap);

    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return pt_orig_syscall(number, args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7]);
    }

    const void *caller = __builtin_return_address(0);
    if (number == 0 || number == 198) {
        if (args[0] == 0 && stack_top > 0 && stack_bot == stack_top) {
            errno = EFAULT;
            return -1;
        }
    }

    BOOL handled = NO;
    intptr_t res = pt_syscall_dispatch_with_caller(number, args, caller, &handled);
    if (handled) {
        return res;
    }
    return pt_orig_syscall(number, args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7]);
}

#pragma mark - MIG Reply Sanitization

#ifndef PT_MIG_REQ_RING_SIZE
#define PT_MIG_REQ_RING_SIZE 16U
#endif

typedef kern_return_t (*PTMachMsg2InternalFn)(void *data,
                                              uint64_t option64,
                                              uint64_t msgh_bits_and_send_size,
                                              uint64_t msgh_remote_and_local_port,
                                              uint64_t msgh_voucher_and_id,
                                              uint64_t desc_count_and_rcv_name,
                                              uint64_t rcv_size,
                                              uint64_t priority_and_timeout);

typedef struct {
    mach_port_t reply_port;
    int req_id;
    int32_t req_flavor;
    bool target_is_self;
    bool valid;
} PTMIGPendingRequest;

static os_unfair_lock s_mig_req_ring_lock = OS_UNFAIR_LOCK_INIT;
static PTMIGPendingRequest s_mig_req_ring[PT_MIG_REQ_RING_SIZE];
static uint32_t s_mig_req_ring_next = 0;

static BOOL pt_is_tracked_mig_req_id(int req_id) {
    return (req_id == 200 ||
            req_id == 202 ||
            req_id == 219 ||
            req_id == 3402 ||
            req_id == 3405 ||
            req_id == 3414 ||
            req_id == 3415);
}

static void pt_mig_ring_push(mach_port_t reply_port, int req_id, int32_t req_flavor, bool target_is_self) {
    if (reply_port == MACH_PORT_NULL || !target_is_self) {
        return;
    }
    if (!pt_is_tracked_mig_req_id(req_id)) {
        return;
    }
    os_unfair_lock_lock(&s_mig_req_ring_lock);
    for (uint32_t i = 0; i < PT_MIG_REQ_RING_SIZE; i++) {
        if (s_mig_req_ring[i].valid && s_mig_req_ring[i].reply_port == reply_port) {
            s_mig_req_ring[i].req_id = req_id;
            s_mig_req_ring[i].req_flavor = req_flavor;
            s_mig_req_ring[i].target_is_self = target_is_self;
            os_unfair_lock_unlock(&s_mig_req_ring_lock);
            return;
        }
    }
    uint32_t slot = s_mig_req_ring_next % PT_MIG_REQ_RING_SIZE;
    s_mig_req_ring_next = (s_mig_req_ring_next + 1U) % PT_MIG_REQ_RING_SIZE;
    s_mig_req_ring[slot].reply_port = reply_port;
    s_mig_req_ring[slot].req_id = req_id;
    s_mig_req_ring[slot].req_flavor = req_flavor;
    s_mig_req_ring[slot].target_is_self = target_is_self;
    s_mig_req_ring[slot].valid = true;
    os_unfair_lock_unlock(&s_mig_req_ring_lock);
}

static bool pt_mig_ring_pop(mach_port_t reply_port, int *out_req_id, int32_t *out_req_flavor, bool *out_target_is_self) {
    if (reply_port == MACH_PORT_NULL) {
        return false;
    }
    os_unfair_lock_lock(&s_mig_req_ring_lock);
    for (uint32_t i = 0; i < PT_MIG_REQ_RING_SIZE; i++) {
        if (s_mig_req_ring[i].valid && s_mig_req_ring[i].reply_port == reply_port) {
            if (out_req_id != NULL) {
                *out_req_id = s_mig_req_ring[i].req_id;
            }
            if (out_req_flavor != NULL) {
                *out_req_flavor = s_mig_req_ring[i].req_flavor;
            }
            if (out_target_is_self != NULL) {
                *out_target_is_self = s_mig_req_ring[i].target_is_self;
            }
            s_mig_req_ring[i].valid = false;
            os_unfair_lock_unlock(&s_mig_req_ring_lock);
            return true;
        }
    }
    os_unfair_lock_unlock(&s_mig_req_ring_lock);
    return false;
}

static void pt_mig_ring_erase(mach_port_t reply_port, int req_id, int32_t req_flavor) {
    if (reply_port == MACH_PORT_NULL) {
        return;
    }
    os_unfair_lock_lock(&s_mig_req_ring_lock);
    for (uint32_t i = 0; i < PT_MIG_REQ_RING_SIZE; i++) {
        if (s_mig_req_ring[i].valid &&
            s_mig_req_ring[i].reply_port == reply_port &&
            s_mig_req_ring[i].req_id == req_id &&
            s_mig_req_ring[i].req_flavor == req_flavor) {
            s_mig_req_ring[i].valid = false;
            break;
        }
    }
    os_unfair_lock_unlock(&s_mig_req_ring_lock);
}

static bool pt_extract_mig_request_meta(const void *req_buf,
                                        mach_msg_bits_t bits,
                                        mach_msg_size_t send_size,
                                        mach_port_t remote_port,
                                        int req_id,
                                        int32_t *out_flavor,
                                        bool *out_target_is_self) {
    if (req_buf == NULL || !pt_is_tracked_mig_req_id(req_id)) {
        return false;
    }
    bool is_complex = ((bits & MACH_MSGH_BITS_COMPLEX) != 0);
    if (req_id == 3415) {
        // task_swap_exception_ports request carries new_port descriptor (complex).
        if (send_size < sizeof(mach_msg_header_t)) {
            return false;
        }
        if (out_flavor != NULL) {
            *out_flavor = 0;
        }
        if (out_target_is_self != NULL) {
            *out_target_is_self = (remote_port == mach_task_self());
        }
        return true;
    }
    if (is_complex) {
        return false;
    }
    if (req_id == 3402) {
        if (send_size < sizeof(mach_msg_header_t)) {
            return false;
        }
        if (out_flavor != NULL) {
            *out_flavor = 0;
        }
        if (out_target_is_self != NULL) {
            *out_target_is_self = (remote_port == mach_task_self());
        }
        return true;
    }
    const size_t min_req_size = sizeof(mach_msg_header_t) + sizeof(NDR_record_t) + sizeof(int32_t);
    if (send_size < min_req_size) {
        return false;
    }
    int32_t flavor = 0;
    memcpy(&flavor, (const uint8_t *)req_buf + sizeof(mach_msg_header_t) + sizeof(NDR_record_t), sizeof(flavor));
    if (out_flavor != NULL) {
        *out_flavor = flavor;
    }
    if (out_target_is_self != NULL) {
        *out_target_is_self = (req_id == 200 || req_id == 202 || req_id == 219)
            ? true
            : (remote_port == mach_task_self());
    }
    return true;
}

static void pt_sanitize_mig_task_threads_reply(void *rcv_buf, size_t usable_bytes) {
    const size_t body_off = sizeof(mach_msg_header_t);
    const size_t desc_off = body_off + sizeof(mach_msg_body_t);
    const size_t ndr_off = desc_off + sizeof(mach_msg_ool_ports_descriptor_t);
    const size_t cnt_off = ndr_off + sizeof(NDR_record_t);
    const size_t min_sz = cnt_off + sizeof(mach_msg_type_number_t);
    if (usable_bytes < min_sz) {
        return;
    }
    uint8_t *bytes = (uint8_t *)rcv_buf;
    mach_msg_body_t body;
    memcpy(&body, bytes + body_off, sizeof(body));
    if (body.msgh_descriptor_count != 1U) {
        return;
    }
    mach_msg_ool_ports_descriptor_t desc;
    memcpy(&desc, bytes + desc_off, sizeof(desc));
    if (desc.type != MACH_MSG_OOL_PORTS_DESCRIPTOR || desc.address == NULL || desc.count == 0U || desc.count > 16384U) {
        return;
    }
    mach_msg_type_number_t act_cnt = 0;
    memcpy(&act_cnt, bytes + cnt_off, sizeof(act_cnt));
    if (act_cnt != desc.count) {
        return;
    }
    thread_act_t *orig_list = (thread_act_t *)desc.address;
    mach_msg_type_number_t orig_cnt = desc.count;
    thread_act_t stack_kept[256];
    thread_act_t *kept_buf = stack_kept;
    if (orig_cnt > (mach_msg_type_number_t)(sizeof(stack_kept) / sizeof(stack_kept[0]))) {
        kept_buf = (thread_act_t *)malloc((size_t)orig_cnt * sizeof(thread_act_t));
        if (kept_buf == NULL) {
            return;
        }
    }
    mach_msg_type_number_t kept = 0;
    for (mach_msg_type_number_t i = 0; i < orig_cnt; i++) {
        thread_act_t thr = orig_list[i];
        if (pt_is_hidden_mach_thread(thr)) {
            mach_port_deallocate(mach_task_self(), thr);
        } else {
            kept_buf[kept++] = thr;
        }
    }
    if (kept < orig_cnt) {
        if (kept == 0U) {
            vm_deallocate(mach_task_self(), (vm_address_t)orig_list, (vm_size_t)(orig_cnt * sizeof(thread_act_t)));
            desc.address = NULL;
            desc.count = 0U;
            act_cnt = 0U;
        } else {
            vm_address_t new_addr = 0;
            if (vm_allocate(mach_task_self(), &new_addr, (vm_size_t)(kept * sizeof(thread_act_t)), VM_FLAGS_ANYWHERE) == KERN_SUCCESS) {
                memcpy((void *)new_addr, kept_buf, (size_t)kept * sizeof(thread_act_t));
                vm_deallocate(mach_task_self(), (vm_address_t)orig_list, (vm_size_t)(orig_cnt * sizeof(thread_act_t)));
                desc.address = (void *)new_addr;
            } else {
                memcpy(orig_list, kept_buf, (size_t)kept * sizeof(thread_act_t));
                memset(orig_list + kept, 0, (size_t)(orig_cnt - kept) * sizeof(thread_act_t));
            }
            desc.count = kept;
            act_cnt = kept;
        }
        memcpy(bytes + desc_off, &desc, sizeof(desc));
        memcpy(bytes + cnt_off, &act_cnt, sizeof(act_cnt));
    }
    if (kept_buf != stack_kept) {
        free(kept_buf);
    }
}

static void pt_sanitize_mig_exception_ports_reply(void *rcv_buf, size_t usable_bytes) {
    mach_port_t svc_port = MACH_PORT_NULL;
    mach_port_t saved_port = MACH_PORT_NULL;
    exception_mask_t saved_mask = 0;
    exception_behavior_t saved_beh = 0;
    thread_state_flavor_t saved_flavor = 0;
    if (!pt_svc_get_redaction_info(&svc_port, &saved_port, &saved_mask, &saved_beh, &saved_flavor)) {
        return;
    }
    BOOL consumed_saved_port = NO;
    const size_t body_off = sizeof(mach_msg_header_t);
    const size_t descs_off = body_off + sizeof(mach_msg_body_t);
    if (usable_bytes < descs_off) {
        if (MACH_PORT_VALID(saved_port)) {
            mach_port_deallocate(mach_task_self(), saved_port);
        }
        return;
    }
    uint8_t *bytes = (uint8_t *)rcv_buf;
    mach_msg_body_t body;
    memcpy(&body, bytes + body_off, sizeof(body));
    uint32_t desc_cnt = body.msgh_descriptor_count;
    if (desc_cnt == 0U || desc_cnt > 32U) {
        if (MACH_PORT_VALID(saved_port)) {
            mach_port_deallocate(mach_task_self(), saved_port);
        }
        return;
    }

    // Detect OOL ports descriptor vs inline port descriptors.
    if (desc_cnt == 1U && usable_bytes >= descs_off + sizeof(mach_msg_ool_ports_descriptor_t)) {
        mach_msg_ool_ports_descriptor_t ool;
        memcpy(&ool, bytes + descs_off, sizeof(ool));
        if (ool.type == MACH_MSG_OOL_PORTS_DESCRIPTOR) {
            if (ool.address != NULL && ool.count > 0U && ool.count <= 32U) {
                mach_port_t *ports = (mach_port_t *)ool.address;
                for (mach_msg_size_t i = 0; i < ool.count; i++) {
                    if (ports[i] == svc_port) {
                        mach_port_deallocate(mach_task_self(), svc_port);
                        if (!consumed_saved_port && MACH_PORT_VALID(saved_port)) {
                            ports[i] = saved_port;
                            consumed_saved_port = YES;
                        } else {
                            ports[i] = MACH_PORT_NULL;
                        }
                    }
                }
            }
            if (!consumed_saved_port && MACH_PORT_VALID(saved_port)) {
                mach_port_deallocate(mach_task_self(), saved_port);
            }
            return;
        }
    }

    size_t descs_bytes = (size_t)desc_cnt * sizeof(mach_msg_port_descriptor_t);
    size_t ndr_off = descs_off + descs_bytes;
    size_t cnt_off = ndr_off + sizeof(NDR_record_t);
    size_t arrays_off = cnt_off + sizeof(mach_msg_type_number_t);
    if (usable_bytes < arrays_off) {
        if (MACH_PORT_VALID(saved_port)) {
            mach_port_deallocate(mach_task_self(), saved_port);
        }
        return;
    }
    mach_msg_type_number_t masks_cnt = 0;
    memcpy(&masks_cnt, bytes + cnt_off, sizeof(masks_cnt));
    if (masks_cnt != desc_cnt || masks_cnt > 32U) {
        if (MACH_PORT_VALID(saved_port)) {
            mach_port_deallocate(mach_task_self(), saved_port);
        }
        return;
    }
    size_t arr_bytes = (size_t)masks_cnt * sizeof(uint32_t);
    size_t needed_end = arrays_off + 3U * arr_bytes;
    if (usable_bytes < needed_end) {
        if (MACH_PORT_VALID(saved_port)) {
            mach_port_deallocate(mach_task_self(), saved_port);
        }
        return;
    }

    mach_msg_port_descriptor_t descs[32];
    exception_mask_t masks[32];
    exception_behavior_t behaviors[32];
    thread_state_flavor_t flavors[32];
    NDR_record_t ndr;
    memcpy(descs, bytes + descs_off, descs_bytes);
    memcpy(&ndr, bytes + ndr_off, sizeof(ndr));
    memcpy(masks, bytes + arrays_off, arr_bytes);
    memcpy(behaviors, bytes + arrays_off + arr_bytes, arr_bytes);
    memcpy(flavors, bytes + arrays_off + 2U * arr_bytes, arr_bytes);

    for (uint32_t i = 0; i < desc_cnt; i++) {
        if (descs[i].type != MACH_MSG_PORT_DESCRIPTOR) {
            if (MACH_PORT_VALID(saved_port)) {
                mach_port_deallocate(mach_task_self(), saved_port);
            }
            return;
        }
    }

    BOOL modified = NO;
    uint32_t out_cnt = 0;
    for (uint32_t i = 0; i < desc_cnt; i++) {
        if (descs[i].name == svc_port) {
            modified = YES;
            mach_port_deallocate(mach_task_self(), svc_port);
            if (!consumed_saved_port && MACH_PORT_VALID(saved_port)) {
                descs[out_cnt] = descs[i];
                descs[out_cnt].name = saved_port;
                masks[out_cnt] = (saved_mask != 0) ? saved_mask : masks[i];
                behaviors[out_cnt] = saved_beh;
                flavors[out_cnt] = saved_flavor;
                consumed_saved_port = YES;
                out_cnt++;
            } else {
                exception_mask_t rem_mask = masks[i] & ~((exception_mask_t)EXC_MASK_BREAKPOINT);
                if (rem_mask != 0) {
                    descs[out_cnt] = descs[i];
                    descs[out_cnt].name = MACH_PORT_NULL;
                    masks[out_cnt] = rem_mask;
                    behaviors[out_cnt] = behaviors[i];
                    flavors[out_cnt] = flavors[i];
                    out_cnt++;
                }
            }
            continue;
        }
        if (out_cnt != i) {
            descs[out_cnt] = descs[i];
            masks[out_cnt] = masks[i];
            behaviors[out_cnt] = behaviors[i];
            flavors[out_cnt] = flavors[i];
        }
        out_cnt++;
    }
    if (!consumed_saved_port && MACH_PORT_VALID(saved_port)) {
        mach_port_deallocate(mach_task_self(), saved_port);
    }
    if (!modified) {
        return;
    }

    body.msgh_descriptor_count = out_cnt;
    memcpy(bytes + body_off, &body, sizeof(body));
    size_t new_descs_bytes = (size_t)out_cnt * sizeof(mach_msg_port_descriptor_t);
    if (out_cnt > 0U) {
        memcpy(bytes + descs_off, descs, new_descs_bytes);
    }
    size_t new_ndr_off = descs_off + new_descs_bytes;
    size_t new_cnt_off = new_ndr_off + sizeof(NDR_record_t);
    size_t new_arr_off = new_cnt_off + sizeof(mach_msg_type_number_t);
    size_t new_arr_bytes = (size_t)out_cnt * sizeof(uint32_t);
    memcpy(bytes + new_ndr_off, &ndr, sizeof(ndr));
    mach_msg_type_number_t new_masks_cnt = out_cnt;
    memcpy(bytes + new_cnt_off, &new_masks_cnt, sizeof(new_masks_cnt));
    if (out_cnt > 0U) {
        memcpy(bytes + new_arr_off, masks, new_arr_bytes);
        memcpy(bytes + new_arr_off + new_arr_bytes, behaviors, new_arr_bytes);
        memcpy(bytes + new_arr_off + 2U * new_arr_bytes, flavors, new_arr_bytes);
    }
    size_t new_total = new_arr_off + 3U * new_arr_bytes;
    if (new_total < needed_end) {
        memset(bytes + new_total, 0, needed_end - new_total);
    }
    mach_msg_header_t *hdr_mut = (mach_msg_header_t *)rcv_buf;
    hdr_mut->msgh_size = (mach_msg_size_t)new_total;
}

static void pt_sanitize_mig_reply_if_needed(void *rcv_buf,
                                            size_t rcv_cap,
                                            mach_port_t rcv_name,
                                            bool had_inline_req,
                                            int inline_req_id,
                                            int32_t inline_req_flavor,
                                            bool inline_target_is_self) {
    if (rcv_buf == NULL || rcv_cap < sizeof(mach_msg_header_t)) {
        return;
    }
    const mach_msg_header_t *hdr = (const mach_msg_header_t *)rcv_buf;
    int reply_id = hdr->msgh_id;
    bool is_simple_reply = (reply_id == 300 || reply_id == 302 || reply_id == 319 || reply_id == 3505);
    bool is_complex_reply = (reply_id == 3502 || reply_id == 3514 || reply_id == 3515);
    if (!is_simple_reply && !is_complex_reply) {
        return;
    }
    size_t usable_bytes = (hdr->msgh_size > 0 && hdr->msgh_size < rcv_cap) ? (size_t)hdr->msgh_size : rcv_cap;

    int req_id = inline_req_id;
    int32_t req_flavor = inline_req_flavor;
    bool target_is_self = inline_target_is_self;
    if (!had_inline_req) {
        bool matched = false;
        if (hdr->msgh_local_port != MACH_PORT_NULL) {
            matched = pt_mig_ring_pop(hdr->msgh_local_port, &req_id, &req_flavor, &target_is_self);
        }
        if (!matched && rcv_name != MACH_PORT_NULL && rcv_name != hdr->msgh_local_port) {
            matched = pt_mig_ring_pop(rcv_name, &req_id, &req_flavor, &target_is_self);
        }
        if (!matched) {
            return;
        }
    }

    if (is_complex_reply) {
        if ((hdr->msgh_bits & MACH_MSGH_BITS_COMPLEX) == 0 || !target_is_self) {
            return;
        }
        if (reply_id == 3502 && req_id == 3402) {
            pt_sanitize_mig_task_threads_reply(rcv_buf, usable_bytes);
        } else if ((reply_id == 3514 && req_id == 3414) ||
                   (reply_id == 3515 && req_id == 3415)) {
            pt_sanitize_mig_exception_ports_reply(rcv_buf, usable_bytes);
        }
        return;
    }

    if ((hdr->msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0) {
        return;
    }
    const size_t prefix = sizeof(mach_msg_header_t) + sizeof(NDR_record_t);
    if (usable_bytes < prefix + sizeof(kern_return_t) + sizeof(natural_t)) {
        return;
    }

    const uint8_t *bytes = (const uint8_t *)rcv_buf;
    kern_return_t reply_rc = KERN_FAILURE;
    memcpy(&reply_rc, bytes + prefix, sizeof(reply_rc));
    if (reply_rc != KERN_SUCCESS) {
        return;
    }
    natural_t payload_count = 0;
    memcpy(&payload_count, bytes + prefix + sizeof(kern_return_t), sizeof(payload_count));
    size_t payload_offset = prefix + sizeof(kern_return_t) + sizeof(natural_t);
    if (payload_count == 0 || (size_t)payload_count > (SIZE_MAX - payload_offset) / sizeof(natural_t)) {
        return;
    }
    size_t payload_bytes = (size_t)payload_count * sizeof(natural_t);
    if (payload_offset + payload_bytes > usable_bytes) {
        return;
    }
    uint8_t *payload = (uint8_t *)rcv_buf + payload_offset;

    if (reply_id == 300 && req_id == 200 && req_flavor == HOST_BASIC_INFO) {
        host_basic_info_data_t info_local;
        memset(&info_local, 0, sizeof(info_local));
        size_t copy_bytes = (payload_bytes < sizeof(info_local)) ? payload_bytes : sizeof(info_local);
        memcpy(&info_local, payload, copy_bytes);
        pt_sanitize_host_basic_info_buf(&info_local, copy_bytes);
        memcpy(payload, &info_local, copy_bytes);
    } else if (reply_id == 302 && req_id == 202 && req_flavor == HOST_VM_INFO) {
        vm_statistics_data_t vm_local;
        memset(&vm_local, 0, sizeof(vm_local));
        size_t copy_bytes = (payload_bytes < sizeof(vm_local)) ? payload_bytes : sizeof(vm_local);
        memcpy(&vm_local, payload, copy_bytes);
        pt_sanitize_host_vm_info_buf(&vm_local, copy_bytes);
        memcpy(payload, &vm_local, copy_bytes);
    } else if (reply_id == 319 && req_id == 219 &&
               (req_flavor == HOST_VM_INFO64 || req_flavor == HOST_VM_INFO)) {
        vm_statistics64_data_t vm64_local;
        memset(&vm64_local, 0, sizeof(vm64_local));
        size_t copy_bytes = (payload_bytes < sizeof(vm64_local)) ? payload_bytes : sizeof(vm64_local);
        memcpy(&vm64_local, payload, copy_bytes);
        pt_sanitize_host_vm_info64_buf(&vm64_local, copy_bytes, req_flavor == HOST_VM_INFO64);
        memcpy(payload, &vm64_local, copy_bytes);
    } else if (reply_id == 3505 && target_is_self && req_id == 3405) {
        if (req_flavor == TASK_VM_INFO || req_flavor == TASK_VM_INFO_PURGEABLE) {
            task_vm_info_data_t vm_local;
            memset(&vm_local, 0, sizeof(vm_local));
            size_t copy_bytes = (payload_bytes < sizeof(vm_local)) ? payload_bytes : sizeof(vm_local);
            memcpy(&vm_local, payload, copy_bytes);
            pt_sanitize_task_vm_info_buf(&vm_local, copy_bytes);
            memcpy(payload, &vm_local, copy_bytes);
        } else if (req_flavor == TASK_AUDIT_TOKEN) {
            audit_token_t tok_local;
            memset(&tok_local, 0, sizeof(tok_local));
            size_t copy_bytes = (payload_bytes < sizeof(tok_local)) ? payload_bytes : sizeof(tok_local);
            memcpy(&tok_local, payload, copy_bytes);
            pt_sanitize_task_audit_token_buf(&tok_local, copy_bytes);
            memcpy(payload, &tok_local, copy_bytes);
        } else if (req_flavor == TASK_SECURITY_TOKEN) {
            security_token_t sec_local;
            memset(&sec_local, 0, sizeof(sec_local));
            size_t copy_bytes = (payload_bytes < sizeof(sec_local)) ? payload_bytes : sizeof(sec_local);
            memcpy(&sec_local, payload, copy_bytes);
            pt_sanitize_task_security_token_buf(&sec_local, copy_bytes);
            memcpy(payload, &sec_local, copy_bytes);
        } else if (req_flavor == TASK_DYLD_INFO && payload_bytes >= sizeof(task_dyld_info_data_t)) {
            task_dyld_info_data_t dyld_local;
            memcpy(&dyld_local, payload, sizeof(dyld_local));
            pt_sanitize_task_dyld_info_buf(&dyld_local, sizeof(dyld_local));
            memcpy(payload, &dyld_local, sizeof(dyld_local));
        }
    }
}

__attribute__((visibility("hidden")))
bool pt_mig_prepare_trap_request(const void *req_buf,
                                 mach_msg_bits_t bits,
                                 mach_msg_size_t send_size,
                                 mach_port_t remote_port,
                                 mach_port_t local_port,
                                 int req_id,
                                 bool receiving,
                                 int32_t *out_flavor,
                                 bool *out_target_is_self) {
    int32_t flavor = 0;
    bool target_is_self = false;
    bool had_req = pt_extract_mig_request_meta(req_buf,
                                               bits,
                                               send_size,
                                               remote_port,
                                               req_id,
                                               &flavor,
                                               &target_is_self);
    if (out_flavor != NULL) {
        *out_flavor = flavor;
    }
    if (out_target_is_self != NULL) {
        *out_target_is_self = target_is_self;
    }
    if (had_req && !receiving) {
        pt_mig_ring_push(local_port, req_id, flavor, target_is_self);
    }
    return had_req;
}

__attribute__((visibility("hidden")))
void pt_mig_finish_trap_reply(void *rcv_buf,
                              size_t rcv_cap,
                              mach_port_t rcv_name,
                              bool sending,
                              bool receiving,
                              bool had_req,
                              int req_id,
                              int32_t req_flavor,
                              bool target_is_self,
                              mach_port_t reply_port,
                              kern_return_t kr) {
    if (sending && !receiving && had_req && kr != KERN_SUCCESS) {
        pt_mig_ring_erase(reply_port, req_id, req_flavor);
    }
    if (kr == KERN_SUCCESS && receiving && rcv_buf != NULL && rcv_cap >= sizeof(mach_msg_header_t)) {
        pt_sanitize_mig_reply_if_needed(rcv_buf, rcv_cap, rcv_name, had_req, req_id, req_flavor, target_is_self);
    }
}

static PTMachMsg2InternalFn pt_get_real_mach_msg2_internal(void) {
    static PTMachMsg2InternalFn s_real_mach_msg2_internal = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_real_mach_msg2_internal = (PTMachMsg2InternalFn)dlsym(RTLD_DEFAULT, "mach_msg2_internal");
    });
    return s_real_mach_msg2_internal;
}

static mach_msg_return_t pt_mach_msg_overwrite(mach_msg_header_t *msg,
                                               mach_msg_option_t option,
                                               mach_msg_size_t send_size,
                                               mach_msg_size_t rcv_size,
                                               mach_port_name_t rcv_name,
                                               mach_msg_timeout_t timeout,
                                               mach_port_name_t notify,
                                               mach_msg_header_t *rcv_msg,
                                               mach_msg_size_t rcv_limit) {
    if (!pt_is_bypass_enabled() || pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return mach_msg_overwrite(msg, option, send_size, rcv_size, rcv_name, timeout, notify, rcv_msg, rcv_limit);
    }
    bool sending = (option & MACH_SEND_MSG) != 0 && msg != NULL;
    bool receiving = (option & MACH_RCV_MSG) != 0;
    mach_msg_header_t *actual_rcv = (rcv_msg != NULL) ? rcv_msg : msg;
    mach_msg_size_t actual_rcv_cap = (rcv_msg != NULL) ? rcv_limit : rcv_size;
    if (actual_rcv == NULL) {
        receiving = false;
    }
    if (!sending && !receiving) {
        return mach_msg_overwrite(msg, option, send_size, rcv_size, rcv_name, timeout, notify, rcv_msg, rcv_limit);
    }

    bool had_req = false;
    int req_id = 0;
    int32_t req_flavor = 0;
    bool target_is_self = false;
    mach_port_t reply_port = MACH_PORT_NULL;
    if (sending) {
        mach_msg_size_t effective_send_size = (send_size > 0) ? send_size : msg->msgh_size;
        had_req = pt_extract_mig_request_meta(msg,
                                              msg->msgh_bits,
                                              effective_send_size,
                                              msg->msgh_remote_port,
                                              msg->msgh_id,
                                              &req_flavor,
                                              &target_is_self);
        if (had_req) {
            req_id = msg->msgh_id;
            reply_port = msg->msgh_local_port;
            if (!receiving) {
                pt_mig_ring_push(reply_port, req_id, req_flavor, target_is_self);
            }
        }
    }

    mach_msg_return_t kr = mach_msg_overwrite(msg, option, send_size, rcv_size, rcv_name, timeout, notify, rcv_msg, rcv_limit);
    if (sending && !receiving && had_req && kr != MACH_MSG_SUCCESS) {
        pt_mig_ring_erase(reply_port, req_id, req_flavor);
    }
    if (kr == MACH_MSG_SUCCESS && receiving) {
        pt_sanitize_mig_reply_if_needed(actual_rcv,
                                        (size_t)actual_rcv_cap,
                                        rcv_name,
                                        had_req,
                                        req_id,
                                        req_flavor,
                                        target_is_self);
    }
    return kr;
}

static mach_msg_return_t pt_mach_msg(mach_msg_header_t *msg,
                                     mach_msg_option_t option,
                                     mach_msg_size_t send_size,
                                     mach_msg_size_t rcv_size,
                                     mach_port_name_t rcv_name,
                                     mach_msg_timeout_t timeout,
                                     mach_port_name_t notify) {
    if (!pt_is_bypass_enabled() || pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return mach_msg(msg, option, send_size, rcv_size, rcv_name, timeout, notify);
    }
    bool sending = (option & MACH_SEND_MSG) != 0 && msg != NULL;
    bool receiving = (option & MACH_RCV_MSG) != 0 && msg != NULL;
    if (!sending && !receiving) {
        return mach_msg(msg, option, send_size, rcv_size, rcv_name, timeout, notify);
    }

    bool had_req = false;
    int req_id = 0;
    int32_t req_flavor = 0;
    bool target_is_self = false;
    mach_port_t reply_port = MACH_PORT_NULL;
    if (sending) {
        mach_msg_size_t effective_send_size = (send_size > 0) ? send_size : msg->msgh_size;
        had_req = pt_extract_mig_request_meta(msg,
                                              msg->msgh_bits,
                                              effective_send_size,
                                              msg->msgh_remote_port,
                                              msg->msgh_id,
                                              &req_flavor,
                                              &target_is_self);
        if (had_req) {
            req_id = msg->msgh_id;
            reply_port = msg->msgh_local_port;
            if (!receiving) {
                pt_mig_ring_push(reply_port, req_id, req_flavor, target_is_self);
            }
        }
    }

    mach_msg_return_t kr = mach_msg(msg, option, send_size, rcv_size, rcv_name, timeout, notify);
    if (sending && !receiving && had_req && kr != MACH_MSG_SUCCESS) {
        pt_mig_ring_erase(reply_port, req_id, req_flavor);
    }
    if (kr == MACH_MSG_SUCCESS && receiving) {
        pt_sanitize_mig_reply_if_needed(msg,
                                        (size_t)rcv_size,
                                        rcv_name,
                                        had_req,
                                        req_id,
                                        req_flavor,
                                        target_is_self);
    }
    return kr;
}

static kern_return_t pt_mach_msg2_internal(void *data,
                                           uint64_t option64,
                                           uint64_t msgh_bits_and_send_size,
                                           uint64_t msgh_remote_and_local_port,
                                           uint64_t msgh_voucher_and_id,
                                           uint64_t desc_count_and_rcv_name,
                                           uint64_t rcv_size,
                                           uint64_t priority_and_timeout) {
    PTMachMsg2InternalFn real_fn = pt_get_real_mach_msg2_internal();
    if (real_fn == NULL) {
        return KERN_NOT_SUPPORTED;
    }
    if (!pt_is_bypass_enabled() || pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return real_fn(data, option64, msgh_bits_and_send_size, msgh_remote_and_local_port,
                       msgh_voucher_and_id, desc_count_and_rcv_name, rcv_size, priority_and_timeout);
    }

    bool is_vector = (option64 & 0x0000000100000000ULL) != 0;
    bool sending = !is_vector && (option64 & MACH_SEND_MSG) != 0 && data != NULL;
    bool receiving = !is_vector && (option64 & MACH_RCV_MSG) != 0 && data != NULL;
    if (!sending && !receiving) {
        return real_fn(data, option64, msgh_bits_and_send_size, msgh_remote_and_local_port,
                       msgh_voucher_and_id, desc_count_and_rcv_name, rcv_size, priority_and_timeout);
    }

    bool had_req = false;
    int req_id = 0;
    int32_t req_flavor = 0;
    bool target_is_self = false;
    mach_port_t reply_port = MACH_PORT_NULL;
    if (sending) {
        const mach_msg_header_t *hdr = (const mach_msg_header_t *)data;
        mach_msg_bits_t bits = (mach_msg_bits_t)(msgh_bits_and_send_size & 0xFFFFFFFFU);
        mach_msg_size_t send_size = (mach_msg_size_t)(msgh_bits_and_send_size >> 32);
        if (send_size == 0) {
            send_size = hdr->msgh_size;
        }
        mach_port_t remote_port = (mach_port_t)(msgh_remote_and_local_port & 0xFFFFFFFFU);
        mach_port_t local_port = (mach_port_t)(msgh_remote_and_local_port >> 32);
        int parsed_id = (int)(msgh_voucher_and_id >> 32);
        if (parsed_id == 0) {
            parsed_id = hdr->msgh_id;
        }
        if (local_port == MACH_PORT_NULL) {
            local_port = hdr->msgh_local_port;
        }
        had_req = pt_extract_mig_request_meta(data, bits, send_size, remote_port, parsed_id, &req_flavor, &target_is_self);
        if (had_req) {
            req_id = parsed_id;
            reply_port = local_port;
            if (!receiving) {
                pt_mig_ring_push(reply_port, req_id, req_flavor, target_is_self);
            }
        }
    }

    kern_return_t kr = real_fn(data, option64, msgh_bits_and_send_size, msgh_remote_and_local_port,
                               msgh_voucher_and_id, desc_count_and_rcv_name, rcv_size, priority_and_timeout);
    if (sending && !receiving && had_req && kr != KERN_SUCCESS) {
        pt_mig_ring_erase(reply_port, req_id, req_flavor);
    }
    if (kr == KERN_SUCCESS && receiving) {
        mach_port_t rcv_name = (mach_port_t)(desc_count_and_rcv_name >> 32);
        size_t rcv_cap = (size_t)(uint32_t)(rcv_size & 0xFFFFFFFFULL);
        pt_sanitize_mig_reply_if_needed(data, rcv_cap, rcv_name, had_req, req_id, req_flavor, target_is_self);
    }
    return kr;
}

#ifndef PT_BOOTSTRAP_UNKNOWN_SERVICE
#define PT_BOOTSTRAP_UNKNOWN_SERVICE 1102
#endif

extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *service_name, mach_port_t *sp);

static kern_return_t pt_bootstrap_look_up(mach_port_t bp, const char *service_name, mach_port_t *sp) {
    if (service_name != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_hidden_macos_mach_service(service_name)) {
        if (sp != NULL) {
            *sp = MACH_PORT_NULL;
        }
        return PT_BOOTSTRAP_UNKNOWN_SERVICE;
    }
    return bootstrap_look_up(bp, service_name, sp);
}

static kern_return_t pt_bootstrap_look_up2(mach_port_t bp,
                                           const char *service_name,
                                           mach_port_t *sp,
                                           pid_t target_pid,
                                           uint64_t flags) {
    if (service_name != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_hidden_macos_mach_service(service_name)) {
        if (sp != NULL) {
            *sp = MACH_PORT_NULL;
        }
        return PT_BOOTSTRAP_UNKNOWN_SERVICE;
    }
    typedef kern_return_t (*BootstrapLookUp2Fn)(mach_port_t, const char *, mach_port_t *, pid_t, uint64_t);
    static BootstrapLookUp2Fn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (BootstrapLookUp2Fn)dlsym(RTLD_NEXT, "bootstrap_look_up2");
    });
    if (s_orig != NULL) {
        return s_orig(bp, service_name, sp, target_pid, flags);
    }
    if (sp != NULL) {
        *sp = MACH_PORT_NULL;
    }
    return PT_BOOTSTRAP_UNKNOWN_SERVICE;
}

static kern_return_t pt_bootstrap_look_up3(mach_port_t bp,
                                           const char *service_name,
                                           mach_port_t *sp,
                                           pid_t target_pid,
                                           const uuid_t instance_id,
                                           uint64_t flags) {
    if (service_name != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_hidden_macos_mach_service(service_name)) {
        if (sp != NULL) {
            *sp = MACH_PORT_NULL;
        }
        return PT_BOOTSTRAP_UNKNOWN_SERVICE;
    }
    typedef kern_return_t (*BootstrapLookUp3Fn)(mach_port_t, const char *, mach_port_t *, pid_t, const uuid_t, uint64_t);
    static BootstrapLookUp3Fn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (BootstrapLookUp3Fn)dlsym(RTLD_NEXT, "bootstrap_look_up3");
    });
    if (s_orig != NULL) {
        return s_orig(bp, service_name, sp, target_pid, instance_id, flags);
    }
    if (sp != NULL) {
        *sp = MACH_PORT_NULL;
    }
    return PT_BOOTSTRAP_UNKNOWN_SERVICE;
}

static pid_t pt_responsibility_get_pid_responsible_for_pid(pid_t pid) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        pid_t self_pid = getpid();
        if (pid == 0 || pid == self_pid) {
            return self_pid;
        }
        errno = ESRCH;
        return -1;
    }
    typedef pid_t (*RespFn)(pid_t);
    static RespFn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (RespFn)dlsym(RTLD_NEXT, "responsibility_get_pid_responsible_for_pid");
    });
    if (s_orig != NULL) {
        return s_orig(pid);
    }
    errno = ENOSYS;
    return -1;
}

static void pt_u_getVersion(uint8_t versionArray[4]) {
    if (versionArray != NULL &&
        pt_is_compat13_7_active() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        versionArray[0] = 64U;
        versionArray[1] = 2U;
        versionArray[2] = 0U;
        versionArray[3] = 0U;
        return;
    }
    typedef void (*UGetVerFn)(uint8_t[4]);
    static UGetVerFn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (UGetVerFn)dlsym(RTLD_NEXT, "u_getVersion");
    });
    if (s_orig != NULL) {
        s_orig(versionArray);
    }
}

static void pt_u_getUnicodeVersion(uint8_t versionArray[4]) {
    if (versionArray != NULL &&
        pt_is_compat13_7_active() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        versionArray[0] = 12U;
        versionArray[1] = 1U;
        versionArray[2] = 0U;
        versionArray[3] = 0U;
        return;
    }
    typedef void (*UGetUniVerFn)(uint8_t[4]);
    static UGetUniVerFn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (UGetUniVerFn)dlsym(RTLD_NEXT, "u_getUnicodeVersion");
    });
    if (s_orig != NULL) {
        s_orig(versionArray);
    }
}

__attribute__((visibility("hidden")))
void *pt_spoofer_dlsym_route(const char *symbol) {
    if (symbol == NULL) {
        return NULL;
    }
    if (strcmp(symbol, "u_getVersion") == 0) {
        return (void *)&pt_u_getVersion;
    }
    if (strcmp(symbol, "u_getUnicodeVersion") == 0) {
        return (void *)&pt_u_getUnicodeVersion;
    }
    if (strcmp(symbol, "MGCopyAnswerWithError") == 0) {
        return (void *)&pt_MGCopyAnswerWithError;
    }
    if (strcmp(symbol, "AudioComponentFindNext") == 0) {
        return (void *)&pt_AudioComponentFindNext;
    }
    if (strcmp(symbol, "AudioComponentCount") == 0) {
        return (void *)&pt_AudioComponentCount;
    }
    if (strcmp(symbol, "UTTypeCopyDeclaringBundleURL") == 0) {
        return (void *)&pt_UTTypeCopyDeclaringBundleURL;
    }
    if (strcmp(symbol, "UTTypeCopyDeclaration") == 0) {
        return (void *)&pt_UTTypeCopyDeclaration;
    }
    if (strcmp(symbol, "vm_read") == 0) {
        return (void *)&pt_vm_read;
    }
    if (strcmp(symbol, "mach_vm_read") == 0) {
        return (void *)&pt_mach_vm_read;
    }
    if (strcmp(symbol, "vm_read_overwrite") == 0) {
        return (void *)&pt_vm_read_overwrite;
    }
    if (strcmp(symbol, "mach_vm_read_overwrite") == 0) {
        return (void *)&pt_mach_vm_read_overwrite;
    }
    if (strcmp(symbol, "vm_region_64") == 0) {
        return (void *)&pt_vm_region_64;
    }
    if (strcmp(symbol, "vm_region_recurse_64") == 0) {
        return (void *)&pt_vm_region_recurse_64;
    }
    if (strcmp(symbol, "mach_vm_region") == 0) {
        return (void *)&pt_mach_vm_region;
    }
    if (strcmp(symbol, "mach_vm_region_recurse") == 0) {
        return (void *)&pt_mach_vm_region_recurse;
    }
    if (strcmp(symbol, "IOIteratorNext") == 0) {
        return (void *)&pt_IOIteratorNext;
    }
    if (strcmp(symbol, "IOObjectGetClass") == 0) {
        return (void *)&pt_IOObjectGetClass;
    }
    if (strcmp(symbol, "IOObjectConformsTo") == 0) {
        return (void *)&pt_IOObjectConformsTo;
    }
    if (strcmp(symbol, "IORegistryEntryGetName") == 0) {
        return (void *)&pt_IORegistryEntryGetName;
    }
    if (strcmp(symbol, "IORegistryEntryGetNameInPlane") == 0) {
        return (void *)&pt_IORegistryEntryGetNameInPlane;
    }
    if (strcmp(symbol, "IORegistryEntryCreateCFProperty") == 0) {
        return (void *)&pt_IORegistryEntryCreateCFProperty;
    }
    if (strcmp(symbol, "IORegistryEntrySearchCFProperty") == 0) {
        return (void *)&pt_IORegistryEntrySearchCFProperty;
    }
    if (strcmp(symbol, "IORegistryEntryCreateCFProperties") == 0) {
        return (void *)&pt_IORegistryEntryCreateCFProperties;
    }
    if (strcmp(symbol, "IORegistryEntryGetPath") == 0) {
        return (void *)&pt_IORegistryEntryGetPath;
    }
    if (strcmp(symbol, "IOServiceGetMatchingService") == 0) {
        return (void *)&pt_IOServiceGetMatchingService;
    }
    if (strcmp(symbol, "IOServiceGetMatchingServices") == 0) {
        return (void *)&pt_IOServiceGetMatchingServices;
    }
    if (strcmp(symbol, "IOPSCopyPowerSourcesInfo") == 0) {
        return (void *)&pt_IOPSCopyPowerSourcesInfo;
    }
    if (strcmp(symbol, "IOPSCopyPowerSourcesList") == 0) {
        return (void *)&pt_IOPSCopyPowerSourcesList;
    }
    if (strcmp(symbol, "IOPSGetPowerSourceDescription") == 0) {
        return (void *)&pt_IOPSGetPowerSourceDescription;
    }
    if (strcmp(symbol, "sysctl") == 0) {
        return (void *)&pt_sysctl;
    }
    if (strcmp(symbol, "__sysctl") == 0) {
        return (void *)&pt_kernel_sysctl;
    }
    if (strcmp(symbol, "sysctlbyname") == 0) {
        return (void *)&pt_sysctlbyname;
    }
    if (strcmp(symbol, "__sysctlbyname") == 0) {
        return (void *)&pt_kernel_sysctlbyname;
    }
    if (strcmp(symbol, "sysctlnametomib") == 0) {
        return (void *)&pt_sysctlnametomib;
    }
    if (strcmp(symbol, "syscall") == 0) {
        return (void *)&pt_syscall;
    }
    if (strcmp(symbol, "uname") == 0) {
        return (void *)&pt_uname;
    }
    if (strcmp(symbol, "bootstrap_look_up") == 0) {
        return (void *)&pt_bootstrap_look_up;
    }
    if (strcmp(symbol, "bootstrap_look_up2") == 0) {
        return (void *)&pt_bootstrap_look_up2;
    }
    if (strcmp(symbol, "bootstrap_look_up3") == 0) {
        return (void *)&pt_bootstrap_look_up3;
    }
    if (strcmp(symbol, "responsibility_get_pid_responsible_for_pid") == 0) {
        return (void *)&pt_responsibility_get_pid_responsible_for_pid;
    }
    if (strcmp(symbol, "host_info") == 0) {
        return (void *)&pt_host_info;
    }
    if (strcmp(symbol, "host_processor_info") == 0) {
        return (void *)&pt_host_processor_info;
    }
    if (strcmp(symbol, "host_statistics") == 0) {
        return (void *)&pt_host_statistics;
    }
    if (strcmp(symbol, "host_statistics64") == 0) {
        return (void *)&pt_host_statistics64;
    }
    if (strcmp(symbol, "task_info") == 0) {
        return (void *)&pt_task_info;
    }
    if (strcmp(symbol, "task_threads") == 0) {
        return (void *)&pt_task_threads;
    }
    if (strcmp(symbol, "pthread_getname_np") == 0) {
        return (void *)&pt_pthread_getname_np;
    }
    if (strcmp(symbol, "thread_info") == 0) {
        return (void *)&pt_thread_info;
    }
    if (strcmp(symbol, "os_proc_available_memory") == 0) {
        return (void *)&pt_os_proc_available_memory;
    }
    if (strcmp(symbol, "mach_msg") == 0) {
        return (void *)&pt_mach_msg;
    }
    if (strcmp(symbol, "mach_msg_overwrite") == 0) {
        return (void *)&pt_mach_msg_overwrite;
    }
    if (strcmp(symbol, "mach_msg2_internal") == 0) {
        if (pt_get_real_mach_msg2_internal() != NULL) {
            return (void *)&pt_mach_msg2_internal;
        }
        return NULL;
    }
    if (strcmp(symbol, "getenv") == 0) {
        return (void *)&pt_getenv;
    }
    if (strcmp(symbol, "_NSGetEnviron") == 0) {
        return (void *)&pt_NSGetEnviron;
    }
    if (strcmp(symbol, "_NSGetArgv") == 0) {
        return (void *)&pt_NSGetArgv;
    }
    if (strcmp(symbol, "_NSGetArgc") == 0) {
        return (void *)&pt_NSGetArgc;
    }
    if (strcmp(symbol, "_NSGetProgname") == 0) {
        return (void *)&pt_NSGetProgname;
    }
    if (strcmp(symbol, "getprogname") == 0) {
        return (void *)&pt_getprogname;
    }
    if (strcmp(symbol, "gethostname") == 0) {
        return (void *)&pt_gethostname;
    }
    if (strcmp(symbol, "getppid") == 0) {
        return (void *)&pt_getppid;
    }
    if (strcmp(symbol, "isatty") == 0) {
        return (void *)&pt_isatty;
    }
    if (strcmp(symbol, "getgid") == 0) {
        return (void *)&pt_getgid;
    }
    if (strcmp(symbol, "getegid") == 0) {
        return (void *)&pt_getegid;
    }
    if (strcmp(symbol, "getgroups") == 0) {
        return (void *)&pt_getgroups;
    }
    if (strcmp(symbol, "getgrouplist") == 0) {
        return (void *)&pt_getgrouplist;
    }
    if (strcmp(symbol, "getgrgid") == 0) {
        return (void *)&pt_getgrgid;
    }
    if (strcmp(symbol, "getgrgid_r") == 0) {
        return (void *)&pt_getgrgid_r;
    }
    if (strcmp(symbol, "getgrnam") == 0) {
        return (void *)&pt_getgrnam;
    }
    if (strcmp(symbol, "getgrnam_r") == 0) {
        return (void *)&pt_getgrnam_r;
    }
    if (strcmp(symbol, "getpwuid") == 0) {
        return (void *)&pt_getpwuid;
    }
    if (strcmp(symbol, "getpwuid_r") == 0) {
        return (void *)&pt_getpwuid_r;
    }
    if (strcmp(symbol, "getpwnam") == 0) {
        return (void *)&pt_getpwnam;
    }
    if (strcmp(symbol, "getpwnam_r") == 0) {
        return (void *)&pt_getpwnam_r;
    }
    if (strcmp(symbol, "getlogin") == 0) {
        return (void *)&pt_getlogin;
    }
    if (strcmp(symbol, "getlogin_r") == 0) {
        return (void *)&pt_getlogin_r;
    }
    if (strcmp(symbol, "user_from_uid") == 0) {
        return (void *)&pt_user_from_uid;
    }
    if (strcmp(symbol, "getutxent") == 0) {
        return (void *)&pt_getutxent;
    }
    if (strcmp(symbol, "getutxid") == 0) {
        return (void *)&pt_getutxid;
    }
    if (strcmp(symbol, "getutxline") == 0) {
        return (void *)&pt_getutxline;
    }
    if (strcmp(symbol, "gethostuuid") == 0) {
        return (void *)&pt_gethostuuid;
    }
    if (strcmp(symbol, "sysconf") == 0) {
        return (void *)&pt_sysconf;
    }
    if (strcmp(symbol, "confstr") == 0) {
        return (void *)&pt_confstr;
    }
    if (strcmp(symbol, "notify_register_check") == 0) {
        return (void *)&pt_notify_register_check;
    }
    if (strcmp(symbol, "notify_register_dispatch") == 0) {
        return (void *)&pt_notify_register_dispatch;
    }
    if (strcmp(symbol, "notify_cancel") == 0) {
        return (void *)&pt_notify_cancel;
    }
    if (strcmp(symbol, "notify_get_state") == 0) {
        return (void *)&pt_notify_get_state;
    }
    if (strcmp(symbol, "CFPreferencesCopyAppValue") == 0) {
        return (void *)&pt_CFPreferencesCopyAppValue;
    }
    if (strcmp(symbol, "CFPreferencesCopyMultiple") == 0) {
        return (void *)&pt_CFPreferencesCopyMultiple;
    }
    if (strcmp(symbol, "CFPropertyListCreateWithData") == 0) {
        return (void *)&pt_CFPropertyListCreateWithData;
    }
    if (strcmp(symbol, "_CFCopySystemVersionDictionary") == 0) {
        return (void *)&pt_CFCopySystemVersionDictionary;
    }
    if (strcmp(symbol, "MGCopyAnswer") == 0) {
        return (void *)&pt_MGCopyAnswer;
    }
    if (strcmp(symbol, "MGCopyMultipleAnswers") == 0) {
        return (void *)&pt_MGCopyMultipleAnswers;
    }
    if (strcmp(symbol, "MGGetBoolAnswer") == 0) {
        return (void *)&pt_MGGetBoolAnswer;
    }
    if (strcmp(symbol, "MGGetSInt32Answer") == 0) {
        return (void *)&pt_MGGetSInt32Answer;
    }
    if (strcmp(symbol, "MGGetStringAnswer") == 0) {
        return (void *)&pt_MGGetStringAnswer;
    }
    if (strcmp(symbol, "MGGetProductType") == 0) {
        return (void *)&pt_MGGetProductType;
    }
    if (strcmp(symbol, "fork") == 0) {
        return (void *)&pt_fork;
    }
    if (strcmp(symbol, "vfork") == 0) {
        return (void *)&pt_vfork;
    }
    if (strcmp(symbol, "popen") == 0) {
        return (void *)&pt_popen;
    }
    if (strcmp(symbol, "posix_spawn") == 0) {
        return (void *)&pt_posix_spawn;
    }
    if (strcmp(symbol, "posix_spawnp") == 0) {
        return (void *)&pt_posix_spawnp;
    }
    if (strcmp(symbol, "system") == 0) {
        return (void *)&pt_system;
    }
    return NULL;
}

DYLD_INTERPOSE(pt_uname, uname)
DYLD_INTERPOSE(pt_availability_version_check, pt_orig_availability_version_check)
DYLD_INTERPOSE(pt_syscall, pt_orig_syscall)
DYLD_INTERPOSE(pt_kernel_sysctl, pt_orig_kernel_sysctl)
DYLD_INTERPOSE(pt_kernel_sysctlbyname, pt_orig_kernel_sysctlbyname)
DYLD_INTERPOSE(pt_vm_region_64, pt_orig_vm_region_64)
DYLD_INTERPOSE(pt_vm_region_recurse_64, pt_orig_vm_region_recurse_64)
DYLD_INTERPOSE(pt_mach_vm_region, pt_orig_mach_vm_region)
DYLD_INTERPOSE(pt_mach_vm_region_recurse, pt_orig_mach_vm_region_recurse)
DYLD_INTERPOSE(pt_vm_read_overwrite, pt_orig_vm_read_overwrite)
DYLD_INTERPOSE(pt_mach_vm_read_overwrite, pt_orig_mach_vm_read_overwrite)
DYLD_INTERPOSE(pt_vm_read, pt_orig_vm_read)
DYLD_INTERPOSE(pt_mach_vm_read, pt_orig_mach_vm_read)
DYLD_INTERPOSE(pt_sysctlbyname, sysctlbyname)
DYLD_INTERPOSE(pt_sysctlnametomib, sysctlnametomib)
DYLD_INTERPOSE(pt_sysctl, sysctl)
DYLD_INTERPOSE(pt_CFCopySystemVersionDictionary, _CFCopySystemVersionDictionary)
DYLD_INTERPOSE(pt_CFPropertyListCreateWithData, CFPropertyListCreateWithData)
DYLD_INTERPOSE(pt_IORegistryEntryCreateCFProperty, IORegistryEntryCreateCFProperty)
DYLD_INTERPOSE(pt_IORegistryEntrySearchCFProperty, IORegistryEntrySearchCFProperty)
DYLD_INTERPOSE(pt_IORegistryEntryCreateCFProperties, IORegistryEntryCreateCFProperties)
DYLD_INTERPOSE(pt_IORegistryEntryGetPath, IORegistryEntryGetPath)
DYLD_INTERPOSE(pt_IOServiceGetMatchingService, IOServiceGetMatchingService)
DYLD_INTERPOSE(pt_IOServiceGetMatchingServices, IOServiceGetMatchingServices)
DYLD_INTERPOSE(pt_IOObjectGetClass, IOObjectGetClass)
DYLD_INTERPOSE(pt_IOIteratorNext, IOIteratorNext)
DYLD_INTERPOSE(pt_AudioComponentFindNext, AudioComponentFindNext)
DYLD_INTERPOSE(pt_AudioComponentCount, AudioComponentCount)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
DYLD_INTERPOSE(pt_UTTypeCopyDeclaringBundleURL, UTTypeCopyDeclaringBundleURL)
DYLD_INTERPOSE(pt_UTTypeCopyDeclaration, UTTypeCopyDeclaration)
#pragma clang diagnostic pop
DYLD_INTERPOSE(pt_IOPSCopyPowerSourcesInfo, IOPSCopyPowerSourcesInfo)
DYLD_INTERPOSE(pt_IOPSCopyPowerSourcesList, IOPSCopyPowerSourcesList)
DYLD_INTERPOSE(pt_IOPSGetPowerSourceDescription, IOPSGetPowerSourceDescription)
DYLD_INTERPOSE(pt_MGCopyAnswer, MGCopyAnswer)
DYLD_INTERPOSE(pt_MGCopyAnswerWithError, MGCopyAnswerWithError)
DYLD_INTERPOSE(pt_MGCopyMultipleAnswers, MGCopyMultipleAnswers)
DYLD_INTERPOSE(pt_MGGetBoolAnswer, MGGetBoolAnswer)
DYLD_INTERPOSE(pt_MGGetSInt32Answer, MGGetSInt32Answer)
DYLD_INTERPOSE(pt_MGGetStringAnswer, MGGetStringAnswer)
DYLD_INTERPOSE(pt_MGGetProductType, MGGetProductType)
DYLD_INTERPOSE(pt_getenv, getenv)
DYLD_INTERPOSE(pt_NSGetEnviron, _NSGetEnviron)
DYLD_INTERPOSE(pt_NSGetArgv, _NSGetArgv)
DYLD_INTERPOSE(pt_NSGetArgc, _NSGetArgc)
DYLD_INTERPOSE(pt_NSGetProgname, _NSGetProgname)
DYLD_INTERPOSE(pt_getprogname, getprogname)
DYLD_INTERPOSE(pt_gethostname, gethostname)
DYLD_INTERPOSE(pt_getgid, getgid)
DYLD_INTERPOSE(pt_getegid, getegid)
DYLD_INTERPOSE(pt_getgroups, getgroups)
DYLD_INTERPOSE(pt_getpwuid, getpwuid)
DYLD_INTERPOSE(pt_getpwuid_r, getpwuid_r)
DYLD_INTERPOSE(pt_getpwnam, getpwnam)
DYLD_INTERPOSE(pt_getpwnam_r, getpwnam_r)
DYLD_INTERPOSE(pt_getlogin, getlogin)
DYLD_INTERPOSE(pt_getlogin_r, getlogin_r)
DYLD_INTERPOSE(pt_NSUserName, NSUserName)
DYLD_INTERPOSE(pt_NSFullUserName, NSFullUserName)
DYLD_INTERPOSE(pt_user_from_uid, user_from_uid)
DYLD_INTERPOSE(pt_sysconf, sysconf)
DYLD_INTERPOSE(pt_confstr, confstr)
DYLD_INTERPOSE(pt_CFCopyHomeDirectoryURL, CFCopyHomeDirectoryURL)
DYLD_INTERPOSE(pt_CFCopyHomeDirectoryURLForUser, CFCopyHomeDirectoryURLForUser)
DYLD_INTERPOSE(pt_CFCopyUserName, CFCopyUserName)
DYLD_INTERPOSE(pt_NSHomeDirectory, NSHomeDirectory)
DYLD_INTERPOSE(pt_NSHomeDirectoryForUser, NSHomeDirectoryForUser)
DYLD_INTERPOSE(pt_NSTemporaryDirectory, NSTemporaryDirectory)
DYLD_INTERPOSE(pt_NSSearchPathForDirectoriesInDomains, NSSearchPathForDirectoriesInDomains)
DYLD_INTERPOSE(pt_CFBundleCreate, CFBundleCreate)
DYLD_INTERPOSE(pt_CFBundleCopyBundleURL, CFBundleCopyBundleURL)
DYLD_INTERPOSE(pt_CFBundleCopyResourcesDirectoryURL, CFBundleCopyResourcesDirectoryURL)
DYLD_INTERPOSE(pt_CFBundleCopyExecutableURL, CFBundleCopyExecutableURL)
DYLD_INTERPOSE(pt_CFBundleCopyResourceURL, CFBundleCopyResourceURL)
DYLD_INTERPOSE(pt_CFBundleCopyResourceURLsOfType, CFBundleCopyResourceURLsOfType)
DYLD_INTERPOSE(pt_CFBundleCopyResourceURLInDirectory, CFBundleCopyResourceURLInDirectory)
DYLD_INTERPOSE(pt_CFBundleCopyResourceURLsOfTypeInDirectory, CFBundleCopyResourceURLsOfTypeInDirectory)
DYLD_INTERPOSE(pt_CFBundleCopyResourceURLForLocalization, CFBundleCopyResourceURLForLocalization)
DYLD_INTERPOSE(pt_CFBundleCopyResourceURLsOfTypeForLocalization, CFBundleCopyResourceURLsOfTypeForLocalization)
DYLD_INTERPOSE(pt_CFBundleCopyAuxiliaryExecutableURL, CFBundleCopyAuxiliaryExecutableURL)
DYLD_INTERPOSE(pt_CFBundleCopyBuiltInPlugInsURL, CFBundleCopyBuiltInPlugInsURL)
DYLD_INTERPOSE(pt_CFBundleCopySharedFrameworksURL, CFBundleCopySharedFrameworksURL)
DYLD_INTERPOSE(pt_CFBundleCopyPrivateFrameworksURL, CFBundleCopyPrivateFrameworksURL)
DYLD_INTERPOSE(pt_CFBundleCopySharedSupportURL, CFBundleCopySharedSupportURL)
DYLD_INTERPOSE(pt_CFBundleCopySupportFilesDirectoryURL, CFBundleCopySupportFilesDirectoryURL)
DYLD_INTERPOSE(pt_CFBundleCopyInfoDictionaryForURL, CFBundleCopyInfoDictionaryForURL)
DYLD_INTERPOSE(pt_CFBundleCopyInfoDictionaryInDirectory, CFBundleCopyInfoDictionaryInDirectory)
DYLD_INTERPOSE(pt_CFBundleGetInfoDictionary, CFBundleGetInfoDictionary)
DYLD_INTERPOSE(pt_CFBundleGetLocalInfoDictionary, CFBundleGetLocalInfoDictionary)
DYLD_INTERPOSE(pt_CFBundleGetValueForInfoDictionaryKey, CFBundleGetValueForInfoDictionaryKey)
DYLD_INTERPOSE(pt_CFBundleGetBundleWithIdentifier, CFBundleGetBundleWithIdentifier)
DYLD_INTERPOSE(pt_CFBundleGetAllBundles, CFBundleGetAllBundles)
DYLD_INTERPOSE(pt_fork, fork)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
DYLD_INTERPOSE(pt_vfork, vfork)
#pragma clang diagnostic pop
DYLD_INTERPOSE(pt_popen, popen)
DYLD_INTERPOSE(pt_popen_darwin_extsn, pt_orig_popen_darwin_extsn)
DYLD_INTERPOSE(pt_posix_spawn, posix_spawn)
DYLD_INTERPOSE(pt_posix_spawnp, posix_spawnp)
DYLD_INTERPOSE(pt_system, pt_orig_system)
DYLD_INTERPOSE(pt_getppid, getppid)
DYLD_INTERPOSE(pt_isatty, isatty)
DYLD_INTERPOSE(pt_usleep, usleep)
DYLD_INTERPOSE(pt_os_proc_available_memory, os_proc_available_memory)
DYLD_INTERPOSE(pt_host_info, host_info)
DYLD_INTERPOSE(pt_host_processor_info, host_processor_info)
DYLD_INTERPOSE(pt_host_statistics, host_statistics)
DYLD_INTERPOSE(pt_host_statistics64, host_statistics64)
DYLD_INTERPOSE(pt_task_info, task_info)
DYLD_INTERPOSE(pt_task_threads, task_threads)
DYLD_INTERPOSE(pt_pthread_getname_np, pthread_getname_np)
DYLD_INTERPOSE(pt_thread_info, thread_info)
DYLD_INTERPOSE(pt_IORegistryEntryGetName, IORegistryEntryGetName)
DYLD_INTERPOSE(pt_IORegistryEntryGetNameInPlane, IORegistryEntryGetNameInPlane)
DYLD_INTERPOSE(pt_IOObjectConformsTo, IOObjectConformsTo)
DYLD_INTERPOSE(pt_CFPreferencesCopyAppValue, CFPreferencesCopyAppValue)
DYLD_INTERPOSE(pt_CFPreferencesCopyMultiple, CFPreferencesCopyMultiple)
DYLD_INTERPOSE(pt_getgrgid, getgrgid)
DYLD_INTERPOSE(pt_getgrgid_r, getgrgid_r)
DYLD_INTERPOSE(pt_getgrnam, getgrnam)
DYLD_INTERPOSE(pt_getgrnam_r, getgrnam_r)
DYLD_INTERPOSE(pt_getgrouplist, pt_orig_getgrouplist)
DYLD_INTERPOSE(pt_getutxent, pt_orig_getutxent)
DYLD_INTERPOSE(pt_getutxid, pt_orig_getutxid)
DYLD_INTERPOSE(pt_getutxline, pt_orig_getutxline)
DYLD_INTERPOSE(pt_gethostuuid, pt_orig_gethostuuid)
DYLD_INTERPOSE(pt_notify_register_check, notify_register_check)
DYLD_INTERPOSE(pt_notify_register_dispatch, notify_register_dispatch)
DYLD_INTERPOSE(pt_notify_cancel, notify_cancel)
DYLD_INTERPOSE(pt_notify_get_state, notify_get_state)
DYLD_INTERPOSE(pt_mach_msg, mach_msg)
DYLD_INTERPOSE(pt_mach_msg_overwrite, mach_msg_overwrite)
DYLD_INTERPOSE(pt_bootstrap_look_up, bootstrap_look_up)
