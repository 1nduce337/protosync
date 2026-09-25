package com.protosync.core;

import android.content.Context;
import android.net.nsd.NsdServiceInfo;
import android.os.Handler;
import android.os.Looper;

import org.json.JSONObject;

import java.io.DataInputStream;
import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * 同步引擎编排(重写版)。
 *
 * 线程模型是本轮重写的核心改进——旧实现"UI 线程直接发网络包"导致
 * NetworkOnMainThreadException 被吞掉、手机→Mac 剪贴板从未真正通过:
 * - 引擎 HandlerThread 拥有全部状态与全部控制帧发送;
 * - 对外 API 只向引擎线程投递任务,任何线程调用都安全;
 * - 事件统一经 main Handler 回调 UI;
 * - 心跳/重连跑在引擎线程,文件 I/O(哈希/分块/落盘)在专用 IO 线程。
 *
 * 心跳:established 后每 5s 发 ping(入站即判活);15s 无入站判死;
 * 握手 10s 超时(配对等待 120s);顺带按 5s 防抖重连已配对的掉线设备。
 */
public final class SyncCore {
    public static final int LISTEN_PORT = 52526; // 被占则回落随机端口

    public interface Listener {
        void onLog(String line);
        void onPeerConnected(String name, String fp);
        void onPeerDisconnected(String fp, String reason);
        void onPairingRequested(String name, String fp);
        void onClipboardText(String text);
        void onClipboardImage(byte[] png);
        void onClipboardResult(boolean ok, String detail);
        void onDiscoveredChanged();
        void onTransferStarted(String id, String name, boolean incoming);
        void onTransferProgress(String id, String name, double fraction, boolean incoming);
        void onTransferFinished(String id, String name, boolean ok, String error,
                                boolean incoming, String savedPath, String savedUri);
        void onActivityChanged();
    }

    public static class ActivityItem {
        public final long time = System.currentTimeMillis();
        public final String kind;      // "peer" | "text" | "image" | "file"
        public final boolean incoming;
        public final String title;
        public final String detail;
        public final boolean failed;

        ActivityItem(String kind, boolean incoming, String title, String detail, boolean failed) {
            this.kind = kind;
            this.incoming = incoming;
            this.title = title;
            this.detail = detail;
            this.failed = failed;
        }
    }

    // ================= 基础设施 =================

    private final Context context;
    private Listener listener;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private android.os.HandlerThread engineThread;
    private Handler engine;
    private final ExecutorService connectors = Executors.newCachedThreadPool(r -> {
        Thread t = new Thread(r, "protosync-connect");
        t.setDaemon(true);
        return t;
    });
    private volatile boolean running = false;

    // 引擎线程专属状态
    private ServerSocket serverSocket;
    private IdentityStore identity;
    private DiscoveryManager discovery;
    private Transfers transfers;
    private final Map<String, PeerLink> connections = new java.util.concurrent.ConcurrentHashMap<>(); // fp → established(传输 IO 线程按指纹读取)
    private final List<PeerLink> pending = new ArrayList<>();                // 握手中
    private final Deque<PeerLink> awaitingPairing = new ArrayDeque<>();
    private final Map<String, Long> seen = new HashMap<>();                  // hash → 时间
    private final Map<String, Long> connectAttempts = new HashMap<>();
    private final Map<String, Long> dialBlockedUntil = new HashMap<>();      // fp → 拉黑截止时间
    private final Map<String, String> pairingNames = new HashMap<>();        // 配对请求队列中的 fp → 设备名
    private final ArrayDeque<ActivityItem> activityLog = new ArrayDeque<>();
    private String myName;

    // ================= 生命周期 =================

    public SyncCore(Context context) {
        this.context = context.getApplicationContext();
    }

    public void start(Listener listener) throws Exception {
        if (running) return;
        this.listener = listener;
        running = true;

        android.os.HandlerThread ht = new android.os.HandlerThread("protosync-engine");
        ht.start();
        engineThread = ht;
        engine = new Handler(ht.getLooper());
        // getLooper() 已保证线程就绪;初始化异常经日志暴露,不阻塞 start() 返回
        engine.post(() -> {
            try {
                engineLoopInit();
            } catch (Exception e) {
                postLog("引擎启动失败: " + e.getMessage());
            }
        });
    }

