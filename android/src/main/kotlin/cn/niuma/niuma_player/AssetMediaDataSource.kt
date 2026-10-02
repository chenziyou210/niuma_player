package cn.niuma.niuma_player

import java.io.IOException
import java.io.InputStream
import tv.danmaku.ijk.media.player.misc.IMediaDataSource

/** Seekable IJK adapter for AssetManager streams, including compressed assets.
 * AssetInputStream implements mark/reset/skip with asset-relative native seeks.
 * Never expose the APK's file descriptor: its offsets belong to the whole APK.
 */
internal class AssetMediaDataSource(private val input: InputStream) : IMediaDataSource {
    private var position = 0L
    private var length: Long? = null
    private var closed = false

    init {
        require(input.markSupported()) { "Asset stream must support reset" }
        input.mark(Int.MAX_VALUE)
    }

    @Synchronized
    override fun readAt(target: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        ensureOpen()
        require(target >= 0 && offset >= 0 && size >= 0 && offset <= buffer.size - size)
        if (size == 0) return 0
        if (target < position) {
            input.reset()
            position = 0L
        }
        while (position < target) {
            val skipped = input.skip(target - position)
            if (skipped > 0) {
                position += skipped
            } else {
                if (input.read() == -1) return -1
                position++
            }
        }
        val count = input.read(buffer, offset, size)
        if (count > 0) position += count
        return count
    }

    @Synchronized
    override fun getSize(): Long {
        ensureOpen()
        length?.let { return it }
        // available() is capped at Int.MAX_VALUE. Seek to EOF to retain long
        // lengths; AssetInputStream.skip uses native seek, not a Java copy loop.
        while (true) {
            position += input.skip(Long.MAX_VALUE - position)
            if (input.read() == -1) break
            position++
        }
        val result = position
        input.reset()
        position = 0L
        length = result
        return result
    }

    @Synchronized
    override fun close() {
        if (closed) return
        closed = true
        input.close()
    }

    private fun ensureOpen() {
        if (closed) throw IOException("Asset media data source is closed")
    }
}
