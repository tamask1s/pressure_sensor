# Talajnyomás service

Web: **https://timeonion.com/pressure_sensor/**

API: **https://timeonion.com/pressure_sensor/api/v1**

OpenAPI: `/pressure_sensor/api/v1/openapi.json`

A meglévő Flutter webet szolgálja ki. Fiókonként külön eszközök/párok, e-mail-megerősítés, HMAC-eszközclaim, offline kötegek, GPS nélküli mérés, CSV, időbeli aggregáció és közös nyomáshőtérkép. A web 5 másodpercenként frissíti az állapotot; a gyűjtő 10 másodpercenként küld presence-t, amely 30 másodperc után lejár. A térképen **nyomás**, nem hitelesített talajtömörségi százalék látható.

## Helytakarékos telepítés

A felhasználó 2026-10-04-i kérése alapján a korábbi PostgreSQL/PostGIS-tervtől eltérően **SQLite WAL + pyproj** működik. Ugyanaz a rácsalgoritmus és HTTP-szerződés marad. Nincs új DB-szerver, Docker vagy Flutter SDK a hoston. A `/opt/mesemondo/venv/bin/python` és meglévő FastAPI/cryptography csomagok csak olvasva újrahasznosítva; új függőség egy külön pyproj könyvtár. A másik alkalmazás venv-jét tilos e projektből módosítani. A közös futtatókörnyezet későbbi cseréjénél a pressure tesztjeit is futtatni kell.

- Service: `pressure_sensor.service`, saját `pressure-sensor` OS-felhasználó, `127.0.0.1:8093`.
- Forrás/web: `/opt/pressure_sensor/current/service`; verziózott kiadások `/opt/pressure_sensor/releases` alatt.
- Adatok: `/var/lib/pressure_sensor/pressure.sqlite3`, csak a saját service számára írható.
- Titkok: `/etc/pressure_sensor/service.env`, `smtp-password`; Gitben nincsenek.
- E-mail: a sinsigra SMTP-szolgáltatója, saját másolatban tárolt hitelesítő adat; nincs változás a sinsigra konfigurációjában.
- Nginx: `/etc/nginx/timeonion-services/pressure_sensor.conf`. Az apex domain általános www-átirányítása alól csak ez az útvonal kivétel. A többi útvonal átirányítása és a többi snippet változatlan.
- Korlátok: egy worker, legfeljebb 16 egyidejű kérés, 256 MB memória, 50% CPU; 512 KiB/kérés. 64 MiB szabad lemez alatt a feltöltés 503-at kap, az app tartós feltöltési sora megőrzi az adatot. A korlát nem helyettesít tárhelyfigyelést.

Telepítés ezen a hoston: `sudo python3 service/ops/deploy.py`. Előtte tesztek, és `service/web/` valamint `service/.deps/` előkészítése szükséges. A script `nginx -t` után tölt újra, hiba esetén a konfigurációt visszaállítja; a meglévő másik két szolgáltatást nem indítja újra. A régi kiadás megmarad. Újratelepítés nem hoz létre új kulcsot/adatbázist.

## Windows eszközszimulátor

A [Windows-szimulátor](../app/SIMULATOR.md) a Flutter app teljes mérési és feltöltési útját használja. A service admin-importja fogadja az általa létrehozott `devices.simulator.json` JSON-listát, változtatás nélkül. A fájl eszköztitkokat tartalmaz: védett csatornán add át az adminnak, és tesztkörnyezetbe importáld:

```sh
python -m pressure.admin import /vedett/hely/devices.simulator.json
```

A parancshoz a kiválasztott környezet `PRESSURE_DB` és `PRESSURE_KEY` beállítása szükséges. Az appban az adott környezet HTTPS API-címét add meg; a telepített service címe `https://timeonion.com/pressure_sensor/api/v1`. Nincs külön szimulátoros API vagy hitelesítési kivétel. A Windows-szimulátorral végzett teljes szerveres mérési próba külön ellenőrzés; az alábbi Python-program az API integrációs próbája.

## Python API-szimulátor a saját gépeden

Python 3 kell, **pip-telepítés nem szükséges**. Regisztrálj a weben és erősítsd meg az e-mailt. A kész privát csomag a szerveren: `service/.runtime/pressure-simulator.zip`. Saját gépre másolás:

```sh
scp graphyt2@timeonion.com:/home/graphyt2/git/pressure_sensor/service/.runtime/pressure-simulator.zip .
```

Bontsd ki, majd futtasd a benne lévő programot. A fájl nincs a nyilvános weben vagy Gitben.

```sh
python simulator.py --email SAJAT_EMAIL --profile simulator-profile.json --seconds 60
```

A jelszót bekéri, nem kerül parancssorba vagy fájlba. Alapból két pár, 4 készülék, 10 Hz/csatorna, élő jelenlét, GPS és változó nyomás. A weben a **SZIMULÁTOR** méréseket keresd; a Térkép nézet egyesíti a párok adatait. A szimulátor HTTP-gyűjtőt utánoz, **nem BLE-hardvert**. Nem alkalmas a valódi szenzor vagy telefonos BLE működésének igazolására.

- `--fast`: várakozás nélkül, múltbeli szintetikus időbélyegekkel tölt fel; nincs hamis élő állapot.
- `--no-gps`: hely nélküli feltöltés; az előzményben látszik, a térképen nem.
- `--register`: regisztráció parancssorból, majd e-mail-megerősítés; utána futtasd nélküle.
- `--url`: másik API URL (alapérték a fenti éles HTTPS-cím).

