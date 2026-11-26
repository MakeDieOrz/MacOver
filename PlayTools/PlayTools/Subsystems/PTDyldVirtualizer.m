//
//  PTDyldVirtualizer.m
//  PlayTools
//

#import "PTDyldInternal.h"
#import "PTArm64StubMath.h"
#import "PTSystemSpooferInternal.h"
#import "PTFSInternal.h"

#import "PTInterposeRegistry.h"

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
                PT_HAS_PREFIX_LIT(name, "_NSApplication") ||
                (pt_is_compat13_7_active() && strcmp(name, "_NSSwiftProcessInfo") == 0)) {
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

#define PT_REG_ORIG_CACHE_CAP 128U

static os_unfair_lock s_reg_orig_cache_lock = OS_UNFAIR_LOCK_INIT;
static struct {
    const void *stripped_target;
    const void *orig_ptr;
} s_reg_orig_cache[PT_REG_ORIG_CACHE_CAP];
static uint32_t s_reg_orig_cache_count = 0;

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
    os_unfair_lock_lock(&s_reg_orig_cache_lock);
    for (uint32_t i = 0; i < s_reg_orig_cache_count; i++) {
        if (s_reg_orig_cache[i].stripped_target == stripped) {
            const void *cached = s_reg_orig_cache[i].orig_ptr;
            os_unfair_lock_unlock(&s_reg_orig_cache_lock);
            return (cached != NULL) ? cached : addr;
        }
    }
    os_unfair_lock_unlock(&s_reg_orig_cache_lock);

    const char *reg_sym = pt_interpose_registry_symbol_for_target(stripped);
    if (reg_sym != NULL) {
        void *resolved = dlsym(RTLD_NEXT, reg_sym);
        os_unfair_lock_lock(&s_reg_orig_cache_lock);
        if (s_reg_orig_cache_count < PT_REG_ORIG_CACHE_CAP) {
            BOOL dup = NO;
            for (uint32_t i = 0; i < s_reg_orig_cache_count; i++) {
                if (s_reg_orig_cache[i].stripped_target == stripped) {
                    dup = YES;
                    break;
                }
            }
            if (!dup) {
                s_reg_orig_cache[s_reg_orig_cache_count].stripped_target = stripped;
                s_reg_orig_cache[s_reg_orig_cache_count].orig_ptr = resolved;
                s_reg_orig_cache_count++;
            }
        }
        os_unfair_lock_unlock(&s_reg_orig_cache_lock);
        if (resolved != NULL) {
            return resolved;
        }
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

extern bool pt_orig_dyld_has_inserted_or_interposing_libraries(void)
    __asm__("_dyld_has_inserted_or_interposing_libraries") __attribute__((weak_import));

static bool pt_dyld_has_inserted_or_interposing_libraries(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return false;
    }
    return (pt_orig_dyld_has_inserted_or_interposing_libraries != NULL)
        ? pt_orig_dyld_has_inserted_or_interposing_libraries()
        : false;
}

extern void pt_orig_dyld_get_image_versions(
    const struct mach_header *mh,
    void (^callback)(uint32_t platform, uint32_t sdk_version, uint32_t min_version))
    __asm__("_dyld_get_image_versions") __attribute__((weak_import));
extern bool pt_orig_dyld_sdk_at_least(const struct mach_header *mh, pt_dyld_build_version_t version)
    __asm__("_dyld_sdk_at_least") __attribute__((weak_import));
extern bool pt_orig_dyld_minos_at_least(const struct mach_header *mh, pt_dyld_build_version_t version)
    __asm__("_dyld_minos_at_least") __attribute__((weak_import));
extern uint32_t pt_orig_dyld_get_sdk_version(const struct mach_header *mh)
    __asm__("_dyld_get_sdk_version") __attribute__((weak_import));
extern uint32_t pt_orig_dyld_get_min_os_version(const struct mach_header *mh)
    __asm__("_dyld_get_min_os_version") __attribute__((weak_import));
extern uint32_t pt_orig_dyld_get_program_sdk_version(void)
    __asm__("_dyld_get_program_sdk_version") __attribute__((weak_import));
extern uint32_t pt_orig_dyld_get_program_min_os_version(void)
    __asm__("_dyld_get_program_min_os_version") __attribute__((weak_import));
extern bool pt_orig_dyld_program_sdk_at_least(pt_dyld_build_version_t version)
    __asm__("_dyld_program_sdk_at_least") __attribute__((weak_import));
extern bool pt_orig_dyld_program_minos_at_least(pt_dyld_build_version_t version)
    __asm__("_dyld_program_minos_at_least") __attribute__((weak_import));

static BOOL pt_extract_raw_versions_from_mh64(const struct mach_header_64 *mh64,
                                              uint32_t *out_minos,
                                              uint32_t *out_sdk) {
    if (mh64 == NULL || !pt_is_valid_user_pointer(mh64) ||
        mh64->magic != MH_MAGIC_64 ||
        mh64->sizeofcmds == 0 || mh64->sizeofcmds > (1U << 20)) {
        return NO;
    }
    const uint8_t *base = (const uint8_t *)mh64;
    size_t total = sizeof(struct mach_header_64) + (size_t)mh64->sizeofcmds;
    size_t off = sizeof(struct mach_header_64);

    int best_prio = 0; // 3=IOS, 2=MACCATALYST, 1=other LC_BUILD_VERSION
    uint32_t best_minos = 0, best_sdk = 0;
    uint32_t vmin_minos = 0, vmin_sdk = 0;
    BOOL has_vmin = NO;

    for (uint32_t i = 0; i < mh64->ncmds && off + sizeof(struct load_command) <= total; i++) {
        const struct load_command *lc = (const struct load_command *)(base + off);
        if (lc->cmdsize < sizeof(struct load_command) || off + lc->cmdsize > total) {
            break;
        }
        if (lc->cmd == LC_BUILD_VERSION && lc->cmdsize >= sizeof(struct build_version_command)) {
            const struct build_version_command *bv = (const struct build_version_command *)lc;
            int prio = (bv->platform == PLATFORM_IOS) ? 3 : ((bv->platform == PLATFORM_MACCATALYST) ? 2 : 1);
            if (prio > best_prio) {
                best_prio = prio;
                best_minos = bv->minos;
                best_sdk = bv->sdk;
            }
        } else if ((lc->cmd == LC_VERSION_MIN_IPHONEOS || lc->cmd == LC_VERSION_MIN_MACOSX) &&
                   lc->cmdsize >= sizeof(struct version_min_command) && !has_vmin) {
            const struct version_min_command *vmc = (const struct version_min_command *)lc;
            vmin_minos = vmc->version;
            vmin_sdk = vmc->sdk;
            has_vmin = YES;
        }
        off += lc->cmdsize;
    }

    if (best_prio > 0) {
        if (out_minos != NULL) *out_minos = best_minos;
        if (out_sdk != NULL) *out_sdk = best_sdk;
        return YES;
    }
    if (has_vmin) {
        if (out_minos != NULL) *out_minos = vmin_minos;
        if (out_sdk != NULL) *out_sdk = vmin_sdk;
        return YES;
    }
    return NO;
}

static BOOL pt_extract_spoofed_ios_image_versions(const struct mach_header *mh,
                                                  uint32_t *out_minos,
                                                  uint32_t *out_sdk) {
    const struct mach_header *real_mh = pt_uncloak_shadow_mach_header(mh);
    if (real_mh == NULL) {
        return NO;
    }
    uint32_t minos = 0, sdk = 0;
    BOOL extracted = NO;
    if (real_mh == pt_get_main_executable_header()) {
        size_t bkp_len = 0;
        const uint8_t *bkp = pt_get_cached_backup_main_mach_header(&bkp_len);
        if (bkp != NULL && bkp_len >= sizeof(struct mach_header_64)) {
            extracted = pt_extract_raw_versions_from_mh64((const struct mach_header_64 *)bkp, &minos, &sdk);
        }
    }
    if (!extracted) {
        extracted = pt_extract_raw_versions_from_mh64((const struct mach_header_64 *)real_mh, &minos, &sdk);
    }
    if (!extracted) {
        return NO;
    }
    uint32_t clamp = pt_get_compat_version_clamp();
    if (clamp != 0) {
        if (minos > clamp) minos = clamp;
        if (sdk > clamp) sdk = clamp;
    }
    if (out_minos != NULL) *out_minos = minos;
    if (out_sdk != NULL) *out_sdk = sdk;
    return YES;
}

static void pt_dyld_get_image_versions(
    const struct mach_header *mh,
    void (^callback)(uint32_t platform, uint32_t sdk_version, uint32_t min_version)) {
    if (mh == NULL || callback == NULL) {
        return;
    }
    const void *caller = __builtin_return_address(0);
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
        uint32_t minos = 0, sdk = 0;
        if (pt_extract_spoofed_ios_image_versions(mh, &minos, &sdk)) {
            callback(PLATFORM_IOS, sdk, minos);
            return;
        }
        if (pt_orig_dyld_get_image_versions != NULL) {
            const struct mach_header *real_mh = pt_uncloak_shadow_mach_header(mh);
            uint32_t clamp = pt_get_compat_version_clamp();
            __block BOOL invoked = NO;
            pt_orig_dyld_get_image_versions(real_mh, ^(uint32_t platform, uint32_t sdk_version, uint32_t min_version) {
                if (invoked) {
                    return;
                }
                invoked = YES;
                (void)platform;
                if (clamp != 0) {
                    if (sdk_version > clamp) sdk_version = clamp;
                    if (min_version > clamp) min_version = clamp;
                }
                callback(PLATFORM_IOS, sdk_version, min_version);
            });
        }
        return;
    }
    if (pt_orig_dyld_get_image_versions != NULL) {
        pt_orig_dyld_get_image_versions(pt_uncloak_shadow_mach_header(mh), callback);
    }
}

