//
//  PTMediaInputSpooferObjC.m
//  PlayTools
//

#import "PSInternal.h"
#import "PTDetectionRules.h"
#import "PTSystemSpooferInternal.h"
@import CoreGraphics;
@import CoreText;
@import JavaScriptCore;
#include <math.h>

static BOOL ps_is_hidden_desktop_font_name(NSString *name) {
    if (![name isKindOfClass:[NSString class]] || name.length == 0) {
        return NO;
    }
    NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return NO;
    }
    return pt_is_hidden_desktop_font_name_cstr([trimmed UTF8String]) ? YES : NO;
}

static NSArray<NSString *> *ps_filter_desktop_font_names(NSArray<NSString *> *names) {
    if (names == nil || names.count == 0) {
        return names;
    }
    NSMutableArray<NSString *> *filtered = nil;
    for (NSUInteger i = 0; i < names.count; i++) {
        NSString *entry = names[i];
        if (ps_is_hidden_desktop_font_name(entry)) {
            if (filtered == nil) {
                filtered = [NSMutableArray arrayWithCapacity:names.count - 1];
                for (NSUInteger j = 0; j < i; j++) {
                    [filtered addObject:names[j]];
                }
            }
        } else if (filtered != nil) {
            [filtered addObject:entry];
        }
    }
    return (filtered != nil) ? [filtered copy] : names;
}

static CFArrayRef ps_filter_desktop_font_cfarray(CFArrayRef CF_CONSUMED rawArray,
                                                 const void *caller) CF_RETURNS_RETAINED {
    if (rawArray == NULL ||
        !pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(caller)) {
        return rawArray;
    }
    CFArrayRef outArray = rawArray;
    @autoreleasepool {
        CFIndex count = CFArrayGetCount(rawArray);
        BOOL hasHidden = NO;
        for (CFIndex i = 0; i < count; i++) {
            CFTypeRef val = CFArrayGetValueAtIndex(rawArray, i);
            if (val != NULL && CFGetTypeID(val) == CFStringGetTypeID() &&
                ps_is_hidden_desktop_font_name((__bridge NSString *)val)) {
                hasHidden = YES;
                break;
            }
        }
        if (hasHidden) {
            CFMutableArrayRef filtered = CFArrayCreateMutable(kCFAllocatorDefault, count, &kCFTypeArrayCallBacks);
            if (filtered != NULL) {
                for (CFIndex i = 0; i < count; i++) {
                    CFTypeRef val = CFArrayGetValueAtIndex(rawArray, i);
                    if (val == NULL) {
                        continue;
                    }
                    if (CFGetTypeID(val) == CFStringGetTypeID() &&
                        ps_is_hidden_desktop_font_name((__bridge NSString *)val)) {
                        continue;
                    }
                    CFArrayAppendValue(filtered, val);
                }
                CFArrayRef copy = CFArrayCreateCopy(kCFAllocatorDefault, filtered);
                CFRelease(filtered);
                if (copy != NULL) {
                    CFRelease(rawArray);
                    outArray = copy;
                }
            }
        }
    }
    return outArray;
}

static CFStringRef ps_sanitize_ctfont_requested_name(CFStringRef name, const void *caller) {
    if (name != NULL &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(caller)) {
        @autoreleasepool {
            if (ps_is_hidden_desktop_font_name((__bridge NSString *)name)) {
                return CFSTR("Helvetica");
            }
        }
    }
    return name;
}

static CTFontRef pt_CTFontCreateWithName(CFStringRef name,
                                         CGFloat size,
                                         const CGAffineTransform * _Nullable matrix) CF_RETURNS_RETAINED {
    CFStringRef effectiveName = ps_sanitize_ctfont_requested_name(name, __builtin_return_address(0));
    return CTFontCreateWithName(effectiveName, size, matrix);
}

static CTFontRef pt_CTFontCreateWithNameAndOptions(CFStringRef name,
                                                   CGFloat size,
                                                   const CGAffineTransform * _Nullable matrix,
                                                   CTFontOptions options) CF_RETURNS_RETAINED {
    CFStringRef effectiveName = ps_sanitize_ctfont_requested_name(name, __builtin_return_address(0));
    return CTFontCreateWithNameAndOptions(effectiveName, size, matrix, options);
}

static CFArrayRef pt_CTFontManagerCopyAvailableFontFamilyNames(void) CF_RETURNS_RETAINED {
    return ps_filter_desktop_font_cfarray(CTFontManagerCopyAvailableFontFamilyNames(),
                                            __builtin_return_address(0));
}

static CFArrayRef pt_CTFontManagerCopyAvailablePostScriptNames(void) CF_RETURNS_RETAINED {
    return ps_filter_desktop_font_cfarray(CTFontManagerCopyAvailablePostScriptNames(),
                                            __builtin_return_address(0));
}

static BOOL ps_is_hidden_desktop_font_url(NSURL *url) {
    if (![url isKindOfClass:[NSURL class]]) {
        return NO;
    }
    NSString *path = url.path;
    if (path.length > 0 &&
        ([path hasPrefix:@"/Users/"] || [path hasPrefix:@"/Library/Fonts/"])) {
        return YES;
    }
    NSString *stem = url.URLByDeletingPathExtension.lastPathComponent;
    return ps_is_hidden_desktop_font_name(stem);
}

static BOOL ps_is_hidden_desktop_font_descriptor(CTFontDescriptorRef desc) {
    if (desc == NULL) {
        return NO;
    }
    BOOL hidden = NO;
    CFTypeRef fam = CTFontDescriptorCopyAttribute(desc, kCTFontFamilyNameAttribute);
    if (fam != NULL) {
        if (CFGetTypeID(fam) == CFStringGetTypeID() &&
            ps_is_hidden_desktop_font_name((__bridge NSString *)fam)) {
            hidden = YES;
        }
        CFRelease(fam);
    }
    if (!hidden) {
        CFTypeRef psName = CTFontDescriptorCopyAttribute(desc, kCTFontNameAttribute);
        if (psName != NULL) {
            if (CFGetTypeID(psName) == CFStringGetTypeID() &&
                ps_is_hidden_desktop_font_name((__bridge NSString *)psName)) {
                hidden = YES;
            }
            CFRelease(psName);
        }
    }
    if (!hidden) {
        CFTypeRef dispName = CTFontDescriptorCopyAttribute(desc, kCTFontDisplayNameAttribute);
        if (dispName != NULL) {
            if (CFGetTypeID(dispName) == CFStringGetTypeID() &&
                ps_is_hidden_desktop_font_name((__bridge NSString *)dispName)) {
                hidden = YES;
            }
            CFRelease(dispName);
        }
    }
    if (!hidden) {
        CFTypeRef fontURL = CTFontDescriptorCopyAttribute(desc, kCTFontURLAttribute);
        if (fontURL != NULL) {
            if (CFGetTypeID(fontURL) == CFURLGetTypeID() &&
                ps_is_hidden_desktop_font_url((__bridge NSURL *)fontURL)) {
                hidden = YES;
            }
            CFRelease(fontURL);
        }
    }
    return hidden;
}

static CFArrayRef ps_filter_desktop_font_descriptor_cfarray(CFArrayRef CF_CONSUMED rawArray,
                                                            const void *caller) CF_RETURNS_RETAINED {
    if (rawArray == NULL ||
        !pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(caller)) {
        return rawArray;
    }
    CFArrayRef outArray = rawArray;
    @autoreleasepool {
        CFIndex count = CFArrayGetCount(rawArray);
        CFTypeID descTypeID = CTFontDescriptorGetTypeID();
        BOOL hasHidden = NO;
        for (CFIndex i = 0; i < count; i++) {
            CFTypeRef val = CFArrayGetValueAtIndex(rawArray, i);
            if (val != NULL && CFGetTypeID(val) == descTypeID &&
                ps_is_hidden_desktop_font_descriptor((CTFontDescriptorRef)val)) {
                hasHidden = YES;
                break;
            }
        }
        if (hasHidden) {
            CFMutableArrayRef filtered = CFArrayCreateMutable(kCFAllocatorDefault, count, &kCFTypeArrayCallBacks);
            if (filtered != NULL) {
                for (CFIndex i = 0; i < count; i++) {
                    CFTypeRef val = CFArrayGetValueAtIndex(rawArray, i);
                    if (val == NULL) {
                        continue;
                    }
                    if (CFGetTypeID(val) == descTypeID &&
                        ps_is_hidden_desktop_font_descriptor((CTFontDescriptorRef)val)) {
                        continue;
                    }
                    CFArrayAppendValue(filtered, val);
                }
                CFArrayRef copy = CFArrayCreateCopy(kCFAllocatorDefault, filtered);
                CFRelease(filtered);
                if (copy != NULL) {
                    CFRelease(rawArray);
                    outArray = copy;
                }
            }
        }
    }
    return outArray;
}

static CFArrayRef _Nullable pt_CTFontCollectionCreateMatchingFontDescriptors(CTFontCollectionRef collection) CF_RETURNS_RETAINED {
    if (collection == NULL) {
        return NULL;
    }
    return ps_filter_desktop_font_descriptor_cfarray(
        CTFontCollectionCreateMatchingFontDescriptors(collection),
        __builtin_return_address(0));
}

static CFArrayRef _Nullable pt_CTFontCollectionCreateMatchingFontDescriptorsSortedWithCallback(
    CTFontCollectionRef collection,
    CTFontCollectionSortDescriptorsCallback _Nullable sortCallback,
    void * _Nullable refCon) CF_RETURNS_RETAINED {
    if (collection == NULL) {
        return NULL;
    }
    return ps_filter_desktop_font_descriptor_cfarray(
        CTFontCollectionCreateMatchingFontDescriptorsSortedWithCallback(collection, sortCallback, refCon),
        __builtin_return_address(0));
}

static CFArrayRef _Nullable pt_CTFontDescriptorCreateMatchingFontDescriptors(
    CTFontDescriptorRef descriptor,
    CFSetRef _Nullable mandatoryAttributes) CF_RETURNS_RETAINED {
    if (descriptor == NULL) {
        return NULL;
    }
    return ps_filter_desktop_font_descriptor_cfarray(
        CTFontDescriptorCreateMatchingFontDescriptors(descriptor, mandatoryAttributes),
        __builtin_return_address(0));
}

static CTFontDescriptorRef _Nullable pt_CTFontDescriptorCreateMatchingFontDescriptor(
    CTFontDescriptorRef descriptor,
    CFSetRef _Nullable mandatoryAttributes) CF_RETURNS_RETAINED {
    if (descriptor == NULL) {
        return NULL;
    }
    CTFontDescriptorRef res = CTFontDescriptorCreateMatchingFontDescriptor(descriptor, mandatoryAttributes);
    if (res != NULL &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        BOOL hide = NO;
        @autoreleasepool {
            hide = ps_is_hidden_desktop_font_descriptor(res);
        }
        if (hide) {
            CFRelease(res);
            return NULL;
        }
    }
    return res;
}

static CTFontDescriptorRef ps_sanitize_ctfont_descriptor(CTFontDescriptorRef descriptor,
                                                         CGFloat size,
                                                         const void *caller,
                                                         BOOL *outAllocated) {
    if (outAllocated != NULL) {
        *outAllocated = NO;
    }
    if (descriptor != NULL &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(caller)) {
        BOOL hide = NO;
        @autoreleasepool {
            hide = ps_is_hidden_desktop_font_descriptor(descriptor);
        }
        if (hide) {
            CTFontDescriptorRef fallback = CTFontDescriptorCreateWithNameAndSize(CFSTR("Helvetica"), size);
            if (fallback != NULL) {
                if (outAllocated != NULL) {
                    *outAllocated = YES;
                }
                return fallback;
            }
        }
    }
    return descriptor;
}

static CTFontRef pt_CTFontCreateWithFontDescriptor(
    CTFontDescriptorRef descriptor,
    CGFloat size,
    const CGAffineTransform * _Nullable matrix) CF_RETURNS_RETAINED {
    BOOL allocated = NO;
    CTFontDescriptorRef effectiveDesc = ps_sanitize_ctfont_descriptor(
        descriptor, size, __builtin_return_address(0), &allocated);
    CTFontRef font = CTFontCreateWithFontDescriptor(effectiveDesc, size, matrix);
    if (allocated && effectiveDesc != NULL) {
        CFRelease(effectiveDesc);
    }
    return font;
}

static CTFontRef pt_CTFontCreateWithFontDescriptorAndOptions(
    CTFontDescriptorRef descriptor,
    CGFloat size,
    const CGAffineTransform * _Nullable matrix,
    CTFontOptions options) CF_RETURNS_RETAINED {
    BOOL allocated = NO;
    CTFontDescriptorRef effectiveDesc = ps_sanitize_ctfont_descriptor(
        descriptor, size, __builtin_return_address(0), &allocated);
    CTFontRef font = CTFontCreateWithFontDescriptorAndOptions(effectiveDesc, size, matrix, options);
    if (allocated && effectiveDesc != NULL) {
        CFRelease(effectiveDesc);
    }
    return font;
}

