import Foundation
import CryptoKit
import Combine
import HongguoCore

@MainActor
final class AccountLibraryController: ObservableObject {
    @Published private(set) var accountProfile: AccountProfile?
    @Published private(set) var selectedOwner: LibraryOwner = .guest
    @Published private(set) var favorites: [Series] = []
    @Published private(set) var history: [WatchRecord] = []
    @Published private(set) var syncing = false
    @Published private(set) var syncPhase = ""
    @Published private(set) var loadingMetadata = false
    @Published private(set) var syncError: String?
    @Published private(set) var lastSync: Date?
    @Published private(set) var needsLogin = false
    @Published private(set) var coverageText: String?
    @Published var persistenceError: String?

    private let persistence: LibraryPersistence
    private let defaults: UserDefaults
    private let metadataLoader: @Sendable (String) async throws -> SeriesDetail
    private let clock: @Sendable () -> Date
    private let saveSession: @MainActor (AccountSession) throws -> Void
    private let removeSession: @MainActor () throws -> Void
    private let makeCloud: @Sendable (AccountSession) throws -> NativeAccountLibraryService
    private var states: [LibraryScope: LibraryState] = [:]
    private var blockedScopes: Set<LibraryScope> = []
    private var sourceID = ""
    private var allowsAccount = true
    private var session: AccountSession?
    private var service: NativeAccountLibraryService?
    private var generation = UUID()
    private var scheduled: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private(set) var metadataTask: Task<Void, Never>?
    private var episodeDetails = LibraryDetailCache()
    private var metadataScheduler = MetadataHydrationScheduler()
    private var metadataGeneration = MetadataHydrationGeneration()
    private var loadTasks: [LibraryScope: Task<LibraryState, any Error>] = [:]
    private var legacySnapshots: [LibraryScope: Data] = [:]
    private var restoreTask: Task<Void, Never>?
    private var mutationTasks: [UUID: Task<Void, Never>] = [:]
    private var mutationTails: [LibraryScope: UUID] = [:]
    private var revisions: [LibraryScope: UInt64] = [:]
    private var dirtyScopes: Set<LibraryScope> = []
    private var saveTasks: [LibraryScope: Task<Void, Never>] = [:]
    private var favoriteRetryRotations: [LibraryScope: LibraryRetryRotation] = [:]
    private var progressRetryRotations: [LibraryScope: LibraryRetryRotation] = [:]

    var showingAccountLibrary: Bool { if case .account = selectedOwner { true } else { false } }
    var pendingCount: Int {
        guard showingAccountLibrary, let state = states[scope] else { return 0 }
        return state.pendingFavorites.count + state.pendingProgress.filter { $0.record != nil }.count
    }
    var retryRequiredCount: Int {
        guard showingAccountLibrary else { return 0 }
        return states[scope]?.retryRequiredCount ?? 0
    }
    private var automaticPendingCount: Int {
        guard showingAccountLibrary else { return 0 }
        return states[scope]?.automaticPendingCount ?? 0
    }
    private var scope: LibraryScope { .init(owner: selectedOwner, sourceID: sourceID) }

    convenience init() {
        var restored: AccountSession?, failed = false
        do { restored = try AccountSessionVault.load() } catch { failed = true }
        self.init(persistence: LibraryPersistence(), defaults: .standard, initialSession: restored,
                  saveSession: AccountSessionVault.save, removeSession: AccountSessionVault.remove)
        if failed { needsLogin = true }
    }

    /// Isolated clients can inject storage and never consult the real Keychain.
    init(persistence: LibraryPersistence, defaults: UserDefaults, initialSession: AccountSession? = nil,
         metadataLoader: @escaping @Sendable (String) async throws -> SeriesDetail = { try await NativeCatalogService().detail(id: $0) },
         clock: @escaping @Sendable () -> Date = { Date() },
         saveSession: @escaping @MainActor (AccountSession) throws -> Void = { _ in },
         removeSession: @escaping @MainActor () throws -> Void = {},
         makeCloud: @escaping @Sendable (AccountSession) throws -> NativeAccountLibraryService = { try NativeAccountLibraryService(session: $0) }) {
        self.persistence = persistence; self.defaults = defaults; self.metadataLoader = metadataLoader; self.clock = clock
        self.saveSession = saveSession; self.removeSession = removeSession
        self.makeCloud = makeCloud
        session = initialSession
        if let restored = session, !restored.isNativeAppSession { session = nil; needsLogin = true }
        accountProfile = session?.profile
        if let session, defaults.bool(forKey: "library.prefersAccount") { selectedOwner = .account(id: session.profile.id) }
    }

