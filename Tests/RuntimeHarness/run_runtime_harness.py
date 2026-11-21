#!/usr/bin/env python3
"""Headless Mac Catalyst runtime harness for PlayTools (Phase 4).

Builds a lightweight Mac Catalyst mock target app + plugin bundle, links it
against PlayTools.framework, and executes isolated OS processes to verify:
  1. Dylib constructor injection completes without _tlv_bootstrap_error or crashes.
  2. PluginManifest.json validation, UserPlugin loading, and dynamic anti-detection
     registration (pt_register_hidden_module / pt_register_hidden_class).
  3. Safe Mode lifecycle: .launching_in_progress breadcrumb written at launch,
     cleared automatically after the stability window, and post-mortem Safe Mode
     activation after an abnormal early exit (< 3s) that blocks user plugins and
     reverts customScaler to 1.0, followed by clean recovery on the next launch.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Optional


MOCK_PLUGIN_C = r"""
#include <arpa/inet.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

typedef void (*pt_register_fn_t)(const char *);

__attribute__((constructor))
static void mock_plugin_init(void) {
    pt_register_fn_t reg_cls = (pt_register_fn_t)dlsym(RTLD_DEFAULT, "pt_register_hidden_class");
    if (reg_cls != NULL) {
        reg_cls("MockHarnessHiddenClass");
    }
    const char *marker_path = getenv("HARNESS_PLUGIN_MARKER");
    if (marker_path != NULL && marker_path[0] != '\0') {
        FILE *fp = fopen(marker_path, "w");
        if (fp != NULL) {
            fputs("loaded\n", fp);
            fclose(fp);
        }
    }
}
"""

MOCK_TARGET_M = r"""
@import Foundation;
@import CoreMotion;
@import QuartzCore;
@import UIKit;
@import PlayTools;
#include <arpa/inet.h>
#include <dlfcn.h>
#include <crt_externs.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

extern bool pt_is_registered_hidden_module(const char *name);
extern bool pt_is_registered_hidden_class(const char *name);
extern int pt_harness_syscall(int, ...) __asm("_syscall");
extern int pt_harness_csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize) __asm("_csops");
extern void pt_harness_dyld_get_image_versions(
    const struct mach_header *mh,
    void (^callback)(uint32_t platform, uint32_t sdk, uint32_t minos))
    __asm("_dyld_get_image_versions") __attribute__((weak_import));

