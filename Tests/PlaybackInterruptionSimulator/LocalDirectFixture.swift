import Foundation

/// Isolated simulator only. The two synthetic catalog entries resolve solely to a loopback fixture.
/// All native Range/header validation, progressive storage and AVPlayer decoding still run.
public enum LocalDirectFixture {
    public static func service() -> NativeCatalogService {
        NativeCatalogService(transport: Catalogue(), prepareSource: { episode, _, _, quality in
            guard ["201","202"].contains(episode) else { throw CatalogError.invalidID }
            let url = URL(string: "https://fixture.fqnovelvod.com/\(episode).mp4")!
            let source = NativeMediaSource(url: url, contentKey: nil, userAgent: "SimulatorFixture", codec: "h264",
                                           quality: "360p", preference: quality, width: 640, height: 360)
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [FixtureHTTP.self]
            let fetcher = try NativeRangeHTTP(source: source, configuration: config)
            let stream = try await NativeProgressiveMedia.shared.prepare(source: source, fetcher: fetcher, diskCache: .shared)
            return .init(url: stream.assetURL, nativeStream: stream)
        })
    }

    private struct Catalogue: HTTPTransport {
        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let html = #"<script>window._ROUTER_DATA = {"loaderData":{"detail_page":{"isSuccess":true,"seriesDetail":{"series_id":"100","series_name":"斷線測試片","episode_cnt":2,"vid_list":["201","202"],"accessible_episode_cnt":2}}}};</script>"#
            return (Data(html.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }
}

private final class FixtureHTTP: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {
    private var transport: URLSession?
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "fixture.fqnovelvod.com" && ["/201.mp4","/202.mp4"].contains(request.url?.path ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let original = request.url, let text = try? String(contentsOf: URL.documentsDirectory.appendingPathComponent("fixture-port"), encoding: .utf8),
              let port = UInt16(text), let url = URL(string: "http://127.0.0.1:\(port)\(original.path)") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        var local = URLRequest(url: url)
        local.setValue(request.value(forHTTPHeaderField: "Range"), forHTTPHeaderField: "Range")
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        transport = session
        session.dataTask(with: local).resume()
    }
    override func stopLoading() { transport?.invalidateAndCancel() }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, let original = request.url,
              let headers = response.allHeaderFields as? [String:String],
              let forwarded = HTTPURLResponse(url: original, statusCode: response.statusCode, httpVersion: "HTTP/1.1", headerFields: headers) else {
            completionHandler(.cancel); return
        }
        client?.urlProtocol(self, didReceive: forwarded, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        client?.urlProtocol(self, didLoad: data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { client?.urlProtocol(self, didFailWithError: error) }
        else { client?.urlProtocolDidFinishLoading(self) }
        session.finishTasksAndInvalidate()
    }
}
