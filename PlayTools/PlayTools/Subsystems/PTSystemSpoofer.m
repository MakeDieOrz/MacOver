//
//  PTSystemSpoofer.m
//  PlayTools
//

#import "PTSystemSpooferInternal.h"
#import "PTFSInternal.h"
#import "PTDyldInternal.h"

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
static os_unfair_lock s_device_info_lock = OS_UNFAIR_LOCK_INIT;
static char s_uncoerced_device_model[64] = "";
static _Atomic BOOL s_has_uncoerced_device_model = NO;
static char s_early_device_model[64] = "iPad13,8";
static char s_early_oem_id[64] = "J522AP";
static char s_final_device_model[64] = "iPad13,8";
static char s_final_oem_id[64] = "J522AP";
static char s_custom_final_oem_id[64] = "";
static BOOL s_has_custom_final_oem_id = NO;
static _Atomic(const char *) s_active_device_model = "iPad13,8";
static _Atomic(const char *) s_active_oem_id = "J522AP";
static _Atomic BOOL s_reported_ios_override_forced_off = NO;
static pthread_once_t s_pt_early_device_once = PTHREAD_ONCE_INIT;
__attribute__((visibility("hidden"))) pthread_once_t s_pt_device_info_once = PTHREAD_ONCE_INIT;
__attribute__((visibility("hidden"))) _Thread_local BOOL s_tls_initializing_device_info = NO;

#ifndef CPUFAMILY_ARM_TWISTER
#define CPUFAMILY_ARM_TWISTER 0x92fb37c8U
#endif
#ifndef CPUFAMILY_ARM_VORTEX_TEMPEST
#define CPUFAMILY_ARM_VORTEX_TEMPEST 0x07d34b9fU
#endif
#ifndef CPUFAMILY_ARM_LIGHTNING_THUNDER
#define CPUFAMILY_ARM_LIGHTNING_THUNDER 0x462504d2U
#endif
#ifndef CPUFAMILY_ARM_FIRESTORM_ICESTORM
#define CPUFAMILY_ARM_FIRESTORM_ICESTORM 0x1b588bb3U
#endif
#ifndef CPUFAMILY_ARM_BLIZZARD_AVALANCHE
#define CPUFAMILY_ARM_BLIZZARD_AVALANCHE 0xda33d83dU
#endif
#ifndef CPUFAMILY_ARM_EVEREST_SAWTOOTH
#define CPUFAMILY_ARM_EVEREST_SAWTOOTH 0x8765edeaU
#endif
#ifndef CPUFAMILY_ARM_COLL
#define CPUFAMILY_ARM_COLL 0x2876f5b5U
#endif
#ifndef CPUFAMILY_ARM_DONAN
#define CPUFAMILY_ARM_DONAN 0x6f5129acU
#endif
#ifndef CPUFAMILY_ARM_TUPAI
#define CPUFAMILY_ARM_TUPAI 0x204526d0U
#endif
#ifndef CPUFAMILY_ARM_HIDRA
#define CPUFAMILY_ARM_HIDRA 0x1d5a87e8U
#endif
#ifndef CPUFAMILY_ARM_THERA
#define CPUFAMILY_ARM_THERA 0xab345f09U
#endif

