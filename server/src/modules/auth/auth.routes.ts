import argon2 from 'argon2';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../db/prisma.js';
import { HttpError } from '../../lib/errors.js';
import { hashToken, verifyRefresh } from '../../lib/tokens.js';
import { createDevice, deviceRegistrationSchema } from '../devices/device.schema.js';
import { createSession } from './auth.service.js';
import { generateSecret, otpauthUri, verifyTotp } from '../../lib/totp.js';
import { requireAuth } from '../../plugins/auth.js';
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
  totp: z.string().optional(),
});

const addDeviceSchema = z.object({
  username: z.string(),
  password: z.string(),
  device: deviceRegistrationSchema,
  totp: z.string().optional(),
});

/** Erreur signalant au client qu'un second facteur est requis. */
const TOTP_REQUIRED = 'TOTP_REQUIRED';

/**
 * Exige le second facteur si le compte l'a activé.
 *
 * Renvoie un code distinct (428) quand le mot de passe est bon mais qu'aucun
 * code n'a été fourni : le client sait alors qu'il doit le demander, sans que
 * cette réponse aide un attaquant qui ignore le mot de passe (il ne l'atteint
 * qu'après l'avoir validé).
 */
function assertSecondFactor(
  user: { totpSecret: string | null; totpEnabledAt: Date | null },
  code: string | undefined,
) {
  if (!user.totpEnabledAt || !user.totpSecret) return;
  if (!code) throw new HttpError(428, TOTP_REQUIRED);
  if (!verifyTotp(user.totpSecret, code)) {
    throw new HttpError(401, 'code de vérification invalide');
  }
}

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
    return reply.code(201).send({ userId: device.userId, deviceId: device.id, role: 'user', ...tokens });
  });

  app.post('/auth/login', { config: passwordRateLimit() }, async (request, reply) => {
    const body = loginSchema.parse(request.body);

    const user = await prisma.user.findUnique({ where: { username: body.username } });
    // Vérifie toujours un hash (même si l'utilisateur n'existe pas) pour ne pas
    // révéler l'existence du compte par le temps de réponse.
    const hash = user?.passwordHash ?? INVALID_HASH;
    const valid = await argon2.verify(hash, body.password).catch(() => false);
    if (!user || !valid) throw new HttpError(401, 'identifiants invalides');

    // Mot de passe validé : on peut exiger le second facteur sans rien révéler
    // à qui ignore le mot de passe.
    assertSecondFactor(user, body.totp);

    const device = await prisma.device.findUnique({ where: { id: body.deviceId } });
    if (!device || device.userId !== user.id || !device.isActive) {
      throw new HttpError(404, 'appareil introuvable');
    }

    await prisma.device.update({
      where: { id: device.id },
      data: { lastSeenAt: new Date() },
    });

    const tokens = await createSession(user.id, device.id);
    return reply.send({ userId: user.id, deviceId: device.id, role: user.role, ...tokens });
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

    // Ajouter un appareil est une action sensible : le second facteur s'y
    // applique aussi. Sans cela, un mot de passe volé suffirait à s'attacher.
    assertSecondFactor(user, body.totp);

    const device = await prisma.$transaction((tx) =>
      createDevice(tx, user.id, body.device),
    );

    const tokens = await createSession(user.id, device.id);
    return reply.code(201).send({ userId: user.id, deviceId: device.id, role: user.role, ...tokens });
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
    // Le rôle est relu ici : la session ne le stocke pas, et le client en a
    // besoin pour (ré)afficher l'entrée d'administration après un rafraîchissement.
    const compte = await prisma.user.findUnique({
      where: { id: claims.sub },
      select: { role: true },
    });
    return reply.send({ userId: claims.sub, deviceId: claims.did, role: compte?.role ?? 'user', ...tokens });
  });

  // ----------------------------------------------------- second facteur (TOTP)

  /** État du second facteur pour le compte courant. */
  app.get('/auth/2fa', { preHandler: requireAuth }, async (request) => {
    const user = await prisma.user.findUnique({ where: { id: request.auth!.userId } });
    return { enabled: user?.totpEnabledAt != null };
  });

  /**
   * Démarre l'enrôlement : génère un secret et renvoie l'URI otpauth à scanner.
   *
   * Le secret est stocké mais le 2FA n'est PAS encore actif — il ne le devient
   * qu'après confirmation par un premier code (/auth/2fa/enable). Sans ça, un
   * utilisateur pourrait s'enfermer dehors en cas d'erreur de configuration de
   * son application d'authentification.
   *
   * Refusé si le 2FA est déjà actif : le réactiver écraserait le secret en
   * service et invaliderait l'application déjà configurée.
   */
  app.post('/auth/2fa/setup', { preHandler: requireAuth }, async (request, reply) => {
    const user = await prisma.user.findUnique({ where: { id: request.auth!.userId } });
    if (!user) throw new HttpError(404, 'utilisateur introuvable');
    if (user.totpEnabledAt) throw new HttpError(409, 'le second facteur est déjà actif');

    const secret = generateSecret();
    await prisma.user.update({
      where: { id: user.id },
      data: { totpSecret: secret, totpEnabledAt: null },
    });

    return reply.send({
      secret,
      otpauthUri: otpauthUri(secret, user.username),
    });
  });

  /** Confirme l'enrôlement avec un premier code, et active le 2FA. */
  app.post('/auth/2fa/enable', { preHandler: requireAuth }, async (request, reply) => {
    const { code } = z.object({ code: z.string() }).parse(request.body);
    const user = await prisma.user.findUnique({ where: { id: request.auth!.userId } });
    if (!user?.totpSecret) throw new HttpError(400, 'commence par /auth/2fa/setup');
    if (user.totpEnabledAt) throw new HttpError(409, 'déjà actif');

    if (!verifyTotp(user.totpSecret, code)) {
      throw new HttpError(401, 'code invalide — vérifie l’heure de ton téléphone');
    }
    await prisma.user.update({
      where: { id: user.id },
      data: { totpEnabledAt: new Date() },
    });
    return reply.send({ enabled: true });
  });

  /**
   * Désactive le second facteur. Exige le mot de passe ET un code courant :
   * ni un jeton volé, ni le seul accès à l'application d'authentification ne
   * doivent suffire à retirer cette protection.
   */
  app.post('/auth/2fa/disable', { preHandler: requireAuth }, async (request, reply) => {
    const { password, code } = z
      .object({ password: z.string(), code: z.string() })
      .parse(request.body);
    const user = await prisma.user.findUnique({ where: { id: request.auth!.userId } });
    if (!user?.passwordHash) throw new HttpError(404, 'utilisateur introuvable');
    if (!user.totpEnabledAt || !user.totpSecret) {
      throw new HttpError(400, 'le second facteur n’est pas actif');
    }

    const valid = await argon2.verify(user.passwordHash, password).catch(() => false);
    if (!valid) throw new HttpError(401, 'mot de passe invalide');
    if (!verifyTotp(user.totpSecret, code)) throw new HttpError(401, 'code invalide');

    await prisma.user.update({
      where: { id: user.id },
      data: { totpSecret: null, totpEnabledAt: null },
    });
    return reply.send({ enabled: false });
  });
}
