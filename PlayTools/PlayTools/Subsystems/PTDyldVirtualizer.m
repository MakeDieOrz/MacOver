//
//  PTDyldVirtualizer.m
//  PlayTools
//

#import "PTInternal.h"

#define PT_HAS_PREFIX_LIT(s, lit) (strncmp((s), (lit), sizeof(lit) - 1) == 0)

__attribute__((visibility("hidden"))) BOOL pt_is_hidden_objc_class(const char *name) {
    if (!pt_is_valid_user_pointer(name)) {
        return NO;
    }
    if (pt_is_registered_hidden_class(name)) {
        return YES;
    }
    switch (name[0]) {
        case 'P':
            if (PT_HAS_PREFIX_LIT(name, "PlayCover") ||
                PT_HAS_PREFIX_LIT(name, "PlayTools") ||
                PT_HAS_PREFIX_LIT(name, "PTPlugin") ||
                PT_HAS_PREFIX_LIT(name, "PTSafeMode") ||
                PT_HAS_PREFIX_LIT(name, "PlayLoader") ||
                PT_HAS_PREFIX_LIT(name, "PlayShadow") ||
                PT_HAS_PREFIX_LIT(name, "PlaySettings") ||
                PT_HAS_PREFIX_LIT(name, "PlayScreen") ||
                PT_HAS_PREFIX_LIT(name, "PlayInput") ||
                PT_HAS_PREFIX_LIT(name, "PlayKeychain") ||
                PT_HAS_PREFIX_LIT(name, "PlayInfo") ||
                PT_HAS_PREFIX_LIT(name, "PTSwizzle") ||
                PT_HAS_PREFIX_LIT(name, "PTFake") ||
                PT_HAS_PREFIX_LIT(name, "PTNetwork") ||
                PT_HAS_PREFIX_LIT(name, "PTMediaVolumeHooks") ||
                PT_HAS_PREFIX_LIT(name, "PSSwizzleHooks") ||
                PT_HAS_PREFIX_LIT(name, "PSNetwork") ||
                PT_HAS_PREFIX_LIT(name, "PSVirtual") ||
                PT_HAS_PREFIX_LIT(name, "PSResolved") ||
                PT_HAS_PREFIX_LIT(name, "PSQLDataSource")) {
                return YES;
            }
            break;
        case 'A':
            if (PT_HAS_PREFIX_LIT(name, "AKInterface") ||
                PT_HAS_PREFIX_LIT(name, "AKPlugin")) {
                return YES;
            }
            break;
        case 'B':
            if (PT_HAS_PREFIX_LIT(name, "BatteryLevelLoader") ||
                PT_HAS_PREFIX_LIT(name, "BackgroundControllerLoader")) {
                return YES;
            }
            break;
        case 'M':
            if (PT_HAS_PREFIX_LIT(name, "MediaVolumeLoader") ||
                PT_HAS_PREFIX_LIT(name, "MacOver")) {
                return YES;
            }
            break;
        case 'N':
            if (strcmp(name, "NSMenuToolbarItem") == 0) {
                return NO;
            }
            if (PT_HAS_PREFIX_LIT(name, "NSApplication") ||
                PT_HAS_PREFIX_LIT(name, "NSWindow") ||
                PT_HAS_PREFIX_LIT(name, "NSView") ||
                PT_HAS_PREFIX_LIT(name, "NSMenu") ||
                PT_HAS_PREFIX_LIT(name, "NSPanel") ||
                strcmp(name, "NSTask") == 0 ||
                strcmp(name, "NSConcreteTask") == 0 ||
                PT_HAS_PREFIX_LIT(name, "NSWorkspace") ||
                PT_HAS_PREFIX_LIT(name, "NSRunningApplication") ||
                PT_HAS_PREFIX_LIT(name, "NSScreen") ||
                PT_HAS_PREFIX_LIT(name, "NSEvent") ||
                PT_HAS_PREFIX_LIT(name, "NSPasteboard") ||
                PT_HAS_PREFIX_LIT(name, "NSCursor") ||
                PT_HAS_PREFIX_LIT(name, "NSStatusBar") ||
                PT_HAS_PREFIX_LIT(name, "NSDockTile") ||
                PT_HAS_PREFIX_LIT(name, "NSOpenPanel") ||
                PT_HAS_PREFIX_LIT(name, "NSSavePanel") ||
                PT_HAS_PREFIX_LIT(name, "NSTouchBar")) {
                return YES;
            }
            break;
        case 'S':
            if (PT_HAS_PREFIX_LIT(name, "SwordRPC")) {
                return YES;
            }
            break;
        case 'U':
            if (PT_HAS_PREFIX_LIT(name, "UINS") ||
                PT_HAS_PREFIX_LIT(name, "UIKitMacHelper")) {
                return YES;
            }
            break;
        case 'V':
            if (PT_HAS_PREFIX_LIT(name, "ViewBridge")) {
                return YES;
            }
            break;
        case '_':
        default:
            break;
    }
    if (pt_is_compat13_7_active()) {
        switch (name[0]) {
            case 'A':
                if (strcmp(name, "ATTrackingManager") == 0) {
                    return YES;
                }
                break;
            case 'D':
                if (strcmp(name, "DCAppAttestService") == 0) {
                    return YES;
                }
                break;
            case 'G':
                if (strcmp(name, "GCMouse") == 0 ||
                    strcmp(name, "GCMouseInput") == 0 ||
                    strcmp(name, "GCKeyboard") == 0 ||
                    strcmp(name, "GCKeyboardInput") == 0 ||
                    strcmp(name, "GCDevice") == 0 ||
                    strcmp(name, "GCPhysicalInputProfile") == 0 ||
                    strcmp(name, "GCHapticsLocality") == 0) {
                    return YES;
                }
                break;
            case 'N':
                if (strcmp(name, "NSAttributedStringMarkdownParsingOptions") == 0 ||
                    strcmp(name, "NSInflectionRule") == 0 ||
                    strcmp(name, "NSMorphology") == 0) {
                    return YES;
                }
                break;
            case 'O':
                if (strcmp(name, "OSLogStore") == 0 ||
                    strcmp(name, "OSLogEntry") == 0 ||
                    strcmp(name, "OSLogEntryLog") == 0) {
                    return YES;
                }
                break;
            case 'P':
                if (PT_HAS_PREFIX_LIT(name, "PHPicker")) {
                    return YES;
                }
                break;
            case 'S':
                if (strcmp(name, "SKOverlay") == 0) {
                    return YES;
                }
                break;
            case 'U':
                if (strcmp(name, "UIColorWell") == 0 ||
                    strcmp(name, "UIColorPickerViewController") == 0 ||
                    strcmp(name, "UIListContentConfiguration") == 0 ||
                    strcmp(name, "UIBackgroundConfiguration") == 0 ||
                    strcmp(name, "UICollectionLayoutListConfiguration") == 0 ||
                    strcmp(name, "UICollectionViewCellRegistration") == 0 ||
                    strcmp(name, "UIDeferredMenuElement") == 0 ||
                    strcmp(name, "UISheetPresentationController") == 0 ||
                    strcmp(name, "UICalendarView") == 0 ||
                    strcmp(name, "UIPasteControl") == 0 ||
                    strcmp(name, "UIHoverStyle") == 0 ||
                    strcmp(name, "UTType") == 0) {
                    return YES;
                }
                break;
            case 'W':
                if (strcmp(name, "WKContentWorld") == 0) {
                    return YES;
                }
                break;
            default:
                break;
        }
    }
    if (strstr(name, "CatalystPoster") != NULL) {
        return YES;
    }
    if (name[0] == '_' || strchr(name, '_') != NULL) {
        if (strstr(name, "Play") != NULL &&
            (strstr(name, "PlayTools") != NULL ||
             strstr(name, "PlayCover") != NULL ||
             strstr(name, "PlayShadow") != NULL ||
             strstr(name, "PlayKeychain") != NULL)) {
            return YES;
        }
        if (strstr(name, "AKInterface") != NULL ||
            strstr(name, "AKPlugin") != NULL ||
            strstr(name, "MacOver") != NULL ||
            strstr(name, "PTFake") != NULL ||
            strstr(name, "SwordRPC") != NULL) {
            return YES;
        }
    }
    return NO;
}

__attribute__((visibility("hidden"))) BOOL pt_is_hidden_objc_protocol_name(const char *name) {
    if (!pt_is_valid_user_pointer(name) || name[0] == '\0') {
        return NO;
    }
    if (strcmp(name, "PTAKInterfacePlugin") == 0 ||
        strcmp(name, "CircleMenuDelegate") == 0 ||
        PT_HAS_PREFIX_LIT(name, "PTNetwork") ||
        PT_HAS_PREFIX_LIT(name, "PlayTools") ||
        PT_HAS_PREFIX_LIT(name, "PlayCover") ||
        PT_HAS_PREFIX_LIT(name, "MacOver") ||
        PT_HAS_PREFIX_LIT(name, "PlayShadow") ||
        PT_HAS_PREFIX_LIT(name, "AKInterface") ||
        PT_HAS_PREFIX_LIT(name, "UINS") ||
        strcmp(name, "NSApplicationDelegate") == 0 ||
        strcmp(name, "NSWindowDelegate") == 0 ||
        strcmp(name, "NSMenuDelegate") == 0 ||
        strcmp(name, "NSToolbarDelegate") == 0) {
        return YES;
    }
    if (pt_is_compat13_7_active()) {
        if (strcmp(name, "PHPickerViewControllerDelegate") == 0 ||
            strcmp(name, "UIColorPickerViewControllerDelegate") == 0 ||
            strcmp(name, "SKOverlayDelegate") == 0 ||
            strcmp(name, "WKScriptMessageHandlerWithReply") == 0) {
            return YES;
        }
    }
    if (strstr(name, "PlayTools") != NULL ||
        strstr(name, "AKInterface") != NULL) {
        return YES;
    }
    return NO;
}

__attribute__((visibility("hidden")))
BOOL pt_is_hidden_objc_selector_name(const char *selName) {
    if (!pt_is_valid_user_pointer(selName)) {
        return NO;
    }
    switch (selName[0]) {
        case 'p':
            return PT_HAS_PREFIX_LIT(selName, "pm_") ||
                   PT_HAS_PREFIX_LIT(selName, "ps_hook_") ||
                   PT_HAS_PREFIX_LIT(selName, "pt_hook_");
        case 'k':
            return PT_HAS_PREFIX_LIT(selName, "kif_");
        default:
            return NO;
    }
}

__attribute__((visibility("hidden"))) BOOL pt_is_hidden_dyld_image_name(const char *name) {
    if (name == NULL) {
        return NO;
    }
    if (pt_is_registered_hidden_module(name)) {
        return YES;
    }
    return (strstr(name, "PlayTools") != NULL ||
            strstr(name, "AKInterface") != NULL ||
            strstr(name, "UserPlugins") != NULL ||
            strstr(name, "AGXMetal") != NULL ||
            strstr(name, "/System/Library/Extensions/") != NULL ||
            strstr(name, "AppKit.framework") != NULL ||
            strstr(name, "UIKitMacHelper.framework") != NULL ||
            strstr(name, "ViewBridge.framework") != NULL ||
            strstr(name, "SkyLight.framework") != NULL ||
            strstr(name, "HIToolbox.framework") != NULL ||
            strstr(name, "Carbon.framework") != NULL);
}

__attribute__((visibility("hidden"))) BOOL pt_should_hide_dyld_image(const char *name) {
    return pt_is_hidden_dyld_image_name(name);
}

__attribute__((visibility("hidden"))) BOOL pt_is_hidden_dyld_image_header(const struct mach_header *mh) {
    return pt_is_registered_hidden_image_header((const void *)mh) ? YES : NO;
}

typedef struct {
    os_unfair_lock lock;
    uint32_t real_count;
    uint32_t virtual_count;
    uint64_t generation;
    uint64_t reg_generation;
    uint32_t *virtual_to_real;
} pt_dyld_virtual_table_t;

static _Atomic uint64_t s_dyld_generation = 0;

static pt_dyld_virtual_table_t s_dyld_vtable = {
    .lock = OS_UNFAIR_LOCK_INIT,
    .real_count = 0,
    .virtual_count = 0,
    .generation = UINT64_MAX,
    .reg_generation = UINT64_MAX,
    .virtual_to_real = NULL
};

static void pt_ensure_dyld_master_callbacks(void);

static void pt_dyld_vtable_refresh_locked(void) {
    uint64_t cur_gen = atomic_load_explicit(&s_dyld_generation, memory_order_acquire);
    uint64_t cur_reg_gen = pt_hidden_registry_generation();
    uint32_t cur_real = _dyld_image_count();
    if (s_dyld_vtable.virtual_to_real != NULL &&
        s_dyld_vtable.generation == cur_gen &&
        s_dyld_vtable.reg_generation == cur_reg_gen &&
        cur_real == s_dyld_vtable.real_count) {
        return;
    }
    uint32_t *new_map = (cur_real > 0) ? (uint32_t *)malloc((size_t)cur_real * sizeof(uint32_t)) : NULL;
    if (cur_real > 0 && new_map == NULL) {
        return;
    }
    uint32_t vcount = 0;
    for (uint32_t i = 0; i < cur_real; i++) {
        const char *name = _dyld_get_image_name(i);
        const struct mach_header *mh = _dyld_get_image_header(i);
        if ((name != NULL && pt_should_hide_dyld_image(name)) ||
            (mh != NULL && pt_is_hidden_dyld_image_header(mh))) {
            continue;
        }
        new_map[vcount++] = i;
    }
    free(s_dyld_vtable.virtual_to_real);
    s_dyld_vtable.virtual_to_real = new_map;
    s_dyld_vtable.real_count = cur_real;
    s_dyld_vtable.virtual_count = vcount;
    s_dyld_vtable.generation = cur_gen;
    s_dyld_vtable.reg_generation = cur_reg_gen;
}

static uint32_t pt_dyld_virtual_count(void) {
    if (atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        pt_ensure_dyld_master_callbacks();
    }
    os_unfair_lock_lock(&s_dyld_vtable.lock);
    pt_dyld_vtable_refresh_locked();
    uint32_t vcount = s_dyld_vtable.virtual_count;
    os_unfair_lock_unlock(&s_dyld_vtable.lock);
    return vcount;
}

static BOOL pt_dyld_virtual_to_real_index(uint32_t virtual_idx, uint32_t *out_real_idx) {
    if (atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        pt_ensure_dyld_master_callbacks();
    }
    os_unfair_lock_lock(&s_dyld_vtable.lock);
    pt_dyld_vtable_refresh_locked();
    BOOL valid = (virtual_idx < s_dyld_vtable.virtual_count && s_dyld_vtable.virtual_to_real != NULL);
    if (valid) {
        *out_real_idx = s_dyld_vtable.virtual_to_real[virtual_idx];
    }
    os_unfair_lock_unlock(&s_dyld_vtable.lock);
    return valid;
}

static uint32_t s_fallback_image_index = 0;
static const char *s_fallback_image_path = "/System/Library/Frameworks/UIKit.framework/UIKit";
static pthread_once_t s_fallback_image_once = PTHREAD_ONCE_INIT;

static void pt_init_fallback_system_image_index(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name != NULL &&
            (strstr(name, "/UIKit.framework/UIKit") != NULL ||
             strstr(name, "UIKitCore.framework") != NULL)) {
            s_fallback_image_index = i;
            s_fallback_image_path = pt_sanitize_image_path_for_app(name);
            return;
        }
    }
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name != NULL && strstr(name, "Foundation.framework") != NULL) {
            s_fallback_image_index = i;
            s_fallback_image_path = pt_sanitize_image_path_for_app(name);
            return;
        }
    }
}

static uint32_t pt_fallback_system_image_index(void) {
    pthread_once(&s_fallback_image_once, pt_init_fallback_system_image_index);
    return s_fallback_image_index;
}

__attribute__((visibility("hidden"))) const char *pt_fallback_system_image_path(void) {
    pthread_once(&s_fallback_image_once, pt_init_fallback_system_image_index);
    return s_fallback_image_path;
}

typedef struct {
    const void *replacement;
    const void *replacee;
} pt_interpose_tuple_t;

static const pt_interpose_tuple_t *s_interpose_tuples = NULL;
static size_t s_interpose_count = 0;
static pthread_once_t s_interpose_once = PTHREAD_ONCE_INIT;

static void pt_init_interpose_tuples(void) {
    const struct mach_header_64 *mh = (const struct mach_header_64 *)dyld_image_header_containing_address((const void *)&pt_init_interpose_tuples);
    if (mh != NULL) {
        unsigned long size = 0;
        uint8_t *sec = getsectiondata(mh, "__DATA", "__interpose", &size);
        if (sec == NULL) {
            sec = getsectiondata(mh, "__DATA_CONST", "__interpose", &size);
        }
        if (sec != NULL && size >= sizeof(pt_interpose_tuple_t)) {
            s_interpose_tuples = (const pt_interpose_tuple_t *)sec;
            s_interpose_count = size / sizeof(pt_interpose_tuple_t);
        }
    }
}

static inline const void *pt_strip_code_ptr(const void *p) {
#if __has_include(<ptrauth.h>)
    return (p != NULL) ? ptrauth_strip(p, ptrauth_key_function_pointer) : NULL;
#else
    return p;
#endif
}

#define PT_SWIZZLE_IMP_SLOTS 2048U

typedef struct {
    _Atomic(uintptr_t) hook;
    _Atomic(uintptr_t) orig;
    _Atomic(uintptr_t) raw_orig;
} pt_swizzle_imp_slot_t;

static pt_swizzle_imp_slot_t s_swizzled_imp_table[PT_SWIZZLE_IMP_SLOTS];
static _Atomic(uintptr_t) s_swizzled_orig_set[PT_SWIZZLE_IMP_SLOTS];
static _Atomic(uintptr_t) s_hidden_swizzle_sel_set[PT_SWIZZLE_IMP_SLOTS];

static void pt_ptr_set_insert(_Atomic(uintptr_t) *table, uintptr_t val) {
    if (val == 0 || val == 1) {
        return;
    }
    uint64_t h = ((uint64_t)(val >> 2) * 11400714819323198485ULL);
    size_t start = (size_t)((h >> 53) & (PT_SWIZZLE_IMP_SLOTS - 1U));
    for (size_t probe = 0; probe < PT_SWIZZLE_IMP_SLOTS; probe++) {
        size_t idx = (start + probe) & (PT_SWIZZLE_IMP_SLOTS - 1U);
        for (;;) {
            uintptr_t cur = atomic_load_explicit(&table[idx], memory_order_acquire);
            if (cur == val) {
                return;
            }
            if (cur == 0) {
                uintptr_t expected = 0;
                if (atomic_compare_exchange_strong_explicit(
                        &table[idx], &expected, val,
                        memory_order_release, memory_order_acquire)) {
                    return;
                }
                continue;
            }
            break;
        }
    }
}