static NSString *pt_state_dir(void) {
    NSArray<NSURL *> *caches = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
                                                                      inDomains:NSUserDomainMask];
    NSURL *base = caches.firstObject ?: [NSURL fileURLWithPath:NSTemporaryDirectory()];
    return [[base URLByAppendingPathComponent:@"app.makedie.PlayTools" isDirectory:YES] path];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        (void)argc;
        (void)argv;

        const char *simCrash = getenv("HARNESS_SIMULATE_CRASH");
        if (simCrash != NULL && strcmp(simCrash, "1") == 0) {
            // Simulate abrupt termination before the 3-second stability window.
            _exit(134);
        }

        // Direct Mach-O linked checks verify internal state across Safe Mode & PTRegistration.
        BOOL safeModeActive = [PTSafeMode isActive];
        double customScaler = (double)[[PlaySettings shared] customScaler];
        BOOL inverseScreenValues = [[PlaySettings shared] inverseScreenValues];
        NSInteger windowFixMethod = [[PlaySettings shared] windowFixMethod];
        NSInteger targetFrameRateHz = [[PlaySettings shared] targetFrameRateHz];
        NSString *reportedIOSVersion = (NSString *)[[PlaySettings shared] reportedIOSVersion] ?: @"";
        BOOL modHidden = pt_is_registered_hidden_module("/App/Frameworks/UserPlugins/MockUserPlugin.dylib");
        BOOL idHidden = pt_is_registered_hidden_module("app.makedie.harness.mockplugin");
        BOOL clsHidden = pt_is_registered_hidden_class("MockHarnessHiddenClass");

        NSOperatingSystemVersion osVer = [[NSProcessInfo processInfo] operatingSystemVersion];
        NSString *osVerString = [[NSProcessInfo processInfo] operatingSystemVersionString] ?: @"";
        NSString *uiDeviceSysVer = [[UIDevice currentDevice] systemVersion] ?: @"";

        char sysctlProdVer[64] = {0};
        size_t sysctlProdVerLen = sizeof(sysctlProdVer);
        if (sysctlbyname("kern.osproductversion", sysctlProdVer, &sysctlProdVerLen, NULL, 0) != 0) {
            sysctlProdVer[0] = '\0';
        }
        char sysctlOSVer[64] = {0};
        size_t sysctlOSVerLen = sizeof(sysctlOSVer);
        if (sysctlbyname("kern.osversion", sysctlOSVer, &sysctlOSVerLen, NULL, 0) != 0) {
            sysctlOSVer[0] = '\0';
        }
        char sysctlOSRelease[64] = {0};
        size_t sysctlOSReleaseLen = sizeof(sysctlOSRelease);
        if (sysctlbyname("kern.osrelease", sysctlOSRelease, &sysctlOSReleaseLen, NULL, 0) != 0) {
            sysctlOSRelease[0] = '\0';
        }
        char sysctlVersion[256] = {0};
        size_t sysctlVersionLen = sizeof(sysctlVersion);
        if (sysctlbyname("kern.version", sysctlVersion, &sysctlVersionLen, NULL, 0) != 0) {
            sysctlVersion[0] = '\0';
        }
        char sysctlMachine[64] = {0};
        size_t sysctlMachineLen = sizeof(sysctlMachine);
        if (sysctlbyname("hw.machine", sysctlMachine, &sysctlMachineLen, NULL, 0) != 0) {
            sysctlMachine[0] = '\0';
        }
        char syscallMachine[64] = {0};
        size_t syscallMachineLen = sizeof(syscallMachine);
        if (pt_harness_syscall(274, "hw.machine", (size_t)10, syscallMachine, &syscallMachineLen, NULL, (size_t)0) != 0) {
            syscallMachine[0] = '\0';
        }
        int kqProbe = pt_harness_syscall(362);
        struct timespec badKevTimeout = { 0, -1 };
        errno = 0;
        BOOL syscallWideArityOK = (kqProbe >= 0 &&
                                   pt_harness_syscall(369, kqProbe, NULL, 0, NULL, 0, 0U, &badKevTimeout) == -1 &&
                                   errno == EINVAL);
        if (kqProbe >= 0) {
            close(kqProbe);
        }
        char csopsTeamShort[10];
        memset(csopsTeamShort, 'X', sizeof(csopsTeamShort));
        errno = 0;
        BOOL csopsTeamShortERange = (pt_harness_csops(0, 14U, csopsTeamShort, sizeof(csopsTeamShort)) == -1 &&
                                     errno == ERANGE &&
                                     csopsTeamShort[0] == 'X');
        char csopsTeamExact[11] = {0};
        BOOL csopsTeamRawOK = (pt_harness_csops(0, 14U, csopsTeamExact, sizeof(csopsTeamExact)) == 0 &&
                               strlen(csopsTeamExact) == 10U);
        char csopsIdentity[128] = {0};
        BOOL csopsIdentityRawOK = (pt_harness_csops(0, 11U, csopsIdentity, sizeof(csopsIdentity)) == 0 &&
                                   strcmp(csopsIdentity, "app.makedie.harness.mockapp") == 0);
        uint32_t csopsEntHdr[2] = {0, 0};
        errno = 0;
        BOOL csopsEntBlobHdrOK = (pt_harness_csops(0, 7U, csopsEntHdr, sizeof(csopsEntHdr)) == -1 &&
                                  errno == ERANGE &&
                                  ntohl(csopsEntHdr[0]) == 0xfade7171U &&
                                  ntohl(csopsEntHdr[1]) > 8U);
        BOOL csopsStringAndBlobOK = (csopsTeamShortERange && csopsTeamRawOK && csopsIdentityRawOK && csopsEntBlobHdrOK);
        size_t swapLen = 0;
        BOOL swapUsageBlocked = (sysctlbyname("vm.swapusage", NULL, &swapLen, NULL, 0) == -1 && errno == ENOENT);
        uint64_t l2CacheSize = 0;
        size_t l2Len = sizeof(l2CacheSize);
        if (sysctlbyname("hw.l2cachesize", &l2CacheSize, &l2Len, NULL, 0) != 0) {
            l2CacheSize = 0;
        }
        bool (*dscContains)(const char *) = (bool (*)(const char *))dlsym(RTLD_DEFAULT, "_dyld_shared_cache_contains_path");
        BOOL dscHidAppKit = (dscContains == NULL) ||
                            (!dscContains("/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit") &&
                             !dscContains("/System/iOSSupport/System/Library/Frameworks/UIKit.framework/UIKit"));

        struct utsname uts;
        memset(&uts, 0, sizeof(uts));
        if (uname(&uts) != 0) {
            memset(&uts, 0, sizeof(uts));
        }

        CMMotionManager *motionMgr = [[CMMotionManager alloc] init];
        BOOL cmAccelAvailable = motionMgr.isAccelerometerAvailable;
        BOOL cmGyroAvailable = motionMgr.isGyroAvailable;
        BOOL cmDeviceMotionAvailable = motionMgr.isDeviceMotionAvailable;
        [motionMgr startAccelerometerUpdates];
        CMAccelerometerData *cmSample = motionMgr.accelerometerData;
        BOOL cmSampleValid = (cmSample != nil && [cmSample isKindOfClass:[CMAccelerometerData class]] &&
                              cmSample.acceleration.z < -0.9);
        [motionMgr stopAccelerometerUpdates];

        Class dcDeviceCls = NSClassFromString(@"DCDevice");
        if (dcDeviceCls == Nil) {
            NSArray<NSString *> *dcPaths = @[
                @"/System/iOSSupport/System/Library/Frameworks/DeviceCheck.framework",
                @"/System/Library/Frameworks/DeviceCheck.framework"
            ];
            for (NSString *dcPath in dcPaths) {
                NSBundle *dcBundle = [NSBundle bundleWithPath:dcPath];
                if (dcBundle != nil && [dcBundle load]) {
                    dcDeviceCls = NSClassFromString(@"DCDevice");
                    if (dcDeviceCls != Nil) {
                        break;
                    }
                }
            }
        }
        Class appAttestCls = NSClassFromString(@"DCAppAttestService");
        BOOL appAttestLoaded = (appAttestCls != Nil);
        BOOL availIOS16 = NO;
        if (@available(iOS 16.0, *)) {
            availIOS16 = YES;
        }
        BOOL uiColorWellLoaded = (NSClassFromString(@"UIColorWell") != Nil);
        BOOL appAttestSupported = NO;
        BOOL appAttestGenKeyUnsupported = YES;
        if (appAttestCls != Nil) {
            id svc = ((id (*)(id, SEL))objc_msgSend)((id)appAttestCls, sel_registerName("sharedService"));
            if (svc != nil) {
                appAttestSupported = ((BOOL (*)(id, SEL))objc_msgSend)(svc, sel_registerName("isSupported"));
                if (!safeModeActive) {
                    appAttestGenKeyUnsupported = NO;
                    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                    __block NSInteger errCode = -1;
                    __block BOOL gotNilKey = NO;
                    void (^cb)(NSString *, NSError *) = ^(NSString *keyId, NSError *err) {
                        gotNilKey = (keyId == nil);
                        errCode = (err != nil) ? err.code : -1;
                        dispatch_semaphore_signal(sem);
                    };
                    ((void (*)(id, SEL, id))objc_msgSend)(
                        svc, sel_registerName("generateKeyWithCompletionHandler:"), cb);
                    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0) {
                        appAttestGenKeyUnsupported = (gotNilKey && errCode == 1);
                    }
                }
            }
        }
        BOOL dcDeviceLoaded = (dcDeviceCls != Nil);
        BOOL dcDeviceSupported = NO;
        BOOL dcDeviceTokenUnsupported = YES;
        if (dcDeviceCls != Nil) {
            id dev = ((id (*)(id, SEL))objc_msgSend)((id)dcDeviceCls, sel_registerName("currentDevice"));
            if (dev != nil) {
                dcDeviceSupported = ((BOOL (*)(id, SEL))objc_msgSend)(dev, sel_registerName("isSupported"));
                if (!safeModeActive) {
                    dcDeviceTokenUnsupported = NO;
                    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                    __block NSInteger errCode = -1;
                    __block BOOL gotNilToken = NO;
                    void (^cb)(NSData *, NSError *) = ^(NSData *tok, NSError *err) {
                        gotNilToken = (tok == nil);
                        errCode = (err != nil) ? err.code : -1;
                        dispatch_semaphore_signal(sem);
                    };
                    ((void (*)(id, SEL, id))objc_msgSend)(
                        dev, sel_registerName("generateTokenWithCompletionHandler:"), cb);
                    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0) {
                        dcDeviceTokenUnsupported = (gotNilToken && errCode == 1);
                    }
                }
            }
        }

        NSFileManager *fm = [NSFileManager defaultManager];
        NSBundle *mainBundle = [NSBundle mainBundle];
        BOOL hidPCInstallGenNS = ([mainBundle objectForInfoDictionaryKey:@"PCInstallGeneration"] == nil &&
                                  mainBundle.infoDictionary[@"PCInstallGeneration"] == nil);
        BOOL hidPCInstallGenCF = (CFBundleGetValueForInfoDictionaryKey(
            CFBundleGetMainBundle(), CFSTR("PCInstallGeneration")) == NULL);
        NSString *provPath = [mainBundle pathForResource:@"embedded" ofType:@"mobileprovision"] ?: @"";
        NSString *provURLPath = [mainBundle URLForResource:@"embedded" withExtension:@"mobileprovision"].path ?: @"";
        CFURLRef cfProvURL = CFBundleCopyResourceURL(CFBundleGetMainBundle(), CFSTR("embedded"), CFSTR("mobileprovision"), NULL);
        NSString *cfProvURLPath = @"";
        if (cfProvURL != NULL) {
            NSURL *bridged = (__bridge_transfer NSURL *)cfProvURL;
            cfProvURLPath = bridged.path ?: @"";
        }
        NSString *probeProv = (provPath.length > 0)
            ? provPath
            : [[mainBundle bundlePath] stringByAppendingPathComponent:@"embedded.mobileprovision"];
        BOOL provFMExists = [fm fileExistsAtPath:probeProv];
        NSData *provData = [NSData dataWithContentsOfFile:probeProv];
        NSString *provNSDataText = (provData != nil)
            ? ([[NSString alloc] initWithData:provData encoding:NSUTF8StringEncoding] ?: @"")
            : @"";
        NSError *provStrErr = nil;
        NSString *provNSStringText = [NSString stringWithContentsOfFile:probeProv
                                                               encoding:NSUTF8StringEncoding
                                                                  error:&provStrErr] ?: @"";
        char provPosixBuf[256] = {0};
        char provGetPathBuf[PATH_MAX] = {0};
        int pfd = open(probeProv.UTF8String, O_RDONLY);
        if (pfd >= 0) {
            ssize_t pr = read(pfd, provPosixBuf, sizeof(provPosixBuf) - 1);
            if (pr > 0) {
                provPosixBuf[pr] = '\0';
            }
            if (fcntl(pfd, F_GETPATH, provGetPathBuf) == -1) {
                provGetPathBuf[0] = '\0';
            }
            close(pfd);
        }
        char provRealBuf[PATH_MAX] = {0};
        if (realpath(probeProv.UTF8String, provRealBuf) == NULL) {
            provRealBuf[0] = '\0';
        }
        BOOL provWriteAccessAllowed = (access(probeProv.UTF8String, W_OK) == 0) || [fm isWritableFileAtPath:probeProv];

        NSString *bundleExecPath = mainBundle.executablePath ?: @"";
        char execPosixBuf[64] = {0};
        char execGetPathBuf[PATH_MAX] = {0};
        int efd = (bundleExecPath.length > 0) ? open(bundleExecPath.UTF8String, O_RDONLY) : -1;
        if (efd >= 0) {
            ssize_t er = read(efd, execPosixBuf, sizeof(execPosixBuf) - 1);
            if (er > 0) {
                execPosixBuf[er] = '\0';
                for (ssize_t i = 0; i < er; i++) {
                    unsigned char uc = (unsigned char)execPosixBuf[i];
                    if (uc < 0x20 || uc > 0x7E) {
                        execPosixBuf[i] = '?';
                    }
                }
            }
            if (fcntl(efd, F_GETPATH, execGetPathBuf) == -1) {
                execGetPathBuf[0] = '\0';
            }
            close(efd);
        }

        BOOL directBackupStatBlocked = NO;
        BOOL directBackupOpenBlocked = NO;
        BOOL directBackupFMBlocked = NO;
        const char *directProbeB64 = getenv("HARNESS_DIRECT_PROBE_B64");
        if (directProbeB64 != NULL && directProbeB64[0] != '\0') {
            NSString *b64Str = [NSString stringWithUTF8String:directProbeB64];
            NSData *decoded = (b64Str != nil) ? [[NSData alloc] initWithBase64EncodedString:b64Str options:0] : nil;
            NSString *probeStr = (decoded != nil) ? [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding] : nil;
            const char *directProbe = probeStr.UTF8String;
            if (directProbe != NULL && directProbe[0] != '\0') {
                struct stat bst;
                errno = 0;
                directBackupStatBlocked = (stat(directProbe, &bst) != 0 && errno == ENOENT);
                errno = 0;
                int dfd = open(directProbe, O_RDONLY);
                if (dfd >= 0) {
                    close(dfd);
                    directBackupOpenBlocked = NO;
                } else {
                    directBackupOpenBlocked = (errno == ENOENT);
                }
                directBackupFMBlocked = ![fm fileExistsAtPath:probeStr];
            }
        }

        NSObject *dlTarget = [NSObject new];
        CADisplayLink *rangeLink = [CADisplayLink displayLinkWithTarget:dlTarget selector:@selector(description)];
        rangeLink.preferredFrameRateRange = CAFrameRateRangeMake(30.0f, 120.0f, 120.0f);
        float displayLinkClampedMaxHz = rangeLink.preferredFrameRateRange.maximum;
        [rangeLink invalidate];

        CADisplayLink *fpsLink = [CADisplayLink displayLinkWithTarget:dlTarget selector:@selector(description)];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        fpsLink.preferredFramesPerSecond = 120;
        NSInteger displayLinkClampedLegacyFPS = fpsLink.preferredFramesPerSecond;