static inline BOOL pt_dyld_version_query_blocked_for_app(pt_dyld_build_version_t version) {
    if (version.platform == 1U || version.platform == PLATFORM_MACCATALYST) {
        return YES;
    }
    uint32_t clamp = pt_get_compat_version_clamp();
    if (clamp != 0 && version.platform == PLATFORM_IOS && version.version > clamp) {
        return YES;
    }
    return NO;
}

static bool pt_dyld_sdk_at_least(const struct mach_header *mh, pt_dyld_build_version_t version) {
    if (mh == NULL) {
        return false;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_dyld_version_query_blocked_for_app(version)) {
            return false;
        }
        uint32_t minos = 0, sdk = 0;
        if (pt_extract_spoofed_ios_image_versions(mh, &minos, &sdk) && version.platform == PLATFORM_IOS) {
            return (sdk >= version.version);
        }
        return (pt_orig_dyld_sdk_at_least != NULL)
            ? pt_orig_dyld_sdk_at_least(pt_maybe_shadow_mach_header(mh), version)
            : false;
    }
    return (pt_orig_dyld_sdk_at_least != NULL)
        ? pt_orig_dyld_sdk_at_least(pt_uncloak_shadow_mach_header(mh), version)
        : false;
}

static bool pt_dyld_minos_at_least(const struct mach_header *mh, pt_dyld_build_version_t version) {
    if (mh == NULL) {
        return false;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_dyld_version_query_blocked_for_app(version)) {
            return false;
        }
        uint32_t minos = 0, sdk = 0;
        if (pt_extract_spoofed_ios_image_versions(mh, &minos, &sdk) && version.platform == PLATFORM_IOS) {
            return (minos >= version.version);
        }
        return (pt_orig_dyld_minos_at_least != NULL)
            ? pt_orig_dyld_minos_at_least(pt_maybe_shadow_mach_header(mh), version)
            : false;
    }
    return (pt_orig_dyld_minos_at_least != NULL)
        ? pt_orig_dyld_minos_at_least(pt_uncloak_shadow_mach_header(mh), version)
        : false;
}

static uint32_t pt_dyld_get_sdk_version(const struct mach_header *mh) {
    if (mh == NULL) {
        return 0;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        uint32_t minos = 0, sdk = 0;
        if (pt_extract_spoofed_ios_image_versions(mh, &minos, &sdk)) {
            return sdk;
        }
        uint32_t v = (pt_orig_dyld_get_sdk_version != NULL)
            ? pt_orig_dyld_get_sdk_version(pt_maybe_shadow_mach_header(mh))
            : 0;
        uint32_t clamp = pt_get_compat_version_clamp();
        if (clamp != 0 && v > clamp) {
            return clamp;
        }
        return v;
    }
    return (pt_orig_dyld_get_sdk_version != NULL)
        ? pt_orig_dyld_get_sdk_version(pt_uncloak_shadow_mach_header(mh))
        : 0;
}

static uint32_t pt_dyld_get_min_os_version(const struct mach_header *mh) {
    if (mh == NULL) {
        return 0;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        uint32_t minos = 0, sdk = 0;
        if (pt_extract_spoofed_ios_image_versions(mh, &minos, &sdk)) {
            return minos;
        }
        uint32_t v = (pt_orig_dyld_get_min_os_version != NULL)
            ? pt_orig_dyld_get_min_os_version(pt_maybe_shadow_mach_header(mh))
            : 0;
        uint32_t clamp = pt_get_compat_version_clamp();
        if (clamp != 0 && v > clamp) {
            return clamp;
        }
        return v;
    }
    return (pt_orig_dyld_get_min_os_version != NULL)
        ? pt_orig_dyld_get_min_os_version(pt_uncloak_shadow_mach_header(mh))
        : 0;
}

static uint32_t pt_dyld_get_program_sdk_version_for_app(void) {
    const struct mach_header *main_mh = pt_get_main_executable_header();
    uint32_t minos = 0, sdk = 0;
    if (main_mh != NULL && pt_extract_spoofed_ios_image_versions(main_mh, &minos, &sdk)) {
        return sdk;
    }
    uint32_t v = (pt_orig_dyld_get_program_sdk_version != NULL) ? pt_orig_dyld_get_program_sdk_version() : 0;
    uint32_t clamp = pt_get_compat_version_clamp();
    return (clamp != 0 && v > clamp) ? clamp : v;
}

static uint32_t pt_dyld_get_program_min_os_version_for_app(void) {
    const struct mach_header *main_mh = pt_get_main_executable_header();
    uint32_t minos = 0, sdk = 0;
    if (main_mh != NULL && pt_extract_spoofed_ios_image_versions(main_mh, &minos, &sdk)) {
        return minos;
    }
    uint32_t v = (pt_orig_dyld_get_program_min_os_version != NULL) ? pt_orig_dyld_get_program_min_os_version() : 0;
    uint32_t clamp = pt_get_compat_version_clamp();
    return (clamp != 0 && v > clamp) ? clamp : v;
}

