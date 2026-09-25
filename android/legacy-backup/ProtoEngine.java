package com.protosync.app;

import android.content.ContentValues;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.MediaStore;
import android.util.Base64;
import android.webkit.MimeTypeMap;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.*;
import java.math.BigInteger;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.security.interfaces.ECPrivateKey;
import java.security.interfaces.ECPublicKey;

import java.security.spec.ECGenParameterSpec;
import java.security.spec.ECParameterSpec;
import java.security.spec.ECPoint;
import java.security.spec.ECPrivateKeySpec;
import java.security.spec.ECPublicKeySpec;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

import javax.crypto.Cipher;
import javax.crypto.KeyAgreement;
import javax.crypto.Mac;
import javax.crypto.SecretKey;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;

/**
 * ProtoSync 协议核心(与 macOS Swift 端逐字节对齐):
 * 分帧 = 4字节大端长度 + JSON;握手 = 双向 hello + ECDSA auth(签名 64B r||s 线格式);
 * 会话密钥 = HKDF(eph×eph ‖ eph×static ‖ static×eph, salt=transcriptHash);
 * 载荷 = ChaCha20-Poly1305,nonce = 4零字节 + 8字节大端计数器,方向独立密钥。
 */
public class ProtoEngine {
    public interface DecisionCallback { void decide(boolean accept); }

    public interface Delegate {
        void postLog(String line);
        void onPeerConnected(String name, String fp);
        void onPeerDisconnected(String fp, String error);
        void onPairingRequested(String name, String fp, DecisionCallback cb);
        void onClipboardText(String text);
        void onDiscoveredChanged();
        void onFileEvent(String line);
    }

    private static final String TAG_SIGN = "sign", TAG_DH = "dh";
    private static final int CHUNK = 192 * 1024;
    private static final int WINDOW = 16;
    public static final String SERVICE_TYPE = "_protosync._tcp.";

    public final Delegate delegate;
    private final Context context;
    private final NsdManager nsd;
    private final Object lock = new Object();

    private ECParameterSpec ecSpec;
    private PrivateKey signPriv, dhPriv;
    private byte[] signPubRaw, dhPubRaw; // 64B X||Y
    private String myName;
    public String fingerprint;

    private final Map<String, PeerConn> connections = new LinkedHashMap<>(); // fp -> 已建立连接
    private final List<PeerConn> pending = new ArrayList<>();                // 握手中(含配对未决)
    private final Map<String, NsdServiceInfo> discovered = new LinkedHashMap<>(); // serviceName -> info(已解析)
    private final Map<String, Long> seen = new ConcurrentHashMap<>();
    private final Map<String, OutgoingTransfer> outgoing = new HashMap<>();
    private final Map<String, IncomingTransfer> incoming = new HashMap<>();
    private final List<String[]> paired = new ArrayList<>(); // {fp, name}
    private final Map<String, String> lastAddr = new HashMap<>(); // fp -> host:port 缓存
    private ServerSocket serverSocket;
    private final ScheduledExecutorService heartbeat = Executors.newSingleThreadScheduledExecutor(r -> {
        Thread t = new Thread(r, "heartbeat");
        t.setDaemon(true);
        return t;
    });
    private final Map<String, Long> connectAttempts = new HashMap<>();
    private NsdManager.RegistrationListener regListener;
    private NsdManager.DiscoveryListener discListener;
    private volatile boolean running = false;
    public boolean autoAcceptPairing = false;

    public ProtoEngine(Context ctx, NsdManager nsd, Delegate delegate) {
        this.context = ctx;
        this.nsd = nsd;
        this.delegate = delegate;
    }

    private void log(String line) { delegate.postLog(line); }

    // ================= 身份 =================

    public void initIdentity(String deviceName) throws Exception {
        myName = deviceName;
        AlgorithmParameters ap = AlgorithmParameters.getInstance("EC");
        ap.init(new ECGenParameterSpec("secp256r1"));
        ecSpec = ap.getParameterSpec(ECParameterSpec.class);

        File keyFile = new File(new File(context.getFilesDir(), "identity"), "device.key");
        if (keyFile.exists()) {
            try {
                // 布局:signPriv 32B || dhPriv 32B || signPub 64B || dhPub 64B = 192B
                // (JCA 无法从裸私钥导出公钥,公钥一并持久化)
                byte[] blob = readAll(keyFile);
                if (blob.length == 192) {
                    signPriv = privFromRaw(sub(blob, 0, 32));
                    dhPriv = privFromRaw(sub(blob, 32, 64));
                    signPubRaw = sub(blob, 64, 128);
                    dhPubRaw = sub(blob, 128, 192);
                }
            } catch (Exception e) { signPriv = null; }
        }
        if (signPriv == null) {
            keyFile.getParentFile().mkdirs();
            KeyPair sign = genPair();
            KeyPair dh = genPair();
            signPriv = sign.getPrivate();
            dhPriv = dh.getPrivate();
            signPubRaw = rawPub(sign);
            dhPubRaw = rawPub(dh);
            writeAll(keyFile, concat(concat(to32(signPriv), to32(dhPriv)), concat(signPubRaw, dhPubRaw)));
        }
        fingerprint = makeFingerprint(signPubRaw, dhPubRaw);
        loadPaired();
        loadLastAddr();
    }

    private static KeyPair genPair() throws Exception {
        KeyPairGenerator kpg = KeyPairGenerator.getInstance("EC");
        kpg.initialize(new ECGenParameterSpec("secp256r1"));
        return kpg.generateKeyPair();
    }

    private PrivateKey privFromRaw(byte[] raw32) throws Exception {
        KeyFactory kf = KeyFactory.getInstance("EC");
        return kf.generatePrivate(new ECPrivateKeySpec(new BigInteger(1, raw32), ecSpec));
    }

    private static byte[] rawPub(KeyPair kp) {
        ECPublicKey pub = (ECPublicKey) kp.getPublic();
        return concat(to32(pub.getW().getAffineX()), to32(pub.getW().getAffineY()));
    }

    public static String makeFingerprint(byte[] signPub, byte[] dhPub) {
        return hex(sha256(concat(signPub, dhPub)));
    }

    // ================= 加密通道 =================

    private static class Channel {
        SecretKey sendKey, recvKey;
        long sendCounter = 0;
        long recvCounter = 0;
    }

    private byte[] transcriptFor(Role role, byte[] peerSignPub, byte[] peerDhPub,
                                 byte[] myEphPub, byte[] peerEphPub) {
        byte[] initSign, initDh, initEph, respSign, respDh, respEph;
        if (role == Role.INITIATOR) {
            initSign = signPubRaw; initDh = dhPubRaw; initEph = myEphPub;
            respSign = peerSignPub; respDh = peerDhPub; respEph = peerEphPub;
        } else {
            respSign = signPubRaw; respDh = dhPubRaw; respEph = myEphPub;
            initSign = peerSignPub; initDh = peerDhPub; initEph = peerEphPub;
        }
        MessageDigest md = messageDigest();
        md.update("ProtoSync-v1".getBytes(StandardCharsets.UTF_8));
        md.update(initSign); md.update(initDh); md.update(initEph);
        md.update(respSign); md.update(respDh); md.update(respEph);
        return md.digest();
    }

