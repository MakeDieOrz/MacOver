import Foundation
import XCTest
@testable import PlayCoverCore
@testable import PlayCoverUI

final class PlayCoverUISPMTests: XCTestCase {
    @MainActor
    func testAlertPresenterQueueOrderingAndDismissalSafety() async {
        let presenter = AlertPresenter(bypassUnitTestAutoResolve: true)

        let t1 = Task {
            await presenter.present(
                PlayCoverAlertRequest(
                    title: "Alert1",
                    message: "M1",
                    buttons: [
                        PlayCoverAlertButton(title: "Yes"),
                        PlayCoverAlertButton(title: "No", isCancel: true)
                    ],
                    suppressionTitle: "Remember"
                )
            )
        }
        let t2 = Task {
            await presenter.present(
                PlayCoverAlertRequest(
                    title: "Alert2",
                    message: "M2",
                    buttons: [
                        PlayCoverAlertButton(title: "Proceed"),
                        PlayCoverAlertButton(title: "Cancel", isCancel: true)
                    ]
                )
            )
        }

        for _ in 0..<10 where presenter.activeRequest == nil {
            await Task.yield()
        }
        XCTAssertEqual(presenter.activeRequest?.title, "Alert1")
        presenter.resolveActive(with: PlayCoverAlertResponse(buttonIndex: 0, suppressionChecked: true))

        let r1 = await t1.value
        XCTAssertEqual(r1, PlayCoverAlertResponse(buttonIndex: 0, suppressionChecked: true))

        await Task.yield()
        guard let secondID = presenter.activeRequest?.id else {
            return XCTFail("Expected second queued alert")
        }
        XCTAssertEqual(presenter.activeRequest?.title, "Alert2")
        // Simulate sheet dismissal via Escape/swipe instead of explicit button click.
        presenter.handleDismissed(requestID: secondID)
        let r2 = await t2.value
        XCTAssertEqual(r2, PlayCoverAlertResponse(buttonIndex: 1, suppressionChecked: false))
        XCTAssertNil(presenter.activeRequest)
    }

    @MainActor
    func testStartupAlertCenterSafeModeToastVMAndPreferences() {
        let center = StartupAlertCenter()
        let item = StartupAlertItem.safeModeActivated(
            appName: "Sample",
            bundleID: "com.example.sample",
            breadcrumbPath: "/tmp/crumb"
        )
        center.enqueue(item)
        center.enqueue(item)
        XCTAssertEqual(center.activeAlert, item)
        center.dismissCurrent()
        XCTAssertNil(center.activeAlert)

        let toastVM = ToastVM()
        let netID = toastVM.showToast(toastType: .network, toastDetails: "Offline")
        let noteID = toastVM.showToast(toastType: .notice, toastDetails: "Notice")
        XCTAssertTrue(toastVM.hasToast(ofType: .network))
        XCTAssertTrue(toastVM.hasToast(ofType: .notice))
        XCTAssertFalse(toastVM.hasToast(ofType: .error))
        toastVM.dismiss(id: netID)
        XCTAssertFalse(toastVM.hasToast(ofType: .network))
        XCTAssertTrue(toastVM.hasToast(ofType: .notice))
        toastVM.dismiss(id: noteID)
        XCTAssertFalse(toastVM.hasToast(ofType: .notice))

        let suiteName = "PlayCoverUISPMTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let installPrefs = InstallPreferences(userDefaults: defaults)
        installPrefs.showInstallPopup = true
        XCTAssertTrue(InstallPreferences(userDefaults: defaults).showInstallPopup)

        let vm = InstallVM()
        XCTAssertFalse(vm.inProgress)
    }
}
