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

__attribute__((visibility("hidden"))) int pt_der_item_cmp(const void *a, const void *b) {
    const pt_der_item_t *ia = (const pt_der_item_t *)a;
    const pt_der_item_t *ib = (const pt_der_item_t *)b;
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
