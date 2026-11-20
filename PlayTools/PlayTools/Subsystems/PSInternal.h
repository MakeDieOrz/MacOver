//
//  PSInternal.h
//  PlayTools
//
//  Shared Objective-C swizzle infrastructure & subsystem installer prototypes
//  extracted from PlayShadow.m.
//

#ifndef PSInternal_h
#define PSInternal_h

#import "PTInternal.h"

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

extern const char *dyld_image_path_containing_address(const void *addr);
extern __attribute__((visibility("hidden"))) const char *pt_sanitize_image_path_for_app(const char *raw_path);
extern __attribute__((visibility("hidden"))) const char *pt_sanitize_image_path_for_cstr(const char *raw_path);
extern __attribute__((visibility("hidden"))) const char *pt_resolve_virtual_path(const char *path, char *buf, size_t bufsize);
extern __attribute__((visibility("hidden"))) const char *pt_virtualize_path_for_app(const char *path, char *buf, size_t bufsize, BOOL use_private_prefix);
extern __attribute__((visibility("hidden"))) const char *pt_get_virtual_home_cstr(void);
extern __attribute__((visibility("hidden"))) const char *pt_get_virtual_tmpdir_cstr(void);
extern __attribute__((visibility("hidden"))) const char *pt_get_host_user_root_cstr(void);
extern __attribute__((visibility("hidden"))) const char *pt_get_device_model_cstr(void);
extern __attribute__((visibility("hidden"))) const char *pt_get_oem_id_cstr(void);
extern __attribute__((visibility("hidden"))) uint32_t pt_get_spoofed_cpu_cores(void);
extern __attribute__((visibility("hidden"))) uint64_t pt_get_spoofed_physical_memory(void);
extern __attribute__((visibility("hidden"))) const char *pt_get_spoofed_gpu_name_cstr(void);
extern __attribute__((visibility("hidden"))) BOOL pt_is_bypass_enabled(void);
extern __attribute__((visibility("hidden"))) BOOL pt_is_virtual_container_path(const char *path);
extern __attribute__((visibility("hidden"))) BOOL pt_is_virtual_container_ancestor_dir(const char *path);
extern __attribute__((visibility("hidden"))) BOOL pt_is_system_or_playtools_caller(const void *ret_addr);
extern __attribute__((visibility("hidden"))) BOOL pt_is_effective_system_or_playtools_caller(const void *ret_addr);
extern __attribute__((visibility("hidden"))) BOOL pt_is_hidden_path(const char *path, const void *caller);
extern __attribute__((visibility("hidden"))) BOOL pt_is_hidden_env_key(const char *name);
extern __attribute__((visibility("hidden"))) BOOL pt_is_hidden_objc_selector_name(const char *selName);
extern __attribute__((visibility("hidden"))) BOOL pt_get_spoofed_device_is_ipad(void);
extern __attribute__((visibility("hidden"))) double pt_get_device_native_scale(void);
extern __attribute__((visibility("hidden"))) uint32_t pt_get_device_native_width(void);
extern __attribute__((visibility("hidden"))) uint32_t pt_get_device_native_height(void);
extern __attribute__((visibility("hidden"))) BOOL pt_is_system_version_plist_dict(NSDictionary *dict);
extern __attribute__((visibility("hidden"))) BOOL pt_sanitize_ios_build_version_cstr(const char *build_cstr, const char *ios_ver_cstr, char *out_buf, size_t out_size);
extern __attribute__((visibility("hidden"))) void pt_sanitize_system_version_dict(NSMutableDictionary *dict);
extern __attribute__((visibility("hidden"))) const char *pt_register_and_virtualize_group_container(const char *real_group_path, char *buf, size_t bufsize, BOOL use_private_prefix);
extern __attribute__((visibility("hidden"))) void pt_register_swizzled_imp(const void *hook_imp, const void *orig_imp);
extern __attribute__((visibility("hidden"))) BOOL pt_is_address_in_playtools(const void *addr);


#define PS_SWIZZLE_MAX_ACTIVE_FRAMES 32

typedef struct {
    const void *self_ptr;
    CFMutableDictionaryRef dict;
    Class dispatched_cls;
} ps_swizzle_active_frame_t;

