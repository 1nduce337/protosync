package com.protosync.app;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipDescription;
import android.content.ClipboardManager;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.content.res.ColorStateList;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.provider.MediaStore;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.MenuItem;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.PopupMenu;
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
import java.util.WeakHashMap;

import static com.protosync.app.PanelUi.ACCENT;
import static com.protosync.app.PanelUi.CORAL;
import static com.protosync.app.PanelUi.FILL;
import static com.protosync.app.PanelUi.FILL_STRONG;
import static com.protosync.app.PanelUi.TEXT;
import static com.protosync.app.PanelUi.TEXT_SECONDARY;

/**
 * 单屏面板(设计方向 B 的 Android 版,见 docs/design/MENUBAR_PANEL.md):
 * 设备头像 → 待决请求(配对 / 文件)→ 传输 → 剪贴板历史 → 收到的文件;底部固定“发送剪贴板”。
 * 所有引擎调用都是 SyncCore 的投递式 API,UI 线程不做任何网络 I/O。
 */
public class MainActivity extends Activity implements SyncService.Ui {
    private SyncService svc;
    private SyncCore core; // 可能为 null(服务引擎尚未就绪)

    private TextView statusText;
    private LinearLayout devicesBox, nearbyBox, requestsBox, transfersBox, historyBox, filesBox;
    private Button sendClipboardButton;
    private View sendFileButton;
    private SettingsDialog settings;
    final StringBuilder logBuf = new StringBuilder();
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final WeakHashMap<SyncCore.ClipItem, Bitmap> thumbs = new WeakHashMap<>();
    private final WeakHashMap<SyncCore.ClipItem, int[]> originalSizes = new WeakHashMap<>();
    private boolean showNearby = false;

    /** 当前展示的配对请求 {name, fp};由服务逐个派发,决定后服务派发下一个 */
    private String[] activePair;

    /** 当前展示的文件请求 */
    private static class OfferUi {
        String id, name, fromName; long size;
    }
    private OfferUi activeOffer;

    /** 活动传输:id → 展示状态(完成/失败态短暂停留后自动清出)。 */
    private static class TransferUi {
        String name; double fraction; boolean incoming;
        String state; // syncing | waiting | done | failed
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
        // 面板固定深色(与 macOS / iOS 一致)
        setTheme(android.R.style.Theme_DeviceDefault_NoActionBar);
        super.onCreate(savedInstanceState);
        getWindow().setStatusBarColor(PanelUi.CANVAS);
        getWindow().setNavigationBarColor(PanelUi.CANVAS);
        if (savedInstanceState != null) {
            savedTargetFp = savedInstanceState.getString(STATE_TARGET_FP);
        }

        setContentView(R.layout.activity_main);
        statusText = findViewById(R.id.statusText);
        LinearLayout content = findViewById(R.id.content);
        devicesBox = section(content, 0);
        nearbyBox = section(content, 18);
        requestsBox = section(content, 18);
        transfersBox = section(content, 18);
        historyBox = section(content, 26);
        filesBox = section(content, 26);

        sendClipboardButton = findViewById(R.id.sendClipboardButton);
        sendClipboardButton.setBackground(PanelUi.pressable(this, ACCENT, 12));
        sendClipboardButton.setOnClickListener(v -> sendClipboard());
        sendFileButton = findViewById(R.id.sendFileButton);
        sendFileButton.setBackground(PanelUi.pressable(this, FILL_STRONG, 12));
        sendFileButton.setOnClickListener(v -> pickFileWithChooser());
        findViewById(R.id.settingsButton).setOnClickListener(v -> openSettings());

