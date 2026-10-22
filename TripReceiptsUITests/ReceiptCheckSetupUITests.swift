import XCTest

/// Drives Setup → Receipt check the way a person does: type the parser's
/// address, tap Check connection, read what the screen says. Needs the
/// parser running on this Mac (`Tools/ui-check.sh` starts one).
final class ReceiptCheckSetupUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        dismissNotificationPrompt()
        app.tabBars.buttons["Setup"].tap()
    }

    func testCheckConnectionReachesTheParser() {
        let port = ProcessInfo.processInfo.environment["PARSER_PORT"] ?? "8787"
        enterServer("127.0.0.1:\(port)")
        snapshot("1-address-typed")

        let check = app.buttons["checkParserButton"]
        XCTAssertTrue(check.isEnabled, "Check connection is greyed out for a valid address")
        check.tap()

        let status = app.descendants(matching: .any).matching(identifier: "parserStatus").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 15), "Nothing appeared after Check connection")
        snapshot("2-connected")
        XCTAssertTrue(status.label.contains("Connected · parser v1"), "Status said: \(status.label)")
    }

    func testUnreachableServerSaysWhy() {
        enterServer("127.0.0.1:9")
        app.buttons["checkParserButton"].tap()

        let status = app.descendants(matching: .any).matching(identifier: "parserStatus").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 15), "Nothing appeared after Check connection")
        snapshot("3-unreachable")
        XCTAssertTrue(status.label.contains("Couldn't reach the parser server:"), "Status said: \(status.label)")
    }

    func testUnusableAddressIsExplained() {
        enterServer("ftp://files.example.com")
        let hint = app.descendants(matching: .any).matching(identifier: "parserAddressHint").firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 5), "No explanation for an address the app can't use")
        XCTAssertFalse(app.buttons["checkParserButton"].isEnabled)
        snapshot("4-unusable")
    }

    // MARK: - Helpers

    private func enterServer(_ address: String) {
        let field = app.textFields["parserServerField"]
        for _ in 0..<6 where !field.isHittable { app.swipeUp() }
        XCTAssertTrue(field.isHittable, "The Parser server field can't be reached")
        // Tap at the right-hand end so deleting clears whatever an earlier run left.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "No keyboard for the field")
        if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        field.typeText(address)
        XCTAssertEqual(field.value as? String, address, "The field didn't take the typed address")
        let check = app.buttons["checkParserButton"]
        for _ in 0..<4 where !check.isHittable { app.swipeUp() }
    }

    private func dismissNotificationPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Don’t Allow", "Don't Allow"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 2) {
                button.tap()
                return
            }
        }
    }

    /// Kept with the test result, and copied to SCREENSHOT_DIR when set.
    private func snapshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
