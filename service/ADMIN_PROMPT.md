# Admin eszköznyilvántartás – Codex prompt

Bővítsd a meglévő pressure_sensor service-t és Flutter webet egyszerű admin eszköznyilvántartással. Gyártási sorozatokat szeretnék importálni; a vásárló továbbra is az app normál BLE/HMAC-claim folyamatával rendeli a készüléket a fiókjához.

- A meglévő, megerősített `tamkis@gmail.com` fiókot egyszeri szerveroldali adminparanccsal léptesd elő. A szerepkör a fiókazonosítóhoz tartozzon az adatbázisban; minden admin API-kérés ellenőrizze. Regisztrációval, kliensparaméterrel vagy az e-mail-cím puszta egyezésével nem szerezhető adminjog. A normál felhasználó 403-at kapjon; az adminjog ne adjon automatikusan hozzáférést mások mérési adataihoz.
- Legyen `GET /api/v1/admin/devices` lapozással és azonosító szerinti kereséssel, valamint `POST /api/v1/admin/devices/import` méretkorlátos JSON-importtal és `dry_run` előnézettel. Fogadd a `fw/PROVISIONING.md` egyedi rekordját és a Windows-szimulátor `devices.simulator.json` listáját is; használd újra a meglévő validálást és titkosítást.
- Az import új eszközöket a gyártói nyilvántartásba vegyen fel, tulajdonos nélkül. Azonos rekord ismétlése legyen ártalmatlan; eltérő adat vagy kulcs ugyanahhoz az azonosítóhoz legyen ütközés. Hibás köteg ne módosítson semmit. Ne írj felül titkot, tulajdonost vagy előzményt; az eszközátadás külön folyamat marad.
- Az eszközbe és a service-be ugyanaz a készülékenkénti titok kerüljön. HTTPS, meglévő hitelesítés és webes CSRF-védelem; titok ne kerüljön válaszba, naplóba vagy tartós böngészőtárolóba. Naplózd az adminművelet idejét, végrehajtóját és érintett eszközazonosítóit, titkok nélkül.
- A weben csak adminnak jelenjen meg az **Admin / Eszköznyilvántartás**: lista, regisztrált/párosított állapot, JSON-fájl kiválasztása, ellenőrzési eredmény és importgomb. Az import nem helyettesíti a vásárlói párosítást.
- Frissítsd az OpenAPI-t és a rövid használati leírást. GitHub workflow-ban teszteld a jogosultságot, atomikusságot, ismétlést/ütközést, titkok elrejtését és az import → normál claim → mérés utat. Kompatibilis migrációval telepíts, ellenőrizd, commitolj és pusholj; más service-hez ne nyúlj.

A Windows-próbához a helyi, privát `%LOCALAPPDATA%/PressureFieldSimulator/default/devices.simulator.json` importálható az elkészült felületen. A fájl nincs Gitben; az importjához előbb el kell juttatni a feltöltést végző gépre.
