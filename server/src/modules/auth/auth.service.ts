import { hashToken, issueTokens } from '../../lib/tokens.js';
import { prisma } from '../../db/prisma.js';

export interface AuthTokensResponse {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
}

/**
 * Émet une paire de jetons pour (utilisateur, appareil) et enregistre la session
 * de rafraîchissement (refresh token stocké haché). Renvoie la réponse publique.
 */
export async function createSession(
  userId: string,
  deviceId: string,
): Promise<AuthTokensResponse> {
  const tokens = issueTokens({ sub: userId, did: deviceId });
  await prisma.authSession.create({
    data: {
      userId,
      deviceId,
      refreshTokenHash: hashToken(tokens.refreshToken),
      expiresAt: tokens.refreshExpiresAt,
    },
  });
  return {
    accessToken: tokens.accessToken,
    refreshToken: tokens.refreshToken,
    expiresIn: tokens.expiresIn,
  };
}
