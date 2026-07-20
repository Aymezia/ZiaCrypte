import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../data/chat_service.dart';

/// Bulle d'un message vocal, lu directement dans l'application.
///
/// Au premier appui, le fichier chiffré est téléchargé et déchiffré en mémoire,
/// écrit dans un fichier temporaire, puis lu. Ce fichier en clair est effacé dès
/// que la bulle disparaît de l'écran : de l'audio déchiffré ne doit pas survivre
/// dans un dossier temporaire après la lecture.
class VoiceMessageBubble extends StatefulWidget {
  const VoiceMessageBubble({
    super.key,
    required this.service,
    required this.attachment,
    required this.mine,
  });

  final ChatService service;
  final AttachmentRef attachment;
  final bool mine;

  @override
  State<VoiceMessageBubble> createState() => _VoiceMessageBubbleState();
}

class _VoiceMessageBubbleState extends State<VoiceMessageBubble> {
  /// Bulle en cours de lecture, s'il y en a une.
  ///
  /// Chaque bulle possède son propre lecteur ; sans ce point de rendez-vous,
  /// appuyer sur un second vocal superposerait les deux sons au lieu de
  /// remplacer le premier.
  static _VoiceMessageBubbleState? _enLecture;

  final AudioPlayer _player = AudioPlayer();
  String? _localPath;
  bool _loading = false;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration? _duree;
  String? _erreur;

  /// Durée de référence pour la barre : celle mesurée par le lecteur si elle
  /// est connue, sinon celle annoncée par l'expéditeur. Les deux diffèrent
  /// toujours un peu — l'expéditeur mesure au chronomètre, le lecteur lit
  /// l'en-tête du fichier.
  Duration get _total =>
      _duree ?? Duration(milliseconds: widget.attachment.voiceDurationMs ?? 0);

  @override
  void initState() {
    super.initState();
    _player.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _playing = state == PlayerState.playing);
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duree = d);
    });
    _player.onPlayerComplete.listen((_) {
      if (_enLecture == this) _enLecture = null;
      if (mounted) {
        setState(() {
          _playing = false;
          _position = Duration.zero;
        });
      }
    });
  }

  @override
  void dispose() {
    if (_enLecture == this) _enLecture = null;
    _player.dispose();
    _effacerFichierLocal();
    super.dispose();
  }

  /// Supprime l'audio déchiffré. Best-effort : échouer ici ne doit rien casser,
  /// mais ne pas essayer laisserait des messages en clair sur le disque.
  void _effacerFichierLocal() {
    final chemin = _localPath;
    if (chemin == null) return;
    try {
      final f = File(chemin);
      if (f.existsSync()) f.deleteSync();
      final dossier = f.parent;
      if (dossier.existsSync() && dossier.listSync().isEmpty) {
        dossier.deleteSync();
      }
    } catch (_) {
      // Rien de plus à faire : au pire le système nettoiera son dossier
      // temporaire. Échouer ici ne doit pas empêcher la bulle de disparaître.
    }
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
      return;
    }

    // Une seule lecture à la fois.
    final autre = _enLecture;
    if (autre != null && autre != this) await autre._player.stop();
    _enLecture = this;

    if (_localPath == null) {
      setState(() {
        _loading = true;
        _erreur = null;
      });
      try {
        final path =
            await widget.service.materializeForPlayback(widget.attachment);
        if (!mounted) return;
        setState(() {
          _loading = false;
          _localPath = path;
        });
      } catch (e) {
        if (!mounted) return;
        // On montre la raison : « Lecture impossible » sans cause ne laisse
        // rien à comprendre, ni à l'utilisateur ni à nous.
        setState(() {
          _loading = false;
          _erreur = '$e';
        });
        return;
      }
      await _lire(reprendre: false);
      return;
    }

    // Le fichier est déjà là : on REPREND. `play()` rechargerait la source et
    // repartirait de zéro, ce qui rendait la pause inutilisable.
    await _lire(reprendre: _position > Duration.zero);
  }

  /// Lance ou reprend la lecture, en rendant compte d'un échec du décodeur.
  ///
  /// Le déchiffrement peut parfaitement réussir et la lecture échouer quand
  /// même : c'est le cas des vocaux enregistrés avant le passage au WAV, dont
  /// le décodeur AAC manque sur beaucoup d'installations Linux. Sans ce
  /// message, l'appui restait sans effet et sans explication.
  Future<void> _lire({required bool reprendre}) async {
    try {
      if (reprendre) {
        await _player.resume();
      } else {
        await _player.play(DeviceFileSource(_localPath!));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _erreur = _messageDecodage(e));
    }
  }

  String _messageDecodage(Object e) {
    final ancien = widget.attachment.fileName.toLowerCase().endsWith('.m4a');
    if (ancien && Platform.isLinux) {
      return 'Ce vocal a été enregistré dans un ancien format (AAC) que ce '
          'système ne sait pas décoder. Installe gstreamer1.0-libav, ou '
          'demande qu’il te soit renvoyé — les nouveaux vocaux se lisent '
          'partout.';
    }
    return 'Lecture impossible : $e';
  }

  Future<void> _seek(double fraction) async {
    final total = _total;
    if (total == Duration.zero || _localPath == null) return;
    final cible = Duration(
        milliseconds: (total.inMilliseconds * fraction.clamp(0.0, 1.0)).round());
    await _player.seek(cible);
    if (mounted) setState(() => _position = cible);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = widget.mine
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;

    if (_erreur != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 18, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Flexible(
            child: Text(_erreur!,
                style: TextStyle(fontSize: 12, color: theme.colorScheme.error)),
          ),
          TextButton(
            onPressed: () => setState(() => _erreur = null),
            child: const Text('Réessayer'),
          ),
        ],
      );
    }

    final totalMs = _total.inMilliseconds;
    final progress =
        totalMs > 0 ? (_position.inMilliseconds / totalMs).clamp(0.0, 1.0) : 0.0;
    // Pendant la lecture on affiche le temps écoulé, à l'arrêt la durée totale :
    // un compteur figé donne l'impression que rien ne se passe.
    final affiche = _playing || _position > Duration.zero ? _position : _total;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: _loading ? null : _toggle,
          icon: _loading
              ? SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: color))
              : Icon(_playing ? Icons.pause_circle : Icons.play_circle,
                  color: color, size: 28),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 120,
          child: LayoutBuilder(
            builder: (context, box) => GestureDetector(
              // Se déplacer dans un vocal est le geste le plus courant après
              // « lire » : réécouter un mot mal entendu sans tout reprendre.
              onTapDown: (d) => _seek(d.localPosition.dx / box.maxWidth),
              onHorizontalDragUpdate: (d) =>
                  _seek(d.localPosition.dx / box.maxWidth),
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                height: 24,
                child: Center(
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 4,
                    backgroundColor: color.withValues(alpha: 0.25),
                    color: color,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(_format(affiche.inMilliseconds),
            style:
                TextStyle(fontSize: 12, color: color.withValues(alpha: 0.85))),
      ],
    );
  }

  static String _format(int ms) {
    final s = (ms / 1000).round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}