    private void engineLoopInit() throws Exception {
        myName = android.os.Build.MODEL == null ? "Android 设备" : android.os.Build.MODEL;
        identity = new IdentityStore(context, myName);
        transfers = new Transfers(new TransfersHost(), context, new TransfersEvents());
        serverSocket = openServerSocket();
        discovery = new DiscoveryManager(context, engine, identity.fingerprint,
                serverSocket.getLocalPort(), new DiscoveryListenerImpl());
        startHeartbeat();
        discovery.start();
        startAcceptLoop();
        postLog("引擎已启动,端口 " + serverSocket.getLocalPort() + ",指纹 " + shortFp());
    }

    private ServerSocket openServerSocket() throws IOException {
        try {
            return new ServerSocket(LISTEN_PORT, 50, InetAddress.getByName("0.0.0.0"));
        } catch (IOException bindFailed) {
            return new ServerSocket(0, 50, InetAddress.getByName("0.0.0.0"));
        }
    }

    public void stop() {
        if (!running) return;
        running = false;
        runOnEngine(() -> {
            if (discovery != null) discovery.stop();
            if (transfers != null) transfers.shutdown();
            for (PeerLink c : new ArrayList<>(connections.values())) c.close("引擎停止");
            for (PeerLink c : new ArrayList<>(pending)) c.close("引擎停止");
            connections.clear();
            pending.clear();
            awaitingPairing.clear();
            try { if (serverSocket != null) serverSocket.close(); } catch (IOException ignored) {}
        });
        if (engineThread != null) engineThread.getLooper().quitSafely();
        connectors.shutdownNow();
        transfersIo.shutdownNow();
    }

    // ================= 投递工具 =================

    private void runOnEngine(Runnable r) {
        Handler h = engine;
        if (h != null) h.post(r);
    }

    private void postLog(String line) {
        Listener l = listener;
        android.util.Log.d("ProtoSync", line);
        if (l != null) mainHandler.post(() -> l.onLog(line));
    }

    private void postEvent(Runnable r) {
        mainHandler.post(r);
    }

    private String shortFp() {
        return identity.fingerprint.substring(0, Math.min(8, identity.fingerprint.length()));
    }

    // ================= 查询 API(任意线程)=================

    public String fingerprint() { return identity != null ? identity.fingerprint : ""; }
    public String deviceName() { return identity != null ? identity.deviceName() : "Android 设备"; }
    public int listeningPort() { return serverSocket != null ? serverSocket.getLocalPort() : 0; }
    public boolean isRunning() { return running; }

    public List<String[]> onlinePeersSnapshot() {
        List<String[]> out = new ArrayList<>();
        for (PeerLink c : connections.values())
            if (c.isEstablished() && c.peerFingerprint() != null)
                out.add(new String[]{c.peerFingerprint(), c.peerName()});
        return out;
    }

    /** 未配对且已解析地址的附近设备:serviceName → {name, host, port} */
    public List<String[]> nearbySnapshot() {
        List<String[]> out = new ArrayList<>();
        if (discovery == null) return out;
        for (Map.Entry<String, NsdServiceInfo> e : discovery.resolvedSnapshot().entrySet()) {
            if (discovery.isSelf(e.getKey())) continue;
            if (identity.isPairedPrefix(e.getKey())) continue;
            NsdServiceInfo info = e.getValue();
            if (info.getHost() != null && info.getPort() > 0)
                out.add(new String[]{e.getKey(), info.getHost().getHostAddress(), String.valueOf(info.getPort())});
        }
        return out;
    }

    public List<String[]> pairedSnapshot() {
        return identity != null ? identity.pairedSnapshot() : new ArrayList<>();
    }

    public synchronized List<ActivityItem> activitySnapshot() {
        return new ArrayList<>(activityLog);
    }

    // ================= 动作 API(任意线程,只投递)=================

