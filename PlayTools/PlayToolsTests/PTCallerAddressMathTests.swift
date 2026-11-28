import Dispatch
import Foundation
import Synchronization
import Testing

extension PlayToolsGlobalStateScope {
@Suite(.serialized)
struct PTCallerAddressMathTests {
    @Test
    func alignmentAndCacheSlotRange() {
        #expect(!pt_caller_addr_is_cacheable_aligned(0))
        #expect(pt_caller_addr_is_cacheable_aligned(0x1_0000_4000))
        #expect(!pt_caller_addr_is_cacheable_aligned(0x1_0000_4001))
        #expect(!pt_caller_addr_is_cacheable_aligned(0x1_0000_4002))
        #expect(!pt_caller_addr_is_cacheable_aligned(0x1_0000_4003))

        for addr: UInt64 in [0x1_0000_0000, 0x1_8000_1234, 0x1_FFFF_FFFC, 0x7FFF_FFFF_FFFC] {
            let slot = pt_caller_addr_cache_slot(addr)
            #expect(slot < Int(PT_CALLER_ADDR_CACHE_SIZE))
        }
    }

    @Test
    func packUnpackAndMatch() {
        let addr: UInt64 = 0x1_0420_8000
        let kinds = [
            UInt8(PT_CALLER_APP),
            UInt8(PT_CALLER_SYS_NON_WRAPPER),
            UInt8(PT_CALLER_PLAYTOOLS),
            UInt8(PT_CALLER_SYS_WRAPPER)
        ]

        for kind in kinds {
            var packed: UInt64 = 0
            #expect(pt_caller_addr_try_pack(addr, kind, &packed))
            #expect(packed == pt_caller_addr_pack(addr, kind))

            var matchedKind: UInt8 = 0
            #expect(pt_caller_addr_cache_match(packed, addr, &matchedKind))
            #expect(matchedKind == kind)
            #expect(!pt_caller_addr_cache_match(packed, addr + 4, &matchedKind))
        }

        #expect(pt_caller_addr_pack(addr, UInt8(PT_CALLER_UNKNOWN)) == 0)
        #expect(pt_caller_addr_pack(addr, 5) == 0)
        #expect(pt_caller_addr_pack(0, UInt8(PT_CALLER_APP)) == 0)
        #expect(pt_caller_addr_pack(addr + 1, UInt8(PT_CALLER_APP)) == 0)

        var unusedKind: UInt8 = 0
        #expect(!pt_caller_addr_cache_match(0, addr, &unusedKind))
    }

    @Test
    func stripReturnAndHighBitsAndValidUserAddr() {
        let baseAddr: UInt = 0x1_0000_1000
        #expect(pt_strip_high_bits_addr(baseAddr) == baseAddr)
        #expect(pt_strip_high_bits_addr(0x0012_0001_0000_1000) == baseAddr)
        #expect(pt_strip_high_bits_addr(0) == 0)

        #expect(UInt(bitPattern: pt_strip_return_addr(0)) == 0)
        let strippedPtr = pt_strip_return_addr(0x0012_0001_0000_1000)
        #expect((UInt(bitPattern: strippedPtr) & UInt(PT_USER_ADDR_STRIP_MASK)) == baseAddr)

        #expect(!pt_is_valid_user_addr(0))
        #expect(!pt_is_valid_user_addr(UInt(bitPattern: -1)))
        #expect(!pt_is_valid_user_addr(UInt(0xFFFF_0000_0000_0000)))
        #expect(!pt_is_valid_user_addr(0x0000_0FFF_FFFF))
        #expect(pt_is_valid_user_addr(0x0012_0001_0000_1000))
    }

    @Test
    func wrapperLibraryAndCallerImagePathClassification() {
        #expect(!pt_is_wrapper_library_path(nil))
        #expect(pt_is_wrapper_library_path("/usr/lib/system/libsystem_kernel.dylib"))
        #expect(pt_is_wrapper_library_path("/usr/lib/swift/libswiftCore.dylib"))
        #expect(pt_is_wrapper_library_path("/System/Library/Frameworks/Foundation.framework/Foundation"))
        #expect(!pt_is_wrapper_library_path("/System/Library/Frameworks/UIKit.framework/UIKit"))

        var cacheable = false
        #expect(pt_classify_caller_image_path(nil, &cacheable) == UInt8(PT_CALLER_APP))
        #expect(!cacheable)

        #expect(
            pt_classify_caller_image_path("/usr/lib/system/libsystem_c.dylib", &cacheable) ==
                UInt8(PT_CALLER_SYS_WRAPPER)
        )
        #expect(cacheable)

