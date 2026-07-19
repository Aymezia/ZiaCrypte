# Le moteur natif atteint ce pont PAR SON NOM, via JNI (FindClass +
# GetStaticMethodID). R8 n'a aucun moyen de voir cette référence : sans cette
# règle il renomme la classe et supprime ses méthodes, et la persistance de
# l'identité échoue silencieusement à l'exécution.
-keep class com.ziacrypte.KeyStoreBridge { *; }

# Conserve aussi les méthodes annotées pour JNI, par principe.
-keepclasseswithmembernames class * {
    native <methods>;
}
