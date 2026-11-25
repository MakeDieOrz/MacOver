//
//  PTDyldVirtualizer.m
//  PlayTools
//

#import "PTDyldInternal.h"
#import "PTArm64StubMath.h"
#import "PTSystemSpooferInternal.h"
#import "PTFSInternal.h"

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
                PT_HAS_PREFIX_LIT(name, "PTPendingTouch") ||
                PT_HAS_PREFIX_LIT(name, "PTNetwork") ||
                PT_HAS_PREFIX_LIT(name, "PTMediaVolumeHooks") ||
                PT_HAS_PREFIX_LIT(name, "PSSwizzleHooks") ||
                PT_HAS_PREFIX_LIT(name, "PSNetwork") ||
                PT_HAS_PREFIX_LIT(name, "PSVirtual") ||
                PT_HAS_PREFIX_LIT(name, "PSVFile") ||
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
                PT_HAS_PREFIX_LIT(name, "NSTouchBar") ||
                strcmp(name, "NSAlert") == 0 ||
                strcmp(name, "NSColorPanel") == 0 ||
                strcmp(name, "NSFontPanel") == 0 ||
                PT_HAS_PREFIX_LIT(name, "NSToolbar") ||
                strcmp(name, "NSDocumentController") == 0 ||
                strcmp(name, "NSDocument") == 0 ||
                strcmp(name, "NSImage") == 0 ||
                strcmp(name, "NSBezierPath") == 0 ||
                strcmp(name, "NSBitmapImageRep") == 0 ||
                strcmp(name, "NSButton") == 0 ||
                strcmp(name, "NSTextField") == 0 ||
                strcmp(name, "NSScrollView") == 0 ||
                strcmp(name, "NSTableView") == 0 ||
                strcmp(name, "NSPopover") == 0 ||
                strcmp(name, "NSSplitView") == 0 ||
                strcmp(name, "NSResponder") == 0 ||
                strcmp(name, "NSAppearance") == 0 ||
                strcmp(name, "NSGraphicsContext") == 0 ||
                strcmp(name, "NSColorSpace") == 0 ||
                strcmp(name, "NSPrintInfo") == 0 ||
                PT_HAS_PREFIX_LIT(name, "NSSharingService") ||
                PT_HAS_PREFIX_LIT(name, "NSUserNotification") ||
                strcmp(name, "NSFontManager") == 0 ||
                strcmp(name, "NSSound") == 0) {
                return YES;
            }
            break;
        case 'U':
            if (PT_HAS_PREFIX_LIT(name, "UINS") ||
                PT_HAS_PREFIX_LIT(name, "UIKitMacHelper") ||
                strcmp(name, "UITitlebar") == 0) {
                return YES;
            }
            break;
        case 'V':
            if (PT_HAS_PREFIX_LIT(name, "ViewBridge")) {
                return YES;
            }
            break;
        case '_':
            if (PT_HAS_PREFIX_LIT(name, "_UINS") ||
                PT_HAS_PREFIX_LIT(name, "_NSWindow") ||
                PT_HAS_PREFIX_LIT(name, "_NSApplication")) {
                return YES;
            }
            break;
        default:
            break;
    }
    if (pt_is_compat13_7_active()) {
        switch (name[0]) {
            case 'A':
                if (strcmp(name, "ATTrackingManager") == 0 ||
                    strcmp(name, "ASAuthorizationPlatformPublicKeyCredentialProvider") == 0) {
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
                if (strcmp(name, "SKOverlay") == 0 ||
                    strcmp(name, "SKAdImpression") == 0) {
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
                    strcmp(name, "UICalendarSelection") == 0 ||
                    strcmp(name, "UIEditMenuInteraction") == 0 ||
                    strcmp(name, "UIFindInteraction") == 0 ||
                    strcmp(name, "UIShape") == 0 ||
                    strcmp(name, "UIContentUnavailableConfiguration") == 0 ||
                    strcmp(name, "UIPasteControl") == 0 ||
                    strcmp(name, "UIHoverStyle") == 0 ||
                    strcmp(name, "UTType") == 0) {
                    return YES;
                }
                break;
            case 'W':
                if (strcmp(name, "WKContentWorld") == 0 ||
                    strcmp(name, "WKFindConfiguration") == 0 ||
                    strcmp(name, "WKPDFConfiguration") == 0) {
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
            strstr(name, "PTFake") != NULL) {
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
        strcmp(name, "NSToolbarDelegate") == 0 ||
        strcmp(name, "NSTableViewDelegate") == 0 ||
        strcmp(name, "NSTableViewDataSource") == 0 ||
        strcmp(name, "NSOutlineViewDelegate") == 0 ||
        strcmp(name, "NSOutlineViewDataSource") == 0 ||
        strcmp(name, "NSSplitViewDelegate") == 0 ||
        strcmp(name, "NSPopoverDelegate") == 0 ||
        strcmp(name, "NSOpenSavePanelDelegate") == 0 ||
        strcmp(name, "NSTouchBarDelegate") == 0 ||
        strcmp(name, "NSTouchBarProvider") == 0 ||
        strcmp(name, "NSUserInterfaceValidations") == 0 ||
        strcmp(name, "NSDraggingSource") == 0 ||
        strcmp(name, "NSDraggingDestination") == 0 ||
        strcmp(name, "NSServicesMenuRequestor") == 0 ||
        strcmp(name, "NSWindowRestoration") == 0 ||
        strcmp(name, "NSControlTextEditingDelegate") == 0 ||
        strcmp(name, "NSTextFieldDelegate") == 0 ||
        strcmp(name, "NSSharingServiceDelegate") == 0 ||
        strcmp(name, "NSAnimatablePropertyContainer") == 0 ||
        strcmp(name, "NSAppearanceCustomization") == 0) {
        return YES;
    }
    if (pt_is_compat13_7_active()) {
        if (strcmp(name, "PHPickerViewControllerDelegate") == 0 ||
            strcmp(name, "UIColorPickerViewControllerDelegate") == 0 ||
            strcmp(name, "SKOverlayDelegate") == 0 ||
            strcmp(name, "WKScriptMessageHandlerWithReply") == 0 ||
            strcmp(name, "UICalendarViewDelegate") == 0 ||
            strcmp(name, "UISheetPresentationControllerDelegate") == 0 ||
            strcmp(name, "UIEditMenuInteractionDelegate") == 0 ||
            strcmp(name, "UIFindInteractionDelegate") == 0 ||
            strcmp(name, "GCDevicePhysicalInput") == 0 ||
            strcmp(name, "MTLCounterSampleBuffer") == 0 ||
            strcmp(name, "MTLCounterSet") == 0) {
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

__attribute__((visibility("hidden"))) BOOL pt_is_app_embedded_bundle_path(const char *path) {
    if (path == NULL || path[0] != '/') {
        return NO;
    }
    if (strstr(path, ".app/Frameworks/") != NULL ||
        strstr(path, ".app/PlugIns/") != NULL ||
        strstr(path, ".app/Contents/Frameworks/") != NULL ||
        strstr(path, ".app/Contents/PlugIns/") != NULL ||
        strstr(path, ".appex/Frameworks/") != NULL) {
        return YES;
    }
    if (s_real_app_bundle_len > 0 &&
        pt_match_prefix_modulo_private(path, s_real_app_bundle_dir, s_real_app_bundle_len) != NULL) {
        return YES;
    }
    return NO;
}

__attribute__((visibility("hidden"))) BOOL pt_is_macos_only_framework_path(const char *name) {
    if (name == NULL || name[0] == '\0' || pt_is_app_embedded_bundle_path(name)) {
        return NO;
    }
    return pt_is_macos_only_framework_path_cstr(name) ? YES : NO;
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
            pt_is_macos_only_framework_path(name));
}

__attribute__((visibility("hidden"))) BOOL pt_should_hide_dyld_image(const char *name) {
    return pt_is_hidden_dyld_image_name(name) || pt_is_post13_7_hidden_framework_path(name);
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

__attribute__((visibility("hidden"))) _Atomic uint64_t s_dyld_generation = 0;

static pt_dyld_virtual_table_t s_dyld_vtable = {
    .lock = OS_UNFAIR_LOCK_INIT,
    .real_count = 0,
    .virtual_count = 0,
    .generation = UINT64_MAX,
    .reg_generation = UINT64_MAX,
    .virtual_to_real = NULL
};

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

__attribute__((visibility("hidden"))) uint32_t pt_dyld_virtual_count(void) {
    if (atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        pt_ensure_dyld_master_callbacks();
    }
    os_unfair_lock_lock(&s_dyld_vtable.lock);
    pt_dyld_vtable_refresh_locked();
    uint32_t vcount = s_dyld_vtable.virtual_count;
    os_unfair_lock_unlock(&s_dyld_vtable.lock);
    return vcount;
}

__attribute__((visibility("hidden"))) BOOL pt_dyld_virtual_to_real_index(uint32_t virtual_idx, uint32_t *out_real_idx) {
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

__attribute__((visibility("hidden"))) uint32_t pt_fallback_system_image_index(void) {
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

__attribute__((visibility("hidden"))) const void *pt_strip_code_ptr(const void *p) {
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
    const char *name = (sel != NULL) ? sel_getName(sel) : NULL;
    if (name != NULL) {
        pt_ptr_set_insert(s_hidden_swizzle_sel_set, (uintptr_t)name);
    }
}

__attribute__((visibility("hidden"))) BOOL pt_is_registered_hidden_swizzle_selector(SEL sel) {
    const char *name = (sel != NULL) ? sel_getName(sel) : NULL;
    return (name != NULL) && pt_ptr_set_contains(s_hidden_swizzle_sel_set, (uintptr_t)name);
}

__attribute__((visibility("hidden"))) BOOL pt_is_swizzled_orig_imp(const void *addr) {
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

__attribute__((visibility("hidden"))) const void *pt_lookup_swizzled_raw_orig_imp(const void *addr) {
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

__attribute__((visibility("hidden"))) const void *pt_resolve_interposed_target(const void *addr) {
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

static const void *pt_resolve_dyld_interposed_only(const void *addr) {
    if (addr == NULL) {
        return NULL;
    }
    const void *stripped = pt_strip_code_ptr(addr);
    if (stripped != addr) {
        return NULL;
    }
    pthread_once(&s_interpose_once, pt_init_interpose_tuples);
    for (size_t i = 0; i < s_interpose_count; i++) {
        if (pt_strip_code_ptr(s_interpose_tuples[i].replacement) == addr &&
            s_interpose_tuples[i].replacee != NULL &&
            pt_strip_code_ptr(s_interpose_tuples[i].replacee) == s_interpose_tuples[i].replacee) {
            return s_interpose_tuples[i].replacee;
        }
    }
    return NULL;
}

#if defined(__arm64__) || defined(__aarch64__)
#define PT_MAX_GOT_CLOAK_MHS 512U

static os_unfair_lock s_got_cloak_lock = OS_UNFAIR_LOCK_INIT;
static const struct mach_header *s_got_cloaked_mhs[PT_MAX_GOT_CLOAK_MHS];
static uint32_t s_got_cloaked_count = 0;
static _Atomic bool s_got_cloak_inited = false;

static BOOL pt_is_got_cloaked_mh(const struct mach_header *mh) {
    os_unfair_lock_lock(&s_got_cloak_lock);
    for (uint32_t i = 0; i < s_got_cloaked_count; i++) {
        if (s_got_cloaked_mhs[i] == mh) {
            os_unfair_lock_unlock(&s_got_cloak_lock);
            return YES;
        }
    }
    os_unfair_lock_unlock(&s_got_cloak_lock);
    return NO;
}

static void pt_mark_got_cloaked_mh(const struct mach_header *mh) {
    os_unfair_lock_lock(&s_got_cloak_lock);
    for (uint32_t i = 0; i < s_got_cloaked_count; i++) {
        if (s_got_cloaked_mhs[i] == mh) {
            os_unfair_lock_unlock(&s_got_cloak_lock);
            return;
        }
    }
    if (s_got_cloaked_count < PT_MAX_GOT_CLOAK_MHS) {
        s_got_cloaked_mhs[s_got_cloaked_count++] = mh;
    }
    os_unfair_lock_unlock(&s_got_cloak_lock);
}

static void pt_restore_one_nonlazy_got_section(const char *img_path,
                                               uintptr_t stubs_start,
                                               uintptr_t stubs_size,
                                               uint32_t stubs_stride,
                                               uintptr_t got_start,
                                               uintptr_t got_size) {
    size_t got_count = (size_t)(got_size / sizeof(void *));
    if (got_count == 0 || got_count > 262144U) {
        return;
    }

    uint64_t stack_bits[512];
    size_t word_count = (got_count + 63U) / 64U;
    uint64_t *heap_bits = NULL;
    uint64_t *stubbed_bits = stack_bits;
    if (word_count > (sizeof(stack_bits) / sizeof(stack_bits[0]))) {
        heap_bits = (uint64_t *)calloc(word_count, sizeof(uint64_t));
        if (heap_bits == NULL) {
            return;
        }
        stubbed_bits = heap_bits;
    } else {
        memset(stack_bits, 0, word_count * sizeof(uint64_t));
    }

    uintptr_t got_end = got_start + got_size;
    uintptr_t stubs_end = stubs_start + stubs_size;
    for (uintptr_t stub_pc = stubs_start; stub_pc < stubs_end; stub_pc += (uintptr_t)stubs_stride) {
        uintptr_t slot_addr = 0;
        if (!pt_decode_arm64_stub_target_slot(stub_pc, (const uint32_t *)stub_pc, stubs_stride, &slot_addr)) {
            // Fail closed if any stub does not match recognized ARM64 stub sequences.
            free(heap_bits);
            return;
        }
        if (slot_addr >= got_start && slot_addr < got_end &&
            ((slot_addr - got_start) % sizeof(void *)) == 0) {
            size_t idx = (size_t)((slot_addr - got_start) / sizeof(void *));
            stubbed_bits[idx >> 6] |= (1ULL << (idx & 63U));
        }
    }

    void **got_slots = (void **)got_start;
    size_t pending = 0;
    for (size_t k = 0; k < got_count; k++) {
        if ((stubbed_bits[k >> 6] & (1ULL << (k & 63U))) != 0ULL) {
            continue;
        }
        if (pt_resolve_dyld_interposed_only(got_slots[k]) != NULL) {
            pending++;
        }
    }
    if (pending == 0) {
        free(heap_bits);
        return;
    }

    uintptr_t page_sz = (vm_page_size > 0) ? (uintptr_t)vm_page_size : 16384U;
    if (got_end > UINTPTR_MAX - (page_sz - 1U)) {
        free(heap_bits);
        return;
    }
    uintptr_t page_start = got_start & ~(page_sz - 1U);
    uintptr_t page_end = (got_end + page_sz - 1U) & ~(page_sz - 1U);
    size_t restored_count = 0;

    for (uintptr_t page_addr = page_start; page_addr < page_end; page_addr += page_sz) {
        uintptr_t ov_start = (page_addr > got_start) ? page_addr : got_start;
        uintptr_t page_limit = page_addr + page_sz;
        uintptr_t ov_end = (page_limit < got_end) ? page_limit : got_end;
        if (ov_start >= ov_end) {
            continue;
        }
        size_t idx_begin = (size_t)((ov_start - got_start) / sizeof(void *));
        size_t idx_end = (size_t)((ov_end - got_start) / sizeof(void *));
        BOOL page_has_target = NO;
        for (size_t k = idx_begin; k < idx_end; k++) {
            if ((stubbed_bits[k >> 6] & (1ULL << (k & 63U))) == 0ULL &&
                pt_resolve_dyld_interposed_only(got_slots[k]) != NULL) {
                page_has_target = YES;
                break;
            }
        }
        if (!page_has_target) {
            continue;
        }

        vm_address_t raddr = (vm_address_t)page_addr;
        vm_size_t rsize = 0;
        vm_region_basic_info_data_64_t rinfo;
        mach_msg_type_number_t rcnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        kern_return_t rkr = vm_region_64(mach_task_self(),
                                         &raddr,
                                         &rsize,
                                         VM_REGION_BASIC_INFO_64,
                                         (vm_region_info_t)&rinfo,
                                         &rcnt,
                                         &obj);
        if (MACH_PORT_VALID(obj)) {
            mach_port_deallocate(mach_task_self(), obj);
        }
        if (rkr != KERN_SUCCESS ||
            raddr > (vm_address_t)page_addr ||
            (vm_address_t)page_addr + page_sz > raddr + rsize) {
            continue;
        }

        vm_prot_t orig_prot = rinfo.protection;
        BOOL changed_prot = NO;
        if ((orig_prot & VM_PROT_WRITE) == 0) {
            kern_return_t pkr = vm_protect(mach_task_self(),
                                           (vm_address_t)page_addr,
                                           (vm_size_t)page_sz,
                                           FALSE,
                                           orig_prot | VM_PROT_WRITE);
            if (pkr != KERN_SUCCESS) {
                pkr = vm_protect(mach_task_self(),
                                 (vm_address_t)page_addr,
                                 (vm_size_t)page_sz,
                                 FALSE,
                                 orig_prot | VM_PROT_WRITE | VM_PROT_COPY);
            }
            if (pkr != KERN_SUCCESS) {
                continue;
            }
            changed_prot = YES;
        }

        for (size_t k = idx_begin; k < idx_end; k++) {
            if ((stubbed_bits[k >> 6] & (1ULL << (k & 63U))) != 0ULL) {
                continue;
            }
            const void *orig_ptr = pt_resolve_dyld_interposed_only(got_slots[k]);
            if (orig_ptr != NULL) {
                __atomic_store_n(&got_slots[k], (void *)orig_ptr, __ATOMIC_RELEASE);
                restored_count++;
            }
        }

        if (changed_prot) {
            (void)vm_protect(mach_task_self(),
                             (vm_address_t)page_addr,
                             (vm_size_t)page_sz,
                             FALSE,
                             orig_prot);
        }
    }

    if (restored_count > 0) {
        PT_DEBUG_TRACE("dyld",
                       "restored %zu un-stubbed non-lazy GOT slots in %s",
                       restored_count,
                       img_path);
    }
    free(heap_bits);
}

static void pt_restore_unstubbed_nonlazy_got_for_image(const struct mach_header *mh,
                                                       intptr_t vmaddr_slide) {
    if (!pt_is_bypass_enabled() || mh == NULL || !pt_is_valid_user_pointer(mh)) {
        return;
    }
    const struct mach_header_64 *mh64 = (const struct mach_header_64 *)mh;
    uint32_t cpu_sub = (uint32_t)mh64->cpusubtype & ~(uint32_t)CPU_SUBTYPE_MASK;
    if (mh64->magic != MH_MAGIC_64 ||
        mh64->cputype != CPU_TYPE_ARM64 ||
        cpu_sub == CPU_SUBTYPE_ARM64E ||
        mh64->sizeofcmds == 0 ||
        mh64->sizeofcmds > (1U << 20)) {
        return;
    }

    const char *img_path = dyld_image_path_containing_address((const void *)mh);
    if (img_path == NULL) {
        return;
    }
    bool cacheable = false;
    if (pt_classify_caller_image_path(img_path, &cacheable) != PT_CALLER_APP) {
        return;
    }
    if (pt_should_hide_dyld_image(img_path) ||
        pt_is_hidden_dyld_image_header(mh) ||
        pt_is_address_in_playtools((const void *)mh)) {
        return;
    }
    if (pt_is_got_cloaked_mh(mh)) {
        return;
    }

    uintptr_t stubs_start = 0;
    uintptr_t stubs_size = 0;
    uint32_t stubs_stride = 0;
    pt_got_sec_range_t got_secs[PT_MAX_NONLAZY_GOT_SECS];
    uint32_t got_sec_count = 0;
    if (!pt_collect_two_table_macho_sections(mh64,
                                             vmaddr_slide,
                                             &stubs_start,
                                             &stubs_size,
                                             &stubs_stride,
                                             got_secs,
                                             &got_sec_count)) {
        pt_mark_got_cloaked_mh(mh);
        return;
    }

    for (uint32_t g = 0; g < got_sec_count; g++) {
        pt_restore_one_nonlazy_got_section(img_path,
                                           stubs_start,
                                           stubs_size,
                                           stubs_stride,
                                           got_secs[g].start,
                                           got_secs[g].size);
    }
    pt_mark_got_cloaked_mh(mh);
}

static void pt_got_cloak_on_dyld_image_added(const struct mach_header *mh, intptr_t vmaddr_slide) {
    pt_restore_unstubbed_nonlazy_got_for_image(mh, vmaddr_slide);
}
#endif /* defined(__arm64__) || defined(__aarch64__) */

__attribute__((visibility("hidden")))
void pt_init_nonlazy_got_cloaking(void) {
#if defined(__arm64__) || defined(__aarch64__)
    if (atomic_exchange_explicit(&s_got_cloak_inited, true, memory_order_acq_rel)) {
        return;
    }
    pthread_once(&s_interpose_once, pt_init_interpose_tuples);
    _dyld_register_func_for_add_image(pt_got_cloak_on_dyld_image_added);
#endif
}

static const struct mach_header_64 *pt_validated_app_arm64_header_for_addr(uintptr_t addr) {
#if defined(__arm64__) || defined(__aarch64__)
    const struct mach_header *mh = dyld_image_header_containing_address((const void *)addr);
    if (mh == NULL || !pt_is_valid_user_pointer((const void *)mh)) {
        return NULL;
    }
    const struct mach_header_64 *mh64 = (const struct mach_header_64 *)mh;
    uint32_t cpu_sub = (uint32_t)mh64->cpusubtype & ~(uint32_t)CPU_SUBTYPE_MASK;
    if (mh64->magic != MH_MAGIC_64 ||
        mh64->cputype != CPU_TYPE_ARM64 ||
        cpu_sub == CPU_SUBTYPE_ARM64E ||
        mh64->sizeofcmds == 0 ||
        mh64->sizeofcmds > (1U << 20)) {
        return NULL;
    }
    const char *img_path = dyld_image_path_containing_address((const void *)mh);
    if (img_path == NULL) {
        return NULL;
    }
    bool cacheable = false;
    if (pt_classify_caller_image_path(img_path, &cacheable) != PT_CALLER_APP ||
        pt_should_hide_dyld_image(img_path) ||
        pt_is_hidden_dyld_image_header(mh) ||
        pt_is_address_in_playtools((const void *)mh)) {
        return NULL;
    }
    return mh64;
#else
    (void)addr;
    return NULL;
#endif
}

__attribute__((visibility("hidden")))
void pt_dyld_sanitize_got_ptrs_in_vm_read_buffer(uintptr_t read_start, uint8_t *dst, size_t copied) {
#if defined(__arm64__) || defined(__aarch64__)
    if (dst == NULL || copied < sizeof(void *) || read_start > UINTPTR_MAX - copied || !pt_is_bypass_enabled()) {
        return;
    }
    uintptr_t read_end = read_start + copied;
    const struct mach_header_64 *mh64 = pt_validated_app_arm64_header_for_addr(read_start);
    if (mh64 == NULL) {
        mh64 = pt_validated_app_arm64_header_for_addr(read_end - 1U);
    }
    if (mh64 == NULL) {
        return;
    }

    const uint8_t *base = (const uint8_t *)mh64;
    size_t total = sizeof(struct mach_header_64) + (size_t)mh64->sizeofcmds;
    size_t off = sizeof(struct mach_header_64);
    uintptr_t slide = 0;
    BOOL has_text = NO;
    for (uint32_t i = 0; i < mh64->ncmds && off + sizeof(struct load_command) <= total; i++) {
        const struct load_command *lc = (const struct load_command *)(base + off);
        if (lc->cmdsize < sizeof(struct load_command) || off + lc->cmdsize > total) {
            break;
        }
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strncmp(seg->segname, "__TEXT", 16) == 0) {
                slide = (uintptr_t)mh64 - (uintptr_t)seg->vmaddr;
                has_text = YES;
                break;
            }
        }
        off += lc->cmdsize;
    }
    if (!has_text) {
        return;
    }

    off = sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < mh64->ncmds && off + sizeof(struct load_command) <= total; i++) {
        const struct load_command *lc = (const struct load_command *)(base + off);
        if (lc->cmdsize < sizeof(struct load_command) || off + lc->cmdsize > total) {
            break;
        }
        off += lc->cmdsize;
        if (lc->cmd != LC_SEGMENT_64 || lc->cmdsize < sizeof(struct segment_command_64)) {
            continue;
        }
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        if ((size_t)seg->nsects > (lc->cmdsize - sizeof(struct segment_command_64)) / sizeof(struct section_64)) {
            break;
        }
        const struct section_64 *sects = (const struct section_64 *)(seg + 1);
        for (uint32_t s = 0; s < seg->nsects; s++) {
            uint32_t stype = sects[s].flags & SECTION_TYPE;
            if ((stype != S_NON_LAZY_SYMBOL_POINTERS && stype != S_LAZY_SYMBOL_POINTERS) ||
                strncmp(sects[s].sectname, "__auth_", 7) == 0) {
                continue;
            }
            uintptr_t s_addr = (uintptr_t)sects[s].addr + slide;
            uintptr_t s_size = (uintptr_t)sects[s].size;
            if (s_size < sizeof(void *) ||
                s_size > UINTPTR_MAX - s_addr ||
                (s_addr % sizeof(void *)) != 0) {
                continue;
            }
            uintptr_t s_end = s_addr + s_size;
            uintptr_t ov_start = (read_start > s_addr) ? read_start : s_addr;
            uintptr_t ov_end = (read_end < s_end) ? read_end : s_end;
            if (ov_start >= ov_end ||
                ov_end - ov_start < sizeof(void *) ||
                ov_start > UINTPTR_MAX - (sizeof(void *) - 1U)) {
                continue;
            }
            uintptr_t slot_addr = (ov_start + (sizeof(void *) - 1U)) & ~(sizeof(void *) - 1U);
            while (slot_addr <= ov_end - sizeof(void *)) {
                size_t dst_off = (size_t)(slot_addr - read_start);
                const void *val = NULL;
                memcpy(&val, dst + dst_off, sizeof(val));
                const void *orig = pt_resolve_dyld_interposed_only(val);
                if (orig != NULL) {
                    memcpy(dst + dst_off, &orig, sizeof(orig));
                }
                if (ov_end - slot_addr < 2U * sizeof(void *)) {
                    break;
                }
                slot_addr += sizeof(void *);
            }
        }
    }
#else
    (void)read_start;
    (void)dst;
    (void)copied;
#endif
}

// Define dyld platform functions for interpose
extern int dyld_get_active_platform(void) __attribute__((weak_import));
static int pt_dyld_get_active_platform(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return PLATFORM_IOS;
    }
    return (dyld_get_active_platform != NULL) ? dyld_get_active_platform() : PLATFORM_IOS;
}

extern uint32_t dyld_get_base_platform(uint32_t platform) __attribute__((weak_import));
static uint32_t pt_dyld_get_base_platform(uint32_t platform) {
    if ((platform == PLATFORM_MACCATALYST || platform == PLATFORM_IOS) &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return PLATFORM_IOS;
    }
    return (dyld_get_base_platform != NULL) ? dyld_get_base_platform(platform) : platform;
}

extern void pt_orig_dyld_get_image_versions(
    const struct mach_header *mh,
    void (^callback)(uint32_t platform, uint32_t sdk_version, uint32_t min_version))
    __asm__("_dyld_get_image_versions") __attribute__((weak_import));

static void pt_dyld_get_image_versions(
    const struct mach_header *mh,
    void (^callback)(uint32_t platform, uint32_t sdk_version, uint32_t min_version)) {
    if (pt_orig_dyld_get_image_versions == NULL || mh == NULL || callback == NULL) {
        return;
    }
    const void *caller = __builtin_return_address(0);
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
        const struct mach_header *lc_mh = pt_maybe_shadow_mach_header(mh);
        BOOL compat13 = pt_is_compat13_7_active();
        pt_orig_dyld_get_image_versions(lc_mh, ^(uint32_t platform, uint32_t sdk_version, uint32_t min_version) {
            if (platform == 1U || platform == PLATFORM_MACCATALYST) {
                platform = PLATFORM_IOS;
            }
            if (compat13) {
                if (sdk_version > 0x0d0700U) {
                    sdk_version = 0x0d0700U;
                }
                if (min_version > 0x0d0700U) {
                    min_version = 0x0d0700U;
                }
            }
            callback(platform, sdk_version, min_version);
        });
        return;
    }
    pt_orig_dyld_get_image_versions(pt_uncloak_shadow_mach_header(mh), callback);
}

static inline BOOL pt_dyld_version_query_blocked_for_app(pt_dyld_build_version_t version) {
    if (version.platform == 1U || version.platform == PLATFORM_MACCATALYST) {
        return YES;
    }
    if (pt_is_compat13_7_active() && version.platform == PLATFORM_IOS && version.version > 0x0d0700U) {
        return YES;
    }
    return NO;
}

extern bool pt_orig_dyld_sdk_at_least(const struct mach_header *mh, pt_dyld_build_version_t version)
    __asm__("_dyld_sdk_at_least") __attribute__((weak_import));

static bool pt_dyld_sdk_at_least(const struct mach_header *mh, pt_dyld_build_version_t version) {
    if (pt_orig_dyld_sdk_at_least == NULL || mh == NULL) {
        return false;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_dyld_version_query_blocked_for_app(version)) {
            return false;
        }
        const struct mach_header *lc_mh = pt_maybe_shadow_mach_header(mh);
        return pt_orig_dyld_sdk_at_least(lc_mh, version);
    }
    return pt_orig_dyld_sdk_at_least(pt_uncloak_shadow_mach_header(mh), version);
}

extern bool pt_orig_dyld_minos_at_least(const struct mach_header *mh, pt_dyld_build_version_t version)
    __asm__("_dyld_minos_at_least") __attribute__((weak_import));

static bool pt_dyld_minos_at_least(const struct mach_header *mh, pt_dyld_build_version_t version) {
    if (pt_orig_dyld_minos_at_least == NULL || mh == NULL) {
        return false;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_dyld_version_query_blocked_for_app(version)) {
            return false;
        }
        const struct mach_header *lc_mh = pt_maybe_shadow_mach_header(mh);
        return pt_orig_dyld_minos_at_least(lc_mh, version);
    }
    return pt_orig_dyld_minos_at_least(pt_uncloak_shadow_mach_header(mh), version);
}

extern uint32_t pt_orig_dyld_get_sdk_version(const struct mach_header *mh)
    __asm__("_dyld_get_sdk_version") __attribute__((weak_import));

static uint32_t pt_dyld_get_sdk_version(const struct mach_header *mh) {
    if (pt_orig_dyld_get_sdk_version == NULL || mh == NULL) {
        return 0;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        uint32_t v = pt_orig_dyld_get_sdk_version(pt_maybe_shadow_mach_header(mh));
        if (pt_is_compat13_7_active() && v > 0x0d0700U) {
            return 0x0d0700U;
        }
        return v;
    }
    return pt_orig_dyld_get_sdk_version(pt_uncloak_shadow_mach_header(mh));
}

extern uint32_t pt_orig_dyld_get_min_os_version(const struct mach_header *mh)
    __asm__("_dyld_get_min_os_version") __attribute__((weak_import));

static uint32_t pt_dyld_get_min_os_version(const struct mach_header *mh) {
    if (pt_orig_dyld_get_min_os_version == NULL || mh == NULL) {
        return 0;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        uint32_t v = pt_orig_dyld_get_min_os_version(pt_maybe_shadow_mach_header(mh));
        if (pt_is_compat13_7_active() && v > 0x0d0700U) {
            return 0x0d0700U;
        }
        return v;
    }
    return pt_orig_dyld_get_min_os_version(pt_uncloak_shadow_mach_header(mh));
}

extern uint32_t pt_orig_dyld_get_program_sdk_version(void)
    __asm__("_dyld_get_program_sdk_version") __attribute__((weak_import));

static uint32_t pt_dyld_get_program_sdk_version(void) {
    if (pt_orig_dyld_get_program_sdk_version == NULL) {
        return 0;
    }
    uint32_t v = pt_orig_dyld_get_program_sdk_version();
    if (pt_is_bypass_enabled() &&
        pt_is_compat13_7_active() &&
        v > 0x0d0700U &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return 0x0d0700U;
    }
    return v;
}

extern uint32_t pt_orig_dyld_get_program_min_os_version(void)
    __asm__("_dyld_get_program_min_os_version") __attribute__((weak_import));

static uint32_t pt_dyld_get_program_min_os_version(void) {
    if (pt_orig_dyld_get_program_min_os_version == NULL) {
        return 0;
    }
    uint32_t v = pt_orig_dyld_get_program_min_os_version();
    if (pt_is_bypass_enabled() &&
        pt_is_compat13_7_active() &&
        v > 0x0d0700U &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return 0x0d0700U;
    }
    return v;
}

extern bool pt_orig_dyld_program_sdk_at_least(pt_dyld_build_version_t version)
    __asm__("_dyld_program_sdk_at_least") __attribute__((weak_import));

static bool pt_dyld_program_sdk_at_least(pt_dyld_build_version_t version) {
    if (pt_orig_dyld_program_sdk_at_least == NULL) {
        return false;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_dyld_version_query_blocked_for_app(version)) {
            return false;
        }
        const struct mach_header *main_mh = pt_get_main_executable_header();
        if (main_mh != NULL && pt_orig_dyld_sdk_at_least != NULL) {
            return pt_orig_dyld_sdk_at_least(pt_maybe_shadow_mach_header(main_mh), version);
        }
    }
    return pt_orig_dyld_program_sdk_at_least(version);
}

extern bool pt_orig_dyld_program_minos_at_least(pt_dyld_build_version_t version)
    __asm__("_dyld_program_minos_at_least") __attribute__((weak_import));

static bool pt_dyld_program_minos_at_least(pt_dyld_build_version_t version) {
    if (pt_orig_dyld_program_minos_at_least == NULL) {
        return false;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_dyld_version_query_blocked_for_app(version)) {
            return false;
        }
        const struct mach_header *main_mh = pt_get_main_executable_header();
        if (main_mh != NULL && pt_orig_dyld_minos_at_least != NULL) {
            return pt_orig_dyld_minos_at_least(pt_maybe_shadow_mach_header(main_mh), version);
        }
    }
    return pt_orig_dyld_program_minos_at_least(version);
}

typedef const struct mach_header *(*pt_dyld_get_prog_image_header_fn)(void);
static pt_dyld_get_prog_image_header_fn pt_resolve_dyld_get_prog_image_header(void) {
    static pt_dyld_get_prog_image_header_fn s_fn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_fn = (pt_dyld_get_prog_image_header_fn)dlsym(RTLD_NEXT, "_dyld_get_prog_image_header");
    });
    return s_fn;
}

