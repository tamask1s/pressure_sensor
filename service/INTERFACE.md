# Service – interfészterv v1

2026-10-03 · A megvalósított kliens v1 szerződése. Ebből készítendő a service OpenAPI-ja. [Teljes rendszer](../SYSTEM.md), [service-terv](SYSTEM.md), [közös tesztadat](../contracts/fixtures.json).

## Konvenciók

HTTPS, `/api/v1`, JSON, UTC RFC3339 időpontok milliszekundummal. Nyomás egész Pa (`1 bar = 100000 Pa`), feszültség mV, távolság m, sebesség m/s. WGS84 mezők név szerint `latitude/longitude`; GeoJSON koordinátasorrend `[longitude, latitude]`. Hiányzó adat `null`, soha nem hamis nulla. Nem véges szám tiltott.

A kliens generál UUID-t a párhoz, mérési sessionhöz, időszegmenshez és GPS-fixhez. `device_id = hps-` + 12 kisbetűs hex; `boot_id` UUID; `seq` uint32. `account_id` az authból származik, íráskor a kliens nem választhat más adatteret. Idegen erőforrás: 404.

Lapozás: `limit` 1–1000, `cursor`, válasz `{items, next_cursor}` stabil sorrenddel. Hibák: `{error:{code,message,request_id,details?}}`; 400 formátum, 401 lejárt/hiányzó auth, 403 nem ellenőrzött e-mail, 404 hiányzó/idegen, 409 állapot vagy eltérő ismétlés, 413 méret, 422 mezőhiba, 429 korlát (`Retry-After`), 503 átmeneti hiba.

## Auth

| Művelet | Kérés → válasz |
|---|---|
| `POST /auth/register` | `{email,password}` → 202, általános válasz; megerősítő levél |
| `POST /auth/verify-email` | `{token}` → 204 |
| `POST /auth/resend-verification` | `{email}` → 202, általános válasz |
| `POST /auth/login` | `{email,password,client_kind:native\|web}` → natív tokenek vagy webes session-cookie; `{account:{id,email},...}` |
| `POST /auth/refresh` | Natív `{refresh_token}` → új tokenpár; egyszerre csak egy refresh folyamat/kliens |
| `GET /auth/session` | Saját account, weben CSRF-token és session-lejárat |
| `POST /auth/logout` | Aktuális session visszavonása, cookie törlése → 204 |
| `POST /auth/forgot-password` | `{email}` → 202, általános válasz |
| `POST /auth/reset-password` | `{token,new_password}` → 204, régi sessionök visszavonása |
| `DELETE /account` | `{password}` + weben CSRF → 204; újrahitelesítés, saját adatok törlése |

Natív tokenválasz: `{account,access_token,expires_in:900,refresh_token}`; bearer access token az API-khoz, refresh csak az auth-végponthoz. Forgatott refresh-token hashként tárolandó; az app atomikusan cseréli a védett tárban. Elveszett refresh-válasz esetén új belépés megengedett, a helyi mérés megmarad. Weben nem adunk refresh tokent JavaScriptnek; cookie-s műveleteknél `X-CSRF-Token` és Origin-ellenőrzés kell. Megerősítő/reset link a web domainre érkezik; az appban a felhasználó ezután beléphet.

E-mail linkek: `/?action=verify-email&token=...`, illetve `/?action=reset-password&token=...`. A `GET /auth/session` válasza `{account:{id,email},csrf_token,expires_at}`. A regisztráció jelszava legalább 12 karakter; felső korlát legalább 128. Natív logout a bearerrel azonosított teljes refresh-családot vonja vissza.

Webes login/regisztráció/reset előtt még nincs munkamenet: ezeknél szigorú Origin-ellenőrzés és rate limit van, session-CSRF csak a bejelentkezett cookie-s műveleteknél kötelező. E-mail token ne kerüljön access-logba vagy harmadik fél URL-jébe.

## Eszközök és tulajdonba vétel

| Művelet | Kérés → válasz |
|---|---|
| `GET /devices`, `GET /devices/{id}` | Saját eszközök/metaadatok/állapot |
| `PATCH /devices/{id}` | `{name}` → frissített eszköz |
| `POST /device-claims/challenge` | `{device_id}` → `{challenge_id,account_id,device_id,nonce,expires_at}` |
| `POST /device-claims/complete` | `{challenge_id,proof}` → `{device,ownership_id}` |
| `GET /rigs` | Saját párok |
| `PUT /rigs/{id}` | `{name,device_a_id,device_b_id,expected_revision}` → `{id,revision,...}` |
| `PATCH /rigs/{id}` | `{archived:true,expected_revision}` → frissített pár |

