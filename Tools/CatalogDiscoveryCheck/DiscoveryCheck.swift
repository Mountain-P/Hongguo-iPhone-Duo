import Foundation
import HongguoCore

/// An explicit live metadata probe. Never resolves or downloads video media.
@main
struct CatalogDiscoveryCheck {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.first == "preview", (2...3).contains(args.count),
               let category = DirectWebService.Category(rawValue: args[1]) {
                let limit = args.count == 3 ? Int(args[2]) ?? 0 : 3
                guard (1...5).contains(limit) else { throw ProbeError.usage }
                let service = RecommendationDiscoveryService(base: NativeCatalogService(category: category), category: category)
                var pages: [[String: Any]] = []
                for page in 1...limit {
                    let result = try await service.home(page: page)
                    let origins = await service.provenance(for: result.items.map(\.id))
                    var counts: [String: Int] = [:]
                    for item in result.items { counts[origins[item.id]?.label ?? "未標示來源", default: 0] += 1 }
                    pages.append(["page": result.page, "count": result.items.count, "hasMore": result.hasMore,
                                  "sources": counts, "sample": result.items.prefix(3).map(\.title)])
                    if !result.hasMore { break }
                    // This explicit metadata probe gives the background side pool its full
                    // bounded preparation window; production page one never waits here.
                    if page == 1 { try await Task.sleep(for: .milliseconds(8_200)) }
                }
                try output(["category": category.rawValue, "pages": pages])
                return
            }
            if args.first == "artist", args.count == 2 {
                let profile = try await ArtistDiscoveryService().artist(id: args[1])
                try output(["artist": profile.artist.name, "hasBiography": !profile.biography.isEmpty,
                            "works": profile.works.count, "sample": profile.works.prefix(3).map(\.title)])
                return
            }
            if args.first == "detail", args.count == 2 {
                let detail = try await NativeCatalogService().detail(id: args[1])
                let metadata = detail.discovery
                try output(["title": detail.series.title, "episodes": detail.episodes.count,
                            "artists": metadata?.artists.count ?? 0, "related": metadata?.related.count ?? 0,
                            "artistSample": metadata?.artists.prefix(3).map { ["name": $0.name, "role": $0.role] } ?? [],
                            "rating": metadata?.ratingText ?? "", "heat": metadata?.heatText ?? "",
                            "release": metadata?.releaseText ?? ""])
                return
            }
            let page = args.count > 2 ? Int(args[2]) ?? 0 : 1
            let result: DiscoveryPage
            switch args.first {
            case "category":
                guard args.count >= 2, let category = DirectWebService.Category(rawValue: args[1]) else { throw ProbeError.usage }
                let genre = args.count > 3 ? args[3] : nil
                result = try await WebDiscoveryService().category(category: category, genre: genre, page: page)
            case "rank":
                let board: DiscoveryRanking
                switch args.dropFirst().first ?? "all" {
                case "all": board = .all
                case "real-drama": board = .realDrama
                case "comic-drama": board = .comicDrama
                case "ai-drama": board = .aiDrama
                default: throw ProbeError.usage
                }
                result = try await WebDiscoveryService().ranking(board: board, page: page)
            case "new":
                let category: NewReleaseCategory
                switch args.dropFirst().first ?? "real-drama" {
                case "real-drama": category = .realDrama
                case "ai-drama": category = .aiDrama
                default: throw ProbeError.usage
                }
                result = try await NativeNewReleaseService().releases(category: category, fresh: true)
            default: throw ProbeError.usage
            }
            let summary: [String: Any] = [
                "count": result.items.count, "page": result.page, "hasMore": result.hasMore,
                "genres": result.genres.map { ["id": $0.id, "title": $0.title] },
                "updatedText": result.updatedText,
                "sample": result.items.prefix(3).map { item -> [String: Any] in
                    var row: [String: Any] = ["title": item.series.title, "tags": item.series.tags,
                        "heat": item.heatText, "score": item.scoreText, "status": item.statusText]
                    if let rank = item.rank { row["rank"] = rank }
                    return row
                }
            ]
            try output(summary)
        } catch {
            // Do not print upstream responses, identities, signed URLs or headers.
            let message = error is ProbeError ? "Usage: CatalogDiscoveryCheck preview <real-drama|comic-drama|ai-drama> [pages:1...5] | category <real-drama|comic-drama|ai-drama> [page] [genre] | rank <all|real-drama|comic-drama|ai-drama> [page] | new <real-drama|ai-drama> | artist <id> | detail <id>" : error.localizedDescription
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        }
    }
    private static func output(_ value: [String: Any]) throws {
        print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
    enum ProbeError: Error { case usage }
}