static const struct mach_header *pt_dyld_get_prog_image_header(void) {
    pt_dyld_get_prog_image_header_fn fn = pt_resolve_dyld_get_prog_image_header();
    if (fn == NULL) {
        return _dyld_get_image_header(0);
    }
    return fn();
}

typedef const char *(*pt_dyld_shared_cache_real_path_fn)(const char *path);
static pt_dyld_shared_cache_real_path_fn pt_resolve_dyld_shared_cache_real_path(void) {
    static pt_dyld_shared_cache_real_path_fn s_fn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_fn = (pt_dyld_shared_cache_real_path_fn)dlsym(RTLD_NEXT, "_dyld_shared_cache_real_path");
    });
    return s_fn;
}

static const char *pt_dyld_shared_cache_real_path(const char *path) {
    pt_dyld_shared_cache_real_path_fn fn = pt_resolve_dyld_shared_cache_real_path();
    if (fn == NULL) {
        return NULL;
    }
    const void *caller = __builtin_return_address(0);
    if (path != NULL && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        if (strcmp(path, "/System/iOSSupport") == 0 ||
            strncmp(path, "/System/iOSSupport/", 19) == 0 ||
            strstr(path, ".framework/Versions/") != NULL ||
            pt_should_hide_dyld_image(path) ||
            pt_is_hidden_path(path, caller)) {
            return NULL;
        }
        const char *res = fn(path);
        if (res != NULL) {
            if (pt_should_hide_dyld_image(res)) {
                return NULL;
            }
            return pt_sanitize_image_path_for_app(res);
        }
        return NULL;
    }
    return fn(path);
}

