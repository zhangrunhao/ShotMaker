import XCTest

final class EditableHighlightTaskUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testQueuedAndRunningWithOldOutputOnlyExposeStop() {
        for state in ["queued", "running"] {
            let app = launch(state)
            XCTAssertTrue(app.buttons["停止"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["highlight-task-edit"].exists)
            XCTAssertFalse(app.buttons["播放"].exists)
            XCTAssertFalse(app.buttons["保存相册"].exists)
            XCTAssertFalse(app.buttons["删除"].exists)
            XCTAssertFalse(app.buttons["重新生成"].exists)
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "唯一可用操作：停止")).firstMatch.exists)
            app.terminate()
        }
    }

    func testStopKeepsTaskAndAllowsEditOrRegeneration() {
        let app = launch("running")
        let stop = app.buttons["停止"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.tap()
        XCTAssertTrue(app.buttons["highlight-task-edit"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["重新生成"].exists)
        XCTAssertTrue(app.buttons["播放"].exists)
        XCTAssertFalse(app.buttons["停止"].exists)
    }

    func testCompletedTaskOpensConfigurationAndDeletionRequiresConfirmation() {
        let app = launch("completed")
        let edit = app.buttons["highlight-task-edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        XCTAssertTrue(app.navigationBars["编辑集锦任务"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["创建任务后训练记录不可更换"].exists)
        app.buttons["返回首页"].tap()
        XCTAssertTrue(app.buttons["删除"].waitForExistence(timeout: 10))
        app.buttons["删除"].tap()
        XCTAssertTrue(app.alerts["删除任务？"].waitForExistence(timeout: 5))
        app.alerts.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["highlight-task-edit"].exists)
    }

    func testModifiedTaskAtLargestTypeShowsStaleOutputAndRequiresReview() {
        let app = launch("modified", largeType: true)
        XCTAssertTrue(app.buttons["highlight-task-edit"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["highlight-task-edit"].label.contains("当前成片不包含最新修改"))
        XCTAssertFalse(app.buttons["重新生成"].exists)
        XCTAssertTrue(app.buttons["播放"].isHittable)
        XCTAssertTrue(app.buttons["删除"].isHittable)
    }

    private func launch(_ state: String, largeType: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHOTMARKER_UI_TEST_TASK_STATE"] = state
        if largeType { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        return app
    }
}
