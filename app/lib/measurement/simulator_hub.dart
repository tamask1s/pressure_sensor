import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../core/model.dart';
import '../core/protocol.dart';
import '../simulator/engine.dart';
import 'device_hub.dart';

class SimulatorHub implements DeviceHub {
  final int port;
  @override
  // scan/connect return only after the capture has received their state.
  final events = StreamController<Json>.broadcast(sync: true);
  @override
  final peers = <String, DevicePeer>{};
  final _desired = <String>{}, _manual = <String>{};
  final _pending = <int, Completer<Json>>{};
  final _connecting = <String, Future<DevicePeer>>{};
  WebSocket? _socket;
  Future<void>? _opening;
  Timer? _timer;
  bool _disposed = false, _reconnecting = false;
  int _requestId = 0;
  SimulatorHub({this.port = simulatorPort}) {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _reconnect());
  }
  void _emit(Json e) {
    if (!_disposed) events.add(e);
  }

  Future<void> _ensure() async {
    if (_disposed) throw const UserError('A szimulátor kapcsolata lezárult.');
    if (_socket != null) return;
    await (_opening ??= _open().whenComplete(() => _opening = null));
  }

  Future<void> _open() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:$port/simulator',
        headers: {'X-Pressure-Simulator': '1'},
        customClient: client,
        compression: CompressionOptions.compressionOff,
      ).timeout(const Duration(seconds: 4));
      if (_disposed) {
        await socket.close();
        return;
      }
      _socket = socket;
      socket.pingInterval = const Duration(seconds: 5);
      socket.listen(
        _receive,
        onError: (Object _) {},
        onDone: () {
          client.close(force: true);
          if (_socket == socket) _lost();
        },
      );
    } catch (_) {
      client.close(force: true);
      throw const UserError(
        'Indítsd el a pressure_simulator.exe programot. Egy szimulátorhoz egy app kapcsolódhat.',
      );
    }
  }

  void _lost() {
    _socket = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(const UserError('Megszakadt a szimulátor kapcsolata.'));
      }
    }
    _pending.clear();
    for (final id in peers.keys.toList()) {
      _drop(id);
    }
    _emit({
      'type': 'error',
      'message': 'A szimulátor nem érhető el. Újracsatlakozás folyamatban.',
    });
  }

  void _drop(String id) {
    if (peers.remove(id) != null) {
      _emit({'type': 'disconnected', 'device_id': id});
    }
  }

  void _receive(dynamic data) {
    try {
      if (data is! String || data.length > 8192) {
        throw const FormatException('Hibás szimulátorüzenet');
      }
      final e = object(jsonDecode(data));
      if (e['id'] is int) {
        final c = _pending.remove(e['id']);
        if (c == null) return;
        if (e['ok'] == true) {
          c.complete(object(e['result']));
        } else {
          c.completeError(UserError(e['error'] as String? ?? 'Szimulátorhiba'));
        }
      } else if (e['type'] == 'packet') {
        if (peers.containsKey(e['device_id'])) {
          _emit({
            'type': 'packet',
            'device_id': e['device_id'],
            'packet': Packet.decode(base64.decode(e['data'] as String)),
          });
        }
      } else if (e['type'] == 'disconnected') {
        _drop(e['device_id'] as String);
      } else if (e['type'] == 'gps' || e['type'] == 'simulator') {
        _emit(e);
      }
    } catch (_) {
      unawaited(_socket?.close(WebSocketStatus.protocolError));
    }
  }

  Future<Json> _request(Json data) async {
    await _ensure();
    if (_disposed || _socket == null) {
      throw const UserError('Nincs szimulátorkapcsolat.');
    }
    final id = ++_requestId, c = Completer<Json>();
    _pending[id] = c;
    _socket!.add(jsonEncode({'id': id, ...data}));
    try {
      return await c.future.timeout(const Duration(seconds: 4));
    } finally {
      _pending.remove(id);
    }
  }

  Future<Json> control(Json command) =>
      _request({'op': 'control', 'command': command});
  @override
  Future<void> scan() async {
    final r = await _request({'op': 'scan'});
    _emit({'type': 'discovery', 'devices': r['devices']});
  }

  @override
  Future<DevicePeer> connect(String peripheral, {String? expected}) =>
      _connecting.putIfAbsent(
        peripheral,
        () => _connect(peripheral, expected: expected).whenComplete(() {
          _connecting.remove(peripheral);
        }),
      );
  Future<DevicePeer> _connect(String peripheral, {String? expected}) async {
    if (peers.containsKey(peripheral)) return peers[peripheral]!;
    final info = await _request({'op': 'connect', 'device_id': peripheral});
    if (info['device_id'] != (expected ?? peripheral) ||
        info['protocol_version'] != 2 ||
        info['firmware_version'] != 'sim-2.0.0') {
      throw const UserError('Eltérő szimulátorazonosító vagy protokoll.');
    }
    final peer = DevicePeer(info);
    await synchronize(peer);
    if (_disposed) throw const UserError('A szimulátor kapcsolata lezárult.');
    peers[peripheral] = peer;
    _emit({
      'type': 'connected',
      'device_id': peripheral,
      'info': info,
      'clock': peer.clock,
    });
    return peer;
  }

  @override
  Future<Json> command(DevicePeer peer, Json command) async {
    if (peer.busy) {
      throw const UserError('Az eszköz még az előző műveletet végzi.');
    }
    peer.busy = true;
    try {
      return await _request({
        'op': 'device',
        'device_id': peer.info['device_id'],
        'command': command,
      });
    } finally {
      peer.busy = false;
    }
  }

  @override
  Future<void> synchronize(DevicePeer peer) async {
    final start = DateTime.now().toUtc().millisecondsSinceEpoch,
        watch = Stopwatch()..start();
    final reply = await command(peer, {'op': 'time'});
    final rtt = watch.elapsedMilliseconds;
    if ((DateTime.now().millisecondsSinceEpoch - start - rtt).abs() > 50) {
      throw const UserError('Az óra megváltozott. Próbáld újra.');
    }
    peer.clock = DeviceClock(
      peer.info['boot_id'] as String,
      reply['uptime_ms'] as int,
      start + rtt ~/ 2,
      (rtt + 1) ~/ 2,
    );
  }

  Future<void> _reconnect() async {
    if (_disposed || _reconnecting || _desired.isEmpty) return;
    _reconnecting = true;
    try {
      await scan();
      for (final id in _desired.toList()) {
        if (_disposed) break;
        if (peers.containsKey(id) || _manual.contains(id)) continue;
        try {
          await connect(id, expected: id);
        } catch (_) {}
      }
    } catch (_) {
      /* The next timer tick retries the loopback process. */
    } finally {
      _reconnecting = false;
    }
  }

  @override
  Future<void> select(List<Json> devices) async {
    _desired
      ..clear()
      ..addAll(devices.map((d) => d['id'] as String));
    _manual.clear();
    for (final id in peers.keys.toList()) {
      if (!_desired.contains(id)) await disconnect(id);
    }
    await scan();
    await _reconnect();
  }

  @override
  Future<void> disconnect(String id) async {
    _manual.add(id);
    if (_socket != null) await _request({'op': 'disconnect', 'device_id': id});
    _drop(id);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    _desired.clear();
    await _socket?.close();
    _lost();
    await events.close();
  }
}
