import XCTest

final class HighlightClipMediaNavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["SHOTMARKER_UI_TEST_CLIP_CONFIRMATION"] = "1"
        app.launchEnvironment["SHOTMARKER_UI_TEST_CLIP_MEDIA"] = "1"
        app.launch()
        XCTAssertTrue(app.navigationBars["审核集锦片段"].waitForExistence(timeout: 20))
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testConfirmingMergedClipLoadsNextClipAndThenAnotherSource() {
        app.buttons["片段 1–3"].tap()
        assertLoadedClip(title: "片段 1–3", start: 1)

        app.buttons["确认片段"].tap()
        assertLoadedClip(title: "片段 4", start: 691.1)
        assertPlaybackAdvances(after: 691.1)

        app.buttons["确认片段"].tap()
        assertLoadedClip(title: "片段 5", start: 21)
        assertPlaybackAdvances(after: 21)

        app.buttons["确认片段"].tap()
        XCTAssertTrue(app.navigationBars["审核集锦片段"].waitForExistence(timeout: 5))
        app.buttons["片段 4"].tap()
        assertLoadedClip(title: "片段 4", start: 691.1)
    }

    private func assertLoadedClip(title: String, start: Double) {
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
        let position = element(label: "当前位置")
        let positioned = NSPredicate { _, _ in
            abs(self.seconds(position) - start) < 0.11
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: positioned, object: nil)], timeout: 10), .completed,
            "\(title) 应定位到新片段起点，实际为 \(position.value ?? "无")")
        let frames = app.staticTexts["ClipMediaLoadedFrameCount"]
        XCTAssertTrue(frames.waitForExistence(timeout: 5))
        let extracted = NSPredicate(format: "label == '8'")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: extracted, object: frames)], timeout: 10), .completed)
        XCTAssertGreaterThan(element(label: "片段终点").frame.midX - element(label: "片段起点").frame.midX, 80,
            "时间轴必须围绕新片段展开，起止手柄不能挤在同一侧")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = title
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func assertPlaybackAdvances(after start: Double) {
        app.buttons["播放片段"].tap()
        let position = element(label: "当前位置")
        let advancing = NSPredicate { _, _ in self.seconds(position) > start + 0.2 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: advancing, object: nil)], timeout: 5), .completed)
        app.buttons["暂停"].tap()
    }

    private func element(label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func seconds(_ element: XCUIElement) -> Double {
        let text = element.value as? String ?? ""
        let components = text.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Double($0) }
        if text.contains("分"), components.count == 2 {
            return components[0] * 60 + components[1]
        }
        return components.first ?? .nan
    }
}
