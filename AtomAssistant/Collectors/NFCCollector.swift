import Foundation
import CoreNFC

/// 读 NFC 标签：助手提出需求，你打开 App 后弹出系统的读取框，把手机靠近标签。
///
/// 只能读 NDEF 格式的标签（网址、文字、自定义记录等）。这种读取拿不到标签的序列号（UID），
/// 门禁卡、银行卡、交通卡这类加密卡也读不了。需要签名里带 NFC 的 entitlement，
/// 普通安装包没有，请用 AtomAssistant-full.ipa。
struct NFCReadCollector: Collector {
    let kind = DataKind.nfcRead

    func authorize() async -> String? {
        NFCNDEFReaderSession.readingAvailable ? nil : "这台设备不支持 NFC 读取"
    }

    func collect(params: [String: Any]) async throws -> [Sample] {
        let reason = params["reason"] as? String ?? ""
        let messages = try await NFCReader().read(prompt: reason.isEmpty ? "把手机靠近 NFC 标签" : reason)
        guard !messages.isEmpty else { throw CollectError("读到了标签，但里面没有内容") }
        let now = Date()
        let records: [[String: Any]] = messages.flatMap { $0.records.map(Self.describe) }
        let payload: [String: Any] = ["messageCount": messages.count, "records": records]
        return [Sample(key: "nfc-\(Int(now.timeIntervalSince1970 * 1000))", capturedAt: now, payload: payload)]
    }

    /// 把一条 NDEF 记录整理成助手读得懂的样子：能解析出网址、文字的就给文字，其余给类型和一小段原始内容。
    private static func describe(_ r: NFCNDEFPayload) -> [String: Any] {
        var out: [String: Any] = [:]
        switch r.typeNameFormat {
        case .nfcWellKnown: out["format"] = "wellKnown"
        case .media: out["format"] = "media"
        case .absoluteURI: out["format"] = "absoluteURI"
        case .nfcExternal: out["format"] = "external"
        case .empty: out["format"] = "empty"
        default: out["format"] = "other"
        }
        out["type"] = String(data: r.type, encoding: .utf8) ?? r.type.base64EncodedString()
        if !r.identifier.isEmpty { out["identifier"] = String(data: r.identifier, encoding: .utf8) ?? r.identifier.base64EncodedString() }
        if let url = r.wellKnownTypeURIPayload() {
            out["uri"] = url.absoluteString
        } else if case let (text?, locale?) = r.wellKnownTypeTextPayload() {
            out["text"] = text
            out["language"] = locale.identifier
        } else if let text = String(data: r.payload, encoding: .utf8), !text.isEmpty {
            out["text"] = String(text.prefix(2000))
        } else {
            // 二进制内容：只带前 256 字节，免得一个大标签撑爆请求。
            out["payloadBase64"] = r.payload.prefix(256).base64EncodedString()
            out["payloadBytes"] = r.payload.count
        }
        return out
    }
}

/// 一次读取会话的包装：弹出系统读取框，等用户把手机靠近标签。
final class NFCReader: NSObject, NFCNDEFReaderSessionDelegate {
    private var session: NFCNDEFReaderSession?
    private var cont: CheckedContinuation<[NFCNDEFMessage], Error>?
    private var finished = false

    func read(prompt: String) async throws -> [NFCNDEFMessage] {
        guard NFCNDEFReaderSession.readingAvailable else { throw CollectError("这台设备不支持 NFC 读取") }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<[NFCNDEFMessage], Error>) in
            cont = c
            let s = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: true)
            s.alertMessage = prompt
            session = s
            DispatchQueue.main.async { s.begin() }
        }
    }

    private func finish(_ result: Result<[NFCNDEFMessage], Error>) {
        guard !finished else { return }
        finished = true
        let c = cont
        cont = nil
        session = nil
        switch result {
        case .success(let m): c?.resume(returning: m)
        case .failure(let e): c?.resume(throwing: e)
        }
    }

    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        session.alertMessage = "读取成功"
        finish(.success(messages))
    }

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        // 读完第一个标签后系统会主动结束会话并报这个错，那是成功的收尾，前面已经交付了结果。
        let code = (error as? NFCReaderError)?.code
        switch code {
        case .readerSessionInvalidationErrorFirstNDEFTagRead:
            finish(.failure(CollectError("没有读到内容")))
        case .readerSessionInvalidationErrorUserCanceled:
            finish(.failure(CollectError("你取消了读取")))
        case .readerSessionInvalidationErrorSessionTimeout:
            finish(.failure(CollectError("等了太久没有靠近标签，读取超时了")))
        default:
            let text = error.localizedDescription
            // 没有 NFC 的 entitlement 时系统会在这里报缺权限。
            let hint = text.lowercased().contains("entitlement") || text.contains("权限")
                ? "（这个安装包没有 NFC 权限，请换用 AtomAssistant-full.ipa 重新签名安装）" : ""
            finish(.failure(CollectError("读取失败：\(text)\(hint)")))
        }
    }
}
