//
//  PTEntitlements.m
//  PlayTools
//

#import "PTInternal.h"
#import "PTCodeSignParser.h"
#import "PTDetectionRules.h"
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
#define PT_CS_OPS_CDHASH 5U
#define PT_CS_OPS_ENTITLEMENTS_BLOB 7
#define PT_CS_OPS_BLOB 10U
#define PT_CS_OPS_IDENTITY 11
#define PT_CS_OPS_TEAMID 14
#define PT_CS_OPS_CLEAR_LV 15U
#define PT_CS_OPS_DER_ENTITLEMENTS_BLOB 16U
#define PT_CS_OPS_VALIDATION_CATEGORY 17U
#define PT_CS_VALIDATION_CATEGORY_APPSTORE 3U
#define PT_CS_VALID 0x00000001U
#define PT_CS_ADHOC 0x00000002U
#define PT_CS_GET_TASK_ALLOW 0x00000004U
#define PT_CS_RUNTIME 0x00010000U
#define PT_CS_LINKER_SIGNED 0x00020000U
#define PT_CS_DESKTOP_CLEAR_MASK (PT_CS_ADHOC | PT_CS_GET_TASK_ALLOW | PT_CS_RUNTIME | PT_CS_LINKER_SIGNED)
#define PT_ERR_SEC_CS_NO_SUCH_CODE ((OSStatus)-67068)

static BOOL pt_get_or_compute_spoofed_primary_cdhash(uint8_t out_hash[20]);

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

