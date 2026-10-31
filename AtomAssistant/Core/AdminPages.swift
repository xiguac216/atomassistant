import Foundation

// 服务器描述的手机界面（见服务端 internal/admin/appui.go）。
// 所有数组都按「可能缺」来解码：服务器上空的列表有时是 null，缺字段不该让整页读不出来。

struct UIPage: Decodable {
    let title: String
    let notice: String?
    let error: String?
    let toolbar: [UIItem]
    let sections: [UISection]

    enum CodingKeys: String, CodingKey { case title, notice, error, toolbar, sections }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        notice = try c.decodeIfPresent(String.self, forKey: .notice)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        toolbar = try c.decodeIfPresent([UIItem].self, forKey: .toolbar) ?? []
        sections = try c.decodeIfPresent([UISection].self, forKey: .sections) ?? []
    }
}

struct UISection: Decodable, Identifiable {
    let id = UUID()
    let title: String?
    let footer: String?
    let items: [UIItem]

    enum CodingKeys: String, CodingKey { case title, footer, items }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        footer = try c.decodeIfPresent(String.self, forKey: .footer)
        items = try c.decodeIfPresent([UIItem].self, forKey: .items) ?? []
    }
}

struct UIItem: Decodable, Identifiable {
    let id = UUID()
    let kind: String
    let title: String?
    let subtitle: String?
    let value: String?
    let badge: String?
    let tone: String?
    let icon: String?
    let text: String?
    let page: String?
    let form: UIForm?
    let action: UIAction?
    let raw: String?
    let menu: [UIAction]

    enum CodingKeys: String, CodingKey {
        case kind, title, subtitle, value, badge, tone, icon, text, page, form, action, raw, menu
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "row"
        title = try c.decodeIfPresent(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        badge = try c.decodeIfPresent(String.self, forKey: .badge)
        tone = try c.decodeIfPresent(String.self, forKey: .tone)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        page = try c.decodeIfPresent(String.self, forKey: .page)
        form = try c.decodeIfPresent(UIForm.self, forKey: .form)
        action = try c.decodeIfPresent(UIAction.self, forKey: .action)
        raw = try c.decodeIfPresent(String.self, forKey: .raw)
        menu = try c.decodeIfPresent([UIAction].self, forKey: .menu) ?? []
    }
}

struct UIAction: Decodable, Identifiable {
    let id = UUID()
    let label: String
    let path: String
    let form: [String: [String]]
    let confirm: String?
    let destructive: Bool
    let sensitive: Bool
    /// 不是写操作：把表单拼成查询参数，打开 path 这个页面。
    let get: Bool

    enum CodingKeys: String, CodingKey { case label, path, form, confirm, destructive, sensitive, get }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        form = try c.decodeIfPresent([String: [String]].self, forKey: .form) ?? [:]
        confirm = try c.decodeIfPresent(String.self, forKey: .confirm)
        destructive = try c.decodeIfPresent(Bool.self, forKey: .destructive) ?? false
        sensitive = try c.decodeIfPresent(Bool.self, forKey: .sensitive) ?? false
        get = try c.decodeIfPresent(Bool.self, forKey: .get) ?? false
    }
}

struct UIForm: Decodable, Identifiable {
    let id = UUID()
    let title: String
    let intro: String?
    let fields: [UIField]
    let submit: UIAction

    enum CodingKeys: String, CodingKey { case title, intro, fields, submit }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        intro = try c.decodeIfPresent(String.self, forKey: .intro)
        fields = try c.decodeIfPresent([UIField].self, forKey: .fields) ?? []
        submit = try c.decode(UIAction.self, forKey: .submit)
    }
}

struct UIField: Decodable, Identifiable {
    let id = UUID()
    let key: String
    let label: String
    let type: String
    let placeholder: String?
    let value: String?
    let values: [String]
    let options: [UIOption]
    let footer: String?
    let required: Bool

    enum CodingKeys: String, CodingKey { case key, label, type, placeholder, value, values, options, footer, required }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "text"
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        values = try c.decodeIfPresent([String].self, forKey: .values) ?? []
        options = try c.decodeIfPresent([UIOption].self, forKey: .options) ?? []
        footer = try c.decodeIfPresent(String.self, forKey: .footer)
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
    }
}

struct UIOption: Decodable, Identifiable {
    var id: String { value }
    let value: String
    let label: String
}

/// 一次写操作的结果。
struct ActionResult: Decodable {
    let ok: Bool
    let message: String?
    /// 处理函数选择了跳转（比如微信开始扫码后要去二维码那一页）。
    let redirect: String?
    let page: UIPage?

    enum CodingKeys: String, CodingKey { case ok, message, redirect, page }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        message = try c.decodeIfPresent(String.self, forKey: .message)
        redirect = try c.decodeIfPresent(String.self, forKey: .redirect)
        page = try c.decodeIfPresent(UIPage.self, forKey: .page)
    }
}

/// 导航栈里的一个页面。
struct PageRoute: Hashable {
    let path: String
}

/// 管理页面的导航栈，由「管理」页持有，页面里的按钮可以往里推新的页面。
@MainActor
final class PageNav: ObservableObject {
    @Published var path: [PageRoute] = []
    func push(_ p: String) { path.append(PageRoute(path: p)) }
}
