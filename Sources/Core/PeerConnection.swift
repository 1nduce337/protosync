import Foundation
import Network

/// 单条设备间连接:TCP → 明文握手(hello/auth)→ AEAD 加密帧。
/// 配对被拒绝时以 error 帧告知对端后关闭。
public final class PeerConnection {
    public enum State {
        case handshaking
        case established
        case closed
    }

    public protocol Delegate: AnyObject {
        func connection(_ connection: PeerConnection, didEstablishPeer peer: PeerInfo)
        func connection(_ connection: PeerConnection, didAcceptPairing peer: PeerInfo)
        func connection(_ connection: PeerConnection, didReceive message: Message)
        func connection(_ connection: PeerConnection, pairingRequested peer: PeerInfo,
                        reply: @escaping (Bool) -> Void)
        func connectionDidClose(_ connection: PeerConnection, error: String?)
    }

    public struct PeerInfo {
        public var fingerprint: String
        public var name: String
        /// 本次握手的配对码(两端一致);非握手来源的 PeerInfo 为 nil
        public var sas: String?
        /// 对端 hello 声称双方已配对(它在自动重连);未经认证,只用于决定怎么回应
        public var claimsPaired: Bool
        public init(fingerprint: String, name: String, sas: String? = nil, claimsPaired: Bool = false) {
            self.fingerprint = fingerprint
            self.name = name
            self.sas = sas
            self.claimsPaired = claimsPaired
        }
    }

    public typealias PairingPolicy = (PeerInfo, @escaping (Bool) -> Void) -> Void

    public let role: SecureChannel.Role
    private let nw: NWConnection
    private weak var delegate: Delegate?
    private let identity: DeviceIdentity
    private let pairingPolicy: PairingPolicy
    /// initiator:本端认为已与对方配对(自动重连),hello 里带上 paired
    private let reconnect: Bool

    private let channel: SecureChannel
    private let codec = FrameCodec()
    private let workQueue: DispatchQueue
    private var isClosed = false
    private var handshakeStarted = false
    private var pairingDecided = false
    private var pendingAuth: Message?
    public private(set) var peerInfo: PeerInfo?
    public private(set) var state: State = .handshaking
    let createdAt = Date()
    public private(set) var handshakeProgressAt = Date()
    public private(set) var awaitingPairingDecision = false
    /// 最近一次收到任何帧的时间(心跳判活依据)。
    public private(set) var lastInboundAt = Date()

    public init(nw: NWConnection, role: SecureChannel.Role, identity: DeviceIdentity,
         pairingPolicy: @escaping PairingPolicy, delegate: Delegate, queue: DispatchQueue,
         reconnect: Bool = false) {
        self.nw = nw
        self.reconnect = reconnect
        self.role = role
        self.identity = identity
        self.pairingPolicy = pairingPolicy
        self.delegate = delegate
        self.channel = SecureChannel(identity: identity, role: role)
        self.workQueue = queue
    }