typedef bool (*pt_dyld_shared_cache_some_image_overridden_fn)(void);
static pt_dyld_shared_cache_some_image_overridden_fn pt_resolve_dyld_shared_cache_some_image_overridden(void) {
    static pt_dyld_shared_cache_some_image_overridden_fn s_fn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_fn = (pt_dyld_shared_cache_some_image_overridden_fn)dlsym(RTLD_NEXT, "dyld_shared_cache_some_image_overridden");
    });
    return s_fn;
}

static bool pt_dyld_shared_cache_some_image_overridden(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return false;
    }
    pt_dyld_shared_cache_some_image_overridden_fn fn = pt_resolve_dyld_shared_cache_some_image_overridden();
    return (fn != NULL) ? fn() : false;
}

typedef bool (*pt_dyld_find_unwind_sections_fn)(void *addr, void *info);
static pt_dyld_find_unwind_sections_fn pt_resolve_dyld_find_unwind_sections(void) {
    static pt_dyld_find_unwind_sections_fn s_fn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_fn = (pt_dyld_find_unwind_sections_fn)dlsym(RTLD_NEXT, "_dyld_find_unwind_sections");
    });
    return s_fn;
}

static bool pt_dyld_find_unwind_sections(void *addr, void *info) {
    pt_dyld_find_unwind_sections_fn fn = pt_resolve_dyld_find_unwind_sections();
    if (fn == NULL) {
        return false;
    }
    if (!pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return fn(addr, info);
    }
    addr = (void *)pt_resolve_interposed_target(addr);
    const char *path = dyld_image_path_containing_address(addr);
    if (path != NULL && pt_should_hide_dyld_image(path)) {
        return false;
    }
    return fn(addr, info);
}

