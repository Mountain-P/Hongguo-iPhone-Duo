import HongguoCore
import SwiftUI

/// Brief seek feedback stays separate from the transport controls.
struct PlaybackSeekNotice: View {
    let side: PlaybackDoubleTap.Side

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 5) {
                Image(systemName: side == .backward ? "gobackward.10" : "goforward.10")
                    .font(.system(size: 30, weight: .semibold))
                Text(side == .backward ? "後退 10 秒" : "前進 10 秒")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 104, height: 104)
            .background(.black.opacity(0.45), in: Circle())
            .position(x: geometry.size.width * (side == .backward ? 0.25 : 0.75),
                      y: geometry.size.height * 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
