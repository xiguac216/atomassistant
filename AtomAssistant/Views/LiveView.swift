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

/// 一个手动读取按钮：按次授权类的数据平时不读，在数据源详情页里点了才读。
struct ManualAction: Identifiable {
    let title: String
    let params: [String: Any]
    var id: String { title }
}

/// 某种数据在详情页里能手动读取的方式。持续上报类只有一个「读取一次」，在详情页自己处理，这里返回空。
func manualActions(for kind: DataKind) -> [ManualAction] {
    switch kind {
    case .locationNow: return [ManualAction(title: "读取当前位置", params: [:])]
    case .locationTrack: return [ManualAction(title: "记录 2 分钟轨迹", params: ["minutes": 2.0])]
    case .bluetoothScan: return [ManualAction(title: "扫描蓝牙 10 秒", params: ["seconds": 10.0])]
    case .networkScan: return [ManualAction(title: "扫描局域网", params: ["seconds": 12.0])]
    case .motionQuery:
        return [ManualAction(title: "近 7 天运动历史", params: ["from": Date().addingTimeInterval(-7 * 86400), "to": Date()])]
    default: return []
    }
}

/// 一种数据的读数卡片。
struct ReadingSection: View {
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
