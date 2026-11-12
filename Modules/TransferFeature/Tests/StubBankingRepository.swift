import Domain
import Foundation
import Synchronization
import Testing

/// 받는 사람·송금·조회 결과를 테스트가 정하고, 받은 요청과 키를 기록한다.
/// 송금·조회 응답은 호출마다 앞에서 하나씩 쓰고, 다 쓰면 마지막을 반복한다.
/// holdFirstTransfer가 켜지면 첫 송금 호출만 release() 전까지 멈춘다 (연타 재현용).
final class StubBankingRepository: BankingRepository {
    struct TransferCall: Equatable {
        let request: TransferRequest
        let idempotencyKey: String
    }

    /// 저장소가 돌려줄 응답. 오류는 던질 때 만든다.
    enum Reply: Sendable {
        case receipt(TransferReceipt)
        case notFound        // findTransfer → nil, transfer → BankingError.server(404)
        case server(Int)     // BankingError.server(statusCode:)
        case connectionLost  // URLError(.networkConnectionLost)
        case unreadable      // DecodingError (2xx 본문을 읽지 못함)
        case cancelled       // CancellationError

        func receipt() throws -> TransferReceipt? {
            switch self {
            case .receipt(let receipt): return receipt
            case .notFound: return nil
            case .server(let code): throw BankingError.server(statusCode: code)
            case .connectionLost: throw URLError(.networkConnectionLost)
            case .unreadable: throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "test"))
            case .cancelled: throw CancellationError()
            }
        }
    }

    private struct State {
        var transfers: [Reply]
        var finds: [Reply]
        var transferCalls: [TransferCall] = []
        var findKeys: [String] = []
        var held: [CheckedContinuation<Void, Never>] = []
        var heldWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let recipients: Result<[Recipient], BankingError>
    private let holdFirstTransfer: Bool
    private let state: Mutex<State>

    init(recipients: Result<[Recipient], BankingError> = .success([]),
         transfers: [Reply] = [.server(500)],
         finds: [Reply] = [.notFound],
         holdFirstTransfer: Bool = false) {
        self.recipients = recipients
        self.holdFirstTransfer = holdFirstTransfer
        self.state = Mutex(State(transfers: transfers, finds: finds))
    }

    var transferCalls: [TransferCall] { state.withLock { $0.transferCalls } }
    var findKeys: [String] { state.withLock { $0.findKeys } }

    /// 멈춘 호출이 생길 때까지 기다린다.
    func waitUntilHeld() async {
        await withCheckedContinuation { continuation in
            state.withLock { state in
                if state.held.isEmpty { state.heldWaiters.append(continuation) } else { continuation.resume() }
            }
        }
    }

    /// 멈춘 호출을 모두 풀어 준다.
    func release() {
        let held = state.withLock { state in
            defer { state.held.removeAll() }
            return state.held
        }
        held.forEach { $0.resume() }
    }

    func fetchAccounts() async throws -> [Account] {
        Issue.record("TransferModel은 fetchAccounts를 부르지 않아야 한다")
        throw BankingError.server(statusCode: 0)
    }

    func fetchRecipients() async throws -> [Recipient] {
        try recipients.get()
    }

    func fetchTransactions(accountID: String) async throws -> [Transaction] {
        Issue.record("TransferModel는 fetchTransactions를 부르지 않아야 한다")
        throw BankingError.server(statusCode: 0)
    }

    func transfer(_ request: TransferRequest, idempotencyKey: String) async throws -> TransferReceipt {
        let (reply, isFirst) = state.withLock { state in
            state.transferCalls.append(TransferCall(request: request, idempotencyKey: idempotencyKey))
            return (Self.next(&state.transfers), state.transferCalls.count == 1)
        }
        if holdFirstTransfer && isFirst { await hold() }
        guard let receipt = try reply.receipt() else { throw BankingError.server(statusCode: 404) }
        return receipt
    }

    func findTransfer(idempotencyKey: String) async throws -> TransferReceipt? {
        let reply = state.withLock { state in
            state.findKeys.append(idempotencyKey)
            return Self.next(&state.finds)
        }
        return try reply.receipt()
    }

    private func hold() async {
        await withCheckedContinuation { continuation in
            state.withLock { state in
                state.held.append(continuation)
                state.heldWaiters.forEach { $0.resume() }
                state.heldWaiters.removeAll()
            }
        }
    }

    private static func next(_ replies: inout [Reply]) -> Reply {
        replies.count > 1 ? replies.removeFirst() : replies[0]
    }
}
