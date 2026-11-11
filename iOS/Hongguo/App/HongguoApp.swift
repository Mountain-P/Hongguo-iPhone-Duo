import SwiftUI

@main
@MainActor
struct HongguoApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var downloads = OfflineDownloadModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(downloads)
                .onAppear { downloads.startObserving() }
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
