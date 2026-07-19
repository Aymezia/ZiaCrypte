import { randomBytes } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { afterAll, beforeAll, describe, expect, test } from 'vitest';
import { buildApp } from '../src/app.js';
import { prisma } from '../src/db/prisma.js';
import { totp, base32Decode } from '../src/lib/totp.js';

const key = (n: number) => randomBytes(n).toString('base64');
const device = () => ({
  platform: 'linux',
  identityPublicKey: key(32),
  signedPrekey: key(32),
  signedPrekeySignature: key(64),
  oneTimePrekeys: [key(32)],
});

const PREFIX = '2fa_t';
let app: FastifyInstance;
let counter = 0;

async function register(label: string) {
  const username = `${PREFIX}_${label}_${counter++}`;
  const res = await app.inject({
    method: 'POST',
    url: '/v1/auth/register',
    payload: { username, password: 'password123', device: device() },
  });
  expect(res.statusCode).toBe(201);
  return { username, ...(res.json() as { accessToken: string; userId: string; deviceId: string }) };
}

/** Code TOTP courant pour un secret base32. */
const codeFor = (secret: string) => totp(base32Decode(secret), Date.now() / 1000, 6);

beforeAll(async () => {
  app = await buildApp();
  await app.ready();
});

afterAll(async () => {
  await prisma.user.deleteMany({ where: { username: { startsWith: PREFIX } } });
  await app.close();
  await prisma.$disconnect();
});

describe('second facteur (TOTP)', () => {
  test('cycle complet : activation, connexion exigeant le code, désactivation', async () => {
    const u = await register('alice');
    const auth = { authorization: `Bearer ${u.accessToken}` };

    // État initial : désactivé.
    const etat0 = await app.inject({ method: 'GET', url: '/v1/auth/2fa', headers: auth });
    expect(etat0.json()).toEqual({ enabled: false });

    // Enrôlement : on obtient un secret, mais le 2FA n'est pas encore actif.
    const setup = await app.inject({ method: 'POST', url: '/v1/auth/2fa/setup', headers: auth });
    expect(setup.statusCode).toBe(200);
    const secret = setup.json().secret as string;
    expect(setup.json().otpauthUri).toContain('otpauth://totp/');

    const etat1 = await app.inject({ method: 'GET', url: '/v1/auth/2fa', headers: auth });
    expect(etat1.json()).toEqual({ enabled: false });

    // Connexion : pas encore exigée, le 2FA n'est pas confirmé.
    const login0 = await app.inject({
      method: 'POST',
      url: '/v1/auth/login',
      payload: { username: u.username, password: 'password123', deviceId: u.deviceId },
    });
    expect(login0.statusCode).toBe(200);

    // Un mauvais code refuse l'activation.
    const badEnable = await app.inject({
      method: 'POST',
      url: '/v1/auth/2fa/enable',
      headers: auth,
      payload: { code: '000000' },
    });
    expect(badEnable.statusCode).toBe(401);

    // Le bon code l'active.
    const enable = await app.inject({
      method: 'POST',
      url: '/v1/auth/2fa/enable',
      headers: auth,
      payload: { code: codeFor(secret) },
    });
    expect(enable.statusCode).toBe(200);
    expect(enable.json()).toEqual({ enabled: true });

    // Désormais, la connexion SANS code est refusée avec un signal distinct.
    const loginSansCode = await app.inject({
      method: 'POST',
      url: '/v1/auth/login',
      payload: { username: u.username, password: 'password123', deviceId: u.deviceId },
    });
    expect(loginSansCode.statusCode).toBe(428);
    expect(loginSansCode.json().error).toBe('TOTP_REQUIRED');

    // Un mauvais code est refusé.
    const loginMauvais = await app.inject({
      method: 'POST',
      url: '/v1/auth/login',
      payload: { username: u.username, password: 'password123', deviceId: u.deviceId, totp: '000000' },
    });
    expect(loginMauvais.statusCode).toBe(401);

    // Le bon code passe.
    const loginBon = await app.inject({
      method: 'POST',
      url: '/v1/auth/login',
      payload: { username: u.username, password: 'password123', deviceId: u.deviceId, totp: codeFor(secret) },
    });
    expect(loginBon.statusCode).toBe(200);

    // Désactivation : exige mot de passe ET code.
    const disableSansCode = await app.inject({
      method: 'POST',
      url: '/v1/auth/2fa/disable',
      headers: auth,
      payload: { password: 'password123', code: '000000' },
    });
    expect(disableSansCode.statusCode).toBe(401);

    const disable = await app.inject({
      method: 'POST',
      url: '/v1/auth/2fa/disable',
      headers: auth,
      payload: { password: 'password123', code: codeFor(secret) },
    });
    expect(disable.statusCode).toBe(200);

    // Retour à la connexion simple.
    const loginFinal = await app.inject({
      method: 'POST',
      url: '/v1/auth/login',
      payload: { username: u.username, password: 'password123', deviceId: u.deviceId },
    });
    expect(loginFinal.statusCode).toBe(200);
  });

  test('le second facteur protège aussi l’ajout d’un appareil', async () => {
    const u = await register('bob');
    const auth = { authorization: `Bearer ${u.accessToken}` };

    const setup = await app.inject({ method: 'POST', url: '/v1/auth/2fa/setup', headers: auth });
    const secret = setup.json().secret as string;
    await app.inject({
      method: 'POST',
      url: '/v1/auth/2fa/enable',
      headers: auth,
      payload: { code: codeFor(secret) },
    });

    // Ajout sans code : refusé, même avec le bon mot de passe.
    const sansCode = await app.inject({
      method: 'POST',
      url: '/v1/auth/add-device',
      payload: { username: u.username, password: 'password123', device: device() },
    });
    expect(sansCode.statusCode).toBe(428);

    // Avec le code : accepté.
    const avecCode = await app.inject({
      method: 'POST',
      url: '/v1/auth/add-device',
      payload: { username: u.username, password: 'password123', device: device(), totp: codeFor(secret) },
    });
    expect(avecCode.statusCode).toBe(201);
  });

  test('le secret n’est jamais renvoyé après l’enrôlement', async () => {
    const u = await register('carol');
    const auth = { authorization: `Bearer ${u.accessToken}` };
    await app.inject({ method: 'POST', url: '/v1/auth/2fa/setup', headers: auth });

    const etat = await app.inject({ method: 'GET', url: '/v1/auth/2fa', headers: auth });
    expect(JSON.stringify(etat.json())).not.toContain('secret');
    expect(etat.json()).toEqual({ enabled: false });
  });
});