static BOOL pt_ptr_set_contains(const _Atomic(uintptr_t) *table, uintptr_t val) {
    if (val == 0 || val == 1) {
        return NO;
    }
    uint64_t h = ((uint64_t)(val >> 2) * 11400714819323198485ULL);
    size_t start = (size_t)((h >> 53) & (PT_SWIZZLE_IMP_SLOTS - 1U));
    for (size_t probe = 0; probe < PT_SWIZZLE_IMP_SLOTS; probe++) {
        size_t idx = (start + probe) & (PT_SWIZZLE_IMP_SLOTS - 1U);
        uintptr_t cur = atomic_load_explicit(&table[idx], memory_order_acquire);
        if (cur == 0) {
            return NO;
        }
        if (cur == val) {
            return YES;
        }
    }
    return NO;
}

__attribute__((visibility("hidden")))
void pt_register_hidden_swizzle_selector(SEL sel) {
    if (sel != NULL) {
        pt_ptr_set_insert(s_hidden_swizzle_sel_set, (uintptr_t)sel);
    }
}

static inline BOOL pt_is_registered_hidden_swizzle_selector(SEL sel) {
    return (sel != NULL) && pt_ptr_set_contains(s_hidden_swizzle_sel_set, (uintptr_t)sel);
}

static inline BOOL pt_is_swizzled_orig_imp(const void *addr) {
    uintptr_t stripped = (uintptr_t)pt_strip_code_ptr(addr);
    return pt_ptr_set_contains(s_swizzled_orig_set, stripped);
}

static inline size_t pt_swizzle_imp_hash(uintptr_t key) {
    uint64_t h = ((uint64_t)(key >> 2) * 11400714819323198485ULL);
    return (size_t)((h >> 53) & (PT_SWIZZLE_IMP_SLOTS - 1U));
}

static uintptr_t pt_lookup_swizzled_orig_one(uintptr_t key) {
    if (key == 0 || key == 1) {
        return 0;
    }
    size_t start = pt_swizzle_imp_hash(key);
    for (size_t probe = 0; probe < PT_SWIZZLE_IMP_SLOTS; probe++) {
        size_t idx = (start + probe) & (PT_SWIZZLE_IMP_SLOTS - 1U);
        pt_swizzle_imp_slot_t *slot = &s_swizzled_imp_table[idx];
        uintptr_t cur = atomic_load_explicit(&slot->hook, memory_order_acquire);
        while (cur == 1) {
            cur = atomic_load_explicit(&slot->hook, memory_order_acquire);
        }
        if (cur == 0) {
            return 0;
        }
        if (cur == key) {
            return atomic_load_explicit(&slot->orig, memory_order_relaxed);
        }
    }
    return 0;
}

static const void *pt_lookup_swizzled_orig_imp(const void *addr) {
    uintptr_t cur = (uintptr_t)pt_strip_code_ptr(addr);
    if (cur == 0 || cur == 1) {
        return NULL;
    }
    const void *resolved = NULL;
    for (int depth = 0; depth < 16; depth++) {
        uintptr_t next = pt_lookup_swizzled_orig_one(cur);
        if (next == 0 || next == cur) {
            break;
        }
        resolved = (const void *)next;
        cur = next;
    }
    return resolved;
}

static const void *pt_lookup_swizzled_raw_orig_imp(const void *addr) {
    uintptr_t cur = (uintptr_t)pt_strip_code_ptr(addr);
    if (cur == 0 || cur == 1) {
        return NULL;
    }
    const void *resolved = NULL;
    for (int depth = 0; depth < 16; depth++) {
        size_t start = pt_swizzle_imp_hash(cur);
        uintptr_t next_stripped = 0;
        uintptr_t next_raw = 0;
        for (size_t probe = 0; probe < PT_SWIZZLE_IMP_SLOTS; probe++) {
            size_t idx = (start + probe) & (PT_SWIZZLE_IMP_SLOTS - 1U);
            pt_swizzle_imp_slot_t *slot = &s_swizzled_imp_table[idx];
            uintptr_t slot_hook = atomic_load_explicit(&slot->hook, memory_order_acquire);
            while (slot_hook == 1) {
                slot_hook = atomic_load_explicit(&slot->hook, memory_order_acquire);
            }
            if (slot_hook == 0) {
                break;
            }
            if (slot_hook == cur) {
                next_stripped = atomic_load_explicit(&slot->orig, memory_order_relaxed);
                next_raw = atomic_load_explicit(&slot->raw_orig, memory_order_relaxed);
                break;
            }
        }
        if (next_stripped == 0 || next_stripped == cur) {
            break;
        }
        resolved = (const void *)(next_raw != 0 ? next_raw : next_stripped);
        cur = next_stripped;
    }
    return resolved;
}

__attribute__((visibility("hidden")))
void pt_register_swizzled_imp(const void *hook_imp, const void *orig_imp) {
    uintptr_t hook = (uintptr_t)pt_strip_code_ptr(hook_imp);
    uintptr_t orig = (uintptr_t)pt_strip_code_ptr(orig_imp);
    uintptr_t raw_orig = (uintptr_t)orig_imp;
    if (hook == 0 || orig == 0 || hook == 1 || orig == 1 || hook == orig) {
        return;
    }
    const void *root_raw = pt_lookup_swizzled_raw_orig_imp(orig_imp);
    const void *root_orig = pt_lookup_swizzled_orig_imp((const void *)orig);
    if (root_orig != NULL) {
        orig = (uintptr_t)root_orig;
        if (root_raw != NULL) {
            raw_orig = (uintptr_t)root_raw;
        }
    }
    if (hook == orig) {
        return;
    }
    pt_ptr_set_insert(s_swizzled_orig_set, orig);
    size_t start = pt_swizzle_imp_hash(hook);
    for (size_t probe = 0; probe < PT_SWIZZLE_IMP_SLOTS; probe++) {
        size_t idx = (start + probe) & (PT_SWIZZLE_IMP_SLOTS - 1U);
        pt_swizzle_imp_slot_t *slot = &s_swizzled_imp_table[idx];
        for (;;) {
            uintptr_t cur = atomic_load_explicit(&slot->hook, memory_order_acquire);
            if (cur == 1) {
                continue;
            }
            if (cur == hook) {
                return;
            }
            if (cur == 0) {
                uintptr_t expected = 0;
                if (atomic_compare_exchange_strong_explicit(
                        &slot->hook, &expected, (uintptr_t)1,
                        memory_order_acq_rel, memory_order_acquire)) {
                    atomic_store_explicit(&slot->orig, orig, memory_order_relaxed);
                    atomic_store_explicit(&slot->raw_orig, raw_orig, memory_order_relaxed);
                    atomic_store_explicit(&slot->hook, hook, memory_order_release);
                    return;
                }
                continue;
            }
            break;
        }
    }
}

__attribute__((visibility("hidden")))
BOOL pt_is_address_in_playtools(const void *addr) {
    const void *stripped = pt_strip_code_ptr(addr);
    if (stripped == NULL) {
        return NO;
    }
    const char *path = dyld_image_path_containing_address(stripped);
    if (path == NULL) {
        return NO;
    }
    return (strstr(path, "PlayTools") != NULL ||
            strstr(path, "AKInterface") != NULL ||
            strstr(path, "UserPlugins") != NULL ||
            pt_is_registered_hidden_module(path));
}

static const void *pt_resolve_interposed_target(const void *addr) {
    if (addr == NULL) {
        return NULL;
    }
    const void *stripped = pt_strip_code_ptr(addr);
    pthread_once(&s_interpose_once, pt_init_interpose_tuples);
    for (size_t i = 0; i < s_interpose_count; i++) {
        if (pt_strip_code_ptr(s_interpose_tuples[i].replacement) == stripped &&
            s_interpose_tuples[i].replacee != NULL) {
            return s_interpose_tuples[i].replacee;
        }
    }
    const void *swizzled_orig = pt_lookup_swizzled_orig_imp(stripped);
    if (swizzled_orig != NULL) {
        return swizzled_orig;
    }
    return addr;
}

// Define dyld platform functions for interpose
extern int dyld_get_active_platform(void) __attribute__((weak_import));
static int pt_dyld_get_active_platform(void) { return PLATFORM_IOS; }

extern uint32_t dyld_get_base_platform(uint32_t platform) __attribute__((weak_import));
static uint32_t pt_dyld_get_base_platform(uint32_t platform) {
    if (platform == PLATFORM_MACCATALYST || platform == PLATFORM_IOS) {
        return PLATFORM_IOS;
    }
    return (dyld_get_base_platform != NULL) ? dyld_get_base_platform(platform) : platform;
}

extern void pt_orig_dyld_get_image_versions(
    const struct mach_header *mh,
    void (^callback)(uint32_t platform, uint32_t sdk_version, uint32_t min_version))
    __asm("_dyld_get_image_versions") __attribute__((weak_import));

static void pt_dyld_get_image_versions(
    const struct mach_header *mh,
    void (^callback)(uint32_t platform, uint32_t sdk_version, uint32_t min_version)) {
    if (pt_orig_dyld_get_image_versions == NULL || mh == NULL || callback == NULL) {
        return;
    }
    const struct mach_header *lc_mh = mh;
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        lc_mh = pt_maybe_shadow_mach_header(mh);
    }
    pt_orig_dyld_get_image_versions(lc_mh, callback);
}

extern bool pt_orig_dyld_sdk_at_least(const struct mach_header *mh, pt_dyld_build_version_t version)
    __asm("_dyld_sdk_at_least") __attribute__((weak_import));

static bool pt_dyld_sdk_at_least(const struct mach_header *mh, pt_dyld_build_version_t version) {
    if (pt_orig_dyld_sdk_at_least == NULL || mh == NULL) {
        return false;
    }
    const struct mach_header *lc_mh = mh;
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        lc_mh = pt_maybe_shadow_mach_header(mh);
    }
    return pt_orig_dyld_sdk_at_least(lc_mh, version);
}

extern bool pt_orig_dyld_minos_at_least(const struct mach_header *mh, pt_dyld_build_version_t version)
    __asm("_dyld_minos_at_least") __attribute__((weak_import));

static bool pt_dyld_minos_at_least(const struct mach_header *mh, pt_dyld_build_version_t version) {
    if (pt_orig_dyld_minos_at_least == NULL || mh == NULL) {
        return false;
    }
    const struct mach_header *lc_mh = mh;
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        lc_mh = pt_maybe_shadow_mach_header(mh);
    }
    return pt_orig_dyld_minos_at_least(lc_mh, version);
}

extern const char *dyld_shared_cache_file_path(void) __attribute__((weak_import));
static const char *pt_dyld_shared_cache_file_path(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        const char *model = pt_get_device_model_cstr();
        if (model != NULL && strcmp(model, "iPad6,7") == 0) {
            return "/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64";
        }
        return "/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e";
    }
    return (dyld_shared_cache_file_path != NULL) ? dyld_shared_cache_file_path() : NULL;
}

extern bool pt_orig_dyld_shared_cache_contains_path(const char *path)
    __asm("__dyld_shared_cache_contains_path") __attribute__((weak_import));
extern const void *_dyld_get_shared_cache_range(size_t *length) __attribute__((weak_import));

static BOOL pt_path_is_post13_7_framework(const char *path) {
    if (path == NULL || path[0] == '\0') {
        return NO;
    }
    return (strstr(path, "/ExtensionKit.framework/") != NULL ||
            strstr(path, "/ExtensionKit.framework") != NULL ||
            strstr(path, "/ExtensionFoundation.framework") != NULL ||
            strstr(path, "/WidgetKit.framework") != NULL ||
            strstr(path, "/TipKit.framework") != NULL ||
            strstr(path, "/AppIntents.framework") != NULL ||
            strstr(path, "/AppTrackingTransparency.framework") != NULL ||
            strstr(path, "/UniformTypeIdentifiers.framework") != NULL ||
            strstr(path, "/Observation.framework") != NULL ||
            strstr(path, "/SwiftData.framework") != NULL ||
            strstr(path, "/ActivityKit.framework") != NULL ||
            strstr(path, "/GroupActivities.framework") != NULL ||
            strstr(path, "/NearbyInteraction.framework") != NULL ||
            strstr(path, "/Charts.framework") != NULL ||
            strstr(path, "/OSLog.framework") != NULL ||
            strstr(path, "libswift_Concurrency.dylib") != NULL ||
            strstr(path, "libswift_StringProcessing.dylib") != NULL);
}

__attribute__((visibility("hidden"))) BOOL pt_is_post13_7_hidden_framework_path(const char *path) {
    if (path == NULL || path[0] == '\0' || !pt_is_compat13_7_active()) {
        return NO;
    }
    return pt_path_is_post13_7_framework(path);
}

#ifndef PT_POST13_MAX_RANGES
#define PT_POST13_MAX_RANGES 128U
#endif

typedef struct {
    uintptr_t start;
    uintptr_t end;
} PTPost13AddrRange;

static os_unfair_lock s_post13_range_lock = OS_UNFAIR_LOCK_INIT;
static PTPost13AddrRange s_post13_ranges[PT_POST13_MAX_RANGES];
static uint32_t s_post13_range_count = 0;
static BOOL s_post13_range_overflow = NO;
static uintptr_t s_post13_dsc_start = 0;
static uintptr_t s_post13_dsc_end = 0;
static _Atomic uint32_t s_post13_cached_image_count = 0;

static void pt_rebuild_post13_range_cache_locked(uint32_t cur_ic) {
    s_post13_range_count = 0;
    s_post13_range_overflow = NO;
    s_post13_dsc_start = 0;
    s_post13_dsc_end = 0;
    if (_dyld_get_shared_cache_range != NULL) {
        size_t dsc_len = 0;
        const void *dsc_base = _dyld_get_shared_cache_range(&dsc_len);
        if (dsc_base != NULL && dsc_len > 0 && (uintptr_t)dsc_base <= UINTPTR_MAX - dsc_len) {
            s_post13_dsc_start = (uintptr_t)dsc_base;
            s_post13_dsc_end = s_post13_dsc_start + (uintptr_t)dsc_len;
        }
    }
    for (uint32_t i = 0; i < cur_ic; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!pt_path_is_post13_7_framework(name)) {
            continue;
        }
        const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (mh == NULL || mh->magic != MH_MAGIC_64) {
            continue;
        }
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const uint8_t *p = (const uint8_t *)(mh + 1);
        const uint8_t *cmds_end = p + mh->sizeofcmds;
        for (uint32_t c = 0; c < mh->ncmds; c++) {
            if ((size_t)(cmds_end - p) < sizeof(struct load_command)) {
                break;
            }
            const struct load_command *lc = (const struct load_command *)p;
            if (lc->cmdsize < sizeof(struct load_command) || (size_t)(cmds_end - p) < lc->cmdsize) {
                break;
            }
            if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
                if (seg->vmsize > 0 && strcmp(seg->segname, "__LINKEDIT") != 0) {
                    uintptr_t start = (uintptr_t)((int64_t)seg->vmaddr + (int64_t)slide);
                    if (seg->vmsize <= UINTPTR_MAX - start) {
                        if (s_post13_range_count < PT_POST13_MAX_RANGES) {
                            s_post13_ranges[s_post13_range_count++] = (PTPost13AddrRange){
                                .start = start,
                                .end = start + (uintptr_t)seg->vmsize
                            };
                        } else {
                            s_post13_range_overflow = YES;
                        }
                    }
                }
            }
            p += lc->cmdsize;
        }
    }
    atomic_store_explicit(&s_post13_cached_image_count, cur_ic, memory_order_release);
}

static BOOL pt_is_hidden_post13_7_class(Class cls) {
    if (cls == Nil || !pt_is_compat13_7_active()) {
        return NO;
    }
    uint32_t cur_ic = _dyld_image_count();
    if (cur_ic != atomic_load_explicit(&s_post13_cached_image_count, memory_order_acquire)) {
        os_unfair_lock_lock(&s_post13_range_lock);
        if (cur_ic != atomic_load_explicit(&s_post13_cached_image_count, memory_order_relaxed)) {
            pt_rebuild_post13_range_cache_locked(cur_ic);
        }
        os_unfair_lock_unlock(&s_post13_range_lock);
    }

    uintptr_t addr = (uintptr_t)cls;
    os_unfair_lock_lock(&s_post13_range_lock);
    for (uint32_t r = 0; r < s_post13_range_count; r++) {
        if (addr >= s_post13_ranges[r].start && addr < s_post13_ranges[r].end) {
            os_unfair_lock_unlock(&s_post13_range_lock);
            return YES;
        }
    }
    BOOL in_dsc = (!s_post13_range_overflow &&
                   s_post13_dsc_end > s_post13_dsc_start &&
                   addr >= s_post13_dsc_start &&
                   addr < s_post13_dsc_end);
    os_unfair_lock_unlock(&s_post13_range_lock);
    if (in_dsc) {
        return NO;
    }
    const char *img = class_getImageName(cls);
    return pt_path_is_post13_7_framework(img);
}

static bool pt_dyld_shared_cache_contains_path(const char *path) {
    if (pt_orig_dyld_shared_cache_contains_path == NULL) {
        return false;
    }
    const void *caller = __builtin_return_address(0);
    if (path != NULL && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        char lex_buf[PATH_MAX];
        const char *norm = path;
        if (norm[0] == '/' && pt_needs_lexical_norm(norm)) {
            const char *collapsed = pt_normalize_lexical_path(norm, lex_buf, sizeof(lex_buf));
            if (collapsed != NULL) {
                norm = collapsed;
            }
        }
        if (strcmp(norm, "/System/iOSSupport") == 0 ||
            strncmp(norm, "/System/iOSSupport/", 19) == 0) {
            return false;
        }
        if (strstr(norm, ".framework/Versions/") != NULL) {
            return false;
        }
        if (pt_is_hidden_dyld_image_name(norm) || pt_is_hidden_path(norm, caller)) {
            return false;
        }
        if (pt_is_post13_7_hidden_framework_path(norm)) {
            return false;
        }
        if (pt_orig_dyld_shared_cache_contains_path(norm)) {
            return true;
        }
        if (strncmp(norm, "/System/Library/", 16) == 0 || strncmp(norm, "/usr/lib/", 9) == 0) {
            char ios_buf[PATH_MAX];
            int n = snprintf(ios_buf, sizeof(ios_buf), "/System/iOSSupport%s", norm);
            if (n > 0 && (size_t)n < sizeof(ios_buf) &&
                pt_orig_dyld_shared_cache_contains_path(ios_buf)) {
                return true;
            }
            const char *slash = strrchr(norm, '/');
            if (slash != NULL && slash > norm && strstr(norm, ".framework/") != NULL &&
                strstr(norm, "/Versions/") == NULL) {
                size_t dir_len = (size_t)(slash - norm);
                n = snprintf(ios_buf, sizeof(ios_buf),
                             "/System/iOSSupport%.*s/Versions/A%s",
                             (int)dir_len, norm, slash);
                if (n > 0 && (size_t)n < sizeof(ios_buf) &&
                    pt_orig_dyld_shared_cache_contains_path(ios_buf)) {
                    return true;
                }
            }
        }
        return false;
    }
    return pt_orig_dyld_shared_cache_contains_path(path);
}

