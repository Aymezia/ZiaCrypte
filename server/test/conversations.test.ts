import { randomBytes } from 'node:crypto';
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

const PREFIX = 'conv_t';
let app: FastifyInstance;
let counter = 0;
const orphans: string[] = [];

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
  await prisma.conversation.deleteMany({ where: { id: { in: orphans } } });
  await prisma.user.deleteMany({ where: { username: { startsWith: PREFIX } } });
  await app.close();
  await prisma.$disconnect();
});

describe('conversations directes', () => {
  /**
   * L'identifiant d'une conversation directe doit être stable : l'historique
   * local et les sessions du ratchet y sont rattachés. En créer une nouvelle à
   * chaque ouverture rendrait les messages précédents inaccessibles.
   */
  test('rouvrir une conversation renvoie la même, pas une nouvelle', async () => {
    const alice = await register('alice');
    const bob = await register('bob');

    const first = await app.inject({
      method: 'POST',
      url: '/v1/conversations',
      headers: { authorization: `Bearer ${alice.accessToken}` },
      payload: { type: 'direct', participantIds: [bob.userId] },
    });
    expect(first.statusCode).toBe(201);

    const again = await app.inject({
      method: 'POST',
      url: '/v1/conversations',
      headers: { authorization: `Bearer ${alice.accessToken}` },
      payload: { type: 'direct', participantIds: [bob.userId] },
    });
    expect(again.statusCode).toBe(200);
    expect(again.json().id).toBe(first.json().id);

    // Et depuis l'autre côté : Bob doit retrouver la conversation d'Alice.
    const fromBob = await app.inject({
      method: 'POST',
      url: '/v1/conversations',
      headers: { authorization: `Bearer ${bob.accessToken}` },
      payload: { type: 'direct', participantIds: [alice.userId] },
    });
    expect(fromBob.json().id).toBe(first.json().id);
  });

  /**
   * Régression : une conversation sans aucun participant (il en reste après la
   * suppression des comptes concernés) satisfait `every` par vacuité. Le filtre
   * la retenait à la place de la vraie conversation et un doublon était créé.
   */
  test('une conversation orpheline ne fait pas créer de doublon', async () => {
    const alice = await register('alice');
    const bob = await register('bob');

    const first = await app.inject({
      method: 'POST',
      url: '/v1/conversations',
      headers: { authorization: `Bearer ${alice.accessToken}` },
      payload: { type: 'direct', participantIds: [bob.userId] },
    });
    const conversationId = first.json().id as string;

    // On fabrique l'orpheline : une conversation directe sans participant.
    const orphan = await prisma.conversation.create({
      data: { type: 'direct', createdBy: alice.userId },
    });
    orphans.push(orphan.id);

    const again = await app.inject({
      method: 'POST',
      url: '/v1/conversations',
      headers: { authorization: `Bearer ${alice.accessToken}` },
      payload: { type: 'direct', participantIds: [bob.userId] },
    });
    expect(again.statusCode).toBe(200);
    expect(again.json().id).toBe(conversationId);

    // Une seule conversation existe pour cette paire.
    const forPair = await prisma.conversation.findMany({
      where: {
        type: 'direct',
        AND: [
          { participants: { some: { userId: alice.userId } } },
          { participants: { some: { userId: bob.userId } } },
        ],
      },
    });
    expect(forPair).toHaveLength(1);
  });
});
