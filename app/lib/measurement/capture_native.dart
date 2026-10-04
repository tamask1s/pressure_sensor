import 'dart:async';
import '../core/model.dart';
import '../core/location.dart';
import '../core/protocol.dart';
import '../platform/recording.dart';
import '../platform/location_source.dart';
import '../storage/store_api.dart';
import 'ble.dart';
import 'capture_api.dart';

Capture createCapture() => NativeCapture();

class NativeCapture implements Capture {
  BleHub? _hub;
  final _events = StreamController<Json>.broadcast();
  @override
  Stream<Json> get events => _events.stream;
  @override
  final Json state = {
    'active': false,
    'channels': <String, Json>{},
    'discovered': <Json>[],
    'gps': 'Automatikus helyhozzárendelés',
    'saved': 0,
    'error': null,
  };
  final _fixes = <Json>[], _buffer = <Json>[], _gaps = <Json>[];
  final _segments = <String, Json>{};
  final _clocks = <String, DeviceClock>{};
  final _seen = <String, int>{};
  final _pendingAt = <String, int>{};
  final _selected = <String>{};
  final _clockUncertain = <String>{};
  StreamSubscription? _bleSub;
  final _gps = LocationSource();
  Timer? _timer;
  Store? _store;
  String? _session;
  bool _gpsEnabled = true,
      _flushing = false,
      _closing = false,
      _disposed = false,
      _clockBusy = false,
      _faulted = false;
  DateTime _gpsRetry = DateTime(2000);
  DateTime _lastSync = DateTime(2000);
  Json? _phoneSegment;
  final _monotonic = Stopwatch()..start();
  int _phoneOffset = DateTime.now().toUtc().millisecondsSinceEpoch;
  void _emit() {
    if (!_disposed) _events.add(state);
  }

