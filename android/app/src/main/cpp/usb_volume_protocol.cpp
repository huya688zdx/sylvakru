#include "usb_volume_protocol.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace sylvakru {

namespace {

// 与 Kotlin Double.roundToInt()（Math.round：floor(x+0.5)，.5 向正无穷）一致
int roundToIntKotlin(double value) {
    return static_cast<int>(std::floor(value + 0.5));
}

int clampInt(int value, int low, int high) {
    return std::min(std::max(value, low), high);
}

// 设备音量表（255=静音，0=最大），101 项；下标即感知刻度
constexpr int kIbassoVolumeTable[] = {
    255, 155, 150, 145, 140, 135, 130, 125, 120, 115, 110, 109, 108, 107, 106, 105,
    104, 103, 102, 101, 100, 99, 98, 97, 96, 95, 94, 93, 92, 91, 90, 88, 86, 84,
    82, 80, 78, 76, 74, 72, 70, 68, 66, 64, 62, 60, 58, 56, 54, 52, 50, 49, 48,
    47, 46, 45, 44, 43, 42, 41, 40, 39, 38, 37, 36, 35, 34, 33, 32, 31, 30, 29,
    28, 27, 26, 25, 24, 23, 22, 21, 20, 19, 18, 17, 16, 15, 14, 13, 12, 11, 10,
    9, 8, 7, 6, 5, 4, 3, 2, 1, 0,
};
constexpr int kIbassoVolumeTableSize =
    static_cast<int>(sizeof(kIbassoVolumeTable) / sizeof(kIbassoVolumeTable[0]));
static_assert(kIbassoVolumeTableSize == 101, "iBasso volume table must have 101 entries");

constexpr int kIbassoEventMinPacketSize = 10;

}  // namespace

int preferredAutoPcmBitDepth(
    const int* source_bit_depth,
    const std::vector<int>& available_bit_depths) {
    // 保序去重并过滤非正值（与 Kotlin filter+distinct 一致）
    std::vector<int> available;
    for (const int depth : available_bit_depths) {
        if (depth > 0 &&
            std::find(available.begin(), available.end(), depth) == available.end()) {
            available.push_back(depth);
        }
    }
    if (source_bit_depth == nullptr) {
        for (const int preferred : {24, 32, 16}) {
            if (std::find(available.begin(), available.end(), preferred) != available.end()) {
                return preferred;
            }
        }
        return available.empty() ? 0 : *std::min_element(available.begin(), available.end());
    }
    if (std::find(available.begin(), available.end(), *source_bit_depth) != available.end()) {
        return *source_bit_depth;
    }
    int result = 0;
    for (const int depth : available) {
        if (depth > *source_bit_depth && (result == 0 || depth < result)) {
            result = depth;
        }
    }
    if (result != 0) {
        return result;
    }
    // 无精确匹配也无更宽槽位（如 32-bit 源、DAC 最高 24-bit）：退而选最大的较窄
    // 槽位，避免调用方落回“最小字节数优先”的候选排序错选 16-bit
    for (const int depth : available) {
        if (depth < *source_bit_depth && depth > result) {
            result = depth;
        }
    }
    return result;
}

int effectiveVolumeGainQ16(int user_gain_q16, int replay_gain_milli_db) {
    const int user_gain = clampInt(user_gain_q16, 0, kIbassoUnityGainQ16);
    if (user_gain == 0) {
        return 0;
    }
    const double factor = std::pow(10.0, replay_gain_milli_db / 20000.0);
    const double adjusted = user_gain * factor;
    if (std::isnan(adjusted) || adjusted <= 0) {
        return 0;
    }
    if (!std::isfinite(adjusted) || adjusted >= kIbassoUnityGainQ16) {
        return kIbassoUnityGainQ16;
    }
    return roundToIntKotlin(adjusted);
}

