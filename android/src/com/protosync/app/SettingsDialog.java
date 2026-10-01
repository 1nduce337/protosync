package com.protosync.app;

import android.app.Dialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Typeface;
import android.text.InputType;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;

import com.protosync.core.SyncCore;

import java.util.List;

import static com.protosync.app.PanelUi.ACCENT;
import static com.protosync.app.PanelUi.DIVIDER;
import static com.protosync.app.PanelUi.FILL;
import static com.protosync.app.PanelUi.TEXT;
import static com.protosync.app.PanelUi.TEXT_SECONDARY;

/**
 * 设置页(全屏,与 macOS“设备与设置”同一视觉语言):本机、已配对设备(自动接收开关 / 移除)、
 * 手动连接、日志。填充分组、无描边;Lime 只用于开启的开关与“完成”。
 */
final class SettingsDialog extends Dialog {
    private final MainActivity activity;
    private final LinearLayout body;
    private TextView logView;
    private EditText manualInput;
    private String manualDraft = "";

    SettingsDialog(MainActivity activity) {
        super(activity, android.R.style.Theme_DeviceDefault_NoActionBar);
        this.activity = activity;

        LinearLayout root = new LinearLayout(activity);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(PanelUi.CANVAS);
        root.setFitsSystemWindows(true);

        LinearLayout bar = new LinearLayout(activity);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setPadding(dp(20), dp(8), dp(8), dp(4));
        bar.addView(PanelUi.bold(activity, "设置", 17, TEXT), PanelUi.weight1());
        bar.addView(PanelUi.linkButton(activity, "完成", ACCENT, v -> dismiss()));
        root.addView(bar);

        ScrollView scroll = new ScrollView(activity);
        body = new LinearLayout(activity);
        body.setOrientation(LinearLayout.VERTICAL);
        body.setPadding(dp(20), dp(8), dp(20), dp(32));
        scroll.addView(body);
        root.addView(scroll, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        setContentView(root);
        if (getWindow() != null) {
            getWindow().setStatusBarColor(PanelUi.CANVAS);
            getWindow().setNavigationBarColor(PanelUi.CANVAS);
        }
    }

    private int dp(float v) { return PanelUi.dp(activity, v); }

    /** 整页重建(设备状态、开关);手动连接的输入草稿跨重建保留 */
    void refresh() {
        SyncCore core = activity.core();
        if (manualInput != null) manualDraft = manualInput.getText().toString();
        body.removeAllViews();
        if (core == null) {
            body.addView(PanelUi.text(activity, "引擎启动中…", 13, TEXT_SECONDARY));
            return;
        }
        identitySection(core);
        pairedSection(core);
        manualSection();
        logSection();
    }

    void refreshLog() {
        if (logView != null) logView.setText(activity.logBuf.length() == 0 ? "暂无记录" : activity.logBuf.toString());
    }

    // ================= 分组 =================

    private LinearLayout group(String title, String footnote) {
        TextView t = PanelUi.text(activity, title, 13, TEXT_SECONDARY);
        t.setPadding(dp(2), 0, 0, dp(6));
        body.addView(t, PanelUi.matchWrap(activity, body.getChildCount() == 0 ? 8 : 24));
        LinearLayout box = new LinearLayout(activity);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setBackground(PanelUi.rounded(activity, FILL, 14));
        body.addView(box, PanelUi.matchWrap(activity, 0));
        if (footnote != null) {
            TextView f = PanelUi.text(activity, footnote, 12, TEXT_SECONDARY);
            f.setPadding(dp(2), dp(6), dp(2), 0);
            body.addView(f);
        }
        return box;
    }

    private LinearLayout row(LinearLayout group) {
        if (group.getChildCount() > 0) {
            View divider = new View(activity);
            divider.setBackgroundColor(DIVIDER);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1);
            lp.leftMargin = dp(14);
            group.addView(divider, lp);
        }
        LinearLayout row = new LinearLayout(activity);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setMinimumHeight(dp(52));
        row.setPadding(dp(14), dp(8), dp(10), dp(8));
        group.addView(row);
        return row;
    }

    private void labelValue(LinearLayout group, String label, View value) {
        LinearLayout r = row(group);
        r.addView(PanelUi.text(activity, label, 15, TEXT), PanelUi.weight1());
        r.addView(value);
    }

    // ================= 本机 =================

    private void identitySection(SyncCore core) {
        LinearLayout g = group("本机", "设备名跟随系统设置里的设备型号。配对时双方核对指纹前 8 位。");
        labelValue(g, "设备名", PanelUi.text(activity, core.deviceName(), 15, TEXT_SECONDARY));

        String fp = core.fingerprint();
        LinearLayout fpValue = new LinearLayout(activity);
        fpValue.setOrientation(LinearLayout.HORIZONTAL);
        fpValue.setGravity(Gravity.CENTER_VERTICAL);
        TextView shortFp = PanelUi.text(activity, PanelUi.shortFp(fp), 15, TEXT_SECONDARY);
        shortFp.setFontFeatureSettings("tnum");
        fpValue.addView(shortFp);
        fpValue.addView(PanelUi.linkButton(activity, "复制完整指纹", ACCENT, v -> {
            ClipboardManager cm = (ClipboardManager) activity.getSystemService(Context.CLIPBOARD_SERVICE);
            cm.setPrimaryClip(ClipData.newPlainText("fingerprint", fp));
            activity.toast("已复制完整指纹");
        }));
        labelValue(g, "指纹", fpValue);

        TextView port = PanelUi.text(activity, String.valueOf(core.listeningPort()), 15, TEXT_SECONDARY);
        port.setFontFeatureSettings("tnum");
        labelValue(g, "端口", port);
    }