        #expect(
            pt_classify_caller_image_path("/System/Library/Frameworks/Metal.framework/Metal", &cacheable) ==
                UInt8(PT_CALLER_SYS_NON_WRAPPER)
        )
        #expect(cacheable)

        #expect(
            pt_classify_caller_image_path("/Users/u/Frameworks/PlayTools.framework/PlayTools", &cacheable) ==
                UInt8(PT_CALLER_PLAYTOOLS)
        )
        #expect(cacheable)

        #expect(
            pt_classify_caller_image_path(
                "/Users/u/Library/Containers/app.makedie.MacOver/Frameworks/PlayTools.framework/PlayTools",
                &cacheable
            ) == UInt8(PT_CALLER_PLAYTOOLS)
        )
        #expect(cacheable)

        let akPath = "/Users/u/Library/Containers/app.makedie.MacOver/Frameworks/PlayTools.framework/" +
            "PlugIns/AKInterface.bundle/Contents/MacOS/AKInterface"
        let akKind = pt_classify_caller_image_path(akPath, &cacheable)
        #expect(akKind == UInt8(PT_CALLER_PLAYTOOLS))
        #expect(cacheable)

        #expect(
            pt_classify_caller_image_path("/Applications/Game.app/Contents/MacOS/Game", &cacheable) ==
                UInt8(PT_CALLER_APP)
        )
        #expect(cacheable)

        #expect(pt_classify_caller_image_path("/tmp/custom.dylib", &cacheable) == UInt8(PT_CALLER_APP))
        #expect(!cacheable)
    }

    @Test
    func highBitBoundaryAddressesAndNullOutPointers() {
        #expect(!pt_is_valid_user_addr(0x0000_0000_FFFF_FFFF))
        #expect(pt_is_valid_user_addr(0x0000_0001_0000_0000))
        // 48-bit user VA (bit 47 set) is preserved after removing the 47-bit mask flaw
        #expect(pt_is_valid_user_addr(0x0000_8000_0000_0000))
        #expect(!pt_is_valid_user_addr(0x0012_0000_0000_0000))
        #expect(pt_is_valid_user_addr(0xFFFE_0001_0000_1000))
        #expect(!pt_is_valid_user_addr(0xFFFF_0000_0000_0000))

        // Width-aware address stripping supports both 48-bit and 52-bit LVA
        #expect(pt_strip_high_bits_addr_with_width(0x00F4_8000_1234_5000, 48) == 0x0000_8000_1234_5000)
        #expect(pt_strip_high_bits_addr_with_width(0x00F4_8000_1234_5000, 52) == 0x0004_8000_1234_5000)

        let addr: UInt64 = 0x1_0420_8000
        #expect(pt_caller_addr_try_pack(addr, UInt8(PT_CALLER_APP), nil))
        let packed = pt_caller_addr_pack(addr, UInt8(PT_CALLER_PLAYTOOLS))
        #expect(pt_caller_addr_cache_match(packed, addr, nil))
        #expect(pt_classify_caller_image_path("/usr/lib/libz.1.dylib", nil) == UInt8(PT_CALLER_SYS_WRAPPER))
    }

    @Test
    func allWrapperLibrariesAndPathSpoofingEdges() {
        #expect(!pt_is_wrapper_library_path(""))
        #expect(!pt_is_wrapper_library_path("/usr/lib/system/../../tmp/evil.dylib"))

        let wrapperPaths = [
            "/usr/lib/libz.1.dylib",
            "/usr/lib/libxml2.2.dylib",
            "/usr/lib/libarchive.2.dylib",
            "/usr/lib/libc++.1.dylib",
            "/usr/lib/libobjc.A.dylib",
            "/usr/lib/libsqlite3.dylib",
            "/System/Library/Frameworks/FoundationEssentials.framework/FoundationEssentials",
            "/System/Library/Frameworks/FoundationInternationalization.framework/FoundationInternationalization",
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
            "/System/Library/PrivateFrameworks/CoreServicesInternal.framework/CoreServicesInternal"
        ]
        for path in wrapperPaths {
            #expect(pt_is_wrapper_library_path(path), "Expected wrapper library for \(path)")
        }

        var cacheable = true
        #expect(pt_classify_caller_image_path("", &cacheable) == UInt8(PT_CALLER_APP))
        #expect(!cacheable)

        let longPath = "/Applications/" + String(repeating: "a", count: 4100) + "/App.app/Contents/MacOS/App"
        #expect(pt_classify_caller_image_path(longPath, &cacheable) == UInt8(PT_CALLER_APP))
        #expect(cacheable)

        // Spoofed parent directory named "PlayTools" must classify as app, not PlayTools
        cacheable = false
        #expect(
            pt_classify_caller_image_path("/Users/PlayTools/Games/App.app/Contents/MacOS/App", &cacheable) ==
                UInt8(PT_CALLER_APP)
        )
        #expect(cacheable)

        // Embedded PlayTools, AKInterface, and UserPlugins inside .app must classify as PT_CALLER_PLAYTOOLS
        #expect(
            pt_classify_caller_image_path(
                "/Applications/Game.app/Contents/Frameworks/PlayTools.framework/PlayTools",
                &cacheable
            ) == UInt8(PT_CALLER_PLAYTOOLS)
        )
        #expect(cacheable)
        let embeddedAkPath = "/Applications/Game.app/Contents/Frameworks/PlayTools.framework/" +
            "PlugIns/AKInterface.bundle/Contents/MacOS/AKInterface"
        #expect(pt_classify_caller_image_path(embeddedAkPath, &cacheable) == UInt8(PT_CALLER_PLAYTOOLS))
        #expect(cacheable)
        #expect(
            pt_classify_caller_image_path(
                "/Applications/Game.app/Contents/Frameworks/UserPlugins/plugin.dylib",
                &cacheable
            ) == UInt8(PT_CALLER_PLAYTOOLS)
        )
        #expect(cacheable)

        // Path traversal escaping /System/ must not classify as system library or cacheable
        cacheable = true
        #expect(
            pt_classify_caller_image_path("/System/../Applications/App.app/Contents/MacOS/App", &cacheable) ==
                UInt8(PT_CALLER_APP)
        )
        #expect(!cacheable)

        // Spoofed AKInterface.bundle / PlayTools.framework outside expected bundle segments (G-03)
        cacheable = false
        #expect(
            pt_classify_caller_image_path("/Users/AKInterface.bundle/Fake.app/Contents/MacOS/App", &cacheable) ==
                UInt8(PT_CALLER_APP)
        )
        #expect(cacheable)

        cacheable = false
        let resPtPath = "/Applications/Game.app/Contents/Resources/PlayTools.framework/Evil"
        #expect(pt_classify_caller_image_path(resPtPath, &cacheable) == UInt8(PT_CALLER_APP))
        #expect(cacheable)

        cacheable = false
        let fakeAppPath = "/Users/Frameworks/PlayTools.framework/Fake.app/Contents/MacOS/App"
        #expect(pt_classify_caller_image_path(fakeAppPath, &cacheable) == UInt8(PT_CALLER_APP))
        #expect(cacheable)

        // Non-system paths containing wrapper library substrings must not match pt_is_wrapper_library_path
        #expect(!pt_is_wrapper_library_path("/tmp/libc++.1.dylib"))
        #expect(
            !pt_is_wrapper_library_path(
                "/Applications/Game.app/Contents/Frameworks/Foundation.framework/Foundation"
            )
        )
    }

    @Test
    func compoundCacheKeysAndWrapperCachePacking() {
        let wrapperLR: UInt = 0x1_9000_1000
        let appSiteLR: UInt = 0x1_0200_4000
        let ptSiteLR: UInt = 0x1_0800_8000

        let appKey = pt_caller_compound_key(wrapperLR, appSiteLR)
        let ptKey = pt_caller_compound_key(wrapperLR, ptSiteLR)
        #expect(appKey != ptKey)
        #expect((appKey & 3) == 0)
        #expect((ptKey & 3) == 0)
        #expect(appKey != 0)

        let k3a = pt_caller_compound_key3(wrapperLR, appSiteLR, 0x1_9000_2000)
        let k3b = pt_caller_compound_key3(wrapperLR, appSiteLR, 0x1_9000_3000)
        #expect(k3a != k3b)
        #expect(pt_caller_compound_key3(0, 0, 0) == 4)

        #expect(pt_wrapper_cache_slot(k3a) < Int(PT_WRAPPER_CACHE_SIZE))
        let packedApp = pt_wrapper_cache_pack(k3a, false)
        let packedSys = pt_wrapper_cache_pack(k3b, true)

        var matched = true
        #expect(pt_wrapper_cache_match(packedApp, k3a, &matched))
        #expect(!matched)
        #expect(!pt_wrapper_cache_match(packedApp, k3b, &matched))
        #expect(pt_wrapper_cache_match(packedSys, k3b, &matched))
        #expect(matched)
        #expect(!pt_wrapper_cache_match(0, k3a, &matched))
        #expect(!pt_wrapper_cache_match(k3a, k3a, &matched))
    }

    @Test
    func boundedFrameClassifierCapsDepthAndRespectsWrapperTransitions() {
        #expect(PT_MAX_CALLER_UNWIND_DEPTH == 32)

        let appDirect: [UInt8] = [
            UInt8(PT_CALLER_SYS_WRAPPER),
            UInt8(PT_CALLER_APP)
        ]
        #expect(
            !appDirect.withUnsafeBufferPointer {
                pt_classify_bounded_frame_kinds($0.baseAddress, $0.count, true)
            }
        )

        let playtoolsThroughWrapper: [UInt8] = [
            UInt8(PT_CALLER_SYS_WRAPPER),
            UInt8(PT_CALLER_SYS_WRAPPER),
            UInt8(PT_CALLER_PLAYTOOLS)
        ]
        #expect(
            playtoolsThroughWrapper.withUnsafeBufferPointer {
                pt_classify_bounded_frame_kinds($0.baseAddress, $0.count, true)
            }
        )

        // Deep wrapper chain (13+ system frames above app frame) must unwind to app
        var nsInvocationAppChain = Array(repeating: UInt8(PT_CALLER_SYS_WRAPPER), count: 14)
        nsInvocationAppChain.append(UInt8(PT_CALLER_APP))
        var cacheable = true
        #expect(
            !nsInvocationAppChain.withUnsafeBufferPointer {
                pt_classify_bounded_frame_kinds_ex($0.baseAddress, $0.count, true, &cacheable)
            }
        )
        #expect(!cacheable)

        // 32nd frame (index 31) is within PT_MAX_CALLER_UNWIND_DEPTH=32 and must unwind to app
        var maxDepthAppChain = Array(repeating: UInt8(PT_CALLER_SYS_WRAPPER), count: 31)
        maxDepthAppChain.append(UInt8(PT_CALLER_APP))
        cacheable = true
        #expect(
            !maxDepthAppChain.withUnsafeBufferPointer {
                pt_classify_bounded_frame_kinds_ex($0.baseAddress, $0.count, true, &cacheable)
            }
        )
        #expect(!cacheable)

        // 33rd frame (beyond PT_MAX_CALLER_UNWIND_DEPTH=32) must NOT be unwound
        var deepAppBeyondCap = Array(repeating: UInt8(PT_CALLER_SYS_WRAPPER), count: 32)
        deepAppBeyondCap.append(UInt8(PT_CALLER_APP))
        cacheable = true
        #expect(
            deepAppBeyondCap.withUnsafeBufferPointer {
                pt_classify_bounded_frame_kinds_ex($0.baseAddress, $0.count, false, &cacheable)
            }
        )
        #expect(!cacheable)

        // 3-frame cacheability: resolved within [0..2] -> cacheable; resolved at >= 3 -> not cacheable
        let shallowSys: [UInt8] = [
            UInt8(PT_CALLER_SYS_WRAPPER),
            UInt8(PT_CALLER_SYS_WRAPPER),
            UInt8(PT_CALLER_SYS_NON_WRAPPER)
        ]
        cacheable = false
        #expect(
            shallowSys.withUnsafeBufferPointer {
                pt_classify_bounded_frame_kinds_ex($0.baseAddress, $0.count, true, &cacheable)
            }
        )
        #expect(cacheable)

        let deeperSys: [UInt8] = [
            UInt8(PT_CALLER_SYS_WRAPPER),
            UInt8(PT_CALLER_SYS_WRAPPER),
            UInt8(PT_CALLER_SYS_WRAPPER),
            UInt8(PT_CALLER_SYS_NON_WRAPPER)
        ]
        cacheable = true
        #expect(
            deeperSys.withUnsafeBufferPointer {
                pt_classify_bounded_frame_kinds_ex($0.baseAddress, $0.count, true, &cacheable)
            }
        )
        // CRIT-04: Never stop unwinding at PT_CALLER_PLAYTOOLS; app -> swizzled pm_* -> wrapper must resolve to app
        let appThroughPlayTools: [UInt8] = [
            UInt8(PT_CALLER_SYS_WRAPPER),
            UInt8(PT_CALLER_PLAYTOOLS),
            UInt8(PT_CALLER_APP)
        ]
        cacheable = false
        #expect(
            !appThroughPlayTools.withUnsafeBufferPointer {
                pt_classify_bounded_frame_kinds_ex($0.baseAddress, $0.count, true, &cacheable)
            }
        )
        #expect(cacheable)

        let sysThroughPlayTools: [UInt8] = [
            UInt8(PT_CALLER_SYS_WRAPPER),
            UInt8(PT_CALLER_PLAYTOOLS),
            UInt8(PT_CALLER_SYS_NON_WRAPPER)
        ]
        cacheable = false
        #expect(
            sysThroughPlayTools.withUnsafeBufferPointer {
                pt_classify_bounded_frame_kinds_ex($0.baseAddress, $0.count, true, &cacheable)
            }
        )
        #expect(cacheable)

        let deepAppThroughPlayTools: [UInt8] = [
            UInt8(PT_CALLER_SYS_WRAPPER),
            UInt8(PT_CALLER_SYS_WRAPPER),
            UInt8(PT_CALLER_PLAYTOOLS),
            UInt8(PT_CALLER_APP)
        ]
        cacheable = true
        #expect(
            !deepAppThroughPlayTools.withUnsafeBufferPointer {
                pt_classify_bounded_frame_kinds_ex($0.baseAddress, $0.count, true, &cacheable)
            }
        )
        #expect(!cacheable)

        let wrappedAppThroughPlayTools: [UInt8] = [
            UInt8(PT_CALLER_SYS_WRAPPER),
            UInt8(PT_CALLER_PLAYTOOLS),
            UInt8(PT_CALLER_SYS_WRAPPER),
            UInt8(PT_CALLER_APP)
        ]
        cacheable = true
        #expect(
            !wrappedAppThroughPlayTools.withUnsafeBufferPointer {
                pt_classify_bounded_frame_kinds_ex($0.baseAddress, $0.count, true, &cacheable)
            }
        )
        #expect(!cacheable)
    }

    @Test
    func pathEarlyExitAndInternalScopeIsolation() {
        pt_reset_hidden_registry_for_testing()
        defer { pt_reset_hidden_registry_for_testing() }

        let bundle = "/Applications/Game.app"
        let data = "/private/var/mobile/Containers/Data/Application/UUID-123"
        let bundleLen = bundle.utf8.count
        let dataLen = data.utf8.count

        bundle.withCString { bundlePtr in
            data.withCString { dataPtr in
                // Safe bundle assets & container tmp skip caller unwinding
                let allowBundleData = pt_is_nonsensitive_app_or_tmp_path(
                    "/Applications/Game.app/Data/level0.pak",
                    bundlePtr, bundleLen,
                    dataPtr, dataLen
                )
                #expect(allowBundleData)

                let allowFirmlinkInfo = pt_is_nonsensitive_app_or_tmp_path(
                    "/System/Volumes/Data/Applications/Game.app/Info.plist",
                    bundlePtr, bundleLen,
                    dataPtr, dataLen
                )
                #expect(allowFirmlinkInfo)

                let allowContainerTmp = pt_is_nonsensitive_app_or_tmp_path(
                    "/var/mobile/Containers/Data/Application/UUID-123/tmp/cache.dat",
                    bundlePtr, bundleLen,
                    dataPtr, dataLen
                )
                #expect(allowContainerTmp)

                // Embedded PlayTools / UserPlugins / registered modules / traversal never early-exit
                let blockPlayTools = pt_is_nonsensitive_app_or_tmp_path(
                    "/Applications/Game.app/Frameworks/PlayTools.framework/PlayTools",
                    bundlePtr, bundleLen,
                    dataPtr, dataLen
                )
                #expect(!blockPlayTools)

                let blockTraversal = pt_is_nonsensitive_app_or_tmp_path(
                    "/var/mobile/Containers/Data/Application/UUID-123/tmp/../Library/Preferences/x.plist",
                    bundlePtr, bundleLen,
                    dataPtr, dataLen
                )
                #expect(!blockTraversal)

                let blockLibraryCaches = pt_is_nonsensitive_app_or_tmp_path(
                    "/var/mobile/Containers/Data/Application/UUID-123/Library/Caches/db.sqlite",
                    bundlePtr, bundleLen,
                    dataPtr, dataLen
                )
                #expect(!blockLibraryCaches)

                pt_register_hidden_module("CustomPlugin.dylib")
                let blockRegisteredModule = pt_is_nonsensitive_app_or_tmp_path(
                    "/var/mobile/Containers/Data/Application/UUID-123/tmp/CustomPlugin.dylib",
                    bundlePtr, bundleLen,
                    dataPtr, dataLen
                )
                #expect(!blockRegisteredModule)

                // MED-02: Runtime artifacts (keymapping state & toucher.log) must never fast-path
                let blockKeymapState = pt_is_nonsensitive_app_or_tmp_path(
                    "/var/mobile/Containers/Data/Application/UUID-123/tmp/pm_keymapping_state.plist",
                    bundlePtr, bundleLen,
                    dataPtr, dataLen
                )
                #expect(!blockKeymapState)

                let blockScopedKeymapState = pt_is_nonsensitive_app_or_tmp_path(
                    "/var/mobile/Containers/Data/Application/UUID-123/tmp/pm_keymapping_state_com_example_game.plist",
                    bundlePtr, bundleLen,
                    dataPtr, dataLen
                )
                #expect(!blockScopedKeymapState)

                let blockToucherLog = pt_is_nonsensitive_app_or_tmp_path(
                    "/var/mobile/Containers/Data/Application/UUID-123/tmp/toucher.log",
                    bundlePtr, bundleLen,
                    dataPtr, dataLen
                )
                #expect(!blockToucherLog)
            }
        }

        // Nested TLS internal scope must not leak across threads
        #expect(!pt_is_in_internal_scope())
        pt_enter_internal_scope()
        pt_enter_internal_scope()
        #expect(pt_is_in_internal_scope())

        let done = DispatchSemaphore(value: 0)
        let otherThreadSawScope = Mutex(true)
        DispatchQueue.global().async {
            let saw = pt_is_in_internal_scope()
            otherThreadSawScope.withLock { $0 = saw }
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 2.0) == .success)
        #expect(!otherThreadSawScope.withLock { $0 })

        pt_leave_internal_scope()
        #expect(pt_is_in_internal_scope())
        pt_leave_internal_scope()
        #expect(!pt_is_in_internal_scope())
        pt_leave_internal_scope()
        #expect(!pt_is_in_internal_scope())
    }

    @Test
    func runtimeUserVirtualAddressWidth52BitLVAAndReset() {
        defer { pt_configure_user_va_bits(48) }

        pt_configure_user_va_bits(52)
        #expect(pt_active_user_addr_strip_mask() == UInt64(PT_USER_ADDR_LVA_STRIP_MASK))
        #expect(
            pt_strip_high_bits_addr(0x00F4_8000_1234_5000) == 0x0004_8000_1234_5000
        )
        #expect(pt_is_valid_user_addr(0x0008_0000_0000_1000))

        pt_configure_user_va_bits(48)
        #expect(pt_active_user_addr_strip_mask() == UInt64(PT_USER_ADDR_STRIP_MASK))
        #expect(!pt_is_valid_user_addr(0x0008_0000_0000_1000))
    }
}
}
