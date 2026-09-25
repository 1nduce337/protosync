package com.protosync.core;

import android.util.Base64;

import org.json.JSONObject;

import java.io.IOException;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.MessageDigest;
import java.security.PrivateKey;
import java.security.PublicKey;
import java.security.SecureRandom;
import java.security.interfaces.ECPrivateKey;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.ECParameterSpec;
import java.security.spec.ECPoint;
import java.security.spec.ECPrivateKeySpec;
import java.security.spec.ECPublicKeySpec;
import java.util.Arrays;

import javax.crypto.Cipher;
import javax.crypto.KeyAgreement;
import javax.crypto.Mac;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * 加密原语,与 macOS Swift 端(SecureChannel.swift)逐字节对齐:
 * - 指纹 = hex(SHA256(signPub64 ‖ dhPub64)),公钥均为 64B X‖Y 裸编码
 * - transcript = SHA256("ProtoSync-v1" ‖ initSign ‖ initDh ‖ initEph ‖ respSign ‖ respDh ‖ respEph)
 * - IKM = DH(ephI,ephR) ‖ DH(ephI,staticR) ‖ DH(staticI,ephR) 各 32B
 * - HKDF-256(salt=transcript, info="protosync-keys", 64B):前 32B=c2s、后 32B=s2c
 * - ChaCha20-Poly1305:nonce = 4 零字节 + 8B 大端计数器;密文帧 = nonce ‖ ct ‖ tag
 * - ECDSA(SHA256withECDSA)线格式 = 64B r‖s(Java DER ↔ raw 互转,pad32 剥前导零左对齐)
 */
public final class Crypto {
    public static final String HKDF_INFO = "protosync-keys";

    private Crypto() {}

    // ================= 身份 =================

    /** 192B 布局:signPriv32 ‖ dhPriv32 ‖ signPub64 ‖ dhPub64(与旧版/现有手机数据兼容)。 */
    public static byte[] packKeys(byte[] signPriv32, byte[] dhPriv32, byte[] signPub64, byte[] dhPub64) {
        return concat(concat(signPriv32, dhPriv32), concat(signPub64, dhPub64));
    }

    public static KeyPair generatePair() throws Exception {
        KeyPairGenerator kpg = KeyPairGenerator.getInstance("EC");
        kpg.initialize(new ECGenParameterSpec("secp256r1"));
        return kpg.generateKeyPair();
    }

    public static PrivateKey privateFromRaw(byte[] raw32, ECParameterSpec spec) throws Exception {
        KeyFactory kf = KeyFactory.getInstance("EC");
        return kf.generatePrivate(new ECPrivateKeySpec(new BigInteger(1, raw32), spec));
    }

    public static byte[] rawPublic(KeyPair kp) {
        java.security.interfaces.ECPublicKey pub = (java.security.interfaces.ECPublicKey) kp.getPublic();
        return concat(to32(pub.getW().getAffineX()), to32(pub.getW().getAffineY()));
    }

    public static byte[] rawPrivate32(ECPrivateKey priv) {
        return to32(priv.getS());
    }

    public static String fingerprint(byte[] signPub64, byte[] dhPub64) {
        return hex(sha256(concat(signPub64, dhPub64)));
    }

    public static ECParameterSpec parameterSpec() throws Exception {
        java.security.AlgorithmParameters ap = java.security.AlgorithmParameters.getInstance("EC");
        ap.init(new ECGenParameterSpec("secp256r1"));
        return ap.getParameterSpec(ECParameterSpec.class);
    }

    // ================= transcript / 会话密钥 =================

    public static byte[] transcript(Role role, byte[] mySign64, byte[] myDh64, byte[] myEph64,
                                    byte[] peerSign64, byte[] peerDh64, byte[] peerEph64) {
        byte[] initSign, initDh, initEph, respSign, respDh, respEph;
        if (role == Role.INITIATOR) {
            initSign = mySign64; initDh = myDh64; initEph = myEph64;
            respSign = peerSign64; respDh = peerDh64; respEph = peerEph64;
        } else {
            respSign = mySign64; respDh = myDh64; respEph = myEph64;
            initSign = peerSign64; initDh = peerDh64; initEph = peerEph64;
        }
        MessageDigest md = sha256();
        md.update("ProtoSync-v1".getBytes(StandardCharsets.UTF_8));
        md.update(initSign); md.update(initDh); md.update(initEph);
        md.update(respSign); md.update(respDh); md.update(respEph);
        return md.digest();
    }

