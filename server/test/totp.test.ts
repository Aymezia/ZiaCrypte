import { describe, expect, test } from 'vitest';
import {
  base32Decode,
  base32Encode,
  hotp,
  otpauthUri,
  totp,
  verifyTotp,
} from '../src/lib/totp.js';

/**
 * Vecteurs de test officiels de la RFC 6238 (Appendix B).
 *
 * Le secret est la chaîne ASCII "12345678901234567890" (20 octets). La RFC
 * donne des codes à 8 chiffres ; c'est le contrôle décisif : sans lui, une
 * erreur d'un octet dans la troncature dynamique produirait des codes
 * plausibles mais incompatibles avec toute application d'authentification.
 */
const RFC_SECRET = Buffer.from('12345678901234567890');
const RFC_VECTORS: Array<[number, string]> = [
  [59, '94287082'],
  [1111111109, '07081804'],
  [1111111111, '14050471'],
  [1234567890, '89005924'],
  [2000000000, '69279037'],
  [20000000000, '65353130'],
];

describe('TOTP — conformité RFC 6238', () => {
  test('reproduit les vecteurs de test officiels (8 chiffres)', () => {
    for (const [time, expected] of RFC_VECTORS) {
      expect(totp(RFC_SECRET, time, 8)).toBe(expected);
    }
  });

  test('les 6 derniers chiffres correspondent aux 6 chiffres standard', () => {
    // Un code à 6 chiffres est le code à 8 chiffres tronqué à droite : même
    // troncature dynamique, modulo différent.
    for (const [time] of RFC_VECTORS) {
      const eight = totp(RFC_SECRET, time, 8);
      const six = totp(RFC_SECRET, time, 6);
      expect(six).toBe(eight.slice(-6));
    }
  });

  test('HOTP suit RFC 4226 (compteur 0..9)', () => {
    // Vecteurs de la RFC 4226 Appendix D, même secret.
    const attendus = [
      '755224', '287082', '359152', '969429', '338314',
      '254676', '287922', '162583', '399871', '520489',
    ];
    for (let counter = 0; counter < attendus.length; counter++) {
      expect(hotp(RFC_SECRET, counter)).toBe(attendus[counter]);
    }
  });
});

describe('base32 (RFC 4648)', () => {
  test('aller-retour sur des octets arbitraires', () => {
    for (const s of ['', 'f', 'fo', 'foo', 'foob', 'fooba', 'foobar']) {
      const b = Buffer.from(s);
      expect(base32Decode(base32Encode(b))).toEqual(b);
    }
  });

  test('vecteurs RFC 4648', () => {
    expect(base32Encode(Buffer.from('foobar'))).toBe('MZXW6YTBOI');
    expect(base32Decode('MZXW6YTBOI').toString()).toBe('foobar');
  });
});

describe('vérification', () => {
  test('accepte le code courant', () => {
    const secret = base32Encode(RFC_SECRET);
    const now = 1111111111 * 1000;
    const code = totp(RFC_SECRET, 1111111111, 6);
    expect(verifyTotp(secret, code, now)).toBe(true);
  });

  test('tolère un décalage d’un pas, refuse au-delà', () => {
    const secret = base32Encode(RFC_SECRET);
    const base = 1111111111 * 1000;
    const code = totp(RFC_SECRET, 1111111111, 6);
    // ±30 s : toléré.
    expect(verifyTotp(secret, code, base + 30_000)).toBe(true);
    expect(verifyTotp(secret, code, base - 30_000)).toBe(true);
    // ±90 s : hors fenêtre.
    expect(verifyTotp(secret, code, base + 90_000)).toBe(false);
  });

  test('refuse un format invalide sans planter', () => {
    const secret = base32Encode(RFC_SECRET);
    for (const bad of ['', '123', 'abcdef', '1234567', '12 34 56']) {
      expect(verifyTotp(secret, bad)).toBe(false);
    }
  });
});

describe('URI otpauth', () => {
  test('contient le secret, l’émetteur et les paramètres', () => {
    const uri = otpauthUri('JBSWY3DPEHPK3PXP', 'alice');
    expect(uri).toContain('otpauth://totp/');
    expect(uri).toContain('secret=JBSWY3DPEHPK3PXP');
    expect(uri).toContain('issuer=ZiaCrypte');
    expect(uri).toContain('algorithm=SHA1');
  });
});
