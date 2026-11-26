//
//  PSInternal.h
//  PlayTools
//
//  Shared Objective-C swizzle infrastructure & subsystem installer prototypes
//  extracted from PlayShadow.m.
//

#ifndef PSInternal_h
#define PSInternal_h

#import "PTCommon.h"
#import "PTSystemSpooferInternal.h"
#import "PTFSInternal.h"
#import "PTDyldInternal.h"
#import "PTNetworkInternal.h"

//
//  PlayShadow.m
//  PlayTools
//
//  Created by Venti on 08/03/2023.
//

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <errno.h>
#include <execinfo.h>
#include <fcntl.h>
#include <fnmatch.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>
#import "../PTCallerAddressMath.h"
#import <PlayTools/PlayTools-Swift.h>


#define PS_SWIZZLE_MAX_ACTIVE_FRAMES 32

typedef struct {
    const void *self_ptr;
    CFMutableDictionaryRef dict;
    Class dispatched_cls;
} ps_swizzle_active_frame_t;

__attribute__((visibility("hidden")))
@interface PlayShadowLoader : NSObject
@end

__attribute__((visibility("hidden")))
@interface PSSwizzleHooks : NSObject
@end

@interface PSSwizzleHooks (PlayShadowCatalog)
- (instancetype) pm_ps_initWithPath:(NSString *)path __attribute__((objc_method_family(init)));
- (instancetype) pm_ps_initWithURL:(NSURL *)url __attribute__((objc_method_family(init)));
- (instancetype) pm_wk_cfg_init __attribute__((objc_method_family(init)));
- (instancetype) pm_wk_cfg_initWithCoder:(NSCoder *)coder __attribute__((objc_method_family(init)));
- (instancetype) pm_ps_jsc_init __attribute__((objc_method_family(init)));
- (instancetype) pm_ps_jsc_initWithVirtualMachine:(id)virtualMachine __attribute__((objc_method_family(init)));
+ (id) pm_ps_jsc_contextWithJSGlobalContextRef:(void *)jsGlobalContextRef;
- (NSURL *) pm_wk_URL;
- (NSURLRequest *) pm_wk_nav_request;
- (NSURLRequest *) pm_wk_frame_request;
- (NSArray *) pm_wk_userScripts;
- (NSURL *) pm_dic_URL;
- (NSString *) pm_currentDirectoryPath;
- (NSString *) pm_ps_portName;
- (NSString *) pm_ps_UID;
- (NSURL *) pm_ps_homeDirectoryForCurrentUser;
- (NSURL *) pm_ps_homeDirectoryForUser:(NSString *)userName;
- (NSURL *) pm_URLByResolvingSymlinksInPath;
- (NSURL *) pm_URLByStandardizingPath;
- (BOOL) pm_checkResourceIsReachableAndReturnError:(NSError **)error;
- (NSDictionary<NSURLResourceKey, id> *) pm_resourceValuesForKeys:(NSArray<NSURLResourceKey> *)keys error:(NSError **)error;
- (BOOL) pm_getResourceValue:(out id *)value forKey:(NSURLResourceKey)key error:(out NSError **)error;
- (void) pm_wk_setCustomUserAgent:(NSString *)customUserAgent;
- (void) pm_ql_setDataSource:(id)dataSource;
- (id) pm_ql_dataSource;
- (instancetype) pm_dic_initWithURL:(NSURL *)url __attribute__((objc_method_family(init)));
- (void) pm_dic_setURL:(NSURL *)url;
- (instancetype) pm_initWithActivityItems:(NSArray *)activityItems
                    applicationActivities:(NSArray *)applicationActivities __attribute__((objc_method_family(init)));
- (id) pm_loadFileURL:(NSURL *)URL allowingReadAccessToURL:(NSURL *)readAccessURL;
- (id) pm_loadFileRequest:(NSURLRequest *)request allowingReadAccessToURL:(NSURL *)readAccessURL;
- (id) pm_wk_loadRequest:(NSURLRequest *)request;
- (id) pm_wk_loadHTMLString:(NSString *)string baseURL:(NSURL *)baseURL;
- (id) pm_wk_loadData:(NSData *)data
             MIMEType:(NSString *)MIMEType
