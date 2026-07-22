import type { Server } from 'node:http';
import { WebSocketServer, WebSocket } from 'ws';
import { verifyAccess } from '../lib/tokens.js';
import {
  appareilsDeDeuxComptes,
  autoriserObservation,
  MAX_ABONNEMENTS,
} from './presence.js';

/**
 * Gateway temps réel.
 *
 * Le serveur ne pousse que des blobs opaques : il notifie l'appareil
 * destinataire qu'un message l'attend, sans jamais rien pouvoir déchiffrer.
 * Le client relit ensuite sa boîte via l'API — la remise reste donc fiable même
 * si la connexion tombe, le WebSocket ne servant qu'à supprimer la latence du
 * polling.
 */
export class RealtimeGateway {
  private readonly wss: WebSocketServer;
  /** Connexions par appareil : un même appareil peut avoir plusieurs onglets. */
  private readonly byDevice = new Map<string, Set<WebSocket>>();

  /** Titulaire de chaque connexion, retenu à la poignée de main. */
  private readonly titulaires = new Map<WebSocket, { deviceId: string; userId: string }>();

  /** Appareils observés par une connexion, déjà autorisés à l'abonnement. */
  private readonly abonnements = new Map<WebSocket, Set<string>>();

  /** Index inverse : qui prévenir quand cet appareil change d'état. */
  private readonly observateurs = new Map<string, Set<WebSocket>>();

  /**
   * Appareils ayant DEMANDÉ à être vus en ligne.
   *
   * Volontairement en mémoire et non en base : la présence est un état de
   * connexion, pas une donnée de compte. Elle ne survit pas au redémarrage du
   * serveur — ce qui est le bon comportement, puisque les connexions non plus.
   */
  private readonly visibles = new Set<string>();

  constructor(server: Server) {
    this.wss = new WebSocketServer({ server, path: '/ws' });

    this.wss.on('connection', (socket, request) => {
      // Le jeton passe en paramètre d'URL : les en-têtes personnalisés ne sont
      // pas disponibles à la poignée de main WebSocket côté navigateur.
      const url = new URL(request.url ?? '/ws', 'http://localhost');
      const token = url.searchParams.get('token');

      let deviceId: string;
      let userId: string;
      try {
        const claims = verifyAccess(token ?? '');
        deviceId = claims.did;
        userId = claims.sub;
      } catch {
        socket.close(4001, 'jeton invalide');
        return;
      }

      this.attach(deviceId, socket);
      this.titulaires.set(socket, { deviceId, userId });

      socket.on('close', () => this.detach(deviceId, socket));
      socket.on('error', () => this.detach(deviceId, socket));
      socket.on('message', (raw) => {
        const texte = raw.toString();
        // Ping applicatif (maintien de connexion).
        if (texte === 'ping') {
          socket.send('pong');
          return;
        }
        this.traiterMessage(socket, deviceId, texte);
      });

      socket.send(JSON.stringify({ type: 'ready' }));
    });
  }

  private attach(deviceId: string, socket: WebSocket) {
    const sockets = this.byDevice.get(deviceId) ?? new Set<WebSocket>();
    sockets.add(socket);
    this.byDevice.set(deviceId, sockets);
  }

  private detach(deviceId: string, socket: WebSocket) {
    this.titulaires.delete(socket);
    this.desabonner(socket);

    const sockets = this.byDevice.get(deviceId);
    if (!sockets) return;
    sockets.delete(socket);
    if (sockets.size > 0) return;

    // Dernière connexion de l'appareil : il passe hors ligne. Tant qu'il lui
    // reste une socket (une autre fenêtre, une reconnexion en recouvrement),
    // annoncer « hors ligne » ferait clignoter l'indicateur chez les autres.
    this.byDevice.delete(deviceId);
    if (this.visibles.delete(deviceId)) this.diffuserPresence(deviceId, 'offline');
  }

  /** Aiguille un message client. Le JSON n'est analysé qu'une fois. */
  private traiterMessage(socket: WebSocket, deviceId: string, brut: string) {
    let message: Record<string, unknown>;
    try {
      const analyse: unknown = JSON.parse(brut);
      if (typeof analyse !== 'object' || analyse === null) return;
      message = analyse as Record<string, unknown>;
    } catch {
      return;
    }

    switch (message.type) {
      case 'typing':
      case 'typing.stop':
        this.relayerEphemere(deviceId, message);
        return;
      case 'presence.mode':
        this.declarerVisibilite(deviceId, message.visible === true);
        return;
      case 'presence.subscribe':
        void this.abonnerPresence(socket, message);
        return;
      default:
        return;
    }
  }

