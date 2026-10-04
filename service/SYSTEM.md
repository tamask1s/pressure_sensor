# Service – rendszerterv

2026-10-03 · A service-t másik Codex valósítja meg; a Flutter kliens elkészült. A teljes rendszer: [../SYSTEM.md](../SYSTEM.md); szerződés: [INTERFACE.md](INTERFACE.md).

## Feladat és felépítés

E-mailes fiókok; eszköztulajdon és párok; offline gyűjtött nyomás/GPS adatok fogadása; aktuális állapot, előzmény, közös fiókhőtérkép és CSV-export. Az ESP32 kizárólag az appal beszél; a service nem BLE-központ.

Javaslat: egy [FastAPI](https://fastapi.tiangolo.com/) alkalmazás, SQLAlchemy/Alembic, PostgreSQL + PostGIS, SMTP, HTTPS reverse proxy. A proxy szolgálja ki az app-projektből származó Flutter web buildet is, az API-val azonos originen. Kezdetben egy service + egy adatbázis; nincs külön üzenetsor. E-mailhez tartós adatbázisos outbox és egy egyszerű újrapróbáló worker elegendő.

## Tárolás és invariánsok

| Entitás | Lényeg |
|---|---|
| `accounts`, `auth_sessions`, `email_tokens` | Ellenőrzött e-mail, Argon2id jelszóhash, lejáró/visszavonható munkamenetek; e-mail-tokenek hashként |
| `devices`, `device_ownerships`, `claim_challenges` | Egyedi hardver-ID, titkosított eszköztitok, legfeljebb egy aktív tulajdon; egyszer használható challenge |
| `rigs`, `rig_members` | Fiókhoz tartozó pár, A/B; egy eszköz legfeljebb egy aktív párban |
| `measurement_sessions`, `session_devices` | Kliens-UUID, gyűjtő-ID, állapot; pártagok és kalibráció megváltoztathatatlan pillanatképe |
| `time_segments`, `gps_fixes`, `samples` | Nyers időhorgonyok és GPS; eszköz/boot/seq szerint egyedi minták, WGS84-hely vagy NULL |
| `device_presence` | Gyűjtő és élő készülékállapot, friss jelenlétjelzés alapján; nem feltöltött előzményből |
| `email_outbox` | Küldendő levelek, próbálkozás, következő időpont; token/titok nem alkalmazásnapló |

Minden felhasználói adat `account_id`-hoz kötött. Az aktuális fiók az ellenőrzött munkamenetből jön, nem a kérés törzséből. Minden azonosítókeresés, összekapcsolás, export és térképlekérdezés fiókra szűr; a DB összetett idegen kulcsai is akadályozzák a fiókok közti hivatkozást. A telepített alkalmazás nem DB-superuserrel fut.

A minta és munkamenet tulajdonosi pillanatképe megmarad eszközátadáskor. Első kiadásban tulajdonosváltás admin CLI-vel, előzetes szinkronnal és új eszközkulccsal; korábbi offline feltöltési jog megszűnik, elutasított helyi adat exportálható. Eszköz- vagy párátnevezés/archiválás nem töröl előzményt.

## Auth és adatkezelés

E-mail-megerősítés és jelszó-visszaállítás rövid életű, egyszer használható tokennel; válaszok nem árulják el, létezik-e az e-mail. Natív kliens: 15 perces access token + legfeljebb 30 napos, forgatott refresh token. Web: szerveroldali session, `Secure`, `HttpOnly`, `SameSite` cookie, módosításoknál CSRF-token + Origin-ellenőrzés. Kijelentkezés visszavon; a web nem tárol auth-titkot localStorage-ban.

TLS, kérésméret- és sebességkorlát, auth/claim rate limit, titkok környezeti konfigurációban; koordináták és jelszavak nem kerülnek normál naplóba. CSV-exportban a felhasználói szöveg nem válhat táblázatképletté. Fióktörlés újrahitelesítéssel, kapcsolódó mérések törlésével és a kezelt mentések megőrzési rendjének jelzésével; az eszköz másnak újra csak ellenőrzött átadással adható.

## Feltöltés, térkép, állapot

Kötegenként egy DB-tranzakció, tartós commit utáni siker. Egyedi mintaazonosító és tartalomegyezés alapján idempotens; eltérő ismétlés konfliktus. Szinkronizáló kliens esetén is minden eszköz tulajdonát ellenőrizni kell. A session lezárása a ténylegesen tárolt mintaszámot ellenőrzi.

Indexek: `(account_id, session_id, captured_at)`, `(device_id, boot_id, seq)` egyedi, időszűrés és PostGIS térindex. Először normál táblák és korlátos lekérdezések; particionálás csak mért igény alapján.

A hőtérkép a főterv §7 algoritmusa: érvényes mozgó minták → másodperces csatornaátlag → párátlag → session/cella átlag → sessionök egyenlő súlyú átlaga. A válasz metrikus UTM-rácsot és WGS84 cellageometriát ad, közös skálával. Lapozás/cellakorlát kötelező. Az alapadat az igazság; gyorsító aggregátum később bevezethető ugyanazzal a szerződéssel.

A friss jelenlét 30 s-ig érvényes, és az adott gyűjtő érvényes lease-éhez kötött. A készülék „friss adat” állapotához a legutóbbi jelenlétjelzésben a BLE-minta a megfigyeléskor legfeljebb 2 s-os lehetett. Ez dátumozott állapotpillanatkép; a UI annak korát is mutatja. Régi köteg feltöltése csak a szinkron állapotát módosítja. Böngészős állapotfrissítés öt másodperces lekérdezéssel.

## Átadás és üzemeltetés

A service-fejlesztő adja: futó forrás, verziózárt függőségek, migrációk, OpenAPI, demo-adatok két fiókkal/két párral, contract- és jogosultsági tesztek, Docker Compose, titok nélküli `.env.example`, eszközprovisioning-import CLI, health/readiness végpont, rövid indítás/mentés/visszaállítás leírás. A web forrását a kliensprojekt szállítja; ennek buildjét kell kiszolgálni.

Konfiguráció: adatbázis-URL, publikus web/API origin, session/aláírási kulcs, eszköztitkok titkosítási kulcsa, SMTP, címzettkorlátok, mentési cél. Kliens buildváltozók: `API_URL` (weben alapból `/api/v1`), `TILE_URL`; szolgáltatói attribúció a térképkomponensben. Első mérési cél: 10 egyidejű pár (200 minta/s), kötegelt forgalom; mérendő, nem igazolt kapacitás. A webre `Cache-Control: no-store` auth/API-válaszoknál, `index.html`-re újraellenőrzés, mérsékelt CSP és `Referrer-Policy: no-referrer` kell; ne cache-elj felhasználói adatot közös proxyban.

Élesítés feltétele: idegen fiók adataihoz minden útvonalon tiltás, duplikált/hálózathibás feltöltés tesztje, egyszer használható claim, 576 000 mintás lekérdezési próba, mentésből visszaállítás és a tényleges appal közös integráció. A szolgáltató/domain és az üzemeltetési keret még egyeztetendő.
