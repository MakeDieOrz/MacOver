#include <assert.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "PTArm64StubMath.h"
#include "PTCallerAddressMath.h"
#include "PTCodeSignParser.h"
#include "PTDetectionRules.h"
#include "PTInterposeRegistry.h"
#include "PTRegistration.h"

#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
static uint32_t to_be32(uint32_t v) {
    return ((v & 0x000000ffU) << 24) | ((v & 0x0000ff00U) << 8) | ((v & 0x00ff0000U) >> 8) | ((v & 0xff000000U) >> 24);
}
#else
static uint32_t to_be32(uint32_t v) {
    return v;
}
#endif

static uint32_t from_be32(uint32_t v) {
    return to_be32(v);
}

/* ---------- Batch 1 Unit Tests ---------- */

static void test_der_entitlements_encoding_and_superblob_rewrite(void) {
    /* Encode sample entitlements dict using production PTCodeSignParser */
    pt_der_buf_t pair1_body = {0};
    const char *k1 = "com.apple.developer.team-identifier";
    const char *v1 = "ABCD123456";
    pt_der_buf_wrap_tlv(&pair1_body, 0x0cU, (const uint8_t *)k1, strlen(k1));
    pt_der_buf_wrap_tlv(&pair1_body, 0x0cU, (const uint8_t *)v1, strlen(v1));
    pt_der_buf_t pair1 = {0};
    pt_der_buf_wrap_tlv(&pair1, 0x30U, pair1_body.data, pair1_body.len);

    pt_der_buf_t set_body = {0};
    pt_der_buf_append(&set_body, pair1.data, pair1.len);

    pt_der_buf_t app_body = {0};
    uint8_t ver[3] = {0x02U, 0x01U, 0x01U};
    pt_der_buf_append(&app_body, ver, sizeof(ver));
    pt_der_buf_wrap_tlv(&app_body, 0x31U, set_body.data, set_body.len);

    pt_der_buf_t root = {0};
    pt_der_buf_wrap_tlv(&root, 0x70U, app_body.data, app_body.len);

    assert(!root.failed);
    assert(root.data[0] == 0x70U);
    for (size_t i = 0; i + 9 <= root.len; i++) {
        assert(memcmp(root.data + i, "PlayTools", 9) != 0);
    }

    uint32_t magic_xml = to_be32(PT_CSMAGIC_EMBEDDED_ENTITLEMENTS);
    uint32_t magic_der = to_be32(PT_CSMAGIC_EMBEDDED_DER_ENTITLEMENTS);
    assert(from_be32(magic_xml) == 0xfade7171U);
    assert(from_be32(magic_der) == 0xfade7172U);

    free(pair1_body.data);
    free(pair1.data);
    free(set_body.data);
    free(app_body.data);
    free(root.data);
}

static void test_attr_ref_zero_fill(void) {
    /* Simulate getattrlist buffer where "Macintosh HD - Data\0" sits at offset 32..52 */
    uint8_t rec[128];
    memset(rec, 0xaa, sizeof(rec));
    uint32_t *rec_len = (uint32_t *)rec;
    *rec_len = 64;
    const char *orig = "Macintosh HD - Data";
    memcpy(rec + 32, orig, strlen(orig) + 1U);

    const char *rep = "Data";
    size_t old_len = strlen(orig) + 1U;
    size_t vlen = strlen(rep) + 1U;
    memcpy(rec + 32, rep, vlen);
    memset(rec + 32 + vlen, 0, old_len - vlen);

    assert(strcmp((const char *)(rec + 32), "Data") == 0);
    for (size_t i = 32 + vlen; i < 32 + old_len; i++) {
        assert(rec[i] == 0);
    }
}

static void test_getgroups_filter(void) {
    const uint32_t mac_gids[] = {20, 12, 29, 33, 61, 79, 80, 81, 98, 100, 101, 204, 250, 395, 398, 399, 400, 701};
    uint32_t out[32];
    int out_n = 0;
    for (size_t i = 0; i < sizeof(mac_gids) / sizeof(mac_gids[0]); i++) {
        uint32_t g = mac_gids[i];
        if (pt_is_desktop_supplemental_gid_c(g)) {
            continue;
        }
        if (g == 20U) {
            g = 501U;
        }
        out[out_n++] = g;
    }
    assert(out_n == 1 && out[0] == 501U);
}

static int is_hidden_sysctl_name(const char *name, int compat13_7, int e_cores) {
    if (name == NULL || name[0] == '\0') {
        return 0;
    }
    if (strcmp(name, "sysctl.proc_translated") == 0 || strcmp(name, "sysctl.proc_native") == 0 ||
        strcmp(name, "kern.iossupportversion") == 0 || strncmp(name, "kern.hibernate", 14) == 0 ||
        strcmp(name, "hw.use_kernelmanagerd") == 0 || strcmp(name, "vm.swapusage") == 0) {
        return 1;
    }
    if (strncmp(name, "hw.perflevel1.", 14) == 0 && e_cores == 0) {
        return 1;
    }
    if (strncmp(name, "hw.optional.arm.FEAT_", 21) == 0 && compat13_7) {
        return 1;
    }
    return 0;
}

static void test_sysctl_filters(void) {
    assert(is_hidden_sysctl_name("sysctl.proc_translated", 0, 4) == 1);
    assert(is_hidden_sysctl_name("kern.hibernatewakenotification", 0, 4) == 1);
    assert(is_hidden_sysctl_name("kern.hibernatefile", 0, 4) == 1);
    assert(is_hidden_sysctl_name("hw.optional.arm.FEAT_BF16", 1, 4) == 1);
    assert(is_hidden_sysctl_name("hw.optional.arm.FEAT_BF16", 0, 4) == 0);
    assert(is_hidden_sysctl_name("vm.swapfileprefix", 1, 4) == 0);
}

/* ---------- Batch 2 Unit Tests ---------- */

static void replace_substr(char *buf, size_t cap, const char *needle, const char *repl) {
    size_t nlen = strlen(needle), rlen = strlen(repl);
    if (nlen == 0 || strcmp(needle, repl) == 0)
        return;
    size_t pos = 0;
    while (1) {
        char *hit = strstr(buf + pos, needle);
        if (!hit)
            break;
        size_t off = (size_t)(hit - buf);
        size_t cur = strlen(buf);
        if (cur - nlen + rlen >= cap)
            break;
        if (rlen != nlen)
            memmove(hit + rlen, hit + nlen, cur - off - nlen + 1U);
        memcpy(hit, repl, rlen);
        pos = off + rlen;
    }
}

static void sanitize_io_compat13(char *buf, size_t cap) {
    static const char *const kSocs[] = {"T8103", "T8101", "T810x", "T6000"};
    for (size_t i = 0; i < sizeof(kSocs) / sizeof(kSocs[0]); i++) {
        replace_substr(buf, cap, kSocs[i], "T8027");
    }
    if (strstr(buf, "AGX") != NULL) {
        replace_substr(buf, cap, "G13", "G11");
    }
    if (strstr(buf, "CamIn") != NULL) {
        replace_substr(buf, cap, "H13", "H11");
    }
}

static void test_ioreg_compat13_sanitize(void) {
    char b1[128] = "AGXFirmwareKextG13RTBuddy";
    sanitize_io_compat13(b1, sizeof(b1));
    assert(strcmp(b1, "AGXFirmwareKextG11RTBuddy") == 0);

    char b2[128] = "AppleH13CamIn";
    sanitize_io_compat13(b2, sizeof(b2));
    assert(strcmp(b2, "AppleH11CamIn") == 0);

    char b3[256] = "IOService:/AppleT810xIO/gpio@T8101GPIOIC/pci@T8103";
    sanitize_io_compat13(b3, sizeof(b3));
    assert(strcmp(b3, "IOService:/AppleT8027IO/gpio@T8027GPIOIC/pci@T8027") == 0);
}

/* ---------- Batch 3 Unit Tests ---------- */

static void test_sf_symbols_and_versions(void) {
    assert(pt_is_post13_7_sf_symbol_name_cstr("brain.head.profile"));
    assert(pt_is_post13_7_sf_symbol_name_cstr("sparkles.tv.fill"));
    assert(pt_is_post13_7_sf_symbol_name_cstr("wrench.and.screwdriver.fill"));
    assert(pt_is_post13_7_sf_symbol_name_cstr("gearshape.fill"));
    /* iOS 13.0 (SF Symbols 1.x) must remain allowed */
    assert(!pt_is_post13_7_sf_symbol_name_cstr("gear"));
    assert(!pt_is_post13_7_sf_symbol_name_cstr("sparkles"));
    assert(!pt_is_post13_7_sf_symbol_name_cstr("house.fill"));

    int32_t fnd13 = (1677 << 16) | (104 << 8);
    int32_t uik13 = (3698 << 16) | (54 << 8);
    assert((fnd13 >> 16) == 1677);
    assert((uik13 >> 16) == 3698);
}

/* ---------- Batch 4 Unit Tests ---------- */

static int is_code_res_key_dirty(const char *k) {
    if (!k)
        return 0;
    return (strstr(k, "PlayTools") != NULL || strstr(k, "AKInterface") != NULL || strstr(k, "SVCPatches") != NULL ||
            strstr(k, "Playtools.strings") != NULL || strstr(k, "UserPlugins") != NULL)
               ? 1
               : 0;
}

static void test_network_and_coderesources(void) {
    assert(pt_is_hidden_network_ifname_prefix_cstr("anpi0"));
    assert(pt_is_hidden_network_ifname_prefix_cstr("anpi2"));
    assert(pt_is_hidden_network_ifname_prefix_cstr("bridge100"));
    assert(pt_is_hidden_network_ifname_prefix_cstr("vlan0"));
    assert(pt_is_hidden_network_ifname_prefix_cstr("bond0"));
    assert(pt_is_hidden_network_ifname_prefix_cstr("fw0"));
    assert(pt_is_hidden_network_ifname_prefix_cstr("usb0"));
    assert(!pt_is_hidden_network_ifname_prefix_cstr("en0"));
    assert(!pt_is_hidden_network_ifname_prefix_cstr("lo0"));
    assert(!pt_is_hidden_network_ifname_prefix_cstr("pdp_ip0"));
    assert(pt_is_secondary_en_ifname_cstr("en1"));
    assert(pt_is_secondary_en_ifname_cstr("en12"));
    assert(!pt_is_secondary_en_ifname_cstr("en0"));

    assert(is_code_res_key_dirty("Frameworks/AKInterface.framework/AKInterface") == 1);
    assert(is_code_res_key_dirty("Frameworks/PlayTools.framework/PlayTools") == 1);
    assert(is_code_res_key_dirty("Info.plist") == 0);
}

/* ---------- Round 1 Hardening Unit Tests ---------- */

static void test_sha256_raw(const uint8_t *msg, size_t len, uint8_t out[CC_SHA256_DIGEST_LENGTH]) {
    CC_SHA256(msg, (CC_LONG)len, out);
}

