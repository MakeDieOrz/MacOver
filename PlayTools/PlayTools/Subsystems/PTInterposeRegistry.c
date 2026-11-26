//
//  PTInterposeRegistry.c
//  PlayTools
//
//  Unified DYLD_INTERPOSE + dlsym Mach-O section index and O(1) lookup.
//

#include "PTInterposeRegistry.h"

#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <string.h>

extern const struct mach_header *dyld_image_header_containing_address(const void *addr);

#define PT_DLSYM_STATIC_SLOT_CAP 4096U

static pt_dlsym_index_t s_dlsym_index;
static uint16_t s_dlsym_slots[PT_DLSYM_STATIC_SLOT_CAP];
static pthread_once_t s_dlsym_once = PTHREAD_ONCE_INIT;

static inline const void *pt_dlsym_strip_ptr(const void *p) {
#if defined(__arm64__) || defined(__aarch64__)
    return (const void *)((uintptr_t)p & 0x0000FFFFFFFFFFFFULL);
#else
    return p;
#endif
}

static uint64_t pt_dlsym_fnv1a(const char *s) {
    uint64_t h = 14695981039346656037ULL;
    for (const unsigned char *p = (const unsigned char *)s; *p != '\0'; p++) {
        h ^= (uint64_t)(*p);
        h *= 1099511628211ULL;
    }
    return h;
}

static bool pt_is_power_of_two(size_t v) {
    return v != 0 && (v & (v - 1U)) == 0;
}

static void *pt_dlsym_eval_entry(const pt_dlsym_entry_t *entry, bool compat13_7_active) {
    if (entry == NULL) {
        return NULL;
    }
    if ((entry->flags & PT_DLSYM_FLAG_HIDE_IN_COMPAT13_7) != 0U && compat13_7_active) {
        return PT_DLSYM_HIDDEN_SENTINEL;
    }
    if ((entry->flags & PT_DLSYM_FLAG_WEAK_GUARD) != 0U && entry->guard == NULL) {
        return NULL;
    }
    if ((entry->flags & PT_DLSYM_FLAG_DYNAMIC_RESOLVER) != 0U) {
        pt_dlsym_resolver_fn resolver = (pt_dlsym_resolver_fn)(uintptr_t)entry->target;
        return (resolver != NULL) ? resolver() : NULL;
    }
    return (void *)(uintptr_t)entry->target;
}

size_t pt_dlsym_index_build(pt_dlsym_index_t *index, const pt_dlsym_entry_t *entries, size_t count,
                            uint16_t *slot_storage, size_t slot_capacity) {
    if (index == NULL) {
        return 0;
    }
    memset(index, 0, sizeof(*index));
    index->entries = entries;
    index->count = count;

    if (entries == NULL || count == 0) {
        return 0;
    }

    bool use_hash = (slot_storage != NULL && pt_is_power_of_two(slot_capacity) && count < (size_t)UINT16_MAX &&
                     count * 2U <= slot_capacity);
    if (use_hash) {
        memset(slot_storage, 0, slot_capacity * sizeof(uint16_t));
        index->slots = slot_storage;
        index->slot_capacity = slot_capacity;
    }

    size_t duplicates = 0;
    size_t mask = use_hash ? (slot_capacity - 1U) : 0U;

    for (size_t i = 0; i < count; i++) {
        const char *sym = entries[i].symbol;
        if (sym == NULL || sym[0] == '\0') {
            continue;
        }
        if (use_hash) {
            size_t slot = (size_t)(pt_dlsym_fnv1a(sym) & mask);
            bool dup = false;
            while (slot_storage[slot] != 0U) {
                const pt_dlsym_entry_t *existing = &entries[(size_t)slot_storage[slot] - 1U];
                if (existing->symbol != NULL && strcmp(existing->symbol, sym) == 0) {
                    dup = true;
                    break;
                }
                slot = (slot + 1U) & mask;
            }
            if (dup) {
                duplicates++;
            } else {
                slot_storage[slot] = (uint16_t)(i + 1U);
            }
        } else {
            for (size_t j = 0; j < i; j++) {
                if (entries[j].symbol != NULL && strcmp(entries[j].symbol, sym) == 0) {
                    duplicates++;
                    break;
                }
            }
        }
    }

    index->duplicate_count = duplicates;
    return duplicates;
}

