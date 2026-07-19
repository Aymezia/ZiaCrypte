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

const PREFIX = 'grp_t';
let app: FastifyInstance;
let counter = 0;

type Compte = { accessToken: string; userId: string; deviceId: string };

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

const auth = (c: Compte) => ({ authorization: `Bearer ${c.accessToken}` });

/** Envoie un blob opaque dans une conversation. Renvoie le code HTTP. */
async function envoyer(de: Compte, conversationId: string, versDevice: string) {
  const res = await app.inject({
    method: 'POST',
    url: '/v1/messages',
    headers: auth(de),
    payload: {
      conversationId,
      recipientDeviceId: versDevice,
      clientMessageId: randomUUID(),
      header: key(48),
      ciphertext: key(64),
    },
  });
  return res.statusCode;
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

describe('conversations de groupe', () => {
  test('création, liste des membres, et rôle du créateur', async () => {
    const a = await register('admin');
    const b = await register('membre');
    const c = await register('membre');

    const conv = await app.inject({
      method: 'POST',
      url: '/v1/conversations',
      headers: auth(a),
      payload: { type: 'group', participantIds: [b.userId, c.userId] },
    });
    expect(conv.statusCode).toBe(201);
    const groupe = conv.json().id as string;

    const membres = await app.inject({
      method: 'GET',
      url: `/v1/conversations/${groupe}/members`,
      headers: auth(a),
    });
    expect(membres.statusCode).toBe(200);
    const liste = membres.json() as Array<{ userId: string; role: string }>;
    expect(liste).toHaveLength(3);
    expect(liste.find((m) => m.userId === a.userId)?.role).toBe('admin');
    expect(liste.find((m) => m.userId === b.userId)?.role).toBe('member');
  });

  test('la composition d’un groupe n’est pas publique', async () => {
    const a = await register('admin');
    const b = await register('membre');
    const etranger = await register('etranger');

    const conv = await app.inject({
      method: 'POST',
      url: '/v1/conversations',
      headers: auth(a),
      payload: { type: 'group', participantIds: [b.userId] },
    });
    const groupe = conv.json().id as string;

    const res = await app.inject({
      method: 'GET',
      url: `/v1/conversations/${groupe}/members`,
      headers: auth(etranger),
    });
    expect(res.statusCode).toBe(403);
  });

  /**
   * Le point le plus important. Quitter un groupe ou en être retiré laisse la
   * ligne d'adhésion en place — elle porte l'historique. Les contrôles
   * d'appartenance testaient la seule présence de cette ligne : un membre exclu
   * conservait donc le droit d'écrire au groupe.
   */
  test('un membre retiré ne peut plus écrire au groupe', async () => {
    const a = await register('admin');
    const b = await register('exclu');

    const conv = await app.inject({
      method: 'POST',
      url: '/v1/conversations',
      headers: auth(a),
      payload: { type: 'group', participantIds: [b.userId] },
    });
    const groupe = conv.json().id as string;

    // Tant qu'il est membre, il écrit.
    expect(await envoyer(b, groupe, a.deviceId)).toBe(201);

    const retrait = await app.inject({
      method: 'DELETE',
      url: `/v1/conversations/${groupe}/members/${b.userId}`,
      headers: auth(a),
    });
    expect(retrait.statusCode).toBe(204);

    // Une fois retiré, il ne peut plus.
    expect(await envoyer(b, groupe, a.deviceId)).toBe(403);

    // Ni déposer de pièce jointe.
    const pj = await app.inject({
      method: 'POST',
      url: '/v1/attachments',
      headers: auth(b),
      payload: {
        conversationId: groupe,
        ciphertextSize: 1024,
        encryptedMetadata: key(32),
      },
    });
    expect(pj.statusCode).toBe(403);
  });

  test('quitter soi-même est permis, retirer autrui exige d’être admin', async () => {
    const a = await register('admin');
    const b = await register('membre');
    const c = await register('membre');

    const conv = await app.inject({
      method: 'POST',
      url: '/v1/conversations',
      headers: auth(a),
      payload: { type: 'group', participantIds: [b.userId, c.userId] },
    });
    const groupe = conv.json().id as string;

    // Un simple membre ne peut pas en exclure un autre.
    const abus = await app.inject({
      method: 'DELETE',
      url: `/v1/conversations/${groupe}/members/${c.userId}`,
      headers: auth(b),
    });
    expect(abus.statusCode).toBe(403);

    // Mais il peut partir de lui-même.
    const depart = await app.inject({
      method: 'DELETE',
      url: `/v1/conversations/${groupe}/members/${b.userId}`,
      headers: auth(b),
    });
    expect(depart.statusCode).toBe(204);
  });

  test('un membre réintégré retrouve le droit d’écrire', async () => {
    const a = await register('admin');
    const b = await register('revenant');

    const conv = await app.inject({
      method: 'POST',
      url: '/v1/conversations',
      headers: auth(a),
      payload: { type: 'group', participantIds: [b.userId] },
    });
    const groupe = conv.json().id as string;

    await app.inject({
      method: 'DELETE',
      url: `/v1/conversations/${groupe}/members/${b.userId}`,
      headers: auth(a),
    });
    expect(await envoyer(b, groupe, a.deviceId)).toBe(403);

    const retour = await app.inject({
      method: 'POST',
      url: `/v1/conversations/${groupe}/members`,
      headers: auth(a),
      payload: { userId: b.userId },
    });
    expect(retour.statusCode).toBe(201);
    expect(await envoyer(b, groupe, a.deviceId)).toBe(201);

    // Une seule ligne d'adhésion, pas deux.
    const lignes = await prisma.conversationParticipant.findMany({
      where: { conversationId: groupe, userId: b.userId },
    });
    expect(lignes).toHaveLength(1);
  });

  test('on n’ajoute pas de membre à une conversation directe', async () => {
    const a = await register('admin');
    const b = await register('membre');
    const c = await register('tiers');

    const conv = await app.inject({
      method: 'POST',
      url: '/v1/conversations',
      headers: auth(a),
      payload: { type: 'direct', participantIds: [b.userId] },
    });
    const directe = conv.json().id as string;

    const res = await app.inject({
      method: 'POST',
      url: `/v1/conversations/${directe}/members`,
      headers: auth(a),
      payload: { userId: c.userId },
    });
    expect(res.statusCode).toBe(400);
  });
});
