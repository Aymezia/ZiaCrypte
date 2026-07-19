import { Prisma } from '@prisma/client';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../db/prisma.js';
import { HttpError } from '../../lib/errors.js';
import { requireAuth } from '../../plugins/auth.js';
import { gateway } from '../../ws/gateway.js';

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

export async function messagesRoutes(app: FastifyInstance) {
  // Dépose un blob chiffré à destination d'un appareil. Le serveur ne fait que
  // relayer des octets opaques — il ne peut rien déchiffrer.
  app.post('/messages', { preHandler: requireAuth }, async (request, reply) => {
    const body = sendSchema.parse(request.body);
    const me = request.auth!;

    const participant = await prisma.conversationParticipant.findUnique({
      where: {
        conversationId_userId: { conversationId: body.conversationId, userId: me.userId },
      },
    });
    if (!participant) throw new HttpError(403, 'non membre de la conversation');

    const recipient = await prisma.device.findUnique({ where: { id: body.recipientDeviceId } });
    if (!recipient || !recipient.isActive) {
      throw new HttpError(404, 'appareil destinataire introuvable');
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
      // Réveille le destinataire s'il est connecté ; sinon il relèvera sa
      // boîte à sa prochaine connexion (la remise ne dépend pas du WebSocket).
      gateway?.notifyPending(body.recipientDeviceId);
      return reply.code(201).send({ id: blob.id });
    } catch (e) {
      // Idempotence anti-rejeu : (recipientDeviceId, clientMessageId) est unique.
      if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2002') {
        return reply.code(200).send({ deduplicated: true });
      }
      throw e;
    }
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
      senderUsername: m.sender.user.username,
      clientMessageId: m.clientMessageId,
      header: b64(m.ratchetHeader),
      ciphertext: b64(m.ciphertext),
      timestampMs: m.createdAt.getTime(),
    }));
  });
}
