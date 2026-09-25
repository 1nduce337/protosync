package com.protosync.core;

import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.security.KeyPair;
import java.security.PrivateKey;

/**
 * 单条设备间连接:TCP → 明文握手(hello/auth)→ AEAD 加密帧。
 *
 * 线程约定(由 SyncCore 保证):
 * - 握手裁决、状态推进、控制帧发送只发生在引擎线程;
 * - 文件分块由传输 I/O 线程发送,与控制帧共用 sendLock(计数器分配+写入同一临界区,
 *   保证 nonce 单调且密文顺序与计数器一致);
 * - reader 线程只做阻塞读,把整帧投递给 FrameSink(SyncCore 转发到引擎线程按序处理)。
 */
public final class PeerLink {
    public interface FrameSink {
        void onFrame(PeerLink link, byte[] payload);
        void onReadFailure(PeerLink link, Exception e);
    }
    /** decide 必须把裁决结果投递回引擎线程,再调 link.decidePairing(...)。 */
    public interface PairingPolicy { void decide(PeerLink link, String name, String fp); }
    public interface Events {
        void established(PeerLink link);
        void closed(PeerLink link, String reason);
    }

    public final Role role;
    public final long createdAt = System.currentTimeMillis();

    private final Socket socket;
    private final DataInputStream in;
    private final OutputStream out;
    private final FrameSink frameSink;
    private final Events events;
    private final IdentityStore identity;
    private final PairingPolicy pairingPolicy;
    private final Object sendLock = new Object();

    private volatile boolean established = false;
    private volatile boolean closed = false;
    private volatile long lastInboundAt = System.currentTimeMillis();

    private KeyPair myEph;
    private Crypto.Channel channel;
    private byte[] transcript64;
    private String peerFp, peerName;
    private byte[] peerSign64, peerDh64, peerEph64;
    private JSONObject pendingAuth;      // 对端 auth 先于本端配对裁决到达时缓冲
    private boolean pairingDecided = false;
    private boolean authSent = false;
    private long pairingDecidedAt = createdAt;
    /** 出站拨号时期望的对端指纹(NSD 记录可能过期指向别的设备);null = 不校验。 */
    private volatile String expectedFp;

    public PeerLink(Socket socket, Role role, IdentityStore identity,
                    PairingPolicy pairingPolicy, FrameSink frameSink, Events events) throws IOException {
        this.socket = socket;
        this.role = role;
        this.identity = identity;
        this.pairingPolicy = pairingPolicy;
        this.frameSink = frameSink;
        this.events = events;
        this.in = new DataInputStream(new BufferedInputStream(socket.getInputStream()));
        this.out = socket.getOutputStream();
    }

    // ================= 状态查询 =================

    public boolean isEstablished() { return established; }
    public boolean isClosed() { return closed; }
    public boolean pairingDecided() { return pairingDecided; }
    public String peerFingerprint() { return peerFp; }
    public String peerName() { return peerName; }
    public long lastInboundAt() { return lastInboundAt; }
    public long pairingDecidedAt() { return pairingDecidedAt; }
    public boolean awaitingDecision() { return peerFp != null && !pairingDecided; }
    public InetSocketAddress remoteAddress() { return (InetSocketAddress) socket.getRemoteSocketAddress(); }
    public void setExpectedFingerprint(String fp) { this.expectedFp = fp; }
    public String expectedFingerprint() { return expectedFp; }

    /** established 后解密一帧(引擎线程调用)。 */
    public JSONObject openSealed(byte[] payload) throws Exception {
        return channel.open(payload);
    }

    // ================= 生命周期 =================

    public void start() {
        Thread t = new Thread(this::readLoop, "conn-" + role.name().toLowerCase(java.util.Locale.US));
        t.setDaemon(true);
        t.start();
    }

    private void readLoop() {
        try {
            socket.setSoTimeout(10_000); // 静默 TCP 客户端不得永久占用线程
            while (!closed) {
                int maxFrame = established ? Protocol.MAX_ESTABLISHED_FRAME : Protocol.MAX_HANDSHAKE_FRAME;
                byte[] payload = Protocol.readFrame(in, maxFrame);
                lastInboundAt = System.currentTimeMillis();
                frameSink.onFrame(this, payload);
            }
        } catch (Exception e) {
            if (!closed) frameSink.onReadFailure(this, e);
        }
    }

    /** 只能在引擎线程调用;幂等。 */
    public void close(String reason) {
        if (closed) return;
        closed = true;
        try { socket.close(); } catch (IOException ignored) {}
        events.closed(this, reason);
    }

    // ================= 发送 =================

    public void sendHandshake(Protocol.Msg m) throws IOException {
        synchronized (sendLock) {
            Protocol.writeFrame(out, Protocol.frame(m));
        }
    }

