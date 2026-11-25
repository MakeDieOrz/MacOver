//
//  PTNetworkRules.m
//  PlayTools
//

#import "PSInternal.h"
#include <time.h>

__attribute__((visibility("hidden")))
@implementation PSNetworkRuleSnapshot
@end

enum {
    PS_NET_FAST_UNINIT = 0,
    PS_NET_FAST_DISABLED = 1,
    PS_NET_FAST_ENABLED = 2
};

static os_unfair_lock s_net_rule_lock = OS_UNFAIR_LOCK_INIT;
static PSNetworkRuleSnapshot *s_net_rule_snapshot = nil;
static _Atomic time_t s_net_last_check = 0;
static _Atomic int s_net_fast_state = PS_NET_FAST_UNINIT;
__attribute__((visibility("hidden"))) _Atomic bool s_net_mock200_cached = true;
static _Atomic bool s_tls_custom_ca_active = false;
static time_t s_net_last_mtime = 0;
static long s_net_last_mtimensec = 0;
static time_t s_certs_last_mtime = 0;
static long s_certs_last_mtimensec = 0;
static BOOL s_certs_last_exists = NO;

static NSString *ps_extract_host_pattern_from_allow_url_rule(NSString *rule, BOOL *outHostless) {
    if (rule.length == 0 || [rule hasPrefix:@"/"] || [rule hasPrefix:@"*/"] || [rule hasPrefix:@"?"]) {
        *outHostless = YES;
        return nil;
    }
    NSString *rest = rule;
    BOOL anchoredHost = NO;
    NSRange firstSlash = [rule rangeOfString:@"/"];
    NSRange schemeSep = [rule rangeOfString:@"://"];
    if (schemeSep.location != NSNotFound &&
        (firstSlash.location == NSNotFound || schemeSep.location < firstSlash.location)) {
        rest = [rule substringFromIndex:schemeSep.location + 3];
        anchoredHost = YES;
    } else if ([rule hasPrefix:@"||"]) {
        rest = [rule substringFromIndex:2];
        anchoredHost = YES;
    } else if ([rule hasPrefix:@"//"]) {
        rest = [rule substringFromIndex:2];
        anchoredHost = YES;
    }
    NSRange slashInRest = [rest rangeOfString:@"/"];
    NSString *authority = (slashInRest.location != NSNotFound)
        ? [rest substringToIndex:slashInRest.location]
        : rest;
    while ([authority hasSuffix:@"^"]) {
        authority = [authority substringToIndex:authority.length - 1];
    }
    NSRange atRange = [authority rangeOfString:@"@" options:NSBackwardsSearch];
    if (atRange.location != NSNotFound) {
        authority = [authority substringFromIndex:atRange.location + 1];
    }
    if (![authority hasPrefix:@"["]) {
        NSRange colonRange = [authority rangeOfString:@":"];
        if (colonRange.location != NSNotFound) {
            authority = [authority substringToIndex:colonRange.location];
        }
    }
    NSString *strippedWildcards = [authority stringByReplacingOccurrencesOfString:@"*" withString:@""];
    if (authority.length == 0 || strippedWildcards.length == 0) {
        *outHostless = YES;
        return nil;
    }
    if (!anchoredHost && ![authority hasPrefix:@"*"]) {
        return [@"*" stringByAppendingString:authority];
    }
    return authority;
}

static BOOL ps_is_valid_scheme_regex_char(unichar ch) {
    return ((ch >= 'a' && ch <= 'z') ||
            (ch >= 'A' && ch <= 'Z') ||
            (ch >= '0' && ch <= '9') ||
            ch == '^' || ch == '+' || ch == '-' || ch == '?' ||
            ch == '(' || ch == ')' || ch == ':' || ch == '|' ||
            ch == '[' || ch == ']');
}

