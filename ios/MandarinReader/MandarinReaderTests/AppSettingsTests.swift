import XCTest
@testable import MandarinReader

final class AppSettingsTests: XCTestCase {

    var defaults: UserDefaults!
    var settings: AppSettings!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "AppSettingsTests-\(UUID().uuidString)")!
        settings = AppSettings(defaults: defaults)
    }

    func test_emptyByDefault() {
        XCTAssertEqual(settings.backendURL, "")
        XCTAssertEqual(settings.apiKey, "")
    }

    func test_persistsBackendURL() {
        settings.backendURL = "https://example.com"

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.backendURL, "https://example.com")
    }

    func test_persistsAPIKey() {
        settings.apiKey = "secret-123"

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.apiKey, "secret-123")
    }

    func test_isConfigured_falseWhenURLMissing() {
        settings.apiKey = "key"
        XCTAssertFalse(settings.isConfigured)
    }

    func test_isConfigured_falseWhenKeyMissing() {
        settings.backendURL = "https://example.com"
        XCTAssertFalse(settings.isConfigured)
    }

    func test_isConfigured_trueWhenBothPresent() {
        settings.backendURL = "https://example.com"
        settings.apiKey = "key"
        XCTAssertTrue(settings.isConfigured)
    }
}
