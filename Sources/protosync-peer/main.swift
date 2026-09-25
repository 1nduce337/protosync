import Foundation
import Core

// 无头测试对端:与菜单栏 App 用同一套 Core,可在单机上开两个进程演示全流程。
//
// 用法:
//   protosync-peer --name 对端名 [--profile 目录名] [--auto-pair]
//                  [--send-text "内容"] [--send-file 路径] [--no-watch]

let args = Array(CommandLine.arguments.dropFirst())

// 重定向到文件时 print 是全缓冲,联调时看不到日志;改为行缓冲。
setvbuf(stdout, nil, _IOLBF, 8192)

func argValue(_ flag: String) -> String? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}
let hasFlag: (String) -> Bool = { args.contains($0) }

let name = argValue("--name") ?? "peer-\(Int.random(in: 100...999))"
let profile = argValue("--profile") ?? "peer"
let autoPair = hasFlag("--auto-pair")
let watchClipboard = !hasFlag("--no-watch")
let sendText = argValue("--send-text")
let sendFile = argValue("--send-file")
let printFp = hasFlag("--print-fp")

let home = FileManager.default.homeDirectoryForCurrentUser
let supportDir = home.appendingPathComponent("Library/Application Support/ProtoSync/\(profile)")
let inboxDir = home.appendingPathComponent("Downloads/ProtoSync-\(profile)")

// --print-fp:只输出该 profile 的指纹后退出(用于跨进程预配对)。
if printFp {
    let s = try IdentityStore(directory: supportDir)
    print(s.identity.fingerprint)
    exit(0)
}

let store: IdentityStore
do {
    store = try IdentityStore(directory: supportDir, deviceName: name)
} catch {
    fputs("初始化身份失败: \(error)\n", stderr)
    exit(1)
}

let engine: SyncEngine
do {
    engine = try SyncEngine(store: store, inboxDirectory: inboxDir)
} catch {
    fputs("初始化引擎失败: \(error)\n", stderr)
    exit(1)
}

func log(_ line: String) {
    let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    print("[\(stamp)] \(line)")
}

final class Delegate: SyncEngine.Delegate {
    let engineRef: SyncEngine
    let autoPair: Bool
    var pendingSends: [() -> Void] = []

    init(engineRef: SyncEngine, autoPair: Bool) {
        self.engineRef = engineRef
        self.autoPair = autoPair
    }

    func engine(_ engine: SyncEngine, peerConnected info: PeerConnection.PeerInfo) {
        log("✅ 已连接: \(info.name) (fp \(DeviceIdentity.shortFingerprint(info.fingerprint)))")
        for send in pendingSends { send() }
        pendingSends.removeAll()
    }

    func engine(_ engine: SyncEngine, peerDisconnected info: PeerConnection.PeerInfo, error: String?) {
        log("🔌 断开: \(info.name)\(error.map { " (\($0))" } ?? "")")
    }

    func engine(_ engine: SyncEngine, pairingRequested info: PeerConnection.PeerInfo,
                reply: @escaping (Bool) -> Void) {
        log("🔑 配对请求: \(info.name) (指纹 \(DeviceIdentity.shortFingerprint(info.fingerprint)))")
        if autoPair {
            reply(true)
            log("   → 自动接受")
        } else {
            print("   是否接受? (y/n) ", terminator: "")
            let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
            reply(line == "y" || line == "yes")
        }
    }

    func engine(_ engine: SyncEngine, didReceiveClipboardText text: String) {
        log("📋 收到文本 (\(text.count) 字): \(text.prefix(120))")
        guard watchClipboard else { return }
        ClipboardMonitor.write(text: text)
    }

    func engine(_ engine: SyncEngine, didReceiveClipboardImage png: Data) {
        log("🖼  收到图片 (\(png.count) 字节),已写入剪贴板")
        ClipboardMonitor.write(png: png)
    }

    func engine(_ engine: SyncEngine, fileTransferStarted id: String, name: String, direction: SyncEngine.Direction) {
        log("📦 \(direction == .incoming ? "接收" : "发送")文件开始: \(name)")
    }

    func engine(_ engine: SyncEngine, fileProgress id: String, name: String, fraction: Double, direction: SyncEngine.Direction) {
        // 只在 25% 步进时打印,避免刷屏
        let pct = Int(fraction * 100)
        if pct % 25 == 0 { log("📦 \(name) \(direction.rawValue) \(pct)%") }
    }

    func engine(_ engine: SyncEngine, fileTransferFinished id: String, name: String, url: URL?, error: String?, direction: SyncEngine.Direction) {
        if let error {
            log("❌ 文件失败: \(name) — \(error)")
        } else if let url {
            log("📦 文件已存: \(url.path)")
        } else {
            log("📦 文件发送完成: \(name)")
        }
    }
}

let delegate = Delegate(engineRef: engine, autoPair: autoPair)
engine.delegate = delegate
engine.autoConnectUnpaired = autoPair

do {
    try engine.start()
} catch {
    fputs("启动失败: \(error)\n", stderr)
    exit(1)
}

log("ProtoSync 对端已启动:name=\(name) fp=\(DeviceIdentity.shortFingerprint(engine.myInfo.fingerprint))")
log("收件箱: \(inboxDir.path)")

// 发送动作等首个对端连上后执行
if let text = sendText {
    delegate.pendingSends.append { engine.broadcastClipboardText(text) }
}
if let filePath = sendFile {
    delegate.pendingSends.append {
        let url = URL(fileURLWithPath: filePath)
        if let peer = engine.onlinePeers().first {
            engine.sendFile(at: url, to: peer.fingerprint)
        } else {
            log("没有在线对端,无法发送 \(filePath)")
        }
    }
}

if watchClipboard {
    let monitor = ClipboardMonitor()
    monitor.onClipboardChanged = { content in
        switch content {
        case .text(let text):
            guard !engine.seenContains(SyncEngine.sha256Hex(Data(text.utf8))) else { return }
            engine.broadcastClipboardText(text)
        case .image(let png):
            guard !engine.seenContains(SyncEngine.sha256Hex(png)) else { return }
            engine.broadcastClipboardImage(png: png)
        case .none:
            break
        }
    }
    monitor.start()
}

// 联调诊断:每 5 秒报一次发现/在线状态
let diag = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
    log("diag: discovered=\(engine.discoveredUnpaired().count) online=\(engine.onlinePeers().count)")
}
RunLoop.main.add(diag, forMode: .common)

// Ctrl-C 退出
signal(SIGINT) { _ in exit(0) }
withExtendedLifetime(engine) {
    RunLoop.main.run()
}