`Device`: `{id,name,ownership_id,firmware_version,protocol_version,sensor_serial,calibration,rig_id?,presence}`. A privát eszköztitok nem API-mező. Egy pár két különböző, saját készülék; egy készülék legfeljebb egy aktív párban. Élő mérés alatt pártagság nem módosítható. Régi session mindig saját pillanatképpel értelmezendő. Offline létrejött session a pillanatképet őrzi, nem írja vissza a pár időközben megváltozott tagságát.

A pár válasza `{id,name,device_a_id,device_b_id,revision,archived}`; létrehozáskor `expected_revision=0`. A PATCH/PUT eszköz- és párvégpontok közvetlenül az objektumot adják. Importformátum: a [készülék-előkészítés](../fw/PROVISIONING.md) JSON-sémája; ez titkos admin-bemenet, soha nem HTTP-válasz.

**Claim:** provisionált eszközönként 32 véletlen bájt titok. A service 16 véletlen bájt nonce-ot ad, base64url padding nélkül; 60 s lejárat, fiókhoz/eszközhöz kötve. A firmware csak a fizikai párosítási ablakban, titkosított/bondolt BLE-kapcsolaton készít választ. A pontos HMAC-bemenet:

```text
UTF8("HPS-CLAIM-v1\n" + device_id + "\n" + account_id + "\n" + challenge_id + "\n") || nonce_bytes
```

Az ID-k kanonikus kisbetűs alakban; `proof = base64url(HMAC-SHA256(device_secret, bemenet))`, padding nélkül. A service konstans idejű összehasonlítást használ; a challenge felhasználása és az egyedi aktív tulajdon bejegyzése egy tranzakció. Idegen tulajdon esetén általános 409. Ugyanazon fiók azonos, már sikeres completion-ismétlése a korábbi eredményt adja; a proof nem használható új claimre. Ismeretlen eszköz/hibás proof/lejárt challenge általános hibát ad, rate limittel. Kulcsbeolvasás csak admin CLI-ben; nyilvános provisioning-végpont nincs.

## Mérések és offline feltöltés

| Művelet | Kérés → válasz |
|---|---|
| `PUT /sessions/{id}` | `SessionStart` → tárolt session; azonos ismétlés 200, új 201, eltérő immutábilis adat 409 |
| `POST /sessions/{id}/batches` | `{batch_id,time_segments:[],gps_fixes:[],samples:[]}` → `{batch_id,inserted,duplicates}` |
| `POST /sessions/{id}/complete` | `{ended_at,status:completed\|interrupted,expected_samples_by_device:{device_id:count},gaps:[]}` → lezárt session; mintaszámeltérés 409 |
| `GET /sessions` | `from,to,rig_ids?,device_ids?,cursor,limit` → sessionlista |
| `GET /sessions/{id}` | Metaadat, állapot, mintaszámok, minőség, feltöltési állapot |
| `GET /sessions/{id}/samples` | `from?,to?,device_id?,cursor,limit` → eredeti minták |
| `GET /sessions/{id}/track` | `cursor,limit` → eredeti GPS-fixek, a résjelzésekkel |
| `GET /sessions/{id}/series` | `device_id?,from,to,bucket_ms` → időablakonként átlag/min/max/darabszám; legfeljebb 5000 pont |
| `GET /sessions/{id}/export.csv` | Streamelt, saját nyers adat; mezők és egységek a fejlécben |

`SessionStart`: `{collector_id,rig_id,rig_revision,name,started_at,gps_enabled,devices:[{device_id,ownership_id,role:A\|B,calibration}]}`. A `collector_id` telepítésenkénti UUID, nem jogosultság. A service a két eszköz aktív tulajdonát ellenőrzi; a session-pártagság a kliens által megőrzött pillanatkép, így késői offline feltöltés is értelmezhető. `calibration`: `{profile_id,sensor_serial,range_min_pa,range_max_pa,scale,offset_pa,verified}`; az eredeti nyomás utólag nem számolódik át csendben.

A kalibrált érték képlete: `round((range_min_pa + (raw_count + 16000) / 32000 * (range_max_pa - range_min_pa)) * scale + offset_pa)`. Alapérték `scale=1`, `offset_pa=0`; a fizikai tartományt a készülékhez kell igazolni. A kalibráció egy sessionön belül nem változik.