characterEncodingName:(NSString *)characterEncodingName
              baseURL:(NSURL *)baseURL;
- (void) pm_wk_removeAllUserScripts;
- (instancetype) pm_wk_initWithFrame:(CGRect)frame configuration:(id)configuration __attribute__((objc_method_family(init)));
- (instancetype) pm_wk_initWithCoder:(NSCoder *)coder __attribute__((objc_method_family(init)));
- (NSString *) pm_wk_customUserAgent;
- (BOOL) pm_ptkb_becomeFirstResponder;
- (BOOL) pm_ptkb_resignFirstResponder;
- (void) pm_ptkb_reloadInputViews;
+ (void) pm_wk_registerSchemeForCustomProtocol:(NSString *)scheme;
+ (void) pm_wk_unregisterSchemeForCustomProtocol:(NSString *)scheme;
@end

// Swizzle infrastructure (defined in PlayShadow.m)
__attribute__((visibility("hidden"))) void ps_swizzle_instance_method(Class cls, SEL origSelector, SEL newSelector);
__attribute__((visibility("hidden"))) void ps_replace_instance_method(Class cls, SEL origSelector, SEL newSelector);
__attribute__((visibility("hidden"))) void ps_swizzle_class_method(Class cls, SEL origSelector, SEL newSelector);
__attribute__((visibility("hidden"))) void ps_replace_class_method(Class cls, SEL origSelector, SEL newSelector);
__attribute__((visibility("hidden"))) void ps_install_nsobject_reflection_hooks(void);
__attribute__((visibility("hidden"))) IMP ps_lookup_orig_imp_and_push(os_unfair_lock *lock, CFMutableDictionaryRef dict, id self, BOOL *outPushed);
__attribute__((visibility("hidden"))) void ps_pop_orig_imp_frame(BOOL pushed);
__attribute__((visibility("hidden"))) void ps_swizzle_class_sel_storing_imp(os_unfair_lock *lock, CFMutableDictionaryRef *dictPtr, Class cls, SEL origSel, SEL hookSel);
__attribute__((visibility("hidden"))) BOOL ps_class_defines_instance_method(Class cls, SEL sel);

// PTFSVirtualizerObjC exports
__attribute__((visibility("hidden"))) NSString *ps_strip_iossupport_nsstring(NSString *p);
__attribute__((visibility("hidden"))) BOOL ps_is_virtual_ancestor_nsstring(NSString *path);
__attribute__((visibility("hidden"))) NSString *ps_normalize_virtual_ancestor_nsstring(NSString *path);
__attribute__((visibility("hidden"))) NSString *ps_resolve_virtual_nsstring_path(NSString *path);
__attribute__((visibility("hidden"))) NSURL *ps_rebuild_file_nsurl(NSURL *origURL, NSString *newPath);
__attribute__((visibility("hidden"))) NSURL *ps_resolve_virtual_nsurl(NSURL *url);
__attribute__((visibility("hidden"))) NSString *ps_virtualize_nsstring_path_for_app(NSString *path, BOOL usePrivatePrefix);
__attribute__((visibility("hidden"))) NSURL *ps_virtualize_nsurl_for_app(NSURL *url, BOOL usePrivatePrefix);
__attribute__((visibility("hidden"))) BOOL ps_is_effective_system_or_playtools_caller(const void *ret_addr);
__attribute__((visibility("hidden"))) BOOL ps_is_hidden_path(NSString *path, const void *caller);
__attribute__((visibility("hidden"))) BOOL ps_is_virtual_container_nsstring(NSString *path);
__attribute__((visibility("hidden"))) void ps_install_quicklook_hooks_if_loaded(void);