static const pt_device_profile_t s_device_profiles[] = {
    { "iPad6,7",    "J98aAP",  "Apple A9X",        "Apple A9X GPU",     2, 2, 0, 4ULL << 30,  CPUFAMILY_ARM_TWISTER,            "RELEASE_ARM64_S8001", "s8001", "iPad Pro (12.9-inch)",                  "ML0F2", "A1584", YES, 2048, 2732, 2.0, 60,  1003, "applegpu_g8s",  12, "G8S"  },
    { "iPad8,6",    "J320xAP", "Apple A12X Bionic","Apple A12X GPU",    8, 4, 4, 4ULL << 30,  CPUFAMILY_ARM_VORTEX_TEMPEST,     "RELEASE_ARM64_T8027", "t8027", "iPad Pro (12.9-inch) (3rd generation)", "MTEL2", "A1876", YES, 2048, 2732, 2.0, 120, 1005, "applegpu_g11g",  7, "G11G" },
    { "iPad13,8",   "J522AP",  "Apple M1",         "Apple M1 GPU",      8, 4, 4, 8ULL << 30,  CPUFAMILY_ARM_FIRESTORM_ICESTORM, "RELEASE_ARM64_T8103", "t8103", "iPad Pro (12.9-inch) (5th generation)", "MHNF3", "A2378", YES, 2048, 2732, 2.0, 120, 1007, "applegpu_g13g",  8, "G13G" },
    { "iPad14,5",   "J620AP",  "Apple M2",         "Apple M2 GPU",      8, 4, 4, 8ULL << 30,  CPUFAMILY_ARM_BLIZZARD_AVALANCHE, "RELEASE_ARM64_T8112", "t8112", "iPad Pro (12.9-inch) (6th generation)", "MNXP3", "A2436", YES, 2048, 2732, 2.0, 120, 1008, "applegpu_g14g", 10, "G14G" },
    { "iPad16,6",   "J720AP",  "Apple M4",         "Apple M4 GPU",      9, 3, 6, 8ULL << 30,  CPUFAMILY_ARM_DONAN,              "RELEASE_ARM64_T8132", "t8132", "iPad Pro 13-inch (M4)",                 "MVX23", "A2925", YES, 2064, 2752, 2.0, 120, 1009, "applegpu_g16g", 10, "G16G" },
    { "iPad17,3",   "J820AP",  "Apple M5",         "Apple M5 GPU",      9, 3, 6, 12ULL << 30, CPUFAMILY_ARM_HIDRA,              "RELEASE_ARM64_T8142", "t8142", "iPad Pro 13-inch (M5)",                 "MD8R4", "A3360", YES, 2064, 2752, 2.0, 120, 1010, "applegpu_g18g", 10, "G18G" },
    { "iPhone12,5", "D431AP",  "Apple A13 Bionic", "Apple A13 GPU",     6, 2, 4, 4ULL << 30,  CPUFAMILY_ARM_LIGHTNING_THUNDER,  "RELEASE_ARM64_T8030", "t8030", "iPhone 11 Pro Max",                     "MWHD2", "A2161", NO,  1242, 2688, 3.0, 60,  1006, "applegpu_g12p",  4, "G12P" },
    { "iPhone14,3", "D64AP",   "Apple A15 Bionic", "Apple A15 GPU",     6, 2, 4, 6ULL << 30,  CPUFAMILY_ARM_BLIZZARD_AVALANCHE, "RELEASE_ARM64_T8110", "t8110", "iPhone 13 Pro Max",                     "MLL63", "A2484", NO,  1284, 2778, 3.0, 120, 1008, "applegpu_g14p",  5, "G14P" },
    { "iPhone15,3", "D74AP",   "Apple A16 Bionic", "Apple A16 GPU",     6, 2, 4, 6ULL << 30,  CPUFAMILY_ARM_EVEREST_SAWTOOTH,   "RELEASE_ARM64_T8120", "t8120", "iPhone 14 Pro Max",                     "MQ8N3", "A2651", NO,  1290, 2796, 3.0, 120, 1008, "applegpu_g15p",  5, "G15P" },
    { "iPhone16,2", "D84AP",   "Apple A17 Pro",    "Apple A17 Pro GPU", 6, 2, 4, 8ULL << 30,  CPUFAMILY_ARM_COLL,               "RELEASE_ARM64_T8130", "t8130", "iPhone 15 Pro Max",                     "MU683", "A2849", NO,  1290, 2796, 3.0, 120, 1009, "applegpu_g16p",  6, "G16P" },
    { "iPhone17,2", "D94AP",   "Apple A18 Pro",    "Apple A18 Pro GPU", 6, 2, 4, 8ULL << 30,  CPUFAMILY_ARM_TUPAI,              "RELEASE_ARM64_T8140", "t8140", "iPhone 16 Pro Max",                     "MYWV3", "A3084", NO,  1320, 2868, 3.0, 120, 1009, "applegpu_g17p",  6, "G17P" },
    { "iPhone18,2", "D94xAP",  "Apple A19 Pro",    "Apple A19 Pro GPU", 6, 2, 4, 12ULL << 30, CPUFAMILY_ARM_THERA,              "RELEASE_ARM64_T8150", "t8150", "iPhone 17 Pro Max",                     "MFY84", "A3257", NO,  1320, 2868, 3.0, 120, 1010, "applegpu_g18p",  6, "G18P" },
};

