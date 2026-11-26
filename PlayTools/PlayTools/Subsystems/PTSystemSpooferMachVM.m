//
//  PTSystemSpooferMachVM.m
//  PlayTools
//

#import "PTSystemSpooferInternal.h"
#import "PTFSInternal.h"
#import "PTDyldInternal.h"
#import "PTSvcInternal.h"
#include <mach/mach_vm.h>

extern size_t os_proc_available_memory(void);

static uint64_t pt_compute_spoofed_available_memory_with_footprint(uint64_t footprint) {
    uint64_t limit = (pt_get_spoofed_physical_memory() * 65ULL) / 100ULL;
    limit &= ~(16384ULL - 1ULL);
    uint64_t floor_bytes = 128ULL << 20;
    if (limit > footprint + floor_bytes) {
        return (limit - footprint) & ~(16384ULL - 1ULL);
    }
    return floor_bytes;
}

__attribute__((visibility("hidden"))) uint64_t pt_compute_spoofed_available_memory(void) {
    uint64_t limit = ((pt_get_spoofed_physical_memory() * 65ULL) / 100ULL) & ~(16384ULL - 1ULL);
    task_vm_info_data_t vm_info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm_info, &count) == KERN_SUCCESS &&
        count >= TASK_VM_INFO_REV1_COUNT) {
        return pt_compute_spoofed_available_memory_with_footprint((uint64_t)vm_info.phys_footprint);
    }
    return (limit / 2ULL) & ~(16384ULL - 1ULL);
}

static size_t pt_os_proc_available_memory(void) {
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return (size_t)pt_compute_spoofed_available_memory();
    }
    return os_proc_available_memory();
}

#define PT_SHADOW_DYLD_SLAB_COUNT 32
#define PT_SHADOW_DYLD_MIN_CAP 1024U
#define PT_SHADOW_DYLD_RETIRED_CAP 128U

static os_unfair_lock s_shadow_dyld_lock = OS_UNFAIR_LOCK_INIT;
static struct dyld_all_image_infos s_shadow_dyld_infos;
static uint32_t s_shadow_dyld_real_count = 0;
static uintptr_t s_shadow_dyld_real_uuid_count = 0;
static uint64_t s_shadow_dyld_real_ts = 0;
static struct dyld_image_info *s_shadow_dyld_slabs[PT_SHADOW_DYLD_SLAB_COUNT] = {0};
static uint32_t s_shadow_dyld_slab_caps[PT_SHADOW_DYLD_SLAB_COUNT] = {0};
static struct dyld_uuid_info *s_shadow_uuid_slabs[PT_SHADOW_DYLD_SLAB_COUNT] = {0};
static uintptr_t s_shadow_uuid_slab_caps[PT_SHADOW_DYLD_SLAB_COUNT] = {0};
static uint32_t s_shadow_dyld_slab_idx = 0;
static uint32_t s_shadow_dyld_max_count = 0;
static uintptr_t s_shadow_uuid_max_count = 0;
static BOOL s_shadow_dyld_initialized = NO;
static uint64_t s_shadow_dyld_reg_gen = UINT64_MAX;
static void *s_shadow_dyld_retired_bufs[PT_SHADOW_DYLD_RETIRED_CAP] = {0};
static uint32_t s_shadow_dyld_retired_count = 0;
static uint32_t s_shadow_dyld_retired_ring_idx = 0;

static inline void pt_retire_shadow_dyld_buf(void *buf) {
    if (buf == NULL) {
        return;
    }
    if (s_shadow_dyld_retired_count < PT_SHADOW_DYLD_RETIRED_CAP) {
        s_shadow_dyld_retired_bufs[s_shadow_dyld_retired_count++] = buf;
    } else {
        free(s_shadow_dyld_retired_bufs[s_shadow_dyld_retired_ring_idx]);
        s_shadow_dyld_retired_bufs[s_shadow_dyld_retired_ring_idx] = buf;
        s_shadow_dyld_retired_ring_idx =
            (s_shadow_dyld_retired_ring_idx + 1U) % PT_SHADOW_DYLD_RETIRED_CAP;
    }
}

static inline size_t pt_round_up_dyld_cap(size_t needed) {
    size_t cap = PT_SHADOW_DYLD_MIN_CAP;
    while (cap < needed && cap <= (SIZE_MAX / 2U)) {
        cap <<= 1U;
    }
    return (cap < needed) ? needed : cap;
}

static inline natural_t pt_scale_vm_page_count(natural_t count, uint64_t spoof_pages, uint64_t total_pages) {
    uint64_t scaled = ((uint64_t)count * spoof_pages) / total_pages;
    return (scaled > UINT32_MAX) ? UINT32_MAX : (natural_t)scaled;
}

static inline uint64_t pt_scale_vm_page_count64(uint64_t count, uint64_t spoof_pages, uint64_t total_pages) {
    __uint128_t scaled = ((__uint128_t)count * (__uint128_t)spoof_pages) / (__uint128_t)total_pages;
    return (scaled > UINT64_MAX) ? UINT64_MAX : (uint64_t)scaled;
}

__attribute__((visibility("hidden"))) void pt_sanitize_host_basic_info_buf(host_basic_info_data_t *info, size_t out_bytes) {
    if (info == NULL) {
        return;
    }
    const pt_device_profile_t *profile = pt_get_active_device_profile();
    integer_t spoof_cores = (integer_t)profile->cores;
    uint64_t spoof_ram = profile->ram_bytes;
    if (out_bytes >= offsetof(host_basic_info_data_t, max_cpus) + sizeof(info->max_cpus)) {
        info->max_cpus = spoof_cores;
    }
    if (out_bytes >= offsetof(host_basic_info_data_t, avail_cpus) + sizeof(info->avail_cpus)) {
        info->avail_cpus = spoof_cores;
    }
    if (out_bytes >= offsetof(host_basic_info_data_t, memory_size) + sizeof(info->memory_size)) {
        info->memory_size = (natural_t)((spoof_ram > 0x80000000ULL) ? 0x80000000ULL : spoof_ram);
    }
    if (out_bytes >= offsetof(host_basic_info_data_t, cpu_subtype) + sizeof(info->cpu_subtype)) {
        info->cpu_subtype = CPU_SUBTYPE_ARM64_ALL;
    }
    if (out_bytes >= offsetof(host_basic_info_data_t, physical_cpu) + sizeof(info->physical_cpu)) {
        info->physical_cpu = spoof_cores;
    }
    if (out_bytes >= offsetof(host_basic_info_data_t, physical_cpu_max) + sizeof(info->physical_cpu_max)) {
        info->physical_cpu_max = spoof_cores;
    }
    if (out_bytes >= offsetof(host_basic_info_data_t, logical_cpu) + sizeof(info->logical_cpu)) {
        info->logical_cpu = spoof_cores;
    }
    if (out_bytes >= offsetof(host_basic_info_data_t, logical_cpu_max) + sizeof(info->logical_cpu_max)) {
        info->logical_cpu_max = spoof_cores;
    }
    if (out_bytes >= offsetof(host_basic_info_data_t, max_mem) + sizeof(info->max_mem)) {
        info->max_mem = spoof_ram;
    }
}

__attribute__((visibility("hidden"))) void pt_sanitize_host_preferred_user_arch_buf(host_preferred_user_arch_data_t *info, size_t out_bytes) {
    if (info == NULL) {
        return;
    }
    if (out_bytes >= offsetof(host_preferred_user_arch_data_t, cpu_type) + sizeof(info->cpu_type)) {
        info->cpu_type = CPU_TYPE_ARM64;
    }
    if (out_bytes >= offsetof(host_preferred_user_arch_data_t, cpu_subtype) + sizeof(info->cpu_subtype)) {
        info->cpu_subtype = CPU_SUBTYPE_ARM64_ALL;
    }
}

static kern_return_t pt_host_info(host_t host,
                                  host_flavor_t flavor,
                                  host_info_t host_info_out,
                                  mach_msg_type_number_t *host_info_outCnt) {
    kern_return_t kr = host_info(host, flavor, host_info_out, host_info_outCnt);
    if (kr == KERN_SUCCESS &&
        host_info_out != NULL &&
        host_info_outCnt != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        size_t out_bytes = (size_t)(*host_info_outCnt) * sizeof(integer_t);
        if (flavor == HOST_BASIC_INFO) {
            pt_sanitize_host_basic_info_buf((host_basic_info_data_t *)host_info_out, out_bytes);
        } else if (flavor == HOST_PREFERRED_USER_ARCH) {
            pt_sanitize_host_preferred_user_arch_buf((host_preferred_user_arch_data_t *)host_info_out, out_bytes);
        }
    }
    return kr;
}

static kern_return_t pt_host_kernel_version(host_t host, kernel_version_t out_version) {
    kern_return_t kr = host_kernel_version(host, out_version);
    if (kr == KERN_SUCCESS &&
        out_version != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        memset(out_version, 0, sizeof(kernel_version_t));
        pt_format_kernel_version(pt_get_active_device_profile(), out_version, sizeof(kernel_version_t));
    }
    return kr;
}

