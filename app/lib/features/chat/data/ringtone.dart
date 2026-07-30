import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

/// Sonnerie d'appel entrant, synthétisée en mémoire (aucun fichier d'asset).
///
/// On génère une fois un court WAV « bip-bip … silence » et on le joue en
/// boucle via audioplayers (déjà présent pour les messages vocaux). Générer le
/// son en code évite d'embarquer un fichier audio et ses questions de licence.
class Sonnerie {
  AudioPlayer? _player;

  Future<void> demarrer() async {
    try {
      final p = _player ??= AudioPlayer();
      await p.setReleaseMode(ReleaseMode.loop);
      await p.play(BytesSource(_wav, mimeType: 'audio/wav'));
    } catch (_) {
      // Pas de sortie audio (environnement de test, session sans son) : la
      // sonnerie est un confort, son échec ne doit rien casser.
    }
  }

  Future<void> arreter() async {
    try {
      await _player?.stop();
    } catch (_) {}
  }

  Future<void> liberer() async {
    try {
      await _player?.dispose();
    } catch (_) {}
    _player = null;
  }

  /// WAV mono 16 bits : ~1,2 s de tonalité douce (deux fréquences proches, avec
  /// fondu pour éviter les clics) puis ~0,8 s de silence. Bouclé, ça donne la
  /// cadence d'une sonnerie.
  static final Uint8List _wav = _genererWav();

  static Uint8List _genererWav() {
    const sr = 16000;
    final nTon = (sr * 1.2).round();
    final nSilence = (sr * 0.8).round();
    final total = nTon + nSilence;
    final pcm = Int16List(total);
    const fade = 400; // échantillons de fondu entrée/sortie
    for (var i = 0; i < nTon; i++) {
      final t = i / sr;
      final onde = (sin(2 * pi * 440 * t) + sin(2 * pi * 480 * t)) / 2;
      var env = 1.0;
      if (i < fade) env = i / fade;
      if (i > nTon - fade) env = (nTon - i) / fade;
      pcm[i] = (onde * 0.35 * env * 32767).round().clamp(-32768, 32767);
    }
    return _emballerWav(pcm, sr);
  }

  /// Ajoute l'en-tête WAV canonique (44 octets) devant les échantillons PCM.
  static Uint8List _emballerWav(Int16List samples, int sr) {
    final octetsData = samples.length * 2;
    final total = 44 + octetsData;
    final out = ByteData(total);
    void ecrireChaine(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        out.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    ecrireChaine(0, 'RIFF');
    out.setUint32(4, 36 + octetsData, Endian.little);
    ecrireChaine(8, 'WAVE');
    ecrireChaine(12, 'fmt ');
    out.setUint32(16, 16, Endian.little); // taille du bloc fmt
    out.setUint16(20, 1, Endian.little); // PCM
    out.setUint16(22, 1, Endian.little); // mono
    out.setUint32(24, sr, Endian.little);
    out.setUint32(28, sr * 2, Endian.little); // débit octets/s
    out.setUint16(32, 2, Endian.little); // alignement bloc
    out.setUint16(34, 16, Endian.little); // bits par échantillon
    ecrireChaine(36, 'data');
    out.setUint32(40, octetsData, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      out.setInt16(44 + i * 2, samples[i], Endian.little);
    }
    return out.buffer.asUint8List();
  }
}
