import SwiftUI

/// 「管理」页：后台除任务外的全部功能入口。和「任务」页一样要先刷脸。
struct ManageView: View {
    @StateObject private var store = AdminStore.shared
    @StateObject private var nav = PageNav()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $nav.path) {
            Group {
                if store.unlocked {
                    PageView(path: "/_hub", fallbackTitle: "管理")
                } else {
                    LockView()
                        .navigationTitle("管理")
                }
            }
            .navigationDestination(for: PageRoute.self) { PageView(path: $0.path) }
        }
        .environmentObject(store)
        .environmentObject(nav)
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background: store.noteBackground()
            case .active: store.noteForeground()
            default: break
            }
        }
        .onChange(of: store.unlocked) { unlocked in
            // 锁上之后把导航栈清掉，免得解锁后落在上次停的敏感页面里。
            if !unlocked { nav.path = [] }
        }
    }
}
