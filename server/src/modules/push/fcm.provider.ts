import { createSign } from 'node:crypto';
import type { PushProvider, WakeResult } from './push.provider.js';

/**
 * Fournisseur Firebase Cloud Messaging (API HTTP v1).
 *
 * Implémenté directement contre l'API REST plutôt qu'avec `firebase-admin` :
 * ce code est sur le chemin des métadonnées de tous les utilisateurs, et le SDK
 * traîne une centaine de dépendances transitives dont aucune n'est auditable
 * raisonnablement. Ici il n'y a que `node:crypto` et `fetch`, tous deux natifs.
 *
 * Le message envoyé est **data-only** : aucun bloc `notification`. Android ne
 * l'affiche donc pas lui-même, il réveille l'application, qui relève sa boîte,
 * déchiffre localement et compose la notification visible. Google ne voit
 * transiter que `{"t":"m"}`.
 */
export class FcmProvider implements PushProvider {
  readonly platform = 'fcm' as const;

  private accessToken: string | null = null;
  private accessTokenExpiry = 0;

  constructor(private readonly account: ServiceAccount) {}

  /**
   * Construit le fournisseur depuis le JSON de compte de service Firebase
   * (Console Firebase → Paramètres → Comptes de service → Générer une clé).
   */
  static fromServiceAccountJson(json: string): FcmProvider {
    const raw = JSON.parse(json) as Partial<ServiceAccount>;
    if (!raw.project_id || !raw.client_email || !raw.private_key) {
      throw new Error(
        'compte de service Firebase invalide : project_id, client_email et private_key sont requis',
      );
    }
    return new FcmProvider({
      project_id: raw.project_id,
      client_email: raw.client_email,
      private_key: raw.private_key,
      token_uri: raw.token_uri ?? 'https://oauth2.googleapis.com/token',
    });
  }

  async wake(token: string): Promise<WakeResult> {
    let bearer: string;
    try {
      bearer = await this.authorize();
    } catch (e) {
      return { status: 'error', reason: `authentification FCM: ${describe(e)}` };
    }

    let response: Response;
    try {
      response = await fetch(
        `https://fcm.googleapis.com/v1/projects/${this.account.project_id}/messages:send`,
        {
          method: 'POST',
          headers: {
            authorization: `Bearer ${bearer}`,
            'content-type': 'application/json',
          },
          body: JSON.stringify({
            message: {
              token,
              // Charge utile creuse. Toute donnée ajoutée ici serait lisible
              // par Google : ne rien y mettre d'autre.
              data: { t: 'm' },
              android: { priority: 'HIGH' },
            },
          }),
          signal: AbortSignal.timeout(10_000),
        },
      );
    } catch (e) {
      return { status: 'error', reason: describe(e) };
    }

    if (response.ok) return { status: 'sent' };

    // 404 UNREGISTERED : application désinstallée. 400 INVALID_ARGUMENT sur un
    // jeton malformé. Dans les deux cas le jeton ne redeviendra jamais valide.
    if (response.status === 404 || response.status === 400) {
      return { status: 'stale' };
    }
    // 401/403 : identifiants serveur erronés — surtout ne pas purger les jetons
    // des utilisateurs pour une faute de configuration de notre côté.
    if (response.status === 401 || response.status === 403) {
      this.accessToken = null; // force un renouvellement au prochain essai
    }
    return { status: 'error', reason: `HTTP ${response.status}` };
  }

  /**
   * Jeton d'accès OAuth2, mis en cache jusqu'à une minute avant son expiration.
   *
   * Google délivre des jetons d'une heure ; en redemander un à chaque
   * notification ajouterait un aller-retour et une limite de débit inutiles.
   */
  private async authorize(): Promise<string> {
    if (this.accessToken && Date.now() < this.accessTokenExpiry) {
      return this.accessToken;
    }

    const now = Math.floor(Date.now() / 1000);
    const claims = {
      iss: this.account.client_email,
      scope: 'https://www.googleapis.com/auth/firebase.messaging',
      aud: this.account.token_uri,
      iat: now,
      exp: now + 3600,
    };

    const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
    const payload = b64url(JSON.stringify(claims));
    const signature = createSign('RSA-SHA256')
      .update(`${header}.${payload}`)
      .sign(this.account.private_key)
      .toString('base64url');

    const response = await fetch(this.account.token_uri, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion: `${header}.${payload}.${signature}`,
      }),
      signal: AbortSignal.timeout(10_000),
    });

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    const body = (await response.json()) as { access_token?: string; expires_in?: number };
    if (!body.access_token) throw new Error('réponse sans access_token');

    this.accessToken = body.access_token;
    this.accessTokenExpiry = Date.now() + ((body.expires_in ?? 3600) - 60) * 1000;
    return this.accessToken;
  }
}

export interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri: string;
}

const b64url = (s: string) => Buffer.from(s, 'utf8').toString('base64url');
const describe = (e: unknown) => (e instanceof Error ? e.message : String(e));