int effectiveHardwareVolumeGainQ16(
    int user_gain_q16,
    int replay_gain_milli_db,
    int dsd_compensation_db,
    bool is_dsd) {
    const int64_t combined =
        static_cast<int64_t>(replay_gain_milli_db) +
        (is_dsd ? static_cast<int64_t>(dsd_compensation_db) * 1000 : 0);
    const int combined_milli_db = static_cast<int>(std::min<int64_t>(
        std::max<int64_t>(combined, INT32_MIN), INT32_MAX));
    return effectiveVolumeGainQ16(user_gain_q16, combined_milli_db);
}

int ibassoVolumeIndex(int gain_q16) {
    if (gain_q16 <= 0) {
        return 0;
    }
    const double digital_gain =
        static_cast<double>(std::min(gain_q16, kIbassoUnityGainQ16)) / kIbassoUnityGainQ16;
    return clampInt(
        roundToIntKotlin(std::pow(digital_gain, 2.0 / 3.0) * (kIbassoVolumeTableSize - 1)),
        0,
        kIbassoVolumeTableSize - 1);
}

int ibassoDeviceVolume(int index) {
    return kIbassoVolumeTable[clampInt(index, 0, kIbassoVolumeTableSize - 1)];
}

int ibassoDsdVolume(int base_volume, int compensation_db) {
    return clampInt(base_volume - clampInt(compensation_db, -12, 6) * 2, 0, 255);
}

IbassoVolumeTarget ibassoAppGainToRaw(
    int gain_q16,
    int replay_gain_milli_db,
    int dsd_compensation_db) {
    const int adjusted_gain = effectiveVolumeGainQ16(gain_q16, replay_gain_milli_db);
    if (adjusted_gain <= 0) {
        return {255, 255};
    }
    const int base_raw = ibassoDeviceVolume(ibassoVolumeIndex(adjusted_gain));
    return {base_raw, ibassoDsdVolume(base_raw, dsd_compensation_db)};
}

int ibassoRawToLinearGainQ16(int raw) {
    const int clamped = clampInt(raw, 0, 255);
    // 取最接近值的下标；并列取靠前者（与 Kotlin minByOrNull 一致）
    int best_index = 0;
    int best_distance = std::abs(kIbassoVolumeTable[0] - clamped);
    for (int index = 1; index < kIbassoVolumeTableSize; ++index) {
        const int distance = std::abs(kIbassoVolumeTable[index] - clamped);
        if (distance < best_distance) {
            best_distance = distance;
            best_index = index;
        }
    }
    return clampInt(
        roundToIntKotlin(
            std::pow(
                static_cast<double>(best_index) / (kIbassoVolumeTableSize - 1), 1.5) *
            kIbassoUnityGainQ16),
        0,
        kIbassoUnityGainQ16);
}

IbassoVolumeEvent ibassoDecodeEvent(const uint8_t* packet, size_t size) {
    IbassoVolumeEvent event;
    if (packet == nullptr || size < kIbassoEventMinPacketSize) {
        return event;
    }
    const bool endpoint_prefixed = packet[4] == 0xfe && packet[5] == 0x01;
    const bool legacy = packet[0] == 0xfe && packet[1] == 0x01;
    if (!endpoint_prefixed && !legacy) {
        return event;
    }
    event.valid = true;
    event.left_raw = packet[8];
    event.right_raw = packet[9];
    return event;
}

namespace {

// 自识别响应包：[7] 为负载长度且不越界时，[6] 是命令号
int ibassoResponseCommand(const uint8_t* packet, size_t size, bool* found) {
    *found = false;
    if (size <= 8) {
        return 0;
    }
    const int payload_length = packet[7];
    if (payload_length > static_cast<int>(size) - 8) {
        return 0;
    }
    *found = true;
    return packet[6];
}

}  // namespace

