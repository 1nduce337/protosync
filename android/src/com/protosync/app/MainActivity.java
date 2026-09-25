package com.protosync.app;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipDescription;
import android.content.ClipboardManager;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.graphics.BitmapFactory;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.provider.MediaStore;
import android.text.method.ScrollingMovementMethod;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import com.protosync.core.SyncCore;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Signal Foundry 单页指挥面板(设计文档 §8.2):
 * System Header → 主操作 → Transfer Track(按需)→ 已配对 / 附近 / 活动 → 诊断折叠区。
 * 所有引擎调用都是 SyncCore 的投递式 API,UI 线程不做任何网络 I/O。
 */
public class MainActivity extends Activity implements SyncService.Ui {
    private SyncService svc;
    private SyncCore core; // 可能为 null(服务引擎尚未就绪)

    private TextView statusText, onlineCount, fingerprintText;
    private TextView transferProgressName, transferProgressPercent, transferMoreLabel;
    private LinearLayout deviceList, nearbyList, activityList, transferCard, diagPanel;
    private TransferTrackView transferTrack;
    private TextView logView, diagToggle;
    private EditText manualInput;
    private Button scanButton;
    private final StringBuilder logBuf = new StringBuilder();
    private android.app.AlertDialog pairingDialog;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private boolean diagExpanded = false;

    /** 活动传输:id → 展示状态(完成/失败态短暂停留后自动清出)。 */
    private static class TransferUi {
        String name; double fraction; boolean incoming;
        String state; // syncing | done | failed
    }
    private final LinkedHashMap<String, TransferUi> transfers = new LinkedHashMap<>();

    private static final int REQ_PICK_FILE = 42;
    private static final String STATE_TARGET_FP = "pendingFileTargetFp";
    private String pendingFileTargetFp;
    private String savedTargetFp;

