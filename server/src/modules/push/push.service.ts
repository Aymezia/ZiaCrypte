import { prisma } from '../../db/prisma.js';
import type { PushProvider } from './push.provider.js';

/**
 * Aiguillage des réveils push vers le bon fournisseur, et purge des jetons
 * morts.
 *
 * Ne connaît rien du contenu des messages — il ne reçoit qu'un identifiant
 * d'appareil. Voir `push.provider.ts` pour le raisonnement sur le payload vide.
 */
export class PushService {
  private readonly providers = new Map<string, PushProvider>();

  constructor(providers: PushProvider[]) {
    for (const p of providers) this.providers.set(p.platform, p);
  }

  /** Un fournisseur est-il branché pour cette plateforme ? */
  supports(platform: string) {
    return this.providers.has(platform);
  }

  /**
   * Réveille tous les jetons enregistrés pour un appareil.
   *
   * Ne lève jamais : le message est déjà persisté côté serveur, et le client le
   * relèvera de toute façon à sa prochaine connexion. Un échec de push dégrade
   * la latence, pas la remise.
   *
   * Renvoie le nombre de jetons effectivement réveillés.
   */
  async wakeDevice(deviceId: string): Promise<number> {
    let woken = 0;
    try {
      const tokens = await prisma.pushToken.findMany({ where: { deviceId } });
      for (const row of tokens) {
        const provider = this.providers.get(row.platform);
        if (!provider) continue;

        const result = await provider.wake(row.token);
        if (result.status === 'sent') {
          woken += 1;
        } else if (result.status === 'stale') {
          // Le fournisseur affirme que ce jeton n'existe plus (app désinstallée,
          // jeton renouvelé). Le garder ferait grossir la table sans fin et
          // ferait échouer chaque envoi suivant.
          await prisma.pushToken
            .delete({ where: { id: row.id } })
            .catch(() => undefined);
        }
      }
    } catch {
      // Base indisponible ou fournisseur défaillant : on abandonne le réveil.
      return woken;
    }
    return woken;
  }
}

/** Instance unique, renseignée au démarrage du serveur. */
export let pushService: PushService | null = null;

export function initPush(providers: PushProvider[]) {
  pushService = new PushService(providers);
  return pushService;
}
