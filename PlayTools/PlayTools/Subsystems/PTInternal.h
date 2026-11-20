//
//  PTInternal.h
//  PlayTools
//
//  Shared internal definitions, kernel ABI structs, and hidden cross-subsystem
//  prototypes extracted from PlayLoader.m.
//

#ifndef PTInternal_h
#define PTInternal_h

//
//  PlayLoader.m
//  PlayTools
//

#include <Foundation/Foundation.h>
#include <copyfile.h>
#include <crt_externs.h>
#include <dirent.h>
#include <dns_sd.h>
#include <errno.h>
#include <execinfo.h>
#include <fcntl.h>
#include <fts.h>
#include <ftw.h>
#include <glob.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/machine.h>
#include <mach/task_info.h>
#include <mach-o/dyld_images.h>
#include <netdb.h>
#include <os/lock.h>
#include <pthread.h>
#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif
#include <pwd.h>
#include <removefile.h>
#include <spawn.h>
#include <sqlite3.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/clonefile.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/stdio.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/xattr.h>
#include <unistd.h>
#include <utime.h>
#include <stdint.h>
#import "../PTCallerAddressMath.h"
#import "PTDebugTrace.h"
#import "PTRegistration.h"
#if __has_include(<libproc.h>)
#include <libproc.h>
#else
#ifndef PROC_ALL_PIDS
#define PROC_ALL_PIDS 1
#endif
#ifndef PROC_PIDLISTFDS
#define PROC_PIDLISTFDS 1
#endif
#ifndef PROC_PIDTASKALLINFO
#define PROC_PIDTASKALLINFO 2
#endif
#ifndef PROC_PIDFDVNODEPATHINFO
#define PROC_PIDFDVNODEPATHINFO 2
#endif
#ifndef PROC_PIDTBSDINFO
#define PROC_PIDTBSDINFO 3
#endif
#ifndef PROC_PIDREGIONPATHINFO
#define PROC_PIDREGIONPATHINFO 8
#endif
#ifndef PROC_PIDVNODEPATHINFO
#define PROC_PIDVNODEPATHINFO 9
#endif
#ifndef PROC_PIDPATHINFO
#define PROC_PIDPATHINFO 11
#endif
#ifndef PROC_PIDT_SHORTBSDINFO
#define PROC_PIDT_SHORTBSDINFO 13
#endif
#ifndef PROC_FLAG_TRACED
#define PROC_FLAG_TRACED 2
#endif
#ifndef PROX_FDTYPE_VNODE
#define PROX_FDTYPE_VNODE 1
#endif
#ifndef MAXCOMLEN
#define MAXCOMLEN 16
#endif

struct proc_fdinfo {
    int32_t  proc_fd;
    uint32_t proc_fdtype;
};

struct proc_fileinfo {
    uint32_t fi_openflags;
    uint32_t fi_status;
    off_t    fi_offset;
    int32_t  fi_type;
    uint32_t fi_guardflags;
};

struct vinfo_stat {
    uint32_t vst_dev;
    uint16_t vst_mode;
    uint16_t vst_nlink;
    uint64_t vst_ino;
    uid_t    vst_uid;
    gid_t    vst_gid;
    int64_t  vst_atime;
    int64_t  vst_atimensec;
    int64_t  vst_mtime;
    int64_t  vst_mtimensec;
    int64_t  vst_ctime;
    int64_t  vst_ctimensec;
    int64_t  vst_birthtime;
    int64_t  vst_birthtimensec;
    off_t    vst_size;
    int64_t  vst_blocks;
    int32_t  vst_blksize;
    uint32_t vst_flags;
    uint32_t vst_gen;
    uint32_t vst_rdev;
    int64_t  vst_qspare[2];
};

struct vnode_info {
    struct vinfo_stat vi_stat;
    int               vi_type;
    int               vi_pad;
    fsid_t            vi_fsid;
};

struct vnode_info_path {
    struct vnode_info vip_vi;
    char              vip_path[MAXPATHLEN];
};

struct vnode_fdinfowithpath {
    struct proc_fileinfo   pfi;
    struct vnode_info_path pvip;
};

struct proc_vnodepathinfo {
    struct vnode_info_path pvi_cdir;
    struct vnode_info_path pvi_rdir;
};

