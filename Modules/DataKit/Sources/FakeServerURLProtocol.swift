import Foundation
import Synchronization

final class FakeServerURLProtocol: URLProtocol, @unchecked Sendable {
    static let server = Mutex<FakeServer?>(nil)

    private var loadingTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == FakeBackend.baseURL.host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let server = Self.server.withLock({ $0 }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let method = request.httpMethod ?? "GET"
        let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        nonisolated(unsafe) let client = client // URLProtocolClient는 Sendable이 아님
        nonisolated(unsafe) let this = self
        loadingTask = Task {
            try? await Task.sleep(for: server.latency)
            if Task.isCancelled { return }
            let result = server.handle(method: method, path: url.path, body: body)
            let response = HTTPURLResponse(url: url, statusCode: result.statusCode, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(this, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(this, didLoad: result.body)
            client?.urlProtocolDidFinishLoading(this)
        }
    }

    override func stopLoading() {
        loadingTask?.cancel()
    }

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
