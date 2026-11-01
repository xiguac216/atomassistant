import SwiftUI
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins

/// 通用页面：按服务器给的界面描述（分区、行、按钮、表单）画原生的列表。
/// 后台的记忆、环境变量、模型、消息源、数据源、MCP、Skill、系统提示词、文件、日志、登录与安全、手机，都是它画出来的。
struct PageView: View {
    @EnvironmentObject var store: AdminStore
    @EnvironmentObject var nav: PageNav
    let path: String
    var fallbackTitle = ""

    /// 合并入口里当前选中的那一段；没有分段时就是 path 本身。
    @State private var current: String?
    @State private var tabs: [UITab] = []
    @State private var page: UIPage?
    @State private var loadError: String?
    @State private var banner: Banner?
    @State private var activeForm: UIForm?
    @State private var pending: PendingAction?
    @State private var busy = false
    @State private var importing = false
    @State private var shareItem: ShareItem?

    struct Banner: Equatable { let text: String; let ok: Bool }
    struct PendingAction: Identifiable { let id = UUID(); let action: UIAction }
    struct ShareItem: Identifiable { let id = UUID(); let url: URL }

    var body: some View {
        List {
            if tabs.count > 1 {
                Section {
                    Picker("分类", selection: Binding(get: { current ?? path }, set: { select($0) })) {
                        ForEach(tabs) { Text($0.title).tag($0.path) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            if let banner {
                Section {
                    Label(banner.text, systemImage: banner.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(banner.ok ? Color.green : Color.red)
                }
                .transition(.opacity)
            }
            if let loadError, page == nil {
                Section { Label(loadError, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange) }
            }
            if let page {
                if let n = page.notice, !n.isEmpty, banner == nil {
                    Section { Label(n, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green) }
                }
                if let e = page.error, !e.isEmpty, banner == nil {
                    Section { Label(e, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red) }
                }
                ForEach(page.sections) { sec in
                    Section {
                        ForEach(sec.items) { it in ItemRow(item: it, activate: activate, request: request) }
                    } header: {
                        if let t = sec.title { Text(t) }
                    } footer: {
                        if let f = sec.footer { Text(f) }
                    }
                }
            } else if loadError == nil {
                Section { HStack { ProgressView(); Text("正在加载…").foregroundStyle(.secondary) } }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(tabs.first(where: { $0.path == (current ?? path) })?.title ?? page?.title ?? fallbackTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                ForEach(page?.toolbar ?? []) { it in
                    if it.kind == "upload" {
                        Button { importing = true } label: { Image(systemName: it.icon ?? "arrow.up.doc") }
                    } else {
                        Button { activate(it) } label: { Image(systemName: it.icon ?? "plus") }
                    }
                }
            }
        }
        .refreshable { await load() }
        .task(id: current ?? path) { await load() }
        .animation(.easeInOut(duration: 0.2), value: banner)
        .sheet(item: $activeForm) { f in
            FormSheet(form: f) { extra in await submit(f.submit, extra: extra) }
        }
        .sheet(item: $shareItem) { ShareSheet(url: $0.url) }
        .confirmationDialog(pending?.action.confirm ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let p = pending {
                Button(p.action.label, role: p.action.destructive ? .destructive : nil) {
                    let a = p.action
                    pending = nil
                    Task { _ = await submit(a, extra: [:]) }
                }
            }
            Button("取消", role: .cancel) { pending = nil }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            Task { await upload(result) }
        }
    }

    // MARK: 加载

    private func load() async {
        do {
            let p = try await store.loadPage(current ?? path)
            if !p.tabs.isEmpty { tabs = p.tabs }
            page = p
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// 切换分段：换一页内容，标题和列表一起过渡。
    private func select(_ to: String) {
        guard to != (current ?? path) else { return }
        Haptics.tap()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            current = to
            page = nil
            banner = nil
        }
    }

    // MARK: 点击

    private func activate(_ it: UIItem) {
        if let f = it.form { activeForm = f; Haptics.tap(); return }
        if let a = it.action { request(a); return }
        if it.kind == "download", let raw = it.raw { Task { await download(raw, name: it.title ?? "文件") }; return }
        if let p = it.page { nav.push(p) }
    }

    /// 要执行一个动作：有确认语的先确认，没有的直接做。
    private func request(_ a: UIAction) {
        Haptics.tap()
        if a.get {
            nav.push(a.path + (a.form.isEmpty ? "" : "?" + query(a.form)))
            return
        }
        if let c = a.confirm, !c.isEmpty {
            pending = PendingAction(action: a)
        } else {
            Task { _ = await submit(a, extra: [:]) }
        }
    }

    private func query(_ f: [String: [String]]) -> String {
        f.flatMap { k, vs in vs.filter { !$0.isEmpty }.map { "\(k)=\($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0)" } }.joined(separator: "&")
    }

    /// 提交一个动作。返回错误文字（成功返回 nil），表单用它在表单里显示错误。
    @discardableResult
    private func submit(_ a: UIAction, extra: [String: [String]]) async -> String? {
        if a.get {
            nav.push(a.path + "?" + query(a.form.merging(extra) { $0 + $1 }))
            return nil
        }
        if a.sensitive {
            if case .failure(let e) = await Biometric.authenticate(reason: "确认：\(a.label)") {
                let msg = e.localizedDescription
                show(msg, ok: false)
                return msg
            }
        }
        busy = true
        defer { busy = false }
        do {
            let r = try await store.perform(a, extra: extra)
            if !r.ok {
                let msg = r.message ?? "操作失败"
                show(msg, ok: false)
                Haptics.error()
                return msg
            }
            Haptics.success()
            if let to = r.redirect, let u = URL(string: to), u.path.hasPrefix("/") {
                nav.push(to)
            } else if let p = r.page {
                page = p
            } else {
                await load()
            }
            if let m = r.message, !m.isEmpty { show(m, ok: true) }
            return nil
        } catch {
            let msg = error.localizedDescription
            show(msg, ok: false)
            Haptics.error()
            return msg
        }
    }

    private func show(_ text: String, ok: Bool) {
        banner = Banner(text: text, ok: ok)
        Task {
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            if banner?.text == text { banner = nil }
        }
    }

    // MARK: 文件

    private func upload(_ result: Result<URL, Error>) async {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let r = try await store.upload(data: data, filename: url.lastPathComponent, mime: mime)
            show(r.message ?? (r.ok ? "已上传" : "上传失败"), ok: r.ok)
            await load()
        } catch {
            show(error.localizedDescription, ok: false)
        }
    }

    private func download(_ raw: String, name: String) async {
        do {
            let data = try await store.download(raw)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(name)
            try data.write(to: file)
            shareItem = ShareItem(url: file)
        } catch {
            show(error.localizedDescription, ok: false)
        }
    }
}

// MARK: - 一行

private func toneColor(_ t: String?) -> Color {
    switch t {
    case "ok": return .green
    case "warn": return .orange
    case "bad": return .red
    case "info": return .blue
    default: return .secondary
    }
}

private struct ItemRow: View {
    let item: UIItem
    let activate: (UIItem) -> Void
    let request: (UIAction) -> Void

    var body: some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                ForEach(item.menu) { a in
                    Button(role: a.destructive ? .destructive : nil) { request(a) } label: { Text(a.label) }
                        .tint(a.destructive ? .red : .accentColor)
                }
            }
            .contextMenu {
                ForEach(item.menu) { a in
                    Button(role: a.destructive ? .destructive : nil) { request(a) } label: { Text(a.label) }
                }
            }
    }

    private var tappable: Bool { item.form != nil || item.action != nil || item.page != nil || item.kind == "download" }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case "text":
            Text(item.text ?? "").font(.system(size: 15)).textSelection(.enabled)
        case "mono":
            VStack(alignment: .leading, spacing: 4) {
                if let t = item.title { Text(t).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Text(item.text ?? "").font(.system(size: 15, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button { UIPasteboard.general.string = item.text; Haptics.tap() } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                }
            }
        case "qr":
            QRView(text: item.text ?? "")
        case "button":
            Button { activate(item) } label: {
                Label(item.title ?? "", systemImage: item.icon ?? "chevron.right")
                    .foregroundStyle(item.action?.destructive == true ? Color.red : Color.accentColor)
            }
        default:
            if let p = item.page, item.form == nil, item.action == nil, item.kind != "download" {
                NavigationLink(value: PageRoute(path: p)) { rowBody }
            } else if tappable {
                Button { activate(item) } label: { rowBody }.buttonStyle(.plain)
            } else {
                rowBody
            }
        }
    }

    private var rowBody: some View {
        HStack(spacing: 12) {
            if let icon = item.icon { IconTile(symbol: icon, tint: .accentColor, size: 30) }
            VStack(alignment: .leading, spacing: 3) {
                if let t = item.title { Text(t).font(.system(size: 16)).lineLimit(3) }
                if let s = item.subtitle, !s.isEmpty { Text(s).font(.footnote).foregroundStyle(.secondary).lineLimit(3) }
            }
            Spacer(minLength: 8)
            if let v = item.value, !v.isEmpty {
                Text(v).font(.footnote).foregroundStyle(toneColor(item.tone)).multilineTextAlignment(.trailing).lineLimit(2)
            }
            if let b = item.badge, !b.isEmpty {
                Text(b).font(.system(size: 12, weight: .semibold)).foregroundStyle(toneColor(item.tone))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(toneColor(item.tone).opacity(0.14), in: Capsule())
            }
            if item.page != nil && item.form == nil && item.action == nil { EmptyView() }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 二维码

struct QRView: View {
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            if let img = Self.image(text) {
                Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                    .frame(maxWidth: 240).padding(8).background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity)
            }
            Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    static func image(_ text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - 分享面板

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - 表单

struct FormSheet: View {
    let form: UIForm
    /// 提交：传入表单里填的内容，返回错误文字（成功返回 nil）。
    let onSubmit: ([String: [String]]) async -> String?
    @Environment(\.dismiss) private var dismiss

    @State private var texts: [Int: String] = [:]
    @State private var picks: [Int: Set<String>] = [:]
    @State private var toggles: [Int: Bool] = [:]
    @State private var dates: [Int: Date] = [:]
    @State private var dateOn: Set<Int> = []
    @State private var error: String?
    @State private var sending = false

    var body: some View {
        NavigationStack {
            Form {
                if let intro = form.intro, !intro.isEmpty {
                    Section { Text(intro).font(.footnote).foregroundStyle(.secondary) }
                }
                ForEach(Array(form.fields.enumerated()), id: \.offset) { i, f in
                    Section {
                        field(i, f)
                    } header: {
                        Text(f.label + (f.required ? " *" : ""))
                    } footer: {
                        if let t = f.footer { Text(t) }
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle(form.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if sending { ProgressView() } else { Button(form.submit.label) { Task { await send() } } }
                }
            }
            .onAppear(perform: seed)
        }
        .presentationDetents([.large])
    }

    @ViewBuilder private func field(_ i: Int, _ f: UIField) -> some View {
        switch f.type {
        case "secure":
            SecureField(f.placeholder ?? "", text: text(i)).textInputAutocapitalization(.never).autocorrectionDisabled()
        case "multiline":
            TextField(f.placeholder ?? "", text: text(i), axis: .vertical).lineLimit(3...12)
        case "number":
            TextField(f.placeholder ?? "", text: text(i)).keyboardType(.decimalPad)
        case "url":
            TextField(f.placeholder ?? "", text: text(i)).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        case "toggle":
            Toggle(f.label, isOn: Binding(get: { toggles[i] ?? false }, set: { toggles[i] = $0 }))
        case "select":
            Picker(f.label, selection: text(i)) {
                ForEach(f.options) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.menu)
        case "multiselect":
            if f.options.isEmpty { Text("没有可选项").foregroundStyle(.secondary) }
            ForEach(f.options) { o in
                Button {
                    var s = picks[i] ?? []
                    if s.contains(o.value) { s.remove(o.value) } else { s.insert(o.value) }
                    picks[i] = s
                } label: {
                    HStack {
                        Text(o.label).foregroundStyle(.primary)
                        Spacer()
                        if picks[i]?.contains(o.value) == true { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }
                }
            }
        case "date":
            Toggle("设置日期", isOn: Binding(get: { dateOn.contains(i) }, set: { if $0 { dateOn.insert(i) } else { dateOn.remove(i) } }))
            if dateOn.contains(i) {
                DatePicker("", selection: Binding(get: { dates[i] ?? Date() }, set: { dates[i] = $0 }), displayedComponents: .date)
                    .datePickerStyle(.compact).labelsHidden()
            }
        default:
            TextField(f.placeholder ?? "", text: text(i)).textInputAutocapitalization(.never).autocorrectionDisabled()
        }
    }

    private func text(_ i: Int) -> Binding<String> {
        Binding(get: { texts[i] ?? "" }, set: { texts[i] = $0 })
    }

    /// 填上服务器给的初始值。
    private func seed() {
        for (i, f) in form.fields.enumerated() {
            switch f.type {
            case "multiselect": picks[i] = Set(f.values)
            case "toggle": toggles[i] = (f.value ?? "") == "1"
            case "select": texts[i] = f.value ?? f.options.first?.value ?? ""
            default: texts[i] = f.value ?? ""
            }
        }
    }

    private func send() async {
        var out: [String: [String]] = [:]
        for (i, f) in form.fields.enumerated() {
            switch f.type {
            case "multiselect":
                for o in f.options where picks[i]?.contains(o.value) == true { out[f.key, default: []].append(o.value) }
            case "toggle":
                if toggles[i] == true { out[f.key, default: []].append("1") }
            case "date":
                if dateOn.contains(i) {
                    let fmt = DateFormatter()
                    fmt.dateFormat = "yyyy-MM-dd"
                    fmt.locale = Locale(identifier: "en_US_POSIX")
                    out[f.key, default: []].append(fmt.string(from: dates[i] ?? Date()))
                }
            default:
                let v = (texts[i] ?? "").trimmingCharacters(in: f.type == "secure" ? [] : .whitespacesAndNewlines)
                if f.required && v.isEmpty && f.type != "toggle" {
                    error = "请填写「\(f.label)」"
                    Haptics.error()
                    return
                }
                out[f.key, default: []].append(v)
            }
        }
        sending = true
        defer { sending = false }
        if let e = await onSubmit(out) {
            error = e
        } else {
            dismiss()
        }
    }
}