  /**
   * Relaie un signal ÉPHÉMÈRE entre appareils, sans jamais le stocker.
   *
   * Sert à l'indicateur « en train d'écrire ». Le passer par un message chiffré
   * brûlerait un cran de ratchet et créerait un blob à chaque frappe, pour une
   * information périmée en trois secondes.
   *
   * Ce que le serveur apprend : que cet appareil écrit vers tels appareils. Il
   * connaît DÉJÀ cette relation — il achemine leurs messages. Le supplément est
   * une granularité temporelle, et c'est pourquoi l'indicateur est désactivable
   * côté client.
   *
   * Rien n'est persisté, rien n'est relayé à qui n'est pas connecté : un
   * indicateur d'écriture arrivé plus tard n'aurait aucun sens.
   */
  private relayerEphemere(
    expediteur: string,
    message: { type?: unknown; to?: unknown; conversationId?: unknown },
  ) {
    if (!Array.isArray(message.to) || typeof message.conversationId !== 'string') {
      return;
    }
    // Borne : un client bavard ne doit pas pouvoir arroser tout le monde.
    const cibles = (message.to as unknown[])
      .filter((d): d is string => typeof d === 'string')
      .slice(0, 50);

    const charge = JSON.stringify({
      type: message.type,
      conversationId: message.conversationId,
      from: expediteur,
    });
    for (const cible of cibles) {
      const sockets = this.byDevice.get(cible);
      if (!sockets) continue;
      for (const s of sockets) {
        if (s.readyState === WebSocket.OPEN) s.send(charge);
      }
    }
  }

  /**
   * Déclare si cet appareil accepte d'être vu « en ligne ».
   *
   * Rien n'est diffusé avant cette déclaration : la présence est un choix, et
   * un client qui ne l'exprime pas — parce qu'il est plus ancien que la
   * fonctionnalité, ou parce que l'utilisateur l'a désactivée — reste
   * silencieux. Le réglage vit côté client, comme l'indicateur d'écriture : le
   * serveur n'a aucune raison de mémoriser une préférence de plus.
   */
  private declarerVisibilite(deviceId: string, visible: boolean) {
    if (visible === this.visibles.has(deviceId)) return;
    if (visible) {
      this.visibles.add(deviceId);
      this.diffuserPresence(deviceId, 'online');
    } else {
      this.visibles.delete(deviceId);
      this.diffuserPresence(deviceId, 'offline');
    }
  }

  /**
   * Abonne une connexion à l'état d'un ensemble d'appareils.
   *
   * L'abonnement REMPLACE le précédent : le client envoie la liste de ce qui
   * l'intéresse à l'instant (les correspondants de ses conversations ouvertes),
   * sans avoir à se désabonner de quoi que ce soit.
   *
   * La réponse est un instantané des appareils autorisés ET actuellement en
   * ligne. Sans lui, un client ne saurait rien jusqu'au prochain changement
   * d'état : quelqu'un déjà connecté paraîtrait absent.
   */
  private async abonnerPresence(socket: WebSocket, message: Record<string, unknown>) {
    const titulaire = this.titulaires.get(socket);
    if (!titulaire) return;

    const demandes = Array.isArray(message.devices)
      ? (message.devices as unknown[])
          .filter((d): d is string => typeof d === 'string')
          .slice(0, MAX_ABONNEMENTS)
      : [];

    const autorises = await autoriserObservation(titulaire.userId, demandes);
    // La connexion a pu se fermer pendant la vérification en base.
    if (!this.titulaires.has(socket)) return;

    this.desabonner(socket);
    if (autorises.size > 0) {
      this.abonnements.set(socket, autorises);
      for (const cible of autorises) {
        const set = this.observateurs.get(cible) ?? new Set<WebSocket>();
        set.add(socket);
        this.observateurs.set(cible, set);
      }
    }

    if (socket.readyState !== WebSocket.OPEN) return;
    socket.send(
      JSON.stringify({
        type: 'presence.snapshot',
        online: [...autorises].filter((d) => this.estEnLigne(d)),
      }),
    );
  }

