#pragma once
#include "core.hpp"
#include <atomic>
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"

namespace hps {
struct Configuration {
    char id[17]{},boot[37]{};
    std::array<uint8_t,32> secret{};
    uint32_t pin=0,sensor_serial=0;
    int32_t min_pa=0,max_pa=20000000;
    bool provisioned=false,calibrated=false;
};
extern Configuration config;
extern std::atomic<bool> sd_enabled,sd_failed,rtc_ok;
extern std::atomic<bool> sensor_failed;
extern std::atomic<uint16_t> sensor_status;
extern std::atomic<uint32_t> sd_dropped,ble_dropped;
extern std::atomic<uint64_t> pairing_until,identify_until;
extern QueueHandle_t sd_queue;
uint64_t now_ms();
int64_t utc_ms();
bool set_clock(int64_t utc);
void initialize_hardware();
bool read_pressure(int16_t& raw);
void read_battery(uint16_t& mv,uint8_t& soc);
bool set_sd(bool enabled);
void sd_task(void*);
void io_task(void*);
void radio_start();
bool radio_connected();
void radio_publish(const Sample& sample);
}
