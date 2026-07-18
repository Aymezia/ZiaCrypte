# ZiaCrypte v0.2.0 — the desktop app works

First release of the **working application**, not just the engine: a Linux desktop client that registers, performs an X3DH handshake and exchanges Double Ratchet–encrypted messages through the relay server.

## Downloads

| Asset | What it is |
|---|---|
| **`ziacrypte-linux-x64.tar.gz`** | The desktop application for Linux x64. libsodium is linked statically — nothing to install. |
| `zia_crypto_test.exe` | Standalone Windows verifier for the crypto engine (single file). |
| `ziacrypte-windows-x64.zip` | Windows engine library + verifier. |

## Run it

```bash
tar xzf ziacrypte-linux-x64.tar.gz
cd linux-x64
./ziacrypte
```

You also need a server:

```bash
cd server
cp .env.example .env      # set DATABASE_URL and the JWT secrets
npx prisma db push
npx tsx src/index.ts      # listens on 3210
```

In the app: enter the server address, pick a username and password, create your account, then type a peer's username to start a conversation.

## What's in this release

**Backend (Node.js + Fastify + Prisma + PostgreSQL)**
- Accounts and authentication: Argon2id passwords, JWT access tokens, refresh tokens stored hashed with rotation and replay rejection
- Devices and prekeys: multi-device registration, prekey upload, X3DH bundle distribution with one-time prekey consumption
- Conversations and an encrypted blob relay with idempotent deduplication
- User lookup

**Desktop application (Flutter)**
- Connection screen and conversation screen, Material 3, light and dark themes
- Talks to the native engine through the Dart FFI layer; a dedicated isolate serialises every native call
- The X3DH handshake material rides along with the first message of a session

## Verified, not assumed

- Crypto engine conformance: X3DH, Double Ratchet, out-of-order delivery, replay rejection, tampering rejection, encrypted session persistence
- Full-chain assembly test (`e2e/`): C++ engine ↔ Dart client ↔ Fastify ↔ PostgreSQL — **7/7**
- The application was **actually launched and driven**: account created (confirmed in the database), handshake completed, an encrypted message sent from the UI and decrypted by a peer
- **The server stores no plaintext** — verified by SQL against the message table: zero occurrences

## Known limitations

- **Device identity is not persisted between launches.** The engine generates fresh keys at startup, so the app registers a new account each time it starts. Persisting identity through the OS key store is next.
- Real-time delivery uses polling every 2 seconds; a WebSocket gateway is planned.
- Windows and macOS desktop builds of the application are not published yet — only the engine is built for Windows.

## Security

Every cryptographic primitive comes from [libsodium](https://libsodium.org). Only the X3DH and Double Ratchet protocol logic is implemented here, following the published Signal specifications. No key is ever written in plaintext, and the server never holds one.
