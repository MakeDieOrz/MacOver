//
//  PTInterposeRegistry.h
//  PlayTools
//
//  Unified DYLD_INTERPOSE + dlsym single-point registration macros and
//  compile-time Mach-O __pt_dlsym section lookup table.
//

#ifndef PTInterposeRegistry_h
#define PTInterposeRegistry_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *(*pt_dlsym_resolver_fn)(void);

enum {
    PT_DLSYM_FLAG_NONE = 0U,
    PT_DLSYM_FLAG_WEAK_GUARD = 1U << 0,
    PT_DLSYM_FLAG_HIDE_IN_COMPAT13_7 = 1U << 1,
    PT_DLSYM_FLAG_DYNAMIC_RESOLVER = 1U << 2,
};

typedef struct __attribute__((aligned(8))) {
    const char *symbol;
    const void *target;
    const void *guard;
    uintptr_t flags;
} pt_dlsym_entry_t;

_Static_assert(sizeof(pt_dlsym_entry_t) == 32U, "pt_dlsym_entry_t must be 32 bytes");

typedef struct {
    const pt_dlsym_entry_t *entries;
    size_t count;
    size_t duplicate_count;
    uint16_t *slots;
    size_t slot_capacity;
} pt_dlsym_index_t;

#define PT_DLSYM_HIDDEN_SENTINEL ((void *)(uintptr_t)-1)

#define PT_REG_CAT_IMPL(a, b) a##b
#define PT_REG_CAT(a, b) PT_REG_CAT_IMPL(a, b)

#define PT_INTERPOSE_RAW(_replacement, _replacee)                                                                      \
    __attribute__((used)) static struct {                                                                              \
        const void *replacement;                                                                                       \
        const void *replacee;                                                                                          \
    } PT_REG_CAT(_pt_interpose_, __COUNTER__) __attribute__((section("__DATA,__interpose"))) = {                       \
        (const void *)(unsigned long)&(_replacement), (const void *)(unsigned long)&(_replacee)};

#define PT_DLSYM_REGISTER_RAW(_sym_str, _target_expr, _guard_expr, _flags)                                             \
    __attribute__((used)) static pt_dlsym_entry_t PT_REG_CAT(_pt_dlsym_, __COUNTER__)                                  \
        __attribute__((section("__DATA,__pt_dlsym"), aligned(8))) = {(_sym_str), (_target_expr), (_guard_expr),        \
                                                                     (uintptr_t)(_flags)};

#define PT_INTERPOSE(_replacement, _replacee)                                                                          \
    PT_INTERPOSE_RAW(_replacement, _replacee)                                                                          \
    PT_DLSYM_REGISTER_RAW(#_replacee, (const void *)(unsigned long)&(_replacement), NULL, PT_DLSYM_FLAG_NONE)

#define PT_INTERPOSE_NAMED(_replacement, _replacee, _sym_str)                                                          \
    PT_INTERPOSE_RAW(_replacement, _replacee)                                                                          \
    PT_DLSYM_REGISTER_RAW((_sym_str), (const void *)(unsigned long)&(_replacement), NULL, PT_DLSYM_FLAG_NONE)

#define PT_INTERPOSE_WEAK(_replacement, _replacee)                                                                     \
    PT_INTERPOSE_RAW(_replacement, _replacee)                                                                          \
    PT_DLSYM_REGISTER_RAW(#_replacee, (const void *)(unsigned long)&(_replacement),                                    \
                          (const void *)(unsigned long)&(_replacee), PT_DLSYM_FLAG_WEAK_GUARD)

#define PT_INTERPOSE_WEAK_NAMED(_replacement, _replacee, _sym_str)                                                     \
    PT_INTERPOSE_RAW(_replacement, _replacee)                                                                          \
    PT_DLSYM_REGISTER_RAW((_sym_str), (const void *)(unsigned long)&(_replacement),                                    \
                          (const void *)(unsigned long)&(_replacee), PT_DLSYM_FLAG_WEAK_GUARD)

#define PT_INTERPOSE_WEAK_NAMED_FLAGS(_replacement, _replacee, _sym_str, _extra_flags)                                 \
    PT_INTERPOSE_RAW(_replacement, _replacee)                                                                          \
    PT_DLSYM_REGISTER_RAW((_sym_str), (const void *)(unsigned long)&(_replacement),                                    \
                          (const void *)(unsigned long)&(_replacee), PT_DLSYM_FLAG_WEAK_GUARD | (_extra_flags))

#define PT_INTERPOSE_ONLY(_replacement, _replacee) PT_INTERPOSE_RAW(_replacement, _replacee)

#define PT_DLSYM_ONLY(_sym_str, _replacement)                                                                          \
    PT_DLSYM_REGISTER_RAW((_sym_str), (const void *)(unsigned long)&(_replacement), NULL, PT_DLSYM_FLAG_NONE)

#define PT_DLSYM_DYNAMIC(_sym_str, _resolver_fn)                                                                       \
    PT_DLSYM_REGISTER_RAW((_sym_str), (const void *)(unsigned long)&(_resolver_fn), NULL,                              \
                          PT_DLSYM_FLAG_DYNAMIC_RESOLVER)

__attribute__((visibility("hidden"))) void *pt_interpose_registry_lookup(const char *symbol, bool compat13_7_active);
__attribute__((visibility("hidden"))) const char *pt_interpose_registry_symbol_for_target(const void *stripped_target);
__attribute__((visibility("hidden"))) size_t pt_interpose_registry_count(void);
__attribute__((visibility("hidden"))) size_t pt_interpose_registry_duplicate_count(void);

__attribute__((visibility("hidden"))) size_t pt_dlsym_index_build(pt_dlsym_index_t *index,
                                                                  const pt_dlsym_entry_t *entries, size_t count,
                                                                  uint16_t *slot_storage, size_t slot_capacity);
__attribute__((visibility("hidden"))) void *pt_dlsym_index_lookup(const pt_dlsym_index_t *index, const char *symbol,
                                                                  bool compat13_7_active);

#ifdef __cplusplus
}
#endif

#endif /* PTInterposeRegistry_h */
