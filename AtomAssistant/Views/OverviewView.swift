import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    let goToRequests: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if model.tokenInvalid { invalidBanner }
                    if !model.requests.isEmpty { requestsBanner }
                    connectionCard
                    recentCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: model.requests.count)
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: model.tokenInvalid)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("概览")
            .refreshable { await model.syncNow() }
        }
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
                                .transition(.scale.combined(with: .opacity))
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
                Divider()
                HStack {
                    stat("上次同步", relative(model.lastSync))
                    Spacer()
                    stat("待上传", "\(model.queueCount) 条")
                    Spacer()
                    stat("已开启", "\(model.enabled.count) 项")
                }
                if let err = model.syncError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                        .transition(.opacity)
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

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).contentTransition(.numericText())
        }
    }

    // MARK: 横幅

    private var requestsBanner: some View {
        Button {
            Haptics.tap()
            goToRequests()
        } label: {
            HStack(spacing: 12) {
                IconTile(symbol: "hand.raised.fill", tint: .orange, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.requests.count) 条授权需求等你处理").font(.system(size: 16, weight: .semibold))
                    Text("助手需要你同意后才会采集").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var invalidBanner: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "exclamationmark.triangle.fill", tint: .red, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("这台手机的令牌已失效").font(.system(size: 16, weight: .semibold))
                Text("请在后台重新添加设备，然后到「设置」里解除配对再重新配对。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: 最近上传

    private var recentCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("上传情况").font(.system(size: 17, weight: .semibold))
                let kinds = DataKind.continuous.filter { model.enabled.contains($0.rawValue) }
                if kinds.isEmpty {
                    Text("还没有开启任何数据。到「数据源」里勾选要上报的内容。")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(kinds) { kind in
                        HStack(spacing: 12) {
                            IconTile(symbol: kind.symbol, tint: kind.tint, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(kind.title).font(.system(size: 15, weight: .medium))
                                if let err = model.collectErrors[kind.rawValue] {
                                    Text(err).font(.caption).foregroundStyle(.orange).lineLimit(2)
                                } else {
                                    Text(relative(model.lastUpload[kind.rawValue])).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text("\(model.uploadCount[kind.rawValue] ?? 0)")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                    }
                }
            }
        }
    }
}
