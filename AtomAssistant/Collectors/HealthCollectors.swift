import Foundation
import HealthKit

private let store = HKHealthStore()

/// 要读的健康数据。读权限被拒和「没有数据」在 HealthKit 里无法区分，所以拿不到时统一说「无数据或未授权」。
private enum HealthTypes {
    struct Cumulative { let id: HKQuantityTypeIdentifier; let name: String; let unit: HKUnit }
    struct Discrete { let id: HKQuantityTypeIdentifier; let name: String; let unit: HKUnit }

    static let cumulative: [Cumulative] = [
        .init(id: .stepCount, name: "steps", unit: .count()),
        .init(id: .distanceWalkingRunning, name: "distanceMeters", unit: .meter()),
        .init(id: .activeEnergyBurned, name: "activeEnergyKcal", unit: .kilocalorie()),
        .init(id: .flightsClimbed, name: "flightsClimbed", unit: .count()),
        .init(id: .appleExerciseTime, name: "exerciseMinutes", unit: .minute()),
        .init(id: .appleStandTime, name: "standMinutes", unit: .minute()),
    ]

    static let discrete: [Discrete] = [
        .init(id: .heartRate, name: "heartRate", unit: HKUnit.count().unitDivided(by: .minute())),
        .init(id: .restingHeartRate, name: "restingHeartRate", unit: HKUnit.count().unitDivided(by: .minute())),
        .init(id: .walkingHeartRateAverage, name: "walkingHeartRate", unit: HKUnit.count().unitDivided(by: .minute())),
        .init(id: .heartRateVariabilitySDNN, name: "heartRateVariabilityMs", unit: .secondUnit(with: .milli)),
        .init(id: .oxygenSaturation, name: "oxygenSaturation", unit: .percent()),
        .init(id: .respiratoryRate, name: "respiratoryRate", unit: HKUnit.count().unitDivided(by: .minute())),
        .init(id: .bodyMass, name: "bodyMassKg", unit: .gramUnit(with: .kilo)),
        .init(id: .vo2Max, name: "vo2Max", unit: HKUnit(from: "ml/(kg*min)")),
    ]

    static var readTypes: Set<HKObjectType> {
        var s = Set<HKObjectType>()
        for c in cumulative { if let t = HKQuantityType.quantityType(forIdentifier: c.id) { s.insert(t) } }
        for d in discrete { if let t = HKQuantityType.quantityType(forIdentifier: d.id) { s.insert(t) } }
        if let t = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(t) }
        s.insert(HKObjectType.workoutType())
        return s
    }
}

private func requestHealth() async -> String? {
    guard HKHealthStore.isHealthDataAvailable() else { return "这台设备不支持健康数据" }
    return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
        store.requestAuthorization(toShare: nil, read: HealthTypes.readTypes) { _, error in
            // 这里的 success 只表示弹窗走完了，不表示用户同意。拿不到数据时会在采集结果里说明。
            // 没有 HealthKit 的 entitlement（免费签名常见）时会在这里报错。
            cont.resume(returning: error.map { "健康授权失败：\($0.localizedDescription)（免费签名通常没有 HealthKit 权限）" })
        }
    }
}

// MARK: - 查询小工具

private func sum(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from: Date, to: Date) async -> Double? {
    guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
    return await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
        let pred = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: pred, options: .cumulativeSum) { _, stats, _ in
            cont.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
        }
        store.execute(q)
    }
}

private func latest(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> (value: Double, date: Date)? {
    guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
    return await withCheckedContinuation { (cont: CheckedContinuation<(value: Double, date: Date)?, Never>) in
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let q = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
            if let s = samples?.first as? HKQuantitySample {
                cont.resume(returning: (s.quantity.doubleValue(for: unit), s.endDate))
            } else {
                cont.resume(returning: nil)
            }
        }
        store.execute(q)
    }
}

private func stats(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from: Date, to: Date) async -> (avg: Double, min: Double, max: Double)? {
    guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
    return await withCheckedContinuation { (cont: CheckedContinuation<(avg: Double, min: Double, max: Double)?, Never>) in
        let pred = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: pred,
                                  options: [.discreteAverage, .discreteMin, .discreteMax]) { _, s, _ in
            if let a = s?.averageQuantity()?.doubleValue(for: unit),
               let lo = s?.minimumQuantity()?.doubleValue(for: unit),
               let hi = s?.maximumQuantity()?.doubleValue(for: unit) {
                cont.resume(returning: (a, lo, hi))
            } else {
                cont.resume(returning: nil)
            }
        }
        store.execute(q)
    }
}

/// 一段时间里的睡眠，按状态累计小时数。
private func sleep(from: Date, to: Date) async -> [String: Double]? {
    guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
    return await withCheckedContinuation { (cont: CheckedContinuation<[String: Double]?, Never>) in
        let pred = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        let q = HKSampleQuery(sampleType: type, predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
            guard let samples = samples as? [HKCategorySample], !samples.isEmpty else { cont.resume(returning: nil); return }
            var hours: [String: Double] = [:]
            for s in samples {
                let name: String
                switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
                case .inBed: name = "inBed"
                case .awake: name = "awake"
                case .asleepCore: name = "core"
                case .asleepDeep: name = "deep"
                case .asleepREM: name = "rem"
                default: name = "asleepUnspecified"
                }
                hours[name, default: 0] += s.endDate.timeIntervalSince(s.startDate) / 3600
            }
            cont.resume(returning: hours)
        }
        store.execute(q)
    }
}

