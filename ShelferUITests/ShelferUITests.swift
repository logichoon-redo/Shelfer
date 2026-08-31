//
//  ShelferUITests.swift
//  ShelferUITests
//
//  Created by Gosan on 8/14/26.
//

import XCTest

final class ShelferUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testFinderIntegrationOnboardingIsReachable() throws {
        let app = XCUIApplication()
        app.launchEnvironment["Shelfer_DEBUG_SHOW_FINDER_ONBOARDING"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["Meet Shelfer"].waitForExistence(timeout: 3))
        let shakeCell = app.buttons["tutorial.feature.shake"]
        let pathCell = app.buttons["tutorial.feature.paths"]
        XCTAssertTrue(shakeCell.exists)
        XCTAssertTrue(pathCell.exists)
        XCTAssertEqual(shakeCell.value as? String, "Selected")
        XCTAssertGreaterThan(shakeCell.frame.height, pathCell.frame.height)

        pathCell.click()
        let pathSelectionPersisted = NSPredicate { _, _ in
            pathCell.value as? String == "Selected"
                && shakeCell.value as? String == "Not selected"
                && pathCell.frame.height > shakeCell.frame.height
        }
        expectation(for: pathSelectionPersisted, evaluatedWith: nil)
        waitForExpectations(timeout: 2)

        // Moving the pointer away must not reset a click-based selection.
        app.staticTexts["Meet Shelfer"].hover()
        XCTAssertEqual(pathCell.value as? String, "Selected")

        app.buttons["Continue"].click()

        XCTAssertTrue(app.staticTexts["Use Shelfer from Finder"].waitForExistence(timeout: 2))
        let openSettingsButton = app.buttons["Open Finder Settings"]
        let enableButton = app.buttons["Open System Settings"]
        XCTAssertTrue(openSettingsButton.exists || enableButton.exists)
    }

    @MainActor
    func testClearButtonAcceptsClicksNearTheEdgeOfItsVisibleCircle() throws {
        let app = XCUIApplication()
        app.launchEnvironment["Shelfer_DEBUG_SEED"] = "/tmp/ShelferButtonHitTarget.txt"
        app.launch()

        let clearButton = app.buttons["Clear shelf"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 3))

        // Exercise transparent space beside the SF Symbol, while remaining
        // inside the visible circular Liquid Glass control.
        clearButton.coordinate(
            withNormalizedOffset: CGVector(dx: 0.86, dy: 0.5)
        ).click()

        XCTAssertTrue(clearButton.waitForNonExistence(timeout: 2))

        // Clearing swaps the filled shelf for a different empty-state view.
        // Verify that view uses the same complete circular interaction target.
        let emptyCloseButton = app.buttons["Close shelf"]
        XCTAssertTrue(emptyCloseButton.waitForExistence(timeout: 2))
        emptyCloseButton.coordinate(
            withNormalizedOffset: CGVector(dx: 0.14, dy: 0.5)
        ).click()
        XCTAssertTrue(emptyCloseButton.waitForNonExistence(timeout: 2))
    }

    @MainActor
    func testCloseButtonAcceptsClicksNearTheEdgeOfItsVisibleCircle() throws {
        let app = XCUIApplication()
        app.launchEnvironment["Shelfer_DEBUG_SEED"] = "/tmp/ShelferCloseHitTarget.txt"
        app.launch()

        let closeButton = app.buttons["Close shelf"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3))
        closeButton.coordinate(
            withNormalizedOffset: CGVector(dx: 0.14, dy: 0.5)
        ).click()

        XCTAssertTrue(closeButton.waitForNonExistence(timeout: 2))
    }

    @MainActor
    func testDirectNotchPathShelfKeepsTheWholeClearCircleInteractive() throws {
        let app = XCUIApplication()
        app.launchEnvironment["Shelfer_DEBUG_SEED"] = "/tmp/ShelferNotchPath.txt"
        app.launchEnvironment["Shelfer_DEBUG_SEED_PATHS_ONLY"] = "1"
        app.launchEnvironment["Shelfer_DEBUG_DIRECT_NOTCH"] = "1"
        app.launchEnvironment["Shelfer_DEBUG_RESTORE_NOTCH"] = "1"
        app.launch()

        let clearButton = app.buttons["Clear shelf"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 5))

        // Match the real Finder workflow: Shelfer is a nonactivating panel and
        // Finder still owns focus when the user reaches for this first click.
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        clearButton.coordinate(
            withNormalizedOffset: CGVector(dx: 0.86, dy: 0.5)
        ).click()

        XCTAssertTrue(clearButton.waitForNonExistence(timeout: 2))
    }

    @MainActor
    func testOptionShakePathShelfKeepsPathsAndFullButtonHitTargets() throws {
        let app = XCUIApplication()
        app.launchEnvironment["Shelfer_DEBUG_SEED"] = "/tmp/ShelferShakePath.txt"
        app.launchEnvironment["Shelfer_DEBUG_SEED_PATHS_ONLY"] = "1"
        app.launchEnvironment["Shelfer_DEBUG_SHAKE_SHELF"] = "1"
        app.launch()

        let detailsButton = app.buttons["Show shelf contents"]
        XCTAssertTrue(detailsButton.waitForExistence(timeout: 4))
        detailsButton.click()

        XCTAssertTrue(app.staticTexts["Path only"].waitForExistence(timeout: 2))
        let backButton = app.buttons["Back to shelf"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 2))
        backButton.click()

        let clearButton = app.buttons["Clear shelf"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 2))
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        clearButton.coordinate(
            withNormalizedOffset: CGVector(dx: 0.86, dy: 0.5)
        ).click()

        XCTAssertTrue(clearButton.waitForNonExistence(timeout: 2))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