typedef struct {
    int min_ios_major;
    int max_ios_major;
} pt_device_os_bounds_t;

static const pt_device_os_bounds_t s_device_os_bounds[] = {
    {  9, 16 }, // iPad6,7    (A9X, EOL iPadOS 16.7.x)
    { 12, 18 }, // iPad8,6    (A12X, EOL iPadOS 18.x)
    { 14, 99 }, // iPad13,8   (M1)
    { 16, 99 }, // iPad14,5   (M2)
    { 17, 99 }, // iPad16,6   (M4)
    { 26, 99 }, // iPad17,3   (M5)
    { 13, 99 }, // iPhone12,5 (A13)
    { 15, 99 }, // iPhone14,3 (A15)
    { 16, 99 }, // iPhone15,3 (A16)
    { 17, 99 }, // iPhone16,2 (A17 Pro)
    { 18, 99 }, // iPhone17,2 (A18 Pro)
    { 26, 99 }, // iPhone18,2 (A19 Pro)
};

_Static_assert(sizeof(s_device_os_bounds) / sizeof(s_device_os_bounds[0]) ==
               sizeof(s_device_profiles) / sizeof(s_device_profiles[0]),
               "s_device_os_bounds count mismatch");

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

static const char *pt_coerce_model_for_ios_major(const char *model, int ios_major) {
    const char *base = (model != NULL && model[0] != '\0') ? model : "iPad13,8";
    if (ios_major <= 0) {
        return base;
    }
    BOOL is_iphone = (strncmp(base, "iPhone", 6) == 0);
    int min_major = 0;
    int max_major = 99;
    BOOL matched_bounds = NO;
    size_t count = sizeof(s_device_profiles) / sizeof(s_device_profiles[0]);
    for (size_t i = 0; i < count; i++) {
        if (strcmp(base, s_device_profiles[i].model) == 0) {
            min_major = s_device_os_bounds[i].min_ios_major;
            max_major = s_device_os_bounds[i].max_ios_major;
            matched_bounds = YES;
            break;
        }
    }
    if (!matched_bounds) {
        if (strncmp(base, "iPhone18,", 9) == 0 || strncmp(base, "iPad17,", 7) == 0) {
            min_major = 26;
            max_major = 99;
        } else if (ios_major <= 13) {
            return is_iphone ? "iPhone12,5" : "iPad8,6";
        } else {
            return base;
        }
    }
    if (ios_major >= min_major && ios_major <= max_major) {
        return base;
    }
    if (ios_major < min_major) {
        // Model is newer than target iOS major: choose newest profile of same form factor within bounds.
        for (size_t i = count; i > 0; i--) {
            size_t idx = i - 1U;
            if (s_device_profiles[idx].is_ipad == (!is_iphone) &&
                ios_major >= s_device_os_bounds[idx].min_ios_major &&
                ios_major <= s_device_os_bounds[idx].max_ios_major) {
                return s_device_profiles[idx].model;
            }
        }
        return is_iphone ? "iPhone12,5" : "iPad8,6";
    }
    // Model is EOL (ios_major > max_major): coerce to a current supported model of same form factor.
    if (!is_iphone) {
        if (ios_major >= 14) {
            return "iPad13,8";
        }
        return "iPad8,6";
    }
    if (ios_major >= 18) {
        return "iPhone17,2";
    }
    for (size_t i = count; i > 0; i--) {
        size_t idx = i - 1U;
        if (!s_device_profiles[idx].is_ipad &&
            ios_major >= s_device_os_bounds[idx].min_ios_major &&
            ios_major <= s_device_os_bounds[idx].max_ios_major) {
            return s_device_profiles[idx].model;
        }
    }
    return "iPhone12,5";
}

