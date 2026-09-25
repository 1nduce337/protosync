package com.protosync.app;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.net.wifi.WifiManager;
import android.os.Binder;
import android.os.IBinder;
import android.os.PowerManager;
import android.util.Log;

import com.protosync.core.SyncCore;

import java.util.ArrayDeque;

/**
 * 前台服务:持有 SyncCore 生命周期,App 退到后台连接不断。
 * 协议与并发全部在 com.protosync.core;本类只负责前台保活、通知与
 * 「UI 不在前台/息屏时的请求排队」(配对请求队列、剪贴板/文件暂存与横幅通知)。
 *
 * 通知渠道设计(渠道重要性创建后不可改,历史渠道直接删除重建):
 * - CHANNEL_CLIP_HI(HIGH):收到剪贴板文本/图片 → 横幅弹出;文本带「复制」按钮
 *   (经透明 CopyActivity 拿焦点后写入,见该类说明)
 * - CHANNEL_FILE(DEFAULT):收到文件 → 普通通知进任务中心,点按/「查看」直接打开
 *   (MediaStore content URI,VIEW + 授权读,无需 FileProvider)
 * - CHANNEL_PAIR(HIGH):配对请求横幅
 * - CHANNEL_SVC(LOW):前台服务常驻
 */
public class SyncService extends Service {
    private static final String TAG = "ProtoSync";
    public static final String CHANNEL_SVC = "protosync_service";
    public static final String CHANNEL_PAIR = "protosync_pairing";
    public static final String CHANNEL_CLIP_HI = "protosync_clipboard_h";
    public static final String CHANNEL_FILE = "protosync_file";
    @SuppressWarnings("unused")
    private static final String LEGACY_CHANNEL_CLIP = "protosync_clipboard"; // 已删除的旧 DEFAULT 渠道

    private static final int NOTIF_CLIP = 3;
    private static final int NOTIF_FILE = 4;

    private volatile SyncCore core;
    private WifiManager.MulticastLock multicastLock;
    private NotificationManager nm;

    private final Object clientLock = new Object();
    private Ui ui;
    private final ArrayDeque<PendingPair> pendingPairs = new ArrayDeque<>();
    private PendingPair activePair;
    private long pairGeneration = 0;
    private String pendingClipboardText;
    private byte[] pendingClipboardImage;

    private static class PendingPair {
        final String name, fp;
        PendingPair(String n, String f) { name = n; fp = f; }
    }

    public class LocalBinder extends Binder {
        SyncService get() { return SyncService.this; }
    }
    private final LocalBinder binder = new LocalBinder();

    public SyncCore core() { return core; }
    public boolean isReady() { return core != null && core.isRunning(); }

    @Override
    public void onCreate() {
        super.onCreate();
        WifiManager wifi = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
        if (wifi != null) {
            multicastLock = wifi.createMulticastLock("protosync");
            multicastLock.setReferenceCounted(false);
            try {
                multicastLock.acquire();
            } catch (SecurityException e) {
                // 没有组播锁发现会退化;手动连接与缓存地址重连仍然可用
                Log.w(TAG, "multicast lock unavailable", e);
                multicastLock = null;
            }
        }
        nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        nm.createNotificationChannel(new NotificationChannel(CHANNEL_SVC, "同步服务", NotificationManager.IMPORTANCE_LOW));
        // 渠道的声音/振动设置只在首次创建生效:删除重建,让新的提醒配置落地
        nm.deleteNotificationChannel(CHANNEL_PAIR);
        nm.deleteNotificationChannel(CHANNEL_CLIP_HI);
        nm.createNotificationChannel(highChannel(CHANNEL_PAIR, "配对请求"));
        nm.createNotificationChannel(highChannel(CHANNEL_CLIP_HI, "剪贴板接收(横幅)"));
        nm.createNotificationChannel(new NotificationChannel(CHANNEL_FILE, "文件接收", NotificationManager.IMPORTANCE_DEFAULT));
        nm.deleteNotificationChannel(LEGACY_CHANNEL_CLIP); // 旧渠道重要性不足且不可升级
        startForeground(1, notification("启动中…"));
        new Thread(() -> {
            try {
                SyncCore c = new SyncCore(getApplicationContext());
                c.start(forwarder);
                core = c;
                updateNotification();
                dispatchNextPair();
            } catch (Exception e) {
                Log.e(TAG, "engine init failed", e);
                updateNotificationText("启动失败: " + e.getMessage());
            }
        }, "engine-init").start();
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) { return START_STICKY; }
    @Override public IBinder onBind(Intent intent) { return binder; }

