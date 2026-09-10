// UsbFlacNative 的 JNI 边界：把 FlacDecoder 以不透明句柄暴露给 Kotlin。
// USB 解码器由 create/destroy 单线程管理；普通播放的输入流由 mpv 回调管理。
#include <jni.h>
#include <android/log.h>
#include <dlfcn.h>

#include <cstdint>
#include <string>

#include "flac_decoder.h"
#include "flac_pcm_stream.h"

namespace {

// 除解码器本体外，记录最近一次 readFrames 的错误与流结束状态，
// 避免 JNI 返回值里同时打包帧数/错误/EOS 三种信息。
struct FlacHandle {
    sylvakru::FlacDecoder decoder;
    std::string last_error;
    bool end_of_stream = false;
};

FlacHandle* fromHandle(jlong handle) {
    return reinterpret_cast<FlacHandle*>(handle);
}

jstring nullableError(JNIEnv* env, const std::string& message) {
    if (message.empty()) {
        return nullptr;
    }
    return env->NewStringUTF(message.c_str());
}

}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_afalphy_sylvakru_UsbFlacNative_create(JNIEnv*, jobject) {
    return reinterpret_cast<jlong>(new FlacHandle());
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_afalphy_sylvakru_UsbFlacNative_open(
    JNIEnv* env,
    jobject,
    jlong handle,
    jstring path) {
    auto* holder = fromHandle(handle);
    if (holder == nullptr || path == nullptr) {
        return nullableError(env, "Invalid FLAC decoder handle.");
    }
    const char* path_chars = env->GetStringUTFChars(path, nullptr);
    if (path_chars == nullptr) {
        return nullableError(env, "Failed to read FLAC path.");
    }
    const auto result = holder->decoder.open(path_chars);
    env->ReleaseStringUTFChars(path, path_chars);
    holder->end_of_stream = false;
    holder->last_error.clear();
    return nullableError(env, result.ok() ? std::string() : result.message);
}

extern "C" JNIEXPORT jlongArray JNICALL
Java_com_afalphy_sylvakru_UsbFlacNative_streamInfo(
    JNIEnv* env,
    jobject,
    jlong handle) {
    auto* holder = fromHandle(handle);
    jlong values[4] = {0, 0, 0, 0};
    if (holder != nullptr) {
        const auto& info = holder->decoder.streamInfo();
        values[0] = static_cast<jlong>(info.sample_rate);
        values[1] = static_cast<jlong>(info.channels);
        values[2] = static_cast<jlong>(info.valid_bits_per_sample);
        values[3] = static_cast<jlong>(info.total_frames);
    }
    jlongArray result = env->NewLongArray(4);
    if (result != nullptr) {
        env->SetLongArrayRegion(result, 0, 4, values);
    }
    return result;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_afalphy_sylvakru_UsbFlacNative_readFrames(
    JNIEnv* env,
    jobject,
    jlong handle,
    jobject buffer,
    jint capacity_frames) {
    auto* holder = fromHandle(handle);
    if (holder == nullptr) {
        return -1;
    }
    if (buffer == nullptr || capacity_frames <= 0) {
        holder->last_error = "FLAC target buffer is invalid.";
        return -1;
    }
    auto* output = static_cast<int32_t*>(env->GetDirectBufferAddress(buffer));
    const jlong capacity_bytes = env->GetDirectBufferCapacity(buffer);
    const auto& info = holder->decoder.streamInfo();
    const jlong required_bytes = static_cast<jlong>(capacity_frames) *
        info.channels * static_cast<jlong>(sizeof(int32_t));
    if (output == nullptr || capacity_bytes < required_bytes) {
        holder->last_error = "FLAC target buffer is not a large enough direct buffer.";
        return -1;
    }
    const auto read = holder->decoder.readFrames(
        output,
        static_cast<uint32_t>(capacity_frames));
    if (!read.ok()) {
        holder->last_error = read.message;
        return -1;
    }
    holder->end_of_stream = read.end_of_stream;
    holder->last_error.clear();
    return static_cast<jint>(read.frames);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_afalphy_sylvakru_UsbFlacNative_endOfStream(
    JNIEnv*,
    jobject,
    jlong handle) {
    auto* holder = fromHandle(handle);
    return (holder != nullptr && holder->end_of_stream) ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_afalphy_sylvakru_UsbFlacNative_lastError(
    JNIEnv* env,
    jobject,
    jlong handle) {
    auto* holder = fromHandle(handle);
    if (holder == nullptr) {
        return nullableError(env, "Invalid FLAC decoder handle.");
    }
    return nullableError(env, holder->last_error);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_afalphy_sylvakru_UsbFlacNative_seekToFrame(
    JNIEnv* env,
    jobject,
    jlong handle,
    jlong frame) {
    auto* holder = fromHandle(handle);
    if (holder == nullptr || frame < 0) {
        return nullableError(env, "Invalid FLAC decoder handle.");
    }
    const auto result = holder->decoder.seekToFrame(static_cast<uint64_t>(frame));
    if (result.ok()) {
        holder->end_of_stream = false;
        return nullptr;
    }
    return nullableError(env, result.message);
}

extern "C" JNIEXPORT void JNICALL
Java_com_afalphy_sylvakru_UsbFlacNative_destroy(
    JNIEnv*,
    jobject,
    jlong handle) {
    delete fromHandle(handle);
}

namespace {

// mpv stream_cb.h 的公开 ABI；通过已有 libmpv 动态符号注册，避免再链接一份播放器。
// 字段顺序对应 https://github.com/mpv-player/mpv/blob/v0.41.0/include/mpv/stream_cb.h
struct MpvStreamInfo {
    void* cookie;
    int64_t (*read_fn)(void*, char*, uint64_t);
    int64_t (*seek_fn)(void*, int64_t);
    int64_t (*size_fn)(void*);
    void (*close_fn)(void*);
    void (*cancel_fn)(void*);
};

constexpr const char* flac_protocol = "sylvakru-flac";

std::string sharedFlacPath(const char* uri) {
    const std::string prefix = std::string(flac_protocol) + "://";
    const std::string value(uri);
    if (value.compare(0, prefix.size(), prefix) != 0) return {};
    std::string path;
    auto hex = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        return -1;
    };
    for (size_t index = prefix.size(); index < value.size(); ++index) {
        char c = value[index];
        if (c == '%') {
            if (index + 2 >= value.size()) return {};
            const int high = hex(value[index + 1]);
            const int low = hex(value[index + 2]);
            if (high < 0 || low < 0) return {};
            c = static_cast<char>((high << 4) | low);
            index += 2;
        }
        if (c == '\0') return {};
        path += c;
    }
    return !path.empty() && path.front() == '/' ? path : std::string();
}

int openSharedFlac(void*, char* uri, MpvStreamInfo* info) {
    auto* stream = new sylvakru::FlacPcmStream();
    const auto opened = stream->open(sharedFlacPath(uri));
    if (!opened.ok()) {
        __android_log_print(ANDROID_LOG_WARN, "SylvakruFlac", "Open failed: %s", opened.message.c_str());
        delete stream;
        return -13; // MPV_ERROR_LOADING_FAILED
    }
    const auto& source = stream->streamInfo();
    __android_log_print(ANDROID_LOG_INFO, "SylvakruFlac",
        "Shared playback decoder=libFLAC source=%uHz/%ubit channels=%u",
        source.sample_rate, source.valid_bits_per_sample, source.channels);
    info->cookie = stream;
    info->read_fn = [](void* cookie, char* buffer, uint64_t size) {
        return static_cast<sylvakru::FlacPcmStream*>(cookie)->read(buffer, size);
    };
    info->seek_fn = [](void* cookie, int64_t offset) {
        return static_cast<sylvakru::FlacPcmStream*>(cookie)->seek(offset);
    };
    info->size_fn = [](void* cookie) { return static_cast<sylvakru::FlacPcmStream*>(cookie)->size(); };
    info->close_fn = [](void* cookie) { delete static_cast<sylvakru::FlacPcmStream*>(cookie); };
    info->cancel_fn = [](void* cookie) { static_cast<sylvakru::FlacPcmStream*>(cookie)->cancel(); };
    return 0;
}

}  // namespace

extern "C" JNIEXPORT jboolean JNICALL
Java_com_afalphy_sylvakru_UsbFlacNative_prepareSharedPlayback(
    JNIEnv* env, jobject, jlong player_handle, jstring uri) {
    if (player_handle == 0 || uri == nullptr) return JNI_FALSE;
    const char* chars = env->GetStringUTFChars(uri, nullptr);
    if (chars == nullptr) return JNI_FALSE;
    const std::string path = sharedFlacPath(chars);
    env->ReleaseStringUTFChars(uri, chars);
    sylvakru::FlacPcmStream probe;
    if (path.empty() || !probe.open(path).ok()) return JNI_FALSE;

    // 库在播放器整个生命周期内保持加载，回调由 mpv 自己关闭和释放。
    static void* mpv = dlopen("libmpv.so", RTLD_NOW | RTLD_LOCAL);
    using RegisterStream = int (*)(void*, const char*, void*, decltype(&openSharedFlac));
    static auto register_stream = mpv == nullptr ? nullptr :
        reinterpret_cast<RegisterStream>(dlsym(mpv, "mpv_stream_cb_add_ro"));
    if (register_stream == nullptr) return JNI_FALSE;
    const int result = register_stream(reinterpret_cast<void*>(player_handle), flac_protocol, nullptr, openSharedFlac);
    // 固定协议重复注册时 mpv 返回 INVALID_PARAMETER，既有回调仍然有效。
    return result == 0 || result == -4 ? JNI_TRUE : JNI_FALSE;
}
