//
//  PTSvcInternal.h
//  PlayTools
//
//  Hidden declarations for PTSvcInterceptor and callers.
//

#ifndef PTSvcInternal_h
#define PTSvcInternal_h

#import "PTCommon.h"

#ifdef __cplusplus
extern "C" {
#endif

__attribute__((visibility("hidden"))) void pt_svc_interceptor_init_early(void);
__attribute__((visibility("hidden"))) void pt_svc_restore_patched_bytes_in_buffer(uintptr_t read_start, uint8_t *dst, size_t copied);
__attribute__((visibility("hidden"))) BOOL pt_svc_get_redaction_info(mach_port_t *out_svc_port, mach_port_t *out_saved_port, exception_mask_t *out_saved_mask, exception_behavior_t *out_saved_beh, thread_state_flavor_t *out_saved_flavor);

#ifdef __cplusplus
}
#endif

#endif /* PTSvcInternal_h */
