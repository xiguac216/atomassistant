import Foundation
import UIKit
import AVFoundation
import Network
import CoreTelephony

// MARK: - 设备状态

struct DeviceStatusCollector: Collector {
    let kind = DataKind.deviceStatus

    func authorize() async -> String? { nil }

    func collect(params: [String: Any]) async throws -> [Sample] {
        let now = Date()
        let p = await MainActor.run { Self.snapshot() }
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

        let g = PrivateAPI.gestalt()
        if let v = g.value { p["gestalt"] = v } else if let e = g.error { p["gestaltError"] = e }

        return [Sample(key: bucketKey("system", seconds: 6 * 3600, at: now), capturedAt: now, payload: p)]
    }

    static func machine() -> String {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}

// MARK: - 网络

struct NetworkCollector: Collector {
    let kind = DataKind.deviceNetwork

    func authorize() async -> String? { nil }

    func collect(params: [String: Any]) async throws -> [Sample] {
        let now = Date()
        var p: [String: Any] = [:]

        let path: Network.NWPath? = await callbackWithTimeout(3, fallback: nil) { done in
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

        return [Sample(key: bucketKey("net", seconds: 300, at: now), capturedAt: now, payload: p)]
    }
}
