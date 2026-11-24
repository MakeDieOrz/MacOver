//
//  PTEntitlements.m
//  PlayTools
//

#import "PTInternal.h"
#include <CommonCrypto/CommonDigest.h>

static NSDictionary *pt_get_fallback_entitlements_dict(void) {
    static NSDictionary *s_fallback_entitlements = nil;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        const char *user_root = pt_get_host_user_root_cstr();
        if (user_root == NULL) {
            return;
        }
        char bid[256];
        bid[0] = '\0';
        NSString *mainBid = [[NSBundle mainBundle] bundleIdentifier];
        if (mainBid.length > 0) {
            strlcpy(bid, [mainBid UTF8String], sizeof(bid));
        } else {
            (void)pt_read_main_bundle_id_early(bid, sizeof(bid));
        }
        if (bid[0] == '\0') {
            return;
        }
        char ent_path[PATH_MAX];
        int n = snprintf(ent_path, sizeof(ent_path),
                         "%s/Library/Containers/app.makedie.MacOver/Entitlements/%s.plist",
                         user_root, bid);
        if (n <= 0 || (size_t)n >= sizeof(ent_path)) {
            return;
        }
        int fd = pt_orig_open_nocancel(ent_path, O_RDONLY);
        if (fd < 0) {
            return;
        }
        size_t len = 0;
        size_t map_size = 0;
        uint8_t *bytes = pt_read_fd_plist_bytes(fd, &len, &map_size);
        close(fd);
        if (bytes != NULL && len > 0) {
            NSData *data = [NSData dataWithBytes:bytes length:len];
            munmap(bytes, map_size);
            id obj = [NSPropertyListSerialization propertyListWithData:data
                                                               options:NSPropertyListImmutable
                                                                format:nil
                                                                 error:nil];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                s_fallback_entitlements = (NSDictionary *)obj;
            }
        } else if (bytes != NULL) {
            munmap(bytes, map_size);
        }
    });
    return s_fallback_entitlements;
}

static BOOL pt_is_hidden_entitlement_key(NSString *key) {
    if (key == nil) {
        return NO;
    }
    if ([key isEqualToString:@"com.apple.security.application-groups"]) {
        return NO;
    }
    return ([key isEqualToString:@"get-task-allow"] ||
            [key isEqualToString:@"com.apple.private.tcc.allow"] ||
            [key hasPrefix:@"com.apple.security."]);
}

#define PT_CS_OPS_STATUS 0
#define PT_CS_OPS_ENTITLEMENTS_BLOB 7
#define PT_CS_OPS_BLOB 10U
#define PT_CS_OPS_IDENTITY 11
#define PT_CS_OPS_TEAMID 14
#define PT_CS_OPS_CLEAR_LV 15U
#define PT_CS_OPS_DER_ENTITLEMENTS_BLOB 16U
#define PT_CSMAGIC_EMBEDDED_ENTITLEMENTS 0xfade7171U
#define PT_CSMAGIC_EMBEDDED_DER_ENTITLEMENTS 0xfade7172U
#define PT_CSMAGIC_EMBEDDED_SIGNATURE 0xfade0cc0U
#define PT_CSMAGIC_CODEDIRECTORY 0xfade0c02U
#define PT_CSSLOT_CODEDIRECTORY 0U
#define PT_CSSLOT_ENTITLEMENTS 5U
#define PT_CSSLOT_DER_ENTITLEMENTS 7U
#define PT_CSSLOT_ALTERNATE_CODEDIRECTORIES 0x1000U
#define PT_CSSLOT_ALTERNATE_CODEDIRECTORY_MAX 5U
#define PT_CS_HASHTYPE_SHA256 2U
#define PT_CS_HASHTYPE_SHA256_TRUNCATED 3U
#define PT_CS_VALID 0x00000001U
#define PT_CS_ADHOC 0x00000002U
#define PT_CS_GET_TASK_ALLOW 0x00000004U
#define PT_ERR_SEC_CS_NO_SUCH_CODE ((OSStatus)-67068)

static BOOL pt_is_valid_apple_team_id_str(const char *s, size_t len) {
    if (s == NULL || len != 10) {
        return NO;
    }
    for (size_t i = 0; i < 10; i++) {
        char c = s[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))) {
            return NO;
        }
    }
    if (strncmp(s, "FAKETEAMID", 10) == 0) {
        return NO;
    }
    return YES;
}

static void pt_get_effective_bundle_id_cstr(char *out_bid, size_t out_size) {
    if (out_bid == NULL || out_size == 0) {
        return;
    }
    out_bid[0] = '\0';
    NSString *mainBid = [[NSBundle mainBundle] bundleIdentifier];
    if (mainBid.length > 0 &&
        [mainBid rangeOfString:@"PlayCover" options:NSCaseInsensitiveSearch].location == NSNotFound &&
        [mainBid rangeOfString:@"MacOver" options:NSCaseInsensitiveSearch].location == NSNotFound) {
        strlcpy(out_bid, [mainBid UTF8String], out_size);
    } else {
        (void)pt_read_main_bundle_id_early(out_bid, out_size);
    }
    if (out_bid[0] == '\0') {
        strlcpy(out_bid, "com.apple.mobile.application", out_size);
    }
}

static BOOL pt_extract_team_id_from_mobileprovision(char out_team[16]) {
    char vbuf[PATH_MAX];
    const char *vpath = pt_copy_virtual_mobileprovision_path(vbuf, sizeof(vbuf));
    if (vpath == NULL || vpath[0] == '\0') {
        return NO;
    }
    char rbuf[PATH_MAX];
    const char *rpath = pt_resolve_virtual_path(vpath, rbuf, sizeof(rbuf));
    char bbuf[PATH_MAX];
    int sys_flag = 0;
    const char *bpath = pt_lookup_app_backup_redirect_for_caller(
        rpath != NULL ? rpath : vpath, NULL, bbuf, sizeof(bbuf), &sys_flag);
    const char *open_path = (bpath != NULL) ? bpath : rpath;
    if (open_path == NULL || open_path[0] != '/') {
        return NO;
    }
    int fd = pt_orig_open_nocancel(open_path, O_RDONLY);
    if (fd < 0) {
        return NO;
    }
    size_t len = 0, map_sz = 0;
    uint8_t *bytes = pt_read_fd_plist_bytes(fd, &len, &map_sz);
    close(fd);
    if (bytes == NULL || len < 32) {
        if (bytes != NULL) {
            munmap(bytes, map_sz);
        }
        return NO;
    }
    BOOL found = NO;
    const char *needle = "<key>TeamIdentifier</key>";
    size_t nlen = strlen(needle);
    for (size_t i = 0; i + nlen + 24 < len; i++) {
        if (memcmp(bytes + i, needle, nlen) == 0) {
            const char *s = (const char *)(bytes + i + nlen);
            const char *end = (const char *)(bytes + ((i + nlen + 256 < len) ? (i + nlen + 256) : len));
            const char *tag = "<string>";
            for (const char *p = s; p + 18 < end; p++) {
                if (memcmp(p, tag, 8) == 0) {
                    const char *val = p + 8;
                    if (pt_is_valid_apple_team_id_str(val, 10) && val[10] == '<') {
                        memcpy(out_team, val, 10);
                        out_team[10] = '\0';
                        found = YES;
                    }
                    break;
                }
            }
            break;
        }
    }
    munmap(bytes, map_sz);
    return found;
}

static const char *pt_get_effective_team_id_cstr(void) {
    static char s_team_id[16] = {0};
    static dispatch_once_t s_team_once;
    dispatch_once(&s_team_once, ^{
        NSDictionary *fb = pt_get_fallback_entitlements_dict();
        id tObj = fb[@"com.apple.developer.team-identifier"];
        if ([tObj isKindOfClass:[NSString class]]) {
            const char *tc = [(NSString *)tObj UTF8String];
            if (tc != NULL && pt_is_valid_apple_team_id_str(tc, strlen(tc))) {
                strlcpy(s_team_id, tc, sizeof(s_team_id));
                return;
            }
        }
        id appIdObj = fb[@"application-identifier"];
        if ([appIdObj isKindOfClass:[NSString class]]) {
            const char *ac = [(NSString *)appIdObj UTF8String];
            const char *dot = (ac != NULL) ? strchr(ac, '.') : NULL;
            if (dot != NULL && pt_is_valid_apple_team_id_str(ac, (size_t)(dot - ac))) {
                memcpy(s_team_id, ac, 10);
                s_team_id[10] = '\0';
                return;
            }
        }
        if (pt_extract_team_id_from_mobileprovision(s_team_id)) {
            return;
        }
        char bid[256];
        pt_get_effective_bundle_id_cstr(bid, sizeof(bid));
        static const char kAlpha[] = "ABCDEFGHJKLMNPQRSTUVWXYZ";
        static const char kAlnum[] = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
        uint64_t h1 = 14695981039346656037ULL;
        for (const unsigned char *p = (const unsigned char *)bid; *p != '\0'; p++) {
            h1 ^= (uint64_t)(*p);
            h1 *= 1099511628211ULL;
        }
        uint64_t h2 = h1 ^ 0x9E3779B97F4A7C15ULL;
        h2 *= 0xBF58476D1CE4E5B9ULL;
        s_team_id[0] = kAlpha[h1 % 24ULL];
        for (int i = 1; i < 10; i++) {
            uint64_t v = (i < 6) ? (h1 >> (i * 6)) : (h2 >> ((i - 6) * 6));
            s_team_id[i] = kAlnum[v & 31ULL];
        }
        s_team_id[10] = '\0';
    });
    return s_team_id;
}

static NSDictionary *pt_get_synthesized_app_entitlements_dict(void) {
    static NSDictionary *s_synth_ent = nil;
    static dispatch_once_t s_synth_once;
    dispatch_once(&s_synth_once, ^{
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        NSDictionary *fb = pt_get_fallback_entitlements_dict();
        for (NSString *k in fb) {
            if ([k isKindOfClass:[NSString class]] && !pt_is_hidden_entitlement_key(k)) {
                m[k] = fb[k];
            }
        }
        const char *team = pt_get_effective_team_id_cstr();
        char bid[256];
        pt_get_effective_bundle_id_cstr(bid, sizeof(bid));
        NSString *teamStr = [NSString stringWithUTF8String:team];
        NSString *bidStr = [NSString stringWithUTF8String:bid];
        if (teamStr.length == 10) {
            if (m[@"com.apple.developer.team-identifier"] == nil) {
                m[@"com.apple.developer.team-identifier"] = teamStr;
            }
            id curAppId = m[@"application-identifier"];
            if (![curAppId isKindOfClass:[NSString class]] ||
                [(NSString *)curAppId hasPrefix:@"FAKETEAMID."] ||
                [(NSString *)curAppId length] == 0) {
                m[@"application-identifier"] = [NSString stringWithFormat:@"%@.%@", teamStr, bidStr];
            }
            if (m[@"keychain-access-groups"] == nil) {
                m[@"keychain-access-groups"] = @[ [NSString stringWithFormat:@"%@.%@", teamStr, bidStr] ];
            }
        }
        s_synth_ent = [m copy];
    });
    return s_synth_ent;
}

static NSData *pt_get_synthesized_entitlements_xml_data(void) {
    static NSData *s_xml_data = nil;
    static dispatch_once_t s_xml_once;
    dispatch_once(&s_xml_once, ^{
        NSDictionary *ent = pt_get_synthesized_app_entitlements_dict();
        if (ent != nil) {
            s_xml_data = [NSPropertyListSerialization dataWithPropertyList:ent
                                                                    format:NSPropertyListXMLFormat_v1_0
                                                                   options:0
                                                                     error:nil];
        }
    });
    return s_xml_data;
}

