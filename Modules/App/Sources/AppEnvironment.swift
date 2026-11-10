import DataKit
import Domain
import os

private let log = Logger(subsystem: "com.example.paylab", category: "app")

enum AppEnvironment {
    static let failTransferArgument = "--fail-transfer"

    /// FakeServer(failTransfers: arguments.contains(failTransferArgument))
    /// → FakeBackend.makeSession(server:) → RemoteBankingRepository(session:)
    static func makeRepository(arguments: [String]) -> any BankingRepository {
        let server = FakeServer(failTransfers: arguments.contains(failTransferArgument))
        log.info("launch failTransfers=\(server.failTransfers, privacy: .public)")
        return RemoteBankingRepository(session: FakeBackend.makeSession(server: server))
    }
}
