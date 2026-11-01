import SwiftUI
import UIKit

/// 触感反馈。
enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

/// 设置 App 里那种彩色圆角方块图标。
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

/// 卡片：系统分组背景色上的圆角容器。
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// 主操作按钮：全宽。iOS 26 起用系统的液态玻璃（按下有系统自带的弹性反馈），更早的系统用实色圆角。
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .foregroundStyle(destructive ? Color.red : Color.white)
        if #available(iOS 26, *) {
            label.glassEffect(.regular.tint(destructive ? Color.red.opacity(0.18) : tint).interactive(), in: .capsule)
        } else {
            label
                .background(destructive ? Color.red.opacity(0.12) : tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .foregroundStyle(Color.accentColor)
        if #available(iOS 26, *) {
            label.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            label
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}

/// 「3 分钟前」这样的相对时间。
func relative(_ date: Date?) -> String {
    guard let date else { return "从未" }
    if abs(date.timeIntervalSinceNow) < 5 { return "刚刚" }
    let f = RelativeDateTimeFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.unitsStyle = .short
    return f.localizedString(for: date, relativeTo: Date())
}

/// 转动的图标，表示正在进行。iOS 18 起用系统的「旋转」符号动画，更早的系统自己转。
struct SpinningSymbol: View {
    let symbol: String
    @State private var turn = false

    var body: some View {
        if #available(iOS 18, *) {
            Image(systemName: symbol).symbolEffect(.rotate, isActive: true)
        } else {
            Image(systemName: symbol)
                .rotationEffect(.degrees(turn ? 360 : 0))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: turn)
                .onAppear { turn = true }
        }
    }
}

extension View {
    /// 符号换成另一个时用系统的「替换」过渡（iOS 17 起），更早的系统不做动画。
    @ViewBuilder func symbolReplace() -> some View {
        if #available(iOS 17, *) { self.contentTransition(.symbolEffect(.replace)) } else { self }
    }

    /// 向下滚动时让标签栏收起（iOS 26 起，系统自带）。
    @ViewBuilder func minimizeTabBarOnScroll() -> some View {
        if #available(iOS 26, *) { self.tabBarMinimizeBehavior(.onScrollDown) } else { self }
    }
}
