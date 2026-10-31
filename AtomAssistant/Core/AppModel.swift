import Foundation
import SwiftUI
import UIKit
import UserNotifications
import BackgroundTasks

/// 一条授权需求处理到哪一步了。
enum FulfilState: Equatable {
    case idle
    case collecting
    case uploading
    case done(Int)
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var paired = false
    @Published private(set) var serverURL = ""
    @Published private(set) var deviceName = ""
    /// 令牌被服务端拒绝（吊销了）。此时要在后台重新添加设备。
    @Published private(set) var tokenInvalid = false

    @Published private(set) var enabled: Set<String> = []
    @Published private(set) var requests: [PendingRequest] = []
    @Published private(set) var fulfil: [String: FulfilState] = [:]
    @Published private(set) var syncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncError: String?
    @Published private(set) var queueCount = 0
    @Published private(set) var lastUpload: [String: Date] = [:]
    @Published private(set) var uploadCount: [String: Int] = [:]
    /// 每种数据最近一次采集失败的原因，采集成功后清掉。
    @Published private(set) var collectErrors: [String: String] = [:]
    @Published private(set) var logs: [LogEntry] = []
    /// 处理过的授权需求（同意、拒绝、过期），最近的在前。
    @Published private(set) var authHistory: [AuthRecord] = []
    /// 上报间隔（分钟）：在后台给这台手机设置，每次同步时从服务器读取。
    @Published private(set) var syncMinutes = Defaults.syncMinutes

    /// 从二维码或链接里带来的、等待确认的配对信息。
    @Published var incomingPairing: (server: String, code: String)?

    private var queue: [QueuedItem] = []
    private var fulfilCache: [String: [QueuedItem]] = [:]
    private var knownRequestIDs: Set<String> = []
    private var loop: Task<Void, Never>?

    private let tokenAccount = "deviceToken"

    private init() {
        serverURL = Defaults.serverURL ?? ""
        deviceName = Defaults.deviceName ?? ""
        paired = !serverURL.isEmpty && Keychain.get(tokenAccount) != nil
        enabled = Defaults.enabledKinds
        lastSync = Defaults.lastSync
        lastUpload = Defaults.lastUpload.mapValues { Date(timeIntervalSince1970: $0) }
        uploadCount = Defaults.uploadCount
        queue = Persistence.load([QueuedItem].self, from: "queue.json") ?? []
        queueCount = queue.count
        logs = Persistence.load([LogEntry].self, from: "log.json") ?? []
        authHistory = Persistence.load([AuthRecord].self, from: "auth-history.json") ?? []
    }

    var client: APIClient? {
        guard paired, let url = URL(string: serverURL), let token = Keychain.get(tokenAccount) else { return nil }
        return APIClient(base: url, token: token)
    }

    // MARK: 日志

    func log(_ text: String, _ level: LogEntry.Level = .info) {
        logs.append(LogEntry(at: Date(), level: level, text: text))
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
        if let e = Persistence.save(logs, to: "log.json") { NSLog("保存日志失败: \(e)") }
    }

    func clearLogs() {
        logs = []
        Persistence.remove("log.json")
    }

    // MARK: 配对

    /// 把用户输入的服务器地址整理成 https 的根地址。
    static func normalizeServer(_ raw: String) throws -> URL {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { throw CollectError("请填写服务器地址") }
        if !s.contains("://") { s = "https://" + s }
        guard var comps = URLComponents(string: s), let host = comps.host, !host.isEmpty else {
            throw CollectError("服务器地址不对")
        }
        guard comps.scheme == "https" else { throw CollectError("服务器地址必须是 https") }
        comps.path = ""
        comps.query = nil
        comps.fragment = nil
        guard let url = comps.url else { throw CollectError("服务器地址不对") }
        _ = host
        return url
    }

    func pair(server: String, code: String) async throws {
        let base = try Self.normalizeServer(server)
        let cleaned = code.uppercased().filter { $0.isLetter || $0.isNumber }
        guard cleaned.count == 8 else { throw CollectError("配对码是 8 位字母和数字") }
        let model = SystemCollector.machine()
        let os = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        let r = try await APIClient.pair(base: base, code: cleaned, model: model, os: os)
        Keychain.set(r.token, for: tokenAccount)
        Defaults.serverURL = base.absoluteString
        Defaults.deviceName = r.name
        serverURL = base.absoluteString
        deviceName = r.name
        tokenInvalid = false
        paired = true
        log("已配对：\(r.name)（\(base.host ?? "")）")
        _ = await requestNotificationAccess()
        await syncNow()
    }

