//
//  PlayLoader.h
//  PlayTools
//

#import <Foundation/Foundation.h>
#import "CoreGraphics/CoreGraphics.h"

#define DYLD_INTERPOSE(_replacement, _replacee)                                                                        \
    __attribute__((used)) static struct {                                                                              \
        const void *replacement;                                                                                       \
        const void *replacee;                                                                                          \
    } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = {                                        \
        (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee};

__attribute__((visibility("hidden")))
@interface PlayLoader : NSObject

@end

#ifdef __cplusplus
extern "C" {
#endif

__attribute__((visibility("hidden"))) BOOL pt_is_bypass_enabled(void);
__attribute__((visibility("hidden"))) BOOL pt_is_effective_system_or_playtools_caller(const void *ret_addr);
__attribute__((visibility("hidden"))) double pt_get_device_native_scale(void);
__attribute__((visibility("hidden"))) uint32_t pt_get_device_native_width(void);
__attribute__((visibility("hidden"))) uint32_t pt_get_device_native_height(void);
__attribute__((visibility("hidden"))) void pt_register_swizzled_imp(const void *hook_imp, const void *orig_imp);
__attribute__((visibility("hidden"))) BOOL pt_is_address_in_playtools(const void *addr);

#ifdef __cplusplus
}
#endif
