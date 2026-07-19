import { env } from './config/env.js';
import { buildApp } from './app.js';
import { prisma } from './db/prisma.js';
import { initGateway } from './ws/gateway.js';

const app = buildApp();

app.ready().then(() => initGateway(app.server));

app.listen({ port: env.PORT, host: env.HOST }).catch(async (err) => {
  app.log.error(err);
  await prisma.$disconnect();
  process.exit(1);
});
