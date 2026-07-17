#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <utility>
#include <vector>

namespace Denial {

    // Tracks physical keys whose down transition was delivered to Flutter.
    // Secure-boundary transitions can balance Flutter immediately while this
    // tracker continues quarantining the corresponding hardware releases.
    class CKeyboardOwnership {
        struct SKey {
            const void* keyboard    = nullptr;
            uint32_t    keycode     = 0;
            bool        releaseSent = false;
        };

        using TKeys = std::vector<SKey>;

      public:
        bool acquire(const void* keyboard, uint32_t keycode) {
            if (!keyboard || owns(keyboard, keycode))
                return false;

            m_keys.push_back(SKey{
                .keyboard = keyboard,
                .keycode  = keycode,
            });
            return true;
        }

        bool owns(const void* keyboard, uint32_t keycode, bool awaitingFlutterRelease = false) const {
            const auto key = find(keyboard, keycode);
            return key != m_keys.end() && (!awaitingFlutterRelease || !key->releaseSent);
        }

        template <typename TRelease>
        bool consumeRelease(const void* keyboard, uint32_t keycode, TRelease&& release) {
            const auto key = find(keyboard, keycode);
            if (key == m_keys.end())
                return false;

            if (!key->releaseSent)
                std::invoke(std::forward<TRelease>(release), keycode);
            m_keys.erase(key);
            return true;
        }

        template <typename TRelease>
        void flush(TRelease&& release) {
            for (auto& key : m_keys) {
                if (!key.releaseSent && std::invoke(release, key.keycode))
                    key.releaseSent = true;
            }
        }

        void eraseKeyboard(const void* keyboard) {
            std::erase_if(m_keys, [keyboard](const SKey& key) { return key.keyboard == keyboard; });
        }

        std::size_t size() const {
            return m_keys.size();
        }

      private:
        TKeys::iterator find(const void* keyboard, uint32_t keycode) {
            return std::ranges::find_if(m_keys, [keyboard, keycode](const SKey& key) { return key.keyboard == keyboard && key.keycode == keycode; });
        }

        TKeys::const_iterator find(const void* keyboard, uint32_t keycode) const {
            return std::ranges::find_if(m_keys, [keyboard, keycode](const SKey& key) { return key.keyboard == keyboard && key.keycode == keycode; });
        }

        TKeys m_keys;
    };

} // namespace Denial
