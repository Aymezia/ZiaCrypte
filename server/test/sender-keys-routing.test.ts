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

const PREFIX = 'sk_route_t';
let app: FastifyInstance;
let counter = 0;

type Compte = { accessToken: string; userId: string; deviceId: string; username: string };

async function register(label: string): Promise<Compte> {
  const username = `${PREFIX}_${label}_${counter++}`;
  const res = await app.inject({
    method: 'POST',
    url: '/v1/auth/register',
    payload: { username, password: 'password123', device: device() },
  });
  expect(res.statusCode).toBe(201);
  return { username, ...(res.json() as Omit<Compte, 'username'>) };
}

const auth = (c: Compte) => ({ authorization: `Bearer ${c.accessToken}` });

beforeAll(async () => {
  app = await buildApp();
  await app.ready();
});

afterAll(async () => {
  await prisma.user.deleteMany({ where: { username: { startsWith: PREFIX } } });
  await app.close();
  await prisma.$disconnect();
});

describe('acheminement des messages de groupe (clés d’expéditeur)', () => {
  test('un seul dépôt sert tous les appareils, avec les MÊMES octets', async () => {
    const a = await register('alice');
    const b = await register('bob');
    const c = await register('carol');

    const conv = await app.inject({
      method: 'POST',
      url: '/v1/conversations',
      headers: auth(a),
      payload: { type: 'group', participantIds: [b.userId, c.userId] },
    });
    expect(conv.statusCode).toBe(201);
    const conversationId = conv.json().id as string;

    const ciphertext = key(96);
    const header = key(16);
    const clientMessageId = randomUUID();

    // UN seul appel pour deux destinataires — c'est tout l'objet.
    const envoi = await app.inject({
      method: 'POST',
      url: '/v1/messages/group',
      headers: auth(a),
      payload: {
        conversationId,
        clientMessageId,
        recipientDeviceIds: [b.deviceId, c.deviceId],
        header,
        ciphertext,
      },
    });
    expect(envoi.statusCode).toBe(201);

    // Chacun relève SON exemplaire...
    const relever = async (compte: Compte) => {
      const res = await app.inject({
        method: 'GET',
        url: '/v1/messages',
        headers: auth(compte),
      });
      expect(res.statusCode).toBe(200);
      return res.json() as Array<Record<string, string>>;
    };

    const pourBob = await relever(b);
    const pourCarol = await relever(c);
    expect(pourBob).toHaveLength(1);
    expect(pourCarol).toHaveLength(1);

    // ...et ce sont bien les mêmes octets : un chiffrement, deux lecteurs.
    expect(pourBob[0].ciphertext).toBe(ciphertext);
    expect(pourCarol[0].ciphertext).toBe(ciphertext);

    // L'expéditeur est nommé : le destinataire doit savoir de QUELLE chaîne
    // d'expéditeur dériver la clé.
    expect(pourBob[0].senderDeviceId).toBe(a.deviceId);
  });

  test('un destinataire qui a bloqué ne reçoit rien, et l’expéditeur ne l’apprend pas', async () => {
    const a = await register('emetteur');
    const b = await register('bloqueur');
    const c = await register('temoin');

    const conv = await app.inject({
      method: 'POST',
      url: '/v1/conversations',
      headers: auth(a),
      payload: { type: 'group', participantIds: [b.userId, c.userId] },
    });
    const conversationId = conv.json().id as string;

    // Bob bloque Alice.
    const blocage = await app.inject({
      method: 'POST',
      url: '/v1/blocks',
      headers: auth(b),
      payload: { userId: a.userId },
    });
    expect(blocage.statusCode).toBeLessThan(300);

    const envoi = await app.inject({
      method: 'POST',
      url: '/v1/messages/group',
      headers: auth(a),
      payload: {
        conversationId,
        clientMessageId: randomUUID(),
        recipientDeviceIds: [b.deviceId, c.deviceId],
        header: key(16),
        ciphertext: key(64),
      },
    });
    // Réponse identique à un envoi normal : rien ne trahit le blocage.
    expect(envoi.statusCode).toBe(201);

    const boiteBob = await app.inject({
      method: 'GET', url: '/v1/messages', headers: auth(b),
    });
    const boiteCarol = await app.inject({
      method: 'GET', url: '/v1/messages', headers: auth(c),
    });
    expect(boiteBob.json()).toHaveLength(0); // rien n'a été écrit pour lui
    expect(boiteCarol.json()).toHaveLength(1); // les autres sont servis
  });

  test('un renvoi après coupure ne duplique pas', async () => {
    const a = await register('reprise');
    const b = await register('cible');

    const conv = await app.inject({
      method: 'POST',
      url: '/v1/conversations',
      headers: auth(a),
      payload: { type: 'group', participantIds: [b.userId] },
    });
    const conversationId = conv.json().id as string;

    const payload = {
      conversationId,
      clientMessageId: randomUUID(),
      recipientDeviceIds: [b.deviceId],
      header: key(16),
      ciphertext: key(64),
    };

    const p1 = await app.inject({
      method: 'POST', url: '/v1/messages/group', headers: auth(a), payload,
    });
    const p2 = await app.inject({
      method: 'POST', url: '/v1/messages/group', headers: auth(a), payload,
    });
    expect(p1.statusCode).toBe(201);
    expect(p2.statusCode).toBe(201);

    const boite = await app.inject({
      method: 'GET', url: '/v1/messages', headers: auth(b),
    });
    expect(boite.json()).toHaveLength(1);
  });

  test('un non-membre ne peut pas déposer dans le groupe', async () => {
    const a = await register('membre');
    const b = await register('membre2');
    const intrus = await register('intrus');

    const conv = await app.inject({
      method: 'POST',
      url: '/v1/conversations',
      headers: auth(a),
      payload: { type: 'group', participantIds: [b.userId] },
    });
    const conversationId = conv.json().id as string;

    const res = await app.inject({
      method: 'POST',
      url: '/v1/messages/group',
      headers: auth(intrus),
      payload: {
        conversationId,
        clientMessageId: randomUUID(),
        recipientDeviceIds: [b.deviceId],
        header: key(16),
        ciphertext: key(64),
      },
    });
    expect(res.statusCode).toBeGreaterThanOrEqual(400);
  });
});