    public void refreshDiscovery() {
        runOnEngine(() -> {
            connectAttempts.clear();
            discovery.restart();
            retryPairedPeers(0);
        });
    }

    public void connectTo(String host, int port) {
        connectTo(host, port, null);
    }

    /** expectedFp:期望对端指纹。NSD 记录可能过期指向别的设备,握手后校验防止连错对象。 */
    public void connectTo(String host, int port, String expectedFp) {
        connectors.execute(() -> {
            try {
                Socket s = new Socket();
                s.connect(new InetSocketAddress(InetAddress.getByName(host), port), 5000);
                registerLink(s, Role.INITIATOR, true, expectedFp);
            } catch (IOException e) {
                postLog("连接 " + host + ":" + port + " 失败: " + e.getMessage());
            }
        });
    }

    public void pairWithNearby(String serviceName) {
        runOnEngine(() -> {
            if (discovery == null) return;
            NsdServiceInfo info = discovery.resolvedSnapshot().get(serviceName);
            if (info == null || info.getHost() == null || info.getPort() <= 0) {
                postLog("该设备地址尚未解析,请稍后重试");
                return;
            }
            String host = info.getHost().getHostAddress();
            int port = info.getPort();
            connectors.execute(() -> {
                try {
                    Socket s = new Socket();
                    s.connect(new InetSocketAddress(InetAddress.getByName(host), port), 5000);
                    registerLink(s, Role.INITIATOR, true, null);
                } catch (IOException e) {
                    postLog("连接 " + host + ":" + port + " 失败: " + e.getMessage());
                }
            });
        });
    }

    public void acceptPairing(String fp, boolean accept) {
        runOnEngine(() -> {
            // 同一 fp 可能有多条握手中的连接(双向同时拨号),全部一起裁决。
            // 决定基于「指纹」而非具体连接:若此刻该指纹的所有连接恰好断线
            // (15s 握手超时循环),决定仍要持久化,否则用户永远无法配对成功。
            List<PeerLink> matches = new ArrayList<>();
            for (Iterator<PeerLink> it = awaitingPairing.iterator(); it.hasNext(); ) {
                PeerLink l = it.next();
                if (fp.equals(l.peerFingerprint())) { matches.add(l); it.remove(); }
            }
            if (accept) {
                String name = matches.isEmpty() ? pairingNames.get(fp) : matches.get(0).peerName();
                identity.addPaired(fp, name);
                pairingNames.remove(fp);
                postLog("🔐 已配对并持久化 " + fp.substring(0, Math.min(8, fp.length()))
                        + (name != null ? " (" + name + ")" : ""));
            } else {
                pairingNames.remove(fp);
            }
            for (PeerLink l : matches) {
                if (!l.isClosed()) l.decidePairing(accept);
            }
        });
    }

    public void removePaired(String fp) {
        runOnEngine(() -> {
            identity.removePaired(fp);
            PeerLink established = connections.get(fp);
            if (established != null) established.close("已取消配对");
            for (PeerLink p : new ArrayList<>(pending)) {
                if (fp.equals(p.peerFingerprint())) p.close("已取消配对");
            }
            postEvent(() -> listener.onDiscoveredChanged());
        });
    }

    /**
     * 手动发送剪贴板(force):接收端跳过去重。旧版的两处坑都在这里修掉——
     * 不再走 seen 预检(5 分钟内见过的内容也必须能发),无在线设备时明确回调失败。
     */
    public void sendClipboardText(String text) {
        runOnEngine(() -> sendClipboard(Protocol.clipboardText(text, Crypto.sha256Hex(
                text.getBytes(StandardCharsets.UTF_8)), true), text));
    }

    public void sendClipboardImage(byte[] png) {
        runOnEngine(() -> sendClipboard(Protocol.clipboardImage(png, Crypto.sha256Hex(png), true), "图片"));
    }

