import SwiftUI
import UserNotifications

@main
struct AtomAssistantApp: App {
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 后台任务必须在 App 启动完成之前注册。
        BackgroundSync.register()
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
                // 切到后台就停掉前台循环，之后靠系统的「后台 App 刷新」唤醒。
                model.stopLoop()
                if model.paired { BackgroundSync.schedule() }
            default:
                break
            }
        }
    }
}
