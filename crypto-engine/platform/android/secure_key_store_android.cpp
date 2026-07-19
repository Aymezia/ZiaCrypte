// Backend Android du SecureKeyStore, via JNI vers l'Android Keystore.
//
// L'Android Keystore n'a PAS d'API C dans le NDK : c'est une API exclusivement
// Java. Le moteur passe donc par la classe compagnon com.ziacrypte.KeyStoreBridge
// (fournie par l'hôte Android de l'application), qui garde une clé AES non
// exportable dans le Keystore matériel et s'en sert pour envelopper la clé
// maîtresse de 32 octets.

#include "storage/secure_key_store.hpp"

#include <jni.h>
#include <cstring>

namespace zia::crypto::storage {
namespace {

JavaVM* g_jvm = nullptr;
/* Référence globale sur la classe du pont. Elle DOIT être résolue depuis
 * JNI_OnLoad : un thread attaché plus tard (l'isolate Dart du moteur, par
 * exemple) utilise le chargeur de classes système, qui ne voit pas les classes
 * de l'application — FindClass y échouerait. */
jclass g_bridge_class = nullptr;

struct AttachedEnv {
  JNIEnv* env = nullptr;
  bool must_detach = false;

  AttachedEnv() {
    if (!g_jvm) return;
    if (g_jvm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) == JNI_OK) return;
    if (g_jvm->AttachCurrentThread(&env, nullptr) == JNI_OK) {
      must_detach = true;
    } else {
      env = nullptr;
    }
  }

  ~AttachedEnv() {
    if (must_detach && g_jvm) g_jvm->DetachCurrentThread();
  }

  bool ok() const { return env != nullptr && g_bridge_class != nullptr; }
};

/* Une exception Java laissée en attente ferait échouer tout appel JNI suivant. */
void clear_pending_exception(JNIEnv* env) {
  if (env->ExceptionCheck()) {
    env->ExceptionDescribe();
    env->ExceptionClear();
  }
}

class AndroidSecureKeyStore : public SecureKeyStore {
 public:
  bool has_master_key() override {
    AttachedEnv attached;
    if (!attached.ok()) return false;
    JNIEnv* env = attached.env;

    jmethodID method = env->GetStaticMethodID(g_bridge_class, "hasMasterKey", "()Z");
    if (!method) {
      clear_pending_exception(env);
      return false;
    }
    const bool result = env->CallStaticBooleanMethod(g_bridge_class, method) == JNI_TRUE;
    clear_pending_exception(env);
    return result;
  }

  bool generate_and_store_master_key(SecureBuffer& out_key) override {
    return call_returning_key("generateMasterKey", out_key);
  }

  bool load_master_key(SecureBuffer& out_key) override {
    return call_returning_key("loadMasterKey", out_key);
  }

  bool delete_master_key() override {
    AttachedEnv attached;
    if (!attached.ok()) return false;
    JNIEnv* env = attached.env;

    jmethodID method = env->GetStaticMethodID(g_bridge_class, "deleteMasterKey", "()Z");
    if (!method) {
      clear_pending_exception(env);
      return false;
    }
    const bool result = env->CallStaticBooleanMethod(g_bridge_class, method) == JNI_TRUE;
    clear_pending_exception(env);
    return result;
  }

 private:
  bool call_returning_key(const char* name, SecureBuffer& out_key) {
    AttachedEnv attached;
    if (!attached.ok()) return false;
    JNIEnv* env = attached.env;

    jmethodID method = env->GetStaticMethodID(g_bridge_class, name, "()[B");
    if (!method) {
      clear_pending_exception(env);
      return false;
    }

    auto bytes = reinterpret_cast<jbyteArray>(
        env->CallStaticObjectMethod(g_bridge_class, method));
    if (env->ExceptionCheck() || bytes == nullptr) {
      clear_pending_exception(env);
      return false;
    }

    const jsize length = env->GetArrayLength(bytes);
    out_key = SecureBuffer(static_cast<size_t>(length));
    env->GetByteArrayRegion(bytes, 0, length,
                            reinterpret_cast<jbyte*>(out_key.data()));

    // La copie Java de la clé est effacée avant d'être relâchée au ramasse-miettes.
    jbyte zero = 0;
    for (jsize i = 0; i < length; ++i) env->SetByteArrayRegion(bytes, i, 1, &zero);
    env->DeleteLocalRef(bytes);

    clear_pending_exception(env);
    return length > 0;
  }
};

} // namespace

SecureKeyStore& platform_key_store() {
  static AndroidSecureKeyStore instance;
  return instance;
}

} // namespace zia::crypto::storage

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void*) {
  zia::crypto::storage::g_jvm = vm;

  JNIEnv* env = nullptr;
  if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) == JNI_OK) {
    jclass local = env->FindClass("com/ziacrypte/KeyStoreBridge");
    if (local != nullptr) {
      zia::crypto::storage::g_bridge_class =
          reinterpret_cast<jclass>(env->NewGlobalRef(local));
      env->DeleteLocalRef(local);
    } else {
      // Sans le pont, le moteur reste utilisable : l'identité ne sera
      // simplement pas persistée (échec propre, jamais de secret en clair).
      env->ExceptionClear();
    }
  }
  return JNI_VERSION_1_6;
}