    func unpair() {
        stopLoop()
        Keychain.remove(tokenAccount)
        Defaults.clearAll()
        Persistence.removeAll()
        paired = false
        serverURL = ""
        deviceName = ""
        enabled = []
        requests = []
        queue = []
        queueCount = 0
        lastUpload = [:]
        uploadCount = [:]
        lastSync = nil
        collectErrors = [:]
        logs = []
        authHistory = []
        fulfil = [:]
        fulfilCache = [:]
        knownRequestIDs = []
        setBadge(0)
    }

    /// 处理 atomassistant://pair?server=…&code=… 这样的链接（扫二维码或点链接进来）。
    func handle(url: URL) {
        guard url.scheme == "atomassistant", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let server = items.first(where: { $0.name == "server" })?.value,
              let code = items.first(where: { $0.name == "code" })?.value else { return }
        incomingPairing = (server, code)
    }

    // MARK: 数据源开关

    /// 打开或关闭一种数据的持续上报。打开时先申请权限，申请不到就不打开，返回原因。
    func setEnabled(_ kind: DataKind, _ on: Bool) async -> String? {
        if on {
            guard let c = Collectors.all[kind] else { return "没有这种数据的采集器" }
            if let why = await c.authorize() {
                log("\(kind.title)：\(why)", .warn)
                return why
            }
            enabled.insert(kind.rawValue)
        } else {
            enabled.remove(kind.rawValue)
        }
        Defaults.enabledKinds = enabled
        if on { await syncNow(only: kind) }
        return nil
    }

    // MARK: 同步

    /// 采集已勾选的数据、上传、拉取授权需求。only 不为空时只采集这一种。
    func syncNow(only: DataKind? = nil) async {
        guard paired, !syncing else { return }
        syncing = true
        syncError = nil
        defer { syncing = false }

        let kinds = only.map { [$0] } ?? DataKind.continuous.filter { enabled.contains($0.rawValue) }
        for kind in kinds {
            guard let c = Collectors.all[kind] else { continue }
            do {
                let samples = try await c.collect(params: [:])
                try enqueue(kind: kind, samples: samples)
                collectErrors[kind.rawValue] = nil
            } catch {
                collectErrors[kind.rawValue] = error.localizedDescription
                log("\(kind.title)采集失败：\(error.localizedDescription)", .warn)
            }
        }
        await flushQueue()
        await refreshRequests()
        if syncError == nil {
            lastSync = Date()
            Defaults.lastSync = lastSync
        }
    }

    /// 手动采集并上传一次，不论有没有勾选持续上报。给「数据源」详情页用，方便看这台手机上到底能拿到什么。
    func collectOnce(_ kind: DataKind) async {
        guard paired, let c = Collectors.all[kind] else { return }
        if let why = await c.authorize() {
            collectErrors[kind.rawValue] = why
            log("\(kind.title)：\(why)", .warn)
            return
        }
        do {
            let samples = try await c.collect(params: [:])
            try enqueue(kind: kind, samples: samples)
            collectErrors[kind.rawValue] = nil
        } catch {
            collectErrors[kind.rawValue] = error.localizedDescription
            log("\(kind.title)采集失败：\(error.localizedDescription)", .warn)
        }
        await flushQueue()
    }

    /// 把采集到的数据排进上传队列，并记下每种数据最近一次的内容给「数据源」页预览。
    private func enqueue(kind: DataKind, samples: [Sample]) throws {
        for s in samples {
            let data = try JSON.data(s.payload)
            queue.removeAll { $0.kind == kind.rawValue && $0.key == s.key }
            queue.append(QueuedItem(kind: kind.rawValue, key: s.key, capturedAt: s.capturedAt, payload: data))
        }
        if let last = samples.last, let d = try? JSON.data(last.payload) {
            Persistence.saveRaw(d, to: "last-\(kind.rawValue).json")
        }
        // 队列不能无限长：离线很久时丢最旧的。
        if queue.count > 5000 { queue.removeFirst(queue.count - 5000) }
        persistQueue()
    }

    private func persistQueue() {
        queueCount = queue.count
        if let e = Persistence.save(queue, to: "queue.json") {
            log("保存上传队列失败：\(e)", .error)
        }
    }

    func lastPayload(_ kind: DataKind) -> String? {
        Persistence.loadRaw("last-\(kind.rawValue).json").map { JSON.pretty($0) }
    }

