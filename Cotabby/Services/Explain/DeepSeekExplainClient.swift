import Foundation

/// File overview:
/// The network boundary of Explain & Translate: one HTTPS POST to DeepSeek's OpenAI-compatible
/// `chat/completions` route, mapped to an `ExplainResult` or an `ExplainFailure`.
///
/// Everything that shapes the answer (prompt, JSON keys, thinking off) is built by the pure
/// `ExplainPromptBuilder`, and everything that reads the answer is the pure
/// `ExplainResponseDecoder`. This type only owns transport concerns: the URL, headers, timeout,
/// cancellation, and HTTP status mapping. That split keeps the side-effectful part tiny.
///
/// It is not `@MainActor`: `URLSession` does its socket work on its own queues, and keeping the
/// client nonisolated means a slow network never touches the main thread.

/// What the coordinator needs from the client. A protocol so tests can substitute a fake that
/// returns canned results without any networking.
protocol ExplainGenerating: Sendable {
    func explain(_ input: ExplainInput, apiKey: String, model: String, baseURL: String) async throws -> ExplainResult
}

nonisolated final class DeepSeekExplainClient: ExplainGenerating {
    /// A short request: one non-streamed JSON answer. Real replies arrived in 1.1–1.5 s in testing;
    /// 25 s covers a slow network without leaving the spinner up forever.
    static let timeoutSeconds: TimeInterval = 25

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func explain(_ input: ExplainInput, apiKey: String, model: String, baseURL: String) async throws -> ExplainResult {
        guard let url = Self.chatCompletionsURL(baseURL: baseURL) else {
            throw ExplainFailure.network("The DeepSeek server address is not a valid URL.")
        }
        var request = URLRequest(url: url, timeoutInterval: Self.timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try ExplainPromptBuilder.requestBody(for: input, model: model)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ExplainFailure.network(error.localizedDescription)
        }

        if let failure = Self.failure(forStatus: (response as? HTTPURLResponse)?.statusCode ?? -1) {
            throw failure
        }
        return try ExplainResponseDecoder.decode(data)
    }

    /// `https://api.deepseek.com` → `https://api.deepseek.com/chat/completions`. A trailing slash or
    /// an explicit `/v1` (DeepSeek accepts both forms) is kept as the user typed it. Plain `http` is
    /// accepted only for this Mac (a local proxy or test server), because the request carries the
    /// API key and the selected text.
    static func chatCompletionsURL(baseURL: String) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + "/chat/completions"),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLoopback) else { return nil }
        return url
    }

    /// Maps an HTTP status to a user-facing failure, or `nil` for success. Pure and static so the
    /// mapping is tested without a server.
    static func failure(forStatus status: Int) -> ExplainFailure? {
        switch status {
        case 200..<300: return nil
        case 401, 403: return .unauthorized
        case 402, 429: return .rateLimitedOrNoBalance
        default: return .server(statusCode: status)
        }
    }
}