    /** established 后使用;控制帧(引擎线程)与文件分块(I/O 线程)共用。 */
    public void sendSealed(Protocol.Msg m) throws Exception {
        synchronized (sendLock) {
            Protocol.writeFrame(out, Protocol.frame(channel.seal(m)));
        }
    }

    // ================= 握手(引擎线程)=================

    /** initiator 在 TCP 就绪后调用。 */
    public void sendHello() throws Exception {
        if (myEph == null) myEph = Crypto.generatePair();
        Protocol.Msg m = new Protocol.Msg()
                .put("type", Protocol.TYPE_HELLO)
                .put("fp", identity.fingerprint)
                .put("name", identity.deviceName())
                .put("signPub", Crypto.b64encodeToString(identity.signPub64))
                .put("dhPub", Crypto.b64encodeToString(identity.dhPub64))
                .put("eph", Crypto.b64encodeToString(Crypto.rawPublic(myEph)));
        sendHandshake(m);
    }

    /** 收到对端 hello:校验指纹、派生密钥、进入配对裁决。 */
    public void acceptHello(JSONObject m) throws Exception {
        if (peerFp != null) throw new IOException("重复 hello");
        byte[] signPub = Crypto.b64decode(m.getString("signPub"));
        byte[] dhPub = Crypto.b64decode(m.getString("dhPub"));
        byte[] eph = Crypto.b64decode(m.getString("eph"));
        String fp = m.getString("fp");
        String name = m.optString("name", "未知设备");
        if (!Crypto.fingerprint(signPub, dhPub).equals(fp))
            throw new SecurityException("指纹与公钥不匹配");
        if (fp.equals(identity.fingerprint)) throw new SecurityException("拒绝连接自己");

        if (myEph == null) myEph = Crypto.generatePair();
        peerFp = fp;
        peerName = name;
        peerSign64 = signPub;
        peerDh64 = dhPub;
        peerEph64 = eph;

        // 有效 hello 证明这不是静默 socket;配对有更长的等待窗口,关闭读超时
        socket.setSoTimeout(0);

        java.security.spec.ECParameterSpec spec = IdentityStore.ECParameterSpecHolder.INSTANCE;
        transcript64 = Crypto.transcript(role, identity.signPub64, identity.dhPub64,
                Crypto.rawPublic(myEph), peerSign64, peerDh64, peerEph64);
        byte[] sessionKeys = Crypto.sessionKeys(role, identity.dhPriv, myEph.getPrivate(),
                Crypto.publicFromRaw(peerDh64, spec), Crypto.publicFromRaw(peerEph64, spec),
                transcript64);
        channel = new Crypto.Channel(role, sessionKeys);

        if (role == Role.RESPONDER) sendHello();

        pairingPolicy.decide(this, peerName, peerFp);
    }

    /** 配对裁决入口(引擎线程):granted=true 发送 auth,拒绝则回 error 帧后关闭。 */
    public void decidePairing(boolean granted) {
        if (closed || pairingDecided) return;
        try {
            if (granted) grantPairing();
            else denyPairing();
        } catch (Exception e) {
            close(String.valueOf(e));
        }
    }

    private void grantPairing() throws Exception {
        pairingDecided = true;
        pairingDecidedAt = System.currentTimeMillis();
        sendHandshake(new Protocol.Msg()
                .put("type", Protocol.TYPE_AUTH)
                .put("sig", Crypto.b64encodeToString(Crypto.sign(identity.signPriv, transcript64))));
        authSent = true;
        JSONObject buffered = pendingAuth;
        pendingAuth = null;
        if (buffered != null) completeAuth(buffered);
    }

    private void denyPairing() throws Exception {
        pairingDecided = true;
        pairingDecidedAt = System.currentTimeMillis();
        try {
            sendHandshake(new Protocol.Msg()
                    .put("type", Protocol.TYPE_ERROR)
                    .put("error", "对方拒绝了配对请求"));
        } catch (IOException ignored) {}
        close("配对被拒绝");
    }

    /** 收到对端 auth:裁决未定时先缓冲,定时后补验。 */
    public void acceptAuth(JSONObject m) throws Exception {
        if (!pairingDecided || !authSent) { pendingAuth = m; return; }
        completeAuth(m);
    }

    private void completeAuth(JSONObject m) throws Exception {
        if (established || closed) return;
        byte[] sig = Crypto.b64decode(m.getString("sig"));
        if (!Crypto.verify(peerSign64, transcript64, sig, IdentityStore.ECParameterSpecHolder.INSTANCE))
            throw new SecurityException("签名验证失败");
        established = true;
        events.established(this);
    }

    public void sendErrorAndClose(String text) {
        try {
            sendHandshake(new Protocol.Msg().put("type", Protocol.TYPE_ERROR).put("error", text));
        } catch (IOException ignored) {}
        close(text);
    }
}