typedef struct {
    uint8_t *data;
    size_t len;
    size_t cap;
    BOOL failed;
} pt_der_buf_t;

static void pt_der_buf_append(pt_der_buf_t *b, const void *src, size_t n) {
    if (b == NULL || b->failed || n == 0 || src == NULL) {
        return;
    }
    if (n > (16U << 20) - b->len) {
        b->failed = YES;
        return;
    }
    if (b->len + n > b->cap) {
        size_t new_cap = (b->cap == 0) ? 256U : b->cap;
        while (new_cap < b->len + n) {
            if (new_cap > (8U << 20)) {
                b->failed = YES;
                return;
            }
            new_cap *= 2U;
        }
        uint8_t *grown = (uint8_t *)realloc(b->data, new_cap);
        if (grown == NULL) {
            b->failed = YES;
            return;
        }
        b->data = grown;
        b->cap = new_cap;
    }
    memcpy(b->data + b->len, src, n);
    b->len += n;
}

static void pt_der_buf_append_byte(pt_der_buf_t *b, uint8_t v) {
    pt_der_buf_append(b, &v, 1U);
}

static void pt_der_buf_append_tag_len(pt_der_buf_t *b, uint8_t tag, size_t content_len) {
    pt_der_buf_append_byte(b, tag);
    if (content_len < 0x80U) {
        pt_der_buf_append_byte(b, (uint8_t)content_len);
    } else if (content_len <= 0xffU) {
        uint8_t hdr[2] = { 0x81U, (uint8_t)content_len };
        pt_der_buf_append(b, hdr, sizeof(hdr));
    } else if (content_len <= 0xffffU) {
        uint8_t hdr[3] = { 0x82U, (uint8_t)(content_len >> 8), (uint8_t)(content_len & 0xffU) };
        pt_der_buf_append(b, hdr, sizeof(hdr));
    } else if (content_len <= 0xffffffU) {
        uint8_t hdr[4] = {
            0x83U,
            (uint8_t)((content_len >> 16) & 0xffU),
            (uint8_t)((content_len >> 8) & 0xffU),
            (uint8_t)(content_len & 0xffU)
        };
        pt_der_buf_append(b, hdr, sizeof(hdr));
    } else {
        uint8_t hdr[5] = {
            0x84U,
            (uint8_t)((content_len >> 24) & 0xffU),
            (uint8_t)((content_len >> 16) & 0xffU),
            (uint8_t)((content_len >> 8) & 0xffU),
            (uint8_t)(content_len & 0xffU)
        };
        pt_der_buf_append(b, hdr, sizeof(hdr));
    }
}

static void pt_der_buf_wrap_tlv(pt_der_buf_t *out, uint8_t tag, const uint8_t *body, size_t body_len) {
    pt_der_buf_append_tag_len(out, tag, body_len);
    pt_der_buf_append(out, body, body_len);
}

typedef struct {
    uint8_t *bytes;
    size_t len;
} pt_der_item_t;

static int pt_der_item_cmp(const void *a, const void *b) {
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

static BOOL pt_der_encode_objc_value(id val, pt_der_buf_t *out);

static void pt_der_encode_dict_pairs(NSDictionary *dict, uint8_t container_tag, pt_der_buf_t *out) {
    if (out == NULL || out->failed) {
        return;
    }
    NSArray *keys = [dict allKeys];
    size_t count = keys.count;
    pt_der_item_t *items = (count > 0) ? (pt_der_item_t *)calloc(count, sizeof(pt_der_item_t)) : NULL;
    if (count > 0 && items == NULL) {
        out->failed = YES;
        return;
    }
    size_t item_count = 0;
    for (id rawKey in keys) {
        if (![rawKey isKindOfClass:[NSString class]]) {
            continue;
        }
        id v = dict[rawKey];
        if (v == nil) {
            continue;
        }
        pt_der_buf_t pair_body = {0};
        const char *kutf = [(NSString *)rawKey UTF8String];
        if (kutf == NULL) {
            continue;
        }
        pt_der_buf_wrap_tlv(&pair_body, 0x0cU, (const uint8_t *)kutf, strlen(kutf));
        if (pt_der_encode_objc_value(v, &pair_body) && !pair_body.failed && pair_body.data != NULL) {
            pt_der_buf_t pair_seq = {0};
            pt_der_buf_wrap_tlv(&pair_seq, 0x30U, pair_body.data, pair_body.len);
            if (!pair_seq.failed && pair_seq.data != NULL) {
                items[item_count].bytes = pair_seq.data;
                items[item_count].len = pair_seq.len;
                item_count++;
            } else {
                free(pair_seq.data);
            }
        }
        free(pair_body.data);
    }
    if (item_count > 1U) {
        qsort(items, item_count, sizeof(pt_der_item_t), pt_der_item_cmp);
    }
    pt_der_buf_t inner = {0};
    for (size_t i = 0; i < item_count; i++) {
        pt_der_buf_append(&inner, items[i].bytes, items[i].len);
        free(items[i].bytes);
    }
    free(items);
    if (!inner.failed) {
        pt_der_buf_wrap_tlv(out, container_tag, inner.data, inner.len);
    } else {
        out->failed = YES;
    }
    free(inner.data);
}

static BOOL pt_der_encode_objc_value(id val, pt_der_buf_t *out) {
    if (val == nil || out == NULL || out->failed) {
        return NO;
    }
    if (CFGetTypeID((__bridge CFTypeRef)val) == CFBooleanGetTypeID()) {
        uint8_t b = [(NSNumber *)val boolValue] ? 0xffU : 0x00U;
        pt_der_buf_wrap_tlv(out, 0x01U, &b, 1U);
        return !out->failed;
    }
    if ([val isKindOfClass:[NSNumber class]]) {
        int64_t iv = [(NSNumber *)val longLongValue];
        uint8_t raw[8];
        for (int i = 7; i >= 0; i--) {
            raw[7 - i] = (uint8_t)(((uint64_t)iv >> (i * 8)) & 0xffULL);
        }
        size_t start = 0;
        while (start < 7U) {
            if ((iv >= 0 && raw[start] == 0x00U && (raw[start + 1U] & 0x80U) == 0) ||
                (iv < 0 && raw[start] == 0xffU && (raw[start + 1U] & 0x80U) != 0)) {
                start++;
            } else {
                break;
            }
        }
        pt_der_buf_wrap_tlv(out, 0x02U, raw + start, 8U - start);
        return !out->failed;
    }
    if ([val isKindOfClass:[NSString class]]) {
        const char *s = [(NSString *)val UTF8String];
        if (s == NULL) {
            return NO;
        }
        pt_der_buf_wrap_tlv(out, 0x0cU, (const uint8_t *)s, strlen(s));
        return !out->failed;
    }
    if ([val isKindOfClass:[NSData class]]) {
        NSData *d = (NSData *)val;
        pt_der_buf_wrap_tlv(out, 0x04U, (const uint8_t *)d.bytes, d.length);
        return !out->failed;
    }
    if ([val isKindOfClass:[NSArray class]]) {
        pt_der_buf_t body = {0};
        for (id elem in (NSArray *)val) {
            (void)pt_der_encode_objc_value(elem, &body);
        }
        if (!body.failed) {
            pt_der_buf_wrap_tlv(out, 0x30U, body.data, body.len);
        } else {
            out->failed = YES;
        }
        free(body.data);
        return !out->failed;
    }
    if ([val isKindOfClass:[NSDictionary class]]) {
        pt_der_encode_dict_pairs((NSDictionary *)val, 0x31U, out);
        return !out->failed;
    }
    return NO;
}

static NSData *pt_get_synthesized_entitlements_der_data(void) {
    static NSData *s_der_data = nil;
    static dispatch_once_t s_der_once;
    dispatch_once(&s_der_once, ^{
        NSDictionary *ent = pt_get_synthesized_app_entitlements_dict();
        if (ent == nil) {
            return;
        }
        pt_der_buf_t root_body = {0};
        uint8_t ver_tlv[3] = { 0x02U, 0x01U, 0x01U };
        pt_der_buf_append(&root_body, ver_tlv, sizeof(ver_tlv));
        pt_der_encode_dict_pairs(ent, 0x31U, &root_body);
        pt_der_buf_t root = {0};
        if (!root_body.failed && root_body.data != NULL) {
            pt_der_buf_wrap_tlv(&root, 0x70U, root_body.data, root_body.len);
        }
        free(root_body.data);
        if (!root.failed && root.data != NULL && root.len > 0) {
            s_der_data = [NSData dataWithBytes:root.data length:root.len];
        }
        free(root.data);
    });
    return s_der_data;
}

static int pt_csops_write_blob_or_erange(uint32_t host_magic,
                                         const void *payload,
                                         size_t payload_len,
                                         void *useraddr,
                                         size_t usersize) {
    if (usersize > 0 && useraddr == NULL) {
        errno = EFAULT;
        return -1;
    }
    size_t total_len = 8U + payload_len;
    if (usersize < 8U) {
        errno = ERANGE;
        return -1;
    }
    uint32_t hdr[2];
    hdr[0] = htonl(host_magic);
    hdr[1] = htonl((uint32_t)total_len);
    memcpy(useraddr, hdr, 8U);
    if (usersize < total_len) {
        errno = ERANGE;
        return -1;
    }
    if (payload_len > 0 && payload != NULL) {
        memcpy((uint8_t *)useraddr + 8U, payload, payload_len);
    }
    return 0;
}

static CFTypeRef pt_SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error) {
    if (entitlement == NULL) {
        if (error != NULL) {
            *error = NULL;
        }
        return NULL;
    }
    NSString *key = (__bridge NSString *)entitlement;
    BOOL bypass = pt_is_bypass_enabled();
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(__builtin_return_address(0));
    if (bypass && key != nil && !is_sys && pt_is_hidden_entitlement_key(key)) {
        PT_DEBUG_TRACE("entitlements", "hid SecTask entitlement=%s", [key UTF8String] ?: "<nil>");
        if (error != NULL) {
            *error = NULL;
        }
        return NULL;
    }
    CFErrorRef localErr = NULL;
    CFTypeRef val = SecTaskCopyValueForEntitlement(task, entitlement, error != NULL ? &localErr : NULL);
    if (val == NULL && key != nil && !is_sys && (!bypass || !pt_is_hidden_entitlement_key(key))) {
        id fallback = bypass ? pt_get_synthesized_app_entitlements_dict()[key]
                             : pt_get_fallback_entitlements_dict()[key];
        if (fallback != nil) {
            if (localErr != NULL) {
                CFRelease(localErr);
                localErr = NULL;
            }
            if (error != NULL) {
                *error = NULL;
            }
            return CFBridgingRetain(fallback);
        }
    }
    if (error != NULL) {
        *error = localErr;
    } else if (localErr != NULL) {
        CFRelease(localErr);
    }
    return val;
}

