import { randomBytes, randomUUID } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { afterAll, beforeAll, describe, expect, test } from 'vitest';
import { buildApp } from '../src/app.js';
import { prisma } from '../src/db/prisma.js';

const key = (n: number) => randomBytes(n).toString('base64');
const device = () => ({
  platform: 'linux',
  identityPublicKey: key(32),
  signedPrekey: key(32),
  signedPrekeySignature: key(64),
  oneTimePrekeys: [key(32), key(32)],
});

const PREFIX = 'del_t';
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
 * Le droit de supprimer son compte n'est pas une commodité : c'est la seule
 * garantie que l'utilisateur peut retirer ses données du serveur. Ces tests
 * couvrent le cas qui l'avait cassé en silence — les clés étrangères sans règle
 * de suppression bloquaient l'effacement dès la première conversation.
 */
describe('suppression de compte', () => {
  test('reste possible après avoir créé une conversation et échangé', async () => {
    const alice = await register('alice');
    const bob = await register('bob');

    const conv = await app.inject({
      method: 'POST',
      url: '/v1/conversations',
      headers: { authorization: `Bearer ${alice.accessToken}` },
      payload: { type: 'direct', participantIds: [bob.userId] },
    });
    const conversationId = conv.json().id as string;

    // Un message dans chaque sens : les blobs référencent les appareils des
    // deux côtés, ce qui exerce les deux clés étrangères de message_blobs.
    for (const [from, toDevice] of [
      [alice.accessToken, bob.deviceId],
      [bob.accessToken, alice.deviceId],
    ] as const) {
      const sent = await app.inject({
        method: 'POST',
        url: '/v1/messages',
        headers: { authorization: `Bearer ${from}` },
        payload: {
          conversationId,
          recipientDeviceId: toDevice,
          clientMessageId: randomUUID(),
          header: key(48),
          ciphertext: key(64),
        },
      });
      expect(sent.statusCode).toBe(201);
    }

    const del = await app.inject({
      method: 'DELETE',
      url: '/v1/users/me',
      headers: { authorization: `Bearer ${alice.accessToken}` },
      payload: { password: 'password123' },
    });
    expect(del.statusCode).toBe(204);

    // Rien d'Alice ne subsiste.
    expect(await prisma.user.findUnique({ where: { id: alice.userId } })).toBeNull();
    expect(await prisma.device.count({ where: { userId: alice.userId } })).toBe(0);
    expect(
      await prisma.messageBlob.count({
        where: {
          OR: [
            { senderDeviceId: alice.deviceId },
            { recipientDeviceId: alice.deviceId },
          ],
        },
      }),
    ).toBe(0);

    // Mais la conversation survit : l'historique de Bob ne lui appartenait pas.
    const survivor = await prisma.conversation.findUnique({
      where: { id: conversationId },
    });
    expect(survivor).not.toBeNull();
    expect(survivor!.createdBy).toBeNull();
  });

  test('exige le mot de passe : un jeton volé ne suffit pas', async () => {
    const victim = await register('victime');

    const del = await app.inject({
      method: 'DELETE',
      url: '/v1/users/me',
      headers: { authorization: `Bearer ${victim.accessToken}` },
      payload: { password: 'mauvais-mot-de-passe' },
    });
    expect(del.statusCode).toBe(401);
    expect(await prisma.user.findUnique({ where: { id: victim.userId } })).not.toBeNull();
  });
});
