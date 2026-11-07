import UIKit

/// Feedback for accepted user commands, never playback observations or cleanup.
@MainActor
enum PlaybackHaptics {
    enum Event: String {
        case speedSelected, boostBegan, boostEnded, boostLocked, boostUnlocked, skip
    }

    private static let selection = UISelectionFeedbackGenerator()
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let lock = UIImpactFeedbackGenerator(style: .medium)

    static func emit(_ event: Event) {
        guard UIApplication.shared.applicationState == .active else { return }
        switch event {
        case .speedSelected: selection.selectionChanged()
        case .boostBegan, .boostEnded: soft.impactOccurred()
        case .boostLocked: lock.impactOccurred()
        case .boostUnlocked, .skip: light.impactOccurred()
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-playback-haptic-diagnostics") {
            NSLog("PlaybackHaptic %@", event.rawValue)
        }
        #endif
    }
}
