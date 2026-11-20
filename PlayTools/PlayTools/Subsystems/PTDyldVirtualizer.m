//
//  PTDyldVirtualizer.m
//  PlayTools
//

#import "PTInternal.h"


static BOOL pt_is_valid_user_pointer(const void *ptr) {
    return pt_is_valid_user_addr((uintptr_t)ptr) ? YES : NO;
}

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
                PT_HAS_PREFIX_LIT(name, "NSTask") ||
                PT_HAS_PREFIX_LIT(name, "NSConcreteTask") ||
                PT_HAS_PREFIX_LIT(name, "NSWorkspace") ||
                PT_HAS_PREFIX_LIT(name, "NSRunningApplication") ||
                PT_HAS_PREFIX_LIT(name, "NSScreen") ||
                PT_HAS_PREFIX_LIT(name, "NSEvent") ||
                PT_HAS_PREFIX_LIT(name, "NSPasteboard")) {
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
        PT_HAS_PREFIX_LIT(name, "AKInterface")) {
        return YES;
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
            return PT_HAS_PREFIX_LIT(selName, "pm_");
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
} pt_swizzle_imp_slot_t;

static pt_swizzle_imp_slot_t s_swizzled_imp_table[PT_SWIZZLE_IMP_SLOTS];

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

__attribute__((visibility("hidden")))
void pt_register_swizzled_imp(const void *hook_imp, const void *orig_imp) {
    uintptr_t hook = (uintptr_t)pt_strip_code_ptr(hook_imp);
    uintptr_t orig = (uintptr_t)pt_strip_code_ptr(orig_imp);
    if (hook == 0 || orig == 0 || hook == 1 || orig == 1 || hook == orig) {
        return;
    }
    const void *root_orig = pt_lookup_swizzled_orig_imp((const void *)orig);
    if (root_orig != NULL) {
        orig = (uintptr_t)root_orig;
    }
    if (hook == orig) {
        return;
    }
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

extern const char *dyld_shared_cache_file_path(void) __attribute__((weak_import));
static const char *pt_dyld_shared_cache_file_path(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return "/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e";
    }
    return (dyld_shared_cache_file_path != NULL) ? dyld_shared_cache_file_path() : NULL;
}


extern const void *pt_orig_objc_getClass(const char *name) __asm__("_objc_getClass");
extern const void *pt_orig_objc_lookUpClass(const char *name) __asm__("_objc_lookUpClass");
extern const void *pt_orig_NSClassFromString(CFStringRef aClassName) __asm__("_NSClassFromString");

static BOOL pt_should_hide_resolved_objc_class(const char *name, Class cls) {
    if (name == NULL || !pt_is_hidden_objc_class(name)) {
        return NO;
    }
    if (name[0] == 'N' && name[1] == 'S' && cls != Nil) {
        const char *img = class_getImageName(cls);
        if (img != NULL) {
            pt_ensure_bundle_path_map();
            if (s_real_app_bundle_len > 0 &&
                pt_match_prefix_modulo_private(img, s_real_app_bundle_dir, s_real_app_bundle_len) != NULL) {
                return NO;
            }
            if (strstr(img, "/UIKitCore.framework/") != NULL ||
                strstr(img, "/UIKit.framework/") != NULL) {
                return NO;
            }
        }
    }
    return YES;
}

static const void *pt_objc_getClass(const char *name) {
    if (name != NULL && pt_is_bypass_enabled() && pt_is_hidden_objc_class(name) &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (name[0] == 'N' && name[1] == 'S') {
            const void *cls = pt_orig_objc_getClass(name);
            if (cls != NULL && !pt_should_hide_resolved_objc_class(name, (__bridge Class)cls)) {
                return cls;
            }
        }
        PT_DEBUG_TRACE("dyld", "hid class=%s", name);
        return NULL;
    }
    return pt_orig_objc_getClass(name);
}

static const void *pt_objc_lookUpClass(const char *name) {
    if (name != NULL && pt_is_bypass_enabled() && pt_is_hidden_objc_class(name) &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (name[0] == 'N' && name[1] == 'S') {
            const void *cls = pt_orig_objc_lookUpClass(name);
            if (cls != NULL && !pt_should_hide_resolved_objc_class(name, (__bridge Class)cls)) {
                return cls;
            }
        }
        PT_DEBUG_TRACE("dyld", "hid class=%s", name);
        return NULL;
    }
    return pt_orig_objc_lookUpClass(name);
}

