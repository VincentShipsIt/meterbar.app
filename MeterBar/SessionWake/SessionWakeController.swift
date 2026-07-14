import Combine
import Foundation

/// The lifecycle abstraction the controller drives. `WakeCoordinator` is the
/// production conformer; tests substitute a fake to assert start/stop without
/// spawning a subprocess.
///
/// The watcher is armed with a provider `runtime` (Claude or Codex), so the
/// controller stays provider-agnostic. `WakeCoordinator` still offers a concrete
/// `start(account:)` convenience for the legacy Claude path, but it is not part
/// of this protocol.
nonisolated protocol WakeWatching: Sendable {
    func start(runtime: WakeProviderRuntime) async
    func stop() async
    func waitUntilFinished() async
}

extension WakeCoordinator: WakeWatching {}

/// Builds a watcher from a runner, bounds, and a state-change sink.
typealias WakeWatcherFactory = @Sendable (
    WakeExecuting,
    WakeBounds,
    @escaping @Sendable (WakeWatcherState) -> Void
) -> WakeWatching

/// Bridges the single ON/OFF toggle to a live, continuous watcher.
///
/// While `isOn`, it runs a `WakeCoordinator` pass (scan → wait for quota →
/// resume), and when a pass settles it re-scans after `rescanInterval` so the
/// watcher keeps watching for the *next* time a session hits its limit — rather
/// than stopping after one resume. Turning the toggle off, or removing the wake
/// account, tears the watcher down deterministically. v1 lifetime is
/// app-running-only: the watcher lives with the process and re-arms on launch
/// if the toggle was left on.
@MainActor
final class SessionWakeController: ObservableObject {
    static let shared = SessionWakeController()

    private let store: SessionWakeSettingsStore
    private let status: SessionWakeStatus
    private let accounts: ClaudeCodeAccountStore
    private let codexAccounts: CodexAccountStore
    private let rescanInterval: TimeInterval
    private let makeWatcher: WakeWatcherFactory

    private var cancellables = Set<AnyCancellable>()
    private var watchTask: Task<Void, Never>?
    private var started = false

    /// The store defaults are `nil` sentinels resolved in the body because the
    /// MainActor-isolated singletons cannot appear in (nonisolated) default
    /// argument position.
    init(
        store: SessionWakeSettingsStore? = nil,
        status: SessionWakeStatus? = nil,
        accounts: ClaudeCodeAccountStore? = nil,
        codexAccounts: CodexAccountStore? = nil,
        rescanInterval: TimeInterval = 300,
        makeWatcher: @escaping WakeWatcherFactory = { runner, bounds, onState in
            WakeCoordinator(runner: runner, bounds: bounds, onState: onState)
        }
    ) {
        self.store = store ?? .shared
        self.status = status ?? .shared
        self.accounts = accounts ?? .shared
        self.codexAccounts = codexAccounts ?? .shared
        self.rescanInterval = rescanInterval
        self.makeWatcher = makeWatcher
    }

    /// Begin observing the toggle and re-arm if it was left on. Idempotent;
    /// call once from the app delegate at launch.
    func activate() {
        guard !started else { return }
        started = true

        // Any change that affects whether/where we should watch triggers a
        // reconcile: the toggle, the active provider, either provider's selected
        // account, and the permission posture. A removed account disarms via the
        // store's account reconcilers below.
        let triggers: [AnyPublisher<Void, Never>] = [
            store.$isOn.map { _ in () }.eraseToAnyPublisher(),
            store.$wakeProvider.map { _ in () }.eraseToAnyPublisher(),
            store.$wakeAccountID.map { _ in () }.eraseToAnyPublisher(),
            store.$wakeCodexAccountID.map { _ in () }.eraseToAnyPublisher(),
            store.$permissionMode.map { _ in () }.eraseToAnyPublisher(),
            store.$bypassAcknowledged.map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(triggers)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.reconcile() }
            .store(in: &cancellables)

        Publishers.Merge(
            accounts.$customAccounts.map { _ in () },
            accounts.$defaultAccountIsEnabled.map { _ in () }
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.store.reconcileAccounts(available: self.accounts.enabledAccounts.map(\.id))
                self.reconcile()
            }
            .store(in: &cancellables)

        Publishers.Merge(
            codexAccounts.$customAccounts.map { _ in () },
            codexAccounts.$defaultAccountIsEnabled.map { _ in () }
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.store.reconcileCodexAccounts(available: self.codexAccounts.enabledAccounts.map(\.id))
                self.reconcile()
            }
            .store(in: &cancellables)

        reconcile()
    }