    /** 返回 64B:前 32B c2s、后 32B s2c。 */
    public static byte[] sessionKeys(Role role, PrivateKey myDh, PrivateKey myEph,
                                     PublicKey peerDh, PublicKey peerEph,
                                     byte[] transcriptHash) throws Exception {
        byte[] ss1 = ecdh(myEph, peerEph);
        byte[] ss2 = role == Role.INITIATOR ? ecdh(myEph, peerDh) : ecdh(myDh, peerEph);
        byte[] ss3 = role == Role.INITIATOR ? ecdh(myDh, peerEph) : ecdh(myEph, peerDh);
        return hkdf(concat(concat(ss1, ss2), ss3), transcriptHash,
                HKDF_INFO.getBytes(StandardCharsets.UTF_8), 64);
    }

    public static PublicKey publicFromRaw(byte[] raw64, ECParameterSpec spec) throws Exception {
        KeyFactory kf = KeyFactory.getInstance("EC");
        return kf.generatePublic(new ECPublicKeySpec(point(raw64), spec));
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

    // ================= 通道(seal / open)=================

    public static class Channel {
        public final byte[] sendKey, recvKey;
        long sendCounter = 0;
        long recvCounter = 0;

        public Channel(Role role, byte[] sessionKeys64) {
            byte[] c2s = Arrays.copyOfRange(sessionKeys64, 0, 32);
            byte[] s2c = Arrays.copyOfRange(sessionKeys64, 32, 64);
            // responder 发送用 s2c:方向映射错会让第一条加密帧验签失败(AEADBadTag)
            this.sendKey = role == Role.INITIATOR ? c2s : s2c;
            this.recvKey = role == Role.INITIATOR ? s2c : c2s;
        }

        /** 密文帧 = 12B nonce ‖ ct ‖ tag。调用方必须串行化(见 PeerLink 的发送锁)。 */
        public byte[] seal(JSONObject m) throws Exception {
            byte[] plain = m.toString().getBytes(StandardCharsets.UTF_8);
            byte[] nonce = nonceFor(sendCounter);
            Cipher cipher = Cipher.getInstance("ChaCha20-Poly1305");
            cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(sendKey, "ChaCha20"),
                    new IvParameterSpec(nonce));
            byte[] ct = cipher.doFinal(plain); // ct ‖ tag(16)
            sendCounter++;
            byte[] out = new byte[12 + ct.length];
            System.arraycopy(nonce, 0, out, 0, 12);
            System.arraycopy(ct, 0, out, 12, ct.length);
            return out;
        }

        public JSONObject open(byte[] frame) throws Exception {
            if (frame.length <= 28) throw new IOException("密文帧过短");
            byte[] nonce = Arrays.copyOfRange(frame, 0, 12);
            if (!MessageDigest.isEqual(nonce, nonceFor(recvCounter)))
                throw new SecurityException("密文 nonce 次序异常");
            Cipher cipher = Cipher.getInstance("ChaCha20-Poly1305");
            cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(recvKey, "ChaCha20"),
                    new IvParameterSpec(nonce));
            byte[] plain = cipher.doFinal(Arrays.copyOfRange(frame, 12, frame.length));
            recvCounter++;
            return new JSONObject(new String(plain, StandardCharsets.UTF_8));
        }
    }

    private static byte[] nonceFor(long counter) {
        byte[] n = new byte[12];
        for (int i = 0; i < 8; i++) n[4 + i] = (byte) (counter >>> (56 - 8 * i));
        return n;
    }

    // ================= ECDSA(r‖s 线格式)=================

    public static byte[] sign(PrivateKey signPriv, byte[] transcriptHash) throws Exception {
        java.security.Signature sig = java.security.Signature.getInstance("SHA256withECDSA");
        sig.initSign(signPriv);
        sig.update(transcriptHash);
        return derToRaw(sig.sign());
    }

    public static boolean verify(byte[] peerSignPub64, byte[] transcriptHash,
                                 byte[] rawSig64, ECParameterSpec spec) throws Exception {
        PublicKey pub = publicFromRaw(peerSignPub64, spec);
        java.security.Signature sig = java.security.Signature.getInstance("SHA256withECDSA");
        sig.initVerify(pub);
        sig.update(transcriptHash);
        return sig.verify(rawToDer(rawSig64));
    }

    public static byte[] derToRaw(byte[] der) {
        int i = 2;
        int rLen = der[i + 1] & 0xff;
        byte[] r = Arrays.copyOfRange(der, i + 2, i + 2 + rLen);
        int j = i + 2 + rLen;
        int sLen = der[j + 1] & 0xff;
        byte[] s = Arrays.copyOfRange(der, j + 2, j + 2 + sLen);
        return concat(pad32(r), pad32(s));
    }

    public static byte[] rawToDer(byte[] raw64) {
        byte[] body = concat(derInt(Arrays.copyOfRange(raw64, 0, 32)),
                derInt(Arrays.copyOfRange(raw64, 32, 64)));
        return concat(new byte[]{0x30, (byte) body.length}, body);
    }

    /** INTEGER + 长度;最高位为 1 时按 DER 规范补 0x00 前缀。 */
    private static byte[] derInt(byte[] v) {
        int i = 0;
        while (i < v.length - 1 && v[i] == 0) i++;
        byte[] u = Arrays.copyOfRange(v, i, v.length);
        byte[] body = (u[0] & 0x80) != 0 ? concat(new byte[]{0x00}, u) : u;
        return concat(new byte[]{0x02, (byte) body.length}, body);
    }

    /**
     * DER 整数可能带 0x00 高位填充:必须剥前导零后右对齐拷入 32B,
     * 否则保留填充零、丢掉最后一个有效字节,验签间歇性失败(失败签名以 00 开头)。
     */
    private static byte[] pad32(byte[] v) {
        int i = 0;
        while (i < v.length - 1 && v[i] == 0) i++;
        byte[] u = Arrays.copyOfRange(v, i, v.length);
        byte[] out = new byte[32];
        System.arraycopy(u, 0, out, 32 - Math.min(32, u.length), Math.min(32, u.length));
        return out;
    }

    // ================= 散列 / 编码工具 =================

    public static MessageDigest sha256() {
        try { return MessageDigest.getInstance("SHA-256"); }
        catch (Exception e) { throw new RuntimeException(e); }
    }

    public static byte[] sha256(byte[] data) { return sha256().digest(data); }

    public static String sha256Hex(byte[] data) { return hex(sha256(data)); }

    public static String hex(byte[] data) {
        StringBuilder sb = new StringBuilder(data.length * 2);
        for (byte b : data) sb.append(String.format(java.util.Locale.US, "%02x", b));
        return sb.toString();
    }

    public static byte[] b64encode(byte[] data) {
        return Base64.encode(data, Base64.NO_WRAP);
    }

    public static String b64encodeToString(byte[] data) {
        return Base64.encodeToString(data, Base64.NO_WRAP);
    }

    public static byte[] b64decode(String s) {
        return Base64.decode(s, Base64.NO_WRAP);
    }

    public static ECPoint point(byte[] raw64) {
        return new ECPoint(new BigInteger(1, Arrays.copyOfRange(raw64, 0, 32)),
                new BigInteger(1, Arrays.copyOfRange(raw64, 32, 64)));
    }

    public static byte[] to32(BigInteger v) {
        byte[] b = v.toByteArray();
        byte[] out = new byte[32];
        int src = Math.max(0, b.length - 32);
        System.arraycopy(b, src, out, 32 - (b.length - src), b.length - src);
        return out;
    }

    public static byte[] concat(byte[] a, byte[] b) {
        byte[] out = new byte[a.length + b.length];
        System.arraycopy(a, 0, out, 0, a.length);
        System.arraycopy(b, 0, out, a.length, b.length);
        return out;
    }

    public static SecureRandom random() { return new SecureRandom(); }
}
