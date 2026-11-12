import Domain
import Foundation
import Synchronization

/// 송금이 처리된 뒤 응답만 망가뜨리는 실패 주입. POST /transfers의 200 응답(새 처리·재요청 모두)에만 적용한다.
public enum TransferFault: String, Sendable, CaseIterable {
    case dropResponseOnce     // 첫 200 응답만 연결 끊김
    case dropResponseAlways   // 200 응답을 매번 연결 끊김
    case garbleResponse       // 200 + 읽을 수 없는 본문
}

public final class FakeServer: Sendable {
    public static let idempotencyKeyHeader = "Idempotency-Key"
    public static let transactionsPerAccount = 5_000

    public struct Response: Sendable {
        public let statusCode: Int
        public let body: Data
        public let dropsConnection: Bool  // true면 응답 대신 연결이 끊긴다

        init(_ statusCode: Int, _ body: Data, dropsConnection: Bool = false) {
            self.statusCode = statusCode
            self.body = body
            self.dropsConnection = dropsConnection
        }
    }

    public let latency: Duration
    public let failTransfers: Bool
    public let transferFault: TransferFault?

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
        var didDropOnce = false
    }

    private let state = Mutex(State())

    public init(latency: Duration = .milliseconds(300), failTransfers: Bool = false,
                transferFault: TransferFault? = nil) {
        self.latency = latency
        self.failTransfers = failTransfers
        self.transferFault = transferFault
    }

    /// 지연 없이 요청 하나를 처리. 상태는 Mutex로 보호.
    public func handle(method: String, path: String, headers: [String: String] = [:],
                       body: Data?) -> Response {
        switch (method, path) {
        case ("GET", "/accounts"):
            return ok(state.withLock { $0.accounts })
        case ("GET", "/recipients"):
            return ok(state.withLock { $0.recipients })
        case ("POST", "/transfers"):
            return applyFault(to: transfer(key: headers[Self.idempotencyKeyHeader], body: body))
        case ("GET", _) where path.hasPrefix("/transfers/"):
            let key = String(path.dropFirst("/transfers/".count))
            return state.withLock { $0.transfers[key] }.map { ok($0.receipt) } ?? failure(404)
        case ("GET", _) where path.hasPrefix("/accounts/") && path.hasSuffix("/transactions"):
            let id = String(path.dropFirst("/accounts/".count).dropLast("/transactions".count))
            guard state.withLock({ $0.accounts.contains { $0.id == id } }) else { return failure(404) }
            return ok(Self.makeTransactions(accountID: id))
        default:
            return failure(404)
        }
    }

    private static let transactionBaseDate = Date(timeIntervalSince1970: 1_793_491_200)  // 2026-11-01 00:00 UTC, 고정
    private static let transactionTitles = ["편의점", "월급", "카페", "김하늘"]

    /// 계좌마다 같은 결과. 날짜는 기준 시각에서 10분씩 거꾸로, 순서는 날짜순이 아니게 섞는다.
    private static func makeTransactions(accountID: String) -> [Transaction] {
        let count = transactionsPerAccount
        return (0..<count).map { position in
            let k = (position * 7_919) % count  // 7919는 소수라 count와 서로소 → 순열
            let title = transactionTitles[k % transactionTitles.count]
            let amount = (k % 7 + 1) * (title == "월급" ? 300_000 : -1_500)
            return Transaction(id: "tx-\(accountID)-\(k)",
                               date: transactionBaseDate.addingTimeInterval(-Double(k) * 600),
                               title: title, amount: amount)
        }
    }

    /// 판정 순서: 실패 주입 500 → 키 없음 400 → 본문 400 → 같은 키(같은 본문 200 재응답 / 다른 본문 422)
    /// → 계좌·받는 사람 404 → 금액 400 → 처리. 같은 키 확인이 금액 검사보다 먼저여야
    /// 처리 뒤 잔액이 줄어든 상태의 재요청에도 저장된 영수증을 돌려준다.
    private func transfer(key: String?, body: Data?) -> Response {
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

    private func applyFault(to response: Response) -> Response {
        guard response.statusCode == 200, let transferFault else { return response }
        switch transferFault {
        case .dropResponseOnce:
            let drop = state.withLock { state in
                defer { state.didDropOnce = true }
                return !state.didDropOnce
            }
            return drop ? Response(200, Data(), dropsConnection: true) : response
        case .dropResponseAlways:
            return Response(200, Data(), dropsConnection: true)
        case .garbleResponse:
            return Response(200, Data("garbled".utf8))
        }
    }

    private func ok<T: Encodable>(_ value: T) -> Response {
        Response(200, (try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
    }

    private func failure(_ statusCode: Int) -> Response {
        Response(statusCode, Data("{}".utf8))
    }
}
