import Domain
import Testing
import TransferFeature

private let savedReceipt = TransferReceipt(transferID: "tr-1", amount: 1_000, balanceAfter: 49_000)

@MainActor
struct TransferModelTests {
    let account = Account(id: "acc-1", name: "테스트 통장", maskedNumber: "1", balance: 50_000)
    let recipient = Recipient(id: "rcp-1", name: "김하늘", bankName: "국민은행", maskedNumber: "1")
    let receipt = savedReceipt

    /// 재시도 대기 0
    func makeModel(_ repository: StubBankingRepository = StubBankingRepository()) -> TransferModel {
        TransferModel(fromAccount: account, repository: repository, retryDelays: [.zero, .zero])
    }

    /// 확인 화면까지 진행: 받는 사람 선택 → 금액 입력 → 다음
    func moveToConfirm(_ model: TransferModel, amountText: String = "1000") {
        model.select(recipient)
        model.amountText = amountText
        model.proceedToConfirm()
    }

    @Test(arguments: zip(["1,000원", "", "abc", "99999999999999999999", "１０００", "-500"],
                         [1_000, nil, nil, nil, nil, 500] as [Int?]))
    func amountParsing(text: String, expected: Int?) {
        let model = makeModel()
        model.amountText = text
        #expect(model.amount == expected)
    }

    @Test(arguments: zip(["", "0", "50000", "50001"], [false, false, true, false]))
    func canProceed(text: String, expected: Bool) {
        let model = makeModel()
        model.amountText = text
        #expect(model.canProceed == expected)
    }

    @Test func selectSetsRecipientAndMovesToAmount() {
        let model = makeModel()
        model.select(recipient)
        #expect(model.selectedRecipient == recipient)
        #expect(model.path == [.amount])
    }

    @Test func proceedToConfirmIgnoredWhenAmountInvalid() {
        let model = makeModel()
        moveToConfirm(model, amountText: "50001")
        #expect(model.path == [.amount])
    }

    @Test func proceedToConfirmMakesNewKey() throws {
        let model = makeModel()
        moveToConfirm(model)
        let first = try #require(model.idempotencyKey)
        model.path.removeLast()  // 확인 화면에서 뒤로
        model.proceedToConfirm()
        let second = try #require(model.idempotencyKey)
        #expect(first != second)
    }

    @Test func proceedToConfirmAppendsConfirm() {
        let model = makeModel()
        moveToConfirm(model)
        #expect(model.path == [.amount, .confirm])
    }

