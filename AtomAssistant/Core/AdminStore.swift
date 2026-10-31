import Foundation
import LocalAuthentication

// MARK: - 数据

struct AdminTask: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let state: String
    let reason: String?
    let needsUser: Bool
    let live: Bool
    let createdAt: Date
    let updatedAt: Date
    let tokens: Int
    let costYuan: Double

    /// 状态的中文名和类别，界面上用颜色区分。
    var stateText: String {
        switch state {
        case "new", "ready": return "排队中"
        case "running": return "进行中"
        case "waiting": return needsUser ? "等你处理" : "等待中"
        case "suspended": return "已挂起"
        case "done": return "已完成"
        case "failed": return "失败"
        case "cancelled": return "已取消"
        default: return state
        }
    }
}

struct AdminOverview: Decodable {
    let assistantOk: Bool
    let assistantProblem: String?
    let waiting: Int
    let active: Int
    let recent: [AdminTask]
    let vaultRequests: Int?
    let memoryPending: Int?
    let todayTokens: Int?
    let todayCostYuan: Double?
}

struct AdminTaskList: Decodable {
    let tasks: [AdminTask]
    let total: Int
    let page: Int
    let pages: Int
}

struct AdminStep: Decodable, Identifiable {
    var id: Int { seq }
    let seq: Int
    let type: String
    let tool: String?
    let status: String
    let sideEffect: String?
    let input: String?
    let output: String?
    let error: String?
}

struct AdminField: Decodable, Identifiable {
    var id: String { key }
    let key: String
    let value: String
}

struct AdminApproval: Decodable {
    let tool: String
    let fields: [AdminField]?
    let irreversible: Bool
    let why: String?
    let rule: String?
}

struct AdminOverBudget: Decodable {
    let suggestTokens: Int
    let suggestYuan: Double
    let suggestHours: Double
    let usageYuan: Double
}

struct AdminTaskDetail: Decodable {
    let task: AdminTask
    let goal: String
    let steps: [AdminStep]
    let approval: AdminApproval?
    let question: String?
    let overBudget: AdminOverBudget?
}

// MARK: - Face ID

enum Biometric {
    /// 这台手机用的生物识别叫什么。
    static var name: String {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else { return "设备密码" }
        switch ctx.biometryType {
        case .faceID: return "面容 ID"
        case .touchID: return "触控 ID"
        default: return "设备密码"
        }
    }

    /// 弹出系统的验证。生物识别不可用或失败时，系统会退回到设备密码。
    static func authenticate(reason: String) async -> Result<Void, Error> {
        let ctx = LAContext()
        ctx.localizedCancelTitle = "取消"
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return ok ? .success(()) : .failure(AdminError("验证没有通过"))
        } catch {
            return .failure(error)
        }
    }
}

struct AdminError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

// MARK: - 状态

/// 手机管理端的状态：Face ID 把门，之后所有请求用配对时拿到的设备令牌，服务端还要确认这台手机被打开了管理权限。
@MainActor
final class AdminStore: ObservableObject {
    static let shared = AdminStore()

    enum Filter: String, CaseIterable, Identifiable {
        case all, active, ended
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .active: return "进行中"
            case .ended: return "已结束"
            }
        }
    }

    @Published private(set) var unlocked = false
    @Published private(set) var overview: AdminOverview?
    @Published private(set) var tasks: [AdminTask] = []
    @Published var filter: Filter = .all
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    /// 服务端说这台手机没有管理权限。
    @Published private(set) var forbidden = false

    private var lockedAt: Date?

    // MARK: 锁

    /// 弹 Face ID。成功后解锁。
    func unlock() async -> String? {
        switch await Biometric.authenticate(reason: "解锁原子助手的管理功能") {
        case .success:
            unlocked = true
            lockedAt = nil
            return nil
        case .failure(let e):
            return e.localizedDescription
        }
    }

    func lock() { unlocked = false }

    /// App 切到后台时记一下时间；回来时离开超过一分钟就重新锁上。
    func noteBackground() { lockedAt = Date() }

    func noteForeground() {
        if let t = lockedAt, Date().timeIntervalSince(t) > 60 { unlocked = false }
        lockedAt = nil
    }

    // MARK: 请求

    private func send(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard let client = AppModel.shared.client else { throw AdminError("还没有配对") }
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        do {
            let out = try await client.appRequest(method, path, body: data)
            forbidden = false
            return out
        } catch APIError.server(403, let msg) {
            forbidden = true
            throw AdminError(msg)
        }
    }

    private func call<T: Decodable>(_ type: T.Type, _ method: String, _ path: String, body: [String: Any]? = nil) async throws -> T {
        try Self.decoder.decode(T.self, from: try await send(method, path, body: body))
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = JSON.parseDate(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "日期格式不对：\(s)"))
        }
        return d
    }()

    // MARK: 列表

    func reload() async {
        guard unlocked else { return }
        loading = true
        defer { loading = false }
        do {
            overview = try await call(AdminOverview.self, "GET", "overview")
            let tab = filter == .all ? "all" : filter.rawValue
            tasks = try await call(AdminTaskList.self, "GET", "tasks?tab=\(tab)").tasks
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func detail(_ id: String) async throws -> AdminTaskDetail {
        try await call(AdminTaskDetail.self, "GET", "tasks/\(id)")
    }

    // MARK: 操作

    func create(goal: String) async throws -> String {
        struct R: Decodable { let id: String }
        return try await call(R.self, "POST", "tasks", body: ["goal": goal]).id
    }

    func approve(_ id: String) async throws { _ = try await send("POST", "tasks/\(id)/approve") }

    func reject(_ id: String, reason: String) async throws {
        _ = try await send("POST", "tasks/\(id)/reject", body: ["reason": reason])
    }

    func cancel(_ id: String) async throws { _ = try await send("POST", "tasks/\(id)/cancel") }

    func reply(_ id: String, text: String) async throws {
        _ = try await send("POST", "tasks/\(id)/reply", body: ["text": text])
    }

    func raiseBudget(_ id: String, _ b: AdminOverBudget) async throws {
        _ = try await send("POST", "tasks/\(id)/budget",
                           body: ["max_tokens": b.suggestTokens, "max_cost_yuan": b.suggestYuan, "max_hours": b.suggestHours])
    }
}
