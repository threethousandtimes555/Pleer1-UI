import SwiftUI

@main
struct PleiApp: App {
    @StateObject private var store = Store()
    @StateObject private var player = Player()
    @Environment(\.scenePhase) private var phase
    @AppStorage("theme") private var themeRaw = "soft"

    init() {
        AppTheme.current.applyAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .id(themeRaw)
                .environmentObject(store)
                .environmentObject(player)
                .environmentObject(player.clock)
                .preferredColorScheme((AppTheme(rawValue: themeRaw) ?? .soft).scheme)
                .onAppear { player.store = store }
                .onOpenURL { url in store.importFiles([url]) }
                .onChange(of: phase) { newPhase in
                    if newPhase == .active { store.importInbox() }
                }
        }
    }
}
