import { Prisma } from '@prisma/client';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../db/prisma.js';
import { HttpError } from '../../lib/errors.js';
import { requireAuth } from '../../plugins/auth.js';
import { messageRateLimit } from '../../plugins/rate-limit.js';
import { gateway } from '../../ws/gateway.js';
import { pushService } from '../push/push.service.js';

/**
 * Canaux de diffusion (un-vers-plusieurs).
 *
 * ## Le partage des rôles avec le moteur
 *
 * Le serveur ne fait que DEUX choses qu'il ne pourrait pas déléguer : garder la
 * clé de lecture scellée (qu'il ne peut pas ouvrir) pour la resservir aux
 * nouveaux venus, et recopier un post à tous les abonnés. Tout le secret vit
 * dans le moteur : la clé de lecture est scellée sous le secret du lien, la clé
 * de signature ne quitte jamais l'admin. Ici, on ne manipule que des octets
 * opaques et une liste d'appareils.
 *
 * ## Le compromis, en clair
 *
 * Le serveur voit qui est abonné — il doit bien savoir à qui recopier. C'est le
 * prix d'un canal ouvert par lien, et il est sans commune mesure avec le secret
 * du contenu, qui tient. Ce n'est PAS l'expéditeur scellé des conversations
 * privées, et ça ne prétend pas l'être.
 */

const b64 = (buf: Uint8Array) => Buffer.from(buf).toString('base64');
const fromB64 = (s: string) => {
  const b = Buffer.from(s, 'base64');
  const out = new Uint8Array(b.length);
  out.set(b);
  return out;
};

// La clé scellée = nonce (24) + distribution chiffrée + tag (16). On borne
// large pour couvrir toute évolution du format de distribution, sans laisser un
// client remplir la base d'un blob arbitraire sous couvert de « clé ».
const sealedKeySchema = z.string().max(4096);

const createSchema = z.object({ sealedKey: sealedKeySchema });
const keySchema = z.object({ sealedKey: sealedKeySchema });
const postSchema = z.object({
  clientMessageId: z.string().uuid(),
  header: z.string(),
  ciphertext: z.string(),
});