    func selectSource(_ source: String, legacy: Data?, allowsAccount: Bool) {
        if sourceID != source || self.allowsAccount != allowsAccount {
            cancelSynchronization(); episodeDetails.removeAll()
        }
        sourceID = source; self.allowsAccount = allowsAccount
        if !allowsAccount { selectedOwner = .guest }
        else if let session, defaults.bool(forKey: "library.prefersAccount") {
            selectedOwner = .account(id: session.profile.id)
        }
        let guestScope = LibraryScope(owner: .guest, sourceID: source)
        if states[guestScope] == nil, let legacy { legacySnapshots[guestScope] = legacy }
        restoreSelected()
    }

    func selectOwner(_ owner: LibraryOwner) {
        if case .account(let id) = owner {
            guard allowsAccount, id == session?.profile.id else { return }
        }
        guard selectedOwner != owner else { return }
        cancelSynchronization(); selectedOwner = owner
        defaults.set(showingAccountLibrary, forKey: "library.prefersAccount")
        favorites = []; history = []; lastSync = nil
        restoreSelected()
        scheduleSync(immediate: true)
    }

    func accept(_ newSession: AccountSession) {
        do {
            _ = try NativePhoneAuthService.validateForLibrary(session: newSession)
            let newService = try makeCloud(newSession)
            try saveSession(newSession)
            cancelSynchronization()
            session = newSession; accountProfile = newSession.profile; service = newService
            needsLogin = false; syncError = nil
            selectedOwner = allowsAccount ? .account(id: newSession.profile.id) : .guest
            favorites = []; history = []; lastSync = nil
            defaults.set(allowsAccount, forKey: "library.prefersAccount")
            restoreSelected()
            scheduleSync(immediate: true)
        } catch { persistenceError = error.localizedDescription }
    }

    func signOut() {
        do { try removeSession() }
        catch { persistenceError = error.localizedDescription; return }
        cancelSynchronization()
        session = nil; accountProfile = nil; selectedOwner = .guest; needsLogin = false
        favorites = []; history = []; lastSync = nil
        defaults.set(false, forKey: "library.prefersAccount")
        restoreSelected()
    }

    func importGuest() {
        guard showingAccountLibrary else { return }
        let context = scope, guestScope = LibraryScope(owner: .guest, sourceID: sourceID)
        let guestMutation = mutationTails[guestScope].flatMap { mutationTasks[$0] }
        enqueueMutation(in: context) { [weak self] in
            guard let self else { return }
            await guestMutation?.value
            let guest = try await self.loadedState(for: guestScope)
            _ = try await self.loadedState(for: context)
            var account = try self.state(for: context)
            try account.importGuest(guest)
            try self.commit(account)
            if context == self.scope { self.scheduleSync(immediate: true) }
        }
    }

    func isFavorite(_ series: Series) -> Bool { states[scope]?.isFavorite(series.id) ?? false }
    func record(for series: Series) -> WatchRecord? { states[scope]?.record(for: series.id) }

    func toggleFavorite(_ series: Series) {
        mutate(scope, syncDelay: .seconds(2)) { state in
            try state.setFavorite(series, isFavorite: !state.isFavorite(series.id))
        }
    }

    func clearHistory() {
        let date = Date()
        mutate(scope) { $0.clearHistory(at: date) }
    }

    func removeHistory(_ series: Series) {
        let date = Date()
        mutate(scope) { $0.removeHistory(seriesID: series.id, at: date) }
    }