IbassoPacketRoute routeIbassoVolumePacket(
    const uint8_t* packet,
    size_t size,
    const std::vector<int>& pending_commands) {
    IbassoPacketRoute route;
    const IbassoVolumeEvent event = ibassoDecodeEvent(packet, size);
    if (event.valid) {
        route.kind = IbassoPacketRouteKind::kEvent;
        route.left_raw = event.left_raw;
        route.right_raw = event.right_raw;
        return route;
    }
    bool has_pending_command = false;
    int command = 0;
    if (size > 6) {
        command = packet[6];
        has_pending_command =
            std::find(pending_commands.begin(), pending_commands.end(), command) !=
            pending_commands.end();
    }
    if (has_pending_command) {
        route.kind = IbassoPacketRouteKind::kCommandResponse;
        route.command = command;
        return route;
    }
    bool found = false;
    const int response_command = ibassoResponseCommand(packet, size, &found);
    if (found) {
        route.kind = IbassoPacketRouteKind::kCommandResponse;
        route.command = response_command;
    }
    return route;
}

void ibassoI2cWritePacket(
    int command, int slave, int offset, int byte_offset, int value, uint8_t out[16]) {
    std::memset(out, 0, 16);
    out[0] = static_cast<uint8_t>(command);
    out[1] = 0x11;
    out[2] = 0x88;
    out[3] = static_cast<uint8_t>(slave);
    out[6] = 5;
    out[7] = static_cast<uint8_t>(offset);
    out[9] = static_cast<uint8_t>(byte_offset);
    out[11] = static_cast<uint8_t>(value);
}

void ibassoRoomWritePacket(int command, int register_id, int value, uint8_t out[16]) {
    std::memset(out, 0, 16);
    out[0] = static_cast<uint8_t>(command);
    out[1] = 0x11;
    out[2] = 0xa0;
    out[3] = 0xa2;
    out[5] = static_cast<uint8_t>(register_id);
    out[6] = 1;
    out[7] = static_cast<uint8_t>(value);
}

void ibassoVolumeReadPacket(uint8_t out[16]) {
    std::memset(out, 0, 16);
    out[0] = 65;
    out[1] = 0x12;
    out[2] = 0xe4;
    out[3] = 0xa2;
    out[5] = 0x11;
    out[6] = 1;
}

std::vector<std::vector<uint8_t>> ibassoVolumePackets(const IbassoVolumeTarget& target) {
    std::vector<std::vector<uint8_t>> packets;
    packets.reserve(10);
    uint8_t buffer[16];
    const auto push_i2c = [&](int command, int slave, int offset, int byte_offset, int value) {
        ibassoI2cWritePacket(command, slave, offset, byte_offset, value, buffer);
        packets.emplace_back(buffer, buffer + 16);
    };
    const auto push_room = [&](int command, int register_id, int value) {
        ibassoRoomWritePacket(command, register_id, value, buffer);
        packets.emplace_back(buffer, buffer + 16);
    };
    push_i2c(1, 0x60, 9, 1, target.base_raw);
    push_i2c(2, 0x60, 9, 2, target.base_raw);
    push_i2c(3, 0x62, 9, 1, target.base_raw);
    push_i2c(4, 0x62, 9, 2, target.base_raw);
    push_i2c(9, 0x60, 7, 0, target.dsd_raw);
    push_i2c(10, 0x60, 7, 1, target.dsd_raw);
    push_room(19, 16, target.base_raw);
    push_i2c(11, 0x62, 7, 0, target.dsd_raw);
    push_i2c(12, 0x62, 7, 1, target.dsd_raw);
    push_room(20, 17, target.base_raw);
    return packets;
}

