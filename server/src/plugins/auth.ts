import type { FastifyReply, FastifyRequest } from 'fastify';
import { prisma } from '../db/prisma.js';
import { verifyAccess } from '../lib/tokens.js';

declare module 'fastify' {
  interface FastifyRequest {
    auth?: { userId: string; deviceId: string };
  }
}

/**
 * preHandler d'authentification : exige un access token Bearer valide, vérifie
 * que l'appareil est toujours actif, puis renseigne `request.auth`.
 *
 * ## Pourquoi interroger la base à chaque requête
 *
 * Un access token est signé pour quinze minutes et n'est révocable par aucun
 * moyen cryptographique : une fois émis, il reste valide jusqu'à expiration.
 * Se contenter d'en vérifier la signature laissait un appareil révoqué lire
 * pendant un quart d'heure — c'est-à-dire faisait de la révocation un bouton
 * décoratif, précisément dans le cas où elle sert : un appareil qu'on ne
 * contrôle plus.
 *
 * Le coût est une recherche par clé primaire, très en deçà de ce que coûte
 * déjà n'importe quelle route utile.
 */
export async function requireAuth(request: FastifyRequest, reply: FastifyReply) {
  const header = request.headers.authorization;
  if (!header?.startsWith('Bearer ')) {
    return reply.code(401).send({ error: 'jeton d’accès manquant' });
  }

  let claims: ReturnType<typeof verifyAccess>;
  try {
    claims = verifyAccess(header.slice('Bearer '.length));
  } catch {
    return reply.code(401).send({ error: 'jeton d’accès invalide ou expiré' });
  }

  const device = await prisma.device.findUnique({
    where: { id: claims.did },
    select: { isActive: true, userId: true, lastSeenAt: true },
  });
  if (!device || !device.isActive || device.userId !== claims.sub) {
    // Code distinct de « jeton invalide » : le client doit pouvoir dire à son
    // porteur ce qui s'est passé, au lieu de boucler sur un rafraîchissement
    // qui échouera tout autant.
    return reply
      .code(401)
      .send({ error: 'cet appareil a été révoqué', code: 'device_revoked' });
  }

  // « Dernière activité » n'a de valeur que si elle reflète l'usage réel : mise
  // à jour à la seule connexion, elle affichait une date vieille de plusieurs
  // jours pour un appareil actif en permanence — inutilisable pour repérer un
  // intrus. Écriture espacée d'au moins cinq minutes : la précision utile ici
  // se compte en heures, pas en secondes.
  const ecoule = Date.now() - device.lastSeenAt.getTime();
  if (ecoule > 5 * 60 * 1000) {
    prisma.device
      .update({ where: { id: claims.did }, data: { lastSeenAt: new Date() } })
      // Détaché : l'horodatage est du confort, il ne doit jamais faire échouer
      // la requête qui l'a déclenché.
      .catch(() => {});
  }

  request.auth = { userId: claims.sub, deviceId: claims.did };
}
