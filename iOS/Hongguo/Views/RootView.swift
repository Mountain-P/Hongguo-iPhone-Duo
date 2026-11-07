import SwiftUI
import UIKit
import HongguoCore

@MainActor
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: MainTab = .home
    @StateObject private var libraryFlush = LibraryFlushCoordinator()

    private enum MainTab: String, Hashable {
        case home = "首頁", preview = "試看", theater = "劇場", library = "我的"
    }

    private var tabBarVisibility: Visibility { model.isImmersivePlayback ? .hidden : .visible }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeFeedView(isActive: selectedTab == .home)
                    .navigationDestination(for: Series.self) { detailDestination($0) }
                    .toolbar(tabBarVisibility, for: .tabBar)
            }
            .toolbar(tabBarVisibility, for: .tabBar)
            .tabItem { Label(MainTab.home.rawValue, systemImage: "house.fill") }
            .tag(MainTab.home)

            NavigationStack {
                RecommendationPreviewView(isActive: selectedTab == .preview)
                    .toolbar(tabBarVisibility, for: .tabBar)
            }
            .toolbar(tabBarVisibility, for: .tabBar)
            .tabItem { Label(MainTab.preview.rawValue, systemImage: "play.rectangle.fill") }
            .tag(MainTab.preview)

            NavigationStack {
                ExploreView()
                    .navigationDestination(for: Series.self) { detailDestination($0) }
                    .toolbar(tabBarVisibility, for: .tabBar)
            }
            .toolbar(tabBarVisibility, for: .tabBar)
            .tabItem { Label(MainTab.theater.rawValue, systemImage: "play.rectangle.on.rectangle") }
            .tag(MainTab.theater)

            NavigationStack {
                LibraryView()
                    .navigationDestination(for: Series.self) { detailDestination($0) }
                    .toolbar(tabBarVisibility, for: .tabBar)
            }
            .toolbar(tabBarVisibility, for: .tabBar)
            .tabItem { Label(MainTab.library.rawValue, systemImage: "person.crop.circle") }
            .tag(MainTab.library)
        }
        .toolbar(tabBarVisibility, for: .tabBar)
        .background(Theme.background)
        .statusBarHidden(model.isImmersivePlayback)
        .onChange(of: selectedTab) { _, _ in
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .task { _ = PlaybackDiagnostics.shared; model.resumeAccount() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.resumeAccount() }
            else { libraryFlush.flush(model) }
        }
        .onChange(of: model.isImmersivePlayback) { _, immersive in
            if !immersive { libraryFlush.flush(model) }
        }
        .alert("儲存紀錄失敗", isPresented: Binding(get: { model.persistenceError != nil }, set: { if !$0 { model.persistenceError = nil } })) {
            Button("知道了") { model.persistenceError = nil }
        } message: { Text(model.persistenceError ?? "") }
    }

    private func detailDestination(_ series: Series) -> some View {
        DetailView(series: series).toolbar(.visible, for: .navigationBar)
    }
}

/// Keep a local save alive briefly when the scene is about to be suspended.
@MainActor
private final class LibraryFlushCoordinator: ObservableObject {
    private var operation: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var anotherPass = false

    func flush(_ model: AppModel) {
        guard operation == nil else { anotherPass = true; return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save viewing progress") { [weak self] in
            self?.endAssertion()
        }
        operation = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.anotherPass = false
                // Child player scene callbacks enqueue the final position in this run loop.
                await Task.yield()
                await model.flushLibrary()
            } while self.anotherPass
            self.endAssertion()
            self.operation = nil
        }
    }

    private func endAssertion() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
