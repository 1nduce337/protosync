import Foundation
import CryptoKit

/// 设备身份:两把静态 P256 密钥(签名用 + ECDH 用)。
/// 指纹 = SHA256(signPub || dhPub) 的 hex。首次运行时生成并持久化到磁盘。
public struct DeviceIdentity {
    public let signingKey: P256.Signing.PrivateKey
    public let dhKey: P256.KeyAgreement.PrivateKey
    public var name: String

    public var fingerprint: String {
        DeviceIdentity.fingerprint(signPub: signingKey.publicKey.rawRepresentation,
                                   dhPub: dhKey.publicKey.rawRepresentation)
    }

    public static func fingerprint(signPub: Data, dhPub: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: signPub)
        hasher.update(data: dhPub)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func shortFingerprint(_ fp: String) -> String {
        String(fp.prefix(8))
    }
}

/// 身份与配对设备的持久化。目录默认 ~/Library/Application Support/ProtoSync/<profile>/
public final class IdentityStore {
    public let directory: URL
    public private(set) var identity: DeviceIdentity
    public private(set) var pairedDevices: [PairedDevice] = []
    private let pairedFile: URL
    private let lock = NSLock()

    public struct PairedDevice: Codable, Equatable {
        public var fingerprint: String
        public var name: String
        public var addedAt: Date
    }

    public init(directory: URL? = nil, deviceName: String? = nil) throws {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProtoSync", isDirectory: true)
        self.directory = base
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        pairedFile = base.appendingPathComponent("paired.json")

        let keyFile = base.appendingPathComponent("device.key")
        let nameFile = base.appendingPathComponent("device.name")

        if let data = try? Data(contentsOf: keyFile), let keys = Self.loadKeys(from: data) {
            identity = DeviceIdentity(signingKey: keys.signing, dhKey: keys.dh, name: "")
        } else {
            // 存储格式:4 字节签名私钥长度 || 签名私钥 raw || ECDH 私钥 raw。
            // 不写死各密钥 rawRepresentation 的长度,避免依赖 CryptoKit 的编码细节。
            let signing = P256.Signing.PrivateKey()
            let dh = P256.KeyAgreement.PrivateKey()
            let blob = Self.packKeys(signing: signing, dh: dh)
            try blob.write(to: keyFile, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
            identity = DeviceIdentity(signingKey: signing, dhKey: dh, name: "")
        }

        if let custom = deviceName {
            identity.name = custom
            try? custom.write(to: nameFile, atomically: true, encoding: .utf8)
        } else if let saved = try? String(contentsOf: nameFile, encoding: .utf8), !saved.isEmpty {
            identity.name = saved
        } else {
            let host: String
            #if os(macOS)
            host = Host.current().localizedName
                ?? ProcessInfo.processInfo.hostName
            #else
            // iOS 等:无 NSHost,用进程主机名兜底(应用层一般会显式传 deviceName)
            host = ProcessInfo.processInfo.hostName
            #endif
            identity.name = host
            try? host.write(to: nameFile, atomically: true, encoding: .utf8)
        }

        if let data = try? Data(contentsOf: pairedFile) {
            let decoder = JSONDecoder()
            // 写入侧用 ISO8601;兼容历史文件(默认 Date 策略)两种都试。
            decoder.dateDecodingStrategy = .iso8601
            if let list = try? decoder.decode([PairedDevice].self, from: data) {
                pairedDevices = list
            } else if let list = try? JSONDecoder().decode([PairedDevice].self, from: data) {
                pairedDevices = list
            }
        }
    }

    public func isPaired(_ fingerprint: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pairedDevices.contains { $0.fingerprint == fingerprint }
    }

    public func pairedDevice(_ fingerprint: String) -> PairedDevice? {
        lock.lock(); defer { lock.unlock() }
        return pairedDevices.first { $0.fingerprint == fingerprint }
    }

    public func addPaired(fingerprint: String, name: String) {
        guard fingerprint != identity.fingerprint else { return } // 不配对自己
        lock.lock()
        if let idx = pairedDevices.firstIndex(where: { $0.fingerprint == fingerprint }) {
            pairedDevices[idx].name = name
        } else {
            pairedDevices.append(PairedDevice(fingerprint: fingerprint, name: name, addedAt: Date()))
        }
        let snapshot = pairedDevices
        lock.unlock()
        persistPaired(snapshot)
    }

    public func removePaired(fingerprint: String) {
        lock.lock()
        pairedDevices.removeAll { $0.fingerprint == fingerprint }
        let snapshot = pairedDevices
        lock.unlock()
        persistPaired(snapshot)
    }

    /// 修改设备名并持久化(新连接的 hello 会带上新名字)。
    public func renameDevice(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        identity.name = trimmed
        let nameFile = directory.appendingPathComponent("device.name")
        try? trimmed.write(to: nameFile, atomically: true, encoding: .utf8)
    }

    private func persistPaired(_ list: [PairedDevice]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(list) {
            try? data.write(to: pairedFile, options: [.atomic])
        }
    }

    // MARK: - 密钥文件格式

    private static func packKeys(signing: P256.Signing.PrivateKey, dh: P256.KeyAgreement.PrivateKey) -> Data {
        let signRaw = signing.rawRepresentation
        let dhRaw = dh.rawRepresentation
        var blob = Data(capacity: 4 + signRaw.count + dhRaw.count)
        var count = UInt32(signRaw.count).bigEndian
        withUnsafeBytes(of: &count) { blob.append(contentsOf: $0) }
        blob.append(signRaw)
        blob.append(dhRaw)
        return blob
    }

    private static func loadKeys(from data: Data) -> (signing: P256.Signing.PrivateKey, dh: P256.KeyAgreement.PrivateKey)? {
        guard data.count > 4 else { return nil }
        let count = Int(data.prefix(4).reduce(0) { ($0 << 8) | Int($1) })
        guard count > 0, count < data.count - 4 else { return nil }
        let signRaw = data.subdata(in: 4..<(4 + count))
        let dhRaw = data.subdata(in: (4 + count)..<data.count)
        guard let signing = try? P256.Signing.PrivateKey(rawRepresentation: signRaw),
              let dh = try? P256.KeyAgreement.PrivateKey(rawRepresentation: dhRaw)
        else { return nil }
        return (signing, dh)
    }
}
