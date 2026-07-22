import { randomBytes } from 'node:crypto';
import type { AddressInfo } from 'node:net';
import type { FastifyInstance } from 'fastify';
import { afterAll, beforeAll, describe, expect, test } from 'vitest';
import { WebSocket } from 'ws';
import { buildApp } from '../src/app.js';
import { prisma } from '../src/db/prisma.js';
import { initGateway } from '../src/ws/gateway.js';

/**
 * Présence « en ligne / hors ligne ».
 *
 * Ces épreuves passent par un VRAI serveur à l'écoute et de VRAIES connexions
 * WebSocket : `fastify.inject`, utilisé partout ailleurs, court-circuite le
 * serveur HTTP et ne peut donc rien dire d'une passerelle temps réel.
 *
 * Ce qui est vérifié tient en une phrase : personne n'apparaît sans l'avoir
 * demandé, et personne ne voit sans y avoir droit.
 */

const key = (n: number) => randomBytes(n).toString('base64');
const device = () => ({
  platform: 'linux',
  identityPublicKey: key(32),
  signedPrekey: key(32),
  signedPrekeySignature: key(64),
  oneTimePrekeys: [key(32)],
});

const PREFIX = 'pres_t';
let app: FastifyInstance;
let port: number;
let counter = 0;
const conversations: string[] = [];
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
    payload: {
      username: `${PREFIX}_${label}_${counter++}`,
      password: 'password123',
      device: device(),
    },
  });
  expect(res.statusCode).toBe(201);
  return res.json() as Compte;
}

async function conversationEntre(a: Compte, b: Compte) {
  const res = await app.inject({
    method: 'POST',
    url: '/v1/conversations',
    headers: { authorization: `Bearer ${a.accessToken}` },
    payload: { type: 'direct', participantIds: [b.userId] },
  });
  expect([200, 201]).toContain(res.statusCode);
  const { id } = res.json() as { id: string };
  conversations.push(id);
  return id;
}

/** Une connexion cliente, avec l'historique de ce qu'elle a reçu. */
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
        if (typeof json === 'object' && json !== null) {
          client.recus.push(json as Record<string, unknown>);
        }
      } catch {
        // 'pong' et autres textes bruts : sans intérêt ici
      }
    });
    await client.attendre((m) => m.type === 'ready');
    return client;
  }

  envoyer(message: unknown) {
    this.socket.send(JSON.stringify(message));
  }

  /** Attend un message satisfaisant le prédicat, ou échoue au bout du délai. */
  async attendre(
    predicat: (m: Record<string, unknown>) => boolean,
    delaiMs = 2000,
  ): Promise<Record<string, unknown>> {
    const limite = Date.now() + delaiMs;
    for (;;) {
      const trouve = this.recus.find(predicat);
      if (trouve) return trouve;
      if (Date.now() > limite) {
        throw new Error(`message attendu jamais reçu ; reçus : ${JSON.stringify(this.recus)}`);
      }
      await new Promise((r) => setTimeout(r, 20));
    }
  }

  /** Vérifie qu'aucun message satisfaisant le prédicat n'arrive. */
  async silence(predicat: (m: Record<string, unknown>) => boolean, delaiMs = 400) {
    await new Promise((r) => setTimeout(r, delaiMs));
    expect(this.recus.filter(predicat)).toEqual([]);
  }

  async fermer() {
    if (this.socket.readyState === WebSocket.OPEN) this.socket.close();
    await new Promise((r) => setTimeout(r, 150));
  }
}

const estPresence = (device: string, etat: string) => (m: Record<string, unknown>) =>
  m.type === 'presence' && m.device === device && m.state === etat;

beforeAll(async () => {
  app = await buildApp();
  await app.ready();
  initGateway(app.server);
  await app.listen({ port: 0, host: '127.0.0.1' });
  port = (app.server.address() as AddressInfo).port;
});

afterAll(async () => {
  for (const s of ouvertes) s.close();
  await prisma.conversation.deleteMany({ where: { id: { in: conversations } } });
  await prisma.user.deleteMany({ where: { username: { startsWith: PREFIX } } });
  await app.close();
  await prisma.$disconnect();
});