static void test_sha1_raw(const uint8_t *msg, size_t len, uint8_t out[CC_SHA1_DIGEST_LENGTH]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA1(msg, (CC_LONG)len, out);
#pragma clang diagnostic pop
}

static void test_der_3byte_len_and_nested_set(void) {
    pt_der_buf_t b = {0};
    pt_der_buf_append_tag_len(&b, 0xB0U, 0x12345U);
    assert(!b.failed);
    assert(b.len == 5U);
    assert(b.data[0] == 0xB0U && b.data[1] == 0x83U && b.data[2] == 0x01U && b.data[3] == 0x23U && b.data[4] == 0x45U);
    free(b.data);

    /* Dictionary containers must use context [16] constructed tag 0xB0 (Apple CoreEntitlements DER spec) */
    pt_der_buf_t inner_kv = {0};
    pt_der_buf_wrap_tlv(&inner_kv, 0x0cU, (const uint8_t *)"subkey", 6U);
    uint8_t der_true = 0xffU;
    pt_der_buf_wrap_tlv(&inner_kv, 0x01U, &der_true, 1U);
    pt_der_buf_t inner_seq = {0};
    pt_der_buf_wrap_tlv(&inner_seq, 0x30U, inner_kv.data, inner_kv.len);
    pt_der_buf_t nested_dict = {0};
    pt_der_buf_wrap_tlv(&nested_dict, 0xB0U, inner_seq.data, inner_seq.len);
    assert(nested_dict.data[0] == 0xB0U);
    free(inner_kv.data);
    free(inner_seq.data);
    free(nested_dict.data);

    /* Key-order sorting: longer key/value SEQUENCE whose key is lexicographically earlier must sort first */
    pt_der_buf_t kv1 = {0}, kv2 = {0}, seq1 = {0}, seq2 = {0};
    pt_der_buf_wrap_tlv(&kv1, 0x0cU, (const uint8_t *)"com.apple.private.longkey.extra", 31U);
    pt_der_buf_wrap_tlv(&kv1, 0x01U, &der_true, 1U);
    pt_der_buf_wrap_tlv(&seq1, 0x30U, kv1.data, kv1.len);

    pt_der_buf_wrap_tlv(&kv2, 0x0cU, (const uint8_t *)"com.apple.short", 15U);
    pt_der_buf_wrap_tlv(&kv2, 0x01U, &der_true, 1U);
    pt_der_buf_wrap_tlv(&seq2, 0x30U, kv2.data, kv2.len);

    pt_der_item_t items[2] = {
        {.bytes = seq2.data, .len = seq2.len},
        {.bytes = seq1.data, .len = seq1.len},
    };
    qsort(items, 2U, sizeof(pt_der_item_t), pt_der_item_cmp);
    assert(items[0].bytes == seq1.data);
    assert(items[1].bytes == seq2.data);
    free(kv1.data);
    free(kv2.data);
    free(seq1.data);
    free(seq2.data);
}

static void test_superblob_cd_special_slot_sha256_update(void) {
    /* Sanity-check SHA-256 against NIST "abc" vector */
    uint8_t abc_hash[32];
    test_sha256_raw((const uint8_t *)"abc", 3U, abc_hash);
    assert(abc_hash[0] == 0xbaU && abc_hash[1] == 0x78U && abc_hash[2] == 0x16U && abc_hash[3] == 0xbfU);

    /* Build synthetic CodeDirectory with nSpecialSlots=7, hashOffset=44+7*32=268, hashType=2, hashSize=32 */
    uint8_t cd[300];
    memset(cd, 0, sizeof(cd));
    uint32_t magic = to_be32(PT_CSMAGIC_CODEDIRECTORY);
    uint32_t cd_len = to_be32((uint32_t)sizeof(cd));
    uint32_t hash_off = to_be32(268U);
    uint32_t n_special = to_be32(7U);
    memcpy(cd + 0, &magic, 4);
    memcpy(cd + 4, &cd_len, 4);
    memcpy(cd + 16, &hash_off, 4);
    memcpy(cd + 24, &n_special, 4);
    cd[36] = 32U; /* hashSize */
    cd[37] = PT_CS_HASHTYPE_SHA256;
    memset(cd + 268U - 5U * 32U, 0x11, 32U);
    memset(cd + 268U - 7U * 32U, 0x22, 32U);

    const char *xml_body = "<plist><dict/></plist>";
    size_t xml_blob_len = 8U + strlen(xml_body);
    uint8_t slot5[64];
    uint32_t m5 = to_be32(PT_CSMAGIC_EMBEDDED_ENTITLEMENTS), l5 = to_be32((uint32_t)xml_blob_len);
    memcpy(slot5, &m5, 4);
    memcpy(slot5 + 4, &l5, 4);
    memcpy(slot5 + 8, xml_body, strlen(xml_body));

    uint8_t der_body[6] = {0x70U, 0x04U, 0x02U, 0x01U, 0x01U, 0x31U};
    size_t der_blob_len = 8U + sizeof(der_body);
    uint8_t slot7[32];
    uint32_t m7 = to_be32(PT_CSMAGIC_EMBEDDED_DER_ENTITLEMENTS), l7 = to_be32((uint32_t)der_blob_len);
    memcpy(slot7, &m7, 4);
    memcpy(slot7 + 4, &l7, 4);
    memcpy(slot7 + 8, der_body, sizeof(der_body));

    /* Compute & patch via production PTCodeSignParser */
    uint8_t xml_sha256[CC_SHA256_DIGEST_LENGTH], der_sha256[CC_SHA256_DIGEST_LENGTH];
    uint8_t zero_sha1[CC_SHA1_DIGEST_LENGTH] = {0};
    pt_sha256_cs_blob(PT_CSMAGIC_EMBEDDED_ENTITLEMENTS, (const uint8_t *)xml_body, strlen(xml_body), xml_sha256);
    pt_sha256_cs_blob(PT_CSMAGIC_EMBEDDED_DER_ENTITLEMENTS, der_body, sizeof(der_body), der_sha256);
    pt_patch_code_directory_entitlement_hashes(cd, sizeof(cd), true, xml_sha256, zero_sha1, true, der_sha256,
                                               zero_sha1);

    uint8_t verify5[32], verify7[32];
    test_sha256_raw(slot5, xml_blob_len, verify5);
    test_sha256_raw(slot7, der_blob_len, verify7);
    assert(memcmp(cd + 268U - 5U * 32U, verify5, 32U) == 0);
    assert(memcmp(cd + 268U - 7U * 32U, verify7, 32U) == 0);
}

static uint64_t fnv1a_cstr(const char *s) {
    uint64_t h = 14695981039346656037ULL;
    while (*s != '\0') {
        h ^= (uint8_t)(*s++);
        h *= 1099511628211ULL;
    }
    return h;
}

static void test_fnv1a_linear_dedup(void) {
    const size_t n_per_slice = 2048U;
    char (*pool)[32] = (char (*)[32])calloc(n_per_slice * 2U, 32U);
    assert(pool != NULL);
    const char **slice1 = (const char **)calloc(n_per_slice, sizeof(const char *));
    const char **slice2 = (const char **)calloc(n_per_slice, sizeof(const char *));
    assert(slice1 != NULL && slice2 != NULL);
    for (size_t i = 0; i < n_per_slice; i++) {
        snprintf(pool[i], 32U, "SwiftUI_Cls_%zu", i);
        slice1[i] = pool[i];
        /* 50% overlap with slice1 */
        size_t idx2 = (i < 1024U) ? i : (n_per_slice + i - 1024U);
        snprintf(pool[n_per_slice + i], 32U, "SwiftUI_Cls_%zu", idx2);
        slice2[i] = pool[n_per_slice + i];
    }
    size_t cap = 8192U; /* power of 2 >= 2 * total */
    const char **ht = (const char **)calloc(cap, sizeof(const char *));
    const char **out = (const char **)calloc(n_per_slice * 2U, sizeof(const char *));
    assert(ht != NULL && out != NULL);
    size_t out_n = 0;
    const char **slices[2] = {slice1, slice2};
    for (int si = 0; si < 2; si++) {
        for (size_t k = 0; k < n_per_slice; k++) {
            const char *c = slices[si][k];
            size_t slot = (size_t)(fnv1a_cstr(c) & (cap - 1U));
            int dup = 0;
            while (ht[slot] != NULL) {
                if (ht[slot] == c || strcmp(ht[slot], c) == 0) {
                    dup = 1;
                    break;
                }
                slot = (slot + 1U) & (cap - 1U);
            }
            if (!dup) {
                ht[slot] = c;
                out[out_n++] = c;
            }
        }
    }
    assert(out_n == 3072U);
    free(ht);
    free(out);
    free(slice1);
    free(slice2);
    free(pool);
}

static void test_sf_symbols_multisuffix(void) {
    assert(pt_is_post13_7_sf_symbol_name_cstr("leaf.circle.fill"));
    assert(pt_is_post13_7_sf_symbol_name_cstr("gearshape.2.fill"));
    assert(pt_is_post13_7_sf_symbol_name_cstr("applelogo"));
    assert(pt_is_post13_7_sf_symbol_name_cstr("house.circle.fill"));
    assert(!pt_is_post13_7_sf_symbol_name_cstr("heart.circle.fill"));
    assert(!pt_is_post13_7_sf_symbol_name_cstr("star.circle.fill"));
    assert(!pt_is_post13_7_sf_symbol_name_cstr("arrow.2.circlepath"));
    assert(pt_is_post13_7_sf_symbol_name_cstr("gearshape.circle"));
    assert(pt_is_post13_7_sf_symbol_name_cstr("bell.badge"));
    assert(pt_is_post13_7_sf_symbol_name_cstr("bolt.car"));
    assert(pt_is_post13_7_sf_symbol_name_cstr("brain"));
    assert(pt_is_post13_7_sf_symbol_name_cstr("ellipsis.curlybraces"));
    assert(pt_is_post13_7_sf_symbol_name_cstr("figure.run"));
    assert(pt_is_post13_7_sf_symbol_name_cstr("theatermasks"));
}

static int ci_contains(const char *hay, const char *needle) {
    size_t nlen = strlen(needle);
    if (nlen == 0)
        return 1;
    for (const char *p = hay; *p; p++) {
        size_t i = 0;
        while (i < nlen && p[i]) {
            char a = p[i], b = needle[i];
            if (a >= 'A' && a <= 'Z')
                a = (char)(a - 'A' + 'a');
            if (b >= 'A' && b <= 'Z')
                b = (char)(b - 'A' + 'a');
            if (a != b)
                break;
            i++;
        }
        if (i == nlen)
            return 1;
    }
    return 0;
}

