//
//  PTNetworkVirtualizer.m
//  PlayTools
//

#import "PSInternal.h"
#include <stdarg.h>

static const char s_ptProxyInjectedTagKey = 0;

__attribute__((visibility("hidden"))) void ps_swizzle_cfg_instance_methods_if_needed(Class concreteCfgCls) {
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
        ps_swizzle_instance_method(concreteCfgCls, @selector(connectionProxyDictionary), @selector(pm_ps_connectionProxyDictionary));
        if (class_getInstanceMethod(concreteCfgCls, @selector(setConnectionProxyDictionary:)) != NULL) {
            ps_swizzle_instance_method(concreteCfgCls, @selector(setConnectionProxyDictionary:), @selector(pm_ps_setConnectionProxyDictionary:));
        }
    }
}

__attribute__((visibility("hidden"))) BOOL ps_dict_has_active_proxy(NSDictionary *dict) {
    if (dict.count == 0) {
        return NO;
    }
    BOOL httpEnabled = ([dict[@"HTTPEnable"] respondsToSelector:@selector(boolValue)] &&
                        [dict[@"HTTPEnable"] boolValue] &&
                        [dict[@"HTTPProxy"] isKindOfClass:[NSString class]] &&
                        [(NSString *)dict[@"HTTPProxy"] length] > 0 &&
                        [dict[@"HTTPPort"] respondsToSelector:@selector(integerValue)] &&
                        [dict[@"HTTPPort"] integerValue] > 0);
    BOOL httpsEnabled = ([dict[@"HTTPSEnable"] respondsToSelector:@selector(boolValue)] &&
                         [dict[@"HTTPSEnable"] boolValue] &&
                         [dict[@"HTTPSProxy"] isKindOfClass:[NSString class]] &&
                         [(NSString *)dict[@"HTTPSProxy"] length] > 0 &&
                         [dict[@"HTTPSPort"] respondsToSelector:@selector(integerValue)] &&
                         [dict[@"HTTPSPort"] integerValue] > 0);
    BOOL socksEnabled = ([dict[@"SOCKSEnable"] respondsToSelector:@selector(boolValue)] &&
                         [dict[@"SOCKSEnable"] boolValue] &&
                         [dict[@"SOCKSProxy"] isKindOfClass:[NSString class]] &&
                         [(NSString *)dict[@"SOCKSProxy"] length] > 0 &&
                         [dict[@"SOCKSPort"] respondsToSelector:@selector(integerValue)] &&
                         [dict[@"SOCKSPort"] integerValue] > 0);
    BOOL pacEnabled = ([dict[@"ProxyAutoConfigEnable"] respondsToSelector:@selector(boolValue)] &&
                       [dict[@"ProxyAutoConfigEnable"] boolValue] &&
                       [dict[@"ProxyAutoConfigURLString"] isKindOfClass:[NSString class]] &&
                       [(NSString *)dict[@"ProxyAutoConfigURLString"] length] > 0);
    return httpEnabled || httpsEnabled || socksEnabled || pacEnabled;
}

static BOOL ps_proxy_dict_matches_snapshot(NSDictionary *dict, PSNetworkRuleSnapshot *snap) {
    if (dict.count == 0 || snap == nil || snap.proxyHost.length == 0 || snap.proxyPort <= 0) {
        return NO;
    }
    if (snap.proxyIsSOCKS5) {
        id host = dict[@"SOCKSProxy"];
        id port = dict[@"SOCKSPort"];
        return ([dict[@"SOCKSEnable"] respondsToSelector:@selector(boolValue)] &&
                [dict[@"SOCKSEnable"] boolValue] &&
                [host isKindOfClass:[NSString class]] &&
                [(NSString *)host isEqualToString:snap.proxyHost] &&
                [port respondsToSelector:@selector(integerValue)] &&
                [port integerValue] == snap.proxyPort);
    }
    BOOL httpMatch = ([dict[@"HTTPEnable"] respondsToSelector:@selector(boolValue)] &&
                      [dict[@"HTTPEnable"] boolValue] &&
                      [dict[@"HTTPProxy"] isKindOfClass:[NSString class]] &&
                      [(NSString *)dict[@"HTTPProxy"] isEqualToString:snap.proxyHost] &&
                      [dict[@"HTTPPort"] respondsToSelector:@selector(integerValue)] &&
                      [dict[@"HTTPPort"] integerValue] == snap.proxyPort);
    BOOL httpsMatch = ([dict[@"HTTPSEnable"] respondsToSelector:@selector(boolValue)] &&
                       [dict[@"HTTPSEnable"] boolValue] &&
                       [dict[@"HTTPSProxy"] isKindOfClass:[NSString class]] &&
                       [(NSString *)dict[@"HTTPSProxy"] isEqualToString:snap.proxyHost] &&
                       [dict[@"HTTPSPort"] respondsToSelector:@selector(integerValue)] &&
                       [dict[@"HTTPSPort"] integerValue] == snap.proxyPort);
    return httpMatch || httpsMatch;
}

static NSData *ps_permissive_ats_context_data(void) {
    static NSData *s_atsData = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_atsData = [NSPropertyListSerialization dataWithPropertyList:@{ @"NSAllowsArbitraryLoads": @YES }
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0
                                                                error:nil];
    });
    return s_atsData;
}

