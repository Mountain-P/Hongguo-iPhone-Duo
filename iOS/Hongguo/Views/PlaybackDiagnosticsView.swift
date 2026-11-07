import HongguoCore
import SwiftUI

@MainActor
struct PlaybackDiagnosticsView: View {
    @ObservedObject private var diagnostics = PlaybackDiagnostics.shared
    @State private var showingClear = false

    private var firstFrames: [Double] { diagnostics.records.filter { $0.context != .replay }.compactMap(\.firstFrameSeconds).sorted() }
    private var medianFirstFrame: Double? {
        guard !firstFrames.isEmpty else { return nil }
        let middle = firstFrames.count / 2
        return firstFrames.count.isMultiple(of: 2)
            ? (firstFrames[middle - 1] + firstFrames[middle]) / 2 : firstFrames[middle]
    }

    var body: some View {
        Form {
            Section {
                #if targetEnvironment(simulator)
                Text("目前是模擬器，數據不能代表 iPhone 的效能或耗電。")
                    .foregroundStyle(.secondary)
                #else
                Text("數據只保存在這部 iPhone，不會自動上傳；不記錄片名、播放網址或帳號。")
                    .foregroundStyle(.secondary)
                #endif
            }
            Section("最近播放") {
                LabeledContent("已結束測量", value: "\(diagnostics.records.count) 次")
                LabeledContent("有首幀的測量", value: "\(firstFrames.count) 次")
                LabeledContent("首幀等待中位數", value: seconds(medianFirstFrame))
                LabeledContent("播放中等待", value: seconds(diagnostics.records.reduce(0) { $0 + $1.rebufferSeconds }))
                LabeledContent("自動重試次數", value: "\(diagnostics.records.reduce(0) { $0 + $1.recoveryCount })")
                Text("從本次開始準備到畫面可顯示的時間，包含自動重試；未顯示畫面的測量不列入首幀中位數。原片重播只記定位準備，不混入首幀中位數。最多保留 80 次。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("目前資源") {
                LabeledContent("記憶體占用", value: memory(diagnostics.footprintMB))
                LabeledContent("本次啟動最高占用", value: memory(diagnostics.peakFootprintMB))
                LabeledContent("溫度狀態", value: thermalDescription)
                LabeledContent("低耗電模式", value: diagnostics.lowPower ? "開啟" : "關閉")
                #if !targetEnvironment(simulator)
                if let delta = diagnostics.batteryChange {
                    LabeledContent("裝置電量變化", value: String(format: "%.0f%%／%.0f 分鐘", delta, diagnostics.batteryWindowSeconds / 60))
                }
                Text("電量變化需拔除充電至少一分鐘，包含系統及其他 App 的耗電，不能當作本 App 單獨耗電。")
                    .font(.footnote).foregroundStyle(.secondary)
                #endif
            }
            Section("系統效能報告") {
                if let report = diagnostics.systemReport {
                    LabeledContent("收到報告", value: report.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("最高記憶體", value: memory(report.peakMemoryMB))
                    LabeledContent("累計 CPU 時間", value: seconds(report.cpuSeconds))
                    if let hitch = report.scrollHitchRatio {
                        LabeledContent("捲動卡頓比率", value: String(format: "%.2f", hitch))
                    }
                } else {
                    Text("尚未收到系統報告。MetricKit 通常按日提供實機使用統計；沒有報告不表示已完成耗電驗證。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("系統日報涵蓋整個 App 的使用，可能包含不同版本，並非單次影片的測量。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !diagnostics.records.isEmpty {
                Section("最近五次") {
                    ForEach(diagnostics.records.suffix(5).reversed()) { record in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(context(record.context)).font(.subheadline)
                            Text("首幀 \(seconds(record.firstFrameSeconds)) · 等待 \(seconds(record.rebufferSeconds)) · \(outcome(record.outcome))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Button("清除播放測量", role: .destructive) { showingClear = true }
                }
            }
        }
        .navigationTitle("播放診斷").navigationBarTitleDisplayMode(.inline)
        .onAppear { diagnostics.refreshResources() }
        .confirmationDialog("清除本機播放測量？", isPresented: $showingClear, titleVisibility: .visible) {
            Button("清除測量", role: .destructive) { diagnostics.clearRecords() }
            Button("取消", role: .cancel) {}
        } message: { Text("不影響收藏或觀看進度，正在播放的測量仍會在結束時保存。") }
    }

    private func seconds(_ value: Double?) -> String { value.map { String(format: "%.2f 秒", $0) } ?? "—" }
    private func memory(_ value: Double?) -> String { value.map { String(format: "%.1f MB", $0) } ?? "—" }
    private var thermalDescription: String {
        switch diagnostics.thermalState {
        case .nominal: "正常"
        case .fair: "稍熱"
        case .serious: "偏高"
        case .critical: "過熱"
        @unknown default: "未知"
        }
    }
    private func outcome(_ value: PlaybackMeasurement.Outcome) -> String {
        switch value { case .completed: "播完"; case .cancelled: "離開或切換"; case .failed: "未能播放" }
    }
    private func context(_ value: PlaybackMeasurement.Context) -> String {
        switch value { case .episode: "正式播放"; case .preview: "推薦試看"; case .replay: "原片重播" }
    }
}