static uint32_t pt_dyld_get_program_sdk_version(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return pt_dyld_get_program_sdk_version_for_app();
    }
    return (pt_orig_dyld_get_program_sdk_version != NULL) ? pt_orig_dyld_get_program_sdk_version() : 0;
}

static uint32_t pt_dyld_get_program_min_os_version(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return pt_dyld_get_program_min_os_version_for_app();
    }
    return (pt_orig_dyld_get_program_min_os_version != NULL) ? pt_orig_dyld_get_program_min_os_version() : 0;
}

static bool pt_dyld_program_sdk_at_least(pt_dyld_build_version_t version) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_dyld_version_query_blocked_for_app(version)) {
            return false;
        }
        if (version.platform == PLATFORM_IOS) {
            return (pt_dyld_get_program_sdk_version_for_app() >= version.version);
        }
        const struct mach_header *main_mh = pt_get_main_executable_header();
        if (main_mh != NULL && pt_orig_dyld_sdk_at_least != NULL) {
            return pt_orig_dyld_sdk_at_least(pt_maybe_shadow_mach_header(main_mh), version);
        }
    }
    return (pt_orig_dyld_program_sdk_at_least != NULL) ? pt_orig_dyld_program_sdk_at_least(version) : false;
}

static bool pt_dyld_program_minos_at_least(pt_dyld_build_version_t version) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_dyld_version_query_blocked_for_app(version)) {
            return false;
        }
        if (version.platform == PLATFORM_IOS) {
            return (pt_dyld_get_program_min_os_version_for_app() >= version.version);
        }
        const struct mach_header *main_mh = pt_get_main_executable_header();
        if (main_mh != NULL && pt_orig_dyld_minos_at_least != NULL) {
            return pt_orig_dyld_minos_at_least(pt_maybe_shadow_mach_header(main_mh), version);
        }
    }
    return (pt_orig_dyld_program_minos_at_least != NULL) ? pt_orig_dyld_program_minos_at_least(version) : false;
}

extern uint64_t pt_orig_dyld_get_program_sdk_version_token(void)
    __asm__("_dyld_get_program_sdk_version_token") __attribute__((weak_import));
extern uint64_t pt_orig_dyld_get_program_minos_version_token(void)
    __asm__("_dyld_get_program_minos_version_token") __attribute__((weak_import));
extern uint32_t pt_orig_dyld_version_token_get_platform(uint64_t token)
    __asm__("_dyld_version_token_get_platform") __attribute__((weak_import));
extern bool pt_orig_dyld_version_token_at_least(uint64_t token, pt_dyld_build_version_t version)
    __asm__("_dyld_version_token_at_least") __attribute__((weak_import));

static uint64_t pt_dyld_get_program_sdk_version_token(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        uint32_t sdk = pt_dyld_get_program_sdk_version_for_app();
        return ((uint64_t)sdk << 32) | (uint64_t)PLATFORM_IOS;
    }
    return (pt_orig_dyld_get_program_sdk_version_token != NULL) ? pt_orig_dyld_get_program_sdk_version_token() : 0ULL;
}

static uint64_t pt_dyld_get_program_minos_version_token(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        uint32_t minos = pt_dyld_get_program_min_os_version_for_app();
        return ((uint64_t)minos << 32) | (uint64_t)PLATFORM_IOS;
    }
    return (pt_orig_dyld_get_program_minos_version_token != NULL) ? pt_orig_dyld_get_program_minos_version_token() : 0ULL;
}

static uint32_t pt_dyld_version_token_get_platform(uint64_t token) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        uint32_t plat = (uint32_t)(token & 0xFFFFFFFFULL);
        if (plat == 1U || plat == PLATFORM_MACCATALYST || plat == PLATFORM_IOS) {
            return PLATFORM_IOS;
        }
        return plat;
    }
    return (pt_orig_dyld_version_token_get_platform != NULL)
        ? pt_orig_dyld_version_token_get_platform(token)
        : (uint32_t)(token & 0xFFFFFFFFULL);
}

static bool pt_dyld_version_token_at_least(uint64_t token, pt_dyld_build_version_t version) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_dyld_version_query_blocked_for_app(version)) {
            return false;
        }
        uint32_t tok_plat = (uint32_t)(token & 0xFFFFFFFFULL);
        uint32_t tok_ver = (uint32_t)(token >> 32);
        if (version.platform == PLATFORM_IOS &&
            (tok_plat == 1U || tok_plat == PLATFORM_MACCATALYST || tok_plat == PLATFORM_IOS)) {
            uint32_t clamp = pt_get_compat_version_clamp();
            if (clamp != 0 && tok_ver > clamp) {
                tok_ver = clamp;
            }
            return (tok_ver >= version.version);
        }
    }
    return (pt_orig_dyld_version_token_at_least != NULL)
        ? pt_orig_dyld_version_token_at_least(token, version)
        : false;
}

typedef const struct mach_header *(*pt_dyld_get_prog_image_header_fn)(void);
extern const struct mach_header *pt_orig_sym_dyld_get_prog_image_header(void) __asm__("__dyld_get_prog_image_header") __attribute__((weak_import));

static const struct mach_header *pt_dyld_get_prog_image_header(void) {
    if (&pt_orig_sym_dyld_get_prog_image_header == NULL) {
        return _dyld_get_image_header(0);
    }
    return pt_orig_sym_dyld_get_prog_image_header();
}

extern const char *pt_orig_sym_dyld_shared_cache_real_path(const char *path) __asm__("__dyld_shared_cache_real_path") __attribute__((weak_import));

static const char *pt_dyld_shared_cache_real_path(const char *path) {
    if (&pt_orig_sym_dyld_shared_cache_real_path == NULL) {
        return NULL;
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
            strncmp(norm, "/System/iOSSupport/", 19) == 0 ||
            strstr(norm, ".framework/Versions/") != NULL ||
            pt_should_hide_dyld_image(norm) ||
            pt_is_hidden_path(norm, caller)) {
            return NULL;
        }
        const char *res = pt_orig_sym_dyld_shared_cache_real_path(norm);
        if (res == NULL && (strncmp(norm, "/System/Library/", 16) == 0 || strncmp(norm, "/usr/lib/", 9) == 0)) {
            char ios_buf[PATH_MAX];
            int n = snprintf(ios_buf, sizeof(ios_buf), "/System/iOSSupport%s", norm);
            if (n > 0 && (size_t)n < sizeof(ios_buf)) {
                res = pt_orig_sym_dyld_shared_cache_real_path(ios_buf);
            }
            if (res == NULL) {
                const char *slash = strrchr(norm, '/');
                if (slash != NULL && slash > norm && strstr(norm, ".framework/") != NULL &&
                    strstr(norm, "/Versions/") == NULL) {
                    size_t dir_len = (size_t)(slash - norm);
                    n = snprintf(ios_buf, sizeof(ios_buf),
                                 "/System/iOSSupport%.*s/Versions/A%s",
                                 (int)dir_len, norm, slash);
                    if (n > 0 && (size_t)n < sizeof(ios_buf)) {
                        res = pt_orig_sym_dyld_shared_cache_real_path(ios_buf);
                    }
                }
            }
        }
        if (res != NULL) {
            if (pt_should_hide_dyld_image(res)) {
                return NULL;
            }
            return pt_sanitize_image_path_for_app(res);
        }
        return NULL;
    }
    return pt_orig_sym_dyld_shared_cache_real_path(path);
}