static void ps_inject_proxy_into_config(NSURLSessionConfiguration *config) {
    if (config == nil || [PTSafeMode isActive]) return;
    PSNetworkRuleSnapshot *snap = ps_get_network_snapshot();
    if (snap == nil) return;
    if (snap.activeProxyDictionary.count > 0 && !ps_dict_has_active_proxy(config.connectionProxyDictionary)) {
        config.connectionProxyDictionary = snap.activeProxyDictionary;
        objc_setAssociatedObject(config, &s_ptProxyInjectedTagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (snap.customCertificates.count > 0) {
        SEL atsSel = NSSelectorFromString(@"set_atsContext:");
        NSData *atsData = ps_permissive_ats_context_data();
        if (atsData != nil && [config respondsToSelector:atsSel]) {
            ((void (*)(id, SEL, NSData *))objc_msgSend)(config, atsSel, atsData);
        }
    }
}

static void ps_inject_block_protocol_into_config(NSURLSessionConfiguration *config) {
    if (config == nil) return;
    ps_swizzle_cfg_instance_methods_if_needed(object_getClass(config));
    ps_inject_proxy_into_config(config);
    if ([config respondsToSelector:@selector(identifier)] && config.identifier.length > 0) {
        return;
    }
    if (ps_get_network_rules() == nil) {
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

static BOOL ps_trust_accepted_by_custom_ca(SecTrustRef serverTrust, NSString *host, PSNetworkRuleSnapshot *snap) {
    if (serverTrust == NULL || snap == nil || snap.customCertificates.count == 0 || [PTSafeMode isActive]) {
        return NO;
    }
    if (!snap.mitmAllHosts &&
        !ps_host_matches_mitm_scope(host, snap) &&
        !ps_should_apply_custom_ca_for_trust(serverTrust, snap)) {
        return NO;
    }
    return ps_evaluate_trust_with_custom_anchors(serverTrust, snap, NULL);
}

typedef void (*PTTrustChallengeForwardBlock)(void (^effectiveCompletion)(NSURLSessionAuthChallengeDisposition, NSURLCredential *));

static void ps_handle_server_trust_challenge(
    NSURLAuthenticationChallenge *challenge,
    BOOL targetHandlesChallenge,
    void (^forwardBlock)(void (^effectiveCompletion)(NSURLSessionAuthChallengeDisposition, NSURLCredential *)),
    void (^completionHandler)(NSURLSessionAuthChallengeDisposition, NSURLCredential *)
) {
    if (completionHandler == nil) {
        return;
    }
    if (challenge == nil ||
        ![challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust] ||
        challenge.protectionSpace.serverTrust == NULL) {
        if (targetHandlesChallenge && forwardBlock != nil) {
            forwardBlock(completionHandler);
        } else {
            completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        }
        return;
    }

    SecTrustRef serverTrust = challenge.protectionSpace.serverTrust;
    NSString *host = challenge.protectionSpace.host;
    PSNetworkRuleSnapshot *snap = [PTSafeMode isActive] ? nil : ps_get_network_snapshot();
    BOOL inCustomCAScope = (snap != nil && snap.customCertificates.count > 0 &&
                            (snap.mitmAllHosts || ps_host_matches_mitm_scope(host, snap) ||
                             ps_should_apply_custom_ca_for_trust(serverTrust, snap)));

    if (snap != nil && snap.mitmAllowPinningBypass && inCustomCAScope) {
        CFErrorRef err = NULL;
        bool ok = SecTrustEvaluateWithError(serverTrust, &err);
        if (err != NULL) {
            CFRelease(err);
        }
        if (!ok) {
            ok = ps_evaluate_trust_with_custom_anchors(serverTrust, snap, NULL);
        }
        if (ok) {
            completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:serverTrust]);
            return;
        }
    }

    if (targetHandlesChallenge && forwardBlock != nil) {
        void (^origCompletion)(NSURLSessionAuthChallengeDisposition, NSURLCredential *) = [completionHandler copy];
        void (^wrappedCompletion)(NSURLSessionAuthChallengeDisposition, NSURLCredential *) =
            ^(NSURLSessionAuthChallengeDisposition disp, NSURLCredential *cred) {
                if (disp == NSURLSessionAuthChallengePerformDefaultHandling &&
                    ps_trust_accepted_by_custom_ca(serverTrust, host, snap)) {
                    origCompletion(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:serverTrust]);
                    return;
                }
                origCompletion(disp, cred);
            };
        forwardBlock(wrappedCompletion);
        return;
    }

    if (ps_trust_accepted_by_custom_ca(serverTrust, host, snap)) {
        completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:serverTrust]);
        return;
    }

    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

static void ps_handle_url_session_trust_challenge(
    id target,
    NSURLSession *session,
    NSURLSessionTask *task,
    NSURLAuthenticationChallenge *challenge,
    void (^completionHandler)(NSURLSessionAuthChallengeDisposition, NSURLCredential *)
) {
    SEL taskSel = @selector(URLSession:task:didReceiveChallenge:completionHandler:);
    SEL sessionSel = @selector(URLSession:didReceiveChallenge:completionHandler:);
    BOOL targetHandlesChallenge = (target != nil) && (
        (task != nil && [target respondsToSelector:taskSel]) ||
        (task == nil && [target respondsToSelector:sessionSel])
    );
    ps_handle_server_trust_challenge(
        challenge,
        targetHandlesChallenge,
        ^(void (^effectiveCompletion)(NSURLSessionAuthChallengeDisposition, NSURLCredential *)) {
            if (task != nil) {
                [(id<NSURLSessionTaskDelegate>)target URLSession:session task:task didReceiveChallenge:challenge completionHandler:effectiveCompletion];
            } else {
                [(id<NSURLSessionDelegate>)target URLSession:session didReceiveChallenge:challenge completionHandler:effectiveCompletion];
            }
        },
        completionHandler
    );
}

static const char s_ptWKNavTrustProxyKey = 0;
static const char s_ptWKDataStoreProxyAppliedKey = 0;

__attribute__((visibility("hidden")))
@interface PTNetworkWKNavigationTrustProxy : NSProxy
@property (nonatomic, weak, readonly, nullable) id target;
- (instancetype)initWithTarget:(nullable id)target;
@end

@implementation PTNetworkWKNavigationTrustProxy

- (instancetype)initWithTarget:(nullable id)target {
    _target = target;
    return self;
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    SEL wkChallengeSel = NSSelectorFromString(@"webView:didReceiveAuthenticationChallenge:completionHandler:");
    if (aSelector == wkChallengeSel) {
        return YES;
    }
    id target = _target;
    return (target != nil && [target respondsToSelector:aSelector]);
}

- (BOOL)conformsToProtocol:(Protocol *)aProtocol {
    id target = _target;
    if (target != nil) {
        return [target conformsToProtocol:aProtocol];
    }
    return [super conformsToProtocol:aProtocol];
}

- (BOOL)isKindOfClass:(Class)aClass {
    id target = _target;
    if (target != nil) {
        return [target isKindOfClass:aClass];
    }
    return NO;
}

- (NSString *)description {
    id target = _target;
    return target != nil ? [target description] : @"<WKNavigationDelegate>";
}

- (NSString *)debugDescription {
    id target = _target;
    return target != nil ? [target debugDescription] : @"<WKNavigationDelegate>";
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    SEL wkChallengeSel = NSSelectorFromString(@"webView:didReceiveAuthenticationChallenge:completionHandler:");
    if (aSelector == wkChallengeSel) {
        return nil;
    }
    return _target;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    id target = _target;
    if (target != nil) {
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        if (sig != nil) {
            return sig;
        }
    }
    return [NSMethodSignature signatureWithObjCTypes:"v@:"];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    id target = _target;
    if (target != nil && [target respondsToSelector:invocation.selector]) {
        [invocation invokeWithTarget:target];
    }
}

- (void)webView:(id)webView
didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    id target = _target;
    SEL wkChallengeSel = NSSelectorFromString(@"webView:didReceiveAuthenticationChallenge:completionHandler:");
    BOOL targetHandlesChallenge = (target != nil && [target respondsToSelector:wkChallengeSel]);
    ps_handle_server_trust_challenge(
        challenge,
        targetHandlesChallenge,
        ^(void (^effectiveCompletion)(NSURLSessionAuthChallengeDisposition, NSURLCredential *)) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(target, wkChallengeSel, webView, challenge, effectiveCompletion);
        },
        completionHandler
    );
}

@end

