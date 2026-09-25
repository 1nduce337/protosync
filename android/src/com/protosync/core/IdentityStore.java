package com.protosync.core;

import android.content.Context;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.PrivateKey;
import java.security.interfaces.ECPrivateKey;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 身份与信任持久化(与旧版文件格式完全兼容,换 APK 不掉指纹、不用重新配对):
 * - files/identity/device.key:192B = signPriv32 ‖ dhPriv32 ‖ signPub64 ‖ dhPub64
 *   (JCA 无法从裸私钥导出公钥,公钥一并持久化)
 * - files/identity/paired.json:[{"fp":"…","name":"…"}]
 * - files/identity/lastaddr.json:{"<fp>":"host:port"}
 */
public final class IdentityStore {
    private final File identityDir;

    public PrivateKey signPriv, dhPriv;
    public byte[] signPub64, dhPub64;
    public String fingerprint;

    private final List<String[]> paired = new ArrayList<>();          // {fp, name}
    private final Map<String, String> lastAddr = new LinkedHashMap<>(); // fp -> host:port

    public IdentityStore(Context context, String deviceName) throws Exception {
        identityDir = new File(context.getFilesDir(), "identity");
        identityDir.mkdirs();

        File keyFile = new File(identityDir, "device.key");
        byte[] blob = keyFile.exists() ? readAll(keyFile) : null;
        if (blob == null || blob.length != 192 || !loadKeys(blob)) {
            KeyPair sign = Crypto.generatePair();
            KeyPair dh = Crypto.generatePair();
            signPriv = sign.getPrivate();
            dhPriv = dh.getPrivate();
            signPub64 = Crypto.rawPublic(sign);
            dhPub64 = Crypto.rawPublic(dh);
            writeAll(keyFile, Crypto.packKeys(
                    Crypto.rawPrivate32((ECPrivateKey) signPriv),
                    Crypto.rawPrivate32((ECPrivateKey) dhPriv),
                    signPub64, dhPub64));
        }
        fingerprint = Crypto.fingerprint(signPub64, dhPub64);

        loadPaired();
        loadLastAddr();
        if (deviceName != null && !deviceName.isEmpty()) saveDeviceName(deviceName);
    }

    private boolean loadKeys(byte[] blob) {
        try {
            java.security.spec.ECParameterSpec spec = ECParameterSpecHolder.INSTANCE;
            signPriv = Crypto.privateFromRaw(java.util.Arrays.copyOfRange(blob, 0, 32), spec);
            dhPriv = Crypto.privateFromRaw(java.util.Arrays.copyOfRange(blob, 32, 64), spec);
            signPub64 = java.util.Arrays.copyOfRange(blob, 64, 128);
            dhPub64 = java.util.Arrays.copyOfRange(blob, 128, 192);
            // 触发一次签名/验证能力检查,坏密钥文件立刻走重新生成路径
            byte[] probe = Crypto.sha256("probe".getBytes(StandardCharsets.UTF_8));
            return Crypto.verify(signPub64, probe, Crypto.sign(signPriv, probe), spec);
        } catch (Exception e) {
            signPriv = null;
            return false;
        }
    }

    /** ECParameterSpec 生成开销大,全进程共享一份。 */
    static final class ECParameterSpecHolder {
        static final java.security.spec.ECParameterSpec INSTANCE = make();
        private static java.security.spec.ECParameterSpec make() {
            try { return Crypto.parameterSpec(); }
            catch (Exception e) { throw new RuntimeException(e); }
        }
    }

    // ================= 设备名 =================

    public String deviceName() {
        try {
            String s = new String(readAll(new File(identityDir, "device.name")), StandardCharsets.UTF_8).trim();
            return s.isEmpty() ? "Android 设备" : s;
        } catch (Exception e) {
            return "Android 设备";
        }
    }

    public void saveDeviceName(String name) {
        try {
            writeAll(new File(identityDir, "device.name"), name.getBytes(StandardCharsets.UTF_8));
        } catch (IOException ignored) {}
    }