    @Override
    public void onDestroy() {
        if (core != null) core.stop();
        if (multicastLock != null && multicastLock.isHeld()) multicastLock.release();
        super.onDestroy();
    }

    // ================= UI 绑定 =================

    public interface Ui {
        void onLog(String line);
        void onPeerConnected(String name, String fp);
        void onPeerDisconnected(String fp, String reason);
        void onPairingRequested(String name, String fp);
        void onClipboardText(String text);
        void onClipboardImage(byte[] png);
        void onClipboardResult(boolean ok, String detail);
        void onStateChanged();
        void onTransferStarted(String id, String name, boolean incoming);
        void onTransferProgress(String id, String name, double fraction, boolean incoming);
        void onTransferFinished(String id, String name, boolean ok, String error,
                                boolean incoming, String savedPath, String savedUri);
        void onActivityChanged();
    }

    /** UI 可见且屏幕亮着才算「在场」;息屏时即使 Activity 未走 onStop 也按后台处理(走横幅通知)。 */
    private boolean uiPresent() {
        if (currentUi() == null) return false;
        PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
        return pm == null || pm.isInteractive();
    }

    /** Activity attach/detach;detach 时把未决配对请求重新排队。 */
    public void attach(Ui d) {
        synchronized (clientLock) {
            ui = d;
        }
        if (isReady()) d.onStateChanged();
        dispatchNextPair();
        String text;
        byte[] image;
        synchronized (clientLock) {
            text = pendingClipboardText;
            image = pendingClipboardImage;
            pendingClipboardText = null;
            pendingClipboardImage = null;
        }
        if (text != null) nm.cancel(NOTIF_CLIP);
        if (image != null) nm.cancel(NOTIF_CLIP);
        if (isInteractive()) {
            if (text != null) d.onClipboardText(text);
            if (image != null) d.onClipboardImage(image);
        } else {
            // 息屏时写剪贴板会被系统忽略:重新暂存,亮屏后(下次事件或再 attach)交付
            synchronized (clientLock) {
                if (text != null) pendingClipboardText = text;
                if (image != null) pendingClipboardImage = image;
            }
        }
        if (isReady()) d.onActivityChanged();
    }

    private boolean isInteractive() {
        PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
        return pm != null && pm.isInteractive();
    }

    public void detach(Ui d) {
        synchronized (clientLock) {
            if (ui != d) return;
            ui = null;
            if (activePair != null) {
                pendingPairs.addFirst(activePair);
                activePair = null;
            }
        }
    }

    /** 逐个派发配对弹窗;决定由 decidePairing(fp, accept) 推进队列。 */
    private void dispatchNextPair() {
        final PendingPair p;
        final Ui d;
        synchronized (clientLock) {
            if (ui == null || activePair != null || pendingPairs.isEmpty()) return;
            d = ui;
            p = pendingPairs.removeFirst();
            activePair = p;
            pairGeneration++;
        }
        nm.cancel(2);
        d.onPairingRequested(p.name, p.fp);
    }

    /** UI 对当前配对弹窗作出决定(主线程)。陈旧决定被代际号拦下。 */
    public void decidePairing(String fp, boolean accept) {
        synchronized (clientLock) {
            if (activePair == null || !activePair.fp.equals(fp)) return;
            activePair = null;
        }
        if (core != null) core.acceptPairing(fp, accept);
        dispatchNextPair();
    }

    // ================= 引擎事件转发 =================

