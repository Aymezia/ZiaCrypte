import { randomBytes, randomUUID } from 'node:crypto';
import type { AddressInfo } from 'node:net';
import type { FastifyInstance } from 'fastify';
import { afterAll, beforeAll, describe, expect, test } from 'vitest';
import { WebSocket } from 'ws';
import { buildApp } from '../src/app.js';
import { prisma } from '../src/db/prisma.js';
import { initGateway } from '../src/ws/gateway.js';

/**
 * Signalisation d'appel : le serveur AIGUILLE sans jamais lire.
 *
 * Ce qui est vérifié : une invitation est relayée à l'appareil appelé, avec son
 * contenu (payload chiffré) INTACT et jamais inspecté ; une invitation d'un
 * correspondant bloqué n'arrive pas ; les étapes suivantes (offer/ice) se
 * relaient vers un appareil connecté.
 *
 * On passe par un VRAI serveur à l'écoute et de vraies sockets : `inject` ne
 * peut rien dire d'une passerelle temps réel.
 */

const key = (n: number) => randomBytes(n).toString('base64');
const device = () => ({
  platform: 'linux',
  identityPublicKey: key(32),
  signedPrekey: key(32),
  signedPrekeySignature: key(64),
  oneTimePrekeys: [key(32)],
});

const PREFIX = 'call_t';
let app: FastifyInstance;
let port: number;
let counter = 0;
const ouvertes: WebSocket[] = [];

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

class Client {
  readonly recus: Record<string, unknown>[] = [];
  private constructor(readonly socket: WebSocket) {}

  static async connecter(compte: Compte): Promise<Client> {
    const socket = new WebSocket(
      `ws://127.0.0.1:${port}/ws?token=${encodeURIComponent(compte.accessToken)}`,
    );
    ouvertes.push(socket);
    const client = new Client(socket);
    socket.on('message', (raw) => {
      try {
        const json: unknown = JSON.parse(raw.toString());
        if (typeof json === 'object' && json !== null) client.recus.push(json as Record<string, unknown>);
      } catch {
        // 'pong' etc.
      }
    });
    await client.attendre((m) => m.type === 'ready');
    return client;
  }

  envoyer(message: unknown) {
    this.socket.send(JSON.stringify(message));
  }

  async attendre(predicat: (m: Record<string, unknown>) => boolean, delaiMs = 2000) {
    const limite = Date.now() + delaiMs;
    for (;;) {
      const t = this.recus.find(predicat);
      if (t) return t;
      if (Date.now() > limite) {
        throw new Error(`message attendu jamais reçu ; reçus : ${JSON.stringify(this.recus)}`);
      }
      await new Promise((r) => setTimeout(r, 20));
    }
  }

  async silence(predicat: (m: Record<string, unknown>) => boolean, delaiMs = 400) {
    await new Promise((r) => setTimeout(r, delaiMs));
    expect(this.recus.filter(predicat)).toEqual([]);
  }
}

beforeAll(async () => {
  app = await buildApp();
  await app.ready();
  initGateway(app.server);
  await app.listen({ port: 0, host: '127.0.0.1' });
  port = (app.server.address() as AddressInfo).port;
});

afterAll(async () => {
  for (const s of ouvertes) s.close();
  await prisma.user.deleteMany({ where: { username: { startsWith: PREFIX } } });
  await app.close();
  await prisma.$disconnect();
});

const estSignal = (m: Record<string, unknown>) => m.type === 'call.signal';

describe('signalisation d’appel', () => {
  test('une invitation est relayée à l’appelé, contenu opaque intact', async () => {
    const alice = await inscrire('alice');
    const bob = await inscrire('bob');
    const cBob = await Client.connecter(bob);
    const cAlice = await Client.connecter(alice);

    // Le payload imite un SDP chiffré : le serveur ne doit pas le toucher.
    const payload = key(200);
    const callId = randomUUID();
    cAlice.envoyer({ type: 'call.signal', to: [bob.deviceId], callId, kind: 'invite', payload });

    const recu = await cBob.attendre(estSignal);
    expect(recu).toMatchObject({
      type: 'call.signal',
      from: alice.deviceId,
      callId,
      kind: 'invite',
      payload, // rendu tel quel, non inspecté
    });
  });

  test('une étape suivante se relaie vers l’appareil connecté', async () => {
    const alice = await inscrire('alice');
    const bob = await inscrire('bob');
    const cBob = await Client.connecter(bob);
    const cAlice = await Client.connecter(alice);

    const callId = randomUUID();
    cAlice.envoyer({ type: 'call.signal', to: [bob.deviceId], callId, kind: 'offer', payload: key(300) });
    const offre = await cBob.attendre((m) => estSignal(m) && m.kind === 'offer');
    expect(offre.callId).toBe(callId);

    // Réponse en sens inverse.
    cBob.envoyer({ type: 'call.signal', to: [alice.deviceId], callId, kind: 'answer', payload: key(300) });
    const rep = await cAlice.attendre((m) => estSignal(m) && m.kind === 'answer');
    expect(rep.from).toBe(bob.deviceId);
  });

  test('une invitation d’un correspondant bloqué n’arrive pas', async () => {
    const alice = await inscrire('alice');
    const bob = await inscrire('bob');
    const cBob = await Client.connecter(bob);
    const cAlice = await Client.connecter(alice);

    // Bob bloque Alice.
    const res = await app.inject({
      method: 'POST',
      url: '/v1/blocks',
      headers: { authorization: `Bearer ${bob.accessToken}` },
      payload: { userId: alice.userId },
    });
    expect(res.statusCode).toBe(204);

    cAlice.envoyer({
      type: 'call.signal',
      to: [bob.deviceId],
      callId: randomUUID(),
      kind: 'invite',
      payload: key(200),
    });
    // Rien ne doit sonner chez Bob.
    await cBob.silence(estSignal);

    await prisma.block.deleteMany({ where: { blockerUserId: bob.userId } });
  });

  test('un payload surdimensionné est rejeté (pas de canal détourné)', async () => {
    const alice = await inscrire('alice');
    const bob = await inscrire('bob');
    const cBob = await Client.connecter(bob);
    const cAlice = await Client.connecter(alice);

    cAlice.envoyer({
      type: 'call.signal',
      to: [bob.deviceId],
      callId: randomUUID(),
      kind: 'invite',
      payload: 'x'.repeat(17 * 1024), // au-delà de la borne
    });
    await cBob.silence(estSignal);
  });
});
