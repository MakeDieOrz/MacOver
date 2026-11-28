//
//  PTRegistration.c
//  PlayTools
//

#include "PTRegistration.h"
#include "../PTCallerAddressMath.h"
#include "PTDebugTrace.h"
#include <os/lock.h>
#include <stdatomic.h>
#include <string.h>

#ifndef DEBUG
extern const char *dyld_image_path_containing_address(const void *addr);
extern const void *dyld_image_header_containing_address(const void *addr);
#endif

#define PT_REG_MAX_ENTRIES 128U
#define PT_REG_MAX_STRING_LEN 128U
#define PT_REG_MAX_HIDDEN_FDS 32U
#define PT_REG_MAX_HIDDEN_PORTS 16U
#define PT_AUTOMATION_TOKEN_CAP 128U
#define PT_AUTOMATION_BUNDLE_CAP 256U
#define PT_AUTOMATION_BRIDGE_DIR_CAP 1024U

static os_unfair_lock s_reg_lock = OS_UNFAIR_LOCK_INIT;

static char s_hidden_modules[PT_REG_MAX_ENTRIES][PT_REG_MAX_STRING_LEN];
static _Atomic size_t s_hidden_module_count = 0;

static char s_hidden_classes[PT_REG_MAX_ENTRIES][PT_REG_MAX_STRING_LEN];
static size_t s_hidden_class_lens[PT_REG_MAX_ENTRIES];
static _Atomic size_t s_hidden_class_count = 0;

static const void *s_hidden_headers[PT_REG_MAX_ENTRIES];
static _Atomic size_t s_hidden_header_count = 0;

static _Atomic uint64_t s_registry_generation = 0;

static os_unfair_lock s_hidden_fd_lock = OS_UNFAIR_LOCK_INIT;
static _Atomic int s_hidden_fds[PT_REG_MAX_HIDDEN_FDS];
static _Atomic size_t s_hidden_fd_count = 0;
static _Atomic bool s_hidden_fds_inited = false;

static _Atomic uint16_t s_hidden_loopback_ports[PT_REG_MAX_HIDDEN_PORTS];
static _Atomic size_t s_hidden_loopback_port_count = 0;

static os_unfair_lock s_automation_lock = OS_UNFAIR_LOCK_INIT;
static _Atomic bool s_automation_available = false;
static uint16_t s_automation_port = 0;
static char s_automation_token[PT_AUTOMATION_TOKEN_CAP];
static char s_automation_bundle_id[PT_AUTOMATION_BUNDLE_CAP];
static char s_automation_bridge_dir[PT_AUTOMATION_BRIDGE_DIR_CAP];

static void pt_secure_zero_bytes(void *ptr, size_t len) {
    if (ptr == NULL || len == 0U) {
        return;
    }
    volatile unsigned char *p = (volatile unsigned char *)ptr;
    for (size_t i = 0; i < len; i++) {
        p[i] = 0U;
    }
}

static void pt_ensure_hidden_fds_inited_locked(void) {
    if (atomic_load_explicit(&s_hidden_fds_inited, memory_order_relaxed)) {
        return;
    }
    for (size_t i = 0; i < PT_REG_MAX_HIDDEN_FDS; i++) {
        atomic_store_explicit(&s_hidden_fds[i], -1, memory_order_relaxed);
    }
    atomic_store_explicit(&s_hidden_fds_inited, true, memory_order_release);
}

void pt_register_hidden_module(const char *image_name_fragment) {
    if (image_name_fragment == NULL || image_name_fragment[0] == '\0') {
        return;
    }

    char normalized[PT_REG_MAX_STRING_LEN];
    strlcpy(normalized, image_name_fragment, sizeof(normalized));
    if (normalized[0] == '\0') {
        return;
    }

    os_unfair_lock_lock(&s_reg_lock);
    size_t count = atomic_load_explicit(&s_hidden_module_count, memory_order_relaxed);
    for (size_t i = 0; i < count; i++) {
        if (strcmp(s_hidden_modules[i], normalized) == 0) {
            os_unfair_lock_unlock(&s_reg_lock);
            return;
        }
    }
    if (count < PT_REG_MAX_ENTRIES) {
        strlcpy(s_hidden_modules[count], normalized, PT_REG_MAX_STRING_LEN);
        atomic_store_explicit(&s_hidden_module_count, count + 1U, memory_order_release);
        atomic_fetch_add_explicit(&s_registry_generation, 1ULL, memory_order_release);
        PT_DEBUG_TRACE("reg", "registered hidden module=%s", normalized);
    }
    os_unfair_lock_unlock(&s_reg_lock);
}

