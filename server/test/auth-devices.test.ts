import { randomBytes } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { afterAll, beforeAll, describe, expect, test } from 'vitest';
import { buildApp } from '../src/app.js';
import { prisma } from '../src/db/prisma.js';

const key = (n: number) => randomBytes(n).toString('base64');
const device = (platform = 'linux') => ({
  platform,
  identityPublicKey: key(32),
  signedPrekey: key(32),
  signedPrekeySignature: key(64),
  oneTimePrekeys: [key(32), key(32)],
});

const USERNAMES = ['alice_test', 'bob_test'];
let app: FastifyInstance;

beforeAll(async () => {
  app = buildApp();
  await app.ready();
  await prisma.user.deleteMany({ where: { username: { in: USERNAMES } } });
});

afterAll(async () => {
  await prisma.user.deleteMany({ where: { username: { in: USERNAMES } } });
  await app.close();
  await prisma.$disconnect();
});

describe('auth + devices + prekeys', () => {
  test('flux complet inscription → bundle X3DH → refresh', async () => {
    // Inscription d'Alice et Bob (chacun avec un appareil)
    const regA = await app.inject({
      method: 'POST',
      url: '/v1/auth/register',
      payload: { username: 'alice_test', password: 'password123', device: device() },
    });
    expect(regA.statusCode).toBe(201);
    const alice = regA.json();
    expect(alice.accessToken).toBeTruthy();

    const regB = await app.inject({
      method: 'POST',
      url: '/v1/auth/register',
      payload: { username: 'bob_test', password: 'password123', device: device('android') },
    });
    expect(regB.statusCode).toBe(201);
    const bob = regB.json();

    // Nom d'utilisateur déjà pris → 409
    const dup = await app.inject({
      method: 'POST',
      url: '/v1/auth/register',
      payload: { username: 'alice_test', password: 'password123', device: device() },
    });
    expect(dup.statusCode).toBe(409);

    // Bundle protégé : sans jeton → 401
    const noAuth = await app.inject({
      method: 'GET',
      url: `/v1/users/${bob.userId}/prekey-bundle`,
    });
    expect(noAuth.statusCode).toBe(401);

    // Alice récupère le bundle X3DH de Bob
    const bundleRes = await app.inject({
      method: 'GET',
      url: `/v1/users/${bob.userId}/prekey-bundle`,
      headers: { authorization: `Bearer ${alice.accessToken}` },
    });
    expect(bundleRes.statusCode).toBe(200);
    const bundle = bundleRes.json();
    expect(Buffer.from(bundle.identityKey, 'base64')).toHaveLength(32);
    expect(Buffer.from(bundle.signedPrekey, 'base64')).toHaveLength(32);
    expect(Buffer.from(bundle.signedPrekeySignature, 'base64')).toHaveLength(64);
    expect(bundle.oneTimePrekey).not.toBeNull();

    // La one-time prekey renvoyée doit avoir été consommée en base
    const consumed = await prisma.oneTimePrekey.count({
      where: { device: { userId: bob.userId }, consumedAt: { not: null } },
    });
    expect(consumed).toBe(1);

    // Un 2e appel consomme la 2e OTPK ; un 3e n'en a plus → oneTimePrekey null
    await app.inject({
      method: 'GET',
      url: `/v1/users/${bob.userId}/prekey-bundle`,
      headers: { authorization: `Bearer ${alice.accessToken}` },
    });
    const empty = await app.inject({
      method: 'GET',
      url: `/v1/users/${bob.userId}/prekey-bundle`,
      headers: { authorization: `Bearer ${alice.accessToken}` },
    });
    expect(empty.json().oneTimePrekey).toBeNull();

    // Liste publique des appareils de Bob
    const devicesRes = await app.inject({ method: 'GET', url: `/v1/devices/${bob.userId}` });
    expect(devicesRes.statusCode).toBe(200);
    expect(devicesRes.json()).toHaveLength(1);

    // Login avec mauvais mot de passe → 401
    const badLogin = await app.inject({
      method: 'POST',
      url: '/v1/auth/login',
      payload: { username: 'alice_test', password: 'wrong', deviceId: alice.deviceId },
    });
    expect(badLogin.statusCode).toBe(401);

    // Login correct → nouveaux jetons
    const login = await app.inject({
      method: 'POST',
      url: '/v1/auth/login',
      payload: { username: 'alice_test', password: 'password123', deviceId: alice.deviceId },
    });
    expect(login.statusCode).toBe(200);

    // Refresh → nouveaux jetons, l'ancien refresh est révoqué
    const refresh = await app.inject({
      method: 'POST',
      url: '/v1/auth/refresh',
      payload: { refreshToken: alice.refreshToken },
    });
    expect(refresh.statusCode).toBe(200);
    expect(refresh.json().accessToken).toBeTruthy();

    // Réutiliser le même refresh (déjà tourné) → 401
    const reused = await app.inject({
      method: 'POST',
      url: '/v1/auth/refresh',
      payload: { refreshToken: alice.refreshToken },
    });
    expect(reused.statusCode).toBe(401);
  });
});
