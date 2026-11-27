//
//  PTSvcInterceptor.m
//  PlayTools
//

#import "PTInternal.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/arm/thread_status.h>
#include <mach/exc.h>
#include <mach/mach.h>
#include <mach_debug/ipc_info.h>
#include <os/lock.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>
#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif

extern const char *dyld_image_path_containing_address(const void *addr);
extern kern_return_t pt_orig_task_set_exception_ports(task_t task,
                                                     exception_mask_t exception_mask,
                                                     mach_port_t new_port,
                                                     exception_behavior_t behavior,
                                                     thread_state_flavor_t new_flavor)
    __asm("_task_set_exception_ports");
extern kern_return_t pt_orig_task_swap_exception_ports(task_t task,
                                                      exception_mask_t exception_mask,
                                                      mach_port_t new_port,
                                                      exception_behavior_t behavior,
                                                      thread_state_flavor_t new_flavor,
                                                      exception_mask_array_t masks,
                                                      mach_msg_type_number_t *masksCnt,
                                                      exception_handler_array_t old_handlers,
                                                      exception_behavior_array_t old_behaviors,
                                                      exception_flavor_array_t old_flavors)
    __asm("_task_swap_exception_ports");
extern kern_return_t pt_orig_thread_set_exception_ports(thread_act_t thread,
                                                       exception_mask_t exception_mask,
                                                       mach_port_t new_port,
                                                       exception_behavior_t behavior,
                                                       thread_state_flavor_t new_flavor)
    __asm("_thread_set_exception_ports");
extern kern_return_t pt_orig_thread_swap_exception_ports(thread_act_t thread,
                                                        exception_mask_t exception_mask,
                                                        mach_port_t new_port,
                                                        exception_behavior_t behavior,
                                                        thread_state_flavor_t new_flavor,
                                                        exception_mask_array_t masks,
                                                        mach_msg_type_number_t *masksCnt,
                                                        exception_handler_array_t old_handlers,
                                                        exception_behavior_array_t old_behaviors,
                                                        exception_flavor_array_t old_flavors)
    __asm("_thread_swap_exception_ports");
extern kern_return_t pt_orig_task_get_exception_ports(task_t task,
                                                     exception_mask_t exception_mask,
                                                     exception_mask_array_t masks,
                                                     mach_msg_type_number_t *masksCnt,
                                                     exception_handler_array_t old_handlers,
                                                     exception_behavior_array_t old_behaviors,
                                                     exception_flavor_array_t old_flavors)
    __asm("_task_get_exception_ports");
extern kern_return_t pt_orig_thread_get_exception_ports(thread_act_t thread,
                                                       exception_mask_t exception_mask,
                                                       exception_mask_array_t masks,
                                                       mach_msg_type_number_t *masksCnt,
                                                       exception_handler_array_t old_handlers,
                                                       exception_behavior_array_t old_behaviors,
                                                       exception_flavor_array_t old_flavors)
    __asm("_thread_get_exception_ports");

extern kern_return_t pt_orig_task_get_exception_ports_info(mach_port_t port,
                                                           exception_mask_t exception_mask,
                                                           exception_mask_array_t masks,
                                                           mach_msg_type_number_t *masksCnt,
                                                           exception_handler_info_array_t old_handlers_info,
                                                           exception_behavior_array_t old_behaviors,
                                                           exception_flavor_array_t old_flavors)
    __asm__("_task_get_exception_ports_info") __attribute__((weak_import));
extern kern_return_t pt_orig_thread_get_exception_ports_info(mach_port_t port,
                                                             exception_mask_t exception_mask,
                                                             exception_mask_array_t masks,
                                                             mach_msg_type_number_t *masksCnt,
                                                             exception_handler_info_array_t old_handlers_info,
                                                             exception_behavior_array_t old_behaviors,
                                                             exception_flavor_array_t old_flavors)
    __asm__("_thread_get_exception_ports_info") __attribute__((weak_import));

#define PT_ARM64_SVC80_INSN 0xD4001001U
#define PT_ARM64_BRK_SVC_INSN 0xD42A0E80U
#define PT_ARM64_CPSR_C (1U << 29)
#define PT_SVC_MANIFEST_MAX_BYTES (4U * 1024U * 1024U)
#define PT_SVC_MAX_MANIFEST_FILES 1024U
#define PT_SVC_MAX_MANIFEST_SITES 262144U
#define PT_SVC_JSON_MAX_DEPTH 32U

#if __DARWIN_UNIX03
#define PT_TS_X(s) ((s).__x)
#define PT_TS_SP(s) ((s).__sp)
#define PT_TS_CPSR(s) ((s).__cpsr)
#else
#define PT_TS_X(s) ((s).x)
#define PT_TS_SP(s) ((s).sp)
#define PT_TS_CPSR(s) ((s).cpsr)
#endif

typedef struct {
    char *relative_path;
    uint64_t *vm_offsets;
    size_t vm_offset_count;
    size_t vm_offset_cap;
} pt_svc_manifest_file_t;

typedef struct {
    pt_svc_manifest_file_t *files;
    size_t file_count;
    size_t file_cap;
    size_t total_sites;
    int64_t schema_version;
} pt_svc_manifest_t;

static _Atomic bool s_svc_interceptor_active = false;
static _Atomic bool s_svc_has_registered_sites = false;
static _Atomic bool s_svc_safe_mode_passthrough = false;

static pt_svc_manifest_t s_manifest = {0};
static os_unfair_lock s_svc_sites_lock = OS_UNFAIR_LOCK_INIT;
static uintptr_t *s_registered_pcs = NULL;
static size_t s_registered_pc_count = 0;
static size_t s_registered_pc_cap = 0;

static _Atomic mach_port_t s_svc_exc_port = MACH_PORT_NULL;
static pthread_t s_svc_exc_thread;
static ipc_info_port_t s_svc_exc_iip = {0, 0};
static _Atomic bool s_svc_exc_iip_valid = false;

typedef struct {
    BOOL valid;
    exception_mask_t mask;
    mach_port_t port;
    exception_behavior_t behavior;
    thread_state_flavor_t flavor;
} pt_svc_saved_exc_handler_t;

#define PT_SVC_THREAD_EXC_SLOTS 64U

typedef struct {
    BOOL in_use;
    thread_act_t thread;
    pt_svc_saved_exc_handler_t bp;
    uint64_t seq;
} pt_svc_thread_exc_entry_t;

static os_unfair_lock s_svc_exc_snapshot_lock = OS_UNFAIR_LOCK_INIT;
static pt_svc_saved_exc_handler_t s_saved_task_bp_handler = {0};
static pt_svc_thread_exc_entry_t s_saved_thread_bp_handlers[PT_SVC_THREAD_EXC_SLOTS];
static uint64_t s_saved_thread_bp_seq = 0;

static mach_port_t pt_svc_retain_send_right(mach_port_t port) {
    if (!MACH_PORT_VALID(port)) {
        return MACH_PORT_NULL;
    }
    if (mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_SEND, 1) == KERN_SUCCESS) {
        return port;
    }
    return MACH_PORT_NULL;
}

static void pt_svc_release_send_right(mach_port_t port) {
    if (MACH_PORT_VALID(port)) {
        (void)mach_port_deallocate(mach_task_self(), port);
    }
}

static void pt_svc_swap_saved_slot_locked(pt_svc_saved_exc_handler_t *slot,
                                          exception_mask_t mask,
                                          mach_port_t retained_new_port,
                                          exception_behavior_t behavior,
                                          thread_state_flavor_t flavor,
                                          pt_svc_saved_exc_handler_t *out_prev) {
    if (out_prev != NULL) {
        *out_prev = *slot;
    } else {
        pt_svc_release_send_right(slot->port);
    }
    if (MACH_PORT_VALID(retained_new_port)) {
        slot->valid = YES;
        slot->mask = mask & (exception_mask_t)EXC_MASK_BREAKPOINT;
        slot->port = retained_new_port;
        slot->behavior = behavior;
        slot->flavor = flavor;
    } else {
        memset(slot, 0, sizeof(*slot));
    }
}

static pt_svc_saved_exc_handler_t pt_svc_copy_retained_task_bp(void) {
    pt_svc_saved_exc_handler_t out = {0};
    os_unfair_lock_lock(&s_svc_exc_snapshot_lock);
    if (s_saved_task_bp_handler.valid && MACH_PORT_VALID(s_saved_task_bp_handler.port)) {
        mach_port_t ref = pt_svc_retain_send_right(s_saved_task_bp_handler.port);
        if (MACH_PORT_VALID(ref)) {
            out = s_saved_task_bp_handler;
            out.port = ref;
        }
    }
    os_unfair_lock_unlock(&s_svc_exc_snapshot_lock);
    return out;
}

static pt_svc_saved_exc_handler_t pt_svc_copy_retained_thread_bp(thread_act_t thread) {
    pt_svc_saved_exc_handler_t out = {0};
    if (!MACH_PORT_VALID(thread)) {
        return out;
    }
    os_unfair_lock_lock(&s_svc_exc_snapshot_lock);
    for (size_t i = 0; i < PT_SVC_THREAD_EXC_SLOTS; i++) {
        const pt_svc_thread_exc_entry_t *e = &s_saved_thread_bp_handlers[i];
        if (e->in_use && e->thread == thread && e->bp.valid && MACH_PORT_VALID(e->bp.port)) {
            mach_port_t ref = pt_svc_retain_send_right(e->bp.port);
            if (MACH_PORT_VALID(ref)) {
                out = e->bp;
                out.port = ref;
            }
            break;
        }
    }
    os_unfair_lock_unlock(&s_svc_exc_snapshot_lock);
    return out;
}

static void pt_svc_update_thread_bp(thread_act_t thread,
                                    exception_mask_t mask,
                                    mach_port_t retained_new_port,
                                    exception_behavior_t behavior,
                                    thread_state_flavor_t flavor,
                                    pt_svc_saved_exc_handler_t *out_prev) {
    if (out_prev != NULL) {
        memset(out_prev, 0, sizeof(*out_prev));
    }
    if (!MACH_PORT_VALID(thread)) {
        pt_svc_release_send_right(retained_new_port);
        return;
    }
    os_unfair_lock_lock(&s_svc_exc_snapshot_lock);
    pt_svc_thread_exc_entry_t *match = NULL;
    pt_svc_thread_exc_entry_t *free_slot = NULL;
    pt_svc_thread_exc_entry_t *oldest_slot = &s_saved_thread_bp_handlers[0];
    for (size_t i = 0; i < PT_SVC_THREAD_EXC_SLOTS; i++) {
        pt_svc_thread_exc_entry_t *e = &s_saved_thread_bp_handlers[i];
        if (!e->in_use) {
            if (free_slot == NULL) {
                free_slot = e;
            }
            continue;
        }
        if (e->thread == thread) {
            match = e;
            break;
        }
        if (e->seq < oldest_slot->seq) {
            oldest_slot = e;
        }
    }
    if (match != NULL) {
        pt_svc_swap_saved_slot_locked(&match->bp, mask, retained_new_port, behavior, flavor, out_prev);
        if (!match->bp.valid) {
            match->in_use = NO;
            match->thread = MACH_PORT_NULL;
            match->seq = 0;
        } else {
            match->seq = ++s_saved_thread_bp_seq;
        }
    } else if (MACH_PORT_VALID(retained_new_port)) {
        pt_svc_thread_exc_entry_t *dst = (free_slot != NULL) ? free_slot : oldest_slot;
        if (dst->in_use) {
            pt_svc_release_send_right(dst->bp.port);
            memset(dst, 0, sizeof(*dst));
        }
        dst->in_use = YES;
        dst->thread = thread;
        dst->seq = ++s_saved_thread_bp_seq;
        pt_svc_swap_saved_slot_locked(&dst->bp, mask, retained_new_port, behavior, flavor, NULL);
    } else {
        pt_svc_release_send_right(retained_new_port);
    }
    os_unfair_lock_unlock(&s_svc_exc_snapshot_lock);
}

