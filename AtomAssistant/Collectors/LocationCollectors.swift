import Foundation
import CoreLocation

/// 定位的一次性包装：申请权限、取一次位置、连续取一段时间。
final class LocationSession: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authCont: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var oneCont: CheckedContinuation<CLLocation, Error>?
    private var points: [CLLocation] = []
    private var tracking = false

    /// CLLocationManager 的回调跑在创建它的线程的 runloop 上，必须在主线程创建，否则永远收不到回调。
    static func make() async -> LocationSession { await MainActor.run { LocationSession() } }

    /// 只申请权限、不取位置，给「数据源」页里开关用。
    static func requestAccess() async -> String? {
        let s = await make()
        return await s.authorize()
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    static func describe(_ s: CLAuthorizationStatus) -> String? {
        switch s {
        case .denied: return "没有定位权限，请到 设置 → 隐私与安全性 → 定位服务 里允许原子助手"
        case .restricted: return "定位被系统限制了"
        default: return nil
        }
    }

    @MainActor
    func authorize() async -> String? {
        var status = manager.authorizationStatus
        if status == .notDetermined {
            status = await withCheckedContinuation { cont in
                authCont = cont
                manager.requestWhenInUseAuthorization()
            }
        }
        if let t = Self.describe(status) { return t }
        return CLLocationManager.locationServicesEnabled() ? nil : "系统的定位服务是关着的"
    }

    @MainActor
    func once(accuracy: CLLocationAccuracy = kCLLocationAccuracyBest) async throws -> CLLocation {
        manager.desiredAccuracy = accuracy
        return try await withCheckedThrowingContinuation { cont in
            oneCont = cont
            manager.requestLocation()
        }
    }

    /// 连续取 minutes 分钟的位置。要求 Info.plist 里有 location 后台模式，这样用户切走 App 也不会中断。
    @MainActor
    func track(minutes: Double) async -> [CLLocation] {
        points = []
        tracking = true
        manager.distanceFilter = 10
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        try? await Task.sleep(nanoseconds: UInt64(minutes * 60 * 1_000_000_000))
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        tracking = false
        return points
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus != .notDetermined, let c = authCont {
            authCont = nil
            c.resume(returning: manager.authorizationStatus)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if tracking {
            points.append(contentsOf: locations)
        } else if let c = oneCont, let last = locations.last {
            oneCont = nil
            c.resume(returning: last)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let c = oneCont {
            oneCont = nil
            c.resume(throwing: error)
        }
    }
}

private func payload(_ l: CLLocation) -> [String: Any] {
    var p: [String: Any] = [
        "latitude": l.coordinate.latitude, "longitude": l.coordinate.longitude,
        "horizontalAccuracyMeters": l.horizontalAccuracy, "timestamp": l.timestamp,
    ]
    if l.verticalAccuracy >= 0 { p["altitudeMeters"] = l.altitude }
    if l.speed >= 0 { p["speedMetersPerSecond"] = l.speed }
    if l.course >= 0 { p["courseDegrees"] = l.course }
    if let f = l.floor { p["floor"] = f.level }
    return p
}

/// 此刻的位置，外加反向地理编码出的地址（要联网，拿不到就只给坐标）。
struct LocationNowCollector: Collector {
    let kind = DataKind.locationNow

    func authorize() async -> String? { await LocationSession.requestAccess() }

    func collect(params: [String: Any]) async throws -> [Sample] {
        let session = await LocationSession.make()
        if let why = await session.authorize() { throw CollectError(why) }
        let loc = try await session.once()
        var p = payload(loc)
        if let place = await Self.place(for: loc) { p["place"] = place }
        return [Sample(key: "loc-\(Int(loc.timestamp.timeIntervalSince1970))", capturedAt: loc.timestamp, payload: p)]
    }

    private static func place(for loc: CLLocation) async -> [String: Any]? {
        await callbackWithTimeout(6, fallback: nil) { done in
            let geocoder = CLGeocoder()
            geocoder.reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "zh_CN")) { marks, _ in
                withExtendedLifetime(geocoder) {}
                guard let m = marks?.first else { done(nil); return }
                var out: [String: Any] = [:]
                if let v = m.name { out["name"] = v }
                if let v = m.thoroughfare { out["street"] = v }
                if let v = m.subLocality { out["district"] = v }
                if let v = m.locality { out["city"] = v }
                if let v = m.administrativeArea { out["province"] = v }
                if let v = m.country { out["country"] = v }
                done(out)
            }
        }
    }
}

/// 一段时间内的轨迹。最多 200 个点（服务端一次最多收 200 条），多了均匀抽稀。
struct LocationTrackCollector: Collector {
    let kind = DataKind.locationTrack

    func authorize() async -> String? { await LocationSession.requestAccess() }

    func collect(params: [String: Any]) async throws -> [Sample] {
        let minutes = min(max((params["minutes"] as? Double) ?? 10, 1), 120)
        let session = await LocationSession.make()
        if let why = await session.authorize() { throw CollectError(why) }
        let pts = await session.track(minutes: minutes)
        guard !pts.isEmpty else { throw CollectError("这段时间没有定位到任何位置（没有移动，或定位被中断）") }
        let limit = 200
        let chosen: [CLLocation]
        if pts.count <= limit {
            chosen = pts
        } else {
            let step = Double(pts.count - 1) / Double(limit - 1)
            chosen = (0..<limit).map { pts[Int((Double($0) * step).rounded())] }
        }
        return chosen.map {
            Sample(key: "trk-\(Int($0.timestamp.timeIntervalSince1970 * 1000))", capturedAt: $0.timestamp, payload: payload($0))
        }
    }
}
