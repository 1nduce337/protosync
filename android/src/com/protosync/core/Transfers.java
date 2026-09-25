package com.protosync.core;

import android.content.ContentValues;
import android.content.Context;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.MediaStore;
import android.webkit.MimeTypeMap;

import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Locale;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

/**
 * 文件收发:192KB 分块 / 16 块滑动窗口 / SHA-256 校验,与 Swift 端对齐。
 *
 * 线程约定:
 * - 发送侧状态(nextIndex/inFlight)只在 IO 线程变;ack 从引擎线程转发过来。
 * - 接收侧状态只在引擎线程变(分块按序到达);done 后的哈希+落盘在 IO 线程,结果回引擎线程。
 * - 表用 ConcurrentHashMap:引擎/IO 两侧都会增删,单个任务内部的修改按上面约定单线程化。
 */
public final class Transfers {
    public static final long MAX_FILE_SIZE = 4L * 1024 * 1024 * 1024; // 与 Swift FileTransferGuard 一致

    public interface Events {
        void onTransferStarted(String id, String name, boolean incoming);
        void onTransferProgress(String id, String name, double fraction, boolean incoming);
        /** savedUri:MediaStore content URI(通知点按直接打开用);应用目录兜底路径时为 null。 */
        void onTransferFinished(String id, String name, boolean ok, String error,
                                boolean incoming, String savedPath, String savedUri);
    }

    public interface Host {
        void sendTo(PeerLink link, Protocol.Msg m) throws Exception;
        void postEngine(Runnable r);
        void postIo(Runnable r);
        /** 该指纹当前存活的连接(引擎连接表是并发安全的);连接被替换后自动续上。 */
        PeerLink linkFor(String fp);
    }

    private static class Outgoing {
        String id, name, sha; long size;
        InputStream input;
        String targetFp;
        int nextIndex = 0, inFlight = 0;
        volatile boolean doneSent = false, cancelled = false;
    }

    private static class Incoming {
        String id, name, sha; long size, received = 0; int chunks = 0;
        String sourceFp;
        FileOutputStream fos; File tempFile;
        boolean finalizing = false;
    }

    private final Host host;
    private final Context context;
    private final Events events;

    private final ConcurrentHashMap<String, Outgoing> outgoing = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<String, Incoming> incoming = new ConcurrentHashMap<>();

    public Transfers(Host host, Context context, Events events) {
        this.host = host;
        this.context = context;
        this.events = events;
    }

    public void shutdown() {
        for (Outgoing t : outgoing.values()) { t.cancelled = true; closeQuietly(t.input); }
        for (Incoming t : incoming.values()) { closeQuietly(t.fos); if (t.tempFile != null) t.tempFile.delete(); }
        outgoing.clear();
        incoming.clear();
    }

    public boolean hasActiveForPeer(String fp) {
        for (Outgoing t : outgoing.values()) if (fp.equals(t.targetFp)) return true;
        for (Incoming t : incoming.values()) if (fp.equals(t.sourceFp)) return true;
        return false;
    }

    public boolean isBusy() { return !outgoing.isEmpty() || !incoming.isEmpty(); }

    // ================= 发送 =================

