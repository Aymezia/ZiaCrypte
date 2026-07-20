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
  // Absent pour une photo de profil : elle n'appartient à aucune conversation.
  conversationId: z.string().uuid().optional(),
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
    const estAvatar = !body.conversationId;

    if (body.conversationId) {
      await requireMembership(body.conversationId, me.userId);
    }

    const storageKey = estAvatar
      ? `avatars/${me.userId}/${randomUUID()}`
      : `${body.conversationId}/${randomUUID()}`;
    const metadata = Buffer.from(body.encryptedMetadata, 'base64');

    // Une photo de profil remplace la précédente : sans cette suppression, tout
    // changement d'avatar laisserait un objet chiffré de plus chez l'hébergeur,
    // pour toujours et sans plus rien pour le retrouver.
    if (estAvatar) {
      const anciennes = await prisma.attachmentRef.findMany({
        where: { ownerUserId: me.userId },
        select: { id: true, storageKey: true },
      });
      for (const ancienne of anciennes) {
        try {
          await requireStorage().send(
            new DeleteObjectCommand({ Bucket: env.S3_BUCKET, Key: ancienne.storageKey }),
          );
        } catch {
          // L'objet a pu disparaître d'un autre côté : on efface la ligne
          // quand même, sinon elle resterait à pointer dans le vide.
        }
      }
      await prisma.attachmentRef.deleteMany({ where: { ownerUserId: me.userId } });
    }

    const attachment = await prisma.attachmentRef.create({
      data: {
        conversationId: body.conversationId ?? null,
        ownerUserId: estAvatar ? me.userId : null,
        uploaderDeviceId: me.deviceId,
        storageKey,
        encryptedMetadata: new Uint8Array(metadata),
        ciphertextSize: BigInt(body.ciphertextSize),
        // Pas d'expiration pour une photo de profil : elle vaut tant qu'elle
        // n'est pas remplacée.
        expiresAt: estAvatar
          ? null
          : new Date(Date.now() + 30 * 24 * 60 * 60 * 1000),
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

    // Photo de profil : accessible à tout compte authentifié.
    //
    // Ce n'est pas un relâchement. L'objet est chiffré, et sa clé ne voyage que
    // dans les messages de bout en bout : seules les personnes à qui son
    // propriétaire l'a annoncée peuvent en faire quoi que ce soit. Exiger en
    // plus une conversation commune n'ajouterait aucune protection, et
    // obligerait à interroger l'appartenance pour un objet que le serveur ne
    // sait de toute façon pas lire.
    if (attachment.conversationId) {
      await requireMembership(attachment.conversationId, request.auth!.userId);
    }

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
