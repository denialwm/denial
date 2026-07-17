#include "managers/input/DenialKeyboardOwnership.hpp"

#include <gtest/gtest.h>

#include <vector>

TEST(DenialKeyboardOwnership, FlushBalancesFlutterAndQuarantinesPhysicalRelease) {
    Denial::CKeyboardOwnership ownership;
    int                        keyboard = 0;
    std::vector<uint32_t>      releases;

    EXPECT_TRUE(ownership.acquire(&keyboard, 28));
    ownership.flush([&](uint32_t keycode) {
        releases.push_back(keycode);
        return true;
    });

    EXPECT_EQ(releases, std::vector<uint32_t>({28}));
    EXPECT_TRUE(ownership.owns(&keyboard, 28));
    EXPECT_FALSE(ownership.owns(&keyboard, 28, true));
    EXPECT_TRUE(ownership.consumeRelease(&keyboard, 28, [&](uint32_t) {
        ADD_FAILURE() << "a boundary-balanced key must not emit a second Flutter release";
        return true;
    }));
    EXPECT_FALSE(ownership.owns(&keyboard, 28));
}

TEST(DenialKeyboardOwnership, DuplicateDownCannotLeaveDuplicateOwnership) {
    Denial::CKeyboardOwnership ownership;
    int                        keyboard     = 0;
    int                        releaseCount = 0;

    EXPECT_TRUE(ownership.acquire(&keyboard, 28));
    EXPECT_FALSE(ownership.acquire(&keyboard, 28));
    EXPECT_EQ(ownership.size(), 1U);

    ownership.flush([&](uint32_t) {
        ++releaseCount;
        return true;
    });
    ownership.flush([&](uint32_t) {
        ++releaseCount;
        return true;
    });
    EXPECT_EQ(releaseCount, 1);
}

TEST(DenialKeyboardOwnership, FailedBoundaryDeliveryRetriesOnPhysicalRelease) {
    Denial::CKeyboardOwnership ownership;
    int                        keyboard     = 0;
    int                        releaseCount = 0;

    ASSERT_TRUE(ownership.acquire(&keyboard, 42));
    ownership.flush([](uint32_t) { return false; });
    EXPECT_TRUE(ownership.owns(&keyboard, 42, true));

    EXPECT_TRUE(ownership.consumeRelease(&keyboard, 42, [&](uint32_t keycode) {
        EXPECT_EQ(keycode, 42U);
        ++releaseCount;
        return true;
    }));
    EXPECT_EQ(releaseCount, 1);
    EXPECT_EQ(ownership.size(), 0U);
}

TEST(DenialKeyboardOwnership, RemovingKeyboardDropsOnlyItsQuarantine) {
    Denial::CKeyboardOwnership ownership;
    int                        firstKeyboard  = 0;
    int                        secondKeyboard = 0;

    ASSERT_TRUE(ownership.acquire(&firstKeyboard, 28));
    ASSERT_TRUE(ownership.acquire(&secondKeyboard, 28));
    ownership.eraseKeyboard(&firstKeyboard);

    EXPECT_FALSE(ownership.owns(&firstKeyboard, 28));
    EXPECT_TRUE(ownership.owns(&secondKeyboard, 28));
}
