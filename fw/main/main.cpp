#include "hardware.hpp"
#include "nvs_flash.h"
#include "esp_err.h"

extern "C" void app_main(){
    // Never erase NVS automatically: it holds the installation identity.
    ESP_ERROR_CHECK(nvs_flash_init());
    hps::initialize_hardware();hps::radio_start();
    xTaskCreate(hps::sd_task,"sd",4096,nullptr,2,nullptr);
    xTaskCreate(hps::io_task,"io",3072,nullptr,1,nullptr);
    hps::Sample sample;uint64_t next_battery=0;TickType_t tick=xTaskGetTickCount();
    for(;;){
        sample.uptime_ms=hps::now_ms();sample.utc_ms=hps::utc_ms();++sample.seq;
        bool ok=hps::read_pressure(sample.raw);
        hps::sensor_failed=!ok;
        sample.pressure_pa=ok?hps::pressure(sample.raw,hps::config.min_pa,hps::config.max_pa):INT32_MIN;
        if(sample.uptime_ms>=next_battery){hps::read_battery(sample.battery_mv,sample.soc);next_battery=sample.uptime_ms+30000;}
        sample.flags=(ok?hps::valid:hps::sensor_error)|(hps::rtc_ok?hps::rtc_valid:0)|
            (hps::sd_enabled&&!hps::sd_failed?hps::sd_active:0)|(hps::sd_failed?hps::sd_error:0)|
            (sample.soc<15?hps::battery_low:0);
        hps::radio_publish(sample);
        if(hps::sd_enabled && !hps::sd_failed && xQueueSend(hps::sd_queue,&sample,0)!=pdTRUE)++hps::sd_dropped;
        vTaskDelayUntil(&tick,pdMS_TO_TICKS(100));
    }
}