    /// Whether the controller currently has a live watch task (test hook).
    var isWatching: Bool { watchTask != nil }

    // MARK: - Reconciliation

    private func reconcile() {
        if store.isOn, let runtime = resolvedRuntime() {
            startWatching(runtime: runtime)
        } else {
            stopWatching()
        }
        // Keep the app-group target the bundled CLI reads in step with the
        // active provider's selection, independent of the app watcher toggle —
        // `meterbar wake` may run from cron even when the watcher is off.
        store.syncSharedWakeTarget(directory: activeAccountDirectory())
    }

    /// Build the runtime for the active provider bound to its selected, enabled
    /// account, or `nil` when no such account exists. Runner construction mirrors
    /// `SessionWakeCLI.makeRuntime` so the app watcher and the CLI behave the
    /// same. `permissionMode`/`bypassAcknowledged`/`prompt` are captured by value
    /// (they are `Sendable`) to keep the `@Sendable` runner factory clean.
    private func resolvedRuntime() -> WakeProviderRuntime? {
        let mode = store.permissionMode
        let bypass = store.bypassAcknowledged
        let prompt = store.prompt

        switch store.wakeProvider {
        case .claude:
            guard let id = store.wakeAccountID,
                  let account = accounts.enabledAccounts.first(where: { $0.id == id }) else { return nil }
            return ClaudeWakeRuntime(account: account) { runnerAccount in
                WakeProcessRunner(
                    account: runnerAccount,
                    permissionMode: mode,
                    bypassAcknowledged: bypass,
                    prompt: prompt
                )
            }
        case .codex:
            guard let id = store.wakeCodexAccountID,
                  let account = codexAccounts.enabledAccounts.first(where: { $0.id == id }) else { return nil }
            return CodexWakeRuntime(account: account) { runnerAccount in
                CodexWakeProcessRunner(
                    account: runnerAccount,
                    permissionMode: mode,
                    bypassAcknowledged: bypass,
                    prompt: prompt
                )
            }
        }
    }

    /// The active provider's selected-account directory (Claude config dir or
    /// Codex CODEX_HOME), or `nil` when nothing enabled is selected.
    private func activeAccountDirectory() -> String? {
        switch store.wakeProvider {
        case .claude:
            guard let id = store.wakeAccountID else { return nil }
            return accounts.enabledAccounts.first(where: { $0.id == id })?.configDirectory
        case .codex:
            guard let id = store.wakeCodexAccountID else { return nil }
            return codexAccounts.enabledAccounts.first(where: { $0.id == id })?.homeDirectory
        }
    }

    private func startWatching(runtime: WakeProviderRuntime) {
        guard watchTask == nil else { return }
        let bounds = store.bounds
        // The factory seam still takes a runner (used by the concrete coordinator
        // init); the runtime supplies the real per-launch runner via makeRunner.
        let runner = runtime.makeRunner()
        let interval = rescanInterval
        let make = makeWatcher

        watchTask = Task {
            while !Task.isCancelled {
                let watcher = make(runner, bounds) { state in
                    Task { @MainActor in SessionWakeStatus.shared.update(state: state) }
                }
                await watcher.start(runtime: runtime)
                // A cancel (toggle off) reliably stops the coordinator via the
                // cancellation handler, regardless of where the pass is.
                await withTaskCancellationHandler {
                    await watcher.waitUntilFinished()
                } onCancel: {
                    Task { await watcher.stop() }
                }
                if Task.isCancelled { break }
                // Keep watching for the next limit hit.
                try? await Task.sleep(nanoseconds: UInt64(max(1, interval) * 1_000_000_000))
            }
        }
    }

    private func stopWatching() {
        guard watchTask != nil else { return }
        watchTask?.cancel()
        watchTask = nil
        status.update(state: .off)
    }
}
