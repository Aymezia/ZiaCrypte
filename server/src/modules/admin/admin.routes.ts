import { randomBytes, createHash } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import argon2 from 'argon2';
import { z } from 'zod';
import { prisma } from '../../db/prisma.js';
import { HttpError } from '../../lib/errors.js';
import { requireAuth } from '../../plugins/auth.js';
import { journaliser, requireAdmin } from '../../plugins/admin.js';
import { gateway } from '../../ws/gateway.js';

/**
 * Routes d'administration.
 *
 * Aucune ne renvoie de contenu de message, et aucune ne peut en renvoyer : le
 * serveur ne détient pas de clé privée. Ce fichier manipule exclusivement des
 * métadonnées que le serveur possède déjà pour acheminer les messages.
 *
 * Le support aux utilisateurs, lui, ne passe pas par ici : c'est une
 * conversation chiffrée ordinaire avec le compte d'administration, comme avec
 * n'importe quel autre contact. Rien de particulier à construire — et surtout
 * rien qui donne à l'administrateur un accès qu'un correspondant n'aurait pas.
 */

const DUREE_JETON_MINUTES = 30;

export async function adminRoutes(app: FastifyInstance) {
  const garde = { preHandler: [requireAuth, requireAdmin] };

  /** Recherche de comptes. Métadonnées uniquement. */
  app.get('/admin/users', garde, async (request) => {
    const { q } = z
      .object({ q: z.string().min(1).max(120).optional() })
      .parse(request.query);

    const users = await prisma.user.findMany({
      where: q ? { username: { contains: q, mode: 'insensitive' } } : {},
      orderBy: { createdAt: 'desc' },
      take: 50,
      select: {
        id: true,
        username: true,
        role: true,
        createdAt: true,
        deletedAt: true,
        totpEnabledAt: true,
        _count: { select: { devices: true } },
      },
    });

    return users.map((u) => ({
      id: u.id,
      username: u.username,
      role: u.role,
      createdAt: u.createdAt.toISOString(),
      supprime: u.deletedAt !== null,
      deuxFacteurs: u.totpEnabledAt !== null,
      appareils: u._count.devices,
    }));
  });

  /**
   * Émet un jeton de réinitialisation, à la demande du titulaire du compte.
   *
   * L'administrateur ne fixe PAS de mot de passe et n'en apprend aucun : il
   * transmet un jeton à usage unique que l'utilisateur échange lui-même contre
   * le mot de passe de son choix. C'est ce qui empêche un administrateur —
   * ou quiconque prendrait son compte — de se connecter à la place de
   * l'utilisateur puis de rattacher un appareil, seul moyen par lequel il
   * pourrait lire les messages À VENIR.
   *
   * Le jeton est stocké haché : même en base, il ne peut pas être rejoué.
   */
  app.post('/admin/users/:id/password-reset', garde, async (request) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    const body = z.object({ reason: z.string().max(500).optional() }).parse(request.body ?? {});

    const user = await prisma.user.findUnique({ where: { id } });
    if (!user || user.deletedAt) throw new HttpError(404, 'compte introuvable');

    const jeton = randomBytes(32).toString('base64url');
    await prisma.user.update({
      where: { id },
      data: {
        resetTokenHash: createHash('sha256').update(jeton).digest('hex'),
        resetExpiresAt: new Date(Date.now() + DUREE_JETON_MINUTES * 60 * 1000),
      },
    });

    await journaliser(request.auth!.userId, 'password_reset_issued', {
      id: user.id,
      label: user.username,
      reason: body.reason,
    });

    return {
      jeton,
      expireDans: `${DUREE_JETON_MINUTES} minutes`,
      rappel:
        'À transmettre au titulaire du compte par un canal dont tu es sûr. Ce ' +
        'jeton ne donne accès à AUCUN message : les clés sont sur ses ' +
        'appareils, pas ici. Il ne restaure pas non plus un historique perdu.',
    };
  });

  /**
   * Supprime un compte.
   *
   * Ce que ça efface : le compte, ses appareils, ses sessions, ses clés
   * publiques. Ce que ça n'efface PAS : les messages déjà reçus et déchiffrés
   * chez ses correspondants — ils sont sur leurs appareils, hors de portée du
   * serveur. Prétendre le contraire serait mentir à qui demande la suppression.
   */
  app.delete('/admin/users/:id', garde, async (request, reply) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    const body = z
      .object({ reason: z.string().min(3).max(500) })
      .parse(request.body ?? {});

    if (id === request.auth!.userId) {
      throw new HttpError(400, 'un administrateur ne se supprime pas lui-même');
    }

    const user = await prisma.user.findUnique({
      where: { id },
      select: { id: true, username: true, role: true, devices: { select: { id: true } } },
    });
    if (!user) throw new HttpError(404, 'compte introuvable');
    if (user.role === 'admin') {
      // Un administrateur qui en supprime un autre est le scénario par lequel
      // un compte compromis verrouille tout le monde dehors.
      throw new HttpError(403, 'un compte d’administration ne se supprime pas par l’API');
    }

    // Journalisé AVANT l'effacement : après, le nom d'utilisateur n'existe plus
    // et la trace ne renverrait à rien.
    await journaliser(request.auth!.userId, 'account_deleted', {
      id: user.id,
      label: user.username,
      reason: body.reason,
    });

    for (const d of user.devices) gateway?.deconnecterAppareil(d.id);
    await prisma.user.delete({ where: { id } });

    return reply.code(204).send();
  });

  /** Journal des actions d'administration. En lecture seule, jamais purgé. */
  app.get('/admin/actions', garde, async (request) => {
    const { limit } = z
      .object({ limit: z.coerce.number().int().min(1).max(200).default(50) })
      .parse(request.query);

    const actions = await prisma.adminAction.findMany({
      orderBy: { createdAt: 'desc' },
      take: limit,
    });

    // Le nom de l'auteur plutôt que son identifiant : un journal qu'il faut
    // déchiffrer soi-même n'est pas consulté.
    const acteurs = await prisma.user.findMany({
      where: { id: { in: [...new Set(actions.map((a) => a.actorUserId))] } },
      select: { id: true, username: true },
    });
    const nom = new Map(acteurs.map((a) => [a.id, a.username]));

    return actions.map((a) => ({
      date: a.createdAt.toISOString(),
      par: nom.get(a.actorUserId) ?? a.actorUserId,
      action: a.action,
      cible: a.targetLabel,
      motif: a.reason,
    }));
  });
}

