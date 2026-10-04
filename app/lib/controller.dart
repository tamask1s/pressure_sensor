import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'core/model.dart';
import 'core/grid.dart';
import 'measurement/capture.dart';
import 'storage/store.dart';
import 'sync/api.dart';
import 'sync/uploader.dart';
import 'platform/vault.dart';
import 'simulator/engine.dart' show simulatorPort;

const hasGps = bool.fromEnvironment('HAS_GPS', defaultValue: true);

class AppController extends ChangeNotifier {
  final bool simulated;
  final int simulationPort;
  final Api api;
  Capture capture;
  AppController({this.simulated = false, this.simulationPort = simulatorPort})
    : api = Api(
        const String.fromEnvironment(
          'API_URL',
          defaultValue: kIsWeb ? '/pressure_sensor/api/v1' : '',
        ),
        vaultNamespace: simulated ? 'sim:$simulationPort:' : '',
      ),
      capture = createCapture(
        simulated: simulated,
        simulationPort: simulationPort,
      );
  String get settingsKey =>
      simulated ? 'sim:$simulationPort:settings' : 'settings';
  Store? store;
  Uploader? uploader;
  Json? account, rig;
  List<Json> devices = [], rigs = [], history = [];
  String? message;
  String collector = ids.v4(), syncStatus = '';
  int pending = 0;
  bool ready = false, busy = false, _syncing = false, _disposed = false;
  Timer? _tick, _ui;
  StreamSubscription? _captureEvents;
  String? _lease;
  int _heartbeat = 0, _serverOffset = 0;
  DateTime _lastPresence = DateTime(2000);
  final _age = Stopwatch()..start();
  int? _catalogAt;
  bool presenceFresh(Map? presence) =>
      presence?['state'] == 'fresh' &&
      _catalogAt != null &&
      (presence?['state_age_ms'] as num? ?? 30000) +
              _age.elapsedMilliseconds -
              _catalogAt! <
          30000;
  bool get local => account?['id'] == 'local';
  bool get recording => capture.state['active'] == true;
  bool get signedIn => account != null;
  Map<String, Json> get channels =>
      Map<String, Json>.from(capture.state['channels'] as Map? ?? {});
  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> init() async {
    try {
      final config = await readVault(settingsKey);
      if (!kIsWeb && config?['api'] is String) api.base = config!['api'];
      collector = config?['collector'] as String? ?? collector;
      await api.restore();
      account = api.account;
      if (account != null) await _open();
    } catch (e) {
      message = explain(e);
    }
    ready = true;
    _tick = Timer.periodic(const Duration(seconds: 5), (_) => synchronize());
    changed();
  }

  Future<void> configure(String url) async {
    if (signedIn) {
      throw const UserError('A szolgáltatás cseréjéhez előbb jelentkezz ki.');
    }
    final clean = url.trim().replaceAll(RegExp(r'/+$'), '');
    final old = api.base;
    api.base = clean;
    try {
      api.uri('/auth/session');
    } catch (_) {
      api.base = old;
      rethrow;
    }
    await writeVault(settingsKey, {'api': api.base, 'collector': collector});
    changed();
  }

  Future<void> login(String email, String password) async {
    if (recording) throw const UserError('Előbb állítsd le a mérést.');
    await api.login(email, password);
    account = api.account;
    await _open();
    changed();
  }

  Future<void> openLocal() async {
    if (kIsWeb) return;
    account = {'id': 'local', 'email': 'Helyi használat'};
    await _open();
    changed();
  }

