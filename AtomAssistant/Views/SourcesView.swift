import SwiftUI

struct SourcesView: View {
    @EnvironmentObject var model: AppModel
    @State private var alertText: String?
    @State private var working: Set<String> = []

    var body: some View {
        List {
                Section {
                    ForEach(DataKind.continuous) { kind in
                        row(kind)
                    }
                } header: {
                    Text("持续上报")
                } footer: {
                    Text("勾选后，App 按后台设置的间隔采集（现在是每 \(model.syncMinutes) 分钟），系统允许时也会在后台刷新。间隔在服务器后台「手机」页里改。打开开关时会请求所需的系统权限。")
                }

                Section {
                    ForEach(DataKind.allCases.filter { $0.perUse }) { kind in
                        HStack(spacing: 12) {
                            IconTile(symbol: kind.symbol, tint: kind.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.title).font(.system(size: 16))
                                Text(kind.detail).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("每次问你").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("按次授权")
                } footer: {
                    Text("这些最私人的数据不会自动上报。助手需要时会在「授权」里问你，你同意了才采集。")
                }
            }
        .listStyle(.insetGrouped)
        .navigationTitle("数据源")
        .navigationDestination(for: DataKind.self) { SourceDetailView(kind: $0) }
        .alert("无法开启", isPresented: Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })) {
            Button("好") {}
        } message: {
            Text(alertText ?? "")
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
    let kind: DataKind
    @State private var busy = false

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
            Section("状态") {
                LabeledContent("持续上报", value: model.enabled.contains(kind.rawValue) ? "已开启" : "未开启")
                LabeledContent("最近上传", value: relative(model.lastUpload[kind.rawValue]))
                LabeledContent("累计上传", value: "\(model.uploadCount[kind.rawValue] ?? 0) 条")
                if let err = model.collectErrors[kind.rawValue] {
                    Label(err, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                }
            }
            Section {
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
            } footer: {
                Text("会先请求这种数据需要的权限；采集结果会显示在下面，并上传到服务器。")
            }
            Section("最近一次采集到的内容") {
                if let json = model.lastPayload(kind) {
                    Text(json)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    Text("还没有采集过").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