    // ================= 配对列表 =================

    public synchronized boolean isPaired(String fp) {
        for (String[] p : paired) if (p[0].equals(fp)) return true;
        return false;
    }

    /** 服务名(指纹前 8 位,可能带 mDNS 改名后缀)是否命中某个已配对指纹。 */
    public synchronized boolean isPairedPrefix(String serviceName) {
        String n = serviceName == null ? "" : serviceName.substring(0, Math.min(8, serviceName.length()));
        for (String[] p : paired) if (p[0].startsWith(n)) return true;
        return false;
    }

    public synchronized void addPaired(String fp, String name) {
        if (fp == null || fp.equals(fingerprint)) return;
        for (String[] p : paired) {
            if (p[0].equals(fp)) { p[1] = name; persistPaired(); return; }
        }
        paired.add(new String[]{fp, name == null ? "?" : name});
        persistPaired();
    }

    public synchronized void removePaired(String fp) {
        boolean changed = paired.removeIf(p -> p[0].equals(fp));
        lastAddr.remove(fp);
        if (changed) { persistPaired(); persistLastAddr(); }
    }

    public synchronized List<String[]> pairedSnapshot() {
        return new ArrayList<>(paired);
    }

    private void loadPaired() {
        try {
            File f = new File(identityDir, "paired.json");
            if (!f.exists()) return;
            JSONArray arr = new JSONArray(new String(readAll(f), StandardCharsets.UTF_8));
            for (int i = 0; i < arr.length(); i++) {
                JSONObject o = arr.getJSONObject(i);
                String fp = o.optString("fp", "");
                String name = o.optString("name", "?");
                if (!fp.isEmpty() && !fp.equals(fingerprint)) paired.add(new String[]{fp, name});
            }
        } catch (Exception ignored) {}
    }

    private void persistPaired() {
        try {
            JSONArray arr = new JSONArray();
            for (String[] p : paired) {
                arr.put(new JSONObject().put("fp", p[0]).put("name", p[1]));
            }
            writeAll(new File(identityDir, "paired.json"), arr.toString().getBytes(StandardCharsets.UTF_8));
        } catch (Exception ignored) {}
    }

    // ================= 对端地址缓存 =================

    public synchronized void rememberAddress(String fp, String hostPort) {
        if (fp == null || hostPort == null) return;
        lastAddr.put(fp, hostPort);
        persistLastAddr();
    }

    public synchronized String addressOf(String fp) {
        return lastAddr.get(fp);
    }

    private void loadLastAddr() {
        try {
            File f = new File(identityDir, "lastaddr.json");
            if (!f.exists()) return;
            JSONObject o = new JSONObject(new String(readAll(f), StandardCharsets.UTF_8));
            java.util.Iterator<String> it = o.keys();
            while (it.hasNext()) {
                String fp = it.next();
                String addr = o.optString(fp, "");
                if (fp.length() >= 8 && addr.contains(":")) lastAddr.put(fp, addr);
            }
        } catch (Exception ignored) {}
    }

    private void persistLastAddr() {
        try {
            JSONObject o = new JSONObject();
            for (Map.Entry<String, String> e : lastAddr.entrySet()) o.put(e.getKey(), e.getValue());
            writeAll(new File(identityDir, "lastaddr.json"), o.toString().getBytes(StandardCharsets.UTF_8));
        } catch (Exception ignored) {}
    }

    // ================= 文件工具 =================

    private static byte[] readAll(File f) throws IOException {
        InputStream in = new FileInputStream(f);
        try { return Protocol.readFully(in, (int) f.length()); } finally { in.close(); }
    }

    private static void writeAll(File f, byte[] data) throws IOException {
        f.getParentFile().mkdirs();
        OutputStream out = new FileOutputStream(f);
        try { out.write(data); } finally { out.close(); }
    }
}
