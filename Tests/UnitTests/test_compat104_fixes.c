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
    printf("All compat104 unit tests passed.\n");
    return 0;
}