    private func flushQueue() async {
        guard let client, !queue.isEmpty else { return }
        let kinds = Array(Set(queue.map(\.kind))).sorted()
        for kind in kinds {
            while true {
                let batch = Array(queue.filter { $0.kind == kind }.prefix(100))
                if batch.isEmpty { break }
                do {
                    _ = try await client.upload(kind: kind, items: batch)
                    let ids = Set(batch.map(\.id))
                    queue.removeAll { ids.contains($0.id) }
                    persistQueue()
                    lastUpload[kind] = Date()
                    uploadCount[kind, default: 0] += batch.count
                    Defaults.lastUpload = lastUpload.mapValues { $0.timeIntervalSince1970 }
                    Defaults.uploadCount = uploadCount
                } catch APIError.unauthorized {
                    markTokenInvalid()
                    return
                } catch APIError.server(let code, let msg) where (400..<500).contains(code) {
                    // 服务端明确拒绝这一批（格式不对、种类不认识）：重传也不会好，丢掉，免得卡住后面的。
                    let ids = Set(batch.map(\.id))
                    queue.removeAll { ids.contains($0.id) }
                    persistQueue()
                    log("服务器拒绝了 \(kind) 的 \(batch.count) 条数据（\(code)：\(msg)），已丢弃", .error)
                } catch {
                    syncError = error.localizedDescription
                    log("上传 \(kind) 失败：\(error.localizedDescription)", .warn)
                    return
                }
            }
        }
    }

    private func markTokenInvalid() {
        tokenInvalid = true
        syncError = APIError.unauthorized.localizedDescription
        log("设备令牌被服务器拒绝，可能已在后台吊销", .error)
    }

    // MARK: 授权需求

    func refreshRequests() async {
        guard let client else { return }
        do {
            let (list, minutes) = try await client.pendingRequests()
            if let m = minutes, m > 0, m != syncMinutes {
                syncMinutes = m
                Defaults.syncMinutes = m
                log("上报间隔改为每 \(m) 分钟（后台设置）")
            }
            // 本机没处理、却从服务器的待办里消失的：过期了，或者在别处处理了。
            let still = Set(list.map(\.id))
            for gone in requests where !still.contains(gone.id) && fulfil[gone.id] == nil {
                recordAuth(gone, .expired)
            }
            let fresh = list.filter { !knownRequestIDs.contains($0.id) }
            knownRequestIDs = Set(list.map(\.id))
            requests = list.sorted { $0.expiresAt < $1.expiresAt }
            setBadge(list.count)
            if !fresh.isEmpty, UIApplication.shared.applicationState != .active {
                notify(fresh)
            }
        } catch APIError.unauthorized {
            markTokenInvalid()
        } catch {
            syncError = error.localizedDescription
            log("拉取授权需求失败：\(error.localizedDescription)", .warn)
        }
    }

    static func params(of r: PendingRequest) -> [String: Any] {
        var p: [String: Any] = [:]
        if let m = r.number("minutes") { p["minutes"] = m }
        if let sec = r.number("seconds") { p["seconds"] = sec }
        if let f = r.date("from") { p["from"] = f }
        if let t = r.date("to") { p["to"] = t }
        // 读取框上要显示的提示，用助手写的原因。
        p["reason"] = r.reason
        return p
    }

    /// 用户点了「同意」：申请权限、采集、交给服务器。
    func approve(_ r: PendingRequest) async {
        guard let client else { return }
        guard let kind = r.dataKind, let collector = Collectors.all[kind] else {
            fulfil[r.id] = .failed("这个版本的 App 不认识「\(r.kind)」这种数据，请更新 App")
            return
        }
        // 上次采集成功但上传失败的，直接重传，不必让用户再等一遍采集。
        if let cached = fulfilCache[r.id] {
            await upload(cached, for: r, kind: kind, client: client)
            return
        }
        fulfil[r.id] = .collecting
        if let why = await collector.authorize() {
            fulfil[r.id] = .failed(why)
            return
        }
        do {
            let samples = try await collector.collect(params: Self.params(of: r))
            let items = try samples.map {
                QueuedItem(kind: kind.rawValue, key: $0.key, capturedAt: $0.capturedAt, payload: try JSON.data($0.payload))
            }
            fulfilCache[r.id] = items
            await upload(items, for: r, kind: kind, client: client)
        } catch {
            fulfil[r.id] = .failed(error.localizedDescription)
            log("\(kind.title)采集失败：\(error.localizedDescription)", .warn)
        }
    }

