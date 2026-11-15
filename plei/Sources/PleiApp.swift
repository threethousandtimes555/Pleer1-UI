import SwiftUI

@main
struct PleiApp: App {
    @StateObject private var store = Store()
    @StateObject private var player = Player()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(player)
                .preferredColorScheme(.dark)
                .onAppear { player.store = store }
                .onOpenURL { url in store.importFile(url) }
        }
    }
}
