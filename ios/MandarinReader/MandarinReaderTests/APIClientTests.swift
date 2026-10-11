import XCTest
@testable import MandarinReader

final class APIClientTests: XCTestCase {

    var client: APIClient!
    var session: URLSession!

    override func setUp() {
        super.setUp()
        URLProtocolMock.reset()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolMock.self]
        session = URLSession(configuration: config)

        client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            token: "tok123",
            session: session
        )
    }

    /// Client with no token — what AuthStore uses for signup/login.
    private func makeAnonymousClient() -> APIClient {
        APIClient(baseURL: URL(string: "https://api.example.com")!, token: nil, session: session)
    }

    private static func respond(_ status: Int, _ body: String = "") -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
    }

    override func tearDown() {
        URLProtocolMock.reset()
        super.tearDown()
    }

    // MARK: - fetchQueue

    func test_fetchQueue_buildsCorrectURL() async throws {
        URLProtocolMock.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.example.com/api/queue?n=20")!,
                statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "[]".data(using: .utf8)!)
        }

        _ = try await client.fetchQueue(count: 20)

        XCTAssertEqual(URLProtocolMock.capturedRequests.count, 1)
        let url = URLProtocolMock.capturedRequests[0].url!
        XCTAssertEqual(url.path, "/api/queue")
        XCTAssertEqual(url.query, "n=20")
    }

    func test_fetchQueue_sendsBearerToken() async throws {
        URLProtocolMock.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.example.com/api/queue?n=20")!,
                statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "[]".data(using: .utf8)!)
        }

        _ = try await client.fetchQueue(count: 20)

        let request = URLProtocolMock.capturedRequests[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok123")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
    }

    func test_fetchQueue_decodesResponse() async throws {
        let body = """
        [
            {
                "id": 1, "traditional": "你好", "pinyin": "ni3 hao3",
                "definition": "hello", "priority_score": 2.0,
                "encounter_count": 5, "context_sentence": null
            },
            {
                "id": 2, "traditional": "謝謝", "pinyin": "xie4 xie4",
                "definition": "thank you", "priority_score": 1.5,
                "encounter_count": 3, "context_sentence": null
            }
        ]
        """.data(using: .utf8)!

        URLProtocolMock.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.example.com/api/queue?n=20")!,
                statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let words = try await client.fetchQueue(count: 20)

        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words[0].traditional, "你好")
        XCTAssertEqual(words[1].traditional, "謝謝")
    }

    func test_fetchQueue_throwsOn401() async {
        URLProtocolMock.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.example.com/api/queue?n=20")!,
                statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        do {
            _ = try await client.fetchQueue(count: 20)
            XCTFail("Expected APIError.unauthorized")
        } catch APIError.unauthorized {
            // expected
        } catch {
            XCTFail("Expected APIError.unauthorized, got \(error)")
        }
    }

    // MARK: - submitReview

    func test_submitReview_buildsCorrectURLAndMethod() async throws {
        URLProtocolMock.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.example.com/api/review/42")!,
                statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8)!)
        }

        try await client.submitReview(wordId: 42, result: .known)

        XCTAssertEqual(URLProtocolMock.capturedRequests.count, 1)
        let request = URLProtocolMock.capturedRequests[0]
        XCTAssertEqual(request.url?.path, "/api/review/42")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func test_submitReview_sendsJSONBody() async throws {
        URLProtocolMock.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.example.com/api/review/42")!,
                statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8)!)
        }

        try await client.submitReview(wordId: 42, result: .learning)

        // URLProtocol strips httpBody from the recorded request — check bodyStream instead.
        let request = URLProtocolMock.capturedRequests[0]
        let bodyData: Data
        if let body = request.httpBody {
            bodyData = body
        } else if let stream = request.httpBodyStream {
            bodyData = Self.readStream(stream)
        } else {
            XCTFail("No body on request"); return
        }

        let parsed = try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
        XCTAssertEqual(parsed?["result"], "learning")
    }

    func test_submitReview_sendsBearerToken() async throws {
        URLProtocolMock.handler = Self.respond(200, "{}")

        try await client.submitReview(wordId: 42, result: .known)

        let header = URLProtocolMock.capturedRequests[0].value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(header, "Bearer tok123")
    }

    // MARK: - auth

    func test_login_postsCredentialsAndDecodesToken() async throws {
        URLProtocolMock.handler = Self.respond(200, #"{"token": "fresh-token", "email": "a@x.com"}"#)

        let auth = try await makeAnonymousClient().login(email: "a@x.com", password: "password123")

        XCTAssertEqual(auth, AuthResponse(token: "fresh-token", email: "a@x.com"))
        let request = URLProtocolMock.capturedRequests[0]
        XCTAssertEqual(request.url?.path, "/api/auth/login")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let parsed = try JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: String]
        XCTAssertEqual(parsed, ["email": "a@x.com", "password": "password123"])
    }

    func test_signup_postsToSignupPath() async throws {
        URLProtocolMock.handler = Self.respond(201, #"{"token": "t", "email": "a@x.com"}"#)

        let auth = try await makeAnonymousClient().signup(email: "a@x.com", password: "password123")

        XCTAssertEqual(auth.token, "t")
        XCTAssertEqual(URLProtocolMock.capturedRequests[0].url?.path, "/api/auth/signup")
        XCTAssertEqual(URLProtocolMock.capturedRequests[0].httpMethod, "POST")
    }

    func test_signup_conflictThrowsEmailTaken() async {
        URLProtocolMock.handler = Self.respond(409)
        do {
            _ = try await makeAnonymousClient().signup(email: "a@x.com", password: "password123")
            XCTFail("expected emailTaken")
        } catch {
            XCTAssertEqual(error as? APIError, .emailTaken)
        }
    }

    func test_login_badCredentialsThrowsUnauthorized() async {
        URLProtocolMock.handler = Self.respond(401)
        do {
            _ = try await makeAnonymousClient().login(email: "a@x.com", password: "wrongpass1")
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthorized)
        }
    }

    func test_signup_validationErrorThrowsValidationFailed() async {
        URLProtocolMock.handler = Self.respond(422, #"{"detail": []}"#)
        do {
            _ = try await makeAnonymousClient().signup(email: "nope", password: "short")
            XCTFail("expected validationFailed")
        } catch {
            XCTAssertEqual(error as? APIError, .validationFailed)
        }
    }

    func test_rateLimitedStatusMapsToRateLimited() async {
        URLProtocolMock.handler = Self.respond(429)
        do {
            _ = try await client.fetchQueue(count: 5)
            XCTFail("expected rateLimited")
        } catch {
            XCTAssertEqual(error as? APIError, .rateLimited)
        }
    }

    func test_logout_postsWithBearerToken() async throws {
        URLProtocolMock.handler = Self.respond(204)

        try await client.logout()

        let request = URLProtocolMock.capturedRequests[0]
        XCTAssertEqual(request.url?.path, "/api/auth/logout")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok123")
    }

    // MARK: - helpers

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        if let stream = request.httpBodyStream { return readStream(stream) }
        return Data()
    }

    private static func readStream(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 { data.append(buffer, count: read) }
            else { break }
        }
        return data
    }
}
