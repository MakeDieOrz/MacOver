//
//  PTGraphicsVirtualizer.m
//  PlayTools
//

#import "PSInternal.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

@implementation PSSwizzleHooks (PlayShadowGraphics)

typedef struct {
    NSUInteger width;
    NSUInteger height;
    NSUInteger depth;
} PSMTLSize;

static os_unfair_lock s_mtl_swizzle_lock = OS_UNFAIR_LOCK_INIT;
static CFMutableDictionaryRef s_mtl_orig_name_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_working_set_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_max_buf_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_supports_family_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_supports_fset_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_supports_bc_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_supports_32f_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_supports_32bit_msaa_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_arg_buffers_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_rw_tex_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_is_low_power_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_is_headless_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_is_removable_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_location_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_location_number_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_peer_group_id_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_peer_index_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_peer_count_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_supports_rt_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_supports_rt_render_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_supports_motion_blur_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_supports_fn_ptr_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_supports_fn_ptr_render_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_supports_dyn_lib_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_supports_render_dyn_lib_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_supports_pull_interp_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_supports_barycentric_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_supports_query_lod_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_max_threads_tg_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_max_tg_mem_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_architecture_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_arch_name_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_lib_sync_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_lib_async_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_opts_langver_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_opts_set_langver_imps = NULL;
static const char kPSMTLCompileOptionsExplicitLangVerKey = 0;

static void pt_mtl_line_and_col_for_location(NSString *source, NSUInteger loc, NSUInteger *outLine, NSUInteger *outCol) {
    NSUInteger line = 1;
    NSUInteger lineStart = 0;
    NSUInteger limit = (loc < source.length) ? loc : source.length;
    for (NSUInteger i = 0; i < limit; i++) {
        if ([source characterAtIndex:i] == '\n') {
            line++;
            lineStart = i + 1;
        }
    }
    if (outLine != NULL) {
        *outLine = line;
    }
    if (outCol != NULL) {
        *outCol = (limit - lineStart) + 1;
    }
}

static void ps_swizzle_mtl_arch_class(Class archCls);

static NSUInteger pt_mtl_default_compile_language_version(void) {
    static NSUInteger s_default_lang_ver = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class optsCls = NSClassFromString(@"MTLCompileOptions");
        SEL langSel = sel_registerName("languageVersion");
        id opts = (optsCls != Nil) ? [optsCls new] : nil;
        if (opts != nil && [opts respondsToSelector:langSel]) {
            s_default_lang_ver = ((NSUInteger (*)(id, SEL))objc_msgSend)(opts, langSel);
        }
    });
    return s_default_lang_ver;
}

static BOOL pt_mtl_should_reject_source_for_compat13(NSString *source, id options, NSError **outError) {
    if (!pt_is_bypass_enabled() || !pt_is_compat13_7_active()) {
        return NO;
    }
    BOOL reject = NO;
    if (options != nil) {
        NSNumber *explicitVer = objc_getAssociatedObject(options, &kPSMTLCompileOptionsExplicitLangVerKey);
        if (explicitVer != nil) {
            if (explicitVer.unsignedIntegerValue > ((2U << 16) | 2U)) {
                reject = YES;
            }
        } else {
            os_unfair_lock_lock(&s_mtl_swizzle_lock);
            BOOL hasOptsSetterHook = (s_mtl_orig_opts_set_langver_imps != NULL);
            os_unfair_lock_unlock(&s_mtl_swizzle_lock);
            if (!hasOptsSetterHook) {
                SEL langSel = sel_registerName("languageVersion");
                if ([options respondsToSelector:langSel]) {
                    NSUInteger langVer = ((NSUInteger (*)(id, SEL))objc_msgSend)(options, langSel);
                    NSUInteger defaultVer = pt_mtl_default_compile_language_version();
                    if (langVer > ((2U << 16) | 2U) && (defaultVer == 0 || langVer != defaultVer)) {
                        reject = YES;
                    }
                }
            }
        }
    }
    if (!reject && source != nil && [source isKindOfClass:[NSString class]]) {
        if ([source containsString:@"metal_simdgroup_matrix"] ||
            [source containsString:@"simdgroup_multiply_accumulate"] ||
            [source containsString:@"metal_raytracing"] ||
            [source containsString:@"raytracing::intersector"]) {
            reject = YES;
        }
    }
    if (!reject) {
        return NO;
    }
    if (outError != NULL) {
        NSString *msg = @"Compilation failed:\nInvalid languageVersion";
        if (source != nil && [source isKindOfClass:[NSString class]]) {
            NSRange hdrRange = [source rangeOfString:@"metal_simdgroup_matrix"];
            NSRange rtHdrRange = [source rangeOfString:@"metal_raytracing"];
            if (hdrRange.location != NSNotFound) {
                NSUInteger line = 1, col = 10;
                pt_mtl_line_and_col_for_location(source, hdrRange.location, &line, &col);
                msg = [NSString stringWithFormat:
                       @"program_source:%lu:%lu: fatal error: 'metal_simdgroup_matrix' file not found\n"
                        "#include <metal_simdgroup_matrix>\n"
                        "         ^~~~~~~~~~~~~~~~~~~~~~~~",
                       (unsigned long)line, (unsigned long)col];
            } else if (rtHdrRange.location != NSNotFound) {
                NSUInteger line = 1, col = 10;
                pt_mtl_line_and_col_for_location(source, rtHdrRange.location, &line, &col);
                msg = [NSString stringWithFormat:
                       @"program_source:%lu:%lu: fatal error: 'metal_raytracing' file not found\n"
                        "#include <metal_raytracing>\n"
                        "         ^~~~~~~~~~~~~~~~~~",
                       (unsigned long)line, (unsigned long)col];
            } else {
                NSRange symRange = [source rangeOfString:@"simdgroup_multiply_accumulate"];
                NSRange rtSymRange = [source rangeOfString:@"raytracing::intersector"];
                if (symRange.location != NSNotFound) {
                    NSUInteger line = 1, col = 1;
                    pt_mtl_line_and_col_for_location(source, symRange.location, &line, &col);
                    msg = [NSString stringWithFormat:
                           @"program_source:%lu:%lu: error: use of undeclared identifier 'simdgroup_multiply_accumulate'",
                           (unsigned long)line, (unsigned long)col];
                } else if (rtSymRange.location != NSNotFound) {
                    NSUInteger line = 1, col = 1;
                    pt_mtl_line_and_col_for_location(source, rtSymRange.location, &line, &col);
                    msg = [NSString stringWithFormat:
                           @"program_source:%lu:%lu: error: use of undeclared identifier 'raytracing'",
                           (unsigned long)line, (unsigned long)col];
                }
            }
        }
        *outError = [NSError errorWithDomain:@"MTLLibraryErrorDomain"
                                        code:3
                                    userInfo:@{
                                        NSLocalizedDescriptionKey : msg
                                    }];
    }
    return YES;
}

