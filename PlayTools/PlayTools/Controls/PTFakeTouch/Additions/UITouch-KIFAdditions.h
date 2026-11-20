//
//  UITouch-KIFAdditions.h
//  KIF
//
//  Created by Eric Firestone on 5/20/11.
//  Licensed to Square, Inc. under one or more contributor license agreements.
//  See the LICENSE file distributed with this work for the terms under
//  which Square, Inc. licenses this file to you.

#import <UIKit/UIKit.h>
#import "IOHIDEvent+KIF.h"
#import "UITouch+Private.h"

@interface UITouch (KIFAdditions)

- (id)pm_kif_initAtPoint:(CGPoint)point inWindow:(UIWindow *)window onView:(UIView*)view __attribute__((objc_method_family(init)));
- (id)pm_kif_initAtPoint:(CGPoint)point inWindow:(UIWindow *)window onView:(UIView*)view fingerIndex:(uint32_t)fingerIndex __attribute__((objc_method_family(init)));
- (id)pm_kif_initTouch __attribute__((objc_method_family(init)));

- (void)pm_kif_setLocationInWindow:(CGPoint)location;
- (void)pm_kif_setPhaseAndUpdateTimestamp:(UITouchPhase)phase;
- (void)pm_kif_setPhaseAndUpdateTimestamp:(UITouchPhase)phase fingerIndex:(uint32_t)fingerIndex;

@end
