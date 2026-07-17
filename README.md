# ZiaCrypte

A secure, end-to-end encrypted messenger inspired by Signal, Session, and Matrix — built with a strict separation between cryptography, interface, and transport.

> **Status:** early development. The cryptographic engine is implemented and tested; the Flutter app and Node.js backend are scaffolded; the Dart FFI layer that connects them is the next milestone.

---

## Design principles

- **Zero-knowledge server.** The backend only relays opaque encrypted blobs. It never sees plaintext, and never holds a private key.
- **No home-made cryptography.** Every low-level primitive (X25519, Ed25519, HKDF, ChaCha20-Poly1305, CSPRNG) comes from [libsodium](https://libsodium.org). We implement only the *protocol* state machine (X3DH, Double Ratchet) on top of it — exactly as Signal and Matrix did.
- **Secrets live in C++ only.** Neither Dart nor JavaScript ever touches a long-term private key. All crypto crosses a clean FFI boundary into the native engine.
- **One codebase, five platforms.** The engine is portable C++20; the app is Flutter. Both target Android, iOS, Windows, macOS, and Linux.

---

## Architecture

Three independent modules communicate only through a shared wire contract:

```
┌─────────────────────────────┐        ┌──────────────────────────┐
│  Flutter app  (Dart)        │        │  Backend  (Node.js/TS)   │
│  UI · navigation · theming  │        │  accounts · presence     │
│  no cryptography at all     │        │  relays encrypted blobs  │
└──────────────┬──────────────┘        └────────────┬─────────────┘
               │ dart:ffi                            │ WSS / HTTPS
┌──────────────┴──────────────┐                      │ (protobuf / JSON)
│  Crypto Engine  (C++)       │                      │
│  libsodium · X3DH ·         │◄─── encrypted ──────┘
│  Double Ratchet · key store │     blobs only
└─────────────────────────────┘
```

| Module | Responsibility | Never does |
|--------|----------------|------------|
| `crypto-engine/` (C++) | Keys, X3DH, Double Ratchet, encryption, secure storage | — |
| `app/` (Flutter) | Interface, navigation, networking, local prefs | Any cryptography |
| `server/` (Node.js) | Accounts, auth, presence, blob relay, push | Decrypt anything |

---

## Security

- **X3DH** asynchronous key agreement (identity, signed prekey, one-time prekeys)
- **Double Ratchet** — forward secrecy and post-compromise security
- **Ed25519** signatures, **X25519** ECDH, **HKDF-SHA256** derivation
- **ChaCha20-Poly1305** authenticated encryption
- Out-of-order delivery via skipped-message keys (bounded, anti-DoS)
- Replay detection, strict signature verification
- Session state persisted **encrypted at rest** (`crypto_secretstream`) under a per-device master key held by the OS key store (Secret Service / Keychain / DPAPI / Android Keystore)
- Guarded, `mlock`ed, always-wiped secret buffers

---

## Repository layout

```
ziacrypte/
├── crypto-engine/     # C++ core — the only module that touches secrets
│   ├── include/zia/   #   public C ABI (zia_crypto.h)
│   ├── src/           #   primitives, identity, x3dh, ratchet, session, storage
│   ├── platform/      #   per-OS SecureKeyStore (linux/windows/apple/android)
│   ├── tests/         #   end-to-end conformance test
│   └── scripts/       #   reproducible cross-builds
├── app/               # Flutter application (Clean Architecture)
├── server/            # Node.js + TypeScript relay (Fastify, Prisma, PostgreSQL)
├── protocol/          # shared contract: .proto envelopes + OpenAPI spec
└── infra/             # Docker Compose, CI workflows
```

---

## Build & test the crypto engine

### Linux (system libsodium — quickest)

```bash
sudo apt install cmake ninja-build libsodium-dev libsecret-1-dev
cd crypto-engine
cmake --preset linux-system
cmake --build --preset linux-system
cd build/linux-system && ctest --output-on-failure
```

Expected: `100% tests passed`.

### Cross-platform (vcpkg)

Presets exist for `windows`, `macos`, `ios`, and `android-arm64` (see `CMakePresets.json`), each pulling libsodium through vcpkg. Configure with `-DCMAKE_TOOLCHAIN_FILE=<vcpkg>/scripts/buildsystems/vcpkg.cmake`.

### Windows binaries from Linux (MinGW)

```bash
sudo apt install mingw-w64 curl
./crypto-engine/scripts/build-windows-mingw.sh
# → dist/windows-x64/{zia_crypto.dll, libsodium-26.dll, zia_crypto_test.exe}
```

---

## Downloads

Prebuilt binaries are provided outside the git tree (source stays binary-free):

- **`ziacrypte-windows-x64.zip`** — Windows x64 engine + standalone conformance test. See [release notes](RELEASE_NOTES.md).

---

## Roadmap

| Phase | Scope | State |
|-------|-------|-------|
| 1–4 | Architecture, engine design, FFI contract, DB/API schema | ✅ |
| 5 | Project scaffolding | ✅ |
| 6 | Crypto engine implementation (X3DH + Double Ratchet) | ✅ tested |
| 7 | Secure storage + encrypted session persistence | ✅ tested |
| 8 | Cross-platform build + native key stores | ✅ Windows validated |
| 9 | Dart FFI layer (engine ↔ Flutter app) | ⏳ next |
| 10+ | Backend endpoints, real-time transport, UI, signing & store release | planned |

---

## License

Not yet chosen. Until a license is added, all rights are reserved by the author.
