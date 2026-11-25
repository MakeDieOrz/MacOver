//
//  PTObjCRuntimeVirtualizer.m
//  PlayTools
//

#import "PTDyldInternal.h"
#import "PTSystemSpooferInternal.h"
#import "PTFSInternal.h"


extern const void *pt_orig_objc_getClass(const char *name) __asm__("_objc_getClass");
extern const void *pt_orig_objc_lookUpClass(const char *name) __asm__("_objc_lookUpClass");
extern const void *pt_orig_objc_getMetaClass(const char *name) __asm__("_objc_getMetaClass");
extern const void *pt_orig_objc_getRequiredClass(const char *name) __asm__("_objc_getRequiredClass");
extern const void *pt_orig_NSClassFromString(CFStringRef aClassName) __asm__("_NSClassFromString");

static BOOL pt_should_hide_resolved_objc_class_with_image(const char *name, Class cls, const char *preloaded_img) {
    if (name != NULL && strcmp(name, "NSMenuToolbarItem") == 0) {
        return NO;
    }
    if (preloaded_img != NULL) {
        if (pt_is_post13_7_hidden_framework_path(preloaded_img)) {
            return YES;
        }
        if (pt_is_hidden_dyld_image_name(preloaded_img)) {
            pt_ensure_bundle_path_map();
            if (s_real_app_bundle_len == 0 ||
                pt_match_prefix_modulo_private(preloaded_img, s_real_app_bundle_dir, s_real_app_bundle_len) == NULL) {
                return YES;
            }
        }
    } else if (cls != Nil) {
        if (pt_is_hidden_post13_7_class(cls) || pt_is_class_in_hidden_image(cls)) {
            return YES;
        }
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
                PT_HAS_PREFIX_LIT(name, "NSTouchBar") ||
                PT_HAS_PREFIX_LIT(name, "NSUserNotification") ||
                PT_HAS_PREFIX_LIT(name, "NSSharingService") ||
                strcmp(name, "NSPrintInfo") == 0 ||
                strcmp(name, "NSSound") == 0) {
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

__attribute__((visibility("hidden"))) BOOL pt_should_hide_resolved_objc_class(const char *name, Class cls) {
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
        if (cls != NULL && pt_should_hide_resolved_objc_class(name, (__bridge Class)cls)) {
            PT_DEBUG_TRACE("dyld", "hid resolved class=%s", name);
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
        if (cls != NULL && pt_should_hide_resolved_objc_class(name, (__bridge Class)cls)) {
            PT_DEBUG_TRACE("dyld", "hid resolved class=%s", name);
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
        if (cls != NULL && pt_should_hide_resolved_objc_class(name, (__bridge Class)cls)) {
            PT_DEBUG_TRACE("dyld", "hid resolved metaclass=%s", name);
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
        if (cls != NULL && pt_should_hide_resolved_objc_class(name, (__bridge Class)cls)) {
            PT_DEBUG_TRACE("dyld", "hid resolved required class=%s", name);
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
            if (cls != NULL && pt_should_hide_resolved_objc_class(cstr, (__bridge Class)cls)) {
                PT_DEBUG_TRACE("dyld", "hid resolved class=%s", cstr);
                return NULL;
            }
            return cls;
        }
    }
    return pt_orig_NSClassFromString(aClassName);
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

static const char **pt_objc_copyImageNames(unsigned int *outCount) {
    unsigned int count = 0;
    const char **names = objc_copyImageNames(&count);
    const void *caller = __builtin_return_address(0);
    if (names != NULL && pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        size_t ht_cap = 64U;
        while (ht_cap < (size_t)count * 2U && ht_cap < (1U << 20)) {
            ht_cap <<= 1U;
        }
        const char **ht = (count > 0) ? (const char **)calloc(ht_cap, sizeof(const char *)) : NULL;
        size_t ht_mask = ht_cap - 1U;
        unsigned int writeIdx = 0;
        for (unsigned int i = 0; i < count; i++) {
            const char *name = names[i];
            if (name == NULL || pt_should_hide_dyld_image(name)) {
                continue;
            }
            const char *sanitized = pt_sanitize_image_path_for_app(name);
            if (sanitized == NULL) {
                continue;
            }
            BOOL dup = NO;
            if (ht != NULL) {
                size_t slot = (size_t)pt_fnv1a_cstr(sanitized) & ht_mask;
                for (size_t probe = 0; probe < ht_cap; probe++) {
                    const char *entry = ht[slot];
                    if (entry == NULL) {
                        ht[slot] = sanitized;
                        break;
                    }
                    if (entry == sanitized || strcmp(entry, sanitized) == 0) {
                        dup = YES;
                        break;
                    }
                    slot = (slot + 1U) & ht_mask;
                }
            } else {
                for (unsigned int j = 0; j < writeIdx; j++) {
                    if (names[j] == sanitized || strcmp(names[j], sanitized) == 0) {
                        dup = YES;
                        break;
                    }
                }
            }
            if (!dup) {
                names[writeIdx++] = sanitized;
            }
        }
        free((void *)ht);
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

static BOOL pt_is_hidden_mtl_device_selector_name(const char *sname, BOOL includeCompat13) {
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
        return YES;
    }
    if (includeCompat13) {
        if (strcmp(sname, "architecture") == 0 ||
            strcmp(sname, "supportsBCTextureCompression") == 0 ||
            strcmp(sname, "supports32BitFloatFiltering") == 0 ||
            strcmp(sname, "supports32BitMSAA") == 0 ||
            strcmp(sname, "supportsRaytracing") == 0 ||
            strcmp(sname, "supportsRaytracingFromRender") == 0 ||
            strcmp(sname, "supportsPrimitiveMotionBlur") == 0 ||
            strcmp(sname, "supportsFunctionPointers") == 0 ||
            strcmp(sname, "supportsFunctionPointersFromRender") == 0 ||
            strcmp(sname, "supportsDynamicLibraries") == 0 ||
            strcmp(sname, "supportsRenderDynamicLibraries") == 0 ||
            strcmp(sname, "supportsPullModelInterpolation") == 0 ||
            strcmp(sname, "supportsShaderBarycentricCoordinates") == 0 ||
            strcmp(sname, "supportsQueryTextureLOD") == 0 ||
            strcmp(sname, "supportsCounterSampling:") == 0 ||
            strcmp(sname, "counterSets") == 0 ||
            strcmp(sname, "sparseTileSizeInBytes") == 0) {
            return YES;
        }
    }
    return NO;
}

static BOOL pt_is_hidden_mtl_device_property_name(const char *pname, BOOL includeCompat13) {
    if (pname == NULL || pname[0] == '\0') {
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
        return YES;
    }
    if (includeCompat13) {
        if (strcmp(pname, "architecture") == 0 ||
            strcmp(pname, "supportsBCTextureCompression") == 0 ||
            strcmp(pname, "supports32BitFloatFiltering") == 0 ||
            strcmp(pname, "supports32BitMSAA") == 0 ||
            strcmp(pname, "supportsDynamicLibraries") == 0 ||
            strcmp(pname, "supportsRenderDynamicLibraries") == 0 ||
            strcmp(pname, "supportsRaytracing") == 0 ||
            strcmp(pname, "supportsRaytracingFromRender") == 0 ||
            strcmp(pname, "supportsPrimitiveMotionBlur") == 0 ||
            strcmp(pname, "supportsFunctionPointers") == 0 ||
            strcmp(pname, "supportsFunctionPointersFromRender") == 0 ||
            strcmp(pname, "supportsPullModelInterpolation") == 0 ||
            strcmp(pname, "supportsShaderBarycentricCoordinates") == 0 ||
            strcmp(pname, "supportsQueryTextureLOD") == 0 ||
            strcmp(pname, "counterSets") == 0 ||
            strcmp(pname, "sparseTileSizeInBytes") == 0) {
            return YES;
        }
    }
    return NO;
}

static Protocol * __unsafe_unretained *pt_class_copyProtocolList(Class cls, unsigned int *outCount) {
    if (!pt_is_valid_user_pointer((__bridge const void *)cls)) {
        if (outCount != NULL) {
            *outCount = 0;
        }
        return NULL;
    }
    unsigned int count = 0;
    Protocol * __unsafe_unretained *protos = class_copyProtocolList(cls, &count);
    if (protos != NULL && count > 0 && pt_is_bypass_enabled() &&
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

static BOOL pt_class_conformsToProtocol(Class cls, Protocol *protocol) {
    if (cls == Nil || protocol == nil) {
        return NO;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        const char *pname = protocol_getName(protocol);
        if (pname != NULL && pt_is_hidden_objc_protocol_name(pname)) {
            return NO;
        }
    }
    return class_conformsToProtocol(cls, protocol);
}

static BOOL pt_protocol_conformsToProtocol(Protocol *proto, Protocol *other) {
    if (proto == nil || other == nil) {
        return NO;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        const char *n1 = protocol_getName(proto);
        const char *n2 = protocol_getName(other);
        if ((n1 != NULL && pt_is_hidden_objc_protocol_name(n1)) ||
            (n2 != NULL && pt_is_hidden_objc_protocol_name(n2))) {
            return NO;
        }
    }
    return protocol_conformsToProtocol(proto, other);
}

static objc_property_t *pt_protocol_copyPropertyList(Protocol *proto, unsigned int *outCount) {
    if (proto == nil) {
        if (outCount != NULL) {
            *outCount = 0;
        }
        return NULL;
    }
    const void *caller = __builtin_return_address(0);
    BOOL appCaller = (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller));
    const char *protoName = appCaller ? protocol_getName(proto) : NULL;
    if (appCaller && protoName != NULL && pt_is_hidden_objc_protocol_name(protoName)) {
        if (outCount != NULL) {
            *outCount = 0;
        }
        return NULL;
    }
    unsigned int count = 0;
    objc_property_t *props = protocol_copyPropertyList(proto, &count);
    if (appCaller && props != NULL && count > 0 &&
        protoName != NULL && strcmp(protoName, "MTLDevice") == 0) {
        BOOL compat13 = pt_is_compat13_7_active();
        unsigned int writeIdx = 0;
        for (unsigned int i = 0; i < count; i++) {
            objc_property_t p = props[i];
            const char *pname = (p != NULL) ? property_getName(p) : NULL;
            if (pname != NULL && pt_is_hidden_mtl_device_property_name(pname, compat13)) {
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

static struct objc_method_description *pt_protocol_copyMethodDescriptionList(Protocol *proto,
                                                                             BOOL isRequiredMethod,
                                                                             BOOL isInstanceMethod,
                                                                             unsigned int *outCount) {
    if (proto == nil) {
        if (outCount != NULL) {
            *outCount = 0;
        }
        return NULL;
    }
    const void *caller = __builtin_return_address(0);
    BOOL appCaller = (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller));
    const char *protoName = appCaller ? protocol_getName(proto) : NULL;
    if (appCaller && protoName != NULL && pt_is_hidden_objc_protocol_name(protoName)) {
        if (outCount != NULL) {
            *outCount = 0;
        }
        return NULL;
    }
    unsigned int count = 0;
    struct objc_method_description *descs =
        protocol_copyMethodDescriptionList(proto, isRequiredMethod, isInstanceMethod, &count);
    if (appCaller && descs != NULL && count > 0 && isInstanceMethod &&
        protoName != NULL && strcmp(protoName, "MTLDevice") == 0) {
        BOOL compat13 = pt_is_compat13_7_active();
        unsigned int writeIdx = 0;
        for (unsigned int i = 0; i < count; i++) {
            const char *sname = (descs[i].name != NULL) ? sel_getName(descs[i].name) : NULL;
            if (sname != NULL && pt_is_hidden_mtl_device_selector_name(sname, compat13)) {
                continue;
            }
            descs[writeIdx++] = descs[i];
        }
        if (writeIdx == 0) {
            free(descs);
            if (outCount != NULL) {
                *outCount = 0;
            }
            return NULL;
        }
        if (outCount != NULL) {
            *outCount = writeIdx;
        }
        return descs;
    }
    if (outCount != NULL) {
        *outCount = count;
    }
    return descs;
}

typedef void (*pt_dyld_for_each_objc_class_fn)(
    const char *className,
    void (^callback)(void *classPtr, bool isLoaded, bool *stop));

static pt_dyld_for_each_objc_class_fn pt_resolve_dyld_for_each_objc_class(void) {
    static pt_dyld_for_each_objc_class_fn s_fn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_fn = (pt_dyld_for_each_objc_class_fn)dlsym(RTLD_NEXT, "_dyld_for_each_objc_class");
    });
    return s_fn;
}

static void pt_dyld_for_each_objc_class(
    const char *className,
    void (^callback)(void *classPtr, bool isLoaded, bool *stop)) {
    pt_dyld_for_each_objc_class_fn fn = pt_resolve_dyld_for_each_objc_class();
    if (fn == NULL || callback == NULL) {
        return;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (className != NULL && pt_is_hidden_objc_class(className) &&
            !(className[0] == 'N' && className[1] == 'S')) {
            return;
        }
        fn(className, ^(void *classPtr, bool isLoaded, bool *stop) {
            const char *img = (classPtr != NULL) ? dyld_image_path_containing_address(classPtr) : NULL;
            if (img != NULL && pt_should_hide_dyld_image(img)) {
                return;
            }
            if (isLoaded && classPtr != NULL) {
                Class cls = (__bridge Class)classPtr;
                const char *cname = (className != NULL) ? className : class_getName(cls);
                if (pt_should_hide_resolved_objc_class_with_image(cname, cls, img)) {
                    return;
                }
            } else if (className != NULL && pt_is_hidden_objc_class(className)) {
                pt_ensure_bundle_path_map();
                if (img == NULL || s_real_app_bundle_len == 0 ||
                    pt_match_prefix_modulo_private(img, s_real_app_bundle_dir, s_real_app_bundle_len) == NULL) {
                    return;
                }
            }
            callback(classPtr, isLoaded, stop);
        });
        return;
    }
    fn(className, callback);
}

typedef void (*pt_dyld_for_each_objc_protocol_fn)(
    const char *protocolName,
    void (^callback)(void *protocolPtr, bool isLoaded, bool *stop));

static pt_dyld_for_each_objc_protocol_fn pt_resolve_dyld_for_each_objc_protocol(void) {
    static pt_dyld_for_each_objc_protocol_fn s_fn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_fn = (pt_dyld_for_each_objc_protocol_fn)dlsym(RTLD_NEXT, "_dyld_for_each_objc_protocol");
    });
    return s_fn;
}

static void pt_dyld_for_each_objc_protocol(
    const char *protocolName,
    void (^callback)(void *protocolPtr, bool isLoaded, bool *stop)) {
    pt_dyld_for_each_objc_protocol_fn fn = pt_resolve_dyld_for_each_objc_protocol();
    if (fn == NULL || callback == NULL) {
        return;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (protocolName != NULL && pt_is_hidden_objc_protocol_name(protocolName)) {
            return;
        }
        fn(protocolName, ^(void *protocolPtr, bool isLoaded, bool *stop) {
            const char *img = (protocolPtr != NULL) ? dyld_image_path_containing_address(protocolPtr) : NULL;
            if (img != NULL && pt_should_hide_dyld_image(img)) {
                return;
            }
            callback(protocolPtr, isLoaded, stop);
        });
        return;
    }
    fn(protocolName, callback);
}

extern void pt_orig_objc_enumerateClasses(
    const void *image,
    const char *namePrefix,
    Protocol *conformingTo,
    Class subclassing,
    void (^block)(Class aClass, BOOL *stop))
    __asm__("_objc_enumerateClasses") __attribute__((weak_import));


static void pt_objc_enumerateClasses(
    const void *image,
    const char *namePrefix,
    Protocol *conformingTo,
    Class subclassing,
    void (^block)(Class aClass, BOOL *stop)) {
    if (pt_orig_objc_enumerateClasses == NULL || block == NULL) {
        return;
    }
    const void *resolvedImage = image;
    if (image != NULL && image != (const void *)-1) {
        resolvedImage = (const void *)pt_uncloak_shadow_mach_header((const struct mach_header *)image);
    }
    const void *caller = __builtin_return_address(0);
    if (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
        if (pt_is_compat13_7_active()) {
            return;
        }
        if (resolvedImage != NULL && resolvedImage != (const void *)-1) {
            const struct mach_header *mh = (const struct mach_header *)resolvedImage;
            const char *imgName = pt_dyld_lookup_image_name_for_mh(mh);
            if (pt_is_hidden_dyld_image_header(mh) ||
                (imgName != NULL && pt_should_hide_dyld_image(imgName))) {
                return;
            }
        }
        if (conformingTo != nil) {
            const char *pname = protocol_getName(conformingTo);
            if (pname != NULL && pt_is_hidden_objc_protocol_name(pname)) {
                return;
            }
        }
        if (subclassing != Nil && pt_should_hide_resolved_objc_class(class_getName(subclassing), subclassing)) {
            return;
        }
        pt_orig_objc_enumerateClasses(resolvedImage, namePrefix, conformingTo, subclassing, ^(Class aClass, BOOL *stop) {
            if (aClass != Nil && pt_should_hide_resolved_objc_class(class_getName(aClass), aClass)) {
                return;
            }
            block(aClass, stop);
        });
        return;
    }
    pt_orig_objc_enumerateClasses(resolvedImage, namePrefix, conformingTo, subclassing, block);
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
            const void *cls = pt_orig_objc_lookUpClass(names[i]);
            if (cls != NULL && pt_should_hide_resolved_objc_class(names[i], (__bridge Class)cls)) {
                continue;
            }
        }
        names[writeIdx++] = names[i];
    }
    names[writeIdx] = NULL;
    return writeIdx;
}

static const char **pt_objc_copy_merged_class_names_for_path(const char *image, unsigned int *outCount) {
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
        return pt_objc_copy_merged_class_names_for_path(image, outCount);
    }
    return objc_copyClassNamesForImage(image, outCount);
}

extern const char **pt_orig_objc_copyClassNamesForImageHeader(const void *mh, unsigned int *outCount)
    __asm__("_objc_copyClassNamesForImageHeader") __attribute__((weak_import));

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
        const char *sanitized_img = (img_name != NULL && strncmp(img_name, "/System/iOSSupport/", 19) == 0)
            ? (img_name + 18)
            : img_name;
        if (pt_is_hidden_dyld_image_header(real_mh) ||
            (img_name != NULL && (pt_is_hidden_dyld_image_name(img_name) ||
                                  pt_is_post13_7_hidden_framework_path(img_name) ||
                                  pt_is_hidden_path(sanitized_img, caller)))) {
            if (outCount != NULL) {
                *outCount = 0;
            }
            return NULL;
        }
        if (img_name != NULL && strncmp(img_name, "/System/", 8) == 0) {
            unsigned int mergedCount = 0;
            const char **merged = pt_objc_copy_merged_class_names_for_path(img_name, &mergedCount);
            if (merged != NULL) {
                if (outCount != NULL) {
                    *outCount = mergedCount;
                }
                return merged;
            }
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
    if (pt_is_hidden_mtl_device_selector_name(sname, NO)) {
        return pt_class_is_mtl_device(cls);
    }
    if (strcmp(sname, "macCatalystVersionIsAtLeastVersion:") == 0) {
        return pt_class_is_or_inherits_from(cls, "NSProcessInfo") ||
               pt_class_is_or_inherits_from(cls, "_NSSwiftProcessInfo");
    }
    if (strcmp(sname, "titlebar") == 0) {
        return pt_class_is_or_inherits_from(cls, "UIWindowScene");
    }
    if (PT_HAS_PREFIX_LIT(sname, "pm_menu_") ||
        strcmp(sname, "toggleKeymapEditor:") == 0 ||
        strcmp(sname, "rotateView:") == 0) {
        return pt_class_is_or_inherits_from(cls, "UIApplication") ||
               pt_class_is_or_inherits_from(cls, "UIViewController");
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
        if (strcmp(sname, "sizeRestrictions") == 0) {
            return pt_class_is_or_inherits_from(cls, "UIWindowScene");
        }
        if (strcmp(sname, "activeAppearance") == 0 ||
            strcmp(sname, "toolbarItemPresentationSize") == 0) {
            return pt_class_is_or_inherits_from(cls, "UITraitCollection");
        }
        if (strcmp(sname, "accuracyAuthorization") == 0 ||
            strcmp(sname, "requestTemporaryFullAccuracyAuthorizationWithPurposeKey:completion:") == 0) {
            return pt_class_is_or_inherits_from(cls, "CLLocationManager");
        }
        if (pt_is_hidden_mtl_device_selector_name(sname, YES)) {
            return pt_class_is_mtl_device(cls);
        }
        if (strcmp(sname, "libraryType") == 0 ||
            strcmp(sname, "setLibraryType:") == 0 ||
            strcmp(sname, "preserveInvariance") == 0 ||
            strcmp(sname, "setPreserveInvariance:") == 0) {
            return pt_class_is_or_inherits_from(cls, "MTLCompileOptions");
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
    if (pt_is_hidden_mtl_device_property_name(pname, NO)) {
        return pt_class_is_mtl_device(cls);
    }
    if (strcmp(pname, "titlebar") == 0) {
        return pt_class_is_or_inherits_from(cls, "UIWindowScene");
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
    if (strcmp(pname, "sizeRestrictions") == 0) {
        return pt_class_is_or_inherits_from(cls, "UIWindowScene");
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
    if (pt_is_hidden_mtl_device_property_name(pname, YES)) {
        return pt_class_is_mtl_device(cls);
    }
    if (strcmp(pname, "libraryType") == 0 ||
        strcmp(pname, "preserveInvariance") == 0) {
        return pt_class_is_or_inherits_from(cls, "MTLCompileOptions");
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
    if (!pt_is_valid_user_pointer((__bridge const void *)cls)) {
        if (outCount != NULL) {
            *outCount = 0;
        }
        return NULL;
    }
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

static BOOL pt_is_hidden_short_library_name(const char *libraryName) {
    if (libraryName == NULL || libraryName[0] == '\0') {
        return NO;
    }
    if (pt_is_registered_hidden_module(libraryName) ||
        strstr(libraryName, "PlayTools") != NULL ||
        strstr(libraryName, "AKInterface") != NULL ||
        strstr(libraryName, "UserPlugins") != NULL ||
        PT_HAS_PREFIX_LIT(libraryName, "AGXMetal")) {
        return YES;
    }
    if (pt_is_compat13_7_active() &&
        (strcmp(libraryName, "swift_Concurrency") == 0 ||
         strcmp(libraryName, "libswift_Concurrency") == 0 ||
         strcmp(libraryName, "swift_StringProcessing") == 0 ||
         strcmp(libraryName, "libswift_StringProcessing") == 0)) {
        return YES;
    }
    char fwPath[256];
    int n = snprintf(fwPath, sizeof(fwPath), "/%s.framework/%s", libraryName, libraryName);
    if (n > 0 && (size_t)n < sizeof(fwPath)) {
        if (pt_is_macos_only_framework_path(fwPath) ||
            pt_is_post13_7_hidden_framework_path(fwPath)) {
            return YES;
        }
    }
    return NO;
}

static int32_t pt_NSVersionOfRunTimeLibrary(const char *libraryName) {
    BOOL appCaller = (libraryName != NULL &&
                      pt_is_bypass_enabled() &&
                      !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    if (appCaller && pt_is_hidden_short_library_name(libraryName)) {
        return -1;
    }
    int32_t orig = NSVersionOfRunTimeLibrary(libraryName);
    if (orig != -1 && appCaller && pt_is_compat13_7_active()) {
        int32_t spoofed = pt_compat13_library_version(libraryName);
        if (spoofed != -1) {
            return spoofed;
        }
    }
    return orig;
}

static int32_t pt_NSVersionOfLinkTimeLibrary(const char *libraryName) {
    BOOL appCaller = (libraryName != NULL &&
                      pt_is_bypass_enabled() &&
                      !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    if (appCaller && pt_is_hidden_short_library_name(libraryName)) {
        return -1;
    }
    int32_t orig = NSVersionOfLinkTimeLibrary(libraryName);
    if (orig != -1 && appCaller && pt_is_compat13_7_active()) {
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

__attribute__((visibility("hidden"))) const char *pt_dyld_lookup_image_name_for_mh(const struct mach_header *mh) {
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
    BOOL is_hidden = ((name != NULL && pt_should_hide_dyld_image(name)) || pt_is_hidden_dyld_image_header(mh));

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
    BOOL is_hidden = ((name != NULL && pt_should_hide_dyld_image(name)) || pt_is_hidden_dyld_image_header(mh));
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

__attribute__((visibility("hidden"))) void pt_ensure_dyld_master_callbacks(void) {
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
        if (path != NULL && pt_should_hide_dyld_image(path)) {
            const struct mach_header *fb_hdr = _dyld_get_image_header(pt_fallback_system_image_index());
            uintptr_t stripped_addr = (uintptr_t)pt_strip_code_ptr(addr);
            if (fb_hdr != NULL && (uintptr_t)fb_hdr > stripped_addr) {
                const struct mach_header *mh0 = _dyld_get_image_header(0);
                if (mh0 != NULL && (uintptr_t)mh0 <= stripped_addr) {
                    fb_hdr = mh0;
                }
            }
            return fb_hdr;
        }
    }
    return hdr;
}

static int pt_dladdr(const void *addr, Dl_info *info) {
    BOOL hide = (pt_is_bypass_enabled() &&
                 !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    const void *orig_addr = addr;
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
            } else if (addr != orig_addr &&
                       info->dli_saddr != NULL &&
                       pt_strip_code_ptr(info->dli_saddr) == pt_strip_code_ptr(addr)) {
                info->dli_saddr = (void *)pt_strip_code_ptr(orig_addr);
            }
        }
    }
    return ret;
}


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
    const void *caller = __builtin_return_address(0);
    if (pt_is_valid_user_pointer((const void *)aSelector) &&
        ps_should_hide_selector_for_target_class(object_getClass(self), aSelector, caller) &&
        s_nsobject_notFoundIMP != NULL) {
        return s_nsobject_notFoundIMP;
    }
    IMP imp = s_orig_nsobject_methodForSelector ? s_orig_nsobject_methodForSelector(self, _cmd, aSelector) : s_nsobject_notFoundIMP;
    if (imp != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        const void *orig = pt_lookup_swizzled_raw_orig_imp((const void *)imp);
        if (orig != NULL) {
            return (IMP)orig;
        }
    }
    return imp;
}

static IMP ps_hook_nsobject_instanceMethodForSelector(id self, SEL _cmd, SEL aSelector) {
    const void *caller = __builtin_return_address(0);
    if (pt_is_valid_user_pointer((const void *)aSelector) &&
        ps_should_hide_selector_for_target_class((Class)self, aSelector, caller) &&
        s_nsobject_notFoundIMP != NULL) {
        return s_nsobject_notFoundIMP;
    }
    IMP imp = s_orig_nsobject_instanceMethodForSelector ? s_orig_nsobject_instanceMethodForSelector(self, _cmd, aSelector) : s_nsobject_notFoundIMP;
    if (imp != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller)) {
        const void *orig = pt_lookup_swizzled_raw_orig_imp((const void *)imp);
        if (orig != NULL) {
            return (IMP)orig;
        }
    }
    return imp;
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

static void *pt_dlsym_resolve_for_each_objc_class(void) {
    return (pt_resolve_dyld_for_each_objc_class() != NULL) ? (void *)&pt_dyld_for_each_objc_class : NULL;
}

static void *pt_dlsym_resolve_for_each_objc_protocol(void) {
    return (pt_resolve_dyld_for_each_objc_protocol() != NULL) ? (void *)&pt_dyld_for_each_objc_protocol : NULL;
}


PT_DLSYM_DYNAMIC("_dyld_for_each_objc_class", pt_dlsym_resolve_for_each_objc_class)
PT_DLSYM_DYNAMIC("_dyld_for_each_objc_protocol", pt_dlsym_resolve_for_each_objc_protocol)

PT_INTERPOSE(pt_objc_getClass, objc_getClass)
PT_INTERPOSE(pt_objc_lookUpClass, objc_lookUpClass)
PT_INTERPOSE(pt_objc_getMetaClass, objc_getMetaClass)
PT_INTERPOSE(pt_objc_getRequiredClass, objc_getRequiredClass)
PT_INTERPOSE(pt_NSClassFromString, NSClassFromString)
PT_INTERPOSE_NAMED(pt_NSStringFromClass, pt_orig_NSStringFromClass, "NSStringFromClass")
PT_INTERPOSE_NAMED(pt_NSProtocolFromString, pt_orig_NSProtocolFromString, "NSProtocolFromString")
PT_INTERPOSE(pt_objc_copyImageNames, objc_copyImageNames)
PT_INTERPOSE(pt_class_getImageName, class_getImageName)
PT_INTERPOSE(pt_objc_copyClassNamesForImage, objc_copyClassNamesForImage)
PT_INTERPOSE_WEAK_NAMED(pt_objc_copyClassNamesForImageHeader, pt_orig_objc_copyClassNamesForImageHeader, "objc_copyClassNamesForImageHeader")
PT_INTERPOSE(pt_objc_copyClassList, objc_copyClassList)
PT_INTERPOSE(pt_objc_getClassList, objc_getClassList)
PT_INTERPOSE_WEAK_NAMED_FLAGS(pt_objc_enumerateClasses, pt_orig_objc_enumerateClasses, "objc_enumerateClasses", PT_DLSYM_FLAG_HIDE_IN_COMPAT13_7)
PT_INTERPOSE(pt_class_getInstanceMethod, class_getInstanceMethod)
PT_INTERPOSE(pt_class_getClassMethod, class_getClassMethod)
PT_INTERPOSE(pt_method_getImplementation, method_getImplementation)
PT_INTERPOSE(pt_class_getMethodImplementation, class_getMethodImplementation)
PT_INTERPOSE(pt_class_copyMethodList, class_copyMethodList)
PT_INTERPOSE(pt_class_respondsToSelector, class_respondsToSelector)
PT_INTERPOSE(pt_class_getProperty, class_getProperty)
PT_INTERPOSE(pt_class_copyPropertyList, class_copyPropertyList)
PT_INTERPOSE(pt_class_getName, class_getName)
PT_INTERPOSE(pt_object_getClassName, object_getClassName)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
PT_INTERPOSE(pt_NSVersionOfRunTimeLibrary, NSVersionOfRunTimeLibrary)
PT_INTERPOSE(pt_NSVersionOfLinkTimeLibrary, NSVersionOfLinkTimeLibrary)
#pragma clang diagnostic pop
PT_INTERPOSE(pt_objc_getProtocol, objc_getProtocol)
PT_INTERPOSE(pt_objc_copyProtocolList, objc_copyProtocolList)
PT_INTERPOSE(pt_class_copyProtocolList, class_copyProtocolList)
PT_INTERPOSE(pt_class_conformsToProtocol, class_conformsToProtocol)
PT_INTERPOSE(pt_protocol_conformsToProtocol, protocol_conformsToProtocol)
PT_INTERPOSE(pt_protocol_copyPropertyList, protocol_copyPropertyList)
PT_INTERPOSE(pt_protocol_copyMethodDescriptionList, protocol_copyMethodDescriptionList)
PT_INTERPOSE(pt_dyld_image_count, _dyld_image_count)
PT_INTERPOSE(pt_dyld_get_image_name, _dyld_get_image_name)
PT_INTERPOSE(pt_dyld_get_image_header, _dyld_get_image_header)
PT_INTERPOSE(pt_dyld_get_image_vmaddr_slide, _dyld_get_image_vmaddr_slide)
PT_INTERPOSE(pt_dyld_register_func_for_add_image, _dyld_register_func_for_add_image)
PT_INTERPOSE(pt_dyld_register_func_for_remove_image, _dyld_register_func_for_remove_image)
PT_INTERPOSE(pt_dyld_image_path_containing_address, dyld_image_path_containing_address)
PT_INTERPOSE(pt_dyld_image_header_containing_address, dyld_image_header_containing_address)
PT_INTERPOSE(pt_getsectiondata, getsectiondata)
PT_INTERPOSE(pt_getsegmentdata, getsegmentdata)
PT_INTERPOSE(pt_getsectdatafromheader_64, getsectdatafromheader_64)
PT_INTERPOSE(pt_dladdr, dladdr)
