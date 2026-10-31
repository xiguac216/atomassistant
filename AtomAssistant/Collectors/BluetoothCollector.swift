import Foundation
import CoreBluetooth

/// 扫描附近的蓝牙设备：助手提出需求，你同意后在手机上扫几秒，结果回传。
/// 只读广播：设备名、信号强度、广播里带的服务和厂商标识。不连接任何设备。
struct BluetoothScanCollector: Collector {
    let kind = DataKind.bluetoothScan

    func authorize() async -> String? {
        let s = await BluetoothScanner.make()
        return await s.ready()
    }

    func collect(params: [String: Any]) async throws -> [Sample] {
        let seconds = min(max((params["seconds"] as? Double) ?? 10, 3), 60)
        let scanner = await BluetoothScanner.make()
        if let why = await scanner.ready() { throw CollectError(why) }
        let devices = await scanner.scan(seconds: seconds)
        let now = Date()
        let payload: [String: Any] = ["seconds": seconds, "count": devices.count, "devices": devices]
        return [Sample(key: "bt-\(Int(now.timeIntervalSince1970 * 1000))", capturedAt: now, payload: payload)]
    }
}

@MainActor
final class BluetoothScanner: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private var lastState: CBManagerState = .unknown
    private var waiter: CheckedContinuation<CBManagerState, Never>?
    private var found: [UUID: [String: Any]] = [:]

    /// CBCentralManager 的回调跑在创建它的队列上，这里统一在主线程创建。
    static func make() async -> BluetoothScanner { BluetoothScanner() }

    /// 等蓝牙就绪。没权限、没开蓝牙就返回原因；第一次会弹出系统的权限框。
    func ready() async -> String? {
        switch CBManager.authorization {
        case .denied: return "没有蓝牙权限，请到 设置 → 隐私与安全性 → 蓝牙 里允许原子助手"
        case .restricted: return "蓝牙被系统限制了"
        default: break
        }
        if manager == nil { manager = CBCentralManager(delegate: self, queue: .main) }
        let state = await waitState()
        switch state {
        case .poweredOn: return nil
        case .poweredOff: return "蓝牙是关着的，请先打开蓝牙"
        case .unauthorized: return "没有蓝牙权限，请到 设置 → 隐私与安全性 → 蓝牙 里允许原子助手"
        case .unsupported: return "这台设备不支持蓝牙"
        default: return "蓝牙还没有就绪（可能在等你处理权限弹窗），请再试一次"
        }
    }

    private func waitState() async -> CBManagerState {
        if lastState != .unknown && lastState != .resetting { return lastState }
        return await withCheckedContinuation { (c: CheckedContinuation<CBManagerState, Never>) in
            waiter = c
            // 弹窗没人点时不能一直等。
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 45 * 1_000_000_000)
                self?.resolve(.unknown)
            }
        }
    }

    private func resolve(_ s: CBManagerState) {
        guard let w = waiter else { return }
        waiter = nil
        w.resume(returning: s)
    }

    /// 扫 seconds 秒，返回按信号强弱排好的设备列表（最多 100 个）。
    func scan(seconds: Double) async -> [[String: Any]] {
        found = [:]
        manager?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        manager?.stopScan()
        let list = found.values.sorted { ($0["rssi"] as? Int ?? -200) > ($1["rssi"] as? Int ?? -200) }
        return Array(list.prefix(100))
    }

    // MARK: CBCentralManagerDelegate

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let s = central.state
        Task { @MainActor in
            self.lastState = s
            if s != .unknown && s != .resetting { self.resolve(s) }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let rssi = RSSI.intValue
        // 127 表示读不到信号强度。
        guard rssi != 127 else { return }
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map { $0.uuidString } ?? []
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        let tx = (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue
        var company: String?
        if let m = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, m.count >= 2 {
            // 前两个字节是厂商编号（小端），例如 0x004C 是苹果。
            company = String(format: "0x%04X", Int(m[0]) | (Int(m[1]) << 8))
        }
        Task { @MainActor in
            var row = self.found[id] ?? ["id": id.uuidString, "seen": 0]
            if let name, !name.isEmpty { row["name"] = name }
            let best = max(rssi, row["rssi"] as? Int ?? -200)
            row["rssi"] = best
            row["seen"] = (row["seen"] as? Int ?? 0) + 1
            if !services.isEmpty { row["services"] = services }
            if let connectable { row["connectable"] = connectable }
            if let tx { row["txPower"] = tx }
            if let company { row["manufacturer"] = company }
            self.found[id] = row
        }
    }
}