static kern_return_t pt_host_processor_info(host_t host,
                                            processor_flavor_t flavor,
                                            natural_t *out_processor_count,
                                            processor_info_array_t *out_processor_info,
                                            mach_msg_type_number_t *out_processor_infoCnt) {
    kern_return_t kr = host_processor_info(host, flavor, out_processor_count, out_processor_info, out_processor_infoCnt);
    if (kr == KERN_SUCCESS &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        natural_t spoof_cores = (natural_t)pt_get_active_device_profile()->cores;
        if (out_processor_count != NULL) {
            natural_t real_cores = *out_processor_count;
            if (spoof_cores > 0 && real_cores > spoof_cores) {
                if (out_processor_infoCnt != NULL && real_cores > 0 && (*out_processor_infoCnt % real_cores) == 0) {
                    *out_processor_infoCnt = (*out_processor_infoCnt / real_cores) * spoof_cores;
                }
                *out_processor_count = spoof_cores;
            } else if (spoof_cores > 0 && real_cores > 0 && real_cores < spoof_cores &&
                       out_processor_info != NULL && *out_processor_info != NULL &&
                       out_processor_infoCnt != NULL && (*out_processor_infoCnt % real_cores) == 0) {
                mach_msg_type_number_t per_core = *out_processor_infoCnt / real_cores;
                mach_msg_type_number_t new_cnt = per_core * spoof_cores;
                vm_size_t old_bytes = (vm_size_t)(*out_processor_infoCnt) * sizeof(integer_t);
                vm_size_t new_bytes = (vm_size_t)new_cnt * sizeof(integer_t);
                vm_address_t new_addr = 0;
                if (per_core > 0 &&
                    vm_allocate(mach_task_self(), &new_addr, new_bytes, VM_FLAGS_ANYWHERE) == KERN_SUCCESS) {
                    const integer_t *src = (const integer_t *)(*out_processor_info);
                    integer_t *dst = (integer_t *)new_addr;
                    memcpy(dst, src, old_bytes);
                    for (natural_t i = real_cores; i < spoof_cores; i++) {
                        natural_t src_idx = i % real_cores;
                        memcpy(dst + (size_t)i * per_core,
                               src + (size_t)src_idx * per_core,
                               (size_t)per_core * sizeof(integer_t));
                    }
                    vm_deallocate(mach_task_self(), (vm_address_t)(*out_processor_info), old_bytes);
                    *out_processor_info = (processor_info_array_t)new_addr;
                    *out_processor_infoCnt = new_cnt;
                    *out_processor_count = spoof_cores;
                }
            }
        }
        if (out_processor_info != NULL && *out_processor_info != NULL &&
            out_processor_infoCnt != NULL && *out_processor_infoCnt > 0 && vm_page_size > 0) {
            size_t used_bytes = (size_t)(*out_processor_infoCnt) * sizeof(integer_t);
            size_t page_sz = (size_t)vm_page_size;
            size_t alloc_bytes = ((used_bytes + page_sz - 1U) / page_sz) * page_sz;
            if (alloc_bytes > used_bytes) {
                memset((uint8_t *)(*out_processor_info) + used_bytes, 0, alloc_bytes - used_bytes);
            }
        }
    }
    return kr;
}

__attribute__((visibility("hidden"))) void pt_sanitize_host_vm_info_buf(vm_statistics_data_t *v, size_t out_bytes) {
    if (v == NULL || out_bytes < offsetof(vm_statistics_data_t, wire_count) + sizeof(natural_t)) {
        return;
    }
    uint64_t page_sz = (vm_page_size > 0) ? (uint64_t)vm_page_size : 16384ULL;
    uint64_t spoof_pages = pt_get_active_device_profile()->ram_bytes / page_sz;
    uint64_t total_pages = (uint64_t)v->free_count + (uint64_t)v->active_count +
                           (uint64_t)v->inactive_count + (uint64_t)v->wire_count;
    if (spoof_pages > 0 && total_pages > 0 && total_pages != spoof_pages) {
        v->free_count = pt_scale_vm_page_count(v->free_count, spoof_pages, total_pages);
        v->active_count = pt_scale_vm_page_count(v->active_count, spoof_pages, total_pages);
        v->inactive_count = pt_scale_vm_page_count(v->inactive_count, spoof_pages, total_pages);
        v->wire_count = pt_scale_vm_page_count(v->wire_count, spoof_pages, total_pages);
        if (out_bytes >= offsetof(vm_statistics_data_t, purgeable_count) + sizeof(v->purgeable_count)) {
            v->purgeable_count = pt_scale_vm_page_count(v->purgeable_count, spoof_pages, total_pages);
        }
        if (out_bytes >= offsetof(vm_statistics_data_t, speculative_count) + sizeof(v->speculative_count)) {
            v->speculative_count = pt_scale_vm_page_count(v->speculative_count, spoof_pages, total_pages);
        }
    }
}

__attribute__((visibility("hidden"))) void pt_sanitize_host_vm_info64_buf(vm_statistics64_data_t *v, size_t out_bytes, BOOL clear_swaps) {
    if (v == NULL || out_bytes < offsetof(vm_statistics64_data_t, wire_count) + sizeof(natural_t)) {
        return;
    }
    uint64_t page_sz = (vm_page_size > 0) ? (uint64_t)vm_page_size : 16384ULL;
    uint64_t spoof_pages = pt_get_active_device_profile()->ram_bytes / page_sz;
    uint64_t total_pages = (uint64_t)v->free_count + (uint64_t)v->active_count +
                           (uint64_t)v->inactive_count + (uint64_t)v->wire_count;
    if (spoof_pages > 0 && total_pages > 0 && total_pages != spoof_pages) {
        v->free_count = pt_scale_vm_page_count(v->free_count, spoof_pages, total_pages);
        v->active_count = pt_scale_vm_page_count(v->active_count, spoof_pages, total_pages);
        v->inactive_count = pt_scale_vm_page_count(v->inactive_count, spoof_pages, total_pages);
        v->wire_count = pt_scale_vm_page_count(v->wire_count, spoof_pages, total_pages);
        if (out_bytes >= offsetof(vm_statistics64_data_t, purgeable_count) + sizeof(v->purgeable_count)) {
            v->purgeable_count = pt_scale_vm_page_count(v->purgeable_count, spoof_pages, total_pages);
        }
        if (out_bytes >= offsetof(vm_statistics64_data_t, speculative_count) + sizeof(v->speculative_count)) {
            v->speculative_count = pt_scale_vm_page_count(v->speculative_count, spoof_pages, total_pages);
        }
        if (out_bytes >= offsetof(vm_statistics64_data_t, total_uncompressed_pages_in_compressor) + sizeof(v->total_uncompressed_pages_in_compressor)) {
            v->total_uncompressed_pages_in_compressor = pt_scale_vm_page_count64(v->total_uncompressed_pages_in_compressor, spoof_pages, total_pages);
        }
        if (out_bytes >= offsetof(vm_statistics64_data_t, compressor_page_count) + sizeof(v->compressor_page_count)) {
            v->compressor_page_count = pt_scale_vm_page_count(v->compressor_page_count, spoof_pages, total_pages);
        }
        if (out_bytes >= offsetof(vm_statistics64_data_t, throttled_count) + sizeof(v->throttled_count)) {
            v->throttled_count = pt_scale_vm_page_count(v->throttled_count, spoof_pages, total_pages);
        }
        if (out_bytes >= offsetof(vm_statistics64_data_t, external_page_count) + sizeof(v->external_page_count)) {
            v->external_page_count = pt_scale_vm_page_count(v->external_page_count, spoof_pages, total_pages);
        }
        if (out_bytes >= offsetof(vm_statistics64_data_t, internal_page_count) + sizeof(v->internal_page_count)) {
            v->internal_page_count = pt_scale_vm_page_count(v->internal_page_count, spoof_pages, total_pages);
        }
    }
    if (spoof_pages > 0 && out_bytes >= offsetof(vm_statistics64_data_t, max_mem_count) + sizeof(v->max_mem_count)) {
        v->max_mem_count = spoof_pages;
    }
    if (clear_swaps) {
        if (out_bytes >= offsetof(vm_statistics64_data_t, swapins) + sizeof(v->swapins)) {
            v->swapins = 0;
        }
        if (out_bytes >= offsetof(vm_statistics64_data_t, swapouts) + sizeof(v->swapouts)) {
            v->swapouts = 0;
        }
        if (out_bytes >= offsetof(vm_statistics64_data_t, swapped_count) + sizeof(v->swapped_count)) {
            v->swapped_count = 0;
        }
        if (out_bytes >= offsetof(vm_statistics64_data_t, swap_count) + sizeof(v->swap_count)) {
            v->swap_count = 0;
        }
    }
}

