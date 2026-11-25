//
//  PTArm64StubMath.h
//  PlayTools
//
//  Pure-C ARM64 Mach-O stub decoder and two-table section collector.
//

#ifndef PTArm64StubMath_h
#define PTArm64StubMath_h

#include <mach-o/loader.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PT_MAX_NONLAZY_GOT_SECS 4U

typedef struct {
    uintptr_t start;
    uintptr_t size;
} pt_got_sec_range_t;

__attribute__((visibility("hidden"))) bool pt_decode_arm64_stub_target_slot(uintptr_t stub_pc, const uint32_t *words,
                                                                            uint32_t stride, uintptr_t *out_slot);

__attribute__((visibility("hidden"))) bool
pt_collect_two_table_macho_sections(const struct mach_header_64 *mh64, intptr_t vmaddr_slide,
                                    uintptr_t *out_stubs_start, uintptr_t *out_stubs_size, uint32_t *out_stubs_stride,
                                    pt_got_sec_range_t *out_got_secs, uint32_t *out_got_count);

#ifdef __cplusplus
}
#endif

#endif /* PTArm64StubMath_h */
