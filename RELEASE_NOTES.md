# ZiaCrypte v0.11.0 — broadcast channels, and a fix that lets Android start

The headline is channels: a one-to-many feed where you publish and subscribers read — end-to-end encrypted, like everything else here. And a fix without which the Android app of the previous release simply would not start.

## Downloads

| Asset | Platform |
|---|---|
| **`ziacrypte-android.apk`** | Android (arm64, arm32, x86_64) — enable "install from unknown sources" |
| **`ziacrypte-windows-x64-app.zip`** | Windows x64 — unzip, run `ziacrypte.exe` |
| **`ziacrypte-linux-x64.tar.gz`** | Linux x64 — `tar xzf … && cd linux-x64 && ./ziacrypte` |
| **`ziacrypte-macos-app.zip`** | macOS — unzip, right-click `ziacrypte.app` → Open (unsigned) |
| `zia_crypto_test.exe` | Standalone Windows verifier for the crypto engine |

Every asset is signed, and the application verifies the signature before installing an update.

## Android now starts

The v0.10.0 APK crashed at launch — `dlopen failed: library "libc++_shared.so" not found`. The native engine was linked against the shared C++ runtime, which wasn't bundled. The bug hid this long because Android had only ever been compiled and symbol-checked, never run on a device. The runtime is now linked statically into the engine; it exposes a pure C interface, so nothing is lost. Verified: the dependency is gone from the `.so` inside the final APK, on all three ABIs.

## Broadcast channels

A channel is a one-to-many feed: an admin publishes, subscribers read. It stays end-to-end encrypted — which is the hard part, because a public feed and secrecy pull against each other. The way they're squared here: **the invite link carries the key.**

- **The link is the key.** A channel's read key is sealed under a secret that lives only in the invite link, after the `#` — a URL fragment never reaches the server. Whoever holds the link can read; the server, which stores only the sealed blob, cannot. The channel's name travels in the link too, so even that stays off the server.
- **Only the admin can publish.** Not because a rule says so, but because the cryptography enforces it: subscribers receive the *read* key, never the signing key. A message a subscriber tried to forge would be rejected by everyone else's client.
- **The tradeoff, stated plainly.** For a channel, the server sees the list of subscribed devices — it has to know where to copy a post. That's inherent to an open, link-joinable feed, and it's a different bargain from private conversations, which keep sender anonymity. The *content* stays secret either way.

To use it: the **+** menu offers *Channel* (create one, then share the link it gives you) and *Join a channel* (paste a link). An admin's channel shows a composer; a subscriber's shows a read-only banner.

Two current limits worth knowing: removing a subscriber doesn't yet rotate the key automatically (until the admin rotates it, a removed subscriber can still read), and channels are text-only for now.

## Under the hood

Post-quantum key agreement (PQXDH, X25519 + ML-KEM-768) remains implemented in the engine and still not active on the wire — the groundwork is in place for a later release to switch it on without a migration.

## Verified by actually running it

- Engine suites: **8/8**, including the six PQXDH checks and six new channel checks, and again under ASan + UBSan
- The same engine cross-compiled for Windows: **12/12** under wine
- Flutter suite **46 passed**; two-client integration (channels, groups, presence, status) against a dedicated server: all passed
- Backend suite against a real PostgreSQL: **61 passed**
- The channel's content was checked absent from the database: zero plaintext in channel blobs
