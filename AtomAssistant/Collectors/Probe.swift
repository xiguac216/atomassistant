import Foundation
import UIKit
import CoreMotion
import CoreLocation
import Intents
import UserNotifications
import CoreNFC

struct ProbeResult: Identifiable {
    enum Status { case ok, partial, blocked }
    let id = UUID()
    let group: String
    let name: String
    let status: Status
    let detail: String
}

/// 能力探测：在这台手机上实测每一类数据到底拿不拿得到。
/// 全部只读，不弹权限框（没授权的只报「未授权」）；私有接口真的去调一次，看系统放不放行。
enum Prober {
    static func run() async -> [ProbeResult] {
        var out: [ProbeResult] = []

        // 私有接口
        let g = PrivateAPI.gestalt()
        if let v = g.value {
            let names = v.keys.sorted().joined(separator: "、")
            out.append(.init(group: "私有接口", name: "MobileGestalt 设备信息", status: .ok, detail: "读到 \(v.count) 项：\(names)"))
        } else {
            out.append(.init(group: "私有接口", name: "MobileGestalt 设备信息", status: .blocked, detail: g.error ?? "未知"))
        }
        // 公开接口与权限
        out.append(contentsOf: await publicChecks())
        return out
    }

    private static func publicChecks() async -> [ProbeResult] {
        var r: [ProbeResult] = []

        let pedo = CMPedometer.isStepCountingAvailable()
        r.append(.init(group: "公开接口", name: "计步", status: pedo ? authStatus(CMPedometer.authorizationStatus() == .authorized, CMPedometer.authorizationStatus() == .notDetermined) : .blocked,
                       detail: "运动与健身权限：" + motionAuth(CMPedometer.authorizationStatus())))
        r.append(.init(group: "公开接口", name: "运动状态",
                       status: CMMotionActivityManager.isActivityAvailable() ? authStatus(CMMotionActivityManager.authorizationStatus() == .authorized, CMMotionActivityManager.authorizationStatus() == .notDetermined) : .blocked,
                       detail: "运动与健身权限：" + motionAuth(CMMotionActivityManager.authorizationStatus())))

        let loc = CLLocationManager().authorizationStatus
        r.append(.init(group: "公开接口", name: "定位", status: authStatus(loc == .authorizedWhenInUse || loc == .authorizedAlways, loc == .notDetermined),
                       detail: "权限：" + locAuth(loc)))

        let focus = INFocusStatusCenter.default.authorizationStatus
        r.append(.init(group: "公开接口", name: "专注模式状态", status: authStatus(focus == .authorized, focus == .notDetermined),
                       detail: "权限：" + (focus == .authorized ? "已授权" : focus == .notDetermined ? "未询问" : "被拒绝或受限")))

        r.append(.init(group: "公开接口", name: "NFC 读取", status: NFCNDEFReaderSession.readingAvailable ? .partial : .blocked,
                       detail: NFCNDEFReaderSession.readingAvailable
                           ? "硬件支持。能否真正读到取决于签名带不带 NFC entitlement（用 AtomAssistant-full.ipa），读取时会弹出系统读取框"
                           : "这台设备不支持"))

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        r.append(.init(group: "公开接口", name: "本地通知", status: settings.authorizationStatus == .authorized ? .ok : .partial,
                       detail: settings.authorizationStatus == .authorized ? "已授权" : "未授权，授权需求到来时手机不会提醒你"))

        let refresh = await MainActor.run { UIApplication.shared.backgroundRefreshStatus }
        r.append(.init(group: "公开接口", name: "后台刷新", status: refresh == .available ? .ok : .blocked,
                       detail: refresh == .available ? "可用：系统会在合适的时候让 App 在后台同步" : "被关闭或受限：请到 设置 → 通用 → 后台 App 刷新 打开"))
        return r
    }

    private static func authStatus(_ granted: Bool, _ undecided: Bool) -> ProbeResult.Status {
        granted ? .ok : (undecided ? .partial : .blocked)
    }

    private static func motionAuth(_ s: CMAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "已授权"
        case .notDetermined: return "未询问"
        default: return "被拒绝或受限"
        }
    }

    private static func locAuth(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .authorizedAlways: return "始终"
        case .authorizedWhenInUse: return "使用期间"
        case .notDetermined: return "未询问"
        default: return "被拒绝或受限"
        }
    }

    /// 探测结果整理成可以上传的报告。
    static func report(_ results: [ProbeResult]) -> [String: Any] {
        [
            "generatedAt": Date(),
            "results": results.map { r -> [String: Any] in
                let s: String
                switch r.status { case .ok: s = "ok"; case .partial: s = "partial"; case .blocked: s = "blocked" }
                return ["group": r.group, "name": r.name, "status": s, "detail": r.detail]
            },
        ]
    }
}
