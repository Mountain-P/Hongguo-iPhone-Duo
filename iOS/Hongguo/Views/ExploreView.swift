import SwiftUI
import HongguoCore

private enum TheaterMode: String, CaseIterable, Identifiable, Sendable {
    case recommended = "推薦", ranking = "排行榜", newReleases = "新劇", categories = "分類"
    var id: String { rawValue }
}

private enum TheaterReleaseKind: String, CaseIterable, Identifiable, Sendable {
    case realDrama = "真人短劇", aiDrama = "AI 短劇"
    var id: String { rawValue }
    var source: NewReleaseCategory { self == .realDrama ? .realDrama : .aiDrama }
}

private struct TheaterQuery: Hashable, Sendable {
    let mode: TheaterMode
    let category: DirectWebService.Category
    let board: DiscoveryRanking
    let releaseKind: TheaterReleaseKind
    let genre: String?
    let usesBridge: Bool

    var key: String {
        if usesBridge { return "bridge" }
        switch mode {
        case .recommended: return "recommended:\(category.rawValue)"
        case .ranking: return "ranking:\(board.rawValue)"
        case .newReleases: return "new:\(releaseKind.rawValue)"
        case .categories: return "category:\(category.rawValue):\(genre ?? "all")"
        }
    }
}

@MainActor
struct ExploreView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var catalogue = TheaterDiscoveryModel()
    @State private var mode: TheaterMode = .recommended
    @State private var category: DirectWebService.Category = .realDrama
    @State private var board: DiscoveryRanking = .all
    @State private var releaseKind: TheaterReleaseKind = .realDrama
    @State private var genre: String?
    @State private var draftGenre: String?
    @State private var showingGenres = false

    private var usesBridge: Bool { model.catalogSource == .bridge }
    private var query: TheaterQuery {
        TheaterQuery(mode: usesBridge ? .recommended : mode, category: category, board: board,
                     releaseKind: releaseKind, genre: mode == .categories ? genre : nil, usesBridge: usesBridge)
    }
    private var loadKey: String { "\(model.revision.uuidString):\(query.key)" }
    private var genreTitle: String {
        catalogue.genres.first(where: { $0.id == genre })?.title ?? "全部題材"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                searchLink
                modeSelector
                selectionControls
                if usesBridge {
                    Text("自訂服務目前提供基本目錄與搜尋。排行榜、新劇與題材分類可在內建目錄使用。")
                        .font(.caption).foregroundStyle(Theme.muted)
                } else if mode == .newReleases {
                    Text("近 7 天上新 · \(releaseKind == .realDrama ? "真人劇" : "AI") · 近期片單")
                        .font(.caption).foregroundStyle(Theme.muted)
                } else if !catalogue.updatedText.isEmpty {
                    Text(catalogue.updatedText).font(.caption).foregroundStyle(Theme.muted)
                }
                if !catalogue.items.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], alignment: .leading, spacing: 12) {
                        ForEach(catalogue.items) { item in
                            NavigationLink(value: item.series) { discoveryCard(item) }
                                .buttonStyle(.plain).contentShape(Rectangle())
                        }
                    }
                }
                catalogueStatus
                if !usesBridge, mode == .newReleases {
                    Text("顯示來源近期收錄的片單，最多 100 部。")
                        .font(.caption2).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 22)
        }
        .clipped()
        .background(alignment: .top) {
            LinearGradient(colors: [Theme.headerTint, Theme.background], startPoint: .top, endPoint: .bottom)
                .frame(height: 270).frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top).allowsHitTesting(false)
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: loadKey) {
            if catalogue.key != loadKey || !catalogue.hasLoadedPage { await load(reset: true) }
        }
        .refreshable { await load(reset: true, fresh: true) }
        .onDisappear { catalogue.cancel() }
        .onChange(of: model.catalogSource) { _, value in
            showingGenres = false
            if value == .bridge { mode = .recommended }
        }
        .sheet(isPresented: $showingGenres) { genreSheet }
    }

    private var searchLink: some View {
        NavigationLink {
            SearchView().toolbar(.visible, for: .navigationBar)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").font(.system(size: 14))
                Text("搜尋劇名，找到下一部好故事").font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
                Text("搜尋").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            }
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 14).frame(height: 42)
            .background(.white.opacity(0.065), in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.045), lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).accessibilityLabel("搜尋短劇")
    }

    private var modeSelector: some View {
        HStack(spacing: 6) {
            ForEach(TheaterMode.allCases) { value in
                let supported = !usesBridge || value == .recommended
                Button { mode = value } label: {
                    Text(value.rawValue).font(.system(size: 14, weight: mode == value ? .semibold : .medium))
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .foregroundStyle(mode == value ? .white : Theme.muted)
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(mode == value ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!supported).opacity(supported ? 1 : 0.4)
                .accessibilityAddTraits(mode == value ? .isSelected : [])
                .accessibilityHint(supported ? "" : "自訂目錄未提供此功能")
            }
        }
    }

    @ViewBuilder
    private var selectionControls: some View {
        if usesBridge {
            Text(model.catalogSource.title).font(.caption).foregroundStyle(Theme.muted)
        } else if mode == .ranking {
            Picker("排行榜", selection: $board) {
                ForEach(DiscoveryRanking.allCases, id: \.rawValue) { value in
                    Text(boardTitle(value)).tag(value)
                }
            }.pickerStyle(.segmented)
        } else if mode == .newReleases {
            Picker("新劇類型", selection: $releaseKind) {
                ForEach(TheaterReleaseKind.allCases) { value in Text(value.rawValue).tag(value) }
            }.pickerStyle(.segmented)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 22) {
                    categoryButton("真人短劇", value: .realDrama)
                    categoryButton("漫劇", value: .comicDrama)
                    categoryButton("AI 短劇", value: .aiDrama)
                    Spacer(minLength: 0)
                }
                if mode == .categories {
                    HStack(spacing: 10) {
                        Button {
                            draftGenre = genre
                            showingGenres = true
                        } label: {
                            Label(genreTitle, systemImage: "line.3.horizontal.decrease")
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 12).frame(minHeight: 38)
                                .background(Theme.surface, in: Capsule())
                        }
                        .buttonStyle(.plain).foregroundStyle(.white)
                        .disabled(catalogue.genres.isEmpty)
                        .accessibilityLabel("選擇題材，\(genreTitle)")
                        if genre != nil {
                            Button("重設") { genre = nil }
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func categoryButton(_ title: String, value: DirectWebService.Category) -> some View {
        Button {
            genre = nil
            category = value
        } label: {
            VStack(spacing: 8) {
                Text(title).font(.system(size: category == value ? 16 : 14, weight: category == value ? .semibold : .medium))
                    .foregroundStyle(category == value ? .white : Theme.muted)
                Capsule().fill(category == value ? .white : .clear).frame(width: 18, height: 3)
            }
            .frame(minHeight: 36, alignment: .top).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityAddTraits(category == value ? .isSelected : [])
    }

    private func discoveryCard(_ item: DiscoveryItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SeriesCard(series: item.series)
                .overlay(alignment: .topLeading) {
                    if mode == .ranking, let rank = item.rank, rank > 0 {
                        Text("\(rank)").font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white).frame(minWidth: 28, minHeight: 28)
                            .background(rank <= 3 ? Theme.accent : .black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                            .padding(6).allowsHitTesting(false)
                            .accessibilityLabel("排名第 \(rank) 名")
                    }
                }
            let annotations = [item.statusText, item.heatText, item.scoreText].filter { !$0.isEmpty }
            if !annotations.isEmpty {
                Text(annotations.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(2)
                    .padding(.horizontal, 8).padding(.bottom, 8)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle()).accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var catalogueStatus: some View {
        if let error = catalogue.error {
            StatusCard(icon: "wifi.exclamationmark", title: "暫時無法載入", message: error,
                       actionTitle: "再試一次", action: { Task { await load(reset: catalogue.items.isEmpty) } })
        } else if catalogue.items.isEmpty && !catalogue.isLoading {
            StatusCard(icon: "film", title: catalogue.hasMore ? "這頁暫時沒有新劇" : "目前沒有符合的劇集",
                       message: catalogue.hasMore ? "來源仍有下一頁，可按「載入更多」繼續找劇。" : mode == .newReleases ? "來源近期片單暫時沒有這類新劇，稍後再重新整理。" : "試試其他分類或題材，或搜尋你想看的劇名。")
        } else if let notice = catalogue.pageNotice, catalogue.error == nil {
            Text(notice).font(.caption).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
        }
        if catalogue.isLoading {
            ProgressView(catalogue.items.isEmpty ? "正在載入劇集…" : "正在載入更多…")
                .font(.caption).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
                .padding(.vertical, catalogue.items.isEmpty ? 48 : 16)
        } else if catalogue.hasMore {
            Button { Task { await load() } } label: {
                Label("載入更多", systemImage: "arrow.down").font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.8))
        }
    }

    private var genreSheet: some View {
        NavigationStack {
            List {
                Section("題材") {
                    genreRow(title: "全部題材", id: nil)
                    ForEach(catalogue.genres) { value in genreRow(title: value.title, id: value.id) }
                }
            }
            .navigationTitle("選擇題材").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showingGenres = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("套用") { genre = draftGenre; showingGenres = false }
                }
                ToolbarItem(placement: .bottomBar) { Button("重設") { draftGenre = nil }.disabled(draftGenre == nil) }
            }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private func genreRow(title: String, id: String?) -> some View {
        Button { draftGenre = id } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if draftGenre == id { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityAddTraits(draftGenre == id ? .isSelected : [])
    }

    private func boardTitle(_ value: DiscoveryRanking) -> String {
        switch value {
        case .all: "總榜"
        case .realDrama: "真人劇"
        case .comicDrama: "漫劇"
        case .aiDrama: "AI 短劇"
        }
    }

    private func load(reset: Bool = false, fresh: Bool = false) async {
        do {
            let legacy: (any CatalogService)? = usesBridge ? try model.catalogService() : nil
            await catalogue.load(query: query, key: loadKey, legacy: legacy, reset: reset, fresh: fresh)
        } catch { catalogue.fail(error) }
    }
}

@MainActor
private final class TheaterDiscoveryModel: ObservableObject {
    @Published private(set) var items: [DiscoveryItem] = []
    @Published private(set) var genres: [DiscoveryGenre] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = false
    @Published private(set) var error: String?
    @Published private(set) var pageNotice: String?
    @Published private(set) var updatedText = ""
    private(set) var key: String?
    private var page = 0
    private var generation = UUID()
    private var operation: Task<DiscoveryPage, any Error>?
    private var knownGenres: [DirectWebService.Category: [DiscoveryGenre]] = [:]
    private let website = WebDiscoveryService()
    private let releases = NativeNewReleaseService()
    var hasLoadedPage: Bool { page > 0 }

    func load(query: TheaterQuery, key requestedKey: String, legacy: (any CatalogService)?, reset: Bool, fresh: Bool) async {
        guard !Task.isCancelled else { return }
        if reset || key != requestedKey {
            cancel()
            key = requestedKey
            items = []; page = 0; hasMore = false; error = nil; updatedText = ""
            genres = query.usesBridge ? [] : knownGenres[query.category] ?? []
        }
        guard !isLoading, page < 100 else { return }
        let request = generation
        let next = page + 1
        isLoading = true; error = nil; pageNotice = nil
        let website = self.website
        let releases = self.releases
        let task = Task<DiscoveryPage, any Error> {
            try Task.checkCancellation()
            if query.usesBridge {
                guard let legacy else { throw CatalogError.invalidConfiguration }
                let result = try await legacy.home(page: next)
                return DiscoveryPage(items: result.items.map { DiscoveryItem(series: $0) }, page: result.page, hasMore: result.hasMore)
            }
            switch query.mode {
            case .recommended:
                return try await website.category(category: query.category, page: next)
            case .categories:
                return try await website.category(category: query.category, genre: query.genre, page: next)
            case .ranking:
                return try await website.ranking(board: query.board, page: next)
            case .newReleases:
                return try await releases.releases(category: query.releaseKind.source, fresh: fresh)
            }
        }
        operation = task
        defer {
            if request == generation { isLoading = false; operation = nil }
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard request == generation, key == requestedKey else { return }
            guard result.page == next else { throw CatalogError.malformedResponse }
            var existing = Set(items.map(\.id))
            let additions = result.items.filter { existing.insert($0.id).inserted }
            items.append(contentsOf: additions)
            page = next
            hasMore = result.hasMore && page < 100
            if additions.isEmpty, hasMore { pageNotice = "這一頁沒有新增劇集，仍可手動載入下一頁。" }
            updatedText = result.updatedText
            if !query.usesBridge, query.mode == .recommended || query.mode == .categories, next == 1 || !result.genres.isEmpty {
                knownGenres[query.category] = result.genres
                genres = result.genres
            }
        } catch is CancellationError {
            return
        } catch {
            guard request == generation, key == requestedKey, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    func cancel() {
        generation = UUID()
        operation?.cancel(); operation = nil; isLoading = false
    }

    func fail(_ error: any Error) {
        cancel()
        self.error = error.localizedDescription
    }
}
