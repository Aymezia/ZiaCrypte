import argon2 from 'argon2';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../db/prisma.js';
import { HttpError } from '../../lib/errors.js';
import { hashToken, verifyRefresh } from '../../lib/tokens.js';
import { createDevice, deviceRegistrationSchema } from '../devices/device.schema.js';
import { createSession } from './auth.service.js';
import { passwordRateLimit, registrationRateLimit } from '../../plugins/rate-limit.js';

/* Hash factice : on vérifie toujours un mot de passe, même si le compte
   n'existe pas, pour ne pas révéler son existence par le temps de réponse. */
const INVALID_HASH =
  '$argon2id$v=19$m=65536,t=3,p=4$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

const registerSchema = z.object({
  username: z.string().min(3).max(64),
  password: z.string().min(8).max(256),
  device: deviceRegistrationSchema,
});

const loginSchema = z.object({
  username: z.string(),
  password: z.string(),
  deviceId: z.string().uuid(),
});

const addDeviceSchema = z.object({
  username: z.string(),
  password: z.string(),
  device: deviceRegistrationSchema,
});

const refreshSchema = z.object({
  refreshToken: z.string(),
});

export async function authRoutes(app: FastifyInstance) {
  app.post('/auth/register', { config: registrationRateLimit() }, async (request, reply) => {
    const body = registerSchema.parse(request.body);

    const existing = await prisma.user.findUnique({ where: { username: body.username } });
    if (existing) throw new HttpError(409, 'nom d’utilisateur déjà pris');

    const passwordHash = await argon2.hash(body.password, { type: argon2.argon2id });

    const device = await prisma.$transaction(async (tx) => {
      const user = await tx.user.create({
        data: { username: body.username, displayName: body.username, passwordHash },
      });
      return createDevice(tx, user.id, body.device);
    });

    const tokens = await createSession(device.userId, device.id);
    return reply.code(201).send({ userId: device.userId, deviceId: device.id, ...tokens });
  });

  app.post('/auth/login', { config: passwordRateLimit() }, async (request, reply) => {
    const body = loginSchema.parse(request.body);

    const user = await prisma.user.findUnique({ where: { username: body.username } });
    // Vérifie toujours un hash (même si l'utilisateur n'existe pas) pour ne pas
    // révéler l'existence du compte par le temps de réponse.
    const hash = user?.passwordHash ?? INVALID_HASH;
    const valid = await argon2.verify(hash, body.password).catch(() => false);
    if (!user || !valid) throw new HttpError(401, 'identifiants invalides');

    const device = await prisma.device.findUnique({ where: { id: body.deviceId } });
    if (!device || device.userId !== user.id || !device.isActive) {
      throw new HttpError(404, 'appareil introuvable');
    }

    await prisma.device.update({
      where: { id: device.id },
      data: { lastSeenAt: new Date() },
    });

    const tokens = await createSession(user.id, device.id);
    return reply.send({ userId: user.id, deviceId: device.id, ...tokens });
  });

  // Rattache un NOUVEL appareil à un compte existant : c'est ce qui permet
  // d'utiliser le même compte sur plusieurs machines. L'appareil génère sa
  // propre identité — aucune clé privée ne circule entre appareils.
  app.post('/auth/add-device', { config: passwordRateLimit() }, async (request, reply) => {
    const body = addDeviceSchema.parse(request.body);

    const user = await prisma.user.findUnique({ where: { username: body.username } });
    const hash = user?.passwordHash ?? INVALID_HASH;
    const valid = await argon2.verify(hash, body.password).catch(() => false);
    if (!user || !valid) throw new HttpError(401, 'identifiants invalides');

    const device = await prisma.$transaction((tx) =>
      createDevice(tx, user.id, body.device),
    );

    const tokens = await createSession(user.id, device.id);
    return reply.code(201).send({ userId: user.id, deviceId: device.id, ...tokens });
  });

  app.post('/auth/refresh', async (request, reply) => {
    const body = refreshSchema.parse(request.body);

    let claims: ReturnType<typeof verifyRefresh>;
    try {
      claims = verifyRefresh(body.refreshToken);
    } catch {
      throw new HttpError(401, 'refresh token invalide ou expiré');
    }

    const session = await prisma.authSession.findFirst({
      where: {
        userId: claims.sub,
        deviceId: claims.did,
        refreshTokenHash: hashToken(body.refreshToken),
        revokedAt: null,
        expiresAt: { gt: new Date() },
      },
    });
    if (!session) throw new HttpError(401, 'session révoquée ou expirée');

    // Rotation : la session précédente est révoquée, une nouvelle est émise.
    await prisma.authSession.update({
      where: { id: session.id },
      data: { revokedAt: new Date() },
    });
    const tokens = await createSession(claims.sub, claims.did);
    return reply.send({ userId: claims.sub, deviceId: claims.did, ...tokens });
  });
}
