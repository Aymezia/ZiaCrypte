# ZiaCrypte Crypto Engine — v0.1.0 (Windows x64)

First public build of the ZiaCrypte cryptographic engine for Windows, with a standalone conformance test you can run directly.

## Download

**`ziacrypte-windows-x64.zip`**

| File | Description |
|------|-------------|
| `zia_crypto.dll` | The engine — X3DH + Double Ratchet over libsodium, with the Windows DPAPI key store built in |
| `libsodium-26.dll` | Runtime dependency (keep it next to the other files) |
| `zia_crypto_test.exe` | Self-contained end-to-end conformance test |
| `README.txt` | How to run |

## How to run

1. Unzip. Keep all files in the **same folder**.
2. Open a command prompt (`cmd.exe`) in that folder.
3. Run:

   ```
   zia_crypto_test.exe
   ```

You should see every check pass:

```
[OK] X3DH handshake + first message decrypted
[OK] Bob's reply decrypted by Alice
[OK] 5 round trips (multiple DH ratchet steps) valid
[OK] Session serialized/encrypted at rest, then restored
[OK] Out-of-order delivery (C, A, B) handled via skipped keys
[OK] Replay detected and rejected
[OK] Tampered ciphertext rejected
All conformance tests passed.
```

## What this build proves

- **Real end-to-end encryption**: two independent engine instances (Alice and Bob) complete an X3DH handshake and exchange messages through the Double Ratchet.
- **Forward secrecy & post-compromise security**: keys advance on every message and every DH ratchet step.
- **Resilience**: out-of-order messages are handled; replays and tampered ciphertext are rejected.
- **Encrypted-at-rest sessions**: session state is serialized and encrypted with a per-device master key protected by **Windows DPAPI** — no key is ever written in plaintext.

## Notes & limitations

- These binaries were **cross-compiled from Linux with MinGW-w64** and validated under **Wine**. On a native Windows CI they are built with CMake + vcpkg instead.
- This is the **engine**, not the full messaging app. The Flutter user interface connects to this engine through an FFI layer that is under active development.
- `zia_crypto.dll` is the exact library the app will load at runtime.
- Reproducible build: `crypto-engine/scripts/build-windows-mingw.sh`.

## Security

Built entirely on [libsodium](https://libsodium.org). No cryptographic primitive is implemented by hand — only the X3DH and Double Ratchet protocol logic, per the published Signal specifications.

---

*SHA-256 checksums are printed by the release workflow; verify your download before running.*