    /** uri 由上层(UI)提供;先在 IO 线程流式哈希,再回引擎线程发 offer。 */
    public void sendFile(PeerLink link, Uri uri, String displayName) {
        host.postIo(() -> {
            long measured = 0;
            String sha;
            try {
                MessageDigest digest = Crypto.sha256();
                try (InputStream hashing = context.getContentResolver().openInputStream(uri)) {
                    if (hashing == null) throw new IOException("无法打开所选文件");
                    byte[] buffer = new byte[1024 * 1024];
                    int n;
                    while ((n = hashing.read(buffer)) >= 0) {
                        if (n > 0) { digest.update(buffer, 0, n); measured += n; }
                    }
                }
                if (measured > MAX_FILE_SIZE) throw new IOException("文件超过 4GB 上限");
                sha = Crypto.hex(digest.digest());
            } catch (Exception e) {
                events.onTransferFinished("", displayName, false, "读取文件失败: " + e.getMessage(), false, null, null);
                return;
            }
            final long size = measured;
            final String fSha = sha;
            final String targetFp = link.peerFingerprint();
            host.postEngine(() -> {
                PeerLink current = host.linkFor(targetFp);
                if (current == null || current.isClosed()) {
                    events.onTransferFinished("", displayName, false, "设备已离线", false, null, null);
                    return;
                }
                String id = UUID.randomUUID().toString();
                Outgoing t = new Outgoing();
                t.id = id;
                t.name = sanitizeFileName(displayName);
                t.size = size;
                t.sha = fSha;
                t.targetFp = targetFp;
                try {
                    t.input = context.getContentResolver().openInputStream(uri);
                    if (t.input == null) throw new IOException("无法重新打开所选文件");
                } catch (Exception e) {
                    events.onTransferFinished(id, displayName, false, "读取文件失败: " + e.getMessage(), false, null, null);
                    return;
                }
                outgoing.put(id, t);
                try {
                    host.sendTo(current, new Protocol.Msg().put("type", Protocol.TYPE_FILE_OFFER)
                            .put("id", id).put("fileName", t.name).put("size", size).put("sha256", fSha));
                    events.onTransferStarted(id, t.name, false);
                } catch (Exception e) {
                    outgoing.remove(id);
                    t.cancelled = true;
                    closeQuietly(t.input);
                    events.onTransferFinished(id, t.name, false, "发送失败: " + e.getMessage(), false, null, null);
                }
            });
        });
    }

    /** 引擎线程收到 file_ack:转发到 IO 线程驱动泵。 */
    public void handleAck(JSONObject m) {
        String id = m.optString("id");
        boolean accept = m.optBoolean("accept");
        boolean done = m.optBoolean("done");
        host.postIo(() -> {
            Outgoing t = outgoing.get(id);
            if (t == null || t.cancelled) return;
            if (done || !accept) {
                boolean ok = done && accept;
                finishOutgoing(id, t, ok, ok ? null : (done ? "接收方校验失败" : "接收方拒绝"));
                return;
            }
            t.inFlight = 0;
            pump(t);
        });
    }

    /** 只在 IO 线程运行。每窗重新解析当前连接:连接被替换后传输无缝续上。 */
    private void pump(Outgoing t) {
        try {
            PeerLink link = host.linkFor(t.targetFp);
            while (!t.cancelled && t.inFlight < Protocol.WINDOW
                    && (long) t.nextIndex * Protocol.CHUNK_SIZE < t.size) {
                if (link == null || link.isClosed()) {
                    link = host.linkFor(t.targetFp);
                    if (link == null || link.isClosed()) throw new IOException("设备已离线");
                }
                long off = (long) t.nextIndex * Protocol.CHUNK_SIZE;
                int len = (int) Math.min(Protocol.CHUNK_SIZE, t.size - off);
                byte[] chunk = Protocol.readFully(t.input, len);
                host.sendTo(link, new Protocol.Msg().put("type", Protocol.TYPE_FILE_CHUNK)
                        .put("id", t.id).put("index", t.nextIndex)
                        .put("data", Crypto.b64encodeToString(chunk)));
                t.nextIndex++;
                t.inFlight++;
            }
            if (!t.cancelled && (long) t.nextIndex * Protocol.CHUNK_SIZE >= t.size && !t.doneSent) {
                t.doneSent = true;
                link = host.linkFor(t.targetFp);
                if (link == null) throw new IOException("设备已离线");
                host.sendTo(link, new Protocol.Msg().put("type", Protocol.TYPE_FILE_DONE).put("id", t.id));
            }
            double fraction = t.size > 0
                    ? Math.min(1.0, (double) ((long) t.nextIndex * Protocol.CHUNK_SIZE) / t.size) : 1.0;
            events.onTransferProgress(t.id, t.name, fraction, false);
        } catch (Exception e) {
            if (!t.cancelled) finishOutgoing(t.id, t, false, "发送失败: " + e.getMessage());
        }
    }

