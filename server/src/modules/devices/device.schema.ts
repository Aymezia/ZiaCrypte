import { Prisma } from '@prisma/client';
import { z } from 'zod';
import { prisma } from '../../db/prisma.js';
import { decodeKey, HttpError, PUBLIC_KEY_LEN, SIGNATURE_LEN } from '../../lib/errors.js';

export const deviceRegistrationSchema = z.object({
  deviceName: z.string().min(1).max(120).default('appareil'),
  platform: z.enum(['android', 'ios', 'windows', 'macos', 'linux']),
  identityPublicKey: z.string(),
  signedPrekey: z.string(),
  signedPrekeySignature: z.string(),
  oneTimePrekeys: z.array(z.string()).default([]),
});

export type DeviceRegistration = z.infer<typeof deviceRegistrationSchema>;

/**
 * Crée un appareil, son signed prekey courant et son pool de one-time prekeys,
 * dans la transaction fournie. Ne stocke QUE des clés publiques.
 */
export async function createDevice(
  tx: Prisma.TransactionClient,
  userId: string,
  reg: DeviceRegistration,
) {
  const identityKey = decodeKey(reg.identityPublicKey, PUBLIC_KEY_LEN, 'identityPublicKey');
  const spk = decodeKey(reg.signedPrekey, PUBLIC_KEY_LEN, 'signedPrekey');
  const spkSig = decodeKey(reg.signedPrekeySignature, SIGNATURE_LEN, 'signedPrekeySignature');

  // Une clé d'identité est propre à UN appareil. Deux appareils qui la
  // partagent — cas rencontré quand un client réutilise le même stockage moteur
  // pour deux comptes — permettent au serveur de prouver qu'ils appartiennent à
  // la même personne, et rendent le handshake X3DH entre eux dégénéré (un DH
  // d'une clé avec elle-même). Le serveur ne peut pas empêcher un client de mal
  // faire, mais il peut refuser d'enregistrer le résultat.
  const clash = await tx.device.findFirst({
    where: { identityPublicKey: identityKey },
    select: { id: true },
  });
  if (clash) {
    throw new HttpError(
      409,
      'cette clé d’identité est déjà utilisée par un autre appareil',
    );
  }

  const device = await tx.device.create({
    data: {
      userId,
      deviceName: reg.deviceName,
      platform: reg.platform,
      identityPublicKey: identityKey,
    },
  });

  await tx.signedPrekey.create({
    data: {
      deviceId: device.id,
      publicKey: spk,
      signature: spkSig,
      isCurrent: true,
      // rotation périodique (cf. conception moteur) : 7 jours par défaut.
      expiresAt: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000),
    },
  });

  if (reg.oneTimePrekeys.length > 0) {
    await tx.oneTimePrekey.createMany({
      data: reg.oneTimePrekeys.map((otpk) => ({
        deviceId: device.id,
        publicKey: decodeKey(otpk, PUBLIC_KEY_LEN, 'oneTimePrekey'),
      })),
    });
  }

  return device;
}

/** Garde-fou : l'appareil existe, est actif et appartient à l'utilisateur. */
export async function assertDeviceOwnedBy(deviceId: string, userId: string) {
  const device = await prisma.device.findUnique({ where: { id: deviceId } });
  if (!device || device.userId !== userId || !device.isActive) {
    throw new HttpError(404, 'appareil introuvable');
  }
  return device;
}