__attribute__((visibility("hidden"))) id ps_create_nw_proxy_config_for_snapshot(PSNetworkRuleSnapshot *snap) {
    if (snap == nil || snap.proxyHost.length == 0 || snap.proxyPort <= 0) {
        return nil;
    }
    char portBuf[16];
    snprintf(portBuf, sizeof(portBuf), "%ld", (long)snap.proxyPort);
    nw_endpoint_t proxyEndpoint = nw_endpoint_create_host([snap.proxyHost UTF8String], portBuf);
    if (proxyEndpoint == nil) {
        return nil;
    }
    return snap.proxyIsSOCKS5
        ? (id)nw_proxy_config_create_socksv5(proxyEndpoint)
        : (id)nw_proxy_config_create_http_connect(proxyEndpoint, NULL);
}

static void ps_apply_proxy_to_wk_data_store(id dataStore) {
    if (dataStore == nil || [PTSafeMode isActive]) {
        return;
    }
    SEL setSel = NSSelectorFromString(@"setProxyConfigurations:");
    SEL getSel = NSSelectorFromString(@"proxyConfigurations");
    if (![dataStore respondsToSelector:setSel]) {
        return;
    }
    PSNetworkRuleSnapshot *snap = ps_get_network_snapshot();
    if (snap != nil && snap.proxyHost.length > 0 && snap.proxyPort > 0) {
        NSArray *existing = [dataStore respondsToSelector:getSel]
            ? ((id (*)(id, SEL))objc_msgSend)(dataStore, getSel)
            : nil;
        BOOL taggedByUs = [objc_getAssociatedObject(dataStore, &s_ptWKDataStoreProxyAppliedKey) boolValue];
        if (existing.count > 0 && !taggedByUs) {
            return;
        }
        id proxyCfg = ps_create_nw_proxy_config_for_snapshot(snap);
        if (proxyCfg != nil) {
            @try {
                ((void (*)(id, SEL, NSArray *))objc_msgSend)(dataStore, setSel, @[ proxyCfg ]);
                objc_setAssociatedObject(dataStore, &s_ptWKDataStoreProxyAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            } @catch (NSException *exception) {
                (void)exception;
            }
        }
    } else if ([objc_getAssociatedObject(dataStore, &s_ptWKDataStoreProxyAppliedKey) boolValue]) {
        @try {
            ((void (*)(id, SEL, NSArray *))objc_msgSend)(dataStore, setSel, nil);
            objc_setAssociatedObject(dataStore, &s_ptWKDataStoreProxyAppliedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } @catch (NSException *exception) {
            (void)exception;
        }
    }
}

__attribute__((visibility("hidden"))) void ps_apply_proxy_to_wk_configuration(id cfg) {
    if (cfg == nil || [PTSafeMode isActive]) {
        return;
    }
    PSNetworkRuleSnapshot *snap = ps_get_network_snapshot();
    if (snap == nil || (snap.proxyHost.length == 0 && snap.customCertificates.count == 0)) {
        return;
    }
    SEL dsSel = NSSelectorFromString(@"websiteDataStore");
    if ([cfg respondsToSelector:dsSel]) {
        id dataStore = ((id (*)(id, SEL))objc_msgSend)(cfg, dsSel);
        ps_apply_proxy_to_wk_data_store(dataStore);
    }
}

__attribute__((visibility("hidden"))) void ps_install_default_wk_trust_delegate(id webView) {
    if (webView == nil || [PTSafeMode isActive]) {
        return;
    }
    SEL cfgSel = NSSelectorFromString(@"configuration");
    if ([webView respondsToSelector:cfgSel]) {
        id cfg = ((id (*)(id, SEL))objc_msgSend)(webView, cfgSel);
        ps_apply_proxy_to_wk_configuration(cfg);
    }
    PSNetworkRuleSnapshot *snap = ps_get_network_snapshot();
    if (snap == nil || snap.customCertificates.count == 0) {
        return;
    }
    SEL getNavSel = NSSelectorFromString(@"navigationDelegate");
    SEL setNavSel = NSSelectorFromString(@"setNavigationDelegate:");
    if (![webView respondsToSelector:getNavSel] || ![webView respondsToSelector:setNavSel]) {
        return;
    }
    id existing = ((id (*)(id, SEL))objc_msgSend)(webView, getNavSel);
    if (existing == nil || object_getClass(existing) != [PTNetworkWKNavigationTrustProxy class]) {
        ((void (*)(id, SEL, id))objc_msgSend)(webView, setNavSel, existing);
    }
}

__attribute__((visibility("hidden")))
@interface PTNetworkSessionTrustProxy : NSProxy <NSURLSessionDelegate, NSURLSessionTaskDelegate, NSURLSessionDataDelegate, NSURLSessionDownloadDelegate>
@property (nonatomic, strong, readonly, nullable) id target;
- (instancetype)initWithTarget:(nullable id)target;
@end

@implementation PTNetworkSessionTrustProxy

- (instancetype)initWithTarget:(nullable id)target {
    _target = target;
    return self;
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector == @selector(URLSession:task:didReceiveChallenge:completionHandler:)) {
        return (_target != nil && [_target respondsToSelector:aSelector]);
    }
    if (aSelector == @selector(URLSession:didReceiveChallenge:completionHandler:)) {
        if (_target == nil) {
            return YES;
        }
        if (![_target respondsToSelector:@selector(URLSession:task:didReceiveChallenge:completionHandler:)]) {
            return YES;
        }
        return [_target respondsToSelector:aSelector];
    }
    return (_target != nil && [_target respondsToSelector:aSelector]);
}

- (BOOL)conformsToProtocol:(Protocol *)aProtocol {
    if (_target != nil) {
        return [_target conformsToProtocol:aProtocol];
    }
    return [super conformsToProtocol:aProtocol];
}

- (BOOL)isKindOfClass:(Class)aClass {
    if (_target != nil) {
        return [_target isKindOfClass:aClass];
    }
    return NO;
}

- (NSString *)description {
    return _target != nil ? [_target description] : @"<NSURLSessionDelegate>";
}

- (NSString *)debugDescription {
    return _target != nil ? [_target debugDescription] : @"<NSURLSessionDelegate>";
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    if (aSelector == @selector(URLSession:didReceiveChallenge:completionHandler:) ||
        aSelector == @selector(URLSession:task:didReceiveChallenge:completionHandler:)) {
        return nil;
    }
    return _target;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    if (_target != nil) {
        NSMethodSignature *sig = [_target methodSignatureForSelector:sel];
        if (sig != nil) {
            return sig;
        }
    }
    return [NSMethodSignature signatureWithObjCTypes:"v@:"];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    if (_target != nil && [_target respondsToSelector:invocation.selector]) {
        [invocation invokeWithTarget:_target];
    }
}

- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    ps_handle_url_session_trust_challenge(_target, session, nil, challenge, completionHandler);
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    ps_handle_url_session_trust_challenge(_target, session, task, challenge, completionHandler);
}

@end

static os_unfair_lock s_ptSharedSessionLock = OS_UNFAIR_LOCK_INIT;
static NSURLSession *s_ptSharedSession = nil;
static _Thread_local BOOL t_ptCreatingSharedSession = NO;

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

