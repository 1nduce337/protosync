import Foundation
import CryptoKit

/// 简化版 Noise 风格握手(纯 CryptoKit,便于将来移植到其他平台):
///
///   C → S : hello {fpC, nameC, signPubC, dhPubC, ephC}
///   S → C : hello {fpS, nameS, signPubS, dhPubS, ephS}
///   C → S : auth  {sig = Sign_staticC("protosync-auth-initiator" || transcriptHash)}
///   S → C : auth  {sig = Sign_staticS("protosync-auth-responder" || transcriptHash)}
///
/// transcriptHash = SHA256("ProtoSync-v2" || init 的三个公钥 || len32(nameI) || nameI
///                                        || resp 的三个公钥 || len32(nameR) || nameR)
/// (len32 = UTF-8 字节长度,4 字节大端)
/// 会话密钥 = HKDF-256(ss1 || ss2 || ss3, salt: transcriptHash)
///   ss1 = DH(ephI, ephR)   ss2 = DH(ephI, staticR)   ss3 = DH(staticI, ephR)
///
/// 三个共享密钥混合后同时提供前向安全与对静态身份的绑定;对端公钥的指纹必须与
/// hello 中声称的 fp 一致,签名必须能用该公钥验证,否则握手失败。
/// 设备名进入 transcript,中间人无法篡改 hello 里的名字;签名带角色标签,
/// 一端的 auth 不能被反射回去冒充另一个角色。
public final class SecureChannel {
    public enum Role { case initiator, responder }

    public let identity: DeviceIdentity
    public let role: Role
    public private(set) var peerFingerprint: String?
    public private(set) var peerName: String?
    public private(set) var peerSignPub: P256.Signing.PublicKey?
    public private(set) var peerDhPub: P256.KeyAgreement.PublicKey?
    /// 6 位配对码(“123 456”):两端由同一 transcript 推导,配对时让用户核对两块屏幕上的码是否一致。
    /// 中间人会与两端各自形成不同的 transcript,码对不上。
    public private(set) var sasCode: String?

    private var myEph: P256.KeyAgreement.PrivateKey?
    private var transcriptHash: Data?
    private var c2sKey: SymmetricKey?
    private var s2cKey: SymmetricKey?
    private var sendCounter: UInt64 = 0
    private var recvCounter: UInt64 = 0

    public init(identity: DeviceIdentity, role: Role) {
        self.identity = identity
        self.role = role
    }

    // MARK: - 握手

    public func makeHello() -> Message {
        // initiator 在连接就绪时调用;responder 在收到对端 hello(已生成 eph)后调用,
        // 两者都必须复用同一把临时密钥,否则密钥派生会错位。
        if myEph == nil { myEph = P256.KeyAgreement.PrivateKey() }
        return Message.hello(
            fp: identity.fingerprint,
            name: identity.name,
            signPub: identity.signingKey.publicKey.rawRepresentation,
            dhPub: identity.dhKey.publicKey.rawRepresentation,
            eph: myEph!.publicKey.rawRepresentation
        )
    }

