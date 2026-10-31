import Foundation
import UIKit
import AVFoundation
import Network
import NetworkExtension
import CoreTelephony

// MARK: - 设备状态

struct DeviceStatusCollector: Collector {
    let kind = DataKind.deviceStatus

    func authorize() async -> String? { nil }

    func collect(params: [String: Any]) async throws -> [Sample] {
        let now = Date()
        var p = await MainActor.run { Self.snapshot() }
        // 私有接口：电池的详细情况。拿不到就只记一下为什么，不影响其他字段。
        let battery = PrivateAPI.batteryDetail()
        if let v = battery.value { p["batteryDetail"] = v } else if let e = battery.error { p["batteryDetailError"] = e }
        return [Sample(key: bucketKey("status", seconds: 300, at: now), capturedAt: now, payload: p)]
    }

    @MainActor
    private static func snapshot() -> [String: Any] {
        let dev = UIDevice.current
        dev.isBatteryMonitoringEnabled = true
        var p: [String: Any] = [:]
        p["batteryLevel"] = dev.batteryLevel >= 0 ? Double(dev.batteryLevel) : NSNull()
        switch dev.batteryState {
        case .charging: p["batteryState"] = "charging"
        case .full: p["batteryState"] = "full"
        case .unplugged: p["batteryState"] = "unplugged"
        default: p["batteryState"] = "unknown"
        }
        p["lowPowerMode"] = ProcessInfo.processInfo.isLowPowerModeEnabled
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: p["thermalState"] = "nominal"
        case .fair: p["thermalState"] = "fair"
        case .serious: p["thermalState"] = "serious"
        case .critical: p["thermalState"] = "critical"
        @unknown default: p["thermalState"] = "unknown"
        }
        p["screenBrightness"] = Double(UIScreen.main.brightness)

        if let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]) {
            if let t = v.volumeTotalCapacity { p["storageTotalBytes"] = t }
            if let a = v.volumeAvailableCapacityForImportantUsage { p["storageAvailableBytes"] = a }
        }

        let session = AVAudioSession.sharedInstance()
        p["outputVolume"] = Double(session.outputVolume)
        p["audioOutputs"] = session.currentRoute.outputs.map { ["type": $0.portType.rawValue, "name": $0.portName] }
        p["isOtherAudioPlaying"] = session.isOtherAudioPlaying
        return p
    }
}

// MARK: - 系统信息

struct SystemCollector: Collector {
    let kind = DataKind.deviceSystem

    func authorize() async -> String? { nil }

    func collect(params: [String: Any]) async throws -> [Sample] {
        let now = Date()
        var p: [String: Any] = [:]
        p["modelIdentifier"] = Self.machine()
        p["systemName"] = await MainActor.run { UIDevice.current.systemName }
        p["systemVersion"] = await MainActor.run { UIDevice.current.systemVersion }
        p["deviceName"] = await MainActor.run { UIDevice.current.name }
        p["physicalMemoryBytes"] = ProcessInfo.processInfo.physicalMemory
        p["cpuCores"] = ProcessInfo.processInfo.processorCount
        p["uptimeSeconds"] = ProcessInfo.processInfo.systemUptime
        p["locale"] = Locale.current.identifier
        p["timeZone"] = TimeZone.current.identifier
        p["languages"] = Locale.preferredLanguages
        if let boot = Self.bootTime() { p["bootTime"] = boot }

        let g = PrivateAPI.gestalt()
        if let v = g.value { p["gestalt"] = v } else if let e = g.error { p["gestaltError"] = e }

        return [Sample(key: bucketKey("system", seconds: 6 * 3600, at: now), capturedAt: now, payload: p)]
    }

    static func machine() -> String {
        var u = utsname()
        uname(&u)
        return withUnsafePointer(to: &u.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: u.machine)) { String(cString: $0) }
        }
    }

    private static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, UInt32(mib.count), &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }
}

// MARK: - 网络

struct NetworkCollector: Collector {
    let kind = DataKind.deviceNetwork

    func authorize() async -> String? { nil }

    func collect(params: [String: Any]) async throws -> [Sample] {
        let now = Date()
        var p: [String: Any] = [:]

        let path: NWPath? = await callbackWithTimeout(3, fallback: nil) { done in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                done(path)
            }
            monitor.start(queue: DispatchQueue(label: "net.probe"))
        }
        if let path {
            p["status"] = path.status == .satisfied ? "satisfied" : "unsatisfied"
            p["wifi"] = path.usesInterfaceType(.wifi)
            p["cellular"] = path.usesInterfaceType(.cellular)
            p["wired"] = path.usesInterfaceType(.wiredEthernet)
            p["expensive"] = path.isExpensive
            p["constrained"] = path.isConstrained
            p["supportsIPv4"] = path.supportsIPv4
            p["supportsIPv6"] = path.supportsIPv6
        } else {
            p["statusError"] = "读取网络路径超时"
        }

        // 蜂窝网络制式。
        let tel = CTTelephonyNetworkInfo()
        if let techs = tel.serviceCurrentRadioAccessTechnology, !techs.isEmpty {
            p["radioTechnologies"] = techs.values.map { $0.replacingOccurrences(of: "CTRadioAccessTechnology", with: "") }
        }

        // Wi-Fi 名需要特殊的 entitlement，免费签名拿不到，探测一下就好。
        let wifi: String? = await callbackWithTimeout(3, fallback: nil) { done in
            NEHotspotNetwork.fetchCurrent { net in done(net?.ssid) }
        }
        if let wifi { p["ssid"] = wifi } else { p["ssidError"] = "拿不到（需要 Wi-Fi 信息的 entitlement 和定位权限）" }

        return [Sample(key: bucketKey("net", seconds: 300, at: now), capturedAt: now, payload: p)]
    }
}
