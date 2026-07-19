package com.ziacrypte

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Coffre-fort Android pour la clé maîtresse du moteur cryptographique.
 *
 * L'Android Keystore n'expose aucune API C dans le NDK : le moteur natif appelle
 * donc ces méthodes par JNI. Le motif est le même que sur les autres plateformes
 * (DPAPI, Keychain, Secret Service) : une clé AES **non exportable** vit dans le
 * Keystore matériel et sert uniquement à envelopper la clé maîtresse de 32
 * octets, qui est stockée chiffrée dans les préférences de l'application.
 *
 * La clé AES ne peut pas être extraite de l'appareil, même root : sans elle, le
 * fichier chiffré est inexploitable.
 */
object KeyStoreBridge {

    private const val KEYSTORE = "AndroidKeyStore"
    private const val KEY_ALIAS = "ziacrypte_master_wrapper"
    private const val PREFS = "ziacrypte_secure"
    private const val PREF_ENTRY = "master_key"
    private const val MASTER_KEY_SIZE = 32
    private const val GCM_TAG_BITS = 128
    private const val GCM_IV_SIZE = 12

    private lateinit var appContext: Context

    /** Appelé par MainActivity : le pont a besoin d'un contexte applicatif. */
    @JvmStatic
    fun init(context: Context) {
        appContext = context.applicationContext
    }

    @JvmStatic
    fun hasMasterKey(): Boolean = runCatching {
        prefs().contains(PREF_ENTRY)
    }.getOrDefault(false)

    @JvmStatic
    fun generateMasterKey(): ByteArray? = runCatching {
        val master = ByteArray(MASTER_KEY_SIZE)
        java.security.SecureRandom().nextBytes(master)

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrapperKey())
        val sealed = cipher.doFinal(master)

        // L'IV précède le chiffré : les deux sont nécessaires au déchiffrement.
        val stored = cipher.iv + sealed
        prefs().edit()
            .putString(PREF_ENTRY, Base64.encodeToString(stored, Base64.NO_WRAP))
            .apply()

        master
    }.getOrNull()

    @JvmStatic
    fun loadMasterKey(): ByteArray? = runCatching {
        val encoded = prefs().getString(PREF_ENTRY, null) ?: return null
        val stored = Base64.decode(encoded, Base64.NO_WRAP)
        if (stored.size <= GCM_IV_SIZE) return null

        val iv = stored.copyOfRange(0, GCM_IV_SIZE)
        val sealed = stored.copyOfRange(GCM_IV_SIZE, stored.size)

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, wrapperKey(), GCMParameterSpec(GCM_TAG_BITS, iv))
        cipher.doFinal(sealed)
    }.getOrNull()

    @JvmStatic
    fun deleteMasterKey(): Boolean = runCatching {
        prefs().edit().remove(PREF_ENTRY).apply()
        KeyStore.getInstance(KEYSTORE).apply { load(null) }.deleteEntry(KEY_ALIAS)
        true
    }.getOrDefault(false)

    private fun prefs() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Clé AES du Keystore, créée à la première utilisation. Non exportable. */
    private fun wrapperKey(): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let {
            return it.secretKey
        }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                // Volontairement sans exigence de déverrouillage : le moteur doit
                // pouvoir déchiffrer une notification reçue écran verrouillé.
                .setUserAuthenticationRequired(false)
                .build()
        )
        return generator.generateKey()
    }
}
