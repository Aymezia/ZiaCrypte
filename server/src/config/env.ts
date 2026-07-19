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
  PORT: z.coerce.number().default(3210),
  // N'écoute que sur la boucle locale : l'exposition publique passe par nginx
  // (terminaison TLS). Mettre HOST=0.0.0.0 pour un déploiement conteneurisé.
  HOST: z.string().default('127.0.0.1'),
  ACCESS_TOKEN_TTL: z.string().default('15m'),
  REFRESH_TOKEN_TTL_DAYS: z.coerce.number().default(30),

  // Stockage objet des pièces jointes (API S3 : MinIO auto-hébergé ici, mais
  // Cloudflare R2 ou Backblaze B2 conviennent en changeant l'endpoint).
  S3_ENDPOINT: z.string().url(),
  S3_REGION: z.string().default('us-east-1'),
  S3_BUCKET: z.string().default('ziacrypte-attachments'),
  S3_ACCESS_KEY: z.string().min(3),
  S3_SECRET_KEY: z.string().min(8),

  // Notifications push. Optionnel : sans compte de service Firebase, le serveur
  // démarre avec un fournisseur inerte et le signale au démarrage. La remise
  // des messages n'en dépend pas — seule la latence hors ligne se dégrade.
  FCM_SERVICE_ACCOUNT_FILE: z.string().optional(),

  // Limitation de débit. Réglable pour que les tests puissent éprouver le
  // mécanisme sans que les autres suites se bloquent elles-mêmes.
  RATE_LIMIT_GLOBAL_MAX: z.coerce.number().default(300),
  RATE_LIMIT_PASSWORD_MAX: z.coerce.number().default(10),
  RATE_LIMIT_PASSWORD_WINDOW: z.string().default('5 minutes'),
  RATE_LIMIT_REGISTER_MAX: z.coerce.number().default(5),
  RATE_LIMIT_REGISTER_WINDOW: z.string().default('1 hour'),

  // Rétention. Un blob déjà relevé est inatteignable par son destinataire :
  // le conserver ne sert plus la remise, seulement à accumuler du chiffré et
  // des métadonnées. Le délai laisse la place à une reprise côté client.
  RETENTION_DELIVERED_HOURS: z.coerce.number().default(24),
  RETENTION_INTERVAL_HOURS: z.coerce.number().default(6),
});

export const env = schema.parse(process.env);