IbassoVolumeVerificationAction ibassoVolumeVerificationAction(
    int target_raw,
    const int* previous_raw,
    const int* readback_raw,
    int failure_count,
    bool is_dsd,
    bool has_pending_request,
    const int* target_dsd_raw,
    const int* previous_dsd_raw) {
    if (readback_raw != nullptr && *readback_raw == target_raw) {
        return IbassoVolumeVerificationAction::kAcceptTarget;
    }
    if (previous_raw != nullptr && readback_raw != nullptr && *readback_raw == *previous_raw) {
        return IbassoVolumeVerificationAction::kKeepPrevious;
    }
    if (failure_count < 3) {
        return IbassoVolumeVerificationAction::kRetryReadback;
    }
    // 还有挂起的音量请求＝用户仍在连续调音量：读回失败多半是 HID 忙不过来，
    // 马上会有下一个事务重写覆盖，让位而不是冻结/暂停触发保护。
    if (has_pending_request) {
        return IbassoVolumeVerificationAction::kYieldToPending;
    }
    // DSD 无数字兜底，但本会话已有可信硬件值且两个寄存器目标都只降不升时，
    // 已发出的写入即使生效也只会更小声：冻结在可信值上继续播放，不再暂停；
    // 任一寄存器要升（含 DSD 增益补偿变化导致）仍严格暂停。
    // 衰减寄存器越大越小声，两个目标都不得小于可信旧值。
    if (is_dsd && previous_raw != nullptr && target_raw >= *previous_raw &&
        target_dsd_raw != nullptr && previous_dsd_raw != nullptr &&
        *target_dsd_raw >= *previous_dsd_raw) {
        return IbassoVolumeVerificationAction::kFreezeDsd;
    }
    if (is_dsd) {
        return IbassoVolumeVerificationAction::kPauseDsd;
    }
    return IbassoVolumeVerificationAction::kFreezePcm;
}

IbassoReaderRecoveryAction ibassoReaderRecoveryAction(
    bool is_dsd,
    bool health_write_only,
    bool health_restart_requested,
    bool reader_running,
    bool generation_matches,
    bool wait_expired) {
    if (!generation_matches) {
        return IbassoReaderRecoveryAction::kCancel;
    }
    // DSD 同样等待有界的 reader 重启：Macaron 切到 native DSD alt 后 HID 有
    // 数百 ms 失聪期，reader 重启中立刻验证必然瞬间 3 连败触发安全门拒启动。
    // 等待超时后仍 VERIFY_NOW 走严格的 DSD 验证结局，绝不落到 FREEZE_PCM。
    if (is_dsd && (wait_expired || (reader_running && !health_restart_requested))) {
        return IbassoReaderRecoveryAction::kVerifyNow;
    }
    if (is_dsd) {
        return IbassoReaderRecoveryAction::kWait;
    }
    if (health_write_only) {
        return IbassoReaderRecoveryAction::kFreezePcm;
    }
    if (reader_running && !health_restart_requested) {
        return IbassoReaderRecoveryAction::kVerifyNow;
    }
    if (wait_expired) {
        return IbassoReaderRecoveryAction::kFreezePcm;
    }
    return IbassoReaderRecoveryAction::kWait;
}

int64_t ibassoVolumePendingDelayMs(
    int64_t last_completed_at_ms,
    bool has_pending_updated_at,
    int64_t pending_updated_at_ms,
    int64_t now_ms) {
    constexpr int64_t kSettleMs = 150;
    constexpr int64_t kPendingQuietMs = 300;
    const int64_t settle_elapsed_ms = std::max<int64_t>(now_ms - last_completed_at_ms, 0);
    const int64_t settle_delay_ms = std::max<int64_t>(kSettleMs - settle_elapsed_ms, 0);
    int64_t quiet_delay_ms = 0;
    if (has_pending_updated_at) {
        const int64_t quiet_elapsed_ms = std::max<int64_t>(now_ms - pending_updated_at_ms, 0);
        quiet_delay_ms = std::max<int64_t>(kPendingQuietMs - quiet_elapsed_ms, 0);
    }
    return std::max(settle_delay_ms, quiet_delay_ms);
}

IbassoActualVolume ibassoActualEventGainQ16(
    int base_raw,
    bool is_dsd,
    int dsd_compensation_db) {
    const int actual_raw = is_dsd
        ? ibassoDsdVolume(base_raw, dsd_compensation_db)
        : clampInt(base_raw, 0, 255);
    return {actual_raw, ibassoRawToLinearGainQ16(actual_raw)};
}

IbassoVolumeTarget ibassoTargetFromEvent(int base_raw, int dsd_compensation_db) {
    // 与 Kotlin 一致：DSD 寄存器按未钳位的 baseRaw 推导（内部结果自会钳位）
    return {clampInt(base_raw, 0, 255), ibassoDsdVolume(base_raw, dsd_compensation_db)};
}

}  // namespace sylvakru