    /// 校验对端 hello,派生会话密钥。fp 与公钥不一致时抛错。
    public func acceptPeerHello(_ message: Message) throws {
        // responder 先收到 hello,此时还没有自己的临时密钥,在此生成。
        if myEph == nil { myEph = P256.KeyAgreement.PrivateKey() }
        guard message.v == ProtocolVersion.current else {
            throw ProtoSyncError.versionMismatch(message.v)
        }
        guard let fp = message.fp,
              let name = message.name,
              let signPubB64 = message.signPub, let signPubData = Data(base64Encoded: signPubB64),
              let dhPubB64 = message.dhPub, let dhPubData = Data(base64Encoded: dhPubB64),
              let ephB64 = message.eph, let ephData = Data(base64Encoded: ephB64)
        else { throw ProtoSyncError.badHandshake("hello 字段缺失") }

        guard DeviceIdentity.fingerprint(signPub: signPubData, dhPub: dhPubData) == fp else {
            throw ProtoSyncError.fingerprintMismatch
        }
        guard let signPub = try? P256.Signing.PublicKey(rawRepresentation: signPubData),
              let dhPub = try? P256.KeyAgreement.PublicKey(rawRepresentation: dhPubData),
              let peerEph = try? P256.KeyAgreement.PublicKey(rawRepresentation: ephData),
              let myEph = myEph
        else { throw ProtoSyncError.badHandshake("公钥解析失败") }

        peerFingerprint = fp
        peerName = name
        peerSignPub = signPub
        peerDhPub = dhPub

        let myStaticDh = identity.dhKey
        let me = (sign: identity.signingKey.publicKey.rawRepresentation,
                  dh: identity.dhKey.publicKey.rawRepresentation,
                  eph: myEph.publicKey.rawRepresentation,
                  name: identity.name)
        let peer = (sign: signPubData, dh: dhPubData, eph: ephData, name: name)
        transcriptHash = role == .initiator
            ? Self.transcript(initiator: me, responder: peer)
            : Self.transcript(initiator: peer, responder: me)
        sasCode = Self.sas(transcriptHash!)

        let ss1 = try myEph.sharedSecretFromKeyAgreement(with: peerEph)
        let ss2: SharedSecret
        let ss3: SharedSecret
        switch role {
        case .initiator:
            ss2 = try myEph.sharedSecretFromKeyAgreement(with: dhPub)   // ephI × staticR
            ss3 = try myStaticDh.sharedSecretFromKeyAgreement(with: peerEph) // staticI × ephR
        case .responder:
            ss2 = try myStaticDh.sharedSecretFromKeyAgreement(with: peerEph) // staticR × ephI
            ss3 = try myEph.sharedSecretFromKeyAgreement(with: dhPub)   // ephR × staticI
        }

        var ikm = Data()
        ss1.withUnsafeBytes { ikm.append(contentsOf: $0) }
        ss2.withUnsafeBytes { ikm.append(contentsOf: $0) }
        ss3.withUnsafeBytes { ikm.append(contentsOf: $0) }

        let expanded = HKDF.derive(ikm: ikm, salt: transcriptHash!, info: Data("protosync-keys".utf8), length: 64)
        c2sKey = SymmetricKey(data: expanded.prefix(32))
        s2cKey = SymmetricKey(data: expanded.suffix(32))
    }

    public func makeAuth() throws -> Message {
        guard let transcriptHash = transcriptHash else {
            throw ProtoSyncError.badHandshake("尚未收到对端 hello")
        }
        let sig = try identity.signingKey.signature(for: Self.authPayload(signer: role, transcriptHash: transcriptHash))
        return Message.auth(sig: sig.rawRepresentation)
    }

    /// 验证对端签名。验证通过即本端进入 established 状态。
    public func verifyAuth(_ message: Message) throws {
        guard let sigB64 = message.sig, let sigData = Data(base64Encoded: sigB64),
              let transcriptHash = transcriptHash,
              let peerSignPub = peerSignPub
        else { throw ProtoSyncError.badHandshake("auth 字段缺失") }
        func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
        let peerRole: Role = role == .initiator ? .responder : .initiator
        let payload = Self.authPayload(signer: peerRole, transcriptHash: transcriptHash)
        guard let sig = try? P256.Signing.ECDSASignature(rawRepresentation: sigData),
              peerSignPub.isValidSignature(sig, for: payload)
        else {
            let selfEph = myEph?.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined() ?? "nil"
            PLog.error("ProtoSync: AUTH_VERIFY_FAIL role=\(role == .initiator ? "I" : "R") selfSign=\(hex(identity.signingKey.publicKey.rawRepresentation)) selfDh=\(hex(identity.dhKey.publicKey.rawRepresentation)) selfEph=\(selfEph) peerSign=\(hex(peerSignPub.rawRepresentation)) peerDh=\(hex(peerDhPub?.rawRepresentation ?? Data())) transcript=\(hex(transcriptHash)) sig=\(hex(sigData))")
            throw ProtoSyncError.badSignature
        }
    }

    // MARK: - transcript / 签名载荷(与 Android Crypto.transcript / authPayload 逐字节对齐)

    typealias TranscriptParty = (sign: Data, dh: Data, eph: Data, name: String)

