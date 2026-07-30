import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../data/chat_service.dart';

/// Écran plein d'appel, superposé au reste dès qu'un appel est en cours.
///
/// Il ne montre que ce qui importe pendant un appel : qui, l'état, et les deux
/// ou trois gestes possibles. Aucun contenu du fil ne doit distraire.
class CallOverlay extends StatefulWidget {
  const CallOverlay({super.key, required this.service});

  final ChatService service;

  @override
  State<CallOverlay> createState() => _CallOverlayState();
}

class _CallOverlayState extends State<CallOverlay> {
  Timer? _tic;

  @override
  void initState() {
    super.initState();
    // Rafraîchit la durée affichée chaque seconde pendant l'appel.
    _tic = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tic?.cancel();
    super.dispose();
  }

  /// Durée écoulée depuis le décroché, en `M:SS`.
  String? _duree() {
    final depuis = widget.service.callDepuis;
    if (depuis == null) return null;
    final d = DateTime.now().difference(depuis);
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final theme = Theme.of(context);
    final entrant = service.callEtat == CallEtat.entrant;
    final connecte = service.callEtat == CallEtat.connecte;

    final duree = _duree();
    final etat = switch (service.callEtat) {
      CallEtat.entrant => 'Appel entrant',
      CallEtat.sortant => 'Appel…',
      CallEtat.connecte => service.callMediaConnecte
          ? (duree ?? 'En communication')
          : 'Connexion…',
      CallEtat.aucun => '',
    };

    return Material(
      color: theme.colorScheme.surface,
      child: DecoratedBox(
        decoration: ZiaTheme.backgroundDecoration(theme.colorScheme),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              children: [
                // Réduire l'appel en pastille flottante pour continuer à
                // naviguer (pas pour un appel entrant, qu'il faut trancher).
                Align(
                  alignment: Alignment.topLeft,
                  child: entrant
                      ? const SizedBox(height: 48)
                      : IconButton(
                          tooltip: 'Réduire',
                          icon: const Icon(Icons.expand_more),
                          onPressed: service.reduireAppel,
                        ),
                ),
                const Spacer(),
                // Halo + initiale : sobre, pas d'avatar identité ici.
                Container(
                  width: 108,
                  height: 108,
                  decoration: BoxDecoration(
                    gradient: ZiaTheme.accentGradient(theme.colorScheme),
                    shape: BoxShape.circle,
                    boxShadow: ZiaTheme.glow(theme.colorScheme.primary,
                        opacity: 0.4, blur: 30),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    (service.callPeerName ?? '?').characters.first.toUpperCase(),
                    style: theme.textTheme.displaySmall?.copyWith(
                        color: theme.colorScheme.onPrimary,
                        fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: 24),
                Text(service.callPeerName ?? 'Inconnu',
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.lock_rounded,
                      size: 13, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Text(etat,
                      style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ]),
                const SizedBox(height: 6),
                Text('Chiffré de bout en bout',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
                if (connecte && service.callMediaConnecte) ...[
                  const SizedBox(height: 12),
                  _qualite(theme, service.callQualite),
                ],
                const Spacer(),

                // Boutons : accepter/refuser pour un entrant, muet/raccrocher
                // sinon.
                if (entrant)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _bouton(
                        theme,
                        icone: Icons.call_end,
                        couleur: theme.colorScheme.error,
                        libelle: 'Refuser',
                        onTap: service.raccrocher,
                      ),
                      _bouton(
                        theme,
                        icone: Icons.call,
                        couleur: const Color(0xFF2FA36B),
                        libelle: 'Accepter',
                        onTap: service.accepterAppel,
                      ),
                    ],
                  )
                else
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _bouton(
                        theme,
                        icone: service.callMuet ? Icons.mic_off : Icons.mic,
                        couleur: service.callMuet
                            ? theme.colorScheme.primary
                            : theme.colorScheme.surfaceContainerHighest,
                        encre: service.callMuet
                            ? theme.colorScheme.onPrimary
                            : theme.colorScheme.onSurface,
                        libelle: service.callMuet ? 'Muet' : 'Micro',
                        onTap: service.basculerMuet,
                        // Le micro n'a de sens qu'une fois en communication.
                        actif: connecte,
                      ),
                      _bouton(
                        theme,
                        icone: Icons.call_end,
                        couleur: theme.colorScheme.error,
                        libelle: 'Raccrocher',
                        onTap: service.raccrocher,
                      ),
                    ],
                  ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Indicateur de qualité de liaison : trois barres + libellé, coloré selon
  /// le niveau (2 bonne, 1 moyenne, 0 faible).
  Widget _qualite(ThemeData theme, int niveau) {
    final (couleur, libelle) = switch (niveau) {
      2 => (const Color(0xFF2FA36B), 'Bonne connexion'),
      1 => (const Color(0xFFE0A030), 'Connexion moyenne'),
      _ => (theme.colorScheme.error, 'Connexion faible'),
    };
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < 3; i++) ...[
          Container(
            width: 4,
            height: 8.0 + i * 4,
            decoration: BoxDecoration(
              color: i <= niveau
                  ? couleur
                  : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 3),
        ],
        const SizedBox(width: 6),
        Text(libelle,
            style: theme.textTheme.bodySmall?.copyWith(color: couleur)),
      ],
    );
  }

  Widget _bouton(
    ThemeData theme, {
    required IconData icone,
    required Color couleur,
    required String libelle,
    required VoidCallback onTap,
    Color? encre,
    bool actif = true,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: actif ? couleur : couleur.withValues(alpha: 0.4),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: actif ? onTap : null,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Icon(icone,
                  size: 28,
                  color: encre ?? theme.colorScheme.onError),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(libelle, style: theme.textTheme.bodySmall),
      ],
    );
  }
}
