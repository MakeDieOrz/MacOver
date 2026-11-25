//
//  PTCommon.h
//  PlayTools
//
//  Shared core types, macros, inline helpers, and coordinator globals.
//

#ifndef PTCommon_h
#define PTCommon_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <arpa/inet.h>
#include <crt_externs.h>
#include <dlfcn.h>
#include <errno.h>
#include <execinfo.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/machine.h>
#include <mach/task_info.h>
#include <mach-o/dyld_images.h>
#include <os/lock.h>
#include <pthread.h>
#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/utsname.h>
#include <unistd.h>

#import "../PTCallerAddressMath.h"
#import "PTDebugTrace.h"
#import "PTInterposeRegistry.h"
#import "PTRegistration.h"
#import "../PlayLoader.h"
#import "../Controls/PTFakeTouch/NSObject+Swizzle.h"
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
#define DEVICE_MODEL pt_get_device_model_cstr()
#define OEM_ID pt_get_oem_id_cstr()

// Shared user-pointer sanity check across PlayTools subsystems.
static inline BOOL pt_is_valid_user_pointer(const void *ptr) {
    return pt_is_valid_user_addr((uintptr_t)ptr) ? YES : NO;
}

typedef enum {
    PT_ENV_ENTRY_KEEP = 0,
    PT_ENV_ENTRY_HIDE = 1,
    PT_ENV_ENTRY_REWRITE = 2
} pt_env_entry_action_t;

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
    uint32_t max_fps;
    int32_t max_apple_gpu_family;
    const char *gpu_arch;
    uint32_t gpu_cores;
    const char *gpu_gen;
} pt_device_profile_t;

typedef enum {
    PT_FS_PATH_NORMAL = 0,
    PT_FS_PATH_HIDDEN = 1,
    PT_FS_PATH_VIRTUAL_ANCESTOR = 2
} pt_fs_path_disposition_t;

typedef struct {
    uint32_t platform;
    uint32_t version;
} pt_dyld_build_version_t;

extern int sandbox_check(pid_t pid, const char *operation, int type, ...);
extern int sandbox_check_by_audit_token(audit_token_t au, const char *operation, int type, ...);
extern const char *dyld_image_path_containing_address(const void *addr);
extern const struct mach_header *dyld_image_header_containing_address(const void *addr);
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

#ifdef __cplusplus
}
#endif

#endif /* PTCommon_h */
