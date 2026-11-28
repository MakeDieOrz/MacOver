//
//  PTEntitlementsInternal.h
//  PlayTools
//
//  Hidden declarations for PTEntitlements and callers.
//

#ifndef PTEntitlementsInternal_h
#define PTEntitlementsInternal_h

#import "PTCommon.h"
#import <Security/Security.h>

#if !TARGET_OS_MACCATALYST && !TARGET_OS_OSX
typedef struct __SecCode *SecCodeRef;
typedef struct __SecCode const *SecStaticCodeRef;
typedef struct __SecRequirement *SecRequirementRef;
typedef struct __SecTask *SecTaskRef;
typedef uint32_t SecCSFlags;

extern OSStatus SecCodeCopySelf(SecCSFlags flags, SecCodeRef *self);
extern OSStatus SecCodeCopyStaticCode(SecCodeRef code, SecCSFlags flags, SecStaticCodeRef *staticCode);
extern OSStatus SecCodeCopyPath(SecStaticCodeRef staticCode, SecCSFlags flags, CFURLRef *path);
extern OSStatus SecCodeCopySigningInformation(SecStaticCodeRef code, SecCSFlags flags, CFDictionaryRef *information);
extern OSStatus SecCodeCheckValidity(SecCodeRef code, SecCSFlags flags, SecRequirementRef requirement);
extern OSStatus SecCodeCheckValidityWithErrors(SecCodeRef code, SecCSFlags flags, SecRequirementRef requirement, CFErrorRef *errors);
extern OSStatus SecStaticCodeCreateWithPath(CFURLRef path, SecCSFlags flags, SecStaticCodeRef *staticCode);
extern OSStatus SecStaticCodeCreateWithPathAndAttributes(CFURLRef path, SecCSFlags flags, CFDictionaryRef attributes, SecStaticCodeRef *staticCode);
extern OSStatus SecStaticCodeCheckValidity(SecStaticCodeRef staticCode, SecCSFlags flags, SecRequirementRef requirement);
extern OSStatus SecStaticCodeCheckValidityWithErrors(SecStaticCodeRef staticCode, SecCSFlags flags, SecRequirementRef requirement, CFErrorRef *errors);
extern CFStringRef SecTaskCopySigningIdentifier(SecTaskRef task, CFErrorRef *error);
extern uint32_t SecTaskGetCodeSignStatus(SecTaskRef task);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);
extern CFDictionaryRef SecTaskCopyValuesForEntitlements(SecTaskRef task, CFArrayRef entitlements, CFErrorRef *error);
#endif

#ifdef __cplusplus
extern "C" {
#endif

__attribute__((visibility("hidden"))) int pt_csops_with_caller(pid_t pid, unsigned int ops, void *useraddr, size_t usersize, const void *caller);
__attribute__((visibility("hidden"))) int pt_csops_audittoken_with_caller(pid_t pid, unsigned int ops, void *useraddr, size_t usersize, audit_token_t *token, const void *caller);
__attribute__((visibility("hidden"))) int pt_ptrace_with_caller(int request, pid_t pid, caddr_t addr, int data, const void *caller);
__attribute__((visibility("hidden"))) int pt_mac_syscall_with_caller(const char *policy, int call, void *arg, const void *caller, BOOL *out_handled);
__attribute__((visibility("hidden"))) BOOL pt_is_hidden_macos_mach_service(const char *name);
__attribute__((visibility("hidden"))) void pt_init_linkedit_cs_blob_cloaking(void);

#ifdef __cplusplus
}
#endif

#endif /* PTEntitlementsInternal_h */