`TimeSegment`: `{id,device_id,boot_id,uptime_anchor_ms,utc_anchor,uncertainty_ms,source:phone|rtc}`. Minden egész uptime 64 bites; JSON-ban csak a pontosan ábrázolható, legfeljebb 2^53−1 tartomány engedett. Új órahorgony új szegmens; régi rekord változatlan.

`GpsFix`: `{id,segment_id,captured_at,latitude,longitude,accuracy_m,speed_mps?,heading_deg?}`. `segment_id` az app monoton/UTC időszegmensének azonosítója, nem készülékhivatkozás; az app GPS-időszegmense `{id,utc_anchor,uptime_anchor_ms,uncertainty_ms,source:phone}` formában szintén a `time_segments` listába kerül, `device_id/boot_id=null` értékkel.

`Sample`:

```json
{
  "device_id": "hps-cc50e3b6194a",
  "boot_id": "53b31f7b-ec78-4e31-a6fd-73d33b4b1a46",
  "seq": 120,
  "time_segment_id": "43c76031-d06d-4e42-9eaf-f6c753564aab",
  "uptime_ms": 123456,
  "captured_at": "2026-10-03T12:00:00.100Z",
  "raw_count": 0,
  "pressure_pa": 10000000,
  "battery_mv": 3850,
  "soc_pct": 65,
  "flags": [],
  "location": null
}
```

Érvényes `location`: `{latitude,longitude,accuracy_m,speed_mps?,fix_before_id,fix_after_id,method:interpolated}`. A két fix ugyanazon session app-időszegmensében van, időben közrefogja a mintát. A nyers fixek és horgonyok a mintával egy kötegben vagy előbb érkeznek. A service ellenőrzi az idő- és pontosságkorlátokat, tartományokat és hivatkozásokat; az interpolált koordinátát a fixekből ellenőrzi. Hiányos illesztésnél `location=null` és megfelelő flag.

`flags` zárt értékkészlete: `sensor_error`, `pressure_out_of_range`, `rtc_invalid`, `battery_unknown`, `sd_error`, `gps_disabled`, `gps_missing`, `gps_inaccurate`, `time_uncertain`, `stationary`, `speed_unknown`. A hiányzó csatorna és BLE-rés session-szintű `gaps` rekord: `{device_id,boot_id?,from_seq?,to_seq?,started_at,ended_at,reason}`. A valódi nulla nyomás érvényes szám; szenzorhibánál `pressure_pa/raw_count=null`.

Egy batch legfeljebb 500 minta, 100 GPS-fix, 20 időszegmens és kibontva 512 KiB. Minden batch atomikus; hiba esetén nincs részleges siker. Azonos batch-ID azonos kanonikus tartalommal újrapróbálható; eltérő tartalom 409. Egyedi `(device_id,boot_id,seq)` másik sessionben is konfliktus, nem második mérés. A duplikációk egyezését minden tárolt mezőre ellenőrizzük. Az app a változatlan köteget tartósan őrzi, és csak siker után jelöli feltöltöttnek.

`inserted` és `duplicates` az **összes** time_segment + GPS-fix + minta darabszáma; összegük a három tömb összhossza. Kötegismétléskor a mentett eredeti nyugta is helyes. A `gps_enabled=true` kizárólag a helykeresés szándéka: **nem kötelezi a mintát helyadatra**; GPS nélküli köteg és session teljes értékű, időbélyeggel feltöltendő.

Sessionlista/részlet: `{id,...SessionStart,status:recording|completed|interrupted,ended_at:null|UTC,expected_samples_by_device:{},gaps:[]}`. Lista rendezése `started_at DESC,id`; minták és GPS-fixek sorrendje `captured_at ASC,id`. `GET /track` fixobjektumokat ad az `items` tömbben. A `GET /series` válasza `{items:[{device_id,captured_at,mean_pa,min_pa,max_pa,sample_count}]}`. Az app saját grafikonhoz is tudja folyamatosan olvasni a nyers mintalapokat.

Lezárt sessionbe új rekord nem írható; korábban elfogadott batch és completion újraküldése sikeres. A lezárás eszközönkénti egyedi mintaszámot ellenőriz, a kieséseket nem találja ki és nem tölti nullával. Félbemaradt app sessionje `interrupted` jelöléssel lezárható ugyanilyen ellenőrzéssel; session-metaadatot a szerver soha nem töröl pusztán inaktivitás miatt.

