import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct URLSessionStreamingClient: StreamingHTTPClient {
    public init() {}

    public func lines(for request: ProviderHTTPRequest, provider: ProviderKind) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let bridge = SessionBridge(provider: provider, continuation: continuation)
            bridge.start(request)
        }
    }
}

private final class SessionBridge: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let provider: ProviderKind
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let lock = NSLock()
    private var buffer = Data()
    private var errorBody = Data()
    private var status = 0
    private var headers: [String: String] = [:]
    private var failed = false
    private var finished = false
    private var session: URLSession?
    private var task: URLSessionTask?

    init(provider: ProviderKind, continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.provider = provider
        self.continuation = continuation
        super.init()
    }

    func start(_ request: ProviderHTTPRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        let task = session.dataTask(with: urlRequest)
        self.task = task
        continuation.onTermination = { [weak self] _ in
            self?.cancel()
        }
        task.resume()
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            status = http.statusCode
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key).lowercased()] = String(describing: value)
            }
            failed = status >= 400
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if failed {
            errorBody.append(data)
            lock.unlock()
            return
        }
        buffer.append(data)
        let lines = drainLines(final: false)
        lock.unlock()
        for line in lines {
            continuation.yield(line)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                finish(.failure(CancellationError()))
            } else {
                finish(.failure(ProviderFailure.network(message: "The provider connection failed.")))
            }
            return
        }
        lock.lock()
        let status = self.status
        let headers = self.headers
        let errorBody = self.errorBody
        let lines = drainLines(final: true)
        let failed = self.failed
        lock.unlock()
        if failed {
            finish(.failure(ProviderTranslator.decodeFailure(
                provider: provider,
                status: status,
                headers: headers,
                body: errorBody
            )))
            return
        }
        for line in lines {
            continuation.yield(line)
        }
        finish(.success(()))
    }

    private func drainLines(final: Bool) -> [String] {
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 10) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            lines.append(line)
        }
        if final, !buffer.isEmpty {
            var line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            if line.hasSuffix("\r") { line.removeLast() }
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        switch result {
        case .success:
            continuation.finish()
        case .failure(let error):
            continuation.finish(throwing: error)
        }
        session?.finishTasksAndInvalidate()
        session = nil
        task = nil
    }
}
