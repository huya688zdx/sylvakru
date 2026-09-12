#pragma once

#include "flac_decoder.h"

#include <atomic>
#include <vector>

namespace sylvakru {

// 将 libFLAC 的有效样本按需呈现为可定位的 RF64 PCM 输入，播放控制仍归 mpv。
class FlacPcmStream {
public:
    FlacResult open(const std::string& path);
    int64_t read(char* output, uint64_t capacity);
    int64_t seek(int64_t offset);
    int64_t size() const { return size_; }
    int pcmContainerBits() const { return sample_bytes_ * 8; }
    uint64_t decodedFrames() const { return decoded_frames_; }
    void cancel() { cancelled_.store(true); }
    const FlacStreamInfo& streamInfo() const { return decoder_.streamInfo(); }

private:
    FlacDecoder decoder_;
    std::vector<uint8_t> header_;
    std::vector<int32_t> samples_;
    std::vector<uint8_t> pcm_;
    size_t pcm_offset_ = 0;
    int sample_bytes_ = 0;
    int64_t position_ = 0;
    int64_t size_ = 0;
    uint64_t decoded_frames_ = 0;
    std::atomic<bool> cancelled_{false};
};

}  // namespace sylvakru
