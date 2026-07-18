import Foundation
import MeterBarShared

/// Account metadata required to plan quota notifications without reading stores.
struct AccountNotificationIdentity: Equatable, Sendable {
    let id: UUID
    let name: String
    let isEnabled: Bool
}

/// One account-aware provider snapshot for the pure notification planner.
struct AccountNotificationPlanInput {
    let service: ServiceType
    let providerEnabled: Bool
    let accounts: [AccountNotificationIdentity]
    let accountMetrics: [UUID: UsageMetrics]
    let fallbackMetrics: UsageMetrics?
}

/// Fired notifications and the dedup state to thread into the next planning pass.
struct AccountNotificationPlan: Equatable, Sendable {
    let notifications: [FiredNotification]
    let notifiedKeys: Set<String>
}

/// Pure account/fallback orchestration shared by Claude Code and Codex.
///
/// Account metrics take precedence whenever at least one enabled account has
/// data. Provider fallback is used only when every enabled account is
/// unavailable. Switching between those namespaces primes the new namespace
/// without delivering, so the same quota state does not produce a duplicate
/// banner merely because account data appeared or disappeared.
struct AccountNotificationPlanner {
    private typealias AvailableAccount = (
        identity: AccountNotificationIdentity,
        metrics: UsageMetrics
    )

    private let decider: NotificationDecider

    init(
        preferences: NotificationPreferences,
        stalenessThreshold: TimeInterval = NotificationDecider.defaultStalenessThreshold
    ) {
        decider = NotificationDecider(
            preferences: preferences,
            stalenessThreshold: stalenessThreshold
        )
    }

    init(decider: NotificationDecider) {
        self.decider = decider
    }

    func plan(
        inputs: [AccountNotificationPlanInput],
        alreadyNotified: Set<String>,
        now: Date = Date()
    ) -> AccountNotificationPlan {
        var keys = alreadyNotified
        var notifications: [FiredNotification] = []

        for input in inputs {
            plan(
                input: input,
                keys: &keys,
                notifications: &notifications,
                now: now
            )
        }

        return AccountNotificationPlan(
            notifications: notifications,
            notifiedKeys: keys
        )
    }

    private func plan(
        input: AccountNotificationPlanInput,
        keys: inout Set<String>,
        notifications: inout [FiredNotification],
        now: Date
    ) {
        let enabledAccounts = input.accounts.filter(\.isEnabled)
        guard input.providerEnabled, !enabledAccounts.isEmpty else {
            clearProviderState(service: input.service, keys: &keys)
            return
        }

        for account in input.accounts where !account.isEnabled {
            keys.subtract(
                NotificationDecider.notificationKeys(
                    service: input.service,
                    accountKey: account.id.uuidString
                )
            )
        }

        let availableAccounts = enabledAccounts.compactMap { account -> AvailableAccount? in
            guard let metrics = input.accountMetrics[account.id] else { return nil }
            return (account, metrics)
        }

        guard !availableAccounts.isEmpty else {
            let changedNamespace = clearAccountState(service: input.service, keys: &keys)
            guard let fallbackMetrics = input.fallbackMetrics else {
                clearFallbackState(service: input.service, keys: &keys)
                return
            }

            let evaluation = decider.evaluate(
                metrics: fallbackMetrics,
                providerEnabled: !changedNamespace,
                alreadyNotified: keys,
                now: now
            )
            keys = evaluation.notifiedKeys
            notifications.append(contentsOf: evaluation.notifications)
            return
        }

        let changedNamespace = clearFallbackState(service: input.service, keys: &keys)
        for available in availableAccounts {
            let evaluation = decider.evaluate(
                metrics: available.metrics,
                providerEnabled: !changedNamespace,
                alreadyNotified: keys,
                accountKey: available.identity.id.uuidString,
                serviceDisplayName: "\(available.identity.name) (\(input.service.displayName))",
                now: now
            )
            keys = evaluation.notifiedKeys
            notifications.append(contentsOf: evaluation.notifications)
        }
    }

    @discardableResult
    private func clearFallbackState(
        service: ServiceType,
        keys: inout Set<String>
    ) -> Bool {
        let fallbackKeys = NotificationDecider.notificationKeys(service: service)
        let removedState = !keys.isDisjoint(with: fallbackKeys)
        keys.subtract(fallbackKeys)
        return removedState
    }

    @discardableResult
    private func clearAccountState(
        service: ServiceType,
        keys: inout Set<String>
    ) -> Bool {
        let fallbackKeys = NotificationDecider.notificationKeys(service: service)
        let servicePrefix = "\(service.rawValue)-"
        let accountKeys = keys.filter {
            $0.hasPrefix(servicePrefix) && !fallbackKeys.contains($0)
        }
        keys.subtract(accountKeys)
        return !accountKeys.isEmpty
    }

    private func clearProviderState(
        service: ServiceType,
        keys: inout Set<String>
    ) {
        clearFallbackState(service: service, keys: &keys)
        clearAccountState(service: service, keys: &keys)
    }
}
