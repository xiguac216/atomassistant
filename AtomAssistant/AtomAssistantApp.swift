import SwiftUI
import UserNotifications

@main
struct AtomAssistantApp: App {
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 后台任务必须在 App 启动完成之前注册。
        BackgroundSync.register()
        // 被位置唤醒、在后台启动时也要按上次的开关恢复后台运行。
        Task { @MainActor in AppModel.shared.resumeBackground() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onOpenURL { model.handle(url: $0) }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                if model.paired { model.startLoop() }
            case .background:
                // 开了后台保活就让同步循环继续跑，否则切到后台就停。
                if !model.keepAlive { model.stopLoop() }
                if model.paired { BackgroundSync.schedule() }
            default:
                break
            }
        }
    }
}
