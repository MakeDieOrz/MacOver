//
//  PTSystemSpooferSysctl.m
//  PlayTools
//

#import "PTSystemSpooferInternal.h"
#import "PTFSInternal.h"
#import "PTDyldInternal.h"
#import "PTNetworkInternal.h"
#include <mach/machine.h>

// Update output of sysctl for key values hw.machine, hw.product, hw.model and hw.target to match iOS output
// This spoofs the device type to apps allowing us to report as any iOS device
typedef struct {
    const char *name;
    int mib[6];
    u_int len;
} pt_sysctl_mib_entry_t;

static pt_sysctl_mib_entry_t s_sysctl_mibs[] = {
    { "hw.targettype", {0}, 0 },
    { "hw.jetsam_properties_product_type", {0}, 0 },
    { "machdep.cpu.brand_string", {0}, 0 },
    { "machdep.cpu.core_count", {0}, 0 },
    { "machdep.cpu.cores_per_package", {0}, 0 },
    { "machdep.cpu.thread_count", {0}, 0 },
    { "machdep.cpu.logical_per_package", {0}, 0 },
    { "machdep.cpu.vendor", {0}, 0 },
    { "hw.activecpu", {0}, 0 },
    { "hw.physicalcpu", {0}, 0 },
    { "hw.physicalcpu_max", {0}, 0 },
    { "hw.logicalcpu", {0}, 0 },
    { "hw.logicalcpu_max", {0}, 0 },
    { "hw.memsize_usable", {0}, 0 },
    { "hw.cpufamily", {0}, 0 },
    { "hw.cputype", {0}, 0 },
    { "hw.cpusubtype", {0}, 0 },
    { "hw.cpusubfamily", {0}, 0 },
    { "hw.nperflevels", {0}, 0 },
    { "hw.perflevel0.physicalcpu", {0}, 0 },
    { "hw.perflevel0.physicalcpu_max", {0}, 0 },
    { "hw.perflevel0.logicalcpu", {0}, 0 },
    { "hw.perflevel0.logicalcpu_max", {0}, 0 },
    { "hw.perflevel0.cpusperl2", {0}, 0 },
    { "hw.perflevel0.l1icachesize", {0}, 0 },
    { "hw.perflevel0.l1dcachesize", {0}, 0 },
    { "hw.perflevel0.l2cachesize", {0}, 0 },
    { "hw.perflevel0.name", {0}, 0 },
    { "hw.perflevel1.physicalcpu", {0}, 0 },
    { "hw.perflevel1.physicalcpu_max", {0}, 0 },
    { "hw.perflevel1.logicalcpu", {0}, 0 },
    { "hw.perflevel1.logicalcpu_max", {0}, 0 },
    { "hw.perflevel1.cpusperl2", {0}, 0 },
    { "hw.perflevel1.l1icachesize", {0}, 0 },
    { "hw.perflevel1.l1dcachesize", {0}, 0 },
    { "hw.perflevel1.l2cachesize", {0}, 0 },
    { "hw.perflevel1.name", {0}, 0 },
    { "hw.l1icachesize", {0}, 0 },
    { "hw.l1dcachesize", {0}, 0 },
    { "hw.l2cachesize", {0}, 0 },
    { "hw.cacheconfig", {0}, 0 },
    { "hw.cachesize", {0}, 0 },
    { "hw.packages", {0}, 0 },
    { "hw.use_kernelmanagerd", {0}, 0 },
    { "hw.features.allows_security_research", {0}, 0 },
    { "hw.ephemeral_storage", {0}, 0 },
    { "hw.use_recovery_securityd", {0}, 0 },
    { "vm.swapusage", {0}, 0 },
    { "vm.swapfileprefix", {0}, 0 },
    { "vm.swap_enabled", {0}, 0 },
    { "vm.darkwake_mode", {0}, 0 },
    { "vm.compressor_mode", {0}, 0 },
    { "vm.compressor.mode", {0}, 0 },
    { "vm.compressor.config.swap_present", {0}, 0 },
    { "vm.compressor.config.swap_active", {0}, 0 },
    { "kern.iossupportversion", {0}, 0 },
    { "kern.osproductversion", {0}, 0 },
    { "kern.coredump", {0}, 0 },
    { "kern.corefile", {0}, 0 },
    { "kern.bootargs", {0}, 0 },
    { "kern.wakereason", {0}, 0 },
    { "kern.hibernatefile", {0}, 0 },
    { "kern.hibernatewakenotification", {0}, 0 },
    { "kern.hibernatemode", {0}, 0 },
    { "kern.hibernatestatistics", {0}, 0 },
    { "kern.hibernategraphicsready", {0}, 0 },
    { "kern.hibernatelockscreenready", {0}, 0 },
    { "kern.hibernatehidready", {0}, 0 },
    { "kern.hibernatecount", {0}, 0 },
    { "kern.hibernatepreview", {0}, 0 },
    { "kern.osproductversioncompat", {0}, 0 },
    { "kern.osvariant_status", {0}, 0 },
    { "kern.osbuildconfig", {0}, 0 },
    { "kern.hv_support", {0}, 0 },
    { "kern.hv_vmm_present", {0}, 0 },
    { "kern.singleuser", {0}, 0 },
    { "kern.safeboot", {0}, 0 },
    { "kern.willshutdown", {0}, 0 },
    { "kern.waketime", {0}, 0 },
    { "kern.sleeptime", {0}, 0 },
    { "kern.secure_kernel", {0}, 0 },
    { "security.mac.amfi.developer_mode_status", {0}, 0 },
    { "sysctl.proc_translated", {0}, 0 },
    { "sysctl.proc_native", {0}, 0 },
    { "sysctl.proc_cputype", {0}, 0 },
};
static pthread_once_t s_pt_sysctl_mibs_once = PTHREAD_ONCE_INIT;
static uint32_t s_sysctl_root_mask = 0;

static void pt_init_sysctl_mibs(void) {
    size_t count = sizeof(s_sysctl_mibs) / sizeof(s_sysctl_mibs[0]);
    uint32_t mask = 0;
    for (size_t i = 0; i < count; i++) {
        size_t n = 6;
        if (sysctlnametomib(s_sysctl_mibs[i].name, s_sysctl_mibs[i].mib, &n) == 0 && n > 0 && n <= 6) {
            s_sysctl_mibs[i].len = (u_int)n;
            int r = s_sysctl_mibs[i].mib[0];
            mask |= (r >= 0 && r < 31) ? (1U << (unsigned)r) : (1U << 31);
        } else {
            s_sysctl_mibs[i].len = 0;
        }
    }
    s_sysctl_root_mask = mask;
}

static const char *pt_lookup_mib_name(const int *name, u_int types) {
    pthread_once(&s_pt_sysctl_mibs_once, pt_init_sysctl_mibs);
    int r = name[0];
    uint32_t bit = (r >= 0 && r < 31) ? (1U << (unsigned)r) : (1U << 31);
    if ((s_sysctl_root_mask & bit) == 0) {
        return NULL;
    }
    size_t count = sizeof(s_sysctl_mibs) / sizeof(s_sysctl_mibs[0]);
    for (size_t i = 0; i < count; i++) {
        const pt_sysctl_mib_entry_t *e = &s_sysctl_mibs[i];
        if (e->len == 0 || e->len != types) {
            continue;
        }
        BOOL match = YES;
        for (u_int j = 0; j < types; j++) {
            if (name[j] != e->mib[j]) {
                match = NO;
                break;
            }
        }
        if (match) {
            return e->name;
        }
    }
    return NULL;
}

static inline BOOL pt_sysctl_resolve_is_sys(const void *caller, int *inout_is_sys_caller) {
    if (*inout_is_sys_caller < 0) {
        *inout_is_sys_caller = pt_is_effective_system_or_playtools_caller(caller) ? 1 : 0;
    }
    return (*inout_is_sys_caller != 0);
}

static uint64_t pt_get_spoofed_l1d_cache_size(const pt_device_profile_t *profile) {
    uint32_t gpu_family = (profile != NULL) ? (uint32_t)profile->max_apple_gpu_family : 1008U;
    return pt_spoofed_l1d_cache_size_u64(gpu_family, false);
}

static uint64_t pt_get_spoofed_l1i_cache_size(const pt_device_profile_t *profile, BOOL is_e_core) {
    uint32_t gpu_family = (profile != NULL) ? (uint32_t)profile->max_apple_gpu_family : 1008U;
    return pt_spoofed_l1i_cache_size_u64(gpu_family, is_e_core ? true : false);
}

static uint64_t pt_get_spoofed_l1d_cache_size_for_level(const pt_device_profile_t *profile, BOOL is_e_core) {
    uint32_t gpu_family = (profile != NULL) ? (uint32_t)profile->max_apple_gpu_family : 1008U;
    return pt_spoofed_l1d_cache_size_u64(gpu_family, is_e_core ? true : false);
}

static void pt_get_spoofed_l2_cache_sizes(const pt_device_profile_t *profile,
                                          uint64_t *out_p_l2,
                                          uint64_t *out_e_l2) {
    uint32_t gpu_family = (profile != NULL) ? (uint32_t)profile->max_apple_gpu_family : 1008U;
    const char *model = (profile != NULL) ? profile->model : NULL;
    pt_spoofed_l2_cache_sizes_u64(gpu_family, model, out_p_l2, out_e_l2);
}

static BOOL pt_is_hidden_sysctl_name(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return NO;
    }
    uint32_t e_cores = (strncmp(name, "hw.perflevel1.", 14) == 0)
        ? (uint32_t)pt_get_active_device_profile()->e_cores
        : 1U;
    return pt_is_hidden_sysctl_name_cstr(
        name,
        pt_is_compat13_7_active() ? true : false,
        e_cores
    ) ? YES : NO;
}

static int pt_get_spoofed_cpusubfamily(const pt_device_profile_t *profile) {
    if (profile != NULL && profile->is_ipad &&
        (strcmp(profile->model, "iPad8,6") == 0 ||
         strcmp(profile->model, "iPad13,8") == 0 ||
         strcmp(profile->model, "iPad14,5") == 0 ||
         strcmp(profile->model, "iPad16,6") == 0 ||
         strcmp(profile->model, "iPad17,3") == 0)) {
        return CPUSUBFAMILY_ARM_HG;
    }
    return CPUSUBFAMILY_ARM_HP;
}

