//
//  PTSystemSpooferInternal.h
//  PlayTools
//
//  Hidden declarations shared across PTSystemSpoofer modules and callers.
//

#ifndef PTSystemSpooferInternal_h
#define PTSystemSpooferInternal_h

#import "PTCommon.h"
#include <sys/event.h>
#include <time.h>
#include <uuid/uuid.h>

typedef struct {
    uint64_t ident;
    int16_t  filter;
    uint16_t flags;
    uint32_t qos;
    uint64_t udata;
    uint32_t fflags;
    uint32_t xflags;
    int64_t  data;
    uint64_t ext[4];
} pt_kevent_qos_s;

_Static_assert(sizeof(pt_kevent_qos_s) == 72, "pt_kevent_qos_s ABI size mismatch");
_Static_assert(offsetof(pt_kevent_qos_s, udata) == 16, "pt_kevent_qos_s udata offset mismatch");
_Static_assert(offsetof(pt_kevent_qos_s, data) == 32, "pt_kevent_qos_s data offset mismatch");

#ifdef __cplusplus
extern "C" {
#endif

// Core device, version & early plist exports
__attribute__((visibility("hidden"))) void pt_init_early_bypass(void);
__attribute__((visibility("hidden"))) const char *pt_raw_getenv(const char *name);
__attribute__((visibility("hidden"))) void pt_ensure_early_device_info_safe(void);
__attribute__((visibility("hidden"))) void pt_init_device_info(void);
__attribute__((visibility("hidden"))) BOOL pt_is_bypass_enabled(void);
__attribute__((visibility("hidden"))) const char *pt_get_host_user_root_cstr(void);
__attribute__((visibility("hidden"))) const char *pt_get_main_executable_path(void);
__attribute__((visibility("hidden"))) const struct mach_header *pt_get_main_executable_header(void);
__attribute__((visibility("hidden"))) BOOL pt_read_main_bundle_id_early(char *out_bid, size_t out_size);
__attribute__((visibility("hidden"))) uint8_t *pt_read_fd_plist_bytes(int fd, size_t *out_len, size_t *out_map_size);
__attribute__((visibility("hidden"))) BOOL pt_read_plist_top_string_from_fd(int fd, const char *key, char *out_val, size_t out_size);
__attribute__((visibility("hidden"))) int pt_open_early_settings_plist_fd(void);
__attribute__((visibility("hidden"))) const char *pt_get_device_model_cstr(void);
__attribute__((visibility("hidden"))) const char *pt_get_oem_id_cstr(void);
__attribute__((visibility("hidden"))) const char *pt_get_spoofed_ios_version_cstr(void);
__attribute__((visibility("hidden"))) const pt_device_profile_t *pt_get_active_device_profile(void);
__attribute__((visibility("hidden"))) const char *pt_get_reported_ios_version_override(const char **out_build);
__attribute__((visibility("hidden"))) BOOL pt_is_compat13_7_active(void);
__attribute__((visibility("hidden"))) BOOL pt_is_availability_app_caller(const void *caller);
__attribute__((visibility("hidden"))) bool pt_availability_version_check(uint32_t count, const pt_dyld_build_version_t versions[]);
__attribute__((visibility("hidden"))) int32_t pt_isPlatformVersionAtLeast(uint32_t platform, uint32_t major, uint32_t minor, uint32_t subminor);
__attribute__((visibility("hidden"))) void pt_disable_reported_ios_override_for_safe_mode(void);
__attribute__((visibility("hidden"))) float pt_get_shared_spoofed_battery_level(void);
__attribute__((visibility("hidden"))) uint32_t pt_get_spoofed_cpu_cores(void);
__attribute__((visibility("hidden"))) uint64_t pt_get_spoofed_physical_memory(void);
__attribute__((visibility("hidden"))) const char *pt_get_spoofed_gpu_name_cstr(void);
__attribute__((visibility("hidden"))) int32_t pt_get_spoofed_max_apple_gpu_family(void);
__attribute__((visibility("hidden"))) const char *pt_get_spoofed_gpu_arch_cstr(void);
__attribute__((visibility("hidden"))) BOOL pt_get_spoofed_device_is_ipad(void);
__attribute__((visibility("hidden"))) void pt_get_spoofed_screen_native_bounds(double *out_portrait_width, double *out_portrait_height, double *out_native_scale);
__attribute__((visibility("hidden"))) double pt_get_device_native_scale(void);
__attribute__((visibility("hidden"))) uint32_t pt_get_device_native_width(void);
__attribute__((visibility("hidden"))) uint32_t pt_get_device_native_height(void);
__attribute__((visibility("hidden"))) uint32_t pt_get_device_max_fps(void);

// Internal helpers shared across PTSystemSpoofer translation units
extern __attribute__((visibility("hidden"))) char s_real_kern_release[64];
extern __attribute__((visibility("hidden"))) char s_spoofed_osversion[64];
extern __attribute__((visibility("hidden"))) char s_spoofed_ios_version[32];
__attribute__((visibility("hidden"))) int pt_write_sysctl_string(const char *value, void *oldp, size_t *oldlenp);
__attribute__((visibility("hidden"))) int pt_write_sysctl_int(int value, void *oldp, size_t *oldlenp);
__attribute__((visibility("hidden"))) int pt_write_sysctl_uint64(void *oldp, size_t *oldlenp, void *newp, uint64_t val);
__attribute__((visibility("hidden"))) int pt_write_sysctl_uint64_array(void *oldp, size_t *oldlenp, void *newp, const uint64_t *vals, size_t count);
__attribute__((visibility("hidden"))) CFDataRef pt_create_compatible_cfdata(CFAllocatorRef allocator);
__attribute__((visibility("hidden"))) void pt_ensure_host_kernel_info(void);
__attribute__((visibility("hidden"))) void pt_fallback_ios_version_for_kern_major(int kern_major, char *out_buf, size_t out_size);
__attribute__((visibility("hidden"))) BOOL pt_sanitize_ios_build_version_with_kern_major(const char *build_cstr, const char *ios_ver_cstr, int kern_major, char *out_buf, size_t out_size);
__attribute__((visibility("hidden"))) const char *pt_get_effective_kern_release(void);
__attribute__((visibility("hidden"))) void pt_format_kernel_version(const pt_device_profile_t *profile, char *buf, size_t buf_size);

// Sysctl & SystemVersion / Info.plist
__attribute__((visibility("hidden"))) int pt_sysctl_with_caller(int *name, u_int types, void *buf, size_t *size, void *arg0, size_t arg1, const void *caller);
__attribute__((visibility("hidden"))) int pt_sysctlbyname_with_caller(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen, const void *caller);
__attribute__((visibility("hidden"))) BOOL pt_is_info_plist_dict(NSDictionary *dict);
__attribute__((visibility("hidden"))) BOOL pt_info_dict_needs_sanitize(NSDictionary *dict);
__attribute__((visibility("hidden"))) NSMutableDictionary *pt_build_sanitized_mutable_info_dict(NSDictionary *dict);
__attribute__((visibility("hidden"))) NSDictionary *pt_build_sanitized_info_dict(NSDictionary *dict);
__attribute__((visibility("hidden"))) BOOL pt_is_system_version_plist_dict(NSDictionary *dict);
__attribute__((visibility("hidden"))) BOOL pt_sanitize_ios_build_version_cstr(const char *build_cstr, const char *ios_ver_cstr, char *out_buf, size_t out_size);
__attribute__((visibility("hidden"))) void pt_sanitize_system_version_dict(NSMutableDictionary *dict);

// IOKit & MobileGestalt
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_io_class_or_name(const char *cls_name, const char *entry_name);
__attribute__((visibility("hidden"))) void pt_sanitize_io_hardware_name(char *buf, size_t cap);
__attribute__((visibility("hidden"))) CFDataRef pt_sanitize_io_nul_delimited_bytes(const uint8_t *src, size_t src_len, CFAllocatorRef allocator) CF_RETURNS_RETAINED;
__attribute__((visibility("hidden"))) CFTypeRef pt_MGCopyAnswer(CFStringRef question, CFDictionaryRef options);
__attribute__((visibility("hidden"))) CFTypeRef pt_MGCopyAnswerWithError(CFStringRef question, CFDictionaryRef options, int *outError);
__attribute__((visibility("hidden"))) CFDictionaryRef pt_MGCopyMultipleAnswers(CFArrayRef questions, CFDictionaryRef options);
__attribute__((visibility("hidden"))) bool pt_MGGetBoolAnswer(CFStringRef question);
__attribute__((visibility("hidden"))) int32_t pt_MGGetSInt32Answer(CFStringRef question, int32_t defaultVal);
__attribute__((visibility("hidden"))) CFStringRef pt_MGGetStringAnswer(CFStringRef question);
__attribute__((visibility("hidden"))) int32_t pt_MGGetProductType(void);

// Env, launch args, CFBundle & CFPreferences
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_env_key(const char *name);
__attribute__((visibility("hidden"))) int pt_macos_launch_arg_skip_count(const char *arg, const char *next_arg);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_env_value(const char *val, BOOL has_virtual_container);
__attribute__((visibility("hidden"))) pt_env_entry_action_t pt_resolve_env_entry(
    const char *key,
    const char *raw_val,
    BOOL has_raw_entry,
    BOOL bypass_enabled,
    const char *vh,
    const char *vt,
    const char **out_val);
__attribute__((visibility("hidden"))) char ***pt_get_app_shadow_environ_ptr(void);
__attribute__((visibility("hidden"))) CFURLRef pt_resolve_cfbundle_input_url(CFURLRef url, const void *caller, BOOL *out_blocked) CF_RETURNS_RETAINED;
__attribute__((visibility("hidden"))) CFURLRef pt_sanitize_cfbundle_returned_url(CFURLRef CF_CONSUMED url, const void *caller) CF_RETURNS_RETAINED;
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_bundle_id_cstr(const char *bid);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_macos_pref_key(const char *key);

// Identity, proc/kevent & Mach VM / Syscall / MIG
__attribute__((visibility("hidden"))) BOOL pt_is_desktop_supplemental_gid(gid_t g);
__attribute__((visibility("hidden"))) gid_t pt_map_spoofed_gid(gid_t raw_gid);
__attribute__((visibility("hidden"))) gid_t pt_getgid_with_caller(const void *caller);
__attribute__((visibility("hidden"))) gid_t pt_getegid_with_caller(const void *caller);
__attribute__((visibility("hidden"))) int pt_getgroups_with_caller(int gidsetsize, gid_t grouplist[], const void *caller);
__attribute__((visibility("hidden"))) int pt_gethostuuid_with_caller(uuid_t id, const struct timespec *wait, const void *caller);
__attribute__((visibility("hidden"))) int pt_getauid_with_caller(void *auid, const void *caller);
__attribute__((visibility("hidden"))) int pt_getaudit_addr_with_caller(void *auinfo, int length, const void *caller);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_thread_name(const char *name);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_mach_thread(thread_act_t thr);
__attribute__((visibility("hidden"))) int pt_kevent_with_caller(int kq, const struct kevent *changelist, int nchanges, struct kevent *eventlist, int nevents, const struct timespec *timeout, const void *caller);
__attribute__((visibility("hidden"))) int pt_kevent64_with_caller(int kq, const struct kevent64_s *changelist, int nchanges, struct kevent64_s *eventlist, int nevents, unsigned int flags, const struct timespec *timeout, const void *caller);
__attribute__((visibility("hidden"))) int pt_kevent_qos_with_caller(int kq, const pt_kevent_qos_s *changelist, int nchanges, pt_kevent_qos_s *eventlist, int nevents, void *data_out, size_t *data_available, unsigned int flags, const void *caller);

__attribute__((visibility("hidden"))) void pt_dyld_set_force_task_dyld_sanitize(BOOL active);
__attribute__((visibility("hidden"))) BOOL pt_dyld_is_force_task_dyld_sanitize(void);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_unregistered_macho_region(uintptr_t addr, uintptr_t size, vm_prot_t prot);
__attribute__((visibility("hidden"))) void pt_sanitize_host_basic_info_buf(host_basic_info_data_t *info, size_t out_bytes);
__attribute__((visibility("hidden"))) void pt_sanitize_host_vm_info_buf(vm_statistics_data_t *v, size_t out_bytes);
__attribute__((visibility("hidden"))) void pt_sanitize_host_vm_info64_buf(vm_statistics64_data_t *v, size_t out_bytes, BOOL clear_swaps);
__attribute__((visibility("hidden"))) void pt_sanitize_task_vm_info_buf(task_vm_info_data_t *vm, size_t out_bytes);
__attribute__((visibility("hidden"))) void pt_sanitize_task_audit_token_buf(audit_token_t *tok, size_t out_bytes);
__attribute__((visibility("hidden"))) void pt_sanitize_task_security_token_buf(security_token_t *tok, size_t out_bytes);
__attribute__((visibility("hidden"))) void pt_sanitize_task_dyld_info_buf(task_dyld_info_data_t *dyld_info, size_t out_bytes);
__attribute__((visibility("hidden"))) void pt_sanitize_vm_read_buffer(uintptr_t read_start, uint8_t *dst, size_t copied);

extern intptr_t pt_orig_syscall(int, ...) __asm("_syscall");
extern int pt_orig_kernel_sysctlbyname(const char *name,
                                       size_t namelen,
                                       void *oldp,
                                       size_t *oldlenp,
                                       void *newp,
                                       size_t newlen) __asm("___sysctlbyname");
__attribute__((visibility("hidden"))) intptr_t pt_syscall_dispatch_with_caller(int number, const uintptr_t args[8], const void *caller, BOOL *out_handled);
__attribute__((visibility("hidden"))) void pt_sanitize_legacy_user64_stat_in_place(void *ub, const void *caller);
__attribute__((visibility("hidden"))) void pt_copy_stat64_to_legacy_user64_stat(const struct stat *src, void *dst_ub);
__attribute__((visibility("hidden"))) bool pt_mig_prepare_trap_request(const void *req_buf, mach_msg_bits_t bits, mach_msg_size_t send_size, mach_port_t remote_port, mach_port_t local_port, int req_id, bool receiving, int32_t *out_flavor, bool *out_target_is_self);
__attribute__((visibility("hidden"))) void pt_mig_finish_trap_reply(void *rcv_buf, size_t rcv_cap, mach_port_t rcv_name, bool sending, bool receiving, bool had_req, int req_id, int32_t req_flavor, bool target_is_self, mach_port_t reply_port, kern_return_t kr);

#ifdef __cplusplus
}
#endif

#endif /* PTSystemSpooferInternal_h */