static kern_return_t pt_host_statistics(host_t host,
                                        host_flavor_t flavor,
                                        host_info_t host_info_out,
                                        mach_msg_type_number_t *host_info_outCnt) {
    kern_return_t kr = host_statistics(host, flavor, host_info_out, host_info_outCnt);
    if (kr == KERN_SUCCESS &&
        flavor == HOST_VM_INFO &&
        host_info_out != NULL &&
        host_info_outCnt != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        size_t out_bytes = (size_t)(*host_info_outCnt) * sizeof(integer_t);
        pt_sanitize_host_vm_info_buf((vm_statistics_data_t *)host_info_out, out_bytes);
    }
    return kr;
}

static kern_return_t pt_host_statistics64(host_t host,
                                          host_flavor_t flavor,
                                          host_info64_t host_info64_out,
                                          mach_msg_type_number_t *host_info64_outCnt) {
    kern_return_t kr = host_statistics64(host, flavor, host_info64_out, host_info64_outCnt);
    if (kr == KERN_SUCCESS &&
        (flavor == HOST_VM_INFO64 || flavor == HOST_VM_INFO) &&
        host_info64_out != NULL &&
        host_info64_outCnt != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        size_t out_bytes = (size_t)(*host_info64_outCnt) * sizeof(integer_t);
        pt_sanitize_host_vm_info64_buf((vm_statistics64_data_t *)host_info64_out, out_bytes, flavor == HOST_VM_INFO64);
    }
    return kr;
}

__attribute__((visibility("hidden"))) void pt_sanitize_task_vm_info_buf(task_vm_info_data_t *vm, size_t out_bytes) {
    if (vm == NULL) {
        return;
    }
    size_t min_bytes = offsetof(task_vm_info_data_t, limit_bytes_remaining) +
                       sizeof(vm->limit_bytes_remaining);
    if (out_bytes >= min_bytes) {
        vm->limit_bytes_remaining = (mach_vm_size_t)pt_compute_spoofed_available_memory_with_footprint(
            (uint64_t)vm->phys_footprint);
    }
    if (out_bytes >= offsetof(task_vm_info_data_t, ledger_swapins) + sizeof(vm->ledger_swapins)) {
        vm->ledger_swapins = 0;
    }
}

__attribute__((visibility("hidden"))) void pt_sanitize_task_audit_token_buf(audit_token_t *tok, size_t out_bytes) {
    if (tok != NULL && out_bytes >= sizeof(audit_token_t)) {
        if (tok->val[2] == 20U) {
            tok->val[2] = 501U;
        }
        if (tok->val[4] == 20U) {
            tok->val[4] = 501U;
        }
    }
}

__attribute__((visibility("hidden"))) void pt_sanitize_task_security_token_buf(security_token_t *tok, size_t out_bytes) {
    if (tok != NULL && out_bytes >= sizeof(security_token_t)) {
        if (tok->val[1] == 20U) {
            tok->val[1] = 501U;
        }
    }
}