    private Channel deriveChannel(Role role, byte[] peerSignPub, byte[] peerDhPub,
                                  KeyPair myEph, byte[] peerEphRaw) throws Exception {
        byte[] myEphPub = rawPub(myEph);
        KeyFactory kf = KeyFactory.getInstance("EC");
        PublicKey peerEphPubKey = kf.generatePublic(new ECPublicKeySpec(point(peerEphRaw), ecSpec));
        PublicKey peerDhPubKey = kf.generatePublic(new ECPublicKeySpec(point(peerDhPub), ecSpec));

        byte[] ss1 = ecdh(myEph.getPrivate(), peerEphPubKey);
        byte[] ss2 = role == Role.INITIATOR ? ecdh(myEph.getPrivate(), peerDhPubKey) : ecdh(dhPriv, peerEphPubKey);
        byte[] ss3 = role == Role.INITIATOR ? ecdh(dhPriv, peerEphPubKey) : ecdh(myEph.getPrivate(), peerDhPubKey);

        byte[] transcript = transcriptFor(role, peerSignPub, peerDhPub, myEphPub, peerEphRaw);
        byte[] okm = hkdf(concat(concat(ss1, ss2), ss3), transcript, "protosync-keys".getBytes(StandardCharsets.UTF_8), 64);
        SecretKey c2sKey = new SecretKeySpec(sub(okm, 0, 32), "ChaCha20");
        SecretKey s2cKey = new SecretKeySpec(sub(okm, 32, 64), "ChaCha20");
        Channel ch = new Channel();
        // The HKDF output is directional. A responder sends on S->C and
        // receives on C->S; using the initiator mapping for both roles makes
        // the first encrypted frame fail authentication when the Mac dials us.
        ch.sendKey = role == Role.INITIATOR ? c2sKey : s2cKey;
        ch.recvKey = role == Role.INITIATOR ? s2cKey : c2sKey;
        return ch;
    }

    private static byte[] ecdh(PrivateKey priv, PublicKey peerPub) throws Exception {
        KeyAgreement ka = KeyAgreement.getInstance("ECDH");
        ka.init(priv);
        ka.doPhase(peerPub, true);
        return to32(new BigInteger(1, ka.generateSecret()));
    }

