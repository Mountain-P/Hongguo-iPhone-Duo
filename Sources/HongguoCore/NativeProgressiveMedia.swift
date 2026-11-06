// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public actor NativeProgressiveMedia {
    public static let shared = NativeProgressiveMedia()
    public init() {}

    public func prepare(source: NativeMediaSource, episodeID: String, fresh: Bool = false) async throws -> NativeMediaStream {
        try validateID(episodeID)
        try NativeMediaPolicy.validate(source)
        try Task.checkCancellation()
        let fetcher = try NativeRangeHTTP(source: source)
        do {
            return try await withThrowingTaskGroup(of: NativeMediaStream.self) { group in
                group.addTask { try await self.prepare(source: source, fetcher: fetcher) }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw NativeSourceError(code: "ETIMEDOUT")
                }
                defer { group.cancelAll() }
                guard let stream = try await group.next() else { throw NativeProgressiveError.invalidRange }
                return stream
            }
        }
        catch { fetcher.close(); throw error }
    }

    // Injectable byte source allows deterministic header, aux, LRU and cancellation tests.
    func prepare(source: NativeMediaSource, fetcher: any NativeRangeFetching) async throws -> NativeMediaStream {
        let first = try await fetcher.fetch(range: 0..<(256 * 1024))
        try Self.validate(first, requested: 0..<(256 * 1024), total: nil, validators: nil)
        var prefix = first.data
        let moovEnd = try Self.headerEnd(prefix, total: first.totalLength)
        let requiredPrefix = min(first.totalLength, moovEnd + min(16, first.totalLength - moovEnd))
        if prefix.count < requiredPrefix {
            let remaining = prefix.count..<requiredPrefix
            let next = try await fetcher.fetch(range: remaining)
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
                return NativeMediaStream(totalLength: first.totalLength, fetcher: fetcher, plan: plan, validators: first.validators, prefix: clearPrefix)
            } catch let requirements as NativeMP4StreamRequirements {
                guard round < 3, !requirements.ranges.isEmpty, requirements.ranges.count <= 512 else { throw NativeProgressiveError.auxiliaryLimit }
                for range in requirements.ranges {
                    guard range.lowerBound >= 0, range.upperBound <= first.totalLength, !range.isEmpty,
                          range.count <= 8 * 1024 * 1024 - auxiliaryBytes else { throw NativeProgressiveError.auxiliaryLimit }
                    let response = try await fetcher.fetch(range: range)
                    try Self.validate(response, requested: range, total: first.totalLength, validators: first.validators)
                    auxiliaryBytes += response.data.count
                    auxiliary.append(NativeMP4ByteRegion(offset: range.lowerBound, data: response.data))
                }
            }
        }
        throw NativeProgressiveError.auxiliaryLimit
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
    public nonisolated var assetURL: URL { URL(string: "hongguo-native://\(id.uuidString.lowercased())/video.mp4")! }
    private let fetcher: any NativeRangeFetching
    private let plan: NativeMP4StreamPlan
    private let prefix: Data
    private var validators: NativeRangeValidators
    private struct Chunk { let data: Data; var access: UInt64 }
    private var cache: [Int: Chunk] = [:]
    private var cacheBytes = 0
    private var access: UInt64 = 0
    private var permanentFailure: (any Error)?
    private let chunkSize = 512 * 1024
    private let cacheLimit = 8 * 1024 * 1024

    init(totalLength: Int, fetcher: any NativeRangeFetching, plan: NativeMP4StreamPlan, validators: NativeRangeValidators, prefix: Data) {
        self.id = UUID(); self.totalLength = totalLength; self.fetcher = fetcher; self.plan = plan; self.validators = validators; self.prefix = prefix
    }

    deinit { (fetcher as? NativeRangeHTTP)?.close() }

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
                do {
                    let response = try await fetcher.fetch(range: start..<end)
                    try Task.checkCancellation()
                    try NativeProgressiveMedia.validate(response, requested: start..<end, total: totalLength, validators: validators)
                    if validators.etag == nil { validators.etag = response.validators.etag }
                    if validators.lastModified == nil { validators.lastModified = response.validators.lastModified }
                    chunk = try plan.decrypt(data: response.data, offset: start)
                    guard chunk.count == end - start else { throw NativeProgressiveError.invalidRange }
                    try Task.checkCancellation()
                    access &+= 1
                    if let old = cache[index] { cacheBytes -= old.data.count }
                    cache[index] = Chunk(data: chunk, access: access); cacheBytes += chunk.count
                    while cacheBytes > cacheLimit, let victim = cache.min(by: { $0.value.access < $1.value.access }) {
                        cacheBytes -= victim.value.data.count; cache.removeValue(forKey: victim.key)
                    }
                } catch {
                    if Self.terminal(error) { permanentFailure = error; cache.removeAll(); cacheBytes = 0 }
                    throw error
                }
            }
            let upper = min(range.upperBound, end)
            output.append(chunk[(offset - start)..<(upper - start)])
            offset = upper
        }
        try Task.checkCancellation()
        return output
    }

    private static func terminal(_ error: any Error) -> Bool {
        if case CatalogError.unauthorized = error { return true }
        if case CatalogError.httpStatus(403) = error { return true }
        if case NativeProgressiveError.changedSource = error { return true }
        return false
    }

    public nonisolated static func == (lhs: NativeMediaStream, rhs: NativeMediaStream) -> Bool { lhs.id == rhs.id }
    public nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
