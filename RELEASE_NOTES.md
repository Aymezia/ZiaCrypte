# ZiaCrypte v0.4.0 — your account survives a restart

Until now the application generated fresh keys at every launch, which meant a brand-new account each time. That is fixed: your device identity is stored encrypted, and the app reconnects to your account with just your password.

## Downloads

| Asset | Platform |
|---|---|
| **`ziacrypte-windows-x64-app.zip`** | Windows x64 — unzip, run `ziacrypte.exe` |
| **`ziacrypte-linux-x64.tar.gz`** | Linux x64 — `tar xzf … && cd linux-x64 && ./ziacrypte` |
| **`ziacrypte-macos-app.zip`** | macOS — unzip, right-click `ziacrypte.app` → Open (unsigned) |
| `zia_crypto_test.exe` | Standalone Windows verifier for the crypto engine |

Nothing to configure: the server address is built in, and libsodium is linked statically.

## What changed

**Identity persistence.** The engine now writes its identity — Ed25519 identity key, signed prekey, one-time prekeys — to `identity.zia`, encrypted with `crypto_secretstream_xchacha20poly1305` under a master key held by the operating system key store (Secret Service on Linux, DPAPI on Windows, Keychain on macOS). It reloads that identity on startup.

Writes are atomic (temporary file then rename), and reads are bounds-checked so a corrupted file fails cleanly instead of being trusted.

**Reconnection.** The application remembers which account belongs to this device (username and identifiers — no secrets) and asks only for your password on the next launch. "Use a different account" is available if you want to start over.

**Degraded, not broken.** If no key store is available (headless session, container, test), the identity still works for the current session; it simply will not be reloaded next time. The failure is recorded in `zia_last_error()`. Refusing to run at all would have made the engine unusable in those environments.

## Verified by actually running it

- New C++ persistence test: identity survives an engine restart, the signed prekey and its signature stay valid, regeneration is refused, and a different storage path yields a different identity
- Engine conformance and persistence suites: **2/2**
- Flutter suite (widget + FFI against the real engine): **5/5**
- **End-to-end on the real application**: an account was created through the interface, the application was closed, relaunched, and reconnected with only a password. The database confirms **two sessions for a single device** — the identity was reused, no account was recreated
- `identity.zia` was inspected on disk: opaque ciphertext, no key in the clear

## Known limitations

- The **Windows** and **macOS** applications are built by CI and their packages verified, but never launched — no such machine was available. Only Linux was exercised end to end.
- Real-time delivery uses polling every 2 seconds; a WebSocket gateway is planned.
- Windows and macOS builds are unsigned, so both systems warn on first launch.
- iOS and Android are scaffolded but not published. iOS requires an Apple Developer account for signing and installation.
- Message history is not stored locally yet: only the identity and account are persisted.

## Security

Every cryptographic primitive comes from [libsodium](https://libsodium.org). Only the X3DH and Double Ratchet protocol logic is implemented here, following the published Signal specifications. Private keys never touch the disk unencrypted, and the server never holds one. The relay is reachable over HTTPS with a Let's Encrypt certificate.
