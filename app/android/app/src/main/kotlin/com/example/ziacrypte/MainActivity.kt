package com.example.ziacrypte

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import androidx.core.content.FileProvider
import com.ziacrypte.KeyStoreBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Le moteur natif appelle KeyStoreBridge par JNI ; celui-ci a besoin
        // d'un contexte applicatif pour atteindre le Keystore et les préférences.
        KeyStoreBridge.init(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ziacrypte/update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installerApk" -> installerApk(call.argument<String>("chemin"), result)
                    "ouvrirFichier" -> ouvrirFichier(call.argument<String>("chemin"), result)
                    "protegerEcran" -> {
                        protegerEcran(call.argument<Boolean>("actif") ?: true)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Empêche les captures d'écran et masque l'application dans la liste des
     * tâches récentes.
     *
     * Ce que ça arrête : une capture faite par l'appareil lui-même, et
     * l'aperçu que le système garde en mémoire après un changement
     * d'application — lequel survit à la fermeture et se retrouve dans les
     * sauvegardes.
     *
     * Ce que ça n'arrête PAS, et l'interface doit le dire : photographier
     * l'écran avec un autre téléphone. Aucun logiciel ne peut l'empêcher.
     */
    private fun protegerEcran(actif: Boolean) {
        runOnUiThread {
            if (actif) {
                window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            }
        }
    }

    /**
     * Ouvre un média déchiffré avec le lecteur du système.
     *
     * Le fichier vit dans le cache de l'application ; le FileProvider n'en
     * accorde l'accès qu'à l'application choisie, et seulement le temps de la
     * lecture. Aucune autre application ne peut parcourir ce dossier.
     */
    private fun ouvrirFichier(chemin: String?, result: MethodChannel.Result) {
        val fichier = chemin?.let { File(it) }
        if (fichier == null || !fichier.isFile) {
            result.error("introuvable", "fichier introuvable : $chemin", null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(this, "$packageName.updates", fichier)
            val type = when (fichier.extension.lowercase()) {
                "mp4", "m4v" -> "video/mp4"
                "mov" -> "video/quicktime"
                "webm" -> "video/webm"
                "mkv" -> "video/x-matroska"
                else -> "video/*"
            }
            startActivity(
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, type)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
            result.success(true)
        } catch (e: Exception) {
            result.error("ouverture_impossible", e.message, null)
        }
    }

    /**
     * Remet un APK **déjà vérifié** à l'installateur du système.
     *
     * Côté Dart, le fichier n'arrive ici qu'après contrôle de sa signature
     * Ed25519 par le moteur natif. Cette méthode ne vérifie donc rien elle-même :
     * elle déclenche l'installation, et Android impose ensuite sa propre
     * confirmation. Une installation réellement silencieuse est réservée aux
     * applications système — et c'est une bonne chose : une application capable
     * de se remplacer sans l'accord de l'utilisateur serait aussi capable de le
     * faire après avoir été compromise.
     */
    private fun installerApk(chemin: String?, result: MethodChannel.Result) {
        if (chemin.isNullOrEmpty()) {
            result.error("chemin_absent", "aucun fichier fourni", null)
            return
        }
        val apk = File(chemin)
        if (!apk.isFile) {
            result.error("introuvable", "fichier introuvable : $chemin", null)
            return
        }
        try {
            // Sur Android 8+, l'autorisation d'installer se demande par
            // application. Sans elle, l'intent d'installation est simplement
            // ignoré : on ouvre le réglage correspondant plutôt que d'échouer
            // en silence.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !packageManager.canRequestPackageInstalls()
            ) {
                startActivity(
                    Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                        .setData(Uri.parse("package:$packageName"))
                )
                result.success(false)
                return
            }

            // Android 7+ refuse les URI `file://` entre applications
            // (FileUriExposedException) : on passe par le FileProvider, qui
            // n'ouvre l'accès qu'à ce fichier précis, et seulement le temps de
            // l'installation.
            val uri = FileProvider.getUriForFile(this, "$packageName.updates", apk)
            startActivity(
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
            result.success(true)
        } catch (e: Exception) {
            result.error("echec_installation", e.message, null)
        }
    }
}
