import { randomUUID } from 'node:crypto';
import { Prisma } from '@prisma/client';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../db/prisma.js';
import { HttpError } from '../../lib/errors.js';
import { requireAuth } from '../../plugins/auth.js';
import { messageRateLimit } from '../../plugins/rate-limit.js';
import { estBloque } from '../blocks/blocks.routes.js';
import { gateway } from '../../ws/gateway.js';
import { requireMembership } from '../conversations/membership.js';
import { pushService } from '../push/push.service.js';

const b64 = (buf: Uint8Array) => Buffer.from(buf).toString('base64');
const fromB64 = (s: string) => {
  const b = Buffer.from(s, 'base64');
  const out = new Uint8Array(b.length);
  out.set(b);
  return out;
};

const sendSchema = z.object({
  conversationId: z.string().uuid(),
  recipientDeviceId: z.string().uuid(),
  clientMessageId: z.string().uuid(),
  header: z.string(), // opaque : en-tête ratchet (+ matériel X3DH pour le 1er message)
  ciphertext: z.string(), // opaque : AEAD
});

const groupSendSchema = z.object({
  conversationId: z.string().uuid(),
  clientMessageId: z.string().uuid(),
  // Tous les appareils du groupe, le nôtre exclu par le client.
  recipientDeviceIds: z.array(z.string().uuid()).min(1).max(500),
  header: z.string(),
  ciphertext: z.string(),
});

