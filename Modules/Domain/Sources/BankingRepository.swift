import Foundation

public enum BankingError: Error, Equatable, Sendable {
    case server(statusCode: Int)
}

public protocol BankingRepository: Sendable {
    func fetchAccounts() async throws -> [Account]
    func fetchRecipients() async throws -> [Recipient]
    /// 같은 idempotencyKey로 다시 보내면 서버는 다시 처리하지 않고 첫 영수증을 돌려준다.
    /// 비 2xx → BankingError.server. 2xx인데 본문을 읽지 못하면 DecodingError (서버는 처리했다).
    func transfer(_ request: TransferRequest, idempotencyKey: String) async throws -> TransferReceipt
    /// 키로 처리된 송금을 찾는다. 서버에 없으면(404) nil.
    func findTransfer(idempotencyKey: String) async throws -> TransferReceipt?
}