export async function channelsRoutes(app: FastifyInstance) {
  /** Crée un canal. L'appelant en devient l'admin (le seul à pouvoir publier). */
  app.post('/channels', { preHandler: requireAuth }, async (request, reply) => {
    const { sealedKey } = createSchema.parse(request.body);
    const me = request.auth!;
    const channel = await prisma.channel.create({
      data: {
        adminUserId: me.userId,
        adminDeviceId: me.deviceId,
        sealedKey: fromB64(sealedKey),
      },
    });
    return reply.code(201).send({ id: channel.id, adminDeviceId: me.deviceId });
  });

  /**
   * Métadonnées d'un canal. Ne réclame PAS d'être abonné : on consulte un canal
   * avant de le rejoindre. Renvoie de quoi afficher et décider, jamais la clé.
   */
  app.get('/channels/:id', { preHandler: requireAuth }, async (request) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    const me = request.auth!;
    const channel = await prisma.channel.findUnique({
      where: { id },
      include: { _count: { select: { subscribers: true } } },
    });
    if (!channel) throw new HttpError(404, 'canal introuvable');

    const abonne = await prisma.channelSubscriber.findUnique({
      where: { channelId_deviceId: { channelId: id, deviceId: me.deviceId } },
      select: { channelId: true },
    });

    return {
      id: channel.id,
      adminDeviceId: channel.adminDeviceId,
      subscriberCount: channel._count.subscribers,
      isAdmin: channel.adminUserId === me.userId,
      isSubscribed: abonne !== null,
      hasKey: channel.sealedKey !== null,
    };
  });

  /**
   * Récupère la clé de lecture scellée. Ouverte à tout compte : il FAUT la
   * récupérer pour rejoindre, donc avant d'être abonné. Sans le secret du lien
   * elle est inexploitable — c'est ce qui rend cette ouverture sûre.
   */
  app.get('/channels/:id/key', { preHandler: requireAuth }, async (request) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    const channel = await prisma.channel.findUnique({
      where: { id },
      select: { sealedKey: true },
    });
    if (!channel) throw new HttpError(404, 'canal introuvable');
    if (!channel.sealedKey) throw new HttpError(404, 'clé du canal indisponible');
    return { sealedKey: b64(channel.sealedKey) };
  });

  /**
   * Dépose (ou fait tourner) la clé de lecture scellée. Réservé à l'admin.
   *
   * La rotation sert au retrait d'un abonné : l'admin crée une nouvelle clé
   * d'expéditeur, la scelle sous un NOUVEAU secret de lien, la dépose ici, et
   * ne rediffuse le nouveau lien qu'à ceux qui restent. L'ancien secret n'ouvre
   * plus rien.
   */
  app.put('/channels/:id/key', { preHandler: requireAuth }, async (request, reply) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    const { sealedKey } = keySchema.parse(request.body);
    const me = request.auth!;
    const channel = await prisma.channel.findUnique({ where: { id }, select: { adminUserId: true } });
    if (!channel) throw new HttpError(404, 'canal introuvable');
    if (channel.adminUserId !== me.userId) throw new HttpError(403, 'réservé à l’admin du canal');

    await prisma.channel.update({ where: { id }, data: { sealedKey: fromB64(sealedKey) } });
    return reply.code(204).send();
  });

  /** Abonne l'appareil courant. Idempotent : rejoindre deux fois ne fait rien. */
  app.post('/channels/:id/subscribers', { preHandler: requireAuth }, async (request, reply) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    const me = request.auth!;
    const channel = await prisma.channel.findUnique({ where: { id }, select: { id: true } });
    if (!channel) throw new HttpError(404, 'canal introuvable');

    await prisma.channelSubscriber.upsert({
      where: { channelId_deviceId: { channelId: id, deviceId: me.deviceId } },
      create: { channelId: id, deviceId: me.deviceId, userId: me.userId },
      update: {},
    });
    return reply.code(204).send();
  });

  /**
   * Désabonne un appareil. Soi-même toujours ; l'admin peut retirer n'importe
   * quel appareil. Retirer quelqu'un n'est que la moitié du travail : l'admin
   * doit ENSUITE faire tourner la clé (PUT …/key), sinon le partant garde de
   * quoi lire la suite. Le serveur ne peut pas l'y forcer — il n'a pas les clés.
   */
  app.delete('/channels/:id/subscribers/:deviceId', { preHandler: requireAuth },
    async (request, reply) => {
      const { id, deviceId } = z
        .object({ id: z.string().uuid(), deviceId: z.string().uuid() })
        .parse(request.params);
      const me = request.auth!;

      if (deviceId !== me.deviceId) {
        // Retrait d'un tiers : réservé à l'admin.
        const channel = await prisma.channel.findUnique({ where: { id }, select: { adminUserId: true } });
        if (!channel) throw new HttpError(404, 'canal introuvable');
        if (channel.adminUserId !== me.userId) throw new HttpError(403, 'réservé à l’admin du canal');
      }

      await prisma.channelSubscriber.deleteMany({ where: { channelId: id, deviceId } });
      return reply.code(204).send();
    });

  /**
   * Publie un message. Réservé à l'admin — mais c'est la CRYPTO qui l'impose,
   * pas cette ligne : un abonné n'a pas la clé de signature, un message qu'il
   * forgerait serait rejeté par les autres. Le contrôle ici évite seulement de
   * stocker un blob voué au rejet.
   *
   * Un seul chiffré, recopié à chaque appareil abonné. Le blob emprunte le tuyau
   * de remise commun : le client le relèvera par GET /messages, reconnaîtra un
   * message de canal à `channelId`, et le déchiffrera avec la clé du canal.
   */
  app.post('/channels/:id/messages', { preHandler: requireAuth, config: messageRateLimit() },
    async (request, reply) => {
      const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
      const body = postSchema.parse(request.body);
      const me = request.auth!;

      const channel = await prisma.channel.findUnique({ where: { id }, select: { adminUserId: true } });
      if (!channel) throw new HttpError(404, 'canal introuvable');
      if (channel.adminUserId !== me.userId) throw new HttpError(403, 'seul l’admin publie');

      // Tous les appareils abonnés, l'appareil publiant exclu : il détient déjà
      // le clair, se recopier le message n'aurait aucun sens.
      const subs = await prisma.channelSubscriber.findMany({
        where: { channelId: id, deviceId: { not: me.deviceId } },
        select: { deviceId: true },
      });
      if (subs.length === 0) return reply.code(201).send({ delivered: 0 });

      const header = fromB64(body.header);
      const ciphertext = fromB64(body.ciphertext);
      const expiresAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);

      // senderDeviceId = l'appareil de l'admin : le client s'en sert comme
      // identifiant d'expéditeur pour déchiffrer avec la clé du canal, tout
      // comme un membre de groupe déchiffre par l'appareil émetteur.
      await prisma.messageBlob.createMany({
        data: subs.map((s) => ({
          channelId: id,
          senderDeviceId: me.deviceId,
          recipientDeviceId: s.deviceId,
          clientMessageId: body.clientMessageId,
          ratchetHeader: header,
          ciphertext,
          expiresAt,
        })),
        // Un renvoi après coupure ne doit ni échouer ni dupliquer.
        skipDuplicates: true,
      });

      for (const s of subs) {
        if (!gateway?.notifyPending(s.deviceId)) void pushService?.wakeDevice(s.deviceId);
      }
      return reply.code(201).send({ delivered: subs.length });
    });

  /** Canaux que l'utilisateur courant administre ou suit (depuis cet appareil). */
  app.get('/channels', { preHandler: requireAuth }, async (request) => {
    const me = request.auth!;
    const [admin, suivis] = await Promise.all([
      prisma.channel.findMany({
        where: { adminUserId: me.userId },
        select: { id: true, createdAt: true },
      }),
      prisma.channelSubscriber.findMany({
        where: { deviceId: me.deviceId },
        select: { channelId: true, channel: { select: { adminDeviceId: true } } },
      }),
    ]);
    return {
      administered: admin.map((c) => c.id),
      subscribed: suivis.map((s) => ({ id: s.channelId, adminDeviceId: s.channel.adminDeviceId })),
    };
  });
}

// P2002 (violation d'unicité) n'est pas attrapé ici : les upsert et
// skipDuplicates l'évitent en amont. Exporté au cas où une route future en
// aurait besoin, sans le réimporter partout.
export const isUniqueViolation = (e: unknown) =>
  e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2002';
