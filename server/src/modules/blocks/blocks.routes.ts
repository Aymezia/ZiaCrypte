import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../db/prisma.js';
import { HttpError } from '../../lib/errors.js';
import { requireAuth } from '../../plugins/auth.js';
import { gateway } from '../../ws/gateway.js';

/**
 * Blocage de comptes.
 *
 * Le serveur ne peut pas lire les messages, mais il sait qui écrit à qui —
 * c'est exactement ce qu'il faut pour refuser une remise. Un blocage qui ne
 * vivrait que dans l'application laisserait la personne bloquée déposer des
 * blobs, consommer du stockage, et voir ses messages marqués « remis ».
 */
export async function blocksRoutes(app: FastifyInstance) {
  /** Comptes bloqués par l'utilisateur courant. */
  app.get('/blocks', { preHandler: requireAuth }, async (request) => {
    const blocks = await prisma.block.findMany({
      where: { blockerUserId: request.auth!.userId },
      orderBy: { createdAt: 'desc' },
      select: {
        blockedUserId: true,
        createdAt: true,
        blocked: { select: { username: true } },
      },
    });
    return blocks.map((b) => ({
      userId: b.blockedUserId,
      username: b.blocked.username,
      depuis: b.createdAt.toISOString(),
    }));
  });

  app.post('/blocks', { preHandler: requireAuth }, async (request, reply) => {
    const { userId } = z
      .object({ userId: z.string().uuid() })
      .parse(request.body);
    const me = request.auth!.userId;

    if (userId === me) throw new HttpError(400, 'on ne se bloque pas soi-même');

    const cible = await prisma.user.findUnique({ where: { id: userId } });
    if (!cible || cible.deletedAt) throw new HttpError(404, 'compte introuvable');

    // Idempotent : rebloquer quelqu'un déjà bloqué ne doit pas produire
    // d'erreur, le client peut légitimement réémettre.
    await prisma.block.upsert({
      where: { blockerUserId_blockedUserId: { blockerUserId: me, blockedUserId: userId } },
      create: { blockerUserId: me, blockedUserId: userId },
      update: {},
    });

    // La présence est autorisée une fois pour toutes à l'abonnement : sans
    // cette coupure, les deux comptes continueraient de se voir « en ligne »
    // jusqu'à leur prochaine reconnexion.
    await gateway?.revoquerPresence(me, userId);

    return reply.code(204).send();
  });

  app.delete('/blocks/:userId', { preHandler: requireAuth }, async (request, reply) => {
    const { userId } = z
      .object({ userId: z.string().uuid() })
      .parse(request.params);
    await prisma.block.deleteMany({
      where: { blockerUserId: request.auth!.userId, blockedUserId: userId },
    });
    return reply.code(204).send();
  });
}

/**
 * Le destinataire a-t-il bloqué l'expéditeur ?
 *
 * Consulté à chaque dépôt de message. Une recherche par clé primaire, dont le
 * coût est sans commune mesure avec celui du stockage d'un blob qui ne sera
 * jamais lu.
 */
export async function estBloque(
  expediteurUserId: string,
  destinataireUserId: string,
): Promise<boolean> {
  const b = await prisma.block.findUnique({
    where: {
      blockerUserId_blockedUserId: {
        blockerUserId: destinataireUserId,
        blockedUserId: expediteurUserId,
      },
    },
    select: { createdAt: true },
  });
  return b !== null;
}
