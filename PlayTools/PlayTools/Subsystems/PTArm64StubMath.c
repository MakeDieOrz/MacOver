//
//  PTArm64StubMath.c
//  PlayTools
//
//  Pure-C ARM64 Mach-O stub decoder and two-table section collector.
//

#include "PTArm64StubMath.h"

#include <stddef.h>
#include <string.h>

__attribute__((visibility("hidden"))) bool pt_decode_arm64_stub_target_slot(uintptr_t stub_pc, const uint32_t *words,
                                                                            uint32_t stride, uintptr_t *out_slot) {
    if (words == NULL || out_slot == NULL || stride < 12U) {
        return false;
    }
    uint32_t w0 = words[0];
    if ((w0 & 0x9F00001FU) != 0x90000010U) {
        return false; // ADRP x16, #page
    }
    uint32_t imm21 = (((w0 >> 5) & 0x7FFFFU) << 2) | ((w0 >> 29) & 0x3U);
    int32_t simm21 = (int32_t)imm21;
    if ((imm21 & (1U << 20)) != 0U) {
        simm21 -= (int32_t)(1U << 21);
    }
    int64_t page_base = (int64_t)(stub_pc & ~(uintptr_t)0xFFFU);
    int64_t page_off = ((int64_t)simm21) * 4096LL;
    uintptr_t page = (uintptr_t)(page_base + page_off);

    uint32_t w1 = words[1];
    uint32_t w2 = words[2];
    if ((w1 & 0xFFC003FFU) == 0xF9400210U && w2 == 0xD61F0200U) {
        uintptr_t uimm = ((uintptr_t)((w1 >> 10) & 0xFFFU)) << 3;
        *out_slot = page + uimm;
        return true;
    }

    if (stride >= 16U && (w1 & 0xFFC003FFU) == 0x91000210U && (w2 & 0xFFC003FEU) == 0xF9400210U) {
        uint32_t rt = w2 & 0x1FU;
        uint32_t w3 = words[3];
        bool branch_ok = (rt == 16U && (w3 == 0xD61F0200U || w3 == 0xD71F0A10U)) ||
                         (rt == 17U && (w3 == 0xD61F0220U || w3 == 0xD71F0A30U || w3 == 0xD71F0E30U));
        if (branch_ok) {
            uintptr_t imm12 = (uintptr_t)((w1 >> 10) & 0xFFFU);
            uintptr_t uimm = ((uintptr_t)((w2 >> 10) & 0xFFFU)) << 3;
            *out_slot = page + imm12 + uimm;
            return true;
        }
    }

    return false;
}

__attribute__((visibility("hidden"))) bool
pt_collect_two_table_macho_sections(const struct mach_header_64 *mh64, intptr_t vmaddr_slide,
                                    uintptr_t *out_stubs_start, uintptr_t *out_stubs_size, uint32_t *out_stubs_stride,
                                    pt_got_sec_range_t *out_got_secs, uint32_t *out_got_count) {
    *out_stubs_start = 0;
    *out_stubs_size = 0;
    *out_stubs_stride = 0;
    *out_got_count = 0;

    if (mh64 == NULL || out_got_secs == NULL || mh64->sizeofcmds == 0 || mh64->sizeofcmds > (1U << 20)) {
        return false;
    }
    const uint8_t *base = (const uint8_t *)mh64;
    size_t total = sizeof(struct mach_header_64) + (size_t)mh64->sizeofcmds;
    size_t off = sizeof(struct mach_header_64);
    uintptr_t slide = (uintptr_t)vmaddr_slide;
    bool has_lazy = false;
    bool text_slide_checked = false;

    for (uint32_t i = 0; i < mh64->ncmds && off + sizeof(struct load_command) <= total; i++) {
        const struct load_command *lc = (const struct load_command *)(base + off);
        if (lc->cmdsize < sizeof(struct load_command) || off + lc->cmdsize > total) {
            break;
        }
        off += lc->cmdsize;
        if (lc->cmd != LC_SEGMENT_64 || lc->cmdsize < sizeof(struct segment_command_64)) {
            continue;
        }
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        if (strncmp(seg->segname, "__TEXT", 16) == 0) {
            text_slide_checked = true;
            if ((uintptr_t)seg->vmaddr + slide != (uintptr_t)mh64) {
                return false;
            }
        }
        if ((size_t)seg->nsects > (lc->cmdsize - sizeof(struct segment_command_64)) / sizeof(struct section_64)) {
            return false;
        }
        const struct section_64 *sects = (const struct section_64 *)(seg + 1);
        for (uint32_t s = 0; s < seg->nsects; s++) {
            uint32_t stype = sects[s].flags & SECTION_TYPE;
            uintptr_t s_addr = (uintptr_t)sects[s].addr + slide;
            uintptr_t s_size = (uintptr_t)sects[s].size;
            if (stype == S_LAZY_SYMBOL_POINTERS && s_size >= sizeof(void *)) {
                has_lazy = true;
            } else if (stype == S_SYMBOL_STUBS && s_size > 0 && s_size <= UINTPTR_MAX - s_addr &&
                       sects[s].reserved2 >= 12U && sects[s].reserved2 <= 32U && (sects[s].reserved2 % 4U) == 0 &&
                       (s_size % (uintptr_t)sects[s].reserved2) == 0) {
                *out_stubs_start = s_addr;
                *out_stubs_size = s_size;
                *out_stubs_stride = sects[s].reserved2;
            } else if (stype == S_NON_LAZY_SYMBOL_POINTERS && s_size >= sizeof(void *) &&
                       s_size <= UINTPTR_MAX - s_addr && (s_size % sizeof(void *)) == 0 &&
                       strncmp(sects[s].sectname, "__auth_", 7) != 0 && *out_got_count < PT_MAX_NONLAZY_GOT_SECS) {
                out_got_secs[*out_got_count] = (pt_got_sec_range_t){
                    .start = s_addr,
                    .size = s_size,
                };
                (*out_got_count)++;
            }
        }
    }

    return (text_slide_checked && has_lazy && *out_stubs_size > 0 && *out_got_count > 0);
}
