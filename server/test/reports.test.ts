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

const PREFIX = 'report_t';
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
  return {
    username,
    ...(res.json() as { accessToken: string; userId: string; deviceId: string; role: string }),
  };
}

const codeFor = (secret: string) => totp(base32Decode(secret), Date.now() / 1000, 6);

/**
 * Crée un compte d'administration : 2FA obligatoire (le serveur refuse un admin
 * sans second facteur), puis élévation du rôle en base — l'API ne permet
 * délibérément pas de se promouvoir soi-même.
 */
async function admin(label: string) {
  const u = await register(label);
  const auth = { authorization: `Bearer ${u.accessToken}` };

  const setup = await app.inject({ method: 'POST', url: '/v1/auth/2fa/setup', headers: auth });
  const secret = setup.json().secret as string;
  const on = await app.inject({
    method: 'POST',
    url: '/v1/auth/2fa/enable',
    headers: auth,
    payload: { code: codeFor(secret) },
  });
  expect(on.statusCode).toBe(200);

  await prisma.user.update({ where: { id: u.userId }, data: { role: 'admin' } });
  return { ...u, secret, auth };
}

beforeAll(async () => {
  app = await buildApp();
  await app.ready();
});

afterAll(async () => {
  // Les signalements n'ont pas de clé étrangère vers les comptes (voulu : ils
  // survivent à la suppression du compte visé), donc rien n'est effacé en
  // cascade — on nettoie explicitement.
  await prisma.report.deleteMany({
    where: { OR: [{ reporterLabel: { startsWith: PREFIX } }, { reportedLabel: { startsWith: PREFIX } }] },
  });
  await prisma.user.deleteMany({ where: { username: { startsWith: PREFIX } } });
  await app.close();
  await prisma.$disconnect();
});

describe('signalement d’abus', () => {
  test('un destinataire signale, seul un admin muni d’un code le voit et le traite', async () => {
    const victime = await register('victime');
    const abuseur = await register('abuseur');
    const moderateur = await admin('moderateur');

    // --- Dépôt : la victime transmet le clair qu'elle a DÉJÀ déchiffré -------
    const depot = await app.inject({
      method: 'POST',
      url: '/v1/reports',
      headers: { authorization: `Bearer ${victime.accessToken}` },
      payload: {
        reportedUsername: abuseur.username,
        reason: 'harcelement',
        note: 'insiste malgré mes refus',
        content: 'message abusif en clair',
        context: JSON.stringify({ conversationId: 'test' }),
      },
    });
    expect(depot.statusCode).toBe(201);

    // --- Un compte ordinaire n'accède pas à la file ------------------------
    // 404 et non 403 : une réponse distincte permettrait d'énumérer les comptes
    // d'administration, cible la plus rentable du système.
    const refus = await app.inject({
      method: 'GET',
      url: '/v1/admin/reports',
      headers: { authorization: `Bearer ${victime.accessToken}` },
    });
    expect(refus.statusCode).toBe(404);

    // --- Un admin SANS code frais est refusé -------------------------------
    // Le second facteur est exigé à chaque action : un jeton d'accès volé ne
    // suffit pas.
    const sansCode = await app.inject({
      method: 'GET',
      url: '/v1/admin/reports',
      headers: moderateur.auth,
    });
    expect(sansCode.statusCode).toBe(403);

    // --- Avec le code : le signalement est là, avec le clair transmis -------
    const avecCode = await app.inject({
      method: 'GET',
      url: '/v1/admin/reports',
      headers: { ...moderateur.auth, 'x-admin-totp': codeFor(moderateur.secret) },
    });
    expect(avecCode.statusCode).toBe(200);
    const liste = avecCode.json() as Array<Record<string, unknown>>;
    const mien = liste.find((r) => r.compteVise === abuseur.username);
    expect(mien).toBeDefined();
    expect(mien!.motif).toBe('harcelement');
    expect(mien!.signalePar).toBe(victime.username);
    // Le serveur ne détient QUE ce que la victime a choisi de transmettre.
    expect(mien!.contenu).toBe('message abusif en clair');
    expect(mien!.statut).toBe('open');

    // --- Traitement --------------------------------------------------------
    const resolu = await app.inject({
      method: 'POST',
      url: `/v1/admin/reports/${mien!.id}/resolve`,
      headers: { ...moderateur.auth, 'x-admin-totp': codeFor(moderateur.secret) },
      payload: { status: 'resolved', resolution: 'compte averti' },
    });
    expect(resolu.statusCode).toBe(200);

    // Il quitte la file « à traiter »...
    const ouverts = await app.inject({
      method: 'GET',
      url: '/v1/admin/reports?status=open',
      headers: { ...moderateur.auth, 'x-admin-totp': codeFor(moderateur.secret) },
    });
    expect(
      (ouverts.json() as Array<Record<string, unknown>>).some((r) => r.id === mien!.id),
    ).toBe(false);

    // ...sans disparaître : la trace reste consultable.
    const tous = await app.inject({
      method: 'GET',
      url: '/v1/admin/reports?status=all',
      headers: { ...moderateur.auth, 'x-admin-totp': codeFor(moderateur.secret) },
    });
    const apres = (tous.json() as Array<Record<string, unknown>>).find((r) => r.id === mien!.id);
    expect(apres!.statut).toBe('resolved');

    // --- Le traitement est journalisé --------------------------------------
    // Un pouvoir sans trace n'est pas un pouvoir encadré.
    const journal = await app.inject({
      method: 'GET',
      url: '/v1/admin/actions',
      headers: { ...moderateur.auth, 'x-admin-totp': codeFor(moderateur.secret) },
    });
    expect(
      (journal.json() as Array<Record<string, unknown>>).some(
        (a) => a.action === 'report_resolved' && a.cible === abuseur.username,
      ),
    ).toBe(true);
  });

  test('un signalement reste recevable sans copie du message', async () => {
    // Harcèlement répété, spam : le nom du compte suffit à agir. Exiger une
    // copie découragerait de signaler ce qui compte le plus.
    const u = await register('sanscopie');
    const cible = await register('cible');
    const res = await app.inject({
      method: 'POST',
      url: '/v1/reports',
      headers: { authorization: `Bearer ${u.accessToken}` },
      payload: { reportedUsername: cible.username, reason: 'spam' },
    });
    expect(res.statusCode).toBe(201);
  });

  test('un signalement survit à la suppression du compte visé', async () => {
    // Sinon supprimer un compte effacerait les preuves qui justifiaient de le
    // supprimer.
    const u = await register('temoin');
    const condamne = await register('condamne');
    await app.inject({
      method: 'POST',
      url: '/v1/reports',
      headers: { authorization: `Bearer ${u.accessToken}` },
      payload: {
        reportedUsername: condamne.username,
        reason: 'contenu_illegal',
        content: 'preuve',
      },
    });

    await prisma.user.delete({ where: { id: condamne.userId } });

    const restant = await prisma.report.findFirst({
      where: { reportedLabel: condamne.username },
    });
    expect(restant).not.toBeNull();
    expect(restant!.content).toBe('preuve');
  });

  test('le dépôt exige une authentification', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/v1/reports',
      payload: { reportedUsername: 'quelquun', reason: 'spam' },
    });
    expect(res.statusCode).toBe(401);
  });
});
