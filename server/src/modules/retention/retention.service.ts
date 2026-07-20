import { DeleteObjectCommand } from '@aws-sdk/client-s3';
import { env } from '../../config/env.js';
import { prisma } from '../../db/prisma.js';
import { s3 } from '../../lib/storage.js';

/**
 * Purge des données arrivées à échéance.
 *
 * Toutes les tables portaient déjà une date d'expiration, et rien ne la lisait
 * jamais : la base grossissait sans fin et le chiffré restait stocké bien
 * au-delà de la durée annoncée. Une promesse de rétention que personne
 * n'applique n'est pas une promesse.
 *
 * L'enjeu n'est pas seulement la place disque. Ce serveur est conçu pour ne
 * rien pouvoir lire ; il reste que ce qu'il conserve peut être saisi, copié ou
 * fuité. Moins il en garde, moins il y a à perdre — y compris les métadonnées
 * (qui a écrit à qui, et quand), que le chiffrement de bout en bout ne protège
 * pas.
 */
export interface PurgeReport {
  blobsLivres: number;
  blobsExpires: number;
  piecesJointes: number;
  piecesJointesEchouees: number;
  sessions: number;
  conversationsOrphelines: number;
}

export async function purgeExpired(
  log: (msg: string) => void = () => {},
): Promise<PurgeReport> {
  const maintenant = new Date();

  // --- Blobs déjà remis ---
  //
  // `GET /v1/messages` ne renvoie que les blobs dont deliveredAt est nul : une
  // fois relevé, un blob est donc DÉJÀ inatteignable par son destinataire. Le
  // conserver ne sert plus à la remise, seulement à constituer une réserve de
  // chiffré et de métadonnées. Le court délai de grâce laisse la place à une
  // éventuelle reprise côté client avant l'effacement définitif.
  const seuilLivraison = new Date(
    maintenant.getTime() - env.RETENTION_DELIVERED_HOURS * 3600 * 1000,
  );
  const blobsLivres = await prisma.messageBlob.deleteMany({
    where: { deliveredAt: { not: null, lt: seuilLivraison } },
  });

  // --- Blobs jamais relevés, arrivés à échéance ---
  // Le destinataire n'est pas revenu dans le délai annoncé. On tient parole.
  const blobsExpires = await prisma.messageBlob.deleteMany({
    where: { expiresAt: { lt: maintenant } },
  });

  // --- Pièces jointes ---
  //
  // L'ORDRE COMPTE. Supprimer d'abord la ligne rendrait l'objet chiffré
  // introuvable : plus rien en base ne porterait sa clé de stockage, et il
  // resterait chez l'hébergeur indéfiniment. On efface donc l'objet d'abord, et
  // on ne retire la ligne qu'en cas de succès — un échec laisse la ligne en
  // place pour être retentée au prochain passage.
  // Sans stockage configuré, on ne peut pas supprimer les objets : on laisse
  // les lignes en place plutôt que de les orpheliner définitivement.
  const perimees =
    s3 === null
      ? []
      : await prisma.attachmentRef.findMany({
          where: { expiresAt: { lt: maintenant } },
          select: { id: true, storageKey: true },
          take: 500,
        });

  let piecesJointes = 0;
  let piecesJointesEchouees = 0;
  for (const piece of perimees) {
    try {
      await s3!.send(
        new DeleteObjectCommand({ Bucket: env.S3_BUCKET, Key: piece.storageKey }),
      );
      await prisma.attachmentRef.delete({ where: { id: piece.id } });
      piecesJointes += 1;
    } catch (e) {
      piecesJointesEchouees += 1;
      log(
        `purge : objet ${piece.storageKey} non supprimé (${
          e instanceof Error ? e.message : String(e)
        }) — la ligne est conservée pour réessayer`,
      );
    }
  }

  // --- Sessions d'authentification ---
  // Expirées ou révoquées : leur hachage de refresh token n'a plus d'usage.
  const sessions = await prisma.authSession.deleteMany({
    where: {
      OR: [{ expiresAt: { lt: maintenant } }, { revokedAt: { not: null } }],
    },
  });

  // --- Conversations sans participant ---
  //
  // Il en reste après la suppression des comptes concernés. Ce n'est pas
  // qu'une question de place : une telle conversation satisfait par vacuité un
  // filtre `every` et avait déjà provoqué la création de conversations en
  // double, rendant l'historique local inaccessible.
  const conversationsOrphelines = await prisma.conversation.deleteMany({
    where: { participants: { none: {} } },
  });

  const rapport: PurgeReport = {
    blobsLivres: blobsLivres.count,
    blobsExpires: blobsExpires.count,
    piecesJointes,
    piecesJointesEchouees,
    sessions: sessions.count,
    conversationsOrphelines: conversationsOrphelines.count,
  };

  const total =
    rapport.blobsLivres +
    rapport.blobsExpires +
    rapport.piecesJointes +
    rapport.sessions +
    rapport.conversationsOrphelines;
  if (total > 0 || rapport.piecesJointesEchouees > 0) {
    log(`purge : ${JSON.stringify(rapport)}`);
  }
  return rapport;
}

/**
 * Lance la purge périodiquement.
 *
 * Un `setInterval` dans le processus suffit ici : le serveur est une instance
 * unique. Avec plusieurs instances il faudrait un verrou pour éviter que toutes
 * purgent en même temps — les suppressions sont idempotentes, mais autant ne
 * pas gaspiller.
 *
 * Les passages ne se chevauchent pas : si l'un dure plus longtemps que
 * l'intervalle, le suivant est simplement sauté.
 */
export function schedulePurge(log: (msg: string) => void) {
  let enCours = false;

  const passer = async () => {
    if (enCours) return;
    enCours = true;
    try {
      await purgeExpired(log);
    } catch (e) {
      // Une purge qui échoue ne doit jamais faire tomber le serveur : au pire
      // les données restent une période de plus.
      log(`purge : échec (${e instanceof Error ? e.message : String(e)})`);
    } finally {
      enCours = false;
    }
  };

  // Un premier passage peu après le démarrage rattrape ce qui s'est accumulé
  // pendant l'arrêt, sans retarder la mise en service.
  const amorce = setTimeout(passer, 30_000);
  const periodique = setInterval(passer, env.RETENTION_INTERVAL_HOURS * 3600 * 1000);

  // unref : ces minuteries ne doivent pas empêcher le processus de s'arrêter.
  amorce.unref();
  periodique.unref();

  return () => {
    clearTimeout(amorce);
    clearInterval(periodique);
  };
}