typedef const struct dyld_process_info_base *pt_dyld_process_info_t;
typedef pt_dyld_process_info_t (*pt_dyld_process_info_create_fn)(task_t task, uint64_t timestamp, kern_return_t *kernelError);
typedef void (*pt_dyld_process_info_for_each_image_fn)(pt_dyld_process_info_t info,
                                                       void (^callback)(uint64_t machHeaderAddress, const uuid_t uuid, const char *path));
typedef uint32_t (*pt_dyld_process_info_get_platform_fn)(pt_dyld_process_info_t info);
typedef void (*pt_dyld_process_info_get_cache_fn)(pt_dyld_process_info_t info, void *cacheInfo);
typedef void (*pt_dyld_process_info_get_state_fn)(pt_dyld_process_info_t info, void *stateInfo);

typedef struct {
    void *plain_fn;
    void *underscored_fn;
} pt_dyld_proc_info_sym_t;

static void pt_resolve_dual_dyld_sym(pt_dyld_proc_info_sym_t *out,
                                     const char *plainName,
                                     const char *underscoredName) {
    out->plain_fn = dlsym(RTLD_NEXT, plainName);
    out->underscored_fn = dlsym(RTLD_NEXT, underscoredName);
}

static const pt_dyld_proc_info_sym_t *pt_dyld_process_info_create_sym(void) {
    static pt_dyld_proc_info_sym_t s_sym = { NULL, NULL };
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pt_resolve_dual_dyld_sym(&s_sym, "dyld_process_info_create", "_dyld_process_info_create");
    });
    return &s_sym;
}

