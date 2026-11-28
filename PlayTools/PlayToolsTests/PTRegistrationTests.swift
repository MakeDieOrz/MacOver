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

    @Test
    func hiddenFDLoopbackPortAndOneShotAutomationBootstrap() {
        #expect(!pt_is_hidden_fd(42))
        pt_register_hidden_fd(42)
        #expect(pt_is_hidden_fd(42))
        #expect(!pt_is_hidden_fd(43))
        pt_unregister_hidden_fd(42)
        #expect(!pt_is_hidden_fd(42))

        #expect(!pt_is_hidden_loopback_port(51234))
        pt_register_hidden_loopback_port(51234)
        #expect(pt_is_hidden_loopback_port(51234))
        pt_unregister_hidden_loopback_port(51234)
        #expect(!pt_is_hidden_loopback_port(51234))

        #expect(!pt_has_automation_bootstrap())
        pt_store_automation_bootstrap(54321, "secret-token", "com.example.app", "/tmp/built-in/CoverUseBridge")
        #expect(pt_has_automation_bootstrap())

        var dirBuf = [CChar](repeating: 0, count: 256)
        #expect(pt_copy_automation_bootstrap_bridge_dir(&dirBuf, dirBuf.count))
        let copiedDir = dirBuf.withUnsafeBufferPointer { buf in
            buf.baseAddress.map { String(cString: $0) } ?? ""
        }
        #expect(copiedDir == "/tmp/built-in/CoverUseBridge")

        var port: UInt16 = 0
        var tokBuf = [CChar](repeating: 0, count: 128)
        var bidBuf = [CChar](repeating: 0, count: 128)
        #expect(pt_consume_automation_bootstrap(&port, &tokBuf, tokBuf.count, &bidBuf, bidBuf.count))
        #expect(port == 54321)
        let consumedTok = tokBuf.withUnsafeBufferPointer { buf in
            buf.baseAddress.map { String(cString: $0) } ?? ""
        }
        let consumedBid = bidBuf.withUnsafeBufferPointer { buf in
            buf.baseAddress.map { String(cString: $0) } ?? ""
        }
        #expect(consumedTok == "secret-token")
        #expect(consumedBid == "com.example.app")
        // One-shot consume clears stored bootstrap credentials immediately
        #expect(!pt_has_automation_bootstrap())
        #expect(!pt_consume_automation_bootstrap(&port, &tokBuf, tokBuf.count, &bidBuf, bidBuf.count))
    }
}
}
