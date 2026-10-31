import Foundation

enum APIError: LocalizedError {
    case unauthorized
    case server(Int, String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "设备令牌已失效，请在后台重新添加设备并配对"
        case .server(let code, let msg): return "服务器返回 \(code)：\(msg)"
        case .transport(let msg): return "连不上服务器：\(msg)"
        }
    }
}

/// 设备接口客户端，对应服务端 internal/device/http.go。
struct APIClient {
    let base: URL
    let token: String?

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    fileprivate func request(_ method: String, _ path: String, body: Data? = nil, prefix: String = "api/device/v1/", contentType: String = "application/json") async throws -> Data {
        guard let url = URL(string: prefix + path, relativeTo: base) else {
            throw APIError.transport("地址不对")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let token { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = body
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await Self.session.data(for: req)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw APIError.transport("没有响应") }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401 where token != nil:
            throw APIError.unauthorized
        default:
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw APIError.server(http.statusCode, obj?["error"] as? String ?? "未知错误")
        }
    }

    // MARK: 配对

    struct PairResult: Decodable {
        let deviceID: String
        let name: String
        let token: String
        enum CodingKeys: String, CodingKey { case deviceID = "device_id", name, token }
    }

    static func pair(base: URL, code: String, model: String, os: String) async throws -> PairResult {
        let body = try JSONSerialization.data(withJSONObject: ["code": code, "model": model, "os": os])
        let data = try await APIClient(base: base, token: nil).request("POST", "pair", body: body)
        return try JSONDecoder().decode(PairResult.self, from: data)
    }

    // MARK: 日常

    /// 确认令牌还有效。
    func me() async throws {
        _ = try await request("GET", "me")
    }

    /// 拉取等你处理的授权需求，同时拿到后台给这台手机设的上报间隔（分钟）。
    func pendingRequests() async throws -> (requests: [PendingRequest], syncMinutes: Int?) {
        let data = try await request("GET", "requests")
        struct Resp: Decodable {
            let requests: [PendingRequest]
            let syncMinutes: Int?
            enum CodingKeys: String, CodingKey { case requests, syncMinutes = "sync_minutes" }
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            if let date = JSON.parseDate(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "日期格式不对：\(s)"))
        }
        let r = try dec.decode(Resp.self, from: data)
        return (r.requests, r.syncMinutes)
    }

    /// 上报一批同一种类的数据，返回服务端实际新增的条数。
    func upload(kind: String, items: [QueuedItem]) async throws -> Int {
        try await send("data", kind: kind, items: items)
    }

    func fulfil(requestID: String, kind: String, items: [QueuedItem]) async throws -> Int {
        try await send("requests/\(requestID)/fulfil", kind: kind, items: items)
    }

    /// 把用户说的话（可带一张已压缩的截屏）交给助手，答复由服务器通过消息源发回。
    func ask(text: String, screenshot: Data?, mime: String) async throws {
        var obj: [String: Any] = ["text": text]
        if let screenshot {
            obj["screenshot_base64"] = screenshot.base64EncodedString()
            obj["screenshot_mime"] = mime
        }
        _ = try await request("POST", "ask", body: try JSONSerialization.data(withJSONObject: obj))
    }

    func decline(requestID: String) async throws {
        _ = try await request("POST", "requests/\(requestID)/decline", body: Data("{}".utf8))
    }

    private func send(_ path: String, kind: String, items: [QueuedItem]) async throws -> Int {
        // payload 已经是序列化好的 JSON，直接拼进去，不再解码重编。
        var out = Data("{\"kind\":".utf8)
        out.append(try JSONSerialization.data(withJSONObject: kind, options: [.fragmentsAllowed]))
        out.append(Data(",\"items\":[".utf8))
        for (i, it) in items.enumerated() {
            if i > 0 { out.append(Data(",".utf8)) }
            out.append(Data("{\"key\":".utf8))
            out.append(try JSONSerialization.data(withJSONObject: it.key, options: [.fragmentsAllowed]))
            out.append(Data(",\"captured_at\":\"\(JSON.iso.string(from: it.capturedAt))\",\"payload\":".utf8))
            out.append(it.payload)
            out.append(Data("}".utf8))
        }
        out.append(Data("]}".utf8))
        let data = try await request("POST", path, body: out)
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["added"] as? Int ?? 0
    }
}

extension APIClient {
    /// 手机管理接口（/api/app/v1/）：需要后台给这台手机打开了「允许管理后台」。
    func appRequest(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        try await request(method, path, body: body, prefix: "api/app/v1/")
    }

    /// 上传文件到工作区（multipart）。
    func appUpload(body: Data, boundary: String) async throws -> Data {
        try await request("POST", "upload", body: body, prefix: "api/app/v1/", contentType: "multipart/form-data; boundary=\(boundary)")
    }
}
