import SwiftUI

@main
struct FridgeApp: App {
    @StateObject private var store = FridgeStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .tint(Color(red: 0.12, green: 0.44, blue: 0.55))
                .task {
                    Reminders.requestPermission()
                    store.refreshReminders()
                }
        }
    }
}
