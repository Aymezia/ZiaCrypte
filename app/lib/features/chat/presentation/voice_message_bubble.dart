import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../data/chat_service.dart';

/// Bulle d'un message vocal, lu directement dans l'application.
///
/// Au premier appui, le fichier chiffré est téléchargé et déchiffré en mémoire,
/// écrit dans un fichier temporaire, puis lu. L'octet audio ne touche jamais le
/// réseau ni le disque de l'utilisateur en clair au-delà de ce cache éphémère.
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
  final AudioPlayer _player = AudioPlayer();
  String? _localPath;
  bool _loading = false;
  bool _playing = false;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _playing = state == PlayerState.playing);
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() { _playing = false; _position = Duration.zero; });
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
      return;
    }
    if (_localPath == null) {
      setState(() => _loading = true);
      final path = await widget.service.materializeForPlayback(widget.attachment);
      if (!mounted) return;
      setState(() { _loading = false; _localPath = path; });
      if (path == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Lecture impossible')),
        );
        return;
      }
    }
    await _player.play(DeviceFileSource(_localPath!));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = widget.mine
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;
    final totalMs = widget.attachment.voiceDurationMs ?? 0;
    final progress = totalMs > 0
        ? (_position.inMilliseconds / totalMs).clamp(0.0, 1.0)
        : 0.0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: _loading ? null : _toggle,
          icon: _loading
              ? SizedBox(
                  height: 20, width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: color))
              : Icon(_playing ? Icons.pause_circle : Icons.play_circle,
                  color: color, size: 28),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 120,
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 4,
            backgroundColor: color.withValues(alpha: 0.25),
            color: color,
          ),
        ),
        const SizedBox(width: 8),
        Text(_format(totalMs),
            style: TextStyle(fontSize: 12, color: color.withValues(alpha: 0.85))),
      ],
    );
  }

  static String _format(int ms) {
    final s = (ms / 1000).round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}
