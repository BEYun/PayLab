import DataKit
import Domain
import os

private let log = Logger(subsystem: "com.example.paylab", category: "app")

enum AppEnvironment {
    static let failTransferArgument = "--fail-transfer"

    /// 송금 처리 뒤 응답을 망가뜨리는 실행 인자. 둘 이상이면 앞쪽이 이긴다.
    static let transferFaultArguments: [(argument: String, fault: TransferFault)] = [
        ("--drop-transfer-response-once", .dropResponseOnce),
        ("--drop-transfer-response", .dropResponseAlways),
        ("--garble-transfer-response", .garbleResponse),
    ]

    static func transferFault(arguments: [String]) -> TransferFault? {
        transferFaultArguments.first { arguments.contains($0.argument) }?.fault
    }

    /// FakeServer(failTransfers:transferFault:) → FakeBackend.makeSession(server:) → RemoteBankingRepository(session:)
    static func makeRepository(arguments: [String]) -> any BankingRepository {
        let server = FakeServer(failTransfers: arguments.contains(failTransferArgument),
                                transferFault: transferFault(arguments: arguments))
        log.info("launch failTransfers=\(server.failTransfers, privacy: .public)")
        log.info("launch transferFault=\(server.transferFault?.rawValue ?? "none", privacy: .public)")
        return RemoteBankingRepository(session: FakeBackend.makeSession(server: server))
    }
}
