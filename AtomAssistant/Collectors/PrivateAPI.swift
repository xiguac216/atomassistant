import Foundation
import UIKit

/// 私有接口。实测在这台手机上能用的只有 MobileGestalt 的一部分键；
/// 其余（电池详情、已安装应用、正在播放等）被系统拦了，已经删掉。
///
/// 没有头文件，全靠 dlopen / dlsym / ObjC 运行时在运行期找；找不到、没权限、返回空都不是错误，
/// 只是这台手机上拿不到——「能力探测」页会把每一项实测的结果列出来。
///
/// 写法上的两条纪律：
///  1. 凡是对不确定存在的对象调 value(forKey:)，先 responds(to:)——键不存在会抛 ObjC 异常，Swift 接不住，App 直接闪退。
///  2. 凡是系统回调式的私有接口，都套超时：没权限时它们常常是不回调，而不是报错。
enum PrivateAPI {
    struct Outcome<T> {
        var value: T?
        var error: String?
    }

    // MARK: MobileGestalt（设备信息的底层来源）

    private typealias MGCopyAnswerFn = @convention(c) (UnsafeRawPointer) -> UnsafeMutableRawPointer?

    /// 只列实测能返回内容的键。序列号、UDID、IMEI、MAC 在这台手机上都被系统拦了，不再去读。
    static let gestaltKeys = [
        "ProductType", "HWModelStr", "ModelNumber", "RegionInfo", "BuildVersion", "CPUArchitecture",
        "MarketingProductName", "DeviceColor", "HasBaseband",
        "main-screen-width", "main-screen-height", "main-screen-scale",
    ]

    static func gestalt(_ keys: [String] = gestaltKeys) -> Outcome<[String: Any]> {
        guard let h = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW) else { return .init(value: nil, error: "dlopen 失败") }
        guard let sym = dlsym(h, "MGCopyAnswer") else { return .init(value: nil, error: "找不到 MGCopyAnswer") }
        let fn = unsafeBitCast(sym, to: MGCopyAnswerFn.self)
        var out: [String: Any] = [:]
        for k in keys {
            let key = k as CFString
            guard let raw = fn(Unmanaged.passUnretained(key).toOpaque()) else { continue }
            let obj = Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()
            // 没权限时有的键返回空串，不算拿到。
            if let s = obj as? String, s.isEmpty { continue }
            out[k] = JSON.clean(obj)
        }
        return .init(value: out.isEmpty ? nil : out, error: out.isEmpty ? "所有键都返回空（被系统拦了）" : nil)
    }
}
