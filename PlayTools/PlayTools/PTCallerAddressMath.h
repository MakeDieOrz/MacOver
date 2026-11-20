//
//  PTCallerAddressMath.h
//  PlayTools
//

#ifndef PTCallerAddressMath_h
#define PTCallerAddressMath_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

enum {
    PT_CALLER_UNKNOWN = 0,
    PT_CALLER_APP = 1,
    PT_CALLER_SYS_NON_WRAPPER = 2,
    PT_CALLER_PLAYTOOLS = 3,
    PT_CALLER_SYS_WRAPPER = 4
};

#define PT_CALLER_ADDR_CACHE_SIZE 1024U
#define PT_WRAPPER_CACHE_SIZE 1024U
#define PT_MAX_CALLER_UNWIND_DEPTH 4
#define PT_CALLER_ADDR_TAG_MASK 3ULL
#define PT_CALLER_ADDR_MASK (~3ULL)
#define PT_USER_ADDR_STRIP_MASK 0x0000ffffffffffffULL
#define PT_USER_ADDR_LVA_STRIP_MASK 0x000fffffffffffffULL
#define PT_USER_ADDR_MIN 0x100000000ULL
#define PT_KERNEL_ADDR_MIN 0xFFFF000000000000ULL

static inline bool pt_caller_addr_is_cacheable_aligned(uint64_t addr) {
    return (addr & PT_CALLER_ADDR_TAG_MASK) == 0ULL && addr != 0ULL;
}

static inline size_t pt_caller_addr_cache_slot(uint64_t addr) {
    return (size_t)(((addr >> 2) ^ (addr >> 14)) & (uint64_t)(PT_CALLER_ADDR_CACHE_SIZE - 1U));
}

static inline bool pt_caller_addr_try_pack(uint64_t addr, uint8_t kind, uint64_t *out_packed) {
    if (!pt_caller_addr_is_cacheable_aligned(addr) || kind < PT_CALLER_APP || kind > PT_CALLER_SYS_WRAPPER) {
        return false;
    }
    uint64_t packed = addr | ((uint64_t)(kind - 1U) & PT_CALLER_ADDR_TAG_MASK);
    if (out_packed != NULL) {
        *out_packed = packed;
    }
    return true;
}

static inline uint64_t pt_caller_addr_pack(uint64_t addr, uint8_t kind) {
    uint64_t packed = 0ULL;
    if (!pt_caller_addr_try_pack(addr, kind, &packed)) {
        return 0ULL;
    }
    return packed;
}

static inline bool pt_caller_addr_cache_match(uint64_t entry, uint64_t addr, uint8_t *out_kind) {
    if (entry == 0ULL || !pt_caller_addr_is_cacheable_aligned(addr)) {
        return false;
    }
    if ((entry & PT_CALLER_ADDR_MASK) != addr) {
        return false;
    }
    if (out_kind != NULL) {
        *out_kind = (uint8_t)((entry & PT_CALLER_ADDR_TAG_MASK) + 1U);
    }
    return true;
}

uint64_t pt_active_user_addr_strip_mask(void);
void pt_configure_user_va_bits(uint8_t va_bits);
void pt_init_user_va_bits_from_kernel(void);

static inline uintptr_t pt_strip_high_bits_addr_with_width(uintptr_t raw_addr, uint8_t va_bits) {
    uint64_t mask = (va_bits >= 52U) ? PT_USER_ADDR_LVA_STRIP_MASK : PT_USER_ADDR_STRIP_MASK;
    return (uintptr_t)((uint64_t)raw_addr & mask);
}

static inline uintptr_t pt_strip_high_bits_addr(uintptr_t raw_addr) {
    return raw_addr & (uintptr_t)pt_active_user_addr_strip_mask();
}

