//
//  PTNetworkVirtualizer.m
//  PlayTools
//

#import "PSInternal.h"


typedef NS_ENUM(NSInteger, PSNetRuleAction) {
    PSNetRuleActionDefault = 0,
    PSNetRuleActionForceMock200 = 1,
    PSNetRuleActionForceFail = 2,
};

__attribute__((visibility("hidden")))
@interface PSNetworkRuleSnapshot : NSObject
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL mock200;
@property (nonatomic, assign) BOOL hasHostlessAllowRule;
@property (nonatomic, strong) NSArray<NSString *> *hostRules;
@property (nonatomic, strong) NSArray<NSNumber *> *hostRuleActions;
@property (nonatomic, strong) NSArray<NSString *> *urlRules;
@property (nonatomic, strong) NSArray<NSNumber *> *urlRuleActions;
@property (nonatomic, strong) NSArray<NSRegularExpression *> *regexRules;
@property (nonatomic, strong) NSArray<NSNumber *> *regexRuleActions;
@property (nonatomic, strong) NSArray<NSString *> *allowHostRules;
@property (nonatomic, strong) NSArray<NSString *> *allowUrlRules;
@property (nonatomic, strong) NSArray<NSRegularExpression *> *allowRegexRules;
@property (nonatomic, strong) NSArray<NSString *> *dnsExemptHostPatterns;
@property (nonatomic, strong) NSArray<NSRegularExpression *> *dnsExemptHostRegexes;
@end

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
static _Atomic bool s_net_mock200_cached = true;
static time_t s_net_last_mtime = 0;
static long s_net_last_mtimensec = 0;

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

static inline BOOL ps_is_network_blocking_possibly_active(void) {
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

static PSNetworkRuleSnapshot *ps_get_network_rules(void) {
    time_t now = time(NULL);
    int fastState = atomic_load_explicit(&s_net_fast_state, memory_order_acquire);
    time_t lastCheck = atomic_load_explicit(&s_net_last_check, memory_order_relaxed);
    if (fastState == PS_NET_FAST_DISABLED && (now - lastCheck) < 10) {
        return nil;
    }

    os_unfair_lock_lock(&s_net_rule_lock);
    PSNetworkRuleSnapshot *current = s_net_rule_snapshot;
    lastCheck = atomic_load_explicit(&s_net_last_check, memory_order_relaxed);
    BOOL freshEnough = (current != nil && (now - lastCheck) < 2);
    os_unfair_lock_unlock(&s_net_rule_lock);
    if (freshEnough) {
        return current.enabled ? current : nil;
    }

    pthread_mutex_lock(&s_net_reload_mutex);
    @try {
        now = time(NULL);
        os_unfair_lock_lock(&s_net_rule_lock);
        current = s_net_rule_snapshot;
        lastCheck = atomic_load_explicit(&s_net_last_check, memory_order_relaxed);
        if (current != nil &&
            ((atomic_load_explicit(&s_net_fast_state, memory_order_relaxed) == PS_NET_FAST_DISABLED && (now - lastCheck) < 10) ||
             (now - lastCheck) < 2)) {
            os_unfair_lock_unlock(&s_net_rule_lock);
            return current.enabled ? current : nil;
        }
        os_unfair_lock_unlock(&s_net_rule_lock);

        @autoreleasepool {
            NSString *plistPath = ps_app_settings_plist_path();
            if (plistPath.length == 0) {
                return current.enabled ? current : nil;
            }
            struct stat st;
            if (stat([plistPath fileSystemRepresentation], &st) != 0) {
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
                    os_unfair_lock_lock(&s_net_rule_lock);
                    s_net_rule_snapshot = empty;
                    atomic_store_explicit(&s_net_mock200_cached, true, memory_order_relaxed);
                    atomic_store_explicit(&s_net_fast_state, PS_NET_FAST_DISABLED, memory_order_release);
                    atomic_store_explicit(&s_net_last_check, now, memory_order_relaxed);
                    current = empty;
                    os_unfair_lock_unlock(&s_net_rule_lock);
                } else {
                    atomic_store_explicit(&s_net_last_check, now, memory_order_relaxed);
                }
                return current.enabled ? current : nil;
            }

            os_unfair_lock_lock(&s_net_rule_lock);
            BOOL unchanged = (current != nil &&
                              st.st_mtimespec.tv_sec == s_net_last_mtime &&
                              st.st_mtimespec.tv_nsec == s_net_last_mtimensec);
            if (unchanged) {
                atomic_store_explicit(&s_net_last_check, now, memory_order_relaxed);
            }
            os_unfair_lock_unlock(&s_net_rule_lock);
            if (unchanged) {
                return current.enabled ? current : nil;
            }

            NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            PSNetworkRuleSnapshot *next = [[PSNetworkRuleSnapshot alloc] init];
        next.enabled = [dict[@"enableNetworkRules"] boolValue];
        NSNumber *mockNum = dict[@"networkBlockMock200"];
        next.mock200 = (mockNum != nil) ? [mockNum boolValue] : YES;

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
        s_net_rule_snapshot = next;
        atomic_store_explicit(&s_net_mock200_cached, next.mock200 ? true : false, memory_order_relaxed);
        atomic_store_explicit(&s_net_fast_state,
                              next.enabled ? PS_NET_FAST_ENABLED : PS_NET_FAST_DISABLED,
                              memory_order_release);
        atomic_store_explicit(&s_net_last_check, now, memory_order_relaxed);
        os_unfair_lock_unlock(&s_net_rule_lock);
        return next.enabled ? next : nil;
        }
    } @finally {
        pthread_mutex_unlock(&s_net_reload_mutex);
    }
}

