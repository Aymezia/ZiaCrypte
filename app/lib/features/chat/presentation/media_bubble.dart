import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/chat_service.dart';

/// Nature d'une pièce jointe, déduite de son nom de fichier.
///
/// Le nom voyage CHIFFRÉ dans le message : le serveur ne sait donc pas s'il
/// relaie une photo, une vidéo ou un document. C'est le client, et lui seul, qui
/// en décide à l'affichage.
enum TypeMedia { image, video, fichier }

TypeMedia typeDe(String fileName) {
  final n = fileName.toLowerCase();
  const images = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'];
  const videos = ['.mp4', '.mov', '.webm', '.mkv', '.avi', '.m4v'];
  if (images.any(n.endsWith)) return TypeMedia.image;
  if (videos.any(n.endsWith)) return TypeMedia.video;
  return TypeMedia.fichier;
}

/// Cache mémoire des médias déchiffrés.
///
/// ## Pourquoi en mémoire et pas sur le disque
///
/// Une photo déchiffrée écrite dans un dossier temporaire y survit à
/// l'application, échappe au chiffrement du coffre, et se retrouve dans les
/// sauvegardes du système. Tant qu'on peut s'en passer, on s'en passe : les
/// octets restent en mémoire, et disparaissent avec le processus.
///
/// Borné en volume — sans cela, faire défiler une conversation chargée de
/// photos ferait enfler l'application jusqu'à la faire tomber.
class _CacheMedia {
  static const int _plafondOctets = 64 * 1024 * 1024;
  static final Map<String, Uint8List> _entrees = {};
  static int _total = 0;

  static Uint8List? lire(String id) {
    final data = _entrees.remove(id);
    if (data == null) return null;
    _entrees[id] = data; // remis en queue : le plus récemment lu part en dernier
    return data;
  }

  static void ecrire(String id, Uint8List data) {
    if (_entrees.containsKey(id)) return;
    _entrees[id] = data;
    _total += data.length;
    while (_total > _plafondOctets && _entrees.length > 1) {
      final plusAncien = _entrees.keys.first;
      _total -= _entrees.remove(plusAncien)?.length ?? 0;
    }
  }
}

/// Pièce jointe visuelle affichée directement dans le fil.
///
/// Les images sous un certain poids se chargent d'elles-mêmes : demander un
/// appui pour voir chaque photo transforme une conversation en corvée. Au-delà,
/// on demande confirmation — décider à la place de quelqu'un de consommer
/// plusieurs mégaoctets, éventuellement en itinérance, ne nous appartient pas.
class MediaBubble extends StatefulWidget {
  const MediaBubble({
    super.key,
    required this.service,
    required this.attachment,
    required this.mine,
  });

  final ChatService service;
  final AttachmentRef attachment;
  final bool mine;

  /// Au-delà, on ne télécharge pas sans y avoir été invité.
  static const int seuilAutomatique = 2 * 1024 * 1024;

  @override
  State<MediaBubble> createState() => _MediaBubbleState();
}

class _MediaBubbleState extends State<MediaBubble> {
  Uint8List? _octets;
  bool _chargement = false;
  String? _erreur;

  TypeMedia get _type => typeDe(widget.attachment.fileName);

  @override
  void initState() {
    super.initState();
    final dejaLa = _CacheMedia.lire(widget.attachment.id);
    if (dejaLa != null) {
      _octets = dejaLa;
    } else if (_type == TypeMedia.image &&
        widget.attachment.size <= MediaBubble.seuilAutomatique) {
      _charger();
    }
  }

  Future<void> _charger() async {
    if (_chargement) return;
    setState(() {
      _chargement = true;
      _erreur = null;
    });
    try {
      final octets = await widget.service.telechargerEnMemoire(widget.attachment);
      _CacheMedia.ecrire(widget.attachment.id, octets);
      if (mounted) {
        setState(() {
          _octets = octets;
          _chargement = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _erreur = '$e';
          _chargement = false;
        });
      }
    }
  }

