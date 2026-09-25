package com.protosync.app;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.os.Bundle;
import android.widget.Toast;

/**
 * 透明剪贴板中转页(通知「复制」按钮的落点)。
 *
 * 为什么必须有一个 Activity:Android 10+ 只允许**持有窗口焦点的应用**写剪贴板,
 * 通知 action 的 receiver/service 回调拿不到焦点,setPrimaryClip 会被静默忽略。
 * 用户点通知按钮 = 主动操作,直接拉起本透明页(符合 Android 12 对 notification
 * trampoline 的限制——禁的是 receiver 中转 startActivity,直接 PendingIntent.getActivity 合规),
 * onWindowFocusChanged 拿到焦点后写入,随即 finish,用户停留在原应用无感知。
 *
 * 文本经内存静态变量传递(Intent extra 会被 Binder 限制截断大文本);进程若在中途被杀,
 * 按钮表现为无操作,无副作用。
 */
public class CopyActivity extends Activity {
    private static volatile String staged;

    public static void stage(String text) { staged = text; }

    private String pending;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        pending = staged;
        staged = null;
        overridePendingTransition(0, 0);
        // 兜底:窗口焦点迟迟不来(如息屏瞬间)也要退出,不能留下透明残页
        getWindow().getDecorView().postDelayed(this::finishIfNotFinishing, 1500);
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus && pending != null) {
            ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
            cm.setPrimaryClip(ClipData.newPlainText("protosync", pending));
            Toast.makeText(this, "已复制到剪贴板(" + pending.length() + " 字)", Toast.LENGTH_SHORT).show();
            pending = null;
            finish();
            overridePendingTransition(0, 0);
        }
    }

    private void finishIfNotFinishing() {
        if (!isFinishing()) {
            finish();
            overridePendingTransition(0, 0);
        }
    }
}
