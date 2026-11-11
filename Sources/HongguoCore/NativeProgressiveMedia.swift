// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public actor NativeProgressiveMedia {
    public static let shared = NativeProgressiveMedia()
    public static let reusableTimeToLive: TimeInterval = 30
    public static let maximumReusableEntries = 2
    public static let maximumReusablePreparationBytes = 2 * 1024 * 1024
    private static let directPlaybackHosts: Set<String> = [
        "v11-reading-videocdn302.qznovelvod.com",
        "v26-reading-videocdn302.qznovelvod.com"
    ]
    private struct Key: Hashable {
        let episodeID: String
        let url: URL
        let key: Data?
        let codec: String
        let userAgent: String
        let quality: String
        let preference: NativePlaybackQuality
    }
    private struct Cached {
        let stream: NativeMediaStream
        let expires: Date
        var access: UInt64
    }
    private struct PlaybackRoute: Hashable {
        let episodeID: String
        let preference: NativePlaybackQuality
    }
    private final class FailedPlaybackRoutes: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [PlaybackRoute: (host: String, expires: Date)] = [:]

        func host(for route: PlaybackRoute, now: Date) -> String? {
            lock.withLock {
                entries = entries.filter { $0.value.expires > now }
                return entries[route]?.host
            }
        }

        func record(_ host: String, for route: PlaybackRoute, now: Date) {
            lock.withLock {
                entries = entries.filter { $0.value.expires > now }
                entries[route] = (host, now.addingTimeInterval(60))
                if entries.count > 16, let oldest = entries.min(by: { $0.value.expires < $1.value.expires }) {
                    entries.removeValue(forKey: oldest.key)
                }
            }
        }

        func clear() { lock.withLock { entries.removeAll() } }
    }
    private var reusable: [Key: Cached] = [:]
    private var requests: [Key: UUID] = [:]
    private let failedRoutes = FailedPlaybackRoutes()
    private var access: UInt64 = 0
    private let now: @Sendable () -> Date
    private let makeFetcher: @Sendable (NativeMediaSource) throws -> any NativeRangeFetching

    public init() {
        now = Date.init
        makeFetcher = { try NativeRangeHTTP(source: $0) }
    }

    init(now: @escaping @Sendable () -> Date = Date.init,
         makeFetcher: @escaping @Sendable (NativeMediaSource) throws -> any NativeRangeFetching) {
        self.now = now; self.makeFetcher = makeFetcher
    }

    public func prepare(source: NativeMediaSource, episodeID: String, fresh: Bool = false) async throws -> NativeMediaStream {
        try await prepare(source: source, episodeID: episodeID, fresh: fresh, deadline: .now + .seconds(30))
    }

    func preparePlayback(source: NativeMediaSource, episodeID: String, fresh: Bool) async throws -> NativeMediaStream {
        var candidates = [source] + source.alternateSources.prefix(2)
        // These direct mirrors served the same rendition with shorter range waits
        // when paired with origins that schedule a redirect on each request.
        if NativeMediaPolicy.isScheduledPlaybackOrigin(source.url),
           let preferred = candidates.dropFirst().firstIndex(where: { Self.directPlaybackHosts.contains($0.url.host?.lowercased() ?? "") }) {
            let direct = candidates.remove(at: preferred)
            candidates.insert(direct, at: 0)
        }
        let deadline = ContinuousClock.now + .seconds(30)
        if NativePrefetchContext.maximumBytes != nil {
            return try await prepare(source: candidates[0], episodeID: episodeID, fresh: fresh, deadline: deadline)
        }
        let route = PlaybackRoute(episodeID: episodeID, preference: source.preference)
        if fresh, let failedHost = failedRoutes.host(for: route, now: now()),
           candidates[0].url.host?.lowercased() == failedHost,
           let alternate = candidates.dropFirst().firstIndex(where: {
               NativeMediaPolicy.allows($0.url) && $0.url.host?.lowercased() != failedHost
           }) {
            let preferred = candidates.remove(at: alternate)
            let failed = candidates.removeFirst()
            candidates.insert(preferred, at: 0)
            candidates.append(failed)
        }
        for candidate in candidates.dropLast() {
            do { return try await prepare(source: candidate, episodeID: episodeID, fresh: fresh, deadline: deadline) }
            catch {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline, PlaybackRecovery.shouldRetryAssetRead(error) else { throw error }
            }
        }
        return try await prepare(source: candidates[candidates.count - 1], episodeID: episodeID, fresh: fresh, deadline: deadline)
    }

    private func prepare(source: NativeMediaSource, episodeID: String, fresh: Bool,
                         deadline: ContinuousClock.Instant) async throws -> NativeMediaStream {
        try validateID(episodeID)
        try NativeMediaPolicy.validate(source)
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw NativeSourceError(code: "ETIMEDOUT") }
        let key = Key(episodeID: episodeID, url: source.url, key: source.contentKey,
                      codec: source.codec, userAgent: source.userAgent, quality: source.quality, preference: source.preference)
        reusable = reusable.filter { $0.value.expires > now() }
        if !fresh, var cached = reusable[key], await cached.stream.isReusable,
           cached.expires > now(), reusable[key]?.stream.id == cached.stream.id {
            try Task.checkCancellation()
            access &+= 1; cached.access = access; reusable[key] = cached
            return cached.stream
        }
        reusable.removeValue(forKey: key)
        let fetcher = try makeFetcher(source)
        let request = UUID(); requests[key] = request
        let byteLimit = NativePrefetchContext.maximumBytes
        let route = PlaybackRoute(episodeID: episodeID, preference: source.preference)
        let host = source.url.host?.lowercased(), routes = failedRoutes, now = now
        do {
            let stream = try await withThrowingTaskGroup(of: NativeMediaStream.self) { group in
                group.addTask {
                    try await self.prepare(source: source, fetcher: fetcher, byteLimit: byteLimit, diskCache: .shared) {
                        if let host { routes.record(host, for: route, now: now()) }
                    }
                }
                group.addTask {
                    try await Task.sleep(until: deadline, clock: .continuous)
                    throw NativeSourceError(code: "ETIMEDOUT")
                }
                defer { group.cancelAll() }
                guard let stream = try await group.next() else { throw NativeProgressiveError.invalidRange }
                return stream
            }
            try Task.checkCancellation()
            if requests[key] == request {
                requests.removeValue(forKey: key)
                if stream.preparationByteCount <= Self.maximumReusablePreparationBytes {
                    access &+= 1
                    reusable[key] = Cached(stream: stream, expires: now().addingTimeInterval(Self.reusableTimeToLive), access: access)
                    while reusable.count > Self.maximumReusableEntries || reusable.values.reduce(0, { $0 + $1.stream.preparationByteCount }) > Self.maximumReusablePreparationBytes {
                        guard let victim = reusable.min(by: { $0.value.access < $1.value.access }) else { break }
                        reusable.removeValue(forKey: victim.key)
                    }
                }
            }
            return stream
        }
        catch {
            if requests[key] == request { requests.removeValue(forKey: key) }
            (fetcher as? NativeRangeHTTP)?.close()
            throw error
        }
    }

    public func clearReusableCache() async {
        let streams = reusable.values.map(\.stream)
        reusable.removeAll()
        requests.removeAll()
        failedRoutes.clear()
        for stream in streams { await stream.trimCachedChunks() }
    }

    var reusableEntryCount: Int { reusable.count }

    public func cachedPlaybackBytes() async -> Int { await NativeChunkDiskCache.shared.byteCount }
    public func clearPlaybackDiskCache() async { await NativeChunkDiskCache.shared.clear() }

    // Injectable byte source allows deterministic header, aux, LRU and cancellation tests.
    func prepare(source: NativeMediaSource, fetcher: any NativeRangeFetching, byteLimit: Int? = nil,
                 diskCache: NativeChunkDiskCache? = nil, onRouteFailure: (@Sendable () -> Void)? = nil) async throws -> NativeMediaStream {
        let reader = PreparationReader(fetcher: fetcher, byteLimit: byteLimit)
        let first = try await reader.fetch(range: 0..<(256 * 1024))
        try Self.validate(first, requested: 0..<(256 * 1024), total: nil, validators: nil)
        var prefix = first.data
        let moovEnd = try Self.headerEnd(prefix, total: first.totalLength)
        let requiredPrefix = min(first.totalLength, moovEnd + min(16, first.totalLength - moovEnd))
        if prefix.count < requiredPrefix {
            let remaining = prefix.count..<requiredPrefix
            let next = try await reader.fetch(range: remaining)
            try Self.validate(next, requested: remaining, total: first.totalLength, validators: first.validators)
            prefix.append(next.data)
        }
        var auxiliary: [NativeMP4ByteRegion] = []
        var auxiliaryBytes = 0
        for round in 0...3 {
            try Task.checkCancellation()
            do {
                let plan = try NativeMP4.prepareStream(prefix: prefix, totalLength: first.totalLength, contentKey: source.contentKey, codec: source.codec, auxiliary: auxiliary)
                try Task.checkCancellation()
                let clearPrefix = try plan.decrypt(data: prefix, offset: 0)
                return NativeMediaStream(totalLength: first.totalLength, fetcher: fetcher, plan: plan,
                    validators: first.validators, prefix: clearPrefix, preparationByteCount: clearPrefix.count + auxiliaryBytes,
                    variant: NativeMediaVariant(source: source), diskCache: diskCache, onRouteFailure: onRouteFailure)
            } catch let requirements as NativeMP4StreamRequirements {
                guard round < 3, !requirements.ranges.isEmpty, requirements.ranges.count <= 512 else { throw NativeProgressiveError.auxiliaryLimit }
                for range in requirements.ranges {
                    guard range.lowerBound >= 0, range.upperBound <= first.totalLength, !range.isEmpty,
                          range.count <= 8 * 1024 * 1024 - auxiliaryBytes else { throw NativeProgressiveError.auxiliaryLimit }
                    let response = try await reader.fetch(range: range)
                    try Self.validate(response, requested: range, total: first.totalLength, validators: first.validators)
                    auxiliaryBytes += response.data.count
                    auxiliary.append(NativeMP4ByteRegion(offset: range.lowerBound, data: response.data))
                }
            }
        }
        throw NativeProgressiveError.auxiliaryLimit
    }

    private actor PreparationReader {
        let fetcher: any NativeRangeFetching
        let byteLimit: Int?
        var requestedBytes = 0
        init(fetcher: any NativeRangeFetching, byteLimit: Int?) {
            self.fetcher = fetcher; self.byteLimit = byteLimit
        }
        func fetch(range: Range<Int>) async throws -> NativeRangeResponse {
            try Task.checkCancellation()
            if let byteLimit, range.count > byteLimit - requestedBytes { throw PlaybackPrefetchError.budgetExceeded }
            requestedBytes += range.count
            return try await fetcher.fetch(range: range)
        }
    }

    static func validate(_ response: NativeRangeResponse, requested: Range<Int>, total: Int?, validators: NativeRangeValidators?) throws {
        guard response.totalLength > 0, requested.lowerBound < response.totalLength,
              response.range == requested.lowerBound..<min(requested.upperBound, response.totalLength),
              response.data.count == response.range.count else { throw NativeProgressiveError.invalidRange }
        guard total.map({ $0 == response.totalLength }) ?? true,
              validators?.accepts(response.validators) ?? true else { throw NativeProgressiveError.changedSource }
    }

    private static func headerEnd(_ prefix: Data, total: Int) throws -> Int {
        func u32(_ offset: Int) throws -> Int {
            guard offset >= 0, offset <= prefix.count - 4 else { throw NativeProgressiveError.unsupportedLayout }
            return prefix[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        guard prefix.count >= 24, String(decoding: prefix[4..<8], as: UTF8.self) == "ftyp" else { throw NativeProgressiveError.unsupportedLayout }
        let ftyp = try u32(0)
        guard ftyp >= 8, ftyp <= prefix.count - 8,
              String(decoding: prefix[(ftyp + 4)..<(ftyp + 8)], as: UTF8.self) == "moov" else { throw NativeProgressiveError.unsupportedLayout }
        let size = try u32(ftyp)
        guard size >= 8, size <= total - ftyp else { throw NativeProgressiveError.unsupportedLayout }
        let end = ftyp + size
        guard end <= 8 * 1024 * 1024 - 16 else { throw NativeProgressiveError.headerTooLarge }
        return end
    }
}

public actor NativeMediaStream: Hashable {
    public nonisolated let id: UUID
    public nonisolated let totalLength: Int
    public nonisolated let preparationByteCount: Int
    public nonisolated let variant: NativeMediaVariant
    public nonisolated var assetURL: URL { URL(string: "hongguo-native://\(id.uuidString.lowercased())/video.mp4")! }
    private let fetcher: any NativeRangeFetching
    private let plan: NativeMP4StreamPlan
    private let prefix: Data
    private let diskCache: NativeChunkDiskCache?
    private let onRouteFailure: (@Sendable () -> Void)?
    private var validators: NativeRangeValidators
    private struct Chunk { let data: Data; var access: UInt64 }
    private var cache: [Int: Chunk] = [:]
    private var cacheBytes = 0
    private var access: UInt64 = 0
    private(set) var decryptedChunkCount = 0
    private(set) var completedChunkFetchCount = 0
    private var permanentFailure: (any Error)?
    private var readAheadStorageFailed = false
    private var optionalDiskWrites: [UUID: Task<Void, Never>] = [:]
    private var diskWriteCount = 0
    private var committedDiskIndices: Set<Int> = []
    private var recentDiskIndices: [Int] = []
    private let maximumRememberedDiskIndices = 1024
    private struct RawChunk: Sendable {
        let data: Data
        let storedOnDisk: Bool
        let writeBusy: Bool
        init(data: Data, storedOnDisk: Bool, writeBusy: Bool = false) {
            self.data = data; self.storedOnDisk = storedOnDisk; self.writeBusy = writeBusy
        }
    }
    private struct Waiter {
        let continuation: CheckedContinuation<RawChunk, any Error>
        let demand: Bool
    }
    private struct Flight {
        let id: UUID
        var task: Task<Void, Never>?
        var waiters: [UUID: Waiter]
        var wantsClearBytes: Bool
        var raw: Data?
    }
    private var flights: [Int: Flight] = [:]
    private let chunkSize = 512 * 1024
    private let cacheLimit = 8 * 1024 * 1024

    init(totalLength: Int, fetcher: any NativeRangeFetching, plan: NativeMP4StreamPlan, validators: NativeRangeValidators, prefix: Data, preparationByteCount: Int? = nil,
         variant: NativeMediaVariant, diskCache: NativeChunkDiskCache? = nil, onRouteFailure: (@Sendable () -> Void)? = nil) {
        self.id = UUID(); self.totalLength = totalLength; self.fetcher = fetcher; self.plan = plan; self.validators = validators; self.prefix = prefix
        self.preparationByteCount = preparationByteCount ?? prefix.count
        self.variant = variant
        self.diskCache = diskCache
        self.onRouteFailure = onRouteFailure
    }

    deinit {
        (fetcher as? NativeRangeHTTP)?.close()
        optionalDiskWrites.values.forEach { $0.cancel() }
    }

    var isReusable: Bool { permanentFailure == nil }
    var pendingReaderCount: Int { flights.values.reduce(0) { $0 + $1.waiters.count } }
    var pendingDiskWriteCount: Int { diskWriteCount }
    public func trimCachedChunks() { cache.removeAll(); cacheBytes = 0 }

    public nonisolated func noteBufferStarvation() {
        onRouteFailure?()
    }

    public var recoverableTerminalError: (any Error)? {
        guard let permanentFailure, PlaybackRecovery.shouldRetryAssetRead(permanentFailure) else { return nil }
        return permanentFailure
    }

    public func read(range: Range<Int>) async throws -> Data {
        try Task.checkCancellation()
        guard range.lowerBound >= 0, range.upperBound <= totalLength else { throw NativeProgressiveError.invalidRange }
        guard !range.isEmpty else { return Data() }
        // The resource loader requests bounded windows; reject accidental whole-file buffering.
        guard range.count <= 8 * 1024 * 1024 else { throw NativeProgressiveError.invalidRange }
        if let permanentFailure { throw permanentFailure }
        var output = Data(); output.reserveCapacity(range.count)
        var offset = range.lowerBound
        while offset < range.upperBound {
            try Task.checkCancellation()
            if offset < prefix.count {
                let end = min(range.upperBound, prefix.count)
                output.append(prefix[offset..<end]); offset = end; continue
            }
            let index = offset / chunkSize
            let start = index * chunkSize, end = min(totalLength, start + chunkSize)
            let chunk: Data
            if var cached = cache[index] {
                access &+= 1; cached.access = access; cache[index] = cached; chunk = cached.data
            } else {
                let raw = try await sharedChunk(index: index, range: start..<end, wantsClearBytes: true)
                try Task.checkCancellation()
                if let permanentFailure { throw permanentFailure }
                // A demand may have joined a raw-only prefetch while its disk write
                // was finishing. The first demand decrypts; the others reuse this entry.
                if let cached = cache[index] { chunk = cached.data }
                else { chunk = try cacheClearChunk(raw.data, index: index, range: start..<end) }
            }
            try Task.checkCancellation()
            if let permanentFailure { throw permanentFailure }
            let upper = min(range.upperBound, end)
            output.append(chunk[(offset - start)..<(upper - start)])
            offset = upper
        }
        try Task.checkCancellation()
        return output
    }

    /// Fills the raw disk cache without allocating clear media or displacing hot playback
    /// chunks. This is deliberately a no-op for fixture/no-disk streams.
    public func prefetch(range: Range<Int>) async throws {
        try Task.checkCancellation()
        guard range.lowerBound >= 0, range.upperBound <= totalLength, range.count <= 8 * 1024 * 1024 else {
            throw NativeProgressiveError.invalidRange
        }
        if let permanentFailure { throw permanentFailure }
        guard let diskCache, !range.isEmpty else { return }
        guard !readAheadStorageFailed else { throw PlaybackPrefetchError.unsupported }
        guard diskWriteCount < 2 else { throw NativeMediaError.busy }
        try await checkDiskPrefetchAvailability(diskCache)
        var offset = max(range.lowerBound, prefix.count)
        while offset < range.upperBound {
            try Task.checkCancellation()
            if let permanentFailure { throw permanentFailure }
            guard !readAheadStorageFailed else { throw PlaybackPrefetchError.unsupported }
            guard diskWriteCount < 2 else { throw NativeMediaError.busy }
            let index = offset / chunkSize, start = index * chunkSize
            let end = min(totalLength, start + chunkSize)
            if cache[index] == nil {
                try await checkDiskPrefetchAvailability(diskCache)
                let raw = try await sharedChunk(index: index, range: start..<end, wantsClearBytes: false)
                guard raw.storedOnDisk else {
                    if raw.writeBusy { throw NativeMediaError.busy }
                    readAheadStorageFailed = true
                    throw PlaybackPrefetchError.unsupported
                }
            }
            offset = min(end, range.upperBound)
        }
        try Task.checkCancellation()
    }

    private func checkDiskPrefetchAvailability(_ diskCache: NativeChunkDiskCache) async throws {
        switch await diskCache.prefetchAvailability {
        case .available: return
        case .opening: throw NativeMediaError.busy
        case .unavailable: throw PlaybackPrefetchError.unsupported
        }
    }

    private func cacheClearChunk(_ raw: Data, index: Int, range: Range<Int>) throws -> Data {
        let clear = try plan.decrypt(data: raw, offset: range.lowerBound)
        guard clear.count == range.count else { throw NativeProgressiveError.invalidRange }
        decryptedChunkCount += 1; access &+= 1
        if let old = cache[index] { cacheBytes -= old.data.count }
        cache[index] = Chunk(data: clear, access: access); cacheBytes += clear.count
        while cacheBytes > cacheLimit, let victim = cache.min(by: { $0.value.access < $1.value.access }) {
            cacheBytes -= victim.value.data.count; cache.removeValue(forKey: victim.key)
        }
        return clear
    }

    private func sharedChunk(index: Int, range: Range<Int>, wantsClearBytes: Bool) async throws -> RawChunk {
        if let permanentFailure { throw permanentFailure }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RawChunk, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var flight = flights[index] {
                    if wantsClearBytes, let raw = flight.raw {
                        // Raw bytes are already validated. A late foreground joiner
                        // must not wait behind a speculative disk commit either.
                        continuation.resume(returning: RawChunk(data: raw, storedOnDisk: false))
                        return
                    }
                    flight.waiters[waiter] = Waiter(continuation: continuation, demand: wantsClearBytes)
                    flight.wantsClearBytes = flight.wantsClearBytes || wantsClearBytes
                    flights[index] = flight
                } else {
                    let id = UUID()
                    flights[index] = Flight(id: id, task: nil,
                        waiters: [waiter: Waiter(continuation: continuation, demand: wantsClearBytes)],
                        wantsClearBytes: wantsClearBytes, raw: nil)
                    let task = Task { [weak self] in
                        guard let self else { return }
                        await self.fetchChunk(index: index, range: range, id: id)
                    }
                    flights[index]?.task = task
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(index: index, waiter: waiter) }
        }
    }

    private func cancelWaiter(index: Int, waiter: UUID) {
        guard var flight = flights[index], let continuation = flight.waiters.removeValue(forKey: waiter) else { return }
        continuation.continuation.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flights.removeValue(forKey: index); flight.task?.cancel()
        } else { flights[index] = flight }
    }

    private func fetchChunk(index: Int, range: Range<Int>, id: UUID) async {
        defer { completedChunkFetchCount += 1 }
        do {
            var raw: Data?, diskGeneration: UUID?
            let bypassDisk = diskWriteCount > 0 && !committedDiskIndices.contains(index)
                && flights[index]?.waiters.values.contains(where: \.demand) == true
            // An optional write can occupy the cache actor. A definitely new demand
            // chunk goes straight to HTTP rather than waiting for a guaranteed miss.
            if !bypassDisk, let diskCache {
                let lookup = await diskCache.lookup(streamID: self.id, index: index, expectedBytes: range.count)
                raw = lookup.data
                diskGeneration = lookup.acceptsWrites ? lookup.generation : nil
            }
            try Task.checkCancellation()
            guard flights[index]?.id == id else { return }
            if !bypassDisk, diskCache != nil {
                if raw != nil { rememberDiskIndex(index) }
                else { committedDiskIndices.remove(index); recentDiskIndices.removeAll { $0 == index } }
            }
            let hitDisk = raw != nil
            if raw == nil {
                let response = try await fetcher.fetch(range: range)
                try Task.checkCancellation()
                guard flights[index]?.id == id else { return }
                try NativeProgressiveMedia.validate(response, requested: range, total: totalLength, validators: validators)
                if validators.etag == nil { validators.etag = response.validators.etag }
                if validators.lastModified == nil { validators.lastModified = response.validators.lastModified }
                raw = response.data
            }
            guard let raw, raw.count == range.count else { throw NativeProgressiveError.invalidRange }
            flights[index]?.raw = raw
            if flights[index]?.wantsClearBytes == true { _ = try cacheClearChunk(raw, index: index, range: range) }
            try Task.checkCancellation()
            guard flights[index]?.id == id else { return }
            if let current = flights[index], current.waiters.values.contains(where: \.demand) {
                // Playback never waits for the optional disk write. Keep only speculative
                // consumers waiting for commit, since read-ahead must stop on write failure.
                var remaining = current
                let delivered = current.waiters.filter { $0.value.demand }
                remaining.waiters = current.waiters.filter { !$0.value.demand }
                if remaining.waiters.isEmpty {
                    flights.removeValue(forKey: index)
                    if !hitDisk, let diskCache, let diskGeneration {
                        scheduleOptionalWrite(raw, index: index, generation: diskGeneration, diskCache: diskCache)
                    }
                } else { flights[index] = remaining }
                let value = RawChunk(data: raw, storedOnDisk: hitDisk)
                delivered.values.forEach { $0.continuation.resume(returning: value) }
                if remaining.waiters.isEmpty { return }
            }
            var storedOnDisk = hitDisk
            var writeBusy = bypassDisk
            if !hitDisk, let diskCache, let diskGeneration {
                if diskWriteCount < 2 {
                    diskWriteCount += 1
                    storedOnDisk = await diskCache.store(raw, streamID: self.id, index: index, generation: diskGeneration)
                    diskWriteCount -= 1
                    if storedOnDisk, !Task.isCancelled, permanentFailure == nil { rememberDiskIndex(index) }
                } else { writeBusy = true }
            }
            try Task.checkCancellation()
            guard flights[index]?.id == id else { return }
            let completed = flights.removeValue(forKey: index)
            let value = RawChunk(data: raw, storedOnDisk: storedOnDisk, writeBusy: writeBusy)
            completed?.waiters.values.forEach { $0.continuation.resume(returning: value) }
        } catch {
            guard flights[index]?.id == id else { return }
            if Self.terminal(error) {
                if (error as? NativeProgressiveError) == .changedSource || (error as? NativeMediaError) == .unsafeURL {
                    onRouteFailure?()
                }
                permanentFailure = error; trimCachedChunks()
                committedDiskIndices = []; recentDiskIndices = []
                let abandoned = flights.values; flights.removeAll()
                for flight in abandoned { flight.task?.cancel() }
                optionalDiskWrites.values.forEach { $0.cancel() }
                for flight in abandoned {
                    flight.waiters.values.forEach { $0.continuation.resume(throwing: error) }
                }
                if let diskCache { await diskCache.remove(streamID: self.id) }
            } else {
                let completed = flights.removeValue(forKey: index)
                completed?.waiters.values.forEach { $0.continuation.resume(throwing: error) }
            }
        }
    }

    private func scheduleOptionalWrite(_ raw: Data, index: Int, generation: UUID, diskCache: NativeChunkDiskCache) {
        guard diskWriteCount < 2 else { return }
        diskWriteCount += 1
        let writeID = UUID(), streamID = id
        optionalDiskWrites[writeID] = Task(priority: .utility) { [weak self] in
            let stored = await diskCache.store(raw, streamID: streamID, index: index, generation: generation)
            await self?.finishedOptionalWrite(writeID, index: index, stored: stored)
        }
    }

    private func finishedOptionalWrite(_ writeID: UUID, index: Int, stored: Bool) {
        guard optionalDiskWrites.removeValue(forKey: writeID) != nil else { return }
        diskWriteCount -= 1
        if stored, permanentFailure == nil { rememberDiskIndex(index) }
        if !stored { readAheadStorageFailed = true }
    }

    private func rememberDiskIndex(_ index: Int) {
        committedDiskIndices.insert(index)
        recentDiskIndices.removeAll { $0 == index }; recentDiskIndices.append(index)
        while recentDiskIndices.count > maximumRememberedDiskIndices {
            committedDiskIndices.remove(recentDiskIndices.removeFirst())
        }
    }

    private static func terminal(_ error: any Error) -> Bool {
        if case CatalogError.unauthorized = error { return true }
        if case CatalogError.httpStatus(401) = error { return true }
        if case CatalogError.httpStatus(403) = error { return true }
        if case NativeMediaError.httpStatus(401) = error { return true }
        if case NativeMediaError.httpStatus(403) = error { return true }
        if error is NativeProgressiveError { return true }
        if let media = error as? NativeMediaError {
            switch media {
            case .network, .busy: return false
            case .httpStatus(let status): return !(500...599).contains(status)
            default: return true
            }
        }
        return false
    }

    public nonisolated static func == (lhs: NativeMediaStream, rhs: NativeMediaStream) -> Bool { lhs.id == rhs.id }
    public nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
