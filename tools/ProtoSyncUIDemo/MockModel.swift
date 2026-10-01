import Foundation
import Combine

// 演示用模拟数据源:全部为假数据,不接触任何网络/剪贴板/文件系统。
// 6 位配对码(SAS)是产品必需的安全确认能力:两端从握手材料各自推导同一码值供用户比对;
// 真实协议(Swift/Android)尚未实现推导逻辑,落地前演示先行(设计规范 §9.3/§12)。
// 其余仍对齐真实边界:无平台类型、无 MB/s/ETA、无剪贴板送达回执。

struct DemoDevice: Identifiable, Equatable {
    enum Status: Equatable {
        case online
        case offline
    }

    let id = UUID()
    var name: String
    var fingerprint: String   // 前 8 位 hex
    var status: Status
    var isPaired: Bool
}
enum DemoFormat {
    static func fingerprintText(_ fp: String) -> String {
        let prefix = String(fp.prefix(8))
        return "\(prefix.prefix(4)) \(prefix.suffix(4))"
    }

    static func pairingCode(_ code: String) -> String {
        "\(code.prefix(3)) \(code.suffix(3))"
    }
}

struct DemoInboxFile: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var meta: String          // "4.03 kB · 20:48" 等
}

struct DemoActivity: Identifiable, Equatable {
    enum Kind: String { case text, image, file, event }
    enum Direction: String { case incoming, outgoing }

    let id = UUID()
    var kind: Kind
    var direction: Direction
    var title: String         // 短预览(隐私:不展示全文)
    var bytesText: String     // "1.2 / 4.8 MB" 或条数
    var detail: String = ""   // "接收中…" / "已保存到收件箱" 等
    var time: Date
    var progress: Double?     // file 传输中 0...1;其余 nil
    var failed: Bool
    var failedReason: String?
}

final class MockModel: ObservableObject {
    enum Mode: String, CaseIterable {
        case overview = "总览"
        case devices = "设备"
        case activity = "流转"
        case inbox = "收件箱"
    }

    @Published var mode: Mode = .overview
    @Published var deviceName: String = "Aperature Studio"
    @Published var fingerprint: String = "a3f9c2e1"
    @Published var serviceOnline = true
    @Published var isScanning = false
    @Published var devices: [DemoDevice] = []
    @Published var activities: [DemoActivity] = []
    @Published var inboxFiles: [DemoInboxFile] = []
    @Published var pairingRequest: PairingRequest?
    @Published var hud: HUDMessage?
    @Published var activeTransfer: DemoActivity?

    struct PairingRequest: Identifiable {
        let id = UUID()
        let name: String
        let fingerprint: String   // 真实协议:指纹确认
        let code: String          // 6 位 SAS 配对码:两端各自推导,应一致
    }

    struct HUDMessage: Identifiable, Equatable {
        let id = UUID()
        var symbol: String
        var text: String
    }

    private var transferTimer: Timer?
    private var transferState: (id: UUID, direction: DemoActivity.Direction, sizeMB: Double, speedMBps: Double, failAt: Double?)?
    private var hudTask: DispatchWorkItem?
    private var counter = 0

    private static let fakePeerNames = ["PMA110", "MatePad 12", "Mi 14", "vivo X100"]
    private static let fakeTexts = [
        "会议纪要:周四 10 点评审 ProtoSync 交互稿",
        "https://github.com/beingpax/VoiceInk",
        "把这份 RFC 里的 nonce 语义再核对一遍",
        "服务器密码已更新,放密码管理器了",
    ]

    init() { seed() }

    var onlineCount: Int { devices.filter { $0.status == .online }.count }

    /// 当前已连接(在线)的全部设备
    var connectedDevices: [DemoDevice] { devices.filter { $0.status == .online } }

    /// 已配对设备,在线的排前面(各自保持原有相对顺序,离线设备回上线时即移动到顶部)
    var pairedSorted: [DemoDevice] {
        let paired = devices.filter { $0.isPaired }
        return paired.filter { $0.status == .online } + paired.filter { $0.status == .offline }
    }

    func seed() {
        devices = [
            DemoDevice(name: "PMA110", fingerprint: "05d7806c", status: .online, isPaired: true),
            DemoDevice(name: "Mi 14", fingerprint: "7c11e94b", status: .offline, isPaired: true),
            DemoDevice(name: "MatePad 12", fingerprint: "b82f3d19", status: .online, isPaired: true),
        ]
        activities = [
            DemoActivity(kind: .file, direction: .incoming, title: "设计稿-v2.png",
                         bytesText: "2.4 MB", time: Date().addingTimeInterval(-600),
                         progress: nil, failed: false, failedReason: nil),
            DemoActivity(kind: .text, direction: .outgoing, title: "https://github.com/beingpax/VoiceInk",
                         bytesText: "38 字", time: Date().addingTimeInterval(-1500),
                         progress: nil, failed: false, failedReason: nil),
        ]
        inboxFiles = [
            DemoInboxFile(name: "设计稿-v2.png", meta: "2.4 MB · 20:15"),
            DemoInboxFile(name: "需求说明.pdf", meta: "412 kB · 19:02"),
        ]
    }

