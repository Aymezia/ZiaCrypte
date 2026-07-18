import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../db/prisma.js';
import { HttpError } from '../../lib/errors.js';
import { requireAuth } from '../../plugins/auth.js';

export async function usersRoutes(app: FastifyInstance) {
  // Recherche d'un correspondant par pseudo, pour démarrer une conversation.
  // Ne renvoie que des informations publiques.
  app.get('/users/lookup', { preHandler: requireAuth }, async (request) => {
    const { username } = z
      .object({ username: z.string().min(1) })
      .parse(request.query);

    const user = await prisma.user.findUnique({ where: { username } });
    if (!user || user.deletedAt) throw new HttpError(404, 'utilisateur introuvable');

    return { id: user.id, username: user.username, displayName: user.displayName };
  });

  // Profil de l'utilisateur courant.
  app.get('/users/me', { preHandler: requireAuth }, async (request) => {
    const user = await prisma.user.findUnique({ where: { id: request.auth!.userId } });
    if (!user) throw new HttpError(404, 'utilisateur introuvable');
    return {
      id: user.id,
      username: user.username,
      displayName: user.displayName,
      deviceId: request.auth!.deviceId,
    };
  });
}
