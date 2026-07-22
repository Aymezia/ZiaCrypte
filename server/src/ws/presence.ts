import { prisma } from '../db/prisma.js';

/**
 * Autorisation de la présence (« en ligne / hors ligne »).
 *
 * ## Ce que la présence ajoute — et ce qu'elle n'ajoute pas
 *
 * Le serveur SAIT DÉJÀ quels appareils sont connectés : il tient leurs
 * WebSocket. La présence ne lui apprend donc rien de nouveau. Ce qu'elle change
 * est ce que les AUTRES apprennent — et une messagerie qui diffuserait cela
 * sans contrôle dirait à n'importe qui, sans son accord, quand telle personne
 * dort, travaille, ou revient de vacances. C'est pourquoi la diffusion est
 * doublement fermée :
 *
 * 1. **Opt-in de l'observé** : rien n'est diffusé tant que l'appareil ne l'a
 *    pas explicitement demandé (`presence.mode`). Un client qui ignore la
 *    fonctionnalité — les versions déjà installées, par exemple — reste
 *    invisible. Le défaut protège.
 * 2. **Autorisation de l'observateur** : on ne peut observer que des appareils
 *    avec qui on partage une conversation, et jamais à travers un blocage. Sans
 *    cette règle, connaître un identifiant d'appareil suffirait à pister son
 *    propriétaire.
 *
 * L'autorisation est vérifiée à l'abonnement, pas à chaque évènement : une
 * requête par abonnement, contre une par changement d'état pour tout le monde.
 * Le blocage, lui, casse les abonnements en cours immédiatement (voir
 * `RealtimeGateway.revoquerPresence`) — c'est le seul cas où l'autorisation
 * peut disparaître pendant qu'une connexion vit.
 */

/**
 * Nombre maximal d'appareils observables par connexion.
 *
 * Une borne, pas une limite fonctionnelle : 200 appareils couvrent largement
 * les correspondants d'une personne réelle, et empêchent un client de faire
 * balayer au serveur un annuaire entier à chaque abonnement.
 */
export const MAX_ABONNEMENTS = 200;

/**
 * Filtre les appareils que cet utilisateur a le droit de voir apparaître.
 *
 * Renvoie le sous-ensemble autorisé de `deviceIds`. Un appareil inconnu,
 * désactivé, sans conversation commune ou concerné par un blocage — dans un
 * sens comme dans l'autre — est simplement absent du résultat : le demandeur
 * n'apprend pas POURQUOI, et ne peut donc pas distinguer « cet appareil
 * n'existe pas » de « cette personne m'a bloqué ».
 */
export async function autoriserObservation(
  observateurUserId: string,
  deviceIds: string[],
): Promise<Set<string>> {
  if (deviceIds.length === 0) return new Set();

  const cibles = await prisma.device.findMany({
    where: { id: { in: deviceIds }, isActive: true },
    select: { id: true, userId: true },
  });
  if (cibles.length === 0) return new Set();

  // Ses propres appareils sont toujours observables : savoir que son téléphone
  // est en ligne ne révèle rien à personne d'autre.
  const autres = [...new Set(cibles.map((c) => c.userId))].filter(
    (u) => u !== observateurUserId,
  );

  const autorisesUsers = new Set<string>();
  if (autres.length > 0) {
    const miennes = await prisma.conversationParticipant.findMany({
      where: { userId: observateurUserId, leftAt: null },
      select: { conversationId: true },
    });
    if (miennes.length > 0) {
      const communs = await prisma.conversationParticipant.findMany({
        where: {
          conversationId: { in: miennes.map((m) => m.conversationId) },
          userId: { in: autres },
          leftAt: null,
        },
        select: { userId: true },
        distinct: ['userId'],
      });
      for (const c of communs) autorisesUsers.add(c.userId);
    }

    // Un blocage coupe la présence dans les DEUX sens. Le contraire serait un
    // aveu : la personne bloquée verrait l'autre disparaître d'un coup et pour
    // toujours, ce qui dit exactement ce qu'un blocage doit taire.
    const blocages = await prisma.block.findMany({
      where: {
        OR: [
          { blockerUserId: observateurUserId, blockedUserId: { in: autres } },
          { blockedUserId: observateurUserId, blockerUserId: { in: autres } },
        ],
      },
      select: { blockerUserId: true, blockedUserId: true },
    });
    for (const b of blocages) {
      autorisesUsers.delete(
        b.blockerUserId === observateurUserId ? b.blockedUserId : b.blockerUserId,
      );
    }
  }

  return new Set(
    cibles
      .filter((c) => c.userId === observateurUserId || autorisesUsers.has(c.userId))
      .map((c) => c.id),
  );
}

/**
 * Appareils de deux comptes, séparés par propriétaire.
 *
 * Sert à casser les abonnements croisés au moment d'un blocage. La passerelle
 * ne connaît que des identifiants d'appareils ; c'est ici — et pas dans le
 * temps réel — que l'on touche à la base.
 */
export async function appareilsDeDeuxComptes(
  userA: string,
  userB: string,
): Promise<{ a: Set<string>; b: Set<string> }> {
  const appareils = await prisma.device.findMany({
    where: { userId: { in: [userA, userB] } },
    select: { id: true, userId: true },
  });
  return {
    a: new Set(appareils.filter((d) => d.userId === userA).map((d) => d.id)),
    b: new Set(appareils.filter((d) => d.userId === userB).map((d) => d.id)),
  };
}
