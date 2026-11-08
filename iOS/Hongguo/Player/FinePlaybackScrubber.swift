import HongguoCore
import SwiftUI

/// Keeps seeks out of the drag loop. Only a completed gesture commits to AVPlayer.
@MainActor
struct FinePlaybackScrubber: View {
    let elapsed: Double
    let duration: Double
    let disabled: Bool
    var bufferedRanges: [PlaybackBufferedRange] = []
    let onEditingChanged: (Bool, Double) -> Void
    let onSeek: (Double) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var scrub: FineScrubbingState?
    @GestureState private var touching = false

    private var position: Double { scrub?.position ?? elapsed }
    private var fraction: CGFloat {
        guard duration.isFinite, duration > 0, position.isFinite else { return 0 }
        return CGFloat(min(max(position / duration, 0), 1))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: scrub == nil ? 4 : 7)
                PlaybackBufferedSegments(ranges: bufferedRanges, duration: duration,
                                         height: scrub == nil ? 4 : 7)
                Capsule().fill(Theme.accent)
                    .frame(width: max(0, geometry.size.width * fraction), height: scrub == nil ? 4 : 7)
                Circle().fill(.white).frame(width: scrub == nil ? 12 : 19, height: scrub == nil ? 12 : 19)
                    .offset(x: max(0, min(geometry.size.width - 12, geometry.size.width * fraction - 6)))
            }
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(drag(width: geometry.size.width))
            .overlay(alignment: .bottom) {
                if let scrub {
                    VStack(spacing: 4) {
                        Text(timeLabel(scrub.position)).font(.title2.weight(.semibold).monospacedDigit())
                        Text(sensitivityLabel(scrub.sensitivity)).font(.caption)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .offset(y: -52).fixedSize().allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
        }
        .frame(height: 44)
        .opacity(disabled ? 0.45 : 1)
        .allowsHitTesting(!disabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("播放進度")
        .accessibilityValue("\(timeLabel(position))，共 \(timeLabel(duration))")
        .accessibilityHint("左右拖動調整進度，往上移動手指可以細調")
        .accessibilityAdjustableAction { direction in
            guard !disabled else { return }
            let delta: Double = direction == .increment ? 5 : -5
            onSeek(min(max(elapsed + delta, 0), duration))
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { cancel() } }
        .onChange(of: disabled) { _, disabled in if disabled { cancel() } }
        .onDisappear { cancel() }
        .task(id: touching) {
            guard !touching else { return }
            // onEnded clears the state first. A system-cancelled drag only rolls back its preview.
            await Task.yield()
            if !touching { cancel() }
        }
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { value in
                guard !disabled, width > 0 else { return }
                if scrub == nil {
                    scrub = FineScrubbingState(position: elapsed, duration: duration, trackWidth: Double(width))
                }
                guard var updated = scrub,
                      let position = updated.update(horizontalTranslation: Double(value.translation.width),
                          upwardDistance: Double(22 - value.location.y)) else { return }
                scrub = updated
                onEditingChanged(true, position)
            }
            .onEnded { _ in
                guard var completed = scrub else { return }
                let target = completed.end()
                scrub = nil
                onEditingChanged(false, target ?? elapsed)
                if let target { onSeek(target) }
            }
    }

    private func cancel() {
        guard var cancelled = scrub else { return }
        cancelled.cancel(); scrub = nil
        onEditingChanged(false, elapsed)
    }

    private func sensitivityLabel(_ sensitivity: FineScrubbingState.Sensitivity) -> String {
        switch sensitivity {
        case .full: "往上移動手指以細調"
        case .half: "½ 速度細調"
        case .quarter: "¼ 速度細調"
        case .tenth: "¹⁄₁₀ 速度精細調整"
        }
    }

    private func timeLabel(_ value: Double) -> String {
        let seconds = value.isFinite ? Int(min(max(value, 0), 359_999)) : 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// AVPlayer's loaded time ranges, independent of disk-cache occupancy.
struct PlaybackBufferedSegments: View {
    let ranges: [PlaybackBufferedRange]
    let duration: Double
    let height: CGFloat

    var body: some View {
        GeometryReader { geometry in
            if duration.isFinite, duration > 0 {
                ZStack(alignment: .leading) {
                    ForEach(Array(ranges.enumerated()), id: \.offset) { _, range in
                        if range.start.isFinite, range.end.isFinite, range.end > range.start {
                            let start = min(max(range.start / duration, 0), 1)
                            let end = min(max(range.end / duration, start), 1)
                            Capsule().fill(.white.opacity(0.5))
                                .frame(width: max(0, geometry.size.width * CGFloat(end - start)), height: height)
                                .offset(x: geometry.size.width * CGFloat(start))
                        }
                    }
                }
                .frame(width: geometry.size.width, height: height, alignment: .leading)
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct PlaybackBufferedProgress: View {
    let elapsed: Double
    let duration: Double
    let ranges: [PlaybackBufferedRange]

    private var fraction: Double {
        guard elapsed.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                PlaybackBufferedSegments(ranges: ranges, duration: duration, height: 3)
                Capsule().fill(.white.opacity(0.8))
                    .frame(width: geometry.size.width * CGFloat(fraction))
            }
        }
        .frame(height: 3)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int(fraction * 100))%")
    }
}
