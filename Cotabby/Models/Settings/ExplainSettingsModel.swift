import Combine
import CoreGraphics
import Foundation

/// File overview:
/// The settings for Explain & Translate: on/off, the two shortcuts, the DeepSeek model and server,
/// the reading voice and speed, and the feature's own DeepSeek key.
///
/// Why a separate model instead of more fields on `SuggestionSettingsModel`: that model is the
/// autocomplete pipeline's settings surface (≈1,900 lines) and is changed often upstream. Keeping
/// this personal feature in its own small type means pulling upstream updates rarely conflicts,
/// and nothing in the autocomplete path can accidentally depend on these values.
///
/// Ownership: built once by `CotabbyAppEnvironment`, observed by the Settings pane (SwiftUI reads
/// the `@Published` values and re-renders on change) and read by `ExplainCoordinator` at the
/// moment a shortcut fires. Every setter writes through to `UserDefaults` immediately.

/// One recorded keyboard shortcut. `keyCode == ExplainShortcut.unboundKeyCode` means "no shortcut".
/// Main-actor isolated (the module default) like `ShortcutModifierMask`, which it contains.
struct ExplainShortcut: Equatable, Sendable {
    static let unboundKeyCode = CGKeyCode(UInt16.max)
    static let unbound = ExplainShortcut(keyCode: unboundKeyCode, modifiers: [], label: "None")

    let keyCode: CGKeyCode
    let modifiers: ShortcutModifierMask
    let label: String

    var isBound: Bool { keyCode != Self.unboundKeyCode }
}

@MainActor
final class ExplainSettingsModel: ObservableObject {
    // Virtual key codes from Carbon's `kVK_ANSI_*` table (layout-independent physical keys).
    static let defaultExplainShortcut = ExplainShortcut(keyCode: 14, modifiers: .option, label: "⌥E")
    static let defaultSpeakShortcut = ExplainShortcut(keyCode: 1, modifiers: .option, label: "⌥S")
    static let defaultModelName = "deepseek-flash"
    static let defaultBaseURL = "https://api.deepseek.com"
    /// `AVSpeechUtterance` rates run 0…1 with 0.5 as the system default; slightly slower is easier
    /// to follow for a learner.
    static let defaultSpeechRate = 0.45

    @Published private(set) var isEnabled: Bool
    @Published private(set) var explainShortcut: ExplainShortcut
    @Published private(set) var speakShortcut: ExplainShortcut
    @Published private(set) var modelName: String
    @Published private(set) var baseURL: String
    /// `nil` means "pick the best installed English voice automatically".
    @Published private(set) var voiceIdentifier: String?
    @Published private(set) var speechRate: Double
    /// Whether a key is saved in this feature's own Keychain item. The key itself is never
    /// published or kept in memory longer than a read.
    @Published private(set) var hasSavedAPIKey: Bool
    /// Last Keychain error, shown under the key field.
    @Published private(set) var credentialError: String?

    private let defaults: UserDefaults
    private let credentialStore: OpenAICompatibleCredentialStoring

    private enum Key {
        static let enabled = "cotabbyExplainEnabled"
        static let explainKeyCode = "cotabbyExplainKeyCode"
        static let explainModifiers = "cotabbyExplainKeyModifiers"
        static let explainLabel = "cotabbyExplainKeyLabel"
        static let speakKeyCode = "cotabbyExplainSpeakKeyCode"
        static let speakModifiers = "cotabbyExplainSpeakKeyModifiers"
        static let speakLabel = "cotabbyExplainSpeakKeyLabel"
        static let modelName = "cotabbyExplainModelName"
        static let baseURL = "cotabbyExplainBaseURL"
        static let voiceIdentifier = "cotabbyExplainVoiceIdentifier"
        static let speechRate = "cotabbyExplainSpeechRate"
    }

