# Prompt a service-t megvalósító Codexnek

**A rendszertervet a felhasználó jóváhagyta. A firmware és Flutter kliens már megvalósult.**

Valósítsd meg a Nyomásmérő V2 service-t a saját `service/` könyvtáradban. Olvasd el a mellékelt `SYSTEM.md` és `INTERFACE.md` dokumentumokat, valamint a főprojekt `../SYSTEM.md` fájljának hőtérkép- és mérési szabályait. Ezek az irányadó szerződések; eltérésüket előbb egyeztesd a kliens fejlesztőjével.

Egy egyszerű FastAPI + PostgreSQL/PostGIS alkalmazás kell: e-mailes regisztráció/megerősítés/reset, natív tokenek és biztonságos webes session, fiókonként elkülönített eszközök/párok, fizikai készülékhez kötött HMAC-claim, offline sessionök idempotens kötegfeltöltése, előzmények/CSV, friss jelenlét és közös nyomáshőtérkép. Az API mindig az authból származó fiókra szűr. Az ESP32 nem internetes kliens. Ne készíts firmware-t vagy új webes UI-t; a Flutter web buildet ugyanazon originen szolgáld ki.

Először rögzítsd az OpenAPI-t az INTERFACE alapján. Ellenőrizd a `../contracts/fixtures.json`, `../app/lib/sync/`, `../app/lib/core/grid.dart` és `../app/test/storage_test.dart` szerződését. Az `inserted+duplicates` minden rekordtípust számol. A GPS automatikus, de mindig opcionális: hely nélkül is fogadd az időbélyeges nyomásadatot, csak a térképről maradjon ki. A mértékegység Pa, idő UTC, hely WGS84, hiányzó adat NULL. Őrizd meg a nyers mintákat/GPS-t és a kalibrációs pillanatképet. A feltöltés ideje nem élő állapot; a hőtérkép nyomást, nem pontsűrűséget mutat, a redundáns A/B azonos súlyú.

Legyen rövid, reviewzható kód; migráció, verziózár, admin eszközimport, tartós e-mail outbox, korlátos/lapozott lekérdezések, egész kötegre vonatkozó DB-tranzakció és duplikációvédelem. Ne vezess be mikroszolgáltatásokat vagy üzenetbrokert mérhető szükség nélkül.

Adj Docker Compose-t, titok nélküli `.env.example`-t, rövid indítás/mentés/visszaállítás leírást és egészségellenőrzést. A kliensnek add át a kész OpenAPI-t, publikus API/web URL-eket, fixture-öket és a pontos auth/claim/szinkron példákat. Eszköztitok, jelszó vagy privát kulcs ne kerüljön a kliens konfigurációjába vagy naplóba.

Teszteld: két fiók teljes izolációja minden végponton; idegen eszköz párba rakásának tiltása; claim lejárat/visszajátszás/párhuzamosság; ismételt és ütköző batch; hálózati újraküldés; késői offline session; tulajdonosváltás; tokenlejárat; régi presence elutasítása; GPS nélküli adat; azonos app/service hőtérkép; két pár egy fiókban; 576 000 mintás adatkészlet; mentésből visszaállítás. Külön nevezd meg a futtatott és a csak tervezett ellenőrzéseket. A kész service-t a valódi klienssel is integráld; mockot ne nevezz éles integrációnak.