// PTWebKitVirtualizer & PTWebKitScripts exports
extern __attribute__((visibility("hidden"))) NSString * const kPSWKEnvScriptMarker;
extern __attribute__((visibility("hidden"))) NSString * const kPSWKVFileScriptMarker;
__attribute__((visibility("hidden"))) void ps_install_webkit_hooks_if_loaded(void);
__attribute__((visibility("hidden"))) NSString *ps_build_wk_env_user_script_source_uncached(
    NSString *plat,
    NSString *uaToken,
    unsigned int cores,
    int ptWidth,
    int ptHeight,
    double dpr,
    BOOL compat13,
    int32_t maxAppleFam);
__attribute__((visibility("hidden"))) NSString *ps_build_wk_vfile_user_script_source(void);

// PTCoreMotionVirtualizer exports
__attribute__((visibility("hidden"))) void ps_install_coremotion_hooks_if_loaded(void);

static inline BOOL ps_is_iphone_device_model(void) {
    const char *m = pt_get_device_model_cstr();
    return (m != NULL && strncmp(m, "iPhone", 6) == 0);
}

// PTSystemSpooferObjC & PTMediaInputSpooferObjC exports
extern __attribute__((visibility("hidden"))) NSBundle * (*s_orig_bundleForClass)(id, SEL, Class);
extern __attribute__((visibility("hidden"))) NSUUID * (*s_orig_device_identifierForVendor)(id, SEL);
__attribute__((visibility("hidden"))) NSBundle *ps_hook_bundle_for_class(id self, SEL _cmd, Class aClass);
__attribute__((visibility("hidden"))) NSUUID *ps_hook_device_identifierForVendor(id self, SEL _cmd);
__attribute__((visibility("hidden"))) NSURL *ps_virtualize_bundle_url_for_caller(NSURL *url, const void *caller);
__attribute__((visibility("hidden"))) NSString *ps_app_settings_plist_path(void);
__attribute__((visibility("hidden"))) BOOL ps_get_cached_ios_sysver(NSOperatingSystemVersion *outVer, NSString * __autoreleasing *outVerString);
__attribute__((visibility("hidden"))) void ps_install_system_jailbreak_bypass_hooks(void);
__attribute__((visibility("hidden"))) void ps_load_environment_bypass_hooks(void);
__attribute__((visibility("hidden"))) void ps_install_dynamic_system_bundle_hooks(void);
__attribute__((visibility("hidden"))) void ps_install_uifont_hooks_if_loaded(void);
__attribute__((visibility("hidden"))) void ps_install_audio_session_port_hooks(void);
__attribute__((visibility("hidden"))) void ps_install_avfoundation_audio_unit_hooks_if_loaded(void);
__attribute__((visibility("hidden"))) void ps_install_corehaptics_hooks_if_loaded(void);
__attribute__((visibility("hidden"))) void ps_install_avcapture_hooks_if_loaded(void);
__attribute__((visibility("hidden"))) void ps_install_coretelephony_hooks_if_loaded(void);
__attribute__((visibility("hidden"))) void ps_install_app_attest_hooks_if_loaded(void);
__attribute__((visibility("hidden"))) void ps_install_local_auth_hooks_if_loaded(void);
__attribute__((visibility("hidden"))) void ps_install_game_controller_hooks_if_loaded(void);
__attribute__((visibility("hidden"))) void ps_install_jscontext_hooks_if_loaded(void);

// PTGraphicsVirtualizer exports
__attribute__((visibility("hidden"))) void pt_install_graphics_hooks_if_loaded(void);
__attribute__((visibility("hidden"))) void pt_install_frame_rate_hooks_if_loaded(void);

// PTNetworkVirtualizer exports
__attribute__((visibility("hidden"))) void ps_install_network_blocker_hooks(void);
__attribute__((visibility("hidden"))) void ps_install_webkit_network_hooks_if_loaded(void);
__attribute__((visibility("hidden"))) void ps_apply_proxy_to_wk_configuration(id cfg);
__attribute__((visibility("hidden"))) void ps_install_default_wk_trust_delegate(id webView);

// PTCustomInputViewHost exports
__attribute__((visibility("hidden"))) void ps_install_custom_input_view_host(void);

#endif /* PSInternal_h */