extern const void *pt_orig_objc_getClass(const char *name) __asm__("_objc_getClass");
extern const void *pt_orig_objc_lookUpClass(const char *name) __asm__("_objc_lookUpClass");
extern const void *pt_orig_objc_getMetaClass(const char *name) __asm__("_objc_getMetaClass");
extern const void *pt_orig_objc_getRequiredClass(const char *name) __asm__("_objc_getRequiredClass");
extern const void *pt_orig_NSClassFromString(CFStringRef aClassName) __asm__("_NSClassFromString");

static BOOL pt_should_hide_resolved_objc_class_with_image(const char *name, Class cls, const char *preloaded_img) {
    if (preloaded_img != NULL) {
        if (pt_is_post13_7_hidden_framework_path(preloaded_img)) {
            return YES;
        }
    } else if (pt_is_hidden_post13_7_class(cls)) {
        return YES;
    }
    if (name == NULL || !pt_is_hidden_objc_class(name)) {
        return NO;
    }
    if (name[0] == 'N' && name[1] == 'S' && cls != Nil) {
        const char *img = (preloaded_img != NULL) ? preloaded_img : class_getImageName(cls);
        if (img != NULL) {
            pt_ensure_bundle_path_map();
            if (s_real_app_bundle_len > 0 &&
                pt_match_prefix_modulo_private(img, s_real_app_bundle_dir, s_real_app_bundle_len) != NULL) {
                return NO;
            }
            if (strcmp(name, "NSTask") == 0 ||
                strcmp(name, "NSConcreteTask") == 0 ||
                PT_HAS_PREFIX_LIT(name, "NSCursor") ||
                PT_HAS_PREFIX_LIT(name, "NSStatusBar") ||
                PT_HAS_PREFIX_LIT(name, "NSDockTile") ||
                PT_HAS_PREFIX_LIT(name, "NSOpenPanel") ||
                PT_HAS_PREFIX_LIT(name, "NSSavePanel") ||
                PT_HAS_PREFIX_LIT(name, "NSTouchBar")) {
                return YES;
            }
            if (pt_is_compat13_7_active() &&
                (strcmp(name, "NSAttributedStringMarkdownParsingOptions") == 0 ||
                 strcmp(name, "NSInflectionRule") == 0 ||
                 strcmp(name, "NSMorphology") == 0)) {
                return YES;
            }
            return (pt_is_hidden_dyld_image_name(img) ||
                    strstr(img, "/WindowManagement.framework/") != NULL ||
                    strstr(img, "/Shortcut.framework/") != NULL);
        }
    }
    return YES;
}

static BOOL pt_should_hide_resolved_objc_class(const char *name, Class cls) {
    return pt_should_hide_resolved_objc_class_with_image(name, cls, NULL);
}

static const void *pt_objc_getClass(const char *name) {
    if (name != NULL && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_is_hidden_objc_class(name)) {
            if (name[0] == 'N' && name[1] == 'S') {
                const void *cls = pt_orig_objc_getClass(name);
                if (cls != NULL && !pt_should_hide_resolved_objc_class(name, (__bridge Class)cls)) {
                    return cls;
                }
            }
            PT_DEBUG_TRACE("dyld", "hid class=%s", name);
            return NULL;
        }
        const void *cls = pt_orig_objc_getClass(name);
        if (cls != NULL && pt_is_hidden_post13_7_class((__bridge Class)cls)) {
            PT_DEBUG_TRACE("dyld", "hid compat13_7 class=%s", name);
            return NULL;
        }
        return cls;
    }
    return pt_orig_objc_getClass(name);
}

static const void *pt_objc_lookUpClass(const char *name) {
    if (name != NULL && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_is_hidden_objc_class(name)) {
            if (name[0] == 'N' && name[1] == 'S') {
                const void *cls = pt_orig_objc_lookUpClass(name);
                if (cls != NULL && !pt_should_hide_resolved_objc_class(name, (__bridge Class)cls)) {
                    return cls;
                }
            }
            PT_DEBUG_TRACE("dyld", "hid class=%s", name);
            return NULL;
        }
        const void *cls = pt_orig_objc_lookUpClass(name);
        if (cls != NULL && pt_is_hidden_post13_7_class((__bridge Class)cls)) {
            PT_DEBUG_TRACE("dyld", "hid compat13_7 class=%s", name);
            return NULL;
        }
        return cls;
    }
    return pt_orig_objc_lookUpClass(name);
}

static const void *pt_objc_getMetaClass(const char *name) {
    if (name != NULL && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_is_hidden_objc_class(name)) {
            if (name[0] == 'N' && name[1] == 'S') {
                const void *cls = pt_orig_objc_lookUpClass(name);
                if (cls != NULL && !pt_should_hide_resolved_objc_class(name, (__bridge Class)cls)) {
                    return pt_orig_objc_getMetaClass(name);
                }
            }
            PT_DEBUG_TRACE("dyld", "hid metaclass=%s", name);
            return NULL;
        }
        const void *cls = pt_orig_objc_lookUpClass(name);
        if (cls != NULL && pt_is_hidden_post13_7_class((__bridge Class)cls)) {
            PT_DEBUG_TRACE("dyld", "hid compat13_7 metaclass=%s", name);
            return NULL;
        }
    }
    return pt_orig_objc_getMetaClass(name);
}

static const void *pt_objc_getRequiredClass(const char *name) {
    if (name != NULL && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_is_hidden_objc_class(name)) {
            if (name[0] == 'N' && name[1] == 'S') {
                const void *cls = pt_orig_objc_lookUpClass(name);
                if (cls != NULL && !pt_should_hide_resolved_objc_class(name, (__bridge Class)cls)) {
                    return pt_orig_objc_getRequiredClass(name);
                }
            }
            PT_DEBUG_TRACE("dyld", "hid required class=%s", name);
            return NULL;
        }
        const void *cls = pt_orig_objc_lookUpClass(name);
        if (cls != NULL && pt_is_hidden_post13_7_class((__bridge Class)cls)) {
            PT_DEBUG_TRACE("dyld", "hid compat13_7 required class=%s", name);
            return NULL;
        }
    }
    return pt_orig_objc_getRequiredClass(name);
}

static const void *pt_NSClassFromString(CFStringRef aClassName) {
    if (aClassName != NULL && pt_is_bypass_enabled()) {
        char buf[256];
        const char *cstr = CFStringGetCStringPtr(aClassName, kCFStringEncodingUTF8);
        if (cstr == NULL && CFStringGetCString(aClassName, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            cstr = buf;
        }
        if (cstr != NULL && !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
            if (pt_is_hidden_objc_class(cstr)) {
                if (cstr[0] == 'N' && cstr[1] == 'S') {
                    const void *cls = pt_orig_NSClassFromString(aClassName);
                    if (cls != NULL && !pt_should_hide_resolved_objc_class(cstr, (__bridge Class)cls)) {
                        return cls;
                    }
                }
                PT_DEBUG_TRACE("dyld", "hid class=%s", cstr);
                return NULL;
            }
            const void *cls = pt_orig_NSClassFromString(aClassName);
            if (cls != NULL && pt_is_hidden_post13_7_class((__bridge Class)cls)) {
                PT_DEBUG_TRACE("dyld", "hid compat13_7 class=%s", cstr);
                return NULL;
            }
            return cls;
        }
    }
    return pt_orig_NSClassFromString(aClassName);
}

static const char **pt_objc_copyImageNames(unsigned int *outCount) {
    unsigned int count = 0;
    const char **names = objc_copyImageNames(&count);
    const void *caller = __builtin_return_address(0);
    if (names != NULL && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        unsigned int writeIdx = 0;
        for (unsigned int i = 0; i < count; i++) {
            const char *name = names[i];
            if (name == NULL || pt_is_hidden_dyld_image_name(name) ||
                pt_is_post13_7_hidden_framework_path(name)) {
                continue;
            }
            names[writeIdx++] = pt_sanitize_image_path_for_app(name);
        }
        names[writeIdx] = NULL;
        if (outCount != NULL) {
            *outCount = writeIdx;
        }
        return names;
    }
    if (outCount != NULL) {
        *outCount = count;
    }
    return names;
}

static const char *pt_class_getImageName(Class cls) {
    const void *caller = __builtin_return_address(0);
    if (cls != Nil && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        const char *name = class_getImageName(cls);
        if (name != NULL && pt_is_post13_7_hidden_framework_path(name)) {
            return NULL;
        }
        if (pt_should_hide_resolved_objc_class_with_image(class_getName(cls), cls, name)) {
            return NULL;
        }
        if (name != NULL) {
            if (pt_is_hidden_dyld_image_name(name)) {
                return pt_fallback_system_image_path();
            }
            return pt_sanitize_image_path_for_app(name);
        }
        return name;
    }
    return class_getImageName(cls);
}

static Protocol *pt_objc_getProtocol(const char *name) {
    if (name == NULL) {
        return NULL;
    }
    if (pt_is_hidden_objc_protocol_name(name) &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NULL;
    }
    return objc_getProtocol(name);
}

extern Protocol *pt_orig_NSProtocolFromString(NSString *namestr) __asm__("_NSProtocolFromString");

static Protocol *pt_NSProtocolFromString(NSString *namestr) {
    if (namestr != nil && pt_is_bypass_enabled()) {
        char buf[256];
        const char *cstr = CFStringGetCStringPtr((__bridge CFStringRef)namestr, kCFStringEncodingUTF8);
        if (cstr == NULL &&
            CFStringGetCString((__bridge CFStringRef)namestr, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            cstr = buf;
        }
        if (cstr != NULL &&
            pt_is_hidden_objc_protocol_name(cstr) &&
            !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
            return nil;
        }
    }
    return pt_orig_NSProtocolFromString(namestr);
}

static Protocol * __unsafe_unretained *pt_objc_copyProtocolList(unsigned int *outCount) {
    unsigned int count = 0;
    Protocol * __unsafe_unretained *protos = objc_copyProtocolList(&count);
    if (protos != NULL && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        unsigned int writeIdx = 0;
        for (unsigned int i = 0; i < count; i++) {
            Protocol *p = protos[i];
            const char *pname = (p != NULL) ? protocol_getName(p) : NULL;
            if (pname != NULL && pt_is_hidden_objc_protocol_name(pname)) {
                continue;
            }
            protos[writeIdx++] = p;
        }
        protos[writeIdx] = NULL;
        if (outCount != NULL) {
            *outCount = writeIdx;
        }
        return protos;
    }
    if (outCount != NULL) {
        *outCount = count;
    }
    return protos;
}

static inline uint64_t pt_fnv1a_cstr(const char *s) {
    uint64_t h = 14695981039346656037ULL;
    const unsigned char *p = (const unsigned char *)s;
    while (*p != '\0') {
        h ^= (uint64_t)(*p++);
        h *= 1099511628211ULL;
    }
    return h;
}

static void pt_append_unique_cand_path(const char **cands, size_t *cand_count, size_t max_cands, const char *path) {
    if (path == NULL || path[0] == '\0' || *cand_count >= max_cands) {
        return;
    }
    for (size_t i = 0; i < *cand_count; i++) {
        if (strcmp(cands[i], path) == 0) {
            return;
        }
    }
    cands[(*cand_count)++] = path;
}

static unsigned int pt_filter_class_names_in_place(const char **names, unsigned int count) {
    unsigned int writeIdx = 0;
    BOOL compat13 = pt_is_compat13_7_active();
    for (unsigned int i = 0; i < count; i++) {
        if (names[i] != NULL) {
            if (pt_is_hidden_objc_class(names[i])) {
                if (names[i][0] == 'N' && names[i][1] == 'S') {
                    const void *cls = pt_orig_objc_lookUpClass(names[i]);
                    if (cls != NULL && !pt_should_hide_resolved_objc_class(names[i], (__bridge Class)cls)) {
                        names[writeIdx++] = names[i];
                        continue;
                    }
                }
                continue;
            }
            if (compat13) {
                const void *cls = pt_orig_objc_lookUpClass(names[i]);
                if (cls != NULL && pt_is_hidden_post13_7_class((__bridge Class)cls)) {
                    continue;
                }
            }
        }
        names[writeIdx++] = names[i];
    }
    names[writeIdx] = NULL;
    return writeIdx;
}

static const char **pt_objc_copyClassNamesForImage(const char *image, unsigned int *outCount) {
    if (image == NULL) {
        if (outCount != NULL) {
            *outCount = 0;
        }
        return NULL;
    }
    const char *orig_image = image;
    char resolved_buf[PATH_MAX];
    image = pt_resolve_virtual_bundle_path(image, resolved_buf, sizeof(resolved_buf));
    if (image == NULL) {
        if (outCount != NULL) {
            *outCount = 0;
        }
        return NULL;
    }
    const void *caller = __builtin_return_address(0);
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        BOOL hidden_path = pt_is_reverse_mapped_iossupport(orig_image, image)
            ? pt_is_hidden_path(orig_image, caller)
            : pt_is_hidden_path(image, caller);
        if (pt_is_hidden_dyld_image_name(image) ||
            pt_is_post13_7_hidden_framework_path(orig_image) ||
            pt_is_post13_7_hidden_framework_path(image) ||
            hidden_path) {
            if (outCount != NULL) {
                *outCount = 0;
            }
            return NULL;
        }
        const char *cand_paths[6] = { NULL, NULL, NULL, NULL, NULL, NULL };
        char ver_path[PATH_MAX];
        char ios_ver_path[PATH_MAX];
        char ios_path[PATH_MAX];
        char stripped_ver_path[PATH_MAX];
        size_t cand_count = 0;
        pt_append_unique_cand_path(cand_paths, &cand_count, 6, image);

        // Derive canonical non-/System/iOSSupport base path so both macOS & Catalyst slices are queried.
        const char *canon = image;
        if (strncmp(image, "/System/iOSSupport/", 19) == 0) {
            canon = image + 18;
            pt_append_unique_cand_path(cand_paths, &cand_count, 6, canon);
        }
        if (strncmp(canon, "/System/", 8) == 0) {
            const char *fw = strstr(canon, ".framework/");
            if (fw != NULL && strstr(fw, ".framework/Versions/") == NULL) {
                size_t prefix_len = (size_t)(fw + 10 - canon);
                int vn = snprintf(ver_path, sizeof(ver_path), "%.*s/Versions/A%s",
                                  (int)prefix_len, canon, fw + 10);
                if (vn > 0 && (size_t)vn < sizeof(ver_path)) {
                    pt_append_unique_cand_path(cand_paths, &cand_count, 6, ver_path);
                    int ivn = snprintf(ios_ver_path, sizeof(ios_ver_path),
                                       "/System/iOSSupport%s", ver_path);
                    if (ivn > 0 && (size_t)ivn < sizeof(ios_ver_path)) {
                        pt_append_unique_cand_path(cand_paths, &cand_count, 6, ios_ver_path);
                    }
                }
            } else if (fw != NULL) {
                const char *ver_a = strstr(fw, ".framework/Versions/A/");
                if (ver_a != NULL) {
                    size_t prefix_len = (size_t)(ver_a + 10 - canon);
                    int sn = snprintf(stripped_ver_path, sizeof(stripped_ver_path), "%.*s%s",
                                      (int)prefix_len, canon, ver_a + 21);
                    if (sn > 0 && (size_t)sn < sizeof(stripped_ver_path)) {
                        pt_append_unique_cand_path(cand_paths, &cand_count, 6, stripped_ver_path);
                    }
                }
            }
            int isn = snprintf(ios_path, sizeof(ios_path), "/System/iOSSupport%s", canon);
            if (isn > 0 && (size_t)isn < sizeof(ios_path)) {
                pt_append_unique_cand_path(cand_paths, &cand_count, 6, ios_path);
            }
        }

        const char **arrays[6] = { NULL, NULL, NULL, NULL, NULL, NULL };
        unsigned int counts[6] = { 0, 0, 0, 0, 0, 0 };
        size_t total_raw = 0;
        size_t non_null_arrays = 0;
        size_t first_idx = 0;
        for (size_t c = 0; c < cand_count; c++) {
            const char *cp = cand_paths[c];
            if (cp == NULL) {
                continue;
            }
            arrays[c] = objc_copyClassNamesForImage(cp, &counts[c]);
            if (arrays[c] != NULL) {
                if (non_null_arrays == 0) {
                    first_idx = c;
                }
                non_null_arrays++;
                total_raw += counts[c];
            }
        }

        const char **names = NULL;
        unsigned int count = 0;
        if (non_null_arrays == 1) {
            names = arrays[first_idx];
            count = counts[first_idx];
        } else if (non_null_arrays > 1) {
            names = (const char **)malloc((total_raw + 1U) * sizeof(const char *));
            if (names != NULL) {
                size_t ht_cap = 64U;
                while (ht_cap < total_raw * 2U && ht_cap < (1U << 22)) {
                    ht_cap <<= 1U;
                }
                const char **ht = (const char **)calloc(ht_cap, sizeof(const char *));
                size_t ht_mask = ht_cap - 1U;
                for (size_t c = 0; c < cand_count; c++) {
                    if (arrays[c] == NULL) {
                        continue;
                    }
                    for (unsigned int k = 0; k < counts[c]; k++) {
                        const char *cname = arrays[c][k];
                        if (cname == NULL) {
                            continue;
                        }
                        BOOL dup = NO;
                        if (ht != NULL) {
                            size_t slot = (size_t)pt_fnv1a_cstr(cname) & ht_mask;
                            for (size_t probe = 0; probe < ht_cap; probe++) {
                                const char *entry = ht[slot];
                                if (entry == NULL) {
                                    ht[slot] = cname;
                                    break;
                                }
                                if (entry == cname || strcmp(entry, cname) == 0) {
                                    dup = YES;
                                    break;
                                }
                                slot = (slot + 1U) & ht_mask;
                            }
                        } else {
                            for (unsigned int m = 0; m < count; m++) {
                                if (names[m] == cname || strcmp(names[m], cname) == 0) {
                                    dup = YES;
                                    break;
                                }
                            }
                        }
                        if (!dup) {
                            names[count++] = cname;
                        }
                    }
                    free((void *)arrays[c]);
                }
                free((void *)ht);
                names[count] = NULL;
            } else {
                for (size_t c = 0; c < cand_count; c++) {
                    free((void *)arrays[c]);
                }
            }
        }

        if (names != NULL) {
            unsigned int writeIdx = pt_filter_class_names_in_place(names, count);
            if (outCount != NULL) {
                *outCount = writeIdx;
            }
        } else if (outCount != NULL) {
            *outCount = 0;
        }
        return names;
    }
    return objc_copyClassNamesForImage(image, outCount);
}

extern const char **pt_orig_objc_copyClassNamesForImageHeader(const void *mh, unsigned int *outCount)
    __asm__("_objc_copyClassNamesForImageHeader") __attribute__((weak_import));
static const char *pt_dyld_lookup_image_name_for_mh(const struct mach_header *mh);

static const char **pt_objc_copyClassNamesForImageHeader(const void *mh, unsigned int *outCount) {
    if (pt_orig_objc_copyClassNamesForImageHeader == NULL || mh == NULL) {
        if (outCount != NULL) {
            *outCount = 0;
        }
        return NULL;
    }
    const struct mach_header *real_mh = pt_uncloak_shadow_mach_header((const struct mach_header *)mh);
    const void *caller = __builtin_return_address(0);
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
        const char *img_name = pt_dyld_lookup_image_name_for_mh(real_mh);
        if (pt_is_hidden_dyld_image_header(real_mh) ||
            (img_name != NULL && (pt_is_hidden_dyld_image_name(img_name) ||
                                  pt_is_post13_7_hidden_framework_path(img_name)))) {
            if (outCount != NULL) {
                *outCount = 0;
            }
            return NULL;
        }
        unsigned int count = 0;
        const char **names = pt_orig_objc_copyClassNamesForImageHeader((const void *)real_mh, &count);
        if (names != NULL) {
            unsigned int writeIdx = pt_filter_class_names_in_place(names, count);
            if (outCount != NULL) {
                *outCount = writeIdx;
            }
        } else if (outCount != NULL) {
            *outCount = 0;
        }
        return names;
    }
    return pt_orig_objc_copyClassNamesForImageHeader((const void *)real_mh, outCount);
}

