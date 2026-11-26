//
//  PTCodeSignParser.c
//  PlayTools
//
//  Pure-C DER TLV encoder and Mach-O CodeDirectory/SuperBlob hash helpers.
//

#include "PTCodeSignParser.h"

#include <arpa/inet.h>
#include <stdlib.h>
#include <string.h>

__attribute__((visibility("hidden"))) void pt_der_buf_append(pt_der_buf_t *b, const void *src, size_t n) {
    if (b == NULL || b->failed || n == 0 || src == NULL) {
        return;
    }
    if (n > (16U << 20) - b->len) {
        b->failed = true;
        return;
    }
    if (b->len + n > b->cap) {
        size_t new_cap = (b->cap == 0) ? 256U : b->cap;
        while (new_cap < b->len + n) {
            if (new_cap > (8U << 20)) {
                b->failed = true;
                return;
            }
            new_cap *= 2U;
        }
        uint8_t *grown = (uint8_t *)realloc(b->data, new_cap);
        if (grown == NULL) {
            b->failed = true;
            return;
        }
        b->data = grown;
        b->cap = new_cap;
    }
    memcpy(b->data + b->len, src, n);
    b->len += n;
}

__attribute__((visibility("hidden"))) void pt_der_buf_append_byte(pt_der_buf_t *b, uint8_t v) {
    pt_der_buf_append(b, &v, 1U);
}

__attribute__((visibility("hidden"))) void pt_der_buf_append_tag_len(pt_der_buf_t *b, uint8_t tag, size_t content_len) {
    pt_der_buf_append_byte(b, tag);
    if (content_len < 0x80U) {
        pt_der_buf_append_byte(b, (uint8_t)content_len);
    } else if (content_len <= 0xffU) {
        uint8_t hdr[2] = {0x81U, (uint8_t)content_len};
        pt_der_buf_append(b, hdr, sizeof(hdr));
    } else if (content_len <= 0xffffU) {
        uint8_t hdr[3] = {0x82U, (uint8_t)(content_len >> 8), (uint8_t)(content_len & 0xffU)};
        pt_der_buf_append(b, hdr, sizeof(hdr));
    } else if (content_len <= 0xffffffU) {
        uint8_t hdr[4] = {0x83U, (uint8_t)((content_len >> 16) & 0xffU), (uint8_t)((content_len >> 8) & 0xffU),
                          (uint8_t)(content_len & 0xffU)};
        pt_der_buf_append(b, hdr, sizeof(hdr));
    } else {
        uint8_t hdr[5] = {0x84U, (uint8_t)((content_len >> 24) & 0xffU), (uint8_t)((content_len >> 16) & 0xffU),
                          (uint8_t)((content_len >> 8) & 0xffU), (uint8_t)(content_len & 0xffU)};
        pt_der_buf_append(b, hdr, sizeof(hdr));
    }
}

__attribute__((visibility("hidden"))) void pt_der_buf_wrap_tlv(pt_der_buf_t *out, uint8_t tag, const uint8_t *body,
                                                               size_t body_len) {
    pt_der_buf_append_tag_len(out, tag, body_len);
    pt_der_buf_append(out, body, body_len);
}

static bool pt_der_read_tlv(const uint8_t *buf, size_t len, size_t *out_hdr_len, size_t *out_body_len,
                            uint8_t *out_tag) {
    if (buf == NULL || len < 2U) {
        return false;
    }
    uint8_t tag = buf[0];
    uint8_t l0 = buf[1];
    size_t hdr_len = 2U;
    size_t body_len = 0U;
    if (l0 < 0x80U) {
        body_len = (size_t)l0;
    } else {
        size_t nbytes = (size_t)(l0 & 0x7fU);
        if (nbytes == 0U || nbytes > 4U || len < 2U + nbytes) {
            return false;
        }
        hdr_len = 2U + nbytes;
        for (size_t i = 0; i < nbytes; i++) {
            body_len = (body_len << 8) | (size_t)buf[2U + i];
        }
    }
    if (body_len > len - hdr_len) {
        return false;
    }
    if (out_hdr_len != NULL) {
        *out_hdr_len = hdr_len;
    }
    if (out_body_len != NULL) {
        *out_body_len = body_len;
    }
    if (out_tag != NULL) {
        *out_tag = tag;
    }
    return true;
}

static bool pt_der_extract_pair_key(const uint8_t *buf, size_t len, const uint8_t **out_key, size_t *out_key_len) {
    uint8_t seq_tag = 0;
    size_t seq_hdr = 0, seq_body = 0;
    if (!pt_der_read_tlv(buf, len, &seq_hdr, &seq_body, &seq_tag) || seq_tag != 0x30U) {
        return false;
    }
    const uint8_t *inner = buf + seq_hdr;
    uint8_t key_tag = 0;
    size_t key_hdr = 0, key_body = 0;
    if (!pt_der_read_tlv(inner, seq_body, &key_hdr, &key_body, &key_tag) || key_tag != 0x0cU) {
        return false;
    }
    if (out_key != NULL) {
        *out_key = inner + key_hdr;
    }
    if (out_key_len != NULL) {
        *out_key_len = key_body;
    }
    return true;
}

