# ZiaCrypte v0.10.0 — presence, personal status, and message padding

Three visible additions, one invisible. The visible ones: you can see when a correspondent is online, and write a status about yourself — both without telling the server anything new. The invisible one: every message now leaves at a fixed size.

## Downloads

| Asset | Platform |
|---|---|
| **`ziacrypte-android.apk`** | Android (arm64, arm32, x86_64) — enable "install from unknown sources" |
| **`ziacrypte-windows-x64-app.zip`** | Windows x64 — unzip, run `ziacrypte.exe` |
| **`ziacrypte-linux-x64.tar.gz`** | Linux x64 — `tar xzf … && cd linux-x64 && ./ziacrypte` |
| **`ziacrypte-macos-app.zip`** | macOS — unzip, right-click `ziacrypte.app` → Open (unsigned) |
| `zia_crypto_test.exe` | Standalone Windows verifier for the crypto engine |

Every asset is signed, and the application verifies the signature before installing an update.

## Online presence — opt-in, and only for people you talk to

A dot next to a correspondent tells you they are reachable. Two locks make that safe:

- **Nothing is broadcast until you ask for it.** Sharing your presence is off by default, exactly like read receipts. The hour at which you open a messenger says when you sleep and when you work — nobody should give that away without choosing to. Clients that predate the feature stay silent on their own.
- **You can only watch devices you already share a conversation with**, never across a block. Blocking someone cuts presence both ways, immediately, without waiting for a reconnection.

There is **no "last seen at"**. A coarse online/offline dot is a convenience; a timestamped history of connections is a sleep diary. You can also watch others without showing yourself — the reciprocity other messengers impose is a politeness rule, not a security one.

The server learns nothing new here: it holds the WebSocket, so it already knew who was connected. What changes is what *other people* learn, which is why the whole feature is built around consent.

## Personal status

A sentence about yourself — "Available", "In a meeting". It does **not** go into a column next to your username, where the host could read it. It travels through the encrypted channel, like profile photos and ephemeral-message settings, and is kept in the engine's encrypted vault.

A phrase people write about themselves often says more than an address book: "in hospital until Friday", "new number", a first name, a town. The consequence is assumed: only people you have an open conversation with see your status.

## Message padding

The server cannot decrypt anything, and since sealed sender it often cannot tell who is writing to whom. It could still see one thing — **the size of every blob**. A read receipt, a group key distribution and a short "ok" each have a characteristic length, and the sequence of sizes draws the shape of a conversation.

Messages are now padded to 160-byte buckets before encryption, control messages included. Measured over a full two-client test run — messages, statuses, control traffic, a group message — the database ended up holding exactly **two distinct ciphertext sizes** instead of one per message. The overhead is bounded at 159 bytes, whatever the message.

The padding is made of spaces rather than the usual `0x80`-and-zeros: the payload is JSON, trailing whitespace is legal there, so clients from previous versions read padded messages correctly without knowing anything about padding. No negotiation, no wire-format change.

## Under the hood: post-quantum groundwork

The engine now implements **PQXDH**, hybrid key agreement combining X25519 with ML-KEM-768 (FIPS 203, via liboqs). What is captured today becomes decryptable the day a quantum machine exists; the post-quantum component is *added* to the Diffie-Hellman exchanges rather than replacing any of them, so breaking ML-KEM leaves today's security intact, and breaking X25519 leaves the post-quantum protection standing.

**It is not active on the wire yet.** The server does not relay the encapsulation key, so sessions still negotiate classic X3DH. This release puts the machinery in place — including a device identity format that can carry post-quantum keys — so the next one can switch it on without a migration. The fallback path is deliberate and tested: it is what keeps already-installed clients working.

## Verified by actually running it

- Engine suites: **7/7**, including six new PQXDH checks, and again under ASan + UBSan
- The same engine cross-compiled for Windows: **12/12** under wine
- Flutter suite: **46 passed**; two-client integration against a dedicated server: all passed
- Backend suite against a real PostgreSQL: **54 passed**

One finding worth recording: the engine's presets build in `Release`, so `NDEBUG` was erasing every `assert()` in the test suite. The binaries ran, printed their "[OK]" lines, and verified nothing beyond the absence of a crash. `NDEBUG` is now stripped from test targets, and the suites pass with their checks genuinely enforced.
