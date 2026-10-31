import SwiftUI

/// 一件任务的详情：它在做什么、等你批什么、做过哪些步骤。
struct TaskDetailView: View {
    @EnvironmentObject var store: AdminStore
    @Environment(\.dismiss) private var dismiss
    let task: AdminTask

    @State private var detail: AdminTaskDetail?
    @State private var error: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var reply = ""
    @State private var showReject = false
    @State private var rejectReason = ""
    @State private var confirmCancel = false
    @State private var confirmDelete = false

    private var current: AdminTask { detail?.task ?? task }

    var body: some View {
        List {
            headerSection
            if let d = detail {
                if let a = d.approval { approvalSection(a) }
                if let q = d.question { questionSection(q) }
                if let b = d.overBudget { budgetSection(b) }
                if current.live && d.approval == nil { replySection }
                goalSection(d.goal)
                stepsSection(d.steps)
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red) }
            }
            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    if current.live {
                        Button(role: .destructive) { confirmCancel = true } label: { Label("取消这个任务", systemImage: "xmark.circle") }
                    } else {
                        Button { tidy("archive", "已归档。") } label: { Label("归档", systemImage: "archivebox") }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("删除", systemImage: "trash") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .confirmationDialog("取消这个任务？", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("取消任务", role: .destructive) { act("任务已取消。") { try await store.cancel(task.id) } }
        } message: {
            Text("取消后不会再被调度。")
        }
        .confirmationDialog("删除这个任务？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { tidy("delete", "已删除。", leave: true) }
        } message: {
            Text("连同步骤和记录一起删除，找不回来。")
        }
        .alert("驳回这个动作", isPresented: $showReject) {
            TextField("修改意见（可不填）", text: $rejectReason)
            Button("驳回", role: .destructive) {
                let r = rejectReason
                rejectReason = ""
                act("已驳回，助手会按你的意见重新处理。") { try await store.reject(task.id, reason: r) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("助手会收到你的意见并换个办法。")
        }
        .refreshable { await load() }
        .task {
            // 任务还在办的时候，每 4 秒刷新一次。
            while !Task.isCancelled {
                await load()
                guard current.live else { break }
                try? await Task.sleep(nanoseconds: 4 * 1_000_000_000)
            }
        }
    }

    // MARK: 各节

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Text(current.title).font(.system(size: 20, weight: .semibold, design: .rounded))
                    Spacer(minLength: 8)
                    StateChip(task: current)
                }
                HStack(spacing: 14) {
                    Label(relative(current.createdAt), systemImage: "clock").font(.footnote).foregroundStyle(.secondary)
                    Label("\(current.tokens.formatted()) tokens", systemImage: "circle.grid.2x2").font(.footnote).foregroundStyle(.secondary)
                    Label("¥" + String(format: "%.2f", current.costYuan), systemImage: "yensign.circle").font(.footnote).foregroundStyle(.secondary)
                }
                if let r = current.reason, !r.isEmpty, !current.needsUser {
                    Text(r).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func approvalSection(_ a: AdminApproval) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label("助手想执行：\(a.tool)", systemImage: "hand.raised.fill")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.orange)
                if a.irreversible {
                    Label("这一步做了就收不回来", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.red)
                }
                if let why = a.why, !why.isEmpty { Text(why).font(.subheadline) }
                if let rule = a.rule, !rule.isEmpty {
                    Text(rule).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(a.fields ?? []) { f in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.key).font(.caption).foregroundStyle(.secondary)
                        Text(f.value).font(.system(size: 14, design: .monospaced)).textSelection(.enabled)
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        Haptics.tap()
                        act("已批准，任务继续执行。") { try await store.approve(task.id) }
                    } label: { Text("批准") }
                        .buttonStyle(PrimaryButtonStyle(tint: .green))
                    Button { showReject = true } label: { Text("驳回") }
                        .buttonStyle(PrimaryButtonStyle(destructive: true))
                }
                .disabled(busy)
            }
            .padding(.vertical, 4)
        } header: {
            Text("等你批准")
        }
    }

    private func questionSection(_ q: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("助手在问你", systemImage: "questionmark.bubble.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(.orange)
                Text(q).font(.system(size: 16))
                replyField(placeholder: "回答助手")
            }
            .padding(.vertical, 4)
        }
    }

    private var replySection: some View {
        Section {
            replyField(placeholder: "补充说明或新的要求")
        } header: {
            Text("给助手留言")
        }
    }

    private func replyField(placeholder: String) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $reply, axis: .vertical)
                .lineLimit(1...5)
            Button {
                let text = reply
                reply = ""
                Haptics.tap()
                act("已发送。") { try await store.reply(task.id, text: text) }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
            }
            .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
        }
    }

    private func budgetSection(_ b: AdminOverBudget) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("预算用尽，任务已挂起", systemImage: "gauge.badge.minus").font(.system(size: 16, weight: .semibold)).foregroundStyle(.orange)
                Text("已用 ¥\(String(format: "%.2f", b.usageYuan))。建议把上限提高到：\(b.suggestTokens.formatted()) tokens、¥\(String(format: "%.2f", b.suggestYuan))、\(String(format: "%.1f", b.suggestHours)) 小时。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button { act("已提高上限，任务继续执行。") { try await store.raiseBudget(task.id, b) } } label: { Text("按建议提高并继续") }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(busy)
            }
            .padding(.vertical, 4)
        }
    }

    private func goalSection(_ goal: String) -> some View {
        Section("任务内容") {
            Text(goal).font(.system(size: 15)).textSelection(.enabled)
        }
    }

    private func stepsSection(_ steps: [AdminStep]) -> some View {
        Section {
            if steps.isEmpty { Text("还没有步骤").foregroundStyle(.secondary) }
            ForEach(steps) { s in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        if let e = s.error, !e.isEmpty { Text(e).font(.footnote).foregroundStyle(.red) }
                        if let i = s.input, !i.isEmpty { block("输入", i) }
                        if let o = s.output, !o.isEmpty { block("输出", o) }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: icon(s.status)).foregroundStyle(color(s.status))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.tool ?? label(s.type)).font(.system(size: 15, weight: .medium))
                            Text("第 \(s.seq) 步 · \(statusText(s.status))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("执行过程")
        }
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func label(_ type: String) -> String {
        switch type {
        case "llm": return "模型推理"
        case "tool": return "调用工具"
        case "wait": return "等待"
        default: return type
        }
    }

    private func statusText(_ s: String) -> String {
        switch s {
        case "done": return "完成"
        case "failed": return "失败"
        case "pending": return "进行中"
        case "awaiting": return "等你批准"
        case "approved": return "已批准"
        case "skipped": return "已跳过"
        default: return s
        }
    }

    private func icon(_ s: String) -> String {
        switch s {
        case "done", "approved": return "checkmark.circle.fill"
        case "failed": return "xmark.circle.fill"
        case "awaiting": return "hand.raised.fill"
        case "pending": return "ellipsis.circle.fill"
        default: return "circle"
        }
    }

    private func color(_ s: String) -> Color {
        switch s {
        case "done", "approved": return .green
        case "failed": return .red
        case "awaiting": return .orange
        case "pending": return .blue
        default: return .gray
        }
    }

    // MARK: 动作

    private func load() async {
        do {
            detail = try await store.detail(task.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 归档或删除一个已结束的任务。
    private func tidy(_ action: String, _ done: String, leave: Bool = false) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await store.batch(task.id, action: action)
                Haptics.success()
                await store.reload()
                if leave { dismiss() } else { notice = done; await load() }
            } catch {
                self.error = error.localizedDescription
                Haptics.error()
            }
        }
    }

    /// 做一个动作，成功后刷新并提示，失败把原因显示出来。
    private func act(_ done: String, _ op: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await op()
                notice = done
                Haptics.success()
                await load()
                await store.reload()
            } catch {
                self.error = error.localizedDescription
                Haptics.error()
            }
        }
    }
}
