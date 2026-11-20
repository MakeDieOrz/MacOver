import Foundation
import XCTest

final class PTRegistrationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        pt_reset_hidden_registry_for_testing()
    }

    override func tearDown() {
        pt_reset_hidden_registry_for_testing()
        super.tearDown()
    }

    func testModuleClassAndHeaderRegistrationAndGenerationTracking() {
        let startGen = pt_hidden_registry_generation()
        XCTAssertEqual(pt_registered_hidden_module_count(), 0)
        XCTAssertEqual(pt_registered_hidden_class_count(), 0)
        XCTAssertEqual(pt_registered_hidden_image_header_count(), 0)

        // Null and empty inputs are ignored safely
        pt_register_hidden_module(nil)
        pt_register_hidden_module("")
        pt_register_hidden_class(nil)
        pt_register_hidden_class("")
        pt_register_hidden_image_header(nil)
        XCTAssertEqual(pt_hidden_registry_generation(), startGen)

        pt_register_hidden_module("CustomOverlayPlugin")
        XCTAssertEqual(pt_registered_hidden_module_count(), 1)
        let afterModGen = pt_hidden_registry_generation()
        XCTAssertGreaterThan(afterModGen, startGen)
        XCTAssertTrue(pt_is_registered_hidden_module("/App/Frameworks/UserPlugins/CustomOverlayPlugin.dylib"))
        XCTAssertFalse(pt_is_registered_hidden_module("/System/Library/Frameworks/UIKit.framework/UIKit"))

        // Duplicate module registration is a no-op
        pt_register_hidden_module("CustomOverlayPlugin")
        XCTAssertEqual(pt_registered_hidden_module_count(), 1)
        XCTAssertEqual(pt_hidden_registry_generation(), afterModGen)

        // Class registration & prefix matching
        pt_register_hidden_class("VendorTelemetryHook")
        XCTAssertEqual(pt_registered_hidden_class_count(), 1)
        XCTAssertTrue(pt_is_registered_hidden_class("VendorTelemetryHook"))
        XCTAssertTrue(pt_is_registered_hidden_class("VendorTelemetryHook_Impl"))
        XCTAssertFalse(pt_is_registered_hidden_class("UIViewController"))

        // Header pointer registration
        let fakeHeader = UnsafeRawPointer(bitPattern: 0x1_0400_0000)
        pt_register_hidden_image_header(fakeHeader)
        XCTAssertEqual(pt_registered_hidden_image_header_count(), 1)
        XCTAssertTrue(pt_is_registered_hidden_image_header(fakeHeader))
        XCTAssertFalse(pt_is_registered_hidden_image_header(UnsafeRawPointer(bitPattern: 0x1_0400_4000)))
    }

    func testConcurrentRegistrationsAndReads() {
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "pt.reg.stress", attributes: .concurrent)

        for idx in 0..<40 {
            group.enter()
            queue.async {
                pt_register_hidden_module("StressMod_\(idx)")
                pt_register_hidden_class("StressCls_\(idx)")
                _ = pt_is_registered_hidden_module("/tmp/StressMod_\(idx).dylib")
                _ = pt_is_registered_hidden_class("StressCls_\(idx)")
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(pt_registered_hidden_module_count(), 40)
        XCTAssertEqual(pt_registered_hidden_class_count(), 40)
        XCTAssertTrue(pt_is_registered_hidden_module("StressMod_39"))
    }
}