#pragma clang diagnostic pop
        [fpsLink invalidate];

        char ***nsArgvp = _NSGetArgv();
        int *nsArgcp = _NSGetArgc();
        int nsArgc = (nsArgcp != NULL) ? *nsArgcp : -1;
        NSArray<NSString *> *procArgs = [NSProcessInfo processInfo].arguments;
        NSString *nsArgv0 = (nsArgvp != NULL && *nsArgvp != NULL && (*nsArgvp)[0] != NULL)
            ? ([NSString stringWithUTF8String:(*nsArgvp)[0]] ?: @"")
            : @"";
        NSString *procArgv0 = (procArgs.count > 0) ? procArgs[0] : @"";
        BOOL argvAllMatch = (nsArgvp != NULL && *nsArgvp != NULL &&
                             nsArgc == (int)procArgs.count && nsArgc >= 1);
        BOOL argvLeakedMacFlag = NO;
        if (argvAllMatch) {
            for (int ai = 0; ai < nsArgc; ai++) {
                const char *ca = (*nsArgvp)[ai];
                NSString *sa = (ca != NULL) ? [NSString stringWithUTF8String:ca] : nil;
                if (sa == nil || ![sa isEqualToString:procArgs[(NSUInteger)ai]]) {
                    argvAllMatch = NO;
                    break;
                }
                if ([sa isEqualToString:@"-NSDocumentRevisionsDebugMode"] ||
                    [sa isEqualToString:@"-ApplePersistenceIgnoreState"]) {
                    argvLeakedMacFlag = YES;
                }
            }
            if ((*nsArgvp)[nsArgc] != NULL) {
                argvAllMatch = NO;
            }
        }
        BOOL argvConsistent = argvAllMatch && !argvLeakedMacFlag &&
                              ([nsArgv0 rangeOfString:@"/var/containers/Bundle/Application/"].location != NSNotFound);
        void *blockedDlsym = dlsym(RTLD_DEFAULT, "pt_is_registered_hidden_module");
        Class reflectedSafeMode = NSClassFromString(@"PTSafeMode");
        Class reflectedPluginCls = objc_lookUpClass("MockHarnessHiddenClass");
        SEL shadowSel = NSSelectorFromString(@"pm_isiOSAppOnMac");
        BOOL leakedShadowResponds = [[NSProcessInfo processInfo] respondsToSelector:shadowSel] ||
                                    [NSProcessInfo instancesRespondToSelector:shadowSel] ||
                                    (class_getInstanceMethod([NSProcessInfo class], shadowSel) != NULL);
        unsigned int piMethodCount = 0;
        Method *piMethods = class_copyMethodList([NSProcessInfo class], &piMethodCount);
        if (piMethods != NULL) {
            for (unsigned int mi = 0; mi < piMethodCount; mi++) {
                const char *sname = sel_getName(method_getName(piMethods[mi]));
                if (sname != NULL && strncmp(sname, "pm_", 3) == 0) {
                    leakedShadowResponds = YES;
                    break;
                }
            }
            free(piMethods);
        }
        BOOL dyldLeakedPlugin = NO;
        uint32_t imgCount = _dyld_image_count();
        for (uint32_t i = 0; i < imgCount; i++) {
            const char *imgName = _dyld_get_image_name(i);
            if (imgName != NULL && strstr(imgName, "MockUserPlugin") != NULL) {
                dyldLeakedPlugin = YES;
                break;
            }
        }

        extern const struct mach_header_64 _mh_execute_header;
        const struct mach_header_64 *mh0 = (const struct mach_header_64 *)_dyld_get_image_header(0);
        intptr_t slide0 = _dyld_get_image_vmaddr_slide(0);
        Dl_info mainDlInfo;
        memset(&mainDlInfo, 0, sizeof(mainDlInfo));
        BOOL dladdrOK = (dladdr((const void *)&main, &mainDlInfo) != 0);
        intptr_t computedSlide0 = 0;
        BOOL foundTextSeg = NO;
        if (mh0 != NULL && mh0->magic == MH_MAGIC_64) {
            const uint8_t *lcp = (const uint8_t *)(mh0 + 1);
            const uint8_t *lcEnd = lcp + mh0->sizeofcmds;
            for (uint32_t li = 0; li < mh0->ncmds && lcp + sizeof(struct load_command) <= lcEnd; li++) {
                const struct load_command *lc = (const struct load_command *)lcp;
                if (lc->cmdsize < sizeof(struct load_command) || lcp + lc->cmdsize > lcEnd) {
                    break;
                }
                if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
                    const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
                    if (strncmp(seg->segname, "__TEXT", 16) == 0) {
                        computedSlide0 = (intptr_t)mh0 - (intptr_t)seg->vmaddr;
                        foundTextSeg = YES;
                        break;
                    }
                }
                lcp += lc->cmdsize;
            }
        }
        BOOL mh0BaseAndSlideConsistent = (mh0 != NULL &&
                                          mh0 == &_mh_execute_header &&
                                          dladdrOK &&
                                          mainDlInfo.dli_fbase == (void *)mh0 &&
                                          foundTextSeg &&
                                          computedSlide0 == slide0);
        __block uint32_t mh0Platform = 0;
        if (mh0 != NULL && pt_harness_dyld_get_image_versions != NULL) {
            pt_harness_dyld_get_image_versions((const struct mach_header *)mh0, ^(uint32_t platform, uint32_t sdk, uint32_t minos) {
                (void)sdk;
                (void)minos;
                if (mh0Platform == 0) {
                    mh0Platform = platform;
                }
            });
        }
        unsigned long mh0TextSize = 0;
        uint8_t *mh0TextPtr = (mh0 != NULL) ? getsectiondata(mh0, "__TEXT", "__text", &mh0TextSize) : NULL;
        BOOL mh0SectionLookupOK = (mh0TextPtr != NULL && mh0TextSize > 0);

        NSString *stateDir = pt_state_dir();
        NSString *crumbPath = [stateDir stringByAppendingPathComponent:@".launching_in_progress"];
        NSString *triggeredPath = [stateDir stringByAppendingPathComponent:@".safe_mode_last_triggered"];

        BOOL crumbAtStart = [fm fileExistsAtPath:crumbPath];
        BOOL triggeredAtStart = [fm fileExistsAtPath:triggeredPath];

        double sleepSecs = 0.0;
        const char *sleepEnv = getenv("HARNESS_SLEEP_SECS");
        if (sleepEnv != NULL && sleepEnv[0] != '\0') {
            sleepSecs = atof(sleepEnv);
        }
        if (sleepSecs > 0.0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:sleepSecs]];
        }

        BOOL crumbAfterSleep = [fm fileExistsAtPath:crumbPath];

        const char *gracefulEnv = getenv("HARNESS_GRACEFUL_EXIT");
        if (gracefulEnv != NULL && strcmp(gracefulEnv, "1") == 0) {
            [[PTSafeMode shared] markGracefulTermination];
        }

        NSDictionary *payload = @{
            @"safeModeActive": safeModeActive ? @YES : @NO,
            @"customScaler": @(customScaler),
            @"inverseScreenValues": inverseScreenValues ? @YES : @NO,
            @"windowFixMethod": @(windowFixMethod),
            @"targetFrameRateHz": @(targetFrameRateHz),
            @"reportedIOSVersion": reportedIOSVersion,
            @"osVersionMajor": @(osVer.majorVersion),
            @"osVersionMinor": @(osVer.minorVersion),
            @"osVersionPatch": @(osVer.patchVersion),
            @"osVersionString": osVerString,
            @"uiDeviceSystemVersion": uiDeviceSysVer,
            @"sysctlOSProductVersion": [NSString stringWithUTF8String:sysctlProdVer] ?: @"",
            @"sysctlOSVersion": [NSString stringWithUTF8String:sysctlOSVer] ?: @"",
            @"sysctlOSRelease": [NSString stringWithUTF8String:sysctlOSRelease] ?: @"",
            @"sysctlVersion": [NSString stringWithUTF8String:sysctlVersion] ?: @"",
            @"sysctlMachine": [NSString stringWithUTF8String:sysctlMachine] ?: @"",
            @"syscallMachine": [NSString stringWithUTF8String:syscallMachine] ?: @"",
            @"syscallWideArityOK": syscallWideArityOK ? @YES : @NO,
            @"swapUsageBlocked": swapUsageBlocked ? @YES : @NO,
            @"csopsStringAndBlobOK": csopsStringAndBlobOK ? @YES : @NO,
            @"l2CacheSize": @(l2CacheSize),
            @"dscHidAppKit": dscHidAppKit ? @YES : @NO,
            @"unameRelease": [NSString stringWithUTF8String:uts.release] ?: @"",
            @"unameVersion": [NSString stringWithUTF8String:uts.version] ?: @"",
            @"unameMachine": [NSString stringWithUTF8String:uts.machine] ?: @"",
            @"appAttestLoaded": appAttestLoaded ? @YES : @NO,
            @"availIOS16": availIOS16 ? @YES : @NO,
            @"uiColorWellLoaded": uiColorWellLoaded ? @YES : @NO,
            @"appAttestSupported": appAttestSupported ? @YES : @NO,
            @"appAttestGenKeyUnsupported": appAttestGenKeyUnsupported ? @YES : @NO,
            @"dcDeviceLoaded": dcDeviceLoaded ? @YES : @NO,
            @"dcDeviceSupported": dcDeviceSupported ? @YES : @NO,
            @"dcDeviceTokenUnsupported": dcDeviceTokenUnsupported ? @YES : @NO,
            @"cmAccelAvailable": cmAccelAvailable ? @YES : @NO,
            @"cmGyroAvailable": cmGyroAvailable ? @YES : @NO,
            @"cmDeviceMotionAvailable": cmDeviceMotionAvailable ? @YES : @NO,
            @"cmSampleValid": cmSampleValid ? @YES : @NO,
            @"provPath": provPath,
            @"hidPCInstallGen": (hidPCInstallGenNS && hidPCInstallGenCF) ? @YES : @NO,
            @"provURLPath": provURLPath,
            @"cfProvURLPath": cfProvURLPath,
            @"provFMExists": provFMExists ? @YES : @NO,
            @"provNSDataText": provNSDataText,
            @"provNSStringText": provNSStringText,
            @"provPosixText": [NSString stringWithUTF8String:provPosixBuf] ?: @"",
            @"provGetPath": [NSString stringWithUTF8String:provGetPathBuf] ?: @"",
            @"provRealpath": [NSString stringWithUTF8String:provRealBuf] ?: @"",
            @"provWriteAccessAllowed": provWriteAccessAllowed ? @YES : @NO,
            @"execPosixPrefix": [NSString stringWithUTF8String:execPosixBuf] ?: @"",
            @"execGetPath": [NSString stringWithUTF8String:execGetPathBuf] ?: @"",
            @"bundleExecutablePath": bundleExecPath,
            @"directBackupStatBlocked": directBackupStatBlocked ? @YES : @NO,
            @"directBackupOpenBlocked": directBackupOpenBlocked ? @YES : @NO,
            @"directBackupFMBlocked": directBackupFMBlocked ? @YES : @NO,
            @"displayLinkClampedMaxHz": @(displayLinkClampedMaxHz),
            @"displayLinkClampedLegacyFPS": @(displayLinkClampedLegacyFPS),
            @"hiddenModuleRegistered": modHidden ? @YES : @NO,
            @"hiddenIdentifierRegistered": idHidden ? @YES : @NO,
            @"hiddenClassRegistered": clsHidden ? @YES : @NO,
            @"antiDetectionHidDlsym": (blockedDlsym == NULL) ? @YES : @NO,
            @"antiDetectionHidSafeModeClass": (reflectedSafeMode == Nil) ? @YES : @NO,
            @"antiDetectionHidPluginClass": (reflectedPluginCls == Nil) ? @YES : @NO,
            @"antiDetectionHidShadowSelector": (!leakedShadowResponds) ? @YES : @NO,
            @"antiDetectionHidPluginImage": (!dyldLeakedPlugin) ? @YES : @NO,
            @"mh0Platform": @(mh0Platform),
            @"mh0BaseAndSlideConsistent": mh0BaseAndSlideConsistent ? @YES : @NO,
            @"mh0SectionLookupOK": mh0SectionLookupOK ? @YES : @NO,
            @"argvConsistent": argvConsistent ? @YES : @NO,
            @"procArgCount": @(procArgs.count),
            @"stateDir": stateDir ?: @"",
            @"breadcrumbExistsAtStart": crumbAtStart ? @YES : @NO,
            @"breadcrumbExistsAfterSleep": crumbAfterSleep ? @YES : @NO,
            @"safeModeMarkerExists": triggeredAtStart ? @YES : @NO,
            @"privateFrameworksPath": [NSBundle mainBundle].privateFrameworksURL.path ?: @""
        };
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        printf("HARNESS_JSON:%s\n", jsonStr.UTF8String);
        fflush(stdout);
    }
    return 0;
}
"""


@dataclass
class ScenarioResult:
    name: str
    passed: bool
    duration_sec: float
    details: str


def run_cmd(cmd: list[str], env: Optional[dict[str, str]] = None, check: bool = True) -> subprocess.CompletedProcess:
    proc = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    if check and proc.returncode != 0:
        raise RuntimeError(
            f"Command failed ({proc.returncode}): {' '.join(cmd)}\n"
            f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
        )
    return proc


def resolve_playtools_framework(repo_root: Path, explicit: Optional[str]) -> Path:
    candidates: list[Path] = []
    if explicit:
        p = Path(explicit).expanduser().resolve()
        if (p / "PlayTools").exists():
            return p
        cat_slice = p / "ios-arm64-maccatalyst" / "PlayTools.framework"
        if (cat_slice / "PlayTools").exists():
            return cat_slice
        raise FileNotFoundError(f"PlayTools.framework not found at {p}")

    # Auto-discover built framework in MacOver locations.
    macover_fw = (
        Path.home()
        / "Library/Containers/app.makedie.MacOver/Frameworks/PlayTools.framework"
    )
    if (macover_fw / "PlayTools").exists():
        candidates.append(macover_fw)
    app_fw = Path("/Applications/MacOver.app/Contents/Frameworks/PlayTools.framework")
    if (app_fw / "PlayTools").exists():
        candidates.append(app_fw)

    if candidates:
        return candidates[0]
    raise FileNotFoundError(
        "Could not locate PlayTools.framework. Pass --playtools-framework <path>."
    )


def parse_harness_json(stdout: str) -> dict:
    for line in stdout.splitlines():
        if line.startswith("HARNESS_JSON:"):
            return json.loads(line[len("HARNESS_JSON:"):])
    raise AssertionError(f"Missing HARNESS_JSON line in output:\n{stdout}")


def write_test_settings_plist(isolated_home: Path, bundle_id: str) -> Path:
    """Configure customScaler != 1.0 in MockTarget's settings plist so Safe Mode revert is observable."""
    target_dir = isolated_home / "Library/Containers/app.makedie.MacOver/PlayTools"
    target_dir.mkdir(parents=True, exist_ok=True)
    plist_path = target_dir / f"{bundle_id}.plist"
    with open(plist_path, "wb") as fp:
        plistlib.dump({"customScaler": 1.75}, fp)
    return plist_path


