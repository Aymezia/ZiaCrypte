import { randomBytes } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { afterAll, beforeAll, describe, expect, test } from 'vitest';
import { buildApp } from '../src/app.js';
import { prisma } from '../src/db/prisma.js';
import { InertPushProvider } from '../src/modules/push/push.provider.js';
import { initPush } from '../src/modules/push/push.service.js';

const key = (n: number) => randomBytes(n).toString('base64');
const device = (platform = 'android') => ({
  platform,
  identityPublicKey: key(32),
  signedPrekey: key(32),
  signedPrekeySignature: key(64),
  oneTimePrekeys: [key(32), key(32)],
});

const PREFIX = 'push_t';
let app: FastifyInstance;
let fcm: InertPushProvider;
let counter = 0;

/**
 * Inscrit un utilisateur jetable et renvoie ses jetons + son appareil.
 * Le pseudo est unique à chaque appel : les cas de test restent indépendants.
 */
async function register(label: string) {
  const username = `${PREFIX}_${label}_${counter++}`;
  const res = await app.inject({
    method: 'POST',
    url: '/v1/auth/register',
    payload: { username, password: 'password123', device: device() },
  });
  expect(res.statusCode).toBe(201);
  return res.json() as {
    accessToken: string;
    userId: string;
    deviceId: string;
  };
}

beforeAll(async () => {
  app = buildApp();
  await app.ready();
  fcm = new InertPushProvider('fcm');
  initPush([fcm]);
  await prisma.user.deleteMany({ where: { username: { startsWith: PREFIX } } });
});

afterAll(async () => {
  await prisma.user.deleteMany({ where: { username: { startsWith: PREFIX } } });
  await app.close();
  await prisma.$disconnect();
});

describe('notifications push sans contenu', () => {
  test('un appareil enregistre son jeton, et seulement le sien', async () => {
    const alice = await register('alice');
    const bob = await register('bob');

    const put = await app.inject({
      method: 'PUT',
      url: '/v1/push/token',
      headers: { authorization: `Bearer ${alice.accessToken}` },
      payload: { platform: 'fcm', token: 'jeton-fcm-d-alice-0123456789' },
    });
    expect(put.statusCode).toBe(200);
    expect(put.json()).toEqual({ active: true });

    // Le jeton est bien rattaché à l'appareil d'Alice, pas à un autre.
    const stored = await prisma.pushToken.findMany({
      where: { deviceId: { in: [alice.deviceId, bob.deviceId] } },
    });
    expect(stored).toHaveLength(1);
    expect(stored[0]!.deviceId).toBe(alice.deviceId);

    // L'appareil est lu dans le jeton d'accès : même en tentant d'imposer
    // l'identifiant de Bob, c'est celui d'Alice qui est utilisé.
    const spoof = await app.inject({
      method: 'PUT',
      url: '/v1/push/token',
      headers: { authorization: `Bearer ${alice.accessToken}` },
      payload: {
        platform: 'fcm',
        token: 'jeton-detourne-0123456789',
        deviceId: bob.deviceId,
      },
    });
    expect(spoof.statusCode).toBe(200);
    const afterSpoof = await prisma.pushToken.findMany({
      where: { deviceId: bob.deviceId },
    });
    expect(afterSpoof).toHaveLength(0);
  });

  test('sans jeton d’accès, aucun enregistrement possible', async () => {
    const res = await app.inject({
      method: 'PUT',
      url: '/v1/push/token',
      payload: { platform: 'fcm', token: 'jeton-anonyme-0123456789' },
    });
    expect(res.statusCode).toBe(401);
  });

  test('un message vers un appareil hors ligne déclenche un réveil', async () => {
    const alice = await register('alice');
    const bob = await register('bob');

    await app.inject({
      method: 'PUT',
      url: '/v1/push/token',
      headers: { authorization: `Bearer ${bob.accessToken}` },
      payload: { platform: 'fcm', token: 'jeton-fcm-de-bob-0123456789' },
    });

    const conv = await app.inject({
      method: 'POST',
      url: '/v1/conversations',
      headers: { authorization: `Bearer ${alice.accessToken}` },
      payload: { type: 'direct', participantIds: [bob.userId] },
    });
    expect(conv.statusCode).toBeLessThan(300);

    const before = fcm.woken.length;
    const send = await app.inject({
      method: 'POST',
      url: '/v1/messages',
      headers: { authorization: `Bearer ${alice.accessToken}` },
      payload: {
        conversationId: conv.json().id,
        recipientDeviceId: bob.deviceId,
        clientMessageId: crypto.randomUUID(),
        header: key(48),
        ciphertext: key(64),
      },
    });
    expect(send.statusCode).toBe(201);

    // Le réveil part sans await côté route : on laisse la microtâche s'écouler.
    await new Promise((r) => setTimeout(r, 50));
    expect(fcm.woken.slice(before)).toEqual(['jeton-fcm-de-bob-0123456789']);
  });

  test('le retrait du jeton est idempotent', async () => {
    const alice = await register('alice');
    await app.inject({
      method: 'PUT',
      url: '/v1/push/token',
      headers: { authorization: `Bearer ${alice.accessToken}` },
      payload: { platform: 'fcm', token: 'jeton-a-retirer-0123456789' },
    });

    for (const expected of [204, 204]) {
      const res = await app.inject({
        method: 'DELETE',
        url: '/v1/push/token?platform=fcm',
        headers: { authorization: `Bearer ${alice.accessToken}` },
      });
      expect(res.statusCode).toBe(expected);
    }
    expect(
      await prisma.pushToken.count({ where: { deviceId: alice.deviceId } }),
    ).toBe(0);
  });
});
