import type { Server } from 'node:http';
import { WebSocketServer, WebSocket } from 'ws';
import { verifyAccess } from '../lib/tokens.js';

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

  constructor(server: Server) {
    this.wss = new WebSocketServer({ server, path: '/ws' });

    this.wss.on('connection', (socket, request) => {
      // Le jeton passe en paramètre d'URL : les en-têtes personnalisés ne sont
      // pas disponibles à la poignée de main WebSocket côté navigateur.
      const url = new URL(request.url ?? '/ws', 'http://localhost');
      const token = url.searchParams.get('token');

      let deviceId: string;
      try {
        deviceId = verifyAccess(token ?? '').did;
      } catch {
        socket.close(4001, 'jeton invalide');
        return;
      }

      this.attach(deviceId, socket);

      socket.on('close', () => this.detach(deviceId, socket));
      socket.on('error', () => this.detach(deviceId, socket));
      socket.on('message', (raw) => {
        const texte = raw.toString();
        // Ping applicatif (maintien de connexion).
        if (texte === 'ping') {
          socket.send('pong');
          return;
        }
        this.relayerEphemere(deviceId, texte);
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
    const sockets = this.byDevice.get(deviceId);
    if (!sockets) return;
    sockets.delete(socket);
    if (sockets.size === 0) this.byDevice.delete(deviceId);
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
  private relayerEphemere(expediteur: string, brut: string) {
    let message: { type?: unknown; to?: unknown; conversationId?: unknown };
    try {
      message = JSON.parse(brut);
    } catch {
      return;
    }
    if (message.type !== 'typing' && message.type !== 'typing.stop') return;
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
