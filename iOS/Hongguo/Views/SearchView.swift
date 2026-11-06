import SwiftUI
import HongguoCore

@MainActor
struct SearchView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var catalog = CatalogModel()
    @State private var text = ""
    @State private var submitted = ""
    @State private var loadedContext: SearchContext?
    @State private var loadID = UUID()
    @State private var loadTask: Task<Void, Never>?

    private struct SearchContext: Hashable {
        let revision: UUID
        let query: String
    }

    private var searchContext: SearchContext { .init(revision: model.revision, query: submitted) }

    var body: some View {
        let context = searchContext
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if submitted.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("下一部，想看什麼？").font(.title2.weight(.bold))
                        Text("搜尋劇名，找到你的下一個故事。").foregroundStyle(Theme.muted).font(.subheadline)
                    }.padding(.top, 18)
                    if !model.searchHistory.isEmpty {
                        Text("最近搜尋").font(.headline)
                        ForEach(model.searchHistory, id: \.self) { query in
                            Button { text = query; submit() } label: {
                                HStack { Image(systemName: "clock"); Text(query); Spacer(); Image(systemName: "arrow.up.left") }
                                    .foregroundStyle(.white).padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                } else {
                    Text("「\(submitted)」的搜尋結果").font(.headline)
                    SeriesGrid(items: catalog.items)
                    if catalog.isLoading { ProgressView().frame(maxWidth: .infinity).padding() }
                    else if let error = catalog.error {
                        StatusCard(icon: "exclamationmark.magnifyingglass", title: "搜尋暫時無法使用", message: error,
                                   actionTitle: "重試", action: { beginLoad() })
                    } else if catalog.items.isEmpty {
                        StatusCard(icon: "magnifyingglass", title: "沒有找到這部劇", message: "試試完整劇名或較短的關鍵字。")
                    } else if catalog.hasMore {
                        Button("載入更多") { beginLoad() }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                    }
                }
            }.padding(20)
        }
        .background(Theme.background).navigationTitle("搜尋")
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜尋短劇名稱")
        .onSubmit(of: .search) { submit() }
        .onChange(of: text) { _, value in
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { submitted = "" }
        }
        .task(id: context) { await activate(context) }
        .onDisappear { cancelLoading() }
    }

    private func submit() {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { submitted = ""; return }
        model.rememberSearch(query)
        if query == submitted { beginLoad(reset: true) }
        else { submitted = query }
    }

    private func activate(_ context: SearchContext) async {
        guard context == searchContext, !Task.isCancelled else { return }
        cancelLoading()
        guard !context.query.isEmpty else { loadedContext = nil; return }
        guard loadedContext != context else { return }
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
            catalog.fail(error)
        }
    }

    private func cancelLoading() {
        loadID = UUID()
        loadTask?.cancel(); loadTask = nil
        catalog.cancel()
    }
}