        if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{android.Manifest.permission.POST_NOTIFICATIONS}, 1);
        }

        startForegroundService(new Intent(this, SyncService.class));
        renderAll();
    }

    private LinearLayout section(LinearLayout parent, float topMarginDp) {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        parent.addView(box, PanelUi.matchWrap(this, topMarginDp));
        return box;
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
    protected void onDestroy() {
        if (settings != null && settings.isShowing()) settings.dismiss();
        super.onDestroy();
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        outState.putString(STATE_TARGET_FP, pendingFileTargetFp);
    }

    SyncCore core() { return core; }

    // ================= 主操作 =================

    /** 手动发送剪贴板:文本优先,其次图片。发送结果由 onClipboardResult 回调提示。 */
    private void sendClipboard() {
        if (core == null) { toast("引擎启动中"); return; }
        ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        ClipData clip = cm.getPrimaryClip();
        if (clip == null || clip.getItemCount() == 0) { toast("剪贴板是空的"); return; }
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
            Bitmap bmp = BitmapFactory.decodeStream(in);
            if (bmp == null) { toast("无法解码剪贴板图片"); return; }
            java.io.ByteArrayOutputStream bos = new java.io.ByteArrayOutputStream();
            bmp.compress(Bitmap.CompressFormat.PNG, 100, bos);
            bmp.recycle();
            core.sendClipboardImage(bos.toByteArray());
        } catch (Exception e) {
            toast("读取剪贴板图片失败：" + e.getMessage());
        }
    }

    private void pickFileWithChooser() {
        if (core == null) { toast("引擎启动中"); return; }
        List<String[]> online = core.onlinePeersSnapshot();
        if (online.isEmpty()) { toast("没有在线设备"); return; }
        if (online.size() == 1) { pickFile(online.get(0)[0]); return; }
        String[] names = new String[online.size()];
        for (int i = 0; i < online.size(); i++) names[i] = online.get(i)[1];
        new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
                .setTitle("发送给哪台设备？")
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
            if (target == null) { toast("发送目标丢失，请重新选择"); return; }
            boolean stillOnline = false;
            if (core != null) {
                for (String[] o : core.onlinePeersSnapshot()) if (o[0].equals(target)) stillOnline = true;
            }
            if (!stillOnline) { toast("目标设备已离线，发送取消"); return; }
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

    private void openSettings() {
        if (core == null) { toast("引擎启动中"); return; }
        if (settings == null) settings = new SettingsDialog(this);
        settings.refresh();
        settings.show();
    }

    void confirmRemove(String fp, String name) {
        new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
                .setTitle("移除「" + name + "」？")
                .setMessage("移除后需要重新配对才能互传剪贴板和文件。")
                .setPositiveButton("移除", (d, w) -> {
                    if (core != null) core.removePaired(fp);
                    log("已移除 " + name);
                })
                .setNegativeButton("取消", null)
                .show();
    }

    // ================= 渲染 =================

    private void renderAll() {
        if (core == null && svc != null) core = svc.isReady() ? svc.core() : null;
        boolean ready = core != null && core.fingerprint().length() >= 8;
        if (!ready) {
            statusText.setText("引擎启动中…");
        } else {
            int online = core.onlinePeersSnapshot().size();
            statusText.setText(online == 0 ? "没有设备在线" : online + " 台设备在线");
        }
        sendClipboardButton.setEnabled(ready);
        sendClipboardButton.setAlpha(ready ? 1f : 0.5f);
        boolean canSendFile = ready && !core.onlinePeersSnapshot().isEmpty();
        sendFileButton.setEnabled(canSendFile);
        sendFileButton.setAlpha(canSendFile ? 1f : 0.4f);

        renderDevices(ready);
        renderNearby(ready);
        renderRequests();
        renderTransfers();
        renderHistory(ready);
        renderFiles(ready);
        if (settings != null && settings.isShowing()) settings.refresh();
    }

    // ---- 设备头像 ----

    private void renderDevices(boolean ready) {
        devicesBox.removeAllViews();
        LinearLayout row = null;
        int column = 0;
        java.util.ArrayList<View> cells = new java.util.ArrayList<>();
        if (ready) {
            List<String[]> online = core.onlinePeersSnapshot();
            java.util.ArrayList<View> offlineCells = new java.util.ArrayList<>();
            for (String[] p : core.pairedSnapshot()) {
                boolean isOnline = false;
                for (String[] o : online) if (o[0].equals(p[0])) isOnline = true;
                // 在线优先,各自保持原有顺序
                (isOnline ? cells : offlineCells).add(deviceCell(p[0], p[1], isOnline));
            }
            cells.addAll(offlineCells);
        }
        cells.add(pairCell(ready));
        for (View cell : cells) {
            if (column == 0) {
                row = new LinearLayout(this);
                row.setOrientation(LinearLayout.HORIZONTAL);
                devicesBox.addView(row, PanelUi.matchWrap(this, devicesBox.getChildCount() == 0 ? 0 : 18));
            }
            row.addView(cell, PanelUi.weight1());
            column = (column + 1) % 3;
        }
        // 补齐最后一行,保持三列等宽
        while (column != 0 && row != null) {
            row.addView(new View(this), PanelUi.weight1());
            column = (column + 1) % 3;
        }
        if (ready && core.pairedSnapshot().isEmpty()) {
            devicesBox.addView(PanelUi.text(this, "还没有配对的设备。点 + 查找附近的设备。", 13, TEXT_SECONDARY),
                    PanelUi.matchWrap(this, 12));
        }
    }

    private View deviceCell(String fp, String name, boolean online) {
        LinearLayout cell = new LinearLayout(this);
        cell.setOrientation(LinearLayout.VERTICAL);
        cell.setGravity(Gravity.CENTER_HORIZONTAL);
        cell.setPadding(0, PanelUi.dp(this, 4), 0, PanelUi.dp(this, 4));
        cell.setBackground(PanelUi.pressable(this, 0, 16));

        cell.addView(PanelUi.avatar(this, name, online, 76));
        TextView title = PanelUi.singleLine(PanelUi.text(this, name, 13, online ? TEXT : TEXT_SECONDARY),
                TextUtils.TruncateAt.END);
        title.setGravity(Gravity.CENTER);
        cell.addView(title, PanelUi.matchWrap(this, 8));
        boolean trusted = core != null && core.isFileTrusted(fp);
        TextView status = PanelUi.singleLine(PanelUi.text(this,
                online ? (trusted ? "在线" : "在线 · 文件需确认") : "离线", 11, TEXT_SECONDARY),
                TextUtils.TruncateAt.END);
        status.setGravity(Gravity.CENTER);
        cell.addView(status, PanelUi.matchWrap(this, 2));

        cell.setContentDescription(name + "，" + (online ? "在线，点按发送文件，长按更多操作" : "离线，长按更多操作"));
        cell.setOnClickListener(v -> {
            if (online) pickFile(fp);
            else toast(name + " 当前离线");
        });
        cell.setOnLongClickListener(v -> {
            showDeviceMenu(v, fp, name, online);
            return true;
        });
        return cell;
    }

    private void showDeviceMenu(View anchor, String fp, String name, boolean online) {
        if (core == null) return;
        PopupMenu menu = new PopupMenu(this, anchor);
        if (online) menu.getMenu().add(0, 1, 0, "发送文件…");
        MenuItem trust = menu.getMenu().add(0, 2, 1, "自动接收文件");
        trust.setCheckable(true);
        trust.setChecked(core.isFileTrusted(fp));
        menu.getMenu().add(0, 3, 2, "移除此设备…");
        menu.setOnMenuItemClickListener(item -> {
            switch (item.getItemId()) {
                case 1: pickFile(fp); break;
                case 2:
                    boolean next = !core.isFileTrusted(fp);
                    core.setFileTrust(fp, next);
                    log(next ? "已开启自动接收：" + name : name + " 的文件将先询问");
                    break;
                case 3: confirmRemove(fp, name); break;
            }
            return true;
        });
        menu.show();
    }

    private View pairCell(boolean ready) {
        LinearLayout cell = new LinearLayout(this);
        cell.setOrientation(LinearLayout.VERTICAL);
        cell.setGravity(Gravity.CENTER_HORIZONTAL);
        cell.setPadding(0, PanelUi.dp(this, 4), 0, PanelUi.dp(this, 4));
        cell.setBackground(PanelUi.pressable(this, 0, 16));

        FrameLayout ring = new FrameLayout(this);
        ring.setBackground(PanelUi.dashedCircle(this, showNearby ? ACCENT : TEXT_SECONDARY));
        ImageView plus = new ImageView(this);
        plus.setImageResource(showNearby ? R.drawable.ic_close : R.drawable.ic_plus);
        plus.setImageTintList(ColorStateList.valueOf(TEXT_SECONDARY));
        int iconSize = PanelUi.dp(this, 26);
        ring.addView(plus, new FrameLayout.LayoutParams(iconSize, iconSize, Gravity.CENTER));
        cell.addView(ring, new LinearLayout.LayoutParams(PanelUi.dp(this, 76), PanelUi.dp(this, 76)));
        TextView label = PanelUi.text(this, "配对", 13, TEXT_SECONDARY);
        label.setGravity(Gravity.CENTER);
        cell.addView(label, PanelUi.matchWrap(this, 8));

        cell.setContentDescription(showNearby ? "收起附近的设备" : "配对新设备");
        cell.setEnabled(ready);
        cell.setOnClickListener(v -> {
            showNearby = !showNearby;
            if (showNearby && core != null) core.refreshDiscovery();
            renderAll();
        });
        return cell;
    }

    // ---- 附近的设备 ----

    private void renderNearby(boolean ready) {
        nearbyBox.removeAllViews();
        if (!showNearby || !ready) {
            nearbyBox.setVisibility(View.GONE);
            return;
        }
        nearbyBox.setVisibility(View.VISIBLE);
        nearbyBox.addView(PanelUi.sectionTitle(this, "附近的设备"));
        List<String[]> nearby = core.nearbySnapshot();
        if (nearby.isEmpty()) {
            nearbyBox.addView(PanelUi.text(this, "没有发现新设备。确认对方已打开 ProtoSync 且在同一网络。", 13, TEXT_SECONDARY));
        }
        for (String[] d : nearby) {
            String serviceName = d[0];
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setBackground(PanelUi.rounded(this, FILL, 14));
            row.setPadding(PanelUi.dp(this, 14), PanelUi.dp(this, 8), PanelUi.dp(this, 8), PanelUi.dp(this, 8));
            TextView name = PanelUi.text(this, "设备 " + serviceName.substring(0, Math.min(8, serviceName.length())), 15, TEXT);
            name.setFontFeatureSettings("tnum");
            row.addView(name, PanelUi.weight1());
            Button pair = PanelUi.primaryButton(this, "配对", 36, 14);
            pair.setOnClickListener(v -> {
                if (core != null) core.pairWithNearby(serviceName);
                log("→ 正在连接 " + serviceName);
            });
            row.addView(pair, new LinearLayout.LayoutParams(PanelUi.dp(this, 76), PanelUi.dp(this, 36)));
            nearbyBox.addView(row, PanelUi.matchWrap(this, nearbyBox.getChildCount() <= 1 ? 0 : 6));
        }
    }

    // ---- 配对请求 / 文件请求(安全决策:卡片常驻,直到决定或失效)----

    private void renderRequests() {
        requestsBox.removeAllViews();
        if (activePair == null && activeOffer == null) {
            requestsBox.setVisibility(View.GONE);
            return;
        }
        requestsBox.setVisibility(View.VISIBLE);
        if (activePair != null) requestsBox.addView(pairingCard(activePair[0], activePair[1]));
        if (activeOffer != null) {
            requestsBox.addView(offerCard(activeOffer), PanelUi.matchWrap(this, activePair != null ? 12 : 0));
        }
    }

    private LinearLayout card() {
        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setBackground(PanelUi.rounded(this, FILL, 16));
        int pad = PanelUi.dp(this, 16);
        card.setPadding(pad, pad, pad, pad);
        return card;
    }

    private View pairingCard(String name, String fp) {
        LinearLayout card = card();
        card.addView(PanelUi.bold(this, "「" + name + "」请求配对", 15, TEXT));
        TextView code = PanelUi.text(this, PanelUi.shortFp(fp), 28, TEXT);
        code.setFontFeatureSettings("tnum");
        card.addView(code, PanelUi.matchWrap(this, 10));
        card.addView(PanelUi.text(this, "确认对方屏幕上显示同一指纹后再接受。", 13, TEXT_SECONDARY),
                PanelUi.matchWrap(this, 6));
        card.addView(buttonPair("接受", v -> decidePair(fp, true), "拒绝", v -> decidePair(fp, false)),
                PanelUi.matchWrap(this, 14));
        return card;
    }

    private View offerCard(OfferUi offer) {
        LinearLayout card = card();
        TextView title = PanelUi.text(this, "「" + offer.fromName + "」想发送「" + offer.name + "」", 15, TEXT);
        title.setMaxLines(2);
        title.setEllipsize(TextUtils.TruncateAt.MIDDLE);
        card.addView(title);
        card.addView(PanelUi.text(this, android.text.format.Formatter.formatShortFileSize(this, offer.size),
                13, TEXT_SECONDARY), PanelUi.matchWrap(this, 4));
        card.addView(buttonPair("接收", v -> decideOffer(offer.id, true, false),
                "拒绝", v -> decideOffer(offer.id, false, false)), PanelUi.matchWrap(this, 14));
        card.addView(PanelUi.linkButton(this, "接收，并始终信任此设备的文件", ACCENT,
                v -> decideOffer(offer.id, true, true)), PanelUi.matchWrap(this, 4));
        return card;
    }

    private View buttonPair(String primary, View.OnClickListener onPrimary,
                            String secondary, View.OnClickListener onSecondary) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        Button a = PanelUi.primaryButton(this, primary, 44, 15);
        a.setOnClickListener(onPrimary);
        Button b = PanelUi.secondaryButton(this, secondary, 44, 15);
        b.setOnClickListener(onSecondary);
        row.addView(a, new LinearLayout.LayoutParams(0, PanelUi.dp(this, 44), 1f));
        LinearLayout.LayoutParams bLp = new LinearLayout.LayoutParams(0, PanelUi.dp(this, 44), 1f);
        bLp.leftMargin = PanelUi.dp(this, 10);
        row.addView(b, bLp);
        return row;
    }

    private void decidePair(String fp, boolean accept) {
        activePair = null;
        renderRequests();
        if (svc != null) svc.decidePairing(fp, accept);
    }

    private void decideOffer(String id, boolean accept, boolean alwaysTrust) {
        if (activeOffer != null && activeOffer.id.equals(id)) activeOffer = null;
        renderRequests();
        if (svc != null) svc.decideFileOffer(id, accept, alwaysTrust);
        if (!accept) log("已拒绝文件请求");
    }

    // ---- 传输 ----

    private void renderTransfers() {
        transfersBox.removeAllViews();
        transfersBox.setVisibility(transfers.isEmpty() ? View.GONE : View.VISIBLE);
        for (TransferUi t : transfers.values()) {
            LinearLayout line = new LinearLayout(this);
            line.setOrientation(LinearLayout.HORIZONTAL);
            line.setGravity(Gravity.CENTER_VERTICAL);
            TextView arrow = PanelUi.bold(this, t.incoming ? "↓" : "↑", 13, TEXT_SECONDARY);
            line.addView(arrow);
            TextView name = PanelUi.singleLine(PanelUi.text(this, t.name, 14, TEXT), TextUtils.TruncateAt.MIDDLE);
            LinearLayout.LayoutParams nameLp = PanelUi.weight1();
            nameLp.leftMargin = PanelUi.dp(this, 6);
            line.addView(name, nameLp);
            String right;
            int rightColor = TEXT_SECONDARY;
            switch (t.state) {
                case "done": right = "已完成"; rightColor = ACCENT; break;
                case "failed": right = "失败"; rightColor = CORAL; break;
                case "waiting": right = "等待对方确认"; break;
                default: right = Math.round(t.fraction * 100) + "%";
            }
            TextView pct = PanelUi.text(this, right, 13, rightColor);
            pct.setFontFeatureSettings("tnum");
            line.addView(pct);
            transfersBox.addView(line, PanelUi.matchWrap(this, transfersBox.getChildCount() == 0 ? 0 : 12));
            transfersBox.addView(PanelUi.progressBar(this, t.fraction, "failed".equals(t.state)));
            ((LinearLayout.LayoutParams) transfersBox.getChildAt(transfersBox.getChildCount() - 1)
                    .getLayoutParams()).topMargin = PanelUi.dp(this, 6);
        }
    }

    // ---- 剪贴板历史 ----

    private void renderHistory(boolean ready) {
        historyBox.removeAllViews();
        List<SyncCore.ClipItem> items = ready ? core.clipHistorySnapshot() : java.util.Collections.emptyList();
        LinearLayout header = new LinearLayout(this);
        header.setOrientation(LinearLayout.HORIZONTAL);
        header.addView(PanelUi.sectionTitle(this, "剪贴板历史"), PanelUi.weight1());
        if (!items.isEmpty()) header.addView(PanelUi.text(this, "点按即复制", 12, TEXT_SECONDARY));
        historyBox.addView(header);
        if (items.isEmpty()) {
            historyBox.addView(PanelUi.text(this, "收到或发出的剪贴板会出现在这里。", 13, TEXT_SECONDARY));
            return;
        }
        SimpleDateFormat fmt = new SimpleDateFormat("HH:mm", Locale.US);
        for (SyncCore.ClipItem item : items) {
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setBackground(PanelUi.pressable(this, FILL, 14));
            row.setPadding(PanelUi.dp(this, 14), PanelUi.dp(this, 11), PanelUi.dp(this, 14), PanelUi.dp(this, 11));
            if (item.png != null) {
                Bitmap thumb = thumbnail(item);
                if (thumb != null) {
                    ImageView iv = new ImageView(this);
                    iv.setImageBitmap(thumb);
                    iv.setScaleType(ImageView.ScaleType.CENTER_CROP);
                    iv.setClipToOutline(true);
                    iv.setBackground(PanelUi.rounded(this, FILL, 6));
                    LinearLayout.LayoutParams ivLp = new LinearLayout.LayoutParams(PanelUi.dp(this, 36), PanelUi.dp(this, 36));
                    ivLp.rightMargin = PanelUi.dp(this, 12);
                    row.addView(iv, ivLp);
                }
            }
            LinearLayout texts = new LinearLayout(this);
            texts.setOrientation(LinearLayout.VERTICAL);
            String preview = preview(item);
            texts.addView(PanelUi.singleLine(PanelUi.text(this, preview, 15, TEXT), TextUtils.TruncateAt.END));
            texts.addView(PanelUi.text(this, item.source + " · " + fmt.format(new Date(item.time)), 12, TEXT_SECONDARY),
                    PanelUi.matchWrap(this, 3));
            row.addView(texts, PanelUi.weight1());
            row.setContentDescription("复制：" + preview);
            row.setOnClickListener(v -> {
                if (item.text != null) writeTextToClipboard(item.text, "已复制");
                else if (item.png != null) writeImageToClipboard(item.png, "已复制");
            });
            historyBox.addView(row, PanelUi.matchWrap(this, 6));
        }
    }

    private String preview(SyncCore.ClipItem item) {
        if (item.text != null) return item.text.replace('\n', ' ');
        thumbnail(item);
        int[] size = originalSizes.get(item);
        return size == null ? "图片" : "图片 · " + size[0] + "×" + size[1];
    }

    /** 解码一次后缓存;缩略图按需降采样,避免大图占内存。原图宽高另存,供预览文字使用 */
    private Bitmap thumbnail(SyncCore.ClipItem item) {
        if (thumbs.containsKey(item)) return thumbs.get(item);
        Bitmap b = null;
        try {
            BitmapFactory.Options bounds = new BitmapFactory.Options();
            bounds.inJustDecodeBounds = true;
            BitmapFactory.decodeByteArray(item.png, 0, item.png.length, bounds);
            BitmapFactory.Options opts = new BitmapFactory.Options();
            opts.inSampleSize = Math.max(1, Math.min(bounds.outWidth, bounds.outHeight) / 128);
            b = BitmapFactory.decodeByteArray(item.png, 0, item.png.length, opts);
            if (b != null) originalSizes.put(item, new int[]{bounds.outWidth, bounds.outHeight});
        } catch (Exception ignored) {}
        thumbs.put(item, b);
        return b;
    }

    // ---- 收到的文件 ----

    private void renderFiles(boolean ready) {
        filesBox.removeAllViews();
        filesBox.addView(PanelUi.sectionTitle(this, "收到的文件"));
        List<SyncCore.ReceivedFile> files = ready ? core.recentFilesSnapshot() : java.util.Collections.emptyList();
        if (files.isEmpty()) {
            filesBox.addView(PanelUi.text(this, "收到的文件保存在“下载/ProtoSync”。", 13, TEXT_SECONDARY));
            return;
        }
        for (SyncCore.ReceivedFile f : files) {
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setMinimumHeight(PanelUi.dp(this, 48));
            row.setBackground(PanelUi.pressable(this, FILL, 14));
            row.setPadding(PanelUi.dp(this, 14), 0, PanelUi.dp(this, 14), 0);
            ImageView icon = new ImageView(this);
            icon.setImageResource(R.drawable.ic_file);
            icon.setImageTintList(ColorStateList.valueOf(TEXT_SECONDARY));
            row.addView(icon, new LinearLayout.LayoutParams(PanelUi.dp(this, 18), PanelUi.dp(this, 18)));
            TextView name = PanelUi.singleLine(PanelUi.text(this, f.name, 15, TEXT), TextUtils.TruncateAt.MIDDLE);
            LinearLayout.LayoutParams nameLp = PanelUi.weight1();
            nameLp.leftMargin = PanelUi.dp(this, 10);
            row.addView(name, nameLp);
            row.setContentDescription("打开 " + f.name);
            row.setOnClickListener(v -> openReceived(f));
            filesBox.addView(row, PanelUi.matchWrap(this, 6));
        }
    }

    private void openReceived(SyncCore.ReceivedFile f) {
        if (f.uri == null) { toast("已保存到 " + f.path); return; }
        try {
            Intent view = new Intent(Intent.ACTION_VIEW);
            android.net.Uri uri = android.net.Uri.parse(f.uri);
            view.setDataAndType(uri, getContentResolver().getType(uri));
            view.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            startActivity(Intent.createChooser(view, f.name));
        } catch (Exception e) {
            toast("无法打开：" + e.getMessage());
        }
    }

    // ================= 剪贴板写入 =================

    private void writeTextToClipboard(String text, String toastText) {
        ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        cm.setPrimaryClip(ClipData.newPlainText("protosync", text));
        toast(toastText);
    }

    /** 图片进剪贴板需要 content URI:API 29+ 写入 MediaStore 图片目录,否则落盘并告知路径 */
    private void writeImageToClipboard(byte[] png, String toastText) {
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
                    toast(toastText);
                    return;
                }
            } catch (Exception e) {
                if (uri != null) {
                    try { getContentResolver().delete(uri, null, null); } catch (Exception ignored) {}
                }
                log("图片进剪贴板失败：" + e.getMessage());
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
            toast("图片已保存 " + out.getAbsolutePath());
        } catch (Exception e) {
            toast("图片保存失败");
        }
    }

    // ================= SyncService.Ui(主线程回调)=================

    @Override public void onLog(String line) { log(line); }

    @Override public void onPeerConnected(String name, String fp) {
        // 配对可能由对端接受驱动完成:卡片随之收起
        if (activePair != null && activePair[1].equals(fp)) activePair = null;
        toast("已连接 " + name);
        renderAll();
    }

    @Override public void onPeerDisconnected(String fp, String reason) {
        renderAll();
    }

    @Override public void onPairingRequested(String name, String fp) {
        activePair = new String[]{name, fp};
        renderRequests();
    }

    @Override public void onFileOfferRequested(String id, String name, long size, String fromName, String fromFp) {
        OfferUi o = new OfferUi();
        o.id = id;
        o.name = name;
        o.size = size;
        o.fromName = fromName;
        activeOffer = o;
        renderRequests();
    }

    @Override public void onFileOfferExpired(String id) {
        if (activeOffer != null && activeOffer.id.equals(id)) {
            activeOffer = null;
            renderRequests();
            toast("文件请求已超时");
        }
    }

    @Override public void onClipboardText(String text) {
        writeTextToClipboard(text, "收到文本，已进剪贴板");
    }

    @Override public void onClipboardImage(byte[] png) {
        writeImageToClipboard(png, "收到图片，已进剪贴板");
    }

    @Override public void onClipboardResult(boolean ok, String detail) {
        toast(detail);
        renderAll();
    }

    @Override public void onStateChanged() { renderAll(); }

    @Override public void onTransferStarted(String id, String name, boolean incoming) {
        TransferUi t = new TransferUi();
        t.name = name;
        t.fraction = 0;
        t.incoming = incoming;
        t.state = "syncing";
        transfers.put(id, t);
        renderTransfers();
    }

    @Override public void onTransferProgress(String id, String name, double fraction, boolean incoming) {
        TransferUi t = transfers.get(id);
        if (t == null) return;
        t.fraction = fraction;
        if ("waiting".equals(t.state) && fraction > 0) t.state = "syncing";
        renderTransfers();
    }

    @Override public void onTransferFinished(String id, String name, boolean ok, String error,
                                             boolean incoming, String savedPath, String savedUri) {
        TransferUi t = transfers.get(id);
        if (t != null) {
            t.state = ok ? "done" : "failed";
            t.fraction = ok ? 1f : t.fraction;
            renderTransfers();
            scheduleTransferRemoval(id, ok ? 2500 : 4000);
        }
        if (error != null && id.isEmpty()) toast("发送失败：" + error); // 未注册任务的前置失败
        if (ok && incoming) renderFiles(core != null);
    }

    private void scheduleTransferRemoval(final String id, long delayMs) {
        ui.postDelayed(() -> {
            transfers.remove(id);
            renderTransfers();
        }, delayMs);
    }

    @Override public void onActivityChanged() {
        // 活动日志变化意味着剪贴板历史 / 传输状态可能变了;等待确认的发送在这里体现
        if (core != null) {
            for (SyncCore.ActivityItem item : core.activitySnapshot()) {
                if ("file".equals(item.kind) && !item.incoming && "等待对方确认…".equals(item.detail)) {
                    for (Map.Entry<String, TransferUi> e : transfers.entrySet()) {
                        TransferUi t = e.getValue();
                        if (!t.incoming && t.name.equals(item.title) && "syncing".equals(t.state) && t.fraction == 0) {
                            t.state = "waiting";
                        }
                    }
                }
                break; // 只看最新一条
            }
        }
        renderTransfers();
        renderHistory(core != null && core.fingerprint().length() >= 8);
    }

    // ================= 工具 =================

    void log(String line) {
        android.util.Log.d("ProtoSyncUI", line);
        ui.post(() -> {
            String stamp = android.text.format.DateFormat.format("HH:mm:ss", new Date()).toString();
            logBuf.insert(0, "[" + stamp + "] " + line + "\n");
            if (logBuf.length() > 8000) logBuf.setLength(8000);
            if (settings != null && settings.isShowing()) settings.refreshLog();
        });
    }

    void toast(String s) {
        ui.post(() -> Toast.makeText(this, s, Toast.LENGTH_SHORT).show());
    }
}
