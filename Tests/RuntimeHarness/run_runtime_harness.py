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
import hashlib
import json
import os
import plistlib
import shutil
import struct
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
@import CoreText;
@import QuartzCore;
@import Security;
@import UIKit;
@import WebKit;
@import PlayTools;
#include <arpa/inet.h>
#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <crt_externs.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/ndr.h>
#include <mach-o/dyld.h>
#include <mach-o/fat.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <pthread.h>
#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif
#include <pwd.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/sockio.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/un.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

extern bool pt_is_registered_hidden_module(const char *name);
extern bool pt_is_registered_hidden_class(const char *name);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
extern bool _dyld_shared_cache_contains_path(const char *path) __attribute__((weak_import));
extern intptr_t pt_harness_syscall(int, ...) __asm("_syscall");
extern int pt_harness_csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize) __asm("_csops");
extern void pt_harness_dyld_get_image_versions(
    const struct mach_header *mh,
    void (^callback)(uint32_t platform, uint32_t sdk, uint32_t minos))
    __asm("_dyld_get_image_versions") __attribute__((weak_import));
#if __has_attribute(swiftcall)
typedef const void *(*pt_harness_swift_lookup_fn)(
    const char *typeNameStart,
    size_t typeNameLength,
    const void *context,
    const void *const *genericArgs) __attribute__((swiftcall));
#endif

static struct utsname g_earlyUts;
static int g_earlyUtsRC = -1;

__attribute__((constructor))
static void pt_harness_early_uname_ctor(void) {
    memset(&g_earlyUts, 0, sizeof(g_earlyUts));
    g_earlyUtsRC = uname(&g_earlyUts);
}

typedef struct {
    char expectedMachine[64];
    int failures;
} pt_uname_stress_ctx_t;

static void *pt_harness_uname_stress_worker(void *arg) {
    pt_uname_stress_ctx_t *ctx = (pt_uname_stress_ctx_t *)arg;
    for (int i = 0; i < 25; i++) {
        struct utsname u;
        memset(&u, 0, sizeof(u));
        if (uname(&u) != 0) {
            __sync_fetch_and_add(&ctx->failures, 1);
            continue;
        }
        char buf[64] = {0};
        size_t len = sizeof(buf);
        if (sysctlbyname("hw.machine", buf, &len, NULL, 0) != 0 ||
            strcmp(buf, ctx->expectedMachine) != 0 ||
            strcmp(u.machine, ctx->expectedMachine) != 0) {
            __sync_fetch_and_add(&ctx->failures, 1);
        }
    }
    return NULL;
}

static BOOL pt_harness_read_self(uint64_t addr, void *out, size_t bytes) {
    vm_size_t copied = 0;
    return (vm_read_overwrite(mach_task_self(), (vm_address_t)addr, bytes,
                              (vm_address_t)out, &copied) == KERN_SUCCESS &&
            copied == bytes);
}

static NSData *pt_harness_memory_header(const struct mach_header *p) {
    struct mach_header_64 h;
    if (p == NULL ||
        !pt_harness_read_self((uintptr_t)p, &h, sizeof(h)) ||
        h.magic != MH_MAGIC_64 ||
        h.sizeofcmds > (1U << 20)) {
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:sizeof(h) + h.sizeofcmds];
    return pt_harness_read_self((uintptr_t)p, data.mutableBytes, data.length) ? data : nil;
}

static NSData *pt_harness_disk_header(NSString *path, NSData *memoryHdr) {
    if (path.length == 0) {
        return nil;
    }
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return nil;
    }
    cpu_subtype_t wanted = CPU_SUBTYPE_ARM64_ALL;
    if (memoryHdr.length >= sizeof(struct mach_header_64)) {
        wanted = ((const struct mach_header_64 *)memoryHdr.bytes)->cpusubtype;
    }
    off_t sliceOff = -1;
    struct fat_header fh;
    if (pread(fd, &fh, sizeof(fh), 0) == (ssize_t)sizeof(fh)) {
        if (fh.magic == MH_MAGIC_64) {
            sliceOff = 0;
        } else {
            uint32_t magic = ntohl(fh.magic);
            uint32_t count = ntohl(fh.nfat_arch);
            if ((magic == FAT_MAGIC || magic == FAT_MAGIC_64) && count <= 128) {
                BOOL wide = (magic == FAT_MAGIC_64);
                size_t stride = wide ? sizeof(struct fat_arch_64) : sizeof(struct fat_arch);
                off_t fallback = -1;
                for (uint32_t i = 0; i < count; i++) {
                    union { struct fat_arch a; struct fat_arch_64 b; } entry;
                    memset(&entry, 0, sizeof(entry));
                    if (pread(fd, &entry, stride, (off_t)(sizeof(fh) + i * stride)) != (ssize_t)stride) {
                        break;
                    }
                    uint32_t cpu = ntohl(wide ? entry.b.cputype : entry.a.cputype);
                    uint32_t sub = ntohl(wide ? entry.b.cpusubtype : entry.a.cpusubtype);
                    uint64_t off = wide ? __builtin_bswap64(entry.b.offset) : ntohl(entry.a.offset);
                    if (cpu != CPU_TYPE_ARM64 || off > (uint64_t)(INT64_MAX - 2 * 1024 * 1024)) {
                        continue;
                    }
                    if ((sub & ~CPU_SUBTYPE_MASK) == ((uint32_t)wanted & ~CPU_SUBTYPE_MASK)) {
                        sliceOff = (off_t)off;
                        break;
                    }
                    if (fallback < 0) {
                        fallback = (off_t)off;
                    }
                }
                if (sliceOff < 0) {
                    sliceOff = fallback;
                }
            }
        }
    }
    NSData *res = nil;
    struct mach_header_64 h;
    if (sliceOff >= 0 &&
        pread(fd, &h, sizeof(h), sliceOff) == (ssize_t)sizeof(h) &&
        h.magic == MH_MAGIC_64 &&
        h.sizeofcmds <= (1U << 20)) {
        NSMutableData *d = [NSMutableData dataWithLength:sizeof(h) + h.sizeofcmds];
        if (pread(fd, d.mutableBytes, d.length, sliceOff) == (ssize_t)d.length) {
            res = d;
        }
    }
    close(fd);
    return res;
}

static const void *pt_harness_strip_ptr(const void *p) {
#if __has_feature(ptrauth_calls)
    return ptrauth_strip(p, ptrauth_key_function_pointer);
#else
    return p;
#endif
}

#if defined(__arm64__) || defined(__aarch64__)
__attribute__((noinline))
static int64_t pt_harness_raw_svc(int64_t sysno,
                                  uintptr_t a0,
                                  uintptr_t a1,
                                  uintptr_t a2,
                                  uintptr_t a3,
                                  uintptr_t a4,
                                  uintptr_t a5,
                                  int *outErrno) {
    register uintptr_t x0 __asm("x0") = a0;
    register uintptr_t x1 __asm("x1") = a1;
    register uintptr_t x2 __asm("x2") = a2;
    register uintptr_t x3 __asm("x3") = a3;
    register uintptr_t x4 __asm("x4") = a4;
    register uintptr_t x5 __asm("x5") = a5;
    register int64_t x16 __asm("x16") = sysno;
    uint32_t carry = 0;
    __asm__ volatile(
        "svc #0x80\n\t"
        "cset %w[c], cs"
        : "+r"(x0), "+r"(x1), "+r"(x2), "+r"(x3), "+r"(x4), "+r"(x5), "+r"(x16), [c] "=r"(carry)
        :
        : "cc", "memory");
    if (carry != 0) {
        if (outErrno != NULL) {
            *outErrno = (int)x0;
        }
        return -1;
    }
    if (outErrno != NULL) {
        *outErrno = 0;
    }
    return (int64_t)x0;
}
#endif

static NSString *pt_state_dir(void) {
    NSArray<NSURL *> *caches = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
                                                                      inDomains:NSUserDomainMask];
    NSURL *base = caches.firstObject ?: [NSURL fileURLWithPath:NSTemporaryDirectory()];
    return [[base URLByAppendingPathComponent:@"app.makedie.PlayTools" isDirectory:YES] path];
}

__attribute__((noinline))
static BOOL pt_harness_deep_file_exists(NSFileManager *fm, NSString *path) {
    SEL existsSel = @selector(fileExistsAtPath:);
    NSMethodSignature *sig1 = [fm methodSignatureForSelector:existsSel];
    NSInvocation *inv1 = [NSInvocation invocationWithMethodSignature:sig1];
    [inv1 setTarget:fm];
    [inv1 setSelector:existsSel];
    [inv1 setArgument:&path atIndex:2];
    [inv1 retainArguments];

    NSInvocation *chain = inv1;
    NSMethodSignature *invokeSig = [NSInvocation instanceMethodSignatureForSelector:@selector(invoke)];
    for (int depth = 0; depth < 4; depth++) {
        NSInvocation *wrapper = [NSInvocation invocationWithMethodSignature:invokeSig];
        [wrapper setTarget:chain];
        [wrapper setSelector:@selector(invoke)];
        [wrapper retainArguments];
        chain = wrapper;
    }
    NSArray<NSInvocation *> *arr = @[chain];
    [arr makeObjectsPerformSelector:@selector(invoke)];
    BOOL exists = NO;
    [inv1 getReturnValue:&exists];
    return exists;
}

