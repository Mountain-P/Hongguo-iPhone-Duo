import SwiftUI
import HongguoCore

@MainActor
struct SearchView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var catalog = CatalogModel()
    @State private var text = ""
    @State private var submitted = ""

    var body: some View {
        ScrollView {
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
                                   actionTitle: "重試", action: { Task { await load(reset: true) } })
                    } else if catalog.items.isEmpty {
                        StatusCard(icon: "magnifyingglass", title: "沒有找到這部劇", message: "試試完整劇名或較短的關鍵字。")
                    } else if catalog.hasMore {
                        Button("載入更多") { Task { await load() } }.buttonStyle(.bordered).frame(maxWidth: .infinity)
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
        .task(id: "\(model.revision.uuidString):\(submitted)") { if !submitted.isEmpty { await load(reset: true) } }
    }

    private func submit() {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { submitted = ""; return }
        model.rememberSearch(query)
        if query == submitted { Task { await load(reset: true) } }
        else { submitted = query }
    }

    private func load(reset: Bool = false) async {
        do { await catalog.load(service: try model.catalogService(), query: submitted, reset: reset) }
        catch { catalog.fail(error) }
    }
}