static BOOL pt_handle_sysctl_name_inner(const char *name,
                                        void *oldp,
                                        size_t *oldlenp,
                                        void *newp,
                                        size_t newlen,
                                        const void *caller,
                                        int *inout_is_sys_caller,
                                        int *out_ret) {
    char c0 = name[0];
    if (c0 != 'h' && c0 != 'k' && c0 != 'm' && c0 != 's' && c0 != 'v') {
        return NO;
    }
    if (c0 == 'v') {
        if (strcmp(name, "vm.swapfileprefix") == 0) {
            if (!pt_is_bypass_enabled() || pt_sysctl_resolve_is_sys(caller, inout_is_sys_caller)) {
                return NO;
            }
            *out_ret = pt_write_sysctl_string("/private/var/vm/swapfile", oldp, oldlenp);
            return YES;
        }
        if (strcmp(name, "vm.swap_enabled") == 0 ||
            strcmp(name, "vm.compressor.config.swap_present") == 0 ||
            strcmp(name, "vm.compressor.config.swap_active") == 0 ||
            strncmp(name, "vm.compressor.segment.swapped", 29) == 0) {
            if (!pt_is_bypass_enabled() || pt_sysctl_resolve_is_sys(caller, inout_is_sys_caller)) {
                return NO;
            }
            *out_ret = pt_write_sysctl_int(0, oldp, oldlenp);
            return YES;
        }
        if (strncmp(name, "vm.compressor.compactor.swapout", 31) == 0) {
            if (!pt_is_bypass_enabled() || pt_sysctl_resolve_is_sys(caller, inout_is_sys_caller)) {
                return NO;
            }
            *out_ret = pt_write_sysctl_uint64(oldp, oldlenp, (newlen > 0) ? newp : NULL, 0ULL);
            return YES;
        }
        if (strncmp(name, "vm.compressor.pages_swapped", 27) == 0 ||
            strncmp(name, "vm.compressor.pages_swap", 24) == 0) {
            if (!pt_is_bypass_enabled() || pt_sysctl_resolve_is_sys(caller, inout_is_sys_caller)) {
                return NO;
            }
            if (oldp != NULL && oldlenp != NULL && *oldlenp == sizeof(int)) {
                *out_ret = pt_write_sysctl_int(0, oldp, oldlenp);
            } else {
                *out_ret = pt_write_sysctl_uint64(oldp, oldlenp, (newlen > 0) ? newp : NULL, 0ULL);
            }
            return YES;
        }
        if (strcmp(name, "vm.compressor_mode") == 0 || strcmp(name, "vm.compressor.mode") == 0) {
            if (!pt_is_bypass_enabled() || pt_sysctl_resolve_is_sys(caller, inout_is_sys_caller)) {
                return NO;
            }
            *out_ret = pt_write_sysctl_int(8, oldp, oldlenp);
            return YES;
        }
    }
    if (c0 == 'h' && strncmp(name, "hw.", 3) == 0) {
        if (!pt_is_bypass_enabled() || pt_sysctl_resolve_is_sys(caller, inout_is_sys_caller)) {
            return NO;
        }
        const char *sub = name + 3;
        if (strcmp(sub, "machine") == 0 || strcmp(sub, "product") == 0) {
            *out_ret = pt_write_sysctl_string(DEVICE_MODEL, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "model") == 0 ||
            strcmp(sub, "target") == 0 ||
            strcmp(sub, "targettype") == 0 ||
            strcmp(sub, "jetsam_properties_product_type") == 0) {
            *out_ret = pt_write_sysctl_string(OEM_ID, oldp, oldlenp);
            return YES;
        }
        const pt_device_profile_t *profile = pt_get_active_device_profile();
        if (strcmp(sub, "use_kernelmanagerd") == 0) {
            errno = ENOENT;
            *out_ret = -1;
            return YES;
        }
        if (strncmp(sub, "optional.arm.", 13) == 0 && pt_is_compat13_7_active()) {
            errno = ENOENT;
            *out_ret = -1;
            return YES;
        }
        if (strcmp(sub, "packages") == 0) {
            *out_ret = pt_write_sysctl_int(1, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "l1icachesize") == 0) {
            uint64_t l1i = pt_get_spoofed_l1i_cache_size(profile, NO);
            *out_ret = pt_write_sysctl_uint64(oldp, oldlenp, (newlen > 0) ? newp : NULL, l1i);
            return YES;
        }
        if (strcmp(sub, "l1dcachesize") == 0) {
            uint64_t l1d = pt_get_spoofed_l1d_cache_size(profile);
            *out_ret = pt_write_sysctl_uint64(oldp, oldlenp, (newlen > 0) ? newp : NULL, l1d);
            return YES;
        }
        if (strcmp(sub, "l2cachesize") == 0) {
            uint64_t p_l2 = 0;
            pt_get_spoofed_l2_cache_sizes(profile, &p_l2, NULL);
            *out_ret = pt_write_sysctl_uint64(oldp, oldlenp, (newlen > 0) ? newp : NULL, p_l2);
            return YES;
        }
        if (strcmp(sub, "cacheconfig") == 0) {
            uint64_t vals[10] = {0};
            vals[0] = (uint64_t)profile->cores;
            vals[1] = 1ULL;
            vals[2] = (uint64_t)(profile->e_cores > 0 ? profile->e_cores : profile->cores);
            *out_ret = pt_write_sysctl_uint64_array(oldp, oldlenp, (newlen > 0) ? newp : NULL, vals, 10U);
            return YES;
        }
        if (strcmp(sub, "cachesize") == 0) {
            uint64_t vals[10] = {0};
            uint64_t p_l2 = 0;
            pt_get_spoofed_l2_cache_sizes(profile, &p_l2, NULL);
            vals[0] = profile->ram_bytes;
            vals[1] = pt_get_spoofed_l1d_cache_size(profile);
            vals[2] = p_l2;
            *out_ret = pt_write_sysctl_uint64_array(oldp, oldlenp, (newlen > 0) ? newp : NULL, vals, 10U);
            return YES;
        }
        if (strcmp(sub, "ncpu") == 0 ||
            strcmp(sub, "activecpu") == 0 ||
            strcmp(sub, "availcpu") == 0 ||
            strcmp(sub, "physicalcpu") == 0 ||
            strcmp(sub, "physicalcpu_max") == 0 ||
            strcmp(sub, "logicalcpu") == 0 ||
            strcmp(sub, "logicalcpu_max") == 0) {
            *out_ret = pt_write_sysctl_int((int)profile->cores, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "memsize") == 0) {
            *out_ret = pt_write_sysctl_uint64(oldp, oldlenp, (newlen > 0) ? newp : NULL, profile->ram_bytes);
            return YES;
        }
        if (strcmp(sub, "memsize_usable") == 0) {
            uint64_t usable = profile->ram_bytes - (profile->ram_bytes / 16ULL);
            *out_ret = pt_write_sysctl_uint64(oldp, oldlenp, (newlen > 0) ? newp : NULL, usable);
            return YES;
        }
        if (strcmp(sub, "physmem") == 0) {
            uint32_t phys32 = (uint32_t)(profile->ram_bytes > 0x80000000ULL ? 0x80000000U : profile->ram_bytes);
            *out_ret = pt_write_sysctl_int((int)phys32, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "cpufamily") == 0) {
            *out_ret = pt_write_sysctl_int((int)profile->cpufamily, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "cputype") == 0) {
            *out_ret = pt_write_sysctl_int((int)CPU_TYPE_ARM64, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "cpusubtype") == 0) {
            *out_ret = pt_write_sysctl_int((int)CPU_SUBTYPE_ARM64_ALL, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "cpusubfamily") == 0) {
            *out_ret = pt_write_sysctl_int(pt_get_spoofed_cpusubfamily(profile), oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "pagesize") == 0) {
            *out_ret = pt_write_sysctl_int(16384, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "nperflevels") == 0) {
            *out_ret = pt_write_sysctl_int(profile->e_cores > 0 ? 2 : 1, oldp, oldlenp);
            return YES;
        }
        if (strncmp(sub, "perflevel0.", 11) == 0) {
            const char *psub = sub + 11;
            if (strcmp(psub, "physicalcpu") == 0 ||
                strcmp(psub, "physicalcpu_max") == 0 ||
                strcmp(psub, "logicalcpu") == 0 ||
                strcmp(psub, "logicalcpu_max") == 0 ||
                strcmp(psub, "cpusperl2") == 0) {
                *out_ret = pt_write_sysctl_int((int)profile->p_cores, oldp, oldlenp);
                return YES;
            }
            if (strcmp(psub, "l1icachesize") == 0) {
                uint64_t p_l1i = pt_get_spoofed_l1i_cache_size(profile, NO);
                *out_ret = pt_write_sysctl_uint64(oldp, oldlenp, (newlen > 0) ? newp : NULL, p_l1i);
                return YES;
            }
            if (strcmp(psub, "l1dcachesize") == 0) {
                uint64_t p_l1d = pt_get_spoofed_l1d_cache_size_for_level(profile, NO);
                *out_ret = pt_write_sysctl_uint64(oldp, oldlenp, (newlen > 0) ? newp : NULL, p_l1d);
                return YES;
            }
            if (strcmp(psub, "l2cachesize") == 0) {
                uint64_t p_l2 = 0;
                pt_get_spoofed_l2_cache_sizes(profile, &p_l2, NULL);
                *out_ret = pt_write_sysctl_uint64(oldp, oldlenp, (newlen > 0) ? newp : NULL, p_l2);
                return YES;
            }
            if (strcmp(psub, "name") == 0) {
                *out_ret = pt_write_sysctl_string("Performance", oldp, oldlenp);
                return YES;
            }
        }
        if (strncmp(sub, "perflevel1.", 11) == 0) {
            if (profile->e_cores == 0) {
                errno = ENOENT;
                *out_ret = -1;
                return YES;
            }
            const char *psub = sub + 11;
            if (strcmp(psub, "physicalcpu") == 0 ||
                strcmp(psub, "physicalcpu_max") == 0 ||
                strcmp(psub, "logicalcpu") == 0 ||
                strcmp(psub, "logicalcpu_max") == 0 ||
                strcmp(psub, "cpusperl2") == 0) {
                *out_ret = pt_write_sysctl_int((int)profile->e_cores, oldp, oldlenp);
                return YES;
            }
            if (strcmp(psub, "l1icachesize") == 0) {
                uint64_t e_l1i = pt_get_spoofed_l1i_cache_size(profile, YES);
                *out_ret = pt_write_sysctl_uint64(oldp, oldlenp, (newlen > 0) ? newp : NULL, e_l1i);
                return YES;
            }
            if (strcmp(psub, "l1dcachesize") == 0) {
                uint64_t e_l1d = pt_get_spoofed_l1d_cache_size_for_level(profile, YES);
                *out_ret = pt_write_sysctl_uint64(oldp, oldlenp, (newlen > 0) ? newp : NULL, e_l1d);
                return YES;
            }
            if (strcmp(psub, "l2cachesize") == 0) {
                uint64_t e_l2 = 0;
                pt_get_spoofed_l2_cache_sizes(profile, NULL, &e_l2);
                *out_ret = pt_write_sysctl_uint64(oldp, oldlenp, (newlen > 0) ? newp : NULL, e_l2);
                return YES;
            }
            if (strcmp(psub, "name") == 0) {
                *out_ret = pt_write_sysctl_string("Efficiency", oldp, oldlenp);
                return YES;
            }
        }
        return NO;
    }
    if (c0 == 'k' && strncmp(name, "kern.", 5) == 0) {
        const char *sub = name + 5;
        if (!pt_is_bypass_enabled() || pt_sysctl_resolve_is_sys(caller, inout_is_sys_caller)) {
            return NO;
        }
        const pt_device_profile_t *profile = pt_get_active_device_profile();
        if (strcmp(sub, "ostype") == 0) {
            *out_ret = pt_write_sysctl_string("Darwin", oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "osrelease") == 0) {
            *out_ret = pt_write_sysctl_string(pt_get_effective_kern_release(), oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "osversion") == 0) {
            pt_ensure_host_kernel_info();
            const char *ov_build = NULL;
            (void)pt_get_reported_ios_version_override(&ov_build);
            *out_ret = pt_write_sysctl_string(ov_build != NULL ? ov_build : s_spoofed_osversion, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "osproductversion") == 0) {
            pt_ensure_host_kernel_info();
            const char *ov_ver = pt_get_reported_ios_version_override(NULL);
            *out_ret = pt_write_sysctl_string(ov_ver != NULL ? ov_ver : s_spoofed_ios_version, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "version") == 0) {
            char kver[256];
            pt_format_kernel_version(profile, kver, sizeof(kver));
            *out_ret = pt_write_sysctl_string(kver, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "hostname") == 0) {
            *out_ret = pt_write_sysctl_string(profile->is_ipad ? "iPad" : "iPhone", oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "osrevision") == 0) {
            *out_ret = pt_write_sysctl_int(199506, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "coredump") == 0) {
            *out_ret = pt_write_sysctl_int(0, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "corefile") == 0) {
            *out_ret = pt_write_sysctl_string("", oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "iossupportversion") == 0 ||
            strcmp(sub, "hibernatefile") == 0) {
            errno = ENOENT;
            *out_ret = -1;
            return YES;
        }
        if (strcmp(sub, "bootargs") == 0 ||
            strcmp(sub, "wakereason") == 0) {
            *out_ret = pt_write_sysctl_string("", oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "secure_kernel") == 0) {
            *out_ret = pt_write_sysctl_int(1, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "hv_support") == 0 ||
            strcmp(sub, "hv_vmm_present") == 0) {
            *out_ret = pt_write_sysctl_int(0, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "osbuildconfig") == 0) {
            *out_ret = pt_write_sysctl_string("release", oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "osvariant_status") == 0) {
            int saved_errno = errno;
            uint64_t raw_status = 0x70010000f288828aULL;
            size_t rlen = sizeof(raw_status);
            (void)sysctlbyname("kern.osvariant_status", &raw_status, &rlen, NULL, 0);
            errno = saved_errno;
            uint64_t consumer_ios_status = pt_sanitize_osvariant_status_u64(raw_status);
            *out_ret = pt_write_sysctl_uint64(oldp, oldlenp, (newlen > 0) ? newp : NULL, consumer_ios_status);
            return YES;
        }
        return NO;
    }
    if (c0 == 'm' && strncmp(name, "machdep.cpu.", 12) == 0) {
        if (!pt_is_bypass_enabled() || pt_sysctl_resolve_is_sys(caller, inout_is_sys_caller)) {
            return NO;
        }
        const pt_device_profile_t *profile = pt_get_active_device_profile();
        const char *sub = name + 12;
        if (strcmp(sub, "brand_string") == 0) {
            *out_ret = pt_write_sysctl_string(profile->cpu_brand, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "core_count") == 0 ||
            strcmp(sub, "cores_per_package") == 0 ||
            strcmp(sub, "thread_count") == 0 ||
            strcmp(sub, "logical_per_package") == 0) {
            *out_ret = pt_write_sysctl_int((int)profile->cores, oldp, oldlenp);
            return YES;
        }
        if (strcmp(sub, "vendor") == 0) {
            *out_ret = pt_write_sysctl_string("Apple", oldp, oldlenp);
            return YES;
        }
        errno = ENOENT;
        *out_ret = -1;
        return YES;
    }
    if (c0 == 's' && strcmp(name, "security.mac.amfi.developer_mode_status") == 0) {
        if (!pt_is_bypass_enabled() || pt_sysctl_resolve_is_sys(caller, inout_is_sys_caller)) {
            return NO;
        }
        *out_ret = pt_write_sysctl_int(0, oldp, oldlenp);
        return YES;
    }
    return NO;
}

