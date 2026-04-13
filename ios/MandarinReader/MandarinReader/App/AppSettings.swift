import Foundation
import Combine

/// Backend URL and API key, persisted to UserDefaults.
/// Published so SwiftUI views refresh when values change.
final class AppSettings: ObservableObject {

    private enum Key {
        static let backendURL = "settings.backendURL"
        static let apiKey = "settings.apiKey"
    }

    private let defaults: UserDefaults

    @Published var backendURL: String {
        didSet { defaults.set(backendURL, forKey: Key.backendURL) }
    }

    @Published var apiKey: String {
        didSet { defaults.set(apiKey, forKey: Key.apiKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.backendURL = defaults.string(forKey: Key.backendURL) ?? ""
        self.apiKey = defaults.string(forKey: Key.apiKey) ?? ""
    }

    var isConfigured: Bool {
        !backendURL.isEmpty && !apiKey.isEmpty
    }

    /// Convenience for wiring APIClient. Nil if `backendURL` is invalid.
    func makeAPIClient() -> APIClient? {
        guard let url = URL(string: backendURL), !apiKey.isEmpty else { return nil }
        return APIClient(baseURL: url, apiKey: apiKey)
    }
}
