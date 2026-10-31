import SwiftUI
import AppIntents

/// 「快捷指令」页：一键把「问原子助手」加到快捷指令，并说明怎么带上截屏、怎么一键触发。
struct ShortcutsView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        IconTile(symbol: "bubble.left.and.text.bubble.right.fill", tint: .indigo, size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("问原子助手").font(.system(size: 20, weight: .semibold, design: .rounded))
                            Text("说一句话，助手想好后通过 QQ 回复你").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if #available(iOS 16.0, *) {
                        // 打开「快捷指令」App，里面已经有原子助手提供好的「问助手」，点一下就能用或加到主屏幕。
                        ShortcutsLink().shortcutsLinkStyle(.automatic)
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text("点上面的按钮会跳到「快捷指令」App。原子助手提供的「问助手」已经在里面了，不用自己搭：点一下就是对它说话，也可以直接对 Siri 说「问原子助手」。")
            }

            Section("直接用语音") {
                step("1", "对 Siri 说「问原子助手」")
                step("2", "Siri 会问你想问什么，你直接说")
                step("3", "助手想好之后，答复发到你的 QQ")
            }

            Section {
                step("1", "打开「快捷指令」App，新建一个快捷指令")
                step("2", "先添加动作「截屏」")
                step("3", "再添加「问原子助手」，把「截屏」的结果接到它的「截屏」栏")
                step("4", "「想问什么」留成「每次询问」，运行时你说话就行")
            } header: {
                Text("想同时带上当前屏幕")
            } footer: {
                Text("iOS 不允许 App 自己截别的 App 的屏幕，所以截屏必须由快捷指令里的「截屏」动作来做。不加这个动作就只发你说的话。")
            }

            Section {
                step("•", "背面轻点：设置 → 辅助功能 → 触控 → 背面轻点，选上你建好的快捷指令")
                step("•", "操作按钮（iPhone 15 Pro 及之后）：设置 → 操作按钮 → 快捷指令")
                step("•", "锁屏或控制中心：给快捷指令添加对应的控件")
            } header: {
                Text("一键触发")
            }

            Section {
                Label("需要先在 App 里完成配对。答复发到哪个消息源，在服务器后台「手机」页设置，默认是 QQ。QQ 机器人对主动发消息有限制，很久没在 QQ 里和助手说过话时，答复可能发不出去，先在 QQ 里和它说一句就好。", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("快捷指令")
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
}
