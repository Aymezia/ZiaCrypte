import { readFileSync } from 'node:fs';
import { env } from '../../config/env.js';
import { FcmProvider } from './fcm.provider.js';
import { InertPushProvider, type PushProvider } from './push.provider.js';

/**
 * Choisit les fournisseurs push selon la configuration présente.
 *
 * Sans identifiants, on installe un fournisseur inerte plutôt que rien : le
 * serveur démarre et fonctionne (la remise des messages ne dépend pas du push),
 * et le journal dit clairement que les réveils ne partent pas. Un push muet
 * sans trace serait le pire des cas — on croirait la fonctionnalité active.
 */
export function buildPushProviders(log: (msg: string) => void): PushProvider[] {
  const providers: PushProvider[] = [];

  if (env.FCM_SERVICE_ACCOUNT_FILE) {
    try {
      const json = readFileSync(env.FCM_SERVICE_ACCOUNT_FILE, 'utf8');
      providers.push(FcmProvider.fromServiceAccountJson(json));
      log('push FCM actif');
    } catch (e) {
      // On ne laisse pas le serveur démarrer sur une configuration push
      // à moitié faite : un chemin erroné doit se voir tout de suite.
      throw new Error(
        `FCM_SERVICE_ACCOUNT_FILE illisible (${env.FCM_SERVICE_ACCOUNT_FILE}) : ` +
          (e instanceof Error ? e.message : String(e)),
      );
    }
  } else {
    providers.push(new InertPushProvider('fcm', log));
    log('push FCM non configuré : les appareils Android hors ligne ne seront pas réveillés');
  }

  // APNs (iOS) : nécessite une clé de signature .p8 et un identifiant d'équipe
  // Apple. Non implémenté tant que le compte développeur n'existe pas — le
  // fournisseur inerte tient la place et le dit.
  providers.push(new InertPushProvider('apns', log));
  log('push APNs non implémenté : les appareils iOS hors ligne ne seront pas réveillés');

  return providers;
}
