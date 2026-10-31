import SwiftUI

/// 数据种类。编号必须与服务端 internal/device/kinds.go 里的一致。
enum DataKind: String, CaseIterable, Identifiable, Codable {
    case deviceStatus = "device.status"
    case deviceSystem = "device.system"
    case deviceNetwork = "device.network"
    case motionPedometer = "motion.pedometer"
    case motionActivity = "motion.activity"
    case healthSummary = "health.summary"
    case mediaNowPlaying = "media.nowplaying"
    case mediaLibrary = "media.library"
    case focusStatus = "focus.status"
    case probeReport = "probe.report"
    case locationNow = "location.now"
    case locationTrack = "location.track"
    case healthQuery = "health.query"
    case motionQuery = "motion.query"

    var id: String { rawValue }

    /// 为真表示每次采集都要用户点同意，只能挂在授权需求上上报。
    var perUse: Bool {
        switch self {
        case .locationNow, .locationTrack, .healthQuery, .motionQuery: return true
        default: return false
        }
    }

    /// 可以持续上报、在「数据源」里勾选的种类（能力探测报告由探测页单独上传）。
    static var continuous: [DataKind] { allCases.filter { !$0.perUse && $0 != .probeReport } }

    var title: String {
        switch self {
        case .deviceStatus: return "设备状态"
        case .deviceSystem: return "系统信息"
        case .deviceNetwork: return "网络状态"
        case .motionPedometer: return "计步"
        case .motionActivity: return "运动状态"
        case .healthSummary: return "健康摘要"
        case .mediaNowPlaying: return "正在播放"
        case .mediaLibrary: return "音乐库"
        case .focusStatus: return "专注模式"
        case .probeReport: return "能力探测"
        case .locationNow: return "当前位置"
        case .locationTrack: return "位置轨迹"
        case .healthQuery: return "健康记录"
        case .motionQuery: return "运动历史"
        }
    }

    var detail: String {
        switch self {
        case .deviceStatus: return "电量、充电、存储、亮度、音频输出"
        case .deviceSystem: return "型号、系统版本、开机时长、内存"
        case .deviceNetwork: return "Wi-Fi、蜂窝、是否计费"
        case .motionPedometer: return "今日步数、距离、爬楼"
        case .motionActivity: return "静止、步行、跑步、骑行、驾车"
        case .healthSummary: return "步数、心率、睡眠、活动能量等"
        case .mediaNowPlaying: return "歌名、歌手、来源应用"
        case .mediaLibrary: return "歌曲数量与最近播放"
        case .focusStatus: return "专注模式是否开启"
        case .probeReport: return "哪些系统接口在这台手机上可用"
        case .locationNow: return "此刻的位置"
        case .locationTrack: return "一段时间内的移动轨迹"
        case .healthQuery: return "指定时间段的详细健康记录"
        case .motionQuery: return "指定时间段的计步与运动历史"
        }
    }

    var symbol: String {
        switch self {
        case .deviceStatus: return "battery.75"
        case .deviceSystem: return "iphone"
        case .deviceNetwork: return "wifi"
        case .motionPedometer: return "figure.walk"
        case .motionActivity: return "figure.run"
        case .healthSummary: return "heart.fill"
        case .mediaNowPlaying: return "music.note"
        case .mediaLibrary: return "music.note.list"
        case .focusStatus: return "moon.fill"
        case .probeReport: return "stethoscope"
        case .locationNow: return "location.fill"
        case .locationTrack: return "point.topleft.down.curvedto.point.bottomright.up"
        case .healthQuery: return "waveform.path.ecg"
        case .motionQuery: return "chart.line.uptrend.xyaxis"
        }
    }