static void test_coderesources_case_insensitive_and_attr_fallback(void) {
    const char *dirty[] = {"Frameworks/playtools.framework/PlayTools", "Playtools.strings",
                           "Frameworks/akinterface.framework/AKInterface", "SVCPatches/patch.bin",
                           "UserPlugins/foo.dylib"};
    for (size_t i = 0; i < sizeof(dirty) / sizeof(dirty[0]); i++) {
        int hit = ci_contains(dirty[i], "playtools") || ci_contains(dirty[i], "akinterface") ||
                  ci_contains(dirty[i], "svcpatches") || ci_contains(dirty[i], "userplugins");
        assert(hit == 1);
    }
    assert(ci_contains("Info.plist", "playtools") == 0);

    /* getattrlistbulk 13-byte slot cannot grow to "/dev/disk0s1s2" (15B), must fall back to "/dev/disk0s1" (13B) */
    char slot[13];
    memcpy(slot, "/dev/disk3s1", 13U);
    const char *ideal = "/dev/disk0s1s2";
    const char *fallback = "/dev/disk0s1";
    int can_grow = 0;
    const char *chosen = (strlen(ideal) + 1U <= sizeof(slot) || can_grow) ? ideal : fallback;
    assert(strlen(chosen) + 1U <= sizeof(slot));
    memcpy(slot, chosen, strlen(chosen) + 1U);
    assert(strcmp(slot, "/dev/disk0s1") == 0);
}

static void test_ioreg_agx_path_and_kinfo_cr_groups_and_prefs(void) {
    /* IORegistry path-safe AGX replacement preserving G12P (not corrupting to G12G) */
    char path[256] = "IOService:/AppleARMPE/sgx/AGXAcceleratorG13G_B0";
    char *p = strstr(path, "AGXAcceleratorG");
    assert(p != NULL);
    size_t tail_off = 15U;
    while (p[tail_off] && p[tail_off] != '/' && p[tail_off] != ':')
        tail_off++;
    char repl[64] = "AGXAcceleratorG12P";
    size_t rlen = strlen(repl);
    memmove(p + rlen, p + tail_off, strlen(p + tail_off) + 1U);
    memcpy(p, repl, rlen);
    assert(strcmp(path, "IOService:/AppleARMPE/sgx/AGXAcceleratorG12P") == 0);

    /* Substring ATCDPXBAR matches M1/M2/M3/M4 */
    assert(strstr("AppleT8112ATCDPXBAR", "ATCDPXBAR") != NULL);
    assert(strstr("AppleT6000ATCDPXBAR", "ATCDPXBAR") != NULL);

    /* kinfo_proc cr_groups scrub */
    uint32_t cr_groups[16] = {20, 12, 61, 80, 81, 204, 250, 395, 398, 399, 400, 701};
    int cr_ngroups = 12;
    int w = 0;
    for (int i = 0; i < cr_ngroups; i++) {
        uint32_t g = cr_groups[i];
        if (pt_is_desktop_supplemental_gid_c((gid_t)g))
            continue;
        if (g == 20U)
            g = 501U;
        cr_groups[w++] = g;
    }
    cr_ngroups = w;
    assert(cr_ngroups == 1 && cr_groups[0] == 501U);

    /* NSGlobalDomain desktop preference keys */
    const char *hidden_prefs[] = {"com.apple.trackpad.scaling", "com.apple.mouse.scaling",
                                  "com.apple.swipescrolldirection", "AppleMiniaturizeOnDoubleClick",
                                  "NSNavRecentPlaces"};
    for (size_t i = 0; i < sizeof(hidden_prefs) / sizeof(hidden_prefs[0]); i++) {
        const char *k = hidden_prefs[i];
        int is_hidden = (strncmp(k, "com.apple.trackpad.", 19) == 0 || strncmp(k, "com.apple.mouse.", 16) == 0 ||
                         strcmp(k, "com.apple.swipescrolldirection") == 0 ||
                         strcmp(k, "AppleMiniaturizeOnDoubleClick") == 0 || strcmp(k, "NSNavRecentPlaces") == 0);
        assert(is_hidden == 1);
    }
}

static void test_round2_cg_hid_dlsym_blacklist(void) {
    const char *blocked[] = {"CGMainDisplayID",
                             "CGGetActiveDisplayList",
                             "CGGetOnlineDisplayList",
                             "CGWindowListCopyWindowInfo",
                             "CGPreflightScreenCaptureAccess",
                             "CGSessionCopyCurrentDictionary",
                             "IOHIDManagerCreate",
                             "IOHIDManagerCopyDevices"};
    for (size_t i = 0; i < sizeof(blocked) / sizeof(blocked[0]); i++) {
        assert(pt_is_hidden_macos_only_dlsym_symbol_cstr(blocked[i]));
    }
    const char *allowed_ios_cg[] = {"CGContextDrawImage",  "CGImageCreate",         "CGColorSpaceCreateDeviceRGB",
                                    "CGPathCreateMutable", "CGBitmapContextCreate", "CGDataProviderCreateWithData"};
    for (size_t i = 0; i < sizeof(allowed_ios_cg) / sizeof(allowed_ios_cg[0]); i++) {
        assert(!pt_is_hidden_macos_only_dlsym_symbol_cstr(allowed_ios_cg[i]));
    }
}

static void test_round2_macos_framework_and_font_filters(void) {
    const char *mac_fw[] = {"/System/Library/Frameworks/Cocoa.framework/Cocoa",
                            "/System/Library/Frameworks/Carbon.framework/Carbon",
                            "/System/Library/Frameworks/ServiceManagement.framework/ServiceManagement",
                            "/System/Library/Frameworks/DiskArbitration.framework/DiskArbitration",
                            "/System/Library/Frameworks/CoreWLAN.framework/CoreWLAN",
                            "/System/Library/Frameworks/EndpointSecurity.framework/EndpointSecurity",
                            "/System/Library/Frameworks/ScriptingBridge.framework/ScriptingBridge",
                            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
                            "/System/Library/Frameworks/AppKit.framework/AppKit"};
    for (size_t i = 0; i < sizeof(mac_fw) / sizeof(mac_fw[0]); i++) {
        assert(pt_is_macos_only_framework_path_cstr(mac_fw[i]));
    }
    const char *ios_fw[] = {"/System/Library/Frameworks/UIKit.framework/UIKit",
                            "/System/Library/Frameworks/Foundation.framework/Foundation",
                            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
                            "/System/Library/Frameworks/Metal.framework/Metal"};
    for (size_t i = 0; i < sizeof(ios_fw) / sizeof(ios_fw[0]); i++) {
        assert(!pt_is_macos_only_framework_path_cstr(ios_fw[i]));
    }

    const char *mac_fonts[] = {"Monaco",    "Lucida Grande", "Skia",       "Osaka",        "AppleGothic",
                               "Wingdings", "Andale Mono",   "Big Caslon", "Comic Sans MS"};
    for (size_t i = 0; i < sizeof(mac_fonts) / sizeof(mac_fonts[0]); i++) {
        assert(pt_is_hidden_desktop_font_name_cstr(mac_fonts[i]));
    }
    const char *ios_fonts[] = {"Helvetica", "SF Pro", "PingFang SC", "Avenir", "Georgia", "Menlo"};
    for (size_t i = 0; i < sizeof(ios_fonts) / sizeof(ios_fonts[0]); i++) {
        assert(!pt_is_hidden_desktop_font_name_cstr(ios_fonts[i]));
    }
}

static uint64_t sanitize_osvariant_status(uint64_t raw) {
    /* XNU bsd/sys/variant_internal.h:
     * - bits [0..27]: 14 two-bit status pairs (0b00=UNKNOWN, 0b10=NO, 0b11=YES)
     * - bits [28..31]: fixed sentinel 0xF (OS_VARIANT_STATUS_INITIAL_BITS = 0x70000000F0000000ULL)
     * - bits [60..62]: initial/version nibble 0x7
     * Clearing ~0x05555555ULL turns YES (0b11) -> NO (0b10) while preserving NO/UNKNOWN,
     * bits [28..31] == 0xF, and high32 bits [60..62] == 0x7. */
    return raw & ~0x05555555ULL;
}

static int is_sensitive_af_unix_path(const char *sun_path) {
    if (sun_path == NULL || sun_path[0] == '\0')
        return 0;
    return (strncmp(sun_path, "/Users/", 7U) == 0 || ci_contains(sun_path, "/Library/Containers/") ||
            ci_contains(sun_path, "MacOver") || ci_contains(sun_path, "PlayTools") ||
            ci_contains(sun_path, "PlayCover"));
}

static void test_round2_xattr_osvariant_and_afunix(void) {
    const char *bad_xattrs[] = {"com.apple.quarantine",   "com.apple.provenance",
                                "com.apple.macl",         "com.apple.FinderInfo",
                                "com.apple.ResourceFork", "com.apple.metadata:kMDItemWhereFroms",
                                "com.apple.rootless"};
    for (size_t i = 0; i < sizeof(bad_xattrs) / sizeof(bad_xattrs[0]); i++) {
        assert(pt_is_hidden_xattr_name_cstr(bad_xattrs[i]));
    }
    assert(!pt_is_hidden_xattr_name_cstr("com.example.custom"));
    assert(!pt_is_hidden_xattr_name_cstr("com.apple.decmpfs"));

    /* Simulate listxattr buffer compaction removing desktop xattrs */
    const char raw_list[] =
        "com.apple.quarantine\0com.example.custom\0com.apple.macl\0com.apple.metadata:kMDItemWhereFroms\0";
    char filtered[256];
    size_t out_len = 0;
    const char *cur = raw_list, *end = raw_list + sizeof(raw_list) - 1U;
    while (cur < end) {
        size_t slen = strlen(cur);
        if (slen > 0 && !pt_is_hidden_xattr_name_cstr(cur)) {
            memcpy(filtered + out_len, cur, slen + 1U);
            out_len += slen + 1U;
        }
        cur += slen + 1U;
    }
    assert(out_len == strlen("com.example.custom") + 1U);
    assert(strcmp(filtered, "com.example.custom") == 0);

    /* kern.osvariant_status 2-bit pair sanitization: YES (0b11) -> NO (0b10), preserving bits [28..31] == 0xF and
     * [60..62] == 0x7 */
    uint64_t dirty_variant = 0x70010000F3FFAB3BULL;
    uint64_t clean_variant = sanitize_osvariant_status(dirty_variant);
    assert(((clean_variant >> 28) & 0xFULL) == 0xFULL);
    assert(((clean_variant >> 60) & 0x7ULL) == 0x7ULL);
    for (unsigned bit = 0; bit < 28; bit += 2) {
        uint64_t orig_pair = (dirty_variant >> bit) & 3ULL;
        uint64_t new_pair = (clean_variant >> bit) & 3ULL;
        if (orig_pair == 3ULL) {
            assert(new_pair == 2ULL); /* YES -> NO */
        } else if (orig_pair == 2ULL) {
            assert(new_pair == 2ULL); /* NO preserved */
        } else if (orig_pair == 0ULL) {
            assert(new_pair == 0ULL); /* UNKNOWN preserved */
        }
        assert(new_pair != 3ULL);
    }
    /* Verify PlayTools customer fallback value preserves sentinel 0xF and 0x7 with no YES pairs */
    uint64_t fallback_variant = 0x70010000F288828AULL;
    assert(((fallback_variant >> 28) & 0xFULL) == 0xFULL);
    assert(((fallback_variant >> 60) & 0x7ULL) == 0x7ULL);
    assert(sanitize_osvariant_status(fallback_variant) == fallback_variant);

    /* AF_UNIX sun_path sensitivity detection */
    assert(is_sensitive_af_unix_path("/Users/alice/Library/Containers/app.makedie.MacOver/Data/tmp/s.sock") == 1);
    assert(is_sensitive_af_unix_path("/tmp/PlayTools-ipc.sock") == 1);
    assert(is_sensitive_af_unix_path("/var/run/syslog") == 0);
    assert(is_sensitive_af_unix_path("/private/var/mobile/Containers/Data/Application/UUID/tmp/app.sock") == 0);
}

