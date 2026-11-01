import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmUnpair = false

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var backgroundRefreshOn: Bool { UIApplication.shared.backgroundRefreshStatus == .available }
    private var totalUploaded: Int { model.uploadCount.values.reduce(0, +) }

    var body: some View {
        NavigationStack {
            List {
                Section("这台手机") {
                    HStack(spacing: 12) {
                        IconTile(symbol: "iphone", tint: .blue, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.deviceName).font(.headline)
                            Text("\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Label(connectionText, systemImage: connectionSymbol)
                            .font(.caption.weight(.semibold)).foregroundStyle(connectionColor)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(connectionColor.opacity(0.14), in: Capsule())
                    }
                    HStack(spacing: 12) {
                        IconTile(symbol: "server.rack", tint: .gray, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("服务器地址").font(.headline)
                            Text(URL(string: model.serverURL)?.host ?? model.serverURL)
                                .font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    HStack(alignment: .top, spacing: 16) {
                        metric("上次同步", relative(model.lastSync))
                        Divider()
                        metric("累计上传", "\(totalUploaded) 条")
                    }
                    .padding(.vertical, 4)
                    HStack(spacing: 12) {
                        IconTile(symbol: "clock.arrow.circlepath", tint: .indigo)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("上报间隔").font(.system(size: 16))
                            Text("在网页后台「手机设备」里修改").font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text("每 \(model.syncMinutes) 分钟").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        IconTile(symbol: "tray.and.arrow.up.fill", tint: .teal)
                        Text("待上传").font(.system(size: 16))
                        Spacer(minLength: 8)
                        Text("\(model.queueCount) 条 · 已开启 \(model.enabled.count) 项").foregroundStyle(.secondary)
                    }
                    NavigationLink {
                        LogView()
                    } label: {
                        HStack(spacing: 12) {
                            IconTile(symbol: "list.bullet.rectangle.fill", tint: .gray)
                            Text("活动日志").font(.system(size: 16))
                        }
                    }
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
                    if let err = model.syncError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("上报情况")
                } footer: {
                    Text("切到后台后，同步完全依赖系统的「后台 App 刷新」（设置 → 通用 → 后台 App 刷新）。系统自己决定什么时候唤醒，不保证按设定的间隔；打开 App 就会立刻同步一次。手动划掉 App 之后系统不会再唤醒它。")
                }

                SourcesSections()

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
            .navigationDestination(for: DataKind.self) { SourceDetailView(kind: $0) }
            .confirmationDialog("解除配对？", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("解除配对", role: .destructive) {
                    Haptics.warning()
                    model.unpair()
                }
            } message: {
                Text("会清掉这台手机上的令牌、待上传的数据、授权记录和日志。")
            }
        }
    }

    private var connectionText: String {
        if model.tokenInvalid { return "令牌已失效" }
        if model.syncError != nil { return "同步出错" }
        return "已连接"
    }

    private var connectionSymbol: String {
        if model.tokenInvalid { return "xmark.octagon.fill" }
        if model.syncError != nil { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private var connectionColor: Color {
        if model.tokenInvalid { return .red }
        if model.syncError != nil { return .orange }
        return .green
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