struct proc_bsdinfo {
    uint32_t pbi_flags;
    uint32_t pbi_status;
    uint32_t pbi_xstatus;
    uint32_t pbi_pid;
    uint32_t pbi_ppid;
    uid_t    pbi_uid;
    gid_t    pbi_gid;
    uid_t    pbi_ruid;
    gid_t    pbi_rgid;
    uid_t    pbi_svuid;
    gid_t    pbi_svgid;
    uint32_t rfu_1;
    char     pbi_comm[MAXCOMLEN];
    char     pbi_name[2 * MAXCOMLEN];
    uint32_t pbi_nfiles;
    uint32_t pbi_pgid;
    uint32_t pbi_pjobc;
    uint32_t e_tdev;
    uint32_t e_tpgid;
    int32_t  pbi_nice;
    uint64_t pbi_start_tvsec;
    uint64_t pbi_start_tvusec;
};

struct proc_bsdshortinfo {
    uint32_t pbsi_pid;
    uint32_t pbsi_ppid;
    uint32_t pbsi_pgid;
    uint32_t pbsi_status;
    char     pbsi_comm[MAXCOMLEN];
    uint32_t pbsi_flags;
    uid_t    pbsi_uid;
    gid_t    pbsi_gid;
    uid_t    pbsi_ruid;
    gid_t    pbsi_rgid;
    uid_t    pbsi_svuid;
    gid_t    pbsi_svgid;
    uint32_t pbsi_rfu;
};

struct proc_taskinfo {
    uint64_t pti_virtual_size;
    uint64_t pti_resident_size;
    uint64_t pti_total_user;
    uint64_t pti_total_system;
    uint64_t pti_threads_user;
    uint64_t pti_threads_system;
    int32_t  pti_policy;
    int32_t  pti_faults;
    int32_t  pti_pageins;
    int32_t  pti_cow_faults;
    int32_t  pti_messages_sent;
    int32_t  pti_messages_received;
    int32_t  pti_syscalls_mach;
    int32_t  pti_syscalls_unix;
    int32_t  pti_csw;
    int32_t  pti_threadnum;
    int32_t  pti_numrunning;
    int32_t  pti_priority;
};

struct proc_taskallinfo {
    struct proc_bsdinfo  pbsd;
    struct proc_taskinfo ptinfo;
};

struct proc_regioninfo {
    uint32_t pri_protection;
    uint32_t pri_max_protection;
    uint32_t pri_inheritance;
    uint32_t pri_flags;
    uint64_t pri_offset;
    uint32_t pri_behavior;
    uint32_t pri_user_wired_count;
    uint32_t pri_user_tag;
    uint32_t pri_pages_resident;
    uint32_t pri_pages_shared_now_private;
    uint32_t pri_pages_swapped_out;
    uint32_t pri_pages_dirtied;
    uint32_t pri_ref_count;
    uint32_t pri_shadow_depth;
    uint32_t pri_share_mode;
    uint32_t pri_private_pages_resident;
    uint32_t pri_shared_pages_resident;
    uint32_t pri_obj_id;
    uint32_t pri_depth;
    uint64_t pri_address;
    uint64_t pri_size;
};

struct proc_regionwithpathinfo {
    struct proc_regioninfo prp_prinfo;
    struct vnode_info_path prp_vip;
};

#ifndef PROC_PIDTHREADINFO
#define PROC_PIDTHREADINFO 5
#endif
#ifndef PROC_PIDTHREADPATHINFO
#define PROC_PIDTHREADPATHINFO 10
#endif
#ifndef PROC_PIDTHREADID64INFO
#define PROC_PIDTHREADID64INFO 15
#endif
#ifndef PROC_PIDREGIONPATHINFO2
#define PROC_PIDREGIONPATHINFO2 22
#endif
#ifndef PROC_PIDREGIONPATHINFO3
#define PROC_PIDREGIONPATHINFO3 23
#endif
#ifndef MAXTHREADNAMESIZE
#define MAXTHREADNAMESIZE 64
#endif

struct proc_threadinfo {
    uint64_t pth_user_time;
    uint64_t pth_system_time;
    int32_t  pth_cpu_usage;
    int32_t  pth_policy;
    int32_t  pth_run_state;
    int32_t  pth_flags;
    int32_t  pth_sleep_time;
    int32_t  pth_curpri;
    int32_t  pth_priority;
    int32_t  pth_maxpriority;
    char     pth_name[MAXTHREADNAMESIZE];
};

struct proc_threadwithpathinfo {
    struct proc_threadinfo pt;
    struct vnode_info_path pvip;
};

extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
extern int proc_pidfdinfo(int pid, int fd, int flavor, void *buffer, int buffersize);
extern int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
extern int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
extern int proc_listallpids(void *buffer, int buffersize);
extern int proc_name(int pid, void *buffer, uint32_t buffersize);
extern int proc_regionfilename(int pid, uint64_t address, void *buffer, uint32_t buffersize);
#endif

#ifndef PROC_PIDTHREADINFO
#define PROC_PIDTHREADINFO 5
#endif
#ifndef PROC_PIDLISTTHREADS
#define PROC_PIDLISTTHREADS 6
#endif
#ifndef PROC_PIDTHREADPATHINFO
#define PROC_PIDTHREADPATHINFO 10
#endif
#ifndef PROC_PIDTHREADID64INFO
#define PROC_PIDTHREADID64INFO 15
#endif
#ifndef PROC_PIDREGIONPATHINFO2
#define PROC_PIDREGIONPATHINFO2 22
#endif
#ifndef PROC_PIDREGIONPATHINFO3
#define PROC_PIDREGIONPATHINFO3 23
#endif

_Static_assert(sizeof(struct proc_fdinfo) == 8, "proc_fdinfo ABI size mismatch");
_Static_assert(sizeof(struct vnode_fdinfowithpath) == 1200, "vnode_fdinfowithpath ABI size mismatch");
_Static_assert(offsetof(struct vnode_fdinfowithpath, pvip.vip_path) == 176, "vnode_fdinfowithpath vip_path offset mismatch");
_Static_assert(sizeof(struct proc_vnodepathinfo) == 2352, "proc_vnodepathinfo ABI size mismatch");
_Static_assert(offsetof(struct proc_vnodepathinfo, pvi_cdir.vip_path) == 152, "proc_vnodepathinfo pvi_cdir offset mismatch");
_Static_assert(offsetof(struct proc_vnodepathinfo, pvi_rdir.vip_path) == 1328, "proc_vnodepathinfo pvi_rdir offset mismatch");
_Static_assert(sizeof(struct proc_bsdinfo) == 136, "proc_bsdinfo ABI size mismatch");
_Static_assert(offsetof(struct proc_bsdinfo, pbi_flags) == 0, "proc_bsdinfo pbi_flags offset mismatch");
_Static_assert(offsetof(struct proc_bsdinfo, pbi_pid) == 12, "proc_bsdinfo pbi_pid offset mismatch");
_Static_assert(offsetof(struct proc_bsdinfo, pbi_ppid) == 16, "proc_bsdinfo pbi_ppid offset mismatch");
_Static_assert(sizeof(struct proc_bsdshortinfo) == 64, "proc_bsdshortinfo ABI size mismatch");
_Static_assert(offsetof(struct proc_bsdshortinfo, pbsi_pid) == 0, "proc_bsdshortinfo pbsi_pid offset mismatch");
_Static_assert(offsetof(struct proc_bsdshortinfo, pbsi_ppid) == 4, "proc_bsdshortinfo pbsi_ppid offset mismatch");
_Static_assert(offsetof(struct proc_bsdshortinfo, pbsi_flags) == 32, "proc_bsdshortinfo pbsi_flags offset mismatch");
_Static_assert(sizeof(struct proc_taskinfo) == 96, "proc_taskinfo ABI size mismatch");
_Static_assert(sizeof(struct proc_taskallinfo) == 232, "proc_taskallinfo ABI size mismatch");
_Static_assert(offsetof(struct proc_taskallinfo, pbsd) == 0, "proc_taskallinfo pbsd offset mismatch");
_Static_assert(sizeof(struct proc_regioninfo) == 96, "proc_regioninfo ABI size mismatch");
_Static_assert(sizeof(struct proc_regionwithpathinfo) == 1272, "proc_regionwithpathinfo ABI size mismatch");
_Static_assert(offsetof(struct proc_regionwithpathinfo, prp_vip.vip_path) == 248, "proc_regionwithpathinfo vip_path offset mismatch");
_Static_assert(sizeof(struct proc_threadinfo) == 112, "proc_threadinfo ABI size mismatch");
_Static_assert(offsetof(struct proc_threadinfo, pth_name) == 48, "proc_threadinfo pth_name offset mismatch");
_Static_assert(sizeof(struct proc_threadwithpathinfo) == 1288, "proc_threadwithpathinfo ABI size mismatch");
_Static_assert(offsetof(struct proc_threadwithpathinfo, pvip.vip_path) == 264, "proc_threadwithpathinfo vip_path offset mismatch");
#import <objc/runtime.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>

