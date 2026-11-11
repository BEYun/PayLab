import Domain
import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.example.paylab", category: "transfer")

@MainActor @Observable
public final class TransferModel {
    public enum Step: Hashable { case amount, confirm, result }
    public enum Outcome: Equatable, Sendable {
        case success(TransferReceipt?)  // nil: 서버는 처리했지만 영수증을 읽지 못함
        case failure(FailureReason)
        case unknown                     // 재시도와 자동 조회 뒤에도 서버가 처리했는지 모름
    }

    public enum FailureReason: Equatable, Sendable {
        case rejected(statusCode: Int)  // 4xx
        case notSent                    // 자동 조회 결과 404

        public var message: String {
            switch self {
            case .rejected(statusCode: 400): "금액을 확인해 주세요"
            case .rejected(statusCode: 404): "계좌나 받는 사람을 찾을 수 없어요"
            case .rejected: "요청을 처리할 수 없어요"
            case .notSent: "보내지 않았어요"
            }
        }
    }

    public let fromAccount: Account
    public private(set) var recipients: [Recipient] = []
    public private(set) var selectedRecipient: Recipient?
    public var amountText = ""
    public var path: [Step] = []
    public private(set) var outcome: Outcome?
    /// 송금 한 건의 송금 키. proceedToConfirm을 통과할 때마다 새로 만든다.
    public private(set) var idempotencyKey: String?
    /// 재시도와 자동 조회가 모두 끝날 때까지 true. 화면은 이 동안 로딩을 보여 준다.
    public private(set) var isSubmitting = false

    private let repository: any BankingRepository
    private let retryDelays: [Duration]

    /// retryDelays: 처리 여부를 모르는 실패 뒤 같은 키로 다시 보내기 전 대기. 개수 = 재시도 횟수.
    public init(fromAccount: Account, repository: any BankingRepository,
                retryDelays: [Duration] = [.milliseconds(500), .seconds(1)]) {
        self.fromAccount = fromAccount
        self.repository = repository
        self.retryDelays = retryDelays
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

    /// 송금이 시작된 뒤(송금 중·결과 있음)에는 무시한다. 한 송금의 키는 처음부터 끝까지 하나다.
    public func proceedToConfirm() {
        guard !isSubmitting, outcome == nil else {
            log.error("confirm ignored \(self.isSubmitting ? "inFlight" : "done", privacy: .public) key=\(self.idempotencyKey ?? "nil", privacy: .public)")
            return
        }
        guard canProceed else {
            log.error("confirm blocked amountText=\"\(self.amountText, privacy: .public)\" amount=\(self.amount.map(String.init) ?? "nil", privacy: .public) balance=\(self.fromAccount.balance, privacy: .public)")
            return
        }
        idempotencyKey = UUID().uuidString
        log.info("confirm amount=\(self.amount ?? 0, privacy: .public)")
        path.append(.confirm)
    }

    /// 송금 중이거나 결과가 이미 있으면 무시한다. 결과는 .result로 이동해 보여 준다.
    /// - 2xx: 보냈어요 (본문을 못 읽어도 서버는 처리했다)
    /// - 4xx: 송금 실패. 재시도하지 않는다.
    /// - 그 밖 (5xx, 전송 오류 등): 처리 여부를 모른다. 같은 키로 retryDelays만큼 다시 보내고,
    ///   그래도 모르면 키로 1번 조회한다 (찾음 → 보냈어요, 404 → 보내지 않았어요, 조회 실패 → 결과 모름).
    public func submit() async {
        guard !isSubmitting, outcome == nil else {
            log.error("submit ignored \(self.isSubmitting ? "inFlight" : "done", privacy: .public) key=\(self.idempotencyKey ?? "nil", privacy: .public)")
            return
        }
        guard let recipient = selectedRecipient, let amount, let key = idempotencyKey else {
            log.error("submit ignored recipient=\(self.selectedRecipient?.id ?? "nil", privacy: .public) amount=\(self.amount.map(String.init) ?? "nil", privacy: .public) key=\(self.idempotencyKey ?? "nil", privacy: .public)")
            return
        }
        isSubmitting = true
        let request = TransferRequest(fromAccountID: fromAccount.id, recipientID: recipient.id, amount: amount)
        log.info("submit start key=\(key, privacy: .public) from=\(request.fromAccountID, privacy: .public) to=\(request.recipientID, privacy: .public) amount=\(amount, privacy: .public)")
        outcome = await send(request, key: key)
        isSubmitting = false
        path.append(.result)
    }

    private func send(_ request: TransferRequest, key: String) async -> Outcome {
        var attempt = 1
        while true {
            do {
                let receipt = try await repository.transfer(request, idempotencyKey: key)
                log.info("submit ok transferID=\(receipt.transferID, privacy: .public) balanceAfter=\(receipt.balanceAfter, privacy: .public)")
                return .success(receipt)
            } catch is DecodingError {
                log.error("submit ok unreadable key=\(key, privacy: .public)")
                return .success(nil)
            } catch BankingError.server(let statusCode) where (400..<500).contains(statusCode) {
                log.error("submit rejected status=\(statusCode, privacy: .public)")
                return .failure(.rejected(statusCode: statusCode))
            } catch {
                guard attempt <= retryDelays.count else {
                    log.error("submit check after attempts=\(attempt, privacy: .public): \(String(describing: error), privacy: .public)")
                    return await check(key: key)
                }
                let delay = retryDelays[attempt - 1]
                log.error("submit retry attempt=\(attempt, privacy: .public) after=\(Int(delay / .milliseconds(1)), privacy: .public)ms: \(String(describing: error), privacy: .public)")
                try? await Task.sleep(for: delay)
                attempt += 1
            }
        }
    }

    /// 키로 조회만 한다. 송금을 새로 만들지 않고, 재시도하지 않는다.
    private func check(key: String) async -> Outcome {
        log.debug("submit check start key=\(key, privacy: .public)")
        do {
            guard let receipt = try await repository.findTransfer(idempotencyKey: key) else {
                log.error("submit check notFound key=\(key, privacy: .public)")
                return .failure(.notSent)
            }
            log.info("submit check ok transferID=\(receipt.transferID, privacy: .public) balanceAfter=\(receipt.balanceAfter, privacy: .public)")
            return .success(receipt)
        } catch is DecodingError {
            log.error("submit check ok unreadable key=\(key, privacy: .public)")
            return .success(nil)
        } catch {
            log.error("submit unknown key=\(key, privacy: .public): \(String(describing: error), privacy: .public)")
            return .unknown
        }
    }
}
