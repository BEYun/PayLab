import Domain
import Foundation
import Synchronization

public final class FakeServer: Sendable {
    public static let idempotencyKeyHeader = "Idempotency-Key"

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
        var transfers: [String: (request: TransferRequest, receipt: TransferReceipt)] = [:]  // 송금 키별
    }

    private let state = Mutex(State())

    public init(latency: Duration = .milliseconds(300), failTransfers: Bool = false) {
        self.latency = latency
        self.failTransfers = failTransfers
    }

    /// 지연 없이 요청 하나를 처리. 상태는 Mutex로 보호.
    public func handle(method: String, path: String, headers: [String: String] = [:],
                       body: Data?) -> (statusCode: Int, body: Data) {
        switch (method, path) {
        case ("GET", "/accounts"):
            return ok(state.withLock { $0.accounts })
        case ("GET", "/recipients"):
            return ok(state.withLock { $0.recipients })
        case ("POST", "/transfers"):
            return transfer(key: headers[Self.idempotencyKeyHeader], body: body)
        case ("GET", _) where path.hasPrefix("/transfers/"):
            let key = String(path.dropFirst("/transfers/".count))
            return state.withLock { $0.transfers[key] }.map { ok($0.receipt) } ?? failure(404)
        default:
            return failure(404)
        }
    }

    /// 판정 순서: 실패 주입 500 → 키 없음 400 → 본문 400 → 같은 키(같은 본문 200 재응답 / 다른 본문 422)
    /// → 계좌·받는 사람 404 → 금액 400 → 처리. 같은 키 확인이 금액 검사보다 먼저여야
    /// 처리 뒤 잔액이 줄어든 상태의 재요청에도 저장된 영수증을 돌려준다.
    private func transfer(key: String?, body: Data?) -> (statusCode: Int, body: Data) {
        if failTransfers { return failure(500) }
        guard let key else { return failure(400) }
        guard let body, let request = try? JSONDecoder().decode(TransferRequest.self, from: body) else {
            return failure(400)
        }
        return state.withLock { state in
            if let saved = state.transfers[key] {
                return saved.request == request ? ok(saved.receipt) : failure(422)
            }
            guard let index = state.accounts.firstIndex(where: { $0.id == request.fromAccountID }),
                  state.recipients.contains(where: { $0.id == request.recipientID })
            else { return failure(404) }
            guard TransferRule.isValidAmount(request.amount, balance: state.accounts[index].balance) else {
                return failure(400)
            }
            state.accounts[index].balance -= request.amount
            let receipt = TransferReceipt(transferID: "tr-\(UUID().uuidString)", amount: request.amount,
                                          balanceAfter: state.accounts[index].balance)
            state.transfers[key] = (request, receipt)
            return ok(receipt)
        }
    }

    private func ok<T: Encodable>(_ value: T) -> (statusCode: Int, body: Data) {
        (200, (try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
    }

    private func failure(_ statusCode: Int) -> (statusCode: Int, body: Data) {
        (statusCode, Data("{}".utf8))
    }
}
