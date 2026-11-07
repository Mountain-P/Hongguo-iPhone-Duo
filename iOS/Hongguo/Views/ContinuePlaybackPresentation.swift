import SwiftUI

@MainActor
struct ContinuePlaybackButton: View {
    let seriesTitle: String
    let isPreparing: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isPreparing { ProgressView().controlSize(.small) }
                else { Image(systemName: "play.fill") }
                Text(isPreparing ? "正在準備…" : "接著看").font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).foregroundStyle(.black).opacity(disabled ? 0.55 : 1)
        .disabled(disabled)
        .accessibilityLabel("接著看\(seriesTitle)")
    }
}

@MainActor
private struct ContinuePlaybackPresentation: ViewModifier {
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var launcher: ContinuePlaybackModel
    let context: ContinuePlaybackContext
    var onSeriesSwipe: ((Int) -> Void)?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if launcher.preparingSeriesID != nil {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("正在準備影片…").font(.subheadline)
                        Spacer(minLength: 12)
                        Button("取消") { launcher.cancelPending() }.font(.subheadline.weight(.semibold))
                    }
                    .padding(13).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(14)
                }
            }
            .onChange(of: context, initial: true) { _, value in launcher.updateContext(value) }
            .onChange(of: launcher.route?.id) { _, value in appModel.isImmersivePlayback = value != nil && context.parentActive }
            .onDisappear {
                // Presenting a cover also hides its parent; retain that cover.
                if launcher.route == nil { launcher.cancelPending() }
            }
            .fullScreenCover(item: Binding(get: { launcher.route }, set: { if $0 == nil { launcher.dismiss() } }),
                             onDismiss: { appModel.isImmersivePlayback = false }) { selection in
                PlayerScreen(series: selection.detail.series, episodes: selection.detail.episodes,
                             initialEpisodeID: selection.continuation.episode.id, resumeSeconds: selection.continuation.seconds,
                             service: selection.service, onProgress: selection.onProgress,
                             onClose: { launcher.dismiss() }, onSeriesSwipe: onSeriesSwipe)
                    .id(selection.id)
            }
    }
}

extension View {
    @MainActor
    func continuePlaybackPresentation(_ launcher: ContinuePlaybackModel, context: ContinuePlaybackContext,
                                      onSeriesSwipe: ((Int) -> Void)? = nil) -> some View {
        modifier(ContinuePlaybackPresentation(launcher: launcher, context: context, onSeriesSwipe: onSeriesSwipe))
    }
}
