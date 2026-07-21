/**
 * Promeut un compte existant au rôle d'administrateur.
 *
 * ## Pourquoi un script et pas une route
 *
 * Il n'existe AUCUNE route pour se donner le rôle d'administrateur, ni pour le
 * donner à quelqu'un d'autre. Un tel point d'entrée serait la cible évidente :
 * une seule faille d'autorisation suffirait à prendre le contrôle de tous les
 * comptes. La promotion exige un accès au serveur — c'est-à-dire un pouvoir
 * qu'on possède déjà quand on l'exécute.
 *
 * Le second facteur est vérifié ici : le garde d'accès refuse toute action
 * d'administration sans 2FA active, et promouvoir un compte qui n'en a pas
 * produirait un administrateur inutilisable.
 *
 *   node server/scripts/promote-admin.mjs <nom-utilisateur>
 *   node server/scripts/promote-admin.mjs <nom-utilisateur> --retirer
 */
import { PrismaClient } from '@prisma/client';

const prisma = new PrismaClient();
const username = process.argv[2];
const retirer = process.argv.includes('--retirer');

if (!username) {
  console.error('usage : node server/scripts/promote-admin.mjs <nom-utilisateur> [--retirer]');
  process.exit(1);
}

const user = await prisma.user.findUnique({ where: { username } });
if (!user || user.deletedAt) {
  console.error(`compte introuvable : ${username}`);
  process.exit(1);
}

if (!retirer && !user.totpEnabledAt) {
  console.error(
    `\n${username} n'a pas activé la vérification en deux étapes.\n\n` +
      "Le garde d'administration l'exige à CHAQUE action : sans elle, un jeton\n" +
      "d'accès volé suffirait à supprimer des comptes. Active-la depuis\n" +
      "l'application (Options -> Vérification en deux étapes), puis relance.\n",
  );
  process.exit(1);
}

await prisma.user.update({
  where: { id: user.id },
  data: { role: retirer ? 'user' : 'admin' },
});

await prisma.adminAction.create({
  data: {
    actorUserId: user.id,
    action: retirer ? 'admin_revoked_via_cli' : 'admin_granted_via_cli',
    targetId: user.id,
    targetLabel: user.username,
    reason: 'exécuté depuis le serveur',
  },
});

console.log(
  retirer
    ? `${username} n'est plus administrateur.`
    : `${username} est administrateur. Rappel : ce rôle ne donne accès à aucun\n` +
        `message — le serveur ne détient aucune clé privée.`,
);
await prisma.$disconnect();
