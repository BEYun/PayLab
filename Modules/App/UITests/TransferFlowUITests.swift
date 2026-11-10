import XCTest

/// 앱을 띄워 송금 흐름을 끝까지 누른다. 앱을 실행할 때마다 가짜 서버 상태는 초기화된다.
final class TransferFlowUITests: XCTestCase {
    @MainActor
    func testTransferSuccessUpdatesHomeBalance() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        sendOneThousandWon(app)
        XCTAssertTrue(app.staticTexts["보냈어요"].waitForExistence(timeout: 5))
        app.buttons["확인"].tap()
        XCTAssertTrue(app.staticTexts["1,249,000원"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testTransferFailureKeepsHomeBalance() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--fail-transfer"]
        app.launch()
        sendOneThousandWon(app)
        XCTAssertTrue(app.staticTexts["송금 실패"].waitForExistence(timeout: 5))
        app.buttons["확인"].tap()
        // 홈 재로드(300ms 지연)가 끝날 때까지 기다려야 깎인 잔액이 드러난다. 2초 안에 나타나면 실패.
        XCTAssertFalse(app.staticTexts["1,249,000원"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["1,250,000원"].exists)
    }

    /// 홈 첫 계좌(PayLab 통장, 1,250,000원)에서 김하늘에게 1,000원 송금을 "보내기"까지 누른다.
    @MainActor
    private func sendOneThousandWon(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["1,250,000원"].waitForExistence(timeout: 5))
        app.buttons["송금"].firstMatch.tap()
        let recipient = app.staticTexts["김하늘"]
        XCTAssertTrue(recipient.waitForExistence(timeout: 5))
        recipient.tap()
        let amount = app.textFields["금액"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText("1000")
        app.buttons["다음"].tap()
        let send = app.buttons["보내기"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
    }
}
