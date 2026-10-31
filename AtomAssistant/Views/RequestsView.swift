import SwiftUI

struct RequestsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            Group {
                if model.requests.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 54)).foregroundStyle(.green.gradient)
                        Text("没有待处理的授权").font(.system(size: 20, weight: .semibold, design: .rounded))
                        Text("助手需要位置、详细健康记录这类最私人的数据时，会在这里问你。你同意了，手机才会去采集。")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                } else {
                    List {
                        Section {
                            ForEach(model.requests) { r in
                                NavigationLink(value: r) { RequestRow(request: r) }
                            }
                        } footer: {
                            Text("原因由助手填写，请核对后再决定。同意后数据只发给你自己的服务器。")
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: model.requests)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("授权")
            .navigationDestination(for: PendingRequest.self) { RequestDetailView(request: $0) }
            .refreshable { await model.refreshRequests() }
        }
    }
}

extension PendingRequest: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct RequestRow: View {
    let request: PendingRequest

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: request.dataKind?.symbol ?? "questionmark", tint: request.dataKind?.tint ?? .gray, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(request.dataKind?.title ?? request.kind).font(.system(size: 16, weight: .semibold))
                Text(request.reason).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

struct RequestDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: PendingRequest
    @State private var confirmDecline = false

    private var state: FulfilState { model.fulfil[request.id] ?? .idle }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                IconTile(symbol: request.dataKind?.symbol ?? "questionmark", tint: request.dataKind?.tint ?? .gray, size: 84)
                    .shadow(color: (request.dataKind?.tint ?? .gray).opacity(0.35), radius: 18, y: 8)
                    .padding(.top, 12)
                VStack(spacing: 6) {
                    Text("助手想要你的\(request.dataKind?.title ?? request.kind)")
                        .font(.system(size: 22, weight: .bold, design: .rounded)).multilineTextAlignment(.center)
                    Text(request.dataKind?.detail ?? "")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("助手写的原因", systemImage: "text.quote").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        Text(request.reason).font(.system(size: 17))
                        if let p = request.paramsSummary {
                            Divider()
                            Label(p, systemImage: "slider.horizontal.3").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Divider()
                        Label("有效至 " + request.expiresAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                stateView
                    .animation(.spring(response: 0.45, dampingFraction: 0.8), value: state)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("拒绝这条需求？", isPresented: $confirmDecline, titleVisibility: .visible) {
            Button("拒绝", role: .destructive) {
                Task { await model.decline(request); Haptics.warning(); dismiss() }
            }
        } message: {
            Text("助手会收到「用户拒绝」，不会再用同样的理由重复要。")
        }
        .onDisappear {
            if case .failed = state { model.resetFulfil(request.id) }
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch state {
        case .idle:
            VStack(spacing: 10) {
                Button {
                    Haptics.tap()
                    Task { await run() }
                } label: { Label("同意并采集", systemImage: "checkmark.circle.fill") }
                    .buttonStyle(PrimaryButtonStyle())
                Button { confirmDecline = true } label: { Text("拒绝") }
                    .buttonStyle(PrimaryButtonStyle(destructive: true))
            }
            .transition(.opacity)
        case .collecting, .uploading:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(state == .collecting ? "正在采集…" : "正在上传…")
                    .font(.system(size: 17, weight: .medium))
                if request.kind == DataKind.locationTrack.rawValue {
                    Text("轨迹要持续采集一段时间，期间可以切到别的 App，但不要划掉原子助手。")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .padding(.vertical, 20)
            .transition(.opacity)
        case .done(let n):
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
                Text("已交给助手（\(n) 条）").font(.system(size: 17, weight: .semibold))
            }
            .padding(.vertical, 16)
            .onAppear { Haptics.success() }
            .transition(.opacity)
        case .failed(let msg):
            VStack(spacing: 12) {
                Label(msg, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(.orange)
                Button { Task { await run() } } label: { Text("重试") }.buttonStyle(PrimaryButtonStyle())
                Button { confirmDecline = true } label: { Text("拒绝") }.buttonStyle(PrimaryButtonStyle(destructive: true))
            }
            .onAppear { Haptics.error() }
            .transition(.opacity)
        }
    }

    private func run() async {
        await model.approve(request)
        if case .done = state { try? await Task.sleep(nanoseconds: 1_200_000_000); dismiss() }
    }
}
