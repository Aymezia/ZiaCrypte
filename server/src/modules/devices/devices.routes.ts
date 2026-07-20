import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../db/prisma.js';
import { decodeKey, HttpError, PUBLIC_KEY_LEN, SIGNATURE_LEN } from '../../lib/errors.js';
import { requireAuth } from '../../plugins/auth.js';
import { gateway } from '../../ws/gateway.js';
import {
  assertDeviceOwnedBy,
  createDevice,
  deviceRegistrationSchema,
} from './device.schema.js';

const b64 = (buf: Uint8Array) => Buffer.from(buf).toString('base64');

const prekeyUploadSchema = z.object({
  signedPrekey: z.string().optional(),
  signedPrekeySignature: z.string().optional(),
  oneTimePrekeys: z.array(z.string()).default([]),
});

export async function devicesRoutes(app: FastifyInstance) {
  // Appareils liés au compte courant, avec ce qu'il faut pour reconnaître un
  // intrus : quand il est apparu, et quand il s'est manifesté pour la dernière
  // fois. Sans cette liste, un appareil lié avec un mot de passe volé lit tout
  // indéfiniment sans laisser la moindre trace visible par sa victime.
  app.get('/devices/me', { preHandler: requireAuth }, async (request) => {
    const { userId, deviceId } = request.auth!;
    const devices = await prisma.device.findMany({
      where: { userId },
      orderBy: { createdAt: 'asc' },
    });
    return devices.map((d) => ({
      id: d.id,
      deviceName: d.deviceName,
      platform: d.platform,
      isActive: d.isActive,
      createdAt: d.createdAt.toISOString(),
      lastSeenAt: d.lastSeenAt.toISOString(),
      current: d.id === deviceId,
    }));
  });

  // Révocation d'un appareil.
  //
  // Trois effets, et les trois sont nécessaires :
  //   1. isActive=false      — l'appareil disparaît des bundles X3DH, donc
  //                            plus personne ne chiffrera à son intention ;
  //   2. sessions révoquées  — il ne peut plus rafraîchir ses jetons ;
  //   3. prekeys supprimées  — aucune nouvelle session ne peut être ouverte
  //                            vers lui, même par un correspondant qui aurait
  //                            gardé un ancien bundle en mémoire.
  //
  // L'access token en cours, lui, n'est pas révocable cryptographiquement :
  // c'est `requireAuth` qui le refuse en constatant que l'appareil est inactif.
  app.delete('/devices/:deviceId', { preHandler: requireAuth }, async (request, reply) => {
    const params = z.object({ deviceId: z.string().uuid() }).parse(request.params);
    const { userId } = request.auth!;

    const device = await prisma.device.findUnique({ where: { id: params.deviceId } });
    if (!device || device.userId !== userId) {
      throw new HttpError(404, 'appareil introuvable');
    }
    if (!device.isActive) return reply.code(204).send();

    await prisma.$transaction(async (tx) => {
      await tx.device.update({
        where: { id: device.id },
        data: { isActive: false },
      });
      await tx.authSession.updateMany({
        where: { deviceId: device.id, revokedAt: null },
        data: { revokedAt: new Date() },
      });
      await tx.oneTimePrekey.deleteMany({ where: { deviceId: device.id } });
      await tx.signedPrekey.updateMany({
        where: { deviceId: device.id, isCurrent: true },
        data: { isCurrent: false },
      });
    });

    // Une socket ouverte survivrait à la révocation : elle a été authentifiée
    // une fois pour toutes à la connexion.
    gateway?.deconnecterAppareil(device.id);

    return reply.code(204).send();
  });

  // Liste publique des appareils d'un utilisateur (clés publiques uniquement).
  app.get('/devices/:userId', async (request) => {
    const { userId } = z.object({ userId: z.string().uuid() }).parse(request.params);
    const devices = await prisma.device.findMany({
      where: { userId, isActive: true },
      orderBy: { createdAt: 'asc' },
    });
    return devices.map((d) => ({
      id: d.id,
      platform: d.platform,
      identityPublicKey: b64(d.identityPublicKey),
      isActive: d.isActive,
      // Date de création : sert à la synchronisation multi-appareils. L'appareil
      // le plus ancien fait autorité et rétro-remplit les plus récents, en ne
      // renvoyant que l'historique antérieur à leur création — donc sans
      // chevaucher les messages reçus en direct depuis.
      createdAt: d.createdAt.toISOString(),
    }));
  });

  // Enregistrement d'un appareil supplémentaire pour l'utilisateur courant.
  app.post('/devices', { preHandler: requireAuth }, async (request, reply) => {
    const reg = deviceRegistrationSchema.parse(request.body);
    const device = await prisma.$transaction((tx) =>
      createDevice(tx, request.auth!.userId, reg),
    );
    return reply.code(201).send({ id: device.id });
  });

  // Upload de prekeys : remplace le signed prekey courant et/ou ajoute des OTPK.
  app.post('/devices/:deviceId/prekeys', { preHandler: requireAuth }, async (request, reply) => {
    const { deviceId } = z.object({ deviceId: z.string().uuid() }).parse(request.params);
    const body = prekeyUploadSchema.parse(request.body);
    await assertDeviceOwnedBy(deviceId, request.auth!.userId);

    await prisma.$transaction(async (tx) => {
      if (body.signedPrekey && body.signedPrekeySignature) {
        await tx.signedPrekey.updateMany({
          where: { deviceId, isCurrent: true },
          data: { isCurrent: false },
        });
        await tx.signedPrekey.create({
          data: {
            deviceId,
            publicKey: decodeKey(body.signedPrekey, PUBLIC_KEY_LEN, 'signedPrekey'),
            signature: decodeKey(body.signedPrekeySignature, SIGNATURE_LEN, 'signedPrekeySignature'),
            isCurrent: true,
            expiresAt: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000),
          },
        });
      }
      if (body.oneTimePrekeys.length > 0) {
        await tx.oneTimePrekey.createMany({
          data: body.oneTimePrekeys.map((otpk) => ({
            deviceId,
            publicKey: decodeKey(otpk, PUBLIC_KEY_LEN, 'oneTimePrekey'),
          })),
        });
      }
    });

    return reply.code(204).send();
  });

  // État du pool de prekeys d'un appareil : permet au client de savoir quand
  // le regarnir avant épuisement.
  app.get('/devices/:deviceId/prekeys', { preHandler: requireAuth }, async (request) => {
    const { deviceId } = z.object({ deviceId: z.string().uuid() }).parse(request.params);
    await assertDeviceOwnedBy(deviceId, request.auth!.userId);

    const oneTimePrekeysRemaining = await prisma.oneTimePrekey.count({
      where: { deviceId, consumedAt: null },
    });
    const signed = await prisma.signedPrekey.findFirst({
      where: { deviceId, isCurrent: true },
    });

    return {
      oneTimePrekeysRemaining,
      signedPrekeyExpiresAt: signed?.expiresAt ?? null,
    };
  });

  // Bundles X3DH de TOUS les appareils actifs d'un utilisateur : l'émetteur
  // doit chiffrer séparément pour chacun, sinon les autres appareils du
  // destinataire ne verraient jamais le message.
  app.get('/users/:userId/prekey-bundles', { preHandler: requireAuth }, async (request) => {
    const { userId } = z.object({ userId: z.string().uuid() }).parse(request.params);

    const devices = await prisma.device.findMany({
      where: { userId, isActive: true },
      orderBy: { createdAt: 'asc' },
    });
    if (devices.length === 0) throw new HttpError(404, 'aucun appareil actif');

    const bundles = [];
    for (const device of devices) {
      const signed = await prisma.signedPrekey.findFirst({
        where: { deviceId: device.id, isCurrent: true },
      });
      if (!signed) continue; // appareil sans signed prekey : inutilisable

      const otpk = await prisma.oneTimePrekey.findFirst({
        where: { deviceId: device.id, consumedAt: null },
        orderBy: { createdAt: 'asc' },
      });
      if (otpk) {
        await prisma.oneTimePrekey.update({
          where: { id: otpk.id },
          data: { consumedAt: new Date() },
        });
      }

      bundles.push({
        deviceId: device.id,
        identityKey: b64(device.identityPublicKey),
        signedPrekey: b64(signed.publicKey),
        signedPrekeySignature: b64(signed.signature),
        oneTimePrekey: otpk ? b64(otpk.publicKey) : null,
      });
    }

    if (bundles.length === 0) throw new HttpError(404, 'aucun signed prekey');
    return bundles;
  });

  // Bundle X3DH du premier appareil actif de l'utilisateur. Consomme (une seule
  // fois) une one-time prekey si disponible.
  app.get('/users/:userId/prekey-bundle', { preHandler: requireAuth }, async (request) => {
    const { userId } = z.object({ userId: z.string().uuid() }).parse(request.params);

    const device = await prisma.device.findFirst({
      where: { userId, isActive: true },
      orderBy: { createdAt: 'asc' },
    });
    if (!device) throw new HttpError(404, 'aucun appareil actif');

    const signed = await prisma.signedPrekey.findFirst({
      where: { deviceId: device.id, isCurrent: true },
    });
    if (!signed) throw new HttpError(404, 'aucun signed prekey');

    // Consomme une one-time prekey disponible (best-effort atomique).
    const otpk = await prisma.oneTimePrekey.findFirst({
      where: { deviceId: device.id, consumedAt: null },
      orderBy: { createdAt: 'asc' },
    });
    if (otpk) {
      await prisma.oneTimePrekey.update({
        where: { id: otpk.id },
        data: { consumedAt: new Date() },
      });
    }

    return {
      deviceId: device.id,
      identityKey: b64(device.identityPublicKey),
      signedPrekey: b64(signed.publicKey),
      signedPrekeySignature: b64(signed.signature),
      oneTimePrekey: otpk ? b64(otpk.publicKey) : null,
    };
  });
}