    static func transcript(initiator: TranscriptParty, responder: TranscriptParty) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data("ProtoSync-v2".utf8))
        for party in [initiator, responder] {
            hasher.update(data: party.sign)
            hasher.update(data: party.dh)
            hasher.update(data: party.eph)
            let nameBytes = Data(party.name.utf8)
            var length = UInt32(nameBytes.count).bigEndian
            hasher.update(data: withUnsafeBytes(of: &length) { Data($0) })
            hasher.update(data: nameBytes)
        }
        return Data(hasher.finalize())
    }

    /// 配对码 = SHA256("ProtoSync-SAS" || transcriptHash) 前 4 字节(大端)对 1,000,000 取模,补齐 6 位。
    /// 与 Android Crypto.sas 逐字节对齐;只在本地计算展示,不上线。
    static func sas(_ transcriptHash: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("ProtoSync-SAS".utf8))
        hasher.update(data: transcriptHash)
        let d = Array(hasher.finalize())
        let value = (UInt32(d[0]) << 24 | UInt32(d[1]) << 16 | UInt32(d[2]) << 8 | UInt32(d[3])) % 1_000_000
        let digits = String(value)
        let padded = String(repeating: "0", count: 6 - digits.count) + digits
        return "\(padded.prefix(3)) \(padded.suffix(3))"
    }

    /// 签名载荷 = 角色标签 || transcriptHash。角色标签防止把一端的 auth 反射给它自己。
    static func authPayload(signer: Role, transcriptHash: Data) -> Data {
        var payload = Data((signer == .initiator ? "protosync-auth-initiator" : "protosync-auth-responder").utf8)
        payload.append(transcriptHash)
        return payload
    }

    // MARK: - 加解密

    private var sendKey: SymmetricKey {
        role == .initiator ? c2sKey! : s2cKey!
    }

    private var recvKey: SymmetricKey {
        role == .initiator ? s2cKey! : c2sKey!
    }

    public func seal(_ message: Message) throws -> Data {
        guard c2sKey != nil else { throw ProtoSyncError.notEstablished }
        let plaintext = try message.encodedData()
        let counter = sendCounter
        sendCounter += 1
        let nonce = Self.nonce(counter)
        let sealed = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: nonce)
        var out = Data(capacity: 12 + sealed.ciphertext.count + 16)
        out.append(nonce.withUnsafeBytes { Data($0) })
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    public func open(_ frame: Data) throws -> Message {
        guard c2sKey != nil else { throw ProtoSyncError.notEstablished }
        guard frame.count > 12 + 16 else { throw ProtoSyncError.badHandshake("密文帧过短") }
        let receivedNonce = Data(frame.prefix(12))
        let expectedNonce = Self.nonceData(recvCounter)
        guard receivedNonce == expectedNonce else {
            throw ProtoSyncError.badHandshake("密文 nonce 次序异常")
        }
        let nonce = try ChaChaPoly.Nonce(data: receivedNonce)
        let ctAndTag = frame.suffix(from: 12)
        let box = try ChaChaPoly.SealedBox(nonce: nonce,
                                           ciphertext: Data(ctAndTag.prefix(ctAndTag.count - 16)),
                                           tag: Data(ctAndTag.suffix(16)))
        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(box, using: recvKey)
            recvCounter += 1
        } catch {
            throw ProtoSyncError.badHandshake("解密失败(密钥或计数器错位)")
        }
        return try Message.decode(from: plaintext)
    }

    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        try! ChaChaPoly.Nonce(data: nonceData(counter))
    }

    private static func nonceData(_ counter: UInt64) -> Data {
        var bytes: [UInt8] = Array(repeating: 0, count: 12)
        let be = counter.bigEndian
        withUnsafeBytes(of: be) { bytes.replaceSubrange(4..<12, with: $0) }
        return Data(bytes)
    }
}

/// 手写 HKDF(RFC 5869),避免依赖 CryptoKit 里各系统版本行为不一的 HKDF API。
public enum HKDF {
    public static func derive(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        let prk = HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: salt))
        var okm = Data()
        var t = Data()
        var counter: UInt8 = 1
        while okm.count < length {
            var input = t
            input.append(info)
            input.append(counter)
            let block = HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: prk))
            t = Data(block)
            okm.append(t)
            counter &+= 1
        }
        return okm.prefix(length)
    }
}
