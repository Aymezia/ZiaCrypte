import { prisma } from '../../db/prisma.js';
import { HttpError } from '../../lib/errors.js';

/**
 * Contrôle d'appartenance à une conversation.
 *
 * Centralisé parce qu'il était dupliqué à trois endroits, et que les trois
 * partageaient le même défaut : ils testaient la seule présence d'une ligne,
 * sans regarder `leftAt`. Quitter un groupe ou en être retiré laisse la ligne
 * en place — c'est voulu, elle porte l'historique d'adhésion — si bien qu'un
 * membre exclu conservait le droit d'écrire au groupe.
 *
 * Une seule fonction, donc une seule règle à vérifier et à corriger.
 */
export async function requireMembership(conversationId: string, userId: string) {
  const participant = await prisma.conversationParticipant.findUnique({
    where: { conversationId_userId: { conversationId, userId } },
  });
  if (!participant || participant.leftAt !== null) {
    throw new HttpError(403, 'non membre de la conversation');
  }
  return participant;
}

/** Comme ci-dessus, en exigeant en plus le rôle d'administrateur. */
export async function requireAdmin(conversationId: string, userId: string) {
  const participant = await requireMembership(conversationId, userId);
  if (participant.role !== 'admin') {
    throw new HttpError(403, 'réservé aux administrateurs du groupe');
  }
  return participant;
}

/** Membres actifs d'une conversation. */
export async function activeMembers(conversationId: string) {
  return prisma.conversationParticipant.findMany({
    where: { conversationId, leftAt: null },
    include: { user: true },
    orderBy: { joinedAt: 'asc' },
  });
}
