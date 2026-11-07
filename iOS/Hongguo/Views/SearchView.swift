import SwiftUI
import HongguoCore

@MainActor
struct SearchView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var catalog = SearchCatalogModel()
    @State private var text = ""
    @State private var submitted = ""
    @State private var loadedContext: SearchContext?
    @State private var loadID = UUID()
    @State private var loadTask: Task<Void, Never>?
    @State private var selectedFilter = SearchResultFilter.all
    @State private var validationError: String?

    private struct SearchContext: Hashable {
        let revision: UUID
        let query: String
    }

    private var searchContext: SearchContext { .init(revision: model.revision, query: submitted) }
    private var filteredItems: [Series] { SearchResultFiltering.apply(selectedFilter, to: catalog.items) }

    var body: some View {
        let context = searchContext
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let validationError {
                    Text(validationError).font(.subheadline).foregroundStyle(Theme.accent)
                }
                if submitted.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("下一部，想看什麼？").font(.title2.weight(.bold))
                        Text("搜尋劇名，找到你的下一個故事。").foregroundStyle(Theme.muted).font(.subheadline)
                    }.padding(.top, 18)
                    if !model.searchHistory.isEmpty {
                        HStack {
                            Text("最近搜尋").font(.headline)
                            Spacer()
                            Button("全部清除", role: .destructive) { model.clearSearchHistory() }
                                .font(.subheadline)
                        }
                        ForEach(model.searchHistory, id: \.self) { query in
                            HStack(spacing: 12) {
                                Button { text = query; submit() } label: {
                                    HStack {
                                        Image(systemName: "clock")
                                        Text(query).multilineTextAlignment(.leading)
                                        Spacer(minLength: 8)
                                        Image(systemName: "arrow.up.left")
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Button { model.removeSearch(query) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).foregroundStyle(Theme.muted)
                                .accessibilityLabel("刪除搜尋紀錄：\(query)")
                            }
                            .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 4)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                } else {
                    Text("「\(submitted)」的搜尋結果").font(.headline)
                    if let alternate = catalog.alternateQuery {
                        Text("原關鍵字沒有結果，已用「\(alternate)」補查簡繁字形。")
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }
                    if !catalog.items.isEmpty { resultFilters }
                    SeriesGrid(items: filteredItems)
                    if catalog.isLoading { ProgressView().frame(maxWidth: .infinity).padding() }
                    else if let error = catalog.error {
                        StatusCard(icon: "exclamationmark.magnifyingglass", title: "搜尋暫時無法使用", message: error,
                                   actionTitle: "重試", action: { beginLoad() })
                    } else if catalog.items.isEmpty {
                        StatusCard(icon: "magnifyingglass", title: "沒有找到這部劇", message: "試試完整劇名或較短的關鍵字。")
                    } else if filteredItems.isEmpty {
                        StatusCard(icon: "line.3.horizontal.decrease", title: "已載入結果沒有這個題材",
                                   message: catalog.hasMore ? "可載入更多搜尋結果，或切回全部題材。" : "可切回全部題材，或換個關鍵字。",
                                   actionTitle: "顯示全部", action: { selectedFilter = .all })
                    }
                    if !catalog.isLoading, catalog.error == nil, catalog.hasMore {
                        Button("載入更多") { beginLoad() }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                    }
                }
            }.padding(20)
        }
        .background(Theme.background).navigationTitle("搜尋")
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜尋短劇名稱")
        .onSubmit(of: .search) { submit() }
        .onChange(of: text) { _, value in
            validationError = nil
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { submitted = "" }
        }
        .task(id: context) { await activate(context) }
        .onDisappear { cancelLoading() }
    }

    private var resultFilters: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !catalog.facets.isEmpty {
                Picker("題材篩選", selection: $selectedFilter) {
                    Text("全部題材").tag(SearchResultFilter.all)
                    ForEach(catalog.facets) { facet in
                        Text("\(facet.title)（\(facet.count)）").tag(SearchResultFilter.tag(facet.id))
                    }
                }
                .pickerStyle(.menu).tint(Theme.accent)
                Text("顯示 \(filteredItems.count)／\(catalog.items.count) 部；只篩選已載入結果的來源題材。")
                    .font(.caption).foregroundStyle(Theme.muted)
            } else {
                Text("來源尚未提供可篩選的題材標籤。")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }

    private func submit() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { submitted = ""; return }
        let query: String
        do { query = try SearchText.query(text) }
        catch { validationError = error.localizedDescription; return }
        validationError = nil; selectedFilter = .all
        model.rememberSearch(query)
        if query == submitted { beginLoad(reset: true) }
        else { submitted = query }
    }

    private func activate(_ context: SearchContext) async {
        guard context == searchContext, !Task.isCancelled else { return }
        cancelLoading()
        guard !context.query.isEmpty else { loadedContext = nil; return }
        guard loadedContext != context else { return }
        selectedFilter = .all
        await load(context: context, reset: true)
    }

    private func beginLoad(reset: Bool = false) {
        let context = searchContext
        guard !context.query.isEmpty, reset || !catalog.isLoading else { return }
        cancelLoading()
        let request = loadID
        loadTask = Task {
            await load(context: context, reset: reset || loadedContext != context)
            if request == loadID { loadTask = nil }
        }
    }

    private func load(context: SearchContext, reset: Bool) async {
        guard context == searchContext, !Task.isCancelled else { return }
        let request = loadID
        if reset { loadedContext = nil }
        do {
            let service = try model.catalogService()
            await catalog.load(service: service, query: context.query, reset: reset)
            guard request == loadID, context == searchContext, !Task.isCancelled else { return }
            if catalog.error == nil { loadedContext = context }
        } catch {
            guard request == loadID, context == searchContext, !Task.isCancelled else { return }
            catalog.fail(error, reset: reset)
        }
    }

    private func cancelLoading() {
        loadID = UUID()
        loadTask?.cancel(); loadTask = nil
        catalog.cancel()
    }
}

