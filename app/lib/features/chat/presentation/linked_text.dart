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

  final List<TapGestureRecognizer> _recognizers = [];

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
      return Text(widget.text, style: widget.style);
    }

    final spans = <InlineSpan>[];
    var curseur = 0;
    for (final m in matches) {
      if (m.start > curseur) {
        spans.add(TextSpan(text: widget.text.substring(curseur, m.start)));
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
      spans.add(TextSpan(text: widget.text.substring(curseur)));
    }

    return Text.rich(TextSpan(style: widget.style, children: spans));
  }
}
