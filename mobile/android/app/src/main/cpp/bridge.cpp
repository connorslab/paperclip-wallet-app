#include <jni.h>
#include <array>
#include <string>
#include <cstring>

extern "C" char* paperclip_mobile_call(const char*, const unsigned char*);
extern "C" void paperclip_mobile_free(char*);

// Use byte arrays: JNI's modified UTF-8 strings are not Rust UTF-8.
extern "C" JNIEXPORT jbyteArray JNICALL
Java_xyz_paperclip_wallet_NativeBridge_call(JNIEnv* env, jobject, jbyteArray input, jbyteArray key) {
    if (!input || !key || env->GetArrayLength(key) != 64 ||
        env->GetArrayLength(input) >= 48 * 1024 * 1024) {
        env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"), "Invalid wallet request");
        return nullptr;
    }
    std::string request(env->GetArrayLength(input), '\0');
    env->GetByteArrayRegion(input, 0, request.size(), reinterpret_cast<jbyte*>(request.data()));
    if (env->ExceptionCheck()) return nullptr;
    if (request.find('\0') != std::string::npos) {
        env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"), "NUL in wallet request");
        return nullptr;
    }
    std::array<unsigned char, 64> seed{};
    env->GetByteArrayRegion(key, 0, seed.size(), reinterpret_cast<jbyte*>(seed.data()));
    if (env->ExceptionCheck()) return nullptr;
    char* result = paperclip_mobile_call(request.c_str(), seed.data());
    volatile unsigned char* wipe = seed.data();
    for (size_t i = 0; i < seed.size(); ++i) wipe[i] = 0;
    if (!result) {
        env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), "Native wallet returned no result");
        return nullptr;
    }
    auto length = static_cast<jsize>(std::strlen(result));
    auto output = env->NewByteArray(length);
    if (output) env->SetByteArrayRegion(output, 0, length, reinterpret_cast<jbyte*>(result));
    paperclip_mobile_free(result);
    return output;
}
