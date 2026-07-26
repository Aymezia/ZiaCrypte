# ZiaCrypte v0.12.1 — three fixes

A small patch over v0.12.0, fixing three bugs — one of them affecting everyone.

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

- **No more disconnects after 15 minutes.** The access token expires every 15 minutes, and the app never used the refresh token to renew it — so past that point it looked disconnected, every request failing while the session was still valid. It now renews the token automatically and transparently on the first expired request.
- **A missing file no longer crashes the app.** Sending a voice message whose recording didn't complete (microphone denied, for instance), or an attachment that had moved, read a file that wasn't there and threw an uncaught error — the red screen. It now shows a message and cancels the send.
- **The message thread no longer errors when you scroll up.** A new message arriving while you were reading older ones could trigger an internal error. Fixed.

## Verified by actually running it

- Flutter suite **46 passed**
- Two-client integration against a dedicated server, all passed — including a new check that an expired access token is renewed and the request still succeeds, and that a failed send stays and can be retried
