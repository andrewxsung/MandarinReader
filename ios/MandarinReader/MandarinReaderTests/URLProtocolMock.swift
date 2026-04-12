import Foundation

/// Test helper: intercepts all URLSession requests and returns a canned response.
/// Install via `URLSessionConfiguration.ephemeral` + `protocolClasses = [URLProtocolMock.self]`.
final class URLProtocolMock: URLProtocol {

    /// Closure-based handler — set before running the test. Receives the incoming
    /// request and returns the HTTP response + body to emit.
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// All requests seen since the last `reset()`.
    static var capturedRequests: [URLRequest] = []

    static func reset() {
        handler = nil
        capturedRequests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequests.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { }
}