static BOOL pt_harness_contains_desktop_font(NSArray<NSString *> *names) {
    NSSet<NSString *> *exact = [NSSet setWithObjects:@"monaco", @"geneva", @"lucida grande", @"herculanum", nil];
    for (id item in names) {
        if (![item isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *lower = [(NSString *)item lowercaseString];
        if ([exact containsObject:lower] || [lower hasPrefix:@"lucidagrande"]) {
            return YES;
        }
    }
    return NO;
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
        char sysctlMibMachine[64] = {0};
        size_t sysctlMibMachineLen = sizeof(sysctlMibMachine);
        int mibMachine[2] = { CTL_HW, HW_MACHINE };
        if (sysctl(mibMachine, 2, sysctlMibMachine, &sysctlMibMachineLen, NULL, 0) != 0) {
            sysctlMibMachine[0] = '\0';
        }
        char syscallMachine[64] = {0};
        size_t syscallMachineLen = sizeof(syscallMachine);
        if (pt_harness_syscall(274, "hw.machine", (size_t)10, syscallMachine, &syscallMachineLen, NULL, (size_t)0) != 0) {
            syscallMachine[0] = '\0';
        }
        int kqProbe = (int)pt_harness_syscall(362);
        struct timespec badKevTimeout = { 0, -1 };
        errno = 0;
        BOOL syscallWideArityOK = (kqProbe >= 0 &&
                                   pt_harness_syscall(369, kqProbe, NULL, 0, NULL, 0, 0U, &badKevTimeout) == -1 &&
                                   errno == EINVAL);
        if (kqProbe >= 0) {
            close(kqProbe);
        }
        struct stat sysAppsSyscallSt;
        errno = 0;
        BOOL syscallStatHidSysApps = (pt_harness_syscall(338, "/System/Applications", &sysAppsSyscallSt) == -1 &&
                                      errno == ENOENT);
        struct stat sysAppsSt, usersSt;
        errno = 0;
        BOOL fsHidMacRoots = (stat("/System/Applications", &sysAppsSt) == -1 && errno == ENOENT &&
                              stat("/Users", &usersSt) == -1 && errno == ENOENT);
        uint32_t csopsTeamShortHdr[2] = {0x11111111U, 0x22222222U};
        errno = 0;
        BOOL csopsTeamShortERange = (pt_harness_csops(0, 14U, csopsTeamShortHdr, sizeof(csopsTeamShortHdr)) == -1 &&
                                     errno == ERANGE &&
                                     ntohl(csopsTeamShortHdr[0]) == 0U &&
                                     ntohl(csopsTeamShortHdr[1]) == 19U);
        uint8_t csopsTeamBuf[64] = {0};
        uint32_t teamMagic = 0, teamLen = 0;
        BOOL csopsTeamBlobOK = NO;
        if (pt_harness_csops(0, 14U, csopsTeamBuf, sizeof(csopsTeamBuf)) == 0) {
            memcpy(&teamMagic, csopsTeamBuf, 4);
            memcpy(&teamLen, csopsTeamBuf + 4, 4);
            const char *teamStr = (const char *)(csopsTeamBuf + 8);
            csopsTeamBlobOK = (ntohl(teamMagic) == 0U &&
                               ntohl(teamLen) == 19U &&
                               strnlen(teamStr, 16) == 10U);
        }
        uint8_t csopsIdBuf[128] = {0};
        uint32_t idMagic = 0, idLen = 0;
        BOOL csopsIdentityBlobOK = NO;
        if (pt_harness_csops(0, 11U, csopsIdBuf, sizeof(csopsIdBuf)) == 0) {
            memcpy(&idMagic, csopsIdBuf, 4);
            memcpy(&idLen, csopsIdBuf + 4, 4);
            const char *idStr = (const char *)(csopsIdBuf + 8);
            size_t expIdLen = strlen("app.makedie.harness.mockapp") + 1U;
            csopsIdentityBlobOK = (ntohl(idMagic) == 0U &&
                                   ntohl(idLen) == (uint32_t)(8U + expIdLen) &&
                                   strcmp(idStr, "app.makedie.harness.mockapp") == 0);
        }
        uint32_t csopsEntHdr[2] = {0, 0};
        errno = 0;
        BOOL csopsEntBlobHdrOK = (pt_harness_csops(0, 7U, csopsEntHdr, sizeof(csopsEntHdr)) == -1 &&
                                  errno == ERANGE &&
                                  ntohl(csopsEntHdr[0]) == 0xfade7171U &&
                                  ntohl(csopsEntHdr[1]) > 8U);
        BOOL csopsStringAndBlobOK = (csopsTeamShortERange && csopsTeamBlobOK && csopsIdentityBlobOK && csopsEntBlobHdrOK);
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
        CMAccelerometerData *cmSampleCopy = [cmSample copy];
        NSString *cmSampleDesc = [cmSample description];
        [motionMgr startDeviceMotionUpdates];
        CMDeviceMotion *cmDM = motionMgr.deviceMotion;
        CMAttitude *cmAttCopy = [cmDM.attitude copy];
        NSString *cmDMDesc = [cmDM description];
        [motionMgr startMagnetometerUpdates];
        CMMagnetometerData *cmMag = motionMgr.magnetometerData;
        NSTimeInterval magTs1 = cmMag.timestamp;
        CMMagneticField magField1 = cmMag.magneticField;
        usleep(3000);
        NSTimeInterval magTs2 = cmMag.timestamp;
        CMMagneticField magField2 = cmMag.magneticField;
        BOOL cmMagImmutable = (cmMag != nil &&
                               magTs2 == magTs1 &&
                               magField1.x == magField2.x &&
                               magField1.y == magField2.y &&
                               magField1.z == magField2.z &&
                               cmDM != nil &&
                               fabs(magTs1 - cmDM.timestamp) < 60.0);
        BOOL cmDMMagneticCalibrated = (cmDM != nil &&
                                       cmDM.magneticField.accuracy != CMMagneticFieldCalibrationAccuracyUncalibrated);
        BOOL cmSampleValid = (cmSample != nil &&
                              [cmSample isKindOfClass:[CMAccelerometerData class]] &&
                              cmSample.acceleration.z < -0.9 &&
                              cmSampleCopy == cmSample &&
                              cmSampleDesc.length > 0 &&
                              cmDM != nil &&
                              [cmDM isKindOfClass:[CMDeviceMotion class]] &&
                              cmAttCopy != nil &&
                              cmDMDesc.length > 0);
        [motionMgr stopMagnetometerUpdates];
        [motionMgr stopDeviceMotionUpdates];
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
        BOOL uiColorWellInClassList = NO;
        int totalClsCount = objc_getClassList(NULL, 0);
        if (totalClsCount > 0 && totalClsCount < 100000) {
            Class *clsBuf = (Class *)calloc((size_t)totalClsCount + 16U, sizeof(Class));
            if (clsBuf != NULL) {
                int gotCls = objc_getClassList(clsBuf, totalClsCount + 16);
                for (int ci = 0; ci < gotCls; ci++) {
                    const char *cname = (clsBuf[ci] != Nil) ? class_getName(clsBuf[ci]) : NULL;
                    if (cname != NULL && strcmp(cname, "UIColorWell") == 0) {
                        uiColorWellInClassList = YES;
                        break;
                    }
                }
                free(clsBuf);
            }
        }
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
        Method isiOSOnMacM = class_getInstanceMethod([NSProcessInfo class], @selector(isiOSAppOnMac));
        IMP isiOSOnMacIMP = (isiOSOnMacM != NULL) ? method_getImplementation(isiOSOnMacM) : NULL;
        Dl_info impDlInfo;
        memset(&impDlInfo, 0, sizeof(impDlInfo));
        if (isiOSOnMacIMP != NULL &&
            dladdr((const void *)isiOSOnMacIMP, &impDlInfo) != 0 &&
            impDlInfo.dli_fname != NULL &&
            strstr(impDlInfo.dli_fname, "PlayTools") != NULL) {
            leakedShadowResponds = YES;
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
        vm_address_t mh0ProbeAddr = (vm_address_t)mh0;
        vm_size_t mh0ProbeSz = 0;
        vm_region_basic_info_data_64_t mh0ProbeInfo;
        mach_msg_type_number_t mh0ProbeCnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t mh0ProbeObj = MACH_PORT_NULL;
        BOOL mh0VMRegionOK = (mh0 != NULL &&
                              vm_region_64(mach_task_self(), &mh0ProbeAddr, &mh0ProbeSz,
                                           VM_REGION_BASIC_INFO_64, (vm_region_info_t)&mh0ProbeInfo,
                                           &mh0ProbeCnt, &mh0ProbeObj) == KERN_SUCCESS);
        if (MACH_PORT_VALID(mh0ProbeObj)) {
            mach_port_deallocate(mach_task_self(), mh0ProbeObj);
        }
        uintptr_t ptSymAddr = (uintptr_t)&pt_is_registered_hidden_module;
        vm_address_t ptProbeAddr = (vm_address_t)ptSymAddr;
        vm_size_t ptProbeSz = 0;
        vm_region_basic_info_data_64_t ptProbeInfo;
        mach_msg_type_number_t ptProbeCnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t ptProbeObj = MACH_PORT_NULL;
        kern_return_t ptProbeKr = vm_region_64(mach_task_self(), &ptProbeAddr, &ptProbeSz,
                                               VM_REGION_BASIC_INFO_64, (vm_region_info_t)&ptProbeInfo,
                                               &ptProbeCnt, &ptProbeObj);
        if (MACH_PORT_VALID(ptProbeObj)) {
            mach_port_deallocate(mach_task_self(), ptProbeObj);
        }
        BOOL vmRegionHidPlayTools = (mh0VMRegionOK &&
                                     !(ptProbeKr == KERN_SUCCESS &&
                                       ptProbeAddr <= ptSymAddr &&
                                       ptSymAddr < ptProbeAddr + ptProbeSz));
        unsigned long mh0TextSize = 0;
        uint8_t *mh0TextPtr = (mh0 != NULL) ? getsectiondata(mh0, "__TEXT", "__text", &mh0TextSize) : NULL;
        BOOL mh0SectionLookupOK = (mh0TextPtr != NULL && mh0TextSize > 0);

        // P1: early constructor uname + 16-thread concurrent uname stress
        BOOL earlyUnameOK = (g_earlyUtsRC == 0 &&
                             (strncmp(g_earlyUts.machine, "iPad", 4) == 0 ||
                              strncmp(g_earlyUts.machine, "iPhone", 6) == 0));
        BOOL concurrentUnameOK = NO;
        if (sysctlMachine[0] != '\0') {
            pt_uname_stress_ctx_t sctx;
            memset(&sctx, 0, sizeof(sctx));
            strlcpy(sctx.expectedMachine, sysctlMachine, sizeof(sctx.expectedMachine));
            pthread_t thrs[16];
            for (int ti = 0; ti < 16; ti++) {
                if (pthread_create(&thrs[ti], NULL, pt_harness_uname_stress_worker, &sctx) != 0) {
                    sctx.failures++;
                }
            }
            for (int ti = 0; ti < 16; ti++) {
                pthread_join(thrs[ti], NULL);
            }
            concurrentUnameOK = (sctx.failures == 0);
        }

        // P1: KERN_PROCARGS2 env boundary check (must not leak apple[] auxiliary entries)
        BOOL procArgs2LeakedApple = NO;
        BOOL procArgs2EnvClean = NO;
        {
            int mib[3] = { CTL_KERN, KERN_PROCARGS2, getpid() };
            size_t p2Sz = 64U * 1024U;
            NSMutableData *p2Data = [NSMutableData dataWithLength:p2Sz];
            if (sysctl(mib, 3, p2Data.mutableBytes, &p2Sz, NULL, 0) == 0 && p2Sz >= sizeof(int)) {
                int p2Argc = 0;
                memcpy(&p2Argc, p2Data.bytes, sizeof(int));
                const char *cur = (const char *)p2Data.bytes + sizeof(int);
                const char *end = (const char *)p2Data.bytes + p2Sz;
                const char *z = memchr(cur, 0, (size_t)(end - cur));
                if (z != NULL && p2Argc >= 0 && p2Argc <= 1024) {
                    cur = z + 1;
                    while (cur < end && *cur == '\0') {
                        cur++;
                    }
                    BOOL argsParsed = YES;
                    for (int ai = 0; ai < p2Argc; ai++) {
                        z = (cur < end) ? memchr(cur, 0, (size_t)(end - cur)) : NULL;
                        if (z == NULL) {
                            argsParsed = NO;
                            break;
                        }
                        cur = z + 1;
                    }
                    if (argsParsed) {
                        NSSet *appleKeys = [NSSet setWithArray:@[
                            @"APP_SANDBOX_CONTAINER_ID", @"dyld_file", @"executable_boothash",
                            @"executable_cdhash", @"executable_file", @"main_stack",
                            @"ptr_munge", @"security_config", @"th_port"
                        ]];
                        NSMutableDictionary *p2Env = [NSMutableDictionary dictionary];
                        while (cur < end && *cur != '\0') {
                            z = memchr(cur, 0, (size_t)(end - cur));
                            if (z == NULL) {
                                break;
                            }
                            NSString *entry = [NSString stringWithUTF8String:cur];
                            NSRange eq = [entry rangeOfString:@"="];
                            if (eq.location != NSNotFound && eq.location > 0) {
                                NSString *k = [entry substringToIndex:eq.location];
                                if ([appleKeys containsObject:k]) {
                                    procArgs2LeakedApple = YES;
                                }
                                p2Env[k] = [entry substringFromIndex:eq.location + 1];
                            }
                            cur = z + 1;
                        }
                        NSDictionary *nsEnv = [NSProcessInfo processInfo].environment;
                        procArgs2EnvClean = (!procArgs2LeakedApple &&
                                             p2Env.count > 0 &&
                                             [p2Env isEqualToDictionary:nsEnv]);
                    }
                }
            }
        }

        // P1: fs.at_systemversion & /System/Volumes/Data hiding & statfs & getpwuid
        BOOL atSystemVersionInodeMatch = NO;
        NSString *atSystemVersionProductName = @"";
        {
            int svDir = open("/System/Library/CoreServices", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
            if (svDir >= 0) {
                struct stat stByName = {0}, stByFd = {0};
                int fstatErr = fstatat(svDir, "SystemVersion.plist", &stByName, 0);
                int svFd = openat(svDir, "SystemVersion.plist", O_RDONLY | O_NONBLOCK | O_CLOEXEC);
                if (svFd >= 0) {
                    if (fstatErr == 0 && fstat(svFd, &stByFd) == 0 &&
                        stByName.st_dev == stByFd.st_dev && stByName.st_ino == stByFd.st_ino &&
                        S_ISREG(stByFd.st_mode) && stByFd.st_size > 0 && stByFd.st_size <= 65536) {
                        atSystemVersionInodeMatch = YES;
                    }
                    NSMutableData *plistBytes = [NSMutableData dataWithLength:(NSUInteger)stByFd.st_size];
                    ssize_t nr = read(svFd, plistBytes.mutableBytes, plistBytes.length);
                    if (nr == (ssize_t)plistBytes.length) {
                        id plist = [NSPropertyListSerialization propertyListWithData:plistBytes
                                                                             options:NSPropertyListImmutable
                                                                              format:NULL
                                                                               error:NULL];
                        if ([plist isKindOfClass:[NSDictionary class]]) {
                            id pn = plist[@"ProductName"];
                            if ([pn isKindOfClass:[NSString class]]) {
                                atSystemVersionProductName = pn;
                            }
                        }
                    }
                    close(svFd);
                }
                close(svDir);
            }
        }
        struct stat svVolSt = {0}, svDataSt = {0};
        BOOL hidSystemVolumes = (stat("/System/Volumes", &svVolSt) == -1 && errno == ENOENT &&
                                 stat("/System/Volumes/Data", &svDataSt) == -1 && errno == ENOENT &&
                                 access("/System/Volumes/Data", F_OK) == -1 && errno == ENOENT);
        struct statfs mntInfo = {0};
        BOOL homeMountClean = (statfs(NSHomeDirectory().fileSystemRepresentation, &mntInfo) == 0 &&
                               strncmp(mntInfo.f_mntonname, "/System/Volumes/", 16) != 0 &&
                               strncmp(mntInfo.f_mntonname, "/Users/", 7) != 0);
        struct passwd pwdBuf = {0};
        struct passwd *pwdRes = NULL;
        char pwdStrBuf[1024] = {0};
        struct passwd *pwdDirect = getpwuid(getuid());
        BOOL passwdClean = (getpwuid_r(getuid(), &pwdBuf, pwdStrBuf, sizeof(pwdStrBuf), &pwdRes) == 0 &&
                            pwdRes != NULL && pwdRes->pw_dir != NULL &&
                            strstr(pwdRes->pw_dir, "/Users/") == NULL &&
                            pwdDirect != NULL && pwdDirect->pw_dir != NULL &&
                            strstr(pwdDirect->pw_dir, "/Users/") == NULL);

        // P1: vm_read_overwrite / mach_vm_read_overwrite + vm.hidden_macho + dladdr consistency
        uint32_t machVmMh0Platform = 0;
        if (mh0 != NULL) {
            struct mach_header_64 mvh;
            mach_vm_size_t mvc = 0;
            if (mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)mh0, sizeof(mvh),
                                       (mach_vm_address_t)(uintptr_t)&mvh, &mvc) == KERN_SUCCESS &&
                mvc == sizeof(mvh) && mvh.magic == MH_MAGIC_64 && mvh.sizeofcmds <= (1U << 20)) {
                NSMutableData *mvd = [NSMutableData dataWithLength:sizeof(mvh) + mvh.sizeofcmds];
                if (mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)mh0, mvd.length,
                                           (mach_vm_address_t)(uintptr_t)mvd.mutableBytes, &mvc) == KERN_SUCCESS &&
                    mvc == mvd.length) {
                    const uint8_t *p = (const uint8_t *)mvd.bytes + sizeof(mvh);
                    size_t rem = mvh.sizeofcmds;
                    for (uint32_t i = 0; i < mvh.ncmds && rem >= sizeof(struct load_command); i++) {
                        struct load_command lc;
                        memcpy(&lc, p, sizeof(lc));
                        if (lc.cmdsize < sizeof(lc) || lc.cmdsize > rem) {
                            break;
                        }
                        if (lc.cmd == LC_BUILD_VERSION && lc.cmdsize >= sizeof(struct build_version_command)) {
                            struct build_version_command bv;
                            memcpy(&bv, p, sizeof(bv));
                            machVmMh0Platform = bv.platform;
                            break;
                        }
                        p += lc.cmdsize;
                        rem -= lc.cmdsize;
                    }
                }
            }
        }
        NSUInteger vmNonIosImages = 0;
        NSUInteger vmDirtyImports = 0;
        NSUInteger vmDladdrDiffs = 0;
        NSUInteger vmParsedImages = 0;
        NSMutableSet<NSNumber *> *registeredImgs = [NSMutableSet set];
        for (uint32_t i = 0; i < imgCount; i++) {
            const struct mach_header *ih = _dyld_get_image_header(i);
            const char *inm = _dyld_get_image_name(i);
            if (ih == NULL) {
                continue;
            }
            [registeredImgs addObject:@((uintptr_t)ih)];
            Dl_info dli = {0};
            if (dladdr(ih, &dli) == 0 || dli.dli_fbase != ih) {
                vmDladdrDiffs++;
            }
            NSData *hdrData = pt_harness_memory_header(ih);
            if (hdrData.length >= sizeof(struct mach_header_64)) {
                const struct mach_header_64 *h = (const struct mach_header_64 *)hdrData.bytes;
                if (h->sizeofcmds == hdrData.length - sizeof(*h)) {
                    vmParsedImages++;
                    const uint8_t *p = (const uint8_t *)hdrData.bytes + sizeof(*h);
                    size_t rem = h->sizeofcmds;
                    BOOL hasMacPlat = NO, hasIosPlat = NO;
                    for (uint32_t ci = 0; ci < h->ncmds && rem >= sizeof(struct load_command); ci++) {
                        struct load_command lc;
                        memcpy(&lc, p, sizeof(lc));
                        if (lc.cmdsize < sizeof(lc) || lc.cmdsize > rem || (lc.cmdsize % 8U) != 0) {
                            break;
                        }
                        if (lc.cmd == LC_BUILD_VERSION && lc.cmdsize >= sizeof(struct build_version_command)) {
                            struct build_version_command bv;
                            memcpy(&bv, p, sizeof(bv));
                            if (bv.platform == 6U || bv.platform == 1U || bv.platform == 7U) {
                                hasMacPlat = YES;
                            }
                            if (bv.platform == 2U) {
                                hasIosPlat = YES;
                            }
                        } else if ((lc.cmd == LC_LOAD_DYLIB || lc.cmd == LC_LOAD_WEAK_DYLIB ||
                                    lc.cmd == LC_REEXPORT_DYLIB || lc.cmd == LC_LOAD_UPWARD_DYLIB) &&
                                   lc.cmdsize >= sizeof(struct dylib_command)) {
                            struct dylib_command dc;
                            memcpy(&dc, p, sizeof(dc));
                            uint32_t off = dc.dylib.name.offset;
                            if (off >= sizeof(dc) && off < lc.cmdsize && memchr(p + off, 0, lc.cmdsize - off) != NULL) {
                                const char *lib = (const char *)p + off;
                                if (strcasestr(lib, "PlayTools") != NULL ||
                                    strcasestr(lib, "AKInterface") != NULL ||
                                    strcasestr(lib, "UserPlugins") != NULL ||
                                    strstr(lib, "AppKit.framework") != NULL ||
                                    strstr(lib, "UIKitMacHelper.framework") != NULL ||
                                    strstr(lib, "/System/iOSSupport/") != NULL) {
                                    vmDirtyImports++;
                                }
                            }
                        }
                        p += lc.cmdsize;
                        rem -= lc.cmdsize;
                    }
                    if (hasMacPlat && !hasIosPlat) {
                        vmNonIosImages++;
                    } else if (hasMacPlat) {
                        vmNonIosImages++;
                    }
                }
            }
            (void)inm;
        }
        NSUInteger vmHiddenMachOCount = 0;
        {
            vm_address_t va = 0;
            for (NSUInteger r = 0; r < 131072; r++) {
                vm_size_t vs = 0;
                vm_region_basic_info_data_64_t ri = {0};
                mach_msg_type_number_t rc = VM_REGION_BASIC_INFO_COUNT_64;
                mach_port_t obj = MACH_PORT_NULL;
                kern_return_t vkr = vm_region_64(mach_task_self(), &va, &vs, VM_REGION_BASIC_INFO_64,
                                                 (vm_region_info_t)&ri, &rc, &obj);
                if (MACH_PORT_VALID(obj)) {
                    mach_port_deallocate(mach_task_self(), obj);
                }
                if (vkr != KERN_SUCCESS || vs == 0 || va > UINTPTR_MAX - vs) {
                    break;
                }
                if ((ri.protection & (VM_PROT_READ | VM_PROT_EXECUTE)) == (VM_PROT_READ | VM_PROT_EXECUTE) &&
                    vs >= sizeof(struct mach_header_64) &&
                    ![registeredImgs containsObject:@((uintptr_t)va)]) {
                    uint32_t magic = 0;
                    if (pt_harness_read_self(va, &magic, sizeof(magic)) && magic == MH_MAGIC_64 &&
                        pt_harness_memory_header((const struct mach_header *)va) != nil) {
                        vmHiddenMachOCount++;
                    }
                }
                va += vs;
            }
        }
        NSData *mainMemHdr = pt_harness_memory_header((const struct mach_header *)mh0);
        NSData *mainDiskHdr = pt_harness_disk_header(bundleExecPath, mainMemHdr);
        BOOL diskHeaderMatchesMemory = (mainMemHdr != nil && mainDiskHdr != nil &&
                                        [mainMemHdr isEqualToData:mainDiskHdr]);
        uint32_t diskHeaderPlatform = 0;
        if (mainDiskHdr.length >= sizeof(struct mach_header_64)) {
            const struct mach_header_64 *dh = (const struct mach_header_64 *)mainDiskHdr.bytes;
            const uint8_t *dp = (const uint8_t *)mainDiskHdr.bytes + sizeof(*dh);
            size_t drem = (dh->sizeofcmds <= mainDiskHdr.length - sizeof(*dh)) ? dh->sizeofcmds : 0;
            for (uint32_t ci = 0; ci < dh->ncmds && drem >= sizeof(struct load_command); ci++) {
                struct load_command lc;
                memcpy(&lc, dp, sizeof(lc));
                if (lc.cmdsize < sizeof(lc) || lc.cmdsize > drem) {
                    break;
                }
                if (lc.cmd == LC_BUILD_VERSION && lc.cmdsize >= sizeof(struct build_version_command)) {
                    struct build_version_command bv;
                    memcpy(&bv, dp, sizeof(bv));
                    diskHeaderPlatform = bv.platform;
                    break;
                }
                dp += lc.cmdsize;
                drem -= lc.cmdsize;
            }
        }

        // P1: dlsym(RTLD_DEFAULT, ...) + dladdr owner verification
        BOOL dlsymCOwnersClean = YES;
        {
            const void *symPtrs[4] = {
                pt_harness_strip_ptr(dlsym(RTLD_DEFAULT, "sysctlbyname")),
                pt_harness_strip_ptr(dlsym(RTLD_DEFAULT, "stat")),
                pt_harness_strip_ptr(dlsym(RTLD_DEFAULT, "csops")),
                pt_harness_strip_ptr(dlsym(RTLD_DEFAULT, "uname"))
            };
            for (int si = 0; si < 4; si++) {
                Dl_info sdli = {0};
                if (symPtrs[si] == NULL || dladdr(symPtrs[si], &sdli) == 0 ||
                    sdli.dli_fname == NULL ||
                    strncmp(sdli.dli_fname, "/usr/lib/system/libsystem_", 26) != 0) {
                    dlsymCOwnersClean = NO;
                    break;
                }
            }
            int (*dynSysctlByName)(const char *, void *, size_t *, void *, size_t) =
                (int (*)(const char *, void *, size_t *, void *, size_t))dlsym(RTLD_DEFAULT, "sysctlbyname");
            int (*dynStat)(const char *, struct stat *) =
                (int (*)(const char *, struct stat *))dlsym(RTLD_DEFAULT, "stat");
            char dynMach[64] = {0};
            size_t dynMachLen = sizeof(dynMach);
            struct stat dynSt = {0};
            if (dynSysctlByName == NULL || dynStat == NULL ||
                dynSysctlByName("hw.machine", dynMach, &dynMachLen, NULL, 0) != 0 ||
                strcmp(dynMach, sysctlMachine) != 0 ||
                !(dynStat("/Users", &dynSt) == -1 && errno == ENOENT)) {
                dlsymCOwnersClean = NO;
            }
        }

        // P1: net.interfaces getifaddrs/freeifaddrs filtering
        BOOL ifaddrsClean = NO;
        NSUInteger ifaddrsCount = 0;
        {
            struct ifaddrs *ifap = NULL;
            if (getifaddrs(&ifap) == 0) {
                BOOL leakedVMIf = NO;
                for (struct ifaddrs *e = ifap; e != NULL; e = e->ifa_next) {
                    ifaddrsCount++;
                    if (e->ifa_name != NULL &&
                        (strncmp(e->ifa_name, "vmenet", 6) == 0 ||
                         strncmp(e->ifa_name, "vmnet", 5) == 0 ||
                         strncmp(e->ifa_name, "bridge", 6) == 0)) {
                        leakedVMIf = YES;
                    }
                }
                freeifaddrs(ifap);
                ifaddrsClean = (ifaddrsCount > 0 && !leakedVMIf);
            }
        }

        // P2: Optional inline ARM64 svc #0x80 interception tests
        NSString *inlineSvcMachine = @"";
        BOOL inlineSvcStatHidSysApps = NO;
        BOOL inlineSvcSysVerIsIOS = NO;
        BOOL inlineSvcCodeReadRestored = NO;
        const char *testInlineSvcEnv = getenv("HARNESS_TEST_INLINE_SVC");
        if (testInlineSvcEnv != NULL && strcmp(testInlineSvcEnv, "1") == 0) {
#if defined(__arm64__) || defined(__aarch64__)
            char svcMach[64] = {0};
            size_t svcMachLen = sizeof(svcMach);
            int svcErr = 0;
            if (pt_harness_raw_svc(274 /* SYS_sysctlbyname */,
                                   (uintptr_t)"hw.machine",
                                   10,
                                   (uintptr_t)svcMach,
                                   (uintptr_t)&svcMachLen,
                                   0,
                                   0,
                                   &svcErr) == 0) {
                inlineSvcMachine = [NSString stringWithUTF8String:svcMach] ?: @"";
            }

            struct stat svcSt = {0};
            svcErr = 0;
            int64_t stRc = pt_harness_raw_svc(338 /* SYS_stat64 */,
                                              (uintptr_t)"/System/Applications",
                                              (uintptr_t)&svcSt,
                                              0, 0, 0, 0,
                                              &svcErr);
            inlineSvcStatHidSysApps = (stRc == -1 && svcErr == ENOENT);

            svcErr = 0;
            int64_t svFd = pt_harness_raw_svc(398 /* SYS_open_nocancel */,
                                              (uintptr_t)"/System/Library/CoreServices/SystemVersion.plist",
                                              O_RDONLY,
                                              0, 0, 0, 0,
                                              &svcErr);
            if (svFd >= 0) {
                NSMutableData *plistBytes = [NSMutableData data];
                uint8_t chunk[2048];
                ssize_t nr = 0;
                while ((nr = read((int)svFd, chunk, sizeof(chunk))) > 0) {
                    [plistBytes appendBytes:chunk length:(NSUInteger)nr];
                }
                close((int)svFd);
                id plistObj = [NSPropertyListSerialization propertyListWithData:plistBytes
                                                                        options:NSPropertyListImmutable
                                                                         format:NULL
                                                                          error:nil];
                if ([plistObj isKindOfClass:[NSDictionary class]]) {
                    NSString *prodName = ((NSDictionary *)plistObj)[@"ProductName"];
                    inlineSvcSysVerIsIOS = [prodName isEqualToString:@"iPhone OS"];
                }
            }

            uint8_t codeBuf[256] = {0};
            vm_size_t codeCopied = 0;
            uintptr_t fnAddr = (uintptr_t)pt_harness_strip_ptr((const void *)&pt_harness_raw_svc);
            if (vm_read_overwrite(mach_task_self(),
                                  (vm_address_t)fnAddr,
                                  sizeof(codeBuf),
                                  (vm_address_t)codeBuf,
                                  &codeCopied) == KERN_SUCCESS &&
                codeCopied >= 16) {
                uint32_t expectedSvc = (0xD4000001U | (0x80U << 5));
                uint32_t expectedBrk = (0xD4200000U | (0x5074U << 5));
                BOOL sawSvc = NO;
                BOOL sawBrk = NO;
                for (vm_size_t off = 0; off + 4 <= codeCopied; off += 4) {
                    uint32_t w = 0;
                    memcpy(&w, codeBuf + off, sizeof(w));
                    if (w == expectedSvc) {
                        sawSvc = YES;
                    }
                    if (w == expectedBrk) {
                        sawBrk = YES;
                    }
                }
                inlineSvcCodeReadRestored = (sawSvc && !sawBrk);
            }
#endif
        }

        // Scenario 10: 99-check anti-detection & contract hardening checks
        BOOL s10StrictBypassEarlyOK = NO;
        BOOL s10DeepUnwindHidMacPaths = NO;
        BOOL s10PlayChainOpaqueRefOK = NO;
        BOOL s10PlayChainForeignGroupBlocked = NO;
        BOOL s10PlayChainSEExportBlocked = NO;
        BOOL s10WebKitVFileHidden = NO;
        BOOL s10DesktopFontsHidden = NO;
        BOOL s10DscVersionedHidden = NO;
        BOOL s10FinderHidden = NO;
        BOOL s10ProcArgsHidSandboxId = NO;
        BOOL s10SelfPidpathVirtual = NO;
        NSString *s10SelfPidpathValue = @"";
        BOOL s10CoreMotionGenuineAndEpochOK = NO;
        BOOL s10AltimeterContractOK = NO;
        BOOL s10UnixRelativeSocketOK = NO;
        BOOL s10ExceptionPortsHidden = NO;
        BOOL s10SysctlCacheTopologyOK = NO;
        const char *testS10Env = getenv("HARNESS_TEST_SCENARIO10");
        if (testS10Env != NULL && strcmp(testS10Env, "1") == 0) {
            // 1. Strict Mode keeps early bypass active even when stored bypass=false
            s10StrictBypassEarlyOK = ([[PlaySettings shared] strictEmulationMode] &&
                                      !safeModeActive &&
                                      vmNonIosImages == 0 &&
                                      vmHiddenMachOCount == 0);

            // 2. A02: Deep NSInvocation/Foundation wrapper chain (14+ system frames) hides Safari/Finder
            s10DeepUnwindHidMacPaths = (!pt_harness_deep_file_exists(fm, @"/Applications/Safari.app") &&
                                        !pt_harness_deep_file_exists(fm, @"/System/Library/CoreServices/Finder.app"));

            // 3. A03: PlayChain opaque 20-byte ref, foreign access group -34018, SE export block
            {
                NSString *svc = [NSString stringWithFormat:@"sc10.svc.%d", getpid()];
                NSString *acct = @"sc10-acct";
                NSDictionary *addQ = @{
                    (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                    (__bridge id)kSecAttrService: svc,
                    (__bridge id)kSecAttrAccount: acct,
                    (__bridge id)kSecValueData: [@"sc10-secret" dataUsingEncoding:NSUTF8StringEncoding],
                    (__bridge id)kSecReturnPersistentRef: @YES,
                };
                CFTypeRef prefObj = NULL;
                OSStatus addSt = SecItemAdd((__bridge CFDictionaryRef)addQ, &prefObj);
                if (addSt == errSecSuccess && prefObj != NULL) {
                    if (CFGetTypeID(prefObj) == CFDataGetTypeID()) {
                        NSData *prefData = (__bridge NSData *)prefObj;
                        const uint8_t *b = (const uint8_t *)prefData.bytes;
                        if (prefData.length == 20 && b[0] >= 0x80 && b[1] >= 0x80 && b[2] >= 0x80 &&
                            memcmp(b, "PCPR1:", 6) != 0) {
                            s10PlayChainOpaqueRefOK = YES;
                        }
                    }
                    CFRelease(prefObj);
                }
                SecItemDelete((__bridge CFDictionaryRef)@{
                    (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                    (__bridge id)kSecAttrService: svc,
                    (__bridge id)kSecAttrAccount: acct,
                });

                NSDictionary *foreignQ = @{
                    (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                    (__bridge id)kSecAttrService: [svc stringByAppendingString:@".foreign"],
                    (__bridge id)kSecAttrAccount: acct,
                    (__bridge id)kSecAttrAccessGroup: @"ZZZZZZZZZZ.com.foreign.unauthorized",
                    (__bridge id)kSecValueData: [@"x" dataUsingEncoding:NSUTF8StringEncoding],
                };
                CFTypeRef foreignRef = NULL;
                OSStatus foreignSt = SecItemAdd((__bridge CFDictionaryRef)foreignQ, &foreignRef);
                if (foreignRef != NULL) {
                    CFRelease(foreignRef);
                }
                s10PlayChainForeignGroupBlocked = (foreignSt == errSecMissingEntitlement);

                NSDictionary *seParams = @{
                    (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
                    (__bridge id)kSecAttrKeySizeInBits: @256,
                    (__bridge id)kSecAttrTokenID: (__bridge id)kSecAttrTokenIDSecureEnclave,
                    (__bridge id)kSecPrivateKeyAttrs: @{
                        (__bridge id)kSecAttrIsPermanent: @NO,
                    },
                };
                CFErrorRef keyErr = NULL;
                SecKeyRef seKey = SecKeyCreateRandomKey((__bridge CFDictionaryRef)seParams, &keyErr);
                if (keyErr != NULL) {
                    CFRelease(keyErr);
                    keyErr = NULL;
                }
                if (seKey != NULL) {
                    CFErrorRef expErr = NULL;
                    CFDataRef extData = SecKeyCopyExternalRepresentation(seKey, &expErr);
                    s10PlayChainSEExportBlocked = (extData == NULL && expErr != NULL);
                    if (extData != NULL) {
                        CFRelease(extData);
                    }
                    if (expErr != NULL) {
                        CFRelease(expErr);
                    }
                    CFRelease(seKey);
                }
            }

            // 4. A04: WebKit internal pt-vfile URL scheme handler hidden from app callers
            {
                WKWebViewConfiguration *wkCfg = [[WKWebViewConfiguration alloc] init];
                s10WebKitVFileHidden = ([wkCfg urlSchemeHandlerForURLScheme:@"pt-vfile"] == nil &&
                                        [wkCfg urlSchemeHandlerForURLScheme:@"PT-VFILE"] == nil);
            }

            // 5. A14: macOS desktop fonts hidden from UIKit and CoreText
            {
                NSArray<NSString *> *uiFamilies = [UIFont familyNames];
                NSArray<NSString *> *monacoFaces = [UIFont fontNamesForFamilyName:@"Monaco"];
                CFArrayRef ctFamiliesRef = CTFontManagerCopyAvailableFontFamilyNames();
                NSArray<NSString *> *ctFamilies = ctFamiliesRef ? (__bridge NSArray<NSString *> *)ctFamiliesRef : @[];
                s10DesktopFontsHidden = (!pt_harness_contains_desktop_font(uiFamilies) &&
                                         monacoFaces.count == 0 &&
                                         !pt_harness_contains_desktop_font(ctFamilies));
                if (ctFamiliesRef != NULL) {
                    CFRelease(ctFamiliesRef);
                }
            }

            // 6. A15: DSC rejects .framework/Versions/ and Finder.app returns ENOENT
            {
                bool dscVer = (_dyld_shared_cache_contains_path != NULL)
                    ? _dyld_shared_cache_contains_path("/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation")
                    : false;
                struct stat fSt = {0};
                errno = 0;
                int fRc = stat("/System/Library/CoreServices/Finder.app", &fSt);
                s10DscVersionedHidden = (!dscVer);
                s10FinderHidden = (fRc != 0 && errno == ENOENT);
            }

            // 7. proc.procargs: APP_SANDBOX_CONTAINER_ID stripped from getenv and KERN_PROCARGS2
            {
                BOOL noEnv = (getenv("APP_SANDBOX_CONTAINER_ID") == NULL);
                BOOL noRawP2 = NO;
                int mib[3] = { CTL_KERN, KERN_PROCARGS2, getpid() };
                size_t p2Sz = 64U * 1024U;
                NSMutableData *p2Buf = [NSMutableData dataWithLength:p2Sz];
                if (sysctl(mib, 3, p2Buf.mutableBytes, &p2Sz, NULL, 0) == 0 && p2Sz > sizeof(int)) {
                    const char *needle = "APP_SANDBOX_CONTAINER_ID=";
                    noRawP2 = (memmem(p2Buf.bytes, p2Sz, needle, strlen(needle)) == NULL);
                }
                s10ProcArgsHidSandboxId = (noEnv && noRawP2);
            }

            // 8. proc.real_pidpath: direct + dlsym proc_pidpath resolve to virtual iOS container path
            NSString *s10SelfPidpath = @"";
            {
                char selfPath[PATH_MAX] = {0};
                typedef int (*PidPathFn)(int, void *, uint32_t);
                PidPathFn symPidPath = (PidPathFn)dlsym(RTLD_DEFAULT, "proc_pidpath");
                char dlsymPath[PATH_MAX] = {0};
                int pidLen = proc_pidpath(getpid(), selfPath, sizeof(selfPath));
                int dlsymLen = (symPidPath != NULL) ? symPidPath(getpid(), dlsymPath, sizeof(dlsymPath)) : -1;
                s10SelfPidpath = (pidLen > 0) ? ([NSString stringWithUTF8String:selfPath] ?: @"") : @"";
                BOOL directOK = (pidLen > 0 &&
                                 (strncmp(selfPath, "/private/var/containers/Bundle/Application/", 43) == 0 ||
                                  strncmp(selfPath, "/var/containers/Bundle/Application/", 35) == 0));
                BOOL dlsymOK = (dlsymLen > 0 &&
                                (strncmp(dlsymPath, "/private/var/containers/Bundle/Application/", 43) == 0 ||
                                 strncmp(dlsymPath, "/var/containers/Bundle/Application/", 35) == 0));
                s10SelfPidpathValue = s10SelfPidpath;
                s10SelfPidpathVirtual = (directOK && dlsymOK);
            }

            // 9. CoreMotion genuine classes + A10 epoch/interval + C05 CMAltimeter
            {
                CMMotionManager *s10Mgr = [[CMMotionManager alloc] init];
                BOOL magIntervalOK = (fabs(s10Mgr.magnetometerUpdateInterval - 0.01) < 1e-6);
                s10Mgr.accelerometerUpdateInterval = 0.02;
                s10Mgr.gyroUpdateInterval = 0.02;
                s10Mgr.deviceMotionUpdateInterval = 0.02;
                NSOperationQueue *q = [[NSOperationQueue alloc] init];
                q.maxConcurrentOperationCount = 1;

                __block CMAccelerometerData *accSample = nil;
                __block CMGyroData *gyroSample = nil;
                __block CMDeviceMotion *dmSample = nil;
                __block CMAltitudeData *altSample = nil;
                dispatch_group_t grp = dispatch_group_create();

                dispatch_group_enter(grp);
                __block BOOL gotAcc = NO;
                [s10Mgr startAccelerometerUpdatesToQueue:q withHandler:^(CMAccelerometerData *data, NSError *err) {
                    (void)err;
                    if (!gotAcc && data != nil) {
                        gotAcc = YES;
                        accSample = data;
                        dispatch_group_leave(grp);
                    }
                }];

                dispatch_group_enter(grp);
                __block BOOL gotGyro = NO;
                [s10Mgr startGyroUpdatesToQueue:q withHandler:^(CMGyroData *data, NSError *err) {
                    (void)err;
                    if (!gotGyro && data != nil) {
                        gotGyro = YES;
                        gyroSample = data;
                        dispatch_group_leave(grp);
                    }
                }];

                dispatch_group_enter(grp);
                __block BOOL gotDM = NO;
                [s10Mgr startDeviceMotionUpdatesToQueue:q withHandler:^(CMDeviceMotion *data, NSError *err) {
                    (void)err;
                    if (!gotDM && data != nil) {
                        gotDM = YES;
                        dmSample = data;
                        dispatch_group_leave(grp);
                    }
                }];

                BOOL altAvail = [CMAltimeter isRelativeAltitudeAvailable];
                CMAltimeter *alt = [[CMAltimeter alloc] init];
                dispatch_group_enter(grp);
                __block BOOL gotAlt = NO;
                [alt startRelativeAltitudeUpdatesToQueue:q withHandler:^(CMAltitudeData *data, NSError *err) {
                    (void)err;
                    if (!gotAlt && data != nil) {
                        gotAlt = YES;
                        altSample = data;
                        dispatch_group_leave(grp);
                    }
                }];

                NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.2];
                while (dispatch_group_wait(grp, DISPATCH_TIME_NOW) != 0 &&
                       [[NSDate date] compare:deadline] == NSOrderedAscending) {
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
                }
                [s10Mgr stopAccelerometerUpdates];
                [s10Mgr stopGyroUpdates];
                [s10Mgr stopDeviceMotionUpdates];
                [alt stopRelativeAltitudeUpdates];
                [q waitUntilAllOperationsAreFinished];

                NSTimeInterval uptime = [[NSProcessInfo processInfo] systemUptime];
                BOOL accOK = (accSample != nil &&
                              [accSample isMemberOfClass:[CMAccelerometerData class]] &&
                              fabs(accSample.timestamp - uptime) < 30.0);
                BOOL gyroOK = (gyroSample != nil &&
                               [gyroSample isMemberOfClass:[CMGyroData class]] &&
                               fabs(gyroSample.timestamp - uptime) < 30.0);
                BOOL dmOK = (dmSample != nil &&
                             [dmSample isMemberOfClass:[CMDeviceMotion class]] &&
                             ![NSStringFromClass([dmSample class]) hasPrefix:@"PSVirtual"] &&
                             fabs(dmSample.timestamp - uptime) < 30.0);
                s10CoreMotionGenuineAndEpochOK = (magIntervalOK && accOK && gyroOK && dmOK);
                s10AltimeterContractOK = (altAvail &&
                                          altSample != nil &&
                                          [altSample isMemberOfClass:[CMAltitudeData class]] &&
                                          altSample.pressure.doubleValue > 90.0 &&
                                          altSample.pressure.doubleValue < 110.0 &&
                                          fabs(altSample.timestamp - uptime) < 30.0);
            }

            // 10. C10: Relative AF_UNIX socket bind/connect/getsockname/getpeername
            {
                char savedCwd[PATH_MAX] = {0};
                if (getcwd(savedCwd, sizeof(savedCwd)) != NULL) {
                    const char *tmpRoot = getenv("TMPDIR") ?: "/tmp";
                    NSString *sockDir = [NSString stringWithFormat:@"%s/sc10sock_%d", tmpRoot, getpid()];
                    [fm createDirectoryAtPath:sockDir withIntermediateDirectories:YES attributes:nil error:nil];
                    if (chdir(sockDir.fileSystemRepresentation) == 0) {
                        int srvFd = socket(AF_UNIX, SOCK_STREAM, 0);
                        int cliFd = socket(AF_UNIX, SOCK_STREAM, 0);
                        if (srvFd >= 0 && cliFd >= 0) {
                            struct sockaddr_un addr;
                            memset(&addr, 0, sizeof(addr));
                            addr.sun_family = AF_UNIX;
                            strlcpy(addr.sun_path, "sc10.sock", sizeof(addr.sun_path));
                            socklen_t addrLen = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + strlen(addr.sun_path) + 1U);
                            if (bind(srvFd, (struct sockaddr *)&addr, addrLen) == 0 && listen(srvFd, 2) == 0) {
                                struct sockaddr_un gotLocal;
                                memset(&gotLocal, 0, sizeof(gotLocal));
                                socklen_t gotLocalLen = sizeof(gotLocal);
                                BOOL localOK = (getsockname(srvFd, (struct sockaddr *)&gotLocal, &gotLocalLen) == 0 &&
                                                strcmp(gotLocal.sun_path, "sc10.sock") == 0);
                                BOOL connOK = (connect(cliFd, (struct sockaddr *)&addr, addrLen) == 0);
                                struct sockaddr_un gotPeer;
                                memset(&gotPeer, 0, sizeof(gotPeer));
                                socklen_t gotPeerLen = sizeof(gotPeer);
                                BOOL peerOK = (connOK &&
                                               getpeername(cliFd, (struct sockaddr *)&gotPeer, &gotPeerLen) == 0 &&
                                               strcmp(gotPeer.sun_path, "sc10.sock") == 0);
                                int accFd = connOK ? accept(srvFd, NULL, NULL) : -1;
                                if (accFd >= 0) {
                                    close(accFd);
                                }
                                s10UnixRelativeSocketOK = (localOK && connOK && peerOK);
                            }
                        }
                        if (cliFd >= 0) close(cliFd);
                        if (srvFd >= 0) close(srvFd);
                        unlink("sc10.sock");
                        (void)chdir(savedCwd);
                    }
                    [fm removeItemAtPath:sockDir error:nil];
                }
            }

            // 11. C14: task_get_exception_ports / thread_get_exception_ports hide s_svc_exc_port
            {
                exception_mask_t masks[EXC_TYPES_COUNT];
                mach_msg_type_number_t count = EXC_TYPES_COUNT;
                mach_port_t ports[EXC_TYPES_COUNT];
                exception_behavior_t behaviors[EXC_TYPES_COUNT];
                thread_state_flavor_t flavors[EXC_TYPES_COUNT];
                kern_return_t tk = task_get_exception_ports(
                    mach_task_self(), EXC_MASK_BREAKPOINT, masks, &count, ports, behaviors, flavors);
                BOOL taskClean = (tk == KERN_SUCCESS);
                if (taskClean) {
                    for (mach_msg_type_number_t i = 0; i < count; i++) {
                        if (MACH_PORT_VALID(ports[i])) {
                            taskClean = NO;
                            mach_port_deallocate(mach_task_self(), ports[i]);
                        }
                    }
                }
                count = EXC_TYPES_COUNT;
                kern_return_t thk = thread_get_exception_ports(
                    mach_thread_self(), EXC_MASK_BREAKPOINT, masks, &count, ports, behaviors, flavors);
                BOOL threadClean = (thk == KERN_SUCCESS);
                if (threadClean) {
                    for (mach_msg_type_number_t i = 0; i < count; i++) {
                        if (MACH_PORT_VALID(ports[i])) {
                            threadClean = NO;
                            mach_port_deallocate(mach_task_self(), ports[i]);
                        }
                    }
                }
                s10ExceptionPortsHidden = (taskClean && threadClean);
            }

            // 12. hw.cacheconfig[0] == hw.ncpu and hw.cachesize[0] == hw.memsize
            {
                int spoofedNcpu = 0;
                size_t ncpuLen = sizeof(spoofedNcpu);
                uint64_t spoofedMem = 0;
                size_t memLen = sizeof(spoofedMem);
                uint64_t cacheCfg[10] = {0};
                size_t cfgLen = sizeof(cacheCfg);
                uint64_t cacheSz[10] = {0};
                size_t szLen = sizeof(cacheSz);
                if (sysctlbyname("hw.ncpu", &spoofedNcpu, &ncpuLen, NULL, 0) == 0 &&
                    sysctlbyname("hw.memsize", &spoofedMem, &memLen, NULL, 0) == 0 &&
                    sysctlbyname("hw.cacheconfig", cacheCfg, &cfgLen, NULL, 0) == 0 &&
                    sysctlbyname("hw.cachesize", cacheSz, &szLen, NULL, 0) == 0 &&
                    cfgLen >= sizeof(uint64_t) &&
                    szLen >= sizeof(uint64_t)) {
                    s10SysctlCacheTopologyOK = ((uint64_t)spoofedNcpu == cacheCfg[0] &&
                                                spoofedMem == cacheSz[0] &&
                                                spoofedNcpu > 0 &&
                                                spoofedMem >= (1ULL << 30));
                }
            }
        }

        // Scenario 11: 1.0.4 audit & detect-v2 parity checks
        BOOL s11ProcPidPathInfoOK = NO;
        BOOL s11SmallCapExcPortsOK = NO;
        BOOL s11CoreMotionCrossCompareOK = NO;
        BOOL s11PlayChainAppGroupAndSEOK = NO;
        BOOL s11CatalystImpUnwrapOK = NO;
        BOOL s11SwiftMangledHiddenOK = NO;
        BOOL s11NetIfListHiddenOK = NO;
        BOOL s11CacheL2AlignedOK = NO;
        BOOL s11GidNotStaffOK = NO;
        BOOL s11MonacoFontHiddenOK = NO;
        BOOL s11FileRefAndFsgetpathOK = NO;
        BOOL s11FileRefUrlOK = NO;
        BOOL s11DownloadsHidden = NO;
        BOOL s11FsgetpathOK = NO;
        NSString *s11FileRefPathValue = @"";
        BOOL s11MGCopyAnswerWithErrorOK = NO;
        BOOL s11AudioAndUTTypeHiddenOK = NO;
        BOOL s11SwapZeroOK = NO;
        BOOL s11SandboxDlsymOK = NO;
        BOOL s11CoreMotionPullCacheOK = NO;
        BOOL s11MigHostAndTaskOK = NO;
        BOOL s11BootstrapBlockedOK = NO;
        BOOL s11SysctlSwapAndTreeOK = NO;
        BOOL s11ResponsibilitySelfOK = NO;
        BOOL s11LsAsnHiddenOK = NO;
        BOOL s11ObjcMetaAndReqHiddenOK = NO;
        BOOL s11Round1DlsymAndProcOK = NO;
        BOOL s11Round1VolumeAndCodeResOK = NO;
        BOOL s11Round1AppKitAndSuperBlobOK = NO;
        BOOL s11Round2CGAndHIDBlockedOK = NO;
        BOOL s11Round2FontsAndDlopenOK = NO;
        BOOL s11Round2MigThreadNetIopsOK = NO;
        BOOL s11R2ThreadsClean = NO, s11R2Mig219OK = NO, s11R2Mig3414OK = NO, s11R2SiocgifconfClean = NO, s11R2IopsOK = NO, s11R2AmfiOK = NO, s11R2HdrImgOK = NO;
        BOOL s11Round3SignKernelCsrOK = NO;
        BOOL s11Round3DyldHandleUnwindOK = NO;
        BOOL s11R3ExplicitHandleOK = NO, s11R3CfBundleOK = NO, s11R3DlopenFromOK = NO, s11R3UnwindOK = NO;
        BOOL s11Round3FsCasePathsAndIORegOK = NO;
        const char *testS11Env = getenv("HARNESS_TEST_SCENARIO11");
        if (testS11Env != NULL && strcmp(testS11Env, "1") == 0) {
            // 1. PROC_PIDPATHINFO (libproc + SYS_proc_info) returns 0 and virtualized iOS bundle path
            {
                typedef int (*PidInfoFn)(int, int, uint64_t, void *, int);
                PidInfoFn fnPidInfo = (PidInfoFn)dlsym(RTLD_DEFAULT, "proc_pidinfo");
                char pbuf1[PROC_PIDPATHINFO_MAXSIZE] = {0};
                errno = 0;
                int rc1 = (fnPidInfo != NULL) ? fnPidInfo(getpid(), PROC_PIDPATHINFO, 0, pbuf1, (int)sizeof(pbuf1)) : -1;
                int err1 = errno;
                BOOL directPathOK = (rc1 == 0 && err1 == 0 &&
                                     (strncmp(pbuf1, "/private/var/containers/Bundle/Application/", 43) == 0 ||
                                      strncmp(pbuf1, "/var/containers/Bundle/Application/", 35) == 0));
                BOOL svcPathOK = YES;
#if defined(__arm64__) || defined(__aarch64__)
                char pbuf2[PROC_PIDPATHINFO_MAXSIZE] = {0};
                int svcErr = 0;
                int64_t rc2 = pt_harness_raw_svc(336 /* SYS_proc_info */,
                                                 2 /* PROC_INFO_CALL_PIDINFO */,
                                                 (uintptr_t)getpid(),
                                                 PROC_PIDPATHINFO,
                                                 0,
                                                 (uintptr_t)pbuf2,
                                                 (uintptr_t)sizeof(pbuf2),
                                                 &svcErr);
                svcPathOK = (rc2 == 0 && svcErr == 0 &&
                             (strncmp(pbuf2, "/private/var/containers/Bundle/Application/", 43) == 0 ||
                              strncmp(pbuf2, "/var/containers/Bundle/Application/", 35) == 0));
#endif
                s11ProcPidPathInfoOK = (directPathOK && svcPathOK);
            }

            // 2. Small-capacity (cnt = 1) task_get_exception_ports bounded write & redaction
            {
                exception_mask_t masks[2] = {0, 0};
                mach_msg_type_number_t count = 1;
                mach_port_t ports[2] = {MACH_PORT_NULL, (mach_port_t)0xCAFEBABEU};
                exception_behavior_t behaviors[2] = {0, 0x5A5A5A5A};
                thread_state_flavor_t flavors[2] = {0, 0x5A5A5A5A};
                kern_return_t kr = task_get_exception_ports(
                    mach_task_self(), EXC_MASK_ALL, masks, &count, ports, behaviors, flavors);
                BOOL noOverflow = (ports[1] == (mach_port_t)0xCAFEBABEU &&
                                   behaviors[1] == 0x5A5A5A5A &&
                                   flavors[1] == 0x5A5A5A5A &&
                                   count <= 1);
                BOOL noBrkPort = YES;
                if (kr == KERN_SUCCESS && count == 1) {
                    if ((masks[0] & EXC_MASK_BREAKPOINT) != 0 && MACH_PORT_VALID(ports[0])) {
                        noBrkPort = NO;
                    }
                    if (MACH_PORT_VALID(ports[0])) {
                        mach_port_deallocate(mach_task_self(), ports[0]);
                    }
                }
                s11SmallCapExcPortsOK = (kr == KERN_SUCCESS && noOverflow && noBrkPort);
            }

            // 3. CoreMotion virtual vs unarchived genuine isEqual: and multiplyByInverseOfAttitude: no-crash
            {
                CMMotionManager *m11 = [[CMMotionManager alloc] init];
                m11.deviceMotionUpdateInterval = 0.02;
                NSOperationQueue *q11 = [[NSOperationQueue alloc] init];
                q11.maxConcurrentOperationCount = 1;
                __block CMDeviceMotion *dmSample11 = nil;
                __block BOOL gotDM11 = NO;
                dispatch_group_t grp11 = dispatch_group_create();
                dispatch_group_enter(grp11);
                [m11 startDeviceMotionUpdatesToQueue:q11 withHandler:^(CMDeviceMotion *data, NSError *err) {
                    (void)err;
                    if (!gotDM11 && data != nil) {
                        gotDM11 = YES;
                        dmSample11 = data;
                        dispatch_group_leave(grp11);
                    }
                }];
                NSDate *dl11 = [NSDate dateWithTimeIntervalSinceNow:1.2];
                while (dispatch_group_wait(grp11, DISPATCH_TIME_NOW) != 0 &&
                       [[NSDate date] compare:dl11] == NSOrderedAscending) {
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
                }
                [m11 stopDeviceMotionUpdates];
                [q11 waitUntilAllOperationsAreFinished];
                if (dmSample11 != nil && dmSample11.attitude != nil) {
                    NSData *dmData = [NSKeyedArchiver archivedDataWithRootObject:dmSample11
                                                           requiringSecureCoding:YES
                                                                           error:nil];
                    NSData *attData = [NSKeyedArchiver archivedDataWithRootObject:dmSample11.attitude
                                                            requiringSecureCoding:YES
                                                                            error:nil];
                    CMDeviceMotion *genDM = dmData
                        ? [NSKeyedUnarchiver unarchivedObjectOfClass:[CMDeviceMotion class]
                                                            fromData:dmData
                                                               error:nil]
                        : nil;
                    CMAttitude *genAtt = attData
                        ? [NSKeyedUnarchiver unarchivedObjectOfClass:[CMAttitude class]
                                                            fromData:attData
                                                               error:nil]
                        : nil;
                    if (genDM != nil && genAtt != nil) {
                        BOOL dmEqFwd = [dmSample11 isEqual:genDM];
                        BOOL dmEqRev = [genDM isEqual:dmSample11];
                        BOOL attEqFwd = [dmSample11.attitude isEqual:genAtt];
                        BOOL attEqRev = [genAtt isEqual:dmSample11.attitude];
                        [dmSample11.attitude multiplyByInverseOfAttitude:genAtt];
                        [genAtt multiplyByInverseOfAttitude:dmSample11.attitude];
                        (void)dmEqFwd;
                        (void)dmEqRev;
                        s11CoreMotionCrossCompareOK = (attEqFwd && attEqRev);
                    }
                }
            }

            // 4. PlayChain App Group allowed, NSNull rejected, & SecKeyCopyAttributes SE redaction
            {
                NSString *grpSvc = [NSString stringWithFormat:@"sc11.grp.%d", getpid()];
                NSDictionary *grpQ = @{
                    (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                    (__bridge id)kSecAttrService: grpSvc,
                    (__bridge id)kSecAttrAccount: @"sc11-acct",
                    (__bridge id)kSecAttrAccessGroup: @"group.app.makedie.harness.shared",
                    (__bridge id)kSecValueData: [@"sc11-grp-secret" dataUsingEncoding:NSUTF8StringEncoding],
                };
                OSStatus grpAddSt = SecItemAdd((__bridge CFDictionaryRef)grpQ, NULL);
                SecItemDelete((__bridge CFDictionaryRef)@{
                    (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                    (__bridge id)kSecAttrService: grpSvc,
                    (__bridge id)kSecAttrAccount: @"sc11-acct",
                });

                NSDictionary *nullGrpQ = @{
                    (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                    (__bridge id)kSecAttrService: [grpSvc stringByAppendingString:@".null"],
                    (__bridge id)kSecAttrAccount: @"sc11-acct",
                    (__bridge id)kSecAttrAccessGroup: [NSNull null],
                    (__bridge id)kSecValueData: [@"x" dataUsingEncoding:NSUTF8StringEncoding],
                };
                OSStatus nullGrpSt = SecItemAdd((__bridge CFDictionaryRef)nullGrpQ, NULL);

                NSDictionary *seParams11 = @{
                    (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
                    (__bridge id)kSecAttrKeySizeInBits: @256,
                    (__bridge id)kSecAttrTokenID: (__bridge id)kSecAttrTokenIDSecureEnclave,
                    (__bridge id)kSecPrivateKeyAttrs: @{
                        (__bridge id)kSecAttrIsPermanent: @NO,
                    },
                };
                SecKeyRef seKey11 = SecKeyCreateRandomKey((__bridge CFDictionaryRef)seParams11, NULL);
                BOOL seAttrsOK = NO;
                if (seKey11 != NULL) {
                    NSDictionary *attrs = CFBridgingRelease(SecKeyCopyAttributes(seKey11));
                    seAttrsOK = (attrs != nil &&
                                 attrs[(__bridge id)kSecValueData] == nil &&
                                 [attrs[(__bridge id)kSecAttrTokenID] isEqual:(__bridge id)kSecAttrTokenIDSecureEnclave]);
                    CFRelease(seKey11);
                }
                s11PlayChainAppGroupAndSEOK = (grpAddSt == errSecSuccess && nullGrpSt == errSecParam && seAttrsOK);
            }

            // 5. version.imp_unwrap_catalyst_bool: CoreFoundation IMP returns NO
            {
                NSProcessInfo *pi = [NSProcessInfo processInfo];
                BOOL allOK = YES;
                NSArray<NSString *> *sels = @[ @"isMacCatalystApp", @"isiOSAppOnMac" ];
                for (NSString *selName in sels) {
                    SEL s = NSSelectorFromString(selName);
                    Method m = class_getInstanceMethod([pi class], s);
                    if (m == NULL) {
                        allOK = NO;
                        break;
                    }
                    IMP imp = method_getImplementation(m);
                    Dl_info dl;
                    memset(&dl, 0, sizeof(dl));
                    BOOL isCF = (imp != NULL && dladdr((const void *)imp, &dl) != 0 &&
                                 dl.dli_fname != NULL && strstr(dl.dli_fname, "CoreFoundation") != NULL);
                    BOOL msgVal = ((BOOL (*)(id, SEL))objc_msgSend)(pi, s);
                    BOOL impVal = (imp != NULL) ? ((BOOL (*)(id, SEL))imp)(pi, s) : YES;
                    if (!isCF || msgVal || impVal) {
                        allOK = NO;
                        break;
                    }
                }
                s11CatalystImpUnwrapOK = allOK;
            }

            // 6. swift_getTypeByMangledNameInContext hides PlayTools & AKInterface
            {
#if __has_attribute(swiftcall)
                pt_harness_swift_lookup_fn swiftLookup =
                    (pt_harness_swift_lookup_fn)dlsym(RTLD_DEFAULT, "swift_getTypeByMangledNameInContext");
                if (swiftLookup != NULL) {
                    const char *ptName = "9PlayTools12PlaySettingsC";
                    const char *akName = "11AKInterface8AKPluginC";
                    const void *ptType = swiftLookup(ptName, strlen(ptName), NULL, NULL);
                    const void *akType = swiftLookup(akName, strlen(akName), NULL, NULL);
                    s11SwiftMangledHiddenOK = (ptType == NULL && akType == NULL);
                }
#endif
            }

            // 7. if_nameindex + NET_RT_IFLIST hide bridge*/vmenet*/vmnet*
            {
                BOOL nameIndexClean = NO;
                struct if_nameindex *ifs = if_nameindex();
                if (ifs != NULL) {
                    BOOL sawAny = NO;
                    BOOL leaked = NO;
                    for (struct if_nameindex *p = ifs; p->if_index != 0 || p->if_name != NULL; p++) {
                        if (p->if_name == NULL) {
                            continue;
                        }
                        sawAny = YES;
                        if (strncmp(p->if_name, "bridge", 6) == 0 ||
                            strncmp(p->if_name, "vmenet", 6) == 0 ||
                            strncmp(p->if_name, "vmnet", 5) == 0 ||
                            strncmp(p->if_name, "anpi", 4) == 0) {
                            leaked = YES;
                        }
                    }
                    if_freenameindex(ifs);
                    nameIndexClean = (sawAny && !leaked);
                }

                BOOL routeListClean = NO;
                int rtMib[6] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST, 0};
                size_t rtLen = 0;
                if (sysctl(rtMib, 6, NULL, &rtLen, NULL, 0) == 0 && rtLen > 0) {
                    NSMutableData *rtBuf = [NSMutableData dataWithLength:rtLen];
                    if (sysctl(rtMib, 6, rtBuf.mutableBytes, &rtLen, NULL, 0) == 0 && rtLen > 0) {
                        const uint8_t *cur = (const uint8_t *)rtBuf.bytes;
                        const uint8_t *end = cur + rtLen;
                        BOOL sawIf = NO;
                        BOOL leaked = NO;
                        while (cur + sizeof(struct if_msghdr) <= end) {
                            const struct if_msghdr *ifm = (const struct if_msghdr *)cur;
                            if (ifm->ifm_msglen < sizeof(struct if_msghdr) || cur + ifm->ifm_msglen > end) {
                                break;
                            }
                            if (ifm->ifm_type == RTM_IFINFO &&
                                cur + sizeof(struct if_msghdr) + sizeof(struct sockaddr_dl) <= end) {
                                const struct sockaddr_dl *sdl = (const struct sockaddr_dl *)(cur + sizeof(struct if_msghdr));
                                if (sdl->sdl_family == AF_LINK && sdl->sdl_nlen > 0 && sdl->sdl_nlen < 64) {
                                    char ifn[64] = {0};
                                    memcpy(ifn, sdl->sdl_data, sdl->sdl_nlen);
                                    sawIf = YES;
                                    if (strncmp(ifn, "bridge", 6) == 0 ||
                                        strncmp(ifn, "vmenet", 6) == 0 ||
                                        strncmp(ifn, "vmnet", 5) == 0) {
                                        leaked = YES;
                                    }
                                }
                            }
                            cur += ifm->ifm_msglen;
                        }
                        routeListClean = (sawIf && !leaked);
                    }
                }
                s11NetIfListHiddenOK = (nameIndexClean && routeListClean);
            }

            // 8. hw.cachesize[1] == hw.l1dcachesize and hw.cachesize[2] == hw.l2cachesize
            {
                uint64_t l1d = 0, l2 = 0;
                size_t l1Len = sizeof(l1d), l2Len = sizeof(l2);
                uint64_t csz[10] = {0};
                size_t cszLen = sizeof(csz);
                if (sysctlbyname("hw.l1dcachesize", &l1d, &l1Len, NULL, 0) == 0 &&
                    sysctlbyname("hw.l2cachesize", &l2, &l2Len, NULL, 0) == 0 &&
                    sysctlbyname("hw.cachesize", csz, &cszLen, NULL, 0) == 0 &&
                    cszLen >= (3U * sizeof(uint64_t))) {
                    s11CacheL2AlignedOK = (l1d > 0 && l2 > 0 && csz[1] == l1d && csz[2] == l2);
                }
            }

            // 9. getgid()/getegid()/getgroups() exclude staff gid 20
            {
                gid_t grps[128] = {0};
                int ng = getgroups(128, grps);
                BOOL has20 = NO;
                for (int i = 0; i < ng; i++) {
                    if (grps[i] == 20) {
                        has20 = YES;
                    }
                }
                s11GidNotStaffOK = (getgid() != 20 && getegid() != 20 && ng >= 0 && !has20);
            }

            // 10. UIFont fontWithName:@"Monaco" & CTFontCreateWithName("Monaco") hidden/substituted
            {
                UIFont *uiMonaco = [UIFont fontWithName:@"Monaco" size:12.0];
                CTFontRef ctMonaco = CTFontCreateWithName(CFSTR("Monaco"), 12.0, NULL);
                BOOL ctOK = NO;
                if (ctMonaco != NULL) {
                    NSString *psName = CFBridgingRelease(CTFontCopyPostScriptName(ctMonaco));
                    ctOK = (psName != nil && ![psName hasPrefix:@"Monaco"]);
                    CFRelease(ctMonaco);
                } else {
                    ctOK = YES;
                }
                s11MonacoFontHiddenOK = (uiMonaco == nil && ctOK);
            }

            // 11. NSURL fileReferenceURL -> filePathURL virtualized, Downloads symlink hidden, fsgetpath virtualized
            {
                NSURL *homeURL = [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES];
                NSURL *refURL = [homeURL fileReferenceURL];
                NSURL *roundTripURL = [refURL filePathURL];
                NSString *rtPath = roundTripURL.path;
                s11FileRefPathValue = rtPath ?: @"";
                BOOL urlOK = (rtPath.length > 0 &&
                              [rtPath rangeOfString:@"/Users/"].location == NSNotFound &&
                              [rtPath rangeOfString:@"/Library/Containers/"].location == NSNotFound);

                NSString *dlLink = [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"];
                struct stat dlSt = {0};
                errno = 0;
                BOOL dlHidden = (lstat(dlLink.fileSystemRepresentation, &dlSt) != 0 && errno == ENOENT);

                BOOL fsgetOK = NO;
                typedef ssize_t (*FsGetPathFn)(char *, size_t, fsid_t *, uint64_t);
                FsGetPathFn fnFsGetPath = (FsGetPathFn)dlsym(RTLD_DEFAULT, "fsgetpath");
                const char *execPath = _dyld_get_image_name(0);
                struct stat exSt = {0};
                struct statfs exFs;
                memset(&exFs, 0, sizeof(exFs));
                if (fnFsGetPath != NULL && execPath != NULL &&
                    stat(execPath, &exSt) == 0 && statfs(execPath, &exFs) == 0) {
                    char fgp[PATH_MAX] = {0};
                    ssize_t fgpLen = fnFsGetPath(fgp, sizeof(fgp), &exFs.f_fsid, exSt.st_ino);
                    fsgetOK = (fgpLen > 0 &&
                               (strncmp(fgp, "/private/var/containers/Bundle/Application/", 43) == 0 ||
                                strncmp(fgp, "/var/containers/Bundle/Application/", 35) == 0));
                }
                s11FileRefUrlOK = urlOK;
                s11DownloadsHidden = dlHidden;
                s11FsgetpathOK = fsgetOK;
                s11FileRefAndFsgetpathOK = (urlOK && dlHidden && fsgetOK);
            }

            // 12. MGCopyAnswerWithError spoofed
            {
                typedef CFTypeRef (*MGErrFn)(CFStringRef, CFDictionaryRef, int *);
                MGErrFn fnMG = (MGErrFn)dlsym(RTLD_DEFAULT, "MGCopyAnswerWithError");
                if (fnMG != NULL) {
                    int err1 = -1, err2 = -1;
                    NSString *pn = CFBridgingRelease(fnMG(CFSTR("ProductName"), NULL, &err1));
                    NSString *pt = CFBridgingRelease(fnMG(CFSTR("ProductType"), NULL, &err2));
                    s11MGCopyAnswerWithErrorOK = (err1 == 0 && err2 == 0 &&
                                                  [pn isEqualToString:@"iPhone OS"] &&
                                                  ([pt hasPrefix:@"iPad"] || [pt hasPrefix:@"iPhone"]));
                }
            }

            // 13. AudioObjectGetPropertyDataSize/AudioComponentFindNext('ahal')/UTType desktop declarations hidden
            {
                (void)dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_LAZY);
                (void)dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
                BOOL noHAL = (dlsym(RTLD_DEFAULT, "AudioObjectGetPropertyDataSize") == NULL &&
                              dlsym(RTLD_DEFAULT, "AudioObjectGetPropertyData") == NULL);

                typedef struct {
                    OSType componentType;
                    OSType componentSubType;
                    OSType componentManufacturer;
                    UInt32 componentFlags;
                    UInt32 componentFlagsMask;
                } HarnessAudioComponentDesc;
                typedef void *(*AudioFindNextFn)(void *, const HarnessAudioComponentDesc *);
                AudioFindNextFn fnFindNext = (AudioFindNextFn)dlsym(RTLD_DEFAULT, "AudioComponentFindNext");
                BOOL noAhal = NO;
                if (fnFindNext != NULL) {
                    HarnessAudioComponentDesc d = {'auou', 'ahal', 'appl', 0, 0};
                    noAhal = (fnFindNext(NULL, &d) == NULL);
                }

                typedef CFURLRef (*UTCopyURLFn)(CFStringRef);
                typedef CFDictionaryRef (*UTCopyDeclFn)(CFStringRef);
                UTCopyURLFn fnUTURL = (UTCopyURLFn)dlsym(RTLD_DEFAULT, "UTTypeCopyDeclaringBundleURL");
                UTCopyDeclFn fnUTDecl = (UTCopyDeclFn)dlsym(RTLD_DEFAULT, "UTTypeCopyDeclaration");
                BOOL utOK = NO;
                if (fnUTURL != NULL && fnUTDecl != NULL) {
                    NSURL *macURL = CFBridgingRelease(fnUTURL(CFSTR("com.apple.mac")));
                    NSURL *finderURL = CFBridgingRelease(fnUTURL(CFSTR("com.apple.finder")));
                    NSDictionary *finderDecl = CFBridgingRelease(fnUTDecl(CFSTR("com.apple.finder")));
                    BOOL macNotCoreTypes = (macURL == nil ||
                                            ![macURL.path.lastPathComponent isEqualToString:@"CoreTypes.bundle"]);
                    utOK = (macNotCoreTypes && finderURL == nil && finderDecl == nil);
                }
                s11AudioAndUTTypeHiddenOK = (noHAL && noAhal && utOK);
            }

            // 13. host_statistics64(HOST_VM_INFO64) zeros swapins/swapouts
            {
                vm_statistics64_data_t vmstat64;
                memset(&vmstat64, 0xff, sizeof(vmstat64));
                mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
                kern_return_t kr = host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vmstat64, &count);
                s11SwapZeroOK = (kr == KERN_SUCCESS && vmstat64.swapins == 0 && vmstat64.swapouts == 0);
            }

            // 14. dlsym("sandbox_check") routes and denies desktop Mach services under SANDBOX_FILTER_GLOBAL_NAME (2)
            {
                typedef int (*SandboxCheckFn)(pid_t, const char *, int, ...);
                SandboxCheckFn fnSandbox = (SandboxCheckFn)dlsym(RTLD_DEFAULT, "sandbox_check");
                if (fnSandbox != NULL) {
                    int dockRC = fnSandbox(getpid(), "mach-lookup", 2, "com.apple.dock.server");
                    int wsRC = fnSandbox(getpid(), "mach-lookup", 2, "com.apple.windowserver.active");
                    s11SandboxDlsymOK = (dockRC == 1 && wsRC == 1);
                }
            }

            // 15. CoreMotion availableAttitudeReferenceFrames, attitudeReferenceFrame, and pull-mode updateInterval cache
            {
                CMMotionManager *mgr11 = [CMMotionManager new];
                CMAttitudeReferenceFrame availFrames = [CMMotionManager availableAttitudeReferenceFrames];
                CMAttitudeReferenceFrame instFrame = mgr11.attitudeReferenceFrame;
                NSMutableSet *ptrs = [NSMutableSet set];
                NSMutableSet *tss = [NSMutableSet set];
                NSUInteger samplesSeen = 0;
                if (mgr11.deviceMotionAvailable && (availFrames & CMAttitudeReferenceFrameXArbitraryZVertical) != 0) {
                    mgr11.deviceMotionUpdateInterval = 1.0;
                    [mgr11 startDeviceMotionUpdatesUsingReferenceFrame:CMAttitudeReferenceFrameXArbitraryZVertical];
                    @try {
                        for (int i = 0; i < 16; i++) {
                            CMDeviceMotion *s = mgr11.deviceMotion;
                            if (s == nil) {
                                break;
                            }
                            samplesSeen++;
                            [ptrs addObject:[NSValue valueWithPointer:(__bridge const void *)s]];
                            [tss addObject:@(s.timestamp)];
                        }
                    } @finally {
                        [mgr11 stopDeviceMotionUpdates];
                    }
                }
                s11CoreMotionPullCacheOK = ((availFrames & CMAttitudeReferenceFrameXArbitraryZVertical) != 0 &&
                                            instFrame == CMAttitudeReferenceFrameXArbitraryZVertical &&
                                            samplesSeen == 16 &&
                                            ptrs.count == 1 &&
                                            tss.count == 1);
            }

            // 16. mach_msg2_internal MIG HOST_BASIC_INFO (200/300) and TASK_VM_INFO (3405/3505) rewriting + 16 KiB Jetsam alignment
            {
                typedef kern_return_t (*Msg2Fn)(void *, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
                typedef mach_port_t (*GetReplyFn)(void);
                typedef void (*ReplyOpFn)(mach_port_t);
                Msg2Fn fnMsg2 = (Msg2Fn)dlsym(RTLD_DEFAULT, "mach_msg2_internal");
                GetReplyFn fnGetReply = (GetReplyFn)dlsym(RTLD_DEFAULT, "mig_get_reply_port");
                ReplyOpFn fnPutReply = (ReplyOpFn)dlsym(RTLD_DEFAULT, "mig_put_reply_port");
                ReplyOpFn fnDeallocReply = (ReplyOpFn)dlsym(RTLD_DEFAULT, "mig_dealloc_reply_port");

                uint64_t sysctlMem = 0;
                size_t sysctlMemLen = sizeof(sysctlMem);
                sysctlbyname("hw.memsize", &sysctlMem, &sysctlMemLen, NULL, 0);

                host_basic_info_data_t wrappedHost = {0};
                mach_msg_type_number_t whc = HOST_BASIC_INFO_COUNT;
                kern_return_t whr = host_info(mach_host_self(), HOST_BASIC_INFO, (host_info_t)&wrappedHost, &whc);

                task_vm_info_data_t wrappedVm = {0};
                mach_msg_type_number_t wvc = TASK_VM_INFO_COUNT;
                kern_return_t wvr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&wrappedVm, &wvc);

                BOOL hostMigOK = NO;
                BOOL taskMigOK = NO;
                if (fnMsg2 != NULL && fnGetReply != NULL && whr == KERN_SUCCESS && wvr == KERN_SUCCESS) {
                    const uint32_t bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
                    const uint64_t opt64 = 0x0000000200000003ULL;
                    const size_t prefix = sizeof(mach_msg_header_t) + sizeof(NDR_record_t);

                    // HOST_BASIC_INFO (200 -> 300)
                    {
                        union {
                            mach_msg_header_t hdr;
                            uint8_t bytes[512];
                        } buf = {0};
                        struct {
                            mach_msg_header_t hdr;
                            NDR_record_t ndr;
                            int flavor;
                            mach_msg_type_number_t count;
                        } req = {0};
                        mach_port_t reply = fnGetReply();
                        if (MACH_PORT_VALID(reply)) {
                            req.ndr = NDR_record;
                            req.flavor = HOST_BASIC_INFO;
                            req.count = HOST_BASIC_INFO_COUNT;
                            memcpy(buf.bytes, &req, sizeof(req));
                            buf.hdr.msgh_bits = bits;
                            buf.hdr.msgh_size = sizeof(req);
                            buf.hdr.msgh_remote_port = mach_host_self();
                            buf.hdr.msgh_local_port = reply;
                            buf.hdr.msgh_id = 200;
                            kern_return_t rc = fnMsg2(buf.bytes, opt64,
                                                      (uint64_t)bits | ((uint64_t)sizeof(req) << 32),
                                                      (uint64_t)mach_host_self() | ((uint64_t)reply << 32),
                                                      (uint64_t)200U << 32,
                                                      (uint64_t)reply << 32,
                                                      (uint64_t)sizeof(buf), 0);
                            if (rc == KERN_SUCCESS) {
                                if (fnPutReply != NULL) fnPutReply(reply);
                            } else if (fnDeallocReply != NULL) {
                                fnDeallocReply(reply);
                            }
                            kern_return_t rrc = KERN_FAILURE;
                            natural_t rcnt = 0;
                            if (rc == KERN_SUCCESS && buf.hdr.msgh_id == 300 &&
                                buf.hdr.msgh_size >= prefix + 8 + sizeof(host_basic_info_data_t)) {
                                memcpy(&rrc, buf.bytes + prefix, sizeof(rrc));
                                memcpy(&rcnt, buf.bytes + prefix + 4, sizeof(rcnt));
                                host_basic_info_data_t migHost = {0};
                                memcpy(&migHost, buf.bytes + prefix + 8, sizeof(migHost));
                                hostMigOK = (rrc == KERN_SUCCESS && rcnt == HOST_BASIC_INFO_COUNT &&
                                             migHost.max_mem == sysctlMem &&
                                             migHost.max_mem == wrappedHost.max_mem &&
                                             migHost.max_cpus == wrappedHost.max_cpus);
                            }
                        }
                    }

                    // TASK_VM_INFO (3405 -> 3505)
                    {
                        union {
                            mach_msg_header_t hdr;
                            uint8_t bytes[1024];
                        } buf = {0};
                        struct {
                            mach_msg_header_t hdr;
                            NDR_record_t ndr;
                            int flavor;
                            mach_msg_type_number_t count;
                        } req = {0};
                        mach_port_t reply = fnGetReply();
                        if (MACH_PORT_VALID(reply)) {
                            req.ndr = NDR_record;
                            req.flavor = TASK_VM_INFO;
                            req.count = TASK_VM_INFO_COUNT;
                            memcpy(buf.bytes, &req, sizeof(req));
                            buf.hdr.msgh_bits = bits;
                            buf.hdr.msgh_size = sizeof(req);
                            buf.hdr.msgh_remote_port = mach_task_self();
                            buf.hdr.msgh_local_port = reply;
                            buf.hdr.msgh_id = 3405;
                            kern_return_t rc = fnMsg2(buf.bytes, opt64,
                                                      (uint64_t)bits | ((uint64_t)sizeof(req) << 32),
                                                      (uint64_t)mach_task_self() | ((uint64_t)reply << 32),
                                                      (uint64_t)3405U << 32,
                                                      (uint64_t)reply << 32,
                                                      (uint64_t)sizeof(buf), 0);
                            if (rc == KERN_SUCCESS) {
                                if (fnPutReply != NULL) fnPutReply(reply);
                            } else if (fnDeallocReply != NULL) {
                                fnDeallocReply(reply);
                            }
                            kern_return_t rrc = KERN_FAILURE;
                            natural_t rcnt = 0;
                            size_t need = offsetof(task_vm_info_data_t, limit_bytes_remaining) + sizeof(mach_vm_size_t);
                            if (rc == KERN_SUCCESS && buf.hdr.msgh_id == 3505 &&
                                buf.hdr.msgh_size >= prefix + 8 + need) {
                                memcpy(&rrc, buf.bytes + prefix, sizeof(rrc));
                                memcpy(&rcnt, buf.bytes + prefix + 4, sizeof(rcnt));
                                task_vm_info_data_t migVm = {0};
                                size_t cbytes = ((size_t)rcnt * sizeof(natural_t) < sizeof(migVm))
                                    ? (size_t)rcnt * sizeof(natural_t) : sizeof(migVm);
                                memcpy(&migVm, buf.bytes + prefix + 8, cbytes);
                                uint64_t migRem = (uint64_t)migVm.limit_bytes_remaining;
                                uint64_t wrapRem = (uint64_t)wrappedVm.limit_bytes_remaining;
                                taskMigOK = (rrc == KERN_SUCCESS &&
                                             migRem > 0 &&
                                             wrapRem > 0 &&
                                             (migRem & 16383ULL) == 0 &&
                                             (wrapRem & 16383ULL) == 0 &&
                                             ((migRem + wrapRem) & 4095ULL) == 0);
                            }
                        }
                    }
                }
                s11MigHostAndTaskOK = (hostMigOK && taskMigOK);
            }

            // 17. bootstrap_look_up/2 return 1102, vm.swapfileprefix, CTL_SYSCTL tree hides proc_translated, responsibility/LS hidden
            {
                typedef kern_return_t (*BootFn)(mach_port_t, const char *, mach_port_t *);
                BootFn fnBoot = (BootFn)dlsym(RTLD_DEFAULT, "bootstrap_look_up");
                mach_port_t sp1 = 123, sp2 = 123;
                kern_return_t br1 = (fnBoot != NULL) ? fnBoot(bootstrap_port, "com.apple.dock.server", &sp1) : -1;
                kern_return_t br2 = (fnBoot != NULL) ? fnBoot(bootstrap_port, "com.apple.windowserver.active", &sp2) : -1;
                s11BootstrapBlockedOK = (br1 == 1102 && br2 == 1102 && sp1 == MACH_PORT_NULL && sp2 == MACH_PORT_NULL);

                char swapPfx[128] = {0};
                size_t swapPfxLen = sizeof(swapPfx);
                int swapRC = sysctlbyname("vm.swapfileprefix", swapPfx, &swapPfxLen, NULL, 0);
                int ptVal = -1;
                size_t ptLen = sizeof(ptVal);
                errno = 0;
                int ptRC = sysctlbyname("sysctl.proc_translated", &ptVal, &ptLen, NULL, 0);
                s11SysctlSwapAndTreeOK = (swapRC == 0 &&
                                          strcmp(swapPfx, "/private/var/vm/swapfile") == 0 &&
                                          ptRC != 0 && errno == ENOENT);

                typedef pid_t (*RespFn)(pid_t);
                RespFn fnResp = (RespFn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
                s11ResponsibilitySelfOK = (fnResp != NULL && fnResp(getpid()) == getpid());

                s11LsAsnHiddenOK = (dlsym(RTLD_DEFAULT, "_LSGetCurrentApplicationASN") == NULL &&
                                    dlsym(RTLD_DEFAULT, "_LSASNCreateWithPid") == NULL &&
                                    dlsym(RTLD_DEFAULT, "_LSCopyApplicationInformation") == NULL);

                s11ObjcMetaAndReqHiddenOK = (objc_getMetaClass("NSApplication") == Nil &&
                                             objc_getRequiredClass("NSApplication") == Nil);
            }

            // 18. Round 1 parity: dlsym routing, utmpx/hostuuid/grouplist/kinfo_proc, volumes, AppKit hiding, SuperBlob CD hash
            {
                BOOL noMetalAll = (dlsym(RTLD_DEFAULT, "MTLCopyAllDevices") == NULL);
                BOOL noAudioHas = (dlsym(RTLD_DEFAULT, "AudioObjectHasProperty") == NULL);
                BOOL noMacSC = (dlsym(RTLD_DEFAULT, "SCDynamicStoreCopyComputerName") == NULL &&
                                dlsym(RTLD_DEFAULT, "SCNetworkInterfaceCopyAll") == NULL);
                BOOL hasDlsymRoutes = (dlsym(RTLD_DEFAULT, "task_get_exception_ports") != NULL &&
                                       dlsym(RTLD_DEFAULT, "getifaddrs") != NULL);
                void (*setUtx)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "setutxent");
                void *(*getUtx)(void) = (void *(*)(void))dlsym(RTLD_DEFAULT, "getutxent");
                void (*endUtx)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "endutxent");
                BOOL utmpxClean = YES;
                if (setUtx != NULL && getUtx != NULL && endUtx != NULL) {
                    setUtx();
                    utmpxClean = (getUtx() == NULL);
                    endUtx();
                }
                int kpMib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
                struct kinfo_proc kp;
                memset(&kp, 0, sizeof(kp));
                size_t kpSz = sizeof(kp);
                BOOL kpClean = NO;
                if (sysctl(kpMib, 4, &kp, &kpSz, NULL, 0) == 0 && kpSz >= sizeof(kp)) {
                    kpClean = YES;
                    int ng = kp.kp_eproc.e_ucred.cr_ngroups;
                    if (ng > 16) ng = 16;
                    for (int gi = 0; gi < ng; gi++) {
                        gid_t g = kp.kp_eproc.e_ucred.cr_groups[gi];
                        if (g == 20U || g == 80U || g == 81U || g == 204U || g == 395U || g == 400U) {
                            kpClean = NO;
                            break;
                        }
                    }
                }
                int glBuf[32] = {0};
                int glN = 32;
                int (*fnGL)(const char *, int, int *, int *) = (int (*)(const char *, int, int *, int *))dlsym(RTLD_DEFAULT, "getgrouplist");
                BOOL glClean = YES;
                if (fnGL != NULL && fnGL("mobile", (int)getgid(), glBuf, &glN) == 0 && glN > 0 && glN <= 32) {
                    for (int gi = 0; gi < glN; gi++) {
                        int g = glBuf[gi];
                        if (g == 20 || g == 80 || g == 81 || g == 204 || g == 395 || g == 400) {
                            glClean = NO;
                            break;
                        }
                    }
                }
                s11Round1DlsymAndProcOK = (noMetalAll && noAudioHas && noMacSC && hasDlsymRoutes && utmpxClean && kpClean && glClean);

                NSURL *homeURL = [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES];
                id vName = nil, vURL = nil;
                [homeURL getResourceValue:&vName forKey:NSURLVolumeNameKey error:nil];
                [homeURL getResourceValue:&vURL forKey:NSURLVolumeURLKey error:nil];
                BOOL volClean = (!([vName isKindOfClass:[NSString class]] && [(NSString *)vName containsString:@"Macintosh HD"]) &&
                                 !([vURL isKindOfClass:[NSURL class]] && [[(NSURL *)vURL path] hasPrefix:@"/System/Volumes/Data"]));
                NSArray<NSURL *> *mounted = [[NSFileManager defaultManager] mountedVolumeURLsIncludingResourceValuesForKeys:nil options:0];
                for (NSURL *mu in mounted) {
                    if ([mu.path hasPrefix:@"/System/Volumes/Data"] || [mu.path hasPrefix:@"/Volumes/"]) {
                        volClean = NO;
                    }
                }
                char csTmp[PATH_MAX] = {0};
                BOOL confstrClean = (confstr(_CS_DARWIN_USER_TEMP_DIR, csTmp, sizeof(csTmp)) == 0 ||
                                     strstr(csTmp, "/var/folders/") == NULL);
                BOOL crPathClean = YES;
                NSString *crP = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"_CodeSignature/CodeResources"];
                int crFd = open(crP.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
                if (crFd >= 0) {
                    char crReal[PATH_MAX] = {0};
                    if (fcntl(crFd, F_GETPATH, crReal) == 0 &&
                        (strstr(crReal, ".pt_coderes_") != NULL || strstr(crReal, "/AppBackups/") != NULL)) {
                        crPathClean = NO;
                    }
                    close(crFd);
                }
                s11Round1VolumeAndCodeResOK = (volClean && confstrClean && crPathClean);

                BOOL appkitHidden = (NSClassFromString(@"NSCursor") == Nil &&
                                     NSClassFromString(@"NSStatusBar") == Nil &&
                                     NSClassFromString(@"NSDockTile") == Nil &&
                                     NSClassFromString(@"NSOpenPanel") == Nil &&
                                     NSClassFromString(@"NSTouchBar") == Nil &&
                                     objc_getMetaClass("NSCursor") == Nil);
                const char **(*fnCopyHdr)(const void *, unsigned int *) =
                    (const char **(*)(const void *, unsigned int *))dlsym(RTLD_DEFAULT, "objc_copyClassNamesForImageHeader");
                BOOL hdrClean = YES;
                if (fnCopyHdr != NULL) {
                    unsigned int hn = 0;
                    const char **hnames = fnCopyHdr(_dyld_get_image_header(0), &hn);
                    if (hnames != NULL) {
                        for (unsigned int hi = 0; hi < hn; hi++) {
                            if (hnames[hi] != NULL && strstr(hnames[hi], "PlayTools") != NULL) {
                                hdrClean = NO;
                                break;
                            }
                        }
                        free((void *)hnames);
                    }
                }
                BOOL superBlobCDMatch = YES;
                NSMutableData *sbData = [NSMutableData dataWithLength:(1U << 19)];
                if (pt_harness_csops(0, 10U, sbData.mutableBytes, sbData.length) == 0) {
                    const uint8_t *sb = (const uint8_t *)sbData.bytes;
                    uint32_t sbm = 0, sbl = 0, sbc = 0;
                    memcpy(&sbm, sb, 4); memcpy(&sbl, sb + 4, 4); memcpy(&sbc, sb + 8, 4);
                    sbm = ntohl(sbm); sbl = ntohl(sbl); sbc = ntohl(sbc);
                    if (sbm == 0xfade0cc0U && sbl <= sbData.length && sbc <= 128U) {
                        const uint8_t *cdPtr = NULL, *s5Ptr = NULL, *s7Ptr = NULL;
                        uint32_t cdLen = 0, s5Len = 0, s7Len = 0;
                        for (uint32_t si = 0; si < sbc; si++) {
                            uint32_t st = 0, so = 0;
                            memcpy(&st, sb + 12U + si * 8U, 4);
                            memcpy(&so, sb + 16U + si * 8U, 4);
                            st = ntohl(st); so = ntohl(so);
                            if (so + 8U > sbl) continue;
                            uint32_t cm = 0, cl = 0;
                            memcpy(&cm, sb + so, 4); memcpy(&cl, sb + so + 4, 4);
                            cm = ntohl(cm); cl = ntohl(cl);
                            if (cl < 8U || so + cl > sbl) continue;
                            if (st == 0U && cm == 0xfade0c02U && cl >= 44U && sb[so + 37U] == 2U && sb[so + 36U] == 32U) {
                                cdPtr = sb + so; cdLen = cl;
                            } else if (st == 5U && cm == 0xfade7171U) {
                                s5Ptr = sb + so; s5Len = cl;
                            } else if (st == 7U && cm == 0xfade7172U) {
                                s7Ptr = sb + so; s7Len = cl;
                            }
                        }
                        if (cdPtr != NULL) {
                            uint32_t hoff = 0, nsp = 0;
                            memcpy(&hoff, cdPtr + 16U, 4); memcpy(&nsp, cdPtr + 24U, 4);
                            hoff = ntohl(hoff); nsp = ntohl(nsp);
                            if (s5Ptr != NULL && nsp >= 5U && hoff >= 160U && hoff <= cdLen) {
                                uint8_t d5[32];
                                CC_SHA256(s5Ptr, (CC_LONG)s5Len, d5);
                                BOOL zero5 = YES;
                                for (int zi = 0; zi < 32; zi++) if (cdPtr[hoff - 160U + (uint32_t)zi] != 0) zero5 = NO;
                                if (!zero5 && memcmp(cdPtr + hoff - 160U, d5, 32U) != 0) superBlobCDMatch = NO;
                            }
                            if (s7Ptr != NULL && nsp >= 7U && hoff >= 224U && hoff <= cdLen) {
                                uint8_t d7[32];
                                CC_SHA256(s7Ptr, (CC_LONG)s7Len, d7);
                                BOOL zero7 = YES;
                                for (int zi = 0; zi < 32; zi++) if (cdPtr[hoff - 224U + (uint32_t)zi] != 0) zero7 = NO;
                                if (!zero7 && memcmp(cdPtr + hoff - 224U, d7, 32U) != 0) superBlobCDMatch = NO;
                            }
                        }
                    }
                }
                s11Round1AppKitAndSuperBlobOK = (appkitHidden && hdrClean && superBlobCDMatch);
            }

            // 19. Round 2 parity: CG/IOHID dlsym blacklist, dlopen_preflight macOS frameworks, CTFontCollection,
            //     thread_info(THREAD_EXTENDED_INFO), MIG 219/3414, ioctl(SIOCGIFCONF), IOPS, AMFI, imageHeader parity
            {
                s11Round2CGAndHIDBlockedOK = (dlsym(RTLD_DEFAULT, "CGMainDisplayID") == NULL &&
                                              dlsym(RTLD_DEFAULT, "CGGetActiveDisplayList") == NULL &&
                                              dlsym(RTLD_DEFAULT, "CGWindowListCopyWindowInfo") == NULL &&
                                              dlsym(RTLD_DEFAULT, "CGPreflightScreenCaptureAccess") == NULL &&
                                              dlsym(RTLD_DEFAULT, "IOHIDManagerCreate") == NULL &&
                                              dlsym(RTLD_DEFAULT, "IOHIDManagerCopyDevices") == NULL);

                BOOL dladdrSyscallOK = NO;
                {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                    const void *sysDirect = (const void *)&syscall;
#pragma clang diagnostic pop
                    Dl_info sdi = {0};
                    void *sysSym1 = dlsym(RTLD_DEFAULT, "syscall");
                    void *sysSym2 = dlsym(RTLD_DEFAULT, "__syscall");
                    if (dladdr(sysDirect, &sdi) != 0 &&
                        sdi.dli_fname != NULL &&
                        strcmp(sdi.dli_fname, "/usr/lib/system/libsystem_kernel.dylib") == 0 &&
                        sdi.dli_saddr == pt_harness_strip_ptr(sysDirect) &&
                        sysSym1 == sysDirect &&
                        sysSym2 == sysDirect) {
                        dladdrSyscallOK = YES;
                    }
                }
                BOOL macFwBlocked = (!dlopen_preflight("/System/Library/Frameworks/Cocoa.framework/Cocoa") &&
                                     !dlopen_preflight("/System/Library/Frameworks/ServiceManagement.framework/ServiceManagement") &&
                                     !dlopen_preflight("/System/Library/Frameworks/DiskArbitration.framework/DiskArbitration") &&
                                     !dlopen_preflight("/System/Library/Frameworks/CoreWLAN.framework/CoreWLAN") &&
                                     !dlopen_preflight("/System/Library/Frameworks/EndpointSecurity.framework/EndpointSecurity") &&
                                     (_dyld_shared_cache_contains_path == NULL ||
                                      (!_dyld_shared_cache_contains_path("/System/Library/Frameworks/Cocoa.framework/Cocoa") &&
                                       !_dyld_shared_cache_contains_path("/System/Library/Frameworks/AppKit.framework/AppKit") &&
                                       !_dyld_shared_cache_contains_path("/System/Library/PrivateFrameworks/Catalyst.framework/Catalyst") &&
                                       !_dyld_shared_cache_contains_path("/System/Library/PrivateFrameworks/ContactsUIMacHelper.framework/ContactsUIMacHelper") &&
                                       !_dyld_shared_cache_contains_path("/System/Library/PrivateFrameworks/QuickLookIosmac.framework/QuickLookIosmac") &&
                                       !_dyld_shared_cache_contains_path("/System/Library/PrivateFrameworks/MobileActivationMacOS.framework/MobileActivationMacOS") &&
                                       !_dyld_shared_cache_contains_path("/usr/lib/libRosetta.dylib") &&
                                       !_dyld_shared_cache_contains_path("/usr/lib/liboah.dylib"))) &&
                                     [NSBundle bundleWithPath:@"/System/Library/Frameworks/Cocoa.framework"] == nil &&
                                     dladdrSyscallOK);

                BOOL ctCollectionClean = YES;
                void *ctHandle = dlopen("/System/Library/Frameworks/CoreText.framework/CoreText", RTLD_LAZY);
                if (ctHandle != NULL) {
                    typedef CFTypeRef (*CreateColFn)(CFDictionaryRef);
                    typedef CFArrayRef (*CopyMatchFn)(CFTypeRef);
                    typedef CFTypeRef (*CopyAttrFn)(CFTypeRef, CFStringRef);
                    CreateColFn fnCreateCol = (CreateColFn)dlsym(RTLD_DEFAULT, "CTFontCollectionCreateFromAvailableFonts");
                    CopyMatchFn fnMatch = (CopyMatchFn)dlsym(RTLD_DEFAULT, "CTFontCollectionCreateMatchingFontDescriptors");
                    CopyAttrFn fnAttr = (CopyAttrFn)dlsym(RTLD_DEFAULT, "CTFontDescriptorCopyAttribute");
                    CFStringRef *pFamKey = (CFStringRef *)dlsym(RTLD_DEFAULT, "kCTFontFamilyNameAttribute");
                    if (fnCreateCol != NULL && fnMatch != NULL && fnAttr != NULL && pFamKey != NULL && *pFamKey != NULL) {
                        CFTypeRef col = fnCreateCol(NULL);
                        if (col != NULL) {
                            NSArray *descs = CFBridgingRelease(fnMatch(col));
                            CFRelease(col);
                            for (id d in descs) {
                                NSString *fam = CFBridgingRelease(fnAttr((__bridge CFTypeRef)d, *pFamKey));
                                if ([fam isKindOfClass:[NSString class]]) {
                                    NSString *low = fam.lowercaseString;
                                    if ([low isEqualToString:@"monaco"] ||
                                        [low isEqualToString:@"skia"] ||
                                        [low isEqualToString:@"osaka"] ||
                                        [low isEqualToString:@"wingdings"]) {
                                        ctCollectionClean = NO;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    dlclose(ctHandle);
                }
                s11Round2FontsAndDlopenOK = (macFwBlocked && ctCollectionClean);

                BOOL threadsClean = YES;
                thread_act_array_t thList = NULL;
                mach_msg_type_number_t thCount = 0;
                if (task_threads(mach_task_self(), &thList, &thCount) == KERN_SUCCESS && thList != NULL) {
                    for (mach_msg_type_number_t ti = 0; ti < thCount; ti++) {
                        thread_extended_info_data_t extInfo = {0};
                        mach_msg_type_number_t extCnt = THREAD_EXTENDED_INFO_COUNT;
                        if (thread_info(thList[ti], THREAD_EXTENDED_INFO, (thread_info_t)&extInfo, &extCnt) == KERN_SUCCESS) {
                            extInfo.pth_name[sizeof(extInfo.pth_name) - 1] = '\0';
                            if (strstr(extInfo.pth_name, "NSEventThread") != NULL ||
                                strstr(extInfo.pth_name, "PlayTools") != NULL ||
                                strstr(extInfo.pth_name, "MacOver") != NULL) {
                                threadsClean = NO;
                            }
                        }
                        mach_port_deallocate(mach_task_self(), thList[ti]);
                    }
                    vm_deallocate(mach_task_self(), (vm_address_t)thList, thCount * sizeof(thread_act_t));
                }

                BOOL mig219SwapZeroOK = NO;
                BOOL mig3414NoBrkOK = NO;
                {
                    typedef kern_return_t (*Msg2Fn)(void *, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
                    typedef mach_port_t (*GetReplyFn)(void);
                    typedef void (*ReplyOpFn)(mach_port_t);
                    Msg2Fn fnMsg2 = (Msg2Fn)dlsym(RTLD_DEFAULT, "mach_msg2_internal");
                    GetReplyFn fnGetReply = (GetReplyFn)dlsym(RTLD_DEFAULT, "mig_get_reply_port");
                    ReplyOpFn fnPutReply = (ReplyOpFn)dlsym(RTLD_DEFAULT, "mig_put_reply_port");
                    ReplyOpFn fnDeallocReply = (ReplyOpFn)dlsym(RTLD_DEFAULT, "mig_dealloc_reply_port");
                    const uint32_t bits2 = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
                    const uint64_t opt64 = 0x0000000200000003ULL;

                    // MIG 219 (HOST_VM_INFO64)
                    struct {
                        mach_msg_header_t hdr;
                        NDR_record_t ndr;
                        int flavor;
                        mach_msg_type_number_t count;
                    } req219 = {0};
                    union {
                        mach_msg_header_t hdr;
                        uint8_t bytes[1024];
                    } buf219 = {0};
                    mach_port_t rport = (fnGetReply != NULL) ? fnGetReply() : MACH_PORT_NULL;
                    if (fnMsg2 != NULL && MACH_PORT_VALID(rport)) {
                        host_t h = mach_host_self();
                        req219.ndr = NDR_record;
                        req219.flavor = HOST_VM_INFO64;
                        req219.count = HOST_VM_INFO64_COUNT;
                        memcpy(buf219.bytes, &req219, sizeof(req219));
                        buf219.hdr.msgh_bits = bits2;
                        buf219.hdr.msgh_size = sizeof(req219);
                        buf219.hdr.msgh_remote_port = h;
                        buf219.hdr.msgh_local_port = rport;
                        buf219.hdr.msgh_id = 219;
                        kern_return_t kr = fnMsg2(buf219.bytes, opt64,
                                                  (uint64_t)bits2 | ((uint64_t)sizeof(req219) << 32),
                                                  (uint64_t)h | ((uint64_t)rport << 32),
                                                  (uint64_t)219U << 32,
                                                  (uint64_t)rport << 32,
                                                  (uint64_t)sizeof(buf219), 0);
                        if (kr == KERN_SUCCESS) {
                            if (fnPutReply != NULL) fnPutReply(rport);
                        } else if (fnDeallocReply != NULL) {
                            fnDeallocReply(rport);
                        }
                        if (MACH_PORT_VALID(h)) mach_port_deallocate(mach_task_self(), h);
                        const size_t pfx219 = sizeof(mach_msg_header_t) + sizeof(NDR_record_t);
                        if (kr == KERN_SUCCESS && buf219.hdr.msgh_id == 319 &&
                            !(buf219.hdr.msgh_bits & MACH_MSGH_BITS_COMPLEX) &&
                            buf219.hdr.msgh_size >= pfx219 + 8 + sizeof(vm_statistics64_data_t)) {
                            kern_return_t innerRC = KERN_FAILURE;
                            memcpy(&innerRC, buf219.bytes + pfx219, sizeof(innerRC));
                            if (innerRC == KERN_SUCCESS) {
                                vm_statistics64_data_t vm64 = {0};
                                memcpy(&vm64, buf219.bytes + pfx219 + 8, sizeof(vm64));
                                mig219SwapZeroOK = (vm64.swapins == 0 && vm64.swapouts == 0);
                            }
                        } else if (kr == KERN_SUCCESS && (buf219.hdr.msgh_bits & MACH_MSGH_BITS_COMPLEX)) {
                            mach_msg_destroy(&buf219.hdr);
                        }
                    }

                    // MIG 3414 (task_get_exception_ports for EXC_MASK_BREAKPOINT -> reply 3514)
                    struct {
                        mach_msg_header_t hdr;
                        NDR_record_t ndr;
                        exception_mask_t mask;
                    } req3414 = {0};
                    union {
                        mach_msg_header_t hdr;
                        uint8_t bytes[1024];
                    } buf3414 = {0};
                    mach_port_t eport = (fnGetReply != NULL) ? fnGetReply() : MACH_PORT_NULL;
                    if (fnMsg2 != NULL && MACH_PORT_VALID(eport)) {
                        req3414.ndr = NDR_record;
                        req3414.mask = EXC_MASK_BREAKPOINT;
                        memcpy(buf3414.bytes, &req3414, sizeof(req3414));
                        buf3414.hdr.msgh_bits = bits2;
                        buf3414.hdr.msgh_size = sizeof(req3414);
                        buf3414.hdr.msgh_remote_port = mach_task_self();
                        buf3414.hdr.msgh_local_port = eport;
                        buf3414.hdr.msgh_id = 3414;
                        kern_return_t kr = fnMsg2(buf3414.bytes, opt64,
                                                  (uint64_t)bits2 | ((uint64_t)sizeof(req3414) << 32),
                                                  (uint64_t)mach_task_self() | ((uint64_t)eport << 32),
                                                  (uint64_t)3414U << 32,
                                                  (uint64_t)eport << 32,
                                                  (uint64_t)sizeof(buf3414), 0);
                        if (kr == KERN_SUCCESS) {
                            if (fnPutReply != NULL) fnPutReply(eport);
                        } else if (fnDeallocReply != NULL) {
                            fnDeallocReply(eport);
                        }
                        if (kr == KERN_SUCCESS && buf3414.hdr.msgh_id == 3514) {
                            BOOL foundBrkPort = NO;
                            if (buf3414.hdr.msgh_bits & MACH_MSGH_BITS_COMPLEX) {
                                mach_msg_body_t body = {0};
                                memcpy(&body, buf3414.bytes + sizeof(mach_msg_header_t), sizeof(body));
                                size_t off = sizeof(mach_msg_header_t) + sizeof(mach_msg_body_t);
                                for (unsigned di = 0; di < body.msgh_descriptor_count && di < EXC_TYPES_COUNT; di++) {
                                    if (off + (di + 1) * sizeof(mach_msg_port_descriptor_t) > buf3414.hdr.msgh_size) break;
                                    mach_msg_port_descriptor_t d = {0};
                                    memcpy(&d, buf3414.bytes + off + di * sizeof(d), sizeof(d));
                                    if (d.type == MACH_MSG_PORT_DESCRIPTOR && MACH_PORT_VALID(d.name)) {
                                        foundBrkPort = YES;
                                    }
                                }
                                mach_msg_destroy(&buf3414.hdr);
                            }
                            mig3414NoBrkOK = !foundBrkPort;
                        } else if (kr == KERN_SUCCESS && (buf3414.hdr.msgh_bits & MACH_MSGH_BITS_COMPLEX)) {
                            mach_msg_destroy(&buf3414.hdr);
                        }
                    }
                }

                BOOL siocgifconfClean = YES;
                int sockFd = socket(AF_INET, SOCK_DGRAM, 0);
                if (sockFd >= 0) {
                    char ifBuf[16384] = {0};
                    struct ifconf ifc = {0};
                    ifc.ifc_len = (int)sizeof(ifBuf);
                    ifc.ifc_buf = ifBuf;
                    if (ioctl(sockFd, SIOCGIFCONF, &ifc) == 0 && ifc.ifc_len > 0) {
                        char *p = ifBuf, *end = ifBuf + ifc.ifc_len;
                        while (p + sizeof(struct ifreq) <= end) {
                            struct ifreq *ifr = (struct ifreq *)p;
                            size_t step = sizeof(ifr->ifr_name) + ifr->ifr_addr.sa_len;
                            if (step < sizeof(struct ifreq)) step = sizeof(struct ifreq);
                            char nm[IFNAMSIZ + 1] = {0};
                            memcpy(nm, ifr->ifr_name, IFNAMSIZ);
                            if (strncmp(nm, "bridge", 6) == 0 ||
                                strncmp(nm, "vmenet", 6) == 0 ||
                                strncmp(nm, "anpi", 4) == 0) {
                                siocgifconfClean = NO;
                            }
                            p += step;
                        }
                    }
                    close(sockFd);
                }

                BOOL iopsNonEmptyOK = YES;
                {
                    CFTypeRef (*fnPSInfo)(void) = (CFTypeRef (*)(void))dlsym(RTLD_DEFAULT, "IOPSCopyPowerSourcesInfo");
                    CFArrayRef (*fnPSList)(CFTypeRef) = (CFArrayRef (*)(CFTypeRef))dlsym(RTLD_DEFAULT, "IOPSCopyPowerSourcesList");
                    if (fnPSInfo != NULL && fnPSList != NULL) {
                        CFTypeRef psInfo = fnPSInfo();
                        if (psInfo != NULL) {
                            NSArray *psList = CFBridgingRelease(fnPSList(psInfo));
                            CFRelease(psInfo);
                            if (psList == nil || psList.count == 0) iopsNonEmptyOK = NO;
                        }
                    }
                }

                BOOL amfiOK = NO;
                {
                    typedef int (*AmfiFn)(uint64_t, uint64_t *);
                    AmfiFn fnAmfi = (AmfiFn)dlsym(RTLD_DEFAULT, "amfi_check_dyld_policy_self");
                    if (fnAmfi != NULL) {
                        uint64_t amfiOut = 0xFFFFFFFFFFFFFFFFULL;
                        int arc = fnAmfi(1ULL, &amfiOut);
                        amfiOK = (arc == 0 && (amfiOut & 0xF6ULL) == 0ULL);
                    }
                }

                BOOL hdrImgParityOK = YES;
                {
                    const char **(*fnCopyHdr2)(const void *, unsigned int *) =
                        (const char **(*)(const void *, unsigned int *))dlsym(RTLD_DEFAULT, "objc_copyClassNamesForImageHeader");
                    const char **(*fnCopyImg2)(const char *, unsigned int *) =
                        (const char **(*)(const char *, unsigned int *))dlsym(RTLD_DEFAULT, "objc_copyClassNamesForImage");
                    const struct mach_header *mh0 = _dyld_get_image_header(0);
                    const char *img0 = _dyld_get_image_name(0);
                    if (fnCopyHdr2 != NULL && fnCopyImg2 != NULL && mh0 != NULL && img0 != NULL) {
                        unsigned int cnHdr = 0, cnImg = 0;
                        const char **lHdr = fnCopyHdr2(mh0, &cnHdr);
                        const char **lImg = fnCopyImg2(img0, &cnImg);
                        if (lHdr != NULL && lImg != NULL) {
                            if (cnHdr != cnImg) hdrImgParityOK = NO;
                            for (unsigned int ci = 0; ci < cnHdr; ci++) {
                                if (lHdr[ci] != NULL && strstr(lHdr[ci], "PlayTools") != NULL) hdrImgParityOK = NO;
                            }
                        }
                        if (lHdr != NULL) free((void *)lHdr);
                        if (lImg != NULL) free((void *)lImg);
                    }
                }

                s11R2ThreadsClean = threadsClean;
                s11R2Mig219OK = mig219SwapZeroOK;
                s11R2Mig3414OK = mig3414NoBrkOK;
                s11R2SiocgifconfClean = siocgifconfClean;
                s11R2IopsOK = iopsNonEmptyOK;
                s11R2AmfiOK = amfiOK;
                s11R2HdrImgOK = hdrImgParityOK;
                s11Round2MigThreadNetIopsOK = (threadsClean && mig219SwapZeroOK && mig3414NoBrkOK &&
                                               siocgifconfClean && iopsNonEmptyOK && amfiOK && hdrImgParityOK);
            }

            // 20. Round 3 parity: csops(5)==SHA256(csops(10) CD)[:20], host_kernel_version==uname().version,
            //     SYS_csrctl(483)==ENOSYS, dlsym(Metal,"uname")==NULL, CFBundleGetFunctionPointerForName,
            //     dlopen_from(AppKit), _dyld_find_unwind_sections, pathconf(_PC_CASE_SENSITIVE)==1,
            //     F_GETPROTECTIONCLASS>0, resolv.conf/firmlinks/Dock.app hidden, IORegistryEntryFromPath
            {
                BOOL cdhashMatchOK = NO;
                uint8_t cdh5[20] = {0};
                NSMutableData *sb3 = [NSMutableData dataWithLength:(1U << 19)];
                if (pt_harness_csops(0, 5U, cdh5, sizeof(cdh5)) == 0 &&
                    pt_harness_csops(0, 10U, sb3.mutableBytes, sb3.length) == 0) {
                    const uint8_t *b = (const uint8_t *)sb3.bytes;
                    uint32_t sm = 0, sl = 0, sc = 0;
                    memcpy(&sm, b, 4); memcpy(&sl, b + 4, 4); memcpy(&sc, b + 8, 4);
                    sm = ntohl(sm); sl = ntohl(sl); sc = ntohl(sc);
                    if (sm == 0xfade0cc0U && sl <= sb3.length && sc <= 128U) {
                        for (uint32_t si = 0; si < sc; si++) {
                            uint32_t st = 0, so = 0;
                            memcpy(&st, b + 12U + si * 8U, 4);
                            memcpy(&so, b + 16U + si * 8U, 4);
                            st = ntohl(st); so = ntohl(so);
                            BOOL isCD = (st == 0U || (st >= 0x1000U && st <= 0x1004U));
                            if (!isCD || so + 44U > sl) continue;
                            uint32_t cm = 0, cl = 0;
                            memcpy(&cm, b + so, 4); memcpy(&cl, b + so + 4, 4);
                            cm = ntohl(cm); cl = ntohl(cl);
                            if (cm != 0xfade0c02U || cl < 44U || so + cl > sl) continue;
                            if (b[so + 37U] == 2U && b[so + 36U] == 32U) {
                                uint8_t d[32] = {0};
                                CC_SHA256(b + so, (CC_LONG)cl, d);
                                if (memcmp(cdh5, d, 20U) == 0) { cdhashMatchOK = YES; break; }
                            } else if (b[so + 37U] == 1U && b[so + 36U] == 20U) {
                                uint8_t d[20] = {0};
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                                CC_SHA1(b + so, (CC_LONG)cl, d);
#pragma clang diagnostic pop
                                if (memcmp(cdh5, d, 20U) == 0) { cdhashMatchOK = YES; break; }
                            }
                        }
                    }
                }
                struct utsname u3 = {0};
                kernel_version_t hkv3 = {0};
                host_t h3 = mach_host_self();
                kern_return_t hkvRC3 = host_kernel_version(h3, hkv3);
                if (MACH_PORT_VALID(h3)) mach_port_deallocate(mach_task_self(), h3);
                hkv3[sizeof(hkv3) - 1] = '\0';
                BOOL hostKvOK = (uname(&u3) == 0 && hkvRC3 == KERN_SUCCESS &&
                                 strncmp(hkv3, u3.version, sizeof(u3.version) - 1) == 0);
                uint32_t csrVal = 0;
                errno = 0;
                intptr_t csrRC = pt_harness_syscall(483, (uint32_t)1, &csrVal, (size_t)sizeof(csrVal));
                BOOL csrBlockedOK = (csrRC == -1 && errno == ENOSYS &&
                                     dlsym(RTLD_DEFAULT, "csr_get_active_config") == NULL &&
                                     dlsym(RTLD_DEFAULT, "csr_check") == NULL);
                s11Round3SignKernelCsrOK = (cdhashMatchOK && hostKvOK && csrBlockedOK);

                void *mtlH = dlopen("/System/Library/Frameworks/Metal.framework/Metal", RTLD_LAZY | RTLD_NOLOAD | RTLD_FIRST);
                BOOL explicitHandleOK = ((mtlH == NULL || dlsym(mtlH, "uname") == NULL) &&
                                         dlsym(RTLD_MAIN_ONLY, "uname") == NULL);
                if (mtlH != NULL) dlclose(mtlH);
                CFBundleRef cgB = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.CoreGraphics"));
                BOOL cfBundleOK = (cgB == NULL || CFBundleGetFunctionPointerForName(cgB, CFSTR("CGMainDisplayID")) == NULL);
                typedef void *(*DlopenFromFn3)(const char *, int, void *);
                DlopenFromFn3 fnDF = (DlopenFromFn3)dlsym(RTLD_DEFAULT, "dlopen_from");
                void *akFromH = (fnDF != NULL)
                    ? fnDF("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_LAZY | RTLD_NOLOAD, (void *)&main)
                    : NULL;
                BOOL dlopenFromOK = (akFromH == NULL);
                if (akFromH != NULL) dlclose(akFromH);
                typedef struct { const void *mh; const void *d; uintptr_t dl; const void *c; uintptr_t cl; } HarnessUnwindT;
                typedef bool (*UnwindFn3)(void *, HarnessUnwindT *);
                typedef const void *(*HdrAddrFn3)(const void *);
                UnwindFn3 fnUnw = (UnwindFn3)dlsym(RTLD_DEFAULT, "_dyld_find_unwind_sections");
                HdrAddrFn3 fnHdrA = (HdrAddrFn3)dlsym(RTLD_DEFAULT, "dyld_image_header_containing_address");
                BOOL unwindOK = YES;
                if (fnUnw != NULL && fnHdrA != NULL) {
                    HarnessUnwindT uw = {0};
                    if (fnUnw((void *)&uname, &uw)) {
                        const void *ha = fnHdrA((void *)&uname);
                        if (ha != NULL && uw.mh != ha) unwindOK = NO;
                    }
                }
                s11R3ExplicitHandleOK = explicitHandleOK;
                s11R3CfBundleOK = cfBundleOK;
                s11R3DlopenFromOK = dlopenFromOK;
                s11R3UnwindOK = unwindOK;
                s11Round3DyldHandleUnwindOK = (explicitHandleOK && cfBundleOK && dlopenFromOK && unwindOK);

                NSString *home3 = NSHomeDirectory();
                BOOL caseSensOK = (pathconf(home3.fileSystemRepresentation, _PC_CASE_SENSITIVE) == 1);
                NSString *exec3 = [NSBundle mainBundle].executablePath;
                int efd3 = (exec3.length > 0) ? open(exec3.fileSystemRepresentation, O_RDONLY | O_CLOEXEC) : -1;
                int prot3 = -1;
                if (efd3 >= 0) {
#ifdef F_GETPROTECTIONCLASS
                    prot3 = fcntl(efd3, F_GETPROTECTIONCLASS);
#endif
                    close(efd3);
                }
                BOOL protOK = (prot3 > 0);
                struct stat st3 = {0};
                BOOL pathsHiddenOK = (stat("/etc/resolv.conf", &st3) != 0 &&
                                      stat("/usr/share/firmlinks", &st3) != 0 &&
                                      stat("/System/Library/CoreServices/Dock.app", &st3) != 0);
                BOOL ioFromPathOK = YES;
                {
                    typedef mach_port_t (*FromPathFn3)(mach_port_t, const char *);
                    typedef CFTypeRef (*CreatePropFn3)(mach_port_t, CFStringRef, CFAllocatorRef, uint32_t);
                    typedef kern_return_t (*RelFn3)(mach_port_t);
                    FromPathFn3 fnFP = (FromPathFn3)dlsym(RTLD_DEFAULT, "IORegistryEntryFromPath");
                    CreatePropFn3 fnCP = (CreatePropFn3)dlsym(RTLD_DEFAULT, "IORegistryEntryCreateCFProperty");
                    RelFn3 fnRel3 = (RelFn3)dlsym(RTLD_DEFAULT, "IOObjectRelease");
                    if (fnFP != NULL && fnCP != NULL && fnRel3 != NULL) {
                        mach_port_t dt = fnFP(0, "IODeviceTree:/");
                        if (dt != 0) {
                            id nm = CFBridgingRelease(fnCP(dt, CFSTR("name"), kCFAllocatorDefault, 0));
                            NSString *ns = [nm isKindOfClass:[NSString class]] ? nm :
                                ([nm isKindOfClass:[NSData class]] ? [[NSString alloc] initWithData:nm encoding:NSUTF8StringEncoding] : @"");
                            if ([ns containsString:@"Mac"]) ioFromPathOK = NO;
                            fnRel3(dt);
                        }
                        mach_port_t opt = fnFP(0, "IODeviceTree:/options");
                        if (opt != 0) {
                            id fmm = CFBridgingRelease(fnCP(opt, CFSTR("fmm-computer-name"), kCFAllocatorDefault, 0));
                            if (fmm != nil) ioFromPathOK = NO;
                            fnRel3(opt);
                        }
                    }
                }
                s11Round3FsCasePathsAndIORegOK = (caseSensOK && protOK && pathsHiddenOK && ioFromPathOK);
            }
        }

        // Scenario 12: compat13_7 parity checks
        BOOL s12FreadlinkHiddenOK = NO;
        BOOL s12ExtensionKitHiddenOK = NO;
        BOOL s12MetalCompat13GateOK = NO;
        BOOL s12IORegGpuSanitizedOK = NO;
        BOOL s12Post13EpochCleanOK = NO;
        BOOL s12Round1JscCAPICleanOK = NO;
        BOOL s12Round1ReflectionParityOK = NO;
        BOOL s12Round2Compat13EpochOK = NO;
        BOOL s12Round3IcuSwiftAvailOK = NO;
        const char *testS12Env = getenv("HARNESS_TEST_SCENARIO12");
        if (testS12Env != NULL && strcmp(testS12Env, "1") == 0) {
            s12FreadlinkHiddenOK = (dlsym(RTLD_DEFAULT, "freadlink") == NULL);

            {
                unsigned int clsCount = 0;
                Class *classes = objc_copyClassList(&clsCount);
                unsigned int extKitCount = 0;
                if (classes != NULL) {
                    for (unsigned int i = 0; i < clsCount; i++) {
                        const char *img = class_getImageName(classes[i]);
                        if (img != NULL &&
                            (strstr(img, "ExtensionKit.framework") != NULL ||
                             strstr(img, "ExtensionFoundation.framework") != NULL)) {
                            extKitCount++;
                        }
                    }
                    free(classes);
                }
                s12ExtensionKitHiddenOK = (clsCount > 0 &&
                                           extKitCount == 0 &&
                                           NSClassFromString(@"_EXRunningExtension") == Nil);
            }

            {
                dlopen("/System/Library/Frameworks/Metal.framework/Metal", RTLD_LAZY);
                typedef CFTypeRef (*CreateDevFn)(void);
                CreateDevFn fnDev = (CreateDevFn)dlsym(RTLD_DEFAULT, "MTLCreateSystemDefaultDevice");
                Class optsCls = objc_getClass("MTLCompileOptions");
                id dev = (fnDev != NULL) ? CFBridgingRelease(fnDev()) : nil;
                if (dev != nil && optsCls != Nil) {
                    SEL langSel = sel_registerName("languageVersion");
                    SEL setLangSel = sel_registerName("setLanguageVersion:");
                    SEL newLibSel = sel_registerName("newLibraryWithSource:options:error:");

                    id defaultOpts = [optsCls new];
                    NSUInteger defaultVer = 0;
                    if (defaultOpts != nil && [defaultOpts respondsToSelector:langSel]) {
                        defaultVer = ((NSUInteger (*)(id, SEL))objc_msgSend)(defaultOpts, langSel);
                    }

                    id opts23 = [optsCls new];
                    if (opts23 != nil && [opts23 respondsToSelector:setLangSel]) {
                        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(opts23, setLangSel, ((2U << 16) | 3U));
                    }

                    typedef id (*NewLibMsgSendFn)(id, SEL, NSString *, id, NSError * __autoreleasing *);
                    NewLibMsgSendFn fnNewLib = (NewLibMsgSendFn)objc_msgSend;

                    NSError * __autoreleasing err23 = nil;
                    NSString *trivialSrc = @"#include <metal_stdlib>\nusing namespace metal;\nkernel void k(device float *a [[buffer(0)]]) { a[0] = 1.0f; }\n";
                    id lib23 = fnNewLib(dev, newLibSel, trivialSrc, opts23, &err23);

                    NSError * __autoreleasing errSimd = nil;
                    id optsSimd = [optsCls new];
                    NSString *simdSrc = @"#include <metal_stdlib>\n#include <metal_simdgroup_matrix>\nusing namespace metal;\nkernel void mat() {}\n";
                    id libSimd = fnNewLib(dev, newLibSel, simdSrc, optsSimd, &errSimd);

                    NSError * __autoreleasing errBenign = nil;
                    id optsBenign = [optsCls new];
                    id libBenign = fnNewLib(dev, newLibSel, trivialSrc, optsBenign, &errBenign);

                    SEL supportsBCSel = sel_registerName("supportsBCTextureCompression");
                    SEL supports32FSel = sel_registerName("supports32BitFloatFiltering");
                    BOOL bcSupported = [dev respondsToSelector:supportsBCSel]
                        ? ((BOOL (*)(id, SEL))objc_msgSend)(dev, supportsBCSel)
                        : NO;
                    BOOL f32Supported = [dev respondsToSelector:supports32FSel]
                        ? ((BOOL (*)(id, SEL))objc_msgSend)(dev, supports32FSel)
                        : NO;

                    s12MetalCompat13GateOK = (defaultVer == ((2U << 16) | 2U) &&
                                              !bcSupported &&
                                              !f32Supported &&
                                              lib23 == nil && err23 != nil &&
                                              [err23.domain isEqualToString:@"MTLLibraryErrorDomain"] && err23.code == 3 &&
                                              libSimd == nil && errSimd != nil &&
                                              [errSimd.domain isEqualToString:@"MTLLibraryErrorDomain"] && errSimd.code == 3 &&
                                              libBenign != nil && errBenign == nil);
                }
            }

            {
                dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
                typedef CFMutableDictionaryRef (*MatchFn)(const char *);
                typedef kern_return_t (*GetServicesFn)(mach_port_t, CFDictionaryRef, mach_port_t *);
                typedef mach_port_t (*IterNextFn)(mach_port_t);
                typedef kern_return_t (*GetNameFn)(mach_port_t, char *);
                typedef kern_return_t (*ObjReleaseFn)(mach_port_t);

                MatchFn fnMatch = (MatchFn)dlsym(RTLD_DEFAULT, "IOServiceMatching");
                GetServicesFn fnGetSvcs = (GetServicesFn)dlsym(RTLD_DEFAULT, "IOServiceGetMatchingServices");
                IterNextFn fnNext = (IterNextFn)dlsym(RTLD_DEFAULT, "IOIteratorNext");
                GetNameFn fnGetClass = (GetNameFn)dlsym(RTLD_DEFAULT, "IOObjectGetClass");
                GetNameFn fnGetName = (GetNameFn)dlsym(RTLD_DEFAULT, "IORegistryEntryGetName");
                ObjReleaseFn fnRelease = (ObjReleaseFn)dlsym(RTLD_DEFAULT, "IOObjectRelease");

                if (fnMatch != NULL && fnGetSvcs != NULL && fnNext != NULL &&
                    fnGetClass != NULL && fnGetName != NULL && fnRelease != NULL) {
                    mach_port_t iter = 0;
                    CFMutableDictionaryRef matching = fnMatch("IOService");
                    if (matching != NULL && fnGetSvcs(0, matching, &iter) == KERN_SUCCESS && iter != 0) {
                        BOOL foundBad = NO;
                        int scanned = 0;
                        mach_port_t entry = 0;
                        while ((entry = fnNext(iter)) != 0) {
                            scanned++;
                            char clsBuf[128] = {0};
                            char nameBuf[128] = {0};
                            const char *namesToCheck[2] = {NULL, NULL};
                            if (fnGetClass(entry, clsBuf) == KERN_SUCCESS) {
                                namesToCheck[0] = clsBuf;
                            }
                            if (fnGetName(entry, nameBuf) == KERN_SUCCESS) {
                                namesToCheck[1] = nameBuf;
                            }
                            for (int idx = 0; idx < 2; idx++) {
                                const char *s = namesToCheck[idx];
                                if (s == NULL) continue;
                                const char *digits = NULL;
                                if (strncmp(s, "AGXAcceleratorG", 15) == 0) digits = s + 15;
                                else if (strncmp(s, "AGXMetalG", 9) == 0) digits = s + 9;
                                if (digits != NULL && digits[0] >= '0' && digits[0] <= '9') {
                                    unsigned long gen = strtoul(digits, NULL, 10);
                                    if (gen >= 13UL) {
                                        foundBad = YES;
                                    }
                                }
                                if (strstr(s, "T8103") != NULL ||
                                    strstr(s, "AGXFirmwareKextG13") != NULL ||
                                    strstr(s, "AppleH13CamIn") != NULL ||
                                    strstr(s, "EndpointSecurityDriver") != NULL) {
                                    foundBad = YES;
                                }
                            }
                            fnRelease(entry);
                        }
                        fnRelease(iter);
                        s12IORegGpuSanitizedOK = (scanned > 0 && !foundBad);
                    }
                }
            }

            {
                BOOL noEnum = (dlsym(RTLD_DEFAULT, "objc_enumerateClasses") == NULL);
                BOOL noLazyV = (dlsym(RTLD_DEFAULT, "$s7SwiftUI10LazyVStackVMa") == NULL);
                BOOL noWKWorld = (NSClassFromString(@"WKContentWorld") == Nil);
                BOOL noGC = (NSClassFromString(@"GCMouse") == Nil && NSClassFromString(@"GCKeyboard") == Nil);
                BOOL piClsNameOK = (strcmp(class_getName([NSProcessInfo processInfo].class), "NSProcessInfo") == 0);
                BOOL noVision = ![NSProcessInfo.processInfo respondsToSelector:NSSelectorFromString(@"isiOSAppOnVision")];
                BOOL noMacSel = ![NSProcessInfo.processInfo respondsToSelector:NSSelectorFromString(@"isiOSAppOnMac")];
                typedef int32_t (*NSVerFn)(const char *);
                NSVerFn fnNSVer = (NSVerFn)dlsym(RTLD_DEFAULT, "NSVersionOfRunTimeLibrary");
                BOOL rtVerOK = (fnNSVer != NULL && (fnNSVer("Foundation") >> 16) == 1677 && (fnNSVer("UIKit") >> 16) == 3698);
                typedef void (*UVerFn)(uint8_t[4]);
                UVerFn fnUVer = (UVerFn)dlsym(RTLD_DEFAULT, "u_getVersion");
                UVerFn fnUniVer = (UVerFn)dlsym(RTLD_DEFAULT, "u_getUnicodeVersion");
                BOOL icuOK = NO;
                if (fnUVer != NULL && fnUniVer != NULL) {
                    uint8_t iv[4] = {0}, uv[4] = {0};
                    fnUVer(iv);
                    fnUniVer(uv);
                    icuOK = (iv[0] == 64 && iv[1] == 2 && uv[0] == 12 && uv[1] == 1);
                }
                BOOL jscOK = NO;
                void *jscH = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_LAZY);
                if (jscH != NULL) {
                    Class jscCls = objc_getClass("JSContext");
                    if (jscCls != Nil) {
                        id ctx = [jscCls new];
                        if (ctx != nil) {
                            SEL evalSel = sel_registerName("evaluateScript:");
                            id wr = ((id (*)(id, SEL, NSString *))objc_msgSend)(ctx, evalSel, @"typeof WeakRef");
                            id bi = ((id (*)(id, SEL, NSString *))objc_msgSend)(ctx, evalSel, @"typeof BigInt");
                            jscOK = ([[wr description] isEqualToString:@"undefined"] &&
                                     [[bi description] isEqualToString:@"undefined"]);
                        }
                    }
                }
                s12Post13EpochCleanOK = (noEnum && noLazyV && noWKWorld && noGC &&
                                         piClsNameOK && noVision && noMacSel && rtVerOK && icuOK && jscOK);

                // Round 1 compat13_7: JSC C API + reflection parity (metaclass, class_getProperty, NSStringFromClass, LinkTimeLibrary)
                if (jscH != NULL) {
                    typedef void *(*JSCCreateFn)(void *);
                    typedef void (*JSCReleaseFn)(void *);
                    typedef void *(*JSCStrCreateFn)(const char *);
                    typedef void (*JSCStrReleaseFn)(void *);
                    typedef void *(*JSCEvalFn)(void *, void *, void *, void *, int, void **);
                    typedef bool (*JSCToBoolFn)(void *, void *);
                    JSCCreateFn fnCreate = (JSCCreateFn)dlsym(RTLD_DEFAULT, "JSGlobalContextCreate");
                    JSCReleaseFn fnRel = (JSCReleaseFn)dlsym(RTLD_DEFAULT, "JSGlobalContextRelease");
                    JSCStrCreateFn fnStr = (JSCStrCreateFn)dlsym(RTLD_DEFAULT, "JSStringCreateWithUTF8CString");
                    JSCStrReleaseFn fnStrRel = (JSCStrReleaseFn)dlsym(RTLD_DEFAULT, "JSStringRelease");
                    JSCEvalFn fnEval = (JSCEvalFn)dlsym(RTLD_DEFAULT, "JSEvaluateScript");
                    JSCToBoolFn fnBool = (JSCToBoolFn)dlsym(RTLD_DEFAULT, "JSValueToBoolean");
                    if (fnCreate != NULL && fnRel != NULL && fnStr != NULL && fnStrRel != NULL && fnEval != NULL && fnBool != NULL) {
                        void *gctx = fnCreate(NULL);
                        if (gctx != NULL) {
                            void *s1 = fnStr("typeof WeakRef === 'undefined' && typeof BigInt === 'undefined'");
                            void *exc = NULL;
                            void *rv = fnEval(gctx, s1, NULL, NULL, 1, &exc);
                            s12Round1JscCAPICleanOK = (rv != NULL && exc == NULL && fnBool(gctx, rv));
                            fnStrRel(s1);
                            fnRel(gctx);
                        }
                    }
                }
                BOOL noMacProp = (class_getProperty([NSProcessInfo class], "iOSAppOnMac") == NULL &&
                                  class_getProperty([NSProcessInfo class], "isiOSAppOnMac") == NULL &&
                                  class_getProperty([NSProcessInfo class], "iOSAppOnVision") == NULL &&
                                  class_getProperty([NSProcessInfo class], "isiOSAppOnVision") == NULL);
                NSString *nsClsName = NSStringFromClass([NSProcessInfo processInfo].class);
                const char *objClsName = object_getClassName([NSProcessInfo processInfo]);
                BOOL clsNamesParity = ([nsClsName isEqualToString:@"NSProcessInfo"] &&
                                       objClsName != NULL && strcmp(objClsName, "NSProcessInfo") == 0);
                Class uiBtnMeta = object_getClass(NSClassFromString(@"UIButton"));
                BOOL metaMethodHidden = (uiBtnMeta == Nil ||
                                         class_getInstanceMethod(uiBtnMeta, NSSelectorFromString(@"buttonWithType:primaryAction:")) == NULL);
                NSVerFn fnLinkVer = (NSVerFn)dlsym(RTLD_DEFAULT, "NSVersionOfLinkTimeLibrary");
                BOOL linkVerOK = (fnLinkVer == NULL || (fnLinkVer("Foundation") >> 16) == 1677);
                s12Round1ReflectionParityOK = (noMacProp && clsNamesParity && metaMethodHidden && linkVerOK);

                // Round 2 compat13_7: JSC structuredClone/AggregateError hidden (ObjC + C API) & Metal raytracing rejected
                BOOL r2JscObjcOK = NO;
                BOOL r2JscCOK = NO;
                if (jscH != NULL) {
                    Class jscCls2 = objc_getClass("JSContext");
                    if (jscCls2 != Nil) {
                        id ctx2 = [jscCls2 new];
                        if (ctx2 != nil) {
                            SEL evalSel2 = sel_registerName("evaluateScript:");
                            id sc = ((id (*)(id, SEL, NSString *))objc_msgSend)(ctx2, evalSel2, @"typeof structuredClone");
                            id ae = ((id (*)(id, SEL, NSString *))objc_msgSend)(ctx2, evalSel2, @"typeof AggregateError");
                            r2JscObjcOK = ([[sc description] isEqualToString:@"undefined"] &&
                                           [[ae description] isEqualToString:@"undefined"]);
                        }
                    }
                    typedef void *(*JSCCreateFn2)(void *);
                    typedef void (*JSCReleaseFn2)(void *);
                    typedef void *(*JSCStrCreateFn2)(const char *);
                    typedef void (*JSCStrReleaseFn2)(void *);
                    typedef void *(*JSCEvalFn2)(void *, void *, void *, void *, int, void **);
                    typedef bool (*JSCToBoolFn2)(void *, void *);
                    JSCCreateFn2 fnC2 = (JSCCreateFn2)dlsym(RTLD_DEFAULT, "JSGlobalContextCreate");
                    JSCReleaseFn2 fnR2 = (JSCReleaseFn2)dlsym(RTLD_DEFAULT, "JSGlobalContextRelease");
                    JSCStrCreateFn2 fnS2 = (JSCStrCreateFn2)dlsym(RTLD_DEFAULT, "JSStringCreateWithUTF8CString");
                    JSCStrReleaseFn2 fnSR2 = (JSCStrReleaseFn2)dlsym(RTLD_DEFAULT, "JSStringRelease");
                    JSCEvalFn2 fnE2 = (JSCEvalFn2)dlsym(RTLD_DEFAULT, "JSEvaluateScript");
                    JSCToBoolFn2 fnB2 = (JSCToBoolFn2)dlsym(RTLD_DEFAULT, "JSValueToBoolean");
                    if (fnC2 != NULL && fnR2 != NULL && fnS2 != NULL && fnSR2 != NULL && fnE2 != NULL && fnB2 != NULL) {
                        void *gc2 = fnC2(NULL);
                        if (gc2 != NULL) {
                            void *s2 = fnS2("typeof structuredClone === 'undefined' && typeof AggregateError === 'undefined'");
                            void *ex2 = NULL;
                            void *rv2 = fnE2(gc2, s2, NULL, NULL, 1, &ex2);
                            r2JscCOK = (rv2 != NULL && ex2 == NULL && fnB2(gc2, rv2));
                            fnSR2(s2);
                            fnR2(gc2);
                        }
                    }
                }
                BOOL r2MetalRtBlockedOK = NO;
                {
                    typedef CFTypeRef (*CreateDevFn2)(void);
                    CreateDevFn2 fnDev2 = (CreateDevFn2)dlsym(RTLD_DEFAULT, "MTLCreateSystemDefaultDevice");
                    Class optsCls2 = objc_getClass("MTLCompileOptions");
                    id dev2 = (fnDev2 != NULL) ? CFBridgingRelease(fnDev2()) : nil;
                    if (dev2 != nil && optsCls2 != Nil) {
                        SEL newLibSel2 = sel_registerName("newLibraryWithSource:options:error:");
                        typedef id (*NewLibMsgSendFn2)(id, SEL, NSString *, id, NSError * __autoreleasing *);
                        NSError * __autoreleasing errRt = nil;
                        id optsRt = [optsCls2 new];
                        NSString *rtSrc = @"#include <metal_stdlib>\n#include <metal_raytracing>\nusing namespace metal;\nkernel void rt() {}\n";
                        id libRt = ((NewLibMsgSendFn2)objc_msgSend)(dev2, newLibSel2, rtSrc, optsRt, &errRt);
                        r2MetalRtBlockedOK = (libRt == nil && errRt != nil &&
                                              [errRt.domain isEqualToString:@"MTLLibraryErrorDomain"] && errRt.code == 3);
                    }
                }
                s12Round2Compat13EpochOK = (r2JscObjcOK && r2JscCOK && r2MetalRtBlockedOK);

                // Round 3 compat13_7: u_charAge(0x1F972)==0, AttributedString/Duration hidden, ___isPlatformVersionAtLeast(2,14,0,0)==0
                BOOL r3IcuAgeOK = NO;
                {
                    typedef void (*UCharAgeFn3)(int32_t, uint8_t[4]);
                    UCharAgeFn3 fnAge = (UCharAgeFn3)dlsym(RTLD_DEFAULT, "u_charAge");
                    if (fnAge != NULL) {
                        uint8_t age[4] = {0xFF, 0xFF, 0xFF, 0xFF};
                        fnAge(0x1F972, age);
                        r3IcuAgeOK = (age[0] == 0);
                    }
                }
                BOOL r3SwiftHiddenOK = (dlsym(RTLD_DEFAULT, "$s10Foundation16AttributedStringVMn") == NULL &&
                                        dlsym(RTLD_DEFAULT, "$ss8DurationVMn") == NULL);
#if __has_attribute(swiftcall)
                {
                    pt_harness_swift_lookup_fn fnSw3 = (pt_harness_swift_lookup_fn)dlsym(RTLD_DEFAULT, "swift_getTypeByMangledNameInContext");
                    if (fnSw3 != NULL) {
                        const char *m1 = "10Foundation16AttributedStringV";
                        const char *m2 = "s8DurationV";
                        if (fnSw3(m1, strlen(m1), NULL, NULL) != NULL ||
                            fnSw3(m2, strlen(m2), NULL, NULL) != NULL) {
                            r3SwiftHiddenOK = NO;
                        }
                    }
                }
#endif
                BOOL r3AvailOK = NO;
                {
                    typedef int32_t (*AvailFn3)(uint32_t, uint32_t, uint32_t, uint32_t);
                    AvailFn3 fnAv = (AvailFn3)dlsym(RTLD_DEFAULT, "__isPlatformVersionAtLeast");
                    if (fnAv != NULL) {
                        r3AvailOK = (fnAv(2U, 14U, 0U, 0U) == 0);
                    }
                }
                s12Round3IcuSwiftAvailOK = (r3IcuAgeOK && r3SwiftHiddenOK && r3AvailOK);
            }
        }

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
            @"sysctlMibMachine": [NSString stringWithUTF8String:sysctlMibMachine] ?: @"",
            @"syscallMachine": [NSString stringWithUTF8String:syscallMachine] ?: @"",
            @"syscallWideArityOK": syscallWideArityOK ? @YES : @NO,
            @"syscallStatHidSysApps": syscallStatHidSysApps ? @YES : @NO,
            @"fsHidMacRoots": fsHidMacRoots ? @YES : @NO,
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
            @"uiColorWellInClassList": uiColorWellInClassList ? @YES : @NO,
            @"appAttestSupported": appAttestSupported ? @YES : @NO,
            @"appAttestGenKeyUnsupported": appAttestGenKeyUnsupported ? @YES : @NO,
            @"dcDeviceLoaded": dcDeviceLoaded ? @YES : @NO,
            @"dcDeviceSupported": dcDeviceSupported ? @YES : @NO,
            @"dcDeviceTokenUnsupported": dcDeviceTokenUnsupported ? @YES : @NO,
            @"cmAccelAvailable": cmAccelAvailable ? @YES : @NO,
            @"cmGyroAvailable": cmGyroAvailable ? @YES : @NO,
            @"cmDeviceMotionAvailable": cmDeviceMotionAvailable ? @YES : @NO,
            @"cmSampleValid": cmSampleValid ? @YES : @NO,
            @"cmMagImmutable": cmMagImmutable ? @YES : @NO,
            @"cmDMMagneticCalibrated": cmDMMagneticCalibrated ? @YES : @NO,
            @"earlyUnameOK": earlyUnameOK ? @YES : @NO,
            @"concurrentUnameOK": concurrentUnameOK ? @YES : @NO,
            @"procArgs2LeakedApple": procArgs2LeakedApple ? @YES : @NO,
            @"procArgs2EnvClean": procArgs2EnvClean ? @YES : @NO,
            @"atSystemVersionInodeMatch": atSystemVersionInodeMatch ? @YES : @NO,
            @"atSystemVersionProductName": atSystemVersionProductName ?: @"",
            @"hidSystemVolumes": hidSystemVolumes ? @YES : @NO,
            @"homeMountClean": homeMountClean ? @YES : @NO,
            @"passwdClean": passwdClean ? @YES : @NO,
            @"machVmMh0Platform": @(machVmMh0Platform),
            @"vmParsedImages": @(vmParsedImages),
            @"vmNonIosImages": @(vmNonIosImages),
            @"vmDirtyImports": @(vmDirtyImports),
            @"vmDladdrDiffs": @(vmDladdrDiffs),
            @"vmHiddenMachOCount": @(vmHiddenMachOCount),
            @"diskHeaderMatchesMemory": diskHeaderMatchesMemory ? @YES : @NO,
            @"diskHeaderPlatform": @(diskHeaderPlatform),
            @"dlsymCOwnersClean": dlsymCOwnersClean ? @YES : @NO,
            @"ifaddrsClean": ifaddrsClean ? @YES : @NO,
            @"ifaddrsCount": @(ifaddrsCount),
            @"inlineSvcMachine": inlineSvcMachine,
            @"inlineSvcStatHidSysApps": inlineSvcStatHidSysApps ? @YES : @NO,
            @"inlineSvcSysVerIsIOS": inlineSvcSysVerIsIOS ? @YES : @NO,
            @"inlineSvcCodeReadRestored": inlineSvcCodeReadRestored ? @YES : @NO,
            @"s10StrictBypassEarlyOK": s10StrictBypassEarlyOK ? @YES : @NO,
            @"s10DeepUnwindHidMacPaths": s10DeepUnwindHidMacPaths ? @YES : @NO,
            @"s10PlayChainOpaqueRefOK": s10PlayChainOpaqueRefOK ? @YES : @NO,
            @"s10PlayChainForeignGroupBlocked": s10PlayChainForeignGroupBlocked ? @YES : @NO,
            @"s10PlayChainSEExportBlocked": s10PlayChainSEExportBlocked ? @YES : @NO,
            @"s10WebKitVFileHidden": s10WebKitVFileHidden ? @YES : @NO,
            @"s10DesktopFontsHidden": s10DesktopFontsHidden ? @YES : @NO,
            @"s10DscVersionedHidden": s10DscVersionedHidden ? @YES : @NO,
            @"s10FinderHidden": s10FinderHidden ? @YES : @NO,
            @"s10ProcArgsHidSandboxId": s10ProcArgsHidSandboxId ? @YES : @NO,
            @"s10SelfPidpathVirtual": s10SelfPidpathVirtual ? @YES : @NO,
            @"s10SelfPidpathValue": s10SelfPidpathValue ?: @"",
            @"s10CoreMotionGenuineAndEpochOK": s10CoreMotionGenuineAndEpochOK ? @YES : @NO,
            @"s10AltimeterContractOK": s10AltimeterContractOK ? @YES : @NO,
            @"s10UnixRelativeSocketOK": s10UnixRelativeSocketOK ? @YES : @NO,
            @"s10ExceptionPortsHidden": s10ExceptionPortsHidden ? @YES : @NO,
            @"s10SysctlCacheTopologyOK": s10SysctlCacheTopologyOK ? @YES : @NO,
            @"s11ProcPidPathInfoOK": s11ProcPidPathInfoOK ? @YES : @NO,
            @"s11SmallCapExcPortsOK": s11SmallCapExcPortsOK ? @YES : @NO,
            @"s11CoreMotionCrossCompareOK": s11CoreMotionCrossCompareOK ? @YES : @NO,
            @"s11PlayChainAppGroupAndSEOK": s11PlayChainAppGroupAndSEOK ? @YES : @NO,
            @"s11CatalystImpUnwrapOK": s11CatalystImpUnwrapOK ? @YES : @NO,
            @"s11SwiftMangledHiddenOK": s11SwiftMangledHiddenOK ? @YES : @NO,
            @"s11NetIfListHiddenOK": s11NetIfListHiddenOK ? @YES : @NO,
            @"s11CacheL2AlignedOK": s11CacheL2AlignedOK ? @YES : @NO,
            @"s11GidNotStaffOK": s11GidNotStaffOK ? @YES : @NO,
            @"s11MonacoFontHiddenOK": s11MonacoFontHiddenOK ? @YES : @NO,
            @"s11FileRefAndFsgetpathOK": s11FileRefAndFsgetpathOK ? @YES : @NO,
            @"s11FileRefUrlOK": s11FileRefUrlOK ? @YES : @NO,
            @"s11DownloadsHidden": s11DownloadsHidden ? @YES : @NO,
            @"s11FsgetpathOK": s11FsgetpathOK ? @YES : @NO,
            @"s11FileRefPathValue": s11FileRefPathValue ?: @"",
            @"s11MGCopyAnswerWithErrorOK": s11MGCopyAnswerWithErrorOK ? @YES : @NO,
            @"s11AudioAndUTTypeHiddenOK": s11AudioAndUTTypeHiddenOK ? @YES : @NO,
            @"s11SwapZeroOK": s11SwapZeroOK ? @YES : @NO,
            @"s11SandboxDlsymOK": s11SandboxDlsymOK ? @YES : @NO,
            @"s11CoreMotionPullCacheOK": s11CoreMotionPullCacheOK ? @YES : @NO,
            @"s11MigHostAndTaskOK": s11MigHostAndTaskOK ? @YES : @NO,
            @"s11BootstrapBlockedOK": s11BootstrapBlockedOK ? @YES : @NO,
            @"s11SysctlSwapAndTreeOK": s11SysctlSwapAndTreeOK ? @YES : @NO,
            @"s11ResponsibilitySelfOK": s11ResponsibilitySelfOK ? @YES : @NO,
            @"s11LsAsnHiddenOK": s11LsAsnHiddenOK ? @YES : @NO,
            @"s11ObjcMetaAndReqHiddenOK": s11ObjcMetaAndReqHiddenOK ? @YES : @NO,
            @"s11Round1DlsymAndProcOK": s11Round1DlsymAndProcOK ? @YES : @NO,
            @"s11Round1VolumeAndCodeResOK": s11Round1VolumeAndCodeResOK ? @YES : @NO,
            @"s11Round1AppKitAndSuperBlobOK": s11Round1AppKitAndSuperBlobOK ? @YES : @NO,
            @"s11Round2CGAndHIDBlockedOK": s11Round2CGAndHIDBlockedOK ? @YES : @NO,
            @"s11Round2FontsAndDlopenOK": s11Round2FontsAndDlopenOK ? @YES : @NO,
            @"s11Round2MigThreadNetIopsOK": s11Round2MigThreadNetIopsOK ? @YES : @NO,
            @"s11R2ThreadsClean": s11R2ThreadsClean ? @YES : @NO,
            @"s11R2Mig219OK": s11R2Mig219OK ? @YES : @NO,
            @"s11R2Mig3414OK": s11R2Mig3414OK ? @YES : @NO,
            @"s11R2SiocgifconfClean": s11R2SiocgifconfClean ? @YES : @NO,
            @"s11R2IopsOK": s11R2IopsOK ? @YES : @NO,
            @"s11R2AmfiOK": s11R2AmfiOK ? @YES : @NO,
            @"s11R2HdrImgOK": s11R2HdrImgOK ? @YES : @NO,
            @"s11Round3SignKernelCsrOK": s11Round3SignKernelCsrOK ? @YES : @NO,
            @"s11Round3DyldHandleUnwindOK": s11Round3DyldHandleUnwindOK ? @YES : @NO,
            @"s11R3ExplicitHandleOK": s11R3ExplicitHandleOK ? @YES : @NO,
            @"s11R3CfBundleOK": s11R3CfBundleOK ? @YES : @NO,
            @"s11R3DlopenFromOK": s11R3DlopenFromOK ? @YES : @NO,
            @"s11R3UnwindOK": s11R3UnwindOK ? @YES : @NO,
            @"s11Round3FsCasePathsAndIORegOK": s11Round3FsCasePathsAndIORegOK ? @YES : @NO,
            @"s12FreadlinkHiddenOK": s12FreadlinkHiddenOK ? @YES : @NO,
            @"s12ExtensionKitHiddenOK": s12ExtensionKitHiddenOK ? @YES : @NO,
            @"s12MetalCompat13GateOK": s12MetalCompat13GateOK ? @YES : @NO,
            @"s12IORegGpuSanitizedOK": s12IORegGpuSanitizedOK ? @YES : @NO,
            @"s12Post13EpochCleanOK": s12Post13EpochCleanOK ? @YES : @NO,
            @"s12Round1JscCAPICleanOK": s12Round1JscCAPICleanOK ? @YES : @NO,
            @"s12Round1ReflectionParityOK": s12Round1ReflectionParityOK ? @YES : @NO,
            @"s12Round2Compat13EpochOK": s12Round2Compat13EpochOK ? @YES : @NO,
            @"s12Round3IcuSwiftAvailOK": s12Round3IcuSwiftAvailOK ? @YES : @NO,
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
            @"vmRegionHidPlayTools": vmRegionHidPlayTools ? @YES : @NO,
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
        "-framework", "CoreText",
        "-framework", "QuartzCore",
        "-framework", "Security",
        "-framework", "UIKit",
        "-framework", "WebKit",
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
        info1["vmRegionHidPlayTools"] is True,
        info1["mh0BaseAndSlideConsistent"] is True,
        info1["mh0SectionLookupOK"] is True,
        info1["argvConsistent"] is True,
        info1["procArgCount"] == 2,
        info1["cmAccelAvailable"] is True,
        info1["cmGyroAvailable"] is True,
        info1["cmDeviceMotionAvailable"] is True,
        info1["cmSampleValid"] is True,
        info1["cmMagImmutable"] is True,
        info1["cmDMMagneticCalibrated"] is True,
        info1["earlyUnameOK"] is True,
        info1["concurrentUnameOK"] is True,
        info1["procArgs2LeakedApple"] is False,
        info1["procArgs2EnvClean"] is True,
        info1["atSystemVersionInodeMatch"] is True,
        info1["atSystemVersionProductName"] != "macOS",
        info1["hidSystemVolumes"] is True,
        info1["homeMountClean"] is True,
        info1["passwdClean"] is True,
        info1["machVmMh0Platform"] == 2,
        int(info1["vmParsedImages"]) > 0,
        info1["vmNonIosImages"] == 0,
        info1["vmDirtyImports"] == 0,
        info1["vmDladdrDiffs"] == 0,
        info1["vmHiddenMachOCount"] == 0,
        info1["dlsymCOwnersClean"] is True,
        info1["ifaddrsClean"] is True,
        int(info1["ifaddrsCount"]) > 0,
        info1["syscallMachine"] == info1["sysctlMachine"] and len(info1["syscallMachine"]) > 0,
        info1["syscallWideArityOK"] is True,
        info1["syscallStatHidSysApps"] is True,
        info1["fsHidMacRoots"] is True,
        info1["availIOS16"] is True,
        info1["uiColorWellLoaded"] is True,
        info1["uiColorWellInClassList"] is True,
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
        info6a["sysctlMibMachine"] == "iPhone12,5",
        info6a["syscallMachine"] == "iPhone12,5",
        info6a["syscallWideArityOK"] is True,
        info6a["syscallStatHidSysApps"] is True,
        info6a["fsHidMacRoots"] is True,
        info6a["unameMachine"] == "iPhone12,5",
        0.0 < float(info6a["displayLinkClampedMaxHz"]) <= 60.0,
        info6a["displayLinkClampedLegacyFPS"] == 60,
        (not info6a["appAttestLoaded"]) or (info6a["appAttestSupported"] is False),
        info6a["appAttestLoaded"] is False,
        info6a["availIOS16"] is False,
        info6a["uiColorWellLoaded"] is False,
        info6a["uiColorWellInClassList"] is False,
        marker6a.exists(),
        info6b["safeModeActive"] is True,
        info6b["reportedIOSVersion"] == "automatic",
        info6b["osVersionMajor"] != 13,
        info6b["availIOS16"] is True,
        info6b["uiColorWellLoaded"] is True,
        info6b["uiColorWellInClassList"] is True,
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

    # Scenario 8: Original iOS Mach-O executable in AppBackups -> vm_read_overwrite(mh0) matches DiskHeader byte-for-byte.
    t7 = time.monotonic()
    isolated_home_8 = work_dir / "IsolatedHome8"
    backup_dir_8 = isolated_home_8 / "Library/Containers/app.makedie.MacOver/AppBackups/app.makedie.harness.mockapp"
    backup_dir_8.mkdir(parents=True, exist_ok=True)
    raw_exec_bytes = bytearray(target_bin.read_bytes())
    # Patch first LC_BUILD_VERSION platform=6 (Catalyst) -> 2 (iOS) in the synthetic backup binary so it differs from Catalyst disk/mem.
    lc_pos = 32
    import struct as _st
    magic_val, _, _, _, ncmds, sizeofcmds, _, _ = _st.unpack_from("<IIIIIIII", raw_exec_bytes, 0)
    assert magic_val == 0xFEEDFACF
    patched_backup_plat = False
    for _ in range(ncmds):
        if lc_pos + 8 > 32 + sizeofcmds:
            break
        cmd, cmdsize = _st.unpack_from("<II", raw_exec_bytes, lc_pos)
        if cmd == 0x32 and cmdsize >= 24:  # LC_BUILD_VERSION
            _st.pack_into("<I", raw_exec_bytes, lc_pos + 8, 2)  # PLATFORM_IOS
            patched_backup_plat = True
            break
        lc_pos += cmdsize
    assert patched_backup_plat
    backup_exec_8 = backup_dir_8 / "executable"
    backup_exec_8.write_bytes(bytes(raw_exec_bytes))
    os.chmod(backup_exec_8, 0o755)
    with open(backup_dir_8 / "manifest.plist", "wb") as fp:
        plistlib.dump(
            {
                "CFBundleIdentifier": "app.makedie.harness.mockapp",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "PCInstallGeneration": "HARNESS-GEN-101",
            },
            fp,
        )
    plist8 = write_test_settings_plist(isolated_home_8, "app.makedie.harness.mockapp")
    marker8a = work_dir / "marker_8a.txt"
    env8 = base_env(
        marker8a,
        HOME=str(isolated_home_8),
        CFFIXED_USER_HOME=str(isolated_home_8),
        PLAYTOOLS_SETTINGS_PLIST=str(plist8),
        PLAYTOOLS_TEST_APP_BACKUPS_DIR=str(backup_dir_8),
        HARNESS_GRACEFUL_EXIT="1",
    )
    proc8a = run_cmd([str(target_bin)], env=env8, check=False)
    if proc8a.returncode != 0:
        results.append(ScenarioResult(
            name="8. AppBackups Mach-O MemoryHeader vs DiskHeader byte parity",
            passed=False,
            duration_sec=time.monotonic() - t7,
            details=f"Exit code {proc8a.returncode}\nstdout={proc8a.stdout}\nstderr={proc8a.stderr}",
        ))
        return results
    info8a = parse_harness_json(proc8a.stdout)
    checks8 = [
        info8a["safeModeActive"] is False,
        info8a["diskHeaderPlatform"] == 2,
        info8a["machVmMh0Platform"] == 2,
        info8a["diskHeaderMatchesMemory"] is True,
    ]
    results.append(ScenarioResult(
        name="8. AppBackups Mach-O MemoryHeader vs DiskHeader byte parity",
        passed=all(checks8),
        duration_sec=time.monotonic() - t7,
        details=json.dumps(info8a, sort_keys=True),
    ))
    if verbose:
        print("  Scenario 8 payload:", info8a)

    # Scenario 9: Opt-in inline ARM64 svc #0x80 brk patching + EXC_BREAKPOINT dispatch + Safe Mode passthrough.
    t8 = time.monotonic()
    patched_app_dir = work_dir / "MockTargetPatched.app"
    shutil.copytree(target_bin.parent, patched_app_dir, symlinks=True)
    patched_bin = patched_app_dir / "MockTarget"

    raw_bytes = bytearray(patched_bin.read_bytes())
    orig_sha = hashlib.sha256(raw_bytes).hexdigest()
    SVC_INSN = 0xD4001001
    BRK_INSN = 0xD42A0E80
    S_ZEROFILL = 0x1
    S_GB_ZEROFILL = 0xC
    S_ATTR_PURE_INSTRUCTIONS = 0x80000000
    S_ATTR_SOME_INSTRUCTIONS = 0x00000400

    mh_magic, _, _, _, ncmds, sizeofcmds, _, _ = struct.unpack_from("<IIIIIIII", raw_bytes, 0)
    assert mh_magic == 0xFEEDFACF
    cmd_off = 32
    cmds_end = 32 + sizeofcmds
    text_vmaddr = 0
    inst_sections: list[tuple[int, int, int]] = []
    dic_ranges: list[tuple[int, int]] = []
    for _ in range(ncmds):
        if cmd_off + 8 > cmds_end:
            break
        cmd, cmdsize = struct.unpack_from("<II", raw_bytes, cmd_off)
        if cmd == 0x19 and cmdsize >= 72:  # LC_SEGMENT_64
            segname_raw, vmaddr, _, _, _, _, _, nsects, _ = struct.unpack_from("<16sQQQQIIII", raw_bytes, cmd_off + 8)
            segname = segname_raw.split(b"\x00", 1)[0].decode("utf-8", errors="replace")
            if segname == "__TEXT":
                text_vmaddr = vmaddr
            sec_off = cmd_off + 72
            for _ in range(nsects):
                if sec_off + 80 > cmd_off + cmdsize:
                    break
                _, _, s_addr, s_size, s_off, _, _, _, s_flags, _, _, _ = struct.unpack_from(
                    "<16s16sQQIIIIIIII", raw_bytes, sec_off
                )
                sec_off += 80
                stype = s_flags & 0xFF
                if stype not in (S_ZEROFILL, S_GB_ZEROFILL) and (
                    s_flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS)
                ) != 0 and s_off > 0 and s_size >= 4:
                    inst_sections.append((s_off, s_off + s_size, s_addr))
        elif cmd == 0x29 and cmdsize >= 16:  # LC_DATA_IN_CODE
            dataoff, datasize = struct.unpack_from("<II", raw_bytes, cmd_off + 8)
            for eo in range(dataoff, dataoff + datasize, 8):
                if eo + 8 <= len(raw_bytes):
                    d_off, d_len, _ = struct.unpack_from("<IHH", raw_bytes, eo)
                    if d_len > 0:
                        dic_ranges.append((d_off, d_off + d_len))
        cmd_off += cmdsize

    svc_sites: list[dict[str, int]] = []
    for s_start, s_end, s_vm in inst_sections:
        for foff in range(s_start, s_end - 3, 4):
            if any(foff + 4 > r0 and foff < r1 for r0, r1 in dic_ranges):
                continue
            word = struct.unpack_from("<I", raw_bytes, foff)[0]
            if word == SVC_INSN:
                struct.pack_into("<I", raw_bytes, foff, BRK_INSN)
                vm_addr = s_vm + (foff - s_start)
                svc_sites.append({
                    "sliceOffset": 0,
                    "fileOffset": foff,
                    "vmAddress": vm_addr,
                    "vmOffset": vm_addr - text_vmaddr,
                })

    assert len(svc_sites) > 0, "Expected at least one inline svc #0x80 site in MockTarget"
    patched_sha = hashlib.sha256(raw_bytes).hexdigest()
    patched_bin.write_bytes(bytes(raw_bytes))
    os.chmod(patched_bin, 0o755)
    tool_env = os.environ.copy()
    if "DEVELOPER_DIR" not in tool_env and Path("/Applications/Xcode.app/Contents/Developer").exists():
        tool_env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    run_cmd(["codesign", "--force", "--deep", "--sign", "-", str(patched_app_dir)], env=tool_env)

    isolated_home_9 = work_dir / "IsolatedHome9"
    isolated_home_9.mkdir(parents=True, exist_ok=True)
    plist9 = write_test_settings_plist(isolated_home_9, "app.makedie.harness.mockapp")
    manifest_dir_9 = isolated_home_9 / "Library/Containers/app.makedie.MacOver/SVCPatches"
    manifest_dir_9.mkdir(parents=True, exist_ok=True)
    manifest_path_9 = manifest_dir_9 / "app.makedie.harness.mockapp.json"
    manifest_path_9.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "bundleIdentifier": "app.makedie.harness.mockapp",
                "originalInstruction": SVC_INSN,
                "patchInstruction": BRK_INSN,
                "files": [
                    {
                        "relativePath": "MockTarget",
                        "originalSHA256": orig_sha,
                        "patchedSHA256": patched_sha,
                        "sites": svc_sites,
                    }
                ],
            },
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )

    def env9(marker_path: Path, **extra: str) -> dict[str, str]:
        env = base_env(marker_path, **extra)
        env["HOME"] = str(isolated_home_9)
        env["CFFIXED_USER_HOME"] = str(isolated_home_9)
        env["PLAYTOOLS_SETTINGS_PLIST"] = str(plist9)
        env["PLAYTOOLS_TEST_SVC_MANIFEST"] = str(manifest_path_9)
        return env

    marker9a = work_dir / "marker_9a.txt"
    svc_probe_b64 = base64.b64encode(str(manifest_path_9).encode("utf-8")).decode("ascii")
    proc9a = run_cmd(
        [str(patched_bin)],
        env=env9(
            marker9a,
            HARNESS_TEST_INLINE_SVC="1",
            HARNESS_DIRECT_PROBE_B64=svc_probe_b64,
            HARNESS_GRACEFUL_EXIT="1",
        ),
        check=False,
    )
    marker9b = work_dir / "marker_9b.txt"
    proc9b = run_cmd(
        [str(patched_bin)],
        env=env9(
            marker9b,
            HARNESS_TEST_INLINE_SVC="1",
            PLAYTOOLS_SAFE_MODE="1",
            HARNESS_GRACEFUL_EXIT="1",
        ),
        check=False,
    )
    if proc9a.returncode != 0 or proc9b.returncode != 0:
        results.append(ScenarioResult(
            name="9. Opt-in inline svc #0x80 interception & Safe Mode passthrough",
            passed=False,
            duration_sec=time.monotonic() - t8,
            details=(
                f"Sub-run rc=({proc9a.returncode}, {proc9b.returncode})\n"
                f"9a stdout={proc9a.stdout}\n9a stderr={proc9a.stderr}\n"
                f"9b stdout={proc9b.stdout}\n9b stderr={proc9b.stderr}"
            ),
        ))
        return results

    info9a = parse_harness_json(proc9a.stdout)
    info9b = parse_harness_json(proc9b.stdout)
    checks9 = [
        info9a["safeModeActive"] is False,
        info9a["inlineSvcMachine"] == info9a["sysctlMachine"] and len(info9a["inlineSvcMachine"]) > 0,
        info9a["inlineSvcStatHidSysApps"] is True,
        info9a["inlineSvcSysVerIsIOS"] is True,
        info9a["inlineSvcCodeReadRestored"] is True,
        info9a["directBackupStatBlocked"] is True,
        info9a["directBackupOpenBlocked"] is True,
        info9a["directBackupFMBlocked"] is True,
        info9b["safeModeActive"] is True,
        info9b["inlineSvcStatHidSysApps"] is False,
        len(info9b["inlineSvcMachine"]) > 0 and info9b["inlineSvcMachine"] != info9a["sysctlMachine"],
    ]
    results.append(ScenarioResult(
        name="9. Opt-in inline svc #0x80 interception & Safe Mode passthrough",
        passed=all(checks9),
        duration_sec=time.monotonic() - t8,
        details=json.dumps({"siteCount": len(svc_sites), "normal": info9a, "safeMode": info9b}, sort_keys=True),
    ))
    if verbose:
        print("  Scenario 9 normal:", info9a)
        print("  Scenario 9 safeMode:", info9b)

    # Scenario 10: 99-check anti-detection & contract hardening (Strict Mode early bypass, A02, A03, A04, A14, A15, procargs, pidpath, CoreMotion/A10/C05, C10, C14)
    t9 = time.monotonic()
    isolated_home_10 = work_dir / "IsolatedHome10"
    isolated_home_10.mkdir(parents=True, exist_ok=True)
    plist10_dir = isolated_home_10 / "Library/Containers/app.makedie.MacOver/PlayTools"
    plist10_dir.mkdir(parents=True, exist_ok=True)
    plist10 = plist10_dir / "app.makedie.harness.mockapp.plist"
    with open(plist10, "wb") as fp:
        plistlib.dump({
            "bypass": False,
            "strictEmulationMode": True,
            "strictViewportOrientation": "landscape",
            "strictViewportScaleMode": "fitScreen",
            "playChain": True,
        }, fp)
    marker10 = work_dir / "marker_10.txt"
    env10 = env9(
        marker10,
        HARNESS_TEST_SCENARIO10="1",
        HARNESS_TEST_INLINE_SVC="1",
        APP_SANDBOX_CONTAINER_ID="app.makedie.harness.mockapp",
        HARNESS_GRACEFUL_EXIT="1",
    )
    env10["HOME"] = str(isolated_home_10)
    env10["CFFIXED_USER_HOME"] = str(isolated_home_10)
    env10["PLAYTOOLS_SETTINGS_PLIST"] = str(plist10)
    proc10 = run_cmd([str(patched_bin)], env=env10, check=False)
    if proc10.returncode != 0:
        results.append(ScenarioResult(
            name="10. 99-check anti-detection & Strict Mode hardening",
            passed=False,
            duration_sec=time.monotonic() - t9,
            details=f"rc={proc10.returncode}\nstdout={proc10.stdout}\nstderr={proc10.stderr}",
        ))
        return results

    info10 = parse_harness_json(proc10.stdout)
    checks10 = [
        info10["safeModeActive"] is False,
        info10["inlineSvcMachine"] == info10["sysctlMachine"] and len(info10["inlineSvcMachine"]) > 0,
        info10["s10StrictBypassEarlyOK"] is True,
        info10["s10DeepUnwindHidMacPaths"] is True,
        info10["s10PlayChainOpaqueRefOK"] is True,
        info10["s10PlayChainForeignGroupBlocked"] is True,
        info10["s10PlayChainSEExportBlocked"] is True,
        info10["s10WebKitVFileHidden"] is True,
        info10["s10DesktopFontsHidden"] is True,
        info10["s10DscVersionedHidden"] is True,
        info10["s10FinderHidden"] is True,
        info10["s10ProcArgsHidSandboxId"] is True,
        info10["s10SelfPidpathVirtual"] is True,
        info10["s10CoreMotionGenuineAndEpochOK"] is True,
        info10["s10AltimeterContractOK"] is True,
        info10["s10UnixRelativeSocketOK"] is True,
        info10["s10ExceptionPortsHidden"] is True,
        info10["s10SysctlCacheTopologyOK"] is True,
    ]
    results.append(ScenarioResult(
        name="10. 99-check anti-detection & Strict Mode hardening",
        passed=all(checks10),
        duration_sec=time.monotonic() - t9,
        details=json.dumps({
            "inlineSvcMachine": info10["inlineSvcMachine"],
            "sysctlMachine": info10["sysctlMachine"],
            **{k: v for k, v in info10.items() if k.startswith("s10")},
        }, sort_keys=True),
    ))
    if verbose:
        print("  Scenario 10 payload:", {k: v for k, v in info10.items() if k.startswith("s10")})

    # Scenario 11: 1.0.4 audit & detect-v2 parity checks
    t10 = time.monotonic()
    isolated_root_11 = work_dir / "IsolatedHome11"
    container_data_11 = isolated_root_11 / "Library/Containers/app.makedie.harness.mockapp/Data"
    container_data_11.mkdir(parents=True, exist_ok=True)
    downloads_link_11 = container_data_11 / "Downloads"
    if not downloads_link_11.exists() and not downloads_link_11.is_symlink():
        os.symlink("/Users/example/Downloads", str(downloads_link_11))
    ent_dir_11 = isolated_root_11 / "Library/Containers/app.makedie.MacOver/Entitlements"
    ent_dir_11.mkdir(parents=True, exist_ok=True)
    with open(ent_dir_11 / "app.makedie.harness.mockapp.plist", "wb") as fp:
        plistlib.dump({
            "com.apple.security.application-groups": ["group.app.makedie.harness.shared"],
        }, fp)
    plist11_dir = isolated_root_11 / "Library/Containers/app.makedie.MacOver/PlayTools"
    plist11_dir.mkdir(parents=True, exist_ok=True)
    plist11 = plist11_dir / "app.makedie.harness.mockapp.plist"
    with open(plist11, "wb") as fp:
        plistlib.dump({
            "bypass": False,
            "strictEmulationMode": True,
            "strictViewportOrientation": "landscape",
            "strictViewportScaleMode": "fitScreen",
            "playChain": True,
        }, fp)
    marker11 = work_dir / "marker_11.txt"
    env11 = env9(
        marker11,
        HARNESS_TEST_SCENARIO11="1",
        HARNESS_TEST_INLINE_SVC="1",
        APP_SANDBOX_CONTAINER_ID="app.makedie.harness.mockapp",
        HARNESS_GRACEFUL_EXIT="1",
    )
    env11["HOME"] = str(container_data_11)
    env11["CFFIXED_USER_HOME"] = str(container_data_11)
    env11["PLAYTOOLS_SETTINGS_PLIST"] = str(plist11)
    proc11 = run_cmd([str(patched_bin)], env=env11, check=False)
    if proc11.returncode != 0:
        results.append(ScenarioResult(
            name="11. 1.0.4 audit & detect-v2 parity checks",
            passed=False,
            duration_sec=time.monotonic() - t10,
            details=f"rc={proc11.returncode}\nstdout={proc11.stdout}\nstderr={proc11.stderr}",
        ))
        return results

    info11 = parse_harness_json(proc11.stdout)
    checks11 = [
        info11["safeModeActive"] is False,
        info11["inlineSvcMachine"] == info11["sysctlMachine"] and len(info11["inlineSvcMachine"]) > 0,
        info11["s11ProcPidPathInfoOK"] is True,
        info11["s11SmallCapExcPortsOK"] is True,
        info11["s11CoreMotionCrossCompareOK"] is True,
        info11["s11PlayChainAppGroupAndSEOK"] is True,
        info11["s11CatalystImpUnwrapOK"] is True,
        info11["s11SwiftMangledHiddenOK"] is True,
        info11["s11NetIfListHiddenOK"] is True,
        info11["s11CacheL2AlignedOK"] is True,
        info11["s11GidNotStaffOK"] is True,
        info11["s11MonacoFontHiddenOK"] is True,
        info11["s11FileRefAndFsgetpathOK"] is True,
        info11["s11MGCopyAnswerWithErrorOK"] is True,
        info11["s11AudioAndUTTypeHiddenOK"] is True,
        info11["s11SwapZeroOK"] is True,
        info11["s11SandboxDlsymOK"] is True,
        info11["s11CoreMotionPullCacheOK"] is True,
        info11["s11MigHostAndTaskOK"] is True,
        info11["s11BootstrapBlockedOK"] is True,
        info11["s11SysctlSwapAndTreeOK"] is True,
        info11["s11ResponsibilitySelfOK"] is True,
        info11["s11LsAsnHiddenOK"] is True,
        info11["s11ObjcMetaAndReqHiddenOK"] is True,
        info11["s11Round1DlsymAndProcOK"] is True,
        info11["s11Round1VolumeAndCodeResOK"] is True,
        info11["s11Round1AppKitAndSuperBlobOK"] is True,
        info11["s11Round2CGAndHIDBlockedOK"] is True,
        info11["s11Round2FontsAndDlopenOK"] is True,
        info11["s11Round2MigThreadNetIopsOK"] is True,
        info11["s11Round3SignKernelCsrOK"] is True,
        info11["s11Round3DyldHandleUnwindOK"] is True,
        info11["s11Round3FsCasePathsAndIORegOK"] is True,
    ]
    results.append(ScenarioResult(
        name="11. 1.0.4 audit & detect-v2 parity checks",
        passed=all(checks11),
        duration_sec=time.monotonic() - t10,
        details=json.dumps({
            "inlineSvcMachine": info11["inlineSvcMachine"],
            "sysctlMachine": info11["sysctlMachine"],
            **{k: v for k, v in info11.items() if k.startswith("s11")},
        }, sort_keys=True),
    ))
    if verbose:
        print("  Scenario 11 payload:", {k: v for k, v in info11.items() if k.startswith("s11")})

    # Scenario 12: compat13_7 parity (freadlink, ExtensionKit, Metal 2.3 gate, AGX IORegistry)
    t12 = time.monotonic()
    isolated_root_12 = work_dir / "IsolatedHome12"
    container_data_12 = isolated_root_12 / "Library/Containers/app.makedie.harness.mockapp/Data"
    container_data_12.mkdir(parents=True, exist_ok=True)
    plist12_dir = isolated_root_12 / "Library/Containers/app.makedie.MacOver/PlayTools"
    plist12_dir.mkdir(parents=True, exist_ok=True)
    plist12 = plist12_dir / "app.makedie.harness.mockapp.plist"
    with open(plist12, "wb") as fp:
        plistlib.dump({
            "bypass": False,
            "strictEmulationMode": True,
            "strictViewportOrientation": "landscape",
            "strictViewportScaleMode": "fitScreen",
            "reportedIOSVersion": "compat13_7",
            "playChain": True,
        }, fp)
    marker12 = work_dir / "marker_12.txt"
    env12 = env9(
        marker12,
        HARNESS_TEST_SCENARIO12="1",
        APP_SANDBOX_CONTAINER_ID="app.makedie.harness.mockapp",
        HARNESS_GRACEFUL_EXIT="1",
    )
    env12["HOME"] = str(container_data_12)
    env12["CFFIXED_USER_HOME"] = str(container_data_12)
    env12["PLAYTOOLS_SETTINGS_PLIST"] = str(plist12)
    proc12 = run_cmd([str(patched_bin)], env=env12, check=False)
    if proc12.returncode != 0:
        results.append(ScenarioResult(
            name="12. compat13_7 parity (freadlink, ExtensionKit, Metal 2.3 gate, AGX IORegistry)",
            passed=False,
            duration_sec=time.monotonic() - t12,
            details=f"rc={proc12.returncode}\nstdout={proc12.stdout}\nstderr={proc12.stderr}",
        ))
        return results

    info12 = parse_harness_json(proc12.stdout)
    checks12 = [
        info12["safeModeActive"] is False,
        info12["reportedIOSVersion"] == "compat13_7",
        info12["s12FreadlinkHiddenOK"] is True,
        info12["s12ExtensionKitHiddenOK"] is True,
        info12["s12MetalCompat13GateOK"] is True,
        info12["s12IORegGpuSanitizedOK"] is True,
        info12["s12Post13EpochCleanOK"] is True,
        info12["s12Round1JscCAPICleanOK"] is True,
        info12["s12Round1ReflectionParityOK"] is True,
        info12["s12Round2Compat13EpochOK"] is True,
        info12["s12Round3IcuSwiftAvailOK"] is True,
    ]
    results.append(ScenarioResult(
        name="12. compat13_7 parity (freadlink, ExtensionKit, Metal 2.3 gate, AGX IORegistry)",
        passed=all(checks12),
        duration_sec=time.monotonic() - t12,
        details=json.dumps({
            "reportedIOSVersion": info12["reportedIOSVersion"],
            **{k: v for k, v in info12.items() if k.startswith("s12")},
        }, sort_keys=True),
    ))
    if verbose:
        print("  Scenario 12 payload:", {k: v for k, v in info12.items() if k.startswith("s12")})

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
