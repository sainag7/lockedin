import SwiftData
import SwiftUI

@main
struct LockedInApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model.settings)
                .environment(model.engine)
                .environment(model.diagnostics)
                .environment(model.notifications)
                .modelContainer(model.container)
                .preferredColorScheme(.dark)
                .tint(Palette.accent)
        }
    }
}
