import SwiftUI
import BudsCore

@main
struct BudsApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverRootView()
                .environmentObject(model)
        } label: {
            MenuBarLabelView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}
