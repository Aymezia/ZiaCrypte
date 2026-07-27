# ZiaCrypte v0.13.0 — polish across the app

An interface pass: the entry screen, the profile, the channels, and the small motion that makes a conversation feel alive.

## Downloads

| Asset | Platform |
|---|---|
| **`ziacrypte-android.apk`** | Android (arm64, arm32, x86_64) — enable "install from unknown sources" |
| **`ziacrypte-windows-x64-app.zip`** | Windows x64 — unzip, run `ziacrypte.exe` |
| **`ziacrypte-linux-x64.tar.gz`** | Linux x64 — `tar xzf … && cd linux-x64 && ./ziacrypte` |
| **`ziacrypte-macos-app.zip`** | macOS — unzip, right-click `ziacrypte.app` → Open (unsigned) |
| `zia_crypto_test.exe` | Standalone Windows verifier for the crypto engine |

Every asset is signed, and the application verifies the signature before installing an update.

## Sign-in screen

- **Show/hide the password.** No more typing blind — the eye reveals it, the top cause of failed sign-ins on mobile.
- **A password-strength gauge** when creating an account, guiding toward something solid without ever blocking you.
- The first field gets focus automatically: the username when creating, the password when returning.

## Profile

The settings screen opens on a real **profile header** now — a large avatar you tap to change, your username, and a status you edit in one tap — instead of the same things scattered as rows down a flat list. Photo and status stay encrypted; the server never sees them.

## Channels

- The header shows the **subscriber count**.
- Admins get **"Renew the key"**, which is what actually removes someone: it mints a fresh read key and retires the old invite link, so anyone you unsubscribed can no longer read. The trade-off is stated up front — you re-share the new link with those who stay, since with channels the link *is* the key.

## A little motion

New messages now **fade and slide in**. Deliberately restrained: only the latest message animates, and only when it has just arrived — the history you scroll through never flickers.

## Verified by actually running it

- Flutter suite **46 passed**
- Two-client integration against a dedicated server, all passed — including a new check that renewing a channel's key locks out the old invite link
- Crypto engine suites **8/8**, and again under ASan + UBSan
