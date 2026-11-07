import Combine
import Darwin
import Foundation
import HongguoCore
import MetricKit
import UIKit

/// Bounded, local-only numbers. No title, content ID, URL, account or token is accepted.
@MainActor
final class PlaybackDiagnostics: NSObject, ObservableObject {
    typealias Context = PlaybackMeasurement.Context
    typealias Outcome = PlaybackMeasurement.Outcome
    static let shared = PlaybackDiagnostics()
    private static let key = "playbackDiagnostics.v1"
    private static let maximumRecords = 80

    @Published private(set) var records: [PlaybackMeasurement.Summary] = []
    @Published private(set) var footprintMB: Double?
    @Published private(set) var peakFootprintMB: Double?
    @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var systemReport: SystemReport?
    @Published private(set) var batteryChange: Double?
    @Published private(set) var batteryWindowSeconds: Double = 0

    struct SystemReport: Codable, Sendable {
        let recordedAt: Date
        let peakMemoryMB: Double?
        let cpuSeconds: Double?
        let scrollHitchRatio: Double?
    }

    private var active: [UUID: PlaybackMeasurement] = [:]
    private var samplingIDs: Set<UUID> = []
    private var memoryTask: Task<Void, Never>?
    private var batteryStartedAt: Double?
    private var batteryStartedLevel: Float?
    private var batteryWindowValid = true
    private var batteryWasEnabled = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        if let data = defaults.data(forKey: Self.key), data.count <= 128 * 1024,
           let decoded = try? JSONDecoder().decode([PlaybackMeasurement.Summary].self, from: data) {
            records = Array(decoded.filter(Self.isValid).suffix(Self.maximumRecords))
        }
        if let data = defaults.data(forKey: Self.key + ".system"), data.count <= 4096 {
            systemReport = try? JSONDecoder().decode(SystemReport.self, from: data)
        }
        // The subscriber API also supports the app's iOS 17 deployment target.
        MXMetricManager.shared.add(self)
    }

    func begin(context: Context) -> UUID {
        let now = ProcessInfo.processInfo.systemUptime
        // Only the foreground player and its handoff can own a measurement.
        if active.count >= 2 {
            for id in Array(active.keys) { finish(id: id, outcome: .cancelled) }
        }
        let id = UUID()
        active[id] = PlaybackMeasurement(id: id, context: context, startedAt: now)
        enableSampling(id: id)
        return id
    }

    func recordReady(id: UUID) { active[id]?.recordReady(at: ProcessInfo.processInfo.systemUptime) }
    func recordFirstFrame(id: UUID) { active[id]?.recordFirstFrame(at: ProcessInfo.processInfo.systemUptime) }
    func recordTransport(id: UUID, waiting: Bool, playing: Bool) {
        active[id]?.recordTransport(waiting: waiting, playing: playing, at: ProcessInfo.processInfo.systemUptime)
        if playing || waiting { enableSampling(id: id) }
    }
    func recordFailure(id: UUID, recovered: Bool) {
        active[id]?.recordFailure(recovered: recovered, at: ProcessInfo.processInfo.systemUptime)
    }
    func recordPause(id: UUID) {
        active[id]?.recordPause(at: ProcessInfo.processInfo.systemUptime)
        sampleResources()
        suspendSampling(id: id)
    }

    func finish(id: UUID, outcome: Outcome) {
        guard var value = active.removeValue(forKey: id),
              let summary = value.finish(outcome: outcome, at: ProcessInfo.processInfo.systemUptime) else { return }
        records.append(summary)
        records = Array(records.suffix(Self.maximumRecords))
        persist()
        sampleResources()
        suspendSampling(id: id)
    }

    func clearRecords() {
        records = []
        defaults.removeObject(forKey: Self.key)
        // The current attempt remains valid and can be saved when it finishes.
    }

    func refreshResources() { sampleResources() }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.key) }
    }

    private func enableSampling(id: UUID) {
        guard active[id] != nil else { return }
        samplingIDs.insert(id)
        guard memoryTask == nil else { return }
        startBatteryWindowIfNeeded(now: ProcessInfo.processInfo.systemUptime)
        sampleResources()
        memoryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, !self.samplingIDs.isEmpty else { return }
                self.sampleResources()
            }
        }
    }

    private func suspendSampling(id: UUID) {
        samplingIDs.remove(id)
        guard samplingIDs.isEmpty else { return }
        memoryTask?.cancel(); memoryTask = nil
        #if !targetEnvironment(simulator)
        if !batteryWasEnabled { UIDevice.current.isBatteryMonitoringEnabled = false }
        #endif
    }

    private static func isValid(_ value: PlaybackMeasurement.Summary) -> Bool {
        let durations = [value.durationSeconds, value.readySeconds ?? 0,
                         value.firstFrameSeconds ?? 0, value.rebufferSeconds]
        return durations.allSatisfy { $0.isFinite && (0...604_800).contains($0) }
            && [value.rebufferCount, value.failureCount, value.recoveryCount].allSatisfy { (0...10_000).contains($0) }
    }

    private func sampleResources() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let value = Double(info.phys_footprint) / 1_048_576
            footprintMB = value; peakFootprintMB = max(peakFootprintMB ?? 0, value)
        }
        thermalState = ProcessInfo.processInfo.thermalState
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        #if !targetEnvironment(simulator)
        if let start = batteryStartedAt, let level = batteryStartedLevel {
            let current = UIDevice.current.batteryLevel
            batteryWindowSeconds = ProcessInfo.processInfo.systemUptime - start
            if UIDevice.current.batteryState != .unplugged { batteryWindowValid = false }
            if batteryWindowValid, current >= 0, batteryWindowSeconds >= 60 {
                batteryChange = Double(level - current) * 100
            } else { batteryChange = nil }
        }
        #endif
    }

    private func startBatteryWindowIfNeeded(now: Double) {
        #if !targetEnvironment(simulator)
        batteryWasEnabled = UIDevice.current.isBatteryMonitoringEnabled
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryStartedAt = now
        batteryWindowSeconds = 0
        batteryChange = nil
        let level = UIDevice.current.batteryLevel
        batteryStartedLevel = level >= 0 ? level : nil
        batteryWindowValid = UIDevice.current.batteryState == .unplugged
        #endif
    }
}

extension PlaybackDiagnostics: MXMetricManagerSubscriber {
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        let summaries = payloads.suffix(2).map { payload in
            SystemReport(recordedAt: payload.timeStampEnd,
                peakMemoryMB: payload.memoryMetrics?.peakMemoryUsage.converted(to: .megabytes).value,
                cpuSeconds: payload.cpuMetrics?.cumulativeCPUTime.converted(to: .seconds).value,
                scrollHitchRatio: payload.animationMetrics?.scrollHitchTimeRatio.value)
        }
        Task { @MainActor [weak self] in
            guard let self, let latest = summaries.max(by: { $0.recordedAt < $1.recordedAt }) else { return }
            self.systemReport = latest
            if let data = try? JSONEncoder().encode(latest) { self.defaults.set(data, forKey: Self.key + ".system") }
        }
    }
}
