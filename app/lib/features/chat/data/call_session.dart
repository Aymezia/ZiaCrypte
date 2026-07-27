// Façade d'appel média, chargée à la demande.
//
// flutter_webrtc embarque une bibliothèque native qui, une fois dans le
// process, fait segfauter le `flutter_tester` headless à son démontage — même
// sans être utilisée. On isole donc TOUT flutter_webrtc dans `call_media.dart`,
// importé ici en DIFFÉRÉ : sa bibliothèque native ne se charge qu'au premier
// appel réel (`loadLibrary`), jamais pendant `flutter test`.
//
// L'implémentation (`CallMedia`) est un type différé : il ne peut pas annoter
// un champ. La façade garde donc son instance en `dynamic` et délègue en
// dispatch dynamique. C'est confiné à ce seul fichier ; l'impl, elle, est
// entièrement typée.
import 'call_media.dart' deferred as media;

class CallSession {
  CallSession({
    required this.iceServers,
    required this.onSignal,
    required this.onConnecte,
  });

  final List<dynamic> iceServers;
  final void Function(String kind, Map<String, Object?> data) onSignal;
  final void Function(bool connecte) onConnecte;

  dynamic _impl; // CallMedia, chargé en différé

  Future<void> _assurerImpl() async {
    if (_impl != null) return;
    await media.loadLibrary();
    _impl = media.CallMedia(
      iceServers: iceServers,
      onSignal: onSignal,
      onConnecte: onConnecte,
    );
  }

  /// Côté appelant : prépare le média et produit l'offre à joindre à l'invite.
  Future<Map<String, Object?>> creerOffre() async {
    await _assurerImpl();
    return await _impl.creerOffre() as Map<String, Object?>;
  }

  /// Côté appelé : consomme l'offre reçue et produit la réponse.
  Future<Map<String, Object?>> repondre(Map<String, dynamic> offre) async {
    await _assurerImpl();
    return await _impl.repondre(offre) as Map<String, Object?>;
  }

  Future<void> appliquerReponse(Map<String, dynamic> rep) async {
    await _impl?.appliquerReponse(rep);
  }

  Future<void> ajouterCandidat(Map<String, dynamic> c) async {
    await _impl?.ajouterCandidat(c);
  }

  /// Coupe ou rétablit le micro ; renvoie l'état muet résultant.
  bool basculerMuet() => (_impl?.basculerMuet() as bool?) ?? false;

  Future<void> fermer() async {
    await _impl?.fermer();
    _impl = null;
  }
}
