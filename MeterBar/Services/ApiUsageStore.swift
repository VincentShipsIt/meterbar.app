import Combine
import Foundation

/// Holds the fetched organization API usage per provider and the user-selected
/// reporting window. Refetches when the window changes or on manual refresh.
/// Only providers with an admin key entered are fetched.
@MainActor
final class ApiUsageStore: ObservableObject {
    typealias UsageFetcher = (ApiProvider, String, ApiUsageWindow) async throws -> ApiUsage

    static let shared = ApiUsageStore()

    @Published private(set) var usage: [ApiProvider: ApiUsage] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var window: ApiUsageWindow = .last7Days

    private let authenticatedProvidersSource: () -> [ApiProvider]
    private let adminKeySource: (ApiProvider) -> String?
    private let fetchUsage: UsageFetcher
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var activeWindow: ApiUsageWindow?

    init(
        authenticatedProviders: (() -> [ApiProvider])? = nil,
        adminKey: ((ApiProvider) -> String?)? = nil,
        fetchUsage: UsageFetcher? = nil
    ) {
        let authManager = AuthenticationManager.shared
        authenticatedProvidersSource = authenticatedProviders ?? {
            ApiProvider.allCases.filter { authManager.isAuthenticated($0) }
        }
        adminKeySource = adminKey ?? { authManager.adminKey(for: $0) }
        self.fetchUsage = fetchUsage ?? { provider, adminKey, window in
            try await ApiUsageService.fetch(provider: provider, adminKey: adminKey, window: window)
        }
    }

    /// Providers the user has entered an admin key for (drives which cards show).
    var authenticatedProviders: [ApiProvider] {
        authenticatedProvidersSource()
    }

    var hasAnyAuthenticated: Bool {
        !authenticatedProviders.isEmpty
    }

    func setWindow(_ newWindow: ApiUsageWindow) {
        guard newWindow != window else { return }
        window = newWindow
        startRefresh(for: newWindow)
    }

    func refresh() async {
        if activeWindow == window, let refreshTask {
            await refreshTask.value
            return
        }
        let task = startRefresh(for: window)
        await task.value
    }

    /// Awaits work already scheduled by `setWindow`. Kept internal so focused
    /// store tests can observe the same path the SwiftUI picker uses.
    func waitForCurrentRefresh() async {
        await refreshTask?.value
    }

    @discardableResult
    private func startRefresh(for requestedWindow: ApiUsageWindow) -> Task<Void, Never> {
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        activeWindow = requestedWindow

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(for: requestedWindow, generation: generation)
        }
        refreshTask = task
        return task
    }

    private func performRefresh(for requestedWindow: ApiUsageWindow, generation: Int) async {
        guard generation == refreshGeneration else { return }

        let providers = authenticatedProviders
        guard !providers.isEmpty else {
            usage = [:]
            lastError = nil
            isLoading = false
            activeWindow = nil
            return
        }

        isLoading = true
        lastError = nil

        var results: [ApiProvider: ApiUsage] = [:]
        var refreshError: String?
        for provider in providers {
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            guard let key = adminKeySource(provider) else { continue }
            do {
                results[provider] = try await fetchUsage(provider, key, requestedWindow)
            } catch {
                guard !Task.isCancelled else { return }
                refreshError = ServiceSupport.safeErrorMessage(for: error)
                if let cached = usage[provider] {
                    results[provider] = cached
                }
            }
        }

        guard !Task.isCancelled, generation == refreshGeneration else { return }
        usage = results
        lastError = refreshError
        isLoading = false
        activeWindow = nil
    }
}
