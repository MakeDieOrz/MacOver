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
#include <netinet/in.h>
#include <sys/socket.h>
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
@property (nonatomic, assign) BOOL isBuiltInMITM;
@property (nonatomic, assign) BOOL mitmAllHosts;
@property (nonatomic, assign) BOOL mitmAllowPinningBypass;
@property (nonatomic, assign) BOOL hideProxyFromApp;
@property (nonatomic, strong) NSArray<NSString *> *mitmHostRules;
@property (nonatomic, strong) NSArray *customCertificates;
@property (nonatomic, strong) NSDictionary<NSString *, id> *activeProxyDictionary;
@property (nonatomic, copy) NSString *proxyHost;
@property (nonatomic, assign) NSInteger proxyPort;
@property (nonatomic, assign) BOOL proxyIsSOCKS5;
// Pre-indexed host & URL lookup structures built at rule-load time
@property (nonatomic, strong) NSDictionary<NSString *, NSNumber *> *exactHostRuleIndex;
@property (nonatomic, strong) NSDictionary<NSString *, NSNumber *> *suffixHostRuleIndex;
@property (nonatomic, strong) NSArray<NSString *> *wildcardHostRules;
@property (nonatomic, strong) NSArray<NSNumber *> *wildcardHostRulePacked;
@property (nonatomic, strong) NSSet<NSString *> *allowExactHosts;
@property (nonatomic, strong) NSSet<NSString *> *allowSuffixHosts;
@property (nonatomic, strong) NSArray<NSString *> *allowWildcardHosts;
@property (nonatomic, strong) NSSet<NSString *> *dnsExemptExactHosts;
@property (nonatomic, strong) NSSet<NSString *> *dnsExemptSuffixHosts;
@property (nonatomic, strong) NSArray<NSString *> *dnsExemptWildcardHosts;
@property (nonatomic, strong) NSSet<NSString *> *mitmExactHosts;
@property (nonatomic, strong) NSSet<NSString *> *mitmSuffixHosts;
@property (nonatomic, strong) NSArray<NSString *> *mitmWildcardHosts;
@property (nonatomic, strong) NSArray<NSString *> *allowLiteralUrlRules;
@property (nonatomic, strong) NSArray<NSString *> *allowWildcardUrlRules;
@property (nonatomic, strong) NSArray<NSString *> *literalUrlRules;
@property (nonatomic, strong) NSArray<NSNumber *> *literalUrlRulePacked;
@property (nonatomic, strong) NSArray<NSString *> *wildcardUrlRules;
@property (nonatomic, strong) NSArray<NSNumber *> *wildcardUrlRulePacked;
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
__attribute__((visibility("hidden"))) void ps_trust_state_reset(SecTrustRef trust);
__attribute__((visibility("hidden"))) void ps_trust_state_set_anchors_only(SecTrustRef trust, BOOL anchorsOnly);
__attribute__((visibility("hidden"))) void ps_trust_state_clear_synthetic_result(SecTrustRef trust);
__attribute__((visibility("hidden"))) void ps_trust_state_set_synthetic_result(SecTrustRef trust, SecTrustResultType result, SecTrustRef evaluatedClone);
__attribute__((visibility("hidden"))) BOOL ps_trust_state_is_anchors_only(SecTrustRef trust);
__attribute__((visibility("hidden"))) BOOL ps_trust_state_get_synthetic_result(SecTrustRef trust, SecTrustResultType *outResult);
__attribute__((visibility("hidden"))) SecTrustRef ps_trust_state_copy_evaluated_clone(SecTrustRef trust) CF_RETURNS_RETAINED;
__attribute__((visibility("hidden"))) BOOL ps_is_hidden_proxy_ipv4_peer(uint32_t addr_be, uint16_t port_host);
__attribute__((visibility("hidden"))) BOOL ps_is_hidden_proxy_ipv6_peer(const struct in6_addr *addr6, uint16_t port_host);
__attribute__((visibility("hidden"))) BOOL ps_is_hidden_proxy_sockaddr(const struct sockaddr *sa, socklen_t sa_len);
__attribute__((visibility("hidden"))) void pt_network_record_mitm_peer(int fd, const struct sockaddr *peer, socklen_t len);
__attribute__((visibility("hidden"))) BOOL pt_network_lookup_mitm_peer(int fd, struct sockaddr_storage *out_addr, socklen_t *out_len);
__attribute__((visibility("hidden"))) BOOL pt_network_get_or_synth_mitm_peer(int fd, int family, BOOL record_in_table, struct sockaddr_storage *out_addr, socklen_t *out_len);
__attribute__((visibility("hidden"))) BOOL pt_network_get_spoofed_local_ip_for_proxied_socket(int family, struct sockaddr_storage *out_addr, socklen_t *out_len);
__attribute__((visibility("hidden"))) id ps_create_nw_proxy_config_for_snapshot(PSNetworkRuleSnapshot *snap);
__attribute__((visibility("hidden"))) void ps_swizzle_cfg_instance_methods_if_needed(Class concreteCfgCls);
__attribute__((visibility("hidden"))) void ps_notify_dynamic_image_loaded(void);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_network_ifname(const char *name);
__attribute__((visibility("hidden"))) void pt_network_notify_fd_dup(int oldfd, int newfd);
__attribute__((visibility("hidden"))) void pt_network_notify_fd_close(int fd);
__attribute__((visibility("hidden"))) int pt_network_ioctl_with_caller(int fd, unsigned long request, uintptr_t arg, const void *caller);
__attribute__((visibility("hidden"))) int pt_network_bind_with_caller(int socket, const struct sockaddr *address, socklen_t address_len, int raw_syscall_num, const void *caller);
__attribute__((visibility("hidden"))) int pt_network_connect_with_caller(int socket, const struct sockaddr *address, socklen_t address_len, int raw_syscall_num, const void *caller);
__attribute__((visibility("hidden"))) int pt_network_connectx_with_caller(int socket, const sa_endpoints_t *endpoints, sae_associd_t associd, unsigned int flags, const struct iovec *iov, unsigned int iovcnt, size_t *len, sae_connid_t *connid, int raw_syscall_num, const void *caller);
__attribute__((visibility("hidden"))) int pt_network_accept_with_caller(int socket, struct sockaddr * __restrict address, socklen_t * __restrict address_len, int raw_syscall_num, const void *caller);
__attribute__((visibility("hidden"))) ssize_t pt_network_sendto_with_caller(int socket, const void *buffer, size_t length, int flags, const struct sockaddr *dest_addr, socklen_t dest_len, int raw_syscall_num, const void *caller);
__attribute__((visibility("hidden"))) ssize_t pt_network_sendmsg_with_caller(int socket, const struct msghdr *message, int flags, int raw_syscall_num, const void *caller);
__attribute__((visibility("hidden"))) ssize_t pt_network_recvfrom_with_caller(int socket, void * __restrict buffer, size_t length, int flags, struct sockaddr * __restrict address, socklen_t * __restrict address_len, int raw_syscall_num, const void *caller);
__attribute__((visibility("hidden"))) ssize_t pt_network_recvmsg_with_caller(int socket, struct msghdr *message, int flags, int raw_syscall_num, const void *caller);
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
