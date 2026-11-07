import CoreGraphics
import Foundation
import ImageIO

public enum PosterImageError: Error, LocalizedError, Equatable, Sendable {
    case invalidURL, invalidResponse, responseTooLarge, invalidImage, imageTooLarge, busy, network
    case httpStatus(Int)
    public var errorDescription: String? { "暫時無法載入海報，稍後可再試。" }
}

/// CGImage is immutable; consumers may display the same decoded thumbnail concurrently.
public final class PosterImage: @unchecked Sendable {
    public let image: CGImage
    public let decodedByteCount: Int
    init(_ image: CGImage) {
        self.image = image
        decodedByteCount = image.bytesPerRow * image.height
    }
}

protocol PosterImageTransport: Sendable {
    func data(for url: URL, maximumBytes: Int) async throws -> Data
}

/// Memory-only poster loading. There is no cookie, credential or disk-image cache.
public actor PosterImagePipeline {
    public static let shared = PosterImagePipeline()
    public struct Configuration: Sendable {
        public let maximumConcurrentRequests: Int
        public let maximumCacheBytes: Int
        public let maximumCacheEntries: Int
        public let maximumDownloadBytes: Int
        public let maximumPendingRequests: Int
        public let maximumPixelDimension: Int
        public init(maximumConcurrentRequests: Int = 3, maximumCacheBytes: Int = 32 * 1024 * 1024,
                    maximumCacheEntries: Int = 80, maximumDownloadBytes: Int = 12 * 1024 * 1024,
                    maximumPendingRequests: Int = 128, maximumPixelDimension: Int = 2048) {
            self.maximumConcurrentRequests = min(max(1, maximumConcurrentRequests), 6)
            self.maximumCacheBytes = min(max(0, maximumCacheBytes), 64 * 1024 * 1024)
            self.maximumCacheEntries = min(max(0, maximumCacheEntries), 200)
            self.maximumDownloadBytes = min(max(1, maximumDownloadBytes), 24 * 1024 * 1024)
            self.maximumPendingRequests = min(max(1, maximumPendingRequests), 256)
            self.maximumPixelDimension = min(max(1, maximumPixelDimension), 2048)
        }
    }
    public struct Statistics: Sendable {
        public let cachedImages: Int
        public let cachedDecodedBytes: Int
        public let activeRequests: Int
        public let queuedRequests: Int
        public let activeDownloads: Int
        public let imageConsumers: Int
        public let downloadConsumers: Int
    }
    private struct Key: Hashable, Sendable { let url: URL; let pixels: Int }
    private struct Entry { let image: PosterImage; var accessed: UInt64 }
    private struct ImageFlight {
        let id: UUID
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<PosterImage, any Error>]
    }
    private struct DataFlight {
        let id: UUID
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<Data, any Error>]
    }
    private struct Slot { let id: UUID; let continuation: CheckedContinuation<Void, any Error> }
    private let configuration: Configuration
    private let transport: any PosterImageTransport
    private var cache: [Key: Entry] = [:]
    private var cacheBytes = 0
    private var access: UInt64 = 0
    private var images: [Key: ImageFlight] = [:]
    private var downloads: [URL: DataFlight] = [:]
    private var activeRequests = 0
    private var slots: [Slot] = []

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration; transport = PosterURLSessionTransport()
    }
    init(configuration: Configuration = .init(), transport: any PosterImageTransport) {
        self.configuration = configuration; self.transport = transport
    }

    public func image(for url: URL, targetPixelSize: Int) async throws -> PosterImage {
        try Task.checkCancellation()
        guard Self.validURL(url) else { throw PosterImageError.invalidURL }
        let pixels = min(max(1, targetPixelSize), configuration.maximumPixelDimension)
        let key = Key(url: url, pixels: min(((pixels + 63) / 64) * 64, configuration.maximumPixelDimension))
        if var entry = cache[key] {
            access &+= 1; entry.accessed = access; cache[key] = entry
            return entry.image
        }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PosterImage, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if images[key] != nil { images[key]?.waiters[waiter] = continuation; return }
                guard images.count < configuration.maximumPendingRequests else {
                    continuation.resume(throwing: PosterImageError.busy); return
                }
                let id = UUID()
                images[key] = ImageFlight(id: id, task: nil, waiters: [waiter: continuation])
                images[key]?.task = Task { [weak self] in
                    guard let self else { return }
                    await self.prepare(key, id: id)
                }
            }
        } onCancel: { Task { await self.cancelImage(key, waiter: waiter) } }
    }

    public func clearMemoryCache() { cache = [:]; cacheBytes = 0 }
    public func statistics() -> Statistics {
        .init(cachedImages: cache.count, cachedDecodedBytes: cacheBytes, activeRequests: activeRequests,
              queuedRequests: slots.count, activeDownloads: downloads.count,
              imageConsumers: images.values.reduce(0) { $0 + $1.waiters.count },
              downloadConsumers: downloads.values.reduce(0) { $0 + $1.waiters.count })
    }

    private func prepare(_ key: Key, id: UUID) async {
        var ownsSlot = false
        do {
            try await acquireSlot(); ownsSlot = true
            try Task.checkCancellation()
            let data = try await sharedData(for: key.url)
            try Task.checkCancellation()
            let decode = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                return try Self.downsample(data, pixels: key.pixels)
            }
            let image = try await withTaskCancellationHandler { try await decode.value } onCancel: { decode.cancel() }
            try Task.checkCancellation()
            finishImage(key, id: id, result: .success(image))
        } catch { finishImage(key, id: id, result: .failure(error)) }
        if ownsSlot { releaseSlot() }
    }

    private func finishImage(_ key: Key, id: UUID, result: Result<PosterImage, any Error>) {
        guard let flight = images[key], flight.id == id else { return }
        images.removeValue(forKey: key)
        if case .success(let image) = result, !flight.waiters.isEmpty {
            if image.decodedByteCount <= configuration.maximumCacheBytes, configuration.maximumCacheEntries > 0 {
                access &+= 1
                if let old = cache.removeValue(forKey: key) { cacheBytes -= old.image.decodedByteCount }
                cache[key] = Entry(image: image, accessed: access); cacheBytes += image.decodedByteCount
                while cacheBytes > configuration.maximumCacheBytes || cache.count > configuration.maximumCacheEntries {
                    guard let oldest = cache.min(by: { $0.value.accessed < $1.value.accessed })?.key,
                          let removed = cache.removeValue(forKey: oldest) else { break }
                    cacheBytes -= removed.image.decodedByteCount
                }
            }
        }
        for waiter in flight.waiters.values { waiter.resume(with: result) }
    }

    private func cancelImage(_ key: Key, waiter: UUID) {
        guard var flight = images[key], let continuation = flight.waiters.removeValue(forKey: waiter) else { return }
        if flight.waiters.isEmpty { images.removeValue(forKey: key); flight.task?.cancel() }
        else { images[key] = flight }
        continuation.resume(throwing: CancellationError())
    }

    private func sharedData(for url: URL) async throws -> Data {
        try Task.checkCancellation()
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if downloads[url] != nil { downloads[url]?.waiters[waiter] = continuation; return }
                let id = UUID(), transport = transport, limit = configuration.maximumDownloadBytes
                downloads[url] = DataFlight(id: id, task: nil, waiters: [waiter: continuation])
                downloads[url]?.task = Task { [weak self] in
                    let result: Result<Data, any Error>
                    do { result = .success(try await transport.data(for: url, maximumBytes: limit)) }
                    catch { result = .failure(error) }
                    if let self { await self.finishData(url, id: id, result: result) }
                }
            }
        } onCancel: { Task { await self.cancelData(url, waiter: waiter) } }
    }

    private func finishData(_ url: URL, id: UUID, result: Result<Data, any Error>) {
        guard let flight = downloads[url], flight.id == id else { return }
        downloads.removeValue(forKey: url)
        let bounded: Result<Data, any Error>
        if case .success(let data) = result, data.count > configuration.maximumDownloadBytes { bounded = .failure(PosterImageError.responseTooLarge) }
        else { bounded = result }
        for waiter in flight.waiters.values { waiter.resume(with: bounded) }
    }

    private func cancelData(_ url: URL, waiter: UUID) {
        guard var flight = downloads[url], let continuation = flight.waiters.removeValue(forKey: waiter) else { return }
        if flight.waiters.isEmpty { downloads.removeValue(forKey: url); flight.task?.cancel() }
        else { downloads[url] = flight }
        continuation.resume(throwing: CancellationError())
    }

    private func acquireSlot() async throws {
        try Task.checkCancellation()
        if activeRequests < configuration.maximumConcurrentRequests { activeRequests += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                slots.append(Slot(id: id, continuation: continuation))
            }
        } onCancel: { Task { await self.cancelSlot(id) } }
    }
    private func cancelSlot(_ id: UUID) {
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return }
        slots.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func releaseSlot() {
        if !slots.isEmpty { slots.removeFirst().continuation.resume() }
        else { activeRequests -= 1 }
    }

    static func validURL(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
            && url.user == nil && url.password == nil && url.absoluteString.utf8.count <= 8192
    }
    static func downsample(_ data: Data, pixels: Int) throws -> PosterImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { throw PosterImageError.invalidImage }
        guard width > 0, height > 0, width <= 32768, height <= 32768,
              width <= 32_000_000 / height else { throw PosterImageError.imageTooLarge }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw PosterImageError.invalidImage }
        try Task.checkCancellation()
        return PosterImage(image)
    }
}

