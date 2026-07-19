import { S3Client } from '@aws-sdk/client-s3';
import { env } from '../config/env.js';

/**
 * Client du stockage objet, partagé.
 *
 * Extrait du module des pièces jointes parce que la purge en a besoin elle
 * aussi : sans accès au stockage, supprimer la ligne en base laisserait
 * l'objet chiffré sur l'hébergeur pour toujours, sans plus rien pour le
 * retrouver ni le supprimer.
 *
 * Ne manipule que du chiffré : les clés de déchiffrement ne transitent que dans
 * les messages de bout en bout et n'atteignent jamais ce serveur.
 */
export const s3 = new S3Client({
  endpoint: env.S3_ENDPOINT,
  region: env.S3_REGION,
  // Indispensable derrière un reverse proxy : sans cela le SDK viserait
  // <bucket>.<hôte>, qui ne résout pas ici.
  forcePathStyle: true,
  credentials: {
    accessKeyId: env.S3_ACCESS_KEY,
    secretAccessKey: env.S3_SECRET_KEY,
  },
});
