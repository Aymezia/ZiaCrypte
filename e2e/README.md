# End-to-end assembly test

Proves the **whole system works together**: the native C++ crypto engine (through Dart FFI), a Dart client, the real Fastify server, and a real PostgreSQL database.

Alice and Bob are two independent clients, each with its own native engine instance. They register, publish prekeys, perform an X3DH handshake through the API, then exchange messages that the server only ever relays as opaque ciphertext.

## Run it

1. **Build the native engine**

   ```bash
   cd ../crypto-engine
   cmake --preset linux-system && cmake --build --preset linux-system
   ```

2. **Start PostgreSQL and the server** (see `../server/README` / `.env.example`)

   ```bash
   cd ../server
   npx prisma db push
   PORT=3210 npx tsx src/index.ts
   ```

3. **Run the test**

   ```bash
   dart pub get
   dart run bin/e2e_client.dart \
     http://127.0.0.1:3210 \
     ../crypto-engine/build/linux-system/src/libzia_crypto.so
   ```

Expected: every step `[OK]`, ending with `7/7 étapes réussies`.

## Verify the server is blind

After a run, the database must contain **no plaintext**:

```sql
SELECT count(*) FROM message_blobs
WHERE encode(ciphertext,'escape') LIKE '%<a phrase you sent>%';
-- must return 0
```

## Note on imports

This is a plain Dart package (not Flutter), so it can run under `dart run`. It imports the FFI client layer directly from `../app/lib/…` via relative paths — the same code the Flutter application uses, so this test exercises the real client stack rather than a copy.