  Future<BleHub> _getHub() async {
    if (_hub != null) return _hub!;
    await bluetoothPermission();
    _hub = BleHub();
    _bleSub = _hub!.events.stream.listen(_onBle);
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      _maintain();
    });
    return _hub!;
  }

  @override
  Future<void> scan() async {
    await (await _getHub()).scan();
  }

  @override
  Future<Json> inspect(String peripheral) async =>
      (await (await _getHub()).connect(peripheral)).info;
  @override
  Future<Json> command(String device, Json command) async {
    final peer = (await _getHub()).peers[device];
    if (peer == null) {
      throw const UserError('Előbb csatlakoztasd a készüléket.');
    }
    return _hub!.command(peer, command);
  }

  @override
  Future<void> select(List<Json> devices) async {
    if (_session != null) {
      throw const UserError('Mérés közben nem váltható eszközpár.');
    }
    _selected
      ..clear()
      ..addAll(devices.map((d) => d['id'] as String));
    await (await _getHub()).select(devices);
  }

  @override
  Future<void> disconnect(String device) async {
    await _hub?.disconnect(device);
  }

  void _onBle(Json e) {
    final channels = state['channels'] as Map<String, Json>;
    switch (e['type']) {
      case 'discovery':
        state['discovered'] = e['devices'];
        break;
      case 'error':
        state['error'] = e['message'];
        break;
      case 'connected':
        final id = e['device_id'] as String, clock = e['clock'] as DeviceClock;
        _clocks[id] = clock;
        _clockUncertain.remove(id);
        _segments[clock.segmentId] = clock.segment(id);
        if (_session != null) {
          _buffer.add(record('time_segments', clock.segment(id)));
        }
        channels[id] = {
          'connected': true,
          'info': e['info'],
          'received_ms': 0,
          'chart': <Json>[],
        };
        break;
      case 'disconnected':
        final id = e['device_id'] as String;
        if (channels[id] != null) channels[id]!['connected'] = false;
        if (_session != null) {
          _gaps.add({
            'device_id': id,
            'boot_id': _clocks[id]?.boot,
            'started_at': utc(_now()),
            'ended_at': null,
            'reason': 'ble_disconnected',
          });
        }
        break;
      case 'packet':
        _onPacket(e['device_id'] as String, e['packet'] as Packet);
        break;
    }
    _emit();
  }

  int _now() => _phoneOffset + _monotonic.elapsedMilliseconds;
  void _onPacket(String device, Packet p) {
    final clock = _clocks[device];
    if (clock == null) return;
    final key = '$device/${clock.boot}', previous = _seen[key];
    if (previous != null && p.seq <= previous) return;
    _seen[key] = p.seq;
    final up = clock.unwrap(p.uptimeLow), at = clock.utcAt(up);
    if (_session != null && previous != null && p.seq > previous + 1) {
      _gaps.add({
        'device_id': device,
        'boot_id': clock.boot,
        'from_seq': previous + 1,
        'to_seq': p.seq - 1,
        'started_at': utc(at),
        'ended_at': utc(at),
        'reason': 'sequence_gap',
      });
    }
    final channel = (state['channels'] as Map<String, Json>)[device] ??= {
      'chart': <Json>[],
    };
    channel.addAll({
      'connected': true,
      'pressure_pa': p.valid ? p.pressure : null,
      'battery_mv': p.battery == 65535 ? null : p.battery,
      'soc_pct': p.soc == 255 ? null : p.soc,
      'flags': p.flags,
      'received_ms': _monotonic.elapsedMilliseconds,
      'seq': p.seq,
      'boot_id': clock.boot,
      'captured_at': utc(at),
    });
    final chart = channel['chart'] as List<Json>;
    chart.add({'at': at, 'pa': p.valid ? p.pressure : null});
    if (chart.length > 600) chart.removeRange(0, chart.length - 600);
    if (_session == null ||
        _closing ||
        _faulted ||
        !_selected.contains(device)) {
      return;
    }
    for (final gap in _gaps) {
      if (gap['device_id'] == device && gap['ended_at'] == null) {
        gap['ended_at'] = utc(at);
      }
    }
    final data = <String, dynamic>{
      'device_id': device,
      'boot_id': clock.boot,
      'seq': p.seq,
      'time_segment_id': clock.segmentId,
      'uptime_ms': up,
      'captured_at': utc(at),
      'raw_count': p.valid ? p.raw : null,
      'pressure_pa': p.valid ? p.pressure : null,
      'battery_mv': p.battery == 65535 ? null : p.battery,
      'soc_pct': p.soc == 255 ? null : p.soc,
      'flags': [
        ...p.quality,
        if (_clockUncertain.contains(device) ||
            up - clock.anchorUptime > 120000)
          'time_uncertain',
      ],
      'location': null,
    };
    if (_buffer.length >= 1000) {
      _abort('A helyi rögzítés nem bírja az adatfolyamot. A mérés megszakadt.');
      return;
    }
    final row = record('samples', data, ready: false);
    _pendingAt[row['id'] as String] = _monotonic.elapsedMilliseconds;
    _buffer.add(row);
  }

  Json _newPhoneSegment() {
    final segment = <String, dynamic>{
      'id': ids.v4(),
      'device_id': null,
      'boot_id': null,
      'uptime_anchor_ms': _monotonic.elapsedMilliseconds,
      'utc_anchor': utc(_now()),
      'uncertainty_ms': 0,
      'source': 'phone',
    };
    _phoneSegment = segment;
    _segments[segment['id'] as String] = segment;
    if (_session != null) _buffer.add(record('time_segments', segment));
    return segment;
  }

  Future<bool> _location({bool request = true}) async {
    if (!_gpsEnabled) {
      state['gps'] = 'GPS nélkül';
      return false;
    }
    return _gps.start(
      (fix) {
        if (_session == null || _closing || _faulted) return;
        fix['segment_id'] = _phoneSegment!['id'];
        if ((milliseconds(fix['captured_at']) - _now()).abs() > 10000) {
          state['gps'] = 'Régi GPS-adat · csak nyomásnapló';
          return;
        }
        if (_fixes.isNotEmpty &&
            milliseconds(fix['captured_at']) <=
                milliseconds(_fixes.last['captured_at'])) {
          return;
        }
        _fixes.add(fix);
        _buffer.add(record('gps_fixes', fix));
        final accuracy = fix['accuracy_m'] as num;
        state['gps'] = accuracy <= 10
            ? 'GPS ±${accuracy.round()} m'
            : 'Pontatlan GPS ±${accuracy.round()} m';
        state['position'] = fix;
      },
      (message) {
        state['gps'] = message;
        _emit();
      },
      request: request,
    );
  }

  @override
  Future<void> start(Store store, String id, Json session) async {
    if (_session != null) throw const UserError('Már fut mérés.');
    if (!_selected.any((id) => _hub?.peers.containsKey(id) == true)) {
      throw const UserError(
        'Legalább egy kiválasztott készülékhez csatlakozz.',
      );
    }
    await store.startSession(id, session);
    _store = store;
    _session = id;
    _closing = false;
    _gpsEnabled = session['gps_enabled'] == true;
    _gaps.clear();
    _fixes.clear();
    _buffer.clear();
    _faulted = false;
    _pendingAt.clear();
    state['paused_due_to_error'] = false;
    state['saved'] = 0;
    state['error'] = null;
    for (final device in _selected) {
      if (_hub?.peers[device] == null) {
        _gaps.add({
          'device_id': device,
          'started_at': session['started_at'],
          'ended_at': null,
          'reason': 'not_connected',
        });
      }
    }
    _segments.clear();
    for (final entry in _clocks.entries.toList()) {
      if (_selected.contains(entry.key)) {
        final clock = entry.value.newSegment();
        _clocks[entry.key] = clock;
        _segments[clock.segmentId] = clock.segment(entry.key);
        _buffer.add(record('time_segments', clock.segment(entry.key)));
      }
    }
    _newPhoneSegment();
    final located = await _location();
    try {
      await holdRecording(true, location: located);
    } catch (_) {
      await stop(interrupted: true);
      rethrow;
    }
    state['active'] = true;
    state['session_id'] = id;
    for (final id in _selected) {
      if (_hub?.peers[id] != null) {
        try {
          await command(id, {'op': 'set_time', 'utc_ms': _now()});
        } catch (_) {}
      }
    }
    await _flush();
    _emit();
  }

  Future<void> _flush() async {
    final store = _store, id = _session;
    if (store == null || id == null || _buffer.isEmpty) return;
    final pending = List<Json>.of(_buffer);
    _buffer.clear();
    try {
      await store.writeRecords(id, pending);
      state['saved'] += (pending.where((r) => r['kind'] == 'samples').length);
    } catch (_) {
      _buffer.insertAll(0, pending);
      rethrow;
    }
  }

  Future<void> _finalize({bool all = false}) async {
    final store = _store, id = _session;
    if (store == null || id == null) return;
    final pending = await store.pendingSamples(id);
    final ready = <Json>[];
    for (final row in pending) {
      final data = object(row['data']);
      if (!all &&
          _monotonic.elapsedMilliseconds - (_pendingAt[row['id']] ?? 0) <
              3000) {
        continue;
      }
      final segment = _segments[data['time_segment_id']];
      ready.add({
        'id': row['id'],
        'data': finalizeLocation(
          data,
          _fixes,
          _gpsEnabled,
          (segment?['uncertainty_ms'] as num? ?? 10000).toInt(),
        ),
      });
    }
    if (ready.isNotEmpty) {
      await store.finalizeSamples(ready);
      for (final row in ready) {
        _pendingAt.remove(row['id']);
      }
    }
    // Keep enough fixes for the oldest unfinished sample; archived fixes stay in SQLite.
    final oldest = pending.isEmpty
        ? _now() - 10000
        : milliseconds(pending.first['data']['captured_at']) - 3000;
    while (_fixes.length > 2 &&
        milliseconds(_fixes[1]['captured_at']) < oldest) {
      _fixes.removeAt(0);
    }
  }

  Future<void> _maintain() async {
    if (_flushing || _disposed) return;
    _flushing = true;
    try {
      for (final c in (state['channels'] as Map<String, Json>).values) {
        c['sample_age_ms'] = c['seq'] == null
            ? null
            : _monotonic.elapsedMilliseconds - (c['received_ms'] as int? ?? 0);
        c['stale'] =
            c['sample_age_ms'] == null || (c['sample_age_ms'] as int) > 500;
      }
      if (_session != null && !_closing && !_faulted) {
        final wall = DateTime.now().toUtc().millisecondsSinceEpoch;
        if ((wall - _now()).abs() > 500) {
          _phoneOffset = wall - _monotonic.elapsedMilliseconds;
          _fixes.clear();
          _clockUncertain.addAll(_selected);
          _newPhoneSegment();
          _lastSync = DateTime(2000);
        }
        await _flush();
        await _finalize();
        if (!_clockBusy &&
            DateTime.now().difference(_lastSync).inSeconds >= 60) {
          _lastSync = DateTime.now();
          unawaited(_syncClocks());
        }
        if (_gpsEnabled && !_gps.running && DateTime.now().isAfter(_gpsRetry)) {
          _gpsRetry = DateTime.now().add(const Duration(seconds: 15));
          unawaited(_location(request: false));
        }
      }
    } catch (e) {
      _abort('Rögzítési hiba: ${explain(e)}');
    } finally {
      _flushing = false;
      _emit();
    }
  }

  void _abort(String message) {
    _faulted = true;
    state['paused_due_to_error'] = true;
    state['error'] = message;
    if (_session != null) {
      unawaited(
        stop(interrupted: true).catchError((Object e) {
          state['error'] =
              'A rögzítés megállt, a lezárás nem sikerült. Szabadíts fel tárhelyet, majd nyomd meg a leállítást. ${explain(e)}';
          _emit();
        }),
      );
    }
  }

  Future<void> _syncClocks() async {
    _clockBusy = true;
    final session = _session;
    try {
      for (final e in _hub!.peers.entries.toList()) {
        if (e.value.busy) continue;
        try {
          await _hub!.synchronize(e.value);
          if (_session != session || _closing) break;
          final c = e.value.clock!;
          _clocks[e.key] = c;
          _clockUncertain.remove(e.key);
          _segments[c.segmentId] = c.segment(e.key);
          _buffer.add(record('time_segments', c.segment(e.key)));
        } catch (_) {
          /* An unavailable peer must not delay local writes. */
        }
      }
    } finally {
      _clockBusy = false;
    }
  }

  @override
  Future<void> stop({bool interrupted = false}) async {
    if (_session == null || _closing) return;
    _closing = true;
    while (_flushing) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await _gps.stop();
    try {
      await _flush();
      await _finalize(all: true);
      final end = utc(_now());
      for (final gap in _gaps) {
        gap['ended_at'] ??= end;
      }
      final counts = await _store!.counts(_session!);
      for (final id in _selected) {
        counts.putIfAbsent(id, () => 0);
      }
      await _store!.finishSession(_session!, {
        'ended_at': end,
        'status': interrupted || _faulted ? 'interrupted' : 'completed',
        'expected_samples_by_device': counts,
        'gaps': _gaps,
      });
      _session = null;
      state['active'] = false;
      state['session_id'] = null;
    } finally {
      _closing = false;
      await holdRecording(false);
      _emit();
    }
  }

  @override
  Future<void> recover(Store store) async {
    for (final s in await store.sessions()) {
      if (s['end'] != null) continue;
      final id = s['id'] as String;
      final fixes = <Json>[], segments = <String, Json>{};
      await for (final page in store.records(id, 'gps_fixes')) {
        fixes.addAll(page);
      }
      await for (final page in store.records(id, 'time_segments')) {
        for (final segment in page) {
          segments[segment['id'] as String] = segment;
        }
      }
      while (true) {
        final rows = await store.pendingSamples(id);
        if (rows.isEmpty) break;
        await store.finalizeSamples([
          for (final row in rows)
            {
              'id': row['id'],
              'data': finalizeLocation(
                object(row['data']),
                fixes,
                s['start']['gps_enabled'] == true,
                (segments[row['data']['time_segment_id']]?['uncertainty_ms']
                            as num? ??
                        10000)
                    .toInt(),
              ),
            },
        ]);
      }
      final counts = await store.counts(id);
      for (final d in objects(s['start']['devices'])) {
        counts.putIfAbsent(d['device_id'] as String, () => 0);
      }
      await store.finishSession(id, {
        'ended_at': utc(DateTime.now().toUtc().millisecondsSinceEpoch),
        'status': 'interrupted',
        'expected_samples_by_device': counts,
        'gaps': [],
      });
      state['error'] =
          'Egy korábban megszakadt mérés adatait helyreállítottuk.';
    }
  }

  @override
  Future<void> dispose() async {
    if (_session != null) await stop(interrupted: true);
    _disposed = true;
    _timer?.cancel();
    await _bleSub?.cancel();
    await _gps.stop();
    await _hub?.dispose();
    await _events.close();
  }
}
