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
        return START_STICKY
    }

    override fun onDestroy() {
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
    }

    private fun releaseLocks() {
        screenReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (ignored: Exception) {
            }
        }
        screenReceiver = null
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

        private var lastText = ""
        private var channel: MethodChannel? = null
        private val mainHandler = Handler(Looper.getMainLooper())

        private fun notifyDart(method: String) {
            mainHandler.post { channel?.invokeMethod(method, null) }
        }

        fun register(context: Context, engine: FlutterEngine) {
            val appContext = context.applicationContext
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
                                appContext.stopService(
                                    Intent(appContext, LinkedPlaybackService::class.java)
                                )
                                result.success(null)
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
