package com.example.ziacrypte

import android.os.Bundle
import com.ziacrypte.KeyStoreBridge
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Le moteur natif appelle KeyStoreBridge par JNI ; celui-ci a besoin
        // d'un contexte applicatif pour atteindre le Keystore et les préférences.
        KeyStoreBridge.init(this)
    }
}