__attribute__((visibility("hidden"))) void pt_sanitize_task_dyld_info_buf(task_dyld_info_data_t *dyld_info, size_t out_bytes) {
    if (dyld_info == NULL || out_bytes < sizeof(task_dyld_info_data_t)) {
        return;
    }
    if (dyld_info->all_image_info_addr != 0 &&
        (dyld_info->all_image_info_format == TASK_DYLD_ALL_IMAGE_INFO_64 ||
         dyld_info->all_image_info_format == TASK_DYLD_ALL_IMAGE_INFO_32)) {
        const struct dyld_all_image_infos *real_infos =
            (const struct dyld_all_image_infos *)(uintptr_t)dyld_info->all_image_info_addr;
        os_unfair_lock_lock(&s_shadow_dyld_lock);
            uint32_t cur_real_count = __atomic_load_n(&real_infos->infoArrayCount, __ATOMIC_ACQUIRE);
            uint64_t cur_real_ts = __atomic_load_n(&real_infos->infoArrayChangeTimestamp, __ATOMIC_ACQUIRE);
            const struct dyld_image_info *cur_real_arr = __atomic_load_n(&real_infos->infoArray, __ATOMIC_ACQUIRE);
            uintptr_t cur_uuid_cnt = __atomic_load_n(&real_infos->uuidArrayCount, __ATOMIC_ACQUIRE);
            uint64_t cur_reg_gen = pt_hidden_registry_generation();
            if (cur_real_arr != NULL &&
                (!s_shadow_dyld_initialized ||
                 s_shadow_dyld_infos.infoArray == NULL ||
                 s_shadow_dyld_reg_gen != cur_reg_gen ||
                 s_shadow_dyld_real_count != cur_real_count ||
                 s_shadow_dyld_real_uuid_count != cur_uuid_cnt ||
                 s_shadow_dyld_real_ts != cur_real_ts)) {
                uint32_t next_slot = (s_shadow_dyld_slab_idx + 1U) & (PT_SHADOW_DYLD_SLAB_COUNT - 1U);
                for (int attempt = 0; attempt < 4; attempt++) {
                    uint64_t ts_before = __atomic_load_n(&real_infos->infoArrayChangeTimestamp, __ATOMIC_ACQUIRE);
                    uint32_t real_count = __atomic_load_n(&real_infos->infoArrayCount, __ATOMIC_ACQUIRE);
                    const struct dyld_image_info *real_arr = __atomic_load_n(&real_infos->infoArray, __ATOMIC_ACQUIRE);
                    uintptr_t real_uuid_cnt = __atomic_load_n(&real_infos->uuidArrayCount, __ATOMIC_ACQUIRE);
                    const struct dyld_uuid_info *real_uuid_arr = __atomic_load_n(&real_infos->uuidArray, __ATOMIC_ACQUIRE);
                    if (real_arr == NULL) {
                        break;
                    }

                    uint32_t min_needed = (real_count > s_shadow_dyld_max_count) ? real_count : s_shadow_dyld_max_count;
                    if (min_needed == 0U) {
                        min_needed = 1U;
                    }
                    size_t rounded_cap = pt_round_up_dyld_cap((size_t)min_needed);
                    uint32_t needed_cap = (rounded_cap > (size_t)UINT32_MAX) ? min_needed : (uint32_t)rounded_cap;
                    struct dyld_image_info *filtered = s_shadow_dyld_slabs[next_slot];
                    uint32_t slab_cap = s_shadow_dyld_slab_caps[next_slot];
                    if (filtered == NULL || slab_cap < needed_cap) {
                        struct dyld_image_info *grown =
                            (struct dyld_image_info *)calloc(needed_cap, sizeof(struct dyld_image_info));
                        if (grown == NULL) {
                            break;
                        }
                        pt_retire_shadow_dyld_buf(filtered);
                        filtered = grown;
                        slab_cap = needed_cap;
                        s_shadow_dyld_slabs[next_slot] = filtered;
                        s_shadow_dyld_slab_caps[next_slot] = slab_cap;
                    }

                    uintptr_t min_uuid_needed =
                        (real_uuid_cnt > s_shadow_uuid_max_count) ? real_uuid_cnt : s_shadow_uuid_max_count;
                    if (min_uuid_needed == 0U) {
                        min_uuid_needed = 1U;
                    }
                    size_t rounded_uuid_cap = pt_round_up_dyld_cap((size_t)min_uuid_needed);
                    uintptr_t needed_uuid_cap =
                        (rounded_uuid_cap < (size_t)min_uuid_needed) ? min_uuid_needed : (uintptr_t)rounded_uuid_cap;
                    struct dyld_uuid_info *filtered_uuids = s_shadow_uuid_slabs[next_slot];
                    uintptr_t uuid_slab_cap = s_shadow_uuid_slab_caps[next_slot];
                    if (filtered_uuids == NULL || uuid_slab_cap < needed_uuid_cap) {
                        struct dyld_uuid_info *grown_uuids =
                            (struct dyld_uuid_info *)calloc(needed_uuid_cap, sizeof(struct dyld_uuid_info));
                        if (grown_uuids == NULL) {
                            break;
                        }
                        pt_retire_shadow_dyld_buf(filtered_uuids);
                        filtered_uuids = grown_uuids;
                        uuid_slab_cap = needed_uuid_cap;
                        s_shadow_uuid_slabs[next_slot] = filtered_uuids;
                        s_shadow_uuid_slab_caps[next_slot] = uuid_slab_cap;
                    }

                    const struct mach_header *hidden_mhs[128];
                    size_t hidden_mh_count = 0;
                    uint32_t write_idx = 0;
                    for (uint32_t i = 0; i < real_count; i++) {
                        const char *img_path = real_arr[i].imageFilePath;
                        if (pt_should_hide_dyld_image(img_path) ||
                            pt_is_hidden_dyld_image_header(real_arr[i].imageLoadAddress)) {
                            if (real_arr[i].imageLoadAddress != NULL &&
                                hidden_mh_count < sizeof(hidden_mhs) / sizeof(hidden_mhs[0])) {
                                hidden_mhs[hidden_mh_count++] = real_arr[i].imageLoadAddress;
                            }
                            continue;
                        }
                        filtered[write_idx] = real_arr[i];
                        if (img_path != NULL) {
                            filtered[write_idx].imageFilePath = pt_sanitize_image_path_for_app(img_path);
                        }
                        write_idx++;
                    }
                    if (write_idx < slab_cap) {
                        memset(&filtered[write_idx], 0, (size_t)(slab_cap - write_idx) * sizeof(struct dyld_image_info));
                    }

                    uintptr_t uuid_write_idx = 0;
                    if (real_uuid_arr != NULL && real_uuid_cnt > 0) {
                        for (uintptr_t j = 0; j < real_uuid_cnt; j++) {
                            const struct mach_header *umh = real_uuid_arr[j].imageLoadAddress;
                            BOOL hide_uuid = NO;
                            for (size_t k = 0; k < hidden_mh_count; k++) {
                                if (hidden_mhs[k] == umh) {
                                    hide_uuid = YES;
                                    break;
                                }
                            }
                            if (!hide_uuid && umh != NULL) {
                                const char *upath = dyld_image_path_containing_address((const void *)umh);
                                if (upath != NULL && pt_should_hide_dyld_image(upath)) {
                                    hide_uuid = YES;
                                }
                            }
                            if (!hide_uuid) {
                                filtered_uuids[uuid_write_idx++] = real_uuid_arr[j];
                            }
                        }
                    }
                    if (uuid_write_idx < uuid_slab_cap) {
                        memset(&filtered_uuids[uuid_write_idx], 0,
                               (size_t)(uuid_slab_cap - uuid_write_idx) * sizeof(struct dyld_uuid_info));
                    }

                    uint64_t ts_after = __atomic_load_n(&real_infos->infoArrayChangeTimestamp, __ATOMIC_ACQUIRE);
                    if (ts_after != ts_before ||
                        __atomic_load_n(&real_infos->infoArrayCount, __ATOMIC_ACQUIRE) != real_count ||
                        __atomic_load_n(&real_infos->uuidArrayCount, __ATOMIC_ACQUIRE) != real_uuid_cnt) {
                        continue;
                    }

                    s_shadow_dyld_slab_idx = next_slot;
                    if (real_count > s_shadow_dyld_max_count) {
                        s_shadow_dyld_max_count = real_count;
                    }
                    if (real_uuid_cnt > s_shadow_uuid_max_count) {
                        s_shadow_uuid_max_count = real_uuid_cnt;
                    }

                    if (!s_shadow_dyld_initialized) {
                        struct dyld_all_image_infos tmp_infos;
                        memset(&tmp_infos, 0, sizeof(tmp_infos));
                        size_t copy_bytes = sizeof(tmp_infos);
                        if (dyld_info->all_image_info_size > 0 && (size_t)dyld_info->all_image_info_size < copy_bytes) {
                            copy_bytes = (size_t)dyld_info->all_image_info_size;
                        }
                        memcpy(&tmp_infos, real_infos, copy_bytes);
                        tmp_infos.infoArrayCount = write_idx;
                        tmp_infos.infoArray = filtered;
                        tmp_infos.uuidArrayCount = uuid_write_idx;
                        tmp_infos.uuidArray = (uuid_write_idx > 0) ? filtered_uuids : NULL;
                        tmp_infos.dyldAllImageInfosAddress = &s_shadow_dyld_infos;
                        if (tmp_infos.initialImageCount > write_idx) {
                            tmp_infos.initialImageCount = write_idx;
                        }
                        if (tmp_infos.dyldPath != NULL) {
                            tmp_infos.dyldPath = "/usr/lib/dyld";
                        }
                        if (tmp_infos.version >= 16) {
                            tmp_infos.platform = PLATFORM_IOS;
                        }
                        if (pt_is_compat13_7_active()) {
                            tmp_infos.version = 16;
                            tmp_infos.dyldVersion = "750.6";
                        }
                        tmp_infos.errorMessage = NULL;
                        tmp_infos.errorKind = 0;
                        tmp_infos.errorClientOfDylibPath = NULL;
                        tmp_infos.errorTargetDylibPath = NULL;
                        tmp_infos.errorSymbol = NULL;
                        tmp_infos.compact_dyld_image_info_addr = 0;
                        tmp_infos.compact_dyld_image_info_size = 0;
                        tmp_infos.aotInfoCount = 0;
                        tmp_infos.aotInfoArray = NULL;
                        tmp_infos.aotInfoArrayChangeTimestamp = 0;
                        tmp_infos.aotSharedCacheBaseAddress = 0;
                        memset(tmp_infos.aotSharedCacheUUID, 0, sizeof(tmp_infos.aotSharedCacheUUID));
                        tmp_infos.infoArrayChangeTimestamp = ts_after;
                        atomic_thread_fence(memory_order_release);
                        memcpy(&s_shadow_dyld_infos, &tmp_infos, sizeof(s_shadow_dyld_infos));
                        atomic_thread_fence(memory_order_release);
                        s_shadow_dyld_initialized = YES;
                    } else {
                        atomic_thread_fence(memory_order_release);
                        if (write_idx < s_shadow_dyld_infos.infoArrayCount) {
                            __atomic_store_n(&s_shadow_dyld_infos.infoArrayCount, write_idx, __ATOMIC_RELEASE);
                            atomic_thread_fence(memory_order_release);
                        }
                        __atomic_store_n(&s_shadow_dyld_infos.infoArray, filtered, __ATOMIC_RELEASE);
                        atomic_thread_fence(memory_order_release);
                        __atomic_store_n(&s_shadow_dyld_infos.infoArrayCount, write_idx, __ATOMIC_RELEASE);

                        if (uuid_write_idx < s_shadow_dyld_infos.uuidArrayCount) {
                            __atomic_store_n(&s_shadow_dyld_infos.uuidArrayCount, uuid_write_idx, __ATOMIC_RELEASE);
                            atomic_thread_fence(memory_order_release);
                        }
                        __atomic_store_n(&s_shadow_dyld_infos.uuidArray,
                                         (uuid_write_idx > 0) ? filtered_uuids : NULL,
                                         __ATOMIC_RELEASE);
                        atomic_thread_fence(memory_order_release);
                        __atomic_store_n(&s_shadow_dyld_infos.uuidArrayCount, uuid_write_idx, __ATOMIC_RELEASE);

                        uintptr_t real_init = real_infos->initialImageCount;
                        uintptr_t clamped_init = (real_init > write_idx) ? (uintptr_t)write_idx : real_init;
                        __atomic_store_n(&s_shadow_dyld_infos.initialImageCount, clamped_init, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.compact_dyld_image_info_addr, (uintptr_t)0, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.compact_dyld_image_info_size, (size_t)0, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.aotInfoCount, (uint32_t)0, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.aotInfoArray, (const struct dyld_aot_image_info *)NULL, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.aotInfoArrayChangeTimestamp, (uint64_t)0, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.aotSharedCacheBaseAddress, (uintptr_t)0, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.errorMessage, (const char *)NULL, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.errorKind, (uintptr_t)0, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.errorClientOfDylibPath, (const char *)NULL, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.errorTargetDylibPath, (const char *)NULL, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.errorSymbol, (const char *)NULL, __ATOMIC_RELEASE);
                        __atomic_store_n(&s_shadow_dyld_infos.infoArrayChangeTimestamp, ts_after, __ATOMIC_RELEASE);
                        if (pt_is_compat13_7_active()) {
                            __atomic_store_n(&s_shadow_dyld_infos.version, (uint32_t)16, __ATOMIC_RELEASE);
                            __atomic_store_n(&s_shadow_dyld_infos.dyldVersion, (const char *)"750.6", __ATOMIC_RELEASE);
                        }
                    }
                    s_shadow_dyld_reg_gen = cur_reg_gen;
                    s_shadow_dyld_real_count = real_count;
                    s_shadow_dyld_real_uuid_count = real_uuid_cnt;
                    s_shadow_dyld_real_ts = ts_after;
                    break;
                }
            }
            if (s_shadow_dyld_initialized && s_shadow_dyld_infos.infoArray != NULL) {
                dyld_info->all_image_info_addr = (mach_vm_address_t)(uintptr_t)&s_shadow_dyld_infos;
                dyld_info->all_image_info_size = sizeof(s_shadow_dyld_infos);
            }
            os_unfair_lock_unlock(&s_shadow_dyld_lock);
    }
}

static _Thread_local int s_tls_force_task_dyld_sanitize = 0;

__attribute__((visibility("hidden")))
void pt_dyld_set_force_task_dyld_sanitize(BOOL active) {
    if (active) {
        s_tls_force_task_dyld_sanitize++;
    } else if (s_tls_force_task_dyld_sanitize > 0) {
        s_tls_force_task_dyld_sanitize--;
    }
}

__attribute__((visibility("hidden")))
BOOL pt_dyld_is_force_task_dyld_sanitize(void) {
    return (s_tls_force_task_dyld_sanitize > 0);
}

