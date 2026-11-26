//
//  PTDetectionRules.h
//  PlayTools
//
//  Pure-C anti-detection rule matchers, path normalizers, and xattr/network filters.
//

#ifndef PTDetectionRules_h
#define PTDetectionRules_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

__attribute__((visibility("hidden")))
const char *pt_normalize_lexical_path(const char *src, char *dst, size_t dst_size);
__attribute__((visibility("hidden"))) const char *pt_match_prefix_modulo_private(const char *path, const char *base,
                                                                                 size_t base_len);
__attribute__((visibility("hidden"))) bool pt_path_has_component(const char *path, const char *comp);

__attribute__((visibility("hidden"))) bool pt_is_macos_only_framework_path_cstr(const char *name);
__attribute__((visibility("hidden"))) bool pt_is_hidden_macos_only_dlsym_symbol_cstr(const char *symbol);

__attribute__((visibility("hidden"))) bool pt_is_desktop_supplemental_gid_c(gid_t g);
__attribute__((visibility("hidden"))) bool pt_is_hidden_thread_name_cstr(const char *name);

__attribute__((visibility("hidden"))) bool pt_is_hidden_env_key_cstr(const char *name);
__attribute__((visibility("hidden"))) bool pt_is_hidden_bundle_id_rule_cstr(const char *bid, bool compat13_7);
__attribute__((visibility("hidden"))) bool pt_is_hidden_macos_pref_key_cstr(const char *key);
__attribute__((visibility("hidden"))) bool pt_is_hidden_macos_mach_service_cstr(const char *name);

__attribute__((visibility("hidden"))) bool pt_is_hidden_xattr_name_cstr(const char *name);
__attribute__((visibility("hidden"))) ssize_t pt_filter_xattr_list_buffer(char *buf, ssize_t raw_len);

__attribute__((visibility("hidden"))) bool pt_is_hidden_network_ifname_prefix_cstr(const char *name);
__attribute__((visibility("hidden"))) bool pt_is_secondary_en_ifname_cstr(const char *name);

__attribute__((visibility("hidden"))) bool pt_is_hidden_desktop_font_name_cstr(const char *name);
__attribute__((visibility("hidden"))) bool pt_is_post13_7_sf_symbol_name_cstr(const char *s);
__attribute__((visibility("hidden"))) bool
pt_is_hidden_swift_mangled_type_name_cstr(const char *typeNameStart, size_t typeNameLength, bool compat13_7);
__attribute__((visibility("hidden"))) bool pt_is_hidden_swift_qualified_token_cstr(const char *tok, size_t len,
                                                                                   bool compat13_7);

#ifdef __cplusplus
}
#endif

#endif /* PTDetectionRules_h */
