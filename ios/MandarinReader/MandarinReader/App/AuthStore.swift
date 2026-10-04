import Combine
import Foundation

/// Observable auth state. Replaces AppSettings — the backend URL is now a
/// compile-time constant (AppConfig) and credentials are a Keychain token.
@MainActor
final class AuthStore: ObservableObject {

    @Published private(set) var token: String?
    @Published private(set) var email: String?

    private let storage: TokenStorage
    private let urlSession: URLSession

    /// `storage` defaults to the Keychain. (Optional rather than a default
    /// argument: default-argument expressions are nonisolated, and the
    /// project's default MainActor isolation makes `KeychainTokenStorage()`
    /// main-actor-isolated.)
    init(storage: TokenStorage? = nil, urlSession: URLSession = .shared) {
        let storage = storage ?? KeychainTokenStorage()
        self.storage = storage
        self.urlSession = urlSession
        let saved = storage.load()
        self.token = saved?.token
        // The Keychain token survives app deletion but the UserDefaults email
        // doesn't, so after a reinstall the stored email can be "".
        self.email = saved?.email.isEmpty == false ? saved?.email : nil
    }

    // Required by this project's Xcode 26 setup: @MainActor classes need an
    // explicit nonisolated deinit or tests crash in the back-deployed shim.
    nonisolated deinit { }

    var isSignedIn: Bool { token != nil }

    func makeAPIClient() -> APIClient {
        APIClient(baseURL: AppConfig.baseURL, token: token, session: urlSession)
    }

    func signIn(email: String, password: String) async throws {
        apply(try await makeAPIClient().login(email: email, password: password))
    }

    func signUp(email: String, password: String) async throws {
        apply(try await makeAPIClient().signup(email: email, password: password))
    }

    func signOut() {
        // Capture the client (and with it the current token) BEFORE clearing
        // state, so the best-effort server-side revocation sends the old token.
        let client = makeAPIClient()
        Task { try? await client.logout() }
        clear()
    }

    /// Call when any API request returns 401 — the session was revoked or expired.
    /// Pass the `token` of the APIClient that made the failing request: a slow
    /// request sent with an old token can come back 401 after the user has
    /// signed in again, and must not clear the new session.
    func handleUnauthorized(rejectedToken: String?) {
        guard rejectedToken == token else { return }
        clear()
    }

    private func clear() {
        storage.clear()
        token = nil
        email = nil
    }

    private func apply(_ auth: AuthResponse) {
        storage.save(token: auth.token, email: auth.email)
        token = auth.token
        email = auth.email
    }
}