    private void finishOutgoing(String id, Outgoing t, boolean ok, String error) {
        outgoing.remove(id);
        t.cancelled = true;
        closeQuietly(t.input);
        events.onTransferFinished(id, t.name, ok, error, false, null, null);
    }

    // ================= 接收(引擎线程)=================

    public void handleOffer(PeerLink link, JSONObject m) {
        String id = m.optString("id", "");
        if (!isValidTransferId(id)) { nack(link, id); return; }
        // 同一对端重发同一 id(发送方 offer 看门狗重试):幂等重发 ack,不重建任务
        Incoming existing = incoming.get(id);
        if (existing != null) {
            if (link.peerFingerprint() != null && link.peerFingerprint().equals(existing.sourceFp)) {
                try {
                    host.sendTo(link, new Protocol.Msg().put("type", Protocol.TYPE_FILE_ACK)
                            .put("id", id).put("accept", true).put("done", false));
                } catch (Exception ignored) {}
                return;
            }
            nack(link, id);
            return;
        }
        if (outgoing.containsKey(id)) { nack(link, id); return; }
        Incoming t = new Incoming();
        try {
            t.id = id;
            t.name = sanitizeFileName(m.getString("fileName"));
            t.size = m.getLong("size");
            if (t.size < 0 || t.size > MAX_FILE_SIZE) throw new IOException("文件大小无效");
            t.sha = m.getString("sha256");
            if (!isValidSha256(t.sha)) throw new IOException("文件摘要无效");
            t.sourceFp = link.peerFingerprint();
            File dir = incomingDir();
            t.tempFile = File.createTempFile(".incoming-", ".part", dir);
            t.fos = new FileOutputStream(t.tempFile);
        } catch (Exception e) {
            closeQuietly(t.fos);
            if (t.tempFile != null) t.tempFile.delete();
            nack(link, id);
            events.onTransferFinished(id, "文件", false, "无法接收: " + e.getMessage(), true, null, null);
            return;
        }
        incoming.put(id, t);
        try {
            host.sendTo(link, new Protocol.Msg().put("type", Protocol.TYPE_FILE_ACK)
                    .put("id", t.id).put("accept", true).put("done", false));
            events.onTransferStarted(t.id, t.name, true);
        } catch (Exception e) {
            failIncoming(link, id, "接收失败: " + e.getMessage());
        }
    }

    public void handleChunk(PeerLink link, JSONObject m) {
        String id = m.optString("id");
        Incoming t = incoming.get(id);
        if (t == null || t.finalizing) return;
        try {
            if (link.peerFingerprint() == null || !link.peerFingerprint().equals(t.sourceFp)) return;
            int index = m.getInt("index");
            if (index != t.chunks) throw new IOException("分块次序异常");
            byte[] chunk = Crypto.b64decode(m.getString("data"));
            if (chunk.length > Protocol.CHUNK_SIZE) throw new IOException("单块超限");
            if (t.received + chunk.length > t.size) throw new IOException("数据超过声明大小");
            t.fos.write(chunk);
            t.received += chunk.length;
            t.chunks++;
            if (t.chunks % Protocol.WINDOW == 0) {
                host.sendTo(link, new Protocol.Msg().put("type", Protocol.TYPE_FILE_ACK)
                        .put("id", t.id).put("accept", true).put("done", false));
            }
            double fraction = t.size > 0 ? (double) t.received / t.size : 1.0;
            events.onTransferProgress(t.id, t.name, fraction, true);
        } catch (Exception e) {
            failIncoming(link, id, "接收失败: " + e.getMessage());
        }
    }

