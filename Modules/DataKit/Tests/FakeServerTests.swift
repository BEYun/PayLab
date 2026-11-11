import DataKit
import Domain
import Foundation
import Testing

/// handle을 직접 부른다. FakeBackend.makeSession을 쓰지 않으므로 병렬 실행해도 된다.
struct FakeServerTests {
    let server = FakeServer(latency: .zero)

    @Test func getAccountsReturnsSeed() throws {
        let result = server.handle(method: "GET", path: "/accounts", body: nil)
        #expect(result.statusCode == 200)
        let accounts = try JSONDecoder().decode([Account].self, from: result.body)
        #expect(accounts.map(\.id) == ["acc-main", "acc-living", "acc-saving"])
        #expect(accounts.map(\.balance) == [1_250_000, 320_000, 50_000])
    }

    @Test func getRecipientsReturnsSeed() throws {
        let result = server.handle(method: "GET", path: "/recipients", body: nil)
        #expect(result.statusCode == 200)
        let recipients = try JSONDecoder().decode([Recipient].self, from: result.body)
        #expect(recipients.map(\.id) == ["rcp-1", "rcp-2", "rcp-3"])
    }

    @Test(arguments: [("GET", "/unknown"), ("DELETE", "/accounts"), ("GET", "/transfers")])
    func unknownRouteReturns404(method: String, path: String) {
        #expect(server.handle(method: method, path: path, body: nil).statusCode == 404)
    }

    @Test func failTransfersReturns500BeforeAnyCheck() throws {
        let failing = FakeServer(latency: .zero, failTransfers: true)
        for body in [nil, Data("x".utf8), try transferBody(amount: 1_000)] {
            #expect(failing.handle(method: "POST", path: "/transfers", body: body).statusCode == 500)
        }
        #expect(try balance(of: "acc-saving", in: failing) == 50_000)
    }

    @Test func missingOrBrokenBodyReturns400() {
        #expect(postTransfer(nil) == 400)
        #expect(postTransfer(Data("x".utf8)) == 400)
    }

    @Test func unknownAccountOrRecipientReturns404() throws {
        #expect(postTransfer(try transferBody(from: "acc-x", amount: 1_000)) == 404)
        #expect(postTransfer(try transferBody(to: "rcp-x", amount: 1_000)) == 404)
        #expect(postTransfer(try transferBody(from: "acc-x", amount: 0)) == 404)  // 금액 검사보다 먼저
        #expect(try balance(of: "acc-saving", in: server) == 50_000)
    }

    @Test func invalidAmountReturns400() throws {
        #expect(postTransfer(try transferBody(amount: 0)) == 400)
        #expect(postTransfer(try transferBody(amount: 50_001)) == 400)
        #expect(try balance(of: "acc-saving", in: server) == 50_000)
    }

    @Test func validTransferDeductsBalance() throws {
        let result = post(try transferBody(amount: 50_000))
        #expect(result.statusCode == 200)
        let saved = try receipt(result.body)
        #expect(saved.amount == 50_000)
        #expect(saved.balanceAfter == 0)
        #expect(saved.transferID.hasPrefix("tr-"))
        #expect(try balance(of: "acc-saving", in: server) == 0)
    }

    @Test func missingKeyReturns400() throws {
        #expect(post(try transferBody(amount: 1_000), key: nil).statusCode == 400)
        #expect(try balance(of: "acc-saving", in: server) == 50_000)
    }

    @Test func sameKeySameBodyReplaysReceipt() throws {
        let first = post(try transferBody(amount: 1_000), key: "K")
        let second = post(try transferBody(amount: 1_000), key: "K")
        #expect(first.statusCode == 200)
        #expect(second.statusCode == 200)
        #expect(try receipt(first.body) == receipt(second.body))
        #expect(try balance(of: "acc-saving", in: server) == 49_000)
    }

    @Test func sameKeyDifferentBodyReturns422() throws {
        #expect(post(try transferBody(amount: 1_000), key: "K").statusCode == 200)
        #expect(post(try transferBody(amount: 2_000), key: "K").statusCode == 422)
        #expect(try balance(of: "acc-saving", in: server) == 49_000)
    }

