import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

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
          '${dir.path}/vocal_${DateTime.now().millisecondsSinceEpoch}.m4a';
      // AAC dans un conteneur m4a : lu nativement par audioplayers sur toutes
      // les plateformes, et compact pour un message vocal.
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000),
        path: path,
      );
      _startedAt = DateTime.now();
      _elapsed = Duration.zero;
      _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        setState(() => _elapsed = DateTime.now().difference(_startedAt!));
      });
      setState(() => _recording = true);
    } catch (e) {
      _snack('Enregistrement impossible sur cet appareil.');
    }
  }

  Future<void> _stop() async {
    _ticker?.cancel();
    final path = await _recorder.stop();
    final durationMs = _startedAt == null
        ? 0
        : DateTime.now().difference(_startedAt!).inMilliseconds;
    setState(() => _recording = false);
    // Ignore un appui trop bref : rien d'exploitable en dessous d'une seconde.
    if (path != null && durationMs >= 800) {
      widget.onRecorded(path, durationMs);
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
