#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
static uint32_t to_be32(uint32_t v) {
    return ((v & 0x000000ffU) << 24) |
           ((v & 0x0000ff00U) << 8) |
           ((v & 0x00ff0000U) >> 8) |
           ((v & 0xff000000U) >> 24);
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

typedef struct {
    uint8_t *data;
    size_t len;
    size_t cap;
    int failed;
} der_buf_t;

static void der_append(der_buf_t *b, const void *src, size_t n) {
    if (b == NULL || b->failed || n == 0 || src == NULL) {
        return;
    }
    if (b->len + n > b->cap) {
        size_t nc = (b->cap == 0) ? 128U : b->cap * 2U;
        while (nc < b->len + n) {
            nc *= 2U;
        }
        uint8_t *p = (uint8_t *)realloc(b->data, nc);
        if (p == NULL) {
            b->failed = 1;
            return;
        }
        b->data = p;
        b->cap = nc;
    }
    memcpy(b->data + b->len, src, n);
    b->len += n;
}

static void der_tag_len(der_buf_t *b, uint8_t tag, size_t len) {
    der_append(b, &tag, 1U);
    if (len < 0x80U) {
        uint8_t l = (uint8_t)len;
        der_append(b, &l, 1U);
    } else if (len <= 0xffU) {
        uint8_t h[2] = { 0x81U, (uint8_t)len };
        der_append(b, h, 2U);
    } else {
        uint8_t h[3] = { 0x82U, (uint8_t)(len >> 8), (uint8_t)(len & 0xffU) };
        der_append(b, h, 3U);
    }
}

static void der_tlv(der_buf_t *b, uint8_t tag, const void *body, size_t len) {
    der_tag_len(b, tag, len);
    der_append(b, body, len);
}

static void test_der_entitlements_encoding_and_superblob_rewrite(void) {
    /* Encode sample entitlements dict: { "com.apple.developer.team-identifier": "ABCD123456", "get-task-allow": false } */
    der_buf_t pair1_body = {0};
    const char *k1 = "com.apple.developer.team-identifier";
    const char *v1 = "ABCD123456";
    der_tlv(&pair1_body, 0x0cU, k1, strlen(k1));
    der_tlv(&pair1_body, 0x0cU, v1, strlen(v1));
    der_buf_t pair1 = {0};
    der_tlv(&pair1, 0x30U, pair1_body.data, pair1_body.len);

    der_buf_t set_body = {0};
    der_append(&set_body, pair1.data, pair1.len);

    der_buf_t app_body = {0};
    uint8_t ver[3] = { 0x02U, 0x01U, 0x01U };
    der_append(&app_body, ver, sizeof(ver));
    der_tlv(&app_body, 0x31U, set_body.data, set_body.len);

    der_buf_t root = {0};
    der_tlv(&root, 0x70U, app_body.data, app_body.len);

    assert(!root.failed);
    assert(root.data[0] == 0x70U);
    /* Ensure zero forbidden markers in DER output */
    for (size_t i = 0; i + 9 <= root.len; i++) {
        assert(memcmp(root.data + i, "PlayTools", 9) != 0);
    }

    /* Verify SuperBlob header magic rewriting constants */
    uint32_t magic_xml = to_be32(0xfade7171U);
    uint32_t magic_der = to_be32(0xfade7172U);
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

static int is_desktop_gid(uint32_t g) {
    switch (g) {
        case 12:
        case 29:
        case 33:
        case 61:
        case 79:
        case 80:
        case 81:
        case 98:
        case 100:
        case 101:
        case 204:
        case 250:
        case 395:
        case 398:
        case 399:
        case 400:
        case 701:
            return 1;
        default:
            return (g >= 390U && g <= 410U) ? 1 : 0;
    }
}

static void test_getgroups_filter(void) {
    const uint32_t mac_gids[] = { 20, 12, 29, 33, 61, 79, 80, 81, 98, 100, 101, 204, 250, 395, 398, 399, 400, 701 };
    uint32_t out[32];
    int out_n = 0;
    for (size_t i = 0; i < sizeof(mac_gids) / sizeof(mac_gids[0]); i++) {
        uint32_t g = mac_gids[i];
        if (is_desktop_gid(g)) {
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
    if (strcmp(name, "sysctl.proc_translated") == 0 ||
        strcmp(name, "sysctl.proc_native") == 0 ||
        strcmp(name, "kern.iossupportversion") == 0 ||
        strncmp(name, "kern.hibernate", 14) == 0 ||
        strcmp(name, "hw.use_kernelmanagerd") == 0 ||
        strcmp(name, "vm.swapusage") == 0) {
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
    if (nlen == 0 || strcmp(needle, repl) == 0) return;
    size_t pos = 0;
    while (1) {
        char *hit = strstr(buf + pos, needle);
        if (!hit) break;
        size_t off = (size_t)(hit - buf);
        size_t cur = strlen(buf);
        if (cur - nlen + rlen >= cap) break;
        if (rlen != nlen) memmove(hit + rlen, hit + nlen, cur - off - nlen + 1U);
        memcpy(hit, repl, rlen);
        pos = off + rlen;
    }
}

static void sanitize_io_compat13(char *buf, size_t cap) {
    static const char *const kSocs[] = { "T8103", "T8101", "T810x", "T6000" };
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

int main(void) {
    test_der_entitlements_encoding_and_superblob_rewrite();
    test_attr_ref_zero_fill();
    test_getgroups_filter();
    test_sysctl_filters();
    test_ioreg_compat13_sanitize();
    printf("All compat104 unit tests passed.\n");
    return 0;
}