    private void sendClipboard(Protocol.Msg m, String preview) {
        if (connections.isEmpty()) {
            postEvent(() -> listener.onClipboardResult(false, "没有在线设备"));
            return;
        }
        int sent = 0;
        StringBuilder errors = new StringBuilder();
        for (PeerLink c : connections.values()) {
            try {
                c.sendSealed(m);
                sent++;
            } catch (Exception e) {
                if (errors.length() > 0) errors.append("; ");
                errors.append(c.peerName()).append(": ").append(e.getMessage());
            }
        }
        boolean ok = sent > 0;
        String detail = ok
                ? (errors.length() > 0 ? "已发送到 " + sent + " 台(部分失败: " + errors + ")" : "已发送")
                : "发送失败: " + errors;
        final boolean okFinal = ok;
        final String detailFinal = detail;
        addActivity("text", false, preview, detailFinal, !okFinal);
        postEvent(() -> listener.onClipboardResult(okFinal, detailFinal));
    }

    public void sendFile(String peerFp, android.net.Uri uri, String displayName) {
        runOnEngine(() -> {
            PeerLink link = connections.get(peerFp);
            if (link == null) {
                events().onTransferFinished("", displayName, false, "设备不在线", false, null, null);
                return;
            }
            transfers.sendFile(link, uri, displayName);
        });
    }

    private Transfers.Events events() { return new TransfersEvents(); }

    // ================= 引擎线程内部 =================

    private void startAcceptLoop() {
        Thread t = new Thread(() -> {
            while (running) {
                try {
                    Socket s = serverSocket.accept();
                    registerLink(s, Role.RESPONDER, false, null);
                } catch (IOException e) {
                    if (running) postLog("accept 失败: " + e.getMessage());
                }
            }
        }, "protosync-accept");
        t.setDaemon(true);
        t.start();
    }

    /** accept/connect 线程 → 引擎线程注册新连接。 */
    private void registerLink(Socket socket, Role role, boolean sendHelloFirst, String expectedFp) {
        runOnEngine(() -> {
            if (!running) {
                try { socket.close(); } catch (IOException ignored) {}
                return;
            }
            try {
                PeerLink link = new PeerLink(socket, role, identity, new PairingPolicyImpl(),
                        new FrameSinkImpl(), new LinkEvents());
                if (expectedFp != null) link.setExpectedFingerprint(expectedFp);
                pending.add(link);
                link.start();
                if (sendHelloFirst) link.sendHello();
            } catch (Exception e) {
                try { socket.close(); } catch (IOException ignored) {}
                postLog("连接初始化失败: " + e.getMessage());
            }
        });
    }

    private class FrameSinkImpl implements PeerLink.FrameSink {
        @Override public void onFrame(PeerLink link, byte[] payload) {
            runOnEngine(() -> handleFrame(link, payload));
        }
        @Override public void onReadFailure(PeerLink link, Exception e) {
            runOnEngine(() -> {
                if (!link.isClosed()) link.close(String.valueOf(e));
            });
        }
    }

    private void handleFrame(PeerLink link, byte[] payload) {
        try {
            if (link.isEstablished()) {
                handleEstablished(link, link.openSealed(payload));
                return;
            }
            JSONObject m = new JSONObject(new String(payload, StandardCharsets.UTF_8));
            String type = m.getString("type");
            switch (type) {
                case Protocol.TYPE_HELLO:
                    link.acceptHello(m);
                    // 出站拨号带期望指纹:NSD 记录过期会把连接拨到错误设备,
                    // 立即断开并暂时拉黑该目标,避免 5 秒一次的错误重连循环
                    if (link.role == Role.INITIATOR && link.expectedFingerprint() != null
                            && !link.expectedFingerprint().equals(link.peerFingerprint())) {
                        postLog("⚠️ 拨号目标不匹配: 期望 "
                                + link.expectedFingerprint().substring(0, Math.min(8, link.expectedFingerprint().length()))
                                + " 实际 " + link.peerFingerprint().substring(0, Math.min(8, link.peerFingerprint().length()))
                                + "(NSD 记录过期?拉黑 60s)");
                        dialBlockedUntil.put(link.expectedFingerprint(), System.currentTimeMillis() + 60_000);
                        link.close("拨号到了非目标设备");
                        return;
                    }
                    break;
                case Protocol.TYPE_AUTH:
                    link.acceptAuth(m);
                    break;
                case Protocol.TYPE_ERROR:
                    link.close(m.optString("error", "对端报错"));
                    break;
                default:
                    link.close("意外握手消息: " + type);
            }
        } catch (Exception e) {
            postLog("握手处理异常 [" + link.role + "]: " + e);
            link.close(String.valueOf(e));
        }
    }

