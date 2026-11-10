import Domain
import Observation

@MainActor @Observable
public final class TransferModel {
    public enum Step: Hashable { case amount, confirm, result }
    public enum Outcome: Equatable { case success(TransferReceipt), failure }

    public let fromAccount: Account
    public private(set) var recipients: [Recipient] = []
    public private(set) var selectedRecipient: Recipient?
    public var amountText = ""
    public var path: [Step] = []
    public private(set) var outcome: Outcome?

    private let repository: any BankingRepository

    public init(fromAccount: Account, repository: any BankingRepository) {
        self.fromAccount = fromAccount
        self.repository = repository
    }

    /// amountText에서 숫자만 남겨 Int로. 비었거나 Int 범위를 넘으면 nil.
    public var amount: Int? {
        Int(amountText.filter(\.isASCII).filter(\.isNumber))
    }

    /// amount가 있고 TransferRule.isValidAmount(amount, balance: fromAccount.balance)
    public var canProceed: Bool {
        guard let amount else { return false }
        return TransferRule.isValidAmount(amount, balance: fromAccount.balance)
    }

    /// 실패 시 빈 목록 유지.
    public func loadRecipients() async {
        if let fetched = try? await repository.fetchRecipients() {
            recipients = fetched
        }
    }

    public func select(_ recipient: Recipient) {
        selectedRecipient = recipient
        path = [.amount]
    }

    public func proceedToConfirm() {
        guard canProceed else { return }
        path.append(.confirm)
    }

    /// 성공 → .success, 어떤 오류든 → .failure. 그다음 .result로 이동.
    public func submit() async {
        guard let recipient = selectedRecipient, let amount else { return }
        let request = TransferRequest(fromAccountID: fromAccount.id, recipientID: recipient.id, amount: amount)
        do {
            outcome = .success(try await repository.transfer(request))
        } catch {
            outcome = .failure
        }
        path.append(.result)
    }
}
