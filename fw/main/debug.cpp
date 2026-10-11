#include "debug.hpp"
#if CONFIG_HPS_DEBUG_CONSOLE
#include "hardware.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "driver/gpio.h"
#include "esp_system.h"

namespace hps {
std::atomic<bool> debug_enabled{false},debug_buttons{true},debug_monitor{false};
std::atomic<int> debug_raw{INT32_MIN},debug_leds{-1},debug_battery{-1};
static void reset(){debug_raw=INT32_MIN;debug_leds=-1;debug_battery=-1;debug_monitor=false;debug_buttons=true;}
static void status(){
    printf("id=%s provisioned=%d BLE=%d pairing=%d debug=%d raw=%d sensor_error=%d sensor_status=%u RTC=%d SD=%d SD_error=%d SD_dropped=%lu BLE_dropped=%lu buttons34/35=%d/%d\n",
        config.id,config.provisioned,radio_connected(),now_ms()<pairing_until,debug_enabled.load(),debug_raw.load(),
        sensor_failed.load(),sensor_status.load(),rtc_ok.load(),sd_enabled.load(),sd_failed.load(),
        (unsigned long)sd_dropped.load(),(unsigned long)ble_dropped.load(),gpio_get_level(GPIO_NUM_34),gpio_get_level(GPIO_NUM_35));
}
static void execute(char* line){
    char op[24]{},arg[40]{},extra[2]{};
    int parts=sscanf(line,"%23s %39s %1s",op,arg,extra);
    if(parts<1)return;
    if(!strcmp(op,"help")){
        puts("status | debug on/off | pair | sensor real/error/<raw -16000..16000> | battery real/<mV 2800..4200> | led auto/<mask 0..31: RGB,SD,BT> | buttons on/off | monitor on/off | sd on/off | time <UTC ms> | provision <6-digit test PIN>");
        return;
    }
    if(!strcmp(op,"status")){status();return;}
    if(!strcmp(op,"debug") && parts==2 && (!strcmp(arg,"on")||!strcmp(arg,"off"))){
        reset();debug_enabled=!strcmp(arg,"on");if(debug_enabled)debug_buttons=false;
        puts(debug_enabled?"DEBUG ON; physical button actions disabled (floating GPIO34/35).":"DEBUG OFF");return;
    }
    if(!debug_enabled){puts("Use: debug on");return;}
    char* end=nullptr;long long number=strtoll(arg,&end,10);bool numeric=parts==2 && *arg && end && !*end;
    bool on=!strcmp(arg,"on"),off=!strcmp(arg,"off"),ok=false;
    if(parts==1 && !strcmp(op,"pair")){pairing_until=now_ms()+120000;ok=true;}
    if(parts==2 && !strcmp(op,"sensor")){
        if(!strcmp(arg,"real")){debug_raw=INT32_MIN;ok=true;}
        else if(!strcmp(arg,"error")){debug_raw=INT32_MAX;ok=true;}
        else if(numeric && number>=-16000 && number<=16000){debug_raw=int(number);ok=true;}
    }
    if(parts==2 && !strcmp(op,"battery")){
        if(!strcmp(arg,"real")){debug_battery=-1;ok=true;}
        else if(numeric && number>=2800 && number<=4200){debug_battery=int(number);ok=true;}
    }
    if(parts==2 && !strcmp(op,"led")){
        if(!strcmp(arg,"auto")){debug_leds=-1;ok=true;}
        else if(numeric && number>=0 && number<=31){debug_leds=int(number);ok=true;}
    }
    if(parts==2 && (on||off)){
        if(!strcmp(op,"sd"))ok=set_sd(on);
        if(!strcmp(op,"buttons")){debug_buttons=on;ok=true;}
        if(!strcmp(op,"monitor")){debug_monitor=on;ok=true;}
    }
    if(!strcmp(op,"time") && numeric && number>=1577836800000LL && number<4102444800000LL){
        bool rtc=set_clock(number);printf("Software UTC set; RTC write=%d\n",rtc);ok=true;
    }
    if(!strcmp(op,"provision") && numeric && strlen(arg)==6 && number>=0 && number<=999999){
        if(config.provisioned){puts("Refused: identity already provisioned.");return;}
        if(provision_test(uint32_t(number))){puts("Test identity stored. Rebooting; use the chosen PIN. Never ship this test identity.");fflush(stdout);vTaskDelay(pdMS_TO_TICKS(100));esp_restart();}
    }
    puts(ok?"OK":"Invalid command or hardware/settings failure; use help.");
}
static void task(void*){
    char line[128]{};size_t used=0;bool overflow=false;
    puts("Bench console: help; debug on. GPIO34/35 need external pull-ups. Unprovisioned devices cannot authenticate BLE.");
    status();
    for(;;){
        int c=getchar();
        if(c==EOF){clearerr(stdin);vTaskDelay(pdMS_TO_TICKS(20));continue;}
        if(c=='\n'||c=='\r'){
            line[used]=0;if(overflow)puts("Command too long.");else execute(line);
            used=0;overflow=false;fflush(stdout);
        }else if(c==8||c==127){if(used)--used;}
        else if(c>=32 && c<127){if(used<sizeof(line)-1)line[used++]=char(c);else overflow=true;}
    }
}
void debug_start(){xTaskCreate(task,"debug",4096,nullptr,1,nullptr);}
}
#endif
