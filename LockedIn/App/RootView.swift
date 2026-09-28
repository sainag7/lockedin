import SwiftUI

struct RootView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            if settings.hasOnboarded {
                RootTabView()
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: settings.hasOnboarded)
    }
}

enum AppTab: Hashable {
    case home, stats, history
}

struct RootTabView: View {
    @Environment(SessionEngine.self) private var engine
    @State private var tab: AppTab = .home

    var body: some View {
        @Bindable var engine = engine
        TabView(selection: $tab) {
            Tab("Lock In", systemImage: "lock.fill", value: AppTab.home) {
                HomeView(showStats: { tab = .stats })
            }
            Tab("Stats", systemImage: "chart.bar.xaxis", value: AppTab.stats) {
                StatsView()
            }
            Tab("History", systemImage: "calendar", value: AppTab.history) {
                HistoryView()
            }
        }
        // Unlocking mid-session always lands on the session screen.
        .onChange(of: engine.lastCredit) { _, credit in
            if credit != nil { tab = .home }
        }
        .sheet(item: $engine.summary) { summary in
            SummaryView(summary: summary)
        }
    }
}
