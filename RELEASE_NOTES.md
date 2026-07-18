# ZiaCrypte v0.2.1 — desktop apps for Linux, Windows and macOS

The messaging application, now built for the three desktop platforms. Same encrypted core everywhere: keys are generated and held by the native C++ engine, and the server only ever relays opaque ciphertext.

## Downloads

| Asset | Platform |
|---|---|
| **`ziacrypte-linux-x64.tar.gz`** | Linux x64 desktop app (libsodium linked statically — nothing to install) |
| **`ziacrypte-windows-x64-app.zip`** | Windows x64 desktop app (includes `zia_crypto.dll` + `libsodium.dll`) |
| **`ziacrypte-macos-app.zip`** | macOS desktop app (`.app` bundle with the engine in `Contents/Frameworks`) |
| `zia_crypto_test.exe` | Standalone Windows verifier for the crypto engine |

## Run it

**Linux** — `tar xzf ziacrypte-linux-x64.tar.gz && cd linux-x64 && ./ziacrypte`
**Windows** — unzip, keep all files together, run `ziacrypte.exe`
**macOS** — unzip and open `ziacrypte.app` (unsigned: right-click → Open the first time)

You also need a server:

```bash
cd server
cp .env.example .env      # set DATABASE_URL and the JWT secrets
npx prisma db push
npx tsx src/index.ts      # listens on 3210
```

In the app: enter the server address, create an account, then type a peer's username to start a conversation.

## What is verified, and what is not

Being precise about this matters more than sounding confident.

**Verified by actually running it**
- Crypto engine conformance on Linux and Windows: X3DH, Double Ratchet, out-of-order delivery, replay rejection, tamper rejection, encrypted session persistence
- Full-chain assembly (`e2e/`): C++ engine ↔ Dart client ↔ Fastify ↔ PostgreSQL — 7/7
- **The Linux application was launched and driven**: account created (confirmed in the database), X3DH handshake, an encrypted message sent from the UI and decrypted by a peer
- The server stores no plaintext — verified by SQL against the message table

**Built but not run**
- The **Windows** and **macOS** applications are compiled by CI on their own runners, and the packages are checked to contain the engine and its dependencies. They have **not been launched** — no Windows or macOS machine was available. The engine DLL is MSVC-built and exports the full API.

## Known limitations

- **Device identity is not persisted between launches.** The engine generates fresh keys at startup, so the app registers a new account each time. Persisting identity through the OS key store is next.
- Real-time delivery uses polling every 2 seconds; a WebSocket gateway is planned.
- iOS and Android are scaffolded but not built or published yet. iOS additionally requires an Apple Developer account for signing and installation.
- macOS and Windows builds are unsigned, so both systems will warn on first launch.

## Security

Every cryptographic primitive comes from [libsodium](https://libsodium.org). Only the X3DH and Double Ratchet protocol logic is implemented here, following the published Signal specifications. No key is ever written in plaintext, and the server never holds one.
