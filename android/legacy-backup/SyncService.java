package com.protosync.app;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.net.nsd.NsdManager;
import android.os.Binder;
import android.os.IBinder;
import android.util.Log;

import java.util.ArrayDeque;

/**
 * 前台服务:持有 ProtoEngine 生命周期,App 退到后台连接不断。
 * UI(MainActivity)通过 bind 拿引擎引用;未绑定时配对请求走通知引导。
 */
public class SyncService extends Service {
    private static final String TAG = "ProtoSync";
    public static final String CHANNEL_SVC = "protosync_service";
    public static final String CHANNEL_PAIR = "protosync_pairing";
    public static final String CHANNEL_CLIP = "protosync_clipboard";

    private volatile ProtoEngine engine;
    private android.net.wifi.WifiManager.MulticastLock multicastLock;
    private volatile boolean ready = false;
    private final Object clientLock = new Object();
    private ProtoEngine.Delegate ui;
    private final ArrayDeque<PendingPair> pendingPairs = new ArrayDeque<>();
    private PendingPair activePair;
    private long pairGeneration = 0;
    private String pendingClipboard;

    private static class PendingPair {
        final String name, fp;
        final ProtoEngine.DecisionCallback cb;
        PendingPair(String n, String f, ProtoEngine.DecisionCallback c) { name = n; fp = f; cb = c; }
    }

    public class LocalBinder extends Binder {
        SyncService get() { return SyncService.this; }
    }
    private final LocalBinder binder = new LocalBinder();

    @Override
    public void onCreate() {
        super.onCreate();
        // 后台 NSD 可靠性:持有组播锁,防止 Wi-Fi 休眠时丢 mDNS
        android.net.wifi.WifiManager wifi = (android.net.wifi.WifiManager)
                getApplicationContext().getSystemService(Context.WIFI_SERVICE);
        if (wifi != null) {
            multicastLock = wifi.createMulticastLock("protosync");
            multicastLock.setReferenceCounted(false);
            try {
                multicastLock.acquire();
            } catch (SecurityException e) {
                // Discovery may be less reliable without the lock, but the service,
                // manual connection, and cached-address reconnect must still work.
                Log.w(TAG, "multicast lock unavailable", e);
                multicastLock = null;
            }
        }
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        nm.createNotificationChannel(new NotificationChannel(CHANNEL_SVC, "同步服务", NotificationManager.IMPORTANCE_LOW));
        nm.createNotificationChannel(new NotificationChannel(CHANNEL_PAIR, "配对请求", NotificationManager.IMPORTANCE_HIGH));
        nm.createNotificationChannel(new NotificationChannel(CHANNEL_CLIP, "剪贴板接收", NotificationManager.IMPORTANCE_DEFAULT));
        startForeground(1, notification("启动中…"));
        new Thread(() -> {
            try {
                NsdManager nsd = (NsdManager) getSystemService(Context.NSD_SERVICE);
                // Build the engine privately and publish it only when identity,
                // listener, and discovery are all ready. This prevents a binder
                // client from observing a null fingerprint or half-started engine.
                ProtoEngine initialized = new ProtoEngine(this, nsd, forwarder);
                initialized.initIdentity(android.os.Build.MODEL);
                // 测试期开关:跳过配对弹窗自动接受(生产版应回退为 false)
                initialized.autoAcceptPairing = true;
                initialized.start();
                engine = initialized;
                ready = true;
                updateNotification();
                ProtoEngine.Delegate d = currentUi();
                if (d != null) d.onDiscoveredChanged();
            } catch (Exception e) {
                Log.e(TAG, "engine init failed", e);
                updateNotificationText("启动失败: " + e.getMessage());
            }
        }, "engine-init").start();
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) { return START_STICKY; }
    @Override public IBinder onBind(Intent intent) { return binder; }
    @Override public void onDestroy() {
        if (engine != null) engine.stop();
        if (multicastLock != null && multicastLock.isHeld()) multicastLock.release();
        super.onDestroy();
    }

    public ProtoEngine getEngine() { return engine; }
    public boolean isReady() { return ready; }

    public void attach(ProtoEngine.Delegate d) {
        String clipboard;
        synchronized (clientLock) {
            ui = d;
            clipboard = pendingClipboard;
            pendingClipboard = null;
        }
        if (ready && d != null) d.onDiscoveredChanged();
        dispatchNextPair();
        if (clipboard != null && d != null) {
            ((NotificationManager) getSystemService(NOTIFICATION_SERVICE)).cancel(3);
            d.onClipboardText(clipboard);
        }
    }

