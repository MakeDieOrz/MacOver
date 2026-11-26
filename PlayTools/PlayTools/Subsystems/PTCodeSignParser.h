//
//  PTCodeSignParser.h
//  PlayTools
//
//  Pure-C DER TLV encoder and Mach-O CodeDirectory/SuperBlob hash helpers.
//

#ifndef PTCodeSignParser_h
#define PTCodeSignParser_h

#include <CommonCrypto/CommonDigest.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PT_CSMAGIC_EMBEDDED_ENTITLEMENTS 0xfade7171U
#define PT_CSMAGIC_EMBEDDED_DER_ENTITLEMENTS 0xfade7172U
#define PT_CSMAGIC_EMBEDDED_SIGNATURE 0xfade0cc0U
#define PT_CSMAGIC_CODEDIRECTORY 0xfade0c02U
#define PT_CSSLOT_CODEDIRECTORY 0U
#define PT_CSSLOT_ENTITLEMENTS 5U
#define PT_CSSLOT_DER_ENTITLEMENTS 7U
#define PT_CSSLOT_ALTERNATE_CODEDIRECTORIES 0x1000U
#define PT_CSSLOT_ALTERNATE_CODEDIRECTORY_MAX 5U
#define PT_CS_HASHTYPE_SHA1 1U
#define PT_CS_HASHTYPE_SHA256 2U
#define PT_CS_HASHTYPE_SHA256_TRUNCATED 3U

typedef struct {
    uint8_t *data;
    size_t len;
    size_t cap;
    bool failed;
} pt_der_buf_t;

typedef struct {
    uint8_t *bytes;
    size_t len;
} pt_der_item_t;

__attribute__((visibility("hidden"))) void pt_der_buf_append(pt_der_buf_t *b, const void *src, size_t n);
__attribute__((visibility("hidden"))) void pt_der_buf_append_byte(pt_der_buf_t *b, uint8_t v);
__attribute__((visibility("hidden"))) void pt_der_buf_append_tag_len(pt_der_buf_t *b, uint8_t tag, size_t content_len);
__attribute__((visibility("hidden"))) void pt_der_buf_wrap_tlv(pt_der_buf_t *out, uint8_t tag, const uint8_t *body,
                                                               size_t body_len);
__attribute__((visibility("hidden"))) int pt_der_item_cmp(const void *a, const void *b);

__attribute__((visibility("hidden"))) void pt_sha256_cs_blob(uint32_t host_magic, const uint8_t *payload,
                                                             size_t payload_len,
                                                             uint8_t out_hash[CC_SHA256_DIGEST_LENGTH]);
__attribute__((visibility("hidden"))) void pt_sha1_cs_blob(uint32_t host_magic, const uint8_t *payload,
                                                           size_t payload_len, uint8_t out_hash[CC_SHA1_DIGEST_LENGTH]);
__attribute__((visibility("hidden"))) void pt_patch_code_directory_entitlement_hashes(
    uint8_t *cd_buf, size_t cd_len, bool has_xml, const uint8_t xml_hash[CC_SHA256_DIGEST_LENGTH],
    const uint8_t xml_sha1[CC_SHA1_DIGEST_LENGTH], bool has_der, const uint8_t der_hash[CC_SHA256_DIGEST_LENGTH],
    const uint8_t der_sha1[CC_SHA1_DIGEST_LENGTH]);
__attribute__((visibility("hidden"))) uint32_t pt_code_directory_special_slot_count(const uint8_t *cd_buf,
                                                                                    size_t cd_len);
__attribute__((visibility("hidden"))) void pt_patch_code_directory_metadata(uint8_t *cd_buf, size_t cd_len,
                                                                            uint32_t clear_flags_mask,
                                                                            const char *replacement_team_id);

#ifdef __cplusplus
}
#endif

#endif /* PTCodeSignParser_h */
