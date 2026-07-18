# ZiaCrypte v0.3.0 — rien à configurer, serveur en HTTPS

The application now ships with its server address built in: download, launch, pick a username, and you are chatting. The relay runs behind HTTPS with a real certificate.

## Downloads

| Asset | Platform |
|---|---|
| **`ziacrypte-windows-x64-app.zip`** | Windows x64 — unzip, run `ziacrypte.exe` |
| **`ziacrypte-linux-x64.tar.gz`** | Linux x64 — `tar xzf … && cd linux-x64 && ./ziacrypte` |
| **`ziacrypte-macos-app.zip`** | macOS — unzip, right-click `ziacrypte.app` → Open (unsigned) |
| `zia_crypto_test.exe` | Standalone Windows verifier for the crypto engine |

No server address to type, no dependency to install: libsodium and the C++ runtime are linked statically into the engine.

## Fixed since v0.2.1

**The Windows application could not start** (`error code 126`). The engine DLL built on the Windows runner depended on `libgcc_s_seh-1.dll` and `libstdc++-6.dll`, which are not present on a normal Windows machine. The engine is now cross-compiled with everything linked statically, and CI **fails the build** if any non-system dependency reappears.

## Infrastructure

The relay is reachable at `https://51.83.199.103.nip.io`:

- nginx terminates TLS on 443 with a Let's Encrypt certificate (auto-renewing)
- The application server listens on `127.0.0.1` only — it is not directly reachable from the internet
- HTTP redirects to HTTPS

Passwords and session tokens are therefore encrypted in transit, on top of the end-to-end encryption that already protects message content.

Note: embedding the address in the binary is a convenience, not a secret — it is readable with `strings` and visible in network traffic.

## What is verified, and what is not

**Verified by actually running it**
- Crypto engine conformance on Linux and Windows: X3DH, Double Ratchet, out-of-order delivery, replay and tamper rejection, encrypted session persistence
- Full-chain assembly (`e2e/`): C++ engine ↔ Dart client ↔ Fastify ↔ PostgreSQL — 7/7
- **The Linux application was launched and driven**, including against the public HTTPS endpoint: account created (confirmed in the database), X3DH handshake, an encrypted message sent from the UI and decrypted by a peer
- The server stores no plaintext — verified by SQL against the message table

**Built and checked, but never launched**
- The **Windows** and **macOS** applications are built by CI on their own runners, and their packages are verified to contain a self-contained engine. No Windows or macOS machine was available to run them.

## Known limitations

- **Device identity is not persisted between launches.** The engine generates fresh keys at startup, so the app registers a new account each time it starts. Persisting identity through the OS key store is the next milestone.
- Real-time delivery uses polling every 2 seconds; a WebSocket gateway is planned.
- Windows and macOS builds are unsigned, so both systems warn on first launch.
- iOS and Android are scaffolded but not published. iOS requires an Apple Developer account for signing and installation.

## Security

Every cryptographic primitive comes from [libsodium](https://libsodium.org). Only the X3DH and Double Ratchet protocol logic is implemented here, following the published Signal specifications. No key is ever written in plaintext, and the server never holds one.