A profilt egyszer egy fiók veszi tulajdonba; másik fiókhoz külön profil kell. Saját generálás a szerveren:

```sh
sudo bash /opt/pressure_sensor/current/service/ops/admin.sh simulator-profile /tmp/private-simulator.json --pairs 2
```

Az admin parancs importálja a szimulált eszközöket, és 0600 jogosultságú privát fájlt ír. A profilt ne tedd a webkönyvtárba/Gitbe. A szimulátor eszközeinek kalibrációja szándékosan `verified=false`.

## Valódi eszközök

A [provisioning](../fw/PROVISIONING.md) szerinti, eszközbe írt 32 bájtos titokkal és szenzoradatokkal készített JSON-t egyszer importálni kell:

```sh
sudo bash /opt/pressure_sensor/current/service/ops/admin.sh import /vedett/hely/device.json
```

Ezután regisztrált felhasználó az appban a fizikai BLE-párosítási ablak alatt claimel. A privát titok nem API-mező. Tulajdonosváltás: előbb szinkron és lezárás, új hardverkulcs/PIN és bondok törlése, majd `transfer` ugyanilyen importfájllal. A régi tulajdonos előzménye megmarad, de új offline feltöltést már nem fogadunk tőle az átadott eszközhöz.

Natív appban az API-cím `https://timeonion.com/pressure_sensor/api/v1`.

## Mentés és visszaállítás

Naponta `pressure_sensor-backup.timer`: SQLite backup API-val konzisztens másolat, integritásellenőrzés, gzip. Két helyi mentést tart meg `/var/backups/pressure_sensor/` alatt, titkos kulcs külön `restore.env`. A helyi másolat **nem véd a szerver elvesztése ellen**; ezt a könyvtárat és `/etc/pressure_sensor/` tartalmát védett külső helyre kell másolni. Külső mentési cél nem lett megadva. Jelszó-visszaállítás/fióktörlés előtti adatok legfeljebb két mentésben maradhatnak; visszaállításkor az azóta törölt fiókok törlését is alkalmazni kell.

Kézi próba: `sudo systemctl start pressure_sensor-backup.service`.

Visszaállítás: csak a `pressure_sensor.service` leállítása; az aktuális DB és `-wal`/`-shm` fájlok megőrzése külön könyvtárban; a kiválasztott `.sqlite3.gz` kibontása új `pressure.sqlite3`-ba. Ellenőrzés `PRAGMA integrity_check`, a mentéshez tartozó `PRESSURE_KEY` beállítása, `chown pressure-sensor:pressure-sensor`, 0600 fájljogosultság, majd indítás és health-ellenőrzés. Élő WAL-adatbázist egyszerű `cp`-vel ne ments.

A séma első verziója a `pressure/schema.sql`; induláskor idempotensen alkalmazódik. Új sémaváltozáshoz explicit új verzió és migráció szükséges. Ez a kiadás nem módosít meglévő külső DB-sémát.

## Tesztelés és build

```sh
PYTHONPATH=service:service/.deps /opt/mesemondo/venv/bin/python -m pytest service/tests -q
PRESSURE_SOAK=1 PYTHONPATH=service:service/.deps /opt/mesemondo/venv/bin/python -m pytest service/tests -q -s
```

A tesztek ideiglenes DB-t és teszt e-mail outboxot használnak, nem küldenek levelet. A soak 576 000 teljes mintát HTTP API-n keresztül ír és térképet kér. A mentés-visszaállítás külön, 400 mintás teszten is lefut; a nagy adatbázist csak elegendő szabad hely esetén duplázza. A visszaállított DB-n ugyanazt az API-eredményt ellenőrzi.

A jelenlegi Flutter artifact a GitHub `37185480118` futás `web` artifactja (`731e617974b19f231c2a14104b47ca2ee0c356c7` commit). Letöltés után SHA256-ellenőrzés, a base href, az egyszer előforduló API-prefix és a domainre korlátozott Referer-policy átírása történik `ops/prepare_web.py`-ban. A forrás és a GitHub workflow már a helyes prefixet tartalmazza; a következő buildhez:

```sh
cd app
flutter build web --release --no-web-resources-cdn --pwa-strategy=none --base-href=/pressure_sensor/ --dart-define=API_URL=/pressure_sensor/api/v1
```

[FastAPI proxy/root_path dokumentáció](https://fastapi.tiangolo.com/advanced/behind-a-proxy/), [SQLite WAL](https://www.sqlite.org/wal.html), [SQLite backup API](https://docs.python.org/3/library/sqlite3.html#sqlite3.Connection.backup).

A web `strict-origin` Referer-policyt használ: az alaptérkép csak a domaint kapja meg, e-mail-tokenes útvonalat/lekérdezést nem. Ez megfelel az [OSM csempehasználat](https://operations.osmfoundation.org/policies/tiles/) webes Referer-követelményének.

A mért nyers adattárolási igény kb. **720 MB / két eszköz / 8 óra**. A jelenlegi kis szerveren hosszú távú terepi gyűjtéshez több tárhely vagy rendszeres archiválás szükséges; a service nem töröl automatikusan mérési adatot.