    // ================= 已配对设备 =================

    private void pairedSection(SyncCore core) {
        LinearLayout g = group("已配对设备 · 自动接收文件",
                "关闭开关后，这台设备发来的每个文件都需要你确认，2 分钟未处理自动拒绝。");
        List<String[]> paired = core.pairedSnapshot();
        List<String[]> online = core.onlinePeersSnapshot();
        if (paired.isEmpty()) {
            row(g).addView(PanelUi.text(activity, "还没有配对的设备", 15, TEXT_SECONDARY));
        }
        for (String[] p : paired) {
            String fp = p[0], name = p[1];
            boolean isOnline = false;
            for (String[] o : online) if (o[0].equals(fp)) isOnline = true;

            LinearLayout r = row(g);
            r.addView(PanelUi.avatar(activity, name, isOnline, 34));

            LinearLayout texts = new LinearLayout(activity);
            texts.setOrientation(LinearLayout.VERTICAL);
            texts.addView(PanelUi.singleLine(PanelUi.text(activity, name, 15, isOnline ? TEXT : TEXT_SECONDARY),
                    TextUtils.TruncateAt.END));
            TextView status = PanelUi.text(activity, (isOnline ? "在线" : "离线") + " · " + PanelUi.shortFp(fp),
                    12, TEXT_SECONDARY);
            status.setFontFeatureSettings("tnum");
            texts.addView(status);
            LinearLayout.LayoutParams textsLp = PanelUi.weight1();
            textsLp.leftMargin = dp(12);
            r.addView(texts, textsLp);

            Switch trust = new Switch(activity);
            trust.setChecked(core.isFileTrusted(fp));
            trust.setThumbTintList(ColorStateList.valueOf(0xFFFFFFFF));
            trust.setTrackTintList(new ColorStateList(
                    new int[][]{{android.R.attr.state_checked}, {}},
                    new int[]{ACCENT, 0x40FFFFFF}));
            trust.setContentDescription("自动接收 " + name + " 的文件");
            trust.setOnCheckedChangeListener((b, checked) -> {
                SyncCore c = activity.core();
                if (c != null) c.setFileTrust(fp, checked);
            });
            r.addView(trust);

            r.setOnLongClickListener(v -> {
                activity.confirmRemove(fp, name);
                return true;
            });
            TextView remove = PanelUi.linkButton(activity, "移除", TEXT_SECONDARY, v -> activity.confirmRemove(fp, name));
            r.addView(remove);
        }
    }

    // ================= 手动连接 =================

    private void manualSection() {
        LinearLayout g = group("手动连接", "局域网发现受限（如访客网络、热点）时，输入对方的 IP:端口。");
        LinearLayout r = row(g);
        manualInput = new EditText(activity);
        manualInput.setHint("192.168.x.x:52525");
        manualInput.setText(manualDraft);
        manualInput.setTextSize(15);
        manualInput.setTextColor(TEXT);
        manualInput.setHintTextColor(PanelUi.TEXT_TERTIARY);
        manualInput.setBackground(null);
        manualInput.setSingleLine(true);
        manualInput.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        r.addView(manualInput, PanelUi.weight1());
        Button connect = PanelUi.primaryButton(activity, "连接", 36, 14);
        connect.setOnClickListener(v -> manualConnect());
        r.addView(connect, new LinearLayout.LayoutParams(dp(76), dp(36)));
    }

    private void manualConnect() {
        SyncCore core = activity.core();
        if (core == null) { activity.toast("引擎启动中"); return; }
        String text = manualInput.getText().toString().trim();
        int colon = text.lastIndexOf(':');
        if (colon <= 0) { activity.toast("格式：IP:端口"); return; }
        try {
            String host = text.substring(0, colon).trim();
            if (host.startsWith("[") && host.endsWith("]")) host = host.substring(1, host.length() - 1);
            int port = Integer.parseInt(text.substring(colon + 1).trim());
            core.connectTo(host, port);
            activity.toast("正在连接 " + host + ":" + port);
        } catch (Exception e) {
            activity.toast("地址无效：" + e.getMessage());
        }
    }

    // ================= 日志 =================

    private void logSection() {
        LinearLayout g = group("日志", null);
        logView = PanelUi.text(activity, "", 11, TEXT_SECONDARY);
        logView.setTypeface(Typeface.MONOSPACE);
        logView.setTextIsSelectable(true);
        logView.setPadding(dp(14), dp(12), dp(14), dp(12));
        g.addView(logView);
        refreshLog();
    }
}