  Future<void> _open() async {
    await writeVault(settingsKey, {'api': api.base, 'collector': collector});
    if (!kIsWeb) {
      final scope = local
          ? 'local'
          : '${sha256.convert(utf8.encode(api.base)).toString().substring(0, 16)}-${account!['id']}';
      store = await openStore(simulated ? 'sim-$simulationPort-$scope' : scope);
      await capture.recover(store!);
      final cache = await store!.meta('catalog');
      devices = objects(cache?['devices']);
      rigs = objects(cache?['rigs']);
      final selection = await store!.meta('selection');
      rig = rigs.where((r) => r['id'] == selection?['rig_id']).firstOrNull;
      uploader = local ? null : Uploader(api, store!, account!['id'] as String);
    }
    _captureEvents = capture.events.listen((_) {
      _ui ??= Timer(const Duration(milliseconds: 250), () {
        _ui = null;
        changed();
      });
    });
    await loadHistory(remote: false);
    ready = true;
    changed();
    if (!local) unawaited(_refreshOnline());
    if (rig != null && !kIsWeb) {
      try {
        await connectRig(rig!);
      } catch (e) {
        message = explain(e);
      }
    }
    unawaited(synchronize());
  }

  Future<void> _refreshOnline() async {
    final current = account?['id'];
    try {
      await refreshCatalog();
      if (account?['id'] == current) await loadHistory();
    } catch (e) {
      message = explain(e);
      changed();
    }
  }

  Future<void> logout() async {
    if (recording) throw const UserError('Előbb állítsd le a mérést.');
    final wasLocal = local;
    account = null;
    // The capture and upload finish before the account-specific database closes.
    while (_syncing) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await _captureEvents?.cancel();
    await capture.dispose();
    capture = createCapture(
      simulated: simulated,
      simulationPort: simulationPort,
    );
    if (!wasLocal) {
      try {
        await api.logout();
      } catch (_) {}
    }
    await store?.close();
    store = null;
    uploader = null;
    account = null;
    rig = null;
    devices = [];
    rigs = [];
    history = [];
    pending = 0;
    _lease = null;
    message = null;
    changed();
  }

  Future<void> refreshCatalog() async {
    if (local) return;
    final current = account?['id'];
    final d = await api.list('/devices'), r = await api.list('/rigs');
    if (account?['id'] != current || current == null) return;
    devices = d;
    _catalogAt = _age.elapsedMilliseconds;
    rigs = r.where((r) => r['archived'] != true).toList();
    if (!recording) rig = rigs.where((r) => r['id'] == rig?['id']).firstOrNull;
    await _cache();
    changed();
  }

  Future<void> _cache() async =>
      store?.putMeta('catalog', {'devices': devices, 'rigs': rigs});
  Json device(String id) =>
      devices.where((d) => d['id'] == id).firstOrNull ??
      {'id': id, 'name': shortId(id)};
  Future<void> addDevice(String peripheral, String name) async {
    if (recording) {
      throw const UserError('Eszköz hozzáadása előtt állítsd le a mérést.');
    }
    final info = await capture.inspect(peripheral);
    final id = info['device_id'] as String;
    Json d;
    if (local) {
      d = {
        'id': id,
        'name': name.trim().isEmpty ? shortId(id) : name.trim(),
        'ownership_id': 'local',
        'calibration': calibration(info),
        'sensor_serial': info['sensor_serial'],
        'firmware_version': info['firmware_version'],
        'protocol_version': 2,
      };
    } else {
      final challenge = await api.call(
        'POST',
        '/device-claims/challenge',
        body: {'device_id': id},
      );
      final proof = await capture.command(id, {
        'op': 'claim',
        'account_id': challenge['account_id'],
        'challenge_id': challenge['challenge_id'],
        'nonce': challenge['nonce'],
      });
      final response = await api.call(
        'POST',
        '/device-claims/complete',
        body: {
          'challenge_id': challenge['challenge_id'],
          'proof': proof['proof'],
        },
      );
      d = object(response['device']);
      if (name.trim().isNotEmpty) {
        d = await api.call(
          'PATCH',
          '/devices/$id',
          body: {'name': name.trim()},
        );
      }
    }
    devices.removeWhere((d) => d['id'] == id);
    devices.add(d);
    await _cache();
    changed();
  }

  Future<void> rename(String id, String name) async {
    if (name.trim().isEmpty) return;
    if (!local) {
      await api.call('PATCH', '/devices/$id', body: {'name': name.trim()});
    }
    device(id)['name'] = name.trim();
    await _cache();
    changed();
  }

