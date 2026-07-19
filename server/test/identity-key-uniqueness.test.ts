import { randomBytes } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { afterAll, beforeAll, describe, expect, test } from 'vitest';
import { buildApp } from '../src/app.js';
import { prisma } from '../src/db/prisma.js';

const key = (n: number) => randomBytes(n).toString('base64');
const device = (identityPublicKey = key(32)) => ({
  platform: 'linux',
  identityPublicKey,
  signedPrekey: key(32),
  signedPrekeySignature: key(64),
  oneTimePrekeys: [key(32)],
});

const PREFIX = 'idk_t';
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

/**
 * Une clé d'identité appartient à UN appareil.
 *
 * Deux appareils qui la partagent permettent au serveur de prouver qu'ils sont
 * la même personne — ce qui vide de son sens le fait d'avoir des comptes
 * séparés — et rendent le handshake X3DH entre eux dégénéré : un DH d'une clé
 * avec elle-même. Le client 0.6.0 produisait ce cas en réutilisant le même
 * stockage moteur pour deux comptes créés sur la même machine.
 */
describe('unicité des clés d’identité', () => {
  test('deux comptes ne peuvent pas publier la même clé d’identité', async () => {
    const shared = key(32);

    const first = await app.inject({
      method: 'POST',
      url: '/v1/auth/register',
      payload: {
        username: `${PREFIX}_a_${counter++}`,
        password: 'password123',
        device: device(shared),
      },
    });
    expect(first.statusCode).toBe(201);

    const second = await app.inject({
      method: 'POST',
      url: '/v1/auth/register',
      payload: {
        username: `${PREFIX}_b_${counter++}`,
        password: 'password123',
        device: device(shared),
      },
    });
    expect(second.statusCode).toBe(409);

    // Le second compte ne doit pas exister à moitié : l'inscription est
    // transactionnelle, un refus ne laisse rien derrière lui.
    const devices = await prisma.device.findMany({
      where: { identityPublicKey: Buffer.from(shared, 'base64') },
    });
    expect(devices).toHaveLength(1);
  });

  test('un appareil supplémentaire du même compte a sa propre clé', async () => {
    const username = `${PREFIX}_multi_${counter++}`;
    const shared = key(32);

    const reg = await app.inject({
      method: 'POST',
      url: '/v1/auth/register',
      payload: { username, password: 'password123', device: device(shared) },
    });
    expect(reg.statusCode).toBe(201);

    // Rattacher un second appareil en réutilisant la clé du premier est refusé,
    // même à l'intérieur d'un seul compte : deux appareils indistinguables
    // cryptographiquement n'ont aucune raison d'exister.
    const same = await app.inject({
      method: 'POST',
      url: '/v1/auth/add-device',
      payload: { username, password: 'password123', device: device(shared) },
    });
    expect(same.statusCode).toBe(409);

    const distinct = await app.inject({
      method: 'POST',
      url: '/v1/auth/add-device',
      payload: { username, password: 'password123', device: device() },
    });
    expect(distinct.statusCode).toBe(201);
  });
});
