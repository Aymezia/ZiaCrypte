#pragma once

#include <sodium.h>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <new>
#include <utility>

namespace zia::crypto {

/*
 * Buffer RAII pour tout secret cryptographique : pages gardées + verrouillées
 * (sodium_malloc/sodium_mlock), jamais copiable implicitement, effacé de façon
 * garantie à la destruction (sodium_munlock puis sodium_free effacent tous deux
 * la mémoire avant de la libérer). Cf. Phase 2 §11.4.
 */
class SecureBuffer {
public:
    SecureBuffer() = default;

    explicit SecureBuffer(size_t size) : size_(size) {
        if (size_ > 0) {
            data_ = static_cast<uint8_t*>(sodium_malloc(size_));
            if (!data_) throw std::bad_alloc();
            sodium_mlock(data_, size_);
        }
    }

    ~SecureBuffer() { reset(); }

    SecureBuffer(const SecureBuffer&) = delete;
    SecureBuffer& operator=(const SecureBuffer&) = delete;

    SecureBuffer(SecureBuffer&& other) noexcept : data_(other.data_), size_(other.size_) {
        other.data_ = nullptr;
        other.size_ = 0;
    }

    SecureBuffer& operator=(SecureBuffer&& other) noexcept {
        if (this != &other) {
            reset();
            data_ = other.data_;
            size_ = other.size_;
            other.data_ = nullptr;
            other.size_ = 0;
        }
        return *this;
    }

    // Copie explicite — jamais implicite — pour les rares cas où le protocole
    // exige de dupliquer un secret (ex : réutilisation d'un signed prekey par
    // plusieurs sessions répondeur, cf. Phase 6 x3dh::accept_handshake).
    SecureBuffer clone() const {
        SecureBuffer copy(size_);
        if (data_ && copy.data_) {
            std::memcpy(copy.data_, data_, size_);
        }
        return copy;
    }

    uint8_t* data() { return data_; }
    const uint8_t* data() const { return data_; }
    size_t size() const { return size_; }
    bool empty() const { return size_ == 0; }

    void reset() {
        if (data_) {
            sodium_munlock(data_, size_); // efface puis déverrouille
            sodium_free(data_);           // efface à nouveau puis libère les pages gardées
            data_ = nullptr;
            size_ = 0;
        }
    }

private:
    uint8_t* data_ = nullptr;
    size_t size_ = 0;
};

} // namespace zia::crypto
