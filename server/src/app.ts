import Fastify, { type FastifyInstance } from 'fastify';
import { ZodError } from 'zod';
import { HttpError } from './lib/errors.js';
import { authRoutes } from './modules/auth/auth.routes.js';
import { conversationsRoutes } from './modules/conversations/conversations.routes.js';
import { devicesRoutes } from './modules/devices/devices.routes.js';
import { messagesRoutes } from './modules/messages/messages.routes.js';
import { usersRoutes } from './modules/users/users.routes.js';

export function buildApp(): FastifyInstance {
  const app = Fastify({ logger: { level: process.env.LOG_LEVEL ?? 'info' } });

  app.setErrorHandler((error, _request, reply) => {
    if (error instanceof ZodError) {
      return reply.code(400).send({ error: 'requête invalide', details: error.issues });
    }
    if (error instanceof HttpError) {
      return reply.code(error.statusCode).send({ error: error.message });
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
      await messagesRoutes(v1);
      await usersRoutes(v1);
    },
    { prefix: '/v1' },
  );

  return app;
}
