package com.afalphy.sylvakru

import java.io.IOException
import java.nio.ByteBuffer

/** libFLAC 的 USB 解码器 JNI 入口及普通播放输入注册。 */
internal object UsbFlacNative {
    init {
        System.loadLibrary("sylvakru_usb_exclusive")
    }

    external fun create(): Long

    external fun open(handle: Long, path: String): String?

    external fun streamInfo(handle: Long): LongArray

    external fun readFrames(handle: Long, buffer: ByteBuffer, capacityFrames: Int): Int

    external fun endOfStream(handle: Long): Boolean

    external fun lastError(handle: Long): String?

    external fun seekToFrame(handle: Long, frame: Long): String?

    external fun destroy(handle: Long)

    external fun prepareSharedPlayback(playerHandle: Long, uri: String): Boolean
}

/**
 * 完整本地 FLAC 文件的原生解码器：绕开系统 MediaCodec，用 libFLAC 输出
 * 交错 S32LE 容器并保留源文件真实有效位深（16/20/24/32），解决部分厂商
 * 解码链路把 24-bit FLAC 压成 16-bit PCM 的问题。
 *
 * 仅供 USB 独占解码线程单线程使用。open 失败抛 [IOException]；
 * 读到流结尾后 [readFrames] 返回 -1；close 可重复调用。
 */
class UsbFlacDecoder private constructor(
    private var handle: Long,
    override val sampleRate: Int,
    override val channels: Int,
    override val validBitsPerSample: Int,
    override val totalFrames: Long,
) : UsbNativePcmDecoder {
    /**
     * 解码最多 [capacityFrames] 帧到 [buffer]（必须是容量足够的 direct buffer，
     * 每帧 channels × 4 字节）。返回写入帧数；流已结束且无数据可读时返回 -1；
     * 解码失败抛 [IOException]，调用方不得静默回退从头播放。
     */
    override fun readFrames(buffer: ByteBuffer, capacityFrames: Int): Int {
        check(handle != 0L) { "UsbFlacDecoder 已关闭" }
        val frames = UsbFlacNative.readFrames(handle, buffer, capacityFrames)
        if (frames < 0) {
            throw IOException(UsbFlacNative.lastError(handle) ?: "FLAC 解码失败")
        }
        if (frames == 0 && UsbFlacNative.endOfStream(handle)) {
            return -1
        }
        return frames
    }

    /** 定位到绝对帧位置；失败抛 [IOException]，解码器状态保持可继续使用。 */
    override fun seekToFrame(frame: Long) {
        check(handle != 0L) { "UsbFlacDecoder 已关闭" }
        val error = UsbFlacNative.seekToFrame(handle, frame)
        if (error != null) {
            throw IOException(error)
        }
    }

    override fun close() {
        if (handle != 0L) {
            UsbFlacNative.destroy(handle)
            handle = 0L
        }
    }

    companion object {
        /** 交错输出容器固定为 S32LE，每样本 4 字节。 */
        const val BYTES_PER_SAMPLE = Int.SIZE_BYTES

        /** 打开完整本地 FLAC 文件；文件缺失、非 FLAC 或格式不支持时抛 [IOException]。 */
        fun open(path: String): UsbFlacDecoder {
            val handle = UsbFlacNative.create()
            val error = UsbFlacNative.open(handle, path)
            if (error != null) {
                UsbFlacNative.destroy(handle)
                throw IOException(error)
            }
            val info = UsbFlacNative.streamInfo(handle)
            val decoder = UsbFlacDecoder(
                handle = handle,
                sampleRate = info[0].toInt(),
                channels = info[1].toInt(),
                validBitsPerSample = info[2].toInt(),
                totalFrames = info[3],
            )
            if (decoder.sampleRate <= 0 || decoder.channels <= 0) {
                decoder.close()
                throw IOException("FLAC 流信息无效")
            }
            return decoder
        }
    }
}
