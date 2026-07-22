# ZiaCrypte

An end-to-end encrypted messenger — Signal-inspired, built from the primitive up, with a strict separation between cryptography, interface, and transport.

The server relays opaque blobs. It cannot read a message, and since sealed sender it often cannot tell who sent one either.

---

## Design principles

- **Zero-knowledge server.** The backend stores and forwards ciphertext. It never sees plaintext and never holds a private key. Message blobs are a delivery queue with a 30-day TTL, not a history store.
- **No home-made cryptography.** Every primitive comes from an audited library — [libsodium](https://libsodium.org) for X25519, Ed25519, HKDF, ChaCha20-Poly1305 and the CSPRNG, [liboqs](https://openquantumsafe.org) for ML-KEM-768. Only the *protocol* state machine (X3DH, PQXDH, Double Ratchet) is ours, exactly as Signal and Matrix did.
- **Secrets live in C++ only.** Neither Dart nor JavaScript ever touches a long-term private key. All cryptography crosses a clean FFI boundary into the native engine.
- **Metadata is treated as content.** Profile photos, group names, personal statuses, ephemeral-message settings and delivery tokens travel inside the encrypted channel rather than in a database column. Message sizes are padded to fixed buckets.
- **One codebase, five platforms.** The engine is portable C++20; the app is Flutter. Both target Android, iOS, Windows, macOS, and Linux.

---

## Architecture

```
┌─────────────────────────────┐        ┌──────────────────────────┐
│  Flutter app  (Dart)        │        │  Backend  (Node.js/TS)   │
│  UI · navigation · theming  │        │  accounts · presence     │
│  no cryptography at all     │        │  relays encrypted blobs  │
└──────────────┬──────────────┘        └────────────┬─────────────┘
               │ dart:ffi                           │ WSS / HTTPS
┌──────────────┴──────────────┐                     │
│  Crypto Engine  (C++)       │                     │
│  libsodium · liboqs · X3DH  │◄─── encrypted ──────┘
│  Double Ratchet · key store │     blobs only
└─────────────────────────────┘
```

| Module | Responsibility | Never does |
|--------|----------------|------------|
| `crypto-engine/` (C++) | Keys, PQXDH, Double Ratchet, sender keys, sealed sender, secure storage | — |
| `app/` (Flutter) | Interface, navigation, networking, local preferences | Any cryptography |
| `server/` (Node.js) | Accounts, auth, blob relay, presence, push, moderation | Decrypt anything |

---

## Security

**Key agreement and message encryption**

- **PQXDH** — hybrid key agreement. The shared secret is `HKDF(DH1‖DH2‖DH3‖DH4 ‖ SS)`, where `SS` comes from an ML-KEM-768 encapsulation. The post-quantum component is *added* to the Diffie-Hellman exchanges, never substituted for them: breaking ML-KEM leaves today's security intact, breaking X25519 leaves the post-quantum protection standing. The encapsulation key is signed by the identity key, and the KDF label differs between hybrid and classic mode, so a forced downgrade produces diverging secrets instead of succeeding silently.
- **Double Ratchet** — forward secrecy and post-compromise security, with a bounded skipped-key cache for out-of-order delivery, and replay rejection.
- **Sender keys** for groups: one encryption for N devices, each message signed so no member can write in another's name.
- **Sealed sender**: a delivery token lets a blob be deposited without authenticating, so the server learns neither the sender nor the conversation.
- **Ed25519** signatures, **X25519** ECDH, **HKDF-SHA256**, **ChaCha20-Poly1305**, and **XChaCha20-Poly1305** for data at rest.

**On the device**

- Session state, identity and local history are encrypted at rest (`crypto_secretstream`) under a per-device master key held by the OS key store — Secret Service, Keychain, DPAPI, or Android Keystore (through JNI, since the Keystore has no NDK C API).
- Guarded, `mlock`ed, always-wiped secret buffers.
- Optional app lock, screenshot blocking on Android, and an exportable passphrase-encrypted backup.

**Against the server**

- Identity pinning with safety numbers: a key substitution is surfaced, and an unresolved alert cancels the "verified" badge rather than reassuring on the wrong key.
- Message padding to 160-byte buckets, so a read receipt, a group key distribution and a short reply become indistinguishable by size.
- Presence is opt-in and only visible to people you already share a conversation with. There is no "last seen" timestamp — deliberately.
- Update packages are signed, and the app verifies the signature against a public key built into the binary.

---

## Repository layout

```
ziacrypte/
├── crypto-engine/     # C++ core — the only module that touches secrets
│   ├── include/zia/   #   public C ABI (zia_crypto.h)
│   ├── src/           #   primitives, identity, x3dh, ratchet, session, storage
│   ├── platform/      #   per-OS SecureKeyStore (linux/windows/apple/android)
│   ├── tests/         #   conformance, persistence, migration, backup, fuzzers
│   └── scripts/       #   reproducible cross-builds (MinGW, Android NDK)
├── app/               # Flutter application (Clean Architecture)
├── server/            # Node.js + TypeScript relay (Fastify, Prisma, PostgreSQL)
├── protocol/          # shared contract: .proto envelopes + OpenAPI spec
├── infra/             # Docker Compose, Nginx, CI workflows
├── e2e/               # pure-Dart client driving the real chain, end to end
├── docs/              # usage charter, data & retention, external storage
└── scripts/           # release, signing, test runners
```

---

## Build and test

### Crypto engine (Linux)

```bash
sudo apt install cmake ninja-build libsodium-dev libsecret-1-dev gnome-keyring dbus-x11

# liboqs is not packaged by any distribution yet — ML-KEM only, no OpenSSL.
git clone --depth 1 --branch 0.14.0 https://github.com/open-quantum-safe/liboqs.git /tmp/liboqs
cmake -S /tmp/liboqs -B /tmp/liboqs/build -GNinja -DCMAKE_BUILD_TYPE=Release \
      -DOQS_MINIMAL_BUILD=KEM_ml_kem_768 -DOQS_USE_OPENSSL=OFF \
      -DOQS_BUILD_ONLY_LIB=ON -DBUILD_SHARED_LIBS=OFF
sudo cmake --build /tmp/liboqs/build --target install

cd crypto-engine
cmake --preset linux-system -DZIA_BUILD_TESTS=ON
cmake --build build/linux-system
dbus-run-session -- bash -c \
  'echo "" | gnome-keyring-daemon --unlock --components=secrets >/dev/null 2>&1
   ctest --test-dir build/linux-system --output-on-failure'
```

The keyring session is required: the suite exercises the real `SecureKeyStore`, not a stub. A sanitizer preset (`linux-sanitizers`, ASan + UBSan) and a libFuzzer preset (`linux-fuzz`) are also defined.

### Server

```bash
cd server
npm ci
npx prisma db push          # needs DATABASE_URL
npm test                    # integration suite against a real PostgreSQL
```

### App

```bash
cd app && flutter pub get
./scripts/run-app-tests.sh          # unit + widget + FFI against the real engine
./scripts/run-integration-tests.sh  # two real clients against a dedicated server
```

### Cross-builds

```bash
./crypto-engine/scripts/build-windows-mingw.sh   # → dist/windows-x64/
ANDROID_NDK_HOME=... ./crypto-engine/scripts/build-android.sh
```

Both link libsodium and liboqs statically, so the artefacts stay self-contained. The Windows build is verifiable from Linux: `wine dist/windows-x64/zia_crypto_test.exe` runs the full conformance suite.

---

## Releases

Signed artefacts are published on GitHub Releases: Android APK, Windows, Linux and macOS application bundles, plus a standalone conformance-test binary for the engine.

`scripts/release.sh` builds the local targets, waits for CI to produce the ones that need Windows and macOS runners, signs all of them in one pass, and publishes only once the set is complete — never half a release. The signing key never touches a CI runner. The application checks for updates against these releases and verifies the signature before installing anything.

---

## Roadmap

| Phase | Scope | State |
|-------|-------|-------|
| 1–5 | Architecture, engine design, FFI contract, DB/API schema, scaffolding | ✅ |
| 6–9 | X3DH + Double Ratchet, secure storage, cross-platform builds, Dart FFI | ✅ tested |
| 10–20 | Backend, Flutter app, real-time transport, attachments, groups | ✅ |
| 21–31 | Voice messages, media, profile photos, backups, linked devices, updates | ✅ |
| 32–36 | Exportable backup, app lock, ephemeral messages, blocking, moderation | ✅ |
| 37 | Sender keys — one group message for N devices | ✅ tested |
| 38 | Presence and personal status | ✅ tested |
| 39 | Message padding ✅ · PQXDH in the engine ✅ · PQXDH over the wire | in progress |
| next | Key transparency · encrypted calls | planned |

Post-quantum key agreement is implemented and tested in the engine, but is **not yet active on the wire**: the server does not relay the encapsulation key, so sessions still negotiate classic X3DH. That fallback is deliberate and tested — it is what keeps already-installed clients working during the migration.

---

## License

Not yet chosen. Until a license is added, all rights are reserved by the author.
