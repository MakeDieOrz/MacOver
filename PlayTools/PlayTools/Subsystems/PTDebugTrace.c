//
//  PTDebugTrace.c
//  PlayTools
//

#include "PTDebugTrace.h"
#include <errno.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static _Atomic bool s_pt_debug_trace_ready = false;
static _Atomic int s_pt_debug_trace_state = -1;
static _Atomic int s_pt_debug_trace_sink_fd = STDERR_FILENO;
static _Thread_local bool s_tls_in_trace = false;

void pt_debug_trace_mark_ready(void) {
    atomic_store_explicit(&s_pt_debug_trace_ready, true, memory_order_release);
}

bool pt_debug_trace_is_enabled(void) {
    if (!atomic_load_explicit(&s_pt_debug_trace_ready, memory_order_acquire)) {
        return false;
    }
    int state = atomic_load_explicit(&s_pt_debug_trace_state, memory_order_acquire);
    if (state >= 0) {
        return state == 1;
    }
    const char *env = getenv("PLAYTOOLS_DEBUG_LOG");
    int resolved = (env != NULL && strcmp(env, "1") == 0) ? 1 : 0;
    atomic_store_explicit(&s_pt_debug_trace_state, resolved, memory_order_release);
    return resolved == 1;
}

void pt_debug_trace_emit(const char *subsystem, const char *func, const char *fmt, ...) {
    int saved_errno = errno;
    if (!pt_debug_trace_is_enabled()) {
        errno = saved_errno;
        return;
    }
    if (s_tls_in_trace) {
        errno = saved_errno;
        return;
    }
    s_tls_in_trace = true;

    char buf[512];
    const char *safe_sub = (subsystem != NULL && subsystem[0] != '\0') ? subsystem : "core";
    const char *safe_fn = (func != NULL && func[0] != '\0') ? func : "unknown";
    int prefix_written = snprintf(buf, sizeof(buf), "[PlayTools] [%s] %s: ", safe_sub, safe_fn);
    size_t pos = 0U;
    if (prefix_written > 0) {
        pos = ((size_t)prefix_written < sizeof(buf)) ? (size_t)prefix_written : (sizeof(buf) - 1U);
    }

    if (fmt != NULL && pos < (sizeof(buf) - 1U)) {
        va_list ap;
        va_start(ap, fmt);
        int msg_written = vsnprintf(buf + pos, sizeof(buf) - pos, fmt, ap);
        va_end(ap);
        if (msg_written > 0) {
            size_t avail = (sizeof(buf) - 1U) - pos;
            size_t add = ((size_t)msg_written < avail) ? (size_t)msg_written : avail;
            pos += add;
        }
    }

    if (pos >= (sizeof(buf) - 1U)) {
        pos = sizeof(buf) - 2U;
    }
    buf[pos++] = '\n';
    buf[pos] = '\0';

    int fd = atomic_load_explicit(&s_pt_debug_trace_sink_fd, memory_order_acquire);
    if (fd >= 0) {
        size_t offset = 0U;
        while (offset < pos) {
            ssize_t n = write(fd, buf + offset, pos - offset);
            if (n <= 0) {
                break;
            }
            offset += (size_t)n;
        }
    }

    s_tls_in_trace = false;
    errno = saved_errno;
}

void pt_debug_trace_emit_cstr(const char *subsystem, const char *func, const char *message) {
    if (!pt_debug_trace_is_enabled()) {
        return;
    }
    pt_debug_trace_emit(subsystem, func, "%s", message != NULL ? message : "");
}

void pt_debug_trace_set_sink_fd_for_testing(int fd) {
    atomic_store_explicit(&s_pt_debug_trace_sink_fd, fd, memory_order_release);
}

void pt_debug_trace_reset_for_testing(int forced_state) {
    atomic_store_explicit(&s_pt_debug_trace_ready, true, memory_order_release);
    atomic_store_explicit(&s_pt_debug_trace_state, forced_state, memory_order_release);
    atomic_store_explicit(&s_pt_debug_trace_sink_fd, STDERR_FILENO, memory_order_release);
}
