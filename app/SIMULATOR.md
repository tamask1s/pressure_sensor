# Windows eszközszimulátor

A GitHub `windows` csomagját bontsd ki, majd indítsd a **`pressure_simulator.exe`** fájlt. Elindítja az appot szimulációs módban; az app bezárásakor leáll. Nem kell Bluetooth vagy új telepítés.

1. **Mérés fiók nélkül** → **Tesztpár előkészítése** → **Mérés indítása**.
2. Az Élő mérés lapon kapcsolható a GPS, haladás, A/B elérhetőség, szenzorhiba; választható változó vagy rögzített nyomás, illetve eszköz-újraindítás.
3. A Térkép és Mérések lap ugyanazt a rögzítést, hőtérképet és CSV-exportot használja, mint éles mérésnél. GPS nélkül is rögzít; csak a hely nélküli minták maradnak le a térképről.

Két redundáns érzékelő, egyenként 10 Hz, 0–200 bar; 10 km/h-s oda-vissza menetek egy példa-területen, Magyarországon. A szimuláció külön helyi adatbázist, beállításokat és belépési adatokat használ. A mérések neve `SIM ·` kezdetű. A tesztpár előkészítése 120 másodpercre nyitja meg a claim-ablakot.

## Service-próba

- Az első indítás készít két véletlen eszközazonosítót és egyedi HMAC-titkot: `%LOCALAPPDATA%/PressureFieldSimulator/default/devices.simulator.json`. Ez egy admin-import rekordokból álló JSON-lista, a [meglévő séma](https://github.com/tamask1s/pressure_sensor/blob/main/fw/PROVISIONING.md) szerint. Újraindításkor ugyanazokat használja.
- Ezt a **titkos fájlt** a service admin-importjával töltsd be a **tesztkörnyezetbe**. Ne tedd Gitbe, és ne másold az apphoz. Elvesztése esetén az új szimulátorazonosítókat újra importálni kell.
- Az app szimulációs ablakában add meg a service HTTPS API-címét, lépj be tesztfiókkal, majd készítsd elő a párt. A normál challenge/HMAC-claim, párlétrehozás, presence, offline kötegfeltöltés és lekérdezés fut; nem kell külön service-végpont vagy auth-kivétel.
- Hálózatkimaradás után a sorból folytatódik a feltöltés. A webes felületen ugyanazzal a tesztfiókkal ellenőrizhető. A helyi mód korábbi mérései nem kerülnek át a fiókba.

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

A GitHub workflow futtatja a protokoll/claim-, újracsatlakozási, GPS nélküli és SQLite→feltöltés teszteket, és az EXE-t a Windows-csomagba teszi. A service-válaszok a tesztben helyettesítettek; valódi szerveres integrációhoz a fenti próba kell.