static Class *pt_objc_copy_class_list_for_caller(unsigned int *outCount, const void *caller) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (classes != NULL && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        unsigned int writeIdx = 0;
        for (unsigned int i = 0; i < count; i++) {
            Class cls = classes[i];
            if (cls != Nil && pt_should_hide_resolved_objc_class(class_getName(cls), cls)) {
                continue;
            }
            classes[writeIdx++] = cls;
        }
        classes[writeIdx] = Nil;
        if (outCount != NULL) {
            *outCount = writeIdx;
        }
        return classes;
    }
    if (outCount != NULL) {
        *outCount = count;
    }
    return classes;
}

static Class *pt_objc_copyClassList(unsigned int *outCount) {
    return pt_objc_copy_class_list_for_caller(outCount, __builtin_return_address(0));
}

static int pt_objc_getClassList(Class *buffer, int bufferCount) {
    const void *caller = __builtin_return_address(0);
    if (!pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(caller)) {
        return objc_getClassList(buffer, bufferCount);
    }
    unsigned int count = 0;
    Class *classes = pt_objc_copy_class_list_for_caller(&count, caller);
    if (classes == NULL) {
        return 0;
    }
    if (buffer != NULL && bufferCount > 0) {
        int limit = (int)count < bufferCount ? (int)count : bufferCount;
        for (int i = 0; i < limit; i++) {
            buffer[i] = classes[i];
        }
    }
    free(classes);
    return (int)count;
}

static BOOL pt_class_is_or_inherits_from(Class cls, const char *targetName) {
    if (cls == Nil || targetName == NULL) {
        return NO;
    }
    for (Class cur = cls; cur != Nil; cur = class_getSuperclass(cur)) {
        const char *cname = class_getName(cur);
        if (cname != NULL && strcmp(cname, targetName) == 0) {
            return YES;
        }
    }
    return NO;
}

static BOOL pt_class_is_mtl_device(Class cls) {
    if (cls == Nil) {
        return NO;
    }
    if (pt_class_is_or_inherits_from(cls, "_MTLDevice")) {
        return YES;
    }
    const char *cname = class_getName(cls);
    return (cname != NULL &&
            strstr(cname, "Device") != NULL &&
            (strstr(cname, "MTL") != NULL || strstr(cname, "AGX") != NULL));
}

static BOOL pt_is_hidden_macos_only_method(Class cls, SEL sel, BOOL isClassMethod) {
    if (isClassMethod || cls == Nil || sel == NULL || !pt_is_bypass_enabled()) {
        return NO;
    }
    const char *sname = sel_getName(sel);
    if (sname == NULL || sname[0] == '\0') {
        return NO;
    }
    if (strcmp(sname, "isLowPower") == 0 ||
        strcmp(sname, "isHeadless") == 0 ||
        strcmp(sname, "isRemovable") == 0 ||
        strcmp(sname, "location") == 0 ||
        strcmp(sname, "locationNumber") == 0 ||
        strcmp(sname, "peerGroupID") == 0 ||
        strcmp(sname, "peerIndex") == 0 ||
        strcmp(sname, "peerCount") == 0) {
        return pt_class_is_mtl_device(cls);
    }
    return NO;
}

static BOOL pt_is_hidden_post13_7_method(Class cls, SEL sel, BOOL isClassMethod) {
    if (cls == Nil || sel == NULL || !pt_is_compat13_7_active() || !pt_is_bypass_enabled()) {
        return NO;
    }
    const char *sname = sel_getName(sel);
    if (sname == NULL || sname[0] == '\0') {
        return NO;
    }
    if (!isClassMethod) {
        if (strcmp(sname, "addAction:forControlEvents:") == 0 ||
            strcmp(sname, "removeAction:forControlEvents:") == 0 ||
            strcmp(sname, "removeActionForIdentifier:forControlEvents:") == 0 ||
            strcmp(sname, "enumerateEventHandlers:") == 0 ||
            strcmp(sname, "contextMenuInteraction") == 0 ||
            strcmp(sname, "isContextMenuInteractionEnabled") == 0 ||
            strcmp(sname, "setContextMenuInteractionEnabled:") == 0 ||
            strcmp(sname, "showsMenuAsPrimaryAction") == 0 ||
            strcmp(sname, "setShowsMenuAsPrimaryAction:") == 0) {
            return pt_class_is_or_inherits_from(cls, "UIControl");
        }
        if (strcmp(sname, "initWithFrame:primaryAction:") == 0 ||
            strcmp(sname, "menu") == 0 ||
            strcmp(sname, "setMenu:") == 0) {
            return pt_class_is_or_inherits_from(cls, "UIButton");
        }
        if (strcmp(sname, "isiOSAppOnMac") == 0 ||
            strcmp(sname, "isiOSAppOnVision") == 0) {
            return pt_class_is_or_inherits_from(cls, "NSProcessInfo") ||
                   pt_class_is_or_inherits_from(cls, "_NSSwiftProcessInfo");
        }
        if (strcmp(sname, "activeAppearance") == 0 ||
            strcmp(sname, "toolbarItemPresentationSize") == 0) {
            return pt_class_is_or_inherits_from(cls, "UITraitCollection");
        }
        if (strcmp(sname, "accuracyAuthorization") == 0 ||
            strcmp(sname, "requestTemporaryFullAccuracyAuthorizationWithPurposeKey:completion:") == 0) {
            return pt_class_is_or_inherits_from(cls, "CLLocationManager");
        }
        if (strcmp(sname, "architecture") == 0 ||
            strcmp(sname, "supportsRaytracing") == 0 ||
            strcmp(sname, "supportsRaytracingFromRender") == 0 ||
            strcmp(sname, "supportsPrimitiveMotionBlur") == 0 ||
            strcmp(sname, "supportsFunctionPointers") == 0 ||
            strcmp(sname, "supportsFunctionPointersFromRender") == 0 ||
            strcmp(sname, "supportsDynamicLibraries") == 0 ||
            strcmp(sname, "supportsRenderDynamicLibraries") == 0 ||
            strcmp(sname, "supportsPullModelInterpolation") == 0 ||
            strcmp(sname, "supportsShaderBarycentricCoordinates") == 0 ||
            strcmp(sname, "supportsQueryTextureLOD") == 0) {
            return pt_class_is_mtl_device(cls);
        }
    } else {
        if (strcmp(sname, "buttonWithType:primaryAction:") == 0 ||
            strcmp(sname, "systemButtonWithPrimaryAction:") == 0) {
            return pt_class_is_or_inherits_from(cls, "UIButton");
        }
        if (strcmp(sname, "actionWithHandler:") == 0) {
            return pt_class_is_or_inherits_from(cls, "UIAction");
        }
        if (strcmp(sname, "shouldMonitorBackgroundEvents") == 0 ||
            strcmp(sname, "setShouldMonitorBackgroundEvents:") == 0) {
            return pt_class_is_or_inherits_from(cls, "GCController");
        }
        if (strcmp(sname, "systemImageNamed:variableValue:withConfiguration:") == 0) {
            return pt_class_is_or_inherits_from(cls, "UIImage");
        }
    }
    return NO;
}

static BOOL pt_is_hidden_objc_property(Class cls, const char *pname) {
    if (cls == Nil || pname == NULL || pname[0] == '\0' || !pt_is_bypass_enabled()) {
        return NO;
    }
    if (strcmp(pname, "lowPower") == 0 ||
        strcmp(pname, "headless") == 0 ||
        strcmp(pname, "removable") == 0 ||
        strcmp(pname, "location") == 0 ||
        strcmp(pname, "locationNumber") == 0 ||
        strcmp(pname, "peerGroupID") == 0 ||
        strcmp(pname, "peerIndex") == 0 ||
        strcmp(pname, "peerCount") == 0) {
        return pt_class_is_mtl_device(cls);
    }
    if (!pt_is_compat13_7_active()) {
        return NO;
    }
    if (strcmp(pname, "iOSAppOnMac") == 0 ||
        strcmp(pname, "isiOSAppOnMac") == 0 ||
        strcmp(pname, "iOSAppOnVision") == 0 ||
        strcmp(pname, "isiOSAppOnVision") == 0) {
        return pt_class_is_or_inherits_from(cls, "NSProcessInfo") ||
               pt_class_is_or_inherits_from(cls, "_NSSwiftProcessInfo");
    }
    if (strcmp(pname, "showsMenuAsPrimaryAction") == 0 ||
        strcmp(pname, "contextMenuInteraction") == 0 ||
        strcmp(pname, "contextMenuInteractionEnabled") == 0) {
        return pt_class_is_or_inherits_from(cls, "UIControl");
    }
    if (strcmp(pname, "menu") == 0) {
        return pt_class_is_or_inherits_from(cls, "UIButton");
    }
    if (strcmp(pname, "shouldMonitorBackgroundEvents") == 0) {
        return pt_class_is_or_inherits_from(cls, "GCController");
    }
    if (strcmp(pname, "activeAppearance") == 0 ||
        strcmp(pname, "toolbarItemPresentationSize") == 0) {
        return pt_class_is_or_inherits_from(cls, "UITraitCollection");
    }
    if (strcmp(pname, "accuracyAuthorization") == 0) {
        return pt_class_is_or_inherits_from(cls, "CLLocationManager");
    }
    if (strcmp(pname, "architecture") == 0 ||
        strcmp(pname, "supportsDynamicLibraries") == 0 ||
        strcmp(pname, "supportsRenderDynamicLibraries") == 0 ||
        strcmp(pname, "supportsRaytracing") == 0 ||
        strcmp(pname, "supportsRaytracingFromRender") == 0 ||
        strcmp(pname, "supportsPrimitiveMotionBlur") == 0 ||
        strcmp(pname, "supportsFunctionPointers") == 0 ||
        strcmp(pname, "supportsFunctionPointersFromRender") == 0 ||
        strcmp(pname, "supportsPullModelInterpolation") == 0 ||
        strcmp(pname, "supportsShaderBarycentricCoordinates") == 0 ||
        strcmp(pname, "supportsQueryTextureLOD") == 0) {
        return pt_class_is_mtl_device(cls);
    }
    return NO;
}

static inline BOOL pt_is_playtools_injected_method(Method m, SEL sel) {
    if (m == NULL || sel == NULL) {
        return NO;
    }
    if (!pt_is_registered_hidden_swizzle_selector(sel) &&
        !pt_is_hidden_objc_selector_name(sel_getName(sel))) {
        return NO;
    }
    const void *imp = (const void *)method_getImplementation(m);
    return pt_is_address_in_playtools(imp) || pt_is_swizzled_orig_imp(imp);
}

static Method pt_class_getInstanceMethod(Class cls, SEL name) {
    if (!pt_is_valid_user_pointer((__bridge const void *)cls) ||
        !pt_is_valid_user_pointer((const void *)name)) {
        return NULL;
    }
    const void *caller = __builtin_return_address(0);
    int is_sys_caller = -1;
    if (pt_is_bypass_enabled()) {
        BOOL isMeta = class_isMetaClass(cls);
        if (pt_is_hidden_post13_7_method(cls, name, isMeta) ||
            pt_is_hidden_macos_only_method(cls, name, isMeta)) {
            is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
            if (is_sys_caller == 0) {
                return NULL;
            }
        }
    }
    Method m = class_getInstanceMethod(cls, name);
    if (m != NULL && pt_is_bypass_enabled() && pt_is_playtools_injected_method(m, name)) {
        if (is_sys_caller < 0) {
            is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
        }
        if (is_sys_caller == 0) {
            return NULL;
        }
    }
    return m;
}

static Method pt_class_getClassMethod(Class cls, SEL name) {
    if (!pt_is_valid_user_pointer((__bridge const void *)cls) ||
        !pt_is_valid_user_pointer((const void *)name)) {
        return NULL;
    }
    const void *caller = __builtin_return_address(0);
    int is_sys_caller = -1;
    if (pt_is_bypass_enabled() && pt_is_hidden_post13_7_method(cls, name, YES)) {
        is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
        if (is_sys_caller == 0) {
            return NULL;
        }
    }
    Method m = class_getClassMethod(cls, name);
    if (m != NULL && pt_is_bypass_enabled() && pt_is_playtools_injected_method(m, name)) {
        if (is_sys_caller < 0) {
            is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
        }
        if (is_sys_caller == 0) {
            return NULL;
        }
    }
    return m;
}

static IMP pt_method_getImplementation(Method m) {
    if (m == NULL) {
        return NULL;
    }
    IMP imp = method_getImplementation(m);
    if (imp != NULL && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        SEL sel = method_getName(m);
        if (sel != NULL && pt_is_playtools_injected_method(m, sel)) {
            return NULL;
        }
        const void *orig = pt_lookup_swizzled_raw_orig_imp((const void *)imp);
        if (orig != NULL) {
            return (IMP)orig;
        }
    }
    return imp;
}

static IMP pt_class_getMethodImplementation(Class cls, SEL name) {
    if (!pt_is_valid_user_pointer((__bridge const void *)cls) ||
        !pt_is_valid_user_pointer((const void *)name)) {
        return NULL;
    }
    const void *caller = __builtin_return_address(0);
    int is_sys_caller = -1;
    if (pt_is_bypass_enabled()) {
        BOOL isMeta = class_isMetaClass(cls);
        if (pt_is_hidden_post13_7_method(cls, name, isMeta) ||
            pt_is_hidden_macos_only_method(cls, name, isMeta)) {
            is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
            if (is_sys_caller == 0) {
                return class_getMethodImplementation(cls, sel_registerName("__pt_ps_nonexistent_sel_lookup__"));
            }
        }
    }
    IMP imp = class_getMethodImplementation(cls, name);
    if (imp != NULL && pt_is_bypass_enabled()) {
        if (is_sys_caller < 0) {
            is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
        }
        if (is_sys_caller == 0) {
            Method m = class_getInstanceMethod(cls, name);
            if (m != NULL && pt_is_playtools_injected_method(m, name)) {
                return class_getMethodImplementation(cls, sel_registerName("__pt_ps_nonexistent_sel_lookup__"));
            }
            const void *orig = pt_lookup_swizzled_raw_orig_imp((const void *)imp);
            if (orig != NULL) {
                return (IMP)orig;
            }
        }
    }
    return imp;
}

static Method *pt_class_copyMethodList(Class cls, unsigned int *outCount) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (methods != NULL && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        BOOL isMeta = class_isMetaClass(cls);
        unsigned int writeIdx = 0;
        for (unsigned int i = 0; i < count; i++) {
            Method m = methods[i];
            if (m != NULL) {
                SEL sel = method_getName(m);
                if (sel != NULL &&
                    (pt_is_playtools_injected_method(m, sel) ||
                     pt_is_hidden_post13_7_method(cls, sel, isMeta) ||
                     pt_is_hidden_macos_only_method(cls, sel, isMeta))) {
                    continue;
                }
            }
            methods[writeIdx++] = m;
        }
        methods[writeIdx] = NULL;
        if (outCount != NULL) {
            *outCount = writeIdx;
        }
        return methods;
    }
    if (outCount != NULL) {
        *outCount = count;
    }
    return methods;
}

static BOOL pt_class_respondsToSelector(Class cls, SEL sel) {
    if (!pt_is_valid_user_pointer((__bridge const void *)cls) ||
        !pt_is_valid_user_pointer((const void *)sel)) {
        return NO;
    }
    const void *caller = __builtin_return_address(0);
    int is_sys_caller = -1;
    if (pt_is_bypass_enabled()) {
        BOOL isMeta = class_isMetaClass(cls);
        if (pt_is_hidden_post13_7_method(cls, sel, isMeta) ||
            pt_is_hidden_macos_only_method(cls, sel, isMeta)) {
            is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
            if (is_sys_caller == 0) {
                return NO;
            }
        }
    }
    BOOL orig = class_respondsToSelector(cls, sel);
    if (orig && pt_is_bypass_enabled()) {
        Method m = class_getInstanceMethod(cls, sel);
        if (m != NULL && pt_is_playtools_injected_method(m, sel)) {
            if (is_sys_caller < 0) {
                is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
            }
            if (is_sys_caller == 0) {
                return NO;
            }
        }
    }
    return orig;
}

static objc_property_t pt_class_getProperty(Class cls, const char *name) {
    if (!pt_is_valid_user_pointer((__bridge const void *)cls) ||
        !pt_is_valid_user_pointer(name)) {
        return NULL;
    }
    if (pt_is_hidden_objc_property(cls, name) &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NULL;
    }
    return class_getProperty(cls, name);
}

static objc_property_t *pt_class_copyPropertyList(Class cls, unsigned int *outCount) {
    unsigned int count = 0;
    objc_property_t *props = class_copyPropertyList(cls, &count);
    if (props != NULL && count > 0 && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        unsigned int writeIdx = 0;
        for (unsigned int i = 0; i < count; i++) {
            objc_property_t p = props[i];
            const char *pname = (p != NULL) ? property_getName(p) : NULL;
            if (pname != NULL && pt_is_hidden_objc_property(cls, pname)) {
                continue;
            }
            props[writeIdx++] = p;
        }
        props[writeIdx] = NULL;
        if (outCount != NULL) {
            *outCount = writeIdx;
        }
        return props;
    }
    if (outCount != NULL) {
        *outCount = count;
    }
    return props;
}

static const char *pt_class_getName(Class cls) {
    const char *orig = class_getName(cls);
    if (orig != NULL &&
        orig[0] == '_' &&
        pt_is_compat13_7_active() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        strcmp(orig, "_NSSwiftProcessInfo") == 0) {
        return "NSProcessInfo";
    }
    return orig;
}

static const char *pt_object_getClassName(id obj) {
    const char *orig = object_getClassName(obj);
    if (orig != NULL &&
        orig[0] == '_' &&
        pt_is_compat13_7_active() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        strcmp(orig, "_NSSwiftProcessInfo") == 0) {
        return "NSProcessInfo";
    }
    return orig;
}

extern NSString *pt_orig_NSStringFromClass(Class aClass) __asm__("_NSStringFromClass");