static CFDictionaryRef pt_SecTaskCopyValuesForEntitlements(SecTaskRef task, CFArrayRef entitlements, CFErrorRef *error) {
    BOOL bypass = pt_is_bypass_enabled();
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(__builtin_return_address(0));
    CFErrorRef localErr = NULL;
    CFDictionaryRef orig = SecTaskCopyValuesForEntitlements(task, entitlements, error != NULL ? &localErr : NULL);
    if (!is_sys) {
        NSDictionary *dict = (__bridge NSDictionary *)orig;
        NSMutableDictionary *clean = nil;
        if (bypass && dict != nil) {
            for (NSString *key in dict) {
                if ([key isKindOfClass:[NSString class]] && pt_is_hidden_entitlement_key(key)) {
                    if (clean == nil) {
                        clean = [dict mutableCopy];
                    }
                    [clean removeObjectForKey:key];
                }
            }
        }
        if (entitlements != NULL) {
            NSDictionary *fb = bypass ? pt_get_synthesized_app_entitlements_dict()
                                      : pt_get_fallback_entitlements_dict();
            if (fb.count > 0) {
                for (id reqKey in (__bridge NSArray *)entitlements) {
                    if ([reqKey isKindOfClass:[NSString class]] &&
                        (!bypass || !pt_is_hidden_entitlement_key((NSString *)reqKey))) {
                        id curVal = (clean != nil) ? clean[reqKey] : dict[reqKey];
                        if (curVal == nil && fb[reqKey] != nil) {
                            if (clean == nil) {
                                clean = (dict != nil) ? [dict mutableCopy] : [NSMutableDictionary dictionary];
                            }
                            clean[reqKey] = fb[reqKey];
                        }
                    }
                }
            }
        }
        if (clean != nil) {
            if (orig != NULL) {
                CFRelease(orig);
            }
            if (localErr != NULL) {
                CFRelease(localErr);
                localErr = NULL;
            }
            if (error != NULL) {
                *error = NULL;
            }
            return (__bridge_retained CFDictionaryRef)[clean copy];
        }
    }
    if (error != NULL) {
        *error = localErr;
    } else if (localErr != NULL) {
        CFRelease(localErr);
    }
    return orig;
}

static uint32_t pt_SecTaskGetCodeSignStatus(SecTaskRef task) {
    uint32_t flags = SecTaskGetCodeSignStatus(task);
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        flags &= ~(PT_CS_ADHOC | PT_CS_GET_TASK_ALLOW);
        flags |= PT_CS_VALID;
    }
    return flags;
}

static CFStringRef pt_SecTaskCopySigningIdentifier(SecTaskRef task, CFErrorRef *error) {
    CFErrorRef localErr = NULL;
    CFStringRef ident = SecTaskCopySigningIdentifier(task, error != NULL ? &localErr : NULL);
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        BOOL bad = (ident == NULL);
        if (!bad &&
            ([(__bridge NSString *)ident rangeOfString:@"PlayCover" options:NSCaseInsensitiveSearch].location !=
                 NSNotFound ||
             [(__bridge NSString *)ident rangeOfString:@"MacOver" options:NSCaseInsensitiveSearch].location !=
                 NSNotFound ||
             [(__bridge NSString *)ident rangeOfString:@"app.makedie" options:NSCaseInsensitiveSearch].location !=
                 NSNotFound)) {
            bad = YES;
        }
        if (bad) {
            char bid[256];
            bid[0] = '\0';
            NSString *mainBid = [[NSBundle mainBundle] bundleIdentifier];
            if (mainBid.length > 0 &&
                [mainBid rangeOfString:@"PlayCover" options:NSCaseInsensitiveSearch].location == NSNotFound &&
                [mainBid rangeOfString:@"MacOver" options:NSCaseInsensitiveSearch].location == NSNotFound) {
                strlcpy(bid, [mainBid UTF8String], sizeof(bid));
            } else {
                (void)pt_read_main_bundle_id_early(bid, sizeof(bid));
            }
            if (bid[0] != '\0') {
                if (ident != NULL) {
                    CFRelease(ident);
                }
                if (localErr != NULL) {
                    CFRelease(localErr);
                    localErr = NULL;
                }
                if (error != NULL) {
                    *error = NULL;
                }
                return CFStringCreateWithCString(kCFAllocatorDefault, bid, kCFStringEncodingUTF8);
            }
        }
    }
    if (error != NULL) {
        *error = localErr;
    } else if (localErr != NULL) {
        CFRelease(localErr);
    }
    return ident;
}

static BOOL pt_static_code_is_hidden(SecStaticCodeRef staticCode, const void *caller, BOOL *out_in_app_bundle) {
    if (out_in_app_bundle != NULL) {
        *out_in_app_bundle = NO;
    }
    if (staticCode == NULL) {
        return NO;
    }
    CFURLRef codeURL = NULL;
    if (SecCodeCopyPath(staticCode, 0, &codeURL) != 0 || codeURL == NULL) {
        return NO;
    }
    UInt8 raw[PATH_MAX];
    BOOL hidden = NO;
    if (CFURLGetFileSystemRepresentation(codeURL, true, raw, sizeof(raw))) {
        const char *path = (const char *)raw;
        char vbuf[PATH_MAX];
        const char *virt = pt_virtualize_path_for_app(path, vbuf, sizeof(vbuf), YES);
        const char *check_path = (virt != NULL) ? virt : path;
        hidden = (pt_is_hidden_path(check_path, caller) || pt_is_hidden_dyld_image_name(check_path));
        if (out_in_app_bundle != NULL && !hidden) {
            pt_ensure_bundle_path_map();
            if (s_real_app_bundle_len > 0 &&
                strncmp(path, s_real_app_bundle_dir, s_real_app_bundle_len) == 0 &&
                (path[s_real_app_bundle_len] == '/' || path[s_real_app_bundle_len] == '\0')) {
                *out_in_app_bundle = YES;
            }
        }
    }
    CFRelease(codeURL);
    return hidden;
}

static BOOL pt_code_is_hidden(SecCodeRef code, const void *caller, BOOL *out_in_app_bundle) {
    if (code == NULL) {
        return NO;
    }
    SecStaticCodeRef sc = NULL;
    if (SecCodeCopyStaticCode(code, 0, &sc) != 0 || sc == NULL) {
        return NO;
    }
    BOOL hidden = pt_static_code_is_hidden(sc, caller, out_in_app_bundle);
    CFRelease(sc);
    return hidden;
}

static OSStatus pt_SecCodeCopySelf(SecCSFlags flags, SecCodeRef *self) {
    return SecCodeCopySelf(flags, self);
}

static OSStatus pt_SecCodeCopyStaticCode(SecCodeRef code, SecCSFlags flags, SecStaticCodeRef *staticCode) {
    return SecCodeCopyStaticCode(code, flags, staticCode);
}

static OSStatus pt_SecCodeCopyPath(SecStaticCodeRef staticCode, SecCSFlags flags, CFURLRef *path) {
    OSStatus st = SecCodeCopyPath(staticCode, flags, path);
    if (st == 0 && path != NULL && *path != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        *path = pt_sanitize_cfbundle_returned_url(*path, __builtin_return_address(0));
        if (*path == NULL) {
            return PT_ERR_SEC_CS_NO_SUCH_CODE;
        }
    }
    return st;
}

static OSStatus pt_SecCodeCopySigningInformation(SecStaticCodeRef code, SecCSFlags flags, CFDictionaryRef *information) {
    const void *caller = __builtin_return_address(0);
    BOOL app_caller = (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller));
    if (app_caller && pt_static_code_is_hidden(code, caller, NULL)) {
        if (information != NULL) {
            *information = NULL;
        }
        return PT_ERR_SEC_CS_NO_SUCH_CODE;
    }
    OSStatus st = SecCodeCopySigningInformation(code, flags, information);
    if (st == 0 && information != NULL && *information != NULL && app_caller) {
        NSDictionary *dict = (__bridge NSDictionary *)(*information);
        if ([dict isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *clean = [dict mutableCopy];
            id mainExec = clean[@"main-executable"];
            if (mainExec != nil && CFGetTypeID((__bridge CFTypeRef)mainExec) == CFURLGetTypeID()) {
                CFURLRef virtURL = pt_sanitize_cfbundle_returned_url(
                    (CFURLRef)CFRetain((__bridge CFTypeRef)mainExec), caller);
                if (virtURL != NULL) {
                    clean[@"main-executable"] = (__bridge_transfer NSURL *)virtURL;
                } else {
                    [clean removeObjectForKey:@"main-executable"];
                }
            }
            id infoPlist = clean[@"info-plist"];
            if ([infoPlist isKindOfClass:[NSDictionary class]] && pt_info_dict_needs_sanitize(infoPlist)) {
                NSDictionary *sanPlist = pt_build_sanitized_info_dict(infoPlist);
                if (sanPlist != nil) {
                    clean[@"info-plist"] = sanPlist;
                }
            }
            id entDict = clean[@"entitlements-dict"];
            if ([entDict isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *cleanEnt = nil;
                for (NSString *ek in (NSDictionary *)entDict) {
                    if ([ek isKindOfClass:[NSString class]] && pt_is_hidden_entitlement_key(ek)) {
                        if (cleanEnt == nil) {
                            cleanEnt = [(NSDictionary *)entDict mutableCopy];
                        }
                        [cleanEnt removeObjectForKey:ek];
                    }
                }
                if (cleanEnt != nil) {
                    clean[@"entitlements-dict"] = [cleanEnt copy];
                }
            }
            [clean removeObjectForKey:@"entitlements"];
            [clean removeObjectForKey:@"entitlements-DER"];
            [clean removeObjectForKey:@"changed-files"];
            id flagsObj = clean[@"flags"];
            if ([flagsObj isKindOfClass:[NSNumber class]]) {
                uint32_t f = [(NSNumber *)flagsObj unsignedIntValue];
                f &= ~(PT_CS_ADHOC | PT_CS_GET_TASK_ALLOW);
                clean[@"flags"] = @(f);
            }
            id statusObj = clean[@"status"];
            if ([statusObj isKindOfClass:[NSNumber class]]) {
                uint32_t s = [(NSNumber *)statusObj unsignedIntValue];
                s &= ~(PT_CS_ADHOC | PT_CS_GET_TASK_ALLOW);
                s |= PT_CS_VALID;
                clean[@"status"] = @(s);
            }
            id platObj = clean[@"platform-identifier"];
            if ([platObj isKindOfClass:[NSNumber class]] && [(NSNumber *)platObj intValue] > 0) {
                clean[@"platform-identifier"] = @(2);
            }
            id identObj = clean[@"identifier"];
            if ([identObj isKindOfClass:[NSString class]] &&
                ([(NSString *)identObj rangeOfString:@"PlayCover" options:NSCaseInsensitiveSearch].location !=
                     NSNotFound ||
                 [(NSString *)identObj rangeOfString:@"MacOver" options:NSCaseInsensitiveSearch].location !=
                     NSNotFound ||
                 [(NSString *)identObj rangeOfString:@"app.makedie" options:NSCaseInsensitiveSearch].location !=
                     NSNotFound)) {
                NSString *mainBid = [[NSBundle mainBundle] bundleIdentifier];
                if (mainBid.length > 0 &&
                    [mainBid rangeOfString:@"PlayCover" options:NSCaseInsensitiveSearch].location == NSNotFound &&
                    [mainBid rangeOfString:@"MacOver" options:NSCaseInsensitiveSearch].location == NSNotFound) {
                    clean[@"identifier"] = mainBid;
                }
            }
            if (clean[@"teamid"] == nil) {
                const char *team = pt_get_effective_team_id_cstr();
                if (team != NULL && team[0] != '\0') {
                    clean[@"teamid"] = [NSString stringWithUTF8String:team];
                }
            }
            CFRelease(*information);
            *information = (__bridge_retained CFDictionaryRef)[clean copy];
        }
    }
    return st;
}

static OSStatus pt_SecStaticCodeCreateWithPath(CFURLRef path, SecCSFlags flags, SecStaticCodeRef *staticCode) {
    const void *caller = __builtin_return_address(0);
    BOOL blocked = NO;
    CFURLRef resolvedURL = pt_resolve_cfbundle_input_url(path, caller, &blocked);
    if (blocked) {
        if (resolvedURL != NULL) {
            CFRelease(resolvedURL);
        }
        if (staticCode != NULL) {
            *staticCode = NULL;
        }
        return PT_ERR_SEC_CS_NO_SUCH_CODE;
    }
    OSStatus st = SecStaticCodeCreateWithPath(resolvedURL != NULL ? resolvedURL : path, flags, staticCode);
    if (resolvedURL != NULL) {
        CFRelease(resolvedURL);
    }
    return st;
}

static OSStatus pt_SecStaticCodeCreateWithPathAndAttributes(CFURLRef path,
                                                            SecCSFlags flags,
                                                            CFDictionaryRef attributes,
                                                            SecStaticCodeRef *staticCode) {
    const void *caller = __builtin_return_address(0);
    BOOL blocked = NO;
    CFURLRef resolvedURL = pt_resolve_cfbundle_input_url(path, caller, &blocked);
    if (blocked) {
        if (resolvedURL != NULL) {
            CFRelease(resolvedURL);
        }
        if (staticCode != NULL) {
            *staticCode = NULL;
        }
        return PT_ERR_SEC_CS_NO_SUCH_CODE;
    }
    OSStatus st = SecStaticCodeCreateWithPathAndAttributes(
        resolvedURL != NULL ? resolvedURL : path, flags, attributes, staticCode);
    if (resolvedURL != NULL) {
        CFRelease(resolvedURL);
    }
    return st;
}

static OSStatus pt_SecCodeCheckValidityWithErrors_for_caller(SecCodeRef code,
                                                              SecCSFlags flags,
                                                              SecRequirementRef requirement,
                                                              CFErrorRef *errors,
                                                              const void *caller) {
    BOOL app_caller = (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller));
    BOOL in_app_bundle = NO;
    if (app_caller && pt_code_is_hidden(code, caller, &in_app_bundle)) {
        if (errors != NULL) {
            *errors = NULL;
        }
        return PT_ERR_SEC_CS_NO_SUCH_CODE;
    }
    CFErrorRef localErr = NULL;
    OSStatus st = SecCodeCheckValidityWithErrors(code, flags, requirement, errors != NULL ? &localErr : NULL);
    if (st != 0 && app_caller && in_app_bundle && requirement == NULL) {
        if (localErr != NULL) {
            CFRelease(localErr);
        }
        if (errors != NULL) {
            *errors = NULL;
        }
        return 0;
    }
    if (errors != NULL) {
        *errors = localErr;
    } else if (localErr != NULL) {
        CFRelease(localErr);
    }
    return st;
}

