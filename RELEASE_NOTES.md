# ZiaCrypte v0.14.0 — encrypted voice calls

You can now call the people you talk to — and the call is end-to-end encrypted, like everything else here.

## Downloads

| Asset | Platform |
|---|---|
| **`ziacrypte-android.apk`** | Android (arm64, arm32, x86_64) — enable "install from unknown sources" |
| **`ziacrypte-windows-x64-app.zip`** | Windows x64 — unzip, run `ziacrypte.exe` |
| **`ziacrypte-linux-x64.tar.gz`** | Linux x64 — `tar xzf … && cd linux-x64 && ./ziacrypte` |
| **`ziacrypte-macos-app.zip`** | macOS — unzip, right-click `ziacrypte.app` → Open (unsigned) |
| `zia_crypto_test.exe` | Standalone Windows verifier for the crypto engine |

Every asset is signed, and the application verifies the signature before installing an update.

## Voice calls

A phone button in any direct conversation starts a call. When it connects, an in-call screen shows who you're talking to, a mute button, and hang up. An incoming call takes over the whole screen so you can't miss it.

What makes it ours:

- **The audio is end-to-end encrypted** (WebRTC's DTLS-SRTP), between the two devices. The server can't listen.
- **No one learns the other's IP.** Calls are relayed through a TURN server, always — so the two ends never see each other's address. The relay carries the encrypted audio but cannot open it.
- **No one can wedge into the call.** The WebRTC handshake fingerprint travels inside our own encrypted, authenticated channel (the Double Ratchet). A server that tried to substitute it would be caught — there's no man in the middle.

Calls work between people who already have a conversation. Group calls aren't here yet; this is one-to-one.

## For the operator

Voice calls need a **TURN relay** (coturn) running alongside the server — see [`docs/appels-turn.md`](docs/appels-turn.md) for the deployment steps. Until it's up, the call button politely says calls aren't available; nothing else is affected. On iOS, ringing while the app is closed still waits on APNs (not yet implemented); Android rings via the existing push wake.

## Verified by actually running it

- Two-client integration against a dedicated server: call signaling — ring, accept, hang up — travels encrypted and drives the call state end to end
- Server suite against a real PostgreSQL: **68 passed**, including the TURN-credential endpoint (short-lived HMAC credentials) and the signaling relay (opaque, block-aware)
- Flutter suite **46 passed**; crypto engine **8/8**, and again under ASan + UBSan

The download is larger than before (the WebRTC media library is bundled).
