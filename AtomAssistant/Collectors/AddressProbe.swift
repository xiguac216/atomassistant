import Foundation
import Contacts

/// 地址探测：看能不能从通讯录里读到「家」「学校」「单位」的地址。
///
/// 只报数量，不读内容、不显示、不上传地址本身——这是为了判断「这条路走不走得通」。
///
/// 已知的限制（Apple 官方文档与论坛确认）：
///  - 地图（Apple Maps）里设的家、单位没有任何公开接口可读；
///  - iOS 上没有「我的名片」接口，`unifiedMeContact` 只在 macOS 上有，所以 App 分不出哪张名片是你自己的。
/// 所以这里统计的是：整个通讯录里，带「家 / 学校 / 单位」标签的地址各有几张名片。
struct AddressProbeResult {
    var lines: [String]
}

enum AddressProbe {
    static func run() async -> AddressProbeResult {
        var lines = [
            "地图里的家与学校：没有公开接口，读不到。",
            "我的名片：iOS 没有读取接口，App 分不出哪张是你自己的名片。",
        ]
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            let ok = (try? await store.requestAccess(for: .contacts)) ?? false
            if !ok { lines.append("通讯录权限：被拒绝，没法继续统计。"); return .init(lines: lines) }
        } else if status != .authorized {
            lines.append("通讯录权限：没有（\(status.rawValue)），请到 设置 → 隐私与安全性 → 通讯录 允许原子助手。")
            return .init(lines: lines)
        }

        var total = 0, withAddress = 0, home = 0, work = 0, school = 0, other = 0
        let request = CNContactFetchRequest(keysToFetch: [CNContactPostalAddressesKey as CNKeyDescriptor])
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                total += 1
                guard !contact.postalAddresses.isEmpty else { return }
                withAddress += 1
                var seen = Set<String>()
                for a in contact.postalAddresses {
                    let label = (a.label ?? "").lowercased()
                    let kind: String
                    if label == CNLabelHome.lowercased() || label.contains("home") || label.contains("家") { kind = "home" }
                    else if label == CNLabelWork.lowercased() || label.contains("work") || label.contains("单位") || label.contains("公司") { kind = "work" }
                    else if label.contains("school") || label.contains("学校") { kind = "school" }
                    else { kind = "other" }
                    seen.insert(kind)
                }
                if seen.contains("home") { home += 1 }
                if seen.contains("work") { work += 1 }
                if seen.contains("school") { school += 1 }
                if seen.contains("other") { other += 1 }
            }
        } catch {
            lines.append("读取通讯录失败：\(error.localizedDescription)")
            return .init(lines: lines)
        }
        lines.append("通讯录里共 \(total) 张名片，其中 \(withAddress) 张有地址。")
        lines.append("带「家」标签的：\(home) 张；「学校」：\(school) 张；「单位」：\(work) 张；其他标签：\(other) 张。")
        lines.append(withAddress == 0 ? "结论：通讯录里没有任何带地址的名片，可以先把家和学校地址写进你自己的名片。" : "结论：通讯录里读得到地址。要用的话，需要告诉我哪张名片是你自己的（按名字找）。")
        return .init(lines: lines)
    }
}
