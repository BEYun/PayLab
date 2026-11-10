import DataKit
import Domain
import Testing

// 가짜 서버 등록(FakeBackend.makeSession)은 프로세스 전역이라 이 Suite는 직렬로 돈다.
@Suite(.serialized)
struct RemoteBankingRepositoryTests {
    func makeRepository(failTransfers: Bool = false) -> RemoteBankingRepository {
        RemoteBankingRepository(session: FakeBackend.makeSession(
            server: FakeServer(latency: .zero, failTransfers: failTransfers)))
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

    @Test func transferReturnsReceipt() async throws {
        let receipt = try await makeRepository().transfer(
            TransferRequest(fromAccountID: "acc-main", recipientID: "rcp-1", amount: 1_000))
        #expect(receipt.amount == 1_000)
        #expect(receipt.balanceAfter == 1_249_000)
    }

    @Test func serverStatusBecomesBankingError() async {
        await #expect(throws: BankingError.server(statusCode: 500)) {
            try await makeRepository(failTransfers: true).transfer(
                TransferRequest(fromAccountID: "acc-main", recipientID: "rcp-1", amount: 1_000))
        }
        await #expect(throws: BankingError.server(statusCode: 404)) {
            try await makeRepository().transfer(
                TransferRequest(fromAccountID: "acc-x", recipientID: "rcp-1", amount: 1_000))
        }
        await #expect(throws: BankingError.server(statusCode: 400)) {
            try await makeRepository().transfer(
                TransferRequest(fromAccountID: "acc-main", recipientID: "rcp-1", amount: 0))
        }
    }
}
