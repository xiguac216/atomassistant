import SwiftUI

/// 概览：上面是连接状态和立即同步，下面是任务（要先刷脸）。
struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var store = AdminStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showNew = false
    @State private var path: [AdminTask] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if model.tokenInvalid {
                    Section { invalidBanner }.plainRow()
                }
                Section { connectionCard }.plainRow()
                if store.unlocked {
                    TaskSections()
                } else {
                    Section { unlockCard }.plainRow()
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("概览")
            .toolbar {
                if store.unlocked {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { Haptics.tap(); showNew = true } label: { Image(systemName: "square.and.pencil") }
                    }
                }
            }
            .navigationDestination(for: AdminTask.self) { TaskDetailView(task: $0) }
            .sheet(isPresented: $showNew) {
                NewTaskSheet { _ in Task { await store.reload() } }
            }
            .refreshable {
                await model.syncNow()
                await store.reload()
            }
            .task {
                // 停在这一页时每 10 秒刷新一次任务。
                while !Task.isCancelled {
                    await store.reload()
                    try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.tokenInvalid)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background: store.noteBackground()
            case .active: store.noteForeground()
            default: break
            }
        }
        .environmentObject(store)
    }

    // MARK: 连接状态

    private var connectionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(statusColor.opacity(0.15)).frame(width: 52, height: 52)
                        if model.syncing {
                            SpinningSymbol(symbol: "arrow.triangle.2.circlepath")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(statusColor)
                        } else {
                            Image(systemName: statusSymbol)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(statusColor)
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(statusTitle)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .contentTransition(.opacity)
                        Text(model.deviceName + " · " + (URL(string: model.serverURL)?.host ?? ""))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if let err = model.syncError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Button {
                    Haptics.tap()
                    Task { await model.syncNow() }
                } label: {
                    HStack(spacing: 8) {
                        if model.syncing { ProgressView().tint(.white) }
                        Text(model.syncing ? "正在同步…" : "立即同步")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.syncing)
            }
        }
    }

    private var statusColor: Color {
        if model.tokenInvalid { return .red }
        if model.syncError != nil { return .orange }
        return .green
    }

    private var statusSymbol: String {
        if model.tokenInvalid { return "xmark.octagon.fill" }
        if model.syncError != nil { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private var statusTitle: String {
        if model.tokenInvalid { return "需要重新配对" }
        if model.syncing { return "正在同步" }
        if model.syncError != nil { return "同步遇到问题" }
        return "已连接"
    }

    private var invalidBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: "exclamationmark.triangle.fill", tint: .red, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("这台手机的令牌已失效").font(.system(size: 16, weight: .semibold))
                Text("请在后台重新添加设备，然后到「设置」里解除配对再重新配对。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var unlockCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("任务已锁定", systemImage: Biometric.name == "面容 ID" ? "faceid" : "lock.fill")
                    .font(.system(size: 17, weight: .semibold))
                Text("用\(Biometric.name)解锁后，可以在这里看任务、批准动作、回复助手。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button {
                    Task {
                        if await store.unlock() == nil { Haptics.success(); await store.reload() } else { Haptics.error() }
                    }
                } label: { Label("用\(Biometric.name)解锁", systemImage: "lock.open.fill") }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

extension View {
    /// 列表里一整块自己画的卡片：去掉行的背景和内边距，让它和分组的左右边缘对齐。
    func plainRow() -> some View {
        self.listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