    private final ServiceConnection conn = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder service) {
            svc = ((SyncService.LocalBinder) service).get();
            core = svc.isReady() ? svc.core() : null;
            svc.attach(MainActivity.this);
        }
        @Override public void onServiceDisconnected(ComponentName name) {
            svc = null;
            core = null;
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        // 平台 DayNight 主题 API 29+;更早设备退回深色 DeviceDefault
        if (Build.VERSION.SDK_INT >= 29) setTheme(android.R.style.Theme_DeviceDefault_DayNight);
        else setTheme(android.R.style.Theme_DeviceDefault);
        super.onCreate(savedInstanceState);
        setTitle("ProtoSync");
        if (savedInstanceState != null) {
            savedTargetFp = savedInstanceState.getString(STATE_TARGET_FP);
        }

        setContentView(R.layout.activity_main);
        statusText = findViewById(R.id.statusText);
        onlineCount = findViewById(R.id.onlineCount);
        deviceList = findViewById(R.id.deviceList);
        nearbyList = findViewById(R.id.nearbyList);
        activityList = findViewById(R.id.activityList);
        transferCard = findViewById(R.id.transferCard);
        transferTrack = findViewById(R.id.transferTrack);
        transferProgressName = findViewById(R.id.transferName);
        transferProgressPercent = findViewById(R.id.transferPercent);
        transferMoreLabel = findViewById(R.id.transferMore);
        fingerprintText = findViewById(R.id.fingerprintText);
        logView = findViewById(R.id.logView);
        logView.setMovementMethod(new ScrollingMovementMethod());
        diagToggle = findViewById(R.id.diagToggle);
        diagPanel = findViewById(R.id.diagPanel);
        manualInput = findViewById(R.id.manualInput);
        scanButton = findViewById(R.id.scanButton);

        ((ImageView) findViewById(R.id.logo)).setImageResource(
                isNightMode() ? R.drawable.protosync_logo_dark : R.drawable.protosync_logo_light);

        findViewById(R.id.sendClipboardButton).setOnClickListener(v -> sendClipboard());
        findViewById(R.id.sendFileButton).setOnClickListener(v -> pickFileWithChooser());
        findViewById(R.id.connectButton).setOnClickListener(v -> manualConnect());
        scanButton.setOnClickListener(v -> {
            if (core == null) { toast("引擎启动中"); return; }
            core.refreshDiscovery();
            scanButton.setText("SCAN…");
            scanButton.postDelayed(() -> scanButton.setText("SCAN"), 1200);
        });
        diagToggle.setOnClickListener(v -> {
            diagExpanded = !diagExpanded;
            diagPanel.setVisibility(diagExpanded ? View.VISIBLE : View.GONE);
            diagToggle.setText(diagExpanded ? "高级连接与诊断 ▾" : "高级连接与诊断 ▸");
        });

        if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{android.Manifest.permission.POST_NOTIFICATIONS}, 1);
        }

        startForegroundService(new Intent(this, SyncService.class));
    }

    private boolean isNightMode() {
        int mask = getResources().getConfiguration().uiMode
                & android.content.res.Configuration.UI_MODE_NIGHT_MASK;
        return mask == android.content.res.Configuration.UI_MODE_NIGHT_YES;
    }

    @Override
    protected void onStart() {
        super.onStart();
        bindService(new Intent(this, SyncService.class), conn, 0);
    }

    @Override
    protected void onStop() {
        if (svc != null) svc.detach(this);
        unbindService(conn);
        super.onStop();
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        outState.putString(STATE_TARGET_FP, pendingFileTargetFp);
    }

    // ---- 主操作 ----

    /** 手动发送剪贴板:文本优先,其次图片。发送结果由 onClipboardResult 回调提示。 */
    private void sendClipboard() {
        if (core == null) { toast("引擎启动中"); return; }
        ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        ClipData clip = cm.getPrimaryClip();
        if (clip == null || clip.getItemCount() == 0) { toast("剪贴板为空"); return; }
        ClipData.Item item = clip.getItemAt(0);

        CharSequence text = item.coerceToText(this);
        if (text != null && text.length() > 0) {
            core.sendClipboardText(text.toString());
            return;
        }
        // 剪贴板是图片:读 URI → PNG 重编码 → kind:image(Mac 端原生支持)
        if (clip.getDescription().hasMimeType(ClipDescription.MIMETYPE_TEXT_INTENT)
                || item.getUri() == null) {
            toast("剪贴板没有可同步的内容");
            return;
        }
        try (InputStream in = getContentResolver().openInputStream(item.getUri())) {
            if (in == null) { toast("无法读取剪贴板图片"); return; }
            android.graphics.Bitmap bmp = BitmapFactory.decodeStream(in);
            if (bmp == null) { toast("无法解码剪贴板图片"); return; }
            java.io.ByteArrayOutputStream bos = new java.io.ByteArrayOutputStream();
            bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, bos);
            bmp.recycle();
            core.sendClipboardImage(bos.toByteArray());
        } catch (Exception e) {
            toast("读取剪贴板图片失败: " + e.getMessage());
        }
    }

    private void pickFileWithChooser() {
        if (core == null) { toast("引擎启动中"); return; }
        List<String[]> online = core.onlinePeersSnapshot();
        if (online.isEmpty()) { toast("没有在线设备"); return; }
        if (online.size() == 1) { pickFile(online.get(0)[0]); return; }
        String[] names = new String[online.size()];
        for (int i = 0; i < online.size(); i++) names[i] = online.get(i)[1];
        new android.app.AlertDialog.Builder(this)
                .setTitle("发送给哪台设备?")
                .setItems(names, (d, which) -> pickFile(online.get(which)[0]))
                .show();
    }

    private void pickFile(String targetFp) {
        pendingFileTargetFp = targetFp;
        savedTargetFp = targetFp;
        Intent intent = new Intent(Intent.ACTION_GET_CONTENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("*/*");
        startActivityForResult(Intent.createChooser(intent, "选择要发送的文件"), REQ_PICK_FILE);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQ_PICK_FILE && resultCode == RESULT_OK && data != null
                && data.getData() != null) {
            // Activity 重建后目标可能丢失:无法证明原目标就中止,绝不静默改发其他设备
            String target = pendingFileTargetFp != null ? pendingFileTargetFp : savedTargetFp;
            if (target == null) { toast("发送目标丢失,请重新选择"); return; }
            boolean stillOnline = false;
            if (core != null) {
                for (String[] o : core.onlinePeersSnapshot()) if (o[0].equals(target)) stillOnline = true;
            }
            if (!stillOnline) { toast("目标设备已离线,发送取消"); return; }
            final String finalTarget = target;
            final android.net.Uri uri = data.getData();
            new Thread(() -> {
                final String name = queryName(uri);
                runOnUiThread(() -> {
                    if (core != null) core.sendFile(finalTarget, uri, name);
                });
            }).start();
        }
    }

    private String queryName(android.net.Uri uri) {
        try (android.database.Cursor c = getContentResolver().query(uri, null, null, null, null)) {
            if (c != null) {
                int idx = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME);
                if (idx >= 0 && c.moveToFirst()) return c.getString(idx);
            }
        } catch (Exception ignored) {}
        return "file";
    }

    private void manualConnect() {
        if (core == null) { toast("引擎启动中"); return; }
        String text = manualInput.getText().toString().trim();
        int colon = text.lastIndexOf(':');
        if (colon <= 0) { toast("格式:IP:端口"); return; }
        try {
            String host = text.substring(0, colon).trim();
            if (host.startsWith("[") && host.endsWith("]")) host = host.substring(1, host.length() - 1);
            Integer.parseInt(text.substring(colon + 1).trim());
            core.connectTo(host, Integer.parseInt(text.substring(colon + 1).trim()));
        } catch (Exception e) {
            toast("地址无效: " + e.getMessage());
        }
    }

    // ---- 状态渲染 ----

    private void refreshEngine() {
        if (core == null && svc != null) core = svc.isReady() ? svc.core() : null;
        if (core == null) {
            statusText.setText("引擎启动中…");
            onlineCount.setText("00");
            return;
        }
        // 引擎线程启动是异步的:isRunning 先于身份加载完成,指纹可能还是空串
        String fp = core.fingerprint();
        if (fp.length() < 8) {
            statusText.setText("引擎启动中…");
            onlineCount.setText(String.format(Locale.US, "%02d", core.onlinePeersSnapshot().size()));
            return;
        }
        statusText.setText("运行中 · 指纹 " + fp.substring(0, 8));
        onlineCount.setText(String.format(Locale.US, "%02d", core.onlinePeersSnapshot().size()));
        fingerprintText.setText("本机指纹 " + fp);
        renderDevices(core);
        renderNearby(core);
        renderActivity(core);
    }

    private void renderDevices(SyncCore core) {
        deviceList.removeAllViews();
        List<String[]> paired = core.pairedSnapshot();
        List<String[]> online = core.onlinePeersSnapshot();
        for (String[] p : paired) {
            boolean isOnline = false;
            for (String[] o : online) if (o[0].equals(p[0])) isOnline = true;
            deviceList.addView(deviceRow(p[0], p[1], isOnline));
        }
        if (paired.isEmpty()) deviceList.addView(emptyHint("暂无已配对设备,从「附近的设备」发起配对"));
    }

    private View deviceRow(String fp, String name, boolean isOnline) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setMinimumHeight(dp(48));
        row.setBackgroundResource(R.drawable.bg_panel);
        row.setPadding(dp(10), dp(6), dp(6), dp(6));
        LinearLayout.LayoutParams rowLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        rowLp.topMargin = dp(6);
        row.setLayoutParams(rowLp);

        View dot = new View(this);
        GradientDrawable dotBg = new GradientDrawable();
        dotBg.setShape(GradientDrawable.OVAL);
        dotBg.setColor(isOnline ? color(R.color.colorLime) : color(R.color.colorTextSecondary));
        dot.setBackground(dotBg);
        row.addView(dot, new LinearLayout.LayoutParams(dp(8), dp(8)));

        TextView tv = new TextView(this);
        tv.setText(String.format(Locale.US, "%s\n%s", name, fp.substring(0, 8)));
        tv.setTextColor(color(R.color.colorTextPrimary));
        tv.setTextSize(13);
        tv.setLineSpacing(0, 0.9f);
        LinearLayout.LayoutParams tvLp = new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        tvLp.leftMargin = dp(10);
        row.addView(tv, tvLp);

        TextView status = new TextView(this);
        status.setText(isOnline ? "● 在线" : "○ 离线");
        status.setTextSize(11);
        status.setFontFeatureSettings("tnum");
        status.setTextColor(color(isOnline ? R.color.colorLime : R.color.colorTextSecondary));
        status.setPadding(dp(6), 0, dp(6), 0);
        row.addView(status);

        if (isOnline) {
            row.addView(miniButton("发文件", v -> pickFile(fp)));
        }
        row.addView(miniButton("取消配对", v -> {
            if (core != null) core.removePaired(fp);
            log("已取消配对 " + name);
        }));
        return row;
    }

    private void renderNearby(SyncCore core) {
        nearbyList.removeAllViews();
        List<String[]> nearby = core.nearbySnapshot();
        for (String[] d : nearby) {
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setMinimumHeight(dp(48));
            row.setBackgroundResource(R.drawable.bg_panel);
            row.setPadding(dp(10), dp(6), dp(6), dp(6));
            LinearLayout.LayoutParams rowLp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            rowLp.topMargin = dp(6);
            row.setLayoutParams(rowLp);

            TextView tv = new TextView(this);
            tv.setText(String.format(Locale.US, "%s\n%s:%s", d[0], d[1], d[2]));
            tv.setTextColor(color(R.color.colorTextPrimary));
            tv.setTextSize(12);
            LinearLayout.LayoutParams tvLp = new LinearLayout.LayoutParams(
                    0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
            tvLp.leftMargin = dp(2);
            row.addView(tv, tvLp);
            row.addView(miniButton("配对", v -> { if (core != null) core.pairWithNearby(d[0]); }));
            nearbyList.addView(row);
        }
        if (nearby.isEmpty()) nearbyList.addView(emptyHint("暂无,点 SCAN 刷新;或用诊断区手动连接"));
    }

    private void renderActivity(SyncCore core) {
        activityList.removeAllViews();
        List<SyncCore.ActivityItem> items = core.activitySnapshot();
        SimpleDateFormat fmt = new SimpleDateFormat("HH:mm:ss", Locale.US);
        for (SyncCore.ActivityItem item : items) {
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setPadding(dp(4), dp(6), dp(4), dp(6));

            TextView arrow = new TextView(this);
            arrow.setText(item.incoming ? "↓" : "↑");
            arrow.setTextSize(13);
            arrow.setTypeface(null, android.graphics.Typeface.BOLD);
            arrow.setTextColor(color(item.failed ? R.color.colorCoral
                    : item.incoming ? R.color.colorCyan : R.color.colorLime));
            row.addView(arrow);

            TextView body = new TextView(this);
            String preview = item.title.length() > 40 ? item.title.substring(0, 40) + "…" : item.title;
            body.setText(String.format(Locale.US, "%s · %s\n%s · %s",
                    kindLabel(item.kind), preview, item.detail, fmt.format(new Date(item.time))));
            body.setTextSize(12);
            body.setTextColor(color(item.failed ? R.color.colorCoral : R.color.colorTextPrimary));
            LinearLayout.LayoutParams bodyLp = new LinearLayout.LayoutParams(
                    0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
            bodyLp.leftMargin = dp(8);
            row.addView(body, bodyLp);
            activityList.addView(row);
        }
        if (items.isEmpty()) activityList.addView(emptyHint("暂无流转记录"));
    }

    private static String kindLabel(String kind) {
        switch (kind) {
            case "text": return "文本";
            case "image": return "图片";
            case "file": return "文件";
            default: return "设备";
        }
    }

    private View emptyHint(String text) {
        TextView tv = new TextView(this);
        tv.setText("  " + text);
        tv.setTextColor(color(R.color.colorTextSecondary));
        tv.setTextSize(12);
        tv.setPadding(0, dp(6), 0, dp(6));
        return tv;
    }

    private Button miniButton(String label, View.OnClickListener onClick) {
        Button b = new Button(this);
        b.setText(label);
        b.setTextSize(11);
        b.setAllCaps(false);
        b.setMinimumWidth(dp(48));
        b.setMinimumHeight(dp(40));
        b.setTextColor(color(R.color.colorTextPrimary));
        b.setBackgroundResource(R.drawable.btn_secondary);
        b.setOnClickListener(onClick);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.leftMargin = dp(4);
        b.setLayoutParams(lp);
        return b;
    }

    // ---- 传输卡 ----

    private void renderTransferCard() {
        if (transfers.isEmpty()) {
            transferCard.setVisibility(View.GONE);
            return;
        }
        TransferUi t = transfers.values().iterator().next();
        int extra = transfers.size() - 1;
        transferCard.setVisibility(View.VISIBLE);
        transferProgressName.setText(t.name);
        int percent = (int) Math.round(t.fraction * 100);
        transferProgressPercent.setText(percent + "%");
        transferMoreLabel.setText(extra > 0 ? ("另有 " + extra + " 个任务进行中") : "");
        transferMoreLabel.setVisibility(extra > 0 ? View.VISIBLE : View.GONE);

        int cyan = color(R.color.colorCyan), lime = color(R.color.colorLime);
        int coral = color(R.color.colorCoral), text = color(R.color.colorTextPrimary);
        switch (t.state) {
            case "done":
                transferTrack.update(1f, TransferTrackView.State.DONE, cyan, lime, coral, text);
                transferProgressPercent.setText("✓");
                transferProgressPercent.setTextColor(lime);
                break;
            case "failed":
                transferTrack.update((float) t.fraction, TransferTrackView.State.FAILED, cyan, lime, coral, text);
                transferProgressPercent.setTextColor(coral);
                break;
            default:
                transferTrack.update((float) t.fraction, TransferTrackView.State.SYNCING, cyan, lime, coral, text);
                transferProgressPercent.setTextColor(text);
        }
    }

    private void scheduleTransferRemoval(final String id, long delayMs) {
        ui.postDelayed(() -> {
            transfers.remove(id);
            renderTransferCard();
        }, delayMs);
    }

    // ---- SyncService.Ui(主线程回调)----

    @Override public void onLog(String line) { log(line); }

    @Override public void onPeerConnected(String name, String fp) {
        toast("已连接 " + name);
        refreshEngine();
    }

    @Override public void onPeerDisconnected(String fp, String reason) {
        refreshEngine();
    }

    @Override public void onPairingRequested(String name, String fp) {
        // 安全决策,不是普通 Toast(§9.3):名称 + 短指纹,SAS 码协议落地前不假装有(§12)
        if (pairingDialog != null) pairingDialog.dismiss();
        pairingDialog = new android.app.AlertDialog.Builder(this)
                .setTitle("配对请求")
                .setMessage("设备「" + name + "」请求配对\n\n指纹 " + fp.substring(0, Math.min(8, fp.length()))
                        + "\n\n请核对两台设备显示的指纹一致后再接受。")
                .setPositiveButton("接受", (d, w) -> { if (svc != null) svc.decidePairing(fp, true); })
                .setNegativeButton("拒绝", (d, w) -> { if (svc != null) svc.decidePairing(fp, false); })
                .setOnCancelListener(d -> { if (svc != null) svc.decidePairing(fp, false); })
                .show();
    }

    @Override public void onClipboardText(String text) {
        ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        cm.setPrimaryClip(ClipData.newPlainText("protosync", text));
        toast("收到文本,已进剪贴板");
    }

    @Override public void onClipboardImage(byte[] png) {
        if (Build.VERSION.SDK_INT >= 29) {
            android.net.Uri uri = null;
            try {
                android.content.ContentValues v = new android.content.ContentValues();
                v.put(MediaStore.Images.Media.DISPLAY_NAME, "protosync-clipboard.png");
                v.put(MediaStore.Images.Media.MIME_TYPE, "image/png");
                v.put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/ProtoSync");
                v.put(MediaStore.MediaColumns.IS_PENDING, 1);
                uri = getContentResolver().insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, v);
                if (uri != null) {
                    try (OutputStream os = getContentResolver().openOutputStream(uri)) {
                        os.write(png);
                    }
                    android.content.ContentValues pub = new android.content.ContentValues();
                    pub.put(MediaStore.MediaColumns.IS_PENDING, 0);
                    getContentResolver().update(uri, pub, null, null);
                    ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
                    cm.setPrimaryClip(ClipData.newUri(getContentResolver(), "protosync", uri));
                    toast("收到图片,已进剪贴板");
                    return;
                }
            } catch (Exception e) {
                if (uri != null) {
                    try { getContentResolver().delete(uri, null, null); } catch (Exception ignored) {}
                }
                log("图片进剪贴板失败: " + e.getMessage());
            }
        }
        // API 28 或 MediaStore 失败:落盘并告知路径
        try {
            File dir = new File(getExternalFilesDir(null), "ProtoSync");
            dir.mkdirs();
            File out = new File(dir, "clipboard-" + System.currentTimeMillis() + ".png");
            try (FileOutputStream fos = new FileOutputStream(out)) {
                fos.write(png);
            }
            toast("收到图片,已保存 " + out.getAbsolutePath());
        } catch (Exception e) {
            toast("收到图片,但保存失败");
        }
    }

    @Override public void onClipboardResult(boolean ok, String detail) {
        toast(detail);
        if (core != null) refreshEngine();
    }

    @Override public void onStateChanged() { refreshEngine(); }

    @Override public void onTransferStarted(String id, String name, boolean incoming) {
        TransferUi t = new TransferUi();
        t.name = name;
        t.fraction = 0;
        t.incoming = incoming;
        t.state = "syncing";
        transfers.put(id, t);
        renderTransferCard();
    }

    @Override public void onTransferProgress(String id, String name, double fraction, boolean incoming) {
        TransferUi t = transfers.get(id);
        if (t == null) return;
        t.fraction = fraction;
        renderTransferCard();
    }

    @Override public void onTransferFinished(String id, String name, boolean ok, String error,
                                             boolean incoming, String savedPath, String savedUri) {
        TransferUi t = transfers.get(id);
        if (t != null) {
            t.state = ok ? "done" : "failed";
            t.fraction = ok ? 1f : t.fraction;
            renderTransferCard();
            scheduleTransferRemoval(id, ok ? 2500 : 4000);
        }
        if (error != null && id.isEmpty()) toast("发送失败: " + error); // 未注册任务的前置失败
    }

    @Override public void onActivityChanged() {
        if (core != null) renderActivity(core);
    }

    // ---- 工具 ----

    private void log(String line) {
        android.util.Log.d("ProtoSyncUI", line);
        ui.post(() -> {
            String stamp = android.text.format.DateFormat.format("HH:mm:ss", new Date()).toString();
            logBuf.insert(0, "[" + stamp + "] " + line + "\n");
            if (logBuf.length() > 8000) logBuf.setLength(8000);
            logView.setText(logBuf.toString());
            if (core != null) refreshEngine();
        });
    }

    private void toast(String s) {
        ui.post(() -> Toast.makeText(this, s, Toast.LENGTH_SHORT).show());
    }

    private int color(int resId) {
        return getResources().getColor(resId, getTheme());
    }

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density);
    }
}
