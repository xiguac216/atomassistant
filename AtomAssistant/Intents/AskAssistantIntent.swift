import AppIntents

/// 「问原子助手」：对 Siri 说一声，再说出想问的话，答复通过后台设置的消息源（默认 QQ）发回给你。
///
/// 它在 App 自己的进程里后台运行，不会把 App 拉到前台。
/// Siri 的限制：触发短语里不能直接带一句自由文本（苹果只允许短语里带固定选项），
/// 所以流程是两步：先说「问原子助手」，Siri 再问「想问原子助手什么？」，你接着说。
@available(iOS 16.0, *)
struct AskAssistantIntent: AppIntent {
    static var title: LocalizedStringResource = "问原子助手"
    static var description = IntentDescription(
        "把你说的话交给原子助手，它想好之后通过 QQ 回复你。",
        categoryName: "原子助手"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "想问什么", requestValueDialog: "想问原子助手什么？")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("问原子助手 \(\.$question)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let server = Defaults.serverURL, let base = URL(string: server), let token = Keychain.get("deviceToken") else {
            throw AskError.notPaired
        }
        do {
            try await APIClient(base: base, token: token).ask(text: question, screenshot: nil, mime: "image/jpeg")
        } catch let e as APIError {
            throw AskError.failed(e.localizedDescription)
        }
        return .result(dialog: "已发给原子助手，想好后会通过 QQ 回复你。")
    }
}

enum AskError: Error, CustomLocalizedStringResourceConvertible {
    case notPaired
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notPaired: return "原子助手还没有配对，请先打开 App 扫码配对。"
        case .failed(let why): return "没发出去：\(why)"
        }
    }
}

/// 装上 App 就能对 Siri 说，不用自己去建快捷指令。
@available(iOS 16.0, *)
struct AtomAssistantShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskAssistantIntent(),
            phrases: [
                "问\(.applicationName)",
                "用\(.applicationName)提问",
                "让\(.applicationName)帮我看看",
                "Ask \(.applicationName)",
            ],
            shortTitle: "问助手",
            systemImageName: "bubble.left.and.text.bubble.right.fill"
        )
    }
}