## Aktuális állapot

`POST /collectors/{id}/presence` → `{lease_id,server_time,expires_at}`. Kérés: `{lease_id?,heartbeat_seq,observed_at,session_id?,devices:[{device_id,boot_id?,ble_connected,last_seq?,sample_age_ms?,pressure_pa?,battery_mv?,soc_pct?,sensor_ok,sd_state}]}`. Legfeljebb két készülék, 10 s küldési időköz; a presence üzenet nem kerül offline feltöltési sorba.

A service 30 s-os, fiókhoz/gyűjtőhöz/eszközökhöz kötött lease-t ad; másik élő gyűjtő átfedése 409. Lease nélküli első kérés csak lease-t ad, élő állapotot még nem állít; ezt újonnan felvett állapottal kell visszaigazolni. Azonos gyűjtő megismételt lease-kérése ugyanazt a még élő lease-t kapja. Lejárt lease régi csomagja nem éleszthet állapotot; `heartbeat_seq` lease-en belül monoton. Minden állapotjel tartalmaz `observed_at` időt is, a válasz `server_time` alapján korrigált UTC-ben; 15 s-nál régebbi vagy 5 s-nál jövőbeli jel elutasított. `fresh`: élő lease, 30 s-nál fiatalabb állapotpillanatkép, és abban BLE + szenzor OK + `sample_age_ms ≤ 2000`. Egyébként `collector_online_device_stale` vagy `last_seen`. A válaszban `observed_at`, `state_age_ms`, `last_seen_at` és `last_measurement_at` is szerepel: a web nem állítja, hogy a legutolsó minta a lekérdezés pillanatában is 2 s-nál fiatalabb.

A `Device.presence` ezek mellett a legutóbbi megfigyelés `pressure_pa,battery_mv,soc_pct,ble_connected,sample_age_ms` mezőit és a `state` felsorolást tartalmazza; előzmény nélkül `null`. A lease nélküli kérés helyi óráját csak órakorrekcióhoz használjuk, nem utasítjuk el órakülönbség miatt: nem hoz létre élő állapotot. A fenti időkorlát a megerősített lease-re érvényes.

## Közös hőtérkép

`GET /map/cells?from=...&to=...&bbox=west,south,east,north&grid_srid=32634&cell_m=10&layer=combined&moving_only=true`.

Opcionális szűrők: `rig_ids`, `device_ids`, `session_ids`; ezek metszete, mindig az aktuális fiókon belül. `layer=combined|A|B`; hiányzó szűrő minden saját párt jelent. `cell_m`: 10/20/50/100/250/500/1000; `grid_srid` a nézethez választott és megtartott helyi UTM zóna. Határmezők és maximális terület validálandó. `moving_only=false` tudatosan az álló/ismeretlen sebességű adatot is bevonja.

Válasz: `{algorithm:"pressure-grid-v1",grid_srid,cell_m,scale:{min_pa,max_pa},cells:[{ix,iy,geometry,mean_pa,min_pa,max_pa,sample_count,session_count,channel_count,partial_channel_seconds}],quality:{excluded_samples,missing_location_samples}}`. GeoJSON `Polygon` WGS84-ben, maximum 5000 cella; többnél 422 `grid_too_fine` és javasolt nagyobb cellaméret, nem csendes levágás.

Az aggregáció pontos sorrendje és GPS-korlátai a főterv §7-ben. Másodperces csoport = `floor(UTC epoch_ms/1000)`; kiválasztott csatornákon azonos súly, majd munkamenetenként/cellánként átlag, végül sessionök egyenlő súlyú átlaga. Cellaindex `floor(UTM_easting/cell_m)`, `floor(UTM_northing/cell_m)`. `sample_count` a bevont eredeti minták száma; a szín kizárólag `mean_pa` függvénye. Az ablak közepének GPS-helyét a service a nyers fixekből képezi; ehhez is kell a hely/időminőség. Hiányzó középhelyű ablak kimarad. `min_pa/max_pa` a bevont eredeti minták szélsőértéke.

Szűrő- és gridváltozással új lekérdezés készül; az egész fiókra kiterjedő lekérdezés sem olvashat idegen adatot. A kliens helyi és service eredménye közös fix adatkészleten egyezzen. Alaptérképcsempék nem e mérési API feladata.
