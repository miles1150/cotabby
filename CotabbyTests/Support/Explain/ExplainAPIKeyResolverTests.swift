import XCTest
@testable import Cotabby

/// Pins the key-source priority and the rule that a non-DeepSeek endpoint key is never reused.
final class ExplainAPIKeyResolverTests: XCTestCase {

    func test_environmentWinsOverEverything() {
        let resolution = ExplainAPIKeyResolver.resolve(
            environment: ["DEEPSEEK_API_KEY": " sk-env "],
            explainKey: "sk-explain",
            endpointKey: "sk-endpoint",
            endpointBaseURL: "https://api.deepseek.com"
        )
        XCTAssertEqual(resolution, .init(apiKey: "sk-env", source: .environment))
    }

    func test_explainKeyIsUsedWhenEnvironmentIsEmpty() {
        let resolution = ExplainAPIKeyResolver.resolve(
            environment: ["DEEPSEEK_API_KEY": "  "],
            explainKey: "sk-explain",
            endpointKey: "sk-endpoint",
            endpointBaseURL: "https://api.deepseek.com"
        )
        XCTAssertEqual(resolution, .init(apiKey: "sk-explain", source: .explainKeychain))
    }

    func test_endpointKeyIsReusedOnlyForDeepSeek() {
        XCTAssertEqual(
            ExplainAPIKeyResolver.resolve(
                environment: [:], explainKey: nil, endpointKey: "sk-endpoint",
                endpointBaseURL: "https://api.deepseek.com/beta"
            ),
            .init(apiKey: "sk-endpoint", source: .endpointKeychain)
        )
        XCTAssertNil(ExplainAPIKeyResolver.resolve(
            environment: [:], explainKey: nil, endpointKey: "sk-other",
            endpointBaseURL: "http://127.0.0.1:11434/v1"
        ))
    }

    /// The endpoint key must not follow Explain to a server the key was not issued for.
    func test_endpointKeyIsNotReusedWhenExplainPointsElsewhere() {
        XCTAssertNil(ExplainAPIKeyResolver.resolve(
            environment: [:], explainKey: nil, endpointKey: "sk-endpoint",
            endpointBaseURL: "https://api.deepseek.com", explainBaseURL: "https://example.com"
        ))
    }

    func test_noKeyAnywhere_returnsNil() {
        XCTAssertNil(ExplainAPIKeyResolver.resolve(
            environment: [:], explainKey: "", endpointKey: nil, endpointBaseURL: nil
        ))
    }

    func test_deepSeekHostCheckRejectsLookAlikes() {
        XCTAssertTrue(ExplainAPIKeyResolver.isDeepSeekHost("https://api.deepseek.com"))
        XCTAssertTrue(ExplainAPIKeyResolver.isDeepSeekHost("https://API.DeepSeek.com/v1"))
        XCTAssertTrue(ExplainAPIKeyResolver.isDeepSeekHost("https://deepseek.com"))
        XCTAssertFalse(ExplainAPIKeyResolver.isDeepSeekHost("https://deepseek.com.evil.example"))
        XCTAssertFalse(ExplainAPIKeyResolver.isDeepSeekHost("https://notdeepseek.com"))
        XCTAssertFalse(ExplainAPIKeyResolver.isDeepSeekHost("not a url"))
        XCTAssertFalse(ExplainAPIKeyResolver.isDeepSeekHost(nil))
    }
}
