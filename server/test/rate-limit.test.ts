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

const PREFIX = 'rl_t';
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
 * La vérification du mot de passe utilise Argon2id, délibérément coûteux. Sans
 * limite, ce coût se retourne contre le serveur : quelques centaines de
 * requêtes par seconde suffisent à le rendre indisponible, sans même chercher à
 * deviner un mot de passe.
 */
describe('limitation de débit', () => {
  test('les tentatives de connexion répétées finissent par être refusées', async () => {
    const username = `${PREFIX}_cible_${counter++}`;
    await app.inject({
      method: 'POST',
      url: '/v1/auth/register',
      payload: { username, password: 'password123', device: device() },
    });

    const codes: number[] = [];
    for (let i = 0; i < 15; i++) {
      const res = await app.inject({
        method: 'POST',
        url: '/v1/auth/login',
        payload: { username, password: 'mauvais', deviceId: crypto.randomUUID() },
        headers: { 'x-forwarded-for': '203.0.113.10' },
      });
      codes.push(res.statusCode);
    }

    // Les premières échouent en 401 (identifiants), les suivantes en 429.
    expect(codes).toContain(401);
    expect(codes).toContain(429);
    // Et une fois la limite atteinte, elle le reste sur la fenêtre.
    expect(codes.at(-1)).toBe(429);
  });

  /**
   * Le point le plus facile à rater.
   *
   * nginx est configuré avec `$proxy_add_x_forwarded_for`, qui AJOUTE l'adresse
   * réelle du client au bout de la chaîne X-Forwarded-For. Ce que le client a
   * pu inventer se retrouve donc à gauche, et l'adresse vraie à droite.
   *
   * Avec `trustProxy` limité à la boucle locale, Fastify remonte la chaîne
   * depuis la droite et s'arrête à la première adresse non fiable : celle que
   * nginx a posée. L'invention du client est ignorée.
   *
   * Ce test reproduit exactement cette forme. Il vaut donc aussi comme garde
   * sur la configuration nginx : si l'on remplaçait
   * `$proxy_add_x_forwarded_for` par `$http_x_forwarded_for` (simple recopie),
   * la limite deviendrait contournable.
   */
  test('une adresse forgée par le client ne contourne pas la limite', async () => {
    const username = `${PREFIX}_spoof_${counter++}`;
    await app.inject({
      method: 'POST',
      url: '/v1/auth/register',
      payload: { username, password: 'password123', device: device() },
    });

    // Le client invente une adresse différente à chaque requête ; nginx ajoute
    // derrière la sienne, toujours la même.
    const vraieAdresse = '203.0.113.200';
    const codes: number[] = [];
    for (let i = 0; i < 15; i++) {
      const res = await app.inject({
        method: 'POST',
        url: '/v1/auth/login',
        payload: { username, password: 'mauvais', deviceId: crypto.randomUUID() },
        headers: { 'x-forwarded-for': `198.51.100.${i}, ${vraieAdresse}` },
      });
      codes.push(res.statusCode);
    }

    // Si l'usurpation fonctionnait, chaque requête aurait sa propre clé et
    // aucune ne serait refusée.
    expect(codes).toContain(429);
  });

  /**
   * Régression. La clé DOIT contenir le pseudo, pour qu'une adresse partagée
   * (entreprise, université, NAT d'opérateur) ne fasse pas bloquer tout le monde
   * dès qu'un utilisateur se trompe de mot de passe.
   *
   * Le hook de limitation tourne par défaut à `onRequest`, avant l'analyse du
   * corps : `request.body` y est vide et le pseudo n'atteignait jamais la clé.
   * Les tests passaient malgré tout parce qu'ils utilisaient des adresses
   * distinctes — ce cas-ci est celui qui l'a révélé.
   */
  test('depuis une même adresse, un compte épuisé n’en bloque pas un autre', async () => {
    const a = `${PREFIX}_meme_a_${counter++}`;
    const b = `${PREFIX}_meme_b_${counter++}`;
    for (const username of [a, b]) {
      await app.inject({
        method: 'POST',
        url: '/v1/auth/register',
        payload: { username, password: 'password123', device: device() },
      });
    }

    const memeAdresse = '203.0.113.55';
    for (let i = 0; i < 15; i++) {
      await app.inject({
        method: 'POST',
        url: '/v1/auth/login',
        payload: { username: a, password: 'mauvais', deviceId: crypto.randomUUID() },
        headers: { 'x-forwarded-for': memeAdresse },
      });
    }

    const res = await app.inject({
      method: 'POST',
      url: '/v1/auth/login',
      payload: { username: b, password: 'mauvais', deviceId: crypto.randomUUID() },
      headers: { 'x-forwarded-for': memeAdresse },
    });
    expect(res.statusCode).toBe(401);
  });

  test('deux comptes distincts ne se bloquent pas l’un l’autre', async () => {
    const a = `${PREFIX}_a_${counter++}`;
    const b = `${PREFIX}_b_${counter++}`;
    for (const username of [a, b]) {
      await app.inject({
        method: 'POST',
        url: '/v1/auth/register',
        payload: { username, password: 'password123', device: device() },
      });
    }

    // On épuise la limite sur A depuis une adresse donnée…
    for (let i = 0; i < 15; i++) {
      await app.inject({
        method: 'POST',
        url: '/v1/auth/login',
        payload: { username: a, password: 'mauvais', deviceId: crypto.randomUUID() },
        headers: { 'x-forwarded-for': '203.0.113.77' },
      });
    }

    // …B, visé depuis une AUTRE adresse, doit rester joignable : la clé
    // combine l'adresse et le pseudo.
    const res = await app.inject({
      method: 'POST',
      url: '/v1/auth/login',
      payload: { username: b, password: 'mauvais', deviceId: crypto.randomUUID() },
      headers: { 'x-forwarded-for': '203.0.113.88' },
    });
    expect(res.statusCode).toBe(401);
  });
});
