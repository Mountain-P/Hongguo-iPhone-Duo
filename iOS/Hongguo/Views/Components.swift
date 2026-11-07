import SwiftUI
import HongguoCore

enum Theme {
    static let accent = Color(red: 1, green: 0.43, blue: 0.16)
    static let background = Color.black
    static let surface = Color(red: 0.115, green: 0.125, blue: 0.125)
    static let muted = Color(red: 0.57, green: 0.60, blue: 0.60)
    static let headerTint = Color(red: 0.025, green: 0.17, blue: 0.16)
}

@MainActor
struct Poster: View {
    let series: Series
    var contentMode: ContentMode = .fill
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Theme.headerTint, Theme.surface, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "play.rectangle.on.rectangle")
                    .font(.system(size: 36, weight: .ultraLight)).foregroundStyle(.white.opacity(0.25))
                if let url = URL(string: series.cover), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                    let side = max(geometry.size.width, geometry.size.height) * displayScale
                    if side.isFinite, side > 0 {
                        PosterBitmap(url: url, pixels: Int(min(side.rounded(.up), 2048)), contentMode: contentMode)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            // Cropped images must not intercept controls outside their poster.
            .contentShape(Rectangle())
        }
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }
}

@MainActor
private struct PosterBitmap: View {
    let url: URL
    let pixels: Int
    let contentMode: ContentMode
    @State private var bitmap: PosterImage?
    @State private var loadedRequest: Request?
    @State private var loadID = UUID()
    private struct Request: Hashable { let url: URL; let pixels: Int }
    private var request: Request {
        // Match the pipeline's buckets so small layout changes do not clear a ready poster.
        let clamped = min(max(1, pixels), 2048)
        return .init(url: url, pixels: min(((clamped + 63) / 64) * 64, 2048))
    }

    var body: some View {
        let requested = request
        Group {
            if loadedRequest?.url == requested.url, let bitmap {
                Image(decorative: bitmap.image, scale: 1).resizable().aspectRatio(contentMode: contentMode)
            } else { Color.clear }
        }
        .task(id: requested) {
            guard !Task.isCancelled else { return }
            let id = UUID(); loadID = id
            if loadedRequest?.url != requested.url {
                bitmap = nil; loadedRequest = nil
            } else if let bitmap, max(bitmap.image.width, bitmap.image.height) >= requested.pixels {
                // Reuse an adequate bitmap when the same poster becomes smaller.
                return
            }
            do {
                let image = try await PosterImagePipeline.shared.image(for: requested.url, targetPixelSize: requested.pixels)
                guard !Task.isCancelled, loadID == id else { return }
                bitmap = image; loadedRequest = requested
            } catch { /* Keep a same-URL bitmap, or the placeholder. A later request can retry. */ }
        }
        .onDisappear { loadID = UUID(); bitmap = nil; loadedRequest = nil }
    }
}

@MainActor
struct SeriesCard: View {
    let series: Series
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Poster(series: series, contentMode: .fit)
                .aspectRatio(0.70, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    if !series.badge.isEmpty {
                        Text(series.badge).font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 4)).padding(6)
                    }
                }
            VStack(alignment: .leading, spacing: 7) {
                Text(series.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !series.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(series.tags.prefix(2).enumerated()), id: \.offset) { _, tag in
                            Text(tag).font(.system(size: 9)).foregroundStyle(Theme.muted).lineLimit(1)
                                .padding(.horizontal, 5).padding(.vertical, 3)
                                .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }
            .padding(8)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct SeriesGrid: View {
    let items: [Series]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], alignment: .leading, spacing: 12) {
            ForEach(items) { series in
                NavigationLink(value: series) { SeriesCard(series: series) }.buttonStyle(.plain)
            }
        }
    }
}

@MainActor
struct StatusCard: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: icon).font(.system(size: 34, weight: .light)).foregroundStyle(Theme.accent)
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.borderedProminent).controlSize(.large) }
        }
        .padding(28).frame(maxWidth: .infinity).background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
    }
}
