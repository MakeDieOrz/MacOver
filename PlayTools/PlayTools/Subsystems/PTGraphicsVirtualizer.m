//
//  PTGraphicsVirtualizer.m
//  PlayTools
//

#import "PSInternal.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

typedef NS_ENUM(NSUInteger, PSMTLEncoderStage) {
    PSMTLEncoderStageCompute = 0,
    PSMTLEncoderStageFragment = 1,
    PSMTLEncoderStageVertex = 2,
};

@interface PSMTLSamplerBindEntry : NSObject {
@public
    id _sampler;
    BOOL _hasLod;
    float _lodMin;
    float _lodMax;
}
@end

@implementation PSMTLSamplerBindEntry
@end

@interface PSMTLEncoderBindingState : NSObject {
@public
    NSMutableSet<NSNumber *> *_tex32FSlots;
    NSMutableDictionary<NSNumber *, PSMTLSamplerBindEntry *> *_samplersByStageSlot;
}
@end

@implementation PSMTLEncoderBindingState
- (instancetype) init {
    self = [super init];
    if (self != nil) {
        _tex32FSlots = [[NSMutableSet alloc] init];
        _samplersByStageSlot = [[NSMutableDictionary alloc] init];
    }
    return self;
}
@end

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
static CFMutableDictionaryRef s_mtl_orig_supports_counter_sampling_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_counter_sets_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_sparse_tile_size_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_raster_order_groups_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_max_threads_tg_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_max_tg_mem_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_architecture_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_arch_name_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_lib_sync_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_lib_async_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_texture_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_sampler_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_cmdqueue_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_cmdqueue_cnt_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_dynlib_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_binarch_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_accel_struct_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_counter_buf_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_intersect_tbl_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_cq_cmdbuf_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_cq_cmdbuf_unret_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_cb_comp_enc_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_cb_comp_enc_desc_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_cb_comp_enc_disp_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_cb_rend_enc_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_cenc_set_tex_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_cenc_set_texs_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_cenc_set_samp_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_cenc_set_samp_lod_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_cenc_set_samps_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_renc_set_ftex_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_renc_set_ftexs_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_renc_set_fsamp_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_renc_set_fsamp_lod_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_renc_set_fsamps_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_renc_set_vtex_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_renc_set_vtexs_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_renc_set_vsamp_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_renc_set_vsamp_lod_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_renc_set_vsamps_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_opts_langver_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_opts_set_langver_imps = NULL;
static CFMutableSetRef s_mtl_swizzled_classes = NULL;
static const char kPSMTLCompileOptionsExplicitLangVerKey = 0;
static const char kPSMTLTextureIs32FKey = 0;
static const char kPSMTLSamplerNearestFallbackKey = 0;
static const char kPSMTLEncoderStateKey = 0;

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

static NSString *pt_mtl_format_missing_header_diagnostic(NSString *source, NSString *headerName) {
    NSString *bracketed = [NSString stringWithFormat:@"<%@>", headerName];
    NSRange hdrRange = [source rangeOfString:bracketed];
    if (hdrRange.location == NSNotFound) {
        hdrRange = [source rangeOfString:headerName];
    }
    if (hdrRange.location == NSNotFound) {
        return nil;
    }
    NSUInteger line = 1, col = 10;
    pt_mtl_line_and_col_for_location(source, hdrRange.location, &line, &col);
    NSRange lineRange = [source lineRangeForRange:NSMakeRange(hdrRange.location, 0)];
    NSString *srcLine = [[source substringWithRange:lineRange]
        stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableString *caret = [NSMutableString stringWithCapacity:(col + hdrRange.length + 1)];
    NSUInteger col0 = (col > 0) ? (col - 1) : 0;
    for (NSUInteger i = 0; i < col0; i++) {
        unichar ch = (i < srcLine.length) ? [srcLine characterAtIndex:i] : ' ';
        [caret appendString:(ch == '\t') ? @"\t" : @" "];
    }
    [caret appendString:@"^"];
    NSUInteger tildes = (hdrRange.length > 1) ? (hdrRange.length - 1) : (headerName.length + 1);
    for (NSUInteger i = 0; i < tildes; i++) {
        [caret appendString:@"~"];
    }
    return [NSString stringWithFormat:
            @"program_source:%lu:%lu: fatal error: '%@' file not found\n%@\n%@",
            (unsigned long)line,
            (unsigned long)col,
            headerName,
            srcLine.length > 0 ? srcLine : [NSString stringWithFormat:@"#include %@", bracketed],
            caret];
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
            NSString *simdMsg = [source containsString:@"metal_simdgroup_matrix"]
                ? pt_mtl_format_missing_header_diagnostic(source, @"metal_simdgroup_matrix")
                : nil;
            NSString *rtMsg = [source containsString:@"metal_raytracing"]
                ? pt_mtl_format_missing_header_diagnostic(source, @"metal_raytracing")
                : nil;
            if (simdMsg != nil) {
                msg = simdMsg;
            } else if (rtMsg != nil) {
                msg = rtMsg;
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

static void ps_swizzle_mtl_command_queue_class(Class cls);
static void ps_swizzle_mtl_command_buffer_class(Class cls);
static void ps_swizzle_mtl_compute_encoder_class(Class cls);
static void ps_swizzle_mtl_render_encoder_class(Class cls);

static BOOL pt_mtl_class_already_swizzled(Class cls) {
    if (cls == Nil) {
        return YES;
    }
    os_unfair_lock_lock(&s_mtl_swizzle_lock);
    if (s_mtl_swizzled_classes == NULL) {
        s_mtl_swizzled_classes = CFSetCreateMutable(kCFAllocatorDefault, 0, NULL);
    }
    BOOL seen = (s_mtl_swizzled_classes != NULL && CFSetContainsValue(s_mtl_swizzled_classes, (__bridge const void *)cls));
    if (!seen && s_mtl_swizzled_classes != NULL) {
        CFSetAddValue(s_mtl_swizzled_classes, (__bridge const void *)cls);
    }
    os_unfair_lock_unlock(&s_mtl_swizzle_lock);
    return seen;
}

static NSString *pt_mtl_rewrite_source_for_apple5_32f(NSString *source, const void *caller) {
    if (source == nil || ![source isKindOfClass:[NSString class]] ||
        !pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(caller) ||
        (!pt_is_compat13_7_active() && pt_get_spoofed_max_apple_gpu_family() >= 1007)) {
        return source;
    }
    static NSRegularExpression *s_constexprSamplerRegex = nil;
    static NSRegularExpression *s_linearFilterRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_constexprSamplerRegex = [NSRegularExpression
            regularExpressionWithPattern:@"constexpr\\s+sampler\\b[^;]*;"
                                 options:NSRegularExpressionDotMatchesLineSeparators
                                   error:nil];
        s_linearFilterRegex = [NSRegularExpression
            regularExpressionWithPattern:@"\\b(min_filter|mag_filter|filter)\\s*::\\s*linear\\b"
                                 options:0
                                   error:nil];
    });
    if (s_constexprSamplerRegex == nil || s_linearFilterRegex == nil) {
        return source;
    }
    NSArray<NSTextCheckingResult *> *matches =
        [s_constexprSamplerRegex matchesInString:source options:0 range:NSMakeRange(0, source.length)];
    if (matches.count == 0) {
        return source;
    }
    NSMutableString *rewritten = nil;
    for (NSInteger i = (NSInteger)matches.count - 1; i >= 0; i--) {
        NSRange declRange = matches[(NSUInteger)i].range;
        NSString *decl = [source substringWithRange:declRange];
        NSString *patchedDecl = [s_linearFilterRegex
            stringByReplacingMatchesInString:decl
                                     options:0
                                       range:NSMakeRange(0, decl.length)
                                withTemplate:@"$1::nearest"];
        if (![patchedDecl isEqualToString:decl]) {
            if (rewritten == nil) {
                rewritten = [source mutableCopy];
            }
            [rewritten replaceCharactersInRange:declRange withString:patchedDecl];
        }
    }
    return (rewritten != nil) ? rewritten : source;
}

static void pt_mtl_prepare_options_and_source(NSString *source,
                                              id options,
                                              const void *caller,
                                              NSString **outSource,
                                              id *outOptions) {
    NSString *finalSource = source;
    id finalOptions = options;
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        if (finalSource != nil && [finalSource isKindOfClass:[NSString class]]) {
            finalSource = pt_mtl_rewrite_source_for_apple5_32f(finalSource, caller);
            if (![finalSource hasPrefix:@"#undef __METAL_MACOS__\n"]) {
                finalSource = [@"#undef __METAL_MACOS__\n#define __METAL_IOS__ 1\n#line 1\n"
                    stringByAppendingString:finalSource];
            }
        }
        if (pt_is_compat13_7_active()) {
            if (finalOptions == nil) {
                Class optsCls = NSClassFromString(@"MTLCompileOptions");
                if (optsCls != Nil) {
                    finalOptions = [optsCls new];
                }
            } else if (objc_getAssociatedObject(finalOptions, &kPSMTLCompileOptionsExplicitLangVerKey) == nil &&
                       [finalOptions respondsToSelector:@selector(copy)]) {
                finalOptions = [finalOptions copy];
            }
            if (finalOptions != nil &&
                objc_getAssociatedObject(options ?: finalOptions, &kPSMTLCompileOptionsExplicitLangVerKey) == nil) {
                SEL setLangSel = sel_registerName("setLanguageVersion:");
                if ([finalOptions respondsToSelector:setLangSel]) {
                    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(finalOptions, setLangSel, ((2U << 16) | 2U));
                }
            }
        }
    }
    if (outSource != NULL) {
        *outSource = finalSource;
    }
    if (outOptions != NULL) {
        *outOptions = finalOptions;
    }
}

