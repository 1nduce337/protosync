package com.protosync.app;

import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.util.AttributeSet;
import android.view.View;

/**
 * Transfer Track(设计文档 §9.4):左端来源节点 → 中间轨道 → 右端目标节点。
 * 传输中:Cyan 轨道进度 + 沿轨脉冲;完成:Lime 实线;失败:Coral 断点。
 * 不显示 ETA/速率(协议没有这些数据,§12)。
 */
public class TransferTrackView extends View {
    public enum State { SYNCING, DONE, FAILED }

    private static final int COLOR_TRACK = 0x33707980; // Steel 40%
    private static final int COLOR_NODE_IDLE = 0xFF707980;

    private final Paint trackPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint progressPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint nodePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint nodeFillPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint pulsePaint = new Paint(Paint.ANTI_ALIAS_FLAG);

    private float fraction = 0f;
    private State state = State.SYNCING;
    private int colorCyan = 0xFF25C7E8, colorLime = 0xFFE7FF16, colorCoral = 0xFFFF5B55;
    private int colorText = 0xFFF2F3EE;
    private float pulsePhase = 0f;
    private ValueAnimator animator;

    public TransferTrackView(Context context) { this(context, null); }

    public TransferTrackView(Context context, AttributeSet attrs) {
        super(context, attrs);
        trackPaint.setStyle(Paint.Style.STROKE);
        trackPaint.setStrokeWidth(dp(2));
        trackPaint.setColor(COLOR_TRACK);

        progressPaint.setStyle(Paint.Style.STROKE);
        progressPaint.setStrokeWidth(dp(2));

        nodePaint.setStyle(Paint.Style.STROKE);
        nodePaint.setStrokeWidth(dp(2));

        nodeFillPaint.setStyle(Paint.Style.FILL);

        pulsePaint.setStyle(Paint.Style.FILL);

        // 传输中的短亮条沿轨道循环移动(140–240ms 节奏,设计文档 §10.2)
        animator = ValueAnimator.ofFloat(0f, 1f);
        animator.setDuration(1400);
        animator.setRepeatCount(ValueAnimator.INFINITE);
        animator.addUpdateListener(a -> {
            pulsePhase = (float) a.getAnimatedValue();
            if (state == State.SYNCING) invalidate();
        });
    }

    @Override protected void onAttachedToWindow() {
        super.onAttachedToWindow();
        if (state == State.SYNCING) animator.start();
    }

    @Override protected void onDetachedFromWindow() {
        animator.cancel();
        super.onDetachedFromWindow();
    }

    public void update(float fraction, State state, int cyan, int lime, int coral, int text) {
        this.fraction = Math.max(0f, Math.min(1f, fraction));
        this.state = state;
        this.colorCyan = cyan;
        this.colorLime = lime;
        this.colorCoral = coral;
        this.colorText = text;
        if (state == State.SYNCING) {
            if (!animator.isRunning()) animator.start();
        } else {
            animator.cancel();
        }
        invalidate();
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        float cy = getHeight() / 2f;
        float nodeR = dp(9);
        float left = getPaddingLeft() + nodeR + dp(2);
        float right = getWidth() - getPaddingRight() - nodeR - dp(2);
        float y = cy;

        // 底轨
        canvas.drawLine(left, y, right, y, trackPaint);

        // 进度色
        int accent;
        switch (state) {
            case DONE: accent = colorLime; break;
            case FAILED: accent = colorCoral; break;
            default: accent = colorCyan;
        }
        progressPaint.setColor(accent);
        float progressEnd = left + (right - left) * (state == State.DONE ? 1f : fraction);
        if (progressEnd > left) canvas.drawLine(left, y, progressEnd, y, progressPaint);

        // 传输中:短亮条脉冲沿轨道移动
        if (state == State.SYNCING) {
            float pulseX = left + (right - left) * pulsePhase;
            float half = dp(10);
            float from = Math.max(left, pulseX - half);
            float to = Math.min(right, pulseX + half);
            if (to > from) {
                pulsePaint.setColor(accent);
                pulsePaint.setAlpha(90);
                canvas.drawLine(from, y, to, y, pulsePaint);
                pulsePaint.setAlpha(255);
            }
            // 中央数据点
            nodeFillPaint.setColor(accent);
            canvas.drawCircle((left + right) / 2f, y, dp(3), nodeFillPaint);
        }

        // 两端节点:外环 + 内芯
        nodePaint.setColor(accent);
        canvas.drawCircle(left, y, nodeR, nodePaint);
        canvas.drawCircle(right, y, nodeR, nodePaint);
        nodeFillPaint.setColor(state == State.FAILED ? colorCoral : accent);
        canvas.drawCircle(left, y, dp(3), nodeFillPaint);
        canvas.drawCircle(right, y, dp(3), nodeFillPaint);

        // 失败:轨道中点断口标记
        if (state == State.FAILED) {
            nodePaint.setColor(colorCoral);
            float mid = (left + right) / 2f;
            canvas.drawLine(mid - dp(6), y - dp(6), mid + dp(6), y + dp(6), nodePaint);
            canvas.drawLine(mid - dp(6), y + dp(6), mid + dp(6), y - dp(6), nodePaint);
        }

        // 方向箭头小刻度:右节点外侧指向目标
        if (state != State.FAILED) {
            nodePaint.setColor(colorText);
            canvas.drawLine(right + dp(6), y, right + dp(12), y, nodePaint);
            canvas.drawLine(right + dp(9), y - dp(3), right + dp(12), y, nodePaint);
            canvas.drawLine(right + dp(9), y + dp(3), right + dp(12), y, nodePaint);
        }
    }

    private float dp(int v) {
        return v * getResources().getDisplayMetrics().density;
    }
}