    func removeHistory(seriesIDs: Set<String>) {
        guard !seriesIDs.isEmpty else { return }
        let date = clock()
        mutate(scope) { state in
            state = try LibraryManagement.removingHistory(seriesIDs: seriesIDs, from: state, at: date)
        }
    }

    func removeFavorites(seriesIDs: Set<String>) {
        guard !seriesIDs.isEmpty else { return }
        let date = clock()
        mutate(scope, syncDelay: .seconds(2)) { state in
            state = try LibraryManagement.removingFavorites(seriesIDs: seriesIDs, from: state, at: date)
        }
    }

    func progressHandler(for series: Series, episodes: [Episode]) -> (Episode, Double, Double) -> Void {
        let capturedScope = scope
        if !episodes.isEmpty { episodeDetails.insert(.init(series: series, episodes: episodes)) }
        return { [weak self] episode, seconds, duration in
            guard let self, seconds.isFinite, duration.isFinite, seconds >= 0 else { return }
            let record = WatchRecord(series: series, episode: episode, seconds: seconds, duration: max(duration, 0),
                                     episodeCount: episodes.isEmpty ? nil : episodes.count)
            self.mutate(capturedScope, syncDelay: .seconds(30)) { try $0.record(record) }
        }
    }

    /// A lifecycle barrier: queued mutations must load their original scope before the newest snapshot reaches disk.
    func flush() async {
        await Task.yield()
        await restoreTask?.value
        while !mutationTasks.isEmpty {
            for task in Array(mutationTasks.values) { await task.value }
        }
        var failed: Set<LibraryScope> = []
        while let context = dirtyScopes.first(where: { !failed.contains($0) }) {
            guard let state = states[context], let revision = revisions[context] else { dirtyScopes.remove(context); continue }
            do {
                try await persistence.save(state, revision: revision)
                if revisions[context] == revision { dirtyScopes.remove(context) }
            } catch { failed.insert(context); persistenceError = error.localizedDescription }
        }
    }

    func scheduleSync(immediate: Bool = false, delay: Duration = .seconds(2)) {
        guard showingAccountLibrary, allowsAccount, session != nil, !needsLogin else { return }
        if immediate { scheduled?.cancel(); scheduled = nil }
        guard scheduled == nil, !syncing else { return }
        let token = generation
        scheduled = Task { @MainActor [weak self] in
            do { if !immediate { try await Task.sleep(for: delay) } }
            catch { return }
            guard let self, self.generation == token, !Task.isCancelled else { return }
            self.scheduled = nil
            await self.synchronize()
        }
    }

