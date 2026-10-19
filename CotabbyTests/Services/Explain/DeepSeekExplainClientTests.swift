import XCTest
@testable import Cotabby

/// Integration-style tests for the DeepSeek client. A `URLProtocol` stub stands in for the
/// network, so the real `URLSession` request path runs (headers, body, status handling, decoding)
/// without contacting DeepSeek.
final class DeepSeekExplainClientTests: XCTestCase {
    private var client: DeepSeekExplainClient!
    private let input = ExplainInput(text: "nuance", mode: .word, wasTruncated: false)

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        client = DeepSeekExplainClient(session: URLSession(configuration: configuration))
    }

    override func tearDown() {
        StubURLProtocol.reset()
        client = nil
        super.tearDown()
    }

    private func reply(_ content: String) -> Data {
        let object: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]]]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    func test_successfulRequest_sendsExpectedRequestAndDecodes() async throws {
        StubURLProtocol.respond(status: 200, body: reply(#"{"explanation":"a small difference","chinese":"细微差别"}"#))

        let result = try await client.explain(input, apiKey: "sk-test", model: "deepseek-flash", baseURL: "https://api.deepseek.com/")

        XCTAssertEqual(result.explanation, "a small difference")
        XCTAssertEqual(result.chinese, "细微差别")
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "deepseek-flash")
    }

    func test_unauthorizedStatus_mapsToUnauthorized() async {
        StubURLProtocol.respond(status: 401, body: Data(#"{"error":{"message":"Authentication Fails"}}"#.utf8))
        await assertFailure(.unauthorized)
    }

    func test_rateLimitStatus_mapsToRateLimited() async {
        StubURLProtocol.respond(status: 429, body: Data())
        await assertFailure(.rateLimitedOrNoBalance)
    }

    func test_serverStatus_mapsToServer() async {
        StubURLProtocol.respond(status: 503, body: Data())
        await assertFailure(.server(statusCode: 503))
    }

    func test_garbageBody_mapsToMalformed() async {
        StubURLProtocol.respond(status: 200, body: Data("<html>oops</html>".utf8))
        await assertFailure(.malformedResponse)
    }

    func test_invalidBaseURL_failsWithoutNetwork() async {
        await assertFailure(
            .network("The DeepSeek server address is not a valid URL."),
            baseURL: "not a url"
        )
        XCTAssertNil(StubURLProtocol.lastRequest)
    }

    func test_chatCompletionsURL() {
        XCTAssertEqual(
            DeepSeekExplainClient.chatCompletionsURL(baseURL: "https://api.deepseek.com")?.absoluteString,
            "https://api.deepseek.com/chat/completions"
        )
        XCTAssertEqual(
            DeepSeekExplainClient.chatCompletionsURL(baseURL: " https://api.deepseek.com/v1// ")?.absoluteString,
            "https://api.deepseek.com/v1/chat/completions"
        )
        XCTAssertNil(DeepSeekExplainClient.chatCompletionsURL(baseURL: "ftp://api.deepseek.com"))
        // Plain HTTP would expose the key and text on the network; only this Mac is allowed.
        XCTAssertNil(DeepSeekExplainClient.chatCompletionsURL(baseURL: "http://api.deepseek.com"))
        XCTAssertEqual(
            DeepSeekExplainClient.chatCompletionsURL(baseURL: "http://127.0.0.1:8899")?.absoluteString,
            "http://127.0.0.1:8899/chat/completions"
        )
        XCTAssertNil(DeepSeekExplainClient.chatCompletionsURL(baseURL: ""))
    }

    func test_statusMapping() {
        XCTAssertNil(DeepSeekExplainClient.failure(forStatus: 200))
        XCTAssertEqual(DeepSeekExplainClient.failure(forStatus: 403), .unauthorized)
        XCTAssertEqual(DeepSeekExplainClient.failure(forStatus: 402), .rateLimitedOrNoBalance)
        XCTAssertEqual(DeepSeekExplainClient.failure(forStatus: 400), .server(statusCode: 400))
    }

    private func assertFailure(
        _ expected: ExplainFailure,
        baseURL: String = "https://api.deepseek.com",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await client.explain(input, apiKey: "sk-test", model: "deepseek-flash", baseURL: baseURL)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ExplainFailure, expected, file: file, line: line)
        }
    }
}

/// Minimal `URLProtocol` stub: records the last request and answers with a canned status and body.
/// Static state is fine because XCTest runs these tests serially and `tearDown` resets it.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    static func respond(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    static func reset() {
        status = 200
        body = Data()
        lastRequest = nil
        lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        // URLSession moves `httpBody` into a stream before it reaches a protocol; read it back.
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
