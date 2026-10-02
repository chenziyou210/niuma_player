package cn.niuma.niuma_player

import java.io.ByteArrayInputStream
import java.io.IOException
import org.junit.Assert.*
import org.junit.Test

class AssetMediaDataSourceTest {
    @Test
    fun randomReadsRespectAssetBoundariesAndDestinationOffset() {
        // Simulates an asset occupying only a slice of the APK.
        val stream = ByteArrayInputStream(byteArrayOf(99, 10, 11, 12, 13, 88), 1, 4)
        val source = AssetMediaDataSource(stream)
        val buffer = ByteArray(4)
        assertEquals(2, source.readAt(2, buffer, 1, 2))
        assertArrayEquals(byteArrayOf(0, 12, 13, 0), buffer)
        assertEquals(4L, source.getSize())
        assertEquals(2, source.readAt(0, buffer, 0, 2))
        assertEquals(10.toByte(), buffer[0])
        assertEquals(11.toByte(), buffer[1])
        assertEquals(-1, source.readAt(4, buffer, 0, 1))
        assertEquals(0, source.readAt(4, buffer, 0, 0))
        source.close()
    }

    @Test
    fun partialAndZeroSkipsStillReachTheRequestedPosition() {
        val stream = object : ByteArrayInputStream(byteArrayOf(1, 2, 3, 4)) {
            override fun skip(n: Long): Long = 0L
        }
        val source = AssetMediaDataSource(stream)
        val buffer = ByteArray(1)
        assertEquals(1, source.readAt(3, buffer, 0, 1))
        assertEquals(4.toByte(), buffer[0])
        assertEquals(4L, source.getSize())
        assertEquals(1, source.readAt(1, buffer, 0, 1))
        assertEquals(2.toByte(), buffer[0])
        source.close()
    }

    @Test
    fun closeIsIdempotentAndRejectsFurtherReads() {
        var closeCalls = 0
        val stream = object : ByteArrayInputStream(byteArrayOf(1)) {
            override fun close() { closeCalls++ }
        }
        val source = AssetMediaDataSource(stream)
        source.close()
        source.close()
        assertEquals(1, closeCalls)
        assertThrows(IOException::class.java) { source.readAt(0, ByteArray(1), 0, 1) }
        assertThrows(IOException::class.java) { source.getSize() }
    }
}