void pt_register_hidden_class(const char *objc_class_name) {
    if (objc_class_name == NULL || objc_class_name[0] == '\0') {
        return;
    }

    char normalized[PT_REG_MAX_STRING_LEN];
    size_t len = strlcpy(normalized, objc_class_name, sizeof(normalized));
    if (normalized[0] == '\0') {
        return;
    }
    if (len >= sizeof(normalized)) {
        len = sizeof(normalized) - 1U;
    }

    os_unfair_lock_lock(&s_reg_lock);
    size_t count = atomic_load_explicit(&s_hidden_class_count, memory_order_relaxed);
    for (size_t i = 0; i < count; i++) {
        if (strcmp(s_hidden_classes[i], normalized) == 0) {
            os_unfair_lock_unlock(&s_reg_lock);
            return;
        }
    }
    if (count < PT_REG_MAX_ENTRIES) {
        strlcpy(s_hidden_classes[count], normalized, PT_REG_MAX_STRING_LEN);
        s_hidden_class_lens[count] = len;
        atomic_store_explicit(&s_hidden_class_count, count + 1U, memory_order_release);
        atomic_fetch_add_explicit(&s_registry_generation, 1ULL, memory_order_release);
        PT_DEBUG_TRACE("reg", "registered hidden class=%s", normalized);
    }
    os_unfair_lock_unlock(&s_reg_lock);
}

void pt_register_hidden_image_header(const void *mach_header) {
    if (mach_header == NULL) {
        return;
    }

    os_unfair_lock_lock(&s_reg_lock);
    size_t count = atomic_load_explicit(&s_hidden_header_count, memory_order_relaxed);
    for (size_t i = 0; i < count; i++) {
        if (s_hidden_headers[i] == mach_header) {
            os_unfair_lock_unlock(&s_reg_lock);
            return;
        }
    }
    if (count < PT_REG_MAX_ENTRIES) {
        s_hidden_headers[count] = mach_header;
        atomic_store_explicit(&s_hidden_header_count, count + 1U, memory_order_release);
        atomic_fetch_add_explicit(&s_registry_generation, 1ULL, memory_order_release);
        PT_DEBUG_TRACE("reg", "registered hidden header=%p", mach_header);
    }
    os_unfair_lock_unlock(&s_reg_lock);
}

bool pt_is_registered_hidden_module(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return false;
    }
    size_t count = atomic_load_explicit(&s_hidden_module_count, memory_order_acquire);
    for (size_t i = 0; i < count; i++) {
        const char *entry = s_hidden_modules[i];
        if (entry[0] != '\0' && strstr(name, entry) != NULL) {
            return true;
        }
    }
    return false;
}

bool pt_is_registered_hidden_class(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return false;
    }
    size_t count = atomic_load_explicit(&s_hidden_class_count, memory_order_acquire);
    for (size_t i = 0; i < count; i++) {
        const char *entry = s_hidden_classes[i];
        size_t len = s_hidden_class_lens[i];
        if (len > 0U && strncmp(name, entry, len) == 0) {
            return true;
        }
    }
    return false;
}

bool pt_is_registered_hidden_image_header(const void *mach_header) {
    if (mach_header == NULL) {
        return false;
    }
    size_t count = atomic_load_explicit(&s_hidden_header_count, memory_order_acquire);
    for (size_t i = 0; i < count; i++) {
        if (s_hidden_headers[i] == mach_header) {
            return true;
        }
    }
    return false;
}

uint64_t pt_hidden_registry_generation(void) {
    return atomic_load_explicit(&s_registry_generation, memory_order_acquire);
}

size_t pt_registered_hidden_module_count(void) {
    return atomic_load_explicit(&s_hidden_module_count, memory_order_acquire);
}

