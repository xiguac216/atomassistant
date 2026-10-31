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

struct MainTabView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            OverviewView(goToRequests: { withAnimation { tab = 1 } })
                .tabItem { Label("概览", systemImage: "square.grid.2x2.fill") }
                .tag(0)
            RequestsView()
                .tabItem { Label("授权", systemImage: "hand.raised.fill") }
                .badge(model.requests.count)
                .tag(1)
            SourcesView()
                .tabItem { Label("数据源", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(2)
            LiveView()
                .tabItem { Label("实测", systemImage: "checklist") }
                .tag(3)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(4)
        }
        // 助手要读 NFC 标签：打开 App 就弹出这一页，并立刻亮出系统的读取框。
        .sheet(item: $model.nfcAutoRequest) { r in
            NavigationStack {
                RequestDetailView(request: r, autoStart: true)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("关闭") { model.nfcAutoRequest = nil } }
                    }
            }
        }
    }
}