    func synchronize(userInitiated: Bool = false) async {
        guard !syncing, showingAccountLibrary, allowsAccount, let session else { return }
        scheduled?.cancel(); scheduled = nil
        let token = generation, context = scope
        syncing = true; syncPhase = "正在讀取觀看紀錄"; syncError = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var continueAutomatically = false
            defer {
                if self.generation == token {
                    self.syncing = false; self.syncPhase = ""; self.syncTask = nil
                    if continueAutomatically, self.automaticPendingCount > 0, !self.needsLogin {
                        self.scheduleSync(delay: .seconds(30))
                    }
                }
            }
            do {
                _ = try await self.loadedState(for: context)
                try self.check(token, scope: context)
                let profile = try NativePhoneAuthService.validateForLibrary(session: session)
                try self.check(token, scope: context)
                self.accountProfile = profile; self.needsLogin = false
                let cloud: NativeAccountLibraryService
                if let existing = self.service { cloud = existing }
                else { cloud = try self.makeCloud(session); self.service = cloud }

                var failures: [String] = []
                var remoteHistory: AccountLibrarySnapshot?
                var remoteFavorites: AccountLibrarySnapshot?
                do { remoteHistory = try await cloud.history(fresh: true) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    if Self.requiresLogin(error) { throw AccountError.expired }
                    failures.append(error.localizedDescription)
                }
                try self.check(token, scope: context)
                if let remoteHistory {
                    let snapshot = try self.makeSnapshot(history: remoteHistory, favorites: nil, token: token, scope: context)
                    var current = try self.state(for: context)
                    try current.merge(remote: snapshot, scope: context)
                    try self.commit(current)
                }
                self.syncPhase = "正在讀取收藏"
                do { remoteFavorites = try await cloud.favorites(fresh: true) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    if Self.requiresLogin(error) { throw AccountError.expired }
                    failures.append(error.localizedDescription)
                }
                try self.check(token, scope: context)

                let remote = try self.makeSnapshot(history: remoteHistory, favorites: remoteFavorites, token: token, scope: context)
                var local = try self.state(for: context)
                try local.merge(remote: remote, scope: context, favoritesAreComplete: remoteFavorites?.isComplete == true)
                try self.commit(local)
                self.coverageText = remoteHistory?.isComplete == false ? "官方近期觀看紀錄已載入；較早紀錄以來源提供的範圍為準。" : nil
                self.refreshMetadata(history: remoteHistory, favorites: remoteFavorites)

                // Favorite operations are explicit desired states. Progress is uploaded only after a successful pull.
                self.syncPhase = "正在同步收藏變更"
                let favorites = self.favoriteBatch(local, manualRetry: userInitiated, scope: context)
                for selected in favorites {
                    try self.check(token, scope: context)
                    // Persist the gate before any await/write. A crash, cancellation,
                    // or lost reply must not turn this into an automatic resend.
                    guard let mutation = try await self.beginFavoriteAttempt(selected.operationID, manualRetry: userInitiated, scope: context) else { continue }
                    try self.check(token, scope: context)
                    if userInitiated { self.favoriteRetryRotations[context]?.didAttempt(mutation.operationID) }
                    do {
                        if userInitiated { _ = await cloud.resetFailedMutation(mutation.operationID) }
                        try self.check(token, scope: context)
                        guard try self.state(for: context).pendingFavorites.contains(where: { $0.operationID == mutation.operationID }) else { continue }
                        let receipt = try await cloud.setFavorite(seriesID: mutation.seriesID, value: mutation.isFavorite,
                                                                  mutationID: mutation.operationID)
                        try self.check(token, scope: context)
                        guard receipt.accountID == session.profile.id, receipt.kind == .favorite else { throw AccountError.expired }
                        guard receipt.mutationID == mutation.operationID else { throw UserLibraryError.invalidMutation }
                        var current = try self.state(for: context)
                        current.acknowledgeFavorites(operationIDs: [receipt.mutationID]); try self.commit(current)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        if Self.requiresLogin(error) { throw AccountError.expired }
                        failures.append(error.localizedDescription)
                    }
                }
                if remoteHistory != nil {
                    self.syncPhase = "正在同步觀看進度"
                    let pending = self.progressBatch(try self.state(for: context), manualRetry: userInitiated, scope: context)
                    for selected in pending {
                        try self.check(token, scope: context)
                        guard let mutation = try await self.beginProgressAttempt(selected.operationID, manualRetry: userInitiated, scope: context) else { continue }
                        try self.check(token, scope: context)
                        if userInitiated { self.progressRetryRotations[context]?.didAttempt(mutation.operationID) }
                        do {
                            if userInitiated { _ = await cloud.resetFailedMutation(mutation.operationID) }
                            let progress = try await self.makeProgress(mutation.record!, token: token, scope: context)
                            try self.check(token, scope: context)
                            guard try self.state(for: context).pendingProgress.contains(where: { $0.operationID == mutation.operationID }) else { continue }
                            let receipt = try await cloud.reportProgress(progress, mutationID: mutation.operationID)
                            try self.check(token, scope: context)
                            guard receipt.accountID == session.profile.id, receipt.kind == .progress else { throw AccountError.expired }
                            guard receipt.mutationID == mutation.operationID else { throw UserLibraryError.invalidMutation }
                            var current = try self.state(for: context)
                            current.acknowledgeProgress(operationIDs: [receipt.mutationID]); try self.commit(current)
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            if Self.requiresLogin(error) { throw AccountError.expired }
                            failures.append(error.localizedDescription)
                        }
                    }
                }
                try self.check(token, scope: context)
                let remaining = try self.state(for: context)
                continueAutomatically = !remaining.eligibleFavorites().isEmpty
                    || (remoteHistory != nil && !remaining.eligibleProgress().isEmpty)
                if failures.isEmpty {
                    self.lastSync = Date()
                    self.defaults.set(self.lastSync, forKey: self.syncDateKey)
                } else { self.syncError = Array(Set(failures)).sorted().joined(separator: "\n") }
            } catch is CancellationError { return }
            catch {
                guard self.generation == token else { return }
                self.syncError = error.localizedDescription
                if case AccountError.expired = error { self.needsLogin = true }
                if case AccountError.authenticationFailed = error { self.needsLogin = true }
            }
        }
        syncTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func favoriteBatch(_ state: LibraryState, manualRetry: Bool, scope context: LibraryScope) -> [FavoriteMutation] {
        let eligible = state.eligibleFavorites(manualRetry: manualRetry)
        guard manualRetry else { return Array(eligible.prefix(20)) }
        var rotation = favoriteRetryRotations[context] ?? LibraryRetryRotation()
        let selected = rotation.select(from: eligible.map(\.operationID), limit: 20)
        favoriteRetryRotations[context] = rotation
        let values = Dictionary(uniqueKeysWithValues: eligible.map { ($0.operationID, $0) })
        return selected.compactMap { values[$0] }
    }