static NSString *pt_NSStringFromClass(Class aClass) {
    if (aClass != Nil &&
        pt_is_compat13_7_active() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        const char *raw = class_getName(aClass);
        if (raw != NULL && raw[0] == '_' && strcmp(raw, "_NSSwiftProcessInfo") == 0) {
            return @"NSProcessInfo";
        }
    }
    return pt_orig_NSStringFromClass(aClass);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
extern int32_t NSVersionOfRunTimeLibrary(const char *libraryName);
extern int32_t NSVersionOfLinkTimeLibrary(const char *libraryName);

static int32_t pt_compat13_library_version(const char *libraryName) {
    if (libraryName == NULL || libraryName[0] == '\0') {
        return -1;
    }
    if (strcmp(libraryName, "Foundation") == 0 || strcmp(libraryName, "CoreFoundation") == 0) {
        return (1677 << 16) | (104 << 8);
    }
    if (strcmp(libraryName, "UIKit") == 0 || strcmp(libraryName, "UIKitCore") == 0) {
        return (3698 << 16) | (54 << 8);
    }
    if (strcmp(libraryName, "WebKit") == 0 || strcmp(libraryName, "JavaScriptCore") == 0) {
        return (609 << 16) | (4 << 8);
    }
    if (strcmp(libraryName, "CFNetwork") == 0) {
        return (1128 << 16);
    }
    if (strcmp(libraryName, "CoreGraphics") == 0) {
        return (1355 << 16) | (13 << 8);
    }
    if (strcmp(libraryName, "QuartzCore") == 0) {
        return (841 << 16) | (20 << 8);
    }
    if (strcmp(libraryName, "Metal") == 0) {
        return (212 << 16) | (7 << 8);
    }
    if (strcmp(libraryName, "CoreMotion") == 0) {
        return (2418 << 16) | (2 << 8);
    }
    if (strcmp(libraryName, "AVFoundation") == 0) {
        return (1800 << 16) | (12 << 8);
    }
    if (strcmp(libraryName, "Security") == 0) {
        return (59306 << 16) | (140 << 8);
    }
    if (strcmp(libraryName, "System") == 0 || strcmp(libraryName, "libSystem.B") == 0) {
        return (1281 << 16) | (100 << 8);
    }
    if (strcmp(libraryName, "objc") == 0 || strcmp(libraryName, "libobjc.A") == 0) {
        return (781 << 16) | (2 << 8);
    }
    if (strcmp(libraryName, "Photos") == 0) {
        return (161 << 16);
    }
    if (strcmp(libraryName, "GameController") == 0) {
        return (101 << 16);
    }
    return -1;
}

static int32_t pt_NSVersionOfRunTimeLibrary(const char *libraryName) {
    if (libraryName != NULL &&
        pt_is_compat13_7_active() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        int32_t spoofed = pt_compat13_library_version(libraryName);
        if (spoofed != -1) {
            return spoofed;
        }
    }
    return NSVersionOfRunTimeLibrary(libraryName);
}

static int32_t pt_NSVersionOfLinkTimeLibrary(const char *libraryName) {
    int32_t orig = NSVersionOfLinkTimeLibrary(libraryName);
    if (orig != -1 &&
        libraryName != NULL &&
        pt_is_compat13_7_active() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        int32_t spoofed = pt_compat13_library_version(libraryName);
        if (spoofed != -1) {
            return spoofed;
        }
    }
    return orig;
}
#pragma clang diagnostic pop

static uint32_t pt_dyld_image_count(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return pt_dyld_virtual_count();
    }
    return _dyld_image_count();
}

static const char *pt_dyld_get_image_name(uint32_t image_index) {
    const void *caller = __builtin_return_address(0);
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
        uint32_t real_idx = 0;
        if (!pt_dyld_virtual_to_real_index(image_index, &real_idx)) {
            return NULL;
        }
        const char *name = _dyld_get_image_name(real_idx);
        if (name != NULL) {
            return pt_sanitize_image_path_for_app(name);
        }
        return name;
    }
    return _dyld_get_image_name(image_index);
}

#ifndef MH_DYLIB_IN_CACHE
#define MH_DYLIB_IN_CACHE 0x80000000U
#endif

#define PT_MAX_SHADOW_MACH_HEADERS 256U

typedef struct {
    const struct mach_header *real_mh;
    const struct mach_header *shadow_mh;
    vm_size_t alloc_size;
} pt_shadow_mach_header_entry_t;

static os_unfair_lock s_shadow_mh_lock = OS_UNFAIR_LOCK_INIT;
static pt_shadow_mach_header_entry_t s_shadow_mh_entries[PT_MAX_SHADOW_MACH_HEADERS];
static uint32_t s_shadow_mh_count = 0;
static _Atomic uint32_t s_shadow_mh_count_atomic = 0;

static BOOL pt_lc_dylib_name_should_drop(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return NO;
    }
    return pt_is_hidden_dyld_image_name(name) ||
           strstr(name, "/Users/") != NULL ||
           strcasestr(name, "PlayCover") != NULL ||
           strcasestr(name, "MacOver") != NULL ||
           strcasestr(name, "app.makedie") != NULL;
}

static BOOL pt_mach_header_64_needs_shadow(const struct mach_header_64 *mh) {
    if (mh == NULL || mh->magic != MH_MAGIC_64 || (mh->flags & MH_DYLIB_IN_CACHE) != 0) {
        return NO;
    }
    if (mh->sizeofcmds == 0 || mh->sizeofcmds > (1U << 20)) {
        return NO;
    }
    const uint8_t *base = (const uint8_t *)mh;
    size_t total = sizeof(struct mach_header_64) + (size_t)mh->sizeofcmds;
    size_t off = sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < mh->ncmds && off + sizeof(struct load_command) <= total; i++) {
        const struct load_command *lc = (const struct load_command *)(base + off);
        if (lc->cmdsize < sizeof(struct load_command) || off + lc->cmdsize > total) {
            break;
        }
        if (lc->cmd == LC_BUILD_VERSION && lc->cmdsize >= sizeof(struct build_version_command)) {
            const struct build_version_command *bv = (const struct build_version_command *)lc;
            if (bv->platform == PLATFORM_MACCATALYST || bv->platform == 1U ||
                (pt_is_compat13_7_active() && (bv->minos > 0x0d0700U || bv->sdk > 0x0d0700U))) {
                return YES;
            }
        } else if (lc->cmd == LC_VERSION_MIN_MACOSX) {
            return YES;
        } else if ((lc->cmd == LC_LOAD_DYLIB || lc->cmd == LC_LOAD_WEAK_DYLIB ||
                    lc->cmd == LC_REEXPORT_DYLIB || lc->cmd == LC_LOAD_UPWARD_DYLIB ||
                    lc->cmd == LC_LAZY_LOAD_DYLIB || lc->cmd == LC_ID_DYLIB) &&
                   lc->cmdsize >= sizeof(struct dylib_command)) {
            const struct dylib_command *dc = (const struct dylib_command *)lc;
            uint32_t noff = dc->dylib.name.offset;
            if (noff >= sizeof(struct dylib_command) && noff < lc->cmdsize) {
                char nbuf[PATH_MAX];
                size_t maxn = lc->cmdsize - noff;
                size_t slen = strnlen((const char *)lc + noff, maxn);
                if (slen < sizeof(nbuf)) {
                    memcpy(nbuf, (const char *)lc + noff, slen);
                    nbuf[slen] = '\0';
                    if (pt_lc_dylib_name_should_drop(nbuf) ||
                        strncmp(nbuf, "/System/iOSSupport/", 19) == 0) {
                        return YES;
                    }
                }
            }
        } else if (lc->cmd == LC_RPATH && lc->cmdsize >= sizeof(struct rpath_command)) {
            const struct rpath_command *rc = (const struct rpath_command *)lc;
            uint32_t poff = rc->path.offset;
            if (poff >= sizeof(struct rpath_command) && poff < lc->cmdsize) {
                char pbuf[PATH_MAX];
                size_t maxp = lc->cmdsize - poff;
                size_t slen = strnlen((const char *)lc + poff, maxp);
                if (slen < sizeof(pbuf)) {
                    memcpy(pbuf, (const char *)lc + poff, slen);
                    pbuf[slen] = '\0';
                    if (pt_lc_dylib_name_should_drop(pbuf) ||
                        strncmp(pbuf, "/System/iOSSupport", 18) == 0) {
                        return YES;
                    }
                }
            }
        }
        off += lc->cmdsize;
    }
    return NO;
}

static BOOL pt_header_has_ios_or_catalyst_build_version(const struct mach_header_64 *mh) {
    const uint8_t *base = (const uint8_t *)mh;
    size_t total = sizeof(struct mach_header_64) + (size_t)mh->sizeofcmds;
    size_t off = sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < mh->ncmds && off + sizeof(struct load_command) <= total; i++) {
        const struct load_command *lc = (const struct load_command *)(base + off);
        if (lc->cmdsize < sizeof(struct load_command) || off + lc->cmdsize > total) {
            break;
        }
        if (lc->cmd == LC_BUILD_VERSION && lc->cmdsize >= sizeof(struct build_version_command)) {
            const struct build_version_command *bv = (const struct build_version_command *)lc;
            if (bv->platform == PLATFORM_IOS || bv->platform == PLATFORM_MACCATALYST) {
                return YES;
            }
        }
        off += lc->cmdsize;
    }
    return NO;
}

__attribute__((visibility("hidden")))
BOOL pt_build_sanitized_mach_header_copy(const struct mach_header_64 *src_mh,
                                         uint8_t *dst_buf,
                                         size_t dst_cap,
                                         size_t *out_sanitized_len) {
    if (src_mh == NULL || dst_buf == NULL || !pt_is_valid_user_pointer(src_mh) ||
        src_mh->magic != MH_MAGIC_64 ||
        src_mh->sizeofcmds == 0 || src_mh->sizeofcmds > (1U << 20)) {
        return NO;
    }
    size_t total = sizeof(struct mach_header_64) + (size_t)src_mh->sizeofcmds;
    if (dst_cap < total) {
        return NO;
    }
    memset(dst_buf, 0, total);

    const uint8_t *src = (const uint8_t *)src_mh;
    struct mach_header_64 new_hdr = *src_mh;
    BOOL prefer_ios_or_catalyst = pt_header_has_ios_or_catalyst_build_version(src_mh);
    BOOL emitted_build_version = NO;
    size_t write_off = sizeof(struct mach_header_64);
    uint32_t new_ncmds = 0;
    size_t read_off = sizeof(struct mach_header_64);

    for (uint32_t i = 0; i < src_mh->ncmds && read_off + sizeof(struct load_command) <= total; i++) {
        const struct load_command *lc = (const struct load_command *)(src + read_off);
        if (lc->cmdsize < sizeof(struct load_command) || read_off + lc->cmdsize > total) {
            break;
        }
        uint32_t cmd = lc->cmd;
        uint32_t cmdsize = lc->cmdsize;
        read_off += cmdsize;

        if (cmd == LC_BUILD_VERSION && cmdsize >= sizeof(struct build_version_command)) {
            const struct build_version_command *src_bv = (const struct build_version_command *)lc;
            uint32_t plat = src_bv->platform;
            if (plat == 1U || plat == 7U || plat == PLATFORM_MACCATALYST || plat == PLATFORM_IOS) {
                if (prefer_ios_or_catalyst && (plat == 1U || plat == 7U)) {
                    continue;
                }
                if (emitted_build_version) {
                    continue;
                }
                if (write_off + cmdsize > total) {
                    return NO;
                }
                memcpy(dst_buf + write_off, lc, cmdsize);
                struct build_version_command *bv = (struct build_version_command *)(dst_buf + write_off);
                if (bv->platform != PLATFORM_IOS) {
                    bv->platform = PLATFORM_IOS;
                }
                if (pt_is_compat13_7_active()) {
                    if (bv->minos > 0x0d0700U) {
                        bv->minos = 0x0d0700U;
                    }
                    if (bv->sdk > 0x0d0700U) {
                        bv->sdk = 0x0d0700U;
                    }
                }
                emitted_build_version = YES;
                write_off += cmdsize;
                new_ncmds++;
                continue;
            }
        }
        if (cmd == LC_VERSION_MIN_MACOSX && cmdsize >= sizeof(struct version_min_command)) {
            if (write_off + cmdsize > total) {
                return NO;
            }
            memcpy(dst_buf + write_off, lc, cmdsize);
            struct version_min_command *vmc = (struct version_min_command *)(dst_buf + write_off);
            vmc->cmd = LC_VERSION_MIN_IPHONEOS;
            write_off += cmdsize;
            new_ncmds++;
            continue;
        }
        if (cmd == LC_LOAD_DYLIB || cmd == LC_LOAD_WEAK_DYLIB ||
            cmd == LC_REEXPORT_DYLIB || cmd == LC_LOAD_UPWARD_DYLIB ||
            cmd == LC_LAZY_LOAD_DYLIB || cmd == LC_ID_DYLIB) {
            if (cmdsize < sizeof(struct dylib_command)) {
                continue;
            }
            const struct dylib_command *dc = (const struct dylib_command *)lc;
            uint32_t noff = dc->dylib.name.offset;
            if (noff < sizeof(struct dylib_command) || noff >= cmdsize) {
                continue;
            }
            char nbuf[PATH_MAX];
            size_t maxn = cmdsize - noff;
            size_t slen = strnlen((const char *)lc + noff, maxn);
            if (slen >= sizeof(nbuf)) {
                continue;
            }
            memcpy(nbuf, (const char *)lc + noff, slen);
            nbuf[slen] = '\0';
            char rewritten[PATH_MAX];
            const char *replacement = NULL;
            if (pt_lc_dylib_name_should_drop(nbuf)) {
                if (cmd != LC_ID_DYLIB) {
                    continue;
                }
                static const char kFallbackIdDylib[] = "/usr/lib/libobjc.A.dylib";
                static const char kTinyIdDylib[] = "/usr/lib/dyld";
                static const char kMicroIdDylib[] = "/a";
                size_t fb_aligned = (sizeof(struct dylib_command) + sizeof(kFallbackIdDylib) + 7U) & ~7ULL;
                size_t tiny_aligned = (sizeof(struct dylib_command) + sizeof(kTinyIdDylib) + 7U) & ~7ULL;
                if (fb_aligned <= (size_t)cmdsize) {
                    replacement = kFallbackIdDylib;
                } else if (tiny_aligned <= (size_t)cmdsize) {
                    replacement = kTinyIdDylib;
                } else {
                    replacement = kMicroIdDylib;
                }
            }
            if (replacement == NULL && strncmp(nbuf, "/System/iOSSupport/usr/lib/swift/libswift", 41) == 0) {
                snprintf(rewritten, sizeof(rewritten), "@rpath/%s", nbuf + 33);
                replacement = rewritten;
            } else if (replacement == NULL && strncmp(nbuf, "/System/iOSSupport/", 19) == 0) {
                replacement = nbuf + 18;
            }
            if (replacement != NULL) {
                size_t rlen = strlen(replacement);
                size_t raw_sz = sizeof(struct dylib_command) + rlen + 1U;
                size_t aligned_sz = (raw_sz + 7U) & ~7ULL;
                if ((aligned_sz <= (size_t)cmdsize || cmd == LC_ID_DYLIB) && write_off + aligned_sz <= total) {
                    struct dylib_command ndc = *dc;
                    ndc.cmdsize = (uint32_t)aligned_sz;
                    ndc.dylib.name.offset = (uint32_t)sizeof(struct dylib_command);
                    memcpy(dst_buf + write_off, &ndc, sizeof(ndc));
                    memcpy(dst_buf + write_off + sizeof(ndc), replacement, rlen + 1U);
                    write_off += aligned_sz;
                    new_ncmds++;
                }
                continue;
            }
        }
        if (cmd == LC_RPATH) {
            if (cmdsize < sizeof(struct rpath_command)) {
                continue;
            }
            const struct rpath_command *rc = (const struct rpath_command *)lc;
            uint32_t poff = rc->path.offset;
            if (poff < sizeof(struct rpath_command) || poff >= cmdsize) {
                continue;
            }
            char pbuf[PATH_MAX];
            size_t maxp = cmdsize - poff;
            size_t slen = strnlen((const char *)lc + poff, maxp);
            if (slen >= sizeof(pbuf)) {
                continue;
            }
            memcpy(pbuf, (const char *)lc + poff, slen);
            pbuf[slen] = '\0';
            if (pt_lc_dylib_name_should_drop(pbuf) ||
                strncmp(pbuf, "/System/iOSSupport", 18) == 0) {
                continue;
            }
        }
        if (write_off + cmdsize > total) {
            return NO;
        }
        memcpy(dst_buf + write_off, lc, cmdsize);
        write_off += cmdsize;
        new_ncmds++;
    }

    new_hdr.ncmds = new_ncmds;
    new_hdr.sizeofcmds = (uint32_t)(write_off - sizeof(struct mach_header_64));
    memcpy(dst_buf, &new_hdr, sizeof(new_hdr));
    if (out_sanitized_len != NULL) {
        *out_sanitized_len = write_off;
    }
    return YES;
}

static const struct mach_header *pt_build_shadow_mach_header_locked(const struct mach_header_64 *src_mh,
                                                                    vm_size_t *out_alloc_size) {
    size_t total = sizeof(struct mach_header_64) + (size_t)src_mh->sizeofcmds;
    vm_size_t page_sz = (vm_page_size > 0) ? (vm_size_t)vm_page_size : 16384U;
    vm_size_t alloc_sz = ((vm_size_t)total + page_sz - 1U) & ~(page_sz - 1U);
    vm_address_t vm_addr = 0;
    if (vm_allocate(mach_task_self(), &vm_addr, alloc_sz, VM_FLAGS_ANYWHERE) != KERN_SUCCESS || vm_addr == 0) {
        return NULL;
    }
    uint8_t *dst = (uint8_t *)(uintptr_t)vm_addr;
    memset(dst, 0, (size_t)alloc_sz);
    if (!pt_build_sanitized_mach_header_copy(src_mh, dst, (size_t)alloc_sz, NULL)) {
        (void)vm_deallocate(mach_task_self(), vm_addr, alloc_sz);
        return NULL;
    }
    (void)vm_protect(mach_task_self(), vm_addr, alloc_sz, FALSE, VM_PROT_READ);
    if (out_alloc_size != NULL) {
        *out_alloc_size = alloc_sz;
    }
    return (const struct mach_header *)dst;
}

