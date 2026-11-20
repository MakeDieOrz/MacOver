//
//  PTFakeMetaTouch.m
//  PTFakeTouch
//
//  Created by PugaTang on 16/4/20.
//  Copyright © 2016年 PugaTang. All rights reserved.
//

#import "PTFakeMetaTouch.h"
#import "UITouch-KIFAdditions.h"
#import "UIApplication+Private.h"
#import "UIEvent+Private.h"
#import "CoreFoundation/CFRunLoop.h"
#import <PlayTools/PlayTools-Swift.h>
#import <math.h>
#import <os/lock.h>
#include <string.h>

#define PT_MAX_FAKE_TOUCHES 64U
#define PT_MOVE_DEADZONE_PT 0.25

__attribute__((visibility("hidden")))
@interface PTPendingTouchOp : NSObject
@property (nonatomic, assign) uint32_t slotId;
@property (nonatomic, assign) uint64_t generation;
@property (nonatomic, assign) UITouchPhase phase;
@property (nonatomic, assign) CGPoint point;
@property (nonatomic, strong, nullable) UIWindow *window;
@property (nonatomic, strong, nullable) UIView *view;
@end

@implementation PTPendingTouchOp
@end

static os_unfair_lock s_touchLock = OS_UNFAIR_LOCK_INIT;
static uint64_t s_producerActiveMask = 0;
static uint64_t s_mainBusyMask = 0;
static uint64_t s_slotGenerations[PT_MAX_FAKE_TOUCHES] = {0};
static NSMutableArray<PTPendingTouchOp *> *s_pendingOps = nil;

// Accessed strictly on the main thread inside eventSendCallback.
static UITouch *s_mainTouches[PT_MAX_FAKE_TOUCHES] = {nil};
static uint64_t s_mainGenerations[PT_MAX_FAKE_TOUCHES] = {0};
static CGPoint s_mainLastPoint[PT_MAX_FAKE_TOUCHES];

static CFRunLoopSourceRef s_source = NULL;
static CFRunLoopRef s_mainLoop = NULL;

static void pt_release_abandoned_slot(uint32_t slot, uint64_t generation) {
    if (slot >= PT_MAX_FAKE_TOUCHES) {
        return;
    }
    os_unfair_lock_lock(&s_touchLock);
    if (s_slotGenerations[slot] == generation) {
        s_mainBusyMask &= ~(1ULL << slot);
        s_producerActiveMask &= ~(1ULL << slot);
    }
    os_unfair_lock_unlock(&s_touchLock);
}

static void pt_flush_main_touches(void) {
    UIApplication *app = [UIApplication sharedApplication];
    UIEvent *event = [app _touchesEvent];
    if (event != nil) {
        [event _clearTouches];

        BOOL hasAny = NO;
        for (uint32_t i = 0; i < PT_MAX_FAKE_TOUCHES; i++) {
            UITouch *t = s_mainTouches[i];
            if (t != nil) {
                [event _addTouch:t forDelayedDelivery:NO];
                hasAny = YES;
            }
        }
        if (hasAny) {
            [app sendEvent:event];
        }
    }

    uint64_t finishedSlots[PT_MAX_FAKE_TOUCHES];
    uint64_t finishedMask = 0;
    for (uint32_t i = 0; i < PT_MAX_FAKE_TOUCHES; i++) {
        UITouch *t = s_mainTouches[i];
        if (t == nil) {
            continue;
        }
        UITouchPhase p = t.phase;
        if (p == UITouchPhaseEnded || p == UITouchPhaseCancelled) {
            finishedSlots[i] = s_mainGenerations[i];
            finishedMask |= (1ULL << i);
            s_mainTouches[i] = nil;
            s_mainGenerations[i] = 0;
            s_mainLastPoint[i] = CGPointZero;
        } else if (p == UITouchPhaseBegan) {
            // Do not let a "began" appear twice across consecutive events.
            [t pm_kif_setPhaseAndUpdateTimestamp:UITouchPhaseMoved fingerIndex:i];
        }
    }

    if (finishedMask != 0) {
        os_unfair_lock_lock(&s_touchLock);
        for (uint32_t i = 0; i < PT_MAX_FAKE_TOUCHES; i++) {
            if ((finishedMask & (1ULL << i)) != 0 &&
                s_slotGenerations[i] == finishedSlots[i] &&
                (s_producerActiveMask & (1ULL << i)) == 0) {
                s_mainBusyMask &= ~(1ULL << i);
            }
        }
        os_unfair_lock_unlock(&s_touchLock);
    }
}

