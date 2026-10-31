import SwiftUI

/// 「任务」页：代替网页后台的概览和任务。打开要先刷脸。
struct TasksView: View {
    @StateObject private var store = AdminStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showNew = false
    @State private var path: [AdminTask] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.unlocked {
                    content
                } else {
                    LockView()
                }
            }
            .navigationTitle("任务")
            .toolbar {
                if store.unlocked {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { Haptics.tap(); showNew = true } label: { Image(systemName: "square.and.pencil") }
                    }
                }
            }
            .navigationDestination(for: AdminTask.self) { TaskDetailView(task: $0) }
            .sheet(isPresented: $showNew) {
                NewTaskSheet { id in
                    Task { await store.reload() }
                    _ = id
                }
            }
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

    private var content: some View {
        List {
            if store.forbidden {
                Section { forbiddenCard }
            } else {
                if let o = store.overview {
                    Section { summary(o) }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    Picker("筛选", selection: $store.filter) {
                        ForEach(AdminStore.Filter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: store.filter) { _ in Task { await store.reload() } }
                }
                .listRowBackground(Color.clear)

                let waiting = store.tasks.filter(\.needsUser)
                let rest = store.tasks.filter { !$0.needsUser }
                if !waiting.isEmpty {
                    Section {
                        ForEach(waiting) { row($0) }
                    } header: {
                        Label("需要你处理", systemImage: "hand.raised.fill").foregroundStyle(.orange)
                    }
                }
                Section {
                    if rest.isEmpty && waiting.isEmpty {
                        Text(store.loading ? "正在加载…" : "没有任务").foregroundStyle(.secondary)
                    }
                    ForEach(rest) { row($0) }
                } header: {
                    if !waiting.isEmpty { Text("其他") }
                }
                if let e = store.error {
                    Section { Label(e, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.reload() }
        .task {
            // 停在这一页时每 10 秒刷新一次。
            while !Task.isCancelled {
                await store.reload()
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.tasks)
    }

    private func row(_ t: AdminTask) -> some View {
        NavigationLink(value: t) {
            HStack(spacing: 12) {
                StateDot(task: t)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.title).font(.system(size: 16, weight: .medium)).lineLimit(2)
                    Text(subtitle(t)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                StateChip(task: t)
            }
            .padding(.vertical, 2)
        }
    }

    private func subtitle(_ t: AdminTask) -> String {
        if t.needsUser, let r = t.reason, !r.isEmpty { return r }
        return relative(t.updatedAt)
    }

    private func summary(_ o: AdminOverview) -> some View {
        VStack(spacing: 10) {
            if !o.assistantOk {
                Label(o.assistantProblem ?? "助手没有正常运行", systemImage: "exclamationmark.octagon.fill")
                    .font(.footnote).foregroundStyle(.red)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            HStack(spacing: 10) {
                stat("待处理", o.waiting, .orange)
                stat("进行中", o.active, .blue)
                stat("待核实记忆", o.memoryPending ?? 0, .purple)
            }
            if let cost = o.todayCostYuan, let tokens = o.todayTokens {
                HStack {
                    Label("今日用量", systemImage: "chart.bar.fill").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(tokens.formatted()) tokens · ¥\(String(format: "%.2f", cost))")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.vertical, 4)
    }

    private func stat(_ title: String, _ n: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(n)").font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(color)
                .contentTransition(.numericText())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var forbiddenCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("这台手机还没有管理权限", systemImage: "lock.shield.fill").font(.system(size: 17, weight: .semibold))
            Text("为了安全，配对后的手机默认只能上报数据。请在电脑上打开网页后台的「手机」页，找到这台手机，点「允许管理后台」，再回来下拉刷新。")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - 状态的小部件

private func stateColor(_ t: AdminTask) -> Color {
    switch t.state {
    case "running": return .blue
    case "waiting": return t.needsUser ? .orange : .teal
    case "suspended": return .orange
    case "done": return .green
    case "failed": return .red
    default: return .gray
    }
}

struct StateDot: View {
    let task: AdminTask
    var body: some View {
        Circle().fill(stateColor(task)).frame(width: 10, height: 10)
            .overlay {
                if task.state == "running" {
                    Circle().stroke(stateColor(task).opacity(0.4), lineWidth: 4).scaleEffect(1.6)
                }
            }
    }
}

struct StateChip: View {
    let task: AdminTask
    var body: some View {
        Text(task.stateText)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(stateColor(task))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(stateColor(task).opacity(0.14), in: Capsule())
    }
}

// MARK: - 锁屏

/// 管理功能的门：要刷脸（或输入设备密码）才打开。
struct LockView: View {
    @EnvironmentObject var store: AdminStore
    @State private var message: String?
    @State private var trying = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: Biometric.name == "面容 ID" ? "faceid" : "lock.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("管理功能已锁定").font(.system(size: 22, weight: .bold, design: .rounded))
            Text("用\(Biometric.name)解锁后，可以在这里看任务、批准动作、回复助手。")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let message {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            Button {
                Task { await run() }
            } label: {
                Label("用\(Biometric.name)解锁", systemImage: "lock.open.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(trying)
            .padding(.horizontal, 32)
            Spacer()
        }
        .padding()
        .task { await run() }
    }

    private func run() async {
        trying = true
        defer { trying = false }
        if let why = await store.unlock() {
            message = why
            Haptics.error()
        } else {
            message = nil
            Haptics.success()
        }
    }
}

// MARK: - 新建

struct NewTaskSheet: View {
    @EnvironmentObject var store: AdminStore
    @Environment(\.dismiss) private var dismiss
    let onCreated: (String) -> Void
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $text)
                    .focused($focused)
                    .frame(minHeight: 160)
                    .padding(10)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                Text("写清楚想让助手做什么，它会自己规划并执行，需要你确认的动作会在「任务」里等你。")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .background(Color(.systemGroupedBackground))
            .navigationTitle("新任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发送") { Task { await send() } }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            let id = try await store.create(goal: text)
            Haptics.success()
            onCreated(id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }
}