static NSRegularExpression *ps_build_dns_exempt_regex_from_pattern(NSString *pattern, BOOL *outHostless) {
    if (pattern.length == 0 || [pattern hasPrefix:@"/"] || [pattern hasPrefix:@"^/"]) {
        *outHostless = YES;
        return nil;
    }

    NSUInteger len = pattern.length;
    NSRange schemeRange = [pattern rangeOfString:@"://"];
    NSUInteger scanStart = 0;
    BOOL hasScheme = NO;
    if (schemeRange.location != NSNotFound) {
        BOOL safeBeforeScheme = (schemeRange.location > 0);
        BOOL esc = NO;
        int pDepth = 0;
        int cDepth = 0;
        for (NSUInteger i = 0; i < schemeRange.location; i++) {
            unichar ch = [pattern characterAtIndex:i];
            if (esc) {
                esc = NO;
                if (ch != '+' && ch != '-') {
                    safeBeforeScheme = NO;
                    break;
                }
                continue;
            }
            if (ch == '\\') { esc = YES; continue; }
            if (cDepth > 0) {
                if (ch == ']') cDepth--;
                if (!ps_is_valid_scheme_regex_char(ch)) {
                    safeBeforeScheme = NO;
                    break;
                }
                continue;
            }
            if (ch == '[') { cDepth++; continue; }
            if (ch == '(') { pDepth++; continue; }
            if (ch == ')') {
                if (pDepth == 0) {
                    safeBeforeScheme = NO;
                    break;
                }
                pDepth--;
                continue;
            }
            if ((ch == '|' && pDepth == 0) || !ps_is_valid_scheme_regex_char(ch)) {
                safeBeforeScheme = NO;
                break;
            }
        }
        if (safeBeforeScheme && !esc && pDepth == 0 && cDepth == 0) {
            hasScheme = YES;
            scanStart = schemeRange.location + 3;
        } else {
            *outHostless = YES;
            return nil;
        }
    }

    BOOL esc = NO;
    int pDepth = 0;
    int cDepth = 0;
    NSUInteger cutPos = NSNotFound;
    BOOL unsafeAuthorityConstruct = NO;
    for (NSUInteger i = scanStart; i < len; i++) {
        unichar ch = [pattern characterAtIndex:i];
        if (esc) { esc = NO; continue; }
        if (ch == '\\') { esc = YES; continue; }
        if (cDepth > 0) {
            if (ch == ':') {
                unsafeAuthorityConstruct = YES;
            }
            if (ch == ']') cDepth--;
            continue;
        }
        if (ch == '[') { cDepth++; continue; }
        if (ch == '(') { pDepth++; continue; }
        if (ch == ')') {
            if (pDepth == 0) {
                unsafeAuthorityConstruct = YES;
                break;
            }
            pDepth--;
            continue;
        }
        if (ch == '@') {
            unsafeAuthorityConstruct = YES;
            break;
        }
        if (ch == '/') {
            if (pDepth == 0) {
                cutPos = i;
                break;
            } else {
                unsafeAuthorityConstruct = YES;
                break;
            }
        }
    }

    if (unsafeAuthorityConstruct || esc || pDepth != 0 || cDepth != 0) {
        *outHostless = YES;
        return nil;
    }

    NSUInteger authEnd = (cutPos != NSNotFound) ? cutPos : len;
    if (authEnd <= scanStart) {
        *outHostless = YES;
        return nil;
    }
    NSString *authorityExpr = [pattern substringWithRange:NSMakeRange(scanStart, authEnd - scanStart)];
    NSUInteger aLen = authorityExpr.length;
    NSMutableString *cleanHost = [NSMutableString stringWithCapacity:aLen];
    BOOL strippedTrailingTopPort = NO;
    int gDepth = 0;
    int clsDepth = 0;
    NSUInteger idx = 0;

    while (idx < aLen) {
        unichar ch = [authorityExpr characterAtIndex:idx];
        BOOL isPortColon = NO;
        NSUInteger afterColonIdx = idx;

        if (ch == '\\') {
            if (idx + 1 >= aLen) {
                *outHostless = YES;
                return nil;
            }
            unichar next = [authorityExpr characterAtIndex:idx + 1];
            if (clsDepth == 0 && next == ':') {
                isPortColon = YES;
                afterColonIdx = idx + 2;
            } else {
                [cleanHost appendFormat:@"\\%C", next];
                idx += 2;
                continue;
            }
        } else if (clsDepth > 0) {
            if (ch == ']') clsDepth--;
            [cleanHost appendFormat:@"%C", ch];
            idx++;
            continue;
        } else if (ch == '[') {
            clsDepth++;
            [cleanHost appendString:@"["];
            idx++;
            continue;
        } else if (ch == '(') {
            gDepth++;
            [cleanHost appendString:@"("];
            idx++;
            if (idx < aLen && [authorityExpr characterAtIndex:idx] == '?') {
                [cleanHost appendString:@"?"];
                idx++;
                if (idx >= aLen) {
                    *outHostless = YES;
                    return nil;
                }
                unichar qch = [authorityExpr characterAtIndex:idx];
                if (qch == '=' || qch == '!' || qch == '<') {
                    *outHostless = YES;
                    return nil;
                }
                while (idx < aLen) {
                    unichar fch = [authorityExpr characterAtIndex:idx];
                    if ((fch >= 'a' && fch <= 'z') || (fch >= 'A' && fch <= 'Z') || fch == '-') {
                        [cleanHost appendFormat:@"%C", fch];
                        idx++;
                    } else {
                        break;
                    }
                }
                if (idx < aLen && [authorityExpr characterAtIndex:idx] == ':') {
                    [cleanHost appendString:@":"];
                    idx++;
                }
            }
            continue;
        } else if (ch == ')') {
            if (gDepth > 0) gDepth--;
            [cleanHost appendString:@")"];
            idx++;
            continue;
        } else if (ch == ':') {
            isPortColon = YES;
            afterColonIdx = idx + 1;
        }

        if (isPortColon) {
            int baseDepth = gDepth;
            idx = afterColonIdx;
            BOOL portEsc = NO;
            int portClsDepth = 0;
            while (idx < aLen) {
                unichar pch = [authorityExpr characterAtIndex:idx];
                if (portEsc) {
                    portEsc = NO;
                    idx++;
                    continue;
                }
                if (pch == '\\') {
                    portEsc = YES;
                    idx++;
                    continue;
                }
                if (portClsDepth > 0) {
                    if (pch == ']') portClsDepth--;
                    idx++;
                    continue;
                }
                if (pch == '[') {
                    portClsDepth++;
                    idx++;
                    continue;
                }
                if (pch == '(') {
                    gDepth++;
                    idx++;
                    continue;
                }
                if (pch == ')') {
                    if (gDepth == baseDepth) {
                        break;
                    }
                    gDepth--;
                    idx++;
                    continue;
                }
                if (gDepth == baseDepth && (pch == '|' || pch == '$')) {
                    break;
                }
                idx++;
            }
            if (baseDepth == 0 && (idx == aLen || (idx < aLen && [authorityExpr characterAtIndex:idx] == '$'))) {
                strippedTrailingTopPort = YES;
            }
            continue;
        }

        [cleanHost appendFormat:@"%C", ch];
        idx++;
    }

    if (cleanHost.length == 0) {
        *outHostless = YES;
        return nil;
    }

    BOOL rightBounded = (cutPos != NSNotFound || strippedTrailingTopPort);
    NSString *compiledPat = nil;
    if (hasScheme) {
        compiledPat = rightBounded
            ? [NSString stringWithFormat:@"^(?:https?://)?%@(?:$|[:/])", cleanHost]
            : [NSString stringWithFormat:@"^(?:https?://)?%@", cleanHost];
    } else {
        compiledPat = rightBounded
            ? [NSString stringWithFormat:@"%@(?:$|[:/])", cleanHost]
            : cleanHost;
    }

    NSRegularExpression *hostRe = [NSRegularExpression regularExpressionWithPattern:compiledPat
                                                                            options:NSRegularExpressionCaseInsensitive
                                                                              error:nil];
    if (hostRe == nil) {
        *outHostless = YES;
        return nil;
    }
    NSString *canaryHttps = @"https://__playtools_canary_host__.invalid/";
    NSString *canaryHttp = @"http://__playtools_canary_host__.invalid/";
    NSString *canaryBare = @"__playtools_canary_host__.invalid/";
    if ([hostRe firstMatchInString:canaryHttps options:0 range:NSMakeRange(0, canaryHttps.length)] != nil ||
        [hostRe firstMatchInString:canaryHttp options:0 range:NSMakeRange(0, canaryHttp.length)] != nil ||
        [hostRe firstMatchInString:canaryBare options:0 range:NSMakeRange(0, canaryBare.length)] != nil) {
        *outHostless = YES;
        return nil;
    }
    return hostRe;
}