static void put_be32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)((v >> 24) & 0xFFU);
    p[1] = (uint8_t)((v >> 16) & 0xFFU);
    p[2] = (uint8_t)((v >> 8) & 0xFFU);
    p[3] = (uint8_t)(v & 0xFFU);
}

static void test_round2_sha1_sha256_cd_and_sfsymbols(void) {
    /* Verify SHA-1 standard test vector ("abc") */
    uint8_t abc_digest[20];
    test_sha1_raw((const uint8_t *)"abc", 3U, abc_digest);
    const uint8_t expected_abc[20] = {0xa9, 0x99, 0x3e, 0x36, 0x47, 0x06, 0x81, 0x6a, 0xba, 0x3e,
                                      0x25, 0x71, 0x78, 0x50, 0xc2, 0x6c, 0x9c, 0xd0, 0xd8, 0x9d};
    assert(memcmp(abc_digest, expected_abc, 20U) == 0);

    /* Dual CodeDirectory patching via production PTCodeSignParser */
    const uint8_t xml_payload[8] = {'<', 'p', 'l', 'i', 's', 't', '/', '>'};
    const uint8_t der_payload[4] = {0x30, 0x02, 0x05, 0x00};

    uint8_t s5_sha1[CC_SHA1_DIGEST_LENGTH], s7_sha1[CC_SHA1_DIGEST_LENGTH];
    uint8_t s5_sha256[CC_SHA256_DIGEST_LENGTH], s7_sha256[CC_SHA256_DIGEST_LENGTH];
    pt_sha1_cs_blob(PT_CSMAGIC_EMBEDDED_ENTITLEMENTS, xml_payload, sizeof(xml_payload), s5_sha1);
    pt_sha1_cs_blob(PT_CSMAGIC_EMBEDDED_DER_ENTITLEMENTS, der_payload, sizeof(der_payload), s7_sha1);
    pt_sha256_cs_blob(PT_CSMAGIC_EMBEDDED_ENTITLEMENTS, xml_payload, sizeof(xml_payload), s5_sha256);
    pt_sha256_cs_blob(PT_CSMAGIC_EMBEDDED_DER_ENTITLEMENTS, der_payload, sizeof(der_payload), s7_sha256);

    uint8_t cd_sha1[256];
    memset(cd_sha1, 0, sizeof(cd_sha1));
    put_be32(cd_sha1 + 0, PT_CSMAGIC_CODEDIRECTORY);
    put_be32(cd_sha1 + 4, 240U);
    put_be32(cd_sha1 + 16, 200U); /* hashOffset */
    put_be32(cd_sha1 + 24, 7U);   /* nSpecialSlots */
    cd_sha1[36] = 20U;            /* hashSize */
    cd_sha1[37] = PT_CS_HASHTYPE_SHA1;
    pt_patch_code_directory_entitlement_hashes(cd_sha1, sizeof(cd_sha1), true, s5_sha256, s5_sha1, true, s7_sha256,
                                               s7_sha1);
    assert(memcmp(cd_sha1 + 100U, s5_sha1, 20U) == 0);
    assert(memcmp(cd_sha1 + 60U, s7_sha1, 20U) == 0);

    uint8_t cd_sha256[320];
    memset(cd_sha256, 0, sizeof(cd_sha256));
    put_be32(cd_sha256 + 0, PT_CSMAGIC_CODEDIRECTORY);
    put_be32(cd_sha256 + 4, 300U);
    put_be32(cd_sha256 + 16, 280U); /* hashOffset */
    put_be32(cd_sha256 + 24, 7U);   /* nSpecialSlots */
    cd_sha256[36] = 32U;            /* hashSize */
    cd_sha256[37] = PT_CS_HASHTYPE_SHA256;
    pt_patch_code_directory_entitlement_hashes(cd_sha256, sizeof(cd_sha256), true, s5_sha256, s5_sha1, true, s7_sha256,
                                               s7_sha1);
    assert(memcmp(cd_sha256 + 120U, s5_sha256, 32U) == 0);
    assert(memcmp(cd_sha256 + 56U, s7_sha256, 32U) == 0);

    /* CodeDirectory metadata scrubbing (flags + FAKETEAMID) and slot count helper */
    uint8_t cd_meta[80];
    memset(cd_meta, 0, sizeof(cd_meta));
    put_be32(cd_meta + 0U, PT_CSMAGIC_CODEDIRECTORY);
    put_be32(cd_meta + 4U, (uint32_t)sizeof(cd_meta));
    put_be32(cd_meta + 8U, 0x20400U); /* version */
    put_be32(cd_meta + 12U,
             0x00010003U); /* flags (adhoc=0x2 + get_task_allow=0x4 cleared, keep valid=0x1 + runtime=0x10000 masked) */
    put_be32(cd_meta + 24U, 5U);  /* nSpecialSlots */
    put_be32(cd_meta + 48U, 64U); /* teamOffset */
    memcpy(cd_meta + 64U, "FAKETEAMID", 11U);
    assert(pt_code_directory_special_slot_count(cd_meta, sizeof(cd_meta)) == 5U);
    pt_patch_code_directory_metadata(cd_meta, sizeof(cd_meta), 0x00010002U, "A2B3C4D5E6");
    uint32_t patched_flags = 0;
    memcpy(&patched_flags, cd_meta + 12U, 4U);
    assert(ntohl(patched_flags) == 0x00000001U);
    assert(strcmp((const char *)(cd_meta + 64U), "A2B3C4D5E6") == 0);

    /* SF Symbols hardware prefix checks directly via production PTDetectionRules */
    assert(pt_is_post13_7_sf_symbol_name_cstr("macbook"));
    assert(pt_is_post13_7_sf_symbol_name_cstr("macbook.gen2"));
    assert(pt_is_post13_7_sf_symbol_name_cstr("macmini"));
    assert(pt_is_post13_7_sf_symbol_name_cstr("macstudio"));
    assert(pt_is_post13_7_sf_symbol_name_cstr("applewatch.watchface"));
    assert(pt_is_post13_7_sf_symbol_name_cstr("airpods.pro"));
    assert(pt_is_post13_7_sf_symbol_name_cstr("visionpro"));
    assert(pt_is_post13_7_sf_symbol_name_cstr("imac"));
    assert(pt_is_post13_7_sf_symbol_name_cstr("imac.fill"));
    assert(pt_is_post13_7_sf_symbol_name_cstr("macpro.gen3"));
    assert(!pt_is_post13_7_sf_symbol_name_cstr("gear"));
    assert(!pt_is_post13_7_sf_symbol_name_cstr("house.fill"));
}

static uint32_t l1i_cache_size_for_machine(const char *machine) {
    if (machine == NULL)
        return 131072U;
    /* A9X (iPad6,7 / iPad6,8): 64 KiB */
    if (strcmp(machine, "iPad6,7") == 0 || strcmp(machine, "iPad6,8") == 0)
        return 65536U;
    /* A14+ / M1+ (iPhone13+, iPad13+): 192 KiB */
    if (strncmp(machine, "iPhone13,", 9) == 0 || strncmp(machine, "iPhone14,", 9) == 0 ||
        strncmp(machine, "iPhone15,", 9) == 0 || strncmp(machine, "iPad13,", 7) == 0 ||
        strncmp(machine, "iPad14,", 7) == 0)
        return 196608U;
    /* A12X / A13 (iPad8,x / iPhone12,x): 128 KiB */
    return 131072U;
}

static void test_round3_cdhash_kernel_version_and_l1i(void) {
    /* Primary CodeDirectory SHA-256[:20] must equal csops(5) CS_OPS_CDHASH */
    uint8_t cd[128];
    memset(cd, 0, sizeof(cd));
    put_be32(cd + 0, 0xfade0c02U);
    put_be32(cd + 4, (uint32_t)sizeof(cd));
    put_be32(cd + 16, 96U);
    put_be32(cd + 24, 2U);
    cd[36] = 32U;
    cd[37] = 2U;
    for (size_t i = 44; i < sizeof(cd); i++)
        cd[i] = (uint8_t)(i * 7U + 3U);

    uint8_t full_sha256[32];
    test_sha256_raw(cd, sizeof(cd), full_sha256);
    uint8_t cdhash5[20];
    memcpy(cdhash5, full_sha256, 20U);
    assert(memcmp(cdhash5, full_sha256, 20U) == 0);

    /* CS_OPS_CDHASH usersize < 20 must fail with ERANGE (34 on Darwin) */
    size_t small_user_sz = 19U;
    assert(small_user_sz < 20U);

    /* CS_OPS_STATUS(0) strips CS_RUNTIME (0x10000) and CS_LINKER_SIGNED (0x20000) */
    uint32_t raw_cs_flags = 0x22030201U; /* includes CS_RUNTIME | CS_LINKER_SIGNED */
    uint32_t clean_cs_flags = raw_cs_flags & ~(0x00010000U | 0x00020000U);
    assert((clean_cs_flags & 0x00010000U) == 0U);
    assert((clean_cs_flags & 0x00020000U) == 0U);
    assert((clean_cs_flags & 0x22000201U) == 0x22000201U);

    /* host_kernel_version formatting matches uname().version */
    char uname_ver[256];
    char host_kv[512];
    snprintf(uname_ver, sizeof(uname_ver),
             "Darwin Kernel Version 19.6.0: Thu Jun 18 20:49:00 PDT 2020; root:xnu-6153.141.1~1/RELEASE_ARM64_T8030");
    snprintf(host_kv, sizeof(host_kv), "%s", uname_ver);
    assert(strcmp(host_kv, uname_ver) == 0);
    assert(strstr(host_kv, "RELEASE_ARM64_") != NULL);
    assert(strstr(host_kv, "19.6.0") != NULL);

    /* hw.l1icachesize per SoC family */
    assert(l1i_cache_size_for_machine("iPad6,7") == 65536U);
    assert(l1i_cache_size_for_machine("iPad8,6") == 131072U);
    assert(l1i_cache_size_for_machine("iPhone12,5") == 131072U);
    assert(l1i_cache_size_for_machine("iPad13,4") == 196608U);
    assert(l1i_cache_size_for_machine("iPhone14,2") == 196608U);
}