    // MARK: - 设备

    func addNearbyDevice() {
        counter += 1
        let name = MockModel.fakePeerNames.randomElement()! + "-\(counter)"
        let fp = String(format: "%08x", Int.random(in: 0..<0xffff_ffff))
        devices.append(DemoDevice(name: name, fingerprint: fp, status: .offline, isPaired: false))
    }

    func pairNearby(_ device: DemoDevice) {
        guard let idx = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[idx].status = .online
        devices[idx].isPaired = true
        flashHUD(symbol: "checkmark.seal", text: "已与 \(device.name) 配对")
    }

    func addDevice(status: DemoDevice.Status) {
        counter += 1
        let name = MockModel.fakePeerNames.randomElement()! + "-\(counter)"
        let fp = String(format: "%08x", Int.random(in: 0..<0xffff_ffff))
        devices.append(DemoDevice(name: name, fingerprint: fp, status: status, isPaired: true))
        flashHUD(symbol: status == .online ? "circle.dotted" : "moon.zzz",
                 text: status == .online ? "\(name) 出现在局域网" : "\(name) 已离线")
    }

    func toggleOnline(_ device: DemoDevice) {
        guard let idx = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[idx].status = devices[idx].status == .online ? .offline : .online
        flashHUD(symbol: devices[idx].status == .online ? "circle.dotted" : "moon.zzz",
                 text: "\(device.name) 已\(devices[idx].status == .online ? "连接" : "离线")")
    }

