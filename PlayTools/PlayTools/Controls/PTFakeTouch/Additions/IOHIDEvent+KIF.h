//
//  IOHIDEvent+KIF.h
//  testAnything
//
//  Created by PugaTang on 16/4/1.
//  Copyright © 2016年 PugaTang. All rights reserved.
//

typedef struct __IOHIDEvent * IOHIDEventRef;
@class UITouch;
__attribute__((visibility("hidden")))
IOHIDEventRef kif_IOHIDEventWithTouches(NSArray *touches) CF_RETURNS_RETAINED;
__attribute__((visibility("hidden")))
IOHIDEventRef kif_IOHIDEventWithTouch(UITouch *touch, uint32_t fingerIndex) CF_RETURNS_RETAINED;