static BOOL pt_handle_sysctl_name(const char *name,
                                  void *oldp,
                                  size_t *oldlenp,
                                  void *newp,
                                  size_t newlen,
                                  const void *caller,
                                  int *inout_is_sys_caller,
                                  int *out_ret) {
    if (name == NULL || out_ret == NULL) {
        return NO;
    }
    if (pt_is_hidden_sysctl_name(name)) {
        if (!pt_is_bypass_enabled() || pt_sysctl_resolve_is_sys(caller, inout_is_sys_caller)) {
            return NO;
        }
        errno = ENOENT;
        *out_ret = -1;
        return YES;
    }
    if (newp != NULL && newlen > 0) {
        size_t probe_len = 0;
        int probe_ret = 0;
        int saved_errno = errno;
        BOOL matched = pt_handle_sysctl_name_inner(name, NULL, &probe_len, NULL, 0,
                                                   caller, inout_is_sys_caller, &probe_ret);
        if (matched) {
            if (probe_ret == -1 && errno == ENOENT) {
                *out_ret = -1;
                return YES;
            }
            errno = EPERM;
            *out_ret = -1;
            return YES;
        }
        errno = saved_errno;
        return NO;
    }
    return pt_handle_sysctl_name_inner(name, oldp, oldlenp, newp, newlen,
                                       caller, inout_is_sys_caller, out_ret);
}

static int pt_sysctlnametomib(const char *sname, int *mibp, size_t *sizep) {
    if (sname != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)) &&
        pt_is_hidden_sysctl_name(sname)) {
        errno = ENOENT;
        return -1;
    }
    return sysctlnametomib(sname, mibp, sizep);
}

static BOOL pt_append_procargs_bytes(char **buf, size_t *len, size_t *cap, const void *src, size_t n) {
    if (n == 0) {
        return YES;
    }
    if (*len + n > *cap) {
        size_t new_cap = (*cap == 0) ? 4096U : *cap;
        while (new_cap < *len + n) {
            if (new_cap > (16U << 20)) {
                return NO;
            }
            new_cap *= 2U;
        }
        char *grown = (char *)realloc(*buf, new_cap);
        if (grown == NULL) {
            return NO;
        }
        *buf = grown;
        *cap = new_cap;
    }
    memcpy(*buf + *len, src, n);
    *len += n;
    return YES;
}

__attribute__((visibility("hidden")))
BOOL pt_is_hidden_env_value(const char *val, BOOL has_virtual_container) {
    if (val == NULL || val[0] == '\0') {
        return NO;
    }
    if (strstr(val, "/Users/") != NULL ||
        strcasestr(val, "PlayTools") != NULL ||
        strcasestr(val, "PlayCover") != NULL ||
        strcasestr(val, "MacOver") != NULL ||
        strcasestr(val, "app.makedie") != NULL ||
        strcasestr(val, "AKInterface") != NULL) {
        return YES;
    }
    if (has_virtual_container &&
        (strstr(val, "/var/folders/") != NULL ||
         strstr(val, "/private/var/folders/") != NULL)) {
        return YES;
    }
    return NO;
}

static char s_initial_host_path_env[4096];
static pthread_once_t s_initial_host_path_once = PTHREAD_ONCE_INIT;

static void pt_init_initial_host_path_env(void) {
    const char *p = pt_raw_getenv("PATH");
    if (p != NULL && p[0] != '\0') {
        strlcpy(s_initial_host_path_env, p, sizeof(s_initial_host_path_env));
    }
}

static BOOL pt_env_val_is_host_path_or_container(const char *val, BOOL has_vc) {
    if (val == NULL || val[0] == '\0') {
        return NO;
    }
    if (pt_is_hidden_env_value(val, has_vc)) {
        return YES;
    }
    if (strncmp(val, "/Users/", 7) == 0 ||
        strncmp(val, "/System/Volumes/Data/Users/", 27) == 0 ||
        strncmp(val, "/var/folders/", 13) == 0 ||
        strncmp(val, "/private/var/folders/", 21) == 0) {
        return YES;
    }
    pt_ensure_data_container_map();
    if (s_real_data_container_len > 0 &&
        pt_match_prefix_modulo_private(val, s_real_data_container_dir, s_real_data_container_len) != NULL) {
        return YES;
    }
    pt_ensure_bundle_path_map();
    if (s_real_app_bundle_len > 0 &&
        pt_match_prefix_modulo_private(val, s_real_app_bundle_dir, s_real_app_bundle_len) != NULL) {
        return YES;
    }
    return NO;
}

static BOOL pt_env_path_val_is_host_macos(const char *val, BOOL has_vc) {
    if (val == NULL || val[0] == '\0') {
        return NO;
    }
    if (pt_is_hidden_env_value(val, has_vc)) {
        return YES;
    }
    pthread_once(&s_initial_host_path_once, pt_init_initial_host_path_env);
    if (s_initial_host_path_env[0] != '\0' && strcmp(val, s_initial_host_path_env) == 0) {
        return YES;
    }
    if (strstr(val, "/usr/local/") != NULL ||
        strstr(val, "/opt/homebrew") != NULL ||
        strstr(val, "/Library/Apple") != NULL ||
        strstr(val, "/System/Cryptexes") != NULL ||
        strstr(val, "/Applications/") != NULL) {
        return YES;
    }
    return NO;
}