static void pt_svc_redact_exc_ports_array(mach_port_t svc_port,
                                          BOOL inject_if_missing_bp,
                                          pt_svc_saved_exc_handler_t *retained_saved,
                                          mach_msg_type_number_t caller_capacity,
                                          exception_mask_array_t masks,
                                          mach_msg_type_number_t *masksCnt,
                                          exception_handler_array_t old_handlers,
                                          exception_behavior_array_t old_behaviors,
                                          exception_flavor_array_t old_flavors) {
    if (masksCnt == NULL || masks == NULL || old_handlers == NULL ||
        old_behaviors == NULL || old_flavors == NULL) {
        if (retained_saved != NULL) {
            pt_svc_release_send_right(retained_saved->port);
            retained_saved->port = MACH_PORT_NULL;
            retained_saved->valid = NO;
        }
        return;
    }

    mach_msg_type_number_t max_cap = (caller_capacity < (mach_msg_type_number_t)EXC_TYPES_COUNT)
        ? caller_capacity
        : (mach_msg_type_number_t)EXC_TYPES_COUNT;
    mach_msg_type_number_t count = *masksCnt;
    if (count > max_cap) {
        for (mach_msg_type_number_t k = max_cap; k < count && k < (mach_msg_type_number_t)EXC_TYPES_COUNT; k++) {
            pt_svc_release_send_right(old_handlers[k]);
            old_handlers[k] = MACH_PORT_NULL;
        }
        count = max_cap;
    }

    BOOL has_saved = (retained_saved != NULL &&
                      retained_saved->valid &&
                      MACH_PORT_VALID(retained_saved->port));
    BOOL saw_bp_slot = NO;
    mach_msg_type_number_t write_idx = 0;

    for (mach_msg_type_number_t i = 0; i < count; i++) {
        exception_mask_t m = masks[i];
        mach_port_t h = old_handlers[i];
        exception_behavior_t b = old_behaviors[i];
        thread_state_flavor_t f = old_flavors[i];

        if (MACH_PORT_VALID(svc_port) && h == svc_port) {
            pt_svc_release_send_right(h);
            if (!has_saved) {
                continue;
            }
            h = retained_saved->port;
            b = retained_saved->behavior;
            f = retained_saved->flavor;
            retained_saved->port = MACH_PORT_NULL;
            retained_saved->valid = NO;
            has_saved = NO;
            saw_bp_slot = YES;
        } else if ((m & (exception_mask_t)EXC_MASK_BREAKPOINT) != 0) {
            saw_bp_slot = YES;
        }

        BOOL merged = NO;
        for (mach_msg_type_number_t j = 0; j < write_idx; j++) {
            if (old_handlers[j] == h && old_behaviors[j] == b && old_flavors[j] == f) {
                masks[j] |= m;
                pt_svc_release_send_right(h);
                merged = YES;
                break;
            }
        }
        if (!merged && write_idx < max_cap) {
            masks[write_idx] = m;
            old_handlers[write_idx] = h;
            old_behaviors[write_idx] = b;
            old_flavors[write_idx] = f;
            write_idx++;
        } else if (!merged) {
            pt_svc_release_send_right(h);
        }
    }

    if (inject_if_missing_bp && !saw_bp_slot && has_saved) {
        BOOL merged = NO;
        for (mach_msg_type_number_t j = 0; j < write_idx; j++) {
            if (old_handlers[j] == retained_saved->port &&
                old_behaviors[j] == retained_saved->behavior &&
                old_flavors[j] == retained_saved->flavor) {
                masks[j] |= (exception_mask_t)EXC_MASK_BREAKPOINT;
                merged = YES;
                break;
            }
        }
        if (!merged && write_idx < max_cap) {
            masks[write_idx] = (exception_mask_t)EXC_MASK_BREAKPOINT;
            old_handlers[write_idx] = retained_saved->port;
            old_behaviors[write_idx] = retained_saved->behavior;
            old_flavors[write_idx] = retained_saved->flavor;
            retained_saved->port = MACH_PORT_NULL;
            retained_saved->valid = NO;
            write_idx++;
        }
    }

    if (retained_saved != NULL) {
        pt_svc_release_send_right(retained_saved->port);
        retained_saved->port = MACH_PORT_NULL;
        retained_saved->valid = NO;
    }

    *masksCnt = write_idx;
}

typedef struct {
    exception_mask_t masks[EXC_TYPES_COUNT];
    mach_port_t handlers[EXC_TYPES_COUNT];
    exception_behavior_t behaviors[EXC_TYPES_COUNT];
    thread_state_flavor_t flavors[EXC_TYPES_COUNT];
    mach_msg_type_number_t count;
} pt_svc_local_exc_ports_t;

static void pt_svc_publish_redacted_exc_ports(mach_port_t svc_port,
                                              BOOL inject_if_missing_bp,
                                              pt_svc_saved_exc_handler_t *retained_saved,
                                              pt_svc_local_exc_ports_t *local,
                                              mach_msg_type_number_t caller_capacity,
                                              exception_mask_array_t masks,
                                              mach_msg_type_number_t *masksCnt,
                                              exception_handler_array_t old_handlers,
                                              exception_behavior_array_t old_behaviors,
                                              exception_flavor_array_t old_flavors) {
    if (local == NULL) {
        if (retained_saved != NULL) {
            pt_svc_release_send_right(retained_saved->port);
            retained_saved->port = MACH_PORT_NULL;
            retained_saved->valid = NO;
        }
        return;
    }
    pt_svc_redact_exc_ports_array(svc_port,
                                  inject_if_missing_bp,
                                  retained_saved,
                                  (mach_msg_type_number_t)EXC_TYPES_COUNT,
                                  local->masks,
                                  &local->count,
                                  local->handlers,
                                  local->behaviors,
                                  local->flavors);
    mach_msg_type_number_t effective_cap = (caller_capacity == 0U)
        ? (mach_msg_type_number_t)EXC_TYPES_COUNT
        : caller_capacity;
    mach_msg_type_number_t copy_count = (local->count < effective_cap) ? local->count : effective_cap;
    if (copy_count > (mach_msg_type_number_t)EXC_TYPES_COUNT) {
        copy_count = (mach_msg_type_number_t)EXC_TYPES_COUNT;
    }
    if (masks == NULL || old_handlers == NULL || old_behaviors == NULL || old_flavors == NULL) {
        copy_count = 0;
    } else {
        for (mach_msg_type_number_t i = 0; i < copy_count; i++) {
            masks[i] = local->masks[i];
            old_handlers[i] = local->handlers[i];
            old_behaviors[i] = local->behaviors[i];
            old_flavors[i] = local->flavors[i];
        }
    }
    for (mach_msg_type_number_t i = copy_count;
         i < local->count && i < (mach_msg_type_number_t)EXC_TYPES_COUNT;
         i++) {
        pt_svc_release_send_right(local->handlers[i]);
        local->handlers[i] = MACH_PORT_NULL;
    }
    if (masksCnt != NULL) {
        *masksCnt = copy_count;
    }
}

static BOOL pt_svc_env_flag_true(const char *val) {
    if (val == NULL) {
        return NO;
    }
    return (strcmp(val, "1") == 0 || strcasecmp(val, "true") == 0 || strcasecmp(val, "yes") == 0);
}

static void pt_svc_free_manifest(pt_svc_manifest_t *manifest) {
    if (manifest == NULL) {
        return;
    }
    for (size_t i = 0; i < manifest->file_count; i++) {
        free(manifest->files[i].relative_path);
        free(manifest->files[i].vm_offsets);
    }
    free(manifest->files);
    memset(manifest, 0, sizeof(*manifest));
}

static BOOL pt_svc_manifest_file_add_offset(pt_svc_manifest_file_t *file,
                                            pt_svc_manifest_t *manifest,
                                            uint64_t vm_offset) {
    if (manifest->total_sites >= PT_SVC_MAX_MANIFEST_SITES) {
        return NO;
    }
    if (file->vm_offset_count == file->vm_offset_cap) {
        size_t next_cap = (file->vm_offset_cap == 0) ? 16U : (file->vm_offset_cap * 2U);
        if (next_cap > PT_SVC_MAX_MANIFEST_SITES) {
            next_cap = PT_SVC_MAX_MANIFEST_SITES;
        }
        uint64_t *next = (uint64_t *)realloc(file->vm_offsets, next_cap * sizeof(uint64_t));
        if (next == NULL) {
            return NO;
        }
        file->vm_offsets = next;
        file->vm_offset_cap = next_cap;
    }
    file->vm_offsets[file->vm_offset_count++] = vm_offset;
    manifest->total_sites++;
    return YES;
}

static BOOL pt_svc_is_safe_relative_path(const char *rel) {
    if (rel == NULL || rel[0] == '\0' || rel[0] == '/') {
        return NO;
    }
    if (strcmp(rel, ".") == 0 || strcmp(rel, "..") == 0 ||
        strncmp(rel, "../", 3) == 0 || strncmp(rel, "./", 2) == 0 ||
        strstr(rel, "/../") != NULL || strstr(rel, "/./") != NULL) {
        return NO;
    }
    size_t len = strlen(rel);
    if ((len >= 3 && strcmp(rel + len - 3, "/..") == 0) ||
        (len >= 2 && strcmp(rel + len - 2, "/.") == 0)) {
        return NO;
    }
    return YES;
}

static BOOL pt_svc_manifest_add_file(pt_svc_manifest_t *manifest,
                                     const char *rel_path,
                                     uint64_t *offsets,
                                     size_t count) {
    if (!pt_svc_is_safe_relative_path(rel_path) || count == 0 ||
        manifest->file_count >= PT_SVC_MAX_MANIFEST_FILES) {
        return NO;
    }
    if (manifest->file_count == manifest->file_cap) {
        size_t next_cap = (manifest->file_cap == 0) ? 8U : (manifest->file_cap * 2U);
        pt_svc_manifest_file_t *next = (pt_svc_manifest_file_t *)realloc(
            manifest->files, next_cap * sizeof(pt_svc_manifest_file_t));
        if (next == NULL) {
            return NO;
        }
        manifest->files = next;
        manifest->file_cap = next_cap;
    }
    char *copy = strdup(rel_path);
    if (copy == NULL) {
        return NO;
    }
    uint64_t *offs_copy = (uint64_t *)malloc(count * sizeof(uint64_t));
    if (offs_copy == NULL) {
        free(copy);
        return NO;
    }
    memcpy(offs_copy, offsets, count * sizeof(uint64_t));
    pt_svc_manifest_file_t *dst = &manifest->files[manifest->file_count++];
    dst->relative_path = copy;
    dst->vm_offsets = offs_copy;
    dst->vm_offset_count = count;
    dst->vm_offset_cap = count;
    return YES;
}

// MARK: - Minimal Bounded JSON Parser for SVCPatchManifest

typedef struct {
    const char *buf;
    size_t len;
    size_t pos;
} pt_json_cur_t;

static void pt_json_skip_ws(pt_json_cur_t *c) {
    while (c->pos < c->len) {
        char ch = c->buf[c->pos];
        if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
            c->pos++;
        } else {
            break;
        }
    }
}

static BOOL pt_json_consume(pt_json_cur_t *c, char expected) {
    pt_json_skip_ws(c);
    if (c->pos < c->len && c->buf[c->pos] == expected) {
        c->pos++;
        return YES;
    }
    return NO;
}

static BOOL pt_json_parse_string(pt_json_cur_t *c, char *out, size_t out_cap) {
    pt_json_skip_ws(c);
    if (c->pos >= c->len || c->buf[c->pos] != '"') {
        return NO;
    }
    c->pos++;
    size_t w = 0;
    BOOL overflowed = NO;
    while (c->pos < c->len) {
        char ch = c->buf[c->pos++];
        if (ch == '"') {
            if (out != NULL && out_cap > 0) {
                out[(w < out_cap) ? w : (out_cap - 1U)] = '\0';
            }
            return !overflowed;
        }
        if (ch == '\\') {
            if (c->pos >= c->len) {
                return NO;
            }
            char esc = c->buf[c->pos++];
            switch (esc) {
                case '"':
                case '\\':
                case '/':
                    ch = esc;
                    break;
                case 'b':
                    ch = '\b';
                    break;
                case 'f':
                    ch = '\f';
                    break;
                case 'n':
                    ch = '\n';
                    break;
                case 'r':
                    ch = '\r';
                    break;
                case 't':
                    ch = '\t';
                    break;
                case 'u': {
                    if (c->pos + 4U > c->len) {
                        return NO;
                    }
                    c->pos += 4U;
                    ch = '?';
                    break;
                }
                default:
                    return NO;
            }
        }
        if (out != NULL && out_cap > 0) {
            if (w + 1U < out_cap) {
                out[w++] = ch;
            } else {
                overflowed = YES;
            }
        }
    }
    return NO;
}

static BOOL pt_json_parse_uint64(pt_json_cur_t *c, uint64_t *out_val) {
    pt_json_skip_ws(c);
    if (c->pos >= c->len) {
        return NO;
    }
    char first = c->buf[c->pos];
    if (first < '0' || first > '9') {
        return NO;
    }
    uint64_t val = 0;
    while (c->pos < c->len) {
        char ch = c->buf[c->pos];
        if (ch < '0' || ch > '9') {
            break;
        }
        uint64_t digit = (uint64_t)(ch - '0');
        if (val > (UINT64_MAX - digit) / 10ULL) {
            return NO;
        }
        val = val * 10ULL + digit;
        c->pos++;
    }
    if (out_val != NULL) {
        *out_val = val;
    }
    return YES;
}

