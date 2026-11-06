import Foundation
import CryptoKit
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

    private let persistence = LibraryPersistence()
    private var states: [LibraryScope: LibraryState] = [:]
    private var blockedScopes: Set<LibraryScope> = []
    private var sourceID = ""
    private var allowsAccount = true
    private var session: AccountSession?
    private var service: NativeAccountLibraryService?
    private var generation = UUID()
    private var scheduled: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var episodeDetails: [String: SeriesDetail] = [:]

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

    init() {
        do {
            session = try AccountSessionVault.load()
            if let restored = session, !restored.isNativeAppSession { session = nil; needsLogin = true }
            accountProfile = session?.profile
            if let session, UserDefaults.standard.bool(forKey: "library.prefersAccount") {
                selectedOwner = .account(id: session.profile.id)
            }
        } catch { needsLogin = true }
    }

    func selectSource(_ source: String, legacy: Data?, allowsAccount: Bool) {
        if sourceID != source || self.allowsAccount != allowsAccount {
            cancelSynchronization(); episodeDetails.removeAll()
        }
        sourceID = source; self.allowsAccount = allowsAccount
        if !allowsAccount { selectedOwner = .guest }
        else if let session, UserDefaults.standard.bool(forKey: "library.prefersAccount") {
            selectedOwner = .account(id: session.profile.id)
        }
        let guestScope = LibraryScope(owner: .guest, sourceID: source)
        do {
            if states[guestScope] == nil {
                do { states[guestScope] = try persistence.load(scope: guestScope, legacy: legacy) }
                catch { blockedScopes.insert(guestScope); throw error }
            }
            try restoreSelected()
        } catch {
            persistenceError = error.localizedDescription; favorites = []; history = []
        }
    }

    func selectOwner(_ owner: LibraryOwner) {
        if case .account(let id) = owner {
            guard allowsAccount, id == session?.profile.id else { return }
        }
        guard selectedOwner != owner else { return }
        cancelSynchronization(); selectedOwner = owner
        UserDefaults.standard.set(showingAccountLibrary, forKey: "library.prefersAccount")
        favorites = []; history = []; lastSync = nil
        do { try restoreSelected() } catch { persistenceError = error.localizedDescription }
        scheduleSync(immediate: true)
    }

    func accept(_ newSession: AccountSession) {
        do {
            _ = try NativePhoneAuthService.validateForLibrary(session: newSession)
            let newService = try NativeAccountLibraryService(session: newSession)
            try AccountSessionVault.save(newSession)
            cancelSynchronization()
            session = newSession; accountProfile = newSession.profile; service = newService
            needsLogin = false; syncError = nil
            selectedOwner = allowsAccount ? .account(id: newSession.profile.id) : .guest
            favorites = []; history = []; lastSync = nil
            UserDefaults.standard.set(allowsAccount, forKey: "library.prefersAccount")
            try restoreSelected()
            scheduleSync(immediate: true)
        } catch { persistenceError = error.localizedDescription }
    }

    func signOut() {
        do { try AccountSessionVault.remove() }
        catch { persistenceError = error.localizedDescription; return }
        cancelSynchronization()
        session = nil; accountProfile = nil; selectedOwner = .guest; needsLogin = false
        favorites = []; history = []; lastSync = nil
        UserDefaults.standard.set(false, forKey: "library.prefersAccount")
        do { try restoreSelected() } catch { persistenceError = error.localizedDescription }
    }

    func importGuest() {
        guard showingAccountLibrary else { return }
        do {
            let guest = try state(for: .init(owner: .guest, sourceID: sourceID))
            var account = try state(for: scope)
            try account.importGuest(guest)
            try commit(account)
            scheduleSync(immediate: true)
        } catch { persistenceError = error.localizedDescription }
    }

    func isFavorite(_ series: Series) -> Bool { states[scope]?.isFavorite(series.id) ?? false }
    func record(for series: Series) -> WatchRecord? { states[scope]?.record(for: series.id) }

    func toggleFavorite(_ series: Series) {
        do {
            var state = try state(for: scope)
            try state.setFavorite(series, isFavorite: !state.isFavorite(series.id))
            try commit(state); scheduleSync()
        } catch { persistenceError = error.localizedDescription }
    }

    func clearHistory() {
        do {
            var state = try state(for: scope); state.clearHistory()
            try commit(state)
        } catch { persistenceError = error.localizedDescription }
    }

    func removeHistory(_ series: Series) {
        do {
            var state = try state(for: scope); state.removeHistory(seriesID: series.id)
            try commit(state)
        } catch { persistenceError = error.localizedDescription }
    }

    func progressHandler(for series: Series, episodes: [Episode]) -> (Episode, Double, Double) -> Void {
        let capturedScope = scope
        if !episodes.isEmpty { episodeDetails[series.id] = .init(series: series, episodes: episodes) }
        return { [weak self] episode, seconds, duration in
            guard let self, seconds.isFinite, duration.isFinite, seconds >= 0 else { return }
            do {
                var state = try self.state(for: capturedScope)
                try state.record(.init(series: series, episode: episode, seconds: seconds, duration: max(duration, 0),
                                       episodeCount: episodes.isEmpty ? nil : episodes.count))
                try self.commit(state)
                if capturedScope == self.scope { self.scheduleSync(delay: .seconds(30)) }
            } catch { self.persistenceError = error.localizedDescription }
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
                let profile = try NativePhoneAuthService.validateForLibrary(session: session)
                try self.check(token, scope: context)
                self.accountProfile = profile; self.needsLogin = false
                let cloud: NativeAccountLibraryService
                if let existing = self.service { cloud = existing }
                else { cloud = try NativeAccountLibraryService(session: session); self.service = cloud }

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
                self.hydrateMetadata(history: remoteHistory, favorites: remoteFavorites, token: token, scope: context)

                // Favorite operations are explicit desired states. Progress is uploaded only after a successful pull.
                self.syncPhase = "正在同步收藏變更"
                for selected in local.eligibleFavorites(manualRetry: userInitiated).prefix(20) {
                    try self.check(token, scope: context)
                    // Persist the gate before any await/write. A crash, cancellation,
                    // or lost reply must not turn this into an automatic resend.
                    guard let mutation = try self.beginFavoriteAttempt(selected.operationID, manualRetry: userInitiated, scope: context) else { continue }
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
                    let pending = try self.state(for: context).eligibleProgress(manualRetry: userInitiated)
                    for selected in pending.prefix(10) {
                        try self.check(token, scope: context)
                        guard let mutation = try self.beginProgressAttempt(selected.operationID, manualRetry: userInitiated, scope: context) else { continue }
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
                    UserDefaults.standard.set(self.lastSync, forKey: self.syncDateKey)
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

    private func beginFavoriteAttempt(_ id: UUID, manualRetry: Bool, scope context: LibraryScope) throws -> FavoriteMutation? {
        var current = try state(for: context)
        guard let mutation = current.pendingFavorites.first(where: { $0.operationID == id }),
              manualRetry || !mutation.retryRequired, current.markFavoriteAttempt(operationID: id) else { return nil }
        try commit(current)
        return mutation
    }

    private func beginProgressAttempt(_ id: UUID, manualRetry: Bool, scope context: LibraryScope) throws -> ProgressMutation? {
        var current = try state(for: context)
        guard let mutation = current.pendingProgress.first(where: { $0.operationID == id && !$0.isDeletion }),
              manualRetry || !mutation.retryRequired, current.markProgressAttempt(operationID: id) else { return nil }
        try commit(current)
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
        if let detail = episodeDetails[remote.id] { return detail.series }
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

    private enum MetadataResult: Sendable { case detail(SeriesDetail), missing, timeout }

    /// The account list is already committed. Poster/detail lookups cannot delay its appearance.
    private func hydrateMetadata(history: AccountLibrarySnapshot?, favorites: AccountLibrarySnapshot?, token: UUID, scope context: LibraryScope) {
        metadataTask?.cancel()
        let items = (history?.items ?? []) + (favorites?.items ?? [])
        let unresolvedEpisodes = Set((history?.items ?? []).filter { $0.episodeID.isEmpty || $0.episodeNumber <= 0 }.map(\.id))
        var seen: Set<String> = []
        let ids = items.filter { item in
            let needsMetadata = item.series.title.isEmpty || item.series.cover.isEmpty || unresolvedEpisodes.contains(item.id)
            return needsMetadata && episodeDetails[item.id] == nil && seen.insert(item.id).inserted
        }.prefix(50).map(\.id)
        guard !ids.isEmpty else { loadingMetadata = false; return }
        loadingMetadata = true
        metadataTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.loadingMetadata = false; self.metadataTask = nil } }
            await withTaskGroup(of: MetadataResult.self) { group in
                var cursor = ids.makeIterator(), outstanding = 0
                func enqueue(_ id: String) {
                    outstanding += 1
                    group.addTask {
                        do { return .detail(try await NativeCatalogService().detail(id: id)) }
                        catch { return .missing }
                    }
                }
                for _ in 0..<min(4, ids.count) { if let id = cursor.next() { enqueue(id) } }
                group.addTask { try? await Task.sleep(for: .seconds(45)); return .timeout }
                while let result = await group.next() {
                    guard !Task.isCancelled, self.generation == token, self.scope == context else { group.cancelAll(); return }
                    switch result {
                    case .timeout: group.cancelAll(); return
                    case .missing: break
                    case .detail(let detail):
                        self.episodeDetails[detail.series.id] = detail
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
        if let detail = episodeDetails[id] { return detail }
        let detail = try await NativeCatalogService().detail(id: id)
        episodeDetails[id] = detail
        return detail
    }

    private func state(for context: LibraryScope) throws -> LibraryState {
        guard !blockedScopes.contains(context) else { throw AppError.message("片庫資料無法讀取，為保留原始紀錄，暫時停止儲存。") }
        if let state = states[context] { return state }
        do {
            let state = try persistence.load(scope: context)
            states[context] = state
            return state
        } catch { blockedScopes.insert(context); throw error }
    }

    private func commit(_ state: LibraryState) throws {
        try persistence.save(state)
        states[state.scope] = state
        if state.scope == scope { favorites = state.favorites; history = state.history }
    }

    private func restoreSelected() throws {
        let state = try state(for: scope)
        favorites = state.favorites; history = state.history
        syncError = nil; coverageText = nil
        lastSync = UserDefaults.standard.object(forKey: syncDateKey) as? Date
    }

    private var syncDateKey: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(scope)) ?? Data()
        return "library.lastSync." + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func cancelSynchronization() {
        generation = UUID(); scheduled?.cancel(); scheduled = nil; syncTask?.cancel(); syncTask = nil
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
