# ZiaCrypte v0.14.1 — the call button, everywhere it should be

A quick fix over v0.14.0: on a wide window (desktop), the call button was missing — so you couldn't start a call at all. It's back, plus two robustness fixes for connectivity.

## Downloads

| Asset | Platform |
|---|---|
| **`ziacrypte-android.apk`** | Android (arm64, arm32, x86_64) — enable "install from unknown sources" |
| **`ziacrypte-windows-x64-app.zip`** | Windows x64 — unzip, run `ziacrypte.exe` |
| **`ziacrypte-linux-x64.tar.gz`** | Linux x64 — `tar xzf … && cd linux-x64 && ./ziacrypte` |
| **`ziacrypte-macos-app.zip`** | macOS — unzip, right-click `ziacrypte.app` → Open (unsigned) |
| `zia_crypto_test.exe` | Standalone Windows verifier for the crypto engine |

Every asset is signed, and the application verifies the signature before installing an update.

## Fixes

- **The call button now shows on desktop.** In the wide, two-pane layout (Windows, macOS, Linux, and tablets), the phone button was absent from the conversation header — calls were impossible to start there. It's now in both layouts.
- **Calls connect more reliably.** ICE candidates that arrived before the other side had picked up were being dropped; with relay-only calls there may be just one, so losing it meant the call never connected. They're now held and replayed once the call is answered.
- **A failed start no longer fails silently.** If fetching the relay credentials errors out (network, expired token), the call now shows why instead of doing nothing when you tap.

## Verified by actually running it

- Flutter suite **46 passed**; server suite **68 passed** (incl. TURN credentials and signaling relay)
- The full call signaling path — ring, accept, hang up — proven end to end between two clients
