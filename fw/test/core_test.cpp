#include "../main/core.hpp"
#include <cassert>
#include <iostream>
#include <string>

int main() {
    using namespace hps;
    assert(pressure(-16000,0,20000000)==0);
    assert(pressure(0,0,20000000)==10000000);
    assert(pressure(16000,0,20000000)==20000000);
    Sample sample;sample.flags=valid;sample.seq=0xffffffff;sample.uptime_ms=0x12345678;sample.pressure_pa=0;sample.raw=-16000;
    const std::array<uint8_t,20> expected={2,1,255,255,255,255,0x78,0x56,0x34,0x12,0,0,0,0,255,255,255,0,0x80,0xc1};
    assert(encode(sample)==expected);
    Fragments fragments;const std::string message(512,'x');
    for(size_t offset=0;offset<message.size();offset+=14){
        auto count=message.size()-offset;if(count>14)count=14;
        uint8_t b[20]{};put(b,5,2);put(b+2,uint32_t(offset),2);put(b+4,512,2);memcpy(b+6,message.data()+offset,count);
        assert(fragments.add(b,count+6,100+offset)==(offset+count==512?1:0));
    }
    assert(std::string(fragments.data.data())==message);
    uint8_t start[]={1,0,0,0,2,0,'a'},end[]={1,0,1,0,2,0,'b'};
    assert(fragments.add(start,sizeof(start),100)==0);
    assert(fragments.add(end,sizeof(end),2101)==-1);
    assert(fragments.add(end,sizeof(end),2102)==-1);
    assert(fragments.add(start,sizeof(start),3000)==0);
    assert(fragments.add(end,sizeof(end),3100)==1);
    HeldButton button;assert(!button.update(true,100));assert(!button.update(true,1599));assert(button.update(true,1600));assert(!button.update(true,4000));assert(!button.update(false,4100));
    // The sensor write command has exactly 5 transmitted bytes plus the address in the CRC.
    const uint8_t bytes[]={0xda,0x22,uint8_t(0x10|crc4(0x22,0x10)),0x93,0x8b};
    auto whole=crc8(bytes,5);assert(crc8(bytes+3,2,crc8(bytes,3))==whole);
    std::cout << "Firmware codec, pressure range, fragment limits/timeouts and button tests passed.\n";
}