static CGFontRef _Nullable pt_CGFontCreateWithFontName(CFStringRef _Nullable name) CF_RETURNS_RETAINED {
    if (name != NULL &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        BOOL hide = NO;
        @autoreleasepool {
            hide = ps_is_hidden_desktop_font_name((__bridge NSString *)name);
        }
        if (hide) {
            return NULL;
        }
    }
    return CGFontCreateWithFontName(name);
}

extern CFArrayRef _Nullable pt_orig_CTFontManagerCopyAvailableFontURLs(void)
    __asm("_CTFontManagerCopyAvailableFontURLs") __attribute__((weak_import)) CF_RETURNS_RETAINED;

static BOOL ps_is_hidden_desktop_ctfont(CTFontRef font) {
    if (font == NULL) {
        return NO;
    }
    BOOL hidden = NO;
    CFStringRef fam = CTFontCopyFamilyName(font);
    if (fam != NULL) {
        hidden = ps_is_hidden_desktop_font_name((__bridge NSString *)fam);
        CFRelease(fam);
    }
    if (!hidden) {
        CFStringRef psName = CTFontCopyPostScriptName(font);
        if (psName != NULL) {
            hidden = ps_is_hidden_desktop_font_name((__bridge NSString *)psName);
            CFRelease(psName);
        }
    }
    return hidden;
}

static CFArrayRef _Nullable pt_CTFontCollectionCreateMatchingFontDescriptorsWithOptions(
    CTFontCollectionRef collection,
    CFDictionaryRef _Nullable options) CF_RETURNS_RETAINED {
    if (collection == NULL) {
        return NULL;
    }
    return ps_filter_desktop_font_descriptor_cfarray(
        CTFontCollectionCreateMatchingFontDescriptorsWithOptions(collection, options),
        __builtin_return_address(0));
}

static CTFontRef _Nullable pt_CTFontCreateCopyWithAttributes(
    CTFontRef font,
    CGFloat size,
    const CGAffineTransform * _Nullable matrix,
    CTFontDescriptorRef _Nullable attributes) CF_RETURNS_RETAINED {
    if (font == NULL) {
        return NULL;
    }
    const void *caller = __builtin_return_address(0);
    BOOL bypass = pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller);
    CTFontRef baseFont = font;
    BOOL releasedBase = NO;
    if (bypass) {
        @autoreleasepool {
            if (ps_is_hidden_desktop_ctfont(font)) {
                CTFontRef fb = CTFontCreateWithName(CFSTR("Helvetica"), (size > 0.0) ? size : CTFontGetSize(font), matrix);
                if (fb != NULL) {
                    baseFont = fb;
                    releasedBase = YES;
                }
            }
        }
    }
    BOOL allocDesc = NO;
    CTFontDescriptorRef effAttr = bypass
        ? ps_sanitize_ctfont_descriptor(attributes, size, caller, &allocDesc)
        : attributes;
    CTFontRef res = CTFontCreateCopyWithAttributes(baseFont, size, matrix, effAttr);
    if (allocDesc && effAttr != NULL) {
        CFRelease(effAttr);
    }
    if (releasedBase && baseFont != NULL) {
        CFRelease(baseFont);
    }
    return res;
}

static CTFontRef _Nullable pt_CTFontCreateCopyWithSymbolicTraits(
    CTFontRef font,
    CGFloat size,
    const CGAffineTransform * _Nullable matrix,
    CTFontSymbolicTraits symTraitValue,
    CTFontSymbolicTraits symTraitMask) CF_RETURNS_RETAINED {
    if (font == NULL) {
        return NULL;
    }
    const void *caller = __builtin_return_address(0);
    CTFontRef baseFont = font;
    BOOL releasedBase = NO;
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        @autoreleasepool {
            if (ps_is_hidden_desktop_ctfont(font)) {
                CTFontRef fb = CTFontCreateWithName(CFSTR("Helvetica"), (size > 0.0) ? size : CTFontGetSize(font), matrix);
                if (fb != NULL) {
                    baseFont = fb;
                    releasedBase = YES;
                }
            }
        }
    }
    CTFontRef res = CTFontCreateCopyWithSymbolicTraits(baseFont, size, matrix, symTraitValue, symTraitMask);
    if (releasedBase && baseFont != NULL) {
        CFRelease(baseFont);
    }
    return res;
}

static CFArrayRef _Nullable pt_CTFontManagerCopyAvailableFontURLs(void) CF_RETURNS_RETAINED {
    if (&pt_orig_CTFontManagerCopyAvailableFontURLs == NULL) {
        return NULL;
    }
    CFArrayRef rawArray = pt_orig_CTFontManagerCopyAvailableFontURLs();
    if (rawArray == NULL ||
        !pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return rawArray;
    }
    CFArrayRef outArray = rawArray;
    @autoreleasepool {
        CFIndex count = CFArrayGetCount(rawArray);
        CFTypeID urlTypeID = CFURLGetTypeID();
        BOOL hasHidden = NO;
        for (CFIndex i = 0; i < count; i++) {
            CFTypeRef val = CFArrayGetValueAtIndex(rawArray, i);
            if (val != NULL && CFGetTypeID(val) == urlTypeID &&
                ps_is_hidden_desktop_font_url((__bridge NSURL *)val)) {
                hasHidden = YES;
                break;
            }
        }
        if (hasHidden) {
            CFMutableArrayRef filtered = CFArrayCreateMutable(kCFAllocatorDefault, count, &kCFTypeArrayCallBacks);
            if (filtered != NULL) {
                for (CFIndex i = 0; i < count; i++) {
                    CFTypeRef val = CFArrayGetValueAtIndex(rawArray, i);
                    if (val == NULL) {
                        continue;
                    }
                    if (CFGetTypeID(val) == urlTypeID &&
                        ps_is_hidden_desktop_font_url((__bridge NSURL *)val)) {
                        continue;
                    }
                    CFArrayAppendValue(filtered, val);
                }
                CFArrayRef copy = CFArrayCreateCopy(kCFAllocatorDefault, filtered);
                CFRelease(filtered);
                if (copy != NULL) {
                    CFRelease(rawArray);
                    outArray = copy;
                }
            }
        }
    }
    return outArray;
}

PT_INTERPOSE(pt_CTFontCreateWithName, CTFontCreateWithName)
PT_INTERPOSE(pt_CTFontCreateWithNameAndOptions, CTFontCreateWithNameAndOptions)
PT_INTERPOSE(pt_CTFontCreateWithFontDescriptor, CTFontCreateWithFontDescriptor)
PT_INTERPOSE(pt_CTFontCreateWithFontDescriptorAndOptions, CTFontCreateWithFontDescriptorAndOptions)
PT_INTERPOSE(pt_CGFontCreateWithFontName, CGFontCreateWithFontName)
PT_INTERPOSE_WEAK_NAMED(pt_CTFontManagerCopyAvailableFontURLs, pt_orig_CTFontManagerCopyAvailableFontURLs, "CTFontManagerCopyAvailableFontURLs")
PT_INTERPOSE(pt_CTFontManagerCopyAvailableFontFamilyNames, CTFontManagerCopyAvailableFontFamilyNames)
PT_INTERPOSE(pt_CTFontManagerCopyAvailablePostScriptNames, CTFontManagerCopyAvailablePostScriptNames)
PT_INTERPOSE(pt_CTFontCollectionCreateMatchingFontDescriptors, CTFontCollectionCreateMatchingFontDescriptors)
PT_INTERPOSE(pt_CTFontCollectionCreateMatchingFontDescriptorsWithOptions, CTFontCollectionCreateMatchingFontDescriptorsWithOptions)
PT_INTERPOSE(pt_CTFontCollectionCreateMatchingFontDescriptorsSortedWithCallback, CTFontCollectionCreateMatchingFontDescriptorsSortedWithCallback)
PT_INTERPOSE(pt_CTFontDescriptorCreateMatchingFontDescriptors, CTFontDescriptorCreateMatchingFontDescriptors)
PT_INTERPOSE(pt_CTFontDescriptorCreateMatchingFontDescriptor, CTFontDescriptorCreateMatchingFontDescriptor)
PT_INTERPOSE(pt_CTFontCreateCopyWithAttributes, CTFontCreateCopyWithAttributes)
PT_INTERPOSE(pt_CTFontCreateCopyWithSymbolicTraits, CTFontCreateCopyWithSymbolicTraits)

static void ps_sanitize_jsc_global_context_ref(JSGlobalContextRef ctx, const void *caller) {
    static _Thread_local BOOL s_tls_in_jsc_c_sanitize = NO;
    if (ctx == NULL || s_tls_in_jsc_c_sanitize ||
        !pt_is_bypass_enabled() ||
        !pt_is_compat13_7_active() ||
        ps_is_effective_system_or_playtools_caller(caller)) {
        return;
    }
    static const char kCleanupJS[] =
        "try{"
        "delete globalThis.WeakRef;"
        "delete globalThis.FinalizationRegistry;"
        "delete globalThis.BigInt;"
        "delete globalThis.BigInt64Array;"
        "delete globalThis.BigUint64Array;"
        "delete globalThis.AggregateError;"
        "delete globalThis.structuredClone;"
        "delete globalThis.Float16Array;"
        "delete globalThis.Iterator;"
        "if(typeof Promise==='function'){delete Promise.any;delete Promise.withResolvers;}"
        "if(typeof Object==='function'){delete Object.hasOwn;delete Object.groupBy;}"
        "if(typeof Map==='function'){delete Map.groupBy;}"
        "if(typeof RegExp==='function'){delete RegExp.escape;if(RegExp.prototype)delete RegExp.prototype.hasIndices;}"
        "if(typeof Error==='function'){delete Error.isError;}"
        "if(typeof Array==='function'){"
        "delete Array.fromAsync;"
        "if(Array.prototype){"
        "delete Array.prototype.at;"
        "delete Array.prototype.findLast;"
        "delete Array.prototype.findLastIndex;"
        "delete Array.prototype.toSorted;"
        "delete Array.prototype.toReversed;"
        "delete Array.prototype.toSpliced;"
        "delete Array.prototype.with;"
        "}"
        "}"
        "if(typeof Int8Array==='function'&&Int8Array.prototype){"
        "var _ta=Object.getPrototypeOf(Int8Array.prototype);"
        "if(_ta){"
        "delete _ta.at;"
        "delete _ta.findLast;"
        "delete _ta.findLastIndex;"
        "delete _ta.toReversed;"
        "delete _ta.toSorted;"
        "delete _ta.with;"
        "}"
        "}"
        "if(typeof Uint8Array==='function'){"
        "delete Uint8Array.fromBase64;"
        "delete Uint8Array.fromHex;"
        "if(Uint8Array.prototype){"
        "delete Uint8Array.prototype.toBase64;"
        "delete Uint8Array.prototype.toHex;"
        "}"
        "}"
        "if(typeof String==='function'&&String.prototype){"
        "delete String.prototype.at;"
        "delete String.prototype.isWellFormed;"
        "delete String.prototype.toWellFormed;"
        "}"
        "if(typeof Set==='function'&&Set.prototype){"
        "delete Set.prototype.union;"
        "delete Set.prototype.intersection;"
        "delete Set.prototype.difference;"
        "delete Set.prototype.symmetricDifference;"
        "delete Set.prototype.isSubsetOf;"
        "delete Set.prototype.isSupersetOf;"
        "delete Set.prototype.isDisjointFrom;"
        "}"
        "if(typeof Intl==='object'&&Intl){"
        "delete Intl.Segmenter;"
        "delete Intl.DisplayNames;"
        "delete Intl.ListFormat;"
        "delete Intl.DurationFormat;"
        "delete Intl.Locale;"
        "delete Intl.supportedValuesOf;"
        "if(typeof Intl.DateTimeFormat==='function'&&Intl.DateTimeFormat.prototype){"
        "delete Intl.DateTimeFormat.prototype.formatRange;"
        "delete Intl.DateTimeFormat.prototype.formatRangeToParts;"
        "}"
        "}"
        "if(typeof WebAssembly==='object'&&WebAssembly){"
        "delete WebAssembly.Exception;"
        "delete WebAssembly.Tag;"
        "}"
        "}catch(e){}";
    s_tls_in_jsc_c_sanitize = YES;
    JSStringRef jsStr = JSStringCreateWithUTF8CString(kCleanupJS);
    if (jsStr != NULL) {
        JSValueRef exc = NULL;
        (void)JSEvaluateScript(ctx, jsStr, NULL, NULL, 1, &exc);
        JSStringRelease(jsStr);
    }
    s_tls_in_jsc_c_sanitize = NO;
}

static JSGlobalContextRef pt_JSGlobalContextCreate(JSClassRef globalObjectClass) {
    JSGlobalContextRef ctx = JSGlobalContextCreate(globalObjectClass);
    if (ctx != NULL) {
        ps_sanitize_jsc_global_context_ref(ctx, __builtin_return_address(0));
    }
    return ctx;
}

static JSGlobalContextRef pt_JSGlobalContextCreateInGroup(JSContextGroupRef group, JSClassRef globalObjectClass) {
    JSGlobalContextRef ctx = JSGlobalContextCreateInGroup(group, globalObjectClass);
    if (ctx != NULL) {
        ps_sanitize_jsc_global_context_ref(ctx, __builtin_return_address(0));
    }
    return ctx;
}