    public void handleDone(PeerLink link, JSONObject m) {
        String id = m.optString("id");
        Incoming t = incoming.get(id);
        if (t == null || t.finalizing) return;
        if (link.peerFingerprint() == null || !link.peerFingerprint().equals(t.sourceFp)) return;
        try {
            if (t.received != t.size) throw new IOException(
                    String.format(Locale.US, "字节数不匹配(收 %d/声明 %d)", t.received, t.size));
            t.finalizing = true;
            closeQuietly(t.fos);
            File temp = t.tempFile;
            host.postIo(() -> {
                String actual;
                try {
                    actual = Crypto.hex(sha256File(temp));
                } catch (Exception e) {
                    host.postEngine(() -> failIncoming(link, id, "校验失败(哈希不可用)"));
                    return;
                }
                host.postEngine(() -> {
                    Incoming cur = incoming.get(id);
                    if (cur == null || !cur.finalizing) return;
                    if (!actual.equalsIgnoreCase(cur.sha)) {
                        failIncoming(link, id, "校验失败(传输损坏)");
                        return;
                    }
                    host.postIo(() -> {
                        String[] saved = null;
                        try {
                            saved = saveReceived(temp, cur.name);
                            final String[] fSaved = saved;
                            host.postEngine(() -> {
                                incoming.remove(id);
                                try {
                                    host.sendTo(link, new Protocol.Msg().put("type", Protocol.TYPE_FILE_ACK)
                                            .put("id", id).put("accept", true).put("done", true));
                                } catch (Exception ignored) {}
                                events.onTransferFinished(id, cur.name, true, null, true, fSaved[0], fSaved[1]);
                            });
                        } catch (Exception e) {
                            host.postEngine(() -> {
                                // 落盘失败:临时文件保留并明示路径,绝不静默丢弃
                                failIncomingKeepTemp(link, id, "保存失败: " + e.getMessage()
                                        + "(临时文件保留在 " + temp.getAbsolutePath() + ")");
                            });
                        }
                    });
                });
            });
        } catch (Exception e) {
            failIncoming(link, id, "接收失败: " + e.getMessage());
        }
    }

    // ================= 失败 / 取消 =================

    private void failIncoming(PeerLink link, String id, String reason) {
        Incoming t = incoming.remove(id);
        if (t != null) {
            closeQuietly(t.fos);
            if (t.tempFile != null) t.tempFile.delete();
        }
        nack(link, id);
        events.onTransferFinished(id, t != null ? t.name : "文件", false, reason, true, null, null);
    }

    private void failIncomingKeepTemp(PeerLink link, String id, String reason) {
        Incoming t = incoming.remove(id);
        if (t != null) closeQuietly(t.fos); // 临时文件保留
        nack(link, id);
        events.onTransferFinished(id, t != null ? t.name : "文件", false, reason, true, null, null);
    }

    private void nack(PeerLink link, String id) {
        try {
            host.sendTo(link, new Protocol.Msg().put("type", Protocol.TYPE_FILE_ACK)
                    .put("id", id).put("accept", false).put("done", true));
        } catch (Exception ignored) {}
    }

    /** 连接断开(引擎线程):取消与该对端相关的全部任务。 */
    public void cancelForPeer(String fp, String reason) {
        for (Outgoing t : outgoing.values()) {
            if (fp.equals(t.targetFp)) {
                finishOutgoing(t.id, t, false, "发送 " + t.name + " 失败: " + reason);
            }
        }
        for (Incoming t : incoming.values()) {
            if (fp.equals(t.sourceFp)) {
                incoming.remove(t.id);
                closeQuietly(t.fos);
                if (t.tempFile != null) t.tempFile.delete();
                events.onTransferFinished(t.id, t.name, false, "接收 " + t.name + " 失败: " + reason, true, null, null);
            }
        }
    }

    // ================= 落盘 =================

