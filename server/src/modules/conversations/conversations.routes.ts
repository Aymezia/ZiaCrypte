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
