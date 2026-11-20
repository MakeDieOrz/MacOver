import XCTest

final class PTCallerAddressMathTests: XCTestCase {
    func testAlignmentAndCacheSlotRange() {
        XCTAssertFalse(pt_caller_addr_is_cacheable_aligned(0))
        XCTAssertTrue(pt_caller_addr_is_cacheable_aligned(0x1_0000_4000))
        XCTAssertFalse(pt_caller_addr_is_cacheable_aligned(0x1_0000_4001))
        XCTAssertFalse(pt_caller_addr_is_cacheable_aligned(0x1_0000_4002))
        XCTAssertFalse(pt_caller_addr_is_cacheable_aligned(0x1_0000_4003))

        for addr: UInt64 in [0x1_0000_0000, 0x1_8000_1234, 0x1_FFFF_FFFC, 0x7FFF_FFFF_FFFC] {
            let slot = pt_caller_addr_cache_slot(addr)
            XCTAssertLessThan(slot, Int(PT_CALLER_ADDR_CACHE_SIZE))
        }
    }

    func testPackUnpackAndMatch() {
        let addr: UInt64 = 0x1_0420_8000
        let kinds = [
            UInt8(PT_CALLER_APP),
            UInt8(PT_CALLER_SYS_NON_WRAPPER),
            UInt8(PT_CALLER_PLAYTOOLS),
            UInt8(PT_CALLER_SYS_WRAPPER)
        ]

        for kind in kinds {
            var packed: UInt64 = 0
            XCTAssertTrue(pt_caller_addr_try_pack(addr, kind, &packed))
            XCTAssertEqual(packed, pt_caller_addr_pack(addr, kind))

            var matchedKind: UInt8 = 0
            XCTAssertTrue(pt_caller_addr_cache_match(packed, addr, &matchedKind))
            XCTAssertEqual(matchedKind, kind)
            XCTAssertFalse(pt_caller_addr_cache_match(packed, addr + 4, &matchedKind))
        }

        XCTAssertEqual(pt_caller_addr_pack(addr, UInt8(PT_CALLER_UNKNOWN)), 0)
        XCTAssertEqual(pt_caller_addr_pack(addr, 5), 0)
        XCTAssertEqual(pt_caller_addr_pack(0, UInt8(PT_CALLER_APP)), 0)
        XCTAssertEqual(pt_caller_addr_pack(addr + 1, UInt8(PT_CALLER_APP)), 0)

        var unusedKind: UInt8 = 0
        XCTAssertFalse(pt_caller_addr_cache_match(0, addr, &unusedKind))
    }

    func testStripReturnAndHighBitsAndValidUserAddr() {
        let baseAddr: UInt = 0x1_0000_1000
        XCTAssertEqual(pt_strip_high_bits_addr(baseAddr), baseAddr)
        XCTAssertEqual(pt_strip_high_bits_addr(0x0012_0001_0000_1000), baseAddr)
        XCTAssertEqual(pt_strip_high_bits_addr(0), 0)

        XCTAssertEqual(UInt(bitPattern: pt_strip_return_addr(0)), 0)
        let strippedPtr = pt_strip_return_addr(0x0012_0001_0000_1000)
        XCTAssertEqual(UInt(bitPattern: strippedPtr) & UInt(PT_USER_ADDR_STRIP_MASK), baseAddr)

        XCTAssertFalse(pt_is_valid_user_addr(0))
        XCTAssertFalse(pt_is_valid_user_addr(UInt(bitPattern: -1)))
        XCTAssertFalse(pt_is_valid_user_addr(UInt(0xFFFF_0000_0000_0000)))
        XCTAssertFalse(pt_is_valid_user_addr(0x0000_0FFF_FFFF))
        XCTAssertTrue(pt_is_valid_user_addr(0x0012_0001_0000_1000))
    }