static BOOL pt_json_skip_value(pt_json_cur_t *c, unsigned depth) {
    if (depth > PT_SVC_JSON_MAX_DEPTH) {
        return NO;
    }
    pt_json_skip_ws(c);
    if (c->pos >= c->len) {
        return NO;
    }
    char ch = c->buf[c->pos];
    if (ch == '"') {
        return pt_json_parse_string(c, NULL, 0);
    }
    if (ch == '{') {
        c->pos++;
        pt_json_skip_ws(c);
        if (pt_json_consume(c, '}')) {
            return YES;
        }
        while (c->pos < c->len) {
            if (!pt_json_parse_string(c, NULL, 0) || !pt_json_consume(c, ':') ||
                !pt_json_skip_value(c, depth + 1U)) {
                return NO;
            }
            if (pt_json_consume(c, ',')) {
                continue;
            }
            return pt_json_consume(c, '}');
        }
        return NO;
    }
    if (ch == '[') {
        c->pos++;
        pt_json_skip_ws(c);
        if (pt_json_consume(c, ']')) {
            return YES;
        }
        while (c->pos < c->len) {
            if (!pt_json_skip_value(c, depth + 1U)) {
                return NO;
            }
            if (pt_json_consume(c, ',')) {
                continue;
            }
            return pt_json_consume(c, ']');
        }
        return NO;
    }
    if (ch == 't' && c->pos + 4U <= c->len && strncmp(c->buf + c->pos, "true", 4) == 0) {
        c->pos += 4U;
        return YES;
    }
    if (ch == 'f' && c->pos + 5U <= c->len && strncmp(c->buf + c->pos, "false", 5) == 0) {
        c->pos += 5U;
        return YES;
    }
    if (ch == 'n' && c->pos + 4U <= c->len && strncmp(c->buf + c->pos, "null", 4) == 0) {
        c->pos += 4U;
        return YES;
    }
    if (ch == '-' || (ch >= '0' && ch <= '9')) {
        if (ch == '-') {
            c->pos++;
        }
        if (c->pos >= c->len || c->buf[c->pos] < '0' || c->buf[c->pos] > '9') {
            return NO;
        }
        while (c->pos < c->len && c->buf[c->pos] >= '0' && c->buf[c->pos] <= '9') {
            c->pos++;
        }
        if (c->pos < c->len && c->buf[c->pos] == '.') {
            c->pos++;
            while (c->pos < c->len && c->buf[c->pos] >= '0' && c->buf[c->pos] <= '9') {
                c->pos++;
            }
        }
        if (c->pos < c->len && (c->buf[c->pos] == 'e' || c->buf[c->pos] == 'E')) {
            c->pos++;
            if (c->pos < c->len && (c->buf[c->pos] == '+' || c->buf[c->pos] == '-')) {
                c->pos++;
            }
            while (c->pos < c->len && c->buf[c->pos] >= '0' && c->buf[c->pos] <= '9') {
                c->pos++;
            }
        }
        return YES;
    }
    return NO;
}

static BOOL pt_json_parse_site_object(pt_json_cur_t *c, BOOL *out_has_vmoff, uint64_t *out_vmoff) {
    *out_has_vmoff = NO;
    *out_vmoff = 0;
    if (!pt_json_consume(c, '{')) {
        return NO;
    }
    if (pt_json_consume(c, '}')) {
        return YES;
    }
    char key[64];
    while (c->pos < c->len) {
        if (!pt_json_parse_string(c, key, sizeof(key)) || !pt_json_consume(c, ':')) {
            return NO;
        }
        if (strcmp(key, "vmOffset") == 0) {
            if (!pt_json_parse_uint64(c, out_vmoff)) {
                return NO;
            }
            *out_has_vmoff = YES;
        } else {
            if (!pt_json_skip_value(c, 1U)) {
                return NO;
            }
        }
        if (pt_json_consume(c, ',')) {
            continue;
        }
        return pt_json_consume(c, '}');
    }
    return NO;
}

static BOOL pt_json_parse_file_object(pt_json_cur_t *c, pt_svc_manifest_t *manifest) {
    if (!pt_json_consume(c, '{')) {
        return NO;
    }
    char rel_path[PATH_MAX];
    rel_path[0] = '\0';

    pt_svc_manifest_file_t temp_file = {0};
    if (pt_json_consume(c, '}')) {
        return YES;
    }
    char key[64];
    while (c->pos < c->len) {
        if (!pt_json_parse_string(c, key, sizeof(key)) || !pt_json_consume(c, ':')) {
            free(temp_file.vm_offsets);
            return NO;
        }
        if (strcmp(key, "relativePath") == 0) {
            if (!pt_json_parse_string(c, rel_path, sizeof(rel_path))) {
                free(temp_file.vm_offsets);
                return NO;
            }
        } else if (strcmp(key, "sites") == 0) {
            if (!pt_json_consume(c, '[')) {
                free(temp_file.vm_offsets);
                return NO;
            }
            if (!pt_json_consume(c, ']')) {
                while (c->pos < c->len) {
                    BOOL has_vmoff = NO;
                    uint64_t vmoff = 0;
                    if (!pt_json_parse_site_object(c, &has_vmoff, &vmoff)) {
                        free(temp_file.vm_offsets);
                        return NO;
                    }
                    if (has_vmoff && !pt_svc_manifest_file_add_offset(&temp_file, manifest, vmoff)) {
                        free(temp_file.vm_offsets);
                        return NO;
                    }
                    if (pt_json_consume(c, ',')) {
                        continue;
                    }
                    if (!pt_json_consume(c, ']')) {
                        free(temp_file.vm_offsets);
                        return NO;
                    }
                    break;
                }
            }
        } else {
            if (!pt_json_skip_value(c, 1U)) {
                free(temp_file.vm_offsets);
                return NO;
            }
        }
        if (pt_json_consume(c, ',')) {
            continue;
        }
        if (!pt_json_consume(c, '}')) {
            free(temp_file.vm_offsets);
            return NO;
        }
        break;
    }

    if (rel_path[0] != '\0' && temp_file.vm_offset_count > 0) {
        (void)pt_svc_manifest_add_file(manifest, rel_path, temp_file.vm_offsets, temp_file.vm_offset_count);
    }
    free(temp_file.vm_offsets);
    return YES;
}

static BOOL pt_svc_parse_manifest_json(const char *json, size_t len, pt_svc_manifest_t *out_manifest) {
    memset(out_manifest, 0, sizeof(*out_manifest));
    pt_json_cur_t cur = {.buf = json, .len = len, .pos = 0};
    if (!pt_json_consume(&cur, '{')) {
        return NO;
    }
    if (pt_json_consume(&cur, '}')) {
        return NO;
    }
    char key[64];
    while (cur.pos < cur.len) {
        if (!pt_json_parse_string(&cur, key, sizeof(key)) || !pt_json_consume(&cur, ':')) {
            pt_svc_free_manifest(out_manifest);
            return NO;
        }
        if (strcmp(key, "schemaVersion") == 0) {
            uint64_t ver = 0;
            if (!pt_json_parse_uint64(&cur, &ver)) {
                pt_svc_free_manifest(out_manifest);
                return NO;
            }
            out_manifest->schema_version = (int64_t)ver;
        } else if (strcmp(key, "files") == 0) {
            if (!pt_json_consume(&cur, '[')) {
                pt_svc_free_manifest(out_manifest);
                return NO;
            }
            if (!pt_json_consume(&cur, ']')) {
                while (cur.pos < cur.len) {
                    if (!pt_json_parse_file_object(&cur, out_manifest)) {
                        pt_svc_free_manifest(out_manifest);
                        return NO;
                    }
                    if (pt_json_consume(&cur, ',')) {
                        continue;
                    }
                    if (!pt_json_consume(&cur, ']')) {
                        pt_svc_free_manifest(out_manifest);
                        return NO;
                    }
                    break;
                }
            }
        } else {
            if (!pt_json_skip_value(&cur, 1U)) {
                pt_svc_free_manifest(out_manifest);
                return NO;
            }
        }
        if (pt_json_consume(&cur, ',')) {
            continue;
        }
        if (!pt_json_consume(&cur, '}')) {
            pt_svc_free_manifest(out_manifest);
            return NO;
        }
        break;
    }

    if (out_manifest->schema_version != 1 || out_manifest->file_count == 0 || out_manifest->total_sites == 0) {
        pt_svc_free_manifest(out_manifest);
        return NO;
    }
    return YES;
}

static BOOL pt_svc_resolve_manifest_path(char *out_path, size_t out_size) {
    if (out_path == NULL || out_size == 0) {
        return NO;
    }
    out_path[0] = '\0';

    const char *override_manifest = pt_raw_getenv("PLAYTOOLS_TEST_SVC_MANIFEST");
    if (override_manifest != NULL && override_manifest[0] == '/') {
        return (strlcpy(out_path, override_manifest, out_size) < out_size);
    }

    const char *user_root = pt_get_host_user_root_cstr();
    if (user_root == NULL || user_root[0] != '/') {
        return NO;
    }

    char bid[256];
    bid[0] = '\0';
    if (!pt_read_main_bundle_id_early(bid, sizeof(bid)) || bid[0] == '\0') {
        const char *home = pt_raw_getenv("CFFIXED_USER_HOME");
        const char *marker = (home != NULL) ? strstr(home, "/Library/Containers/") : NULL;
        if (marker != NULL) {
            const char *cid_start = marker + 20;
            const char *cid_end = strchr(cid_start, '/');
            size_t clen = (cid_end != NULL) ? (size_t)(cid_end - cid_start) : strlen(cid_start);
            if (clen > 0 && clen < sizeof(bid)) {
                memcpy(bid, cid_start, clen);
                bid[clen] = '\0';
            }
        }
    }
    if (bid[0] == '\0') {
        return NO;
    }

    int n = snprintf(out_path,
                     out_size,
                     "%s/Library/Containers/app.makedie.MacOver/SVCPatches/%s.json",
                     user_root,
                     bid);
    return (n > 0 && (size_t)n < out_size);
}

static BOOL pt_svc_load_manifest_from_disk(pt_svc_manifest_t *out_manifest) {
    char path[PATH_MAX];
    if (!pt_svc_resolve_manifest_path(path, sizeof(path))) {
        return NO;
    }

    pt_enter_internal_scope();
    int fd = pt_orig_open_nocancel(path, O_RDONLY | O_CLOEXEC, 0);
    if (fd < 0) {
        pt_leave_internal_scope();
        return NO;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 0 ||
        (uint64_t)st.st_size > PT_SVC_MANIFEST_MAX_BYTES) {
        close(fd);
        pt_leave_internal_scope();
        return NO;
    }

    size_t sz = (size_t)st.st_size;
    char *buf = (char *)malloc(sz + 1U);
    if (buf == NULL) {
        close(fd);
        pt_leave_internal_scope();
        return NO;
    }
    size_t total = 0;
    while (total < sz) {
        ssize_t r = read(fd, buf + total, sz - total);
        if (r < 0) {
            if (errno == EINTR) {
                continue;
            }
            free(buf);
            close(fd);
            pt_leave_internal_scope();
            return NO;
        }
        if (r == 0) {
            break;
        }
        total += (size_t)r;
    }
    close(fd);
    pt_leave_internal_scope();

    buf[total] = '\0';
    BOOL ok = pt_svc_parse_manifest_json(buf, total, out_manifest);
    free(buf);
    return ok;
}

// MARK: - Registered Patched PC Set & Dyld Binding

static uint64_t pt_svc_get_text_segment_vmsize(const struct mach_header *mh) {
    if (mh == NULL || mh->magic != MH_MAGIC_64) {
        return 0;
    }
    const struct mach_header_64 *mh64 = (const struct mach_header_64 *)mh;
    if (mh64->sizeofcmds == 0 || mh64->sizeofcmds > (1U << 20)) {
        return 0;
    }
    const uint8_t *base = (const uint8_t *)mh64;
    size_t total = sizeof(struct mach_header_64) + (size_t)mh64->sizeofcmds;
    size_t off = sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < mh64->ncmds && off + sizeof(struct load_command) <= total; i++) {
        const struct load_command *lc = (const struct load_command *)(base + off);
        if (lc->cmdsize < sizeof(struct load_command) || off + lc->cmdsize > total) {
            break;
        }
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strncmp(seg->segname, "__TEXT", 16) == 0) {
                return seg->vmsize;
            }
        }
        off += lc->cmdsize;
    }
    return 0;
}

static void pt_svc_insert_pc_locked(uintptr_t pc) {
    size_t lo = 0;
    size_t hi = s_registered_pc_count;
    while (lo < hi) {
        size_t mid = lo + ((hi - lo) / 2U);
        if (s_registered_pcs[mid] < pc) {
            lo = mid + 1U;
        } else {
            hi = mid;
        }
    }
    if (lo < s_registered_pc_count && s_registered_pcs[lo] == pc) {
        return;
    }
    if (s_registered_pc_count == s_registered_pc_cap) {
        size_t next_cap = (s_registered_pc_cap == 0) ? 64U : (s_registered_pc_cap * 2U);
        if (next_cap > PT_SVC_MAX_MANIFEST_SITES) {
            next_cap = PT_SVC_MAX_MANIFEST_SITES;
        }
        if (s_registered_pc_count >= next_cap) {
            return;
        }
        uintptr_t *next = (uintptr_t *)realloc(s_registered_pcs, next_cap * sizeof(uintptr_t));
        if (next == NULL) {
            return;
        }
        s_registered_pcs = next;
        s_registered_pc_cap = next_cap;
    }
    if (lo < s_registered_pc_count) {
        memmove(&s_registered_pcs[lo + 1U],
                &s_registered_pcs[lo],
                (s_registered_pc_count - lo) * sizeof(uintptr_t));
    }
    s_registered_pcs[lo] = pc;
    s_registered_pc_count++;
}

static const pt_svc_manifest_file_t *pt_svc_match_manifest_file_for_image_path(const char *raw_path) {
    if (raw_path == NULL || raw_path[0] == '\0') {
        return NULL;
    }
    const char *p = raw_path;
    if (strncmp(p, "/System/Volumes/Data/", 21) == 0) {
        p += 20;
    }
    const char *bundle_rel = NULL;
    if (s_real_app_bundle_dir[0] != '\0') {
        size_t b_len = strlen(s_real_app_bundle_dir);
        const char *sub = pt_match_prefix_modulo_private(p, s_real_app_bundle_dir, b_len);
        if (sub != NULL && sub[0] == '/') {
            bundle_rel = sub + 1;
        }
    }
    if (bundle_rel != NULL) {
        for (size_t i = 0; i < s_manifest.file_count; i++) {
            if (strcmp(bundle_rel, s_manifest.files[i].relative_path) == 0) {
                return &s_manifest.files[i];
            }
        }
        return NULL;
    }
    size_t plen = strlen(p);
    for (size_t i = 0; i < s_manifest.file_count; i++) {
        const char *rp = s_manifest.files[i].relative_path;
        size_t rlen = strlen(rp);
        if (plen > rlen && p[plen - rlen - 1U] == '/' &&
            strcmp(p + (plen - rlen), rp) == 0) {
            return &s_manifest.files[i];
        }
    }
    return NULL;
}