__attribute__((visibility("hidden")))
pt_env_entry_action_t pt_resolve_env_entry(const char *key,
                                           const char *raw_val,
                                           BOOL has_raw_entry,
                                           BOOL bypass_enabled,
                                           const char *vh,
                                           const char *vt,
                                           const char **out_val) {
    if (out_val != NULL) {
        *out_val = NULL;
    }
    if (key == NULL || key[0] == '\0' || !has_raw_entry || raw_val == NULL) {
        return PT_ENV_ENTRY_HIDE;
    }
    if (!bypass_enabled) {
        return PT_ENV_ENTRY_KEEP;
    }
    BOOL has_vc = (vh != NULL);
    if (strcmp(key, "HOME") == 0 || strcmp(key, "CFFIXED_USER_HOME") == 0) {
        if (vh != NULL && pt_env_val_is_host_path_or_container(raw_val, has_vc)) {
            if (out_val != NULL) {
                *out_val = vh;
            }
            return PT_ENV_ENTRY_REWRITE;
        }
        if (pt_is_hidden_env_value(raw_val, has_vc)) {
            return PT_ENV_ENTRY_HIDE;
        }
        return PT_ENV_ENTRY_KEEP;
    }
    if (strcmp(key, "TMPDIR") == 0 || strcmp(key, "TMP") == 0 || strcmp(key, "TEMP") == 0) {
        if (vt != NULL && pt_env_val_is_host_path_or_container(raw_val, has_vc)) {
            if (out_val != NULL) {
                *out_val = vt;
            }
            return PT_ENV_ENTRY_REWRITE;
        }
        if (pt_is_hidden_env_value(raw_val, has_vc)) {
            return PT_ENV_ENTRY_HIDE;
        }
        return PT_ENV_ENTRY_KEEP;
    }
    if (strcmp(key, "PWD") == 0) {
        if (pt_env_val_is_host_path_or_container(raw_val, has_vc)) {
            if (out_val != NULL) {
                *out_val = "/";
            }
            return PT_ENV_ENTRY_REWRITE;
        }
        return PT_ENV_ENTRY_KEEP;
    }
    if (strcmp(key, "PATH") == 0) {
        if (pt_env_path_val_is_host_macos(raw_val, has_vc)) {
            if (out_val != NULL) {
                *out_val = "/usr/bin:/bin:/usr/sbin:/sbin";
            }
            return PT_ENV_ENTRY_REWRITE;
        }
        return PT_ENV_ENTRY_KEEP;
    }
    if (pt_is_hidden_env_key(key) || pt_is_hidden_env_value(raw_val, has_vc)) {
        return PT_ENV_ENTRY_HIDE;
    }
    return PT_ENV_ENTRY_KEEP;
}

extern int pt_orig_kernel_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen)
    __asm("___sysctl");

static BOOL pt_is_xnu_apple_vector_entry(const char *entry, size_t elen) {
    if (entry == NULL || elen == 0) {
        return NO;
    }
    static const struct {
        const char *prefix;
        size_t len;
    } kApplePrefixes[] = {
        PT_STR_ENTRY("executable_path="),
        PT_STR_ENTRY("pfz="),
        PT_STR_ENTRY("stack_guard="),
        PT_STR_ENTRY("malloc_entropy="),
        PT_STR_ENTRY("ptr_munge="),
        PT_STR_ENTRY("main_stack="),
        PT_STR_ENTRY("executable_file="),
        PT_STR_ENTRY("dyld_file="),
        PT_STR_ENTRY("executable_cdhash="),
        PT_STR_ENTRY("executable_boothash="),
        PT_STR_ENTRY("arm64e_abi="),
        PT_STR_ENTRY("th_port="),
        PT_STR_ENTRY("dyld_flags="),
        PT_STR_ENTRY("shm_size="),
        PT_STR_ENTRY("ptrauth_disabled="),
    };
    for (size_t i = 0; i < sizeof(kApplePrefixes) / sizeof(kApplePrefixes[0]); i++) {
        if (elen >= kApplePrefixes[i].len &&
            memcmp(entry, kApplePrefixes[i].prefix, kApplePrefixes[i].len) == 0) {
            return YES;
        }
    }
    return NO;
}

static int pt_handle_sysctl_procargs(int *name, u_int types, void *buf, size_t *size) {
    if (types < 3 || (name[2] != getpid())) {
        errno = ESRCH;
        return -1;
    }
    BOOL is_v2 = (name[1] == KERN_PROCARGS2);
    // Always query KERN_PROCARGS2 from the kernel so we have the exact argc boundary
    // for both KERN_PROCARGS (v1) and KERN_PROCARGS2 (v2), preventing argv/envp/apple misclassification.
    int query_mib[3] = { CTL_KERN, KERN_PROCARGS2, name[2] };
    size_t raw_len = 0;
    if (pt_orig_kernel_sysctl(query_mib, 3, NULL, &raw_len, NULL, 0) != 0 || raw_len < sizeof(int)) {
        return -1;
    }
    size_t alloc_len = raw_len + 64U;
    char *raw = (char *)malloc(alloc_len);
    if (raw == NULL) {
        errno = ENOMEM;
        return -1;
    }
    if (pt_orig_kernel_sysctl(query_mib, 3, raw, &raw_len, NULL, 0) != 0 || raw_len < sizeof(int)) {
        int saved = errno;
        free(raw);
        errno = saved;
        return -1;
    }
    raw[raw_len] = '\0';

    char *out = NULL;
    size_t out_len = 0;
    size_t out_cap = 0;
    size_t pos = sizeof(int);
    int argc = 0;
    memcpy(&argc, raw, sizeof(int));
    if (argc < 0) {
        argc = 0;
    }

    if (is_v2) {
        if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, &argc, sizeof(int))) {
            free(raw); free(out); errno = ENOMEM; return -1;
        }
    }

    char vexec_buf[PATH_MAX];
    const char *virt_exec = "";
    if (pos < raw_len) {
        const char *exec_path = raw + pos;
        size_t elen = strnlen(exec_path, raw_len - pos);
        virt_exec = pt_virtualize_path_for_app(exec_path, vexec_buf, sizeof(vexec_buf), YES);
        size_t velen = strlen(virt_exec) + 1U;
        if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, virt_exec, velen)) {
            free(raw); free(out); errno = ENOMEM; return -1;
        }
        pos += (elen < raw_len - pos) ? (elen + 1U) : elen;
        while (pos < raw_len && raw[pos] == '\0') {
            pos++;
        }
        uint8_t zero = 0;
        while ((out_len & 3U) != 0U) {
            if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, &zero, 1U)) {
                free(raw); free(out); errno = ENOMEM; return -1;
            }
        }
    }

    // Emit sanitized argv for BOTH KERN_PROCARGS (v1) and KERN_PROCARGS2 (v2).
    BOOL bypass = pt_is_bypass_enabled();
    int written_argc = 0;
    for (int i = 0; i < argc && pos < raw_len; i++) {
        const char *arg = raw + pos;
        size_t alen = strnlen(arg, raw_len - pos);
        size_t next_pos = pos + ((alen < raw_len - pos) ? (alen + 1U) : alen);
        if (bypass && i > 0) {
            const char *next_arg = (i + 1 < argc && next_pos < raw_len) ? (raw + next_pos) : NULL;
            int skip = pt_macos_launch_arg_skip_count(arg, next_arg);
            if (skip > 0) {
                pos = next_pos;
                if (skip == 2 && i + 1 < argc && pos < raw_len) {
                    size_t nlen = strnlen(raw + pos, raw_len - pos);
                    pos += (nlen < raw_len - pos) ? (nlen + 1U) : nlen;
                    i++;
                }
                continue;
            }
        }
        const char *out_arg = arg;
        char varg[PATH_MAX];
        if (i == 0) {
            out_arg = pt_virtualize_path_for_app(arg, varg, sizeof(varg), YES);
        }
        if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, out_arg, strlen(out_arg) + 1U)) {
            free(raw); free(out); errno = ENOMEM; return -1;
        }
        written_argc++;
        pos = next_pos;
    }
    if (is_v2 && out != NULL && out_len >= sizeof(int)) {
        memcpy(out, &written_argc, sizeof(int));
    }

    // Serialize sanitized envp directly from pt_get_app_shadow_environ_ptr() so zeroed
    // PlayLoader.m stack slots never truncate the environment vector.
    char ***shadow_envpp = pt_get_app_shadow_environ_ptr();
    char **shadow_envp = (shadow_envpp != NULL) ? __atomic_load_n(shadow_envpp, __ATOMIC_ACQUIRE) : NULL;
    if (shadow_envp != NULL) {
        for (size_t i = 0; shadow_envp[i] != NULL; i++) {
            const char *kv = shadow_envp[i];
            if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, kv, strlen(kv) + 1U)) {
                free(raw); free(out); errno = ENOMEM; return -1;
            }
        }
    }

    // Empty-string separator between envp[] and apple[].
    if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, "", 1U)) {
        free(raw); free(out); errno = ENOMEM; return -1;
    }

    // Scan remaining raw bytes (skipping any NUL runs left by zeroed env slots) and emit sanitized apple[] entries.
    const char *vh = pt_get_virtual_home_cstr();
    BOOL has_vc = (vh != NULL);
    BOOL in_apple = NO;
    BOOL wrote_exec_path_apple = NO;
    while (pos < raw_len) {
        if (raw[pos] == '\0') {
            pos++;
            continue;
        }
        const char *entry = raw + pos;
        size_t elen = strnlen(entry, raw_len - pos);
        pos += (elen < raw_len - pos) ? (elen + 1U) : elen;

        if (!in_apple) {
            if (elen >= 16U && memcmp(entry, "executable_path=", 16U) == 0) {
                in_apple = YES;
            } else if (!pt_is_xnu_apple_vector_entry(entry, elen)) {
                continue;
            }
        }

        if (elen >= 16U && memcmp(entry, "executable_path=", 16U) == 0) {
            if (!wrote_exec_path_apple) {
                if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, "executable_path=", 16U) ||
                    !pt_append_procargs_bytes(&out, &out_len, &out_cap, virt_exec, strlen(virt_exec) + 1U)) {
                    free(raw); free(out); errno = ENOMEM; return -1;
                }
                wrote_exec_path_apple = YES;
            }
            continue;
        }
        if (elen >= 19U && memcmp(entry, "MACOVER_AUTOMATION_", 19U) == 0) {
            continue;
        }
        char abuf_stack[1024];
        char *abuf_heap = NULL;
        const char *astr = abuf_stack;
        if (elen < sizeof(abuf_stack)) {
            memcpy(abuf_stack, entry, elen);
            abuf_stack[elen] = '\0';
        } else {
            abuf_heap = (char *)malloc(elen + 1U);
            if (abuf_heap == NULL) {
                free(raw); free(out); errno = ENOMEM; return -1;
            }
            memcpy(abuf_heap, entry, elen);
            abuf_heap[elen] = '\0';
            astr = abuf_heap;
        }
        BOOL hide_apple = (bypass && pt_is_hidden_env_value(astr, has_vc));
        free(abuf_heap);
        if (hide_apple) {
            continue;
        }
        if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, entry, elen) ||
            !pt_append_procargs_bytes(&out, &out_len, &out_cap, "", 1U)) {
            free(raw); free(out); errno = ENOMEM; return -1;
        }
    }
    if (!wrote_exec_path_apple && virt_exec[0] != '\0') {
        if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, "executable_path=", 16U) ||
            !pt_append_procargs_bytes(&out, &out_len, &out_cap, virt_exec, strlen(virt_exec) + 1U)) {
            free(raw); free(out); errno = ENOMEM; return -1;
        }
    }
    if (!pt_append_procargs_bytes(&out, &out_len, &out_cap, "", 1U)) {
        free(raw); free(out); errno = ENOMEM; return -1;
    }
    free(raw);

    if (buf == NULL) {
        if (size != NULL) {
            *size = out_len;
        }
        free(out);
        return 0;
    }
    if (size == NULL || *size < out_len) {
        if (size != NULL) {
            *size = out_len;
        }
        free(out);
        errno = ENOMEM;
        return -1;
    }
    if (out_len > 0 && out != NULL) {
        memcpy(buf, out, out_len);
    }
    *size = out_len;
    free(out);
    return 0;
}