    func testWrapperLibraryAndCallerImagePathClassification() {
        XCTAssertFalse(pt_is_wrapper_library_path(nil))
        XCTAssertTrue(pt_is_wrapper_library_path("/usr/lib/system/libsystem_kernel.dylib"))
        XCTAssertTrue(pt_is_wrapper_library_path("/usr/lib/swift/libswiftCore.dylib"))
        XCTAssertTrue(pt_is_wrapper_library_path("/System/Library/Frameworks/Foundation.framework/Foundation"))
        XCTAssertFalse(pt_is_wrapper_library_path("/System/Library/Frameworks/UIKit.framework/UIKit"))

        var cacheable = false
        XCTAssertEqual(pt_classify_caller_image_path(nil, &cacheable), UInt8(PT_CALLER_APP))
        XCTAssertFalse(cacheable)

        XCTAssertEqual(
            pt_classify_caller_image_path("/usr/lib/system/libsystem_c.dylib", &cacheable),
            UInt8(PT_CALLER_SYS_WRAPPER)
        )
        XCTAssertTrue(cacheable)

        XCTAssertEqual(
            pt_classify_caller_image_path("/System/Library/Frameworks/Metal.framework/Metal", &cacheable),
            UInt8(PT_CALLER_SYS_NON_WRAPPER)
        )
        XCTAssertTrue(cacheable)

        XCTAssertEqual(
            pt_classify_caller_image_path("/Users/u/Frameworks/PlayTools.framework/PlayTools", &cacheable),
            UInt8(PT_CALLER_PLAYTOOLS)
        )
        XCTAssertTrue(cacheable)

        XCTAssertEqual(
            pt_classify_caller_image_path("/Applications/Game.app/Contents/MacOS/Game", &cacheable),
            UInt8(PT_CALLER_APP)
        )
        XCTAssertTrue(cacheable)

        XCTAssertEqual(
            pt_classify_caller_image_path("/tmp/custom.dylib", &cacheable),
            UInt8(PT_CALLER_APP)
        )
        XCTAssertFalse(cacheable)
    }

    func testHighBitBoundaryAddressesAndNullOutPointers() {
        XCTAssertFalse(pt_is_valid_user_addr(0x0000_0000_FFFF_FFFF))
        XCTAssertTrue(pt_is_valid_user_addr(0x0000_0001_0000_0000))
        // 48-bit user VA (bit 47 set) is preserved after removing the 47-bit mask flaw
        XCTAssertTrue(pt_is_valid_user_addr(0x0000_8000_0000_0000))
        XCTAssertFalse(pt_is_valid_user_addr(0x0012_0000_0000_0000))
        XCTAssertTrue(pt_is_valid_user_addr(0xFFFE_0001_0000_1000))
        XCTAssertFalse(pt_is_valid_user_addr(0xFFFF_0000_0000_0000))

        // Width-aware address stripping supports both 48-bit and 52-bit LVA
        XCTAssertEqual(
            pt_strip_high_bits_addr_with_width(0x00F4_8000_1234_5000, 48),
            0x0000_8000_1234_5000
        )
        XCTAssertEqual(
            pt_strip_high_bits_addr_with_width(0x00F4_8000_1234_5000, 52),
            0x0004_8000_1234_5000
        )

        let addr: UInt64 = 0x1_0420_8000
        XCTAssertTrue(pt_caller_addr_try_pack(addr, UInt8(PT_CALLER_APP), nil))
        let packed = pt_caller_addr_pack(addr, UInt8(PT_CALLER_PLAYTOOLS))
        XCTAssertTrue(pt_caller_addr_cache_match(packed, addr, nil))
        XCTAssertEqual(
            pt_classify_caller_image_path("/usr/lib/libz.1.dylib", nil),
            UInt8(PT_CALLER_SYS_WRAPPER)
        )
    }

    func testAllWrapperLibrariesAndPathSpoofingEdges() {
        XCTAssertFalse(pt_is_wrapper_library_path(""))
        XCTAssertFalse(pt_is_wrapper_library_path("/usr/lib/system/../../tmp/evil.dylib"))

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
            XCTAssertTrue(pt_is_wrapper_library_path(path), "Expected wrapper library for \(path)")
        }

        var cacheable = true
        XCTAssertEqual(pt_classify_caller_image_path("", &cacheable), UInt8(PT_CALLER_APP))
        XCTAssertFalse(cacheable)

        let longPath = "/Applications/" + String(repeating: "a", count: 4100) + "/App.app/Contents/MacOS/App"
        XCTAssertEqual(pt_classify_caller_image_path(longPath, &cacheable), UInt8(PT_CALLER_APP))
        XCTAssertTrue(cacheable)

        // Spoofed parent directory named "PlayTools" must classify as app, not PlayTools
        cacheable = false
        XCTAssertEqual(
            pt_classify_caller_image_path("/Users/PlayTools/Games/App.app/Contents/MacOS/App", &cacheable),
            UInt8(PT_CALLER_APP)
        )
        XCTAssertTrue(cacheable)

        // Embedded PlayTools, AKInterface, and UserPlugins inside .app must classify as PT_CALLER_PLAYTOOLS
        XCTAssertEqual(
            pt_classify_caller_image_path(
                "/Applications/Game.app/Contents/Frameworks/PlayTools.framework/PlayTools",
                &cacheable
            ),
            UInt8(PT_CALLER_PLAYTOOLS)
        )
        XCTAssertTrue(cacheable)
        XCTAssertEqual(
            pt_classify_caller_image_path(
                "/Applications/Game.app/Contents/Frameworks/PlayTools.framework/PlugIns/AKInterface.bundle/Contents/MacOS/AKInterface",
                &cacheable
            ),
            UInt8(PT_CALLER_PLAYTOOLS)
        )
        XCTAssertTrue(cacheable)
        XCTAssertEqual(
            pt_classify_caller_image_path(
                "/Applications/Game.app/Contents/Frameworks/UserPlugins/plugin.dylib",
                &cacheable
            ),
            UInt8(PT_CALLER_PLAYTOOLS)
        )
        XCTAssertTrue(cacheable)

