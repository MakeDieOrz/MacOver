//
//  PTDyldInternal.h
//  PlayTools
//
//  Hidden declarations shared across PTDyldVirtualizer, PTDyldLoaders,
//  PTObjCRuntimeVirtualizer, and other subsystems.
//

#ifndef PTDyldInternal_h
#define PTDyldInternal_h

#import "PTCommon.h"
#import "PTDetectionRules.h"
@import MachO;

#ifdef __cplusplus
extern "C" {
#endif

// Public/subsystem dyld & runtime cloaking exports
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_macos_only_dlsym_symbol(const char *symbol);
__attribute__((visibility("hidden"))) void *pt_route_dlsym_symbol_for_app(const char *symbol);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_objc_class(const char *name);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_objc_protocol_name(const char *name);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_objc_selector_name(const char *selName);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_dyld_image_name(const char *name);
__attribute__((visibility("hidden"))) BOOL pt_is_post13_7_hidden_framework_path(const char *path);
__attribute__((visibility("hidden"))) BOOL pt_should_hide_dyld_image(const char *name);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_dyld_image_header(const struct mach_header *mh);
__attribute__((visibility("hidden"))) const char *pt_fallback_system_image_path(void);
__attribute__((visibility("hidden"))) const struct mach_header *pt_maybe_shadow_mach_header(const struct mach_header *real_mh);
__attribute__((visibility("hidden"))) const struct mach_header *pt_uncloak_shadow_mach_header(const struct mach_header *mh);
__attribute__((visibility("hidden"))) BOOL pt_build_sanitized_mach_header_copy(const struct mach_header_64 *src_mh, uint8_t *dst_buf, size_t dst_cap, size_t *out_sanitized_len);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_vm_region_range(uintptr_t addr, uintptr_t size);
__attribute__((visibility("hidden"))) void pt_register_swizzled_imp(const void *hook_imp, const void *orig_imp);
__attribute__((visibility("hidden"))) void pt_register_hidden_swizzle_selector(SEL sel);
__attribute__((visibility("hidden"))) BOOL pt_is_address_in_playtools(const void *addr);
__attribute__((visibility("hidden"))) void pt_init_nonlazy_got_cloaking(void);
__attribute__((visibility("hidden"))) void pt_dyld_sanitize_got_ptrs_in_vm_read_buffer(uintptr_t read_start, uint8_t *dst, size_t copied);
__attribute__((visibility("hidden"))) void ps_install_nsobject_reflection_hooks(void);

// Internal helpers shared across PTDyldVirtualizer / PTDyldLoaders / PTObjCRuntimeVirtualizer
extern __attribute__((visibility("hidden"))) _Atomic uint64_t s_dyld_generation;

__attribute__((visibility("hidden"))) uint32_t pt_dyld_virtual_count(void);
__attribute__((visibility("hidden"))) BOOL pt_dyld_virtual_to_real_index(uint32_t virtual_idx, uint32_t *out_real_idx);
__attribute__((visibility("hidden"))) uint32_t pt_fallback_system_image_index(void);
__attribute__((visibility("hidden"))) const char *pt_dyld_lookup_image_name_for_mh(const struct mach_header *mh);
__attribute__((visibility("hidden"))) void pt_ensure_dyld_master_callbacks(void);
__attribute__((visibility("hidden"))) const void *pt_strip_code_ptr(const void *p);
__attribute__((visibility("hidden"))) const void *pt_resolve_interposed_target(const void *addr);
__attribute__((visibility("hidden"))) const void *pt_lookup_swizzled_raw_orig_imp(const void *addr);
__attribute__((visibility("hidden"))) BOOL pt_is_registered_hidden_swizzle_selector(SEL sel);
__attribute__((visibility("hidden"))) BOOL pt_is_swizzled_orig_imp(const void *addr);
__attribute__((visibility("hidden"))) BOOL pt_is_app_embedded_bundle_path(const char *path);
__attribute__((visibility("hidden"))) BOOL pt_is_macos_only_framework_path(const char *name);

__attribute__((visibility("hidden"))) BOOL pt_is_hidden_post13_7_class(Class cls);
__attribute__((visibility("hidden"))) BOOL pt_is_class_in_hidden_image(Class cls);
__attribute__((visibility("hidden"))) BOOL pt_should_hide_resolved_objc_class(const char *name, Class cls);
__attribute__((visibility("hidden"))) const char *pt_dyld_sanitize_or_hide_image_path(const char *path);

#ifdef __cplusplus
}
#endif

#endif /* PTDyldInternal_h */
