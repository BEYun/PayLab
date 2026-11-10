import Foundation

public enum BankingError: Error, Equatable, Sendable {
    case server(statusCode: Int)
}

public protocol BankingRepository: Sendable {
    func fetchAccounts() async throws -> [Account]
    func fetchRecipients() async throws -> [Recipient]
    func transfer(_ request: TransferRequest) async throws -> TransferReceipt
}
