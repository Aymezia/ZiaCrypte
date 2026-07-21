import type { FastifyReply, FastifyRequest } from 'fastify';
import { prisma } from '../db/prisma.js';
import { verifyTotp } from '../lib/totp.js';
import { HttpError } from '../lib/errors.js';

/**
 * Garde d'accès aux routes d'administration.
 *
 * ## Ce qu'un administrateur PEUT faire
 *
 * Consulter des métadonnées de comptes, supprimer un compte, et émettre un
 * jeton de réinitialisation de mot de passe à la demande de son titulaire.
 *
 * ## Ce qu'il ne peut PAS faire, et ce n'est pas une politique mais un fait
 *
 * Lire un message. Aucune route d'administration ne renvoie de contenu, et
 * surtout : le serveur ne détient aucune clé privée. Même en écrivant une route
 * qui renverrait les blobs, ils resteraient indéchiffrables. Le pouvoir de
 * l'administrateur s'arrête là où commence le chiffrement de bout en bout.
 *
 * ## Le piège qu'on ferme ici
 *
 * Le vrai risque n'est pas la lecture, c'est la PRISE DE CONTRÔLE : qui peut
 * changer un mot de passe peut se connecter, puis rattacher un appareil — et
 * un appareil rattaché reçoit les messages À VENIR. C'est pourquoi
 * l'administrateur ne fixe jamais de mot de passe : il émet un jeton que seul
 * l'utilisateur peut échanger contre le mot de passe de son choix. Le serveur
 * n'apprend rien, l'administrateur non plus.
 *
 * ## Élévation à chaque action
 *
 * Le second facteur est exigé À CHAQUE requête d'administration, pas seulement
 * à la connexion. Un jeton d'accès volé à un administrateur ne suffit donc pas :
 * il faudrait aussi son générateur de codes. C'est la contrepartie normale d'un
 * compte qui peut supprimer les comptes des autres.
 */
export async function requireAdmin(request: FastifyRequest, reply: FastifyReply) {
  const auth = request.auth;
  if (!auth) {
    return reply.code(401).send({ error: 'authentification requise' });
  }

  const user = await prisma.user.findUnique({
    where: { id: auth.userId },
    select: { role: true, totpSecret: true, totpEnabledAt: true, deletedAt: true },
  });

  // Réponse volontairement identique pour « pas administrateur » et « compte
  // inconnu » : une réponse différente permettrait d'énumérer les comptes
  // d'administration, qui sont la cible la plus rentable du système.
  if (!user || user.deletedAt || user.role !== 'admin') {
    return reply.code(404).send({ error: 'ressource introuvable' });
  }

  if (!user.totpEnabledAt || !user.totpSecret) {
    throw new HttpError(
      403,
      'la vérification en deux étapes est obligatoire pour un compte d’administration',
    );
  }

  const code = request.headers['x-admin-totp'];
  if (typeof code !== 'string' || !verifyTotp(user.totpSecret, code)) {
    throw new HttpError(403, 'code de vérification requis pour cette action');
  }
}

/**
 * Inscrit une action d'administration au journal.
 *
 * Sans clé étrangère vers le compte visé : la trace doit survivre à sa
 * suppression, sinon supprimer un compte effacerait la preuve qu'on l'a
 * supprimé. `targetLabel` conserve le nom d'utilisateur pour la même raison.
 */
export async function journaliser(
  actorUserId: string,
  action: string,
  cible?: { id?: string; label?: string; reason?: string },
) {
  await prisma.adminAction.create({
    data: {
      actorUserId,
      action,
      targetId: cible?.id ?? null,
      targetLabel: cible?.label ?? null,
      reason: cible?.reason ?? null,
    },
  });
}
