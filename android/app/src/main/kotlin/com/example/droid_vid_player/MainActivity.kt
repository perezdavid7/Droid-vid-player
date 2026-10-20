package com.example.droid_vid_player

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Native, dedicated scrub-frame retriever.
 *
 * ExoPlayer remains responsible for full-quality sound/video playback.
 * During a finger drag, Flutter can request an individually decoded frame
 * without waiting for ExoPlayer to reposition its playback timeline.
 *
 * All retriever work is serialized on one worker thread. The Dart side
 * coalesces movement so a fast-moving finger cannot queue old frames.
 */
class MainActivity : FlutterActivity() {
    private val mainThread = Handler(Looper.getMainLooper())
    private val channelName = "droid_vid_player/frame_preview"
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()
    private var retriever: MediaMetadataRetriever? = null
    private var source: String? = null
    private var targetWidth: Int = 960
    private var targetHeight: Int = 540

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "open" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("BAD_SOURCE", "No video file path", null)
                            return@setMethodCallHandler
                        }
                        worker.execute {
                            try {
                                retriever?.release()
                                retriever = null
                                source = null
                                val media = MediaMetadataRetriever()
                                media.setDataSource(path)
                                val width = media.extractMetadata(
                                    MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH
                                )?.toIntOrNull() ?: 960
                                val height = media.extractMetadata(
                                    MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT
                                )?.toIntOrNull() ?: 540
                                val scale = minOf(1.0, 960.0 / maxOf(1, width))
                                targetWidth = maxOf(2, ((width * scale).toInt() / 2) * 2)
                                targetHeight = maxOf(2, ((height * scale).toInt() / 2) * 2)
                                retriever = media
                                source = path
                                mainThread.post { result.success(true) }
                            } catch (ex: Exception) {
                                retriever?.release()
                                retriever = null
                                source = null
                                mainThread.post { result.error("FRAME_OPEN_FAILED", ex.message, null) }
                            }
                        }
                    }

                    "frame" -> {
                        val ms = call.argument<Number>("timeMs")?.toLong()
                        val path = call.argument<String>("path")
                        if (ms == null || path.isNullOrEmpty()) {
                            result.error("BAD_FRAME", "Time or source missing", null)
                            return@setMethodCallHandler
                        }
                        worker.execute {
                            val media = retriever
                            if (media == null || source != path) {
                                mainThread.post { result.error("NOT_READY", "Frame decoder unavailable", null) }
                                return@execute
                            }
                            var bitmap: Bitmap? = null
                            try {
                                val us = maxOf(0, ms) * 1000L
                                bitmap = if (Build.VERSION.SDK_INT >= 27) {
                                    media.getScaledFrameAtTime(
                                        us,
                                        MediaMetadataRetriever.OPTION_CLOSEST,
                                        targetWidth,
                                        targetHeight
                                    )
                                } else {
                                    media.getFrameAtTime(
                                        us, MediaMetadataRetriever.OPTION_CLOSEST
                                    )
                                }
                                if (bitmap == null) {
                                    mainThread.post { result.error("NO_FRAME", "No frame decoded at $ms ms", null) }
                                } else {
                                    val out = ByteArrayOutputStream(96 * 1024)
                                    bitmap.compress(Bitmap.CompressFormat.JPEG, 83, out)
                                    val encoded = out.toByteArray()
                                    mainThread.post { result.success(encoded) }
                                }
                            } catch (ex: Exception) {
                                mainThread.post { result.error("FRAME_FAILED", ex.message, null) }
                            } finally {
                                bitmap?.recycle()
                            }
                        }
                    }

                    "close" -> worker.execute {
                        try {
                            retriever?.release()
                            retriever = null
                            source = null
                            mainThread.post { result.success(null) }
                        } catch (ex: Exception) {
                            mainThread.post { result.error("FRAME_CLOSE_FAILED", ex.message, null) }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        worker.execute {
            retriever?.release()
            retriever = null
            source = null
        }
        worker.shutdown()
        super.onDestroy()
    }
}
