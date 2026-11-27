import Foundation
import Testing
@testable import PlayCoverCore
@testable import PlayCoverUI

@Suite(.serialized)
struct PlayCoverUISPMTests {
    @Test
    @MainActor
    func alertPresenterQueueOrderingAndDismissalSafety() async throws {
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
        #expect(presenter.activeRequest?.title == "Alert1")
        presenter.resolveActive(with: PlayCoverAlertResponse(buttonIndex: 0, suppressionChecked: true))

        let r1 = await t1.value
        #expect(r1 == PlayCoverAlertResponse(buttonIndex: 0, suppressionChecked: true))

        await Task.yield()
        let secondID = try #require(presenter.activeRequest?.id)
        #expect(presenter.activeRequest?.title == "Alert2")
        presenter.handleDismissed(requestID: secondID)
        let r2 = await t2.value
        #expect(r2 == PlayCoverAlertResponse(buttonIndex: 1, suppressionChecked: false))
        #expect(presenter.activeRequest == nil)
    }

    @Test
    @MainActor
    func startupAlertCenterSafeModeToastVMAndPreferences() throws {
        let center = StartupAlertCenter()
        let item = StartupAlertItem.safeModeActivated(
            appName: "Sample",
            bundleID: "com.example.sample",
            breadcrumbPath: "/tmp/crumb"
        )
        center.enqueue(item)
        center.enqueue(item)
        #expect(center.activeAlert == item)
        center.dismissCurrent()
        #expect(center.activeAlert == nil)

        let toastVM = ToastVM()
        let netID = toastVM.showToast(toastType: .network, toastDetails: "Offline")
        let noteID = toastVM.showToast(toastType: .notice, toastDetails: "Notice")
        #expect(toastVM.hasToast(ofType: .network))
        #expect(toastVM.hasToast(ofType: .notice))
        #expect(!toastVM.hasToast(ofType: .error))
        toastVM.dismiss(id: netID)
        #expect(!toastVM.hasToast(ofType: .network))
        #expect(toastVM.hasToast(ofType: .notice))
        toastVM.dismiss(id: noteID)
        #expect(!toastVM.hasToast(ofType: .notice))

        let suiteName = "PlayCoverUISPMTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let installPrefs = InstallPreferences(userDefaults: defaults)
        installPrefs.showInstallPopup = true
        #expect(InstallPreferences(userDefaults: defaults).showInstallPopup)

        let vm = InstallVM()
        #expect(!vm.inProgress)
    }

    @Test
    @MainActor
    func progressVMHandlesBackgroundUpdatesAndCancelsPendingDismissalOnRestart() async throws {
        enum SampleStep: String, Sendable {
            case start
            case mid
            case done
        }

        let vm = ProgressVM<SampleStep>(start: .start, ends: [.done])
        await Task.detached {
            vm.next(.start, 0.0, 0.2)
            vm.updateProgress(0.45)
        }.value

        // Allow MainActor hop queued by nonisolated helpers to flush
        for _ in 0..<20 where !vm.inProgress || vm.progress < 0.4 {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(vm.status == .start)
        #expect(vm.inProgress)
        #expect(abs(vm.progress - 0.45) < 0.01)

        vm.next(.done, 1.0, 1.0)
        #expect(vm.status == .done)
        #expect(vm.progress == 1.0)

        // Start a fresh operation before the 1.5s auto-dismiss fires; it must stay inProgress past 1.7s
        try await Task.sleep(for: .milliseconds(250))
        vm.next(.start, 0.0, 0.3)
        try await Task.sleep(for: .milliseconds(1600))
        #expect(vm.inProgress)
        #expect(vm.status == .start)
    }
}
