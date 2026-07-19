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
      // Répond au ping applicatif du client (maintien de connexion).
      socket.on('message', (raw) => {
        if (raw.toString() === 'ping') socket.send('pong');
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

  /** Prévient un appareil qu'un blob l'attend. Sans effet s'il est hors ligne. */
  notifyPending(deviceId: string) {
    const sockets = this.byDevice.get(deviceId);
    if (!sockets) return;
    const payload = JSON.stringify({ type: 'message.pending' });
    for (const socket of sockets) {
      if (socket.readyState === WebSocket.OPEN) socket.send(payload);
    }
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
