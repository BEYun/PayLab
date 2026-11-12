import DataKit
import Domain
import Foundation
import Testing

// 가짜 서버 등록(FakeBackend.makeSession)은 프로세스 전역이라 이 Suite는 직렬로 돈다.
@Suite(.serialized)
struct RemoteBankingRepositoryTests {
    func makeRepository(failTransfers: Bool = false, transferFault: TransferFault? = nil) -> RemoteBankingRepository {
        RemoteBankingRepository(session: FakeBackend.makeSession(
            server: FakeServer(latency: .zero, failTransfers: failTransfers, transferFault: transferFault)))
    }

    @Test func fetchAccountsDecodesSeed() async throws {
        let accounts = try await makeRepository().fetchAccounts()
        #expect(accounts.count == 3)
        #expect(accounts.first?.id == "acc-main")
        #expect(accounts.first?.balance == 1_250_000)
    }

    @Test func fetchRecipientsDecodesSeed() async throws {
        let recipients = try await makeRepository().fetchRecipients()
        #expect(recipients.map(\.id) == ["rcp-1", "rcp-2", "rcp-3"])
    }

    @Test func fetchTransactionsDecodes() async throws {
        let transactions = try await makeRepository().fetchTransactions(accountID: "acc-main")
        #expect(transactions.count == FakeServer.transactionsPerAccount)
    }

    @Test func transferReturnsReceipt() async throws {
        let receipt = try await makeRepository().transfer(
            TransferRequest(fromAccountID: "acc-main", recipientID: "rcp-1", amount: 1_000), idempotencyKey: UUID().uuidString)
        #expect(receipt.amount == 1_000)
        #expect(receipt.balanceAfter == 1_249_000)
    }

    @Test func serverStatusBecomesBankingError() async {
        await #expect(throws: BankingError.server(statusCode: 500)) {
            try await makeRepository(failTransfers: true).transfer(
                TransferRequest(fromAccountID: "acc-main", recipientID: "rcp-1", amount: 1_000), idempotencyKey: UUID().uuidString)
        }
        await #expect(throws: BankingError.server(statusCode: 404)) {
            try await makeRepository().transfer(
                TransferRequest(fromAccountID: "acc-x", recipientID: "rcp-1", amount: 1_000), idempotencyKey: UUID().uuidString)
        }
        await #expect(throws: BankingError.server(statusCode: 400)) {
            try await makeRepository().transfer(
                TransferRequest(fromAccountID: "acc-main", recipientID: "rcp-1", amount: 0), idempotencyKey: UUID().uuidString)
        }
    }

    @Test func sameKeyTransfersOnce() async throws {
        let repository = makeRepository()
        let request = TransferRequest(fromAccountID: "acc-main", recipientID: "rcp-1", amount: 1_000)
        let first = try await repository.transfer(request, idempotencyKey: "K")
        let second = try await repository.transfer(request, idempotencyKey: "K")
        #expect(first == second)
        let accounts = try await repository.fetchAccounts()
        #expect(accounts.first { $0.id == "acc-main" }?.balance == 1_249_000)
    }

    @Test func findTransferReturnsReceiptOrNil() async throws {
        let repository = makeRepository()
        let receipt = try await repository.transfer(
            TransferRequest(fromAccountID: "acc-main", recipientID: "rcp-1", amount: 1_000), idempotencyKey: "K")
        #expect(try await repository.findTransfer(idempotencyKey: "K") == receipt)
        #expect(try await repository.findTransfer(idempotencyKey: "none") == nil)
    }

    @Test func droppedResponseThrowsURLError() async throws {
        let repository = makeRepository(transferFault: .dropResponseAlways)
        let request = TransferRequest(fromAccountID: "acc-main", recipientID: "rcp-1", amount: 1_000)
        await #expect(throws: URLError.self) {
            try await repository.transfer(request, idempotencyKey: "K")
        }
        let found = try await repository.findTransfer(idempotencyKey: "K")
        #expect(found?.amount == 1_000)
    }

    @Test func garbledResponseThrowsDecodingError() async {
        let repository = makeRepository(transferFault: .garbleResponse)
        await #expect(throws: DecodingError.self) {
            try await repository.transfer(
                TransferRequest(fromAccountID: "acc-main", recipientID: "rcp-1", amount: 1_000), idempotencyKey: "K")
        }
    }
}