def build_mock_app(work_dir: Path, playtools_fw: Path) -> Path:
    tool_env = os.environ.copy()
    if "DEVELOPER_DIR" not in tool_env and Path("/Applications/Xcode.app/Contents/Developer").is_dir():
        tool_env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    sdk_path = run_cmd(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=tool_env).stdout.strip()
    ios_support_fw = f"{sdk_path}/System/iOSSupport/System/Library/Frameworks"
    fw_parent = str(playtools_fw.parent)

    app_dir = work_dir / "MockTarget.app"
    plugins_dir = app_dir / "Frameworks/UserPlugins"
    plugins_dir.mkdir(parents=True, exist_ok=True)

    # Flat iOS/MacCatalyst bundle Info.plist
    clean_info_plist = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": "MockTarget",
        "CFBundleIdentifier": "app.makedie.harness.mockapp",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "MockTarget",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
    }
    info_plist = {
        **clean_info_plist,
        "PCInstallGeneration": "HARNESS-GEN-101",
    }
    with open(app_dir / "Info.plist", "wb") as fp:
        plistlib.dump(info_plist, fp)

    # 1. Build MockUserPlugin.dylib
    plugin_c = work_dir / "MockUserPlugin.c"
    plugin_c.write_text(MOCK_PLUGIN_C, encoding="utf-8")
    plugin_dylib = plugins_dir / "MockUserPlugin.dylib"
    run_cmd([
        "xcrun", "clang", "-dynamiclib",
        "-target", "arm64-apple-ios15.0-macabi",
        "-isysroot", sdk_path,
        "-O2", "-Wall", "-Wextra",
        "-install_name", "@rpath/MockUserPlugin.dylib",
        str(plugin_c),
        "-o", str(plugin_dylib),
    ], env=tool_env)
    run_cmd(["codesign", "--force", "--sign", "-", str(plugin_dylib)], env=tool_env)

    # PlayTools default PlayToolsVersion lookup reads CFBundleShortVersionString from PlayTools.framework
    manifest = {
        "manifestVersion": "1.0",
        "identifier": "app.makedie.harness.mockplugin",
        "name": "Mock Harness Plugin",
        "version": "1.0.0",
        "minPlayToolsVersion": "1.0.0",
        "targetBundleIdentifiers": ["app.makedie.harness.mockapp"],
        "loadPriority": 50,
        "capabilities": ["runtime-harness"],
        "entrypoint": "MockUserPlugin.dylib",
    }
    (plugins_dir / "MockUserPlugin.manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n",
        encoding="utf-8",
    )

    # 2. Build MockTarget executable linked against PlayTools.framework
    target_m = work_dir / "MockTarget.m"
    target_m.write_text(MOCK_TARGET_M, encoding="utf-8")
    target_bin = app_dir / "MockTarget"
    run_cmd([
        "xcrun", "clang", "-fobjc-arc", "-fmodules", "-O2",
        "-target", "arm64-apple-ios15.0-macabi",
        "-isysroot", sdk_path,
        "-iframework", ios_support_fw,
        "-F", fw_parent,
        "-framework", "Foundation",
        "-framework", "CoreMotion",
        "-framework", "QuartzCore",
        "-framework", "UIKit",
        "-framework", "PlayTools",
        "-Wl,-rpath,@executable_path/Frameworks",
        f"-Wl,-rpath,{fw_parent}",
        str(target_m),
        "-o", str(target_bin),
    ], env=tool_env)
    run_cmd(["codesign", "--force", "--deep", "--sign", "-", str(app_dir)], env=tool_env)
    return target_bin


