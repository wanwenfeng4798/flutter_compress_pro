package com.compress.all.flutter_compress_pro

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class FrameRateCapTest {
    @Test
    fun capBelowSourceApplies() {
        assertTrue(CompressionEngine.shouldCapFrameRate(24.0, 30.0))
    }

    @Test
    fun capAtOrAboveSourceNeverRaisesRate() {
        assertFalse(CompressionEngine.shouldCapFrameRate(30.0, 30.0))
        assertFalse(CompressionEngine.shouldCapFrameRate(60.0, 30.0))
    }

    @Test
    fun noCapMeansNoEffect() {
        assertFalse(CompressionEngine.shouldCapFrameRate(null, 30.0))
    }

    @Test
    fun unknownSourceRateStillAppliesTheCap() {
        assertTrue(CompressionEngine.shouldCapFrameRate(24.0, null))
    }

    @Test
    fun rotatedSourceReportsDisplayedSize() {
        assertEquals(1080 to 1920, MediaProbe.displaySize(1920, 1080, 90))
        assertEquals(1080 to 1920, MediaProbe.displaySize(1920, 1080, 270))
        assertEquals(1920 to 1080, MediaProbe.displaySize(1920, 1080, 0))
        assertEquals(1920 to 1080, MediaProbe.displaySize(1920, 1080, 180))
    }
}
