import SwiftUI

/// 「对 Siri 说话」页：说明怎么直接用 Siri 问原子助手。
struct ShortcutsView: View {
    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    IconTile(symbol: "waveform.circle.fill", tint: .indigo, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("问原子助手").font(.system(size: 20, weight: .semibold, design: .rounded))
                        Text("说一句话，助手想好后通过 QQ 回复你").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                step("1", "唤醒 Siri，说「问原子助手」")
                step("2", "Siri 会问「想问原子助手什么？」")
                step("3", "你直接说出想问的话")
                step("4", "助手想好之后，答复发到你的 QQ")
            } header: {
                Text("怎么用")
            } footer: {
                Text("装上 App 之后就可以用，不用自己建快捷指令。也可以说「用原子助手提问」「让原子助手帮我看看」。")
            }

            Section("几点说明") {
                note("触发短语里不能直接带上问题。这是苹果的限制：短语里只能带固定选项，不能带自由说的话，所以要分两步说。")
                note("需要先在 App 里完成配对。答复发到哪个消息源，在服务器后台「手机」页设置，默认是 QQ。")
                note("QQ 机器人对主动发消息有限制，很久没在 QQ 里和助手说过话时，答复可能发不出去，先在 QQ 里和它说一句就好。")
                note("这样没法带截屏：iOS 不允许 App 自己截别的 App 的屏幕。")
            }

            Section {
                Label("如果对 Siri 说了没反应：到 设置 → Siri → 原子助手，确认「在 Siri 中显示 App」「学习此 App」是开的；说不通中文触发词时，可以试试英文说「Ask 原子助手」。", systemImage: "questionmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("对 Siri 说话")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(n)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
            Text(text).font(.system(size: 15))
        }
        .padding(.vertical, 2)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).foregroundStyle(.secondary)
    }
}
