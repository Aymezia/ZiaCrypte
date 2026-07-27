import { createHmac } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { env } from '../../config/env.js';
import { HttpError } from '../../lib/errors.js';
import { requireAuth } from '../../plugins/auth.js';

/**
 * Identifiants TURN à durée de vie courte, pour les appels chiffrés.
 *
 * ## Ce que le serveur fait ici — et ce qu'il ne peut pas faire
 *
 * Un appel WebRTC chiffre la voix DE BOUT EN BOUT (DTLS-SRTP), entre les deux
 * appareils. Le serveur TURN ne fait que relayer ces octets déjà chiffrés quand
 * une connexion directe est impossible : il ne peut pas les écouter. Ce module
 * ne délivre que le droit d'utiliser ce relais, sous une forme qui ne met aucun
 * secret durable dans l'application.
 *
 * ## Pourquoi des identifiants HMAC horodatés plutôt qu'un mot de passe
 *
 * On suit le « TURN REST API » de coturn (use-auth-secret) : le nom
 * d'utilisateur porte une échéance, et le mot de passe est un HMAC de ce nom
 * sous un secret partagé avec coturn. coturn recalcule le HMAC et refuse tout
 * nom expiré. Conséquences : le secret ne quitte jamais le serveur, un
 * identifiant intercepté cesse de valoir en une heure, et il n'y a aucun compte
 * TURN à gérer.
 */
export async function turnRoutes(app: FastifyInstance) {
  app.get('/turn-credentials', { preHandler: requireAuth }, async (request) => {
    if (!env.TURN_URLS || !env.TURN_SHARED_SECRET) {
      // Appels non configurés sur ce déploiement. 503 plutôt que 404 : la route
      // existe, c'est la dépendance (le TURN) qui manque — le client distingue
      // « fonctionnalité absente » de « appelez plus tard ».
      throw new HttpError(503, 'appels indisponibles : relais TURN non configuré');
    }

    const ttl = env.TURN_CREDENTIAL_TTL;
    const expiry = Math.floor(Date.now() / 1000) + ttl;
    // username = échéance:compte. L'échéance est ce que coturn vérifie ; le
    // compte ne lui sert pas, mais il lie l'identifiant à un utilisateur (utile
    // au diagnostic côté relais) et empêche de rejouer celui d'un autre.
    const username = `${expiry}:${request.auth!.userId}`;
    const credential = createHmac('sha1', env.TURN_SHARED_SECRET)
      .update(username)
      .digest('base64');

    const urls = env.TURN_URLS.split(',')
      .map((u) => u.trim())
      .filter(Boolean);

    // Format directement consommable par RTCPeerConnection côté client.
    return {
      ttl,
      iceServers: [{ urls, username, credential }],
    };
  });
}
