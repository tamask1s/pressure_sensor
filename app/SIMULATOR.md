# Windows eszközszimulátor

A [GitHub Build and test](https://github.com/tamask1s/pressure_sensor/actions/workflows/build.yml) legfrissebb sikeres `main` futásánál, az **Artifacts → windows** csomagot töltsd le GitHub-belépés után. Bontsd ki az egész ZIP-et, majd indítsd a **`pressure_simulator.exe`** fájlt. Elindítja a Windows appot szimulációs módban; az app bezárásakor leáll. Ugyanaz a Flutter app és mérési/feltöltési kód fut, mint Androidon. Egy szimulátor már **két érzékelőt** ad; egy párhoz egy példány elég. Bluetooth vagy Python nem kell.

1. **Mérés fiók nélkül** → **Tesztpár előkészítése** → **Mérés indítása**.
2. Az Élő mérés lapon kapcsolható a GPS, haladás, A/B elérhetőség, szenzorhiba; választható változó vagy rögzített nyomás, illetve eszköz-újraindítás.
3. A Térkép és Mérések lap ugyanazt a rögzítést, hőtérképet és CSV-exportot használja, mint éles mérésnél. GPS nélkül is rögzít; csak a hely nélküli minták maradnak le a térképről.

Két redundáns érzékelő, egyenként 10 Hz, 0–200 bar; 10 km/h-s oda-vissza menetek egy példa-területen, Magyarországon. A szimuláció külön helyi adatbázist, beállításokat és belépési adatokat használ. A mérések neve `SIM ·` kezdetű. A tesztpár előkészítése 120 másodpercre nyitja meg a claim-ablakot.

## Service-próba

A gyártói előkészítés és a vásárlói párosítás két külön lépés. Eladás előtt az eszköz azonosítóját és titkát egyszer a service-be kell importálni. Utána a vásárló csak az appban párosít. A szimulátor friss, véletlen eszközöket generál, ezért ezekhez is kell az egyszeri előkészítés.

1. Indítsd a szimulátort. Az első indítás létrehozza a **privát** `%LOCALAPPDATA%/PressureFieldSimulator/default/devices.simulator.json` fájlt két eszközzel. A [webes felületen](https://timeonion.com/pressure_sensor/) adminnal belépve: **Admin → JSON kiválasztása és ellenőrzése → Importálás**. Válaszd ezt a fájlt; sikeres import után a készülékek „regisztrált” állapotúak. Azonos fájl ismételt importja ártalmatlan. A fájlt őrizd meg, ne tedd Gitbe vagy nyilvános tárhelyre. Újraindításkor ugyanazok az eszközök maradnak.
2. Az app **Szolgáltatás címe** mezőjébe pontosan ezt írd: `https://timeonion.com/pressure_sensor/api/v1`. Lépj be a megerősített tesztfiókoddal.
3. **Tesztpár előkészítése** → **Mérés indítása**. Hagyd bekapcsolva a **GPS** és **Traktor halad** kapcsolót, mérj legalább egy percet, majd **Mérés leállítása**. Várd meg: **Feltöltés rendben · 0 minta vár feltöltésre**.
4. A [webes felületen](https://timeonion.com/pressure_sensor/) ugyanazzal a fiókkal a **Mérések** lapon keresd a `SIM ·` mérést, majd nyisd meg a **Térkép** lapot. GPS kikapcsolásával is van időbélyeges feltöltés, csak a hely nélküli minták nem rajzolhatók térképre.

Ha a párosítás `claim_unavailable` / ütközés hibával megáll, ellenőrizd az importot: pontosan ennek a gépnek és profilnak az eszközei legyenek előkészítve, és ne tartozzanak másik fiókhoz. Nyomd meg újra a tesztpár gombját az import után. A szerver külön Python-szimulátorcsomagja más eszközazonosítókat tartalmaz; annak előkészítése nem regisztrálja automatikusan a Windows-szimulátort.

Hálózatkimaradás után a feltöltési sor folytatódik. A helyi, fiók nélküli mód korábbi mérései nem kerülnek át a fiókba.

Második párhoz indíts más profilt és portot; az új importfájlt is töltsd be, és lépj be ugyanabba vagy másik tesztfiókba:

```powershell
.\pressure_simulator.exe --profile=traktor2 --port=47833
```

Az app és szimulátor **egy gépen** fut, csak `127.0.0.1` WebSocket-kapcsolattal, szimulátoronként egy appal. A service lehet távoli. A 20 bájtos BLE-mintákat az app rendes dekódere dolgozza fel, az időegyeztetés és HMAC is a szerződést követi. A rádió, GATT-fragmentálás, Bluetooth PIN/bond, fizikai szenzor, RTC és SD-kártya működését ez nem igazolja; SD/azonosítás csak szimulált állapot.

## Fejlesztés

A repó Flutter 3.35.4 / Dart 3.9.2 környezetével, az `app/` könyvtárból:

```powershell
flutter pub get --enforce-lockfile
dart run bin/simulator.dart --headless
# Másik terminálban:
flutter build windows --release
.\build\windows\x64\runner\Release\pressure_field.exe --simulator
# Csomagolás, a Windows build után:
dart compile exe bin/simulator.dart -o build/windows/x64/runner/Release/pressure_simulator.exe
```

A `--headless` csak a szimulátort indítja; leállítás Ctrl+C. Egyedi app-port: `--simulator-port=47833`.

A GitHub workflow futtatja a protokoll/claim-, újracsatlakozási, GPS nélküli és SQLite→feltöltés teszteket, és mindkét EXE-t a Windows-csomagba teszi. A CI service-válaszai helyettesítettek.

2026-10-04: a helyi Windows-szimulátor EXE és a Flutter app valódi capture/SQLite/feltöltési kódja sikeresen használta az éles service-t: adminimport, HMAC-claim, pár, élő státusz, 660 feltöltött minta (439 GPS-szel, 221 helyadat nélkül), lezárás és üres feltöltési sor. A CSV 660 sort, a közös hőtérkép 8 cellát adott; a mérés és a térkép az éles Flutter weben, Edge-ben is látható, JavaScript-hiba nélkül. A próbához a natív pluginhívásokat helyettesítő tesztfuttató kapcsolódott a külön szimulátorfolyamathoz; a Windows app teljes kattintásos próbáját ez nem helyettesíti.

Az integráció közben javítottuk a GPS-hozzárendelés pontosságát: a számítás megtartja a feltöltött GPS-időpontok mikroszekundumait. Régebbi app `invalid_location` hibát adhat; használd a javítást tartalmazó legfrissebb sikeres buildet. A regressziós eset a GitHub-tesztek része. A service ehhez nem igényelt módosítást.
