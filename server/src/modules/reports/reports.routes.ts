import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../db/prisma.js';
import { HttpError } from '../../lib/errors.js';
import { requireAuth } from '../../plugins/auth.js';
import { journaliser, requireAdmin } from '../../plugins/admin.js';
import { reportRateLimit } from '../../plugins/rate-limit.js';

/**
 * Signalement d'abus.
 *
 * ## Le seul chemin honnête vers un contenu chiffré
 *
 * Le serveur ne lit pas les messages : il n'a pas les clés. La modération ne
 * peut donc PAS partir de lui. Elle part du DESTINATAIRE — lui seul a déchiffré
 * le message, lui seul peut choisir de le révéler. Le dépôt d'un signalement,
 * c'est exactement ce moment : le client renvoie le clair que l'utilisateur a
 * décidé de transmettre. Le chiffrement de bout en bout n'est pas contourné, il
 * est respecté ; la seule personne à pouvoir lever le voile est la victime, sur
 * son propre message.
 *
 * Le contenu est facultatif : un signalement pour harcèlement répété ou spam
 * reste recevable sur le seul nom du compte visé.
 */

// Motifs cadrés sur la charte d'usage. Volontairement peu nombreux : une liste
// courte est comprise et effectivement utilisée ; une liste fleuve ne l'est pas.
const MOTIFS = ['spam', 'harcelement', 'contenu_illegal', 'arnaque', 'autre'] as const;

const reportSchema = z.object({
  // Le signaleur nomme le compte visé : il vient de déchiffrer son message, il
  // sait qui c'est. Le serveur, lui, l'ignore quand l'envoi était scellé.
  reportedUsername: z.string().min(1).max(120),
  reason: z.enum(MOTIFS),
  note: z.string().max(2000).optional(),
  // Copie EN CLAIR du message, transmise volontairement. Bornée pour ne pas
  // faire du signalement un canal de dépôt détourné.
  content: z.string().max(20000).optional(),
  context: z.string().max(4000).optional(),
});

const resolveSchema = z.object({
  status: z.enum(['resolved', 'dismissed']),
  resolution: z.string().max(2000).optional(),
});

export async function reportsRoutes(app: FastifyInstance) {
  /**
   * Dépose un signalement. Authentifié : on veut pouvoir recouper les abus de
   * l'outil de signalement lui-même (dénonciations en masse), et un signalement
   * anonyme n'apporte rien de plus à qui décide au bout.
   */
  app.post('/reports', { preHandler: requireAuth, config: reportRateLimit() }, async (request, reply) => {
    const body = reportSchema.parse(request.body);
    const me = request.auth!;

    const moi = await prisma.user.findUnique({
      where: { id: me.userId },
      select: { username: true },
    });

    // Résolution du compte visé, au mieux : on garde toujours le LABEL fourni,
    // même si le compte est introuvable (déjà supprimé, pseudo mal orthographié).
    // Le signalement reste exploitable — il ne dépend pas d'une jointure.
    const vise = await prisma.user.findUnique({
      where: { username: body.reportedUsername },
      select: { id: true, username: true },
    });

    const report = await prisma.report.create({
      data: {
        reporterUserId: me.userId,
        reporterLabel: moi?.username ?? null,
        reportedUserId: vise?.id ?? null,
        reportedLabel: vise?.username ?? body.reportedUsername,
        reason: body.reason,
        note: body.note ?? null,
        content: body.content ?? null,
        context: body.context ?? null,
      },
      select: { id: true },
    });

    // Accusé volontairement sobre : on ne dit pas si le compte visé « existe »,
    // ce qui permettrait d'énumérer les comptes en signalant des pseudos au
    // hasard.
    return reply.code(201).send({ ok: true, id: report.id });
  });

  const garde = { preHandler: [requireAuth, requireAdmin] };

  /** File des signalements. Par défaut, ceux qui restent à traiter. */
  app.get('/admin/reports', garde, async (request) => {
    const { status, limit } = z
      .object({
        status: z.enum(['open', 'resolved', 'dismissed', 'all']).default('open'),
        limit: z.coerce.number().int().min(1).max(200).default(50),
      })
      .parse(request.query);

    const reports = await prisma.report.findMany({
      where: status === 'all' ? {} : { status },
      orderBy: { createdAt: 'desc' },
      take: limit,
    });

    return reports.map((r) => ({
      id: r.id,
      signalePar: r.reporterLabel,
      compteVise: r.reportedLabel,
      compteViseId: r.reportedUserId,
      motif: r.reason,
      note: r.note,
      // Le clair transmis par la victime. Renvoyé tel quel à l'administrateur :
      // c'est l'objet même du signalement. Rien d'autre du compte visé n'est
      // lisible — ni ses autres messages, ni ses clés.
      contenu: r.content,
      contexte: r.context,
      statut: r.status,
      date: r.createdAt.toISOString(),
      traiteLe: r.handledAt?.toISOString() ?? null,
      resolution: r.resolution,
    }));
  });

  /**
   * Clôt un signalement : traité ou écarté. Ne fait rien au compte visé — la
   * sanction (bannissement, suppression) passe par les routes de comptes, et
   * reste ainsi tracée séparément dans le journal d'administration.
   */
  app.post('/admin/reports/:id/resolve', garde, async (request) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
    const body = resolveSchema.parse(request.body ?? {});

    const report = await prisma.report.findUnique({ where: { id } });
    if (!report) throw new HttpError(404, 'signalement introuvable');

    await prisma.report.update({
      where: { id },
      data: {
        status: body.status,
        handledByUserId: request.auth!.userId,
        handledAt: new Date(),
        resolution: body.resolution ?? null,
      },
    });

    await journaliser(request.auth!.userId, `report_${body.status}`, {
      id: report.reportedUserId ?? undefined,
      label: report.reportedLabel ?? undefined,
      reason: body.resolution,
    });

    return { ok: true };
  });
}