static void eventSendCallback(void *info) {
    (void)info;
    NSArray<PTPendingTouchOp *> *ops = nil;
    os_unfair_lock_lock(&s_touchLock);
    if (s_pendingOps.count > 0) {
        ops = [s_pendingOps copy];
        [s_pendingOps removeAllObjects];
    }
    os_unfair_lock_unlock(&s_touchLock);

    if (ops.count == 0) {
        return;
    }

    BOOL dirty = NO;
    for (PTPendingTouchOp *op in ops) {
        uint32_t slot = op.slotId;
        if (slot >= PT_MAX_FAKE_TOUCHES) {
            continue;
        }
        if (op.phase == UITouchPhaseBegan) {
            if (s_mainTouches[slot] != nil) {
                UITouch *prev = s_mainTouches[slot];
                if (prev.phase != UITouchPhaseEnded && prev.phase != UITouchPhaseCancelled) {
                    [prev pm_kif_setPhaseAndUpdateTimestamp:UITouchPhaseCancelled fingerIndex:slot];
                }
                pt_flush_main_touches();
                dirty = NO;
            }
            UIWindow *targetWindow = op.window ?: [[PlayScreen shared] activeTouchWindowAtPoint:op.point];
            if (targetWindow == nil) {
                pt_release_abandoned_slot(slot, op.generation);
                continue;
            }
            CGPoint pointInWindow = CGPointMake(op.point.x - targetWindow.frame.origin.x,
                                                op.point.y - targetWindow.frame.origin.y);
            UIView *targetView = op.view ?: [targetWindow hitTest:pointInWindow withEvent:nil];
            UITouch *touch = [[UITouch alloc] pm_kif_initAtPoint:pointInWindow
                                                        inWindow:targetWindow
                                                          onView:targetView
                                                     fingerIndex:slot];
            if (touch != nil) {
                s_mainTouches[slot] = touch;
                s_mainGenerations[slot] = op.generation;
                s_mainLastPoint[slot] = op.point;
                dirty = YES;
            } else {
                pt_release_abandoned_slot(slot, op.generation);
            }
            continue;
        }

        UITouch *touch = (s_mainGenerations[slot] == op.generation) ? s_mainTouches[slot] : nil;
        if (touch == nil) {
            continue;
        }

        // Apply coordinate dead-zone filtering on consecutive moves so micro-jitter
        // does not flood UIKit without dropping terminal events.
        if (op.phase == UITouchPhaseMoved) {
            CGFloat dx = op.point.x - s_mainLastPoint[slot].x;
            CGFloat dy = op.point.y - s_mainLastPoint[slot].y;
            if (isfinite(dx) && isfinite(dy) && hypot(dx, dy) <= PT_MOVE_DEADZONE_PT) {
                continue;
            }
        }

        // Preserve strict Began -> Moved/Ended ordering even when a fast tap completes
        // between two main-runloop passes.
        if (touch.phase == UITouchPhaseBegan) {
            pt_flush_main_touches();
            dirty = NO;
            touch = (s_mainGenerations[slot] == op.generation) ? s_mainTouches[slot] : nil;
            if (touch == nil) {
                continue;
            }
        }

        UIWindow *touchWindow = touch.window;
        CGPoint pointInWindow = touchWindow != nil
            ? CGPointMake(op.point.x - touchWindow.frame.origin.x,
                          op.point.y - touchWindow.frame.origin.y)
            : op.point;
        [touch pm_kif_setLocationInWindow:pointInWindow];
        [touch pm_kif_setPhaseAndUpdateTimestamp:op.phase fingerIndex:slot];
        s_mainLastPoint[slot] = op.point;
        dirty = YES;

        if (op.phase == UITouchPhaseEnded || op.phase == UITouchPhaseCancelled) {
            pt_flush_main_touches();
            dirty = NO;
        }
    }

    if (dirty) {
        pt_flush_main_touches();
    }
}

@implementation PTFakeMetaTouch

