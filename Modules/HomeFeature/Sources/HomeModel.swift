import Domain
import Observation

@MainActor @Observable
public final class HomeModel {
    public private(set) var accounts: [Account] = []
    public private(set) var isLoading = false

    private let repository: any BankingRepository

    public init(repository: any BankingRepository) {
        self.repository = repository
    }

    /// fetchAccounts 성공 시 accounts 교체. 실패 시 기존 accounts 유지.
    public func load() async {
        isLoading = true
        defer { isLoading = false }
        if let fetched = try? await repository.fetchAccounts() {
            accounts = fetched
        }
    }
}