    @Test func replayBeatsBalanceCheck() throws {
        let first = post(try transferBody(amount: 30_000), key: "K")
        #expect(try balance(of: "acc-saving", in: server) == 20_000)
        let replay = post(try transferBody(amount: 30_000), key: "K")  // 잔액 20,000 < 30,000이어도 저장된 영수증
        #expect(replay.statusCode == 200)
        #expect(try receipt(replay.body) == receipt(first.body))
        #expect(try balance(of: "acc-saving", in: server) == 20_000)
    }

    @Test func getTransferByKey() throws {
        let posted = post(try transferBody(amount: 1_000), key: "K")
        let found = server.handle(method: "GET", path: "/transfers/K", body: nil)
        #expect(found.statusCode == 200)
        #expect(try receipt(found.body) == receipt(posted.body))
        #expect(server.handle(method: "GET", path: "/transfers/none", body: nil).statusCode == 404)
    }

    @Test func dropResponseOnceDropsFirstOnly() throws {
        let faulty = FakeServer(latency: .zero, transferFault: .dropResponseOnce)
        let first = post(try transferBody(amount: 1_000), key: "K", to: faulty)
        #expect(first.dropsConnection)
        #expect(try balance(of: "acc-saving", in: faulty) == 49_000)
        let second = post(try transferBody(amount: 1_000), key: "K", to: faulty)
        #expect(!second.dropsConnection)
        #expect(second.statusCode == 200)
        let found = faulty.handle(method: "GET", path: "/transfers/K", body: nil)
        #expect(try receipt(second.body) == receipt(found.body))
        #expect(try balance(of: "acc-saving", in: faulty) == 49_000)
    }

    @Test func dropResponseAlwaysDropsEveryReplay() throws {
        let faulty = FakeServer(latency: .zero, transferFault: .dropResponseAlways)
        #expect(post(try transferBody(amount: 1_000), key: "K", to: faulty).dropsConnection)
        #expect(post(try transferBody(amount: 1_000), key: "K", to: faulty).dropsConnection)
        let found = faulty.handle(method: "GET", path: "/transfers/K", body: nil)
        #expect(found.statusCode == 200)
        #expect(!found.dropsConnection)
        #expect(try balance(of: "acc-saving", in: faulty) == 49_000)
    }

    @Test func garbleResponseCommitsWithUnreadableBody() throws {
        let faulty = FakeServer(latency: .zero, transferFault: .garbleResponse)
        let result = post(try transferBody(amount: 1_000), key: "K", to: faulty)
        #expect(result.statusCode == 200)
        #expect(!result.dropsConnection)
        #expect(throws: DecodingError.self) { try receipt(result.body) }
        #expect(try balance(of: "acc-saving", in: faulty) == 49_000)
    }

    @Test func faultsDoNotTouchRejections() throws {
        let faulty = FakeServer(latency: .zero, transferFault: .dropResponseAlways)
        let result = post(try transferBody(amount: 0), key: "K", to: faulty)
        #expect(result.statusCode == 400)
        #expect(!result.dropsConnection)
    }

    /// 키를 주지 않으면 호출마다 새 키. key: nil이면 헤더 없음.
    private func post(_ body: Data?, key: String? = UUID().uuidString, to target: FakeServer? = nil) -> FakeServer.Response {
        let headers = key.map { [FakeServer.idempotencyKeyHeader: $0] } ?? [:]
        return (target ?? server).handle(method: "POST", path: "/transfers", headers: headers, body: body)
    }

    private func postTransfer(_ body: Data?) -> Int {
        post(body).statusCode
    }
}

private func receipt(_ body: Data) throws -> TransferReceipt {
    try JSONDecoder().decode(TransferReceipt.self, from: body)
}

private func transferBody(from: String = "acc-saving", to: String = "rcp-1", amount: Int) throws -> Data {
    try JSONEncoder().encode(TransferRequest(fromAccountID: from, recipientID: to, amount: amount))
}

private func balance(of id: String, in server: FakeServer) throws -> Int {
    let result = server.handle(method: "GET", path: "/accounts", body: nil)
    let accounts = try JSONDecoder().decode([Account].self, from: result.body)
    return try #require(accounts.first { $0.id == id }).balance
}