    public func start() {
        nw.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .preparing:
                PLog.info("ProtoSync: conn preparing (\(self?.role == .initiator ? "initiator" : "responder"))")
            case .ready:
                PLog.info("ProtoSync: conn ready (\(self?.role == .initiator ? "initiator" : "responder"))")
                guard let self, !self.isClosed else { return }
                if self.role == .initiator, !self.handshakeStarted {
                    self.handshakeStarted = true
                    self.beginHandshake()
                }
            case .failed(let error):
                PLog.info("ProtoSync: conn failed: \(error.localizedDescription)")
                self?.close(withError: error.localizedDescription)
            case .waiting(let error):
                // waiting 通常是暂态(接口选择/解析中),等它自己恢复,不能关连接。
                PLog.info("ProtoSync: connection waiting: \(error.localizedDescription)")
            case .cancelled:
                self?.close(withError: nil)
            default:
                break
            }
        }
        nw.start(queue: workQueue)
        receiveLoop()
    }

    public func shutdown() {
        close(withError: nil)
    }

    /// 仅在 established 后可用;发送经加密。
    public func send(_ message: Message) {
        workQueue.async { [weak self] in
            guard let self, !self.isClosed, self.state == .established else { return }
            do {
                let frame = FrameCodec.wrap(try self.channel.seal(message))
                self.nw.send(content: frame, completion: .contentProcessed { [weak self] error in
                    if let error { self?.close(withError: error.localizedDescription) }
                })
            } catch {
                self.close(withError: error.localizedDescription)
            }
        }
    }

    /// 发完这一条再关闭(用于 unpair:必须送达后才断开)。
    public func sendThenShutdown(_ message: Message) {
        workQueue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            guard self.state == .established, let sealed = try? self.channel.seal(message) else {
                self.close(withError: nil)
                return
            }
            self.nw.send(content: FrameCodec.wrap(sealed), completion: .contentProcessed { [weak self] _ in
                self?.close(withError: nil)
            })
        }
    }

    // MARK: - 握手

    private func beginHandshake() {
        sendHandshakeFrame(channel.makeHello(paired: reconnect))
    }

    private func completeAuth(_ message: Message) throws {
        guard state == .handshaking else { return }
        try channel.verifyAuth(message)
        state = .established
        if let info = peerInfo {
            delegate?.connection(self, didEstablishPeer: info)
        }
    }

    private func handleHandshakeFrame(_ frame: Data) {
        do {
            let message = try Message.decode(from: frame)
            _ = message
            switch message.type {
            case MessageType.hello:
                guard peerInfo == nil else {
                    throw ProtoSyncError.unexpectedMessage("重复 hello")
                }
                try channel.acceptPeerHello(message)
                let info = PeerInfo(fingerprint: channel.peerFingerprint!, name: channel.peerName ?? "未知设备",
                                    sas: channel.sasCode, claimsPaired: channel.peerClaimsPaired)
                peerInfo = info
                // responder 收到对方 hello 后,要先回自己的 hello 再进入 auth 阶段。
                if role == .responder {
                    sendHandshakeFrame(channel.makeHello())
                }
                // 配对裁决:策略层决定是否接受(弹窗/自动),裁决前不发送 auth。
                awaitingPairingDecision = true
                handshakeProgressAt = Date()
                pairingPolicy(info) { [weak self] granted in
                    guard let self else { return }
                    self.workQueue.async {
                        guard !self.isClosed, !self.pairingDecided else { return }
                        self.pairingDecided = true
                        self.awaitingPairingDecision = false
                        self.handshakeProgressAt = Date()
                        guard granted else {
                            self.sendHandshakeFrame(.error("对方拒绝了配对请求"))
                            self.close(withError: "配对被拒绝")
                            return
                        }
                        do {
                            self.delegate?.connection(self, didAcceptPairing: info)
                            self.sendHandshakeFrame(try self.channel.makeAuth())
                            // 对端的 auth 可能先于本端裁决到达,此时补验。
                            if let buffered = self.pendingAuth {
                                self.pendingAuth = nil
                                try self.completeAuth(buffered)
                            }
                        } catch { self.close(withError: error.localizedDescription) }
                    }
                }
            case MessageType.auth:
                // 裁决未完成时先缓存(对端可能自动接受,auth 到得很快)。
                guard pairingDecided else {
                    pendingAuth = message
                    return
                }
                try completeAuth(message)
            case MessageType.error:
                close(withError: message.error ?? "对端报错")
            default:
                throw ProtoSyncError.unexpectedMessage(message.type)
            }
        } catch ProtoSyncError.versionMismatch(let peerVersion) {
            // 旧版本对端能识别 error 帧并展示原因,比静默断开或含糊的验签失败更好排查
            let error = ProtoSyncError.versionMismatch(peerVersion)
            sendHandshakeFrame(.error(error.localizedDescription))
            close(withError: error.localizedDescription)
        } catch {
            let head = [UInt8](frame.prefix(48))
            let preview = "hex=" + head.map { String(format: "%02x", $0) }.joined()
            PLog.info("ProtoSync: decode failed frame=\(preview)")
            close(withError: error.localizedDescription)
        }
    }

    // MARK: - 收发循环

    private func sendHandshakeFrame(_ message: Message) {
        guard let frame = try? FrameCodec.encode(message) else { return }
        nw.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error { self?.close(withError: error.localizedDescription) }
        })
    }

    private func receiveLoop() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.close(withError: error.localizedDescription)
                return
            }
            if let data {
                self.lastInboundAt = Date()
                do {
                    for frame in try self.codec.feed(data) {
                        if self.state == .established {
                            let message = try self.channel.open(frame)
                            self.delegate?.connection(self, didReceive: message)
                        } else {
                            self.handleHandshakeFrame(frame)
                        }
                        if self.isClosed { return }
                    }
                } catch {
                    self.close(withError: error.localizedDescription)
                    return
                }
            }
            if isComplete {
                self.close(withError: nil)
                return
            }
            self.receiveLoop()
        }
    }

    private func close(withError error: String?) {
        guard !isClosed else { return }
        isClosed = true
        state = .closed
        let reason = "ProtoSync: conn closed (\(role == .initiator ? "initiator" : "responder")) peer=\(peerInfo?.fingerprint.prefix(8) ?? "?") err=\(error ?? "nil")"
        PLog.info(reason)
        nw.cancel()
        delegate?.connectionDidClose(self, error: error)
    }
}
