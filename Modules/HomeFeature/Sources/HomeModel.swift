import Domain
import Observation
import os

private let log = Logger(subsystem: "com.example.paylab", category: "home")

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
        log.debug("load start")
        do {
            accounts = try await repository.fetchAccounts()
            log.info("load ok accounts=\(self.accounts.count, privacy: .public)")
        } catch {
            log.error("load failed keep=\(self.accounts.count, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
