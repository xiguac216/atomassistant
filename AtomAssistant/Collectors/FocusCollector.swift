import Foundation
import Intents

// MARK: - 专注模式

struct FocusCollector: Collector {
    let kind = DataKind.focusStatus

    func authorize() async -> String? {
        let status = await withCheckedContinuation { (cont: CheckedContinuation<INFocusStatusAuthorizationStatus, Never>) in
            INFocusStatusCenter.default.requestAuthorization { cont.resume(returning: $0) }
        }
        return status == .authorized ? nil : "没有「专注模式状态」权限，请到 设置 → 专注模式 → 专注模式状态 里允许"
    }

    func collect(params: [String: Any]) async throws -> [Sample] {
        guard INFocusStatusCenter.default.authorizationStatus == .authorized else { throw CollectError("没有专注模式状态的权限") }
        let now = Date()
        var p: [String: Any] = [:]
        if let focused = INFocusStatusCenter.default.focusStatus.isFocused {
            p["isFocused"] = focused
        } else {
            p["isFocused"] = NSNull()
        }
        return [Sample(key: bucketKey("focus", seconds: 120, at: now), capturedAt: now, payload: p)]
    }
}
