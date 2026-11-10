import Domain
import Synchronization
import Testing

/// 받는 사람·송금 결과를 테스트가 정하고, transfer가 받은 요청을 기록한다.
final class StubBankingRepository: BankingRepository {
    private let recipients: Result<[Recipient], BankingError>
    private let transferResult: Result<TransferReceipt, BankingError>
    private let requests = Mutex<[TransferRequest]>([])

    init(recipients: Result<[Recipient], BankingError> = .success([]),
         transfer: Result<TransferReceipt, BankingError> = .failure(.server(statusCode: 500))) {
        self.recipients = recipients
        self.transferResult = transfer
    }

    var transferRequests: [TransferRequest] { requests.withLock { $0 } }

    func fetchAccounts() async throws -> [Account] {
        Issue.record("TransferModel은 fetchAccounts를 부르지 않아야 한다")
        throw BankingError.server(statusCode: 0)
    }

    func fetchRecipients() async throws -> [Recipient] {
        try recipients.get()
    }

    func transfer(_ request: TransferRequest) async throws -> TransferReceipt {
        requests.withLock { $0.append(request) }
        return try transferResult.get()
    }
}