/**
 * Échange du jeton contre un nouveau mot de passe. Route PUBLIQUE : son
 * titulaire n'a plus accès à son compte, c'est tout l'objet.
 */
export async function passwordResetRoutes(app: FastifyInstance) {
  app.post('/auth/password-reset', async (request, reply) => {
    const body = z
      .object({
        username: z.string().min(1),
        token: z.string().min(20),
        newPassword: z.string().min(12).max(200),
      })
      .parse(request.body);

    const user = await prisma.user.findUnique({ where: { username: body.username } });
    const hash = createHash('sha256').update(body.token).digest('hex');

    // Message unique quelle que soit la cause : sans cela, la réponse
    // distinguerait « compte inexistant » de « jeton expiré », ce qui permet
    // d'énumérer les comptes.
    const invalide = () =>
      new HttpError(400, 'jeton invalide ou expiré — demande-en un nouveau');

    if (
      !user ||
      user.deletedAt ||
      !user.resetTokenHash ||
      !user.resetExpiresAt ||
      user.resetExpiresAt < new Date() ||
      user.resetTokenHash !== hash
    ) {
      throw invalide();
    }

    const passwordHash = await argon2.hash(body.newPassword, { type: argon2.argon2id });

    await prisma.$transaction(async (tx) => {
      await tx.user.update({
        where: { id: user.id },
        data: { passwordHash, resetTokenHash: null, resetExpiresAt: null },
      });
      // Toutes les sessions tombent : si le mot de passe a été réinitialisé
      // parce qu'il était compromis, laisser les sessions ouvertes viderait
      // l'opération de son sens.
      await tx.authSession.updateMany({
        where: { userId: user.id, revokedAt: null },
        data: { revokedAt: new Date() },
      });
    });

    return reply.send({
      ok: true,
      rappel:
        'Tes appareils déjà liés gardent leurs clés et ton historique. Tu devras ' +
        't’y reconnecter. Ce changement ne restaure aucun message perdu.',
    });
  });
}
