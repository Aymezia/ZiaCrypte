import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Texte de message dont les URL sont cliquables.
///
/// Un `StatefulWidget` plutôt qu'une simple fonction, pour une raison précise :
/// chaque lien a besoin d'un [TapGestureRecognizer], et un recognizer créé dans
/// `build` DOIT être libéré, sinon il fuit à chaque reconstruction — et dans un
/// fil de discussion, les bulles se reconstruisent souvent. On garde donc la
/// liste des recognizers et on la libère à chaque rebuild puis à la destruction.
class LinkedText extends StatefulWidget {
  const LinkedText({
    super.key,
    required this.text,
    required this.style,
    required this.linkColor,
    required this.onTapLink,
  });

  final String text;
  final TextStyle style;
  final Color linkColor;
  final void Function(String url) onTapLink;

  @override
  State<LinkedText> createState() => _LinkedTextState();
}

class _LinkedTextState extends State<LinkedText> {
  // http(s) uniquement : on ne rend pas cliquable un « ftp:// » ou un schéma
  // exotique, et surtout jamais un « javascript: ». La borne s'arrête au
  // premier espace ; la ponctuation finale est retirée à l'ouverture.
  static final _regex = RegExp(r'https?://[^\s]+', caseSensitive: false);

  // Mise en forme légère : `code`, **gras**, *gras*, _italique_. Volontairement
  // simple (pas d'imbrication) : de quoi mettre en valeur, sans un moteur
  // Markdown complet ni ses surprises.
  static final _md =
      RegExp(r'`([^`]+)`|\*\*([^*]+)\*\*|\*([^*]+)\*|_([^_]+)_');

  final List<TapGestureRecognizer> _recognizers = [];

  /// Découpe un fragment sans lien en spans stylés selon la mise en forme.
  List<InlineSpan> _spansMarkdown(String texte) {
    final spans = <InlineSpan>[];
    var curseur = 0;
    for (final m in _md.allMatches(texte)) {
      if (m.start > curseur) {
        spans.add(TextSpan(text: texte.substring(curseur, m.start)));
      }
      if (m.group(1) != null) {
        spans.add(TextSpan(
            text: m.group(1),
            style: TextStyle(
                fontFamily: 'monospace',
                backgroundColor: widget.style.color?.withValues(alpha: 0.12))));
      } else if (m.group(2) != null || m.group(3) != null) {
        spans.add(TextSpan(
            text: m.group(2) ?? m.group(3),
            style: const TextStyle(fontWeight: FontWeight.bold)));
      } else if (m.group(4) != null) {
        spans.add(TextSpan(
            text: m.group(4),
            style: const TextStyle(fontStyle: FontStyle.italic)));
      }
      curseur = m.end;
    }
    if (curseur < texte.length) {
      spans.add(TextSpan(text: texte.substring(curseur)));
    }
    return spans;
  }

  void _libererRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _libererRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // On repart de recognizers neufs à chaque construction : les anciens ne
    // pointent plus vers les bons spans une fois le texte ou l'ordre changés.
    _libererRecognizers();

    final matches = _regex.allMatches(widget.text).toList();
    if (matches.isEmpty) {
      return Text.rich(
          TextSpan(style: widget.style, children: _spansMarkdown(widget.text)));
    }

    final spans = <InlineSpan>[];
    var curseur = 0;
    for (final m in matches) {
      if (m.start > curseur) {
        spans.addAll(_spansMarkdown(widget.text.substring(curseur, m.start)));
      }
      final url = m.group(0)!;
      final recognizer = TapGestureRecognizer()
        ..onTap = () => widget.onTapLink(url);
      _recognizers.add(recognizer);
      spans.add(TextSpan(
        text: url,
        style: TextStyle(
          color: widget.linkColor,
          decoration: TextDecoration.underline,
          decorationColor: widget.linkColor,
        ),
        recognizer: recognizer,
      ));
      curseur = m.end;
    }
    if (curseur < widget.text.length) {
      spans.addAll(_spansMarkdown(widget.text.substring(curseur)));
    }

    return Text.rich(TextSpan(style: widget.style, children: spans));
  }
}
