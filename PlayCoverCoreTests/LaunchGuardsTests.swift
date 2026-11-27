import AppKit
import Foundation
import Testing
@testable import PlayCover

@Suite
struct LaunchGuardsTests {
    @Test
    func processInfoIsRunningUnitTestsIsTrue() {
        #expect(ProcessInfo.isRunningUnitTests)
    }

    @Test
    @MainActor
    func guardedServicesAndAppDelegateExecuteSafelyInUnitTests() {
        let deps = PlayCoverDependencies(loadInitialData: false)
        let beforeCount = deps.log.logdata.count
        deps.log.msg("LaunchGuardsTests.msg")
        deps.log.error("LaunchGuardsTests.error")
        #expect(deps.log.logdata.count > beforeCount)
        #expect(deps.log.logdata.contains("LaunchGuardsTests.msg"))
        #expect(deps.log.logdata.contains("ERROR: LaunchGuardsTests.error"))

        deps.notifyService.allowNotify()
        deps.notifyService.notify("Title", "Message")
        deps.soundDeviceService.prepareSoundDevice()
        UpdateScheme.checkForUpdate()

        let updater = UpdaterViewModel()
        #expect(!updater.canCheckForUpdates)
        updater.checkForUpdates()

        let delegate = AppDelegate(dependencies: deps)
        delegate.application(NSApplication.shared, open: [URL(fileURLWithPath: "/tmp/nonexistent.ipa")])
        delegate.powerModal()
    }
}