static NSString *ps_strip_inline_comment(NSString *raw) {
    if (raw == nil) return @"";
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0 ||
        [trimmed hasPrefix:@"#"] ||
        [trimmed hasPrefix:@"//"] ||
        [trimmed hasPrefix:@";"] ||
        [trimmed hasPrefix:@"! "] ||
        [trimmed hasPrefix:@"!\t"] ||
        [trimmed hasPrefix:@"!["] ||
        [trimmed isEqualToString:@"!"]) {
        return @"";
    }
    NSUInteger len = trimmed.length;
    BOOL esc = NO;
    int clsDepth = 0;
    for (NSUInteger i = 0; i < len; i++) {
        unichar ch = [trimmed characterAtIndex:i];
        if (esc) {
            esc = NO;
            continue;
        }
        if (ch == '\\') {
            esc = YES;
            continue;
        }
        if (clsDepth > 0) {
            if (ch == ']') clsDepth--;
            continue;
        }
        if (ch == '[') {
            clsDepth++;
            continue;
        }
        if (i > 0) {
            unichar prev = [trimmed characterAtIndex:i - 1];
            if (prev == ' ' || prev == '\t') {
                if (ch == '#' || (ch == '/' && (i + 1) < len && [trimmed characterAtIndex:i + 1] == '/')) {
                    return [[trimmed substringToIndex:i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                }
            }
        }
    }
    return trimmed;
}

static BOOL ps_parse_action_token(NSString *token, BOOL *ioIsAllow, PSNetRuleAction *ioAction) {
    NSString *upper = [[token stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] uppercaseString];
    if ([upper isEqualToString:@"DIRECT"] || [upper isEqualToString:@"ALLOW"]) {
        if (ioIsAllow) *ioIsAllow = YES;
        return YES;
    }
    if ([upper isEqualToString:@"MOCK-200"] ||
        [upper isEqualToString:@"MOCK200"] ||
        [upper isEqualToString:@"REJECT-DICT"] ||
        [upper isEqualToString:@"REJECT-200"] ||
        [upper isEqualToString:@"REJECT-EMPTY"]) {
        if (ioAction) *ioAction = PSNetRuleActionForceMock200;
        return YES;
    }
    if ([upper isEqualToString:@"REJECT-DROP"] ||
        [upper isEqualToString:@"REJECT-ERROR"] ||
        [upper isEqualToString:@"REJECT-NO-DROP"] ||
        [upper isEqualToString:@"FAIL"]) {
        if (ioAction) *ioAction = PSNetRuleActionForceFail;
        return YES;
    }
    if ([upper isEqualToString:@"REJECT"] ||
        [upper isEqualToString:@"BLOCK"] ||
        [upper isEqualToString:@"PROXY"] ||
        [upper isEqualToString:@"REJECT-TINYGIF"]) {
        if (ioAction) *ioAction = PSNetRuleActionDefault;
        return YES;
    }
    if ([upper isEqualToString:@"NO-RESOLVE"] ||
        [upper isEqualToString:@"PRE-MATCH"] ||
        [upper isEqualToString:@"EXTENDED-MATCHING"]) {
        return YES;
    }
    return NO;
}

static NSString *ps_normalize_plain_host_token(NSString *rawHost, BOOL exactOnly) {
    NSString *h = [[rawHost stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    while ([h hasSuffix:@"^"]) {
        h = [h substringToIndex:h.length - 1];
    }
    if (![h hasPrefix:@"["]) {
        NSRange colon = [h rangeOfString:@":"];
        if (colon.location != NSNotFound) {
            h = [h substringToIndex:colon.location];
        }
    }
    if (h.length == 0) return @"";
    if (exactOnly) {
        if ([h hasPrefix:@"."]) {
            h = [h substringFromIndex:1];
        }
        return h.length > 0 ? [@"=" stringByAppendingString:h] : @"";
    }
    if ([h hasPrefix:@"*."]) {
        return [h substringFromIndex:1];
    }
    return h;
}

static void ps_append_escaped_regex_char(NSMutableString *out,
                                         unichar ch,
                                         BOOL treatStarAsWildcard,
                                         BOOL wildcardNoSlash,
                                         BOOL treatCaretAsSep) {
    if (ch == '*' && treatStarAsWildcard) {
        [out appendString:(wildcardNoSlash ? @"[^/?#:]*" : @".*")];
        return;
    }
    if (ch == '^' && treatCaretAsSep) {
        [out appendString:@"(?:$|[/?#&])"];
        return;
    }
    switch (ch) {
        case '\\': case '^': case '$': case '.': case '|': case '?':
        case '*':  case '+': case '(': case ')': case '[': case ']':
        case '{':  case '}':
            [out appendFormat:@"\\%C", ch];
            break;
        default:
            [out appendFormat:@"%C", ch];
            break;
    }
}

static NSRegularExpression *ps_compile_adblock_anchor_rule(NSString *afterDoublePipe,
                                                           NSString **outPureHost,
                                                           NSString **outAuthorityHost) {
    if (outPureHost) *outPureHost = nil;
    if (outAuthorityHost) *outAuthorityHost = nil;
    if (afterDoublePipe.length == 0) return nil;

    NSString *s = [afterDoublePipe stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSRange dollar = [s rangeOfString:@"$" options:NSBackwardsSearch];
    if (dollar.location != NSNotFound && dollar.location + 1 < s.length) {
        NSString *opt = [s substringFromIndex:dollar.location + 1];
        BOOL allOptChars = YES;
        BOOL hasAsciiLetter = NO;
        for (NSUInteger i = 0; i < opt.length; i++) {
            unichar ch = [opt characterAtIndex:i];
            if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')) {
                hasAsciiLetter = YES;
            } else if (!((ch >= '0' && ch <= '9') || ch == ',' || ch == '~' || ch == '=' || ch == '-')) {
                allOptChars = NO;
                break;
            }
        }
        if (allOptChars && hasAsciiLetter) {
            s = [s substringToIndex:dollar.location];
        }
    }
    if (s.length == 0) return nil;

    NSRange slashOrQuery = [s rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/?"]];
    if (slashOrQuery.location == NSNotFound) {
        NSString *pure = ps_normalize_plain_host_token(s, NO);
        if (pure.length > 0 && outPureHost) {
            *outPureHost = pure;
        }
        return nil;
    }

    NSString *authorityRaw = [s substringToIndex:slashOrQuery.location];
    NSString *pathPart = [s substringFromIndex:slashOrQuery.location];
    while ([authorityRaw hasSuffix:@"^"]) {
        authorityRaw = [authorityRaw substringToIndex:authorityRaw.length - 1];
    }
    if (outAuthorityHost) {
        NSString *authHost = ps_normalize_plain_host_token(authorityRaw, NO);
        if (authHost.length > 0) {
            *outAuthorityHost = authHost;
        }
    }

    NSString *authLower = [authorityRaw lowercaseString];
    NSString *explicitPort = nil;
    if (![authLower hasPrefix:@"["]) {
        NSRange colon = [authLower rangeOfString:@":"];
        if (colon.location != NSNotFound) {
            NSString *portCandidate = [authLower substringFromIndex:colon.location + 1];
            BOOL allDigits = portCandidate.length > 0;
            for (NSUInteger i = 0; i < portCandidate.length; i++) {
                unichar c = [portCandidate characterAtIndex:i];
                if (c < '0' || c > '9') { allDigits = NO; break; }
            }
            if (allDigits) {
                explicitPort = portCandidate;
                authLower = [authLower substringToIndex:colon.location];
            }
        }
    }

    NSMutableString *pat = [NSMutableString stringWithString:@"^[a-z][a-z0-9+.-]*://"];
    NSString *hostBody = authLower;
    if ([hostBody hasPrefix:@"*."]) {
        hostBody = [hostBody substringFromIndex:2];
    } else if ([hostBody hasPrefix:@"."]) {
        hostBody = [hostBody substringFromIndex:1];
    }
    [pat appendString:@"(?:[^/?#:]*\\.)?"];
    for (NSUInteger i = 0; i < hostBody.length; i++) {
        ps_append_escaped_regex_char(pat, [hostBody characterAtIndex:i], YES, YES, NO);
    }
    if (explicitPort.length > 0) {
        [pat appendFormat:@":%@", explicitPort];
    } else {
        [pat appendString:@"(?::\\d+)?"];
    }

    BOOL endAnchor = NO;
    if ([pathPart hasSuffix:@"$"]) {
        endAnchor = YES;
        pathPart = [pathPart substringToIndex:pathPart.length - 1];
    }
    for (NSUInteger i = 0; i < pathPart.length; i++) {
        ps_append_escaped_regex_char(pat, [pathPart characterAtIndex:i], YES, NO, YES);
    }
    if (endAnchor) {
        [pat appendString:@"$"];
    }
    return [NSRegularExpression regularExpressionWithPattern:pat
                                                    options:NSRegularExpressionCaseInsensitive
                                                      error:nil];
}

static pthread_mutex_t s_net_reload_mutex = PTHREAD_MUTEX_INITIALIZER;

__attribute__((visibility("hidden"))) BOOL ps_is_network_blocking_possibly_active(void) {
    if ([PTSafeMode isActive]) {
        return NO;
    }
    int st = atomic_load_explicit(&s_net_fast_state, memory_order_acquire);
    if (st == PS_NET_FAST_DISABLED) {
        time_t now = time(NULL);
        time_t last = atomic_load_explicit(&s_net_last_check, memory_order_relaxed);
        if ((now - last) < 10) {
            return NO;
        }
    }
    return YES;
}

__attribute__((visibility("hidden"))) PSNetworkRuleSnapshot *ps_get_network_snapshot(void) {
    if ([PTSafeMode isActive]) {
        return nil;
    }
    time_t now = time(NULL);

    os_unfair_lock_lock(&s_net_rule_lock);
    PSNetworkRuleSnapshot *current = s_net_rule_snapshot;
    time_t lastCheck = atomic_load_explicit(&s_net_last_check, memory_order_relaxed);
    BOOL freshEnough = (current != nil && (now - lastCheck) < 2);
    os_unfair_lock_unlock(&s_net_rule_lock);
    if (freshEnough) {
        return current;
    }

    pthread_mutex_lock(&s_net_reload_mutex);
    @try {
        now = time(NULL);
        os_unfair_lock_lock(&s_net_rule_lock);
        current = s_net_rule_snapshot;
        lastCheck = atomic_load_explicit(&s_net_last_check, memory_order_relaxed);
        if (current != nil && (now - lastCheck) < 2) {
            os_unfair_lock_unlock(&s_net_rule_lock);
            return current;
        }
        os_unfair_lock_unlock(&s_net_rule_lock);

        @autoreleasepool {
            NSString *plistPath = ps_app_settings_plist_path();
            if (plistPath.length == 0) {
                return current;
            }
            NSString *certsPath = [plistPath stringByAppendingString:@".certs"];
            struct stat st;
            struct stat certsSt;
            BOOL plistExists = (stat([plistPath fileSystemRepresentation], &st) == 0);
            BOOL certsExists = (stat([certsPath fileSystemRepresentation], &certsSt) == 0);

            if (!plistExists) {
                if (current == nil) {
                    PSNetworkRuleSnapshot *empty = [[PSNetworkRuleSnapshot alloc] init];
                    empty.enabled = NO;
                    empty.mock200 = YES;
                    empty.hasHostlessAllowRule = NO;
                    empty.hostRules = @[];
                    empty.hostRuleActions = @[];
                    empty.urlRules = @[];
                    empty.urlRuleActions = @[];
                    empty.regexRules = @[];
                    empty.regexRuleActions = @[];
                    empty.allowHostRules = @[];
                    empty.allowUrlRules = @[];
                    empty.allowRegexRules = @[];
                    empty.dnsExemptHostPatterns = @[];
                    empty.dnsExemptHostRegexes = @[];
                    empty.mitmAllHosts = YES;
                    empty.hideProxyFromApp = YES;
                    empty.mitmHostRules = @[];
                    empty.customCertificates = @[];
                    empty.activeProxyDictionary = @{};
                    os_unfair_lock_lock(&s_net_rule_lock);
                    s_net_rule_snapshot = empty;
                    atomic_store_explicit(&s_net_mock200_cached, true, memory_order_relaxed);
                    atomic_store_explicit(&s_tls_custom_ca_active, false, memory_order_release);
                    atomic_store_explicit(&s_net_fast_state, PS_NET_FAST_DISABLED, memory_order_release);
                    atomic_store_explicit(&s_net_last_check, now, memory_order_relaxed);
                    current = empty;
                    os_unfair_lock_unlock(&s_net_rule_lock);
                } else {
                    atomic_store_explicit(&s_net_last_check, now, memory_order_relaxed);
                }
                return current;
            }

            os_unfair_lock_lock(&s_net_rule_lock);
            BOOL plistUnchanged = (current != nil &&
                                   st.st_mtimespec.tv_sec == s_net_last_mtime &&
                                   st.st_mtimespec.tv_nsec == s_net_last_mtimensec);
            BOOL certsUnchanged = (certsExists == s_certs_last_exists &&
                                   (!certsExists ||
                                    (certsSt.st_mtimespec.tv_sec == s_certs_last_mtime &&
                                     certsSt.st_mtimespec.tv_nsec == s_certs_last_mtimensec)));
            BOOL unchanged = plistUnchanged && certsUnchanged;
            if (unchanged) {
                atomic_store_explicit(&s_net_last_check, now, memory_order_relaxed);
            }
            os_unfair_lock_unlock(&s_net_rule_lock);
            if (unchanged) {
                return current;
            }

            NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            PSNetworkRuleSnapshot *next = [[PSNetworkRuleSnapshot alloc] init];
        next.enabled = [dict[@"enableNetworkRules"] boolValue];
        NSNumber *mockNum = dict[@"networkBlockMock200"];
        next.mock200 = (mockNum != nil) ? [mockNum boolValue] : YES;

        NSString *proxyMode = [dict[@"networkProxyMode"] isKindOfClass:[NSString class]]
            ? (NSString *)dict[@"networkProxyMode"]
            : @"direct";
        NSString *extProto = [dict[@"externalProxyProtocol"] isKindOfClass:[NSString class]]
            ? (NSString *)dict[@"externalProxyProtocol"]
            : @"http";
        NSString *extHost = [dict[@"externalProxyHost"] isKindOfClass:[NSString class]]
            ? [(NSString *)dict[@"externalProxyHost"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
            : @"";
        NSInteger extPort = [dict[@"externalProxyPort"] integerValue];
        NSInteger mitmCfgPort = [dict[@"mitmPort"] integerValue];
        NSInteger mitmRunPort = [dict[@"mitmRuntimePort"] integerValue];
        BOOL isBuiltInMITM = [proxyMode isEqualToString:@"builtInMITM"];

        next.enableCustomCertificates = [dict[@"enableCustomCertificates"] boolValue] || isBuiltInMITM;
        NSNumber *mitmAllNum = dict[@"mitmAllHosts"];
        next.mitmAllHosts = (mitmAllNum != nil) ? [mitmAllNum boolValue] : YES;
        next.mitmAllowPinningBypass = [dict[@"mitmAllowPinningBypass"] boolValue];
        NSNumber *hideProxyNum = dict[@"hideProxyFromApp"];
        next.hideProxyFromApp = (hideProxyNum != nil) ? [hideProxyNum boolValue] : YES;

        NSMutableArray<NSString *> *parsedMitmHosts = [NSMutableArray array];
        NSArray *rawMitmHosts = dict[@"mitmHostPatterns"];
        if ([rawMitmHosts isKindOfClass:[NSArray class]]) {
            for (id entry in rawMitmHosts) {
                if (![entry isKindOfClass:[NSString class]]) continue;
                NSString *tok = ps_normalize_plain_host_token((NSString *)entry, NO);
                if (tok.length > 0) {
                    [parsedMitmHosts addObject:tok];
                }
            }
        }
        next.mitmHostRules = [parsedMitmHosts copy];

        NSMutableDictionary<NSString *, id> *proxyDict = [NSMutableDictionary dictionary];
        if (isBuiltInMITM) {
            NSInteger activePort = (mitmRunPort > 0) ? mitmRunPort : mitmCfgPort;
            if (activePort > 0 && activePort <= 65535) {
                next.proxyHost = @"127.0.0.1";
                next.proxyPort = activePort;
                next.proxyIsSOCKS5 = NO;
                proxyDict[@"HTTPEnable"] = @YES;
                proxyDict[@"HTTPProxy"] = @"127.0.0.1";
                proxyDict[@"HTTPPort"] = @(activePort);
                proxyDict[@"HTTPSEnable"] = @YES;
                proxyDict[@"HTTPSProxy"] = @"127.0.0.1";
                proxyDict[@"HTTPSPort"] = @(activePort);
            }
        } else if ([proxyMode isEqualToString:@"external"] && extHost.length > 0 && extPort > 0 && extPort <= 65535) {
            next.proxyHost = extHost;
            next.proxyPort = extPort;
            if ([extProto caseInsensitiveCompare:@"socks5"] == NSOrderedSame) {
                next.proxyIsSOCKS5 = YES;
                proxyDict[@"SOCKSEnable"] = @YES;
                proxyDict[@"SOCKSProxy"] = extHost;
                proxyDict[@"SOCKSPort"] = @(extPort);
            } else {
                next.proxyIsSOCKS5 = NO;
                proxyDict[@"HTTPEnable"] = @YES;
                proxyDict[@"HTTPProxy"] = extHost;
                proxyDict[@"HTTPPort"] = @(extPort);
                proxyDict[@"HTTPSEnable"] = @YES;
                proxyDict[@"HTTPSProxy"] = extHost;
                proxyDict[@"HTTPSPort"] = @(extPort);
            }
        }
        next.activeProxyDictionary = [proxyDict copy];

        NSMutableArray *parsedCerts = [NSMutableArray array];
        if (next.enableCustomCertificates && certsExists) {
            NSDictionary *certsDict = [NSDictionary dictionaryWithContentsOfFile:certsPath];
            NSArray *certDatas = certsDict[@"certificates"];
            if ([certDatas isKindOfClass:[NSArray class]]) {
                for (id item in certDatas) {
                    if (![item isKindOfClass:[NSData class]]) continue;
                    SecCertificateRef certRef = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)(NSData *)item);
                    if (certRef != NULL) {
                        [parsedCerts addObject:CFBridgingRelease(certRef)];
                    }
                }
            }
        }
        next.customCertificates = [parsedCerts copy];

        BOOL hasHostlessAllow = NO;
        NSMutableArray<NSString *> *hosts = [NSMutableArray array];
        NSMutableArray<NSNumber *> *hostActions = [NSMutableArray array];
        NSMutableArray<NSString *> *urls = [NSMutableArray array];
        NSMutableArray<NSNumber *> *urlActions = [NSMutableArray array];
        NSMutableArray<NSRegularExpression *> *regexes = [NSMutableArray array];
        NSMutableArray<NSNumber *> *regexActions = [NSMutableArray array];
        NSMutableArray<NSString *> *allowHosts = [NSMutableArray array];
        NSMutableArray<NSString *> *allowUrls = [NSMutableArray array];
        NSMutableArray<NSRegularExpression *> *allowRegexes = [NSMutableArray array];
        NSMutableArray<NSString *> *dnsExemptHosts = [NSMutableArray array];
        NSMutableArray<NSRegularExpression *> *dnsExemptRegexes = [NSMutableArray array];
        NSArray *rawList = dict[@"blockedURLPatterns"];
        if (next.enabled && [rawList isKindOfClass:[NSArray class]]) {
            for (id item in rawList) {
                if (![item isKindOfClass:[NSString class]]) continue;
                NSString *trimmed = ps_strip_inline_comment((NSString *)item);
                if (trimmed.length == 0) continue;

                BOOL isAllowRule = NO;
                PSNetRuleAction ruleAction = PSNetRuleActionDefault;
                if ([trimmed hasPrefix:@"@@"]) {
                    isAllowRule = YES;
                    trimmed = [[trimmed substringFromIndex:2] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                } else if ([trimmed hasPrefix:@"!"]) {
                    isAllowRule = YES;
                    trimmed = [[trimmed substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                }
                if (trimmed.length == 0) continue;

                NSRange firstComma = [trimmed rangeOfString:@","];
                if (firstComma.location != NSNotFound) {
                    NSString *kind = [[[trimmed substringToIndex:firstComma.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] uppercaseString];
                    NSString *rest = [[trimmed substringFromIndex:firstComma.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    BOOL isRegexKind = ([kind isEqualToString:@"URL-REGEX"] || [kind isEqualToString:@"REGEX"]);
                    BOOL isDomainExact = ([kind isEqualToString:@"DOMAIN"] || [kind isEqualToString:@"HOST"]);
                    BOOL isDomainSuffix = ([kind isEqualToString:@"DOMAIN-SUFFIX"] || [kind isEqualToString:@"HOST-SUFFIX"]);
                    BOOL isDomainKeyword = ([kind isEqualToString:@"DOMAIN-KEYWORD"] || [kind isEqualToString:@"HOST-KEYWORD"]);

                    if (isRegexKind) {
                        while (YES) {
                            NSRange lastComma = [rest rangeOfString:@"," options:NSBackwardsSearch];
                            if (lastComma.location == NSNotFound) break;
                            NSString *tail = [rest substringFromIndex:lastComma.location + 1];
                            if (ps_parse_action_token(tail, &isAllowRule, &ruleAction)) {
                                rest = [[rest substringToIndex:lastComma.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                            } else {
                                break;
                            }
                        }
                        if (rest.length > 0) {
                            NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:rest
                                                                                                options:NSRegularExpressionCaseInsensitive
                                                                                                  error:nil];
                            if (re != nil) {
                                if (isAllowRule) {
                                    [allowRegexes addObject:re];
                                    NSRegularExpression *hostRe = ps_build_dns_exempt_regex_from_pattern(rest, &hasHostlessAllow);
                                    if (hostRe != nil) {
                                        [dnsExemptRegexes addObject:hostRe];
                                    }
                                } else {
                                    [regexes addObject:re];
                                    [regexActions addObject:@(ruleAction)];
                                }
                            }
                            continue;
                        }
                    } else if (isDomainExact || isDomainSuffix || isDomainKeyword) {
                        NSArray<NSString *> *parts = [rest componentsSeparatedByString:@","];
                        NSString *val = [parts.firstObject stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        for (NSUInteger idx = 1; idx < parts.count; idx++) {
                            ps_parse_action_token(parts[idx], &isAllowRule, &ruleAction);
                        }
                        if (val.length > 0) {
                            NSString *hostToken = nil;
                            if (isDomainExact) {
                                hostToken = ps_normalize_plain_host_token(val, YES);
                            } else if (isDomainSuffix) {
                                NSString *norm = ps_normalize_plain_host_token(val, NO);
                                if (norm.length > 0) {
                                    if ([norm containsString:@"*"] || [norm hasPrefix:@"."]) {
                                        hostToken = norm;
                                    } else {
                                        hostToken = [@"." stringByAppendingString:norm];
                                    }
                                }
                            } else {
                                hostToken = [NSString stringWithFormat:@"*%@*", [val lowercaseString]];
                            }
                            if (hostToken.length > 0) {
                                NSString *clean = [NSString stringWithUTF8String:[hostToken UTF8String]] ?: hostToken;
                                if (isAllowRule) {
                                    [allowHosts addObject:clean];
                                } else {
                                    [hosts addObject:clean];
                                    [hostActions addObject:@(ruleAction)];
                                }
                                continue;
                            }
                        }
                    }
                }

                if ([trimmed hasPrefix:@"||"]) {
                    NSString *afterPipes = [trimmed substringFromIndex:2];
                    NSString *pureHost = nil;
                    NSString *authHost = nil;
                    NSRegularExpression *re = ps_compile_adblock_anchor_rule(afterPipes, &pureHost, &authHost);
                    if (pureHost.length > 0) {
                        NSString *clean = [NSString stringWithUTF8String:[pureHost UTF8String]] ?: pureHost;
                        if (isAllowRule) {
                            [allowHosts addObject:clean];
                        } else {
                            [hosts addObject:clean];
                            [hostActions addObject:@(ruleAction)];
                        }
                        continue;
                    }
                    if (re != nil) {
                        if (isAllowRule) {
                            [allowRegexes addObject:re];
                            NSString *stripped = [authHost stringByReplacingOccurrencesOfString:@"*" withString:@""];
                            if (authHost.length > 0 && stripped.length > 0) {
                                [dnsExemptHosts addObject:authHost];
                            } else {
                                hasHostlessAllow = YES;
                            }
                        } else {
                            [regexes addObject:re];
                            [regexActions addObject:@(ruleAction)];
                        }
                        continue;
                    }
                }

                if ([trimmed hasPrefix:@"^"] ||
                    ([trimmed hasPrefix:@"/"] && [trimmed hasSuffix:@"/"] && trimmed.length > 2)) {
                    NSString *pat = [trimmed hasPrefix:@"^"]
                        ? trimmed
                        : [trimmed substringWithRange:NSMakeRange(1, trimmed.length - 2)];
                    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat
                                                                                        options:NSRegularExpressionCaseInsensitive
                                                                                          error:nil];
                    if (re != nil) {
                        if (isAllowRule) {
                            [allowRegexes addObject:re];
                            NSRegularExpression *hostRe = ps_build_dns_exempt_regex_from_pattern(pat, &hasHostlessAllow);
                            if (hostRe != nil) {
                                [dnsExemptRegexes addObject:hostRe];
                            }
                        } else {
                            [regexes addObject:re];
                            [regexActions addObject:@(ruleAction)];
                        }
                        continue;
                    }
                }

                if ([trimmed hasPrefix:@"|"]) {
                    NSString *body = [trimmed substringFromIndex:1];
                    BOOL endAnchor = NO;
                    if (body.length > 1 && [body hasSuffix:@"|"]) {
                        endAnchor = YES;
                        body = [body substringToIndex:body.length - 1];
                    }
                    if (body.length > 0) {
                        NSMutableString *pat = [NSMutableString stringWithString:@"^"];
                        for (NSUInteger i = 0; i < body.length; i++) {
                            ps_append_escaped_regex_char(pat, [body characterAtIndex:i], YES, NO, YES);
                        }
                        if (endAnchor) {
                            [pat appendString:@"$"];
                        }
                        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pat
                                                                                            options:NSRegularExpressionCaseInsensitive
                                                                                              error:nil];
                        if (re != nil) {
                            if (isAllowRule) {
                                [allowRegexes addObject:re];
                                NSString *hostPat = ps_extract_host_pattern_from_allow_url_rule([body lowercaseString], &hasHostlessAllow);
                                if (hostPat.length > 0) {
                                    [dnsExemptHosts addObject:hostPat];
                                }
                            } else {
                                [regexes addObject:re];
                                [regexActions addObject:@(ruleAction)];
                            }
                            continue;
                        }
                    }
                }

                NSString *lower = [trimmed lowercaseString];
                if ([lower containsString:@"/"]) {
                    NSString *clean = [NSString stringWithUTF8String:[lower UTF8String]] ?: lower;
                    if (isAllowRule) {
                        [allowUrls addObject:clean];
                        NSString *hostPat = ps_extract_host_pattern_from_allow_url_rule(clean, &hasHostlessAllow);
                        if (hostPat.length > 0) {
                            [dnsExemptHosts addObject:hostPat];
                        }
                    } else {
                        [urls addObject:clean];
                        [urlActions addObject:@(ruleAction)];
                    }
                } else {
                    NSString *normHost = ps_normalize_plain_host_token(lower, NO);
                    if (normHost.length > 0) {
                        NSString *clean = [NSString stringWithUTF8String:[normHost UTF8String]] ?: normHost;
                        if (isAllowRule) {
                            [allowHosts addObject:clean];
                        } else {
                            [hosts addObject:clean];
                            [hostActions addObject:@(ruleAction)];
                        }
                    }
                }
            }
        }
        next.hasHostlessAllowRule = hasHostlessAllow;
        next.hostRules = [hosts copy];
        next.hostRuleActions = [hostActions copy];
        next.urlRules = [urls copy];
        next.urlRuleActions = [urlActions copy];
        next.regexRules = [regexes copy];
        next.regexRuleActions = [regexActions copy];
        next.allowHostRules = [allowHosts copy];
        next.allowUrlRules = [allowUrls copy];
        next.allowRegexRules = [allowRegexes copy];
        next.dnsExemptHostPatterns = [dnsExemptHosts copy];
        next.dnsExemptHostRegexes = [dnsExemptRegexes copy];

        os_unfair_lock_lock(&s_net_rule_lock);
        s_net_last_mtime = st.st_mtimespec.tv_sec;
        s_net_last_mtimensec = st.st_mtimespec.tv_nsec;
        s_certs_last_exists = certsExists;
        if (certsExists) {
            s_certs_last_mtime = certsSt.st_mtimespec.tv_sec;
            s_certs_last_mtimensec = certsSt.st_mtimespec.tv_nsec;
        } else {
            s_certs_last_mtime = 0;
            s_certs_last_mtimensec = 0;
        }
        s_net_rule_snapshot = next;
        atomic_store_explicit(&s_net_mock200_cached, next.mock200 ? true : false, memory_order_relaxed);
        atomic_store_explicit(&s_tls_custom_ca_active,
                              next.customCertificates.count > 0 ? true : false,
                              memory_order_release);
        atomic_store_explicit(&s_net_fast_state,
                              next.enabled ? PS_NET_FAST_ENABLED : PS_NET_FAST_DISABLED,
                              memory_order_release);
        atomic_store_explicit(&s_net_last_check, now, memory_order_relaxed);
        os_unfair_lock_unlock(&s_net_rule_lock);
        return next;
        }
    } @finally {
        pthread_mutex_unlock(&s_net_reload_mutex);
    }
}

__attribute__((visibility("hidden"))) PSNetworkRuleSnapshot *ps_get_network_rules(void) {
    time_t now = time(NULL);
    int fastState = atomic_load_explicit(&s_net_fast_state, memory_order_acquire);
    time_t lastCheck = atomic_load_explicit(&s_net_last_check, memory_order_relaxed);
    if (fastState == PS_NET_FAST_DISABLED && (now - lastCheck) < 10) {
        return nil;
    }
    PSNetworkRuleSnapshot *snap = ps_get_network_snapshot();
    return (snap != nil && snap.enabled) ? snap : nil;
}


static BOOL ps_match_single_host_rule(const char *host, size_t hostLen, const char *rule);

static NSString *ps_extract_trust_hostname(SecTrustRef trust) {
    if (trust == NULL) return nil;
    CFArrayRef policies = NULL;
    if (SecTrustCopyPolicies(trust, &policies) == errSecSuccess && policies != NULL) {
        CFIndex count = CFArrayGetCount(policies);
        for (CFIndex i = 0; i < count; i++) {
            SecPolicyRef policy = (SecPolicyRef)CFArrayGetValueAtIndex(policies, i);
            if (policy == NULL) continue;
            CFDictionaryRef props = SecPolicyCopyProperties(policy);
            if (props != NULL) {
                NSString *name = [(__bridge NSDictionary *)props objectForKey:(__bridge id)kSecPolicyName];
                if ([name isKindOfClass:[NSString class]] && name.length > 0) {
                    NSString *copy = [name copy];
                    CFRelease(props);
                    CFRelease(policies);
                    return copy;
                }
                CFRelease(props);
            }
        }
        CFRelease(policies);
    }
    CFArrayRef chain = SecTrustCopyCertificateChain(trust);
    if (chain != NULL) {
        if (CFArrayGetCount(chain) > 0) {
            SecCertificateRef leaf = (SecCertificateRef)CFArrayGetValueAtIndex(chain, 0);
            if (leaf != NULL) {
                NSString *summary = CFBridgingRelease(SecCertificateCopySubjectSummary(leaf));
                if ([summary isKindOfClass:[NSString class]] && summary.length > 0) {
                    CFRelease(chain);
                    return summary;
                }
            }
        }
        CFRelease(chain);
    }
    return nil;
}

__attribute__((visibility("hidden"))) BOOL ps_host_matches_mitm_scope(NSString *host, PSNetworkRuleSnapshot *snap) {
    if (snap == nil || snap.customCertificates.count == 0) {
        return NO;
    }
    if (snap.mitmAllHosts) {
        return YES;
    }
    if (host.length == 0 || snap.mitmHostRules.count == 0) {
        return NO;
    }
    const char *hostCStr = [host UTF8String];
    if (hostCStr == NULL) return NO;
    size_t hostLen = strlen(hostCStr);
    for (NSString *rule in snap.mitmHostRules) {
        if (ps_match_single_host_rule(hostCStr, hostLen, [rule UTF8String])) {
            return YES;
        }
    }
    return NO;
}

__attribute__((visibility("hidden"))) BOOL ps_should_apply_custom_ca_for_trust(SecTrustRef trust, PSNetworkRuleSnapshot *snap) {
    if (trust == NULL || snap == nil || snap.customCertificates.count == 0 || [PTSafeMode isActive]) {
        return NO;
    }
    if (snap.mitmAllHosts) {
        return YES;
    }
    NSString *host = ps_extract_trust_hostname(trust);
    return ps_host_matches_mitm_scope(host, snap);
}

__attribute__((visibility("hidden"))) BOOL ps_evaluate_trust_with_custom_anchors(SecTrustRef trust, PSNetworkRuleSnapshot *snap, CFErrorRef *outError) {
    if (trust == NULL || snap == nil || snap.customCertificates.count == 0) {
        return NO;
    }
    CFArrayRef existingCustomAnchors = NULL;
    BOOL hadExistingCustom = (SecTrustCopyCustomAnchorCertificates(trust, &existingCustomAnchors) == errSecSuccess &&
                              existingCustomAnchors != NULL);

    NSMutableArray *merged = [NSMutableArray arrayWithArray:snap.customCertificates];
    if (hadExistingCustom) {
        [merged addObjectsFromArray:(__bridge NSArray *)existingCustomAnchors];
    }

    OSStatus setStatus = SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)merged);
    if (setStatus != errSecSuccess) {
        if (existingCustomAnchors != NULL) {
            CFRelease(existingCustomAnchors);
        }
        return NO;
    }
    SecTrustSetAnchorCertificatesOnly(trust, false);

    CFErrorRef evalErr = NULL;
    bool ok = SecTrustEvaluateWithError(trust, &evalErr);
    if (ok) {
        if (evalErr != NULL) CFRelease(evalErr);
        if (existingCustomAnchors != NULL) CFRelease(existingCustomAnchors);
        if (outError != NULL) *outError = NULL;
        return YES;
    }

    // Restore original custom anchor state on failure.
    if (hadExistingCustom) {
        SecTrustSetAnchorCertificates(trust, existingCustomAnchors);
    } else {
        SecTrustSetAnchorCertificates(trust, NULL);
    }
    if (existingCustomAnchors != NULL) {
        CFRelease(existingCustomAnchors);
    }
    if (outError != NULL) {
        *outError = evalErr;
    } else if (evalErr != NULL) {
        CFRelease(evalErr);
    }
    return NO;
}


static BOOL ps_match_single_host_rule(const char *host, size_t hostLen, const char *rule) {
    if (host == NULL || rule == NULL || hostLen == 0) return NO;
    size_t ruleLen = strlen(rule);
    if (ruleLen == 0) return NO;
    if (rule[0] == '=') {
        const char *exact = rule + 1;
        size_t exactLen = ruleLen - 1;
        return (exactLen > 0 && hostLen == exactLen && strncasecmp(host, exact, exactLen) == 0);
    }
    if (rule[0] == '.') {
        const char *base = rule + 1;
        size_t baseLen = ruleLen - 1;
        if (hostLen == baseLen && strncasecmp(host, base, baseLen) == 0) {
            return YES;
        }
        if (hostLen > ruleLen && strncasecmp(host + hostLen - ruleLen, rule, ruleLen) == 0) {
            return YES;
        }
        return NO;
    }
    if (strchr(rule, '*') != NULL) {
        return (fnmatch(rule, host, FNM_CASEFOLD) == 0);
    }
    if (hostLen == ruleLen && strncasecmp(host, rule, ruleLen) == 0) {
        return YES;
    }
    if (hostLen > ruleLen && host[hostLen - ruleLen - 1] == '.' &&
        strncasecmp(host + hostLen - ruleLen, rule, ruleLen) == 0) {
        return YES;
    }
    return NO;
}

__attribute__((visibility("hidden")))
int ps_should_block_host_cstr(const char *hostname) {
    if (hostname == NULL || hostname[0] == '\0' || !ps_is_network_blocking_possibly_active()) return 0;
    @autoreleasepool {
        PSNetworkRuleSnapshot *snap = ps_get_network_rules();
        if (snap == nil || !snap.enabled || snap.hostRules.count == 0 || snap.hasHostlessAllowRule) return 0;
        size_t hostLen = strlen(hostname);

        BOOL matchesBlockedHost = NO;
        for (NSString *rule in snap.hostRules) {
            if (ps_match_single_host_rule(hostname, hostLen, [rule UTF8String])) {
                matchesBlockedHost = YES;
                break;
            }
        }
        if (!matchesBlockedHost) {
            return 0;
        }

        for (NSString *allowRule in snap.allowHostRules) {
            if (ps_match_single_host_rule(hostname, hostLen, [allowRule UTF8String])) {
                return 0;
            }
        }
        for (NSString *exemptPat in snap.dnsExemptHostPatterns) {
            if (ps_match_single_host_rule(hostname, hostLen, [exemptPat UTF8String])) {
                return 0;
            }
        }
        if (snap.dnsExemptHostRegexes.count > 0) {
            NSString *hostStr = [NSString stringWithUTF8String:hostname];
            if (hostStr.length > 0) {
                NSString *probeHttps = [NSString stringWithFormat:@"https://%@/", hostStr];
                NSString *probeHttp = [NSString stringWithFormat:@"http://%@/", hostStr];
                NSString *probeBare = [NSString stringWithFormat:@"%@/", hostStr];
                NSRange rHttps = NSMakeRange(0, probeHttps.length);
                NSRange rHttp = NSMakeRange(0, probeHttp.length);
                NSRange rBare = NSMakeRange(0, probeBare.length);
                for (NSRegularExpression *re in snap.dnsExemptHostRegexes) {
                    if ([re firstMatchInString:probeHttps options:0 range:rHttps] != nil ||
                        [re firstMatchInString:probeHttp options:0 range:rHttp] != nil ||
                        [re firstMatchInString:probeBare options:0 range:rBare] != nil) {
                        return 0;
                    }
                }
            }
        }
        return 1;
    }
}

static BOOL ps_resolve_mock200(PSNetworkRuleSnapshot *snap, NSArray<NSNumber *> *actions, NSUInteger idx) {
    PSNetRuleAction act = (idx < actions.count)
        ? (PSNetRuleAction)[actions[idx] integerValue]
        : PSNetRuleActionDefault;
    if (act == PSNetRuleActionForceMock200) return YES;
    if (act == PSNetRuleActionForceFail) return NO;
    return snap.mock200;
}

__attribute__((visibility("hidden"))) BOOL ps_should_block_url(NSURL *url, BOOL *outMock200) {
    if (url == nil || !ps_is_network_blocking_possibly_active()) return NO;
    @autoreleasepool {
        PSNetworkRuleSnapshot *snap = ps_get_network_rules();
        if (snap == nil || !snap.enabled) return NO;
        if (outMock200 != NULL) {
            *outMock200 = snap.mock200;
        }
        NSString *host = url.host;
        if (host.length > 0 && snap.allowHostRules.count > 0) {
            const char *hostCStr = [host UTF8String];
            size_t hostLen = strlen(hostCStr);
            for (NSString *rule in snap.allowHostRules) {
                if (ps_match_single_host_rule(hostCStr, hostLen, [rule UTF8String])) {
                    return NO;
                }
            }
        }
        if (snap.allowRegexRules.count > 0) {
            NSString *absStr = url.absoluteString ?: @"";
            if (absStr.length > 0) {
                NSRange fullRange = NSMakeRange(0, absStr.length);
                for (NSRegularExpression *re in snap.allowRegexRules) {
                    if ([re firstMatchInString:absStr options:0 range:fullRange] != nil) {
                        return NO;
                    }
                }
            }
        }
        if (snap.allowUrlRules.count > 0) {
            NSString *fullURL = [url.absoluteString lowercaseString] ?: @"";
            NSString *path = [url.path lowercaseString] ?: @"";
            for (NSString *rule in snap.allowUrlRules) {
                if ([rule containsString:@"*"]) {
                    const char *rCStr = [rule UTF8String];
                    if (fnmatch(rCStr, [fullURL UTF8String], FNM_CASEFOLD) == 0 ||
                        (path.length > 0 && fnmatch(rCStr, [path UTF8String], FNM_CASEFOLD) == 0)) {
                        return NO;
                    }
                } else {
                    if ([fullURL containsString:rule] || (path.length > 0 && [path containsString:rule])) {
                        return NO;
                    }
                }
            }
        }
        if (host.length > 0 && snap.hostRules.count > 0) {
            const char *hostCStr = [host UTF8String];
            size_t hostLen = strlen(hostCStr);
            for (NSUInteger i = 0; i < snap.hostRules.count; i++) {
                NSString *rule = snap.hostRules[i];
                if (ps_match_single_host_rule(hostCStr, hostLen, [rule UTF8String])) {
                    if (outMock200 != NULL) {
                        *outMock200 = ps_resolve_mock200(snap, snap.hostRuleActions, i);
                    }
                    return YES;
                }
            }
        }
        if (snap.regexRules.count > 0) {
            NSString *absStr = url.absoluteString ?: @"";
            if (absStr.length > 0) {
                NSRange fullRange = NSMakeRange(0, absStr.length);
                for (NSUInteger i = 0; i < snap.regexRules.count; i++) {
                    NSRegularExpression *re = snap.regexRules[i];
                    if ([re firstMatchInString:absStr options:0 range:fullRange] != nil) {
                        if (outMock200 != NULL) {
                            *outMock200 = ps_resolve_mock200(snap, snap.regexRuleActions, i);
                        }
                        return YES;
                    }
                }
            }
        }
        if (snap.urlRules.count > 0) {
            NSString *fullURL = [url.absoluteString lowercaseString] ?: @"";
            NSString *path = [url.path lowercaseString] ?: @"";
            for (NSUInteger i = 0; i < snap.urlRules.count; i++) {
                NSString *rule = snap.urlRules[i];
                if ([rule containsString:@"*"]) {
                    const char *rCStr = [rule UTF8String];
                    if (fnmatch(rCStr, [fullURL UTF8String], FNM_CASEFOLD) == 0 ||
                        (path.length > 0 && fnmatch(rCStr, [path UTF8String], FNM_CASEFOLD) == 0)) {
                        if (outMock200 != NULL) {
                            *outMock200 = ps_resolve_mock200(snap, snap.urlRuleActions, i);
                        }
                        return YES;
                    }
                } else {
                    if ([fullURL containsString:rule] || (path.length > 0 && [path containsString:rule])) {
                        if (outMock200 != NULL) {
                            *outMock200 = ps_resolve_mock200(snap, snap.urlRuleActions, i);
                        }
                        return YES;
                    }
                }
            }
        }
        return NO;
    }
}
