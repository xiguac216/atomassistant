import Foundation

/// 一行读数：左边是名字，右边是值。「实测」页用它把采集到的数据用中文逐项显示，方便核对准不准。
struct ReadingRow: Identifiable {
    let id = UUID()
    let label: String
    let value: String
}

/// 一次读取的结果。
struct Reading {
    var rows: [ReadingRow]
    /// 原始数据（JSON），和上传到服务器的内容一致。
    var raw: String
    var at: Date
}

enum Readable {
    // MARK: 入口

    static func reading(kind: DataKind, samples: [Sample]) -> Reading {
        let raw = samples.compactMap { try? JSON.data($0.payload) }.map { JSON.pretty($0) }.joined(separator: "\n")
        return Reading(rows: Self.rows(kind: kind, samples: samples), raw: raw, at: samples.last?.capturedAt ?? Date())
    }

    static func rows(kind: DataKind, samples: [Sample]) -> [ReadingRow] {
        guard let p = samples.last?.payload else { return [] }
        switch kind {
        case .deviceStatus: return status(p)
        case .deviceSystem: return system(p)
        case .deviceNetwork: return network(p)
        case .motionPedometer: return pedometer(p)
        case .motionActivity: return activity(p)
        case .focusStatus: return [.init(label: "专注模式", value: yesNo(p["isFocused"], yes: "开启", no: "关闭"))]
        case .locationCoarse: return coarse(p)
        case .locationNow: return location(p)
        case .locationTrack: return track(samples)
        case .motionQuery: return perDay(samples, motionDay)
        case .nfcRead: return nfc(p)
        case .bluetoothScan: return bluetooth(p)
        case .networkScan: return lan(p)
        case .probeReport: return []
        }
    }

    // MARK: 小工具

    private static func row(_ label: String, _ value: String?) -> ReadingRow? {
        guard let value, !value.isEmpty else { return nil }
        return ReadingRow(label: label, value: value)
    }