extern bool pt_orig_sym_dyld_shared_cache_some_image_overridden(void) __asm__("_dyld_shared_cache_some_image_overridden") __attribute__((weak_import));

static bool pt_dyld_shared_cache_some_image_overridden(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return false;
    }
    return (&pt_orig_sym_dyld_shared_cache_some_image_overridden != NULL) ? pt_orig_sym_dyld_shared_cache_some_image_overridden() : false;
}

extern bool pt_orig_sym_dyld_find_unwind_sections(void *addr, void *info) __asm__("__dyld_find_unwind_sections") __attribute__((weak_import));

static bool pt_dyld_find_unwind_sections(void *addr, void *info) {
    if (&pt_orig_sym_dyld_find_unwind_sections == NULL) {
        return false;
    }
    if (!pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return pt_orig_sym_dyld_find_unwind_sections(addr, info);
    }
    addr = (void *)pt_resolve_interposed_target(addr);
    const char *path = dyld_image_path_containing_address(addr);
    if (path != NULL && pt_should_hide_dyld_image(path)) {
        return false;
    }
    return pt_orig_sym_dyld_find_unwind_sections(addr, info);
}

typedef const struct dyld_process_info_base *pt_dyld_process_info_t;
typedef pt_dyld_process_info_t (*pt_dyld_process_info_create_fn)(task_t task, uint64_t timestamp, kern_return_t *kernelError);
typedef void (*pt_dyld_process_info_for_each_image_fn)(pt_dyld_process_info_t info,
                                                       void (^callback)(uint64_t machHeaderAddress, const uuid_t uuid, const char *path));
typedef uint32_t (*pt_dyld_process_info_get_platform_fn)(pt_dyld_process_info_t info);
typedef void (*pt_dyld_process_info_get_cache_fn)(pt_dyld_process_info_t info, void *cacheInfo);
typedef void (*pt_dyld_process_info_get_state_fn)(pt_dyld_process_info_t info, void *stateInfo);

extern pt_dyld_process_info_t pt_orig_sym_dyld_process_info_create(task_t task, uint64_t timestamp, kern_return_t *kernelError) __asm__("__dyld_process_info_create") __attribute__((weak_import));
extern void pt_orig_sym_dyld_process_info_for_each_image(pt_dyld_process_info_t info,
                                                         void (^callback)(uint64_t machHeaderAddress, const uuid_t uuid, const char *path)) __asm__("__dyld_process_info_for_each_image") __attribute__((weak_import));
extern uint32_t pt_orig_sym_dyld_process_info_get_platform(pt_dyld_process_info_t info) __asm__("__dyld_process_info_get_platform") __attribute__((weak_import));
extern void pt_orig_sym_dyld_process_info_get_cache(pt_dyld_process_info_t info, void *cacheInfo) __asm__("__dyld_process_info_get_cache") __attribute__((weak_import));
extern void pt_orig_sym_dyld_process_info_get_state(pt_dyld_process_info_t info, void *stateInfo) __asm__("__dyld_process_info_get_state") __attribute__((weak_import));

typedef struct {
    void *plain_fn;
    void *underscored_fn;
} pt_dyld_proc_info_sym_t;

static void pt_resolve_dual_dyld_sym(pt_dyld_proc_info_sym_t *out,
                                     const char *plainName,
                                     void *origUnderscored) {
    out->plain_fn = dlsym(RTLD_NEXT, plainName);
    out->underscored_fn = origUnderscored;
}

static const pt_dyld_proc_info_sym_t *pt_dyld_process_info_create_sym(void) {
    static pt_dyld_proc_info_sym_t s_sym = { NULL, NULL };
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pt_resolve_dual_dyld_sym(&s_sym, "dyld_process_info_create", (void *)&pt_orig_sym_dyld_process_info_create);
    });
    return &s_sym;
}

static pt_dyld_process_info_create_fn pt_resolve_dyld_process_info_create(void) {
    if (&pt_orig_sym_dyld_process_info_create != NULL) {
        return pt_orig_sym_dyld_process_info_create;
    }
    return (pt_dyld_process_info_create_fn)pt_dyld_process_info_create_sym()->plain_fn;
}

static const pt_dyld_proc_info_sym_t *pt_dyld_process_info_for_each_image_sym(void) {
    static pt_dyld_proc_info_sym_t s_sym = { NULL, NULL };
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pt_resolve_dual_dyld_sym(&s_sym, "dyld_process_info_for_each_image", (void *)&pt_orig_sym_dyld_process_info_for_each_image);
    });
    return &s_sym;
}

static pt_dyld_process_info_for_each_image_fn pt_resolve_dyld_process_info_for_each_image(void) {
    if (&pt_orig_sym_dyld_process_info_for_each_image != NULL) {
        return pt_orig_sym_dyld_process_info_for_each_image;
    }
    return (pt_dyld_process_info_for_each_image_fn)pt_dyld_process_info_for_each_image_sym()->plain_fn;
}

static const pt_dyld_proc_info_sym_t *pt_dyld_process_info_get_platform_sym(void) {
    static pt_dyld_proc_info_sym_t s_sym = { NULL, NULL };
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pt_resolve_dual_dyld_sym(&s_sym, "dyld_process_info_get_platform", (void *)&pt_orig_sym_dyld_process_info_get_platform);
    });
    return &s_sym;
}

static pt_dyld_process_info_get_platform_fn pt_resolve_dyld_process_info_get_platform(void) {
    if (&pt_orig_sym_dyld_process_info_get_platform != NULL) {
        return pt_orig_sym_dyld_process_info_get_platform;
    }
    return (pt_dyld_process_info_get_platform_fn)pt_dyld_process_info_get_platform_sym()->plain_fn;
}

static const pt_dyld_proc_info_sym_t *pt_dyld_process_info_get_cache_sym(void) {
    static pt_dyld_proc_info_sym_t s_sym = { NULL, NULL };
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pt_resolve_dual_dyld_sym(&s_sym, "dyld_process_info_get_cache", (void *)&pt_orig_sym_dyld_process_info_get_cache);
    });
    return &s_sym;
}

static pt_dyld_process_info_get_cache_fn pt_resolve_dyld_process_info_get_cache(void) {
    if (&pt_orig_sym_dyld_process_info_get_cache != NULL) {
        return pt_orig_sym_dyld_process_info_get_cache;
    }
    return (pt_dyld_process_info_get_cache_fn)pt_dyld_process_info_get_cache_sym()->plain_fn;
}

static const pt_dyld_proc_info_sym_t *pt_dyld_process_info_get_state_sym(void) {
    static pt_dyld_proc_info_sym_t s_sym = { NULL, NULL };
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pt_resolve_dual_dyld_sym(&s_sym, "dyld_process_info_get_state", (void *)&pt_orig_sym_dyld_process_info_get_state);
    });
    return &s_sym;
}

