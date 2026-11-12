import Domain
import Synchronization
import Testing

/// fetchAccounts·fetchTransactions 결과를 테스트가 정한다. 나머지 메서드는 HomeFeature 모델이 부르지 않는다.
final class StubBankingRepository: BankingRepository {
    private let accounts: Mutex<Result<[Account], BankingError>>
    private let transactions: Mutex<Result<[Transaction], BankingError>>

    init(accounts: Result<[Account], BankingError>,
         transactions: Result<[Transaction], BankingError> = .success([])) {
        self.accounts = Mutex(accounts)
        self.transactions = Mutex(transactions)
    }

    func setAccounts(_ result: Result<[Account], BankingError>) {
        accounts.withLock { $0 = result }
    }

    func setTransactions(_ result: Result<[Transaction], BankingError>) {
        transactions.withLock { $0 = result }
    }

    func fetchAccounts() async throws -> [Account] {
        try accounts.withLock { $0 }.get()
    }

    func fetchRecipients() async throws -> [Recipient] {
        Issue.record("HomeModel은 fetchRecipients를 부르지 않아야 한다")
        throw BankingError.server(statusCode: 0)
    }

    func fetchTransactions(accountID: String) async throws -> [Transaction] {
        try transactions.withLock { $0 }.get()
    }

    func transfer(_ request: TransferRequest, idempotencyKey: String) async throws -> TransferReceipt {
        Issue.record("HomeModel은 transfer를 부르지 않아야 한다")
        throw BankingError.server(statusCode: 0)
    }

    func findTransfer(idempotencyKey: String) async throws -> TransferReceipt? {
        Issue.record("HomeModel은 findTransfer를 부르지 않아야 한다")
        throw BankingError.server(statusCode: 0)
    }
}