static int pt_effective_ios_major_for_override(int override_mode) {
    if (override_mode == 2) {
        return 13;
    }
    if (override_mode == 1) {
        return 18;
    }
    pt_ensure_host_kernel_info();
    int host_major = atoi(s_spoofed_ios_version);
    return (host_major > 0) ? host_major : 18;
}

static void pt_init_early_device_info(void) {
    int fd = pt_open_early_settings_plist_fd();
    char parsed_model[64] = {0};
    BOOL has_model = NO;
    int override_mode = 0;
    BOOL safe_or_forced_off = (atomic_load_explicit(&s_reported_ios_override_forced_off, memory_order_acquire) ||
                               pt_is_safe_mode_env_active());
    if (fd >= 0) {
        char raw_model[64] = {0};
        if (pt_read_plist_top_string_from_fd(fd, "iosDeviceModel", raw_model, sizeof(raw_model))) {
            pt_copy_trimmed_ascii(raw_model, parsed_model, sizeof(parsed_model));
            has_model = (parsed_model[0] != '\0');
        }
        char rep_mode[32] = {0};
        if (!safe_or_forced_off &&
            pt_read_plist_top_string_from_fd(fd, "reportedIOSVersion", rep_mode, sizeof(rep_mode))) {
            override_mode = pt_parse_reported_ios_override_mode_cstr(rep_mode);
        }
        close(fd);
    }

    const char *base_model = has_model ? parsed_model : "iPad13,8";
    const char *effective_model = base_model;
    if (!safe_or_forced_off) {
        int eff_ios_major = pt_effective_ios_major_for_override(override_mode);
        effective_model = pt_coerce_model_for_ios_major(base_model, eff_ios_major);
    }

    os_unfair_lock_lock(&s_device_info_lock);
    strlcpy(s_uncoerced_device_model, base_model, sizeof(s_uncoerced_device_model));
    atomic_store_explicit(&s_has_uncoerced_device_model, YES, memory_order_release);
    const pt_device_profile_t *profile = pt_set_cached_device_profile_from_model(
        effective_model,
        s_early_device_model, sizeof(s_early_device_model),
        s_early_oem_id, sizeof(s_early_oem_id));
    atomic_store_explicit(&s_active_device_profile, profile, memory_order_release);
    atomic_store_explicit(&s_active_device_model, profile->model, memory_order_release);
    atomic_store_explicit(&s_active_oem_id, profile->oem_id, memory_order_release);
    os_unfair_lock_unlock(&s_device_info_lock);
}