static pt_dyld_process_info_create_fn pt_resolve_dyld_process_info_create(void) {
    const pt_dyld_proc_info_sym_t *sym = pt_dyld_process_info_create_sym();
    return (pt_dyld_process_info_create_fn)(sym->underscored_fn != NULL ? sym->underscored_fn : sym->plain_fn);
}

static const pt_dyld_proc_info_sym_t *pt_dyld_process_info_for_each_image_sym(void) {
    static pt_dyld_proc_info_sym_t s_sym = { NULL, NULL };
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pt_resolve_dual_dyld_sym(&s_sym, "dyld_process_info_for_each_image", "_dyld_process_info_for_each_image");
    });
    return &s_sym;
}

static pt_dyld_process_info_for_each_image_fn pt_resolve_dyld_process_info_for_each_image(void) {
    const pt_dyld_proc_info_sym_t *sym = pt_dyld_process_info_for_each_image_sym();
    return (pt_dyld_process_info_for_each_image_fn)(sym->underscored_fn != NULL ? sym->underscored_fn : sym->plain_fn);
}

static const pt_dyld_proc_info_sym_t *pt_dyld_process_info_get_platform_sym(void) {
    static pt_dyld_proc_info_sym_t s_sym = { NULL, NULL };
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pt_resolve_dual_dyld_sym(&s_sym, "dyld_process_info_get_platform", "_dyld_process_info_get_platform");
    });
    return &s_sym;
}