    private class PairingPolicyImpl implements PeerLink.PairingPolicy {
        @Override public void decide(PeerLink link, String name, String fp) {
            boolean paired = identity.isPaired(fp);
            postLog("配对裁决 [" + link.role + "] " + fp.substring(0, Math.min(8, fp.length()))
                    + " → " + (paired ? "已配对,自动放行" : "未配对,请求用户确认"));
            if (paired) {
                runOnEngine(() -> link.decidePairing(true));
                return;
            }
            runOnEngine(() -> {
                if (link.isClosed() || link.pairingDecided()) return;
                pairingNames.put(fp, name);
                awaitingPairing.addLast(link);
                postEvent(() -> listener.onPairingRequested(name, fp));
            });
        }
    }

    private class LinkEvents implements PeerLink.Events {
        @Override public void established(PeerLink link) { onLinkEstablished(link); }
        @Override public void closed(PeerLink link, String reason) { onLinkClosed(link, reason); }
    }

    private void onLinkEstablished(PeerLink link) {
        String fp = link.peerFingerprint();
        pending.remove(link);
        removeFromAwaiting(link);
        PeerLink existing = connections.get(fp);
        if (existing != null && existing != link) {
            // 双向同时各建一条:双方按同一规则收敛——fp 较小一方发起的连接获胜。
            // 必须先登记新连接再关旧连接:close 回调里按 connections.get(fp)==link
            // 判断是否清理,先关后放会把存活的传输任务连带取消掉。
            Role preferred = identity.fingerprint.compareTo(fp) < 0 ? Role.INITIATOR : Role.RESPONDER;
            if (link.role == preferred) {
                connections.put(fp, link);
                rememberAddress(link);
                existing.close("被新连接替换");
            } else {
                link.close("重复连接");
            }
            return; // 替换存活路径不算新的上线事件
        }
        if (connections.containsKey(fp)) return;
        connections.put(fp, link);
        rememberAddress(link);
        String name = link.peerName();
        addActivity("peer", true, name, "已连接", false);
        postLog("✅ 已连接 " + name);
        postEvent(() -> listener.onPeerConnected(name, fp));
    }

    private void onLinkClosed(PeerLink link, String reason) {
        pending.remove(link);
        removeFromAwaiting(link);
        String fp = link.peerFingerprint();
        if (fp == null) {
            postLog("连接关闭(未完成握手," + link.role + "): " + reason);
            return;
        }
        postLog("🔌 断开 " + fp.substring(0, Math.min(8, fp.length())) + " [" + link.role + "]"
                + (reason != null ? " (" + reason + ")" : ""));
        if (connections.get(fp) == link) {
            connections.remove(fp);
            transfers.cancelForPeer(fp, reason == null ? "连接已关闭" : reason);
            postEvent(() -> listener.onPeerDisconnected(fp, reason));
        }
    }

    private void removeFromAwaiting(PeerLink link) {
        awaitingPairing.remove(link);
    }

    private void rememberAddress(PeerLink link) {
        try {
            String address = null;
            if (link.role == Role.INITIATOR) {
                InetSocketAddress remote = link.remoteAddress();
                if (remote != null && remote.getAddress() != null)
                    address = remote.getAddress().getHostAddress() + ":" + remote.getPort();
            } else {
                // 应答方向的远端端口是临时源端口,不是对端监听端口;优先用 NSD 解析地址
                String shortFp = link.peerFingerprint().substring(0, Math.min(8, link.peerFingerprint().length()));
                for (Map.Entry<String, NsdServiceInfo> e : discovery.resolvedSnapshot().entrySet()) {
                    if (e.getKey().startsWith(shortFp) && e.getValue().getHost() != null
                            && e.getValue().getPort() > 0) {
                        address = e.getValue().getHost().getHostAddress() + ":" + e.getValue().getPort();
                        break;
                    }
                }
            }
            if (address != null) identity.rememberAddress(link.peerFingerprint(), address);
        } catch (Exception ignored) {}
    }