#if !TARGET_OS_MACCATALYST && !TARGET_OS_OSX
typedef struct __SecCode *SecCodeRef;
typedef struct __SecCode const *SecStaticCodeRef;
typedef struct __SecRequirement *SecRequirementRef;
typedef struct __SecTask *SecTaskRef;
typedef uint32_t SecCSFlags;

extern OSStatus SecCodeCopySelf(SecCSFlags flags, SecCodeRef *self);
extern OSStatus SecCodeCopyStaticCode(SecCodeRef code, SecCSFlags flags, SecStaticCodeRef *staticCode);
extern OSStatus SecCodeCopyPath(SecStaticCodeRef staticCode, SecCSFlags flags, CFURLRef *path);
extern OSStatus SecCodeCopySigningInformation(SecStaticCodeRef code, SecCSFlags flags, CFDictionaryRef *information);
extern OSStatus SecCodeCheckValidity(SecCodeRef code, SecCSFlags flags, SecRequirementRef requirement);
extern OSStatus SecCodeCheckValidityWithErrors(SecCodeRef code, SecCSFlags flags, SecRequirementRef requirement, CFErrorRef *errors);
extern OSStatus SecStaticCodeCreateWithPath(CFURLRef path, SecCSFlags flags, SecStaticCodeRef *staticCode);
extern OSStatus SecStaticCodeCreateWithPathAndAttributes(CFURLRef path, SecCSFlags flags, CFDictionaryRef attributes, SecStaticCodeRef *staticCode);
extern OSStatus SecStaticCodeCheckValidity(SecStaticCodeRef staticCode, SecCSFlags flags, SecRequirementRef requirement);
extern OSStatus SecStaticCodeCheckValidityWithErrors(SecStaticCodeRef staticCode, SecCSFlags flags, SecRequirementRef requirement, CFErrorRef *errors);
extern CFStringRef SecTaskCopySigningIdentifier(SecTaskRef task, CFErrorRef *error);
extern uint32_t SecTaskGetCodeSignStatus(SecTaskRef task);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);
extern CFDictionaryRef SecTaskCopyValuesForEntitlements(SecTaskRef task, CFArrayRef entitlements, CFErrorRef *error);
#endif

extern int sandbox_check(pid_t pid, const char *operation, int type, ...);
extern int sandbox_check_by_audit_token(audit_token_t au, const char *operation, int type, ...);
extern const char *dyld_image_path_containing_address(const void *addr);
extern const struct mach_header *dyld_image_header_containing_address(const void *addr);

#import "../PlayLoader.h"
#import <PlayTools/PlayTools-Swift.h>
#import <sys/utsname.h>
#import "../Controls/PTFakeTouch/NSObject+Swizzle.h"
#import <dlfcn.h>

__attribute__((visibility("hidden"))) const char *pt_sanitize_image_path_for_app(const char *raw_path);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_env_key(const char *name);

@import MachO;
@import CFNetwork;
@import Network;
@import SystemConfiguration;


#ifdef __OBJC__
#import <PlayTools/PlayTools-Swift.h>
#endif

#ifndef PLATFORM_IOS
#define PLATFORM_IOS 2
#endif
#ifndef PLATFORM_MACCATALYST
#define PLATFORM_MACCATALYST 6
#endif
#ifndef P_TRACED
#define P_TRACED 0x00000800
#endif

#define PT_STR_ENTRY(lit) { (lit), sizeof(lit) - 1 }
#define PT_HAS_PREFIX_LIT(s, lit) (strncmp((s), (lit), sizeof(lit) - 1) == 0)
#define DEVICE_MODEL pt_get_device_model()
#define OEM_ID pt_get_oem_id()

typedef struct {
    const char *model;
    const char *oem_id;
    const char *cpu_brand;
    const char *gpu_name;
    uint32_t cores;
    uint32_t p_cores;
    uint32_t e_cores;
    uint64_t ram_bytes;
    uint32_t cpufamily;
    const char *kernel_tag;
    const char *soc_code;
    const char *marketing_name;
    const char *model_number;
    const char *regulatory_model;
    BOOL is_ipad;
    uint32_t native_width;
    uint32_t native_height;
    double native_scale;
} pt_device_profile_t;

typedef enum {
    PT_FS_PATH_NORMAL = 0,
    PT_FS_PATH_HIDDEN = 1,
    PT_FS_PATH_VIRTUAL_ANCESTOR = 2
} pt_fs_path_disposition_t;