static kern_return_t pt_task_info(task_name_t target_task,
                                  task_flavor_t flavor,
                                  task_info_t task_info_out,
                                  mach_msg_type_number_t *task_info_outCnt) {
    kern_return_t kr = task_info(target_task, flavor, task_info_out, task_info_outCnt);
    BOOL force_dyld = (flavor == TASK_DYLD_INFO && pt_dyld_is_force_task_dyld_sanitize());
    if (kr != KERN_SUCCESS ||
        target_task != mach_task_self() ||
        task_info_out == NULL ||
        task_info_outCnt == NULL ||
        !pt_is_bypass_enabled() ||
        (!force_dyld && pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)))) {
        return kr;
    }

    size_t out_bytes = (size_t)(*task_info_outCnt) * sizeof(natural_t);
    if (flavor == TASK_VM_INFO || flavor == TASK_VM_INFO_PURGEABLE) {
        pt_sanitize_task_vm_info_buf((task_vm_info_data_t *)task_info_out, out_bytes);
    } else if (flavor == TASK_AUDIT_TOKEN) {
        pt_sanitize_task_audit_token_buf((audit_token_t *)task_info_out, out_bytes);
    } else if (flavor == TASK_SECURITY_TOKEN) {
        pt_sanitize_task_security_token_buf((security_token_t *)task_info_out, out_bytes);
    } else if (flavor == TASK_DYLD_INFO) {
        pt_sanitize_task_dyld_info_buf((task_dyld_info_data_t *)task_info_out, out_bytes);
    }
    return kr;
}

extern kern_return_t pt_orig_vm_region_64(
    vm_map_read_t target_task,
    vm_address_t *address,
    vm_size_t *size,
    vm_region_flavor_t flavor,
    vm_region_info_t info,
    mach_msg_type_number_t *infoCnt,
    mach_port_t *object_name) __asm("_vm_region_64");

extern kern_return_t pt_orig_vm_region_recurse_64(
    vm_map_read_t target_task,
    vm_address_t *address,
    vm_size_t *size,
    natural_t *nesting_depth,
    vm_region_recurse_info_t info,
    mach_msg_type_number_t *infoCnt) __asm("_vm_region_recurse_64");

extern kern_return_t pt_orig_mach_vm_region(
    vm_map_read_t target_task,
    mach_vm_address_t *address,
    mach_vm_size_t *size,
    vm_region_flavor_t flavor,
    vm_region_info_t info,
    mach_msg_type_number_t *infoCnt,
    mach_port_t *object_name) __asm("_mach_vm_region");

extern kern_return_t pt_orig_mach_vm_region_recurse(
    vm_map_read_t target_task,
    mach_vm_address_t *address,
    mach_vm_size_t *size,
    natural_t *nesting_depth,
    vm_region_recurse_info_t info,
    mach_msg_type_number_t *infoCnt) __asm("_mach_vm_region_recurse");

extern kern_return_t pt_orig_vm_read_overwrite(
    vm_map_read_t target_task,
    vm_address_t address,
    vm_size_t size,
    vm_address_t data,
    vm_size_t *outsize) __asm("_vm_read_overwrite");

extern kern_return_t pt_orig_mach_vm_read_overwrite(
    vm_map_read_t target_task,
    mach_vm_address_t address,
    mach_vm_size_t size,
    mach_vm_address_t data,
    mach_vm_size_t *outsize) __asm("_mach_vm_read_overwrite");

extern kern_return_t pt_orig_vm_read(
    vm_map_read_t target_task,
    vm_address_t address,
    vm_size_t size,
    vm_offset_t *data,
    mach_msg_type_number_t *dataCnt) __asm("_vm_read");

extern kern_return_t pt_orig_mach_vm_read(
    vm_map_read_t target_task,
    mach_vm_address_t address,
    mach_vm_size_t size,
    vm_offset_t *data,
    mach_msg_type_number_t *dataCnt) __asm("_mach_vm_read");

extern kern_return_t pt_orig_vm_copy(
    vm_map_t target_task,
    vm_address_t source_address,
    vm_size_t size,
    vm_address_t dest_address) __asm("_vm_copy");

extern kern_return_t pt_orig_mach_vm_copy(
    vm_map_t target_task,
    mach_vm_address_t source_address,
    mach_vm_size_t size,
    mach_vm_address_t dest_address) __asm("_mach_vm_copy");

extern kern_return_t pt_orig_vm_read_list(
    vm_map_read_t target_task,
    vm_read_entry_t data_list,
    natural_t count) __asm("_vm_read_list");

extern kern_return_t pt_orig_mach_vm_read_list(
    vm_map_read_t target_task,
    mach_vm_read_entry_t data_list,
    natural_t count) __asm("_mach_vm_read_list");

static vm_prot_t pt_extract_vm_region_prot(vm_region_flavor_t flavor,
                                           const void *info,
                                           mach_msg_type_number_t infoCnt,
                                           BOOL is_recurse) {
    if (info == NULL) {
        return 0;
    }
    if (is_recurse) {
        if (infoCnt >= VM_REGION_SUBMAP_SHORT_INFO_COUNT_64) {
            return ((const vm_region_submap_short_info_data_64_t *)info)->protection;
        }
        return 0;
    }
    switch (flavor) {
        case VM_REGION_BASIC_INFO_64:
            if (infoCnt >= VM_REGION_BASIC_INFO_COUNT_64) {
                return ((const vm_region_basic_info_data_64_t *)info)->protection;
            }
            return 0;
        case VM_REGION_BASIC_INFO:
            if (infoCnt >= VM_REGION_BASIC_INFO_COUNT) {
                return ((const vm_region_basic_info_data_t *)info)->protection;
            }
            return 0;
        case VM_REGION_EXTENDED_INFO:
            if (infoCnt >= VM_REGION_EXTENDED_INFO_COUNT) {
                return ((const vm_region_extended_info_data_t *)info)->protection;
            }
            return 0;
        default:
            return 0;
    }
}

#define PT_CPU_TYPE_APPLE_GPU ((cpu_type_t)0x01000013)

static inline BOOL pt_is_sanitizable_macho_cputype(cpu_type_t ct) {
    return (ct == CPU_TYPE_ARM64 || ct == PT_CPU_TYPE_APPLE_GPU);
}

__attribute__((visibility("hidden")))
BOOL pt_is_hidden_unregistered_macho_region(uintptr_t addr, uintptr_t size, vm_prot_t prot) {
    if ((prot & (VM_PROT_READ | VM_PROT_EXECUTE)) != (VM_PROT_READ | VM_PROT_EXECUTE) ||
        addr == 0 ||
        size < sizeof(struct mach_header_64)) {
        return NO;
    }
    if (dyld_image_header_containing_address((const void *)addr) != NULL) {
        return NO;
    }
    struct mach_header_64 hdr;
    memset(&hdr, 0, sizeof(hdr));
    mach_vm_size_t out_sz = 0;
    kern_return_t kr = pt_orig_mach_vm_read_overwrite(
        mach_task_self(),
        (mach_vm_address_t)addr,
        sizeof(hdr),
        (mach_vm_address_t)(uintptr_t)&hdr,
        &out_sz);
    if (kr != KERN_SUCCESS || out_sz != sizeof(hdr)) {
        return NO;
    }
    return (hdr.magic == MH_MAGIC_64 &&
            hdr.cputype == CPU_TYPE_ARM64 &&
            hdr.sizeofcmds > 0 &&
            hdr.sizeofcmds <= (1U << 20) &&
            (hdr.filetype == MH_DYLIB || hdr.filetype == MH_BUNDLE || hdr.filetype == MH_DYLINKER));
}

