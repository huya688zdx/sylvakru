#include "usb_volume_protocol.h"

#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

// 与 Kotlin UsbVolumeProtocolTest / UsbHardwareVolumeTest 中涉及下沉符号的
// 用例逐个对拍（用例名保持对应）。音量安全红线：所有断言必须逐数值/逐字节。

namespace {

using sylvakru::IbassoPacketRouteKind;
using sylvakru::IbassoReaderRecoveryAction;
using sylvakru::IbassoVolumeVerificationAction;

constexpr int kIntMin = INT32_MIN;
constexpr int kIntMax = INT32_MAX;

// 与 Kotlin 测试的 gainQ16ForIndex 一致：((index / 100.0)^1.5 * 65536).roundToInt()
int gainQ16ForIndex(int index) {
    return static_cast<int>(std::floor(std::pow(index / 100.0, 1.5) * 65536 + 0.5));
}

std::vector<uint8_t> ibassoEventPacket(int left_raw, int right_raw) {
    std::vector<uint8_t> packet(32, 0);
    packet[4] = 0xfe;
    packet[5] = 0x01;
    packet[8] = static_cast<uint8_t>(left_raw);
    packet[9] = static_cast<uint8_t>(right_raw);
    return packet;
}

std::vector<uint8_t> ibassoResponsePacket(int command, int value = 0) {
    std::vector<uint8_t> packet(32, 0);
    packet[6] = static_cast<uint8_t>(command);
    packet[7] = 1;
    packet[8] = static_cast<uint8_t>(value);
    return packet;
}

void selectsUsbSlotFromPcmSourceBitDepthInAutoMode() {
    const int source16 = 16;
    const int source20 = 20;
    const int source32 = 32;
    assert(sylvakru::preferredAutoPcmBitDepth(&source16, {16, 24, 32}) == 16);
    assert(sylvakru::preferredAutoPcmBitDepth(&source20, {16, 24, 32}) == 24);
    assert(sylvakru::preferredAutoPcmBitDepth(nullptr, {16, 24, 32}) == 24);
    // 无更宽槽位时选最大的较窄槽位，而非放弃偏好（放弃会错选 16-bit）
    assert(sylvakru::preferredAutoPcmBitDepth(&source32, {16, 24}) == 24);
    assert(sylvakru::preferredAutoPcmBitDepth(&source32, {}) == 0);
}

void combinesReplayGainIntoEffectiveLinearGainSafely() {
    assert(sylvakru::effectiveVolumeGainQ16(0, 6000) == 0);
    assert(sylvakru::effectiveVolumeGainQ16(65536, 6000) == 65536);
    assert(std::abs(sylvakru::effectiveVolumeGainQ16(65536, -6021) - 32768) <= 2);
    assert(sylvakru::effectiveVolumeGainQ16(65536, kIntMin) == 0);
    assert(sylvakru::effectiveVolumeGainQ16(1, kIntMax) == 65536);
}

void addsDsdCompensationOnlyToDsdHardwareVolume() {
    assert(std::abs(
        sylvakru::effectiveHardwareVolumeGainQ16(32768, 0, 6, true) - 65381) <= 2);
    assert(sylvakru::effectiveHardwareVolumeGainQ16(32768, 0, 6, false) == 32768);
    assert(sylvakru::effectiveHardwareVolumeGainQ16(0, kIntMax, 6, true) == 0);
}

void mapsAcousticGainToIbassoHardwareTable() {
    const int ninety_percent_gain = static_cast<int>(std::pow(0.9, 1.5) * 65536);
    assert(sylvakru::ibassoVolumeIndex(0) == 0);
    assert(sylvakru::ibassoVolumeIndex(ninety_percent_gain) == 90);
    assert(sylvakru::ibassoVolumeIndex(65536) == 100);
    assert(sylvakru::ibassoDeviceVolume(23) == 97);
    assert(sylvakru::ibassoDeviceVolume(90) == 10);
}

void appliesDsdCompensationInHalfDbHardwareSteps() {
    assert(sylvakru::ibassoDsdVolume(97, 6) == 85);
    assert(sylvakru::ibassoDsdVolume(97, -6) == 109);
    assert(sylvakru::ibassoDsdVolume(4, 6) == 0);
    assert(sylvakru::ibassoDsdVolume(250, -6) == 255);
}

void mapsAppGainToIbassoRawTable() {
    assert(sylvakru::ibassoAppGainToRaw(0, 0, 0).base_raw == 255);
    assert(sylvakru::ibassoAppGainToRaw(gainQ16ForIndex(23), 0, 0).base_raw == 97);
    assert(sylvakru::ibassoAppGainToRaw(gainQ16ForIndex(90), 0, 0).base_raw == 10);
    assert(sylvakru::ibassoAppGainToRaw(65536, 0, 0).base_raw == 0);
}

void keepsMuteAcrossDsdCompensation() {
    const auto muted_up = sylvakru::ibassoAppGainToRaw(0, 0, 6);
    assert(muted_up.base_raw == 255 && muted_up.dsd_raw == 255);
    const auto muted_down = sylvakru::ibassoAppGainToRaw(0, 0, -6);
    assert(muted_down.base_raw == 255 && muted_down.dsd_raw == 255);
}

void appliesReplayGainBeforeClampAndDsdHalfDbSteps() {
    const auto boosted = sylvakru::ibassoAppGainToRaw(gainQ16ForIndex(90), 6000, 0);
    assert(boosted.base_raw == 0 && boosted.dsd_raw == 0);
    const auto dsd_down = sylvakru::ibassoAppGainToRaw(gainQ16ForIndex(23), 0, 6);
    assert(dsd_down.base_raw == 97 && dsd_down.dsd_raw == 85);
    const auto dsd_up = sylvakru::ibassoAppGainToRaw(gainQ16ForIndex(23), 0, -6);
    assert(dsd_up.base_raw == 97 && dsd_up.dsd_raw == 109);
    const auto muted = sylvakru::ibassoAppGainToRaw(65536, kIntMin, 0);
    assert(muted.base_raw == 255 && muted.dsd_raw == 255);
    const auto full = sylvakru::ibassoAppGainToRaw(65536, kIntMax, 0);
    assert(full.base_raw == 0 && full.dsd_raw == 0);
}

void mapsRawTableValuesBackToLinearGain() {
    assert(sylvakru::ibassoRawToLinearGainQ16(255) == 0);
    assert(std::abs(sylvakru::ibassoRawToLinearGainQ16(97) - gainQ16ForIndex(23)) <= 1);
    assert(std::abs(sylvakru::ibassoRawToLinearGainQ16(10) - gainQ16ForIndex(90)) <= 1);
    assert(sylvakru::ibassoRawToLinearGainQ16(0) == 65536);
}

void decodesEndpointPrefixedAndLegacyUnsolicitedVolumeEvents() {
    const auto packet = ibassoEventPacket(97, 98);
    std::vector<uint8_t> legacy(16, 0);
    legacy[0] = 0xfe;
    legacy[1] = 0x01;
    legacy[8] = 97;
    legacy[9] = 98;

    const auto event = sylvakru::ibassoDecodeEvent(packet.data(), packet.size());
    assert(event.valid && event.left_raw == 97 && event.right_raw == 98);
    const auto legacy_event = sylvakru::ibassoDecodeEvent(legacy.data(), legacy.size());
    assert(legacy_event.valid && legacy_event.left_raw == 97 && legacy_event.right_raw == 98);
    assert(!sylvakru::ibassoDecodeEvent(packet.data(), 9).valid);

    std::vector<uint8_t> response(32, 0);
    response[6] = 65;
    response[8] = 97;
    assert(!sylvakru::ibassoDecodeEvent(response.data(), response.size()).valid);
}

void routesUnsolicitedEventsBeforeCommandResponses() {
    auto packet = ibassoEventPacket(97, 97);
    packet[6] = 65;

    const auto route = sylvakru::routeIbassoVolumePacket(packet.data(), packet.size(), {65});
    assert(route.kind == IbassoPacketRouteKind::kEvent);
    assert(route.left_raw == 97 && route.right_raw == 97);
}

void routesCommandResponsesAndKeepsTheirCommandId() {
    const auto matching_packet = ibassoResponsePacket(65);
    const auto matching =
        sylvakru::routeIbassoVolumePacket(matching_packet.data(), matching_packet.size(), {65});
    const auto wrong_packet = ibassoResponsePacket(64);
    const auto wrong_command =
        sylvakru::routeIbassoVolumePacket(wrong_packet.data(), wrong_packet.size(), {65});

    assert(matching.kind == IbassoPacketRouteKind::kCommandResponse);
    assert(matching.command == 65);
    assert(wrong_command.kind == IbassoPacketRouteKind::kCommandResponse);
    assert(wrong_command.command == 64);
}

void routesLateValidCommandResponsesWithoutReportingUnknownPackets() {
    const auto packet = ibassoResponsePacket(0, 120);
    const auto route = sylvakru::routeIbassoVolumePacket(packet.data(), packet.size(), {});
    assert(route.kind == IbassoPacketRouteKind::kCommandResponse);
    assert(route.command == 0);
}

void doesNotMistakeOrdinaryResponsesForEvents() {
    const auto packet = ibassoResponsePacket(19);
    const auto route = sylvakru::routeIbassoVolumePacket(packet.data(), packet.size(), {19});
    assert(route.kind == IbassoPacketRouteKind::kCommandResponse);
}

void classifiesStereoEventsAndUnknownPackets() {
    const auto event_packet = ibassoEventPacket(97, 98);
    const auto event =
        sylvakru::routeIbassoVolumePacket(event_packet.data(), event_packet.size(), {});
    assert(event.kind == IbassoPacketRouteKind::kEvent);

    const uint8_t tiny[] = {0x01};
    const auto unknown = sylvakru::routeIbassoVolumePacket(tiny, 1, {});
    assert(unknown.kind == IbassoPacketRouteKind::kUnknown);
}

void verifiesIbassoWriteBeforeChangingHardwareAuthority() {
    const int previous = 102;
    const int readback_target = 100;
    const int readback_previous = 102;
    assert(sylvakru::ibassoVolumeVerificationAction(
        100, &previous, &readback_target, 1, false, false, nullptr, nullptr) ==
        IbassoVolumeVerificationAction::kAcceptTarget);
    assert(sylvakru::ibassoVolumeVerificationAction(
        100, &previous, &readback_previous, 1, false, false, nullptr, nullptr) ==
        IbassoVolumeVerificationAction::kKeepPrevious);
    assert(sylvakru::ibassoVolumeVerificationAction(
        100, &previous, nullptr, 1, false, false, nullptr, nullptr) ==
        IbassoVolumeVerificationAction::kRetryReadback);
    assert(sylvakru::ibassoVolumeVerificationAction(
        100, &previous, nullptr, 3, false, false, nullptr, nullptr) ==
        IbassoVolumeVerificationAction::kFreezePcm);
    assert(sylvakru::ibassoVolumeVerificationAction(
        100, &previous, nullptr, 3, true, false, nullptr, nullptr) ==
        IbassoVolumeVerificationAction::kPauseDsd);
}

void freezesDsdAtTheTrustedTargetOnlyWhenBothRegistersDoNotRise() {
    const int previous = 102;
    const int previous_dsd = 100;
    const int target_dsd_lower = 102;
    const int target_dsd_higher = 98;
    // 衰减寄存器增大才是降低音量，先用设备音量表校验测试方向。
    assert(sylvakru::ibassoRawToLinearGainQ16(104) <
        sylvakru::ibassoRawToLinearGainQ16(previous));
    assert(sylvakru::ibassoRawToLinearGainQ16(target_dsd_lower) <
        sylvakru::ibassoRawToLinearGainQ16(previous_dsd));
    assert(sylvakru::ibassoVolumeVerificationAction(
        104, &previous, nullptr, 3, true, false, &target_dsd_lower, &previous_dsd) ==
        IbassoVolumeVerificationAction::kFreezeDsd);
    assert(sylvakru::ibassoVolumeVerificationAction(
        100, &previous, nullptr, 3, true, false, &target_dsd_higher, &previous_dsd) ==
        IbassoVolumeVerificationAction::kPauseDsd);
    assert(sylvakru::ibassoVolumeVerificationAction(
        104, &previous, nullptr, 3, true, false, &target_dsd_higher, &previous_dsd) ==
        IbassoVolumeVerificationAction::kPauseDsd);
    assert(sylvakru::ibassoVolumeVerificationAction(
        100, nullptr, nullptr, 3, true, false, &target_dsd_lower, nullptr) ==
        IbassoVolumeVerificationAction::kPauseDsd);
}

void yieldsVerificationToAPendingRequestInsteadOfFreezing() {
    const int previous = 102;
    const int readback_target = 100;
    assert(sylvakru::ibassoVolumeVerificationAction(
        100, &previous, nullptr, 3, false, true, nullptr, nullptr) ==
        IbassoVolumeVerificationAction::kYieldToPending);
    assert(sylvakru::ibassoVolumeVerificationAction(
        100, &previous, nullptr, 3, true, true, nullptr, nullptr) ==
        IbassoVolumeVerificationAction::kYieldToPending);
    // 读回成功匹配时照常接受，不受挂起请求影响
    assert(sylvakru::ibassoVolumeVerificationAction(
        100, &previous, &readback_target, 3, false, true, nullptr, nullptr) ==
        IbassoVolumeVerificationAction::kAcceptTarget);
}

void waitsForPcmReaderRestartWithoutVerifyingOrFreezing() {
    assert(sylvakru::ibassoReaderRecoveryAction(
        false, /*write_only=*/false, /*restart_requested=*/true,
        /*reader_running=*/false, /*generation_matches=*/true, /*wait_expired=*/false) ==
        IbassoReaderRecoveryAction::kWait);
}

void verifiesPcmAsSoonAsTheRestartedReaderIsReady() {
    // Kotlin: IbassoReaderHealth().afterFailure().afterRestart()
    // → restartRequested=false、writeOnly=false
    assert(sylvakru::ibassoReaderRecoveryAction(
        false, false, false, /*reader_running=*/true, true, false) ==
        IbassoReaderRecoveryAction::kVerifyNow);
}

void freezesPcmWhenReaderRecoveryExpiresOrBecomesWriteOnly() {
    assert(sylvakru::ibassoReaderRecoveryAction(
        false, false, /*restart_requested=*/true, false, true, /*wait_expired=*/true) ==
        IbassoReaderRecoveryAction::kFreezePcm);
    assert(sylvakru::ibassoReaderRecoveryAction(
        false, /*write_only=*/true, false, false, true, false) ==
        IbassoReaderRecoveryAction::kFreezePcm);
}

void waitsForDsdReaderRestartThenVerifiesWithoutFreezingPcm() {
    assert(sylvakru::ibassoReaderRecoveryAction(
        true, false, /*restart_requested=*/true, false, true, false) ==
        IbassoReaderRecoveryAction::kWait);
    assert(sylvakru::ibassoReaderRecoveryAction(
        true, false, false, /*reader_running=*/true, true, false) ==
        IbassoReaderRecoveryAction::kVerifyNow);
    // 超时后 DSD 仍是 VERIFY_NOW（走严格验证结局），不得落到 FREEZE_PCM
    assert(sylvakru::ibassoReaderRecoveryAction(
        true, false, /*restart_requested=*/true, false, true, /*wait_expired=*/true) ==
        IbassoReaderRecoveryAction::kVerifyNow);
    assert(sylvakru::ibassoReaderRecoveryAction(
        false, false, /*restart_requested=*/true, false, /*generation_matches=*/false, false) ==
        IbassoReaderRecoveryAction::kCancel);
}

void waitsForIbassoSettleAndLatestPendingQuietWindow() {
    assert(sylvakru::ibassoVolumePendingDelayMs(1000, false, 0, 1050) == 100);
    assert(sylvakru::ibassoVolumePendingDelayMs(1000, true, 1100, 1200) == 200);
    assert(sylvakru::ibassoVolumePendingDelayMs(1000, true, 1100, 1350) == 50);
    assert(sylvakru::ibassoVolumePendingDelayMs(1000, true, 1100, 1400) == 0);
}

void buildsIbassoI2cVolumePacket() {
    uint8_t packet[16];
    sylvakru::ibassoI2cWritePacket(1, 0x60, 9, 1, 97, packet);
    const uint8_t expected[16] = {1, 0x11, 0x88, 0x60, 0, 0, 5, 9, 0, 1, 0, 97, 0, 0, 0, 0};
    assert(std::memcmp(packet, expected, 16) == 0);
}

void keepsRoomAndReadPacketByteLayout() {
    uint8_t room[16];
    sylvakru::ibassoRoomWritePacket(19, 16, 97, room);
    const uint8_t expected_room[16] =
        {19, 0x11, 0xa0, 0xa2, 0, 16, 1, 97, 0, 0, 0, 0, 0, 0, 0, 0};
    assert(std::memcmp(room, expected_room, 16) == 0);

    uint8_t read[16];
    sylvakru::ibassoVolumeReadPacket(read);
    const uint8_t expected_read[16] =
        {65, 0x12, 0xe4, 0xa2, 0, 0x11, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    assert(std::memcmp(read, expected_read, 16) == 0);
}

void buildsCompleteIbassoTargetAndRollbackPacketGroups() {
    const int expected_commands[10] = {1, 2, 3, 4, 9, 10, 19, 11, 12, 20};

    const auto check_group = [&](const sylvakru::IbassoVolumeTarget& target,
                                 const int expected_values[10]) {
        const auto packets = sylvakru::ibassoVolumePackets(target);
        assert(packets.size() == 10);
        for (int index = 0; index < 10; ++index) {
            assert(static_cast<int>(packets[index].size()) == 16);
            const int command = packets[index][0];
            assert(command == expected_commands[index]);
            const int value_offset = (command == 19 || command == 20) ? 7 : 11;
            assert(packets[index][value_offset] == expected_values[index]);
        }
    };

    const int target_values[10] = {97, 97, 97, 97, 85, 85, 97, 85, 85, 97};
    check_group({97, 85}, target_values);

    // 回滚目标（对应 Kotlin ibassoRollbackTarget(null, 109, 6)）：base=109、dsd=97
    assert(sylvakru::ibassoDsdVolume(109, 6) == 97);
    const int rollback_values[10] = {109, 109, 109, 109, 97, 97, 109, 97, 97, 109};
    check_group({109, 97}, rollback_values);
}

void mapsIbassoBaseRawToCurrentPcmOrDsdGain() {
    const auto pcm = sylvakru::ibassoActualEventGainQ16(97, false, 6);
    assert(pcm.raw == 97);
    assert(pcm.gain_q16 == sylvakru::ibassoRawToLinearGainQ16(97));
    const auto dsd = sylvakru::ibassoActualEventGainQ16(97, true, 6);
    assert(dsd.raw == 85);
    assert(dsd.gain_q16 == sylvakru::ibassoRawToLinearGainQ16(85));
}

void unsolicitedIbassoEventBecomesTrustedTarget() {
    const auto target = sylvakru::ibassoTargetFromEvent(97, 6);
    assert(target.base_raw == 97 && target.dsd_raw == 85);
}

}  // namespace

int main() {
#define RUN(test)                         \
    do {                                  \
        std::fprintf(stderr, #test "\n"); \
        test();                           \
    } while (false)
    RUN(selectsUsbSlotFromPcmSourceBitDepthInAutoMode);
    RUN(combinesReplayGainIntoEffectiveLinearGainSafely);
    RUN(addsDsdCompensationOnlyToDsdHardwareVolume);
    RUN(mapsAcousticGainToIbassoHardwareTable);
    RUN(appliesDsdCompensationInHalfDbHardwareSteps);
    RUN(mapsAppGainToIbassoRawTable);
    RUN(keepsMuteAcrossDsdCompensation);
    RUN(appliesReplayGainBeforeClampAndDsdHalfDbSteps);
    RUN(mapsRawTableValuesBackToLinearGain);
    RUN(decodesEndpointPrefixedAndLegacyUnsolicitedVolumeEvents);
    RUN(routesUnsolicitedEventsBeforeCommandResponses);
    RUN(routesCommandResponsesAndKeepsTheirCommandId);
    RUN(routesLateValidCommandResponsesWithoutReportingUnknownPackets);
    RUN(doesNotMistakeOrdinaryResponsesForEvents);
    RUN(classifiesStereoEventsAndUnknownPackets);
    RUN(verifiesIbassoWriteBeforeChangingHardwareAuthority);
    RUN(freezesDsdAtTheTrustedTargetOnlyWhenBothRegistersDoNotRise);
    RUN(yieldsVerificationToAPendingRequestInsteadOfFreezing);
    RUN(waitsForPcmReaderRestartWithoutVerifyingOrFreezing);
    RUN(verifiesPcmAsSoonAsTheRestartedReaderIsReady);
    RUN(freezesPcmWhenReaderRecoveryExpiresOrBecomesWriteOnly);
    RUN(waitsForDsdReaderRestartThenVerifiesWithoutFreezingPcm);
    RUN(waitsForIbassoSettleAndLatestPendingQuietWindow);
    RUN(buildsIbassoI2cVolumePacket);
    RUN(keepsRoomAndReadPacketByteLayout);
    RUN(buildsCompleteIbassoTargetAndRollbackPacketGroups);
    RUN(mapsIbassoBaseRawToCurrentPcmOrDsdGain);
    RUN(unsolicitedIbassoEventBecomesTrustedTarget);
#undef RUN
    std::fprintf(stderr, "all tests passed\n");
    return 0;
}