        // Path traversal escaping /System/ must not classify as system library or cacheable
        cacheable = true
        XCTAssertEqual(
            pt_classify_caller_image_path("/System/../Applications/App.app/Contents/MacOS/App", &cacheable),
            UInt8(PT_CALLER_APP)
        )
        XCTAssertFalse(cacheable)

        // Spoofed AKInterface.bundle / PlayTools.framework outside expected bundle segments (G-03)
        cacheable = false
        XCTAssertEqual(
            pt_classify_caller_image_path("/Users/AKInterface.bundle/Fake.app/Contents/MacOS/App", &cacheable),
            UInt8(PT_CALLER_APP)
        )
        XCTAssertTrue(cacheable)

        cacheable = false
        XCTAssertEqual(
            pt_classify_caller_image_path("/Applications/Game.app/Contents/Resources/PlayTools.framework/Evil", &cacheable),
            UInt8(PT_CALLER_APP)
        )
        XCTAssertTrue(cacheable)

        cacheable = false
        XCTAssertEqual(
            pt_classify_caller_image_path("/Users/Frameworks/PlayTools.framework/Fake.app/Contents/MacOS/App", &cacheable),
            UInt8(PT_CALLER_APP)
        )
        XCTAssertTrue(cacheable)

        // Non-system paths containing wrapper library substrings must not match pt_is_wrapper_library_path
        XCTAssertFalse(pt_is_wrapper_library_path("/tmp/libc++.1.dylib"))
        XCTAssertFalse(pt_is_wrapper_library_path("/Applications/Game.app/Contents/Frameworks/Foundation.framework/Foundation"))
    }

    func testCompoundCacheKeysAndWrapperCachePacking() {
        let wrapperLR: UInt = 0x1_9000_1000
        let appSiteLR: UInt = 0x1_0200_4000
        let ptSiteLR: UInt = 0x1_0800_8000

        let appKey = pt_caller_compound_key(wrapperLR, appSiteLR)
        let ptKey = pt_caller_compound_key(wrapperLR, ptSiteLR)
        XCTAssertNotEqual(appKey, ptKey)
        XCTAssertEqual(appKey & 3, 0)
        XCTAssertEqual(ptKey & 3, 0)
        XCTAssertNotEqual(appKey, 0)

        let k3a = pt_caller_compound_key3(wrapperLR, appSiteLR, 0x1_9000_2000)
        let k3b = pt_caller_compound_key3(wrapperLR, appSiteLR, 0x1_9000_3000)
        XCTAssertNotEqual(k3a, k3b)
        XCTAssertEqual(pt_caller_compound_key3(0, 0, 0), 4)

        XCTAssertLessThan(pt_wrapper_cache_slot(k3a), Int(PT_WRAPPER_CACHE_SIZE))
        let packedApp = pt_wrapper_cache_pack(k3a, false)
        let packedSys = pt_wrapper_cache_pack(k3b, true)

        var matched = true
        XCTAssertTrue(pt_wrapper_cache_match(packedApp, k3a, &matched))
        XCTAssertFalse(matched)
        XCTAssertFalse(pt_wrapper_cache_match(packedApp, k3b, &matched))
        XCTAssertTrue(pt_wrapper_cache_match(packedSys, k3b, &matched))
        XCTAssertTrue(matched)
        XCTAssertFalse(pt_wrapper_cache_match(0, k3a, &matched))
        XCTAssertFalse(pt_wrapper_cache_match(k3a, k3a, &matched))
    }

    func testBoundedFrameClassifierCapsDepthAndRespectsWrapperTransitions() {
        XCTAssertEqual(PT_MAX_CALLER_UNWIND_DEPTH, 4)

        let appDirect: [UInt8] = [
            UInt8(PT_CALLER_SYS_WRAPPER),
            UInt8(PT_CALLER_APP)
        ]
        XCTAssertFalse(appDirect.withUnsafeBufferPointer {
            pt_classify_bounded_frame_kinds($0.baseAddress, $0.count, true)
        })

        let playtoolsThroughWrapper: [UInt8] = [
            UInt8(PT_CALLER_SYS_WRAPPER),
            UInt8(PT_CALLER_SYS_WRAPPER),
            UInt8(PT_CALLER_PLAYTOOLS)
        ]
        XCTAssertTrue(playtoolsThroughWrapper.withUnsafeBufferPointer {
            pt_classify_bounded_frame_kinds($0.baseAddress, $0.count, true)
        })

        // Fifth frame (beyond PT_MAX_CALLER_UNWIND_DEPTH=4) must NOT be unwound
        let deepAppBeyondCap: [UInt8] = [
            UInt8(PT_CALLER_SYS_WRAPPER),
            UInt8(PT_CALLER_SYS_WRAPPER),
            UInt8(PT_CALLER_SYS_WRAPPER),
            UInt8(PT_CALLER_SYS_WRAPPER),
            UInt8(PT_CALLER_APP)
        ]
        XCTAssertTrue(deepAppBeyondCap.withUnsafeBufferPointer {
            pt_classify_bounded_frame_kinds($0.baseAddress, $0.count, false)
        })
    }

    func testPathEarlyExitAndInternalScopeIsolation() {
        pt_reset_hidden_registry_for_testing()
        defer { pt_reset_hidden_registry_for_testing() }

        let bundle = "/Applications/Game.app"
        let data = "/private/var/mobile/Containers/Data/Application/UUID-123"

        // Safe bundle assets & container tmp skip caller unwinding
        XCTAssertTrue(pt_is_nonsensitive_app_or_tmp_path(
            "/Applications/Game.app/Data/level0.pak",
            bundle, bundle.utf8.count,
            data, data.utf8.count
        ))
        XCTAssertTrue(pt_is_nonsensitive_app_or_tmp_path(
            "/System/Volumes/Data/Applications/Game.app/Info.plist",
            bundle, bundle.utf8.count,
            data, data.utf8.count
        ))
        XCTAssertTrue(pt_is_nonsensitive_app_or_tmp_path(
            "/var/mobile/Containers/Data/Application/UUID-123/tmp/cache.dat",
            bundle, bundle.utf8.count,
            data, data.utf8.count
        ))

        // Embedded PlayTools / UserPlugins / registered modules / traversal never early-exit
        XCTAssertFalse(pt_is_nonsensitive_app_or_tmp_path(
            "/Applications/Game.app/Frameworks/PlayTools.framework/PlayTools",
            bundle, bundle.utf8.count,
            data, data.utf8.count
        ))
        XCTAssertFalse(pt_is_nonsensitive_app_or_tmp_path(
            "/var/mobile/Containers/Data/Application/UUID-123/tmp/../Library/Preferences/x.plist",
            bundle, bundle.utf8.count,
            data, data.utf8.count
        ))
        XCTAssertFalse(pt_is_nonsensitive_app_or_tmp_path(
            "/var/mobile/Containers/Data/Application/UUID-123/Library/Caches/db.sqlite",
            bundle, bundle.utf8.count,
            data, data.utf8.count
        ))
        pt_register_hidden_module("CustomPlugin.dylib")
        XCTAssertFalse(pt_is_nonsensitive_app_or_tmp_path(
            "/var/mobile/Containers/Data/Application/UUID-123/tmp/CustomPlugin.dylib",
            bundle, bundle.utf8.count,
            data, data.utf8.count
        ))

        // Nested TLS internal scope must not leak across threads
        XCTAssertFalse(pt_is_in_internal_scope())
        pt_enter_internal_scope()
        pt_enter_internal_scope()
        XCTAssertTrue(pt_is_in_internal_scope())

        let exp = expectation(description: "thread-local scope isolated")
        var otherThreadSawScope = true
        DispatchQueue.global().async {
            otherThreadSawScope = pt_is_in_internal_scope()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
        XCTAssertFalse(otherThreadSawScope)

        pt_leave_internal_scope()
        XCTAssertTrue(pt_is_in_internal_scope())
        pt_leave_internal_scope()
        XCTAssertFalse(pt_is_in_internal_scope())
        pt_leave_internal_scope()
        XCTAssertFalse(pt_is_in_internal_scope())
    }

    func testRuntimeUserVirtualAddressWidth52BitLVAAndReset() {
        defer { pt_configure_user_va_bits(48) }

        pt_configure_user_va_bits(52)
        XCTAssertEqual(pt_active_user_addr_strip_mask(), UInt64(PT_USER_ADDR_LVA_STRIP_MASK))
        let lvaAddr: UInt = 0x0004_8000_1234_5000
        let taggedLvaAddr: UInt = 0x00F4_8000_1234_5000
        XCTAssertEqual(pt_strip_high_bits_addr(taggedLvaAddr), lvaAddr)
        let strippedPtr = pt_strip_return_addr(taggedLvaAddr)
        XCTAssertEqual(UInt(bitPattern: strippedPtr) & UInt(PT_USER_ADDR_LVA_STRIP_MASK), lvaAddr)

        pt_configure_user_va_bits(48)
        XCTAssertEqual(pt_active_user_addr_strip_mask(), UInt64(PT_USER_ADDR_STRIP_MASK))
        XCTAssertEqual(pt_strip_high_bits_addr(taggedLvaAddr), 0x0000_8000_1234_5000)
    }
}