private func workouts(from: Date, to: Date) async -> [[String: Any]] {
    await withCheckedContinuation { (cont: CheckedContinuation<[[String: Any]], Never>) in
        let pred = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let q = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: pred, limit: 30, sortDescriptors: [sort]) { _, samples, _ in
            let list = (samples as? [HKWorkout] ?? []).map { w -> [String: Any] in
                var row: [String: Any] = [
                    "type": w.workoutActivityType.rawValue,
                    "start": w.startDate, "end": w.endDate, "durationMinutes": w.duration / 60,
                ]
                if let e = w.totalEnergyBurned?.doubleValue(for: .kilocalorie()) { row["energyKcal"] = e }
                if let d = w.totalDistance?.doubleValue(for: .meter()) { row["distanceMeters"] = d }
                return row
            }
            cont.resume(returning: list)
        }
        store.execute(q)
    }
}

// MARK: - 持续上报：今日摘要

struct HealthSummaryCollector: Collector {
    let kind = DataKind.healthSummary

    func authorize() async -> String? { await requestHealth() }

    func collect(params: [String: Any]) async throws -> [Sample] {
        guard HKHealthStore.isHealthDataAvailable() else { throw CollectError("这台设备不支持健康数据") }
        let now = Date()
        let today = startOfToday()
        var p: [String: Any] = ["date": dayFormatter.string(from: today)]
        var got = false

        for c in HealthTypes.cumulative {
            if let v = await sum(c.id, unit: c.unit, from: today, to: now) { p[c.name] = v; got = true }
        }
        var latestValues: [String: Any] = [:]
        for d in HealthTypes.discrete {
            if let l = await latest(d.id, unit: d.unit) {
                latestValues[d.name] = ["value": l.value, "at": l.date] as [String: Any]
                got = true
            }
        }
        if !latestValues.isEmpty { p["latest"] = latestValues }
        if let h = await sleep(from: now.addingTimeInterval(-36 * 3600), to: now) { p["sleepLast36hHours"] = h; got = true }
        let ws = await workouts(from: now.addingTimeInterval(-7 * 86400), to: now)
        if !ws.isEmpty { p["workoutsLast7d"] = ws; got = true }

        guard got else { throw CollectError("没有读到任何健康数据：没有数据，或没有授权（HealthKit 区分不了这两种情况）") }
        return [Sample(key: bucketKey("health", seconds: 900, at: now), capturedAt: now, payload: p)]
    }
}

// MARK: - 按次授权：指定时间段的详细记录

struct HealthQueryCollector: Collector {
    let kind = DataKind.healthQuery

    func authorize() async -> String? { await requestHealth() }

    func collect(params: [String: Any]) async throws -> [Sample] {
        guard HKHealthStore.isHealthDataAvailable() else { throw CollectError("这台设备不支持健康数据") }
        let now = Date()
        let to = min((params["to"] as? Date) ?? now, now)
        let from = (params["from"] as? Date) ?? to.addingTimeInterval(-7 * 86400)
        guard from < to else { throw CollectError("时间范围不对") }
        guard to.timeIntervalSince(from) <= 31 * 86400 else { throw CollectError("时间跨度不能超过 31 天") }

        let cal = Calendar.current
        var samples: [Sample] = []
        var dayStart = cal.startOfDay(for: from)
        while dayStart < to {
            let next = cal.date(byAdding: .day, value: 1, to: dayStart) ?? to
            let lo = max(dayStart, from), hi = min(next, to)
            var p: [String: Any] = ["date": dayFormatter.string(from: dayStart)]
            var got = false
            for c in HealthTypes.cumulative {
                if let v = await sum(c.id, unit: c.unit, from: lo, to: hi) { p[c.name] = v; got = true }
            }
            var spread: [String: Any] = [:]
            for d in HealthTypes.discrete {
                if let s = await stats(d.id, unit: d.unit, from: lo, to: hi) {
                    spread[d.name] = ["avg": s.avg, "min": s.min, "max": s.max]
                    got = true
                }
            }
            if !spread.isEmpty { p["stats"] = spread }
            // 睡眠按「醒来那天」算：取当天中午前的 24 小时。
            let nightEnd = min(cal.date(byAdding: .hour, value: 12, to: dayStart) ?? hi, hi)
            if let h = await sleep(from: nightEnd.addingTimeInterval(-24 * 3600), to: nightEnd) { p["sleepHours"] = h; got = true }
            let ws = await workouts(from: lo, to: hi)
            if !ws.isEmpty { p["workouts"] = ws; got = true }

            if got { samples.append(Sample(key: "hq-" + dayFormatter.string(from: dayStart), capturedAt: hi, payload: p)) }
            dayStart = next
        }
        guard !samples.isEmpty else { throw CollectError("这段时间没有读到健康数据：没有数据，或没有授权") }
        return samples
    }
}
