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
    } else if (len <= 0xffffU) {
        uint8_t h[3] = { 0x82U, (uint8_t)(len >> 8), (uint8_t)(len & 0xffU) };
        der_append(b, h, 3U);
    } else if (len <= 0xffffffU) {
        uint8_t h[4] = {
            0x83U,
            (uint8_t)((len >> 16) & 0xffU),
            (uint8_t)((len >> 8) & 0xffU),
            (uint8_t)(len & 0xffU)
        };
        der_append(b, h, 4U);
    } else {
        uint8_t h[5] = {
            0x84U,
            (uint8_t)((len >> 24) & 0xffU),
            (uint8_t)((len >> 16) & 0xffU),
            (uint8_t)((len >> 8) & 0xffU),
            (uint8_t)(len & 0xffU)
        };
        der_append(b, h, 5U);
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

/* ---------- Batch 3 Unit Tests ---------- */

static int sf_cmp(const void *k, const void *e) {
    return strcmp((const char *)k, *(const char * const *)e);
}

static int is_post13_sf_symbol(const char *s) {
    static const char *const kPost13Prefixes[] = {
        "aqi.", "arrow.triangle.", "camera.metering.", "contextualmenu.",
        "die.face.", "dock.", "figure.", "filemenu.", "menubar.",
        "point.3.", "rectangle.inset.", "rectangle.split.",
        "signpost.", "wave.3.", "widget.",
    };
    static const char *const kPost13Symbols[] = {
        "airpodsmax", "airpodspro", "allergens", "ant", "applescript", "applewatch",
        "banknote", "barometer", "bicycle", "binoculars", "books.vertical", "brain.head.profile",
        "building.columns", "bus", "case", "character", "checklist", "comb", "cpu",
        "cross.case", "crown", "cup.and.saucer", "cursorarrow", "diamond", "esim",
        "externaldrive", "ferry", "figure.walk", "fingerprint", "fork.knife", "fuelpump",
        "gearshape", "giftcard", "graduationcap", "guitars", "gyroscope", "hifispeaker",
        "homepod", "horn", "humidity", "hurricane", "internaldrive", "ladybug",
        "lanyardcard", "laptopcomputer", "leaf", "level", "list.bullet.rectangle", "lungs",
        "macmini", "macpro", "macstudio", "megaphone", "memorychip", "menucard",
        "metronome", "newspaper", "note.text", "octagon", "opticaldisc", "opticid",
        "paintpalette", "parkingsign", "pawprint", "pc", "pianokeys", "pills",
        "puzzlepiece", "radio", "recordingtape", "ruler", "scroll", "seal",
        "server.rack", "shareplay", "shippingbox", "sidebar.leading", "sidebar.trailing", "simcard",
        "sparkles.tv", "swift", "tablecells", "takeoutbag", "terminal", "theatermasks",
        "tornado", "touchid", "tram", "tropicalstorm", "tuningfork", "visionpro",
        "wallet.pass", "wrench.and.screwdriver", "xserve"
    };
    size_t n = sizeof(kPost13Symbols) / sizeof(kPost13Symbols[0]);
    for (size_t i = 1; i < n; i++) {
        assert(strcmp(kPost13Symbols[i - 1], kPost13Symbols[i]) < 0);
    }
    for (size_t i = 0; i < sizeof(kPost13Prefixes) / sizeof(kPost13Prefixes[0]); i++) {
        if (strncmp(s, kPost13Prefixes[i], strlen(kPost13Prefixes[i])) == 0) return 1;
    }
    char base[128];
    snprintf(base, sizeof(base), "%s", s);
    if (bsearch(base, kPost13Symbols, n, sizeof(kPost13Symbols[0]), sf_cmp) != NULL) return 1;
    static const char *const kSuffixes[] = { ".fill", ".circle", ".square", ".slash" };
    for (size_t i = 0; i < sizeof(kSuffixes) / sizeof(kSuffixes[0]); i++) {
        size_t sl = strlen(kSuffixes[i]), bl = strlen(base);
        if (bl > sl && strcmp(base + bl - sl, kSuffixes[i]) == 0) {
            base[bl - sl] = '\0';
            if (bsearch(base, kPost13Symbols, n, sizeof(kPost13Symbols[0]), sf_cmp) != NULL) return 1;
            break;
        }
    }
    return 0;
}

static void test_sf_symbols_and_versions(void) {
    assert(is_post13_sf_symbol("brain.head.profile") == 1);
    assert(is_post13_sf_symbol("sparkles.tv.fill") == 1);
    assert(is_post13_sf_symbol("wrench.and.screwdriver.fill") == 1);
    assert(is_post13_sf_symbol("gearshape.fill") == 1);
    /* iOS 13.0 (SF Symbols 1.x) must remain allowed */
    assert(is_post13_sf_symbol("gear") == 0);
    assert(is_post13_sf_symbol("sparkles") == 0);
    assert(is_post13_sf_symbol("house.fill") == 0);

    int32_t fnd13 = (1677 << 16) | (104 << 8);
    int32_t uik13 = (3698 << 16) | (54 << 8);
    assert((fnd13 >> 16) == 1677);
    assert((uik13 >> 16) == 3698);
}

/* ---------- Batch 4 Unit Tests ---------- */

static int is_hidden_ifname_prefix(const char *name) {
    if (!name || !name[0]) return 0;
    return (strncmp(name, "vmenet", 6) == 0 ||
            strncmp(name, "vmnet", 5) == 0 ||
            strncmp(name, "bridge", 6) == 0 ||
            strncmp(name, "anpi", 4) == 0) ? 1 : 0;
}

static int is_code_res_key_dirty(const char *k) {
    if (!k) return 0;
    return (strstr(k, "PlayTools") != NULL ||
            strstr(k, "AKInterface") != NULL ||
            strstr(k, "SVCPatches") != NULL ||
            strstr(k, "Playtools.strings") != NULL ||
            strstr(k, "UserPlugins") != NULL) ? 1 : 0;
}

static void test_network_and_coderesources(void) {
    assert(is_hidden_ifname_prefix("anpi0") == 1);
    assert(is_hidden_ifname_prefix("anpi2") == 1);
    assert(is_hidden_ifname_prefix("bridge100") == 1);
    assert(is_hidden_ifname_prefix("en0") == 0);
    assert(is_hidden_ifname_prefix("lo0") == 0);

    assert(is_code_res_key_dirty("Frameworks/AKInterface.framework/AKInterface") == 1);
    assert(is_code_res_key_dirty("Frameworks/PlayTools.framework/PlayTools") == 1);
    assert(is_code_res_key_dirty("Info.plist") == 0);
}

/* ---------- Round 1 Hardening Unit Tests ---------- */

static uint32_t rotr32(uint32_t x, unsigned n) {
    return (x >> n) | (x << (32U - n));
}

static void sha256_compute(const uint8_t *msg, size_t len, uint8_t out[32]) {
    static const uint32_t k[64] = {
        0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU, 0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U,
        0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U, 0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U,
        0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU, 0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
        0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U, 0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U,
        0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U, 0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
        0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U, 0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
        0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
        0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U, 0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U
    };
    uint32_t h[8] = {
        0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
        0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U
    };
    size_t padded = ((len + 9U + 63U) / 64U) * 64U;
    uint8_t *buf = (uint8_t *)calloc(1U, padded);
    assert(buf != NULL);
    if (len > 0) memcpy(buf, msg, len);
    buf[len] = 0x80U;
    uint64_t bitlen = (uint64_t)len * 8ULL;
    for (int i = 0; i < 8; i++) {
        buf[padded - 1U - (size_t)i] = (uint8_t)((bitlen >> (i * 8)) & 0xffULL);
    }
    for (size_t off = 0; off < padded; off += 64U) {
        uint32_t w[64];
        for (int i = 0; i < 16; i++) {
            w[i] = ((uint32_t)buf[off + (size_t)i * 4U] << 24) |
                   ((uint32_t)buf[off + (size_t)i * 4U + 1U] << 16) |
                   ((uint32_t)buf[off + (size_t)i * 4U + 2U] << 8) |
                   (uint32_t)buf[off + (size_t)i * 4U + 3U];
        }
        for (int i = 16; i < 64; i++) {
            uint32_t s0 = rotr32(w[i - 15], 7U) ^ rotr32(w[i - 15], 18U) ^ (w[i - 15] >> 3);
            uint32_t s1 = rotr32(w[i - 2], 17U) ^ rotr32(w[i - 2], 19U) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
        for (int i = 0; i < 64; i++) {
            uint32_t S1 = rotr32(e, 6U) ^ rotr32(e, 11U) ^ rotr32(e, 25U);
            uint32_t ch = (e & f) ^ ((~e) & g);
            uint32_t t1 = hh + S1 + ch + k[i] + w[i];
            uint32_t S0 = rotr32(a, 2U) ^ rotr32(a, 13U) ^ rotr32(a, 22U);
            uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
            uint32_t t2 = S0 + maj;
            hh = g; g = f; f = e; e = d + t1;
            d = c; c = b; b = a; a = t1 + t2;
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d;
        h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
    }
    free(buf);
    for (int i = 0; i < 8; i++) {
        out[i * 4] = (uint8_t)(h[i] >> 24);
        out[i * 4 + 1] = (uint8_t)(h[i] >> 16);
        out[i * 4 + 2] = (uint8_t)(h[i] >> 8);
        out[i * 4 + 3] = (uint8_t)h[i];
    }
}

static void test_der_3byte_len_and_nested_set(void) {
    der_buf_t b = {0};
    der_tag_len(&b, 0x31U, 0x12345U);
    assert(!b.failed);
    assert(b.len == 5U);
    assert(b.data[0] == 0x31U && b.data[1] == 0x83U && b.data[2] == 0x01U && b.data[3] == 0x23U && b.data[4] == 0x45U);
    free(b.data);

    /* Nested dictionary must use SET tag 0x31 (Apple CE DER spec) */
    der_buf_t inner_kv = {0};
    der_tlv(&inner_kv, 0x0cU, "subkey", 6U);
    uint8_t der_true = 0xffU;
    der_tlv(&inner_kv, 0x01U, &der_true, 1U);
    der_buf_t inner_seq = {0};
    der_tlv(&inner_seq, 0x30U, inner_kv.data, inner_kv.len);
    der_buf_t nested_set = {0};
    der_tlv(&nested_set, 0x31U, inner_seq.data, inner_seq.len);
    assert(nested_set.data[0] == 0x31U);
    free(inner_kv.data);
    free(inner_seq.data);
    free(nested_set.data);
}

static void test_superblob_cd_special_slot_sha256_update(void) {
    /* Sanity-check SHA-256 against NIST "abc" vector */
    uint8_t abc_hash[32];
    sha256_compute((const uint8_t *)"abc", 3U, abc_hash);
    assert(abc_hash[0] == 0xbaU && abc_hash[1] == 0x78U && abc_hash[2] == 0x16U && abc_hash[3] == 0xbfU);

    /* Build synthetic CodeDirectory with nSpecialSlots=7, hashOffset=44+7*32=268, hashType=2, hashSize=32 */
    uint8_t cd[300];
    memset(cd, 0, sizeof(cd));
    uint32_t magic = to_be32(0xfade0c02U);
    uint32_t cd_len = to_be32((uint32_t)sizeof(cd));
    uint32_t hash_off = to_be32(268U);
    uint32_t n_special = to_be32(7U);
    memcpy(cd + 0, &magic, 4);
    memcpy(cd + 4, &cd_len, 4);
    memcpy(cd + 16, &hash_off, 4);
    memcpy(cd + 24, &n_special, 4);
    cd[36] = 32U; /* hashSize */
    cd[37] = 2U;  /* CS_HASHTYPE_SHA256 */
    /* Seed non-zero stale hashes at special slots -5 and -7 */
    memset(cd + 268U - 5U * 32U, 0x11, 32U);
    memset(cd + 268U - 7U * 32U, 0x22, 32U);

    /* Sanitized slot 5 (XML) and slot 7 (DER) blobs including 8-byte header */
    const char *xml_body = "<plist><dict/></plist>";
    size_t xml_blob_len = 8U + strlen(xml_body);
    uint8_t slot5[64];
    uint32_t m5 = to_be32(0xfade7171U), l5 = to_be32((uint32_t)xml_blob_len);
    memcpy(slot5, &m5, 4);
    memcpy(slot5 + 4, &l5, 4);
    memcpy(slot5 + 8, xml_body, strlen(xml_body));

    uint8_t der_body[6] = { 0x70U, 0x04U, 0x02U, 0x01U, 0x01U, 0x31U };
    size_t der_blob_len = 8U + sizeof(der_body);
    uint8_t slot7[32];
    uint32_t m7 = to_be32(0xfade7172U), l7 = to_be32((uint32_t)der_blob_len);
    memcpy(slot7, &m7, 4);
    memcpy(slot7 + 4, &l7, 4);
    memcpy(slot7 + 8, der_body, sizeof(der_body));

    /* Update CD special slots -5 and -7 */
    uint8_t h5[32], h7[32];
    sha256_compute(slot5, xml_blob_len, h5);
    sha256_compute(slot7, der_blob_len, h7);
    memcpy(cd + 268U - 5U * 32U, h5, 32U);
    memcpy(cd + 268U - 7U * 32U, h7, 32U);

    /* Verify detector check passes */
    uint8_t verify5[32], verify7[32];
    sha256_compute(slot5, xml_blob_len, verify5);
    sha256_compute(slot7, der_blob_len, verify7);
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
    const char **slices[2] = { slice1, slice2 };
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

static int is_post13_sf_symbol_multisuffix(const char *s) {
    static const char *const kTable[] = {
        "applelogo", "brain.head.profile", "gearshape", "gearshape.2",
        "ipad", "iphone", "leaf", "macbook", "sparkles.tv", "wrench.and.screwdriver"
    };
    size_t n = sizeof(kTable) / sizeof(kTable[0]);
    for (size_t i = 1; i < n; i++) {
        assert(strcmp(kTable[i - 1], kTable[i]) < 0);
    }
    char base[128];
    snprintf(base, sizeof(base), "%s", s);
    if (bsearch(base, kTable, n, sizeof(kTable[0]), sf_cmp) != NULL) return 1;
    static const char *const kSuffixes[] = { ".fill", ".circle", ".square", ".slash" };
    int changed = 1;
    while (changed) {
        changed = 0;
        for (size_t i = 0; i < sizeof(kSuffixes) / sizeof(kSuffixes[0]); i++) {
            size_t sl = strlen(kSuffixes[i]), bl = strlen(base);
            if (bl > sl && strcmp(base + bl - sl, kSuffixes[i]) == 0) {
                base[bl - sl] = '\0';
                if (bsearch(base, kTable, n, sizeof(kTable[0]), sf_cmp) != NULL) return 1;
                changed = 1;
                break;
            }
        }
    }
    return 0;
}

static void test_sf_symbols_multisuffix(void) {
    assert(is_post13_sf_symbol_multisuffix("leaf.circle.fill") == 1);
    assert(is_post13_sf_symbol_multisuffix("gearshape.2.fill") == 1);
    assert(is_post13_sf_symbol_multisuffix("applelogo") == 1);
    assert(is_post13_sf_symbol_multisuffix("house.circle.fill") == 0);
}

static int ci_contains(const char *hay, const char *needle) {
    size_t nlen = strlen(needle);
    if (nlen == 0) return 1;
    for (const char *p = hay; *p; p++) {
        size_t i = 0;
        while (i < nlen && p[i]) {
            char a = p[i], b = needle[i];
            if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
            if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
            if (a != b) break;
            i++;
        }
        if (i == nlen) return 1;
    }
    return 0;
}

static void test_coderesources_case_insensitive_and_attr_fallback(void) {
    const char *dirty[] = {
        "Frameworks/playtools.framework/PlayTools",
        "Playtools.strings",
        "Frameworks/akinterface.framework/AKInterface",
        "SVCPatches/patch.bin",
        "UserPlugins/foo.dylib"
    };
    for (size_t i = 0; i < sizeof(dirty) / sizeof(dirty[0]); i++) {
        int hit = ci_contains(dirty[i], "playtools") ||
                  ci_contains(dirty[i], "akinterface") ||
                  ci_contains(dirty[i], "svcpatches") ||
                  ci_contains(dirty[i], "userplugins");
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
    while (p[tail_off] && p[tail_off] != '/' && p[tail_off] != ':') tail_off++;
    char repl[64] = "AGXAcceleratorG12P";
    size_t rlen = strlen(repl);
    memmove(p + rlen, p + tail_off, strlen(p + tail_off) + 1U);
    memcpy(p, repl, rlen);
    assert(strcmp(path, "IOService:/AppleARMPE/sgx/AGXAcceleratorG12P") == 0);

    /* Substring ATCDPXBAR matches M1/M2/M3/M4 */
    assert(strstr("AppleT8112ATCDPXBAR", "ATCDPXBAR") != NULL);
    assert(strstr("AppleT6000ATCDPXBAR", "ATCDPXBAR") != NULL);

    /* kinfo_proc cr_groups scrub */
    uint32_t cr_groups[16] = { 20, 12, 61, 80, 81, 204, 250, 395, 398, 399, 400, 701 };
    int cr_ngroups = 12;
    int w = 0;
    for (int i = 0; i < cr_ngroups; i++) {
        uint32_t g = cr_groups[i];
        if (is_desktop_gid(g)) continue;
        if (g == 20U) g = 501U;
        cr_groups[w++] = g;
    }
    cr_ngroups = w;
    assert(cr_ngroups == 1 && cr_groups[0] == 501U);

    /* NSGlobalDomain desktop preference keys */
    const char *hidden_prefs[] = {
        "com.apple.trackpad.scaling",
        "com.apple.mouse.scaling",
        "com.apple.swipescrolldirection",
        "AppleMiniaturizeOnDoubleClick",
        "NSNavRecentPlaces"
    };
    for (size_t i = 0; i < sizeof(hidden_prefs) / sizeof(hidden_prefs[0]); i++) {
        const char *k = hidden_prefs[i];
        int is_hidden = (strncmp(k, "com.apple.trackpad.", 19) == 0 ||
                         strncmp(k, "com.apple.mouse.", 16) == 0 ||
                         strcmp(k, "com.apple.swipescrolldirection") == 0 ||
                         strcmp(k, "AppleMiniaturizeOnDoubleClick") == 0 ||
                         strcmp(k, "NSNavRecentPlaces") == 0);
        assert(is_hidden == 1);
    }
}

static int is_blocked_cg_or_hid_symbol(const char *sym) {
    static const char *const kBlocked[] = {
        "CGMainDisplayID",
        "CGGetActiveDisplayList",
        "CGGetOnlineDisplayList",
        "CGWindowListCopyWindowInfo",
        "CGPreflightScreenCaptureAccess",
        "CGRequestScreenCaptureAccess",
        "CGSessionCopyCurrentDictionary",
        "CGDisplayBounds",
        "CGDisplayPixelsWide",
        "CGDisplayPixelsHigh",
        "IOHIDManagerCreate",
        "IOHIDManagerCopyDevices",
        "IOHIDManagerOpen",
        "IOHIDManagerSetDeviceMatching"
    };
    if (sym == NULL) return 0;
    for (size_t i = 0; i < sizeof(kBlocked) / sizeof(kBlocked[0]); i++) {
        if (strcmp(sym, kBlocked[i]) == 0) return 1;
    }
    return 0;
}

static void test_round2_cg_hid_dlsym_blacklist(void) {
    const char *blocked[] = {
        "CGMainDisplayID", "CGGetActiveDisplayList", "CGGetOnlineDisplayList",
        "CGWindowListCopyWindowInfo", "CGPreflightScreenCaptureAccess",
        "CGSessionCopyCurrentDictionary", "IOHIDManagerCreate", "IOHIDManagerCopyDevices"
    };
    for (size_t i = 0; i < sizeof(blocked) / sizeof(blocked[0]); i++) {
        assert(is_blocked_cg_or_hid_symbol(blocked[i]) == 1);
    }
    const char *allowed_ios_cg[] = {
        "CGContextDrawImage", "CGImageCreate", "CGColorSpaceCreateDeviceRGB",
        "CGPathCreateMutable", "CGBitmapContextCreate", "CGDataProviderCreateWithData"
    };
    for (size_t i = 0; i < sizeof(allowed_ios_cg) / sizeof(allowed_ios_cg[0]); i++) {
        assert(is_blocked_cg_or_hid_symbol(allowed_ios_cg[i]) == 0);
    }
}

static int is_macos_only_framework_path(const char *path) {
    static const char *const kMacFrameworks[] = {
        "AppKit.framework", "Cocoa.framework", "Carbon.framework",
        "ServiceManagement.framework", "DiskArbitration.framework",
        "CoreWLAN.framework", "EndpointSecurity.framework",
        "ScriptingBridge.framework", "ApplicationServices.framework",
        "QTKit.framework", "ScreenCaptureKit.framework", "IOBluetooth.framework"
    };
    if (path == NULL) return 0;
    for (size_t i = 0; i < sizeof(kMacFrameworks) / sizeof(kMacFrameworks[0]); i++) {
        if (ci_contains(path, kMacFrameworks[i])) return 1;
    }
    return 0;
}

static int is_macos_only_desktop_font(const char *name) {
    static const char *const kDesktopFonts[] = {
        "monaco", "lucida grande", "lucidagrande", "skia", "osaka",
        "applegothic", "wingdings", "andale mono", "big caslon", "comic sans ms"
    };
    if (name == NULL) return 0;
    for (size_t i = 0; i < sizeof(kDesktopFonts) / sizeof(kDesktopFonts[0]); i++) {
        if (ci_contains(name, kDesktopFonts[i])) return 1;
    }
    return 0;
}

static void test_round2_macos_framework_and_font_filters(void) {
    const char *mac_fw[] = {
        "/System/Library/Frameworks/Cocoa.framework/Cocoa",
        "/System/Library/Frameworks/Carbon.framework/Carbon",
        "/System/Library/Frameworks/ServiceManagement.framework/ServiceManagement",
        "/System/Library/Frameworks/DiskArbitration.framework/DiskArbitration",
        "/System/Library/Frameworks/CoreWLAN.framework/CoreWLAN",
        "/System/Library/Frameworks/EndpointSecurity.framework/EndpointSecurity",
        "/System/Library/Frameworks/ScriptingBridge.framework/ScriptingBridge",
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
        "/System/Library/Frameworks/AppKit.framework/AppKit"
    };
    for (size_t i = 0; i < sizeof(mac_fw) / sizeof(mac_fw[0]); i++) {
        assert(is_macos_only_framework_path(mac_fw[i]) == 1);
    }
    const char *ios_fw[] = {
        "/System/Library/Frameworks/UIKit.framework/UIKit",
        "/System/Library/Frameworks/Foundation.framework/Foundation",
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
        "/System/Library/Frameworks/Metal.framework/Metal"
    };
    for (size_t i = 0; i < sizeof(ios_fw) / sizeof(ios_fw[0]); i++) {
        assert(is_macos_only_framework_path(ios_fw[i]) == 0);
    }

    const char *mac_fonts[] = {
        "Monaco", "Lucida Grande", "Skia", "Osaka", "AppleGothic",
        "Wingdings", "Andale Mono", "Big Caslon", "Comic Sans MS"
    };
    for (size_t i = 0; i < sizeof(mac_fonts) / sizeof(mac_fonts[0]); i++) {
        assert(is_macos_only_desktop_font(mac_fonts[i]) == 1);
    }
    const char *ios_fonts[] = {
        "Helvetica", "SF Pro", "PingFang SC", "Avenir", "Georgia", "Menlo"
    };
    for (size_t i = 0; i < sizeof(ios_fonts) / sizeof(ios_fonts[0]); i++) {
        assert(is_macos_only_desktop_font(ios_fonts[i]) == 0);
    }
}

static int is_desktop_xattr_name(const char *name) {
    static const char *const kExact[] = {
        "com.apple.quarantine", "com.apple.provenance", "com.apple.macl",
        "com.apple.FinderInfo", "com.apple.ResourceFork"
    };
    if (name == NULL) return 0;
    for (size_t i = 0; i < sizeof(kExact) / sizeof(kExact[0]); i++) {
        if (strcmp(name, kExact[i]) == 0) return 1;
    }
    return strncmp(name, "com.apple.metadata:", 19U) == 0;
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
    if (sun_path == NULL || sun_path[0] == '\0') return 0;
    return (strncmp(sun_path, "/Users/", 7U) == 0 ||
            ci_contains(sun_path, "/Library/Containers/") ||
            ci_contains(sun_path, "MacOver") ||
            ci_contains(sun_path, "PlayTools") ||
            ci_contains(sun_path, "PlayCover"));
}

static void test_round2_xattr_osvariant_and_afunix(void) {
    const char *bad_xattrs[] = {
        "com.apple.quarantine", "com.apple.provenance", "com.apple.macl",
        "com.apple.FinderInfo", "com.apple.ResourceFork",
        "com.apple.metadata:kMDItemWhereFroms"
    };
    for (size_t i = 0; i < sizeof(bad_xattrs) / sizeof(bad_xattrs[0]); i++) {
        assert(is_desktop_xattr_name(bad_xattrs[i]) == 1);
    }
    assert(is_desktop_xattr_name("com.example.custom") == 0);
    assert(is_desktop_xattr_name("com.apple.decmpfs") == 0);

    /* Simulate listxattr buffer compaction removing desktop xattrs */
    const char raw_list[] = "com.apple.quarantine\0com.example.custom\0com.apple.macl\0com.apple.metadata:kMDItemWhereFroms\0";
    char filtered[256];
    size_t out_len = 0;
    const char *cur = raw_list, *end = raw_list + sizeof(raw_list) - 1U;
    while (cur < end) {
        size_t slen = strlen(cur);
        if (slen > 0 && !is_desktop_xattr_name(cur)) {
            memcpy(filtered + out_len, cur, slen + 1U);
            out_len += slen + 1U;
        }
        cur += slen + 1U;
    }
    assert(out_len == strlen("com.example.custom") + 1U);
    assert(strcmp(filtered, "com.example.custom") == 0);

    /* kern.osvariant_status 2-bit pair sanitization: YES (0b11) -> NO (0b10), preserving bits [28..31] == 0xF and [60..62] == 0x7 */
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

static uint32_t rol32(uint32_t x, uint32_t n) { return (x << n) | (x >> (32U - n)); }

static void sha1_compute(const uint8_t *data, size_t len, uint8_t out[20]) {
    uint32_t h0 = 0x67452301U, h1 = 0xEFCDAB89U, h2 = 0x98BADCFEU, h3 = 0x10325476U, h4 = 0xC3D2E1F0U;
    size_t padded_len = ((len + 9U + 63U) / 64U) * 64U;
    uint8_t *buf = (uint8_t *)calloc(1, padded_len);
    assert(buf != NULL);
    memcpy(buf, data, len);
    buf[len] = 0x80U;
    uint64_t bits = (uint64_t)len * 8ULL;
    for (int i = 0; i < 8; i++) buf[padded_len - 1U - (size_t)i] = (uint8_t)((bits >> (i * 8)) & 0xFFU);
    for (size_t off = 0; off < padded_len; off += 64U) {
        uint32_t w[80];
        for (int i = 0; i < 16; i++) {
            w[i] = ((uint32_t)buf[off + (size_t)i * 4U] << 24) |
                   ((uint32_t)buf[off + (size_t)i * 4U + 1U] << 16) |
                   ((uint32_t)buf[off + (size_t)i * 4U + 2U] << 8) |
                   ((uint32_t)buf[off + (size_t)i * 4U + 3U]);
        }
        for (int i = 16; i < 80; i++) w[i] = rol32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1U);
        uint32_t a = h0, b = h1, c = h2, d = h3, e = h4;
        for (int i = 0; i < 80; i++) {
            uint32_t f, k;
            if (i < 20) { f = (b & c) | ((~b) & d); k = 0x5A827999U; }
            else if (i < 40) { f = b ^ c ^ d; k = 0x6ED9EBA1U; }
            else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDCU; }
            else { f = b ^ c ^ d; k = 0xCA62C1D6U; }
            uint32_t tmp = rol32(a, 5U) + f + e + k + w[i];
            e = d; d = c; c = rol32(b, 30U); b = a; a = tmp;
        }
        h0 += a; h1 += b; h2 += c; h3 += d; h4 += e;
    }
    free(buf);
    uint32_t hs[5] = { h0, h1, h2, h3, h4 };
    for (int i = 0; i < 5; i++) put_be32(out + (size_t)i * 4U, hs[i]);
}

static int is_post13_hardware_sf_symbol_prefix(const char *s) {
    static const char *const kHwPrefixes[] = {
        "macbook", "imac", "macmini", "macpro", "macstudio",
        "applewatch", "airpods", "visionpro", "xserve", "homepod"
    };
    if (s == NULL) return 0;
    for (size_t i = 0; i < sizeof(kHwPrefixes) / sizeof(kHwPrefixes[0]); i++) {
        size_t plen = strlen(kHwPrefixes[i]);
        if (strncmp(s, kHwPrefixes[i], plen) == 0 &&
            (s[plen] == '\0' || s[plen] == '.' || s[plen] == '_')) {
            return 1;
        }
    }
    return 0;
}

static void test_round2_sha1_sha256_cd_and_sfsymbols(void) {
    /* Verify SHA-1 standard test vector ("abc") */
    uint8_t abc_digest[20];
    sha1_compute((const uint8_t *)"abc", 3U, abc_digest);
    const uint8_t expected_abc[20] = {
        0xa9, 0x99, 0x3e, 0x36, 0x47, 0x06, 0x81, 0x6a, 0xba, 0x3e,
        0x25, 0x71, 0x78, 0x50, 0xc2, 0x6c, 0x9c, 0xd0, 0xd8, 0x9d
    };
    assert(memcmp(abc_digest, expected_abc, 20U) == 0);

    /* Dual CodeDirectory patching: SHA-1 (hashType=1, hashSize=20) + SHA-256 (hashType=2, hashSize=32) */
    const uint8_t slot5[16] = { 0xfa, 0xde, 0x71, 0x71, 0, 0, 0, 16, '<', 'p', 'l', 'i', 's', 't', '/', '>' };
    const uint8_t slot7[12] = { 0xfa, 0xde, 0x71, 0x72, 0, 0, 0, 12, 0x30, 0x02, 0x05, 0x00 };

    uint8_t cd_sha1[256];
    memset(cd_sha1, 0, sizeof(cd_sha1));
    put_be32(cd_sha1 + 0, 0xfade0c02U);
    put_be32(cd_sha1 + 4, 240U);
    put_be32(cd_sha1 + 16, 200U); /* hashOffset */
    put_be32(cd_sha1 + 24, 7U);   /* nSpecialSlots */
    cd_sha1[36] = 20U;            /* hashSize */
    cd_sha1[37] = 1U;             /* hashType = SHA-1 */

    uint8_t s5_sha1[20], s7_sha1[20];
    sha1_compute(slot5, sizeof(slot5), s5_sha1);
    sha1_compute(slot7, sizeof(slot7), s7_sha1);
    memcpy(cd_sha1 + 200U - 5U * 20U, s5_sha1, 20U);
    memcpy(cd_sha1 + 200U - 7U * 20U, s7_sha1, 20U);
    assert(memcmp(cd_sha1 + 100U, s5_sha1, 20U) == 0);
    assert(memcmp(cd_sha1 + 60U, s7_sha1, 20U) == 0);

    uint8_t cd_sha256[320];
    memset(cd_sha256, 0, sizeof(cd_sha256));
    put_be32(cd_sha256 + 0, 0xfade0c02U);
    put_be32(cd_sha256 + 4, 300U);
    put_be32(cd_sha256 + 16, 280U); /* hashOffset */
    put_be32(cd_sha256 + 24, 7U);   /* nSpecialSlots */
    cd_sha256[36] = 32U;            /* hashSize */
    cd_sha256[37] = 2U;             /* hashType = SHA-256 */

    uint8_t s5_sha256[32], s7_sha256[32];
    sha256_compute(slot5, sizeof(slot5), s5_sha256);
    sha256_compute(slot7, sizeof(slot7), s7_sha256);
    memcpy(cd_sha256 + 280U - 5U * 32U, s5_sha256, 32U);
    memcpy(cd_sha256 + 280U - 7U * 32U, s7_sha256, 32U);
    assert(memcmp(cd_sha256 + 120U, s5_sha256, 32U) == 0);
    assert(memcmp(cd_sha256 + 56U, s7_sha256, 32U) == 0);

    /* SF Symbols hardware prefix checks */
    assert(is_post13_hardware_sf_symbol_prefix("macbook") == 1);
    assert(is_post13_hardware_sf_symbol_prefix("macbook.gen2") == 1);
    assert(is_post13_hardware_sf_symbol_prefix("imac.fill") == 1);
    assert(is_post13_hardware_sf_symbol_prefix("macmini") == 1);
    assert(is_post13_hardware_sf_symbol_prefix("macpro.gen3") == 1);
    assert(is_post13_hardware_sf_symbol_prefix("macstudio") == 1);
    assert(is_post13_hardware_sf_symbol_prefix("applewatch.watchface") == 1);
    assert(is_post13_hardware_sf_symbol_prefix("airpods.pro") == 1);
    assert(is_post13_hardware_sf_symbol_prefix("visionpro") == 1);
    assert(is_post13_hardware_sf_symbol_prefix("gear") == 0);
    assert(is_post13_hardware_sf_symbol_prefix("house.fill") == 0);
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
    printf("All compat104 unit tests passed.\n");
    return 0;
}
