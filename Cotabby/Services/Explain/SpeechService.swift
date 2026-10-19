import AVFoundation
import Combine
import NaturalLanguage

/// File overview:
/// Reads text aloud with the voices built into macOS (`AVSpeechSynthesizer`). Free, offline, and
/// private: nothing leaves the Mac. The user picks a voice and speed in Settings; "Premium" and
/// "Enhanced" voices (downloadable in System Settings → Accessibility → Spoken Content) sound
/// much more natural than the defaults, so automatic selection prefers them.
///
/// Lifetime matters here: `AVSpeechSynthesizer` stops talking the moment it is deallocated, so
/// this service is created once by `CotabbyAppEnvironment` and lives as long as the app.
@MainActor
final class SpeechService: NSObject, ObservableObject, SpeechPerforming {
    /// One installed voice, flattened for the Settings picker.
    struct VoiceOption: Identifiable, Equatable {
        let id: String
        let name: String
        let language: String
        let qualityLabel: String

        var displayName: String {
            qualityLabel.isEmpty ? "\(name) (\(language))" : "\(name) (\(language), \(qualityLabel))"
        }
    }

    @Published private(set) var isSpeaking = false

    var isSpeakingPublisher: AnyPublisher<Bool, Never> {
        $isSpeaking.eraseToAnyPublisher()
    }

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    nonisolated deinit {}

    /// Speaks `text`, replacing anything already being read. Chinese text automatically uses a
    /// Chinese voice, because an English voice reads Chinese characters as silence or noise.
    func speak(_ text: String, preferredVoiceIdentifier: String?, rate: Double) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = Float(rate)
        utterance.voice = Self.voice(for: trimmed, preferredIdentifier: preferredVoiceIdentifier)
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    /// English voices for the Settings picker, best quality first.
    static func englishVoiceOptions() -> [VoiceOption] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
                if lhs.language != rhs.language { return lhs.language < rhs.language }
                return lhs.name < rhs.name
            }
            .map { VoiceOption(id: $0.identifier, name: $0.name, language: $0.language, qualityLabel: qualityLabel($0.quality)) }
    }

    // MARK: - Voice selection

    private static func voice(for text: String, preferredIdentifier: String?) -> AVSpeechSynthesisVoice? {
        if isMostlyChinese(text) {
            return bestVoice(languagePrefix: "zh-CN") ?? bestVoice(languagePrefix: "zh")
        }
        if let preferredIdentifier, let voice = AVSpeechSynthesisVoice(identifier: preferredIdentifier) {
            return voice
        }
        return bestVoice(languagePrefix: "en-US") ?? bestVoice(languagePrefix: "en")
    }

    /// Highest-quality installed voice whose language starts with `languagePrefix`.
    private static func bestVoice(languagePrefix: String) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(languagePrefix) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
    }

    private static func isMostlyChinese(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else { return false }
        return language == .simplifiedChinese || language == .traditionalChinese
    }

    private static func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return ""
        }
    }
}

// The delegate callbacks arrive on an arbitrary queue; hop to the main actor before touching the
// published state that SwiftUI observes.
extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Re-read our own synthesizer on the main actor (not the callback's copy, which is not
        // Sendable). Reading it at that moment also avoids a stale "stopped" from an old utterance
        // flipping the icon after a new one has already started.
        Task { @MainActor in self.isSpeaking = self.synthesizer.isSpeaking }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = self.synthesizer.isSpeaking }
    }
}