static uint64_t ps_mtl_memory_cap(void) {
    uint64_t mem = pt_get_spoofed_physical_memory();
    if (mem == 0) {
        mem = (uint64_t)[[NSProcessInfo processInfo] physicalMemory];
    }
    return (mem * 3ULL) / 4ULL;
}

- (NSString *) pm_mtl_device_name {
    if (!pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        BOOL pushed = NO;
        IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_name_imps, self, &pushed);
        if (origIMP != NULL) {
            @try {
                return ((NSString *(*)(id, SEL))origIMP)(self, @selector(name));
            } @finally {
                ps_pop_orig_imp_frame(pushed);
            }
        }
    }
    const char *gpuName = pt_get_spoofed_gpu_name_cstr();
    if (gpuName != NULL && gpuName[0] != '\0') {
        static os_unfair_lock s_gpuNameLock = OS_UNFAIR_LOCK_INIT;
        static const char *s_lastGpuPtr = NULL;
        static char s_lastGpuBuf[128] = {0};
        static NSString *s_cachedGpuName = nil;
        os_unfair_lock_lock(&s_gpuNameLock);
        if (s_cachedGpuName == nil || (s_lastGpuPtr != gpuName && strncmp(s_lastGpuBuf, gpuName, sizeof(s_lastGpuBuf) - 1) != 0)) {
            NSString *s = [NSString stringWithUTF8String:gpuName];
            if (s.length > 0) {
                s_cachedGpuName = [s copy];
                s_lastGpuPtr = gpuName;
                strlcpy(s_lastGpuBuf, gpuName, sizeof(s_lastGpuBuf));
            }
        }
        NSString *result = s_cachedGpuName;
        os_unfair_lock_unlock(&s_gpuNameLock);
        if (result.length > 0) {
            return result;
        }
    }
    return @"Apple GPU";
}

