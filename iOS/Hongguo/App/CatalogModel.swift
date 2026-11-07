import Combine
import Foundation
import HongguoCore

@MainActor
final class CatalogModel: ObservableObject {
    @Published private(set) var items: [Series] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var hasMore = false
    private var page = 0
    private var generation = UUID()
    var hasLoadedPage: Bool { page > 0 }

    func load(service: any CatalogService, query: String? = nil, reset: Bool = false) async {
        guard !Task.isCancelled else { return }
        if reset {
            generation = UUID(); items = []; page = 0; hasMore = false; isLoading = false
        }
        guard !isLoading, page < 100 else { return }
        let request = generation
        isLoading = true; error = nil
        defer { if request == generation { isLoading = false } }
        do {
            let next = page + 1
            let result: SeriesPage
            if let query { result = try await service.search(query: query, page: next) }
            else { result = try await service.home(page: next) }
            guard request == generation, !Task.isCancelled else { return }
            guard result.page == next else { throw CatalogError.malformedResponse }
            var known = Set(items.map(\.id))
            items.append(contentsOf: result.items.filter { known.insert($0.id).inserted })
            page = next
            // Duplicate or empty pages can precede valid later pages. Keep the
            // explicit next-page action while respecting the source and cap.
            hasMore = result.hasMore && next < 100
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    func cancel() { generation = UUID(); isLoading = false }

    func fail(_ error: Error) { generation = UUID(); items = []; isLoading = false; self.error = error.localizedDescription }
}
