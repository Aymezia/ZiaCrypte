import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';

/**
 * TOTP (RFC 6238) — second facteur d'authentification par code temporel.
 *
 * ## Où ça vit, et pourquoi
 *
 * Le TOTP est une protection de COMPTE, vérifiée côté serveur — au même titre
 * que le hachage Argon2 du mot de passe et les JWT, déjà en Node. Ce n'est pas
 * de la cryptographie de bout en bout : il ne touche aucune clé privée
 * d'utilisateur et ne chiffre aucun message. Il n'a donc rien à faire dans le
 * moteur natif ; le placer là compliquerait sans rien protéger de plus.
 *
 * ## Conformité
 *
 * L'algorithme suit RFC 6238 (TOTP) au-dessus de RFC 4226 (HOTP), en HMAC-SHA1,
 * ce que produisent Google Authenticator, Aegis, 1Password et les autres par
 * défaut. La conformité est verrouillée par les vecteurs de test officiels de
 * la RFC (voir totp.test.ts) : sans ce contrôle, un décalage d'un octet dans la
 * troncature dynamique donnerait des codes plausibles mais incompatibles avec
 * toutes les applications d'authentification.
 */

const DIGITS = 6;
const PERIOD_SECONDS = 30;
/** Tolérance : ±1 pas, pour absorber une horloge légèrement décalée. */
const WINDOW = 1;

// ---- Base32 (RFC 4648), l'encodage attendu par les applications TOTP ----

const B32_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

export function base32Encode(data: Buffer): string {
  let bits = 0;
  let value = 0;
  let out = '';
  for (const byte of data) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += B32_ALPHABET[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += B32_ALPHABET[(value << (5 - bits)) & 31];
  return out;
}

export function base32Decode(input: string): Buffer {
  const clean = input.toUpperCase().replace(/=+$/,'').replace(/\s/g, '');
  let bits = 0;
  let value = 0;
  const out: number[] = [];
  for (const ch of clean) {
    const idx = B32_ALPHABET.indexOf(ch);
    if (idx === -1) throw new Error('caractère base32 invalide');
    value = (value << 5) | idx;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return Buffer.from(out);
}

// ---- HOTP / TOTP ----

/** Un mot de passe à usage unique pour un compteur donné (RFC 4226). */
export function hotp(secret: Buffer, counter: number, digits = DIGITS): string {
  const buf = Buffer.alloc(8);
  // Compteur 64 bits en big-endian. On écrit les 32 bits de poids faible ;
  // les codes ne dépassent jamais 2^32 pas dans un usage réaliste.
  buf.writeUInt32BE(Math.floor(counter / 2 ** 32), 0);
  buf.writeUInt32BE(counter >>> 0, 4);

  const digest = createHmac('sha1', secret).update(buf).digest();

  // Troncature dynamique (RFC 4226 §5.3) : les 4 bits de poids faible du
  // dernier octet désignent l'offset des 4 octets à extraire.
  const offset = digest[digest.length - 1]! & 0x0f;
  const code =
    ((digest[offset]! & 0x7f) << 24) |
    ((digest[offset + 1]! & 0xff) << 16) |
    ((digest[offset + 2]! & 0xff) << 8) |
    (digest[offset + 3]! & 0xff);

  return (code % 10 ** digits).toString().padStart(digits, '0');
}

/** Le code TOTP attendu à un instant donné (secondes epoch). */
export function totp(secret: Buffer, atSeconds: number, digits = DIGITS): string {
  return hotp(secret, Math.floor(atSeconds / PERIOD_SECONDS), digits);
}

/**
 * Vérifie un code soumis, en tolérant ±WINDOW pas.
 *
 * Comparaison à temps constant : le temps de réponse ne doit pas révéler
 * combien de chiffres du code étaient corrects.
 */
export function verifyTotp(secretBase32: string, code: string, now = Date.now()): boolean {
  const cleaned = code.replace(/\s/g, '');
  if (!/^\d{6}$/.test(cleaned)) return false;

  const secret = base32Decode(secretBase32);
  const step = Math.floor(now / 1000 / PERIOD_SECONDS);
  const submitted = Buffer.from(cleaned);

  for (let w = -WINDOW; w <= WINDOW; w++) {
    const expected = Buffer.from(hotp(secret, step + w));
    if (expected.length === submitted.length && timingSafeEqual(expected, submitted)) {
      return true;
    }
  }
  return false;
}

/** Secret aléatoire de 160 bits (recommandation RFC 4226), en base32. */
export function generateSecret(): string {
  return base32Encode(randomBytes(20));
}

/** URI otpauth:// à encoder en QR pour l'enrôlement dans une application. */
export function otpauthUri(secretBase32: string, account: string, issuer = 'ZiaCrypte'): string {
  const label = encodeURIComponent(`${issuer}:${account}`);
  const params = new URLSearchParams({
    secret: secretBase32,
    issuer,
    algorithm: 'SHA1',
    digits: String(DIGITS),
    period: String(PERIOD_SECONDS),
  });
  return `otpauth://totp/${label}?${params.toString()}`;
}
