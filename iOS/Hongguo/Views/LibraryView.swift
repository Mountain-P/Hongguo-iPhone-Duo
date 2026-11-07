import SwiftUI
import HongguoCore

@MainActor
struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var section: LibrarySection = .history
    @State private var filter: HistoryFilter = .all
    @State private var showingLogin = false
    @State private var confirmation: LibraryConfirmation?
    @State private var query = ""
    @State private var favoriteSort: LibraryFavoriteSort = .storedOrder
    @State private var historySort: LibraryHistorySort = .recent
    @State private var isEditing = false
    @State private var selectedIDs: Set<String> = []

    private enum LibrarySection: String, CaseIterable, Identifiable {
        case history = "歷史", favorites = "收藏"
        var id: String { rawValue }
    }

    private enum HistoryFilter: String, CaseIterable, Identifiable {
        case all = "全部", inProgress = "本集未完", completed = "本集看完"
        var id: String { rawValue }
    }

    private struct BatchSelection {
        let ids: Set<String>
        let owner: LibraryOwner
        let revision: UUID
        let libraryName: String
        var isAccount: Bool { if case .account = owner { true } else { false } }
    }

    private enum LibraryConfirmation {
        case clearHistory, importGuest, signOut
        case removeHistory(BatchSelection), removeFavorites(BatchSelection)

        var title: String {
            switch self {
            case .clearHistory: "清除觀看紀錄？"
            case .importGuest: "匯入本機片庫到紅果帳號？"
            case .signOut: "登出紅果帳號？"
            case .removeHistory(let selection): "移除 \(selection.ids.count) 部本機觀看紀錄？"
            case .removeFavorites(let selection): "取消收藏 \(selection.ids.count) 部劇集？"
            }
        }

        var message: String {
            switch self {
            case .clearHistory: "只清除目前片庫在這部 iPhone 的觀看紀錄。"
            case .importGuest: "本機收藏與觀看進度將加入目前帳號並同步至紅果，本機片庫會繼續保留。"
            case .signOut: "登出後切換至本機片庫。這個帳號在本機的片庫快取會保留，重新登入同一帳號即可使用。"
            case .removeHistory(let selection): "目前片庫：\(selection.libraryName)。只移除這部 iPhone 的 \(selection.ids.count) 部觀看紀錄，不刪除官方觀看紀錄；收藏會保留。"
            case .removeFavorites(let selection): "目前片庫：\(selection.libraryName)。將取消 \(selection.ids.count) 部收藏。" + (selection.isAccount ? "這些帳號取消收藏會加入待同步變更並同步至紅果；觀看紀錄會保留。" : "只更改這部 iPhone 的本機收藏；觀看紀錄會保留。")
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
        let status: LibraryHistoryFilter = switch filter { case .all: .all; case .inProgress: .inProgress; case .completed: .completed }
        return LibraryBrowser.history(model.history, query: query, filter: status, sort: historySort)
    }

    private var filteredFavorites: [Series] { LibraryBrowser.favorites(model.favorites, query: query, sort: favoriteSort) }
    private var visibleIDs: Set<String> { Set(section == .history ? filteredHistory.map(\.id) : filteredFavorites.map(\.id)) }

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
                    browserControls
                    if section == .history { historyFilters }
                    if isEditing { selectionControls }
                    libraryContent
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
            case .removeHistory(let selection):
                Button("移除 \(selection.ids.count) 部本機紀錄", role: .destructive) {
                    guard selectionMatchesCurrentLibrary(selection) else { resetSelection(); return }
                    model.removeHistory(seriesIDs: selection.ids)
                    resetSelection()
                }
            case .removeFavorites(let selection):
                Button("取消 \(selection.ids.count) 部收藏", role: .destructive) {
                    guard selectionMatchesCurrentLibrary(selection) else { resetSelection(); return }
                    model.removeFavorites(seriesIDs: selection.ids)
                    resetSelection()
                }
            }
            Button("取消", role: .cancel) {}
        } message: { value in
            Text(value.message)
        }
        .onChange(of: section) { _, _ in resetSelection() }
        .onChange(of: filter) { _, _ in selectedIDs = []; confirmation = nil }
        .onChange(of: query) { _, value in
            if value.count > 80 { query = String(value.prefix(80)) }
            selectedIDs = []; confirmation = nil
        }
        .onChange(of: model.selectedLibraryOwner) { _, _ in resetSelection(); query = "" }
        .onChange(of: model.revision) { _, _ in resetSelection(); query = "" }
        .onChange(of: model.history.map(\.id)) { _, ids in
            if section == .history { selectedIDs.formIntersection(ids) }
        }
        .onChange(of: model.favorites.map(\.id)) { _, ids in
            if section == .favorites { selectedIDs.formIntersection(ids) }
        }
    }

    private var browserControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField(section == .history ? "搜尋目前觀看紀錄" : "搜尋目前收藏", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .accessibilityIdentifier("library.search")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted) }
                        .buttonStyle(.plain).accessibilityLabel("清除片庫搜尋")
                }
            }
            .font(.subheadline).padding(12)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 12) {
                Text("顯示 \(visibleIDs.count)／\(section == .history ? model.history.count : model.favorites.count) 部")
                    .font(.caption).foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
                Menu {
                    if section == .history {
                        Picker("觀看紀錄排序", selection: $historySort) {
                            ForEach(LibraryHistorySort.allCases) { Text($0.title).tag($0) }
                        }
                    } else {
                        Picker("收藏排序", selection: $favoriteSort) {
                            ForEach(LibraryFavoriteSort.allCases) { Text($0.title).tag($0) }
                        }
                    }
                } label: {
                    Label(section == .history ? historySort.title : favoriteSort.title, systemImage: "arrow.up.arrow.down")
                        .font(.caption).lineLimit(1)
                }
                .tint(Theme.accent).accessibilityLabel("片庫排序")
                Button(isEditing ? "完成" : "編輯") {
                    if isEditing { resetSelection() } else { selectedIDs = []; isEditing = true }
                }
                .font(.subheadline.weight(.semibold)).tint(Theme.accent)
                .disabled(visibleIDs.isEmpty && !isEditing)
                .accessibilityIdentifier("library.edit")
            }
        }
    }

    private var selectionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(libraryName) · 已選 \(selectedIDs.count) 部").font(.caption).foregroundStyle(Theme.muted)
            HStack(spacing: 14) {
                Button(selectedIDs == visibleIDs && !visibleIDs.isEmpty ? "取消全選" : "全選顯示結果") {
                    selectedIDs = selectedIDs == visibleIDs ? [] : visibleIDs
                }
                .font(.caption).disabled(visibleIDs.isEmpty)
                Spacer(minLength: 0)
                Button(section == .history ? "移除本機紀錄" : "取消收藏", role: .destructive) {
                    let selection = BatchSelection(ids: selectedIDs.intersection(visibleIDs), owner: model.selectedLibraryOwner,
                                                   revision: model.revision, libraryName: libraryName)
                    guard !selection.ids.isEmpty else { return }
                    confirmation = section == .history ? .removeHistory(selection) : .removeFavorites(selection)
                }
                .font(.caption.weight(.semibold)).buttonStyle(.bordered)
                .disabled(selectedIDs.isEmpty).accessibilityIdentifier("library.removeSelected")
            }
        }
        .padding(12).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var libraryContent: some View {
        if section == .history {
            if filteredHistory.isEmpty {
                StatusCard(icon: "clock", title: model.history.isEmpty && model.librarySyncing ? "正在載入觀看紀錄" : model.history.isEmpty ? "從第一個故事開始" : "沒有符合的觀看紀錄",
                           message: model.history.isEmpty && model.librarySyncing ? "讀到的片庫會先顯示，海報會接著補齊。" : model.history.isEmpty ? "播放過的劇集會留在這裡，隨時接著看。" : "調整搜尋或分集進度篩選，查看其他紀錄。")
                    .padding(.vertical, 22)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], alignment: .leading, spacing: 18) {
                    ForEach(filteredHistory) { historyItem($0) }
                }
            }
        } else if filteredFavorites.isEmpty {
            StatusCard(icon: "heart", title: model.favorites.isEmpty ? "喜歡的故事，先收藏" : "沒有符合的收藏",
                       message: model.favorites.isEmpty ? "在劇集頁點一下愛心，就能加入你的片庫。" : "調整搜尋文字，查看其他收藏。")
                .padding(.vertical, 30)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], alignment: .leading, spacing: 12) {
                ForEach(filteredFavorites) { favoriteItem($0) }
            }
        }
    }

    @ViewBuilder
    private func historyItem(_ record: WatchRecord) -> some View {
        if isEditing {
            selectableCard(record.series) { historyCard(record) }
        } else {
            NavigationLink(value: record.series) { historyCard(record) }
                .buttonStyle(.plain).contentShape(Rectangle())
                .contextMenu {
                    Button(role: .destructive) { model.removeHistory(record.series) } label: {
                        Label("移除本機紀錄", systemImage: "trash")
                    }
                }
        }
    }

    @ViewBuilder
    private func favoriteItem(_ series: Series) -> some View {
        if isEditing { selectableCard(series) { SeriesCard(series: series) } }
        else { NavigationLink(value: series) { SeriesCard(series: series) }.buttonStyle(.plain) }
    }

    private func selectableCard<Content: View>(_ series: Series, @ViewBuilder content: () -> Content) -> some View {
        Button {
            if !selectedIDs.insert(series.id).inserted { selectedIDs.remove(series.id) }
        } label: {
            content()
                .overlay(alignment: .topTrailing) {
                    Image(systemName: selectedIDs.contains(series.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title2).symbolRenderingMode(.palette)
                        .foregroundStyle(selectedIDs.contains(series.id) ? Theme.accent : .white, .black.opacity(0.75))
                        .padding(7)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(selectedIDs.contains(series.id) ? Theme.accent : .clear, lineWidth: 2)
                }
        }
        .buttonStyle(.plain).accessibilityLabel(series.title)
        .accessibilityValue(selectedIDs.contains(series.id) ? "已選取" : "未選取")
        .accessibilityAddTraits(selectedIDs.contains(series.id) ? .isSelected : [])
    }

    private var libraryName: String { model.showingAccountLibrary ? "帳號片庫" : "本機片庫" }

    private func selectionMatchesCurrentLibrary(_ selection: BatchSelection) -> Bool {
        selection.owner == model.selectedLibraryOwner && selection.revision == model.revision
    }

    private func resetSelection() { selectedIDs = []; isEditing = false; confirmation = nil }

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
                Button(model.accountNeedsLogin ? "重新登入" : model.retryRequiredSyncCount > 0 ? "同步並重試" : "立即同步") {
                    if model.accountNeedsLogin {
                        showingLogin = true
                    } else {
                        Task { await model.synchronizeLibrary() }
                    }
                }
                .buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
                .disabled(model.librarySyncing)
            }
            if model.retryRequiredSyncCount > 0 {
                Text("有 \(model.retryRequiredSyncCount) 筆變更尚未確認，已暫停自動重送；按「同步並重試」才會再次提交。")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
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
        if model.retryRequiredSyncCount > 0 { return "有 \(model.retryRequiredSyncCount) 筆變更需手動重試" }
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
