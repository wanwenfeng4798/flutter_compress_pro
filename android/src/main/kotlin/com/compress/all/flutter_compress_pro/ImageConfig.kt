package com.compress.all.flutter_compress_pro

/** Parsed mirror of the Dart [ImageCompressConfig]. */
data class ImageConfig(
    /** Requested output format, or null to keep the source's. */
    val format: String?,
    val quality: Int,
    val targetSizeKB: Int?,
    val maxWidth: Int?,
    val maxHeight: Int?,
    val keepExif: Boolean,
    val lossless: Boolean,
    val keepOriginalIfLarger: Boolean,
    val minSavingsPercent: Int,
) {
    fun validate() {
        if (quality !in 1..100 || minSavingsPercent !in 0..99 ||
            listOf(targetSizeKB, maxWidth, maxHeight).any { it != null && it <= 0 } ||
            format?.let { it !in listOf("jpeg", "png", "webp", "heic") } == true
        ) {
            throw BadArgumentException("Invalid image configuration")
        }
    }

    companion object {
        fun fromMap(m: Map<String, Any?>) = ImageConfig(
            format = m["format"] as? String,
            quality = (m["quality"] as? Number)?.toInt() ?: 85,
            targetSizeKB = (m["targetSizeKB"] as? Number)?.toInt(),
            maxWidth = (m["maxWidth"] as? Number)?.toInt(),
            maxHeight = (m["maxHeight"] as? Number)?.toInt(),
            keepExif = m["keepExif"] as? Boolean ?: false,
            lossless = m["lossless"] as? Boolean ?: false,
            keepOriginalIfLarger = m["keepOriginalIfLarger"] as? Boolean ?: true,
            minSavingsPercent = (m["minSavingsPercent"] as? Number)?.toInt() ?: 0,
        ).also { it.validate() }
    }
}
