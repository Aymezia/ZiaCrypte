# ZiaCrypte v0.12.0 — the conversation, refined

This release is all about the screen you actually look at. Reactions, a fix for messages that used to vanish when they failed to send, tappable links, sender names in groups, unread badges, and a scroll that no longer fights you.

## Downloads

| Asset | Platform |
|---|---|
| **`ziacrypte-android.apk`** | Android (arm64, arm32, x86_64) — enable "install from unknown sources" |
| **`ziacrypte-windows-x64-app.zip`** | Windows x64 — unzip, run `ziacrypte.exe` |
| **`ziacrypte-linux-x64.tar.gz`** | Linux x64 — `tar xzf … && cd linux-x64 && ./ziacrypte` |
| **`ziacrypte-macos-app.zip`** | macOS — unzip, right-click `ziacrypte.app` → Open (unsigned) |
| `zia_crypto_test.exe` | Standalone Windows verifier for the crypto engine |

Every asset is signed, and the application verifies the signature before installing an update.

## Reactions

Long-press a message to react — 👍 ❤️ 😂 😮 😢 🙏. Reactions travel through the encrypted channel like everything else: the server sees a blob, never an emoji. Tap a reaction to toggle your own; a small pill under the message shows the count and highlights the ones you added. (Channels stay one-way, so reactions don't apply there.)

## Messages no longer vanish when a send fails

Before, if a message failed to reach anyone — no network, server unreachable — it simply disappeared from the thread, as if you'd never written it. Now it stays, marked **"Non envoyé · réessayer"**, and a tap resends it. Nothing is silently lost.

## Smaller things that add up

- **Sender names in groups.** Received messages in a group now show who wrote them, each name in its own colour. No more guessing.
- **Unread badges.** The conversation list shows a count on anything you haven't opened, with the name in bold — a purely local marker, unrelated to read receipts.
- **A scroll that behaves.** Reading older messages no longer yanks you to the bottom every time something new arrives. A "jump to latest" button appears instead, lit when there's something new.
- **Tappable links.** URLs in messages are now clickable — after a confirmation, because opening a link tells that site your IP and the time you clicked. The full address is shown so you can spot a decoy.
- **A real empty state.** A new conversation greets you with a word about the encryption instead of a blank "no messages yet".

## Verified by actually running it

- Flutter suite **46 passed**
- Two-client integration against a dedicated server, all passed — including new end-to-end checks that a group message carries its author, that unread counts increment off-screen and clear on open, that a failed send stays and resends, and that a reaction crosses to the other side and toggles off
- Crypto engine suites **8/8**, and again under ASan + UBSan