    private func progressBatch(_ state: LibraryState, manualRetry: Bool, scope context: LibraryScope) -> [ProgressMutation] {
        let eligible = state.eligibleProgress(manualRetry: manualRetry)
        guard manualRetry else { return Array(eligible.prefix(10)) }
        var rotation = progressRetryRotations[context] ?? LibraryRetryRotation()
        let selected = rotation.select(from: eligible.map(\.operationID), limit: 10)
        progressRetryRotations[context] = rotation
        let values = Dictionary(uniqueKeysWithValues: eligible.map { ($0.operationID, $0) })
        return selected.compactMap { values[$0] }
    }

    private func beginFavoriteAttempt(_ id: UUID, manualRetry: Bool, scope context: LibraryScope) async throws -> FavoriteMutation? {
        var current = try state(for: context)
        guard let mutation = current.pendingFavorites.first(where: { $0.operationID == id }),
              manualRetry || !mutation.retryRequired, current.markFavoriteAttempt(operationID: id) else { return nil }
        try await durablyCommit(current)
        return mutation
    }

    private func beginProgressAttempt(_ id: UUID, manualRetry: Bool, scope context: LibraryScope) async throws -> ProgressMutation? {
        var current = try state(for: context)
        guard let mutation = current.pendingProgress.first(where: { $0.operationID == id && !$0.isDeletion }),
              manualRetry || !mutation.retryRequired, current.markProgressAttempt(operationID: id) else { return nil }
        try await durablyCommit(current)
        return mutation
    }