__attribute__((visibility("hidden")))
const struct mach_header *pt_maybe_shadow_mach_header(const struct mach_header *real_mh) {
    if (real_mh == NULL || !pt_is_valid_user_pointer((const void *)real_mh)) {
        return real_mh;
    }
    if (atomic_load_explicit(&s_shadow_mh_count_atomic, memory_order_acquire) > 0) {
        os_unfair_lock_lock(&s_shadow_mh_lock);
        for (uint32_t i = 0; i < s_shadow_mh_count; i++) {
            if (s_shadow_mh_entries[i].real_mh == real_mh ||
                s_shadow_mh_entries[i].shadow_mh == real_mh) {
                const struct mach_header *res = s_shadow_mh_entries[i].shadow_mh;
                os_unfair_lock_unlock(&s_shadow_mh_lock);
                return res;
            }
        }
        os_unfair_lock_unlock(&s_shadow_mh_lock);
    }

    const struct mach_header_64 *mh64 = (const struct mach_header_64 *)real_mh;
    if (!pt_mach_header_64_needs_shadow(mh64)) {
        return real_mh;
    }

    os_unfair_lock_lock(&s_shadow_mh_lock);
    for (uint32_t i = 0; i < s_shadow_mh_count; i++) {
        if (s_shadow_mh_entries[i].real_mh == real_mh) {
            const struct mach_header *res = s_shadow_mh_entries[i].shadow_mh;
            os_unfair_lock_unlock(&s_shadow_mh_lock);
            return res;
        }
    }
    const struct mach_header *shadow = real_mh;
    if (s_shadow_mh_count < PT_MAX_SHADOW_MACH_HEADERS) {
        vm_size_t alloc_sz = 0;
        const struct mach_header *built = pt_build_shadow_mach_header_locked(mh64, &alloc_sz);
        if (built != NULL) {
            s_shadow_mh_entries[s_shadow_mh_count++] = (pt_shadow_mach_header_entry_t){
                .real_mh = real_mh,
                .shadow_mh = built,
                .alloc_size = alloc_sz
            };
            atomic_store_explicit(&s_shadow_mh_count_atomic, s_shadow_mh_count, memory_order_release);
            shadow = built;
        }
    }
    os_unfair_lock_unlock(&s_shadow_mh_lock);
    return shadow;
}

__attribute__((visibility("hidden")))
const struct mach_header *pt_uncloak_shadow_mach_header(const struct mach_header *mh) {
    if (mh == NULL || atomic_load_explicit(&s_shadow_mh_count_atomic, memory_order_acquire) == 0) {
        return mh;
    }
    os_unfair_lock_lock(&s_shadow_mh_lock);
    for (uint32_t i = 0; i < s_shadow_mh_count; i++) {
        if (s_shadow_mh_entries[i].shadow_mh == mh) {
            const struct mach_header *real_mh = s_shadow_mh_entries[i].real_mh;
            os_unfair_lock_unlock(&s_shadow_mh_lock);
            return real_mh;
        }
    }
    os_unfair_lock_unlock(&s_shadow_mh_lock);
    return mh;
}

__attribute__((visibility("hidden")))
BOOL pt_is_hidden_vm_region_range(uintptr_t addr, uintptr_t size) {
    if (addr == 0) {
        return NO;
    }
    if (atomic_load_explicit(&s_shadow_mh_count_atomic, memory_order_acquire) > 0) {
        uintptr_t end = (size > 0 && addr + size > addr) ? (addr + size) : (addr + 1U);
        os_unfair_lock_lock(&s_shadow_mh_lock);
        for (uint32_t i = 0; i < s_shadow_mh_count; i++) {
            uintptr_t sbase = (uintptr_t)s_shadow_mh_entries[i].shadow_mh;
            uintptr_t send = sbase + (uintptr_t)s_shadow_mh_entries[i].alloc_size;
            if (addr < send && end > sbase) {
                os_unfair_lock_unlock(&s_shadow_mh_lock);
                return YES;
            }
        }
        os_unfair_lock_unlock(&s_shadow_mh_lock);
    }

    const struct mach_header *mh = dyld_image_header_containing_address((const void *)addr);
    if (mh != NULL && pt_is_hidden_dyld_image_header(mh)) {
        return YES;
    }
    const char *path = dyld_image_path_containing_address((const void *)addr);
    if (path != NULL && pt_should_hide_dyld_image(path)) {
        return YES;
    }
    return NO;
}

static uint8_t *pt_getsectiondata(const struct mach_header_64 *mhp,
                                  const char *segname,
                                  const char *sectname,
                                  unsigned long *size) {
    const struct mach_header_64 *real_mh =
        (const struct mach_header_64 *)pt_uncloak_shadow_mach_header((const struct mach_header *)mhp);
    return getsectiondata(real_mh, segname, sectname, size);
}

static uint8_t *pt_getsegmentdata(const struct mach_header_64 *mhp,
                                  const char *segname,
                                  unsigned long *size) {
    const struct mach_header_64 *real_mh =
        (const struct mach_header_64 *)pt_uncloak_shadow_mach_header((const struct mach_header *)mhp);
    return getsegmentdata(real_mh, segname, size);
}

static char *pt_getsectdatafromheader_64(const struct mach_header_64 *mhp,
                                         const char *segname,
                                         const char *sectname,
                                         uint64_t *size) {
    const struct mach_header_64 *real_mh =
        (const struct mach_header_64 *)pt_uncloak_shadow_mach_header((const struct mach_header *)mhp);
    return getsectdatafromheader_64(real_mh, segname, sectname, size);
}

static const struct mach_header *pt_dyld_get_image_header(uint32_t image_index) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        uint32_t real_idx = 0;
        if (!pt_dyld_virtual_to_real_index(image_index, &real_idx)) {
            return NULL;
        }
        return _dyld_get_image_header(real_idx);
    }
    return _dyld_get_image_header(image_index);
}

static intptr_t pt_dyld_get_image_vmaddr_slide(uint32_t image_index) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        uint32_t real_idx = 0;
        if (!pt_dyld_virtual_to_real_index(image_index, &real_idx)) {
            return 0;
        }
        return _dyld_get_image_vmaddr_slide(real_idx);
    }
    return _dyld_get_image_vmaddr_slide(image_index);
}

#define PT_MAX_APP_DYLD_CALLBACKS 64

typedef void (*pt_dyld_image_callback_t)(const struct mach_header *mh, intptr_t vmaddr_slide);

typedef struct {
    const struct mach_header *mh;
    intptr_t slide;
} pt_visible_dyld_image_t;

typedef struct {
    pt_dyld_image_callback_t func;
    BOOL replaying;
    pt_visible_dyld_image_t *queued;
    size_t queued_count;
    size_t queued_cap;
} pt_app_dyld_listener_t;

static pt_app_dyld_listener_t s_app_dyld_listeners[PT_MAX_APP_DYLD_CALLBACKS];
static uint32_t s_app_dyld_add_callback_count = 0;
static pt_dyld_image_callback_t s_app_dyld_remove_callbacks[PT_MAX_APP_DYLD_CALLBACKS];
static uint32_t s_app_dyld_remove_callback_count = 0;
static const struct mach_header *s_hidden_dyld_headers[256];
static uint32_t s_hidden_dyld_header_count = 0;
static pt_visible_dyld_image_t *s_visible_dyld_images = NULL;
static size_t s_visible_dyld_count = 0;
static size_t s_visible_dyld_cap = 0;
static pthread_mutex_t s_app_dyld_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t s_dyld_master_once = PTHREAD_ONCE_INIT;
static _Atomic BOOL s_replaying_initial = NO;
static _Atomic uint64_t s_dyld_replay_tid = 0;

static BOOL pt_visible_dyld_list_append(pt_visible_dyld_image_t **list,
                                        size_t *count,
                                        size_t *cap,
                                        const struct mach_header *mh,
                                        intptr_t slide) {
    if (*count >= *cap) {
        size_t new_cap = (*cap == 0) ? 64 : (*cap * 2);
        pt_visible_dyld_image_t *grown =
            (pt_visible_dyld_image_t *)realloc(*list, new_cap * sizeof(pt_visible_dyld_image_t));
        if (grown == NULL) {
            return NO;
        }
        *list = grown;
        *cap = new_cap;
    }
    (*list)[(*count)++] = (pt_visible_dyld_image_t){ .mh = mh, .slide = slide };
    return YES;
}

static BOOL pt_visible_dyld_list_contains(const pt_visible_dyld_image_t *list,
                                          size_t count,
                                          const struct mach_header *mh,
                                          intptr_t slide) {
    for (size_t i = 0; i < count; i++) {
        if (list[i].mh == mh && list[i].slide == slide) {
            return YES;
        }
    }
    return NO;
}

static const char *pt_dyld_lookup_image_name_for_mh(const struct mach_header *mh) {
    if (mh == NULL) {
        return NULL;
    }
    const char *path = dyld_image_path_containing_address((const void *)mh);
    if (path != NULL) {
        return path;
    }
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        if (_dyld_get_image_header(i) == mh) {
            return _dyld_get_image_name(i);
        }
    }
    return NULL;
}

static void pt_master_dyld_add_image_callback(const struct mach_header *mh, intptr_t vmaddr_slide) {
    atomic_fetch_add_explicit(&s_dyld_generation, 1, memory_order_release);
    // Look up image name before taking s_app_dyld_mutex to avoid ABBA lock inversion with dyld.
    const char *name = pt_dyld_lookup_image_name_for_mh(mh);
    BOOL is_hidden = ((name != NULL && pt_is_hidden_dyld_image_name(name)) || pt_is_hidden_dyld_image_header(mh));

    pthread_mutex_lock(&s_app_dyld_mutex);
    if (is_hidden) {
        BOOL found = NO;
        for (uint32_t i = 0; i < s_hidden_dyld_header_count; i++) {
            if (s_hidden_dyld_headers[i] == mh) {
                found = YES;
                break;
            }
        }
        if (!found && s_hidden_dyld_header_count < 256) {
            s_hidden_dyld_headers[s_hidden_dyld_header_count++] = mh;
        }
        pthread_mutex_unlock(&s_app_dyld_mutex);
        return;
    }

    BOOL already_visible = NO;
    for (size_t i = 0; i < s_visible_dyld_count; i++) {
        if (s_visible_dyld_images[i].mh == mh) {
            s_visible_dyld_images[i].slide = vmaddr_slide;
            already_visible = YES;
            break;
        }
    }
    if (!already_visible) {
        pt_visible_dyld_list_append(&s_visible_dyld_images,
                                    &s_visible_dyld_count,
                                    &s_visible_dyld_cap,
                                    mh,
                                    vmaddr_slide);
    }

    if (atomic_load_explicit(&s_replaying_initial, memory_order_acquire)) {
        uint64_t tid = 0;
        pthread_threadid_np(NULL, &tid);
        if (tid != 0 && tid == atomic_load_explicit(&s_dyld_replay_tid, memory_order_acquire)) {
            pthread_mutex_unlock(&s_app_dyld_mutex);
            return;
        }
    }

    if (already_visible) {
        pthread_mutex_unlock(&s_app_dyld_mutex);
        return;
    }

    pt_dyld_image_callback_t local_cbs[PT_MAX_APP_DYLD_CALLBACKS];
    uint32_t local_cb_count = 0;
    for (uint32_t j = 0; j < s_app_dyld_add_callback_count; j++) {
        pt_app_dyld_listener_t *l = &s_app_dyld_listeners[j];
        if (l->func == NULL) {
            continue;
        }
        if (l->replaying) {
            pt_visible_dyld_list_append(&l->queued,
                                        &l->queued_count,
                                        &l->queued_cap,
                                        mh,
                                        vmaddr_slide);
        } else if (local_cb_count < PT_MAX_APP_DYLD_CALLBACKS) {
            local_cbs[local_cb_count++] = l->func;
        }
    }
    pthread_mutex_unlock(&s_app_dyld_mutex);
    for (uint32_t j = 0; j < local_cb_count; j++) {
        local_cbs[j](mh, vmaddr_slide);
    }
}

static void pt_master_dyld_remove_image_callback(const struct mach_header *mh, intptr_t vmaddr_slide) {
    atomic_fetch_add_explicit(&s_dyld_generation, 1, memory_order_release);
    const char *name = pt_dyld_lookup_image_name_for_mh(mh);
    BOOL is_hidden = ((name != NULL && pt_is_hidden_dyld_image_name(name)) || pt_is_hidden_dyld_image_header(mh));
    pthread_mutex_lock(&s_app_dyld_mutex);
    for (uint32_t i = 0; i < s_hidden_dyld_header_count; i++) {
        if (s_hidden_dyld_headers[i] == mh) {
            is_hidden = YES;
            s_hidden_dyld_headers[i] = s_hidden_dyld_headers[--s_hidden_dyld_header_count];
            break;
        }
    }
    for (size_t i = 0; i < s_visible_dyld_count; i++) {
        if (s_visible_dyld_images[i].mh == mh) {
            if (i + 1 < s_visible_dyld_count) {
                memmove(&s_visible_dyld_images[i],
                        &s_visible_dyld_images[i + 1],
                        (s_visible_dyld_count - 1 - i) * sizeof(pt_visible_dyld_image_t));
            }
            s_visible_dyld_count--;
            break;
        }
    }
    if (is_hidden) {
        pthread_mutex_unlock(&s_app_dyld_mutex);
        return;
    }
    uint32_t cb_count = s_app_dyld_remove_callback_count;
    pt_dyld_image_callback_t local_cbs[PT_MAX_APP_DYLD_CALLBACKS];
    for (uint32_t j = 0; j < cb_count; j++) {
        local_cbs[j] = s_app_dyld_remove_callbacks[j];
    }
    pthread_mutex_unlock(&s_app_dyld_mutex);
    for (uint32_t j = 0; j < cb_count; j++) {
        if (local_cbs[j] != NULL) {
            local_cbs[j](mh, vmaddr_slide);
        }
    }
}

static void pt_init_dyld_master_callbacks(void) {
    uint64_t tid = 0;
    pthread_threadid_np(NULL, &tid);
    atomic_store_explicit(&s_dyld_replay_tid, tid, memory_order_release);
    atomic_store_explicit(&s_replaying_initial, YES, memory_order_release);
    _dyld_register_func_for_add_image(pt_master_dyld_add_image_callback);
    atomic_store_explicit(&s_replaying_initial, NO, memory_order_release);
    atomic_store_explicit(&s_dyld_replay_tid, 0, memory_order_release);
    _dyld_register_func_for_remove_image(pt_master_dyld_remove_image_callback);
}

static void pt_ensure_dyld_master_callbacks(void) {
    pthread_once(&s_dyld_master_once, pt_init_dyld_master_callbacks);
}

static void pt_dyld_register_func_for_add_image(void (*func)(const struct mach_header *mh, intptr_t vmaddr_slide)) {
    if (func == NULL) {
        return;
    }
    if (!pt_is_bypass_enabled() || pt_is_system_or_playtools_caller((const void *)func)) {
        _dyld_register_func_for_add_image(func);
        return;
    }
    pt_ensure_dyld_master_callbacks();

    pthread_mutex_lock(&s_app_dyld_mutex);
    BOOL has_slot = (s_app_dyld_add_callback_count < PT_MAX_APP_DYLD_CALLBACKS);
    uint32_t slot_idx = 0;
    if (has_slot) {
        slot_idx = s_app_dyld_add_callback_count++;
        s_app_dyld_listeners[slot_idx] = (pt_app_dyld_listener_t){
            .func = func,
            .replaying = YES,
            .queued = NULL,
            .queued_count = 0,
            .queued_cap = 0,
        };
    }
    size_t replay_count = s_visible_dyld_count;
    size_t replay_cap = replay_count;
    pt_visible_dyld_image_t *replay_buf = NULL;
    if (replay_count > 0) {
        replay_buf = (pt_visible_dyld_image_t *)malloc(replay_count * sizeof(pt_visible_dyld_image_t));
        if (replay_buf != NULL) {
            memcpy(replay_buf, s_visible_dyld_images, replay_count * sizeof(pt_visible_dyld_image_t));
        } else {
            replay_count = 0;
            replay_cap = 0;
        }
    }
    pthread_mutex_unlock(&s_app_dyld_mutex);

    for (size_t i = 0; i < replay_count; i++) {
        func(replay_buf[i].mh, replay_buf[i].slide);
    }

    if (has_slot) {
        pthread_mutex_lock(&s_app_dyld_mutex);
        while (s_app_dyld_listeners[slot_idx].queued_count > 0) {
            pt_app_dyld_listener_t *l = &s_app_dyld_listeners[slot_idx];
            pt_visible_dyld_image_t *batch = l->queued;
            size_t n = l->queued_count;
            l->queued = NULL;
            l->queued_count = 0;
            l->queued_cap = 0;
            pthread_mutex_unlock(&s_app_dyld_mutex);

            for (size_t k = 0; k < n; k++) {
                if (!pt_visible_dyld_list_contains(replay_buf, replay_count, batch[k].mh, batch[k].slide)) {
                    func(batch[k].mh, batch[k].slide);
                    pt_visible_dyld_list_append(&replay_buf,
                                                &replay_count,
                                                &replay_cap,
                                                batch[k].mh,
                                                batch[k].slide);
                }
            }
            free(batch);
            pthread_mutex_lock(&s_app_dyld_mutex);
        }
        s_app_dyld_listeners[slot_idx].replaying = NO;
        pthread_mutex_unlock(&s_app_dyld_mutex);
    }

    free(replay_buf);
}

static void pt_dyld_register_func_for_remove_image(void (*func)(const struct mach_header *mh, intptr_t vmaddr_slide)) {
    if (func == NULL) {
        return;
    }
    if (!pt_is_bypass_enabled() || pt_is_system_or_playtools_caller((const void *)func)) {
        _dyld_register_func_for_remove_image(func);
        return;
    }
    pt_ensure_dyld_master_callbacks();
    pthread_mutex_lock(&s_app_dyld_mutex);
    if (s_app_dyld_remove_callback_count < PT_MAX_APP_DYLD_CALLBACKS) {
        s_app_dyld_remove_callbacks[s_app_dyld_remove_callback_count++] = func;
    }
    pthread_mutex_unlock(&s_app_dyld_mutex);
}