    private func upload(_ items: [QueuedItem], for r: PendingRequest, kind: DataKind, client: APIClient) async {
        fulfil[r.id] = .uploading
        do {
            let n = try await client.fulfil(requestID: r.id, kind: kind.rawValue, items: items)
            fulfilCache[r.id] = nil
            fulfil[r.id] = .done(n)
            recordAuth(r, .approved, count: n)
            log("已按授权上传 \(kind.title)：\(items.count) 条")
            // 让「完成」的动画有时间被看到，再把它从待处理里拿掉。
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            requests.removeAll { $0.id == r.id }
            setBadge(requests.count)
        } catch APIError.unauthorized {
            markTokenInvalid()
            fulfil[r.id] = .failed(APIError.unauthorized.localizedDescription)
        } catch APIError.server(404, _) {
            fulfilCache[r.id] = nil
            fulfil[r.id] = .failed("这条需求已经过期或被处理过了")
            await refreshRequests()
        } catch {
            fulfil[r.id] = .failed(error.localizedDescription + "（数据已留着，点重试即可）")
        }
    }

    func decline(_ r: PendingRequest) async {
        guard let client else { return }
        do {
            try await client.decline(requestID: r.id)
            recordAuth(r, .declined)
            fulfilCache[r.id] = nil
            fulfil[r.id] = nil
            requests.removeAll { $0.id == r.id }
            setBadge(requests.count)
            log("已拒绝需求：\(r.kind)")
        } catch APIError.unauthorized {
            markTokenInvalid()
        } catch {
            fulfil[r.id] = .failed("拒绝失败：" + error.localizedDescription)
        }
    }

    func resetFulfil(_ id: String) { fulfil[id] = nil }

    private func recordAuth(_ r: PendingRequest, _ outcome: AuthRecord.Outcome, count: Int? = nil) {
        guard !authHistory.contains(where: { $0.id == r.id }) else { return }
        authHistory.insert(AuthRecord(id: r.id, kind: r.kind, reason: r.reason, at: Date(), outcome: outcome, count: count), at: 0)
        if authHistory.count > 200 { authHistory.removeLast(authHistory.count - 200) }
        if let e = Persistence.save(authHistory, to: "auth-history.json") { NSLog("保存授权记录失败: \(e)") }
    }

    // MARK: 探测报告

    func uploadProbe(_ report: [String: Any]) async -> String? {
        guard let client else { return "还没有配对" }
        do {
            let item = QueuedItem(kind: DataKind.probeReport.rawValue, key: "probe-\(Int(Date().timeIntervalSince1970))",
                                  capturedAt: Date(), payload: try JSON.data(report))
            _ = try await client.upload(kind: item.kind, items: [item])
            log("已上传能力探测报告")
            return nil
        } catch APIError.unauthorized {
            markTokenInvalid()
            return APIError.unauthorized.localizedDescription
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: 通知与角标

    func requestNotificationAccess() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    private func notify(_ fresh: [PendingRequest]) {
        let content = UNMutableNotificationContent()
        let first = fresh[0]
        content.title = fresh.count == 1 ? "助手想要你的「\(first.dataKind?.title ?? first.kind)」" : "助手有 \(fresh.count) 条新的授权需求"
        content.body = fresh.count == 1 ? first.reason : "打开原子助手，看看并决定是否同意。"
        content.sound = .default
        let req = UNNotificationRequest(identifier: "req-" + first.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { [weak self] error in
            if let error { Task { @MainActor in self?.log("发本地通知失败：\(error.localizedDescription)", .warn) } }
        }
    }

    private func setBadge(_ n: Int) {
        UNUserNotificationCenter.current().setBadgeCount(n) { _ in }
    }

    // MARK: 前台循环与后台刷新

    /// 按后台设置的间隔同步。只在 App 在前台时跑；切到后台后靠系统的「后台 App 刷新」唤醒。
    func startLoop() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                // 间隔由后台设置，每一轮都读最新的。
                let minutes = self?.syncMinutes ?? 20
                try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            }
        }
    }

    func stopLoop() {
        loop?.cancel()
        loop = nil
    }
}

enum BackgroundSync {
    static let identifier = "io.github.xiguac.ios.atomassistant.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            schedule()
            let work = Task { @MainActor in
                await AppModel.shared.syncNow()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = {
                work.cancel()
                task.setTaskCompleted(success: false)
            }
        }
    }

    /// 请系统在间隔之后的合适时机唤醒一次。系统不保证准时，也不保证一定会来。
    static func schedule() {
        let req = BGAppRefreshTaskRequest(identifier: identifier)
        // 系统本来也不会比 15 分钟更勤；后台设了更长的间隔就按它来。
        req.earliestBeginDate = Date(timeIntervalSinceNow: Double(max(15, Defaults.syncMinutes)) * 60)
        do {
            try BGTaskScheduler.shared.submit(req)
        } catch {
            NSLog("预约后台刷新失败: \(error.localizedDescription)")
        }
    }
}
