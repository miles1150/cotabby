import Foundation

/// File overview:
/// Decides which DeepSeek API key Explain & Translate uses. Pure: the caller reads the three
/// possible sources (process environment, the Explain keychain item, the autocomplete endpoint's
/// keychain item) and this type only chooses, so the priority rule is testable without touching
/// the real environment or Keychain.
///
/// Priority, highest first:
/// 1. `$DEEPSEEK_API_KEY` — the user's own setup. Only visible when Cotabby Dev is launched from a
///    shell that exported it (or after `launchctl setenv`); apps opened from Finder do not see
///    shell variables, which is why it cannot be the only source.
/// 2. The key saved in Settings → Explain & Translate (its own Keychain item).
/// 3. The autocomplete endpoint's key — reused only when that endpoint is DeepSeek *and* Explain
///    itself talks to DeepSeek, so a key is never sent to a server it was not issued for.
nonisolated enum ExplainAPIKeyResolver {
    static let environmentVariableName = "DEEPSEEK_API_KEY"

    /// Where the chosen key came from, shown in Settings so the user knows which one is active.
    enum Source: Equatable, Sendable {
        case environment
        case explainKeychain
        case endpointKeychain

        var label: String {
            switch self {
            case .environment: return "the DEEPSEEK_API_KEY environment variable"
            case .explainKeychain: return "the key saved on this page"
            case .endpointKeychain: return "the Engine & Model endpoint key (DeepSeek)"
            }
        }
    }

    struct Resolution: Equatable, Sendable {
        let apiKey: String
        let source: Source
    }

    static func resolve(
        environment: [String: String],
        explainKey: String?,
        endpointKey: String?,
        endpointBaseURL: String?,
        explainBaseURL: String = "https://api.deepseek.com"
    ) -> Resolution? {
        if let key = nonEmpty(environment[environmentVariableName]) {
            return Resolution(apiKey: key, source: .environment)
        }
        if let key = nonEmpty(explainKey) {
            return Resolution(apiKey: key, source: .explainKeychain)
        }
        if let key = nonEmpty(endpointKey), isDeepSeekHost(endpointBaseURL), isDeepSeekHost(explainBaseURL) {
            return Resolution(apiKey: key, source: .endpointKeychain)
        }
        return nil
    }

    /// True only for `deepseek.com` and its subdomains. Parsing the host (instead of a substring
    /// search) stops a look-alike such as `deepseek.com.evil.example` from receiving the key.
    static func isDeepSeekHost(_ baseURL: String?) -> Bool {
        guard let baseURL,
              let host = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?
                .lowercased() else {
            return false
        }
        return host == "deepseek.com" || host.hasSuffix(".deepseek.com")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