#define PT_RT_ROUNDUP(a) ((a) > 0U ? (1U + (((a) - 1U) | (sizeof(uint32_t) - 1U))) : sizeof(uint32_t))

static BOOL pt_u16_list_contains(const uint16_t *arr, size_t count, uint16_t val) {
    for (size_t i = 0; i < count; i++) {
        if (arr[i] == val) {
            return YES;
        }
    }
    return NO;
}

static void pt_u16_list_set_hidden(uint16_t *arr, size_t *count, size_t cap, uint16_t val, BOOL hidden) {
    if (val == 0) {
        return;
    }
    for (size_t i = 0; i < *count; i++) {
        if (arr[i] == val) {
            if (!hidden) {
                arr[i] = arr[*count - 1U];
                (*count)--;
            }
            return;
        }
    }
    if (hidden && *count < cap) {
        arr[(*count)++] = val;
    }
}

static BOOL pt_rt_ifinfo_msg_has_hidden_ifname(const uint8_t *msg,
                                               size_t msg_len,
                                               size_t fixed_hdr_len,
                                               int addrs) {
    if ((addrs & RTA_IFP) == 0 || msg_len <= fixed_hdr_len) {
        return NO;
    }
    const uint8_t *cur = msg + fixed_hdr_len;
    const uint8_t *end = msg + msg_len;
    for (int bit = 1; bit <= RTA_IFP; bit <<= 1) {
        if ((addrs & bit) == 0) {
            continue;
        }
        if ((size_t)(end - cur) < sizeof(struct sockaddr)) {
            return NO;
        }
        const struct sockaddr *sa = (const struct sockaddr *)cur;
        size_t sa_len = (size_t)sa->sa_len;
        if (sa_len == 0 || (size_t)(end - cur) < sa_len) {
            return NO;
        }
        if (bit == RTA_IFP) {
            if (sa->sa_family == AF_LINK && sa_len >= offsetof(struct sockaddr_dl, sdl_data)) {
                const struct sockaddr_dl *sdl = (const struct sockaddr_dl *)sa;
                size_t avail = sa_len - offsetof(struct sockaddr_dl, sdl_data);
                size_t nlen = (size_t)sdl->sdl_nlen;
                if (nlen > avail) {
                    nlen = avail;
                }
                if (nlen > 0 && nlen < IFNAMSIZ) {
                    char ifname[IFNAMSIZ];
                    memcpy(ifname, sdl->sdl_data, nlen);
                    ifname[nlen] = '\0';
                    return pt_is_hidden_network_ifname(ifname);
                }
            }
            return NO;
        }
        size_t step = (size_t)PT_RT_ROUNDUP((unsigned int)sa_len);
        if (step > (size_t)(end - cur)) {
            return NO;
        }
        cur += step;
    }
    return NO;
}

typedef struct {
    u_short msglen;
    u_char version;
    u_char type;
} pt_rt_msg_prefix_t;

static void pt_compact_rt_iflist_sysctl(void *buf, size_t *size) {
    if (buf == NULL || size == NULL || *size == 0) {
        return;
    }
    uint8_t *base = (uint8_t *)buf;
    size_t total = *size;
    size_t read_pos = 0;
    size_t write_pos = 0;
    uint16_t hidden_indices[64];
    size_t hidden_count = 0;
    BOOL skip_cur_if = NO;

    while (read_pos + sizeof(pt_rt_msg_prefix_t) <= total) {
        const uint8_t *msg = base + read_pos;
        pt_rt_msg_prefix_t pre;
        memcpy(&pre, msg, sizeof(pre));
        size_t msglen = (size_t)pre.msglen;
        if (msglen < sizeof(pt_rt_msg_prefix_t) || read_pos + msglen > total) {
            size_t rem = total - read_pos;
            if (write_pos != read_pos) {
                memmove(base + write_pos, base + read_pos, rem);
            }
            write_pos += rem;
            read_pos = total;
            break;
        }

        BOOL drop = NO;
        switch (pre.type) {
            case RTM_IFINFO:
                if (msglen >= sizeof(struct if_msghdr)) {
                    struct if_msghdr ifm;
                    memcpy(&ifm, msg, sizeof(ifm));
                    skip_cur_if = pt_rt_ifinfo_msg_has_hidden_ifname(
                        msg, msglen, sizeof(struct if_msghdr), ifm.ifm_addrs);
                    pt_u16_list_set_hidden(hidden_indices, &hidden_count, 64U, ifm.ifm_index, skip_cur_if);
                    drop = skip_cur_if;
                } else {
                    skip_cur_if = NO;
                }
                break;

            case RTM_IFINFO2:
                if (msglen >= sizeof(struct if_msghdr2)) {
                    struct if_msghdr2 ifm2;
                    memcpy(&ifm2, msg, sizeof(ifm2));
                    skip_cur_if = pt_rt_ifinfo_msg_has_hidden_ifname(
                        msg, msglen, sizeof(struct if_msghdr2), ifm2.ifm_addrs);
                    pt_u16_list_set_hidden(hidden_indices, &hidden_count, 64U, ifm2.ifm_index, skip_cur_if);
                    drop = skip_cur_if;
                } else {
                    skip_cur_if = NO;
                }
                break;

            case RTM_NEWADDR:
                if (msglen >= sizeof(struct ifa_msghdr)) {
                    struct ifa_msghdr ifam;
                    memcpy(&ifam, msg, sizeof(ifam));
                    drop = (skip_cur_if ||
                            pt_u16_list_contains(hidden_indices, hidden_count, ifam.ifam_index));
                }
                break;

            case RTM_NEWMADDR:
                if (msglen >= sizeof(struct ifma_msghdr)) {
                    struct ifma_msghdr ifmam;
                    memcpy(&ifmam, msg, sizeof(ifmam));
                    drop = (skip_cur_if ||
                            pt_u16_list_contains(hidden_indices, hidden_count, ifmam.ifmam_index));
                }
                break;

            case RTM_NEWMADDR2:
                if (msglen >= sizeof(struct ifma_msghdr2)) {
                    struct ifma_msghdr2 ifmam2;
                    memcpy(&ifmam2, msg, sizeof(ifmam2));
                    drop = (skip_cur_if ||
                            pt_u16_list_contains(hidden_indices, hidden_count, ifmam2.ifmam_index));
                }
                break;

            default:
                break;
        }

        if (!drop) {
            if (write_pos != read_pos) {
                memmove(base + write_pos, msg, msglen);
            }
            write_pos += msglen;
        }
        read_pos += msglen;
    }

    if (read_pos < total) {
        size_t rem = total - read_pos;
        if (write_pos != read_pos) {
            memmove(base + write_pos, base + read_pos, rem);
        }
        write_pos += rem;
    }
    *size = write_pos;
}

static BOOL pt_rt_ifindex_is_hidden(uint16_t ifindex, uint8_t cache[256]) {
    if (ifindex == 0U) {
        return NO;
    }
    if (ifindex < 256U && cache[ifindex] != 0U) {
        return (cache[ifindex] == 2U);
    }
    int saved_errno = errno;
    char ifname[IFNAMSIZ + 1];
    memset(ifname, 0, sizeof(ifname));
    BOOL hidden = NO;
    if (if_indextoname((unsigned int)ifindex, ifname) != NULL) {
        hidden = pt_is_hidden_network_ifname(ifname);
    }
    errno = saved_errno;
    if (ifindex < 256U) {
        cache[ifindex] = hidden ? 2U : 1U;
    }
    return hidden;
}

static void pt_compact_rt_dump_sysctl(void *buf, size_t *size, BOOL is_dump2) {
    if (buf == NULL || size == NULL || *size == 0) {
        return;
    }
    uint8_t *base = (uint8_t *)buf;
    size_t total = *size;
    size_t read_pos = 0;
    size_t write_pos = 0;
    uint8_t idx_cache[256];
    memset(idx_cache, 0, sizeof(idx_cache));
    size_t min_hdr = is_dump2 ? sizeof(struct rt_msghdr2) : sizeof(struct rt_msghdr);

    while (read_pos + sizeof(pt_rt_msg_prefix_t) <= total) {
        const uint8_t *msg = base + read_pos;
        pt_rt_msg_prefix_t pre;
        memcpy(&pre, msg, sizeof(pre));
        size_t msglen = (size_t)pre.msglen;
        if (msglen < sizeof(pt_rt_msg_prefix_t) || read_pos + msglen > total) {
            size_t rem = total - read_pos;
            if (write_pos != read_pos) {
                memmove(base + write_pos, base + read_pos, rem);
            }
            write_pos += rem;
            read_pos = total;
            break;
        }
        BOOL drop = NO;
        if (msglen >= min_hdr) {
            uint16_t rtm_index = 0;
            int rtm_addrs = 0;
            if (is_dump2) {
                struct rt_msghdr2 rtm2;
                memcpy(&rtm2, msg, sizeof(rtm2));
                rtm_index = rtm2.rtm_index;
                rtm_addrs = rtm2.rtm_addrs;
            } else {
                struct rt_msghdr rtm;
                memcpy(&rtm, msg, sizeof(rtm));
                rtm_index = rtm.rtm_index;
                rtm_addrs = rtm.rtm_addrs;
            }
            if (pt_rt_ifindex_is_hidden(rtm_index, idx_cache) ||
                pt_rt_ifinfo_msg_has_hidden_ifname(msg, msglen, min_hdr, rtm_addrs)) {
                drop = YES;
            }
        }
        if (!drop) {
            if (write_pos != read_pos) {
                memmove(base + write_pos, msg, msglen);
            }
            write_pos += msglen;
        }
        read_pos += msglen;
    }
    if (read_pos < total) {
        size_t rem = total - read_pos;
        if (write_pos != read_pos) {
            memmove(base + write_pos, base + read_pos, rem);
        }
        write_pos += rem;
    }
    *size = write_pos;
}

