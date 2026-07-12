import Combine
import Foundation

/// Owns the single prompt-once flag for MeterBar's first-launch experience.
/// Launch-at-login remains opt-in and is only registered after an explicit tap.
final class FirstRunOnboardingStore: ObservableObject {
    static let shared = FirstRunOnboardingStore()

    @Published private(set) var hasCompletedFirstRun: Bool

    private let userDefaults: UserDefaults
    private let launchAtLogin: LaunchAtLoginStore

    init(
        userDefaults: UserDefaults = .standard,
        launchAtLogin: LaunchAtLoginStore = .shared
    ) {
        self.userDefaults = userDefaults
        self.launchAtLogin = launchAtLogin
        hasCompletedFirstRun = userDefaults.bool(forKey: StorageKeys.hasCompletedFirstRun)
    }

    var shouldPresent: Bool { !hasCompletedFirstRun }

    func chooseLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            launchAtLogin.setEnabled(true)
        }
        complete()
    }

    /// Clicking away is also a dismissal choice; onboarding must never nag on
    /// a later launch after the user has seen and dismissed it.
    func dismiss() {
        complete()
    }

    private func complete() {
        guard !hasCompletedFirstRun else { return }
        hasCompletedFirstRun = true
        userDefaults.set(true, forKey: StorageKeys.hasCompletedFirstRun)
    }
}
