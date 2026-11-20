//
//  PTSystemSpoofer.m
//  PlayTools
//

#import "PTInternal.h"

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
static char s_early_device_model[64] = "iPad13,8";
static char s_early_oem_id[64] = "J522AP";
static char s_final_device_model[64] = "iPad13,8";
static char s_final_oem_id[64] = "J522AP";
static _Atomic(const char *) s_active_device_model = s_early_device_model;
static _Atomic(const char *) s_active_oem_id = s_early_oem_id;
static pthread_once_t s_pt_early_device_once = PTHREAD_ONCE_INIT;
__attribute__((visibility("hidden"))) pthread_once_t s_pt_device_info_once = PTHREAD_ONCE_INIT;
__attribute__((visibility("hidden"))) _Thread_local BOOL s_tls_initializing_device_info = NO;


static const pt_device_profile_t s_device_profiles[] = {
    { "iPad6,7",    "J98aAP",  "Apple A9X",        "Apple A9X GPU",     2, 2, 0, 4ULL << 30, 0x67ceee93U, "RELEASE_ARM64_T8000", "t8000", "iPad Pro (12.9-inch)",                  "ML0F2", "A1584", YES, 2048, 2732, 2.0, 60  },
    { "iPad8,6",    "J320xAP", "Apple A12X Bionic","Apple A12X GPU",    8, 4, 4, 4ULL << 30, 0x07d34b9fU, "RELEASE_ARM64_T8027", "t8027", "iPad Pro (12.9-inch) (3rd generation)", "MTEL2", "A1876", YES, 2048, 2732, 2.0, 120 },
    { "iPad13,8",   "J522AP",  "Apple M1",         "Apple M1 GPU",      8, 4, 4, 8ULL << 30, 0x1b588bb3U, "RELEASE_ARM64_T8103", "t8103", "iPad Pro (12.9-inch) (5th generation)", "MHNF3", "A2378", YES, 2048, 2732, 2.0, 120 },
    { "iPad14,5",   "J620AP",  "Apple M2",         "Apple M2 GPU",      8, 4, 4, 8ULL << 30, 0xda33d83dU, "RELEASE_ARM64_T8112", "t8112", "iPad Pro (12.9-inch) (6th generation)", "MNXP3", "A2436", YES, 2048, 2732, 2.0, 120 },
    { "iPad16,6",   "J720AP",  "Apple M4",         "Apple M4 GPU",      9, 3, 6, 8ULL << 30, 0x6f5129acU, "RELEASE_ARM64_T8132", "t8132", "iPad Pro 13-inch (M4)",                 "MVX23", "A2925", YES, 2064, 2752, 2.0, 120 },
    { "iPad17,3",   "J820AP",  "Apple M5",         "Apple M5 GPU",      9, 3, 6, 12ULL << 30, 0x1d5a87e8U, "RELEASE_ARM64_T8142", "t8142", "iPad Pro 13-inch (M5)",                 "MD8R4", "A3360", YES, 2064, 2752, 2.0, 120 },
    { "iPhone12,5", "D431AP",  "Apple A13 Bionic", "Apple A13 GPU",     6, 2, 4, 4ULL << 30, 0x573b5eecU, "RELEASE_ARM64_T8030", "t8030", "iPhone 11 Pro Max",                     "MWHD2", "A2161", NO,  1242, 2688, 3.0, 60  },
    { "iPhone14,3", "D64AP",   "Apple A15 Bionic", "Apple A15 GPU",     6, 2, 4, 6ULL << 30, 0xda33d83dU, "RELEASE_ARM64_T8110", "t8110", "iPhone 13 Pro Max",                     "MLL63", "A2484", NO,  1284, 2778, 3.0, 120 },
    { "iPhone15,3", "D74AP",   "Apple A16 Bionic", "Apple A16 GPU",     6, 2, 4, 6ULL << 30, 0x8765edeaU, "RELEASE_ARM64_T8120", "t8120", "iPhone 14 Pro Max",                     "MQ8N3", "A2651", NO,  1290, 2796, 3.0, 120 },
    { "iPhone16,2", "D84AP",   "Apple A17 Pro",    "Apple A17 Pro GPU", 6, 2, 4, 8ULL << 30, 0xfa33415eU, "RELEASE_ARM64_T8130", "t8130", "iPhone 15 Pro Max",                     "MU683", "A2849", NO,  1290, 2796, 3.0, 120 },
    { "iPhone17,2", "D94AP",   "Apple A18 Pro",    "Apple A18 Pro GPU", 6, 2, 4, 8ULL << 30, 0x75d4acb9U, "RELEASE_ARM64_T8140", "t8140", "iPhone 16 Pro Max",                     "MYWV3", "A3084", NO,  1320, 2868, 3.0, 120 },
    { "iPhone18,2", "D94xAP",  "Apple A19 Pro",    "Apple A19 Pro GPU", 6, 2, 4, 12ULL << 30, 0xab345f09U, "RELEASE_ARM64_T8150", "t8150", "iPhone 17 Pro Max",                     "MFY84", "A3257", NO,  1320, 2868, 3.0, 120 },
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

__attribute__((visibility("hidden"))) void pt_init_early_bypass(void) {
    pt_enter_internal_scope();
    const char *dis = getenv("DISABLE_PLAYSHADOW_BYPASS");
    if (dis != NULL && strcmp(dis, "1") == 0) {
        atomic_store_explicit(&s_bypass_enabled, NO, memory_order_relaxed);
        atomic_store_explicit(&s_pt_bypass_inited, YES, memory_order_release);
        PT_DEBUG_TRACE("spoofer", "bypass disabled via DISABLE_PLAYSHADOW_BYPASS=1");
        pt_leave_internal_scope();
        return;
    }
    int fd = pt_open_early_settings_plist_fd();
    if (fd >= 0) {
        BOOL bypass_val = YES;
        if (pt_read_plist_top_bool_from_fd(fd, "bypass", &bypass_val) && !bypass_val) {
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
    if (pt_extract_host_user_root_from_env_val(getenv("HOME"), s_cached_host_user_root, sizeof(s_cached_host_user_root))) {
        return;
    }
    if (pt_extract_host_user_root_from_env_val(getenv("CFFIXED_USER_HOME"), s_cached_host_user_root, sizeof(s_cached_host_user_root))) {
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
        if (pt_extract_host_user_root_from_env_val(getenv("HOME"), tls_early_root, sizeof(tls_early_root)) ||
            pt_extract_host_user_root_from_env_val(getenv("CFFIXED_USER_HOME"), tls_early_root, sizeof(tls_early_root))) {
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

    const char *override_plist = getenv("PLAYTOOLS_SETTINGS_PLIST");
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
            const char *home = getenv("CFFIXED_USER_HOME");
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

static void pt_init_early_device_info(void) {
    int fd = pt_open_early_settings_plist_fd();
    if (fd >= 0) {
        char parsed_model[64];
        if (pt_read_plist_top_string_from_fd(fd, "iosDeviceModel", parsed_model, sizeof(parsed_model)) &&
            parsed_model[0] != '\0') {
            const pt_device_profile_t *profile = pt_set_cached_device_profile_from_model(
                parsed_model,
                s_early_device_model, sizeof(s_early_device_model),
                s_early_oem_id, sizeof(s_early_oem_id));
            atomic_store_explicit(&s_active_device_profile, profile, memory_order_release);
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
    BOOL prev_tls = s_tls_initializing_device_info;
    s_tls_initializing_device_info = YES;
    @autoreleasepool {
        NSString *model = [[PlaySettings shared] deviceModel];
        const char *m = [model UTF8String];
        if (m != NULL && m[0] != '\0') {
            final_profile = pt_set_cached_device_profile_from_model(
                m,
                s_final_device_model, sizeof(s_final_device_model),
                s_final_oem_id, sizeof(s_final_oem_id));
        } else {
            NSString *oem = [[PlaySettings shared] oemID];
            const char *o = [oem UTF8String];
            if (o != NULL && o[0] != '\0') {
                strlcpy(s_final_oem_id, o, sizeof(s_final_oem_id));
            }
        }
    }
    s_tls_initializing_device_info = prev_tls;
    atomic_store_explicit(&s_active_device_profile, final_profile, memory_order_release);
    atomic_store_explicit(&s_active_device_model, s_final_device_model, memory_order_release);
    atomic_store_explicit(&s_active_oem_id, s_final_oem_id, memory_order_release);
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
static _Atomic BOOL s_reported_ios_override_forced_off = NO;
static pthread_once_t s_host_kern_once = PTHREAD_ONCE_INIT;

static BOOL pt_is_safe_mode_env_active(void) {
    const char *raw = getenv("PLAYTOOLS_SAFE_MODE");
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

    char osv[64] = {0};
    size_t osv_len = sizeof(osv);
    if (sysctlbyname("kern.osversion", osv, &osv_len, NULL, 0) != 0) {
        osv[0] = '\0';
    }
    int major = atoi(s_real_kern_release);
    if (osv[0] != '\0') {
        if (major >= 24 &&
            osv[0] >= '0' && osv[0] <= '9' &&
            osv[1] >= '0' && osv[1] <= '9') {
            int b_prefix = (osv[0] - '0') * 10 + (osv[1] - '0');
            int target_prefix = major - 2;
            if (b_prefix > target_prefix) {
                snprintf(s_spoofed_osversion, sizeof(s_spoofed_osversion), "%d%s", target_prefix, osv + 2);
            } else {
                strlcpy(s_spoofed_osversion, osv, sizeof(s_spoofed_osversion));
            }
        } else {
            strlcpy(s_spoofed_osversion, osv, sizeof(s_spoofed_osversion));
        }
    }

    int sv_fd = pt_orig_open_nocancel("/System/Library/CoreServices/SystemVersion.plist", O_RDONLY);
    if (sv_fd >= 0) {
        char ios_ver[32];
        if (pt_read_plist_top_string_from_fd(sv_fd, "iOSSupportVersion", ios_ver, sizeof(ios_ver)) &&
            ios_ver[0] != '\0') {
            strlcpy(s_spoofed_ios_version, ios_ver, sizeof(s_spoofed_ios_version));
        }
        close(sv_fd);
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
                if (strcasecmp(rep_mode, "compat18_3") == 0 ||
                    strcmp(rep_mode, "18.3") == 0 ||
                    strcasecmp(rep_mode, "ios18_3") == 0) {
                    atomic_store_explicit(&s_reported_ios_override_mode,
                                          PT_REPORTED_IOS_OVERRIDE_18_3,
                                          memory_order_release);
                } else if (strcasecmp(rep_mode, "compat13_7") == 0 ||
                           strcmp(rep_mode, "13.7") == 0 ||
                           strcasecmp(rep_mode, "ios13_7") == 0) {
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
    { "hw.perflevel0.name", {0}, 0 },
    { "hw.perflevel1.physicalcpu", {0}, 0 },
    { "hw.perflevel1.physicalcpu_max", {0}, 0 },
    { "hw.perflevel1.logicalcpu", {0}, 0 },
    { "hw.perflevel1.logicalcpu_max", {0}, 0 },
    { "hw.perflevel1.name", {0}, 0 },
    { "hw.use_kernelmanagerd", {0}, 0 },
    { "kern.iossupportversion", {0}, 0 },
    { "kern.osproductversion", {0}, 0 },
    { "kern.bootargs", {0}, 0 },
    { "kern.wakereason", {0}, 0 },
    { "kern.hibernatefile", {0}, 0 },
    { "kern.hv_support", {0}, 0 },
    { "kern.secure_kernel", {0}, 0 },
    { "security.mac.amfi.developer_mode_status", {0}, 0 },
    { "sysctl.proc_translated", {0}, 0 },
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
    char c0 = name[0];
    if (c0 != 'h' && c0 != 'k' && c0 != 'm' && c0 != 's') {
        return NO;
    }
    if (c0 == 'h' && strncmp(name, "hw.", 3) == 0) {
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
        if (!pt_is_bypass_enabled() || pt_sysctl_resolve_is_sys(caller, inout_is_sys_caller)) {
            return NO;
        }
        const pt_device_profile_t *profile = pt_get_active_device_profile();
        if (strcmp(sub, "use_kernelmanagerd") == 0) {
            *out_ret = pt_write_sysctl_int(0, oldp, oldlenp);
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
        if (strcmp(sub, "hv_support") == 0) {
            *out_ret = pt_write_sysctl_int(0, oldp, oldlenp);
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
    if ((c0 == 's' && strcmp(name, "security.mac.amfi.developer_mode_status") == 0) ||
        (c0 == 's' && strcmp(name, "sysctl.proc_translated") == 0)) {
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
        (strcmp(sname, "kern.iossupportversion") == 0 ||
         strcmp(sname, "kern.hibernatefile") == 0) &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
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

static inline BOOL pt_is_hidden_env_value(const char *val) {
    if (val == NULL || val[0] == '\0') {
        return NO;
    }
    return (strstr(val, "/Users/") != NULL ||
            strcasestr(val, "PlayTools") != NULL ||
            strcasestr(val, "PlayCover") != NULL ||
            strcasestr(val, "MacOver") != NULL ||
            strcasestr(val, "app.makedie") != NULL ||
            strcasestr(val, "AKInterface") != NULL);
}

static int pt_handle_sysctl_procargs(int *name, u_int types, void *buf, size_t *size) {
    if (types < 3 || (name[2] != getpid())) {
        errno = ESRCH;
        return -1;
    }
    BOOL is_v2 = (name[1] == KERN_PROCARGS2);
    size_t raw_len = 0;
    if (sysctl(name, types, NULL, &raw_len, NULL, 0) != 0 || raw_len == 0) {
        return -1;
    }
    size_t alloc_len = raw_len + 64U;
    char *raw = (char *)malloc(alloc_len);
    if (raw == NULL) {
        errno = ENOMEM;
        return -1;
    }
    if (sysctl(name, types, raw, &raw_len, NULL, 0) != 0) {
        int saved = errno;
        free(raw);
        errno = saved;
        return -1;
    }

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

    if (is_v2 && argc > 0) {
        for (int i = 0; i < argc && pos < raw_len; i++) {
            const char *arg = raw + pos;
            size_t alen = strnlen(arg, raw_len - pos);
            const char *out_arg = arg;
            char varg[PATH_MAX];
            if (i == 0) {
                out_arg = pt_virtualize_path_for_app(arg, varg, sizeof(varg), YES);
            }
            if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, out_arg, strlen(out_arg) + 1U)) {
                free(raw); free(out); errno = ENOMEM; return -1;
            }
            pos += (alen < raw_len - pos) ? (alen + 1U) : alen;
        }
    }

    const char *vh = pt_get_virtual_home_cstr();
    const char *vt = pt_get_virtual_tmpdir_cstr();
    BOOL wrote_home = NO;
    BOOL wrote_cffixed_home = NO;
    BOOL wrote_tmpdir = NO;
    BOOL wrote_pwd = NO;
    BOOL wrote_path = NO;
    while (pos < raw_len) {
        if (raw[pos] == '\0') {
            pos++;
            continue;
        }
        const char *entry = raw + pos;
        size_t elen = strnlen(entry, raw_len - pos);
        const char *eq = (const char *)memchr(entry, '=', elen);
        if (eq != NULL && eq > entry) {
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
            if (strcmp(kptr, "HOME") == 0 && vh != NULL) {
                if (!wrote_home) {
                    if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, "HOME=", 5U) ||
                        !pt_append_procargs_bytes(&out, &out_len, &out_cap, vh, strlen(vh) + 1U)) {
                        free(heap_key); free(raw); free(out); errno = ENOMEM; return -1;
                    }
                    wrote_home = YES;
                }
            } else if (strcmp(kptr, "CFFIXED_USER_HOME") == 0 && vh != NULL) {
                if (!wrote_cffixed_home) {
                    if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, "CFFIXED_USER_HOME=", 18U) ||
                        !pt_append_procargs_bytes(&out, &out_len, &out_cap, vh, strlen(vh) + 1U)) {
                        free(heap_key); free(raw); free(out); errno = ENOMEM; return -1;
                    }
                    wrote_cffixed_home = YES;
                }
            } else if (strcmp(kptr, "TMPDIR") == 0 && vt != NULL) {
                if (!wrote_tmpdir) {
                    if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, "TMPDIR=", 7U) ||
                        !pt_append_procargs_bytes(&out, &out_len, &out_cap, vt, strlen(vt) + 1U)) {
                        free(heap_key); free(raw); free(out); errno = ENOMEM; return -1;
                    }
                    wrote_tmpdir = YES;
                }
            } else if (strcmp(kptr, "PWD") == 0) {
                if (!wrote_pwd) {
                    static const char kSafePwd[] = "PWD=/";
                    if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, kSafePwd, sizeof(kSafePwd))) {
                        free(heap_key); free(raw); free(out); errno = ENOMEM; return -1;
                    }
                    wrote_pwd = YES;
                }
            } else if (strcmp(kptr, "PATH") == 0) {
                if (!wrote_path) {
                    static const char kSafePath[] = "PATH=/usr/bin:/bin:/usr/sbin:/sbin";
                    if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, kSafePath, sizeof(kSafePath))) {
                        free(heap_key); free(raw); free(out); errno = ENOMEM; return -1;
                    }
                    wrote_path = YES;
                }
            } else if (!pt_is_hidden_env_key(kptr)) {
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
                BOOL hide_val = pt_is_hidden_env_value(vptr);
                free(heap_val);
                if (!hide_val) {
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
    if (!wrote_home && vh != NULL) {
        if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, "HOME=", 5U) ||
            !pt_append_procargs_bytes(&out, &out_len, &out_cap, vh, strlen(vh) + 1U)) {
            free(raw); free(out); errno = ENOMEM; return -1;
        }
    }
    if (!wrote_cffixed_home && vh != NULL) {
        if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, "CFFIXED_USER_HOME=", 18U) ||
            !pt_append_procargs_bytes(&out, &out_len, &out_cap, vh, strlen(vh) + 1U)) {
            free(raw); free(out); errno = ENOMEM; return -1;
        }
    }
    if (!wrote_tmpdir && vt != NULL) {
        if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, "TMPDIR=", 7U) ||
            !pt_append_procargs_bytes(&out, &out_len, &out_cap, vt, strlen(vt) + 1U)) {
            free(raw); free(out); errno = ENOMEM; return -1;
        }
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

static int pt_sysctl(int *name, u_int types, void *buf, size_t *size, void *arg0, size_t arg1) {
    const void *ret_addr = __builtin_return_address(0);
    int is_sys_caller = -1;
    if (name != NULL && types >= 2) {
        if (name[0] == CTL_HW) {
            if (name[1] == HW_MACHINE || name[1] == HW_PRODUCT) {
                return pt_write_sysctl_string(DEVICE_MODEL, buf, size);
            } else if (name[1] == HW_MODEL || name[1] == HW_TARGET) {
                return pt_write_sysctl_string(OEM_ID, buf, size);
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
    int ret = sysctl(name, types, buf, size, arg0, arg1);
    if (ret == 0 && name != NULL && types >= 3 &&
        name[0] == CTL_KERN && name[1] == KERN_PROC && size != NULL) {
        BOOL is_sys = pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller);
        if (name[2] == KERN_PROC_PID) {
            if (buf != NULL && *size >= sizeof(struct kinfo_proc)) {
                struct kinfo_proc *info = (struct kinfo_proc *)buf;
                info->kp_proc.p_flag &= ~P_TRACED;
                if (!is_sys) {
                    info->kp_eproc.e_ppid = 1;
                    strlcpy(info->kp_eproc.e_login, "mobile", sizeof(info->kp_eproc.e_login));
                }
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
                        entries[i].kp_proc.p_flag &= ~P_TRACED;
                        if (!is_sys) {
                            entries[i].kp_eproc.e_ppid = 1;
                            strlcpy(entries[i].kp_eproc.e_login, "mobile", sizeof(entries[i].kp_eproc.e_login));
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
    return ret;
}

static int pt_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (name != NULL) {
        int is_sys_caller = -1;
        int sret = 0;
        if (pt_handle_sysctl_name(name, oldp, oldlenp, newp, newlen, __builtin_return_address(0), &is_sys_caller, &sret)) {
            PT_DEBUG_TRACE("spoofer", "spoofed sysctlbyname name=%s ret=%d", name, sret);
            return sret;
        }
    }
    return sysctlbyname(name, oldp, oldlenp, newp, newlen);
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
    id origProdName = dict[@"ProductName"];
    id iosVer = dict[@"iOSSupportVersion"];
    BOOL hadMacMarkers = (([origProdName isKindOfClass:[NSString class]] &&
                           [(NSString *)origProdName isEqualToString:@"macOS"]) ||
                          iosVer != nil);
    if ([iosVer isKindOfClass:[NSString class]] && [(NSString *)iosVer length] > 0) {
        dict[@"ProductVersion"] = iosVer;
        if (dict[@"ProductUserVisibleVersion"] != nil) {
            dict[@"ProductUserVisibleVersion"] = iosVer;
        }
    }
    [dict removeObjectForKey:@"iOSSupportVersion"];
    pt_ensure_host_kernel_info();
    id buildVer = dict[@"ProductBuildVersion"];
    if ([buildVer isKindOfClass:[NSString class]] && [(NSString *)buildVer length] >= 3) {
        NSString *bstr = (NSString *)buildVer;
        unichar c0 = [bstr characterAtIndex:0];
        unichar c1 = [bstr characterAtIndex:1];
        if (c0 >= '0' && c0 <= '9' && c1 >= '0' && c1 <= '9') {
            int b_prefix = (int)(c0 - '0') * 10 + (int)(c1 - '0');
            if (hadMacMarkers && b_prefix >= 24) {
                // macOS 15 (24*) -> iOS 18 (22*), macOS 26 (25*) -> iOS 26 (23*), etc.
                dict[@"ProductBuildVersion"] = [NSString stringWithFormat:@"%d%@", b_prefix - 2, [bstr substringFromIndex:2]];
            } else {
                int major = atoi(s_real_kern_release);
                if (major >= 24) {
                    int target_prefix = major - 2;
                    if (b_prefix > target_prefix) {
                        dict[@"ProductBuildVersion"] = [NSString stringWithFormat:@"%d%@", target_prefix, [bstr substringFromIndex:2]];
                    }
                }
            }
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
    if (dict[@"CFBundleIdentifier"] == nil && dict[@"CFBundleExecutable"] == nil) {
        return nil;
    }
    BOOL needs_clean = NO;
    id platforms = dict[@"CFBundleSupportedPlatforms"];
    if ([platforms isKindOfClass:[NSArray class]]) {
        for (id p in (NSArray *)platforms) {
            if ([p isKindOfClass:[NSString class]] &&
                ([(NSString *)p isEqualToString:@"MacOSX"] ||
                 [(NSString *)p isEqualToString:@"macOS"])) {
                needs_clean = YES;
                break;
            }
        }
    }
    id dtPlat = dict[@"DTPlatformName"];
    if ([dtPlat isKindOfClass:[NSString class]] &&
        ([(NSString *)dtPlat caseInsensitiveCompare:@"macosx"] == NSOrderedSame)) {
        needs_clean = YES;
    }
    id dtSdk = dict[@"DTSDKName"];
    if ([dtSdk isKindOfClass:[NSString class]] &&
        ([(NSString *)dtSdk hasPrefix:@"macosx"] || [(NSString *)dtSdk hasPrefix:@"MacOSX"])) {
        needs_clean = YES;
    }
    id prin = dict[@"NSPrincipalClass"];
    if ([prin isKindOfClass:[NSString class]] &&
        [(NSString *)prin isEqualToString:@"NSApplication"]) {
        needs_clean = YES;
    }
    if (dict[@"LSMinimumSystemVersion"] != nil || dict[@"LSEnvironment"] != nil) {
        needs_clean = YES;
    }
    if (!needs_clean) {
        return nil;
    }
    NSMutableDictionary *clean = [dict mutableCopy];
    if ([platforms isKindOfClass:[NSArray class]]) {
        clean[@"CFBundleSupportedPlatforms"] = [NSMutableArray arrayWithObject:@"iPhoneOS"];
    }
    if ([dtPlat isKindOfClass:[NSString class]] &&
        [(NSString *)dtPlat caseInsensitiveCompare:@"macosx"] == NSOrderedSame) {
        clean[@"DTPlatformName"] = @"iphoneos";
    }
    if ([dtSdk isKindOfClass:[NSString class]] &&
        ([(NSString *)dtSdk hasPrefix:@"macosx"] || [(NSString *)dtSdk hasPrefix:@"MacOSX"])) {
        clean[@"DTSDKName"] = @"iphoneos";
    }
    if ([prin isKindOfClass:[NSString class]] &&
        [(NSString *)prin isEqualToString:@"NSApplication"]) {
        clean[@"NSPrincipalClass"] = @"UIApplication";
    }
    [clean removeObjectForKey:@"LSMinimumSystemVersion"];
    [clean removeObjectForKey:@"LSEnvironment"];
    return clean;
}

static CFPropertyListRef pt_CFPropertyListCreateWithData(CFAllocatorRef allocator, CFDataRef data, CFOptionFlags options, CFPropertyListFormat *format, CFErrorRef *error) {
    CFPropertyListRef plist = CFPropertyListCreateWithData(allocator, data, options, format, error);
    if (plist != NULL && CFGetTypeID(plist) == CFDictionaryGetTypeID()) {
        NSDictionary *dict = (__bridge NSDictionary *)plist;
        id prodName = dict[@"ProductName"];
        BOOL isSysVer = (dict[@"ProductBuildVersion"] != nil &&
                         (([prodName isKindOfClass:[NSString class]] && [(NSString *)prodName isEqualToString:@"macOS"]) ||
                          dict[@"iOSSupportVersion"] != nil));
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
            @"IONVRAM", @"efi-boot-device"
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
            @"model-number", @"regulatory-model-number", @"platform-name",
            @"product-name", @"manufacturer"
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
    if (CFStringCompare(key, CFSTR("platform-name"), 0) == kCFCompareEqualTo) {
        return pt_create_ioreg_cstr_like("iphoneos", orig_val, allocator);
    }
    if (CFStringCompare(key, CFSTR("product-name"), 0) == kCFCompareEqualTo) {
        return pt_create_ioreg_cstr_like(profile->marketing_name, orig_val, allocator);
    }
    if (CFStringCompare(key, CFSTR("manufacturer"), 0) == kCFCompareEqualTo) {
        return pt_create_ioreg_cstr_like("Apple Inc.", orig_val, allocator);
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

extern kern_return_t IORegistryEntryGetPath(mach_port_t entry, const char *plane, char *path);
static kern_return_t pt_IORegistryEntryGetPath(mach_port_t entry, const char *plane, char *path) {
    kern_return_t kr = IORegistryEntryGetPath(entry, plane, path);
    if (kr == KERN_SUCCESS && path != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (strstr(path, "AppleACPIPlatformExpert") != NULL ||
            strstr(path, "AppleSMC") != NULL ||
            strstr(path, "Mac") != NULL) {
            strlcpy(path, "IOService:/AppleARMPE", 512);
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
        NSString *p = (NSString *)prov;
        if ([p isEqualToString:@"AppleACPIPlatformExpert"] ||
            [p isEqualToString:@"AppleSMC"] ||
            [p isEqualToString:@"AppleSMBusController"] ||
            [p isEqualToString:@"IOThunderboltController"] ||
            [p isEqualToString:@"AppleThunderboltHAL"] ||
            [p isEqualToString:@"AppleBacklightDisplay"] ||
            [p isEqualToString:@"IODisplayWrangler"] ||
            [p isEqualToString:@"AGPM"]) {
            return YES;
        }
    }
    id nameMatch = dict[@"IONameMatch"];
    if ([nameMatch isKindOfClass:[NSString class]]) {
        NSString *nm = (NSString *)nameMatch;
        if ([nm containsString:@"Mac"] || [nm containsString:@"AppleSMC"]) {
            return YES;
        }
    } else if ([nameMatch isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)nameMatch) {
            if ([item isKindOfClass:[NSString class]] &&
                ([(NSString *)item containsString:@"Mac"] || [(NSString *)item containsString:@"AppleSMC"])) {
                return YES;
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

extern CFTypeRef IOPSCopyPowerSourcesInfo(void);
static CFTypeRef pt_IOPSCopyPowerSourcesInfo(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
    }
    return IOPSCopyPowerSourcesInfo();
}

extern CFArrayRef IOPSCopyPowerSourcesList(CFTypeRef blob);
static CFArrayRef pt_IOPSCopyPowerSourcesList(CFTypeRef blob) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
    }
    return IOPSCopyPowerSourcesList(blob);
}

extern CFDictionaryRef IOPSGetPowerSourceDescription(CFTypeRef blob, CFTypeRef ps);
static CFDictionaryRef pt_IOPSGetPowerSourceDescription(CFTypeRef blob, CFTypeRef ps) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NULL;
    }
    return IOPSGetPowerSourceDescription(blob, ps);
}

extern CFTypeRef MGCopyAnswer(CFStringRef question, CFDictionaryRef options) __attribute__((weak_import));
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
        strcasestr(name, "playcover") != NULL ||
        strcasestr(name, "macover") != NULL ||
        strcasestr(name, "playtools") != NULL) {
        return YES;
    }
    static const char *const kHiddenKeys[] = {
        "DYLD_INSERT_LIBRARIES",
        "DYLD_LIBRARY_PATH",
        "DYLD_FRAMEWORK_PATH",
        "DYLD_FALLBACK_LIBRARY_PATH",
        "DYLD_FALLBACK_FRAMEWORK_PATH",
        "DYLD_ROOT_PATH",
        "DYLD_SHARED_REGION",
        "DYLD_PRINT_LIBRARIES",
        "DYLD_PRINT_OPTS",
        "DYLD_PRINT_ENV",
        "DYLD_FORCE_FLAT_NAMESPACE",
        "MallocStackLogging",
        "MallocStackLoggingNoCompact",
        "NSZombieEnabled",
        "CLASSIC",
        "OSSignpostLogging",
        "METAL_DEVICE_WRAPPER_TYPE",
        "METAL_DEBUG_ERROR_MODE",
        "__XPC_DYLD_LIBRARY_PATH",
        "__XPC_DYLD_FRAMEWORK_PATH",
        "__CFBundleIdentifier",
        "TERM_PROGRAM",
        "TERM_PROGRAM_VERSION",
        "TERM_SESSION_ID",
        "SHELL",
        "SSH_AUTH_SOCK",
        "SECURITYSESSIONID",
        "LaunchInstanceID",
        "COMMAND_MODE",
        "USE_EXTRA_ANTIJB",
        "USER",
        "LOGNAME",
        "OLDPWD",
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
    BOOL bypass = pt_is_bypass_enabled();
    const void *caller = NULL;
    int is_sys = -1;
    {
        BOOL is_home = (strcmp(name, "HOME") == 0 || strcmp(name, "CFFIXED_USER_HOME") == 0);
        BOOL is_tmpdir = (!is_home && strcmp(name, "TMPDIR") == 0);
        BOOL is_pwd = (!is_home && !is_tmpdir && bypass && strcmp(name, "PWD") == 0);
        BOOL is_path = (!is_home && !is_tmpdir && !is_pwd && bypass && strcmp(name, "PATH") == 0);
        BOOL is_hidden = (!is_home && !is_tmpdir && !is_pwd && !is_path && bypass && pt_is_hidden_env_key(name));
        if (is_home || is_tmpdir || is_pwd || is_path || is_hidden) {
            caller = __builtin_return_address(0);
            is_sys = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
            if (is_sys == 0) {
                if (is_hidden) {
                    PT_DEBUG_TRACE("spoofer", "hid getenv key=%s", name);
                    return NULL;
                }
                if (is_pwd) {
                    PT_DEBUG_TRACE("spoofer", "spoofed getenv PWD");
                    return (char *)"/";
                }
                if (is_path) {
                    PT_DEBUG_TRACE("spoofer", "spoofed getenv PATH");
                    return (char *)"/usr/bin:/bin:/usr/sbin:/sbin";
                }
                if (is_home) {
                    const char *vh = pt_get_virtual_home_cstr();
                    if (vh != NULL) {
                        PT_DEBUG_TRACE("spoofer", "virtualized getenv %s -> %s", name, vh);
                        return (char *)vh;
                    }
                } else if (is_tmpdir) {
                    const char *vt = pt_get_virtual_tmpdir_cstr();
                    if (vt != NULL) {
                        PT_DEBUG_TRACE("spoofer", "virtualized getenv TMPDIR -> %s", vt);
                        return (char *)vt;
                    }
                }
            }
        }
    }
    char *val = getenv(name);
    if (val != NULL && bypass && pt_is_hidden_env_value(val)) {
        if (is_sys < 0) {
            is_sys = pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) ? 1 : 0;
        }
        if (is_sys == 0) {
            return NULL;
        }
    }
    return val;
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

static char ***pt_NSGetEnviron(void) {
    char ***real_envp = _NSGetEnviron();
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire) ||
        real_envp == NULL || *real_envp == NULL ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) ||
        !pt_is_bypass_enabled()) {
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
        char **new_env = (char **)calloc(real_count + 4, sizeof(char *));
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
                if (strcmp(key_ptr, "HOME") == 0) {
                    free(heap_key);
                    if (vh != NULL) {
                        if (!added_home) {
                            char *kv = pt_alloc_env_kv("HOME", vh);
                            if (kv == NULL) {
                                alloc_ok = NO;
                                break;
                            }
                            new_env[out_idx++] = kv;
                            added_home = YES;
                        }
                    } else {
                        char *dup = strdup(snap_dup);
                        if (dup == NULL) {
                            alloc_ok = NO;
                            break;
                        }
                        new_env[out_idx++] = dup;
                        added_home = YES;
                    }
                    continue;
                }
                if (strcmp(key_ptr, "CFFIXED_USER_HOME") == 0) {
                    free(heap_key);
                    if (vh != NULL) {
                        if (!added_cffixed_home) {
                            char *kv = pt_alloc_env_kv("CFFIXED_USER_HOME", vh);
                            if (kv == NULL) {
                                alloc_ok = NO;
                                break;
                            }
                            new_env[out_idx++] = kv;
                            added_cffixed_home = YES;
                        }
                    } else {
                        char *dup = strdup(snap_dup);
                        if (dup == NULL) {
                            alloc_ok = NO;
                            break;
                        }
                        new_env[out_idx++] = dup;
                        added_cffixed_home = YES;
                    }
                    continue;
                }
                if (strcmp(key_ptr, "TMPDIR") == 0) {
                    free(heap_key);
                    if (vt != NULL) {
                        if (!added_tmpdir) {
                            char *kv = pt_alloc_env_kv("TMPDIR", vt);
                            if (kv == NULL) {
                                alloc_ok = NO;
                                break;
                            }
                            new_env[out_idx++] = kv;
                            added_tmpdir = YES;
                        }
                    } else {
                        char *dup = strdup(snap_dup);
                        if (dup == NULL) {
                            alloc_ok = NO;
                            break;
                        }
                        new_env[out_idx++] = dup;
                        added_tmpdir = YES;
                    }
                    continue;
                }
                if (strcmp(key_ptr, "PWD") == 0) {
                    free(heap_key);
                    char *dup = strdup("PWD=/");
                    if (dup == NULL) {
                        alloc_ok = NO;
                        break;
                    }
                    new_env[out_idx++] = dup;
                    continue;
                }
                if (strcmp(key_ptr, "PATH") == 0) {
                    free(heap_key);
                    char *dup = strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin");
                    if (dup == NULL) {
                        alloc_ok = NO;
                        break;
                    }
                    new_env[out_idx++] = dup;
                    continue;
                }
                BOOL hidden = (pt_is_hidden_env_key(key_ptr) || pt_is_hidden_env_value(eq + 1));
                free(heap_key);
                if (hidden) {
                    continue;
                }
                char *dup = strdup(snap_dup);
                if (dup == NULL) {
                    alloc_ok = NO;
                    break;
                }
                new_env[out_idx++] = dup;
            }
            if (alloc_ok && !added_home && vh != NULL) {
                char *kv = pt_alloc_env_kv("HOME", vh);
                if (kv == NULL) {
                    alloc_ok = NO;
                } else {
                    new_env[out_idx++] = kv;
                }
            }
            if (alloc_ok && !added_cffixed_home && vh != NULL) {
                char *kv = pt_alloc_env_kv("CFFIXED_USER_HOME", vh);
                if (kv == NULL) {
                    alloc_ok = NO;
                } else {
                    new_env[out_idx++] = kv;
                }
            }
            if (alloc_ok && !added_tmpdir && vt != NULL) {
                char *kv = pt_alloc_env_kv("TMPDIR", vt);
                if (kv == NULL) {
                    alloc_ok = NO;
                } else {
                    new_env[out_idx++] = kv;
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

__attribute__((visibility("hidden"))) BOOL pt_info_dict_needs_sanitize(NSDictionary *dict) {
    if (![dict isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    if (dict[@"LSMinimumSystemVersion"] != nil ||
        dict[@"LSMinimumSystemVersionByArchitecture"] != nil ||
        dict[@"LSRequiresNativeExecution"] != nil ||
        dict[@"NSSupportsAutomaticTermination"] != nil ||
        dict[@"NSSupportsSuddenTermination"] != nil ||
        dict[@"LSApplicationCategoryType"] != nil) {
        return YES;
    }
    id dtPlatform = dict[@"DTPlatformName"];
    if ([dtPlatform isKindOfClass:[NSString class]]) {
        if ([dtPlatform isEqualToString:@"macosx"] || [dtPlatform isEqualToString:@"maccatalyst"]) {
            return YES;
        }
    }
    id dtSdk = dict[@"DTSDKName"];
    if ([dtSdk isKindOfClass:[NSString class]] &&
        ([dtSdk rangeOfString:@"macosx" options:NSCaseInsensitiveSearch].location != NSNotFound ||
         [dtSdk rangeOfString:@"maccatalyst" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
        return YES;
    }
    id sup = dict[@"CFBundleSupportedPlatforms"];
    if ([sup isKindOfClass:[NSArray class]]) {
        for (id p in (NSArray *)sup) {
            if ([p isKindOfClass:[NSString class]] &&
                ([p isEqualToString:@"MacOSX"] || [p isEqualToString:@"MacCatalyst"])) {
                return YES;
            }
        }
    }
    return NO;
}

__attribute__((visibility("hidden"))) NSDictionary *pt_build_sanitized_info_dict(NSDictionary *dict) {
    NSMutableDictionary *m = [dict mutableCopy];
    [m removeObjectForKey:@"LSMinimumSystemVersion"];
    [m removeObjectForKey:@"LSMinimumSystemVersionByArchitecture"];
    [m removeObjectForKey:@"LSRequiresNativeExecution"];
    [m removeObjectForKey:@"NSSupportsAutomaticTermination"];
    [m removeObjectForKey:@"NSSupportsSuddenTermination"];
    [m removeObjectForKey:@"LSApplicationCategoryType"];

    id dtPlatform = m[@"DTPlatformName"];
    if ([dtPlatform isKindOfClass:[NSString class]] &&
        ([dtPlatform isEqualToString:@"macosx"] || [dtPlatform isEqualToString:@"maccatalyst"])) {
        m[@"DTPlatformName"] = @"iphoneos";
    }
    id dtSdk = m[@"DTSDKName"];
    if ([dtSdk isKindOfClass:[NSString class]]) {
        NSString *sdkStr = (NSString *)dtSdk;
        if ([sdkStr rangeOfString:@"macosx" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            m[@"DTSDKName"] = [sdkStr stringByReplacingOccurrencesOfString:@"macosx"
                                                                withString:@"iphoneos"
                                                                   options:NSCaseInsensitiveSearch
                                                                     range:NSMakeRange(0, sdkStr.length)];
        } else if ([sdkStr rangeOfString:@"maccatalyst" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            m[@"DTSDKName"] = @"iphoneos";
        }
    }
    id sup = m[@"CFBundleSupportedPlatforms"];
    if ([sup isKindOfClass:[NSArray class]]) {
        BOOL hasMac = NO;
        for (id p in (NSArray *)sup) {
            if ([p isKindOfClass:[NSString class]] &&
                ([p isEqualToString:@"MacOSX"] || [p isEqualToString:@"MacCatalyst"])) {
                hasMac = YES;
                break;
            }
        }
        if (hasMac) {
            m[@"CFBundleSupportedPlatforms"] = @[ @"iPhoneOS" ];
        }
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
    NSDictionary *clean = pt_build_sanitized_info_dict(dict);
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
        s_bundle_info_cache = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, &kCFTypeDictionaryValueCallBacks);
    }
    CFDictionaryRef cached = (s_bundle_info_cache != NULL)
        ? (CFDictionaryRef)CFDictionaryGetValue(s_bundle_info_cache, rawDict)
        : NULL;
    os_unfair_lock_unlock(&s_bundle_info_cache_lock);
    if (cached != NULL) {
        return cached;
    }
    NSDictionary *clean = pt_build_sanitized_info_dict(dict);
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
        CFDictionaryRef sanitized = pt_sanitize_info_dict_cached_get(CFBundleGetLocalInfoDictionary(bundle), caller);
        if (sanitized != NULL && CFDictionaryContainsKey(sanitized, key)) {
            return CFDictionaryGetValue(sanitized, key);
        }
        CFDictionaryRef mainSanitized = pt_sanitize_info_dict_cached_get(CFBundleGetInfoDictionary(bundle), caller);
        if (mainSanitized != NULL) {
            NSString *nsKey = (__bridge NSString *)key;
            if ([nsKey isEqualToString:@"LSMinimumSystemVersion"] ||
                [nsKey isEqualToString:@"LSMinimumSystemVersionByArchitecture"] ||
                [nsKey isEqualToString:@"LSRequiresNativeExecution"] ||
                [nsKey isEqualToString:@"NSSupportsAutomaticTermination"] ||
                [nsKey isEqualToString:@"NSSupportsSuddenTermination"] ||
                [nsKey isEqualToString:@"LSApplicationCategoryType"]) {
                return CFDictionaryGetValue(mainSanitized, key);
            }
            if ([nsKey isEqualToString:@"DTPlatformName"] ||
                [nsKey isEqualToString:@"DTSDKName"] ||
                [nsKey isEqualToString:@"CFBundleSupportedPlatforms"]) {
                return CFDictionaryGetValue(mainSanitized, key);
            }
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
    if (name != NULL && namelen > 0 && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
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

static struct passwd *pt_getpwuid(uid_t uid) {
    struct passwd *real_pw = getpwuid(uid);
    if (real_pw != NULL &&
        (uid == getuid() || uid == 501) &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        struct passwd *pw_buf = pt_get_mobile_tls_passwd(real_pw->pw_uid, real_pw->pw_gid);
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
        pt_fill_mobile_passwd_struct(pwd->pw_uid, pwd->pw_gid, pwd, buffer, bufsize);
    }
    return rc;
}

static struct passwd *pt_getpwnam(const char *login) {
    if (login != NULL && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (strcmp(login, "mobile") == 0) {
            struct passwd *pw_buf = pt_get_mobile_tls_passwd(getuid(), getgid());
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
            pt_fill_mobile_passwd_struct(getuid(), getgid(), pwd, buffer, bufsize);
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
            if (s_virtual_private_data_len > 0) {
                const char *sub = (name == _CS_DARWIN_USER_TEMP_DIR) ? "/tmp/" :
                                  (name == _CS_DARWIN_USER_CACHE_DIR) ? "/Library/Caches/" : "/";
                char vpath[PATH_MAX];
                int n = snprintf(vpath, sizeof(vpath), "%s%s", s_virtual_private_data_dir, sub);
                if (n > 0 && (size_t)n < sizeof(vpath)) {
                    if (buf != NULL && len > 0) {
                        strlcpy(buf, vpath, len);
                    }
                    return (size_t)n + 1;
                }
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

static uint64_t pt_compute_spoofed_available_memory(void) {
    uint64_t limit = (pt_get_spoofed_physical_memory() * 65ULL) / 100ULL;
    task_vm_info_data_t vm_info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm_info, &count) == KERN_SUCCESS &&
        count >= TASK_VM_INFO_REV1_COUNT) {
        uint64_t footprint = (uint64_t)vm_info.phys_footprint;
        uint64_t floor_bytes = 128ULL << 20;
        if (limit > footprint + floor_bytes) {
            return limit - footprint;
        }
        return floor_bytes;
    }
    return limit / 2ULL;
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
        const pt_device_profile_t *profile = pt_get_active_device_profile();
        host_basic_info_data_t *info = (host_basic_info_data_t *)host_info_out;
        size_t out_bytes = (size_t)(*host_info_outCnt) * sizeof(integer_t);
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
    return kr;
}

static kern_return_t pt_host_processor_info(host_t host,
                                            processor_flavor_t flavor,
                                            natural_t *out_processor_count,
                                            processor_info_array_t *out_processor_info,
                                            mach_msg_type_number_t *out_processor_infoCnt) {
    kern_return_t kr = host_processor_info(host, flavor, out_processor_count, out_processor_info, out_processor_infoCnt);
    if (kr == KERN_SUCCESS &&
        out_processor_count != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        natural_t spoof_cores = (natural_t)pt_get_active_device_profile()->cores;
        natural_t real_cores = *out_processor_count;
        if (spoof_cores > 0 && real_cores > spoof_cores) {
            if (out_processor_infoCnt != NULL && real_cores > 0 && (*out_processor_infoCnt % real_cores) == 0) {
                *out_processor_infoCnt = (*out_processor_infoCnt / real_cores) * spoof_cores;
            }
            *out_processor_count = spoof_cores;
        }
    }
    return kr;
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
        if (out_bytes >= offsetof(vm_statistics_data_t, wire_count) + sizeof(natural_t)) {
            vm_statistics_data_t *v = (vm_statistics_data_t *)host_info_out;
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
        if (out_bytes >= offsetof(vm_statistics64_data_t, wire_count) + sizeof(natural_t)) {
            vm_statistics64_data_t *v = (vm_statistics64_data_t *)host_info64_out;
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
        }
    }
    return kr;
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
    if (flavor == TASK_VM_INFO) {
        size_t min_bytes = offsetof(task_vm_info_data_t, limit_bytes_remaining) +
                           sizeof(((task_vm_info_data_t *)0)->limit_bytes_remaining);
        if (out_bytes >= min_bytes) {
            task_vm_info_data_t *vm = (task_vm_info_data_t *)task_info_out;
            if (vm->limit_bytes_remaining == 0) {
                vm->limit_bytes_remaining = (mach_vm_size_t)pt_compute_spoofed_available_memory();
            }
        }
    } else if (flavor == TASK_DYLD_INFO && out_bytes >= sizeof(task_dyld_info_data_t)) {
        task_dyld_info_data_t *dyld_info = (task_dyld_info_data_t *)task_info_out;
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
    return kr;
}


DYLD_INTERPOSE(pt_uname, uname)
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
DYLD_INTERPOSE(pt_IOPSCopyPowerSourcesInfo, IOPSCopyPowerSourcesInfo)
DYLD_INTERPOSE(pt_IOPSCopyPowerSourcesList, IOPSCopyPowerSourcesList)
DYLD_INTERPOSE(pt_IOPSGetPowerSourceDescription, IOPSGetPowerSourceDescription)
DYLD_INTERPOSE(pt_MGCopyAnswer, MGCopyAnswer)
DYLD_INTERPOSE(pt_MGCopyMultipleAnswers, MGCopyMultipleAnswers)
DYLD_INTERPOSE(pt_MGGetBoolAnswer, MGGetBoolAnswer)
DYLD_INTERPOSE(pt_MGGetSInt32Answer, MGGetSInt32Answer)
DYLD_INTERPOSE(pt_MGGetStringAnswer, MGGetStringAnswer)
DYLD_INTERPOSE(pt_MGGetProductType, MGGetProductType)
DYLD_INTERPOSE(pt_getenv, getenv)
DYLD_INTERPOSE(pt_NSGetEnviron, _NSGetEnviron)
DYLD_INTERPOSE(pt_gethostname, gethostname)
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