static void pt_svc_on_dyld_image_added(const struct mach_header *mh, intptr_t vmaddr_slide) {
    (void)vmaddr_slide;
    if (mh == NULL || mh->magic != MH_MAGIC_64) {
        return;
    }
    const char *img_name = dyld_image_path_containing_address(mh);
    const pt_svc_manifest_file_t *mfile = pt_svc_match_manifest_file_for_image_path(img_name);
    if (mfile == NULL) {
        return;
    }
    uint64_t text_vmsize = pt_svc_get_text_segment_vmsize(mh);
    if (text_vmsize < sizeof(struct mach_header_64)) {
        return;
    }

    uintptr_t mh_base = (uintptr_t)mh;
    BOOL added = NO;
    os_unfair_lock_lock(&s_svc_sites_lock);
    for (size_t i = 0; i < mfile->vm_offset_count; i++) {
        uint64_t off = mfile->vm_offsets[i];
        if (off < sizeof(struct mach_header_64) || off + 4ULL > text_vmsize) {
            continue;
        }
        uintptr_t pc = mh_base + (uintptr_t)off;
        uint32_t word = 0;
        memcpy(&word, (const void *)pc, sizeof(word));
        if (word == PT_ARM64_BRK_SVC_INSN) {
            pt_svc_insert_pc_locked(pc);
            added = YES;
        }
    }
    if (added) {
        atomic_store_explicit(&s_svc_has_registered_sites, true, memory_order_release);
    }
    os_unfair_lock_unlock(&s_svc_sites_lock);
}

static BOOL pt_svc_is_registered_pc(uintptr_t pc) {
    if (!atomic_load_explicit(&s_svc_has_registered_sites, memory_order_acquire)) {
        return NO;
    }
    BOOL found = NO;
    os_unfair_lock_lock(&s_svc_sites_lock);
    size_t lo = 0;
    size_t hi = s_registered_pc_count;
    while (lo < hi) {
        size_t mid = lo + ((hi - lo) / 2U);
        uintptr_t cur = s_registered_pcs[mid];
        if (cur == pc) {
            found = YES;
            break;
        }
        if (cur < pc) {
            lo = mid + 1U;
        } else {
            hi = mid;
        }
    }
    os_unfair_lock_unlock(&s_svc_sites_lock);
    return found;
}

__attribute__((visibility("hidden")))
void pt_svc_restore_patched_bytes_in_buffer(uintptr_t read_start, uint8_t *dst, size_t copied) {
    if (!atomic_load_explicit(&s_svc_has_registered_sites, memory_order_acquire) ||
        dst == NULL || copied == 0 || read_start > UINTPTR_MAX - copied) {
        return;
    }
    static const uint8_t kOrigSvcBytes[4] = {0x01U, 0x10U, 0x00U, 0xD4U};
    uintptr_t read_end = read_start + copied;

    os_unfair_lock_lock(&s_svc_sites_lock);
    size_t lo = 0;
    size_t hi = s_registered_pc_count;
    uintptr_t first_target = (read_start >= 3U) ? (read_start - 3U) : 0U;
    while (lo < hi) {
        size_t mid = lo + ((hi - lo) / 2U);
        if (s_registered_pcs[mid] < first_target) {
            lo = mid + 1U;
        } else {
            hi = mid;
        }
    }
    for (size_t i = lo; i < s_registered_pc_count; i++) {
        uintptr_t site_start = s_registered_pcs[i];
        if (site_start >= read_end) {
            break;
        }
        uintptr_t site_end = (site_start <= UINTPTR_MAX - 4U) ? (site_start + 4U) : UINTPTR_MAX;
        uintptr_t ov_start = (site_start > read_start) ? site_start : read_start;
        uintptr_t ov_end = (site_end < read_end) ? site_end : read_end;
        if (ov_start < ov_end) {
            size_t site_off = (size_t)(ov_start - site_start);
            size_t dst_off = (size_t)(ov_start - read_start);
            size_t ov_len = (size_t)(ov_end - ov_start);
            memcpy(dst + dst_off, kOrigSvcBytes + site_off, ov_len);
        }
    }
    os_unfair_lock_unlock(&s_svc_sites_lock);
}

// MARK: - Mach EXC_BREAKPOINT Server

#if defined(__arm64__) || defined(__aarch64__)

extern mach_msg_return_t mach_msg_overwrite_trap(mach_msg_header_t *msg,
                                                 mach_msg_option_t option,
                                                 mach_msg_size_t send_size,
                                                 mach_msg_size_t rcv_size,
                                                 mach_port_name_t rcv_name,
                                                 mach_msg_timeout_t timeout,
                                                 mach_port_name_t notify,
                                                 mach_msg_header_t *rcv_msg,
                                                 mach_msg_size_t rcv_limit);

static void pt_raw_arm64_svc80_sp(int64_t x16,
                                   const uint64_t in_x[8],
                                   uint64_t sp0,
                                   uint64_t sp1,
                                   uint64_t out_x[2],
                                   bool *out_carry) {
    if (x16 == SYS_exit) {
        _exit((int)in_x[0]);
    }
    register uint64_t r0 __asm("x0") = in_x[0];
    register uint64_t r1 __asm("x1") = in_x[1];
    register uint64_t r2 __asm("x2") = in_x[2];
    register uint64_t r3 __asm("x3") = in_x[3];
    register uint64_t r4 __asm("x4") = in_x[4];
    register uint64_t r5 __asm("x5") = in_x[5];
    register uint64_t r6 __asm("x6") = in_x[6];
    register uint64_t r7 __asm("x7") = in_x[7];
    register int64_t r16 __asm("x16") = x16;
    register uint64_t r9 __asm("x9") = sp0;
    register uint64_t r10 __asm("x10") = sp1;
    uint32_t carry = 0;
    __asm__ volatile(
        "sub sp, sp, #16\n\t"
        "stp %[s0], %[s1], [sp]\n\t"
        "svc #0x80\n\t"
        "cset %w[c], cs\n\t"
        "add sp, sp, #16"
        : "+r"(r0), "+r"(r1), "+r"(r2), "+r"(r3),
          "+r"(r4), "+r"(r5), "+r"(r6), "+r"(r7),
          "+r"(r16), [c] "=&r"(carry)
        : [s0] "r"(r9), [s1] "r"(r10)
        : "cc", "memory");
    out_x[0] = r0;
    out_x[1] = r1;
    *out_carry = (carry != 0);
}

#pragma pack(push, 4)
typedef struct {
    mach_msg_header_t Head;
    mach_msg_body_t msgh_body;
    mach_msg_port_descriptor_t thread;
    mach_msg_port_descriptor_t task;
    NDR_record_t NDR;
    exception_type_t exception;
    mach_msg_type_number_t codeCnt;
    int64_t code[2];
    int flavor;
    mach_msg_type_number_t old_stateCnt;
    natural_t old_state[1296];
    mach_msg_trailer_t trailer;
} pt_mach_exc_req_t;

typedef struct {
    mach_msg_header_t Head;
    NDR_record_t NDR;
    kern_return_t RetCode;
    int flavor;
    mach_msg_type_number_t new_stateCnt;
    natural_t new_state[1296];
} pt_mach_exc_reply_t;
#pragma pack(pop)

static void pt_svc_dealloc_req_ports(mach_port_t thread_port, mach_port_t task_port) {
    if (MACH_PORT_VALID(thread_port)) {
        (void)mach_port_deallocate(mach_task_self(), thread_port);
    }
    if (MACH_PORT_VALID(task_port)) {
        (void)mach_port_deallocate(mach_task_self(), task_port);
    }
}

static kern_return_t pt_svc_forward_mach_exc_64(mach_port_t dest_port,
                                                exception_behavior_t base_beh,
                                                mach_port_t thread_port,
                                                mach_port_t task_port,
                                                exception_type_t exception,
                                                const int64_t *code,
                                                mach_msg_type_number_t codeCnt,
                                                int *inout_flavor,
                                                const natural_t *old_state,
                                                mach_msg_type_number_t old_stateCnt,
                                                natural_t *out_new_state,
                                                mach_msg_type_number_t *inout_new_stateCnt) {
    if (!MACH_PORT_VALID(dest_port) || codeCnt > 2U || old_stateCnt > 1296U) {
        return KERN_INVALID_ARGUMENT;
    }
    mach_port_t reply_port = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply_port) != KERN_SUCCESS ||
        !MACH_PORT_VALID(reply_port)) {
        return KERN_FAILURE;
    }

#pragma pack(push, 4)
    typedef struct {
        mach_msg_header_t Head;
        NDR_record_t NDR;
        kern_return_t RetCode;
        int flavor;
        mach_msg_type_number_t new_stateCnt;
        natural_t new_state[1296];
        mach_msg_trailer_t trailer;
    } pt_fwd_reply_t;
#pragma pack(pop)

    union {
        uint8_t bytes[6144];
        pt_fwd_reply_t reply;
    } io_buf;
    memset(&io_buf, 0, sizeof(io_buf));
    size_t pos = 0;

    mach_msg_id_t req_id = 2407;
    mach_msg_id_t expected_reply_id = 2507;
    BOOL has_identity = YES;
    BOOL has_state = YES;
    if (base_beh == EXCEPTION_DEFAULT) {
        req_id = 2405;
        expected_reply_id = 2505;
        has_state = NO;
    } else if (base_beh == EXCEPTION_STATE) {
        req_id = 2406;
        expected_reply_id = 2506;
        has_identity = NO;
    }

    mach_msg_header_t hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.msgh_bits = has_identity
        ? (MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE))
        : MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    hdr.msgh_remote_port = dest_port;
    hdr.msgh_local_port = reply_port;
    hdr.msgh_id = req_id;
    memcpy(io_buf.bytes + pos, &hdr, sizeof(hdr));
    pos += sizeof(hdr);

    if (has_identity) {
        mach_msg_body_t body = { .msgh_descriptor_count = 2 };
        mach_msg_port_descriptor_t tdesc = {
            .name = thread_port,
            .disposition = MACH_MSG_TYPE_COPY_SEND,
            .type = MACH_MSG_PORT_DESCRIPTOR
        };
        mach_msg_port_descriptor_t kdesc = {
            .name = task_port,
            .disposition = MACH_MSG_TYPE_COPY_SEND,
            .type = MACH_MSG_PORT_DESCRIPTOR
        };
        memcpy(io_buf.bytes + pos, &body, sizeof(body));
        pos += sizeof(body);
        memcpy(io_buf.bytes + pos, &tdesc, sizeof(tdesc));
        pos += sizeof(tdesc);
        memcpy(io_buf.bytes + pos, &kdesc, sizeof(kdesc));
        pos += sizeof(kdesc);
    }

    NDR_record_t ndr = NDR_record;
    memcpy(io_buf.bytes + pos, &ndr, sizeof(ndr));
    pos += sizeof(ndr);
    memcpy(io_buf.bytes + pos, &exception, sizeof(exception));
    pos += sizeof(exception);
    memcpy(io_buf.bytes + pos, &codeCnt, sizeof(codeCnt));
    pos += sizeof(codeCnt);
    if (codeCnt > 0U && code != NULL) {
        size_t cb = (size_t)codeCnt * sizeof(int64_t);
        memcpy(io_buf.bytes + pos, code, cb);
        pos += cb;
    }
    if (has_state) {
        int flv = (inout_flavor != NULL) ? *inout_flavor : 0;
        memcpy(io_buf.bytes + pos, &flv, sizeof(flv));
        pos += sizeof(flv);
        memcpy(io_buf.bytes + pos, &old_stateCnt, sizeof(old_stateCnt));
        pos += sizeof(old_stateCnt);
        if (old_stateCnt > 0U && old_state != NULL) {
            size_t sb = (size_t)old_stateCnt * sizeof(natural_t);
            if (pos + sb > sizeof(io_buf.bytes)) {
                (void)mach_port_mod_refs(mach_task_self(), reply_port, MACH_PORT_RIGHT_RECEIVE, -1);
                return MIG_ARRAY_TOO_LARGE;
            }
            memcpy(io_buf.bytes + pos, old_state, sb);
            pos += sb;
        }
    }

    mach_msg_size_t send_sz = (mach_msg_size_t)pos;
    memcpy(io_buf.bytes + offsetof(mach_msg_header_t, msgh_size), &send_sz, sizeof(send_sz));

    mach_msg_return_t mr = mach_msg((mach_msg_header_t *)io_buf.bytes,
                                    MACH_SEND_MSG | MACH_RCV_MSG,
                                    send_sz,
                                    (mach_msg_size_t)sizeof(io_buf.reply),
                                    reply_port,
                                    MACH_MSG_TIMEOUT_NONE,
                                    MACH_PORT_NULL);
    (void)mach_port_mod_refs(mach_task_self(), reply_port, MACH_PORT_RIGHT_RECEIVE, -1);
    if (mr != MACH_MSG_SUCCESS) {
        return (kern_return_t)mr;
    }
    if ((io_buf.reply.Head.msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0) {
        mach_msg_destroy(&io_buf.reply.Head);
        return MIG_TYPE_ERROR;
    }
    if (io_buf.reply.Head.msgh_id != expected_reply_id ||
        io_buf.reply.Head.msgh_size < (mach_msg_size_t)sizeof(mig_reply_error_t)) {
        return (io_buf.reply.Head.msgh_id == MACH_NOTIFY_SEND_ONCE) ? MIG_SERVER_DIED : MIG_REPLY_MISMATCH;
    }
    if (io_buf.reply.RetCode != KERN_SUCCESS) {
        return io_buf.reply.RetCode;
    }
    if (has_state) {
        size_t state_hdr_sz = offsetof(pt_fwd_reply_t, new_state);
        if (io_buf.reply.Head.msgh_size < state_hdr_sz || io_buf.reply.new_stateCnt > 1296U ||
            io_buf.reply.Head.msgh_size < state_hdr_sz + (size_t)io_buf.reply.new_stateCnt * sizeof(natural_t)) {
            return MIG_TYPE_ERROR;
        }
        if (inout_flavor != NULL) {
            *inout_flavor = io_buf.reply.flavor;
        }
        if (out_new_state != NULL && inout_new_stateCnt != NULL) {
            mach_msg_type_number_t cap = *inout_new_stateCnt;
            mach_msg_type_number_t copy_cnt = (io_buf.reply.new_stateCnt < cap) ? io_buf.reply.new_stateCnt : cap;
            if (copy_cnt > 0U) {
                memcpy(out_new_state, io_buf.reply.new_state, (size_t)copy_cnt * sizeof(natural_t));
            }
            *inout_new_stateCnt = copy_cnt;
        }
    }
    return KERN_SUCCESS;
}

