import Foundation

/// 落在「Application Support/AtomAssistant」下的小文件：上传队列、活动日志、每种数据最近一次的内容。
/// 用文件而不是 UserDefaults：队列可能不小，而且后台任务和前台都要读写，文件更省心。
enum Persistence {
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("AtomAssistant", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(type, from: data)
    }

    /// 写失败返回错误文字，由调用方决定怎么让用户看到。
    @discardableResult
    static func save<T: Encodable>(_ value: T, to name: String) -> String? {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        do {
            try enc.encode(value).write(to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func saveRaw(_ data: Data, to name: String) {
        try? data.write(to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func loadRaw(_ name: String) -> Data? { try? Data(contentsOf: url(name)) }

    static func remove(_ name: String) { try? FileManager.default.removeItem(at: url(name)) }

    static func removeAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files { try? FileManager.default.removeItem(at: f) }
    }
}

/// 简单的设置项，存在 UserDefaults 里。
enum Defaults {
    private static let d = UserDefaults.standard

    static var serverURL: String? {
        get { d.string(forKey: "serverURL") }
        set { d.set(newValue, forKey: "serverURL") }
    }
    static var deviceName: String? {
        get { d.string(forKey: "deviceName") }
        set { d.set(newValue, forKey: "deviceName") }
    }
    /// 勾选了持续上报的种类编号。
    static var enabledKinds: Set<String> {
        get { Set(d.stringArray(forKey: "enabledKinds") ?? []) }
        set { d.set(Array(newValue), forKey: "enabledKinds") }
    }
    /// 每种数据最近一次成功上传的时间。
    static var lastUpload: [String: Double] {
        get { d.dictionary(forKey: "lastUpload") as? [String: Double] ?? [:] }
        set { d.set(newValue, forKey: "lastUpload") }
    }
    /// 每种数据累计上传的条数。
    static var uploadCount: [String: Int] {
        get { d.dictionary(forKey: "uploadCount") as? [String: Int] ?? [:] }
        set { d.set(newValue, forKey: "uploadCount") }
    }
    /// 后台保活（静音音频）和位置唤醒的开关。
    static var keepAlive: Bool {
        get { d.bool(forKey: "keepAlive") }
        set { d.set(newValue, forKey: "keepAlive") }
    }
    static var wakeOnMove: Bool {
        get { d.bool(forKey: "wakeOnMove") }
        set { d.set(newValue, forKey: "wakeOnMove") }
    }
    /// 后台里给这台手机设的上报间隔（分钟），每次同步时从服务器更新。
    static var syncMinutes: Int {
        get { d.integer(forKey: "syncMinutes") > 0 ? d.integer(forKey: "syncMinutes") : 20 }
        set { d.set(newValue, forKey: "syncMinutes") }
    }
    static var lastSync: Date? {
        get { d.object(forKey: "lastSync") as? Date }
        set { d.set(newValue, forKey: "lastSync") }
    }

    static func clearAll() {
        for k in ["serverURL", "deviceName", "enabledKinds", "lastUpload", "uploadCount", "lastSync", "keepAlive", "wakeOnMove", "syncMinutes"] {
            d.removeObject(forKey: k)
        }
    }
}