static void ps_swizzle_cfg_instance_methods_if_needed(Class concreteCfgCls) {
    if (concreteCfgCls == Nil) {
        return;
    }
    static os_unfair_lock s_cfgSwizzleLock = OS_UNFAIR_LOCK_INIT;
    static CFMutableSetRef s_swizzledCfgClasses = NULL;
    os_unfair_lock_lock(&s_cfgSwizzleLock);
    if (s_swizzledCfgClasses == NULL) {
        s_swizzledCfgClasses = CFSetCreateMutable(kCFAllocatorDefault, 0, NULL);
    }
    BOOL alreadyDone = (s_swizzledCfgClasses != NULL &&
                        CFSetContainsValue(s_swizzledCfgClasses, (__bridge const void *)concreteCfgCls));
    if (!alreadyDone && s_swizzledCfgClasses != NULL) {
        CFSetAddValue(s_swizzledCfgClasses, (__bridge const void *)concreteCfgCls);
    }
    os_unfair_lock_unlock(&s_cfgSwizzleLock);
    if (!alreadyDone) {
        ps_swizzle_instance_method(concreteCfgCls, @selector(setProtocolClasses:), @selector(pm_setProtocolClasses:));
        ps_swizzle_instance_method(concreteCfgCls, @selector(protocolClasses), @selector(pm_ps_protocolClasses));
    }
}

static void ps_inject_block_protocol_into_config(NSURLSessionConfiguration *config) {
    if (config == nil) return;
    if ([config respondsToSelector:@selector(identifier)] && config.identifier.length > 0) {
        return;
    }
    Class protoCls = objc_getClass("PTNetworkBlockProtocol");
    if (protoCls == nil) return;
    NSArray *existing = config.protocolClasses;
    if (existing.count > 0 && existing.firstObject == protoCls) {
        return;
    }
    NSMutableArray *protocols = existing ? [existing mutableCopy] : [NSMutableArray array];
    [protocols removeObject:protoCls];
    [protocols insertObject:protoCls atIndex:0];
    config.protocolClasses = protocols;
}

__attribute__((visibility("hidden")))
@interface PSSwizzleHooks (PlayShadowNetwork)
@end

@implementation PSSwizzleHooks (PlayShadowNetwork)

+ (NSURLSessionConfiguration *) pm_defaultSessionConfiguration {
    NSURLSessionConfiguration *config = [self pm_defaultSessionConfiguration];
    ps_inject_block_protocol_into_config(config);
    return config;
}

+ (NSURLSessionConfiguration *) pm_ephemeralSessionConfiguration {
    NSURLSessionConfiguration *config = [self pm_ephemeralSessionConfiguration];
    ps_inject_block_protocol_into_config(config);
    return config;
}

- (NSArray<Class> *) pm_ps_protocolClasses {
    const void *caller = __builtin_return_address(0);
    NSArray<Class> *classes = [self pm_ps_protocolClasses];
    if (classes.count == 0 || ps_is_effective_system_or_playtools_caller(caller)) {
        return classes;
    }
    Class protoCls = objc_getClass("PTNetworkBlockProtocol");
    if (protoCls == Nil || ![classes containsObject:protoCls]) {
        return classes;
    }
    NSMutableArray<Class> *filtered = [classes mutableCopy];
    [filtered removeObject:protoCls];
    return filtered;
}

- (void) pm_setProtocolClasses:(NSArray<Class> *)protocolClasses {
    if ([self respondsToSelector:@selector(identifier)]) {
        NSString *ident = ((NSString *(*)(id, SEL))objc_msgSend)(self, @selector(identifier));
        if ([ident isKindOfClass:[NSString class]] && ident.length > 0) {
            [self pm_setProtocolClasses:protocolClasses];
            return;
        }
    }
    Class protoCls = objc_getClass("PTNetworkBlockProtocol");
    if (protoCls != nil) {
        NSMutableArray<Class> *modified = protocolClasses ? [protocolClasses mutableCopy] : [NSMutableArray array];
        if (modified.count == 0 || modified.firstObject != protoCls) {
            [modified removeObject:protoCls];
            [modified insertObject:protoCls atIndex:0];
        }
        [self pm_setProtocolClasses:modified];
        return;
    }
    [self pm_setProtocolClasses:protocolClasses];
}

+ (NSURLSession *) pm_sessionWithConfiguration:(NSURLSessionConfiguration *)configuration {
    ps_inject_block_protocol_into_config(configuration);
    return [self pm_sessionWithConfiguration:configuration];
}

