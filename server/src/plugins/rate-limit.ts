import rateLimit from '@fastify/rate-limit';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { env } from '../config/env.js';

/**
 * Limitation de débit.
 *
 * ## Ce qu'on protège
 *
 * Les routes d'authentification vérifient le mot de passe avec Argon2id,
 * délibérément coûteux. C'est une bonne chose contre le cassage hors ligne,
 * mais ça retourne l'arme contre le serveur : chaque tentative consomme du CPU
 * et de la mémoire. Sans limite, quelques centaines de requêtes par seconde
 * suffisent à rendre le service indisponible pour tout le monde — sans même
 * chercher à deviner un mot de passe.
 *
 * La limite sert donc deux buts à la fois : freiner le cassage en ligne, et
 * empêcher qu'on épuise la machine à travers Argon2.
 *
 * ## Le piège de l'adresse IP
 *
 * Le serveur n'écoute que sur la boucle locale ; nginx termine le TLS et relaie.
 * Sans `trustProxy`, toutes les requêtes semblent venir de 127.0.0.1 : une
 * limite posée là-dessus traiterait l'ensemble des utilisateurs comme un seul,
 * et le premier à l'atteindre bloquerait tous les autres. Un déni de service
 * qu'on s'infligerait soi-même.
 *
 * `trustProxy: true` serait pire : la chaîne X-Forwarded-For serait crue en
 * entier, donc un client pourrait s'inventer une adresse à chaque requête et
 * contourner la limite sans effort.
 *
 * On ne fait donc confiance qu'au saut immédiat — la boucle locale, c'est-à-dire
 * nginx. `request.ip` devient alors la dernière adresse que NOUS avons posée,
 * celle du vrai client, et rien de ce qu'il envoie ne peut la changer.
 */

/** Adresses de confiance : uniquement le proxy local. */
export const TRUSTED_PROXIES = ['127.0.0.1', '::1'];

export async function registerRateLimit(app: FastifyInstance) {
  await app.register(rateLimit, {
    // Plafond large, appliqué à tout : il n'existe que pour borner l'abus
    // grossier. Les routes sensibles ont le leur, bien plus strict.
    global: true,
    max: env.RATE_LIMIT_GLOBAL_MAX,
    timeWindow: '1 minute',
    // Le corps construit ici est levé tel quel par le plugin : il DOIT porter
    // son propre statusCode, sinon le gestionnaire d'erreurs global n'y voit
    // qu'une erreur sans statut et répond 500 — la protection fonctionnerait
    // en ressemblant à un plantage.
    // Message sans détail : inutile d'indiquer à un attaquant où il en est.
    errorResponseBuilder: () => ({
      statusCode: 429,
      error: 'Too Many Requests',
      message: 'trop de requêtes, réessaie dans un instant',
    }),
  });
}

/**
 * Limite pour une route qui vérifie un mot de passe (connexion, ajout
 * d'appareil).
 *
 * La clé combine l'adresse ET le pseudo visé. Le pseudo compte : sans lui, un
 * attaquant disposant de plusieurs adresses répartirait ses essais sur un même
 * compte sans jamais atteindre la limite.
 */
export function passwordRateLimit() {
  return {
    rateLimit: {
      // Après analyse du corps : à `onRequest` (le défaut), `request.body` est
      // encore vide et le pseudo n'entrerait jamais dans la clé — la limite
      // retomberait sur la seule adresse, sans que rien ne le signale.
      hook: 'preValidation' as const,
      max: env.RATE_LIMIT_PASSWORD_MAX,
      timeWindow: env.RATE_LIMIT_PASSWORD_WINDOW,
      keyGenerator: (request: FastifyRequest) => {
        const body = request.body as { username?: unknown } | undefined;
        const username =
          typeof body?.username === 'string' ? body.username.toLowerCase() : '';
        return `pwd:${request.ip}:${username}`;
      },
      errorResponseBuilder: () => ({
        statusCode: 429,
        error: 'Too Many Requests',
        message: 'trop de tentatives, réessaie dans quelques minutes',
      }),
    },
  };
}

/**
 * Limite de création de comptes, indexée sur la seule adresse.
 *
 * Ici le pseudo NE DOIT PAS entrer dans la clé : chaque inscription en utilise
 * un différent par nature, la limite ne se déclencherait donc jamais. La menace
 * est la création de comptes en masse depuis une source, et c'est la source
 * qu'il faut compter.
 */
export function registrationRateLimit() {
  return {
    rateLimit: {
      max: env.RATE_LIMIT_REGISTER_MAX,
      timeWindow: env.RATE_LIMIT_REGISTER_WINDOW,
      keyGenerator: (request: FastifyRequest) => `reg:${request.ip}`,
      errorResponseBuilder: () => ({
        statusCode: 429,
        error: 'Too Many Requests',
        message: 'trop de comptes créés depuis cette adresse, réessaie plus tard',
      }),
    },
  };
}

/**
 * Limite d'envoi de messages, indexée sur l'appareil expéditeur.
 *
 * On compte par appareil authentifié, pas par adresse : un compte qui inonde le
 * fait quel que soit son réseau, et beaucoup d'utilisateurs légitimes partagent
 * une même adresse (NAT, université, opérateur mobile) — les compter ensemble
 * punirait les innocents. Repli sur l'adresse si l'authentification n'a pas
 * encore renseigné `request.auth`, pour ne jamais laisser la route sans borne.
 *
 * Ne lit AUCUN contenu : seul le rythme d'envoi entre dans la décision.
 */
export function messageRateLimit() {
  return {
    rateLimit: {
      hook: 'preHandler' as const,
      max: env.RATE_LIMIT_MESSAGE_MAX,
      timeWindow: env.RATE_LIMIT_MESSAGE_WINDOW,
      keyGenerator: (request: FastifyRequest) =>
        `msg:${request.auth?.deviceId ?? request.ip}`,
      errorResponseBuilder: () => ({
        statusCode: 429,
        error: 'Too Many Requests',
        message: 'trop de messages envoyés coup sur coup, réessaie dans un instant',
      }),
    },
  };
}

/**
 * Limite de dépôt de signalements, indexée sur le compte signaleur.
 *
 * Empêche que l'outil de modération devienne lui-même un moyen de harcèlement :
 * sans borne, un compte pourrait noyer un autre sous les dénonciations.
 */
export function reportRateLimit() {
  return {
    rateLimit: {
      hook: 'preHandler' as const,
      max: env.RATE_LIMIT_REPORT_MAX,
      timeWindow: env.RATE_LIMIT_REPORT_WINDOW,
      keyGenerator: (request: FastifyRequest) =>
        `report:${request.auth?.userId ?? request.ip}`,
      errorResponseBuilder: () => ({
        statusCode: 429,
        error: 'Too Many Requests',
        message: 'trop de signalements envoyés, réessaie plus tard',
      }),
    },
  };
}