size_t pt_registered_hidden_class_count(void) {
    return atomic_load_explicit(&s_hidden_class_count, memory_order_acquire);
}

size_t pt_registered_hidden_image_header_count(void) {
    return atomic_load_explicit(&s_hidden_header_count, memory_order_acquire);
}

static bool pt_registration_allow_internal_caller(const void *ret_addr) {
#ifdef DEBUG
    (void)ret_addr;
    return true;
#else
    if (pt_is_in_internal_scope()) {
        return true;
    }
    if (ret_addr == NULL) {
        return false;
    }
    const void *stripped = pt_strip_return_addr((uintptr_t)ret_addr);
    if (stripped == NULL) {
        return false;
    }
    const void *self_hdr = dyld_image_header_containing_address((const void *)&pt_registration_allow_internal_caller);
    const void *caller_hdr = dyld_image_header_containing_address(stripped);
    if (self_hdr != NULL && caller_hdr == self_hdr) {
        return true;
    }
    if (caller_hdr != NULL && pt_is_registered_hidden_image_header(caller_hdr)) {
        return true;
    }
    const char *fname = dyld_image_path_containing_address(stripped);
    if (fname == NULL || fname[0] == '\0') {
        return false;
    }
    if (pt_is_registered_hidden_module(fname)) {
        return true;
    }
    return pt_classify_caller_image_path(fname, NULL) != PT_CALLER_APP;
#endif
}

void pt_register_hidden_fd(int fd) {
    if (fd < 0 || !pt_registration_allow_internal_caller(__builtin_return_address(0))) {
        return;
    }
    os_unfair_lock_lock(&s_hidden_fd_lock);
    pt_ensure_hidden_fds_inited_locked();
    size_t free_slot = PT_REG_MAX_HIDDEN_FDS;
    for (size_t i = 0; i < PT_REG_MAX_HIDDEN_FDS; i++) {
        int cur = atomic_load_explicit(&s_hidden_fds[i], memory_order_relaxed);
        if (cur == fd) {
            os_unfair_lock_unlock(&s_hidden_fd_lock);
            return;
        }
        if (cur < 0 && free_slot == PT_REG_MAX_HIDDEN_FDS) {
            free_slot = i;
        }
    }
    if (free_slot < PT_REG_MAX_HIDDEN_FDS) {
        atomic_store_explicit(&s_hidden_fds[free_slot], fd, memory_order_release);
        atomic_fetch_add_explicit(&s_hidden_fd_count, 1U, memory_order_release);
    }
    os_unfair_lock_unlock(&s_hidden_fd_lock);
}

void pt_unregister_hidden_fd(int fd) {
    if (fd < 0 || !pt_registration_allow_internal_caller(__builtin_return_address(0))) {
        return;
    }
    os_unfair_lock_lock(&s_hidden_fd_lock);
    if (!atomic_load_explicit(&s_hidden_fds_inited, memory_order_relaxed)) {
        os_unfair_lock_unlock(&s_hidden_fd_lock);
        return;
    }
    for (size_t i = 0; i < PT_REG_MAX_HIDDEN_FDS; i++) {
        if (atomic_load_explicit(&s_hidden_fds[i], memory_order_relaxed) == fd) {
            atomic_store_explicit(&s_hidden_fds[i], -1, memory_order_release);
            size_t prev = atomic_load_explicit(&s_hidden_fd_count, memory_order_relaxed);
            if (prev > 0U) {
                atomic_store_explicit(&s_hidden_fd_count, prev - 1U, memory_order_release);
            }
            break;
        }
    }
    os_unfair_lock_unlock(&s_hidden_fd_lock);
}

bool pt_is_hidden_fd(int fd) {
    if (fd < 0 || atomic_load_explicit(&s_hidden_fd_count, memory_order_acquire) == 0U ||
        !atomic_load_explicit(&s_hidden_fds_inited, memory_order_acquire)) {
        return false;
    }
    for (size_t i = 0; i < PT_REG_MAX_HIDDEN_FDS; i++) {
        if (atomic_load_explicit(&s_hidden_fds[i], memory_order_acquire) == fd) {
            return true;
        }
    }
    return false;
}