describe('présence', () => {
  test('un correspondant visible apparaît, puis disparaît en se déconnectant', async () => {
    const alice = await inscrire('alice');
    const bob = await inscrire('bob');
    await conversationEntre(alice, bob);

    const cBob = await Client.connecter(bob);
    cBob.envoyer({ type: 'presence.mode', visible: true });

    const cAlice = await Client.connecter(alice);
    cAlice.envoyer({ type: 'presence.subscribe', devices: [bob.deviceId] });

    // L'instantané compte autant que les évènements : sans lui, un
    // correspondant déjà connecté paraîtrait absent jusqu'à ce qu'il bouge.
    const snapshot = await cAlice.attendre((m) => m.type === 'presence.snapshot');
    expect(snapshot.online).toEqual([bob.deviceId]);

    await cBob.fermer();
    await cAlice.attendre(estPresence(bob.deviceId, 'offline'));
  });

  test("rien n'est diffusé tant que la visibilité n'est pas déclarée", async () => {
    const alice = await inscrire('alice');
    const bob = await inscrire('bob');
    await conversationEntre(alice, bob);

    const cBob = await Client.connecter(bob);
    const cAlice = await Client.connecter(alice);
    cAlice.envoyer({ type: 'presence.subscribe', devices: [bob.deviceId] });

    // Bob est connecté mais n'a rien demandé : c'est le cas des clients
    // antérieurs à la fonctionnalité, et de ceux qui l'ont désactivée.
    const snapshot = await cAlice.attendre((m) => m.type === 'presence.snapshot');
    expect(snapshot.online).toEqual([]);
    await cBob.fermer();
    await cAlice.silence((m) => m.type === 'presence');
  });

  test('sans conversation commune, on ne voit rien', async () => {
    const bob = await inscrire('bob');
    const inconnu = await inscrire('inconnu');

    const cBob = await Client.connecter(bob);
    cBob.envoyer({ type: 'presence.mode', visible: true });

    const cInconnu = await Client.connecter(inconnu);
    cInconnu.envoyer({ type: 'presence.subscribe', devices: [bob.deviceId] });

    const snapshot = await cInconnu.attendre((m) => m.type === 'presence.snapshot');
    expect(snapshot.online).toEqual([]);

    // Et l'abonnement refusé ne doit pas non plus livrer les changements
    // d'état : connaître un identifiant d'appareil ne suffit pas à pister.
    await cBob.fermer();
    await cInconnu.silence((m) => m.type === 'presence');
  });

  test('un blocage coupe la présence des deux côtés, sans attendre la reconnexion', async () => {
    const alice = await inscrire('alice');
    const bob = await inscrire('bob');
    await conversationEntre(alice, bob);

    const cBob = await Client.connecter(bob);
    cBob.envoyer({ type: 'presence.mode', visible: true });
    const cAlice = await Client.connecter(alice);
    cAlice.envoyer({ type: 'presence.mode', visible: true });
    cAlice.envoyer({ type: 'presence.subscribe', devices: [bob.deviceId] });
    cBob.envoyer({ type: 'presence.subscribe', devices: [alice.deviceId] });
    await cAlice.attendre((m) => m.type === 'presence.snapshot');
    await cBob.attendre((m) => m.type === 'presence.snapshot');

    const res = await app.inject({
      method: 'POST',
      url: '/v1/blocks',
      headers: { authorization: `Bearer ${alice.accessToken}` },
      payload: { userId: bob.userId },
    });
    expect(res.statusCode).toBe(204);

    await cBob.fermer();
    await cAlice.silence((m) => m.type === 'presence');

    // Dans l'autre sens aussi : la personne bloquée ne doit pas déduire du
    // silence soudain de l'autre qu'elle vient d'être bloquée.
    await cAlice.fermer();
    await cBob.silence((m) => m.type === 'presence');

    await prisma.block.deleteMany({ where: { blockerUserId: alice.userId } });
  });

  // L'aiguillage des messages a été réécrit pour accueillir la présence :
  // l'indicateur d'écriture, qui passe par le même canal, doit continuer de
  // fonctionner à l'identique.
  test("l'indicateur d'écriture est toujours relayé", async () => {
    const alice = await inscrire('alice');
    const bob = await inscrire('bob');
    const conversationId = await conversationEntre(alice, bob);

    const cBob = await Client.connecter(bob);
    const cAlice = await Client.connecter(alice);
    cAlice.envoyer({ type: 'typing', conversationId, to: [bob.deviceId] });

    const signal = await cBob.attendre((m) => m.type === 'typing');
    expect(signal).toMatchObject({ conversationId, from: alice.deviceId });
  });

  test('une seconde fenêtre fermée ne fait pas passer hors ligne', async () => {
    const alice = await inscrire('alice');
    const bob = await inscrire('bob');
    await conversationEntre(alice, bob);

    const bob1 = await Client.connecter(bob);
    const bob2 = await Client.connecter(bob);
    bob1.envoyer({ type: 'presence.mode', visible: true });

    const cAlice = await Client.connecter(alice);
    cAlice.envoyer({ type: 'presence.subscribe', devices: [bob.deviceId] });
    const snapshot = await cAlice.attendre((m) => m.type === 'presence.snapshot');
    expect(snapshot.online).toEqual([bob.deviceId]);

    await bob2.fermer();
    await cAlice.silence(estPresence(bob.deviceId, 'offline'));

    await bob1.fermer();
    await cAlice.attendre(estPresence(bob.deviceId, 'offline'));
  });
});