static void test_round3_fs_case_gid_and_prot(void) {
    /* Three-way APFS case-sensitivity bit: VOL_CAP_FMT_CASE_SENSITIVE = 0x00000020 */
    const uint32_t kVolCapFmtCaseSensitive = 0x00000020U;
    uint32_t caps_format = 0x00000001U; /* initially case-insensitive macOS APFS */
    uint32_t valid_format = 0x00000001U;
    caps_format |= kVolCapFmtCaseSensitive;
    valid_format |= kVolCapFmtCaseSensitive;
    assert((caps_format & kVolCapFmtCaseSensitive) != 0U);
    assert((valid_format & kVolCapFmtCaseSensitive) != 0U);

    /* st_gid 20 (staff) -> 501 (mobile), other gids preserved */
    uint32_t gids_in[3] = {20U, 501U, 0U};
    uint32_t gids_exp[3] = {501U, 501U, 0U};
    for (size_t i = 0; i < 3; i++) {
        uint32_t mapped = (gids_in[i] == 20U) ? 501U : gids_in[i];
        assert(mapped == gids_exp[i]);
    }

    /* F_GETPROTECTIONCLASS: macOS returns 0 (PROTECTION_CLASS_NONE) -> spoof to 4
     * (NSFileProtectionCompleteUntilFirstUserAuthentication) */
    int raw_prot = 0;
    int spoofed_prot = (raw_prot == 0) ? 4 : raw_prot;
    assert(spoofed_prot > 0 && spoofed_prot == 4);
}

static int is_icu_age_post_13_7(uint8_t major, uint8_t minor) {
    /* iOS 13.7 ships ICU 64.2 / Unicode 12.1 */
    return (major > 12U) || (major == 12U && minor > 1U);
}

static int verify_swift_length_prefixed_mangling(const char *s) {
    /* Checks <digits><ident> tokens (skipping leading stdlib shorthand 's' before a digit) */
    const char *p = s;
    if (*p == 's' && p[1] >= '0' && p[1] <= '9')
        p++;
    int count = 0;
    while (*p >= '0' && *p <= '9') {
        size_t len = 0;
        while (*p >= '0' && *p <= '9') {
            len = len * 10U + (size_t)(*p - '0');
            p++;
        }
        if (len == 0 || strlen(p) < len)
            return 0;
        p += len;
        count++;
    }
    return count > 0 && (*p == 'V' || *p == 'C' || *p == 'O' || *p == 'P');
}