void *pt_dlsym_index_lookup(const pt_dlsym_index_t *index, const char *symbol, bool compat13_7_active) {
    if (index == NULL || index->entries == NULL || index->count == 0 || symbol == NULL || symbol[0] == '\0') {
        return NULL;
    }

    if (index->slots != NULL && pt_is_power_of_two(index->slot_capacity)) {
        size_t mask = index->slot_capacity - 1U;
        size_t slot = (size_t)(pt_dlsym_fnv1a(symbol) & mask);
        for (size_t probe = 0; probe < index->slot_capacity; probe++) {
            uint16_t idx_plus_one = index->slots[slot];
            if (idx_plus_one == 0U) {
                return NULL;
            }
            const pt_dlsym_entry_t *entry = &index->entries[(size_t)idx_plus_one - 1U];
            if (entry->symbol != NULL && strcmp(entry->symbol, symbol) == 0) {
                return pt_dlsym_eval_entry(entry, compat13_7_active);
            }
            slot = (slot + 1U) & mask;
        }
        return NULL;
    }

    for (size_t i = 0; i < index->count; i++) {
        const pt_dlsym_entry_t *entry = &index->entries[i];
        if (entry->symbol != NULL && strcmp(entry->symbol, symbol) == 0) {
            return pt_dlsym_eval_entry(entry, compat13_7_active);
        }
    }
    return NULL;
}

static void pt_interpose_registry_init_once(void) {
    const struct mach_header_64 *mh = (const struct mach_header_64 *)dyld_image_header_containing_address(
        (const void *)&pt_interpose_registry_init_once);
    if (mh == NULL) {
        return;
    }
    unsigned long size = 0;
    uint8_t *sec = getsectiondata(mh, "__DATA", "__pt_dlsym", &size);
    if (sec == NULL) {
        sec = getsectiondata(mh, "__DATA_CONST", "__pt_dlsym", &size);
    }
    if (sec != NULL && size >= sizeof(pt_dlsym_entry_t)) {
        size_t count = size / sizeof(pt_dlsym_entry_t);
        (void)pt_dlsym_index_build(&s_dlsym_index, (const pt_dlsym_entry_t *)sec, count, s_dlsym_slots,
                                   PT_DLSYM_STATIC_SLOT_CAP);
    }
}

void *pt_interpose_registry_lookup(const char *symbol, bool compat13_7_active) {
    pthread_once(&s_dlsym_once, pt_interpose_registry_init_once);
    return pt_dlsym_index_lookup(&s_dlsym_index, symbol, compat13_7_active);
}

const char *pt_interpose_registry_symbol_for_target(const void *stripped_target) {
    if (stripped_target == NULL) {
        return NULL;
    }
    const void *needle = pt_dlsym_strip_ptr(stripped_target);
    pthread_once(&s_dlsym_once, pt_interpose_registry_init_once);
    if (s_dlsym_index.entries == NULL || s_dlsym_index.count == 0) {
        return NULL;
    }
    for (size_t i = 0; i < s_dlsym_index.count; i++) {
        const pt_dlsym_entry_t *entry = &s_dlsym_index.entries[i];
        if ((entry->flags & PT_DLSYM_FLAG_DYNAMIC_RESOLVER) != 0U) {
            continue;
        }
        if (entry->symbol != NULL && entry->target != NULL &&
            (entry->target == stripped_target || pt_dlsym_strip_ptr(entry->target) == needle)) {
            return entry->symbol;
        }
    }
    return NULL;
}

size_t pt_interpose_registry_count(void) {
    pthread_once(&s_dlsym_once, pt_interpose_registry_init_once);
    return s_dlsym_index.count;
}

size_t pt_interpose_registry_duplicate_count(void) {
    pthread_once(&s_dlsym_once, pt_interpose_registry_init_once);
    return s_dlsym_index.duplicate_count;
}
