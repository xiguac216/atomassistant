import Foundation
import CoreLocation

/// 粗略位置：读到当前的精确位置后，在手机上先随机偏移 10 到 20 公里，再上报。
///
/// 精确位置只在这个函数里短暂存在，不写盘、不上传、不显示；服务器永远收不到它。
/// 偏移的方向和距离每次都重新随机（距离在 10–20 公里均匀取，方向在 0–360 度均匀取）。
/// 所以单次上报只能说明「你大概在这附近、在哪个城市」，不能还原出你的真实位置；
/// 但同一个地方上报很多次，平均下来会逼近真实位置，这是随机偏移固有的局限。
struct CoarseLocationCollector: Collector {
    let kind = DataKind.locationCoarse

    func authorize() async -> String? { await LocationSession.requestAccess() }

    func collect(params: [String: Any]) async throws -> [Sample] {
        let session = await LocationSession.make()
        if let why = await session.authorize() { throw CollectError(why) }
        // 只要城市级精度，省电。
        let precise = try await session.once(accuracy: kCLLocationAccuracyKilometer)
        let fuzzed = Fuzz.randomized(latitude: precise.coordinate.latitude, longitude: precise.coordinate.longitude)

        var payload: [String: Any] = [
            // 保留 3 位小数（约 100 米）：偏移已经是公里级，再多的小数位只是假精度。
            "latitude": (fuzzed.latitude * 1000).rounded() / 1000,
            "longitude": (fuzzed.longitude * 1000).rounded() / 1000,
            "approximate": true,
            "offsetKmMin": Fuzz.minKm,
            "offsetKmMax": Fuzz.maxKm,
        ]
        // 反向地理编码用的是偏移之后的坐标，也只取到城市一级。
        if let place = await Self.city(latitude: fuzzed.latitude, longitude: fuzzed.longitude) { payload["place"] = place }
        let now = Date()
        return [Sample(key: bucketKey("coarse", seconds: 600, at: now), capturedAt: now, payload: payload)]
    }

    private static func city(latitude: Double, longitude: Double) async -> [String: Any]? {
        await callbackWithTimeout(6, fallback: nil) { done in
            let geocoder = CLGeocoder()
            geocoder.reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude),
                                            preferredLocale: Locale(identifier: "zh_CN")) { marks, _ in
                withExtendedLifetime(geocoder) {}
                guard let m = marks?.first else { done(nil); return }
                var out: [String: Any] = [:]
                if let v = m.locality { out["city"] = v }
                if let v = m.administrativeArea { out["province"] = v }
                if let v = m.country { out["country"] = v }
                done(out.isEmpty ? nil : out)
            }
        }
    }
}

/// 随机偏移。纯数学，不依赖系统，方便核对。
enum Fuzz {
    static let minKm = 10.0
    static let maxKm = 20.0
    private static let earthKm = 6371.0

    /// 把坐标沿随机方向移动 10 到 20 公里（球面上的目的地公式）。
    static func randomized(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        var rng = SystemRandomNumberGenerator()
        let distance = Double.random(in: minKm...maxKm, using: &rng)
        let bearing = Double.random(in: 0..<(2 * Double.pi), using: &rng)
        return moved(latitude: latitude, longitude: longitude, km: distance, bearing: bearing)
    }

    static func moved(latitude: Double, longitude: Double, km: Double, bearing: Double) -> (latitude: Double, longitude: Double) {
        let la1 = latitude * .pi / 180, lo1 = longitude * .pi / 180
        let d = km / earthKm
        let la2 = asin(sin(la1) * cos(d) + cos(la1) * sin(d) * cos(bearing))
        let lo2 = lo1 + atan2(sin(bearing) * sin(d) * cos(la1), cos(d) - sin(la1) * sin(la2))
        // 经度归一化到 [-180, 180)。
        var lon = (lo2 * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if lon >= 180 { lon -= 360 }
        if lon < -180 { lon += 360 }
        return (la2 * 180 / .pi, lon)
    }
}