static BOOL pt_svc_forward_to_saved_bp_handler(const pt_svc_saved_exc_handler_t *saved,
                                               mach_port_t thread_port,
                                               mach_port_t task_port,
                                               exception_type_t exception,
                                               const int64_t *code,
                                               mach_msg_type_number_t codeCnt,
                                               int req_flavor,
                                               const uint8_t *req_old_state_bytes,
                                               mach_msg_type_number_t req_old_stateCnt,
                                               pt_mach_exc_reply_t *reply) {
    if (saved == NULL || !saved->valid || !MACH_PORT_VALID(saved->port)) {
        return NO;
    }
    exception_behavior_t base_beh = saved->behavior & ~((exception_behavior_t)MACH_EXCEPTION_MASK);
    if (base_beh != EXCEPTION_DEFAULT &&
        base_beh != EXCEPTION_STATE &&
        base_beh != EXCEPTION_STATE_IDENTITY) {
        return NO;
    }
    if ((base_beh == EXCEPTION_DEFAULT || base_beh == EXCEPTION_STATE_IDENTITY) &&
        (!MACH_PORT_VALID(thread_port) || !MACH_PORT_VALID(task_port))) {
        return NO;
    }
    BOOL want_64 = ((saved->behavior & (exception_behavior_t)MACH_EXCEPTION_CODES) != 0);

    int fwd_flavor = (saved->flavor != 0) ? (int)saved->flavor : req_flavor;
    natural_t fwd_old_state[1296] = {0};
    mach_msg_type_number_t fwd_old_cnt = 0;
    if (base_beh == EXCEPTION_STATE || base_beh == EXCEPTION_STATE_IDENTITY) {
        if (fwd_flavor == req_flavor) {
            fwd_old_cnt = (req_old_stateCnt <= 1296U) ? req_old_stateCnt : 1296U;
            if (fwd_old_cnt > 0U && req_old_state_bytes != NULL) {
                memcpy(fwd_old_state, req_old_state_bytes, (size_t)fwd_old_cnt * sizeof(natural_t));
            }
        } else {
#ifdef THREAD_STATE_NONE
            BOOL is_none_flavor = (fwd_flavor == THREAD_STATE_NONE);
#else
            BOOL is_none_flavor = (fwd_flavor == 13);
#endif
            if (!is_none_flavor && MACH_PORT_VALID(thread_port)) {
                fwd_old_cnt = 1296U;
                if (thread_get_state(thread_port, fwd_flavor, (thread_state_t)fwd_old_state, &fwd_old_cnt) != KERN_SUCCESS) {
                    return NO;
                }
            }
        }
    }

    natural_t fwd_new_state[1296] = {0};
    mach_msg_type_number_t fwd_new_cnt = 1296U;
    kern_return_t fwd_kr = KERN_FAILURE;

    if (want_64) {
        fwd_kr = pt_svc_forward_mach_exc_64(saved->port,
                                            base_beh,
                                            thread_port,
                                            task_port,
                                            exception,
                                            code,
                                            codeCnt,
                                            &fwd_flavor,
                                            fwd_old_state,
                                            fwd_old_cnt,
                                            fwd_new_state,
                                            &fwd_new_cnt);
    } else {
        exception_data_type_t code32[2] = {0, 0};
        for (mach_msg_type_number_t i = 0; i < codeCnt && i < 2U; i++) {
            code32[i] = (exception_data_type_t)code[i];
        }
        if (base_beh == EXCEPTION_DEFAULT) {
            fwd_kr = exception_raise(saved->port, thread_port, task_port, exception, code32, codeCnt);
        } else if (base_beh == EXCEPTION_STATE) {
            fwd_kr = exception_raise_state(saved->port,
                                           exception,
                                           code32,
                                           codeCnt,
                                           &fwd_flavor,
                                           (thread_state_t)fwd_old_state,
                                           fwd_old_cnt,
                                           (thread_state_t)fwd_new_state,
                                           &fwd_new_cnt);
        } else {
            fwd_kr = exception_raise_state_identity(saved->port,
                                                    thread_port,
                                                    task_port,
                                                    exception,
                                                    code32,
                                                    codeCnt,
                                                    &fwd_flavor,
                                                    (thread_state_t)fwd_old_state,
                                                    fwd_old_cnt,
                                                    (thread_state_t)fwd_new_state,
                                                    &fwd_new_cnt);
        }
    }

    if (fwd_kr != KERN_SUCCESS) {
        return NO;
    }

    if (base_beh != EXCEPTION_DEFAULT &&
        fwd_flavor == req_flavor &&
        fwd_new_cnt >= ARM_THREAD_STATE64_COUNT &&
        fwd_new_cnt <= 1296U) {
        reply->flavor = fwd_flavor;
        reply->new_stateCnt = fwd_new_cnt;
        memcpy(reply->new_state, fwd_new_state, (size_t)fwd_new_cnt * sizeof(natural_t));
    } else {
#ifdef THREAD_STATE_NONE
        BOOL is_none_out = (fwd_flavor == THREAD_STATE_NONE);
#else
        BOOL is_none_out = (fwd_flavor == 13);
#endif
        if (base_beh != EXCEPTION_DEFAULT && !is_none_out && fwd_new_cnt > 0U && MACH_PORT_VALID(thread_port)) {
            (void)thread_set_state(thread_port, fwd_flavor, (thread_state_t)fwd_new_state, fwd_new_cnt);
        }
        mach_msg_type_number_t cur_cnt = ARM_THREAD_STATE64_COUNT;
        if (MACH_PORT_VALID(thread_port) &&
            thread_get_state(thread_port, ARM_THREAD_STATE64, (thread_state_t)reply->new_state, &cur_cnt) == KERN_SUCCESS &&
            cur_cnt >= ARM_THREAD_STATE64_COUNT &&
            cur_cnt <= 1296U) {
            reply->flavor = req_flavor;
            reply->new_stateCnt = cur_cnt;
        } else {
            reply->flavor = req_flavor;
            reply->new_stateCnt = req_old_stateCnt;
            if (req_old_state_bytes != NULL && req_old_stateCnt <= 1296U) {
                memcpy(reply->new_state, req_old_state_bytes, (size_t)req_old_stateCnt * sizeof(natural_t));
            }
        }
    }

    reply->RetCode = KERN_SUCCESS;
    reply->Head.msgh_size = (mach_msg_size_t)(offsetof(pt_mach_exc_reply_t, new_state) +
                                              (size_t)reply->new_stateCnt * sizeof(natural_t));
    return YES;
}