+ (NSURLSession *) pm_sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
                                      delegate:(id<NSURLSessionDelegate>)delegate
                                 delegateQueue:(NSOperationQueue *)queue {
    ps_inject_block_protocol_into_config(configuration);
    return [self pm_sessionWithConfiguration:configuration delegate:delegate delegateQueue:queue];
}

@end

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

static BOOL ps_should_block_url(NSURL *url, BOOL *outMock200) {
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

__attribute__((visibility("hidden")))
@interface PTNetworkBlockProtocol : NSURLProtocol {
    _Atomic BOOL _cancelled;
}
@end

@implementation PTNetworkBlockProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!ps_is_network_blocking_possibly_active()) return NO;
    NSURL *url = request.URL;
    if (url == nil) return NO;
    NSString *scheme = url.scheme;
    if (scheme == nil) return NO;
    if ([scheme caseInsensitiveCompare:@"http"] != NSOrderedSame &&
        [scheme caseInsensitiveCompare:@"https"] != NSOrderedSame &&
        [scheme caseInsensitiveCompare:@"ws"] != NSOrderedSame &&
        [scheme caseInsensitiveCompare:@"wss"] != NSOrderedSame) {
        return NO;
    }
    return ps_should_block_url(url, NULL);
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    atomic_store_explicit(&_cancelled, false, memory_order_relaxed);
    BOOL mock200 = atomic_load_explicit(&s_net_mock200_cached, memory_order_relaxed);
    NSURL *reqURL = self.request.URL;
    if (reqURL != nil) {
        (void)ps_should_block_url(reqURL, &mock200);
    }
    NSString *scheme = reqURL.scheme;
    NSString *upgradeHdr = [self.request valueForHTTPHeaderField:@"Upgrade"];
    if ((scheme != nil &&
         ([scheme caseInsensitiveCompare:@"ws"] == NSOrderedSame ||
          [scheme caseInsensitiveCompare:@"wss"] == NSOrderedSame)) ||
        (upgradeHdr != nil && [upgradeHdr caseInsensitiveCompare:@"websocket"] == NSOrderedSame)) {
        mock200 = NO;
    }
    if (atomic_load_explicit(&_cancelled, memory_order_acquire)) {
        return;
    }
    if (mock200) {
        static NSData *s_mockBody = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            s_mockBody = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
        });
        NSURL *url = reqURL ?: [NSURL URLWithString:@"https://localhost/"];
        BOOL isHead = (self.request.HTTPMethod != nil &&
                       [self.request.HTTPMethod caseInsensitiveCompare:@"HEAD"] == NSOrderedSame);
        NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:url
                                                              statusCode:200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:@{
                                                                @"Content-Type": @"application/json; charset=utf-8",
                                                                @"Content-Length": @"2"
                                                            }];
        [self.client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        if (!isHead && !atomic_load_explicit(&_cancelled, memory_order_acquire)) {
            [self.client URLProtocol:self didLoadData:s_mockBody];
        }
        if (!atomic_load_explicit(&_cancelled, memory_order_acquire)) {
            [self.client URLProtocolDidFinishLoading:self];
        }
    } else {
        NSError *err = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
        if (!atomic_load_explicit(&_cancelled, memory_order_acquire)) {
            [self.client URLProtocol:self didFailWithError:err];
        }
    }
}

- (void)stopLoading {
    atomic_store_explicit(&_cancelled, true, memory_order_release);
}

@end

__attribute__((visibility("hidden"))) void ps_install_network_blocker_hooks(void) {
    if ([PTSafeMode isActive]) {
        return;
    }
    PSNetworkRuleSnapshot *snap = ps_get_network_rules();
    if (snap == nil || !snap.enabled ||
        (snap.hostRules.count == 0 && snap.urlRules.count == 0 && snap.regexRules.count == 0)) {
        return;
    }
    PT_DEBUG_TRACE("network", "installing network blocker hooks hosts=%lu urls=%lu regex=%lu",
                   (unsigned long)snap.hostRules.count,
                   (unsigned long)snap.urlRules.count,
                   (unsigned long)snap.regexRules.count);
    [NSURLProtocol registerClass:[PTNetworkBlockProtocol class]];
    Class cfgCls = objc_getClass("NSURLSessionConfiguration");
    ps_swizzle_class_method(cfgCls, @selector(defaultSessionConfiguration), @selector(pm_defaultSessionConfiguration));
    ps_swizzle_class_method(cfgCls, @selector(ephemeralSessionConfiguration), @selector(pm_ephemeralSessionConfiguration));
    NSURLSessionConfiguration *sampleCfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    Class concreteCfgCls = sampleCfg != nil ? object_getClass(sampleCfg) : cfgCls;
    ps_swizzle_cfg_instance_methods_if_needed(concreteCfgCls);
    Class sessionCls = objc_getClass("NSURLSession");
    ps_swizzle_class_method(sessionCls, @selector(sessionWithConfiguration:), @selector(pm_sessionWithConfiguration:));
    ps_swizzle_class_method(sessionCls, @selector(sessionWithConfiguration:delegate:delegateQueue:), @selector(pm_sessionWithConfiguration:delegate:delegateQueue:));
}