static void pt_sanitize_kinfo_proc(struct kinfo_proc *info, BOOL is_sys) {
    if (info == NULL) {
        return;
    }
    if (is_sys || !pt_is_bypass_enabled()) {
        return;
    }
    info->kp_proc.p_flag &= ~P_TRACED;
    info->kp_eproc.e_ppid = 1;
    strlcpy(info->kp_eproc.e_login, "mobile", sizeof(info->kp_eproc.e_login));
    info->kp_eproc.e_pcred.p_rgid = pt_map_spoofed_gid(info->kp_eproc.e_pcred.p_rgid);
    info->kp_eproc.e_pcred.p_svgid = pt_map_spoofed_gid(info->kp_eproc.e_pcred.p_svgid);
    size_t max_groups = sizeof(info->kp_eproc.e_ucred.cr_groups) / sizeof(info->kp_eproc.e_ucred.cr_groups[0]);
    short raw_n = info->kp_eproc.e_ucred.cr_ngroups;
    if (raw_n < 0) {
        raw_n = 0;
    }
    if ((size_t)raw_n > max_groups) {
        raw_n = (short)max_groups;
    }
    gid_t filtered[NGROUPS];
    size_t filtered_n = 0;
    for (short i = 0; i < raw_n && filtered_n < max_groups; i++) {
        gid_t g = info->kp_eproc.e_ucred.cr_groups[i];
        if (pt_is_desktop_supplemental_gid(g)) {
            continue;
        }
        g = pt_map_spoofed_gid(g);
        BOOL dup = NO;
        for (size_t j = 0; j < filtered_n; j++) {
            if (filtered[j] == g) {
                dup = YES;
                break;
            }
        }
        if (!dup) {
            filtered[filtered_n++] = g;
        }
    }
    if (filtered_n == 0) {
        filtered[0] = 501;
        filtered_n = 1;
    }
    for (size_t i = 0; i < filtered_n; i++) {
        info->kp_eproc.e_ucred.cr_groups[i] = filtered[i];
    }
    for (size_t i = filtered_n; i < max_groups; i++) {
        info->kp_eproc.e_ucred.cr_groups[i] = 0;
    }
    info->kp_eproc.e_ucred.cr_ngroups = (short)filtered_n;
}

#define PT_OID_NAME_CACHE_CAP 256U

typedef struct {
    int oid[CTL_MAXNAME];
    u_int len;
    char name[128];
    bool valid;
} pt_oid_name_cache_entry_t;

static os_unfair_lock s_oid_name_cache_lock = OS_UNFAIR_LOCK_INIT;
static pt_oid_name_cache_entry_t s_oid_name_cache[PT_OID_NAME_CACHE_CAP];
static uint32_t s_oid_name_cache_next = 0;

static BOOL pt_reverse_resolve_oid_name(const int *name, u_int types, char *out_name, size_t out_cap) {
    if (name == NULL || types == 0 || types > CTL_MAXNAME || out_name == NULL || out_cap == 0) {
        return NO;
    }
    os_unfair_lock_lock(&s_oid_name_cache_lock);
    for (uint32_t i = 0; i < PT_OID_NAME_CACHE_CAP; i++) {
        const pt_oid_name_cache_entry_t *e = &s_oid_name_cache[i];
        if (e->valid && e->len == types && memcmp(e->oid, name, (size_t)types * sizeof(int)) == 0) {
            BOOL ok = (e->name[0] != '\0');
            if (ok) {
                strlcpy(out_name, e->name, out_cap);
            }
            os_unfair_lock_unlock(&s_oid_name_cache_lock);
            return ok;
        }
    }
    os_unfair_lock_unlock(&s_oid_name_cache_lock);

    int q[CTL_MAXNAME + 2];
    q[0] = 0;
    q[1] = 1;
    memcpy(q + 2, name, (size_t)types * sizeof(int));
    char kbuf[256];
    size_t klen = sizeof(kbuf) - 1U;
    int saved_errno = errno;
    int kr = pt_orig_kernel_sysctl(q, 2U + types, kbuf, &klen, NULL, 0);
    errno = saved_errno;
    if (kr == 0 && klen > 0 && klen < sizeof(kbuf)) {
        kbuf[klen] = '\0';
    } else {
        kbuf[0] = '\0';
    }

    os_unfair_lock_lock(&s_oid_name_cache_lock);
    uint32_t slot = s_oid_name_cache_next % PT_OID_NAME_CACHE_CAP;
    s_oid_name_cache_next = (s_oid_name_cache_next + 1U) % PT_OID_NAME_CACHE_CAP;
    memcpy(s_oid_name_cache[slot].oid, name, (size_t)types * sizeof(int));
    s_oid_name_cache[slot].len = types;
    strlcpy(s_oid_name_cache[slot].name, kbuf, sizeof(s_oid_name_cache[slot].name));
    s_oid_name_cache[slot].valid = true;
    os_unfair_lock_unlock(&s_oid_name_cache_lock);

    if (kbuf[0] != '\0') {
        strlcpy(out_name, kbuf, out_cap);
        return YES;
    }
    return NO;
}