    private func makeSnapshot(history remoteHistory: AccountLibrarySnapshot?, favorites remoteFavorites: AccountLibrarySnapshot?,
                              token: UUID, scope context: LibraryScope) throws -> LibrarySnapshot {
        if let remoteHistory, case .account(let id) = context.owner, remoteHistory.accountID != id { throw AccountError.expired }
        if let remoteFavorites, case .account(let id) = context.owner, remoteFavorites.accountID != id { throw AccountError.expired }
        let local = try state(for: context)
        let known = Dictionary((local.favorites + local.history.map(\.series)).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var favorites: [Series] = [], history: [WatchRecord] = []
        for item in remoteFavorites?.items ?? [] {
            try check(token, scope: context)
            let series = completeSeries(item.series, known: known)
            favorites.append(series)
        }
        for item in remoteHistory?.items ?? [] {
            try check(token, scope: context)
            if let record = remoteRecord(item, series: completeSeries(item.series, known: known)) { history.append(record) }
        }
        try check(token, scope: context)
        return .init(favorites: favorites, history: history)
    }

    private func completeSeries(_ remote: Series, known: [String: Series]) -> Series {
        guard remote.title.isEmpty || remote.cover.isEmpty else { return remote }
        if let detail = episodeDetails.value(for: remote.id, now: clock()) { return detail.series }
        if let series = known[remote.id], !series.title.isEmpty { return series }
        var placeholder = remote
        if placeholder.title.isEmpty { placeholder.title = "劇集資料載入中" }
        return placeholder
    }

    private func remoteRecord(_ item: AccountLibraryItem, series: Series, detail: SeriesDetail? = nil) -> WatchRecord? {
        let episode: Episode?
        if let detail {
            episode = detail.episodes.first { $0.id == item.episodeID }
                ?? detail.episodes.first { $0.number == item.episodeNumber }
        } else if !item.episodeID.isEmpty, item.episodeNumber > 0 {
            episode = .init(id: item.episodeID, number: item.episodeNumber, title: "第 \(item.episodeNumber) 集")
        } else { episode = nil }
        guard let episode else { return nil }
        let date = item.updatedAtMilliseconds.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date(timeIntervalSince1970: 0)
        return .init(series: series, episode: episode, seconds: item.positionSeconds, duration: item.durationSeconds,
                     updatedAt: date, episodeCount: detail?.episodes.count)
    }

    private enum MetadataResult: Sendable { case detail(String, SeriesDetail), missing(String), cancelled, timeout }

    func refreshMetadata(history: AccountLibrarySnapshot?, favorites: AccountLibrarySnapshot?) {
        guard states[scope] != nil else { return }
        hydrateMetadata(history: history, favorites: favorites, token: generation, scope: scope)
    }

    /// The account list is already committed. Poster/detail lookups cannot delay its appearance.
    private func hydrateMetadata(history: AccountLibrarySnapshot?, favorites: AccountLibrarySnapshot?, token: UUID, scope context: LibraryScope) {
        metadataTask?.cancel()
        metadataTask = nil
        let lease = metadataGeneration.begin(scope: context)
        let items = (history?.items ?? []) + (favorites?.items ?? [])
        let unresolvedEpisodes = Set((history?.items ?? []).filter { $0.episodeID.isEmpty || $0.episodeNumber <= 0 }.map(\.id))
        let known = Dictionary(((states[context]?.favorites ?? []) + (states[context]?.history.map(\.series) ?? []))
            .map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let candidates = items.filter { item in
            let series = known[item.id] ?? item.series
            let needsMetadata = series.title.isEmpty || series.title == "劇集資料載入中" || series.cover.isEmpty || unresolvedEpisodes.contains(item.id)
            return needsMetadata && episodeDetails.value(for: item.id, now: clock()) == nil
        }.map(\.id)
        let ids = metadataScheduler.batch(candidates: candidates, now: clock())
        guard !ids.isEmpty else { loadingMetadata = false; return }
        loadingMetadata = true
        metadataTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token, self.metadataGeneration.accepts(lease) {
                    self.loadingMetadata = false; self.metadataTask = nil
                }
            }
            await withTaskGroup(of: MetadataResult.self) { group in
                var cursor = ids.makeIterator(), outstanding = 0
                var unfinished = Set(ids)
                let loader = self.metadataLoader
                func enqueue(_ id: String) {
                    outstanding += 1
                    group.addTask {
                        do {
                            let detail = try await loader(id)
                            guard detail.series.id == id else { return .missing(id) }
                            return .detail(id, detail)
                        } catch is CancellationError { return .cancelled }
                        catch { return .missing(id) }
                    }
                }
                for _ in 0..<min(4, ids.count) { if let id = cursor.next() { enqueue(id) } }
                group.addTask { try? await Task.sleep(for: .seconds(45)); return .timeout }
                while let result = await group.next() {
                    guard !Task.isCancelled, self.generation == token, self.scope == context,
                          self.metadataGeneration.accepts(lease) else { group.cancelAll(); return }
                    switch result {
                    case .timeout:
                        unfinished.forEach { self.metadataScheduler.completed($0, succeeded: false, now: self.clock()) }
                        group.cancelAll(); return
                    case .cancelled: break
                    case .missing(let id):
                        unfinished.remove(id); self.metadataScheduler.completed(id, succeeded: false, now: self.clock())
                    case .detail(let id, let detail):
                        unfinished.remove(id); self.metadataScheduler.completed(id, succeeded: true, now: self.clock())
                        self.episodeDetails.insert(detail, now: self.clock())
                        do {
                            var current = try self.state(for: context)
                            if let item = history?.items.first(where: { $0.id == detail.series.id }),
                               let record = self.remoteRecord(item, series: detail.series, detail: detail) {
                                try current.merge(remote: .init(history: [record]), scope: context)
                            }
                            if current.favorites.contains(where: { $0.id == detail.series.id }) || current.history.contains(where: { $0.series.id == detail.series.id }) {
                                try current.enrichSeries(detail.series)
                                try self.commit(current)
                            }
                        } catch { self.persistenceError = error.localizedDescription }
                    }
                    outstanding -= 1
                    if let next = cursor.next() { enqueue(next) }
                    if outstanding == 0 { group.cancelAll(); return }
                }
            }
        }
    }

