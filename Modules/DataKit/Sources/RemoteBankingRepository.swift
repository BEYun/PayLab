import Domain
import Foundation
import os

private let log = Logger(subsystem: "com.example.paylab", category: "network")

public struct RemoteBankingRepository: BankingRepository {
    private let session: URLSession
    private let baseURL: URL

    public init(session: URLSession, baseURL: URL = FakeBackend.baseURL) {
        self.session = session
        self.baseURL = baseURL
    }

    public func fetchAccounts() async throws -> [Account] {
        try await send("GET", "accounts")
    }

    public func fetchRecipients() async throws -> [Recipient] {
        try await send("GET", "recipients")
    }

    public func transfer(_ request: TransferRequest, idempotencyKey: String) async throws -> TransferReceipt {
        try await send("POST", "transfers", body: JSONEncoder().encode(request),
                       headers: [FakeServer.idempotencyKeyHeader: idempotencyKey])
    }

    public func findTransfer(idempotencyKey: String) async throws -> TransferReceipt? {
        do {
            return try await send("GET", "transfers/\(idempotencyKey)") as TransferReceipt
        } catch BankingError.server(statusCode: 404) {
            return nil
        }
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: Data? = nil,
                                    headers: [String: String] = [:]) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        log.debug("request \(method, privacy: .public) /\(path, privacy: .public)")
        let start = ContinuousClock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            log.error("transport failed \(method, privacy: .public) /\(path, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
        let ms = (ContinuousClock.now - start) / .milliseconds(1)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let isSuccess = (200..<300).contains(status)
        log.log(level: isSuccess ? .info : .error,
                "response \(status, privacy: .public) \(method, privacy: .public) /\(path, privacy: .public) \(Int(ms), privacy: .public)ms \(data.count, privacy: .public)B")
        #if DEBUG
        log.debug("body \(method, privacy: .public) /\(path, privacy: .public) \(String(decoding: data, as: UTF8.self), privacy: .public)")
        #endif
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BankingError.server(statusCode: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as DecodingError {
            log.error("decode failed \(String(describing: T.self), privacy: .public) \(method, privacy: .public) /\(path, privacy: .public): \(Self.describe(error), privacy: .public)")
            #if DEBUG
            log.error("body \(method, privacy: .public) /\(path, privacy: .public) \(String(decoding: data, as: UTF8.self), privacy: .public)")
            #endif
            throw error
        }
    }

    /// "typeMismatch(Int) at [0].balance: <debugDescription>" 형식
    private static func describe(_ error: DecodingError) -> String {
        func path(_ codingPath: [any CodingKey]) -> String {
            let joined = codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            let trimmed = joined.hasPrefix(".") ? String(joined.dropFirst()) : joined
            return trimmed.isEmpty ? "<root>" : trimmed
        }
        switch error {
        case let .typeMismatch(type, context):
            return "typeMismatch(\(type)) at \(path(context.codingPath)): \(context.debugDescription)"
        case let .valueNotFound(type, context):
            return "valueNotFound(\(type)) at \(path(context.codingPath)): \(context.debugDescription)"
        case let .keyNotFound(key, context):
            return "keyNotFound(\(key.stringValue)) at \(path(context.codingPath)): \(context.debugDescription)"
        case let .dataCorrupted(context):
            return "dataCorrupted at \(path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }
}