struct PosterURLSessionTransport: PosterImageTransport {
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
    }
    func data(for url: URL, maximumBytes: Int) async throws -> Data {
        try await PosterDownload(configuration: configuration).data(for: url, maximumBytes: maximumBytes)
    }
}

/// Each network operation has one private ephemeral session and one exactly-once continuation.
private final class PosterDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var maximumBytes = 0
    private var redirects = 0
    private var finished = false
    private let template: URLSessionConfiguration

    init(configuration: URLSessionConfiguration) { template = configuration }

    func data(for url: URL, maximumBytes: Int) async throws -> Data {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !finished, !Task.isCancelled else {
                    lock.unlock(); continuation.resume(throwing: CancellationError()); return
                }
                self.continuation = continuation; self.maximumBytes = maximumBytes
                let configuration = template.copy() as! URLSessionConfiguration
                configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
                configuration.httpCookieAcceptPolicy = .never; configuration.httpAdditionalHeaders = nil
                configuration.urlCredentialStorage = nil; configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                var request = URLRequest(url: url)
                request.httpMethod = "GET"; request.httpShouldHandleCookies = false
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                let task = session.dataTask(with: request)
                self.session = session; self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, let url = response.url, PosterImagePipeline.validURL(url) else {
            completionHandler(.cancel); finish(.failure(PosterImageError.invalidResponse)); return
        }
        guard response.statusCode == 200 else {
            completionHandler(.cancel); finish(.failure(PosterImageError.httpStatus(response.statusCode))); return
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel); finish(.failure(PosterImageError.responseTooLarge)); return
        }
        lock.lock(); let allowed = !finished; lock.unlock()
        completionHandler(allowed ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard data.count <= maximumBytes - buffer.count else {
            lock.unlock(); finish(.failure(PosterImageError.responseTooLarge)); return
        }
        buffer.append(data); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if error != nil { finish(.failure(PosterImageError.network)) }
        else {
            lock.lock(); let data = buffer; lock.unlock()
            finish(.success(data))
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.lock(); redirects += 1; let allowed = !finished && redirects <= 5; lock.unlock()
        guard allowed, let url = request.url, PosterImagePipeline.validURL(url) else {
            completionHandler(nil); finish(.failure(PosterImageError.invalidURL)); return
        }
        var safe = URLRequest(url: url)
        safe.httpMethod = "GET"; safe.httpShouldHandleCookies = false
        safe.setValue("image/*", forHTTPHeaderField: "Accept")
        completionHandler(safe)
    }
    private func finish(_ result: Result<Data, any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation, task = task, session = session
        self.continuation = nil; self.task = nil; self.session = nil; buffer = Data()
        lock.unlock()
        if case .failure = result { task?.cancel(); session?.invalidateAndCancel() }
        else { session?.finishTasksAndInvalidate() }
        continuation?.resume(with: result)
    }
}
