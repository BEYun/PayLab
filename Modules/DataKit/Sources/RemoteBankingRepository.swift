import Domain
import Foundation

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

    public func transfer(_ request: TransferRequest) async throws -> TransferReceipt {
        try await send("POST", "transfers", body: JSONEncoder().encode(request))
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: Data? = nil) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BankingError.server(statusCode: http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
