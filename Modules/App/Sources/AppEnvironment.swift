import DataKit
import Domain

enum AppEnvironment {
    static let failTransferArgument = "--fail-transfer"

    /// FakeServer(failTransfers: arguments.contains(failTransferArgument))
    /// → FakeBackend.makeSession(server:) → RemoteBankingRepository(session:)
    static func makeRepository(arguments: [String]) -> any BankingRepository {
        let server = FakeServer(failTransfers: arguments.contains(failTransferArgument))
        return RemoteBankingRepository(session: FakeBackend.makeSession(server: server))
    }
}