export async function messagesRoutes(app: FastifyInstance) {
  // Dépose un blob chiffré à destination d'un appareil. Le serveur ne fait que
  // relayer des octets opaques — il ne peut rien déchiffrer.
  app.post('/messages', { preHandler: requireAuth, config: messageRateLimit() }, async (request, reply) => {
    const body = sendSchema.parse(request.body);
    const me = request.auth!;

    await requireMembership(body.conversationId, me.userId);

    const recipient = await prisma.device.findUnique({ where: { id: body.recipientDeviceId } });
    if (!recipient || !recipient.isActive) {
      throw new HttpError(404, 'appareil destinataire introuvable');
    }

    // Blocage : on accepte la requête et on ne stocke RIEN.
    //
    // Répondre par une erreur apprendrait à l'expéditeur qu'il est bloqué, ce
    // qui, dans les situations de harcèlement, se paie par une escalade ou la
    // création d'un autre compte. Vu de lui, le message part et n'est jamais
    // remis — indiscernable d'un destinataire qui ne relève pas.
    //
    // La réponse imite EXACTEMENT celle d'un dépôt réussi : même code 201, même
    // forme, un identifiant d'apparence normale. Un premier essai renvoyait 202
    // au lieu de 201 — il suffisait de comparer les codes pour savoir qu'on
    // était bloqué, ce qui vidait la mesure de son sens. L'identifiant est
    // aléatoire et ne correspond à aucune ligne : le serveur n'a rien écrit.
    if (await estBloque(me.userId, recipient.userId)) {
      return reply.code(201).send({ id: randomUUID() });
    }

    try {
      const blob = await prisma.messageBlob.create({
        data: {
          conversationId: body.conversationId,
          senderDeviceId: me.deviceId,
          recipientDeviceId: body.recipientDeviceId,
          clientMessageId: body.clientMessageId,
          ratchetHeader: fromB64(body.header),
          ciphertext: fromB64(body.ciphertext),
          expiresAt: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000),
        },
      });
      // Réveille le destinataire s'il est connecté ; sinon on tente un push
      // sans contenu. Dans tous les cas la remise ne dépend d'aucun des deux :
      // le blob est persisté et sera relevé à la prochaine connexion.
      //
      // Pas d'`await` : un fournisseur push lent ne doit pas retarder la
      // réponse à l'expéditeur, et l'échec est déjà avalé par wakeDevice.
      if (!gateway?.notifyPending(body.recipientDeviceId)) {
        void pushService?.wakeDevice(body.recipientDeviceId);
      }
      return reply.code(201).send({ id: blob.id });
    } catch (e) {
      // Idempotence anti-rejeu : (recipientDeviceId, clientMessageId) est unique.
      if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2002') {
        return reply.code(200).send({ deduplicated: true });
      }
      throw e;
    }
  });

  /**
   * Dépôt d'un message de GROUPE chiffré une seule fois (clés d'expéditeur).
   *
   * Le client chiffre UNE fois avec la clé de groupe puis dépose ici, en
   * nommant tous les appareils destinataires. Sans cette route, il devait
   * chiffrer et téléverser une fois par appareil : dix membres à deux
   * appareils, c'était vingt requêtes pour un message.
   *
   * ## Ce que le serveur fait, et ne fait pas
   *
   * Il écrit une ligne de remise par destinataire, toutes portant LES MÊMES
   * octets. Le chiffré est donc dupliqué en base — c'est un choix assumé : le
   * gain visé (le coût côté client et la bande passante) est intégralement
   * obtenu, et déduplique-r plus tard ne changera rien pour les clients déjà
   * déployés. Il ne peut toujours rien déchiffrer : la clé de groupe n'a jamais
   * transité par lui, elle a été distribuée dans le canal pair-à-pair.
   */
  app.post('/messages/group', { preHandler: requireAuth, config: messageRateLimit() },
    async (request, reply) => {
      const body = groupSendSchema.parse(request.body);
      const me = request.auth!;

      await requireMembership(body.conversationId, me.userId);

      const devices = await prisma.device.findMany({
        where: { id: { in: body.recipientDeviceIds }, isActive: true },
        select: { id: true, userId: true },
      });

      // Blocages appliqués destinataire par destinataire, en silence : celui
      // qui bloque ne doit pas être trahi, et l'expéditeur ne doit pas
      // apprendre qu'il l'est. On n'écrit simplement pas sa ligne.
      const bloques = await Promise.all(
        devices.map((d) => estBloque(me.userId, d.userId)),
      );
      const cibles = devices.filter((_, i) => !bloques[i]);

      const header = fromB64(body.header);
      const ciphertext = fromB64(body.ciphertext);
      const expiresAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);

      // skipDuplicates : (recipientDeviceId, clientMessageId) est unique, un
      // renvoi après coupure réseau ne doit pas échouer ni dupliquer.
      await prisma.messageBlob.createMany({
        data: cibles.map((d) => ({
          conversationId: body.conversationId,
          senderDeviceId: me.deviceId,
          recipientDeviceId: d.id,
          clientMessageId: body.clientMessageId,
          ratchetHeader: header,
          ciphertext,
          expiresAt,
        })),
        skipDuplicates: true,
      });

      for (const d of cibles) {
        if (!gateway?.notifyPending(d.id)) void pushService?.wakeDevice(d.id);
      }

      // Le nombre d'appareils servis n'est pas renvoyé : il varie selon les
      // blocages, et le publier apprendrait à l'expéditeur qu'il est bloqué.
      return reply.code(201).send({ ok: true });
    });

  /**
   * Statut de remise des messages que l'appareil courant a ENVOYÉS.
   *
   * Le serveur connaît déjà la date de remise : il la pose lui-même quand le
   * destinataire relève sa boîte. L'exposer ici à l'expéditeur ne lui apprend
   * donc rien de neuf — c'est le reçu de remise, le signal « ton message est
   * arrivé sur un appareil du correspondant ».
   *
   * La requête est scopée à `senderDeviceId` : on ne renvoie le statut que des
   * blobs que CET appareil a émis. Impossible de sonder la remise des messages
   * d'autrui.
   *
   * Il n'y a délibérément PAS de reçu de lecture ici. Un « lu » passant par le
   * serveur lui révélerait que le destinataire a ouvert le message — une
   * métadonnée que le chiffrement de bout en bout ne protège pas. S'il est un
   * jour ajouté, ce sera par un message chiffré, et sur option.
   */
  app.get('/messages/status', { preHandler: requireAuth }, async (request) => {
    const { ids } = z.object({ ids: z.string() }).parse(request.query);
    const list = ids.split(',').filter(Boolean).slice(0, 500);
    if (list.length === 0) return { delivered: [] };

    const rows = await prisma.messageBlob.findMany({
      where: {
        senderDeviceId: request.auth!.deviceId,
        clientMessageId: { in: list },
        deliveredAt: { not: null },
      },
      select: { clientMessageId: true },
    });
    return { delivered: rows.map((r) => r.clientMessageId) };
  });

  // Récupère les blobs en attente pour l'appareil courant, puis les marque livrés.
  app.get('/messages', { preHandler: requireAuth }, async (request) => {
    const deviceId = request.auth!.deviceId;
    const pending = await prisma.messageBlob.findMany({
      where: { recipientDeviceId: deviceId, deliveredAt: null },
      orderBy: { createdAt: 'asc' },
      take: 200,
      // Le pseudo de l'expéditeur permet au destinataire d'afficher qui lui
      // écrit, y compris pour une conversation qu'il n'a pas initiée.
      include: { sender: { include: { user: true } } },
    });

    if (pending.length > 0) {
      await prisma.messageBlob.updateMany({
        where: { id: { in: pending.map((m) => m.id) } },
        data: { deliveredAt: new Date() },
      });
    }

    return pending.map((m) => ({
      id: m.id,
      conversationId: m.conversationId,
      senderDeviceId: m.senderDeviceId,
      // Absents pour un message SCELLÉ : le serveur ne sait pas qui l'a
      // déposé, et c'est tout l'objet. Le client trouve l'expéditeur à
      // l'intérieur de l'enveloppe, une fois ouverte. Le champ `sealed` le lui
      // signale — sans quoi il chercherait un en-tête de ratchet qui n'existe
      // pas et rejetterait le message sans comprendre pourquoi.
      sealed: m.senderDeviceId === null,
      senderUsername: m.sender?.user.username ?? null,
      // Identifiant de compte de l'expéditeur : sert d'ancrage stable pour
      // l'épinglage des clés d'identité côté client. Le pseudo ne convient pas,
      // il peut être réattribué après suppression d'un compte.
      senderUserId: m.sender?.userId ?? null,
      clientMessageId: m.clientMessageId,
      header: b64(m.ratchetHeader),
      ciphertext: b64(m.ciphertext),
      timestampMs: m.createdAt.getTime(),
    }));
  });
}
