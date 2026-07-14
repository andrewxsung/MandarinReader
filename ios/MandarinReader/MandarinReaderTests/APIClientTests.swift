import XCTest
@testable import MandarinReader

final class APIClientTests: XCTestCase {

    var client: APIClient!

    override func setUp() {
        super.setUp()
        URLProtocolMock.reset()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolMock.self]
        let session = URLSession(configuration: config)

        client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "test-key-123",
            session: session
        )
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

    func test_fetchQueue_sendsAPIKeyHeader() async throws {
        URLProtocolMock.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.example.com/api/queue?n=20")!,
                statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "[]".data(using: .utf8)!)
        }

        _ = try await client.fetchQueue(count: 20)

        let header = URLProtocolMock.capturedRequests[0].value(forHTTPHeaderField: "X-API-Key")
        XCTAssertEqual(header, "test-key-123")
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

    // MARK: - helpers

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