static pt_dyld_process_info_get_platform_fn pt_resolve_dyld_process_info_get_platform(void) {
    const pt_dyld_proc_info_sym_t *sym = pt_dyld_process_info_get_platform_sym();
    return (pt_dyld_process_info_get_platform_fn)(sym->underscored_fn != NULL ? sym->underscored_fn : sym->plain_fn);
}

static const pt_dyld_proc_info_sym_t *pt_dyld_process_info_get_cache_sym(void) {
    static pt_dyld_proc_info_sym_t s_sym = { NULL, NULL };
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pt_resolve_dual_dyld_sym(&s_sym, "dyld_process_info_get_cache", "_dyld_process_info_get_cache");
    });
    return &s_sym;
}

static pt_dyld_process_info_get_cache_fn pt_resolve_dyld_process_info_get_cache(void) {
    const pt_dyld_proc_info_sym_t *sym = pt_dyld_process_info_get_cache_sym();
    return (pt_dyld_process_info_get_cache_fn)(sym->underscored_fn != NULL ? sym->underscored_fn : sym->plain_fn);
}

static const pt_dyld_proc_info_sym_t *pt_dyld_process_info_get_state_sym(void) {
    static pt_dyld_proc_info_sym_t s_sym = { NULL, NULL };
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pt_resolve_dual_dyld_sym(&s_sym, "dyld_process_info_get_state", "_dyld_process_info_get_state");
    });
    return &s_sym;
}

static pt_dyld_process_info_get_state_fn pt_resolve_dyld_process_info_get_state(void) {
    const pt_dyld_proc_info_sym_t *sym = pt_dyld_process_info_get_state_sym();
    return (pt_dyld_process_info_get_state_fn)(sym->underscored_fn != NULL ? sym->underscored_fn : sym->plain_fn);
}

static pt_dyld_process_info_t pt_dyld_process_info_create(task_t task, uint64_t timestamp, kern_return_t *kernelError) {
    pt_dyld_process_info_create_fn fn = pt_resolve_dyld_process_info_create();
    if (fn == NULL) {
        if (kernelError != NULL) {
            *kernelError = KERN_NOT_SUPPORTED;
        }
        return NULL;
    }
    if (task == mach_task_self() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        pt_dyld_set_force_task_dyld_sanitize(YES);
        pt_dyld_process_info_t info = fn(task, timestamp, kernelError);
        pt_dyld_set_force_task_dyld_sanitize(NO);
        return info;
    }
    return fn(task, timestamp, kernelError);
}

static void pt_dyld_process_info_for_each_image(pt_dyld_process_info_t info,
                                                void (^callback)(uint64_t machHeaderAddress, const uuid_t uuid, const char *path)) {
    pt_dyld_process_info_for_each_image_fn fn = pt_resolve_dyld_process_info_for_each_image();
    if (fn == NULL || info == NULL || callback == NULL) {
        return;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        fn(info, ^(uint64_t machHeaderAddress, const uuid_t uuid, const char *path) {
            if ((path != NULL && pt_should_hide_dyld_image(path)) ||
                (machHeaderAddress != 0 && pt_is_hidden_dyld_image_header((const struct mach_header *)(uintptr_t)machHeaderAddress))) {
                return;
            }
            const char *cleanPath = (path != NULL) ? pt_sanitize_image_path_for_app(path) : NULL;
            callback(machHeaderAddress, uuid, cleanPath);
        });
        return;
    }
    fn(info, callback);
}

static uint32_t pt_dyld_process_info_get_platform(pt_dyld_process_info_t info) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return PLATFORM_IOS;
    }
    pt_dyld_process_info_get_platform_fn fn = pt_resolve_dyld_process_info_get_platform();
    return (fn != NULL) ? fn(info) : PLATFORM_IOS;
}

static void pt_dyld_process_info_get_cache(pt_dyld_process_info_t info, void *cacheInfo) {
    pt_dyld_process_info_get_cache_fn fn = pt_resolve_dyld_process_info_get_cache();
    if (fn == NULL) {
        return;
    }
    fn(info, cacheInfo);
}