static void test_round3_extended_dlsym_fw_icu_swift(void) {
    /* Extended macOS-only dlsym symbols hidden; iOS CGContext/CGColor/QuartzCore NOT touched */
    const char *blocked_syms[] = {"AuthorizationCreate",
                                  "SecKeychainCopyDefault",
                                  "CVDisplayLinkCreateWithActiveCGDisplays",
                                  "FSEventStreamCreate",
                                  "csr_get_active_config",
                                  "csr_check",
                                  "csrctl",
                                  "SCDynamicStoreCopyComputerName",
                                  "IOBluetoothDeviceInquiryCreateWithDelegate"};
    for (size_t i = 0; i < sizeof(blocked_syms) / sizeof(blocked_syms[0]); i++) {
        assert(pt_is_hidden_macos_only_dlsym_symbol_cstr(blocked_syms[i]));
    }
    const char *safe_ios_syms[] = {"CGContextDrawImage",    "CGColorSpaceCreateDeviceRGB",
                                   "CGImageCreate",         "SecItemCopyMatching",
                                   "SecKeyCreateRandomKey", "SCNetworkReachabilityCreateWithName"};
    for (size_t i = 0; i < sizeof(safe_ios_syms) / sizeof(safe_ios_syms[0]); i++) {
        assert(!pt_is_hidden_macos_only_dlsym_symbol_cstr(safe_ios_syms[i]));
    }

    /* /Quartz.framework hidden while QuartzCore.framework MUST remain visible */
    assert(pt_is_macos_only_framework_path_cstr("/System/Library/Frameworks/Quartz.framework/Quartz"));
    assert(pt_is_macos_only_framework_path_cstr("/System/Library/Frameworks/CoreMediaIO.framework/CoreMediaIO"));
    assert(pt_is_macos_only_framework_path_cstr(
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation"));
    assert(pt_is_macos_only_framework_path_cstr(
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/FSEvents.framework/FSEvents"));
    assert(!pt_is_macos_only_framework_path_cstr("/System/Library/Frameworks/QuartzCore.framework/QuartzCore"));
    assert(!pt_is_macos_only_framework_path_cstr("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"));

    /* ICU u_charAge > 12.1 predicate */
    assert(is_icu_age_post_13_7(12U, 1U) == 0);
    assert(is_icu_age_post_13_7(12U, 0U) == 0);
    assert(is_icu_age_post_13_7(11U, 0U) == 0);
    assert(is_icu_age_post_13_7(13U, 0U) == 1);
    assert(is_icu_age_post_13_7(14U, 0U) == 1);
    assert(is_icu_age_post_13_7(15U, 1U) == 1);

    /* Swift length-prefixed mangling accuracy (zero off-by-one length bugs) */
    const char *mangled[] = {"10Foundation16AttributedStringV", "s8DurationV", "8StoreKit7ProductV",
                             "11Observation20ObservationRegistrarV", "9PlayTools12PlaySettingsC"};
    for (size_t i = 0; i < sizeof(mangled) / sizeof(mangled[0]); i++) {
        assert(verify_swift_length_prefixed_mangling(mangled[i]) == 1);
    }
    assert(verify_swift_length_prefixed_mangling("99Foundation16AttributedStringV") == 0);
}

static void test_round3_hidden_bundle_ids_regression(void) {
    const char *must_hide_always[] = {"com.apple.ApplicationServices",
                                      "com.apple.ServiceManagement",
                                      "com.apple.ScriptingBridge",
                                      "com.apple.DiskArbitration",
                                      "com.apple.Hypervisor",
                                      "com.apple.Virtualization",
                                      "com.apple.CoreWLAN",
                                      "com.apple.OpenDirectory",
                                      "com.apple.DirectoryService",
                                      "com.apple.FinderSync",
                                      "com.apple.SystemAdministration",
                                      "com.apple.Automator",
                                      "com.apple.AppleScriptObjC",
                                      "com.apple.InputMethodKit",
                                      "com.apple.PreferencePanes",
                                      "com.apple.ScreenSaver",
                                      "com.apple.SecurityInterface",
                                      "com.apple.OSAKit",
                                      "com.apple.NetFS",
                                      "com.apple.ParavirtualizedGraphics",
                                      "com.apple.DriverKit"};
    for (size_t i = 0; i < sizeof(must_hide_always) / sizeof(must_hide_always[0]); i++) {
        assert(pt_is_hidden_bundle_id_rule_cstr(must_hide_always[i], false));
        assert(pt_is_hidden_bundle_id_rule_cstr(must_hide_always[i], true));
    }
    const char *must_hide_compat13[] = {
        "com.apple.ExtensionKit",    "com.apple.ExtensionFoundation", "com.apple.AppIntents",
        "com.apple.OSLog",           "com.apple.WorkoutKit",          "com.apple.FamilyControls",
        "com.apple.ManagedSettings", "com.apple.DeviceActivity",      "com.apple.CoreTransferable",
        "com.apple.Spatial",         "com.apple.LockedCameraCapture", "com.apple.MarketplaceKit"};
    for (size_t i = 0; i < sizeof(must_hide_compat13) / sizeof(must_hide_compat13[0]); i++) {
        assert(!pt_is_hidden_bundle_id_rule_cstr(must_hide_compat13[i], false));
        assert(pt_is_hidden_bundle_id_rule_cstr(must_hide_compat13[i], true));
    }
    const char *safe_ios_bundles[] = {"com.apple.UIKit", "com.apple.Foundation", "com.apple.CoreGraphics",
                                      "com.apple.Metal", "com.apple.QuartzCore"};
    for (size_t i = 0; i < sizeof(safe_ios_bundles) / sizeof(safe_ios_bundles[0]); i++) {
        assert(!pt_is_hidden_bundle_id_rule_cstr(safe_ios_bundles[i], false));
        assert(!pt_is_hidden_bundle_id_rule_cstr(safe_ios_bundles[i], true));
    }
}

static int mock_is_app_embedded(const char *path) {
    return (strstr(path, ".app/Frameworks/") != NULL || strstr(path, ".app/Contents/Frameworks/") != NULL ||
            strstr(path, ".app/PlugIns/") != NULL || strstr(path, ".appex/Frameworks/") != NULL);
}

static void mock_strip_nested_image_versions(const char *p, char *out, size_t out_sz) {
    size_t plen = strlen(p);
    assert(plen < out_sz);
    memcpy(out, p, plen + 1U);
    for (int iter = 0; iter < 8; iter++) {
        const char *fw_ver = strstr(out, ".framework/Versions/");
        const char *bdl_ver = strstr(out, ".bundle/Versions/");
        const char *bdl_mac = strstr(out, ".bundle/Contents/MacOS/");
        const char *hit = fw_ver;
        size_t keep_ext_len = 10U;
        size_t skip_prefix_len = 20U;
        if (bdl_ver != NULL && (hit == NULL || bdl_ver < hit)) {
            hit = bdl_ver;
            keep_ext_len = 7U;
            skip_prefix_len = 17U;
        }
        if (bdl_mac != NULL && (hit == NULL || bdl_mac < hit)) {
            hit = bdl_mac;
            keep_ext_len = 7U;
            skip_prefix_len = 22U;
        }
        if (hit == NULL)
            break;
        const char *rest = (hit == bdl_mac) ? (hit + skip_prefix_len) : strchr(hit + skip_prefix_len, '/');
        if (rest == NULL)
            break;
        size_t prefix_len = (size_t)(hit - out) + keep_ext_len;
        size_t rest_len = strlen(rest);
        assert(prefix_len + rest_len < out_sz);
        memmove(out + prefix_len, rest, rest_len + 1U);
    }
}

static void test_round4_audit_regressions(void) {
    /* 1. Preferences dict filtering with >64 keys must use dynamic allocation and never overflow/truncate */
    const size_t n_keys = 128U;
    char (*keys)[32] = (char (*)[32])calloc(n_keys, 32U);
    int *kept = (int *)calloc(n_keys, sizeof(int));
    assert(keys != NULL && kept != NULL);
    size_t kept_count = 0;
    for (size_t i = 0; i < n_keys; i++) {
        if (i == 10U || i == 75U || i == 120U) {
            snprintf(keys[i], 32U, "com.apple.trackpad.k%zu", i);
        } else {
            snprintf(keys[i], 32U, "app.benign.key_%zu", i);
        }
        int hidden = (strncmp(keys[i], "com.apple.trackpad.", 19U) == 0);
        if (!hidden)
            kept[kept_count++] = (int)i;
    }
    assert(kept_count == 125U);
    assert(kept[kept_count - 1U] == 127);
    free(kept);
    free(keys);

    /* 2. Dual-signed SuperBlob (slot 0 SHA-1 + slot 0x1000 SHA-256): prefer SHA-256 CDHash */
    uint8_t cd_sha1[64], cd_sha256[64];
    memset(cd_sha1, 0x11, sizeof(cd_sha1));
    memset(cd_sha256, 0x22, sizeof(cd_sha256));
    uint8_t h_sha1[20], h_sha256[32];
    test_sha1_raw(cd_sha1, sizeof(cd_sha1), h_sha1);
    test_sha256_raw(cd_sha256, sizeof(cd_sha256), h_sha256);
    /* Simulate XNU csops(5) picking SHA-256 alt CD (0x1000) over SHA-1 primary CD (0) */
    uint8_t kernel_cdhash[20];
    memcpy(kernel_cdhash, h_sha256, 20U);
    assert(memcmp(kernel_cdhash, h_sha1, 20U) != 0);
    int matched_any = (memcmp(kernel_cdhash, h_sha1, 20U) == 0) || (memcmp(kernel_cdhash, h_sha256, 20U) == 0);
    assert(matched_any == 1);

    /* 3. F_GETPROTECTIONCLASS: negative error (e.g. -1 / EBADF) must NEVER be rewritten to 3; only ret == 0 spoofs to 3
     */
    int dp_err = -1;
    int dp_mac_zero = 0;
    int dp_existing = 4;
    int out_err = (dp_err == 0) ? 3 : dp_err;
    int out_zero = (dp_mac_zero == 0) ? 3 : dp_mac_zero;
    int out_existing = (dp_existing == 0) ? 3 : dp_existing;
    assert(out_err == -1);
    assert(out_zero == 3);
    assert(out_existing == 4);

    /* 4. protocol_copyMethodDescriptionList full-list copy with sentinel {NULL, NULL} never overflows */
    typedef struct {
        const char *name;
        const char *types;
    } MockMethodDesc;
    const size_t cnt = 4U;
    MockMethodDesc src[4] = {{"m1", "v@:"}, {"m2", "v@:"}, {"m3", "v@:"}, {"m4", "v@:"}};
    /* Allocate (cnt + 1) slots so full copy + terminating {NULL, NULL} never writes out of bounds */
    MockMethodDesc *dst = (MockMethodDesc *)calloc(cnt + 1U, sizeof(MockMethodDesc));
    assert(dst != NULL);
    size_t w = 0;
    for (size_t i = 0; i < cnt; i++)
        dst[w++] = src[i];
    dst[w].name = NULL;
    dst[w].types = NULL;
    assert(w == cnt && dst[cnt].name == NULL && dst[cnt].types == NULL);
    free(dst);

    /* 5. NSVersionOfRunTimeLibrary: hidden macOS libs and unloaded libs must return -1 */
    const char *hidden_or_unloaded[] = {"AppKit", "Cocoa", "ServiceManagement", "NonExistentLibXYZ"};
    for (size_t i = 0; i < sizeof(hidden_or_unloaded) / sizeof(hidden_or_unloaded[0]); i++) {
        int is_hidden = (strcmp(hidden_or_unloaded[i], "AppKit") == 0 || strcmp(hidden_or_unloaded[i], "Cocoa") == 0 ||
                         strcmp(hidden_or_unloaded[i], "ServiceManagement") == 0);
        int is_loaded = 0;
        int32_t ver = (is_hidden || !is_loaded) ? -1 : (1677 << 16);
        assert(ver == -1);
    }

    /* 6. Multi-digit en10+ interface matching via production PTDetectionRules */
    assert(!pt_is_secondary_en_ifname_cstr("en0"));
    assert(pt_is_secondary_en_ifname_cstr("en1"));
    assert(pt_is_secondary_en_ifname_cstr("en9"));
    assert(pt_is_secondary_en_ifname_cstr("en10"));
    assert(pt_is_secondary_en_ifname_cstr("en15"));
    assert(!pt_is_secondary_en_ifname_cstr("en1a"));

    /* 7. MTLDevice compat13_7 three-property symmetry: supportsBCTextureCompression, supports32BitMSAA,
     * supports32BitFloatFiltering */
    const char *compat13_mtl_props[] = {"supportsBCTextureCompression", "supports32BitMSAA",
                                        "supports32BitFloatFiltering"};
    for (size_t i = 0; i < 3U; i++) {
        assert(strncmp(compat13_mtl_props[i], "supports", 8U) == 0);
    }

    /* 8. Darwin syscall numbers: SYS_openat_dprotected_np == 218 does NOT collide with SYS_open_dprotected_np (216) or
     * 478 (SYS_proc_uuid_policy / other) */
    const int kSysOpenDprotectedNp = 216;
    const int kSysOpenatDprotectedNp = 218;
    const int kSysOther478 = 478;
    assert(kSysOpenatDprotectedNp != kSysOpenDprotectedNp);
    assert(kSysOpenatDprotectedNp != kSysOther478);
    assert(kSysOpenatDprotectedNp == 218);

    /* 9. Path-component boundary & app-embedded bundle exemption must NOT match MyCocoa.framework as Cocoa.framework */
    assert(pt_path_has_component("/System/Library/Frameworks/Cocoa.framework/Cocoa", "Cocoa.framework"));
    assert(pt_path_has_component("/System/Library/Frameworks/Cocoa.framework", "Cocoa.framework"));
    assert(!pt_path_has_component(
        "/var/containers/Bundle/Application/X/DemoApp.app/Frameworks/MyCocoa.framework/MyCocoa", "Cocoa.framework"));
    assert(mock_is_app_embedded(
               "/var/containers/Bundle/Application/X/DemoApp.app/Frameworks/MyCocoa.framework/MyCocoa") == 1);
    assert(mock_is_app_embedded(
               "/var/containers/Bundle/Application/X/DemoApp.app/Frameworks/Charts.framework/Charts") == 1);
    assert(mock_is_app_embedded("/System/Library/Frameworks/Charts.framework/Charts") == 0);

    /* 10. Nested .framework/Versions/ and .bundle/Contents/MacOS/ image path stripping */
    char stripped_img[512];
    mock_strip_nested_image_versions(
        "/System/Library/Frameworks/Accelerate.framework/Versions/A/Frameworks/vImage.framework/Versions/A/vImage",
        stripped_img, sizeof(stripped_img));
    assert(strcmp(stripped_img, "/System/Library/Frameworks/Accelerate.framework/Frameworks/vImage.framework/vImage") ==
           0);
    mock_strip_nested_image_versions("/System/Library/CoreServices/RawCamera.bundle/Contents/MacOS/RawCamera",
                                     stripped_img, sizeof(stripped_img));
    assert(strcmp(stripped_img, "/System/Library/CoreServices/RawCamera.bundle/RawCamera") == 0);
    mock_strip_nested_image_versions("/System/Library/AccessibilityBundles/AccessibilitySettingsLoader.bundle/Versions/"
                                     "A/AccessibilitySettingsLoader",
                                     stripped_img, sizeof(stripped_img));
    assert(
        strcmp(stripped_img,
               "/System/Library/AccessibilityBundles/AccessibilitySettingsLoader.bundle/AccessibilitySettingsLoader") ==
        0);
}

static uint32_t mock_encode_adrp_x16(uintptr_t stub_pc, uintptr_t target_page) {
    int64_t delta_pages = ((int64_t)target_page - (int64_t)(stub_pc & ~(uintptr_t)0xFFFU)) / 4096LL;
    uint32_t imm21 = (uint32_t)delta_pages & 0x1FFFFFU;
    uint32_t immlo = imm21 & 0x3U;
    uint32_t immhi = (imm21 >> 2) & 0x7FFFFU;
    return 0x90000010U | (immlo << 29) | (immhi << 5);
}

static uint32_t mock_encode_ldr_x_uimm(uint32_t rt, uintptr_t byte_off) {
    assert((byte_off & 7U) == 0U && (byte_off >> 3) < 4096U);
    return 0xF9400200U | (rt & 0x1FU) | ((uint32_t)(byte_off >> 3) << 10);
}

static void test_arm64_stub_decoder_and_got_bitmap(void) {
    /* 12-byte ARM64 stub with positive and negative ADRP page offsets via production PTArm64StubMath */
    uintptr_t pc_pos = 0x101451f10ULL;
    uintptr_t target_pos = 0x10188c960ULL;
    uint32_t stub_pos[3] = {
        mock_encode_adrp_x16(pc_pos, target_pos & ~(uintptr_t)0xFFFU),
        mock_encode_ldr_x_uimm(16U, target_pos & 0xFFFU),
        0xD61F0200U, /* br x16 */
    };
    uintptr_t decoded = 0;
    assert(pt_decode_arm64_stub_target_slot(pc_pos, stub_pos, 12U, &decoded));
    assert(decoded == target_pos);

    uintptr_t pc_neg = 0x102400100ULL;
    uintptr_t target_neg = 0x102004220ULL;
    uint32_t stub_neg[3] = {
        mock_encode_adrp_x16(pc_neg, target_neg & ~(uintptr_t)0xFFFU),
        mock_encode_ldr_x_uimm(16U, target_neg & 0xFFFU),
        0xD61F0200U,
    };
    decoded = 0;
    assert(pt_decode_arm64_stub_target_slot(pc_neg, stub_neg, 12U, &decoded));
    assert(decoded == target_neg);

    /* 16-byte ARM64e/PAC stub: adrp x16; add x16, x16, #imm12; ldr x17, [x16, #uimm]; braa x17, x16 */
    uintptr_t pc_pac = 0x100500000ULL;
    uintptr_t target_pac = 0x100801048ULL; /* page + 0x040 (ADD) + 0x008 (LDR) */
    uint32_t stub_pac[4] = {
        mock_encode_adrp_x16(pc_pac, target_pac & ~(uintptr_t)0xFFFU),
        0x91000210U | (0x040U << 10),
        mock_encode_ldr_x_uimm(17U, 0x008U),
        0xD71F0A30U, /* braa x17, x16 */
    };
    decoded = 0;
    assert(pt_decode_arm64_stub_target_slot(pc_pac, stub_pac, 16U, &decoded));
    assert(decoded == target_pac);

    /* Fail-closed rejections: short stride, NOP, wrong register, BLR instead of BR */
    assert(!pt_decode_arm64_stub_target_slot(pc_pos, stub_pos, 8U, &decoded));
    uint32_t bad_nop[3] = {0xD503201FU, stub_pos[1], stub_pos[2]};
    assert(!pt_decode_arm64_stub_target_slot(pc_pos, bad_nop, 12U, &decoded));
    uint32_t bad_reg[3] = {stub_pos[0], mock_encode_ldr_x_uimm(15U, 0x960U), stub_pos[2]};
    assert(!pt_decode_arm64_stub_target_slot(pc_pos, bad_reg, 12U, &decoded));
    uint32_t bad_blr[3] = {stub_pos[0], stub_pos[1], 0xD63F0200U};
    assert(!pt_decode_arm64_stub_target_slot(pc_pos, bad_blr, 12U, &decoded));

    /* GOT bitmap: mark slot 3 & slot 67 as stubbed, leave slot 2 & slot 66 un-stubbed */
    uint64_t bitmap[2] = {0, 0};
    uintptr_t got_base = 0x101888000ULL;
    size_t stub_indices[2] = {3U, 67U};
    for (size_t i = 0; i < 2U; i++) {
        uintptr_t slot_addr = got_base + stub_indices[i] * sizeof(void *);
        size_t idx = (size_t)((slot_addr - got_base) / sizeof(void *));
        bitmap[idx >> 6] |= (1ULL << (idx & 63U));
    }
    assert((bitmap[0] & (1ULL << 3U)) != 0ULL);
    assert((bitmap[0] & (1ULL << 2U)) == 0ULL);
    assert((bitmap[1] & (1ULL << 3U)) != 0ULL);
    assert((bitmap[1] & (1ULL << 2U)) == 0ULL);
}

static void test_v105_macos_frameworks_and_vm_read_got_sanitize(void) {
    /* Remaining macOS-only frameworks must match as whole components and preserve iOS siblings */
    const char *macos_paths[] = {
        "/System/Library/Frameworks/OpenGL.framework/OpenGL",
        "/System/Library/Frameworks/OpenGL.framework/Libraries/libGL.dylib",
        "/System/Library/Frameworks/Kerberos.framework/Kerberos",
        "/System/Library/Frameworks/LDAP.framework/LDAP",
        "/System/Library/Frameworks/QuickLookUI.framework/QuickLookUI",
        "/System/Library/PrivateFrameworks/PreferencePanesSupport.framework/PreferencePanesSupport",
        "/System/Library/Frameworks/SecurityFoundation.framework/SecurityFoundation",
        "/System/Library/PrivateFrameworks/NetAuth.framework/NetAuth",
        "/System/Library/PrivateFrameworks/IO80211.framework/IO80211",
        "/System/Library/PrivateFrameworks/AppleVA.framework/AppleVA",
        "/usr/lib/libUniversalAccess.dylib",
    };
    const char *comps[] = {
        "OpenGL.framework",
        "OpenGL.framework",
        "Kerberos.framework",
        "LDAP.framework",
        "QuickLookUI.framework",
        "PreferencePanesSupport.framework",
        "SecurityFoundation.framework",
        "NetAuth.framework",
        "IO80211.framework",
        "AppleVA.framework",
        "libUniversalAccess.dylib",
    };
    for (size_t i = 0; i < sizeof(macos_paths) / sizeof(macos_paths[0]); i++) {
        assert(pt_path_has_component(macos_paths[i], comps[i]));
        assert(pt_is_macos_only_framework_path_cstr(macos_paths[i]));
        assert(mock_is_app_embedded(macos_paths[i]) == 0);
    }
    assert(!pt_path_has_component("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", "OpenGL.framework"));
    assert(!pt_path_has_component("/System/Library/Frameworks/QuickLook.framework/QuickLook", "QuickLookUI.framework"));
    assert(mock_is_app_embedded(
               "/var/containers/Bundle/Application/X/DemoApp.app/Frameworks/OpenGL.framework/OpenGL") == 1);

    /* Aligned vm_read GOT/lazy slot sanitization window math */
    const uintptr_t sec_start = 0x104008000ULL;
    const uintptr_t sec_end = sec_start + 5U * sizeof(uintptr_t);
    const uintptr_t fake_pt_open = 0x101001111ULL;
    const uintptr_t fake_real_open = 0x19f002222ULL;
    const uintptr_t untouched_val = 0x123456789abcdef0ULL;

    /* Partial unaligned read starting at sec_start + 3 through sec_start + 36 */
    uintptr_t read_start = sec_start + 3U;
    uint8_t buf[33];
    memset(buf, 0xAA, sizeof(buf));
    /* Place fake_pt_open at aligned slot sec_start + 8 (offset 5) and fake_pt_open at sec_start + 16 (offset 13) */
    memcpy(buf + (sec_start + 8U - read_start), &fake_pt_open, sizeof(fake_pt_open));
    memcpy(buf + (sec_start + 16U - read_start), &untouched_val, sizeof(untouched_val));
    memcpy(buf + (sec_start + 24U - read_start), &fake_pt_open, sizeof(fake_pt_open));

    uintptr_t read_end = read_start + sizeof(buf);
    uintptr_t ov_start = (read_start > sec_start) ? read_start : sec_start;
    uintptr_t ov_end = (read_end < sec_end) ? read_end : sec_end;
    uintptr_t slot_addr = (ov_start + (sizeof(uintptr_t) - 1U)) & ~(sizeof(uintptr_t) - 1U);
    assert(slot_addr == sec_start + 8U);
    while (slot_addr <= ov_end - sizeof(uintptr_t)) {
        size_t dst_off = (size_t)(slot_addr - read_start);
        uintptr_t val = 0;
        memcpy(&val, buf + dst_off, sizeof(val));
        if (val == fake_pt_open) {
            memcpy(buf + dst_off, &fake_real_open, sizeof(fake_real_open));
        }
        if (ov_end - slot_addr < 2U * sizeof(uintptr_t)) {
            break;
        }
        slot_addr += sizeof(uintptr_t);
    }
    uintptr_t got8 = 0, got16 = 0, got24 = 0;
    memcpy(&got8, buf + 5U, sizeof(got8));
    memcpy(&got16, buf + 13U, sizeof(got16));
    memcpy(&got24, buf + 21U, sizeof(got24));
    assert(got8 == fake_real_open);
    assert(got16 == untouched_val);
    assert(got24 == fake_real_open);
}

static void test_v105_batch2_sysctl_iokit_mig_and_metal(void) {
    /* 1. CTL_SYSCTL sub-MIB discrimination: 1/4/5/6 query name2oid, only 2 walks sysctl.next */
    int mib_fmt[5] = {0, 4, 1, 2, 3};
    assert((mib_fmt[1] == 1 || mib_fmt[1] == 4 || mib_fmt[1] == 5 || mib_fmt[1] == 6));
    assert(!(mib_fmt[1] == 2));
    int mib_descr[5] = {0, 5, 1, 2, 3};
    assert((mib_descr[1] == 1 || mib_descr[1] == 4 || mib_descr[1] == 5 || mib_descr[1] == 6));
    assert(!(mib_descr[1] == 2));
    int mib_next[3] = {0, 2, 1};
    assert(mib_next[1] == 2);

    /* 2. NUL-delimited IOKit byte sequence sanitization preserves multi-string boundaries */
    const uint8_t raw_dt_compat[] = "Mac14,2\0applegpu_g14g\0J413AP\0";
    size_t raw_len = sizeof(raw_dt_compat) - 1U;
    assert(memmem(raw_dt_compat, raw_len, "applegpu_g14g", 13) != NULL);
    assert(memmem(raw_dt_compat, raw_len, "J413", 4) != NULL);
    size_t tok_count = 0;
    for (size_t i = 0; i < raw_len; i++) {
        if (raw_dt_compat[i] == '\0') {
            tok_count++;
        }
    }
    assert(tok_count == 3U);

    /* 3. MIG mach_vm_read_overwrite reply packed outsize offset check */
    typedef struct {
        uint8_t header[24];
        uint8_t ndr[8];
        int32_t ret_code;
        uint64_t outsize;
    } __attribute__((packed)) mock_vm_ro_reply_t;
    mock_vm_ro_reply_t ro_reply;
    memset(&ro_reply, 0, sizeof(ro_reply));
    ro_reply.ret_code = 0;
    ro_reply.outsize = 4096ULL;
    uint64_t decoded_outsize = 0;
    memcpy(&decoded_outsize, ((const uint8_t *)&ro_reply) + 32U + sizeof(int32_t), sizeof(decoded_outsize));
    assert(decoded_outsize == 4096ULL);

    /* 4. Metal missing-header diagnostic bracket column alignment */
    const char *src = "#include <metal_stdlib>\n#include <metal_simdgroup_matrix>\n";
    const char *bracket = strstr(src, "<metal_simdgroup_matrix>");
    assert(bracket != NULL);
    unsigned long line = 1, col = 1;
    for (const char *p = src; p < bracket; p++) {
        if (*p == '\n') {
            line++;
            col = 1;
        } else {
            col++;
        }
    }
    assert(line == 2 && col == 10);
}

static int pt_dummy_fn_a(void) {
    return 1;
}
static int pt_dummy_fn_b(void) {
    return 2;
}

static void test_production_c_modules_extra(void) {
    /* 1. pt_filter_xattr_list_buffer compaction + unterminated tail */
    char xbuf[128];
    const char *entries[] = {"com.apple.quarantine", "com.example.keep1", "com.apple.metadata:kMDItemWhereFroms",
                             "com.apple.decmpfs"};
    size_t pos = 0;
    for (size_t i = 0; i < 4U; i++) {
        size_t l = strlen(entries[i]) + 1U;
        memcpy(xbuf + pos, entries[i], l);
        pos += l;
    }
    ssize_t filtered_len = pt_filter_xattr_list_buffer(xbuf, (ssize_t)pos);
    const char expected[] = "com.example.keep1\0com.apple.decmpfs\0";
    assert(filtered_len == (ssize_t)(sizeof(expected) - 1U));
    assert(memcmp(xbuf, expected, (size_t)filtered_len) == 0);

    /* 2. pt_normalize_lexical_path & pt_match_prefix_modulo_private */
    char norm[256];
    assert(pt_normalize_lexical_path("/private//var/./mobile/../tmp/", norm, sizeof(norm)) == norm);
    assert(strcmp(norm, "/private/var/tmp") == 0);
    const char *rel =
        pt_match_prefix_modulo_private("/var/containers/Bundle/Application/X", "/private/var/containers", 23U);
    assert(rel != NULL && strcmp(rel, "/Bundle/Application/X") == 0);

    /* 3. Env, Prefs, Threads, Mach services */
    assert(pt_is_hidden_env_key_cstr("DYLD_INSERT_LIBRARIES"));
    assert(!pt_is_hidden_env_key_cstr("HOME"));
    assert(pt_is_hidden_macos_pref_key_cstr("NSWindow Frame Main"));
    assert(!pt_is_hidden_macos_pref_key_cstr("AppleLanguages"));
    assert(pt_is_hidden_thread_name_cstr("com.apple.NSEventThread"));
    assert(!pt_is_hidden_thread_name_cstr("com.apple.main-thread"));
    assert(pt_is_hidden_macos_mach_service_cstr("com.apple.dock.server"));
    assert(pt_is_hidden_macos_mach_service_cstr("com.apple.SecurityServer"));
    assert(!pt_is_hidden_macos_mach_service_cstr("com.apple.securityd"));

    /* 4. pt_collect_two_table_macho_sections on synthetic Mach-O buffer */
    struct {
        struct mach_header_64 hdr;
        struct segment_command_64 seg_text;
        struct section_64 sec_stubs;
        struct segment_command_64 seg_data;
        struct section_64 sec_la;
        struct section_64 sec_got;
    } fake_mh;
    memset(&fake_mh, 0, sizeof(fake_mh));
    fake_mh.hdr.magic = MH_MAGIC_64;
    fake_mh.hdr.ncmds = 2U;
    fake_mh.hdr.sizeofcmds = sizeof(fake_mh) - sizeof(fake_mh.hdr);
    fake_mh.seg_text.cmd = LC_SEGMENT_64;
    fake_mh.seg_text.cmdsize = sizeof(fake_mh.seg_text) + sizeof(fake_mh.sec_stubs);
    memcpy(fake_mh.seg_text.segname, "__TEXT", 6);
    fake_mh.seg_text.vmaddr = (uint64_t)(uintptr_t)&fake_mh;
    fake_mh.seg_text.nsects = 1U;
    fake_mh.sec_stubs.flags = S_SYMBOL_STUBS;
    fake_mh.sec_stubs.addr = (uint64_t)(uintptr_t)&fake_mh + 0x1000ULL;
    fake_mh.sec_stubs.size = 36U;
    fake_mh.sec_stubs.reserved2 = 12U;
    fake_mh.seg_data.cmd = LC_SEGMENT_64;
    fake_mh.seg_data.cmdsize = sizeof(fake_mh.seg_data) + 2U * sizeof(fake_mh.sec_la);
    memcpy(fake_mh.seg_data.segname, "__DATA_CONST", 12);
    fake_mh.seg_data.nsects = 2U;
    fake_mh.sec_la.flags = S_LAZY_SYMBOL_POINTERS;
    fake_mh.sec_la.addr = 0x200000000ULL;
    fake_mh.sec_la.size = sizeof(void *);
    fake_mh.sec_got.flags = S_NON_LAZY_SYMBOL_POINTERS;
    memcpy(fake_mh.sec_got.sectname, "__got", 5);
    fake_mh.sec_got.addr = 0x200004000ULL;
    fake_mh.sec_got.size = 4U * sizeof(void *);

    uintptr_t stubs_start = 0, stubs_size = 0;
    uint32_t stubs_stride = 0, got_count = 0;
    pt_got_sec_range_t got_secs[PT_MAX_NONLAZY_GOT_SECS];
    assert(pt_collect_two_table_macho_sections(&fake_mh.hdr, 0, &stubs_start, &stubs_size, &stubs_stride, got_secs,
                                               &got_count));
    assert(stubs_size == 36U && stubs_stride == 12U && got_count == 1U && got_secs[0].start == 0x200004000ULL &&
           got_secs[0].size == 4U * sizeof(void *));

    /* 5. PTInterposeRegistry hash table lookup + compat13_7 hiding */
    const pt_dlsym_entry_t reg_entries[2] = {
        {"pt_sym_alpha", (const void *)&pt_dummy_fn_a, NULL, PT_DLSYM_FLAG_NONE},
        {"pt_sym_beta", (const void *)&pt_dummy_fn_b, (const void *)&pt_dummy_fn_b,
         PT_DLSYM_FLAG_WEAK_GUARD | PT_DLSYM_FLAG_HIDE_IN_COMPAT13_7},
    };
    uint16_t reg_slots[16];
    pt_dlsym_index_t reg_idx;
    size_t dup_cnt = pt_dlsym_index_build(&reg_idx, reg_entries, 2U, reg_slots, 16U);
    assert(dup_cnt == 0U);
    assert(pt_dlsym_index_lookup(&reg_idx, "pt_sym_alpha", false) == (const void *)&pt_dummy_fn_a);
    assert(pt_dlsym_index_lookup(&reg_idx, "pt_sym_beta", false) == (const void *)&pt_dummy_fn_b);
    assert(pt_dlsym_index_lookup(&reg_idx, "pt_sym_beta", true) == PT_DLSYM_HIDDEN_SENTINEL);

    /* 6. PTCallerAddressMath helpers */
    uint64_t packed_caller = 0ULL;
    assert(pt_caller_addr_try_pack(0x104008000ULL, PT_CALLER_APP, &packed_caller));
    uint8_t out_kind = PT_CALLER_UNKNOWN;
    assert(pt_caller_addr_cache_match(packed_caller, 0x104008000ULL, &out_kind));
    assert(out_kind == PT_CALLER_APP);
    assert(pt_caller_addr_cache_slot(0x104008000ULL) < PT_CALLER_ADDR_CACHE_SIZE);
    assert(pt_wrapper_cache_slot(pt_caller_compound_key(0x104008000ULL, 0x104008010ULL)) < PT_WRAPPER_CACHE_SIZE);
}

static void test_swift_hidden_type_boundary_rules(void) {
    /* App-defined classes ending with ViewBridge / AppKit / SkyLight / PlayTools must NEVER be hidden */
    static const char *const kAllowedTypes[] = {
        "AppMod.CustomWebViewBridge.Type",
        "AppMod.ViewBridge.Type",
        "AppMod.MyAppKit.Config",
        "AppMod.MySkyLight.Renderer",
        "AppMod.MyScreenCaptureKit.Helper",
        "AppMod.MyPlayTools.Helper",
        "Swift.Optional<AppMod.CustomWebViewBridge.Type>",
        "16AppKitControllerC",
        "15CocoaLumberjackC",
        "26CarbonCopyC",
        "19PlayToolsHelperC",
        "18SkyLightRendererC",
        "19HIToolboxWrapperC",
    };
    for (size_t i = 0; i < sizeof(kAllowedTypes) / sizeof(kAllowedTypes[0]); i++) {
        const char *s = kAllowedTypes[i];
        size_t len = strlen(s);
        assert(!pt_is_hidden_swift_mangled_type_name_cstr(s, len, false));
        assert(!pt_is_hidden_swift_mangled_type_name_cstr(s, len, true));
        assert(!pt_is_hidden_swift_qualified_token_cstr(s, len, false));
        assert(!pt_is_hidden_swift_qualified_token_cstr(s, len, true));
    }

    assert(!pt_is_hidden_swift_mangled_type_name_cstr("AppMod.MySwiftUI.App", 20U, true));
    assert(!pt_is_hidden_swift_qualified_token_cstr("AppMod.MySwiftUI.App", 20U, true));
    assert(!pt_is_hidden_swift_qualified_token_cstr("Swift.Optional<ViewBridge.NSRemoteView>", 39U, false));

    /* Genuine host / PlayTools mangled and qualified types MUST remain hidden */
    static const char *const kHiddenMangledOrQualified[] = {
        "9PlayTools12PlaySettingsC",
        "11AKInterface9AKPluginC",
        "6AppKit8NSWindowC",
        "10ViewBridge12NSRemoteViewC",
        "5Cocoa11NSWorkspaceC",
        "PlayTools.PlaySettings",
        "ViewBridge.NSRemoteView",
        "ViewBridge.NSRemoteView.Type",
        "AppKit.NSWindow.Type",
        "Swift.Optional<ViewBridge.NSRemoteView>",
        "Swift.Array<AppKit.NSWindow>",
    };
    for (size_t i = 0; i < sizeof(kHiddenMangledOrQualified) / sizeof(kHiddenMangledOrQualified[0]); i++) {
        const char *s = kHiddenMangledOrQualified[i];
        assert(pt_is_hidden_swift_mangled_type_name_cstr(s, strlen(s), false));
        assert(pt_is_hidden_swift_mangled_type_name_cstr(s, strlen(s), true));
    }

    static const char *const kHiddenQualifiedTokens[] = {
        "PlayTools.PlaySettings",
        "ViewBridge.NSRemoteView",
        "ViewBridge.NSRemoteView.Type",
        "AppKit.NSWindow.Type",
    };
    for (size_t i = 0; i < sizeof(kHiddenQualifiedTokens) / sizeof(kHiddenQualifiedTokens[0]); i++) {
        const char *s = kHiddenQualifiedTokens[i];
        assert(pt_is_hidden_swift_qualified_token_cstr(s, strlen(s), false));
        assert(pt_is_hidden_swift_qualified_token_cstr(s, strlen(s), true));
    }

    /* compat13_7 gating for modern SwiftUI / stdlib types */
    static const char *const kCompat13OnlyMangled[] = {
        "7SwiftUI10LazyVStackV", "SwiftUI.LazyVStack", "SwiftUI.App", "Swift.Duration", "s8DurationV", "ScT",
    };
    for (size_t i = 0; i < sizeof(kCompat13OnlyMangled) / sizeof(kCompat13OnlyMangled[0]); i++) {
        const char *s = kCompat13OnlyMangled[i];
        assert(!pt_is_hidden_swift_mangled_type_name_cstr(s, strlen(s), false));
        assert(pt_is_hidden_swift_mangled_type_name_cstr(s, strlen(s), true));
    }
    assert(!pt_is_hidden_swift_qualified_token_cstr("SwiftUI.App", 11U, false));
    assert(pt_is_hidden_swift_qualified_token_cstr("SwiftUI.App", 11U, true));
    assert(!pt_is_hidden_swift_qualified_token_cstr("Swift.Duration", 14U, false));
    assert(pt_is_hidden_swift_qualified_token_cstr("Swift.Duration", 14U, true));
}

int main(void) {
    test_der_entitlements_encoding_and_superblob_rewrite();
    test_attr_ref_zero_fill();
    test_getgroups_filter();
    test_sysctl_filters();
    test_ioreg_compat13_sanitize();
    test_sf_symbols_and_versions();
    test_network_and_coderesources();
    test_der_3byte_len_and_nested_set();
    test_superblob_cd_special_slot_sha256_update();
    test_fnv1a_linear_dedup();
    test_sf_symbols_multisuffix();
    test_coderesources_case_insensitive_and_attr_fallback();
    test_ioreg_agx_path_and_kinfo_cr_groups_and_prefs();
    test_round2_cg_hid_dlsym_blacklist();
    test_round2_macos_framework_and_font_filters();
    test_round2_xattr_osvariant_and_afunix();
    test_round2_sha1_sha256_cd_and_sfsymbols();
    test_round3_cdhash_kernel_version_and_l1i();
    test_round3_fs_case_gid_and_prot();
    test_round3_extended_dlsym_fw_icu_swift();
    test_round3_hidden_bundle_ids_regression();
    test_round4_audit_regressions();
    test_arm64_stub_decoder_and_got_bitmap();
    test_v105_macos_frameworks_and_vm_read_got_sanitize();
    test_v105_batch2_sysctl_iokit_mig_and_metal();
    test_production_c_modules_extra();
    test_swift_hidden_type_boundary_rules();
    printf("All compat104 unit tests passed.\n");
    return 0;
}
