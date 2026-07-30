import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Implémentation média WebRTC, chargée en DIFFÉRÉ par CallSession (call_session.dart).
///
/// flutter_webrtc est importé ici NORMALEMENT (types propres), mais ce fichier
/// n'est jamais chargé tant qu'un appel réel n'a pas démarré : la façade le
/// défère. Sa bibliothèque native reste donc hors du process pendant les tests,
/// où elle ferait segfauter le flutter_tester à son démontage.
///
/// Un appel WebRTC en cours : la couche MÉDIA, distincte de la signalisation.
///
/// ## Ce que WebRTC apporte, et pourquoi c'est sûr
///
/// La voix est chiffrée de bout en bout par **DTLS-SRTP**, entre les deux
/// appareils, dans libwebrtc — pas dans notre moteur, mais c'est de la crypto
/// standard et auditée. L'empreinte DTLS voyage dans le SDP, lui-même échangé
/// via notre canal chiffré et authentifié (Double Ratchet) : personne ne peut
/// substituer une empreinte et s'intercaler dans le média.
///
/// ## Relais TOUJOURS
///
/// `iceTransportPolicy: relay` force le passage par le TURN : les correspondants
/// ne découvrent jamais l'IP l'un de l'autre. Le relais voit les IP mais pas le
/// contenu — le choix de vie privée retenu, au prix d'un peu de bande passante.
class CallMedia {
  CallMedia({
    required this.iceServers,
    required this.onSignal,
    required this.onConnecte,
    this.onQualite,
  });

  /// Serveurs ICE (TURN) au format attendu par RTCPeerConnection.
  final List<dynamic> iceServers;

  /// Émet un signal local (offre/réponse/candidat ICE) à chiffrer et envoyer.
  final void Function(String kind, Map<String, Object?> data) onSignal;

  /// Appelé quand le média est réellement connecté (ou perdu).
  final void Function(bool connecte) onConnecte;

  /// Qualité de liaison estimée : 2 bonne, 1 moyenne, 0 faible.
  final void Function(int niveau)? onQualite;

  RTCPeerConnection? _pc;
  MediaStream? _local;
  MediaStream? _remote;

  Timer? _echantillonQualite;
  int _perdusPrec = 0;
  int _recusPrec = 0;

  MediaStream? get remoteStream => _remote;

  Future<void> _init() async {
    _pc = await createPeerConnection({
      'iceServers': iceServers,
      // Relais imposé : jamais de candidat direct, donc aucune IP révélée au
      // correspondant. Tout passe par le TURN.
      'iceTransportPolicy': 'relay',
      'sdpSemantics': 'unified-plan',
    });

    _local = await navigator.mediaDevices
        .getUserMedia({'audio': true, 'video': false});
    for (final track in _local!.getTracks()) {
      await _pc!.addTrack(track, _local!);
    }

    _pc!.onIceCandidate = (c) {
      if (c.candidate == null) return;
      onSignal('ice', {
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    };
    _pc!.onTrack = (event) {
      if (event.streams.isNotEmpty) _remote = event.streams.first;
    };
    _pc!.onConnectionState = (state) {
      onConnecte(
          state == RTCPeerConnectionState.RTCPeerConnectionStateConnected);
    };
    // L'état de connexion agrégé (onConnectionState) n'est pas rapporté de façon
    // fiable sur toutes les plateformes ; l'état ICE, lui, l'est. On s'appuie
    // donc sur les deux : « connecté/complété » → média en place.
    _pc!.onIceConnectionState = (state) {
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        onConnecte(true);
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        onConnecte(false);
      }
    };
    _demarrerQualite();
  }

  /// Échantillonne périodiquement la qualité de liaison à partir des stats
  /// WebRTC (perte de paquets sur l'intervalle, temps d'aller-retour) et publie
  /// un niveau 2/1/0. Best-effort : une lecture ratée est simplement ignorée.
  void _demarrerQualite() {
    if (onQualite == null) return;
    _echantillonQualite = Timer.periodic(const Duration(seconds: 3), (_) async {
      final pc = _pc;
      if (pc == null) return;
      try {
        final reports = await pc.getStats();
        int perdus = 0, recus = 0;
        double? rtt;
        for (final r in reports) {
          if (r.type == 'inbound-rtp') {
            perdus += ((r.values['packetsLost'] as num?) ?? 0).toInt();
            recus += ((r.values['packetsReceived'] as num?) ?? 0).toInt();
          } else if (r.type == 'remote-inbound-rtp') {
            final v = r.values['roundTripTime'];
            if (v is num) rtt = v.toDouble();
          }
        }
        final dPerdus = perdus - _perdusPrec;
        final dRecus = recus - _recusPrec;
        _perdusPrec = perdus;
        _recusPrec = recus;
        if (dRecus + dPerdus <= 0) return; // pas de trafic mesurable
        final perte = dPerdus / (dRecus + dPerdus);
        final int niveau;
        if (perte < 0.02 && (rtt == null || rtt < 0.3)) {
          niveau = 2;
        } else if (perte < 0.08 && (rtt == null || rtt < 0.6)) {
          niveau = 1;
        } else {
          niveau = 0;
        }
        onQualite!(niveau);
      } catch (_) {
        // stats indisponibles sur cette plateforme/instant : on n'insiste pas
      }
    });
  }

  /// Côté appelant : prépare le média et produit l'offre à joindre à l'invite.
  Future<Map<String, Object?>> creerOffre() async {
    await _init();
    final offre = await _pc!.createOffer({'offerToReceiveAudio': true});
    await _pc!.setLocalDescription(offre);
    return {'sdp': offre.sdp, 'type': offre.type};
  }

  /// Côté appelé : consomme l'offre reçue et produit la réponse.
  Future<Map<String, Object?>> repondre(Map<String, dynamic> offre) async {
    await _init();
    await _pc!.setRemoteDescription(RTCSessionDescription(
        offre['sdp'] as String, offre['type'] as String));
    final rep = await _pc!.createAnswer();
    await _pc!.setLocalDescription(rep);
    return {'sdp': rep.sdp, 'type': rep.type};
  }

  /// Côté appelant : applique la réponse de l'appelé.
  Future<void> appliquerReponse(Map<String, dynamic> rep) async {
    await _pc?.setRemoteDescription(RTCSessionDescription(
        rep['sdp'] as String, rep['type'] as String));
  }

  /// Ajoute un candidat ICE reçu du correspondant.
  Future<void> ajouterCandidat(Map<String, dynamic> c) async {
    await _pc?.addCandidate(RTCIceCandidate(
      c['candidate'] as String?,
      c['sdpMid'] as String?,
      (c['sdpMLineIndex'] as num?)?.toInt(),
    ));
  }

  /// Coupe le micro, ou le remet. Renvoie l'état muet résultant.
  bool basculerMuet() {
    final tracks = _local?.getAudioTracks() ?? const [];
    if (tracks.isEmpty) return false;
    final muet = tracks.first.enabled; // était actif → on coupe
    for (final t in tracks) {
      t.enabled = !muet;
    }
    return muet;
  }

  Future<void> fermer() async {
    _echantillonQualite?.cancel();
    _echantillonQualite = null;
    for (final t in _local?.getTracks() ?? const []) {
      await t.stop();
    }
    await _local?.dispose();
    await _pc?.close();
    _pc = null;
    _local = null;
    _remote = null;
  }
}
