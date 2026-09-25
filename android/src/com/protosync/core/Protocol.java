package com.protosync.core;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.DataInputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

/**
 * 线协议:每帧 = 4 字节大端长度 + 载荷。握手阶段载荷是明文 JSON;
 * established 后载荷 = 12B nonce ‖ ChaCha20-Poly1305 密文 ‖ 16B tag。
 * 与 macOS Swift 端逐字节对齐(FrameCodec.maxFrameSize = 64MB)。
 */
public final class Protocol {
    public static final String TYPE_HELLO = "hello";
    public static final String TYPE_AUTH = "auth";
    public static final String TYPE_CLIPBOARD = "clipboard";
    public static final String TYPE_FILE_OFFER = "file_offer";
    public static final String TYPE_FILE_CHUNK = "file_chunk";
    public static final String TYPE_FILE_DONE = "file_done";
    public static final String TYPE_FILE_ACK = "file_ack";
    public static final String TYPE_ERROR = "error";
    public static final String TYPE_PING = "ping";

    /** established 后的帧上限,与 Swift FrameCodec.maxFrameSize 对齐(旧实现 16MB 会导致 Mac 大剪贴板断连)。 */
    public static final int MAX_ESTABLISHED_FRAME = 64 * 1024 * 1024;
    /** 握手阶段帧上限(hello/auth 都远小于此,防御性收窄)。 */
    public static final int MAX_HANDSHAKE_FRAME = 64 * 1024 * 1024;

    public static final int CHUNK_SIZE = 192 * 1024;
    public static final int WINDOW = 16;

    private Protocol() {}

    /** JSONObject.put 抛受检异常,链式构建太吵;转为非受检。 */
    public static class Msg extends JSONObject {
        public Msg() {}
        public Msg(String json) throws JSONException { super(json); }
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

    public static byte[] frame(JSONObject m) {
        return frame(m.toString().getBytes(StandardCharsets.UTF_8));
    }

    public static byte[] frame(byte[] payload) {
        byte[] out = new byte[4 + payload.length];
        out[0] = (byte) (payload.length >>> 24);
        out[1] = (byte) (payload.length >>> 16);
        out[2] = (byte) (payload.length >>> 8);
        out[3] = (byte) payload.length;
        System.arraycopy(payload, 0, out, 4, payload.length);
        return out;
    }

    /** 阻塞读一帧;返回载荷(不含长度前缀)。maxFrame 由调用方按握手状态决定。 */
    public static byte[] readFrame(DataInputStream in, int maxFrame) throws IOException {
        int len;
        try {
            len = in.readInt();
        } catch (EOFException done) {
            throw done;
        }
        if (len <= 0 || len > maxFrame) throw new IOException("帧长度异常: " + len);
        byte[] payload = new byte[len];
        in.readFully(payload);
        return payload;
    }

    public static void writeFrame(OutputStream out, byte[] framed) throws IOException {
        out.write(framed);
        out.flush();
    }

    public static byte[] readFully(InputStream in, int length) throws IOException {
        byte[] out = new byte[length];
        int offset = 0;
        while (offset < length) {
            int n = in.read(out, offset, length - offset);
            if (n < 0) throw new EOFException("输入提前结束");
            offset += n;
        }
        return out;
    }

    public static Msg clipboardText(String text, String hash, boolean force) {
        Msg m = new Msg().put("type", TYPE_CLIPBOARD).put("kind", "text")
                .put("data", text).put("hash", hash);
        if (force) m.put("force", true);
        return m;
    }

    public static Msg clipboardImage(byte[] png, String hash, boolean force) {
        Msg m = new Msg().put("type", TYPE_CLIPBOARD).put("kind", "image")
                .put("data", android.util.Base64.encodeToString(png, android.util.Base64.NO_WRAP))
                .put("hash", hash);
        if (force) m.put("force", true);
        return m;
    }
}
