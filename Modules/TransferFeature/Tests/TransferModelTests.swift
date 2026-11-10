import Domain
import Testing
import TransferFeature

@MainActor
struct TransferModelTests {
    let account = Account(id: "acc-1", name: "테스트 통장", maskedNumber: "1", balance: 50_000)
    let recipient = Recipient(id: "rcp-1", name: "김하늘", bankName: "국민은행", maskedNumber: "1")
    let receipt = TransferReceipt(transferID: "tr-1", amount: 1_000, balanceAfter: 49_000)

    func makeModel(_ repository: StubBankingRepository = StubBankingRepository()) -> TransferModel {
        TransferModel(fromAccount: account, repository: repository)
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

    @Test func proceedToConfirmAppendsConfirm() {
        let model = makeModel()
        moveToConfirm(model)
        #expect(model.path == [.amount, .confirm])
    }

    @Test func submitSuccess() async {
        let repository = StubBankingRepository(transfer: .success(receipt))
        let model = makeModel(repository)
        moveToConfirm(model)
        await model.submit()
        #expect(model.outcome == .success(receipt))
        #expect(model.path.last == .result)
        #expect(repository.transferRequests == [TransferRequest(fromAccountID: "acc-1", recipientID: "rcp-1", amount: 1_000)])
    }

    @Test func submitFailure() async {
        let model = makeModel()
        moveToConfirm(model)
        await model.submit()
        #expect(model.outcome == .failure)
        #expect(model.path.last == .result)
    }

    @Test func submitWithoutRecipientDoesNothing() async {
        let repository = StubBankingRepository(transfer: .success(receipt))
        let model = makeModel(repository)
        model.amountText = "1000"
        await model.submit()
        #expect(repository.transferRequests.isEmpty)
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