void pt_register_hidden_loopback_port(uint16_t port) {
    if (port == 0U || !pt_registration_allow_internal_caller(__builtin_return_address(0))) {
        return;
    }
    os_unfair_lock_lock(&s_hidden_fd_lock);
    size_t free_slot = PT_REG_MAX_HIDDEN_PORTS;
    for (size_t i = 0; i < PT_REG_MAX_HIDDEN_PORTS; i++) {
        uint16_t cur = atomic_load_explicit(&s_hidden_loopback_ports[i], memory_order_relaxed);
        if (cur == port) {
            os_unfair_lock_unlock(&s_hidden_fd_lock);
            return;
        }
        if (cur == 0U && free_slot == PT_REG_MAX_HIDDEN_PORTS) {
            free_slot = i;
        }
    }
    if (free_slot < PT_REG_MAX_HIDDEN_PORTS) {
        atomic_store_explicit(&s_hidden_loopback_ports[free_slot], port, memory_order_release);
        atomic_fetch_add_explicit(&s_hidden_loopback_port_count, 1U, memory_order_release);
    }
    os_unfair_lock_unlock(&s_hidden_fd_lock);
}

void pt_unregister_hidden_loopback_port(uint16_t port) {
    if (port == 0U || !pt_registration_allow_internal_caller(__builtin_return_address(0))) {
        return;
    }
    os_unfair_lock_lock(&s_hidden_fd_lock);
    for (size_t i = 0; i < PT_REG_MAX_HIDDEN_PORTS; i++) {
        if (atomic_load_explicit(&s_hidden_loopback_ports[i], memory_order_relaxed) == port) {
            atomic_store_explicit(&s_hidden_loopback_ports[i], 0U, memory_order_release);
            size_t prev = atomic_load_explicit(&s_hidden_loopback_port_count, memory_order_relaxed);
            if (prev > 0U) {
                atomic_store_explicit(&s_hidden_loopback_port_count, prev - 1U, memory_order_release);
            }
            break;
        }
    }
    os_unfair_lock_unlock(&s_hidden_fd_lock);
}

bool pt_is_hidden_loopback_port(uint16_t port) {
    if (port == 0U || atomic_load_explicit(&s_hidden_loopback_port_count, memory_order_acquire) == 0U) {
        return false;
    }
    for (size_t i = 0; i < PT_REG_MAX_HIDDEN_PORTS; i++) {
        if (atomic_load_explicit(&s_hidden_loopback_ports[i], memory_order_acquire) == port) {
            return true;
        }
    }
    return false;
}

void pt_store_automation_bootstrap(uint16_t port, const char *token, const char *bundle_id, const char *bridge_dir) {
    os_unfair_lock_lock(&s_automation_lock);
    s_automation_port = 0U;
    pt_secure_zero_bytes(s_automation_token, sizeof(s_automation_token));
    pt_secure_zero_bytes(s_automation_bundle_id, sizeof(s_automation_bundle_id));
    pt_secure_zero_bytes(s_automation_bridge_dir, sizeof(s_automation_bridge_dir));
    bool valid = (port > 0U && token != NULL && token[0] != '\0' && bundle_id != NULL && bundle_id[0] != '\0');
    if (valid) {
        s_automation_port = port;
        strlcpy(s_automation_token, token, sizeof(s_automation_token));
        strlcpy(s_automation_bundle_id, bundle_id, sizeof(s_automation_bundle_id));
        if (bridge_dir != NULL && bridge_dir[0] != '\0') {
            strlcpy(s_automation_bridge_dir, bridge_dir, sizeof(s_automation_bridge_dir));
        }
    }
    atomic_store_explicit(&s_automation_available, valid, memory_order_release);
    os_unfair_lock_unlock(&s_automation_lock);
}

void pt_clear_automation_bootstrap(void) {
    os_unfair_lock_lock(&s_automation_lock);
    s_automation_port = 0U;
    pt_secure_zero_bytes(s_automation_token, sizeof(s_automation_token));
    pt_secure_zero_bytes(s_automation_bundle_id, sizeof(s_automation_bundle_id));
    pt_secure_zero_bytes(s_automation_bridge_dir, sizeof(s_automation_bridge_dir));
    atomic_store_explicit(&s_automation_available, false, memory_order_release);
    os_unfair_lock_unlock(&s_automation_lock);
}

