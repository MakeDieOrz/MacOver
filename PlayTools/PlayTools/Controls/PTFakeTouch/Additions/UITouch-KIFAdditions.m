//
//  UITouch-KIFAdditions.m
//  KIF
//
//  Created by Eric Firestone on 5/20/11.
//  Licensed to Square, Inc. under one or more contributor license agreements.
//  See the LICENSE file distributed with this work for the terms under
//  which Square, Inc. licenses this file to you.

#import "UITouch-KIFAdditions.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import "PTFakeMetaTouch.h"

@implementation UITouch (KIFAdditions)

- (id)pm_kif_initAtPoint:(CGPoint)point inWindow:(UIWindow *)window onView:(UIView*)view
{
    return [self pm_kif_initAtPoint:point inWindow:window onView:view fingerIndex:0];
}

- (id)pm_kif_initAtPoint:(CGPoint)point inWindow:(UIWindow *)window onView:(UIView*)view fingerIndex:(uint32_t)fingerIndex;
{
    self = [super init];
    if (self == nil) {
        return nil;
    }
    
    // Create a fake tap touch
    [self setWindow:window]; // Wipes out some values. Needs to be first.
    
    [self _setLocationInWindow:point resetPrevious:YES];
    
    UIView *hitTestView = view;
    
    [self setView:hitTestView];
    [self setPhase:UITouchPhaseBegan];
    if ([self respondsToSelector:@selector(setTapCount:)]) {
        [self setTapCount:1];
    }
    if ([self respondsToSelector:@selector(_setIsTapToClick:)]) {
        [self _setIsTapToClick:NO];
    } else {
        if ([self respondsToSelector:@selector(_setIsFirstTouchForView:)]) {
            [self _setIsFirstTouchForView:YES];
        }
        if ([self respondsToSelector:@selector(setIsTap:)]) {
            [self setIsTap:NO];
        }
    }
    [self setTimestamp: [[NSProcessInfo processInfo] systemUptime]];
    if ([self respondsToSelector:@selector(setGestureView:)]) {
        [self setGestureView:hitTestView];
    }
    
    [self kif_setHidEventWithFingerIndex:fingerIndex];
    return self;
}

- (id)pm_kif_initTouch;
{
    //DLog(@"init...touch...");
    self = [super init];
    if (self == nil) {
        return nil;
    }
    UIWindow *window = nil;
    for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *winScene = (UIWindowScene *)scene;
            if (winScene.windows.count > 0) {
                window = [winScene.windows lastObject];
                break;
            }
        }
    }
    CGPoint point = CGPointMake(0, 0);
    [self setWindow:window]; // Wipes out some values.  Needs to be first.
    
    [self _setLocationInWindow:point resetPrevious:YES];
    
    UIView *hitTestView = [window hitTest:point withEvent:nil];
    
    [self setView:hitTestView];
    [self setPhase:UITouchPhaseEnded];
    //DLog(@"init...touch...setPhase 3");
    if ([self respondsToSelector:@selector(_setIsTapToClick:)]) {
        [self _setIsTapToClick:NO];
    } else {
        if ([self respondsToSelector:@selector(_setIsFirstTouchForView:)]) {
            [self _setIsFirstTouchForView:YES];
        }
        if ([self respondsToSelector:@selector(setIsTap:)]) {
            [self setIsTap:NO];
        }
    }
    [self setTimestamp: [[NSProcessInfo processInfo] systemUptime]];
    if ([self respondsToSelector:@selector(setGestureView:)]) {
        [self setGestureView:hitTestView];
    }
    
    [self kif_setHidEventWithFingerIndex:0];
    return self;
}

//
// pm_kif_setLocationInWindow:
//
// Setter to allow access to the _locationInWindow member.
//
- (void)pm_kif_setLocationInWindow:(CGPoint)location
{
    [self setTimestamp: [[NSProcessInfo processInfo] systemUptime]];
    [self _setLocationInWindow:location resetPrevious:NO];
}

- (void)pm_kif_setPhaseAndUpdateTimestamp:(UITouchPhase)phase
{
    [self pm_kif_setPhaseAndUpdateTimestamp:phase fingerIndex:0];
}

- (void)pm_kif_setPhaseAndUpdateTimestamp:(UITouchPhase)phase fingerIndex:(uint32_t)fingerIndex
{
    //DLog(@"setPhaseAndUpdateTimestamp : %ld",(long)phase);
    [self setTimestamp: [[NSProcessInfo processInfo] systemUptime]];
    [self setPhase:phase];
    // Update the IOHIDEvent to match the new phase.
    // Some games validate IOHIDEvent.eventMask against UITouch.phase,
    // so keeping them in sync is critical for fake touch acceptance.
    [self kif_setHidEventWithFingerIndex:fingerIndex];
}

- (void)kif_setHidEventWithFingerIndex:(uint32_t)fingerIndex {
    IOHIDEventRef event = kif_IOHIDEventWithTouch(self, fingerIndex);
    if (event != NULL) {
        [self _setHidEvent:event];
        CFRelease(event);
    }
    CGFloat radius = 24.5 + (CGFloat)(fingerIndex % 3U) * 0.6;
    SEL setMajorSel = sel_registerName("setMajorRadius:");
    SEL privMajorSel = sel_registerName("_setMajorRadius:");
    SEL setTolSel = sel_registerName("_setMajorRadiusTolerance:");
    if ([self respondsToSelector:privMajorSel]) {
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(self, privMajorSel, radius);
    } else if ([self respondsToSelector:setMajorSel]) {
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(self, setMajorSel, radius);
    }
    if ([self respondsToSelector:setTolSel]) {
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(self, setTolSel, (CGFloat)1.5);
    }
}

@end
