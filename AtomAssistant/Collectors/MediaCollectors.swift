import Foundation
import MediaPlayer
import Intents

// MARK: - 正在播放

/// 先用私有的 MediaRemote（任何 App 的播放都能看到），拿不到再退回公开的「音乐」App 播放状态。
struct NowPlayingCollector: Collector {
    let kind = DataKind.mediaNowPlaying

    /// 读「音乐」App 的播放状态要媒体库权限；被拒绝也不影响 MediaRemote 那条路，所以不当成失败。
    func authorize() async -> String? {
        if MPMediaLibrary.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { (cont: CheckedContinuation<MPMediaLibraryAuthorizationStatus, Never>) in
                MPMediaLibrary.requestAuthorization { cont.resume(returning: $0) }
            }
        }
        return nil
    }

    func collect(params: [String: Any]) async throws -> [Sample] {
        let now = Date()
        var p: [String: Any] = [:]

        let r = await PrivateAPI.nowPlaying()
        if let v = r.value { p["source"] = "mediaremote"; p["info"] = v }
        else if let e = r.error { p["mediaRemoteError"] = e }

        // 公开接口：只能看到系统「音乐」App 里在播的。需要媒体库权限，没授权就跳过。
        if MPMediaLibrary.authorizationStatus() == .authorized {
            let item = await MainActor.run { () -> [String: Any]? in
                let player = MPMusicPlayerController.systemMusicPlayer
                guard let it = player.nowPlayingItem else { return nil }
                return [
                    "title": it.title ?? "", "artist": it.artist ?? "", "album": it.albumTitle ?? "",
                    "durationSeconds": it.playbackDuration, "elapsedSeconds": player.currentPlaybackTime,
                    "state": Self.stateName(player.playbackState),
                ]
            }
            if let item { p["musicApp"] = item }
        }

        if p["info"] == nil && p["musicApp"] == nil {
            p["playing"] = false
        }
        return [Sample(key: bucketKey("np", seconds: 60, at: now), capturedAt: now, payload: p)]
    }

    private static func stateName(_ s: MPMusicPlaybackState) -> String {
        switch s {
        case .playing: return "playing"
        case .paused: return "paused"
        case .stopped: return "stopped"
        case .interrupted: return "interrupted"
        case .seekingForward: return "seekingForward"
        case .seekingBackward: return "seekingBackward"
        @unknown default: return "unknown"
        }
    }
}

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
