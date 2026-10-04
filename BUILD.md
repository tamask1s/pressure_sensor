# Használat és build

## Kipróbálás

A GitHub **Actions → Build and test** sikeres futásából töltsd le az artifactokat. Windows: a teljes `windows` csomag kibontása után `pressure_field.exe`. Android: az `android-test-apk` csomag APK-ja, Android 8+. A `web` statikus fájljait a service-szel azonos HTTPS-originről szolgáld ki, API: `/api/v1`.

1. Készülékenként egyszer [USB-előkészítés](fw/PROVISIONING.md).
2. Helyi mód, vagy API HTTPS-cím megadása, regisztráció és e-mail-megerősítés.
3. Eszközök → Hozzáadás; BT-gomb 1,5 s, majd a készülék hatjegyű PIN-je. Két eszközből pár létrehozása.
4. Élő mérés → Mérés indítása. A GPS automatikus; nélküle is készül időbélyeges napló és feltöltés.
5. Mérések: görbe és CSV. Térkép: közös fiókadatok, időszak/pár/csatorna szűrés.

Helyi módban az adatok ezen az eszközön maradnak. Fiókos mérés offline is rögzül, majd ugyanabba a fiókba szinkronizál. Androidon a mérési értesítés visszanyitja az appot a leállításhoz. Windowsban futnia kell az appnak. Hosszú műszakhoz legalább 1 GB szabad hely ajánlott.

## Fordítás

Flutter **3.35.4 / Dart 3.9.2**; Androidhoz JDK 21 és Android SDK 36, NDK 27.0.12077973; Windowshoz Visual Studio 2022 Desktop C++, ATL és Windows SDK. A [workflow](.github/workflows/build.yml) rögzíti a pontos buildlépéseket és minden automatizált tesztet. Az SDK-kat a buildkörnyezet biztosítja.

Az `app/` könyvtárban:

```sh
flutter pub get --enforce-lockfile
flutter build windows --release --no-pub
flutter build apk --release --no-pub
flutter build web --release --no-pub --no-web-resources-cdn --pwa-strategy=none
```

A Windows-parancsot Windowson futtasd. A Flutter szükség esetén előállítja a Gradle wrappert és a pluginregisztrációt. A buildtermékek `app/build/` alatt keletkeznek. Az Android tesztkulcsos; saját kiadási aláíráshoz az ignorált `app/android/key.properties` mezői: `storeFile`, `storePassword`, `keyAlias`, `keyPassword`. GitHubon jelenleg teszt-APK készül, titok nélkül.

Buildkapcsolók: `--dart-define=HAS_GPS=false`, `--dart-define=API_URL=https://host/api/v1`, `--dart-define=TILE_URL=...`. Saját térképszolgáltatóhoz az attribúciót is módosítsd az `app/lib/ui/map.dart` fájlban. A web alapból `/api/v1`; éles API HTTPS-only. A `ALLOW_LOCAL_HTTP=true` kizárólag fejlesztői, loopbackes próbához használható.

Firmware: aktivált **ESP-IDF 6.0.2** környezetből, a repó gyökerében:

```sh
idf.py -C fw set-target esp32
idf.py -C fw build
idf.py -C fw -p COM7 flash
```

A portot igazítsd a géphez. A firmware-frissítés nem írja felül az egyedi NVS-t. CI-ben az Espressif `espressif/idf:v6.0.2` konténere fordít; az artifact `flash_args` fájlja adja a címeket. A lábkiosztás a [rendszertervben](SYSTEM.md).

## Átvételi próba

Két valódi ESP32-vel még szükséges: PIN/bond és újracsatlakozás, szenzortartomány, RTC/akku/SD, 8 órás képernyőzárt Android- és Windows-próba, GPS- és internetkiesés, appkilövés és tárhelyhiba. A dokumentált PTE7300 CRC-hibát kezeli a firmware; a `STATUS_SYNC` további diagnosztikai bitjei gyártói ellenőrzést igényelnek. A service elkészülte után két fiók izolációja, claim, tokenfrissítés, kötegismétlés és több pár közös térképe ellenőrizendő. Részletes elfogadás: [SYSTEM.md §10](SYSTEM.md#10-megvalósítási-sorrend-és-elfogadás).
