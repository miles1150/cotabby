import XCTest
@testable import Cotabby

/// Tests the lenient decoding of DeepSeek replies. Fixtures mirror real replies captured while
/// testing the live API (word, idiom and sentence cases), plus the drift we must tolerate.
final class ExplainResponseDecoderTests: XCTestCase {

    /// Wraps model-written content in the OpenAI-compatible envelope DeepSeek returns.
    private func envelope(_ content: String) throws -> Data {
        let object: [String: Any] = [
            "id": "test",
            "choices": [["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"]]
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    func test_wordReply_decodesAllFields() throws {
        let content = """
        {"mode":"word","explanation":"A very small difference in meaning, feeling, or sound.",
         "chinese":"细微差别；微妙之处","ipa":"/ˈnjuː.ɑːns/","part_of_speech":"noun",
         "example":"There is a nuance in meaning between these two words.","hard_words":[]}
        """
        let result = try ExplainResponseDecoder.decode(try envelope(content))

        XCTAssertEqual(result, ExplainResult(
            explanation: "A very small difference in meaning, feeling, or sound.",
            chinese: "细微差别；微妙之处",
            ipa: "/ˈnjuː.ɑːns/",
            partOfSpeech: "noun",
            example: "There is a nuance in meaning between these two words.",
            hardWords: []
        ))
    }

    func test_sentenceReply_decodesHardWordsAndNullOptionals() throws {
        let content = """
        {"explanation":"I will talk to you again after the pull request is merged.",
         "chinese":"等这个 PR 合并之后，我会再回来找你。","ipa":null,"part_of_speech":null,"example":null,
         "hard_words":[{"word":"circle back","meaning":"return to a topic later"},
                       {"word":"lands","meaning":"gets merged (software slang)"}]}
        """
        let result = try ExplainResponseDecoder.decodeContent(content)

        XCTAssertNil(result.ipa)
        XCTAssertNil(result.partOfSpeech)
        XCTAssertNil(result.example)
        XCTAssertEqual(result.hardWords, [
            ExplainHardWord(word: "circle back", meaning: "return to a topic later"),
            ExplainHardWord(word: "lands", meaning: "gets merged (software slang)")
        ])
    }

    func test_codeFencedJSON_isAccepted() throws {
        let content = "```json\n{\"explanation\":\"hi\",\"chinese\":\"你好\"}\n```"
        let result = try ExplainResponseDecoder.decodeContent(content)
        XCTAssertEqual(result.explanation, "hi")
        XCTAssertEqual(result.chinese, "你好")
    }

    /// "null" written as a string, empty strings and whitespace all mean "absent".
    func test_nullLikeStrings_becomeNil() throws {
        let content = #"{"explanation":"x","chinese":"y","ipa":"null","part_of_speech":"  ","example":""}"#
        let result = try ExplainResponseDecoder.decodeContent(content)
        XCTAssertNil(result.ipa)
        XCTAssertNil(result.partOfSpeech)
        XCTAssertNil(result.example)
        XCTAssertEqual(result.hardWords, [])
    }

    func test_hardWords_skipMalformedEntriesAndCapAtThree() throws {
        let content = """
        {"explanation":"x","chinese":"y","hard_words":[
          {"word":"a","meaning":"1"},"oops",{"word":"b"},{"word":"c","meaning":"3"},
          {"word":"d","meaning":"4"},{"word":"e","meaning":"5"}]}
        """
        let result = try ExplainResponseDecoder.decodeContent(content)
        XCTAssertEqual(result.hardWords.map(\.word), ["a", "c", "d"])
    }

    func test_missingRequiredField_throwsMalformed() {
        XCTAssertThrowsError(try ExplainResponseDecoder.decodeContent(#"{"explanation":"only this"}"#)) {
            XCTAssertEqual($0 as? ExplainFailure, .malformedResponse)
        }
        XCTAssertThrowsError(try ExplainResponseDecoder.decodeContent(#"{"chinese":"只有这个","explanation":" "}"#)) {
            XCTAssertEqual($0 as? ExplainFailure, .malformedResponse)
        }
    }

    func test_nonJSONContent_throwsMalformed() {
        XCTAssertThrowsError(try ExplainResponseDecoder.decodeContent("Sure! Here is the explanation: ...")) {
            XCTAssertEqual($0 as? ExplainFailure, .malformedResponse)
        }
    }

    func test_emptyOrNullContent_throwsMalformed() throws {
        let nullContent = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": NSNull()]]]])
        XCTAssertThrowsError(try ExplainResponseDecoder.decode(nullContent))
        XCTAssertThrowsError(try ExplainResponseDecoder.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try ExplainResponseDecoder.decode(Data("not json".utf8)))
    }
}
