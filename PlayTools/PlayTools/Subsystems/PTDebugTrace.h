//
//  PTDebugTrace.h
//  PlayTools
//
//  TLV-safe, recursion-safe, async-signal-safe C/ObjC syscall interpose trace
//  facility gated by PLAYTOOLS_DEBUG_LOG=1.
//

#ifndef PTDebugTrace_h
#define PTDebugTrace_h

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

void pt_debug_trace_mark_ready(void);
bool pt_debug_trace_is_enabled(void);
void pt_debug_trace_emit(const char *subsystem, const char *func, const char *fmt, ...)
    __attribute__((format(printf, 3, 4)));
void pt_debug_trace_emit_cstr(const char *subsystem, const char *func, const char *message);
void pt_debug_trace_set_sink_fd_for_testing(int fd);
void pt_debug_trace_reset_for_testing(int forced_state);

#define PT_DEBUG_TRACE(subsystem, fmt, ...)                                                                            \
    do {                                                                                                               \
        if (__builtin_expect(pt_debug_trace_is_enabled(), 0)) {                                                        \
            pt_debug_trace_emit((subsystem), __func__, (fmt), ##__VA_ARGS__);                                          \
        }                                                                                                              \
    } while (0)

#ifdef __cplusplus
}
#endif

#endif /* PTDebugTrace_h */
