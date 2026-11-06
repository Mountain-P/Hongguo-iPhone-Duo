import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Never forward a bridge's credentials to a different origin or downgrade TLS.
        guard let original = task.originalRequest?.url, let target = request.url,
              sameOrigin(original, target), target.user == nil, target.password == nil else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CatalogError.malformedResponse }
            return (data, http)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as CatalogError { throw error }
        catch { throw CatalogError.network }
    }
}

func sameOrigin(_ left: URL, _ right: URL) -> Bool {
    func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
    return left.scheme?.lowercased() == right.scheme?.lowercased()
        && left.host?.lowercased() == right.host?.lowercased() && port(left) == port(right)
}

func load(_ request: URLRequest, using transport: any HTTPTransport) async throws -> Data {
    let (data, response) = try await transport.data(for: request)
    try Task.checkCancellation()
    guard (200...299).contains(response.statusCode) else {
        if response.statusCode == 401 { throw CatalogError.unauthorized }
        throw CatalogError.httpStatus(response.statusCode)
    }
    guard data.count <= 16 * 1024 * 1024 else { throw CatalogError.responseTooLarge }
    return data
}

func dictionary(_ data: Data) throws -> [String: Any] {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CatalogError.malformedResponse
    }
    return object
}

func string(_ value: Any?) -> String {
    if let value = value as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
    // String IDs preserve all digits. JSON numeric IDs are accepted only when they are exact integers.
    if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
        return value.stringValue
    }
    return ""
}

import CoreFoundation

func integer(_ value: Any?) -> Int? {
    if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return Int(exactly: value.doubleValue) }
    return Int(string(value))
}

func cleanedURLString(_ value: Any?) -> String {
    string(value).replacingOccurrences(of: "\\/", with: "/")
        .replacingOccurrences(of: "\\u002F", with: "/", options: .caseInsensitive)
        .replacingOccurrences(of: "\\u0026", with: "&", options: .caseInsensitive)
        .replacingOccurrences(of: "&amp;", with: "&")
}

func tags(_ value: Any?) -> [String] {
    if let value = value as? String {
        return value.components(separatedBy: CharacterSet(charactersIn: "·|,，")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    guard let rows = value as? [Any] else { return [] }
    var result: [String] = []
    for row in rows {
        let object = row as? [String: Any]
        let text = string(object?["name"] ?? object?["tag_name"] ?? object?["title"] ?? row)
        if !text.isEmpty && !result.contains(text) { result.append(text) }
    }
    return Array(result.prefix(5))
}
