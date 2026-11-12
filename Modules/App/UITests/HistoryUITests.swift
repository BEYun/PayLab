import XCTest

/// 홈 계좌 행 → 거래 내역 → 스크롤. 거래 수천 건을 그려도 앱이 살아 있어야 한다.
final class HistoryUITests: XCTestCase {
    @MainActor
    func testHistoryOpensAndScrolls() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["1,250,000원"].waitForExistence(timeout: 5))
        app.staticTexts["PayLab 통장"].tap()
        XCTAssertTrue(app.navigationBars["거래 내역"].waitForExistence(timeout: 5))
        // 가장 최근 거래: 11월 1일 09:00 편의점 (가짜 서버 기준 시각)
        XCTAssertTrue(app.staticTexts["11월 1일 일요일"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["편의점"].firstMatch.exists)
        for _ in 0..<3 {
            app.swipeUp()
        }
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.navigationBars["거래 내역"].exists)
    }
}
