#include "zia/zia_crypto.h"
#include "ratchet/ratchet_state.hpp"
#include "storage/secure_key_store.hpp"

#include <sodium.h>
#include <cstring>
#include <cstdlib>
#include <vector>

using namespace zia::crypto;

namespace {

void write_u32_le(uint8_t* out, uint32_t v) {
    out[0] = static_cast<uint8_t>(v);
    out[1] = static_cast<uint8_t>(v >> 8);
    out[2] = static_cast<uint8_t>(v >> 16);
    out[3] = static_cast<uint8_t>(v >> 24);
}

uint32_t read_u32_le(const uint8_t* in) {
    return static_cast<uint32_t>(in[0]) | (static_cast<uint32_t>(in[1]) << 8) |
           (static_cast<uint32_t>(in[2]) << 16) | (static_cast<uint32_t>(in[3]) << 24);
}

void append(std::vector<uint8_t>& buf, const uint8_t* data, size_t len) {
    buf.insert(buf.end(), data, data + len);
}

void append_u32(std::vector<uint8_t>& buf, uint32_t v) {
    uint8_t tmp[4];
    write_u32_le(tmp, v);
    append(buf, tmp, 4);
}

void append_bool_and_key32(std::vector<uint8_t>& buf, bool present, const SecureBuffer& key) {
    buf.push_back(present ? 1 : 0);
    uint8_t zero[32] = {0};
    append(buf, present ? key.data() : zero, 32);
}

/* Sérialise l'état complet du Double Ratchet, en clair (avant chiffrement at-rest). */
std::vector<uint8_t> serialize_state(const ZiaSession& s) {
    std::vector<uint8_t> buf;
    buf.reserve(256 + s.skipped.size() * 68);

    append(buf, s.ad, sizeof(s.ad));
    append(buf, s.dhs_public, sizeof(s.dhs_public));
    append(buf, s.dhs_private.data(), s.dhs_private.size()); // 32 (X25519)

    buf.push_back(s.has_dhr ? 1 : 0);
    append(buf, s.dhr_public, sizeof(s.dhr_public));

    append(buf, s.root_key.data(), s.root_key.size());
    append_bool_and_key32(buf, s.has_send_chain, s.send_chain_key);
    append_bool_and_key32(buf, s.has_recv_chain, s.recv_chain_key);

    append_u32(buf, s.ns);
    append_u32(buf, s.nr);
    append_u32(buf, s.pn);

    append_u32(buf, static_cast<uint32_t>(s.skipped.size()));
    for (const auto& sk : s.skipped) {
        append(buf, sk.dh_public, sizeof(sk.dh_public));
        append_u32(buf, sk.n);
        append(buf, sk.key.data(), sk.key.size()); // 32
    }

    return buf;
}

bool deserialize_state(const uint8_t* data, size_t len, ZiaSession& s) {
    size_t offset = 0;
    auto need = [&](size_t n) { return offset + n <= len; };

    if (!need(sizeof(s.ad))) return false;
    std::memcpy(s.ad, data + offset, sizeof(s.ad)); offset += sizeof(s.ad);

    if (!need(32)) return false;
    std::memcpy(s.dhs_public, data + offset, 32); offset += 32;

    if (!need(32)) return false;
    s.dhs_private = SecureBuffer(32);
    std::memcpy(s.dhs_private.data(), data + offset, 32); offset += 32;

    if (!need(1 + 32)) return false;
    s.has_dhr = data[offset] != 0; offset += 1;
    std::memcpy(s.dhr_public, data + offset, 32); offset += 32;

    if (!need(32)) return false;
    s.root_key = SecureBuffer(32);
    std::memcpy(s.root_key.data(), data + offset, 32); offset += 32;

    if (!need(1 + 32)) return false;
    s.has_send_chain = data[offset] != 0; offset += 1;
    s.send_chain_key = SecureBuffer(32);
    std::memcpy(s.send_chain_key.data(), data + offset, 32); offset += 32;

    if (!need(1 + 32)) return false;
    s.has_recv_chain = data[offset] != 0; offset += 1;
    s.recv_chain_key = SecureBuffer(32);
    std::memcpy(s.recv_chain_key.data(), data + offset, 32); offset += 32;

    if (!need(12)) return false;
    s.ns = read_u32_le(data + offset); offset += 4;
    s.nr = read_u32_le(data + offset); offset += 4;
    s.pn = read_u32_le(data + offset); offset += 4;

    if (!need(4)) return false;
    uint32_t skipped_count = read_u32_le(data + offset); offset += 4;

    s.skipped.clear();
    s.skipped.reserve(skipped_count);
    for (uint32_t i = 0; i < skipped_count; ++i) {
        if (!need(32 + 4 + 32)) return false;
        ZiaSkippedKey sk;
        std::memcpy(sk.dh_public, data + offset, 32); offset += 32;
        sk.n = read_u32_le(data + offset); offset += 4;
        sk.key = SecureBuffer(32);
        std::memcpy(sk.key.data(), data + offset, 32); offset += 32;
        s.skipped.push_back(std::move(sk));
    }

    return offset == len;
}

/* La clé maîtresse est propre à l'appareil (un seul coffre-fort par machine),
 * pas à une session ni à un ZiaEngine en particulier : générée au premier
 * appel, réutilisée ensuite. */
bool ensure_master_key(SecureBuffer& out_key) {
    auto& store = storage::platform_key_store();
    if (store.has_master_key()) {
        return store.load_master_key(out_key);
    }
    return store.generate_and_store_master_key(out_key);
}

} // namespace

