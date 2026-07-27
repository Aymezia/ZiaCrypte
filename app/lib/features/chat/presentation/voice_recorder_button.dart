import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Format d'enregistrement : WAV PCM 16 bits, 16 kHz, mono.
///
/// ## Pourquoi pas AAC, qui serait cinq fois plus compact
///
/// Parce qu'un message vocal qui ne se lit pas ne vaut rien, quelle que soit sa
/// taille. L'AAC dans un conteneur m4a se lit nativement sur Windows, macOS,
/// iOS et Android — mais **pas sous Linux** : GStreamer ne sait démultiplexer
/// le conteneur qu'avec `plugins-base`/`good`, et le décodeur AAC vit dans
/// `plugins-bad` ou `libav`, absents de beaucoup d'installations. Le message
/// arrivait donc, se déchiffrait, et ne produisait aucun son.
///
/// Opus a le défaut symétrique : parfait sous Linux et Android, absent des
/// décodeurs natifs de Windows et d'Apple.
///
/// Le WAV est le seul format que les quatre plateformes décodent sans aucune
/// dépendance supplémentaire. Il coûte environ 32 ko par seconde — d'où le
/// 16 kHz mono, largement suffisant pour la voix, et la durée plafonnée.
/// On pourra revenir à Opus le jour où l'on embarquera un décodeur.
const _configVocale = RecordConfig(
  encoder: AudioEncoder.wav,
  sampleRate: 16000,
  numChannels: 1,
  noiseSuppress: true,
  autoGain: true,
);

/// Au-delà, un « message vocal » devient un fichier lourd sans le dire.
/// 3 minutes de WAV 16 kHz mono ≈ 5,8 Mo.
const _dureeMaximale = Duration(minutes: 3);

/// Bouton d'enregistrement de message vocal.
///
/// Un appui démarre l'enregistrement, un second l'arrête et déclenche l'envoi.
/// L'audio est capturé en fichier local temporaire ; c'est l'appelant qui le
/// chiffre et l'envoie (via le chemin des pièces jointes, déjà éprouvé).
///
/// La capture micro dépend du matériel : sur une machine sans périphérique
/// d'entrée, `hasPermission` échoue et le bouton le signale plutôt que de
/// paraître inerte.
class VoiceRecorderButton extends StatefulWidget {
  const VoiceRecorderButton({
    super.key,
    required this.enabled,
    required this.onRecorded,
  });

  final bool enabled;

  /// Appelé à la fin de l'enregistrement avec le chemin du fichier et sa durée.
  final void Function(String path, int durationMs) onRecorded;

  @override
  State<VoiceRecorderButton> createState() => _VoiceRecorderButtonState();
}

class _VoiceRecorderButtonState extends State<VoiceRecorderButton> {
  final AudioRecorder _recorder = AudioRecorder();
  bool _recording = false;
  DateTime? _startedAt;
  Timer? _ticker;
  Duration _elapsed = Duration.zero;

  @override
  void dispose() {
    _ticker?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_recording) {
      await _stop();
    } else {
      await _start();
    }
  }

  Future<void> _start() async {
    try {
      if (!await _recorder.hasPermission()) {
        _snack('Micro indisponible ou permission refusée.');
        return;
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/vocal_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _recorder.start(_configVocale, path: path);
      _startedAt = DateTime.now();
      _elapsed = Duration.zero;
      _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        setState(() => _elapsed = DateTime.now().difference(_startedAt!));
        // Arrêt automatique : sans borne, un micro laissé ouvert produit un
        // fichier de plusieurs dizaines de mégaoctets sans que personne s'en
        // aperçoive avant l'envoi.
        if (_elapsed >= _dureeMaximale) {
          _snack('Durée maximale atteinte — enregistrement envoyé.');
          _stop();
        }
      });
      setState(() => _recording = true);
    } catch (e) {
      _snack('Enregistrement impossible sur cet appareil.');
    }
  }

  Future<void> _stop() async {
    _ticker?.cancel();
    // stop() peut lever si l'enregistrement n'a pas abouti (permission retirée
    // en cours, stockage plein) : sans ce garde, l'exception remontait non
    // capturée et affichait l'écran d'erreur rouge.
    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {
      if (mounted) setState(() => _recording = false);
      _snack('Enregistrement interrompu — rien à envoyer.');
      return;
    }
    final durationMs = _startedAt == null
        ? 0
        : DateTime.now().difference(_startedAt!).inMilliseconds;
    if (mounted) setState(() => _recording = false);
    // Ignore un appui trop bref : rien d'exploitable en dessous d'une seconde.
    if (path == null || durationMs < 800) return;
    // Le plugin peut renvoyer un chemin SANS fichier : on vérifie avant de le
    // confier à l'envoi, plutôt que de laisser la lecture échouer plus loin.
    if (await File(path).exists()) {
      widget.onRecorded(path, durationMs);
    } else {
      _snack('Enregistrement introuvable — rien à envoyer.');
    }
  }

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_recording) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fiber_manual_record, color: theme.colorScheme.error, size: 16),
          const SizedBox(width: 4),
          Text(_format(_elapsed), style: theme.textTheme.bodySmall),
          IconButton(
            tooltip: 'Arrêter et envoyer',
            onPressed: _toggle,
            icon: Icon(Icons.stop_circle, color: theme.colorScheme.primary),
          ),
        ],
      );
    }
    return IconButton(
      tooltip: 'Message vocal',
      onPressed: widget.enabled ? _toggle : null,
      icon: const Icon(Icons.mic_none_rounded),
    );
  }

  static String _format(Duration d) {
    final s = d.inSeconds;
    return '${(s ~/ 60).toString().padLeft(1, '0')}:'
        '${(s % 60).toString().padLeft(2, '0')}';
  }
}