    private static byte[] hkdf(byte[] ikm, byte[] salt, byte[] info, int len) throws Exception {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(salt, "HmacSHA256"));
        byte[] prk = mac.doFinal(ikm);
        byte[] okm = new byte[len];
        byte[] t = new byte[0];
        int done = 0;
        byte counter = 1;
        while (done < len) {
            mac.init(new SecretKeySpec(prk, "HmacSHA256"));
            mac.update(t);
            mac.update(info);
            mac.update(counter++);
            t = mac.doFinal();
            int n = Math.min(32, len - done);
            System.arraycopy(t, 0, okm, done, n);
            done += n;
        }
        return okm;
    }

    private static byte[] nonceFor(long counter) {
        byte[] n = new byte[12];
        for (int i = 0; i < 8; i++) n[4 + i] = (byte) (counter >>> (56 - 8 * i));
        return n;
    }

    private static byte[] seal(Channel ch, JSONObject m) throws Exception {
        byte[] plain = m.toString().getBytes(StandardCharsets.UTF_8);
        byte[] nonce = nonceFor(ch.sendCounter);
        Cipher cipher = Cipher.getInstance("ChaCha20-Poly1305");
        cipher.init(Cipher.ENCRYPT_MODE, ch.sendKey, new IvParameterSpec(nonce));
        byte[] ct = cipher.doFinal(plain); // ciphertext || tag(16)
        ch.sendCounter++;
        byte[] out = new byte[12 + ct.length];
        System.arraycopy(nonce, 0, out, 0, 12);
        System.arraycopy(ct, 0, out, 12, ct.length);
        return out;
    }

    private static JSONObject open(Channel ch, byte[] frame) throws Exception {
        if (frame.length <= 28) throw new IOException("密文帧过短");
        byte[] nonce = sub(frame, 0, 12);
        if (!MessageDigest.isEqual(nonce, nonceFor(ch.recvCounter)))
            throw new SecurityException("密文 nonce 次序异常");
        Cipher cipher = Cipher.getInstance("ChaCha20-Poly1305");
        cipher.init(Cipher.DECRYPT_MODE, ch.recvKey, new IvParameterSpec(nonce));
        byte[] plain = cipher.doFinal(sub(frame, 12, frame.length));
        ch.recvCounter++;
        return new JSONObject(new String(plain, StandardCharsets.UTF_8));
    }

    // ---- ECDSA:Swift 端线格式是 64B r||s;Java 是 DER,互转 ----

    private byte[] signTranscript(byte[] transcript) throws Exception {
        Signature sig = Signature.getInstance("SHA256withECDSA");
        sig.initSign(signPriv);
        sig.update(transcript);
        return derToRaw(sig.sign());
    }

    private boolean verifyRawSig(byte[] peerSignPub, byte[] transcript, byte[] rawSig64) throws Exception {
        KeyFactory kf = KeyFactory.getInstance("EC");
        PublicKey pub = kf.generatePublic(new ECPublicKeySpec(point(peerSignPub), ecSpec));
        Signature sig = Signature.getInstance("SHA256withECDSA");
        sig.initVerify(pub);
        sig.update(transcript);
        return sig.verify(rawToDer(rawSig64));
    }

    private static byte[] derToRaw(byte[] der) {
        int i = 2;
        int rLen = der[i + 1] & 0xff;
        byte[] r = sub(der, i + 2, i + 2 + rLen);
        int j = i + 2 + rLen;
        int sLen = der[j + 1] & 0xff;
        byte[] s = sub(der, j + 2, j + 2 + sLen);
        return concat(pad32(r), pad32(s));
    }

    private static byte[] rawToDer(byte[] raw64) {
        byte[] body = concat(derInt(sub(raw64, 0, 32)), derInt(sub(raw64, 32, 64)));
        return concat(new byte[]{0x30, (byte) body.length}, body);
    }

    /** INTEGER + 长度;最高位为 1 时按 DER 规范补 0x00 前缀(否则约 75% 签名验证失败)。 */
    private static byte[] derInt(byte[] v) {
        int i = 0;
        while (i < v.length - 1 && v[i] == 0) i++;
        byte[] u = sub(v, i, v.length);
        byte[] body = (u[0] & 0x80) != 0 ? concat(new byte[]{0x00}, u) : u;
        return concat(new byte[]{0x02, (byte) body.length}, body);
    }

    private static byte[] stripLeadingZero(byte[] v) {
        int i = 0;
        while (i < v.length - 1 && v[i] == 0) i++;
        return sub(v, i, v.length);
    }

    private static byte[] pad32(byte[] v) {
        // DER 整数带 0x00 高位填充时(约75%的签名),必须从左侧裁剪对齐,
        // 旧实现 arraycopy 前32字节会把填充零保留、丢掉最后一个有效字节。
        int i = 0;
        while (i < v.length - 1 && v[i] == 0) i++;
        byte[] u = sub(v, i, v.length);
        byte[] out = new byte[32];
        System.arraycopy(u, 0, out, 32 - Math.min(32, u.length), Math.min(32, u.length));
        return out;
    }

    // ================= 消息 =================

    private static JSONObject msg(String type) { return new JSONObject(); }

    private JSONObject helloMessage(KeyPair eph) throws Exception {
        return new JSONObject()
                .put("type", "hello")
                .put("fp", fingerprint)
                .put("name", myName)
                .put("signPub", Base64.encodeToString(signPubRaw, Base64.NO_WRAP))
                .put("dhPub", Base64.encodeToString(dhPubRaw, Base64.NO_WRAP))
                .put("eph", Base64.encodeToString(rawPub(eph), Base64.NO_WRAP));
    }

    // ================= 连接 =================

    enum Role { INITIATOR, RESPONDER }

    private class PeerConn {
        Socket socket;
        DataInputStream in;
        OutputStream out;
        Role role;
        Channel channel;
        byte[] channelTranscript;
        String peerFp, peerName;
        byte[] peerSignPub, peerDhPub, peerEphPub;
        KeyPair myEph;
        volatile boolean established = false, closed = false;
        volatile long lastInboundAt = System.currentTimeMillis();
        final long createdAt = System.currentTimeMillis();
        JSONObject pendingAuth; // 配对裁决前收到的对端 auth,裁决后补验
        boolean pairingDecided = false;
        long pairingDecidedAt = createdAt;
        boolean authSent = false;
        boolean authInProgress = false;
        private final Object sendLock = new Object();

        /** 入参必须是已含 4 字节长度前缀的完整帧(frame()/seal 包装产物),不再二次加前缀。 */
        void sendFrame(byte[] framed) throws IOException {
            synchronized (sendLock) {
                out.write(framed);
                out.flush();
            }
        }

        void sendJson(JSONObject m) throws IOException {
            sendFrame(frame(m.toString().getBytes(StandardCharsets.UTF_8)));
        }

        void sendSealed(JSONObject m) throws Exception {
            // Counter allocation and socket write must be one critical section.
            // Otherwise heartbeat/file/UI threads can reuse a nonce or reorder
            // ciphertexts relative to their monotonically increasing counters.
            synchronized (sendLock) {
                byte[] framed = frame(seal(channel, m));
                out.write(framed);
                out.flush();
            }
        }

        void close(String err) {
            synchronized (this) {
                if (closed) return;
                closed = true;
            }
            try { socket.close(); } catch (IOException ignored) {}
            synchronized (lock) { pending.remove(this); }
            String fp = peerFp;
            if (fp != null) {
                boolean wasRegistered;
                synchronized (lock) {
                    wasRegistered = connections.get(fp) == this;
                    if (wasRegistered) connections.remove(fp);
                }
                // 只有登记连接的断开才上报;被收敛淘汰的败者静默消失
                if (wasRegistered) {
                    cancelTransfersForPeer(fp, err == null ? "连接已关闭" : err);
                    delegate.onPeerDisconnected(fp, err);
                }
            }
        }
    }

    public void start() throws Exception {
        if (running) return;
        running = true;
        // 固定端口 52526(与 Mac 端 52525 对称):重启地址不变,手动连接/对端重连才可靠
        try {
            serverSocket = new ServerSocket(52526, 50, InetAddress.getByName("0.0.0.0"));
        } catch (IOException bindFailed) {
            serverSocket = new ServerSocket(0, 50, InetAddress.getByName("0.0.0.0"));
        }
        heartbeat.scheduleAtFixedRate(() -> {
            try { heartbeatTick(); }
            catch (Throwable e) { log("心跳任务异常: " + e.getMessage()); }
        }, 5, 5, TimeUnit.SECONDS);
        Thread t = new Thread(this::acceptLoop, "accept");
        t.setDaemon(true);
        t.start();
        advertise();
        browse();
        log("引擎已启动,端口 " + serverSocket.getLocalPort());
    }

    public void stop() {
        running = false;
        heartbeat.shutdownNow();
        try { serverSocket.close(); } catch (Exception ignored) {}
        List<PeerConn> toClose = new ArrayList<>();
        synchronized (lock) {
            toClose.addAll(connections.values());
            for (PeerConn c : pending) if (!toClose.contains(c)) toClose.add(c);
        }
        // Never call close while holding lock: close itself removes from the
        // maps and takes the per-connection monitor.
        for (PeerConn c : toClose) c.close(null);
        synchronized (lock) { connections.clear(); pending.clear(); }
        unadvertise();
        unbrowse();
    }

    public int listeningPort() { return serverSocket != null ? serverSocket.getLocalPort() : 0; }

    private void acceptLoop() {
        while (running) {
            try {
                Socket s = serverSocket.accept();
                PeerConn c = new PeerConn();
                c.socket = s;
                c.in = new DataInputStream(new BufferedInputStream(s.getInputStream()));
                c.out = s.getOutputStream();
                c.role = Role.RESPONDER;
                s.setSoTimeout(10_000); // a silent TCP client must not hold a thread forever
                synchronized (lock) { pending.add(c); }
                spawnReader(c);
            } catch (IOException e) {
                if (running) log("accept 失败: " + e.getMessage());
            }
        }
    }

    public void connectTo(InetAddress host, int port) {
        new Thread(() -> {
            try {
                Socket s = new Socket();
                s.connect(new InetSocketAddress(host, port), 5000);
                PeerConn c = new PeerConn();
                c.socket = s;
                c.in = new DataInputStream(new BufferedInputStream(s.getInputStream()));
                c.out = s.getOutputStream();
                c.role = Role.INITIATOR;
                s.setSoTimeout(10_000);
                synchronized (lock) { pending.add(c); }
                spawnReader(c);
            } catch (IOException e) {
                log("连接 " + host.getHostAddress() + ":" + port + " 失败: " + e.getMessage());
            }
        }, "connect").start();
    }

    private void spawnReader(PeerConn c) {
        Thread t = new Thread(() -> connLoop(c), "conn-" + c.role);
        t.setDaemon(true);
        t.start();
    }

    private void connLoop(PeerConn c) {
        try {
            c.myEph = genPair();
            if (c.role == Role.INITIATOR) c.sendJson(helloMessage(c.myEph));
            while (!c.closed) {
                int len = c.in.readInt();
                int maxFrame = c.established ? 16 * 1024 * 1024 : 64 * 1024;
                if (len <= 0 || len > maxFrame) throw new IOException("帧长度异常: " + len);
                byte[] payload = new byte[len];
                c.in.readFully(payload);
                c.lastInboundAt = System.currentTimeMillis();
                if (c.established) {
                    handleEstablished(c, open(c.channel, payload));
                } else {
                    handleHandshake(c, new JSONObject(new String(payload, StandardCharsets.UTF_8)));
                }
            }
        } catch (Throwable e) {
            if (c.closed) return;
            StringWriter sw = new StringWriter();
            e.printStackTrace(new PrintWriter(sw));
            String trace = sw.toString();
            if (trace.length() > 1500) trace = trace.substring(0, 1500);
            log("连接异常: " + e + "\n" + trace);
            c.close(String.valueOf(e));
        }
    }

    private static byte[] frame(byte[] payload) {
        byte[] out = new byte[4 + payload.length];
        out[0] = (byte) (payload.length >>> 24);
        out[1] = (byte) (payload.length >>> 16);
        out[2] = (byte) (payload.length >>> 8);
        out[3] = (byte) payload.length;
        System.arraycopy(payload, 0, out, 4, payload.length);
        return out;
    }

    private void handleHandshake(PeerConn c, JSONObject m) {
        try {
            String type = m.getString("type");
            if ("hello".equals(type)) {
                byte[] signPub = Base64.decode(m.getString("signPub"), Base64.NO_WRAP);
                byte[] dhPub = Base64.decode(m.getString("dhPub"), Base64.NO_WRAP);
                byte[] eph = Base64.decode(m.getString("eph"), Base64.NO_WRAP);
                String fp = m.getString("fp");
                if (!makeFingerprint(signPub, dhPub).equals(fp))
                    throw new SecurityException("指纹与公钥不匹配");
                if (fp.equals(fingerprint)) throw new SecurityException("拒绝连接自己");
                c.peerFp = fp;
                c.peerName = m.optString("name", "未知设备");
                c.peerSignPub = signPub;
                c.peerDhPub = dhPub;
                c.peerEphPub = eph;
                synchronized (lock) { if (!pending.contains(c)) pending.add(c); }
                // A valid hello proves this is not a silent socket. Pairing has
                // its own longer timeout below, so disable the read timeout.
                c.socket.setSoTimeout(0);
                c.channel = deriveChannel(c.role, signPub, dhPub, c.myEph, eph);
                c.channelTranscript = transcriptFor(c.role, signPub, dhPub,
                        rawPub(c.myEph), eph);
                if (c.role == Role.RESPONDER) c.sendJson(helloMessage(c.myEph));
                synchronized (c) { c.pairingDecided = false; }
                if (isPaired(fp)) {
                    synchronized (c) {
                        c.pairingDecided = true;
                        c.pairingDecidedAt = System.currentTimeMillis();
                    }
                    grantPairing(c);
                } else if (autoAcceptPairing) {
                    addPaired(fp, c.peerName);
                    synchronized (c) {
                        c.pairingDecided = true;
                        c.pairingDecidedAt = System.currentTimeMillis();
                    }
                    grantPairing(c);
                } else {
                    delegate.onPairingRequested(c.peerName, fp, accept ->
                        new Thread(() -> {
                            synchronized (c) {
                                if (c.closed || c.pairingDecided) return;
                                c.pairingDecided = true;
                                c.pairingDecidedAt = System.currentTimeMillis();
                            }
                            if (accept) {
                                addPaired(fp, c.peerName);
                                try { grantPairing(c); } catch (Exception e) { c.close(e.getMessage()); }
                            } else {
                                try { c.sendJson(new Msg().put("type", "error").put("error", "对方拒绝了配对请求")); } catch (IOException ignored) {}
                                c.close("配对被拒绝");
                            }
                        }, "pair-reply").start());
                }
            } else if ("auth".equals(type)) {
                synchronized (c) {
                    if (!c.pairingDecided || !c.authSent) { c.pendingAuth = m; return; } // 对端 auth 先于本端裁决到达,缓冲
                }
                completeAuth(c, m);
            } else if ("error".equals(type)) {
                c.close(m.optString("error", "对端报错"));
            } else {
                throw new IOException("意外握手消息: " + type);
            }
        } catch (Exception e) {
            c.close(e.getMessage());
        }
    }

    private void grantPairing(PeerConn c) throws Exception {
        c.sendJson(new Msg().put("type", "auth")
                .put("sig", Base64.encodeToString(signTranscript(c.channelTranscript), Base64.NO_WRAP)));
        JSONObject buffered;
        synchronized (c) {
            c.authSent = true;
            buffered = c.pendingAuth;
            c.pendingAuth = null;
        }
        if (buffered != null) completeAuth(c, buffered);
    }

    private void completeAuth(PeerConn c, JSONObject m) throws Exception {
        synchronized (c) {
            if (c.established || c.authInProgress) return;
            c.authInProgress = true;
        }
        try {
            byte[] sig = Base64.decode(m.getString("sig"), Base64.NO_WRAP);
            if (!verifyRawSig(c.peerSignPub, c.channelTranscript, sig))
                throw new SecurityException("签名验证失败");
        } catch (Exception e) {
            synchronized (c) { c.authInProgress = false; }
            throw e;
        }
        synchronized (c) {
            if (c.closed) { c.authInProgress = false; return; }
            c.established = true;
        }
        boolean notify, accepted;
        PeerConn loser = null;
        synchronized (lock) {
            // This connection is no longer handshaking. Leaving it in pending
            // makes heartbeatTick close a healthy connection as a 10s timeout.
            pending.remove(c);
            PeerConn existing = connections.get(c.peerFp);
            if (c.closed) {
                accepted = false;
                notify = false;
            } else if (existing != null && existing != c) {
                // 双向同时各建一条:双方按同一规则收敛——fp 较小一方发起的连接获胜
                Role preferred = fingerprint.compareTo(c.peerFp) < 0 ? Role.INITIATOR : Role.RESPONDER;
                if (c.role == preferred) {
                    connections.put(c.peerFp, c);
                    loser = existing;
                    accepted = true;
                    notify = false; // replacing a live path is not a new online event
                } else {
                    loser = c;
                    accepted = false;
                    notify = false;
                }
            } else {
                connections.put(c.peerFp, c);
                accepted = true;
                notify = true;
            }
        }
        if (loser != null) loser.close(loser == c ? "重复连接" : "被新连接替换");
        if (!accepted) return;
        rememberPeerAddress(c);
        if (notify) {
            log("✅ 已连接 " + c.peerName);
            delegate.onPeerConnected(c.peerName, c.peerFp);
        }
    }

    private void handleEstablished(PeerConn c, JSONObject m) {
        try {
            switch (m.getString("type")) {
                case "clipboard": {
                    // seenPut returns true only for a new/expired hash.
                    if (!seenPut(m.getString("hash"))) return;
                    if ("text".equals(m.optString("kind"))) {
                        String text = m.getString("data");
                        log("📋 收到文本 " + text.length() + " 字");
                        delegate.onClipboardText(text);
                    }
                    break;
                }
                case "file_offer": handleFileOffer(c, m); break;
                case "file_chunk": handleFileChunk(c, m); break;
                case "file_done": handleFileDone(c, m); break;
                case "file_ack": handleFileAck(m); break;
                case "ping": break; // 判活只看 lastInboundAt
                default: break;
            }
        } catch (Throwable e) {
            StringWriter sw = new StringWriter();
            e.printStackTrace(new PrintWriter(sw));
            log("消息处理失败: " + e + "\n" + sw);
        }
    }

    // ================= 剪贴板 =================

    public boolean seenHas(String hash) {
        Long t = seen.get(hash);
        if (t == null) return false;
        if (System.currentTimeMillis() - t < 300_000) return true;
        seen.remove(hash, t);
        return false;
    }

    public boolean seenPut(String hash) {
        long now = System.currentTimeMillis();
        Long previous = seen.put(hash, now);
        boolean fresh = previous == null || now - previous >= 300_000;
        if (seen.size() > 512) {
            long cutoff = now - 300_000;
            seen.entrySet().removeIf(e -> e.getValue() < cutoff);
            if (seen.size() > 512) {
                List<Map.Entry<String, Long>> oldest = new ArrayList<>(seen.entrySet());
                oldest.sort(Comparator.comparingLong(Map.Entry::getValue));
                for (int i = 0; i < oldest.size() - 512; i++)
                    seen.remove(oldest.get(i).getKey(), oldest.get(i).getValue());
            }
        }
        return fresh;
    }

    public String textHash(String text) {
        return hex(sha256(text.getBytes(StandardCharsets.UTF_8)));
    }

    public void broadcastText(String text) {
        seenPut(textHash(text));
        JSONObject m = new Msg().put("type", "clipboard").put("kind", "text")
                .put("data", text).put("hash", textHash(text));
        synchronized (lock) {
            for (PeerConn c : connections.values()) {
                try { c.sendSealed(m); } catch (Exception e) { log("发送失败: " + e.getMessage()); }
            }
        }
    }

    // ================= 文件 =================

    private static class OutgoingTransfer {
        String id, name; long size; InputStream input; int nextIndex = 0, inFlight = 0; boolean doneSent = false;
        String targetFp;
    }

    private static class IncomingTransfer {
        String id, name, sha; long size, received = 0; int chunks = 0;
        String sourceFp;
        FileOutputStream fos; File file;
    }

    /** Hash and stream a content URI without retaining the whole file in memory. */
    public void sendFile(String fp, String name, Uri uri) {
        PeerConn c;
        synchronized (lock) { c = connections.get(fp); }
        if (c == null) { delegate.onFileEvent("设备不在线"); return; }
        InputStream hashing = null;
        InputStream sending = null;
        long size = 0;
        String sha;
        try {
            MessageDigest digest = messageDigest();
            hashing = context.getContentResolver().openInputStream(uri);
            if (hashing == null) throw new IOException("无法打开所选文件");
            byte[] buffer = new byte[1024 * 1024];
            int n;
            while ((n = hashing.read(buffer)) >= 0) {
                if (n == 0) continue;
                digest.update(buffer, 0, n);
                size += n;
            }
            hashing.close();
            hashing = null;
            sha = hex(digest.digest());
            sending = context.getContentResolver().openInputStream(uri);
            if (sending == null) throw new IOException("无法重新打开所选文件");
        } catch (Exception e) {
            try { if (hashing != null) hashing.close(); } catch (IOException ignored) {}
            try { if (sending != null) sending.close(); } catch (IOException ignored) {}
            delegate.onFileEvent("读取文件失败: " + e.getMessage());
            return;
        }
        String id = UUID.randomUUID().toString();
        OutgoingTransfer t = new OutgoingTransfer();
        t.id = id; t.name = safeFileName(name); t.size = size; t.input = sending; t.targetFp = fp;
        synchronized (lock) { outgoing.put(id, t); }
        try {
            c.sendSealed(new Msg().put("type", "file_offer").put("id", id)
                    .put("fileName", t.name).put("size", size).put("sha256", sha));
            delegate.onFileEvent("发送 " + t.name + " 开始");
        } catch (Exception e) {
            synchronized (lock) { outgoing.remove(id); }
            closeQuietly(t.input);
            delegate.onFileEvent("发送失败: " + e.getMessage());
        }
    }

    private void handleFileOffer(PeerConn c, JSONObject m) throws Exception {
        String id = m.optString("id", "");
        if (!id.matches("[A-Za-z0-9-]{1,80}")) {
            try {
                c.sendSealed(new Msg().put("type", "file_ack").put("id", id)
                        .put("accept", false).put("done", true));
            } catch (Exception ignored) {}
            return;
        }
        synchronized (lock) {
            if (incoming.containsKey(id) || outgoing.containsKey(id)) {
                c.sendSealed(new Msg().put("type", "file_ack").put("id", id)
                        .put("accept", false).put("done", true));
                return;
            }
        }
        IncomingTransfer t = new IncomingTransfer();
        try {
            t.id = id;
            t.name = safeFileName(m.getString("fileName"));
            t.size = m.getLong("size");
            if (t.size < 0) throw new IOException("文件大小无效");
            t.sha = m.getString("sha256");
            if (!t.sha.matches("[0-9a-fA-F]{64}")) throw new IOException("文件摘要无效");
            t.sourceFp = c.peerFp;
            File base = context.getExternalFilesDir(null);
            if (base == null) throw new IOException("外部存储不可用");
            File dir = new File(base, "ProtoSync");
            if (!dir.exists() && !dir.mkdirs()) throw new IOException("无法创建临时目录");
            t.file = File.createTempFile(".incoming-", ".part", dir);
            t.fos = new FileOutputStream(t.file);
            synchronized (lock) { incoming.put(t.id, t); }
            c.sendSealed(new Msg().put("type", "file_ack").put("id", t.id)
                    .put("accept", true).put("done", false));
            delegate.onFileEvent("接收 " + t.name + " 开始");
        } catch (Exception e) {
            closeQuietly(t.fos);
            if (t.file != null) t.file.delete();
            failIncoming(c, id, "无法接收文件: " + e.getMessage());
        }
    }

    private void handleFileChunk(PeerConn c, JSONObject m) throws Exception {
        String id = m.getString("id");
        IncomingTransfer t;
        synchronized (lock) { t = incoming.get(id); }
        if (t == null) return;
        try {
            int index = m.getInt("index");
            if (index != t.chunks) throw new IOException("文件分块次序异常");
            byte[] chunk = Base64.decode(m.getString("data"), Base64.NO_WRAP);
            if (t.received + chunk.length > t.size) throw new IOException("文件数据超过声明大小");
            t.fos.write(chunk);
            t.received += chunk.length;
            t.chunks++;
            if (t.chunks % WINDOW == 0)
                c.sendSealed(new Msg().put("type", "file_ack").put("id", t.id)
                        .put("accept", true).put("done", false));
            delegate.onFileEvent(String.format(Locale.US, "接收 %s %d%%", t.name,
                    t.size > 0 ? (int) (t.received * 100 / t.size) : 100));
        } catch (Exception e) {
            failIncoming(c, id, "接收失败: " + e.getMessage());
        }
    }

    private void handleFileDone(PeerConn c, JSONObject m) throws Exception {
        String id = m.getString("id");
        IncomingTransfer t;
        synchronized (lock) { t = incoming.get(id); }
        if (t == null) return;
        try {
            t.fos.close();
            if (t.received != t.size || !Arrays.equals(sha256File(t.file), sha256FromHex(t.sha))) {
                failIncoming(c, id, "接收 " + t.name + " 校验失败");
                return;
            }
            synchronized (lock) { incoming.remove(id); }
            File finalFile = saveReceived(t.file, t.name);
            c.sendSealed(new Msg().put("type", "file_ack").put("id", t.id)
                    .put("accept", true).put("done", true));
            delegate.onFileEvent("📦 已保存 " + finalFile.getAbsolutePath());
        } catch (Exception e) {
            failIncoming(c, id, "接收失败: " + e.getMessage());
        }
    }

    private void failIncoming(PeerConn c, String id, String reason) {
        IncomingTransfer t;
        synchronized (lock) { t = incoming.remove(id); }
        if (t != null) {
            closeQuietly(t.fos);
            if (t.file != null) t.file.delete();
        }
        try {
            c.sendSealed(new Msg().put("type", "file_ack").put("id", id)
                    .put("accept", false).put("done", true));
        } catch (Exception ignored) {}
        delegate.onFileEvent(reason);
    }

    private void cancelTransfersForPeer(String fp, String reason) {
        List<OutgoingTransfer> cancelledOut = new ArrayList<>();
        List<IncomingTransfer> cancelledIn = new ArrayList<>();
        synchronized (lock) {
            Iterator<Map.Entry<String, OutgoingTransfer>> oi = outgoing.entrySet().iterator();
            while (oi.hasNext()) {
                OutgoingTransfer t = oi.next().getValue();
                if (fp.equals(t.targetFp)) { cancelledOut.add(t); oi.remove(); }
            }
            Iterator<Map.Entry<String, IncomingTransfer>> ii = incoming.entrySet().iterator();
            while (ii.hasNext()) {
                IncomingTransfer t = ii.next().getValue();
                if (fp.equals(t.sourceFp)) { cancelledIn.add(t); ii.remove(); }
            }
        }
        for (OutgoingTransfer t : cancelledOut) {
            closeQuietly(t.input);
            delegate.onFileEvent("发送 " + t.name + " 失败: " + reason);
        }
        for (IncomingTransfer t : cancelledIn) {
            closeQuietly(t.fos);
            if (t.file != null) t.file.delete();
            delegate.onFileEvent("接收 " + t.name + " 失败: " + reason);
        }
    }

    private void handleFileAck(JSONObject m) {
        OutgoingTransfer t;
        synchronized (lock) { t = outgoing.get(m.optString("id")); }
        if (t == null) return;
        if (m.optBoolean("done")) {
            synchronized (lock) { outgoing.remove(t.id); }
            closeQuietly(t.input);
            delegate.onFileEvent(m.optBoolean("accept")
                    ? "发送 " + t.name + " 完成"
                    : "发送 " + t.name + " 失败: 接收方拒绝或校验失败");
            return;
        }
        if (!m.optBoolean("accept")) {
            synchronized (lock) { outgoing.remove(t.id); }
            closeQuietly(t.input);
            delegate.onFileEvent("发送 " + t.name + " 失败: 接收方拒绝");
            return;
        }
        t.inFlight = 0;
        pump(t);
    }

    private void pump(OutgoingTransfer t) {
        PeerConn c;
        synchronized (lock) { c = connections.get(t.targetFp); }
        if (c == null) {
            synchronized (lock) { outgoing.remove(t.id); }
            closeQuietly(t.input);
            delegate.onFileEvent("发送 " + t.name + " 失败: 设备已离线");
            return;
        }
        try {
            while (t.inFlight < WINDOW && (long) t.nextIndex * CHUNK < t.size) {
                long off = (long) t.nextIndex * CHUNK;
                int len = (int) Math.min(CHUNK, t.size - off);
                byte[] chunk = readExactly(t.input, len);
                if (chunk.length != len) throw new EOFException("源文件读取提前结束");
                c.sendSealed(new Msg().put("type", "file_chunk").put("id", t.id)
                        .put("index", t.nextIndex)
                        .put("data", Base64.encodeToString(chunk, Base64.NO_WRAP)));
                t.nextIndex++;
                t.inFlight++;
            }
            if ((long) t.nextIndex * CHUNK >= t.size && !t.doneSent) {
                t.doneSent = true;
                c.sendSealed(new Msg().put("type", "file_done").put("id", t.id));
            }
        } catch (Exception e) {
            synchronized (lock) { outgoing.remove(t.id); }
            closeQuietly(t.input);
            delegate.onFileEvent("发送失败: " + e.getMessage());
        }
    }

    /** 心跳:每 5s 双向 ping;15s 无入站帧即判死;顺带重连已配对的掉线设备。 */
    private void heartbeatTick() {
        long now = System.currentTimeMillis();
        // 握手超 10s 未建立的连接(对端不可达/AP隔离)清理,防泄漏
        List<PeerConn> pendingSnapshot;
        synchronized (lock) { pendingSnapshot = new ArrayList<>(pending); }
        for (PeerConn p : pendingSnapshot) {
            boolean awaitingUser;
            long timeoutBase;
            synchronized (p) {
                awaitingUser = p.peerFp != null && !p.pairingDecided;
                timeoutBase = p.pairingDecided ? p.pairingDecidedAt : p.createdAt;
            }
            long timeout = awaitingUser ? 120_000 : 10_000;
            if (!p.established && now - timeoutBase > timeout) p.close("握手超时");
        }
        List<PeerConn> conns;
        synchronized (lock) { conns = new ArrayList<>(connections.values()); }
        for (PeerConn c : conns) {
            if (now - c.lastInboundAt > 15_000) {
                c.close("心跳超时");
                continue;
            }
            if (c.established) {
                try { c.sendSealed(new Msg().put("type", "ping")); }
                catch (Exception e) { c.close("心跳发送失败"); }
            }
        }
        // 已配对但掉线的设备:重试发现缓存里的地址(5s 防抖)
        List<String[]> targets = new ArrayList<>();
        synchronized (lock) {
            for (String[] pd : paired) {
                String fp = pd[0];
                if (connections.containsKey(fp) || connections.keySet().stream().anyMatch(k -> k.startsWith(fp))) continue;
                if (pending.stream().anyMatch(p -> p.peerFp != null && p.peerFp.startsWith(fp))) continue;
                // 首选 NSD 实时地址;后台 NSD 失灵时退回缓存地址(手机出站方向通常可达)
                String addr = null;
                for (Map.Entry<String, NsdServiceInfo> e : discovered.entrySet()) {
                    if (fp.startsWith(serviceShortFp(e.getKey()))) {
                        NsdServiceInfo info = e.getValue();
                        if (info.getHost() != null && info.getPort() > 0)
                            addr = formatHostPort(info.getHost().getHostAddress(), info.getPort());
                        break;
                    }
                }
                if (addr == null) addr = lastAddr.get(fp);
                if (addr == null) continue;
                Long last = connectAttempts.get(fp);
                if (last != null && now - last < 5_000) continue;
                connectAttempts.put(fp, now);
                String[] hp = splitHostPort(addr);
                if (hp != null) targets.add(new String[]{fp, hp[0], hp[1]});
            }
        }
        for (String[] t : targets) {
            try {
                connectTo(InetAddress.getByName(t[1]), Integer.parseInt(t[2]));
            } catch (Exception ignored) {}
        }
        if (connectAttempts.size() > 64) connectAttempts.clear();
    }

    // ================= Bonjour(NSD) =================

    private void advertise() {
        unadvertise();
        regListener = new NsdManager.RegistrationListener() {
            @Override public void onServiceRegistered(NsdServiceInfo info) {}
            @Override public void onServiceUnregistered(NsdServiceInfo info) {}
            @Override public void onRegistrationFailed(NsdServiceInfo info, int errorCode) { log("服务注册失败: " + errorCode); }
            @Override public void onUnregistrationFailed(NsdServiceInfo info, int errorCode) {}
        };
        NsdServiceInfo si = new NsdServiceInfo();
        si.setServiceName(fingerprint.substring(0, 8));
        si.setServiceType(SERVICE_TYPE);
        si.setPort(serverSocket.getLocalPort());
        nsd.registerService(si, NsdManager.PROTOCOL_DNS_SD, regListener);
    }

    private void unadvertise() {
        if (regListener != null) {
            try { nsd.unregisterService(regListener); } catch (Exception ignored) {}
            regListener = null;
        }
    }

    private void browse() {
        unbrowse();
        discListener = new NsdManager.DiscoveryListener() {
            @Override public void onDiscoveryStarted(String type) {}
            @Override public void onDiscoveryStopped(String type) {}
            @Override public void onStartDiscoveryFailed(String type, int code) { log("发现启动失败: " + code); }
            @Override public void onStopDiscoveryFailed(String type, int code) {}

            @Override public void onServiceFound(NsdServiceInfo info) {
                if (isSelfService(info.getServiceName())) return;
                synchronized (lock) { discovered.put(info.getServiceName(), info); }
                delegate.onDiscoveredChanged();
                nsd.resolveService(info, new NsdManager.ResolveListener() {
                    @Override public void onResolveFailed(NsdServiceInfo i, int code) {
                        synchronized (lock) { discovered.remove(i.getServiceName()); }
                        delegate.onDiscoveredChanged();
                    }
                    @Override public void onServiceResolved(NsdServiceInfo i) {
                        synchronized (lock) { discovered.put(i.getServiceName(), i); }
                        delegate.onDiscoveredChanged();
                    }
                });
            }

            @Override public void onServiceLost(NsdServiceInfo info) {
                synchronized (lock) { discovered.remove(info.getServiceName()); }
                delegate.onDiscoveredChanged();
            }
        };
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discListener);
    }

    private void unbrowse() {
        if (discListener != null) {
            try { nsd.stopServiceDiscovery(discListener); } catch (Exception ignored) {}
            discListener = null;
        }
    }

    public void refreshDiscovery() {
        synchronized (lock) { discovered.clear(); connectAttempts.clear(); }
        browse();
    }

    public boolean isSelfService(String serviceName) {
        return fingerprint != null && serviceName.startsWith(fingerprint.substring(0, 8));
    }

    /** 未配对且已解析出地址的设备:serviceName -> host:port */
    public List<String[]> discoveredUnpaired() {
        List<String[]> out = new ArrayList<>();
        synchronized (lock) {
            for (Map.Entry<String, NsdServiceInfo> e : discovered.entrySet()) {
                if (isSelfService(e.getKey())) continue;
                if (isPairedPrefix(e.getKey())) continue;
                NsdServiceInfo info = e.getValue();
                InetAddress host = info.getHost();
                if (host != null && info.getPort() > 0)
                    out.add(new String[]{e.getKey(), host.getHostAddress(), String.valueOf(info.getPort())});
            }
        }
        return out;
    }

    // ================= 配对 =================

    public boolean isPaired(String fp) {
        synchronized (lock) {
            for (String[] p : paired) if (p[0].equals(fp)) return true;
        }
        return false;
    }

    public boolean isPairedPrefix(String shortName) {
        String normalized = serviceShortFp(shortName);
        synchronized (lock) {
            for (String[] p : paired) if (p[0].startsWith(normalized)) return true;
        }
        return false;
    }

    public void addPaired(String fp, String name) {
        if (fp.equals(fingerprint)) return;
        synchronized (lock) {
            for (String[] p : paired) if (p[0].equals(fp)) { p[1] = name; return; }
            paired.add(new String[]{fp, name});
        }
        persistPaired();
    }

    public void removePaired(String fp) {
        PeerConn established;
        List<PeerConn> handshakes = new ArrayList<>();
        synchronized (lock) {
            Iterator<String[]> it = paired.iterator();
            while (it.hasNext()) if (it.next()[0].equals(fp)) it.remove();
            lastAddr.remove(fp);
            established = connections.get(fp);
            for (PeerConn p : pending) if (fp.equals(p.peerFp)) handshakes.add(p);
        }
        persistPaired();
        persistLastAddr();
        if (established != null) established.close("已取消配对");
        for (PeerConn p : handshakes) p.close("已取消配对");
    }

    public List<String[]> pairedList() {
        synchronized (lock) { return new ArrayList<>(paired); }
    }

    public List<String[]> onlinePeers() {
        List<String[]> out = new ArrayList<>();
        synchronized (lock) {
            for (PeerConn c : connections.values())
                if (c.established && c.peerFp != null) out.add(new String[]{c.peerFp, c.peerName});
        }
        return out;
    }

    private void persistPaired() {
        StringBuilder sb = new StringBuilder("[");
        boolean first = true;
        synchronized (lock) {
            for (String[] p : paired) {
                if (!first) sb.append(",");
                first = false;
                sb.append("{\"fp\":\"").append(p[0]).append("\",\"name\":\"")
                  .append(p[1].replace("\"", "'")).append("\"}");
            }
        }
        sb.append("]");
        try {
            writeAll(new File(new File(context.getFilesDir(), "identity"), "paired.json"),
                    sb.toString().getBytes(StandardCharsets.UTF_8));
        } catch (IOException ignored) {}
    }

    private void persistLastAddr() {
        try {
            StringBuilder sb = new StringBuilder("{");
            boolean first = true;
            synchronized (lock) {
                for (Map.Entry<String, String> e : lastAddr.entrySet()) {
                    if (!first) sb.append(",");
                    first = false;
                    sb.append("\"").append(e.getKey()).append("\":\"").append(e.getValue()).append("\"");
                }
            }
            sb.append("}");
            writeAll(new File(new File(context.getFilesDir(), "identity"), "lastaddr.json"),
                    sb.toString().getBytes(StandardCharsets.UTF_8));
        } catch (Exception ignored) {}
    }

    /**
     * Cache a peer's listening endpoint, never an accepted socket's ephemeral
     * source port. For responder connections NSD is the only reliable source
     * of the peer's listening port; if it is unavailable, retain the old cache.
     */
    private void rememberPeerAddress(PeerConn c) {
        try {
            InetSocketAddress remote = (InetSocketAddress) c.socket.getRemoteSocketAddress();
            String address = null;
            if (c.role == Role.INITIATOR) {
                address = formatHostPort(remote.getAddress().getHostAddress(), remote.getPort());
            } else {
                String shortFp = c.peerFp.substring(0, Math.min(8, c.peerFp.length()));
                synchronized (lock) {
                    for (Map.Entry<String, NsdServiceInfo> e : discovered.entrySet()) {
                        NsdServiceInfo info = e.getValue();
                        if (e.getKey().startsWith(shortFp) && info.getHost() != null && info.getPort() > 0) {
                            address = formatHostPort(info.getHost().getHostAddress(), info.getPort());
                            break;
                        }
                    }
                }
            }
            if (address != null) {
                synchronized (lock) { lastAddr.put(c.peerFp, address); }
                persistLastAddr();
            }
        } catch (Exception ignored) {}
    }

    private void loadLastAddr() {
        try {
            File f = new File(new File(context.getFilesDir(), "identity"), "lastaddr.json");
            if (!f.exists()) return;
            String s = new String(readAll(f), StandardCharsets.UTF_8);
            for (String part : s.split(",")) {
                int i = part.indexOf("\":\"");
                if (i < 0) continue;
                String fp = part.substring(0, i).replace("{", "").replace("\"", "").trim();
                String addr = part.substring(i + 3).replace("}", "").replace("\"", "").trim();
                if (fp.length() >= 8 && addr.contains(":")) lastAddr.put(fp, addr);
            }
        } catch (Exception ignored) {}
    }

    private void loadPaired() {
        try {
            File f = new File(new File(context.getFilesDir(), "identity"), "paired.json");
            if (!f.exists()) return;
            String s = new String(readAll(f), StandardCharsets.UTF_8);
            for (String part : s.split("\\{")) {
                String fp = extract(part, "fp");
                String name = extract(part, "name");
                if (fp != null && !fp.equals(fingerprint)) {
                    synchronized (lock) { paired.add(new String[]{fp, name == null ? "?" : name}); }
                }
            }
        } catch (Exception ignored) {}
    }

    private static String extract(String s, String key) {
        int i = s.indexOf("\"" + key + "\":\"");
        if (i < 0) return null;
        int start = i + key.length() + 4;
        int end = s.indexOf('"', start);
        return end < 0 ? null : s.substring(start, end);
    }

    /** JSONObject.put 抛受检 JSONException,链式构建太吵;此子类转为非受检。 */
    public static class Msg extends JSONObject {
        @Override public Msg put(String name, Object value) {
            try { super.put(name, value); } catch (JSONException e) { throw new RuntimeException(e); }
            return this;
        }
        @Override public Msg put(String name, boolean value) {
            try { super.put(name, value); } catch (JSONException e) { throw new RuntimeException(e); }
            return this;
        }
        @Override public Msg put(String name, long value) {
            try { super.put(name, value); } catch (JSONException e) { throw new RuntimeException(e); }
            return this;
        }
        @Override public Msg put(String name, int value) {
            try { super.put(name, value); } catch (JSONException e) { throw new RuntimeException(e); }
            return this;
        }
    }

    // ================= 工具 =================

    private static MessageDigest messageDigest() {
        try { return MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException e) { throw new RuntimeException(e); }
    }

    private static byte[] sha256(byte[] data) { return messageDigest().digest(data); }

    private static String serviceShortFp(String serviceName) {
        return serviceName == null ? "" : serviceName.substring(0, Math.min(8, serviceName.length()));
    }

    private static String formatHostPort(String host, int port) {
        return (host.contains(":") && !host.startsWith("[") ? "[" + host + "]" : host) + ":" + port;
    }

    private static String[] splitHostPort(String address) {
        if (address == null) return null;
        String host;
        String port;
        if (address.startsWith("[")) {
            int end = address.indexOf(']');
            if (end < 0 || end + 2 > address.length() || address.charAt(end + 1) != ':') return null;
            host = address.substring(1, end);
            port = address.substring(end + 2);
        } else {
            int colon = address.lastIndexOf(':');
            if (colon <= 0 || colon == address.length() - 1) return null;
            host = address.substring(0, colon);
            port = address.substring(colon + 1);
        }
        return new String[]{host, port};
    }

    private static byte[] sha256File(File file) throws IOException {
        MessageDigest digest = messageDigest();
        InputStream in = new BufferedInputStream(new FileInputStream(file));
        try {
            byte[] buffer = new byte[1024 * 1024];
            int n;
            while ((n = in.read(buffer)) >= 0) if (n > 0) digest.update(buffer, 0, n);
            return digest.digest();
        } finally { in.close(); }
    }

    private static byte[] sha256FromHex(String hexStr) {
        byte[] out = new byte[32];
        for (int i = 0; i < 32; i++) out[i] = (byte) Integer.parseInt(hexStr.substring(i * 2, i * 2 + 2), 16);
        return out;
    }

    private static String hex(byte[] data) {
        StringBuilder sb = new StringBuilder(data.length * 2);
        for (byte b : data) sb.append(String.format(Locale.US, "%02x", b));
        return sb.toString();
    }

    private static ECPoint point(byte[] raw64) {
        return new ECPoint(new BigInteger(1, sub(raw64, 0, 32)), new BigInteger(1, sub(raw64, 32, 64)));
    }

    private static byte[] to32(BigInteger v) {
        byte[] b = v.toByteArray();
        byte[] out = new byte[32];
        int src = Math.max(0, b.length - 32);
        System.arraycopy(b, src, out, 32 - (b.length - src), b.length - src);
        return out;
    }

    private static byte[] to32(PrivateKey priv) { return to32(((ECPrivateKey) priv).getS()); }

    private static byte[] concat(byte[] a, byte[] b) {
        byte[] out = new byte[a.length + b.length];
        System.arraycopy(a, 0, out, 0, a.length);
        System.arraycopy(b, 0, out, a.length, b.length);
        return out;
    }

    private static byte[] sub(byte[] a, int from, int to) {
        return Arrays.copyOfRange(a, from, Math.min(to, a.length));
    }

    private static byte[] readAll(File f) throws IOException {
        InputStream in = new FileInputStream(f);
        try { return readAll(in); } finally { in.close(); }
    }

    public static byte[] readAll(InputStream in) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[64 * 1024];
        int n;
        while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
        return out.toByteArray();
    }

    private static byte[] readExactly(InputStream in, int length) throws IOException {
        byte[] out = new byte[length];
        int offset = 0;
        while (offset < length) {
            int n = in.read(out, offset, length - offset);
            if (n < 0) break;
            if (n > 0) offset += n;
        }
        return offset == length ? out : Arrays.copyOf(out, offset);
    }

    private static void closeQuietly(Closeable closeable) {
        if (closeable == null) return;
        try { closeable.close(); } catch (IOException ignored) {}
    }

    private static String safeFileName(String name) {
        String clean = new File(name == null ? "file" : name).getName().replace('\0', '_').trim();
        if (clean.isEmpty() || ".".equals(clean) || "..".equals(clean)) clean = "file";
        return clean.length() > 200 ? clean.substring(0, 200) : clean;
    }

    private static void writeAll(File f, byte[] data) throws IOException {
        f.getParentFile().mkdirs();
        OutputStream out = new FileOutputStream(f);
        try { out.write(data); } finally { out.close(); }
    }

    private static void copy(File src, File dst) throws IOException {
        InputStream in = new BufferedInputStream(new FileInputStream(src));
        OutputStream out = new BufferedOutputStream(new FileOutputStream(dst));
        try {
            byte[] buffer = new byte[1024 * 1024];
            int n;
            while ((n = in.read(buffer)) >= 0) if (n > 0) out.write(buffer, 0, n);
        } finally {
            try { in.close(); } finally { out.close(); }
        }
    }

    /** 校验后的落盘:API29+ 走 MediaStore 存公共 Downloads/ProtoSync(免权限),旧版本退回 app 目录。 */
    private File saveReceived(File tmp, String name) {
        if (Build.VERSION.SDK_INT >= 29) {
            Uri uri = null;
            try {
                ContentValues v = new ContentValues();
                v.put(MediaStore.Downloads.DISPLAY_NAME, name);
                v.put(MediaStore.Downloads.MIME_TYPE, mimeTypeFor(name));
                v.put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/ProtoSync");
                v.put(MediaStore.MediaColumns.IS_PENDING, 1);
                uri = context.getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, v);
                if (uri != null) {
                    java.io.InputStream in = new BufferedInputStream(new FileInputStream(tmp));
                    java.io.OutputStream os = context.getContentResolver().openOutputStream(uri);
                    if (os == null) throw new IOException("无法写入系统下载目录");
                    try {
                        byte[] buffer = new byte[1024 * 1024];
                        int n;
                        while ((n = in.read(buffer)) >= 0) if (n > 0) os.write(buffer, 0, n);
                    } finally {
                        try { in.close(); } finally { os.close(); }
                    }
                    ContentValues published = new ContentValues();
                    published.put(MediaStore.MediaColumns.IS_PENDING, 0);
                    context.getContentResolver().update(uri, published, null, null);
                    tmp.delete();
                    return new File(Environment.getExternalStoragePublicDirectory(
                            Environment.DIRECTORY_DOWNLOADS) + "/ProtoSync", name);
                }
            } catch (Exception e) {
                if (uri != null) {
                    try { context.getContentResolver().delete(uri, null, null); } catch (Exception ignored) {}
                }
                log("MediaStore 保存失败,退回应用目录: " + e.getMessage());
            }
        }
        try {
            File dir = new File(context.getExternalFilesDir(null), "ProtoSync");
            dir.mkdirs();
            File out = availableFile(dir, name);
            if (!tmp.renameTo(out)) { copy(tmp, out); tmp.delete(); }
            return out;
        } catch (IOException e) {
            return tmp;
        }
    }

    private static String mimeTypeFor(String name) {
        String ext = name.contains(".")
                ? name.substring(name.lastIndexOf('.') + 1).toLowerCase(Locale.US) : "";
        String mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext);
        return mime != null ? mime : "application/octet-stream";
    }

    private static File availableFile(File dir, String name) {
        File f = new File(dir, name);
        if (!f.exists()) return f;
        String base = name.contains(".") ? name.substring(0, name.lastIndexOf('.')) : name;
        String ext = name.contains(".") ? name.substring(name.lastIndexOf('.')) : "";
        int n = 2;
        while (true) {
            f = new File(dir, base + " (" + n + ")" + ext);
            if (!f.exists()) return f;
            n++;
        }
    }
}