static BOOL pt_svc_handle_exception_msg(const pt_mach_exc_req_t *req, pt_mach_exc_reply_t *reply) {
    memset(reply, 0, sizeof(*reply));
    reply->Head.msgh_bits = MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(req->Head.msgh_bits), 0);
    reply->Head.msgh_remote_port = req->Head.msgh_remote_port;
    reply->Head.msgh_local_port = MACH_PORT_NULL;
    reply->Head.msgh_id = req->Head.msgh_id + 100;
    reply->Head.msgh_reserved = 0;
    reply->Head.msgh_size = (mach_msg_size_t)sizeof(mig_reply_error_t);
    reply->NDR = NDR_record;
    reply->RetCode = KERN_FAILURE;

    mach_port_t req_thread = MACH_PORT_NULL;
    mach_port_t req_task = MACH_PORT_NULL;
    if ((req->Head.msgh_bits & MACH_MSGH_BITS_COMPLEX) != 0) {
        if (req->Head.msgh_size >= offsetof(pt_mach_exc_req_t, thread) + sizeof(req->thread) &&
            req->thread.type == MACH_MSG_PORT_DESCRIPTOR &&
            MACH_PORT_VALID(req->thread.name)) {
            req_thread = req->thread.name;
        }
        if (req->Head.msgh_size >= offsetof(pt_mach_exc_req_t, task) + sizeof(req->task) &&
            req->task.type == MACH_MSG_PORT_DESCRIPTOR &&
            MACH_PORT_VALID(req->task.name)) {
            req_task = req->task.name;
        }
    }

    if (req->Head.msgh_id != 2407) {
        pt_svc_dealloc_req_ports(req_thread, req_task);
        reply->RetCode = MIG_BAD_ID;
        return YES;
    }

    size_t req_prefix = offsetof(pt_mach_exc_req_t, code);
    if (req->Head.msgh_size < req_prefix || req->codeCnt > 2U) {
        pt_svc_dealloc_req_ports(req_thread, req_task);
        reply->RetCode = MIG_BAD_ARGUMENTS;
        return YES;
    }
    size_t code_bytes = (size_t)req->codeCnt * sizeof(int64_t);
    size_t tail_off = req_prefix + code_bytes;
    size_t min_tail = sizeof(int) + sizeof(mach_msg_type_number_t);
    if (req->Head.msgh_size < tail_off + min_tail) {
        pt_svc_dealloc_req_ports(req_thread, req_task);
        reply->RetCode = MIG_BAD_ARGUMENTS;
        return YES;
    }

    const uint8_t *tail = (const uint8_t *)req + tail_off;
    int flavor = 0;
    mach_msg_type_number_t old_stateCnt = 0;
    memcpy(&flavor, tail, sizeof(flavor));
    memcpy(&old_stateCnt, tail + sizeof(flavor), sizeof(old_stateCnt));

    if (flavor != ARM_THREAD_STATE64 || old_stateCnt < ARM_THREAD_STATE64_COUNT ||
        old_stateCnt > 1296U ||
        req->Head.msgh_size < tail_off + min_tail + (size_t)old_stateCnt * sizeof(natural_t)) {
        pt_svc_dealloc_req_ports(req_thread, req_task);
        reply->RetCode = KERN_FAILURE;
        return YES;
    }

    arm_thread_state64_t state;
    memcpy(&state, tail + min_tail, sizeof(state));

    uintptr_t pc = (uintptr_t)arm_thread_state64_get_pc(state);
    if (!pt_svc_is_registered_pc(pc)) {
        // Real debugger breakpoint / __builtin_trap / non-PlayTools brk:
        // forward cleanly to any saved thread or task breakpoint exception port first.
        mach_port_t svc_port = atomic_load_explicit(&s_svc_exc_port, memory_order_acquire);
        pt_svc_saved_exc_handler_t saved = pt_svc_copy_retained_thread_bp(req_thread);
        if (!saved.valid || !MACH_PORT_VALID(saved.port) || saved.port == svc_port) {
            pt_svc_release_send_right(saved.port);
            saved = pt_svc_copy_retained_task_bp();
        }
        BOOL forwarded = NO;
        if (saved.valid && MACH_PORT_VALID(saved.port) && saved.port != svc_port) {
            forwarded = pt_svc_forward_to_saved_bp_handler(&saved,
                                                             req_thread,
                                                             req_task,
                                                             req->exception,
                                                             req->code,
                                                             req->codeCnt,
                                                             flavor,
                                                             tail + min_tail,
                                                             old_stateCnt,
                                                             reply);
        }
        pt_svc_release_send_right(saved.port);
        pt_svc_dealloc_req_ports(req_thread, req_task);
        if (!forwarded) {
            reply->RetCode = KERN_FAILURE;
            reply->Head.msgh_size = (mach_msg_size_t)sizeof(mig_reply_error_t);
        }
        return YES;
    }

    int64_t x16 = (int64_t)PT_TS_X(state)[16];
    uint64_t in_x[8];
    for (int i = 0; i < 8; i++) {
        in_x[i] = PT_TS_X(state)[i];
    }
    uint64_t sp_args[2] = {0, 0};
    {
        uint64_t sp = PT_TS_SP(state);
        if (sp != 0 && pt_is_valid_user_pointer((const void *)(uintptr_t)sp)) {
            memcpy(&sp_args[0], (const void *)(uintptr_t)sp, sizeof(sp_args[0]));
            if (sp <= UINT64_MAX - sizeof(uint64_t) &&
                pt_is_valid_user_pointer((const void *)(uintptr_t)(sp + sizeof(uint64_t)))) {
                memcpy(&sp_args[1], (const void *)(uintptr_t)(sp + sizeof(uint64_t)), sizeof(sp_args[1]));
            }
        }
    }

    // Preserve faulting thread identity for thread_self_trap (-27) and SYS_thread_selfid (372)
    BOOL handled_faulting_thread_identity = NO;
    if (x16 == -27 && MACH_PORT_VALID(req_thread)) {
        PT_TS_X(state)[0] = (uint64_t)req_thread;
        pt_svc_dealloc_req_ports(MACH_PORT_NULL, req_task);
        handled_faulting_thread_identity = YES;
    } else if (x16 == 372 && MACH_PORT_VALID(req_thread)) {
        thread_identifier_info_data_t tinfo;
        mach_msg_type_number_t tcnt = THREAD_IDENTIFIER_INFO_COUNT;
        if (thread_info(req_thread, THREAD_IDENTIFIER_INFO, (thread_info_t)&tinfo, &tcnt) == KERN_SUCCESS) {
            PT_TS_X(state)[0] = (uint64_t)tinfo.thread_id;
            PT_TS_CPSR(state) &= ~PT_ARM64_CPSR_C;
            handled_faulting_thread_identity = YES;
        }
        pt_svc_dealloc_req_ports(req_thread, req_task);
    } else {
        pt_svc_dealloc_req_ports(req_thread, req_task);
    }

    BOOL passthrough = atomic_load_explicit(&s_svc_safe_mode_passthrough, memory_order_acquire) ||
                       !pt_is_bypass_enabled() ||
                       (x16 < 0);
    if (handled_faulting_thread_identity) {
        // Already populated x0 (and CPSR.C if applicable) on state from req_thread.
    } else if (passthrough) {
        BOOL intercept_mach_msg = ((x16 == -31 || x16 == -32 || x16 == -47) &&
                                   !atomic_load_explicit(&s_svc_safe_mode_passthrough, memory_order_acquire) &&
                                   pt_is_bypass_enabled() &&
                                   !pt_is_effective_system_or_playtools_caller((const void *)pc));
        bool mig_sending = false;
        bool mig_receiving = false;
        bool mig_had_req = false;
        int mig_req_id = 0;
        int32_t mig_req_flavor = 0;
        bool mig_target_is_self = false;
        mach_port_t mig_reply_port = MACH_PORT_NULL;
        void *mig_rcv_buf = NULL;
        size_t mig_rcv_cap = 0;
        mach_port_t mig_rcv_name = MACH_PORT_NULL;

        if (intercept_mach_msg && in_x[0] != 0 && pt_is_valid_user_pointer((const void *)(uintptr_t)in_x[0])) {
            if (x16 == -31 || x16 == -32) {
                // mach_msg_trap / mach_msg_overwrite_trap(msg, option, send_size, rcv_size, rcv_name, timeout, notify[, rcv_msg, rcv_limit@[sp]])
                mach_msg_header_t *hdr = (mach_msg_header_t *)(uintptr_t)in_x[0];
                mach_msg_option_t option = (mach_msg_option_t)in_x[1];
                mach_msg_size_t send_size = (mach_msg_size_t)in_x[2];
                mach_msg_size_t rcv_size = (mach_msg_size_t)in_x[3];
                mig_rcv_name = (mach_port_t)in_x[4];
                mig_sending = (option & MACH_SEND_MSG) != 0;
                mig_receiving = (option & MACH_RCV_MSG) != 0;
                mig_rcv_buf = hdr;
                mig_rcv_cap = (size_t)rcv_size;
                if (x16 == -32 && in_x[7] != 0 && pt_is_valid_user_pointer((const void *)(uintptr_t)in_x[7])) {
                    mig_rcv_buf = (void *)(uintptr_t)in_x[7];
                    uint64_t sp = PT_TS_SP(state);
                    if (sp != 0 && pt_is_valid_user_pointer((const void *)(uintptr_t)sp)) {
                        uint32_t rcv_limit = 0;
                        memcpy(&rcv_limit, (const void *)(uintptr_t)sp, sizeof(rcv_limit));
                        mig_rcv_cap = (size_t)rcv_limit;
                    }
                }
                if (mig_sending) {
                    mach_msg_size_t eff_sz = (send_size > 0) ? send_size : hdr->msgh_size;
                    mig_req_id = hdr->msgh_id;
                    mig_reply_port = hdr->msgh_local_port;
                    mig_had_req = pt_mig_prepare_trap_request(hdr,
                                                              hdr->msgh_bits,
                                                              eff_sz,
                                                              hdr->msgh_remote_port,
                                                              mig_reply_port,
                                                              mig_req_id,
                                                              mig_receiving,
                                                              &mig_req_flavor,
                                                              &mig_target_is_self);
                }
            } else if (x16 == -47) {
                // mach_msg2_trap(data, option64, bits_and_send_sz, remote_and_local, voucher_and_id, desc_and_rcv_name, rcv_size, prio_timeout)
                void *data = (void *)(uintptr_t)in_x[0];
                uint64_t option64 = in_x[1];
                bool is_vector = (option64 & 0x0000000100000000ULL) != 0;
                mig_sending = !is_vector && ((option64 & MACH_SEND_MSG) != 0);
                mig_receiving = !is_vector && ((option64 & MACH_RCV_MSG) != 0);
                mig_rcv_buf = data;
                mig_rcv_cap = (size_t)(uint32_t)(in_x[6] & 0xFFFFFFFFULL);
                mig_rcv_name = (mach_port_t)(in_x[5] >> 32);
                if (mig_sending) {
                    const mach_msg_header_t *hdr = (const mach_msg_header_t *)data;
                    mach_msg_bits_t bits = (mach_msg_bits_t)(in_x[2] & 0xFFFFFFFFU);
                    mach_msg_size_t send_size = (mach_msg_size_t)(in_x[2] >> 32);
                    if (send_size == 0) {
                        send_size = hdr->msgh_size;
                    }
                    mach_port_t remote_port = (mach_port_t)(in_x[3] & 0xFFFFFFFFU);
                    mach_port_t local_port = (mach_port_t)(in_x[3] >> 32);
                    int parsed_id = (int)(in_x[4] >> 32);
                    if (parsed_id == 0) {
                        parsed_id = hdr->msgh_id;
                    }
                    if (local_port == MACH_PORT_NULL) {
                        local_port = hdr->msgh_local_port;
                    }
                    mig_req_id = parsed_id;
                    mig_reply_port = local_port;
                    mig_had_req = pt_mig_prepare_trap_request(data,
                                                              bits,
                                                              send_size,
                                                              remote_port,
                                                              local_port,
                                                              parsed_id,
                                                              mig_receiving,
                                                              &mig_req_flavor,
                                                              &mig_target_is_self);
                }
            }
        }

        uint64_t out_x[2] = {0, 0};
        bool carry = false;
        if (x16 == -32) {
            mach_msg_return_t mr_ov = mach_msg_overwrite_trap((mach_msg_header_t *)(uintptr_t)in_x[0],
                                                              (mach_msg_option_t)in_x[1],
                                                              (mach_msg_size_t)in_x[2],
                                                              (mach_msg_size_t)in_x[3],
                                                              (mach_port_name_t)in_x[4],
                                                              (mach_msg_timeout_t)in_x[5],
                                                              (mach_port_name_t)in_x[6],
                                                              (mach_msg_header_t *)(uintptr_t)in_x[7],
                                                              (mach_msg_size_t)sp_args[0]);
            out_x[0] = (uint64_t)(int64_t)mr_ov;
        } else {
            pt_raw_arm64_svc80_sp(x16, in_x, sp_args[0], sp_args[1], out_x, &carry);
        }
        PT_TS_X(state)[0] = out_x[0];
        PT_TS_X(state)[1] = out_x[1];
        if (intercept_mach_msg && (mig_sending || mig_receiving)) {
            pt_mig_finish_trap_reply(mig_rcv_buf,
                                     mig_rcv_cap,
                                     mig_rcv_name,
                                     mig_sending,
                                     mig_receiving,
                                     mig_had_req,
                                     mig_req_id,
                                     mig_req_flavor,
                                     mig_target_is_self,
                                     mig_reply_port,
                                     (kern_return_t)(int32_t)out_x[0],
                                     (const void *)pc);
        }
        if (x16 >= 0) {
            if (carry) {
                PT_TS_CPSR(state) |= PT_ARM64_CPSR_C;
            } else {
                PT_TS_CPSR(state) &= ~PT_ARM64_CPSR_C;
            }
        }
    } else {
        uintptr_t args[8] = {0};
        int sys_num = (int)x16;
        if (sys_num == 0 || sys_num == 198) {
            sys_num = (int)in_x[0];
            for (size_t i = 0; i < 7U; i++) {
                args[i] = (uintptr_t)in_x[i + 1U];
            }
            args[7] = (uintptr_t)sp_args[0];
        } else {
            for (size_t i = 0; i < 8U; i++) {
                args[i] = (uintptr_t)in_x[i];
            }
        }
        BOOL handled = NO;
        errno = 0;
        intptr_t ret = pt_syscall_dispatch_with_caller(sys_num, args, (const void *)pc, &handled);
        if (handled) {
            if (ret == -1 && errno != 0) {
                PT_TS_X(state)[0] = (uint64_t)(unsigned int)errno;
                PT_TS_CPSR(state) |= PT_ARM64_CPSR_C;
            } else {
                PT_TS_X(state)[0] = (uint64_t)ret;
                PT_TS_CPSR(state) &= ~PT_ARM64_CPSR_C;
            }
        } else {
            uint64_t out_x[2] = {0, 0};
            bool carry = false;
            pt_raw_arm64_svc80_sp(x16, in_x, sp_args[0], sp_args[1], out_x, &carry);
            PT_TS_X(state)[0] = out_x[0];
            PT_TS_X(state)[1] = out_x[1];
            if (carry) {
                PT_TS_CPSR(state) |= PT_ARM64_CPSR_C;
            } else {
                PT_TS_CPSR(state) &= ~PT_ARM64_CPSR_C;
            }
        }
    }

    uintptr_t next_pc = pc + 4U;
#if __has_feature(ptrauth_calls)
    void *next_fptr = ptrauth_sign_unauthenticated((void *)next_pc, ptrauth_key_function_pointer, 0);
#else
    void *next_fptr = (void *)next_pc;
#endif
    arm_thread_state64_set_pc_fptr(state, next_fptr);

    reply->RetCode = KERN_SUCCESS;
    reply->flavor = flavor;
    reply->new_stateCnt = old_stateCnt;
    memcpy(reply->new_state, tail + min_tail, (size_t)old_stateCnt * sizeof(natural_t));
    memcpy(reply->new_state, &state, sizeof(state));
    reply->Head.msgh_size = (mach_msg_size_t)(offsetof(pt_mach_exc_reply_t, new_state) +
                                              (size_t)old_stateCnt * sizeof(natural_t));
    return YES;
}

static void *pt_svc_exc_server_thread(void *arg) {
    (void)arg;
    pthread_setname_np("app.makedie.playtools.svc_exc");

    pt_mach_exc_req_t req;
    pt_mach_exc_reply_t reply;
    for (;;) {
        memset(&req, 0, sizeof(req));
        mach_msg_return_t mr = mach_msg(&req.Head,
                                        MACH_RCV_MSG | MACH_RCV_LARGE,
                                        0,
                                        (mach_msg_size_t)sizeof(req),
                                        atomic_load_explicit(&s_svc_exc_port, memory_order_acquire),
                                        MACH_MSG_TIMEOUT_NONE,
                                        MACH_PORT_NULL);
        if (mr != MACH_MSG_SUCCESS) {
            if (mr == MACH_RCV_PORT_DIED || mr == MACH_RCV_PORT_CHANGED || mr == MACH_RCV_INVALID_NAME) {
                break;
            }
            continue;
        }
        if (pt_svc_handle_exception_msg(&req, &reply) &&
            MACH_PORT_VALID(reply.Head.msgh_remote_port)) {
            mach_msg_return_t sr = mach_msg(&reply.Head,
                                            MACH_SEND_MSG,
                                            reply.Head.msgh_size,
                                            0,
                                            MACH_PORT_NULL,
                                            MACH_MSG_TIMEOUT_NONE,
                                            MACH_PORT_NULL);
            if (sr != MACH_MSG_SUCCESS) {
                mach_msg_destroy(&reply.Head);
            }
        }
    }
    return NULL;
}

