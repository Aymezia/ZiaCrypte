import { randomBytes, randomUUID } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { afterAll, beforeAll, describe, expect, test } from 'vitest';
import { buildApp } from '../src/app.js';
import { prisma } from '../src/db/prisma.js';

/**
 * Canaux de diffusion, côté serveur.
 *
 * Ce que ces épreuves affirment, et qu'aucune ne pourrait déduire du code seul :
 *  - la clé scellée est resservie telle quelle à un nouveau venu (le serveur ne
 *    la touche pas, il la transporte) ;
 *  - SEUL l'admin publie et fait tourner la clé — un abonné qui essaie est
 *    refusé net ;
 *  - un post atteint tous les abonnés SAUF l'appareil qui publie ;
 *  - le blob de canal emprunte le tuyau commun (GET /messages) en se signalant
 *    par `channelId`.
 */

const key = (n: number) => randomBytes(n).toString('base64');
const device = () => ({
  platform: 'linux',
  identityPublicKey: key(32),
  signedPrekey: key(32),
  signedPrekeySignature: key(64),
  oneTimePrekeys: [key(32)],
});

const PREFIX = 'chan_t';
let app: FastifyInstance;
let counter = 0;
const canaux: string[] = [];

interface Compte {
  accessToken: string;
  userId: string;
  deviceId: string;
}

async function inscrire(label: string): Promise<Compte> {
  const res = await app.inject({
    method: 'POST',
    url: '/v1/auth/register',
    payload: { username: `${PREFIX}_${label}_${counter++}`, password: 'password123', device: device() },
  });
  expect(res.statusCode).toBe(201);
  return res.json() as Compte;
}

const auth = (c: Compte) => ({ authorization: `Bearer ${c.accessToken}` });

beforeAll(async () => {
  app = await buildApp();
  await app.ready();
});

afterAll(async () => {
  await prisma.channel.deleteMany({ where: { id: { in: canaux } } });
  await prisma.user.deleteMany({ where: { username: { startsWith: PREFIX } } });
  await app.close();
  await prisma.$disconnect();
});

async function creerCanal(admin: Compte, sealed = key(120)): Promise<string> {
  const res = await app.inject({
    method: 'POST',
    url: '/v1/channels',
    headers: auth(admin),
    payload: { sealedKey: sealed },
  });
  expect(res.statusCode).toBe(201);
  const { id } = res.json() as { id: string };
  canaux.push(id);
  return id;
}

