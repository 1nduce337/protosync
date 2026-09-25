package com.protosync.core;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Handler;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * NSD(Bonjour)注册 + 浏览。
 *
 * 关键点:
 * - NsdManager 经 getSystemService 获取(SDK 34 stub 不开放双参构造),其回调在主线程
 *   返回;这里把全部状态机逻辑投递回引擎线程执行,状态变更仍然单线程化。
 * - NSD 的 stop 是异步的,连续「停止→立即重开」会 already-active/internal error 导致
 *   发现永久停摆(旧实现的坑)。显式状态机:
 *     IDLE → STARTING → RUNNING → STOPPING → (restartRequested ? STARTING : IDLE)
 *   失败路径有界退避重试,shutdown 后绝不复活。
 */
public final class DiscoveryManager {
    public static final String SERVICE_TYPE = "_protosync._tcp.";

    public interface Listener {
        void onDiscoveredChanged();   // 引擎线程回调
        void onLog(String line);
    }

    private enum State { IDLE, STARTING, RUNNING, STOPPING }

    private final NsdManager nsd;
    private final Handler engine;
    private final Listener listener;
    private final String myShortFp;
    private final int myPort;

    private State state = State.IDLE;        // 引擎线程专属
    private boolean restartRequested = false;
    private boolean shutdown = false;
    private int startRetries = 0;

    private NsdManager.RegistrationListener regListener;
    private NsdManager.DiscoveryListener discListener;

    /** serviceName(指纹前8位,同名冲突会带 " (2)" 后缀)→ 已解析服务信息。引擎线程写,快照给任意线程。 */
    private final Map<String, NsdServiceInfo> resolved = new LinkedHashMap<>();

    public DiscoveryManager(Context context, Handler engineHandler,
                            String fingerprint, int listenPort, Listener listener) {
        this.nsd = (NsdManager) context.getSystemService(Context.NSD_SERVICE);
        this.engine = engineHandler;
        this.myShortFp = fingerprint.substring(0, Math.min(8, fingerprint.length()));
        this.myPort = listenPort;
        this.listener = listener;
    }

    /** 任意线程:返回快照。 */
    public Map<String, NsdServiceInfo> resolvedSnapshot() {
        synchronized (resolved) {
            return new LinkedHashMap<>(resolved);
        }
    }

    /** 服务名前缀是否指向自己(处理 mDNS 同名冲突改名 "xxxx (2)")。 */
    public boolean isSelf(String serviceName) {
        return serviceName != null && serviceName.startsWith(myShortFp);
    }

    // ---- 以下公开动作任意线程可调,内部转引擎线程 ----

    public void start() {
        engine.post(this::doStart);
    }

    /** 手动刷新:重注册 + 状态机化重启浏览。 */
    public void restart() {
        engine.post(() -> {
            listener.onLog("↻ 刷新发现");
            advertise();
            switch (state) {
                case RUNNING:
                case STARTING:
                case STOPPING:
                    restartRequested = true;
                    if (state == State.RUNNING || state == State.STARTING) {
                        state = State.STOPPING;
                        try { nsd.stopServiceDiscovery(discListener); }
                        catch (Exception e) { onDiscoverStopped(); }
                    }
                    break;
                case IDLE:
                    beginDiscovery();
                    break;
            }
        });
    }

    public void stop() {
        engine.post(() -> {
            shutdown = true;
            restartRequested = false;
            unadvertise();
            if (state == State.RUNNING || state == State.STARTING) {
                try { nsd.stopServiceDiscovery(discListener); } catch (Exception ignored) {}
            }
            state = State.IDLE;
        });
    }

    // ---- 引擎线程内部状态机 ----

    private void doStart() {
        advertise();
        beginDiscovery();
    }

    private void beginDiscovery() {
        if (shutdown) return;
        state = State.STARTING;
        // NSD 回调在主线程,全部转投引擎线程
        discListener = new NsdManager.DiscoveryListener() {
            @Override public void onDiscoveryStarted(String type) {
                engine.post(() -> {
                    state = State.RUNNING;
                    startRetries = 0;
                    if (restartRequested) restart(); // 停止期间又来了刷新请求
                });
            }
            @Override public void onDiscoveryStopped(String type) {
                engine.post(DiscoveryManager.this::onDiscoverStopped);
            }
            @Override public void onStartDiscoveryFailed(String type, int code) {
                engine.post(() -> {
                    listener.onLog("发现启动失败: " + code);
                    state = State.IDLE;
                    scheduleDiscoveryRetry();
                });
            }
            @Override public void onStopDiscoveryFailed(String type, int code) {
                // 停不下来就当作已停,继续走重启/终止路径,避免卡死在 STOPPING
                engine.post(DiscoveryManager.this::onDiscoverStopped);
            }
            @Override public void onServiceFound(NsdServiceInfo info) {
                if (isSelf(info.getServiceName())) return;
                resolve(info);
            }
            @Override public void onServiceLost(NsdServiceInfo info) {
                engine.post(() -> {
                    synchronized (resolved) { resolved.remove(info.getServiceName()); }
                    listener.onDiscoveredChanged();
                });
            }
        };
        try {
            nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discListener);
        } catch (Exception e) {
            state = State.IDLE;
            scheduleDiscoveryRetry();
        }
    }

    private void onDiscoverStopped() {
        synchronized (resolved) { resolved.clear(); }
        listener.onDiscoveredChanged();
        if (shutdown) { state = State.IDLE; return; }
        if (restartRequested) {
            restartRequested = false;
            beginDiscovery();
        } else {
            state = State.IDLE;
        }
    }

    private void scheduleDiscoveryRetry() {
        if (shutdown) return;
        if (startRetries >= 2) { restartRequested = false; return; } // 有界:最多重试 2 次
        startRetries++;
        long delay = 500L * startRetries;
        engine.postDelayed(() -> {
            if (!shutdown && state == State.IDLE) beginDiscovery();
        }, delay);
    }

    private void resolve(NsdServiceInfo info) {
        nsd.resolveService(info, new NsdManager.ResolveListener() {
            @Override public void onResolveFailed(NsdServiceInfo i, int code) {
                engine.post(() -> {
                    synchronized (resolved) { resolved.remove(i.getServiceName()); }
                    listener.onDiscoveredChanged();
                });
            }
            @Override public void onServiceResolved(NsdServiceInfo i) {
                engine.post(() -> {
                    synchronized (resolved) { resolved.put(i.getServiceName(), i); }
                    listener.onDiscoveredChanged();
                });
            }
        });
    }

    // ---- 注册(对外广播)----

    private void advertise() {
        unadvertise();
        regListener = new NsdManager.RegistrationListener() {
            @Override public void onServiceRegistered(NsdServiceInfo info) {}
            @Override public void onServiceUnregistered(NsdServiceInfo info) {}
            @Override public void onRegistrationFailed(NsdServiceInfo info, int errorCode) {
                engine.post(() -> listener.onLog("服务注册失败: " + errorCode));
            }
            @Override public void onUnregistrationFailed(NsdServiceInfo info, int errorCode) {}
        };
        NsdServiceInfo si = new NsdServiceInfo();
        si.setServiceName(myShortFp);
        si.setServiceType(SERVICE_TYPE);
        si.setPort(myPort);
        try {
            nsd.registerService(si, NsdManager.PROTOCOL_DNS_SD, regListener);
        } catch (Exception e) {
            listener.onLog("服务注册异常: " + e.getMessage());
        }
    }

    private void unadvertise() {
        if (regListener != null) {
            try { nsd.unregisterService(regListener); } catch (Exception ignored) {}
            regListener = null;
        }
    }
}