static OSStatus pt_SecCodeCheckValidityWithErrors(SecCodeRef code,
                                                  SecCSFlags flags,
                                                  SecRequirementRef requirement,
                                                  CFErrorRef *errors) {
    return pt_SecCodeCheckValidityWithErrors_for_caller(
        code, flags, requirement, errors, __builtin_return_address(0));
}

static OSStatus pt_SecCodeCheckValidity(SecCodeRef code, SecCSFlags flags, SecRequirementRef requirement) {
    return pt_SecCodeCheckValidityWithErrors_for_caller(
        code, flags, requirement, NULL, __builtin_return_address(0));
}

static OSStatus pt_SecStaticCodeCheckValidityWithErrors_for_caller(SecStaticCodeRef staticCode,
                                                                    SecCSFlags flags,
                                                                    SecRequirementRef requirement,
                                                                    CFErrorRef *errors,
                                                                    const void *caller) {
    BOOL app_caller = (pt_is_bypass_enabled() && !pt_is_effective_system_or_playtools_caller(caller));
    BOOL in_app_bundle = NO;
    if (app_caller && pt_static_code_is_hidden(staticCode, caller, &in_app_bundle)) {
        if (errors != NULL) {
            *errors = NULL;
        }
        return PT_ERR_SEC_CS_NO_SUCH_CODE;
    }
    CFErrorRef localErr = NULL;
    OSStatus st = SecStaticCodeCheckValidityWithErrors(
        staticCode, flags, requirement, errors != NULL ? &localErr : NULL);
    if (st != 0 && app_caller && in_app_bundle && requirement == NULL) {
        if (localErr != NULL) {
            CFRelease(localErr);
        }
        if (errors != NULL) {
            *errors = NULL;
        }
        return 0;
    }
    if (errors != NULL) {
        *errors = localErr;
    } else if (localErr != NULL) {
        CFRelease(localErr);
    }
    return st;
}

static OSStatus pt_SecStaticCodeCheckValidityWithErrors(SecStaticCodeRef staticCode,
                                                        SecCSFlags flags,
                                                        SecRequirementRef requirement,
                                                        CFErrorRef *errors) {
    return pt_SecStaticCodeCheckValidityWithErrors_for_caller(
        staticCode, flags, requirement, errors, __builtin_return_address(0));
}

static OSStatus pt_SecStaticCodeCheckValidity(SecStaticCodeRef staticCode,
                                              SecCSFlags flags,
                                              SecRequirementRef requirement) {
    return pt_SecStaticCodeCheckValidityWithErrors_for_caller(
        staticCode, flags, requirement, NULL, __builtin_return_address(0));
}

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
extern int csops_audittoken(pid_t pid, unsigned int ops, void *useraddr, size_t usersize, audit_token_t *token);

#ifndef PT_CS_HASHTYPE_SHA1
#define PT_CS_HASHTYPE_SHA1 1U
#endif