    var tint: Color {
        switch self {
        case .deviceStatus: return .green
        case .deviceSystem: return .gray
        case .deviceNetwork: return .blue
        case .motionPedometer, .motionActivity, .motionQuery: return .orange
        case .healthSummary, .healthQuery: return .pink
        case .mediaNowPlaying, .mediaLibrary: return .red
        case .focusStatus: return .purple
        case .probeReport: return .teal
        case .locationNow, .locationTrack: return .blue
        }
    }
}

/// 助手向这台手机提出的一条授权需求。
struct PendingRequest: Codable, Identifiable, Equatable {
    let id: String
    let kind: String
    let reason: String
    let params: [String: JSONValue]?
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id, kind, reason, params
        case expiresAt = "expires_at"
    }

    var dataKind: DataKind? { DataKind(rawValue: kind) }

    /// 参数里的数字，如 minutes。
    func number(_ key: String) -> Double? { params?[key]?.number }

    /// 参数里的时间，如 from、to（RFC3339）。
    func date(_ key: String) -> Date? {
        guard let s = params?[key]?.string else { return nil }
        return JSON.parseDate(s)
    }

    /// 把参数写成人看得懂的一句话。
    var paramsSummary: String? {
        guard let params, !params.isEmpty else { return nil }
        var parts: [String] = []
        if let m = number("minutes") { parts.append("持续 \(Int(m)) 分钟") }
        if let f = params["from"]?.string, let t = params["to"]?.string {
            parts.append("\(f.prefix(10)) 至 \(t.prefix(10))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "，")
    }
}

/// 任意 JSON 值，只用来原样读取需求里的参数。
enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var number: Double? { if case .number(let n) = self { return n }; return nil }
}

/// 采集到的一条数据。payload 是任意 JSON 兼容的字典，发送前会被清洗。
struct Sample {
    var key: String
    var capturedAt: Date
    var payload: [String: Any]
}

/// 排队等待上传的一条数据，落在磁盘上，断网、被杀掉都不丢。
struct QueuedItem: Codable, Identifiable {
    var id: String { kind + "|" + key }
    let kind: String
    let key: String
    let capturedAt: Date
    /// 已序列化的 JSON。
    let payload: Data
}

struct LogEntry: Codable, Identifiable {
    var id = UUID()
    let at: Date
    let level: Level
    let text: String
    enum Level: String, Codable { case info, warn, error }
}

/// 把采集到的字典洗成 JSONSerialization 一定吃得下的样子：
/// NaN/无穷会让它直接抛 ObjC 异常（Swift 接不住），日期、二进制、其他类型要先转成文字。
enum JSON {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain = ISO8601DateFormatter()

    /// 解析 RFC3339 时间。服务端（Go）的小数秒最长 9 位，系统的解析器不一定都认，认不了就去掉小数秒再试。
    static func parseDate(_ s: String) -> Date? {
        if let d = iso.date(from: s) ?? plain.date(from: s) { return d }
        guard let dot = s.firstIndex(of: "."),
              let end = s[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) else { return nil }
        return plain.date(from: String(s[..<dot]) + String(s[end...]))
    }

    static func clean(_ v: Any?) -> Any {
        guard let v else { return NSNull() }
        switch v {
        case is NSNull: return NSNull()
        case let v as NSNumber:
            // 数字和布尔都会桥接成 NSNumber；要先认出布尔，否则 0/1 会被当成 false/true 或反过来。
            if CFGetTypeID(v) == CFBooleanGetTypeID() { return v.boolValue }
            return v.doubleValue.isFinite ? v : NSNull()
        case let v as String: return v
        case let v as Date: return iso.string(from: v)
        case let v as Data: return v.base64EncodedString()
        case let v as URL: return v.absoluteString
        case let v as [Any?]: return v.map { clean($0) }
        case let v as [String: Any?]: return v.mapValues { clean($0) }
        default: return String(describing: v)
        }
    }

    static func data(_ dict: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: clean(dict), options: [.sortedKeys])
    }

    static func pretty(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: out, encoding: .utf8) else { return String(data: data, encoding: .utf8) ?? "" }
        return s
    }
}
