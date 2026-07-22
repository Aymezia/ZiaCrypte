import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Deux écrans d'accueil, montrés une seule fois avant le premier compte.
///
/// Ils ne vendent pas la fonctionnalité : ils expliquent ce que l'application
/// garantit et ce qu'elle NE garantit pas. Quelqu'un qui ne comprend pas que
/// perdre son appareil signifie perdre ses messages sera déçu au pire moment ;
/// autant le dire d'emblée, quand la promesse est encore en train de se former.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onTermine});

  final VoidCallback onTermine;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pages = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: DecoratedBox(
        decoration: ZiaTheme.backgroundDecoration(theme.colorScheme),
        child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pages,
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  _page1(theme),
                  _page2(theme),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                2,
                (i) => AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: _page == i ? 20 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _page == i
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16)),
                  onPressed: () {
                    if (_page == 0) {
                      _pages.nextPage(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOut);
                    } else {
                      widget.onTermine();
                    }
                  },
                  child: Text(_page == 0 ? 'Suivant' : 'Commencer'),
                ),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }

  Widget _page1(ThemeData theme) => _gabarit(
        theme,
        icone: Icons.lock_rounded,
        titre: 'Personne ne peut lire tes messages',
        corps: const [
          ('Chiffrés sur ton appareil',
              'Tes messages sont chiffrés avant de partir, et déchiffrés '
                  'seulement chez ton correspondant.'),
          ('Le serveur ne détient aucune clé',
              'Il transporte des octets qu’il ne peut pas ouvrir. Même saisi '
                  'ou compromis, il n’a rien à livrer.'),
          ('Tu peux le vérifier',
              'Un numéro de sécurité, à comparer de vive voix, prouve que '
                  'personne ne s’est intercalé entre vous.'),
        ],
      );

  Widget _page2(ThemeData theme) => _gabarit(
        theme,
        icone: Icons.key_rounded,
        titre: 'Tes clés n’existent que chez toi',
        corps: const [
          ('Rien n’est récupérable',
              'Aucune clé n’est déposée sur un serveur. C’est la garantie — '
                  'et la contrepartie.'),
          ('Perdre l’appareil, c’est perdre l’historique',
              'Personne, pas même nous, ne peut te le rendre. Ajoute un second '
                  'appareil pendant que tu le peux.'),
          ('Un mot de passe solide compte vraiment',
              'Il protège ton compte sur le serveur. Active aussi la '
                  'vérification en deux étapes dans les options.'),
        ],
      );

  Widget _gabarit(
    ThemeData theme, {
    required IconData icone,
    required String titre,
    required List<(String, String)> corps,
  }) =>
      SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(32, 40, 32, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  gradient: ZiaTheme.accentGradient(theme.colorScheme),
                  shape: BoxShape.circle,
                  boxShadow: ZiaTheme.glow(theme.colorScheme.primary,
                      opacity: 0.4, blur: 26),
                ),
                child: Icon(icone,
                    size: 44, color: theme.colorScheme.onPrimary),
              ),
            ),
            const SizedBox(height: 28),
            Text(titre,
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 24),
            for (final (t, d) in corps) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Icon(Icons.check_circle,
                        size: 18, color: theme.colorScheme.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t,
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(d,
                            style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                height: 1.35)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
            ],
          ],
        ),
      );
}
