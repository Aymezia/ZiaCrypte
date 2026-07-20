import { S3Client } from '@aws-sdk/client-s3';
import { env } from '../config/env.js';
import { HttpError } from './errors.js';

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
/** Le stockage objet est-il configuré ? */
export const storageConfigured =
  Boolean(env.S3_ENDPOINT && env.S3_ACCESS_KEY && env.S3_SECRET_KEY);

/**
 * Client S3, ou `null` si le stockage n'est pas configuré.
 *
 * Construire un client avec des identifiants absents produirait des échecs
 * obscurs au premier appel ; un `null` explicite oblige les appelants à traiter
 * le cas, et permet de répondre clairement « fonction indisponible ».
 */
export const s3: S3Client | null = storageConfigured
  ? new S3Client({
      endpoint: env.S3_ENDPOINT!,
      region: env.S3_REGION,
      // Indispensable derrière un reverse proxy (MinIO local) : sans cela le
      // SDK viserait <bucket>.<hôte>, qui ne résout pas.
      //
      // Réglable, parce que tous les hébergeurs ne s'accommodent pas du même
      // style d'URL. Cloudflare R2 accepte les deux ; d'autres n'acceptent que
      // le style virtuel, et une valeur figée aurait rendu la bascule
      // impossible sans toucher au code.
      forcePathStyle: env.S3_FORCE_PATH_STYLE,
      credentials: {
        accessKeyId: env.S3_ACCESS_KEY!,
        secretAccessKey: env.S3_SECRET_KEY!,
      },
    })
  : null;

/** Client S3 garanti, ou une erreur lisible pour le client HTTP. */
export function requireStorage(): S3Client {
  if (!s3) {
    throw new HttpError(
      503,
      'stockage des pièces jointes non configuré sur ce serveur',
    );
  }
  return s3;
}
