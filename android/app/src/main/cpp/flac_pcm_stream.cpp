#include "flac_pcm_stream.h"

#include <algorithm>
#include <cstring>
#include <limits>

namespace sylvakru {

FlacResult FlacPcmStream::open(const std::string& path) {
    const auto result = decoder_.open(path);
    if (!result.ok()) return result;
    const auto& info = decoder_.streamInfo();
    sample_bytes_ = info.valid_bits_per_sample <= 16 ? 2 :
        (info.valid_bits_per_sample <= 24 ? 3 : 4);
    const uint32_t frame_bytes = info.channels * sample_bytes_;
    if (info.total_frames == 0 || info.total_frames >
        static_cast<uint64_t>(std::numeric_limits<int64_t>::max() - 80) / frame_bytes) {
        return {FlacError::kUnsupportedFormat, "FLAC sample count is unavailable."};
    }
    const uint64_t data_size = info.total_frames * frame_bytes;
    // RF64 保留长文件的 64 位长度；只生成 80 字节头，不落盘整首 PCM。
    header_.clear();
    auto text = [&](const char* value) {
        header_.insert(header_.end(), value, value + 4);
    };
    auto number = [&](uint64_t value, int bytes) {
        for (int index = 0; index < bytes; ++index) {
            header_.push_back(static_cast<uint8_t>(value >> (index * 8)));
        }
    };
    text("RF64"); number(0xffffffff, 4); text("WAVE");
    text("ds64"); number(28, 4);
    number(data_size + 72, 8); number(data_size, 8);
    number(info.total_frames, 8); number(0, 4);
    text("fmt "); number(16, 4); number(1, 2);
    number(info.channels, 2); number(info.sample_rate, 4);
    number(info.sample_rate * frame_bytes, 4);
    number(frame_bytes, 2); number(sample_bytes_ * 8, 2);
    text("data"); number(0xffffffff, 4);
    samples_.resize(4096 * info.channels);
    pcm_.clear();
    pcm_offset_ = 0;
    position_ = 0;
    decoded_frames_ = 0;
    size_ = static_cast<int64_t>(header_.size() + data_size);
    cancelled_.store(false);
    return {};
}

int64_t FlacPcmStream::read(char* output, uint64_t capacity) {
    if (cancelled_.load() || output == nullptr) return -1;
    if (capacity == 0 || position_ >= size_) return 0;
    if (position_ < static_cast<int64_t>(header_.size())) {
        const auto count = std::min<uint64_t>(capacity, header_.size() - position_);
        std::memcpy(output, header_.data() + position_, count);
        position_ += count;
        return count;
    }
    if (pcm_.empty() || pcm_offset_ == pcm_.size()) {
        // seek 可停在帧内；首次填充后跳过相应字节，后续按完整帧解码。
        const size_t skip = pcm_.empty() ? pcm_offset_ : 0;
        const auto decoded = decoder_.readFrames(samples_.data(), 4096);
        if (!decoded.ok()) return -1;
        if (decoded.frames == 0) return position_ == size_ ? 0 : -1;
        decoded_frames_ += decoded.frames;
        const auto& info = decoder_.streamInfo();
        const size_t count = decoded.frames * info.channels;
        pcm_.resize(count * sample_bytes_);
        const int shift = sample_bytes_ * 8 - info.valid_bits_per_sample;
        for (size_t index = 0; index < count; ++index) {
            // libFLAC 样本低位对齐；PCM 按容器位宽左对齐，避免高位深播放音量变小。
            const uint32_t value = static_cast<uint32_t>(samples_[index]) << shift;
            for (int byte = 0; byte < sample_bytes_; ++byte) {
                pcm_[index * sample_bytes_ + byte] = static_cast<uint8_t>(value >> (byte * 8));
            }
        }
        pcm_offset_ = skip;
    }
    const auto count = std::min<uint64_t>(
        std::min<uint64_t>(capacity, pcm_.size() - pcm_offset_), size_ - position_);
    std::memcpy(output, pcm_.data() + pcm_offset_, count);
    pcm_offset_ += count;
    position_ += count;
    return count;
}

int64_t FlacPcmStream::seek(int64_t offset) {
    if (cancelled_.load() || offset < 0 || offset > size_) return -1;
    if (offset == position_) return offset;
    const uint64_t data_offset = offset > static_cast<int64_t>(header_.size())
        ? offset - header_.size() : 0;
    const uint32_t frame_bytes = decoder_.streamInfo().channels * sample_bytes_;
    // libFLAC 不接受定位到总帧数，流末尾由长度直接判断。
    if (offset != size_ && !decoder_.seekToFrame(data_offset / frame_bytes).ok()) return -1;
    pcm_.clear();
    pcm_offset_ = data_offset % frame_bytes;
    position_ = offset;
    return offset;
}

}  // namespace sylvakru