    private static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        return nil
    }

    private static func str(_ v: Any?) -> String? { v as? String }

    private static func bool(_ v: Any?) -> Bool? {
        if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        return nil
    }

    private static func yesNo(_ v: Any?, yes: String = "是", no: String = "否") -> String {
        guard let b = bool(v) else { return "未知" }
        return b ? yes : no
    }

    private static func pct(_ v: Any?) -> String? { num(v).map { String(format: "%.0f%%", $0 * 100) } }

    private static func fmt(_ v: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", v) }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private static let hmFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// 载荷里的时间可能已经是字符串（经过清洗），也可能还是 Date。
    private static func date(_ v: Any?) -> Date? {
        if let d = v as? Date { return d }
        if let s = v as? String { return JSON.parseDate(s) }
        return nil
    }

    private static func compact(_ rows: [ReadingRow?]) -> [ReadingRow] { rows.compactMap { $0 } }

    // MARK: 设备

    private static func status(_ p: [String: Any]) -> [ReadingRow] {
        let state = ["charging": "充电中", "full": "已充满", "unplugged": "未充电", "unknown": "未知"]
        let thermal = ["nominal": "正常", "fair": "偏热", "serious": "严重发热", "critical": "危急"]
        let outputs = (p["audioOutputs"] as? [[String: Any]] ?? []).map { "\($0["name"] as? String ?? "")（\($0["type"] as? String ?? "")）" }
        return compact([
            row("电量", pct(p["batteryLevel"])),
            row("充电状态", state[str(p["batteryState"]) ?? ""] ?? str(p["batteryState"])),
            row("低电量模式", yesNo(p["lowPowerMode"], yes: "开启", no: "关闭")),
            row("机身温度状态", thermal[str(p["thermalState"]) ?? ""] ?? str(p["thermalState"])),
            row("屏幕亮度", pct(p["screenBrightness"])),
            row("媒体音量", pct(p["outputVolume"])),
            row("音频输出", outputs.joined(separator: "、")),
            row("其他 App 正在出声", yesNo(p["isOtherAudioPlaying"])),
        ])
    }

    private static func system(_ p: [String: Any]) -> [ReadingRow] {
        let g = p["gestalt"] as? [String: Any] ?? [:]
        var screen: String?
        if let w = num(g["main-screen-width"]), let h = num(g["main-screen-height"]) {
            screen = "\(Int(w))×\(Int(h))" + (num(g["main-screen-scale"]).map { " @\(Int($0))x" } ?? "")
        }
        return compact([
            row("型号", str(p["modelIdentifier"])),
            row("系统", [str(p["systemName"]), str(p["systemVersion"])].compactMap { $0 }.joined(separator: " ")),
            row("构建号", str(g["BuildVersion"])),
            row("屏幕", screen),
            row("处理器架构", str(g["CPUArchitecture"])),
            row("硬件型号", str(g["HWModelStr"])),
            row("型号编号", str(g["ModelNumber"])),
            row("销售地区", str(g["RegionInfo"])),
            row("机身颜色代码", str(g["DeviceColor"])),
            row("有蜂窝基带", g["HasBaseband"] == nil ? nil : yesNo(g["HasBaseband"])),
        ])
    }

    private static func network(_ p: [String: Any]) -> [ReadingRow] {
        var link = "无"
        if bool(p["wifi"]) == true { link = "Wi-Fi" }
        else if bool(p["cellular"]) == true { link = "蜂窝网络" }
        else if bool(p["wired"]) == true { link = "有线" }
        let radios = (p["radioTechnologies"] as? [String])?.joined(separator: "、")
        return compact([
            row("联网", str(p["status"]) == "satisfied" ? "已联网" : "未联网"),
            row("当前走", link),
            row("计费网络（热点/蜂窝）", yesNo(p["expensive"])),
            row("低数据模式", yesNo(p["constrained"], yes: "开启", no: "关闭")),
            row("蜂窝制式", radios),
            row("IPv4 / IPv6", "\(yesNo(p["supportsIPv4"], yes: "支持", no: "不支持")) / \(yesNo(p["supportsIPv6"], yes: "支持", no: "不支持"))"),
        ])
    }

    // MARK: 运动

    private static func pedometer(_ p: [String: Any]) -> [ReadingRow] {
        var pace: String?
        if let s = num(p["averageActivePaceSecPerMeter"]), s > 0 {
            let perKm = s * 1000
            pace = "\(Int(perKm) / 60) 分 \(Int(perKm) % 60) 秒 / 公里"
        }
        return compact([
            row("日期", str(p["date"])),
            row("步数", num(p["steps"]).map { "\(Int($0)) 步" }),
            row("步行跑步距离", num(p["distanceMeters"]).map { "\(fmt($0 / 1000, 2)) 公里" }),
            row("爬楼", [num(p["floorsAscended"]).map { "上 \(Int($0)) 层" }, num(p["floorsDescended"]).map { "下 \(Int($0)) 层" }]
                .compactMap { $0 }.joined(separator: "，")),
            row("平均配速", pace),
        ])
    }

    private static let stateName = ["stationary": "静止", "walking": "步行", "running": "跑步", "cycling": "骑行",
                                    "automotive": "乘车", "unknown": "未知"]

    private static func activity(_ p: [String: Any]) -> [ReadingRow] {
        var rows = compact([row("当前状态", stateName[str(p["current"]) ?? ""] ?? str(p["current"]))])
        let segs = p["segments"] as? [[String: Any]] ?? []
        for s in segs.suffix(40) {
            guard let from = date(s["from"]), let to = date(s["to"]) else { continue }
            let mins = Int(to.timeIntervalSince(from) / 60)
            rows.append(.init(label: "\(hmFmt.string(from: from))–\(hmFmt.string(from: to))",
                              value: "\(stateName[str(s["state"]) ?? ""] ?? "?")（\(mins) 分钟）"))
        }
        return rows
    }

    // MARK: 健康

    private static func perDay(_ samples: [Sample], _ f: ([String: Any]) -> String) -> [ReadingRow] {
        samples.map { ReadingRow(label: str($0.payload["date"]) ?? "", value: f($0.payload)) }
    }

    private static func motionDay(_ p: [String: Any]) -> String {
        var parts: [String] = []
        if let v = num(p["steps"]) { parts.append("\(Int(v)) 步") }
        if let v = num(p["distanceMeters"]) { parts.append("\(fmt(v / 1000, 1)) 公里") }
        if let v = num(p["floorsAscended"]) { parts.append("爬 \(Int(v)) 层") }
        if let segs = p["segments"] as? [[String: Any]] { parts.append("\(segs.count) 段活动") }
        return parts.isEmpty ? "无数据" : parts.joined(separator: " · ")
    }

    // MARK: 位置

    private static func location(_ p: [String: Any]) -> [ReadingRow] {
        var addr: String?
        if let pl = p["place"] as? [String: Any] {
            addr = ["province", "city", "district", "street", "name"].compactMap { str(pl[$0]) }.joined(separator: " ")
        }
        return compact([
            row("纬度", num(p["latitude"]).map { fmt($0, 6) }),
            row("经度", num(p["longitude"]).map { fmt($0, 6) }),
            row("水平精度", num(p["horizontalAccuracyMeters"]).map { "±\(Int($0)) 米" }),
            row("海拔", num(p["altitudeMeters"]).map { "\(fmt($0, 1)) 米" }),
            row("速度", num(p["speedMetersPerSecond"]).map { "\(fmt($0 * 3.6, 1)) 公里/小时" }),
            row("航向", num(p["courseDegrees"]).map { "\(Int($0))°" }),
            row("地址", addr),
        ])
    }

    private static func coarse(_ p: [String: Any]) -> [ReadingRow] {
        var place: String?
        if let pl = p["place"] as? [String: Any] {
            place = ["country", "province", "city"].compactMap { str(pl[$0]) }.joined(separator: " ")
        }
        return compact([
            row("大致纬度", num(p["latitude"]).map { fmt($0, 3) }),
            row("大致经度", num(p["longitude"]).map { fmt($0, 3) }),
            row("说明", "已随机偏移 \(Int(num(p["offsetKmMin"]) ?? 10))–\(Int(num(p["offsetKmMax"]) ?? 20)) 公里，不是真实位置"),
            row("所在城市（按偏移后的坐标）", place),
        ])
    }

    private static func track(_ samples: [Sample]) -> [ReadingRow] {
        guard let first = samples.first, let last = samples.last else { return [] }
        var meters = 0.0
        var prev: (Double, Double)?
        for s in samples {
            guard let la = num(s.payload["latitude"]), let lo = num(s.payload["longitude"]) else { continue }
            if let (pla, plo) = prev { meters += haversine(pla, plo, la, lo) }
            prev = (la, lo)
        }
        return compact([
            row("记录点数", "\(samples.count)"),
            row("开始", timeFmt.string(from: first.capturedAt)),
            row("结束", timeFmt.string(from: last.capturedAt)),
            row("总里程", "\(fmt(meters / 1000, 2)) 公里"),
            row("起点", [num(first.payload["latitude"]), num(first.payload["longitude"])].compactMap { $0 }.map { fmt($0, 5) }.joined(separator: ", ")),
            row("终点", [num(last.payload["latitude"]), num(last.payload["longitude"])].compactMap { $0 }.map { fmt($0, 5) }.joined(separator: ", ")),
        ])
    }

    private static func haversine(_ la1: Double, _ lo1: Double, _ la2: Double, _ lo2: Double) -> Double {
        let r = 6_371_000.0
        let dLa = (la2 - la1) * .pi / 180, dLo = (lo2 - lo1) * .pi / 180
        let a = sin(dLa / 2) * sin(dLa / 2) + cos(la1 * .pi / 180) * cos(la2 * .pi / 180) * sin(dLo / 2) * sin(dLo / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }

    // MARK: 扫描类

    private static func nfc(_ p: [String: Any]) -> [ReadingRow] {
        let recs = p["records"] as? [[String: Any]] ?? []
        var rows = [ReadingRow(label: "记录数", value: "\(recs.count)")]
        for (i, r) in recs.enumerated() {
            let value = str(r["uri"]) ?? str(r["text"]) ?? "（二进制 \(num(r["payloadBytes"]).map { "\(Int($0))" } ?? "?") 字节）"
            rows.append(.init(label: "记录 \(i + 1)·\(str(r["format"]) ?? "")", value: value))
        }
        return rows
    }

    private static func bluetooth(_ p: [String: Any]) -> [ReadingRow] {
        let devs = p["devices"] as? [[String: Any]] ?? []
        var rows = [ReadingRow(label: "扫描 \(Int(num(p["seconds"]) ?? 0)) 秒，发现", value: "\(devs.count) 个设备")]
        for d in devs.prefix(40) {
            let name = str(d["name"]) ?? "（未命名）"
            var extra: [String] = []
            if let m = str(d["manufacturer"]) { extra.append("厂商 \(m)") }
            if let c = bool(d["connectable"]) { extra.append(c ? "可连接" : "不可连接") }
            rows.append(.init(label: name, value: "\(Int(num(d["rssi"]) ?? 0)) dBm" + (extra.isEmpty ? "" : " · " + extra.joined(separator: " · "))))
        }
        return rows
    }

    private static func lan(_ p: [String: Any]) -> [ReadingRow] {
        var rows = compact([row("本机", str(p["localIP"])), row("网段", str(p["subnet"])), row("提示", str(p["note"]))])
        let hosts = p["hosts"] as? [[String: Any]] ?? []
        rows.append(.init(label: "在线设备", value: "\(hosts.count) 个"))
        for h in hosts {
            let ports = (h["openPorts"] as? [Any] ?? []).compactMap { num($0).map { "\(Int($0))" } }
            rows.append(.init(label: str(h["ip"]) ?? "", value: ports.isEmpty ? "在线（试的端口都没开）" : "开放端口 " + ports.joined(separator: ",")))
        }
        let bonjour = p["bonjour"] as? [[String: Any]] ?? []
        rows.append(.init(label: "Bonjour 广播的服务", value: "\(bonjour.count) 个"))
        for b in bonjour.prefix(60) {
            rows.append(.init(label: str(b["name"]) ?? "", value: str(b["type"]) ?? ""))
        }
        return rows
    }
}
