import Foundation
import AVFoundation
import CoreLocation

/// 让 App 留在后台继续同步。自签名不受 App Store 审核限制，但 iOS 运行时的限制仍然在：
///  - 静音音频：循环播放一段静音，系统把 App 当成「正在播放」，不会挂起它。会多耗一点电；
///    被别的音频打断后要自己恢复；内存紧张时系统仍可能杀掉它。
///  - 显著位置变化：移动约 500 米时系统会唤醒（甚至重新拉起）App。只用它当「叫醒信号」，
///    唤醒后同步一次，不上传位置。需要「始终」定位权限和后台 App 刷新。
///  用户手动划掉 App 之后，系统基本不会再拉起它，这一点绕不开。
final class BackgroundKeeper: NSObject, CLLocationManagerDelegate {
    static let shared = BackgroundKeeper()

    private var player: AVAudioPlayer?
    private var observing = false
    private var manager: CLLocationManager?

    var audioRunning: Bool { player?.isPlaying ?? false }

    // MARK: 静音音频

    /// 开始后台保活。失败返回原因。
    func startAudio() -> String? {
        do {
            let session = AVAudioSession.sharedInstance()
            // mixWithOthers：不打断、不压低你正在听的音乐和视频。
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let p = try AVAudioPlayer(data: Self.silentWAV())
            p.numberOfLoops = -1
            p.volume = 1
            guard p.prepareToPlay(), p.play() else { return "系统没有让静音播放起来，可能被别的音频占用了" }
            player = p
            observe()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func stopAudio() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func observe() {
        guard !observing else { return }
        observing = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            // 电话、闹钟这类打断结束后，自己接着放。
            try? AVAudioSession.sharedInstance().setActive(true)
            self?.player?.play()
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            // 系统的音频服务重启了，之前的播放器作废，重建。
            guard let self, self.player != nil else { return }
            self.player = nil
            _ = self.startAudio()
        }
    }

    /// 一秒钟的静音 WAV（8kHz、16 位、单声道），在内存里拼出来，不带任何资源文件。
    static func silentWAV() -> Data {
        let rate = 8000
        let dataSize = rate * 2
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(Data("RIFF".utf8)); u32(UInt32(36 + dataSize)); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(UInt32(dataSize)); d.append(Data(count: dataSize))
        return d
    }

    // MARK: 显著位置变化唤醒

    /// 现在的定位授权，设置页用它提示「还没给始终允许」。
    var wakeAuthorization: CLAuthorizationStatus { CLLocationManager().authorizationStatus }

    @MainActor
    func startWake() {
        let m = manager ?? CLLocationManager()
        m.delegate = self
        manager = m
        // 要「始终」才能在后台、甚至被杀后收到。先申请，用户在系统弹窗里选。
        if m.authorizationStatus != .authorizedAlways {
            m.requestAlwaysAuthorization()
        }
        m.allowsBackgroundLocationUpdates = true
        m.startMonitoringSignificantLocationChanges()
    }

    @MainActor
    func stopWake() {
        manager?.stopMonitoringSignificantLocationChanges()
        manager?.allowsBackgroundLocationUpdates = false
        manager = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // 只拿它当叫醒信号：同步一次，位置本身不读、不传。
        Task { @MainActor in
            AppModel.shared.log("位置唤醒：移动了一段距离，同步一次")
            await AppModel.shared.syncNow()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in AppModel.shared.log("位置唤醒出错：\(error.localizedDescription)", .warn) }
    }
}
