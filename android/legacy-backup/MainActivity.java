package com.protosync.app;

import android.Manifest;
import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.os.IBinder;
import android.text.method.ScrollingMovementMethod;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.net.InetAddress;
import java.util.List;

public class MainActivity extends Activity implements ProtoEngine.Delegate {
    private String savedTargetFp;
    private SyncService svc;
    private ProtoEngine engine; // 可能为 null(服务引擎尚未就绪)
    private TextView statusText;
    private LinearLayout deviceList, discoveredList;
    private TextView logView;
    private EditText manualInput;
    private final StringBuilder logBuf = new StringBuilder();
    private android.app.AlertDialog pairingDialog;

    private final ServiceConnection conn = new ServiceConnection() {
        @Override public void onServiceConnected(android.content.ComponentName name, IBinder service) {
            svc = ((SyncService.LocalBinder) service).get();
            engine = svc.isReady() ? svc.getEngine() : null;
            svc.attach(MainActivity.this);
            if (engine != null) statusText.setText("ProtoSync 运行中 · 指纹 " + engine.fingerprint.substring(0, 8));
            rebuildLists();
        }
        @Override public void onServiceDisconnected(android.content.ComponentName name) {
            svc = null;
            engine = null;
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setTitle("ProtoSync");
        if (savedInstanceState != null) {
            savedTargetFp = savedInstanceState.getString(STATE_TARGET_FP);
        }

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = (int) (16 * getResources().getDisplayMetrics().density);
        root.setPadding(pad, pad, pad, pad);

        statusText = new TextView(this);
        statusText.setTextSize(16);
        root.addView(statusText);

        root.addView(sectionLabel("发现的设备(点按配对/连接)"));
        discoveredList = new LinearLayout(this);
        discoveredList.setOrientation(LinearLayout.VERTICAL);
        root.addView(discoveredList);

        root.addView(sectionLabel("已配对"));
        deviceList = new LinearLayout(this);
        deviceList.setOrientation(LinearLayout.VERTICAL);
        root.addView(deviceList);

        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        Button refresh = new Button(this);
        refresh.setText("刷新");
        refresh.setOnClickListener(v -> {
            if (engine == null) { toast("引擎启动中"); return; }
            engine.refreshDiscovery();
            log("↻ 手动刷新");
        });
        Button sendClip = new Button(this);
        sendClip.setText("发送剪贴板");
        sendClip.setOnClickListener(v -> sendClipboard());
        Button sendFile = new Button(this);
        sendFile.setText("发送文件");
        sendFile.setOnClickListener(v -> pickFileWithChooser());
        row.addView(refresh);
        row.addView(sendClip);
        row.addView(sendFile);
        root.addView(row);

        manualInput = new EditText(this);
        manualInput.setHint("手动连接 IP:端口(校园网 mDNS 被禁时用)");
        manualInput.setTextSize(12);
        root.addView(manualInput);
        Button connectBtn = new Button(this);
        connectBtn.setText("连接以上地址");
        connectBtn.setOnClickListener(v -> manualConnect());
        root.addView(connectBtn);

        logView = new TextView(this);
        logView.setTextSize(12);
        logView.setMovementMethod(new ScrollingMovementMethod());
        root.addView(logView, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        ScrollView sc = new ScrollView(this);
        sc.addView(root);
        setContentView(sc);

        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 1);
        }

        startForegroundService(new Intent(this, SyncService.class));
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

    private View sectionLabel(String s) {
        TextView tv = new TextView(this);
        tv.setText(s);
        tv.setPadding(0, (int) (12 * getResources().getDisplayMetrics().density), 0,
                (int) (4 * getResources().getDisplayMetrics().density));
        return tv;
    }

    // ---- 动作 ----

    private void sendClipboard() {
        if (engine == null) { toast("引擎启动中"); return; }
        ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        ClipData clip = cm.getPrimaryClip();
        if (clip == null || clip.getItemCount() == 0) { toast("剪贴板为空"); return; }
        CharSequence text = clip.getItemAt(0).coerceToText(this);
        if (text == null || text.length() == 0) { toast("剪贴板没有文本"); return; }
        String hash = engine.textHash(text.toString());
        if (engine.seenHas(hash)) { toast("该内容来自其他设备,不再回传"); return; }
        engine.broadcastText(text.toString());
        log("📤 已发送剪贴板 " + text.length() + " 字");
    }

    private static final int REQ_PICK_FILE = 42;
    private static final String STATE_TARGET_FP = "pendingFileTargetFp";
    private String pendingFileTargetFp;

    /** 多台在线时弹目标选择;单台直发。 */
    private void pickFileWithChooser() {
        if (engine == null) { toast("引擎启动中"); return; }
        final List<String[]> online = engine.onlinePeers();
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
        startActivityForResult(
                Intent.createChooser(intent, "选择要发送的文件"), REQ_PICK_FILE);
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        outState.putString(STATE_TARGET_FP, pendingFileTargetFp);
    }

    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQ_PICK_FILE && resultCode == RESULT_OK && data != null
                && data.getData() != null) {
            // Activity 重建后目标可能丢失:无法证明原目标就中止,绝不静默改发其他设备
            String target = pendingFileTargetFp;
            if (target == null) target = savedTargetFp;
            if (target == null) { toast("发送目标丢失,请重新选择"); return; }
            boolean stillOnline = false;
            ProtoEngine eng = engine;
            if (eng != null) {
                for (String[] o : eng.onlinePeers()) if (o[0].equals(target)) stillOnline = true;
            }
            if (!stillOnline) { toast("目标设备已离线,发送取消"); return; }
            final String finalTarget = target;
            new Thread(() -> {
                try {
                    String name = queryName(data.getData());
                    if (engine != null) engine.sendFile(finalTarget, name, data.getData());
                } catch (Exception e) {
                    log("读取文件失败: " + e.getMessage());
                }
            }).start();
        }
    }

    private String queryName(android.net.Uri uri) {
        android.database.Cursor c = getContentResolver().query(uri, null, null, null, null);
        if (c != null) {
            try {
                int idx = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME);
                if (idx >= 0 && c.moveToFirst()) return c.getString(idx);
            } finally { c.close(); }
        }
        return "file";
    }

    private void manualConnect() {
        if (engine == null) { toast("引擎启动中"); return; }
        String text = manualInput.getText().toString().trim();
        int colon = text.lastIndexOf(':');
        if (colon <= 0) { toast("格式:IP:端口"); return; }
        try {
            String host = text.substring(0, colon).trim();
            if (host.startsWith("[") && host.endsWith("]")) host = host.substring(1, host.length() - 1);
            InetAddress addr = InetAddress.getByName(host);
            int port = Integer.parseInt(text.substring(colon + 1).trim());
            engine.connectTo(addr, port);
            log("→ 连接 " + text);
        } catch (Exception e) {
            toast("地址无效: " + e.getMessage());
        }
    }

    // ---- UI 刷新 ----

    private void rebuildLists() {
        runOnUiThread(() -> {
            // Binding can complete before SyncService's background engine init.
            // Re-read it on the service's ready/discovery callback instead of
            // permanently retaining the null observed during onServiceConnected.
            if (engine == null && svc != null) engine = svc.getEngine();
            ProtoEngine e = engine;
            if (e == null) {
                statusText.setText("ProtoSync 引擎启动中…");
                return;
            }
            statusText.setText("ProtoSync 运行中 · 指纹 " + e.fingerprint.substring(0, 8));
            discoveredList.removeAllViews();
            for (String[] d : e.discoveredUnpaired()) {
                discoveredList.addView(rowView("设备 " + d[0] + "  (" + d[1] + ":" + d[2] + ")", "配对", v -> {
                    try {
                        e.connectTo(InetAddress.getByName(d[1]), Integer.parseInt(d[2]));
                    } catch (Exception ex) {
                        toast("连接失败: " + ex.getMessage());
                    }
                }));
            }
            if (e.discoveredUnpaired().isEmpty()) {
                TextView empty = new TextView(this);
                empty.setText("  (暂无,点“刷新”;或用下方手动连接)");
                empty.setTextSize(12);
                discoveredList.addView(empty);
            }

            deviceList.removeAllViews();
            List<String[]> online = e.onlinePeers();
            for (String[] p : e.pairedList()) {
                boolean isOnline = false;
                for (String[] o : online) if (o[0].equals(p[0])) isOnline = true;
                LinearLayout row = new LinearLayout(this);
                row.setOrientation(LinearLayout.HORIZONTAL);
                row.setPadding(0, 4, 0, 4);
                TextView tv = new TextView(this);
                tv.setText((isOnline ? "● " : "○ ") + p[1] + "  (" + p[0].substring(0, 8) + ")");
                tv.setTextSize(14);
                row.addView(tv, new LinearLayout.LayoutParams(
                        0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
                if (isOnline) {
                    Button send = new Button(this);
                    send.setText("发文件");
                    send.setTextSize(12);
                    send.setOnClickListener(v -> pickFile(p[0]));
                    row.addView(send);
                }
                Button unpair = new Button(this);
                unpair.setText("取消配对");
                unpair.setTextSize(12);
                unpair.setOnClickListener(v -> {
                    e.removePaired(p[0]);
                    log("已取消配对 " + p[1]);
                    rebuildLists();
                });
                row.addView(unpair);
                deviceList.addView(row);
            }
        });
    }

    private View rowView(String title, String action, View.OnClickListener onClick) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setPadding(0, 4, 0, 4);
        TextView tv = new TextView(this);
        tv.setText(title);
        tv.setTextSize(14);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        row.addView(tv, lp);
        if (action != null) {
            Button b = new Button(this);
            b.setText(action);
            b.setTextSize(12);
            b.setOnClickListener(onClick);
            row.addView(b);
        }
        return row;
    }

    private void toast(String s) {
        runOnUiThread(() -> Toast.makeText(this, s, Toast.LENGTH_SHORT).show());
    }

    // ---- ProtoEngine.Delegate(引擎线程回调,统一跳主线程) ----

    @Override public void postLog(String line) { log(line); }

    @Override public void onPeerConnected(String name, String fp) {
        rebuildLists();
        log("✅ 已连接 " + name);
        toast("已连接 " + name);
    }

    @Override public void onPeerDisconnected(String fp, String error) {
        rebuildLists();
        log("🔌 断开 " + fp.substring(0, 8) + (error != null ? " (" + error + ")" : ""));
    }

    @Override public void onPairingRequested(String name, String fp, ProtoEngine.DecisionCallback cb) {
        runOnUiThread(() -> {
            if (pairingDialog != null) pairingDialog.dismiss();
            pairingDialog = new android.app.AlertDialog.Builder(this)
                    .setTitle("配对请求")
                    .setMessage("设备「" + name + "」请求配对\n\n指纹 " + fp.substring(0, 8)
                            + "\n\n确认是同一主人后接受。")
                    .setPositiveButton("接受", (d, w) -> cb.decide(true))
                    .setNegativeButton("拒绝", (d, w) -> cb.decide(false))
                    .setOnCancelListener(d -> cb.decide(false))
                    .show();
        });
    }

    @Override public void onClipboardText(String text) {
        runOnUiThread(() -> {
            ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
            cm.setPrimaryClip(ClipData.newPlainText("protosync", text));
            log("📋 已复制到剪贴板");
            toast("收到文本,已进剪贴板");
        });
    }

    @Override public void onDiscoveredChanged() { rebuildLists(); }

    @Override public void onFileEvent(String line) { log(line); }

    private void log(String line) {
        android.util.Log.d("ProtoSyncUI", line);
        runOnUiThread(() -> {
            String stamp = android.text.format.DateFormat.format("HH:mm:ss", new java.util.Date()).toString();
            logBuf.insert(0, "[" + stamp + "] " + line + "\n");
            if (logBuf.length() > 8000) logBuf.setLength(8000);
            logView.setText(logBuf.toString());
            rebuildLists();
        });
    }
}