__attribute__((visibility("hidden")))
int pt_sysctl_with_caller(int *name,
                          u_int types,
                          void *buf,
                          size_t *size,
                          void *arg0,
                          size_t arg1,
                          const void *ret_addr) {
    int is_sys_caller = -1;
    if (name != NULL && types >= 2) {
        if (name[0] == 0 &&
            pt_is_bypass_enabled() &&
            !pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
            if (name[1] == 3 && arg0 != NULL && arg1 > 0 && arg1 <= 512U) {
                char qname[513];
                size_t slen = strnlen((const char *)arg0, arg1);
                memcpy(qname, arg0, slen);
                qname[slen] = '\0';
                if (pt_is_hidden_sysctl_name(qname)) {
                    errno = ENOENT;
                    return -1;
                }
            } else if ((name[1] == 1 || name[1] == 4 || name[1] == 5 || name[1] == 6) &&
                       types >= 3 && types <= CTL_MAXNAME + 2) {
                int name_q[CTL_MAXNAME + 2];
                name_q[0] = 0;
                name_q[1] = 1;
                memcpy(name_q + 2, name + 2, (size_t)(types - 2U) * sizeof(int));
                char qname[512];
                size_t qlen = sizeof(qname) - 1U;
                if (pt_orig_kernel_sysctl(name_q, types, qname, &qlen, NULL, 0) == 0) {
                    qname[qlen < sizeof(qname) ? qlen : sizeof(qname) - 1U] = '\0';
                    if (pt_is_hidden_sysctl_name(qname)) {
                        errno = ENOENT;
                        return -1;
                    }
                }
            } else if (name[1] == 2 && types <= CTL_MAXNAME + 2) {
                int cur_q[CTL_MAXNAME + 2];
                memcpy(cur_q, name, (size_t)types * sizeof(int));
                u_int cur_qlen = types;
                for (int skip = 0; skip < 2048; skip++) {
                    int next_oid[CTL_MAXNAME];
                    size_t next_sz = sizeof(next_oid);
                    int r = pt_orig_kernel_sysctl(cur_q, cur_qlen, next_oid, &next_sz, NULL, 0);
                    if (r != 0) {
                        return r;
                    }
                    if (next_sz == 0 || next_sz > sizeof(next_oid) || (next_sz % sizeof(int)) != 0) {
                        return pt_orig_kernel_sysctl(cur_q, cur_qlen, buf, size, arg0, arg1);
                    }
                    u_int next_cnt = (u_int)(next_sz / sizeof(int));
                    int name_q[CTL_MAXNAME + 2];
                    name_q[0] = 0;
                    name_q[1] = 1;
                    memcpy(name_q + 2, next_oid, next_sz);
                    char oid_name[512];
                    size_t oid_name_sz = sizeof(oid_name) - 1U;
                    int saved_errno = errno;
                    int name_r = pt_orig_kernel_sysctl(name_q, 2U + next_cnt, oid_name, &oid_name_sz, NULL, 0);
                    errno = saved_errno;
                    if (name_r == 0) {
                        oid_name[oid_name_sz < sizeof(oid_name) ? oid_name_sz : sizeof(oid_name) - 1U] = '\0';
                        if (pt_is_hidden_sysctl_name(oid_name)) {
                            cur_q[0] = 0;
                            cur_q[1] = name[1];
                            memcpy(cur_q + 2, next_oid, next_sz);
                            cur_qlen = 2U + next_cnt;
                            continue;
                        }
                    }
                    if (size == NULL) {
                        errno = EINVAL;
                        return -1;
                    }
                    if (buf == NULL) {
                        *size = next_sz;
                        return 0;
                    }
                    if (*size < next_sz) {
                        *size = next_sz;
                        errno = ENOMEM;
                        return -1;
                    }
                    memcpy(buf, next_oid, next_sz);
                    *size = next_sz;
                    return 0;
                }
                errno = ENOENT;
                return -1;
            }
        }
        if (name[0] == CTL_KERN) {
            if (types >= 4 && name[1] == KERN_PROC && name[2] == KERN_PROC_PID &&
                name[3] != getpid()) {
                if (pt_is_bypass_enabled() && !pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                    errno = ESRCH;
                    return -1;
                }
            }
            if (types >= 3 && name[1] == KERN_PROC && name[2] != KERN_PROC_PID && buf == NULL && size != NULL &&
                pt_is_bypass_enabled() && !pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                *size = sizeof(struct kinfo_proc);
                return 0;
            }
            if (types >= 3 && (name[1] == KERN_PROCARGS || name[1] == KERN_PROCARGS2) &&
                pt_is_bypass_enabled() && !pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                return pt_handle_sysctl_procargs(name, types, buf, size);
            }
        }
        const char *mapped_name = pt_lookup_mib_name(name, types);
        if (mapped_name != NULL) {
            int sret = 0;
            if (pt_handle_sysctl_name(mapped_name, buf, size, arg0, arg1, ret_addr, &is_sys_caller, &sret)) {
                return sret;
            }
        } else if (name[0] != 0 &&
                   name[0] != CTL_NET &&
                   !(name[0] == CTL_KERN && types >= 2 &&
                     (name[1] == KERN_PROC || name[1] == KERN_PROCARGS || name[1] == KERN_PROCARGS2)) &&
                   types <= CTL_MAXNAME &&
                   pt_is_bypass_enabled() &&
                   !pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
            char resolved_name[128];
            if (pt_reverse_resolve_oid_name(name, types, resolved_name, sizeof(resolved_name))) {
                int sret = 0;
                if (pt_handle_sysctl_name(resolved_name, buf, size, arg0, arg1, ret_addr, &is_sys_caller, &sret)) {
                    return sret;
                }
            }
        }
        if ((name[0] == CTL_KERN || name[0] == CTL_HW) && pt_is_bypass_enabled()) {
            if (name[0] == CTL_KERN) {
                switch (name[1]) {
                    case KERN_OSTYPE:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            if (arg0 != NULL && arg1 > 0) { errno = EPERM; return -1; }
                            return pt_write_sysctl_string("Darwin", buf, size);
                        }
                        break;
                    case KERN_OSRELEASE:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            if (arg0 != NULL && arg1 > 0) { errno = EPERM; return -1; }
                            return pt_write_sysctl_string(pt_get_effective_kern_release(), buf, size);
                        }
                        break;
                    case KERN_OSVERSION:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            if (arg0 != NULL && arg1 > 0) { errno = EPERM; return -1; }
                            pt_ensure_host_kernel_info();
                            const char *ov_build = NULL;
                            (void)pt_get_reported_ios_version_override(&ov_build);
                            return pt_write_sysctl_string(ov_build != NULL ? ov_build : s_spoofed_osversion, buf, size);
                        }
                        break;
                    case KERN_VERSION:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            if (arg0 != NULL && arg1 > 0) { errno = EPERM; return -1; }
                            char kver[256];
                            pt_format_kernel_version(pt_get_active_device_profile(), kver, sizeof(kver));
                            return pt_write_sysctl_string(kver, buf, size);
                        }
                        break;
                    case KERN_HOSTNAME:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            if (arg0 != NULL && arg1 > 0) { errno = EPERM; return -1; }
                            return pt_write_sysctl_string(pt_get_active_device_profile()->is_ipad ? "iPad" : "iPhone", buf, size);
                        }
                        break;
                    case KERN_OSREV:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            if (arg0 != NULL && arg1 > 0) { errno = EPERM; return -1; }
                            return pt_write_sysctl_int(199506, buf, size);
                        }
                        break;
                    default:
                        break;
                }
            } else if (name[0] == CTL_HW) {
                switch (name[1]) {
                    case HW_MACHINE:
                    case HW_PRODUCT:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            if (arg0 != NULL && arg1 > 0) { errno = EPERM; return -1; }
                            return pt_write_sysctl_string(DEVICE_MODEL, buf, size);
                        }
                        break;
                    case HW_MODEL:
                    case HW_TARGET:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            if (arg0 != NULL && arg1 > 0) { errno = EPERM; return -1; }
                            return pt_write_sysctl_string(OEM_ID, buf, size);
                        }
                        break;
                    case HW_NCPU:
                    case HW_AVAILCPU:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            if (arg0 != NULL && arg1 > 0) { errno = EPERM; return -1; }
                            return pt_write_sysctl_int((int)pt_get_active_device_profile()->cores, buf, size);
                        }
                        break;
                    case HW_MEMSIZE:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            if (arg0 != NULL && arg1 > 0) { errno = EPERM; return -1; }
                            return pt_write_sysctl_uint64(buf, size, NULL, pt_get_active_device_profile()->ram_bytes);
                        }
                        break;
                    case HW_PHYSMEM:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            if (arg0 != NULL && arg1 > 0) { errno = EPERM; return -1; }
                            uint64_t ram = pt_get_active_device_profile()->ram_bytes;
                            uint32_t phys32 = (uint32_t)(ram > 0x80000000ULL ? 0x80000000U : ram);
                            return pt_write_sysctl_int((int)phys32, buf, size);
                        }
                        break;
                    case HW_PAGESIZE:
                        if (!pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
                            if (arg0 != NULL && arg1 > 0) { errno = EPERM; return -1; }
                            return pt_write_sysctl_int(16384, buf, size);
                        }
                        break;
                    default:
                        break;
                }
            }
        }
    }
    // Fallback must not re-enter our ___sysctl interpose: libc's public sysctl()
    // forwards every non-CTL_USER MIB to __sysctl, which is interposed by
    // pt_kernel_sysctl and would recurse forever. Keep libc's userspace
    // CTL_USER handling, and call the original kernel entry for everything else.
    int ret = (name != NULL && types >= 1 && name[0] == CTL_USER)
        ? sysctl(name, types, buf, size, arg0, arg1)
        : pt_orig_kernel_sysctl(name, types, buf, size, arg0, arg1);
    if (ret == 0 && name != NULL && types >= 3 &&
        name[0] == CTL_KERN && name[1] == KERN_PROC && size != NULL &&
        pt_is_bypass_enabled()) {
        BOOL is_sys = pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller);
        if (name[2] == KERN_PROC_PID) {
            if (buf != NULL && *size >= sizeof(struct kinfo_proc)) {
                pt_sanitize_kinfo_proc((struct kinfo_proc *)buf, is_sys);
            }
        } else if (name[2] == KERN_PROC_ALL ||
                   (!is_sys && name[2] != KERN_PROC_PID)) {
            pid_t self_pid = getpid();
            if (buf == NULL) {
                if (!is_sys) {
                    *size = sizeof(struct kinfo_proc);
                }
            } else if (*size >= sizeof(struct kinfo_proc)) {
                size_t count = *size / sizeof(struct kinfo_proc);
                struct kinfo_proc *entries = (struct kinfo_proc *)buf;
                BOOL found_self = NO;
                for (size_t i = 0; i < count; i++) {
                    if (entries[i].kp_proc.p_pid == self_pid) {
                        pt_sanitize_kinfo_proc(&entries[i], is_sys);
                        if (!is_sys) {
                            if (i != 0) {
                                entries[0] = entries[i];
                            }
                            *size = sizeof(struct kinfo_proc);
                        }
                        found_self = YES;
                        break;
                    }
                }
                if (!is_sys && !found_self) {
                    *size = 0;
                }
            }
        }
    }
    if (ret == 0 && name != NULL && types >= 5 &&
        name[0] == CTL_NET && name[1] == PF_ROUTE &&
        buf != NULL && size != NULL && *size > 0 &&
        pt_is_bypass_enabled() &&
        !pt_sysctl_resolve_is_sys(ret_addr, &is_sys_caller)) {
        if (name[4] == NET_RT_IFLIST || name[4] == NET_RT_IFLIST2
#ifdef NET_RT_IFLISTL
            || name[4] == NET_RT_IFLISTL
#endif
        ) {
            pt_compact_rt_iflist_sysctl(buf, size);
        } else if (name[4] == NET_RT_DUMP) {
            pt_compact_rt_dump_sysctl(buf, size, NO);
        }
#ifdef NET_RT_DUMP2
        else if (name[4] == NET_RT_DUMP2) {
            pt_compact_rt_dump_sysctl(buf, size, YES);
        }
#endif
    }
    return ret;
}

static int pt_sysctl(int *name, u_int types, void *buf, size_t *size, void *arg0, size_t arg1) {
    return pt_sysctl_with_caller(name, types, buf, size, arg0, arg1, __builtin_return_address(0));
}

static int pt_kernel_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return pt_orig_kernel_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    }
    return pt_sysctl_with_caller(name, namelen, oldp, oldlenp, newp, newlen, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_sysctlbyname_with_caller(const char *name,
                                void *oldp,
                                size_t *oldlenp,
                                void *newp,
                                size_t newlen,
                                const void *caller) {
    if (name != NULL) {
        int is_sys_caller = -1;
        int sret = 0;
        if (pt_handle_sysctl_name(name, oldp, oldlenp, newp, newlen, caller, &is_sys_caller, &sret)) {
            PT_DEBUG_TRACE("spoofer", "spoofed sysctlbyname name=%s ret=%d", name, sret);
            return sret;
        }
    }
    return sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

static int pt_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    return pt_sysctlbyname_with_caller(name, oldp, oldlenp, newp, newlen, __builtin_return_address(0));
}

extern int pt_orig_kernel_sysctlbyname(const char *name,
                                       size_t namelen,
                                       void *oldp,
                                       size_t *oldlenp,
                                       void *newp,
                                       size_t newlen) __asm("___sysctlbyname");

static int pt_kernel_sysctlbyname(const char *name,
                                  size_t namelen,
                                  void *oldp,
                                  size_t *oldlenp,
                                  void *newp,
                                  size_t newlen) {
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return pt_orig_kernel_sysctlbyname(name, namelen, oldp, oldlenp, newp, newlen);
    }
    const void *caller = __builtin_return_address(0);
    if (name != NULL && namelen > 0 && namelen < 256U && pt_is_valid_user_pointer(name)) {
        char nbuf[256];
        size_t slen = strnlen(name, namelen);
        memcpy(nbuf, name, slen);
        nbuf[slen] = '\0';
        int is_sys_caller = -1;
        int sret = 0;
        if (pt_handle_sysctl_name(nbuf, oldp, oldlenp, newp, newlen, caller, &is_sys_caller, &sret)) {
            return sret;
        }
    }
    return pt_orig_kernel_sysctlbyname(name, namelen, oldp, oldlenp, newp, newlen);
}

