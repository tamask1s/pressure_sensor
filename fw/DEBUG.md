# Hardverteszt soros portról

A `esp32-firmware-debug` GitHub artifact tartalmazza a konzolt. A normál firmware-ből ez kimarad; az app önálló/felhős buildválasztása ettől független.

Saját build ESP-IDF 6.0.2-vel, a `fw/` könyvtárban, külön konfigurációval:

```sh
idf.py -B build-debug -D SDKCONFIG=sdkconfig.bench -D "SDKCONFIG_DEFAULTS=sdkconfig.defaults;sdkconfig.debug" build
idf.py -B build-debug -p COM7 flash monitor
```

UART0, 115200 baud, sorvége Enter. Egy parancs/sor, legfeljebb 127 karakter. Induláskor minden valódi hardveren működik; a tesztmód külön aktiválandó.

1. `status`: eszközazonosító, provisioning, BLE/párosítás, szenzor, RTC, SD, hibaszámlálók, gombszintek.
2. `debug on`: engedélyezi a tesztparancsokat; a lebegő gombbemenetek műveleteit letiltja.
3. Csak előkészítetlen próbapanelen: `provision 123456`. Véletlen privát kulcsot és a megadott PIN-t ment, majd újraindul. Meglévő azonosítást nem ír felül; a kulcsot nem írja ki. Ez tesztazonosság, nem gyártási provisioning.
4. Újra `debug on`, majd `sensor 0`, `pair`. Az appban csatlakoztasd a készüléket a választott PIN-nel. A szimulált nyomás 100 bar az alapértelmezett 0–200 bar tartományban. Szenzor, RTC és SD nélkül is tesztelhető a titkosított BLE és a telefonos napló.

| Parancs | Művelet |
|---|---|
| `help`, `status` | Súgó, állapot; debug aktiválása nélkül is |
| `debug on`, `debug off` | Tesztfelülírások engedélyezése / törlése |
| `pair` | 120 s párosítási ablak, fizikai gomb nélkül |
| `sensor -16000` … `sensor 16000` | Állandó nyers tesztadat; 0–200 bar az alaptartományban |
| `sensor real`, `sensor error` | Valódi szenzor / injektált szenzorhiba |
| `battery 2800` … `battery 4200`, `battery real` | Akkufeszültség szimulációja / valódi ADC |
| `led 0` … `led 31`, `led auto` | Bitmaszk: R=1, G=2, B=4, SD=8, BT=16; automatikus jelzés |
| `buttons on`, `buttons off` | Fizikai gombműveletek engedélyezése / tiltása |
| `monitor on`, `monitor off` | GPIO34/35 változásainak soros naplózása |
| `sd on`, `sd off` | Valódi SD-napló; a beállítás újraindítás után is megmarad |
| `time 1790000000000` | Szoftveres UTC és a valódi RTC íráspróbája |

A tesztfelülírások újraindításkor elvesznek; az SD-beállítás és az egyszer előkészített identitás marad. A mesterséges mérés BLE/SD flagje bit6 (`simulated`), az app jelzi, a CSV megőrzi. Régi app ezt a bővítést még nem fogadja el: a debug firmware-hez az új app szükséges. A telefonos szimulátor továbbra is külön, `SIM` nevű méréseket készít.

Puszta devboardnál a GPIO34/35 bemeneteknek nincs belső felhúzójuk: gombteszthez külső felhúzás kell, például 10 kΩ 3,3 V-ra, gomb a földre. [Espressif GPIO-leírás](https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/peripherals/gpio.html). Az I²C-nek is külső felhúzás kell. Az SD/RTC/szenzor hiánya nem hitelesítési hiba; a PIN/kulcs hiánya viszont szándékosan tiltja a biztonságos BLE-kapcsolatot. A soros állapot elkülöníti ezeket; Dani konkrét paneljének hibáját hardveres próba nélkül nem lehet biztosan megállapítani.

A részleges I²C/ADC-inicializálási hiba nem állítja le a BLE-t. NVS-, memória- vagy BLE-alaprendszer-hibából továbbra sem következik működőképes készülék; a gyártási identitást nem töröljük automatikusan.
