//
//  PTGraphicsVirtualizer.m
//  PlayTools
//

#import "PSInternal.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include <stdatomic.h>

typedef NS_ENUM(NSUInteger, PSMTLEncoderStage) {
    PSMTLEncoderStageCompute = 0,
    PSMTLEncoderStageFragment = 1,
    PSMTLEncoderStageVertex = 2,
};

__attribute__((visibility("hidden")))
@interface PSMTLLibrary32FInfo : NSObject {
@public
    __weak id _device;
    NSString *_nearestSource;
    id _compileOptionsCopy;
    id _nearestLibrary;
    BOOL _attempted;
}
- (id) nearestLibrary;
@end

@implementation PSMTLLibrary32FInfo
- (id) nearestLibrary {
    @synchronized (self) {
        if (_attempted) {
            return _nearestLibrary;
        }
        _attempted = YES;
        id dev = _device;
        if (dev == nil || _nearestSource == nil) {
            return nil;
        }
        SEL sel = sel_registerName("newLibraryWithSource:options:error:");
        if ([dev respondsToSelector:sel]) {
            NSError *err = nil;
            typedef id (*PTMTLBuildLibFn)(id, SEL, NSString *, id, NSError **) NS_RETURNS_RETAINED;
            _nearestLibrary = ((PTMTLBuildLibFn)objc_msgSend)(dev, sel, _nearestSource, _compileOptionsCopy, &err);
        }
        return _nearestLibrary;
    }
}
@end

__attribute__((visibility("hidden")))
@interface PSMTLFunction32FInfo : NSObject {
@public
    PSMTLLibrary32FInfo *_libInfo;
    NSString *_name;
    id _constantValuesCopy;
    id _nearestFunction;
    BOOL _attempted;
}
- (id) nearestFunction;
@end

@implementation PSMTLFunction32FInfo
- (id) nearestFunction {
    @synchronized (self) {
        if (_attempted) {
            return _nearestFunction;
        }
        _attempted = YES;
        id lib = [_libInfo nearestLibrary];
        if (lib == nil || _name == nil) {
            return nil;
        }
        if (_constantValuesCopy != nil) {
            SEL sel = sel_registerName("newFunctionWithName:constantValues:error:");
            if ([lib respondsToSelector:sel]) {
                NSError *err = nil;
                typedef id (*PTMTLBuildFnConstFn)(id, SEL, NSString *, id, NSError **) NS_RETURNS_RETAINED;
                _nearestFunction = ((PTMTLBuildFnConstFn)objc_msgSend)(lib, sel, _name, _constantValuesCopy, &err);
            }
        } else {
            SEL sel = sel_registerName("newFunctionWithName:");
            if ([lib respondsToSelector:sel]) {
                typedef id (*PTMTLBuildFnFn)(id, SEL, NSString *) NS_RETURNS_RETAINED;
                _nearestFunction = ((PTMTLBuildFnFn)objc_msgSend)(lib, sel, _name);
            }
        }
        return _nearestFunction;
    }
}
@end

__attribute__((visibility("hidden")))
@interface PSMTLPipeline32FInfo : NSObject {
@public
    __weak id _device;
    BOOL _isRender;
    PSMTLFunction32FInfo *_computeFnInfo;
    PSMTLFunction32FInfo *_vertexFnInfo;
    PSMTLFunction32FInfo *_fragmentFnInfo;
    PSMTLFunction32FInfo *_tileFnInfo;
    id _descriptorCopy;
    NSUInteger _options;
    BOOL _hasOptions;
    id _nearestPipeline;
    BOOL _attempted;
}
- (id) nearestPipeline;
@end

@implementation PSMTLPipeline32FInfo
- (id) nearestPipeline {
    id computeFn = [_computeFnInfo nearestFunction];
    id vertexFn = [_vertexFnInfo nearestFunction];
    id fragmentFn = [_fragmentFnInfo nearestFunction];
    id tileFn = [_tileFnInfo nearestFunction];
    @synchronized (self) {
        if (_attempted) {
            return _nearestPipeline;
        }
        _attempted = YES;
        id dev = _device;
        if (dev == nil) {
            return nil;
        }
        if (_isRender) {
            if (_descriptorCopy == nil || ![_descriptorCopy respondsToSelector:@selector(copy)]) {
                return nil;
            }
            id desc = [_descriptorCopy copy];
            if (desc == nil) {
                return nil;
            }
            if (vertexFn != nil && [desc respondsToSelector:sel_registerName("setVertexFunction:")]) {
                ((void (*)(id, SEL, id))objc_msgSend)(desc, sel_registerName("setVertexFunction:"), vertexFn);
            }
            if (fragmentFn != nil && [desc respondsToSelector:sel_registerName("setFragmentFunction:")]) {
                ((void (*)(id, SEL, id))objc_msgSend)(desc, sel_registerName("setFragmentFunction:"), fragmentFn);
            }
            NSError *err = nil;
            if (_hasOptions) {
                SEL sel = sel_registerName("newRenderPipelineStateWithDescriptor:options:reflection:error:");
                if ([dev respondsToSelector:sel]) {
                    typedef id (*Fn)(id, SEL, id, NSUInteger, id *, NSError **) NS_RETURNS_RETAINED;
                    _nearestPipeline = ((Fn)objc_msgSend)(dev, sel, desc, _options, NULL, &err);
                }
            } else {
                SEL sel = sel_registerName("newRenderPipelineStateWithDescriptor:error:");
                if ([dev respondsToSelector:sel]) {
                    typedef id (*Fn)(id, SEL, id, NSError **) NS_RETURNS_RETAINED;
                    _nearestPipeline = ((Fn)objc_msgSend)(dev, sel, desc, &err);
                }
            }
            return _nearestPipeline;
        }
        if (_descriptorCopy != nil && [_descriptorCopy respondsToSelector:@selector(copy)]) {
            id desc = [_descriptorCopy copy];
            if (desc == nil) {
                return nil;
            }
            if (computeFn != nil && [desc respondsToSelector:sel_registerName("setComputeFunction:")]) {
                ((void (*)(id, SEL, id))objc_msgSend)(desc, sel_registerName("setComputeFunction:"), computeFn);
            }
            SEL sel = sel_registerName("newComputePipelineStateWithDescriptor:options:reflection:error:");
            if ([dev respondsToSelector:sel]) {
                NSError *err = nil;
                typedef id (*Fn)(id, SEL, id, NSUInteger, id *, NSError **) NS_RETURNS_RETAINED;
                _nearestPipeline = ((Fn)objc_msgSend)(dev, sel, desc, _hasOptions ? _options : 0U, NULL, &err);
            }
            return _nearestPipeline;
        }
        if (computeFn == nil) {
            return nil;
        }
        NSError *err = nil;
        if (_hasOptions) {
            SEL sel = sel_registerName("newComputePipelineStateWithFunction:options:reflection:error:");
            if ([dev respondsToSelector:sel]) {
                typedef id (*Fn)(id, SEL, id, NSUInteger, id *, NSError **) NS_RETURNS_RETAINED;
                _nearestPipeline = ((Fn)objc_msgSend)(dev, sel, computeFn, _options, NULL, &err);
            }
        } else {
            SEL sel = sel_registerName("newComputePipelineStateWithFunction:error:");
            if ([dev respondsToSelector:sel]) {
                typedef id (*Fn)(id, SEL, id, NSError **) NS_RETURNS_RETAINED;
                _nearestPipeline = ((Fn)objc_msgSend)(dev, sel, computeFn, &err);
            }
        }
        (void)tileFn;
        return _nearestPipeline;
    }
}
@end

__attribute__((visibility("hidden")))
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

