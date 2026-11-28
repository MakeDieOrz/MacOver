//
//  PTSvcInternal.h
//  PlayTools
//
//  Hidden declarations for PTSvcInterceptor and callers.
//

#ifndef PTSvcInternal_h
#define PTSvcInternal_h

#import "PTCommon.h"
#include <mach_debug/ipc_info.h>

#ifdef __cplusplus
extern "C" {
#endif

__attribute__((visibility("hidden"))) void pt_svc_interceptor_init_early(void);
__attribute__((visibility("hidden"))) BOOL pt_svc_range_overlaps_patched_site(uintptr_t addr, size_t len);
__attribute__((visibility("hidden"))) void pt_svc_restore_patched_bytes_in_buffer(uintptr_t read_start, uint8_t *dst, size_t copied);
__attribute__((visibility("hidden"))) BOOL pt_svc_get_redaction_info(mach_port_t *out_svc_port, mach_port_t *out_saved_port, exception_mask_t *out_saved_mask, exception_behavior_t *out_saved_beh, thread_state_flavor_t *out_saved_flavor);
__attribute__((visibility("hidden"))) BOOL pt_svc_record_bp_handler_from_mig(BOOL is_thread, mach_port_t target_port, exception_mask_t orig_mask, mach_port_t new_port, exception_behavior_t behavior, thread_state_flavor_t flavor);
__attribute__((visibility("hidden"))) void pt_svc_redact_exc_ports_info_arrays(BOOL is_thread, mach_port_t target_port, exception_mask_t *masks, mach_msg_type_number_t *masksCnt, ipc_info_port_t *handlers_info, exception_behavior_t *behaviors, thread_state_flavor_t *flavors);

#ifdef __cplusplus
}
#endif

#endif /* PTSvcInternal_h */
