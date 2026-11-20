//
//  NSObject+PrivateSwizzle.h
//  PlayTools
//
//  Created by siri on 06.10.2021.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

extern __attribute__((visibility("hidden")))
void pt_swizzle_instance_method(Class _Nullable cls, SEL origSelector, SEL newSelector);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