    init(defaults: UserDefaults = .standard, credentialStore: OpenAICompatibleCredentialStoring) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        explainShortcut = Self.loadShortcut(
            defaults, code: Key.explainKeyCode, modifiers: Key.explainModifiers, label: Key.explainLabel,
            fallback: Self.defaultExplainShortcut
        )
        speakShortcut = Self.loadShortcut(
            defaults, code: Key.speakKeyCode, modifiers: Key.speakModifiers, label: Key.speakLabel,
            fallback: Self.defaultSpeakShortcut
        )
        modelName = Self.nonEmpty(defaults.string(forKey: Key.modelName)) ?? Self.defaultModelName
        baseURL = Self.nonEmpty(defaults.string(forKey: Key.baseURL)) ?? Self.defaultBaseURL
        voiceIdentifier = Self.nonEmpty(defaults.string(forKey: Key.voiceIdentifier))
        let storedRate = defaults.object(forKey: Key.speechRate) as? Double
        speechRate = Self.clampRate(storedRate ?? Self.defaultSpeechRate)
        hasSavedAPIKey = (try? credentialStore.readAPIKey())?.isEmpty == false
    }

    // Matches `KeychainOpenAICompatibleCredentialStore`: an explicit nonisolated deinit avoids the
    // Xcode 26.0–26.3 isolated-deinit miscompile for main-actor classes held through protocols.
    nonisolated deinit {}

    // MARK: - Setters

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Key.enabled)
    }

    func setExplainShortcut(_ shortcut: ExplainShortcut) {
        guard shortcut != explainShortcut else { return }
        explainShortcut = shortcut
        Self.saveShortcut(shortcut, defaults, code: Key.explainKeyCode, modifiers: Key.explainModifiers, label: Key.explainLabel)
    }

    func setSpeakShortcut(_ shortcut: ExplainShortcut) {
        guard shortcut != speakShortcut else { return }
        speakShortcut = shortcut
        Self.saveShortcut(shortcut, defaults, code: Key.speakKeyCode, modifiers: Key.speakModifiers, label: Key.speakLabel)
    }

    func setModelName(_ name: String) {
        let resolved = Self.nonEmpty(name) ?? Self.defaultModelName
        guard resolved != modelName else { return }
        modelName = resolved
        defaults.set(resolved, forKey: Key.modelName)
    }

    func setBaseURL(_ url: String) {
        let resolved = Self.nonEmpty(url) ?? Self.defaultBaseURL
        guard resolved != baseURL else { return }
        baseURL = resolved
        defaults.set(resolved, forKey: Key.baseURL)
    }

    func setVoiceIdentifier(_ identifier: String?) {
        let resolved = Self.nonEmpty(identifier)
        guard resolved != voiceIdentifier else { return }
        voiceIdentifier = resolved
        if let resolved {
            defaults.set(resolved, forKey: Key.voiceIdentifier)
        } else {
            defaults.removeObject(forKey: Key.voiceIdentifier)
        }
    }

    func setSpeechRate(_ rate: Double) {
        let resolved = Self.clampRate(rate)
        guard resolved != speechRate else { return }
        speechRate = resolved
        defaults.set(resolved, forKey: Key.speechRate)
    }

    // MARK: - API key

    /// Saves (or, for an empty string, deletes) this feature's DeepSeek key in the Keychain.
    func saveAPIKey(_ apiKey: String) {
        do {
            try credentialStore.saveAPIKey(apiKey)
            credentialError = nil
        } catch {
            credentialError = error.localizedDescription
        }
        hasSavedAPIKey = (try? credentialStore.readAPIKey())?.isEmpty == false
    }

    /// Reads the saved key at request time. Never cached, so a key change applies immediately.
    func readSavedAPIKey() -> String? {
        try? credentialStore.readAPIKey()
    }

    // MARK: - Helpers

    private static func loadShortcut(
        _ defaults: UserDefaults,
        code: String,
        modifiers: String,
        label: String,
        fallback: ExplainShortcut
    ) -> ExplainShortcut {
        guard let storedCode = defaults.object(forKey: code) as? Int,
              let storedLabel = defaults.string(forKey: label) else {
            return fallback
        }
        let storedModifiers = (defaults.object(forKey: modifiers) as? Int).map { UInt32(truncatingIfNeeded: $0) } ?? 0
        return ExplainShortcut(
            keyCode: CGKeyCode(truncatingIfNeeded: storedCode),
            modifiers: ShortcutModifierMask(rawValue: storedModifiers),
            label: storedLabel
        )
    }

    private static func saveShortcut(
        _ shortcut: ExplainShortcut,
        _ defaults: UserDefaults,
        code: String,
        modifiers: String,
        label: String
    ) {
        defaults.set(Int(shortcut.keyCode), forKey: code)
        defaults.set(Int(shortcut.modifiers.rawValue), forKey: modifiers)
        defaults.set(shortcut.label, forKey: label)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Keeps speech in a range that is still understandable (0.2 is very slow, 0.65 is fast).
    private static func clampRate(_ rate: Double) -> Double {
        min(max(rate, 0.2), 0.65)
    }
}
