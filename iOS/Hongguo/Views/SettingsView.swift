import SwiftUI
import HongguoCore

@MainActor
struct SettingsView: View {
    var isSetupSheet = false
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var catalogSource: CatalogSource = .website
    @State private var playbackMode: PlaybackMode = .native
    @State private var address = ""
    @State private var token = ""
    @State private var status: String?
    @State private var isConnecting = false
    @State private var operationID = UUID()
    @State private var connectionTask: Task<Void, Never>?

    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "開發版" }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 15) {
                    Image(systemName: "play.square.stack.fill").font(.system(size: 34)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("紅果 · 隨身短劇").font(.headline)
                        Text("iPhone 原生版 \(appVersion)").font(.caption).foregroundStyle(Theme.muted)
                    }
                }.padding(.vertical, 8)
            }
            Section("播放方式") {
                Picker("播放方式", selection: $playbackMode) {
                    ForEach(PlaybackMode.allCases) { Text($0.title).tag($0) }
                }.disabled(isConnecting)
                if playbackMode == .native {
                    Label("直接在 iPhone 播放", systemImage: "iphone")
                    Text("不需設定網址或啟動電腦服務。回到劇集選一集，即可開始準備影片。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("選用功能：連接你自行架設的相容服務。完成驗證後才會切換。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if playbackMode == .bridge {
            Section("自訂播放服務") {
                TextField("https://video.example.com", text: $address)
                    .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("播放服務網址").disabled(isConnecting)
                SecureField("服務口令（未啟用可留空）", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(isConnecting)
                Text("請填入本專案橋接服務的網址。其他短劇網站或 Quest 影院網址不能直接當作此服務使用。外網使用 HTTPS；區域網路可使用 HTTP。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(action: connect) {
                    HStack {
                        Text(isConnecting ? "正在驗證服務…" : "驗證並儲存播放服務")
                        Spacer()
                        if isConnecting { ProgressView() }
                    }
                }.disabled(isConnecting || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
                Text("儲存前會確認服務協定與劇集資料。各集能否取源、播放，仍以服務的實際回應為準。口令只保存在本機鑰匙圈。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("瀏覽目錄") {
                Picker("目錄來源", selection: $catalogSource) {
                    ForEach(CatalogSource.allCases) { Text($0.title).tag($0) }
                }.disabled(isConnecting)
                Text("選擇自訂服務後，可繼續使用內建目錄找劇。播放將使用已驗證的自訂服務。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("使用內建目錄瀏覽") {
                    catalogSource = .website
                    model.useWebsiteCatalog()
                }.disabled(isConnecting)
            }
            }
            Section("觀看體驗") {
                Label("直向觀看與橫向全螢幕", systemImage: "rotate.right")
                Label("倍速、快轉與自動下一集", systemImage: "forward.end")
                Text("長按影片暫時 2 倍速；上滑鎖定。鎖定時長按下滑解除，回到原先速度。")
                    .font(.footnote).foregroundStyle(.secondary)
                Label("收藏與進度先保存在這部 iPhone", systemImage: "iphone")
                Text("在「我的」登入紅果帳號後，可查看帳號片庫與同步狀態；本機片庫仍會保留。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("專案與授權") {
                Link("hongguoTV · 原始碼與橋接協定", destination: URL(string: "https://github.com/N3urda/hongguoTV")!)
                Link("hongguo-drama · 取源與官網解析參考", destination: URL(string: "https://github.com/jackotom/hongguo-drama")!)
                Link("hongguo-tv · 新版取源流程參考", destination: URL(string: "https://github.com/aston314/hongguo-tv")!)
                Link("hongguo-player · 功能參考", destination: URL(string: "https://github.com/yangbin1322/hongguo-player")!)
                Link("hongguo-tv-releases · 功能參考", destination: URL(string: "https://github.com/aston314/hongguo-tv-releases")!)
                Text("本專案採 GPL-3.0。這是第三方用戶端，與紅果官方無隸屬關係。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden).background(Theme.background).navigationTitle(isSetupSheet ? "播放設定" : "設定")
        .toolbar {
            if isSetupSheet { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .onAppear {
            catalogSource = model.catalogSource
            playbackMode = model.playbackMode
            address = model.serverURL
            token = model.token(for: model.serverURL)
        }
        .onDisappear { cancelConnection() }
        .onChange(of: address) { _, value in
            cancelConnection()
            token = value == model.serverURL ? model.token(for: value) : ""
            status = nil
        }
        .onChange(of: token) { _, _ in cancelConnection(); status = nil }
        .onChange(of: catalogSource) { _, _ in cancelConnection(); status = nil }
        .onChange(of: playbackMode) { _, value in
            cancelConnection(); status = nil
            if value == .native, model.playbackMode != .native {
                model.useNativePlayback()
                catalogSource = .website
            }
        }
    }

    private func cancelConnection() {
        operationID = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        isConnecting = false
    }

    private func connect() {
        cancelConnection()
        let request = UUID()
        operationID = request
        let draftAddress = address
        let draftToken = token
        let draftCatalog = catalogSource
        isConnecting = true
        status = nil
        connectionTask = Task {
            defer { if request == operationID { isConnecting = false; connectionTask = nil } }
            do {
                let count = try await model.connect(address: draftAddress, token: draftToken, catalogSource: draftCatalog)
                guard request == operationID, !Task.isCancelled else { return }
                status = "服務協定與目錄已確認，取得 \(count) 部劇集。各集播放結果仍以實際取源為準。"
                if isSetupSheet { dismiss() }
            } catch is CancellationError {
                return
            } catch {
                if request == operationID, !Task.isCancelled { status = error.localizedDescription }
            }
        }
    }
}
