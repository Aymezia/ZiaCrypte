/**
 * Éprouve le stockage objet configuré, par un aller-retour RÉEL.
 *
 * ## Pourquoi ce script existe
 *
 * Basculer d'hébergeur se fait en changeant cinq variables. Une faute de frappe
 * dans une clé ne se manifesterait qu'au premier envoi d'une pièce jointe par
 * un utilisateur — trop tard, et sous une forme incompréhensible pour lui.
 *
 * ## Pourquoi il passe par des URL présignées
 *
 * C'est le chemin réel : le serveur signe, et le client dépose ou récupère les
 * octets DIRECTEMENT chez l'hébergeur. Un test qui se contenterait d'appeler le
 * SDK côté serveur validerait un chemin que personne n'emprunte, et laisserait
 * passer les hébergeurs dont les URL présignées ne fonctionnent pas.
 *
 * Vérifie aussi que la suppression efface pour de bon : toute la purge de
 * rétention repose là-dessus, et un effacement qui échoue en silence laisse les
 * pièces jointes s'accumuler indéfiniment.
 *
 *   node server/scripts/check-storage.mjs
 */
import { randomBytes } from 'node:crypto';
import {
  DeleteObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  PutObjectCommand,
  S3Client,
} from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { readFileSync } from 'node:fs';

const envPath = process.argv[2] ?? new URL('../.env', import.meta.url).pathname;
const env = {};
try {
  for (const ligne of readFileSync(envPath, 'utf8').split('\n')) {
    const m = ligne.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, '');
  }
} catch {
  console.error(`Fichier d'environnement illisible : ${envPath}`);
  process.exit(1);
}

const manquantes = ['S3_ENDPOINT', 'S3_BUCKET', 'S3_ACCESS_KEY', 'S3_SECRET_KEY']
  .filter((v) => !env[v]);
if (manquantes.length) {
  console.error(`Variables manquantes : ${manquantes.join(', ')}`);
  process.exit(1);
}

const bucket = env.S3_BUCKET;
const pathStyle = (env.S3_FORCE_PATH_STYLE ?? 'true') === 'true';

console.log(`>> Stockage visé : ${env.S3_ENDPOINT} / ${bucket}`);
console.log(`   région ${env.S3_REGION ?? 'auto'}, style ${pathStyle ? 'chemin' : 'virtuel'}`);

const s3 = new S3Client({
  endpoint: env.S3_ENDPOINT,
  region: env.S3_REGION ?? 'auto',
  forcePathStyle: pathStyle,
  credentials: {
    accessKeyId: env.S3_ACCESS_KEY,
    secretAccessKey: env.S3_SECRET_KEY,
  },
});

const cle = `zia-verification-${Date.now()}-${randomBytes(4).toString('hex')}.bin`;
// Contenu aléatoire : on veut prouver que ce sont NOS octets qui reviennent,
// pas un cache ni un objet resté d'un essai précédent.
const contenu = randomBytes(64 * 1024);

let echec = false;
const etape = (titre, detail) => console.log(`   ${titre} : ${detail}`);

try {
  const urlDepot = await getSignedUrl(
    s3,
    new PutObjectCommand({ Bucket: bucket, Key: cle }),
    { expiresIn: 300 },
  );
  const depot = await fetch(urlDepot, { method: 'PUT', body: contenu });
  if (!depot.ok) throw new Error(`dépôt refusé (HTTP ${depot.status})`);
  etape('dépôt par URL présignée', 'accepté');

  const urlLecture = await getSignedUrl(
    s3,
    new GetObjectCommand({ Bucket: bucket, Key: cle }),
    { expiresIn: 300 },
  );
  const lecture = await fetch(urlLecture);
  if (!lecture.ok) throw new Error(`lecture refusée (HTTP ${lecture.status})`);
  const retour = Buffer.from(await lecture.arrayBuffer());

  if (!retour.equals(contenu)) {
    throw new Error(
      `contenu relu différent (${retour.length} octets contre ${contenu.length})`,
    );
  }
  etape('relecture', `${retour.length} octets, identiques`);

  await s3.send(new DeleteObjectCommand({ Bucket: bucket, Key: cle }));
  let existeEncore = true;
  try {
    await s3.send(new HeadObjectCommand({ Bucket: bucket, Key: cle }));
  } catch {
    existeEncore = false;
  }
  if (existeEncore) {
    throw new Error(
      'objet toujours présent après suppression — la purge de rétention ne ' +
        'pourrait rien effacer chez cet hébergeur',
    );
  }
  etape('suppression', 'effacement confirmé');

  console.log('\n>> Stockage opérationnel : dépôt, relecture conforme, suppression.');
} catch (e) {
  echec = true;
  console.error(`\n>> ÉCHEC : ${e.message}`);
  // Ménage au cas où l'objet aurait été déposé avant l'échec.
  try {
    await s3.send(new DeleteObjectCommand({ Bucket: bucket, Key: cle }));
  } catch {
    // rien de plus à tenter
  }
}

process.exit(echec ? 1 : 0);
