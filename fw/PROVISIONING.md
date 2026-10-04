# Készülék előkészítése

Készülékenként egyszer, aktivált ESP-IDF 6.0.2 környezetből. A gyári alap-MAC adja az ID-t: `hps-` + 12 kisbetűs hex. A tényleges szenzorsorozatszámot és nyomástartományt ellenőrizd; 200 bar csak a V1 feltételezése volt.

```sh
python -m esptool --chip esp32 --port COM7 read-mac
python -c "import secrets; print(secrets.token_hex(32)); print(f'{secrets.randbelow(1000000):06d}')"
```

A második parancs egyedi 32 bájtos titkot és hatjegyű BLE PIN-t ad. Ezeket csak védett helyen őrizd. Készíts `provisioning/hps-<mac>/nvs.csv` fájlt; a jelölt értékeket cseréld le:

```csv
key,type,encoding,value
hps,namespace,,
secret,data,hex2bin,<64 hex karakter>
pin,data,u32,<PIN egész számként>
min_pa,data,i32,<minimum Pa>
max_pa,data,i32,<maximum Pa>
verified,data,u8,1
sd,data,u8,0
```

`verified=1` csak ellenőrzött tartományhoz; különben 0. A PIN-címkén a kezdő nullákat is tüntesd fel. Tartomány: `0 ≤ min_pa < max_pa ≤ 60000000`, 1 bar = 100000 Pa.

A gyökérből, PowerShellben, aktivált IDF-környezetben:

```powershell
python "$env:IDF_PATH/components/nvs_flash/nvs_partition_generator/nvs_partition_gen.py" generate provisioning/hps-<mac>/nvs.csv provisioning/hps-<mac>/nvs.bin 0x6000
python -m esptool --chip esp32 --port COM7 write-flash 0x9000 provisioning/hps-<mac>/nvs.bin
```

A service admin-importja ugyanazt a titkot és a tényleges készülékadatokat kapja:

```json
{
  "device_id": "hps-<mac>",
  "secret_hex": "<64 hex karakter>",
  "sensor_serial": 123456,
  "protocol_version": 2,
  "calibration": {
    "profile_id": "hps-<mac>-<min_pa>-<max_pa>",
    "sensor_serial": 123456,
    "range_min_pa": 0,
    "range_max_pa": 20000000,
    "scale": 1,
    "offset_pa": 0,
    "verified": true
  }
}
```

A számok helyőrző példák. A titok, az NVS-kép és az importfájl nem kerülhet Gitbe vagy a klienshez. Az NVS újraírása a bondokat és beállításokat is törli; normál firmware-frissítésnél hagyd meg. Tulajdonosváltáshoz service-admin átadás és új kulcs/PIN kell. A jelenlegi NVS nincs flash-titkosítva.
