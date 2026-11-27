import Foundation
import Testing

extension PlayToolsGlobalStateScope {
@Suite(.serialized)
final class PTRegistrationTests {
    init() {
        pt_reset_hidden_registry_for_testing()
    }

    deinit {
        pt_reset_hidden_registry_for_testing()
    }

    @Test
    func moduleClassAndHeaderRegistrationAndGenerationTracking() {
        let startGen = pt_hidden_registry_generation()
        #expect(pt_registered_hidden_module_count() == 0)
        #expect(pt_registered_hidden_class_count() == 0)
        #expect(pt_registered_hidden_image_header_count() == 0)

        // Null and empty inputs are ignored safely
        pt_register_hidden_module(nil)
        pt_register_hidden_module("")
        pt_register_hidden_class(nil)
        pt_register_hidden_class("")
        pt_register_hidden_image_header(nil)
        #expect(pt_hidden_registry_generation() == startGen)

        pt_register_hidden_module("CustomOverlayPlugin")
        #expect(pt_registered_hidden_module_count() == 1)
        let afterModGen = pt_hidden_registry_generation()
        #expect(afterModGen > startGen)
        #expect(pt_is_registered_hidden_module("/App/Frameworks/UserPlugins/CustomOverlayPlugin.dylib"))
        #expect(!pt_is_registered_hidden_module("/System/Library/Frameworks/UIKit.framework/UIKit"))

        // Duplicate module registration is a no-op
        pt_register_hidden_module("CustomOverlayPlugin")
        #expect(pt_registered_hidden_module_count() == 1)
        #expect(pt_hidden_registry_generation() == afterModGen)

        // Class registration & prefix matching
        pt_register_hidden_class("VendorTelemetryHook")
        #expect(pt_registered_hidden_class_count() == 1)
        #expect(pt_is_registered_hidden_class("VendorTelemetryHook"))
        #expect(pt_is_registered_hidden_class("VendorTelemetryHook_Impl"))
        #expect(!pt_is_registered_hidden_class("UIViewController"))

        // Header pointer registration
        let fakeHeader = UnsafeRawPointer(bitPattern: 0x1_0400_0000)
        pt_register_hidden_image_header(fakeHeader)
        #expect(pt_registered_hidden_image_header_count() == 1)
        #expect(pt_is_registered_hidden_image_header(fakeHeader))
        #expect(!pt_is_registered_hidden_image_header(UnsafeRawPointer(bitPattern: 0x1_0400_4000)))
    }

    @Test
    func concurrentRegistrationsAndReads() {
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
        #expect(group.wait(timeout: .now() + 5) == .success)
        #expect(pt_registered_hidden_module_count() == 40)
        #expect(pt_registered_hidden_class_count() == 40)
        #expect(pt_is_registered_hidden_module("StressMod_39"))
    }
}
}
