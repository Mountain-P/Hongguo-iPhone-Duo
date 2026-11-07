// SPDX-License-Identifier: GPL-3.0-only
import Combine
import Foundation
import Network

/// Advisory policy only; it never changes the system's network configuration.
@MainActor
final class PlaybackPrefetchNetworkPolicy: ObservableObject {
    @Published private(set) var allowsPrefetch = false
    private var pathAllowed = false
    private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private let monitor = NWPathMonitor()
    private var powerObserver: NSObjectProtocol?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let allowed = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pathAllowed = allowed
                self.allowsPrefetch = allowed && !self.lowPower
            }
        }
        monitor.start(queue: DispatchQueue(label: "tw.mountainp.hongguo.episode-prefetch-policy"))
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                                                              object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                self.allowsPrefetch = self.pathAllowed && !self.lowPower
            }
        }
    }

    deinit {
        monitor.cancel()
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
    }
}
