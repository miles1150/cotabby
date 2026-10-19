import XCTest
@testable import Cotabby

/// Pure tests for the rules that turn a raw selection into a bounded, classified `ExplainInput`.
/// The mode decides which prompt DeepSeek gets and which fields the panel shows, so a wrong mode
/// is a visible behavior change even though no network call is involved.
final class ExplainModeClassifierTests: XCTestCase {

    // MARK: - Empty input

    func test_emptyOrWhitespaceSelection_returnsNil() {
        for raw in ["", "   ", "\n\t \n"] {
            XCTAssertNil(ExplainModeClassifier.classify(raw), "raw \(raw.debugDescription)")
        }
    }

    // MARK: - Word mode

    func test_singleWord_isWordMode() {
        let input = ExplainModeClassifier.classify("nuance")
        XCTAssertEqual(input, ExplainInput(text: "nuance", mode: .word, wasTruncated: false))
    }

    /// Idioms without sentence punctuation read like dictionary entries, not sentences.
    func test_shortPhraseWithoutSentenceEnding_isWordMode() {
        XCTAssertEqual(ExplainModeClassifier.classify("take it with a grain of salt")?.mode, .word)
        XCTAssertEqual(ExplainModeClassifier.classify("circle back")?.mode, .word)
    }

    /// Selections copied from chat often carry stray quotes or a trailing comma; those must not
    /// push a single word into sentence mode.
    func test_wordWithSurroundingPunctuation_isWordModeAndKeepsText() {
        let input = ExplainModeClassifier.classify("  \"nuance,\"  ")
        XCTAssertEqual(input?.mode, .word)
        XCTAssertEqual(input?.text, "\"nuance,\"")
    }

    // MARK: - Sentence mode

    func test_shortSentenceWithEnding_isSentenceMode() {
        XCTAssertEqual(ExplainModeClassifier.classify("I'll circle back once the PR lands.")?.mode, .sentence)
    }

    func test_shortPhraseWithQuestionMark_isSentenceMode() {
        XCTAssertEqual(ExplainModeClassifier.classify("Does that make sense?")?.mode, .sentence)
    }

    /// Seven or more words read as a sentence even when the selection stops before the period.
    func test_longerFragmentWithoutEnding_isSentenceMode() {
        XCTAssertEqual(
            ExplainModeClassifier.classify("we should refactor the parser before adding more rules")?.mode,
            .sentence
        )
    }

    func test_twoSentences_isSentenceMode() {
        XCTAssertEqual(ExplainModeClassifier.classify("It works now. Let me know if it breaks again.")?.mode, .sentence)
    }

    // MARK: - Paragraph mode

    func test_threeSentences_isParagraphMode() {
        let text = "I pushed the fix. The tests pass locally. Could you review it today?"
        XCTAssertEqual(ExplainModeClassifier.classify(text)?.mode, .paragraph)
    }

    func test_manyWordsInOneSentence_isParagraphMode() {
        let text = Array(repeating: "word", count: ExplainModeClassifier.maxSentenceWords + 1).joined(separator: " ")
        XCTAssertEqual(ExplainModeClassifier.classify(text)?.mode, .paragraph)
    }

    // MARK: - Normalization and truncation

    /// Line breaks and runs of spaces from wrapped terminal or chat output collapse to one space.
    func test_internalWhitespaceIsCollapsed() {
        XCTAssertEqual(ExplainModeClassifier.classify("circle\n   back")?.text, "circle back")
    }

    func test_longSelection_isTruncatedAtWordBoundary() {
        let raw = Array(repeating: "alpha", count: 200).joined(separator: " ")
        let input = ExplainModeClassifier.classify(raw)

        XCTAssertEqual(input?.wasTruncated, true)
        XCTAssertEqual(input?.mode, .paragraph)
        let text = input?.text ?? ""
        XCTAssertLessThanOrEqual(text.count, ExplainModeClassifier.maxCharacters)
        XCTAssertFalse(text.hasSuffix(" "))
        XCTAssertTrue(text.split(separator: " ").allSatisfy { $0 == "alpha" }, "no word may be cut")
    }

    /// A single huge token (a URL or base64 blob) has no word boundary; it is hard-cut instead.
    func test_longSingleToken_isHardCut() {
        let raw = String(repeating: "x", count: ExplainModeClassifier.maxCharacters + 50)
        let input = ExplainModeClassifier.classify(raw)
        XCTAssertEqual(input?.text.count, ExplainModeClassifier.maxCharacters)
        XCTAssertEqual(input?.wasTruncated, true)
    }

    /// Chinese full-width sentence endings count as sentence endings too.
    func test_chineseSentenceEndingsCount() {
        XCTAssertEqual(ExplainModeClassifier.sentenceCount(in: "这是第一句。这是第二句！这是第三句？"), 3)
    }
}
