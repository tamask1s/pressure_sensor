#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <climits>

namespace hps {
constexpr uint8_t valid = 1, rtc_valid = 2, sd_active = 4, sd_error = 8,
                  battery_low = 16, sensor_error = 32;
struct Sample {
    uint32_t seq = 0;
    uint64_t uptime_ms = 0;
    int64_t utc_ms = 0;
    int32_t pressure_pa = INT32_MIN;
    int16_t raw = 0;
    uint16_t battery_mv = UINT16_MAX;
    uint8_t soc = UINT8_MAX, flags = 0;
};
inline void put(uint8_t* p, uint32_t v, size_t n) {
    for (size_t i = 0; i < n; ++i) p[i] = uint8_t(v >> (i * 8));
}
inline uint16_t u16(const uint8_t* p) { return p[0] | (uint16_t(p[1]) << 8); }
inline std::array<uint8_t,20> encode(const Sample& s) {
    std::array<uint8_t,20> b{};
    b[0] = 2; b[1] = s.flags;
    put(b.data()+2,s.seq,4); put(b.data()+6,uint32_t(s.uptime_ms),4);
    put(b.data()+10,uint32_t(s.pressure_pa),4); put(b.data()+14,s.battery_mv,2);
    b[16] = s.soc; put(b.data()+18,uint16_t(s.raw),2);
    return b;
}
inline uint8_t crc8(const uint8_t* data,size_t n,uint8_t seed=0xff) {
    for(size_t i=0;i<n;++i) {
        seed ^= data[i];
        for(int b=0;b<8;++b) seed = (seed & 0x80) ? uint8_t((seed<<1)^0xd5) : uint8_t(seed<<1);
    }
    return seed;
}
inline uint8_t crc4(uint8_t reg,uint8_t size) {
    uint8_t c=15, b[2]={reg,size};
    for(int i=0;i<12;++i) {
        bool different=((c>>3)&1) != ((b[i/8]>>(7-i%8))&1);
        c=uint8_t(((c<<1) ^ (different?3:0))&15);
    }
    return c;
}
struct Fragments {
    std::array<char,513> data{};
    uint16_t id=0, size=0, used=0;
    uint64_t start=0;
    void clear(){ id=size=used=0; start=0; }
    // -1 invalid, 0 partial, 1 complete.
    int add(const uint8_t* p,size_t n,uint64_t now) {
        if(n<7 || n>20) { clear(); return -1; }
        auto rid=u16(p),offset=u16(p+2),total=u16(p+4);
        if(!rid || !total || total>512 || offset+n-6>total) { clear(); return -1; }
        if(offset==0){ clear(); id=rid;size=total;start=now; }
        if(id!=rid || size!=total || used!=offset || now-start>2000){clear();return -1;}
        memcpy(data.data()+used,p+6,n-6);used=uint16_t(used+n-6);data[used]=0;
        return used==size?1:0;
    }
};
struct HeldButton {
    uint64_t since=0; bool fired=false;
    bool update(bool down,uint64_t now,uint64_t hold=1500) {
        if(!down){since=0;fired=false;return false;}
        if(!since) since=now;
        if(!fired && now-since>=hold){fired=true;return true;}
        return false;
    }
};
inline int32_t pressure(int16_t raw,int32_t min_pa,int32_t max_pa) {
    return min_pa + int32_t(((int64_t(raw)+16000)*(max_pa-min_pa)+16000)/32000);
}
}
