import Foundation
import Network
import Darwin

/// 扫描当前 Wi-Fi 局域网里的设备：用 Bonjour 看谁在广播服务，再对本网段逐个地址试几个常见端口。
/// 第一次会弹出「本地网络」权限框。只做 TCP 连接试探，不发任何数据，不做漏洞探测。
struct NetworkScanCollector: Collector {
    let kind = DataKind.networkScan

    /// 常见端口：网页、加密网页、SSH、文件共享、AirPlay、iPhone 同步、备用网页。
    static let ports: [UInt16] = [80, 443, 22, 445, 7000, 62078, 8080]

    /// 要找的 Bonjour 服务类型。Info.plist 里的 NSBonjourServices 必须和这里一致。
    static let bonjourTypes = [
        "_http._tcp", "_https._tcp", "_airplay._tcp", "_raop._tcp", "_hap._tcp", "_ipp._tcp",
        "_printer._tcp", "_smb._tcp", "_ssh._tcp", "_googlecast._tcp", "_companion-link._tcp", "_device-info._tcp",
    ]

    func authorize() async -> String? { nil }

    func collect(params: [String: Any]) async throws -> [Sample] {
        let seconds = min(max((params["seconds"] as? Double) ?? 10, 5), 40)
        guard let me = Self.wifiIPv4() else { throw CollectError("没有连接 Wi-Fi，局域网扫描只能在 Wi-Fi 下做") }
        let started = Date()
        let deadline = started.addingTimeInterval(seconds)

        // 1. Bonjour：一边浏览，一边做 2。
        let browsers = Self.startBrowsing()
        // 2. 本网段（按 /24 算，掩码更大也只扫自己所在的 /24）逐个试端口。
        let prefix = me.ip.split(separator: ".").prefix(3).joined(separator: ".")
        let hosts = await Self.sweep(prefix: prefix, selfIP: me.ip, deadline: deadline)
        // 留够时间让 Bonjour 的结果到齐。
        let wait = deadline.timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        let (services, browseError) = browsers.finish()

        var payload: [String: Any] = [
            "localIP": me.ip, "subnet": "\(prefix).0/24", "seconds": seconds,
            "hostCount": hosts.count, "hosts": hosts, "bonjourCount": services.count, "bonjour": services,
        ]
        if hosts.isEmpty && services.isEmpty {
            payload["note"] = browseError ?? "没有发现任何设备。如果确定网络里有设备，多半是「本地网络」权限没给：设置 → 隐私与安全性 → 本地网络"
        }
        let now = Date()
        return [Sample(key: "lan-\(Int(now.timeIntervalSince1970 * 1000))", capturedAt: now, payload: payload)]
    }

    // MARK: 本机地址

    /// Wi-Fi（en0）的 IPv4 地址。
    static func wifiIPv4() -> (ip: String, mask: String)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cur {
            let ifa = p.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               String(cString: ifa.ifa_name) == "en0",
               let ip = numeric(addr), let m = ifa.ifa_netmask, let mask = numeric(m) {
                return (ip, mask)
            }
            cur = ifa.ifa_next
        }
        return nil
    }

    private static func numeric(_ sa: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: host)
    }

    // MARK: 端口试探

    private enum Probe { case open, refused, none }

    private static func probe(host: String, port: UInt16) async -> Probe {
        guard let p = NWEndpoint.Port(rawValue: port) else { return .none }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        let result: Probe = await callbackWithTimeout(0.7, fallback: Probe.none) { done in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    done(.open)
                case .failed(let e), .waiting(let e):
                    // 拒绝连接说明这个地址上有设备，只是这个端口没开。
                    if case .posix(let code) = e, code == .ECONNREFUSED { done(.refused) } else { done(.none) }
                default:
                    break
                }
            }
            conn.start(queue: DispatchQueue.global(qos: .utility))
        }
        conn.cancel()
        return result
    }

    /// 并发试探 prefix.1 到 prefix.254，同时最多 60 个连接在飞。
    private static func sweep(prefix: String, selfIP: String, deadline: Date) async -> [[String: Any]] {
        var alive: [String: (open: [Int], refused: Bool)] = [:]
        let targets = (1...254).map { "\(prefix).\($0)" }.filter { $0 != selfIP }
        await withTaskGroup(of: (String, UInt16, Probe).self) { group in
            var inflight = 0
            func add(_ host: String, _ port: UInt16) {
                group.addTask { (host, port, await probe(host: host, port: port)) }
                inflight += 1
            }
            var queue: [(String, UInt16)] = []
            for h in targets { for p in ports { queue.append((h, p)) } }
            var idx = 0
            while idx < queue.count && inflight < 60 {
                add(queue[idx].0, queue[idx].1); idx += 1
            }
            while let (host, port, r) = await group.next() {
                inflight -= 1
                switch r {
                case .open: alive[host, default: ([], false)].open.append(Int(port))
                case .refused: alive[host, default: ([], false)].refused = true
                case .none: break
                }
                if idx < queue.count && Date() < deadline {
                    add(queue[idx].0, queue[idx].1); idx += 1
                }
            }
        }
        func order(_ ip: String) -> Int { Int(ip.split(separator: ".").last ?? "0") ?? 0 }
        return alive.keys.sorted { order($0) < order($1) }.map { ip in
            let v = alive[ip]!
            var row: [String: Any] = ["ip": ip, "openPorts": v.open.sorted()]
            if v.open.isEmpty { row["note"] = "有设备在线，但试的这几个端口都没开" }
            return row
        }
    }

    // MARK: Bonjour

    private final class Browsers {
        private var list: [NWBrowser] = []
        private let lock = NSLock()
        private var found: [String: [String: Any]] = [:]
        private var error: String?

        func add(_ type: String) {
            let b = NWBrowser(for: .bonjour(type: type, domain: nil), using: NWParameters())
            b.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let e), .waiting(let e):
                    self?.lock.lock(); self?.error = "Bonjour 浏览出错：\(e)（多半是「本地网络」权限没给）"; self?.lock.unlock()
                default: break
                }
            }
            b.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                for r in results {
                    if case let .service(name, t, domain, _) = r.endpoint {
                        self.found["\(name)|\(t)|\(domain)"] = ["name": name, "type": t]
                    }
                }
            }
            b.start(queue: DispatchQueue.global(qos: .utility))
            list.append(b)
        }

        func finish() -> ([[String: Any]], String?) {
            list.forEach { $0.cancel() }
            lock.lock(); defer { lock.unlock() }
            let rows = found.values.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
            return (rows, error)
        }
    }

    private static func startBrowsing() -> Browsers {
        let b = Browsers()
        for t in bonjourTypes { b.add(t) }
        return b
    }
}
