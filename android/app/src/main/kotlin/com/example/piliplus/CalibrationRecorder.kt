package com.example.piliplus

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AudioEffect
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * 联动播放声学校准的录音：单声道 16 位 PCM，录音来源优先不做处理的
 * UNPROCESSED，其次语音识别、普通麦克风，并关闭回声消除、降噪与自动增益。
 * 只录音，不涉及播放输出；录到的数据由 Dart 端定时取走
 */
object CalibrationRecorder {
    private const val METHOD_CHANNEL = "com.example.piliplus/linked_calibration"

    private var record: AudioRecord? = null
    private var effects: List<AudioEffect> = emptyList()
    private var thread: Thread? = null

    @Volatile
    private var running = false
    private val buffer = ByteArrayOutputStream()
    private val lock = Any()

    fun register(context: Context, engine: FlutterEngine) {
        val appContext = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "start" -> result.success(
                            start(appContext, call.argument<Int>("rate") ?: 48000)
                        )

                        "read" -> result.success(read())

                        "stop" -> {
                            stop()
                            result.success(null)
                        }

                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("linked_calibration", e.message, null)
                }
            }
    }

    @SuppressLint("MissingPermission")
    private fun start(context: Context, rate: Int): String {
        stop()
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val sources = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
                audio.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED) == "true"
            ) {
                add(MediaRecorder.AudioSource.UNPROCESSED to "unprocessed")
            }
            add(MediaRecorder.AudioSource.VOICE_RECOGNITION to "voice_recognition")
            add(MediaRecorder.AudioSource.MIC to "mic")
        }
        val minSize = AudioRecord.getMinBufferSize(
            rate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        // 至少 200ms，读取线程每次取出不超过其一半
        val size = maxOf(minSize, rate * 2 / 5)
        for ((source, name) in sources) {
            val candidate = try {
                AudioRecord(
                    source,
                    rate,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                    size,
                )
            } catch (e: Exception) {
                null
            } ?: continue
            if (candidate.state != AudioRecord.STATE_INITIALIZED) {
                candidate.release()
                continue
            }
            val attached = disableEffects(candidate.audioSessionId)
            try {
                candidate.startRecording()
            } catch (e: Exception) {
                attached.forEach { it.release() }
                candidate.release()
                continue
            }
            if (candidate.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                attached.forEach { it.release() }
                candidate.release()
                continue
            }
            record = candidate
            effects = attached
            running = true
            thread = Thread {
                val chunk = ByteArray(size / 2)
                while (running) {
                    val read = candidate.read(chunk, 0, chunk.size)
                    if (read > 0) {
                        synchronized(lock) { buffer.write(chunk, 0, read) }
                    } else if (read < 0) {
                        break
                    }
                }
            }.apply { start() }
            return name
        }
        throw IllegalStateException("无法打开麦克风")
    }

    /** 关闭系统可能默认挂接的语音处理，失败时忽略 */
    private fun disableEffects(session: Int): List<AudioEffect> {
        val list = mutableListOf<AudioEffect>()
        try {
            if (AcousticEchoCanceler.isAvailable()) {
                AcousticEchoCanceler.create(session)?.let { list.add(it) }
            }
            if (NoiseSuppressor.isAvailable()) {
                NoiseSuppressor.create(session)?.let { list.add(it) }
            }
            if (AutomaticGainControl.isAvailable()) {
                AutomaticGainControl.create(session)?.let { list.add(it) }
            }
            list.forEach { it.enabled = false }
        } catch (e: Exception) {
        }
        return list
    }

    private fun read(): ByteArray = synchronized(lock) {
        val bytes = buffer.toByteArray()
        buffer.reset()
        bytes
    }

    private fun stop() {
        running = false
        val current = record
        if (current != null) {
            try {
                current.stop()
            } catch (e: Exception) {
            }
        }
        thread?.join(500)
        thread = null
        effects.forEach { it.release() }
        effects = emptyList()
        current?.release()
        record = null
        synchronized(lock) { buffer.reset() }
    }
}