    /** API 29+ 走 MediaStore 公共 Downloads/ProtoSync(免存储权限);失败退回应用目录。
     *  返回 {绝对路径, content URI(可为 null)}。 */
    private String[] saveReceived(File tmp, String name) throws Exception {
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
                    try (InputStream in = new BufferedInputStream(new FileInputStream(tmp));
                         OutputStream os = context.getContentResolver().openOutputStream(uri)) {
                        if (os == null) throw new IOException("无法写入系统下载目录");
                        byte[] buffer = new byte[1024 * 1024];
                        int n;
                        while ((n = in.read(buffer)) >= 0) if (n > 0) os.write(buffer, 0, n);
                    }
                    ContentValues published = new ContentValues();
                    published.put(MediaStore.MediaColumns.IS_PENDING, 0);
                    context.getContentResolver().update(uri, published, null, null);
                    tmp.delete();
                    return new String[]{
                            new File(Environment.getExternalStoragePublicDirectory(
                                    Environment.DIRECTORY_DOWNLOADS), "ProtoSync/" + name).getAbsolutePath(),
                            uri.toString()};
                }
            } catch (Exception e) {
                if (uri != null) {
                    try { context.getContentResolver().delete(uri, null, null); } catch (Exception ignored) {}
                }
                throw e; // 公共目录失败不静默降级,由调用方决定(保留临时文件并报告)
            }
        }
        File base = context.getExternalFilesDir(null);
        File dir = new File(base != null ? base : context.getFilesDir(), "ProtoSync");
        if (!dir.exists() && !dir.mkdirs()) throw new IOException("无法创建接收目录");
        File out = availableFile(dir, name);
        if (!tmp.renameTo(out)) {
            try (InputStream in = new BufferedInputStream(new FileInputStream(tmp));
                 OutputStream os = new BufferedOutputStream(new FileOutputStream(out))) {
                byte[] buffer = new byte[1024 * 1024];
                int n;
                while ((n = in.read(buffer)) >= 0) if (n > 0) os.write(buffer, 0, n);
            }
            tmp.delete();
        }
        return new String[]{out.getAbsolutePath(), null};
    }

    private File incomingDir() throws IOException {
        File base = context.getExternalFilesDir(null);
        File dir = new File(base != null ? base : new File(context.getFilesDir(), "ext"), "ProtoSync");
        if (!dir.exists() && !dir.mkdirs()) throw new IOException("无法创建临时目录");
        return dir;
    }

    // ================= 校验工具(对齐 Swift FileTransferGuard)=================

    public static boolean isValidTransferId(String id) {
        return id != null && !id.isEmpty() && id.length() <= 64
                && id.matches("[A-Za-z0-9-]{1,64}");
    }

    public static boolean isValidSha256(String s) {
        if (s == null || s.length() != 64) return false;
        for (char c : s.toCharArray()) {
            boolean hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
            if (!hex) return false;
        }
        return true;
    }

    /** 远端文件名:只留 basename,拒绝空/./..、路径分隔符、控制字符,限长 200。 */
    public static String sanitizeFileName(String raw) {
        String name = raw == null ? "" : raw.trim().replace("\0", "_");
        if (name.contains("/") || name.contains("\\") || name.contains(":")) name = "file";
        name = name.substring(name.lastIndexOf('/') + 1);
        if (name.isEmpty() || ".".equals(name) || "..".equals(name)) name = "file";
        for (char c : name.toCharArray()) {
            if (c < 0x20 || c == 0x7f) { name = "file"; break; }
        }
        return name.length() > 200 ? name.substring(0, 200) : name;
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

    private static byte[] sha256File(File file) throws IOException {
        MessageDigest digest = Crypto.sha256();
        try (InputStream in = new BufferedInputStream(new FileInputStream(file))) {
            byte[] buffer = new byte[1024 * 1024];
            int n;
            while ((n = in.read(buffer)) >= 0) if (n > 0) digest.update(buffer, 0, n);
        }
        return digest.digest();
    }

    private static void closeQuietly(java.io.Closeable c) {
        if (c == null) return;
        try { c.close(); } catch (IOException ignored) {}
    }
}