static inline const void *pt_strip_return_addr(uintptr_t raw_lr) {
#if __has_include(<ptrauth.h>)
    uintptr_t stripped = (uintptr_t)ptrauth_strip((const void *)raw_lr, ptrauth_key_return_address);
#else
    uintptr_t stripped = (uintptr_t)__builtin_extract_return_addr((void *)raw_lr);
#endif
#if !__has_feature(ptrauth_calls)
    stripped &= (uintptr_t)pt_active_user_addr_strip_mask();
#endif
    return (const void *)stripped;
}

static inline bool pt_is_valid_user_addr(uintptr_t raw) {
    if (raw == 0U || raw == (uintptr_t)-1) {
        return false;
    }
    if ((uint64_t)raw >= PT_KERNEL_ADDR_MIN) {
        return false;
    }
    uintptr_t addr = pt_strip_high_bits_addr(raw);
    return (uint64_t)addr >= PT_USER_ADDR_MIN;
}

static inline uint64_t pt_caller_compound_key(uintptr_t lr, uintptr_t fp1_lr) {
    uint64_t a = (uint64_t)pt_strip_high_bits_addr(lr);
    uint64_t b = (uint64_t)pt_strip_high_bits_addr(fp1_lr);
    uint64_t mixed = (a ^ ((b << 7) | (b >> 57))) & PT_CALLER_ADDR_MASK;
    return (mixed == 0ULL) ? 4ULL : mixed;
}

static inline uint64_t pt_caller_compound_key3(uintptr_t lr, uintptr_t fp1_lr, uintptr_t fp2_lr) {
    uint64_t a = (uint64_t)pt_strip_high_bits_addr(lr);
    uint64_t b = (uint64_t)pt_strip_high_bits_addr(fp1_lr);
    uint64_t c = (uint64_t)pt_strip_high_bits_addr(fp2_lr);
    uint64_t mixed = (a ^ ((b << 7) | (b >> 57)) ^ ((c << 13) | (c >> 51))) & PT_CALLER_ADDR_MASK;
    return (mixed == 0ULL) ? 4ULL : mixed;
}

static inline size_t pt_wrapper_cache_slot(uint64_t compound_key) {
    return (size_t)(((compound_key >> 2) ^ (compound_key >> 14) ^ (compound_key >> 26)) &
                    (uint64_t)(PT_WRAPPER_CACHE_SIZE - 1U));
}

static inline uint64_t pt_wrapper_cache_pack(uint64_t compound_key, bool is_sys_or_playtools) {
    uint64_t key = compound_key & PT_CALLER_ADDR_MASK;
    if (key == 0ULL) {
        key = 4ULL;
    }
    return key | (is_sys_or_playtools ? 2ULL : 1ULL);
}

static inline bool pt_wrapper_cache_match(uint64_t entry, uint64_t compound_key, bool *out_is_sys_or_playtools) {
    if (entry == 0ULL) {
        return false;
    }
    uint64_t tag = entry & PT_CALLER_ADDR_TAG_MASK;
    if (tag != 1ULL && tag != 2ULL) {
        return false;
    }
    uint64_t expected_key = compound_key & PT_CALLER_ADDR_MASK;
    if (expected_key == 0ULL) {
        expected_key = 4ULL;
    }
    if ((entry & PT_CALLER_ADDR_MASK) != expected_key) {
        return false;
    }
    if (out_is_sys_or_playtools != NULL) {
        *out_is_sys_or_playtools = (tag == 2ULL);
    }
    return true;
}

bool pt_is_wrapper_library_path(const char *fname);
uint8_t pt_classify_caller_image_path(const char *fname, bool *out_cacheable);
bool pt_is_nonsensitive_app_or_tmp_path(const char *norm_path, const char *bundle_dir, size_t bundle_len,
                                        const char *data_dir, size_t data_len);

void pt_enter_internal_scope(void);
void pt_leave_internal_scope(void);
bool pt_is_in_internal_scope(void);

bool pt_classify_bounded_frame_kinds(const uint8_t *frame_kinds, size_t count, bool initial_seen_wrapper);

#ifdef __cplusplus
}
#endif

#endif /* PTCallerAddressMath_h */