  /** Retire une connexion de tous les index d'observation. */
  private desabonner(socket: WebSocket) {
    const cibles = this.abonnements.get(socket);
    if (!cibles) return;
    for (const cible of cibles) {
      const set = this.observateurs.get(cible);
      if (!set) continue;
      set.delete(socket);
      if (set.size === 0) this.observateurs.delete(cible);
    }
    this.abonnements.delete(socket);
  }

  /** En ligne = au moins une socket ouverte, ET visibilité déclarée. */
  private estEnLigne(deviceId: string): boolean {
    if (!this.visibles.has(deviceId)) return false;
    const sockets = this.byDevice.get(deviceId);
    if (!sockets) return false;
    for (const s of sockets) if (s.readyState === WebSocket.OPEN) return true;
    return false;
  }

  private diffuserPresence(deviceId: string, etat: 'online' | 'offline') {
    const observateurs = this.observateurs.get(deviceId);
    if (!observateurs) return;
    const charge = JSON.stringify({ type: 'presence', device: deviceId, state: etat });
    for (const socket of observateurs) {
      if (socket.readyState === WebSocket.OPEN) socket.send(charge);
    }
  }

  /**
   * Coupe les abonnements croisés entre deux comptes, à l'instant d'un blocage.
   *
   * C'est le seul endroit où une autorisation accordée à l'abonnement peut
   * devenir fausse pendant qu'une connexion vit. Sans cette coupure, bloquer
   * quelqu'un ne le priverait de la présence qu'à sa prochaine reconnexion —
   * autant dire pas.
   */
  async revoquerPresence(userA: string, userB: string) {
    const { a, b } = await appareilsDeDeuxComptes(userA, userB);
    for (const [socket, titulaire] of this.titulaires) {
      const interdits =
        titulaire.userId === userA ? b : titulaire.userId === userB ? a : null;
      if (!interdits) continue;
      const cibles = this.abonnements.get(socket);
      if (!cibles) continue;
      for (const cible of interdits) {
        if (!cibles.delete(cible)) continue;
        const set = this.observateurs.get(cible);
        if (!set) continue;
        set.delete(socket);
        if (set.size === 0) this.observateurs.delete(cible);
      }
      if (cibles.size === 0) this.abonnements.delete(socket);
    }
  }

  /**
   * Prévient un appareil qu'un blob l'attend.
   *
   * Renvoie `true` si au moins une socket ouverte a reçu le signal. L'appelant
   * s'en sert pour décider d'un repli en notification push : une socket
   * présente mais en cours de fermeture ne compte pas comme jointe.
   */
  notifyPending(deviceId: string): boolean {
    const sockets = this.byDevice.get(deviceId);
    if (!sockets) return false;
    const payload = JSON.stringify({ type: 'message.pending' });
    let delivered = false;
    for (const socket of sockets) {
      if (socket.readyState !== WebSocket.OPEN) continue;
      socket.send(payload);
      delivered = true;
    }
    return delivered;
  }

  /**
   * Ferme les sockets d'un appareil révoqué.
   *
   * Une connexion WebSocket est authentifiée une seule fois, à l'ouverture :
   * sans cette coupure, un appareil révoqué garderait un canal temps réel
   * ouvert et continuerait d'être prévenu des messages en attente, alors même
   * que l'API le refuse déjà.
   */
  deconnecterAppareil(deviceId: string) {
    const sockets = this.byDevice.get(deviceId);
    if (!sockets) return;
    for (const socket of sockets) {
      // 4003 : code applicatif, pour que le client distingue une révocation
      // d'une coupure réseau et cesse de se reconnecter en boucle.
      try {
        socket.close(4003, 'appareil révoqué');
      } catch {
        // socket déjà en cours de fermeture : rien à faire
      }
    }
    this.byDevice.delete(deviceId);
    // Un appareil révoqué doit disparaître des indicateurs tout de suite, sans
    // attendre l'évènement de fermeture de chacune de ses sockets.
    if (this.visibles.delete(deviceId)) this.diffuserPresence(deviceId, 'offline');
  }

  get connectedDevices() {
    return this.byDevice.size;
  }
}

/** Instance unique, renseignée au démarrage du serveur. */
export let gateway: RealtimeGateway | null = null;

export function initGateway(server: Server) {
  gateway = new RealtimeGateway(server);
  return gateway;
}
