# Telepítési átadás

Az önálló apphoz nem kell service. A felhős egyeszközös méréshez telepítsd a mostani backend-forrást:

- `Rig.device_b_id` opcionális/null; egy készülékhez is létrejön a mérőegység.
- `SessionStart.devices`: 1–2 különböző eszköz; szerepek `A` vagy `A,B`.
- Új minta-flag: `simulated` (firmware hardverteszt). A korábbi kérések változatlanul érvényesek.
- Nincs adatbázis-migráció. A felhasználói és eszközjogok változatlanok.
- A web fordításakor **`--dart-define=ENABLE_CLOUD=true` kötelező**; a natív build alapból önálló.

Másik Codexnek: „Pullold a main ágat; futtasd a service tesztjeit (az új `tests/test_single_device.py`-t is). A README meglévő mentési/telepítési eljárásával telepítsd a kompatibilis API-bővítést és az ENABLE_CLOUD=true web buildet. Ellenőrizd az egyeszközös regisztrált mérőegység → mérés → köteg → lezárás → CSV folyamatot, a kétcsatornás működést és a fiókizolációt. Más szolgáltatást ne módosíts. A tesztprofilok titkai ne kerüljenek Gitbe.”
