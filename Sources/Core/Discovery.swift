import Foundation
import Network

/// Bonjour 服务发现。服务名 = 设备指纹前 16 位 hex(稳定、天然唯一,
/// 避免同名冲突和 TXT 解析的兼容性问题),设备的人类可读名字由握手 hello 带出。
public struct DiscoveredService: Equatable {
    public let shortFp: String
    public let endpoint: NWEndpoint
}

public final class ServiceBrowser {
    public var onServicesChanged: (([DiscoveredService]) -> Void)?

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "protosync.browser")

    public init() {}

    public func start() {
        let params = NWParameters()
        let browser = NWBrowser(for: .bonjour(type: "_protosync._tcp", domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let services = results.compactMap { result -> DiscoveredService? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredService(shortFp: name, endpoint: result.endpoint)
            }
            self?.onServicesChanged?(services)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    public func restart() {
        stop()
        start()
    }
}

public final class ServiceListener {
    public var onNewConnection: ((NWConnection) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "protosync.listener")
    public private(set) var port: UInt16 = 0
    private var shortFp = ""
    private var triedAnyFallback = false

    public init() {}

    /// 固定端口 52525,重启不变(手动 IP 连接才可靠);被占用时回落随机端口。
    public func start(shortFp: String) throws {
        self.shortFp = shortFp
        triedAnyFallback = false
        startListener(on: 52525)
    }

    private func startListener(on fixedPort: UInt16?) {
        listener?.cancel()
        listener = nil
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let newListener: NWListener
        do {
            if let fixedPort, let p = NWEndpoint.Port(rawValue: fixedPort) {
                newListener = try NWListener(using: params, on: p)
            } else {
                newListener = try NWListener(using: params, on: .any)
            }
        } catch {
            PLog.info("ProtoSync: listener create failed: \(error.localizedDescription)")
            fallbackIfNeeded()
            return
        }
        newListener.service = NWListener.Service(name: shortFp, type: "_protosync._tcp")
        newListener.newConnectionHandler = { [weak self] connection in
            self?.onNewConnection?(connection)
        }
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = newListener?.port?.rawValue ?? 0
                PLog.info("ProtoSync: listening on port \(self.port)")
            case .failed(let error):
                PLog.info("ProtoSync: listener failed: \(error.localizedDescription)")
                self.fallbackIfNeeded()
            default:
                break
            }
        }
        listener = newListener
        newListener.start(queue: queue)
    }

    private func fallbackIfNeeded() {
        guard !triedAnyFallback else { return }
        triedAnyFallback = true
        startListener(on: nil)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    public func restart(shortFp: String) throws {
        try start(shortFp: shortFp)
    }
}

import Darwin

public enum LanAddress {
    /// 首选 en0 的局域网 IPv4;找不到返回任意非环回 IPv4。
    public static func primaryIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var fallback: String?
        var ptr = ifaddr
        while let p = ptr {
            let ifa = p.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var addr = sockaddr_in()
                memcpy(&addr, sa, MemoryLayout<sockaddr_in>.size)
                let ip = String(cString: inet_ntoa(addr.sin_addr))
                if !ip.hasPrefix("127.") {
                    let name = String(cString: ifa.ifa_name)
                    if name == "en0" { return ip }
                    if fallback == nil { fallback = ip }
                }
            }
            ptr = p.pointee.ifa_next
        }
        return fallback
    }
}
