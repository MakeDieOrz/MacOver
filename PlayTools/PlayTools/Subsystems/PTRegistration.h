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

void pt_register_hidden_module(const char *image_name_fragment);
void pt_register_hidden_class(const char *objc_class_name);
void pt_register_hidden_image_header(const void *mach_header);

bool pt_is_registered_hidden_module(const char *name);
bool pt_is_registered_hidden_class(const char *name);
bool pt_is_registered_hidden_image_header(const void *mach_header);

uint64_t pt_hidden_registry_generation(void);
size_t pt_registered_hidden_module_count(void);
size_t pt_registered_hidden_class_count(void);
size_t pt_registered_hidden_image_header_count(void);

void pt_reset_hidden_registry_for_testing(void);

#ifdef __cplusplus
}
#endif

#endif /* PTRegistration_h */