  Future<void> prepareSimulation() async {
    if (!simulated || recording) {
      throw const UserError('Előbb állítsd le a mérést.');
    }
    await capture.command('simulator', {'action': 'pairing'});
    await capture.scan();
    final found = objects(capture.state['discovered']);
    if (found.length != 2) {
      throw const UserError('Kapcsold be mindkét szimulált érzékelőt.');
    }
    if (!local) await refreshCatalog();
    final selected = <String>[];
    for (var i = 0; i < found.length; i++) {
      final p = found[i]['peripheral'] as String;
      final info = await capture.inspect(p);
      selected.add(info['device_id'] as String);
      if (!devices.any((d) => d['id'] == info['device_id'])) {
        await addDevice(p, 'Szimulált ${i == 0 ? 'A' : 'B'}');
      }
    }
    final existing = rigs
        .where(
          (r) =>
              selected.contains(r['device_a_id']) &&
              selected.contains(r['device_b_id']),
        )
        .firstOrNull;
    if (existing != null) {
      await connectRig(existing);
    } else {
      await saveRig('Szimulált traktor', selected[0], selected[1]);
    }
    changed();
  }

  Future<void> saveRig(String name, String a, String b) async {
    if (recording) throw const UserError('Előbb állítsd le a mérést.');
    if (a == b || name.trim().isEmpty) {
      throw const UserError('Adj nevet és válassz két különböző készüléket.');
    }
    if (rigs.any(
      (r) => [r['device_a_id'], r['device_b_id']].any((d) => d == a || d == b),
    )) {
      throw const UserError(
        'A készülék már egy pár tagja. Előbb archiváld azt a párt.',
      );
    }
    final id = ids.v4(),
        body = {
          'name': name.trim(),
          'device_a_id': a,
          'device_b_id': b,
          'expected_revision': 0,
        };
    final r = local
        ? {'id': id, ...body, 'revision': 1}
        : await api.call('PUT', '/rigs/$id', body: body);
    rigs.add(r);
    await _cache();
    if (!kIsWeb) await connectRig(r);
    changed();
  }

  Future<void> archiveRig(Json r) async {
    if (recording) throw const UserError('Előbb állítsd le a mérést.');
    if (!local) {
      await api.call(
        'PATCH',
        '/rigs/${r['id']}',
        body: {'archived': true, 'expected_revision': r['revision']},
      );
    }
    rigs.removeWhere((e) => e['id'] == r['id']);
    if (rig?['id'] == r['id']) {
      rig = null;
      if (!kIsWeb) await capture.select([]);
    }
    await _cache();
    changed();
  }

  Future<void> connectRig(Json r) async {
    if (recording) throw const UserError('Mérés közben nem váltható pár.');
    rig = r;
    _lease = null;
    await store?.putMeta('selection', {'rig_id': r['id']});
    changed();
    await capture.select([device(r['device_a_id']), device(r['device_b_id'])]);
  }

  Future<void> start(String name) async {
    final r = rig, s = store;
    if (r == null || s == null) {
      throw const UserError('Előbb válassz eszközpárt.');
    }
    final snapshot = <Json>[];
    for (final role in ['A', 'B']) {
      final id = r[role == 'A' ? 'device_a_id' : 'device_b_id'] as String,
          d = device(id),
          info = channels[id]?['info'];
      final cal = info == null
          ? object(d['calibration'])
          : calibration(object(info));
      if (!local && info != null) {
        final expected = d['calibration'];
        if (expected == null ||
            expected['range_min_pa'] != cal['range_min_pa'] ||
            expected['range_max_pa'] != cal['range_max_pa'] ||
            expected['sensor_serial'] != cal['sensor_serial']) {
          throw const UserError(
            'A készülék kalibrációja eltér a fiókban tárolttól. Ellenőrizd az előkészítést.',
          );
        }
      }
      snapshot.add({
        'device_id': id,
        'ownership_id': d['ownership_id'],
        'role': role,
        'calibration': cal,
      });
    }
    final now = DateTime.now().toUtc();
    await capture.start(s, ids.v4(), {
      'collector_id': collector,
      'rig_id': r['id'],
      'rig_revision': r['revision'],
      'name':
          '${simulated ? 'SIM · ' : ''}${name.trim().isEmpty ? '${r['name']} · ${now.toLocal().toString().substring(0, 16)}' : name.trim()}',
      'started_at': now.toIso8601String(),
      'gps_enabled': hasGps,
      'devices': snapshot,
    });
    changed();
  }

