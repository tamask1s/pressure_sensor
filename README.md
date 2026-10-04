# Talajnyomás

ESP32 C++ firmware (`fw/`), Flutter Android/Windows/web kliens (`app/`), és a [működő service, telepítés és szimulátor](service/README.md). Automatikus GPS-hozzárendelés; GPS nélkül is időbélyeges mentés és feltöltés.

[Használat és build](BUILD.md) · [Windows eszközszimulátor](app/SIMULATOR.md) · [Rendszerterv](SYSTEM.md) · [BLE-szerződés](contracts/ble.md) · [GitHub build és tesztek](https://github.com/tamask1s/pressure_sensor/actions/workflows/build.yml). A workflow Windows-, Android-, web- és ESP32-csomagot készít, hét napig letölthető artifactként. A nagy tárolási próba kézi indításkor választható.

A Windows-szimulátor külön folyamatként, két eszközzel, GPS-szel és újracsatlakozással kipróbálva; a kliens-, protokoll- és SQLite→feltöltés tesztek sikeresek. A service éles címe https://timeonion.com/pressure_sensor/; az API-szimuláció, webes térkép és mentés ellenőrzéseit a [tesztjelentés](service/VALIDATION.md) részletezi. A Windows-szimulátor → Flutter mérési kód → éles service → webes hőtérkép próba sikeres; részletek a [szimulátor útmutatójában](app/SIMULATOR.md). Valódi BLE-hardveres és képernyőzáras terepi próba még szükséges. Az Android APK tesztkulcsos.
