import Foundation

enum APIError: Error, Equatable {
    case unauthorized
    case emailTaken
    case validationFailed
    case rateLimited
    case httpError(status: Int)
    case invalidResponse
}

/// Thin wrapper around `URLSession` for the MandarinReader backend.
/// Injected with baseURL, bearer token, and session for testability.
/// `token` is nil for the unauthenticated auth calls (signup/login).
final class APIClient {
    private let baseURL: URL
    private let token: String?
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL, token: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
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

        let request = authorizedRequest(url: components.url!, method: "GET")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        return try decoder.decode([WordQueueItem].self, from: data)
    }

    /// `POST /api/review/{wordId}` with body `{"result": "known" | "learning" | "ignore"}`.
    func submitReview(wordId: Int, result: ReviewResult) async throws {
        var request = authorizedRequest(path: "api/review/\(wordId)", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(ReviewRequest(result: result))

        let (_, response) = try await session.data(for: request)
        try Self.validate(response)
    }

    private func authorizedRequest(path: String, method: String) -> URLRequest {
        authorizedRequest(url: baseURL.appendingPathComponent(path), method: method)
    }

    private func authorizedRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw APIError.unauthorized
        case 409: throw APIError.emailTaken
        case 422: throw APIError.validationFailed
        case 429: throw APIError.rateLimited
        default: throw APIError.httpError(status: http.statusCode)
        }
    }
}

// MARK: - Auth

struct AuthResponse: Decodable, Equatable {
    let token: String
    let email: String
}

private struct CredentialsBody: Encodable {
    let email: String
    let password: String
}

extension APIClient {
    /// `POST /api/auth/signup` — 201 `{token, email}`; 409 if the email is taken.
    func signup(email: String, password: String) async throws -> AuthResponse {
        try await authCall(path: "api/auth/signup", email: email, password: password)
    }

    /// `POST /api/auth/login` — 200 `{token, email}`; 401 on bad credentials.
    func login(email: String, password: String) async throws -> AuthResponse {
        try await authCall(path: "api/auth/login", email: email, password: password)
    }

    /// `POST /api/auth/logout` — revokes the bearer token server-side (204).
    func logout() async throws {
        let request = authorizedRequest(path: "api/auth/logout", method: "POST")
        let (_, response) = try await session.data(for: request)
        try Self.validate(response)
    }

    private func authCall(path: String, email: String, password: String) async throws -> AuthResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(CredentialsBody(email: email, password: password))
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        return try decoder.decode(AuthResponse.self, from: data)
    }
}
