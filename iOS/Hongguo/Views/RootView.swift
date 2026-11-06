import SwiftUI
import UIKit
import HongguoCore

@MainActor
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: MainTab = .home

    private enum MainTab: String, Hashable {
        case home = "首頁", theater = "劇場", library = "我的"
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
        .task { model.resumeAccount() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.resumeAccount() }
        }
        .alert("儲存紀錄失敗", isPresented: Binding(get: { model.persistenceError != nil }, set: { if !$0 { model.persistenceError = nil } })) {
            Button("知道了") { model.persistenceError = nil }
        } message: { Text(model.persistenceError ?? "") }
    }

    private func detailDestination(_ series: Series) -> some View {
        DetailView(series: series).toolbar(.visible, for: .navigationBar)
    }
}
