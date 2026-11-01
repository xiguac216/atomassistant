import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            if model.paired {
                MainTabView()
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.03)), removal: .opacity))
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: model.paired)
    }
}

/// 四个标签：概览、授权、管理、设置。有新的授权需求时，打开 App 会直接弹出来。
struct MainTabView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var popup: PendingRequest?
    /// 这一次打开 App 已经弹过的需求：划掉不处理，同一次打开里不再弹，下次打开再提醒。
    @State private var shown: Set<String> = []

    var body: some View {
        TabView(selection: $tab) {
            OverviewView()
                .tabItem { Label("概览", systemImage: "square.grid.2x2.fill") }
                .tag(0)
            RequestsView()
                .tabItem { Label("授权", systemImage: "hand.raised.fill") }
                .badge(model.requests.count)
                .tag(1)
            ManageView()
                .tabItem { Label("管理", systemImage: "slider.horizontal.3") }
                .tag(2)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .minimizeTabBarOnScroll()
        .sheet(item: $popup, onDismiss: { maybePopup() }) { r in
            NavigationStack {
                RequestDetailView(request: r)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("稍后") { popup = nil } }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: model.requests) { _ in maybePopup() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { shown = []; maybePopup() }
        }
        .onAppear { maybePopup() }
    }

    private func maybePopup() {
        guard popup == nil, scenePhase == .active,
              let r = model.requests.first(where: { !shown.contains($0.id) }) else { return }
        shown.insert(r.id)
        Haptics.warning()
        popup = r
    }
}
