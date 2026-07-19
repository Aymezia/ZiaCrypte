import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../db/prisma.js';
import { HttpError } from '../../lib/errors.js';
import { requireAuth } from '../../plugins/auth.js';
import { activeMembers, requireAdmin, requireMembership } from './membership.js';

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

  /**
   * Membres actifs d'une conversation.
   *
   * Le client en a besoin pour diffuser : chaque message de groupe est chiffré
   * séparément pour chaque appareil de chaque membre. Réservé aux membres —
   * la composition d'un groupe est une information en soi.
   */
  app.get('/conversations/:id/members', { preHandler: requireAuth }, async (request) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    await requireMembership(id, request.auth!.userId);

    const membres = await activeMembers(id);
    return membres.map((m) => ({
      userId: m.userId,
      username: m.user.username,
      role: m.role,
      joinedAt: m.joinedAt,
    }));
  });

  /**
   * Ajoute un membre à un groupe. Réservé aux administrateurs.
   *
   * Le serveur ne transmet AUCUN historique au nouvel arrivant : il ne le
   * pourrait pas, ne détenant que du chiffré dont il n'a pas les clés. Le
   * nouveau membre ne verra que les messages postérieurs à son arrivée.
   */
  app.post('/conversations/:id/members', { preHandler: requireAuth }, async (request, reply) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    const body = z.object({ userId: z.string().uuid() }).parse(request.body);

    const conversation = await prisma.conversation.findUnique({ where: { id } });
    if (!conversation) throw new HttpError(404, 'conversation introuvable');
    if (conversation.type !== 'group') {
      throw new HttpError(400, 'une conversation directe a exactement deux membres');
    }
    await requireAdmin(id, request.auth!.userId);

    const cible = await prisma.user.findUnique({ where: { id: body.userId } });
    if (!cible) throw new HttpError(404, 'utilisateur introuvable');

    // Un ancien membre revient : on réactive sa ligne plutôt que d'en créer une
    // seconde, la clé primaire étant (conversation, utilisateur).
    await prisma.conversationParticipant.upsert({
      where: { conversationId_userId: { conversationId: id, userId: body.userId } },
      create: { conversationId: id, userId: body.userId, role: 'member' },
      update: { leftAt: null, joinedAt: new Date() },
    });

    return reply.code(201).send({ userId: body.userId });
  });

  /**
   * Retire un membre, ou quitte le groupe soi-même.
   *
   * La ligne n'est pas supprimée mais marquée : elle porte l'historique
   * d'adhésion, et les contrôles d'appartenance regardent `leftAt`. Sans cela
   * un membre exclu garderait le droit d'écrire au groupe.
   */
  app.delete('/conversations/:id/members/:userId', { preHandler: requireAuth }, async (request, reply) => {
    const { id, userId } = z
      .object({ id: z.string().uuid(), userId: z.string().uuid() })
      .parse(request.params);
    const me = request.auth!.userId;

    // On peut toujours partir de soi-même ; retirer quelqu'un d'autre exige
    // d'être administrateur.
    if (userId === me) {
      await requireMembership(id, me);
    } else {
      await requireAdmin(id, me);
    }

    await prisma.conversationParticipant.update({
      where: { conversationId_userId: { conversationId: id, userId } },
      data: { leftAt: new Date() },
    });

    return reply.code(204).send();
  });
}