static BOOL pt_svc_install_exception_handler(void) {
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
    if (kr != KERN_SUCCESS || !MACH_PORT_VALID(port)) {
        return NO;
    }
    kr = mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        mach_port_destruct(mach_task_self(), port, 0, 0);
        return NO;
    }

    atomic_store_explicit(&s_svc_exc_port, port, memory_order_release);
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    int prc = pthread_create(&s_svc_exc_thread, &attr, pt_svc_exc_server_thread, NULL);
    pthread_attr_destroy(&attr);
    if (prc != 0) {
        atomic_store_explicit(&s_svc_exc_port, MACH_PORT_NULL, memory_order_release);
        mach_port_destruct(mach_task_self(), port, -1, 0);
        return NO;
    }

    exception_mask_t old_masks[EXC_TYPES_COUNT] = {0};
    mach_msg_type_number_t old_count = EXC_TYPES_COUNT;
    exception_handler_t old_handlers[EXC_TYPES_COUNT] = {0};
    exception_behavior_t old_behaviors[EXC_TYPES_COUNT] = {0};
    thread_state_flavor_t old_flavors[EXC_TYPES_COUNT] = {0};

    kr = pt_orig_task_swap_exception_ports(
        mach_task_self(),
        EXC_MASK_BREAKPOINT,
        port,
        (exception_behavior_t)((unsigned int)EXCEPTION_STATE_IDENTITY | (unsigned int)MACH_EXCEPTION_CODES),
        ARM_THREAD_STATE64,
        old_masks,
        &old_count,
        old_handlers,
        old_behaviors,
        old_flavors);
    pt_svc_saved_exc_handler_t pre_bp = {0};
    for (mach_msg_type_number_t i = 0; i < old_count && i < EXC_TYPES_COUNT; i++) {
        if (kr == KERN_SUCCESS &&
            !pre_bp.valid &&
            (old_masks[i] & (exception_mask_t)EXC_MASK_BREAKPOINT) != 0 &&
            MACH_PORT_VALID(old_handlers[i]) &&
            old_handlers[i] != port) {
            pre_bp.valid = YES;
            pre_bp.mask = old_masks[i] & (exception_mask_t)EXC_MASK_BREAKPOINT;
            pre_bp.port = old_handlers[i];
            pre_bp.behavior = old_behaviors[i];
            pre_bp.flavor = old_flavors[i];
            continue;
        }
        if (MACH_PORT_VALID(old_handlers[i]) && old_handlers[i] != port) {
            mach_port_deallocate(mach_task_self(), old_handlers[i]);
        }
    }
    if (kr != KERN_SUCCESS) {
        pt_svc_release_send_right(pre_bp.port);
        atomic_store_explicit(&s_svc_exc_port, MACH_PORT_NULL, memory_order_release);
        mach_port_destruct(mach_task_self(), port, -1, 0);
        return NO;
    }
    os_unfair_lock_lock(&s_svc_exc_snapshot_lock);
    pt_svc_release_send_right(s_saved_task_bp_handler.port);
    s_saved_task_bp_handler = pre_bp;
    os_unfair_lock_unlock(&s_svc_exc_snapshot_lock);
    if (&pt_orig_task_get_exception_ports_info != NULL) {
        exception_mask_t q_masks[EXC_TYPES_COUNT] = {0};
        mach_msg_type_number_t q_cnt = EXC_TYPES_COUNT;
        ipc_info_port_t q_info[EXC_TYPES_COUNT] = {{0, 0}};
        exception_behavior_t q_beh[EXC_TYPES_COUNT] = {0};
        thread_state_flavor_t q_flav[EXC_TYPES_COUNT] = {0};
        if (pt_orig_task_get_exception_ports_info(mach_task_self(),
                                                  EXC_MASK_BREAKPOINT,
                                                  q_masks,
                                                  &q_cnt,
                                                  q_info,
                                                  q_beh,
                                                  q_flav) == KERN_SUCCESS) {
            for (mach_msg_type_number_t i = 0; i < q_cnt && i < EXC_TYPES_COUNT; i++) {
                if ((q_masks[i] & (exception_mask_t)EXC_MASK_BREAKPOINT) != 0 &&
                    q_info[i].iip_port_object != 0U) {
                    s_svc_exc_iip = q_info[i];
                    atomic_store_explicit(&s_svc_exc_iip_valid, true, memory_order_release);
                    break;
                }
            }
        }
    }
    return YES;
}

#endif /* defined(__arm64__) || defined(__aarch64__) */

// MARK: - Exception Port Preservation Interposers

static kern_return_t pt_task_set_exception_ports(task_t task,
                                                 exception_mask_t exception_mask,
                                                 mach_port_t new_port,
                                                 exception_behavior_t behavior,
                                                 thread_state_flavor_t new_flavor) {
    if (atomic_load_explicit(&s_svc_interceptor_active, memory_order_acquire) &&
        task == mach_task_self() &&
        (exception_mask & EXC_MASK_BREAKPOINT) != 0 &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        mach_port_t retained_new = pt_svc_retain_send_right(new_port);
        if (MACH_PORT_VALID(new_port) && !MACH_PORT_VALID(retained_new)) {
            return KERN_INVALID_RIGHT;
        }
        exception_mask_t filtered = exception_mask & ~((exception_mask_t)EXC_MASK_BREAKPOINT);
        if (filtered != 0) {
            kern_return_t kr = pt_orig_task_set_exception_ports(task, filtered, new_port, behavior, new_flavor);
            if (kr != KERN_SUCCESS) {
                pt_svc_release_send_right(retained_new);
                return kr;
            }
        }
        os_unfair_lock_lock(&s_svc_exc_snapshot_lock);
        pt_svc_swap_saved_slot_locked(&s_saved_task_bp_handler, exception_mask, retained_new, behavior, new_flavor, NULL);
        os_unfair_lock_unlock(&s_svc_exc_snapshot_lock);
        return KERN_SUCCESS;
    }
    return pt_orig_task_set_exception_ports(task, exception_mask, new_port, behavior, new_flavor);
}

static kern_return_t pt_task_swap_exception_ports(task_t task,
                                                  exception_mask_t exception_mask,
                                                  mach_port_t new_port,
                                                  exception_behavior_t behavior,
                                                  thread_state_flavor_t new_flavor,
                                                  exception_mask_array_t masks,
                                                  mach_msg_type_number_t *masksCnt,
                                                  exception_handler_array_t old_handlers,
                                                  exception_behavior_array_t old_behaviors,
                                                  exception_flavor_array_t old_flavors) {
    if (atomic_load_explicit(&s_svc_interceptor_active, memory_order_acquire) &&
        task == mach_task_self() &&
        (exception_mask & EXC_MASK_BREAKPOINT) != 0 &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        BOOL has_out_arrays = (masks != NULL && masksCnt != NULL &&
                               old_handlers != NULL && old_behaviors != NULL && old_flavors != NULL);
        mach_msg_type_number_t caller_capacity = (masksCnt != NULL) ? *masksCnt : 0;
        mach_port_t retained_new = pt_svc_retain_send_right(new_port);
        if (MACH_PORT_VALID(new_port) && !MACH_PORT_VALID(retained_new)) {
            return KERN_INVALID_RIGHT;
        }
        pt_svc_local_exc_ports_t local = {0};
        local.count = EXC_TYPES_COUNT;
        exception_mask_t filtered = exception_mask & ~((exception_mask_t)EXC_MASK_BREAKPOINT);
        if (filtered != 0) {
            kern_return_t kr = pt_orig_task_swap_exception_ports(
                task,
                filtered,
                new_port,
                behavior,
                new_flavor,
                has_out_arrays ? local.masks : masks,
                has_out_arrays ? &local.count : masksCnt,
                has_out_arrays ? local.handlers : old_handlers,
                has_out_arrays ? local.behaviors : old_behaviors,
                has_out_arrays ? local.flavors : old_flavors);
            if (kr != KERN_SUCCESS) {
                pt_svc_release_send_right(retained_new);
                return kr;
            }
        } else {
            local.count = 0;
        }
        pt_svc_saved_exc_handler_t prev_bp = {0};
        os_unfair_lock_lock(&s_svc_exc_snapshot_lock);
        pt_svc_swap_saved_slot_locked(&s_saved_task_bp_handler, exception_mask, retained_new, behavior, new_flavor, &prev_bp);
        os_unfair_lock_unlock(&s_svc_exc_snapshot_lock);
        mach_port_t svc_port = atomic_load_explicit(&s_svc_exc_port, memory_order_acquire);
        if (has_out_arrays) {
            pt_svc_publish_redacted_exc_ports(svc_port,
                                              YES,
                                              &prev_bp,
                                              &local,
                                              caller_capacity,
                                              masks,
                                              masksCnt,
                                              old_handlers,
                                              old_behaviors,
                                              old_flavors);
        } else {
            pt_svc_redact_exc_ports_array(svc_port,
                                          YES,
                                          &prev_bp,
                                          caller_capacity,
                                          masks,
                                          masksCnt,
                                          old_handlers,
                                          old_behaviors,
                                          old_flavors);
        }
        return KERN_SUCCESS;
    }
    return pt_orig_task_swap_exception_ports(task,
                                             exception_mask,
                                             new_port,
                                             behavior,
                                             new_flavor,
                                             masks,
                                             masksCnt,
                                             old_handlers,
                                             old_behaviors,
                                             old_flavors);
}

static kern_return_t pt_thread_set_exception_ports(thread_act_t thread,
                                                   exception_mask_t exception_mask,
                                                   mach_port_t new_port,
                                                   exception_behavior_t behavior,
                                                   thread_state_flavor_t new_flavor) {
    if (atomic_load_explicit(&s_svc_interceptor_active, memory_order_acquire) &&
        (exception_mask & EXC_MASK_BREAKPOINT) != 0 &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        mach_port_t retained_new = pt_svc_retain_send_right(new_port);
        if (MACH_PORT_VALID(new_port) && !MACH_PORT_VALID(retained_new)) {
            return KERN_INVALID_RIGHT;
        }
        exception_mask_t filtered = exception_mask & ~((exception_mask_t)EXC_MASK_BREAKPOINT);
        if (filtered != 0) {
            kern_return_t kr = pt_orig_thread_set_exception_ports(thread, filtered, new_port, behavior, new_flavor);
            if (kr != KERN_SUCCESS) {
                pt_svc_release_send_right(retained_new);
                return kr;
            }
        }
        pt_svc_update_thread_bp(thread, exception_mask, retained_new, behavior, new_flavor, NULL);
        return KERN_SUCCESS;
    }
    return pt_orig_thread_set_exception_ports(thread, exception_mask, new_port, behavior, new_flavor);
}

static kern_return_t pt_thread_swap_exception_ports(thread_act_t thread,
                                                    exception_mask_t exception_mask,
                                                    mach_port_t new_port,
                                                    exception_behavior_t behavior,
                                                    thread_state_flavor_t new_flavor,
                                                    exception_mask_array_t masks,
                                                    mach_msg_type_number_t *masksCnt,
                                                    exception_handler_array_t old_handlers,
                                                    exception_behavior_array_t old_behaviors,
                                                    exception_flavor_array_t old_flavors) {
    if (atomic_load_explicit(&s_svc_interceptor_active, memory_order_acquire) &&
        (exception_mask & EXC_MASK_BREAKPOINT) != 0 &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        BOOL has_out_arrays = (masks != NULL && masksCnt != NULL &&
                               old_handlers != NULL && old_behaviors != NULL && old_flavors != NULL);
        mach_msg_type_number_t caller_capacity = (masksCnt != NULL) ? *masksCnt : 0;
        mach_port_t retained_new = pt_svc_retain_send_right(new_port);
        if (MACH_PORT_VALID(new_port) && !MACH_PORT_VALID(retained_new)) {
            return KERN_INVALID_RIGHT;
        }
        pt_svc_local_exc_ports_t local = {0};
        local.count = EXC_TYPES_COUNT;
        exception_mask_t filtered = exception_mask & ~((exception_mask_t)EXC_MASK_BREAKPOINT);
        if (filtered != 0) {
            kern_return_t kr = pt_orig_thread_swap_exception_ports(
                thread,
                filtered,
                new_port,
                behavior,
                new_flavor,
                has_out_arrays ? local.masks : masks,
                has_out_arrays ? &local.count : masksCnt,
                has_out_arrays ? local.handlers : old_handlers,
                has_out_arrays ? local.behaviors : old_behaviors,
                has_out_arrays ? local.flavors : old_flavors);
            if (kr != KERN_SUCCESS) {
                pt_svc_release_send_right(retained_new);
                return kr;
            }
        } else {
            local.count = 0;
        }
        pt_svc_saved_exc_handler_t prev_bp = {0};
        pt_svc_update_thread_bp(thread, exception_mask, retained_new, behavior, new_flavor, &prev_bp);
        mach_port_t svc_port = atomic_load_explicit(&s_svc_exc_port, memory_order_acquire);
        if (has_out_arrays) {
            pt_svc_publish_redacted_exc_ports(svc_port,
                                              YES,
                                              &prev_bp,
                                              &local,
                                              caller_capacity,
                                              masks,
                                              masksCnt,
                                              old_handlers,
                                              old_behaviors,
                                              old_flavors);
        } else {
            pt_svc_redact_exc_ports_array(svc_port,
                                          YES,
                                          &prev_bp,
                                          caller_capacity,
                                          masks,
                                          masksCnt,
                                          old_handlers,
                                          old_behaviors,
                                          old_flavors);
        }
        return KERN_SUCCESS;
    }
    return pt_orig_thread_swap_exception_ports(thread,
                                               exception_mask,
                                               new_port,
                                               behavior,
                                               new_flavor,
                                               masks,
                                               masksCnt,
                                               old_handlers,
                                               old_behaviors,
                                               old_flavors);
}

