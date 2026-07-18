import type { FastifyReply, FastifyRequest } from 'fastify';
import { verifyAccess } from '../lib/tokens.js';

declare module 'fastify' {
  interface FastifyRequest {
    auth?: { userId: string; deviceId: string };
  }
}

/**
 * preHandler d'authentification : exige un access token Bearer valide et
 * renseigne `request.auth`. À attacher aux routes protégées.
 */
export async function requireAuth(request: FastifyRequest, reply: FastifyReply) {
  const header = request.headers.authorization;
  if (!header?.startsWith('Bearer ')) {
    return reply.code(401).send({ error: 'jeton d’accès manquant' });
  }
  try {
    const claims = verifyAccess(header.slice('Bearer '.length));
    request.auth = { userId: claims.sub, deviceId: claims.did };
  } catch {
    return reply.code(401).send({ error: 'jeton d’accès invalide ou expiré' });
  }
}