- (uint64_t) pm_ps_mtl_recommendedMaxWorkingSetSize {
    SEL sel = sel_registerName("recommendedMaxWorkingSetSize");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_working_set_imps, self, &pushed);
    uint64_t orig = 0;
    if (origIMP != NULL) {
        @try {
            orig = ((uint64_t (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        uint64_t cap = ps_mtl_memory_cap();
        if (cap > 0 && orig > cap) {
            return cap;
        }
    }
    return orig;
}

- (NSUInteger) pm_ps_mtl_maxBufferLength {
    SEL sel = sel_registerName("maxBufferLength");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_max_buf_imps, self, &pushed);
    NSUInteger orig = 0;
    if (origIMP != NULL) {
        @try {
            orig = ((NSUInteger (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        uint64_t cap = ps_mtl_memory_cap();
        if (cap > 0 && (uint64_t)orig > cap) {
            return (NSUInteger)cap;
        }
    }
    return orig;
}

- (BOOL) pm_ps_mtl_supportsFamily:(NSInteger)gpuFamily {
    SEL sel = sel_registerName("supportsFamily:");
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        // Hide macOS (2000..2999) and Mac Catalyst (4000..4999) GPU families on spoofed iOS
        if ((gpuFamily >= 2000 && gpuFamily < 3000) || (gpuFamily >= 4000 && gpuFamily < 5000)) {
            return NO;
        }
        int32_t maxAppleFam = pt_get_spoofed_max_apple_gpu_family();
        if (gpuFamily >= 1001 && gpuFamily < 1100 && gpuFamily > (NSInteger)maxAppleFam) {
            return NO;
        }
        if (gpuFamily == 5001 && maxAppleFam < 1007) { // MTLGPUFamilyMetal3 requires Apple7+
            return NO;
        }
        if (gpuFamily == 5002 &&
            (pt_get_reported_ios_version_override(NULL) != NULL || maxAppleFam < 1007)) {
            // MTLGPUFamilyMetal4 does not exist on iOS 13.7/18.3 and requires Apple7+
            return NO;
        }
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_supports_family_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((BOOL (*)(id, SEL, NSInteger))origIMP)(self, sel, gpuFamily);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return NO;
}

- (BOOL) pm_ps_mtl_supportsFeatureSet:(NSUInteger)featureSet {
    SEL sel = sel_registerName("supportsFeatureSet:");
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        // macOS (10000+) and tvOS (30000+) feature sets do not exist on iOS
        if (featureSet >= 10000U) {
            return NO;
        }
        int32_t maxAppleFam = pt_get_spoofed_max_apple_gpu_family();
        if ((featureSet == 11U || featureSet == 15U) && maxAppleFam < 1004) {
            return NO;
        }
        if (featureSet == 16U && maxAppleFam < 1005) {
            return NO;
        }
        if (featureSet <= 16U) {
            return YES;
        }
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_supports_fset_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((BOOL (*)(id, SEL, NSUInteger))origIMP)(self, sel, featureSet);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return NO;
}

- (BOOL) pm_ps_mtl_supportsBCTextureCompression {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NO;
    }
    SEL sel = sel_registerName("supportsBCTextureCompression");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_supports_bc_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((BOOL (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return NO;
}

- (BOOL) pm_ps_mtl_supports32BitFloatFiltering {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_get_spoofed_max_apple_gpu_family() < 1007) {
        return NO;
    }
    SEL sel = sel_registerName("supports32BitFloatFiltering");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_supports_32f_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((BOOL (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return NO;
}

- (BOOL) pm_ps_mtl_isLowPower {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NO;
    }
    SEL sel = sel_registerName("isLowPower");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_is_low_power_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((BOOL (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return NO;
}

- (BOOL) pm_ps_mtl_isHeadless {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NO;
    }
    SEL sel = sel_registerName("isHeadless");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_is_headless_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((BOOL (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return NO;
}

- (BOOL) pm_ps_mtl_isRemovable {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return NO;
    }
    SEL sel = sel_registerName("isRemovable");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_is_removable_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((BOOL (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return NO;
}

- (NSUInteger) pm_ps_mtl_location {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return 0; // MTLDeviceLocationBuiltIn
    }
    SEL sel = sel_registerName("location");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_location_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((NSUInteger (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return 0;
}

- (NSUInteger) pm_ps_mtl_locationNumber {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return 0;
    }
    SEL sel = sel_registerName("locationNumber");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_location_number_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((NSUInteger (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return 0;
}

- (uint64_t) pm_ps_mtl_peerGroupID {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return 0ULL;
    }
    SEL sel = sel_registerName("peerGroupID");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_peer_group_id_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((uint64_t (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return 0ULL;
}

- (uint32_t) pm_ps_mtl_peerIndex {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return 0U;
    }
    SEL sel = sel_registerName("peerIndex");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_peer_index_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((uint32_t (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return 0U;
}

- (uint32_t) pm_ps_mtl_peerCount {
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return 0U;
    }
    SEL sel = sel_registerName("peerCount");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_peer_count_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((uint32_t (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return 0U;
}

- (BOOL) pm_ps_mtl_supportsRaytracing {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        (pt_is_compat13_7_active() || pt_get_spoofed_max_apple_gpu_family() < 1007)) {
        return NO;
    }
    SEL sel = sel_registerName("supportsRaytracing");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_supports_rt_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((BOOL (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return NO;
}

- (BOOL) pm_ps_mtl_supportsRaytracingFromRender {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        (pt_is_compat13_7_active() || pt_get_spoofed_max_apple_gpu_family() < 1007)) {
        return NO;
    }
    SEL sel = sel_registerName("supportsRaytracingFromRender");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_supports_rt_render_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((BOOL (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return NO;
}

- (BOOL) pm_ps_mtl_supportsPrimitiveMotionBlur {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        (pt_is_compat13_7_active() || pt_get_spoofed_max_apple_gpu_family() < 1007)) {
        return NO;
    }
    SEL sel = sel_registerName("supportsPrimitiveMotionBlur");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_supports_motion_blur_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((BOOL (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return NO;
}

- (BOOL) pm_ps_mtl_supportsFunctionPointers {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        (pt_is_compat13_7_active() || pt_get_spoofed_max_apple_gpu_family() < 1006)) {
        return NO;
    }
    SEL sel = sel_registerName("supportsFunctionPointers");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_supports_fn_ptr_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((BOOL (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return NO;
}

- (BOOL) pm_ps_mtl_supportsFunctionPointersFromRender {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        (pt_is_compat13_7_active() || pt_get_spoofed_max_apple_gpu_family() < 1006)) {
        return NO;
    }
    SEL sel = sel_registerName("supportsFunctionPointersFromRender");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_supports_fn_ptr_render_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((BOOL (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return NO;
}

- (BOOL) pm_ps_mtl_supportsDynamicLibraries {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        (pt_is_compat13_7_active() || pt_get_spoofed_max_apple_gpu_family() < 1006)) {
        return NO;
    }
    SEL sel = sel_registerName("supportsDynamicLibraries");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_supports_dyn_lib_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((BOOL (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return NO;
}

- (BOOL) pm_ps_mtl_supportsRenderDynamicLibraries {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        (pt_is_compat13_7_active() || pt_get_spoofed_max_apple_gpu_family() < 1006)) {
        return NO;
    }
    SEL sel = sel_registerName("supportsRenderDynamicLibraries");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_supports_render_dyn_lib_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((BOOL (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return NO;
}

- (BOOL) pm_ps_mtl_supportsPullModelInterpolation {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        (pt_is_compat13_7_active() || pt_get_spoofed_max_apple_gpu_family() < 1007)) {
        return NO;
    }
    SEL sel = sel_registerName("supportsPullModelInterpolation");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_supports_pull_interp_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((BOOL (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return NO;
}

- (BOOL) pm_ps_mtl_supportsShaderBarycentricCoordinates {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        (pt_is_compat13_7_active() || pt_get_spoofed_max_apple_gpu_family() < 1007)) {
        return NO;
    }
    SEL sel = sel_registerName("supportsShaderBarycentricCoordinates");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_supports_barycentric_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((BOOL (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return NO;
}

- (BOOL) pm_ps_mtl_supportsQueryTextureLOD {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        (pt_is_compat13_7_active() || pt_get_spoofed_max_apple_gpu_family() < 1004)) {
        return NO;
    }
    SEL sel = sel_registerName("supportsQueryTextureLOD");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_supports_query_lod_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((BOOL (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return NO;
}

- (BOOL) pm_ps_mtl_supports32BitMSAA {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        (pt_is_compat13_7_active() || pt_get_spoofed_max_apple_gpu_family() < 1007)) {
        return NO;
    }
    SEL sel = sel_registerName("supports32BitMSAA");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_supports_32bit_msaa_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((BOOL (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return NO;
}

- (NSUInteger) pm_ps_mtl_argumentBuffersSupport {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_get_spoofed_max_apple_gpu_family() <= 1005) {
        return 0U; // MTLArgumentBuffersTier1
    }
    SEL sel = sel_registerName("argumentBuffersSupport");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_arg_buffers_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((NSUInteger (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return 0U;
}

- (NSUInteger) pm_ps_mtl_readWriteTextureSupport {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_get_spoofed_max_apple_gpu_family() <= 1003) {
        return 1U; // MTLReadWriteTextureTier1
    }
    SEL sel = sel_registerName("readWriteTextureSupport");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_rw_tex_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((NSUInteger (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return 1U;
}

- (PSMTLSize) pm_ps_mtl_maxThreadsPerThreadgroup {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_get_spoofed_max_apple_gpu_family() <= 1003) {
        return (PSMTLSize){ 512, 512, 512 };
    }
    SEL sel = sel_registerName("maxThreadsPerThreadgroup");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_max_threads_tg_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((PSMTLSize (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return (PSMTLSize){ 1024, 1024, 1024 };
}

- (NSUInteger) pm_ps_mtl_maxThreadgroupMemoryLength {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_get_spoofed_max_apple_gpu_family() <= 1003) {
        return 16384U;
    }
    SEL sel = sel_registerName("maxThreadgroupMemoryLength");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_max_tg_mem_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((NSUInteger (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return 32768U;
}

- (NSString *) pm_ps_mtl_arch_name {
    SEL sel = @selector(name);
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        const char *archCStr = pt_get_spoofed_gpu_arch_cstr();
        if (archCStr != NULL && archCStr[0] != '\0') {
            NSString *spoofed = [NSString stringWithUTF8String:archCStr];
            if (spoofed.length > 0) {
                return spoofed;
            }
        }
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_arch_name_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((NSString *(*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return @"applegpu_g13g";
}

- (id) pm_ps_mtl_architecture {
    if (pt_is_bypass_enabled() &&
        pt_is_compat13_7_active() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return nil;
    }
    SEL sel = sel_registerName("architecture");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_architecture_imps, self, &pushed);
    id arch = nil;
    if (origIMP != NULL) {
        @try {
            arch = ((id (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (arch != nil) {
        ps_swizzle_mtl_arch_class(object_getClass(arch));
    }
    return arch;
}

- (id) pm_ps_mtl_newLibraryWithSource:(NSString *)source options:(id)options error:(NSError **)error NS_RETURNS_RETAINED {
    if (!ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        NSError *rejectError = nil;
        if (pt_mtl_should_reject_source_for_compat13(source, options, &rejectError)) {
            if (error != NULL) {
                *error = rejectError;
            }
            return nil;
        }
    }
    SEL sel = sel_registerName("newLibraryWithSource:options:error:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_lib_sync_imps, self, &pushed);
    if (origIMP != NULL) {
        typedef id (*PTMTLNewLibSyncOrigFn)(id, SEL, NSString *, id, NSError **) NS_RETURNS_RETAINED;
        @try {
            return ((PTMTLNewLibSyncOrigFn)origIMP)(self, sel, source, options, error);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return nil;
}

- (void) pm_ps_mtl_newLibraryWithSource:(NSString *)source
                                options:(id)options
                      completionHandler:(void (^)(id library, NSError *error))completionHandler {
    if (!ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        NSError *rejectError = nil;
        if (pt_mtl_should_reject_source_for_compat13(source, options, &rejectError)) {
            if (completionHandler != nil) {
                completionHandler(nil, rejectError);
            }
            return;
        }
    }
    SEL sel = sel_registerName("newLibraryWithSource:options:completionHandler:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_lib_async_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, NSString *, id, id))origIMP)(self, sel, source, options, completionHandler);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
}

- (void) pm_ps_mtl_opts_setLanguageVersion:(NSUInteger)ver {
    if (!ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        objc_setAssociatedObject(self, &kPSMTLCompileOptionsExplicitLangVerKey, @(ver),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    SEL sel = sel_registerName("setLanguageVersion:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_opts_set_langver_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, NSUInteger))origIMP)(self, sel, ver);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
}

- (NSUInteger) pm_ps_mtl_opts_languageVersion {
    if (pt_is_bypass_enabled() &&
        pt_is_compat13_7_active() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        objc_getAssociatedObject(self, &kPSMTLCompileOptionsExplicitLangVerKey) == nil) {
        return ((2U << 16) | 2U);
    }
    SEL sel = sel_registerName("languageVersion");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_opts_langver_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((NSUInteger (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return ((2U << 16) | 2U);
}

@end

static void ps_swizzle_mtl_compile_options_if_loaded(void) {
    Class optsCls = NSClassFromString(@"MTLCompileOptions");
    if (optsCls == Nil) {
        return;
    }
    static dispatch_once_t optsOnce;
    dispatch_once(&optsOnce, ^{
        id sample = [optsCls new];
        Class targetCls = (sample != nil) ? object_getClass(sample) : optsCls;
        if (targetCls != Nil) {
            ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_opts_langver_imps, targetCls,
                                             sel_registerName("languageVersion"),
                                             @selector(pm_ps_mtl_opts_languageVersion));
            ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_opts_set_langver_imps, targetCls,
                                             sel_registerName("setLanguageVersion:"),
                                             @selector(pm_ps_mtl_opts_setLanguageVersion:));
        }
    });
}

static void ps_swizzle_mtl_arch_class(Class archCls) {
    if (archCls == Nil) {
        return;
    }
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_arch_name_imps, archCls,
                                     @selector(name), @selector(pm_ps_mtl_arch_name));
}

static void ps_swizzle_mtl_device_class(Class cls) {
    if (cls == Nil) {
        return;
    }
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_name_imps, cls,
                                     @selector(name), @selector(pm_mtl_device_name));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_working_set_imps, cls,
                                     sel_registerName("recommendedMaxWorkingSetSize"),
                                     @selector(pm_ps_mtl_recommendedMaxWorkingSetSize));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_max_buf_imps, cls,
                                     sel_registerName("maxBufferLength"),
                                     @selector(pm_ps_mtl_maxBufferLength));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_supports_family_imps, cls,
                                     sel_registerName("supportsFamily:"),
                                     @selector(pm_ps_mtl_supportsFamily:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_supports_fset_imps, cls,
                                     sel_registerName("supportsFeatureSet:"),
                                     @selector(pm_ps_mtl_supportsFeatureSet:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_supports_bc_imps, cls,
                                     sel_registerName("supportsBCTextureCompression"),
                                     @selector(pm_ps_mtl_supportsBCTextureCompression));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_supports_32f_imps, cls,
                                     sel_registerName("supports32BitFloatFiltering"),
                                     @selector(pm_ps_mtl_supports32BitFloatFiltering));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_supports_32bit_msaa_imps, cls,
                                     sel_registerName("supports32BitMSAA"),
                                     @selector(pm_ps_mtl_supports32BitMSAA));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_arg_buffers_imps, cls,
                                     sel_registerName("argumentBuffersSupport"),
                                     @selector(pm_ps_mtl_argumentBuffersSupport));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_rw_tex_imps, cls,
                                     sel_registerName("readWriteTextureSupport"),
                                     @selector(pm_ps_mtl_readWriteTextureSupport));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_is_low_power_imps, cls,
                                     sel_registerName("isLowPower"),
                                     @selector(pm_ps_mtl_isLowPower));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_is_headless_imps, cls,
                                     sel_registerName("isHeadless"),
                                     @selector(pm_ps_mtl_isHeadless));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_is_removable_imps, cls,
                                     sel_registerName("isRemovable"),
                                     @selector(pm_ps_mtl_isRemovable));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_location_imps, cls,
                                     sel_registerName("location"),
                                     @selector(pm_ps_mtl_location));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_location_number_imps, cls,
                                     sel_registerName("locationNumber"),
                                     @selector(pm_ps_mtl_locationNumber));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_peer_group_id_imps, cls,
                                     sel_registerName("peerGroupID"),
                                     @selector(pm_ps_mtl_peerGroupID));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_peer_index_imps, cls,
                                     sel_registerName("peerIndex"),
                                     @selector(pm_ps_mtl_peerIndex));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_peer_count_imps, cls,
                                     sel_registerName("peerCount"),
                                     @selector(pm_ps_mtl_peerCount));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_supports_rt_imps, cls,
                                     sel_registerName("supportsRaytracing"),
                                     @selector(pm_ps_mtl_supportsRaytracing));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_supports_rt_render_imps, cls,
                                     sel_registerName("supportsRaytracingFromRender"),
                                     @selector(pm_ps_mtl_supportsRaytracingFromRender));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_supports_motion_blur_imps, cls,
                                     sel_registerName("supportsPrimitiveMotionBlur"),
                                     @selector(pm_ps_mtl_supportsPrimitiveMotionBlur));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_supports_fn_ptr_imps, cls,
                                     sel_registerName("supportsFunctionPointers"),
                                     @selector(pm_ps_mtl_supportsFunctionPointers));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_supports_fn_ptr_render_imps, cls,
                                     sel_registerName("supportsFunctionPointersFromRender"),
                                     @selector(pm_ps_mtl_supportsFunctionPointersFromRender));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_supports_dyn_lib_imps, cls,
                                     sel_registerName("supportsDynamicLibraries"),
                                     @selector(pm_ps_mtl_supportsDynamicLibraries));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_supports_render_dyn_lib_imps, cls,
                                     sel_registerName("supportsRenderDynamicLibraries"),
                                     @selector(pm_ps_mtl_supportsRenderDynamicLibraries));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_supports_pull_interp_imps, cls,
                                     sel_registerName("supportsPullModelInterpolation"),
                                     @selector(pm_ps_mtl_supportsPullModelInterpolation));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_supports_barycentric_imps, cls,
                                     sel_registerName("supportsShaderBarycentricCoordinates"),
                                     @selector(pm_ps_mtl_supportsShaderBarycentricCoordinates));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_supports_query_lod_imps, cls,
                                     sel_registerName("supportsQueryTextureLOD"),
                                     @selector(pm_ps_mtl_supportsQueryTextureLOD));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_max_threads_tg_imps, cls,
                                     sel_registerName("maxThreadsPerThreadgroup"),
                                     @selector(pm_ps_mtl_maxThreadsPerThreadgroup));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_max_tg_mem_imps, cls,
                                     sel_registerName("maxThreadgroupMemoryLength"),
                                     @selector(pm_ps_mtl_maxThreadgroupMemoryLength));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_architecture_imps, cls,
                                     sel_registerName("architecture"),
                                     @selector(pm_ps_mtl_architecture));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_lib_sync_imps, cls,
                                     sel_registerName("newLibraryWithSource:options:error:"),
                                     @selector(pm_ps_mtl_newLibraryWithSource:options:error:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_lib_async_imps, cls,
                                     sel_registerName("newLibraryWithSource:options:completionHandler:"),
                                     @selector(pm_ps_mtl_newLibraryWithSource:options:completionHandler:));
}

__attribute__((visibility("hidden"))) void ps_install_metal_hooks_if_loaded(void) {
    ps_swizzle_mtl_compile_options_if_loaded();
    typedef CFTypeRef (*ps_mtl_create_default_fn)(void);
    ps_mtl_create_default_fn mtlCreateDefault = (ps_mtl_create_default_fn)dlsym(RTLD_DEFAULT, "MTLCreateSystemDefaultDevice");
#if TARGET_OS_MACCATALYST
    typedef CFArrayRef (*ps_mtl_copy_all_fn)(void);
    ps_mtl_copy_all_fn mtlCopyAll = (ps_mtl_copy_all_fn)dlsym(RTLD_DEFAULT, "MTLCopyAllDevices");
#else
    void *mtlCopyAll = NULL;
#endif
    if (mtlCreateDefault != NULL || mtlCopyAll != NULL) {
        static dispatch_once_t mtlOnce;
        dispatch_once(&mtlOnce, ^{
            PT_DEBUG_TRACE("graphics", "installing Metal hooks");
            if (mtlCreateDefault != NULL) {
                CFTypeRef devRef = mtlCreateDefault();
                if (devRef != NULL) {
                    id dev = CFBridgingRelease(devRef);
                    if (dev != nil) {
                        ps_swizzle_mtl_device_class(object_getClass(dev));
                    }
                }
            }
#if TARGET_OS_MACCATALYST
            if (mtlCopyAll != NULL) {
                CFArrayRef devsRef = mtlCopyAll();
                if (devsRef != NULL) {
                    NSArray *devices = CFBridgingRelease(devsRef);
                    for (id dev in devices) {
                        if (dev != nil) {
                            ps_swizzle_mtl_device_class(object_getClass(dev));
                        }
                    }
                }
            }
#endif
        });
    }
}


static void (*s_orig_dl_setPreferredFrameRateRange)(id, SEL, CAFrameRateRange) = NULL;
static CAFrameRateRange (*s_orig_dl_preferredFrameRateRange)(id, SEL) = NULL;
static void (*s_orig_dl_setPreferredFramesPerSecond)(id, SEL, NSInteger) = NULL;
static NSInteger (*s_orig_dl_preferredFramesPerSecond)(id, SEL) = NULL;
static void (*s_orig_dl_addToRunLoopForMode)(id, SEL, NSRunLoop *, NSRunLoopMode) = NULL;

static void (*s_orig_mtkview_setPreferredFramesPerSecond)(id, SEL, NSInteger) = NULL;
static NSInteger (*s_orig_mtkview_preferredFramesPerSecond)(id, SEL) = NULL;
static void (*s_orig_mtkview_didMoveToWindow)(id, SEL) = NULL;

static NSInteger ps_effective_target_frame_rate_hz(void) {
    NSInteger explicitHz = [[PlaySettings shared] targetFrameRateHz];
    if (explicitHz > 0) {
        return explicitHz;
    }
    if (![PTSafeMode isActive] && pt_is_bypass_enabled()) {
        uint32_t devMax = pt_get_device_max_fps();
        if (devMax > 0U) {
            return (NSInteger)devMax;
        }
    }
    return 0;
}

static CAFrameRateRange ps_clamped_frame_rate_range(CAFrameRateRange range, NSInteger capHz) {
    if (capHz <= 0) {
        return range;
    }
    float cap = (float)capHz;
    float clippedMax = (!isfinite(range.maximum) || range.maximum <= 0.0f) ? cap : fminf(range.maximum, cap);
    float clippedMin = (!isfinite(range.minimum) || range.minimum <= 0.0f) ? clippedMax : fminf(range.minimum, clippedMax);
    float clippedPref = (!isfinite(range.preferred) || range.preferred <= 0.0f)
        ? clippedMax
        : fminf(fmaxf(range.preferred, clippedMin), clippedMax);
    return (CAFrameRateRange){ clippedMin, clippedMax, clippedPref };
}

static NSInteger ps_clamped_legacy_fps(NSInteger fps, NSInteger capHz) {
    if (capHz <= 0) {
        return fps;
    }
    if (fps <= 0) {
        return capHz;
    }
    return (fps < capHz) ? fps : capHz;
}

static IMP ps_replace_method_with_c_hook(Class cls, SEL sel, IMP hookIMP) {
    if (cls == Nil || sel == NULL || hookIMP == NULL) {
        return NULL;
    }
    Method m = class_getInstanceMethod(cls, sel);
    if (m == NULL) {
        return NULL;
    }
    IMP origBefore = method_getImplementation(m);
    IMP prev = class_replaceMethod(cls, sel, hookIMP, method_getTypeEncoding(m));
    IMP orig = prev ?: origBefore;
    if (orig != NULL) {
        pt_register_swizzled_imp((const void *)hookIMP, (const void *)orig);
    }
    return orig;
}

static void ps_hook_dl_setPreferredFrameRateRange(id self, SEL _cmd, CAFrameRateRange range) {
    NSInteger capHz = ps_effective_target_frame_rate_hz();
    if (capHz > 0 && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        CAFrameRateRange clamped = ps_clamped_frame_rate_range(range, capHz);
        PT_DEBUG_TRACE("graphics",
                       "CADisplayLink setPreferredFrameRateRange cap=%ld (%.1f,%.1f,%.1f)->(%.1f,%.1f,%.1f)",
                       (long)capHz,
                       range.minimum, range.maximum, range.preferred,
                       clamped.minimum, clamped.maximum, clamped.preferred);
        range = clamped;
    }
    if (s_orig_dl_setPreferredFrameRateRange != NULL) {
        s_orig_dl_setPreferredFrameRateRange(self, _cmd, range);
    }
}

static void ps_hook_dl_setPreferredFramesPerSecond(id self, SEL _cmd, NSInteger fps) {
    NSInteger capHz = ps_effective_target_frame_rate_hz();
    if (capHz > 0 && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        NSInteger clamped = ps_clamped_legacy_fps(fps, capHz);
        PT_DEBUG_TRACE("graphics",
                       "CADisplayLink setPreferredFramesPerSecond cap=%ld %ld->%ld",
                       (long)capHz, (long)fps, (long)clamped);
        fps = clamped;
    }
    if (s_orig_dl_setPreferredFramesPerSecond != NULL) {
        s_orig_dl_setPreferredFramesPerSecond(self, _cmd, fps);
    }
}

static void ps_hook_dl_addToRunLoopForMode(id self, SEL _cmd, NSRunLoop *runloop, NSRunLoopMode mode) {
    NSInteger capHz = ps_effective_target_frame_rate_hz();
    if (capHz > 0 && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        CAFrameRateRange curRange = { 0.0f, 0.0f, 0.0f };
        if (s_orig_dl_preferredFrameRateRange != NULL) {
            curRange = s_orig_dl_preferredFrameRateRange(self, sel_registerName("preferredFrameRateRange"));
        }
        NSInteger curLegacyFPS = 0;
        if (s_orig_dl_preferredFramesPerSecond != NULL) {
            curLegacyFPS = s_orig_dl_preferredFramesPerSecond(self, sel_registerName("preferredFramesPerSecond"));
        }
        BOOL keepLowerLegacyFPS = (curRange.maximum <= 0.0f && curLegacyFPS > 0 && curLegacyFPS < capHz);
        if (!keepLowerLegacyFPS && s_orig_dl_setPreferredFrameRateRange != NULL) {
            CAFrameRateRange clamped = ps_clamped_frame_rate_range(curRange, capHz);
            PT_DEBUG_TRACE("graphics",
                           "CADisplayLink addToRunLoop cap=%ld -> (%.1f,%.1f,%.1f)",
                           (long)capHz, clamped.minimum, clamped.maximum, clamped.preferred);
            s_orig_dl_setPreferredFrameRateRange(self, sel_registerName("setPreferredFrameRateRange:"), clamped);
        }
    }
    if (s_orig_dl_addToRunLoopForMode != NULL) {
        s_orig_dl_addToRunLoopForMode(self, _cmd, runloop, mode);
    }
}

static void ps_hook_mtkview_setPreferredFramesPerSecond(id self, SEL _cmd, NSInteger fps) {
    NSInteger capHz = ps_effective_target_frame_rate_hz();
    if (capHz > 0 && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        NSInteger clamped = ps_clamped_legacy_fps(fps, capHz);
        PT_DEBUG_TRACE("graphics",
                       "MTKView setPreferredFramesPerSecond cap=%ld %ld->%ld",
                       (long)capHz, (long)fps, (long)clamped);
        fps = clamped;
    }
    if (s_orig_mtkview_setPreferredFramesPerSecond != NULL) {
        s_orig_mtkview_setPreferredFramesPerSecond(self, _cmd, fps);
    }
}

static void ps_hook_mtkview_didMoveToWindow(id self, SEL _cmd) {
    if (s_orig_mtkview_didMoveToWindow != NULL) {
        s_orig_mtkview_didMoveToWindow(self, _cmd);
    }
    NSInteger capHz = ps_effective_target_frame_rate_hz();
    if (capHz > 0 && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        NSInteger curFPS = 0;
        if (s_orig_mtkview_preferredFramesPerSecond != NULL) {
            curFPS = s_orig_mtkview_preferredFramesPerSecond(self, sel_registerName("preferredFramesPerSecond"));
        }
        NSInteger clamped = ps_clamped_legacy_fps(curFPS, capHz);
        if (clamped != curFPS && s_orig_mtkview_setPreferredFramesPerSecond != NULL) {
            PT_DEBUG_TRACE("graphics",
                           "MTKView didMoveToWindow cap=%ld %ld->%ld",
                           (long)capHz, (long)curFPS, (long)clamped);
            s_orig_mtkview_setPreferredFramesPerSecond(self, sel_registerName("setPreferredFramesPerSecond:"), clamped);
        }
    }
}

static void ps_install_display_link_hooks_if_loaded(void) {
    Class dlCls = objc_getClass("CADisplayLink");
    if (dlCls == Nil) {
        return;
    }
    static dispatch_once_t dlOnce;
    dispatch_once(&dlOnce, ^{
        PT_DEBUG_TRACE("graphics", "installing CADisplayLink frame rate hooks");
        Method mGetRange = class_getInstanceMethod(dlCls, sel_registerName("preferredFrameRateRange"));
        if (mGetRange != NULL) {
            s_orig_dl_preferredFrameRateRange = (CAFrameRateRange (*)(id, SEL))method_getImplementation(mGetRange);
        }
        Method mGetFPS = class_getInstanceMethod(dlCls, sel_registerName("preferredFramesPerSecond"));
        if (mGetFPS != NULL) {
            s_orig_dl_preferredFramesPerSecond = (NSInteger (*)(id, SEL))method_getImplementation(mGetFPS);
        }
        s_orig_dl_setPreferredFrameRateRange = (void (*)(id, SEL, CAFrameRateRange))ps_replace_method_with_c_hook(
            dlCls, sel_registerName("setPreferredFrameRateRange:"), (IMP)ps_hook_dl_setPreferredFrameRateRange);
        s_orig_dl_setPreferredFramesPerSecond = (void (*)(id, SEL, NSInteger))ps_replace_method_with_c_hook(
            dlCls, sel_registerName("setPreferredFramesPerSecond:"), (IMP)ps_hook_dl_setPreferredFramesPerSecond);
        s_orig_dl_addToRunLoopForMode = (void (*)(id, SEL, NSRunLoop *, NSRunLoopMode))ps_replace_method_with_c_hook(
            dlCls, sel_registerName("addToRunLoop:forMode:"), (IMP)ps_hook_dl_addToRunLoopForMode);
    });
}

static void ps_install_mtkview_frame_rate_hooks_if_loaded(void) {
    Class mtkCls = objc_getClass("MTKView");
    if (mtkCls == Nil) {
        static dispatch_once_t obsOnce;
        dispatch_once(&obsOnce, ^{
            [[NSNotificationCenter defaultCenter] addObserverForName:NSBundleDidLoadNotification
                                                              object:nil
                                                               queue:nil
                                                          usingBlock:^(NSNotification * _Nonnull note) {
                (void)note;
                if (objc_getClass("MTKView") != Nil) {
                    ps_install_mtkview_frame_rate_hooks_if_loaded();
                }
            }];
        });
        return;
    }
    static dispatch_once_t mtkOnce;
    dispatch_once(&mtkOnce, ^{
        PT_DEBUG_TRACE("graphics", "installing MTKView frame rate hooks");
        Method mGetFPS = class_getInstanceMethod(mtkCls, sel_registerName("preferredFramesPerSecond"));
        if (mGetFPS != NULL) {
            s_orig_mtkview_preferredFramesPerSecond = (NSInteger (*)(id, SEL))method_getImplementation(mGetFPS);
        }
        s_orig_mtkview_setPreferredFramesPerSecond = (void (*)(id, SEL, NSInteger))ps_replace_method_with_c_hook(
            mtkCls, sel_registerName("setPreferredFramesPerSecond:"), (IMP)ps_hook_mtkview_setPreferredFramesPerSecond);
        s_orig_mtkview_didMoveToWindow = (void (*)(id, SEL))ps_replace_method_with_c_hook(
            mtkCls, sel_registerName("didMoveToWindow"), (IMP)ps_hook_mtkview_didMoveToWindow);
    });
}

void pt_install_frame_rate_hooks_if_loaded(void) {
    ps_install_display_link_hooks_if_loaded();
    ps_install_mtkview_frame_rate_hooks_if_loaded();
}

void pt_install_graphics_hooks_if_loaded(void) {

    ps_install_metal_hooks_if_loaded();
    pt_install_frame_rate_hooks_if_loaded();

}
