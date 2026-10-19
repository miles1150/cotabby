import Foundation

/// File overview:
/// Turns DeepSeek's raw chat-completions reply into an `ExplainResult`. Pure and lenient on
/// purpose: the model is asked for an exact JSON shape, but real replies drift (code fences
/// around the JSON, a missing optional key, "null" written as a string, extra hard words). The
/// decoder accepts every harmless variation and rejects only replies that lack the two fields the
/// panel cannot do without: `explanation` and `chinese`.
///
/// Two decoding steps, two concerns:
/// 1. The OpenAI-compatible envelope (`choices[0].message.content`) — fixed by the API.
/// 2. The content string, which is itself JSON written by the model — loose by nature.
nonisolated enum ExplainResponseDecoder {
    /// The panel shows at most this many hard words even if the model returns more.
    static let maxHardWords = 3

    static func decode(_ data: Data) throws -> ExplainResult {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let content = envelope.choices.first?.message.content else {
            throw ExplainFailure.malformedResponse
        }
        return try decodeContent(content)
    }

    /// Decodes the model-written JSON string. Internal so tests can feed content directly.
    static func decodeContent(_ content: String) throws -> ExplainResult {
        let json = stripCodeFence(content)
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExplainFailure.malformedResponse
        }

        guard let explanation = cleanString(object["explanation"]),
              let chinese = cleanString(object["chinese"]) else {
            throw ExplainFailure.malformedResponse
        }

        return ExplainResult(
            explanation: explanation,
            chinese: chinese,
            ipa: cleanString(object["ipa"]),
            partOfSpeech: cleanString(object["part_of_speech"]),
            example: cleanString(object["example"]),
            hardWords: hardWords(from: object["hard_words"])
        )
    }

    // MARK: - Private helpers

    /// Removes a Markdown code fence (```json … ```) if the model wrapped its JSON in one.
    private static func stripCodeFence(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        if let firstNewline = trimmed.firstIndex(of: "\n") {
            trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
        }
        if trimmed.hasSuffix("```") {
            trimmed = String(trimmed.dropLast(3))
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A non-empty trimmed string, or nil for missing values, JSON null, "", or the text "null".
    private static func cleanString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "null" else { return nil }
        return trimmed
    }

    /// Reads `[{"word": …, "meaning": …}]`, skipping malformed entries, capped at `maxHardWords`.
    private static func hardWords(from value: Any?) -> [ExplainHardWord] {
        guard let entries = value as? [Any] else { return [] }
        let words = entries.compactMap { entry -> ExplainHardWord? in
            guard let dictionary = entry as? [String: Any],
                  let word = cleanString(dictionary["word"]),
                  let meaning = cleanString(dictionary["meaning"]) else { return nil }
            return ExplainHardWord(word: word, meaning: meaning)
        }
        return Array(words.prefix(maxHardWords))
    }

    // MARK: - Envelope wire types

    private struct Envelope: Decodable {
        let choices: [Choice]
    }

    private struct Choice: Decodable {
        let message: Message
    }

    private struct Message: Decodable {
        let content: String?
    }
}
