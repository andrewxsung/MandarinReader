import XCTest

/// Walks through the app and saves App Store screenshots.
///
/// Run it with `scripts/take_screenshots.sh`, which runs it once on an iPhone
/// and once on an iPad simulator and copies the PNGs into `screenshots/`.
///
/// Needs the backend running locally (Debug builds talk to localhost:8000).
/// Each run signs up a fresh account, so the queue starts with the HSK 1
/// starter words (愛 first).
final class AppStoreScreenshotTests: XCTestCase {

    private var app: XCUIApplication!
    private var outputDir: URL?
    private var shotNumber = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !dir.isEmpty {
            outputDir = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: outputDir!, withIntermediateDirectories: true)
        }
        app = XCUIApplication()
        app.launchArguments += ["-resetAuthForUITests"]
        app.launch()
    }

    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        signUpFreshAccount()

        // A previous run on this simulator may have left unsynced reviews.
        let discard = app.buttons["Discard"]
        if discard.waitForExistence(timeout: 2) { discard.tap() }

        // 1. Start screen. Fewer words keeps the session short.
        let start = app.buttons["Start Practice"]
        XCTAssertTrue(start.waitForExistence(timeout: 15), "Start screen never appeared. Is the backend running?")
        let decrement = app.steppers.firstMatch.buttons["Decrement"]
        for _ in 0..<3 where decrement.exists { decrement.tap() }
        snap("start")

        // 2. Settings sheet (account, delete account, credits).
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.buttons["Delete Account"].waitForExistence(timeout: 5))
        snap("settings")
        app.buttons["Done"].tap()

        // 3. Flash card: the first starter word is shown for 3 seconds.
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(app.staticTexts["愛"].waitForExistence(timeout: 10),
                      "First card wasn't 愛. Was the account seeded with the HSK 1 words?")
        snap("flash-card")

        // 4. Writing canvas, after the flash hides the character.
        XCTAssertTrue(app.buttons["Write the word above"].waitForExistence(timeout: 10))
        sleep(1)  // let the canvas finish appearing
        snap("handwriting")
    }

    // MARK: - Helpers

    private func signUpFreshAccount() {
        let createToggle = app.buttons["No account? Create one"]
        XCTAssertTrue(createToggle.waitForExistence(timeout: 10), "Login screen never appeared")
        createToggle.tap()

        let email = app.textFields["Email"]
        email.tap()
        email.typeText("screenshots+\(Int(Date().timeIntervalSince1970))@example.com")

        let password = app.secureTextFields["Password (min 8 characters)"]
        password.tap()
        password.typeText("screenshot-pass-1")

        app.buttons["Create Account"].tap()
    }

    /// Saves a full-screen PNG to SCREENSHOT_DIR (when set) and attaches it
    /// to the test result either way.
    private func snap(_ name: String) {
        shotNumber += 1
        let fileName = String(format: "%02d-%@", shotNumber, name)
        let screenshot = XCUIScreen.main.screenshot()

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = fileName
        attachment.lifetime = .keepAlways
        add(attachment)

        if let outputDir {
            let url = outputDir.appendingPathComponent(fileName + ".png")
            XCTAssertNoThrow(try screenshot.pngRepresentation.write(to: url))
        }
    }
}
