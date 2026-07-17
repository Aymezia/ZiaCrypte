// Backend Android du SecureKeyStore via JNI vers l'Android Keystore.
//
// ⚠️ NON COMPILÉ NI TESTÉ dans l'environnement de développement Linux : ce
// fichier ne se construit qu'avec le NDK Android et sera validé par le job
// Android de la CI matricielle (Phase 8).
//
// Particularité Android : l'Android Keystore N'A PAS d'API C dans le NDK — c'est
// une API exclusivement Java. Un backend natif DOIT donc passer par JNI vers un
// helper Java/Kotlin. Ce fichier attend une classe compagnon
//   com.ziacrypte.KeyStoreBridge
// fournie côté hôte Android de l'app Flutter (à écrire lors de l'intégration
// Flutter/Android), exposant trois méthodes statiques :
//   static boolean hasMasterKey()
//   static byte[]  generateMasterKey()   // AES Keystore non-exportable enveloppant 32 octets
//   static byte[]  loadMasterKey()
//   static boolean deleteMasterKey()
//
// La JavaVM est capturée dans JNI_OnLoad (motif NDK standard). Sans ce pont
// câblé, platform_key_store() renvoie un store qui échoue proprement (jamais de
// secret en clair, jamais de crash) — c'est la tâche d'intégration Android de la
// Phase 8 de fournir KeyStoreBridge.

#include "storage/secure_key_store.hpp"

#include <jni.h>
#include <cstring>

namespace zia::crypto::storage {
namespace {

JavaVM* g_jvm = nullptr;

JNIEnv* attach_env() {
    if (!g_jvm) return nullptr;
    JNIEnv* env = nullptr;
    if (g_jvm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) == JNI_OK) {
        return env;
    }
    return (g_jvm->AttachCurrentThread(&env, nullptr) == JNI_OK) ? env : nullptr;
}

jclass find_bridge(JNIEnv* env) {
    return env ? env->FindClass("com/ziacrypte/KeyStoreBridge") : nullptr;
}

class AndroidSecureKeyStore : public SecureKeyStore {
public:
    bool has_master_key() override {
        JNIEnv* env = attach_env();
        jclass cls = find_bridge(env);
        if (!cls) return false;
        jmethodID m = env->GetStaticMethodID(cls, "hasMasterKey", "()Z");
        return m && env->CallStaticBooleanMethod(cls, m) == JNI_TRUE;
    }

    bool generate_and_store_master_key(SecureBuffer& out_key) override {
        return call_returning_key("generateMasterKey", out_key);
    }

    bool load_master_key(SecureBuffer& out_key) override {
        return call_returning_key("loadMasterKey", out_key);
    }

    bool delete_master_key() override {
        JNIEnv* env = attach_env();
        jclass cls = find_bridge(env);
        if (!cls) return false;
        jmethodID m = env->GetStaticMethodID(cls, "deleteMasterKey", "()Z");
        return m && env->CallStaticBooleanMethod(cls, m) == JNI_TRUE;
    }

private:
    bool call_returning_key(const char* method, SecureBuffer& out_key) {
        JNIEnv* env = attach_env();
        jclass cls = find_bridge(env);
        if (!cls) return false;
        jmethodID m = env->GetStaticMethodID(cls, method, "()[B");
        if (!m) return false;

        auto bytes = reinterpret_cast<jbyteArray>(env->CallStaticObjectMethod(cls, m));
        if (!bytes) return false;

        jsize len = env->GetArrayLength(bytes);
        out_key = SecureBuffer(static_cast<size_t>(len));
        env->GetByteArrayRegion(bytes, 0, len, reinterpret_cast<jbyte*>(out_key.data()));
        // Efface la copie Java temporaire avant de la relâcher.
        jbyte zero = 0;
        for (jsize i = 0; i < len; ++i) env->SetByteArrayRegion(bytes, i, 1, &zero);
        env->DeleteLocalRef(bytes);
        return true;
    }
};

} // namespace

SecureKeyStore& platform_key_store() {
    static AndroidSecureKeyStore instance;
    return instance;
}

} // namespace zia::crypto::storage

// Capture de la JavaVM au chargement de la bibliothèque (motif NDK standard).
extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void*) {
    zia::crypto::storage::g_jvm = vm;
    return JNI_VERSION_1_6;
}