__attribute__((visibility("hidden")))
@interface PSVirtualFileReadScope : NSObject
@property (nonatomic, copy) NSString *allowedRealPath;
@property (nonatomic, copy) NSString *expectedDocRealPath;
@property (nonatomic, assign) BOOL allowSubtree;
@property (nonatomic, assign) BOOL allowAllAppContainers;
@end

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
extern __attribute__((visibility("hidden"))) os_unfair_lock s_wkCanonRootsLock;
extern __attribute__((visibility("hidden"))) NSMutableArray<NSString *> *s_wkCanonContainerRoots;
__attribute__((visibility("hidden"))) NSString *ps_strip_iossupport_nsstring(NSString *p);
__attribute__((visibility("hidden"))) BOOL ps_is_virtual_ancestor_nsstring(NSString *path);
__attribute__((visibility("hidden"))) NSString *ps_resolve_virtual_nsstring_path(NSString *path);
__attribute__((visibility("hidden"))) NSURL *ps_resolve_virtual_nsurl(NSURL *url);
__attribute__((visibility("hidden"))) NSString *ps_virtualize_nsstring_path_for_app(NSString *path, BOOL usePrivatePrefix);
__attribute__((visibility("hidden"))) NSURL *ps_virtualize_nsurl_for_app(NSURL *url, BOOL usePrivatePrefix);
__attribute__((visibility("hidden"))) BOOL ps_is_effective_system_or_playtools_caller(const void *ret_addr);
__attribute__((visibility("hidden"))) BOOL ps_is_hidden_path(NSString *path, const void *caller);
__attribute__((visibility("hidden"))) BOOL ps_is_virtual_container_nsstring(NSString *path);
__attribute__((visibility("hidden"))) NSString *ps_extract_virtual_container_root(NSString *virtPath);
__attribute__((visibility("hidden"))) void ps_seed_wk_canon_container_roots(void);
__attribute__((visibility("hidden"))) NSString *ps_canonical_container_real_path_from_url(NSURL *url);
__attribute__((visibility("hidden"))) BOOL ps_real_path_matches_or_under(NSString *candidate, NSString *root, BOOL allowSubtree);
__attribute__((visibility("hidden"))) void ps_set_wkwebview_read_scope(id webView, PSVirtualFileReadScope *scope);
__attribute__((visibility("hidden"))) id ps_shared_vfile_scheme_handler(void);
__attribute__((visibility("hidden"))) void ps_install_webkit_hooks_if_loaded(void);
__attribute__((visibility("hidden"))) void ps_install_quicklook_hooks_if_loaded(void);

// PTSystemSpooferObjC exports
extern __attribute__((visibility("hidden"))) NSBundle * (*s_orig_bundleForClass)(id, SEL, Class);
extern __attribute__((visibility("hidden"))) NSUUID * (*s_orig_device_identifierForVendor)(id, SEL);
__attribute__((visibility("hidden"))) NSBundle *ps_hook_bundle_for_class(id self, SEL _cmd, Class aClass);
__attribute__((visibility("hidden"))) NSUUID *ps_hook_device_identifierForVendor(id self, SEL _cmd);
__attribute__((visibility("hidden"))) NSURL *ps_virtualize_bundle_url_for_caller(NSURL *url, const void *caller);
__attribute__((visibility("hidden"))) NSString *ps_app_settings_plist_path(void);
__attribute__((visibility("hidden"))) void ps_install_system_jailbreak_bypass_hooks(void);
__attribute__((visibility("hidden"))) void ps_load_environment_bypass_hooks(void);
__attribute__((visibility("hidden"))) void ps_install_dynamic_system_bundle_hooks(void);

// PTGraphicsVirtualizer exports
__attribute__((visibility("hidden"))) void pt_install_graphics_hooks_if_loaded(void);
__attribute__((visibility("hidden"))) void pt_install_frame_rate_hooks_if_loaded(void);

// PTNetworkVirtualizer exports
__attribute__((visibility("hidden"))) void ps_install_network_blocker_hooks(void);

#endif /* PSInternal_h */
