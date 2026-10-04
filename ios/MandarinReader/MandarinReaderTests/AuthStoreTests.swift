import XCTest
@testable import MandarinReader

/// One AuthStore per test, backed by InMemoryTokenStorage — never the real
/// Keychain/UserDefaults (Xcode 26: a second ObservableObject against the
/// same defaults suite in one test crashes).
@MainActor
final class AuthStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocolMock.reset()
    }

    override func tearDown() {
        URLProtocolMock.reset()
        super.tearDown()
    }

    private func mockedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolMock.self]
        return URLSession(configuration: config)
    }

    func test_initLoadsPersistedToken() {
        let storage = InMemoryTokenStorage(token: "tok123", email: "a@x.com")
        let store = AuthStore(storage: storage)
        XCTAssertTrue(store.isSignedIn)
        XCTAssertEqual(store.email, "a@x.com")
    }

    func test_initWithEmptyStorageIsSignedOut() {
        let store = AuthStore(storage: InMemoryTokenStorage())
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(store.email)
    }

    func test_handleUnauthorizedClearsState() {
        let storage = InMemoryTokenStorage(token: "tok123", email: "a@x.com")
        let store = AuthStore(storage: storage)
        store.handleUnauthorized()
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(store.email)
        XCTAssertNil(storage.load())
    }

    func test_signInPersistsToken() async throws {
        URLProtocolMock.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = #"{"token": "fresh", "email": "a@x.com"}"#.data(using: .utf8)!
            return (response, body)
        }
        let storage = InMemoryTokenStorage()
        let store = AuthStore(storage: storage, urlSession: mockedSession())

        try await store.signIn(email: "a@x.com", password: "password123")

        XCTAssertTrue(store.isSignedIn)
        XCTAssertEqual(store.email, "a@x.com")
        XCTAssertEqual(storage.load()?.token, "fresh")
        XCTAssertEqual(URLProtocolMock.capturedRequests.first?.url?.path, "/api/auth/login")
    }

    func test_signUpPersistsToken() async throws {
        URLProtocolMock.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            let body = #"{"token": "new", "email": "b@x.com"}"#.data(using: .utf8)!
            return (response, body)
        }
        let storage = InMemoryTokenStorage()
        let store = AuthStore(storage: storage, urlSession: mockedSession())

        try await store.signUp(email: "b@x.com", password: "password123")

        XCTAssertTrue(store.isSignedIn)
        XCTAssertEqual(storage.load()?.email, "b@x.com")
        XCTAssertEqual(URLProtocolMock.capturedRequests.first?.url?.path, "/api/auth/signup")
    }

    func test_signInFailureStaysSignedOut() async {
        URLProtocolMock.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let storage = InMemoryTokenStorage()
        let store = AuthStore(storage: storage, urlSession: mockedSession())

        do {
            try await store.signIn(email: "a@x.com", password: "wrongpass1")
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthorized)
        }
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(storage.load())
    }

    func test_signOutClearsStateAndRevokesOldToken() async {
        let logoutSent = expectation(description: "logout request sent")
        URLProtocolMock.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/auth/logout")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok123")
            logoutSent.fulfill()
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let storage = InMemoryTokenStorage(token: "tok123", email: "a@x.com")
        let store = AuthStore(storage: storage, urlSession: mockedSession())

        store.signOut()

        // State clears synchronously; the revocation call is best-effort async
        // but must still carry the token captured before clearing.
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(store.email)
        XCTAssertNil(storage.load())
        await fulfillment(of: [logoutSent], timeout: 2)
    }
}
