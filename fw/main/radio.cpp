#include "hardware.hpp"
#include <cstdio>
#include <cstring>
#include <string>
#include "cJSON.h"
#include "mbedtls/base64.h"
#include "psa/crypto.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/ble_sm.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "store/config/ble_store_config.h"
#include "freertos/semphr.h"
extern "C" void ble_store_config_init(void);

namespace hps {
#define HPS_UUID(n) BLE_UUID128_INIT(0x00,0xc2,0xcf,0xb6,0x90,0x7d,0x23,0xa1,0x2d,0x4e,0xe8,0x8e,n,0x00,0x5a,0x5c)
static const ble_uuid128_t service_uuid=HPS_UUID(1),sample_uuid=HPS_UUID(2),info_uuid=HPS_UUID(3),control_uuid=HPS_UUID(4),result_uuid=HPS_UUID(5);
static ble_gatt_chr_def characteristics[5]{};
static ble_gatt_svc_def services[2]{};
static uint16_t sample_handle,result_handle;
static std::atomic<uint16_t> connection{BLE_HS_CONN_HANDLE_NONE},supervision{0};
static std::atomic<uint32_t> generation{0};
static std::atomic<bool> authenticated{false},notify_samples{false},notify_result{false},busy{false};
static uint8_t own_address_type;
static Fragments fragments;
static std::string result="{\"id\":0,\"ok\":false,\"error\":\"no_result\"}";
static SemaphoreHandle_t result_lock;
static QueueHandle_t samples,commands;
struct Command{uint32_t generation;uint16_t id;char data[513];};
static void advertise();
static int event(ble_gap_event*,void*);
bool radio_connected(){return authenticated;}
static int append(ble_gatt_access_ctxt* c,const std::string& value){
    return os_mbuf_append(c->om,value.data(),value.size())==0?0:BLE_ATT_ERR_INSUFFICIENT_RES;
}
static std::string json_text(cJSON* object){char* text=cJSON_PrintUnformatted(object);std::string s=text?text:"{}";cJSON_free(text);return s;}
static std::string info(){
    auto j=cJSON_CreateObject();
    cJSON_AddStringToObject(j,"device_id",config.id);cJSON_AddStringToObject(j,"boot_id",config.boot);
    cJSON_AddNumberToObject(j,"uptime_ms",double(now_ms()));cJSON_AddStringToObject(j,"firmware_version","2.0.0");
    cJSON_AddNumberToObject(j,"protocol_version",2);cJSON_AddNumberToObject(j,"sensor_serial",config.sensor_serial);
    cJSON_AddBoolToObject(j,"provisioned",config.provisioned);cJSON_AddBoolToObject(j,"pairing_open",now_ms()<pairing_until);
    cJSON_AddNumberToObject(j,"range_min_pa",config.min_pa);cJSON_AddNumberToObject(j,"range_max_pa",config.max_pa);
    cJSON_AddBoolToObject(j,"calibration_verified",config.calibrated);cJSON_AddNumberToObject(j,"sd_dropped",sd_dropped);
    cJSON_AddNumberToObject(j,"ble_dropped",ble_dropped);cJSON_AddNumberToObject(j,"supervision_ms",supervision);
    cJSON_AddNumberToObject(j,"sensor_status",sensor_status);
    auto value=json_text(j);cJSON_Delete(j);return value;
}
static int access(uint16_t,uint16_t,ble_gatt_access_ctxt* c,void* arg){
    intptr_t kind=reinterpret_cast<intptr_t>(arg);
    if(kind==3 && c->op==BLE_GATT_ACCESS_OP_READ_CHR)return append(c,info());
    if(!authenticated)return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
    if(kind==5 && c->op==BLE_GATT_ACCESS_OP_READ_CHR){
        xSemaphoreTake(result_lock,portMAX_DELAY);auto value=result;xSemaphoreGive(result_lock);return append(c,value);
    }
    if(kind!=4 || c->op!=BLE_GATT_ACCESS_OP_WRITE_CHR)return BLE_ATT_ERR_READ_NOT_PERMITTED;
    if(busy)return BLE_ATT_ERR_INSUFFICIENT_RES;
    uint8_t bytes[20];uint16_t length=0;
    if(OS_MBUF_PKTLEN(c->om)>20 || ble_hs_mbuf_to_flat(c->om,bytes,sizeof(bytes),&length))return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    int state=fragments.add(bytes,length,now_ms());
    if(state<0)return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    if(state==1){
        Command cmd{};cmd.generation=generation;cmd.id=fragments.id;
        if(strlen(fragments.data.data())!=fragments.used){fragments.clear();return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;}
        memcpy(cmd.data,fragments.data.data(),fragments.used+1);fragments.clear();
        busy=true;if(xQueueSend(commands,&cmd,0)!=pdTRUE){busy=false;return BLE_ATT_ERR_INSUFFICIENT_RES;}
    }
    return 0;
}
static bool uuid_string(const char* s){
    if(!s || strlen(s)!=36)return false;
    for(int i=0;i<36;++i){if(i==8||i==13||i==18||i==23){if(s[i]!='-')return false;}
        else if(!((s[i]>='0'&&s[i]<='9')||(s[i]>='a'&&s[i]<='f')))return false;}
    return true;
}
static const char* text(cJSON* j,const char* key){auto v=cJSON_GetObjectItemCaseSensitive(j,key);return cJSON_IsString(v)?v->valuestring:nullptr;}
static std::string claim(cJSON* j){
    auto account=text(j,"account_id"),challenge=text(j,"challenge_id"),nonce=text(j,"nonce");
    if(!uuid_string(account)||!uuid_string(challenge)||!nonce||strlen(nonce)!=22)return {};
    std::string encoded=nonce;for(char& c:encoded){if(c=='-')c='+';if(c=='_')c='/';}encoded+="==";
    uint8_t decoded[16];size_t size=0;
    if(mbedtls_base64_decode(decoded,sizeof(decoded),&size,reinterpret_cast<const unsigned char*>(encoded.data()),encoded.size()) || size!=16)return {};
    std::string input=std::string("HPS-CLAIM-v1\n")+config.id+"\n"+account+"\n"+challenge+"\n";
    input.append(reinterpret_cast<char*>(decoded),16);
    psa_key_attributes_t attrs=PSA_KEY_ATTRIBUTES_INIT;psa_key_id_t key=0;
    psa_set_key_type(&attrs,PSA_KEY_TYPE_HMAC);psa_set_key_bits(&attrs,256);psa_set_key_usage_flags(&attrs,PSA_KEY_USAGE_SIGN_MESSAGE);
    psa_set_key_algorithm(&attrs,PSA_ALG_HMAC(PSA_ALG_SHA_256));
    if(psa_import_key(&attrs,config.secret.data(),32,&key)!=PSA_SUCCESS)return {};
    uint8_t mac[32];size_t count=0;
    auto rc=psa_mac_compute(key,PSA_ALG_HMAC(PSA_ALG_SHA_256),reinterpret_cast<const uint8_t*>(input.data()),input.size(),mac,sizeof(mac),&count);
    psa_destroy_key(key);psa_reset_key_attributes(&attrs);if(rc!=PSA_SUCCESS||count!=32)return {};
    unsigned char out[48];size_t written=0;if(mbedtls_base64_encode(out,sizeof(out),&written,mac,32))return {};
    std::string proof(reinterpret_cast<char*>(out),written);while(!proof.empty()&&proof.back()=='=')proof.pop_back();
    for(char& c:proof){if(c=='+')c='-';if(c=='/')c='_';}return proof;
}
static void execute(const Command& cmd){
    if(cmd.generation!=generation || !authenticated){busy=false;return;}
    cJSON* request=cJSON_Parse(cmd.data);cJSON* response=cJSON_CreateObject();
    cJSON_AddNumberToObject(response,"id",cmd.id);bool ok=false;std::string error="invalid_command";
    auto op=text(request,"op");
    if(op && !strcmp(op,"time")){
        auto up=now_ms();auto utc=utc_ms();cJSON_AddNumberToObject(response,"uptime_ms",double(up));
        if(utc)cJSON_AddNumberToObject(response,"utc_ms",double(utc));else cJSON_AddNullToObject(response,"utc_ms");ok=true;
    }else if(op && !strcmp(op,"set_time")){
        auto utc=cJSON_GetObjectItemCaseSensitive(request,"utc_ms");
        if(cJSON_IsNumber(utc)&&utc->valuedouble>=1577836800000.0&&utc->valuedouble<4102444800000.0){
            bool rtc_written=set_clock(int64_t(utc->valuedouble));cJSON_AddBoolToObject(response,"rtc_valid",rtc_written);
            cJSON_AddNumberToObject(response,"uptime_ms",double(now_ms()));cJSON_AddNumberToObject(response,"utc_ms",double(utc_ms()));ok=true;
        }
    }else if(op && !strcmp(op,"identify")){identify_until=now_ms()+3000;ok=true;
    }else if(op && !strcmp(op,"sd")){
        auto value=cJSON_GetObjectItemCaseSensitive(request,"enabled");if(cJSON_IsBool(value)){ok=set_sd(cJSON_IsTrue(value));error="settings_write_failed";cJSON_AddBoolToObject(response,"enabled",sd_enabled);}
    }else if(op && !strcmp(op,"claim")){
        if(!config.provisioned||now_ms()>=pairing_until)error="pairing_window_closed";
        else{auto proof=claim(request);if(!proof.empty()){cJSON_AddStringToObject(response,"proof",proof.c_str());ok=true;}}
    }
    cJSON_AddBoolToObject(response,"ok",ok);if(!ok)cJSON_AddStringToObject(response,"error",error.c_str());
    if(cmd.generation==generation && authenticated){
        auto value=json_text(response);xSemaphoreTake(result_lock,portMAX_DELAY);result=value;xSemaphoreGive(result_lock);
        if(notify_result){uint8_t id[2];put(id,cmd.id,2);auto mb=ble_hs_mbuf_from_flat(id,2);if(mb)ble_gatts_notify_custom(connection,result_handle,mb);}
    }
    cJSON_Delete(response);cJSON_Delete(request);busy=false;
}
static void worker(void*){
    for(;;){
        Command cmd;if(xQueueReceive(commands,&cmd,0)==pdTRUE)execute(cmd);
        Sample sample;
        if(xQueueReceive(samples,&sample,pdMS_TO_TICKS(10))==pdTRUE && authenticated && notify_samples){
            auto bytes=encode(sample);auto mb=ble_hs_mbuf_from_flat(bytes.data(),bytes.size());
            if(!mb || ble_gatts_notify_custom(connection,sample_handle,mb))++ble_dropped;
        }
    }
}
void radio_publish(const Sample& sample){
    if(uxQueueMessagesWaiting(samples))++ble_dropped;
    xQueueOverwrite(samples,&sample);
}
static int event(ble_gap_event* e,void*){
    switch(e->type){
    case BLE_GAP_EVENT_CONNECT:
        if(e->connect.status){advertise();break;}
        connection=e->connect.conn_handle;authenticated=false;++generation;
        if(config.provisioned)ble_gap_security_initiate(connection);
        {ble_gap_upd_params params{};params.itvl_min=24;params.itvl_max=40;params.latency=0;params.supervision_timeout=200;ble_gap_update_params(connection,&params);}
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        connection=BLE_HS_CONN_HANDLE_NONE;authenticated=false;notify_samples=false;notify_result=false;
        ++generation;fragments.clear();advertise();break;
    case BLE_GAP_EVENT_ENC_CHANGE:{
        ble_gap_conn_desc d{};if(!e->enc_change.status && !ble_gap_conn_find(connection,&d))authenticated=d.sec_state.encrypted && d.sec_state.authenticated && d.sec_state.bonded;
        if(!authenticated){ble_gap_terminate(connection,BLE_ERR_AUTH_FAIL);}
        break;}
    case BLE_GAP_EVENT_CONN_UPDATE:{ble_gap_conn_desc d{};if(!ble_gap_conn_find(connection,&d))supervision=d.supervision_timeout*10;break;}
    case BLE_GAP_EVENT_SUBSCRIBE:
        if(e->subscribe.attr_handle==sample_handle)notify_samples=e->subscribe.cur_notify;
        if(e->subscribe.attr_handle==result_handle){notify_result=e->subscribe.cur_notify;}
        break;
    case BLE_GAP_EVENT_PASSKEY_ACTION:{
        if(!config.provisioned||now_ms()>=pairing_until){ble_gap_terminate(connection,BLE_ERR_AUTH_FAIL);break;}
        ble_sm_io io{};io.action=e->passkey.params.action;
        if(io.action==BLE_SM_IOACT_DISP){io.passkey=config.pin;ble_sm_inject_io(e->passkey.conn_handle,&io);}
        else {ble_gap_terminate(connection,BLE_ERR_AUTH_FAIL);}
        break;}
    case BLE_GAP_EVENT_REPEAT_PAIRING:{
        if(now_ms()>=pairing_until)return BLE_GAP_REPEAT_PAIRING_IGNORE;
        ble_gap_conn_desc d{};if(!ble_gap_conn_find(connection,&d))ble_store_util_delete_peer(&d.peer_id_addr);
        return BLE_GAP_REPEAT_PAIRING_RETRY;}
    case BLE_GAP_EVENT_ADV_COMPLETE:advertise();break;
    default:break;
    }return 0;
}
static void advertise(){
    ble_hs_adv_fields fields{};fields.flags=BLE_HS_ADV_F_DISC_GEN|BLE_HS_ADV_F_BREDR_UNSUP;
    fields.uuids128=const_cast<ble_uuid128_t*>(&service_uuid);fields.num_uuids128=1;fields.uuids128_is_complete=1;
    ble_gap_adv_set_fields(&fields);
    ble_hs_adv_fields scan{};scan.name=reinterpret_cast<const uint8_t*>(config.id);scan.name_len=strlen(config.id);scan.name_is_complete=1;
    ble_gap_adv_rsp_set_fields(&scan);ble_gap_adv_params p{};p.conn_mode=BLE_GAP_CONN_MODE_UND;p.disc_mode=BLE_GAP_DISC_MODE_GEN;
    p.itvl_min=now_ms()<30000?160:1600;p.itvl_max=p.itvl_min+160;
    ble_gap_adv_start(own_address_type,nullptr,now_ms()<30000?int32_t(30000-now_ms()):BLE_HS_FOREVER,&p,event,nullptr);
}
static void sync(){ble_hs_id_infer_auto(0,&own_address_type);advertise();}
static void host(void*){nimble_port_run();nimble_port_freertos_deinit();}
void radio_start(){
    result_lock=xSemaphoreCreateMutex();samples=xQueueCreate(1,sizeof(Sample));commands=xQueueCreate(1,sizeof(Command));
    configASSERT(result_lock&&samples&&commands);psa_crypto_init();ESP_ERROR_CHECK(nimble_port_init());
    ble_hs_cfg.sync_cb=sync;ble_hs_cfg.sm_io_cap=BLE_HS_IO_DISPLAY_ONLY;ble_hs_cfg.sm_bonding=1;ble_hs_cfg.sm_mitm=1;ble_hs_cfg.sm_sc=1;
    ble_hs_cfg.sm_our_key_dist=BLE_SM_PAIR_KEY_DIST_ENC|BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist=BLE_SM_PAIR_KEY_DIST_ENC|BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.store_status_cb=ble_store_util_status_rr;ble_store_config_init();ble_svc_gap_init();ble_svc_gatt_init();ble_svc_gap_device_name_set(config.id);
    const ble_uuid128_t* uuids[]={&sample_uuid,&info_uuid,&control_uuid,&result_uuid};
    uint16_t flags[]={BLE_GATT_CHR_F_NOTIFY,BLE_GATT_CHR_F_READ,
        uint16_t(BLE_GATT_CHR_F_WRITE|BLE_GATT_CHR_F_WRITE_ENC|BLE_GATT_CHR_F_WRITE_AUTHEN),
        uint16_t(BLE_GATT_CHR_F_READ|BLE_GATT_CHR_F_READ_ENC|BLE_GATT_CHR_F_READ_AUTHEN|BLE_GATT_CHR_F_NOTIFY)};
    for(int i=0;i<4;++i){characteristics[i].uuid=&uuids[i]->u;characteristics[i].access_cb=access;characteristics[i].flags=flags[i];characteristics[i].arg=reinterpret_cast<void*>(intptr_t(i+2));}
    characteristics[0].val_handle=&sample_handle;characteristics[3].val_handle=&result_handle;
    services[0].type=BLE_GATT_SVC_TYPE_PRIMARY;services[0].uuid=&service_uuid.u;services[0].characteristics=characteristics;
    configASSERT(ble_gatts_count_cfg(services)==0);configASSERT(ble_gatts_add_svcs(services)==0);
    xTaskCreate(worker,"ble_io",6144,nullptr,3,nullptr);nimble_port_freertos_init(host);
}
}