PT_INTERPOSE(pt_JSGlobalContextCreate, JSGlobalContextCreate)
PT_INTERPOSE(pt_JSGlobalContextCreateInGroup, JSGlobalContextCreateInGroup)


@implementation PSSwizzleHooks (PlayShadowMediaInput)

static NSError *ps_make_devicecheck_unsupported_error(void) {
    NSString *domain = @"com.apple.devicecheck.error";
    NSString * __unsafe_unretained const *sym =
        (NSString * __unsafe_unretained const *)dlsym(RTLD_DEFAULT, "DCErrorDomain");
    if (sym != NULL && *sym != nil && [*sym isKindOfClass:[NSString class]]) {
        domain = *sym;
    }
    // DCErrorFeatureUnsupported == 1 in <DeviceCheck/DCError.h>
    return [NSError errorWithDomain:domain code:1 userInfo:nil];
}

- (BOOL) pm_ps_appAttest_isSupported {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NO;
    }
    return [self pm_ps_appAttest_isSupported];
}

- (void) pm_ps_appAttest_generateKeyWithCompletionHandler:(void (^)(NSString * _Nullable keyId, NSError * _Nullable error))completionHandler {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (completionHandler != nil) {
            NSError *err = ps_make_devicecheck_unsupported_error();
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                completionHandler(nil, err);
            });
        }
        return;
    }
    [self pm_ps_appAttest_generateKeyWithCompletionHandler:completionHandler];
}

- (void) pm_ps_appAttest_attestKey:(NSString *)keyId
                    clientDataHash:(NSData *)clientDataHash
                 completionHandler:(void (^)(NSData * _Nullable attestationObject, NSError * _Nullable error))completionHandler {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (completionHandler != nil) {
            NSError *err = ps_make_devicecheck_unsupported_error();
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                completionHandler(nil, err);
            });
        }
        return;
    }
    [self pm_ps_appAttest_attestKey:keyId clientDataHash:clientDataHash completionHandler:completionHandler];
}

- (void) pm_ps_appAttest_generateAssertion:(NSString *)keyId
                            clientDataHash:(NSData *)clientDataHash
                         completionHandler:(void (^)(NSData * _Nullable assertionObject, NSError * _Nullable error))completionHandler {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (completionHandler != nil) {
            NSError *err = ps_make_devicecheck_unsupported_error();
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                completionHandler(nil, err);
            });
        }
        return;
    }
    [self pm_ps_appAttest_generateAssertion:keyId clientDataHash:clientDataHash completionHandler:completionHandler];
}

- (BOOL) pm_ps_dcDevice_isSupported {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NO;
    }
    return [self pm_ps_dcDevice_isSupported];
}

- (void) pm_ps_dcDevice_generateTokenWithCompletionHandler:(void (^)(NSData * _Nullable data, NSError * _Nullable error))completion {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (completion != nil) {
            NSError *err = ps_make_devicecheck_unsupported_error();
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                completion(nil, err);
            });
        }
        return;
    }
    [self pm_ps_dcDevice_generateTokenWithCompletionHandler:completion];
}


static atomic_bool s_audio_port_name_swizzled = false;
static atomic_bool s_audio_port_uid_swizzled = false;

static NSString *ps_sanitize_audio_port_string(NSString *orig, NSString *portType, BOOL isUID) {
    if (orig.length == 0) {
        return orig;
    }
    NSString *devWord = pt_get_spoofed_device_is_ipad() ? @"iPad" : @"iPhone";
    if ([portType isEqualToString:@"Speaker"]) {
        if (isUID) {
            return @"Speaker";
        }
        if ([orig rangeOfString:@"扬声器"].location != NSNotFound) {
            return @"扬声器";
        }
        return @"Speaker";
    }
    if ([portType isEqualToString:@"MicrophoneBuiltIn"]) {
        if (isUID) {
            return @"Built-In Microphone";
        }
        if ([orig rangeOfString:@"麦克风"].location != NSNotFound) {
            return [NSString stringWithFormat:@"%@ 麦克风", devWord];
        }
        return [NSString stringWithFormat:@"%@ Microphone", devWord];
    }

    static NSArray<NSString *> *s_macModels = nil;
    static NSArray<NSString *> *s_macDisplays = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_macModels = @[@"MacBook Air", @"MacBook Pro", @"MacBook", @"Mac mini", @"Mac Studio", @"Mac Pro", @"iMac"];
        s_macDisplays = @[@"Studio Display", @"Pro Display XDR", @"Pro Display", @"Apple Display", @"LG UltraFine"];
    });

    NSString *res = orig;
    BOOL changed = NO;
    if ([res rangeOfString:@"BuiltInSpeakerDevice"].location != NSNotFound) {
        res = [res stringByReplacingOccurrencesOfString:@"BuiltInSpeakerDevice" withString:@"Speaker"];
        changed = YES;
    }
    if ([res rangeOfString:@"BuiltInMicrophoneDevice"].location != NSNotFound) {
        res = [res stringByReplacingOccurrencesOfString:@"BuiltInMicrophoneDevice" withString:@"Built-In Microphone"];
        changed = YES;
    }
    if ([res caseInsensitiveCompare:@"Built-in Output"] == NSOrderedSame) {
        return @"Speaker";
    }
    if ([res caseInsensitiveCompare:@"Built-in Input"] == NSOrderedSame ||
        [res caseInsensitiveCompare:@"Built-in Microphone"] == NSOrderedSame) {
        return isUID ? @"Built-In Microphone" : [NSString stringWithFormat:@"%@ Microphone", devWord];
    }
    if ([res rangeOfString:@"Built-in Output" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        res = [res stringByReplacingOccurrencesOfString:@"Built-in Output"
                                             withString:@"Speaker"
                                                options:NSCaseInsensitiveSearch
                                                  range:NSMakeRange(0, res.length)];
        changed = YES;
    }
    if ([res rangeOfString:@"Built-in Input" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        res = [res stringByReplacingOccurrencesOfString:@"Built-in Input"
                                             withString:[NSString stringWithFormat:@"%@ Microphone", devWord]
                                                options:NSCaseInsensitiveSearch
                                                  range:NSMakeRange(0, res.length)];
        changed = YES;
    }
    if ([res rangeOfString:@"Built-in Microphone" options:NSCaseInsensitiveSearch].location != NSNotFound && !isUID) {
        res = [res stringByReplacingOccurrencesOfString:@"Built-in Microphone"
                                             withString:[NSString stringWithFormat:@"%@ Microphone", devWord]
                                                options:NSCaseInsensitiveSearch
                                                  range:NSMakeRange(0, res.length)];
        changed = YES;
    }
    for (NSString *disp in s_macDisplays) {
        if ([res rangeOfString:disp options:NSCaseInsensitiveSearch].location != NSNotFound) {
            if ([res rangeOfString:@"Microphone" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [res rangeOfString:@"Mic" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                return isUID ? @"Built-In Microphone" : [NSString stringWithFormat:@"%@ Microphone", devWord];
            }
            if ([res rangeOfString:@"Speaker" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [res rangeOfString:@"Audio" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [res caseInsensitiveCompare:disp] == NSOrderedSame) {
                return @"Speaker";
            }
            res = [res stringByReplacingOccurrencesOfString:disp
                                                 withString:devWord
                                                    options:NSCaseInsensitiveSearch
                                                      range:NSMakeRange(0, res.length)];
            changed = YES;
        }
    }
    for (NSString *macModel in s_macModels) {
        if ([res rangeOfString:macModel options:NSCaseInsensitiveSearch].location != NSNotFound) {
            res = [res stringByReplacingOccurrencesOfString:macModel
                                                 withString:devWord
                                                    options:NSCaseInsensitiveSearch
                                                      range:NSMakeRange(0, res.length)];
            changed = YES;
        }
    }
    if (changed) {
        NSString *pluralSpeakers = [NSString stringWithFormat:@"%@ Speakers", devWord];
        if ([res caseInsensitiveCompare:pluralSpeakers] == NSOrderedSame) {
            return @"Speaker";
        }
        NSString *zhSpeakers = [NSString stringWithFormat:@"%@ 扬声器", devWord];
        NSString *compactSpeaker = [NSString stringWithFormat:@"%@扬声器", devWord];
        if ([res caseInsensitiveCompare:zhSpeakers] == NSOrderedSame ||
            [res caseInsensitiveCompare:compactSpeaker] == NSOrderedSame) {
            return @"扬声器";
        }
        if ([res rangeOfString:zhSpeakers].location != NSNotFound) {
            res = [res stringByReplacingOccurrencesOfString:zhSpeakers
                                                 withString:@"扬声器"];
        }
        if ([res rangeOfString:compactSpeaker].location != NSNotFound) {
            res = [res stringByReplacingOccurrencesOfString:compactSpeaker
                                                 withString:@"扬声器"];
        }
        NSString *compactMic = [NSString stringWithFormat:@"%@麦克风", devWord];
        if ([res rangeOfString:compactMic].location != NSNotFound) {
            res = [res stringByReplacingOccurrencesOfString:compactMic
                                                 withString:[NSString stringWithFormat:@"%@ 麦克风", devWord]];
        }
    }
    return res;
}

static NSString *ps_audio_port_type(id portDesc) {
    SEL ptSel = NSSelectorFromString(@"portType");
    if (portDesc != nil && [portDesc respondsToSelector:ptSel]) {
        return ((NSString *(*)(id, SEL))objc_msgSend)(portDesc, ptSel);
    }
    return nil;
}

static BOOL ps_av_string_is_virtual_desktop_audio(NSString *s);

static BOOL ps_audio_port_is_virtual_desktop(id port) {
    if (port == nil) {
        return NO;
    }
    NSString *rawName = nil;
    if (atomic_load_explicit(&s_audio_port_name_swizzled, memory_order_acquire) &&
        [port respondsToSelector:@selector(pm_ps_portName)]) {
        rawName = ((NSString *(*)(id, SEL))objc_msgSend)(port, @selector(pm_ps_portName));
    } else {
        SEL pnSel = NSSelectorFromString(@"portName");
        if ([port respondsToSelector:pnSel]) {
            rawName = ((NSString *(*)(id, SEL))objc_msgSend)(port, pnSel);
        }
    }
    if ([rawName isKindOfClass:[NSString class]] && ps_av_string_is_virtual_desktop_audio(rawName)) {
        return YES;
    }
    NSString *rawUID = nil;
    if (atomic_load_explicit(&s_audio_port_uid_swizzled, memory_order_acquire) &&
        [port respondsToSelector:@selector(pm_ps_UID)]) {
        rawUID = ((NSString *(*)(id, SEL))objc_msgSend)(port, @selector(pm_ps_UID));
    } else {
        SEL uidSel = NSSelectorFromString(@"UID");
        if ([port respondsToSelector:uidSel]) {
            rawUID = ((NSString *(*)(id, SEL))objc_msgSend)(port, uidSel);
        }
    }
    if ([rawUID isKindOfClass:[NSString class]] && ps_av_string_is_virtual_desktop_audio(rawUID)) {
        return YES;
    }
    return NO;
}

static NSArray *ps_filter_audio_ports_array(NSArray *ports, BOOL keepOneFallback) {
    if (![ports isKindOfClass:[NSArray class]] || ports.count == 0) {
        return ports;
    }
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:ports.count];
    for (id port in ports) {
        if (!ps_audio_port_is_virtual_desktop(port)) {
            [filtered addObject:port];
        }
    }
    if (keepOneFallback && filtered.count == 0 && ports.count > 0) {
        [filtered addObject:ports.firstObject];
    }
    return [filtered copy];
}

- (NSArray *) pm_ps_avsession_availableInputs {
    NSArray *orig = [self pm_ps_avsession_availableInputs];
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_filter_audio_ports_array(orig, NO);
    }
    return orig;
}

- (NSArray *) pm_ps_audio_route_inputs {
    NSArray *orig = [self pm_ps_audio_route_inputs];
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_filter_audio_ports_array(orig, NO);
    }
    return orig;
}

- (NSArray *) pm_ps_audio_route_outputs {
    NSArray *orig = [self pm_ps_audio_route_outputs];
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_filter_audio_ports_array(orig, YES);
    }
    return orig;
}

typedef struct {
    uint32_t componentType;
    uint32_t componentSubType;
    uint32_t componentManufacturer;
    uint32_t componentFlags;
    uint32_t componentFlagsMask;
} PSAudioComponentDescABI;

static NSArray *ps_filter_av_audio_unit_components(NSArray *components) {
    if (![components isKindOfClass:[NSArray class]] || components.count == 0) {
        return components;
    }
    SEL acSel = sel_registerName("audioComponent");
    NSMutableArray *filtered = nil;
    for (NSUInteger i = 0; i < components.count; i++) {
        id comp = components[i];
        BOOL hidden = NO;
        if (comp != nil && [comp respondsToSelector:acSel]) {
            struct OpaqueAudioComponent *ac =
                ((struct OpaqueAudioComponent *(*)(id, SEL))objc_msgSend)(comp, acSel);
            if (ac != NULL && pt_is_hidden_audio_component(ac)) {
                hidden = YES;
            }
        }
        if (hidden) {
            if (filtered == nil) {
                filtered = [NSMutableArray arrayWithCapacity:components.count - 1];
                for (NSUInteger j = 0; j < i; j++) {
                    [filtered addObject:components[j]];
                }
            }
        } else if (filtered != nil) {
            [filtered addObject:comp];
        }
    }
    return (filtered != nil) ? [filtered copy] : components;
}

- (NSArray *) pm_ps_avau_componentsMatchingDescription:(PSAudioComponentDescABI)description {
    NSArray *orig = [self pm_ps_avau_componentsMatchingDescription:description];
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_filter_av_audio_unit_components(orig);
    }
    return orig;
}