    @Test func submitSuccess() async throws {
        let repository = StubBankingRepository(transfers: [.receipt(receipt)])
        let model = makeModel(repository)
        moveToConfirm(model)
        await model.submit()
        #expect(model.outcome == .success(receipt))
        #expect(model.path.last == .result)
        let key = try #require(model.idempotencyKey)
        #expect(repository.transferCalls == [.init(
            request: TransferRequest(fromAccountID: "acc-1", recipientID: "rcp-1", amount: 1_000), idempotencyKey: key)])
    }

    @Test func unknownErrorThreeTimesThenNotFoundIsNotSent() async {
        let repository = StubBankingRepository()  // 송금 500 반복, 조회 404
        let model = makeModel(repository)
        moveToConfirm(model)
        await model.submit()
        #expect(model.outcome == .failure(.notSent))
        #expect(repository.transferCalls.count == 3)
        #expect(repository.findKeys.count == 1)
        #expect(model.path.last == .result)
        #expect(!model.isSubmitting)
    }

    @Test func checkFailureEndsUnknown() async {
        let repository = StubBankingRepository(finds: [.server(500)])
        let model = makeModel(repository)
        moveToConfirm(model)
        await model.submit()
        #expect(model.outcome == .unknown)
        #expect(repository.transferCalls.count == 3)
        #expect(repository.findKeys.count == 1)  // 조회는 재시도하지 않는다
        #expect(model.path.last == .result)
        #expect(!model.isSubmitting)
    }

    /// 재현(사용자 피드백): 재시도 뒤에도 모르면 앱이 키로 자동 조회해 결과까지 보여 줘야 한다.
    @Test func retriesExhaustedThenAutoCheckFindsTransfer() async throws {
        let repository = StubBankingRepository(finds: [.receipt(receipt)])  // 송금 500 반복
        let model = makeModel(repository)
        moveToConfirm(model)
        await model.submit()
        #expect(model.outcome == .success(receipt))
        #expect(repository.findKeys == [try #require(model.idempotencyKey)])
    }

    @Test func unknownErrorRetriesWithSameKeyThenSucceeds() async throws {
        let repository = StubBankingRepository(transfers: [.server(500), .connectionLost, .receipt(receipt)])
        let model = makeModel(repository)
        moveToConfirm(model)
        await model.submit()
        #expect(model.outcome == .success(receipt))
        let key = try #require(model.idempotencyKey)
        #expect(repository.transferCalls.count == 3)
        #expect(repository.transferCalls.allSatisfy { $0.idempotencyKey == key })
        #expect(repository.findKeys.isEmpty)
    }

    @Test func otherErrorIsTreatedAsUnknown() async {
        let repository = StubBankingRepository(transfers: [.cancelled])
        let model = makeModel(repository)
        moveToConfirm(model)
        await model.submit()
        #expect(model.outcome == .failure(.notSent))  // 재시도 3번 뒤 조회 404
        #expect(repository.transferCalls.count == 3)
        #expect(repository.findKeys.count == 1)
    }

    @Test(arguments: [400, 404, 422])
    func clientErrorIsRejectedWithoutRetry(statusCode: Int) async {
        let repository = StubBankingRepository(transfers: [.server(statusCode)])
        let model = makeModel(repository)
        moveToConfirm(model)
        await model.submit()
        #expect(model.outcome == .failure(.rejected(statusCode: statusCode)))
        #expect(repository.transferCalls.count == 1)
        #expect(repository.findKeys.isEmpty)
        #expect(model.path.last == .result)
        #expect(!model.isSubmitting)
    }

    @Test func submitAfterResultIsIgnored() async {
        let repository = StubBankingRepository(transfers: [.receipt(receipt)])
        let model = makeModel(repository)
        moveToConfirm(model)
        await model.submit()
        await model.submit()
        #expect(repository.transferCalls.count == 1)
        #expect(model.path == [.amount, .confirm, .result])
    }

    @Test(arguments: [
        (.receipt(savedReceipt), .success(savedReceipt)),
        (.notFound, .failure(.notSent)),
        (.unreadable, .success(nil)),
        (.server(500), .unknown),
        (.connectionLost, .unknown),
    ] as [(StubBankingRepository.Reply, TransferModel.Outcome)])
    func autoCheckOutcome(reply: StubBankingRepository.Reply, expected: TransferModel.Outcome) async throws {
        let repository = StubBankingRepository(finds: [reply])  // 송금 500 반복 → 자동 조회
        let model = makeModel(repository)
        moveToConfirm(model)
        await model.submit()
        #expect(model.outcome == expected)
        #expect(repository.findKeys == [try #require(model.idempotencyKey)])
        #expect(repository.transferCalls.count == 3)  // 조회는 송금을 새로 보내지 않는다
        #expect(!model.isSubmitting)
    }

    /// 재현(최종 리뷰): 송금 중 확인 화면이 pop되고 다시 "다음"을 누르면 키가 바뀌었다.
    /// 송금이 시작되면 키는 고정이고, 자동 조회도 보낸 키로 한다.
    @Test(.timeLimit(.minutes(1))) func keyStaysFixedOnceSubmitStarts() async throws {  // 회귀 시 waitUntilHeld가 멈추지 않게
        let repository = StubBankingRepository(finds: [.receipt(receipt)], holdFirstTransfer: true)
        let model = makeModel(repository)
        moveToConfirm(model)
        let first = Task { await model.submit() }
        await repository.waitUntilHeld()
        model.path.removeLast()   // 송금 중 확인 화면이 pop됨
        model.proceedToConfirm()  // 금액 화면에서 "다음"
        repository.release()
        await first.value
        let sentKey = try #require(repository.transferCalls.first?.idempotencyKey)
        #expect(model.idempotencyKey == sentKey)
        #expect(repository.findKeys == [sentKey])
        #expect(model.outcome == .success(receipt))
    }

    @Test(arguments: [
        (.rejected(statusCode: 400), "금액을 확인해 주세요"),
        (.rejected(statusCode: 404), "계좌나 받는 사람을 찾을 수 없어요"),
        (.rejected(statusCode: 422), "요청을 처리할 수 없어요"),
        (.notSent, "보내지 않았어요"),
    ] as [(TransferModel.FailureReason, String)])
    func failureReasonMessage(reason: TransferModel.FailureReason, expected: String) {
        #expect(reason.message == expected)
    }

    /// 재현: 송금 중에 "보내기"를 다시 누르면 요청이 두 번 갔다.
    @Test(.timeLimit(.minutes(1))) func doubleSubmitSendsOnce() async {  // 회귀 시 waitUntilHeld가 멈추지 않게
        let repository = StubBankingRepository(transfers: [.receipt(receipt)], holdFirstTransfer: true)
        let model = makeModel(repository)
        moveToConfirm(model)
        let first = Task { await model.submit() }
        await repository.waitUntilHeld()
        await model.submit()  // 송금 중 두 번째 탭
        #expect(model.isSubmitting)
        repository.release()
        await first.value
        #expect(repository.transferCalls.count == 1)
        #expect(model.outcome == .success(receipt))
    }

    /// 재현: 서버는 처리했는데(200) 본문을 못 읽으면 "송금 실패"로 보였다.
    @Test func decodingErrorMeansSent() async {
        let repository = StubBankingRepository(transfers: [.unreadable])
        let model = makeModel(repository)
        moveToConfirm(model)
        await model.submit()
        #expect(model.outcome == .success(nil))
        #expect(repository.transferCalls.count == 1)
    }

    @Test func submitWithoutRecipientDoesNothing() async {
        let repository = StubBankingRepository(transfers: [.receipt(receipt)])
        let model = makeModel(repository)
        model.amountText = "1000"
        await model.submit()
        #expect(repository.transferCalls.isEmpty)
        #expect(model.outcome == nil)
        #expect(model.path == [])
    }

    @Test func loadRecipientsSuccess() async {
        let model = makeModel(StubBankingRepository(recipients: .success([recipient])))
        await model.loadRecipients()
        #expect(model.recipients == [recipient])
    }

    @Test func loadRecipientsFailureKeepsEmpty() async {
        let model = makeModel(StubBankingRepository(recipients: .failure(.server(statusCode: 500))))
        await model.loadRecipients()
        #expect(model.recipients.isEmpty)
    }
}
