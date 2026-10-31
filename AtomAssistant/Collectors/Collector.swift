import Foundation

/// 一种数据的采集器。持续上报的和按次授权的都实现它：按次授权的靠 params 接收需求里的参数。
protocol Collector {
    var kind: DataKind { get }
    /// 申请这种数据需要的系统权限。返回 nil 表示可以用，否则是给用户看的原因。
    func authorize() async -> String?
    func collect(params: [String: Any]) async throws -> [Sample]
}

struct CollectError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Collectors {
    static let all: [DataKind: Collector] = {
        let list: [Collector] = [
            DeviceStatusCollector(), SystemCollector(), NetworkCollector(),
            PedometerCollector(), ActivityCollector(),
            FocusCollector(),
            BluetoothScanCollector(), NetworkScanCollector(),
            CoarseLocationCollector(), LocationNowCollector(), LocationTrackCollector(),
            MotionQueryCollector(), NFCReadCollector(),
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.kind, $0) })
    }()
}

// MARK: - 小工具

/// 把「回调式」接口包成 async，并保证一定会返回：回调迟迟不来就用 fallback。
/// 系统里有些接口（私有的尤其）没权限时不是报错而是干脆不回调。
func callbackWithTimeout<T>(_ seconds: Double, fallback: T, _ start: (@escaping (T) -> Void) -> Void) async -> T {
    await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
        let lock = NSLock()
        var done = false
        let finish: (T) -> Void = { value in
            lock.lock()
            let already = done
            done = true
            lock.unlock()
            if !already { cont.resume(returning: value) }
        }
        start(finish)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { finish(fallback) }
    }
}

/// 按 5 分钟、小时、天这样的桶给数据起稳定的 key，同一桶里重传不会重复入库。
func bucketKey(_ prefix: String, seconds: TimeInterval, at date: Date = Date()) -> String {
    "\(prefix)-\(Int(date.timeIntervalSince1970 / seconds))"
}

func startOfToday() -> Date { Calendar.current.startOfDay(for: Date()) }

let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()