- (NSArray *) pm_ps_avau_componentsPassingTest:(BOOL (^)(id component, BOOL *stop))testHandler {
    const void *caller = __builtin_return_address(0);
    if (testHandler != nil &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(caller)) {
        BOOL (^userTest)(id, BOOL *) = [testHandler copy];
        SEL acSel = sel_registerName("audioComponent");
        return [self pm_ps_avau_componentsPassingTest:^BOOL(id component, BOOL *stop) {
            if (component != nil && [component respondsToSelector:acSel]) {
                struct OpaqueAudioComponent *ac =
                    ((struct OpaqueAudioComponent *(*)(id, SEL))objc_msgSend)(component, acSel);
                if (ac != NULL && pt_is_hidden_audio_component(ac)) {
                    return NO;
                }
            }
            return userTest(component, stop);
        }];
    }
    return [self pm_ps_avau_componentsPassingTest:testHandler];
}

- (NSString *) pm_ps_portName {
    const void *caller = __builtin_return_address(0);
    NSString *orig = [self pm_ps_portName];
    if (orig.length > 0 && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        return ps_sanitize_audio_port_string(orig, ps_audio_port_type(self), NO);
    }
    return orig;
}

- (NSString *) pm_ps_UID {
    const void *caller = __builtin_return_address(0);
    NSString *orig = [self pm_ps_UID];
    if (orig.length > 0 && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        return ps_sanitize_audio_port_string(orig, ps_audio_port_type(self), YES);
    }
    return orig;
}

- (NSString *) pm_ps_audio_port_description {
    const void *caller = __builtin_return_address(0);
    NSString *origDesc = [self pm_ps_audio_port_description];
    if (origDesc.length > 0 && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        NSString *portType = ps_audio_port_type(self);
        NSString *res = origDesc;
        if (atomic_load_explicit(&s_audio_port_name_swizzled, memory_order_acquire)) {
            NSString *realName = [self pm_ps_portName];
            NSString *sanitizedName = ps_sanitize_audio_port_string(realName, portType, NO);
            if (realName.length > 0 && sanitizedName.length > 0 && ![sanitizedName isEqualToString:realName]) {
                res = [res stringByReplacingOccurrencesOfString:realName withString:sanitizedName];
            }
        }
        if (atomic_load_explicit(&s_audio_port_uid_swizzled, memory_order_acquire)) {
            NSString *realUID = [self pm_ps_UID];
            NSString *sanitizedUID = ps_sanitize_audio_port_string(realUID, portType, YES);
            if (realUID.length > 0 && sanitizedUID.length > 0 && ![sanitizedUID isEqualToString:realUID]) {
                res = [res stringByReplacingOccurrencesOfString:realUID withString:sanitizedUID];
            }
        }
        res = ps_sanitize_audio_port_string(res, nil, NO);
        return res;
    }
    return origDesc;
}

static os_unfair_lock s_av_swizzle_lock = OS_UNFAIR_LOCK_INIT;
static CFMutableDictionaryRef s_av_orig_name_imps = NULL;
static CFMutableDictionaryRef s_av_orig_modelid_imps = NULL;
static CFMutableDictionaryRef s_av_orig_uniqueid_imps = NULL;
static CFMutableDictionaryRef s_av_orig_desc_imps = NULL;
static CFMutableDictionaryRef s_av_orig_fov_imps = NULL;
static CFMutableDictionaryRef s_av_orig_flash_imps = NULL;
static CFMutableDictionaryRef s_av_orig_torch_imps = NULL;
static CFMutableDictionaryRef s_av_orig_mfr_imps = NULL;
static CFMutableDictionaryRef s_av_orig_transport_imps = NULL;
static os_unfair_lock s_ch_swizzle_lock = OS_UNFAIR_LOCK_INIT;
static CFMutableDictionaryRef s_ch_orig_supports_haptics_imps = NULL;
static atomic_bool s_gc_app_bg_events = false;
static atomic_bool s_gc_app_bg_events_set = false;
static os_unfair_lock s_av_uid_map_lock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSString *> *ps_av_synth_uid_map(void) {
    static NSMutableDictionary<NSString *, NSString *> *s_map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_map = [[NSMutableDictionary alloc] initWithCapacity:16];
    });
    return s_map;
}

