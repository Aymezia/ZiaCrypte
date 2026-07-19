import { randomBytes, randomUUID } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { afterAll, beforeAll, describe, expect, test } from 'vitest';
import { buildApp } from '../src/app.js';
import { prisma } from '../src/db/prisma.js';
import { purgeExpired } from '../src/modules/retention/retention.service.js';

const key = (n: number) => randomBytes(n).toString('base64');
const bytes = (n: number) => new Uint8Array(randomBytes(n));
const device = () => ({
  platform: 'linux',
  identityPublicKey: key(32),
  signedPrekey: key(32),
  signedPrekeySignature: key(64),
  oneTimePrekeys: [key(32)],
});

const PREFIX = 'ret_t';
let app: FastifyInstance;
let counter = 0;

async function register(label: string) {
  const res = await app.inject({
    method: 'POST',
    url: '/v1/auth/register',
    payload: {
      username: `${PREFIX}_${label}_${counter++}`,
      password: 'password123',
      device: device(),
    },
  });
  expect(res.statusCode).toBe(201);
  return res.json() as { accessToken: string; userId: string; deviceId: string };
}

/** Dépose un blob directement, pour maîtriser ses dates. */
async function blob(opts: {
  conversationId: string;
  from: string;
  to: string;
  deliveredAt?: Date | null;
  expiresAt: Date;
}) {
  return prisma.messageBlob.create({
    data: {
      conversationId: opts.conversationId,
      senderDeviceId: opts.from,
      recipientDeviceId: opts.to,
      clientMessageId: randomUUID(),
      ratchetHeader: bytes(48),
      ciphertext: bytes(64),
      deliveredAt: opts.deliveredAt ?? null,
      expiresAt: opts.expiresAt,
    },
  });
}

const jours = (n: number) => new Date(Date.now() + n * 24 * 3600 * 1000);
const heures = (n: number) => new Date(Date.now() + n * 3600 * 1000);

beforeAll(async () => {
  app = await buildApp();
  await app.ready();
});

afterAll(async () => {
  await prisma.user.deleteMany({ where: { username: { startsWith: PREFIX } } });
  await app.close();
  await prisma.$disconnect();
});

/**
 * Toutes les tables portaient une date d'expiration que rien ne lisait. Une
 * promesse de rétention que personne n'applique n'est pas une promesse : le
 * chiffré restait indéfiniment, avec ses métadonnées — qui a écrit à qui, et
 * quand — que le chiffrement de bout en bout ne protège pas.
 */
describe('purge des données expirées', () => {
  test('supprime ce qui a expiré, garde ce qui est encore vivant', async () => {
    const alice = await register('alice');
    const bob = await register('bob');

    const conv = await app.inject({
      method: 'POST',
      url: '/v1/conversations',
      headers: { authorization: `Bearer ${alice.accessToken}` },
      payload: { type: 'direct', participantIds: [bob.userId] },
    });
    const conversationId = conv.json().id as string;

    const vivant = await blob({
      conversationId,
      from: alice.deviceId,
      to: bob.deviceId,
      expiresAt: jours(30),
    });
    const perime = await blob({
      conversationId,
      from: alice.deviceId,
      to: bob.deviceId,
      expiresAt: jours(-1),
    });
    const livreRecemment = await blob({
      conversationId,
      from: alice.deviceId,
      to: bob.deviceId,
      deliveredAt: heures(-1),
      expiresAt: jours(30),
    });
    const livreAncien = await blob({
      conversationId,
      from: alice.deviceId,
      to: bob.deviceId,
      deliveredAt: heures(-48),
      expiresAt: jours(30),
    });

    await purgeExpired();

    const reste = async (id: string) =>
      (await prisma.messageBlob.findUnique({ where: { id } })) !== null;

    // Ce qui doit rester.
    expect(await reste(vivant.id)).toBe(true);
    expect(await reste(livreRecemment.id)).toBe(true);

    // Ce qui doit partir.
    expect(await reste(perime.id)).toBe(false);
    expect(await reste(livreAncien.id)).toBe(false);
  });

  test('un blob relevé par son destinataire finit par être effacé', async () => {
    const alice = await register('alice');
    const bob = await register('bob');

    const conv = await app.inject({
      method: 'POST',
      url: '/v1/conversations',
      headers: { authorization: `Bearer ${alice.accessToken}` },
      payload: { type: 'direct', participantIds: [bob.userId] },
    });

    const envoi = await app.inject({
      method: 'POST',
      url: '/v1/messages',
      headers: { authorization: `Bearer ${alice.accessToken}` },
      payload: {
        conversationId: conv.json().id,
        recipientDeviceId: bob.deviceId,
        clientMessageId: randomUUID(),
        header: key(48),
        ciphertext: key(64),
      },
    });
    expect(envoi.statusCode).toBe(201);
    const blobId = envoi.json().id as string;

    // Bob relève sa boîte : le blob passe en « remis ».
    await app.inject({
      method: 'GET',
      url: '/v1/messages',
      headers: { authorization: `Bearer ${bob.accessToken}` },
    });

    // Il n'est déjà plus atteignable — GET /messages ne renvoie que les non
    // remis. Le conserver n'aide donc plus personne.
    const relecture = await app.inject({
      method: 'GET',
      url: '/v1/messages',
      headers: { authorization: `Bearer ${bob.accessToken}` },
    });
    expect(relecture.json()).toHaveLength(0);

    // Le délai de grâce n'est pas écoulé : il est encore là.
    await purgeExpired();
    expect(
      await prisma.messageBlob.findUnique({ where: { id: blobId } }),
    ).not.toBeNull();

    // Une fois le délai passé, il disparaît.
    await prisma.messageBlob.update({
      where: { id: blobId },
      data: { deliveredAt: heures(-48) },
    });
    await purgeExpired();
    expect(
      await prisma.messageBlob.findUnique({ where: { id: blobId } }),
    ).toBeNull();
  });

  test('les sessions expirées ou révoquées sont effacées', async () => {
    const alice = await register('alice');

    const active = await prisma.authSession.findFirst({
      where: { userId: alice.userId },
    });
    expect(active).not.toBeNull();

    const expiree = await prisma.authSession.create({
      data: {
        userId: alice.userId,
        deviceId: alice.deviceId,
        refreshTokenHash: randomBytes(32).toString('hex'),
        expiresAt: jours(-1),
      },
    });
    const revoquee = await prisma.authSession.create({
      data: {
        userId: alice.userId,
        deviceId: alice.deviceId,
        refreshTokenHash: randomBytes(32).toString('hex'),
        expiresAt: jours(30),
        revokedAt: new Date(),
      },
    });

    await purgeExpired();

    expect(
      await prisma.authSession.findUnique({ where: { id: expiree.id } }),
    ).toBeNull();
    expect(
      await prisma.authSession.findUnique({ where: { id: revoquee.id } }),
    ).toBeNull();
    // La session en cours d'Alice n'est pas touchée : elle est encore valide.
    expect(
      await prisma.authSession.findUnique({ where: { id: active!.id } }),
    ).not.toBeNull();
  });

  test('les conversations sans participant sont retirées', async () => {
    const alice = await register('alice');

    const orpheline = await prisma.conversation.create({
      data: { type: 'direct', createdBy: alice.userId },
    });

    await purgeExpired();

    expect(
      await prisma.conversation.findUnique({ where: { id: orpheline.id } }),
    ).toBeNull();
  });
});
