/** Erreur HTTP applicative — mappée en réponse par le gestionnaire global. */
export class HttpError extends Error {
  constructor(
    public readonly statusCode: number,
    message: string,
  ) {
    super(message);
  }
}

/**
 * Décode une clé publique base64 et vérifie sa longueur (jamais un secret).
 * Renvoie un Uint8Array adossé à un ArrayBuffer (type attendu par Prisma Bytes).
 */
export function decodeKey(
  b64: string,
  expectedLen: number,
  field: string,
): Uint8Array<ArrayBuffer> {
  const buf = Buffer.from(b64, 'base64');
  if (buf.length !== expectedLen) {
    throw new HttpError(400, `${field} : longueur invalide (attendu ${expectedLen} octets)`);
  }
  const out = new Uint8Array(expectedLen); // adossé à un ArrayBuffer frais
  out.set(buf);
  return out;
}

export const PUBLIC_KEY_LEN = 32;
export const SIGNATURE_LEN = 64;