static pt_dyld_process_info_get_state_fn pt_resolve_dyld_process_info_get_state(void) {
    if (&pt_orig_sym_dyld_process_info_get_state != NULL) {
        return pt_orig_sym_dyld_process_info_get_state;
    }
    return (pt_dyld_process_info_get_state_fn)pt_dyld_process_info_get_state_sym()->plain_fn;
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
static _Atomic uint64_t s_post13_cached_dyld_gen = UINT64_MAX;

static void pt_rebuild_post13_range_cache(uint32_t cur_ic, uint64_t cur_gen) {
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
    atomic_store_explicit(&s_post13_cached_dyld_gen, cur_gen, memory_order_release);
    os_unfair_lock_unlock(&s_post13_range_lock);
}

__attribute__((visibility("hidden"))) BOOL pt_is_hidden_post13_7_class(Class cls) {
    if (cls == Nil || !pt_is_compat13_7_active()) {
        return NO;
    }
    uint32_t cur_ic = _dyld_image_count();
    uint64_t cur_gen = atomic_load_explicit(&s_dyld_generation, memory_order_acquire);
    if (cur_ic != atomic_load_explicit(&s_post13_cached_image_count, memory_order_acquire) ||
        cur_gen != atomic_load_explicit(&s_post13_cached_dyld_gen, memory_order_acquire)) {
        pt_rebuild_post13_range_cache(cur_ic, cur_gen);
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
static _Atomic uint64_t s_hidden_img_cached_dyld_gen = UINT64_MAX;

static void pt_rebuild_hidden_img_range_cache(uint32_t cur_ic, uint64_t cur_reg_gen, uint64_t cur_dyld_gen) {
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
    atomic_store_explicit(&s_hidden_img_cached_dyld_gen, cur_dyld_gen, memory_order_release);
    os_unfair_lock_unlock(&s_hidden_img_range_lock);
    free(local_ranges);
}

__attribute__((visibility("hidden"))) BOOL pt_is_class_in_hidden_image(Class cls) {
    if (cls == Nil) {
        return NO;
    }
    uint32_t cur_ic = _dyld_image_count();
    uint64_t cur_reg_gen = pt_hidden_registry_generation();
    uint64_t cur_dyld_gen = atomic_load_explicit(&s_dyld_generation, memory_order_acquire);
    if (cur_ic != atomic_load_explicit(&s_hidden_img_cached_image_count, memory_order_acquire) ||
        cur_reg_gen != atomic_load_explicit(&s_hidden_img_cached_reg_gen, memory_order_acquire) ||
        cur_dyld_gen != atomic_load_explicit(&s_hidden_img_cached_dyld_gen, memory_order_acquire)) {
        pt_rebuild_hidden_img_range_cache(cur_ic, cur_reg_gen, cur_dyld_gen);
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

__attribute__((visibility("hidden"))) const char *pt_dyld_sanitize_or_hide_image_path(const char *path) {
    if (path == NULL) {
        return NULL;
    }
    if (pt_should_hide_dyld_image(path)) {
        return NULL;
    }
    return pt_sanitize_image_path_for_app(path);
}

extern bool pt_orig_dyld_is_memory_immutable(const void *addr, size_t length)
    __asm__("__dyld_is_memory_immutable") __attribute__((weak_import));

static bool pt_dyld_is_memory_immutable(const void *addr, size_t length) {
    if (pt_orig_dyld_is_memory_immutable == NULL) {
        return false;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        addr = pt_resolve_interposed_target(addr);
        const struct mach_header *mh = dyld_image_header_containing_address(addr);
        if (mh != NULL && pt_is_hidden_dyld_image_header(mh)) {
            return false;
        }
        const char *path = dyld_image_path_containing_address(addr);
        if (path != NULL && pt_should_hide_dyld_image(path)) {
            return false;
        }
    }
    return pt_orig_dyld_is_memory_immutable(addr, length);
}

typedef struct {
    uuid_t uuid;
    uint64_t offsetInImage;
    const struct mach_header *image;
} pt_dyld_image_uuid_offset_t;

extern void pt_orig_dyld_images_for_addresses(unsigned count,
                                              const void *addresses[],
                                              pt_dyld_image_uuid_offset_t infos[])
    __asm__("__dyld_images_for_addresses") __attribute__((weak_import));

static void pt_dyld_images_for_addresses(unsigned count,
                                         const void *addresses[],
                                         pt_dyld_image_uuid_offset_t infos[]) {
    if (pt_orig_dyld_images_for_addresses == NULL || count == 0 || addresses == NULL || infos == NULL) {
        return;
    }
    BOOL appCaller = (pt_is_bypass_enabled() &&
                      !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    if (!appCaller) {
        pt_orig_dyld_images_for_addresses(count, addresses, infos);
        return;
    }
    const void *stack_addrs[64];
    const void **resolved_addrs = stack_addrs;
    const void **heap_addrs = NULL;
    if (count > 64U) {
        heap_addrs = (const void **)malloc((size_t)count * sizeof(const void *));
        if (heap_addrs == NULL) {
            pt_orig_dyld_images_for_addresses(count, addresses, infos);
            return;
        }
        resolved_addrs = heap_addrs;
    }
    for (unsigned i = 0; i < count; i++) {
        resolved_addrs[i] = pt_resolve_interposed_target(addresses[i]);
    }
    pt_orig_dyld_images_for_addresses(count, resolved_addrs, infos);
    free(heap_addrs);

    const struct mach_header *fb_hdr = _dyld_get_image_header(pt_fallback_system_image_index());
    for (unsigned i = 0; i < count; i++) {
        const struct mach_header *mh = infos[i].image;
        if (mh == NULL) {
            continue;
        }
        const char *path = pt_dyld_lookup_image_name_for_mh(mh);
        if (pt_is_hidden_dyld_image_header(mh) || (path != NULL && pt_should_hide_dyld_image(path))) {
            memset(infos[i].uuid, 0, sizeof(infos[i].uuid));
            infos[i].offsetInImage = 0;
            infos[i].image = fb_hdr;
        }
    }
}

typedef void (*pt_dyld_load_notify_fn)(const struct mach_header *mh, const char *path, bool unloadable);
typedef void (*pt_dyld_bulk_notify_fn)(unsigned count, const struct mach_header *mhs[], const char *paths[]);

extern void pt_orig_dyld_register_for_image_loads(pt_dyld_load_notify_fn func)
    __asm__("__dyld_register_for_image_loads") __attribute__((weak_import));
extern void pt_orig_dyld_register_for_bulk_image_loads(pt_dyld_bulk_notify_fn func)
    __asm__("__dyld_register_for_bulk_image_loads") __attribute__((weak_import));

typedef struct {
    const struct mach_header *mh;
    const char *path;
    bool unloadable;
} pt_dyld_load_rec_t;

static pthread_mutex_t s_load_notify_mutex = PTHREAD_MUTEX_INITIALIZER;
static pt_dyld_load_rec_t *s_visible_load_recs = NULL;
static size_t s_visible_load_count = 0;
static size_t s_visible_load_cap = 0;
static pt_dyld_load_notify_fn s_app_load_cbs[64];
static uint32_t s_app_load_cb_count = 0;
static pt_dyld_bulk_notify_fn s_app_bulk_cbs[64];
static uint32_t s_app_bulk_cb_count = 0;
static _Atomic BOOL s_load_master_replaying = NO;
static dispatch_once_t s_load_master_once;
static dispatch_once_t s_bulk_master_once;

static void pt_append_visible_load_rec_locked(const struct mach_header *mh, const char *path, bool unloadable) {
    for (size_t i = 0; i < s_visible_load_count; i++) {
        if (s_visible_load_recs[i].mh == mh) {
            return;
        }
    }
    if (s_visible_load_count >= s_visible_load_cap) {
        size_t new_cap = (s_visible_load_cap == 0) ? 128U : (s_visible_load_cap * 2U);
        pt_dyld_load_rec_t *grown = (pt_dyld_load_rec_t *)realloc(s_visible_load_recs, new_cap * sizeof(pt_dyld_load_rec_t));
        if (grown == NULL) {
            return;
        }
        s_visible_load_recs = grown;
        s_visible_load_cap = new_cap;
    }
    s_visible_load_recs[s_visible_load_count++] = (pt_dyld_load_rec_t){
        .mh = mh,
        .path = path,
        .unloadable = unloadable
    };
}

static void pt_master_dyld_load_cb(const struct mach_header *mh, const char *path, bool unloadable) {
    if (mh == NULL) {
        return;
    }
    const char *lookup_path = (path != NULL) ? path : pt_dyld_lookup_image_name_for_mh(mh);
    if (pt_is_hidden_dyld_image_header(mh) || (lookup_path != NULL && pt_should_hide_dyld_image(lookup_path))) {
        return;
    }
    const char *clean_path = (lookup_path != NULL) ? pt_sanitize_image_path_for_app(lookup_path) : NULL;
    pthread_mutex_lock(&s_load_notify_mutex);
    size_t prev_count = s_visible_load_count;
    pt_append_visible_load_rec_locked(mh, clean_path, unloadable);
    BOOL is_new = (s_visible_load_count > prev_count);
    BOOL replaying = atomic_load_explicit(&s_load_master_replaying, memory_order_acquire);
    pt_dyld_load_notify_fn cbs[64];
    uint32_t cb_n = (!replaying && is_new) ? s_app_load_cb_count : 0;
    if (cb_n > 0) {
        memcpy(cbs, s_app_load_cbs, cb_n * sizeof(pt_dyld_load_notify_fn));
    }
    pthread_mutex_unlock(&s_load_notify_mutex);
    for (uint32_t i = 0; i < cb_n; i++) {
        if (cbs[i] != NULL) {
            cbs[i](mh, clean_path, unloadable);
        }
    }
}

static void pt_master_dyld_bulk_cb(unsigned count, const struct mach_header *mhs[], const char *paths[]) {
    if (count == 0 || mhs == NULL) {
        return;
    }
    const struct mach_header **clean_mhs = (const struct mach_header **)malloc((size_t)count * sizeof(const struct mach_header *));
    const char **clean_paths = (const char **)malloc((size_t)count * sizeof(const char *));
    if (clean_mhs == NULL || clean_paths == NULL) {
        free(clean_mhs);
        free(clean_paths);
        return;
    }
    unsigned kept = 0;
    for (unsigned i = 0; i < count; i++) {
        const struct mach_header *mh = mhs[i];
        const char *raw_p = (paths != NULL && paths[i] != NULL) ? paths[i] : pt_dyld_lookup_image_name_for_mh(mh);
        if (mh == NULL || pt_is_hidden_dyld_image_header(mh) || (raw_p != NULL && pt_should_hide_dyld_image(raw_p))) {
            continue;
        }
        clean_mhs[kept] = mh;
        clean_paths[kept] = (raw_p != NULL) ? pt_sanitize_image_path_for_app(raw_p) : NULL;
        kept++;
    }
    if (kept > 0) {
        pt_dyld_bulk_notify_fn cbs[64];
        uint32_t cb_n = 0;
        pthread_mutex_lock(&s_load_notify_mutex);
        cb_n = s_app_bulk_cb_count;
        if (cb_n > 0) {
            memcpy(cbs, s_app_bulk_cbs, cb_n * sizeof(pt_dyld_bulk_notify_fn));
        }
        pthread_mutex_unlock(&s_load_notify_mutex);
        for (uint32_t i = 0; i < cb_n; i++) {
            if (cbs[i] != NULL) {
                cbs[i](kept, clean_mhs, clean_paths);
            }
        }
    }
    free(clean_mhs);
    free(clean_paths);
}

static void pt_ensure_load_notify_master(void) {
    dispatch_once(&s_load_master_once, ^{
        if (pt_orig_dyld_register_for_image_loads != NULL) {
            atomic_store_explicit(&s_load_master_replaying, YES, memory_order_release);
            pt_orig_dyld_register_for_image_loads(pt_master_dyld_load_cb);
            atomic_store_explicit(&s_load_master_replaying, NO, memory_order_release);
        }
    });
}

static void pt_dyld_register_for_image_loads(pt_dyld_load_notify_fn func) {
    if (pt_orig_dyld_register_for_image_loads == NULL || func == NULL) {
        return;
    }
    if (!pt_is_bypass_enabled() || pt_is_system_or_playtools_caller((const void *)func)) {
        pt_orig_dyld_register_for_image_loads(func);
        return;
    }
    pt_ensure_load_notify_master();
    pthread_mutex_lock(&s_load_notify_mutex);
    size_t count = s_visible_load_count;
    pt_dyld_load_rec_t *snap = (count > 0) ? (pt_dyld_load_rec_t *)malloc(count * sizeof(pt_dyld_load_rec_t)) : NULL;
    if (snap != NULL) {
        memcpy(snap, s_visible_load_recs, count * sizeof(pt_dyld_load_rec_t));
    } else {
        count = 0;
    }
    if (s_app_load_cb_count < 64) {
        s_app_load_cbs[s_app_load_cb_count++] = func;
    }
    pthread_mutex_unlock(&s_load_notify_mutex);
    for (size_t i = 0; i < count; i++) {
        func(snap[i].mh, snap[i].path, snap[i].unloadable);
    }
    free(snap);
}

static void pt_dyld_register_for_bulk_image_loads(pt_dyld_bulk_notify_fn func) {
    if (pt_orig_dyld_register_for_bulk_image_loads == NULL || func == NULL) {
        return;
    }
    if (!pt_is_bypass_enabled() || pt_is_system_or_playtools_caller((const void *)func)) {
        pt_orig_dyld_register_for_bulk_image_loads(func);
        return;
    }
    pthread_mutex_lock(&s_load_notify_mutex);
    if (s_app_bulk_cb_count < 64) {
        s_app_bulk_cbs[s_app_bulk_cb_count++] = func;
    }
    pthread_mutex_unlock(&s_load_notify_mutex);
    dispatch_once(&s_bulk_master_once, ^{
        pt_orig_dyld_register_for_bulk_image_loads(pt_master_dyld_bulk_cb);
    });
}

extern void pt_orig_dyld_process_info_for_each_segment(
    pt_dyld_process_info_t info,
    uint64_t machHeaderAddress,
    void (^callback)(uint64_t segmentAddress, uint64_t segmentSize, const char *segmentName))
    __asm__("__dyld_process_info_for_each_segment") __attribute__((weak_import));

static void pt_dyld_process_info_for_each_segment(
    pt_dyld_process_info_t info,
    uint64_t machHeaderAddress,
    void (^callback)(uint64_t segmentAddress, uint64_t segmentSize, const char *segmentName)) {
    if (pt_orig_dyld_process_info_for_each_segment == NULL || info == NULL || callback == NULL) {
        return;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        const struct mach_header *mh = (const struct mach_header *)(uintptr_t)machHeaderAddress;
        if (mh != NULL) {
            const char *path = pt_dyld_lookup_image_name_for_mh(mh);
            if (pt_is_hidden_dyld_image_header(mh) || (path != NULL && pt_should_hide_dyld_image(path))) {
                return;
            }
        }
    }
    pt_orig_dyld_process_info_for_each_segment(info, machHeaderAddress, callback);
}

extern const struct mach_header *pt_orig_dyld_get_dlopen_image_header(void *handle)
    __asm__("__dyld_get_dlopen_image_header") __attribute__((weak_import));

static const struct mach_header *pt_dyld_get_dlopen_image_header(void *handle) {
    if (pt_orig_dyld_get_dlopen_image_header == NULL) {
        return NULL;
    }
    const struct mach_header *mh = pt_orig_dyld_get_dlopen_image_header(handle);
    if (mh != NULL && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_is_compat13_7_active()) {
            return NULL;
        }
        const char *path = pt_dyld_lookup_image_name_for_mh(mh);
        if (pt_is_hidden_dyld_image_header(mh) || (path != NULL && pt_should_hide_dyld_image(path))) {
            return NULL;
        }
    }
    return mh;
}

extern void *pt_orig_dyld_process_create_for_current_task(void)
    __asm__("_dyld_process_create_for_current_task") __attribute__((weak_import));
extern void *pt_orig_dyld_process_create_for_task(task_t task, kern_return_t *kr)
    __asm__("_dyld_process_create_for_task") __attribute__((weak_import));
extern void *pt_orig_dyld_process_snapshot_create_for_process(void *process, kern_return_t *kr)
    __asm__("_dyld_process_snapshot_create_for_process") __attribute__((weak_import));
extern void pt_orig_dyld_process_snapshot_for_each_image(void *snapshot, void (^block)(void *image))
    __asm__("_dyld_process_snapshot_for_each_image") __attribute__((weak_import));
extern void *pt_orig_dyld_process_snapshot_get_shared_cache(void *snapshot)
    __asm__("_dyld_process_snapshot_get_shared_cache") __attribute__((weak_import));
extern void pt_orig_dyld_shared_cache_for_each_image(void *cache, void (^block)(void *image))
    __asm__("_dyld_shared_cache_for_each_image") __attribute__((weak_import));
extern const char *pt_orig_dyld_image_get_file_path(void *image)
    __asm__("_dyld_image_get_file_path") __attribute__((weak_import));
extern const char *pt_orig_dyld_image_get_installname(void *image)
    __asm__("_dyld_image_get_installname") __attribute__((weak_import));

static void *pt_dyld_process_create_for_current_task(void) {
    if (pt_orig_dyld_process_create_for_current_task == NULL) {
        return NULL;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_compat13_7_active()) {
        return NULL;
    }
    return pt_orig_dyld_process_create_for_current_task();
}

static void *pt_dyld_process_create_for_task(task_t task, kern_return_t *kr) {
    if (pt_orig_dyld_process_create_for_task == NULL) {
        if (kr != NULL) *kr = KERN_NOT_SUPPORTED;
        return NULL;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_compat13_7_active()) {
        if (kr != NULL) *kr = KERN_NOT_SUPPORTED;
        return NULL;
    }
    return pt_orig_dyld_process_create_for_task(task, kr);
}

static void *pt_dyld_process_snapshot_create_for_process(void *process, kern_return_t *kr) {
    if (pt_orig_dyld_process_snapshot_create_for_process == NULL) {
        if (kr != NULL) *kr = KERN_NOT_SUPPORTED;
        return NULL;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_is_compat13_7_active()) {
            if (kr != NULL) *kr = KERN_NOT_SUPPORTED;
            return NULL;
        }
        pt_dyld_set_force_task_dyld_sanitize(YES);
        void *snap = pt_orig_dyld_process_snapshot_create_for_process(process, kr);
        pt_dyld_set_force_task_dyld_sanitize(NO);
        return snap;
    }
    return pt_orig_dyld_process_snapshot_create_for_process(process, kr);
}

static void *pt_dyld_process_snapshot_get_shared_cache(void *snapshot) {
    if (pt_orig_dyld_process_snapshot_get_shared_cache == NULL || snapshot == NULL) {
        return NULL;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_compat13_7_active()) {
        return NULL;
    }
    return pt_orig_dyld_process_snapshot_get_shared_cache(snapshot);
}

static BOOL pt_dyld_image_t_should_hide(void *image) {
    if (image == NULL) {
        return YES;
    }
    const char *fp = (pt_orig_dyld_image_get_file_path != NULL) ? pt_orig_dyld_image_get_file_path(image) : NULL;
    if (fp != NULL && pt_should_hide_dyld_image(fp)) {
        return YES;
    }
    const char *inst = (pt_orig_dyld_image_get_installname != NULL) ? pt_orig_dyld_image_get_installname(image) : NULL;
    if (inst != NULL && pt_should_hide_dyld_image(inst)) {
        return YES;
    }
    return NO;
}

static void pt_dyld_process_snapshot_for_each_image(void *snapshot, void (^block)(void *image)) {
    if (pt_orig_dyld_process_snapshot_for_each_image == NULL || snapshot == NULL || block == NULL) {
        return;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_is_compat13_7_active()) {
            return;
        }
        pt_orig_dyld_process_snapshot_for_each_image(snapshot, ^(void *image) {
            if (!pt_dyld_image_t_should_hide(image)) {
                block(image);
            }
        });
        return;
    }
    pt_orig_dyld_process_snapshot_for_each_image(snapshot, block);
}

static void pt_dyld_shared_cache_for_each_image(void *cache, void (^block)(void *image)) {
    if (pt_orig_dyld_shared_cache_for_each_image == NULL || cache == NULL || block == NULL) {
        return;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_is_compat13_7_active()) {
            return;
        }
        pt_orig_dyld_shared_cache_for_each_image(cache, ^(void *image) {
            if (!pt_dyld_image_t_should_hide(image)) {
                block(image);
            }
        });
        return;
    }
    pt_orig_dyld_shared_cache_for_each_image(cache, block);
}

static const char *pt_dyld_image_get_file_path(void *image) {
    if (pt_orig_dyld_image_get_file_path == NULL || image == NULL) {
        return NULL;
    }
    const char *raw = pt_orig_dyld_image_get_file_path(image);
    if (raw != NULL && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return pt_dyld_sanitize_or_hide_image_path(raw);
    }
    return raw;
}

static const char *pt_dyld_image_get_installname(void *image) {
    if (pt_orig_dyld_image_get_installname == NULL || image == NULL) {
        return NULL;
    }
    const char *raw = pt_orig_dyld_image_get_installname(image);
    if (raw != NULL && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return pt_dyld_sanitize_or_hide_image_path(raw);
    }
    return raw;
}

static void *pt_dlsym_resolve_proc_info_create_plain(void) {
    return (pt_dyld_process_info_create_sym()->plain_fn != NULL) ? (void *)&pt_dyld_process_info_create : NULL;
}

static void *pt_dlsym_resolve_proc_info_for_each_plain(void) {
    return (pt_dyld_process_info_for_each_image_sym()->plain_fn != NULL)
               ? (void *)&pt_dyld_process_info_for_each_image
               : NULL;
}

static void *pt_dlsym_resolve_proc_info_platform_plain(void) {
    return (pt_dyld_process_info_get_platform_sym()->plain_fn != NULL)
               ? (void *)&pt_dyld_process_info_get_platform
               : NULL;
}

static void *pt_dlsym_resolve_proc_info_cache_plain(void) {
    return (pt_dyld_process_info_get_cache_sym()->plain_fn != NULL)
               ? (void *)&pt_dyld_process_info_get_cache
               : NULL;
}

static void *pt_dlsym_resolve_proc_info_state_plain(void) {
    return (pt_dyld_process_info_get_state_sym()->plain_fn != NULL)
               ? (void *)&pt_dyld_process_info_get_state
               : NULL;
}

PT_INTERPOSE_WEAK_NAMED(pt_dyld_shared_cache_real_path, pt_orig_sym_dyld_shared_cache_real_path, "_dyld_shared_cache_real_path")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_shared_cache_some_image_overridden, pt_orig_sym_dyld_shared_cache_some_image_overridden, "dyld_shared_cache_some_image_overridden")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_get_prog_image_header, pt_orig_sym_dyld_get_prog_image_header, "_dyld_get_prog_image_header")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_find_unwind_sections, pt_orig_sym_dyld_find_unwind_sections, "_dyld_find_unwind_sections")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_process_info_create, pt_orig_sym_dyld_process_info_create, "_dyld_process_info_create")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_process_info_for_each_image, pt_orig_sym_dyld_process_info_for_each_image, "_dyld_process_info_for_each_image")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_process_info_get_platform, pt_orig_sym_dyld_process_info_get_platform, "_dyld_process_info_get_platform")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_process_info_get_cache, pt_orig_sym_dyld_process_info_get_cache, "_dyld_process_info_get_cache")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_process_info_get_state, pt_orig_sym_dyld_process_info_get_state, "_dyld_process_info_get_state")

