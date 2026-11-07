import Foundation

public struct RecommendationProvenance: Hashable, Sendable {
    public enum Source: String, Sendable { case category, ranking, newRelease }
    public let source: Source
    public let category: DirectWebService.Category
    public let rankNumber: Int?
    public init(source: Source, category: DirectWebService.Category, rankNumber: Int? = nil) {
        self.source = source; self.category = category
        self.rankNumber = rankNumber.flatMap { (1...1_000).contains($0) ? $0 : nil }
    }
    public var label: String {
        let kind: String
        switch category { case .realDrama: kind = "真人"; case .comicDrama: kind = "漫劇"; case .aiDrama: kind = "AI" }
        switch source {
        case .category: return "\(kind)目錄"
        case .ranking: return "\(kind)熱播榜"
        case .newRelease: return "\(kind)近 7 天上新"
        }
    }
}

public protocol RecommendationProvenanceProviding: Sendable {
    func provenance(for seriesIDs: [String]) async -> [String: RecommendationProvenance]
}

/// Public catalogue candidates only. Page one never waits for a supplemental source.
/// One bounded supplemental snapshot is mixed into later pages; playback stays with `base`.
public actor RecommendationDiscoveryService: CatalogService, RecommendationProvenanceProviding {
    public static let maximumSupplementalItemsPerSource = 40
    public static let maximumProvenanceEntries = 512
    private let base: any CatalogService
    private let category: DirectWebService.Category
    private let ranking: @Sendable (DiscoveryRanking) async throws -> DiscoveryPage
    private let releases: @Sendable (NewReleaseCategory) async throws -> DiscoveryPage
    private let supplementalTimeout: Duration
    private var generation = UUID()
    private var activeID: UUID?
    private var activeOperation: DiscoveryOperation<PageInputs>?
    private var supplementalTask: Task<[Candidate], Never>?
    private var supplemental: [Candidate] = []
    private var baseBuffer: [Series] = []
    private var basePage = 0
    private var baseHasMore = true
    private var outputPage = 0
    private var seen: Set<String> = []
    private var cachedPages: [Int: SeriesPage] = [:]
    private var provenanceByID: [String: RecommendationProvenance] = [:]
    private var provenanceOrder: [String] = []

    public init(base: any CatalogService, category: DirectWebService.Category) {
        self.base = base; self.category = category; supplementalTimeout = .seconds(8)
        let web = WebDiscoveryService(), recent = NativeNewReleaseService()
        ranking = { try await web.ranking(board: $0, page: 1) }
        releases = { try await recent.releases(category: $0) }
    }

    init(base: any CatalogService, category: DirectWebService.Category, supplementalTimeout: Duration = .seconds(8),
         ranking: @escaping @Sendable (DiscoveryRanking) async throws -> DiscoveryPage,
         releases: @escaping @Sendable (NewReleaseCategory) async throws -> DiscoveryPage) {
        self.base = base; self.category = category
        self.supplementalTimeout = min(max(supplementalTimeout, .milliseconds(1)), .seconds(8))
        self.ranking = ranking; self.releases = releases
    }

    deinit { activeOperation?.cancel(); supplementalTask?.cancel() }

    public func provenance(for seriesIDs: [String]) -> [String: RecommendationProvenance] {
        var result: [String: RecommendationProvenance] = [:]
        for id in seriesIDs.prefix(Self.maximumProvenanceEntries) {
            if let value = provenanceByID[id] { result[id] = value }
        }
        return result
    }

    public func search(query: String, page: Int) async throws -> SeriesPage { try await base.search(query: query, page: page) }
    public func detail(id: String) async throws -> SeriesDetail { try await base.detail(id: id) }
    public func playback(seriesID: String, episodeID: String, fresh: Bool) async throws -> PlaybackSource {
        try await base.playback(seriesID: seriesID, episodeID: episodeID, fresh: fresh)
    }

    public func home(page: Int) async throws -> SeriesPage {
        try Task.checkCancellation(); try validatePage(page)
        if page == 1 { reset() }
        else if let cached = cachedPages[page] { return cached }
        guard page == outputPage + 1, activeID == nil else { throw CatalogError.invalidPage }
        let token = generation, request = UUID()
        let fetchBase = baseHasMore && baseBuffer.count < 94
        let nextBasePage = basePage + 1
        let base = base
        let sideTask = page == 1 ? nil : supplementalTask
        let operation = DiscoveryOperation<PageInputs>()
        activeID = request; activeOperation = operation
        defer {
            if Task.isCancelled, generation == token {
                supplementalTask?.cancel(); supplementalTask = nil
            }
            if activeID == request { activeID = nil; activeOperation = nil }
        }
        let inputs = try await operation.run {
            let primary = fetchBase ? try await base.home(page: nextBasePage) : nil
            try Task.checkCancellation()
            let secondary = await sideTask?.value
            try Task.checkCancellation()
            return PageInputs(base: primary, supplemental: secondary)
        }
        try Task.checkCancellation()
        guard generation == token, activeID == request else { throw CancellationError() }
        if let primary = inputs.base {
            guard primary.page == nextBasePage, primary.items.count <= 100,
                  primary.items.allSatisfy(Self.valid) else { throw CatalogError.malformedResponse }
        }

        var main = baseBuffer
        var localSeen = seen
        var bufferedIDs = Set(main.map(\.id))
        if let primary = inputs.base {
            main.append(contentsOf: primary.items.filter { !localSeen.contains($0.id) && bufferedIDs.insert($0.id).inserted })
        }
        guard main.count <= 200 else { throw CatalogError.responseTooLarge }
        let primaryHasMore = inputs.base.map { $0.hasMore && nextBasePage < 100 } ?? baseHasMore
        var side = inputs.supplemental ?? supplemental
        side.removeAll { localSeen.contains($0.series.id) || bufferedIDs.contains($0.series.id) }
        var emitted: [Candidate] = []
        let sideBudget = main.isEmpty && !primaryHasMore ? 20 : 6
        var sideCount = 0, mainCount = 0
        while emitted.count < 100 && (!main.isEmpty || (!side.isEmpty && sideCount < sideBudget)) {
            let takeSide = !side.isEmpty && sideCount < sideBudget && (main.isEmpty || mainCount == 4)
            let item: Candidate
            if takeSide { item = side.removeFirst(); sideCount += 1; mainCount = 0 }
            else if !main.isEmpty {
                item = Candidate(series: main.removeFirst(), provenance: .init(source: .category, category: category))
                mainCount += 1
            } else { break }
            if localSeen.insert(item.series.id).inserted { emitted.append(item) }
        }
        guard localSeen.count <= 10_000 else { throw CatalogError.responseTooLarge }
        baseBuffer = main; supplemental = side; seen = localSeen
        if inputs.base != nil { basePage = nextBasePage; baseHasMore = primaryHasMore }
        if inputs.supplemental != nil { supplementalTask = nil }
        if page == 1 { startSupplemental() }
        outputPage = page
        let more = page < 100 && seen.count < 10_000
            && (baseHasMore || !baseBuffer.isEmpty || !supplemental.isEmpty || supplementalTask != nil)
        let result = SeriesPage(items: emitted.map(\.series), page: page, hasMore: more)
        cachedPages[page] = result
        cachedPages = cachedPages.filter { $0.key >= page - 1 }
        for candidate in emitted { remember(candidate) }
        return result
    }

    private func reset() {
        generation = UUID(); activeOperation?.cancel(); activeOperation = nil; activeID = nil
        supplementalTask?.cancel(); supplementalTask = nil; supplemental = []; baseBuffer = []
        basePage = 0; baseHasMore = true; outputPage = 0; seen = []; cachedPages = [:]
        provenanceByID = [:]; provenanceOrder = []
    }

    private func startSupplemental() {
        let category = category, ranking = ranking, releases = releases, timeout = supplementalTimeout
        supplementalTask = Task {
            async let ranked = Self.loadRanking(category: category, timeout: timeout, load: ranking)
            async let recent = Self.loadReleases(category: category, timeout: timeout, load: releases)
            let (a, b) = await (ranked, recent)
            guard !Task.isCancelled else { return [] }
            var result: [Candidate] = [], ids: Set<String> = []
            for index in 0..<max(a.count, b.count) {
                for pool in [a, b] where pool.indices.contains(index) {
                    if ids.insert(pool[index].series.id).inserted { result.append(pool[index]) }
                }
            }
            return result
        }
    }

    private func remember(_ candidate: Candidate) {
        provenanceByID[candidate.series.id] = candidate.provenance
        provenanceOrder.removeAll { $0 == candidate.series.id }; provenanceOrder.append(candidate.series.id)
        while provenanceOrder.count > Self.maximumProvenanceEntries {
            provenanceByID.removeValue(forKey: provenanceOrder.removeFirst())
        }
    }

    private struct Candidate: Sendable { let series: Series; let provenance: RecommendationProvenance }
    private struct PageInputs: Sendable { let base: SeriesPage?; let supplemental: [Candidate]? }

    private static func loadRanking(category: DirectWebService.Category, timeout: Duration,
                                    load: @escaping @Sendable (DiscoveryRanking) async throws -> DiscoveryPage) async -> [Candidate] {
        let board: DiscoveryRanking
        switch category { case .realDrama: board = .realDrama; case .comicDrama: board = .comicDrama; case .aiDrama: board = .aiDrama }
        do {
            let page = try await DiscoveryOperation<DiscoveryPage>().run(timeout: timeout) { try await load(board) }
            try Task.checkCancellation()
            return candidates(page, source: .ranking, category: category)
        } catch { return [] }
    }

    private static func loadReleases(category: DirectWebService.Category, timeout: Duration,
                                     load: @escaping @Sendable (NewReleaseCategory) async throws -> DiscoveryPage) async -> [Candidate] {
        let releaseCategory: NewReleaseCategory
        switch category { case .realDrama: releaseCategory = .realDrama; case .aiDrama: releaseCategory = .aiDrama; case .comicDrama: return [] }
        do {
            let page = try await DiscoveryOperation<DiscoveryPage>().run(timeout: timeout) { try await load(releaseCategory) }
            try Task.checkCancellation()
            return candidates(page, source: .newRelease, category: category)
        } catch { return [] }
    }

    private static func candidates(_ page: DiscoveryPage, source: RecommendationProvenance.Source,
                                   category: DirectWebService.Category) -> [Candidate] {
        guard page.page == 1, page.items.count <= 500 else { return [] }
        var ids: Set<String> = []
        return page.items.prefix(100).filter { valid($0.series) && ids.insert($0.id).inserted }
            .prefix(maximumSupplementalItemsPerSource).map {
                Candidate(series: $0.series, provenance: .init(source: source, category: category, rankNumber: source == .ranking ? $0.rank : nil))
            }
    }

    private static func valid(_ series: Series) -> Bool {
        let title = series.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? validateID(series.id)) != nil && series.id.contains(where: { $0 != "0" })
            && (1...256).contains(title.count)
            && !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

/// An unstructured worker cannot hold the caller open after cancellation/deadline.
/// Only this coordinator resumes the continuation; late workers have no adapter-state access.
private final class DiscoveryOperation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func run(timeout: Duration? = nil, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(continuation, timeout: timeout, operation: operation)
            }
        } onCancel: { self.cancel() }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func install(_ continuation: CheckedContinuation<Value, any Error>, timeout: Duration?,
                         operation: @escaping @Sendable () async throws -> Value) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result); return }
        self.continuation = continuation
        lock.unlock()
        let worker = Task {
            do { try Task.checkCancellation(); self.finish(.success(try await operation())) }
            catch { self.finish(.failure(error)) }
        }
        let timer = timeout.map { duration in Task {
            do { try await Task.sleep(for: duration); self.finish(.failure(CatalogError.network)) }
            catch { }
        } }
        lock.lock()
        if result == nil { self.worker = worker; self.timer = timer; lock.unlock() }
        else { lock.unlock(); worker.cancel(); timer?.cancel() }
    }

    private func finish(_ value: Result<Value, any Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let continuation = self.continuation, worker = self.worker, timer = self.timer
        self.continuation = nil; self.worker = nil; self.timer = nil
        lock.unlock()
        worker?.cancel(); timer?.cancel()
        continuation?.resume(with: value)
    }
}
