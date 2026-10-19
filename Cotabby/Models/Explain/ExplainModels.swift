import Foundation

/// File overview:
/// Shared values for the Explain & Translate feature: what kind of text the user selected, the
/// bounded request built from it, the structured answer the model returns, and the user-facing
/// failure reasons. They live in `Models/` because every layer reads them: the pure rules in
/// `Support/Explain` produce and parse them, the DeepSeek client transports them, the coordinator
/// moves them between states, and the SwiftUI panel renders them. Keeping them as plain immutable
/// structs (no behavior, no references) means each layer can hand them along without worrying
/// about another layer mutating a value it still holds.

/// How the selected text should be explained. The mode is chosen by deterministic code rules
/// (`ExplainModeClassifier`), never by the model, so the same selection always gets the same
/// kind of answer and the rules are unit-testable.
nonisolated enum ExplainMode: String, Equatable, Sendable, CaseIterable {
    /// A single word or a short phrase/idiom: dictionary-style entry.
    case word
    /// One or two sentences: a plain-English rewrite plus the hard words.
    case sentence
    /// Anything longer: a Chinese translation plus a short English summary.
    case paragraph
}

/// The bounded text the model will see, plus how it was derived from the raw selection.
nonisolated struct ExplainInput: Equatable, Sendable {
    /// Whitespace-normalized selection, cut to the character budget.
    let text: String
    let mode: ExplainMode
    /// True when the raw selection was longer than the budget, so the panel can say so.
    let wasTruncated: Bool
}

/// One hard word or idiom pulled out of a sentence, with a simple English meaning.
nonisolated struct ExplainHardWord: Equatable, Sendable, Hashable {
    let word: String
    let meaning: String
}

/// The structured answer shown in the panel. Optional fields are absent for modes that do not
/// use them (for example `ipa` only exists for word mode), so the view shows only what exists.
nonisolated struct ExplainResult: Equatable, Sendable {
    /// Simple-English explanation (word and sentence mode) or short summary (paragraph mode).
    let explanation: String
    /// Natural Simplified Chinese translation of the selection.
    let chinese: String
    let ipa: String?
    let partOfSpeech: String?
    let example: String?
    let hardWords: [ExplainHardWord]
}

/// What the floating panel is showing. The coordinator replaces the whole value on every change
/// (never mutates a part of it), so the view always renders one consistent state.
nonisolated enum ExplainPanelState: Equatable, Sendable {
    case loading(ExplainInput)
    case loaded(ExplainInput, ExplainResult)
    /// `input` is nil when the failure happened before any text was read (no selection).
    case failed(ExplainFailure, input: ExplainInput?)

    var input: ExplainInput? {
        switch self {
        case .loading(let input), .loaded(let input, _): return input
        case .failed(_, let input): return input
        }
    }
}

/// Why an explanation could not be shown. Each case carries enough meaning for the panel to give
/// the user a short, actionable message without leaking raw HTTP bodies or the API key.
nonisolated enum ExplainFailure: Error, Equatable, Sendable {
    /// Nothing was selected, or the selection could not be read from the focused app.
    case noSelection
    /// No DeepSeek key in the environment, the Explain keychain item, or the endpoint keychain item.
    case missingAPIKey
    /// DeepSeek rejected the key (HTTP 401/403).
    case unauthorized
    /// DeepSeek asked us to slow down or the account has no balance (HTTP 402/429).
    case rateLimitedOrNoBalance
    /// Any other non-2xx status.
    case server(statusCode: Int)
    /// Network failure or timeout, with the system's short description.
    case network(String)
    /// The reply arrived but did not contain the JSON shape we asked for.
    case malformedResponse

    /// One short sentence for the panel.
    var userMessage: String {
        switch self {
        case .noSelection:
            return "Select some text first, then press the shortcut again."
        case .missingAPIKey:
            return "No DeepSeek API key. Add it in Settings → Explain & Translate."
        case .unauthorized:
            return "DeepSeek rejected the API key. Check it in Settings → Explain & Translate."
        case .rateLimitedOrNoBalance:
            return "DeepSeek is rate limiting this key or the account has no balance."
        case .server(let statusCode):
            return "DeepSeek returned an error (HTTP \(statusCode)). Try again."
        case .network(let description):
            return "Could not reach DeepSeek: \(description)"
        case .malformedResponse:
            return "DeepSeek's answer could not be read. Try again."
        }
    }
}
