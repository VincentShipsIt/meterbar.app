import Foundation
import Combine

class AuthenticationManager: ObservableObject {
    static let shared = AuthenticationManager()

    @Published var claudeAdminKey: String?
    @Published var openaiAdminKey: String?
    // Note: Cursor doesn't need authentication since it has no API

    private let keychain = KeychainManager.shared

    private init() {
        loadCredentials()
    }

    private func loadCredentials() {
        claudeAdminKey = keychain.get(key: "claude_admin_key")
        openaiAdminKey = keychain.get(key: "openai_admin_key")
    }

    func setClaudeAdminKey(_ key: String) -> Bool {
        let success = keychain.save(key: "claude_admin_key", value: key)
        if success {
            claudeAdminKey = key
        }
        return success
    }

    func setOpenAIAdminKey(_ key: String) -> Bool {
        let success = keychain.save(key: "openai_admin_key", value: key)
        if success {
            openaiAdminKey = key
        }
        return success
    }

    func removeClaudeAdminKey() {
        _ = keychain.delete(key: "claude_admin_key")
        claudeAdminKey = nil
    }

    func removeOpenAIAdminKey() {
        _ = keychain.delete(key: "openai_admin_key")
        openaiAdminKey = nil
    }

    var isClaudeAuthenticated: Bool {
        claudeAdminKey != nil
    }

    var isOpenAIAuthenticated: Bool {
        openaiAdminKey != nil
    }
}