static void pt_sha256_cs_blob(uint32_t host_magic, const uint8_t *payload, size_t payload_len, uint8_t out_hash[CC_SHA256_DIGEST_LENGTH]) {
    size_t full_sz = 8U + payload_len;
    uint32_t hdr[2] = { htonl(host_magic), htonl((uint32_t)full_sz) };
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
static void pt_sha1_cs_blob(uint32_t host_magic, const uint8_t *payload, size_t payload_len, uint8_t out_hash[CC_SHA1_DIGEST_LENGTH]) {
    size_t full_sz = 8U + payload_len;
    uint32_t hdr[2] = { htonl(host_magic), htonl((uint32_t)full_sz) };
    CC_SHA1_CTX ctx;
    CC_SHA1_Init(&ctx);
    CC_SHA1_Update(&ctx, hdr, sizeof(hdr));
    if (payload != NULL && payload_len > 0) {
        CC_SHA1_Update(&ctx, payload, (CC_LONG)payload_len);
    }
    CC_SHA1_Final(out_hash, &ctx);
}
#pragma clang diagnostic pop

static void pt_patch_code_directory_entitlement_hashes(uint8_t *cd_buf,
                                                       size_t cd_len,
                                                       BOOL has_xml,
                                                       const uint8_t xml_hash[CC_SHA256_DIGEST_LENGTH],
                                                       const uint8_t xml_sha1[CC_SHA1_DIGEST_LENGTH],
                                                       BOOL has_der,
                                                       const uint8_t der_hash[CC_SHA256_DIGEST_LENGTH],
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
    if (n_special >= PT_CSSLOT_DER_ENTITLEMENTS && hash_offset >= (uint32_t)PT_CSSLOT_DER_ENTITLEMENTS * (uint32_t)hash_size) {
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

static int pt_handle_spoofed_csops_blob(pid_t pid,
                                        void *useraddr,
                                        size_t usersize,
                                        BOOL use_audittoken,
                                        audit_token_t *token) {
    if (usersize > 0 && useraddr == NULL) {
        errno = EFAULT;
        return -1;
    }
    if (usersize < 8U) {
        errno = ERANGE;
        return -1;
    }
    uint32_t probe[2] = {0, 0};
    errno = 0;
    int pr = use_audittoken
        ? csops_audittoken(pid, PT_CS_OPS_BLOB, probe, sizeof(probe), token)
        : csops(pid, PT_CS_OPS_BLOB, probe, sizeof(probe));
    int probe_errno = errno;
    if (pr < 0 && probe_errno != ERANGE) {
        errno = probe_errno;
        return -1;
    }
    uint32_t raw_magic = ntohl(probe[0]);
    uint32_t raw_len = ntohl(probe[1]);
    if (raw_magic != PT_CSMAGIC_EMBEDDED_SIGNATURE || raw_len < 12U || raw_len > (16U << 20)) {
        return use_audittoken
            ? csops_audittoken(pid, PT_CS_OPS_BLOB, useraddr, usersize, token)
            : csops(pid, PT_CS_OPS_BLOB, useraddr, usersize);
    }
    uint8_t *raw_buf = (uint8_t *)malloc(raw_len);
    if (raw_buf == NULL) {
        errno = ENOMEM;
        return -1;
    }
    int rr = use_audittoken
        ? csops_audittoken(pid, PT_CS_OPS_BLOB, raw_buf, raw_len, token)
        : csops(pid, PT_CS_OPS_BLOB, raw_buf, raw_len);
    if (rr != 0) {
        int saved = errno;
        free(raw_buf);
        errno = saved;
        return -1;
    }
    uint32_t slot_count = 0;
    memcpy(&slot_count, raw_buf + 8U, sizeof(slot_count));
    slot_count = ntohl(slot_count);
    if (slot_count == 0 || slot_count > 256U || (size_t)slot_count * 8U > (size_t)(raw_len - 12U)) {
        free(raw_buf);
        return use_audittoken
            ? csops_audittoken(pid, PT_CS_OPS_BLOB, useraddr, usersize, token)
            : csops(pid, PT_CS_OPS_BLOB, useraddr, usersize);
    }

    BOOL compat13 = pt_is_compat13_7_active();
    NSData *xmlData = pt_get_synthesized_entitlements_xml_data();
    NSData *derData = compat13 ? nil : pt_get_synthesized_entitlements_der_data();
    typedef struct {
        uint32_t type;
        uint32_t magic_override;
        uint8_t *mutable_bytes;
        const uint8_t *bytes;
        size_t len;
    } pt_sb_slot_t;

    pt_sb_slot_t *slots = (pt_sb_slot_t *)calloc((size_t)slot_count + 2U, sizeof(pt_sb_slot_t));
    if (slots == NULL) {
        free(raw_buf);
        errno = ENOMEM;
        return -1;
    }
    uint32_t out_count = 0;
    size_t payload_total = 0;
    BOOL saw_xml_slot = NO;
    BOOL saw_der_slot = NO;
    for (uint32_t i = 0; i < slot_count; i++) {
        uint32_t stype = 0, soff = 0;
        memcpy(&stype, raw_buf + 12U + i * 8U, sizeof(stype));
        memcpy(&soff, raw_buf + 16U + i * 8U, sizeof(soff));
        stype = ntohl(stype);
        soff = ntohl(soff);
        if (soff < 12U + slot_count * 8U || soff + 8U > raw_len) {
            continue;
        }
        uint32_t clen = 0;
        memcpy(&clen, raw_buf + soff + 4U, sizeof(clen));
        clen = ntohl(clen);
        if (clen < 8U || clen > raw_len - soff) {
            continue;
        }
        if (stype == PT_CSSLOT_ENTITLEMENTS) {
            saw_xml_slot = YES;
            if (xmlData == nil || xmlData.length == 0) {
                continue;
            }
            slots[out_count] = (pt_sb_slot_t){
                .type = stype,
                .magic_override = PT_CSMAGIC_EMBEDDED_ENTITLEMENTS,
                .mutable_bytes = NULL,
                .bytes = (const uint8_t *)xmlData.bytes,
                .len = xmlData.length,
            };
            payload_total += 8U + xmlData.length;
            out_count++;
        } else if (stype == PT_CSSLOT_DER_ENTITLEMENTS) {
            saw_der_slot = YES;
            if (compat13 || derData == nil || derData.length == 0) {
                continue;
            }
            slots[out_count] = (pt_sb_slot_t){
                .type = stype,
                .magic_override = PT_CSMAGIC_EMBEDDED_DER_ENTITLEMENTS,
                .mutable_bytes = NULL,
                .bytes = (const uint8_t *)derData.bytes,
                .len = derData.length,
            };
            payload_total += 8U + derData.length;
            out_count++;
        } else {
            slots[out_count] = (pt_sb_slot_t){
                .type = stype,
                .magic_override = 0U,
                .mutable_bytes = raw_buf + soff,
                .bytes = raw_buf + soff,
                .len = (size_t)clen,
            };
            payload_total += (size_t)clen;
            out_count++;
        }
    }
    if (!saw_xml_slot && xmlData != nil && xmlData.length > 0) {
        slots[out_count] = (pt_sb_slot_t){
            .type = PT_CSSLOT_ENTITLEMENTS,
            .magic_override = PT_CSMAGIC_EMBEDDED_ENTITLEMENTS,
            .mutable_bytes = NULL,
            .bytes = (const uint8_t *)xmlData.bytes,
            .len = xmlData.length,
        };
        payload_total += 8U + xmlData.length;
        out_count++;
    }
    if (!saw_der_slot && !compat13 && derData != nil && derData.length > 0) {
        slots[out_count] = (pt_sb_slot_t){
            .type = PT_CSSLOT_DER_ENTITLEMENTS,
            .magic_override = PT_CSMAGIC_EMBEDDED_DER_ENTITLEMENTS,
            .mutable_bytes = NULL,
            .bytes = (const uint8_t *)derData.bytes,
            .len = derData.length,
        };
        payload_total += 8U + derData.length;
        out_count++;
    }

    uint8_t xml_hash[CC_SHA256_DIGEST_LENGTH] = {0};
    uint8_t der_hash[CC_SHA256_DIGEST_LENGTH] = {0};
    uint8_t xml_sha1[CC_SHA1_DIGEST_LENGTH] = {0};
    uint8_t der_sha1[CC_SHA1_DIGEST_LENGTH] = {0};
    BOOL has_xml = (xmlData != nil && xmlData.length > 0);
    BOOL has_der = (!compat13 && derData != nil && derData.length > 0);
    if (has_xml) {
        pt_sha256_cs_blob(PT_CSMAGIC_EMBEDDED_ENTITLEMENTS, (const uint8_t *)xmlData.bytes, xmlData.length, xml_hash);
        pt_sha1_cs_blob(PT_CSMAGIC_EMBEDDED_ENTITLEMENTS, (const uint8_t *)xmlData.bytes, xmlData.length, xml_sha1);
    }
    if (has_der) {
        pt_sha256_cs_blob(PT_CSMAGIC_EMBEDDED_DER_ENTITLEMENTS, (const uint8_t *)derData.bytes, derData.length, der_hash);
        pt_sha1_cs_blob(PT_CSMAGIC_EMBEDDED_DER_ENTITLEMENTS, (const uint8_t *)derData.bytes, derData.length, der_sha1);
    }
    for (uint32_t i = 0; i < out_count; i++) {
        uint32_t stype = slots[i].type;
        if (slots[i].mutable_bytes != NULL &&
            (stype == PT_CSSLOT_CODEDIRECTORY ||
             (stype >= PT_CSSLOT_ALTERNATE_CODEDIRECTORIES &&
              stype < PT_CSSLOT_ALTERNATE_CODEDIRECTORIES + PT_CSSLOT_ALTERNATE_CODEDIRECTORY_MAX))) {
            pt_patch_code_directory_entitlement_hashes(
                slots[i].mutable_bytes, slots[i].len, has_xml, xml_hash, xml_sha1, has_der, der_hash, der_sha1);
        }
    }

    size_t header_len = 12U + (size_t)out_count * 8U;
    if (payload_total > (size_t)UINT32_MAX - header_len) {
        free(slots);
        free(raw_buf);
        errno = EOVERFLOW;
        return -1;
    }
    size_t out_total = header_len + payload_total;
    if (usersize < 8U) {
        free(slots);
        free(raw_buf);
        errno = ERANGE;
        return -1;
    }
    uint32_t out_hdr[2] = { htonl(PT_CSMAGIC_EMBEDDED_SIGNATURE), htonl((uint32_t)out_total) };
    memcpy(useraddr, out_hdr, sizeof(out_hdr));
    if (usersize < out_total) {
        free(slots);
        free(raw_buf);
        errno = ERANGE;
        return -1;
    }
    uint8_t *dst = (uint8_t *)useraddr;
    uint32_t be_count = htonl(out_count);
    memcpy(dst + 8U, &be_count, sizeof(be_count));
    size_t cur_off = header_len;
    for (uint32_t i = 0; i < out_count; i++) {
        uint32_t idx_pair[2] = { htonl(slots[i].type), htonl((uint32_t)cur_off) };
        memcpy(dst + 12U + i * 8U, idx_pair, sizeof(idx_pair));
        if (slots[i].magic_override != 0U) {
            size_t full_sz = 8U + slots[i].len;
            uint32_t chdr[2] = { htonl(slots[i].magic_override), htonl((uint32_t)full_sz) };
            memcpy(dst + cur_off, chdr, sizeof(chdr));
            memcpy(dst + cur_off + 8U, slots[i].bytes, slots[i].len);
            cur_off += full_sz;
        } else {
            memcpy(dst + cur_off, slots[i].bytes, slots[i].len);
            cur_off += slots[i].len;
        }
    }
    free(slots);
    free(raw_buf);
    return 0;
}

static int pt_handle_spoofed_csops_query(pid_t pid,
                                         unsigned int ops,
                                         void *useraddr,
                                         size_t usersize,
                                         BOOL use_audittoken,
                                         audit_token_t *token) {
    if (ops == PT_CS_OPS_ENTITLEMENTS_BLOB) {
        NSData *xmlData = pt_get_synthesized_entitlements_xml_data();
        if (xmlData != nil && xmlData.length > 0) {
            return pt_csops_write_blob_or_erange(PT_CSMAGIC_EMBEDDED_ENTITLEMENTS,
                                                 xmlData.bytes,
                                                 xmlData.length,
                                                 useraddr,
                                                 usersize);
        }
        errno = ENOENT;
        return -1;
    }
    if (ops == PT_CS_OPS_DER_ENTITLEMENTS_BLOB) {
        if (pt_is_compat13_7_active()) {
            errno = ENOENT;
            return -1;
        }
        NSData *derData = pt_get_synthesized_entitlements_der_data();
        if (derData != nil && derData.length > 0) {
            return pt_csops_write_blob_or_erange(PT_CSMAGIC_EMBEDDED_DER_ENTITLEMENTS,
                                                 derData.bytes,
                                                 derData.length,
                                                 useraddr,
                                                 usersize);
        }
        errno = ENOENT;
        return -1;
    }
    if (ops == PT_CS_OPS_BLOB) {
        return pt_handle_spoofed_csops_blob(pid, useraddr, usersize, use_audittoken, token);
    }
    if (ops == PT_CS_OPS_TEAMID) {
        const char *team = pt_get_effective_team_id_cstr();
        size_t tlen = (team != NULL) ? strlen(team) : 0;
        if (tlen > 0) {
            return pt_csops_write_blob_or_erange(0U, team, tlen + 1U, useraddr, usersize);
        }
        errno = ENOENT;
        return -1;
    }
    if (ops == PT_CS_OPS_IDENTITY) {
        char bid[256];
        pt_get_effective_bundle_id_cstr(bid, sizeof(bid));
        size_t blen = strlen(bid);
        if (blen > 0) {
            return pt_csops_write_blob_or_erange(0U, bid, blen + 1U, useraddr, usersize);
        }
        errno = ENOENT;
        return -1;
    }
    return -2;
}

__attribute__((visibility("hidden")))
int pt_csops_with_caller(pid_t pid, unsigned int ops, void *useraddr, size_t usersize, const void *caller) {
    if (!atomic_load_explicit(&s_libsystem_ready, memory_order_acquire)) {
        return csops(pid, ops, useraddr, usersize);
    }
    if (pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller) &&
        (pid == 0 || pid == getpid())) {
        int handled = pt_handle_spoofed_csops_query(pid, ops, useraddr, usersize, NO, NULL);
        if (handled != -2) {
            return handled;
        }
        int ret = csops(pid, ops, useraddr, usersize);
        if (ret == 0 && ops == PT_CS_OPS_STATUS && useraddr != NULL && usersize >= sizeof(uint32_t)) {
            uint32_t *flags = (uint32_t *)useraddr;
            *flags &= ~(PT_CS_ADHOC | PT_CS_GET_TASK_ALLOW);
            *flags |= PT_CS_VALID;
            PT_DEBUG_TRACE("entitlements", "spoofed csops status pid=%d flags=0x%x", pid, *flags);
        }
        return ret;
    }
    return csops(pid, ops, useraddr, usersize);
}

static int pt_csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize) {
    return pt_csops_with_caller(pid, ops, useraddr, usersize, __builtin_return_address(0));
}

__attribute__((visibility("hidden")))
int pt_csops_audittoken_with_caller(pid_t pid,
                                    unsigned int ops,
                                    void *useraddr,
                                    size_t usersize,
                                    audit_token_t *token,
                                    const void *caller) {
    if (atomic_load_explicit(&s_libsystem_ready, memory_order_acquire) &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller) &&
        (pid == 0 || pid == getpid())) {
        int handled = pt_handle_spoofed_csops_query(pid, ops, useraddr, usersize, YES, token);
        if (handled != -2) {
            return handled;
        }
        int ret = csops_audittoken(pid, ops, useraddr, usersize, token);
        if (ret == 0 && ops == PT_CS_OPS_STATUS && useraddr != NULL && usersize >= sizeof(uint32_t)) {
            uint32_t *flags = (uint32_t *)useraddr;
            *flags &= ~(PT_CS_ADHOC | PT_CS_GET_TASK_ALLOW);
            *flags |= PT_CS_VALID;
        }
        return ret;
    }
    return csops_audittoken(pid, ops, useraddr, usersize, token);
}

static int pt_csops_audittoken(pid_t pid, unsigned int ops, void *useraddr, size_t usersize, audit_token_t *token) {
    return pt_csops_audittoken_with_caller(pid, ops, useraddr, usersize, token, __builtin_return_address(0));
}

extern int ptrace(int request, pid_t pid, caddr_t addr, int data);
#ifndef PT_DENY_ATTACH
#define PT_DENY_ATTACH 31
#endif
__attribute__((visibility("hidden")))
int pt_ptrace_with_caller(int request, pid_t pid, caddr_t addr, int data, const void *caller) {
    (void)caller;
    if (request == PT_DENY_ATTACH && pt_is_bypass_enabled()) {
        PT_DEBUG_TRACE("entitlements", "bypassed ptrace PT_DENY_ATTACH pid=%d", pid);
        return 0;
    }
    return ptrace(request, pid, addr, data);
}

static int pt_ptrace(int request, pid_t pid, caddr_t addr, int data) {
    return pt_ptrace_with_caller(request, pid, addr, data, __builtin_return_address(0));
}


// Interpose Apple Keychain functions (SecItemCopyMatching, SecItemAdd, SecItemUpdate, SecItemDelete)
// This allows us to intercept keychain requests and return our own data

