import SwiftUI

/// 实测页的状态：每种数据读一次，结果只显示在手机上，不上传。
@MainActor
final class LiveModel: ObservableObject {
    enum Result {
        case running
        case ok(Reading)
        case failed(String)
    }

    @Published private(set) var results: [DataKind: Result] = [:]
    @Published private(set) var runningAll = false

    func run(_ kind: DataKind, params: [String: Any] = [:]) async {
        guard let c = Collectors.all[kind] else { return }
        results[kind] = .running
        if let why = await c.authorize() {
            results[kind] = .failed(why)
            return
        }
        do {
            let samples = try await c.collect(params: params)
            results[kind] = .ok(Readable.reading(kind: kind, samples: samples))
        } catch {
            results[kind] = .failed(error.localizedDescription)
        }
    }

    /// 把所有可持续上报的数据挨个读一遍。会依次弹出各种权限框。
    func runAll() async {
        runningAll = true
        for kind in DataKind.continuous { await run(kind) }
        runningAll = false
        Haptics.success()
    }
}

struct LiveView: View {
    @StateObject private var live = LiveModel()

    /// 手动读取的按次授权类：每种给一个按钮和它的参数。
    private struct Manual: Identifiable {
        let kind: DataKind
        let title: String
        let params: [String: Any]
        var id: String { kind.rawValue + title }
    }

    private var manual: [Manual] {
        let week = Date().addingTimeInterval(-7 * 86400)
        return [
            Manual(kind: .locationNow, title: "读取当前位置", params: [:]),
            Manual(kind: .locationTrack, title: "记录 2 分钟轨迹", params: ["minutes": 2.0]),
            Manual(kind: .bluetoothScan, title: "扫描蓝牙 10 秒", params: ["seconds": 10.0]),
            Manual(kind: .networkScan, title: "扫描局域网", params: ["seconds": 12.0]),
            Manual(kind: .motionQuery, title: "近 7 天运动历史", params: ["from": week, "to": Date()]),
        ]
    }

    var body: some View {
        List {
                Section {
                    Button {
                        Haptics.tap()
                        Task { await live.runAll() }
                    } label: {
                        HStack {
                            Label("读取全部持续数据", systemImage: "arrow.clockwise.circle.fill")
                            Spacer()
                            if live.runningAll { ProgressView() }
                        }
                    }
                    .disabled(live.runningAll)
                } footer: {
                    Text("在手机上把每一项数据读一遍，用中文逐项显示，原始数据在每项下面可以展开。只显示，不上传，用来核对读得准不准。第一次会依次弹出各种权限请求。")
                }

                ForEach(DataKind.continuous) { kind in
                    ReadingSection(kind: kind, result: live.results[kind]) {
                        Task { await live.run(kind) }
                    }
                }

                Section {
                    ForEach(manual) { m in
                        Button {
                            Haptics.tap()
                            Task { await live.run(m.kind, params: m.params) }
                        } label: {
                            HStack(spacing: 12) {
                                IconTile(symbol: m.kind.symbol, tint: m.kind.tint)
                                Text(m.title).foregroundStyle(.primary)
                                Spacer()
                                if case .running = live.results[m.kind] { ProgressView() }
                            }
                        }
                    }
                } header: {
                    Text("按次授权类（手动读取）")
                } footer: {
                    Text("这些最私人的数据平时不会自动读取。你点按钮就是同意，读到的内容同样只显示在手机上。")
                }

                ForEach(manual.map(\.kind).uniqued()) { kind in
                    if live.results[kind] != nil {
                        ReadingSection(kind: kind, result: live.results[kind], onRefresh: nil)
                    }
                }
            }
        .listStyle(.insetGrouped)
        .navigationTitle("实测")
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

/// 一种数据的读数卡片。
private struct ReadingSection: View {
    let kind: DataKind
    let result: LiveModel.Result?
    let onRefresh: (() -> Void)?

    var body: some View {
        Section {
            switch result {
            case .none:
                Text("还没读取").foregroundStyle(.secondary)
            case .running:
                HStack(spacing: 10) { ProgressView(); Text("正在读取…").foregroundStyle(.secondary) }
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
            case .ok(let r):
                if r.rows.isEmpty {
                    Text("读到了，但没有可显示的内容").foregroundStyle(.secondary)
                }
                ForEach(r.rows) { row in
                    HStack(alignment: .top) {
                        Text(row.label).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(row.value).multilineTextAlignment(.trailing).textSelection(.enabled)
                    }
                    .font(.system(size: 15))
                }
                DisclosureGroup("原始数据") {
                    Text(r.raw)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
                .font(.footnote)
            }
        } header: {
            HStack(spacing: 8) {
                Image(systemName: kind.symbol).foregroundStyle(kind.tint)
                Text(kind.title)
                Spacer()
                if let onRefresh {
                    Button { Haptics.tap(); onRefresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                }
            }
        }
    }
}