    private final SyncCore.Listener forwarder = new SyncCore.Listener() {
        @Override public void onLog(String line) {
            // 引擎层 postLog 已写过 Log.d,这里只转发 UI,避免日志翻倍
            Ui d = currentUi(); if (d != null) d.onLog(line);
        }
        @Override public void onPeerConnected(String name, String fp) {
            clearActivePair(fp); // 已配对成功(可能由对端 accept 驱动)
            updateNotification();
            Ui d = currentUi(); if (d != null) d.onPeerConnected(name, fp);
        }
        @Override public void onPeerDisconnected(String fp, String reason) {
            updateNotification();
            Ui d = currentUi(); if (d != null) d.onPeerDisconnected(fp, reason);
        }
        @Override public void onPairingRequested(String name, String fp) {
            synchronized (clientLock) {
                for (PendingPair pp : pendingPairs) if (pp.fp.equals(fp)) return; // 去重
                pendingPairs.addLast(new PendingPair(name, fp));
            }
            dispatchNextPair();
            if (currentUi() == null) notifyPairing(name, fp);
        }
        @Override public void onClipboardText(String text) {
            if (uiPresent()) {
                currentUi().onClipboardText(text);
            } else {
                synchronized (clientLock) { pendingClipboardText = text; }
                notifyClipboardText(text);
            }
        }
        @Override public void onClipboardImage(byte[] png) {
            if (uiPresent()) {
                Ui d = currentUi(); if (d != null) d.onClipboardImage(png);
            } else {
                synchronized (clientLock) { pendingClipboardImage = png; }
                notifyClipboardImage(png);
            }
        }
        @Override public void onClipboardResult(boolean ok, String detail) {
            Ui d = currentUi(); if (d != null) d.onClipboardResult(ok, detail);
        }
        @Override public void onDiscoveredChanged() {
            Ui d = currentUi(); if (d != null) d.onStateChanged();
        }
        @Override public void onTransferStarted(String id, String name, boolean incoming) {
            Ui d = currentUi(); if (d != null) d.onTransferStarted(id, name, incoming);
        }
        @Override public void onTransferProgress(String id, String name, double fraction, boolean incoming) {
            Ui d = currentUi(); if (d != null) d.onTransferProgress(id, name, fraction, incoming);
        }
        @Override public void onTransferFinished(String id, String name, boolean ok, String error,
                                                 boolean incoming, String savedPath, String savedUri) {
            if (incoming && ok && savedPath != null && !uiPresent()) {
                notifyFile(name, savedPath, savedUri);
            }
            Ui d = currentUi(); if (d != null) d.onTransferFinished(id, name, ok, error, incoming, savedPath, savedUri);
        }
        @Override public void onActivityChanged() {
            Ui d = currentUi(); if (d != null) d.onActivityChanged();
        }
    };

    private Ui currentUi() {
        synchronized (clientLock) { return ui; }
    }

    private void clearActivePair(String fp) {
        synchronized (clientLock) {
            if (activePair != null && activePair.fp.equals(fp)) activePair = null;
        }
    }

    // ================= 通知 =================

