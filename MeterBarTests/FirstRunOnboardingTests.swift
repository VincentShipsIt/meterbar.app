@testable import MeterBar
import XCTest

final class FirstRunOnboardingTests: XCTestCase {
    private final class FakeLaunchController: LaunchAtLoginControlling {
        var status: LaunchAtLoginStatus = .notRegistered
        private(set) var registerCallCount = 0

        func currentStatus() -> LaunchAtLoginStatus { status }
        func register() throws {
            registerCallCount += 1
            status = .enabled
        }
        func unregister() throws { status = .notRegistered }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "FirstRunOnboardingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testFreshInstallPresentsAndDismissPersistsOnce() {
        let store = FirstRunOnboardingStore(
            userDefaults: defaults,
            launchAtLogin: LaunchAtLoginStore(controller: FakeLaunchController())
        )
        XCTAssertTrue(store.shouldPresent)

        store.dismiss()

        XCTAssertFalse(store.shouldPresent)
        let reloaded = FirstRunOnboardingStore(
            userDefaults: defaults,
            launchAtLogin: LaunchAtLoginStore(controller: FakeLaunchController())
        )
        XCTAssertFalse(reloaded.shouldPresent)
    }

    func testEnableLaunchAtLoginRegistersAndCompletesOnboarding() {
        let controller = FakeLaunchController()
        let launchAtLogin = LaunchAtLoginStore(controller: controller)
        let store = FirstRunOnboardingStore(userDefaults: defaults, launchAtLogin: launchAtLogin)

        store.chooseLaunchAtLogin(true)

        XCTAssertEqual(controller.registerCallCount, 1)
        XCTAssertTrue(launchAtLogin.isEnabled)
        XCTAssertFalse(store.shouldPresent)
    }

    func testNotNowCompletesWithoutRegistering() {
        let controller = FakeLaunchController()
        let store = FirstRunOnboardingStore(
            userDefaults: defaults,
            launchAtLogin: LaunchAtLoginStore(controller: controller)
        )

        store.chooseLaunchAtLogin(false)

        XCTAssertEqual(controller.registerCallCount, 0)
        XCTAssertFalse(store.shouldPresent)
    }
}