PT_DLSYM_DYNAMIC("dyld_process_info_create", pt_dlsym_resolve_proc_info_create_plain)
PT_DLSYM_DYNAMIC("dyld_process_info_for_each_image", pt_dlsym_resolve_proc_info_for_each_plain)
PT_DLSYM_DYNAMIC("dyld_process_info_get_platform", pt_dlsym_resolve_proc_info_platform_plain)
PT_DLSYM_DYNAMIC("dyld_process_info_get_cache", pt_dlsym_resolve_proc_info_cache_plain)
PT_DLSYM_DYNAMIC("dyld_process_info_get_state", pt_dlsym_resolve_proc_info_state_plain)

PT_INTERPOSE_WEAK(pt_dyld_get_active_platform, dyld_get_active_platform)
PT_INTERPOSE_WEAK(pt_dyld_get_base_platform, dyld_get_base_platform)
PT_INTERPOSE_WEAK_NAMED(pt_dyld_has_inserted_or_interposing_libraries, pt_orig_dyld_has_inserted_or_interposing_libraries, "dyld_has_inserted_or_interposing_libraries")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_get_image_versions, pt_orig_dyld_get_image_versions, "dyld_get_image_versions")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_sdk_at_least, pt_orig_dyld_sdk_at_least, "dyld_sdk_at_least")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_minos_at_least, pt_orig_dyld_minos_at_least, "dyld_minos_at_least")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_get_sdk_version, pt_orig_dyld_get_sdk_version, "dyld_get_sdk_version")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_get_min_os_version, pt_orig_dyld_get_min_os_version, "dyld_get_min_os_version")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_get_program_sdk_version, pt_orig_dyld_get_program_sdk_version, "dyld_get_program_sdk_version")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_get_program_min_os_version, pt_orig_dyld_get_program_min_os_version, "dyld_get_program_min_os_version")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_program_sdk_at_least, pt_orig_dyld_program_sdk_at_least, "dyld_program_sdk_at_least")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_program_minos_at_least, pt_orig_dyld_program_minos_at_least, "dyld_program_minos_at_least")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_get_program_sdk_version_token, pt_orig_dyld_get_program_sdk_version_token, "dyld_get_program_sdk_version_token")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_get_program_minos_version_token, pt_orig_dyld_get_program_minos_version_token, "dyld_get_program_minos_version_token")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_version_token_get_platform, pt_orig_dyld_version_token_get_platform, "dyld_version_token_get_platform")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_version_token_at_least, pt_orig_dyld_version_token_at_least, "dyld_version_token_at_least")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_is_memory_immutable, pt_orig_dyld_is_memory_immutable, "_dyld_is_memory_immutable")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_images_for_addresses, pt_orig_dyld_images_for_addresses, "_dyld_images_for_addresses")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_register_for_image_loads, pt_orig_dyld_register_for_image_loads, "_dyld_register_for_image_loads")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_register_for_bulk_image_loads, pt_orig_dyld_register_for_bulk_image_loads, "_dyld_register_for_bulk_image_loads")
PT_INTERPOSE_WEAK_NAMED(pt_dyld_process_info_for_each_segment, pt_orig_dyld_process_info_for_each_segment, "_dyld_process_info_for_each_segment")
PT_INTERPOSE_WEAK_NAMED_FLAGS(pt_dyld_get_dlopen_image_header, pt_orig_dyld_get_dlopen_image_header, "_dyld_get_dlopen_image_header", PT_DLSYM_FLAG_HIDE_IN_COMPAT13_7)
PT_INTERPOSE_WEAK_NAMED_FLAGS(pt_dyld_process_create_for_current_task, pt_orig_dyld_process_create_for_current_task, "dyld_process_create_for_current_task", PT_DLSYM_FLAG_HIDE_IN_COMPAT13_7)
PT_INTERPOSE_WEAK_NAMED_FLAGS(pt_dyld_process_create_for_task, pt_orig_dyld_process_create_for_task, "dyld_process_create_for_task", PT_DLSYM_FLAG_HIDE_IN_COMPAT13_7)
PT_INTERPOSE_WEAK_NAMED_FLAGS(pt_dyld_process_snapshot_create_for_process, pt_orig_dyld_process_snapshot_create_for_process, "dyld_process_snapshot_create_for_process", PT_DLSYM_FLAG_HIDE_IN_COMPAT13_7)
PT_INTERPOSE_WEAK_NAMED_FLAGS(pt_dyld_process_snapshot_for_each_image, pt_orig_dyld_process_snapshot_for_each_image, "dyld_process_snapshot_for_each_image", PT_DLSYM_FLAG_HIDE_IN_COMPAT13_7)
PT_INTERPOSE_WEAK_NAMED_FLAGS(pt_dyld_process_snapshot_get_shared_cache, pt_orig_dyld_process_snapshot_get_shared_cache, "dyld_process_snapshot_get_shared_cache", PT_DLSYM_FLAG_HIDE_IN_COMPAT13_7)
PT_INTERPOSE_WEAK_NAMED_FLAGS(pt_dyld_shared_cache_for_each_image, pt_orig_dyld_shared_cache_for_each_image, "dyld_shared_cache_for_each_image", PT_DLSYM_FLAG_HIDE_IN_COMPAT13_7)
PT_INTERPOSE_WEAK_NAMED_FLAGS(pt_dyld_image_get_file_path, pt_orig_dyld_image_get_file_path, "dyld_image_get_file_path", PT_DLSYM_FLAG_HIDE_IN_COMPAT13_7)
PT_INTERPOSE_WEAK_NAMED_FLAGS(pt_dyld_image_get_installname, pt_orig_dyld_image_get_installname, "dyld_image_get_installname", PT_DLSYM_FLAG_HIDE_IN_COMPAT13_7)
PT_INTERPOSE_WEAK(pt_dyld_shared_cache_file_path, dyld_shared_cache_file_path)
PT_INTERPOSE_WEAK_NAMED_FLAGS(pt_dyld_shared_cache_contains_path, pt_orig_dyld_shared_cache_contains_path, "_dyld_shared_cache_contains_path", PT_DLSYM_FLAG_HIDE_IN_COMPAT13_7)
PT_DLSYM_REGISTER_RAW("_dyld_shared_cache_file_path_containing_address", NULL, NULL, PT_DLSYM_FLAG_HIDE_IN_COMPAT13_7)
