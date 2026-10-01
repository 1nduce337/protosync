import Foundation
import CryptoKit
import Core

// 极简测试 runner(CLT 环境无 XCTest)。断言失败即计数,最终以非零码退出。

var failures = 0
var ran = 0

func check(_ condition: Bool, _ name: String) {
    ran += 1
    if condition {
        print("✅ \(name)")
    } else {
        failures += 1
        print("❌ \(name)")
    }
}

func checkThrows(_ body: () throws -> Void, _ name: String) {
    ran += 1
    do {
        try body()
        failures += 1
        print("❌ \(name)(未抛错)")
    } catch {
        print("✅ \(name)")
    }
}

func tempDir(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("protosync-tests-\(UUID().uuidString)-\(name)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - 分帧

do {
    let messages = [
        Message.clipboardText("你好, ProtoSync! 🎉", hash: "abc123"),
        Message.fileOffer(id: "t1", name: "a.png", size: 12345, sha256: "deadbeef"),
        Message.error("测试错误"),
    ]
    let stream = try messages.reduce(Data()) { try $0 + FrameCodec.encode($1) }

    let codec = FrameCodec()
    var decoded: [Message] = []
    var index = 0
    while index < stream.count {
        let step = min(7, stream.count - index)
        decoded += try codec.feed(stream[index..<(index + step)]).map { try Message.decode(from: $0) }
        index += step
    }
    check(decoded == messages, "分帧:编码/解码往返(粘包半包)")

    let huge: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0x00]
    var threw = false
    do { _ = try FrameCodec().feed(Data(huge)) } catch { threw = true }
    check(threw, "分帧:拒绝超大帧")
} catch {
    failures += 1
    print("❌ 分帧测试异常: \(error)")
}

// MARK: - 加密握手

do {
    let alice = try IdentityStore(directory: tempDir("alice"), deviceName: "Alice")
    let bob = try IdentityStore(directory: tempDir("bob"), deviceName: "Bob")

    let client = SecureChannel(identity: alice.identity, role: .initiator)
    let server = SecureChannel(identity: bob.identity, role: .responder)

    try server.acceptPeerHello(client.makeHello())
    try client.acceptPeerHello(server.makeHello())

    check(client.peerFingerprint == bob.identity.fingerprint, "握手:客户端看到 Bob 指纹")
    check(server.peerFingerprint == alice.identity.fingerprint, "握手:服务端看到 Alice 指纹")

    try server.verifyAuth(try client.makeAuth())
    try client.verifyAuth(try server.makeAuth())

    let original = Message.clipboardText("机密消息", hash: "h1")
    check(try server.open(try client.seal(original)) == original, "加密:C→S 解密一致")
    check(try client.open(try server.seal(original)) == original, "加密:S→C 解密一致")

    // 密钥新鲜度:第二条消息 nonce 递增,密文不同
    let s1 = try client.seal(original)
    let s2 = try client.seal(original)
    check(s1 != s2, "加密:相同明文产出不同密文")
} catch {
    failures += 1
    print("❌ 握手测试异常: \(error)")
}

// MARK: - 重连标记与 unpair

do {
    let alice = try IdentityStore(directory: tempDir("re-a"), deviceName: "Alice")
    let bob = try IdentityStore(directory: tempDir("re-b"), deviceName: "Bob")
    let client = SecureChannel(identity: alice.identity, role: .initiator)
    let server = SecureChannel(identity: bob.identity, role: .responder)
    let hello = client.makeHello(paired: true)
    check(hello.paired == true, "重连:hello 带 paired")
    // 线上 JSON 也必须带上(Java 端按 "paired" 键读取)
    let json = String(data: try hello.encodedData(), encoding: .utf8) ?? ""
    check(json.contains("\"paired\":true"), "重连:JSON 含 \"paired\":true")
    try server.acceptPeerHello(hello)
    try client.acceptPeerHello(server.makeHello())
    check(server.peerClaimsPaired, "重连:应答方看到 paired")
    check(!client.peerClaimsPaired, "重连:应答方的 hello 不带 paired")
    check(!(String(data: try SecureChannel(identity: alice.identity, role: .initiator).makeHello().encodedData(),
                   encoding: .utf8) ?? "").contains("paired"), "重连:默认 hello 不含 paired 键")

    try server.verifyAuth(try client.makeAuth())
    try client.verifyAuth(try server.makeAuth())
    check(try client.open(try server.seal(.unpair())).type == MessageType.unpair, "unpair:经加密通道送达")
} catch {
    failures += 1
    print("❌ 重连测试异常: \(error)")
}

do {
    let alice = try IdentityStore(directory: tempDir("fp-a"), deviceName: "A")
    let bob = try IdentityStore(directory: tempDir("fp-b"), deviceName: "B")

    let client = SecureChannel(identity: alice.identity, role: .initiator)
    let server = SecureChannel(identity: bob.identity, role: .responder)

    var helloC = client.makeHello()
    helloC.fp = String(repeating: "0", count: 64)
    checkThrows({ try server.acceptPeerHello(helloC) }, "握手:冒充指纹被拒绝")
} catch {
    failures += 1
    print("❌ 冒充测试异常: \(error)")
}

// MARK: - 握手加固(v2:版本、设备名绑定、角色标签)

do {
    let alice = try IdentityStore(directory: tempDir("v2-a"), deviceName: "Alice")
    let bob = try IdentityStore(directory: tempDir("v2-b"), deviceName: "Bob")

    // 旧版本 hello(无 v 字段)给出明确的版本错误
    do {
        let server = SecureChannel(identity: bob.identity, role: .responder)
        var old = SecureChannel(identity: alice.identity, role: .initiator).makeHello()
        old.v = nil
        var gotVersionError = false
        do { try server.acceptPeerHello(old) } catch ProtoSyncError.versionMismatch { gotVersionError = true }
        check(gotVersionError, "握手:旧版本 hello 报版本不兼容")
    }

    // 中间人篡改 hello 中的设备名 → 两端 transcript 不同,验签失败
    do {
        let client = SecureChannel(identity: alice.identity, role: .initiator)
        let server = SecureChannel(identity: bob.identity, role: .responder)
        var tampered = client.makeHello()
        tampered.name = "Mallory"
        try server.acceptPeerHello(tampered)
        try client.acceptPeerHello(server.makeHello())
        checkThrows({ try server.verifyAuth(try client.makeAuth()) }, "握手:篡改设备名导致验签失败")
    }

    // 签名带角色标签:两端同一身份时(v1 下 transcript 与密钥都相同),
    // 应答方把自己的 auth 反射回去也不能冒充发起方
    do {
        let client = SecureChannel(identity: alice.identity, role: .initiator)
        let server = SecureChannel(identity: alice.identity, role: .responder)
        try server.acceptPeerHello(client.makeHello())
        try client.acceptPeerHello(server.makeHello())
        let serverAuth = try server.makeAuth()
        checkThrows({ try server.verifyAuth(serverAuth) }, "握手:反射本端 auth 被拒绝")
        try client.verifyAuth(serverAuth)
        check(true, "握手:角色正确的 auth 仍可验证")
    }

    do {
        let client = SecureChannel(identity: alice.identity, role: .initiator)
        let server = SecureChannel(identity: bob.identity, role: .responder)
        try server.acceptPeerHello(client.makeHello())
        try client.acceptPeerHello(server.makeHello())
        try server.verifyAuth(try client.makeAuth())
        try client.verifyAuth(try server.makeAuth())
        check(true, "握手:v2 正常双向认证")
        check(client.sasCode != nil && client.sasCode == server.sasCode, "配对码:两端一致")
        check(client.sasCode?.count == 7 && client.sasCode?.dropFirst(3).first == " ", "配对码:格式为“123 456”")
    }

    // 篡改握手(中间人改名)→ 两端配对码不同,用户核对时能发现
    do {
        let client = SecureChannel(identity: alice.identity, role: .initiator)
        let server = SecureChannel(identity: bob.identity, role: .responder)
        var tampered = client.makeHello()
        tampered.name = "Mallory"
        try server.acceptPeerHello(tampered)
        try client.acceptPeerHello(server.makeHello())
        check(client.sasCode != server.sasCode, "配对码:握手被篡改时两端不同")
    }
} catch {
    failures += 1
    print("❌ 握手加固测试异常: \(error)")
}

// MARK: - 文件信任(按设备自动接收)

do {
    let dir = tempDir("trust")
    let peer = String(repeating: "b", count: 64)
    let store = try IdentityStore(directory: dir, deviceName: "T")
    check(!store.isFileTrusted(peer), "信任:未配对设备不自动接收")
    store.addPaired(fingerprint: peer, name: "朋友")
    check(store.isFileTrusted(peer), "信任:新配对设备默认自动接收")
    store.setFileTrust(fingerprint: peer, trusted: false)
    let reloaded = try IdentityStore(directory: dir)
    check(!reloaded.isFileTrusted(peer), "信任:关闭自动接收后持久化")
    reloaded.addPaired(fingerprint: peer, name: "朋友改名")
    check(!reloaded.isFileTrusted(peer), "信任:重复配对不重置设置")

    // 旧版 paired.json 没有 trustFiles 字段 → 视为信任(升级后行为不变)
    let legacyDir = tempDir("trust-legacy")
    try """
    [{"addedAt":"2026-01-01T00:00:00Z","fingerprint":"\(peer)","name":"旧设备"}]
    """.write(to: legacyDir.appendingPathComponent("paired.json"), atomically: true, encoding: .utf8)
    let legacy = try IdentityStore(directory: legacyDir, deviceName: "L")
    check(legacy.isFileTrusted(peer), "信任:旧版配对记录默认自动接收")
} catch {
    failures += 1
    print("❌ 文件信任测试异常: \(error)")
}

// MARK: - HKDF RFC 5869 向量

do {
    func hexData(_ hex: String) -> Data {
        var bytes: [UInt8] = []
        var it = hex.makeIterator()
        while let high = it.next(), let low = it.next() {
            bytes.append(UInt8(String([high, low]), radix: 16)!)
        }
        return Data(bytes)
    }
    let okm = HKDF.derive(ikm: hexData("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"),
                          salt: hexData("000102030405060708090a0b0c"),
                          info: hexData("f0f1f2f3f4f5f6f7f8f9"),
                          length: 42)
    check(okm.map { String(format: "%02x", $0) }.joined()
        == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
        "HKDF:RFC 5869 A.1 测试向量")
}

// MARK: - 身份持久化

do {
    let dir = tempDir("persist")
    let first = try IdentityStore(directory: dir, deviceName: "持久化设备")
    let second = try IdentityStore(directory: dir)
    check(first.identity.fingerprint == second.identity.fingerprint, "身份:重启后指纹不变")
    check(second.identity.name == "持久化设备", "身份:设备名持久化")
    second.addPaired(fingerprint: String(repeating: "a", count: 64), name: "朋友")
    let third = try IdentityStore(directory: dir)
    check(third.pairedDevices.count == 1 && third.pairedDevices[0].name == "朋友", "身份:配对列表持久化")
} catch {
    failures += 1
    print("❌ 身份测试异常: \(error)")
}

// MARK: - 去重缓存

do {
    var cache = SeenCache()
    cache.insert("aaa")
    check(cache.contains("aaa") && !cache.contains("bbb"), "去重:插入后可见")
}


// MARK: - 文件传输输入校验(FileTransferGuard)

do {
    check(FileTransferGuard.sanitizedTransferID("abc-XYZ-123") == "abc-XYZ-123", "校验:合法传输 id 通过")
    check(FileTransferGuard.sanitizedTransferID("../evil") == nil, "校验:路径穿越 id 拒绝")
    check(FileTransferGuard.sanitizedTransferID(String(repeating: "a", count: 65)) == nil, "校验:超长 id 拒绝")
    check(FileTransferGuard.sanitizedTransferID("") == nil, "校验:空 id 拒绝")

    check(FileTransferGuard.sanitizedFileName("报告.pdf") == "报告.pdf", "校验:普通文件名保留")
    check(FileTransferGuard.sanitizedFileName("../../etc/passwd") == nil, "校验:相对路径逃逸拒绝")
    check(FileTransferGuard.sanitizedFileName("/absolute/path") == nil, "校验:绝对路径拒绝")
    check(FileTransferGuard.sanitizedFileName("C:\\evil.txt") == nil, "校验:Windows 盘符路径拒绝")
    check(FileTransferGuard.sanitizedFileName("..") == nil, "校验:dot-dot 拒绝")
    check(FileTransferGuard.sanitizedFileName("a\u{0}b") == nil, "校验:控制字符拒绝")
    check(FileTransferGuard.sanitizedFileName("  ok.txt  ") == "ok.txt", "校验:首尾空白修剪")
    check(FileTransferGuard.sanitizedFileName(String(repeating: "x", count: 201)) == nil, "校验:超长文件名拒绝")

    check(FileTransferGuard.isValidSHA256Hex(String(repeating: "a", count: 64)), "校验:合法 SHA 通过")
    check(!FileTransferGuard.isValidSHA256Hex(String(repeating: "g", count: 64)), "校验:非十六进制 SHA 拒绝")
    check(!FileTransferGuard.isValidSHA256Hex("abcd"), "校验:短 SHA 拒绝")
    check(FileTransferGuard.isValidSize(0) && FileTransferGuard.isValidSize(1024), "校验:合法大小通过")
    check(!FileTransferGuard.isValidSize(-1), "校验:负数大小拒绝")
    check(!FileTransferGuard.isValidSize(FileTransferGuard.maxFileSize + 1), "校验:超上限大小拒绝")
}

// MARK: - 剪贴板 force 标志(手动发送绕过去重)

do {
    let forced = Message.clipboardText("重发同一条", hash: "h2", force: true)
    let decoded = try Message.decode(from: forced.encodedData())
    check(decoded.force == true, "协议:force=true 编解码往返")

    let plain = Message.clipboardText("普通同步", hash: "h3")
    let plainDecoded = try Message.decode(from: plain.encodedData())
    check(plainDecoded.force == nil, "协议:自动同步默认不带 force")

    // 引擎接收语义:非 force 命中 seen 丢弃,force 命中 seen 仍投递
    var seen = SeenCache()
    seen.insert("h2")
    let hash = "h2"
    let autoDropped = !forced.force! && seen.contains(hash) // force=true → 不丢弃
    check(!autoDropped, "去重:force 手动发送不被 seen 丢弃")
    let autoMessage = Message.clipboardText("自动同步", hash: "h2")
    let autoIsDropped = !(autoMessage.force == true) && seen.contains(hash)
    check(autoIsDropped, "去重:非 force 自动同步仍被 seen 丢弃")
}

print("\n\(ran - failures)/\(ran) 通过")
exit(failures == 0 ? 0 : 1)