static NSError *pt_mtl_make_compat13_unsupported_error(NSString *domain, NSInteger code, NSString *feature) {
    return [NSError errorWithDomain:domain
                                code:code
                            userInfo:@{
                                NSLocalizedDescriptionKey : [NSString stringWithFormat:@"%@ is unsupported on this device", feature]
                            }];
}

static inline uint64_t ps_mtl_stage_slot_key(PSMTLEncoderStage stage, NSUInteger index) {
    return (((uint64_t)stage & 0xFULL) << 32) | ((uint64_t)index & 0xFFFFFFFFULL);
}

static PSMTLEncoderBindingState *ps_mtl_encoder_state(id encoder, BOOL createIfMissing) {
    if (encoder == nil) {
        return nil;
    }
    PSMTLEncoderBindingState *state = objc_getAssociatedObject(encoder, &kPSMTLEncoderStateKey);
    if (state == nil && createIfMissing) {
        state = [[PSMTLEncoderBindingState alloc] init];
        objc_setAssociatedObject(encoder, &kPSMTLEncoderStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static void ps_mtl_encoder_apply_sampler(id encoder,
                                         PSMTLEncoderStage stage,
                                         NSUInteger index,
                                         PSMTLSamplerBindEntry *entry,
                                         id samplerToBind) {
    if (encoder == nil || entry == nil) {
        return;
    }
    CFMutableDictionaryRef dict = NULL;
    SEL sel = NULL;
    if (stage == PSMTLEncoderStageCompute) {
        dict = entry->_hasLod ? s_mtl_orig_cenc_set_samp_lod_imps : s_mtl_orig_cenc_set_samp_imps;
        sel = entry->_hasLod ? sel_registerName("setSamplerState:lodMinClamp:lodMaxClamp:atIndex:")
                             : sel_registerName("setSamplerState:atIndex:");
    } else if (stage == PSMTLEncoderStageFragment) {
        dict = entry->_hasLod ? s_mtl_orig_renc_set_fsamp_lod_imps : s_mtl_orig_renc_set_fsamp_imps;
        sel = entry->_hasLod ? sel_registerName("setFragmentSamplerState:lodMinClamp:lodMaxClamp:atIndex:")
                             : sel_registerName("setFragmentSamplerState:atIndex:");
    } else if (stage == PSMTLEncoderStageVertex) {
        dict = entry->_hasLod ? s_mtl_orig_renc_set_vsamp_lod_imps : s_mtl_orig_renc_set_vsamp_imps;
        sel = entry->_hasLod ? sel_registerName("setVertexSamplerState:lodMinClamp:lodMaxClamp:atIndex:")
                             : sel_registerName("setVertexSamplerState:atIndex:");
    }
    if (dict == NULL || sel == NULL) {
        return;
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, dict, encoder, &pushed);
    if (origIMP != NULL) {
        @try {
            if (entry->_hasLod) {
                ((void (*)(id, SEL, id, float, float, NSUInteger))origIMP)(
                    encoder, sel, samplerToBind, entry->_lodMin, entry->_lodMax, index);
            } else {
                ((void (*)(id, SEL, id, NSUInteger))origIMP)(encoder, sel, samplerToBind, index);
            }
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
}

static void ps_mtl_encoder_record_textures(id encoder,
                                           PSMTLEncoderStage stage,
                                           const id __unsafe_unretained *textures,
                                           NSRange range) {
    if (encoder == nil ||
        !pt_is_bypass_enabled() ||
        (!pt_is_compat13_7_active() && pt_get_spoofed_max_apple_gpu_family() >= 1007)) {
        return;
    }
    PSMTLEncoderBindingState *state = ps_mtl_encoder_state(encoder, YES);
    NSMutableArray *updates = nil;
    @synchronized (state) {
        BOOL had32F = (state->_tex32FSlots.count > 0);
        for (NSUInteger i = 0; i < range.length; i++) {
            id tex = (textures != NULL) ? textures[i] : nil;
            BOOL is32F = (tex != nil && objc_getAssociatedObject(tex, &kPSMTLTextureIs32FKey) != nil);
            NSNumber *slotKey = @(ps_mtl_stage_slot_key(stage, range.location + i));
            if (is32F) {
                [state->_tex32FSlots addObject:slotKey];
            } else {
                [state->_tex32FSlots removeObject:slotKey];
            }
        }
        BOOL has32F = (state->_tex32FSlots.count > 0);
        if (had32F != has32F && state->_samplersByStageSlot.count > 0) {
            updates = [NSMutableArray arrayWithCapacity:state->_samplersByStageSlot.count * 3];
            [state->_samplersByStageSlot enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, PSMTLSamplerBindEntry *entry, BOOL *stop) {
                (void)stop;
                id fallback = objc_getAssociatedObject(entry->_sampler, &kPSMTLSamplerNearestFallbackKey);
                id target = has32F ? (fallback ?: entry->_sampler) : entry->_sampler;
                if (target != nil) {
                    [updates addObject:key];
                    [updates addObject:entry];
                    [updates addObject:target];
                }
            }];
        }
    }
    for (NSUInteger i = 0; i + 2 < updates.count; i += 3) {
        uint64_t k = ((NSNumber *)updates[i]).unsignedLongLongValue;
        PSMTLEncoderStage s = (PSMTLEncoderStage)((k >> 32) & 0xFULL);
        NSUInteger idx = (NSUInteger)(k & 0xFFFFFFFFULL);
        ps_mtl_encoder_apply_sampler(encoder, s, idx, updates[i + 1], updates[i + 2]);
    }
}

static id ps_mtl_encoder_record_sampler(id encoder,
                                        PSMTLEncoderStage stage,
                                        id sampler,
                                        BOOL hasLod,
                                        float lodMin,
                                        float lodMax,
                                        NSUInteger index) {
    if (encoder == nil ||
        !pt_is_bypass_enabled() ||
        (!pt_is_compat13_7_active() && pt_get_spoofed_max_apple_gpu_family() >= 1007)) {
        return sampler;
    }
    id fallback = (sampler != nil) ? objc_getAssociatedObject(sampler, &kPSMTLSamplerNearestFallbackKey) : nil;
    PSMTLEncoderBindingState *state = ps_mtl_encoder_state(encoder, (fallback != nil));
    if (state == nil) {
        return sampler;
    }
    NSNumber *slotKey = @(ps_mtl_stage_slot_key(stage, index));
    @synchronized (state) {
        if (fallback != nil) {
            PSMTLSamplerBindEntry *entry = [[PSMTLSamplerBindEntry alloc] init];
            entry->_sampler = sampler;
            entry->_hasLod = hasLod;
            entry->_lodMin = lodMin;
            entry->_lodMax = lodMax;
            state->_samplersByStageSlot[slotKey] = entry;
            if (state->_tex32FSlots.count > 0) {
                return fallback;
            }
        } else {
            [state->_samplersByStageSlot removeObjectForKey:slotKey];
        }
    }
    return sampler;
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
        if (gpuFamily == 3002 && maxAppleFam < 1004) { // MTLGPUFamilyCommon2 requires Apple4+
            return NO;
        }
        if (gpuFamily == 3003 && maxAppleFam < 1005) { // MTLGPUFamilyCommon3 requires Apple5+
            return NO;
        }
        if (gpuFamily == 5001 && (pt_is_compat13_7_active() || maxAppleFam < 1007)) {
            // MTLGPUFamilyMetal3 introduced in iOS 16 and requires Apple7+
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
        (pt_is_compat13_7_active() || pt_get_spoofed_max_apple_gpu_family() < 1007)) {
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

- (BOOL) pm_ps_mtl_supportsCounterSampling:(NSUInteger)samplingPoint {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        (pt_is_compat13_7_active() || pt_get_spoofed_max_apple_gpu_family() < 1005)) {
        return NO;
    }
    SEL sel = sel_registerName("supportsCounterSampling:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_supports_counter_sampling_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((BOOL (*)(id, SEL, NSUInteger))origIMP)(self, sel, samplingPoint);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return NO;
}

- (NSArray *) pm_ps_mtl_counterSets {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_compat13_7_active()) {
        return nil;
    }
    SEL sel = sel_registerName("counterSets");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_counter_sets_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((NSArray *(*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return nil;
}

- (NSUInteger) pm_ps_mtl_sparseTileSizeInBytes {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_get_spoofed_max_apple_gpu_family() <= 1005) {
        return 0U;
    }
    SEL sel = sel_registerName("sparseTileSizeInBytes");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_sparse_tile_size_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            return ((NSUInteger (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return 0U;
}

- (BOOL) pm_ps_mtl_rasterOrderGroupsSupported {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_get_spoofed_max_apple_gpu_family() <= 1003) {
        return NO;
    }
    SEL sel = sel_registerName("areRasterOrderGroupsSupported");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_raster_order_groups_imps, self, &pushed);
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
    const void *caller = __builtin_return_address(0);
    if (!ps_is_effective_system_or_playtools_caller(caller)) {
        NSError *rejectError = nil;
        if (pt_mtl_should_reject_source_for_compat13(source, options, &rejectError)) {
            if (error != NULL) {
                *error = rejectError;
            }
            return nil;
        }
        pt_mtl_prepare_options_and_source(source, options, caller, &source, &options);
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
    const void *caller = __builtin_return_address(0);
    if (!ps_is_effective_system_or_playtools_caller(caller)) {
        NSError *rejectError = nil;
        if (pt_mtl_should_reject_source_for_compat13(source, options, &rejectError)) {
            if (completionHandler != nil) {
                completionHandler(nil, rejectError);
            }
            return;
        }
        pt_mtl_prepare_options_and_source(source, options, caller, &source, &options);
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

- (id) pm_ps_mtl_newTextureWithDescriptor:(id)descriptor NS_RETURNS_RETAINED {
    const void *caller = __builtin_return_address(0);
    SEL sel = sel_registerName("newTextureWithDescriptor:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_texture_imps, self, &pushed);
    id tex = nil;
    if (origIMP != NULL) {
        typedef id (*PTMTLNewTexOrigFn)(id, SEL, id) NS_RETURNS_RETAINED;
        @try {
            tex = ((PTMTLNewTexOrigFn)origIMP)(self, sel, descriptor);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (tex != nil && descriptor != nil &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(caller)) {
        SEL pfSel = sel_registerName("pixelFormat");
        if ([descriptor respondsToSelector:pfSel]) {
            NSUInteger pf = ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, pfSel);
            if (pf == 55U || pf == 105U || pf == 125U) {
                objc_setAssociatedObject(tex, &kPSMTLTextureIs32FKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
    return tex;
}

- (id) pm_ps_mtl_newSamplerStateWithDescriptor:(id)descriptor NS_RETURNS_RETAINED {
    const void *caller = __builtin_return_address(0);
    SEL sel = sel_registerName("newSamplerStateWithDescriptor:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_sampler_imps, self, &pushed);
    id sampler = nil;
    typedef id (*PTMTLNewSamplerOrigFn)(id, SEL, id) NS_RETURNS_RETAINED;
    if (origIMP != NULL) {
        @try {
            sampler = ((PTMTLNewSamplerOrigFn)origIMP)(self, sel, descriptor);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (origIMP != NULL && sampler != nil && descriptor != nil &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(caller) &&
        (pt_is_compat13_7_active() || pt_get_spoofed_max_apple_gpu_family() < 1007) &&
        [descriptor respondsToSelector:@selector(copy)]) {
        SEL minSel = sel_registerName("minFilter");
        SEL magSel = sel_registerName("magFilter");
        SEL mipSel = sel_registerName("mipFilter");
        NSUInteger minF = [descriptor respondsToSelector:minSel] ? ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, minSel) : 0U;
        NSUInteger magF = [descriptor respondsToSelector:magSel] ? ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, magSel) : 0U;
        NSUInteger mipF = [descriptor respondsToSelector:mipSel] ? ((NSUInteger (*)(id, SEL))objc_msgSend)(descriptor, mipSel) : 0U;
        if (minF == 1U || magF == 1U || mipF == 2U) {
            id patchedDesc = [descriptor copy];
            if (patchedDesc != nil) {
                SEL setMinSel = sel_registerName("setMinFilter:");
                SEL setMagSel = sel_registerName("setMagFilter:");
                SEL setMipSel = sel_registerName("setMipFilter:");
                if (minF == 1U && [patchedDesc respondsToSelector:setMinSel]) {
                    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(patchedDesc, setMinSel, 0U);
                }
                if (magF == 1U && [patchedDesc respondsToSelector:setMagSel]) {
                    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(patchedDesc, setMagSel, 0U);
                }
                if (mipF == 2U && [patchedDesc respondsToSelector:setMipSel]) {
                    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(patchedDesc, setMipSel, 1U);
                }
                BOOL pushedFallback = NO;
                IMP fallbackIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_sampler_imps, self, &pushedFallback);
                if (fallbackIMP != NULL) {
                    id fallback = nil;
                    @try {
                        fallback = ((PTMTLNewSamplerOrigFn)fallbackIMP)(self, sel, patchedDesc);
                    } @finally {
                        ps_pop_orig_imp_frame(pushedFallback);
                    }
                    if (fallback != nil) {
                        objc_setAssociatedObject(sampler, &kPSMTLSamplerNearestFallbackKey, fallback,
                                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    }
                }
            }
        }
    }
    return sampler;
}

- (id) pm_ps_mtl_newCommandQueue NS_RETURNS_RETAINED {
    SEL sel = sel_registerName("newCommandQueue");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_cmdqueue_imps, self, &pushed);
    id queue = nil;
    if (origIMP != NULL) {
        typedef id (*PTMTLNewCQOrigFn)(id, SEL) NS_RETURNS_RETAINED;
        @try {
            queue = ((PTMTLNewCQOrigFn)origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (queue != nil) {
        ps_swizzle_mtl_command_queue_class(object_getClass(queue));
    }
    return queue;
}

- (id) pm_ps_mtl_newCommandQueueWithMaxCommandBufferCount:(NSUInteger)count NS_RETURNS_RETAINED {
    SEL sel = sel_registerName("newCommandQueueWithMaxCommandBufferCount:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_cmdqueue_cnt_imps, self, &pushed);
    id queue = nil;
    if (origIMP != NULL) {
        typedef id (*PTMTLNewCQCntOrigFn)(id, SEL, NSUInteger) NS_RETURNS_RETAINED;
        @try {
            queue = ((PTMTLNewCQCntOrigFn)origIMP)(self, sel, count);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (queue != nil) {
        ps_swizzle_mtl_command_queue_class(object_getClass(queue));
    }
    return queue;
}

- (id) pm_ps_mtl_newDynamicLibrary:(id)library error:(NSError **)error NS_RETURNS_RETAINED {
    if (pt_is_bypass_enabled() &&
        pt_is_compat13_7_active() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (error != NULL) {
            *error = pt_mtl_make_compat13_unsupported_error(@"MTLLibraryErrorDomain", 1, @"Dynamic Metal libraries");
        }
        return nil;
    }
    SEL sel = sel_registerName("newDynamicLibrary:error:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_dynlib_imps, self, &pushed);
    if (origIMP != NULL) {
        typedef id (*PTMTLNewDynLibOrigFn)(id, SEL, id, NSError **) NS_RETURNS_RETAINED;
        @try {
            return ((PTMTLNewDynLibOrigFn)origIMP)(self, sel, library, error);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return nil;
}

- (id) pm_ps_mtl_newBinaryArchiveWithDescriptor:(id)descriptor error:(NSError **)error NS_RETURNS_RETAINED {
    if (pt_is_bypass_enabled() &&
        pt_is_compat13_7_active() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (error != NULL) {
            *error = pt_mtl_make_compat13_unsupported_error(@"MTLBinaryArchiveErrorDomain", 1, @"Binary archives");
        }
        return nil;
    }
    SEL sel = sel_registerName("newBinaryArchiveWithDescriptor:error:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_binarch_imps, self, &pushed);
    if (origIMP != NULL) {
        typedef id (*PTMTLNewBinArchOrigFn)(id, SEL, id, NSError **) NS_RETURNS_RETAINED;
        @try {
            return ((PTMTLNewBinArchOrigFn)origIMP)(self, sel, descriptor, error);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return nil;
}

- (id) pm_ps_mtl_newAccelerationStructureWithDescriptor:(id)descriptor NS_RETURNS_RETAINED {
    if (pt_is_bypass_enabled() &&
        pt_is_compat13_7_active() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return nil;
    }
    SEL sel = sel_registerName("newAccelerationStructureWithDescriptor:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_accel_struct_imps, self, &pushed);
    if (origIMP != NULL) {
        typedef id (*PTMTLNewAccelOrigFn)(id, SEL, id) NS_RETURNS_RETAINED;
        @try {
            return ((PTMTLNewAccelOrigFn)origIMP)(self, sel, descriptor);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return nil;
}

- (id) pm_ps_mtl_newCounterSampleBufferWithDescriptor:(id)descriptor error:(NSError **)error NS_RETURNS_RETAINED {
    if (pt_is_bypass_enabled() &&
        pt_is_compat13_7_active() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        if (error != NULL) {
            *error = pt_mtl_make_compat13_unsupported_error(@"MTLCounterErrorDomain", 1, @"Counter sample buffers");
        }
        return nil;
    }
    SEL sel = sel_registerName("newCounterSampleBufferWithDescriptor:error:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_counter_buf_imps, self, &pushed);
    if (origIMP != NULL) {
        typedef id (*PTMTLNewCounterOrigFn)(id, SEL, id, NSError **) NS_RETURNS_RETAINED;
        @try {
            return ((PTMTLNewCounterOrigFn)origIMP)(self, sel, descriptor, error);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return nil;
}

- (id) pm_ps_mtl_newIntersectionFunctionTableWithDescriptor:(id)descriptor NS_RETURNS_RETAINED {
    if (pt_is_bypass_enabled() &&
        pt_is_compat13_7_active() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return nil;
    }
    SEL sel = sel_registerName("newIntersectionFunctionTableWithDescriptor:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_intersect_tbl_imps, self, &pushed);
    if (origIMP != NULL) {
        typedef id (*PTMTLNewIntersectOrigFn)(id, SEL, id) NS_RETURNS_RETAINED;
        @try {
            return ((PTMTLNewIntersectOrigFn)origIMP)(self, sel, descriptor);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return nil;
}

- (id) pm_ps_mtl_cq_commandBuffer {
    SEL sel = sel_registerName("commandBuffer");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_cq_cmdbuf_imps, self, &pushed);
    id cb = nil;
    if (origIMP != NULL) {
        @try {
            cb = ((id (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (cb != nil) {
        ps_swizzle_mtl_command_buffer_class(object_getClass(cb));
    }
    return cb;
}

- (id) pm_ps_mtl_cq_commandBufferWithUnretainedReferences {
    SEL sel = sel_registerName("commandBufferWithUnretainedReferences");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_cq_cmdbuf_unret_imps, self, &pushed);
    id cb = nil;
    if (origIMP != NULL) {
        @try {
            cb = ((id (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (cb != nil) {
        ps_swizzle_mtl_command_buffer_class(object_getClass(cb));
    }
    return cb;
}

- (id) pm_ps_mtl_cb_computeCommandEncoder {
    SEL sel = sel_registerName("computeCommandEncoder");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_cb_comp_enc_imps, self, &pushed);
    id enc = nil;
    if (origIMP != NULL) {
        @try {
            enc = ((id (*)(id, SEL))origIMP)(self, sel);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (enc != nil) {
        ps_swizzle_mtl_compute_encoder_class(object_getClass(enc));
    }
    return enc;
}

- (id) pm_ps_mtl_cb_computeCommandEncoderWithDescriptor:(id)descriptor {
    SEL sel = sel_registerName("computeCommandEncoderWithDescriptor:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_cb_comp_enc_desc_imps, self, &pushed);
    id enc = nil;
    if (origIMP != NULL) {
        @try {
            enc = ((id (*)(id, SEL, id))origIMP)(self, sel, descriptor);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (enc != nil) {
        ps_swizzle_mtl_compute_encoder_class(object_getClass(enc));
    }
    return enc;
}

- (id) pm_ps_mtl_cb_computeCommandEncoderWithDispatchType:(NSUInteger)dispatchType {
    SEL sel = sel_registerName("computeCommandEncoderWithDispatchType:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_cb_comp_enc_disp_imps, self, &pushed);
    id enc = nil;
    if (origIMP != NULL) {
        @try {
            enc = ((id (*)(id, SEL, NSUInteger))origIMP)(self, sel, dispatchType);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (enc != nil) {
        ps_swizzle_mtl_compute_encoder_class(object_getClass(enc));
    }
    return enc;
}

- (id) pm_ps_mtl_cb_renderCommandEncoderWithDescriptor:(id)descriptor {
    SEL sel = sel_registerName("renderCommandEncoderWithDescriptor:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_cb_rend_enc_imps, self, &pushed);
    id enc = nil;
    if (origIMP != NULL) {
        @try {
            enc = ((id (*)(id, SEL, id))origIMP)(self, sel, descriptor);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (enc != nil) {
        ps_swizzle_mtl_render_encoder_class(object_getClass(enc));
    }
    return enc;
}

- (void) pm_ps_mtl_cenc_setTexture:(id)texture atIndex:(NSUInteger)index {
    const void *caller = __builtin_return_address(0);
    SEL sel = sel_registerName("setTexture:atIndex:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_cenc_set_tex_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, id, NSUInteger))origIMP)(self, sel, texture, index);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (!ps_is_effective_system_or_playtools_caller(caller)) {
        id __unsafe_unretained singleTex = texture;
        ps_mtl_encoder_record_textures(self, PSMTLEncoderStageCompute, &singleTex, NSMakeRange(index, 1));
    }
}

- (void) pm_ps_mtl_cenc_setTextures:(const id __unsafe_unretained *)textures withRange:(NSRange)range {
    const void *caller = __builtin_return_address(0);
    SEL sel = sel_registerName("setTextures:withRange:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_cenc_set_texs_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, const id __unsafe_unretained *, NSRange))origIMP)(self, sel, textures, range);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (!ps_is_effective_system_or_playtools_caller(caller) && range.length > 0) {
        ps_mtl_encoder_record_textures(self, PSMTLEncoderStageCompute, textures, range);
    }
}

- (void) pm_ps_mtl_cenc_setSamplerState:(id)sampler atIndex:(NSUInteger)index {
    const void *caller = __builtin_return_address(0);
    id effSampler = ps_is_effective_system_or_playtools_caller(caller)
        ? sampler
        : ps_mtl_encoder_record_sampler(self, PSMTLEncoderStageCompute, sampler, NO, 0.0f, 0.0f, index);
    SEL sel = sel_registerName("setSamplerState:atIndex:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_cenc_set_samp_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, id, NSUInteger))origIMP)(self, sel, effSampler, index);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
}

- (void) pm_ps_mtl_cenc_setSamplerState:(id)sampler
                            lodMinClamp:(float)lodMinClamp
                            lodMaxClamp:(float)lodMaxClamp
                                atIndex:(NSUInteger)index {
    const void *caller = __builtin_return_address(0);
    id effSampler = ps_is_effective_system_or_playtools_caller(caller)
        ? sampler
        : ps_mtl_encoder_record_sampler(self, PSMTLEncoderStageCompute, sampler, YES, lodMinClamp, lodMaxClamp, index);
    SEL sel = sel_registerName("setSamplerState:lodMinClamp:lodMaxClamp:atIndex:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_cenc_set_samp_lod_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, id, float, float, NSUInteger))origIMP)(
                self, sel, effSampler, lodMinClamp, lodMaxClamp, index);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
}

- (void) pm_ps_mtl_cenc_setSamplerStates:(const id __unsafe_unretained *)samplers withRange:(NSRange)range {
    const void *caller = __builtin_return_address(0);
    SEL sel = sel_registerName("setSamplerStates:withRange:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_cenc_set_samps_imps, self, &pushed);
    if (origIMP == NULL) {
        return;
    }
    const id __unsafe_unretained *effSamplers = samplers;
    if (!ps_is_effective_system_or_playtools_caller(caller) && samplers != NULL && range.length > 0 && range.length <= 256) {
        id __unsafe_unretained stackBuf[256];
        BOOL changed = NO;
        for (NSUInteger i = 0; i < range.length; i++) {
            id origS = samplers[i];
            id effS = ps_mtl_encoder_record_sampler(self, PSMTLEncoderStageCompute, origS, NO, 0.0f, 0.0f, range.location + i);
            stackBuf[i] = effS;
            if (effS != origS) {
                changed = YES;
            }
        }
        effSamplers = changed ? stackBuf : samplers;
        @try {
            ((void (*)(id, SEL, const id __unsafe_unretained *, NSRange))origIMP)(self, sel, effSamplers, range);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
        return;
    }
    @try {
        ((void (*)(id, SEL, const id __unsafe_unretained *, NSRange))origIMP)(self, sel, samplers, range);
    } @finally {
        ps_pop_orig_imp_frame(pushed);
    }
}

- (void) pm_ps_mtl_renc_setFragmentTexture:(id)texture atIndex:(NSUInteger)index {
    const void *caller = __builtin_return_address(0);
    SEL sel = sel_registerName("setFragmentTexture:atIndex:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_renc_set_ftex_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, id, NSUInteger))origIMP)(self, sel, texture, index);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (!ps_is_effective_system_or_playtools_caller(caller)) {
        id __unsafe_unretained singleTex = texture;
        ps_mtl_encoder_record_textures(self, PSMTLEncoderStageFragment, &singleTex, NSMakeRange(index, 1));
    }
}

- (void) pm_ps_mtl_renc_setFragmentTextures:(const id __unsafe_unretained *)textures withRange:(NSRange)range {
    const void *caller = __builtin_return_address(0);
    SEL sel = sel_registerName("setFragmentTextures:withRange:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_renc_set_ftexs_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, const id __unsafe_unretained *, NSRange))origIMP)(self, sel, textures, range);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (!ps_is_effective_system_or_playtools_caller(caller) && range.length > 0) {
        ps_mtl_encoder_record_textures(self, PSMTLEncoderStageFragment, textures, range);
    }
}

- (void) pm_ps_mtl_renc_setFragmentSamplerState:(id)sampler atIndex:(NSUInteger)index {
    const void *caller = __builtin_return_address(0);
    id effSampler = ps_is_effective_system_or_playtools_caller(caller)
        ? sampler
        : ps_mtl_encoder_record_sampler(self, PSMTLEncoderStageFragment, sampler, NO, 0.0f, 0.0f, index);
    SEL sel = sel_registerName("setFragmentSamplerState:atIndex:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_renc_set_fsamp_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, id, NSUInteger))origIMP)(self, sel, effSampler, index);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
}

- (void) pm_ps_mtl_renc_setFragmentSamplerState:(id)sampler
                                    lodMinClamp:(float)lodMinClamp
                                    lodMaxClamp:(float)lodMaxClamp
                                        atIndex:(NSUInteger)index {
    const void *caller = __builtin_return_address(0);
    id effSampler = ps_is_effective_system_or_playtools_caller(caller)
        ? sampler
        : ps_mtl_encoder_record_sampler(self, PSMTLEncoderStageFragment, sampler, YES, lodMinClamp, lodMaxClamp, index);
    SEL sel = sel_registerName("setFragmentSamplerState:lodMinClamp:lodMaxClamp:atIndex:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_renc_set_fsamp_lod_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, id, float, float, NSUInteger))origIMP)(
                self, sel, effSampler, lodMinClamp, lodMaxClamp, index);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
}

- (void) pm_ps_mtl_renc_setFragmentSamplerStates:(const id __unsafe_unretained *)samplers withRange:(NSRange)range {
    const void *caller = __builtin_return_address(0);
    SEL sel = sel_registerName("setFragmentSamplerStates:withRange:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_renc_set_fsamps_imps, self, &pushed);
    if (origIMP == NULL) {
        return;
    }
    if (!ps_is_effective_system_or_playtools_caller(caller) && samplers != NULL && range.length > 0 && range.length <= 256) {
        id __unsafe_unretained stackBuf[256];
        BOOL changed = NO;
        for (NSUInteger i = 0; i < range.length; i++) {
            id origS = samplers[i];
            id effS = ps_mtl_encoder_record_sampler(self, PSMTLEncoderStageFragment, origS, NO, 0.0f, 0.0f, range.location + i);
            stackBuf[i] = effS;
            if (effS != origS) {
                changed = YES;
            }
        }
        const id __unsafe_unretained *effSamplers = changed ? stackBuf : samplers;
        @try {
            ((void (*)(id, SEL, const id __unsafe_unretained *, NSRange))origIMP)(self, sel, effSamplers, range);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
        return;
    }
    @try {
        ((void (*)(id, SEL, const id __unsafe_unretained *, NSRange))origIMP)(self, sel, samplers, range);
    } @finally {
        ps_pop_orig_imp_frame(pushed);
    }
}

- (void) pm_ps_mtl_renc_setVertexTexture:(id)texture atIndex:(NSUInteger)index {
    const void *caller = __builtin_return_address(0);
    SEL sel = sel_registerName("setVertexTexture:atIndex:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_renc_set_vtex_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, id, NSUInteger))origIMP)(self, sel, texture, index);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (!ps_is_effective_system_or_playtools_caller(caller)) {
        id __unsafe_unretained singleTex = texture;
        ps_mtl_encoder_record_textures(self, PSMTLEncoderStageVertex, &singleTex, NSMakeRange(index, 1));
    }
}

- (void) pm_ps_mtl_renc_setVertexTextures:(const id __unsafe_unretained *)textures withRange:(NSRange)range {
    const void *caller = __builtin_return_address(0);
    SEL sel = sel_registerName("setVertexTextures:withRange:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_renc_set_vtexs_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, const id __unsafe_unretained *, NSRange))origIMP)(self, sel, textures, range);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (!ps_is_effective_system_or_playtools_caller(caller) && range.length > 0) {
        ps_mtl_encoder_record_textures(self, PSMTLEncoderStageVertex, textures, range);
    }
}

- (void) pm_ps_mtl_renc_setVertexSamplerState:(id)sampler atIndex:(NSUInteger)index {
    const void *caller = __builtin_return_address(0);
    id effSampler = ps_is_effective_system_or_playtools_caller(caller)
        ? sampler
        : ps_mtl_encoder_record_sampler(self, PSMTLEncoderStageVertex, sampler, NO, 0.0f, 0.0f, index);
    SEL sel = sel_registerName("setVertexSamplerState:atIndex:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_renc_set_vsamp_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, id, NSUInteger))origIMP)(self, sel, effSampler, index);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
}

- (void) pm_ps_mtl_renc_setVertexSamplerState:(id)sampler
                                  lodMinClamp:(float)lodMinClamp
                                  lodMaxClamp:(float)lodMaxClamp
                                      atIndex:(NSUInteger)index {
    const void *caller = __builtin_return_address(0);
    id effSampler = ps_is_effective_system_or_playtools_caller(caller)
        ? sampler
        : ps_mtl_encoder_record_sampler(self, PSMTLEncoderStageVertex, sampler, YES, lodMinClamp, lodMaxClamp, index);
    SEL sel = sel_registerName("setVertexSamplerState:lodMinClamp:lodMaxClamp:atIndex:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_renc_set_vsamp_lod_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, id, float, float, NSUInteger))origIMP)(
                self, sel, effSampler, lodMinClamp, lodMaxClamp, index);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
}

- (void) pm_ps_mtl_renc_setVertexSamplerStates:(const id __unsafe_unretained *)samplers withRange:(NSRange)range {
    const void *caller = __builtin_return_address(0);
    SEL sel = sel_registerName("setVertexSamplerStates:withRange:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_renc_set_vsamps_imps, self, &pushed);
    if (origIMP == NULL) {
        return;
    }
    if (!ps_is_effective_system_or_playtools_caller(caller) && samplers != NULL && range.length > 0 && range.length <= 256) {
        id __unsafe_unretained stackBuf[256];
        BOOL changed = NO;
        for (NSUInteger i = 0; i < range.length; i++) {
            id origS = samplers[i];
            id effS = ps_mtl_encoder_record_sampler(self, PSMTLEncoderStageVertex, origS, NO, 0.0f, 0.0f, range.location + i);
            stackBuf[i] = effS;
            if (effS != origS) {
                changed = YES;
            }
        }
        const id __unsafe_unretained *effSamplers = changed ? stackBuf : samplers;
        @try {
            ((void (*)(id, SEL, const id __unsafe_unretained *, NSRange))origIMP)(self, sel, effSamplers, range);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
        return;
    }
    @try {
        ((void (*)(id, SEL, const id __unsafe_unretained *, NSRange))origIMP)(self, sel, samplers, range);
    } @finally {
        ps_pop_orig_imp_frame(pushed);
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
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_supports_counter_sampling_imps, cls,
                                     sel_registerName("supportsCounterSampling:"),
                                     @selector(pm_ps_mtl_supportsCounterSampling:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_counter_sets_imps, cls,
                                     sel_registerName("counterSets"),
                                     @selector(pm_ps_mtl_counterSets));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_sparse_tile_size_imps, cls,
                                     sel_registerName("sparseTileSizeInBytes"),
                                     @selector(pm_ps_mtl_sparseTileSizeInBytes));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_raster_order_groups_imps, cls,
                                     sel_registerName("areRasterOrderGroupsSupported"),
                                     @selector(pm_ps_mtl_rasterOrderGroupsSupported));
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
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_texture_imps, cls,
                                     sel_registerName("newTextureWithDescriptor:"),
                                     @selector(pm_ps_mtl_newTextureWithDescriptor:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_sampler_imps, cls,
                                     sel_registerName("newSamplerStateWithDescriptor:"),
                                     @selector(pm_ps_mtl_newSamplerStateWithDescriptor:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_cmdqueue_imps, cls,
                                     sel_registerName("newCommandQueue"),
                                     @selector(pm_ps_mtl_newCommandQueue));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_cmdqueue_cnt_imps, cls,
                                     sel_registerName("newCommandQueueWithMaxCommandBufferCount:"),
                                     @selector(pm_ps_mtl_newCommandQueueWithMaxCommandBufferCount:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_dynlib_imps, cls,
                                     sel_registerName("newDynamicLibrary:error:"),
                                     @selector(pm_ps_mtl_newDynamicLibrary:error:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_binarch_imps, cls,
                                     sel_registerName("newBinaryArchiveWithDescriptor:error:"),
                                     @selector(pm_ps_mtl_newBinaryArchiveWithDescriptor:error:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_accel_struct_imps, cls,
                                     sel_registerName("newAccelerationStructureWithDescriptor:"),
                                     @selector(pm_ps_mtl_newAccelerationStructureWithDescriptor:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_counter_buf_imps, cls,
                                     sel_registerName("newCounterSampleBufferWithDescriptor:error:"),
                                     @selector(pm_ps_mtl_newCounterSampleBufferWithDescriptor:error:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_intersect_tbl_imps, cls,
                                     sel_registerName("newIntersectionFunctionTableWithDescriptor:"),
                                     @selector(pm_ps_mtl_newIntersectionFunctionTableWithDescriptor:));
}

static void ps_swizzle_mtl_command_queue_class(Class cls) {
    if (pt_mtl_class_already_swizzled(cls)) {
        return;
    }
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_cq_cmdbuf_imps, cls,
                                     sel_registerName("commandBuffer"),
                                     @selector(pm_ps_mtl_cq_commandBuffer));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_cq_cmdbuf_unret_imps, cls,
                                     sel_registerName("commandBufferWithUnretainedReferences"),
                                     @selector(pm_ps_mtl_cq_commandBufferWithUnretainedReferences));
}

static void ps_swizzle_mtl_command_buffer_class(Class cls) {
    if (pt_mtl_class_already_swizzled(cls)) {
        return;
    }
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_cb_comp_enc_imps, cls,
                                     sel_registerName("computeCommandEncoder"),
                                     @selector(pm_ps_mtl_cb_computeCommandEncoder));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_cb_comp_enc_desc_imps, cls,
                                     sel_registerName("computeCommandEncoderWithDescriptor:"),
                                     @selector(pm_ps_mtl_cb_computeCommandEncoderWithDescriptor:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_cb_comp_enc_disp_imps, cls,
                                     sel_registerName("computeCommandEncoderWithDispatchType:"),
                                     @selector(pm_ps_mtl_cb_computeCommandEncoderWithDispatchType:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_cb_rend_enc_imps, cls,
                                     sel_registerName("renderCommandEncoderWithDescriptor:"),
                                     @selector(pm_ps_mtl_cb_renderCommandEncoderWithDescriptor:));
}

static void ps_swizzle_mtl_compute_encoder_class(Class cls) {
    if (pt_mtl_class_already_swizzled(cls)) {
        return;
    }
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_cenc_set_tex_imps, cls,
                                     sel_registerName("setTexture:atIndex:"),
                                     @selector(pm_ps_mtl_cenc_setTexture:atIndex:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_cenc_set_texs_imps, cls,
                                     sel_registerName("setTextures:withRange:"),
                                     @selector(pm_ps_mtl_cenc_setTextures:withRange:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_cenc_set_samp_imps, cls,
                                     sel_registerName("setSamplerState:atIndex:"),
                                     @selector(pm_ps_mtl_cenc_setSamplerState:atIndex:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_cenc_set_samp_lod_imps, cls,
                                     sel_registerName("setSamplerState:lodMinClamp:lodMaxClamp:atIndex:"),
                                     @selector(pm_ps_mtl_cenc_setSamplerState:lodMinClamp:lodMaxClamp:atIndex:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_cenc_set_samps_imps, cls,
                                     sel_registerName("setSamplerStates:withRange:"),
                                     @selector(pm_ps_mtl_cenc_setSamplerStates:withRange:));
}

static void ps_swizzle_mtl_render_encoder_class(Class cls) {
    if (pt_mtl_class_already_swizzled(cls)) {
        return;
    }
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_renc_set_ftex_imps, cls,
                                     sel_registerName("setFragmentTexture:atIndex:"),
                                     @selector(pm_ps_mtl_renc_setFragmentTexture:atIndex:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_renc_set_ftexs_imps, cls,
                                     sel_registerName("setFragmentTextures:withRange:"),
                                     @selector(pm_ps_mtl_renc_setFragmentTextures:withRange:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_renc_set_fsamp_imps, cls,
                                     sel_registerName("setFragmentSamplerState:atIndex:"),
                                     @selector(pm_ps_mtl_renc_setFragmentSamplerState:atIndex:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_renc_set_fsamp_lod_imps, cls,
                                     sel_registerName("setFragmentSamplerState:lodMinClamp:lodMaxClamp:atIndex:"),
                                     @selector(pm_ps_mtl_renc_setFragmentSamplerState:lodMinClamp:lodMaxClamp:atIndex:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_renc_set_fsamps_imps, cls,
                                     sel_registerName("setFragmentSamplerStates:withRange:"),
                                     @selector(pm_ps_mtl_renc_setFragmentSamplerStates:withRange:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_renc_set_vtex_imps, cls,
                                     sel_registerName("setVertexTexture:atIndex:"),
                                     @selector(pm_ps_mtl_renc_setVertexTexture:atIndex:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_renc_set_vtexs_imps, cls,
                                     sel_registerName("setVertexTextures:withRange:"),
                                     @selector(pm_ps_mtl_renc_setVertexTextures:withRange:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_renc_set_vsamp_imps, cls,
                                     sel_registerName("setVertexSamplerState:atIndex:"),
                                     @selector(pm_ps_mtl_renc_setVertexSamplerState:atIndex:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_renc_set_vsamp_lod_imps, cls,
                                     sel_registerName("setVertexSamplerState:lodMinClamp:lodMaxClamp:atIndex:"),
                                     @selector(pm_ps_mtl_renc_setVertexSamplerState:lodMinClamp:lodMaxClamp:atIndex:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_renc_set_vsamps_imps, cls,
                                     sel_registerName("setVertexSamplerStates:withRange:"),
                                     @selector(pm_ps_mtl_renc_setVertexSamplerStates:withRange:));
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
