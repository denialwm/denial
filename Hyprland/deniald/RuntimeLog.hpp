#pragma once

#include "../src/debug/log/Logger.hpp"

#if defined(DENIAL_ENABLE_DIAGNOSTICS)
#define DENIAL_HOT_LOG(...) Log::logger->log(__VA_ARGS__)
#else
#define DENIAL_HOT_LOG(...) ((void)0)
#endif
