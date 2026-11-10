import Domain
import Observation
import os

private let log = Logger(subsystem: "com.example.paylab", category: "transfer")

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
        log.debug("recipients start")
        do {
            recipients = try await repository.fetchRecipients()
            log.info("recipients ok count=\(self.recipients.count, privacy: .public)")
        } catch {
            log.error("recipients failed: \(String(describing: error), privacy: .public)")
        }
    }

    public func select(_ recipient: Recipient) {
        log.info("select recipient=\(recipient.id, privacy: .public)")
        selectedRecipient = recipient
        path = [.amount]
    }

    public func proceedToConfirm() {
        guard canProceed else {
            log.error("confirm blocked amountText=\"\(self.amountText, privacy: .public)\" amount=\(self.amount.map(String.init) ?? "nil", privacy: .public) balance=\(self.fromAccount.balance, privacy: .public)")
            return
        }
        log.info("confirm amount=\(self.amount ?? 0, privacy: .public)")
        path.append(.confirm)
    }

    /// 성공 → .success, 어떤 오류든 → .failure. 그다음 .result로 이동.
    public func submit() async {
        guard let recipient = selectedRecipient, let amount else {
            log.error("submit ignored recipient=\(self.selectedRecipient?.id ?? "nil", privacy: .public) amount=\(self.amount.map(String.init) ?? "nil", privacy: .public)")
            return
        }
        let request = TransferRequest(fromAccountID: fromAccount.id, recipientID: recipient.id, amount: amount)
        log.info("submit start from=\(request.fromAccountID, privacy: .public) to=\(request.recipientID, privacy: .public) amount=\(amount, privacy: .public)")
        do {
            let receipt = try await repository.transfer(request)
            log.info("submit ok transferID=\(receipt.transferID, privacy: .public) balanceAfter=\(receipt.balanceAfter, privacy: .public)")
            outcome = .success(receipt)
        } catch {
            log.error("submit failed: \(String(describing: error), privacy: .public)")
            outcome = .failure
        }
        path.append(.result)
    }
}