__attribute__((visibility("hidden"))) void pt_sanitize_vm_read_buffer(uintptr_t read_start, uint8_t *dst, size_t copied) {
    if (dst == NULL || copied == 0 || read_start > UINTPTR_MAX - copied) {
        return;
    }
    pt_svc_restore_patched_bytes_in_buffer(read_start, dst, copied);
    pt_dyld_sanitize_got_ptrs_in_vm_read_buffer(read_start, dst, copied);
    uintptr_t read_end = read_start + copied;
    const struct mach_header *mh = dyld_image_header_containing_address((const void *)read_start);
    if (mh == NULL && copied > sizeof(struct mach_header_64)) {
        uintptr_t next_page = (read_start + (uintptr_t)0x3FFFU) & ~(uintptr_t)0x3FFFU;
        if (next_page > read_start && next_page < read_end) {
            mh = dyld_image_header_containing_address((const void *)next_page);
        }
    }
    const struct mach_header_64 *mh64 = NULL;
    uintptr_t mh_base = 0;
    size_t real_hdr_total = 0;

    if (mh != NULL && pt_is_valid_user_pointer((const void *)mh)) {
        mh64 = (const struct mach_header_64 *)mh;
        if (mh64->magic != MH_MAGIC_64 ||
            mh64->sizeofcmds == 0 ||
            mh64->sizeofcmds > (1U << 20)) {
            return;
        }
        mh_base = (uintptr_t)mh64;
        real_hdr_total = sizeof(struct mach_header_64) + (size_t)mh64->sizeofcmds;
        if (mh_base > UINTPTR_MAX - real_hdr_total) {
            return;
        }
    } else {
        struct mach_header_64 hdr_copy;
        memset(&hdr_copy, 0, sizeof(hdr_copy));
        uintptr_t cand_base = 0;
        if (copied >= sizeof(struct mach_header_64)) {
            memcpy(&hdr_copy, dst, sizeof(hdr_copy));
            if (hdr_copy.magic == MH_MAGIC_64 &&
                pt_is_sanitizable_macho_cputype(hdr_copy.cputype) &&
                hdr_copy.ncmds > 0 &&
                hdr_copy.ncmds <= 4096U &&
                hdr_copy.sizeofcmds > 0 &&
                hdr_copy.sizeofcmds <= (1U << 20)) {
                cand_base = read_start;
            }
        }
        if (cand_base == 0 && copied > sizeof(struct mach_header_64)) {
            uintptr_t next_page = (read_start + (uintptr_t)0x3FFFU) & ~(uintptr_t)0x3FFFU;
            if (next_page > read_start && next_page + sizeof(struct mach_header_64) <= read_end) {
                memcpy(&hdr_copy, dst + (next_page - read_start), sizeof(hdr_copy));
                if (hdr_copy.magic == MH_MAGIC_64 &&
                    pt_is_sanitizable_macho_cputype(hdr_copy.cputype) &&
                    hdr_copy.ncmds > 0 &&
                    hdr_copy.ncmds <= 4096U &&
                    hdr_copy.sizeofcmds > 0 &&
                    hdr_copy.sizeofcmds <= (1U << 20)) {
                    cand_base = next_page;
                }
            }
        }
        if (cand_base == 0) {
            uintptr_t cur_page = read_start & ~(uintptr_t)0x3FFFU;
            for (int p = 0; p < 4; p++) {
                if (p > 0) {
                    if (cur_page < (uintptr_t)0x4000U) {
                        break;
                    }
                    cur_page -= (uintptr_t)0x4000U;
                }
                if (cur_page == read_start && copied >= sizeof(struct mach_header_64)) {
                    continue;
                }
                if (read_start < cur_page || (read_start - cur_page) > 65536U) {
                    break;
                }
                mach_vm_size_t hdr_out = 0;
                kern_return_t hkr = pt_orig_mach_vm_read_overwrite(
                    mach_task_self(),
                    (mach_vm_address_t)cur_page,
                    sizeof(hdr_copy),
                    (mach_vm_address_t)(uintptr_t)&hdr_copy,
                    &hdr_out);
                if (hkr == KERN_SUCCESS &&
                    hdr_out == sizeof(hdr_copy) &&
                    hdr_copy.magic == MH_MAGIC_64 &&
                    pt_is_sanitizable_macho_cputype(hdr_copy.cputype) &&
                    hdr_copy.ncmds > 0 &&
                    hdr_copy.ncmds <= 4096U &&
                    hdr_copy.sizeofcmds > 0 &&
                    hdr_copy.sizeofcmds <= (1U << 20)) {
                    size_t cand_total = sizeof(struct mach_header_64) + (size_t)hdr_copy.sizeofcmds;
                    if (cur_page <= UINTPTR_MAX - cand_total && read_start < cur_page + cand_total) {
                        cand_base = cur_page;
                        break;
                    }
                }
            }
        }
        if (cand_base == 0) {
            return;
        }
        real_hdr_total = sizeof(struct mach_header_64) + (size_t)hdr_copy.sizeofcmds;
        if (cand_base > UINTPTR_MAX - real_hdr_total) {
            return;
        }
        uintptr_t cand_end = cand_base + real_hdr_total;
        uintptr_t ov_start = (read_start > cand_base) ? read_start : cand_base;
        uintptr_t ov_end = (read_end < cand_end) ? read_end : cand_end;
        if (ov_start >= ov_end) {
            return;
        }
        uint8_t *raw_hdr = (uint8_t *)malloc(real_hdr_total);
        uint8_t *san_hdr = (uint8_t *)malloc(real_hdr_total);
        if (raw_hdr != NULL && san_hdr != NULL) {
            const uint8_t *src_ptr = NULL;
            if (cand_base >= read_start && cand_end <= read_end) {
                src_ptr = dst + (cand_base - read_start);
            } else {
                mach_vm_size_t full_out = 0;
                kern_return_t fkr = pt_orig_mach_vm_read_overwrite(
                    mach_task_self(),
                    (mach_vm_address_t)cand_base,
                    (mach_vm_size_t)real_hdr_total,
                    (mach_vm_address_t)(uintptr_t)raw_hdr,
                    &full_out);
                if (fkr == KERN_SUCCESS && full_out == real_hdr_total) {
                    src_ptr = raw_hdr;
                }
            }
            if (src_ptr != NULL &&
                pt_build_sanitized_mach_header_copy((const struct mach_header_64 *)src_ptr,
                                                    san_hdr,
                                                    real_hdr_total,
                                                    NULL)) {
                size_t dst_off = (size_t)(ov_start - read_start);
                size_t rel_off = (size_t)(ov_start - cand_base);
                size_t ov_len = (size_t)(ov_end - ov_start);
                memcpy(dst + dst_off, san_hdr + rel_off, ov_len);
            }
        }
        free(raw_hdr);
        free(san_hdr);
        return;
    }

    uintptr_t mh_end = mh_base + real_hdr_total;
    uintptr_t ov_start = (read_start > mh_base) ? read_start : mh_base;
    uintptr_t ov_end = (read_end < mh_end) ? read_end : mh_end;
    if (ov_start < ov_end) {
        size_t dst_off = (size_t)(ov_start - read_start);
        size_t rel_off = (size_t)(ov_start - mh_base);
        size_t ov_len = (size_t)(ov_end - ov_start);
        BOOL handled_hdr = NO;

        if (mh == pt_get_main_executable_header()) {
            size_t backup_len = 0;
            const uint8_t *backup_hdr = pt_get_cached_backup_main_mach_header(&backup_len);
            if (backup_hdr != NULL && backup_len >= sizeof(struct mach_header_64)) {
                const uint8_t *copy_src = backup_hdr;
                size_t copy_total = backup_len;
                uint8_t stack_bkp[16384];
                uint8_t *heap_bkp = NULL;
                if (pt_get_compat_version_clamp() != 0) {
                    uint8_t *work_bkp = (backup_len <= sizeof(stack_bkp)) ? stack_bkp : (heap_bkp = (uint8_t *)malloc(backup_len));
                    if (work_bkp != NULL &&
                        pt_build_sanitized_mach_header_copy((const struct mach_header_64 *)backup_hdr,
                                                            work_bkp, backup_len, NULL)) {
                        copy_src = work_bkp;
                    }
                }
                if (rel_off < copy_total) {
                    size_t copy_len = ov_len;
                    if (copy_len > copy_total - rel_off) {
                        copy_len = copy_total - rel_off;
                    }
                    memcpy(dst + dst_off, copy_src + rel_off, copy_len);
                    if (copy_len < ov_len) {
                        memset(dst + dst_off + copy_len, 0, ov_len - copy_len);
                    }
                } else {
                    memset(dst + dst_off, 0, ov_len);
                }
                free(heap_bkp);
                handled_hdr = YES;
            }
        }

        if (!handled_hdr) {
            uint8_t stack_buf[16384];
            uint8_t *heap_buf = NULL;
            uint8_t *work_buf = stack_buf;
            if (real_hdr_total > sizeof(stack_buf)) {
                heap_buf = (uint8_t *)malloc(real_hdr_total);
                work_buf = heap_buf;
            }
            if (work_buf != NULL &&
                pt_build_sanitized_mach_header_copy(mh64, work_buf, real_hdr_total, NULL)) {
                memcpy(dst + dst_off, work_buf + rel_off, ov_len);
            }
            free(heap_buf);
        }
    }
}

static kern_return_t pt_vm_read_overwrite(vm_map_read_t target_task,
                                          vm_address_t address,
                                          vm_size_t size,
                                          vm_address_t data,
                                          vm_size_t *outsize) {
    kern_return_t kr = pt_orig_vm_read_overwrite(target_task, address, size, data, outsize);
    if (kr == KERN_SUCCESS &&
        outsize != NULL &&
        *outsize > 0 &&
        data != 0 &&
        target_task == mach_task_self() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        pt_sanitize_vm_read_buffer((uintptr_t)address, (uint8_t *)(uintptr_t)data, (size_t)*outsize);
    }
    return kr;
}

static kern_return_t pt_mach_vm_read_overwrite(vm_map_read_t target_task,
                                               mach_vm_address_t address,
                                               mach_vm_size_t size,
                                               mach_vm_address_t data,
                                               mach_vm_size_t *outsize) {
    kern_return_t kr = pt_orig_mach_vm_read_overwrite(target_task, address, size, data, outsize);
    if (kr == KERN_SUCCESS &&
        outsize != NULL &&
        *outsize > 0 &&
        data != 0 &&
        target_task == mach_task_self() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        pt_sanitize_vm_read_buffer((uintptr_t)address, (uint8_t *)(uintptr_t)data, (size_t)*outsize);
    }
    return kr;
}

