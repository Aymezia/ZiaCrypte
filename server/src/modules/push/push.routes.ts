import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../db/prisma.js';
import { requireAuth } from '../../plugins/auth.js';
import { pushService } from './push.service.js';

const registerSchema = z.object({
  platform: z.enum(['fcm', 'apns']),
  // Les jetons FCM font ~160 caractères, ceux d'APNs 64 hexadécimaux. La borne
  // haute évite qu'un client bavard remplisse la table.
  token: z.string().min(16).max(4096),
});

export async function pushRoutes(app: FastifyInstance) {
  /**
   * Déclare le jeton push de l'appareil **courant**.
   *
   * L'appareil est lu dans le jeton d'accès, jamais dans le corps de la
   * requête : un compte compromis ne peut donc pas rediriger les réveils d'un
   * autre appareil vers un jeton qu'il contrôle.
   */
  app.put('/push/token', { preHandler: requireAuth }, async (request, reply) => {
    const body = registerSchema.parse(request.body);
    const deviceId = request.auth!.deviceId;

    await prisma.pushToken.upsert({
      where: { deviceId_platform: { deviceId, platform: body.platform } },
      create: { deviceId, platform: body.platform, token: body.token },
      update: { token: body.token, updatedAt: new Date() },
    });

    // Le client a besoin de savoir si le push est réellement opérant : sans
    // fournisseur configuré côté serveur, il doit garder sa connexion ouverte
    // plutôt que de compter sur un réveil qui ne viendra pas.
    return reply.code(200).send({
      active: pushService?.supports(body.platform) ?? false,
    });
  });

  /**
   * Retire le jeton de l'appareil courant (déconnexion, refus des
   * notifications). Idempotent : supprimer un jeton absent n'est pas une
   * erreur.
   */
  app.delete('/push/token', { preHandler: requireAuth }, async (request, reply) => {
    const { platform } = z
      .object({ platform: z.enum(['fcm', 'apns']) })
      .parse(request.query);

    await prisma.pushToken
      .delete({
        where: {
          deviceId_platform: { deviceId: request.auth!.deviceId, platform },
        },
      })
      .catch(() => undefined);

    return reply.code(204).send();
  });
}
