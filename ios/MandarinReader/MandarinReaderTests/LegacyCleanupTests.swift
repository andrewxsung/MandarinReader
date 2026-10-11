import XCTest
@testable import MandarinReader

final class LegacyCleanupTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "LegacyCleanupTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func test_removesLegacyKeysAndSetsFlag() {
        defaults.set("secret-123", forKey: "settings.apiKey")
        defaults.set("https://example.com", forKey: "settings.backendURL")
        // Save through the real store so a renamed store key breaks this test.
        let store = UserDefaultsPendingReviewStore(defaults: defaults)
        store.save([PendingReview(wordId: 1, traditional: "你", pinyin: nil, result: .known)])
        defaults.set("keep", forKey: "unrelated")

        LegacyCleanup.run(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "settings.apiKey"))
        XCTAssertNil(defaults.object(forKey: "settings.backendURL"))
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep")
        XCTAssertTrue(defaults.bool(forKey: LegacyCleanup.doneKey))
    }

    func test_runsOnlyOnce() {
        LegacyCleanup.run(defaults: defaults)

        // Reviews queued by the post-accounts app must survive later launches.
        let queued = Data("[{\"wordId\":1}]".utf8)
        defaults.set(queued, forKey: "pendingReviews")
        LegacyCleanup.run(defaults: defaults)

        XCTAssertEqual(defaults.data(forKey: "pendingReviews"), queued)
    }
}