  /// Ouvre une vidéo avec le lecteur du système.
  ///
  /// Lire une vidéo dans l'application demanderait un moteur de décodage
  /// embarqué (libmpv) sur chaque plateforme. Plutôt que de promettre une
  /// lecture intégrée qui ne fonctionnerait pas partout — la leçon des messages
  /// vocaux est encore fraîche — on passe la main au lecteur du système, qui,
  /// lui, sait décoder ce qu'il a.
  Future<void> _ouvrirVideo() async {
    setState(() {
      _chargement = true;
      _erreur = null;
    });
    try {
      final chemin =
          await widget.service.materializeForPlayback(widget.attachment);
      if (Platform.isAndroid) {
        await const MethodChannel('ziacrypte/update')
            .invokeMethod<void>('ouvrirFichier', {'chemin': chemin});
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [chemin], mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.start('open', [chemin], mode: ProcessStartMode.detached);
      } else if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', chemin],
            mode: ProcessStartMode.detached);
      }
      if (mounted) setState(() => _chargement = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _erreur = '$e';
          _chargement = false;
        });
      }
    }
  }

  void _plainEcran() {
    final octets = _octets;
    if (octets == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _VisionneuseImage(
          octets: octets, nom: widget.attachment.fileName),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final encre = widget.mine
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;

    if (_erreur != null) return _carteErreur(theme);
    if (_type == TypeMedia.video) return _carteVideo(theme, encre);

    final octets = _octets;
    if (octets == null) {
      return _carteAttente(theme, encre);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280, maxHeight: 320),
        child: GestureDetector(
          onTap: _plainEcran,
          child: Image.memory(
            octets,
            fit: BoxFit.cover,
            // Une image illisible ne doit pas casser la conversation : on
            // retombe sur la carte de fichier, qui reste téléchargeable.
            errorBuilder: (_, __, ___) => _carteErreurImage(theme, encre),
          ),
        ),
      ),
    );
  }

  Widget _carteAttente(ThemeData theme, Color encre) => InkWell(
        onTap: _chargement ? null : _charger,
        child: Container(
          width: 220,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
          child: Row(
            children: [
              if (_chargement)
                SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: encre))
              else
                Icon(Icons.image_outlined, color: encre),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _chargement
                      ? 'Déchiffrement…'
                      : 'Photo · ${_poids(widget.attachment.size)}\nappuyer pour afficher',
                  style: TextStyle(fontSize: 12, color: encre),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _carteVideo(ThemeData theme, Color encre) => InkWell(
        onTap: _chargement ? null : _ouvrirVideo,
        child: Container(
          width: 240,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: encre.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: _chargement
                    ? SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: encre))
                    : Icon(Icons.play_arrow_rounded, color: encre),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.attachment.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: encre, fontWeight: FontWeight.w500)),
                    Text('Vidéo · ${_poids(widget.attachment.size)}',
                        style: TextStyle(
                            fontSize: 11, color: encre.withValues(alpha: 0.8))),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  Widget _carteErreurImage(ThemeData theme, Color encre) => Container(
        width: 220,
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Icon(Icons.broken_image_outlined, color: encre),
          const SizedBox(width: 10),
          Expanded(
              child: Text('Image illisible',
                  style: TextStyle(fontSize: 12, color: encre))),
        ]),
      );

  Widget _carteErreur(ThemeData theme) => Container(
        width: 240,
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Icon(Icons.error_outline, size: 18, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(_erreur!,
                maxLines: 3,
                style:
                    TextStyle(fontSize: 11, color: theme.colorScheme.error)),
          ),
          TextButton(
              onPressed: () => setState(() => _erreur = null),
              child: const Text('Réessayer')),
        ]),
      );

  static String _poids(int octets) => octets >= 1024 * 1024
      ? '${(octets / (1024 * 1024)).toStringAsFixed(1)} Mo'
      : '${(octets / 1024).round()} Ko';
}

/// Image en plein écran, avec zoom.
class _VisionneuseImage extends StatelessWidget {
  const _VisionneuseImage({required this.octets, required this.nom});

  final Uint8List octets;
  final String nom;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(nom, style: const TextStyle(fontSize: 14)),
        ),
        body: Center(
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 5,
            child: Image.memory(octets),
          ),
        ),
      );
}
