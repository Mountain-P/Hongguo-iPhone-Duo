import SwiftUI
import HongguoCore

@MainActor
struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var section: LibrarySection = .history
    @State private var filter: HistoryFilter = .all
    @State private var showingLogin = false
    @State private var confirmation: LibraryConfirmation?

    private enum LibrarySection: String, CaseIterable, Identifiable {
        case history = "歷史", favorites = "收藏"
        var id: String { rawValue }
    }

    private enum HistoryFilter: String, CaseIterable, Identifiable {
        case all = "全部", inProgress = "本集未完", completed = "本集看完"
        var id: String { rawValue }
    }

    private enum LibraryConfirmation {
        case clearHistory, importGuest, signOut

        var title: String {
            switch self {
            case .clearHistory: "清除觀看紀錄？"
            case .importGuest: "匯入本機片庫到紅果帳號？"
            case .signOut: "登出紅果帳號？"
            }
        }

        var message: String {
            switch self {
            case .clearHistory: "只清除目前片庫在這部 iPhone 的觀看紀錄。"
            case .importGuest: "本機收藏與觀看進度將加入目前帳號並同步至紅果，本機片庫會繼續保留。"
            case .signOut: "登出後切換至本機片庫。這個帳號在本機的片庫快取會保留，重新登入同一帳號即可使用。"
            }
        }
    }

    private var accountSelection: Binding<Bool> {
        Binding {
            model.showingAccountLibrary
        } set: { useAccount in
            if !useAccount {
                model.selectLibraryOwner(.guest)
            } else if model.canUseAccountLibrary, let profile = model.accountProfile {
                model.selectLibraryOwner(.account(id: profile.id))
            } else if model.playbackMode == .native {
                showingLogin = true
            }
        }
    }

    private var filteredHistory: [WatchRecord] {
        model.history.filter { record in
            switch filter {
            case .all: true
            case .inProgress: record.progress < 0.98
            case .completed: record.progress >= 0.98
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                profileHeader
                VStack(alignment: .leading, spacing: 18) {
                    libraryOwnerPicker
                    if model.showingAccountLibrary {
                        accountSyncPanel
                    } else {
                        Text(model.playbackMode == .native
                             ? "本機片庫保存在這部 iPhone。登入後可自行選擇匯入帳號。"
                             : "目前使用自訂播放服務，收藏與觀看紀錄保存在本機片庫。")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    sectionTabs
                    if section == .history {
                        historyFilters
                        if filter != .all {
                            Text("依最近觀看的分集進度篩選").font(.system(size: 10)).foregroundStyle(Theme.muted)
                                .padding(.top, -8)
                        }
                        if filteredHistory.isEmpty {
                            StatusCard(icon: "clock", title: model.history.isEmpty && model.librarySyncing ? "正在載入觀看紀錄" : model.history.isEmpty ? "從第一個故事開始" : "沒有符合的觀看紀錄",
                                       message: model.history.isEmpty && model.librarySyncing ? "讀到的片庫會先顯示，海報會接著補齊。" : model.history.isEmpty ? "播放過的劇集會留在這裡，隨時接著看。" : "切換上方分類，查看其他分集進度。")
                                .padding(.vertical, 22)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], alignment: .leading, spacing: 18) {
                                ForEach(filteredHistory) { record in
                                    NavigationLink(value: record.series) { historyCard(record) }
                                        .buttonStyle(.plain)
                                        .contentShape(Rectangle())
                                        .contextMenu {
                                            Button(role: .destructive) { model.removeHistory(record.series) } label: {
                                                Label("移除本機紀錄", systemImage: "trash")
                                            }
                                        }
                                }
                            }
                        }
                    } else if model.favorites.isEmpty {
                        StatusCard(icon: "heart", title: "喜歡的故事，先收藏", message: "在劇集頁點一下愛心，就能加入你的片庫。")
                            .padding(.vertical, 30)
                    } else {
                        SeriesGrid(items: model.favorites)
                    }
                    if model.hasAccount {
                        Divider().overlay(.white.opacity(0.08))
                        Button("登出紅果帳號", role: .destructive) { confirmation = .signOut }
                            .font(.subheadline).frame(minHeight: 36)
                    }
                }
                .padding(.horizontal, 14).padding(.top, 18).padding(.bottom, 28)
                .frame(maxWidth: .infinity, minHeight: 420, alignment: .topLeading)
                .background(Theme.surface, in: UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
            }
        }
        .background(alignment: .top) {
            LinearGradient(colors: [Theme.headerTint, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(height: 260).frame(maxHeight: .infinity, alignment: .top).ignoresSafeArea(edges: .top)
        }
        .background(Theme.surface)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingLogin) {
            NativePhoneLoginView { model.acceptAccountSession($0) }
        }
        .confirmationDialog(confirmation?.title ?? "確認", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible, presenting: confirmation) { value in
            switch value {
            case .clearHistory:
                Button("清除觀看紀錄", role: .destructive) { model.clearHistory() }
            case .importGuest:
                Button("匯入並同步") { model.importGuestLibrary() }
            case .signOut:
                Button("登出", role: .destructive) { model.signOut() }
            }
            Button("取消", role: .cancel) {}
        } message: { value in
            Text(value.message)
        }
    }

    private var profileHeader: some View {
        HStack(spacing: 15) {
            profileAvatar
            VStack(alignment: .leading, spacing: 7) {
                Text(profileTitle).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                if let profile = model.accountProfile {
                    Text(profile.maskedPhone.isEmpty ? "紅果帳號" : profile.maskedPhone)
                        .font(.caption).foregroundStyle(Theme.muted)
                } else if model.playbackMode == .native {
                    Button("手機驗證碼登入") { showingLogin = true }
                        .font(.subheadline.weight(.medium)).buttonStyle(.borderedProminent)
                        .tint(Theme.accent).foregroundStyle(.black).controlSize(.small)
                } else {
                    Text("本機用戶").font(.caption).foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 0)
            NavigationLink {
                SettingsView().toolbar(.visible, for: .navigationBar)
            } label: {
                Image(systemName: "gearshape").font(.system(size: 20, weight: .regular)).foregroundStyle(.white.opacity(0.85))
                    .frame(width: 42, height: 42).contentShape(Circle())
            }
            .buttonStyle(.plain).accessibilityLabel("設定")
        }
        .padding(.horizontal, 20).padding(.top, 26).padding(.bottom, 32)
    }

    private var profileTitle: String {
        guard let profile = model.accountProfile else { return "我的片庫" }
        let nickname = profile.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return nickname.isEmpty ? "紅果帳號" : nickname
    }

    private var profileAvatar: some View {
        AsyncImage(url: model.accountProfile?.avatar) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.fill")
                .font(.system(size: 30, weight: .light)).foregroundStyle(.white.opacity(0.78))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LinearGradient(colors: [Color(red: 0.18, green: 0.36, blue: 0.34), Color(red: 0.08, green: 0.19, blue: 0.19)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .frame(width: 62, height: 62).clipped().clipShape(Circle())
        .overlay { Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1) }
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    private var libraryOwnerPicker: some View {
        Picker("片庫儲存位置", selection: accountSelection) {
            Text("本機片庫").tag(false)
            Text("帳號片庫").tag(true)
        }
        .pickerStyle(.segmented)
        .disabled(model.playbackMode != .native)
    }

    private var accountSyncPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        if model.librarySyncing { ProgressView().controlSize(.small) }
                        Text(syncStatus).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                    }
                    if let date = model.lastLibrarySync {
                        Text("上次同步 \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(Theme.muted)
                    }
                }
                Spacer(minLength: 0)
                Button(model.accountNeedsLogin ? "重新登入" : "立即同步") {
                    if model.accountNeedsLogin {
                        showingLogin = true
                    } else {
                        Task { await model.synchronizeLibrary() }
                    }
                }
                .buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
                .disabled(model.librarySyncing)
            }
            if let error = model.librarySyncError, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let coverage = model.libraryCoverageText, !coverage.isEmpty {
                Text(coverage).font(.caption2).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if model.libraryMetadataLoading {
                Text("正在補齊海報與劇集資料，已可瀏覽和點播。")
                    .font(.caption2).foregroundStyle(Theme.muted)
            }
            Button { confirmation = .importGuest } label: {
                Label("匯入本機收藏與進度", systemImage: "square.and.arrow.up")
                    .font(.caption.weight(.medium)).frame(minHeight: 28)
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .disabled(model.librarySyncing || model.accountNeedsLogin)
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private var syncStatus: String {
        if model.librarySyncing { return model.librarySyncPhase.isEmpty ? "正在同步片庫" : model.librarySyncPhase }
        if model.accountNeedsLogin { return "登入已到期，片庫快取已保留" }
        if model.pendingSyncCount > 0 { return "有 \(model.pendingSyncCount) 筆變更等待同步" }
        if model.librarySyncError != nil { return "同步尚未完成，已保留手機片庫" }
        return model.lastLibrarySync == nil ? "可同步紅果收藏與觀看進度" : "片庫已同步"
    }

    private var sectionTabs: some View {
        HStack(alignment: .top, spacing: 25) {
            ForEach(LibrarySection.allCases) { value in
                let count = value == .history ? model.history.count : model.favorites.count
                Button { section = value } label: {
                    VStack(spacing: 9) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(value.rawValue).font(.system(size: 18, weight: section == value ? .semibold : .medium))
                            if count > 0 { Text("\(count)").font(.system(size: 10, weight: .medium)) }
                        }
                        .foregroundStyle(section == value ? .white : Theme.muted)
                        Capsule().fill(section == value ? .white : .clear).frame(width: 19, height: 3)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == value ? .isSelected : [])
            }
            Spacer(minLength: 0)
            if section == .history && !model.history.isEmpty {
                Button { confirmation = .clearHistory } label: {
                    Image(systemName: "trash").font(.system(size: 15)).foregroundStyle(Theme.muted)
                        .frame(width: 32, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("清除觀看紀錄")
            }
        }
    }

    private var historyFilters: some View {
        HStack(spacing: 9) {
            ForEach(HistoryFilter.allCases) { value in
                Button { filter = value } label: {
                    Text(value.rawValue).font(.system(size: 11, weight: filter == value ? .medium : .regular))
                        .foregroundStyle(filter == value ? Theme.accent : Theme.muted)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(filter == value ? Theme.accent.opacity(0.16) : .white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filter == value ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    private func historyCard(_ record: WatchRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Poster(series: record.series, contentMode: .fit)
                .aspectRatio(0.70, contentMode: .fit)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                }
                .overlay(alignment: .bottomLeading) {
                    Text("第 \(record.episode.number) 集").font(.system(size: 10, weight: .medium)).foregroundStyle(.white)
                        .padding(7)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            Text(record.series.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
            Text(record.duration > 0 ? "本集已看 \(Int(record.progress * 100))%" : "看到第 \(record.episode.number) 集")
                .font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
            ProgressView(value: record.progress).tint(Theme.accent).scaleEffect(y: 0.7)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