  Future<void> stop() async {
    await capture.stop();
    await loadHistory();
    unawaited(synchronize());
    changed();
  }

  Future<void> synchronize({bool force = false}) async {
    if (!signedIn) return;
    if (_syncing) {
      changed();
      return;
    }
    _syncing = true;
    try {
      await uploader?.tick(force: force);
      syncStatus = local
          ? 'Helyi mód · nincs feltöltés'
          : uploader?.status ?? '';
      pending = await store?.pendingCount() ?? 0;
      if (kIsWeb && !local) {
        try {
          await refreshCatalog();
        } catch (e) {
          message = explain(e);
        }
      }
      if (!local &&
          !kIsWeb &&
          rig != null &&
          DateTime.now().difference(_lastPresence).inSeconds >= 10) {
        _lastPresence = DateTime.now();
        try {
          await _presence();
        } catch (e) {
          _lease = null;
          syncStatus = explain(e);
        }
      }
    } finally {
      _syncing = false;
      changed();
    }
  }

  Future<void> _presence() async {
    final r = rig!;
    final now = DateTime.now().toUtc();
    final result = await api.call(
      'POST',
      '/collectors/$collector/presence',
      body: {
        if (_lease != null) 'lease_id': _lease,
        'heartbeat_seq': ++_heartbeat,
        'observed_at': utc(now.millisecondsSinceEpoch + _serverOffset),
        'session_id': capture.state['session_id'],
        'devices': [
          for (final id in [r['device_a_id'], r['device_b_id']])
            () {
              final c = channels[id];
              return {
                'device_id': id,
                'boot_id': c?['boot_id'],
                'ble_connected': c?['connected'] == true,
                'last_seq': c?['seq'],
                'sample_age_ms': c?['sample_age_ms'],
                'pressure_pa': (c?['stale'] == false)
                    ? (c?['pressure_pa'])
                    : null,
                'battery_mv': c?['battery_mv'],
                'soc_pct': c?['soc_pct'],
                'sensor_ok': c?['pressure_pa'] != null && c?['stale'] == false,
                'sd_state': c == null
                    ? 'unknown'
                    : ((c['flags'] as int? ?? 0) & 8 != 0
                          ? 'error'
                          : ((c['flags'] as int? ?? 0) & 4 != 0
                                ? 'recording'
                                : 'off')),
              };
            }(),
        ],
      },
    );
    _lease = result['lease_id'] as String;
    _serverOffset =
        milliseconds(result['server_time']) -
        DateTime.now().toUtc().millisecondsSinceEpoch;
  }

  Future<void> loadHistory({bool remote = true}) async {
    final current = account?['id'];
    final own = await store?.sessions() ?? [];
    final merged = <String, Json>{};
    if (remote && !local && signedIn) {
      try {
        for (final s in await api.list('/sessions')) {
          merged[s['id'] as String] = {
            'id': s['id'],
            'start': s,
            'end': s['ended_at'] == null ? null : s,
            'remote': true,
            'completed':
                s['status'] == 'completed' || s['status'] == 'interrupted',
          };
        }
      } catch (e) {
        message = explain(e);
      }
    }
    if (account?['id'] != current) return;
    for (final s in own) {
      merged[s['id'] as String] = {...s, 'local': true};
    }
    history = merged.values.toList()
      ..sort(
        (a, b) => (b['start']['started_at'] as String).compareTo(
          a['start']['started_at'] as String,
        ),
      );
    changed();
  }

