import Foundation
import CoreMotion

private let pedometer = CMPedometer()
private let activityManager = CMMotionActivityManager()

private func authText(_ s: CMAuthorizationStatus) -> String? {
    switch s {
    case .denied: return "没有「运动与健身」权限，请到 设置 → 隐私与安全性 → 运动与健身 里打开"
    case .restricted: return "运动与健身被系统限制了"
    default: return nil
    }
}

/// 计步：今日步数、距离、爬楼。
struct PedometerCollector: Collector {
    let kind = DataKind.motionPedometer

    func authorize() async -> String? {
        guard CMPedometer.isStepCountingAvailable() else { return "这台设备不支持计步" }
        if let t = authText(CMPedometer.authorizationStatus()) { return t }
        // 第一次查询会弹出权限请求。
        _ = try? await Self.query(from: startOfToday(), to: Date())
        return authText(CMPedometer.authorizationStatus())
    }

    func collect(params: [String: Any]) async throws -> [Sample] {
        let now = Date()
        let data = try await Self.query(from: startOfToday(), to: now)
        return [Sample(key: bucketKey("ped", seconds: 600, at: now), capturedAt: now, payload: Self.payload(data, day: startOfToday()))]
    }

    static func query(from: Date, to: Date) async throws -> CMPedometerData {
        try await withCheckedThrowingContinuation { cont in
            pedometer.queryPedometerData(from: from, to: to) { data, error in
                if let data { cont.resume(returning: data) }
                else { cont.resume(throwing: error ?? CollectError("计步没有返回数据")) }
            }
        }
    }

    static func payload(_ d: CMPedometerData, day: Date) -> [String: Any] {
        var p: [String: Any] = ["date": dayFormatter.string(from: day), "steps": d.numberOfSteps.intValue]
        if let v = d.distance { p["distanceMeters"] = v.doubleValue }
        if let v = d.floorsAscended { p["floorsAscended"] = v.intValue }
        if let v = d.floorsDescended { p["floorsDescended"] = v.intValue }
        if let v = d.averageActivePace { p["averageActivePaceSecPerMeter"] = v.doubleValue }
        return p
    }
}

private func stateName(_ a: CMMotionActivity) -> String {
    if a.automotive { return "automotive" }
    if a.cycling { return "cycling" }
    if a.running { return "running" }
    if a.walking { return "walking" }
    if a.stationary { return "stationary" }
    return "unknown"
}

private func confidenceName(_ c: CMMotionActivityConfidence) -> String {
    switch c {
    case .high: return "high"
    case .medium: return "medium"
    default: return "low"
    }
}

/// 把一连串运动状态记录压成「从几点到几点是什么状态」的片段。
private func segments(_ list: [CMMotionActivity], end: Date) -> [[String: Any]] {
    var out: [[String: Any]] = []
    var current: (state: String, start: Date, conf: String)?
    for a in list {
        let s = stateName(a)
        if s == "unknown" { continue }
        if let c = current, c.state == s { continue }
        if let c = current {
            out.append(["state": c.state, "from": c.start, "to": a.startDate, "confidence": c.conf])
        }
        current = (s, a.startDate, confidenceName(a.confidence))
    }
    if let c = current {
        out.append(["state": c.state, "from": c.start, "to": end, "confidence": c.conf])
    }
    return out
}

private func activityHistory(from: Date, to: Date) async throws -> [CMMotionActivity] {
    try await withCheckedThrowingContinuation { cont in
        activityManager.queryActivityStarting(from: from, to: to, to: OperationQueue()) { list, error in
            if let list { cont.resume(returning: list) }
            else { cont.resume(throwing: error ?? CollectError("运动状态没有返回数据")) }
        }
    }
}

/// 运动状态：最近 6 小时里静止、步行、跑步、骑行、驾车的时间段。
struct ActivityCollector: Collector {
    let kind = DataKind.motionActivity

    func authorize() async -> String? {
        guard CMMotionActivityManager.isActivityAvailable() else { return "这台设备不支持运动状态" }
        if let t = authText(CMMotionActivityManager.authorizationStatus()) { return t }
        _ = try? await activityHistory(from: Date().addingTimeInterval(-60), to: Date())
        return authText(CMMotionActivityManager.authorizationStatus())
    }

    func collect(params: [String: Any]) async throws -> [Sample] {
        let now = Date()
        let list = try await activityHistory(from: now.addingTimeInterval(-6 * 3600), to: now)
        let segs = segments(list, end: now)
        let p: [String: Any] = ["windowHours": 6, "segments": segs, "current": segs.last?["state"] ?? "unknown"]
        return [Sample(key: bucketKey("act", seconds: 600, at: now), capturedAt: now, payload: p)]
    }
}

/// 按次授权：指定时间段的计步与运动历史。系统只保留最近 7 天。
struct MotionQueryCollector: Collector {
    let kind = DataKind.motionQuery

    func authorize() async -> String? {
        guard CMPedometer.isStepCountingAvailable() else { return "这台设备不支持计步" }
        if let t = authText(CMPedometer.authorizationStatus()) { return t }
        _ = try? await PedometerCollector.query(from: startOfToday(), to: Date())
        return authText(CMPedometer.authorizationStatus())
    }

    func collect(params: [String: Any]) async throws -> [Sample] {
        let now = Date()
        let earliest = now.addingTimeInterval(-7 * 86400)
        var from = (params["from"] as? Date) ?? startOfToday()
        let to = min((params["to"] as? Date) ?? now, now)
        if from < earliest { from = earliest }
        guard from < to else { throw CollectError("时间范围不对，或超出了系统保留的最近 7 天") }

        let cal = Calendar.current
        var samples: [Sample] = []
        var dayStart = cal.startOfDay(for: from)
        while dayStart < to {
            let next = cal.date(byAdding: .day, value: 1, to: dayStart) ?? to
            let lo = max(dayStart, from), hi = min(next, to)
            var p: [String: Any] = ["date": dayFormatter.string(from: dayStart)]
            if let d = try? await PedometerCollector.query(from: lo, to: hi) {
                p.merge(PedometerCollector.payload(d, day: dayStart)) { $1 }
            }
            if CMMotionActivityManager.isActivityAvailable(), let acts = try? await activityHistory(from: lo, to: hi) {
                p["segments"] = segments(acts, end: hi)
            }
            samples.append(Sample(key: "mq-" + dayFormatter.string(from: dayStart), capturedAt: hi, payload: p))
            dayStart = next
        }
        return samples
    }
}