/// Search pagination keeps the actual query that produced page one, including a single empty-result fallback.
@MainActor
private final class SearchCatalogModel: ObservableObject {
    @Published private(set) var items: [Series] = []
    @Published private(set) var facets: [SearchResultFacet] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var hasMore = false
    @Published private(set) var alternateQuery: String?
    private var effectiveQuery: String?
    private var page = 0
    private var generation = UUID()

    func load(service: any CatalogService, query: String, reset: Bool) async {
        guard !Task.isCancelled else { return }
        if reset {
            generation = UUID(); items = []; facets = []; page = 0; hasMore = false
            effectiveQuery = nil; alternateQuery = nil; isLoading = false
        }
        guard !isLoading else { return }
        let request = generation
        let next = page + 1
        isLoading = true; error = nil
        defer { if request == generation { isLoading = false } }
        do {
            try Task.checkCancellation()
            let result: SeriesPage
            let resolvedQuery: String
            if next == 1 {
                let resolution = try await SearchQueryPlan(query: query).firstPage(using: service)
                result = resolution.page; resolvedQuery = resolution.effectiveQuery
            } else {
                guard let effectiveQuery else { throw CatalogError.malformedResponse }
                result = try await service.search(query: effectiveQuery, page: next)
                resolvedQuery = effectiveQuery
            }
            try Task.checkCancellation()
            guard request == generation else { return }
            guard result.page == next else { throw CatalogError.malformedResponse }
            var known = Set(items.map(\.id))
            items.append(contentsOf: result.items.filter { known.insert($0.id).inserted })
            page = next; effectiveQuery = resolvedQuery
            alternateQuery = resolvedQuery == query ? nil : resolvedQuery
            facets = SearchResultFiltering.facets(in: items)
            // An empty/duplicate page may still have a next page; the user chooses each bounded request.
            hasMore = result.hasMore && next < 100
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    func cancel() { generation = UUID(); isLoading = false }

    func fail(_ error: Error, reset: Bool) {
        cancel()
        if reset {
            items = []; facets = []; page = 0; hasMore = false; effectiveQuery = nil; alternateQuery = nil
        }
        self.error = error.localizedDescription
    }
}
