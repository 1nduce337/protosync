import Foundation

// 线协议:每帧 = 4 字节大端长度 + JSON 消息体。
// 建立加密通道之前,hello / auth 两类握手帧以明文传输;之后所有帧经 SecureChannel 加密
// (帧体 = 12 字节随机化计数 nonce + ChaChaPoly 密文)。

public enum MessageType {
    public static let hello = "hello"
    public static let auth = "auth"
    public static let clipboard = "clipboard"
    public static let fileOffer = "file_offer"
    public static let fileChunk = "file_chunk"
    public static let fileDone = "file_done"
    public static let fileAck = "file_ack"
    public static let error = "error"
    public static let ping = "ping"
}

public struct Message: Codable, Equatable {
    public var type: String

    // hello / auth
    public var fp: String?        // 对端完整指纹 (hex)
    public var name: String?      // 设备名
    public var signPub: String?   // 静态签名公钥 raw (base64)
    public var dhPub: String?     // 静态 ECDH 公钥 raw (base64)
    public var eph: String?       // 临时 ECDH 公钥 raw (base64)
    public var sig: String?       // auth: 对 transcriptHash 的静态签名 (base64)

    // file
    public var id: String?        // 传输会话 id
    public var fileName: String?
    public var size: Int64?
    public var sha256: String?
    public var index: Int?
    public var accept: Bool?
    public var done: Bool?

    // clipboard
    public var kind: String?      // "text" | "image"
    public var data: String?      // base64 (image) 或原文 (text)
    public var hash: String?      // 内容 sha256 (hex)
    public var force: Bool?       // 手动发送:true = 接收端跳过去重检查(用户明确意图)

    public var error: String?

    public init() { self.type = "" }

    public static func hello(fp: String, name: String, signPub: Data, dhPub: Data, eph: Data) -> Message {
        Message(type: MessageType.hello, fp: fp, name: name,
                signPub: signPub.base64EncodedString(),
                dhPub: dhPub.base64EncodedString(),
                eph: eph.base64EncodedString())
    }

    public static func auth(sig: Data) -> Message {
        var m = Message(type: MessageType.auth)
        m.sig = sig.base64EncodedString()
        return m
    }

    public static func clipboardText(_ text: String, hash: String, force: Bool = false) -> Message {
        Message(type: MessageType.clipboard, kind: "text", data: text, hash: hash, force: force ? true : nil)
    }

    public static func clipboardImage(_ png: Data, hash: String) -> Message {
        Message(type: MessageType.clipboard, kind: "image",
                data: png.base64EncodedString(), hash: hash)
    }

    public static func fileOffer(id: String, name: String, size: Int64, sha256: String) -> Message {
        Message(type: MessageType.fileOffer, id: id, fileName: name, size: size, sha256: sha256)
    }

    public static func fileChunk(id: String, index: Int, data: Data) -> Message {
        Message(type: MessageType.fileChunk, id: id, index: index,
                data: data.base64EncodedString())
    }

    public static func fileDone(id: String) -> Message {
        Message(type: MessageType.fileDone, id: id)
    }

    public static func fileAck(id: String, accept: Bool, done: Bool) -> Message {
        Message(type: MessageType.fileAck, id: id, accept: accept, done: done)
    }

    public static func error(_ text: String) -> Message {
        Message(type: MessageType.error, error: text)
    }

    public init(type: String, fp: String? = nil, name: String? = nil,
                signPub: String? = nil, dhPub: String? = nil, eph: String? = nil, sig: String? = nil,
                id: String? = nil, fileName: String? = nil, size: Int64? = nil, sha256: String? = nil,
                index: Int? = nil, accept: Bool? = nil, done: Bool? = nil,
                kind: String? = nil, data: String? = nil, hash: String? = nil,
                force: Bool? = nil,
                error: String? = nil) {
        self.type = type
        self.fp = fp
        self.name = name
        self.signPub = signPub
        self.dhPub = dhPub
        self.eph = eph
        self.sig = sig
        self.id = id
        self.fileName = fileName
        self.size = size
        self.sha256 = sha256
        self.index = index
        self.accept = accept
        self.done = done
        self.kind = kind
        self.data = data
        self.hash = hash
        self.force = force
        self.error = error
    }

    public func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> Message {
        try JSONDecoder().decode(Message.self, from: data)
    }
}

/// TCP 流分帧:4 字节大端长度 + 载荷。
/// 握手阶段载荷是明文 JSON 消息;建立加密后载荷是 nonce+密文,交给 SecureChannel 解密。
public final class FrameCodec {
    public static let maxFrameSize = 64 * 1024 * 1024
    private var buffer: [UInt8] = []

    public init() {}

    /// 喂入字节,返回所有已完整解析的帧载荷。用 [UInt8] 做缓冲,避免 Data 切片索引陷阱。
    public func feed(_ data: Data) throws -> [Data] {
        buffer.append(contentsOf: [UInt8](data))
        var frames: [Data] = []
        while true {
            guard buffer.count >= 4 else { break }
            let length = (UInt64(buffer[0]) << 24) | (UInt64(buffer[1]) << 16)
                       | (UInt64(buffer[2]) << 8) | UInt64(buffer[3])
            guard length <= UInt64(FrameCodec.maxFrameSize) else {
                throw ProtoSyncError.frameTooLarge(length)
            }
            guard buffer.count >= 4 + Int(length) else { break }
            frames.append(Data(buffer[4..<(4 + Int(length))]))
            buffer.removeFirst(4 + Int(length))
        }
        return frames
    }

    public static func encode(_ message: Message) throws -> Data {
        let body = try message.encodedData()
        return withLengthPrefix(body)
    }

    public static func wrap(_ sealed: Data) -> Data {
        withLengthPrefix(sealed)
    }

    private static func withLengthPrefix(_ body: Data) -> Data {
        var frame = Data(capacity: 4 + body.count)
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(body)
        return frame
    }
}

public enum ProtoSyncError: LocalizedError {
    case frameTooLarge(UInt64)
    case unexpectedMessage(String)
    case fingerprintMismatch
    case badSignature
    case badHandshake(String)
    case notEstablished
    case cryptoFailure(String)

    public var errorDescription: String? {
        switch self {
        case .frameTooLarge(let n): return "帧过大: \(n)"
        case .unexpectedMessage(let t): return "意外消息类型: \(t)"
        case .fingerprintMismatch: return "指纹与公钥不匹配"
        case .badSignature: return "签名验证失败"
        case .badHandshake(let why): return "握手失败: \(why)"
        case .notEstablished: return "加密通道尚未建立"
        case .cryptoFailure(let why): return "加密操作失败: \(why)"
        }
    }
}
