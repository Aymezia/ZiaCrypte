# ZiaCrypte v0.5.0 — history, real-time delivery, and Android

Three things this release makes usable: your conversations survive a restart, messages arrive instantly instead of on a timer, and there is now an Android build.

## Downloads

| Asset | Platform |
|---|---|
| **`ziacrypte-android.apk`** | Android (arm64, arm32, x86_64) — enable "install from unknown sources" |
| **`ziacrypte-windows-x64-app.zip`** | Windows x64 — unzip, run `ziacrypte.exe` |
| **`ziacrypte-linux-x64.tar.gz`** | Linux x64 — `tar xzf … && cd linux-x64 && ./ziacrypte` |
| **`ziacrypte-macos-app.zip`** | macOS — unzip, right-click `ziacrypte.app` → Open (unsigned) |
| `zia_crypto_test.exe` | Standalone Windows verifier for the crypto engine |

Nothing to configure: the server address is built in and the relay runs over HTTPS.

## Conversation history, encrypted locally

The engine gained a general-purpose local vault: arbitrary data encrypted with `crypto_secretstream_xchacha20poly1305` under the device master key held by the OS key store. Writes are atomic and entry names are validated, so a caller cannot escape the vault directory.

The application keeps each conversation's history there. Two backend fixes were needed to make it work for both correspondents: a direct conversation between two people is now unique (its identifier changed on every open before, orphaning the stored history), and received messages carry the sender's username so the recipient knows who is writing.

## Real-time delivery

A WebSocket gateway notifies a device that a blob is waiting; the client then fetches it immediately. **The WebSocket carries no content** — only a signal — and delivery never depends on it: the periodic fetch remains as a safety net (now every 15 s), with automatic reconnection. Authentication happens at the handshake, and nginx relays the upgrade over TLS.

## Android

The engine is cross-compiled with the NDK for three ABIs with libsodium linked statically. Since the Android Keystore has no C API, the native backend reaches `com.ziacrypte.KeyStoreBridge` through JNI: a non-exportable AES key in the hardware Keystore wraps the 32-byte master key.

Two traps were found and fixed along the way:

- `FindClass` from a secondary thread cannot see application classes (wrong class loader). The class is now cached as a global reference in `JNI_OnLoad`.
- **R8 was renaming that class**, which would have made the native lookup fail silently at runtime — persistence would have broken with no error. This was caught by inspecting the DEX of the first APK, where every class had been obfuscated. Keep rules now preserve it, confirmed in the final DEX.

## Verified by actually running it

- Engine suites (conformance + persistence, including vault checks): **2/2**
- Flutter suite (widget + FFI against the real engine): **5/5**
- Backend integration suite against a real PostgreSQL: **1/1**
- **History**: two messages sent from the interface, application closed, relaunched, history restored — and the vault file on disk contains no readable text
- **Real-time**: an auto-replying peer answered and the reply appeared in the application in under 2.5 s, well before the 15 s periodic fetch
- **Android APK**: contents verified — native libraries for all three ABIs, INTERNET permission, and the JNI bridge with its five methods intact after R8

## Known limitations

- The **Android, Windows and macOS** applications are built and their packages verified, but **never launched** — no such device was available here. Only Linux was exercised end to end.
- The APK is signed with a debug key; Android will warn on install.
- Windows and macOS builds are unsigned.
- Message history is kept per device: a new device starts with an empty history.
- iOS is scaffolded but not published; it requires an Apple Developer account for signing and installation.

## Security

Every cryptographic primitive comes from [libsodium](https://libsodium.org). Only the X3DH and Double Ratchet protocol logic is implemented here, following the published Signal specifications. Private keys and conversation history never touch the disk unencrypted, and the server never holds a key nor sees a plaintext.
