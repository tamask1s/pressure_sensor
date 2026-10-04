import 'dart:async';
import 'dart:math';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import '../core/model.dart';
import '../core/protocol.dart';

class Peer {
  final Peripheral peripheral;
  final Json info;
  final Map<String, GATTCharacteristic> characteristics;
  DeviceClock? clock;
  bool busy = false;
  int requestId = 1;
  Peer(this.peripheral, this.info, this.characteristics);
}

class BleHub {
  final CentralManager manager = CentralManager();
  final events = StreamController<Json>.broadcast();
  final discovered = <String, DiscoveredEventArgs>{}, peers = <String, Peer>{};
  final desired = <String>{}, manual = <String>{}, connecting = <String>{};
  final nextAttempt = <String, DateTime>{}, attempts = <String, int>{};
  final subscriptions = <StreamSubscription>[];
  Timer? timer;
  bool scanning = false, disposed = false;
  Future<void>? _scanWork;
  BleHub() {
    subscriptions.add(
      manager.discovered.listen((e) {
        discovered[e.peripheral.uuid.toString()] = e;
        events.add({
          'type': 'discovery',
          'devices': [
            for (final d in discovered.entries)
              {
                'peripheral': d.key,
                'name': d.value.advertisement.name ?? shortId(d.key),
                'rssi': d.value.rssi,
              },
          ],
        });
        _reconnect();
      }),
    );
    subscriptions.add(
      manager.connectionStateChanged.listen((e) {
        if (e.state == ConnectionState.disconnected) {
          for (final p in peers.entries.toList()) {
            if (p.value.peripheral.uuid == e.peripheral.uuid) {
              peers.remove(p.key);
              events.add({'type': 'disconnected', 'device_id': p.key});
              _backoff(p.key);
            }
          }
        }
      }),
    );
    subscriptions.add(
      manager.characteristicNotified.listen((e) {
        if (e.characteristic.uuid.toString() != bleUuid(2)) return;
        for (final entry in peers.entries) {
          if (entry.value.peripheral.uuid == e.peripheral.uuid) {
            try {
              final packet = Packet.decode(e.value);
              events.add({
                'type': 'packet',
                'device_id': entry.key,
                'packet': packet,
              });
            } catch (error) {
              events.add({'type': 'error', 'message': explain(error)});
            }
            break;
          }
        }
      }),
    );
    subscriptions.add(
      manager.stateChanged.listen((e) {
        events.add({'type': 'adapter', 'state': e.state.name});
        if (e.state == BluetoothLowEnergyState.poweredOn) {
          scanning = false;
          _reconnect();
        }
      }),
    );
    timer = Timer.periodic(const Duration(seconds: 1), (_) => _reconnect());
  }
  Future<void> scan() =>
      _scanWork ??= _scan().whenComplete(() => _scanWork = null);
  Future<void> _scan() async {
    if (disposed) return;
    if (manager.state == BluetoothLowEnergyState.unauthorized) {
      await manager.authorize();
    }
    if (manager.state != BluetoothLowEnergyState.poweredOn) {
      throw const UserError(
        'Kapcsold be a Bluetooth-t, és engedélyezd a közeli eszközök elérését.',
      );
    }
    if (!scanning) {
      await manager.startDiscovery(serviceUUIDs: [UUID.fromString(bleUuid(1))]);
      scanning = true;
      if (disposed) {
        await manager.stopDiscovery();
        scanning = false;
      }
    }
  }

  Future<void> _reconnect() async {
    if (disposed || desired.isEmpty) return;
    try {
      await scan();
    } catch (_) {
      return;
    }
    for (final id in desired.toList()) {
      if (disposed) break;
      if (manual.contains(id) ||
          peers.containsKey(id) ||
          connecting.contains(id) ||
          DateTime.now().isBefore(nextAttempt[id] ?? DateTime(2000))) {
        continue;
      }
      final candidates = discovered.values.where(
        (d) => d.advertisement.name == id,
      );
      if (candidates.isEmpty) continue;
      connecting.add(id);
      try {
        await connect(
          candidates.first.peripheral.uuid.toString(),
          expected: id,
        );
        attempts[id] = 0;
      } catch (e) {
        if (!disposed) {
          events.add({
            'type': 'error',
            'message': '${shortId(id)}: ${explain(e)}',
          });
        }
        _backoff(id);
      } finally {
        connecting.remove(id);
      }
    }
  }

  void _backoff(String id) {
    final n = ((attempts[id] ?? 0) + 1).clamp(1, 5);
    attempts[id] = n;
    nextAttempt[id] = DateTime.now().add(
      Duration(
        milliseconds: min(15000, 500 * (1 << n)) + Random().nextInt(300),
      ),
    );
  }

