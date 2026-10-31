import AppIntents
import UIKit

/// 快捷指令里的「问原子助手」动作：把你说的话（可附一张截屏）交给助手，答复通过后台设置的消息源（默认 QQ）发回给你。
///
/// 它在 App 自己的进程里后台运行，不会把 App 拉到前台。
@available(iOS 16.0, *)
struct AskAssistantIntent: AppIntent {
    static var title: LocalizedStringResource = "问原子助手"
    static var description = IntentDescription(
        "把你说的话交给原子助手，它想好之后通过 QQ 回复你。可以附带一张截屏。",
        categoryName: "原子助手"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "想问什么", requestValueDialog: "想问原子助手什么？")
    var question: String

    @Parameter(
        title: "截屏（可选）",
        description: "在快捷指令里先加一个「截屏」动作，把它的结果接到这里；不接就不带截屏。",
        supportedTypeIdentifiers: ["public.image"]
    )
    var screenshot: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("问原子助手 \(\.$question)，截屏 \(\.$screenshot)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let server = Defaults.serverURL, let base = URL(string: server), let token = Keychain.get("deviceToken") else {
            throw AskError.notPaired
        }
        var imageData: Data?
        if let screenshot {
            guard let jpeg = Self.compressed(screenshot.data) else { throw AskError.badImage }
            imageData = jpeg
        }
        do {
            try await APIClient(base: base, token: token).ask(text: question, screenshot: imageData, mime: "image/jpeg")
        } catch let e as APIError {
            throw AskError.failed(e.localizedDescription)
        }
        return .result(dialog: "已发给原子助手，想好后会通过 QQ 回复你。")
    }

    /// 截屏很大：缩到长边 1600 像素、压成 JPEG，服务器一次最多收 3MB。
    static func compressed(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 1600 / longest)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.7)
    }
}

enum AskError: Error, CustomLocalizedStringResourceConvertible {
    case notPaired
    case badImage
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notPaired: return "原子助手还没有配对，请先打开 App 扫码配对。"
        case .badImage: return "这张截屏读不出来。"
        case .failed(let why): return "没发出去：\(why)"
        }
    }
}

/// 让这个动作不用用户自己去建快捷指令就能用：出现在「快捷指令」App 的原子助手里，也能对 Siri 说。
@available(iOS 16.0, *)
struct AtomAssistantShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskAssistantIntent(),
            phrases: [
                "问\(.applicationName)",
                "用\(.applicationName)提问",
                "让\(.applicationName)帮我看看",
            ],
            shortTitle: "问助手",
            systemImageName: "bubble.left.and.text.bubble.right.fill"
        )
    }
}