+ (void)load {
    s_pendingOps = [[NSMutableArray alloc] init];
    memset(s_mainLastPoint, 0, sizeof(s_mainLastPoint));
    CFRunLoopSourceContext context;
    memset(&context, 0, sizeof(CFRunLoopSourceContext));
    context.perform = eventSendCallback;
    s_source = CFRunLoopSourceCreate(NULL, -2, &context);
    s_mainLoop = CFRunLoopGetMain();
    if (s_mainLoop != NULL && s_source != NULL) {
        CFRetain(s_mainLoop);
        CFRunLoopAddSource(s_mainLoop, s_source, kCFRunLoopCommonModes);
    }
}

+ (NSInteger)fakeTouchId:(NSInteger)pointId
                 AtPoint:(CGPoint)point
          withTouchPhase:(UITouchPhase)phase
                inWindow:(UIWindow * _Nullable)window
                  onView:(UIView * _Nullable)view {
    if (s_source == NULL || s_mainLoop == NULL) {
        return -1;
    }

    if (phase == UITouchPhaseBegan) {
        uint32_t chosenSlot = PT_MAX_FAKE_TOUCHES;
        os_unfair_lock_lock(&s_touchLock);
        uint64_t combinedBusy = s_producerActiveMask | s_mainBusyMask;
        for (uint32_t i = 0; i < PT_MAX_FAKE_TOUCHES; i++) {
            if ((combinedBusy & (1ULL << i)) == 0) {
                chosenSlot = i;
                break;
            }
        }
        if (chosenSlot == PT_MAX_FAKE_TOUCHES) {
            for (uint32_t i = 0; i < PT_MAX_FAKE_TOUCHES; i++) {
                if ((s_producerActiveMask & (1ULL << i)) == 0) {
                    chosenSlot = i;
                    break;
                }
            }
        }
        if (chosenSlot == PT_MAX_FAKE_TOUCHES) {
            os_unfair_lock_unlock(&s_touchLock);
            return -1;
        }

        s_producerActiveMask |= (1ULL << chosenSlot);
        s_mainBusyMask |= (1ULL << chosenSlot);
        uint64_t gen = ++s_slotGenerations[chosenSlot];

        PTPendingTouchOp *op = [[PTPendingTouchOp alloc] init];
        op.slotId = chosenSlot;
        op.generation = gen;
        op.phase = UITouchPhaseBegan;
        op.point = point;
        op.window = window;
        op.view = view;
        [s_pendingOps addObject:op];
        os_unfair_lock_unlock(&s_touchLock);

        CFRunLoopSourceSignal(s_source);
        CFRunLoopWakeUp(s_mainLoop);
        return (NSInteger)chosenSlot;
    }

    if (pointId < 0 || pointId >= (NSInteger)PT_MAX_FAKE_TOUCHES) {
        return -1;
    }
    uint32_t slot = (uint32_t)pointId;

    os_unfair_lock_lock(&s_touchLock);
    if ((s_producerActiveMask & (1ULL << slot)) == 0) {
        os_unfair_lock_unlock(&s_touchLock);
        return -1;
    }
    uint64_t gen = s_slotGenerations[slot];

    BOOL coalesced = NO;
    if (phase == UITouchPhaseMoved && s_pendingOps.count > 0) {
        for (NSInteger idx = (NSInteger)s_pendingOps.count - 1; idx >= 0; idx--) {
            PTPendingTouchOp *prev = s_pendingOps[(NSUInteger)idx];
            if (prev.slotId == slot && prev.generation == gen) {
                if (prev.phase == UITouchPhaseMoved) {
                    prev.point = point;
                    if (window != nil) {
                        prev.window = window;
                    }
                    if (view != nil) {
                        prev.view = view;
                    }
                    coalesced = YES;
                }
                break;
            }
        }
    }

    if (!coalesced) {
        PTPendingTouchOp *op = [[PTPendingTouchOp alloc] init];
        op.slotId = slot;
        op.generation = gen;
        op.phase = phase;
        op.point = point;
        op.window = window;
        op.view = view;
        [s_pendingOps addObject:op];
    }

    BOOL isTerminal = (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled);
    if (isTerminal) {
        s_producerActiveMask &= ~(1ULL << slot);
    }
    os_unfair_lock_unlock(&s_touchLock);

    CFRunLoopSourceSignal(s_source);
    CFRunLoopWakeUp(s_mainLoop);
    return isTerminal ? -1 : pointId;
}

@end