static BOOL pt_should_block_cfstring_host(CFStringRef hostRef) {
    if (hostRef == NULL) return NO;
    char buf[512];
    const char *cstr = CFStringGetCStringPtr(hostRef, kCFStringEncodingUTF8);
    if (cstr == NULL && CFStringGetCString(hostRef, buf, sizeof(buf), kCFStringEncodingUTF8)) {
        cstr = buf;
    }
    return (cstr != NULL && ps_should_block_host_cstr(cstr) != 0);
}

static int pt_getaddrinfo(const char *hostname, const char *servname,
                          const struct addrinfo *hints, struct addrinfo **res) {
    if (hostname != NULL && ps_should_block_host_cstr(hostname)) {
        PT_DEBUG_TRACE("network", "blocked getaddrinfo host=%s", hostname);
        return EAI_NONAME;
    }
    return getaddrinfo(hostname, servname, hints, res);
}

static struct hostent *pt_gethostbyname(const char *name) {
    if (name != NULL && ps_should_block_host_cstr(name)) {
        h_errno = HOST_NOT_FOUND;
        return NULL;
    }
    return gethostbyname(name);
}

static struct hostent *pt_gethostbyname2(const char *name, int af) {
    if (name != NULL && ps_should_block_host_cstr(name)) {
        h_errno = HOST_NOT_FOUND;
        return NULL;
    }
    return gethostbyname2(name, af);
}

static DNSServiceErrorType pt_DNSServiceGetAddrInfo(
    DNSServiceRef *sdRef,
    DNSServiceFlags flags,
    uint32_t interfaceIndex,
    DNSServiceProtocol protocol,
    const char *hostname,
    DNSServiceGetAddrInfoReply callBack,
    void *context) {
    if (hostname != NULL && ps_should_block_host_cstr(hostname)) {
        return kDNSServiceErr_NoSuchRecord;
    }
    return DNSServiceGetAddrInfo(sdRef, flags, interfaceIndex, protocol, hostname, callBack, context);
}

static CFHostRef pt_CFHostCreateWithName(CFAllocatorRef allocator, CFStringRef hostname) {
    if (pt_should_block_cfstring_host(hostname)) {
        return CFHostCreateWithName(allocator, CFSTR("invalid.invalid."));
    }
    return CFHostCreateWithName(allocator, hostname);
}

static void pt_CFStreamCreatePairWithSocketToHost(
    CFAllocatorRef alloc,
    CFStringRef host,
    UInt32 port,
    CFReadStreamRef *readStream,
    CFWriteStreamRef *writeStream) {
    if (pt_should_block_cfstring_host(host)) {
        CFStreamCreatePairWithSocketToHost(alloc, CFSTR("0.0.0.0"), 1, readStream, writeStream);
        return;
    }
    CFStreamCreatePairWithSocketToHost(alloc, host, port, readStream, writeStream);
}

static NW_RETURNS_RETAINED nw_endpoint_t pt_nw_endpoint_create_host(const char *hostname, const char *port) {
    if (hostname == NULL || port == NULL) {
        return NULL;
    }
    if (ps_should_block_host_cstr(hostname)) {
        PT_DEBUG_TRACE("network", "blocked nw_endpoint host=%s port=%s", hostname, port);
        return nw_endpoint_create_host("0.0.0.0", "1");
    }
    return nw_endpoint_create_host(hostname, port);
}

static SCNetworkReachabilityRef pt_SCNetworkReachabilityCreateWithName(
    CFAllocatorRef allocator,
    const char *nodename) {
    if (nodename == NULL) {
        return NULL;
    }
    if (ps_should_block_host_cstr(nodename)) {
        return SCNetworkReachabilityCreateWithName(allocator, "invalid.invalid.");
    }
    return SCNetworkReachabilityCreateWithName(allocator, nodename);
}


typedef struct {
    BOOL active;
    int dirfd;
    int saved_fd;
    int (*fn_pthread_fchdir)(int);
} pt_unix_fchdir_guard_t;

static int (*pt_get_pthread_fchdir_fn(void))(int) {
    static _Atomic(void *) s_fn = NULL;
    static _Atomic(int) s_inited = 0;
    if (atomic_load_explicit(&s_inited, memory_order_acquire) == 0) {
        void *sym = dlsym(RTLD_DEFAULT, "__pthread_fchdir");
        atomic_store_explicit(&s_fn, sym, memory_order_relaxed);
        atomic_store_explicit(&s_inited, 1, memory_order_release);
        return (int (*)(int))sym;
    }
    return (int (*)(int))atomic_load_explicit(&s_fn, memory_order_relaxed);
}

#define PT_UNIX_REL_SOCK_SLOTS 64U

typedef struct {
    uint64_t sock_ino;
    char leaf[sizeof(((struct sockaddr_un *)0)->sun_path)];
    char virt_path[sizeof(((struct sockaddr_un *)0)->sun_path)];
} pt_unix_rel_sock_entry_t;