ZIA_API ZiaStatus zia_session_serialize(ZiaSession* session, uint8_t** out, size_t* out_len) {
    if (!session || !out || !out_len) return ZIA_ERR_INVALID_ARG;

    SecureBuffer master_key;
    if (!ensure_master_key(master_key)) return ZIA_ERR_STORAGE_IO;

    std::vector<uint8_t> plaintext = serialize_state(*session);

    uint8_t header[crypto_secretstream_xchacha20poly1305_HEADERBYTES];
    crypto_secretstream_xchacha20poly1305_state st;
    if (crypto_secretstream_xchacha20poly1305_init_push(&st, header, master_key.data()) != 0) {
        sodium_memzero(plaintext.data(), plaintext.size());
        return ZIA_ERR_CRYPTO_FAILURE;
    }

    size_t ciphertext_len = plaintext.size() + crypto_secretstream_xchacha20poly1305_ABYTES;
    size_t total_len = sizeof(header) + ciphertext_len;
    auto* buffer = static_cast<uint8_t*>(malloc(total_len));
    if (!buffer) {
        sodium_memzero(plaintext.data(), plaintext.size());
        return ZIA_ERR_OUT_OF_MEMORY;
    }
    std::memcpy(buffer, header, sizeof(header));

    unsigned long long actual_len = 0;
    int rc = crypto_secretstream_xchacha20poly1305_push(
        &st, buffer + sizeof(header), &actual_len,
        plaintext.data(), plaintext.size(), nullptr, 0,
        crypto_secretstream_xchacha20poly1305_TAG_FINAL);

    sodium_memzero(plaintext.data(), plaintext.size());

    if (rc != 0) {
        free(buffer);
        return ZIA_ERR_CRYPTO_FAILURE;
    }

    *out = buffer;
    *out_len = total_len;
    return ZIA_OK;
}

ZIA_API ZiaStatus zia_session_deserialize(ZiaEngine*, const uint8_t* data, size_t len,
                                          ZiaSession** out_session) {
    if (!data || !out_session) return ZIA_ERR_INVALID_ARG;
    constexpr size_t kMinLen = crypto_secretstream_xchacha20poly1305_HEADERBYTES +
                               crypto_secretstream_xchacha20poly1305_ABYTES;
    if (len < kMinLen) return ZIA_ERR_INVALID_ARG;

    SecureBuffer master_key;
    if (!ensure_master_key(master_key)) return ZIA_ERR_STORAGE_IO;

    const uint8_t* header = data;
    const uint8_t* ciphertext = data + crypto_secretstream_xchacha20poly1305_HEADERBYTES;
    size_t ciphertext_len = len - crypto_secretstream_xchacha20poly1305_HEADERBYTES;

    crypto_secretstream_xchacha20poly1305_state st;
    if (crypto_secretstream_xchacha20poly1305_init_pull(&st, header, master_key.data()) != 0) {
        return ZIA_ERR_CRYPTO_FAILURE;
    }

    std::vector<uint8_t> plaintext(ciphertext_len - crypto_secretstream_xchacha20poly1305_ABYTES);
    unsigned long long plaintext_len = 0;
    uint8_t tag = 0;
    int rc = crypto_secretstream_xchacha20poly1305_pull(
        &st, plaintext.data(), &plaintext_len, &tag, ciphertext, ciphertext_len, nullptr, 0);

    if (rc != 0) {
        sodium_memzero(plaintext.data(), plaintext.size());
        return ZIA_ERR_CRYPTO_FAILURE;
    }

    auto* session = new ZiaSession();
    bool ok = deserialize_state(plaintext.data(), static_cast<size_t>(plaintext_len), *session);
    sodium_memzero(plaintext.data(), plaintext.size());

    if (!ok) {
        delete session;
        return ZIA_ERR_CRYPTO_FAILURE;
    }

    *out_session = session;
    return ZIA_OK;
}

ZIA_API void zia_session_close(ZiaSession* session) {
    delete session; // les destructeurs de SecureBuffer effacent chaque secret
}