    func removeDevice(_ device: DemoDevice) {
        devices.removeAll { $0.id == device.id }
        flashHUD(symbol: "trash", text: "已移除 \(device.name)")
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.isScanning = false
            self?.flashHUD(symbol: "circle.dotted", text: "已重新扫描局域网")
        }
    }

    // MARK: - 配对(6 位 SAS 配对码 + 指纹确认)

    func simulatePairingRequest() {
        let fp = String(format: "%08x", Int.random(in: 0..<0xffff_ffff))
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        pairingRequest = PairingRequest(name: MockModel.fakePeerNames.randomElement()!, fingerprint: fp, code: code)
    }

    func acceptPairing() {
        guard let req = pairingRequest else { return }
        pairingRequest = nil
        devices.append(DemoDevice(name: req.name, fingerprint: req.fingerprint, status: .online, isPaired: true))
        pushActivity(.event, .incoming, title: "已与 \(req.name) 完成配对",
                     bytesText: "指纹 \(req.fingerprint)", failed: false)
        flashHUD(symbol: "checkmark.seal", text: "配对完成")
    }

    func rejectPairing() {
        guard let req = pairingRequest else { return }
        pairingRequest = nil
        pushActivity(.event, .incoming, title: "已拒绝 \(req.name) 的配对请求",
                     bytesText: "指纹 \(req.fingerprint)", failed: true)
    }

    // MARK: - 剪贴板

    func simulateIncomingText() {
        pushActivity(.text, .incoming, title: MockModel.fakeTexts.randomElement()!,
                     bytesText: "\(Int.random(in: 8...60)) 字", failed: false)
        flashHUD(symbol: "doc.on.doc", text: "收到文本,已进剪贴板")
    }

    func simulateIncomingImage() {
        pushActivity(.image, .incoming, title: "截图 2026-09-17.png",
                     bytesText: "\(Int.random(in: 120...900)) KB", failed: false)
        flashHUD(symbol: "photo", text: "收到图片,已进剪贴板")
    }

    func simulateSendClipboard() {
        let online = devices.filter { $0.status == .online }.count
        guard online > 0 else { flashHUD(symbol: "wifi.slash", text: "没有在线设备"); return }
        pushActivity(.text, .outgoing, title: MockModel.fakeTexts.randomElement()!,
                     bytesText: "\(Int.random(in: 8...60)) 字", failed: false)
        flashHUD(symbol: "arrow.up.doc", text: "已发送给 \(online) 台设备")
    }

    // MARK: - 文件传输模拟(支持多任务并发)

    struct TransferJob: Identifiable, Equatable {
        let id: UUID
        let direction: DemoActivity.Direction
        let name: String
        let sizeMB: Double
        var doneMB: Double
        let speedMBps: Double
        let failAt: Double?
        var failed: Bool
        var completed: Bool = false
    }

    @Published var jobs: [TransferJob] = []

    var overallProgress: (fraction: Double, doneMB: Double, totalMB: Double)? {
        guard !jobs.isEmpty else { return nil }
        let total = jobs.reduce(0) { $0 + $1.sizeMB }
        let done = jobs.reduce(0) { $0 + $1.doneMB }
        guard total > 0 else { return nil }
        return (done / total, done, total)
    }

    private var jobTimer: Timer?

    func simulateFileTransfer(direction: DemoActivity.Direction, duration: Double, failAt: Double?, parallel: Int = 1) {
        for n in 0..<max(1, parallel) {
            let sizeMB = Double.random(in: 40...320)
            // 让调试按钮标注的时长真实生效
            let speed = sizeMB / max(1, duration) * Double.random(in: 0.85...1.15)
            let name = direction == .incoming
                ? MockModel.fakePeerNames.randomElement()! + "-导出.zip"
                : ["年度总结.pptx", "扫描件.pdf", "demo 录屏.mov"].randomElement()! + (n > 0 ? " (\(n + 1))" : "")
            let job = TransferJob(id: UUID(), direction: direction, name: name,
                                  sizeMB: sizeMB, doneMB: 0, speedMBps: speed,
                                  failAt: failAt, failed: false)
            jobs.append(job)
            activities.insert(DemoActivity(
                kind: .file, direction: direction, title: name,
                bytesText: "0 / \(String(format: "%.1f", sizeMB)) MB",
                time: Date(), progress: 0, failed: false, failedReason: nil), at: 0)
        }
        if activities.count > 80 { activities.removeLast(activities.count - 80) }

        guard jobTimer == nil else { return }   // 已有 tick 在跑,新任务自动被推
        let timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); self?.jobTimer = nil; return }
            guard !self.jobs.isEmpty else {
                t.invalidate(); self.jobTimer = nil; return
            }
            let dt = 0.08
            for i in self.jobs.indices {
                guard !self.jobs[i].failed, !self.jobs[i].completed else { continue }
                var job = self.jobs[i]
                let step = job.speedMBps * dt
                job.doneMB = min(job.sizeMB, job.doneMB + step * Double.random(in: 0.7...1.3))

                let frac = job.sizeMB > 0 ? job.doneMB / job.sizeMB : 1
                if let fail = job.failAt, frac >= fail {
                    job.failed = true
                    self.jobs[i] = job
                    if let idx = self.activities.firstIndex(where: { $0.title == job.name && $0.progress != nil }) {
                        self.activities[idx].progress = nil
                        self.activities[idx].failed = true
                        self.activities[idx].failedReason = "连接被对端重置(模拟)"
                    }
                    self.flashHUD(symbol: "exclamationmark.triangle.fill", text: "\(job.name) 传输失败")
                    self.scheduleJobRemoval(id: job.id, after: 4)   // 已中断态短暂停留后清出主舞台
                    continue
                }
                if job.doneMB >= job.sizeMB {
                    // 完成分支只会进这一次:标记 completed 后不再被 tick 处理
                    job.doneMB = job.sizeMB
                    job.completed = true
                    self.jobs[i] = job
                    if let idx = self.activities.firstIndex(where: { $0.title == job.name && $0.progress != nil }) {
                        self.activities[idx].progress = nil
                        self.activities[idx].bytesText = String(format: "%.1f MB", job.sizeMB)
                        self.activities[idx].detail = job.direction == .incoming ? "已保存到收件箱" : "已发送"
                    }
                    if job.direction == .incoming {
                        self.inboxFiles.insert(DemoInboxFile(
                            name: job.name, meta: String(format: "%.1f MB · 现在", job.sizeMB)), at: 0)
                    }
                    self.flashHUD(symbol: job.direction == .incoming ? "tray.full" : "checkmark.circle",
                                  text: job.direction == .incoming ? "\(job.name) 已保存到收件箱" : "\(job.name) 已发送")
                    self.scheduleJobRemoval(id: job.id, after: 2.5) // 完成态(Lime 轨道)短暂停留后回空闲
                } else {
                    self.jobs[i] = job
                    if let idx = self.activities.firstIndex(where: { $0.title == job.name && $0.progress != nil }) {
                        self.activities[idx].progress = frac
                        self.activities[idx].bytesText = String(format: "%.1f / %.1f MB", job.doneMB, job.sizeMB)
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 从主舞台移除已结束的任务;resetDemo 清空后此操作自然成为空操作
    private func scheduleJobRemoval(id: UUID, after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.jobs.removeAll { $0.id == id }
        }
    }

    func clearActivities() { activities.removeAll() }

    func resetDemo() {
        jobTimer?.invalidate()
        jobTimer = nil
        jobs.removeAll()
                pairingRequest = nil
        seed()
        flashHUD(symbol: "arrow.counterclockwise", text: "演示已重置")
    }

    // MARK: - 内部

    private func pushActivity(_ kind: DemoActivity.Kind, _ direction: DemoActivity.Direction,
                              title: String, bytesText: String, failed: Bool,
                              failedReason: String? = nil) {
        activities.insert(DemoActivity(kind: kind, direction: direction, title: title,
                                       bytesText: bytesText, time: Date(), progress: nil,
                                       failed: failed, failedReason: failedReason), at: 0)
        if activities.count > 80 { activities.removeLast(activities.count - 80) }
    }

    func flashHUD(symbol: String, text: String) {
        hudTask?.cancel()
        hud = HUDMessage(symbol: symbol, text: text)
        let task = DispatchWorkItem { [weak self] in self?.hud = nil }
        hudTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: task)
    }

    func hud(symbol: String, text: String) { flashHUD(symbol: symbol, text: text) }
}
