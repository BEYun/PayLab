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
        let result = server.handle(method: "POST", path: "/transfers", body: try transferBody(amount: 50_000))
        #expect(result.statusCode == 200)
        let receipt = try JSONDecoder().decode(TransferReceipt.self, from: result.body)
        #expect(receipt.amount == 50_000)
        #expect(receipt.balanceAfter == 0)
        #expect(receipt.transferID.hasPrefix("tr-"))
        #expect(try balance(of: "acc-saving", in: server) == 0)
    }

    private func postTransfer(_ body: Data?) -> Int {
        server.handle(method: "POST", path: "/transfers", body: body).statusCode
    }
}

private func transferBody(from: String = "acc-saving", to: String = "rcp-1", amount: Int) throws -> Data {
    try JSONEncoder().encode(TransferRequest(fromAccountID: from, recipientID: to, amount: amount))
}

private func balance(of id: String, in server: FakeServer) throws -> Int {
    let result = server.handle(method: "GET", path: "/accounts", body: nil)
    let accounts = try JSONDecoder().decode([Account].self, from: result.body)
    return try #require(accounts.first { $0.id == id }).balance
}