  Future<Peer> connect(String peripheral, {String? expected}) async {
    if (disposed) throw const UserError('A kapcsolatkezelő már leállt.');
    final found = discovered[peripheral];
    if (found == null) {
      throw const UserError('Az eszköz eltűnt. Indíts új keresést.');
    }
    final known = peers.values.where(
      (p) => p.peripheral.uuid == found.peripheral.uuid,
    );
    if (known.isNotEmpty) return known.first;
    final p = found.peripheral;
    try {
      await manager.connect(p).timeout(const Duration(seconds: 25));
      final services = await manager
          .discoverGATT(p)
          .timeout(const Duration(seconds: 15));
      final chars = <String, GATTCharacteristic>{};
      void visit(GATTService s) {
        for (final c in s.characteristics) {
          chars[c.uuid.toString()] = c;
        }
        for (final child in s.includedServices) {
          visit(child);
        }
      }

      for (final s in services) {
        visit(s);
      }
      for (final n in [2, 3, 4, 5]) {
        if (!chars.containsKey(bleUuid(n))) {
          throw const UserError('A készülékhez V2 firmware szükséges.');
        }
      }
      final info = decodeObject(
        await manager
            .readCharacteristic(p, chars[bleUuid(3)]!)
            .timeout(const Duration(seconds: 10)),
      );
      if (disposed) throw const UserError('A kapcsolatkezelő már leállt.');
      if (info['protocol_version'] != 2 ||
          !RegExp(
            r'^hps-[0-9a-f]{12}$',
          ).hasMatch(info['device_id'] as String? ?? '') ||
          (expected != null && info['device_id'] != expected)) {
        throw const UserError('Eltérő eszközazonosító vagy protokoll.');
      }
      if (info['provisioned'] != true) {
        throw const UserError('A készülék USB-s előkészítése még hiányzik.');
      }
      final peer = Peer(p, info, chars);
      peers[info['device_id'] as String] = peer;
      final secureUntil = DateTime.now().add(const Duration(seconds: 35));
      while (true) {
        try {
          await manager
              .readCharacteristic(p, chars[bleUuid(5)]!)
              .timeout(const Duration(seconds: 5));
          break;
        } catch (_) {
          if (DateTime.now().isAfter(secureUntil)) {
            throw const UserError(
              'A biztonságos párosítás nem sikerült. Nyisd meg a párosítási ablakot, és ellenőrizd a PIN-t.',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
      await synchronize(peer);
      await manager
          .setCharacteristicNotifyState(p, chars[bleUuid(2)]!, state: true)
          .timeout(const Duration(seconds: 10));
      info.addAll(
        decodeObject(
          await manager
              .readCharacteristic(p, chars[bleUuid(3)]!)
              .timeout(const Duration(seconds: 5)),
        ),
      );
      if (disposed) throw const UserError('A kapcsolatkezelő már leállt.');
      events.add({
        'type': 'connected',
        'device_id': info['device_id'],
        'info': info,
        'clock': peer.clock,
      });
      return peer;
    } catch (_) {
      peers.removeWhere((_, peer) => peer.peripheral.uuid == p.uuid);
      try {
        await manager.disconnect(p);
      } catch (_) {}
      rethrow;
    }
  }

  Future<Json> command(Peer peer, Json command) async {
    if (peer.busy) {
      throw const UserError('Az eszköz még az előző műveletet végzi.');
    }
    peer.busy = true;
    try {
      final id = peer.requestId;
      peer.requestId = id % 65535 + 1;
      for (final frame in controlFrames(id, command)) {
        await manager
            .writeCharacteristic(
              peer.peripheral,
              peer.characteristics[bleUuid(4)]!,
              value: frame,
              type: GATTCharacteristicWriteType.withResponse,
            )
            .timeout(const Duration(seconds: 3));
      }
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline)) {
        final answer = decodeObject(
          await manager
              .readCharacteristic(
                peer.peripheral,
                peer.characteristics[bleUuid(5)]!,
              )
              .timeout(const Duration(seconds: 3)),
        );
        if (answer['id'] == id) {
          if (answer['ok'] != true) {
            throw UserError('A készülék válasza: ${answer['error']}');
          }
          return answer;
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      throw TimeoutException('BLE-válasz');
    } finally {
      peer.busy = false;
    }
  }

  Future<void> synchronize(Peer p) async {
    DeviceClock? best;
    var bestRtt = 1 << 30;
    for (var i = 0; i < 3; ++i) {
      final start = DateTime.now().toUtc().millisecondsSinceEpoch;
      final watch = Stopwatch()..start();
      final reply = await command(p, {'op': 'time'});
      final rtt = watch.elapsedMilliseconds;
      if ((DateTime.now().toUtc().millisecondsSinceEpoch - start - rtt).abs() >
          50) {
        continue;
      }
      if (rtt < bestRtt) {
        bestRtt = rtt;
        best = DeviceClock(
          p.info['boot_id'] as String,
          (reply['uptime_ms'] as num).toInt(),
          start + rtt ~/ 2,
          (rtt + 1) ~/ 2,
        );
      }
    }
    p.clock = best;
    if (best == null) {
      throw const UserError(
        'A telefon órája megváltozott az időegyeztetés közben. Próbáld újra.',
      );
    }
  }

  Future<void> select(List<Json> devices) async {
    final ids = devices.map((e) => e['id'] as String).toSet();
    for (final id in peers.keys.toList()) {
      if (!ids.contains(id)) await disconnect(id);
    }
    desired
      ..clear()
      ..addAll(ids);
    manual.clear();
    await scan();
    await _reconnect();
  }

  Future<void> disconnect(String id) async {
    manual.add(id);
    final peer = peers.remove(id);
    if (peer != null) await manager.disconnect(peer.peripheral);
    events.add({'type': 'disconnected', 'device_id': id});
  }

  Future<void> dispose() async {
    disposed = true;
    timer?.cancel();
    desired.clear();
    for (final id in peers.keys.toList()) {
      await disconnect(id);
    }
    if (scanning) {
      try {
        await manager.stopDiscovery();
      } catch (_) {}
    }
    for (final s in subscriptions) {
      await s.cancel();
    }
    await events.close();
  }
}