static kern_return_t pt_vm_read(vm_map_read_t target_task,
                                vm_address_t address,
                                vm_size_t size,
                                vm_offset_t *data,
                                mach_msg_type_number_t *dataCnt) {
    kern_return_t kr = pt_orig_vm_read(target_task, address, size, data, dataCnt);
    if (kr == KERN_SUCCESS &&
        data != NULL &&
        *data != 0 &&
        dataCnt != NULL &&
        *dataCnt > 0 &&
        target_task == mach_task_self() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        pt_sanitize_vm_read_buffer((uintptr_t)address, (uint8_t *)(uintptr_t)(*data), (size_t)(*dataCnt));
    }
    return kr;
}

static kern_return_t pt_mach_vm_read(vm_map_read_t target_task,
                                     mach_vm_address_t address,
                                     mach_vm_size_t size,
                                     vm_offset_t *data,
                                     mach_msg_type_number_t *dataCnt) {
    kern_return_t kr = pt_orig_mach_vm_read(target_task, address, size, data, dataCnt);
    if (kr == KERN_SUCCESS &&
        data != NULL &&
        *data != 0 &&
        dataCnt != NULL &&
        *dataCnt > 0 &&
        target_task == mach_task_self() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        pt_sanitize_vm_read_buffer((uintptr_t)address, (uint8_t *)(uintptr_t)(*data), (size_t)(*dataCnt));
    }
    return kr;
}

static kern_return_t pt_vm_copy(vm_map_t target_task,
                                vm_address_t source_address,
                                vm_size_t size,
                                vm_address_t dest_address) {
    kern_return_t kr = pt_orig_vm_copy(target_task, source_address, size, dest_address);
    if (kr == KERN_SUCCESS &&
        size > 0 &&
        dest_address != 0 &&
        target_task == mach_task_self() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        pt_sanitize_vm_read_buffer((uintptr_t)source_address, (uint8_t *)(uintptr_t)dest_address, (size_t)size);
    }
    return kr;
}

static kern_return_t pt_mach_vm_copy(vm_map_t target_task,
                                     mach_vm_address_t source_address,
                                     mach_vm_size_t size,
                                     mach_vm_address_t dest_address) {
    kern_return_t kr = pt_orig_mach_vm_copy(target_task, source_address, size, dest_address);
    if (kr == KERN_SUCCESS &&
        size > 0 &&
        dest_address != 0 &&
        target_task == mach_task_self() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        pt_sanitize_vm_read_buffer((uintptr_t)source_address, (uint8_t *)(uintptr_t)dest_address, (size_t)size);
    }
    return kr;
}

static kern_return_t pt_vm_read_list(vm_map_read_t target_task,
                                     vm_read_entry_t data_list,
                                     natural_t count) {
    vm_address_t orig_addrs[VM_MAP_ENTRY_MAX];
    natural_t clamped = (data_list != NULL && count <= VM_MAP_ENTRY_MAX) ? count : 0U;
    for (natural_t i = 0; i < clamped; i++) {
        orig_addrs[i] = data_list[i].address;
    }
    kern_return_t kr = pt_orig_vm_read_list(target_task, data_list, count);
    if (kr == KERN_SUCCESS &&
        clamped > 0U &&
        target_task == mach_task_self() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        for (natural_t i = 0; i < clamped; i++) {
            if (orig_addrs[i] != 0 && data_list[i].address != 0 && data_list[i].size > 0) {
                pt_sanitize_vm_read_buffer((uintptr_t)orig_addrs[i],
                                           (uint8_t *)(uintptr_t)data_list[i].address,
                                           (size_t)data_list[i].size);
            }
        }
    }
    return kr;
}

static kern_return_t pt_mach_vm_read_list(vm_map_read_t target_task,
                                          mach_vm_read_entry_t data_list,
                                          natural_t count) {
    mach_vm_address_t orig_addrs[VM_MAP_ENTRY_MAX];
    natural_t clamped = (data_list != NULL && count <= VM_MAP_ENTRY_MAX) ? count : 0U;
    for (natural_t i = 0; i < clamped; i++) {
        orig_addrs[i] = data_list[i].address;
    }
    kern_return_t kr = pt_orig_mach_vm_read_list(target_task, data_list, count);
    if (kr == KERN_SUCCESS &&
        clamped > 0U &&
        target_task == mach_task_self() &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        for (natural_t i = 0; i < clamped; i++) {
            if (orig_addrs[i] != 0 && data_list[i].address != 0 && data_list[i].size > 0) {
                pt_sanitize_vm_read_buffer((uintptr_t)orig_addrs[i],
                                           (uint8_t *)(uintptr_t)data_list[i].address,
                                           (size_t)data_list[i].size);
            }
        }
    }
    return kr;
}

static BOOL pt_vm_region_should_probe_path(vm_region_flavor_t flavor,
                                           const void *info,
                                           mach_msg_type_number_t infoCnt,
                                           BOOL is_recurse) {
    if (info == NULL) {
        return NO;
    }
    if (is_recurse) {
        if (infoCnt >= VM_REGION_SUBMAP_SHORT_INFO_COUNT_64) {
            const vm_region_submap_short_info_data_64_t *si = (const vm_region_submap_short_info_data_64_t *)info;
            return (si->external_pager != 0 || si->share_mode == SM_SHARED || si->share_mode == SM_COW);
        }
        return NO;
    }
    switch (flavor) {
        case VM_REGION_EXTENDED_INFO:
            if (infoCnt >= VM_REGION_EXTENDED_INFO_COUNT) {
                const vm_region_extended_info_data_t *ei = (const vm_region_extended_info_data_t *)info;
                return (ei->external_pager != 0 || ei->share_mode == SM_SHARED || ei->share_mode == SM_COW);
            }
            return NO;
        case VM_REGION_BASIC_INFO_64:
            if (infoCnt >= VM_REGION_BASIC_INFO_COUNT_64) {
                const vm_region_basic_info_data_64_t *bi = (const vm_region_basic_info_data_64_t *)info;
                return (bi->shared != 0 || (bi->protection & VM_PROT_READ) != 0);
            }
            return NO;
        case VM_REGION_BASIC_INFO:
            if (infoCnt >= VM_REGION_BASIC_INFO_COUNT) {
                const vm_region_basic_info_data_t *bi = (const vm_region_basic_info_data_t *)info;
                return (bi->shared != 0 || (bi->protection & VM_PROT_READ) != 0);
            }
            return NO;
        default:
            return NO;
    }
}

#define PT_VM_REGION_MAX_SKIPS 4096

__attribute__((visibility("hidden")))
BOOL pt_vm_region_should_hide_range(uintptr_t cur_addr,
                                    uintptr_t cur_size,
                                    vm_region_flavor_t flavor,
                                    const void *info,
                                    mach_msg_type_number_t infoCnt,
                                    BOOL is_recurse,
                                    const void *caller) {
    vm_prot_t prot = pt_extract_vm_region_prot(flavor, info, infoCnt, is_recurse);
    BOOL path_hidden = NO;
    if (pt_vm_region_should_probe_path(flavor, info, infoCnt, is_recurse) &&
        dyld_image_header_containing_address((const void *)cur_addr) == NULL) {
        path_hidden = pt_fs_probe_hidden_region_path(cur_addr, caller);
    }
    return (path_hidden ||
            pt_is_hidden_vm_region_range(cur_addr, cur_size) ||
            pt_is_hidden_unregistered_macho_region(cur_addr, cur_size, prot));
}

__attribute__((visibility("hidden")))
kern_return_t pt_vm_region_64_with_caller(vm_map_read_t target_task,
                                          vm_address_t *address,
                                          vm_size_t *size,
                                          vm_region_flavor_t flavor,
                                          vm_region_info_t info,
                                          mach_msg_type_number_t *infoCnt,
                                          mach_port_t *object_name,
                                          const void *caller) {
    BOOL filter = (address != NULL && size != NULL && infoCnt != NULL &&
                   target_task == mach_task_self() &&
                   pt_is_bypass_enabled() &&
                   !pt_is_effective_system_or_playtools_caller(caller));
    mach_msg_type_number_t orig_cnt = (infoCnt != NULL) ? *infoCnt : 0;
    for (int skip = 0; skip < PT_VM_REGION_MAX_SKIPS; skip++) {
        kern_return_t kr = pt_orig_vm_region_64(target_task, address, size, flavor, info, infoCnt, object_name);
        if (kr != KERN_SUCCESS || !filter) {
            return kr;
        }
        vm_address_t cur_addr = *address;
        vm_size_t cur_size = *size;
        if (!pt_vm_region_should_hide_range((uintptr_t)cur_addr, (uintptr_t)cur_size, flavor, info, *infoCnt, NO, caller)) {
            return kr;
        }
        if (object_name != NULL && MACH_PORT_VALID(*object_name)) {
            mach_port_deallocate(mach_task_self(), *object_name);
            *object_name = MACH_PORT_NULL;
        }
        if (cur_size == 0 || cur_addr + cur_size <= cur_addr) {
            return KERN_INVALID_ADDRESS;
        }
        *address = cur_addr + cur_size;
        *infoCnt = orig_cnt;
    }
    return KERN_INVALID_ADDRESS;
}

