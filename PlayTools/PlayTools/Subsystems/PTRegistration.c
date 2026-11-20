//
//  PTRegistration.c
//  PlayTools
//

#include "PTRegistration.h"
#include "PTDebugTrace.h"
#include <os/lock.h>
#include <stdatomic.h>
#include <string.h>

#define PT_REG_MAX_ENTRIES 128U
#define PT_REG_MAX_STRING_LEN 128U

static os_unfair_lock s_reg_lock = OS_UNFAIR_LOCK_INIT;

static char s_hidden_modules[PT_REG_MAX_ENTRIES][PT_REG_MAX_STRING_LEN];
static _Atomic size_t s_hidden_module_count = 0;

static char s_hidden_classes[PT_REG_MAX_ENTRIES][PT_REG_MAX_STRING_LEN];
static size_t s_hidden_class_lens[PT_REG_MAX_ENTRIES];
static _Atomic size_t s_hidden_class_count = 0;

static const void *s_hidden_headers[PT_REG_MAX_ENTRIES];
static _Atomic size_t s_hidden_header_count = 0;

static _Atomic uint64_t s_registry_generation = 0;

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
}