extern int pt_orig_open_nocancel(const char *, int, ...) __asm("_open$NOCANCEL");

#ifdef __cplusplus
extern "C" {
#endif

// Shared state across PlayLoader coordinator & subsystems (visibility=hidden)
extern __attribute__((visibility("hidden"))) volatile _Atomic bool s_libsystem_ready;
extern __attribute__((visibility("hidden"))) _Atomic BOOL s_pt_loaded;
extern __attribute__((visibility("hidden"))) _Atomic BOOL s_bypass_enabled;
extern __attribute__((visibility("hidden"))) _Atomic BOOL s_pt_bypass_inited;
extern __attribute__((visibility("hidden"))) _Atomic int s_playchain_cached;
extern __attribute__((visibility("hidden"))) _Atomic int s_playchain_debug_cached;
extern __attribute__((visibility("hidden"))) _Atomic int s_block_sleep_spamming_cached;
extern __attribute__((visibility("hidden"))) pthread_once_t s_pt_bypass_early_once;
extern __attribute__((visibility("hidden"))) pthread_once_t s_pt_device_info_once;
extern __attribute__((visibility("hidden"))) _Thread_local int s_tls_bypass_init_depth;
extern __attribute__((visibility("hidden"))) _Thread_local BOOL s_tls_initializing_device_info;
extern __attribute__((visibility("hidden"))) _Atomic uint8_t ue_status;
extern __attribute__((visibility("hidden"))) dispatch_semaphore_t thread_sleep_sem;

extern __attribute__((visibility("hidden"))) char s_real_app_bundle_dir[PATH_MAX];
extern __attribute__((visibility("hidden"))) size_t s_real_app_bundle_len;
extern __attribute__((visibility("hidden"))) char s_real_data_container_dir[PATH_MAX];
extern __attribute__((visibility("hidden"))) size_t s_real_data_container_len;
extern __attribute__((visibility("hidden"))) char s_virtual_private_bundle_dir[PATH_MAX];
extern __attribute__((visibility("hidden"))) char s_virtual_private_data_dir[PATH_MAX];
extern __attribute__((visibility("hidden"))) size_t s_virtual_private_data_len;

// SystemSpoofer exports
__attribute__((visibility("hidden"))) void pt_init_early_bypass(void);
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
__attribute__((visibility("hidden"))) const char *pt_get_reported_ios_version_override(const char **out_build);
__attribute__((visibility("hidden"))) void pt_disable_reported_ios_override_for_safe_mode(void);
__attribute__((visibility("hidden"))) uint32_t pt_get_spoofed_cpu_cores(void);
__attribute__((visibility("hidden"))) uint64_t pt_get_spoofed_physical_memory(void);
__attribute__((visibility("hidden"))) const char *pt_get_spoofed_gpu_name_cstr(void);
__attribute__((visibility("hidden"))) BOOL pt_get_spoofed_device_is_ipad(void);
__attribute__((visibility("hidden"))) void pt_get_spoofed_screen_native_bounds(double *out_portrait_width, double *out_portrait_height, double *out_native_scale);
__attribute__((visibility("hidden"))) double pt_get_device_native_scale(void);
__attribute__((visibility("hidden"))) uint32_t pt_get_device_native_width(void);
__attribute__((visibility("hidden"))) uint32_t pt_get_device_native_height(void);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_env_key(const char *name);
__attribute__((visibility("hidden"))) CFURLRef pt_resolve_cfbundle_input_url(CFURLRef url, const void *caller, BOOL *out_blocked) CF_RETURNS_RETAINED;
__attribute__((visibility("hidden"))) CFURLRef pt_sanitize_cfbundle_returned_url(CFURLRef CF_CONSUMED url, const void *caller) CF_RETURNS_RETAINED;
__attribute__((visibility("hidden"))) BOOL pt_info_dict_needs_sanitize(NSDictionary *dict);
__attribute__((visibility("hidden"))) NSDictionary *pt_build_sanitized_info_dict(NSDictionary *dict);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_thread_name(const char *name);
__attribute__((visibility("hidden"))) CFTypeRef pt_MGCopyAnswer(CFStringRef question, CFDictionaryRef options);
__attribute__((visibility("hidden"))) CFDictionaryRef pt_MGCopyMultipleAnswers(CFArrayRef questions, CFDictionaryRef options);
__attribute__((visibility("hidden"))) bool pt_MGGetBoolAnswer(CFStringRef question);
__attribute__((visibility("hidden"))) int32_t pt_MGGetSInt32Answer(CFStringRef question, int32_t defaultVal);
__attribute__((visibility("hidden"))) CFStringRef pt_MGGetStringAnswer(CFStringRef question);
__attribute__((visibility("hidden"))) int32_t pt_MGGetProductType(void);

// FSVirtualizer exports
__attribute__((visibility("hidden"))) BOOL pt_is_system_or_playtools_caller(const void *ret_addr);
__attribute__((visibility("hidden"))) BOOL pt_is_effective_system_or_playtools_caller(const void *ret_addr);
__attribute__((visibility("hidden"))) BOOL pt_needs_lexical_norm(const char *p);
__attribute__((visibility("hidden"))) const char *pt_normalize_lexical_path(const char *src, char *dst, size_t dst_size);
__attribute__((visibility("hidden"))) const char *pt_match_prefix_modulo_private(const char *path, const char *base, size_t base_len);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_path(const char *path, const void *caller);
__attribute__((visibility("hidden"))) void pt_ensure_bundle_path_map(void);
__attribute__((visibility("hidden"))) BOOL pt_ensure_data_container_map(void);
__attribute__((visibility("hidden"))) const char *pt_register_and_virtualize_group_container(const char *real_group_path, char *buf, size_t bufsize, BOOL use_private_prefix);
__attribute__((visibility("hidden"))) const char *pt_get_virtual_home_cstr(void);
__attribute__((visibility("hidden"))) const char *pt_get_virtual_tmpdir_cstr(void);
__attribute__((visibility("hidden"))) BOOL pt_is_virtual_container_ancestor_dir(const char *path);
__attribute__((visibility("hidden"))) const char *pt_virtualize_path_for_app(const char *path, char *buf, size_t bufsize, BOOL use_private_prefix);
__attribute__((visibility("hidden"))) const char *pt_sanitize_image_path_for_app(const char *raw_path);
__attribute__((visibility("hidden"))) const char *pt_sanitize_image_path_for_cstr(const char *raw_path);
__attribute__((visibility("hidden"))) BOOL pt_is_virtual_container_path(const char *path);
__attribute__((visibility("hidden"))) BOOL pt_is_reverse_mapped_iossupport(const char *orig_path, const char *resolved_path);
__attribute__((visibility("hidden"))) const char *pt_resolve_virtual_path(const char *path, char *buf, size_t bufsize);
__attribute__((visibility("hidden"))) const char *pt_resolve_virtual_bundle_path(const char *path, char *buf, size_t bufsize);
__attribute__((visibility("hidden"))) BOOL pt_fd_is_sensitive(int fd, const void *caller);
__attribute__((visibility("hidden"))) pt_fs_path_disposition_t pt_prepare_fs_path_cached_caller(const char *raw_path, const void *caller, char *vbuf, size_t vbuf_size, const char **out_path, int *inout_is_sys_caller);
__attribute__((visibility("hidden"))) BOOL pt_prepare_fs_path_for_modify(int dirfd, const char *raw_path, const void *caller, char *vbuf, size_t vbuf_size, const char **out_path, int ancestor_errno);
__attribute__((visibility("hidden"))) void pt_disable_app_backups_for_safe_mode(void);
__attribute__((visibility("hidden"))) BOOL pt_has_backup_mobileprovision(void);
__attribute__((visibility("hidden"))) const char *pt_copy_virtual_mobileprovision_path(char *buf, size_t bufsize);
__attribute__((visibility("hidden"))) const char *pt_lookup_app_backup_redirect_for_caller(const char *raw_path, const void *caller, char *vbuf, size_t vbuf_size, int *inout_is_sys_caller);

// DyldVirtualizer exports
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_objc_class(const char *name);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_objc_protocol_name(const char *name);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_objc_selector_name(const char *selName);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_dyld_image_name(const char *name);
__attribute__((visibility("hidden"))) BOOL pt_should_hide_dyld_image(const char *name);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_dyld_image_header(const struct mach_header *mh);
__attribute__((visibility("hidden"))) const char *pt_fallback_system_image_path(void);
__attribute__((visibility("hidden"))) void pt_register_swizzled_imp(const void *hook_imp, const void *orig_imp);
__attribute__((visibility("hidden"))) BOOL pt_is_address_in_playtools(const void *addr);

// NetworkVirtualizer exports
__attribute__((visibility("hidden"))) int ps_should_block_host_cstr(const char *hostname);

#ifdef __cplusplus
}
#endif

#endif /* PTInternal_h */