static os_unfair_lock s_unix_rel_sock_lock = OS_UNFAIR_LOCK_INIT;
static pt_unix_rel_sock_entry_t s_unix_rel_sock_table[PT_UNIX_REL_SOCK_SLOTS];
static uint32_t s_unix_rel_sock_cursor = 0;

static uint64_t pt_unix_sock_ino(int fd) {
    struct stat st;
    return (fd >= 0 && fstat(fd, &st) == 0) ? (uint64_t)st.st_ino : 0;
}

static void pt_unix_record_rel_sock(int fd, const char *leaf, const char *virt_path) {
    if (fd < 0 || leaf == NULL || leaf[0] == '\0' || virt_path == NULL || virt_path[0] != '/') {
        return;
    }
    uint64_t ino = pt_unix_sock_ino(fd);
    os_unfair_lock_lock(&s_unix_rel_sock_lock);
    pt_unix_rel_sock_entry_t *dst = NULL;
    if (ino != 0) {
        for (size_t i = 0; i < PT_UNIX_REL_SOCK_SLOTS; i++) {
            if (s_unix_rel_sock_table[i].sock_ino == ino) {
                dst = &s_unix_rel_sock_table[i];
                break;
            }
        }
    }
    if (dst == NULL) {
        uint32_t idx = s_unix_rel_sock_cursor++ & (PT_UNIX_REL_SOCK_SLOTS - 1U);
        dst = &s_unix_rel_sock_table[idx];
    }
    dst->sock_ino = ino;
    strlcpy(dst->leaf, leaf, sizeof(dst->leaf));
    strlcpy(dst->virt_path, virt_path, sizeof(dst->virt_path));
    os_unfair_lock_unlock(&s_unix_rel_sock_lock);
}

static BOOL pt_unix_copy_entry_by_fd(int fd,
                                     char *out_leaf,
                                     size_t out_leaf_cap,
                                     char *out_virt,
                                     size_t out_virt_cap) {
    uint64_t ino = pt_unix_sock_ino(fd);
    if (ino == 0) {
        return NO;
    }
    BOOL found = NO;
    os_unfair_lock_lock(&s_unix_rel_sock_lock);
    for (size_t i = 0; i < PT_UNIX_REL_SOCK_SLOTS; i++) {
        const pt_unix_rel_sock_entry_t *e = &s_unix_rel_sock_table[i];
        if (e->sock_ino == ino && e->leaf[0] != '\0' && e->virt_path[0] == '/') {
            if (out_leaf && out_leaf_cap > 0) {
                strlcpy(out_leaf, e->leaf, out_leaf_cap);
            }
            if (out_virt && out_virt_cap > 0) {
                strlcpy(out_virt, e->virt_path, out_virt_cap);
            }
            found = YES;
            break;
        }
    }
    os_unfair_lock_unlock(&s_unix_rel_sock_lock);
    return found;
}

static BOOL pt_unix_lookup_rel_sock(int fd, const char *leaf, char *out_virt, size_t out_cap) {
    if (leaf == NULL || leaf[0] == '\0' || out_virt == NULL || out_cap == 0) {
        return NO;
    }
    uint64_t ino = pt_unix_sock_ino(fd);
    BOOL found = NO;
    os_unfair_lock_lock(&s_unix_rel_sock_lock);
    if (ino != 0) {
        for (size_t i = 0; i < PT_UNIX_REL_SOCK_SLOTS; i++) {
            const pt_unix_rel_sock_entry_t *e = &s_unix_rel_sock_table[i];
            if (e->sock_ino == ino &&
                e->virt_path[0] == '/' &&
                strcmp(e->leaf, leaf) == 0) {
                if (strlcpy(out_virt, e->virt_path, out_cap) < out_cap) {
                    found = YES;
                }
                break;
            }
        }
    }
    if (!found) {
        uint32_t cur = s_unix_rel_sock_cursor;
        for (uint32_t k = 0; k < PT_UNIX_REL_SOCK_SLOTS; k++) {
            uint32_t idx = (cur - 1U - k) & (PT_UNIX_REL_SOCK_SLOTS - 1U);
            const pt_unix_rel_sock_entry_t *e = &s_unix_rel_sock_table[idx];
            if (e->virt_path[0] == '/' && strcmp(e->leaf, leaf) == 0) {
                if (strlcpy(out_virt, e->virt_path, out_cap) < out_cap) {
                    found = YES;
                }
                break;
            }
        }
    }
    os_unfair_lock_unlock(&s_unix_rel_sock_lock);
    return found;
}