    /**
     * HIGH 渠道模板:显式开启声音+振动。部分 OEM(ColorOS 等)对「无提醒动作」的
     * HIGH 渠道仍会在投递时把实际重要度降为 DEFAULT,导致横幅不弹;
     * 渠道带上提醒动作后一般可恢复(渠道重要性只在首次创建生效,删除重建)。
     */
    private NotificationChannel highChannel(String id, String name) {
        NotificationChannel c = new NotificationChannel(id, name, NotificationManager.IMPORTANCE_HIGH);
        c.setSound(android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_NOTIFICATION),
                new android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION)
                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build());
        c.enableVibration(true);
        return c;
    }

    private PendingIntent openActivity() {
        Intent i = new Intent(this, MainActivity.class);
        i.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        return PendingIntent.getActivity(this, 0, i, PendingIntent.FLAG_IMMUTABLE);
    }

    private Notification notification(String text) {
        return new Notification.Builder(this, CHANNEL_SVC)
                .setSmallIcon(android.R.drawable.stat_notify_sync)
                .setContentTitle("ProtoSync")
                .setContentText(text)
                .setOngoing(true)
                .setContentIntent(openActivity())
                .build();
    }

    private void updateNotification() {
        int n = core == null ? 0 : core.onlinePeersSnapshot().size();
        updateNotificationText(n + " 台设备在线");
    }

    private void updateNotificationText(String text) {
        nm.notify(1, notification(text));
    }

    /** 后台收到文本:横幅 + 「复制」按钮(透明 Activity 拿焦点后写入)。 */
    private void notifyClipboardText(String text) {
        String preview = text.length() > 60 ? text.substring(0, 60) + "…" : text;
        Notification.Builder b = new Notification.Builder(this, CHANNEL_CLIP_HI)
                .setSmallIcon(android.R.drawable.ic_menu_edit)
                .setContentTitle("收到剪贴板文本")
                .setContentText(preview)
                .setCategory(Notification.CATEGORY_MESSAGE)
                .setPriority(Notification.PRIORITY_MAX) // 遗留字段,部分 OEM 投递逻辑仍参考
                .setAutoCancel(true)
                .setContentIntent(openActivity());
        if (text.length() <= 4000) {
            b.setStyle(new Notification.BigTextStyle().bigText(
                    text.length() > 500 ? text.substring(0, 500) + "…" : text));
        }
        if (text.length() <= 2_000_000) { // 超长文本不走按钮,点通知进 App 复制
            CopyActivity.stage(text);
            Intent copy = new Intent(this, CopyActivity.class);
            PendingIntent pi = PendingIntent.getActivity(this, 1, copy,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
            b.addAction(new Notification.Action.Builder(null, "复制", pi).build());
        }
        nm.notify(NOTIF_CLIP, b.build());
    }

    /** 后台收到图片:横幅 + 大图预览(点通知进 App 后写入剪贴板)。 */
    private void notifyClipboardImage(byte[] png) {
        Notification.Builder b = new Notification.Builder(this, CHANNEL_CLIP_HI)
                .setSmallIcon(android.R.drawable.ic_menu_gallery)
                .setContentTitle("收到剪贴板图片")
                .setContentText(png.length / 1024 + " KB,点按复制到剪贴板")
                .setAutoCancel(true)
                .setContentIntent(openActivity());
        try {
            android.graphics.Bitmap bmp = android.graphics.BitmapFactory.decodeByteArray(png, 0, png.length);
            if (bmp != null) {
                b.setStyle(new Notification.BigPictureStyle()
                        .bigPicture(bmp)
                        .setSummaryText(png.length / 1024 + " KB"));
            }
        } catch (Throwable ignored) {}
        nm.notify(NOTIF_CLIP, b.build());
    }

    /** 后台收到文件:普通通知;「查看」用 chooser 兜底(无查看器时也能选应用打开)。 */
    private void notifyFile(String name, String path, String uri) {
        Notification.Builder b = new Notification.Builder(this, CHANNEL_FILE)
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle("收到文件 " + name)
                .setContentText("已保存到 Downloads/ProtoSync,点按打开 ProtoSync")
                .setAutoCancel(true)
                .setContentIntent(openActivity());
        if (uri != null) {
            Intent view = new Intent(Intent.ACTION_VIEW)
                    .setDataAndType(android.net.Uri.parse(uri), mimeFromName(name))
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            PendingIntent pi = PendingIntent.getActivity(this,
                    (name + path).hashCode(),
                    Intent.createChooser(view, "打开文件"),
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
            b.addAction(new Notification.Action.Builder(null, "查看", pi).build());
        }
        // 以路径为 tag:同名不同文件各自一条,重复收到同一文件则原地更新
        nm.notify("file:" + path, NOTIF_FILE, b.build());
    }

    private static String mimeFromName(String name) {
        String ext = name.contains(".") ? name.substring(name.lastIndexOf('.') + 1).toLowerCase() : "";
        String mime = android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext);
        return mime != null ? mime : "*/*";
    }

    private void notifyPairing(String name, String fp) {
        Notification n = new Notification.Builder(this, CHANNEL_PAIR)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle("配对请求")
                .setContentText(name + " (" + fp.substring(0, Math.min(8, fp.length())) + ") 请求配对,点击处理")
                .setAutoCancel(true)
                .setContentIntent(openActivity())
                .build();
        nm.notify(2, n);
    }
}
