#include "hardware.hpp"
#include <algorithm>
#include <cstdio>
#include <ctime>
#include <cstdlib>
#include <unistd.h>
#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "driver/sdspi_host.h"
#include "driver/spi_common.h"
#include "esp_adc/adc_oneshot.h"
#include "esp_adc/adc_cali.h"
#include "esp_adc/adc_cali_scheme.h"
#include "esp_mac.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "esp_vfs_fat.h"
#include "nvs.h"
#include "freertos/semphr.h"

namespace hps {
Configuration config;
std::atomic<bool> sd_enabled{false},sd_failed{false},rtc_ok{false};
std::atomic<bool> sensor_failed{true};
std::atomic<uint16_t> sensor_status{UINT16_MAX};
std::atomic<uint32_t> sd_dropped{0},ble_dropped{0};
std::atomic<uint64_t> pairing_until{0},identify_until{0};
QueueHandle_t sd_queue;
static i2c_master_bus_handle_t bus;
static i2c_master_dev_handle_t sensor,rtc;
static SemaphoreHandle_t bus_lock;
static adc_oneshot_unit_handle_t adc;
static adc_cali_handle_t adc_cal;
static std::atomic<int64_t> utc_offset{0};
static nvs_handle_t nvs;
static bool sensor_started=false;
static constexpr gpio_num_t red=GPIO_NUM_32,green=GPIO_NUM_33,blue=GPIO_NUM_25,
    sd_led=GPIO_NUM_27,bt_led=GPIO_NUM_13,bt_btn=GPIO_NUM_34,sd_btn=GPIO_NUM_35;
uint64_t now_ms(){return esp_timer_get_time()/1000;}
int64_t utc_ms(){auto offset=utc_offset.load();return offset?offset+int64_t(now_ms()):0;}
static uint8_t bcd(int n){return uint8_t((n/10)*16+n%10);}
static int dec(uint8_t n){return (n>>4)*10+(n&15);}
static bool transfer(i2c_master_dev_handle_t dev,const uint8_t* tx,size_t nt,uint8_t* rx,size_t nr){
    if(xSemaphoreTake(bus_lock,pdMS_TO_TICKS(30))!=pdTRUE)return false;
    esp_err_t result=nr?i2c_master_transmit_receive(dev,tx,nt,rx,nr,25):i2c_master_transmit(dev,tx,nt,25);
    xSemaphoreGive(bus_lock);return result==ESP_OK;
}
static bool sensor_read(uint8_t reg,uint16_t* out,size_t words){
    if(words<1 || words>2)return false;
    uint8_t h[3]={0xda,reg,uint8_t(((words*2-1)<<4)|crc4(reg,uint8_t((words*2-1)<<4)))};
    uint8_t rx[7]{};
    if(!transfer(sensor,h+1,2,rx,words*2+1))return false;
    uint8_t c=crc8(h,3),rd=0xdb;c=crc8(&rd,1,c);c=crc8(rx,words*2,c);
    if(c!=rx[words*2])return false;
    for(size_t i=0;i<words;++i)out[i]=u16(rx+i*2);
    return true;
}
static bool sensor_start(){
    uint8_t b[6]={0xda,0x22,0,0x93,0x8b,0};
    b[2]=0x10|crc4(0x22,0x10);b[5]=crc8(b,5);
    return transfer(sensor,b+1,5,nullptr,0);
}
bool read_pressure(int16_t& raw){
    if(!sensor_started){sensor_started=sensor_start();return false;}
    uint16_t value[2]{};
    if(!sensor_read(0x30,value,2)){sensor_status=UINT16_MAX;return false;}
    sensor_status=value[1];
    // Only the documented communication-CRC fault is decoded; keep other bits for diagnostics.
    if(value[1]&(1<<11))return false;
    raw=int16_t(value[0]);
    // Values outside the specified transfer interval are not valid pressure.
    return raw>=-16000 && raw<=16000;
}
bool set_clock(int64_t utc){
    if(utc<1577836800000LL || utc>=4102444800000LL)return false;
    time_t seconds=utc/1000;tm t{};gmtime_r(&seconds,&t);
    uint8_t b[]={0,bcd(t.tm_sec),bcd(t.tm_min),bcd(t.tm_hour),bcd(t.tm_wday+1),bcd(t.tm_mday),bcd(t.tm_mon+1),bcd(t.tm_year-100)};
    bool written=transfer(rtc,b,sizeof(b),nullptr,0);
    uint8_t reg=0x0f,status=0;
    if(written && transfer(rtc,&reg,1,&status,1)){
        uint8_t clear[]={0x0f,uint8_t(status&0x7f)};written=transfer(rtc,clear,2,nullptr,0);
    }else written=false;
    utc_offset=utc-int64_t(now_ms());rtc_ok=written;return written;
}
void read_battery(uint16_t& mv,uint8_t& soc){
    int64_t sum=0;int count=0;
    for(int i=0;i<20;++i){int raw=0,value=0;if(adc_oneshot_read(adc,ADC_CHANNEL_9,&raw)==ESP_OK &&
        adc_cal && adc_cali_raw_to_voltage(adc_cal,raw,&value)==ESP_OK){sum+=value;++count;}}
    if(count<15){mv=UINT16_MAX;soc=UINT8_MAX;return;}
    int value=int((sum/count-17)*4341/1000);
    if(value<1500 || value>5000){mv=UINT16_MAX;soc=UINT8_MAX;return;}
    mv=uint16_t(value);soc=uint8_t(std::clamp((value-2800)*100/1400,0,100));
}
bool set_sd(bool enabled){
    if(nvs_set_u8(nvs,"sd",enabled)!=ESP_OK||nvs_commit(nvs)!=ESP_OK)return false;
    sd_enabled=enabled;if(!enabled)sd_failed=false;
    return true;
}
void initialize_hardware(){
    setenv("TZ","UTC0",1);tzset();
    uint8_t mac[6];ESP_ERROR_CHECK(esp_efuse_mac_get_default(mac));
    snprintf(config.id,sizeof(config.id),"hps-%02x%02x%02x%02x%02x%02x",mac[0],mac[1],mac[2],mac[3],mac[4],mac[5]);
    uint8_t u[16];esp_fill_random(u,16);u[6]=(u[6]&15)|64;u[8]=(u[8]&63)|128;
    snprintf(config.boot,sizeof(config.boot),"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        u[0],u[1],u[2],u[3],u[4],u[5],u[6],u[7],u[8],u[9],u[10],u[11],u[12],u[13],u[14],u[15]);
    ESP_ERROR_CHECK(nvs_open("hps",NVS_READWRITE,&nvs));size_t length=32;
    config.provisioned=nvs_get_blob(nvs,"secret",config.secret.data(),&length)==ESP_OK && length==32 &&
        nvs_get_u32(nvs,"pin",&config.pin)==ESP_OK && config.pin<=999999;
    nvs_get_i32(nvs,"min_pa",&config.min_pa);nvs_get_i32(nvs,"max_pa",&config.max_pa);
    if(config.min_pa<0 || config.max_pa<=config.min_pa || config.max_pa>60000000){config.min_pa=0;config.max_pa=20000000;}
    uint8_t flag=0;nvs_get_u8(nvs,"verified",&flag);config.calibrated=flag==1;
    flag=0;nvs_get_u8(nvs,"sd",&flag);sd_enabled=flag==1;
    gpio_config_t io{};io.pin_bit_mask=(1ULL<<red)|(1ULL<<green)|(1ULL<<blue)|(1ULL<<sd_led)|(1ULL<<bt_led);
    io.mode=GPIO_MODE_OUTPUT;ESP_ERROR_CHECK(gpio_config(&io));
    io.pin_bit_mask=(1ULL<<bt_btn)|(1ULL<<sd_btn);io.mode=GPIO_MODE_INPUT;ESP_ERROR_CHECK(gpio_config(&io));
    bus_lock=xSemaphoreCreateMutex();
    i2c_master_bus_config_t bc{};bc.i2c_port=I2C_NUM_0;bc.sda_io_num=GPIO_NUM_21;bc.scl_io_num=GPIO_NUM_22;bc.clk_source=I2C_CLK_SRC_DEFAULT;bc.glitch_ignore_cnt=7;
    ESP_ERROR_CHECK(i2c_new_master_bus(&bc,&bus));
    i2c_device_config_t dc{};dc.dev_addr_length=I2C_ADDR_BIT_LEN_7;dc.device_address=0x6d;dc.scl_speed_hz=100000;
    ESP_ERROR_CHECK(i2c_master_bus_add_device(bus,&dc,&sensor));dc.device_address=0x68;
    ESP_ERROR_CHECK(i2c_master_bus_add_device(bus,&dc,&rtc));
    sensor_started=sensor_start();uint16_t serial[2]{};if(sensor_read(0x50,serial,2))config.sensor_serial=uint32_t(serial[0])|(uint32_t(serial[1])<<16);
    uint8_t reg=0x0f,status=0,clock[7]{};
    if(transfer(rtc,&reg,1,&status,1) && !(status&0x80)){
        reg=0;if(transfer(rtc,&reg,1,clock,7) && !(clock[2]&0x40) && !(clock[5]&0x80)){
            tm t{};t.tm_sec=dec(clock[0]&0x7f);t.tm_min=dec(clock[1]);t.tm_hour=dec(clock[2]&0x3f);
            t.tm_mday=dec(clock[4]);t.tm_mon=dec(clock[5]&0x1f)-1;t.tm_year=dec(clock[6])+100;
            const tm original=t;auto epoch=mktime(&t);
            bool digits=true;for(auto digit:clock){if((digit&15)>9)digits=false;}
            if(digits && original.tm_sec<60 && original.tm_min<60 && original.tm_hour<24 &&
                t.tm_mday==original.tm_mday && t.tm_mon==original.tm_mon && t.tm_year==original.tm_year &&
                epoch>=1577836800 && epoch<4102444800LL){utc_offset=int64_t(epoch)*1000-int64_t(now_ms());rtc_ok=true;}
        }
    }
    adc_oneshot_unit_init_cfg_t ac{};ac.unit_id=ADC_UNIT_2;ESP_ERROR_CHECK(adc_oneshot_new_unit(&ac,&adc));
    adc_oneshot_chan_cfg_t channel{};channel.atten=ADC_ATTEN_DB_0;channel.bitwidth=ADC_BITWIDTH_12;
    ESP_ERROR_CHECK(adc_oneshot_config_channel(adc,ADC_CHANNEL_9,&channel));
    adc_cali_line_fitting_config_t cal{};cal.unit_id=ADC_UNIT_2;cal.atten=ADC_ATTEN_DB_0;cal.bitwidth=ADC_BITWIDTH_12;cal.default_vref=1100;
    adc_cali_create_scheme_line_fitting(&cal,&adc_cal);
    sd_queue=xQueueCreate(100,sizeof(Sample));configASSERT(sd_queue);
}
void sd_task(void*){
    spi_bus_config_t b{};b.mosi_io_num=23;b.miso_io_num=19;b.sclk_io_num=18;b.quadwp_io_num=-1;b.quadhd_io_num=-1;
    bool spi_ok=spi_bus_initialize(SPI2_HOST,&b,SPI_DMA_CH_AUTO)==ESP_OK;
    FILE* file=nullptr;sdmmc_card_t* card=nullptr;uint64_t flush_at=0;uint32_t part=0;
    for(;;){
        if(sd_enabled && !file && !sd_failed){
            sdmmc_host_t host=SDSPI_HOST_DEFAULT();host.slot=SPI2_HOST;
            sdspi_device_config_t dev=SDSPI_DEVICE_CONFIG_DEFAULT();dev.gpio_cs=GPIO_NUM_5;dev.host_id=SPI2_HOST;
            esp_vfs_fat_sdmmc_mount_config_t mount{};mount.max_files=2;mount.allocation_unit_size=16*1024;mount.format_if_mount_failed=false;
            if(!spi_ok || esp_vfs_fat_sdspi_mount("/sd",&host,&dev,&mount,&card)!=ESP_OK){sd_failed=true;}
            else{
                char path[120];snprintf(path,sizeof(path),"/sd/%s-%lu.csv",config.boot,(unsigned long)++part);
                file=fopen(path,"wx");
                if(!file)sd_failed=true;
                else{fprintf(file,"device_id,boot_id,seq,uptime_ms,utc_ms,raw,pressure_pa,battery_mv,soc_pct,flags,range_min_pa,range_max_pa\n");flush_at=now_ms();}
            }
        }
        Sample s;
        if(xQueueReceive(sd_queue,&s,pdMS_TO_TICKS(100))==pdTRUE && file){
            if(fprintf(file,"%s,%s,%lu,%llu,%lld,%d,%ld,%u,%u,%u,%ld,%ld\n",config.id,config.boot,(unsigned long)s.seq,
                (unsigned long long)s.uptime_ms,(long long)s.utc_ms,s.raw,(long)s.pressure_pa,s.battery_mv,s.soc,s.flags,
                (long)config.min_pa,(long)config.max_pa)<0)sd_failed=true;
        }
        if(file && now_ms()-flush_at>=1000){if(fflush(file)!=0 || fsync(fileno(file))!=0)sd_failed=true;flush_at=now_ms();}
        if((!sd_enabled || sd_failed) && (file || card)){
            if(file){if(fclose(file)!=0)sd_failed=true;file=nullptr;}
            if(card){esp_vfs_fat_sdcard_unmount("/sd",card);card=nullptr;}
        }
    }
}
void io_task(void*){
    HeldButton bt,sd;for(;;){
        auto now=now_ms();
        if(bt.update(!gpio_get_level(bt_btn),now))pairing_until=now+120000;
        if(sd.update(!gpio_get_level(sd_btn),now))set_sd(!sd_enabled);
        bool blink=(now/250)%2,identify=now<identify_until;
        gpio_set_level(bt_led,now<pairing_until && blink);gpio_set_level(sd_led,sd_failed?blink:bool(sd_enabled));
        gpio_set_level(red,identify?blink:(!config.provisioned||sd_failed||sensor_failed));
        gpio_set_level(green,identify?blink:(!radio_connected()));gpio_set_level(blue,identify?blink:radio_connected());
        vTaskDelay(pdMS_TO_TICKS(25));
    }
}
}
