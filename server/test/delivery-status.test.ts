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
  oneTimePrekeys: [key(32)],
});

const PREFIX = 'del_st';
let app: FastifyInstance;
let counter = 0;

type Compte = { accessToken: string; userId: string; deviceId: string };
const auth = (c: Compte) => ({ authorization: `Bearer ${c.accessToken}` });

async function register(label: string): Promise<Compte> {
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
  return res.json() as Compte;
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

describe('statut de remise', () => {
  test('un message devient « remis » quand le destinataire relève sa boîte', async () => {
    const alice = await register('alice');
    const bob = await register('bob');

    const conv = await app.inject({
      method: 'POST',
      url: '/v1/conversations',
      headers: auth(alice),
      payload: { type: 'direct', participantIds: [bob.userId] },
    });
    const conversationId = conv.json().id as string;

    const clientMessageId = randomUUID();
    const envoi = await app.inject({
      method: 'POST',
      url: '/v1/messages',
      headers: auth(alice),
      payload: {
        conversationId,
        recipientDeviceId: bob.deviceId,
        clientMessageId,
        header: key(48),
        ciphertext: key(64),
      },
    });
    expect(envoi.statusCode).toBe(201);

    // Avant que Bob relève : pas encore remis.
    const avant = await app.inject({
      method: 'GET',
      url: `/v1/messages/status?ids=${clientMessageId}`,
      headers: auth(alice),
    });
    expect(avant.json().delivered).toEqual([]);

    // Bob relève sa boîte.
    await app.inject({ method: 'GET', url: '/v1/messages', headers: auth(bob) });

    // Maintenant : remis.
    const apres = await app.inject({
      method: 'GET',
      url: `/v1/messages/status?ids=${clientMessageId}`,
      headers: auth(alice),
    });
    expect(apres.json().delivered).toEqual([clientMessageId]);
  });

  /**
   * Le statut n'est visible que de l'expéditeur du message. Sans ce scope, on
   * pourrait sonder la remise des messages d'autrui — une fuite de métadonnée.
   */
  test('on ne voit pas le statut des messages qu’on n’a pas envoyés', async () => {
    const alice = await register('alice');
    const bob = await register('bob');
    const curieux = await register('curieux');

    const conv = await app.inject({
      method: 'POST',
      url: '/v1/conversations',
      headers: auth(alice),
      payload: { type: 'direct', participantIds: [bob.userId] },
    });

    const clientMessageId = randomUUID();
    await app.inject({
      method: 'POST',
      url: '/v1/messages',
      headers: auth(alice),
      payload: {
        conversationId: conv.json().id,
        recipientDeviceId: bob.deviceId,
        clientMessageId,
        header: key(48),
        ciphertext: key(64),
      },
    });
    await app.inject({ method: 'GET', url: '/v1/messages', headers: auth(bob) });

    // Alice, qui l'a envoyé, voit « remis ».
    const vueAlice = await app.inject({
      method: 'GET',
      url: `/v1/messages/status?ids=${clientMessageId}`,
      headers: auth(alice),
    });
    expect(vueAlice.json().delivered).toEqual([clientMessageId]);

    // Un tiers qui devine l'identifiant ne voit rien.
    const vueCurieux = await app.inject({
      method: 'GET',
      url: `/v1/messages/status?ids=${clientMessageId}`,
      headers: auth(curieux),
    });
    expect(vueCurieux.json().delivered).toEqual([]);
  });

  test('une liste vide ou inconnue ne renvoie rien, sans erreur', async () => {
    const alice = await register('alice');
    const vide = await app.inject({
      method: 'GET',
      url: '/v1/messages/status?ids=',
      headers: auth(alice),
    });
    expect(vide.statusCode).toBe(200);
    expect(vide.json().delivered).toEqual([]);

    const inconnu = await app.inject({
      method: 'GET',
      url: `/v1/messages/status?ids=${randomUUID()}`,
      headers: auth(alice),
    });
    expect(inconnu.json().delivered).toEqual([]);
  });
});
