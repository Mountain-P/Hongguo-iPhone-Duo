// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum NativeHTTPPolicy {
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["fqnovel.com", "snssdk.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func request(_ args: [String: Any]) throws -> URLRequest {
        guard let raw = args["url"] as? String, raw.count <= 32768, let url = URL(string: raw), allowed(url) else { throw NativeSourceError(code: "SECURITY_BLOCKED") }
        let method = (args["method"] as? String ?? "GET").uppercased()
        guard method == "GET" || method == "POST" else { throw NativeSourceError(code: "SECURITY_BLOCKED") }
        let timeout = min(30_000, max(1, args["timeout"] as? Double ?? 8_000)) / 1000
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        if let body = args["body"] as? String {
            guard let data = Data(base64Encoded: body), data.count <= 1024 * 1024, method == "POST" else { throw NativeSourceError(code: "SECURITY_BLOCKED") }
            request.httpBody = data
        }
        for (key, value) in args["headers"] as? [String: String] ?? [:] {
            guard key.range(of: #"^[A-Za-z0-9-]{1,80}$"#, options: .regularExpression) != nil,
                  value.utf8.count <= 32768, !value.contains("\r"), !value.contains("\n") else { throw NativeSourceError(code: "SECURITY_BLOCKED") }
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }
}

/// One ephemeral, cookie-free transaction. Redirects are returned to the JS
/// allowlist instead of forwarding signed bodies or registration cookies.
private final class NativeHTTPTransaction: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var completion: CheckedContinuation<(Data, HTTPURLResponse), any Error>?
    private var cancelled = false
    private var finished = false
    private var session: URLSession?
    private var response: HTTPURLResponse?
    private var body = Data()

    func run(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                completion = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.urlCredentialStorage = nil
                configuration.urlCache = nil
                configuration.timeoutIntervalForResource = min(30, request.timeoutInterval)
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                let task = session.dataTask(with: request)
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }

    private func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = completion; completion = nil
        let session = session; self.session = nil
        lock.unlock()
        continuation?.resume(with: result)
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(.failure(NativeSourceError(code: "INVALID_RESPONSE"))); return
        }
        self.response = http
        // Status is authoritative even when an error body is huge or not UTF-8.
        // requestJson must observe 401/403 and stop anonymous recovery immediately.
        if http.statusCode != 200 {
            completionHandler(.cancel); finish(.success((Data(), http))); return
        }
        guard response.expectedContentLength <= 2 * 1024 * 1024 else {
            completionHandler(.cancel); finish(.failure(NativeSourceError(code: "INVALID_RESPONSE"))); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard body.count + data.count <= 2 * 1024 * 1024 else { finish(.failure(NativeSourceError(code: "INVALID_RESPONSE"))); return }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish(.failure(error)) }
        else if let response { finish(.success((body, response))) }
        else { finish(.failure(NativeSourceError(code: "INVALID_RESPONSE"))) }
    }
}

enum NativeHTTP {
    static func perform(_ json: String) async -> String {
        do {
            guard let encoded = json.data(using: .utf8), encoded.count <= 2 * 1024 * 1024,
                  let spec = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { throw NativeSourceError(code: "SECURITY_BLOCKED") }
            let request = try NativeHTTPPolicy.request(spec)
            let (data, response) = try await NativeHTTPTransaction().run(request)
            return try responseJSON(data, response: response)
        } catch {
            let code: String
            if error is CancellationError { code = "ERR_CANCELED" }
            else if let native = error as? NativeSourceError { code = native.code }
            else if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut: code = "ETIMEDOUT"
                case .cancelled: code = "ERR_CANCELED"
                case .cannotFindHost, .dnsLookupFailed: code = "ENOTFOUND"
                case .networkConnectionLost: code = "ECONNRESET"
                default: code = "ERR_NETWORK"
                }
            } else { code = "ERR_NETWORK" }
            return encode(["error": code])
        }
    }

    static func responseJSON(_ data: Data, response: HTTPURLResponse) throws -> String {
        let raw: String
        if response.statusCode != 200 { raw = "" }
        else {
            guard data.count <= 2 * 1024 * 1024, let decoded = String(data: data, encoding: .utf8) else { throw NativeSourceError(code: "INVALID_RESPONSE") }
            raw = decoded
        }
        var headers: [String: Any] = [:]
        for (key, value) in response.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
        if let fields = response.allHeaderFields as? [String: String], let url = response.url {
            headers["set-cookie"] = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).map { $0.name + "=" + $0.value }
        }
        return encode(["status": response.statusCode, "headers": headers, "data": raw])
    }

    private static func encode(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? #"{"error":"INVALID_RESPONSE"}"#
    }
}