static const void *pt_NSClassFromString(CFStringRef aClassName) {
    if (aClassName != NULL && pt_is_bypass_enabled()) {
        char buf[256];
        const char *cstr = CFStringGetCStringPtr(aClassName, kCFStringEncodingUTF8);
        if (cstr == NULL && CFStringGetCString(aClassName, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            cstr = buf;
        }
        if (cstr != NULL && pt_is_hidden_objc_class(cstr) &&
            !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
            if (cstr[0] == 'N' && cstr[1] == 'S') {
                const void *cls = pt_orig_NSClassFromString(aClassName);
                if (cls != NULL && !pt_should_hide_resolved_objc_class(cstr, (__bridge Class)cls)) {
                    return cls;
                }
            }
            PT_DEBUG_TRACE("dyld", "hid class=%s", cstr);
            return NULL;
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
            if (name == NULL || pt_is_hidden_dyld_image_name(name)) {
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
        if (pt_should_hide_resolved_objc_class(class_getName(cls), cls)) {
            return NULL;
        }
        const char *name = class_getImageName(cls);
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
        if (pt_is_hidden_dyld_image_name(image) || hidden_path) {
            if (outCount != NULL) {
                *outCount = 0;
            }
            return NULL;
        }
        unsigned int count = 0;
        const char **names = objc_copyClassNamesForImage(image, &count);
        if (names == NULL && strncmp(image, "/System/", 8) == 0) {
            const char *fw = strstr(image, ".framework/");
            if (fw != NULL && strstr(fw, ".framework/Versions/") == NULL) {
                char ver_path[PATH_MAX];
                size_t prefix_len = (size_t)(fw + 10 - image);
                snprintf(ver_path, sizeof(ver_path), "%.*s/Versions/A%s",
                         (int)prefix_len, image, fw + 10);
                names = objc_copyClassNamesForImage(ver_path, &count);
                if (names == NULL && strncmp(ver_path, "/System/iOSSupport/", 19) != 0) {
                    char ios_ver_path[PATH_MAX];
                    snprintf(ios_ver_path, sizeof(ios_ver_path), "/System/iOSSupport%s", ver_path);
                    names = objc_copyClassNamesForImage(ios_ver_path, &count);
                }
            }
            if (names == NULL && strncmp(image, "/System/iOSSupport/", 19) != 0) {
                char ios_path[PATH_MAX];
                snprintf(ios_path, sizeof(ios_path), "/System/iOSSupport%s", image);
                names = objc_copyClassNamesForImage(ios_path, &count);
            }
        }
        if (names != NULL) {
            unsigned int writeIdx = 0;
            for (unsigned int i = 0; i < count; i++) {
                if (names[i] != NULL && pt_is_hidden_objc_class(names[i])) {
                    if (names[i][0] == 'N' && names[i][1] == 'S') {
                        const void *cls = pt_orig_objc_lookUpClass(names[i]);
                        if (cls != NULL && !pt_should_hide_resolved_objc_class(names[i], (__bridge Class)cls)) {
                            names[writeIdx++] = names[i];
                            continue;
                        }
                    }
                    continue;
                }
                names[writeIdx++] = names[i];
            }
            names[writeIdx] = NULL;
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

static Class *pt_objc_copyClassList(unsigned int *outCount) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (classes != NULL && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
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

static int pt_objc_getClassList(Class *buffer, int bufferCount) {
    if (!pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return objc_getClassList(buffer, bufferCount);
    }
    unsigned int count = 0;
    Class *classes = pt_objc_copyClassList(&count);
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

static Method *pt_class_copyMethodList(Class cls, unsigned int *outCount) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (methods != NULL && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        unsigned int writeIdx = 0;
        for (unsigned int i = 0; i < count; i++) {
            Method m = methods[i];
            if (m != NULL) {
                SEL sel = method_getName(m);
                const char *selName = (sel != NULL) ? sel_getName(sel) : NULL;
                if (pt_is_hidden_objc_selector_name(selName) &&
                    pt_is_address_in_playtools((const void *)method_getImplementation(m))) {
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
    BOOL orig = class_respondsToSelector(cls, sel);
    if (orig && pt_is_bypass_enabled() &&
        pt_is_hidden_objc_selector_name(sel_getName(sel)) &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        Method m = class_getInstanceMethod(cls, sel);
        if (m != NULL && pt_is_address_in_playtools((const void *)method_getImplementation(m))) {
            return NO;
        }
    }
    return orig;
}

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

static BOOL pt_should_block_dlopen_path(const char *path, const void *caller) {
    if (path == NULL || !pt_is_bypass_enabled()) {
        return NO;
    }
    if (pt_is_effective_system_or_playtools_caller(caller)) {
        return NO;
    }
    return (pt_is_hidden_path(path, caller) ||
            pt_is_hidden_dyld_image_name(path) ||
            strstr(path, "MobileSubstrate") != NULL ||
            strstr(path, "SubstrateInserter") != NULL ||
            strstr(path, "SubstrateBootstrap") != NULL ||
            strstr(path, "TweakInject") != NULL ||
            strstr(path, "frida") != NULL ||
            strstr(path, "cycript") != NULL);
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
    if (mh == NULL || rpath_rel == NULL || mh->magic != MH_MAGIC_64) {
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
    return (caller != NULL) ? dlopen_from(path, mode, (void *)caller) : dlopen(path, mode);
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
            int res = pt_dlopen_preflight_search_rpaths(caller_hdr, rel, caller_dir, exec_dir, caller);
            if (res > 0) {
                return true;
            }
            if (res < 0) {
                return false;
            }
            if (main_hdr != NULL && main_hdr != caller_hdr) {
                res = pt_dlopen_preflight_search_rpaths(main_hdr, rel, exec_dir, exec_dir, caller);
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
        }
        if (symbol[0] == 'M' && symbol[1] == 'G') {
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
                    if (app_caller && pt_is_hidden_dyld_image_name(img_name)) {
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
                pt_is_hidden_dyld_image_name(sym_info.dli_fname)) {
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
DYLD_INTERPOSE(pt_dyld_shared_cache_file_path, dyld_shared_cache_file_path)
DYLD_INTERPOSE(pt_objc_getClass, objc_getClass)
DYLD_INTERPOSE(pt_objc_lookUpClass, objc_lookUpClass)
DYLD_INTERPOSE(pt_NSClassFromString, NSClassFromString)
DYLD_INTERPOSE(pt_objc_copyImageNames, objc_copyImageNames)
DYLD_INTERPOSE(pt_class_getImageName, class_getImageName)
DYLD_INTERPOSE(pt_objc_copyClassNamesForImage, objc_copyClassNamesForImage)
DYLD_INTERPOSE(pt_objc_copyClassList, objc_copyClassList)
DYLD_INTERPOSE(pt_objc_getClassList, objc_getClassList)
DYLD_INTERPOSE(pt_class_copyMethodList, class_copyMethodList)
DYLD_INTERPOSE(pt_class_respondsToSelector, class_respondsToSelector)
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
DYLD_INTERPOSE(pt_dladdr, dladdr)
DYLD_INTERPOSE(pt_dlopen, dlopen)
DYLD_INTERPOSE(pt_dlopen_preflight, dlopen_preflight)
DYLD_INTERPOSE(pt_dlsym, dlsym)
DYLD_INTERPOSE(pt_dlerror, dlerror)

static BOOL (*s_orig_nsobject_respondsToSelector)(id, SEL, SEL) = NULL;
static BOOL (*s_orig_nsobject_instancesRespondToSelector)(id, SEL, SEL) = NULL;
static id (*s_orig_nsobject_methodSignatureForSelector)(id, SEL, SEL) = NULL;
static id (*s_orig_nsobject_instanceMethodSignatureForSelector)(id, SEL, SEL) = NULL;
static IMP (*s_orig_nsobject_methodForSelector)(id, SEL, SEL) = NULL;
static IMP (*s_orig_nsobject_instanceMethodForSelector)(id, SEL, SEL) = NULL;
static IMP s_nsobject_notFoundIMP = NULL;

static inline BOOL ps_should_hide_selector_for_target_class(Class targetCls, SEL aSelector, const void *caller) {
    if (targetCls == Nil ||
        !pt_is_bypass_enabled() ||
        !pt_is_hidden_objc_selector_name(sel_getName(aSelector)) ||
        pt_is_effective_system_or_playtools_caller(caller)) {
        return NO;
    }
    Method m = class_getInstanceMethod(targetCls, aSelector);
    if (m == NULL) {
        return NO;
    }
    return pt_is_address_in_playtools((const void *)method_getImplementation(m));
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
