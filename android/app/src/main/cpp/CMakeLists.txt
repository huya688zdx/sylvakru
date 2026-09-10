cmake_minimum_required(VERSION 3.22.1)

project(sylvakru_usb_exclusive)

set(BUILD_CXXLIBS OFF CACHE BOOL "" FORCE)
set(BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(BUILD_DOCS OFF CACHE BOOL "" FORCE)
set(BUILD_UTILS OFF CACHE BOOL "" FORCE)
set(WITH_OGG OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(INSTALL_MANPAGES OFF CACHE BOOL "" FORCE)
set(INSTALL_PKGCONFIG_MODULES OFF CACHE BOOL "" FORCE)
set(INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
if(ANDROID)
    # libFLAC 1.5.0 会在部分 32 位 Android CMake 配置中误判 API 级别；
    # 本应用 minSdk=26，fseeko/ftello 在所有受支持设备上均可用。
    set(HAVE_FSEEKO 1 CACHE INTERNAL "" FORCE)
endif()
add_subdirectory(
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../third_party/flac-1.5.0
    ${CMAKE_CURRENT_BINARY_DIR}/flac
    EXCLUDE_FROM_ALL
)
if(ANDROID AND CMAKE_SYSTEM_PROCESSOR MATCHES "armv7-a|i686")
    target_compile_definitions(FLAC PRIVATE HAVE_FSEEKO)
endif()

# libwavpack：只编解码库，不编 CLI/安装件；DSD 支持关闭（DSD .wv 打开
# 直接失败，上层回退共享输出），legacy(<4.0) 文件同样不支持
set(WAVPACK_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(WAVPACK_ENABLE_LEGACY OFF CACHE BOOL "" FORCE)
set(WAVPACK_ENABLE_DSD OFF CACHE BOOL "" FORCE)
set(WAVPACK_ENABLE_LIBICONV OFF CACHE BOOL "" FORCE)
set(WAVPACK_INSTALL_CMAKE_MODULE OFF CACHE BOOL "" FORCE)
set(WAVPACK_INSTALL_DOCS OFF CACHE BOOL "" FORCE)
set(WAVPACK_INSTALL_PKGCONFIG_MODULE OFF CACHE BOOL "" FORCE)
add_subdirectory(
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../third_party/wavpack-5.9.0
    ${CMAKE_CURRENT_BINARY_DIR}/wavpack
    EXCLUDE_FROM_ALL
)

add_library(
    sylvakru_flac_decoder
    STATIC
    flac_decoder.cpp
    flac_pcm_stream.cpp
)
target_include_directories(sylvakru_flac_decoder PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(sylvakru_flac_decoder PUBLIC FLAC::FLAC)

add_library(
    sylvakru_wavpack_decoder
    STATIC
    wavpack_decoder.cpp
)
target_include_directories(sylvakru_wavpack_decoder PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(sylvakru_wavpack_decoder PUBLIC WavPack::WavPack)

# DSD 容器解析与 DoP/Native 打包：平台无关纯逻辑，从 Kotlin UsbDsd.kt 下沉，
# 供 Android JNI 与未来桌面独占实现共同复用
add_library(
    sylvakru_usb_dsd
    STATIC
    usb_dsd.cpp
)
target_include_directories(sylvakru_usb_dsd PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

# UAC 原始描述符解析（AS 格式/时钟源/Feature Unit 音量/输出端子源）：
# 从引擎 Kotlin 私有函数下沉的平台无关纯逻辑
add_library(
    sylvakru_usb_uac
    STATIC
    usb_uac.cpp
)
target_include_directories(sylvakru_usb_uac PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

# DAC quirk 键匹配与位完美混音采样率选择：从 UsbDacQuirks/UsbPreferredMixer
# 下沉的平台无关纯逻辑（quirk JSON 装载仍在 Kotlin）
add_library(
    sylvakru_usb_dac_quirks
    STATIC
    usb_dac_quirks.cpp
)
target_include_directories(sylvakru_usb_dac_quirks PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

# iBasso HID 音量协议纯逻辑（增益换算/音量表/HID 报文/验证决策）：
# 从 UsbVolumeProtocol.kt 下沉；会话策略胶水仍在 Kotlin。音量安全红线：
# 任何数值行为改动必须先过 usb_volume_protocol_test 对拍
add_library(
    sylvakru_usb_volume_protocol
    STATIC
    usb_volume_protocol.cpp
)
target_include_directories(sylvakru_usb_volume_protocol PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

# PCM 分包器纯计算核心（槽位/位深转换、数字音量、淡入淡出、反馈包长状态机）：
# 从引擎 PcmIsoPacketizer 下沉；线程/缓冲/URB 节奏仍在 Kotlin。
# 音量安全红线：数字音量数值行为改动必须先过 usb_pcm_packetizer_test 对拍
add_library(
    sylvakru_usb_pcm_packetizer
    STATIC
    usb_pcm_packetizer.cpp
)
target_include_directories(sylvakru_usb_pcm_packetizer PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

if(ANDROID)
    add_library(
        sylvakru_usb_exclusive
        SHARED
        usb_exclusive_engine.cpp
        flac_decoder_jni.cpp
        wavpack_decoder_jni.cpp
        usb_dsd_jni.cpp
        usb_uac_jni.cpp
        usb_dac_quirks_jni.cpp
        usb_volume_protocol_jni.cpp
        usb_pcm_packetizer_jni.cpp
    )

    find_library(log-lib log)

    target_link_libraries(
        sylvakru_usb_exclusive
        sylvakru_flac_decoder
        sylvakru_wavpack_decoder
        sylvakru_usb_dsd
        sylvakru_usb_uac
        sylvakru_usb_dac_quirks
        sylvakru_usb_volume_protocol
        sylvakru_usb_pcm_packetizer
        ${log-lib}
        ${CMAKE_DL_LIBS}
    )
endif()

option(SYLVAKRU_BUILD_HOST_TESTS "Build Sylvakru native host tests" OFF)
set(
    SYLVAKRU_FLAC_TESTDATA_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/testdata"
    CACHE STRING
    "Sylvakru FLAC 测试 fixture 目录（设备上运行时覆盖为设备路径）"
)
if(SYLVAKRU_BUILD_HOST_TESTS)
    add_executable(flac_decoder_test tests/flac_decoder_test.cpp)
    target_compile_definitions(
        flac_decoder_test
        PRIVATE SYLVAKRU_FLAC_TESTDATA_DIR="${SYLVAKRU_FLAC_TESTDATA_DIR}"
    )
    target_link_libraries(flac_decoder_test PRIVATE sylvakru_flac_decoder)

    # WavPack 测试不需要 fixture：用 libwavpack 编码 API 现场生成再往返验证
    add_executable(wavpack_decoder_test tests/wavpack_decoder_test.cpp)
    target_link_libraries(wavpack_decoder_test PRIVATE sylvakru_wavpack_decoder)

    # 音量协议测试：对拍 Kotlin 侧全部涉及下沉符号的用例（音量安全红线）
    add_executable(usb_volume_protocol_test tests/usb_volume_protocol_test.cpp)
    target_link_libraries(usb_volume_protocol_test PRIVATE sylvakru_usb_volume_protocol)

    # DSD 测试不需要 fixture：运行时手工构造最小 DSF/DFF 文件与 Kotlin 版对拍
    add_executable(usb_dsd_test tests/usb_dsd_test.cpp)
    target_link_libraries(usb_dsd_test PRIVATE sylvakru_usb_dsd)

    # UAC 描述符测试：手工构造 UAC1/UAC2 描述符片段对拍
    add_executable(usb_uac_test tests/usb_uac_test.cpp)
    target_link_libraries(usb_uac_test PRIVATE sylvakru_usb_uac)

    # PCM 分包器核心测试：对拍 Kotlin 转换/增益/淡入/包长语义（含 DoP 透传红线）
    add_executable(usb_pcm_packetizer_test tests/usb_pcm_packetizer_test.cpp)
    target_link_libraries(usb_pcm_packetizer_test PRIVATE sylvakru_usb_pcm_packetizer)

    # quirk 键匹配/采样率选择测试：对拍 Kotlin 匹配用例
    add_executable(usb_dac_quirks_test tests/usb_dac_quirks_test.cpp)
    target_link_libraries(usb_dac_quirks_test PRIVATE sylvakru_usb_dac_quirks)
endif()
