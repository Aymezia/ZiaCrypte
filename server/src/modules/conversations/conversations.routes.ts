import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../db/prisma.js';
import { HttpError } from '../../lib/errors.js';
import { requireAuth } from '../../plugins/auth.js';

const createSchema = z.object({
  type: z.enum(['direct', 'group']).default('direct'),
  participantIds: z.array(z.string().uuid()).min(1),
});

export async function conversationsRoutes(app: FastifyInstance) {
  // Crée une conversation avec l'utilisateur courant + les participants indiqués.
  app.post('/conversations', { preHandler: requireAuth }, async (request, reply) => {
    const body = createSchema.parse(request.body);
    const me = request.auth!.userId;
    const participantIds = Array.from(new Set([me, ...body.participantIds]));

    // Tous les participants doivent exister.
    const count = await prisma.user.count({ where: { id: { in: participantIds } } });
    if (count !== participantIds.length) throw new HttpError(400, 'participant inconnu');

    // Une conversation directe entre deux personnes est unique : on renvoie
    // l'existante plutôt que d'en créer une nouvelle à chaque ouverture. Sans
    // cela son identifiant changerait à chaque fois, et l'historique local
    // rattaché à cet identifiant serait perdu.
    if (body.type === 'direct' && participantIds.length === 2) {
      // Un `every` seul ne convient pas : il est vrai par vacuité sur une
      // conversation SANS participant (il en reste après la suppression des
      // comptes concernés). findFirst en renvoyait une, le contrôle de taille
      // échouait, et une conversation en double était créée alors qu'une
      // valide existait — l'historique local rattaché à l'ancien identifiant
      // devenait alors inaccessible.
      //
      // On exige donc explicitement la présence de CHAQUE participant, et
      // exactement deux au total pour exclure un groupe qui les contiendrait.
      const candidates = await prisma.conversation.findMany({
        where: {
          type: 'direct',
          AND: participantIds.map((userId) => ({
            participants: { some: { userId } },
          })),
        },
        include: { participants: true },
        orderBy: { createdAt: 'asc' },
      });
      const existing = candidates.find((c) => c.participants.length === 2);
      if (existing) {
        return reply.code(200).send({ id: existing.id, type: existing.type });
      }
    }

    const conversation = await prisma.conversation.create({
      data: {
        type: body.type,
        createdBy: me,
        participants: {
          create: participantIds.map((userId) => ({
            userId,
            role: userId === me ? 'admin' : 'member',
          })),
        },
      },
    });

    return reply.code(201).send({ id: conversation.id, type: conversation.type });
  });

  // Liste les conversations de l'utilisateur courant.
  app.get('/conversations', { preHandler: requireAuth }, async (request) => {
    const rows = await prisma.conversationParticipant.findMany({
      where: { userId: request.auth!.userId, leftAt: null },
      include: { conversation: true },
      orderBy: { joinedAt: 'desc' },
    });
    return rows.map((r) => ({
      id: r.conversationId,
      type: r.conversation.type,
      joinedAt: r.joinedAt,
    }));
  });
}