static inline BOOL pt_is_playchain_enabled(void) {
    int cached = atomic_load_explicit(&s_playchain_cached, memory_order_acquire);
    if (cached >= 0) {
        return cached != 0;
    }
    BOOL v = NO;
    if (atomic_load_explicit(&s_pt_loaded, memory_order_acquire)) {
        v = [[PlaySettings shared] playChain];
        atomic_store_explicit(&s_playchain_cached, v ? 1 : 0, memory_order_release);
    }
    return v;
}

static inline BOOL pt_is_playchain_debug_enabled(void) {
    int cached = atomic_load_explicit(&s_playchain_debug_cached, memory_order_acquire);
    if (cached >= 0) {
        return cached != 0;
    }
    BOOL v = NO;
    if (atomic_load_explicit(&s_pt_loaded, memory_order_acquire)) {
        v = [[PlaySettings shared] playChainDebugging];
        atomic_store_explicit(&s_playchain_debug_cached, v ? 1 : 0, memory_order_release);
    }
    return v;
}

static void pt_merge_entitlement_values(NSMutableDictionary *merged, NSString *key, id value) {
    if (merged == nil || key.length == 0 || value == nil) {
        return;
    }
    NSMutableArray<NSString *> *combined = [NSMutableArray array];
    id existing = merged[key];
    if ([existing isKindOfClass:[NSString class]]) {
        NSString *str = (NSString *)existing;
        if (str.length > 0) {
            [combined addObject:str];
        }
    } else if ([existing isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)existing) {
            if ([item isKindOfClass:[NSString class]] &&
                [(NSString *)item length] > 0 &&
                ![combined containsObject:item]) {
                [combined addObject:item];
            }
        }
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *str = (NSString *)value;
        if (str.length > 0 && ![combined containsObject:str]) {
            [combined addObject:str];
        }
    } else if ([value isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)value) {
            if ([item isKindOfClass:[NSString class]] &&
                [(NSString *)item length] > 0 &&
                ![combined containsObject:item]) {
                [combined addObject:item];
            }
        }
    }
    if (combined.count > 0) {
        merged[key] = [combined copy];
    }
}

static void pt_merge_application_identifier(NSMutableDictionary *merged, id appIdValue) {
    if (merged == nil || ![appIdValue isKindOfClass:[NSString class]]) {
        return;
    }
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *appId = [(NSString *)appIdValue stringByTrimmingCharactersInSet:ws];
    if (appId.length == 0 || [appId isEqualToString:@"FAKETEAMID."]) {
        return;
    }
    if (merged[@"application-identifier"] == nil) {
        merged[@"application-identifier"] = appId;
    }
    pt_merge_entitlement_values(merged, @"keychain-access-groups", appId);
}

static NSArray<NSString *> *pt_get_allowed_keychain_access_groups(void) {
    static NSArray<NSString *> *s_allowed_groups = nil;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        NSMutableDictionary *merged = [NSMutableDictionary dictionary];
        NSDictionary *synth = pt_get_synthesized_app_entitlements_dict();
        if (synth != nil) {
            [merged addEntriesFromDictionary:synth];
        }
        NSDictionary *fb = pt_get_fallback_entitlements_dict();
        if (fb != nil) {
            pt_merge_application_identifier(merged, fb[@"application-identifier"]);
            pt_merge_entitlement_values(merged, @"com.apple.security.application-groups", fb[@"com.apple.security.application-groups"]);
        }
        SecCodeRef selfCode = NULL;
        if (SecCodeCopySelf(0, &selfCode) == 0 && selfCode != NULL) {
            CFDictionaryRef info = NULL;
            // kSecCSSigningInformation == 2
            if (SecCodeCopySigningInformation(selfCode, 2, &info) == 0 && info != NULL) {
                NSDictionary *infoDict = (__bridge NSDictionary *)info;
                NSDictionary *liveEnt = infoDict[@"entitlements-dict"];
                if ([liveEnt isKindOfClass:[NSDictionary class]]) {
                    pt_merge_entitlement_values(merged, @"keychain-access-groups", liveEnt[@"keychain-access-groups"]);
                    pt_merge_entitlement_values(merged,
                                                @"com.apple.security.application-groups",
                                                liveEnt[@"com.apple.security.application-groups"]);
                    pt_merge_application_identifier(merged, liveEnt[@"application-identifier"]);
                }
            }
            if (info != NULL) {
                CFRelease(info);
            }
        }
        if (selfCode != NULL) {
            CFRelease(selfCode);
        }
        SecTaskRef selfTask = SecTaskCreateFromSelf(kCFAllocatorDefault);
        if (selfTask != NULL) {
            CFTypeRef taskGroups = SecTaskCopyValueForEntitlement(selfTask, CFSTR("keychain-access-groups"), NULL);
            if (taskGroups != NULL) {
                pt_merge_entitlement_values(merged, @"keychain-access-groups", (__bridge id)taskGroups);
                CFRelease(taskGroups);
            }
            CFTypeRef taskAppGroups = SecTaskCopyValueForEntitlement(
                selfTask, CFSTR("com.apple.security.application-groups"), NULL);
            if (taskAppGroups != NULL) {
                pt_merge_entitlement_values(merged,
                                            @"com.apple.security.application-groups",
                                            (__bridge id)taskAppGroups);
                CFRelease(taskAppGroups);
            }
            CFTypeRef taskAppId = SecTaskCopyValueForEntitlement(selfTask, CFSTR("application-identifier"), NULL);
            if (taskAppId != NULL) {
                if (CFGetTypeID(taskAppId) == CFStringGetTypeID()) {
                    pt_merge_application_identifier(merged, (__bridge id)taskAppId);
                }
                CFRelease(taskAppId);
            }
            CFRelease(selfTask);
        }
        const char *team = pt_get_effective_team_id_cstr();
        char bid[256];
        pt_get_effective_bundle_id_cstr(bid, sizeof(bid));
        NSString *teamStr = (team != NULL) ? ([NSString stringWithUTF8String:team] ?: @"") : @"";
        NSString *bidStr = [NSString stringWithUTF8String:bid] ?: @"";
        s_allowed_groups = [PTPlayChainPolicyBridge expandAccessGroupPatternsFromEntitlements:merged
                                                                                       teamID:teamStr
                                                                                     bundleID:bidStr];
    });
    return s_allowed_groups ?: @[];
}

static OSStatus pt_validate_dict_access_group(CFDictionaryRef dictRef, BOOL isReadOnlyQuery) {
    if (dictRef == NULL) {
        return errSecSuccess;
    }
    NSDictionary *dict = (__bridge NSDictionary *)dictRef;
    id requested = dict[(__bridge NSString *)kSecAttrAccessGroup];
    if (requested == nil) {
        return errSecSuccess;
    }
    NSArray<NSString *> *allowed = pt_get_allowed_keychain_access_groups();
    return [PTPlayChainPolicyBridge validateAccessGroup:requested
                                        allowedPatterns:allowed
                                        isReadOnlyQuery:isReadOnlyQuery];
}

static OSStatus pt_validate_key_params_access_groups(CFDictionaryRef parametersRef) {
    if (parametersRef == NULL) {
        return errSecSuccess;
    }
    OSStatus st = pt_validate_dict_access_group(parametersRef, NO);
    if (st != errSecSuccess) {
        return st;
    }
    NSDictionary *params = (__bridge NSDictionary *)parametersRef;
    id privAttrs = params[(__bridge NSString *)kSecPrivateKeyAttrs];
    if ([privAttrs isKindOfClass:[NSDictionary class]]) {
        st = pt_validate_dict_access_group((__bridge CFDictionaryRef)privAttrs, NO);
        if (st != errSecSuccess) {
            return st;
        }
    }
    id pubAttrs = params[(__bridge NSString *)kSecPublicKeyAttrs];
    if ([pubAttrs isKindOfClass:[NSDictionary class]]) {
        st = pt_validate_dict_access_group((__bridge CFDictionaryRef)pubAttrs, NO);
        if (st != errSecSuccess) {
            return st;
        }
    }
    return errSecSuccess;
}

// Use the implementations from PlayKeychain
static OSStatus pt_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    const void *caller = __builtin_return_address(0);
    OSStatus retval;
    if (result != NULL) {
        *result = NULL;
    }
    if (pt_is_playchain_enabled()) {
        if (query == NULL) {
            return errSecParam;
        }
        if (!pt_is_effective_system_or_playtools_caller(caller)) {
            OSStatus agrpStatus = pt_validate_dict_access_group(query, YES);
            if (agrpStatus != errSecSuccess) {
                return agrpStatus;
            }
        }
        retval = [PlayKeychain copyMatching:(__bridge NSDictionary * _Nonnull)(query) result:result];
        if (retval == errSecItemNotFound) {
            CFTypeRef secClass = CFDictionaryGetValue(query, kSecClass);
            if ((secClass != NULL && CFEqual(secClass, kSecClassCertificate)) ||
                CFDictionaryContainsKey(query, kSecMatchPolicy) ||
                CFDictionaryContainsKey(query, kSecMatchTrustedOnly)) {
                if (result != NULL) {
                    *result = NULL;
                }
                retval = SecItemCopyMatching(query, result);
            }
        }
    } else {
        retval = SecItemCopyMatching(query, result);
    }
    if (result != NULL && retval == errSecSuccess && pt_is_playchain_debug_enabled()) {
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemCopyMatching: %@", query]];
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemCopyMatching result: %@", (result && *result) ? (__bridge id)(*result) : @"(null)"]];
    }
    return retval;
}

static OSStatus pt_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    const void *caller = __builtin_return_address(0);
    OSStatus retval;
    if (result != NULL) {
        *result = NULL;
    }
    if (pt_is_playchain_enabled()) {
        if (attributes == NULL) {
            return errSecParam;
        }
        if (!pt_is_effective_system_or_playtools_caller(caller)) {
            OSStatus agrpStatus = pt_validate_dict_access_group(attributes, NO);
            if (agrpStatus != errSecSuccess) {
                return agrpStatus;
            }
        }
        retval = [PlayKeychain add:(__bridge NSDictionary * _Nonnull)(attributes) result:result];
    } else {
        retval = SecItemAdd(attributes, result);
    }
    if (result != NULL && retval == errSecSuccess && pt_is_playchain_debug_enabled()) {
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemAdd: %@", attributes]];
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemAdd result: %@", (result && *result) ? (__bridge id)(*result) : @"(null)"]];
    }
    return retval;
}

static OSStatus pt_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    const void *caller = __builtin_return_address(0);
    OSStatus retval;
    if (pt_is_playchain_enabled()) {
        if (query == NULL || attributesToUpdate == NULL) {
            return errSecParam;
        }
        if (!pt_is_effective_system_or_playtools_caller(caller)) {
            OSStatus agrpStatus = pt_validate_dict_access_group(query, NO);
            if (agrpStatus != errSecSuccess) {
                return agrpStatus;
            }
            agrpStatus = pt_validate_dict_access_group(attributesToUpdate, NO);
            if (agrpStatus != errSecSuccess) {
                return agrpStatus;
            }
        }
        retval = [PlayKeychain update:(__bridge NSDictionary * _Nonnull)(query) attributesToUpdate:(__bridge NSDictionary * _Nonnull)(attributesToUpdate)];
    } else {
        retval = SecItemUpdate(query, attributesToUpdate);
    }
    if (attributesToUpdate != NULL && pt_is_playchain_debug_enabled()) {
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemUpdate: %@", query]];
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemUpdate attributesToUpdate: %@", attributesToUpdate]];
    }
    return retval;
}

