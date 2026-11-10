import Domain
import Synchronization
import Testing

/// fetchAccounts 결과를 테스트가 정한다. 나머지 메서드는 HomeModel이 부르지 않는다.
final class StubBankingRepository: BankingRepository {
    private let accounts: Mutex<Result<[Account], BankingError>>

    init(accounts: Result<[Account], BankingError>) {
        self.accounts = Mutex(accounts)
    }

    func setAccounts(_ result: Result<[Account], BankingError>) {
        accounts.withLock { $0 = result }
    }

    func fetchAccounts() async throws -> [Account] {
        try accounts.withLock { $0 }.get()
    }

    func fetchRecipients() async throws -> [Recipient] {
        Issue.record("HomeModel은 fetchRecipients를 부르지 않아야 한다")
        throw BankingError.server(statusCode: 0)
    }

    func transfer(_ request: TransferRequest) async throws -> TransferReceipt {
        Issue.record("HomeModel은 transfer를 부르지 않아야 한다")
        throw BankingError.server(statusCode: 0)
    }
}
