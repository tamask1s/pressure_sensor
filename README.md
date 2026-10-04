# Talajnyomás

ESP32 C++ firmware (`fw/`), Flutter Android/Windows/web kliens (`app/`), és a külön elkészítendő service [terve, interfésze és Codex-promptja](service/CODEX_PROMPT.md). Automatikus GPS-hozzárendelés; GPS nélkül is időbélyeges mentés és feltöltés.

[Használat és build](BUILD.md) · [Rendszerterv](SYSTEM.md) · [BLE-szerződés](contracts/ble.md) · [GitHub build és tesztek](https://github.com/tamask1s/pressure_sensor/actions/workflows/build.yml). A workflow Windows-, Android-, web- és ESP32-csomagot készít, hét napig letölthető artifactként. A nagy tárolási próba kézi indításkor választható.

Helyben mind a négy kiadás lefordult; 15 kliens- és a natív C++ teszt sikeres, az 576 000 mintás szintetikus SQLite-próba is. Valódi kétkészülékes, képernyőzáras és service-integrációs próba még szükséges. A service itt specifikáció, az Android APK tesztkulcsos.
