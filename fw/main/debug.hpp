#pragma once
#include "sdkconfig.h"
#include <atomic>
#include <cstdint>
namespace hps {
#if CONFIG_HPS_DEBUG_CONSOLE
extern std::atomic<bool> debug_enabled,debug_buttons,debug_monitor;
extern std::atomic<int> debug_raw,debug_leds,debug_battery;
void debug_start();
bool provision_test(uint32_t pin);
#else
inline void debug_start() {}
#endif
}
