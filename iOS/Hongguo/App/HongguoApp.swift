import SwiftUI

@main
@MainActor
struct HongguoApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.downloads)
                .onAppear { model.downloads.startObserving() }
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
