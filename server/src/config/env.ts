import { existsSync } from 'node:fs';
import { z } from 'zod';

// Node 20.12+ : charge .env sans dépendance externe.
if (existsSync('.env')) {
  process.loadEnvFile('.env');
}

const schema = z.object({
  DATABASE_URL: z.string().url(),
  JWT_ACCESS_SECRET: z.string().min(16),
  JWT_REFRESH_SECRET: z.string().min(16),
  PORT: z.coerce.number().default(3000),
  ACCESS_TOKEN_TTL: z.string().default('15m'),
  REFRESH_TOKEN_TTL_DAYS: z.coerce.number().default(30),
});

export const env = schema.parse(process.env);
