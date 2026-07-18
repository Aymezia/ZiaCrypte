import { createHash, randomUUID } from 'node:crypto';
import jwt from 'jsonwebtoken';
import { env } from '../config/env.js';

export interface TokenClaims {
  sub: string; // userId
  did: string; // deviceId
}

export interface IssuedTokens {
  accessToken: string;
  refreshToken: string;
  refreshJti: string;
  refreshExpiresAt: Date;
  expiresIn: number; // secondes
}

const ACCESS_TTL_SECONDS = 15 * 60;

export function issueTokens(claims: TokenClaims): IssuedTokens {
  const refreshJti = randomUUID();
  const refreshTtlSeconds = env.REFRESH_TOKEN_TTL_DAYS * 24 * 60 * 60;
  const accessToken = jwt.sign({ ...claims, typ: 'access' }, env.JWT_ACCESS_SECRET, {
    expiresIn: ACCESS_TTL_SECONDS,
  });
  const refreshToken = jwt.sign(
    { ...claims, typ: 'refresh', jti: refreshJti },
    env.JWT_REFRESH_SECRET,
    { expiresIn: refreshTtlSeconds },
  );
  const refreshExpiresAt = new Date(Date.now() + refreshTtlSeconds * 1000);
  return {
    accessToken,
    refreshToken,
    refreshJti,
    refreshExpiresAt,
    expiresIn: ACCESS_TTL_SECONDS,
  };
}

export function verifyAccess(token: string): TokenClaims {
  const payload = jwt.verify(token, env.JWT_ACCESS_SECRET) as jwt.JwtPayload;
  if (payload.typ !== 'access') throw new Error('type de jeton invalide');
  return { sub: payload.sub as string, did: payload.did as string };
}

export function verifyRefresh(token: string): TokenClaims & { jti: string } {
  const payload = jwt.verify(token, env.JWT_REFRESH_SECRET) as jwt.JwtPayload;
  if (payload.typ !== 'refresh') throw new Error('type de jeton invalide');
  return {
    sub: payload.sub as string,
    did: payload.did as string,
    jti: payload.jti as string,
  };
}

/** Les refresh tokens sont stockés hachés (SHA-256) — jamais en clair. */
export function hashToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}