static OSStatus pt_SecItemDelete(CFDictionaryRef query) {
    const void *caller = __builtin_return_address(0);
    OSStatus retval;
    if (pt_is_playchain_enabled()) {
        if (query == NULL) {
            return errSecParam;
        }
        if (!pt_is_effective_system_or_playtools_caller(caller)) {
            OSStatus agrpStatus = pt_validate_dict_access_group(query, NO);
            if (agrpStatus != errSecSuccess) {
                return agrpStatus;
            }
        }
        retval = [PlayKeychain delete:(__bridge NSDictionary * _Nonnull)(query)];
    } else {
        retval = SecItemDelete(query);
    }
    if (pt_is_playchain_debug_enabled()) {
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecItemDelete: %@", query]];
    }
    return retval;
}

static SecKeyRef pt_SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    const void *caller = __builtin_return_address(0);
    SecKeyRef result;
    if (error != NULL) {
        *error = NULL;
    }
    if (pt_is_playchain_enabled()) {
        if (parameters == NULL) {
            if (error != NULL) {
                *error = CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainOSStatus, errSecParam, NULL);
            }
            return NULL;
        }
        if (!pt_is_effective_system_or_playtools_caller(caller)) {
            OSStatus agrpStatus = pt_validate_key_params_access_groups(parameters);
            if (agrpStatus != errSecSuccess) {
                if (error != NULL) {
                    *error = CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainOSStatus, agrpStatus, NULL);
                }
                return NULL;
            }
        }
        result = [PlayKeychain keyCreateRandomKey:(__bridge NSDictionary * _Nonnull)(parameters) error:error];
    } else {
        result = SecKeyCreateRandomKey(parameters, (void *)error);
    }
    if (pt_is_playchain_debug_enabled()) {
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecKeyCreateRandomKey: %@", parameters]];
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecKeyCreateRandomKey result: %@", result]];
    }
    return result;
}

static CFDataRef pt_SecKeyCopyExternalRepresentation(SecKeyRef key, CFErrorRef *error) {
    if (error != NULL) {
        *error = NULL;
    }
    if (key == NULL) {
        if (error != NULL) {
            *error = CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainOSStatus, errSecParam, NULL);
        }
        return NULL;
    }
    const void *caller = __builtin_return_address(0);
    if (pt_is_playchain_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller) &&
        [PTPlayChainSecureEnclaveRegistry isSecureEnclaveKey:key]) {
        if (error != NULL) {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: @"Secure Enclave private keys cannot be exported."
            };
            *error = CFErrorCreate(kCFAllocatorDefault,
                                   kCFErrorDomainOSStatus,
                                   errSecUnimplemented,
                                   (__bridge CFDictionaryRef)userInfo);
        }
        if (pt_is_playchain_debug_enabled()) {
            [PlayKeychain debugLogger:@"Blocked SecKeyCopyExternalRepresentation on simulated Secure Enclave key"];
        }
        return NULL;
    }
    return SecKeyCopyExternalRepresentation(key, error);
}

static CFDictionaryRef pt_SecKeyCopyAttributes(SecKeyRef key) {
    if (key == NULL) {
        return NULL;
    }
    CFDictionaryRef attrs = SecKeyCopyAttributes(key);
    if (attrs == NULL) {
        return NULL;
    }
    const void *caller = __builtin_return_address(0);
    if (pt_is_playchain_enabled() &&
        !pt_is_effective_system_or_playtools_caller(caller) &&
        [PTPlayChainSecureEnclaveRegistry isSecureEnclaveKey:key]) {
        NSDictionary *dict = (__bridge NSDictionary *)attrs;
        if ([dict isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *sanitized = [dict mutableCopy];
            [sanitized removeObjectForKey:(__bridge id)kSecValueData];
            sanitized[(__bridge id)kSecAttrTokenID] = (__bridge id)kSecAttrTokenIDSecureEnclave;
            CFRelease(attrs);
            return (__bridge_retained CFDictionaryRef)[sanitized copy];
        }
    }
    return attrs;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
// Deprecated, but some apps might still use it.
static OSStatus pt_SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    const void *caller = __builtin_return_address(0);
    OSStatus retval;
    if (pt_is_playchain_enabled()) {
        if (parameters == NULL) {
            return errSecParam;
        }
        if (!pt_is_effective_system_or_playtools_caller(caller)) {
            OSStatus agrpStatus = pt_validate_key_params_access_groups(parameters);
            if (agrpStatus != errSecSuccess) {
                return agrpStatus;
            }
        }
        retval = [PlayKeychain keyGeneratePair:(__bridge NSDictionary * _Nonnull)(parameters) publicKey:(void *)publicKey privateKey:(void *)privateKey];
    } else {
        retval = SecKeyGeneratePair(parameters, (void *)publicKey, (void *)privateKey);
    }
    if (pt_is_playchain_debug_enabled()) {
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecKeyGeneratePair: %@", parameters]];
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecKeyGeneratePair public key result: %@", (retval == errSecSuccess && publicKey != NULL) ? *publicKey : nil]];
        [PlayKeychain debugLogger:[NSString stringWithFormat:@"SecKeyGeneratePair private key result: %@", (retval == errSecSuccess && privateKey != NULL) ? *privateKey : nil]];
    }
    return retval;
}

DYLD_INTERPOSE(pt_SecItemCopyMatching, SecItemCopyMatching)
DYLD_INTERPOSE(pt_SecItemAdd, SecItemAdd)
DYLD_INTERPOSE(pt_SecItemUpdate, SecItemUpdate)
DYLD_INTERPOSE(pt_SecItemDelete, SecItemDelete)
DYLD_INTERPOSE(pt_SecKeyCreateRandomKey, SecKeyCreateRandomKey)
DYLD_INTERPOSE(pt_SecKeyCopyExternalRepresentation, SecKeyCopyExternalRepresentation)
DYLD_INTERPOSE(pt_SecKeyCopyAttributes, SecKeyCopyAttributes)
DYLD_INTERPOSE(pt_SecKeyGeneratePair, SecKeyGeneratePair)
#pragma clang diagnostic pop


extern char *sandbox_extension_issue_file(const char *extension_class, const char *path, uint32_t flags);
extern char *sandbox_extension_issue_file_to_self(const char *extension_class, const char *path, uint32_t flags);
extern char *sandbox_extension_issue_file_to_process(const char *extension_class, const char *path, uint32_t flags, audit_token_t token);
extern char *sandbox_extension_issue_file_to_process_by_pid(const char *extension_class, const char *path, uint32_t flags, pid_t pid);

static char *pt_sandbox_extension_issue_file(const char *extension_class, const char *path, uint32_t flags) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EPERM)) {
        return NULL;
    }
    return sandbox_extension_issue_file(extension_class, path, flags);
}

static char *pt_sandbox_extension_issue_file_to_self(const char *extension_class, const char *path, uint32_t flags) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EPERM)) {
        return NULL;
    }
    return sandbox_extension_issue_file_to_self(extension_class, path, flags);
}

static char *pt_sandbox_extension_issue_file_to_process(const char *extension_class, const char *path, uint32_t flags, audit_token_t token) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EPERM)) {
        return NULL;
    }
    return sandbox_extension_issue_file_to_process(extension_class, path, flags, token);
}

static char *pt_sandbox_extension_issue_file_to_process_by_pid(const char *extension_class, const char *path, uint32_t flags, pid_t pid) {
    char vbuf[PATH_MAX];
    if (!pt_prepare_fs_path_for_modify(AT_FDCWD, path, __builtin_return_address(0), vbuf, sizeof(vbuf), &path, EPERM)) {
        return NULL;
    }
    return sandbox_extension_issue_file_to_process_by_pid(extension_class, path, flags, pid);
}

#ifndef SANDBOX_FILTER_NONE
#define PT_SANDBOX_FILTER_NONE 0
#else
#define PT_SANDBOX_FILTER_NONE SANDBOX_FILTER_NONE
#endif
#ifndef SANDBOX_FILTER_PATH
#define PT_SANDBOX_FILTER_PATH 1
#else
#define PT_SANDBOX_FILTER_PATH SANDBOX_FILTER_PATH
#endif
#ifndef SANDBOX_FILTER_DESCRIPTOR
#define PT_SANDBOX_FILTER_DESCRIPTOR 10
#else
#define PT_SANDBOX_FILTER_DESCRIPTOR SANDBOX_FILTER_DESCRIPTOR
#endif

static int pt_sandbox_check_impl(BOOL use_audit_token,
                                 pid_t pid,
                                 audit_token_t au,
                                 const char *operation,
                                 int type,
                                 va_list ap,
                                 const void *caller) {
    int filter = (type & 0x0f);
    BOOL bypass = pt_is_bypass_enabled();
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);

    if (!is_sys && bypass && !use_audit_token && pid != 0 && pid != getpid()) {
        errno = EPERM;
        return -1;
    }

    if (filter == PT_SANDBOX_FILTER_NONE) {
        int ret = use_audit_token ? sandbox_check_by_audit_token(au, operation, type)
                                  : sandbox_check(pid, operation, type);
        if (!is_sys && bypass && ret == 0 &&
            (operation == NULL || strncmp(operation, "process-fork", 12) == 0)) {
            return 1;
        }
        return ret;
    }

    if (filter == PT_SANDBOX_FILTER_PATH) {
        const char *path = va_arg(ap, const char *);
        char vbuf[PATH_MAX];
        const char *resolved = path;
        int is_sys_flag = is_sys ? 1 : 0;
        pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(
            path, caller, vbuf, sizeof(vbuf), &resolved, &is_sys_flag);
        if (!is_sys && bypass && (disp == PT_FS_PATH_HIDDEN || disp == PT_FS_PATH_VIRTUAL_ANCESTOR)) {
            return 1;
        }
        return use_audit_token ? sandbox_check_by_audit_token(au, operation, type, resolved)
                               : sandbox_check(pid, operation, type, resolved);
    }

    if (filter == PT_SANDBOX_FILTER_DESCRIPTOR) {
        int fd = va_arg(ap, int);
        if (!is_sys && pt_fd_is_sensitive(fd, caller)) {
            return 1;
        }
        return use_audit_token ? sandbox_check_by_audit_token(au, operation, type, fd)
                               : sandbox_check(pid, operation, type, fd);
    }

    uintptr_t arg1 = va_arg(ap, uintptr_t);
    if (!is_sys && bypass && arg1 != 0 &&
        (filter == 2 || filter == 3 || filter == 6 || filter == 9 || filter == 12)) {
        const char *sarg = (const char *)arg1;
        if (strcasestr(sarg, "playcover") != NULL ||
            strcasestr(sarg, "macover") != NULL ||
            strcasestr(sarg, "app.makedie") != NULL ||
            strcasestr(sarg, "playtools") != NULL ||
            strcasestr(sarg, "akinterface") != NULL) {
            return 1;
        }
        if (filter == 2 && pt_is_hidden_macos_mach_service(sarg)) {
            return 1;
        }
    }
    return use_audit_token ? sandbox_check_by_audit_token(au, operation, type, arg1)
                           : sandbox_check(pid, operation, type, arg1);
}

