import Fastify, { type FastifyInstance } from 'fastify';
import { ZodError } from 'zod';
import { HttpError } from './lib/errors.js';
import { registerRateLimit, TRUSTED_PROXIES } from './plugins/rate-limit.js';
import { adminRoutes, passwordResetRoutes } from './modules/admin/admin.routes.js';
import { sealedRoutes } from './modules/messages/sealed.routes.js';
import { blocksRoutes } from './modules/blocks/blocks.routes.js';
import { reportsRoutes } from './modules/reports/reports.routes.js';
import { attachmentsRoutes } from './modules/attachments/attachments.routes.js';
import { authRoutes } from './modules/auth/auth.routes.js';
import { channelsRoutes } from './modules/channels/channels.routes.js';
import { turnRoutes } from './modules/calls/turn.routes.js';
import { conversationsRoutes } from './modules/conversations/conversations.routes.js';
import { devicesRoutes } from './modules/devices/devices.routes.js';
import { messagesRoutes } from './modules/messages/messages.routes.js';
import { pushRoutes } from './modules/push/push.routes.js';
import { usersRoutes } from './modules/users/users.routes.js';

export async function buildApp(): Promise<FastifyInstance> {
  const app = Fastify({
    logger: { level: process.env.LOG_LEVEL ?? 'info' },
    // Ne croire que le proxy local, jamais la chaîne X-Forwarded-For entière :
    // sinon un client se forge l'adresse de son choix. Voir plugins/rate-limit.
    trustProxy: TRUSTED_PROXIES,
  });

  await registerRateLimit(app);

  app.setErrorHandler((error, _request, reply) => {
    if (error instanceof ZodError) {
      return reply.code(400).send({ error: 'requête invalide', details: error.issues });
    }
    if (error instanceof HttpError) {
      return reply.code(error.statusCode).send({ error: error.message });
    }
    // Erreurs portant déjà un statut client (limitation de débit, charge utile
    // trop grande, JSON malformé…). Sans ce cas, elles étaient transformées en
    // 500 : atteindre la limite de débit ressemblait à un plantage du serveur,
    // et remplissait le journal d'erreurs internes qui n'en sont pas.
    const { statusCode, message } = error as {
      statusCode?: number;
      message?: string;
    };
    if (typeof statusCode === 'number' && statusCode >= 400 && statusCode < 500) {
      return reply.code(statusCode).send({ error: message ?? 'requête refusée' });
    }
    app.log.error(error);
    return reply.code(500).send({ error: 'erreur interne' });
  });

  app.get('/health', async () => ({ status: 'ok' }));

  app.register(
    async (v1) => {
      await authRoutes(v1);
      await devicesRoutes(v1);
      await conversationsRoutes(v1);
      await channelsRoutes(v1);
      await turnRoutes(v1);
      await messagesRoutes(v1);
      await usersRoutes(v1);
      await attachmentsRoutes(v1);
      await pushRoutes(v1);
      await sealedRoutes(v1);
      await blocksRoutes(v1);
      await reportsRoutes(v1);
      await adminRoutes(v1);
      await passwordResetRoutes(v1);
    },
    { prefix: '/v1' },
  );

  return app;
}