__attribute__((visibility("hidden"))) void pt_init_device_info(void) {
    pt_enter_internal_scope();
    if (s_tls_early_device_init == 0) {
        s_tls_early_device_init++;
        pthread_once(&s_pt_early_device_once, pt_init_early_device_info);
        s_tls_early_device_init--;
    }

    char early_model_copy[64] = {0};
    char early_oem_copy[64] = {0};
    os_unfair_lock_lock(&s_device_info_lock);
    strlcpy(early_model_copy, s_early_device_model, sizeof(early_model_copy));
    strlcpy(early_oem_copy, s_early_oem_id, sizeof(early_oem_copy));
    os_unfair_lock_unlock(&s_device_info_lock);

    char raw_cfg_model[64] = {0};
    char settings_model[64] = {0};
    char settings_oem[64] = {0};
    BOOL prev_tls = s_tls_initializing_device_info;
    s_tls_initializing_device_info = YES;
    @autoreleasepool {
        PlaySettings *ps = [PlaySettings shared];
        NSString *rawCfg = [ps rawConfiguredDeviceModel];
        const char *rm = [rawCfg UTF8String];
        if (rm != NULL && rm[0] != '\0') {
            pt_copy_trimmed_ascii(rm, raw_cfg_model, sizeof(raw_cfg_model));
        }
        NSString *model = [ps deviceModel];
        const char *m = [model UTF8String];
        if (m != NULL && m[0] != '\0') {
            pt_copy_trimmed_ascii(m, settings_model, sizeof(settings_model));
        } else {
            NSString *oem = [ps oemID];
            const char *o = [oem UTF8String];
            if (o != NULL && o[0] != '\0') {
                strlcpy(settings_oem, o, sizeof(settings_oem));
            }
        }
    }
    s_tls_initializing_device_info = prev_tls;

    int eff_ios_major = 0;
    BOOL safe_or_forced_off = (atomic_load_explicit(&s_reported_ios_override_forced_off, memory_order_acquire) ||
                               pt_is_safe_mode_env_active());
    if (!safe_or_forced_off) {
        const char *eff_ver = pt_get_spoofed_ios_version_cstr();
        eff_ios_major = (eff_ver != NULL) ? atoi(eff_ver) : 0;
    }

    os_unfair_lock_lock(&s_device_info_lock);
    if (raw_cfg_model[0] != '\0') {
        strlcpy(s_uncoerced_device_model, raw_cfg_model, sizeof(s_uncoerced_device_model));
        atomic_store_explicit(&s_has_uncoerced_device_model, YES, memory_order_release);
    }
    strlcpy(s_final_device_model, early_model_copy, sizeof(s_final_device_model));
    strlcpy(s_final_oem_id, early_oem_copy, sizeof(s_final_oem_id));
    const pt_device_profile_t *final_profile = pt_device_profile_for_model(s_final_device_model);
    const char *published_model = final_profile->model;
    const char *published_oem = final_profile->oem_id;

    if (settings_model[0] != '\0') {
        const char *eff_m = settings_model;
        if (safe_or_forced_off &&
            atomic_load_explicit(&s_has_uncoerced_device_model, memory_order_acquire) &&
            s_uncoerced_device_model[0] != '\0') {
            eff_m = s_uncoerced_device_model;
        } else if (!safe_or_forced_off && eff_ios_major > 0) {
            eff_m = pt_coerce_model_for_ios_major(eff_m, eff_ios_major);
        }
        final_profile = pt_set_cached_device_profile_from_model(
            eff_m,
            s_final_device_model, sizeof(s_final_device_model),
            s_final_oem_id, sizeof(s_final_oem_id));
        published_model = final_profile->model;
        published_oem = final_profile->oem_id;
    } else if (settings_oem[0] != '\0') {
        strlcpy(s_final_oem_id, settings_oem, sizeof(s_final_oem_id));
        if (!s_has_custom_final_oem_id) {
            strlcpy(s_custom_final_oem_id, settings_oem, sizeof(s_custom_final_oem_id));
            s_has_custom_final_oem_id = YES;
        }
        published_oem = s_custom_final_oem_id;
    }

    atomic_store_explicit(&s_active_device_profile, final_profile, memory_order_release);
    atomic_store_explicit(&s_active_device_model, published_model, memory_order_release);
    atomic_store_explicit(&s_active_oem_id, published_oem, memory_order_release);
    atomic_store_explicit(&s_pt_device_info_ready, YES, memory_order_release);
    os_unfair_lock_unlock(&s_device_info_lock);
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

__attribute__((visibility("hidden"))) const pt_device_profile_t *pt_get_active_device_profile(void) {
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



__attribute__((visibility("hidden"))) int pt_write_sysctl_string(const char *value, void *oldp, size_t *oldlenp) {
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

__attribute__((visibility("hidden"))) int pt_write_sysctl_int(int value, void *oldp, size_t *oldlenp) {
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

__attribute__((visibility("hidden"))) int pt_write_sysctl_uint64(void *oldp, size_t *oldlenp, void *newp, uint64_t val) {
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
    if (*oldlenp < sizeof(uint64_t)) {
        *oldlenp = sizeof(uint64_t);
        errno = ENOMEM;
        return -1;
    }
    memcpy(oldp, &val, sizeof(uint64_t));
    *oldlenp = sizeof(uint64_t);
    return 0;
}

__attribute__((visibility("hidden"))) int pt_write_sysctl_uint64_array(void *oldp,
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


__attribute__((visibility("hidden"))) CFDataRef pt_create_compatible_cfdata(CFAllocatorRef allocator) {
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

__attribute__((visibility("hidden"))) char s_real_kern_release[64] = "24.3.0";
static char s_spoofed_kern_version_prefix[256] = "Darwin Kernel Version 24.3.0: Sat Jan 11 02:18:34 PST 2025; root:xnu-11215.82.3~1";
static char s_compat18_kern_version_prefix[256] = "Darwin Kernel Version 24.3.0: Sat Jan 11 02:18:34 PST 2025; root:xnu-11215.61.2~1";
static char s_compat13_kern_version_prefix[256] = "Darwin Kernel Version 19.6.0: Mon Jul  6 21:14:08 PDT 2020; root:xnu-6153.121.2~1";
__attribute__((visibility("hidden"))) char s_spoofed_osversion[64] = "22D63";
__attribute__((visibility("hidden"))) char s_spoofed_ios_version[32] = "18.3";
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

__attribute__((visibility("hidden"))) void pt_fallback_ios_version_for_kern_major(int kern_major, char *out_buf, size_t out_size) {
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
        case 26: strlcpy(out_buf, "26.0", out_size); break;
        default:
            if (kern_major >= 27) {
                snprintf(out_buf, out_size, "%d.0", kern_major);
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
    if (ios_major == 26) {
        *out_expected_prefix = 23;
        return YES;
    }
    if (ios_major >= 27 && ios_major <= 99) {
        *out_expected_prefix = ios_major - 1;
        return YES;
    }
    return NO;
}

__attribute__((visibility("hidden"))) BOOL pt_sanitize_ios_build_version_with_kern_major(const char *build_cstr,
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
        expected_prefix = (kern_major >= 27) ? (kern_major - 1) : (kern_major - 2);
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

__attribute__((visibility("hidden"))) void pt_ensure_host_kernel_info(void) {
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
    os_unfair_lock_lock(&s_device_info_lock);
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
    os_unfair_lock_unlock(&s_device_info_lock);
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

static BOOL pt_is_availability_app_caller_fp(const void *caller, const void *frame_ptr) {
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire) || pt_is_in_internal_scope()) {
        return NO;
    }
    const void *scaller = pt_strip_return_addr((uintptr_t)caller);
    if (!pt_is_system_or_playtools_caller(scaller)) {
        return YES;
    }
    const char *img = (scaller != NULL) ? dyld_image_path_containing_address(scaller) : NULL;
    if (img == NULL || strstr(img, "libswiftCore") == NULL) {
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
        const void *slr = pt_strip_return_addr(frame[1]);
        if (slr != NULL) {
            if (!pt_is_system_or_playtools_caller(slr)) {
                return YES;
            }
            if (pt_is_address_in_playtools(slr)) {
                if (next_fp <= fp) {
                    break;
                }
                fp = next_fp;
                continue;
            }
            const char *pimg = dyld_image_path_containing_address(slr);
            if (pimg == NULL || strstr(pimg, "libswiftCore") == NULL) {
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
BOOL pt_is_availability_app_caller(const void *caller) {
    return pt_is_availability_app_caller_fp(caller, __builtin_frame_address(0));
}

static uint32_t pt_parse_packed_os_version_cstr(const char *ver_cstr) {
    if (ver_cstr == NULL || ver_cstr[0] == '\0') {
        return 0;
    }
    int maj = 0, min = 0, pat = 0;
    if (sscanf(ver_cstr, "%d.%d.%d", &maj, &min, &pat) < 1 || maj <= 0 || maj > 255) {
        return 0;
    }
    if (min < 0 || min > 255) min = 0;
    if (pat < 0 || pat > 255) pat = 0;
    return ((uint32_t)maj << 16) | ((uint32_t)min << 8) | (uint32_t)pat;
}

__attribute__((visibility("hidden")))
uint32_t pt_get_compat_version_clamp(void) {
    pt_ensure_host_kernel_info();
    switch (pt_active_reported_ios_override()) {
        case PT_REPORTED_IOS_OVERRIDE_13_7:
            return 0x000D0700U;
        case PT_REPORTED_IOS_OVERRIDE_18_3:
            return 0x00120300U;
        default:
            return 0U;
    }
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
    if (pt_is_availability_app_caller_fp(caller, fp)) {
        pt_ensure_host_kernel_info();
        uint32_t spoofed_ver = pt_get_compat_version_clamp();
        if (spoofed_ver == 0) {
            spoofed_ver = pt_parse_packed_os_version_cstr(pt_get_spoofed_ios_version_cstr());
        }
        for (uint32_t i = 0; i < count; i++) {
            if (versions[i].platform == 2U) { // PLATFORM_IOS
                if (spoofed_ver != 0) {
                    return (spoofed_ver >= versions[i].version);
                }
                pt_dyld_build_version_t ios_only = versions[i];
                return (pt_orig_availability_version_check != NULL)
                    ? pt_orig_availability_version_check(1U, &ios_only)
                    : true;
            }
        }
        // On real iOS, queries containing only non-iOS platforms (e.g. PLATFORM_MACOS / PLATFORM_MACCATALYST) return true.
        return true;
    }
    return (pt_orig_availability_version_check != NULL)
        ? pt_orig_availability_version_check(count, versions)
        : true;
}

__attribute__((visibility("hidden")))
int32_t pt_isPlatformVersionAtLeast(uint32_t platform, uint32_t major, uint32_t minor, uint32_t subminor) {
    if (atomic_load_explicit(&s_libsystem_ready, memory_order_acquire) &&
        pt_is_bypass_enabled() &&
        pt_is_availability_app_caller_fp(__builtin_return_address(0), __builtin_frame_address(0))) {
        if (platform == 1U || platform == 6U) { // PLATFORM_MACOS / PLATFORM_MACCATALYST
            return 0;
        }
        if (platform == 2U) { // PLATFORM_IOS
            pt_ensure_host_kernel_info();
            uint32_t spoofed_ver = pt_get_compat_version_clamp();
            if (spoofed_ver == 0) {
                spoofed_ver = pt_parse_packed_os_version_cstr(pt_get_spoofed_ios_version_cstr());
            }
            if (spoofed_ver != 0 && major <= 255U && minor <= 255U && subminor <= 255U) {
                uint32_t target = (major << 16) | (minor << 8) | subminor;
                return (spoofed_ver >= target) ? 1 : 0;
            }
            if (spoofed_ver == 0 && major <= 255U && minor <= 255U && subminor <= 255U) {
                pt_dyld_build_version_t v = { 2U, (major << 16) | (minor << 8) | subminor };
                if (pt_orig_availability_version_check != NULL) {
                    return pt_orig_availability_version_check(1U, &v) ? 1 : 0;
                }
            }
            return 0;
        }
    }
    typedef int32_t (*IsPlatVerFn)(uint32_t, uint32_t, uint32_t, uint32_t);
    static IsPlatVerFn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (IsPlatVerFn)dlsym(RTLD_NEXT, "__isPlatformVersionAtLeast");
    });
    if (s_orig != NULL) {
        return s_orig(platform, major, minor, subminor);
    }
    return 0;
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

__attribute__((visibility("hidden"))) const char *pt_get_effective_kern_release(void) {
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

__attribute__((visibility("hidden"))) void pt_format_kernel_version(const pt_device_profile_t *profile, char *buf, size_t buf_size) {
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

PT_DLSYM_ONLY("__isPlatformVersionAtLeast", pt_isPlatformVersionAtLeast)
PT_INTERPOSE(pt_uname, uname)
PT_INTERPOSE_NAMED(pt_availability_version_check, pt_orig_availability_version_check, "_availability_version_check")
