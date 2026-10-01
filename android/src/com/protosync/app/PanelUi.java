package com.protosync.app;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.Locale;

/**
 * 面板设计(方向 B,docs/design/MENUBAR_PANEL.md)的 Android 令牌与小组件,
 * 对应 Swift 端 PanelStyle.swift。固定深色;Lime 只用于主按钮、在线点、进度与开启的开关。
 */
final class PanelUi {
    static final int CANVAS = 0xFF141416;
    static final int FILL = 0x0FFFFFFF;          // white 6%
    static final int FILL_STRONG = 0x1CFFFFFF;   // white 11%
    static final int DIVIDER = 0x0FFFFFFF;
    static final int TEXT = 0xFFF5F5F7;
    static final int TEXT_SECONDARY = 0xFF98989D;
    static final int TEXT_TERTIARY = 0xFF636366;
    static final int ACCENT = 0xFFE7FF16;
    static final int ON_ACCENT = 0xFF15181B;
    static final int CORAL = 0xFFFF6B66;
    private static final int RIPPLE = 0x22FFFFFF;

    private PanelUi() {}

    static int dp(Context c, float v) {
        return Math.round(v * c.getResources().getDisplayMetrics().density);
    }

    // ================= 形状 =================

    static GradientDrawable rounded(Context c, int color, float radiusDp) {
        GradientDrawable d = new GradientDrawable();
        d.setColor(color);
        d.setCornerRadius(dp(c, radiusDp));
        return d;
    }

    static GradientDrawable circle(int color) {
        GradientDrawable d = new GradientDrawable();
        d.setShape(GradientDrawable.OVAL);
        d.setColor(color);
        return d;
    }

    static GradientDrawable dashedCircle(Context c, int strokeColor) {
        GradientDrawable d = new GradientDrawable();
        d.setShape(GradientDrawable.OVAL);
        d.setColor(0);
        d.setStroke(dp(c, 1.5f), strokeColor, dp(c, 5), dp(c, 4));
        return d;
    }

    /** 可点按的填充底(带水波纹):行、卡片、次要按钮共用 */
    static Drawable pressable(Context c, int color, float radiusDp) {
        return new RippleDrawable(ColorStateList.valueOf(RIPPLE), rounded(c, color, radiusDp),
                rounded(c, 0xFFFFFFFF, radiusDp));
    }

    // ================= 文字 =================

    static TextView text(Context c, CharSequence s, float sp, int color) {
        TextView tv = new TextView(c);
        tv.setText(s);
        tv.setTextSize(sp);
        tv.setTextColor(color);
        return tv;
    }

    static TextView bold(Context c, CharSequence s, float sp, int color) {
        TextView tv = text(c, s, sp, color);
        tv.setTypeface(Typeface.DEFAULT_BOLD);
        return tv;
    }

    static TextView singleLine(TextView tv, android.text.TextUtils.TruncateAt where) {
        tv.setSingleLine(true);
        tv.setEllipsize(where);
        return tv;
    }

    /** 分组标题:13sp 次要色 */
    static TextView sectionTitle(Context c, String s) {
        TextView tv = text(c, s, 13, TEXT_SECONDARY);
        tv.setPadding(dp(c, 2), 0, 0, dp(c, 6));
        return tv;
    }

    // ================= 按钮 =================

    static Button primaryButton(Context c, String label, float heightDp, float sp) {
        Button b = baseButton(c, label, sp, heightDp);
        b.setTextColor(ON_ACCENT);
        b.setTypeface(Typeface.DEFAULT_BOLD);
        b.setBackground(pressable(c, ACCENT, heightDp > 40 ? 12 : 8));
        return b;
    }

    static Button secondaryButton(Context c, String label, float heightDp, float sp) {
        Button b = baseButton(c, label, sp, heightDp);
        b.setTextColor(TEXT);
        b.setBackground(pressable(c, FILL_STRONG, heightDp > 40 ? 12 : 8));
        return b;
    }

    private static Button baseButton(Context c, String label, float sp, float heightDp) {
        Button b = new Button(c);
        b.setText(label);
        b.setTextSize(sp);
        b.setAllCaps(false);
        b.setStateListAnimator(null);
        b.setMinHeight(dp(c, heightDp));
        b.setMinimumHeight(dp(c, heightDp));
        b.setPadding(dp(c, 12), 0, dp(c, 12), 0);
        return b;
    }