    public void detach(ProtoEngine.Delegate d) {
        synchronized (clientLock) {
            if (ui != d) return;
            ui = null;
            // The old Activity may be destroyed while its dialog is showing.
            // Requeue the request; a generation token makes its stale callback inert.
            if (activePair != null) {
                pendingPairs.addFirst(activePair);
                activePair = null;
            }
        }
    }

    private ProtoEngine.Delegate currentUi() {
        synchronized (clientLock) { return ui; }
    }

    /** 引擎回调转发:有 UI 给 UI,没有就记日志/发通知。 */
    private final ProtoEngine.Delegate forwarder = new ProtoEngine.Delegate() {
        @Override public void postLog(String line) {
            Log.d(TAG, line);
            ProtoEngine.Delegate d = currentUi(); if (d != null) d.postLog(line);
        }
        @Override public void onPeerConnected(String name, String fp) {
            updateNotification();
            ProtoEngine.Delegate d = currentUi(); if (d != null) d.onPeerConnected(name, fp);
        }
        @Override public void onPeerDisconnected(String fp, String error) {
            updateNotification();
            ProtoEngine.Delegate d = currentUi(); if (d != null) d.onPeerDisconnected(fp, error);
        }
        @Override public void onPairingRequested(String name, String fp, ProtoEngine.DecisionCallback cb) {
            synchronized (clientLock) { pendingPairs.addLast(new PendingPair(name, fp, cb)); }
            dispatchNextPair();
            if (currentUi() == null) notifyPairing(name, fp);
        }
        @Override public void onClipboardText(String text) {
            ProtoEngine.Delegate d;
            synchronized (clientLock) {
                d = ui;
                if (d == null) pendingClipboard = text;
            }
            if (d != null) d.onClipboardText(text);
            else notifyClipboard();
        }
        @Override public void onDiscoveredChanged() {
            ProtoEngine.Delegate d = currentUi(); if (d != null) d.onDiscoveredChanged();
        }
        @Override public void onFileEvent(String line) {
            ProtoEngine.Delegate d = currentUi(); if (d != null) d.onFileEvent(line);
        }
    };

    /** Deliver one pairing dialog at a time; the callback advances the queue. */
    private void dispatchNextPair() {
        final PendingPair p;
        final ProtoEngine.Delegate d;
        final long generation;
        synchronized (clientLock) {
            if (ui == null || activePair != null || pendingPairs.isEmpty()) return;
            d = ui;
            p = pendingPairs.removeFirst();
            activePair = p;
            generation = ++pairGeneration;
        }
        ((NotificationManager) getSystemService(NOTIFICATION_SERVICE)).cancel(2);
        d.onPairingRequested(p.name, p.fp, accept -> {
            synchronized (clientLock) {
                if (activePair != p || pairGeneration != generation) return;
                activePair = null;
            }
            p.cb.decide(accept);
            dispatchNextPair();
        });
    }

    private PendingIntent openActivity() {
        Intent i = new Intent(this, MainActivity.class);
        i.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        return PendingIntent.getActivity(this, 0, i, PendingIntent.FLAG_IMMUTABLE);
    }

    private Notification notification(String text) {
        return new Notification.Builder(this, CHANNEL_SVC)
                .setSmallIcon(android.R.drawable.ic_menu_share)
                .setContentTitle("ProtoSync")
                .setContentText(text)
                .setOngoing(true)
                .setContentIntent(openActivity())
                .build();
    }

    private void updateNotification() {
        int n = engine == null ? 0 : engine.onlinePeers().size();
        updateNotificationText(n + " 台设备在线");
    }

    private void updateNotificationText(String text) {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        nm.notify(1, notification(text));
    }

    private void notifyPairing(String name, String fp) {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        Notification n = new Notification.Builder(this, CHANNEL_PAIR)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle("配对请求")
                .setContentText(name + " (" + fp.substring(0, 8) + ") 请求配对,点击处理")
                .setAutoCancel(true)
                .setContentIntent(openActivity())
                .build();
        nm.notify(2, n);
    }

    private void notifyClipboard() {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        Notification n = new Notification.Builder(this, CHANNEL_CLIP)
                .setSmallIcon(android.R.drawable.ic_menu_edit)
                .setContentTitle("收到剪贴板内容")
                .setContentText("点按打开 ProtoSync 并复制")
                .setAutoCancel(true)
                .setContentIntent(openActivity())
                .build();
        nm.notify(3, n);
    }
}
