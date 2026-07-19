/**
 * Contrat d'un fournisseur de notifications push.
 *
 * ## Pourquoi le payload est vide
 *
 * Google (FCM) et Apple (APNs) voient en clair tout ce qui transite par leurs
 * serveurs : ce sont des tiers non fiables du point de vue du modèle de menace.
 * Une notification qui contiendrait le nom de l'expéditeur ou un aperçu du
 * message annulerait le chiffrement de bout en bout pour la seule métadonnée
 * qui compte vraiment — qui parle à qui, et quand.
 *
 * ZiaCrypte n'envoie donc qu'un **signal creux** : « un blob t'attend ».
 * L'application se réveille, relève sa boîte via l'API authentifiée, déchiffre
 * localement, puis compose elle-même la notification affichée. Le fournisseur
 * apprend au mieux qu'un appareil a reçu quelque chose, jamais quoi ni de qui.
 *
 * C'est le compromis retenu par Signal. Session s'en passe complètement, au
 * prix de la réactivité ; nous gardons le push parce qu'un messager qui
 * n'arrive pas quand l'écran est éteint n'est pas utilisé.
 */
export interface PushProvider {
  /** Plateforme servie, telle que stockée en base. */
  readonly platform: 'fcm' | 'apns';

  /**
   * Réveille un appareil. Ne transporte aucun contenu : voir l'en-tête.
   *
   * Ne doit jamais lever : un échec de notification n'a pas à faire échouer
   * l'envoi du message, qui est déjà persisté et sera relevé à la prochaine
   * connexion. Le résultat sert uniquement à purger les jetons morts.
   */
  wake(token: string): Promise<WakeResult>;
}

export type WakeResult =
  /** Le fournisseur a accepté le signal. */
  | { status: 'sent' }
  /** Jeton périmé ou désinscrit : l'appelant doit le supprimer. */
  | { status: 'stale' }
  /** Panne transitoire (réseau, 5xx) : on retentera au prochain message. */
  | { status: 'error'; reason: string };

/**
 * Fournisseur inerte, utilisé quand aucun identifiant n'est configuré.
 *
 * Permet de faire tourner le serveur en développement et en test sans compte
 * Google ni Apple. Il journalise au lieu d'émettre, ce qui rend le repli
 * observable plutôt que silencieux.
 */
export class InertPushProvider implements PushProvider {
  readonly platform: 'fcm' | 'apns';
  /** Jetons réveillés, dans l'ordre — lu par les tests. */
  readonly woken: string[] = [];

  constructor(
    platform: 'fcm' | 'apns',
    private readonly log?: (msg: string) => void,
  ) {
    this.platform = platform;
  }

  async wake(token: string): Promise<WakeResult> {
    this.woken.push(token);
    this.log?.(
      `push ${this.platform} non configuré : réveil ignoré pour ${token.slice(0, 8)}…`,
    );
    return { status: 'sent' };
  }
}
