import { env } from './config/env.js';
import { buildApp } from './app.js';
import { prisma } from './db/prisma.js';
import { buildPushProviders } from './modules/push/push.bootstrap.js';
import { initPush } from './modules/push/push.service.js';
import { schedulePurge } from './modules/retention/retention.service.js';
import { initGateway } from './ws/gateway.js';

const app = await buildApp();

app.ready().then(() => {
  initGateway(app.server);
  initPush(buildPushProviders((msg) => app.log.info(msg)));
  schedulePurge((msg) => app.log.info(msg));
});

app.listen({ port: env.PORT, host: env.HOST }).catch(async (err) => {
  app.log.error(err);
  await prisma.$disconnect();
  process.exit(1);
});
