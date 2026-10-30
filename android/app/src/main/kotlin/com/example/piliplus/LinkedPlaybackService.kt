package com.example.piliplus

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 联动播放期间常驻的前台服务：保持 CPU 与 WiFi 唤醒、接收局域网广播，
 * 使熄屏或位于后台时连接与播放同步不中断
 */
class LinkedPlaybackService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLocks: List<WifiManager.WifiLock> = emptyList()
    private var multicastLock: WifiManager.MulticastLock? = null
    private var screenReceiver: BroadcastReceiver? = null
    private var volumeReceiver: BroadcastReceiver? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: lastText
        lastText = text
        val notification = buildNotification(text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        acquireLocks()
        // 进程被回收后不由系统重建：此时没有应用会话，单独的服务无法恢复联动，
        // 用户重新打开应用即恢复
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        resetVolume()
        releaseLocks()
        super.onDestroy()
    }

    @SuppressLint("WakelockTimeout")
    private fun acquireLocks() {
        if (wakeLock == null) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "PiliPlus:LinkedPlayback",
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        if (wifiLocks.isEmpty()) {
            @Suppress("DEPRECATION")
            val modes = buildList {
                add(WifiManager.WIFI_MODE_FULL_HIGH_PERF)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    add(WifiManager.WIFI_MODE_FULL_LOW_LATENCY)
                }
            }
            wifiLocks = modes.mapNotNull { mode ->
                try {
                    wifi.createWifiLock(mode, "PiliPlus:LinkedPlayback:$mode").apply {
                        setReferenceCounted(false)
                        acquire()
                    }
                } catch (ignored: Exception) {
                    null
                }
            }
        }
        if (multicastLock == null) {
            multicastLock = try {
                wifi.createMulticastLock("PiliPlus:LinkedPlayback").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            } catch (ignored: Exception) {
                null
            }
        }
        if (screenReceiver == null) {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    notifyDart("screenOn")
                }
            }
            val filter = IntentFilter(Intent.ACTION_SCREEN_ON)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(receiver, filter)
            }
            screenReceiver = receiver
        }
        if (volumeReceiver == null) {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    val stream = intent?.getIntExtra(EXTRA_VOLUME_STREAM_TYPE, -1)
                    if (stream != AudioManager.STREAM_MUSIC) return
                    val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    // 以广播自带的本次档位为准，读取当前值可能已是之后的变化
                    val index = intent?.getIntExtra(EXTRA_VOLUME_STREAM_VALUE, -1)
                        ?.takeIf { it >= 0 }
                        ?: audio.getStreamVolume(AudioManager.STREAM_MUSIC)
                    notifyDart(
                        "volume",
                        mapOf(
                            "v" to volumeOf(audio, index),
                            "self" to isOwnChange(index),
                        ),
                    )
                }
            }
            val filter = IntentFilter(VOLUME_CHANGED_ACTION)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(receiver, filter)
            }
            volumeReceiver = receiver
        }
    }

    private fun releaseLocks() {
        screenReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (ignored: Exception) {
            }
        }
        screenReceiver = null
        volumeReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (ignored: Exception) {
            }
        }
        volumeReceiver = null
        multicastLock?.takeIf { it.isHeld }?.release()
        multicastLock = null
        wifiLocks.forEach { if (it.isHeld) it.release() }
        wifiLocks = emptyList()
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
    }

    private fun buildNotification(text: String): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "联动播放",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply { setShowBadge(false) }
            )
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.drawable.ic_notification_icon)
            .setContentTitle("联动播放")
            .setContentText(text)
            .setContentIntent(launch)
            .setOngoing(true)
            .setShowWhen(false)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "com.example.piliplus.linked_playback"
        private const val NOTIFICATION_ID = 41763
        private const val EXTRA_TEXT = "text"
        private const val METHOD_CHANNEL = "com.example.piliplus/linked_playback"
        private const val VOLUME_CHANGED_ACTION = "android.media.VOLUME_CHANGED_ACTION"
        private const val EXTRA_VOLUME_STREAM_TYPE = "android.media.EXTRA_VOLUME_STREAM_TYPE"
        private const val EXTRA_VOLUME_STREAM_VALUE = "android.media.EXTRA_VOLUME_STREAM_VALUE"

        /** 本机设置音量后等待系统回报确认的最长时间，超时后不再视为待确认 */
        private const val PENDING_TIMEOUT_MS = 1000L

        private var lastText = ""
        private var channel: MethodChannel? = null
        private val mainHandler = Handler(Looper.getMainLooper())

        private var audioManager: AudioManager? = null

        /**
         * 本机发起、尚待系统回报确认的音量档位。设置串行进行，同一时刻最多一条，
         * 系统回报的档位与之相同即为确认，否则为用户调整
         */
        private var pendingIndex: Int? = null
        private var pendingToken = 0

        /** 待确认期间收到的最新设置目标，确认或超时后再应用 */
        private var queuedIndex: Int? = null

        private fun notifyDart(method: String, arguments: Any? = null) {
            mainHandler.post { channel?.invokeMethod(method, arguments) }
        }

        private fun volumeOf(audio: AudioManager, index: Int): Double {
            val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            return if (max > 0) index.toDouble() / max else 0.0
        }

        /** 系统回报的音量是否为本机设置所致（在主线程调用） */
        private fun isOwnChange(index: Int): Boolean {
            val pending = pendingIndex ?: return false
            pendingIndex = null
            if (pending != index) {
                // 用户调整：作废排队的设置，以用户的音量为准
                queuedIndex = null
                return false
            }
            applyQueued()
            return true
        }

        /** 联动停止：作废待确认、排队的设置及超时回调 */
        private fun resetVolume() {
            pendingIndex = null
            queuedIndex = null
            pendingToken++
        }

        private fun applyQueued() {
            val queued = queuedIndex ?: return
            queuedIndex = null
            applyIndex(queued)
        }

        private fun applyIndex(index: Int) {
            val audio = audioManager ?: return
            if (index == audio.getStreamVolume(AudioManager.STREAM_MUSIC)) return
            val token = ++pendingToken
            pendingIndex = index
            audio.setStreamVolume(AudioManager.STREAM_MUSIC, index, 0)
            mainHandler.postDelayed({
                if (token == pendingToken && pendingIndex == index) {
                    pendingIndex = null
                    applyQueued()
                }
            }, PENDING_TIMEOUT_MS)
        }

        /**
         * 设置媒体音量（取最接近的档位），不显示系统音量界面，返回当前实际音量；
         * 上一次设置尚未确认时只记下最新目标（在主线程调用）
         */
        private fun setVolume(volume: Double): Double {
            val audio = audioManager ?: return 0.0
            val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            val index = Math.round(volume.coerceIn(0.0, 1.0) * max).toInt()
            if (pendingIndex != null) {
                queuedIndex = index
            } else {
                applyIndex(index)
            }
            return volumeOf(audio, audio.getStreamVolume(AudioManager.STREAM_MUSIC))
        }

        fun register(context: Context, engine: FlutterEngine) {
            val appContext = context.applicationContext
            audioManager = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            channel = MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL).apply {
                setMethodCallHandler { call, result ->
                    try {
                        when (call.method) {
                            "start" -> {
                                val intent = Intent(appContext, LinkedPlaybackService::class.java)
                                    .putExtra(EXTRA_TEXT, call.argument<String>("text") ?: "")
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                    appContext.startForegroundService(intent)
                                } else {
                                    appContext.startService(intent)
                                }
                                result.success(null)
                            }

                            "stop" -> {
                                resetVolume()
                                appContext.stopService(
                                    Intent(appContext, LinkedPlaybackService::class.java)
                                )
                                result.success(null)
                            }

                            "getVolume" -> {
                                val audio = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                                result.success(
                                    volumeOf(audio, audio.getStreamVolume(AudioManager.STREAM_MUSIC))
                                )
                            }

                            "setVolume" -> {
                                result.success(setVolume(call.argument<Double>("v") ?: 0.0))
                            }

                            else -> result.notImplemented()
                        }
                    } catch (e: Exception) {
                        result.error("linked_playback", e.message, null)
                    }
                }
            }
        }
    }
}