__attribute__((visibility("hidden"))) int pt_der_item_cmp(const void *a, const void *b) {
    const pt_der_item_t *ia = (const pt_der_item_t *)a;
    const pt_der_item_t *ib = (const pt_der_item_t *)b;
    const uint8_t *ka = NULL;
    const uint8_t *kb = NULL;
    size_t ka_len = 0;
    size_t kb_len = 0;
    if (pt_der_extract_pair_key(ia->bytes, ia->len, &ka, &ka_len) &&
        pt_der_extract_pair_key(ib->bytes, ib->len, &kb, &kb_len)) {
        size_t min_k = (ka_len < kb_len) ? ka_len : kb_len;
        int c = (min_k > 0) ? memcmp(ka, kb, min_k) : 0;
        if (c != 0) {
            return c;
        }
        if (ka_len < kb_len) {
            return -1;
        }
        return (ka_len > kb_len) ? 1 : 0;
    }
    size_t min_len = (ia->len < ib->len) ? ia->len : ib->len;
    int c = (min_len > 0) ? memcmp(ia->bytes, ib->bytes, min_len) : 0;
    if (c != 0) {
        return c;
    }
    if (ia->len < ib->len) {
        return -1;
    }
    return (ia->len > ib->len) ? 1 : 0;
}

__attribute__((visibility("hidden"))) void pt_sha256_cs_blob(uint32_t host_magic, const uint8_t *payload,
                                                             size_t payload_len,
                                                             uint8_t out_hash[CC_SHA256_DIGEST_LENGTH]) {
    size_t full_sz = 8U + payload_len;
    uint32_t hdr[2] = {htonl(host_magic), htonl((uint32_t)full_sz)};
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    CC_SHA256_Update(&ctx, hdr, sizeof(hdr));
    if (payload != NULL && payload_len > 0) {
        CC_SHA256_Update(&ctx, payload, (CC_LONG)payload_len);
    }
    CC_SHA256_Final(out_hash, &ctx);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
__attribute__((visibility("hidden"))) void pt_sha1_cs_blob(uint32_t host_magic, const uint8_t *payload,
                                                           size_t payload_len,
                                                           uint8_t out_hash[CC_SHA1_DIGEST_LENGTH]) {
    size_t full_sz = 8U + payload_len;
    uint32_t hdr[2] = {htonl(host_magic), htonl((uint32_t)full_sz)};
    CC_SHA1_CTX ctx;
    CC_SHA1_Init(&ctx);
    CC_SHA1_Update(&ctx, hdr, sizeof(hdr));
    if (payload != NULL && payload_len > 0) {
        CC_SHA1_Update(&ctx, payload, (CC_LONG)payload_len);
    }
    CC_SHA1_Final(out_hash, &ctx);
}
#pragma clang diagnostic pop

__attribute__((visibility("hidden"))) void pt_patch_code_directory_entitlement_hashes(
    uint8_t *cd_buf, size_t cd_len, bool has_xml, const uint8_t xml_hash[CC_SHA256_DIGEST_LENGTH],
    const uint8_t xml_sha1[CC_SHA1_DIGEST_LENGTH], bool has_der, const uint8_t der_hash[CC_SHA256_DIGEST_LENGTH],
    const uint8_t der_sha1[CC_SHA1_DIGEST_LENGTH]) {
    if (cd_buf == NULL || cd_len < 40U) {
        return;
    }
    uint32_t cd_magic = 0, cd_declared_len = 0, hash_offset = 0, n_special = 0;
    memcpy(&cd_magic, cd_buf + 0U, sizeof(cd_magic));
    memcpy(&cd_declared_len, cd_buf + 4U, sizeof(cd_declared_len));
    memcpy(&hash_offset, cd_buf + 16U, sizeof(hash_offset));
    memcpy(&n_special, cd_buf + 24U, sizeof(n_special));
    cd_magic = ntohl(cd_magic);
    cd_declared_len = ntohl(cd_declared_len);
    hash_offset = ntohl(hash_offset);
    n_special = ntohl(n_special);
    if (cd_magic != PT_CSMAGIC_CODEDIRECTORY || cd_declared_len > cd_len || hash_offset > cd_len) {
        return;
    }
    uint8_t hash_size = cd_buf[36];
    uint8_t hash_type = cd_buf[37];
    const uint8_t *use_xml = NULL;
    const uint8_t *use_der = NULL;
    if ((hash_type == PT_CS_HASHTYPE_SHA256 && hash_size == CC_SHA256_DIGEST_LENGTH) ||
        (hash_type == PT_CS_HASHTYPE_SHA256_TRUNCATED && hash_size == 20U)) {
        use_xml = xml_hash;
        use_der = der_hash;
    } else if (hash_type == PT_CS_HASHTYPE_SHA1 && hash_size == CC_SHA1_DIGEST_LENGTH) {
        use_xml = xml_sha1;
        use_der = der_sha1;
    } else {
        return;
    }
    if (n_special >= PT_CSSLOT_ENTITLEMENTS && hash_offset >= (uint32_t)PT_CSSLOT_ENTITLEMENTS * (uint32_t)hash_size) {
        size_t off5 = (size_t)hash_offset - (size_t)PT_CSSLOT_ENTITLEMENTS * (size_t)hash_size;
        if (off5 + (size_t)hash_size <= cd_len) {
            if (has_xml && use_xml != NULL) {
                memcpy(cd_buf + off5, use_xml, (size_t)hash_size);
            } else {
                memset(cd_buf + off5, 0, (size_t)hash_size);
            }
        }
    }
    if (n_special >= PT_CSSLOT_DER_ENTITLEMENTS &&
        hash_offset >= (uint32_t)PT_CSSLOT_DER_ENTITLEMENTS * (uint32_t)hash_size) {
        size_t off7 = (size_t)hash_offset - (size_t)PT_CSSLOT_DER_ENTITLEMENTS * (size_t)hash_size;
        if (off7 + (size_t)hash_size <= cd_len) {
            if (has_der && use_der != NULL) {
                memcpy(cd_buf + off7, use_der, (size_t)hash_size);
            } else {
                memset(cd_buf + off7, 0, (size_t)hash_size);
            }
        }
    }
}

__attribute__((visibility("hidden"))) uint32_t pt_code_directory_special_slot_count(const uint8_t *cd_buf,
                                                                                    size_t cd_len) {
    if (cd_buf == NULL || cd_len < 40U) {
        return 0U;
    }
    uint32_t cd_magic = 0, cd_declared_len = 0, n_special = 0;
    memcpy(&cd_magic, cd_buf + 0U, sizeof(cd_magic));
    memcpy(&cd_declared_len, cd_buf + 4U, sizeof(cd_declared_len));
    memcpy(&n_special, cd_buf + 24U, sizeof(n_special));
    cd_magic = ntohl(cd_magic);
    cd_declared_len = ntohl(cd_declared_len);
    n_special = ntohl(n_special);
    if (cd_magic != PT_CSMAGIC_CODEDIRECTORY || cd_declared_len > cd_len) {
        return 0U;
    }
    return n_special;
}

__attribute__((visibility("hidden"))) void pt_patch_code_directory_metadata(uint8_t *cd_buf, size_t cd_len,
                                                                            uint32_t clear_flags_mask,
                                                                            const char *replacement_team_id) {
    if (cd_buf == NULL || cd_len < 40U) {
        return;
    }
    uint32_t cd_magic = 0, cd_declared_len = 0, cd_version = 0, cd_flags = 0;
    memcpy(&cd_magic, cd_buf + 0U, sizeof(cd_magic));
    memcpy(&cd_declared_len, cd_buf + 4U, sizeof(cd_declared_len));
    memcpy(&cd_version, cd_buf + 8U, sizeof(cd_version));
    memcpy(&cd_flags, cd_buf + 12U, sizeof(cd_flags));
    cd_magic = ntohl(cd_magic);
    cd_declared_len = ntohl(cd_declared_len);
    cd_version = ntohl(cd_version);
    cd_flags = ntohl(cd_flags);
    if (cd_magic != PT_CSMAGIC_CODEDIRECTORY || cd_declared_len > cd_len) {
        return;
    }
    cd_flags &= ~clear_flags_mask;
    uint32_t be_flags = htonl(cd_flags);
    memcpy(cd_buf + 12U, &be_flags, sizeof(be_flags));

    if (cd_len >= 52U && cd_version >= 0x20200U && replacement_team_id != NULL && strlen(replacement_team_id) == 10U) {
        uint32_t team_off = 0;
        memcpy(&team_off, cd_buf + 48U, sizeof(team_off));
        team_off = ntohl(team_off);
        if (team_off > 0U && (size_t)team_off + 11U <= cd_len) {
            const char *cur_team = (const char *)(cd_buf + team_off);
            if (memcmp(cur_team, "FAKETEAMID", 10U) == 0 && cur_team[10] == '\0') {
                memcpy(cd_buf + team_off, replacement_team_id, 10U);
            }
        }
    }
}