static int pt_prepare_unix_sockaddr(const struct sockaddr *address,
                                    socklen_t address_len,
                                    const void *caller,
                                    struct sockaddr_un *out_mapped,
                                    socklen_t *out_len,
                                    pt_unix_fchdir_guard_t *out_guard,
                                    char *out_leaf,
                                    size_t out_leaf_cap,
                                    char *out_virt,
                                    size_t out_virt_cap) {
    if (out_guard != NULL) {
        out_guard->active = NO;
        out_guard->dirfd = -1;
        out_guard->saved_fd = -1;
        out_guard->fn_pthread_fchdir = NULL;
    }
    if (out_leaf != NULL && out_leaf_cap > 0) {
        out_leaf[0] = '\0';
    }
    if (out_virt != NULL && out_virt_cap > 0) {
        out_virt[0] = '\0';
    }
    if (address == NULL ||
        address_len <= (socklen_t)offsetof(struct sockaddr_un, sun_path) ||
        address->sa_family != AF_UNIX) {
        return 0;
    }
    const struct sockaddr_un *un = (const struct sockaddr_un *)address;
    size_t max_sun = (size_t)address_len - offsetof(struct sockaddr_un, sun_path);
    char raw_path[PATH_MAX];
    size_t copy_len = strnlen(un->sun_path, MIN(max_sun, sizeof(raw_path) - 1U));
    memcpy(raw_path, un->sun_path, copy_len);
    raw_path[copy_len] = '\0';

    if (raw_path[0] != '/') {
        return 0;
    }
    char resolved_buf[PATH_MAX];
    const char *resolved = NULL;
    int is_sys = -1;
    pt_fs_path_disposition_t disp = pt_prepare_fs_path_cached_caller(
        raw_path, caller, resolved_buf, sizeof(resolved_buf), &resolved, &is_sys);
    if (disp == PT_FS_PATH_HIDDEN) {
        errno = ENOENT;
        return -1;
    }
    if (disp == PT_FS_PATH_VIRTUAL_ANCESTOR) {
        errno = EACCES;
        return -1;
    }
    if (resolved == NULL || strcmp(resolved, raw_path) == 0) {
        return 0;
    }
    size_t rlen = strlen(resolved);
    if (rlen < sizeof(out_mapped->sun_path)) {
        memset(out_mapped, 0, sizeof(*out_mapped));
        out_mapped->sun_family = AF_UNIX;
        memcpy(out_mapped->sun_path, resolved, rlen + 1U);
        out_mapped->sun_len = (unsigned char)SUN_LEN(out_mapped);
        *out_len = (socklen_t)sizeof(*out_mapped);
        return 1;
    }
    if (out_guard == NULL) {
        errno = ENAMETOOLONG;
        return -1;
    }
    const char *slash = strrchr(resolved, '/');
    if (slash == NULL || slash[1] == '\0') {
        errno = ENAMETOOLONG;
        return -1;
    }
    size_t parent_len = (size_t)(slash - resolved);
    char parent_dir[PATH_MAX];
    if (parent_len == 0) {
        parent_dir[0] = '/';
        parent_dir[1] = '\0';
    } else if (parent_len < sizeof(parent_dir)) {
        memcpy(parent_dir, resolved, parent_len);
        parent_dir[parent_len] = '\0';
    } else {
        errno = ENAMETOOLONG;
        return -1;
    }
    const char *leaf = slash + 1;
    char rel[sizeof(out_mapped->sun_path)];
    int rn = snprintf(rel, sizeof(rel), "./%s", leaf);
    if (rn < 0 || (size_t)rn >= sizeof(rel)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    int (*fn)(int) = pt_get_pthread_fchdir_fn();
    if (fn == NULL) {
        errno = ENAMETOOLONG;
        return -1;
    }
    int dirfd = pt_orig_open_nocancel(parent_dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dirfd < 0) {
        return -1;
    }
    int saved_fd = pt_orig_open_nocancel(".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fn(dirfd) != 0) {
        int saved_err = errno;
        close(dirfd);
        if (saved_fd >= 0) {
            close(saved_fd);
        }
        errno = saved_err;
        return -1;
    }
    out_guard->active = YES;
    out_guard->dirfd = dirfd;
    out_guard->saved_fd = saved_fd;
    out_guard->fn_pthread_fchdir = fn;

    if (out_leaf != NULL && out_leaf_cap > 0) {
        strlcpy(out_leaf, leaf, out_leaf_cap);
    }
    if (out_virt != NULL && out_virt_cap > 0) {
        if ((strncmp(raw_path, "/var/", 5) == 0 || strncmp(raw_path, "/private/var/", 13) == 0) &&
            strlen(raw_path) < out_virt_cap) {
            strlcpy(out_virt, raw_path, out_virt_cap);
        } else {
            char vbuf[PATH_MAX];
            const char *vp = pt_virtualize_path_for_app(resolved, vbuf, sizeof(vbuf), NO);
            if (vp != NULL && vp[0] == '/' && strlen(vp) < out_virt_cap) {
                strlcpy(out_virt, vp, out_virt_cap);
            }
        }
    }

    memset(out_mapped, 0, sizeof(*out_mapped));
    out_mapped->sun_family = AF_UNIX;
    memcpy(out_mapped->sun_path, rel, (size_t)rn + 1U);
    out_mapped->sun_len = (unsigned char)SUN_LEN(out_mapped);
    *out_len = (socklen_t)sizeof(*out_mapped);
    return 1;
}

static void pt_end_unix_fchdir(pt_unix_fchdir_guard_t *guard) {
    if (guard == NULL || !guard->active) {
        return;
    }
    int saved_errno = errno;
    if (guard->fn_pthread_fchdir != NULL) {
        if (guard->saved_fd >= 0) {
            struct stat st_saved, st_proc;
            BOOL have_saved = (fstat(guard->saved_fd, &st_saved) == 0);
            if (guard->fn_pthread_fchdir(-1) == 0) {
                if (have_saved) {
                    int pfd = pt_orig_open_nocancel(".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
                    BOOL match_proc = (pfd >= 0 && fstat(pfd, &st_proc) == 0 &&
                                       st_proc.st_dev == st_saved.st_dev &&
                                       st_proc.st_ino == st_saved.st_ino);
                    if (pfd >= 0) {
                        close(pfd);
                    }
                    if (!match_proc) {
                        (void)guard->fn_pthread_fchdir(guard->saved_fd);
                    }
                }
            } else {
                (void)guard->fn_pthread_fchdir(guard->saved_fd);
            }
        } else {
            (void)guard->fn_pthread_fchdir(-1);
        }
    }
    if (guard->saved_fd >= 0) {
        close(guard->saved_fd);
    }
    if (guard->dirfd >= 0) {
        close(guard->dirfd);
    }
    guard->active = NO;
    guard->dirfd = -1;
    guard->saved_fd = -1;
    errno = saved_errno;
}

static void pt_virtualize_unix_sockaddr_out(int socket_fd,
                                            struct sockaddr *address,
                                            socklen_t *address_len,
                                            socklen_t caller_cap,
                                            const void *caller) {
    if (address == NULL || address_len == NULL ||
        caller_cap <= (socklen_t)offsetof(struct sockaddr_un, sun_path) ||
        *address_len <= (socklen_t)offsetof(struct sockaddr_un, sun_path) ||
        address->sa_family != AF_UNIX ||
        !pt_is_bypass_enabled() ||
        pt_is_effective_system_or_playtools_caller(caller)) {
        return;
    }
    struct sockaddr_un *un = (struct sockaddr_un *)address;
    size_t written = (size_t)MIN(*address_len, caller_cap);
    size_t avail = written - offsetof(struct sockaddr_un, sun_path);
    if (avail == 0) {
        return;
    }
    char raw_path[PATH_MAX];
    size_t n = strnlen(un->sun_path, MIN(avail, sizeof(raw_path) - 1U));
    memcpy(raw_path, un->sun_path, n);
    raw_path[n] = '\0';

    char vbuf[PATH_MAX];
    const char *virt = NULL;
    if (raw_path[0] == '/') {
        virt = pt_virtualize_path_for_app(raw_path, vbuf, sizeof(vbuf), NO);
    } else if (strncmp(raw_path, "./", 2) == 0 && raw_path[2] != '\0') {
        if (pt_unix_lookup_rel_sock(socket_fd, raw_path + 2, vbuf, sizeof(vbuf))) {
            virt = vbuf;
        }
    }
    if (virt == NULL || strcmp(virt, raw_path) == 0) {
        return;
    }
    size_t vlen = strlen(virt);
    size_t path_cap = (size_t)caller_cap - offsetof(struct sockaddr_un, sun_path);
    socklen_t needed_len = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + vlen + 1U);
    if (needed_len <= caller_cap && vlen + 1U <= path_cap) {
        memcpy(un->sun_path, virt, vlen + 1U);
        un->sun_len = (unsigned char)MIN((size_t)needed_len, (size_t)UCHAR_MAX);
        *address_len = needed_len;
    } else if (avail > 0) {
        size_t copy_n = MIN(vlen, avail - 1U);
        memcpy(un->sun_path, virt, copy_n);
        un->sun_path[copy_n] = '\0';
        un->sun_len = (unsigned char)MIN(written, (size_t)UCHAR_MAX);
    }
}

static int pt_bind(int socket, const struct sockaddr *address, socklen_t address_len) {
    struct sockaddr_un mapped;
    socklen_t mapped_len = address_len;
    pt_unix_fchdir_guard_t guard;
    char leaf_buf[sizeof(mapped.sun_path)];
    char virt_buf[sizeof(mapped.sun_path)];
    int prep = pt_prepare_unix_sockaddr(address, address_len, __builtin_return_address(0),
                                          &mapped, &mapped_len, &guard,
                                          leaf_buf, sizeof(leaf_buf), virt_buf, sizeof(virt_buf));
    if (prep < 0) {
        return -1;
    }
    const struct sockaddr *use_addr = (prep > 0) ? (const struct sockaddr *)&mapped : address;
    socklen_t use_len = (prep > 0) ? mapped_len : address_len;
    int ret = bind(socket, use_addr, use_len);
    pt_end_unix_fchdir(&guard);
    if (ret == 0 && leaf_buf[0] != '\0' && virt_buf[0] == '/') {
        pt_unix_record_rel_sock(socket, leaf_buf, virt_buf);
    }
    return ret;
}

static int pt_connect(int socket, const struct sockaddr *address, socklen_t address_len) {
    struct sockaddr_un mapped;
    socklen_t mapped_len = address_len;
    pt_unix_fchdir_guard_t guard;
    char leaf_buf[sizeof(mapped.sun_path)];
    char virt_buf[sizeof(mapped.sun_path)];
    int prep = pt_prepare_unix_sockaddr(address, address_len, __builtin_return_address(0),
                                          &mapped, &mapped_len, &guard,
                                          leaf_buf, sizeof(leaf_buf), virt_buf, sizeof(virt_buf));
    if (prep < 0) {
        return -1;
    }
    const struct sockaddr *use_addr = (prep > 0) ? (const struct sockaddr *)&mapped : address;
    socklen_t use_len = (prep > 0) ? mapped_len : address_len;
    int ret = connect(socket, use_addr, use_len);
    pt_end_unix_fchdir(&guard);
    if (ret == 0 && leaf_buf[0] != '\0' && virt_buf[0] == '/') {
        pt_unix_record_rel_sock(socket, leaf_buf, virt_buf);
    }
    return ret;
}

static int pt_accept(int socket, struct sockaddr * __restrict address, socklen_t * __restrict address_len) {
    socklen_t caller_cap = (address_len != NULL) ? *address_len : 0;
    int ret = accept(socket, address, address_len);
    if (ret >= 0) {
        char leaf_buf[sizeof(((struct sockaddr_un *)0)->sun_path)];
        char virt_buf[sizeof(((struct sockaddr_un *)0)->sun_path)];
        if (pt_unix_copy_entry_by_fd(socket, leaf_buf, sizeof(leaf_buf), virt_buf, sizeof(virt_buf))) {
            pt_unix_record_rel_sock(ret, leaf_buf, virt_buf);
        }
        if (address != NULL && address_len != NULL) {
            pt_virtualize_unix_sockaddr_out(ret, address, address_len, caller_cap, __builtin_return_address(0));
        }
    }
    return ret;
}

static ssize_t pt_sendto(int socket,
                         const void *buffer,
                         size_t length,
                         int flags,
                         const struct sockaddr *dest_addr,
                         socklen_t dest_len) {
    struct sockaddr_un mapped;
    socklen_t mapped_len = dest_len;
    pt_unix_fchdir_guard_t guard;
    int prep = pt_prepare_unix_sockaddr(dest_addr, dest_len, __builtin_return_address(0),
                                          &mapped, &mapped_len, &guard,
                                          NULL, 0, NULL, 0);
    if (prep < 0) {
        return -1;
    }
    const struct sockaddr *use_addr = (prep > 0) ? (const struct sockaddr *)&mapped : dest_addr;
    socklen_t use_len = (prep > 0) ? mapped_len : dest_len;
    ssize_t ret = sendto(socket, buffer, length, flags, use_addr, use_len);
    pt_end_unix_fchdir(&guard);
    return ret;
}

static int pt_getsockname(int socket, struct sockaddr * __restrict address, socklen_t * __restrict address_len) {
    if (address == NULL || address_len == NULL) {
        errno = EFAULT;
        return -1;
    }
    socklen_t caller_cap = *address_len;
    int ret = getsockname(socket, address, address_len);
    if (ret == 0) {
        pt_virtualize_unix_sockaddr_out(socket, address, address_len, caller_cap, __builtin_return_address(0));
    }
    return ret;
}

static int pt_getpeername(int socket, struct sockaddr * __restrict address, socklen_t * __restrict address_len) {
    if (address == NULL || address_len == NULL) {
        errno = EFAULT;
        return -1;
    }
    socklen_t caller_cap = *address_len;
    int ret = getpeername(socket, address, address_len);
    if (ret == 0) {
        pt_virtualize_unix_sockaddr_out(socket, address, address_len, caller_cap, __builtin_return_address(0));
    }
    return ret;
}


DYLD_INTERPOSE(pt_getaddrinfo, getaddrinfo)
DYLD_INTERPOSE(pt_gethostbyname, gethostbyname)
DYLD_INTERPOSE(pt_gethostbyname2, gethostbyname2)
DYLD_INTERPOSE(pt_DNSServiceGetAddrInfo, DNSServiceGetAddrInfo)
DYLD_INTERPOSE(pt_CFHostCreateWithName, CFHostCreateWithName)
DYLD_INTERPOSE(pt_CFStreamCreatePairWithSocketToHost, CFStreamCreatePairWithSocketToHost)
DYLD_INTERPOSE(pt_nw_endpoint_create_host, nw_endpoint_create_host)
DYLD_INTERPOSE(pt_SCNetworkReachabilityCreateWithName, SCNetworkReachabilityCreateWithName)
DYLD_INTERPOSE(pt_bind, bind)
DYLD_INTERPOSE(pt_connect, connect)
DYLD_INTERPOSE(pt_accept, accept)
DYLD_INTERPOSE(pt_sendto, sendto)
DYLD_INTERPOSE(pt_getsockname, getsockname)
DYLD_INTERPOSE(pt_getpeername, getpeername)
