import Foundation

public enum FakeBackend {
    public static let baseURL = URL(string: "https://api.paylab.example")!

    /// server를 FakeServerURLProtocol에 등록하고, 그 프로토콜만 쓰는 URLSession을 반환
    public static func makeSession(server: FakeServer) -> URLSession {
        FakeServerURLProtocol.server.withLock { $0 = server }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeServerURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