def run_scenarios(target_bin: Path, work_dir: Path, verbose: bool) -> list[ScenarioResult]:
    results: list[ScenarioResult] = []
    isolated_home = work_dir / "IsolatedHome"
    isolated_home.mkdir(parents=True, exist_ok=True)
    settings_plist = write_test_settings_plist(isolated_home, "app.makedie.harness.mockapp")

    def base_env(marker_path: Path, **extra: str) -> dict[str, str]:
        env = os.environ.copy()
        env["HOME"] = str(isolated_home)
        env["CFFIXED_USER_HOME"] = str(isolated_home)
        env["TMPDIR"] = str(work_dir / "tmp")
        env["PLAYTOOLS_SETTINGS_PLIST"] = str(settings_plist)
        Path(env["TMPDIR"]).mkdir(parents=True, exist_ok=True)
        # Ensure we do not inherit Safe Mode, bypass disables, or debug trace flags from caller environment.
        env.pop("PLAYTOOLS_SAFE_MODE", None)
        env.pop("DISABLE_PLAYSHADOW_BYPASS", None)
        env.pop("PLAYTOOLS_DEBUG_LOG", None)
        env["HARNESS_PLUGIN_MARKER"] = str(marker_path)
        env.update(extra)
        return env

    # Scenario 1: Clean launch -> plugin loads, dynamic registration succeeds, stability timer clears breadcrumb.
    t0 = time.monotonic()
    marker1 = work_dir / "marker_1.txt"
    proc1 = run_cmd(
        [
            str(target_bin),
            "-NSDocumentRevisionsDebugMode",
            "YES",
            "-ApplePersistenceIgnoreState",
            "YES",
            "--harness-keep",
        ],
        env=base_env(marker1, HARNESS_SLEEP_SECS="3.5"),
        check=False,
    )
    if proc1.returncode != 0:
        results.append(ScenarioResult(
            name="1. Normal launch, injection & stability breadcrumb clear",
            passed=False,
            duration_sec=time.monotonic() - t0,
            details=f"Exit code {proc1.returncode}\nstdout={proc1.stdout}\nstderr={proc1.stderr}",
        ))
        return results

    info1 = parse_harness_json(proc1.stdout)
    checks1 = [
        info1["safeModeActive"] is False,
        abs(float(info1["customScaler"]) - 1.75) < 1e-4,
        marker1.exists(),
        info1["hiddenModuleRegistered"] is True,
        info1["hiddenIdentifierRegistered"] is True,
        info1["hiddenClassRegistered"] is True,
        info1["antiDetectionHidDlsym"] is True,
        info1["antiDetectionHidSafeModeClass"] is True,
        info1["antiDetectionHidPluginClass"] is True,
        info1["antiDetectionHidShadowSelector"] is True,
        info1["antiDetectionHidPluginImage"] is True,
        info1["mh0Platform"] == 2,
        info1["mh0BaseAndSlideConsistent"] is True,
        info1["mh0SectionLookupOK"] is True,
        info1["argvConsistent"] is True,
        info1["procArgCount"] == 2,
        info1["cmAccelAvailable"] is True,
        info1["cmGyroAvailable"] is True,
        info1["cmDeviceMotionAvailable"] is True,
        info1["cmSampleValid"] is True,
        info1["availIOS16"] is True,
        info1["uiColorWellLoaded"] is True,
        info1["hidPCInstallGen"] is True,
        info1["swapUsageBlocked"] is True,
        info1["csopsStringAndBlobOK"] is True,
        0 < int(info1["l2CacheSize"]) <= (16 << 20),
        info1["dscHidAppKit"] is True,
        (not info1["appAttestLoaded"]) or (
            info1["appAttestSupported"] is False and info1["appAttestGenKeyUnsupported"] is True
        ),
        (not info1["dcDeviceLoaded"]) or (
            info1["dcDeviceSupported"] is False and info1["dcDeviceTokenUnsupported"] is True
        ),
        info1["breadcrumbExistsAtStart"] is True,
        info1["breadcrumbExistsAfterSleep"] is False,
    ]
    results.append(ScenarioResult(
        name="1. Normal launch, injection & stability breadcrumb clear",
        passed=all(checks1),
        duration_sec=time.monotonic() - t0,
        details=json.dumps(info1, sort_keys=True),
    ))
    if verbose:
        print("  Scenario 1 payload:", info1)

    # Scenario 2: Simulated early crash (<3s) -> next launch activates Safe Mode and blocks user plugins.
    t1 = time.monotonic()
    marker_crash = work_dir / "marker_crash.txt"
    proc_crash = run_cmd(
        [str(target_bin)],
        env=base_env(marker_crash, HARNESS_SIMULATE_CRASH="1"),
        check=False,
    )
    crumb_path = Path(info1["stateDir"]) / ".launching_in_progress"
    marker2 = work_dir / "marker_2_safemode.txt"
    proc2 = run_cmd(
        [str(target_bin)],
        env=base_env(marker2),
        check=False,
    )
    if proc2.returncode != 0:
        results.append(ScenarioResult(
            name="2. Early crash post-mortem detection -> Safe Mode activation",
            passed=False,
            duration_sec=time.monotonic() - t1,
            details=f"Recovery launch failed with {proc2.returncode}\nstderr={proc2.stderr}",
        ))
        return results

    info2 = parse_harness_json(proc2.stdout)
    checks2 = [
        proc_crash.returncode == 134,
        info2["safeModeActive"] is True,
        info2["safeModeMarkerExists"] is True,
        info2["breadcrumbExistsAtStart"] is False,
        info2["hiddenModuleRegistered"] is False,
        info2["hiddenClassRegistered"] is False,
        not crumb_path.exists(),
        not marker2.exists(),
        abs(float(info2["customScaler"]) - 1.0) < 1e-6,
    ]
    results.append(ScenarioResult(
        name="2. Early crash post-mortem detection -> Safe Mode activation",
        passed=all(checks2),
        duration_sec=time.monotonic() - t1,
        details=json.dumps({"crashCode": proc_crash.returncode, "pluginLoadedInSafeMode": marker2.exists(), **info2}, sort_keys=True),
    ))
    if verbose:
        print("  Scenario 2 payload:", info2)

    # Scenario 3: Subsequent launch after Safe Mode recovers to normal operation & loads plugins again.
    t2 = time.monotonic()
    marker3 = work_dir / "marker_3_recovered.txt"
    proc3 = run_cmd(
        [str(target_bin)],
        env=base_env(marker3, HARNESS_GRACEFUL_EXIT="1"),
        check=False,
    )
    if proc3.returncode != 0:
        results.append(ScenarioResult(
            name="3. Post-Safe-Mode recovery & plugin reload",
            passed=False,
            duration_sec=time.monotonic() - t2,
            details=f"Exit code {proc3.returncode}\nstderr={proc3.stderr}",
        ))
        return results

    info3 = parse_harness_json(proc3.stdout)
    checks3 = [
        info3["safeModeActive"] is False,
        abs(float(info3["customScaler"]) - 1.75) < 1e-4,
        marker3.exists(),
        info3["hiddenModuleRegistered"] is True,
        info3["hiddenClassRegistered"] is True,
        not crumb_path.exists(),
    ]
    results.append(ScenarioResult(
        name="3. Post-Safe-Mode recovery & plugin reload",
        passed=all(checks3),
        duration_sec=time.monotonic() - t2,
        details=json.dumps({"pluginLoadedAfterRecovery": marker3.exists(), **info3}, sort_keys=True),
    ))
    if verbose:
        print("  Scenario 3 payload:", info3)

    # Scenario 4: PLAYTOOLS_DEBUG_LOG=1 emits [PlayTools] traces while anti-detection remains intact.
    t3 = time.monotonic()
    marker4 = work_dir / "marker_4_debuglog.txt"
    proc4 = run_cmd(
        [str(target_bin)],
        env=base_env(marker4, HARNESS_GRACEFUL_EXIT="1", PLAYTOOLS_DEBUG_LOG="1"),
        check=False,
    )
    if proc4.returncode != 0:
        results.append(ScenarioResult(
            name="4. PLAYTOOLS_DEBUG_LOG=1 C/ObjC trace output & intact anti-detection",
            passed=False,
            duration_sec=time.monotonic() - t3,
            details=f"Exit code {proc4.returncode}\nstderr={proc4.stderr}",
        ))
        return results

    info4 = parse_harness_json(proc4.stdout)
    debug_lines = [line for line in proc4.stderr.splitlines() if line.startswith("[PlayTools] [")]
    has_spoofer_trace = any("[PlayTools] [spoofer]" in line for line in debug_lines)
    has_dyld_trace = any("[PlayTools] [dyld]" in line for line in debug_lines)
    checks4 = [
        len(debug_lines) >= 2,
        has_spoofer_trace,
        has_dyld_trace,
        marker4.exists(),
        info4["safeModeActive"] is False,
        info4["antiDetectionHidDlsym"] is True,
        info4["antiDetectionHidSafeModeClass"] is True,
        info4["antiDetectionHidPluginClass"] is True,
        info4["antiDetectionHidPluginImage"] is True,
        not crumb_path.exists(),
    ]
    results.append(ScenarioResult(
        name="4. PLAYTOOLS_DEBUG_LOG=1 C/ObjC trace output & intact anti-detection",
        passed=all(checks4),
        duration_sec=time.monotonic() - t3,
        details=json.dumps({
            "debugTraceCount": len(debug_lines),
            "sampleTraceLines": debug_lines[:5],
            **info4,
        }, sort_keys=True),
    ))
    if verbose:
        print("  Scenario 4 payload:", {"debugTraceCount": len(debug_lines), **info4})

    # Scenario 5: runtime settings (reportedIOSVersion compat18_3, fixed30, inverseScreenValues, windowFixMethod)
    # + one-shot Safe Mode revert without mutating plist on disk.
    t4 = time.monotonic()
    isolated_home_5 = work_dir / "IsolatedHome5"
    isolated_home_5.mkdir(parents=True, exist_ok=True)
    target_dir_5 = isolated_home_5 / "Library/Containers/app.makedie.MacOver/PlayTools"
    target_dir_5.mkdir(parents=True, exist_ok=True)
    plist5 = target_dir_5 / "app.makedie.harness.mockapp.plist"
    with open(plist5, "wb") as fp:
        plistlib.dump(
            {
                "customScaler": 1.75,
                "inverseScreenValues": True,
                "windowFixMethod": 1,
                "frameRateTarget": "fixed30",
                "reportedIOSVersion": "compat18_3",
            },
            fp,
        )
    plist5_bytes_before = plist5.read_bytes()

    def env5(marker_path: Path, **extra: str) -> dict[str, str]:
        env = base_env(marker_path, **extra)
        env["HOME"] = str(isolated_home_5)
        env["CFFIXED_USER_HOME"] = str(isolated_home_5)
        env["PLAYTOOLS_SETTINGS_PLIST"] = str(plist5)
        return env

    marker5a = work_dir / "marker_5a.txt"
    proc5a = run_cmd([str(target_bin)], env=env5(marker5a, HARNESS_GRACEFUL_EXIT="1"), check=False)
    marker5b = work_dir / "marker_5b.txt"
    proc5b = run_cmd(
        [str(target_bin)],
        env=env5(marker5b, PLAYTOOLS_SAFE_MODE="1", HARNESS_GRACEFUL_EXIT="1"),
        check=False,
    )
    if proc5a.returncode != 0 or proc5b.returncode != 0:
        results.append(ScenarioResult(
            name="5. compat18_3 / fixed30 clamping & one-shot Safe Mode revert",
            passed=False,
            duration_sec=time.monotonic() - t4,
            details=(
                f"Sub-run rc=({proc5a.returncode}, {proc5b.returncode})\n"
                f"5a stdout={proc5a.stdout}\n5a stderr={proc5a.stderr}\n"
                f"5b stdout={proc5b.stdout}\n5b stderr={proc5b.stderr}"
            ),
        ))
        return results

    info5a = parse_harness_json(proc5a.stdout)
    info5b = parse_harness_json(proc5b.stdout)
    plist5_bytes_after = plist5.read_bytes()
    checks5 = [
        info5a["safeModeActive"] is False,
        info5a["reportedIOSVersion"] == "compat18_3",
        info5a["osVersionMajor"] == 18,
        info5a["osVersionMinor"] == 3,
        info5a["uiDeviceSystemVersion"] == "18.3",
        info5a["sysctlOSProductVersion"] == "18.3",
        info5a["sysctlOSVersion"] == "22D63",
        info5a["targetFrameRateHz"] == 30,
        0.0 < float(info5a["displayLinkClampedMaxHz"]) <= 30.0,
        info5a["displayLinkClampedLegacyFPS"] == 30,
        info5a["inverseScreenValues"] is True,
        info5a["windowFixMethod"] == 1,
        abs(float(info5a["customScaler"]) - 1.75) < 1e-4,
        marker5a.exists(),
        info5b["safeModeActive"] is True,
        info5b["targetFrameRateHz"] == 0,
        info5b["inverseScreenValues"] is False,
        info5b["windowFixMethod"] == 0,
        abs(float(info5b["customScaler"]) - 1.0) < 1e-4,
        info5b["reportedIOSVersion"] == "automatic",
        info5b["osVersionMajor"] != 18,
        float(info5b["displayLinkClampedMaxHz"]) >= 119.0,
        info5b["displayLinkClampedLegacyFPS"] == 120,
        not marker5b.exists(),
        plist5_bytes_after == plist5_bytes_before,
    ]
    results.append(ScenarioResult(
        name="5. compat18_3 / fixed30 clamping & one-shot Safe Mode revert",
        passed=all(checks5),
        duration_sec=time.monotonic() - t4,
        details=json.dumps(
            {
                "normal": info5a,
                "safeMode": info5b,
                "plistUnchanged": plist5_bytes_after == plist5_bytes_before,
            },
            sort_keys=True,
        ),
    ))
    if verbose:
        print("  Scenario 5 normal:", info5a)
        print("  Scenario 5 safeMode:", info5b)

    # Scenario 6: compat13_7 + iPhone12,5 + aligned Darwin 19.6.0 / xnu-6153 + App Attest isSupported=NO
    t5 = time.monotonic()
    isolated_home_6 = work_dir / "IsolatedHome6"
    isolated_home_6.mkdir(parents=True, exist_ok=True)
    target_dir_6 = isolated_home_6 / "Library/Containers/app.makedie.MacOver/PlayTools"
    target_dir_6.mkdir(parents=True, exist_ok=True)
    plist6 = target_dir_6 / "app.makedie.harness.mockapp.plist"
    with open(plist6, "wb") as fp:
        plistlib.dump(
            {
                "reportedIOSVersion": "compat13_7",
                "iosDeviceModel": "iPhone12,5",
            },
            fp,
        )
    plist6_bytes_before = plist6.read_bytes()

    def env6(marker_path: Path, **extra: str) -> dict[str, str]:
        env = base_env(marker_path, **extra)
        env["HOME"] = str(isolated_home_6)
        env["CFFIXED_USER_HOME"] = str(isolated_home_6)
        env["PLAYTOOLS_SETTINGS_PLIST"] = str(plist6)
        return env

    marker6a = work_dir / "marker_6a.txt"
    proc6a = run_cmd([str(target_bin)], env=env6(marker6a, HARNESS_GRACEFUL_EXIT="1"), check=False)
    marker6b = work_dir / "marker_6b.txt"
    proc6b = run_cmd(
        [str(target_bin)],
        env=env6(marker6b, PLAYTOOLS_SAFE_MODE="1", HARNESS_GRACEFUL_EXIT="1"),
        check=False,
    )
    if proc6a.returncode != 0 or proc6b.returncode != 0:
        results.append(ScenarioResult(
            name="6. compat13_7 / iPhone12,5 / 19.6.0 / App Attest & Safe Mode revert",
            passed=False,
            duration_sec=time.monotonic() - t5,
            details=(
                f"Sub-run rc=({proc6a.returncode}, {proc6b.returncode})\n"
                f"6a stdout={proc6a.stdout}\n6a stderr={proc6a.stderr}\n"
                f"6b stdout={proc6b.stdout}\n6b stderr={proc6b.stderr}"
            ),
        ))
        return results

    info6a = parse_harness_json(proc6a.stdout)
    info6b = parse_harness_json(proc6b.stdout)
    plist6_bytes_after = plist6.read_bytes()
    checks6 = [
        info6a["safeModeActive"] is False,
        info6a["reportedIOSVersion"] == "compat13_7",
        info6a["osVersionMajor"] == 13,
        info6a["osVersionMinor"] == 7,
        info6a["uiDeviceSystemVersion"] == "13.7",
        info6a["sysctlOSProductVersion"] == "13.7",
        info6a["sysctlOSVersion"] == "17H35",
        info6a["sysctlOSRelease"] == "19.6.0",
        info6a["unameRelease"] == "19.6.0",
        "xnu-6153" in info6a["sysctlVersion"],
        "xnu-6153" in info6a["unameVersion"],
        info6a["sysctlMachine"] == "iPhone12,5",
        info6a["syscallMachine"] == "iPhone12,5",
        info6a["syscallWideArityOK"] is True,
        info6a["unameMachine"] == "iPhone12,5",
        0.0 < float(info6a["displayLinkClampedMaxHz"]) <= 60.0,
        info6a["displayLinkClampedLegacyFPS"] == 60,
        (not info6a["appAttestLoaded"]) or (info6a["appAttestSupported"] is False),
        info6a["appAttestLoaded"] is False,
        info6a["availIOS16"] is False,
        info6a["uiColorWellLoaded"] is False,
        marker6a.exists(),
        info6b["safeModeActive"] is True,
        info6b["reportedIOSVersion"] == "automatic",
        info6b["osVersionMajor"] != 13,
        info6b["availIOS16"] is True,
        info6b["uiColorWellLoaded"] is True,
        info6b["sysctlOSRelease"] != "19.6.0",
        info6b["unameRelease"] != "19.6.0",
        not marker6b.exists(),
        plist6_bytes_after == plist6_bytes_before,
    ]
    results.append(ScenarioResult(
        name="6. compat13_7 / iPhone12,5 / 19.6.0 / App Attest & Safe Mode revert",
        passed=all(checks6),
        duration_sec=time.monotonic() - t5,
        details=json.dumps(
            {
                "normal": info6a,
                "safeMode": info6b,
                "plistUnchanged": plist6_bytes_after == plist6_bytes_before,
            },
            sort_keys=True,
        ),
    ))
    if verbose:
        print("  Scenario 6 normal:", info6a)
        print("  Scenario 6 safeMode:", info6b)

    # Scenario 7: AppBackups read-only virtualization, direct-probe hiding, Safe Mode bypass, absent backup safety
    t6 = time.monotonic()
    isolated_home_7 = work_dir / "IsolatedHome7"
    backup_dir_7 = isolated_home_7 / "Library/Containers/app.makedie.MacOver/AppBackups/app.makedie.harness.mockapp"
    backup_dir_7.mkdir(parents=True, exist_ok=True)
    backup_prov_7 = backup_dir_7 / "embedded.mobileprovision"
    backup_exec_7 = backup_dir_7 / "executable"
    backup_prov_bytes = b"MOCK_BACKUP_MOBILEPROVISION_101"
    backup_exec_bytes = b"BACKUP_EXEC_PAYLOAD_101"
    backup_prov_7.write_bytes(backup_prov_bytes)
    backup_exec_7.write_bytes(backup_exec_bytes)
    os.chmod(backup_exec_7, 0o755)
    with open(backup_dir_7 / "Info.plist", "wb") as fp:
        plistlib.dump(
            {
                "CFBundleDevelopmentRegion": "en",
                "CFBundleExecutable": "MockTarget",
                "CFBundleIdentifier": "app.makedie.harness.mockapp",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": "MockTarget",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
            },
            fp,
        )
    with open(backup_dir_7 / "manifest.plist", "wb") as fp:
        plistlib.dump(
            {
                "CFBundleIdentifier": "app.makedie.harness.mockapp",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "PCInstallGeneration": "HARNESS-GEN-101",
            },
            fp,
        )
    unmanifested_dir_7 = isolated_home_7 / "UnmanifestedBackups"
    unmanifested_dir_7.mkdir(parents=True, exist_ok=True)
    (unmanifested_dir_7 / "embedded.mobileprovision").write_bytes(backup_prov_bytes)
    (unmanifested_dir_7 / "executable").write_bytes(backup_exec_bytes)
    plist7 = write_test_settings_plist(isolated_home_7, "app.makedie.harness.mockapp")

    def env7(marker_path: Path, backup_override: Path, **extra: str) -> dict[str, str]:
        env = base_env(marker_path, **extra)
        env["HOME"] = str(isolated_home_7)
        env["CFFIXED_USER_HOME"] = str(isolated_home_7)
        env["PLAYTOOLS_SETTINGS_PLIST"] = str(plist7)
        env["PLAYTOOLS_TEST_APP_BACKUPS_DIR"] = str(backup_override)
        return env

    marker7a = work_dir / "marker_7a.txt"
    direct_probe_b64 = base64.b64encode(str(backup_prov_7).encode("utf-8")).decode("ascii")
    proc7a = run_cmd(
        [str(target_bin)],
        env=env7(
            marker7a,
            backup_dir_7,
            HARNESS_DIRECT_PROBE_B64=direct_probe_b64,
            HARNESS_GRACEFUL_EXIT="1",
        ),
        check=False,
    )
    marker7b = work_dir / "marker_7b.txt"
    proc7b = run_cmd(
        [str(target_bin)],
        env=env7(
            marker7b,
            backup_dir_7,
            PLAYTOOLS_SAFE_MODE="1",
            HARNESS_GRACEFUL_EXIT="1",
        ),
        check=False,
    )
    marker7c = work_dir / "marker_7c.txt"
    proc7c = run_cmd(
        [str(target_bin)],
        env=env7(
            marker7c,
            isolated_home_7 / "NonExistentBackups",
            HARNESS_GRACEFUL_EXIT="1",
        ),
        check=False,
    )
    marker7d = work_dir / "marker_7d.txt"
    proc7d = run_cmd(
        [str(target_bin)],
        env=env7(
            marker7d,
            unmanifested_dir_7,
            HARNESS_GRACEFUL_EXIT="1",
        ),
        check=False,
    )
    if (
        proc7a.returncode != 0
        or proc7b.returncode != 0
        or proc7c.returncode != 0
        or proc7d.returncode != 0
    ):
        results.append(ScenarioResult(
            name="7. AppBackups read-only virtualization & direct-probe hiding",
            passed=False,
            duration_sec=time.monotonic() - t6,
            details=(
                f"Sub-run rc=({proc7a.returncode}, {proc7b.returncode}, "
                f"{proc7c.returncode}, {proc7d.returncode})\n"
                f"7a stdout={proc7a.stdout}\n7a stderr={proc7a.stderr}\n"
                f"7b stdout={proc7b.stdout}\n7b stderr={proc7b.stderr}\n"
                f"7c stdout={proc7c.stdout}\n7c stderr={proc7c.stderr}\n"
                f"7d stdout={proc7d.stdout}\n7d stderr={proc7d.stderr}"
            ),
        ))
        return results

    info7a = parse_harness_json(proc7a.stdout)
    info7b = parse_harness_json(proc7b.stdout)
    info7c = parse_harness_json(proc7c.stdout)
    info7d = parse_harness_json(proc7d.stdout)
    checks7 = [
        info7a["safeModeActive"] is False,
        info7a["provPath"].endswith("/embedded.mobileprovision"),
        "/var/containers/Bundle/Application/" in info7a["provPath"],
        info7a["provURLPath"] == info7a["provPath"],
        info7a["cfProvURLPath"] == info7a["provPath"],
        info7a["provFMExists"] is True,
        info7a["provNSDataText"] == "MOCK_BACKUP_MOBILEPROVISION_101",
        info7a["provNSStringText"] == "MOCK_BACKUP_MOBILEPROVISION_101",
        info7a["provPosixText"] == "MOCK_BACKUP_MOBILEPROVISION_101",
        info7a["provGetPath"] == info7a["provPath"],
        info7a["provRealpath"] == info7a["provPath"],
        info7a["provWriteAccessAllowed"] is False,
        info7a["execPosixPrefix"] == "BACKUP_EXEC_PAYLOAD_101",
        info7a["execGetPath"] == info7a["bundleExecutablePath"],
        "/var/containers/Bundle/Application/" in info7a["bundleExecutablePath"],
        info7a["directBackupStatBlocked"] is True,
        info7a["directBackupOpenBlocked"] is True,
        info7a["directBackupFMBlocked"] is True,
        backup_prov_7.read_bytes() == backup_prov_bytes,
        backup_exec_7.read_bytes() == backup_exec_bytes,
        info7b["safeModeActive"] is True,
        info7b["provPath"] == "",
        info7b["cfProvURLPath"] == "",
        info7b["provFMExists"] is False,
        info7b["provPosixText"] == "",
        info7b["execPosixPrefix"] != "BACKUP_EXEC_PAYLOAD_101",
        info7c["safeModeActive"] is False,
        info7c["provPath"] == "",
        info7c["provURLPath"] == "",
        info7c["cfProvURLPath"] == "",
        info7c["provFMExists"] is False,
        info7c["provPosixText"] == "",
        info7c["execPosixPrefix"] != "BACKUP_EXEC_PAYLOAD_101",
        info7d["safeModeActive"] is False,
        info7d["provPath"] == "",
        info7d["provFMExists"] is False,
        info7d["provPosixText"] == "",
        info7d["execPosixPrefix"] != "BACKUP_EXEC_PAYLOAD_101",
    ]
    results.append(ScenarioResult(
        name="7. AppBackups read-only virtualization & direct-probe hiding",
        passed=all(checks7),
        duration_sec=time.monotonic() - t6,
        details=json.dumps(
            {
                "withBackups": info7a,
                "safeMode": info7b,
                "absentBackups": info7c,
                "unmanifestedBackups": info7d,
            },
            sort_keys=True,
        ),
    ))
    if verbose:
        print("  Scenario 7 withBackups:", info7a)
        print("  Scenario 7 safeMode:", info7b)
        print("  Scenario 7 absentBackups:", info7c)

    return results


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="PlayTools headless runtime test harness.")
    parser.add_argument(
        "--playtools-framework",
        default=None,
        help="Path to PlayTools.framework (or PlayTools.xcframework).",
    )
    parser.add_argument(
        "--json",
        dest="json_path",
        default=None,
        help="Optional output path for JSON results.",
    )
    parser.add_argument("--keep-temp", action="store_true", help="Keep temporary work directory.")
    parser.add_argument("-v", "--verbose", action="store_true", help="Verbose output.")
    args = parser.parse_args(argv)

    repo_root = Path(__file__).resolve().parent.parent.parent
    playtools_fw = resolve_playtools_framework(repo_root, args.playtools_framework)
    print(f"Using PlayTools.framework: {playtools_fw}")

    work_dir = Path(tempfile.mkdtemp(prefix="playtools-harness-"))
    diag_log = Path("/tmp/PlayTools-app.makedie.harness.mockapp.log")
    results: list[ScenarioResult] = []
    start_ts = time.monotonic()

    try:
        target_bin = build_mock_app(work_dir, playtools_fw)
        results = run_scenarios(target_bin, work_dir, args.verbose)
    finally:
        if diag_log.exists():
            try:
                diag_log.unlink()
            except OSError:
                pass
        if args.keep_temp:
            print(f"Kept temporary harness dir: {work_dir}")
        else:
            shutil.rmtree(work_dir, ignore_errors=True)

    passed_count = sum(1 for r in results if r.passed)
    failed_count = len(results) - passed_count
    total_dur = round(time.monotonic() - start_ts, 3)

    print("\n=== Headless Runtime Harness Results ===")
    for r in results:
        tag = "PASS" if r.passed else "FAIL"
        print(f"[{tag}] {r.name} ({r.duration_sec:.2f}s)")
        if not r.passed or args.verbose:
            print(f"       {r.details}")
    print(f"Summary: {passed_count}/{len(results)} passed ({total_dur:.2f}s)")

    if args.json_path:
        report = {
            "playtools_framework": str(playtools_fw),
            "total": len(results),
            "passed": passed_count,
            "failed": failed_count,
            "duration_sec": total_dur,
            "results": [asdict(r) for r in results],
        }
        out_path = Path(args.json_path).expanduser()
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    return 0 if (results and failed_count == 0) else 1


if __name__ == "__main__":
    sys.exit(main())