    /** 纯文字按钮(链接样式),保证 44dp 触控高度 */
    static TextView linkButton(Context c, String label, int color, View.OnClickListener onClick) {
        TextView tv = text(c, label, 13, color);
        tv.setGravity(Gravity.CENTER);
        tv.setMinHeight(dp(c, 44));
        tv.setPadding(dp(c, 8), 0, dp(c, 8), 0);
        tv.setBackground(new RippleDrawable(ColorStateList.valueOf(RIPPLE), null, rounded(c, 0xFFFFFFFF, 8)));
        tv.setOnClickListener(onClick);
        return tv;
    }

    // ================= 设备头像 =================

    /** 设备类型图标:协议不携带设备类型,按设备名推断(只影响图标),与 Swift Panel.glyph 一致 */
    static int glyph(String name) {
        String n = name == null ? "" : name.toLowerCase(Locale.ROOT);
        if (n.contains("iphone")) return R.drawable.ic_phone;
        if (n.contains("ipad")) return R.drawable.ic_tablet;
        if (n.contains("macbook")) return R.drawable.ic_laptop;
        if (n.contains("imac") || n.contains("mac mini") || n.contains("mac studio") || n.contains("mac pro"))
            return R.drawable.ic_desktop;
        return R.drawable.ic_phone;
    }

    /** 圆形设备头像:sizeDp 直径;在线时右下角 Lime 点(描一圈画布色,与背景分开) */
    static FrameLayout avatar(Context c, String name, boolean online, float sizeDp) {
        FrameLayout frame = new FrameLayout(c);
        View disc = new View(c);
        disc.setBackground(circle(online ? FILL_STRONG : FILL));
        frame.addView(disc, new FrameLayout.LayoutParams(dp(c, sizeDp), dp(c, sizeDp)));

        ImageView icon = new ImageView(c);
        icon.setImageResource(glyph(name));
        icon.setImageTintList(ColorStateList.valueOf(online ? TEXT : TEXT_TERTIARY));
        int iconSize = dp(c, sizeDp * 0.36f);
        FrameLayout.LayoutParams iconLp = new FrameLayout.LayoutParams(iconSize, iconSize, Gravity.CENTER);
        frame.addView(icon, iconLp);

        if (online) {
            View dot = new View(c);
            GradientDrawable d = circle(ACCENT);
            d.setStroke(dp(c, sizeDp > 50 ? 2.5f : 1.5f), CANVAS);
            dot.setBackground(d);
            int dotSize = dp(c, sizeDp > 50 ? 14 : 9);
            FrameLayout.LayoutParams dotLp = new FrameLayout.LayoutParams(dotSize, dotSize, Gravity.BOTTOM | Gravity.END);
            dotLp.rightMargin = dp(c, sizeDp > 50 ? 3 : 0);
            dotLp.bottomMargin = dp(c, sizeDp > 50 ? 3 : 0);
            frame.addView(dot, dotLp);
        }
        frame.setLayoutParams(new LinearLayout.LayoutParams(dp(c, sizeDp), dp(c, sizeDp)));
        return frame;
    }

    // ================= 进度条 =================

    /** 3dp 细进度条:轨道 white 10%,填充 Lime(失败时 Coral) */
    static View progressBar(Context c, double fraction, boolean failed) {
        LinearLayout track = new LinearLayout(c);
        track.setOrientation(LinearLayout.HORIZONTAL);
        track.setBackground(rounded(c, 0x1AFFFFFF, 2));
        float f = (float) Math.max(0.02, Math.min(1, fraction));
        View fill = new View(c);
        fill.setBackground(rounded(c, failed ? CORAL : ACCENT, 2));
        track.addView(fill, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, f));
        if (f < 1f) {
            track.addView(new View(c), new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f - f));
        }
        track.setLayoutParams(new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(c, 3)));
        return track;
    }

    // ================= 布局参数 =================

    static LinearLayout.LayoutParams matchWrap(Context c, float topMarginDp) {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(c, topMarginDp);
        return lp;
    }

    static LinearLayout.LayoutParams weight1() {
        return new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
    }

    static String shortFp(String fp) {
        if (fp == null || fp.length() < 8) return fp == null ? "" : fp;
        return fp.substring(0, 4) + " " + fp.substring(4, 8);
    }

    static String groupedFp(String fp) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < fp.length(); i += 4) {
            if (sb.length() > 0) sb.append(' ');
            sb.append(fp, i, Math.min(fp.length(), i + 4));
        }
        return sb.toString();
    }
}