static void pt_dyld_process_info_get_state(pt_dyld_process_info_t info, void *stateInfo) {
    pt_dyld_process_info_get_state_fn fn = pt_resolve_dyld_process_info_get_state();
    if (fn == NULL) {
        return;
    }
    fn(info, stateInfo);
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
    if (path == NULL || path[0] == '\0' || pt_is_app_embedded_bundle_path(path)) {
        return NO;
    }
    static const char *const kPost13_7Components[] = {
        "ExtensionKit.framework",
        "ExtensionFoundation.framework",
        "WidgetKit.framework",
        "TipKit.framework",
        "AppIntents.framework",
        "AppTrackingTransparency.framework",
        "UniformTypeIdentifiers.framework",
        "Observation.framework",
        "SwiftData.framework",
        "ActivityKit.framework",
        "GroupActivities.framework",
        "NearbyInteraction.framework",
        "Charts.framework",
        "OSLog.framework",
        "WeatherKit.framework",
        "MusicKit.framework",
        "RoomPlan.framework",
        "WorkoutKit.framework",
        "Translation.framework",
        "FamilyControls.framework",
        "ManagedSettings.framework",
        "DeviceActivity.framework",
        "Cinematic.framework",
        "CoreTransferable.framework",
        "Spatial.framework",
        "DockKit.framework",
        "FinanceKit.framework",
        "JournalingSuggestions.framework",
        "SensitiveContentAnalysis.framework",
        "LockedCameraCapture.framework",
        "MarketplaceKit.framework",
        "libswift_Concurrency.dylib",
        "libswift_StringProcessing.dylib",
    };
    const size_t n = sizeof(kPost13_7Components) / sizeof(kPost13_7Components[0]);
    for (size_t i = 0; i < n; i++) {
        if (pt_path_has_component(path, kPost13_7Components[i])) {
            return YES;
        }
    }
    return NO;
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

static void pt_rebuild_post13_range_cache(uint32_t cur_ic) {
    // Collect ranges outside s_post13_range_lock to avoid ABBA lock inversion with dyld.
    PTPost13AddrRange local_ranges[PT_POST13_MAX_RANGES];
    uint32_t local_count = 0;
    BOOL local_overflow = NO;
    uintptr_t local_dsc_start = 0;
    uintptr_t local_dsc_end = 0;
    if (_dyld_get_shared_cache_range != NULL) {
        size_t dsc_len = 0;
        const void *dsc_base = _dyld_get_shared_cache_range(&dsc_len);
        if (dsc_base != NULL && dsc_len > 0 && (uintptr_t)dsc_base <= UINTPTR_MAX - dsc_len) {
            local_dsc_start = (uintptr_t)dsc_base;
            local_dsc_end = local_dsc_start + (uintptr_t)dsc_len;
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
                        if (local_count < PT_POST13_MAX_RANGES) {
                            local_ranges[local_count++] = (PTPost13AddrRange){
                                .start = start,
                                .end = start + (uintptr_t)seg->vmsize
                            };
                        } else {
                            local_overflow = YES;
                        }
                    }
                }
            }
            p += lc->cmdsize;
        }
    }
    os_unfair_lock_lock(&s_post13_range_lock);
    if (local_count > 0) {
        memcpy(s_post13_ranges, local_ranges, (size_t)local_count * sizeof(PTPost13AddrRange));
    }
    s_post13_range_count = local_count;
    s_post13_range_overflow = local_overflow;
    s_post13_dsc_start = local_dsc_start;
    s_post13_dsc_end = local_dsc_end;
    atomic_store_explicit(&s_post13_cached_image_count, cur_ic, memory_order_release);
    os_unfair_lock_unlock(&s_post13_range_lock);
}

__attribute__((visibility("hidden"))) BOOL pt_is_hidden_post13_7_class(Class cls) {
    if (cls == Nil || !pt_is_compat13_7_active()) {
        return NO;
    }
    uint32_t cur_ic = _dyld_image_count();
    if (cur_ic != atomic_load_explicit(&s_post13_cached_image_count, memory_order_acquire)) {
        pt_rebuild_post13_range_cache(cur_ic);
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

#ifndef PT_HIDDEN_IMG_MAX_RANGES
#define PT_HIDDEN_IMG_MAX_RANGES 512U
#endif

static os_unfair_lock s_hidden_img_range_lock = OS_UNFAIR_LOCK_INIT;
static PTPost13AddrRange s_hidden_img_ranges[PT_HIDDEN_IMG_MAX_RANGES];
static uint32_t s_hidden_img_range_count = 0;
static BOOL s_hidden_img_range_overflow = NO;
static uintptr_t s_hidden_img_dsc_start = 0;
static uintptr_t s_hidden_img_dsc_end = 0;
static _Atomic uint32_t s_hidden_img_cached_image_count = 0;
static _Atomic uint64_t s_hidden_img_cached_reg_gen = UINT64_MAX;

static void pt_rebuild_hidden_img_range_cache(uint32_t cur_ic, uint64_t cur_reg_gen) {
    // Collect ranges outside s_hidden_img_range_lock to avoid ABBA lock inversion with dyld/PTRegistration.
    PTPost13AddrRange *local_ranges =
        (PTPost13AddrRange *)malloc(PT_HIDDEN_IMG_MAX_RANGES * sizeof(PTPost13AddrRange));
    uint32_t local_count = 0;
    BOOL local_overflow = (local_ranges == NULL);
    uintptr_t local_dsc_start = 0;
    uintptr_t local_dsc_end = 0;
    if (_dyld_get_shared_cache_range != NULL) {
        size_t dsc_len = 0;
        const void *dsc_base = _dyld_get_shared_cache_range(&dsc_len);
        if (dsc_base != NULL && dsc_len > 0 && (uintptr_t)dsc_base <= UINTPTR_MAX - dsc_len) {
            local_dsc_start = (uintptr_t)dsc_base;
            local_dsc_end = local_dsc_start + (uintptr_t)dsc_len;
        }
    }
    if (local_ranges != NULL) {
        for (uint32_t i = 0; i < cur_ic; i++) {
            const char *name = _dyld_get_image_name(i);
            const struct mach_header *raw_mh = _dyld_get_image_header(i);
            if ((name == NULL || !pt_is_hidden_dyld_image_name(name)) &&
                (raw_mh == NULL || !pt_is_hidden_dyld_image_header(raw_mh))) {
                continue;
            }
            const struct mach_header_64 *mh = (const struct mach_header_64 *)raw_mh;
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
                            if (local_count < PT_HIDDEN_IMG_MAX_RANGES) {
                                local_ranges[local_count++] = (PTPost13AddrRange){
                                    .start = start,
                                    .end = start + (uintptr_t)seg->vmsize
                                };
                            } else {
                                local_overflow = YES;
                            }
                        }
                    }
                }
                p += lc->cmdsize;
            }
        }
    }
    os_unfair_lock_lock(&s_hidden_img_range_lock);
    if (local_ranges != NULL && local_count > 0) {
        memcpy(s_hidden_img_ranges, local_ranges, (size_t)local_count * sizeof(PTPost13AddrRange));
    }
    s_hidden_img_range_count = local_count;
    s_hidden_img_range_overflow = local_overflow;
    s_hidden_img_dsc_start = local_dsc_start;
    s_hidden_img_dsc_end = local_dsc_end;
    atomic_store_explicit(&s_hidden_img_cached_image_count, cur_ic, memory_order_release);
    atomic_store_explicit(&s_hidden_img_cached_reg_gen, cur_reg_gen, memory_order_release);
    os_unfair_lock_unlock(&s_hidden_img_range_lock);
    free(local_ranges);
}