- (BOOL) pm_ps_av_hasFlash {
    SEL sel = sel_registerName("hasFlash");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_av_swizzle_lock, s_av_orig_flash_imps, self, &pushed);
    BOOL orig = NO;
    if (origIMP != NULL) {
        @try {
            orig = ((BOOL (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        SEL posSel = sel_registerName("position");
        if ([self respondsToSelector:posSel]) {
            NSInteger pos = ((NSInteger (*)(id, SEL))objc_msgSend)(self, posSel);
            if (pos == 2) {
                return NO;
            }
            if (pos == 1) {
                return YES;
            }
        }
    }
    return orig;
}

- (BOOL) pm_ps_av_hasTorch {
    SEL sel = sel_registerName("hasTorch");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_av_swizzle_lock, s_av_orig_torch_imps, self, &pushed);
    BOOL orig = NO;
    if (origIMP != NULL) {
        @try {
            orig = ((BOOL (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        SEL posSel = sel_registerName("position");
        if ([self respondsToSelector:posSel]) {
            NSInteger pos = ((NSInteger (*)(id, SEL))objc_msgSend)(self, posSel);
            if (pos == 2) {
                return NO;
            }
            if (pos == 1) {
                return YES;
            }
        }
    }
    return orig;
}

- (float) pm_ps_av_videoFieldOfView {
    SEL sel = sel_registerName("videoFieldOfView");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_av_swizzle_lock, s_av_orig_fov_imps, self, &pushed);
    float orig = 0.0f;
    if (origIMP != NULL) {
        @try {
            orig = ((float (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        (!isfinite(orig) || orig <= 0.0f)) {
        return 63.0f;
    }
    return orig;
}

static void ps_swizzle_capture_format_class(Class cls) {
    if (cls == Nil) {
        return;
    }
    SEL fovSel = sel_registerName("videoFieldOfView");
    if (class_getInstanceMethod(cls, fovSel) != NULL) {
        ps_swizzle_class_sel_storing_imp(&s_av_swizzle_lock, &s_av_orig_fov_imps, cls,
                                         fovSel, @selector(pm_ps_av_videoFieldOfView));
    }
}

static void ps_swizzle_capture_device_class(Class cls) {
    if (cls == Nil) {
        return;
    }
    ps_swizzle_class_sel_storing_imp(&s_av_swizzle_lock, &s_av_orig_name_imps, cls,
                                     sel_registerName("localizedName"), @selector(pm_ps_av_localizedName));
    ps_swizzle_class_sel_storing_imp(&s_av_swizzle_lock, &s_av_orig_modelid_imps, cls,
                                     sel_registerName("modelID"), @selector(pm_ps_av_modelID));
    if (class_getInstanceMethod(cls, sel_registerName("uniqueID")) != NULL) {
        ps_swizzle_class_sel_storing_imp(&s_av_swizzle_lock, &s_av_orig_uniqueid_imps, cls,
                                         sel_registerName("uniqueID"), @selector(pm_ps_av_uniqueID));
    }
    if (class_getInstanceMethod(cls, @selector(description)) != NULL) {
        ps_swizzle_class_sel_storing_imp(&s_av_swizzle_lock, &s_av_orig_desc_imps, cls,
                                         @selector(description), @selector(pm_ps_av_description));
    }
    if (class_getInstanceMethod(cls, sel_registerName("hasFlash")) != NULL) {
        ps_swizzle_class_sel_storing_imp(&s_av_swizzle_lock, &s_av_orig_flash_imps, cls,
                                         sel_registerName("hasFlash"), @selector(pm_ps_av_hasFlash));
    }
    if (class_getInstanceMethod(cls, sel_registerName("hasTorch")) != NULL) {
        ps_swizzle_class_sel_storing_imp(&s_av_swizzle_lock, &s_av_orig_torch_imps, cls,
                                         sel_registerName("hasTorch"), @selector(pm_ps_av_hasTorch));
    }
    if (class_getInstanceMethod(cls, sel_registerName("manufacturer")) != NULL) {
        ps_swizzle_class_sel_storing_imp(&s_av_swizzle_lock, &s_av_orig_mfr_imps, cls,
                                         sel_registerName("manufacturer"), @selector(pm_ps_av_manufacturer));
    }
    if (class_getInstanceMethod(cls, sel_registerName("transportType")) != NULL) {
        ps_swizzle_class_sel_storing_imp(&s_av_swizzle_lock, &s_av_orig_transport_imps, cls,
                                         sel_registerName("transportType"), @selector(pm_ps_av_transportType));
    }
}

static BOOL ps_av_string_is_virtual_desktop_audio(NSString *s) {
    if (s.length == 0) {
        return NO;
    }
    static NSArray<NSString *> *s_virtualAudioKeywords = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_virtualAudioKeywords = @[
            @"BlackHole",
            @"Loopback",
            @"ZoomAudioDevice",
            @"TeamsAudioDevice",
            @"Aggregate",
            @"CADefaultDeviceAggregate",
            @"Soundflower",
            @"VB-Cable",
            @"OBS Virtual",
            @"Krisp"
        ];
    });
    for (NSString *kw in s_virtualAudioKeywords) {
        if ([s rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static NSString *ps_av_raw_string_prop(id dev, CFMutableDictionaryRef dict, SEL sel) {
    if (dev == nil || sel == NULL) {
        return nil;
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_av_swizzle_lock, dict, dev, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((NSString *(*)(id, SEL))origIMP)(dev, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if ([dev respondsToSelector:sel]) {
        return ((NSString *(*)(id, SEL))objc_msgSend)(dev, sel);
    }
    return nil;
}

static BOOL ps_is_hidden_capture_device(id dev) {
    if (dev == nil) {
        return NO;
    }
    SEL dtSel = sel_registerName("deviceType");
    if ([dev respondsToSelector:dtSel]) {
        NSString *dt = ((NSString *(*)(id, SEL))objc_msgSend)(dev, dtSel);
        if ([dt isKindOfClass:[NSString class]]) {
            if ([dt containsString:@"Continuity"] ||
                [dt containsString:@"External"] ||
                [dt containsString:@"DeskView"]) {
                return YES;
            }
        }
    }
    NSString *name = ps_av_raw_string_prop(dev, s_av_orig_name_imps, sel_registerName("localizedName"));
    if ([name isKindOfClass:[NSString class]]) {
        if ([name containsString:@"Continuity"] ||
            [name containsString:@"Desk View"] ||
            ps_av_string_is_virtual_desktop_audio(name)) {
            return YES;
        }
    }
    NSString *modelID = ps_av_raw_string_prop(dev, s_av_orig_modelid_imps, sel_registerName("modelID"));
    if ([modelID isKindOfClass:[NSString class]] && ps_av_string_is_virtual_desktop_audio(modelID)) {
        return YES;
    }
    NSString *uid = ps_av_raw_string_prop(dev, s_av_orig_uniqueid_imps, sel_registerName("uniqueID"));
    if ([uid isKindOfClass:[NSString class]] && ps_av_string_is_virtual_desktop_audio(uid)) {
        return YES;
    }
    return NO;
}

static NSString *ps_sanitize_capture_device_string(id dev, NSString *orig, BOOL isModelID) {
    if (orig.length == 0) {
        return orig;
    }
    BOOL isCamera = NO;
    SEL hasMediaSel = sel_registerName("hasMediaType:");
    if ([dev respondsToSelector:hasMediaSel]) {
        isCamera = ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(dev, hasMediaSel, @"vide");
    }
    if (isCamera ||
        [orig rangeOfString:@"FaceTime" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [orig rangeOfString:@"Camera" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [orig rangeOfString:@"UVC" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        NSInteger pos = 0;
        SEL posSel = sel_registerName("position");
        if ([dev respondsToSelector:posSel]) {
            pos = ((NSInteger (*)(id, SEL))objc_msgSend)(dev, posSel);
        }
        if (pos == 1) {
            return isModelID
                ? @"com.apple.avfoundation.avcapturedevice.built-in_video:0"
                : @"Back Camera";
        }
        return isModelID
            ? @"com.apple.avfoundation.avcapturedevice.built-in_video:1"
            : @"Front Camera";
    }
    return ps_sanitize_audio_port_string(orig, nil, isModelID);
}

static NSString *ps_sanitize_capture_device_unique_id(id dev, NSString *orig) {
    if (orig.length == 0) {
        return orig;
    }
    NSString *sanitized = orig;
    BOOL isVideo = NO;
    BOOL isAudio = NO;
    SEL hasMediaSel = sel_registerName("hasMediaType:");
    if ([dev respondsToSelector:hasMediaSel]) {
        isVideo = ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(dev, hasMediaSel, @"vide");
        isAudio = ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(dev, hasMediaSel, @"soun");
    }
    if (isVideo) {
        NSInteger pos = 0;
        SEL posSel = sel_registerName("position");
        if ([dev respondsToSelector:posSel]) {
            pos = ((NSInteger (*)(id, SEL))objc_msgSend)(dev, posSel);
        }
        sanitized = (pos == 1)
            ? @"com.apple.avfoundation.avcapturedevice.built-in_video:0"
            : @"com.apple.avfoundation.avcapturedevice.built-in_video:1";
    } else if (isAudio || [orig rangeOfString:@"BuiltInMicrophoneDevice"].location != NSNotFound) {
        sanitized = @"com.apple.avfoundation.avcapturedevice.built-in_audio:0";
    } else {
        sanitized = ps_sanitize_capture_device_string(dev, orig, YES);
    }
    if (sanitized.length > 0 && ![sanitized isEqualToString:orig]) {
        NSMutableDictionary<NSString *, NSString *> *uidMap = ps_av_synth_uid_map();
        NSString *keyCopy = [sanitized copy];
        NSString *origCopy = [orig copy];
        os_unfair_lock_lock(&s_av_uid_map_lock);
        if (uidMap[keyCopy] == nil && uidMap.count < 64U) {
            uidMap[keyCopy] = origCopy;
        }
        os_unfair_lock_unlock(&s_av_uid_map_lock);
    }
    return sanitized;
}

static NSArray *ps_filter_capture_devices(NSArray *devices, BOOL isAppCaller) {
    if (devices == nil) {
        return nil;
    }
    NSMutableArray *filtered = isAppCaller ? [NSMutableArray arrayWithCapacity:devices.count] : nil;
    NSMutableDictionary<NSString *, NSNumber *> *seenCamIdx = isAppCaller ? [NSMutableDictionary dictionary] : nil;
    SEL dtSel = sel_registerName("deviceType");
    SEL posSel = sel_registerName("position");
    SEL hasMediaSel = sel_registerName("hasMediaType:");
    SEL hasFlashSel = sel_registerName("hasFlash");
    SEL activeFmtSel = sel_registerName("activeFormat");
    SEL fmtsSel = sel_registerName("formats");
    for (id dev in devices) {
        if (dev != nil) {
            ps_swizzle_capture_device_class(object_getClass(dev));
            if (isAppCaller) {
                if ([dev respondsToSelector:activeFmtSel]) {
                    id activeFmt = ((id (*)(id, SEL))objc_msgSend)(dev, activeFmtSel);
                    if (activeFmt != nil) {
                        ps_swizzle_capture_format_class(object_getClass(activeFmt));
                    }
                }
                if ([dev respondsToSelector:fmtsSel]) {
                    NSArray *fmts = ((NSArray *(*)(id, SEL))objc_msgSend)(dev, fmtsSel);
                    if ([fmts isKindOfClass:[NSArray class]] && fmts.count > 0 && fmts.firstObject != nil) {
                        ps_swizzle_capture_format_class(object_getClass(fmts.firstObject));
                    }
                }
            }
            if (isAppCaller && !ps_is_hidden_capture_device(dev)) {
                BOOL isVideo = [dev respondsToSelector:hasMediaSel]
                    ? ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(dev, hasMediaSel, @"vide")
                    : NO;
                if (isVideo && [dev respondsToSelector:dtSel] && [dev respondsToSelector:posSel]) {
                    NSString *dt = ((NSString *(*)(id, SEL))objc_msgSend)(dev, dtSel) ?: @"";
                    NSInteger pos = ((NSInteger (*)(id, SEL))objc_msgSend)(dev, posSel);
                    NSString *dedupKey = [NSString stringWithFormat:@"%@:%ld", dt, (long)pos];
                    NSNumber *existingIdx = seenCamIdx[dedupKey];
                    if (existingIdx != nil) {
                        if (pos == 1 && [dev respondsToSelector:hasFlashSel]) {
                            BOOL newHasFlash = NO;
                            BOOL pushed = NO;
                            IMP origFlashIMP = ps_lookup_orig_imp_and_push(&s_av_swizzle_lock, s_av_orig_flash_imps, dev, &pushed);
                            if (origFlashIMP != NULL) {
                                @try {
                                    newHasFlash = ((BOOL (*)(id, SEL))origFlashIMP)(dev, hasFlashSel);
                                } @finally {
                                    ps_pop_orig_imp_frame(pushed);
                                }
                            } else {
                                newHasFlash = ((BOOL (*)(id, SEL))objc_msgSend)(dev, hasFlashSel);
                            }
                            if (newHasFlash) {
                                NSUInteger idx = existingIdx.unsignedIntegerValue;
                                if (idx < filtered.count) {
                                    filtered[idx] = dev;
                                }
                            }
                        }
                        continue;
                    }
                    seenCamIdx[dedupKey] = @(filtered.count);
                }
                [filtered addObject:dev];
            }
        }
    }
    return isAppCaller ? [filtered copy] : devices;
}

- (NSString *) pm_ps_av_localizedName {
    SEL sel = sel_registerName("localizedName");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_av_swizzle_lock, s_av_orig_name_imps, self, &pushed);
    NSString *orig = nil;
    if (origIMP != NULL) {
        @try {
            orig = ((NSString *(*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (orig.length > 0 && pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_sanitize_capture_device_string(self, orig, NO);
    }
    return orig;
}

- (NSString *) pm_ps_av_modelID {
    SEL sel = sel_registerName("modelID");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_av_swizzle_lock, s_av_orig_modelid_imps, self, &pushed);
    NSString *orig = nil;
    if (origIMP != NULL) {
        @try {
            orig = ((NSString *(*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (orig.length > 0 && pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_sanitize_capture_device_string(self, orig, YES);
    }
    return orig;
}

- (NSString *) pm_ps_av_uniqueID {
    SEL sel = sel_registerName("uniqueID");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_av_swizzle_lock, s_av_orig_uniqueid_imps, self, &pushed);
    NSString *orig = nil;
    if (origIMP != NULL) {
        @try {
            orig = ((NSString *(*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (orig.length > 0 && pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_sanitize_capture_device_unique_id(self, orig);
    }
    return orig;
}

- (NSString *) pm_ps_av_manufacturer {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return @"Apple Inc.";
    }
    SEL sel = sel_registerName("manufacturer");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_av_swizzle_lock, s_av_orig_mfr_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((NSString *(*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return @"Apple Inc.";
}

- (int32_t) pm_ps_av_transportType {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return 0x626C746E; // 'bltn' (kIOAudioDeviceTransportTypeBuiltIn)
    }
    SEL sel = sel_registerName("transportType");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_av_swizzle_lock, s_av_orig_transport_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((int32_t (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return 0x626C746E;
}

- (NSString *) pm_ps_av_description {
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_av_swizzle_lock, s_av_orig_desc_imps, self, &pushed);
    NSString *orig = nil;
    if (origIMP != NULL) {
        @try {
            orig = ((NSString *(*)(id, SEL))origIMP)(self, @selector(description));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (orig.length > 0 && pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        NSString *res = orig;
        NSString *rawName = ps_av_raw_string_prop(self, s_av_orig_name_imps, sel_registerName("localizedName"));
        if (rawName.length > 0) {
            NSString *cleanName = ps_sanitize_capture_device_string(self, rawName, NO);
            if (cleanName.length > 0 && ![cleanName isEqualToString:rawName]) {
                res = [res stringByReplacingOccurrencesOfString:rawName withString:cleanName];
            }
        }
        NSString *rawModel = ps_av_raw_string_prop(self, s_av_orig_modelid_imps, sel_registerName("modelID"));
        if (rawModel.length > 0) {
            NSString *cleanModel = ps_sanitize_capture_device_string(self, rawModel, YES);
            if (cleanModel.length > 0 && ![cleanModel isEqualToString:rawModel]) {
                res = [res stringByReplacingOccurrencesOfString:rawModel withString:cleanModel];
            }
        }
        NSString *rawUID = ps_av_raw_string_prop(self, s_av_orig_uniqueid_imps, sel_registerName("uniqueID"));
        if (rawUID.length > 0) {
            NSString *cleanUID = ps_sanitize_capture_device_unique_id(self, rawUID);
            if (cleanUID.length > 0 && ![cleanUID isEqualToString:rawUID]) {
                res = [res stringByReplacingOccurrencesOfString:rawUID withString:cleanUID];
            }
        }
        return ps_sanitize_audio_port_string(res, nil, NO);
    }
    return orig;
}

+ (id) pm_ps_av_deviceWithUniqueID:(NSString *)deviceUniqueID {
    NSString *lookupID = deviceUniqueID;
    BOOL isAppCaller = pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0));
    if (isAppCaller && lookupID.length > 0) {
        NSMutableDictionary<NSString *, NSString *> *uidMap = ps_av_synth_uid_map();
        os_unfair_lock_lock(&s_av_uid_map_lock);
        NSString *mapped = uidMap[lookupID];
        os_unfair_lock_unlock(&s_av_uid_map_lock);
        if (mapped.length > 0) {
            lookupID = mapped;
        }
    }
    id dev = [self pm_ps_av_deviceWithUniqueID:lookupID];
    if (dev != nil) {
        ps_swizzle_capture_device_class(object_getClass(dev));
        if (isAppCaller && ps_is_hidden_capture_device(dev)) {
            return nil;
        }
    }
    return dev;
}

+ (NSArray *) pm_ps_av_devices {
    NSArray *devices = [self pm_ps_av_devices];
    BOOL isAppCaller = pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0));
    return ps_filter_capture_devices(devices, isAppCaller);
}

+ (NSArray *) pm_ps_av_devicesWithMediaType:(NSString *)mediaType {
    NSArray *devices = [self pm_ps_av_devicesWithMediaType:mediaType];
    BOOL isAppCaller = pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0));
    return ps_filter_capture_devices(devices, isAppCaller);
}

+ (id) pm_ps_av_defaultDeviceWithMediaType:(NSString *)mediaType {
    id dev = [self pm_ps_av_defaultDeviceWithMediaType:mediaType];
    if (dev != nil) {
        ps_swizzle_capture_device_class(object_getClass(dev));
        BOOL isAppCaller = pt_is_bypass_enabled() &&
            !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0));
        if (isAppCaller) {
            SEL activeFmtSel = sel_registerName("activeFormat");
            if ([dev respondsToSelector:activeFmtSel]) {
                id activeFmt = ((id (*)(id, SEL))objc_msgSend)(dev, activeFmtSel);
                if (activeFmt != nil) {
                    ps_swizzle_capture_format_class(object_getClass(activeFmt));
                }
            }
            if (ps_is_hidden_capture_device(dev)) {
                NSArray *fallback = ps_filter_capture_devices([self pm_ps_av_devicesWithMediaType:mediaType], YES);
                return fallback.firstObject;
            }
        }
    }
    return dev;
}

+ (id) pm_ps_av_defaultDeviceWithDeviceType:(NSString *)deviceType mediaType:(NSString *)mediaType position:(NSInteger)position {
    id dev = [self pm_ps_av_defaultDeviceWithDeviceType:deviceType mediaType:mediaType position:position];
    if (dev != nil) {
        ps_swizzle_capture_device_class(object_getClass(dev));
        BOOL isAppCaller = pt_is_bypass_enabled() &&
            !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0));
        if (isAppCaller) {
            SEL activeFmtSel = sel_registerName("activeFormat");
            if ([dev respondsToSelector:activeFmtSel]) {
                id activeFmt = ((id (*)(id, SEL))objc_msgSend)(dev, activeFmtSel);
                if (activeFmt != nil) {
                    ps_swizzle_capture_format_class(object_getClass(activeFmt));
                }
            }
            if (ps_is_hidden_capture_device(dev)) {
                return nil;
            }
        }
    }
    return dev;
}

- (NSArray *) pm_ps_av_session_devices {
    NSArray *devices = [self pm_ps_av_session_devices];
    BOOL isAppCaller = pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0));
    return ps_filter_capture_devices(devices, isAppCaller);
}


static const char kPSLAContextEvaluatedKey = 0;

static BOOL ps_is_reported_ios_13_or_older(void) {
    if (pt_is_compat13_7_active()) {
        return YES;
    }
    NSOperatingSystemVersion ver = {0, 0, 0};
    if (ps_get_cached_ios_sysver(&ver, NULL) && ver.majorVersion > 0 && ver.majorVersion <= 13) {
        return YES;
    }
    return NO;
}

static BOOL ps_is_faceid_device_model(void) {
    const char *m = pt_get_device_model_cstr();
    if (m == NULL || m[0] == '\0') {
        return NO;
    }
    // Exclude Touch ID iPhone SE and iPad mini (A17 Pro) models before matching iPhone12+/14+/iPad16+ prefixes
    if (strcmp(m, "iPhone12,8") == 0 || strcmp(m, "iPhone14,6") == 0 ||
        strcmp(m, "iPad16,1") == 0 || strcmp(m, "iPad16,2") == 0) {
        return NO;
    }
    if (strncmp(m, "iPad8,", 6) == 0 ||
        strncmp(m, "iPad16,", 7) == 0 ||
        strncmp(m, "iPad17,", 7) == 0 ||
        strcmp(m, "iPhone10,3") == 0 ||
        strcmp(m, "iPhone10,6") == 0 ||
        strncmp(m, "iPhone11,", 9) == 0 ||
        strncmp(m, "iPhone12,", 9) == 0 ||
        strncmp(m, "iPhone13,", 9) == 0 ||
        strncmp(m, "iPhone14,", 9) == 0 ||
        strncmp(m, "iPhone15,", 9) == 0 ||
        strncmp(m, "iPhone16,", 9) == 0 ||
        strncmp(m, "iPhone17,", 9) == 0 ||
        strncmp(m, "iPhone18,", 9) == 0) {
        return YES;
    }
    static const char * const kExtraFaceIDModels[] = {
        "iPad13,4", "iPad13,5", "iPad13,6", "iPad13,7",
        "iPad13,8", "iPad13,9", "iPad13,10", "iPad13,11",
        "iPad14,3", "iPad14,4", "iPad14,5", "iPad14,6"
    };
    for (size_t i = 0; i < sizeof(kExtraFaceIDModels) / sizeof(kExtraFaceIDModels[0]); i++) {
        if (strcmp(m, kExtraFaceIDModels[i]) == 0) {
            return YES;
        }
    }
    return NO;
}


+ (UIFont *) pm_ps_uifont_fontWithName:(NSString *)fontName size:(CGFloat)fontSize {
    const void *caller = __builtin_return_address(0);
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(caller) &&
        ps_is_hidden_desktop_font_name(fontName)) {
        return nil;
    }
    return [self pm_ps_uifont_fontWithName:fontName size:fontSize];
}

+ (UIFont *) pm_ps_uifont_fontWithDescriptor:(UIFontDescriptor *)descriptor size:(CGFloat)pointSize {
    const void *caller = __builtin_return_address(0);
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(caller) &&
        descriptor != nil &&
        ps_is_hidden_desktop_font_descriptor((__bridge CTFontDescriptorRef)descriptor)) {
        CGFloat effSize = (pointSize > 0.0) ? pointSize : 12.0;
        UIFontDescriptor *fallbackDesc = [UIFontDescriptor fontDescriptorWithName:@"Helvetica" size:effSize];
        if (fallbackDesc != nil) {
            return [self pm_ps_uifont_fontWithDescriptor:fallbackDesc size:pointSize];
        }
    }
    return [self pm_ps_uifont_fontWithDescriptor:descriptor size:pointSize];
}

static NSArray<UIFontDescriptor *> *ps_filter_matching_uifont_descriptors(NSArray *orig, const void *caller) {
    if (orig.count == 0 ||
        !pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(caller)) {
        return orig;
    }
    NSMutableArray *filtered = nil;
    for (NSUInteger i = 0; i < orig.count; i++) {
        id entry = orig[i];
        BOOL hidden = (entry != nil &&
                       ps_is_hidden_desktop_font_descriptor((__bridge CTFontDescriptorRef)entry));
        if (hidden) {
            if (filtered == nil) {
                filtered = [NSMutableArray arrayWithCapacity:orig.count - 1];
                for (NSUInteger j = 0; j < i; j++) {
                    [filtered addObject:orig[j]];
                }
            }
        } else if (filtered != nil) {
            [filtered addObject:entry];
        }
    }
    return (filtered != nil) ? [filtered copy] : orig;
}

- (NSArray<UIFontDescriptor *> *) pm_ps_uifontdesc_matchingFontDescriptorsWithMandatoryKeys:(NSSet *)mandatoryKeys {
    NSArray *orig = [self pm_ps_uifontdesc_matchingFontDescriptorsWithMandatoryKeys:mandatoryKeys];
    return ps_filter_matching_uifont_descriptors(orig, __builtin_return_address(0));
}

- (NSArray<UIFontDescriptor *> *) pm_ps_ctfontdesc_matchingFontDescriptorsWithMandatoryKeys:(NSSet *)mandatoryKeys {
    NSArray *orig = [self pm_ps_ctfontdesc_matchingFontDescriptorsWithMandatoryKeys:mandatoryKeys];
    return ps_filter_matching_uifont_descriptors(orig, __builtin_return_address(0));
}

- (NSArray<UIFontDescriptor *> *) pm_ps_uictfontdesc_matchingFontDescriptorsWithMandatoryKeys:(NSSet *)mandatoryKeys {
    NSArray *orig = [self pm_ps_uictfontdesc_matchingFontDescriptorsWithMandatoryKeys:mandatoryKeys];
    return ps_filter_matching_uifont_descriptors(orig, __builtin_return_address(0));
}

- (BOOL) pm_ps_ch_supportsHaptics {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ps_is_iphone_device_model();
    }
    SEL sel = sel_registerName("supportsHaptics");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_ch_swizzle_lock, s_ch_orig_supports_haptics_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((BOOL (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return NO;
}

+ (id) pm_ps_ch_capabilitiesForHardware {
    id cap = [self pm_ps_ch_capabilitiesForHardware];
    if (cap != nil) {
        SEL shSel = sel_registerName("supportsHaptics");
        Class cls = object_getClass(cap);
        if (cls != Nil && class_getInstanceMethod(cls, shSel) != NULL) {
            ps_swizzle_class_sel_storing_imp(&s_ch_swizzle_lock,
                                             &s_ch_orig_supports_haptics_imps,
                                             cls,
                                             shSel,
                                             @selector(pm_ps_ch_supportsHaptics));
        }
    }
    return cap;
}

- (BOOL) pm_ps_ch_startAndReturnError:(NSError **)error {
    BOOL ok = [self pm_ps_ch_startAndReturnError:error];
    if (!ok &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        ps_is_iphone_device_model()) {
        if (error != NULL) {
            *error = nil;
        }
        return YES;
    }
    return ok;
}

- (void) pm_ps_ch_startWithCompletionHandler:(void (^)(NSError *error))completionHandler {
    BOOL isAppCaller = pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        ps_is_iphone_device_model();
    if (isAppCaller && completionHandler != nil) {
        void (^userHandler)(NSError *) = [completionHandler copy];
        [self pm_ps_ch_startWithCompletionHandler:^(NSError *error) {
            (void)error;
            userHandler(nil);
        }];
        return;
    }
    [self pm_ps_ch_startWithCompletionHandler:completionHandler];
}

static NSError *ps_la_watch_unavailable_error(void) {
    return [NSError errorWithDomain:@"com.apple.LocalAuthentication"
                               code:-11
                           userInfo:@{ NSLocalizedDescriptionKey : @"Apple Watch authentication is not available." }];
}

- (BOOL) pm_ps_la_canEvaluatePolicy:(NSInteger)policy error:(NSError **)error {
    const void *caller = __builtin_return_address(0);
    BOOL isAppCaller = pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller);
    if (isAppCaller && policy >= 3) {
        if (error != NULL) {
            *error = ps_la_watch_unavailable_error();
        }
        return NO;
    }
    BOOL ok = [self pm_ps_la_canEvaluatePolicy:policy error:error];
    objc_setAssociatedObject(self,
                             &kPSLAContextEvaluatedKey,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!ok && isAppCaller && (policy == 1 || policy == 2) &&
        error != NULL && *error != nil &&
        [(*error).domain isEqualToString:@"com.apple.LocalAuthentication"] &&
        (*error).code == -6) {
        *error = [NSError errorWithDomain:@"com.apple.LocalAuthentication"
                                     code:-7
                                 userInfo:@{ NSLocalizedDescriptionKey : @"No identities are enrolled." }];
    }
    return ok;
}

- (void) pm_ps_la_evaluatePolicy:(NSInteger)policy
                 localizedReason:(NSString *)localizedReason
                           reply:(void (^)(BOOL success, NSError *error))reply {
    const void *caller = __builtin_return_address(0);
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(caller) &&
        policy >= 3) {
        if (reply != nil) {
            reply(NO, ps_la_watch_unavailable_error());
        }
        return;
    }
    objc_setAssociatedObject(self,
                             &kPSLAContextEvaluatedKey,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self pm_ps_la_evaluatePolicy:policy localizedReason:localizedReason reply:reply];
}

- (NSInteger) pm_ps_la_biometryType {
    NSInteger orig = [self pm_ps_la_biometryType];
    const void *caller = __builtin_return_address(0);
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(caller)) {
        if (orig == 4) {
            return 0;
        }
        if (orig == 0) {
            NSNumber *eval = objc_getAssociatedObject(self, &kPSLAContextEvaluatedKey);
            if ([eval boolValue]) {
                return ps_is_faceid_device_model() ? 2 : 1;
            }
            return 0;
        }
        if (ps_is_faceid_device_model() && orig == 1) {
            NSNumber *eval = objc_getAssociatedObject(self, &kPSLAContextEvaluatedKey);
            return [eval boolValue] ? 2 : 0;
        }
    }
    return orig;
}

- (NSInteger) pm_ps_la_domain_biometryType {
    NSInteger orig = [self pm_ps_la_domain_biometryType];
    const void *caller = __builtin_return_address(0);
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(caller)) {
        if (orig == 4) {
            return 0;
        }
        if (orig == 0) {
            return ps_is_faceid_device_model() ? 2 : 1;
        }
        if (ps_is_faceid_device_model() && orig == 1) {
            return 2;
        }
    }
    return orig;
}

+ (void) pm_ps_gc_setShouldMonitorBackgroundEvents:(BOOL)shouldMonitor {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_is_compat13_7_active()) {
            return;
        }
        atomic_store_explicit(&s_gc_app_bg_events, shouldMonitor ? true : false, memory_order_release);
        atomic_store_explicit(&s_gc_app_bg_events_set, true, memory_order_release);
    }
    [self pm_ps_gc_setShouldMonitorBackgroundEvents:shouldMonitor];
}

+ (BOOL) pm_ps_gc_shouldMonitorBackgroundEvents {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (pt_is_compat13_7_active()) {
            return NO;
        }
        return atomic_load_explicit(&s_gc_app_bg_events_set, memory_order_acquire)
            ? (atomic_load_explicit(&s_gc_app_bg_events, memory_order_acquire) ? YES : NO)
            : NO;
    }
    return [self pm_ps_gc_shouldMonitorBackgroundEvents];
}

+ (BOOL) pm_ps_gc_respondsToSelector:(SEL)aSelector {
    const void *caller = __builtin_return_address(0);
    if (aSelector != NULL &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(caller)) {
        if (pt_is_hidden_objc_selector_name(sel_getName(aSelector))) {
            return NO;
        }
        if ((aSelector == NSSelectorFromString(@"shouldMonitorBackgroundEvents") ||
             aSelector == NSSelectorFromString(@"setShouldMonitorBackgroundEvents:")) &&
            ps_is_reported_ios_13_or_older()) {
            return NO;
        }
    }
    return [self pm_ps_gc_respondsToSelector:aSelector];
}

+ (NSArray *) pm_ps_gc_mice {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return @[];
    }
    return [self pm_ps_gc_mice];
}

+ (id) pm_ps_gc_currentMouse {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return nil;
    }
    return [self pm_ps_gc_currentMouse];
}

+ (id) pm_ps_gc_coalescedKeyboard {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return nil;
    }
    return [self pm_ps_gc_coalescedKeyboard];
}

static void ps_sanitize_jscontext_for_compat13(id ctx, const void *caller) {
    static _Thread_local BOOL s_tls_in_jsc_sanitize = NO;
    if (ctx == nil || s_tls_in_jsc_sanitize ||
        !pt_is_bypass_enabled() ||
        !pt_is_compat13_7_active() ||
        ps_is_effective_system_or_playtools_caller(caller)) {
        return;
    }
    SEL evalSel = sel_registerName("evaluateScript:");
    if (![ctx respondsToSelector:evalSel]) {
        return;
    }
    s_tls_in_jsc_sanitize = YES;
    @try {
        NSString *cleanupJS =
            @"try{"
             "delete globalThis.WeakRef;"
             "delete globalThis.FinalizationRegistry;"
             "delete globalThis.BigInt;"
             "delete globalThis.BigInt64Array;"
             "delete globalThis.BigUint64Array;"
             "delete globalThis.AggregateError;"
             "delete globalThis.structuredClone;"
             "delete globalThis.Float16Array;"
             "delete globalThis.Iterator;"
             "if(typeof Promise==='function'){delete Promise.any;delete Promise.withResolvers;}"
             "if(typeof Object==='function'){delete Object.hasOwn;delete Object.groupBy;}"
             "if(typeof Map==='function'){delete Map.groupBy;}"
             "if(typeof RegExp==='function'){delete RegExp.escape;if(RegExp.prototype)delete RegExp.prototype.hasIndices;}"
             "if(typeof Error==='function'){delete Error.isError;}"
             "if(typeof Array==='function'){"
             "delete Array.fromAsync;"
             "if(Array.prototype){"
             "delete Array.prototype.at;"
             "delete Array.prototype.findLast;"
             "delete Array.prototype.findLastIndex;"
             "delete Array.prototype.toSorted;"
             "delete Array.prototype.toReversed;"
             "delete Array.prototype.toSpliced;"
             "delete Array.prototype.with;"
             "}"
             "}"
             "if(typeof Int8Array==='function'&&Int8Array.prototype){"
             "var _ta=Object.getPrototypeOf(Int8Array.prototype);"
             "if(_ta){"
             "delete _ta.at;"
             "delete _ta.findLast;"
             "delete _ta.findLastIndex;"
             "delete _ta.toReversed;"
             "delete _ta.toSorted;"
             "delete _ta.with;"
             "}"
             "}"
             "if(typeof Uint8Array==='function'){"
             "delete Uint8Array.fromBase64;"
             "delete Uint8Array.fromHex;"
             "if(Uint8Array.prototype){"
             "delete Uint8Array.prototype.toBase64;"
             "delete Uint8Array.prototype.toHex;"
             "}"
             "}"
             "if(typeof String==='function'&&String.prototype){"
             "delete String.prototype.at;"
             "delete String.prototype.isWellFormed;"
             "delete String.prototype.toWellFormed;"
             "}"
             "if(typeof Set==='function'&&Set.prototype){"
             "delete Set.prototype.union;"
             "delete Set.prototype.intersection;"
             "delete Set.prototype.difference;"
             "delete Set.prototype.symmetricDifference;"
             "delete Set.prototype.isSubsetOf;"
             "delete Set.prototype.isSupersetOf;"
             "delete Set.prototype.isDisjointFrom;"
             "}"
             "if(typeof Intl==='object'&&Intl){"
             "delete Intl.Segmenter;"
             "delete Intl.DisplayNames;"
             "delete Intl.ListFormat;"
             "delete Intl.DurationFormat;"
             "delete Intl.Locale;"
             "delete Intl.supportedValuesOf;"
             "if(typeof Intl.DateTimeFormat==='function'&&Intl.DateTimeFormat.prototype){"
             "delete Intl.DateTimeFormat.prototype.formatRange;"
             "delete Intl.DateTimeFormat.prototype.formatRangeToParts;"
             "}"
             "}"
             "if(typeof WebAssembly==='object'&&WebAssembly){"
             "delete WebAssembly.Exception;"
             "delete WebAssembly.Tag;"
             "}"
             "}catch(e){}";
        (void)((id (*)(id, SEL, NSString *))objc_msgSend)(ctx, evalSel, cleanupJS);
        SEL setExcSel = sel_registerName("setException:");
        if ([ctx respondsToSelector:setExcSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(ctx, setExcSel, nil);
        }
    } @catch (NSException *ignored) {
        (void)ignored;
    }
    s_tls_in_jsc_sanitize = NO;
}

- (instancetype) pm_ps_jsc_init {
    const void *caller = __builtin_return_address(0);
    self = [self pm_ps_jsc_init];
    if (self != nil) {
        ps_sanitize_jscontext_for_compat13(self, caller);
    }
    return self;
}

- (instancetype) pm_ps_jsc_initWithVirtualMachine:(id)virtualMachine {
    const void *caller = __builtin_return_address(0);
    self = [self pm_ps_jsc_initWithVirtualMachine:virtualMachine];
    if (self != nil) {
        ps_sanitize_jscontext_for_compat13(self, caller);
    }
    return self;
}

+ (id) pm_ps_jsc_contextWithJSGlobalContextRef:(void *)jsGlobalContextRef {
    const void *caller = __builtin_return_address(0);
    id ctx = [self pm_ps_jsc_contextWithJSGlobalContextRef:jsGlobalContextRef];
    if (ctx != nil) {
        ps_sanitize_jscontext_for_compat13(ctx, caller);
    }
    return ctx;
}

static BOOL ps_is_post13_7_sf_symbol_name(NSString *name) {
    if (name == nil || name.length == 0) {
        return NO;
    }
    return pt_is_post13_7_sf_symbol_name_cstr([name UTF8String]) ? YES : NO;
}

+ (UIImage *) pm_ps_uiimage_systemImageNamed:(NSString *)name {
    if (pt_is_bypass_enabled() &&
        pt_is_compat13_7_active() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        ps_is_post13_7_sf_symbol_name(name)) {
        return nil;
    }
    return [self pm_ps_uiimage_systemImageNamed:name];
}

+ (UIImage *) pm_ps_uiimage_systemImageNamed:(NSString *)name withConfiguration:(UIImageConfiguration *)configuration {
    if (pt_is_bypass_enabled() &&
        pt_is_compat13_7_active() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        ps_is_post13_7_sf_symbol_name(name)) {
        return nil;
    }
    return [self pm_ps_uiimage_systemImageNamed:name withConfiguration:configuration];
}

+ (UIImage *) pm_ps_uiimage_systemImageNamed:(NSString *)name compatibleWithTraitCollection:(UITraitCollection *)traitCollection {
    if (pt_is_bypass_enabled() &&
        pt_is_compat13_7_active() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        ps_is_post13_7_sf_symbol_name(name)) {
        return nil;
    }
    return [self pm_ps_uiimage_systemImageNamed:name compatibleWithTraitCollection:traitCollection];
}

+ (UIImage *) pm_ps_uiimage_systemImageNamed:(NSString *)name
                               variableValue:(double)value
                           withConfiguration:(UIImageConfiguration *)configuration {
    if (pt_is_bypass_enabled() &&
        pt_is_compat13_7_active() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return nil;
    }
    return [self pm_ps_uiimage_systemImageNamed:name variableValue:value withConfiguration:configuration];
}

+ (UIImage *) pm_ps_uiimage_priv_systemImageNamed:(NSString *)name {
    if (pt_is_bypass_enabled() &&
        pt_is_compat13_7_active() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        ps_is_post13_7_sf_symbol_name(name)) {
        return nil;
    }
    return [self pm_ps_uiimage_priv_systemImageNamed:name];
}

+ (UIImage *) pm_ps_uiimage_priv_systemImageNamed:(NSString *)name
                            withConfiguration:(UIImageConfiguration *)configuration {
    if (pt_is_bypass_enabled() &&
        pt_is_compat13_7_active() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        ps_is_post13_7_sf_symbol_name(name)) {
        return nil;
    }
    return [self pm_ps_uiimage_priv_systemImageNamed:name withConfiguration:configuration];
}

+ (NSArray<NSString *> *) pm_ps_uifont_familyNames {
    NSArray<NSString *> *orig = [self pm_ps_uifont_familyNames];
    if (orig.count == 0 ||
        !pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return orig;
    }
    return ps_filter_desktop_font_names(orig);
}

+ (NSArray<NSString *> *) pm_ps_uifont_fontNamesForFamilyName:(NSString *)familyName {
    const void *caller = __builtin_return_address(0);
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(caller) &&
        ps_is_hidden_desktop_font_name(familyName)) {
        return @[];
    }
    NSArray<NSString *> *orig = [self pm_ps_uifont_fontNamesForFamilyName:familyName];
    if (orig.count == 0 ||
        !pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(caller)) {
        return orig;
    }
    return ps_filter_desktop_font_names(orig);
}



- (NSString *) pm_ps_audio_route_description {
    const void *caller = __builtin_return_address(0);
    NSString *origDesc = [self pm_ps_audio_route_description];
    if (origDesc.length > 0 && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        return ps_sanitize_audio_port_string(origDesc, nil, NO);
    }
    return origDesc;
}


@end

static os_unfair_lock s_audio_port_swizzle_lock = OS_UNFAIR_LOCK_INIT;
static BOOL s_audio_port_hooks_installed = NO;
static BOOL s_audio_route_hooks_installed = NO;
static BOOL s_audio_session_avail_hooks_installed = NO;

__attribute__((visibility("hidden"))) void ps_install_audio_session_port_hooks(void) {
    os_unfair_lock_lock(&s_audio_port_swizzle_lock);
    if (!s_audio_port_hooks_installed) {
        Class cls = NSClassFromString(@"AVAudioSessionPortDescription");
        if (cls != Nil) {
            SEL portNameSel = NSSelectorFromString(@"portName");
            if (class_getInstanceMethod(cls, portNameSel) != NULL) {
                ps_swizzle_instance_method(cls, portNameSel, @selector(pm_ps_portName));
                atomic_store_explicit(&s_audio_port_name_swizzled, true, memory_order_release);
            }
            SEL uidSel = NSSelectorFromString(@"UID");
            if (class_getInstanceMethod(cls, uidSel) != NULL) {
                ps_swizzle_instance_method(cls, uidSel, @selector(pm_ps_UID));
                atomic_store_explicit(&s_audio_port_uid_swizzled, true, memory_order_release);
            }
            if (class_getInstanceMethod(cls, @selector(description)) != NULL) {
                ps_swizzle_instance_method(cls, @selector(description), @selector(pm_ps_audio_port_description));
            }
            s_audio_port_hooks_installed = YES;
        }
    }
    if (!s_audio_route_hooks_installed) {
        Class routeCls = NSClassFromString(@"AVAudioSessionRouteDescription");
        if (routeCls != Nil) {
            if (class_getInstanceMethod(routeCls, @selector(description)) != NULL) {
                ps_swizzle_instance_method(routeCls, @selector(description), @selector(pm_ps_audio_route_description));
            }
            SEL inputsSel = sel_registerName("inputs");
            if (class_getInstanceMethod(routeCls, inputsSel) != NULL) {
                ps_swizzle_instance_method(routeCls, inputsSel, @selector(pm_ps_audio_route_inputs));
            }
            SEL outputsSel = sel_registerName("outputs");
            if (class_getInstanceMethod(routeCls, outputsSel) != NULL) {
                ps_swizzle_instance_method(routeCls, outputsSel, @selector(pm_ps_audio_route_outputs));
            }
            s_audio_route_hooks_installed = YES;
        }
    }
    if (!s_audio_session_avail_hooks_installed) {
        Class sessCls = NSClassFromString(@"AVAudioSession");
        if (sessCls != Nil) {
            SEL availSel = sel_registerName("availableInputs");
            if (class_getInstanceMethod(sessCls, availSel) != NULL) {
                ps_swizzle_instance_method(sessCls, availSel, @selector(pm_ps_avsession_availableInputs));
            }
            s_audio_session_avail_hooks_installed = YES;
        }
    }
    os_unfair_lock_unlock(&s_audio_port_swizzle_lock);
}

__attribute__((visibility("hidden"))) void ps_install_avfoundation_audio_unit_hooks_if_loaded(void) {
    Class mgrCls = NSClassFromString(@"AVAudioUnitComponentManager");
    if (mgrCls != Nil) {
        static dispatch_once_t avauOnce;
        dispatch_once(&avauOnce, ^{
            SEL matchSel = sel_registerName("componentsMatchingDescription:");
            if (class_getInstanceMethod(mgrCls, matchSel) != NULL) {
                ps_swizzle_instance_method(mgrCls, matchSel, @selector(pm_ps_avau_componentsMatchingDescription:));
            }
            SEL passSel = sel_registerName("componentsPassingTest:");
            if (class_getInstanceMethod(mgrCls, passSel) != NULL) {
                ps_swizzle_instance_method(mgrCls, passSel, @selector(pm_ps_avau_componentsPassingTest:));
            }
        });
    }
}

__attribute__((visibility("hidden"))) void ps_install_corehaptics_hooks_if_loaded(void) {
    Class chCls = NSClassFromString(@"CHHapticEngine");
    if (chCls != Nil) {
        static dispatch_once_t chOnce;
        dispatch_once(&chOnce, ^{
            SEL capSel = sel_registerName("capabilitiesForHardware");
            if (class_getClassMethod(chCls, capSel) != NULL) {
                ps_swizzle_class_method(chCls, capSel, @selector(pm_ps_ch_capabilitiesForHardware));
            }
            SEL startErrSel = sel_registerName("startAndReturnError:");
            if (class_getInstanceMethod(chCls, startErrSel) != NULL) {
                ps_swizzle_instance_method(chCls, startErrSel, @selector(pm_ps_ch_startAndReturnError:));
            }
            SEL startCompSel = sel_registerName("startWithCompletionHandler:");
            if (class_getInstanceMethod(chCls, startCompSel) != NULL) {
                ps_swizzle_instance_method(chCls, startCompSel, @selector(pm_ps_ch_startWithCompletionHandler:));
            }
        });
    }
}

static os_unfair_lock s_av_hooks_lock = OS_UNFAIR_LOCK_INIT;
static BOOL s_av_device_hooks_installed = NO;
static BOOL s_av_session_hooks_installed = NO;

__attribute__((visibility("hidden"))) void ps_install_avcapture_hooks_if_loaded(void) {
    os_unfair_lock_lock(&s_av_hooks_lock);
    if (!s_av_device_hooks_installed) {
        Class avCls = objc_getClass("AVCaptureDevice");
        if (avCls != Nil) {
            SEL devicesSel = sel_registerName("devices");
            if (class_getClassMethod(avCls, devicesSel) != NULL) {
                ps_swizzle_class_method(avCls, devicesSel, @selector(pm_ps_av_devices));
            }
            SEL devicesMediaSel = sel_registerName("devicesWithMediaType:");
            if (class_getClassMethod(avCls, devicesMediaSel) != NULL) {
                ps_swizzle_class_method(avCls, devicesMediaSel, @selector(pm_ps_av_devicesWithMediaType:));
            }
            SEL defMediaSel = sel_registerName("defaultDeviceWithMediaType:");
            if (class_getClassMethod(avCls, defMediaSel) != NULL) {
                ps_swizzle_class_method(avCls, defMediaSel, @selector(pm_ps_av_defaultDeviceWithMediaType:));
            }
            SEL defTypeSel = sel_registerName("defaultDeviceWithDeviceType:mediaType:position:");
            if (class_getClassMethod(avCls, defTypeSel) != NULL) {
                ps_swizzle_class_method(avCls, defTypeSel, @selector(pm_ps_av_defaultDeviceWithDeviceType:mediaType:position:));
            }
            SEL devWithUidSel = sel_registerName("deviceWithUniqueID:");
            if (class_getClassMethod(avCls, devWithUidSel) != NULL) {
                ps_swizzle_class_method(avCls, devWithUidSel, @selector(pm_ps_av_deviceWithUniqueID:));
            }
            ps_swizzle_capture_device_class(avCls);
            Class avFmtCls = objc_getClass("AVCaptureDeviceFormat");
            if (avFmtCls != Nil) {
                ps_swizzle_capture_format_class(avFmtCls);
            }
            s_av_device_hooks_installed = YES;
        }
    }
    if (!s_av_session_hooks_installed) {
        Class sessionCls = objc_getClass("AVCaptureDeviceDiscoverySession");
        if (sessionCls != Nil) {
            SEL devicesSel = sel_registerName("devices");
            if (class_getInstanceMethod(sessionCls, devicesSel) != NULL) {
                ps_swizzle_instance_method(sessionCls, devicesSel, @selector(pm_ps_av_session_devices));
            }
            s_av_session_hooks_installed = YES;
        }
    }
    os_unfair_lock_unlock(&s_av_hooks_lock);
}


__attribute__((visibility("hidden"))) void ps_install_app_attest_hooks_if_loaded(void) {
    Class appAttestCls = objc_getClass("DCAppAttestService");
    if (appAttestCls != Nil) {
        static dispatch_once_t appAttestOnce;
        dispatch_once(&appAttestOnce, ^{
            SEL isSupportedSel = NSSelectorFromString(@"isSupported");
            if (class_getInstanceMethod(appAttestCls, isSupportedSel) != NULL) {
                ps_swizzle_instance_method(appAttestCls, isSupportedSel, @selector(pm_ps_appAttest_isSupported));
            }
            SEL genKeySel = NSSelectorFromString(@"generateKeyWithCompletionHandler:");
            if (class_getInstanceMethod(appAttestCls, genKeySel) != NULL) {
                ps_swizzle_instance_method(appAttestCls, genKeySel, @selector(pm_ps_appAttest_generateKeyWithCompletionHandler:));
            }
            SEL attestSel = NSSelectorFromString(@"attestKey:clientDataHash:completionHandler:");
            if (class_getInstanceMethod(appAttestCls, attestSel) != NULL) {
                ps_swizzle_instance_method(appAttestCls, attestSel, @selector(pm_ps_appAttest_attestKey:clientDataHash:completionHandler:));
            }
            SEL assertSel = NSSelectorFromString(@"generateAssertion:clientDataHash:completionHandler:");
            if (class_getInstanceMethod(appAttestCls, assertSel) != NULL) {
                ps_swizzle_instance_method(appAttestCls, assertSel, @selector(pm_ps_appAttest_generateAssertion:clientDataHash:completionHandler:));
            }
        });
    }
    Class dcDeviceCls = objc_getClass("DCDevice");
    if (dcDeviceCls != Nil) {
        static dispatch_once_t dcDeviceOnce;
        dispatch_once(&dcDeviceOnce, ^{
            SEL isSupportedSel = NSSelectorFromString(@"isSupported");
            if (class_getInstanceMethod(dcDeviceCls, isSupportedSel) != NULL) {
                ps_swizzle_instance_method(dcDeviceCls, isSupportedSel, @selector(pm_ps_dcDevice_isSupported));
            }
            SEL genTokenSel = NSSelectorFromString(@"generateTokenWithCompletionHandler:");
            if (class_getInstanceMethod(dcDeviceCls, genTokenSel) != NULL) {
                ps_swizzle_instance_method(dcDeviceCls, genTokenSel, @selector(pm_ps_dcDevice_generateTokenWithCompletionHandler:));
            }
        });
    }
}

__attribute__((visibility("hidden"))) void ps_install_uifont_hooks_if_loaded(void) {
    Class fontCls = objc_getClass("UIFont");
    if (fontCls != Nil) {
        static dispatch_once_t fontOnce;
        dispatch_once(&fontOnce, ^{
            if (class_getClassMethod(fontCls, @selector(familyNames)) != NULL) {
                ps_swizzle_class_method(fontCls, @selector(familyNames), @selector(pm_ps_uifont_familyNames));
            }
            if (class_getClassMethod(fontCls, @selector(fontNamesForFamilyName:)) != NULL) {
                ps_swizzle_class_method(fontCls,
                                        @selector(fontNamesForFamilyName:),
                                        @selector(pm_ps_uifont_fontNamesForFamilyName:));
            }
            if (class_getClassMethod(fontCls, @selector(fontWithName:size:)) != NULL) {
                ps_swizzle_class_method(fontCls,
                                        @selector(fontWithName:size:),
                                        @selector(pm_ps_uifont_fontWithName:size:));
            }
            SEL withDescSel = sel_registerName("fontWithDescriptor:size:");
            if (class_getClassMethod(fontCls, withDescSel) != NULL) {
                ps_swizzle_class_method(fontCls,
                                        withDescSel,
                                        @selector(pm_ps_uifont_fontWithDescriptor:size:));
            }
        });
    }
    Class descCls = objc_getClass("UIFontDescriptor");
    if (descCls != Nil) {
        static dispatch_once_t descOnce;
        dispatch_once(&descOnce, ^{
            SEL matchSel = sel_registerName("matchingFontDescriptorsWithMandatoryKeys:");
            if (class_getInstanceMethod(descCls, matchSel) != NULL) {
                ps_swizzle_instance_method(descCls,
                                           matchSel,
                                           @selector(pm_ps_uifontdesc_matchingFontDescriptorsWithMandatoryKeys:));
            }
            Class ctDescCls = objc_getClass("NSCTFontDescriptor");
            if (ctDescCls != Nil && ctDescCls != descCls && ps_class_defines_instance_method(ctDescCls, matchSel)) {
                ps_swizzle_instance_method(ctDescCls,
                                           matchSel,
                                           @selector(pm_ps_ctfontdesc_matchingFontDescriptorsWithMandatoryKeys:));
            }
            Class uiCtDescCls = objc_getClass("UICTFontDescriptor");
            if (uiCtDescCls != Nil && uiCtDescCls != descCls && uiCtDescCls != ctDescCls &&
                ps_class_defines_instance_method(uiCtDescCls, matchSel)) {
                ps_swizzle_instance_method(uiCtDescCls,
                                           matchSel,
                                           @selector(pm_ps_uictfontdesc_matchingFontDescriptorsWithMandatoryKeys:));
            }
        });
    }
}


__attribute__((visibility("hidden"))) void ps_install_local_auth_hooks_if_loaded(void) {
    Class laCtxCls = NSClassFromString(@"LAContext");
    if (laCtxCls != Nil) {
        static dispatch_once_t laOnce;
        dispatch_once(&laOnce, ^{
            SEL canEvalSel = NSSelectorFromString(@"canEvaluatePolicy:error:");
            if (class_getInstanceMethod(laCtxCls, canEvalSel) != NULL) {
                ps_swizzle_instance_method(laCtxCls,
                                           canEvalSel,
                                           @selector(pm_ps_la_canEvaluatePolicy:error:));
            }
            SEL evalSel = NSSelectorFromString(@"evaluatePolicy:localizedReason:reply:");
            if (class_getInstanceMethod(laCtxCls, evalSel) != NULL) {
                ps_swizzle_instance_method(laCtxCls,
                                           evalSel,
                                           @selector(pm_ps_la_evaluatePolicy:localizedReason:reply:));
            }
            SEL biometrySel = NSSelectorFromString(@"biometryType");
            if (class_getInstanceMethod(laCtxCls, biometrySel) != NULL) {
                ps_swizzle_instance_method(laCtxCls,
                                           biometrySel,
                                           @selector(pm_ps_la_biometryType));
            }
        });
    }
    Class domainBiometryCls = NSClassFromString(@"LADomainStateBiometry");
    if (domainBiometryCls != Nil) {
        static dispatch_once_t domainBioOnce;
        dispatch_once(&domainBioOnce, ^{
            SEL biometrySel = NSSelectorFromString(@"biometryType");
            if (class_getInstanceMethod(domainBiometryCls, biometrySel) != NULL) {
                ps_swizzle_instance_method(domainBiometryCls,
                                           biometrySel,
                                           @selector(pm_ps_la_domain_biometryType));
            }
        });
    }
}

__attribute__((visibility("hidden"))) void ps_install_jscontext_hooks_if_loaded(void) {
    Class jscCls = objc_getClass("JSContext");
    if (jscCls != Nil) {
        static dispatch_once_t jscOnce;
        dispatch_once(&jscOnce, ^{
            if (class_getInstanceMethod(jscCls, @selector(init)) != NULL) {
                ps_swizzle_instance_method(jscCls, @selector(init), @selector(pm_ps_jsc_init));
            }
            SEL initVMSel = NSSelectorFromString(@"initWithVirtualMachine:");
            if (class_getInstanceMethod(jscCls, initVMSel) != NULL) {
                ps_swizzle_instance_method(jscCls, initVMSel, @selector(pm_ps_jsc_initWithVirtualMachine:));
            }
            SEL ctxRefSel = NSSelectorFromString(@"contextWithJSGlobalContextRef:");
            if (class_getClassMethod(jscCls, ctxRefSel) != NULL) {
                ps_swizzle_class_method(jscCls, ctxRefSel, @selector(pm_ps_jsc_contextWithJSGlobalContextRef:));
            }
        });
    }
}

__attribute__((visibility("hidden"))) void ps_install_game_controller_hooks_if_loaded(void) {
    Class gcCls = objc_getClass("GCController");
    if (gcCls != Nil) {
        static dispatch_once_t gcOnce;
        dispatch_once(&gcOnce, ^{
            SEL bgSel = NSSelectorFromString(@"shouldMonitorBackgroundEvents");
            if (class_getClassMethod(gcCls, bgSel) != NULL) {
                ps_swizzle_class_method(gcCls,
                                        bgSel,
                                        @selector(pm_ps_gc_shouldMonitorBackgroundEvents));
            }
            SEL setBgSel = NSSelectorFromString(@"setShouldMonitorBackgroundEvents:");
            if (class_getClassMethod(gcCls, setBgSel) != NULL) {
                ps_swizzle_class_method(gcCls,
                                        setBgSel,
                                        @selector(pm_ps_gc_setShouldMonitorBackgroundEvents:));
            }
            if (class_getClassMethod(gcCls, @selector(respondsToSelector:)) != NULL) {
                ps_swizzle_class_method(gcCls,
                                        @selector(respondsToSelector:),
                                        @selector(pm_ps_gc_respondsToSelector:));
            }
        });
    }
    Class gcMouseCls = objc_getClass("GCMouse");
    if (gcMouseCls != Nil) {
        static dispatch_once_t gcMouseOnce;
        dispatch_once(&gcMouseOnce, ^{
            SEL miceSel = NSSelectorFromString(@"mice");
            if (class_getClassMethod(gcMouseCls, miceSel) != NULL) {
                ps_swizzle_class_method(gcMouseCls, miceSel, @selector(pm_ps_gc_mice));
            }
            SEL curSel = NSSelectorFromString(@"current");
            if (class_getClassMethod(gcMouseCls, curSel) != NULL) {
                ps_swizzle_class_method(gcMouseCls, curSel, @selector(pm_ps_gc_currentMouse));
            }
        });
    }
    Class gcKeyCls = objc_getClass("GCKeyboard");
    if (gcKeyCls != Nil) {
        static dispatch_once_t gcKeyOnce;
        dispatch_once(&gcKeyOnce, ^{
            SEL coalescedSel = NSSelectorFromString(@"coalescedKeyboard");
            if (class_getClassMethod(gcKeyCls, coalescedSel) != NULL) {
                ps_swizzle_class_method(gcKeyCls, coalescedSel, @selector(pm_ps_gc_coalescedKeyboard));
            }
        });
    }
}
