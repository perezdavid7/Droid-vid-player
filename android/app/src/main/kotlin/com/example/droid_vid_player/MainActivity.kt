package com.example.droid_vid_player

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.view.Surface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.abs

/**
 * Experimental scrub preview: one persistent platform MediaCodec decoder
 * feeding a GPU-backed Flutter Texture. No JPEG transfers, no FFmpeg jobs,
 * no seek requests sent to the ordinary ExoPlayer while finger-dragging.
 *
 * Created only when a picture swipe starts, released when it ends. This
 * separation preserves normal playback and the timeline on codec failure.
 */
class MainActivity : FlutterActivity() {
    private val ui = Handler(android.os.Looper.getMainLooper())
    private val decodeThread = HandlerThread("DroidScrubHardware")
    private lateinit var decode: Handler
    private lateinit var channel: MethodChannel
    private lateinit var flutterEngineRef: FlutterEngine

    private var extractor: MediaExtractor? = null
    private var codec: MediaCodec? = null
    private var entry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var currentPath: String? = null
    private var generation: Int = 0
    private var lastDecodedUs: Long = -1
    private var queuedEos = false
    private val desiredUs = AtomicLong(-1)
    private val pumpScheduled = AtomicBoolean(false)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngineRef = flutterEngine
        decodeThread.start()
        decode = Handler(decodeThread.looper)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "droid_vid_player/hardware_scrub"
        )
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("NO_PATH", "Missing video path", null)
                        return@setMethodCallHandler
                    }
                    desiredUs.set(-1)
                    decode.post {
                        closeInternal()
                        try {
                            val e = MediaExtractor()
                            e.setDataSource(path)
                            val track = (0 until e.trackCount).firstOrNull { index ->
                                e.getTrackFormat(index).getString(MediaFormat.KEY_MIME)
                                    ?.startsWith("video/") == true
                            } ?: throw IllegalStateException("No video track")
                            val format = e.getTrackFormat(track)
                            val mime = format.getString(MediaFormat.KEY_MIME)
                                ?: throw IllegalStateException("No video codec")
                            e.selectTrack(track)
                            val texture = flutterEngineRef.renderer.createSurfaceTexture()
                            val width = format.getInteger(MediaFormat.KEY_WIDTH)
                            val height = format.getInteger(MediaFormat.KEY_HEIGHT)
                            texture.surfaceTexture().setDefaultBufferSize(width, height)
                            val display = Surface(texture.surfaceTexture())
                            val decoder = MediaCodec.createDecoderByType(mime)
                            try {
                                decoder.configure(format, display, null, 0)
                                decoder.start()
                            } catch (error: Exception) {
                                decoder.release()
                                display.release()
                                texture.release()
                                e.release()
                                throw error
                            }
                            extractor = e
                            codec = decoder
                            entry = texture
                            surface = display
                            currentPath = path
                            lastDecodedUs = -1
                            queuedEos = false
                            generation++
                            val session = generation
                            ui.post {
                                result.success(mapOf(
                                    "textureId" to texture.id(),
                                    "session" to session,
                                    "width" to width,
                                    "height" to height,
                                    "hardware" to (
                                        android.os.Build.VERSION.SDK_INT >= 29 &&
                                        decoder.codecInfo.isHardwareAccelerated
                                    )
                                ))
                            }
                        } catch (error: Exception) {
                            closeInternal()
                            ui.post {
                                result.error(
                                    "SCRUB_DECODER_UNAVAILABLE", error.message, null
                                )
                            }
                        }
                    }
                }
                "seek" -> {
                    val at = call.argument<Number>("timeMs")?.toLong()
                    if (at == null) {
                        result.error("NO_TIME", "Missing scrub timestamp", null)
                    } else {
                        desiredUs.set(at.coerceAtLeast(0) * 1000L)
                        scheduleDecode()
                        result.success(null)
                    }
                }
                "close" -> {
                    desiredUs.set(-1)
                    decode.post {
                        closeInternal()
                        ui.post { result.success(null) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun scheduleDecode() {
        if (!pumpScheduled.compareAndSet(false, true)) return
        decode.post {
            pumpScheduled.set(false)
            val requested = desiredUs.get()
            if (requested < 0 || codec == null || extractor == null) return@post
            val rendered = try {
                decodeToward(requested)
            } catch (error: Exception) {
                ui.post {
                    channel.invokeMethod(
                        "previewError", error.message ?: "Hardware frame decode failed"
                    )
                }
                desiredUs.set(-1)
                false
            }
            // Coalesce finger moves: do work for the newest position, not a
            // growing queue of stale timestamps. Continue unfinished GOP decode.
            if (desiredUs.get() >= 0 && (desiredUs.get() != requested || !rendered)) {
                scheduleDecode()
            }
        }
    }

    private fun decodeToward(targetUs: Long): Boolean {
        val media = extractor ?: return true
        val decoder = codec ?: return true
        if (lastDecodedUs < 0 || targetUs + 40_000 < lastDecodedUs ||
            targetUs - lastDecodedUs > 1_500_000) {
            media.seekTo(targetUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            decoder.flush()
            lastDecodedUs = -1
            queuedEos = false
        }
        val info = MediaCodec.BufferInfo()
        val deadline = SystemClock.uptimeMillis() + 100
        var decodedCount = 0
        while (SystemClock.uptimeMillis() < deadline && decodedCount < 120) {
            if (desiredUs.get() < 0) return true
            if (desiredUs.get() != targetUs && decodedCount > 4) return true
            if (!queuedEos) {
                val input = decoder.dequeueInputBuffer(1000)
                if (input >= 0) {
                    val inputBuffer = decoder.getInputBuffer(input)
                        ?: throw IllegalStateException("Decoder input unavailable")
                    inputBuffer.clear()
                    val amount = media.readSampleData(inputBuffer, 0)
                    if (amount < 0) {
                        decoder.queueInputBuffer(input, 0, 0, 0,
                            MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        queuedEos = true
                    } else {
                        val pts = media.sampleTime.coerceAtLeast(0)
                        decoder.queueInputBuffer(input, 0, amount, pts, 0)
                        media.advance()
                    }
                }
            }
            when (val output = decoder.dequeueOutputBuffer(info, 1000)) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> continue
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> continue
                else -> if (output >= 0) {
                    decodedCount++
                    val pts = info.presentationTimeUs
                    lastDecodedUs = pts
                    val eos = (info.flags and
                        MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    val render = (info.size > 0 && pts >= targetUs) || eos
                    decoder.releaseOutputBuffer(output, render)
                    if (render) {
                        val session = generation
                        ui.post {
                            channel.invokeMethod("frameReady",
                                mapOf("session" to session, "timeMs" to pts / 1000))
                        }
                        return true
                    }
                }
            }
        }
        return queuedEos && media.sampleTime < 0
    }

    private fun closeInternal() {
        desiredUs.set(-1)
        generation++
        try { codec?.stop() } catch (_: Exception) {}
        try { codec?.release() } catch (_: Exception) {}
        codec = null
        try { extractor?.release() } catch (_: Exception) {}
        extractor = null
        try { surface?.release() } catch (_: Exception) {}
        surface = null
        try { entry?.release() } catch (_: Exception) {}
        entry = null
        currentPath = null
        lastDecodedUs = -1
        queuedEos = false
    }

    override fun onDestroy() {
        if (::decode.isInitialized) {
            desiredUs.set(-1)
            decode.post {
                closeInternal()
                decodeThread.quitSafely()
            }
        }
        super.onDestroy()
    }
}
