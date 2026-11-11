import Domain
import Synchronization
import Testing

/// 받는 사람·송금 결과를 테스트가 정하고, transfer가 받은 요청과 키를 기록한다.
final class StubBankingRepository: BankingRepository {
    struct TransferCall: Equatable {
        let request: TransferRequest
        let idempotencyKey: String
    }

    private let recipients: Result<[Recipient], BankingError>
    private let transferResult: Result<TransferReceipt, BankingError>
    private let calls = Mutex<[TransferCall]>([])

    init(recipients: Result<[Recipient], BankingError> = .success([]),
         transfer: Result<TransferReceipt, BankingError> = .failure(.server(statusCode: 500))) {
        self.recipients = recipients
        self.transferResult = transfer
    }

    var transferCalls: [TransferCall] { calls.withLock { $0 } }

    func fetchAccounts() async throws -> [Account] {
        Issue.record("TransferModel은 fetchAccounts를 부르지 않아야 한다")
        throw BankingError.server(statusCode: 0)
    }

    func fetchRecipients() async throws -> [Recipient] {
        try recipients.get()
    }

    func transfer(_ request: TransferRequest, idempotencyKey: String) async throws -> TransferReceipt {
        calls.withLock { $0.append(TransferCall(request: request, idempotencyKey: idempotencyKey)) }
        return try transferResult.get()
    }

    func findTransfer(idempotencyKey: String) async throws -> TransferReceipt? {
        Issue.record("아직 findTransfer를 부르지 않아야 한다")
        throw BankingError.server(statusCode: 0)
    }
}