    private func makeProgress(_ record: WatchRecord, token: UUID, scope context: LibraryScope) async throws -> AccountWatchProgress {
        let timestamp = record.updatedAt.timeIntervalSince1970 * 1000
        guard timestamp.isFinite, (946_684_800_000...4_102_444_800_000).contains(timestamp) else {
            throw AppError.message("這筆觀看紀錄缺少有效的同步時間，紀錄已保留在手機。")
        }
        let detail = try await details(for: record.series.id)
        try check(token, scope: context)
        guard let episode = detail.episodes.first(where: { $0.id == record.episode.id })
                ?? detail.episodes.first(where: { $0.number == record.episode.number }) else {
            throw AppError.message("來源暫時無法確認這集的續播位置，紀錄已保留在手機。")
        }
        return .init(seriesID: record.series.id, episodeID: episode.id, episodeNumber: episode.number,
                     positionSeconds: record.seconds, durationSeconds: record.duration, episodeCount: detail.episodes.count,
                     watchedAtMilliseconds: Int64(timestamp))
    }

    private func details(for id: String) async throws -> SeriesDetail {
        if let detail = episodeDetails.value(for: id, now: clock()) { return detail }
        let token = generation
        let detail = try await metadataLoader(id)
        try Task.checkCancellation()
        if token == generation { episodeDetails.insert(detail, now: clock()) }
        return detail
    }

    private func state(for context: LibraryScope) throws -> LibraryState {
        guard !blockedScopes.contains(context) else { throw AppError.message("片庫資料無法讀取，為保留原始紀錄，暫時停止儲存。") }
        if let state = states[context] { return state }
        throw AppError.message("片庫正在載入，請稍後重試。")
    }

    private func loadedState(for context: LibraryScope) async throws -> LibraryState {
        guard !blockedScopes.contains(context) else { return try state(for: context) }
        if let state = states[context] { return state }
        let task: Task<LibraryState, any Error>
        if let existing = loadTasks[context] { task = existing }
        else {
            let persistence = persistence, legacy = legacySnapshots[context]
            task = Task { try await persistence.load(scope: context, legacy: legacy) }
            loadTasks[context] = task
        }
        do {
            let loaded = try await task.value
            // Another waiter may already have loaded and mutated this scope.
            if states[context] == nil { states[context] = loaded }
            loadTasks.removeValue(forKey: context); legacySnapshots.removeValue(forKey: context)
            return try state(for: context)
        } catch {
            loadTasks.removeValue(forKey: context); blockedScopes.insert(context)
            throw error
        }
    }