+ (NSURLSessionConfiguration *) pm_backgroundSessionConfigurationWithIdentifier:(NSString *)identifier {
    NSURLSessionConfiguration *config = [self pm_backgroundSessionConfigurationWithIdentifier:identifier];
    ps_inject_block_protocol_into_config(config);
    return config;
}

- (NSDictionary *) pm_ps_connectionProxyDictionary {
    const void *caller = __builtin_return_address(0);
    NSDictionary *dict = [self pm_ps_connectionProxyDictionary];
    if (dict.count == 0 || ps_is_effective_system_or_playtools_caller(caller)) {
        return dict;
    }
    PSNetworkRuleSnapshot *snap = [PTSafeMode isActive] ? nil : ps_get_network_snapshot();
    if (snap != nil && snap.hideProxyFromApp && pt_is_bypass_enabled() &&
        ([objc_getAssociatedObject(self, &s_ptProxyInjectedTagKey) boolValue] ||
         ps_proxy_dict_matches_snapshot(dict, snap))) {
        return nil;
    }
    return dict;
}

- (void) pm_ps_setConnectionProxyDictionary:(NSDictionary *)proxyDict {
    PSNetworkRuleSnapshot *snap = [PTSafeMode isActive] ? nil : ps_get_network_snapshot();
    if (snap != nil && snap.activeProxyDictionary.count > 0 && !ps_dict_has_active_proxy(proxyDict)) {
        [self pm_ps_setConnectionProxyDictionary:snap.activeProxyDictionary];
        objc_setAssociatedObject(self, &s_ptProxyInjectedTagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    objc_setAssociatedObject(self, &s_ptProxyInjectedTagKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self pm_ps_setConnectionProxyDictionary:proxyDict];
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
    if (ps_get_network_rules() != nil) {
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
    }
    [self pm_setProtocolClasses:protocolClasses];
}

+ (NSURLSession *) pm_sharedSession {
    if (t_ptCreatingSharedSession || [PTSafeMode isActive]) {
        return [self pm_sharedSession];
    }
    PSNetworkRuleSnapshot *snap = ps_get_network_snapshot();
    BOOL needsCustomSession = (snap != nil &&
                               (snap.customCertificates.count > 0 ||
                                snap.activeProxyDictionary.count > 0 ||
                                (snap.enabled && (snap.hostRules.count > 0 ||
                                                  snap.urlRules.count > 0 ||
                                                  snap.regexRules.count > 0))));
    if (!needsCustomSession) {
        return [self pm_sharedSession];
    }
    os_unfair_lock_lock(&s_ptSharedSessionLock);
    NSURLSession *existing = s_ptSharedSession;
    os_unfair_lock_unlock(&s_ptSharedSessionLock);
    if (existing != nil) {
        return existing;
    }

    t_ptCreatingSharedSession = YES;
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    ps_inject_block_protocol_into_config(cfg);
    id<NSURLSessionDelegate> delegateProxy = (snap.customCertificates.count > 0)
        ? [[PTNetworkSessionTrustProxy alloc] initWithTarget:nil]
        : nil;
    NSURLSession *created = [self pm_sessionWithConfiguration:cfg delegate:delegateProxy delegateQueue:nil];
    t_ptCreatingSharedSession = NO;

    os_unfair_lock_lock(&s_ptSharedSessionLock);
    if (s_ptSharedSession == nil) {
        s_ptSharedSession = created;
    } else {
        created = s_ptSharedSession;
    }
    os_unfair_lock_unlock(&s_ptSharedSessionLock);
    return created;
}

+ (NSURLSession *) pm_sessionWithConfiguration:(NSURLSessionConfiguration *)configuration {
    ps_inject_block_protocol_into_config(configuration);
    PSNetworkRuleSnapshot *snap = [PTSafeMode isActive] ? nil : ps_get_network_snapshot();
    BOOL isBackground = ([configuration respondsToSelector:@selector(identifier)] &&
                         configuration.identifier.length > 0);
    if (snap != nil && snap.customCertificates.count > 0 && !isBackground) {
        PTNetworkSessionTrustProxy *proxy = [[PTNetworkSessionTrustProxy alloc] initWithTarget:nil];
        return [self pm_sessionWithConfiguration:configuration delegate:proxy delegateQueue:nil];
    }
    return [self pm_sessionWithConfiguration:configuration];
}

+ (NSURLSession *) pm_sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
                                      delegate:(id<NSURLSessionDelegate>)delegate
                                 delegateQueue:(NSOperationQueue *)queue {
    ps_inject_block_protocol_into_config(configuration);
    id<NSURLSessionDelegate> effectiveDelegate = delegate;
    PSNetworkRuleSnapshot *snap = [PTSafeMode isActive] ? nil : ps_get_network_snapshot();
    BOOL isBackgroundWithoutDelegate = ([configuration respondsToSelector:@selector(identifier)] &&
                                        configuration.identifier.length > 0 &&
                                        delegate == nil);
    if (snap != nil && snap.customCertificates.count > 0 && !isBackgroundWithoutDelegate) {
        if (delegate == nil || object_getClass(delegate) != [PTNetworkSessionTrustProxy class]) {
            effectiveDelegate = [[PTNetworkSessionTrustProxy alloc] initWithTarget:delegate];
        }
    }
    return [self pm_sessionWithConfiguration:configuration delegate:effectiveDelegate delegateQueue:queue];
}

- (id<NSURLSessionDelegate>) pm_ps_sessionDelegate {
    id del = [self pm_ps_sessionDelegate];
    if (del != nil && object_getClass(del) == [PTNetworkSessionTrustProxy class] &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ((PTNetworkSessionTrustProxy *)del).target;
    }
    return del;
}

- (void) pm_ps_setTaskDelegate:(id<NSURLSessionTaskDelegate>)delegate {
    id<NSURLSessionTaskDelegate> effectiveDelegate = delegate;
    PSNetworkRuleSnapshot *snap = [PTSafeMode isActive] ? nil : ps_get_network_snapshot();
    if (snap != nil && snap.customCertificates.count > 0 && delegate != nil &&
        object_getClass(delegate) != [PTNetworkSessionTrustProxy class]) {
        effectiveDelegate = [[PTNetworkSessionTrustProxy alloc] initWithTarget:delegate];
    }
    [self pm_ps_setTaskDelegate:effectiveDelegate];
}

- (id<NSURLSessionTaskDelegate>) pm_ps_taskDelegate {
    id del = [self pm_ps_taskDelegate];
    if (del != nil && object_getClass(del) == [PTNetworkSessionTrustProxy class] &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ((PTNetworkSessionTrustProxy *)del).target;
    }
    return del;
}

@end


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
    PSNetworkRuleSnapshot *snap = ps_get_network_snapshot();
    BOOL hasBlocking = (snap != nil && snap.enabled &&
        (snap.hostRules.count > 0 || snap.urlRules.count > 0 || snap.regexRules.count > 0));
    if (hasBlocking) {
        PT_DEBUG_TRACE("network", "installing network blocker hooks hosts=%lu urls=%lu regex=%lu",
                       (unsigned long)snap.hostRules.count,
                       (unsigned long)snap.urlRules.count,
                       (unsigned long)snap.regexRules.count);
        [NSURLProtocol registerClass:[PTNetworkBlockProtocol class]];
    }
    Class cfgCls = objc_getClass("NSURLSessionConfiguration");
    ps_swizzle_class_method(cfgCls, @selector(defaultSessionConfiguration), @selector(pm_defaultSessionConfiguration));
    ps_swizzle_class_method(cfgCls, @selector(ephemeralSessionConfiguration), @selector(pm_ephemeralSessionConfiguration));
    if ([cfgCls respondsToSelector:@selector(backgroundSessionConfigurationWithIdentifier:)]) {
        ps_swizzle_class_method(cfgCls, @selector(backgroundSessionConfigurationWithIdentifier:), @selector(pm_backgroundSessionConfigurationWithIdentifier:));
    }
    NSURLSessionConfiguration *sampleCfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    Class concreteCfgCls = sampleCfg != nil ? object_getClass(sampleCfg) : cfgCls;
    ps_swizzle_cfg_instance_methods_if_needed(concreteCfgCls);
    Class sessionCls = objc_getClass("NSURLSession");
    ps_swizzle_class_method(sessionCls, @selector(sharedSession), @selector(pm_sharedSession));
    ps_swizzle_class_method(sessionCls, @selector(sessionWithConfiguration:), @selector(pm_sessionWithConfiguration:));
    ps_swizzle_class_method(sessionCls, @selector(sessionWithConfiguration:delegate:delegateQueue:), @selector(pm_sessionWithConfiguration:delegate:delegateQueue:));
    ps_swizzle_instance_method(sessionCls, @selector(delegate), @selector(pm_ps_sessionDelegate));
    Class taskCls = objc_getClass("NSURLSessionTask");
    if (taskCls != Nil) {
        if ([taskCls instancesRespondToSelector:@selector(setDelegate:)]) {
            ps_swizzle_instance_method(taskCls, @selector(setDelegate:), @selector(pm_ps_setTaskDelegate:));
        }
        if ([taskCls instancesRespondToSelector:@selector(delegate)]) {
            ps_swizzle_instance_method(taskCls, @selector(delegate), @selector(pm_ps_taskDelegate));
        }
    }
    ps_install_webkit_network_hooks_if_loaded();
}

@interface PSSwizzleHooks (PlayShadowWebKitNetwork)
@end

@implementation PSSwizzleHooks (PlayShadowWebKitNetwork)

+ (id) pm_wk_ds_defaultDataStore {
    id store = [self pm_wk_ds_defaultDataStore];
    ps_apply_proxy_to_wk_data_store(store);
    return store;
}

+ (id) pm_wk_ds_nonPersistentDataStore {
    id store = [self pm_wk_ds_nonPersistentDataStore];
    ps_apply_proxy_to_wk_data_store(store);
    return store;
}

+ (id) pm_wk_ds_dataStoreForIdentifier:(NSUUID *)identifier {
    id store = [self pm_wk_ds_dataStoreForIdentifier:identifier];
    ps_apply_proxy_to_wk_data_store(store);
    return store;
}

- (void) pm_wk_ds_setProxyConfigurations:(NSArray *)proxyConfigurations {
    if (proxyConfigurations.count == 0 && ![PTSafeMode isActive]) {
        PSNetworkRuleSnapshot *snap = ps_get_network_snapshot();
        if (snap != nil && snap.proxyHost.length > 0 && snap.proxyPort > 0) {
            id proxyCfg = ps_create_nw_proxy_config_for_snapshot(snap);
            if (proxyCfg != nil) {
                [self pm_wk_ds_setProxyConfigurations:@[ proxyCfg ]];
                objc_setAssociatedObject(self, &s_ptWKDataStoreProxyAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                return;
            }
        }
    }
    objc_setAssociatedObject(self, &s_ptWKDataStoreProxyAppliedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self pm_wk_ds_setProxyConfigurations:proxyConfigurations];
}

- (NSArray *) pm_wk_ds_proxyConfigurations {
    const void *caller = __builtin_return_address(0);
    NSArray *configs = [self pm_wk_ds_proxyConfigurations];
    if (configs.count == 0 || ps_is_effective_system_or_playtools_caller(caller)) {
        return configs;
    }
    PSNetworkRuleSnapshot *snap = [PTSafeMode isActive] ? nil : ps_get_network_snapshot();
    if (snap != nil && snap.hideProxyFromApp && pt_is_bypass_enabled() &&
        [objc_getAssociatedObject(self, &s_ptWKDataStoreProxyAppliedKey) boolValue]) {
        return nil;
    }
    return configs;
}

- (void) pm_wk_setNavigationDelegate:(id)navigationDelegate {
    PSNetworkRuleSnapshot *snap = [PTSafeMode isActive] ? nil : ps_get_network_snapshot();
    if (snap != nil && snap.customCertificates.count > 0) {
        id unwrapped = navigationDelegate;
        if (unwrapped != nil && object_getClass(unwrapped) == [PTNetworkWKNavigationTrustProxy class]) {
            unwrapped = ((PTNetworkWKNavigationTrustProxy *)unwrapped).target;
        }
        PTNetworkWKNavigationTrustProxy *proxy = [[PTNetworkWKNavigationTrustProxy alloc] initWithTarget:unwrapped];
        objc_setAssociatedObject(self, &s_ptWKNavTrustProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self pm_wk_setNavigationDelegate:proxy];
        return;
    }
    objc_setAssociatedObject(self, &s_ptWKNavTrustProxyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self pm_wk_setNavigationDelegate:navigationDelegate];
}

- (id) pm_wk_navigationDelegate {
    id del = [self pm_wk_navigationDelegate];
    if (del != nil && object_getClass(del) == [PTNetworkWKNavigationTrustProxy class] &&
        !ps_is_effective_system_or_playtools_caller(__builtin_return_address(0))) {
        return ((PTNetworkWKNavigationTrustProxy *)del).target;
    }
    return del;
}

@end

__attribute__((visibility("hidden"))) void ps_install_webkit_network_hooks_if_loaded(void) {
    if ([PTSafeMode isActive]) {
        return;
    }
    static os_unfair_lock s_wkNetHookLock = OS_UNFAIR_LOCK_INIT;
    static BOOL s_wkDataStoreHooked = NO;
    static BOOL s_wkWebViewNetHooked = NO;

    Class dsCls = objc_getClass("WKWebsiteDataStore");
    Class wkCls = objc_getClass("WKWebView");
    BOOL needDS = NO;
    BOOL needWK = NO;

    os_unfair_lock_lock(&s_wkNetHookLock);
    if (dsCls != Nil && !s_wkDataStoreHooked) {
        s_wkDataStoreHooked = YES;
        needDS = YES;
    }
    if (wkCls != Nil && !s_wkWebViewNetHooked) {
        s_wkWebViewNetHooked = YES;
        needWK = YES;
    }
    os_unfair_lock_unlock(&s_wkNetHookLock);

    if (needDS) {
        SEL defSel = NSSelectorFromString(@"defaultDataStore");
        SEL npSel = NSSelectorFromString(@"nonPersistentDataStore");
        SEL idSel = NSSelectorFromString(@"dataStoreForIdentifier:");
        SEL setProxySel = NSSelectorFromString(@"setProxyConfigurations:");
        SEL getProxySel = NSSelectorFromString(@"proxyConfigurations");
        if ([dsCls respondsToSelector:defSel]) {
            ps_swizzle_class_method(dsCls, defSel, @selector(pm_wk_ds_defaultDataStore));
        }
        if ([dsCls respondsToSelector:npSel]) {
            ps_swizzle_class_method(dsCls, npSel, @selector(pm_wk_ds_nonPersistentDataStore));
        }
        if ([dsCls respondsToSelector:idSel]) {
            ps_swizzle_class_method(dsCls, idSel, @selector(pm_wk_ds_dataStoreForIdentifier:));
        }
        if ([dsCls instancesRespondToSelector:setProxySel]) {
            ps_swizzle_instance_method(dsCls, setProxySel, @selector(pm_wk_ds_setProxyConfigurations:));
        }
        if ([dsCls instancesRespondToSelector:getProxySel]) {
            ps_swizzle_instance_method(dsCls, getProxySel, @selector(pm_wk_ds_proxyConfigurations));
        }
    }

    if (needWK) {
        SEL setNavSel = NSSelectorFromString(@"setNavigationDelegate:");
        SEL getNavSel = NSSelectorFromString(@"navigationDelegate");
        if ([wkCls instancesRespondToSelector:setNavSel]) {
            ps_swizzle_instance_method(wkCls, setNavSel, @selector(pm_wk_setNavigationDelegate:));
        }
        if ([wkCls instancesRespondToSelector:getNavSel]) {
            ps_swizzle_instance_method(wkCls, getNavSel, @selector(pm_wk_navigationDelegate));
        }
    }
}



static bool pt_SecTrustEvaluateWithError(SecTrustRef trust, CFErrorRef *error) {
    CFErrorRef firstErr = NULL;
    bool ok = SecTrustEvaluateWithError(trust, &firstErr);
    if (ok) {
        if (error != NULL) {
            *error = NULL;
        }
        if (firstErr != NULL) {
            CFRelease(firstErr);
        }
        return true;
    }

    PSNetworkRuleSnapshot *snap = ps_get_network_snapshot();
    if (ps_should_apply_custom_ca_for_trust(trust, snap)) {
        CFErrorRef customErr = NULL;
        if (ps_evaluate_trust_with_custom_anchors(trust, snap, &customErr)) {
            if (customErr != NULL) CFRelease(customErr);
            if (firstErr != NULL) CFRelease(firstErr);
            if (error != NULL) *error = NULL;
            return true;
        }
        if (customErr != NULL) {
            CFRelease(customErr);
        }
    }

    if (error != NULL) {
        *error = firstErr;
    } else if (firstErr != NULL) {
        CFRelease(firstErr);
    }
    return false;
}

static OSStatus pt_SecTrustEvaluateAsyncWithError(
    SecTrustRef trust,
    dispatch_queue_t queue,
    SecTrustWithErrorCallback result
) {
    if (result == nil) {
        return errSecParam;
    }
    SecTrustWithErrorCallback origResult = [result copy];
    return SecTrustEvaluateAsyncWithError(trust, queue, ^(SecTrustRef tRef, bool ok, CFErrorRef err) {
        if (!ok && tRef != NULL) {
            PSNetworkRuleSnapshot *snap = ps_get_network_snapshot();
            if (ps_should_apply_custom_ca_for_trust(tRef, snap)) {
                CFErrorRef customErr = NULL;
                if (ps_evaluate_trust_with_custom_anchors(tRef, snap, &customErr)) {
                    if (customErr != NULL) CFRelease(customErr);
                    origResult(tRef, true, NULL);
                    return;
                }
                if (customErr != NULL) CFRelease(customErr);
            }
        }
        origResult(tRef, ok, err);
    });
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static OSStatus pt_SecTrustEvaluate(SecTrustRef trust, SecTrustResultType *result) {
    OSStatus status = SecTrustEvaluate(trust, result);
    if (status == errSecSuccess && result != NULL &&
        (*result == kSecTrustResultUnspecified || *result == kSecTrustResultProceed)) {
        return status;
    }
    PSNetworkRuleSnapshot *snap = ps_get_network_snapshot();
    if (ps_should_apply_custom_ca_for_trust(trust, snap)) {
        if (ps_evaluate_trust_with_custom_anchors(trust, snap, NULL)) {
            SecTrustResultType evaluatedResult = kSecTrustResultUnspecified;
            (void)SecTrustGetTrustResult(trust, &evaluatedResult);
            if (result != NULL) {
                *result = evaluatedResult;
            }
            return errSecSuccess;
        }
    }
    return status;
}

static OSStatus pt_SecTrustEvaluateAsync(
    SecTrustRef trust,
    dispatch_queue_t queue,
    SecTrustCallback result
) {
    if (result == nil) {
        return errSecParam;
    }
    SecTrustCallback origResult = [result copy];
    return SecTrustEvaluateAsync(trust, queue, ^(SecTrustRef tRef, SecTrustResultType trustResult) {
        if (tRef != NULL && trustResult != kSecTrustResultUnspecified && trustResult != kSecTrustResultProceed) {
            PSNetworkRuleSnapshot *snap = ps_get_network_snapshot();
            if (ps_should_apply_custom_ca_for_trust(tRef, snap) &&
                ps_evaluate_trust_with_custom_anchors(tRef, snap, NULL)) {
                SecTrustResultType customResult = kSecTrustResultUnspecified;
                (void)SecTrustGetTrustResult(tRef, &customResult);
                origResult(tRef, customResult);
                return;
            }
        }
        origResult(tRef, trustResult);
    });
}
#pragma clang diagnostic pop

static void ps_attach_custom_ca_verify_block(sec_protocol_options_t secOpts) {
    if (secOpts == nil) return;
    dispatch_queue_t verifyQueue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    sec_protocol_options_set_verify_block(
        secOpts,
        ^(sec_protocol_metadata_t metadata __unused, sec_trust_t trust, sec_protocol_verify_complete_t complete) {
            SecTrustRef trustRef = sec_trust_copy_ref(trust);
            if (trustRef != NULL) {
                CFErrorRef cfErr = NULL;
                bool ok = pt_SecTrustEvaluateWithError(trustRef, &cfErr);
                if (cfErr != NULL) CFRelease(cfErr);
                CFRelease(trustRef);
                complete(ok);
            } else {
                complete(false);
            }
        },
        verifyQueue
    );
}

static NW_RETURNS_RETAINED nw_protocol_options_t pt_nw_tls_create_options(void) {
    nw_protocol_options_t opts = nw_tls_create_options();
    if (opts != nil && ![PTSafeMode isActive]) {
        PSNetworkRuleSnapshot *snap = ps_get_network_snapshot();
        if (snap != nil && snap.customCertificates.count > 0) {
            sec_protocol_options_t secOpts = nw_tls_copy_sec_protocol_options(opts);
            ps_attach_custom_ca_verify_block(secOpts);
        }
    }
    return opts;
}

static const char s_ptNWParamsProxyAppliedKey = 0;

static BOOL ps_is_loopback_or_proxy_host(const char *host, PSNetworkRuleSnapshot *snap) {
    if (host == NULL || host[0] == '\0') {
        return YES;
    }
    if (strcasecmp(host, "localhost") == 0 ||
        strcmp(host, "127.0.0.1") == 0 ||
        strcmp(host, "::1") == 0 ||
        strcmp(host, "0.0.0.0") == 0) {
        return YES;
    }
    if (snap != nil && snap.proxyHost.length > 0 &&
        strcasecmp(host, snap.proxyHost.UTF8String) == 0) {
        return YES;
    }
    return NO;
}

static BOOL ps_is_loopback_proxy_url(CFURLRef urlRef, PSNetworkRuleSnapshot *snap) {
    if (urlRef == NULL) {
        return YES;
    }
    NSURL *nsurl = (__bridge NSURL *)urlRef;
    NSString *scheme = nsurl.scheme.lowercaseString;
    if (scheme.length == 0 ||
        [scheme isEqualToString:@"file"] ||
        [scheme isEqualToString:@"about"] ||
        [scheme isEqualToString:@"data"]) {
        return YES;
    }
    NSString *host = nsurl.host;
    if (host.length == 0) {
        return YES;
    }
    return ps_is_loopback_or_proxy_host(host.UTF8String, snap);
}

static void ps_apply_nw_proxy_if_needed(nw_parameters_t params, PSNetworkRuleSnapshot *snap) {
    if (params == nil || snap == nil || snap.proxyHost.length == 0 || snap.proxyPort <= 0) {
        return;
    }
    if (objc_getAssociatedObject(params, &s_ptNWParamsProxyAppliedKey) != nil) {
        return;
    }
    nw_proxy_config_t proxyCfg = ps_create_nw_proxy_config_for_snapshot(snap);
    if (proxyCfg != nil) {
        nw_privacy_context_t privacyCtx = nw_privacy_context_create("MacOverProxy");
        if (privacyCtx != nil) {
            nw_privacy_context_add_proxy(privacyCtx, proxyCfg);
            nw_parameters_set_privacy_context(params, privacyCtx);
            objc_setAssociatedObject(params, &s_ptNWParamsProxyAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

static NW_RETURNS_RETAINED nw_parameters_t pt_nw_parameters_create_secure_tcp(
    nw_parameters_configure_protocol_block_t configure_tls,
    nw_parameters_configure_protocol_block_t configure_tcp
) {
    PSNetworkRuleSnapshot *snap = [PTSafeMode isActive] ? nil : ps_get_network_snapshot();
    nw_parameters_configure_protocol_block_t effectiveTLS = configure_tls;
    nw_parameters_configure_protocol_block_t copiedOrigTLS = nil;

    if (snap != nil && snap.customCertificates.count > 0 &&
        configure_tls != NULL && configure_tls != NW_PARAMETERS_DISABLE_PROTOCOL) {
        BOOL hasUserBlock = (configure_tls != NW_PARAMETERS_DEFAULT_CONFIGURATION);
        copiedOrigTLS = hasUserBlock ? [configure_tls copy] : nil;
        BOOL allowPinBypass = snap.mitmAllowPinningBypass;
        effectiveTLS = ^(nw_protocol_options_t options) {
            sec_protocol_options_t secOpts = nw_tls_copy_sec_protocol_options(options);
            if (!allowPinBypass) {
                ps_attach_custom_ca_verify_block(secOpts);
                if (copiedOrigTLS != nil) {
                    copiedOrigTLS(options);
                }
            } else {
                if (copiedOrigTLS != nil) {
                    copiedOrigTLS(options);
                }
                ps_attach_custom_ca_verify_block(secOpts);
            }
        };
    }

    if (effectiveTLS == NULL) {
        effectiveTLS = NW_PARAMETERS_DEFAULT_CONFIGURATION;
    }
    nw_parameters_configure_protocol_block_t effectiveTCP = configure_tcp != NULL
        ? configure_tcp
        : NW_PARAMETERS_DEFAULT_CONFIGURATION;
    nw_parameters_t params = nw_parameters_create_secure_tcp(effectiveTLS, effectiveTCP);
    return params;
}

static NW_RETURNS_RETAINED nw_connection_t pt_nw_connection_create(
    nw_endpoint_t endpoint,
    nw_parameters_t parameters
) {
    if (endpoint == nil || parameters == nil) {
        return nil;
    }
    nw_parameters_t effectiveParams = parameters;
    PSNetworkRuleSnapshot *snap = [PTSafeMode isActive] ? nil : ps_get_network_snapshot();
    if (snap != nil && snap.proxyHost.length > 0 && snap.proxyPort > 0) {
        nw_endpoint_type_t endpointType = nw_endpoint_get_type(endpoint);
        BOOL eligibleTarget = NO;
        if (endpointType == nw_endpoint_type_host) {
            const char *host = nw_endpoint_get_hostname(endpoint);
            eligibleTarget = !ps_is_loopback_or_proxy_host(host, snap);
        } else if (endpointType == nw_endpoint_type_url) {
            const char *urlStr = nw_endpoint_get_url(endpoint);
            if (urlStr != NULL) {
                NSURL *parsed = [NSURL URLWithString:[NSString stringWithUTF8String:urlStr]];
                eligibleTarget = (parsed != nil && !ps_is_loopback_proxy_url((__bridge CFURLRef)parsed, snap));
            }
        }
        if (eligibleTarget) {
            BOOL isUDP = NO;
            nw_protocol_stack_t stack = nw_parameters_copy_default_protocol_stack(parameters);
            if (stack != nil) {
                nw_protocol_options_t transport = nw_protocol_stack_copy_transport_protocol(stack);
                if (transport != nil) {
                    nw_protocol_definition_t transportDef = nw_protocol_options_copy_definition(transport);
                    nw_protocol_definition_t udpDef = nw_protocol_copy_udp_definition();
                    if (transportDef != nil && udpDef != nil) {
                        isUDP = nw_protocol_definition_is_equal(transportDef, udpDef);
                    }
                }
            }
            if (!isUDP) {
                nw_parameters_t copied = nw_parameters_copy(parameters);
                if (copied != nil) {
                    ps_apply_nw_proxy_if_needed(copied, snap);
                    effectiveParams = copied;
                } else {
                    ps_apply_nw_proxy_if_needed(effectiveParams, snap);
                }
            }
        }
    }
    return nw_connection_create(endpoint, effectiveParams);
}

static NSMutableDictionary *ps_copy_merged_proxy_dictionary(CFDictionaryRef orig, PSNetworkRuleSnapshot *snap) {
    NSMutableDictionary *merged = orig != NULL
        ? [(__bridge NSDictionary *)orig mutableCopy]
        : [NSMutableDictionary dictionary];
    [merged removeObjectsForKeys:@[
        @"HTTPEnable", @"HTTPProxy", @"HTTPPort",
        @"HTTPSEnable", @"HTTPSProxy", @"HTTPSPort",
        @"SOCKSEnable", @"SOCKSProxy", @"SOCKSPort",
        @"ProxyAutoConfigEnable", @"ProxyAutoConfigURLString",
        @"ProxyAutoDiscoveryEnable", @"ExceptionsList", @"__SCOPED__"
    ]];
    if (snap.activeProxyDictionary.count > 0) {
        [merged addEntriesFromDictionary:snap.activeProxyDictionary];
    }
    return merged;
}

static CFDictionaryRef pt_CFNetworkCopySystemProxySettings(void) {
    const void *caller = __builtin_return_address(0);
    PSNetworkRuleSnapshot *snap = [PTSafeMode isActive] ? nil : ps_get_network_snapshot();
    if (snap != nil && snap.hideProxyFromApp && pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(caller)) {
        return CFDictionaryCreateCopy(kCFAllocatorDefault, (__bridge CFDictionaryRef)@{});
    }
    CFDictionaryRef orig = CFNetworkCopySystemProxySettings();
    if (snap != nil && snap.activeProxyDictionary.count > 0) {
        NSMutableDictionary *merged = ps_copy_merged_proxy_dictionary(orig, snap);
        if (orig != NULL) CFRelease(orig);
        return CFDictionaryCreateCopy(kCFAllocatorDefault, (__bridge CFDictionaryRef)merged);
    }
    return orig;
}

static CFArrayRef pt_CFNetworkCopyProxiesForURL(CFURLRef url, CFDictionaryRef proxySettings) {
    const void *caller = __builtin_return_address(0);
    PSNetworkRuleSnapshot *snap = [PTSafeMode isActive] ? nil : ps_get_network_snapshot();
    if (snap != nil && snap.hideProxyFromApp && pt_is_bypass_enabled() &&
        !ps_is_effective_system_or_playtools_caller(caller)) {
        NSArray *hidden = @[ @{ (__bridge NSString *)kCFProxyTypeKey: (__bridge NSString *)kCFProxyTypeNone } ];
        return CFArrayCreateCopy(kCFAllocatorDefault, (__bridge CFArrayRef)hidden);
    }
    CFDictionaryRef effectiveSettings = proxySettings;
    CFDictionaryRef synthesizedSettings = NULL;
    if (snap != nil && snap.activeProxyDictionary.count > 0 && !ps_is_loopback_proxy_url(url, snap)) {
        NSDictionary *inDict = (__bridge NSDictionary *)proxySettings;
        if (!ps_dict_has_active_proxy(inDict)) {
            NSMutableDictionary *merged = ps_copy_merged_proxy_dictionary(proxySettings, snap);
            synthesizedSettings = CFDictionaryCreateCopy(kCFAllocatorDefault, (__bridge CFDictionaryRef)merged);
            effectiveSettings = synthesizedSettings;
        }
    }
    if (effectiveSettings == NULL) {
        synthesizedSettings = CFDictionaryCreateCopy(kCFAllocatorDefault, (__bridge CFDictionaryRef)@{});
        effectiveSettings = synthesizedSettings;
    }
    CFArrayRef orig = CFNetworkCopyProxiesForURL(url, effectiveSettings);
    if (synthesizedSettings != NULL) {
        CFRelease(synthesizedSettings);
    }
    if (snap != nil && snap.activeProxyDictionary.count > 0 && !ps_is_loopback_proxy_url(url, snap)) {
        NSURL *nsurl = (__bridge NSURL *)url;
        NSString *scheme = nsurl.scheme.lowercaseString;
        NSString *proxyType = snap.proxyIsSOCKS5
            ? (__bridge NSString *)kCFProxyTypeSOCKS
            : (([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"wss"])
               ? (__bridge NSString *)kCFProxyTypeHTTPS
               : (__bridge NSString *)kCFProxyTypeHTTP);
        NSDictionary *injectedEntry = @{
            (__bridge NSString *)kCFProxyTypeKey: proxyType,
            (__bridge NSString *)kCFProxyHostNameKey: snap.proxyHost,
            (__bridge NSString *)kCFProxyPortNumberKey: @(snap.proxyPort)
        };
        NSArray *origArr = (__bridge NSArray *)orig;
        NSDictionary *first = ([origArr.firstObject isKindOfClass:[NSDictionary class]]) ? origArr.firstObject : nil;
        NSString *firstHost = [first[(__bridge NSString *)kCFProxyHostNameKey] isKindOfClass:[NSString class]]
            ? first[(__bridge NSString *)kCFProxyHostNameKey]
            : nil;
        NSNumber *firstPort = [first[(__bridge NSString *)kCFProxyPortNumberKey] respondsToSelector:@selector(integerValue)]
            ? first[(__bridge NSString *)kCFProxyPortNumberKey]
            : nil;
        if (firstHost == nil || ![firstHost isEqualToString:snap.proxyHost] || firstPort.integerValue != snap.proxyPort) {
            NSMutableArray *updated = [NSMutableArray arrayWithObject:injectedEntry];
            for (id item in origArr) {
                if ([item isKindOfClass:[NSDictionary class]]) {
                    NSString *t = item[(__bridge NSString *)kCFProxyTypeKey];
                    if ([t isKindOfClass:[NSString class]] && [t isEqualToString:(__bridge NSString *)kCFProxyTypeNone]) {
                        continue;
                    }
                }
                [updated addObject:item];
            }
            if (orig != NULL) CFRelease(orig);
            return CFArrayCreateCopy(kCFAllocatorDefault, (__bridge CFArrayRef)updated);
        }
    }
    return orig;
}

PT_INTERPOSE(pt_SecTrustEvaluateWithError, SecTrustEvaluateWithError)
PT_INTERPOSE(pt_SecTrustEvaluateAsyncWithError, SecTrustEvaluateAsyncWithError)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
PT_INTERPOSE(pt_SecTrustEvaluate, SecTrustEvaluate)
PT_INTERPOSE(pt_SecTrustEvaluateAsync, SecTrustEvaluateAsync)
#pragma clang diagnostic pop
PT_INTERPOSE(pt_nw_tls_create_options, nw_tls_create_options)
PT_INTERPOSE(pt_nw_parameters_create_secure_tcp, nw_parameters_create_secure_tcp)
PT_INTERPOSE(pt_nw_connection_create, nw_connection_create)
PT_INTERPOSE(pt_CFNetworkCopySystemProxySettings, CFNetworkCopySystemProxySettings)
PT_INTERPOSE(pt_CFNetworkCopyProxiesForURL, CFNetworkCopyProxiesForURL)