__attribute__((visibility("hidden")))
@interface PSMTLEncoderBindingState : NSObject {
@public
    NSMutableSet<NSNumber *> *_tex32FSlots;
    NSMutableDictionary<NSNumber *, PSMTLSamplerBindEntry *> *_samplersByStageSlot;
    id _currentPipeline;
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
static os_unfair_lock s_mtl_host_fam_lock = OS_UNFAIR_LOCK_INIT;
static int32_t s_mtl_host_max_apple_family = 0;
static CFMutableDictionaryRef s_mtl_orig_name_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_description_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_debug_description_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_formatted_description_imps = NULL;
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
static CFMutableDictionaryRef s_mtl_orig_are_barycentric_imps = NULL;
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
static CFMutableDictionaryRef s_mtl_orig_new_lib_data_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_lib_url_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_lib_file_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_lib_new_fn_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_lib_new_fn_const_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_lib_new_fn_const_async_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_comp_pipe_fn_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_comp_pipe_fn_async_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_comp_pipe_fn_opts_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_comp_pipe_fn_opts_async_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_comp_pipe_desc_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_comp_pipe_desc_async_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_comp_pipe_desc_opts_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_comp_pipe_desc_opts_async_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_rend_pipe_desc_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_rend_pipe_desc_async_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_rend_pipe_desc_opts_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_new_rend_pipe_desc_opts_async_imps = NULL;
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
static CFMutableDictionaryRef s_mtl_orig_cenc_set_pipe_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_cenc_set_tex_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_cenc_set_texs_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_cenc_set_samp_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_cenc_set_samp_lod_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_cenc_set_samps_imps = NULL;
static CFMutableDictionaryRef s_mtl_orig_renc_set_pipe_imps = NULL;
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
static const char kPSMTLLibrary32FInfoKey = 0;
static const char kPSMTLFunction32FInfoKey = 0;
static const char kPSMTLPipeline32FInfoKey = 0;

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

typedef NS_ENUM(NSInteger, PSMTLIfState) {
    PSMTLIfStateUnknown = 0,
    PSMTLIfStateActive = 1,
    PSMTLIfStateInactive = 2,
};

typedef struct {
    PSMTLIfState state;
    BOOL seenActive;
    BOOL seenUnknown;
} PSMTLIfFrame;

static BOOL pt_mtl_parse_strict_integer(NSString *s, long long *outVal) {
    if (s.length == 0) {
        return NO;
    }
    const char *cstr = [s UTF8String];
    if (cstr == NULL || cstr[0] == '\0') {
        return NO;
    }
    char *endPtr = NULL;
    long long v = strtoll(cstr, &endPtr, 0);
    if (endPtr == cstr) {
        return NO;
    }
    while (*endPtr == 'u' || *endPtr == 'U' || *endPtr == 'l' || *endPtr == 'L') {
        endPtr++;
    }
    if (*endPtr != '\0') {
        return NO;
    }
    if (outVal != NULL) {
        *outVal = v;
    }
    return YES;
}

static PSMTLIfState pt_mtl_eval_compat13_expr(NSString *expr) {
    if (expr == nil) {
        return PSMTLIfStateUnknown;
    }
    NSString *s = [expr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // Strip matching outer parentheses
    while (s.length >= 2 && [s characterAtIndex:0] == '(' && [s characterAtIndex:s.length - 1] == ')') {
        int depth = 0;
        BOOL wrapsAll = YES;
        for (NSUInteger i = 0; i < s.length; i++) {
            unichar ch = [s characterAtIndex:i];
            if (ch == '(') depth++;
            else if (ch == ')') depth--;
            if (depth == 0 && i + 1 < s.length) {
                wrapsAll = NO;
                break;
            }
        }
        if (!wrapsAll) {
            break;
        }
        s = [[s substringWithRange:NSMakeRange(1, s.length - 2)]
             stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if (s.length == 0) {
        return PSMTLIfStateUnknown;
    }

    // Split top-level '||' (lowest precedence)
    {
        int depth = 0;
        for (NSUInteger i = 0; i + 1 < s.length; i++) {
            unichar ch = [s characterAtIndex:i];
            if (ch == '(') depth++;
            else if (ch == ')') { if (depth > 0) depth--; }
            else if (depth == 0 && ch == '|' && [s characterAtIndex:i + 1] == '|') {
                PSMTLIfState lhs = pt_mtl_eval_compat13_expr([s substringToIndex:i]);
                PSMTLIfState rhs = pt_mtl_eval_compat13_expr([s substringFromIndex:i + 2]);
                if (lhs == PSMTLIfStateActive || rhs == PSMTLIfStateActive) {
                    return PSMTLIfStateActive;
                }
                if (lhs == PSMTLIfStateInactive && rhs == PSMTLIfStateInactive) {
                    return PSMTLIfStateInactive;
                }
                return PSMTLIfStateUnknown;
            }
        }
    }
    // Split top-level '&&'
    {
        int depth = 0;
        for (NSUInteger i = 0; i + 1 < s.length; i++) {
            unichar ch = [s characterAtIndex:i];
            if (ch == '(') depth++;
            else if (ch == ')') { if (depth > 0) depth--; }
            else if (depth == 0 && ch == '&' && [s characterAtIndex:i + 1] == '&') {
                PSMTLIfState lhs = pt_mtl_eval_compat13_expr([s substringToIndex:i]);
                PSMTLIfState rhs = pt_mtl_eval_compat13_expr([s substringFromIndex:i + 2]);
                if (lhs == PSMTLIfStateInactive || rhs == PSMTLIfStateInactive) {
                    return PSMTLIfStateInactive;
                }
                if (lhs == PSMTLIfStateActive && rhs == PSMTLIfStateActive) {
                    return PSMTLIfStateActive;
                }
                return PSMTLIfStateUnknown;
            }
        }
    }

    // Unary '!'
    if ([s characterAtIndex:0] == '!' && (s.length < 2 || [s characterAtIndex:1] != '=')) {
        PSMTLIfState inner = pt_mtl_eval_compat13_expr([s substringFromIndex:1]);
        if (inner == PSMTLIfStateActive) return PSMTLIfStateInactive;
        if (inner == PSMTLIfStateInactive) return PSMTLIfStateActive;
        return PSMTLIfStateUnknown;
    }

    NSString *compact = [[s componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
                         componentsJoinedByString:@""];
    if ([compact isEqualToString:@"defined(__METAL_MACOS__)"] ||
        [compact isEqualToString:@"defined__METAL_MACOS__"]) {
        return PSMTLIfStateInactive;
    }
    if ([compact isEqualToString:@"defined(__METAL_IOS__)"] ||
        [compact isEqualToString:@"defined__METAL_IOS__"]) {
        return PSMTLIfStateActive;
    }

    long long literalVal = 0;
    if (pt_mtl_parse_strict_integer(compact, &literalVal)) {
        return (literalVal != 0) ? PSMTLIfStateActive : PSMTLIfStateInactive;
    }

    // Evaluate simple comparisons against __METAL_VERSION__ (220 under compat13_7)
    static const char * const kOps[] = { ">=", "<=", "==", "!=", ">", "<" };
    for (size_t k = 0; k < sizeof(kOps) / sizeof(kOps[0]); k++) {
        NSString *op = [NSString stringWithUTF8String:kOps[k]];
        NSRange r = [compact rangeOfString:op];
        if (r.location != NSNotFound) {
            NSString *lhsStr = [compact substringToIndex:r.location];
            NSString *rhsStr = [compact substringFromIndex:r.location + r.length];
            long long lhsVal = 0, rhsVal = 0;
            BOOL lhsKnown = NO, rhsKnown = NO;
            if ([lhsStr isEqualToString:@"__METAL_VERSION__"]) {
                lhsVal = 220;
                lhsKnown = YES;
            } else {
                lhsKnown = pt_mtl_parse_strict_integer(lhsStr, &lhsVal);
            }
            if ([rhsStr isEqualToString:@"__METAL_VERSION__"]) {
                rhsVal = 220;
                rhsKnown = YES;
            } else {
                rhsKnown = pt_mtl_parse_strict_integer(rhsStr, &rhsVal);
            }
            if (lhsKnown && rhsKnown) {
                BOOL result = NO;
                if (k == 0) result = (lhsVal >= rhsVal);
                else if (k == 1) result = (lhsVal <= rhsVal);
                else if (k == 2) result = (lhsVal == rhsVal);
                else if (k == 3) result = (lhsVal != rhsVal);
                else if (k == 4) result = (lhsVal > rhsVal);
                else result = (lhsVal < rhsVal);
                return result ? PSMTLIfStateActive : PSMTLIfStateInactive;
            }
            return PSMTLIfStateUnknown;
        }
    }

    return PSMTLIfStateUnknown;
}

static NSString *pt_mtl_strip_comments_and_inactive_guard_blocks(NSString *source) {
    if (source == nil || source.length == 0U) {
        return source;
    }
    NSUInteger len = source.length;
    NSMutableString *masked = [NSMutableString stringWithCapacity:len];
    const unichar *chars = NULL;
    unichar *heapChars = malloc(len * sizeof(unichar));
    if (heapChars == NULL) {
        return source;
    }
    [source getCharacters:heapChars range:NSMakeRange(0, len)];
    chars = heapChars;

    // Pass 1: blank comments (//... and /*...*/) while preserving '\n' for exact line:col diagnostics
    BOOL inLineComment = NO;
    BOOL inBlockComment = NO;
    BOOL inString = NO;
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = chars[i];
        unichar next = (i + 1U < len) ? chars[i + 1U] : 0;
        if (inLineComment) {
            if (c == '\n') {
                inLineComment = NO;
                [masked appendString:@"\n"];
            } else {
                [masked appendString:@" "];
            }
            continue;
        }
        if (inBlockComment) {
            if (c == '*' && next == '/') {
                [masked appendString:@"  "];
                i++;
                inBlockComment = NO;
            } else if (c == '\n') {
                [masked appendString:@"\n"];
            } else {
                [masked appendString:@" "];
            }
            continue;
        }
        if (inString) {
            [masked appendFormat:@"%C", c];
            if (c == '\\' && i + 1U < len) {
                i++;
                [masked appendFormat:@"%C", chars[i]];
            } else if (c == '"') {
                inString = NO;
            }
            continue;
        }
        if (c == '"') {
            inString = YES;
            [masked appendFormat:@"%C", c];
        } else if (c == '/' && next == '/') {
            inLineComment = YES;
            [masked appendString:@"  "];
            i++;
        } else if (c == '/' && next == '*') {
            inBlockComment = YES;
            [masked appendString:@"  "];
            i++;
        } else {
            [masked appendFormat:@"%C", c];
        }
    }
    free(heapChars);

    // Pass 2: blank inactive preprocessor branches using a 3-state (Active/Inactive/Unknown) stack
    NSArray<NSString *> *lines = [masked componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString *> *outLines = [NSMutableArray arrayWithCapacity:lines.count];
    PSMTLIfFrame ifStack[128];
    NSUInteger stackDepth = 0;
    NSUInteger overflowDepth = 0;
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:ws];
        if ([trimmed hasPrefix:@"#"]) {
            NSString *afterHash = [[trimmed substringFromIndex:1] stringByTrimmingCharactersInSet:ws];
            if ([afterHash hasPrefix:@"ifdef"] &&
                (afterHash.length == 5 || [ws characterIsMember:[afterHash characterAtIndex:5]])) {
                NSString *sym = [[afterHash substringFromIndex:5] stringByTrimmingCharactersInSet:ws];
                NSRange sp = [sym rangeOfCharacterFromSet:ws];
                if (sp.location != NSNotFound) sym = [sym substringToIndex:sp.location];
                PSMTLIfState st = PSMTLIfStateUnknown;
                if ([sym isEqualToString:@"__METAL_MACOS__"]) st = PSMTLIfStateInactive;
                else if ([sym isEqualToString:@"__METAL_IOS__"]) st = PSMTLIfStateActive;
                if (stackDepth < 128U) {
                    ifStack[stackDepth++] = (PSMTLIfFrame){ st, (st == PSMTLIfStateActive), (st == PSMTLIfStateUnknown) };
                } else {
                    overflowDepth++;
                }
                [outLines addObject:line];
                continue;
            }
            if ([afterHash hasPrefix:@"ifndef"] &&
                (afterHash.length == 6 || [ws characterIsMember:[afterHash characterAtIndex:6]])) {
                NSString *sym = [[afterHash substringFromIndex:6] stringByTrimmingCharactersInSet:ws];
                NSRange sp = [sym rangeOfCharacterFromSet:ws];
                if (sp.location != NSNotFound) sym = [sym substringToIndex:sp.location];
                PSMTLIfState st = PSMTLIfStateUnknown;
                if ([sym isEqualToString:@"__METAL_MACOS__"]) st = PSMTLIfStateActive;
                else if ([sym isEqualToString:@"__METAL_IOS__"]) st = PSMTLIfStateInactive;
                if (stackDepth < 128U) {
                    ifStack[stackDepth++] = (PSMTLIfFrame){ st, (st == PSMTLIfStateActive), (st == PSMTLIfStateUnknown) };
                } else {
                    overflowDepth++;
                }
                [outLines addObject:line];
                continue;
            }
            if ([afterHash hasPrefix:@"if"] &&
                (afterHash.length == 2 || [ws characterIsMember:[afterHash characterAtIndex:2]] || [afterHash characterAtIndex:2] == '(' || [afterHash characterAtIndex:2] == '!')) {
                NSString *expr = [afterHash substringFromIndex:2];
                PSMTLIfState st = pt_mtl_eval_compat13_expr(expr);
                if (stackDepth < 128U) {
                    ifStack[stackDepth++] = (PSMTLIfFrame){ st, (st == PSMTLIfStateActive), (st == PSMTLIfStateUnknown) };
                } else {
                    overflowDepth++;
                }
                [outLines addObject:line];
                continue;
            }
            if ([afterHash hasPrefix:@"elif"] &&
                (afterHash.length == 4 || [ws characterIsMember:[afterHash characterAtIndex:4]] || [afterHash characterAtIndex:4] == '(' || [afterHash characterAtIndex:4] == '!')) {
                if (overflowDepth == 0 && stackDepth > 0) {
                    PSMTLIfFrame *top = &ifStack[stackDepth - 1];
                    if (top->seenActive) {
                        top->state = PSMTLIfStateInactive;
                    } else {
                        PSMTLIfState st = pt_mtl_eval_compat13_expr([afterHash substringFromIndex:4]);
                        if (st == PSMTLIfStateInactive) {
                            top->state = PSMTLIfStateInactive;
                        } else if (st == PSMTLIfStateActive) {
                            top->state = top->seenUnknown ? PSMTLIfStateUnknown : PSMTLIfStateActive;
                            top->seenActive = YES;
                        } else {
                            top->state = PSMTLIfStateUnknown;
                            top->seenUnknown = YES;
                        }
                    }
                }
                [outLines addObject:line];
                continue;
            }
            if ([afterHash hasPrefix:@"else"] &&
                (afterHash.length == 4 || [ws characterIsMember:[afterHash characterAtIndex:4]])) {
                if (overflowDepth == 0 && stackDepth > 0) {
                    PSMTLIfFrame *top = &ifStack[stackDepth - 1];
                    if (top->seenActive) {
                        top->state = PSMTLIfStateInactive;
                    } else if (top->seenUnknown) {
                        top->state = PSMTLIfStateUnknown;
                    } else {
                        top->state = PSMTLIfStateActive;
                        top->seenActive = YES;
                    }
                }
                [outLines addObject:line];
                continue;
            }
            if ([afterHash hasPrefix:@"endif"] &&
                (afterHash.length == 5 || [ws characterIsMember:[afterHash characterAtIndex:5]])) {
                if (overflowDepth > 0) {
                    overflowDepth--;
                } else if (stackDepth > 0) {
                    stackDepth--;
                }
                [outLines addObject:line];
                continue;
            }
        }
        BOOL insideInactive = NO;
        for (NSUInteger idx = 0; idx < stackDepth; idx++) {
            if (ifStack[idx].state == PSMTLIfStateInactive) {
                insideInactive = YES;
                break;
            }
        }
        if (insideInactive) {
            [outLines addObject:[@"" stringByPaddingToLength:line.length withString:@" " startingAtIndex:0]];
        } else {
            [outLines addObject:line];
        }
    }
    return [outLines componentsJoinedByString:@"\n"];
}

static BOOL pt_mtl_source_contains_barycentric_attr(NSString *source, NSRange *outRange) {
    if (source.length == 0 || [source rangeOfString:@"barycentric_coord"].location == NSNotFound) {
        return NO;
    }
    static NSRegularExpression *s_baryRe = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_baryRe = [NSRegularExpression regularExpressionWithPattern:@"\\[\\[\\s*barycentric_coord\\s*\\]\\]"
                                                             options:0
                                                               error:nil];
    });
    if (s_baryRe == nil) {
        return NO;
    }
    NSTextCheckingResult *m = [s_baryRe firstMatchInString:source options:0 range:NSMakeRange(0, source.length)];
    if (m != nil && m.range.location != NSNotFound) {
        if (outRange != NULL) {
            *outRange = m.range;
        }
        return YES;
    }
    return NO;
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
    NSString *effectiveSource = nil;
    NSRange baryRange = NSMakeRange(NSNotFound, 0);
    if (!reject && source != nil && [source isKindOfClass:[NSString class]]) {
        effectiveSource = pt_mtl_strip_comments_and_inactive_guard_blocks(source);
        if ([effectiveSource containsString:@"metal_simdgroup_matrix"] ||
            [effectiveSource containsString:@"simdgroup_multiply_accumulate"] ||
            [effectiveSource containsString:@"metal_raytracing"] ||
            [effectiveSource containsString:@"raytracing::intersector"] ||
            pt_mtl_source_contains_barycentric_attr(effectiveSource, &baryRange)) {
            reject = YES;
        }
    }
    if (!reject) {
        return NO;
    }
    if (outError != NULL) {
        NSString *msg = @"Compilation failed:\nInvalid languageVersion";
        if (effectiveSource != nil && [effectiveSource isKindOfClass:[NSString class]]) {
            NSString *simdMsg = [effectiveSource containsString:@"metal_simdgroup_matrix"]
                ? pt_mtl_format_missing_header_diagnostic(effectiveSource, @"metal_simdgroup_matrix")
                : nil;
            NSString *rtMsg = [effectiveSource containsString:@"metal_raytracing"]
                ? pt_mtl_format_missing_header_diagnostic(effectiveSource, @"metal_raytracing")
                : nil;
            if (simdMsg != nil) {
                msg = simdMsg;
            } else if (rtMsg != nil) {
                msg = rtMsg;
            } else {
                NSRange symRange = [effectiveSource rangeOfString:@"simdgroup_multiply_accumulate"];
                NSRange rtSymRange = [effectiveSource rangeOfString:@"raytracing::intersector"];
                if (symRange.location != NSNotFound) {
                    NSUInteger line = 1, col = 1;
                    pt_mtl_line_and_col_for_location(effectiveSource, symRange.location, &line, &col);
                    msg = [NSString stringWithFormat:
                           @"program_source:%lu:%lu: error: use of undeclared identifier 'simdgroup_multiply_accumulate'",
                           (unsigned long)line, (unsigned long)col];
                } else if (rtSymRange.location != NSNotFound) {
                    NSUInteger line = 1, col = 1;
                    pt_mtl_line_and_col_for_location(effectiveSource, rtSymRange.location, &line, &col);
                    msg = [NSString stringWithFormat:
                           @"program_source:%lu:%lu: error: use of undeclared identifier 'raytracing'",
                           (unsigned long)line, (unsigned long)col];
                } else if (baryRange.location != NSNotFound) {
                    NSUInteger line = 1, col = 1;
                    pt_mtl_line_and_col_for_location(effectiveSource, baryRange.location, &line, &col);
                    msg = [NSString stringWithFormat:
                           @"program_source:%lu:%lu: error: unknown attribute 'barycentric_coord'",
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

static inline uint16_t pt_mtl_read_le16(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static inline uint32_t pt_mtl_read_le32(const uint8_t *p) {
    return (uint32_t)p[0] |
           ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

static inline uint64_t pt_mtl_read_le64(const uint8_t *p) {
    return (uint64_t)pt_mtl_read_le32(p) | ((uint64_t)pt_mtl_read_le32(p + 4) << 32);
}

static BOOL pt_mtl_should_reject_metallib_bytes_for_compat13(const uint8_t *bytes, size_t len, NSError **outError) {
    if (!pt_is_bypass_enabled() || !pt_is_compat13_7_active()) {
        return NO;
    }
    if (bytes == NULL || len < 40U || memcmp(bytes, "MTLB", 4) != 0) {
        return NO;
    }
    BOOL reject = NO;
    // Dynamic Metal libraries (fileType == 2) require Metal 2.3 / iOS 14+
    uint8_t fileType = bytes[10];
    if (fileType == 2U) {
        reject = YES;
    }
    if (!reject) {
        uint64_t flOff = pt_mtl_read_le64(bytes + 24);
        uint64_t flSize = pt_mtl_read_le64(bytes + 32);
        if (flOff >= 40ULL && flOff + 4ULL <= (uint64_t)len && flSize >= 4ULL) {
            uint64_t maxEnd = (uint64_t)len;
            uint64_t entriesStart = flOff + 4ULL;
            uint64_t entriesEnd = (flSize <= maxEnd - entriesStart) ? (entriesStart + flSize) : maxEnd;
            uint32_t entryCount = pt_mtl_read_le32(bytes + flOff);
            uint64_t pos = entriesStart;
            for (uint32_t e = 0; e < entryCount && e < 4096U && pos + 4ULL <= entriesEnd; e++) {
                uint32_t entrySize = pt_mtl_read_le32(bytes + pos);
                if (entrySize < 4U || (uint64_t)entrySize > entriesEnd - pos) {
                    break;
                }
                uint64_t tagPos = pos + 4ULL;
                uint64_t entryEnd = pos + (uint64_t)entrySize;
                while (tagPos + 4ULL <= entryEnd) {
                    if (memcmp(bytes + tagPos, "ENDT", 4) == 0) {
                        break;
                    }
                    if (tagPos + 6ULL > entryEnd) {
                        break;
                    }
                    uint16_t tagLen = pt_mtl_read_le16(bytes + tagPos + 4ULL);
                    if (tagPos + 6ULL + (uint64_t)tagLen > entryEnd) {
                        break;
                    }
                    if (memcmp(bytes + tagPos, "VERS", 4) == 0 && tagLen >= 8U) {
                        uint16_t langMaj = pt_mtl_read_le16(bytes + tagPos + 10ULL);
                        uint16_t langMin = pt_mtl_read_le16(bytes + tagPos + 12ULL);
                        if (langMaj > 2U || (langMaj == 2U && langMin > 2U)) {
                            reject = YES;
                            break;
                        }
                    }
                    tagPos += 6ULL + (uint64_t)tagLen;
                }
                if (reject) {
                    break;
                }
                pos = entryEnd;
            }
        }
    }
    if (reject && outError != NULL) {
        *outError = [NSError errorWithDomain:@"MTLLibraryErrorDomain"
                                        code:1
                                    userInfo:@{
                                        NSLocalizedDescriptionKey : @"Unsupported Metal library version"
                                    }];
    }
    return reject;
}

static BOOL pt_mtl_should_reject_metallib_dispatch_data_for_compat13(id dataObj, NSError **outError) {
    if (!pt_is_bypass_enabled() || !pt_is_compat13_7_active() || dataObj == nil) {
        return NO;
    }
    dispatch_data_t ddata = (dispatch_data_t)dataObj;
    size_t total = dispatch_data_get_size(ddata);
    if (total < 40U) {
        return NO;
    }
    // Copy header (40 bytes) first to determine exact metadata extent
    uint8_t hdr[40];
    uint8_t *hdrPtr = hdr;
    size_t hdrLen = sizeof(hdr);
    __block size_t copied = 0;
    dispatch_data_apply(ddata, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
        (void)region;
        if (offset >= hdrLen) {
            return false;
        }
        size_t take = size;
        if (offset + take > hdrLen) {
            take = hdrLen - offset;
        }
        memcpy(hdrPtr + offset, buffer, take);
        if (offset + take > copied) {
            copied = offset + take;
        }
        return copied < hdrLen;
    });
    if (copied < sizeof(hdr) || memcmp(hdr, "MTLB", 4) != 0) {
        return NO;
    }
    if (hdr[10] == 2U) {
        return pt_mtl_should_reject_metallib_bytes_for_compat13(hdr, sizeof(hdr), outError);
    }
    uint64_t flOff = pt_mtl_read_le64(hdr + 24);
    uint64_t flSize = pt_mtl_read_le64(hdr + 32);
    size_t need = sizeof(hdr);
    if (flOff >= 40ULL && flOff < (uint64_t)total && flSize <= (2ULL * 1024ULL * 1024ULL)) {
        uint64_t end = flOff + 4ULL + flSize;
        if (end > (uint64_t)total) end = (uint64_t)total;
        if (end <= (2ULL * 1024ULL * 1024ULL)) {
            need = (size_t)end;
        }
    }
    uint8_t *buf = malloc(need);
    if (buf == NULL) {
        return NO;
    }
    __block size_t got = 0;
    dispatch_data_apply(ddata, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
        (void)region;
        if (offset >= need) {
            return false;
        }
        size_t take = size;
        if (offset + take > need) {
            take = need - offset;
        }
        memcpy(buf + offset, buffer, take);
        if (offset + take > got) {
            got = offset + take;
        }
        return got < need;
    });
    BOOL reject = pt_mtl_should_reject_metallib_bytes_for_compat13(buf, got, outError);
    free(buf);
    return reject;
}

static BOOL pt_mtl_should_reject_metallib_path_for_compat13(NSString *path, NSError **outError) {
    if (!pt_is_bypass_enabled() || !pt_is_compat13_7_active() || path.length == 0) {
        return NO;
    }
    NSString *resolved = ps_resolve_virtual_nsstring_path(path);
    const char *cpath = [resolved fileSystemRepresentation];
    if (cpath == NULL || cpath[0] == '\0') {
        return NO;
    }
    int fd = open(cpath, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return NO;
    }
    uint8_t hdr[40];
    ssize_t n = pread(fd, hdr, sizeof(hdr), 0);
    if (n < (ssize_t)sizeof(hdr) || memcmp(hdr, "MTLB", 4) != 0) {
        close(fd);
        return NO;
    }
    if (hdr[10] == 2U) {
        close(fd);
        return pt_mtl_should_reject_metallib_bytes_for_compat13(hdr, sizeof(hdr), outError);
    }
    struct stat st;
    uint64_t total = (fstat(fd, &st) == 0 && st.st_size > 0) ? (uint64_t)st.st_size : (uint64_t)n;
    uint64_t flOff = pt_mtl_read_le64(hdr + 24);
    uint64_t flSize = pt_mtl_read_le64(hdr + 32);
    size_t need = sizeof(hdr);
    if (flOff >= 40ULL && flOff < total && flSize <= (2ULL * 1024ULL * 1024ULL)) {
        uint64_t end = flOff + 4ULL + flSize;
        if (end > total) end = total;
        if (end <= (2ULL * 1024ULL * 1024ULL)) {
            need = (size_t)end;
        }
    }
    uint8_t *buf = malloc(need);
    if (buf == NULL) {
        close(fd);
        return NO;
    }
    size_t filled = 0;
    while (filled < need) {
        ssize_t r = pread(fd, buf + filled, need - filled, (off_t)filled);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        filled += (size_t)r;
    }
    close(fd);
    BOOL reject = pt_mtl_should_reject_metallib_bytes_for_compat13(buf, filled, outError);
    free(buf);
    return reject;
}

static void ps_swizzle_mtl_library_class(Class cls);
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

static NSString *pt_mtl_apply_ios_source_prefix(NSString *source) {
    if (source == nil || ![source isKindOfClass:[NSString class]]) {
        return source;
    }
    if ([source hasPrefix:@"#undef __METAL_MACOS__\n"]) {
        return source;
    }
    return [@"#undef __METAL_MACOS__\n#define __METAL_IOS__ 1\n#line 1\n" stringByAppendingString:source];
}

static NSString *pt_mtl_rewrite_source_for_apple5_32f(NSString *source, const void *caller) {
    if (source == nil || ![source isKindOfClass:[NSString class]] ||
        !pt_is_bypass_enabled() ||
        ps_is_effective_system_or_playtools_caller(caller) ||
        (!pt_is_compat13_7_active() && pt_get_spoofed_max_apple_gpu_family() >= 1007) ||
        ![source containsString:@"<float"]) {
        return nil;
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
        return nil;
    }
    NSArray<NSTextCheckingResult *> *matches =
        [s_constexprSamplerRegex matchesInString:source options:0 range:NSMakeRange(0, source.length)];
    if (matches.count == 0) {
        return nil;
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
    return rewritten;
}

static void pt_mtl_prepare_options_and_source(NSString *source,
                                              id options,
                                              const void *caller,
                                              NSString **outSource,
                                              id *outOptions,
                                              NSString **outNearestSource) {
    NSString *finalSource = source;
    NSString *nearestSource = nil;
    id finalOptions = options;
    if (pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        if (finalSource != nil && [finalSource isKindOfClass:[NSString class]]) {
            NSString *rewrittenNearest = pt_mtl_rewrite_source_for_apple5_32f(finalSource, caller);
            finalSource = pt_mtl_apply_ios_source_prefix(finalSource);
            if (rewrittenNearest != nil) {
                nearestSource = pt_mtl_apply_ios_source_prefix(rewrittenNearest);
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
    if (outNearestSource != NULL) {
        *outNearestSource = nearestSource;
    }
}

static void ps_mtl_attach_library_32f_info(id library, id device, NSString *nearestSource, id compileOptions) {
    if (library == nil || device == nil || nearestSource == nil) {
        return;
    }
    ps_swizzle_mtl_library_class(object_getClass(library));
    PSMTLLibrary32FInfo *info = [[PSMTLLibrary32FInfo alloc] init];
    info->_device = device;
    info->_nearestSource = [nearestSource copy];
    if (compileOptions != nil && [compileOptions respondsToSelector:@selector(copy)]) {
        info->_compileOptionsCopy = [compileOptions copy];
    }
    objc_setAssociatedObject(library, &kPSMTLLibrary32FInfoKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ps_mtl_attach_function_32f_info(id fn, id library, NSString *name, id constantValues) {
    if (fn == nil || library == nil || name == nil) {
        return;
    }
    PSMTLLibrary32FInfo *libInfo = objc_getAssociatedObject(library, &kPSMTLLibrary32FInfoKey);
    if (libInfo == nil) {
        return;
    }
    PSMTLFunction32FInfo *info = [[PSMTLFunction32FInfo alloc] init];
    info->_libInfo = libInfo;
    info->_name = [name copy];
    if (constantValues != nil && [constantValues respondsToSelector:@selector(copy)]) {
        info->_constantValuesCopy = [constantValues copy];
    }
    objc_setAssociatedObject(fn, &kPSMTLFunction32FInfoKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ps_mtl_attach_compute_pipeline_32f_info(id pipeline, id device, id function, id descriptor, BOOL hasOptions, NSUInteger options) {
    if (pipeline == nil || device == nil) {
        return;
    }
    id effectiveFn = function;
    if (effectiveFn == nil && descriptor != nil && [descriptor respondsToSelector:sel_registerName("computeFunction")]) {
        effectiveFn = ((id (*)(id, SEL))objc_msgSend)(descriptor, sel_registerName("computeFunction"));
    }
    PSMTLFunction32FInfo *fnInfo = (effectiveFn != nil) ? objc_getAssociatedObject(effectiveFn, &kPSMTLFunction32FInfoKey) : nil;
    if (fnInfo == nil) {
        return;
    }
    PSMTLPipeline32FInfo *info = [[PSMTLPipeline32FInfo alloc] init];
    info->_device = device;
    info->_isRender = NO;
    info->_computeFnInfo = fnInfo;
    if (descriptor != nil && [descriptor respondsToSelector:@selector(copy)]) {
        info->_descriptorCopy = [descriptor copy];
    }
    info->_hasOptions = hasOptions;
    info->_options = options;
    objc_setAssociatedObject(pipeline, &kPSMTLPipeline32FInfoKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void ps_mtl_attach_render_pipeline_32f_info(id pipeline, id device, id descriptor, BOOL hasOptions, NSUInteger options) {
    if (pipeline == nil || device == nil || descriptor == nil) {
        return;
    }
    id vFn = [descriptor respondsToSelector:sel_registerName("vertexFunction")]
        ? ((id (*)(id, SEL))objc_msgSend)(descriptor, sel_registerName("vertexFunction"))
        : nil;
    id fFn = [descriptor respondsToSelector:sel_registerName("fragmentFunction")]
        ? ((id (*)(id, SEL))objc_msgSend)(descriptor, sel_registerName("fragmentFunction"))
        : nil;
    PSMTLFunction32FInfo *vInfo = (vFn != nil) ? objc_getAssociatedObject(vFn, &kPSMTLFunction32FInfoKey) : nil;
    PSMTLFunction32FInfo *fInfo = (fFn != nil) ? objc_getAssociatedObject(fFn, &kPSMTLFunction32FInfoKey) : nil;
    if (vInfo == nil && fInfo == nil) {
        return;
    }
    PSMTLPipeline32FInfo *info = [[PSMTLPipeline32FInfo alloc] init];
    info->_device = device;
    info->_isRender = YES;
    info->_vertexFnInfo = vInfo;
    info->_fragmentFnInfo = fInfo;
    if ([descriptor respondsToSelector:@selector(copy)]) {
        info->_descriptorCopy = [descriptor copy];
    }
    info->_hasOptions = hasOptions;
    info->_options = options;
    objc_setAssociatedObject(pipeline, &kPSMTLPipeline32FInfoKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

static void ps_mtl_encoder_apply_pipeline(id encoder, PSMTLEncoderStage stage, id pipelineToBind) {
    if (encoder == nil || pipelineToBind == nil) {
        return;
    }
    CFMutableDictionaryRef dict = (stage == PSMTLEncoderStageCompute)
        ? s_mtl_orig_cenc_set_pipe_imps
        : s_mtl_orig_renc_set_pipe_imps;
    SEL sel = (stage == PSMTLEncoderStageCompute)
        ? sel_registerName("setComputePipelineState:")
        : sel_registerName("setRenderPipelineState:");
    if (dict == NULL) {
        return;
    }
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, dict, encoder, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, id))origIMP)(encoder, sel, pipelineToBind);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
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
    id currentPipeline = nil;
    BOOL switched32F = NO;
    BOOL nowHas32F = NO;
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
        switched32F = (had32F != has32F);
        nowHas32F = has32F;
        if (switched32F) {
            currentPipeline = state->_currentPipeline;
            if (state->_samplersByStageSlot.count > 0) {
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
    }
    for (NSUInteger i = 0; i + 2 < updates.count; i += 3) {
        uint64_t k = ((NSNumber *)updates[i]).unsignedLongLongValue;
        PSMTLEncoderStage s = (PSMTLEncoderStage)((k >> 32) & 0xFULL);
        NSUInteger idx = (NSUInteger)(k & 0xFFFFFFFFULL);
        ps_mtl_encoder_apply_sampler(encoder, s, idx, updates[i + 1], updates[i + 2]);
    }
    if (switched32F && currentPipeline != nil) {
        PSMTLPipeline32FInfo *pinfo = objc_getAssociatedObject(currentPipeline, &kPSMTLPipeline32FInfoKey);
        if (pinfo != nil) {
            id targetPipeline = nowHas32F ? ([pinfo nearestPipeline] ?: currentPipeline) : currentPipeline;
            ps_mtl_encoder_apply_pipeline(encoder, stage, targetPipeline);
        }
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

static int32_t pt_mtl_host_max_apple_family(id dev) {
    os_unfair_lock_lock(&s_mtl_host_fam_lock);
    int32_t cached = s_mtl_host_max_apple_family;
    os_unfair_lock_unlock(&s_mtl_host_fam_lock);
    if (cached > 0 || dev == nil) {
        return cached;
    }
    SEL sel = sel_registerName("supportsFamily:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_supports_family_imps, dev, &pushed);
    int32_t found = 0;
    if (origIMP != NULL) {
        @try {
            for (int32_t fam = 1010; fam >= 1001; fam--) {
                if (((BOOL (*)(id, SEL, NSInteger))origIMP)(dev, sel, (NSInteger)fam)) {
                    found = fam;
                    break;
                }
            }
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (found > 0) {
        os_unfair_lock_lock(&s_mtl_host_fam_lock);
        if (s_mtl_host_max_apple_family == 0) {
            s_mtl_host_max_apple_family = found;
        }
        cached = s_mtl_host_max_apple_family;
        os_unfair_lock_unlock(&s_mtl_host_fam_lock);
    }
    return cached;
}

static int32_t pt_mtl_effective_max_apple_gpu_family(id dev) {
    int32_t profileFam = pt_get_spoofed_max_apple_gpu_family();
    int32_t hostFam = pt_mtl_host_max_apple_family(dev);
    if (hostFam > 0 && profileFam > hostFam) {
        return hostFam;
    }
    return profileFam;
}

static BOOL pt_mtl_effective_gpu_identity_override(id dev,
                                                   NSString **outName,
                                                   NSString **outArch,
                                                   const char **outGen) {
    int32_t profileFam = pt_get_spoofed_max_apple_gpu_family();
    int32_t hostFam = pt_mtl_host_max_apple_family(dev);
    if (hostFam <= 0 || hostFam >= profileFam) {
        return NO;
    }
    NSString *name = nil;
    NSString *arch = nil;
    const char *gen = NULL;
    if (hostFam <= 1007) {
        name = @"Apple A14 GPU";
        arch = @"applegpu_g13p";
        gen = "G13P";
    } else if (hostFam == 1008) {
        name = @"Apple A16 GPU";
        arch = @"applegpu_g15p";
        gen = "G15P";
    } else if (hostFam == 1009) {
        name = @"Apple A18 Pro GPU";
        arch = @"applegpu_g17p";
        gen = "G17P";
    } else {
        return NO;
    }
    if (outName != NULL) *outName = name;
    if (outArch != NULL) *outArch = arch;
    if (outGen != NULL) *outGen = gen;
    return YES;
}

static uint64_t ps_mtl_spoofed_ram_bytes(void) {
    uint64_t mem = pt_get_spoofed_physical_memory();
    if (mem == 0) {
        mem = (uint64_t)[[NSProcessInfo processInfo] physicalMemory];
    }
    return mem;
}

static uint64_t ps_mtl_memory_cap(void) {
    return (ps_mtl_spoofed_ram_bytes() * 3ULL) / 4ULL;
}

static uint64_t ps_mtl_max_buffer_cap(void) {
    // iOS Metal maxBufferLength ceiling is ~50% of physical RAM
    return ps_mtl_spoofed_ram_bytes() / 2ULL;
}

static NSString *pt_mtl_spoofed_gpu_name_string(void) {
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

static NSString *pt_mtl_spoofed_gpu_name_string_for_device(id dev) {
    NSString *overrideName = nil;
    if (pt_mtl_effective_gpu_identity_override(dev, &overrideName, NULL, NULL) &&
        overrideName.length > 0) {
        return overrideName;
    }
    return pt_mtl_spoofed_gpu_name_string();
}

static NSString *ps_mtl_sanitize_device_description(id dev, NSString *rawDesc) {
    if (rawDesc.length == 0) {
        return rawDesc;
    }
    const pt_device_profile_t *prof = pt_get_active_device_profile();
    const char *gpuGen = (prof != NULL && prof->gpu_gen != NULL && prof->gpu_gen[0] != '\0')
        ? prof->gpu_gen
        : "G13G";
    NSString *overrideName = nil;
    const char *overrideGen = NULL;
    if (pt_mtl_effective_gpu_identity_override(dev, &overrideName, NULL, &overrideGen) &&
        overrideGen != NULL && overrideGen[0] != '\0') {
        gpuGen = overrideGen;
    }
    NSString *spoofedClassTag = [NSString stringWithFormat:@"AGX%sDevice", gpuGen];
    NSString *spoofedGpuName = (overrideName.length > 0) ? overrideName : pt_mtl_spoofed_gpu_name_string();

    static NSRegularExpression *s_agxTagRe = nil;
    static NSRegularExpression *s_nameLineRe = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_agxTagRe = [NSRegularExpression
            regularExpressionWithPattern:@"\\bAGX(?:Metal)?G[0-9]+[A-Za-z0-9_]*Device\\b"
                                 options:0
                                   error:nil];
        s_nameLineRe = [NSRegularExpression
            regularExpressionWithPattern:@"^([ \\t]*name[ \\t]*=[ \\t]*)([^\\r\\n]+)$"
                                 options:NSRegularExpressionAnchorsMatchLines
                                   error:nil];
    });

    NSString *res = rawDesc;
    if (s_agxTagRe != nil) {
        NSString *escapedTag = [NSRegularExpression escapedTemplateForString:spoofedClassTag];
        res = [s_agxTagRe stringByReplacingMatchesInString:res
                                                   options:0
                                                     range:NSMakeRange(0, res.length)
                                              withTemplate:escapedTag];
    }
    if (s_nameLineRe != nil) {
        NSString *escapedName = [NSRegularExpression escapedTemplateForString:spoofedGpuName];
        res = [s_nameLineRe stringByReplacingMatchesInString:res
                                                     options:0
                                                       range:NSMakeRange(0, res.length)
                                                withTemplate:[NSString stringWithFormat:@"$1%@", escapedName]];
    }
    // Also scrub any raw host device name occurrences outside the `name = ...` line
    if (dev != nil) {
        BOOL pushed = NO;
        IMP origNameIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_name_imps, dev, &pushed);
        NSString *rawName = nil;
        if (origNameIMP != NULL) {
            @try {
                rawName = ((NSString *(*)(id, SEL))origNameIMP)(dev, @selector(name));
            } @finally {
                ps_pop_orig_imp_frame(pushed);
            }
        }
        if (rawName.length > 0 &&
            ![rawName isEqualToString:spoofedGpuName] &&
            ![spoofedGpuName containsString:rawName]) {
            res = [res stringByReplacingOccurrencesOfString:rawName withString:spoofedGpuName];
        }
    }
    return res;
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
    return pt_mtl_spoofed_gpu_name_string_for_device(self);
}

- (NSString *) pm_ps_mtl_description {
    const void *caller = __builtin_return_address(0);
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_description_imps, self, &pushed);
    NSString *orig = nil;
    if (origIMP != NULL) {
        @try {
            orig = ((NSString *(*)(id, SEL))origIMP)(self, @selector(description));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (orig.length > 0 && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        return ps_mtl_sanitize_device_description(self, orig);
    }
    return orig;
}

- (NSString *) pm_ps_mtl_debugDescription {
    const void *caller = __builtin_return_address(0);
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_debug_description_imps, self, &pushed);
    NSString *orig = nil;
    if (origIMP != NULL) {
        @try {
            orig = ((NSString *(*)(id, SEL))origIMP)(self, @selector(debugDescription));
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (orig.length > 0 && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        return ps_mtl_sanitize_device_description(self, orig);
    }
    return orig;
}

- (NSString *) pm_ps_mtl_formattedDescription:(NSUInteger)indent {
    const void *caller = __builtin_return_address(0);
    SEL sel = sel_registerName("formattedDescription:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_formatted_description_imps, self, &pushed);
    NSString *orig = nil;
    if (origIMP != NULL) {
        @try {
            orig = ((NSString *(*)(id, SEL, NSUInteger))origIMP)(self, sel, indent);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (orig.length > 0 && pt_is_bypass_enabled() && !ps_is_effective_system_or_playtools_caller(caller)) {
        return ps_mtl_sanitize_device_description(self, orig);
    }
    return orig;
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
        uint64_t mem = ps_mtl_spoofed_ram_bytes();
        uint64_t cap = ps_mtl_memory_cap();
        uint64_t floorVal = (mem * 5ULL) / 8ULL;
        if (cap > 0 && orig > cap) {
            return cap;
        }
        if (floorVal > 0 && orig < floorVal) {
            return (mem * 2ULL) / 3ULL;
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
        uint64_t cap = ps_mtl_max_buffer_cap();
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
        int32_t maxAppleFam = pt_mtl_effective_max_apple_gpu_family(self);
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
        int32_t maxAppleFam = pt_mtl_effective_max_apple_gpu_family(self);
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
        (pt_is_compat13_7_active() || pt_mtl_effective_max_apple_gpu_family(self) < 1007)) {
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
        (pt_is_compat13_7_active() || pt_mtl_effective_max_apple_gpu_family(self) < 1007)) {
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
        (pt_is_compat13_7_active() || pt_mtl_effective_max_apple_gpu_family(self) < 1007)) {
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
        (pt_is_compat13_7_active() || pt_mtl_effective_max_apple_gpu_family(self) < 1007)) {
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
        (pt_is_compat13_7_active() || pt_mtl_effective_max_apple_gpu_family(self) < 1006)) {
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
        (pt_is_compat13_7_active() || pt_mtl_effective_max_apple_gpu_family(self) < 1006)) {
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
        (pt_is_compat13_7_active() || pt_mtl_effective_max_apple_gpu_family(self) < 1006)) {
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
        (pt_is_compat13_7_active() || pt_mtl_effective_max_apple_gpu_family(self) < 1006)) {
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
        (pt_is_compat13_7_active() || pt_mtl_effective_max_apple_gpu_family(self) < 1007)) {
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
        (pt_is_compat13_7_active() || pt_mtl_effective_max_apple_gpu_family(self) < 1007)) {
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

- (BOOL) pm_ps_mtl_areBarycentricCoordsSupported {
    if (pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        (pt_is_compat13_7_active() || pt_mtl_effective_max_apple_gpu_family(self) < 1007)) {
        return NO;
    }
    SEL sel = sel_registerName("areBarycentricCoordsSupported");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_are_barycentric_imps, self, &pushed);
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
        (pt_is_compat13_7_active() || pt_mtl_effective_max_apple_gpu_family(self) < 1004)) {
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
        (pt_is_compat13_7_active() || pt_mtl_effective_max_apple_gpu_family(self) < 1007)) {
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
        (pt_is_compat13_7_active() || pt_mtl_effective_max_apple_gpu_family(self) < 1005)) {
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
        pt_mtl_effective_max_apple_gpu_family(self) <= 1005) {
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
        pt_mtl_effective_max_apple_gpu_family(self) <= 1003) {
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
        pt_mtl_effective_max_apple_gpu_family(self) <= 1006) {
        return 0U; // MTLArgumentBuffersTier1 (Apple6/A13 and older)
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
        pt_mtl_effective_max_apple_gpu_family(self) <= 1003) {
        return 0U; // MTLReadWriteTextureTierNone (Apple3/A9X and older)
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
        pt_mtl_effective_max_apple_gpu_family(self) <= 1003) {
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
        pt_mtl_effective_max_apple_gpu_family(self) <= 1003) {
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
        NSString *overrideArch = nil;
        if (pt_mtl_effective_gpu_identity_override(nil, NULL, &overrideArch, NULL) &&
            overrideArch.length > 0) {
            return overrideArch;
        }
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
    (void)pt_mtl_host_max_apple_family(self);
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
    NSString *nearestSource = nil;
    id compileOptionsCopy = nil;
    BOOL appCaller = !ps_is_effective_system_or_playtools_caller(caller);
    if (appCaller) {
        NSError *rejectError = nil;
        if (pt_mtl_should_reject_source_for_compat13(source, options, &rejectError)) {
            if (error != NULL) {
                *error = rejectError;
            }
            return nil;
        }
        pt_mtl_prepare_options_and_source(source, options, caller, &source, &options, &nearestSource);
        if (nearestSource != nil && options != nil && [options respondsToSelector:@selector(copy)]) {
            compileOptionsCopy = [options copy];
        }
    }
    SEL sel = sel_registerName("newLibraryWithSource:options:error:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_lib_sync_imps, self, &pushed);
    id lib = nil;
    if (origIMP != NULL) {
        typedef id (*PTMTLNewLibSyncOrigFn)(id, SEL, NSString *, id, NSError **) NS_RETURNS_RETAINED;
        @try {
            lib = ((PTMTLNewLibSyncOrigFn)origIMP)(self, sel, source, options, error);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (appCaller && lib != nil && nearestSource != nil) {
        ps_mtl_attach_library_32f_info(lib, self, nearestSource, compileOptionsCopy);
    }
    return lib;
}

- (void) pm_ps_mtl_newLibraryWithSource:(NSString *)source
                                options:(id)options
                      completionHandler:(void (^)(id library, NSError *error))completionHandler {
    const void *caller = __builtin_return_address(0);
    NSString *nearestSource = nil;
    id compileOptionsCopy = nil;
    BOOL appCaller = !ps_is_effective_system_or_playtools_caller(caller);
    if (appCaller) {
        NSError *rejectError = nil;
        if (pt_mtl_should_reject_source_for_compat13(source, options, &rejectError)) {
            if (completionHandler != nil) {
                completionHandler(nil, rejectError);
            }
            return;
        }
        pt_mtl_prepare_options_and_source(source, options, caller, &source, &options, &nearestSource);
        if (nearestSource != nil && options != nil && [options respondsToSelector:@selector(copy)]) {
            compileOptionsCopy = [options copy];
        }
    }
    void (^effectiveHandler)(id, NSError *) = completionHandler;
    if (appCaller && nearestSource != nil && completionHandler != nil) {
        id dev = self;
        void (^origHandler)(id, NSError *) = [completionHandler copy];
        effectiveHandler = ^(id library, NSError *error) {
            if (library != nil) {
                ps_mtl_attach_library_32f_info(library, dev, nearestSource, compileOptionsCopy);
            }
            origHandler(library, error);
        };
    }
    SEL sel = sel_registerName("newLibraryWithSource:options:completionHandler:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_lib_async_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, NSString *, id, id))origIMP)(self, sel, source, options, effectiveHandler);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
}

- (id) pm_ps_mtl_newLibraryWithData:(id)data error:(NSError **)error NS_RETURNS_RETAINED {
    const void *caller = __builtin_return_address(0);
    if (!ps_is_effective_system_or_playtools_caller(caller)) {
        NSError *rejectError = nil;
        if (pt_mtl_should_reject_metallib_dispatch_data_for_compat13(data, &rejectError)) {
            if (error != NULL) {
                *error = rejectError;
            }
            return nil;
        }
    }
    SEL sel = sel_registerName("newLibraryWithData:error:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_lib_data_imps, self, &pushed);
    if (origIMP != NULL) {
        typedef id (*Fn)(id, SEL, id, NSError **) NS_RETURNS_RETAINED;
        @try {
            return ((Fn)origIMP)(self, sel, data, error);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return nil;
}

- (id) pm_ps_mtl_newLibraryWithURL:(NSURL *)url error:(NSError **)error NS_RETURNS_RETAINED {
    const void *caller = __builtin_return_address(0);
    if (!ps_is_effective_system_or_playtools_caller(caller) && [url isKindOfClass:[NSURL class]] && [url isFileURL]) {
        NSError *rejectError = nil;
        if (pt_mtl_should_reject_metallib_path_for_compat13(url.path, &rejectError)) {
            if (error != NULL) {
                *error = rejectError;
            }
            return nil;
        }
    }
    SEL sel = sel_registerName("newLibraryWithURL:error:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_lib_url_imps, self, &pushed);
    if (origIMP != NULL) {
        typedef id (*Fn)(id, SEL, NSURL *, NSError **) NS_RETURNS_RETAINED;
        @try {
            return ((Fn)origIMP)(self, sel, url, error);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return nil;
}

- (id) pm_ps_mtl_newLibraryWithFile:(NSString *)filepath error:(NSError **)error NS_RETURNS_RETAINED {
    const void *caller = __builtin_return_address(0);
    if (!ps_is_effective_system_or_playtools_caller(caller) && [filepath isKindOfClass:[NSString class]]) {
        NSError *rejectError = nil;
        if (pt_mtl_should_reject_metallib_path_for_compat13(filepath, &rejectError)) {
            if (error != NULL) {
                *error = rejectError;
            }
            return nil;
        }
    }
    SEL sel = sel_registerName("newLibraryWithFile:error:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_lib_file_imps, self, &pushed);
    if (origIMP != NULL) {
        typedef id (*Fn)(id, SEL, NSString *, NSError **) NS_RETURNS_RETAINED;
        @try {
            return ((Fn)origIMP)(self, sel, filepath, error);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    return nil;
}

- (id) pm_ps_mtl_lib_newFunctionWithName:(NSString *)name NS_RETURNS_RETAINED {
    const void *caller = __builtin_return_address(0);
    BOOL appCaller = !ps_is_effective_system_or_playtools_caller(caller);
    SEL sel = sel_registerName("newFunctionWithName:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_lib_new_fn_imps, self, &pushed);
    id fn = nil;
    if (origIMP != NULL) {
        typedef id (*PTMTLLibNewFnOrigFn)(id, SEL, NSString *) NS_RETURNS_RETAINED;
        @try {
            fn = ((PTMTLLibNewFnOrigFn)origIMP)(self, sel, name);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (appCaller && fn != nil) {
        ps_mtl_attach_function_32f_info(fn, self, name, nil);
    }
    return fn;
}

- (id) pm_ps_mtl_lib_newFunctionWithName:(NSString *)name
                          constantValues:(id)constantValues
                                   error:(NSError **)error NS_RETURNS_RETAINED {
    const void *caller = __builtin_return_address(0);
    BOOL appCaller = !ps_is_effective_system_or_playtools_caller(caller);
    SEL sel = sel_registerName("newFunctionWithName:constantValues:error:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_lib_new_fn_const_imps, self, &pushed);
    id fn = nil;
    if (origIMP != NULL) {
        typedef id (*PTMTLLibNewFnConstOrigFn)(id, SEL, NSString *, id, NSError **) NS_RETURNS_RETAINED;
        @try {
            fn = ((PTMTLLibNewFnConstOrigFn)origIMP)(self, sel, name, constantValues, error);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (appCaller && fn != nil) {
        ps_mtl_attach_function_32f_info(fn, self, name, constantValues);
    }
    return fn;
}

- (void) pm_ps_mtl_lib_newFunctionWithName:(NSString *)name
                            constantValues:(id)constantValues
                         completionHandler:(void (^)(id function, NSError *error))completionHandler {
    const void *caller = __builtin_return_address(0);
    BOOL appCaller = !ps_is_effective_system_or_playtools_caller(caller);
    void (^effectiveHandler)(id, NSError *) = completionHandler;
    if (appCaller && completionHandler != nil &&
        objc_getAssociatedObject(self, &kPSMTLLibrary32FInfoKey) != nil) {
        id lib = self;
        NSString *nameCopy = [name copy];
        id constCopy = [constantValues respondsToSelector:@selector(copy)] ? [constantValues copy] : constantValues;
        void (^origHandler)(id, NSError *) = [completionHandler copy];
        effectiveHandler = ^(id fn, NSError *error) {
            if (fn != nil) {
                ps_mtl_attach_function_32f_info(fn, lib, nameCopy, constCopy);
            }
            origHandler(fn, error);
        };
    }
    SEL sel = sel_registerName("newFunctionWithName:constantValues:completionHandler:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_lib_new_fn_const_async_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, NSString *, id, id))origIMP)(self, sel, name, constantValues, effectiveHandler);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
}

- (id) pm_ps_mtl_newComputePipelineStateWithFunction:(id)function error:(NSError **)error NS_RETURNS_RETAINED {
    const void *caller = __builtin_return_address(0);
    BOOL appCaller = !ps_is_effective_system_or_playtools_caller(caller);
    SEL sel = sel_registerName("newComputePipelineStateWithFunction:error:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_comp_pipe_fn_imps, self, &pushed);
    id pipe = nil;
    if (origIMP != NULL) {
        typedef id (*Fn)(id, SEL, id, NSError **) NS_RETURNS_RETAINED;
        @try {
            pipe = ((Fn)origIMP)(self, sel, function, error);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (appCaller && pipe != nil) {
        ps_mtl_attach_compute_pipeline_32f_info(pipe, self, function, nil, NO, 0U);
    }
    return pipe;
}

- (void) pm_ps_mtl_newComputePipelineStateWithFunction:(id)function
                                     completionHandler:(void (^)(id pipeline, NSError *error))completionHandler {
    const void *caller = __builtin_return_address(0);
    BOOL appCaller = !ps_is_effective_system_or_playtools_caller(caller);
    void (^effectiveHandler)(id, NSError *) = completionHandler;
    if (appCaller && completionHandler != nil &&
        function != nil && objc_getAssociatedObject(function, &kPSMTLFunction32FInfoKey) != nil) {
        id dev = self;
        void (^origHandler)(id, NSError *) = [completionHandler copy];
        effectiveHandler = ^(id pipe, NSError *error) {
            if (pipe != nil) {
                ps_mtl_attach_compute_pipeline_32f_info(pipe, dev, function, nil, NO, 0U);
            }
            origHandler(pipe, error);
        };
    }
    SEL sel = sel_registerName("newComputePipelineStateWithFunction:completionHandler:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_comp_pipe_fn_async_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, id, id))origIMP)(self, sel, function, effectiveHandler);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
}

- (id) pm_ps_mtl_newComputePipelineStateWithFunction:(id)function
                                             options:(NSUInteger)options
                                          reflection:(id __autoreleasing *)reflection
                                               error:(NSError **)error NS_RETURNS_RETAINED {
    const void *caller = __builtin_return_address(0);
    BOOL appCaller = !ps_is_effective_system_or_playtools_caller(caller);
    SEL sel = sel_registerName("newComputePipelineStateWithFunction:options:reflection:error:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_comp_pipe_fn_opts_imps, self, &pushed);
    id pipe = nil;
    if (origIMP != NULL) {
        typedef id (*Fn)(id, SEL, id, NSUInteger, id __autoreleasing *, NSError **) NS_RETURNS_RETAINED;
        @try {
            pipe = ((Fn)origIMP)(self, sel, function, options, reflection, error);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (appCaller && pipe != nil) {
        ps_mtl_attach_compute_pipeline_32f_info(pipe, self, function, nil, YES, options);
    }
    return pipe;
}

- (void) pm_ps_mtl_newComputePipelineStateWithFunction:(id)function
                                               options:(NSUInteger)options
                                     completionHandler:(void (^)(id pipeline, id reflection, NSError *error))completionHandler {
    const void *caller = __builtin_return_address(0);
    BOOL appCaller = !ps_is_effective_system_or_playtools_caller(caller);
    void (^effectiveHandler)(id, id, NSError *) = completionHandler;
    if (appCaller && completionHandler != nil &&
        function != nil && objc_getAssociatedObject(function, &kPSMTLFunction32FInfoKey) != nil) {
        id dev = self;
        void (^origHandler)(id, id, NSError *) = [completionHandler copy];
        effectiveHandler = ^(id pipe, id refl, NSError *error) {
            if (pipe != nil) {
                ps_mtl_attach_compute_pipeline_32f_info(pipe, dev, function, nil, YES, options);
            }
            origHandler(pipe, refl, error);
        };
    }
    SEL sel = sel_registerName("newComputePipelineStateWithFunction:options:completionHandler:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_comp_pipe_fn_opts_async_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, id, NSUInteger, id))origIMP)(self, sel, function, options, effectiveHandler);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
}

- (id) pm_ps_mtl_newComputePipelineStateWithDescriptor:(id)descriptor
                                                 error:(NSError **)error NS_RETURNS_RETAINED {
    const void *caller = __builtin_return_address(0);
    BOOL appCaller = !ps_is_effective_system_or_playtools_caller(caller);
    SEL sel = sel_registerName("newComputePipelineStateWithDescriptor:error:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_comp_pipe_desc_imps, self, &pushed);
    id pipe = nil;
    if (origIMP != NULL) {
        typedef id (*Fn)(id, SEL, id, NSError **) NS_RETURNS_RETAINED;
        @try {
            pipe = ((Fn)origIMP)(self, sel, descriptor, error);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (appCaller && pipe != nil) {
        ps_mtl_attach_compute_pipeline_32f_info(pipe, self, nil, descriptor, NO, 0U);
    }
    return pipe;
}

- (void) pm_ps_mtl_newComputePipelineStateWithDescriptor:(id)descriptor
                                       completionHandler:(void (^)(id pipeline, NSError *error))completionHandler {
    const void *caller = __builtin_return_address(0);
    BOOL appCaller = !ps_is_effective_system_or_playtools_caller(caller);
    void (^effectiveHandler)(id, NSError *) = completionHandler;
    if (appCaller && completionHandler != nil && descriptor != nil) {
        id dev = self;
        id descCopy = [descriptor respondsToSelector:@selector(copy)] ? [descriptor copy] : descriptor;
        void (^origHandler)(id, NSError *) = [completionHandler copy];
        effectiveHandler = ^(id pipe, NSError *error) {
            if (pipe != nil) {
                ps_mtl_attach_compute_pipeline_32f_info(pipe, dev, nil, descCopy, NO, 0U);
            }
            origHandler(pipe, error);
        };
    }
    SEL sel = sel_registerName("newComputePipelineStateWithDescriptor:completionHandler:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_comp_pipe_desc_async_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, id, id))origIMP)(self, sel, descriptor, effectiveHandler);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
}

- (id) pm_ps_mtl_newComputePipelineStateWithDescriptor:(id)descriptor
                                               options:(NSUInteger)options
                                            reflection:(id __autoreleasing *)reflection
                                                 error:(NSError **)error NS_RETURNS_RETAINED {
    const void *caller = __builtin_return_address(0);
    BOOL appCaller = !ps_is_effective_system_or_playtools_caller(caller);
    SEL sel = sel_registerName("newComputePipelineStateWithDescriptor:options:reflection:error:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_comp_pipe_desc_opts_imps, self, &pushed);
    id pipe = nil;
    if (origIMP != NULL) {
        typedef id (*Fn)(id, SEL, id, NSUInteger, id __autoreleasing *, NSError **) NS_RETURNS_RETAINED;
        @try {
            pipe = ((Fn)origIMP)(self, sel, descriptor, options, reflection, error);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (appCaller && pipe != nil) {
        ps_mtl_attach_compute_pipeline_32f_info(pipe, self, nil, descriptor, YES, options);
    }
    return pipe;
}

- (void) pm_ps_mtl_newComputePipelineStateWithDescriptor:(id)descriptor
                                                 options:(NSUInteger)options
                                       completionHandler:(void (^)(id pipeline, id reflection, NSError *error))completionHandler {
    const void *caller = __builtin_return_address(0);
    BOOL appCaller = !ps_is_effective_system_or_playtools_caller(caller);
    void (^effectiveHandler)(id, id, NSError *) = completionHandler;
    if (appCaller && completionHandler != nil && descriptor != nil) {
        id dev = self;
        id descCopy = [descriptor respondsToSelector:@selector(copy)] ? [descriptor copy] : descriptor;
        void (^origHandler)(id, id, NSError *) = [completionHandler copy];
        effectiveHandler = ^(id pipe, id refl, NSError *error) {
            if (pipe != nil) {
                ps_mtl_attach_compute_pipeline_32f_info(pipe, dev, nil, descCopy, YES, options);
            }
            origHandler(pipe, refl, error);
        };
    }
    SEL sel = sel_registerName("newComputePipelineStateWithDescriptor:options:completionHandler:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_comp_pipe_desc_opts_async_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, id, NSUInteger, id))origIMP)(self, sel, descriptor, options, effectiveHandler);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
}

- (id) pm_ps_mtl_newRenderPipelineStateWithDescriptor:(id)descriptor error:(NSError **)error NS_RETURNS_RETAINED {
    const void *caller = __builtin_return_address(0);
    BOOL appCaller = !ps_is_effective_system_or_playtools_caller(caller);
    SEL sel = sel_registerName("newRenderPipelineStateWithDescriptor:error:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_rend_pipe_desc_imps, self, &pushed);
    id pipe = nil;
    if (origIMP != NULL) {
        typedef id (*Fn)(id, SEL, id, NSError **) NS_RETURNS_RETAINED;
        @try {
            pipe = ((Fn)origIMP)(self, sel, descriptor, error);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (appCaller && pipe != nil) {
        ps_mtl_attach_render_pipeline_32f_info(pipe, self, descriptor, NO, 0U);
    }
    return pipe;
}

- (void) pm_ps_mtl_newRenderPipelineStateWithDescriptor:(id)descriptor
                                      completionHandler:(void (^)(id pipeline, NSError *error))completionHandler {
    const void *caller = __builtin_return_address(0);
    BOOL appCaller = !ps_is_effective_system_or_playtools_caller(caller);
    void (^effectiveHandler)(id, NSError *) = completionHandler;
    if (appCaller && completionHandler != nil && descriptor != nil) {
        id dev = self;
        id descCopy = [descriptor respondsToSelector:@selector(copy)] ? [descriptor copy] : descriptor;
        void (^origHandler)(id, NSError *) = [completionHandler copy];
        effectiveHandler = ^(id pipe, NSError *error) {
            if (pipe != nil) {
                ps_mtl_attach_render_pipeline_32f_info(pipe, dev, descCopy, NO, 0U);
            }
            origHandler(pipe, error);
        };
    }
    SEL sel = sel_registerName("newRenderPipelineStateWithDescriptor:completionHandler:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_rend_pipe_desc_async_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, id, id))origIMP)(self, sel, descriptor, effectiveHandler);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
}

- (id) pm_ps_mtl_newRenderPipelineStateWithDescriptor:(id)descriptor
                                              options:(NSUInteger)options
                                           reflection:(id __autoreleasing *)reflection
                                                error:(NSError **)error NS_RETURNS_RETAINED {
    const void *caller = __builtin_return_address(0);
    BOOL appCaller = !ps_is_effective_system_or_playtools_caller(caller);
    SEL sel = sel_registerName("newRenderPipelineStateWithDescriptor:options:reflection:error:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_rend_pipe_desc_opts_imps, self, &pushed);
    id pipe = nil;
    if (origIMP != NULL) {
        typedef id (*Fn)(id, SEL, id, NSUInteger, id __autoreleasing *, NSError **) NS_RETURNS_RETAINED;
        @try {
            pipe = ((Fn)origIMP)(self, sel, descriptor, options, reflection, error);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
    if (appCaller && pipe != nil) {
        ps_mtl_attach_render_pipeline_32f_info(pipe, self, descriptor, YES, options);
    }
    return pipe;
}

- (void) pm_ps_mtl_newRenderPipelineStateWithDescriptor:(id)descriptor
                                                options:(NSUInteger)options
                                      completionHandler:(void (^)(id pipeline, id reflection, NSError *error))completionHandler {
    const void *caller = __builtin_return_address(0);
    BOOL appCaller = !ps_is_effective_system_or_playtools_caller(caller);
    void (^effectiveHandler)(id, id, NSError *) = completionHandler;
    if (appCaller && completionHandler != nil && descriptor != nil) {
        id dev = self;
        id descCopy = [descriptor respondsToSelector:@selector(copy)] ? [descriptor copy] : descriptor;
        void (^origHandler)(id, id, NSError *) = [completionHandler copy];
        effectiveHandler = ^(id pipe, id refl, NSError *error) {
            if (pipe != nil) {
                ps_mtl_attach_render_pipeline_32f_info(pipe, dev, descCopy, YES, options);
            }
            origHandler(pipe, refl, error);
        };
    }
    SEL sel = sel_registerName("newRenderPipelineStateWithDescriptor:options:completionHandler:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_new_rend_pipe_desc_opts_async_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, id, NSUInteger, id))origIMP)(self, sel, descriptor, options, effectiveHandler);
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

- (void) pm_ps_mtl_cenc_setComputePipelineState:(id)pipeline {
    const void *caller = __builtin_return_address(0);
    id effPipeline = pipeline;
    if (pipeline != nil &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(caller) &&
        (pt_is_compat13_7_active() || pt_get_spoofed_max_apple_gpu_family() < 1007)) {
        PSMTLPipeline32FInfo *pinfo = objc_getAssociatedObject(pipeline, &kPSMTLPipeline32FInfoKey);
        PSMTLEncoderBindingState *state = ps_mtl_encoder_state(self, (pinfo != nil));
        if (state != nil) {
            BOOL has32F = NO;
            @synchronized (state) {
                state->_currentPipeline = pipeline;
                has32F = (state->_tex32FSlots.count > 0);
            }
            if (has32F && pinfo != nil) {
                effPipeline = [pinfo nearestPipeline] ?: pipeline;
            }
        }
    }
    SEL sel = sel_registerName("setComputePipelineState:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_cenc_set_pipe_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, id))origIMP)(self, sel, effPipeline);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
    }
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

- (void) pm_ps_mtl_renc_setRenderPipelineState:(id)pipeline {
    const void *caller = __builtin_return_address(0);
    id effPipeline = pipeline;
    if (pipeline != nil &&
        pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(caller) &&
        (pt_is_compat13_7_active() || pt_get_spoofed_max_apple_gpu_family() < 1007)) {
        PSMTLPipeline32FInfo *pinfo = objc_getAssociatedObject(pipeline, &kPSMTLPipeline32FInfoKey);
        PSMTLEncoderBindingState *state = ps_mtl_encoder_state(self, (pinfo != nil));
        if (state != nil) {
            BOOL has32F = NO;
            @synchronized (state) {
                state->_currentPipeline = pipeline;
                has32F = (state->_tex32FSlots.count > 0);
            }
            if (has32F && pinfo != nil) {
                effPipeline = [pinfo nearestPipeline] ?: pipeline;
            }
        }
    }
    SEL sel = sel_registerName("setRenderPipelineState:");
    BOOL pushed = NO;
    IMP origIMP = ps_lookup_orig_imp_and_push(&s_mtl_swizzle_lock, s_mtl_orig_renc_set_pipe_imps, self, &pushed);
    if (origIMP != NULL) {
        @try {
            ((void (*)(id, SEL, id))origIMP)(self, sel, effPipeline);
        } @finally {
            ps_pop_orig_imp_frame(pushed);
        }
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

static void ps_swizzle_mtl_device_sel_avoiding_nsobject(CFMutableDictionaryRef *dictPtr,
                                                        Class cls,
                                                        SEL origSel,
                                                        SEL hookSel) {
    if (cls == Nil || origSel == NULL || hookSel == NULL) {
        return;
    }
    Class nsObjCls = [NSObject class];
    BOOL definedBelowNSObject = NO;
    for (Class c = cls; c != Nil && c != nsObjCls; c = class_getSuperclass(c)) {
        if (ps_class_defines_instance_method(c, origSel)) {
            definedBelowNSObject = YES;
            break;
        }
    }
    if (definedBelowNSObject) {
        ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, dictPtr, cls, origSel, hookSel);
        return;
    }
    // Method is inherited from NSObject; add wrapper directly on cls so NSObject itself is untouched
    Method origMethod = class_getInstanceMethod(cls, origSel);
    Method hookMethod = class_getInstanceMethod([PSSwizzleHooks class], hookSel);
    if (origMethod == NULL || hookMethod == NULL) {
        return;
    }
    IMP origIMP = method_getImplementation(origMethod);
    IMP hookIMP = method_getImplementation(hookMethod);
    if (origIMP == NULL || hookIMP == NULL || origIMP == hookIMP) {
        return;
    }
    BOOL added = NO;
    os_unfair_lock_lock(&s_mtl_swizzle_lock);
    if (*dictPtr == NULL) {
        *dictPtr = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
    }
    if (*dictPtr != NULL && !CFDictionaryContainsKey(*dictPtr, (__bridge const void *)cls)) {
        CFDictionarySetValue(*dictPtr, (__bridge const void *)cls, (const void *)origIMP);
        added = class_addMethod(cls, origSel, hookIMP, method_getTypeEncoding(origMethod));
    }
    os_unfair_lock_unlock(&s_mtl_swizzle_lock);
    if (added) {
        pt_register_swizzled_imp((const void *)hookIMP, (const void *)origIMP);
    }
}

static void ps_swizzle_mtl_device_class(Class cls) {
    if (cls == Nil) {
        return;
    }
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_name_imps, cls,
                                     @selector(name), @selector(pm_mtl_device_name));
    ps_swizzle_mtl_device_sel_avoiding_nsobject(&s_mtl_orig_description_imps, cls,
                                                @selector(description), @selector(pm_ps_mtl_description));
    ps_swizzle_mtl_device_sel_avoiding_nsobject(&s_mtl_orig_debug_description_imps, cls,
                                                @selector(debugDescription), @selector(pm_ps_mtl_debugDescription));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_formatted_description_imps, cls,
                                     sel_registerName("formattedDescription:"),
                                     @selector(pm_ps_mtl_formattedDescription:));
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
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_are_barycentric_imps, cls,
                                     sel_registerName("areBarycentricCoordsSupported"),
                                     @selector(pm_ps_mtl_areBarycentricCoordsSupported));
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
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_lib_data_imps, cls,
                                     sel_registerName("newLibraryWithData:error:"),
                                     @selector(pm_ps_mtl_newLibraryWithData:error:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_lib_url_imps, cls,
                                     sel_registerName("newLibraryWithURL:error:"),
                                     @selector(pm_ps_mtl_newLibraryWithURL:error:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_lib_file_imps, cls,
                                     sel_registerName("newLibraryWithFile:error:"),
                                     @selector(pm_ps_mtl_newLibraryWithFile:error:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_comp_pipe_fn_imps, cls,
                                     sel_registerName("newComputePipelineStateWithFunction:error:"),
                                     @selector(pm_ps_mtl_newComputePipelineStateWithFunction:error:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_comp_pipe_fn_async_imps, cls,
                                     sel_registerName("newComputePipelineStateWithFunction:completionHandler:"),
                                     @selector(pm_ps_mtl_newComputePipelineStateWithFunction:completionHandler:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_comp_pipe_fn_opts_imps, cls,
                                     sel_registerName("newComputePipelineStateWithFunction:options:reflection:error:"),
                                     @selector(pm_ps_mtl_newComputePipelineStateWithFunction:options:reflection:error:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_comp_pipe_fn_opts_async_imps, cls,
                                     sel_registerName("newComputePipelineStateWithFunction:options:completionHandler:"),
                                     @selector(pm_ps_mtl_newComputePipelineStateWithFunction:options:completionHandler:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_comp_pipe_desc_imps, cls,
                                     sel_registerName("newComputePipelineStateWithDescriptor:error:"),
                                     @selector(pm_ps_mtl_newComputePipelineStateWithDescriptor:error:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_comp_pipe_desc_async_imps, cls,
                                     sel_registerName("newComputePipelineStateWithDescriptor:completionHandler:"),
                                     @selector(pm_ps_mtl_newComputePipelineStateWithDescriptor:completionHandler:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_comp_pipe_desc_opts_imps, cls,
                                     sel_registerName("newComputePipelineStateWithDescriptor:options:reflection:error:"),
                                     @selector(pm_ps_mtl_newComputePipelineStateWithDescriptor:options:reflection:error:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_comp_pipe_desc_opts_async_imps, cls,
                                     sel_registerName("newComputePipelineStateWithDescriptor:options:completionHandler:"),
                                     @selector(pm_ps_mtl_newComputePipelineStateWithDescriptor:options:completionHandler:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_rend_pipe_desc_imps, cls,
                                     sel_registerName("newRenderPipelineStateWithDescriptor:error:"),
                                     @selector(pm_ps_mtl_newRenderPipelineStateWithDescriptor:error:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_rend_pipe_desc_async_imps, cls,
                                     sel_registerName("newRenderPipelineStateWithDescriptor:completionHandler:"),
                                     @selector(pm_ps_mtl_newRenderPipelineStateWithDescriptor:completionHandler:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_rend_pipe_desc_opts_imps, cls,
                                     sel_registerName("newRenderPipelineStateWithDescriptor:options:reflection:error:"),
                                     @selector(pm_ps_mtl_newRenderPipelineStateWithDescriptor:options:reflection:error:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_new_rend_pipe_desc_opts_async_imps, cls,
                                     sel_registerName("newRenderPipelineStateWithDescriptor:options:completionHandler:"),
                                     @selector(pm_ps_mtl_newRenderPipelineStateWithDescriptor:options:completionHandler:));
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

static void ps_swizzle_mtl_library_class(Class cls) {
    if (pt_mtl_class_already_swizzled(cls)) {
        return;
    }
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_lib_new_fn_imps, cls,
                                     sel_registerName("newFunctionWithName:"),
                                     @selector(pm_ps_mtl_lib_newFunctionWithName:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_lib_new_fn_const_imps, cls,
                                     sel_registerName("newFunctionWithName:constantValues:error:"),
                                     @selector(pm_ps_mtl_lib_newFunctionWithName:constantValues:error:));
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_lib_new_fn_const_async_imps, cls,
                                     sel_registerName("newFunctionWithName:constantValues:completionHandler:"),
                                     @selector(pm_ps_mtl_lib_newFunctionWithName:constantValues:completionHandler:));
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
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_cenc_set_pipe_imps, cls,
                                     sel_registerName("setComputePipelineState:"),
                                     @selector(pm_ps_mtl_cenc_setComputePipelineState:));
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
    ps_swizzle_class_sel_storing_imp(&s_mtl_swizzle_lock, &s_mtl_orig_renc_set_pipe_imps, cls,
                                     sel_registerName("setRenderPipelineState:"),
                                     @selector(pm_ps_mtl_renc_setRenderPipelineState:));
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

static void ps_register_hidden_mtl_helper_classes(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pt_register_hidden_class("PSMTLLibrary32FInfo");
        pt_register_hidden_class("PSMTLFunction32FInfo");
        pt_register_hidden_class("PSMTLPipeline32FInfo");
        pt_register_hidden_class("PSMTLSamplerBindEntry");
        pt_register_hidden_class("PSMTLEncoderBindingState");
    });
}

__attribute__((visibility("hidden"))) void ps_install_metal_hooks_if_loaded(void) {
    ps_register_hidden_mtl_helper_classes();
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
                        (void)pt_mtl_host_max_apple_family(dev);
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
                            (void)pt_mtl_host_max_apple_family(dev);
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

static const char kPSDLAutoClampedKey = 0;
static const char kPSDLExplicitlySetKey = 0;
static const char kPSMTKAutoClampedKey = 0;
static const char kPSMTKExplicitlySetKey = 0;

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
    float clippedMin = (!isfinite(range.minimum) || range.minimum <= 0.0f)
        ? 0.0f
        : fminf(range.minimum, clippedMax);
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
    if (!ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        objc_setAssociatedObject(self, &kPSDLExplicitlySetKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &kPSDLAutoClampedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (capHz > 0) {
            CAFrameRateRange clamped = ps_clamped_frame_rate_range(range, capHz);
            PT_DEBUG_TRACE("graphics",
                           "CADisplayLink setPreferredFrameRateRange cap=%ld (%.1f,%.1f,%.1f)->(%.1f,%.1f,%.1f)",
                           (long)capHz,
                           range.minimum, range.maximum, range.preferred,
                           clamped.minimum, clamped.maximum, clamped.preferred);
            range = clamped;
        }
    }
    if (s_orig_dl_setPreferredFrameRateRange != NULL) {
        s_orig_dl_setPreferredFrameRateRange(self, _cmd, range);
    }
}

static CAFrameRateRange ps_hook_dl_preferredFrameRateRange(id self, SEL _cmd) {
    if (ps_effective_target_frame_rate_hz() > 0 &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        objc_getAssociatedObject(self, &kPSDLAutoClampedKey) != nil &&
        objc_getAssociatedObject(self, &kPSDLExplicitlySetKey) == nil) {
        return (CAFrameRateRange){ 0.0f, 0.0f, 0.0f };
    }
    if (s_orig_dl_preferredFrameRateRange != NULL) {
        return s_orig_dl_preferredFrameRateRange(self, _cmd);
    }
    return (CAFrameRateRange){ 0.0f, 0.0f, 0.0f };
}

static void ps_hook_dl_setPreferredFramesPerSecond(id self, SEL _cmd, NSInteger fps) {
    NSInteger capHz = ps_effective_target_frame_rate_hz();
    if (!ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        objc_setAssociatedObject(self, &kPSDLExplicitlySetKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &kPSDLAutoClampedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (capHz > 0) {
            NSInteger clamped = ps_clamped_legacy_fps(fps, capHz);
            PT_DEBUG_TRACE("graphics",
                           "CADisplayLink setPreferredFramesPerSecond cap=%ld %ld->%ld",
                           (long)capHz, (long)fps, (long)clamped);
            fps = clamped;
        }
    }
    if (s_orig_dl_setPreferredFramesPerSecond != NULL) {
        s_orig_dl_setPreferredFramesPerSecond(self, _cmd, fps);
    }
}

static NSInteger ps_hook_dl_preferredFramesPerSecond(id self, SEL _cmd) {
    if (ps_effective_target_frame_rate_hz() > 0 &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        objc_getAssociatedObject(self, &kPSDLAutoClampedKey) != nil &&
        objc_getAssociatedObject(self, &kPSDLExplicitlySetKey) == nil) {
        return 0;
    }
    if (s_orig_dl_preferredFramesPerSecond != NULL) {
        return s_orig_dl_preferredFramesPerSecond(self, _cmd);
    }
    return 0;
}

static void ps_hook_dl_addToRunLoopForMode(id self, SEL _cmd, NSRunLoop *runloop, NSRunLoopMode mode) {
    NSInteger capHz = ps_effective_target_frame_rate_hz();
    if (capHz > 0 && !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        BOOL compat13 = pt_is_bypass_enabled() && pt_is_compat13_7_active();
        NSInteger curLegacyFPS = 0;
        if (s_orig_dl_preferredFramesPerSecond != NULL) {
            curLegacyFPS = s_orig_dl_preferredFramesPerSecond(self, sel_registerName("preferredFramesPerSecond"));
        }
        if (compat13) {
            // Never invoke iOS 15+ setPreferredFrameRateRange: under compat13_7
            NSInteger clampedFPS = ps_clamped_legacy_fps(curLegacyFPS, capHz);
            if (clampedFPS != curLegacyFPS && s_orig_dl_setPreferredFramesPerSecond != NULL) {
                if (objc_getAssociatedObject(self, &kPSDLExplicitlySetKey) == nil) {
                    objc_setAssociatedObject(self, &kPSDLAutoClampedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                s_orig_dl_setPreferredFramesPerSecond(self, sel_registerName("setPreferredFramesPerSecond:"), clampedFPS);
            }
        } else {
            CAFrameRateRange curRange = { 0.0f, 0.0f, 0.0f };
            if (s_orig_dl_preferredFrameRateRange != NULL) {
                curRange = s_orig_dl_preferredFrameRateRange(self, sel_registerName("preferredFrameRateRange"));
            }
            BOOL keepLowerLegacyFPS = (curRange.maximum <= 0.0f && curLegacyFPS > 0 && curLegacyFPS < capHz);
            if (!keepLowerLegacyFPS && s_orig_dl_setPreferredFrameRateRange != NULL) {
                if (objc_getAssociatedObject(self, &kPSDLExplicitlySetKey) == nil &&
                    curRange.maximum <= 0.0f) {
                    objc_setAssociatedObject(self, &kPSDLAutoClampedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                CAFrameRateRange clamped = ps_clamped_frame_rate_range(curRange, capHz);
                PT_DEBUG_TRACE("graphics",
                               "CADisplayLink addToRunLoop cap=%ld -> (%.1f,%.1f,%.1f)",
                               (long)capHz, clamped.minimum, clamped.maximum, clamped.preferred);
                s_orig_dl_setPreferredFrameRateRange(self, sel_registerName("setPreferredFrameRateRange:"), clamped);
            }
        }
    }
    if (s_orig_dl_addToRunLoopForMode != NULL) {
        s_orig_dl_addToRunLoopForMode(self, _cmd, runloop, mode);
    }
}

static void ps_hook_mtkview_setPreferredFramesPerSecond(id self, SEL _cmd, NSInteger fps) {
    NSInteger capHz = ps_effective_target_frame_rate_hz();
    if (!ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        objc_setAssociatedObject(self, &kPSMTKExplicitlySetKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &kPSMTKAutoClampedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (capHz > 0) {
            NSInteger clamped = ps_clamped_legacy_fps(fps, capHz);
            PT_DEBUG_TRACE("graphics",
                           "MTKView setPreferredFramesPerSecond cap=%ld %ld->%ld",
                           (long)capHz, (long)fps, (long)clamped);
            fps = clamped;
        }
    }
    if (s_orig_mtkview_setPreferredFramesPerSecond != NULL) {
        s_orig_mtkview_setPreferredFramesPerSecond(self, _cmd, fps);
    }
}

static NSInteger ps_hook_mtkview_preferredFramesPerSecond(id self, SEL _cmd) {
    if (ps_effective_target_frame_rate_hz() > 0 &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        objc_getAssociatedObject(self, &kPSMTKAutoClampedKey) != nil &&
        objc_getAssociatedObject(self, &kPSMTKExplicitlySetKey) == nil) {
        return 60;
    }
    if (s_orig_mtkview_preferredFramesPerSecond != NULL) {
        return s_orig_mtkview_preferredFramesPerSecond(self, _cmd);
    }
    return 60;
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
            if (objc_getAssociatedObject(self, &kPSMTKExplicitlySetKey) == nil) {
                objc_setAssociatedObject(self, &kPSMTKAutoClampedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
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
        s_orig_dl_preferredFrameRateRange = (CAFrameRateRange (*)(id, SEL))ps_replace_method_with_c_hook(
            dlCls, sel_registerName("preferredFrameRateRange"), (IMP)ps_hook_dl_preferredFrameRateRange);
        s_orig_dl_preferredFramesPerSecond = (NSInteger (*)(id, SEL))ps_replace_method_with_c_hook(
            dlCls, sel_registerName("preferredFramesPerSecond"), (IMP)ps_hook_dl_preferredFramesPerSecond);
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
        s_orig_mtkview_preferredFramesPerSecond = (NSInteger (*)(id, SEL))ps_replace_method_with_c_hook(
            mtkCls, sel_registerName("preferredFramesPerSecond"), (IMP)ps_hook_mtkview_preferredFramesPerSecond);
        s_orig_mtkview_setPreferredFramesPerSecond = (void (*)(id, SEL, NSInteger))ps_replace_method_with_c_hook(
            mtkCls, sel_registerName("setPreferredFramesPerSecond:"), (IMP)ps_hook_mtkview_setPreferredFramesPerSecond);
        s_orig_mtkview_didMoveToWindow = (void (*)(id, SEL))ps_replace_method_with_c_hook(
            mtkCls, sel_registerName("didMoveToWindow"), (IMP)ps_hook_mtkview_didMoveToWindow);
    });
}

void pt_install_frame_rate_hooks_if_loaded(void) {
    ps_register_hidden_mtl_helper_classes();
    ps_install_display_link_hooks_if_loaded();
    ps_install_mtkview_frame_rate_hooks_if_loaded();
}

void pt_install_graphics_hooks_if_loaded(void) {
    ps_register_hidden_mtl_helper_classes();
    ps_install_metal_hooks_if_loaded();
    pt_install_frame_rate_hooks_if_loaded();

}
