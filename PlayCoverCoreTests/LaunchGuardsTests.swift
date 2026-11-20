import AppKit
import Foundation
import XCTest
@testable import PlayCover

final class LaunchGuardsTests: XCTestCase {
    func testProcessInfoIsRunningUnitTestsIsTrue() {
        XCTAssertTrue(ProcessInfo.isRunningUnitTests)
    }

    func testGuardedServicesAndAppDelegateExecuteSafelyInUnitTests() {
        let deps = PlayCoverDependencies(loadInitialData: false)
        let beforeCount = deps.log.logdata.count
        deps.log.msg("LaunchGuardsTests.msg")
        deps.log.error("LaunchGuardsTests.error")
        XCTAssertGreaterThan(deps.log.logdata.count, beforeCount)
        XCTAssertTrue(deps.log.logdata.contains("LaunchGuardsTests.msg"))
        XCTAssertTrue(deps.log.logdata.contains("ERROR: LaunchGuardsTests.error"))

        deps.notifyService.allowNotify()
        deps.notifyService.notify("Title", "Message")
        deps.soundDeviceService.prepareSoundDevice()
        UpdateScheme.checkForUpdate()

        let updater = UpdaterViewModel()
        XCTAssertFalse(updater.canCheckForUpdates)
        updater.checkForUpdates()

        let delegate = AppDelegate(dependencies: deps)
        delegate.application(NSApplication.shared, open: [URL(fileURLWithPath: "/tmp/nonexistent.ipa")])
        delegate.powerModal()
    }
}
