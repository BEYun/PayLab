import Domain
import Foundation
import Synchronization

public final class FakeServer: Sendable {
    public let latency: Duration
    public let failTransfers: Bool

    private struct State {
        var accounts: [Account] = [
            Account(id: "acc-main", name: "PayLab 통장", maskedNumber: "3333-01-****21", balance: 1_250_000),
            Account(id: "acc-living", name: "생활비 통장", maskedNumber: "3333-02-****58", balance: 320_000),
            Account(id: "acc-saving", name: "비상금 통장", maskedNumber: "3333-03-****07", balance: 50_000),
        ]
        let recipients: [Recipient] = [
            Recipient(id: "rcp-1", name: "김하늘", bankName: "국민은행", maskedNumber: "123-45-****78"),
            Recipient(id: "rcp-2", name: "이도윤", bankName: "신한은행", maskedNumber: "110-23-****56"),
            Recipient(id: "rcp-3", name: "박서연", bankName: "우리은행", maskedNumber: "1002-3-****89"),
        ]
    }

    private let state = Mutex(State())

    public init(latency: Duration = .milliseconds(300), failTransfers: Bool = false) {
        self.latency = latency
        self.failTransfers = failTransfers
    }

    /// 지연 없이 요청 하나를 처리. 상태는 Mutex로 보호.
    public func handle(method: String, path: String, body: Data?) -> (statusCode: Int, body: Data) {
        switch (method, path) {
        case ("GET", "/accounts"):
            return ok(state.withLock { $0.accounts })
        case ("GET", "/recipients"):
            return ok(state.withLock { $0.recipients })
        case ("POST", "/transfers"):
            return transfer(body: body)
        default:
            return failure(404)
        }
    }

    private func transfer(body: Data?) -> (statusCode: Int, body: Data) {
        if failTransfers { return failure(500) }
        guard let body, let request = try? JSONDecoder().decode(TransferRequest.self, from: body) else {
            return failure(400)
        }
        return state.withLock { state in
            guard let index = state.accounts.firstIndex(where: { $0.id == request.fromAccountID }),
                  state.recipients.contains(where: { $0.id == request.recipientID })
            else { return failure(404) }
            guard TransferRule.isValidAmount(request.amount, balance: state.accounts[index].balance) else {
                return failure(400)
            }
            state.accounts[index].balance -= request.amount
            return ok(TransferReceipt(transferID: "tr-\(UUID().uuidString)", amount: request.amount,
                                      balanceAfter: state.accounts[index].balance))
        }
    }

    private func ok<T: Encodable>(_ value: T) -> (statusCode: Int, body: Data) {
        (200, (try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
    }

    private func failure(_ statusCode: Int) -> (statusCode: Int, body: Data) {
        (statusCode, Data("{}".utf8))
    }
}