  Stream<List<Json>> samples(Json session, {bool forceRemote = false}) async* {
    final id = session['id'] as String;
    if (!forceRemote && session['local'] == true && store != null) {
      yield* store!.records(id, 'samples');
      return;
    }
    String? cursor;
    do {
      final p = await api.call(
        'GET',
        '/sessions/$id/samples',
        query: {'limit': '1000', if (cursor != null) 'cursor': cursor},
      );
      yield objects(p['items']);
      final next = p['next_cursor'] as String?;
      if (next != null && next == cursor) {
        throw const FormatException('Ismétlődő kurzor');
      }
      cursor = next;
    } while (cursor != null);
  }

  Future<List<Json>> series(Json session, {String? deviceId}) async {
    final start = milliseconds(session['start']['started_at']),
        end = milliseconds(
          session['end']?['ended_at'] ??
              DateTime.now().toUtc().toIso8601String(),
        );
    final bucket = ((end - start) / 500).ceil().clamp(100, 1 << 40);
    if (session['local'] != true) {
      final rows = await api.list(
        '/sessions/${session['id']}/series',
        query: {
          'from': utc(start),
          'to': utc(end),
          'bucket_ms': '$bucket',
          if (deviceId != null) 'device_id': deviceId,
        },
      );
      return [
        for (final p in rows)
          {
            'at': milliseconds(p['captured_at']),
            'device_id': p['device_id'],
            'pa': p['mean_pa'],
            'min': p['min_pa'],
            'max': p['max_pa'],
          },
      ];
    }
    final totals = <String, Json>{};
    await for (final page in samples(session)) {
      for (final s in page) {
        if (s['pressure_pa'] == null ||
            (deviceId != null && s['device_id'] != deviceId)) {
          continue;
        }
        final at = (milliseconds(s['captured_at']) ~/ bucket) * bucket,
            key = '${s['device_id']}/$at';
        final b = totals.putIfAbsent(
          key,
          () => {
            'at': at,
            'device_id': s['device_id'],
            'sum': 0.0,
            'n': 0,
            'min': s['pressure_pa'],
            'max': s['pressure_pa'],
          },
        );
        b['sum'] += s['pressure_pa'];
        b['n']++;
        if (s['pressure_pa'] < b['min']) b['min'] = s['pressure_pa'];
        if (s['pressure_pa'] > b['max']) b['max'] = s['pressure_pa'];
      }
    }
    return totals.values
        .map(
          (b) => {
            'at': b['at'],
            'device_id': b['device_id'],
            'pa': b['sum'] / b['n'],
            'min': b['min'],
            'max': b['max'],
          },
        )
        .toList()
      ..sort((a, b) => (a['at'] as int).compareTo(b['at'] as int));
  }

  Future<Json> localMap(
    List<Json> selected,
    GridSpec spec, {
    String layer = 'combined',
    bool moving = true,
  }) async {
    if (store == null) return {'cells': <Json>[]};
    final fixes = <String, List<Json>>{};
    for (final s in selected) {
      if (s['local'] != true) continue;
      final f = <Json>[];
      await for (final page in store!.records(s['id'], 'gps_fixes')) {
        f.addAll(page);
      }
      fixes[s['id']] = f;
    }
    final grid = PressureGrid(spec, fixes, layer: layer, movingOnly: moving);
    for (final s in selected) {
      if (s['local'] != true) continue;
      final roles = {
        for (final d in objects(s['start']['devices']))
          d['device_id']: d['role'],
      };
      await for (final page in store!.records(s['id'], 'samples')) {
        for (final sample in page) {
          grid.add(s['id'], roles[sample['device_id']] ?? 'A', sample);
        }
      }
    }
    return grid.finish();
  }

  Future<void> deleteAccount(String password) async {
    if (recording) throw const UserError('Előbb állítsd le a mérést.');
    await api.call('DELETE', '/account', body: {'password': password});
    await logout();
  }

  @override
  void dispose() {
    _disposed = true;
    _tick?.cancel();
    _ui?.cancel();
    unawaited(_captureEvents?.cancel());
    unawaited(capture.dispose());
    api.close();
    super.dispose();
  }
}
