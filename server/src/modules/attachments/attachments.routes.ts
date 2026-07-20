import { randomUUID } from 'node:crypto';
import {
  DeleteObjectCommand,
  GetObjectCommand,
  PutObjectCommand,
} from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { requireMembership } from '../conversations/membership.js';
import { requireStorage } from '../../lib/storage.js';
import { env } from '../../config/env.js';
import { prisma } from '../../db/prisma.js';
import { HttpError } from '../../lib/errors.js';
import { requireAuth } from '../../plugins/auth.js';

/**
 * Pièces jointes.
 *
 * Le serveur ne manipule que des URL pré-signées : le contenu part directement
 * du client vers le stockage objet, **déjà chiffré** sous une clé que seul le
 * destinataire recevra (dans le message chiffré de bout en bout). Ni ce serveur
 * ni l'hébergeur du stockage ne peuvent lire quoi que ce soit.
 */


const UPLOAD_TTL_SECONDS = 15 * 60;
const DOWNLOAD_TTL_SECONDS = 60 * 60;
const MAX_SIZE = 64 * 1024 * 1024;

const createSchema = z.object({
  conversationId: z.string().uuid(),
  ciphertextSize: z.number().int().positive().max(MAX_SIZE),
  // Nom de fichier et type MIME sont chiffrés par le client : le serveur ne
  // stocke qu'un blob opaque de métadonnées.
  encryptedMetadata: z.string(),
});

export async function attachmentsRoutes(app: FastifyInstance) {
  // Réserve une pièce jointe et renvoie l'URL de dépôt.
  app.post('/attachments', { preHandler: requireAuth }, async (request, reply) => {
    const body = createSchema.parse(request.body);
    const me = request.auth!;

    await requireMembership(body.conversationId, me.userId);

    const storageKey = `${body.conversationId}/${randomUUID()}`;
    const metadata = Buffer.from(body.encryptedMetadata, 'base64');

    const attachment = await prisma.attachmentRef.create({
      data: {
        conversationId: body.conversationId,
        uploaderDeviceId: me.deviceId,
        storageKey,
        encryptedMetadata: new Uint8Array(metadata),
        ciphertextSize: BigInt(body.ciphertextSize),
        expiresAt: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000),
      },
    });

    const uploadUrl = await getSignedUrl(
      requireStorage(),
      new PutObjectCommand({ Bucket: env.S3_BUCKET, Key: storageKey }),
      { expiresIn: UPLOAD_TTL_SECONDS },
    );

    return reply.code(201).send({
      attachmentId: attachment.id,
      uploadUrl,
      expiresAt: new Date(Date.now() + UPLOAD_TTL_SECONDS * 1000).toISOString(),
    });
  });

  // URL de téléchargement, réservée aux membres de la conversation.
  app.get('/attachments/:id', { preHandler: requireAuth }, async (request) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);

    const attachment = await prisma.attachmentRef.findUnique({ where: { id } });
    if (!attachment) throw new HttpError(404, 'pièce jointe introuvable');

    await requireMembership(attachment.conversationId, request.auth!.userId);

    const downloadUrl = await getSignedUrl(
      requireStorage(),
      new GetObjectCommand({ Bucket: env.S3_BUCKET, Key: attachment.storageKey }),
      { expiresIn: DOWNLOAD_TTL_SECONDS },
    );

    return {
      attachmentId: attachment.id,
      downloadUrl,
      ciphertextSize: Number(attachment.ciphertextSize),
      encryptedMetadata: Buffer.from(attachment.encryptedMetadata).toString('base64'),
    };
  });

  // Suppression par l'appareil qui a déposé la pièce jointe.
  app.delete('/attachments/:id', { preHandler: requireAuth }, async (request, reply) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);

    const attachment = await prisma.attachmentRef.findUnique({ where: { id } });
    if (!attachment) throw new HttpError(404, 'pièce jointe introuvable');
    if (attachment.uploaderDeviceId !== request.auth!.deviceId) {
      throw new HttpError(403, 'seul l’émetteur peut supprimer cette pièce jointe');
    }

    await requireStorage().send(
      new DeleteObjectCommand({ Bucket: env.S3_BUCKET, Key: attachment.storageKey }),
    );
    await prisma.attachmentRef.delete({ where: { id } });
    return reply.code(204).send();
  });
}
