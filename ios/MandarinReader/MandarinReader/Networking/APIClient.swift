import Foundation

enum APIError: Error, Equatable {
    case unauthorized
    case httpError(status: Int)
    case invalidResponse
}

/// Thin wrapper around `URLSession` for the MandarinReader backend.
/// Injected with baseURL, API key, and session for testability.
final class APIClient {
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.encoder = JSONEncoder()
    }

    /// `GET /api/queue?n={count}` — returns the next N words from the priority queue.
    func fetchQueue(count: Int) async throws -> [WordQueueItem] {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/queue"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "n", value: String(count))]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")

        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        return try decoder.decode([WordQueueItem].self, from: data)
    }

    /// `POST /api/review/{wordId}` with body `{"result": "known" | "learning" | "ignore"}`.
    func submitReview(wordId: Int, result: ReviewResult) async throws {
        let url = baseURL.appendingPathComponent("api/review/\(wordId)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(ReviewRequest(result: result))

        let (_, response) = try await session.data(for: request)
        try Self.validate(response)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw APIError.unauthorized
        default: throw APIError.httpError(status: http.statusCode)
        }
    }
}
