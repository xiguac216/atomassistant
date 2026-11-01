import SwiftUI

/// 概览里的任务：标题行（数量、今日用量）、分段（进行中 / 待处理 / 已完成）、任务卡片。要先刷脸解锁。
struct TaskSections: View {
    @EnvironmentObject var store: AdminStore
    @State private var seg: Seg = .active

    enum Seg: String, CaseIterable, Identifiable {
        case active, waiting, done
        var id: String { rawValue }
        var title: String {
            switch self {
            case .active: return "进行中"
            case .waiting: return "待处理"
            case .done: return "已完成"
            }
        }
    }

    private static let ended: Set<String> = ["done", "failed", "cancelled"]

    private func belongs(_ t: AdminTask, _ s: Seg) -> Bool {
        switch s {
        case .waiting: return t.needsUser
        case .done: return Self.ended.contains(t.state)
        case .active: return !t.needsUser && !Self.ended.contains(t.state)
        }
    }

    var body: some View {
        Group {
            if store.forbidden {
                Section { forbiddenCard.cardRow() }
            } else {
                if let o = store.overview, !o.assistantOk {
                    Section { problem(o).cardRow() }
                }
                let shown = store.tasks.filter { belongs($0, seg) }
                Section {
                    header.cardRow(top: 14, bottom: 4)
                    Picker("分类", selection: $seg.animation(.spring(response: 0.35, dampingFraction: 0.85))) {
                        ForEach(Seg.allCases) { s in
                            let n = store.tasks.filter { belongs($0, s) }.count
                            Text(n > 0 && s == .waiting ? "\(s.title) \(n)" : s.title).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .cardRow(top: 4, bottom: 8)
                    if shown.isEmpty {
                        Text(store.loading ? "正在加载…" : "这一类没有任务")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 28)
                            .cardRow()
                    }
                    ForEach(shown) { t in
                        ZStack {
                            NavigationLink(value: t) { EmptyView() }.opacity(0)
                            TaskCard(task: t)
                        }
                        .cardRow()
                    }
                    if let e = store.error {
                        Label(e, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange).cardRow()
                    }
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.tasks)
        .task {
            // 分段是在手机上按状态分的，要把各种状态的任务都取回来。
            if store.filter != .all { store.filter = .all; await store.reload() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("任务").font(.title3.weight(.bold))
            Text("\(store.overview?.active ?? 0) 个进行中")
                .font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
            Spacer(minLength: 8)
            if let tokens = store.overview?.todayTokens {
                Text("今日 \(tokenText(tokens))")
                    .font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }

    private func problem(_ o: AdminOverview) -> some View {
        Label(o.assistantProblem ?? "助手没有正常运行", systemImage: "exclamationmark.octagon.fill")
            .font(.footnote).foregroundStyle(.red)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var forbiddenCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("这台手机还没有管理权限", systemImage: "lock.shield.fill").font(.system(size: 17, weight: .semibold))
                Text("为了安全，配对后的手机默认只能上报数据。请在电脑上打开网页后台的「手机」页，找到这台手机，点「允许管理后台」，再回来下拉刷新。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// 一张任务卡片：标题和状态、一句说明、时间和用量。要你处理的带一圈醒目的边。
struct TaskCard: View {
    let task: AdminTask

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(task.title).font(.headline).lineLimit(2)
                Spacer(minLength: 8)
                StateChip(task: task)
            }
            if let r = task.reason, !r.isEmpty {
                Text(r).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            if task.needsUser {
                Label("需要你处理，点开批准或回复", systemImage: "hand.raised.fill")
                    .font(.footnote.weight(.medium)).foregroundStyle(.orange)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Divider()
            HStack {
                Text(relative(task.updatedAt)).font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                if task.tokens > 0 {
                    Label(tokenText(task.tokens), systemImage: "circle.dotted")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            if task.needsUser {
                RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.orange.opacity(0.5), lineWidth: 1.5)
            }
        }
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
