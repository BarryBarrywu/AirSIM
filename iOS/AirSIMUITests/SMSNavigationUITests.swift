import XCTest

final class SMSNavigationUITests: XCTestCase {
    @MainActor
    func testContactsSearchAndRecentsTitleSurviveTabSwitches() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["sms-compose"].waitForExistence(timeout: 10))
        for _ in 0..<2 {
            app.tabBars.buttons["联系人"].tap()
            XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(app.searchFields.firstMatch.isHittable)
            app.tabBars.buttons["最近"].tap()
            XCTAssertTrue(app.navigationBars["最近通话"].waitForExistence(timeout: 5))
            app.tabBars.buttons["设置"].tap()
            app.tabBars.buttons["短信"].tap()
            XCTAssertTrue(app.buttons["sms-compose"].waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testConversationReopensAfterSwitchingTabsAndReturning() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["AIRSIM_UI_FIXTURE"] = "sms-navigation"
        app.launch()
        defer { app.terminate() }
        let compose = app.buttons["sms-compose"]
        XCTAssertTrue(compose.waitForExistence(timeout: 10), "real toolbar must expose its compose action")
        for iteration in 0..<3 {
            app.tabBars.buttons["设置"].tap()
            app.tabBars.buttons["短信"].tap()
            XCTAssertTrue(compose.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["sms-list-actions"].exists)
            if iteration == 0 {
                compose.tap()
                let cancel = app.buttons["取消"]
                XCTAssertTrue(cancel.waitForExistence(timeout: 5))
                cancel.tap()
                XCTAssertTrue(compose.waitForExistence(timeout: 5))
            }
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "sms-navigation-fixture")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
            let navigation = app.navigationBars["sms-navigation-fixture"]
            XCTAssertTrue(navigation.waitForExistence(timeout: 5))
            XCTAssertFalse(app.tabBars.buttons["短信"].isHittable, "conversation must cover the root tabs")
            navigation.buttons.firstMatch.tap()
            XCTAssertTrue(compose.waitForExistence(timeout: 5))
            XCTAssertTrue(app.tabBars.buttons["短信"].isHittable)
        }
    }
}