    // ================= established 消息分发 =================

    private void handleEstablished(PeerLink link, JSONObject m) {
        try {
            switch (m.getString("type")) {
                case Protocol.TYPE_CLIPBOARD: {
                    String hash = m.getString("hash");
                    boolean force = m.optBoolean("force", false);
                    // 手动发送(force)是用户明确意图,不受 5 分钟去重限制;
                    // 自动同步的重复内容丢弃。两者都插入 seen 防回环。
                    if (!force && seenHas(hash)) return;
                    seenPut(hash);
                    String kind = m.optString("kind", "");
                    if ("text".equals(kind)) {
                        String text = m.getString("data");
                        addActivity("text", true, text, "已复制到剪贴板", false);
                        postEvent(() -> listener.onClipboardText(text));
                    } else if ("image".equals(kind)) {
                        byte[] png = Crypto.b64decode(m.getString("data"));
                        addActivity("image", true, "图片", "已复制到剪贴板", false);
                        postEvent(() -> listener.onClipboardImage(png));
                    }
                    break;
                }
                case Protocol.TYPE_FILE_OFFER: transfers.handleOffer(link, m); break;
                case Protocol.TYPE_FILE_CHUNK: transfers.handleChunk(link, m); break;
                case Protocol.TYPE_FILE_DONE: transfers.handleDone(link, m); break;
                case Protocol.TYPE_FILE_ACK: transfers.handleAck(m); break;
                case Protocol.TYPE_PING: break; // 判活只看 lastInboundAt
                default: break;
            }
        } catch (Throwable e) {
            postLog("消息处理失败: " + e);
        }
    }

    // ================= 剪贴板 seen 缓存 =================

    private boolean seenHas(String hash) {
        Long t = seen.get(hash);
        if (t == null) return false;
        if (System.currentTimeMillis() - t < 300_000) return true;
        seen.remove(hash);
        return false;
    }

    private void seenPut(String hash) {
        long now = System.currentTimeMillis();
        seen.put(hash, now);
        if (seen.size() > 512) {
            long cutoff = now - 300_000;
            seen.values().removeIf(t -> t < cutoff);
            if (seen.size() > 512) {
                List<Map.Entry<String, Long>> oldest = new ArrayList<>(seen.entrySet());
                // 按时间排序,删到 512 以内
                oldest.sort((a, b) -> Long.compare(a.getValue(), b.getValue()));
                Set<String> doomed = new HashSet<>();
                for (int i = 0; i < oldest.size() - 512; i++) doomed.add(oldest.get(i).getKey());
                doomed.forEach(seen::remove);
            }
        }
    }

    // ================= 心跳与重连 =================

    private void startHeartbeat() {
        Runnable tick = new Runnable() {
            @Override public void run() {
                if (!running) return;
                try { heartbeatTick(); } catch (Throwable e) { postLog("心跳任务异常: " + e); }
                engine.postDelayed(this, 5000);
            }
        };
        engine.postDelayed(tick, 5000);
    }

    private void heartbeatTick() {
        long now = System.currentTimeMillis();
        for (PeerLink p : new ArrayList<>(pending)) {
            if (p.isEstablished() || p.isClosed()) continue;
            boolean awaitingUser = p.awaitingDecision();
            long base = p.pairingDecided() ? p.pairingDecidedAt() : p.createdAt;
            long timeout = awaitingUser ? 120_000 : 10_000;
            if (now - base > timeout) p.close("握手超时");
        }
        for (PeerLink c : new ArrayList<>(connections.values())) {
            if (now - c.lastInboundAt() > 15_000) {
                c.close("心跳超时");
                continue;
            }
            try { c.sendSealed(new Protocol.Msg().put("type", Protocol.TYPE_PING)); }
            catch (Exception e) { c.close("心跳发送失败"); }
        }
        retryPairedPeers(now);
    }

