import MeterBarShared
import XCTest
@testable import MeterBar

final class AccountNotificationPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let claudeAccountID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 10))
    private let secondClaudeAccountID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 11))
    private let codexAccountID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 12))

    private var planner: AccountNotificationPlanner {
        AccountNotificationPlanner(preferences: .default)
    }

    private func account(
        id: UUID,
        name: String,
        isEnabled: Bool = true
    ) -> AccountNotificationIdentity {
        AccountNotificationIdentity(id: id, name: name, isEnabled: isEnabled)
    }

    private func metrics(
        service: ServiceType,
        used: Double,
        weeklyUsed: Double? = nil,
        lastUpdated: Date? = nil
    ) -> UsageMetrics {
        UsageMetrics(
            service: service,
            sessionLimit: UsageLimit(used: used, total: 100, resetTime: nil),
            weeklyLimit: weeklyUsed.map { UsageLimit(used: $0, total: 100, resetTime: nil) },
            lastUpdated: lastUpdated ?? now
        )
    }

    private func input(
        service: ServiceType = .claudeCode,
        providerEnabled: Bool = true,
        accounts: [AccountNotificationIdentity],
        accountMetrics: [UUID: UsageMetrics] = [:],
        fallbackMetrics: UsageMetrics? = nil
    ) -> AccountNotificationPlanInput {
        AccountNotificationPlanInput(
            service: service,
            providerEnabled: providerEnabled,
            accounts: accounts,
            accountMetrics: accountMetrics,
            fallbackMetrics: fallbackMetrics
        )
    }

    func testPlansPerAccountKeysAndDisplayNames() {
        let result = planner.plan(
            inputs: [
                input(
                    accounts: [
                        account(id: claudeAccountID, name: "Work"),
                        account(id: secondClaudeAccountID, name: "Personal")
                    ],
                    accountMetrics: [
                        claudeAccountID: metrics(service: .claudeCode, used: 100),
                        secondClaudeAccountID: metrics(service: .claudeCode, used: 100)
                    ]
                )
            ],
            alreadyNotified: [],
            now: now
        )

        XCTAssertEqual(result.notifications.count, 2)
        XCTAssertEqual(Set(result.notifications.map(\.key)), [
            "Claude Code-\(claudeAccountID.uuidString)-session-critical",
            "Claude Code-\(secondClaudeAccountID.uuidString)-session-critical"
        ])
        XCTAssertEqual(Set(result.notifications.map(\.serviceDisplayName)), [
            "Work (Claude Code)",
            "Personal (Claude Code)"
        ])
    }

    func testUsesProviderFallbackWhenEveryEnabledAccountIsUnavailable() {
        let result = planner.plan(
            inputs: [
                input(
                    accounts: [
                        account(id: claudeAccountID, name: "Work"),
                        account(id: secondClaudeAccountID, name: "Personal")
                    ],
                    fallbackMetrics: metrics(service: .claudeCode, used: 100)
                )
            ],
            alreadyNotified: [],
            now: now
        )

        XCTAssertEqual(result.notifications.map(\.key), ["Claude Code-session-critical"])
        XCTAssertTrue(result.notifiedKeys.contains("Claude Code-session-critical"))
    }

    func testFallbackToAccountTransitionPrimesNewNamespaceWithoutDuplicate() {
        let fallbackResult = planner.plan(
            inputs: [
                input(
                    accounts: [account(id: claudeAccountID, name: "Work")],
                    fallbackMetrics: metrics(service: .claudeCode, used: 100)
                )
            ],
            alreadyNotified: [],
            now: now
        )
        XCTAssertEqual(fallbackResult.notifications.map(\.key), ["Claude Code-session-critical"])

        let accountResult = planner.plan(
            inputs: [
                input(
                    accounts: [account(id: claudeAccountID, name: "Work")],
                    accountMetrics: [claudeAccountID: metrics(service: .claudeCode, used: 100)]
                )
            ],
            alreadyNotified: fallbackResult.notifiedKeys,
            now: now
        )

        XCTAssertTrue(accountResult.notifications.isEmpty)
        XCTAssertFalse(accountResult.notifiedKeys.contains("Claude Code-session-critical"))
        XCTAssertTrue(
            accountResult.notifiedKeys.contains(
                "Claude Code-\(claudeAccountID.uuidString)-session-critical"
            )
        )
    }

    func testFallbackToAccountTransitionStillDeliversEscalationsAndNewQuotaKinds() {
        let fallbackResult = planner.plan(
            inputs: [
                input(
                    accounts: [account(id: claudeAccountID, name: "Work")],
                    fallbackMetrics: metrics(service: .claudeCode, used: 90)
                )
            ],
            alreadyNotified: [],
            now: now
        )
        XCTAssertEqual(fallbackResult.notifications.map(\.level), [.warning])

        let accountResult = planner.plan(
            inputs: [
                input(
                    accounts: [account(id: claudeAccountID, name: "Work")],
                    accountMetrics: [
                        claudeAccountID: metrics(
                            service: .claudeCode,
                            used: 100,
                            weeklyUsed: 100
                        )
                    ]
                )
            ],
            alreadyNotified: fallbackResult.notifiedKeys,
            now: now
        )

        XCTAssertEqual(accountResult.notifications.map(\.level), [.critical, .critical])
        XCTAssertEqual(
            accountResult.notifications.map(\.quotaDisplayName),
            ["Session", "Weekly"]
        )
    }

    func testTemporaryFullDataGapPreservesAccountDedupState() {
        let available = input(
            accounts: [account(id: claudeAccountID, name: "Work")],
            accountMetrics: [claudeAccountID: metrics(service: .claudeCode, used: 100)]
        )
        let first = planner.plan(inputs: [available], alreadyNotified: [], now: now)
        XCTAssertEqual(first.notifications.count, 1)

        let unavailable = planner.plan(
            inputs: [input(accounts: [account(id: claudeAccountID, name: "Work")])],
            alreadyNotified: first.notifiedKeys,
            now: now
        )
        let recovered = planner.plan(
            inputs: [available],
            alreadyNotified: unavailable.notifiedKeys,
            now: now
        )

        XCTAssertEqual(unavailable.notifiedKeys, first.notifiedKeys)
        XCTAssertTrue(recovered.notifications.isEmpty)
    }

    func testAccountToFallbackTransitionPrimesNewNamespaceWithoutDuplicate() {
        let accountResult = planner.plan(
            inputs: [
                input(
                    accounts: [account(id: claudeAccountID, name: "Work")],
                    accountMetrics: [claudeAccountID: metrics(service: .claudeCode, used: 100)]
                )
            ],
            alreadyNotified: [],
            now: now
        )
        XCTAssertEqual(accountResult.notifications.count, 1)

        let fallbackResult = planner.plan(
            inputs: [
                input(
                    accounts: [account(id: claudeAccountID, name: "Work")],
                    fallbackMetrics: metrics(service: .claudeCode, used: 100)
                )
            ],
            alreadyNotified: accountResult.notifiedKeys,
            now: now
        )

        XCTAssertTrue(fallbackResult.notifications.isEmpty)
        XCTAssertEqual(
            fallbackResult.notifiedKeys,
            Set([
                "Claude Code-\(claudeAccountID.uuidString)-session-warn",
                "Claude Code-\(claudeAccountID.uuidString)-session-critical",
                "Claude Code-session-warn",
                "Claude Code-session-critical"
            ])
        )
    }

    func testCachedHealthyFallbackDoesNotLoseExhaustedAccountDedupState() {
        let accounts = [
            account(id: claudeAccountID, name: "Healthy"),
            account(id: secondClaudeAccountID, name: "Exhausted")
        ]
        let available = input(
            accounts: accounts,
            accountMetrics: [
                claudeAccountID: metrics(service: .claudeCode, used: 0),
                secondClaudeAccountID: metrics(service: .claudeCode, used: 100)
            ]
        )
        let first = planner.plan(inputs: [available], alreadyNotified: [], now: now)
        XCTAssertEqual(first.notifications.map(\.key), [
            "Claude Code-\(secondClaudeAccountID.uuidString)-session-critical"
        ])

        let unavailable = planner.plan(
            inputs: [
                input(
                    accounts: accounts,
                    fallbackMetrics: metrics(service: .claudeCode, used: 0)
                )
            ],
            alreadyNotified: first.notifiedKeys,
            now: now
        )
        let recovered = planner.plan(
            inputs: [available],
            alreadyNotified: unavailable.notifiedKeys,
            now: now
        )

        XCTAssertTrue(unavailable.notifications.isEmpty)
        XCTAssertTrue(recovered.notifications.isEmpty)
        XCTAssertTrue(
            recovered.notifiedKeys.contains(
                "Claude Code-\(secondClaudeAccountID.uuidString)-session-critical"
            )
        )
    }

    func testCachedExhaustedFallbackDoesNotMaskAnotherAccountsFirstCrossing() {
        let accounts = [
            account(id: claudeAccountID, name: "Exhausted"),
            account(id: secondClaudeAccountID, name: "Healthy")
        ]
        let first = planner.plan(
            inputs: [
                input(
                    accounts: accounts,
                    accountMetrics: [
                        claudeAccountID: metrics(service: .claudeCode, used: 100),
                        secondClaudeAccountID: metrics(service: .claudeCode, used: 0)
                    ]
                )
            ],
            alreadyNotified: [],
            now: now
        )
        XCTAssertEqual(first.notifications.map(\.key), [
            "Claude Code-\(claudeAccountID.uuidString)-session-critical"
        ])

        let unavailable = planner.plan(
            inputs: [
                input(
                    accounts: accounts,
                    fallbackMetrics: metrics(service: .claudeCode, used: 100)
                )
            ],
            alreadyNotified: first.notifiedKeys,
            now: now
        )
        let recovered = planner.plan(
            inputs: [
                input(
                    accounts: accounts,
                    accountMetrics: [
                        claudeAccountID: metrics(service: .claudeCode, used: 100),
                        secondClaudeAccountID: metrics(service: .claudeCode, used: 100)
                    ]
                )
            ],
            alreadyNotified: unavailable.notifiedKeys,
            now: now
        )

        XCTAssertTrue(unavailable.notifications.isEmpty)
        XCTAssertEqual(recovered.notifications.map(\.key), [
            "Claude Code-\(secondClaudeAccountID.uuidString)-session-critical"
        ])
    }

    func testDisabledAccountCleanupRearmsLaterCrossing() {
        let enabledInput = input(
            accounts: [
                account(id: claudeAccountID, name: "Work"),
                account(id: secondClaudeAccountID, name: "Personal")
            ],
            accountMetrics: [
                claudeAccountID: metrics(service: .claudeCode, used: 100),
                secondClaudeAccountID: metrics(service: .claudeCode, used: 100)
            ]
        )
        let first = planner.plan(inputs: [enabledInput], alreadyNotified: [], now: now)
        XCTAssertEqual(first.notifications.count, 2)

        let disabled = planner.plan(
            inputs: [
                input(
                    accounts: [
                        account(id: claudeAccountID, name: "Work", isEnabled: false),
                        account(id: secondClaudeAccountID, name: "Personal")
                    ],
                    accountMetrics: [
                        claudeAccountID: metrics(service: .claudeCode, used: 100),
                        secondClaudeAccountID: metrics(service: .claudeCode, used: 100)
                    ]
                )
            ],
            alreadyNotified: first.notifiedKeys,
            now: now
        )
        XCTAssertTrue(disabled.notifications.isEmpty)
        XCTAssertFalse(disabled.notifiedKeys.contains {
            $0.hasPrefix("Claude Code-\(claudeAccountID.uuidString)")
        })
        XCTAssertTrue(disabled.notifiedKeys.contains {
            $0.hasPrefix("Claude Code-\(secondClaudeAccountID.uuidString)")
        })

        let reenabled = planner.plan(
            inputs: [enabledInput],
            alreadyNotified: disabled.notifiedKeys,
            now: now
        )
        XCTAssertEqual(reenabled.notifications.count, 1)
        XCTAssertTrue(
            reenabled.notifications[0].key.hasPrefix(
                "Claude Code-\(claudeAccountID.uuidString)"
            )
        )
    }

    func testDisabledProviderCleanupRearmsLaterCrossing() {
        let enabledInput = input(
            service: .codexCli,
            accounts: [account(id: codexAccountID, name: "Work")],
            accountMetrics: [codexAccountID: metrics(service: .codexCli, used: 100)]
        )
        let first = planner.plan(inputs: [enabledInput], alreadyNotified: [], now: now)

        let disabled = planner.plan(
            inputs: [
                input(
                    service: .codexCli,
                    providerEnabled: false,
                    accounts: [account(id: codexAccountID, name: "Work")],
                    accountMetrics: [codexAccountID: metrics(service: .codexCli, used: 100)]
                )
            ],
            alreadyNotified: first.notifiedKeys,
            now: now
        )
        XCTAssertTrue(disabled.notifications.isEmpty)
        XCTAssertTrue(disabled.notifiedKeys.isEmpty)

        let reenabled = planner.plan(
            inputs: [enabledInput],
            alreadyNotified: disabled.notifiedKeys,
            now: now
        )
        XCTAssertEqual(reenabled.notifications.count, 1)
    }

    func testThreadsKeysSequentiallyAcrossClaudeThenCodex() {
        let inputs = [
            input(
                accounts: [account(id: claudeAccountID, name: "Claude Work")],
                accountMetrics: [claudeAccountID: metrics(service: .claudeCode, used: 100)]
            ),
            input(
                service: .codexCli,
                accounts: [account(id: codexAccountID, name: "Codex Work")],
                accountMetrics: [codexAccountID: metrics(service: .codexCli, used: 100)]
            )
        ]

        let first = planner.plan(inputs: inputs, alreadyNotified: [], now: now)
        XCTAssertEqual(first.notifications.count, 2)
        XCTAssertTrue(first.notifiedKeys.contains {
            $0.hasPrefix("Claude Code-\(claudeAccountID.uuidString)")
        })
        XCTAssertTrue(first.notifiedKeys.contains {
            $0.hasPrefix("Codex CLI-\(codexAccountID.uuidString)")
        })

        let repeated = planner.plan(inputs: inputs, alreadyNotified: first.notifiedKeys, now: now)
        XCTAssertTrue(repeated.notifications.isEmpty)
        XCTAssertEqual(repeated.notifiedKeys, first.notifiedKeys)
    }

    func testStaleAndUnavailableAccountsDoNotBlockFreshAccountPlanning() {
        let unavailableKey = "Claude Code-\(secondClaudeAccountID.uuidString)-session-warn"
        let result = planner.plan(
            inputs: [
                input(
                    accounts: [
                        account(id: claudeAccountID, name: "Stale"),
                        account(id: secondClaudeAccountID, name: "Unavailable"),
                        account(id: codexAccountID, name: "Fresh")
                    ],
                    accountMetrics: [
                        claudeAccountID: metrics(
                            service: .claudeCode,
                            used: 100,
                            lastUpdated: now.addingTimeInterval(
                                -NotificationDecider.defaultStalenessThreshold - 1
                            )
                        ),
                        codexAccountID: metrics(service: .claudeCode, used: 100)
                    ],
                    fallbackMetrics: metrics(service: .claudeCode, used: 100)
                )
            ],
            alreadyNotified: [unavailableKey],
            now: now
        )

        XCTAssertEqual(
            result.notifications.map(\.key),
            ["Claude Code-\(codexAccountID.uuidString)-session-critical"]
        )
        XCTAssertTrue(result.notifiedKeys.contains(unavailableKey))
        XCTAssertTrue(
            result.notifiedKeys.contains(
                "Claude Code-\(claudeAccountID.uuidString)-session-critical"
            )
        )
        XCTAssertFalse(result.notifiedKeys.contains("Claude Code-session-critical"))
    }
}