describe('canaux', () => {
  test('la clé scellée est resservie à l’identique à un nouveau venu', async () => {
    const admin = await inscrire('admin');
    const abonne = await inscrire('abonne');
    const sealed = key(120);
    const id = await creerCanal(admin, sealed);

    // N'importe quel compte peut récupérer la clé — il lui faudra le secret du
    // lien pour l'ouvrir, que le serveur n'a pas.
    const res = await app.inject({ method: 'GET', url: `/v1/channels/${id}/key`, headers: auth(abonne) });
    expect(res.statusCode).toBe(200);
    expect((res.json() as { sealedKey: string }).sealedKey).toBe(sealed);
  });

  test('seul l’admin peut déposer et faire tourner la clé', async () => {
    const admin = await inscrire('admin');
    const intrus = await inscrire('intrus');
    const id = await creerCanal(admin);

    const refuse = await app.inject({
      method: 'PUT',
      url: `/v1/channels/${id}/key`,
      headers: auth(intrus),
      payload: { sealedKey: key(120) },
    });
    expect(refuse.statusCode).toBe(403);

    const nouvelle = key(120);
    const ok = await app.inject({
      method: 'PUT',
      url: `/v1/channels/${id}/key`,
      headers: auth(admin),
      payload: { sealedKey: nouvelle },
    });
    expect(ok.statusCode).toBe(204);

    const relu = await app.inject({ method: 'GET', url: `/v1/channels/${id}/key`, headers: auth(admin) });
    expect((relu.json() as { sealedKey: string }).sealedKey).toBe(nouvelle);
  });

  test('seul l’admin publie ; un abonné qui essaie est refusé', async () => {
    const admin = await inscrire('admin');
    const abonne = await inscrire('abonne');
    const id = await creerCanal(admin);

    await app.inject({ method: 'POST', url: `/v1/channels/${id}/subscribers`, headers: auth(abonne) });

    const refuse = await app.inject({
      method: 'POST',
      url: `/v1/channels/${id}/messages`,
      headers: auth(abonne),
      payload: { clientMessageId: randomUUID(), header: key(1), ciphertext: key(40) },
    });
    expect(refuse.statusCode).toBe(403);
  });

  test('un post atteint tous les abonnés sauf l’appareil qui publie, via GET /messages', async () => {
    const admin = await inscrire('admin');
    const a = await inscrire('a');
    const b = await inscrire('b');
    const id = await creerCanal(admin);

    for (const c of [a, b]) {
      const r = await app.inject({ method: 'POST', url: `/v1/channels/${id}/subscribers`, headers: auth(c) });
      expect(r.statusCode).toBe(204);
    }
    // L'admin s'abonne aussi depuis son propre appareil : il ne devra PAS
    // recevoir son propre post.
    await app.inject({ method: 'POST', url: `/v1/channels/${id}/subscribers`, headers: auth(admin) });

    const clientMessageId = randomUUID();
    const post = await app.inject({
      method: 'POST',
      url: `/v1/channels/${id}/messages`,
      headers: auth(admin),
      payload: { clientMessageId, header: key(1), ciphertext: key(60) },
    });
    expect(post.statusCode).toBe(201);
    // a et b, pas l'admin.
    expect((post.json() as { delivered: number }).delivered).toBe(2);

    // a reçoit le blob par le tuyau commun, marqué channelId.
    const boiteA = await app.inject({ method: 'GET', url: '/v1/messages', headers: auth(a) });
    const blobs = boiteA.json() as Array<{ channelId: string | null; senderDeviceId: string; clientMessageId: string }>;
    const recu = blobs.find((m) => m.clientMessageId === clientMessageId);
    expect(recu).toBeDefined();
    expect(recu!.channelId).toBe(id);
    expect(recu!.senderDeviceId).toBe(admin.deviceId);

    // L'admin ne se voit rien remettre.
    const boiteAdmin = await app.inject({ method: 'GET', url: '/v1/messages', headers: auth(admin) });
    const pourAdmin = (boiteAdmin.json() as Array<{ clientMessageId: string }>)
      .filter((m) => m.clientMessageId === clientMessageId);
    expect(pourAdmin).toEqual([]);
  });

  test('se désabonner arrête la remise des posts suivants', async () => {
    const admin = await inscrire('admin');
    const abonne = await inscrire('abonne');
    const id = await creerCanal(admin);

    await app.inject({ method: 'POST', url: `/v1/channels/${id}/subscribers`, headers: auth(abonne) });
    await app.inject({
      method: 'DELETE',
      url: `/v1/channels/${id}/subscribers/${abonne.deviceId}`,
      headers: auth(abonne),
    });

    const clientMessageId = randomUUID();
    const post = await app.inject({
      method: 'POST',
      url: `/v1/channels/${id}/messages`,
      headers: auth(admin),
      payload: { clientMessageId, header: key(1), ciphertext: key(40) },
    });
    expect((post.json() as { delivered: number }).delivered).toBe(0);

    const boite = await app.inject({ method: 'GET', url: '/v1/messages', headers: auth(abonne) });
    const recu = (boite.json() as Array<{ clientMessageId: string }>)
      .filter((m) => m.clientMessageId === clientMessageId);
    expect(recu).toEqual([]);
  });

  test('un tiers ne peut pas désabonner l’appareil d’un autre', async () => {
    const admin = await inscrire('admin');
    const abonne = await inscrire('abonne');
    const intrus = await inscrire('intrus');
    const id = await creerCanal(admin);
    await app.inject({ method: 'POST', url: `/v1/channels/${id}/subscribers`, headers: auth(abonne) });

    const refuse = await app.inject({
      method: 'DELETE',
      url: `/v1/channels/${id}/subscribers/${abonne.deviceId}`,
      headers: auth(intrus),
    });
    expect(refuse.statusCode).toBe(403);

    // L'admin, lui, peut retirer n'importe quel abonné.
    const parAdmin = await app.inject({
      method: 'DELETE',
      url: `/v1/channels/${id}/subscribers/${abonne.deviceId}`,
      headers: auth(admin),
    });
    expect(parAdmin.statusCode).toBe(204);
  });

  test('les métadonnées distinguent admin, abonné et simple visiteur', async () => {
    const admin = await inscrire('admin');
    const abonne = await inscrire('abonne');
    const visiteur = await inscrire('visiteur');
    const id = await creerCanal(admin);
    await app.inject({ method: 'POST', url: `/v1/channels/${id}/subscribers`, headers: auth(abonne) });

    const vuAdmin = (await app.inject({ method: 'GET', url: `/v1/channels/${id}`, headers: auth(admin) })).json();
    expect(vuAdmin).toMatchObject({ isAdmin: true, isSubscribed: false, subscriberCount: 1, hasKey: true });

    const vuAbonne = (await app.inject({ method: 'GET', url: `/v1/channels/${id}`, headers: auth(abonne) })).json();
    expect(vuAbonne).toMatchObject({ isAdmin: false, isSubscribed: true });

    const vuVisiteur = (await app.inject({ method: 'GET', url: `/v1/channels/${id}`, headers: auth(visiteur) })).json();
    expect(vuVisiteur).toMatchObject({ isAdmin: false, isSubscribed: false });
  });
});
