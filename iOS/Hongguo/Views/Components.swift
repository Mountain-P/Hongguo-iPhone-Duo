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
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Theme.headerTint, Theme.surface, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "play.rectangle.on.rectangle")
                    .font(.system(size: 36, weight: .ultraLight)).foregroundStyle(.white.opacity(0.25))
                if let url = URL(string: series.cover), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: contentMode)
                    } placeholder: { Color.clear }
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
