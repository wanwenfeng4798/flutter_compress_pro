package com.compress.all.flutter_compress_pro

import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import java.io.File

/** Reads source video metadata. Kept separate so it can be reused (e.g. by a
 * future image pipeline) and unit-reasoned about on its own. */
object MediaProbe {
    fun videoInfo(path: String): Map<String, Any?> {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(path)
            val rotation = r.int(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
            val (width, height) = displaySize(
                r.int(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH),
                r.int(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT),
                rotation,
            )
            return mapOf(
                "path" to path,
                "width" to width,
                "height" to height,
                "durationMs" to r.long(MediaMetadataRetriever.METADATA_KEY_DURATION),
                "sizeBytes" to File(path).length(),
                "bitrateKbps" to r.int(MediaMetadataRetriever.METADATA_KEY_BITRATE) / 1000,
                "frameRate" to r.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE,
                )?.toDoubleOrNull(),
                "codec" to codec(path),
                "hasAudio" to (r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes"),
                "rotation" to rotation,
            )
        } finally {
            r.release()
        }
    }

    /** Displayed size: the retriever reports coded dimensions, but Media3 applies
     * effects after rotation, so a 90/270 source must be measured swapped. */
    internal fun displaySize(width: Int, height: Int, rotation: Int): Pair<Int, Int> =
        if (rotation == 90 || rotation == 270) height to width else width to height

    private fun codec(path: String): String? {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(path)
            (0 until extractor.trackCount).mapNotNull { extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME) }
                .firstOrNull { it.startsWith("video/") }?.let {
                    if (it.contains("hevc")) "h265" else if (it.contains("avc")) "h264" else it
                }
        } finally { extractor.release() }
    }

    private fun MediaMetadataRetriever.int(key: Int) = extractMetadata(key)?.toIntOrNull() ?: 0
    private fun MediaMetadataRetriever.long(key: Int) = extractMetadata(key)?.toLongOrNull() ?: 0L
}
