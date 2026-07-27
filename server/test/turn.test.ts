import { createHmac, randomBytes } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { afterAll, beforeAll, describe, expect, test } from 'vitest';
import { buildApp } from '../src/app.js';
import { prisma } from '../src/db/prisma.js';

/**
 * Credentials TURN pour les appels chiffrés.
 *
 * Ce que ces épreuves affirment : la route exige une authentification, et
 * quand un TURN est configuré, elle rend des identifiants HMAC à ÉCHÉANCE
 * FUTURE, calculés sous le secret partagé — exactement ce que coturn
 * recalculera. Le secret partagé de test est fourni par le script `npm test`.
 */

const key = (n: number) => randomBytes(n).toString('base64');
const device = () => ({
  platform: 'linux',
  identityPublicKey: key(32),
  signedPrekey: key(32),
  signedPrekeySignature: key(64),
  oneTimePrekeys: [key(32)],
});

const PREFIX = 'turn_t';
const SECRET = process.env.TURN_SHARED_SECRET!;
let app: FastifyInstance;
let counter = 0;

beforeAll(async () => {
  app = await buildApp();
  await app.ready();
});

afterAll(async () => {
  await prisma.user.deleteMany({ where: { username: { startsWith: PREFIX } } });
  await app.close();
  await prisma.$disconnect();
});

async function inscrire() {
  const res = await app.inject({
    method: 'POST',
    url: '/v1/auth/register',
    payload: { username: `${PREFIX}_${counter++}`, password: 'password123', device: device() },
  });
  expect(res.statusCode).toBe(201);
  return res.json() as { accessToken: string; userId: string };
}

describe('credentials TURN', () => {
  test('sans authentification, la route est refusée', async () => {
    const res = await app.inject({ method: 'GET', url: '/v1/turn-credentials' });
    expect(res.statusCode).toBe(401);
  });

  test('avec authentification, rend des identifiants HMAC à échéance future', async () => {
    const compte = await inscrire();
    const res = await app.inject({
      method: 'GET',
      url: '/v1/turn-credentials',
      headers: { authorization: `Bearer ${compte.accessToken}` },
    });
    expect(res.statusCode).toBe(200);
    const body = res.json() as {
      ttl: number;
      iceServers: Array<{ urls: string[]; username: string; credential: string }>;
    };

    const ice = body.iceServers[0];
    expect(ice.urls).toContain('turn:appel.test:3478');

    // Le nom porte « échéance:compte », l'échéance dans le futur.
    const [expiryStr, userId] = ice.username.split(':');
    expect(userId).toBe(compte.userId);
    const expiry = Number(expiryStr);
    const maintenant = Math.floor(Date.now() / 1000);
    expect(expiry).toBeGreaterThan(maintenant);
    expect(expiry).toBeLessThanOrEqual(maintenant + body.ttl + 2);

    // Le mot de passe est EXACTEMENT le HMAC que coturn recalculera.
    const attendu = createHmac('sha1', SECRET).update(ice.username).digest('base64');
    expect(ice.credential).toBe(attendu);
  });

  test('deux appels donnent des identifiants distincts (échéance qui avance)', async () => {
    const compte = await inscrire();
    const appel = () =>
      app
        .inject({
          method: 'GET',
          url: '/v1/turn-credentials',
          headers: { authorization: `Bearer ${compte.accessToken}` },
        })
        .then((r) => (r.json() as { iceServers: Array<{ credential: string }> }).iceServers[0]);

    const a = await appel();
    await new Promise((r) => setTimeout(r, 1100)); // l'échéance est en secondes
    const b = await appel();
    // Rien de secret durable : chaque identifiant est éphémère et unique.
    expect(a.credential).not.toBe(b.credential);
  });
});
