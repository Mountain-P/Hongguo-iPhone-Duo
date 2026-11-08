import HongguoCore
import SwiftUI

@MainActor
struct PlaybackQualityMenu: View {
    @ObservedObject var model: PlayerModel
    var compact = false

    private var currentQuality: String? {
        guard let variant = model.nativeVariant else { return nil }
        if let width = variant.width, let height = variant.height,
           (1...16_384).contains(width), (1...16_384).contains(height) {
            return "\(min(width, height))p"
        }
        let quality = variant.quality.lowercased()
        guard quality.range(of: #"^\d{3,4}p$"#, options: .regularExpression) != nil else { return nil }
        return quality
    }

    var body: some View {
        Menu {
            Section {
                qualityButton("畫質優先", preference: .automatic)
                qualityButton("流暢優先", preference: .dataSaver)
            } header: {
                Text(currentQuality.map { "目前畫質：\($0)" } ?? "播放畫質")
            }
            Text("切換會保留進度；可用畫質依來源而定。")
        } label: {
            Group {
                if model.isSwitchingQuality {
                    ProgressView().tint(.white)
                } else {
                    Label("播放畫質", systemImage: "slider.horizontal.3")
                        .labelStyle(.iconOnly)
                }
            }
            .frame(width: compact ? 46 : nil, height: compact ? 46 : nil)
            .contentShape(Rectangle())
        }
        .disabled(!model.supportsPlaybackQuality || model.isSwitchingQuality || model.isLoading || model.duration <= 0)
        .accessibilityLabel("播放畫質")
        .accessibilityValue(model.isSwitchingQuality ? "正在切換" :
            (model.playbackQuality == .automatic ? "畫質優先" : "流暢優先") + (currentQuality.map { "，\($0)" } ?? ""))
    }

    private func qualityButton(_ title: String, preference: NativePlaybackQuality) -> some View {
        Button { model.switchPlaybackQuality(preference) } label: {
            if model.playbackQuality == preference {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

@MainActor
struct PlaybackQualityStatus: View {
    @ObservedObject var model: PlayerModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    var body: some View {
        if model.isSwitchingQuality || model.qualityNotice != nil {
            Group {
                if model.isSwitchingQuality {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("正在切換畫質…")
                    }
                } else if let notice = model.qualityNotice {
                    Text(notice).multilineTextAlignment(.center)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background {
                if reduceTransparency { Capsule().fill(Color(white: 0.12)) }
                else { Capsule().fill(.ultraThinMaterial) }
            }
            .frame(maxWidth: 340)
            .allowsHitTesting(false)
        }
    }
}

@MainActor
struct PlaybackAudioStatus: View {
    @ObservedObject var model: PlayerModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if let notice = model.audioPlaybackNotice {
            Text(notice)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background {
                    if reduceTransparency { Capsule().fill(Color(white: 0.12)) }
                    else { Capsule().fill(.ultraThinMaterial) }
                }
                .frame(maxWidth: 340)
                .allowsHitTesting(false)
        }
    }
}
