import Foundation

/// File overview:
/// Pure rules that turn whatever the user selected into a bounded `ExplainInput`: whitespace is
/// collapsed, overly long selections are cut at a word boundary, and the text is classified as a
/// word/phrase, a sentence, or a paragraph.
///
/// Why code rules instead of letting the model decide: the mode controls which prompt we send
/// and which fields the panel renders. A deterministic rule gives the same answer for the same
/// selection every time, costs no tokens, and is covered by plain unit tests. The model only
/// does the part it is good at — explaining and translating.
///
/// This is a caseless `enum` (a namespace with no instances) because it owns no state; every
/// function is a pure input → output mapping.
nonisolated enum ExplainModeClassifier {
    /// Upper bound on characters sent to DeepSeek. Keeps cost and latency predictable and stops an
    /// accidental "select all" from shipping a whole document off the Mac.
    static let maxCharacters = 500
    /// A selection with at most this many words and no sentence ending is treated as a phrase.
    /// Seven covers common idioms ("take it with a grain of salt") without swallowing clauses.
    static let maxWordModeWords = 7
    /// Above this many words a selection is a paragraph even if it is a single long sentence.
    static let maxSentenceWords = 40
    /// Above this many sentences a selection is a paragraph.
    static let maxSentences = 2

    /// Sentence-ending marks in English and full-width Chinese punctuation.
    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "。", "！", "？", "…"]
    /// Closing marks that may trail a sentence ending ("He said 'go.'"), skipped when checking it.
    private static let trailingClosers: Set<Character> = ["\"", "'", ")", "]", "”", "’", "」", "』", "）"]

    /// Returns `nil` when the selection has no visible text; otherwise the bounded, classified input.
    static func classify(_ rawSelection: String) -> ExplainInput? {
        let normalized = collapseWhitespace(rawSelection)
        guard !normalized.isEmpty else { return nil }

        let (text, wasTruncated) = truncate(normalized)
        let wordCount = text.split(separator: " ").count
        let sentences = sentenceCount(in: text)

        let mode: ExplainMode
        if wordCount <= maxWordModeWords, !endsWithSentenceTerminator(text), sentences <= 1 {
            mode = .word
        } else if sentences <= maxSentences, wordCount <= maxSentenceWords, !wasTruncated {
            mode = .sentence
        } else {
            mode = .paragraph
        }
        return ExplainInput(text: text, mode: mode, wasTruncated: wasTruncated)
    }

    /// Counts sentence endings: a run of terminators ("?!", "...") that is followed by whitespace
    /// or the end of the text counts once. Text with no terminator is one sentence. Internal (not
    /// private) so tests can pin the counting rule directly.
    static func sentenceCount(in text: String) -> Int {
        let characters = Array(text)
        var count = 0
        var index = 0
        while index < characters.count {
            guard sentenceTerminators.contains(characters[index]) else {
                index += 1
                continue
            }
            // Swallow the whole run of terminators so "?!" or "..." count as one ending.
            var end = index
            while end + 1 < characters.count, sentenceTerminators.contains(characters[end + 1]) {
                end += 1
            }
            let next = end + 1
            // A period inside a token ("v1.2", "e.g.x") is not an ending. Full-width marks are
            // always endings because Chinese does not put a space after them.
            let isFullWidth = "。！？".contains(characters[end])
            if isFullWidth || next >= characters.count || characters[next].isWhitespace
                || trailingClosers.contains(characters[next]) {
                count += 1
            }
            index = next
        }
        return max(count, 1)
    }

    // MARK: - Private helpers

    /// Collapses every run of whitespace (spaces, tabs, line breaks from wrapped terminal or chat
    /// output) into one space and trims the ends.
    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Cuts text to `maxCharacters`, preferring the last word boundary so no word is split. A single
    /// token longer than the budget (a URL, a hash) has no boundary and is hard-cut.
    private static func truncate(_ text: String) -> (String, Bool) {
        guard text.count > maxCharacters else { return (text, false) }
        let prefix = String(text.prefix(maxCharacters))
        // If the cut lands exactly on a word boundary, the prefix is already whole words.
        let nextIndex = text.index(text.startIndex, offsetBy: maxCharacters)
        if text[nextIndex] == " " {
            return (prefix, true)
        }
        if let lastSpace = prefix.lastIndex(of: " ") {
            let wholeWords = String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespaces)
            if !wholeWords.isEmpty { return (wholeWords, true) }
        }
        return (prefix, true)
    }

    private static func endsWithSentenceTerminator(_ text: String) -> Bool {
        var trimmed = Substring(text)
        while let last = trimmed.last, trailingClosers.contains(last) {
            trimmed = trimmed.dropLast()
        }
        guard let last = trimmed.last else { return false }
        return sentenceTerminators.contains(last)
    }
}