__attribute__((visibility("hidden"))) BOOL pt_is_class_in_hidden_image(Class cls) {
    if (cls == Nil) {
        return NO;
    }
    uint32_t cur_ic = _dyld_image_count();
    uint64_t cur_reg_gen = pt_hidden_registry_generation();
    if (cur_ic != atomic_load_explicit(&s_hidden_img_cached_image_count, memory_order_acquire) ||
        cur_reg_gen != atomic_load_explicit(&s_hidden_img_cached_reg_gen, memory_order_acquire)) {
        pt_rebuild_hidden_img_range_cache(cur_ic, cur_reg_gen);
    }
    uintptr_t addr = (uintptr_t)cls;
    os_unfair_lock_lock(&s_hidden_img_range_lock);
    for (uint32_t r = 0; r < s_hidden_img_range_count; r++) {
        if (addr >= s_hidden_img_ranges[r].start && addr < s_hidden_img_ranges[r].end) {
            os_unfair_lock_unlock(&s_hidden_img_range_lock);
            return YES;
        }
    }
    BOOL in_dsc = (!s_hidden_img_range_overflow &&
                   s_hidden_img_dsc_end > s_hidden_img_dsc_start &&
                   addr >= s_hidden_img_dsc_start &&
                   addr < s_hidden_img_dsc_end);
    os_unfair_lock_unlock(&s_hidden_img_range_lock);
    if (in_dsc) {
        return NO;
    }
    const char *img = class_getImageName(cls);
    if (img == NULL) {
        return NO;
    }
    pt_ensure_bundle_path_map();
    if (s_real_app_bundle_len > 0 &&
        pt_match_prefix_modulo_private(img, s_real_app_bundle_dir, s_real_app_bundle_len) != NULL) {
        return NO;
    }
    return pt_is_hidden_dyld_image_name(img);
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

static void *pt_dlsym_resolve_shared_cache_real_path(void) {
    return (pt_resolve_dyld_shared_cache_real_path() != NULL) ? (void *)&pt_dyld_shared_cache_real_path : NULL;
}

static void *pt_dlsym_resolve_shared_cache_overridden(void) {
    return (pt_resolve_dyld_shared_cache_some_image_overridden() != NULL)
               ? (void *)&pt_dyld_shared_cache_some_image_overridden
               : NULL;
}

static void *pt_dlsym_resolve_prog_image_header(void) {
    return (pt_resolve_dyld_get_prog_image_header() != NULL) ? (void *)&pt_dyld_get_prog_image_header : NULL;
}

static void *pt_dlsym_resolve_find_unwind_sections(void) {
    return (pt_resolve_dyld_find_unwind_sections() != NULL) ? (void *)&pt_dyld_find_unwind_sections : NULL;
}

static void *pt_dlsym_resolve_proc_info_create_plain(void) {
    return (pt_dyld_process_info_create_sym()->plain_fn != NULL) ? (void *)&pt_dyld_process_info_create : NULL;
}

static void *pt_dlsym_resolve_proc_info_create_underscored(void) {
    return (pt_dyld_process_info_create_sym()->underscored_fn != NULL) ? (void *)&pt_dyld_process_info_create : NULL;
}

static void *pt_dlsym_resolve_proc_info_for_each_plain(void) {
    return (pt_dyld_process_info_for_each_image_sym()->plain_fn != NULL)
               ? (void *)&pt_dyld_process_info_for_each_image
               : NULL;
}

static void *pt_dlsym_resolve_proc_info_for_each_underscored(void) {
    return (pt_dyld_process_info_for_each_image_sym()->underscored_fn != NULL)
               ? (void *)&pt_dyld_process_info_for_each_image
               : NULL;
}

static void *pt_dlsym_resolve_proc_info_platform_plain(void) {
    return (pt_dyld_process_info_get_platform_sym()->plain_fn != NULL)
               ? (void *)&pt_dyld_process_info_get_platform
               : NULL;
}

static void *pt_dlsym_resolve_proc_info_platform_underscored(void) {
    return (pt_dyld_process_info_get_platform_sym()->underscored_fn != NULL)
               ? (void *)&pt_dyld_process_info_get_platform
               : NULL;
}

static void *pt_dlsym_resolve_proc_info_cache_plain(void) {
    return (pt_dyld_process_info_get_cache_sym()->plain_fn != NULL)
               ? (void *)&pt_dyld_process_info_get_cache
               : NULL;
}

static void *pt_dlsym_resolve_proc_info_cache_underscored(void) {
    return (pt_dyld_process_info_get_cache_sym()->underscored_fn != NULL)
               ? (void *)&pt_dyld_process_info_get_cache
               : NULL;
}

static void *pt_dlsym_resolve_proc_info_state_plain(void) {
    return (pt_dyld_process_info_get_state_sym()->plain_fn != NULL)
               ? (void *)&pt_dyld_process_info_get_state
               : NULL;
}

static void *pt_dlsym_resolve_proc_info_state_underscored(void) {
    return (pt_dyld_process_info_get_state_sym()->underscored_fn != NULL)
               ? (void *)&pt_dyld_process_info_get_state
               : NULL;
}

PT_DLSYM_DYNAMIC("_dyld_shared_cache_real_path", pt_dlsym_resolve_shared_cache_real_path)
PT_DLSYM_DYNAMIC("dyld_shared_cache_some_image_overridden", pt_dlsym_resolve_shared_cache_overridden)
PT_DLSYM_DYNAMIC("_dyld_get_prog_image_header", pt_dlsym_resolve_prog_image_header)
PT_DLSYM_DYNAMIC("_dyld_find_unwind_sections", pt_dlsym_resolve_find_unwind_sections)
PT_DLSYM_DYNAMIC("dyld_process_info_create", pt_dlsym_resolve_proc_info_create_plain)
PT_DLSYM_DYNAMIC("_dyld_process_info_create", pt_dlsym_resolve_proc_info_create_underscored)
PT_DLSYM_DYNAMIC("dyld_process_info_for_each_image", pt_dlsym_resolve_proc_info_for_each_plain)
PT_DLSYM_DYNAMIC("_dyld_process_info_for_each_image", pt_dlsym_resolve_proc_info_for_each_underscored)
PT_DLSYM_DYNAMIC("dyld_process_info_get_platform", pt_dlsym_resolve_proc_info_platform_plain)
PT_DLSYM_DYNAMIC("_dyld_process_info_get_platform", pt_dlsym_resolve_proc_info_platform_underscored)
PT_DLSYM_DYNAMIC("dyld_process_info_get_cache", pt_dlsym_resolve_proc_info_cache_plain)
PT_DLSYM_DYNAMIC("_dyld_process_info_get_cache", pt_dlsym_resolve_proc_info_cache_underscored)
PT_DLSYM_DYNAMIC("dyld_process_info_get_state", pt_dlsym_resolve_proc_info_state_plain)
PT_DLSYM_DYNAMIC("_dyld_process_info_get_state", pt_dlsym_resolve_proc_info_state_underscored)

PT_INTERPOSE_WEAK(pt_dyld_get_active_platform, dyld_get_active_platform)
PT_INTERPOSE_WEAK(pt_dyld_get_base_platform, dyld_get_base_platform)
PT_INTERPOSE_WEAK_NAMED(pt_dyld_get_image_versions, pt_orig_dyld_get_image_versions, "dyld_get_image_versions")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_sdk_at_least, pt_orig_dyld_sdk_at_least, "dyld_sdk_at_least")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_minos_at_least, pt_orig_dyld_minos_at_least, "dyld_minos_at_least")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_get_sdk_version, pt_orig_dyld_get_sdk_version, "dyld_get_sdk_version")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_get_min_os_version, pt_orig_dyld_get_min_os_version, "dyld_get_min_os_version")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_get_program_sdk_version, pt_orig_dyld_get_program_sdk_version, "dyld_get_program_sdk_version")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_get_program_min_os_version, pt_orig_dyld_get_program_min_os_version, "dyld_get_program_min_os_version")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_program_sdk_at_least, pt_orig_dyld_program_sdk_at_least, "dyld_program_sdk_at_least")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_program_minos_at_least, pt_orig_dyld_program_minos_at_least, "dyld_program_minos_at_least")
PT_INTERPOSE_WEAK(pt_dyld_shared_cache_file_path, dyld_shared_cache_file_path)
PT_INTERPOSE_NAMED(pt_dyld_shared_cache_contains_path, pt_orig_dyld_shared_cache_contains_path, "_dyld_shared_cache_contains_path")
