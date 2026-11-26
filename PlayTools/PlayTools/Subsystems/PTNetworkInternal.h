//
//  PTNetworkInternal.h
//  PlayTools
//
//  Hidden declarations shared across PTNetworkRules, PTNetworkVirtualizer,
//  PTNetworkSocketIf, and other subsystems.
//

#ifndef PTNetworkInternal_h
#define PTNetworkInternal_h

#import "PTCommon.h"
@import CFNetwork;
@import Network;
@import SystemConfiguration;

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
@property (nonatomic, assign) BOOL enableCustomCertificates;
@property (nonatomic, assign) BOOL mitmAllHosts;
@property (nonatomic, assign) BOOL mitmAllowPinningBypass;
@property (nonatomic, assign) BOOL hideProxyFromApp;
@property (nonatomic, strong) NSArray<NSString *> *mitmHostRules;
@property (nonatomic, strong) NSArray *customCertificates;
@property (nonatomic, strong) NSDictionary<NSString *, id> *activeProxyDictionary;
@property (nonatomic, copy) NSString *proxyHost;
@property (nonatomic, assign) NSInteger proxyPort;
@property (nonatomic, assign) BOOL proxyIsSOCKS5;
@end

#ifdef __cplusplus
extern "C" {
#endif

extern __attribute__((visibility("hidden"))) _Atomic bool s_net_mock200_cached;
__attribute__((visibility("hidden"))) BOOL ps_is_network_blocking_possibly_active(void);
__attribute__((visibility("hidden"))) PSNetworkRuleSnapshot *ps_get_network_snapshot(void);
__attribute__((visibility("hidden"))) PSNetworkRuleSnapshot *ps_get_network_rules(void);
__attribute__((visibility("hidden"))) BOOL ps_should_block_url(NSURL *url, BOOL *outMock200);
__attribute__((visibility("hidden"))) int ps_should_block_host_cstr(const char *hostname);
__attribute__((visibility("hidden"))) BOOL ps_dict_has_active_proxy(NSDictionary *dict);
__attribute__((visibility("hidden"))) BOOL ps_host_matches_mitm_scope(NSString *host, PSNetworkRuleSnapshot *snap);
__attribute__((visibility("hidden"))) BOOL ps_should_apply_custom_ca_for_trust(SecTrustRef trust, PSNetworkRuleSnapshot *snap);
__attribute__((visibility("hidden"))) BOOL ps_evaluate_trust_with_custom_anchors(SecTrustRef trust, PSNetworkRuleSnapshot *snap, CFErrorRef *outError);
__attribute__((visibility("hidden"))) id ps_create_nw_proxy_config_for_snapshot(PSNetworkRuleSnapshot *snap);
__attribute__((visibility("hidden"))) void ps_swizzle_cfg_instance_methods_if_needed(Class concreteCfgCls);
__attribute__((visibility("hidden"))) void ps_notify_dynamic_image_loaded(void);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_network_ifname(const char *name);
__attribute__((visibility("hidden"))) void pt_network_notify_fd_dup(int oldfd, int newfd);
__attribute__((visibility("hidden"))) void pt_network_notify_fd_close(int fd);
__attribute__((visibility("hidden"))) int pt_network_ioctl_with_caller(int fd, unsigned long request, uintptr_t arg, const void *caller);
__attribute__((visibility("hidden"))) int pt_network_bind_with_caller(int socket, const struct sockaddr *address, socklen_t address_len, int raw_syscall_num, const void *caller);
__attribute__((visibility("hidden"))) int pt_network_connect_with_caller(int socket, const struct sockaddr *address, socklen_t address_len, int raw_syscall_num, const void *caller);
__attribute__((visibility("hidden"))) int pt_network_accept_with_caller(int socket, struct sockaddr * __restrict address, socklen_t * __restrict address_len, int raw_syscall_num, const void *caller);
__attribute__((visibility("hidden"))) ssize_t pt_network_sendto_with_caller(int socket, const void *buffer, size_t length, int flags, const struct sockaddr *dest_addr, socklen_t dest_len, int raw_syscall_num, const void *caller);
__attribute__((visibility("hidden"))) int pt_network_getsockname_with_caller(int socket, struct sockaddr * __restrict address, socklen_t * __restrict address_len, int raw_syscall_num, const void *caller);
__attribute__((visibility("hidden"))) int pt_network_getpeername_with_caller(int socket, struct sockaddr * __restrict address, socklen_t * __restrict address_len, int raw_syscall_num, const void *caller);

__attribute__((visibility("hidden"))) void ps_install_network_blocker_hooks(void);
__attribute__((visibility("hidden"))) void ps_install_webkit_network_hooks_if_loaded(void);
__attribute__((visibility("hidden"))) void ps_apply_proxy_to_wk_configuration(id cfg);
__attribute__((visibility("hidden"))) void ps_install_default_wk_trust_delegate(id webView);

#ifdef __cplusplus
}
#endif

#endif /* PTNetworkInternal_h */
