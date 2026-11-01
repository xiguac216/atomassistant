import SwiftUI

struct SourcesView: View {
    var body: some View {
        List { SourcesSections() }
            .listStyle(.insetGrouped)
            .navigationTitle("数据源")
            .navigationDestination(for: DataKind.self) { SourceDetailView(kind: $0) }
    }
}

/// 数据源的两个分区：持续上报（带开关）和按次授权（读取一次、实测读数）。设置页直接嵌在里面。
struct SourcesSections: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var live = LiveModel()
    @State private var alertText: String?
    @State private var working: Set<String> = []

    var body: some View {
        Group {
            Section {
                ForEach(DataKind.continuous) { kind in
                    row(kind)
                }
            } header: {
                Text("数据源与权限控制")
            } footer: {
                Text("勾选后，App 按后台设置的间隔采集（现在是每 \(model.syncMinutes) 分钟），系统允许时也会在后台刷新。打开开关时会请求所需的系统权限。")
            }

            Section {
                ForEach(DataKind.allCases.filter { $0.perUse }) { kind in
                    perUseRow(kind)
                }
            } header: {
                HStack {
                    Text("按次授权与敏感情报")
                    Spacer()
                    Text("每次问你").font(.caption.weight(.semibold)).textCase(nil)
                }
            } footer: {
                Text("这些最私人的数据不会自动上报。助手需要时会在「授权」里问你，你同意了才采集。点「读取一次」自己读一遍，读到的内容只显示在手机上。")
            }
        }
        .alert("无法开启", isPresented: Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })) {
            Button("好") {}
        } message: {
            Text(alertText ?? "")
        }
    }

    private func perUseRow(_ kind: DataKind) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                NavigationLink(value: kind) {
                    HStack(spacing: 12) {
                        IconTile(symbol: kind.symbol, tint: kind.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title).font(.system(size: 16))
                            Text(kind.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Button {
                    Haptics.tap()
                    Task { await live.run(kind, params: manualActions(for: kind).first?.params ?? [:]) }
                } label: {
                    Text("读取一次").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(CompactPrimaryStyle())
                .fixedSize()
            }
            HStack(alignment: .firstTextBaseline) {
                Text("实测读数").font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(readingText(kind))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .multilineTextAlignment(.trailing).lineLimit(2)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.vertical, 4)
    }

    private func readingText(_ kind: DataKind) -> String {
        guard let r = live.results[kind] else { return "还没读取" }
        switch r {
        case .running: return "正在读取…"
        case .failed(let why): return why
        case .ok(let reading):
            guard let first = reading.rows.first else { return "读到了，但没有可显示的内容" }
            return "\(first.label) \(first.value)"
        }
    }

    private func row(_ kind: DataKind) -> some View {
        let on = model.enabled.contains(kind.rawValue)
        return HStack(spacing: 12) {
            NavigationLink(value: kind) {
                HStack(spacing: 12) {
                    IconTile(symbol: kind.symbol, tint: kind.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title).font(.system(size: 16))
                        if let err = model.collectErrors[kind.rawValue], on {
                            Text(err).font(.footnote).foregroundStyle(.orange).lineLimit(2)
                        } else {
                            Text(kind.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            if working.contains(kind.rawValue) {
                ProgressView()
            } else {
                Toggle("", isOn: Binding(
                    get: { on },
                    set: { newValue in
                        Haptics.tap()
                        working.insert(kind.rawValue)
                        Task {
                            let why = await model.setEnabled(kind, newValue)
                            working.remove(kind.rawValue)
                            if let why { alertText = "\(kind.title)：\(why)"; Haptics.error() }
                        }
                    }
                ))
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

struct SourceDetailView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var live = LiveModel()
    let kind: DataKind
    @State private var busy = false

    private var manual: [ManualAction] { manualActions(for: kind) }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    IconTile(symbol: kind.symbol, tint: kind.tint, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(kind.title).font(.system(size: 20, weight: .semibold, design: .rounded))
                        Text(kind.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            if !kind.perUse {
                Section("状态") {
                    LabeledContent("持续上报", value: model.enabled.contains(kind.rawValue) ? "已开启" : "未开启")
                    LabeledContent("最近上传", value: relative(model.lastUpload[kind.rawValue]))
                    LabeledContent("累计上传", value: "\(model.uploadCount[kind.rawValue] ?? 0) 条")
                    if let err = model.collectErrors[kind.rawValue] {
                        Label(err, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                    }
                }
            }
            Section {
                if kind.perUse {
                    ForEach(manual) { m in
                        Button {
                            Haptics.tap()
                            Task { await live.run(kind, params: m.params) }
                        } label: {
                            HStack {
                                Text(m.title)
                                Spacer()
                                if case .running = live.results[kind] { ProgressView() }
                            }
                        }
                    }
                } else {
                    Button {
                        Haptics.tap()
                        Task { await live.run(kind) }
                    } label: {
                        HStack {
                            Text("读取一次")
                            Spacer()
                            if case .running = live.results[kind] { ProgressView() }
                        }
                    }
                    Button {
                        Haptics.tap()
                        busy = true
                        Task {
                            // 手动采集一次：没开启的也采，方便看这台手机上到底能拿到什么。
                            await model.collectOnce(kind)
                            busy = false
                        }
                    } label: {
                        HStack {
                            Text("现在采集并上传一次")
                            Spacer()
                            if busy { ProgressView() }
                        }
                    }
                    .disabled(busy)
                }
            } footer: {
                Text(kind.perUse
                     ? "你点按钮就是同意。读到的内容只显示在手机上，不会上传。"
                     : "「读取一次」只在手机上显示，用来核对准不准；「采集并上传」会先请求权限，再把结果交给服务器。")
            }
            if live.results[kind] != nil {
                ReadingSection(kind: kind, result: live.results[kind], onRefresh: nil)
            }
            if !kind.perUse, live.results[kind] == nil, let json = model.lastPayload(kind) {
                Section {
                    DisclosureGroup("最近一次采集到的原始内容") {
                        Text(json)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .font(.footnote)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