static kern_return_t pt_task_get_exception_ports(task_t task,
                                                 exception_mask_t exception_mask,
                                                 exception_mask_array_t masks,
                                                 mach_msg_type_number_t *masksCnt,
                                                 exception_handler_array_t old_handlers,
                                                 exception_behavior_array_t old_behaviors,
                                                 exception_flavor_array_t old_flavors) {
    BOOL should_redact = (atomic_load_explicit(&s_svc_interceptor_active, memory_order_acquire) &&
                          !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    BOOL has_out_arrays = (masks != NULL && masksCnt != NULL &&
                           old_handlers != NULL && old_behaviors != NULL && old_flavors != NULL);
    if (!should_redact || !has_out_arrays) {
        return pt_orig_task_get_exception_ports(task,
                                                exception_mask,
                                                masks,
                                                masksCnt,
                                                old_handlers,
                                                old_behaviors,
                                                old_flavors);
    }
    mach_msg_type_number_t caller_capacity = *masksCnt;
    pt_svc_local_exc_ports_t local = {0};
    local.count = EXC_TYPES_COUNT;
    kern_return_t kr = pt_orig_task_get_exception_ports(task,
                                                        exception_mask,
                                                        local.masks,
                                                        &local.count,
                                                        local.handlers,
                                                        local.behaviors,
                                                        local.flavors);
    if (kr == KERN_SUCCESS) {
        mach_port_t svc_port = atomic_load_explicit(&s_svc_exc_port, memory_order_acquire);
        pt_svc_saved_exc_handler_t saved = pt_svc_copy_retained_task_bp();
        BOOL inject_missing = (task == mach_task_self() &&
                               (exception_mask & (exception_mask_t)EXC_MASK_BREAKPOINT) != 0);
        pt_svc_publish_redacted_exc_ports(svc_port,
                                          inject_missing,
                                          &saved,
                                          &local,
                                          caller_capacity,
                                          masks,
                                          masksCnt,
                                          old_handlers,
                                          old_behaviors,
                                          old_flavors);
    }
    return kr;
}

static kern_return_t pt_thread_get_exception_ports(thread_act_t thread,
                                                   exception_mask_t exception_mask,
                                                   exception_mask_array_t masks,
                                                   mach_msg_type_number_t *masksCnt,
                                                   exception_handler_array_t old_handlers,
                                                   exception_behavior_array_t old_behaviors,
                                                   exception_flavor_array_t old_flavors) {
    BOOL should_redact = (atomic_load_explicit(&s_svc_interceptor_active, memory_order_acquire) &&
                          !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0)));
    BOOL has_out_arrays = (masks != NULL && masksCnt != NULL &&
                           old_handlers != NULL && old_behaviors != NULL && old_flavors != NULL);
    if (!should_redact || !has_out_arrays) {
        return pt_orig_thread_get_exception_ports(thread,
                                                  exception_mask,
                                                  masks,
                                                  masksCnt,
                                                  old_handlers,
                                                  old_behaviors,
                                                  old_flavors);
    }
    mach_msg_type_number_t caller_capacity = *masksCnt;
    pt_svc_local_exc_ports_t local = {0};
    local.count = EXC_TYPES_COUNT;
    kern_return_t kr = pt_orig_thread_get_exception_ports(thread,
                                                          exception_mask,
                                                          local.masks,
                                                          &local.count,
                                                          local.handlers,
                                                          local.behaviors,
                                                          local.flavors);
    if (kr == KERN_SUCCESS) {
        mach_port_t svc_port = atomic_load_explicit(&s_svc_exc_port, memory_order_acquire);
        pt_svc_saved_exc_handler_t saved = pt_svc_copy_retained_thread_bp(thread);
        BOOL inject_missing = ((exception_mask & (exception_mask_t)EXC_MASK_BREAKPOINT) != 0);
        pt_svc_publish_redacted_exc_ports(svc_port,
                                          inject_missing,
                                          &saved,
                                          &local,
                                          caller_capacity,
                                          masks,
                                          masksCnt,
                                          old_handlers,
                                          old_behaviors,
                                          old_flavors);
    }
    return kr;
}

__attribute__((visibility("hidden")))
BOOL pt_svc_record_bp_handler_from_mig(BOOL is_thread,
                                       mach_port_t target_port,
                                       exception_mask_t orig_mask,
                                       mach_port_t new_port,
                                       exception_behavior_t behavior,
                                       thread_state_flavor_t flavor) {
    if (!atomic_load_explicit(&s_svc_interceptor_active, memory_order_acquire) ||
        (orig_mask & (exception_mask_t)EXC_MASK_BREAKPOINT) == 0) {
        return NO;
    }
    mach_port_t retained_new = pt_svc_retain_send_right(new_port);
    if (is_thread) {
        pt_svc_update_thread_bp(target_port, orig_mask, retained_new, behavior, flavor, NULL);
    } else {
        os_unfair_lock_lock(&s_svc_exc_snapshot_lock);
        pt_svc_swap_saved_slot_locked(&s_saved_task_bp_handler, orig_mask, retained_new, behavior, flavor, NULL);
        os_unfair_lock_unlock(&s_svc_exc_snapshot_lock);
    }
    return YES;
}

__attribute__((visibility("hidden")))
void pt_svc_redact_exc_ports_info_arrays(BOOL is_thread,
                                         mach_port_t target_port,
                                         exception_mask_t *masks,
                                         mach_msg_type_number_t *masksCnt,
                                         ipc_info_port_t *handlers_info,
                                         exception_behavior_t *behaviors,
                                         thread_state_flavor_t *flavors) {
    if (!atomic_load_explicit(&s_svc_interceptor_active, memory_order_acquire) ||
        masks == NULL || masksCnt == NULL || handlers_info == NULL ||
        behaviors == NULL || flavors == NULL) {
        return;
    }
    mach_msg_type_number_t count = (*masksCnt < (mach_msg_type_number_t)EXC_TYPES_COUNT)
        ? *masksCnt
        : (mach_msg_type_number_t)EXC_TYPES_COUNT;
    bool iip_known = atomic_load_explicit(&s_svc_exc_iip_valid, memory_order_acquire);
    pt_svc_saved_exc_handler_t saved = is_thread
        ? pt_svc_copy_retained_thread_bp(target_port)
        : pt_svc_copy_retained_task_bp();
    BOOL has_saved = (saved.valid && MACH_PORT_VALID(saved.port));
    mach_msg_type_number_t write_idx = 0;
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        BOOL matches_svc = NO;
        if ((masks[i] & (exception_mask_t)EXC_MASK_BREAKPOINT) != 0) {
            if (iip_known && s_svc_exc_iip.iip_port_object != 0U) {
                matches_svc = (handlers_info[i].iip_port_object == s_svc_exc_iip.iip_port_object);
            } else {
                matches_svc = (behaviors[i] == (exception_behavior_t)((unsigned int)EXCEPTION_STATE_IDENTITY | (unsigned int)MACH_EXCEPTION_CODES) &&
                               flavors[i] == ARM_THREAD_STATE64);
            }
        }
        if (matches_svc) {
            exception_mask_t rem = masks[i] & ~((exception_mask_t)EXC_MASK_BREAKPOINT);
            if (rem != 0) {
                masks[write_idx] = rem;
                handlers_info[write_idx] = handlers_info[i];
                behaviors[write_idx] = behaviors[i];
                flavors[write_idx] = flavors[i];
                write_idx++;
            }
            continue;
        }
        if (write_idx != i) {
            masks[write_idx] = masks[i];
            handlers_info[write_idx] = handlers_info[i];
            behaviors[write_idx] = behaviors[i];
            flavors[write_idx] = flavors[i];
        }
        write_idx++;
    }
    if (has_saved && write_idx < (mach_msg_type_number_t)EXC_TYPES_COUNT) {
        masks[write_idx] = (exception_mask_t)EXC_MASK_BREAKPOINT;
        handlers_info[write_idx] = (ipc_info_port_t){ 0U, 0U };
        behaviors[write_idx] = saved.behavior;
        flavors[write_idx] = saved.flavor;
        write_idx++;
    }
    pt_svc_release_send_right(saved.port);
    *masksCnt = write_idx;
}

static kern_return_t pt_task_get_exception_ports_info(mach_port_t port,
                                                      exception_mask_t exception_mask,
                                                      exception_mask_array_t masks,
                                                      mach_msg_type_number_t *masksCnt,
                                                      exception_handler_info_array_t old_handlers_info,
                                                      exception_behavior_array_t old_behaviors,
                                                      exception_flavor_array_t old_flavors) {
    if (&pt_orig_task_get_exception_ports_info == NULL) {
        return KERN_NOT_SUPPORTED;
    }
    kern_return_t kr = pt_orig_task_get_exception_ports_info(
        port, exception_mask, masks, masksCnt, old_handlers_info, old_behaviors, old_flavors);
    if (kr == KERN_SUCCESS &&
        atomic_load_explicit(&s_svc_interceptor_active, memory_order_acquire) &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        pt_svc_redact_exc_ports_info_arrays(NO, port, masks, masksCnt, old_handlers_info, old_behaviors, old_flavors);
    }
    return kr;
}

static kern_return_t pt_thread_get_exception_ports_info(mach_port_t port,
                                                        exception_mask_t exception_mask,
                                                        exception_mask_array_t masks,
                                                        mach_msg_type_number_t *masksCnt,
                                                        exception_handler_info_array_t old_handlers_info,
                                                        exception_behavior_array_t old_behaviors,
                                                        exception_flavor_array_t old_flavors) {
    if (&pt_orig_thread_get_exception_ports_info == NULL) {
        return KERN_NOT_SUPPORTED;
    }
    kern_return_t kr = pt_orig_thread_get_exception_ports_info(
        port, exception_mask, masks, masksCnt, old_handlers_info, old_behaviors, old_flavors);
    if (kr == KERN_SUCCESS &&
        atomic_load_explicit(&s_svc_interceptor_active, memory_order_acquire) &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        pt_svc_redact_exc_ports_info_arrays(YES, port, masks, masksCnt, old_handlers_info, old_behaviors, old_flavors);
    }
    return kr;
}

PT_INTERPOSE(pt_task_set_exception_ports, task_set_exception_ports)
PT_INTERPOSE(pt_task_swap_exception_ports, task_swap_exception_ports)
PT_INTERPOSE(pt_task_get_exception_ports, task_get_exception_ports)
PT_INTERPOSE_WEAK_NAMED(pt_task_get_exception_ports_info, pt_orig_task_get_exception_ports_info, "task_get_exception_ports_info")
PT_INTERPOSE(pt_thread_set_exception_ports, thread_set_exception_ports)
PT_INTERPOSE(pt_thread_swap_exception_ports, thread_swap_exception_ports)
PT_INTERPOSE(pt_thread_get_exception_ports, thread_get_exception_ports)
PT_INTERPOSE_WEAK_NAMED(pt_thread_get_exception_ports_info, pt_orig_thread_get_exception_ports_info, "thread_get_exception_ports_info")

__attribute__((visibility("hidden")))
BOOL pt_svc_get_redaction_info(mach_port_t *out_svc_port,
                               mach_port_t *out_saved_port,
                               exception_mask_t *out_saved_mask,
                               exception_behavior_t *out_saved_beh,
                               thread_state_flavor_t *out_saved_flavor) {
    if (out_svc_port != NULL) {
        *out_svc_port = MACH_PORT_NULL;
    }
    if (out_saved_port != NULL) {
        *out_saved_port = MACH_PORT_NULL;
    }
    if (out_saved_mask != NULL) {
        *out_saved_mask = 0;
    }
    if (out_saved_beh != NULL) {
        *out_saved_beh = 0;
    }
    if (out_saved_flavor != NULL) {
        *out_saved_flavor = 0;
    }
    if (!atomic_load_explicit(&s_svc_interceptor_active, memory_order_acquire)) {
        return NO;
    }
    mach_port_t svc_port = atomic_load_explicit(&s_svc_exc_port, memory_order_acquire);
    if (!MACH_PORT_VALID(svc_port)) {
        return NO;
    }
    if (out_svc_port != NULL) {
        *out_svc_port = svc_port;
    }
    pt_svc_saved_exc_handler_t saved = pt_svc_copy_retained_task_bp();
    if (saved.valid && MACH_PORT_VALID(saved.port) && saved.port != svc_port) {
        if (out_saved_port != NULL) {
            *out_saved_port = saved.port;
        } else {
            pt_svc_release_send_right(saved.port);
        }
        if (out_saved_mask != NULL) {
            *out_saved_mask = saved.mask;
        }
        if (out_saved_beh != NULL) {
            *out_saved_beh = saved.behavior;
        }
        if (out_saved_flavor != NULL) {
            *out_saved_flavor = saved.flavor;
        }
    } else {
        pt_svc_release_send_right(saved.port);
    }
    return YES;
}

// MARK: - Initialization

__attribute__((visibility("hidden"))) void pt_svc_interceptor_init_early(void) {
    static _Atomic bool s_inited = false;
    if (atomic_exchange_explicit(&s_inited, true, memory_order_acq_rel)) {
        return;
    }

#if defined(__arm64__) || defined(__aarch64__)
    BOOL safe_mode = [PTSafeMode isActive] || pt_svc_env_flag_true(pt_raw_getenv("PLAYTOOLS_SAFE_MODE"));
    atomic_store_explicit(&s_svc_safe_mode_passthrough, safe_mode, memory_order_release);

    if (!pt_svc_load_manifest_from_disk(&s_manifest)) {
        return;
    }

    _dyld_register_func_for_add_image(pt_svc_on_dyld_image_added);
    if (pt_svc_install_exception_handler()) {
        atomic_store_explicit(&s_svc_interceptor_active, true, memory_order_release);
        PT_DEBUG_TRACE("svc", "inline svc interceptor active (sites=%zu safemode=%d)",
                       s_registered_pc_count, safe_mode ? 1 : 0);
    }
#endif
}
