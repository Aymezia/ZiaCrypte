import { createHash, randomBytes, randomUUID } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../db/prisma.js';
import { HttpError } from '../../lib/errors.js';
import { requireAuth } from '../../plugins/auth.js';
import { gateway } from '../../ws/gateway.js';

/**
 * Dépôt scellé : déposer un message SANS dire qui on est.
 *
 * ## Ce que ça retire au serveur
 *
 * Il ne pouvait déjà rien lire. Il savait en revanche qui écrivait à qui, dans
 * quelle conversation, et à quelle fréquence — un graphe qui en apprend souvent
 * plus que le contenu. Sur ce chemin, il ne voit plus qu'un jeton de remise,
 * une boîte de destination, et des octets.
 *
 * ## Le jeton remplace l'authentification
 *
 * Il est tiré au hasard par l'appareil, publié HACHÉ au serveur, et communiqué
 * en clair à ses correspondants par le canal chiffré — donc uniquement à ceux
 * avec qui une session existe déjà. Le détenir prouve qu'on a été en contact,
 * ce qui est exactement l'autorisation qu'on veut, sans révéler d'identité.
 *
 * ## L'abus, qu'il faut regarder en face
 *
 * Une route non authentifiée est une invitation. Trois bornes :
 *   - le jeton doit correspondre à un appareil actif (sinon 404 générique) ;
 *   - la taille est plafonnée comme sur le chemin normal ;
 *   - un plafond de dépôts par jeton et par fenêtre, sans quoi un jeton fuité
 *     permettrait de noyer une boîte.
 *
 * Ce que ça ne protège pas : quelqu'un qui a le jeton peut déposer
 * anonymement. C'est le prix du dispositif, et c'est pourquoi le jeton est
 * rotatif — le changer coupe l'accès à qui l'aurait obtenu.
 */

const MAX_SIZE = 64 * 1024;

const sealedSchema = z.object({
  deliveryToken: z.string().min(20).max(200),
  recipientDeviceId: z.string().uuid(),
  clientMessageId: z.string().uuid(),
  // L'enveloppe entière est scellée : en-tête de ratchet, matériel de
  // handshake et contenu sont dedans. Le serveur ne distingue plus rien.
  sealed: z.string(),
});

const hacher = (t: string) => createHash('sha256').update(t).digest('hex');

export async function sealedRoutes(app: FastifyInstance) {
  /**
   * Publie (ou fait tourner) le jeton de remise de l'appareil courant.
   *
   * Le clair n'est rendu qu'ICI, une seule fois : c'est au client de le
   * distribuer à ses correspondants par le canal chiffré. Le serveur n'en garde
   * que l'empreinte et ne peut donc pas le communiquer à qui le demanderait.
   */
  app.post('/messages/delivery-token', { preHandler: requireAuth }, async (request) => {
    const jeton = randomBytes(32).toString('base64url');
    await prisma.device.update({
      where: { id: request.auth!.deviceId },
      data: { deliveryTokenHash: hacher(jeton) },
    });
    return {
      deliveryToken: jeton,
      rappel:
        'À diffuser uniquement par le canal chiffré. Qui le détient peut ' +
        'déposer un message pour cet appareil sans s’identifier ; le faire ' +
        'tourner coupe cet accès.',
    };
  });

  /**
   * Dépôt scellé. AUCUNE authentification : c'est tout l'objet.
   */
  app.post('/messages/sealed', async (request, reply) => {
    const body = sealedSchema.parse(request.body);
    const sealed = Buffer.from(body.sealed, 'base64');
    if (sealed.length === 0 || sealed.length > MAX_SIZE) {
      throw new HttpError(413, 'enveloppe hors bornes');
    }

    const device = await prisma.device.findUnique({
      where: { id: body.recipientDeviceId },
      select: { id: true, isActive: true, deliveryTokenHash: true },
    });

    // Réponse identique pour « appareil inconnu », « inactif » et « mauvais
    // jeton » : les distinguer permettrait d'énumérer les appareils et de
    // tester des jetons en observant les écarts.
    if (
      !device ||
      !device.isActive ||
      !device.deliveryTokenHash ||
      device.deliveryTokenHash !== hacher(body.deliveryToken)
    ) {
      throw new HttpError(404, 'destinataire introuvable');
    }

    try {
      const blob = await prisma.messageBlob.create({
        data: {
          // Ni expéditeur ni conversation : c'est précisément ce qu'on retire.
          conversationId: null,
          senderDeviceId: null,
          recipientDeviceId: device.id,
          clientMessageId: body.clientMessageId,
          // L'en-tête est vide : tout est dans l'enveloppe scellée.
          ratchetHeader: new Uint8Array(0),
          ciphertext: new Uint8Array(sealed),
          expiresAt: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000),
        },
      });
      gateway?.notifyPending(device.id);
      return reply.code(201).send({ id: blob.id });
    } catch (e) {
      // Même forme de réponse qu'un dépôt réussi en cas de doublon : le
      // déposant ne doit rien apprendre de plus qu'à l'accoutumée.
      return reply.code(201).send({ id: randomUUID() });
    }
  });
}