    private func mutate(_ context: LibraryScope, syncDelay: Duration? = nil,
                        _ body: @escaping @MainActor (inout LibraryState) throws -> Void) {
        let apply: @MainActor () throws -> Void = { [weak self] in
            guard let self else { return }
            var state = try self.state(for: context)
            let before = state
            try body(&state)
            guard state != before else { return }
            try self.commit(state)
            if context == self.scope, let syncDelay { self.scheduleSync(delay: syncDelay) }
        }
        if states[context] != nil, mutationTails[context] == nil {
            do { try apply() } catch { persistenceError = error.localizedDescription }
        } else {
            enqueueMutation(in: context) { [weak self] in
                guard let self else { return }
                _ = try await self.loadedState(for: context)
                try apply()
            }
        }
    }

    private func enqueueMutation(in context: LibraryScope, _ operation: @escaping @MainActor () async throws -> Void) {
        let id = UUID()
        let previous = mutationTails[context].flatMap { mutationTasks[$0] }
        mutationTails[context] = id
        mutationTasks[id] = Task { @MainActor [weak self] in
            await previous?.value
            defer {
                self?.mutationTasks.removeValue(forKey: id)
                if self?.mutationTails[context] == id { self?.mutationTails.removeValue(forKey: context) }
            }
            do { try await operation() }
            catch { self?.persistenceError = error.localizedDescription }
        }
    }

    @discardableResult
    private func commit(_ state: LibraryState) throws -> UInt64 {
        guard !blockedScopes.contains(state.scope), states[state.scope] != nil else { throw LibraryStorageError.unreadable }
        let revision = revisions[state.scope, default: 0] + 1
        revisions[state.scope] = revision
        states[state.scope] = state
        dirtyScopes.insert(state.scope)
        if state.scope == scope { favorites = state.favorites; history = state.history }
        scheduleSave(state.scope)
        return revision
    }

    /// A network mutation may begin only after the marked snapshot is durable.
    private func durablyCommit(_ state: LibraryState) async throws {
        let revision = try commit(state)
        try await persistence.save(state, revision: revision)
        if revisions[state.scope] == revision { dirtyScopes.remove(state.scope) }
    }

    private func scheduleSave(_ context: LibraryScope) {
        guard saveTasks[context] == nil else { return }
        saveTasks[context] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.saveTasks.removeValue(forKey: context) }
            while self.dirtyScopes.contains(context), let state = self.states[context], let revision = self.revisions[context] {
                do {
                    try await self.persistence.save(state, revision: revision)
                    if self.revisions[context] == revision { self.dirtyScopes.remove(context) }
                } catch {
                    self.persistenceError = error.localizedDescription
                    return
                }
            }
        }
    }

    private func restoreSelected() {
        let context = scope, token = generation
        syncError = nil; coverageText = nil
        lastSync = defaults.object(forKey: syncDateKey) as? Date
        if let state = states[context] { favorites = state.favorites; history = state.history; return }
        favorites = []; history = []
        restoreTask?.cancel()
        restoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.loadedState(for: context)
                try self.check(token, scope: context)
                let state = try self.state(for: context)
                self.favorites = state.favorites; self.history = state.history
            } catch is CancellationError { return }
            catch {
                guard self.generation == token, self.scope == context, !Task.isCancelled else { return }
                self.persistenceError = error.localizedDescription
            }
        }
    }

    private var syncDateKey: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(scope)) ?? Data()
        return "library.lastSync." + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func cancelSynchronization() {
        generation = UUID(); scheduled?.cancel(); scheduled = nil; syncTask?.cancel(); syncTask = nil
        restoreTask?.cancel(); restoreTask = nil
        metadataGeneration.invalidate(); metadataScheduler = MetadataHydrationScheduler()
        episodeDetails.removeAll()
        metadataTask?.cancel(); metadataTask = nil; loadingMetadata = false
        if let service { Task { await service.invalidate() } }
        service = nil; syncing = false; syncPhase = ""; syncError = nil; coverageText = nil
    }

    private func check(_ token: UUID, scope context: LibraryScope) throws {
        try Task.checkCancellation()
        guard token == generation, context == scope else { throw CancellationError() }
    }

    private static func requiresLogin(_ error: any Error) -> Bool {
        if let error = error as? AccountLibraryError, error.status == 401 { return true }
        return (error as? AccountError) == .expired || (error as? AccountError) == .authenticationFailed
    }
}