static kern_return_t pt_vm_region_64(vm_map_read_t target_task,
                                     vm_address_t *address,
                                     vm_size_t *size,
                                     vm_region_flavor_t flavor,
                                     vm_region_info_t info,
                                     mach_msg_type_number_t *infoCnt,
                                     mach_port_t *object_name) {
    return pt_vm_region_64_with_caller(target_task, address, size, flavor, info, infoCnt, object_name,
                                       __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
kern_return_t pt_vm_region_recurse_64_with_caller(vm_map_read_t target_task,
                                                  vm_address_t *address,
                                                  vm_size_t *size,
                                                  natural_t *nesting_depth,
                                                  vm_region_recurse_info_t info,
                                                  mach_msg_type_number_t *infoCnt,
                                                  const void *caller) {
    BOOL filter = (address != NULL && size != NULL && infoCnt != NULL &&
                   target_task == mach_task_self() &&
                   pt_is_bypass_enabled() &&
                   !pt_is_effective_system_or_playtools_caller(caller));
    mach_msg_type_number_t orig_cnt = (infoCnt != NULL) ? *infoCnt : 0;
    natural_t orig_depth = (nesting_depth != NULL) ? *nesting_depth : 0;
    for (int skip = 0; skip < PT_VM_REGION_MAX_SKIPS; skip++) {
        kern_return_t kr = pt_orig_vm_region_recurse_64(target_task, address, size, nesting_depth, info, infoCnt);
        if (kr != KERN_SUCCESS || !filter) {
            return kr;
        }
        vm_address_t cur_addr = *address;
        vm_size_t cur_size = *size;
        if (!pt_vm_region_should_hide_range((uintptr_t)cur_addr, (uintptr_t)cur_size, 0, info, *infoCnt, YES, caller)) {
            return kr;
        }
        if (cur_size == 0 || cur_addr + cur_size <= cur_addr) {
            return KERN_INVALID_ADDRESS;
        }
        *address = cur_addr + cur_size;
        *infoCnt = orig_cnt;
        if (nesting_depth != NULL) {
            *nesting_depth = orig_depth;
        }
    }
    return KERN_INVALID_ADDRESS;
}

static kern_return_t pt_vm_region_recurse_64(vm_map_read_t target_task,
                                             vm_address_t *address,
                                             vm_size_t *size,
                                             natural_t *nesting_depth,
                                             vm_region_recurse_info_t info,
                                             mach_msg_type_number_t *infoCnt) {
    return pt_vm_region_recurse_64_with_caller(target_task, address, size, nesting_depth, info, infoCnt,
                                               __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
kern_return_t pt_mach_vm_region_with_caller(vm_map_read_t target_task,
                                            mach_vm_address_t *address,
                                            mach_vm_size_t *size,
                                            vm_region_flavor_t flavor,
                                            vm_region_info_t info,
                                            mach_msg_type_number_t *infoCnt,
                                            mach_port_t *object_name,
                                            const void *caller) {
    BOOL filter = (address != NULL && size != NULL && infoCnt != NULL &&
                   target_task == mach_task_self() &&
                   pt_is_bypass_enabled() &&
                   !pt_is_effective_system_or_playtools_caller(caller));
    mach_msg_type_number_t orig_cnt = (infoCnt != NULL) ? *infoCnt : 0;
    for (int skip = 0; skip < PT_VM_REGION_MAX_SKIPS; skip++) {
        kern_return_t kr = pt_orig_mach_vm_region(target_task, address, size, flavor, info, infoCnt, object_name);
        if (kr != KERN_SUCCESS || !filter) {
            return kr;
        }
        mach_vm_address_t cur_addr = *address;
        mach_vm_size_t cur_size = *size;
        if (!pt_vm_region_should_hide_range((uintptr_t)cur_addr, (uintptr_t)cur_size, flavor, info, *infoCnt, NO, caller)) {
            return kr;
        }
        if (object_name != NULL && MACH_PORT_VALID(*object_name)) {
            mach_port_deallocate(mach_task_self(), *object_name);
            *object_name = MACH_PORT_NULL;
        }
        if (cur_size == 0 || cur_addr + cur_size <= cur_addr) {
            return KERN_INVALID_ADDRESS;
        }
        *address = cur_addr + cur_size;
        *infoCnt = orig_cnt;
    }
    return KERN_INVALID_ADDRESS;
}

static kern_return_t pt_mach_vm_region(vm_map_read_t target_task,
                                       mach_vm_address_t *address,
                                       mach_vm_size_t *size,
                                       vm_region_flavor_t flavor,
                                       vm_region_info_t info,
                                       mach_msg_type_number_t *infoCnt,
                                       mach_port_t *object_name) {
    return pt_mach_vm_region_with_caller(target_task, address, size, flavor, info, infoCnt, object_name,
                                         __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
kern_return_t pt_mach_vm_region_recurse_with_caller(vm_map_read_t target_task,
                                                    mach_vm_address_t *address,
                                                    mach_vm_size_t *size,
                                                    natural_t *nesting_depth,
                                                    vm_region_recurse_info_t info,
                                                    mach_msg_type_number_t *infoCnt,
                                                    const void *caller) {
    BOOL filter = (address != NULL && size != NULL && infoCnt != NULL &&
                   target_task == mach_task_self() &&
                   pt_is_bypass_enabled() &&
                   !pt_is_effective_system_or_playtools_caller(caller));
    mach_msg_type_number_t orig_cnt = (infoCnt != NULL) ? *infoCnt : 0;
    natural_t orig_depth = (nesting_depth != NULL) ? *nesting_depth : 0;
    for (int skip = 0; skip < PT_VM_REGION_MAX_SKIPS; skip++) {
        kern_return_t kr = pt_orig_mach_vm_region_recurse(target_task, address, size, nesting_depth, info, infoCnt);
        if (kr != KERN_SUCCESS || !filter) {
            return kr;
        }
        mach_vm_address_t cur_addr = *address;
        mach_vm_size_t cur_size = *size;
        if (!pt_vm_region_should_hide_range((uintptr_t)cur_addr, (uintptr_t)cur_size, 0, info, *infoCnt, YES, caller)) {
            return kr;
        }
        if (cur_size == 0 || cur_addr + cur_size <= cur_addr) {
            return KERN_INVALID_ADDRESS;
        }
        *address = cur_addr + cur_size;
        *infoCnt = orig_cnt;
        if (nesting_depth != NULL) {
            *nesting_depth = orig_depth;
        }
    }
    return KERN_INVALID_ADDRESS;
}

static kern_return_t pt_mach_vm_region_recurse(vm_map_read_t target_task,
                                               mach_vm_address_t *address,
                                               mach_vm_size_t *size,
                                               natural_t *nesting_depth,
                                               vm_region_recurse_info_t info,
                                               mach_msg_type_number_t *infoCnt) {
    return pt_mach_vm_region_recurse_with_caller(target_task, address, size, nesting_depth, info, infoCnt,
                                                 __builtin_return_address(0));
}

PT_INTERPOSE_NAMED(pt_vm_region_64, pt_orig_vm_region_64, "vm_region_64")
PT_INTERPOSE_NAMED(pt_vm_region_recurse_64, pt_orig_vm_region_recurse_64, "vm_region_recurse_64")
PT_INTERPOSE_NAMED(pt_mach_vm_region, pt_orig_mach_vm_region, "mach_vm_region")
PT_INTERPOSE_NAMED(pt_mach_vm_region_recurse, pt_orig_mach_vm_region_recurse, "mach_vm_region_recurse")
PT_INTERPOSE_NAMED(pt_vm_read_overwrite, pt_orig_vm_read_overwrite, "vm_read_overwrite")
PT_INTERPOSE_NAMED(pt_mach_vm_read_overwrite, pt_orig_mach_vm_read_overwrite, "mach_vm_read_overwrite")
PT_INTERPOSE_NAMED(pt_vm_read, pt_orig_vm_read, "vm_read")
PT_INTERPOSE_NAMED(pt_mach_vm_read, pt_orig_mach_vm_read, "mach_vm_read")
PT_INTERPOSE_NAMED(pt_vm_copy, pt_orig_vm_copy, "vm_copy")
PT_INTERPOSE_NAMED(pt_mach_vm_copy, pt_orig_mach_vm_copy, "mach_vm_copy")
PT_INTERPOSE_NAMED(pt_vm_read_list, pt_orig_vm_read_list, "vm_read_list")
PT_INTERPOSE_NAMED(pt_mach_vm_read_list, pt_orig_mach_vm_read_list, "mach_vm_read_list")
PT_INTERPOSE(pt_os_proc_available_memory, os_proc_available_memory)
PT_INTERPOSE(pt_host_info, host_info)
PT_INTERPOSE(pt_host_processor_info, host_processor_info)
PT_INTERPOSE(pt_host_statistics, host_statistics)
PT_INTERPOSE(pt_host_statistics64, host_statistics64)
PT_INTERPOSE(pt_task_info, task_info)
PT_INTERPOSE(pt_host_kernel_version, host_kernel_version)