static id pt_sanitize_entitlement_value_for_key(NSString *key, id val) {
    if (key == nil || val == nil) {
        return val;
    }
    const char *team = pt_get_effective_team_id_cstr();
    char bid[256];
    pt_get_effective_bundle_id_cstr(bid, sizeof(bid));
    NSString *teamStr = (team != NULL && strlen(team) == 10U) ? [NSString stringWithUTF8String:team] : nil;
    NSString *bidStr = (bid[0] != '\0') ? [NSString stringWithUTF8String:bid] : nil;
    if (teamStr.length != 10) {
        return val;
    }
    if ([key isEqualToString:@"com.apple.developer.team-identifier"]) {
        if ([val isKindOfClass:[NSString class]]) {
            return teamStr;
        }
        return val;
    }
    if ([key isEqualToString:@"application-identifier"] ||
        [key isEqualToString:@"com.apple.application-identifier"]) {
        if ([val isKindOfClass:[NSString class]] && bidStr.length > 0) {
            return [NSString stringWithFormat:@"%@.%@", teamStr, bidStr];
        }
        return val;
    }
    if ([key isEqualToString:@"keychain-access-groups"] && [val isKindOfClass:[NSArray class]]) {
        NSMutableArray *mapped = nil;
        NSArray *arr = (NSArray *)val;
        NSString *expectedAppGroup = (bidStr.length > 0)
            ? [NSString stringWithFormat:@"%@.%@", teamStr, bidStr]
            : nil;
        for (NSUInteger i = 0; i < arr.count; i++) {
            id entry = arr[i];
            if (![entry isKindOfClass:[NSString class]]) {
                continue;
            }
            NSString *s = (NSString *)entry;
            NSString *replacement = s;
            if ([s hasPrefix:@"$(AppIdentifierPrefix)"]) {
                NSString *rest = [s substringFromIndex:22];
                if ([rest hasPrefix:@"."]) {
                    replacement = [teamStr stringByAppendingString:rest];
                } else if (rest.length > 0) {
                    replacement = [NSString stringWithFormat:@"%@.%@", teamStr, rest];
                } else if (expectedAppGroup != nil) {
                    replacement = expectedAppGroup;
                }
            } else if ([s hasPrefix:@"FAKETEAMID."]) {
                NSString *rest = [s substringFromIndex:11];
                replacement = (rest.length > 0)
                    ? [NSString stringWithFormat:@"%@.%@", teamStr, rest]
                    : (expectedAppGroup ?: s);
            } else if ([s rangeOfString:@"PlayCover" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                       [s rangeOfString:@"MacOver" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                       [s rangeOfString:@"app.makedie" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                replacement = expectedAppGroup ?: s;
            } else if (expectedAppGroup != nil && bidStr.length > 0) {
                NSRange dot = [s rangeOfString:@"."];
                if (dot.location == 10) {
                    NSString *suffix = [s substringFromIndex:11];
                    if ([suffix isEqualToString:bidStr] && ![s isEqualToString:expectedAppGroup]) {
                        replacement = expectedAppGroup;
                    }
                }
            }
            if (![replacement isEqualToString:s]) {
                if (mapped == nil) {
                    mapped = [arr mutableCopy];
                }
                mapped[i] = replacement;
            }
        }
        return (mapped != nil) ? [mapped copy] : val;
    }
    return val;
}

static NSDictionary *pt_get_synthesized_app_entitlements_dict(void) {
    static NSDictionary *s_synth_ent = nil;
    static dispatch_once_t s_synth_once;
    dispatch_once(&s_synth_once, ^{
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        NSDictionary *fb = pt_get_fallback_entitlements_dict();
        for (NSString *k in fb) {
            if ([k isKindOfClass:[NSString class]] && !pt_is_hidden_entitlement_key(k)) {
                m[k] = pt_sanitize_entitlement_value_for_key(k, fb[k]);
            }
        }
        const char *team = pt_get_effective_team_id_cstr();
        char bid[256];
        pt_get_effective_bundle_id_cstr(bid, sizeof(bid));
        NSString *teamStr = [NSString stringWithUTF8String:team];
        NSString *bidStr = [NSString stringWithUTF8String:bid];
        if (teamStr.length == 10) {
            m[@"com.apple.developer.team-identifier"] = teamStr;
            if (bidStr.length > 0) {
                m[@"application-identifier"] = [NSString stringWithFormat:@"%@.%@", teamStr, bidStr];
                if (m[@"keychain-access-groups"] == nil) {
                    m[@"keychain-access-groups"] = @[ [NSString stringWithFormat:@"%@.%@", teamStr, bidStr] ];
                }
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
        pt_der_encode_dict_pairs((NSDictionary *)val, 0xB0U, out);
        return !out->failed;
    }
    return NO;
}

static NSData *pt_encode_entitlements_der(NSDictionary *ent) {
    if (ent == nil) {
        return nil;
    }
    pt_der_buf_t root_body = {0};
    uint8_t ver_tlv[3] = { 0x02U, 0x01U, 0x01U };
    pt_der_buf_append(&root_body, ver_tlv, sizeof(ver_tlv));
    pt_der_encode_dict_pairs(ent, 0xB0U, &root_body);
    pt_der_buf_t root = {0};
    if (!root_body.failed && root_body.data != NULL) {
        pt_der_buf_wrap_tlv(&root, 0x70U, root_body.data, root_body.len);
    }
    free(root_body.data);
    NSData *derData = nil;
    if (!root.failed && root.data != NULL && root.len > 0) {
        derData = [NSData dataWithBytes:root.data length:root.len];
    }
    free(root.data);
    return derData;
}

static NSData *pt_get_synthesized_entitlements_der_data(void) {
    static NSData *s_der_data = nil;
    static dispatch_once_t s_der_once;
    dispatch_once(&s_der_once, ^{
        s_der_data = pt_encode_entitlements_der(pt_get_synthesized_app_entitlements_dict());
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
    if (val != NULL && bypass && !is_sys && key != nil) {
        id sanVal = pt_sanitize_entitlement_value_for_key(key, (__bridge id)val);
        if (sanVal != (__bridge id)val && ![sanVal isEqual:(__bridge id)val]) {
            CFRelease(val);
            val = CFBridgingRetain(sanVal);
        }
    }
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
                if (![key isKindOfClass:[NSString class]]) {
                    continue;
                }
                if (pt_is_hidden_entitlement_key(key)) {
                    if (clean == nil) {
                        clean = [dict mutableCopy];
                    }
                    [clean removeObjectForKey:key];
                } else {
                    id cur = dict[key];
                    id san = pt_sanitize_entitlement_value_for_key(key, cur);
                    if (san != cur && ![san isEqual:cur]) {
                        if (clean == nil) {
                            clean = [dict mutableCopy];
                        }
                        clean[key] = san;
                    }
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
        flags &= ~PT_CS_DESKTOP_CLEAR_MASK;
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
    BOOL in_app_bundle = NO;
    if (app_caller && pt_static_code_is_hidden(code, caller, &in_app_bundle)) {
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
                    if (![ek isKindOfClass:[NSString class]]) {
                        continue;
                    }
                    if (pt_is_hidden_entitlement_key(ek)) {
                        if (cleanEnt == nil) {
                            cleanEnt = [(NSDictionary *)entDict mutableCopy];
                        }
                        [cleanEnt removeObjectForKey:ek];
                    } else {
                        id rawVal = ((NSDictionary *)entDict)[ek];
                        id sanVal = pt_sanitize_entitlement_value_for_key(ek, rawVal);
                        if (sanVal != rawVal && ![sanVal isEqual:rawVal]) {
                            if (cleanEnt == nil) {
                                cleanEnt = [(NSDictionary *)entDict mutableCopy];
                            }
                            cleanEnt[ek] = sanVal;
                        }
                    }
                }
                if (cleanEnt != nil) {
                    clean[@"entitlements-dict"] = [cleanEnt copy];
                }
            }
            if (in_app_bundle) {
                NSDictionary *entForBlob = [clean[@"entitlements-dict"] isKindOfClass:[NSDictionary class]]
                    ? clean[@"entitlements-dict"]
                    : (((flags & 2U) != 0U || clean[@"entitlements"] != nil || clean[@"entitlements-DER"] != nil)
                           ? pt_get_synthesized_app_entitlements_dict()
                           : nil);
                if (entForBlob != nil) {
                    clean[@"entitlements-dict"] = entForBlob;
                    NSData *xmlPayload = [NSPropertyListSerialization dataWithPropertyList:entForBlob
                                                                                    format:NSPropertyListXMLFormat_v1_0
                                                                                   options:0
                                                                                     error:nil];
                    if (xmlPayload.length > 0 && xmlPayload.length <= (size_t)UINT32_MAX - 8U) {
                        NSMutableData *xmlBlob = [NSMutableData dataWithLength:8U + xmlPayload.length];
                        uint32_t hdr[2] = { htonl(PT_CSMAGIC_EMBEDDED_ENTITLEMENTS), htonl((uint32_t)(8U + xmlPayload.length)) };
                        memcpy(xmlBlob.mutableBytes, hdr, sizeof(hdr));
                        memcpy((uint8_t *)xmlBlob.mutableBytes + 8U, xmlPayload.bytes, xmlPayload.length);
                        clean[@"entitlements"] = [xmlBlob copy];
                    } else {
                        [clean removeObjectForKey:@"entitlements"];
                    }
                    if (!pt_is_compat13_7_active()) {
                        NSData *derPayload = pt_encode_entitlements_der(entForBlob);
                        if (derPayload.length > 0 && derPayload.length <= (size_t)UINT32_MAX - 8U) {
                            NSMutableData *derBlob = [NSMutableData dataWithLength:8U + derPayload.length];
                            uint32_t hdr[2] = { htonl(PT_CSMAGIC_EMBEDDED_DER_ENTITLEMENTS), htonl((uint32_t)(8U + derPayload.length)) };
                            memcpy(derBlob.mutableBytes, hdr, sizeof(hdr));
                            memcpy((uint8_t *)derBlob.mutableBytes + 8U, derPayload.bytes, derPayload.length);
                            clean[@"entitlements-DER"] = [derBlob copy];
                        } else {
                            [clean removeObjectForKey:@"entitlements-DER"];
                        }
                    } else {
                        [clean removeObjectForKey:@"entitlements-DER"];
                    }
                } else {
                    [clean removeObjectForKey:@"entitlements"];
                    [clean removeObjectForKey:@"entitlements-DER"];
                }
            } else {
                [clean removeObjectForKey:@"entitlements"];
                [clean removeObjectForKey:@"entitlements-DER"];
            }
            [clean removeObjectForKey:@"changed-files"];
            id flagsObj = clean[@"flags"];
            if ([flagsObj isKindOfClass:[NSNumber class]]) {
                uint32_t f = [(NSNumber *)flagsObj unsignedIntValue];
                f &= ~PT_CS_DESKTOP_CLEAR_MASK;
                clean[@"flags"] = @(f);
            }
            id statusObj = clean[@"status"];
            if ([statusObj isKindOfClass:[NSNumber class]]) {
                uint32_t s = [(NSNumber *)statusObj unsignedIntValue];
                s &= ~PT_CS_DESKTOP_CLEAR_MASK;
                s |= PT_CS_VALID;
                clean[@"status"] = @(s);
            }
            if (in_app_bundle && (clean[@"cdhash"] != nil || clean[@"cdhashes"] != nil)) {
                uint8_t cdhash[20];
                if (pt_get_or_compute_spoofed_primary_cdhash(cdhash)) {
                    NSData *cdData = [NSData dataWithBytes:cdhash length:sizeof(cdhash)];
                    if (clean[@"cdhash"] != nil) {
                        clean[@"cdhash"] = cdData;
                    }
                    if (clean[@"cdhashes"] != nil) {
                        clean[@"cdhashes"] = @[ cdData ];
                    }
                }
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
            {
                const char *team = pt_get_effective_team_id_cstr();
                if (team != NULL && strlen(team) == 10U) {
                    NSString *teamStr = [NSString stringWithUTF8String:team];
                    id curTeam = clean[@"teamid"];
                    if (in_app_bundle ||
                        curTeam == nil ||
                        ![curTeam isKindOfClass:[NSString class]] ||
                        [(NSString *)curTeam length] == 0) {
                        clean[@"teamid"] = teamStr;
                    }
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

static os_unfair_lock s_spoofed_cdhash_lock = OS_UNFAIR_LOCK_INIT;
static uint8_t s_spoofed_primary_cdhash[20];
static BOOL s_spoofed_primary_cdhash_valid = NO;
static BOOL s_spoofed_primary_cdhash_compat13 = NO;

static void pt_store_spoofed_primary_cdhash(const uint8_t *cd_bytes, size_t cd_len, BOOL compat13) {
    if (cd_bytes == NULL || cd_len < 40U || cd_len > (16U << 20)) {
        return;
    }
    uint8_t hash_type = cd_bytes[37];
    uint8_t out20[20];
    if (hash_type == PT_CS_HASHTYPE_SHA1) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        CC_SHA1(cd_bytes, (CC_LONG)cd_len, out20);
#pragma clang diagnostic pop
    } else {
        uint8_t full[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(cd_bytes, (CC_LONG)cd_len, full);
        memcpy(out20, full, sizeof(out20));
    }
    os_unfair_lock_lock(&s_spoofed_cdhash_lock);
    memcpy(s_spoofed_primary_cdhash, out20, sizeof(out20));
    s_spoofed_primary_cdhash_compat13 = compat13;
    s_spoofed_primary_cdhash_valid = YES;
    os_unfair_lock_unlock(&s_spoofed_cdhash_lock);
}

static int pt_handle_spoofed_csops_blob(pid_t pid,
                                        void *useraddr,
                                        size_t usersize,
                                        BOOL use_audittoken,
                                        audit_token_t *token);

static BOOL pt_get_or_compute_spoofed_primary_cdhash(uint8_t out_hash[20]) {
    if (out_hash == NULL) {
        return NO;
    }
    BOOL compat13 = pt_is_compat13_7_active();
    os_unfair_lock_lock(&s_spoofed_cdhash_lock);
    if (s_spoofed_primary_cdhash_valid && s_spoofed_primary_cdhash_compat13 == compat13) {
        memcpy(out_hash, s_spoofed_primary_cdhash, 20U);
        os_unfair_lock_unlock(&s_spoofed_cdhash_lock);
        return YES;
    }
    os_unfair_lock_unlock(&s_spoofed_cdhash_lock);

    int saved_errno = errno;
    uint8_t probe[8] = {0};
    (void)pt_handle_spoofed_csops_blob(getpid(), probe, sizeof(probe), NO, NULL);
    errno = saved_errno;

    os_unfair_lock_lock(&s_spoofed_cdhash_lock);
    BOOL ok = (s_spoofed_primary_cdhash_valid && s_spoofed_primary_cdhash_compat13 == compat13);
    if (ok) {
        memcpy(out_hash, s_spoofed_primary_cdhash, 20U);
    }
    os_unfair_lock_unlock(&s_spoofed_cdhash_lock);
    return ok;
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
    int saved_errno = errno;
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
        errno = saved_errno;
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
        errno = saved_errno;
        return use_audittoken
            ? csops_audittoken(pid, PT_CS_OPS_BLOB, useraddr, usersize, token)
            : csops(pid, PT_CS_OPS_BLOB, useraddr, usersize);
    }

    uint32_t max_cd_special_slots = 0;
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
        if (stype == PT_CSSLOT_CODEDIRECTORY ||
            (stype >= PT_CSSLOT_ALTERNATE_CODEDIRECTORIES &&
             stype < PT_CSSLOT_ALTERNATE_CODEDIRECTORIES + PT_CSSLOT_ALTERNATE_CODEDIRECTORY_MAX)) {
            uint32_t sc = pt_code_directory_special_slot_count(raw_buf + soff, (size_t)clen);
            if (sc > max_cd_special_slots) {
                max_cd_special_slots = sc;
            }
        }
    }

    BOOL compat13 = pt_is_compat13_7_active();
    BOOL allow_der_slot = (!compat13 && max_cd_special_slots >= PT_CSSLOT_DER_ENTITLEMENTS);
    NSData *xmlData = pt_get_synthesized_entitlements_xml_data();
    NSData *derData = allow_der_slot ? pt_get_synthesized_entitlements_der_data() : nil;
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
            if (!allow_der_slot || derData == nil || derData.length == 0) {
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
    if (!saw_der_slot && allow_der_slot && derData != nil && derData.length > 0) {
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
    BOOL has_der = (allow_der_slot && derData != nil && derData.length > 0);
    if (has_xml) {
        pt_sha256_cs_blob(PT_CSMAGIC_EMBEDDED_ENTITLEMENTS, (const uint8_t *)xmlData.bytes, xmlData.length, xml_hash);
        pt_sha1_cs_blob(PT_CSMAGIC_EMBEDDED_ENTITLEMENTS, (const uint8_t *)xmlData.bytes, xmlData.length, xml_sha1);
    }
    if (has_der) {
        pt_sha256_cs_blob(PT_CSMAGIC_EMBEDDED_DER_ENTITLEMENTS, (const uint8_t *)derData.bytes, derData.length, der_hash);
        pt_sha1_cs_blob(PT_CSMAGIC_EMBEDDED_DER_ENTITLEMENTS, (const uint8_t *)derData.bytes, derData.length, der_sha1);
    }
    uint8_t **heap_cd_bufs = (uint8_t **)calloc(out_count > 0 ? out_count : 1U, sizeof(uint8_t *));
    size_t heap_cd_count = 0;
    const char *effective_team_id = pt_get_effective_team_id_cstr();
    const uint8_t *best_cd_bytes = NULL;
    size_t best_cd_len = 0;
    BOOL best_cd_is_sha256 = NO;
    for (uint32_t i = 0; i < out_count; i++) {
        uint32_t stype = slots[i].type;
        if (slots[i].mutable_bytes != NULL &&
            (stype == PT_CSSLOT_CODEDIRECTORY ||
             (stype >= PT_CSSLOT_ALTERNATE_CODEDIRECTORIES &&
              stype < PT_CSSLOT_ALTERNATE_CODEDIRECTORIES + PT_CSSLOT_ALTERNATE_CODEDIRECTORY_MAX))) {
            if (heap_cd_bufs != NULL &&
                slots[i].len >= 52U &&
                effective_team_id != NULL &&
                strlen(effective_team_id) == 10U) {
                uint32_t cd_ver = 0, team_off = 0;
                memcpy(&cd_ver, slots[i].mutable_bytes + 8U, sizeof(cd_ver));
                memcpy(&team_off, slots[i].mutable_bytes + 48U, sizeof(team_off));
                cd_ver = ntohl(cd_ver);
                team_off = ntohl(team_off);
                if (cd_ver >= 0x20200U && team_off == 0U && slots[i].len <= (size_t)UINT32_MAX - 11U) {
                    size_t new_len = slots[i].len + 11U;
                    uint8_t *grown = (uint8_t *)malloc(new_len);
                    if (grown != NULL) {
                        memcpy(grown, slots[i].mutable_bytes, slots[i].len);
                        memcpy(grown + slots[i].len, effective_team_id, 11U);
                        uint32_t be_new_len = htonl((uint32_t)new_len);
                        uint32_t be_team_off = htonl((uint32_t)slots[i].len);
                        memcpy(grown + 4U, &be_new_len, sizeof(be_new_len));
                        memcpy(grown + 48U, &be_team_off, sizeof(be_team_off));
                        payload_total += 11U;
                        slots[i].mutable_bytes = grown;
                        slots[i].bytes = grown;
                        slots[i].len = new_len;
                        heap_cd_bufs[heap_cd_count++] = grown;
                    }
                }
            }
            pt_patch_code_directory_metadata(
                slots[i].mutable_bytes, slots[i].len, PT_CS_DESKTOP_CLEAR_MASK, effective_team_id);
            pt_patch_code_directory_entitlement_hashes(
                slots[i].mutable_bytes, slots[i].len, has_xml, xml_hash, xml_sha1, has_der, der_hash, der_sha1);
            if (slots[i].len >= 40U) {
                uint8_t ht = slots[i].mutable_bytes[37];
                BOOL is_sha256 = (ht == PT_CS_HASHTYPE_SHA256 || ht == PT_CS_HASHTYPE_SHA256_TRUNCATED);
                if ((is_sha256 && !best_cd_is_sha256) ||
                    (best_cd_bytes == NULL && stype == PT_CSSLOT_CODEDIRECTORY)) {
                    best_cd_bytes = slots[i].mutable_bytes;
                    best_cd_len = slots[i].len;
                    best_cd_is_sha256 = is_sha256;
                }
            }
        }
    }
    if (best_cd_bytes != NULL) {
        pt_store_spoofed_primary_cdhash(best_cd_bytes, best_cd_len, compat13);
    }

    size_t header_len = 12U + (size_t)out_count * 8U;
    if (payload_total > (size_t)UINT32_MAX - header_len) {
        for (size_t hi = 0; hi < heap_cd_count; hi++) {
            free(heap_cd_bufs[hi]);
        }
        free(heap_cd_bufs);
        free(slots);
        free(raw_buf);
        errno = EOVERFLOW;
        return -1;
    }
    size_t out_total = header_len + payload_total;
    if (usersize < 8U) {
        for (size_t hi = 0; hi < heap_cd_count; hi++) {
            free(heap_cd_bufs[hi]);
        }
        free(heap_cd_bufs);
        free(slots);
        free(raw_buf);
        errno = ERANGE;
        return -1;
    }
    uint32_t out_hdr[2] = { htonl(PT_CSMAGIC_EMBEDDED_SIGNATURE), htonl((uint32_t)out_total) };
    memcpy(useraddr, out_hdr, sizeof(out_hdr));
    if (usersize < out_total) {
        for (size_t hi = 0; hi < heap_cd_count; hi++) {
            free(heap_cd_bufs[hi]);
        }
        free(heap_cd_bufs);
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
    for (size_t hi = 0; hi < heap_cd_count; hi++) {
        free(heap_cd_bufs[hi]);
    }
    free(heap_cd_bufs);
    free(slots);
    free(raw_buf);
    errno = saved_errno;
    return 0;
}

static int pt_handle_spoofed_csops_query(pid_t pid,
                                         unsigned int ops,
                                         void *useraddr,
                                         size_t usersize,
                                         BOOL use_audittoken,
                                         audit_token_t *token) {
    if (ops == PT_CS_OPS_CDHASH) {
        if (usersize > 0 && useraddr == NULL) {
            errno = EFAULT;
            return -1;
        }
        if (usersize < 20U) {
            errno = ERANGE;
            return -1;
        }
        uint8_t cdhash[20];
        if (pt_get_or_compute_spoofed_primary_cdhash(cdhash)) {
            memcpy(useraddr, cdhash, sizeof(cdhash));
            return 0;
        }
        return -2;
    }
    if (ops == PT_CS_OPS_VALIDATION_CATEGORY) {
        if (pt_is_compat13_7_active()) {
            errno = EINVAL;
            return -1;
        }
        if (usersize > 0 && useraddr == NULL) {
            errno = EFAULT;
            return -1;
        }
        if (usersize < sizeof(uint32_t)) {
            errno = ERANGE;
            return -1;
        }
        uint32_t cat = PT_CS_VALIDATION_CATEGORY_APPSTORE;
        memcpy(useraddr, &cat, sizeof(cat));
        return 0;
    }
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
            *flags &= ~PT_CS_DESKTOP_CLEAR_MASK;
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
            *flags &= ~PT_CS_DESKTOP_CLEAR_MASK;
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

static void pt_ensure_playchain_default_access_group(void) {
    static dispatch_once_t s_agrp_once;
    dispatch_once(&s_agrp_once, ^{
        NSArray<NSString *> *allowed = pt_get_allowed_keychain_access_groups();
        if (allowed.count > 0) {
            [PlayKeychain setDefaultAccessGroup:allowed.firstObject];
        }
    });
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
        pt_ensure_playchain_default_access_group();
        BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
        if (!is_sys) {
            OSStatus agrpStatus = pt_validate_dict_access_group(query, YES);
            if (agrpStatus != errSecSuccess) {
                return agrpStatus;
            }
        }
        retval = [PlayKeychain copyMatching:(__bridge NSDictionary * _Nonnull)(query) result:result];
        if (retval == errSecItemNotFound && is_sys) {
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
        pt_ensure_playchain_default_access_group();
        NSDictionary *attrsDict = (__bridge NSDictionary *)attributes;
        if (!pt_is_effective_system_or_playtools_caller(caller)) {
            id rawToken = attrsDict[(__bridge id)kSecAttrTokenID];
            if ([rawToken isKindOfClass:[NSString class]] &&
                [(NSString *)rawToken isEqualToString:(__bridge NSString *)kSecAttrTokenIDSecureEnclave] &&
                attrsDict[(__bridge id)kSecValueData] != nil) {
                return errSecParam;
            }
            OSStatus agrpStatus = pt_validate_dict_access_group(attributes, NO);
            if (agrpStatus != errSecSuccess) {
                return agrpStatus;
            }
            if (attrsDict[(__bridge id)kSecAttrAccessGroup] == nil) {
                NSString *defGroup = pt_get_allowed_keychain_access_groups().firstObject;
                if (defGroup.length > 0) {
                    NSMutableDictionary *withAgrp = [attrsDict mutableCopy];
                    withAgrp[(__bridge id)kSecAttrAccessGroup] = defGroup;
                    attrsDict = [withAgrp copy];
                }
            }
        }
        retval = [PlayKeychain add:attrsDict result:result];
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
        pt_ensure_playchain_default_access_group();
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
        pt_ensure_playchain_default_access_group();
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
        pt_ensure_playchain_default_access_group();
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
    if (pt_is_playchain_enabled() && !pt_is_effective_system_or_playtools_caller(caller)) {
        BOOL isSE = [PTPlayChainSecureEnclaveRegistry isSecureEnclaveKey:key];
        NSDictionary *persisted = [PTPlayChainSecureEnclaveRegistry persistedAttributesForKey:key];
        if (isSE || persisted.count > 0) {
            NSDictionary *dict = (__bridge NSDictionary *)attrs;
            if ([dict isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *sanitized = [dict mutableCopy];
                if (persisted != nil) {
                    for (id pKey in persisted) {
                        sanitized[pKey] = persisted[pKey];
                    }
                }
                if (isSE) {
                    [sanitized removeObjectForKey:(__bridge id)kSecValueData];
                    sanitized[(__bridge id)kSecAttrTokenID] = (__bridge id)kSecAttrTokenIDSecureEnclave;
                }
                CFRelease(attrs);
                return (__bridge_retained CFDictionaryRef)[sanitized copy];
            }
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
        pt_ensure_playchain_default_access_group();
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

PT_INTERPOSE(pt_SecItemCopyMatching, SecItemCopyMatching)
PT_INTERPOSE(pt_SecItemAdd, SecItemAdd)
PT_INTERPOSE(pt_SecItemUpdate, SecItemUpdate)
PT_INTERPOSE(pt_SecItemDelete, SecItemDelete)
PT_INTERPOSE(pt_SecKeyCreateRandomKey, SecKeyCreateRandomKey)
PT_INTERPOSE(pt_SecKeyCopyExternalRepresentation, SecKeyCopyExternalRepresentation)
PT_INTERPOSE(pt_SecKeyCopyAttributes, SecKeyCopyAttributes)
PT_INTERPOSE(pt_SecKeyGeneratePair, SecKeyGeneratePair)
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

    if (!is_sys && bypass) {
        if (!use_audit_token && pid != 0 && pid != getpid()) {
            errno = EPERM;
            return -1;
        }
        if (use_audit_token) {
            pid_t au_pid = (pid_t)au.val[5];
            if (au_pid != 0 && au_pid != getpid()) {
                errno = EPERM;
                return -1;
            }
        }
    }

    if (filter == PT_SANDBOX_FILTER_NONE) {
        int ret = use_audit_token ? sandbox_check_by_audit_token(au, operation, type)
                                  : sandbox_check(pid, operation, type);
        if (!is_sys && bypass && ret == 0 &&
            (operation == NULL ||
             strncmp(operation, "process-fork", 12) == 0 ||
             strncmp(operation, "process-exec", 12) == 0)) {
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
    return pt_is_hidden_macos_mach_service_cstr(name) ? YES : NO;
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

extern int pt_orig_amfi_check_dyld_policy_self(uint64_t, uint64_t *) __asm__("_amfi_check_dyld_policy_self") __attribute__((weak_import));

static int pt_amfi_check_dyld_policy_self(uint64_t in_flags, uint64_t *out_flags) {
    if (&pt_orig_amfi_check_dyld_policy_self == NULL) {
        errno = ENOSYS;
        return -1;
    }
    int ret = pt_orig_amfi_check_dyld_policy_self(in_flags, out_flags);
    if (ret == 0 && out_flags != NULL &&
        pt_is_bypass_enabled() &&
        !pt_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        *out_flags &= ~PT_AMFI_DYLD_RELAXED_MASK;
    }
    return ret;
}

extern int pt_orig_mac_syscall(const char *policy, int call, void *arg) __asm("___mac_syscall");

static BOOL pt_mac_sandbox_operation_denied(const char *operation) {
    return (operation != NULL &&
            pt_is_valid_user_pointer(operation) &&
            (strncmp(operation, "process-fork", 12) == 0 ||
             strncmp(operation, "process-exec", 12) == 0));
}

static BOOL pt_mac_sandbox_should_deny(const char *operation,
                                       int type,
                                       uintptr_t arg0,
                                       const void *caller) {
    if (pt_mac_sandbox_operation_denied(operation)) {
        return YES;
    }
    int filter = (type & 0x0f);
    if (filter == PT_SANDBOX_FILTER_PATH && arg0 != 0 && pt_is_valid_user_pointer((const void *)arg0)) {
        const char *path = (const char *)arg0;
        char vbuf[PATH_MAX];
        const char *resolved = path;
        int is_sys_flag = 0;
        pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(
            path, caller, vbuf, sizeof(vbuf), &resolved, &is_sys_flag);
        if (disp == PT_FS_PATH_HIDDEN || disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
            return YES;
        }
    } else if (filter == PT_SANDBOX_FILTER_DESCRIPTOR) {
        if (pt_fd_is_sensitive((int)arg0, caller)) {
            return YES;
        }
    } else if ((filter == 2 || filter == 3 || filter == 6 || filter == 9 || filter == 12) &&
               arg0 != 0 && pt_is_valid_user_pointer((const void *)arg0)) {
        const char *sarg = (const char *)arg0;
        if (strcasestr(sarg, "playcover") != NULL ||
            strcasestr(sarg, "macover") != NULL ||
            strcasestr(sarg, "app.makedie") != NULL ||
            strcasestr(sarg, "playtools") != NULL ||
            strcasestr(sarg, "akinterface") != NULL) {
            return YES;
        }
        if (filter == 2 && pt_is_hidden_macos_mach_service(sarg)) {
            return YES;
        }
    }
    return NO;
}

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
            uintptr_t arg0;
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
        if (pt_mac_sandbox_should_deny(sb_req.operation, sb_req.type, sb_req.arg0, caller)) {
            if (out_handled != NULL) {
                *out_handled = YES;
            }
            return 1;
        }
        if ((sb_req.type & 0x0f) == PT_SANDBOX_FILTER_PATH &&
            sb_req.arg0 != 0 &&
            pt_is_valid_user_pointer((const void *)sb_req.arg0)) {
            char vbuf[PATH_MAX];
            const char *resolved = (const char *)sb_req.arg0;
            int is_sys_flag = 0;
            (void)pt_prepare_fs_path_cached_caller(
                (const char *)sb_req.arg0, caller, vbuf, sizeof(vbuf), &resolved, &is_sys_flag);
            if (resolved != (const char *)sb_req.arg0) {
                sb_req.arg0 = (uintptr_t)resolved;
                if (out_handled != NULL) {
                    *out_handled = YES;
                }
                return pt_orig_mac_syscall(policy, call, &sb_req);
            }
        }
    } else if (strcmp(policy, "Sandbox") == 0 && call == 2 && arg != NULL && pt_is_valid_user_pointer(arg)) {
        struct {
            audit_token_t au;
            const char *operation;
            int type;
            uint32_t pad1;
            uintptr_t arg0;
        } sb_au_req;
        memset(&sb_au_req, 0, sizeof(sb_au_req));
        memcpy(&sb_au_req, arg, sizeof(sb_au_req));
        pid_t au_pid = (pid_t)sb_au_req.au.val[5];
        if (au_pid != 0 && au_pid != getpid()) {
            if (out_handled != NULL) {
                *out_handled = YES;
            }
            errno = EPERM;
            return -1;
        }
        if (pt_mac_sandbox_should_deny(sb_au_req.operation, sb_au_req.type, sb_au_req.arg0, caller)) {
            if (out_handled != NULL) {
                *out_handled = YES;
            }
            return 1;
        }
        if ((sb_au_req.type & 0x0f) == PT_SANDBOX_FILTER_PATH &&
            sb_au_req.arg0 != 0 &&
            pt_is_valid_user_pointer((const void *)sb_au_req.arg0)) {
            char vbuf[PATH_MAX];
            const char *resolved = (const char *)sb_au_req.arg0;
            int is_sys_flag = 0;
            (void)pt_prepare_fs_path_cached_caller(
                (const char *)sb_au_req.arg0, caller, vbuf, sizeof(vbuf), &resolved, &is_sys_flag);
            if (resolved != (const char *)sb_au_req.arg0) {
                sb_au_req.arg0 = (uintptr_t)resolved;
                if (out_handled != NULL) {
                    *out_handled = YES;
                }
                return pt_orig_mac_syscall(policy, call, &sb_au_req);
            }
        }
    } else if (strcmp(policy, "Sandbox") == 0 && call == 21 && arg != NULL && pt_is_valid_user_pointer(arg)) {
        struct {
            uint64_t pid;
            uint64_t pidver;
            const char *operation;
            uint64_t flags;
            uint64_t count;
            const char *const *paths;
            uint8_t *results;
        } sb_bulk;
        memset(&sb_bulk, 0, sizeof(sb_bulk));
        memcpy(&sb_bulk, arg, sizeof(sb_bulk));
        if (sb_bulk.pid != 0 && (pid_t)sb_bulk.pid != getpid()) {
            if (out_handled != NULL) {
                *out_handled = YES;
            }
            errno = EPERM;
            return -1;
        }
        if (pt_mac_sandbox_operation_denied(sb_bulk.operation) &&
            sb_bulk.results != NULL &&
            pt_is_valid_user_pointer(sb_bulk.results) &&
            sb_bulk.count <= 4096U) {
            if (out_handled != NULL) {
                *out_handled = YES;
            }
            memset(sb_bulk.results, 1, (size_t)sb_bulk.count);
            return 0;
        }
        if (sb_bulk.count > 0 &&
            sb_bulk.count <= 4096U &&
            sb_bulk.paths != NULL &&
            pt_is_valid_user_pointer(sb_bulk.paths)) {
            size_t cnt = (size_t)sb_bulk.count;
            const char **rewritten = (const char **)calloc(cnt, sizeof(const char *));
            char (*vbufs)[PATH_MAX] = (char (*)[PATH_MAX])malloc(cnt * PATH_MAX);
            BOOL *deny_mask = (BOOL *)calloc(cnt, sizeof(BOOL));
            if (rewritten != NULL && vbufs != NULL && deny_mask != NULL) {
                for (size_t i = 0; i < cnt; i++) {
                    const char *p = sb_bulk.paths[i];
                    const char *resolved = p;
                    int is_sys_flag = 0;
                    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(
                        p, caller, vbufs[i], PATH_MAX, &resolved, &is_sys_flag);
                    if (disp == PT_FS_PATH_HIDDEN || disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
                        deny_mask[i] = YES;
                    }
                    rewritten[i] = resolved;
                }
                __typeof__(sb_bulk) sb_bulk_copy = sb_bulk;
                sb_bulk_copy.paths = rewritten;
                if (out_handled != NULL) {
                    *out_handled = YES;
                }
                int ret = pt_orig_mac_syscall(policy, call, &sb_bulk_copy);
                if (ret == 0 && sb_bulk.results != NULL && pt_is_valid_user_pointer(sb_bulk.results)) {
                    for (size_t i = 0; i < cnt; i++) {
                        if (deny_mask[i]) {
                            sb_bulk.results[i] = 1;
                        }
                    }
                }
                free(rewritten);
                free(vbufs);
                free(deny_mask);
                return ret;
            }
            free(rewritten);
            free(vbufs);
            free(deny_mask);
        }
    }
    return 0;
}

extern int pt_orig_sandbox_check_by_uniqueid(pid_t pid, uint64_t uniqueid, const char *operation, int type, ...)
    __asm__("_sandbox_check_by_uniqueid") __attribute__((weak_import));
extern int pt_orig_sandbox_check_by_reference(void *ref, const char *operation, int type, ...)
    __asm__("_sandbox_check_by_reference") __attribute__((weak_import));
extern int pt_orig_sandbox_check_bulk(const audit_token_t *au,
                                      const char *operation,
                                      int flags,
                                      uint32_t count,
                                      const char *const *paths,
                                      uint8_t *results)
    __asm__("_sandbox_check_bulk") __attribute__((weak_import));

static int pt_sandbox_check_by_uniqueid(pid_t pid, uint64_t uniqueid, const char *operation, int type, ...) {
    if (&pt_orig_sandbox_check_by_uniqueid == NULL) {
        errno = ENOSYS;
        return -1;
    }
    const void *caller = __builtin_return_address(0);
    int filter = (type & 0x0f);
    BOOL bypass = pt_is_bypass_enabled();
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (!is_sys && bypass && pid != 0 && pid != getpid()) {
        errno = EPERM;
        return -1;
    }
    if (filter == PT_SANDBOX_FILTER_NONE) {
        int ret = pt_orig_sandbox_check_by_uniqueid(pid, uniqueid, operation, type);
        if (!is_sys && bypass && ret == 0 &&
            (operation == NULL ||
             strncmp(operation, "process-fork", 12) == 0 ||
             strncmp(operation, "process-exec", 12) == 0)) {
            return 1;
        }
        return ret;
    }
    va_list ap;
    va_start(ap, type);
    if (filter == PT_SANDBOX_FILTER_PATH) {
        const char *path = va_arg(ap, const char *);
        va_end(ap);
        char vbuf[PATH_MAX];
        const char *resolved = path;
        int is_sys_flag = is_sys ? 1 : 0;
        pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(
            path, caller, vbuf, sizeof(vbuf), &resolved, &is_sys_flag);
        if (!is_sys && bypass && (disp == PT_FS_PATH_HIDDEN || disp == PT_FS_PATH_VIRTUAL_ANCESTOR)) {
            return 1;
        }
        return pt_orig_sandbox_check_by_uniqueid(pid, uniqueid, operation, type, resolved);
    }
    uintptr_t arg1 = va_arg(ap, uintptr_t);
    va_end(ap);
    if (!is_sys && bypass && pt_mac_sandbox_should_deny(operation, type, arg1, caller)) {
        return 1;
    }
    return pt_orig_sandbox_check_by_uniqueid(pid, uniqueid, operation, type, arg1);
}

static int pt_sandbox_check_by_reference(void *ref, const char *operation, int type, ...) {
    if (&pt_orig_sandbox_check_by_reference == NULL) {
        errno = ENOSYS;
        return -1;
    }
    const void *caller = __builtin_return_address(0);
    int filter = (type & 0x0f);
    BOOL bypass = pt_is_bypass_enabled();
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (filter == PT_SANDBOX_FILTER_NONE) {
        int ret = pt_orig_sandbox_check_by_reference(ref, operation, type);
        if (!is_sys && bypass && ret == 0 &&
            (operation == NULL ||
             strncmp(operation, "process-fork", 12) == 0 ||
             strncmp(operation, "process-exec", 12) == 0)) {
            return 1;
        }
        return ret;
    }
    va_list ap;
    va_start(ap, type);
    if (filter == PT_SANDBOX_FILTER_PATH) {
        const char *path = va_arg(ap, const char *);
        va_end(ap);
        char vbuf[PATH_MAX];
        const char *resolved = path;
        int is_sys_flag = is_sys ? 1 : 0;
        pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(
            path, caller, vbuf, sizeof(vbuf), &resolved, &is_sys_flag);
        if (!is_sys && bypass && (disp == PT_FS_PATH_HIDDEN || disp == PT_FS_PATH_VIRTUAL_ANCESTOR)) {
            return 1;
        }
        return pt_orig_sandbox_check_by_reference(ref, operation, type, resolved);
    }
    uintptr_t arg1 = va_arg(ap, uintptr_t);
    va_end(ap);
    if (!is_sys && bypass && pt_mac_sandbox_should_deny(operation, type, arg1, caller)) {
        return 1;
    }
    return pt_orig_sandbox_check_by_reference(ref, operation, type, arg1);
}

static int pt_sandbox_check_bulk(const audit_token_t *au,
                                 const char *operation,
                                 int flags,
                                 uint32_t count,
                                 const char *const *paths,
                                 uint8_t *results) {
    if (&pt_orig_sandbox_check_bulk == NULL) {
        errno = ENOSYS;
        return -1;
    }
    const void *caller = __builtin_return_address(0);
    BOOL bypass = pt_is_bypass_enabled();
    BOOL is_sys = pt_is_effective_system_or_playtools_caller(caller);
    if (!is_sys && bypass && au != NULL && pt_is_valid_user_pointer(au)) {
        pid_t au_pid = (pid_t)au->val[5];
        if (au_pid != 0 && au_pid != getpid()) {
            errno = EPERM;
            return -1;
        }
    }
    if (is_sys || !bypass || count == 0 || count > 4096U) {
        return pt_orig_sandbox_check_bulk(au, operation, flags, count, paths, results);
    }
    if (pt_mac_sandbox_operation_denied(operation)) {
        if (results != NULL && pt_is_valid_user_pointer(results)) {
            memset(results, 1, count);
            return 0;
        }
        return pt_orig_sandbox_check_bulk(au, operation, flags, count, paths, results);
    }
    if (paths == NULL || !pt_is_valid_user_pointer(paths)) {
        return pt_orig_sandbox_check_bulk(au, operation, flags, count, paths, results);
    }
    const char **rewritten = (const char **)calloc(count, sizeof(const char *));
    char (*vbufs)[PATH_MAX] = (char (*)[PATH_MAX])malloc((size_t)count * PATH_MAX);
    BOOL *deny_mask = (BOOL *)calloc(count, sizeof(BOOL));
    if (rewritten == NULL || vbufs == NULL || deny_mask == NULL) {
        free(rewritten);
        free(vbufs);
        free(deny_mask);
        return pt_orig_sandbox_check_bulk(au, operation, flags, count, paths, results);
    }
    for (uint32_t i = 0; i < count; i++) {
        const char *p = paths[i];
        const char *resolved = p;
        int is_sys_flag = 0;
        pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(
            p, caller, vbufs[i], PATH_MAX, &resolved, &is_sys_flag);
        if (disp == PT_FS_PATH_HIDDEN || disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
            deny_mask[i] = YES;
        }
        rewritten[i] = resolved;
    }
    int ret = pt_orig_sandbox_check_bulk(au, operation, flags, count, rewritten, results);
    if (ret == 0 && results != NULL && pt_is_valid_user_pointer(results)) {
        for (uint32_t i = 0; i < count; i++) {
            if (deny_mask[i]) {
                results[i] = 1;
            }
        }
    }
    free(rewritten);
    free(vbufs);
    free(deny_mask);
    return ret;
}

static int pt_mac_syscall(const char *policy, int call, void *arg) {
    BOOL handled = NO;
    int ret = pt_mac_syscall_with_caller(policy, call, arg, __builtin_return_address(0), &handled);
    if (handled) {
        return ret;
    }
    return pt_orig_mac_syscall(policy, call, arg);
}

PT_INTERPOSE(pt_SecTaskCopyValueForEntitlement, SecTaskCopyValueForEntitlement)
PT_INTERPOSE(pt_SecTaskCopyValuesForEntitlements, SecTaskCopyValuesForEntitlements)
PT_INTERPOSE(pt_SecTaskGetCodeSignStatus, SecTaskGetCodeSignStatus)
PT_INTERPOSE(pt_SecTaskCopySigningIdentifier, SecTaskCopySigningIdentifier)
PT_INTERPOSE_ONLY(pt_SecCodeCopySelf, SecCodeCopySelf)
PT_INTERPOSE_ONLY(pt_SecCodeCopyStaticCode, SecCodeCopyStaticCode)
PT_INTERPOSE_ONLY(pt_SecCodeCopyPath, SecCodeCopyPath)
PT_INTERPOSE_ONLY(pt_SecCodeCopySigningInformation, SecCodeCopySigningInformation)
PT_INTERPOSE_ONLY(pt_SecCodeCheckValidity, SecCodeCheckValidity)
PT_INTERPOSE_ONLY(pt_SecCodeCheckValidityWithErrors, SecCodeCheckValidityWithErrors)
PT_INTERPOSE_ONLY(pt_SecStaticCodeCreateWithPath, SecStaticCodeCreateWithPath)
PT_INTERPOSE_ONLY(pt_SecStaticCodeCreateWithPathAndAttributes, SecStaticCodeCreateWithPathAndAttributes)
PT_INTERPOSE_ONLY(pt_SecStaticCodeCheckValidity, SecStaticCodeCheckValidity)
PT_INTERPOSE_ONLY(pt_SecStaticCodeCheckValidityWithErrors, SecStaticCodeCheckValidityWithErrors)
PT_INTERPOSE(pt_csops, csops)
PT_INTERPOSE(pt_csops_audittoken, csops_audittoken)
extern void pt_orig_raw_ptrace(void) __asm__("___ptrace") __attribute__((weak_import));

PT_INTERPOSE(pt_ptrace, ptrace)
PT_INTERPOSE_WEAK_NAMED(pt_ptrace, pt_orig_raw_ptrace, "__ptrace")
PT_INTERPOSE_WEAK_NAMED(pt_amfi_check_dyld_policy_self, pt_orig_amfi_check_dyld_policy_self, "amfi_check_dyld_policy_self")
PT_INTERPOSE(pt_sandbox_extension_issue_file, sandbox_extension_issue_file)
PT_INTERPOSE(pt_sandbox_extension_issue_file_to_self, sandbox_extension_issue_file_to_self)
PT_INTERPOSE(pt_sandbox_extension_issue_file_to_process, sandbox_extension_issue_file_to_process)
PT_INTERPOSE(pt_sandbox_extension_issue_file_to_process_by_pid, sandbox_extension_issue_file_to_process_by_pid)
PT_INTERPOSE(pt_sandbox_check, sandbox_check)
PT_INTERPOSE(pt_sandbox_check_by_audit_token, sandbox_check_by_audit_token)
PT_INTERPOSE_WEAK_NAMED(pt_sandbox_check_by_uniqueid, pt_orig_sandbox_check_by_uniqueid, "sandbox_check_by_uniqueid")
PT_INTERPOSE_WEAK_NAMED(pt_sandbox_check_by_reference, pt_orig_sandbox_check_by_reference, "sandbox_check_by_reference")
PT_INTERPOSE_WEAK_NAMED(pt_sandbox_check_bulk, pt_orig_sandbox_check_bulk, "sandbox_check_bulk")
PT_INTERPOSE_NAMED(pt_mac_syscall, pt_orig_mac_syscall, "__mac_syscall")
