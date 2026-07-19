import argon2 from 'argon2';
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

  // Suppression du compte. Les appareils, prekeys, sessions et blobs en
  // attente disparaissent en cascade ; l'historique local, lui, reste sur les
  // appareils (il est chiffré et n'a jamais transité par le serveur).
  app.delete('/users/me', { preHandler: requireAuth }, async (request, reply) => {
    const { password } = z
      .object({ password: z.string() })
      .parse(request.body ?? {});

    const user = await prisma.user.findUnique({ where: { id: request.auth!.userId } });
    if (!user?.passwordHash) throw new HttpError(404, 'utilisateur introuvable');

    // On redemande le mot de passe : un jeton volé ne doit pas suffire à
    // détruire un compte.
    const valid = await argon2.verify(user.passwordHash, password).catch(() => false);
    if (!valid) throw new HttpError(401, 'mot de passe invalide');

    await prisma.user.delete({ where: { id: user.id } });
    return reply.code(204).send();
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
