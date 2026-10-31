import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmUnpair = false

    private var backgroundRefreshOn: Bool { UIApplication.shared.backgroundRefreshStatus == .available }

    var body: some View {
        NavigationStack {
            List {
                Section("这台手机") {
                    LabeledContent("设备名", value: model.deviceName)
                    LabeledContent("服务器", value: URL(string: model.serverURL)?.host ?? model.serverURL)
                    LabeledContent("连接", value: model.tokenInvalid ? "令牌已失效" : "正常")
                    LabeledContent("上报间隔", value: "每 \(model.syncMinutes) 分钟")
                }

                Section {
                    HStack(spacing: 12) {
                        IconTile(symbol: "arrow.triangle.2.circlepath", tint: backgroundRefreshOn ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("后台同步").font(.system(size: 16))
                            Text(backgroundRefreshOn ? "已开启：系统会在合适的时候唤醒 App 同步" : "「后台 App 刷新」是关的，切到后台后不会同步")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if !backgroundRefreshOn {
                        Button("打开系统设置") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                } header: {
                    Text("后台运行")
                } footer: {
                    Text("切到后台后，同步完全依赖系统的「后台 App 刷新」（设置 → 通用 → 后台 App 刷新）。系统自己决定什么时候唤醒，通常一天只有有限的几次，不保证按你设的间隔；想要最新的数据，打开 App 就会立刻同步一次。你手动划掉 App 之后系统不会再唤醒它。")
                }

                Section {
                    NavigationLink {
                        ShortcutsView()
                    } label: {
                        HStack(spacing: 12) {
                            IconTile(symbol: "bubble.left.and.text.bubble.right.fill", tint: .indigo)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("快捷指令").font(.system(size: 16))
                                Text("说一句话问助手，答复发到 QQ").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    NavigationLink {
                        ProbeView()
                    } label: {
                        HStack(spacing: 12) {
                            IconTile(symbol: "stethoscope", tint: .teal)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("能力探测").font(.system(size: 16))
                                Text("实测这台手机上哪些数据拿得到").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    NavigationLink {
                        LogView()
                    } label: {
                        HStack(spacing: 12) {
                            IconTile(symbol: "list.bullet.rectangle.fill", tint: .gray)
                            Text("活动日志").font(.system(size: 16))
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        confirmUnpair = true
                    } label: {
                        Text("解除配对并清除本机数据")
                    }
                } footer: {
                    Text("解除后这台手机不再上报。要彻底断开，也请在后台「手机」页吊销这台设备。")
                }

                Section {
                    LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                } footer: {
                    Text("原子助手 App 只把数据发给你自己配对的服务器，不经过任何第三方。")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .confirmationDialog("解除配对？", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("解除配对", role: .destructive) {
                    Haptics.warning()
                    model.unpair()
                }
            } message: {
                Text("会清掉这台手机上的令牌、待上传的数据和日志。")
            }
        }
    }
}

struct LogView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            if model.logs.isEmpty {
                Text("暂无记录").foregroundStyle(.secondary)
            }
            ForEach(model.logs.reversed()) { e in
                VStack(alignment: .leading, spacing: 3) {
                    Text(e.text)
                        .font(.system(size: 14))
                        .foregroundStyle(e.level == .error ? Color.red : e.level == .warn ? Color.orange : Color.primary)
                    Text(e.at.formatted(date: .abbreviated, time: .standard))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("活动日志")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("清空") { model.clearLogs() }.disabled(model.logs.isEmpty)
            }
        }
    }
}

struct ProbeView: View {
    @EnvironmentObject var model: AppModel
    @State private var results: [ProbeResult] = []
    @State private var running = false
    @State private var uploadNote: String?

    var body: some View {
        List {
            Section {
                Button {
                    Haptics.tap()
                    run()
                } label: {
                    HStack {
                        Text(results.isEmpty ? "开始探测" : "重新探测")
                        Spacer()
                        if running { ProgressView() }
                    }
                }
                .disabled(running)
                if !results.isEmpty {
                    Button {
                        Task {
                            uploadNote = await model.uploadProbe(Prober.report(results)) ?? "已上传，助手可以在 probe.report 里读到"
                        }
                    } label: { Text("上传探测报告") }
                    if let uploadNote { Text(uploadNote).font(.footnote).foregroundStyle(.secondary) }
                }
            } footer: {
                Text("只读探测，不会改动任何东西。私有接口会真的调用一次，看系统放不放行；没在播放音乐时，正在播放那一项会显示「没拿到」。")
            }

            if !results.isEmpty {
                summary
                ForEach(groups, id: \.self) { g in
                    Section(g) {
                        ForEach(results.filter { $0.group == g }) { r in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: symbol(r.status))
                                    .foregroundStyle(color(r.status))
                                    .font(.system(size: 18))
                                    .padding(.top, 1)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(r.name).font(.system(size: 15, weight: .medium))
                                    Text(r.detail).font(.footnote).foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("能力探测")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: results.count)
    }

    private var groups: [String] {
        var seen: [String] = []
        for r in results where !seen.contains(r.group) { seen.append(r.group) }
        return seen
    }

    private var summary: some View {
        Section {
            HStack {
                count("可用", results.filter { $0.status == .ok }.count, .green)
                Spacer()
                count("待验证", results.filter { $0.status == .partial }.count, .orange)
                Spacer()
                count("被拦", results.filter { $0.status == .blocked }.count, .red)
            }
            .padding(.vertical, 4)
        }
    }

    private func count(_ title: String, _ n: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(n)").font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(color)
                .contentTransition(.numericText())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func symbol(_ s: ProbeResult.Status) -> String {
        switch s {
        case .ok: return "checkmark.circle.fill"
        case .partial: return "questionmark.circle.fill"
        case .blocked: return "xmark.circle.fill"
        }
    }

    private func color(_ s: ProbeResult.Status) -> Color {
        switch s {
        case .ok: return .green
        case .partial: return .orange
        case .blocked: return .red
        }
    }

    private func run() {
        running = true
        uploadNote = nil
        Task {
            let r = await Prober.run()
            results = r
            running = false
            Haptics.success()
        }
    }
}