__attribute__((visibility("hidden")))
BOOL pt_is_hidden_macos_mach_service(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return NO;
    }
    if (strcmp(name, "com.apple.dock.server") == 0 ||
        strncmp(name, "com.apple.dock.", 15) == 0 ||
        strncmp(name, "com.apple.windowserver.", 23) == 0 ||
        strncmp(name, "com.apple.finder.", 17) == 0 ||
        strcmp(name, "com.apple.Finder") == 0 ||
        strncmp(name, "com.apple.coreservices.launchservicesd", 38) == 0 ||
        strncmp(name, "com.apple.coreservices.appleevents", 34) == 0 ||
        strncmp(name, "com.apple.coreservices.quarantine-resolver", 42) == 0 ||
        strncmp(name, "com.apple.coreservices.sharedfilelistd", 38) == 0 ||
        strncmp(name, "com.apple.loginwindow", 21) == 0 ||
        strncmp(name, "com.apple.systemuiserver", 24) == 0 ||
        strcmp(name, "com.apple.pasteboard.1") == 0 ||
        strcmp(name, "com.apple.CoreDisplay.master") == 0 ||
        strncmp(name, "com.apple.SkyLight.", 19) == 0 ||
        strncmp(name, "com.apple.ControlCenter", 23) == 0 ||
        strncmp(name, "com.apple.tsm.uiserver", 22) == 0 ||
        strcmp(name, "com.apple.DesktopServicesHelper") == 0 ||
        strncmp(name, "com.apple.endpointsecurity.", 27) == 0) {
        return YES;
    }
    if (strcasestr(name, "playcover") != NULL ||
        strcasestr(name, "macover") != NULL ||
        strcasestr(name, "app.makedie") != NULL ||
        strcasestr(name, "playtools") != NULL ||
        strcasestr(name, "akinterface") != NULL) {
        return YES;
    }
    return NO;
}

static int pt_sandbox_check(pid_t pid, const char *operation, int type, ...) {
    audit_token_t zero_au = {0};
    va_list ap;
    va_start(ap, type);
    int ret = pt_sandbox_check_impl(NO, pid, zero_au, operation, type, ap, __builtin_return_address(0));
    va_end(ap);
    return ret;
}

static int pt_sandbox_check_by_audit_token(audit_token_t au, const char *operation, int type, ...) {
    va_list ap;
    va_start(ap, type);
    int ret = pt_sandbox_check_impl(YES, 0, au, operation, type, ap, __builtin_return_address(0));
    va_end(ap);
    return ret;
}

// Clear desktop/development-relaxed AMFI dyld policy output bits while preserving
// normal signed iOS app execution bits (ALLOW_AT_PATH=0x1, ALLOW_FALLBACK_PATHS=0x8).
#define PT_AMFI_DYLD_RELAXED_MASK 0x00000000000000F6ULL

static int pt_amfi_check_dyld_policy_self(uint64_t in_flags, uint64_t *out_flags) {
    typedef int (*AmfiDyldPolicyFn)(uint64_t, uint64_t *);
    static AmfiDyldPolicyFn s_orig = NULL;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_orig = (AmfiDyldPolicyFn)dlsym(RTLD_NEXT, "amfi_check_dyld_policy_self");
    });
    if (s_orig == NULL) {
        errno = ENOSYS;
        return -1;
    }
    int ret = s_orig(in_flags, out_flags);
    if (ret == 0 && out_flags != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        *out_flags &= ~PT_AMFI_DYLD_RELAXED_MASK;
    }
    return ret;
}

extern int pt_orig_mac_syscall(const char *policy, int call, void *arg) __asm("___mac_syscall");

__attribute__((visibility("hidden")))
int pt_mac_syscall_with_caller(const char *policy, int call, void *arg, const void *caller, BOOL *out_handled) {
    if (out_handled != NULL) {
        *out_handled = NO;
    }
    if (policy == NULL ||
        !pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(caller) ||
        !pt_is_valid_user_pointer(policy)) {
        return 0;
    }
    if (strcmp(policy, "AMFI") == 0 && call == 0x5a && arg != NULL && pt_is_valid_user_pointer(arg)) {
        if (out_handled != NULL) {
            *out_handled = YES;
        }
        int ret = pt_orig_mac_syscall(policy, call, arg);
        if (ret == 0) {
            uint64_t *out_ptr = NULL;
            memcpy(&out_ptr, (const uint8_t *)arg + sizeof(uint64_t), sizeof(out_ptr));
            if (out_ptr != NULL && pt_is_valid_user_pointer(out_ptr)) {
                *out_ptr &= ~PT_AMFI_DYLD_RELAXED_MASK;
            }
        }
        return ret;
    }
    if (strcmp(policy, "Sandbox") == 0 && call == 0 && arg != NULL && pt_is_valid_user_pointer(arg)) {
        struct {
            pid_t pid;
            uint32_t pad0;
            const char *operation;
            int type;
            uint32_t pad1;
            const char *arg0;
        } sb_req;
        memset(&sb_req, 0, sizeof(sb_req));
        memcpy(&sb_req, arg, sizeof(sb_req));
        if (sb_req.pid != 0 && sb_req.pid != getpid()) {
            if (out_handled != NULL) {
                *out_handled = YES;
            }
            errno = EPERM;
            return -1;
        }
        int filter = (sb_req.type & 0x0f);
        if (sb_req.operation != NULL && pt_is_valid_user_pointer(sb_req.operation) &&
            strncmp(sb_req.operation, "process-fork", 12) == 0) {
            if (out_handled != NULL) {
                *out_handled = YES;
            }
            return 1;
        }
        if (filter == PT_SANDBOX_FILTER_PATH && sb_req.arg0 != NULL && pt_is_valid_user_pointer(sb_req.arg0)) {
            char vbuf[PATH_MAX];
            const char *resolved = sb_req.arg0;
            int is_sys_flag = 0;
            pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(
                sb_req.arg0, caller, vbuf, sizeof(vbuf), &resolved, &is_sys_flag);
            if (disp == PT_FS_PATH_HIDDEN || disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
                if (out_handled != NULL) {
                    *out_handled = YES;
                }
                return 1;
            }
        } else if (filter == 2 && sb_req.arg0 != NULL && pt_is_valid_user_pointer(sb_req.arg0)) {
            if (pt_is_hidden_macos_mach_service(sb_req.arg0)) {
                if (out_handled != NULL) {
                    *out_handled = YES;
                }
                return 1;
            }
        }
    }
    return 0;
}

__attribute__((visibility("hidden")))
void *pt_entitlements_dlsym_route(const char *symbol) {
    if (symbol == NULL) {
        return NULL;
    }
    if (strcmp(symbol, "amfi_check_dyld_policy_self") == 0) {
        return (void *)&pt_amfi_check_dyld_policy_self;
    }
    if (strcmp(symbol, "sandbox_check") == 0) {
        return (void *)&pt_sandbox_check;
    }
    if (strcmp(symbol, "sandbox_check_by_audit_token") == 0) {
        return (void *)&pt_sandbox_check_by_audit_token;
    }
    if (strcmp(symbol, "sandbox_extension_issue_file") == 0) {
        return (void *)&pt_sandbox_extension_issue_file;
    }
    if (strcmp(symbol, "sandbox_extension_issue_file_to_self") == 0) {
        return (void *)&pt_sandbox_extension_issue_file_to_self;
    }
    if (strcmp(symbol, "sandbox_extension_issue_file_to_process") == 0) {
        return (void *)&pt_sandbox_extension_issue_file_to_process;
    }
    if (strcmp(symbol, "sandbox_extension_issue_file_to_process_by_pid") == 0) {
        return (void *)&pt_sandbox_extension_issue_file_to_process_by_pid;
    }
    if (strcmp(symbol, "csops") == 0) {
        return (void *)&pt_csops;
    }
    if (strcmp(symbol, "csops_audittoken") == 0) {
        return (void *)&pt_csops_audittoken;
    }
    if (strcmp(symbol, "ptrace") == 0) {
        return (void *)&pt_ptrace;
    }
    if (strcmp(symbol, "SecTaskCopyValueForEntitlement") == 0) {
        return (void *)&pt_SecTaskCopyValueForEntitlement;
    }
    if (strcmp(symbol, "SecTaskCopyValuesForEntitlements") == 0) {
        return (void *)&pt_SecTaskCopyValuesForEntitlements;
    }
    if (strcmp(symbol, "SecTaskGetCodeSignStatus") == 0) {
        return (void *)&pt_SecTaskGetCodeSignStatus;
    }
    if (strcmp(symbol, "SecTaskCopySigningIdentifier") == 0) {
        return (void *)&pt_SecTaskCopySigningIdentifier;
    }
    if (strcmp(symbol, "SecItemCopyMatching") == 0) {
        return (void *)&pt_SecItemCopyMatching;
    }
    if (strcmp(symbol, "SecItemAdd") == 0) {
        return (void *)&pt_SecItemAdd;
    }
    if (strcmp(symbol, "SecItemUpdate") == 0) {
        return (void *)&pt_SecItemUpdate;
    }
    if (strcmp(symbol, "SecItemDelete") == 0) {
        return (void *)&pt_SecItemDelete;
    }
    if (strcmp(symbol, "SecKeyCreateRandomKey") == 0) {
        return (void *)&pt_SecKeyCreateRandomKey;
    }
    if (strcmp(symbol, "SecKeyCopyExternalRepresentation") == 0) {
        return (void *)&pt_SecKeyCopyExternalRepresentation;
    }
    if (strcmp(symbol, "SecKeyCopyAttributes") == 0) {
        return (void *)&pt_SecKeyCopyAttributes;
    }
    if (strcmp(symbol, "SecKeyGeneratePair") == 0) {
        return (void *)&pt_SecKeyGeneratePair;
    }
    return NULL;
}


DYLD_INTERPOSE(pt_SecTaskCopyValueForEntitlement, SecTaskCopyValueForEntitlement)
DYLD_INTERPOSE(pt_SecTaskCopyValuesForEntitlements, SecTaskCopyValuesForEntitlements)
DYLD_INTERPOSE(pt_SecTaskGetCodeSignStatus, SecTaskGetCodeSignStatus)
DYLD_INTERPOSE(pt_SecTaskCopySigningIdentifier, SecTaskCopySigningIdentifier)
DYLD_INTERPOSE(pt_SecCodeCopySelf, SecCodeCopySelf)
DYLD_INTERPOSE(pt_SecCodeCopyStaticCode, SecCodeCopyStaticCode)
DYLD_INTERPOSE(pt_SecCodeCopyPath, SecCodeCopyPath)
DYLD_INTERPOSE(pt_SecCodeCopySigningInformation, SecCodeCopySigningInformation)
DYLD_INTERPOSE(pt_SecCodeCheckValidity, SecCodeCheckValidity)
DYLD_INTERPOSE(pt_SecCodeCheckValidityWithErrors, SecCodeCheckValidityWithErrors)
DYLD_INTERPOSE(pt_SecStaticCodeCreateWithPath, SecStaticCodeCreateWithPath)
DYLD_INTERPOSE(pt_SecStaticCodeCreateWithPathAndAttributes, SecStaticCodeCreateWithPathAndAttributes)
DYLD_INTERPOSE(pt_SecStaticCodeCheckValidity, SecStaticCodeCheckValidity)
DYLD_INTERPOSE(pt_SecStaticCodeCheckValidityWithErrors, SecStaticCodeCheckValidityWithErrors)
DYLD_INTERPOSE(pt_csops, csops)
DYLD_INTERPOSE(pt_csops_audittoken, csops_audittoken)
DYLD_INTERPOSE(pt_ptrace, ptrace)
DYLD_INTERPOSE(pt_sandbox_extension_issue_file, sandbox_extension_issue_file)
DYLD_INTERPOSE(pt_sandbox_extension_issue_file_to_self, sandbox_extension_issue_file_to_self)
DYLD_INTERPOSE(pt_sandbox_extension_issue_file_to_process, sandbox_extension_issue_file_to_process)
DYLD_INTERPOSE(pt_sandbox_extension_issue_file_to_process_by_pid, sandbox_extension_issue_file_to_process_by_pid)
DYLD_INTERPOSE(pt_sandbox_check, sandbox_check)
DYLD_INTERPOSE(pt_sandbox_check_by_audit_token, sandbox_check_by_audit_token)
