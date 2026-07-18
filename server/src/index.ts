import { env } from './config/env.js';
import { buildApp } from './app.js';
import { prisma } from './db/prisma.js';

const app = buildApp();

app.listen({ port: env.PORT, host: '0.0.0.0' }).catch(async (err) => {
  app.log.error(err);
  await prisma.$disconnect();
  process.exit(1);
});
