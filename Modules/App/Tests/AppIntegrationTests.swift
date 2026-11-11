import DataKit
import Domain
import Foundation
import HomeFeature
import Testing
import TransferFeature
@testable import PayLab

// 가짜 서버 등록(FakeBackend.makeSession)은 프로세스 전역이라 이 Suite는 직렬로 돌고, 테스트마다 다시 등록한다.
// 호스트 앱도 실행될 때 자기 서버를 등록하지만 읽기 요청만 보내므로 테스트 상태를 바꾸지 않는다.
@MainActor @Suite(.serialized)
struct AppIntegrationTests {
    @Test func defaultArgumentsTransferSucceeds() async throws {
        let request = TransferRequest(fromAccountID: "acc-main", recipientID: "rcp-1", amount: 1_000)
        let receipt = try await AppEnvironment.makeRepository(arguments: []).transfer(request, idempotencyKey: UUID().uuidString)
        #expect(receipt.balanceAfter == 1_249_000)
    }

    @Test func failTransferArgumentMakesTransferFail() async {
        let request = TransferRequest(fromAccountID: "acc-main", recipientID: "rcp-1", amount: 1_000)
        let repository = AppEnvironment.makeRepository(arguments: ["--fail-transfer"])
        await #expect(throws: BankingError.server(statusCode: 500)) {
            try await repository.transfer(request, idempotencyKey: UUID().uuidString)
        }
    }

    @Test(arguments: [
        ([], nil),
        (["--drop-transfer-response-once"], .dropResponseOnce),
        (["--drop-transfer-response"], .dropResponseAlways),
        (["--garble-transfer-response"], .garbleResponse),
        (["--drop-transfer-response", "--drop-transfer-response-once"], .dropResponseOnce),  // 표 앞쪽이 이김
    ] as [([String], TransferFault?)])
    func transferFaultArguments(arguments: [String], expected: TransferFault?) {
        #expect(AppEnvironment.transferFault(arguments: arguments) == expected)
    }

    @Test func successfulTransferShowsOnHome() async throws {
        let (home, transfer) = try await sendOneThousandWonFromMain(FakeServer(latency: .zero))
        if case .success(let receipt?) = transfer.outcome {
            #expect(receipt.balanceAfter == 1_249_000)
        } else {
            Issue.record("송금이 성공해야 한다: \(String(describing: transfer.outcome))")
        }
        await home.load()
        #expect(mainBalance(home) == 1_249_000)
    }

    @Test func failTransferEndsNotSentAndKeepsHomeBalance() async throws {
        let (home, transfer) = try await sendOneThousandWonFromMain(FakeServer(latency: .zero, failTransfers: true))
        #expect(transfer.outcome == .failure(.notSent))  // 재시도 3번 → 자동 조회 404
        await home.load()
        #expect(mainBalance(home) == 1_250_000)
    }

    @Test func dropOnceRetriesToSuccess() async throws {
        let (home, transfer) = try await sendOneThousandWonFromMain(
            FakeServer(latency: .zero, transferFault: .dropResponseOnce))
        if case .success(let receipt?) = transfer.outcome {
            #expect(receipt.balanceAfter == 1_249_000)
        } else {
            Issue.record("재시도가 영수증을 받아야 한다: \(String(describing: transfer.outcome))")
        }
        await home.load()
        #expect(mainBalance(home) == 1_249_000)
    }

    @Test func dropAlwaysAutoCheckFindsTransfer() async throws {
        let (home, transfer) = try await sendOneThousandWonFromMain(
            FakeServer(latency: .zero, transferFault: .dropResponseAlways))
        if case .success(let receipt?) = transfer.outcome {  // 재시도 3번 모두 끊김 → 자동 조회가 찾음
            #expect(receipt.balanceAfter == 1_249_000)
        } else {
            Issue.record("자동 조회가 송금을 찾아야 한다: \(String(describing: transfer.outcome))")
        }
        await home.load()
        #expect(mainBalance(home) == 1_249_000)
    }

    @Test func garbleShowsSentWithoutReceipt() async throws {
        let (home, transfer) = try await sendOneThousandWonFromMain(
            FakeServer(latency: .zero, transferFault: .garbleResponse))
        #expect(transfer.outcome == .success(nil))
        await home.load()
        #expect(mainBalance(home) == 1_249_000)
    }

    private func mainBalance(_ home: HomeModel) -> Int? {
        home.accounts.first { $0.id == "acc-main" }?.balance
    }

    /// 홈을 불러와 acc-main에서 첫 받는 사람에게 1,000원 송금을 마칠 때까지 진행한다. 재시도 대기 0.
    private func sendOneThousandWonFromMain(_ server: FakeServer) async throws -> (HomeModel, TransferModel) {
        let repository = RemoteBankingRepository(session: FakeBackend.makeSession(server: server))
        let home = HomeModel(repository: repository)
        await home.load()
        let main = try #require(home.accounts.first { $0.id == "acc-main" })
        let transfer = TransferModel(fromAccount: main, repository: repository, retryDelays: [.zero, .zero])
        await transfer.loadRecipients()
        transfer.select(try #require(transfer.recipients.first))
        transfer.amountText = "1000"
        transfer.proceedToConfirm()
        await transfer.submit()
        return (home, transfer)
    }
}