extern const char *dyld_image_path_containing_address(const void *addr);
static const char *pt_dyld_image_path_containing_address(const void *addr) {
    BOOL hide = (pt_is_bypass_enabled() &&
                 !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    if (hide) {
        addr = pt_resolve_interposed_target(addr);
    }
    const char *path = dyld_image_path_containing_address(addr);
    if (path != NULL && hide) {
        if (pt_is_hidden_dyld_image_name(path)) {
            return pt_fallback_system_image_path();
        }
        return pt_sanitize_image_path_for_app(path);
    }
    return path;
}

extern const struct mach_header *dyld_image_header_containing_address(const void *addr);
static const struct mach_header *pt_dyld_image_header_containing_address(const void *addr) {
    BOOL hide = (pt_is_bypass_enabled() &&
                 !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    if (hide) {
        addr = pt_resolve_interposed_target(addr);
    }
    const struct mach_header *hdr = dyld_image_header_containing_address(addr);
    if (hdr != NULL && hide) {
        const char *path = dyld_image_path_containing_address(addr);
        if (path != NULL && pt_is_hidden_dyld_image_name(path)) {
            return _dyld_get_image_header(pt_fallback_system_image_index());
        }
    }
    return hdr;
}

static int pt_dladdr(const void *addr, Dl_info *info) {
    BOOL hide = (pt_is_bypass_enabled() &&
                 !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    if (hide) {
        addr = pt_resolve_interposed_target(addr);
    }
    int ret = dladdr(addr, info);
    if (ret != 0 && info != NULL && info->dli_fname != NULL && hide) {
        if (pt_is_hidden_dyld_image_name(info->dli_fname)) {
            PT_DEBUG_TRACE("dyld", "cloaked dladdr fname=%s", info->dli_fname);
            uint32_t fb_idx = pt_fallback_system_image_index();
            const struct mach_header *fb_hdr = _dyld_get_image_header(fb_idx);
            const char *fb_path = pt_fallback_system_image_path();
            uintptr_t stripped_addr = (uintptr_t)pt_strip_code_ptr(addr);
            if (fb_hdr != NULL && (uintptr_t)fb_hdr > stripped_addr) {
                const struct mach_header *mh0 = _dyld_get_image_header(0);
                const char *name0 = _dyld_get_image_name(0);
                if (mh0 != NULL && (uintptr_t)mh0 <= stripped_addr && name0 != NULL) {
                    fb_hdr = mh0;
                    fb_path = pt_sanitize_image_path_for_app(name0);
                }
            }
            if (fb_hdr != NULL && fb_path != NULL) {
                info->dli_fname = fb_path;
                info->dli_fbase = (void *)fb_hdr;
            } else {
                info->dli_fname = "/System/Library/Frameworks/UIKit.framework/UIKit";
            }
            info->dli_sname = NULL;
            info->dli_saddr = NULL;
        } else {
            info->dli_fname = pt_sanitize_image_path_for_app(info->dli_fname);
            if (info->dli_sname != NULL &&
                (strstr(info->dli_sname, "isiOSAppOnVision") != NULL ||
                 (pt_is_compat13_7_active() && strstr(info->dli_sname, "isiOSAppOnMac") != NULL))) {
                info->dli_sname = NULL;
                info->dli_saddr = NULL;
            }
        }
    }
    return ret;
}

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

static BOOL pt_should_block_dlopen_path(const char *path, const void *caller) {
    if (path == NULL || !pt_is_bypass_enabled()) {
        return NO;
    }
    if (pt_is_effective_system_or_playtools_caller(caller)) {
        return NO;
    }
    return (pt_is_hidden_path(path, caller) ||
            pt_is_hidden_dyld_image_name(path) ||
            pt_is_post13_7_hidden_framework_path(path) ||
            pt_has_blocked_jailbreak_dlopen_component(path));
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

extern void *dlopen_from(const char *path, int mode, void *addressInCaller);

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
    if (handle != NULL && orig_path != NULL) {
        ps_notify_dynamic_image_loaded();
    }
    return handle;
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
        if (pt_should_block_dlopen_path(path, caller)) {
            pt_set_blocked_dlopen_preflight_error(path);
            return false;
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
            if (res > 0) {
                return true;
            }
            if (res < 0) {
                return false;
            }
            if (main_hdr != NULL && main_hdr != caller_hdr) {
                const struct mach_header *main_lc_hdr =
                    sanitize_rpath_lc ? pt_maybe_shadow_mach_header(main_hdr) : main_hdr;
                res = pt_dlopen_preflight_search_rpaths(main_lc_hdr, rel, exec_dir, exec_dir, caller);
                if (res > 0) {
                    return true;
                }
                if (res < 0) {
                    return false;
                }
            }
        } else {
            char expanded[PATH_MAX];
            if (pt_expand_dyld_token_path(path, caller_dir, exec_dir, expanded, sizeof(expanded))) {
                int res = pt_dlopen_preflight_try_candidate(expanded, caller);
                if (res > 0) {
                    return true;
                }
                if (res < 0) {
                    return false;
                }
            }
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

extern const void *pt_orig_swift_typeByName(uint64_t w0, uint64_t w1)
    __asm("_$ss11_typeByNameyypXpSgSSF") __attribute__((swiftcall)) __attribute__((weak_import));

extern CFTypeRef pt_orig_swift_string_bridge(uint64_t w0, uint64_t w1)
    __asm("_$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF")
    __attribute__((swiftcall)) __attribute__((weak_import)) CF_RETURNS_RETAINED;

static BOOL pt_memmem_lit(const char *buf, size_t len, const char *lit, size_t lit_len) {
    return (buf != NULL && len >= lit_len && memmem(buf, len, lit, lit_len) != NULL);
}

static BOOL pt_is_hidden_swift_mangled_type_name(const char *typeNameStart, size_t typeNameLength) {
    if (typeNameStart == NULL || typeNameLength == 0 || !pt_is_valid_user_pointer(typeNameStart)) {
        return NO;
    }
    size_t scan_len = (typeNameLength > 4096U) ? 4096U : typeNameLength;
    if (pt_memmem_lit(typeNameStart, scan_len, "9PlayTools", 10) ||
        pt_memmem_lit(typeNameStart, scan_len, "PlayTools.", 10) ||
        pt_memmem_lit(typeNameStart, scan_len, "11AKInterface", 13) ||
        pt_memmem_lit(typeNameStart, scan_len, "AKInterface.", 12) ||
        pt_memmem_lit(typeNameStart, scan_len, "9PlayCover", 10) ||
        pt_memmem_lit(typeNameStart, scan_len, "8AKPlugin", 9)) {
        return YES;
    }
    if (pt_is_compat13_7_active()) {
#define PT_MEMMEM_LIT(buf, len, lit) pt_memmem_lit((buf), (len), (lit), sizeof(lit) - 1U)
        if (PT_MEMMEM_LIT(typeNameStart, scan_len, "7SwiftUI10LazyVStack") ||
            PT_MEMMEM_LIT(typeNameStart, scan_len, "7SwiftUI12ProgressView") ||
            PT_MEMMEM_LIT(typeNameStart, scan_len, "7SwiftUI10LazyHStack") ||
            PT_MEMMEM_LIT(typeNameStart, scan_len, "7SwiftUI9LazyVGrid") ||
            PT_MEMMEM_LIT(typeNameStart, scan_len, "7SwiftUI9LazyHGrid") ||
            PT_MEMMEM_LIT(typeNameStart, scan_len, "7SwiftUI10TextEditor") ||
            PT_MEMMEM_LIT(typeNameStart, scan_len, "7SwiftUI11ColorPicker") ||
            PT_MEMMEM_LIT(typeNameStart, scan_len, "7SwiftUI10AsyncImage") ||
            PT_MEMMEM_LIT(typeNameStart, scan_len, "7SwiftUI15NavigationStack") ||
            PT_MEMMEM_LIT(typeNameStart, scan_len, "7SwiftUI4GridV") ||
            PT_MEMMEM_LIT(typeNameStart, scan_len, "7SwiftUI10AppStorage") ||
            PT_MEMMEM_LIT(typeNameStart, scan_len, "7SwiftUI11StateObject") ||
            PT_MEMMEM_LIT(typeNameStart, scan_len, "7SwiftUI12SceneStorage") ||
            PT_MEMMEM_LIT(typeNameStart, scan_len, "7SwiftUI12ScaledMetric") ||
            PT_MEMMEM_LIT(typeNameStart, scan_len, "12_Concurrency") ||
            PT_MEMMEM_LIT(typeNameStart, scan_len, "22UniformTypeIdentifiers6UTType") ||
            PT_MEMMEM_LIT(typeNameStart, scan_len, "5OSLog6Logger") ||
            PT_MEMMEM_LIT(typeNameStart, scan_len, "SwiftUI.LazyVStack") ||
            PT_MEMMEM_LIT(typeNameStart, scan_len, "SwiftUI.ProgressView") ||
            PT_MEMMEM_LIT(typeNameStart, scan_len, "_Concurrency.Task") ||
            (scan_len >= 3 && strncmp(typeNameStart, "ScT", 3) == 0)) {
            return YES;
        }
#undef PT_MEMMEM_LIT
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
    if (pt_should_hide_swift_type_lookup(typeNameStart, typeNameLength, __builtin_return_address(0)) ||
        &swift_getTypeByMangledNameInContext == NULL) {
        return NULL;
    }
    return swift_getTypeByMangledNameInContext(typeNameStart, typeNameLength, context, genericArgs);
}

static const void *pt_swift_getTypeByMangledNameInContext2(const char *typeNameStart,
                                                          size_t typeNameLength,
                                                          const void *context,
                                                          const void * const *genericArgs)
    __attribute__((swiftcall)) {
    if (pt_should_hide_swift_type_lookup(typeNameStart, typeNameLength, __builtin_return_address(0)) ||
        &swift_getTypeByMangledNameInContext2 == NULL) {
        return NULL;
    }
    return swift_getTypeByMangledNameInContext2(typeNameStart, typeNameLength, context, genericArgs);
}

static const void *pt_swift_getTypeByMangledNameInContextInMetadataState(size_t metadataState,
                                                                        const char *typeNameStart,
                                                                        size_t typeNameLength,
                                                                        const void *context,
                                                                        const void * const *genericArgs)
    __attribute__((swiftcall)) {
    if (pt_should_hide_swift_type_lookup(typeNameStart, typeNameLength, __builtin_return_address(0)) ||
        &swift_getTypeByMangledNameInContextInMetadataState == NULL) {
        return NULL;
    }
    return swift_getTypeByMangledNameInContextInMetadataState(metadataState,
                                                              typeNameStart,
                                                              typeNameLength,
                                                              context,
                                                              genericArgs);
}

static const void *pt_swift_getTypeByMangledNameInContextInMetadataState2(size_t metadataState,
                                                                         const char *typeNameStart,
                                                                         size_t typeNameLength,
                                                                         const void *context,
                                                                         const void * const *genericArgs)
    __attribute__((swiftcall)) {
    if (pt_should_hide_swift_type_lookup(typeNameStart, typeNameLength, __builtin_return_address(0)) ||
        &swift_getTypeByMangledNameInContextInMetadataState2 == NULL) {
        return NULL;
    }
    return swift_getTypeByMangledNameInContextInMetadataState2(metadataState,
                                                               typeNameStart,
                                                               typeNameLength,
                                                               context,
                                                               genericArgs);
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
    if (pt_is_bypass_enabled() &&
        pt_is_swift_type_lookup_app_caller(caller) &&
        pt_swift_string_is_hidden_type(w0, w1)) {
        return NULL;
    }
    if (&pt_orig_swift_typeByName == NULL) {
        return NULL;
    }
    return pt_orig_swift_typeByName(w0, w1);
}

static void *pt_dlsym(void *handle, const char *symbol) {
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return dlsym(handle, symbol);
    }
    s_tls_dlerror_pending = false;
    const void *caller = __builtin_return_address(0);
    BOOL app_caller = (pt_is_bypass_enabled() &&
                       !pt_is_effective_system_or_playtools_caller(caller));
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
        } else if (strncmp(symbol, "SecCode", 7) == 0 ||
                   strncmp(symbol, "SecStaticCode", 13) == 0 ||
                   strncmp(symbol, "SecRequirementCreate", 20) == 0 ||
                   strncmp(symbol, "MTLCopyAllDevices", 17) == 0 ||
                   strncmp(symbol, "AudioObject", 11) == 0 ||
                   strncmp(symbol, "AudioHardware", 13) == 0 ||
                   strcmp(symbol, "AudioDeviceCreateIOProcID") == 0 ||
                   strcmp(symbol, "AudioDeviceDestroyIOProcID") == 0 ||
                   strcmp(symbol, "AudioDeviceStart") == 0 ||
                   strcmp(symbol, "AudioDeviceStop") == 0 ||
                   strncmp(symbol, "AudioDeviceGetProperty", 22) == 0 ||
                   strcmp(symbol, "AudioDeviceSetProperty") == 0 ||
                   strcmp(symbol, "SCDynamicStoreCopyComputerName") == 0 ||
                   strcmp(symbol, "SCDynamicStoreCopyLocalHostName") == 0 ||
                   strcmp(symbol, "SCNetworkInterfaceCopyAll") == 0 ||
                   strcmp(symbol, "_LSCopyApplicationInformation") == 0 ||
                   strcmp(symbol, "_LSGetCurrentApplicationASN") == 0 ||
                   strncmp(symbol, "_LSASN", 6) == 0 ||
                   strncmp(symbol, "_LSCopyApplicationInformation", 29) == 0 ||
                   (pt_is_compat13_7_active() &&
                    (strcmp(symbol, "freadlink") == 0 ||
                     strcmp(symbol, "objc_enumerateClasses") == 0 ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI10LazyVStack") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI12ProgressView") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI10LazyHStack") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI9LazyVGrid") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI9LazyHGrid") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI10TextEditor") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI11ColorPicker") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI10AsyncImage") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI15NavigationStack") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI4GridV") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI10AppStorage") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI11StateObject") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI12SceneStorage") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s7SwiftUI12ScaledMetric") ||
                     PT_HAS_PREFIX_LIT(symbol, "$sScT") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s12_Concurrency") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s22UniformTypeIdentifiers6UTType") ||
                     PT_HAS_PREFIX_LIT(symbol, "$s5OSLog6Logger")))) {
            PT_DEBUG_TRACE("dyld", "hid macOS-only symbol=%s", symbol);
            pt_set_synthetic_dlerror("symbol not found");
            return NULL;
        } else if (pt_is_compat13_7_active() &&
                   (strcmp(symbol, "kCFCoreFoundationVersionNumber") == 0 ||
                    strcmp(symbol, "NSFoundationVersionNumber") == 0)) {
            static const double s_compat13_cf_version = 1677.104;
            return (void *)&s_compat13_cf_version;
        } else if (strcmp(symbol, "_dyld_shared_cache_contains_path") == 0) {
            return (void *)&pt_dyld_shared_cache_contains_path;
        } else if (strcmp(symbol, "_availability_version_check") == 0) {
            return (void *)&pt_availability_version_check;
        } else if (strcmp(symbol, "environ") == 0) {
            char ***shadow_envp = pt_get_app_shadow_environ_ptr();
            if (shadow_envp != NULL) {
                return (void *)shadow_envp;
            }
        } else if (symbol[0] == 'M' && symbol[1] == 'G') {
            if (strcmp(symbol, "MGCopyAnswer") == 0) {
                return (void *)&pt_MGCopyAnswer;
            }
            if (strcmp(symbol, "MGCopyAnswerWithError") == 0) {
                return (void *)&pt_MGCopyAnswerWithError;
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
        } else if (handle != RTLD_MAIN_ONLY) {
            if (strcmp(symbol, "swift_getTypeByMangledNameInContext") == 0 &&
                &swift_getTypeByMangledNameInContext != NULL) {
                return (void *)&pt_swift_getTypeByMangledNameInContext;
            }
            if (strcmp(symbol, "swift_getTypeByMangledNameInContext2") == 0 &&
                &swift_getTypeByMangledNameInContext2 != NULL) {
                return (void *)&pt_swift_getTypeByMangledNameInContext2;
            }
            if (strcmp(symbol, "swift_getTypeByMangledNameInContextInMetadataState") == 0 &&
                &swift_getTypeByMangledNameInContextInMetadataState != NULL) {
                return (void *)&pt_swift_getTypeByMangledNameInContextInMetadataState;
            }
            if (strcmp(symbol, "swift_getTypeByMangledNameInContextInMetadataState2") == 0 &&
                &swift_getTypeByMangledNameInContextInMetadataState2 != NULL) {
                return (void *)&pt_swift_getTypeByMangledNameInContextInMetadataState2;
            }
            if (strcmp(symbol, "$ss11_typeByNameyypXpSgSSF") == 0 &&
                &pt_orig_swift_typeByName != NULL) {
                return (void *)&pt_swift_typeByName;
            }
            if (strcmp(symbol, "objc_getClass") == 0) {
                return (void *)&pt_objc_getClass;
            }
            if (strcmp(symbol, "objc_lookUpClass") == 0) {
                return (void *)&pt_objc_lookUpClass;
            }
            if (strcmp(symbol, "objc_getMetaClass") == 0) {
                return (void *)&pt_objc_getMetaClass;
            }
            if (strcmp(symbol, "objc_getRequiredClass") == 0) {
                return (void *)&pt_objc_getRequiredClass;
            }
            if (strcmp(symbol, "NSClassFromString") == 0) {
                return (void *)&pt_NSClassFromString;
            }
            if (strcmp(symbol, "NSStringFromClass") == 0) {
                return (void *)&pt_NSStringFromClass;
            }
            if (strcmp(symbol, "NSProtocolFromString") == 0) {
                return (void *)&pt_NSProtocolFromString;
            }
            if (strcmp(symbol, "objc_copyClassList") == 0) {
                return (void *)&pt_objc_copyClassList;
            }
            if (strcmp(symbol, "objc_getClassList") == 0) {
                return (void *)&pt_objc_getClassList;
            }
            if (strcmp(symbol, "class_getImageName") == 0) {
                return (void *)&pt_class_getImageName;
            }
            if (strcmp(symbol, "objc_copyClassNamesForImage") == 0) {
                return (void *)&pt_objc_copyClassNamesForImage;
            }
            if (strcmp(symbol, "objc_copyClassNamesForImageHeader") == 0 &&
                &pt_orig_objc_copyClassNamesForImageHeader != NULL) {
                return (void *)&pt_objc_copyClassNamesForImageHeader;
            }
            if (strcmp(symbol, "objc_copyImageNames") == 0) {
                return (void *)&pt_objc_copyImageNames;
            }
            if (strcmp(symbol, "class_getName") == 0) {
                return (void *)&pt_class_getName;
            }
            if (strcmp(symbol, "object_getClassName") == 0) {
                return (void *)&pt_object_getClassName;
            }
            if (strcmp(symbol, "class_getInstanceMethod") == 0) {
                return (void *)&pt_class_getInstanceMethod;
            }
            if (strcmp(symbol, "class_getClassMethod") == 0) {
                return (void *)&pt_class_getClassMethod;
            }
            if (strcmp(symbol, "method_getImplementation") == 0) {
                return (void *)&pt_method_getImplementation;
            }
            if (strcmp(symbol, "class_getMethodImplementation") == 0) {
                return (void *)&pt_class_getMethodImplementation;
            }
            if (strcmp(symbol, "class_copyMethodList") == 0) {
                return (void *)&pt_class_copyMethodList;
            }
            if (strcmp(symbol, "class_respondsToSelector") == 0) {
                return (void *)&pt_class_respondsToSelector;
            }
            if (strcmp(symbol, "class_getProperty") == 0) {
                return (void *)&pt_class_getProperty;
            }
            if (strcmp(symbol, "class_copyPropertyList") == 0) {
                return (void *)&pt_class_copyPropertyList;
            }
            if (strcmp(symbol, "objc_getProtocol") == 0) {
                return (void *)&pt_objc_getProtocol;
            }
            if (strcmp(symbol, "objc_copyProtocolList") == 0) {
                return (void *)&pt_objc_copyProtocolList;
            }
            if (strcmp(symbol, "NSVersionOfRunTimeLibrary") == 0) {
                return (void *)&pt_NSVersionOfRunTimeLibrary;
            }
            if (strcmp(symbol, "NSVersionOfLinkTimeLibrary") == 0) {
                return (void *)&pt_NSVersionOfLinkTimeLibrary;
            }
            if (strcmp(symbol, "_dyld_image_count") == 0) {
                return (void *)&pt_dyld_image_count;
            }
            if (strcmp(symbol, "_dyld_get_image_name") == 0) {
                return (void *)&pt_dyld_get_image_name;
            }
            if (strcmp(symbol, "_dyld_get_image_header") == 0) {
                return (void *)&pt_dyld_get_image_header;
            }
            if (strcmp(symbol, "_dyld_get_image_vmaddr_slide") == 0) {
                return (void *)&pt_dyld_get_image_vmaddr_slide;
            }
            if (strcmp(symbol, "_dyld_register_func_for_add_image") == 0) {
                return (void *)&pt_dyld_register_func_for_add_image;
            }
            if (strcmp(symbol, "_dyld_register_func_for_remove_image") == 0) {
                return (void *)&pt_dyld_register_func_for_remove_image;
            }
            if (strcmp(symbol, "dyld_image_path_containing_address") == 0) {
                return (void *)&pt_dyld_image_path_containing_address;
            }
            if (strcmp(symbol, "dyld_image_header_containing_address") == 0) {
                return (void *)&pt_dyld_image_header_containing_address;
            }
            if (strcmp(symbol, "dyld_get_active_platform") == 0 && &dyld_get_active_platform != NULL) {
                return (void *)&pt_dyld_get_active_platform;
            }
            if (strcmp(symbol, "dyld_get_base_platform") == 0 && &dyld_get_base_platform != NULL) {
                return (void *)&pt_dyld_get_base_platform;
            }
            if (strcmp(symbol, "dyld_get_image_versions") == 0 && &pt_orig_dyld_get_image_versions != NULL) {
                return (void *)&pt_dyld_get_image_versions;
            }
            if (strcmp(symbol, "dyld_sdk_at_least") == 0 && &pt_orig_dyld_sdk_at_least != NULL) {
                return (void *)&pt_dyld_sdk_at_least;
            }
            if (strcmp(symbol, "dyld_minos_at_least") == 0 && &pt_orig_dyld_minos_at_least != NULL) {
                return (void *)&pt_dyld_minos_at_least;
            }
            if (strcmp(symbol, "dyld_shared_cache_file_path") == 0 && &dyld_shared_cache_file_path != NULL) {
                return (void *)&pt_dyld_shared_cache_file_path;
            }
            if (strcmp(symbol, "dladdr") == 0) {
                return (void *)&pt_dladdr;
            }
            if (strcmp(symbol, "dlopen") == 0) {
                return (void *)&pt_dlopen;
            }
            if (strcmp(symbol, "dlopen_preflight") == 0) {
                return (void *)&pt_dlopen_preflight;
            }
            if (strcmp(symbol, "dlerror") == 0) {
                return (void *)&pt_dlerror;
            }
            if (strcmp(symbol, "dlsym") == 0) {
                return (void *)&pt_dlsym;
            }
            if (strcmp(symbol, "getsectiondata") == 0) {
                return (void *)&pt_getsectiondata;
            }
            if (strcmp(symbol, "getsegmentdata") == 0) {
                return (void *)&pt_getsegmentdata;
            }
            if (strcmp(symbol, "getsectdatafromheader_64") == 0) {
                return (void *)&pt_getsectdatafromheader_64;
            }
            void *routed = pt_fs_dlsym_route(symbol);
            if (routed != NULL) {
                return routed;
            }
            routed = pt_network_dlsym_route(symbol);
            if (routed != NULL) {
                return routed;
            }
            routed = pt_spoofer_dlsym_route(symbol);
            if (routed != NULL) {
                return routed;
            }
            routed = pt_entitlements_dlsym_route(symbol);
            if (routed != NULL) {
                return routed;
            }
            routed = pt_svc_dlsym_route(symbol);
            if (routed != NULL) {
                return routed;
            }
            routed = pt_objc_spoofer_dlsym_route(symbol);
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
                    const char *img_name = _dyld_get_image_name(j);
                    if (img_name == NULL) {
                        continue;
                    }
                    if (app_caller &&
                        (pt_is_hidden_dyld_image_name(img_name) ||
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
        if (target_sym == sym) {
            Dl_info sym_info;
            if (dladdr(target_sym, &sym_info) != 0 && sym_info.dli_fname != NULL &&
                (pt_is_hidden_dyld_image_name(sym_info.dli_fname) ||
                 pt_is_post13_7_hidden_framework_path(sym_info.dli_fname))) {
                PT_DEBUG_TRACE("dyld", "hid dlsym symbol=%s", symbol != NULL ? symbol : "<null>");
                pt_set_synthetic_dlerror("symbol not found");
                return NULL;
            }
        }
    }
    return sym;
}


DYLD_INTERPOSE(pt_dyld_get_active_platform, dyld_get_active_platform)
DYLD_INTERPOSE(pt_dyld_get_base_platform, dyld_get_base_platform)
DYLD_INTERPOSE(pt_dyld_get_image_versions, pt_orig_dyld_get_image_versions)
DYLD_INTERPOSE(pt_dyld_sdk_at_least, pt_orig_dyld_sdk_at_least)
DYLD_INTERPOSE(pt_dyld_minos_at_least, pt_orig_dyld_minos_at_least)
DYLD_INTERPOSE(pt_dyld_shared_cache_file_path, dyld_shared_cache_file_path)
DYLD_INTERPOSE(pt_dyld_shared_cache_contains_path, pt_orig_dyld_shared_cache_contains_path)
DYLD_INTERPOSE(pt_objc_getClass, objc_getClass)
DYLD_INTERPOSE(pt_objc_lookUpClass, objc_lookUpClass)
DYLD_INTERPOSE(pt_objc_getMetaClass, objc_getMetaClass)
DYLD_INTERPOSE(pt_objc_getRequiredClass, objc_getRequiredClass)
DYLD_INTERPOSE(pt_NSClassFromString, NSClassFromString)
DYLD_INTERPOSE(pt_NSStringFromClass, pt_orig_NSStringFromClass)
DYLD_INTERPOSE(pt_NSProtocolFromString, pt_orig_NSProtocolFromString)
DYLD_INTERPOSE(pt_objc_copyImageNames, objc_copyImageNames)
DYLD_INTERPOSE(pt_class_getImageName, class_getImageName)
DYLD_INTERPOSE(pt_objc_copyClassNamesForImage, objc_copyClassNamesForImage)
DYLD_INTERPOSE(pt_objc_copyClassNamesForImageHeader, pt_orig_objc_copyClassNamesForImageHeader)
DYLD_INTERPOSE(pt_objc_copyClassList, objc_copyClassList)
DYLD_INTERPOSE(pt_objc_getClassList, objc_getClassList)
DYLD_INTERPOSE(pt_class_getInstanceMethod, class_getInstanceMethod)
DYLD_INTERPOSE(pt_class_getClassMethod, class_getClassMethod)
DYLD_INTERPOSE(pt_method_getImplementation, method_getImplementation)
DYLD_INTERPOSE(pt_class_getMethodImplementation, class_getMethodImplementation)
DYLD_INTERPOSE(pt_class_copyMethodList, class_copyMethodList)
DYLD_INTERPOSE(pt_class_respondsToSelector, class_respondsToSelector)
DYLD_INTERPOSE(pt_class_getProperty, class_getProperty)
DYLD_INTERPOSE(pt_class_copyPropertyList, class_copyPropertyList)
DYLD_INTERPOSE(pt_class_getName, class_getName)
DYLD_INTERPOSE(pt_object_getClassName, object_getClassName)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
DYLD_INTERPOSE(pt_NSVersionOfRunTimeLibrary, NSVersionOfRunTimeLibrary)
DYLD_INTERPOSE(pt_NSVersionOfLinkTimeLibrary, NSVersionOfLinkTimeLibrary)
#pragma clang diagnostic pop
DYLD_INTERPOSE(pt_objc_getProtocol, objc_getProtocol)
DYLD_INTERPOSE(pt_objc_copyProtocolList, objc_copyProtocolList)
DYLD_INTERPOSE(pt_dyld_image_count, _dyld_image_count)
DYLD_INTERPOSE(pt_dyld_get_image_name, _dyld_get_image_name)
DYLD_INTERPOSE(pt_dyld_get_image_header, _dyld_get_image_header)
DYLD_INTERPOSE(pt_dyld_get_image_vmaddr_slide, _dyld_get_image_vmaddr_slide)
DYLD_INTERPOSE(pt_dyld_register_func_for_add_image, _dyld_register_func_for_add_image)
DYLD_INTERPOSE(pt_dyld_register_func_for_remove_image, _dyld_register_func_for_remove_image)
DYLD_INTERPOSE(pt_dyld_image_path_containing_address, dyld_image_path_containing_address)
DYLD_INTERPOSE(pt_dyld_image_header_containing_address, dyld_image_header_containing_address)
DYLD_INTERPOSE(pt_getsectiondata, getsectiondata)
DYLD_INTERPOSE(pt_getsegmentdata, getsegmentdata)
DYLD_INTERPOSE(pt_getsectdatafromheader_64, getsectdatafromheader_64)
DYLD_INTERPOSE(pt_dladdr, dladdr)
DYLD_INTERPOSE(pt_dlopen, dlopen)
DYLD_INTERPOSE(pt_dlopen_preflight, dlopen_preflight)
DYLD_INTERPOSE(pt_dlsym, dlsym)
DYLD_INTERPOSE(pt_dlerror, dlerror)
DYLD_INTERPOSE(pt_swift_getTypeByMangledNameInContext, swift_getTypeByMangledNameInContext)
DYLD_INTERPOSE(pt_swift_getTypeByMangledNameInContext2, swift_getTypeByMangledNameInContext2)
DYLD_INTERPOSE(pt_swift_getTypeByMangledNameInContextInMetadataState, swift_getTypeByMangledNameInContextInMetadataState)
DYLD_INTERPOSE(pt_swift_getTypeByMangledNameInContextInMetadataState2, swift_getTypeByMangledNameInContextInMetadataState2)
DYLD_INTERPOSE(pt_swift_typeByName, pt_orig_swift_typeByName)

static BOOL (*s_orig_nsobject_respondsToSelector)(id, SEL, SEL) = NULL;
static BOOL (*s_orig_nsobject_instancesRespondToSelector)(id, SEL, SEL) = NULL;
static id (*s_orig_nsobject_methodSignatureForSelector)(id, SEL, SEL) = NULL;
static id (*s_orig_nsobject_instanceMethodSignatureForSelector)(id, SEL, SEL) = NULL;
static IMP (*s_orig_nsobject_methodForSelector)(id, SEL, SEL) = NULL;
static IMP (*s_orig_nsobject_instanceMethodForSelector)(id, SEL, SEL) = NULL;
static IMP s_nsobject_notFoundIMP = NULL;

static inline BOOL ps_should_hide_selector_for_target_class(Class targetCls, SEL aSelector, const void *caller) {
    if (targetCls == Nil ||
        aSelector == NULL ||
        !pt_is_bypass_enabled()) {
        return NO;
    }
    BOOL isMeta = class_isMetaClass(targetCls);
    if (pt_is_hidden_post13_7_method(targetCls, aSelector, isMeta) ||
        pt_is_hidden_macos_only_method(targetCls, aSelector, isMeta)) {
        return !pt_is_effective_system_or_playtools_caller(caller);
    }
    Method m = class_getInstanceMethod(targetCls, aSelector);
    if (m == NULL || !pt_is_playtools_injected_method(m, aSelector)) {
        return NO;
    }
    return !pt_is_effective_system_or_playtools_caller(caller);
}

static BOOL ps_hook_nsobject_respondsToSelector(id self, SEL _cmd, SEL aSelector) {
    if (!pt_is_valid_user_pointer((const void *)aSelector)) {
        return NO;
    }
    BOOL orig = s_orig_nsobject_respondsToSelector ? s_orig_nsobject_respondsToSelector(self, _cmd, aSelector) : NO;
    if (orig && ps_should_hide_selector_for_target_class(object_getClass(self), aSelector, __builtin_return_address(0))) {
        return NO;
    }
    return orig;
}

static BOOL ps_hook_nsobject_instancesRespondToSelector(id self, SEL _cmd, SEL aSelector) {
    if (!pt_is_valid_user_pointer((const void *)aSelector)) {
        return NO;
    }
    BOOL orig = s_orig_nsobject_instancesRespondToSelector ? s_orig_nsobject_instancesRespondToSelector(self, _cmd, aSelector) : NO;
    if (orig && ps_should_hide_selector_for_target_class((Class)self, aSelector, __builtin_return_address(0))) {
        return NO;
    }
    return orig;
}

static id ps_hook_nsobject_methodSignatureForSelector(id self, SEL _cmd, SEL aSelector) {
    if (!pt_is_valid_user_pointer((const void *)aSelector)) {
        return nil;
    }
    if (ps_should_hide_selector_for_target_class(object_getClass(self), aSelector, __builtin_return_address(0))) {
        return nil;
    }
    return s_orig_nsobject_methodSignatureForSelector ? s_orig_nsobject_methodSignatureForSelector(self, _cmd, aSelector) : nil;
}

static id ps_hook_nsobject_instanceMethodSignatureForSelector(id self, SEL _cmd, SEL aSelector) {
    if (!pt_is_valid_user_pointer((const void *)aSelector)) {
        return nil;
    }
    if (ps_should_hide_selector_for_target_class((Class)self, aSelector, __builtin_return_address(0))) {
        return nil;
    }
    return s_orig_nsobject_instanceMethodSignatureForSelector ? s_orig_nsobject_instanceMethodSignatureForSelector(self, _cmd, aSelector) : nil;
}

static IMP ps_hook_nsobject_methodForSelector(id self, SEL _cmd, SEL aSelector) {
    if (pt_is_valid_user_pointer((const void *)aSelector) &&
        ps_should_hide_selector_for_target_class(object_getClass(self), aSelector, __builtin_return_address(0)) &&
        s_nsobject_notFoundIMP != NULL) {
        return s_nsobject_notFoundIMP;
    }
    return s_orig_nsobject_methodForSelector ? s_orig_nsobject_methodForSelector(self, _cmd, aSelector) : s_nsobject_notFoundIMP;
}

static IMP ps_hook_nsobject_instanceMethodForSelector(id self, SEL _cmd, SEL aSelector) {
    if (pt_is_valid_user_pointer((const void *)aSelector) &&
        ps_should_hide_selector_for_target_class((Class)self, aSelector, __builtin_return_address(0)) &&
        s_nsobject_notFoundIMP != NULL) {
        return s_nsobject_notFoundIMP;
    }
    return s_orig_nsobject_instanceMethodForSelector ? s_orig_nsobject_instanceMethodForSelector(self, _cmd, aSelector) : s_nsobject_notFoundIMP;
}

__attribute__((visibility("hidden"))) void ps_install_nsobject_reflection_hooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class nsObjCls = objc_getClass("NSObject");
        if (nsObjCls == Nil) {
            return;
        }
        Class nsObjMeta = object_getClass((id)nsObjCls);
        s_nsobject_notFoundIMP = [nsObjCls instanceMethodForSelector:sel_registerName("__pt_ps_nonexistent_sel_lookup__")];
        Method m = class_getInstanceMethod(nsObjCls, @selector(respondsToSelector:));
        if (m != NULL) {
            IMP origBefore = method_getImplementation(m);
            IMP prev = class_replaceMethod(
                nsObjCls, @selector(respondsToSelector:), (IMP)ps_hook_nsobject_respondsToSelector, method_getTypeEncoding(m));
            IMP orig = prev ?: origBefore;
            s_orig_nsobject_respondsToSelector = (BOOL (*)(id, SEL, SEL))orig;
            pt_register_swizzled_imp((const void *)ps_hook_nsobject_respondsToSelector, (const void *)orig);
        }
        m = class_getClassMethod(nsObjCls, @selector(instancesRespondToSelector:));
        if (m != NULL && nsObjMeta != Nil) {
            IMP origBefore = method_getImplementation(m);
            IMP prev = class_replaceMethod(
                nsObjMeta, @selector(instancesRespondToSelector:), (IMP)ps_hook_nsobject_instancesRespondToSelector, method_getTypeEncoding(m));
            IMP orig = prev ?: origBefore;
            s_orig_nsobject_instancesRespondToSelector = (BOOL (*)(id, SEL, SEL))orig;
            pt_register_swizzled_imp((const void *)ps_hook_nsobject_instancesRespondToSelector, (const void *)orig);
        }
        m = class_getInstanceMethod(nsObjCls, @selector(methodSignatureForSelector:));
        if (m != NULL) {
            IMP origBefore = method_getImplementation(m);
            IMP prev = class_replaceMethod(
                nsObjCls, @selector(methodSignatureForSelector:), (IMP)ps_hook_nsobject_methodSignatureForSelector, method_getTypeEncoding(m));
            IMP orig = prev ?: origBefore;
            s_orig_nsobject_methodSignatureForSelector = (id (*)(id, SEL, SEL))orig;
            pt_register_swizzled_imp((const void *)ps_hook_nsobject_methodSignatureForSelector, (const void *)orig);
        }
        m = class_getClassMethod(nsObjCls, @selector(instanceMethodSignatureForSelector:));
        if (m != NULL && nsObjMeta != Nil) {
            IMP origBefore = method_getImplementation(m);
            IMP prev = class_replaceMethod(
                nsObjMeta, @selector(instanceMethodSignatureForSelector:), (IMP)ps_hook_nsobject_instanceMethodSignatureForSelector, method_getTypeEncoding(m));
            IMP orig = prev ?: origBefore;
            s_orig_nsobject_instanceMethodSignatureForSelector = (id (*)(id, SEL, SEL))orig;
            pt_register_swizzled_imp((const void *)ps_hook_nsobject_instanceMethodSignatureForSelector, (const void *)orig);
        }
        m = class_getInstanceMethod(nsObjCls, @selector(methodForSelector:));
        if (m != NULL) {
            IMP origBefore = method_getImplementation(m);
            IMP prev = class_replaceMethod(
                nsObjCls, @selector(methodForSelector:), (IMP)ps_hook_nsobject_methodForSelector, method_getTypeEncoding(m));
            IMP orig = prev ?: origBefore;
            s_orig_nsobject_methodForSelector = (IMP (*)(id, SEL, SEL))orig;
            pt_register_swizzled_imp((const void *)ps_hook_nsobject_methodForSelector, (const void *)orig);
        }
        m = class_getClassMethod(nsObjCls, @selector(instanceMethodForSelector:));
        if (m != NULL && nsObjMeta != Nil) {
            IMP origBefore = method_getImplementation(m);
            IMP prev = class_replaceMethod(
                nsObjMeta, @selector(instanceMethodForSelector:), (IMP)ps_hook_nsobject_instanceMethodForSelector, method_getTypeEncoding(m));
            IMP orig = prev ?: origBefore;
            s_orig_nsobject_instanceMethodForSelector = (IMP (*)(id, SEL, SEL))orig;
            pt_register_swizzled_imp((const void *)ps_hook_nsobject_instanceMethodForSelector, (const void *)orig);
        }
    });
}
