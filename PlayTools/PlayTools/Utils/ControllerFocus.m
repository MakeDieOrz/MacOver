//
//  ControllerFocus.m
//  PlayTools
//
//  Created by Edoardo C. on 23/02/26.
//

#import <Foundation/Foundation.h>
#import <GameController/GCController.h>
#import "PTSystemSpooferInternal.h"

__attribute__((visibility("hidden")))
@interface BackgroundControllerLoader : NSObject
@end

@implementation BackgroundControllerLoader
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!pt_is_compat13_7_active() &&
            [GCController respondsToSelector:@selector(setShouldMonitorBackgroundEvents:)]) {
            [GCController setShouldMonitorBackgroundEvents:YES];
        }
    });
}
@end
