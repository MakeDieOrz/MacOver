//
//  PTRegistration.h
//  PlayTools
//
//  Dynamic anti-detection registration API decoupling core runtime hooks
//  from external/user plugin metadata.
//

#ifndef PTRegistration_h
#define PTRegistration_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef PT_INTERNAL_VISIBILITY
#ifdef DEBUG
#define PT_INTERNAL_VISIBILITY
#else
#define PT_INTERNAL_VISIBILITY __attribute__((visibility("hidden")))
#endif
#endif

// Public plugin / CoverUseBridge ABI (exported in Release).
void pt_register_hidden_module(const char *image_name_fragment);
void pt_register_hidden_class(const char *objc_class_name);
void pt_register_hidden_image_header(const void *mach_header);

PT_INTERNAL_VISIBILITY bool pt_is_registered_hidden_module(const char *name);
PT_INTERNAL_VISIBILITY bool pt_is_registered_hidden_class(const char *name);
PT_INTERNAL_VISIBILITY bool pt_is_registered_hidden_image_header(const void *mach_header);

PT_INTERNAL_VISIBILITY uint64_t pt_hidden_registry_generation(void);
PT_INTERNAL_VISIBILITY size_t pt_registered_hidden_module_count(void);
PT_INTERNAL_VISIBILITY size_t pt_registered_hidden_class_count(void);
PT_INTERNAL_VISIBILITY size_t pt_registered_hidden_image_header_count(void);

void pt_register_hidden_fd(int fd);
void pt_unregister_hidden_fd(int fd);
PT_INTERNAL_VISIBILITY bool pt_is_hidden_fd(int fd);

void pt_register_hidden_loopback_port(uint16_t port);
void pt_unregister_hidden_loopback_port(uint16_t port);
PT_INTERNAL_VISIBILITY bool pt_is_hidden_loopback_port(uint16_t port);

PT_INTERNAL_VISIBILITY void pt_store_automation_bootstrap(uint16_t port, const char *token, const char *bundle_id,
                                                          const char *bridge_dir);
PT_INTERNAL_VISIBILITY void pt_clear_automation_bootstrap(void);
PT_INTERNAL_VISIBILITY bool pt_has_automation_bootstrap(void);
PT_INTERNAL_VISIBILITY bool pt_copy_automation_bootstrap_bridge_dir(char *out_dir, size_t dir_cap);
bool pt_consume_automation_bootstrap(uint16_t *out_port, char *out_token, size_t token_cap, char *out_bundle_id,
                                     size_t bundle_cap);

#ifdef DEBUG
void pt_reset_hidden_registry_for_testing(void);
#endif

#ifdef __cplusplus
}
#endif

#endif /* PTRegistration_h */