__attribute__((visibility("hidden")))
BOOL pt_is_system_version_plist_dict(NSDictionary *dict) {
    if (![dict isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    if (![dict[@"ProductBuildVersion"] isKindOfClass:[NSString class]] ||
        dict[@"CFBundleIdentifier"] != nil ||
        dict[@"CFBundleExecutable"] != nil) {
        return NO;
    }
    if (dict[@"iOSSupportVersion"] != nil) {
        return YES;
    }
    id prodName = dict[@"ProductName"];
    if ([prodName isKindOfClass:[NSString class]] &&
        [dict[@"ProductVersion"] isKindOfClass:[NSString class]]) {
        NSString *pn = (NSString *)prodName;
        return ([pn isEqualToString:@"macOS"] ||
                [pn isEqualToString:@"Mac OS X"] ||
                [pn isEqualToString:@"iPhone OS"] ||
                [pn isEqualToString:@"iOS"]);
    }
    return NO;
}

__attribute__((visibility("hidden")))
BOOL pt_sanitize_ios_build_version_cstr(const char *build_cstr,
                                        const char *ios_ver_cstr,
                                        char *out_buf,
                                        size_t out_size) {
    pt_ensure_host_kernel_info();
    return pt_sanitize_ios_build_version_with_kern_major(
        build_cstr, ios_ver_cstr, atoi(s_real_kern_release), out_buf, out_size);
}

__attribute__((visibility("hidden")))
const char *pt_get_spoofed_ios_version_cstr(void) {
    pt_ensure_host_kernel_info();
    const char *ov_ver = pt_get_reported_ios_version_override(NULL);
    if (ov_ver != NULL && ov_ver[0] != '\0') {
        return ov_ver;
    }
    return s_spoofed_ios_version;
}

__attribute__((visibility("hidden")))
void pt_get_effective_ios_version_and_build(const char **out_ver, const char **out_build) {
    const char *ov_build = NULL;
    const char *ov_ver = pt_get_reported_ios_version_override(&ov_build);
    if (ov_ver != NULL && ov_ver[0] != '\0' && ov_build != NULL && ov_build[0] != '\0') {
        if (out_ver != NULL) *out_ver = ov_ver;
        if (out_build != NULL) *out_build = ov_build;
        return;
    }
    pt_ensure_host_kernel_info();
    if (out_ver != NULL) *out_ver = s_spoofed_ios_version;
    if (out_build != NULL) *out_build = s_spoofed_osversion;
}

__attribute__((visibility("hidden")))
void pt_sanitize_system_version_dict(NSMutableDictionary *dict) {
    if (dict == nil) {
        return;
    }
    const char *ov_build = NULL;
    const char *ov_ver = pt_get_reported_ios_version_override(&ov_build);
    if (ov_ver != NULL && ov_build != NULL) {
        NSString *verStr = [NSString stringWithUTF8String:ov_ver];
        if (verStr != nil) {
            dict[@"ProductVersion"] = verStr;
            if (dict[@"ProductUserVisibleVersion"] != nil) {
                dict[@"ProductUserVisibleVersion"] = verStr;
            }
        }
        [dict removeObjectForKey:@"iOSSupportVersion"];
        NSString *buildStr = [NSString stringWithUTF8String:ov_build];
        if (buildStr != nil) {
            dict[@"ProductBuildVersion"] = buildStr;
        }
        dict[@"ProductName"] = @"iPhone OS";
        return;
    }
    pt_ensure_host_kernel_info();
    id origProdName = dict[@"ProductName"];
    BOOL origWasMac = ([origProdName isKindOfClass:[NSString class]] &&
                       ([(NSString *)origProdName isEqualToString:@"macOS"] ||
                        [(NSString *)origProdName isEqualToString:@"Mac OS X"]));
    id iosVer = dict[@"iOSSupportVersion"];
    BOOL copiedIOSVer = NO;
    if ([iosVer isKindOfClass:[NSString class]] && [(NSString *)iosVer length] > 0) {
        NSString *iosStr = (NSString *)iosVer;
        int parsedMaj = atoi([iosStr UTF8String]);
        if (parsedMaj >= 11 && (parsedMaj <= 18 || parsedMaj >= 26)) {
            dict[@"ProductVersion"] = iosStr;
            if (dict[@"ProductUserVisibleVersion"] != nil) {
                dict[@"ProductUserVisibleVersion"] = iosStr;
            }
            copiedIOSVer = YES;
        }
    }
    [dict removeObjectForKey:@"iOSSupportVersion"];

    if (origWasMac && !copiedIOSVer) {
        NSString *derivedVer = nil;
        id macVerObj = dict[@"ProductVersion"];
        if ([macVerObj isKindOfClass:[NSString class]] && [(NSString *)macVerObj length] > 0) {
            int macMaj = 0, macMin = 0, macPat = 0;
            int nscan = sscanf([(NSString *)macVerObj UTF8String], "%d.%d.%d", &macMaj, &macMin, &macPat);
            if (nscan >= 1 && macMaj >= 11 && macMaj <= 15) {
                int iosMaj = macMaj + 3;
                derivedVer = (nscan >= 3 && macPat > 0)
                    ? [NSString stringWithFormat:@"%d.%d.%d", iosMaj, macMin, macPat]
                    : [NSString stringWithFormat:@"%d.%d", iosMaj, (nscan >= 2 ? macMin : 0)];
            } else if (nscan >= 1 && macMaj >= 26) {
                derivedVer = (NSString *)macVerObj;
            }
        }
        if (derivedVer == nil && dict[@"ProductBuildVersion"] != nil &&
            [dict[@"ProductBuildVersion"] isKindOfClass:[NSString class]]) {
            int bPrefix = atoi([(NSString *)dict[@"ProductBuildVersion"] UTF8String]);
            if (bPrefix >= 19 && bPrefix <= 99) {
                char fbuf[32];
                pt_fallback_ios_version_for_kern_major(bPrefix, fbuf, sizeof(fbuf));
                derivedVer = [NSString stringWithUTF8String:fbuf];
            }
        }
        if (derivedVer == nil && s_spoofed_ios_version[0] != '\0') {
            derivedVer = [NSString stringWithUTF8String:s_spoofed_ios_version];
        }
        if (derivedVer != nil) {
            dict[@"ProductVersion"] = derivedVer;
            if (dict[@"ProductUserVisibleVersion"] != nil) {
                dict[@"ProductUserVisibleVersion"] = derivedVer;
            }
        }
    } else if (!origWasMac) {
        id curProdVer = dict[@"ProductVersion"];
        if (![curProdVer isKindOfClass:[NSString class]] || [(NSString *)curProdVer length] == 0) {
            NSString *fallbackVer = [NSString stringWithUTF8String:s_spoofed_ios_version];
            if (fallbackVer.length > 0) {
                dict[@"ProductVersion"] = fallbackVer;
                if (dict[@"ProductUserVisibleVersion"] != nil) {
                    dict[@"ProductUserVisibleVersion"] = fallbackVer;
                }
            }
        } else {
            int pvMaj = atoi([(NSString *)curProdVer UTF8String]);
            if (pvMaj < 11 || (pvMaj >= 19 && pvMaj <= 25)) {
                NSString *fallbackVer = [NSString stringWithUTF8String:s_spoofed_ios_version];
                if (fallbackVer.length > 0) {
                    dict[@"ProductVersion"] = fallbackVer;
                    if (dict[@"ProductUserVisibleVersion"] != nil) {
                        dict[@"ProductUserVisibleVersion"] = fallbackVer;
                    }
                }
            }
        }
    }

    id prodVer = dict[@"ProductVersion"];
    const char *iosVerCStr = [prodVer isKindOfClass:[NSString class]] ? [(NSString *)prodVer UTF8String] : NULL;
    id buildVer = dict[@"ProductBuildVersion"];
    const char *rawBuildCStr = [buildVer isKindOfClass:[NSString class]] ? [(NSString *)buildVer UTF8String] : "";
    char sanitized[64] = {0};
    if (pt_sanitize_ios_build_version_cstr(rawBuildCStr,
                                           iosVerCStr,
                                           sanitized,
                                           sizeof(sanitized))) {
        NSString *mapped = [NSString stringWithUTF8String:sanitized];
        if (mapped != nil) {
            dict[@"ProductBuildVersion"] = mapped;
        }
    }
    dict[@"ProductName"] = @"iPhone OS";
}

extern CFDictionaryRef _CFCopySystemVersionDictionary(void);
static CFDictionaryRef pt_CFCopySystemVersionDictionary(void) {
    CFDictionaryRef orig = _CFCopySystemVersionDictionary();
    if (orig == NULL) {
        return NULL;
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        NSMutableDictionary *dict = [(__bridge NSDictionary *)orig mutableCopy];
        CFRelease(orig);
        pt_sanitize_system_version_dict(dict);
        return (__bridge_retained CFDictionaryRef)[dict copy];
    }
    return orig;
}

static NSMutableDictionary *pt_maybe_sanitize_info_plist_dict(NSDictionary *dict) {
    if (!pt_is_info_plist_dict(dict) || !pt_info_dict_needs_sanitize(dict)) {
        return nil;
    }
    return pt_build_sanitized_mutable_info_dict(dict);
}

static CFPropertyListRef pt_CFPropertyListCreateWithData(CFAllocatorRef allocator, CFDataRef data, CFOptionFlags options, CFPropertyListFormat *format, CFErrorRef *error) {
    CFPropertyListRef plist = CFPropertyListCreateWithData(allocator, data, options, format, error);
    if (plist != NULL && CFGetTypeID(plist) == CFDictionaryGetTypeID()) {
        NSDictionary *dict = (__bridge NSDictionary *)plist;
        BOOL isSysVer = pt_is_system_version_plist_dict(dict);
        BOOL isInfoPlist = (!isSysVer && (dict[@"CFBundleIdentifier"] != nil || dict[@"CFBundleExecutable"] != nil));
        BOOL isCodeRes = (!isSysVer && !isInfoPlist &&
                          ([dict[@"files"] isKindOfClass:[NSDictionary class]] ||
                           [dict[@"files2"] isKindOfClass:[NSDictionary class]] ||
                           [dict[@"rules"] isKindOfClass:[NSDictionary class]] ||
                           [dict[@"rules2"] isKindOfClass:[NSDictionary class]]));
        if ((isSysVer || isCodeRes || isInfoPlist) &&
            pt_is_bypass_enabled() &&
            !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
            BOOL immutable = (options == kCFPropertyListImmutable);
            if (isSysVer) {
                NSMutableDictionary *modified = [dict mutableCopy];
                pt_sanitize_system_version_dict(modified);
                CFRelease(plist);
                return (__bridge_retained CFPropertyListRef)(immutable ? [modified copy] : modified);
            }
            if (isCodeRes) {
                NSMutableDictionary *modified = pt_sanitize_code_resources_dict(dict, !immutable);
                if (modified != nil) {
                    CFRelease(plist);
                    return (__bridge_retained CFPropertyListRef)(immutable ? [modified copy] : modified);
                }
            }
            if (isInfoPlist) {
                NSMutableDictionary *modified = pt_maybe_sanitize_info_plist_dict(dict);
                if (modified != nil) {
                    if (immutable && [modified[@"CFBundleSupportedPlatforms"] isKindOfClass:[NSMutableArray class]]) {
                        modified[@"CFBundleSupportedPlatforms"] = [modified[@"CFBundleSupportedPlatforms"] copy];
                    }
                    CFRelease(plist);
                    return (__bridge_retained CFPropertyListRef)(immutable ? [modified copy] : modified);
                }
            }
        }
    }
    return plist;
}

PT_INTERPOSE_NAMED(pt_kernel_sysctl, pt_orig_kernel_sysctl, "__sysctl")
PT_INTERPOSE_NAMED(pt_kernel_sysctlbyname, pt_orig_kernel_sysctlbyname, "__sysctlbyname")
PT_INTERPOSE(pt_sysctlbyname, sysctlbyname)
PT_INTERPOSE(pt_sysctlnametomib, sysctlnametomib)
PT_INTERPOSE(pt_sysctl, sysctl)
PT_INTERPOSE(pt_CFCopySystemVersionDictionary, _CFCopySystemVersionDictionary)
PT_INTERPOSE(pt_CFPropertyListCreateWithData, CFPropertyListCreateWithData)