bool pt_has_automation_bootstrap(void) {
    return atomic_load_explicit(&s_automation_available, memory_order_acquire);
}

bool pt_copy_automation_bootstrap_bridge_dir(char *out_dir, size_t dir_cap) {
    if (out_dir == NULL || dir_cap == 0U) {
        return false;
    }
    out_dir[0] = '\0';
    os_unfair_lock_lock(&s_automation_lock);
    bool has =
        (atomic_load_explicit(&s_automation_available, memory_order_relaxed) && s_automation_bridge_dir[0] != '\0');
    if (has) {
        strlcpy(out_dir, s_automation_bridge_dir, dir_cap);
    }
    os_unfair_lock_unlock(&s_automation_lock);
    return has;
}

bool pt_consume_automation_bootstrap(uint16_t *out_port, char *out_token, size_t token_cap, char *out_bundle_id,
                                     size_t bundle_cap) {
    if (out_port == NULL || out_token == NULL || token_cap == 0U || out_bundle_id == NULL || bundle_cap == 0U) {
        return false;
    }
    *out_port = 0U;
    out_token[0] = '\0';
    out_bundle_id[0] = '\0';
    if (!pt_registration_allow_internal_caller(__builtin_return_address(0))) {
        return false;
    }
    os_unfair_lock_lock(&s_automation_lock);
    bool valid = (atomic_load_explicit(&s_automation_available, memory_order_relaxed) && s_automation_port > 0U &&
                  s_automation_token[0] != '\0' && s_automation_bundle_id[0] != '\0');
    if (valid) {
        *out_port = s_automation_port;
        strlcpy(out_token, s_automation_token, token_cap);
        strlcpy(out_bundle_id, s_automation_bundle_id, bundle_cap);
        s_automation_port = 0U;
        pt_secure_zero_bytes(s_automation_token, sizeof(s_automation_token));
        pt_secure_zero_bytes(s_automation_bundle_id, sizeof(s_automation_bundle_id));
        pt_secure_zero_bytes(s_automation_bridge_dir, sizeof(s_automation_bridge_dir));
        atomic_store_explicit(&s_automation_available, false, memory_order_release);
    }
    os_unfair_lock_unlock(&s_automation_lock);
    return valid;
}

#ifdef DEBUG
void pt_reset_hidden_registry_for_testing(void) {
    os_unfair_lock_lock(&s_reg_lock);
    atomic_store_explicit(&s_hidden_module_count, 0U, memory_order_release);
    atomic_store_explicit(&s_hidden_class_count, 0U, memory_order_release);
    atomic_store_explicit(&s_hidden_header_count, 0U, memory_order_release);
    memset(s_hidden_modules, 0, sizeof(s_hidden_modules));
    memset(s_hidden_classes, 0, sizeof(s_hidden_classes));
    memset(s_hidden_class_lens, 0, sizeof(s_hidden_class_lens));
    memset(s_hidden_headers, 0, sizeof(s_hidden_headers));
    atomic_fetch_add_explicit(&s_registry_generation, 1ULL, memory_order_release);
    os_unfair_lock_unlock(&s_reg_lock);

    os_unfair_lock_lock(&s_hidden_fd_lock);
    for (size_t i = 0; i < PT_REG_MAX_HIDDEN_FDS; i++) {
        atomic_store_explicit(&s_hidden_fds[i], -1, memory_order_relaxed);
    }
    atomic_store_explicit(&s_hidden_fd_count, 0U, memory_order_release);
    atomic_store_explicit(&s_hidden_fds_inited, true, memory_order_release);
    for (size_t i = 0; i < PT_REG_MAX_HIDDEN_PORTS; i++) {
        atomic_store_explicit(&s_hidden_loopback_ports[i], 0U, memory_order_relaxed);
    }
    atomic_store_explicit(&s_hidden_loopback_port_count, 0U, memory_order_release);
    os_unfair_lock_unlock(&s_hidden_fd_lock);

    pt_clear_automation_bootstrap();
}
#endif