    /** 已配对但掉线的设备:NSD 实时地址优先,缓存地址兜底(5s 防抖)。 */
    private void retryPairedPeers(long now) {
        for (String[] pd : identity.pairedSnapshot()) {
            String fp = pd[0];
            if (connections.containsKey(fp)) continue;
            boolean pendingExists = false;
            for (PeerLink p : pending) {
                if (p.peerFingerprint() != null && p.peerFingerprint().startsWith(fp)) { pendingExists = true; break; }
            }
            if (pendingExists) continue;
            String addr = resolvedAddressFor(fp);
            if (addr == null) addr = identity.addressOf(fp);
            if (addr == null) continue;
            Long last = connectAttempts.get(fp);
            if (last != null && now - last < 5_000) continue;
            Long blocked = dialBlockedUntil.get(fp);
            if (blocked != null && now < blocked) continue;
            connectAttempts.put(fp, now);
            int colon = addr.lastIndexOf(':');
            if (colon <= 0) continue;
            String host = addr.substring(0, colon).replace("[", "").replace("]", "");
            int port;
            try { port = Integer.parseInt(addr.substring(colon + 1)); }
            catch (NumberFormatException e) { continue; }
            connectTo(host, port, fp);
        }
        if (connectAttempts.size() > 64) connectAttempts.clear();
    }

    private String resolvedAddressFor(String fp) {
        if (discovery == null) return null;
        String shortFp = fp.substring(0, Math.min(8, fp.length()));
        for (Map.Entry<String, NsdServiceInfo> e : discovery.resolvedSnapshot().entrySet()) {
            if (e.getKey().startsWith(shortFp) && e.getValue().getHost() != null && e.getValue().getPort() > 0)
                return e.getValue().getHost().getHostAddress() + ":" + e.getValue().getPort();
        }
        return null;
    }

    // ================= 活动日志 =================

    private void addActivity(String kind, boolean incoming, String title, String detail, boolean failed) {
        synchronized (activityLog) {
            activityLog.addFirst(new ActivityItem(kind, incoming, title, detail, failed));
            while (activityLog.size() > 100) activityLog.removeLast();
        }
        postEvent(() -> listener.onActivityChanged());
    }

    // ================= 事件桥 =================

    private class DiscoveryListenerImpl implements DiscoveryManager.Listener {
        @Override public void onDiscoveredChanged() {
            postEvent(() -> listener.onDiscoveredChanged());
        }
        @Override public void onLog(String line) { postLog(line); }
    }

    private class TransfersHost implements Transfers.Host {
        @Override public void sendTo(PeerLink link, Protocol.Msg m) throws Exception {
            link.sendSealed(m);
        }
        @Override public void postEngine(Runnable r) { runOnEngine(r); }
        @Override public void postIo(Runnable r) { transfersIo.execute(r); }
        @Override public PeerLink linkFor(String fp) { return connections.get(fp); }
    }

    private final ExecutorService transfersIo = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "protosync-io");
        t.setDaemon(true);
        return t;
    });

    private class TransfersEvents implements Transfers.Events {
        @Override public void onTransferStarted(String id, String name, boolean incomingDir) {
            addActivity("file", incomingDir, name, incomingDir ? "接收中…" : "发送中…", false);
            postEvent(() -> listener.onTransferStarted(id, name, incomingDir));
        }
        @Override public void onTransferProgress(String id, String name, double fraction, boolean incomingDir) {
            postEvent(() -> listener.onTransferProgress(id, name, fraction, incomingDir));
        }
        @Override public void onTransferFinished(String id, String name, boolean ok, String error,
                                                 boolean incomingDir, String savedPath, String savedUri) {
            String detail;
            if (!ok) detail = "失败: " + error;
            else if (incomingDir) detail = "已保存 " + (savedPath != null ? savedPath : "");
            else detail = "发送完成";
            addActivity("file", incomingDir, name, detail, !ok);
            postEvent(() -> listener.onTransferFinished(id, name, ok, error, incomingDir, savedPath, savedUri));
        }
    }
}
